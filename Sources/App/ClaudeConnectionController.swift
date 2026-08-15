import Foundation

/// The Claude counterpart to `CodexConnectionController` (spec D1, D3, D5).
///
/// Everything above the `live` mark is pure: it takes measured facts and returns a decision or a string, so
/// the deterministic rail can reach all of the judgement. The live half below performs the measurements and
/// owns the polling loop's real clock, sleep, and cancellation.
///
/// **Why this is not symmetrical with Codex, and must not be made so (D3).** Codex's credential belongs to
/// ViddyDictate's own audited Codex home, so re-running its device login costs the user nothing. Claude's
/// credential is ONE PER MACOS ACCOUNT: `claude auth login` mints a new token and invalidates the old one,
/// which signs out every Claude Code session on the Mac, including a running agent. So this flow refuses to
/// launch a login when the machine is already signed in, and says what it would have cost instead. The app
/// never rotates that credential on its own; it only ever names the command the user can run themselves.
///
/// **Connection state has one owner and it is not this file.** Every reading here comes from
/// `LLMProviderDetection` (L2/D2), and success is established by re-measuring through it - never by reading
/// what the login command printed. Nothing in this file parses vendor prose, and no raw status payload is
/// logged or displayed: the real `claude auth status --json` also carries account identity fields.
enum ClaudeConnectionFlow {

    // MARK: - Pure vocabulary

    /// What the polling loop learned from one status reading.
    enum PollStep: Equatable {
        case connected
        /// A real, well-formed answer that ViddyDictate cannot use (D4). Terminal: signing in again
        /// cannot change it, so the loop stops rather than sending the user round a loop.
        case unusable(String)
        case keepWaiting
        case timedOut
    }

    /// How a whole sign-in attempt ended. `refusedAlreadyConnected` is D3's whole point: it is a
    /// deliberate non-action, not a failure.
    enum SignInResult: Equatable {
        case connected
        case refusedAlreadyConnected
        case unusable(String)
        case timedOut
        case cancelled
        case notInstalled
        case launchFailed(String)
        case alreadyInProgress
    }

    enum Severity: Equatable {
        case info
        case warning
    }

    /// One thing said to the user. Held as data rather than built into an `NSAlert` here so the wording is
    /// covered by the deterministic gate instead of only by a GUI probe.
    struct Message: Equatable {
        let title: String
        let body: String
        let severity: Severity
    }

    struct Polling: Equatable {
        let interval: TimeInterval
        let deadline: TimeInterval
    }

    /// A poll every 2s is cheap (the status command is ~0.2s and makes no network call), and the wait is
    /// bounded at what the vendor's own device flows allow. Both numbers are spec D5's.
    static let defaultPolling = Polling(interval: 2, deadline: 15 * 60)

    // MARK: - Pure decisions

    /// D3, as an exhaustive switch: only a real installed-and-signed-out machine gets a login. `.ready`
    /// returning false here is the rule that keeps ViddyDictate from rotating a machine-wide credential.
    ///
    /// The situation vocabulary is `ProviderOnboarding`'s on purpose. A second enum meaning the same four
    /// things is how two surfaces start disagreeing about what "signed out" means.
    static func launchesSignIn(_ situation: ProviderOnboardingSituation) -> Bool {
        switch situation {
        case .signedOut: return true
        case .ready, .unavailable, .notInstalled: return false
        }
    }

    /// One status reading, judged. The verdict comes from `LLMProviderDetection.claudeState`, so the
    /// subscription whitelist (D4) is applied by its owner and is not re-implemented here.
    ///
    /// The transient/terminal split matters: a status command that timed out or could not start is the
    /// APPARATUS momentarily failing, and treating it as a verdict would abandon a user mid-sign-in for a
    /// hiccup. A well-formed `loggedIn` answer we cannot use is the opposite - a settled fact.
    static func step(observation: LLMProviderDetection.ClaudeAuthStatusObservation,
                     elapsed: TimeInterval,
                     deadline: TimeInterval) -> PollStep {
        let state = LLMProviderDetection.claudeState(binaryFound: true, authStatus: observation)
        if state.canRun { return .connected }
        if case .status(let status) = observation, status.loggedIn {
            return .unusable(reason(of: state))
        }
        return elapsed >= deadline ? .timedOut : .keepWaiting
    }

