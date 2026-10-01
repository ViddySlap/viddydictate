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
/// - **The feature's own model, per app (D1/D4).** The Ollama choice queues Ollama, then the feature's Ollama
///   staff pick (`gemma4:e4b` for email, `qwen3-coder:30b` for cleanup and prompt prep). A Mac whose local app
///   is Ollama (the only one installed, or the effective Preferred app of two) is offered a pull of that pick
///   alone, with no LM Studio row anywhere. A Mac with LM Studio and not Ollama is offered exactly what 29e3f47
///   offered, compared to literals taken from that commit's output. No Ollama pull is offered that this Mac
///   cannot fit (the first-run window's own fit check): a 16 GB Mac is never offered `qwen3-coder:30b`.
/// - **Persisted identifiers.** Every id and raw value already on users' disks is compared to a literal taken
///   from 12c0db4's source, and a 1.1.0-shaped `bootstrap.json` round-trips with its LM Studio rows intact.
///
/// Scratch only: no app is opened, nothing is downloaded, and no live preference or Application Support is
/// read or written.
///
/// Negative controls, each of which the gate must catch:
/// (d) the plan with no lms-ready step;
/// (e) the local-app choice with Ollama listed first, or offered as LM Studio's equal;
/// (f) an Ollama choice that queues the app and no model;
/// (g) an Ollama-only Mac offered LM Studio;
/// (h) an Ollama pull offered with no fit check.
enum InstallerLocalStepsFixtureSelfTest {
    private static let ollamaFixtureModel = "installer-steps-fixture:4b"
    private static let adminWarning =
        "macOS will ask for Touch ID or your password so Ollama can install its command-line tool; approve it."

    // Assertion names the negative controls look up.
    private static let lmStudioOrderCheck = "the engine plan orders LM Studio app -> lms-ready -> LM Studio model"
    private static let queuedModelCheck =
        "a model row queued straight after the LM Studio app row installs (lms appears once LM Studio opens)"
    private static let firstChoiceCheck = "LM Studio is listed first and is the only recommended option"
    private static let ollamaChoiceModelCheck =
        "neither app: the Ollama choice plans app(ollama) -> ready(ollama) -> the feature's own Ollama pull"
    private static let ollamaOnlyCheck =
        "Ollama-only Mac missing the pick: a pull of the feature's Ollama staff pick, and no LM Studio row anywhere"
    private static let fitCheck = "a 16 GB Mac is never offered a qwen3-coder:30b install, on any page"

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
        print("--- the feature's own model, per app (real policy) ---")
        checkOllamaChoiceModel(realPolicy, scratch: scratch, reporter)
        checkOllamaOnly(realPolicy, reporter)
        checkLMStudioUnchanged(reporter)
        checkFit(realPolicy, reporter)
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
        let plan = [BootstrapInstallPlan.ollama, model]
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
        // D4's families are agreed (S8 names them for the first-run window); its pick LABEL is not, and no
        // label lives in the plan. So the shipped Ollama models are exactly the two families, nothing else.
        let shippedOllamaModels = BootstrapInstallPlan.allComponents.flatMap { $0.localSteps.compactMap { step -> String? in
            if case .model(let ref) = step, ref.backend == .ollama { return ref.modelID }
            return nil
        } }
        reporter.record("the shipped Ollama models are D4's two families and nothing else",
                        shippedOllamaModels == ["gemma4:e4b", "qwen3-coder:30b"],
                        shippedOllamaModels.joined(separator: ", "))

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
        reporter.record("the Ollama option installs the Ollama app row, then the feature's own Ollama model",
                        choice.option(.ollama)?.components
                            == [BootstrapInstallPlan.ollama, BootstrapInstallPlan.ollamaGemma])
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

    // MARK: - The feature's own model, per app

    /// The policy under test, as a value, so a negative control can stand in for it.
    private typealias Policy = (PointOfUseFeature, [LLMProvider: LLMProviderDetection.Presence], LocalBackendID?,
                                ComponentPicker.MachineFacts?) -> PointOfUseOffer?

    private static let realPolicy: Policy = { feature, presences, preferred, facts in
        PointOfUsePolicy.offer(for: feature, presences: presences, bootstrap: coreInstalled,
                               preferredLocalApp: preferred, facts: facts)
    }

