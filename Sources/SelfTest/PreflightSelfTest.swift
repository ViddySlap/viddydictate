import Foundation

/// Pure coverage for first-run preflight (Public V1 spec W5): every failure mode produces a specific,
/// actionable message, and preflight warns without ever blocking.
///
/// Every fixture is a synthetic `PreflightObservation`. No daemon, provider, keychain, TCC grant, or live
/// app is consulted, so a green run here means the POLICY is right rather than that this machine happens
/// to be set up. The failure-mode table is derived from the state types themselves (`allCases`, and the
/// daemon's `Kind` discriminator), so adding a new state without a message and a fixture fails this gate
/// rather than shipping an unreachable or unlabelled failure.
enum PreflightSelfTest {

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate first-run preflight - selftest ===")
        let reporter = SelfTestReporter()

        checkCleanMachine(reporter)
        checkEveryFailureModeHasItsOwnMessage(reporter)
        checkDaemonMessages(reporter)
        checkProviderMessages(reporter)
        checkGrantMessages(reporter)
        checkWebSearchMessages(reporter)
        checkWarnNeverBlock(reporter)
        checkDetailIsBounded(reporter)
        checkPurity(reporter)

        print("\n=== RESULT ===")
        print(reporter.passed ? "PREFLIGHT GREEN" : "PREFLIGHT FAILED")
        return reporter.passed
    }

    // MARK: - Fixtures

    private static let fixtureUID: UInt32 = 501

    /// A machine where everything is set up. Every failure fixture is this, with exactly one field
    /// changed, so a message that fires can only have come from the field under test.
    ///
    /// Visible to the module (rather than private) because `PreflightSurfaceSelfTest` asserts that the
    /// SURFACE carries every message this gate proves the POLICY produces. Sharing the table means the two
    /// gates cannot cover different sets of failure modes, and a newly added state lands in both at once.
    static var healthy: PreflightObservation {
        PreflightObservation(
            daemon: .ready(model: "large-v3-turbo"),
            providers: [
                .claude: .init(installed: true, state: .available),
                .codex: .init(installed: true, state: .available),
                .local: .init(installed: true, state: .available),
            ],
            microphone: .granted,
            accessibility: .granted,
            inputMonitoring: .granted,
            webSearchHelperInstalled: true,
            webAnswerKeySource: .keychain,
            launchUserID: fixtureUID)
    }

    /// The worst possible machine: every check failing at once. Shared with the surface gates for the same
    /// reason `healthy` is - one definition of "nothing works" keeps the policy gate, the presentation gate,
    /// and the offscreen render driving the same fixture.
    static var broken: PreflightObservation {
        var observation = healthy
        observation.daemon = .notInstalled
        observation.providers = Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map {
            ($0, LLMProviderDetection.Presence(installed: false, state: .unavailable("absent")))
        })
        observation.microphone = .notGranted
        observation.accessibility = .notGranted
        observation.inputMonitoring = .notGranted
        observation.webSearchHelperInstalled = false
        observation.webAnswerKeySource = nil
        return observation
    }

    /// A sample observation per daemon state. Written as a switch over `Kind` so a new daemon case cannot
    /// compile without landing here, which is what keeps the failure-mode table honest.
    private static func daemonSample(_ kind: PreflightDaemonState.Kind) -> PreflightDaemonState {
        switch kind {
        case .notInstalled: return .notInstalled
        case .unreachable: return .unreachable("Could not connect to the server.")
        case .loading: return .loading("loading")
        case .ready: return .ready(model: "large-v3-turbo")
        }
    }

    private static func observation(daemon: PreflightDaemonState) -> PreflightObservation {
        var o = healthy; o.daemon = daemon; return o
    }

    private static func observation(providers: [LLMProvider: LLMProviderDetection.Presence])
        -> PreflightObservation {
        var o = healthy; o.providers = providers; return o
    }

    private static func finding(_ check: PreflightCheck,
                                _ observation: PreflightObservation) -> PreflightFinding {
        // A missing finding is itself a failure; a placeholder keeps the rest of the run reporting.
        Preflight.evaluate(observation).finding(check)
            ?? PreflightFinding(check: check, severity: .ok, summary: "MISSING",
                                remedy: nil, reducedFunction: nil)
    }

    /// Every failure mode this gate knows about, as (label, check, observation). One row per state a user
    /// can actually be in. Shared with `PreflightSurfaceSelfTest`; see `healthy`.
    static var failureModes: [(label: String, check: PreflightCheck, obs: PreflightObservation)] {
        var rows: [(String, PreflightCheck, PreflightObservation)] = []

        for kind in PreflightDaemonState.Kind.allCases where kind != .ready {
            rows.append(("daemon.\(kind.rawValue)", .sttDaemon, observation(daemon: daemonSample(kind))))
        }

        // The provider check fails only when NO provider can run, so its failure modes are the shapes the
        // combined message has to distinguish, not one row per provider.
        for (label, providers) in providerFailureFixtures {
            rows.append(("provider.\(label)", .textProvider, observation(providers: providers)))
        }

        for grant in PreflightGrant.allCases where grant != .granted {
            var mic = healthy; mic.microphone = grant
            rows.append(("microphone.\(grant.rawValue)", .microphone, mic))
        }
        var ax = healthy; ax.accessibility = .notGranted
        rows.append(("accessibility.notGranted", .accessibility, ax))
        var im = healthy; im.inputMonitoring = .notGranted
        rows.append(("inputMonitoring.notGranted", .inputMonitoring, im))

        var helper = healthy; helper.webSearchHelperInstalled = false
        rows.append(("webSearchHelper.missing", .webSearchHelper, helper))
        var key = healthy; key.webAnswerKeySource = nil
        rows.append(("webAnswerKey.absent", .webAnswerKey, key))

        return rows.map { (label: $0.0, check: $0.1, obs: $0.2) }
    }

    private static let providerFailureFixtures: [(String, [LLMProvider: LLMProviderDetection.Presence])] = [
        ("noneInstalled", [
            .claude: .init(installed: false, state: .unavailable("CLI unavailable")),
            .codex: .init(installed: false, state: .unavailable("the codex CLI is not installed")),
            .local: .init(installed: false, state: .unavailable("LM Studio is not installed")),
        ]),
        ("allInstalledSignedOut", [
            .claude: .init(installed: true, state: .disconnected),
            .codex: .init(installed: true, state: .disconnected),
            .local: .init(installed: true, state: .unavailable("LM Studio is not running")),
        ]),
        ("mixed", [
            .claude: .init(installed: false, state: .unavailable("CLI unavailable")),
            .codex: .init(installed: true, state: .disconnected),
            .local: .init(installed: true, state: .unavailable("LM Studio is not running")),
        ]),
        // The nothing-measured fixture is deliberately NOT here: it is the same observable state as
        // `noneInstalled` (nothing is installed), so it renders the same row by design and belongs in the
        // dedicated check that asserts it is not read as a silent green, not in the distinctness table.
    ]

    // MARK: - Checks

    private static func checkCleanMachine(_ check: SelfTestReporter) {
        print("--- a fully set-up machine reports clean ---")
        let report = Preflight.evaluate(healthy)
        check("a healthy observation produces no warnings", report.isClean)
        check("every check is reported even when it passes",
              report.findings.map(\.check) == PreflightCheck.allCases)
        check("a passing check carries no remedy and no reduced-function claim",
              report.findings.allSatisfy { $0.remedy == nil && $0.reducedFunction == nil })
        check("every passing check still explains what it found",
              report.findings.allSatisfy { !$0.summary.isEmpty })
        check("the clean report's log token names no warnings",
              report.logToken == "preflight clean=true warnings=[]")
    }

    private static func checkEveryFailureModeHasItsOwnMessage(_ check: SelfTestReporter) {
        print("--- one specific, actionable message per failure mode ---")
        let modes = failureModes

        check("every check has at least one failure fixture",
              Set(modes.map(\.check)) == Set(PreflightCheck.allCases),
              "covered \(Set(modes.map(\.check)).count)/\(PreflightCheck.allCases.count)")

        var rows: [String: String] = [:]
        var everyModeWarns = true
        var everyWarningIsActionable = true
        var onlyTheTestedCheckWarns = true

        for mode in modes {
            let report = Preflight.evaluate(mode.obs)
            guard let f = report.finding(mode.check), f.isWarning else {
                everyModeWarns = false
                continue
            }
            if f.remedy?.isEmpty != false || f.reducedFunction?.isEmpty != false || f.summary.isEmpty {
                everyWarningIsActionable = false
            }
            if report.warnings.map(\.check) != [mode.check] { onlyTheTestedCheckWarns = false }
            // The row as a user reads it. Two checks may share a summary (Accessibility and Input
            // Monitoring are both "Not granted to ViddyDictate") without being confusable, because the
            // row is always headed by the check's own title - so distinctness is asserted on what is
            // actually shown, not on one field of it.
            rows[mode.label] = "\(mode.check.title): \(f.summary) FIX: \(f.remedy ?? "")"
        }

        check("every failure mode produces a warning", everyModeWarns)
        check("every warning carries a summary, a remedy, and what stops working",
              everyWarningIsActionable)
        check("one broken thing warns about exactly one thing", onlyTheTestedCheckWarns)
        check("no two failure modes read the same to a user",
              Set(rows.values).count == rows.count,
              "\(Set(rows.values).count) distinct of \(rows.count)")

        // "Actionable" means it names a command, a place, or an explicit thing to do - not that it is
        // merely non-empty. Waiting for a load and re-running the check is a concrete instruction; a
        // remedy that matches nothing here is prose, and prose does not fix a machine.
        let actionTokens = ["./install-daemon.sh", "launchctl kickstart", "System Settings",
                            "./install-websearch-helper.sh", "claude auth login", "Connect",
                            "./scripts/set-gemini-key.sh", "LM Studio", "approve",
                            "run this check again"]
        check("every remedy names a command, a place, or an explicit thing to do",
              rows.values.allSatisfy { row in actionTokens.contains { row.contains($0) } })
    }

    private static func checkDaemonMessages(_ check: SelfTestReporter) {
        print("--- the daemon's three failures send the user to three different places ---")
        let notInstalled = finding(.sttDaemon, observation(daemon: .notInstalled))
        check("a daemon that was never installed is told to install it",
              notInstalled.remedy?.contains("./install-daemon.sh") == true
                && notInstalled.summary.contains(DaemonClient.agentLabel))

        let unreachable = finding(.sttDaemon, observation(daemon: .unreachable("Could not connect.")))
        check("an installed daemon that is not answering is told to kickstart it, with its real domain",
              unreachable.remedy?.contains(
                "launchctl kickstart gui/\(fixtureUID)/\(DaemonClient.agentLabel)") == true)
        check("the socket error is quoted so the user can act on it",
              unreachable.summary.contains("Could not connect."))

        let loading = finding(.sttDaemon, observation(daemon: .loading("loading")))
        check("a daemon that is still loading is told to wait, not to reinstall",
              loading.remedy?.contains("wait") == true
                && loading.remedy?.contains("./install-daemon.sh") != true)

        check("every daemon failure says recording still works and only transcription is lost",
              [notInstalled, unreachable, loading].allSatisfy {
                  $0.reducedFunction?.contains("Recording still works") == true
              })

        let ready = finding(.sttDaemon, observation(daemon: .ready(model: "large-v3-turbo")))
        check("a ready daemon reports the model it is actually running",
              !ready.isWarning && ready.summary.contains("large-v3-turbo"))
    }

    private static func checkProviderMessages(_ check: SelfTestReporter) {
        print("--- signed-out and not-installed get different remedies ---")
        var single = healthy
        // Exactly one provider signed in is sufficient (locked decision 3), including the last rung.
        for present in LLMProvider.allCases {
            single.providers = Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map { provider in
                (provider, LLMProviderDetection.Presence(
                    installed: true,
                    state: provider == present ? .available : .disconnected))
            })
            let f = finding(.textProvider, single)
            check("only \(present.rawValue) signed in is enough for the provider check to pass",
                  !f.isWarning
                    && f.summary.contains(ModelsPowerSettingsView.displayName(for: present)))
        }

        let notInstalled = finding(.textProvider, observation(
            providers: Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map {
                ($0, LLMProviderDetection.Presence(installed: false, state: .unavailable("absent")))
            })))
        check("a provider that is not installed is told to install it",
              notInstalled.summary.contains("Claude is not installed")
                && notInstalled.remedy?.contains("install Claude Code") == true
                && notInstalled.remedy?.contains("install ChatGPT.app") == true)

        let signedOut = finding(.textProvider, observation(
            providers: Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map {
                ($0, LLMProviderDetection.Presence(installed: true, state: .disconnected))
            })))
        check("a provider that is installed but signed out is told to sign in, not to install",
              signedOut.summary.contains("Codex is installed but signed out")
                && signedOut.remedy?.contains(
                    "click Connect beside Codex above on the Setup tab") == true
                && signedOut.remedy?.contains("Models & Power") != true
                && signedOut.remedy?.contains("install ChatGPT.app") != true)

        check("the same provider reads differently when installed than when absent",
              notInstalled.summary != signedOut.summary && notInstalled.remedy != signedOut.remedy)

        // The remedy is a menu because either provider is sufficient and never both.
        check("the remedy offers alternatives rather than a checklist",
              signedOut.remedy?.hasPrefix("do any one of these: ") == true)

        check("losing every provider costs the transforms and explicitly not raw dictation",
              signedOut.reducedFunction?.contains("Raw dictation is unaffected") == true)

        // An unmeasured provider map must not read as signed in.
        let unmeasured = finding(.textProvider, observation(providers: [:]))
        check("a provider nobody measured is never counted as signed in",
              unmeasured.isWarning && unmeasured.summary.contains("not installed"))

        check("providers are listed in the order routing would try them",
              LLMAvailabilityRouting.fallbackOrder == [.claude, .codex, .local]
                && orderOfNames(in: signedOut.summary) == [.claude, .codex, .local])
    }

    private static func orderOfNames(in text: String) -> [LLMProvider] {
        LLMProvider.allCases
            .compactMap { provider -> (LLMProvider, Int)? in
                guard let r = text.range(of: ModelsPowerSettingsView.displayName(for: provider)) else {
                    return nil
                }
                return (provider, text.distance(from: text.startIndex, to: r.lowerBound))
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private static func checkGrantMessages(_ check: SelfTestReporter) {
        print("--- the three TCC grants name their own System Settings pane ---")
        var denied = healthy
        denied.microphone = .notGranted
        denied.accessibility = .notGranted
        denied.inputMonitoring = .notGranted
        let report = Preflight.evaluate(denied)

        check("the microphone remedy names the Microphone pane",
              report.finding(.microphone)?.remedy?.contains(
                "System Settings > Privacy & Security > Microphone") == true)
        check("the accessibility remedy names the Accessibility pane",
              report.finding(.accessibility)?.remedy?.contains(
                "System Settings > Privacy & Security > Accessibility") == true)
        check("the input-monitoring remedy names the Input Monitoring pane",
              report.finding(.inputMonitoring)?.remedy?.contains(
                "System Settings > Privacy & Security > Input Monitoring") == true)
        check("the two relaunch-required grants say to relaunch and the microphone does not",
              report.finding(.accessibility)?.remedy?.contains("reopen ViddyDictate") == true
                && report.finding(.inputMonitoring)?.remedy?.contains("reopen ViddyDictate") == true
                && report.finding(.microphone)?.remedy?.contains("reopen") != true)

        var undetermined = healthy
        undetermined.microphone = .notDetermined
        let notYetAsked = finding(.microphone, undetermined)
        check("a microphone grant that was never requested is not reported as turned off",
              notYetAsked.isWarning
                && notYetAsked.remedy?.contains("System Settings") != true
                && notYetAsked.remedy?.contains("approve") == true)
    }

    private static func checkWebSearchMessages(_ check: SelfTestReporter) {
        print("--- the two web-search halves fail independently ---")
        var noHelper = healthy; noHelper.webSearchHelperInstalled = false
        let helper = finding(.webSearchHelper, noHelper)
        check("a missing helper is told to run the installer",
              helper.remedy?.contains("./install-websearch-helper.sh") == true)
        check("a missing helper says Option+L is lost and Option+G is not",
              helper.reducedFunction?.contains("Option+L") == true
                && helper.reducedFunction?.contains("Option+G), is unaffected") == true)
        check("a missing helper does not also warn about the key",
              Preflight.evaluate(noHelper).warnings.map(\.check) == [.webSearchHelper])

        var noKey = healthy; noKey.webAnswerKeySource = nil
        let key = finding(.webAnswerKey, noKey)
        check("a missing key reuses the secret store's own setup hint",
              key.remedy == SecretStore.Secret.geminiAPIKey.setupHint)
        check("a missing key says Option+G is off and Option+L is not",
              key.reducedFunction?.contains("Option+G") == true
                && key.reducedFunction?.contains("(Option+L) and every other mode are unaffected") == true)
        check("a missing key does not also warn about the helper",
              Preflight.evaluate(noKey).warnings.map(\.check) == [.webAnswerKey])

        for source in [SecretStore.Source.keychain, .environment] {
            var set = healthy; set.webAnswerKeySource = source
            let f = finding(.webAnswerKey, set)
            check("a key resolved from the \(source.rawValue) passes and says so",
                  !f.isWarning && f.summary.contains(source.rawValue))
        }
    }

    private static func checkWarnNeverBlock(_ check: SelfTestReporter) {
        print("--- W5: preflight warns, it never blocks ---")
        check("a blocking severity is not expressible",
              PreflightSeverity.allCases.map(\.rawValue) == ["ok", "warning"])

        // The worst possible machine: every check failing at once.
        let report = Preflight.evaluate(broken)

        check("every check can fail at once and every one of them still only warns",
              report.warnings.count == PreflightCheck.allCases.count
                && report.findings.allSatisfy { $0.severity == .warning })
        check("a totally unconfigured machine still produces a report rather than a refusal",
              report.findings.count == PreflightCheck.allCases.count)

        // W5 forbids a "you may not continue" state, so no message may imply one either.
        let blockingPhrases = ["cannot continue", "before you can use", "you must fix",
                               "not allowed", "disabled until", "required before"]
        let allText = report.findings.flatMap { [$0.summary, $0.remedy ?? "", $0.reducedFunction ?? ""] }
        check("no message tells the user they may not proceed",
              allText.allSatisfy { text in
                  let lower = text.lowercased()
                  return !blockingPhrases.contains { lower.contains($0) }
              })
        check("the log token names every warning and quotes none of their text",
              report.logToken.contains("clean=false")
                && PreflightCheck.allCases.allSatisfy { report.logToken.contains($0.rawValue) }
                && !report.logToken.contains("System Settings"))
    }

    private static func checkDetailIsBounded(_ check: SelfTestReporter) {
        print("--- vendor and daemon text is bounded before it reaches a message ---")
        let runaway = String(repeating: "x", count: 4_000)
        let f = finding(.sttDaemon, observation(daemon: .unreachable(runaway)))
        check("a runaway daemon error is truncated rather than pasted whole",
              f.summary.count < 400 && f.summary.contains("..."))

        let multiline = finding(.sttDaemon, observation(daemon: .loading("line one\nline two\n  line three")))
        check("a multi-line diagnostic is flattened to one line",
              !multiline.summary.contains("\n") && multiline.summary.contains("line one line two line three"))

        var providers = healthy
        providers.providers = [.claude: .init(installed: true, state: .unavailable(runaway)),
                               .codex: .init(installed: false, state: .unavailable("absent")),
                               .local: .init(installed: false, state: .unavailable("absent"))]
        check("a runaway provider reason is bounded the same way",
              finding(.textProvider, providers).summary.count < 600)

        check("text shorter than the bound is passed through untouched",
              Preflight.bounded("loading") == "loading")
    }

    private static func checkPurity(_ check: SelfTestReporter) {
        print("--- evaluation is a pure function of the observation ---")
        let observation = healthy
        check("the same observation evaluates identically twice",
              Preflight.evaluate(observation) == Preflight.evaluate(observation))

        var changed = observation
        changed.webSearchHelperInstalled = false
        let before = Preflight.evaluate(observation).findings
        let after = Preflight.evaluate(changed).findings
        let differing = zip(before, after).filter { $0 != $1 }.map(\.0.check)
        check("changing one measured fact changes exactly one finding", differing == [.webSearchHelper])

        check("re-running over an unchanged observation is stable",
              (0..<3).allSatisfy { _ in Preflight.evaluate(changed) == Preflight.evaluate(changed) })
    }
}
