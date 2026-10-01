import Foundation

/// `--installer-local-steps-selftest`: the installer plan across both local apps, as DATA and as a queue run.
///
/// - **LM Studio's CLI gap.** The plan must make LM Studio ready (its `lms` exists) after the app and before
///   any LM Studio model. The queue half runs the REAL `LMStudioInstaller.ensureCLIReady` and `installModel`
///   over a scratch "Mac" where `lms` only appears once LM Studio has been opened, which is the measured
///   behaviour: before this slice, a model row queued straight after the app row failed with "LM Studio CLI
///   is not executable".
/// - **Ollama's order.** App, then server-ready, then the pull; a running row's activity (the approval wait,
///   real bytes) reaches the engine's caller.
/// - **The point-of-use choice (D3).** On a Mac with neither app: LM Studio first, the only recommended
///   option; Ollama second, the advanced option, carrying the macOS-prompt warning. Every button still only
///   installs or skips.
/// - **Persisted identifiers.** Every id and raw value already on users' disks is compared to a literal taken
///   from 12c0db4's source, and a 1.1.0-shaped `bootstrap.json` round-trips with its LM Studio rows intact.
///
/// Scratch only: no app is opened, nothing is downloaded, and no live preference or Application Support is
/// read or written.
///
/// Negative controls, each of which the gate must catch:
/// (d) the plan with no lms-ready step;
/// (e) the local-app choice with Ollama listed first, or offered as LM Studio's equal.
enum InstallerLocalStepsFixtureSelfTest {
    private static let ollamaFixtureModel = "installer-steps-fixture:4b"
    private static let adminWarning =
        "macOS will ask for Touch ID or your password so Ollama can install its command-line tool; approve it."

    // Assertion names the negative controls look up.
    private static let lmStudioOrderCheck = "the engine plan orders LM Studio app -> lms-ready -> LM Studio model"
    private static let queuedModelCheck =
        "a model row queued straight after the LM Studio app row installs (lms appears once LM Studio opens)"
    private static let firstChoiceCheck = "LM Studio is listed first and is the only recommended option"