    private static func reason(of state: LLMProviderAvailabilityState) -> String {
        guard case .unavailable(let why) = state else { return "Claude Code reported a state ViddyDictate cannot use" }
        return why
    }

    /// Seconds left before the bounded wait gives up, floored at zero.
    static func remaining(elapsed: TimeInterval, deadline: TimeInterval) -> TimeInterval {
        max(0, deadline - elapsed)
    }

    // MARK: - Pure sign-in loop

    /// The whole attempt, with every impure edge injected. The live controller supplies the real clock,
    /// sleep, cancel flag, launcher, and measurement; the deterministic gate supplies fakes and drives
    /// every branch - including the one that must NOT launch anything.
    static func runSignIn(polling: Polling = defaultPolling,
                          launch: () -> ClaudeSignIn.Outcome,
                          observe: () -> LLMProviderDetection.ClaudeAuthStatusObservation,
                          now: () -> TimeInterval,
                          wait: (TimeInterval) -> Void,
                          isCancelled: () -> Bool,
                          onLaunched: (String) -> Void = { _ in },
                          onWaiting: (TimeInterval) -> Void = { _ in }) -> SignInResult {
        // D3's guard, and the reason it lives HERE rather than in a caller: the measurement is taken
        // immediately before the launch, so a stale reading from a surface that was drawn minutes ago
        // cannot cause a credential rotation. An apparatus hiccup deliberately does NOT block the user's
        // own explicit request - only a positive "already signed in" does.
        switch step(observation: observe(), elapsed: 0, deadline: .infinity) {
        case .connected:
            return .refusedAlreadyConnected
        case .unusable(let why):
            return .unusable(why)
        case .keepWaiting, .timedOut:
            break
        }

        let command: String
        switch launch() {
        case .notInstalled: return .notInstalled
        case .failed(let reason): return .launchFailed(reason)
        case .launched(let launched): command = launched
        }
        onLaunched(command)

        let start = now()
        while true {
            if isCancelled() { return .cancelled }
            onWaiting(remaining(elapsed: now() - start, deadline: polling.deadline))
            wait(polling.interval)
            if isCancelled() { return .cancelled }
            switch step(observation: observe(),
                        elapsed: now() - start,
                        deadline: polling.deadline) {
            case .connected: return .connected
            case .unusable(let why): return .unusable(why)
            case .timedOut: return .timedOut
            case .keepWaiting: continue
            }
        }
    }

    // MARK: - Pure copy

    /// The command a user can always run themselves. Sourced from `ClaudeSignIn` so the sentence and the
    /// script can never name different commands.
    static func loginCommandText(_ command: String?) -> String {
        command ?? "claude auth login"
    }

    static var deadlineText: String {
        "\(Int((defaultPolling.deadline / 60).rounded())) minutes"
    }

    static let awaitingFieldText = "waiting for sign-in..."

