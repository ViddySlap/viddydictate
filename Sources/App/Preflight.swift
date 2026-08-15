import Foundation

/// First-run and re-runnable preflight: the checks that turn a silent non-working
/// install into a self-diagnosing one.
///
/// Product decision: preflight WARNS, it NEVER BLOCKS. Preflight has no "you may not
/// continue" state and no code path may refuse to dictate because a check failed. That is not a
/// convention here, it is the shape of the type: `PreflightSeverity` has exactly two cases and a
/// blocking verdict is not expressible, so a caller cannot branch on one and a later edit cannot add
/// one without changing this file. Reduced function must also be truthful rather than silent, so every
/// warning carries both the step that fixes it and a plain statement of what stops working until then.
///
/// The judgement is one pure function, `Preflight.evaluate(_:)`, over a `PreflightObservation` of
/// measured facts. The measuring half (`Preflight.observe`) is a separate, deliberately thin
/// transcription of existing accessors. Nothing here surfaces anything: the Settings surface that reads
/// this report is separate so measurement logic and interface presentation stay independent.
enum PreflightCheck: String, CaseIterable {
    case sttDaemon
    case textProvider
    case microphone
    case accessibility
    case inputMonitoring
    case webSearchHelper
    case webAnswerKey

    /// The row label. Kept beside the check identity so the surface link inherits the wording rather
    /// than inventing a second set of names.
    var title: String {
        switch self {
        case .sttDaemon: return "Speech-to-text daemon"
        case .textProvider: return "Text provider sign-in"
        case .microphone: return "Microphone access"
        case .accessibility: return "Accessibility access"
        case .inputMonitoring: return "Input Monitoring access"
        case .webSearchHelper: return "Web-search helper"
        case .webAnswerKey: return "Gemini answer key"
        }
    }
}

/// Two cases, and deliberately no third. See the W5 note above.
enum PreflightSeverity: String, CaseIterable {
    case ok
    case warning
}

struct PreflightFinding: Equatable {
    let check: PreflightCheck
    let severity: PreflightSeverity
    /// What this part of the machine is in right now, in one plain-language line.
    let summary: String
    /// The exact step that fixes it: a command to run or a System Settings path to open. Non-nil for
    /// every warning and nil for every ok, so "a warning always tells you what to do" is checkable.
    let remedy: String?
    /// What stops working until the remedy is applied, and what keeps working regardless. Non-nil for
    /// every warning and nil for every ok.
    let reducedFunction: String?

    var isWarning: Bool { severity == .warning }
}

struct PreflightReport: Equatable {
    /// One finding per check, always every check, in `PreflightCheck.allCases` order. A check is never
    /// omitted because it passed: a status surface that hides the green rows cannot be re-read as proof
    /// that the check actually ran.
    let findings: [PreflightFinding]

    var warnings: [PreflightFinding] { findings.filter(\.isWarning) }
    var isClean: Bool { warnings.isEmpty }

    func finding(_ check: PreflightCheck) -> PreflightFinding? {
        findings.first { $0.check == check }
    }

    /// Content-safe one-line record for the app log. Names which checks warned, never their messages, so
    /// no vendor or daemon diagnostic text reaches the log through this path.
    var logToken: String {
        "preflight clean=\(isClean) warnings=["
            + warnings.map(\.check.rawValue).joined(separator: ",") + "]"
    }
}

// MARK: - Observation

/// The STT daemon's state. `Kind` exists so a self-test can enumerate the failure modes: adding a case
/// below forces a new `Kind` (the `kind` switch is exhaustive), which in turn forces the fixture table
/// that covers it, so a state cannot be added without a message and a fixture.
enum PreflightDaemonState: Equatable {
    /// No LaunchAgent for the daemon and nothing answering: it was never installed.
    case notInstalled
    /// The LaunchAgent is installed but nothing answered on 127.0.0.1:8765.
    case unreachable(String)
    /// It answered and reported itself not ready (cold model load, or its own error).
    case loading(String)
    /// Answered, ready, running `model`.
    case ready(model: String)

    enum Kind: String, CaseIterable {
        case notInstalled, unreachable, loading, ready
    }

    var kind: Kind {
        switch self {
        case .notInstalled: return .notInstalled
        case .unreachable: return .unreachable
        case .loading: return .loading
        case .ready: return .ready
        }
    }
}

/// A TCC grant as preflight can observe it WITHOUT requesting it. `notDetermined` is reachable only for
/// Microphone: the Accessibility and Input Monitoring APIs return a bare Boolean and genuinely cannot
/// tell "never asked" from "turned off", so the collector reports `notGranted` for both rather than
/// guessing which one it is.
enum PreflightGrant: String, CaseIterable {
    case granted
    case notDetermined
    case notGranted
}

