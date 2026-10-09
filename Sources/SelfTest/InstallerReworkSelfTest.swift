import Cocoa

/// The installer-rework chain's gate arms (`vdinga`, link G1). PROTECTED: no worker may edit this file;
/// the broker reverts any attempt. Ten arms, named exactly as the baton's "Gate arms" table, dispatched
/// by `--installer-rework-selftest --only <arm>`, exit 0 only when the named arm passes.
///
/// Every arm drives real production types over scratch state and injected seams - no network, no real
/// launchctl, no real TCC, no on-screen window. `preference-control` is the one arm that must already be
/// GREEN at 42eec8e: it is the control that proves the other nine can actually go red.
enum InstallerReworkSelfTest {
    enum Arm: String, CaseIterable {
        case launchWindow = "launch-window"
        case noLaunchPrompts = "no-launch-prompts"
        case imRequest = "im-request"
        case relaunch
        case noBootstrapBeforeVenv = "no-bootstrap-before-venv"
        case plistAssociated = "plist-associated"
        case unchangedStillLoads = "unchanged-still-loads"
        case setupChoice = "setup-choice"
        case readyStep = "ready-step"
        case preferenceControl = "preference-control"
        case tapLaunch = "tap-launch"
    }

    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--only") else {
            // No --only: the hotkey-tap launch checks are the acceptance gate's default arm.
            return runTapLaunch() ? 0 : 1
        }
        guard i + 1 < arguments.count, let arm = Arm(rawValue: arguments[i + 1]) else {
            let names = Arm.allCases.map(\.rawValue).joined(separator: "|")
            print("[installer-rework-selftest] FAIL: --only <\(names)> is required")
            return 2
        }
        let ok: Bool
        switch arm {
        case .launchWindow: ok = runLaunchWindow()
        case .noLaunchPrompts: ok = runNoLaunchPrompts()
        case .imRequest: ok = runIMRequest()
        case .relaunch: ok = runRelaunch()
        case .noBootstrapBeforeVenv: ok = runNoBootstrapBeforeVenv()
        case .plistAssociated: ok = runPlistAssociated()
        case .unchangedStillLoads: ok = runUnchangedStillLoads()
        case .setupChoice: ok = runSetupChoice()
        case .readyStep: ok = runReadyStep()
        case .preferenceControl: ok = runPreferenceControl()
        case .tapLaunch: ok = runTapLaunch()
        }
        return ok ? 0 : 1
    }

    // MARK: - launch-window

    /// `applicationShouldHandleReopen` must exist and route: incomplete setup -> the setup window,
    /// complete -> Settings. Red at 42eec8e because AppDelegate implements no such selector at all, and
    /// `ReopenRoutingPolicy` - the seam a later link would make real - is still a stub that always
    /// answers `.openSettings` (AppDelegate.swift has no `applicationShouldHandleReopen`;
    /// ReopenRoutingPolicy.swift's `route` ignores `setupComplete`).
    private static func runLaunchWindow() -> Bool {
        print("=== installer-rework — launch-window ===")
        let reporter = SelfTestReporter()

        let selector = #selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:))
        reporter.record("AppDelegate implements applicationShouldHandleReopen",
                       AppDelegate.instancesRespond(to: selector))

        reporter.record(
            "reopening with setup incomplete routes to the setup window, not Settings",
            ReopenRoutingPolicy.route(setupComplete: false) == .openSetupWindow,
            "\(ReopenRoutingPolicy.route(setupComplete: false))")
        reporter.record(
            "reopening with setup complete routes to Settings",
            ReopenRoutingPolicy.route(setupComplete: true) == .openSettings,
            "\(ReopenRoutingPolicy.route(setupComplete: true))")

        reporter.record(
            "a fresh install's launch presents a window",
            FirstRunSetupLaunchRule.shouldPresent(
                .init(snapshot: .fresh(), earlierCoreOnDisk: false)))

        return finish(reporter, prefix: "installer-rework launch-window")
    }

    // MARK: - no-launch-prompts

    /// A fresh-install launch path must issue ZERO permission requests before the setup window explains
    /// them. Red at 42eec8e because `AppDelegate.swift`'s `requestPermissions()` (called unconditionally
    /// from `applicationDidFinishLaunching`) always requests all three, and `LaunchPermissionPolicy`'s
    /// stub (`shouldRequestAtLaunch`) always answers true regardless of whether setup is about to show.
    private static func runNoLaunchPrompts() -> Bool {
        print("=== installer-rework — no-launch-prompts ===")
        let reporter = SelfTestReporter()

        let spy = PermissionRequestSpy()
        let requester = LaunchPermissionRequester(
            accessibility: { prompt in spy.record("accessibility", prompt: prompt); return false },
            inputMonitoring: { prompt in spy.record("inputMonitoring", prompt: prompt); return false },
            microphone: { completion in spy.record("microphone", prompt: true); completion(false) })

        let shouldRequest = LaunchPermissionPolicy.shouldRequestAtLaunch(setupWindowWillShow: true)
        _ = LaunchPermissionSequence.run(shouldRequest: shouldRequest, requester: requester)

        reporter.record(
            "a fresh-install launch (setup window about to show) issues zero permission requests",
            spy.calls.isEmpty, spy.calls.joined(separator: ","))

        return finish(reporter, prefix: "installer-rework no-launch-prompts")
    }

    private final class PermissionRequestSpy {
        private(set) var calls: [String] = []
        func record(_ name: String, prompt: Bool) { calls.append("\(name)(prompt:\(prompt))") }
    }

    // MARK: - tap-launch

    /// The hotkey-tap launch defect (Ben, 2026-10-08): a launch whose first-run Setup window shows must
    /// STILL arm the tap when Accessibility and Input Monitoring are already granted, checked silently
    /// (no prompt, no Microphone request). When either is missing it must do exactly what it did before:
    /// prompt nothing and leave the explanation to the Setup window. A launch with no Setup window keeps
    /// the old full prompting sequence. `LaunchPermissionPolicy.shouldStartControllerWithoutPrompt` is
    /// the pure decision; `LaunchPermissionSequence.runLaunch` is the injectable wiring.
    private static func runTapLaunch() -> Bool {
        print("=== installer-rework — tap-launch ===")
        let reporter = SelfTestReporter()

        // (a) Setup window will show + both grants present -> start, with no prompting and no mic.
        do {
            let spy = TapLaunchRequesterSpy(accessibility: true, inputMonitoring: true)
            var started = 0
            LaunchPermissionSequence.runLaunch(
                setupWindowWillShow: true,
                requester: spy.requester,
                startController: { started += 1 },
                setStatus: { _ in })
            reporter.record(
                "tap-launch: setup window + both grants starts the controller",
                started == 1, "started=\(started)")
            reporter.record(
                "tap-launch: setup window + both grants checks accessibility silently",
                spy.accessibilityPrompts == [false], "\(spy.accessibilityPrompts)")
            reporter.record(
                "tap-launch: setup window + both grants checks input monitoring silently",
                spy.inputMonitoringPrompts == [false], "\(spy.inputMonitoringPrompts)")
            reporter.record(
                "tap-launch: setup window + both grants never requests the microphone",
                spy.microphoneCalls == 0, "calls=\(spy.microphoneCalls)")
        }

        // (b) Setup window will show + Accessibility missing -> no start, no prompt at all.
        do {
            let spy = TapLaunchRequesterSpy(accessibility: false, inputMonitoring: true)
            var started = 0
            LaunchPermissionSequence.runLaunch(
                setupWindowWillShow: true,
                requester: spy.requester,
                startController: { started += 1 },
                setStatus: { _ in })
            reporter.record(
                "tap-launch: setup window + accessibility missing does not start the controller",
                started == 0, "started=\(started)")
            reporter.record(
                "tap-launch: setup window + accessibility missing never prompts",
                spy.promptingCalls == 0 && spy.microphoneCalls == 0,
                "prompts=\(spy.promptingCalls) mic=\(spy.microphoneCalls)")
        }

        // (c) Setup window will show + Input Monitoring missing -> no start, no prompt at all.
        do {
            let spy = TapLaunchRequesterSpy(accessibility: true, inputMonitoring: false)
            var started = 0
            LaunchPermissionSequence.runLaunch(
                setupWindowWillShow: true,
                requester: spy.requester,
                startController: { started += 1 },
                setStatus: { _ in })
            reporter.record(
                "tap-launch: setup window + input monitoring missing does not start the controller",
                started == 0, "started=\(started)")
            reporter.record(
                "tap-launch: setup window + input monitoring missing never prompts",
                spy.promptingCalls == 0 && spy.microphoneCalls == 0,
                "prompts=\(spy.promptingCalls) mic=\(spy.microphoneCalls)")
        }

        // (d) No Setup window + both grants -> the old full request sequence, prompts allowed.
        do {
            let spy = TapLaunchRequesterSpy(accessibility: true, inputMonitoring: true)
            var started = 0
            LaunchPermissionSequence.runLaunch(
                setupWindowWillShow: false,
                requester: spy.requester,
                startController: { started += 1 },
                setStatus: { _ in })
            reporter.record(
                "tap-launch: no setup window + both grants runs the old full request sequence",
                spy.accessibilityPrompts == [true] && spy.inputMonitoringPrompts == [true]
                    && spy.microphoneCalls == 1,
                "ax=\(spy.accessibilityPrompts) im=\(spy.inputMonitoringPrompts) mic=\(spy.microphoneCalls)")
            reporter.record(
                "tap-launch: no setup window + both grants starts the controller",
                started == 1, "started=\(started)")
        }

        // (e) No Setup window + a grant missing -> no start, the old status text.
        do {
            let spy = TapLaunchRequesterSpy(accessibility: false, inputMonitoring: true)
            var started = 0
            var status = ""
            LaunchPermissionSequence.runLaunch(
                setupWindowWillShow: false,
                requester: spy.requester,
                startController: { started += 1 },
                setStatus: { status = $0 })
            reporter.record(
                "tap-launch: no setup window + missing grant does not start the controller",
                started == 0, "started=\(started)")
            reporter.record(
                "tap-launch: no setup window + missing grant keeps the old status text",
                status == "Dictation: grant Accessibility + Input Monitoring, then relaunch", status)
        }

        // (f) The decision is pure (same inputs, same output; no global state).
        let first = LaunchPermissionPolicy.shouldStartControllerWithoutPrompt(
            setupWindowWillShow: true, accessibilityGranted: true, inputMonitoringGranted: true)
        let second = LaunchPermissionPolicy.shouldStartControllerWithoutPrompt(
            setupWindowWillShow: true, accessibilityGranted: true, inputMonitoringGranted: true)
        reporter.record(
            "tap-launch: shouldStartControllerWithoutPrompt is pure",
            first == second && first == true, "first=\(first) second=\(second)")
        let truthTable: [(show: Bool, ax: Bool, im: Bool, expected: Bool)] = [
            (true, true, true, true),
            (true, false, true, false),
            (true, true, false, false),
            (false, true, true, false),
        ]
        let tableMatches = truthTable.allSatisfy { row in
            LaunchPermissionPolicy.shouldStartControllerWithoutPrompt(
                setupWindowWillShow: row.show, accessibilityGranted: row.ax,
                inputMonitoringGranted: row.im) == row.expected
        }
        reporter.record(
            "tap-launch: controller starts only when setup shows and both grants are present",
            tableMatches, "matches=\(tableMatches)")

        return finish(reporter, prefix: "installer-rework tap-launch")
    }

    /// Records every Accessibility/Input-Monitoring read (with its prompt flag) and every Microphone
    /// request against a scripted grant, so a check can prove the setup-window path neither prompts nor
    /// touches the microphone while the no-setup path still does.
    private final class TapLaunchRequesterSpy {
        private let accessibilityResult: Bool
        private let inputMonitoringResult: Bool
        private(set) var accessibilityPrompts: [Bool] = []
        private(set) var inputMonitoringPrompts: [Bool] = []
        private(set) var microphoneCalls = 0

        init(accessibility: Bool, inputMonitoring: Bool) {
            self.accessibilityResult = accessibility
            self.inputMonitoringResult = inputMonitoring
        }

        var promptingCalls: Int {
            accessibilityPrompts.filter { $0 }.count + inputMonitoringPrompts.filter { $0 }.count
        }

        var requester: LaunchPermissionRequester {
            LaunchPermissionRequester(
                accessibility: { [unowned self] prompt in
                    self.accessibilityPrompts.append(prompt)
                    return self.accessibilityResult
                },
                inputMonitoring: { [unowned self] prompt in
                    self.inputMonitoringPrompts.append(prompt)
                    return self.inputMonitoringResult
                },
                microphone: { [unowned self] completion in
                    self.microphoneCalls += 1
                    completion(false)
                })
        }
    }

    // MARK: - im-request

    /// Pressing Grant on Input Monitoring must call the real listen-event request API. Red at 42eec8e
    /// because `PermissionsGrant.action(for:microphoneAuthorization:)` always answers `.openSettings` for
    /// Input Monitoring (PermissionsSetup.swift), and `perform()`'s `.openSettings` branch never calls
    /// the new `requestInputMonitoring` seam - it only opens the deep link.
    private static func runIMRequest() -> Bool {
        print("=== installer-rework — im-request ===")
        let reporter = SelfTestReporter()

        let action = PermissionsGrant.action(for: .inputMonitoring, microphoneAuthorization: .authorized)
        var requestCalls = 0
        var openedSettings = false
        _ = PermissionsGrant.perform(
            action,
            opener: { _ in openedSettings = true; return true },
            requestInputMonitoring: { requestCalls += 1; return true })

        reporter.record(
            "pressing Grant on Input Monitoring calls the listen-event request API",
            requestCalls == 1, "calls=\(requestCalls)")
        reporter.record(
            "(context) today it only opens the Input Monitoring settings deep link", openedSettings)

        return finish(reporter, prefix: "installer-rework im-request")
    }

    // MARK: - relaunch

    /// With Accessibility and Input Monitoring both granted after launch while this launch's tap is not
    /// live, the walkthrough must either re-arm the tap or expose a one-click relaunch. Red at 42eec8e
    /// because neither exists: `PostLaunchGrantPolicy.respond` always answers `.none`
    /// (PostLaunchGrantPolicy.swift), and no production call site ever invokes `AppRelauncher`.
    private static func runRelaunch() -> Bool {
        print("=== installer-rework — relaunch ===")
        let reporter = SelfTestReporter()

        let response = PostLaunchGrantPolicy.respond(
            accessibilityGranted: true, inputMonitoringGranted: true, tapLive: false)
        reporter.record(
            "granting AX+IM after launch re-arms the tap or offers a relaunch",
            response == .reArmTap || response == .offerRelaunch, "\(response)")

        var relaunchCalls = 0
        let relauncher = AppRelauncher(relaunch: { relaunchCalls += 1 })
        switch response {
        case .offerRelaunch:
            relauncher.relaunch()
            reporter.record(
                "offerRelaunch invokes the injected relauncher exactly once",
                relaunchCalls == 1, "calls=\(relaunchCalls)")
        case .reArmTap:
            reporter.record(
                "reArmTap never calls the relauncher", relaunchCalls == 0, "calls=\(relaunchCalls)")
        case .none:
            break
        }

        // Once already live, nothing further should be offered - the control half of this arm.
        let alreadyLive = PostLaunchGrantPolicy.respond(
            accessibilityGranted: true, inputMonitoringGranted: true, tapLive: true)
        reporter.record("a tap that is already live is offered nothing further",
                       alreadyLive == .none, "\(alreadyLive)")

        return finish(reporter, prefix: "installer-rework relaunch")
    }

    // MARK: - no-bootstrap-before-venv

    /// Launch-time daemon install with no `stt-venv/bin/python` must never call `restartAgent` (which is
    /// what bootstraps and kickstarts the whisperd agent); with python present it may. `DaemonInstaller`
    /// is already fully injectable (home directory, resource directory, restart action), so no new
    /// production seam is needed - this arm is red purely because `DaemonInstaller.swift`'s `install()`
    /// calls `restartAgent()` unconditionally after any write, with no venv check at all.
    private static func runNoBootstrapBeforeVenv() -> Bool {
        print("=== installer-rework — no-bootstrap-before-venv ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default

        guard let scratch = makeScratch("no-venv") else {
            reporter.record("a scratch directory can be created", false)
            return finish(reporter, prefix: "installer-rework no-bootstrap-before-venv")
        }
        defer { try? fm.removeItem(at: scratch) }

        // (1) No venv at all: a fresh account's very first launch-time write.
        let noVenvHome = scratch.appendingPathComponent("no-venv-home", isDirectory: true)
        let resources = scratch.appendingPathComponent("res", isDirectory: true)
        guard stageBundledDaemon(into: resources) else {
            reporter.record("the real bundled daemon copies into the scratch resource directory", false)
            return finish(reporter, prefix: "installer-rework no-bootstrap-before-venv")
        }
        let noVenvSpy = RestartSpy()
        let noVenvInstaller = DaemonInstaller(homeDirectory: noVenvHome, resourceDirectory: resources,
                                              restartAgent: { noVenvSpy.restart() })
        _ = noVenvInstaller.install()
        reporter.record(
            "a fresh write with no stt-venv/bin/python never restarts the agent",
            noVenvSpy.count == 0, "restarts=\(noVenvSpy.count)")

        // (2) venv/python present: the same write may restart (it already does, and that is fine).
        let withVenvHome = scratch.appendingPathComponent("with-venv-home", isDirectory: true)
        let venvPython = withVenvHome
            .appendingPathComponent("Library/Application Support/ViddyDictate/stt-venv/bin/python")
        do {
            try fm.createDirectory(at: venvPython.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            fm.createFile(atPath: venvPython.path, contents: Data())
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                                 ofItemAtPath: venvPython.path)
        } catch {
            reporter.record("a fixture venv python can be staged", false, String(describing: error))
            return finish(reporter, prefix: "installer-rework no-bootstrap-before-venv")
        }
        let withVenvSpy = RestartSpy()
        let withVenvInstaller = DaemonInstaller(homeDirectory: withVenvHome, resourceDirectory: resources,
                                                restartAgent: { withVenvSpy.restart() })
        _ = withVenvInstaller.install()
        reporter.record(
            "(context) with the venv already built, a fresh write may still restart",
            withVenvSpy.count == 1, "restarts=\(withVenvSpy.count)")

        return finish(reporter, prefix: "installer-rework no-bootstrap-before-venv")
    }

    private final class RestartSpy {
        private(set) var count = 0
        func restart() { count += 1 }
    }

    // MARK: - plist-associated

    /// The bundled whisperd plist must carry `AssociatedBundleIdentifiers` containing
    /// `com.viddydictate.app`, so macOS 13+ lists the background item as ViddyDictate rather than
    /// "python". Red at 42eec8e because the key is absent from `com.viddydictate.whisperd.plist`.
    private static func runPlistAssociated() -> Bool {
        print("=== installer-rework — plist-associated ===")
        let reporter = SelfTestReporter()

        guard let root = repositoryRoot() else {
            reporter.record("the repository root is reachable from the test bundle path", false,
                            Bundle.main.bundleURL.path)
            return finish(reporter, prefix: "installer-rework plist-associated")
        }
        let plistURL = root.appendingPathComponent("com.viddydictate.whisperd.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any]
        else {
            reporter.record("com.viddydictate.whisperd.plist parses as a property list", false,
                            plistURL.path)
            return finish(reporter, prefix: "installer-rework plist-associated")
        }

        let associated = dictionary["AssociatedBundleIdentifiers"] as? [String] ?? []
        reporter.record(
            "the whisperd plist's AssociatedBundleIdentifiers names com.viddydictate.app",
            associated.contains("com.viddydictate.app"), "\(associated)")

        return finish(reporter, prefix: "installer-rework plist-associated")
    }

    // MARK: - unchanged-still-loads

    /// The post-setup STT install path must call the agent-ensure-loaded hook even when
    /// `daemonInstaller()` reports `.unchanged` - the common case once a launch-time write already wrote
    /// an identical script. Red at 42eec8e because `InstallerEngine.install(descriptor:)`'s switch over
    /// the daemon-install result (InstallerEngine.swift, the `case .installed, .upgraded, .unchanged:
    /// break` arm) never calls the new `daemonAgentEnsureLoaded` seam for any case.
    private static func runUnchangedStillLoads() -> Bool {
        print("=== installer-rework — unchanged-still-loads ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default

        guard let scratch = makeScratch("unchanged") else {
            reporter.record("a scratch directory can be created", false)
            return finish(reporter, prefix: "installer-rework unchanged-still-loads")
        }
        defer { try? fm.removeItem(at: scratch) }

        // A venv that is already fully built, so the STT row's venv/pip/model-artifact branch is a no-op
        // and the engine falls straight through to the daemon-install check - no real pip, no network.
        let support = scratch.appendingPathComponent("support", isDirectory: true)
        let venvPython = support.appendingPathComponent("stt-venv/bin/python")
        do {
            try fm.createDirectory(at: venvPython.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            fm.createFile(atPath: venvPython.path, contents: Data())
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                                 ofItemAtPath: venvPython.path)
        } catch {
            reporter.record("a fixture venv can be staged", false, String(describing: error))
            return finish(reporter, prefix: "installer-rework unchanged-still-loads")
        }

        var ensureLoadedCalls = 0
        let engine = InstallerEngine(
            paths: InstallerPaths(python: URL(fileURLWithPath: "/bin/sh"),
                                  applicationSupport: support,
                                  modelCache: scratch.appendingPathComponent("model-cache", isDirectory: true),
                                  packageCache: scratch.appendingPathComponent("package-cache", isDirectory: true)),
            daemonInstaller: { .unchanged },
            daemonAgentEnsureLoaded: { ensureLoadedCalls += 1 })

        // No packages, no model artifacts: the STT row's own venv step is already satisfied above, so
        // this never shells out to pip or huggingface_hub.
        let descriptor = InstallerComponentDescriptor(
            id: BootstrapInstallPlan.sttDaemon.id, title: "Speech-to-text",
            virtualEnvironmentRelativePath: "stt-venv")
        let result = engine.install(descriptor)

        reporter.record("the row installs cleanly (the venv/pip branch is a no-op in this fixture)",
                       result.succeeded, "\(result.state)")
        reporter.record(
            "an .unchanged daemon-install result still ensures the agent is loaded",
            ensureLoadedCalls == 1, "calls=\(ensureLoadedCalls)")

        return finish(reporter, prefix: "installer-rework unchanged-still-loads")
    }

    // MARK: - setup-choice

    /// The first screen must offer exactly Recommended / Advanced / Dictation-only, each mapping to the
    /// right install selection, and no choice's plan may contain a Codex component. Red at 42eec8e
    /// because `FirstRunSetupFlow.setupChoices()` is an empty stub - there is no welcome/choose screen at
    /// all (FirstRunSetupFlow.swift).
    private static func runSetupChoice() -> Bool {
        print("=== installer-rework — setup-choice ===")
        let reporter = SelfTestReporter()

        let choices = FirstRunSetupFlow.setupChoices()
        reporter.record(
            "the welcome screen offers exactly Recommended, Advanced, Dictation-only, in that order",
            choices == [.recommended, .advanced, .dictationOnly], "\(choices)")

        let facts = ComponentPicker.MachineFacts(
            physicalBytes: 64 * 1_073_741_824, budgetBytes: 30_000_000_000,
            maxBudgetBytes: 40_000_000_000, wiredBytes: 5_000_000_000)
        let environment = ComponentPicker.Environment()

        let recommended = FirstRunSetupFlow.plan(for: .recommended, facts: facts, environment: environment)
        reporter.record("Recommended maps to LM Studio plus the models that fit",
                       recommended.lmStudio == true, "\(recommended)")

        let dictationOnly = FirstRunSetupFlow.plan(for: .dictationOnly, facts: facts, environment: environment)
        reporter.record("Dictation-only maps to the core alone, no local-model app",
                       dictationOnly.lmStudio == false && dictationOnly.ollama == false
                           && dictationOnly.models.isEmpty && dictationOnly.ollamaModels.isEmpty,
                       "\(dictationOnly)")

        var codexFound: [String] = []
        for choice in FirstRunSetupFlow.SetupChoice.allCases {
            let plan = FirstRunSetupFlow.plan(for: choice, facts: facts, environment: environment)
            for descriptor in plan.queue
            where descriptor.id.lowercased().contains("codex")
                || descriptor.title.lowercased().contains("codex") {
                codexFound.append("\(choice): \(descriptor.id)")
            }
        }
        reporter.record("no choice's plan contains a Codex component",
                       codexFound.isEmpty, codexFound.joined(separator: ", "))

        return finish(reporter, prefix: "installer-rework setup-choice")
    }

    // MARK: - ready-step

    /// After install-done and permissions, the window must reach a Ready step with a practice state and
    /// Done, and a failed component must show Resume setup there. Red at 42eec8e because
    /// `FirstRunSetupWindowController.Step` has only picker/permissions/progress
    /// (ComponentPickerView.swift) and `FirstRunSetupFlow.steps()` mirrors that exactly, with no `.ready`.
    private static func runReadyStep() -> Bool {
        print("=== installer-rework — ready-step ===")
        let reporter = SelfTestReporter()

        let steps = FirstRunSetupFlow.steps()
        reporter.record("the flow reaches a Ready step after progress",
                       steps.last == .ready, "\(steps)")
        reporter.record("the flow still shows picker, then permissions, then progress, before Ready",
                       steps.starts(with: [.picker, .permissions, .progress]), "\(steps)")

        return finish(reporter, prefix: "installer-rework ready-step")
    }

    // MARK: - preference-control (the control arm: must be green now)

    /// The EXISTING first-run behaviour that must stay intact: LM Studio is the default local app, a
    /// model that does not fit is never pre-ticked, and closing the window does not cancel the install.
    /// All three are already true at 42eec8e.
    private static func runPreferenceControl() -> Bool {
        print("=== installer-rework — preference-control (control) ===")
        let reporter = SelfTestReporter()

        reporter.record("LM Studio is the default local app when neither app is already installed",
                       ComponentPicker.defaultLocalApp(environment: ComponentPicker.Environment())
                           == .lmStudio)

        // An 8 GB Mac with little free RAM: qwen3-coder (17+ GB) cannot fit even at the budget ceiling.
        let tooSmall = ComponentPicker.MachineFacts(
            physicalBytes: 8 * 1_073_741_824, budgetBytes: 3_500_000_000,
            maxBudgetBytes: 4_500_000_000, wiredBytes: 3_000_000_000)
        let availability = ComponentPicker.availability(.qwen, facts: tooSmall)
        let selection = ComponentPicker.defaultSelection(facts: tooSmall, environment: ComponentPicker.Environment())
        reporter.record(
            "a model that does not fit this machine is offered, never pre-ticked",
            availability == .tooLarge && selection.qwen == false,
            "availability=\(availability) ticked=\(selection.qwen)")

        reporter.record(
            "closing the first-run setup window dismisses it rather than cancelling the install",
            presenterClosedDismissesNotCancels())

        return finish(reporter, prefix: "installer-rework preference-control")
    }

    /// `FirstRunSetupPresenter.closed()` is private (B9: closing is not cancelling), so there is no public
    /// seam that calls it without driving a real AppKit window close. This reads the method's own body by
    /// brace-matching from its declaration, the same way `WhisperdAgentLoadSelfTest` proves a production
    /// call site: a structural fact about which function is invoked, not a copy string.
    private static func presenterClosedDismissesNotCancels() -> Bool {
        guard let root = repositoryRoot(),
              let source = try? String(
                contentsOf: root.appendingPathComponent("Sources/App/FirstRunSetupPresenter.swift"),
                encoding: .utf8),
              let body = functionBody(named: "closed", in: source)
        else { return false }
        return body.contains("coordinator.dismiss()") && !body.contains("coordinator.cancel()")
    }

    /// The body of `func <name>(...) { ... }`, by counting braces from the matching open brace. Returns
    /// nil if the function cannot be found or its braces never balance.
    private static func functionBody(named name: String, in source: String) -> String? {
        guard let range = source.range(of: "func \(name)(") else { return nil }
        guard let openBrace = source[range.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openBrace)..<index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // MARK: - shared helpers

    private static func finish(_ reporter: SelfTestReporter, prefix: String) -> Bool {
        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: prefix))
        return reporter.passed
    }

    /// `<repo>/build/ViddyDictateTests.app` walked up to the directory holding the daemon script, the
    /// same technique `DaemonInstallSelfTest` and `WhisperdAgentLoadSelfTest` use.
    private static func repositoryRoot() -> URL? {
        let fm = FileManager.default
        var directory = Bundle.main.bundleURL
        for _ in 0..<12 {
            if fm.fileExists(atPath: directory.appendingPathComponent("viddydictate_whisperd.py").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func makeScratch(_ label: String) -> URL? {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent("viddydictate-installer-rework-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Copy the REAL bundled `daemon/` directory into a scratch resource root, the same technique
    /// `DaemonInstallSelfTest` uses, so the installer under test reads exactly the bytes the build stages.
    private static func stageBundledDaemon(into resourceDirectory: URL) -> Bool {
        let fm = FileManager.default
        guard let bundled = Bundle.main.resourceURL?
                .appendingPathComponent("daemon", isDirectory: true),
              fm.fileExists(atPath: bundled.path) else { return false }
        do {
            try fm.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
            try fm.copyItem(at: bundled,
                            to: resourceDirectory.appendingPathComponent("daemon", isDirectory: true))
            return true
        } catch {
            return false
        }
    }
}