    /// The three features a local text model serves, with D4's Ollama staff pick for each.
    private static let textFeatures: [(PointOfUseFeature, String)] = [
        (.email, "gemma4:e4b"), (.cleanup, "qwen3-coder:30b"), (.promptPrep, "qwen3-coder:30b"),
    ]

    /// Synthetic Macs, fixed numbers rather than this machine's sysctls. 16 GB: qwen3-coder:30b (18.56 GB x 1.15)
    /// cannot fit even at the 12.6 GB ceiling, gemma4:e4b fits there but not at today's budget (a tight fit).
    private static let mac16 = ComponentPicker.MachineFacts(
        physicalBytes: 17_179_869_184, budgetBytes: 8_000_000_000, maxBudgetBytes: 12_600_000_000,
        wiredBytes: 3_000_000_000)
    private static let mac64 = ComponentPicker.MachineFacts(
        physicalBytes: 68_719_476_736, budgetBytes: 32_000_000_000, maxBudgetBytes: 50_000_000_000,
        wiredBytes: 5_000_000_000)

    /// One app's reading: nil models with `installed` true is a stopped app (its catalog unread).
    private static func machine(lmStudio: [String]?, ollama: [String]?, lmStudioInstalled: Bool? = nil,
                                ollamaInstalled: Bool? = nil,
                                claude: Bool = false) -> [LLMProvider: LLMProviderDetection.Presence] {
        func reading(_ backend: LocalBackendID, _ models: [String]?,
                     _ installed: Bool) -> LLMProviderDetection.LocalBackendReading {
            LLMProviderDetection.LocalBackendReading(
                backend: backend, installed: installed, responding: models != nil,
                models: models.map { $0.map { LMStudioModelOption(modelID: $0, label: $0, backend: backend) } },
                startable: backend == .ollama && installed)
        }
        let local = LLMProviderDetection.mergedLocalPresence([
            reading(.lmStudio, lmStudio, lmStudioInstalled ?? (lmStudio != nil)),
            reading(.ollama, ollama, ollamaInstalled ?? (ollama != nil)),
        ])
        return [.local: local,
                .claude: LLMProviderDetection.Presence(installed: claude,
                                                      state: claude ? .available : .unavailable("CLI unavailable")),
                .codex: LLMProviderDetection.Presence(installed: false,
                                                     state: .unavailable("the codex CLI is not installed"))]
    }

    /// Every component a page could hand the queue: the offer's own, the chooser's, and each app option's.
    private static func everyComponent(_ offer: PointOfUseOffer?) -> [InstallerComponentDescriptor] {
        guard let offer else { return [] }
        var all: [InstallerComponentDescriptor]
        switch offer {
        case .install(let install): all = install.components
        case .chooser(let chooser): all = chooser.localComponents
        }
        all += offer.localAppChoice?.options.flatMap(\.components) ?? []
        return all
    }

    private static func offerComponents(_ offer: PointOfUseOffer?) -> [InstallerComponentDescriptor]? {
        switch offer {
        case .install(let install)?: return install.components
        case .chooser(let chooser)?: return chooser.localComponents
        case nil: return nil
        }
    }

    /// Whether LM Studio appears anywhere on the offer: a queue row that touches it, an app option, or a word.
    private static func mentionsLMStudio(_ offer: PointOfUseOffer?) -> Bool {
        guard let offer else { return false }
        let steps = everyComponent(offer).flatMap(\.localSteps)
        let words = [offer.header] + offer.lines + offer.buttons.flatMap { [$0.title, $0.detail] }
        return steps.contains { $0.backend == .lmStudio } || offer.localAppChoice != nil
            || words.contains { $0.contains("LM Studio") }
    }

    private static func steps(_ components: [InstallerComponentDescriptor]?) -> [String] {
        (components ?? []).flatMap(\.localSteps).map(describe)
    }

    /// The same offer with its app choice transformed. Negative controls only.
    private static func mapChoice(
        _ offer: PointOfUseOffer?,
        _ transform: (PointOfUseLocalAppChoice) -> PointOfUseLocalAppChoice) -> PointOfUseOffer? {
        switch offer {
        case .install(var install)?:
            install.localAppChoice = install.localAppChoice.map(transform)
            return .install(install)
        case .chooser(var chooser)?:
            chooser.localAppChoice = chooser.localAppChoice.map(transform)
            return .chooser(chooser)
        case nil:
            return nil
        }
    }

