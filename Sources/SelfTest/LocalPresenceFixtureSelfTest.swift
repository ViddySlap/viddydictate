import Foundation

/// G6 (`--local-presence-selftest`): the ONE `.local` presence merged from every local app, the pinned-app
/// start (spec D2 step 1), and the Preferred-local-app rule (D3).
///
/// Real code throughout: `LLMProviderDetection.observeLocal` over the real `LMStudioBackend` (injected
/// dependencies standing in for `lms`) and the real `OllamaBackend` (a scripted transport standing in for
/// its HTTP server and the install paths). The app launch is a RECORDER: it only flips the scripted Ollama
/// to answering, so this gate can never open anything. The poll runs on a fake clock that each sleep
/// advances, so a server that never comes up still ends inside the bound.
///
/// The LM-Studio-only arm compares against 1.1.0's own path on the same `lms ls` fixture:
/// `LMStudioModelCatalog.parse` for the catalog (what `ModelResidency.availableModels()` returned) and the
/// untouched single-app `localState` for the state, so the expectation is never this slice's code.
///
/// Negative controls: the contract is re-run against three broken variants, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) presence that observes LM Studio only;
/// (b) a start policy that also opens a CLI-only (Homebrew) Ollama;
/// (c) a Preferred-app rule that ignores what is installed.
enum LocalPresenceFixtureSelfTest {
    private static let ollamaAppPath = "/Applications/Ollama.app"
    private static let ollamaCLIPath = "/opt/homebrew/bin/ollama"
    private static let ollamaChat = "ollama-presence-fixture-chat:latest"
    private static let ollamaSecond = "ollama-presence-fixture-second:7b"

    /// An `lms ls --llm --json` body: two `llm` rows (one also flagged vision) and one `vlm` row, which
    /// 1.1.0's text catalog excludes.
    private static let lmStudioCatalogJSON = """
    [
      {"type":"llm","modelKey":"lmstudio-presence-fixture-chat","displayName":"Presence Chat","sizeBytes":4250000000},
      {"type":"vlm","modelKey":"lmstudio-presence-fixture-vlm","displayName":"Presence VLM","sizeBytes":1100000000},
      {"type":"llm","modelKey":"lmstudio-presence-fixture-seeing","displayName":"Presence Seeing","vision":true}
    ]
    """

    private static let ollamaTags = """
    {"models":[
      {"name":"\(ollamaChat)","model":"\(ollamaChat)","size":3338000000,"digest":"presence-digest-chat",
       "capabilities":["completion","tools"]},
      {"name":"\(ollamaSecond)","model":"\(ollamaSecond)","size":4700000000,"digest":"presence-digest-second",
       "capabilities":["completion"]},
      {"name":"ollama-presence-fixture-remote:cloud","size":384,"remote_host":"https://ollama.com:443"}
    ]}
    """

    // MARK: - Scripted apps

    /// LM Studio as the adapter sees it through `lms`.
    private struct LMStudioScript {
        var installed = true
        var running = true
        /// nil models a catalog read that failed while the server answered.
        var catalogJSON: String? = LocalPresenceFixtureSelfTest.lmStudioCatalogJSON

        func backend() -> LMStudioBackend {
            let script = self
            return LMStudioBackend(dependencies: .init(
                isInstalled: { script.installed },
                serverResponds: { script.running },
                installedCatalog: {
                    guard script.running, let json = script.catalogJSON else { return nil }
                    return LMStudioModelCatalog.parseInstalled(Data(json.utf8))
                },
                residentSnapshot: { [] },
                ensureLoaded: { _, _ in false },
                unload: { _ in }))
        }
    }

    /// Ollama's server and install paths. `up` flips when the recorder "launches" the app.
    private final class OllamaScript {
        var kind: OllamaInstallKind?
        var up: Bool
        /// Whether a launch brings the server up (false: a first-run app waiting on its macOS prompt).
        var launchStartsServer = true
        private(set) var events: [String] = []

        init(kind: OllamaInstallKind?, up: Bool) {
            self.kind = kind
            self.up = up
        }

        func launched(_ path: String) {
            events.append("launch \(path)")
            if launchStartsServer { up = true }
        }

        var launchCount: Int { events.filter { $0.hasPrefix("launch") }.count }

        func backend() -> OllamaBackend {
            OllamaBackend(
                transport: OllamaBackend.Transport(
                    send: { request, _ in self.serve(request) },
                    pathStatus: { path in self.pathStatus(path) }),
                environment: [:], homeDirectory: "/presence-fixture-home")
        }