/// Everything `evaluate` is allowed to know. Every field is a machine-derived enum, Boolean, or vendor
/// diagnostic string; there is no field a transcript, prompt, or provider response could occupy, so a
/// preflight message cannot carry user content by construction.
struct PreflightObservation: Equatable {
    var daemon: PreflightDaemonState
    var providers: [LLMProvider: LLMProviderDetection.Presence]
    var microphone: PreflightGrant
    var accessibility: PreflightGrant
    var inputMonitoring: PreflightGrant
    var webSearchHelperInstalled: Bool
    /// Where the Gemini key resolved from, or nil when the feature is off. Mirrors `SecretStore`'s own
    /// resolution result rather than re-deriving it.
    var webAnswerKeySource: SecretStore.Source?
    /// The launchd GUI domain's uid, so the daemon remedy is a command the user can paste rather than a
    /// description of one. Carried in the observation to keep `evaluate` pure.
    var launchUserID: UInt32
}

// MARK: - Evaluation (pure)

enum Preflight {

    /// Bound for vendor/daemon diagnostic text quoted into a message. It arrives from outside the app, so
    /// it is flattened to one line and truncated before it can reach a Settings row or the log.
    static let detailLimit = 160

    static func bounded(_ detail: String, limit: Int = detailLimit) -> String {
        let flat = detail
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "..."
    }

    /// The whole judgement, as a pure function of measured facts.
    static func evaluate(_ observation: PreflightObservation) -> PreflightReport {
        PreflightReport(findings: PreflightCheck.allCases.map {
            finding(for: $0, observation)
        })
    }

    private static func ok(_ check: PreflightCheck, _ summary: String) -> PreflightFinding {
        PreflightFinding(check: check, severity: .ok, summary: summary,
                         remedy: nil, reducedFunction: nil)
    }

    private static func warn(_ check: PreflightCheck,
                             _ summary: String,
                             remedy: String,
                             reducedFunction: String) -> PreflightFinding {
        PreflightFinding(check: check, severity: .warning, summary: summary,
                         remedy: remedy, reducedFunction: reducedFunction)
    }

    private static func finding(for check: PreflightCheck,
                                _ observation: PreflightObservation) -> PreflightFinding {
        switch check {
        case .sttDaemon: return daemonFinding(observation)
        case .textProvider: return providerFinding(observation)
        case .microphone: return microphoneFinding(observation.microphone)
        case .accessibility: return accessibilityFinding(observation.accessibility)
        case .inputMonitoring: return inputMonitoringFinding(observation.inputMonitoring)
        case .webSearchHelper: return webSearchHelperFinding(observation.webSearchHelperInstalled)
        case .webAnswerKey: return webAnswerKeyFinding(observation.webAnswerKeySource)
        }
    }

    // MARK: STT daemon

    /// Recording is the app's own capability; transcription is the daemon's. Every daemon warning says so,
    /// because "dictation is broken" and "dictation records but cannot transcribe" send a user to
    /// different places.
    private static let daemonReduced =
        "Recording still works, but nothing can be transcribed until the daemon answers."

    private static func daemonFinding(_ observation: PreflightObservation) -> PreflightFinding {
        switch observation.daemon {
        case .ready(let model):
            return ok(.sttDaemon,
                      "Running and warm on 127.0.0.1:8765 (model \(bounded(model))).")
        case .notInstalled:
            return warn(.sttDaemon,
                        "Not installed: no LaunchAgent for \(DaemonClient.agentLabel) and nothing "
                            + "answering on 127.0.0.1:8765.",
                        remedy: "run ./install-daemon.sh from the ViddyDictate repo - it creates the "
                            + "Python venv, downloads the speech model on first run, and loads the "
                            + "LaunchAgent",
                        reducedFunction: daemonReduced)
        case .unreachable(let detail):
            return warn(.sttDaemon,
                        "Installed, but nothing answered on 127.0.0.1:8765 (\(bounded(detail))).",
                        remedy: "run launchctl kickstart gui/\(observation.launchUserID)/"
                            + "\(DaemonClient.agentLabel) in Terminal, then run this check again",
                        reducedFunction: daemonReduced)
        case .loading(let detail):
            return warn(.sttDaemon,
                        "Answering on 127.0.0.1:8765 but not ready yet (\(bounded(detail))).",
                        remedy: "wait for the speech model to finish loading, then run this check "
                            + "again - a cold load takes about twenty seconds",
                        reducedFunction: daemonReduced)
        }
    }

    // MARK: Text provider