    private static func checkOllamaChoiceModel(_ policy: Policy, scratch: URL, _ reporter: SelfTestReporter) {
        var mismatches: [String] = []
        for (feature, tag) in textFeatures {
            for claude in [false, true] {
                let offer = policy(feature, machine(lmStudio: nil, ollama: nil, claude: claude), nil, mac64)
                let planned = steps(offer?.localAppChoice?.option(.ollama)?.components)
                let expected = ["app(ollama)", "ready(ollama)", "ready(ollama)", "model(ollama:\(tag))"]
                if planned != expected {
                    mismatches.append("\(feature.id)\(claude ? "+claude" : ""): \(planned.joined(separator: " -> "))")
                }
            }
        }
        reporter.record(ollamaChoiceModelCheck, mismatches.isEmpty, mismatches.joined(separator: " | "))

        let email = policy(.email, machine(lmStudio: nil, ollama: nil), nil, mac64)?.localAppChoice
        let cleanup = policy(.cleanup, machine(lmStudio: nil, ollama: nil), nil, mac64)?.localAppChoice
        reporter.record("the Ollama option's button quotes the pull's measured size, plus Ollama",
                        email?.option(.ollama)?.button.detail == "Downloads 6.58 GB plus Ollama."
                            && cleanup?.option(.ollama)?.button.detail == "Downloads 18.56 GB plus Ollama.",
                        [email, cleanup].map { $0?.option(.ollama)?.button.detail ?? "nil" }.joined(separator: " | "))
        reporter.record("the Ollama option says it pulls the feature's model after the app",
                        email?.option(.ollama)?.detail == "The advanced option, for people who already use Ollama. "
                            + "ViddyDictate installs it from Ollama's own download, then pulls the model email mode uses.",
                        email?.option(.ollama)?.detail ?? "nil")
        // LM Studio's option, word for word as 29e3f47 printed it.
        let lmStudio = email?.option(.lmStudio)
        reporter.record("the LM Studio option is 29e3f47's, row for row and word for word",
                        lmStudio?.components.map(\.id) == ["lm-studio", "model:google/gemma-4-e4b"]
                            && lmStudio?.detail == "The simple install. ViddyDictate installs LM Studio from its own "
                                + "installer, then the model email mode uses."
                            && lmStudio?.button.title == "Install LM Studio"
                            && lmStudio?.button.detail == "Downloads 6.86 GB plus LM Studio."
                            && lmStudio?.warning == nil && lmStudio?.recommended == true,
                        lmStudio.map { "\($0.components.map(\.id)) \($0.button.detail)" } ?? "nil")

        // The queue the Ollama choice hands the installer, run: the app, its server, then the pull.
        guard let components = email?.option(.ollama)?.components else { return }
        let performer = RecordingPerformer()
        let engine = InstallerEngine(paths: scratchPaths(scratch), local: performer, sleep: { _ in })
        let results = components.map { engine.install($0, activity: { _ in }) }
        reporter.record("the Ollama choice's queue runs app, ready, ready, pull of gemma4:e4b",
                        results.allSatisfy(\.succeeded)
                            && performer.calls
                                == ["app:ollama", "ready:ollama", "ready:ollama", "model:ollama:gemma4:e4b"],
                        performer.calls.joined(separator: ", "))
    }