        private func pathStatus(_ path: String) -> OllamaBackend.PathStatus {
            switch (kind, path) {
            case (.app?, LocalPresenceFixtureSelfTest.ollamaAppPath):
                return OllamaBackend.PathStatus(exists: true, isDirectory: true, isExecutable: true)
            case (.cli?, LocalPresenceFixtureSelfTest.ollamaCLIPath):
                return OllamaBackend.PathStatus(exists: true, isDirectory: false, isExecutable: true)
            default:
                return .missing
            }
        }

        private func serve(_ request: URLRequest) -> (Data?, HTTPURLResponse?, Error?) {
            let path = request.url?.path ?? ""
            events.append("\(path) \(up ? "up" : "down")")
            guard up, let url = request.url else {
                return (nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
            }
            let body: String
            switch path {
            case "/api/version": body = "{\"version\":\"0.35.0\"}"
            case "/api/tags": body = LocalPresenceFixtureSelfTest.ollamaTags
            default: body = "{\"error\":\"not scripted\"}"
            }
            let status = path == "/api/version" || path == "/api/tags" ? 200 : 404
            return (Data(body.utf8),
                    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil),
                    nil)
        }
    }

    /// A starter whose launch is `script`'s recorder and whose clock only moves when it sleeps.
    private static func starter(_ script: OllamaScript, pinned: Set<LocalBackendID> = [],
                                preferred: LocalBackendID? = nil) -> LLMProviderDetection.LocalBackendStarter {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        return LLMProviderDetection.LocalBackendStarter(
            pinnedBackends: pinned, preferredExplicit: preferred,
            launch: { script.launched($0) },
            pollTimeout: LLMProviderDetection.LocalBackendStarter.defaultPollTimeout,
            pollInterval: LLMProviderDetection.LocalBackendStarter.defaultPollInterval,
            now: { clock }, sleep: { clock = clock.addingTimeInterval($0) })
    }

    // MARK: - The seams the mutants replace

    private typealias ObserveSubject =
        ([LocalModelBackend], LLMProviderDetection.LocalBackendStarter) -> LLMProviderDetection.LocalObservation
    private typealias PreferenceSubject = (LocalBackendID?, Set<LocalBackendID>) -> LocalBackendID

    private static let realObserve: ObserveSubject = { LLMProviderDetection.observeLocal(backends: $0, starter: $1) }
    private static let realPreference: PreferenceSubject = {
        LocalBackendPreference.effective(explicit: $0, installed: $1)
    }

    // Assertion names the negative controls look up.
    private static let ollamaOnlyCheck =
        "only Ollama running, LM Studio absent: .local is available with Ollama's models, tagged Ollama"
    private static let cliNotStartedCheck = "a CLI-only Ollama that is not running is never started, even when pinned"
    private static let preferenceCheck = "automatic with only Ollama installed prefers Ollama"

