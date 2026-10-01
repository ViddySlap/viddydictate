import Foundation

/// G4 (`--local-capacity-backends-selftest`): ADR 0018's capacity policy across both local apps, driven
/// through the REAL `ModelManager` over injected `CapacityDependencies`. LM Studio is an in-memory resident
/// set; Ollama is the real `OllamaBackend` over a scripted transport (an in-memory `/api/tags`, `/api/show`,
/// `/api/ps` and `/api/generate` that loads and unloads really change), so the incoming estimate, the
/// tags-sized residents and D5's reuse rule are the shipped code, not a copy of it. No socket, no kernel
/// reading, no LM Studio, no preferences.
///
/// Distinct values everywhere, so a default cannot pass by accident:
/// - the gemma-like model is 6.6 GB in `/api/tags` but **0.3 GB** in `/api/ps`, the 10-20x under-report
///   measured on Ben's Mac, and its budget is set so a ps-based estimate visibly fits, a tags-only estimate
///   (no KV) also fits, and only tags + KV(num_ctx) refuses;
/// - `shared-id-on-both:7b` is resident in BOTH apps, owned in one and foreign in the other;
/// - Ollama's `expires_at` order is the REVERSE of ViddyDictate's own use order;
/// - every load carries the idle window **437**, never the app's 600.
///
/// The LM-Studio-only arm replays `ModelCapacitySelfTest`'s scenarios with that file's expected values
/// written out, twice: through the String API with no Ollama facts at all, and through the ref API with a
/// scripted Ollama present that must receive no request.
///
/// Negative controls: the contract is re-run against three broken policies, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) the Ollama estimate sized from `/api/ps` instead of `/api/tags`;
/// (b) eviction keyed by model id alone (an evicted id is unloaded in both apps);
/// (c) a policy blind to the resident context, which reloads even a larger resident instance.
enum LocalCapacityBackendsFixtureSelfTest {
    private static let ttl = 437
    private static let gb: UInt64 = 1_000_000_000

    private static let sharedID = "shared-id-on-both:7b"
    private static let lmIncoming = "lmstudio-fixture-incoming"
    private static let gemmaLike = "ollama-fixture-gemma-like:e4b"
    private static let ollamaIncoming = "ollama-fixture-incoming:7b"
    private static let older = "ollama-fixture-older:7b"
    private static let newer = "ollama-fixture-newer:7b"
    private static let busy = "ollama-fixture-busy:7b"
    private static let foreign = "ollama-fixture-foreign:7b"
    private static let roomy = "ollama-fixture-roomy:7b"
    private static let snug = "ollama-fixture-snug:7b"

    /// The fixture geometry's KV cache: 42 layers x 2 KV heads x (256 + 256) x tokens x 2 bytes.
    private static func fixtureKV(_ tokens: Int) -> Int64 { 42 * 2 * 512 * Int64(tokens) * 2 }

    // Assertion names the negative controls look up.
    private static let estimateCheck =
        "the Ollama estimate is (tags size + KV(8192)) x 1.15: 6.6 GB in tags but 0.3 GB in ps, over budget, refused"
    private static let sameIDCheck =
        "evicting ViddyDictate's Ollama shared-id-on-both:7b leaves LM Studio's foreign shared-id-on-both:7b loaded"
    private static let reuseCheck =
        "a resident Ollama model at context 32768 serves a 16384 request as it is: no load, num_ctx 32768"

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== local capacity across both apps fixture selftest (ADR 0018 + D5) ===")
        let reporter = SelfTestReporter()

