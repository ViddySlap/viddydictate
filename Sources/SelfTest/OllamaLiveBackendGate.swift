import Foundation

/// G9 (`--ollama-live`, services): the real `OllamaBackend` against the real Ollama on this Mac. It is the
/// only gate that can see provider drift in the native API (tags/show/ps shapes, `keep_alive` semantics,
/// the load-without-generating path), which every scripted fixture is blind to by construction.
///
/// Abstains (exit 0, `[skip] ... SKIPPED`, the shape `run_service_gate` reads) exactly when the apparatus
/// is missing: a managed sandbox, no Ollama installed, a server that does not answer, no usable model, or
/// every usable model already resident. Every claim about a server that DID answer is blocking.
///
/// It only ever loads and unloads a model that was NOT resident when it started, so it cannot evict a
/// model another app (or the user) loaded. Other resident models must still be resident after the unload.
/// The wired-memory reading around the load is printed for the capacity slice's measurement, never asserted.
enum OllamaLiveBackendGate {
    private static let tag = "[ollama-live]"
    private static let ttlSeconds = 20
    private static let contextTokens = 4096

    static func run() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_SANDBOX"]?.isEmpty == false
            || environment["CODEX_PERMISSION_PROFILE"]?.isEmpty == false {
            print("\(tag) [skip] SKIPPED: managed sandbox denies live Ollama access")
            return true
        }

        let backend = OllamaBackend()
        guard let kind = backend.installKind else {
            print("\(tag) [skip] SKIPPED: Ollama is not installed (no Ollama.app, no ollama CLI)")
            return true
        }
        guard backend.serverResponds() else {
            print("\(tag) [skip] SKIPPED: Ollama (\(kind.rawValue)) is installed but \(backend.baseURL.absoluteString) "
                  + "is not answering /api/version")
            return true
        }
        print("\(tag) server: \(backend.baseURL.absoluteString) (\(kind.rawValue) install)")

        guard let models = backend.installedModels() else {
            print("\(tag) FAIL: answering Ollama did not produce a parseable catalog (tags/show)")
            return false
        }
        guard !models.isEmpty else {
            print("\(tag) [skip] SKIPPED: Ollama reports no usable local chat models")
            return true
        }
        let names = models.map(\.ref.modelID)
        guard names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(names).count == names.count else {
            print("\(tag) FAIL: the catalog contains blank or duplicate model names")
            return false
        }
        guard !names.contains(where: OllamaCatalog.isCloudName) else {
            print("\(tag) FAIL: a cloud model reached the Local catalog: "
                  + names.filter(OllamaCatalog.isCloudName).joined(separator: ", "))
            return false
        }
        print("\(tag) catalog: \(models.count) usable model(s): \(names.joined(separator: ", "))")

        guard let before = backend.residentModels() else {
            print("\(tag) FAIL: answering Ollama did not produce a parseable /api/ps")
            return false
        }
        let residentBefore = Set(before.map { OllamaBackend.canonicalModelName($0.ref.modelID) })
        let candidates = models.filter { !residentBefore.contains(OllamaBackend.canonicalModelName($0.ref.modelID)) }
        guard let target = pickTarget(candidates) else {
            print("\(tag) [skip] SKIPPED load/unload: every usable model is already resident, and this gate "
                  + "never unloads a model it did not load")
            print("\(tag) PASS: catalog checks only")
            return true
        }
        let wasResident = residentBefore.contains(OllamaBackend.canonicalModelName(target.ref.modelID))
        let foreign = before.filter {
            OllamaBackend.canonicalModelName($0.ref.modelID) != OllamaBackend.canonicalModelName(target.ref.modelID)
        }
        print("\(tag) target: \(target.ref.modelID) (\(target.sizeBytes.map(WiredReading.gb) ?? "size unknown"), "
              + "vision=\(target.isVision), resident before=\(wasResident)); foreign resident: "
              + (foreign.isEmpty ? "none" : foreign.map(\.ref.modelID).joined(separator: ", ")))

        let wiredBefore = SystemMemory.wiredBytes
        let loadStarted = Date()
        let loaded = backend.ensureLoaded(target.ref, ttlSeconds: ttlSeconds, contextTokens: contextTokens)
        var passed = true
        defer {
            // Never leave the gate's own model behind, whatever failed above.
            if loaded { backend.unload(target.ref) }
        }
        guard loaded else {
            print("\(tag) FAIL: ensureLoaded(\(target.ref.modelID), ttl \(ttlSeconds), ctx \(contextTokens)) returned false")
            return false
        }
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        let wiredAfter = SystemMemory.wiredBytes