    static func run() -> Bool {
        print("=== local presence fixture selftest (merged .local, pinned-app start, preferred app) ===")
        let reporter = SelfTestReporter()

        print("--- contract (real observeLocal and LocalBackendPreference) ---")
        checkContract(observe: realObserve, preference: realPreference, reporter)
        checkLMStudioOnlyMatches110(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[local-presence-selftest] PASS"
            : "[local-presence-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(observe: ObserveSubject, preference: PreferenceSubject,
                                      _ reporter: SelfTestReporter) {
        let noLMStudio = LMStudioScript(installed: false, running: false)

        // Only Ollama, running.
        let ollamaUp = OllamaScript(kind: .app, up: true)
        let onlyOllama = observe([noLMStudio.backend(), ollamaUp.backend()], .never).presence
        let tagged = onlyOllama.availableLocalModels ?? []
        reporter.record(
            ollamaOnlyCheck,
            onlyOllama.state == .available && onlyOllama.installed
                && tagged.map(\.modelID) == [ollamaChat, ollamaSecond]
                && tagged.allSatisfy { $0.backend == .ollama },
            "state=\(onlyOllama.state) models=\(tagged.map { "\($0.backend.rawValue):\($0.modelID)" })")

        // Both apps running: one merged list, LM Studio's first, each in its own order.
        let both = observe([LMStudioScript().backend(), OllamaScript(kind: .app, up: true).backend()], .never)
        let merged = (both.presence.availableLocalModels ?? []).map { "\($0.backend.rawValue):\($0.modelID)" }
        reporter.record(
            "both running: one catalog, LM Studio's models then Ollama's, each in its own order",
            merged == ["lmStudio:lmstudio-presence-fixture-chat", "lmStudio:lmstudio-presence-fixture-seeing",
                       "ollama:\(ollamaChat)", "ollama:\(ollamaSecond)"]
                && both.models == both.presence.availableLocalModels,
            "\(merged)")

        // Neither installed.
        let neither = observe([noLMStudio.backend(), OllamaScript(kind: nil, up: false).backend()], .never).presence
        var neitherReason = ""
        if case .unavailable(let why) = neither.state { neitherReason = why }
        reporter.record("neither app installed: the reason names both apps",
                        !neither.installed && neitherReason.contains("LM Studio") && neitherReason.contains("Ollama"),
                        neitherReason)

        // An Ollama app, installed but stopped, and pinned: one launch, by path, then the re-probe.
        let stopped = OllamaScript(kind: .app, up: false)
        let started = observe([noLMStudio.backend(), stopped.backend()],
                              starter(stopped, pinned: [.ollama])).presence
        let launchIndex = stopped.events.firstIndex(of: "launch \(ollamaAppPath)")
        let reprobed = launchIndex.map { i in stopped.events[(i + 1)...].contains("/api/tags up") } ?? false
        reporter.record(
            "a pinned Ollama app that is not running is opened exactly once, by path, then re-probed",
            stopped.launchCount == 1 && launchIndex != nil && reprobed && started.state == .available
                && (started.availableLocalModels ?? []).map(\.modelID) == [ollamaChat, ollamaSecond],
            "events=\(stopped.events)")

        // Automatic preference: the only installed app is the Preferred one, so it is started unpinned.
        let preferredOnly = OllamaScript(kind: .app, up: false)
        _ = observe([noLMStudio.backend(), preferredOnly.backend()], starter(preferredOnly))
        reporter.record("the only installed app is the automatic Preferred app and is started with no pin",
                        preferredOnly.launchCount == 1, "events=\(preferredOnly.events)")

        // Not pinned, not preferred (LM Studio is installed too, so automatic is LM Studio): left alone.
        let bystander = OllamaScript(kind: .app, up: false)
        let leftAlone = observe([LMStudioScript().backend(), bystander.backend()], starter(bystander)).presence
        reporter.record("an Ollama app that is neither pinned nor preferred is not started",
                        bystander.launchCount == 0 && leftAlone.state == .available,
                        "events=\(bystander.events)")

        // A first-run app waiting on its macOS prompt: one launch, a bounded wait, then guidance.
        let prompting = OllamaScript(kind: .app, up: false)
        prompting.launchStartsServer = false
        let stuck = observe([noLMStudio.backend(), prompting.backend()],
                            starter(prompting, pinned: [.ollama])).presence
        let polls = prompting.events.filter { $0 == "/api/version down" }.count
        reporter.record(
            "an app that does not come up is launched once, polled within the bound, and the user is told what to do",
            prompting.launchCount == 1 && polls >= 2 && polls <= 22
                && stuck.state == .unavailable(LLMProviderDetection.ollamaDidNotStartReason),
            "polls=\(polls) state=\(stuck.state)")

        // A Homebrew CLI install is a daemon the user owns.
        let cli = OllamaScript(kind: .cli, up: false)
        let cliPresence = observe([noLMStudio.backend(), cli.backend()],
                                  starter(cli, pinned: [.ollama], preferred: .ollama)).presence
        reporter.record(cliNotStartedCheck, cli.launchCount == 0, "events=\(cli.events)")
        reporter.record("a CLI-only Ollama that is not running says so, and nothing more",
                        cliPresence.installed
                            && cliPresence.state == .unavailable("Ollama is installed but not running"),
                        "state=\(cliPresence.state)")

        // Both installed, neither usable: each app's own reason.
        let bothDown = observe(
            [LMStudioScript(running: false).backend(), OllamaScript(kind: .app, up: false).backend()], .never).presence
        reporter.record("both installed and stopped: each app's own reason",
                        bothDown.state == .unavailable("LM Studio is not running; Ollama is not running"),
                        "state=\(bothDown.state)")

        // The Preferred local app.
        reporter.record(preferenceCheck, preference(nil, [.ollama]) == .ollama)
        reporter.record("automatic with only LM Studio installed prefers LM Studio",
                        preference(nil, [.lmStudio]) == .lmStudio)
        reporter.record("automatic with both installed prefers LM Studio",
                        preference(nil, [.lmStudio, .ollama]) == .lmStudio)
        reporter.record("automatic with neither installed prefers LM Studio", preference(nil, []) == .lmStudio)
        reporter.record("an explicit choice wins over what is installed",
                        preference(.ollama, [.lmStudio]) == .ollama && preference(.lmStudio, [.ollama]) == .lmStudio
                            && preference(.ollama, []) == .ollama)
    }

    // MARK: - LM Studio only: exactly 1.1.0

    private static func checkLMStudioOnlyMatches110(_ reporter: SelfTestReporter) {
        let noOllama = OllamaScript(kind: nil, up: false)

        func legacy(installed: Bool, running: Bool, models: [LMStudioModelOption]?) -> LLMProviderDetection.Presence {
            // 1.1.0's observeLocal, transcribed: install, then the server, then the catalog.
            guard installed else {
                return .init(installed: false,
                             state: LLMProviderDetection.localState(lmsInstalled: false, serverResponding: false))
            }
            guard running else {
                return .init(installed: true,
                             state: LLMProviderDetection.localState(lmsInstalled: true, serverResponding: false))
            }
            return .init(installed: true,
                         state: LLMProviderDetection.localState(lmsInstalled: true, serverResponding: true,
                                                                availableModels: models),
                         availableLocalModels: models)
        }

        let cases: [(String, LMStudioScript, [LMStudioModelOption]?)] = [
            ("running with models", LMStudioScript(), LMStudioModelCatalog.parse(Data(lmStudioCatalogJSON.utf8))),
            ("running with an empty catalog", LMStudioScript(catalogJSON: "[]"), []),
            ("running with an unreadable catalog", LMStudioScript(catalogJSON: nil), nil),
            ("not running", LMStudioScript(running: false), nil),
        ]
        for (label, script, models) in cases {
            let observed = LLMProviderDetection.observeLocal(
                backends: [script.backend(), noOllama.backend()], starter: .never)
            let expected = legacy(installed: script.installed, running: script.running,
                                  models: script.running ? models : nil)
            reporter.record(
                "LM Studio only, \(label): installed, state and catalog are exactly 1.1.0's",
                observed.presence.installed == expected.installed && observed.presence.state == expected.state
                    && observed.presence.availableLocalModels == expected.availableLocalModels
                    && observed.models == expected.availableLocalModels,
                "state=\(observed.presence.state) want=\(expected.state)")
        }
        let fixtureParse = LMStudioModelCatalog.parse(Data(lmStudioCatalogJSON.utf8)) ?? []
        reporter.record("fixture: 1.1.0's text catalog drops the vlm row and keeps both llm rows",
                        fixtureParse.map(\.modelID)
                            == ["lmstudio-presence-fixture-chat", "lmstudio-presence-fixture-seeing"])
        reporter.record("LM Studio only: nothing is ever started (LM Studio starts lazily inside the load)",
                        noOllama.launchCount == 0 && LMStudioScript().backend().backgroundLaunchPath == nil)
    }

    // MARK: - Negative controls

    /// Forwards everything to an Ollama backend but offers a launch path for ANY install, CLI included: the
    /// bug the "never start a CLI-only Ollama" rule exists to prevent.
    private struct LaunchesAnyInstall: LocalModelBackend {
        let wrapped: OllamaBackend
        var id: LocalBackendID { wrapped.id }
        func isInstalled() -> Bool { wrapped.isInstalled() }
        func serverResponds() -> Bool { wrapped.serverResponds() }
        func installedModels() -> [LocalInstalledModel]? { wrapped.installedModels() }
        func residentModels() -> [LocalResidentModel]? { wrapped.residentModels() }
        func ensureLoaded(_ ref: LocalModelRef, ttlSeconds: Int, contextTokens: Int?) -> Bool {
            wrapped.ensureLoaded(ref, ttlSeconds: ttlSeconds, contextTokens: contextTokens)
        }
        func unload(_ ref: LocalModelRef) { wrapped.unload(ref) }
        func routableModelOptions() -> [LMStudioModelOption]? { wrapped.routableModelOptions() }
        var backgroundLaunchPath: String? {
            wrapped.installKind == .cli ? LocalPresenceFixtureSelfTest.ollamaCLIPath : wrapped.backgroundLaunchPath
        }
    }

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) Presence that only ever asks LM Studio.
        let lmStudioOnly: ObserveSubject = { backends, starter in
            realObserve(backends.filter { $0.id == .lmStudio }, starter)
        }
        requireCaught(reporter, mutant: "presence that reads LM Studio only", by: ollamaOnlyCheck) {
            checkContract(observe: lmStudioOnly, preference: realPreference, $0)
        }

        // (b) A start policy that also opens a CLI-only install.
        let startsCLI: ObserveSubject = { backends, starter in
            realObserve(backends.map { backend -> LocalModelBackend in
                guard let ollama = backend as? OllamaBackend else { return backend }
                return LaunchesAnyInstall(wrapped: ollama)
            }, starter)
        }
        requireCaught(reporter, mutant: "start policy that opens a CLI-only Ollama", by: cliNotStartedCheck) {
            checkContract(observe: startsCLI, preference: realPreference, $0)
        }

        // (c) A Preferred-app rule that never looks at what is installed.
        let ignoresInstalled: PreferenceSubject = { explicit, _ in explicit ?? .lmStudio }
        requireCaught(reporter, mutant: "Preferred-app rule that ignores what is installed", by: preferenceCheck) {
            checkContract(observe: realObserve, preference: ignoresInstalled, $0)
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