        checkBackendFacts(reporter)
        print("--- contract (real ModelManager, real OllamaBackend over a scripted transport) ---")
        checkContract(realDependencies, reporter)
        checkLRUAndBusy(reporter)
        checkSettleAndFacts(reporter)
        checkLMStudioOnlyMatchesToday(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[local-capacity-backends-selftest] PASS"
            : "[local-capacity-backends-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - The scripted Mac

    private struct OllamaModel {
        let tagsSize: UInt64
        let psSize: UInt64
        let expiresAt: String
    }

    private static let ollamaCatalog: [String: OllamaModel] = [
        sharedID: OllamaModel(tagsSize: 4 * gb, psSize: gb / 5, expiresAt: "2026-09-30T14:10:00Z"),
        gemmaLike: OllamaModel(tagsSize: 6_600_000_000, psSize: 300_000_000, expiresAt: "2026-09-30T14:20:00Z"),
        ollamaIncoming: OllamaModel(tagsSize: 2 * gb, psSize: gb / 10, expiresAt: "2026-09-30T14:30:00Z"),
        // expires_at says `older` was used LAST; ViddyDictate's own stamps say the opposite.
        older: OllamaModel(tagsSize: gb, psSize: gb / 20, expiresAt: "2026-09-30T16:00:00Z"),
        newer: OllamaModel(tagsSize: gb, psSize: gb / 20, expiresAt: "2026-09-30T13:00:00Z"),
        busy: OllamaModel(tagsSize: gb, psSize: gb / 20, expiresAt: "2026-09-30T12:00:00Z"),
        foreign: OllamaModel(tagsSize: 1_500_000_000, psSize: gb / 20, expiresAt: "2026-09-30T11:00:00Z"),
        roomy: OllamaModel(tagsSize: gb, psSize: gb / 20, expiresAt: "2026-09-30T14:40:00Z"),
        snug: OllamaModel(tagsSize: gb, psSize: gb / 20, expiresAt: "2026-09-30T14:50:00Z"),
    ]

    /// Both apps and the kernel's wired reading, as one mutable world every closure reads.
    private final class World {
        // LM Studio
        var lmInstalled: [LMStudioInstalledModel] = [
            LMStudioInstalledModel(modelID: lmIncoming, label: lmIncoming, type: "llm",
                                   sizeBytes: Int64(2 * gb), visionFlag: false),
            LMStudioInstalledModel(modelID: sharedID, label: sharedID, type: "llm",
                                   sizeBytes: Int64(3 * gb), visionFlag: false),
        ]
        var lmResidents: [ModelResidency.ResidentModel] = []
        var lmLoads: [String] = []
        var lmUnloads: [String] = []
        // Ollama: name -> loaded context, in load order.
        var ollamaResident: [String: Int] = [:]
        var ollamaOrder: [String] = []
        var ollamaRequests: [(path: String, body: [String: Any]?)] = []
        // The kernel.
        var wired: UInt64 = 0
        var budget: UInt64 = 1_000 * 1_000_000_000
        var now = Date(timeIntervalSince1970: 1_000)

        var ollamaUnloads: [String] {
            ollamaRequests.compactMap { request in
                guard request.path == "/api/generate",
                      (request.body?["keep_alive"] as? NSNumber)?.intValue == 0 else { return nil }
                return request.body?["model"] as? String
            }
        }

        var ollamaLoads: [[String: Any]] {
            ollamaRequests.compactMap { request in
                guard request.path == "/api/generate",
                      (request.body?["keep_alive"] as? NSNumber)?.intValue != 0 else { return nil }
                return request.body
            }
        }

        func residentInOllama(_ name: String, context: Int) {
            ollamaResident[name] = context
            if !ollamaOrder.contains(name) { ollamaOrder.append(name) }
        }

        func residentInLMStudio(_ id: String, size: UInt64, lastUsed: UInt64?, status: String = "idle") {
            lmResidents.append(.init(identifier: id, sizeBytes: size, lastUsedTime: lastUsed, status: status))
        }

        var transport: OllamaBackend.Transport {
            OllamaBackend.Transport(
                send: { request, _ in self.serve(request) },
                pathStatus: { _ in .missing })
        }

        private func serve(_ request: URLRequest) -> (Data?, HTTPURLResponse?, Error?) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            ollamaRequests.append((path, body))
            let (text, status) = reply(path: path, body: body)
            let response = request.url.flatMap {
                HTTPURLResponse(url: $0, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            }
            return (Data(text.utf8), response, nil)
        }

        private func reply(path: String, body: [String: Any]?) -> (String, Int) {
            let model = body?["model"] as? String
            switch path {
            case "/api/tags":
                let rows = ollamaCatalog.keys.sorted().map { name in
                    "{\"name\":\"\(name)\",\"model\":\"\(name)\",\"size\":\(ollamaCatalog[name]!.tagsSize),"
                        + "\"capabilities\":[\"completion\",\"tools\"]}"
                }
                return ("{\"models\":[\(rows.joined(separator: ","))]}", 200)
            case "/api/show":
                guard let model, ollamaCatalog[model] != nil else { return ("{\"error\":\"not found\"}", 404) }
                return ("""
                {"capabilities":["completion","tools"],"model_info":{"general.architecture":"fixturearch",
                 "fixturearch.block_count":42,"fixturearch.attention.head_count":8,
                 "fixturearch.attention.head_count_kv":2,"fixturearch.attention.key_length":256,
                 "fixturearch.attention.value_length":256}}
                """, 200)
            case "/api/ps":
                let rows = ollamaOrder.compactMap { name -> String? in
                    guard let context = ollamaResident[name], let row = ollamaCatalog[name] else { return nil }
                    return "{\"name\":\"\(name)\",\"model\":\"\(name)\",\"size\":\(row.psSize),"
                        + "\"size_vram\":\(row.psSize),\"expires_at\":\"\(row.expiresAt)\","
                        + "\"context_length\":\(context)}"
                }
                return ("{\"models\":[\(rows.joined(separator: ","))]}", 200)
            case "/api/generate":
                guard let model, let row = ollamaCatalog[model] else {
                    return ("{\"error\":\"model not found\"}", 404)
                }
                if (body?["keep_alive"] as? NSNumber)?.intValue == 0 {
                    if ollamaResident.removeValue(forKey: model) != nil {
                        wired -= min(wired, row.tagsSize)
                    }
                    ollamaOrder.removeAll { $0 == model }
                    return ("{\"done\":true,\"done_reason\":\"unload\"}", 200)
                }
                let context = ((body?["options"] as? [String: Any])?["num_ctx"] as? NSNumber)?.intValue ?? 4096
                residentInOllama(model, context: context)
                return ("{\"done\":true,\"done_reason\":\"load\"}", 200)
            default:
                return ("{\"error\":\"not found\"}", 404)
            }
        }
    }

    // MARK: - The seam the mutants replace

    private typealias DependencyFactory = (World) -> ModelManager.CapacityDependencies

    private static func ollamaBackend(_ world: World) -> OllamaBackend {
        OllamaBackend(transport: world.transport, environment: [:], homeDirectory: "/fixture-home")
    }

    private static func lmStudioDependencies(_ world: World,
                                             ollama: ModelManager.OllamaCapacityDependencies?)
        -> ModelManager.CapacityDependencies {
        ModelManager.CapacityDependencies(
            availableInstalledModels: { world.lmInstalled },
            residentModels: { world.lmResidents },
            wiredBytes: { world.wired },
            budgetBytes: { _ in world.budget },
            ensureLoaded: { model, _ in
                world.lmLoads.append(model)
                let size = world.lmInstalled.first { $0.modelID == model }?.sizeBytes ?? 0
                world.residentInLMStudio(model, size: UInt64(size), lastUsed: 5)
                world.wired += UInt64(size)
                return true
            },
            unload: { model in
                world.lmUnloads.append(model)
                if let row = world.lmResidents.first(where: { $0.identifier == model }) {
                    world.wired -= min(world.wired, row.sizeBytes)
                }
                world.lmResidents.removeAll { $0.identifier == model }
            },
            log: { _ in },
            ollama: ollama)
    }

    private static let realDependencies: DependencyFactory = { world in
        lmStudioDependencies(world, ollama: .backed(by: ollamaBackend(world)))
    }

    private static func manager(_ world: World) -> ModelManager {
        ModelManager(clock: { world.now })
    }

    private static func ref(_ backend: LocalBackendID, _ id: String) -> LocalModelRef {
        LocalModelRef(backend: backend, modelID: id)
    }

    // MARK: - Backend facts

    private static func checkBackendFacts(_ reporter: SelfTestReporter) {
        print("--- backend facts (real OllamaBackend) ---")
        let world = World()
        world.residentInOllama(gemmaLike, context: 4096)
        let backend = ollamaBackend(world)
        let resident = backend.residentModels()?.first
        reporter.record("residentModels sizes a loaded model from /api/tags (6.6 GB), never /api/ps (0.3 GB)",
                        resident?.residentBytes == 6_600_000_000 && resident?.contextLength == 4096,
                        "residentBytes=\(resident?.residentBytes ?? 0)")
        let kv8 = backend.kvCacheBytes(for: ref(.ollama, gemmaLike), contextTokens: 8192)
        let kv16 = backend.kvCacheBytes(for: ref(.ollama, gemmaLike), contextTokens: 16384)
        let shows = world.ollamaRequests.filter { $0.path == "/api/show" }.count
        reporter.record("kvCacheBytes is the S2 upper bound from model_info, linear in num_ctx, show asked once",
                        kv8 == fixtureKV(8192) && kv16 == 2 * fixtureKV(8192) && shows == 1,
                        "kv8=\(kv8 ?? -1) kv16=\(kv16 ?? -1) shows=\(shows)")
        reporter.record("an LM Studio ref has no Ollama KV", backend.kvCacheBytes(
            for: ref(.lmStudio, gemmaLike), contextTokens: 8192) == nil)
        let expected = UInt64((Double(6_600_000_000 + fixtureKV(8192)) * 1.15).rounded(.up))
        reporter.record("the Ollama estimate keeps ADR 0018's 1.15 factor over tags size + KV",
                        ModelManager.estimatedIncomingBytes(sizeBytes: 6_600_000_000,
                                                            kvCacheBytes: fixtureKV(8192)) == expected
                            && ModelManager.incomingFootprintFactor == 1.15,
                        "expected=\(expected)")
        reporter.record("a missing geometry falls back to a pessimistic KV, never zero",
                        ModelManager.fallbackKVCacheBytes(sizeBytes: 4_000_000_000, contextTokens: 8192)
                            == 1_000_000_000
                            && ModelManager.fallbackKVCacheBytes(sizeBytes: 4_000_000_000, contextTokens: 16384)
                            == 2_000_000_000)
        reporter.record("D5's reuse rule: larger or equal reuses, smaller or unreported reloads",
                        OllamaBackend.reusesResident(contextLength: 32768, wanted: 16384)
                            && OllamaBackend.reusesResident(contextLength: 8192, wanted: 8192)
                            && !OllamaBackend.reusesResident(contextLength: 4096, wanted: 8192)
                            && !OllamaBackend.reusesResident(contextLength: nil, wanted: 8192))

        // The backend applies the same rule on its own (the policy is not the only guard).
        let direct = World()
        direct.residentInOllama(roomy, context: 32768)
        direct.residentInOllama(snug, context: 4096)
        let directBackend = ollamaBackend(direct)
        let roomyLoaded = directBackend.ensureLoaded(ref(.ollama, roomy), ttlSeconds: ttl, contextTokens: 16384)
        let roomyLoads = direct.ollamaLoads.count
        let snugLoaded = directBackend.ensureLoaded(ref(.ollama, snug), ttlSeconds: ttl, contextTokens: 8192)
        let snugLoad = direct.ollamaLoads.last
        reporter.record("OllamaBackend.ensureLoaded reuses a larger context and reloads a smaller one at ours",
                        roomyLoaded && roomyLoads == 0 && snugLoaded && direct.ollamaLoads.count == 1
                            && (snugLoad?["keep_alive"] as? NSNumber)?.intValue == ttl
                            && ((snugLoad?["options"] as? [String: Any])?["num_ctx"] as? NSNumber)?.intValue == 8192
                            && direct.ollamaResident[snug] == 8192,
                        "loads=\(direct.ollamaLoads.count)")
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(_ dependencies: DependencyFactory, _ reporter: SelfTestReporter) {
        // (1) The estimate: tags + KV, never ps. The model is resident at 4096 and the request needs 8192, so
        // it is a reload and goes through the estimate. 10 GB wired against an 18 GB budget: ps (0.3 GB) fits,
        // tags alone (7.59 GB) fits, tags + KV (8.40 GB) does not.
        do {
            let world = World()
            world.residentInOllama(gemmaLike, context: 4096)
            world.wired = 10 * gb
            world.budget = 18 * gb
            let result = manager(world).ensureReady(ref(.ollama, gemmaLike), contextTokens: 8192,
                                                    ttlOverrideSeconds: ttl, dependencies: dependencies(world))
            reporter.record(estimateCheck,
                            result == .capacityRefused(.overBudget) && world.ollamaLoads.isEmpty,
                            "result=\(result) loads=\(world.ollamaLoads.count)")
        }

        // (2a) Same id in both apps: ViddyDictate loaded Ollama's, LM Studio's is foreign (and older).
        do {
            let world = World()
            world.residentInLMStudio(sharedID, size: 3 * gb, lastUsed: 1)
            let policy = manager(world)
            let deps = dependencies(world)
            let setup = policy.ensureReady(ref(.ollama, sharedID), contextTokens: 8192,
                                           ttlOverrideSeconds: ttl, dependencies: deps)
            world.wired = 15 * gb
            world.budget = 16 * gb
            let incoming = policy.ensureReady(ref(.lmStudio, lmIncoming), ttlOverrideSeconds: ttl,
                                              dependencies: deps)
            reporter.record(sameIDCheck,
                            setup == .ready && incoming == .ready && world.lmUnloads.isEmpty
                                && world.lmResidents.contains { $0.identifier == sharedID }
                                && world.ollamaUnloads == [sharedID] && world.lmLoads == [lmIncoming],
                            "lmUnloads=\(world.lmUnloads) ollamaUnloads=\(world.ollamaUnloads) incoming=\(incoming)")
        }

        // (2b) The reverse: ViddyDictate loaded LM Studio's, Ollama's is foreign.
        do {
            let world = World()
            world.residentInOllama(sharedID, context: 8192)
            let policy = manager(world)
            let deps = dependencies(world)
            let setup = policy.ensureReady(ref(.lmStudio, sharedID), ttlOverrideSeconds: ttl, dependencies: deps)
            world.wired = 15 * gb
            world.budget = 16 * gb
            let incoming = policy.ensureReady(ref(.ollama, ollamaIncoming), contextTokens: 8192,
                                              ttlOverrideSeconds: ttl, dependencies: deps)
            let load = world.ollamaLoads.last
            reporter.record(
                "evicting ViddyDictate's LM Studio shared-id-on-both:7b leaves Ollama's foreign one loaded",
                setup == .ready && incoming == .ready && world.lmUnloads == [sharedID]
                    && world.ollamaResident[sharedID] == 8192 && world.ollamaUnloads.isEmpty,
                "lmUnloads=\(world.lmUnloads) ollamaUnloads=\(world.ollamaUnloads) incoming=\(incoming)")
            reporter.record("the Ollama cold load carries keep_alive 437 and the surface's num_ctx 8192",
                            load?["model"] as? String == ollamaIncoming
                                && (load?["keep_alive"] as? NSNumber)?.intValue == ttl
                                && ((load?["options"] as? [String: Any])?["num_ctx"] as? NSNumber)?.intValue == 8192)
        }

        // (3) D5: reuse a larger resident context, reload a smaller one.
        do {
            let world = World()
            world.residentInOllama(roomy, context: 32768)
            world.residentInOllama(snug, context: 4096)
            let policy = manager(world)
            let deps = dependencies(world)
            let reused = policy.ensureReadyForChat(ref(.ollama, roomy), contextTokens: 16384,
                                                   ttlOverrideSeconds: ttl, dependencies: deps)
            reporter.record(reuseCheck,
                            reused.result == .ready && reused.contextTokens == 32768 && world.ollamaLoads.isEmpty
                                && world.ollamaResident[roomy] == 32768,
                            "result=\(reused.result) ctx=\(reused.contextTokens ?? -1) loads=\(world.ollamaLoads.count)")
            let reloaded = policy.ensureReadyForChat(ref(.ollama, snug), contextTokens: 8192,
                                                     ttlOverrideSeconds: ttl, dependencies: deps)
            reporter.record("a resident Ollama model at context 4096 is reloaded at the 8192 the request needs",
                            reloaded.result == .ready && reloaded.contextTokens == 8192
                                && world.ollamaLoads.count == 1 && world.ollamaResident[snug] == 8192,
                            "result=\(reloaded.result) ctx=\(reloaded.contextTokens ?? -1)")
        }
    }

    // MARK: - LRU by ViddyDictate's own stamps, busy and foreign models kept

    private static func checkLRUAndBusy(_ reporter: SelfTestReporter) {
        print("--- LRU ranks by ViddyDictate's own use; busy and foreign Ollama models survive ---")
        let world = World()
        world.residentInOllama(foreign, context: 8192)
        let policy = manager(world)
        let deps = realDependencies(world)
        for (name, at) in [(older, 100.0), (newer, 200.0), (busy, 300.0)] {
            world.now = Date(timeIntervalSince1970: at)
            _ = policy.ensureReady(ref(.ollama, name), contextTokens: 8192, ttlOverrideSeconds: ttl,
                                   dependencies: deps)
        }
        // `older` was loaded first but USED last; `busy` has a request in flight.
        world.now = Date(timeIntervalSince1970: 400)
        policy.beginRequest(on: ref(.ollama, older))
        world.now = Date(timeIntervalSince1970: 500)
        policy.endRequest(on: ref(.ollama, older))
        world.now = Date(timeIntervalSince1970: 600)
        policy.beginRequest(on: ref(.ollama, busy))

        // 15 GB + (2 GB + KV) x 1.15 is over 17 GB; freeing the two idle owned 1 GB models makes it fit.
        world.wired = 15 * gb
        world.budget = 17 * gb
        let result = policy.ensureReady(ref(.ollama, ollamaIncoming), contextTokens: 8192,
                                        ttlOverrideSeconds: ttl, dependencies: deps)
        reporter.record("eviction runs LRU by ViddyDictate's own stamps (newer@200 before older@500), "
                            + "not by /api/ps expires_at (which orders them the other way)",
                        world.ollamaUnloads == [newer, older], "unloads=\(world.ollamaUnloads)")
        reporter.record("a model with a ViddyDictate request in flight is never evicted",
                        world.ollamaResident[busy] != nil && !world.ollamaUnloads.contains(busy))
        reporter.record("a foreign Ollama model is never evicted, even the oldest",
                        world.ollamaResident[foreign] != nil && !world.ollamaUnloads.contains(foreign))
        reporter.record("after the pass the incoming model loads", result == .ready, "result=\(result)")

        policy.endRequest(on: ref(.ollama, busy))
        world.wired = 15 * gb
        world.ollamaRequests.removeAll()
        _ = policy.ensureReady(ref(.ollama, sharedID), contextTokens: 8192, ttlOverrideSeconds: ttl,
                               dependencies: deps)
        reporter.record("once its request ends the formerly busy model is an ordinary candidate",
                        world.ollamaUnloads.contains(busy), "unloads=\(world.ollamaUnloads)")
    }

    // MARK: - Settle wait and missing facts

    private static func checkSettleAndFacts(_ reporter: SelfTestReporter) {
        print("--- settle wait and missing Ollama facts ---")
        // The kernel lags the unload: three stale readings, then the freed number. Without the 2 s window the
        // recheck refuses the load it just made room for; with it the load proceeds, for Ollama as for LM Studio.
        func settle(_ seconds: Double) -> (ModelManager.ReadinessResult, [String]) {
            let world = World()
            let policy = manager(world)
            let base = realDependencies(world)
            _ = policy.ensureReady(ref(.ollama, older), contextTokens: 8192, ttlOverrideSeconds: ttl,
                                   dependencies: base)
            var reads = 0
            let deps = ModelManager.CapacityDependencies(
                availableInstalledModels: base.availableInstalledModels, residentModels: base.residentModels,
                wiredBytes: { defer { reads += 1 }; return reads < 3 ? 15 * gb : 10 * gb },
                budgetBytes: { _ in 16 * gb }, ensureLoaded: base.ensureLoaded, unload: base.unload,
                log: { _ in }, evictionSettleSeconds: seconds, ollama: base.ollama)
            let result = policy.ensureReady(ref(.ollama, ollamaIncoming), contextTokens: 8192,
                                            ttlOverrideSeconds: ttl, dependencies: deps)
            return (result, world.ollamaUnloads)
        }
        let without = settle(0)
        let with = settle(1.0)
        reporter.record("without the settle window a stale reading refuses after an Ollama eviction",
                        without.0 == .capacityRefused(.overBudget) && without.1 == [older])
        reporter.record("with it the recheck sees the freed memory: still one unload, then the load",
                        with.0 == .ready && with.1 == [older], "result=\(with.0)")

        let world = World()
        let noOllama = lmStudioDependencies(world, ollama: nil)
        reporter.record("an Ollama ref with no Ollama facts is refused as facts unavailable, not loaded",
                        ModelManager().ensureReady(ref(.ollama, gemmaLike), contextTokens: 8192,
                                                   dependencies: noOllama) == .capacityRefused(.factsUnavailable))
        let blind = World()
        blind.residentInOllama(gemmaLike, context: 8192)
        let blindDeps = lmStudioDependencies(blind, ollama: ModelManager.OllamaCapacityDependencies(
            installedModels: { nil }, residentModels: { nil }, kvCacheBytes: { _, _ in nil },
            ensureLoaded: { _, _, _ in true }, unload: { _ in }))
        reporter.record("an unreadable /api/ps refuses an Ollama request (fail closed)",
                        ModelManager().ensureReady(ref(.ollama, gemmaLike), dependencies: blindDeps)
                            == .capacityRefused(.factsUnavailable))
        reporter.record("an unreadable Ollama never refuses an LM Studio request it has no part in",
                        ModelManager().ensureReady(lmIncoming, ttlOverrideSeconds: ttl, dependencies: blindDeps)
                            == .ready)
    }

    // MARK: - LM Studio only: today's decisions, byte for byte

    /// `ModelCapacitySelfTest`'s scenarios with that file's expected values written out (not re-derived from
    /// this slice's code), run through the String API with no Ollama facts and through the ref API with a
    /// scripted Ollama present, which must not be asked anything.
    private static func checkLMStudioOnlyMatchesToday(_ reporter: SelfTestReporter) {
        print("--- LM-Studio-only decisions equal ModelCapacitySelfTest's ---")
        for viaRef in [false, true] {
            let arm = viaRef ? "ref API, Ollama present" : "String API, no Ollama"
            let world = World()   // its Ollama side holds a foreign model and must see zero requests
            world.residentInOllama(foreign, context: 8192)
            let ollama: ModelManager.OllamaCapacityDependencies? =
                viaRef ? .backed(by: ollamaBackend(world)) : nil
            world.ollamaRequests.removeAll()

            func ready(_ policy: ModelManager, _ model: String,
                       _ deps: ModelManager.CapacityDependencies) -> ModelManager.ReadinessResult {
                viaRef ? policy.ensureReady(ref(.lmStudio, model), ttlOverrideSeconds: 600, dependencies: deps)
                    : policy.ensureReady(model, ttlOverrideSeconds: 600, dependencies: deps)
            }
            func installed(_ id: String, _ size: Int64?) -> LMStudioInstalledModel {
                .init(modelID: id, label: id, type: "llm", sizeBytes: size, visionFlag: false)
            }
            func row(_ id: String, _ size: UInt64, _ last: UInt64?, _ status: String) -> ModelResidency.ResidentModel {
                .init(identifier: id, sizeBytes: size, lastUsedTime: last, status: status)
            }

            // ownershipAndEvictionChecks
            do {
                let policy = ModelManager()
                var residents: [ModelResidency.ResidentModel] = [row("foreign/huge", 900, 1, "idle")]
                var unloads: [String] = []
                var loads: [String] = []
                let catalog = [installed("foreign/huge", 900), installed("owned/old", 10), installed("owned/new", 10),
                               installed("owned/busy", 10), installed("incoming", 100)]
                var wiredReads = 0
                var wired: () -> UInt64 = { 0 }
                let deps = ModelManager.CapacityDependencies(
                    availableInstalledModels: { catalog }, residentModels: { residents },
                    wiredBytes: { wired() }, budgetBytes: { _ in 1_000 },
                    ensureLoaded: { model, _ in
                        loads.append(model)
                        let last: UInt64 = ["owned/old": 20, "owned/new": 30, "owned/busy": 10, "incoming": 40][model] ?? 1
                        residents.append(row(model, 10, last, "idle"))
                        return true
                    },
                    unload: { model in unloads.append(model); residents.removeAll { $0.identifier == model } },
                    log: { _ in }, ollama: ollama)
                let foreignReuse = ready(policy, "foreign/huge", deps)
                let reuseLoads = loads
                for owned in ["owned/old", "owned/new", "owned/busy"] { _ = ready(policy, owned, deps) }
                residents = residents.map {
                    $0.identifier == "owned/busy" ? row($0.identifier, $0.sizeBytes, $0.lastUsedTime, "loading") : $0
                }
                loads.removeAll()
                wired = { wiredReads += 1; return wiredReads == 1 ? 900 : 700 }
                let incoming = ready(policy, "incoming", deps)
                reporter.record("[\(arm)] ownership + eviction: foreign reuse loads nothing; unloads [owned/old, "
                                    + "owned/new]; foreign and busy survive; two wired reads; incoming loads",
                                foreignReuse == .ready && reuseLoads.isEmpty
                                    && unloads == ["owned/old", "owned/new"]
                                    && residents.contains { $0.identifier == "foreign/huge" }
                                    && residents.contains { $0.identifier == "owned/busy" }
                                    && incoming == .ready && wiredReads == 2 && loads == ["incoming"],
                                "unloads=\(unloads) loads=\(loads) wiredReads=\(wiredReads)")
            }

            // missingRecencyEvictionChecks
            do {
                let policy = ModelManager()
                var residents: [ModelResidency.ResidentModel] = []
                var unloads: [String] = []
                var wired: UInt64 = 0
                let catalog = ["owned/missing-recency", "owned/older", "owned/generating", "incoming"]
                    .map { installed($0, 100) }
                let deps = ModelManager.CapacityDependencies(
                    availableInstalledModels: { catalog }, residentModels: { residents },
                    wiredBytes: { wired }, budgetBytes: { _ in 250 },
                    ensureLoaded: { model, _ in
                        residents.append(row(model, 100, model == "owned/older" ? 10 : nil,
                                             model == "owned/generating" ? "generating" : "idle"))
                        return true
                    },
                    unload: { model in unloads.append(model); residents.removeAll { $0.identifier == model }; wired = 0 },
                    log: { _ in }, ollama: ollama)
                for owned in ["owned/missing-recency", "owned/older", "owned/generating"] { _ = ready(policy, owned, deps) }
                wired = 300
                let incoming = ready(policy, "incoming", deps)
                reporter.record("[\(arm)] missing recency sorts after a known older model; generating is kept",
                                unloads == ["owned/older", "owned/missing-recency"] && incoming == .ready
                                    && residents.contains { $0.identifier == "owned/generating" },
                                "unloads=\(unloads) result=\(incoming)")
            }

            // onePassCheck
            do {
                let policy = ModelManager()
                var residents: [ModelResidency.ResidentModel] = []
                var unloads: [String] = []
                var loads: [String] = []
                var residentReads = 0
                var wiredReads = 0
                let catalog = [installed("owned", 10), installed("incoming", 100)]
                let setup = ModelManager.CapacityDependencies(
                    availableInstalledModels: { catalog }, residentModels: { residents },
                    wiredBytes: { 0 }, budgetBytes: { _ in 1_000 },
                    ensureLoaded: { model, _ in residents.append(row(model, 10, 1, "idle")); return true },
                    unload: { _ in }, log: { _ in }, ollama: ollama)
                _ = ready(policy, "owned", setup)
                let blocked = ModelManager.CapacityDependencies(
                    availableInstalledModels: { catalog },
                    residentModels: { residentReads += 1; return residents },
                    wiredBytes: { wiredReads += 1; return 950 }, budgetBytes: { _ in 1_000 },
                    ensureLoaded: { model, _ in loads.append(model); return true },
                    unload: { unloads.append($0) }, log: { _ in }, ollama: ollama)
                let outcome = ready(policy, "incoming", blocked)
                reporter.record("[\(arm)] one pass: over budget after one snapshot and two wired reads, owned "
                                    + "unloaded once, incoming never loaded",
                                outcome == .capacityRefused(.overBudget) && residentReads == 1 && wiredReads == 2
                                    && unloads == ["owned"] && loads.isEmpty,
                                "outcome=\(outcome) residentReads=\(residentReads) wiredReads=\(wiredReads)")
            }

            // residentBypassLoggingChecks + factorAndMissingFactChecks
            do {
                var logs: [String] = []
                var reads = 0
                let deps = ModelManager.CapacityDependencies(
                    availableInstalledModels: { reads += 1; return nil },
                    residentModels: { [row("fixture/already-resident", 1_200_000_000, 1, "idle")] },
                    wiredBytes: { reads += 1; return nil }, budgetBytes: { _ in 1_000_000_000 },
                    ensureLoaded: { _, _ in true }, unload: { _ in }, log: { logs.append($0) }, ollama: ollama)
                let bypass = ready(ModelManager(), "fixture/already-resident", deps)
                reporter.record("[\(arm)] resident bypass: ready with no catalog or wired read, and the exact log line",
                                bypass == .ready && reads == 0 && logs == [
                                    "model capacity: fixture/already-resident is already resident at 1.2 GB, "
                                        + "above the current 1.0 GB budget; reusing it because this request "
                                        + "allocates no new model memory",
                                ], "logs=\(logs)")

                func result(installed list: [LMStudioInstalledModel]? = [installed("incoming", 100)],
                            residents: [ModelResidency.ResidentModel]? = [], wired: UInt64? = 10,
                            budget: UInt64? = 1_000, loads: Bool = true) -> ModelManager.ReadinessResult {
                    ready(ModelManager(), "incoming", ModelManager.CapacityDependencies(
                        availableInstalledModels: { list }, residentModels: { residents },
                        wiredBytes: { wired }, budgetBytes: { _ in budget },
                        ensureLoaded: { _, _ in loads }, unload: { _ in }, log: { _ in }, ollama: ollama))
                }
                reporter.record("[\(arm)] every missing fact refuses softly; a load failure stays distinct",
                                result(residents: nil) == .capacityRefused(.factsUnavailable)
                                    && result(installed: nil) == .capacityRefused(.factsUnavailable)
                                    && result(installed: [installed("incoming", nil)]) == .capacityRefused(.factsUnavailable)
                                    && result(wired: nil) == .capacityRefused(.factsUnavailable)
                                    && result(budget: nil) == .capacityRefused(.factsUnavailable)
                                    && result(loads: false) == .loadFailed
                                    && result() == .ready)
            }

            reporter.record("[\(arm)] Ollama was asked nothing", world.ollamaRequests.isEmpty,
                            "requests=\(world.ollamaRequests.map(\.path))")
        }
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) The estimate sized from /api/ps: the catalog rows carry ps's size instead of tags'.
        let psSized: DependencyFactory = { world in
            let real = ModelManager.OllamaCapacityDependencies.backed(by: ollamaBackend(world))
            let mutant = ModelManager.OllamaCapacityDependencies(
                installedModels: {
                    real.installedModels()?.map { model in
                        LocalInstalledModel(
                            ref: model.ref, label: model.label,
                            sizeBytes: ollamaCatalog[model.ref.modelID].map { Int64($0.psSize) } ?? model.sizeBytes,
                            isVision: model.isVision, supportsTools: model.supportsTools,
                            supportsThinking: model.supportsThinking)
                    }
                },
                residentModels: real.residentModels, kvCacheBytes: real.kvCacheBytes,
                ensureLoaded: real.ensureLoaded, unload: real.unload)
            return lmStudioDependencies(world, ollama: mutant)
        }
        requireCaught(reporter, mutant: "Ollama estimate sized from /api/ps", by: estimateCheck) {
            checkContract(psSized, $0)
        }

        // (b) Eviction keyed by id alone: unloading an evicted model unloads that id in both apps.
        let idOnly: DependencyFactory = { world in
            let backend = ollamaBackend(world)
            let real = realDependencies(world)
            let realOllama = ModelManager.OllamaCapacityDependencies.backed(by: backend)
            return ModelManager.CapacityDependencies(
                availableInstalledModels: real.availableInstalledModels, residentModels: real.residentModels,
                wiredBytes: real.wiredBytes, budgetBytes: real.budgetBytes, ensureLoaded: real.ensureLoaded,
                unload: { id in real.unload(id); backend.unload(LocalModelRef(backend: .ollama, modelID: id)) },
                log: { _ in },
                ollama: ModelManager.OllamaCapacityDependencies(
                    installedModels: realOllama.installedModels, residentModels: realOllama.residentModels,
                    kvCacheBytes: realOllama.kvCacheBytes, ensureLoaded: realOllama.ensureLoaded,
                    unload: { ref in realOllama.unload(ref); real.unload(ref.modelID) }))
        }
        requireCaught(reporter, mutant: "eviction keyed by model id alone", by: sameIDCheck) {
            checkContract(idOnly, $0)
        }

        // (c) Blind to the resident context: ps's context is dropped and every load is unconditional.
        let alwaysReloads: DependencyFactory = { world in
            let backend = ollamaBackend(world)
            let real = ModelManager.OllamaCapacityDependencies.backed(by: backend)
            let mutant = ModelManager.OllamaCapacityDependencies(
                installedModels: real.installedModels,
                residentModels: {
                    real.residentModels()?.map {
                        LocalResidentModel(ref: $0.ref, residentBytes: $0.residentBytes, lastUsed: $0.lastUsed,
                                           isIdle: $0.isIdle, expiresAt: $0.expiresAt, contextLength: nil)
                    }
                },
                kvCacheBytes: real.kvCacheBytes,
                ensureLoaded: { backend.load($0, ttlSeconds: $1, contextTokens: $2) },
                unload: real.unload)
            return lmStudioDependencies(world, ollama: mutant)
        }
        requireCaught(reporter, mutant: "policy that reloads even a larger resident context", by: reuseCheck) {
            checkContract(alwaysReloads, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