    /// Clamped at zero in the formatter as well as in `remaining`: `%02d` on a negative remainder renders
    /// "0:-30", and a countdown is exactly the kind of string nobody re-reads once it looks plausible.
    static func waitingFieldText(remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.down)))
        return String(format: "waiting for sign-in... %d:%02d left", seconds / 60, seconds % 60)
    }

    /// What the flow says for each measured situation. `.signedOut` is the sheet shown WHILE polling, so
    /// the four situations and the four things said stay one set.
    static func situationMessage(_ situation: ProviderOnboardingSituation,
                                 reason: String? = nil,
                                 command: String? = nil) -> Message {
        let login = loginCommandText(command)
        switch situation {
        case .ready:
            return Message(
                title: "Claude Code is already signed in",
                body: "ViddyDictate is using the Claude Code sign-in already on this Mac, so there is "
                    + "nothing to do here.\n\nIt does not sign you in again on purpose. One Claude Code "
                    + "sign-in is shared by everything using Claude Code on this Mac, so replacing it "
                    + "would sign those sessions out. If you ever do need a fresh one, run this in "
                    + "Terminal yourself:\n\n\(login)",
                severity: .info)
        case .signedOut:
            return Message(
                title: "Signing in to Claude Code",
                body: "Terminal is opening with this command:\n\n\(login)\n\nFinish the sign-in there. "
                    + "ViddyDictate checks every couple of seconds and closes this by itself as soon as "
                    + "Claude Code reports you are signed in, so there is nothing to click here. Cancel "
                    + "only stops the waiting; it does not undo a sign-in.",
                severity: .info)
        case .unavailable:
            return Message(
                title: "ViddyDictate cannot use this Claude Code connection",
                body: "Reported: \(Preflight.bounded(reason ?? "no reason given"))\n\nSigning in again "
                    + "would not change this, so ViddyDictate does not offer it. Use Codex instead, or "
                    + "switch Claude Code to a claude.ai subscription outside ViddyDictate.",
                severity: .warning)
        case .notInstalled:
            return Message(
                title: "Claude Code is not installed",
                body: "ViddyDictate signs in through Claude Code's own command, so there is nothing to "
                    + "sign in to yet. Install Claude Code, then check again - the sign-in button "
                    + "appears once it is here.",
                severity: .warning)
        }
    }

    /// What the flow says once an attempt is over. `nil` for a user's own cancel: they know what they did,
    /// and a sheet demanding acknowledgement of it is noise. Three results deliberately reuse the
    /// situation copy rather than paraphrasing it a second time.
    static func resultMessage(_ result: SignInResult, command: String? = nil) -> Message? {
        let login = loginCommandText(command)
        switch result {
        case .connected:
            return Message(
                title: "Claude Code is signed in",
                body: "ViddyDictate re-checked with Claude Code's own status command, and it reports a "
                    + "claude.ai subscription sign-in. No route, model, or default changed.",
                severity: .info)
        case .refusedAlreadyConnected:
            return situationMessage(.ready, command: command)
        case .unusable(let why):
            return situationMessage(.unavailable, reason: why, command: command)
        case .notInstalled:
            return situationMessage(.notInstalled, command: command)
        case .timedOut:
            return Message(
                title: "Still waiting for the Claude Code sign-in",
                body: "ViddyDictate watched for \(deadlineText) and Claude Code still reports no "
                    + "subscription sign-in, so it stopped waiting. Nothing changed. You can finish the "
                    + "sign-in whenever you like by running this in Terminal:\n\n\(login)",
                severity: .warning)
        case .launchFailed(let why):
            return Message(
                title: "Could not start the Claude Code sign-in",
                body: "\(Preflight.bounded(why))\n\nYou can still sign in yourself: run this in "
                    + "Terminal, then check again:\n\n\(login)",
                severity: .warning)
        case .alreadyInProgress:
            return Message(
                title: "A Claude Code sign-in is already waiting",
                body: "ViddyDictate is already watching for a Claude Code sign-in. Finish it in the "
                    + "Terminal window it opened, or cancel that first.",
                severity: .info)
        case .cancelled:
            return nil
        }
    }
}

// MARK: - live

/// The live half: one measurement owner, one poll at a time, and callbacks on the main thread.
final class ClaudeConnectionController {
    static let shared = ClaudeConnectionController()

    /// Everything a host needs to decide what to present, taken in ONE measurement so the situation and
    /// the command it names cannot come from two different readings of the machine.
    struct Measurement {
        let binary: String?
        let presence: LLMProviderDetection.Presence
        let situation: ProviderOnboardingSituation
        /// The literal `claude auth login` line for this machine's CLI, `nil` when there is no CLI.
        let command: String?
        /// The vendor's own reason, when the situation carries one worth quoting.
        let reason: String?
    }

    private let lock = NSLock()
    private var signInInProgress = false
    private var cancelRequested = false

    private init() {}