    static func run() -> Bool {
        print("=== Installer local steps fixture selftest (LM Studio CLI order, Ollama order, D3 choice) ===")
        let reporter = SelfTestReporter()
        guard let scratch = scratchDirectory(reporter) else {
            print("[installer-local-steps-selftest] FAIL")
            return false
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        print("--- LM Studio: app, lms-ready, model (real plan) ---")
        checkLMStudioPlan(realLMStudioPlan, scratch: scratch, reporter)
        checkCLIReadyDetails(scratch: scratch, reporter)
        print("--- Ollama: app, server-ready, pull ---")
        checkOllamaPlan(scratch: scratch, reporter)
        print("--- the point-of-use choice on a Mac with neither app (real choice) ---")
        checkChoiceOrder(realChoice, reporter)
        checkChoiceDetails(reporter)
        print("--- persisted identifiers are unchanged ---")
        checkPersistedIdentifiers(scratch: scratch, reporter)
        checkNegativeControls(scratch: scratch, reporter)

        print(reporter.passed
            ? "[installer-local-steps-selftest] PASS"
            : "[installer-local-steps-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - LM Studio plan

    /// What point-of-use installs for email mode on a Mac with no LM Studio: the shipped descriptors.
    private static var realLMStudioPlan: [InstallerComponentDescriptor] {
        PointOfUseFeature.email.components
    }

    private static var gemmaRef: LocalModelRef {
        LocalModelRef(backend: .lmStudio, modelID: LMStudioInstaller.gemmaModelID)
    }

    /// True when every model step in the flattened plan has a ready step for its app before it, and that
    /// ready step comes after the app's own install step when the plan has one.
    private static func readyPrecedesEveryModel(_ plan: [InstallerComponentDescriptor],
                                                backend: LocalBackendID) -> Bool {
        let steps = plan.flatMap(\.localSteps)
        let appIndex = steps.firstIndex(of: .app(backend))
        var sawModel = false
        for (index, step) in steps.enumerated() {
            guard case .model(let ref) = step, ref.backend == backend else { continue }
            sawModel = true
            let readyBefore = steps[..<index].indices.contains { steps[$0] == .ready(backend) && $0 > (appIndex ?? -1) }
            if !readyBefore { return false }
        }
        return sawModel
    }

    private static func checkLMStudioPlan(_ plan: [InstallerComponentDescriptor], scratch: URL,
                                          _ reporter: SelfTestReporter) {
        let steps = plan.flatMap(\.localSteps)
        reporter.record(lmStudioOrderCheck,
                        steps.first == .app(.lmStudio) && readyPrecedesEveryModel(plan, backend: .lmStudio),
                        steps.map(describe).joined(separator: " -> "))
        let modelRows = plan.filter { $0.localSteps.contains { if case .model = $0 { return true }; return false } }
        reporter.record("a model row queued on its own still makes lms ready first",
                        !modelRows.isEmpty && modelRows.allSatisfy { readyPrecedesEveryModel([$0], backend: .lmStudio) })

        // The queue: the real CLI-ready and model mechanisms over a scratch Mac.
        let mac = ScratchMac(root: scratch.appendingPathComponent("mac-\(UUID().uuidString)", isDirectory: true))
        let engine = InstallerEngine(
            paths: scratchPaths(scratch), local: mac,
            sleep: { _ in })
        let results = engine.installAll(plan)
        let failures = results.compactMap { result -> String? in
            if case .failed(let failure, _) = result.state { return "\(result.componentID): \(failure.message)" }
            return nil
        }
        reporter.record(queuedModelCheck,
                        results.count == plan.count && results.allSatisfy(\.succeeded)
                            && mac.fetched == [LMStudioInstaller.gemmaModelID],
                        failures.joined(separator: " | "))
        reporter.record("LM Studio was opened by path, in the background, exactly once",
                        mac.opened == [["/usr/bin/open", "-g", mac.application.path]],
                        mac.opened.map { $0.joined(separator: " ") }.joined(separator: " | "))
    }

    /// A scratch Mac for the LM Studio half: installing the app creates its bundle, opening it creates
    /// `lms` two polls later, and `lms get` records what it fetched. Everything else is the real installer.
    private final class ScratchMac: InstallerLocalPerforming {
        let root: URL
        let application: URL
        let lms: URL
        private(set) var opened: [[String]] = []
        private(set) var fetched: [String] = []
        private var pollsUntilCLI: Int?
        private var now: TimeInterval = 0

        init(root: URL) {
            self.root = root
            application = root.appendingPathComponent("Applications/\(LMStudioInstaller.appName)", isDirectory: true)
            lms = root.appendingPathComponent("home/.lmstudio/bin/lms")
        }

        private func run(_ executable: String, _ arguments: [String]) throws -> LMStudioInstaller.CommandResult {
            if executable == "/usr/bin/open" {
                opened.append([executable] + arguments)
                pollsUntilCLI = 2
                return .init(status: 0, stdout: "", stderr: "")
            }
            if executable == lms.path, arguments.first == "ls" { return .init(status: 0, stdout: "[]", stderr: "") }
            if executable == lms.path, arguments.first == "get" {
                fetched.append(arguments.dropFirst().joined(separator: " "))
                return .init(status: 0, stdout: "downloaded", stderr: "")
            }
            return .init(status: 1, stdout: "", stderr: "unexpected command \(executable)")
        }

        private func sleep(_ seconds: TimeInterval) {
            now += seconds
            guard let remaining = pollsUntilCLI else { return }
            if remaining <= 1 {
                pollsUntilCLI = nil
                try? FileManager.default.createDirectory(at: lms.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: lms.path, contents: Data(),
                                               attributes: [.posixPermissions: 0o700])
            } else {
                pollsUntilCLI = remaining - 1
            }
        }

        func installApplication(_ backend: LocalBackendID,
                                report: @escaping (InstallerLocalActivity) -> Void) throws {
            try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        }

        func makeReady(_ backend: LocalBackendID, report: @escaping (InstallerLocalActivity) -> Void) throws {
            _ = try LMStudioInstaller.ensureCLIReady(lmsURL: lms, applications: [application],
                                                     commandRunner: run, clock: { self.now },
                                                     sleep: { self.sleep($0) })
        }

        func installModel(_ ref: LocalModelRef, report: @escaping (InstallerLocalActivity) -> Void) throws {
            _ = try LMStudioInstaller.installModel(ref.modelID, lmsURL: lms, commandRunner: run)
        }
    }

    private static func checkCLIReadyDetails(scratch: URL, _ reporter: SelfTestReporter) {
        let root = scratch.appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
        let lms = root.appendingPathComponent("home/.lmstudio/bin/lms")
        let app = root.appendingPathComponent("Applications/LM Studio.app", isDirectory: true)
        var calls: [[String]] = []
        let runner: LMStudioInstaller.CommandRunner = { executable, arguments in
            calls.append([executable] + arguments)
            return .init(status: 0, stdout: "", stderr: "")
        }
        var now: TimeInterval = 0

        reporter.record("with no LM Studio app, readiness fails without opening anything",
                        (try? LMStudioInstaller.ensureCLIReady(lmsURL: lms, applications: [app],
                                                               commandRunner: runner)) == nil && calls.isEmpty)

        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        do {
            _ = try LMStudioInstaller.ensureCLIReady(lmsURL: lms, applications: [app], commandRunner: runner,
                                                     clock: { now }, sleep: { now += $0 })
            reporter.record("an lms that never appears ends at the bound with a message that says what to do", false)
        } catch {
            let failure = InstallerEngine.failure(forLocal: error)
            reporter.record("an lms that never appears ends at the bound with a message that says what to do",
                            now >= LMStudioInstaller.cliWaitBound
                                && now < LMStudioInstaller.cliWaitBound + 2 * LMStudioInstaller.cliPollInterval
                                && failure.message.contains("Open LM Studio once") && !failure.isRetryable,
                            failure.message)
        }

        try? FileManager.default.createDirectory(at: lms.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: lms.path, contents: Data(), attributes: [.posixPermissions: 0o700])
        calls.removeAll()
        reporter.record("an lms that already exists opens nothing",
                        (try? LMStudioInstaller.ensureCLIReady(lmsURL: lms, applications: [app],
                                                               commandRunner: runner)) == .alreadyPresent
                            && calls.isEmpty)
        reporter.record("the default lms path is the one ModelResidency and installModel use",
                        LMStudioInstaller.cliURL.path.hasSuffix("/.lmstudio/bin/lms"))
    }

    // MARK: - Ollama plan

    /// Records the queue's calls and reports what a real Ollama row would: the approval wait, then bytes.
    private final class RecordingPerformer: InstallerLocalPerforming {
        private(set) var calls: [String] = []

        func installApplication(_ backend: LocalBackendID,
                                report: @escaping (InstallerLocalActivity) -> Void) throws {
            calls.append("app:\(backend.rawValue)")
        }

        func makeReady(_ backend: LocalBackendID, report: @escaping (InstallerLocalActivity) -> Void) throws {
            calls.append("ready:\(backend.rawValue)")
            if backend == .ollama { report(.awaitingApproval(.ollama)) }
        }

        func installModel(_ ref: LocalModelRef, report: @escaping (InstallerLocalActivity) -> Void) throws {
            calls.append("model:\(ref.backend.rawValue):\(ref.modelID)")
            report(.bytes(InstallerByteProgress(completed: 1_250_000, expected: 5_000_241)))
        }
    }

    private static func checkOllamaPlan(scratch: URL, _ reporter: SelfTestReporter) {
        let ref = LocalModelRef(backend: .ollama, modelID: ollamaFixtureModel)
        let model = BootstrapInstallPlan.localModel(ref, detail: "fixture model row", downloadBytes: nil)
        let plan = PointOfUseFeature.email.ollamaComponents + [model]
        let steps = plan.flatMap(\.localSteps)
        reporter.record("the engine plan orders Ollama app -> server-ready -> Ollama pull",
                        steps.first == .app(.ollama) && readyPrecedesEveryModel(plan, backend: .ollama)
                            && steps.last == .model(ref),
                        steps.map(describe).joined(separator: " -> "))
        reporter.record("the Ollama app row itself waits for the server, so it lands usable",
                        BootstrapInstallPlan.ollama.localSteps == [.app(.ollama), .ready(.ollama)])
        reporter.record("an Ollama model row has its own id, distinct from the same model id in LM Studio",
                        model.id == "ollama-model:\(ollamaFixtureModel)"
                            && BootstrapInstallPlan.componentID(for: LocalModelRef(backend: .lmStudio,
                                                                                   modelID: ollamaFixtureModel))
                                == "model:\(ollamaFixtureModel)")
        reporter.record("no Ollama default model is named in the shipped plan (D4 is open)",
                        !BootstrapInstallPlan.allComponents.contains { $0.localSteps.contains {
                            if case .model(let ref) = $0 { return ref.backend == .ollama }
                            return false
                        } })

        let performer = RecordingPerformer()
        let engine = InstallerEngine(paths: scratchPaths(scratch), local: performer, sleep: { _ in })
        var heard: [InstallerLocalActivity] = []
        let results = plan.map { engine.install($0, activity: { heard.append($0) }) }
        reporter.record("the queue runs app, ready, ready, pull in that order",
                        results.allSatisfy(\.succeeded)
                            && performer.calls == ["app:ollama", "ready:ollama", "ready:ollama",
                                                   "model:ollama:\(ollamaFixtureModel)"],
                        performer.calls.joined(separator: ", "))
        reporter.record("a running row's approval wait and real bytes reach the engine's caller",
                        heard.contains(.awaitingApproval(.ollama))
                            && heard.contains(.bytes(InstallerByteProgress(completed: 1_250_000, expected: 5_000_241))))
        let running = BootstrapComponentRecord(id: model.id, title: model.title, phase: .installing)
        reporter.record("and the progress line renders them in the row's own words",
                        PointOfUsePolicy.progressLine(running, activity: heard.last) == "\(model.title)   1 MB of 5 MB"
                            && PointOfUsePolicy.progressLine(running, activity: nil) == "\(model.title)   installing",
                        PointOfUsePolicy.progressLine(running, activity: heard.last))
    }

    // MARK: - The D3 choice

    /// Both apps' readings merged as `observeLocal` merges them. An installed app is running with no models,
    /// so its offer is measurable rather than suppressed as unknown.
    private static func presences(lmStudio: Bool, ollama: Bool,
                                  claude: Bool = false) -> [LLMProvider: LLMProviderDetection.Presence] {
        let local = LLMProviderDetection.mergedLocalPresence([
            LLMProviderDetection.LocalBackendReading(backend: .lmStudio, installed: lmStudio, responding: lmStudio,
                                                     models: lmStudio ? [] : nil),
            LLMProviderDetection.LocalBackendReading(backend: .ollama, installed: ollama, responding: ollama,
                                                     models: ollama ? [] : nil),
        ])
        return [.local: local,
                .claude: LLMProviderDetection.Presence(installed: claude,
                                                      state: claude ? .available : .unavailable("CLI unavailable")),
                .codex: LLMProviderDetection.Presence(installed: false,
                                                     state: .unavailable("the codex CLI is not installed"))]
    }

    private static var coreInstalled: BootstrapSnapshot {
        var snapshot = BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents)
        for descriptor in BootstrapInstallPlan.mandatoryCore {
            snapshot.apply(InstallerComponentResult(componentID: descriptor.id, title: descriptor.title,
                                                    state: .installed))
        }
        return snapshot
    }

    private static var realChoice: PointOfUseLocalAppChoice? {
        PointOfUsePolicy.offer(for: .email, presences: presences(lmStudio: false, ollama: false),
                               bootstrap: coreInstalled)?.localAppChoice
    }

    private static func checkChoiceOrder(_ choice: PointOfUseLocalAppChoice?, _ reporter: SelfTestReporter) {
        guard let choice else {
            reporter.record(firstChoiceCheck, false, "no choice was offered")
            return
        }
        let first = choice.options.first
        reporter.record(firstChoiceCheck,
                        choice.options.count == 2 && first?.backend == .lmStudio && first?.recommended == true
                            && choice.options.filter(\.recommended).count == 1
                            && Set(choice.options.map(\.label)).count == choice.options.count,
                        choice.options.map { "\($0.backend.rawValue)(\($0.label))" }.joined(separator: ", "))
        let ollama = choice.option(.ollama)
        reporter.record("Ollama is the advanced option and carries the macOS-prompt warning, word for word",
                        choice.options.last?.backend == .ollama && ollama?.recommended == false
                            && ollama?.warning == adminWarning,
                        ollama?.warning ?? "no warning")
    }

    private static func checkChoiceDetails(_ reporter: SelfTestReporter) {
        let bare = presences(lmStudio: false, ollama: false)
        guard case .chooser(let chooser)? = PointOfUsePolicy.offer(for: .email, presences: bare,
                                                                    bootstrap: coreInstalled),
              let choice = chooser.localAppChoice else {
            reporter.record("a bare Mac's chooser carries the local-app choice", false)
            return
        }
        reporter.record("a bare Mac's chooser carries the local-app choice, beside its four unchanged buttons",
                        chooser.buttons.map(\.id) == [PointOfUsePolicy.skipButtonID, PointOfUsePolicy.claudeButtonID,
                                                      PointOfUsePolicy.codexButtonID, PointOfUsePolicy.localButtonID])
        reporter.record("the LM Studio option installs exactly what Set up local models always installed",
                        choice.option(.lmStudio)?.components == chooser.localComponents
                            && chooser.localComponents == [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.gemma])
        reporter.record("the Ollama option installs the Ollama app row (no model until D4)",
                        choice.option(.ollama)?.components == [BootstrapInstallPlan.ollama])
        reporter.record("LM Studio's option raises no macOS-prompt warning", choice.option(.lmStudio)?.warning == nil)
        let routes = Set(choice.buttons.map(\.route.kind))
        reporter.record("every button on the choice only installs or skips (the route invariant holds)",
                        routes == [.install, .skip] && choice.options.allSatisfy { $0.button.route == .install },
                        routes.map(\.rawValue).sorted().joined(separator: ","))
        let ids = choice.buttons.map(\.id) + chooser.buttons.map(\.id)
        reporter.record("the choice's buttons have ids no other offer button uses",
                        Set(choice.options.map(\.button.id)).isDisjoint(with: chooser.buttons.map(\.id))
                            && Set(choice.options.map(\.button.id)).count == 2, ids.joined(separator: ","))
        reporter.record("the offer's log token names the two apps and no content",
                        PointOfUseOffer.chooser(chooser).logToken.hasSuffix(" apps=lmStudio,ollama"),
                        PointOfUseOffer.chooser(chooser).logToken)

        if case .install(let offer)? = PointOfUsePolicy.offer(for: .email, presences: presences(lmStudio: false,
                                                                                                  ollama: false,
                                                                                                  claude: true),
                                                              bootstrap: coreInstalled) {
            reporter.record("with Claude signed in but neither local app, the install offer carries the choice too",
                            offer.localAppChoice?.options.first?.backend == .lmStudio
                                && offer.components == [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.gemma])
        } else {
            reporter.record("with Claude signed in but neither local app, the install offer carries the choice too",
                            false)
        }
        let lmStudioHere = PointOfUsePolicy.offer(for: .email, presences: presences(lmStudio: true, ollama: false),
                                                  bootstrap: coreInstalled)
        let ollamaHere = PointOfUsePolicy.offer(for: .email, presences: presences(lmStudio: false, ollama: true),
                                                bootstrap: coreInstalled)
        reporter.record("a Mac that already has either app is offered an install, but not asked which app",
                        lmStudioHere != nil && lmStudioHere?.localAppChoice == nil
                            && ollamaHere != nil && ollamaHere?.localAppChoice == nil)
        reporter.record("a local-only feature is never offered the choice",
                        PointOfUsePolicy.offer(for: .dictation, presences: bare,
                                               bootstrap: BootstrapSnapshot.fresh(descriptors:
                                                   BootstrapInstallPlan.allComponents))?.localAppChoice == nil)

        let ollamaInstall = PointOfUsePolicy.installOffer(for: .email, outstanding: [BootstrapInstallPlan.ollama])
        reporter.record("an Ollama install page says to expect and approve the macOS prompt",
                        ollamaInstall.lines.contains(adminWarning), ollamaInstall.lines.joined(separator: " | "))

        // The Preferred local app follows what got installed from the choice.
        let table: [(LocalBackendID, LocalBackendID?, LocalBackendID?)] = [
            (.ollama, nil, nil), (.ollama, .lmStudio, nil), (.ollama, .ollama, .ollama),
            (.lmStudio, .ollama, nil), (.lmStudio, .lmStudio, .lmStudio),
        ]
        reporter.record("the Preferred local app follows the installed app, never pinning the one passed over",
                        table.allSatisfy { installed, explicit, expected in
                            let next = PointOfUsePolicy.preferenceAfterInstalling(installed, explicit: explicit)
                            return next == expected
                                && LocalBackendPreference.effective(explicit: next, installed: [installed]) == installed
                        })
    }

    // MARK: - Persisted identifiers (literals from 12c0db4's source)

    private static func checkPersistedIdentifiers(scratch: URL, _ reporter: SelfTestReporter) {
        let legacyIDs = ["stt-daemon", "web-search", "lm-studio", "model:google/gemma-4-e4b",
                         "model:qwen3-coder-30b-a3b-instruct-mlx"]
        let all = BootstrapInstallPlan.allComponents.map(\.id)
        reporter.record("every 1.1.0 component id is unchanged and in its place; new rows are appended",
                        Array(all.prefix(legacyIDs.count)) == legacyIDs && all.dropFirst(legacyIDs.count) == ["ollama"],
                        all.joined(separator: ","))
        reporter.record("LM Studio rows keep their titles",
                        BootstrapInstallPlan.lmStudio.title == "LM Studio"
                            && BootstrapInstallPlan.gemma.title == "google/gemma-4-e4b"
                            && BootstrapInstallPlan.qwen.title == "qwen3-coder-30b-a3b-instruct-mlx")
        reporter.record("the mandatory core is unchanged",
                        BootstrapSnapshot.mandatoryCoreIDs == ["stt-daemon", "web-search"])
        reporter.record("bootstrap.json's name, version and raw values are unchanged",
                        BootstrapStateStore.fileName == "bootstrap.json" && BootstrapSnapshot.currentVersion == 1
                            && [BootstrapComponentPhase.pending, .installing, .installed, .failed].map(\.rawValue)
                                == ["pending", "installing", "installed", "failed"]
                            && [BootstrapLifecycle.idle, .downloading, .degraded, .complete].map(\.rawValue)
                                == ["idle", "downloading", "degraded", "complete"])
        reporter.record("the stored backend raw values are unchanged",
                        LocalBackendID.lmStudio.rawValue == "lmStudio" && LocalBackendID.ollama.rawValue == "ollama")

        let record = BootstrapComponentRecord(id: "lm-studio", title: "LM Studio", phase: .installed, attempts: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) }
        reporter.record("an LM Studio row encodes to the same bytes as before",
                        encoded == #"{"attempts":1,"id":"lm-studio","phase":"installed","title":"LM Studio"}"#,
                        encoded ?? "nil")

        // A bootstrap.json as 1.1.0 wrote it, with LM Studio and gemma installed and qwen failed.
        let legacy = """
        {"components":[\
        {"attempts":1,"id":"stt-daemon","phase":"installed","title":"Transcription engine"},\
        {"attempts":1,"id":"web-search","phase":"installed","title":"Web search"},\
        {"attempts":1,"id":"lm-studio","phase":"installed","title":"LM Studio"},\
        {"attempts":2,"id":"model:google/gemma-4-e4b","phase":"installed","title":"google/gemma-4-e4b"},\
        {"attempts":3,"failureMessage":"fixture: lms get failed","id":"model:qwen3-coder-30b-a3b-instruct-mlx",\
        "phase":"failed","title":"qwen3-coder-30b-a3b-instruct-mlx"}],\
        "lifecycle":"degraded","mandatoryComponentIDs":["stt-daemon","web-search"],"version":1}
        """
        let url = scratch.appendingPathComponent("legacy-bootstrap.json")
        do {
            try Data(legacy.utf8).write(to: url)
            var written: Data?
            let store = BootstrapStateStore(url: url, writer: { data, _ in written = data })
            let snapshot = store.snapshot()
            let legacyRows = try JSONDecoder().decode(BootstrapSnapshot.self, from: Data(legacy.utf8)).components
            reporter.record("a 1.1.0 bootstrap.json loads with every LM Studio row exactly as it was",
                            Array(snapshot.components.prefix(legacyRows.count)) == legacyRows
                                && snapshot.lifecycle == .degraded)
            reporter.record("the new Ollama row joins as pending, and the file is not rewritten on open",
                            snapshot.component("ollama")?.phase == .pending && written == nil)
            store.markInstalling(componentID: "ollama")
            let rewritten = written.map { String(decoding: $0, as: UTF8.self) } ?? ""
            reporter.record("a later write keeps the LM Studio rows byte-for-byte",
                            rewritten.contains(#"{"attempts":1,"id":"lm-studio","phase":"installed","title":"LM Studio"}"#)
                                && rewritten.contains(#"{"attempts":3,"failureMessage":"fixture: lms get failed","#
                                    + #""id":"model:qwen3-coder-30b-a3b-instruct-mlx","phase":"failed","#
                                    + #""title":"qwen3-coder-30b-a3b-instruct-mlx"}"#),
                            rewritten)
        } catch {
            reporter.record("legacy bootstrap.json fixture", false, String(describing: error))
        }
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(scratch: URL, _ reporter: SelfTestReporter) {
        // (d) The plan before this slice: the app row installs the app only, and the model row fetches only.
        let noReady = realLMStudioPlan.map { descriptor in
            InstallerComponentDescriptor(
                id: descriptor.id, title: descriptor.title, detail: descriptor.detail,
                localSteps: descriptor.localSteps.filter { if case .ready = $0 { return false }; return true },
                downloadBytes: descriptor.downloadBytes)
        }
        requireCaught(reporter, mutant: "plan with no lms-ready step", by: lmStudioOrderCheck) {
            checkLMStudioPlan(noReady, scratch: scratch, $0)
        }
        requireCaught(reporter, mutant: "plan with no lms-ready step, run as a queue", by: queuedModelCheck) {
            checkLMStudioPlan(noReady, scratch: scratch, $0)
        }

        guard let real = realChoice else {
            reporter.record("negative controls need the real choice", false)
            return
        }
        // (e1) Ollama listed first.
        let ollamaFirst = PointOfUseLocalAppChoice(header: real.header, lines: real.lines,
                                                   options: Array(real.options.reversed()))
        requireCaught(reporter, mutant: "choice with Ollama listed first", by: firstChoiceCheck) {
            checkChoiceOrder(ollamaFirst, $0)
        }
        // (e2) Ollama offered as LM Studio's equal: both recommended, the same label.
        let equals = PointOfUseLocalAppChoice(header: real.header, lines: real.lines, options: real.options.map {
            PointOfUseLocalAppOption(backend: $0.backend, title: $0.title, label: "Recommended", recommended: true,
                                     detail: $0.detail, warning: $0.warning, components: $0.components,
                                     button: $0.button)
        })
        requireCaught(reporter, mutant: "choice with Ollama offered as an equal", by: firstChoiceCheck) {
            checkChoiceOrder(equals, $0)
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

    // MARK: - Helpers

    private static func describe(_ step: InstallerLocalStep) -> String {
        switch step {
        case .app(let backend): return "app(\(backend.rawValue))"
        case .ready(let backend): return "ready(\(backend.rawValue))"
        case .model(let ref): return "model(\(ref.backend.rawValue):\(ref.modelID))"
        }
    }

    private static func scratchPaths(_ scratch: URL) -> InstallerPaths {
        let support = scratch.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
        return InstallerPaths(python: URL(fileURLWithPath: "/nonexistent/python"),
                              applicationSupport: support,
                              modelCache: support.appendingPathComponent("model-cache"),
                              packageCache: support.appendingPathComponent("package-cache"))
    }

    private static func scratchDirectory(_ reporter: SelfTestReporter) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-installer-local-steps-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            reporter.record("scratch fixture setup", false, String(describing: error))
            return nil
        }
    }
}