    private static func checkOllamaOnly(_ policy: Policy, _ reporter: SelfTestReporter) {
        // Each case: a Mac whose local app is Ollama, missing the feature's pick.
        let cases: [(String, [LLMProvider: LLMProviderDetection.Presence], LocalBackendID?)] = [
            ("Ollama only, Claude signed in", machine(lmStudio: nil, ollama: ["llama3.2:1b"], claude: true), nil),
            ("Ollama only, nothing else", machine(lmStudio: nil, ollama: []), nil),
            ("Ollama only, Preferred set to LM Studio", machine(lmStudio: nil, ollama: [], claude: true), .lmStudio),
            ("both apps, Preferred Ollama", machine(lmStudio: ["llama-3.2-1b-instruct"], ollama: ["llama3.2:1b"]),
             .ollama),
        ]
        var mismatches: [String] = []
        for (feature, tag) in textFeatures {
            for (label, presences, preferred) in cases {
                let offer = policy(feature, presences, preferred, mac64)
                let components = offerComponents(offer)
                let ok = components?.map(\.id) == ["ollama-model:\(tag)"]
                    && steps(components) == ["ready(ollama)", "model(ollama:\(tag))"]
                    && !mentionsLMStudio(offer)
                if !ok {
                    let planned = steps(everyComponent(offer)).joined(separator: " -> ")
                    mismatches.append("\(feature.id) on \(label): \(planned)"
                        + (mentionsLMStudio(offer) ? " (mentions LM Studio)" : ""))
                }
            }
        }
        reporter.record(ollamaOnlyCheck, mismatches.isEmpty, mismatches.joined(separator: " | "))

        let ollamaOnly = machine(lmStudio: nil, ollama: [], claude: true)
        guard case .install(let email)? = policy(.email, ollamaOnly, nil, mac64),
              case .install(let cleanup)? = policy(.cleanup, ollamaOnly, nil, mac64) else {
            reporter.record("an Ollama-only Mac with Claude signed in gets an install offer", false)
            return
        }
        reporter.record("the pull offer names the model, its app and its measured size",
                        email.header == "EMAIL MODE - NOT INSTALLED YET"
                            && email.lines == ["Email mode uses gemma4:e4b in Ollama, 6.58 GB.",
                                               "It installs here. Email mode runs as soon as it lands, and you can close this."]
                            && cleanup.lines.first == "Cleanup uses qwen3-coder:30b in Ollama, 18.56 GB.",
                        (email.lines + cleanup.lines.prefix(1)).joined(separator: " | "))
        reporter.record("its button installs the model in Ollama and says what it downloads; Not now skips",
                        email.buttons.map(\.title) == ["Install gemma4:e4b in Ollama", "Not now"]
                            && email.buttons.map(\.detail) == ["Downloads 6.58 GB.",
                                                               "Nothing is installed and your text is untouched."]
                            && email.buttons.map(\.route) == [.install, .skip]
                            && cleanup.buttons.first?.title == "Install qwen3-coder:30b in Ollama",
                        email.buttons.map { "\($0.title): \($0.detail)" }.joined(separator: " | "))
        reporter.record("pressing it installs the page's own row, with no app choice in between",
                        email.buttons.first.map { PointOfUsePolicy.installStep(pressed: $0, offer: .install(email),
                                                                              choice: nil, running: false) }
                            == .installComponents && email.localAppChoice == nil)

        let both = machine(lmStudio: ["llama-3.2-1b-instruct"], ollama: ["llama3.2:1b"])
        reporter.record("both apps on Automatic: the effective Preferred app is LM Studio, so its offer is LM Studio's",
                        offerComponents(policy(.email, both, nil, mac64))?.map(\.id) == ["model:google/gemma-4-e4b"]
                            && offerComponents(policy(.email, both, .lmStudio, mac64))?.map(\.id)
                                == ["model:google/gemma-4-e4b"])
        reporter.record("an Ollama Mac that already holds the pick is offered nothing",
                        policy(.email, machine(lmStudio: nil, ollama: ["gemma4:e4b"], claude: true), nil, mac64) == nil
                            && policy(.cleanup, machine(lmStudio: nil, ollama: ["qwen3-coder:30b"], claude: true), nil,
                                      mac64) == nil)
        reporter.record("a stopped Ollama (its catalog unread) is offered nothing rather than a guess",
                        policy(.email, machine(lmStudio: nil, ollama: nil, ollamaInstalled: true, claude: true), nil,
                               mac64) == nil)
        guard case .chooser(let chooser)? = policy(.email, machine(lmStudio: nil, ollama: []), nil, mac64) else {
            reporter.record("an Ollama-only Mac with nothing else still gets B14's chooser", false)
            return
        }
        reporter.record("an Ollama-only Mac with nothing else gets B14's chooser, whose local route is the pull",
                        chooser.buttons.map(\.id) == [PointOfUsePolicy.skipButtonID, PointOfUsePolicy.claudeButtonID,
                                                      PointOfUsePolicy.codexButtonID, PointOfUsePolicy.localButtonID]
                            && chooser.localComponents == [BootstrapInstallPlan.ollamaGemma]
                            && chooser.buttons.last?.detail == "6.58 GB. Nothing you dictate leaves this Mac.",
                        chooser.buttons.last?.detail ?? "nil")
        let routes = Set([PointOfUseOffer.install(email), .install(cleanup), .chooser(chooser)]
            .flatMap { $0.buttons.map(\.route.kind) })
        reporter.record("every button on an Ollama page still only installs, skips or opens a sign-in",
                        routes.isSubset(of: [.install, .skip, .guidedProvider]))
    }