    var isSigningIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return signInInProgress
    }

    /// Measure off the main thread (the status command spawns a process) and publish, so the stored
    /// availability a surface reads never drifts from what this flow just saw.
    func measure(completion: @escaping (Measurement) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let binary = CloudCleanupClient.resolveBinary()
            let presence = LLMProviderDetection.observeClaude(binary: binary)
            let measurement = Measurement(
                binary: binary,
                presence: presence,
                situation: ProviderOnboarding.situation(presence),
                command: binary.map { ClaudeSignIn.command(binary: $0) },
                reason: {
                    guard case .unavailable(let why) = presence.state else { return nil }
                    return why
                }())
            DispatchQueue.main.async {
                Settings.modelsPower.setAvailabilityState(presence.state, for: .claude)
                completion(measurement)
            }
        }
    }

    /// Hand `claude auth login` to Terminal and watch for it to take effect. Returns through `completion`
    /// on the main thread exactly once. `onWaiting` reports the seconds left, once per poll, so a host can
    /// show a countdown without owning the clock.
    func startSignIn(binary: String,
                     polling: ClaudeConnectionFlow.Polling = ClaudeConnectionFlow.defaultPolling,
                     onLaunched: ((String) -> Void)? = nil,
                     onWaiting: ((TimeInterval) -> Void)? = nil,
                     completion: @escaping (ClaudeConnectionFlow.SignInResult) -> Void) {
        lock.lock()
        guard !signInInProgress else {
            lock.unlock()
            DispatchQueue.main.async { completion(.alreadyInProgress) }
            return
        }
        signInInProgress = true
        cancelRequested = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClaudeConnectionFlow.runSignIn(
                polling: polling,
                launch: { ClaudeSignIn.launch(binary: binary) },
                observe: { LLMProviderDetection.claudeAuthStatus(binary: binary) },
                now: { Self.monotonicNow() },
                wait: { self.sleepUntilNextPoll($0) },
                isCancelled: { self.isCancelRequested },
                onLaunched: { command in
                    guard let onLaunched else { return }
                    DispatchQueue.main.async { onLaunched(command) }
                },
                onWaiting: { seconds in
                    guard let onWaiting else { return }
                    DispatchQueue.main.async { onWaiting(seconds) }
                })
            // Whatever the loop concluded, the state a surface reads is re-MEASURED through the one owner
            // rather than inferred from this result. Log the outcome only as its own case name: the status
            // payload behind it carries account identity fields and never reaches a log.
            let presence = LLMProviderDetection.observeClaude(binary: binary)
            Log.write("claude sign-in: attempt ended \(Self.logToken(result))")
            self.lock.lock()
            self.signInInProgress = false
            self.cancelRequested = false
            self.lock.unlock()
            DispatchQueue.main.async {
                Settings.modelsPower.setAvailabilityState(presence.state, for: .claude)
                completion(result)
            }
        }
    }

    /// Stops the waiting. It cannot and must not undo a sign-in the user already completed in Terminal.
    func cancelSignIn() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    private var isCancelRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    /// Monotonic on purpose: a 15-minute bound measured against the wall clock would end early or late
    /// whenever the machine's time was corrected.
    private static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Sleep the poll interval in slices so Cancel is felt within a quarter second rather than after the
    /// full interval.
    private func sleepUntilNextPoll(_ seconds: TimeInterval) {
        let slice: TimeInterval = 0.25
        var left = seconds
        while left > 0 {
            if isCancelRequested { return }
            Thread.sleep(forTimeInterval: min(slice, left))
            left -= slice
        }
    }

    /// Content-safe: the case name only, never a reason string that quoted the vendor.
    private static func logToken(_ result: ClaudeConnectionFlow.SignInResult) -> String {
        switch result {
        case .connected: return "connected"
        case .refusedAlreadyConnected: return "already-connected-no-reauth"
        case .unusable: return "unsupported-connection"
        case .timedOut: return "timed-out"
        case .cancelled: return "cancelled"
        case .notInstalled: return "not-installed"
        case .launchFailed: return "launch-failed"
        case .alreadyInProgress: return "already-in-progress"
        }
    }
}