    /// Availability-resolved routing already degrades gracefully when a provider disappears (locked
    /// decision 4), so losing every provider costs the transforms and nothing else. Saying which is the
    /// difference between a user who thinks the app is broken and one who knows dictation still lands.
    private static let providerReduced =
        "Every text transform (cleanup, tighten, summarize, prompt prep, email, and both search modes) "
        + "reports itself off. Raw dictation is unaffected and still lands."

    /// The declared preference order, read from the routing policy rather than restated, so preflight
    /// lists providers in the same order that routing would actually try them.
    private static var providerOrder: [LLMProvider] { LLMAvailabilityRouting.fallbackOrder }

    private static func presence(_ observation: PreflightObservation,
                                 _ provider: LLMProvider) -> LLMProviderDetection.Presence {
        // An unmeasured provider is reported as absent rather than assumed present: silently counting a
        // provider nobody measured as "signed in" is exactly the false green this check exists to avoid.
        observation.providers[provider]
            ?? LLMProviderDetection.Presence(installed: false, state: .unavailable("not measured"))
    }

    private static func providerPhrase(_ provider: LLMProvider,
                                       _ presence: LLMProviderDetection.Presence) -> String {
        let name = ModelsPowerSettingsView.displayName(for: provider)
        if presence.state.canRun { return "\(name) is signed in" }
        guard presence.installed else { return "\(name) is not installed" }
        switch presence.state {
        case .available: return "\(name) is signed in"
        case .disconnected: return "\(name) is installed but signed out"
        case .unavailable(let why): return "\(name) is installed but not usable (\(bounded(why)))"
        }
    }

    /// One concrete step per provider. Which of the two sentences a provider gets is DERIVED from whether
    /// it is installed, never guessed: that is the signed-out versus not-installed split, and it is the
    /// only thing preflight says about it. The onboarding flow built on top of the same distinction is
    /// W4's question and P9's item.
    private static func providerRemedy(_ provider: LLMProvider,
                                       _ presence: LLMProviderDetection.Presence) -> String {
        switch (provider, presence.installed, presence.state.requiresConnection) {
        case (.claude, false, _):
            return "install Claude Code, then run claude auth login"
        case (.claude, true, true):
            return "run claude auth login in Terminal"
        case (.claude, true, false):
            return "use a supported claude.ai subscription connection or choose another provider"
        case (.codex, false, _):
            return "install ChatGPT.app, which ships the codex CLI ViddyDictate signs in through"
        case (.codex, true, true):
            return "click Connect beside Codex above on the Setup tab"
        case (.codex, true, false):
            return "review the reported Codex state or choose another provider"
        case (.local, false, _):
            return "install LM Studio (optional - the cloud providers are the V1 baseline)"
        case (.local, true, _):
            return "start LM Studio so its local server answers"
        }
    }

    private static func providerFinding(_ observation: PreflightObservation) -> PreflightFinding {
        let ordered = providerOrder.map { ($0, presence(observation, $0)) }
        let ready = ordered.filter { $0.1.state.canRun }
        guard ready.isEmpty else {
            let names = ready.map { ModelsPowerSettingsView.displayName(for: $0.0) }
            return ok(.textProvider, "Signed in to \(names.joined(separator: ", ")).")
        }
        // Either provider is sufficient and never both (locked decision 3), so the remedy is a menu of
        // alternatives, not a checklist.
        return warn(.textProvider,
                    "No text provider is available: "
                        + ordered.map { providerPhrase($0.0, $0.1) }.joined(separator: "; ") + ".",
                    remedy: "do any one of these: "
                        + ordered.map { providerRemedy($0.0, $0.1) }.joined(separator: "; "),
                    reducedFunction: providerReduced)
    }

    // MARK: TCC grants

    private static func microphoneFinding(_ grant: PreflightGrant) -> PreflightFinding {
        switch grant {
        case .granted:
            return ok(.microphone, "Granted.")
        case .notDetermined:
            return warn(.microphone,
                        "Not requested yet - macOS has never asked for it.",
                        remedy: "start a dictation once and approve the macOS microphone prompt",
                        reducedFunction: "The first recording pauses on the permission prompt instead "
                            + "of capturing audio.")
        case .notGranted:
            return warn(.microphone,
                        "Turned off for ViddyDictate.",
                        remedy: "open System Settings > Privacy & Security > Microphone and turn "
                            + "ViddyDictate on",
                        reducedFunction: "Dictation cannot record any audio.")
        }
    }

    /// Accessibility and Input Monitoring are both required before the global key tap starts, so losing
    /// either one costs every hotkey rather than one feature. Both remedies end in a relaunch because
    /// these two grants only take effect on the next launch.
    private static let hotkeyReduced =
        "The global hotkeys cannot start, so no dictation hotkey fires. The app itself still opens."