    /// A page as text, one line per field, in the form the literals below were captured in from 29e3f47.
    private static func transcript(_ offer: PointOfUseOffer?) -> [String] {
        guard let offer else { return ["nil"] }
        var out: [String]
        switch offer {
        case .install(let install): out = ["install comps=\(install.components.map(\.id).joined(separator: ","))"]
        case .chooser(let chooser): out = ["chooser local=\(chooser.localComponents.map(\.id).joined(separator: ","))"]
        }
        out.append("header=\(offer.header)")
        out += offer.lines.map { "line=\($0)" }
        out += offer.buttons.map { button -> String in
            let route: String
            switch button.route {
            case .skip: route = "skip"
            case .install: route = "install"
            case .guidedProvider(let provider): route = "guidedProvider(\(provider.rawValue))"
            }
            return "button=\(button.id)|\(button.title)|\(button.detail)|\(route)"
        }
        out.append("choice=\(offer.localAppChoice == nil ? "none" : "yes")")
        out.append("log=\(offer.logToken)")
        return out
    }

    /// 29e3f47's install offer for a feature on an LM Studio Mac missing its model, captured from that commit.
    private static func lmStudioInstall29e3f47(id: String, title: String, model: String, size: String) -> [String] {
        ["install comps=model:\(model)",
         "header=\(title.uppercased()) - NOT INSTALLED YET",
         "line=\(title) uses \(model), \(size).",
         "line=It installs here. \(title) runs as soon as it lands, and you can close this.",
         "button=install-now|Install now|Downloads \(size).|install",
         "button=skip|Not now|Nothing is installed and your text is untouched.|skip",
         "choice=none",
         "log=point-of-use offer=install feature=\(id) buttons=install-now,skip"]
    }

    private static func checkLMStudioUnchanged(_ reporter: SelfTestReporter) {
        let email = lmStudioInstall29e3f47(id: "email", title: "Email mode", model: "google/gemma-4-e4b",
                                           size: "6.86 GB")
        let cleanup = lmStudioInstall29e3f47(id: "cleanup", title: "Cleanup",
                                             model: "qwen3-coder-30b-a3b-instruct-mlx", size: "17.19 GB")
        let promptPrep = lmStudioInstall29e3f47(id: "prompt-prep", title: "Prompt prep",
                                                model: "qwen3-coder-30b-a3b-instruct-mlx", size: "17.19 GB")
        let chooser = [
            "chooser local=model:google/gemma-4-e4b",
            "header=EMAIL MODE NEEDS A MODEL - PICK A ROUTE",
            "line=This Mac has no local model installed, and neither the Claude nor the Codex CLI is here.",
            "line=ViddyDictate has sent nothing anywhere. A cloud provider only ever runs if you pick one here.",
            "button=skip|Skip this time|Leave it. Your text is untouched.|skip",
            "button=set-up-claude|Set up Claude|Sign in to Claude Code. Your text would then leave this Mac.|guidedProvider(claude)",
            "button=set-up-codex|Set up Codex|Sign in to Codex. Your text would then leave this Mac.|guidedProvider(codex)",
            "button=set-up-local-models|Set up local models|6.86 GB. Nothing you dictate leaves this Mac.|install",
            "choice=none",
            "log=point-of-use offer=chooser feature=email buttons=skip,set-up-claude,set-up-codex,set-up-local-models",
        ]
        let lmOnly = machine(lmStudio: [], ollama: nil, claude: true)
        let lmOther = machine(lmStudio: ["llama-3.2-1b-instruct"], ollama: nil)
        let lmBare = machine(lmStudio: [], ollama: nil)
        let expectations: [(String, PointOfUseFeature, [LLMProvider: LLMProviderDetection.Presence], [String])] = [
            ("email, Claude signed in", .email, lmOnly, email),
            ("cleanup, Claude signed in", .cleanup, lmOnly, cleanup),
            ("prompt prep, Claude signed in", .promptPrep, lmOnly, promptPrep),
            ("email, another model installed", .email, lmOther, email),
            ("cleanup, another model installed", .cleanup, lmOther, cleanup),
            ("email, nothing else installed", .email, lmBare, chooser),
        ]
        var mismatches: [String] = []
        for (label, feature, presences, expected) in expectations {
            // Whatever the Preferred app says and however small the Mac: neither is read without Ollama.
            for preferred in [nil, LocalBackendID.lmStudio, .ollama] {
                for facts in [nil, mac16, mac64] {
                    let got = transcript(realPolicy(feature, presences, preferred, facts))
                    if got != expected {
                        mismatches.append("\(label), preferred \(preferred?.rawValue ?? "automatic"): "
                            + got.joined(separator: " / "))
                    }
                }
            }
        }
        reporter.record("an LM-Studio-only Mac's offer is 29e3f47's, byte for byte, on every preference and Mac",
                        mismatches.isEmpty, mismatches.prefix(2).joined(separator: " | "))
        // A presence built by hand (no per-app readings) keeps the 1.1.0 reading: LM Studio's offer.
        let handBuilt: [LLMProvider: LLMProviderDetection.Presence] = [
            .local: LLMProviderDetection.Presence(
                installed: true, state: .available,
                availableLocalModels: [LMStudioModelOption(modelID: "llama", label: "llama")]),
            .claude: LLMProviderDetection.Presence(installed: false, state: .unavailable("CLI unavailable")),
            .codex: LLMProviderDetection.Presence(installed: false,
                                                  state: .unavailable("the codex CLI is not installed")),
        ]
        reporter.record("a presence with no per-app breakdown is offered LM Studio's model, as in 1.1.0",
                        transcript(realPolicy(.email, handBuilt, .ollama, mac16)) == email)
    }