        guard let afterLoad = backend.residentModels(),
              let row = afterLoad.first(where: { same($0.ref.modelID, target.ref.modelID) }) else {
            print("\(tag) FAIL: \(target.ref.modelID) is not in /api/ps after a successful ensureLoaded")
            return false
        }
        let expected = Date().addingTimeInterval(TimeInterval(ttlSeconds))
        if let expiresAt = row.expiresAt, abs(expiresAt.timeIntervalSince(expected)) <= 10 {
            print("\(tag) ok: resident, expires_at is now + \(Int(expiresAt.timeIntervalSinceNow.rounded())) s "
                  + "(keep_alive \(ttlSeconds) s reached the wire)")
        } else {
            print("\(tag) FAIL: expires_at \(row.expiresAt.map { "\($0)" } ?? "absent") is not now + \(ttlSeconds) s ± 10 s; "
                  + "keep_alive did not reach the wire")
            passed = false
        }
        print("\(tag) info: loaded in \(String(format: "%.1f", loadSeconds)) s; resident bytes (tags size) "
              + "\(WiredReading.gb(Int64(clamping: row.residentBytes))), context_length "
              + "\(row.contextLength.map(String.init) ?? "unreported") (requested \(contextTokens))")
        print("\(tag) info: wired before \(WiredReading.text(wiredBefore)), after load "
              + "\(WiredReading.text(wiredAfter)), delta \(WiredReading.delta(wiredBefore, wiredAfter))")
        let evictedByOllama = foreign.filter { model in !afterLoad.contains { same($0.ref.modelID, model.ref.modelID) } }
        if !evictedByOllama.isEmpty {
            // Ollama's own scheduler may make room (OLLAMA_MAX_LOADED_MODELS, memory). That is its policy,
            // not our unload, so it is reported rather than failed.
            print("\(tag) note: Ollama itself unloaded \(evictedByOllama.map(\.ref.modelID).joined(separator: ", ")) "
                  + "to make room for the load")
        }

        backend.unload(target.ref)
        let unloadStarted = Date()
        var afterUnload: [LocalResidentModel]?
        var gone = false
        while Date().timeIntervalSince(unloadStarted) < 5 {
            afterUnload = backend.residentModels()
            if let snapshot = afterUnload, !snapshot.contains(where: { same($0.ref.modelID, target.ref.modelID) }) {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if gone {
            print("\(tag) ok: \(target.ref.modelID) left /api/ps "
                  + "\(String(format: "%.2f", Date().timeIntervalSince(unloadStarted))) s after unload")
        } else {
            print("\(tag) FAIL: \(target.ref.modelID) is still in /api/ps 5 s after unload (keep_alive 0)")
            passed = false
        }

        // Foreign-model safety: whatever was resident after the load and was not ours is still resident
        // after our unload. A foreign model whose own expiry fell inside the test window may leave on its
        // own; that is reported, not failed.
        let unloadEnded = Date()
        for model in foreign where afterLoad.contains(where: { same($0.ref.modelID, model.ref.modelID) }) {
            let stillThere = afterUnload?.contains { same($0.ref.modelID, model.ref.modelID) } ?? false
            if stillThere { continue }
            if let expiry = model.expiresAt, expiry <= unloadEnded {
                print("\(tag) note: foreign \(model.ref.modelID) expired on its own schedule during the test")
                continue
            }
            print("\(tag) FAIL: foreign model \(model.ref.modelID) was resident before the unload and is gone after it")
            passed = false
        }

        print(passed
            ? "\(tag) PASS: catalog, keep_alive load, unload and foreign-model safety against a live Ollama"
            : "\(tag) FAIL")
        return passed
    }

    /// The smallest usable model that is not vision-capable (the cheapest completion model to load), else
    /// the smallest of all. An unknown size sorts last, so a model that reported one is preferred.
    private static func pickTarget(_ models: [LocalInstalledModel]) -> LocalInstalledModel? {
        func smallest(_ list: [LocalInstalledModel]) -> LocalInstalledModel? {
            list.min { ($0.sizeBytes ?? Int64.max) < ($1.sizeBytes ?? Int64.max) }
        }
        return smallest(models.filter { !$0.isVision }) ?? smallest(models)
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        OllamaBackend.canonicalModelName(lhs) == OllamaBackend.canonicalModelName(rhs)
    }

    /// Informational formatting for the wired-memory measurement (spec section 4's open question).
    private enum WiredReading {
        static func gb(_ bytes: Int64) -> String {
            SystemMemory.formatGB(UInt64(max(0, bytes)))
        }

        static func text(_ bytes: UInt64?) -> String {
            bytes.map(SystemMemory.formatGB) ?? "unavailable"
        }

        static func delta(_ before: UInt64?, _ after: UInt64?) -> String {
            guard let before, let after else { return "unavailable" }
            let sign = after >= before ? "+" : "-"
            return sign + SystemMemory.formatGB(after >= before ? after - before : before - after)
        }
    }
}
