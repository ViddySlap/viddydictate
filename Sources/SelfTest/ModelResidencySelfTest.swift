import Foundation

/// Headless verification of the model-residency mechanism (interop ADR 0004, reversing ADR 0006's
/// app-side idle timer): LM Studio — not the app — owns eviction, via the per-model `--ttl` set on each
/// `ensureReady` load. Run with `--residency-selftest`. Needs LM Studio.
///
/// It runs the locked interleaved eviction acceptance test on the real app path, on qwen (the cleanup /
/// retrieval model the acceptance test names), with a SHORT test TTL so eviction is observable in
/// seconds instead of the production 15 minutes:
///
///   1. per-model TTL policy is the locked one (qwen 900s, gemma 300s)  [pure unit assert]
///   2. clean slate: qwen unloaded
///   3. ViddyDictate cleanup-path load: `ensureReady(qwen, ttlOverride: short)` -> resident, and the
///      short TTL actually reached LM Studio (`lms ps --json` ttlMs)
///   4. a real qwen `/v1/chat/completions` turn (the shared-client seam) succeeds against the instance
///   5. a second cleanup-path `ensureReady` reuses the SAME resident instance (no reload)
///   6. idle past the TTL with the app doing NOTHING -> LM Studio evicts qwen on its own
///      (`lms ps` no longer lists it), while bge-m3's residency is UNCHANGED (not evicted by side effect)
///   7. JIT reload on the next request: `ensureReady(qwen)` brings it back
///
/// The app makes zero `unload` calls across steps 3-7, so an eviction observed at step 6 can only be
/// LM Studio's. Full rationale + the production interleave: `docs/model-residency.md`.
enum ModelResidencySelfTest {

    /// A representative model loaded outside ViddyDictate. It must never be evicted as a side effect
    /// of loading or evicting the app's LLMs. Not a Settings model.
    private static let bgeEmbedder = "text-embedding-bge-m3"
    /// Short idle TTL for the test so eviction happens in seconds, not the production 15 min. Comfortably
    /// longer than the gap between the load and the idle wait so the model does not evict mid-test.
    private static let testTTL = 20
    /// How long to idle after last use before checking for eviction (TTL + margin).
    private static let idleWait: TimeInterval = 35