    private static func accessibilityFinding(_ grant: PreflightGrant) -> PreflightFinding {
        guard grant != .granted else { return ok(.accessibility, "Granted.") }
        return warn(.accessibility,
                    "Not granted to ViddyDictate.",
                    remedy: "open System Settings > Privacy & Security > Accessibility, turn "
                        + "ViddyDictate on, then quit and reopen ViddyDictate",
                    reducedFunction: hotkeyReduced)
    }

    private static func inputMonitoringFinding(_ grant: PreflightGrant) -> PreflightFinding {
        guard grant != .granted else { return ok(.inputMonitoring, "Granted.") }
        return warn(.inputMonitoring,
                    "Not granted to ViddyDictate.",
                    remedy: "open System Settings > Privacy & Security > Input Monitoring, turn "
                        + "ViddyDictate on, then quit and reopen ViddyDictate",
                    reducedFunction: hotkeyReduced)
    }

    // MARK: Web search

    private static func webSearchHelperFinding(_ installed: Bool) -> PreflightFinding {
        guard !installed else { return ok(.webSearchHelper, "Installed (venv and helper both present).") }
        return warn(.webSearchHelper,
                    "Not installed: the search venv or its helper script is missing.",
                    remedy: "run ./install-websearch-helper.sh from the ViddyDictate repo",
                    reducedFunction: "Local web search (Option+L) cannot retrieve results. Every other "
                        + "mode, including Gemini answers (Option+G), is unaffected.")
    }

    /// Inside the web-search area on purpose: without the key, Option+G is off. W5's answer requires
    /// reduced function to be truthful rather than silent, and a preflight that reported the helper green
    /// while Option+G was dead would be exactly the silent half-working install this check exists to
    /// catch. `SecretStore` already anticipated preflight reading its resolution.
    private static func webAnswerKeyFinding(_ source: SecretStore.Source?) -> PreflightFinding {
        guard let source = source else {
            return warn(.webAnswerKey,
                        "Not set - no \(SecretStore.Secret.geminiAPIKey.label) in the login keychain "
                            + "or the test override.",
                        remedy: SecretStore.Secret.geminiAPIKey.setupHint,
                        reducedFunction: "Gemini answers (Option+G) report themselves off. Local web "
                            + "search (Option+L) and every other mode are unaffected.")
        }
        return ok(.webAnswerKey, "Set (source \(source.rawValue)).")
    }
}

// MARK: - Live observation

extension Preflight {

    static var daemonAgentPlistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/\(DaemonClient.agentLabel).plist"
    }

    /// Measure the machine, then hand the facts to `evaluate`. Every field below is a direct read of an
    /// accessor that already owns its concept; this half deliberately contains no judgement, so the
    /// deterministic rail's coverage of `evaluate` is coverage of the whole decision.
    ///
    /// Spawns processes and performs a loopback request, so the measuring happens off the calling thread.
    /// The completion runs on whichever background queue finished the health request, NOT on the queue
    /// this was called from and never on the main queue, so a caller that touches UI must hop itself.
    /// Nothing here prompts: the microphone read is the non-requesting one.
    static func observe(completion: @escaping (PreflightObservation) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let providers = LLMProviderDetection.observeAll()
            let helperInstalled = WebSearchBackend.isInstalled
            let keySource = SecretStore.resolveSource(.geminiAPIKey)
            let agentInstalled = FileManager.default.isReadableFile(atPath: daemonAgentPlistPath)

            DaemonClient.healthOutcome { outcome in
                let daemon: PreflightDaemonState
                switch outcome {
                case .ready(let model):
                    daemon = .ready(model: model)
                case .notReady(let detail):
                    daemon = .loading(detail)
                case .unreachable(let detail):
                    // Nothing answered. If the LaunchAgent was never installed that is both the more
                    // likely cause and the more actionable message, so it wins over the socket error.
                    daemon = agentInstalled ? .unreachable(detail) : .notInstalled
                }
                completion(PreflightObservation(
                    daemon: daemon,
                    providers: providers,
                    microphone: grant(Permissions.microphoneAuthorization()),
                    accessibility: Permissions.accessibility(prompt: false) ? .granted : .notGranted,
                    inputMonitoring: Permissions.inputMonitoring(prompt: false) ? .granted : .notGranted,
                    webSearchHelperInstalled: helperInstalled,
                    webAnswerKeySource: keySource,
                    launchUserID: getuid()))
            }
        }
    }

    /// Only Microphone can distinguish "never asked" from "turned off"; see `PreflightGrant`.
    static func grant(_ status: MicrophoneAuthorization) -> PreflightGrant {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .notGranted
        }
    }
}
