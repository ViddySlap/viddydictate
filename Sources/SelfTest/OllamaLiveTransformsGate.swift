import Foundation

/// `--ollama-transforms-live` (services): one real cleanup and one real email through `gemma4:e4b` on the
/// real Ollama, through the shipped clients and the live `LocalChatTransport` (ModelManager readiness, the
/// translator, native `/api/chat`), with the idle window overridden to 20 s. It asserts both answers are
/// non-empty and carry no `<think>` text, then that the model leaves `/api/ps` on its own once the window
/// has passed: the keep_alive the requests carried is what unloads it.
///
/// Abstains (exit 0, `[skip] ... SKIPPED`, the shape `run_service_gate` reads) exactly when the apparatus
/// is missing: a managed sandbox, no Ollama installed, a server that does not answer, or no `gemma4:e4b`.
/// It also abstains when `gemma4:e4b` is already resident, because its 20 s window would cut short a
/// model someone else loaded; and when the capacity guard refuses the load, which is the guard working,
/// not a transform failing. Every claim about a model it did run is blocking.
enum OllamaLiveTransformsGate {
    private static let tag = "[ollama-transforms-live]"
    private static let model = "gemma4:e4b"
    private static let ttlSeconds = 20
    /// Past the window, Ollama's scheduler checks expiry on its own timer; the probe saw release within 1 s.
    private static let unloadGraceSeconds: TimeInterval = 20

    static func run() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_SANDBOX"]?.isEmpty == false
            || environment["CODEX_PERMISSION_PROFILE"]?.isEmpty == false {
            print("\(tag) [skip] SKIPPED: managed sandbox denies live Ollama access")
            return true
        }
        let backend = OllamaBackend.shared
        guard backend.isInstalled() else {
            print("\(tag) [skip] SKIPPED: Ollama is not installed (no Ollama.app, no ollama CLI)")
            return true
        }
        guard backend.serverResponds() else {
            print("\(tag) [skip] SKIPPED: Ollama is installed but \(backend.baseURL.absoluteString) is not answering")
            return true
        }
        guard let models = backend.installedModels() else {
            print("\(tag) FAIL: answering Ollama did not produce a parseable catalog")
            return false
        }
        let wanted = OllamaBackend.canonicalModelName(model)
        guard models.contains(where: { OllamaBackend.canonicalModelName($0.ref.modelID) == wanted }) else {
            print("\(tag) [skip] SKIPPED: \(model) is not pulled in Ollama")
            return true
        }
        guard let before = backend.residentModels() else {
            print("\(tag) FAIL: answering Ollama did not produce a readable /api/ps")
            return false
        }
        if before.contains(where: { OllamaBackend.canonicalModelName($0.ref.modelID) == wanted }) {
            print("\(tag) [skip] SKIPPED: \(model) is already resident; a 20 s window would cut short a model "
                  + "this gate did not load")
            return true
        }

        let transport = LocalChatTransport.live(keepAliveOverride: ttlSeconds)
        var passed = true

        let cleanup = wait { done in
            CleanupClient.cleanup(
                "so um the meeting is moved to thursday at three and uh bring the slides",
                timeout: 180, model: model, backend: .ollama, systemPrompt: Settings.cleanupPrompt(.cleanup),
                surface: .cleanup, transport: transport, completion: done)
        }
        if case .unavailable(let reason) = cleanup,
           reason == CleanupClient.overBudgetMessage || reason == CleanupClient.memoryFactsUnavailableMessage {
            print("\(tag) [skip] SKIPPED: the capacity guard refused \(model) (\(reason))")
            return true
        }
        passed = check("cleanup", cleanup) && passed

        let email = wait { done in
            EmailClient.email(
                "notes: thank the team for the launch, ask for feedback by friday, sign off as Sam",
                timeout: 240, model: model, backend: .ollama, transport: transport, completion: done)
        }
        passed = check("email", email) && passed

        let deadline = Date().addingTimeInterval(TimeInterval(ttlSeconds) + unloadGraceSeconds)
        var stillResident = true
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            guard let resident = backend.residentModels() else { continue }
            stillResident = resident.contains { OllamaBackend.canonicalModelName($0.ref.modelID) == wanted }
            if !stillResident { break }
        }
        if stillResident {
            print("\(tag) FAIL: \(model) is still in /api/ps \(Int(TimeInterval(ttlSeconds) + unloadGraceSeconds)) s "
                  + "after the last request; keep_alive \(ttlSeconds) did not govern it")
            backend.unload(LocalModelRef(backend: .ollama, modelID: model))
            passed = false
        } else {
            print("\(tag) ok: \(model) unloaded on its own after the \(ttlSeconds) s window")
        }
        print(passed ? "\(tag) PASS" : "\(tag) FAIL")
        return passed
    }

    private static func wait(_ body: (@escaping (CleanupClient.Result) -> Void) -> Void) -> CleanupClient.Result {
        let done = DispatchSemaphore(value: 0)
        var result: CleanupClient.Result = .unavailable("no result")
        body { result = $0; done.signal() }
        _ = done.wait(timeout: .now() + 400)
        return result
    }

    private static func check(_ surface: String, _ result: CleanupClient.Result) -> Bool {
        guard case .ok(let text) = result else {
            print("\(tag) FAIL: \(surface) on \(model) returned \(result)")
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().contains("<think") else {
            print("\(tag) FAIL: \(surface) on \(model) was empty or carried <think> text")
            return false
        }
        print("\(tag) ok: \(surface) returned \(trimmed.count) characters, no <think> text")
        return true
    }
}