    static func run() -> Bool {
        let model = Settings.cleanupModel
        print("--- model residency: interleaved eviction test (interop ADR 0004), model: \(model) ---\n")

        let reporter = SelfTestReporter()
        let check = reporter

        // 1. Per-model TTL policy is the locked one — pure, no LM Studio needed.
        let qwenTTL = ModelManager.shared.ttl(for: Settings.cleanupModel)
        let gemmaTTL = ModelManager.shared.ttl(for: Settings.emailModel)
        check("per-model TTL policy (qwen 900 / gemma 300)", qwenTTL == 900 && gemmaTTL == 300,
              "qwen=\(qwenTTL)s, gemma=\(gemmaTTL)s")

        guard FileManager.default.isExecutableFile(atPath: "\(NSHomeDirectory())/.lmstudio/bin/lms") else {
            print("\n  [skip] lms CLI not found, cannot run the live eviction test")
            return false
        }

        // Record bge-m3 residency up front; the invariant is that qwen's whole load/evict cycle does not
        // change it (it should be resident via the keep-alive, but the test proves "unchanged", not "up").
        let bgeBefore = ModelResidency.isLoaded(bgeEmbedder)
        print("  [info] bge-m3 resident at start: \(b(bgeBefore))\(bgeBefore ? "" : "  (keep-alive down? not this test's concern)")\n")

        // 2. Clean slate so the test's own load definitely applies the short TTL.
        ModelResidency.unload(model)
        check("clean slate: qwen not resident", !ModelResidency.isLoaded(model), "isLoaded=\(b(ModelResidency.isLoaded(model)))")

        // 3. ViddyDictate cleanup-path load, with the short test TTL, via the real production path.
        let t0 = Date()
        let ready = ModelManager.shared.ensureReady(model, ttlOverrideSeconds: testTTL)
        let residentAfterLoad = ModelResidency.isLoaded(model)
        check("cleanup-path load makes qwen resident", ready && residentAfterLoad,
              String(format: "ensureReady=%@, isLoaded=%@, %.1fs", b(ready), b(residentAfterLoad), Date().timeIntervalSince(t0)))
        let seenTTL = ModelResidency.loadedTTLSeconds(model)
        check("per-model TTL reached LM Studio", seenTTL == testTTL, "lms ps ttl=\(seenTTL.map(String.init) ?? "nil")s (expected \(testTTL)s)")

        // 4. Shared-client seam: a real /v1 chat turn against the shared resident qwen. Also resets LM Studio's
        //    idle clock, so the idle window below is measured from here.
        let turn = chatTurn(model: model, endpoint: Settings.cleanupEndpoint)
        check("qwen /v1 chat turn succeeds", turn.ok, turn.detail)

        // 5. A second cleanup-path ensureReady reuses the SAME instance (resident -> no reload).
        let reuse = ModelManager.shared.ensureReady(model)
        check("cleanup-path reuse hits the resident instance", reuse && ModelResidency.isLoaded(model),
              "ensureReady=\(b(reuse)), isLoaded=\(b(ModelResidency.isLoaded(model)))")

        // 6. Idle past the TTL — the app does NOTHING here. Any eviction is LM Studio's.
        print("\n  [info] idling \(Int(idleWait))s (no use) to let LM Studio evict qwen past its \(testTTL)s TTL...\n")
        Thread.sleep(forTimeInterval: idleWait)
        let evicted = !ModelResidency.isLoaded(model)
        check("LM Studio evicted qwen on idle (app issued no unload)", evicted, "isLoaded after idle=\(b(!evicted))")
        let bgeAfter = ModelResidency.isLoaded(bgeEmbedder)
        check("bge-m3 residency unchanged (not evicted by side effect)", bgeAfter == bgeBefore,
              "bge-m3 before=\(b(bgeBefore)), after=\(b(bgeAfter))")

        // 7. JIT reload on the next request restores it (and leaves qwen resident with the production TTL).
        let reloaded = ModelManager.shared.ensureReady(model)
        check("next request JIT-reloads qwen", reloaded && ModelResidency.isLoaded(model),
              "ensureReady=\(b(reloaded)), isLoaded=\(b(ModelResidency.isLoaded(model)))")

        print("\n=== RESULT ===")
        print(reporter.passed ? "GREEN BAR CLEARED ✅" : "RESIDENCY TEST FAILED ❌")
        return reporter.passed
    }

    /// One synchronous `/v1/chat/completions` turn (headless CLI, so block on a semaphore). Proves a
    /// An external-client-style API turn works against the shared resident model; a tiny max_tokens keeps it fast.
    private static func chatTurn(model: String, endpoint: URL) -> (ok: Bool, detail: String) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 1,
            "stream": false,
            "messages": [["role": "user", "content": "ping"]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (false, "encode failed") }
        req.httpBody = data

        var result: (ok: Bool, detail: String) = (false, "no response")
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error = error { result = (false, error.localizedDescription); return }
            guard let http = response as? HTTPURLResponse else { result = (false, "no http response"); return }
            guard (200..<300).contains(http.statusCode) else { result = (false, "HTTP \(http.statusCode)"); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["choices"] is [[String: Any]]
            else { result = (false, "HTTP 200 but no choices array"); return }
            result = (true, "HTTP \(http.statusCode), choices present")
        }
        task.resume()
        if sem.wait(timeout: .now() + 65) == .timedOut { return (false, "chat turn timed out") }
        return result
    }

    private static func b(_ v: Bool) -> String { v ? "yes" : "no" }
}