    private static func checkFit(_ policy: Policy, _ reporter: SelfTestReporter) {
        let machines: [(String, [LLMProvider: LLMProviderDetection.Presence], LocalBackendID?)] = [
            ("neither app", machine(lmStudio: nil, ollama: nil), nil),
            ("neither app, Claude", machine(lmStudio: nil, ollama: nil, claude: true), nil),
            ("Ollama only", machine(lmStudio: nil, ollama: []), nil),
            ("Ollama only, Claude", machine(lmStudio: nil, ollama: [], claude: true), nil),
            ("both, Preferred Ollama", machine(lmStudio: ["llama-3.2-1b-instruct"], ollama: ["llama3.2:1b"]), .ollama),
        ]
        let qwen = LocalModelRef(backend: .ollama, modelID: "qwen3-coder:30b")
        var offered: [String] = []
        for (feature, _) in textFeatures {
            for (label, presences, preferred) in machines {
                let offer = policy(feature, presences, preferred, mac16)
                let queued = everyComponent(offer).flatMap(\.localSteps).contains(.model(qwen))
                let pages = (offer?.buttons ?? []) + (offer?.localAppChoice?.buttons ?? [])
                let named = pages.contains { $0.route == .install && $0.title.contains("qwen3-coder:30b") }
                if queued || named { offered.append("\(feature.id) on \(label)") }
            }
        }
        reporter.record(fitCheck, offered.isEmpty, offered.joined(separator: ", "))

        reporter.record("the fit verdict is the first-run window's own (ComponentPicker.availability)",
                        !PointOfUsePolicy.ollamaModelFits(BootstrapInstallPlan.ollamaQwen, facts: mac16)
                            && ComponentPicker.availability(.ollamaQwen, facts: mac16) == .tooLarge
                            && PointOfUsePolicy.ollamaModelFits(BootstrapInstallPlan.ollamaQwen, facts: mac64)
                            && ComponentPicker.availability(.ollamaGemma, facts: mac16) == .tightFit
                            && PointOfUsePolicy.ollamaModelFits(BootstrapInstallPlan.ollamaGemma, facts: mac16))
        if case .install(let tooBig)? = policy(.cleanup, machine(lmStudio: nil, ollama: [], claude: true), nil, mac16) {
            reporter.record("on a 16 GB Ollama Mac, cleanup says its model is too big and only closes",
                            tooBig.components.isEmpty && tooBig.buttons.map(\.route) == [.skip]
                                && tooBig.buttons.map(\.title) == ["Close"]
                                && tooBig.header == "CLEANUP - TOO BIG FOR THIS MAC"
                                && tooBig.lines == ["Cleanup uses qwen3-coder:30b in Ollama, 18.56 GB. "
                                                    + "Your Mac has 16 GB - this model needs more."],
                            (tooBig.lines + tooBig.buttons.map(\.title)).joined(separator: " | "))
        } else {
            reporter.record("on a 16 GB Ollama Mac, cleanup says its model is too big and only closes", false)
        }
        reporter.record("a tight fit is still offered: email on a 16 GB Ollama Mac pulls gemma4:e4b",
                        offerComponents(policy(.email, machine(lmStudio: nil, ollama: [], claude: true), nil, mac16))
                            == [BootstrapInstallPlan.ollamaGemma])
        let smallChoice = policy(.cleanup, machine(lmStudio: nil, ollama: nil), nil, mac16)?.localAppChoice
        reporter.record("on a 16 GB Mac with neither app, cleanup's Ollama option is the app alone and says why",
                        smallChoice?.option(.ollama)?.components == [BootstrapInstallPlan.ollama]
                            && smallChoice?.option(.ollama)?.detail.hasSuffix(
                                "qwen3-coder:30b needs more memory than this Mac can give it, so no model is pulled.")
                                == true,
                        smallChoice?.option(.ollama)?.detail ?? "nil")
        reporter.record("a 64 GB Ollama Mac is offered qwen3-coder:30b for cleanup",
                        offerComponents(policy(.cleanup, machine(lmStudio: nil, ollama: [], claude: true), nil, mac64))
                            == [BootstrapInstallPlan.ollamaQwen])
    }

    // MARK: - Persisted identifiers (literals from 12c0db4's source)

    private static func checkPersistedIdentifiers(scratch: URL, _ reporter: SelfTestReporter) {
        let legacyIDs = ["stt-daemon", "web-search", "lm-studio", "model:google/gemma-4-e4b",
                         "model:qwen3-coder-30b-a3b-instruct-mlx"]
        let all = BootstrapInstallPlan.allComponents.map(\.id)
        reporter.record("every 1.1.0 component id is unchanged and in its place; new rows are appended",
                        Array(all.prefix(legacyIDs.count)) == legacyIDs
                            && Array(all.dropFirst(legacyIDs.count))
                                == ["ollama", "ollama-model:gemma4:e4b", "ollama-model:qwen3-coder:30b"],
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

        // (f) The Ollama choice queues the app and no model: 29e3f47's option.
        let appAlone: Policy = { feature, presences, preferred, facts in
            mapChoice(realPolicy(feature, presences, preferred, facts)) { choice in
                PointOfUseLocalAppChoice(header: choice.header, lines: choice.lines, options: choice.options.map {
                    PointOfUseLocalAppOption(backend: $0.backend, title: $0.title, label: $0.label,
                                             recommended: $0.recommended, detail: $0.detail, warning: $0.warning,
                                             components: $0.backend == .ollama ? [BootstrapInstallPlan.ollama]
                                                 : $0.components,
                                             button: $0.button)
                })
            }
        }
        requireCaught(reporter, mutant: "Ollama choice that queues no model", by: ollamaChoiceModelCheck) {
            checkOllamaChoiceModel(appAlone, scratch: scratch, $0)
        }
        // (g) An Ollama-only Mac offered LM Studio and its model: what 29e3f47 offered it.
        let lmStudioAlways: Policy = { feature, _, _, _ in
            .install(PointOfUsePolicy.installOffer(for: feature, outstanding: feature.components))
        }
        requireCaught(reporter, mutant: "Ollama-only Mac offered LM Studio", by: ollamaOnlyCheck) {
            checkOllamaOnly(lmStudioAlways, $0)
        }
        // (h) The Ollama pull offered with no fit check: the policy never told this Mac's memory.
        let noFitCheck: Policy = { feature, presences, preferred, _ in
            realPolicy(feature, presences, preferred, nil)
        }
        requireCaught(reporter, mutant: "Ollama pull with no fit check", by: fitCheck) {
            checkFit(noFitCheck, $0)
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
