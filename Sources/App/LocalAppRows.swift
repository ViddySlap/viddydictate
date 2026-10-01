import Foundation

/// The Setup tab's local model apps card, as data (spec D1/D3): one status row per local app, the buttons
/// each row offers, the section headline, and the Preferred local app choices.
///
/// `LocalModelsSectionView` draws these and performs the buttons; this file only decides. Every row is a pure
/// function of S3a's merged `.local` presence (its per-app `localBackendReadings`, the same measurement the
/// Setup tab's preflight rows read) plus what the shared install queue says about the app's own row, so the
/// whole matrix is gated without AppKit or a Mac (`--local-apps-setup-selftest`).
///
/// The rules this file holds:
///
/// - **LM Studio is always the first row.** On a Mac with neither app it is the simple, recommended install
///   and Ollama is the advanced option (D3). The recommended marker exists ONLY in that situation and only
///   ever on LM Studio: once either app is installed nothing is recommended, because the choice was made.
/// - **Install** when the app is not installed, through the shared `BootstrapInstallCoordinator` queue, the
///   same rows the point-of-use offer installs. Its copy for Ollama carries the macOS-prompt warning.
/// - **Open** when an APP is installed: by path, never by name.
/// - **Start** only for an installed APP that is not running. A CLI-only (Homebrew) Ollama has neither Open
///   nor Start, because there is no app to open and ViddyDictate never starts a daemon the user manages; its
///   row says how to start it instead.
/// - **The headline keeps 1.1.0's exact words unless Ollama is installed.** A Mac with LM Studio only, or
///   with neither app, reads "Local models run in LM Studio, on this Mac." byte for byte.
enum LocalAppRows {

    // MARK: - Row model

    /// What one app is doing, as the row states it.
    enum State: Equatable {
        /// No measurement has reached the section yet (the Setup tab's first check is still running).
        case checking
        /// The presence carried no per-app breakdown for this app, so there is nothing true to say about it.
        case notMeasured
        case notInstalled
        /// An installed app whose server does not answer.
        case notRunning
        /// A command-line (Homebrew) Ollama whose server does not answer.
        case commandLineNotRunning
        /// Installed, but ViddyDictate will not use it (S3a's reading carries the reason): Ollama pointed at a
        /// server on another machine by `OLLAMA_HOST`. No Start, since starting it would not change that.
        case notUsed(reason: String)
        /// Answering. `models` is nil when its catalog did not answer.
        case running(models: Int?, commandLine: Bool)
    }

    /// What the shared install queue, or a Start the user pressed, says about this app's own row. Folded in
    /// on top of the measured state: it only ever changes a not-installed or not-running row.
    enum Activity: Equatable {
        case idle
        /// The app's install row is running. `detail` is `InstallProgress.statusText` for it, which on Ollama
        /// is the wait for its macOS prompt rather than a byte count.
        case installing(detail: String)
        /// The app's last install failed with this text (the vendor's own, B10).
        case installFailed(message: String)
        /// The user pressed Start and the start has not come back yet.
        case starting
    }

    enum Action: String, CaseIterable {
        case install
        case open
        case start
    }

    struct Button: Equatable {
        let action: Action
        let title: String
        let isEnabled: Bool
    }

    struct Row: Equatable {
        let backend: LocalBackendID
        /// The app's own name.
        let title: String
        /// "Simple - recommended" / "Advanced", only on a Mac with neither app (D3). nil otherwise.
        let tag: String?
        /// True only for LM Studio on a Mac with neither app.
        let recommended: Bool
        let state: State
        /// The short state word in the row's status column, like every other Setup row has.
        let stateWord: String
        /// Whether the state word reads as something to act on (orange) rather than fine or absent.
        let needsAttention: Bool
        let status: String
        /// One more sentence where the state needs one (how to start a CLI install, the Ollama prompt, a
        /// failed install's own error). nil when the status line says everything.
        let detail: String?
        /// In drawing order.
        let buttons: [Button]

        func button(_ action: Action) -> Button? { buttons.first { $0.action == action } }
    }

    // MARK: - Building the rows

    /// LM Studio first, then Ollama, always both.
    static let order: [LocalBackendID] = [.lmStudio, .ollama]

    /// The rows for `presence` (S3a's merged `.local` presence; nil while the tab's first check is running),
    /// with what the install queue or a pressed Start says about each app on top. The Preferred local app is
    /// deliberately not an input: which app is preferred never changes what an app's row says or offers.
    static func build(presence: LLMProviderDetection.Presence?,
                      activity: [LocalBackendID: Activity] = [:]) -> [Row] {
        let readings = order.map { reading($0, in: presence) }
        // D3's situation, measured: both apps measurably absent. An unmeasured app is never counted absent.
        let neither = readings.allSatisfy { $0?.installed == false }
        return zip(order, readings).map { backend, reading in
            row(backend, reading: reading, measured: presence != nil, neitherInstalled: neither,
                activity: activity[backend] ?? .idle)
        }
    }

    /// One app's reading. A presence built without the per-app breakdown (a hand-built one) answers for LM
    /// Studio from its merged fields, exactly as `PointOfUsePolicy.isSatisfied` does, and says nothing about
    /// Ollama: the merged fields measured only "some local app".
    static func reading(_ backend: LocalBackendID, in presence: LLMProviderDetection.Presence?)
        -> LLMProviderDetection.LocalBackendReading? {
        guard let presence else { return nil }
        if let readings = presence.localBackendReadings {
            return readings.first { $0.backend == backend }
                ?? LLMProviderDetection.LocalBackendReading(backend: backend, installed: false,
                                                            responding: false, models: nil)
        }
        guard backend == .lmStudio else { return nil }
        return LLMProviderDetection.LocalBackendReading(
            backend: .lmStudio, installed: presence.installed, responding: presence.state.canRun,
            models: presence.state.canRun ? presence.availableLocalModels : nil)
    }

    private static func row(_ backend: LocalBackendID, reading: LLMProviderDetection.LocalBackendReading?,
                            measured: Bool, neitherInstalled: Bool, activity: Activity) -> Row {
        let state = self.state(reading, measured: measured)
        let recommended = neitherInstalled && backend == .lmStudio
        let tag: String? = neitherInstalled ? (backend == .lmStudio ? recommendedTag : advancedTag) : nil

        var word = stateWord(state)
        var attention = false
        var status = statusText(state, backend: backend)
        var detail = detailText(state, backend: backend, reading: reading, neitherInstalled: neitherInstalled)
        var buttons: [Button] = []

        switch state {
        case .checking, .notMeasured:
            break
        case .notInstalled:
            switch activity {
            case .installing(let progress):
                word = "INSTALLING"
                status = "Installing"
                detail = backend == .ollama ? "\(progress). \(OllamaInstaller.adminPromptWarning)" : progress
                buttons = [Button(action: .install, title: installingTitle, isEnabled: false)]
            case .installFailed(let message):
                word = "FAILED"
                attention = true
                status = "Not installed. The last install stopped:"
                detail = message
                buttons = [Button(action: .install, title: retryTitle, isEnabled: true)]
            case .idle, .starting:
                buttons = [Button(action: .install, title: installTitle, isEnabled: true)]
            }
        case .notRunning:
            // Not running is an ordinary state (LM Studio starts its server lazily on the next load). Only a
            // start S3a already attempted that did not answer is something to act on.
            attention = reading?.startAttempted == true
            let starting = activity == .starting
            if starting { status = "Starting" }
            buttons = [Button(action: .open, title: openTitle, isEnabled: true),
                       Button(action: .start, title: starting ? startingTitle : startTitle,
                              isEnabled: !starting)]
        case .commandLineNotRunning:
            // No Open (there is no app) and no Start (a daemon the user manages). The detail says how.
            break
        case .notUsed:
            // Starting or opening it would not bring it to this Mac. The detail says why.
            attention = true
        case .running(_, let commandLine):
            if !commandLine { buttons = [Button(action: .open, title: openTitle, isEnabled: true)] }
        }

        return Row(backend: backend, title: backend.displayName, tag: tag, recommended: recommended,
                   state: state, stateWord: word, needsAttention: attention, status: status,
                   detail: detail, buttons: buttons)
    }

    static func state(_ reading: LLMProviderDetection.LocalBackendReading?, measured: Bool) -> State {
        guard measured else { return .checking }
        guard let reading else { return .notMeasured }
        guard reading.installed else { return .notInstalled }
        if let refusal = reading.refusal { return .notUsed(reason: refusal) }
        let commandLine = isCommandLine(reading)
        guard reading.responding else { return commandLine ? .commandLineNotRunning : .notRunning }
        return .running(models: reading.models?.count, commandLine: commandLine)
    }

    /// An installed Ollama with no desktop app to open is the Homebrew CLI (S3a's `startable` is exactly
    /// "has an app bundle observation may open"). LM Studio is always its app.
    static func isCommandLine(_ reading: LLMProviderDetection.LocalBackendReading) -> Bool {
        reading.backend == .ollama && reading.installed && !reading.startable
    }

    // MARK: - Copy

    static let cardTitle = "Local model apps"

    static let recommendedTag = "Simple - recommended"
    static let advancedTag = "Advanced"

    static let installTitle = "Install"
    /// The same word the first-run window's failed rows use (`InstallProgress.retryTitle`), and the word every
    /// installer failure message tells the user to choose. One word app-wide.
    static var retryTitle: String { InstallProgress.retryTitle }
    static let installingTitle = "Installing..."
    static let openTitle = "Open"
    static let startTitle = "Start"
    static let startingTitle = "Starting..."

    static func stateWord(_ state: State) -> String {
        switch state {
        case .checking: return "CHECKING"
        case .notMeasured: return "NOT CHECKED"
        case .notInstalled: return "NOT INSTALLED"
        case .notRunning: return "NOT RUNNING"
        case .commandLineNotRunning: return "NOT RUNNING"
        case .notUsed: return "NOT USED"
        case .running: return "RUNNING"
        }
    }

    static func statusText(_ state: State, backend: LocalBackendID) -> String {
        switch state {
        case .checking: return "Checking..."
        case .notMeasured: return "Not measured on this check"
        case .notInstalled: return "Not installed"
        case .notRunning: return "Installed, not running"
        case .commandLineNotRunning:
            return "Installed as a command-line tool (Homebrew), not running"
        case .notUsed: return "Installed, not used"
        case .running(let models, _):
            guard let models else { return "Running; its model list did not answer" }
            switch models {
            case 0: return "Running with no models installed"
            case 1: return "Running with 1 model"
            default: return "Running with \(models) models"
            }
        }
    }

    private static func detailText(_ state: State, backend: LocalBackendID,
                                   reading: LLMProviderDetection.LocalBackendReading?,
                                   neitherInstalled: Bool) -> String? {
        switch state {
        case .checking, .notMeasured:
            return nil
        case .notInstalled:
            return installCopy(backend, neitherInstalled: neitherInstalled)
        case .notRunning:
            // S3a's own guidance after a start it attempted did not answer: the macOS prompt is the usual cause.
            if reading?.startAttempted == true { return LLMProviderDetection.ollamaDidNotStartReason }
            switch backend {
            case .lmStudio:
                return "Start turns on LM Studio's local server in the background. Open brings up its window."
            case .ollama: return "Start opens Ollama in the background. Open brings up the app."
            }
        case .commandLineNotRunning:
            return commandLineStartCopy
        case .notUsed(let reason):
            return reason
        case .running(_, let commandLine):
            return commandLine
                ? "Installed as a command-line tool (Homebrew). Its server is yours to start and stop." : nil
        }
    }

    /// What Install does, said before it is pressed. Ollama's carries the warning about its macOS prompt
    /// (D8), word for word the one the point-of-use choice and the installer row use.
    static func installCopy(_ backend: LocalBackendID, neitherInstalled: Bool) -> String {
        switch backend {
        case .lmStudio:
            return (neitherInstalled ? "The simple install. " : "")
                + "Install downloads LM Studio from its own site and checks its signature."
        case .ollama:
            return (neitherInstalled ? "The advanced option, for people who already use Ollama. " : "")
                + "Install downloads Ollama from its own site and checks its signature. "
                + OllamaInstaller.adminPromptWarning
        }
    }

    /// A CLI-only Ollama is a daemon the user runs. ViddyDictate never starts it, so the row says how.
    static let commandLineStartCopy =
        "ViddyDictate does not start a command-line install. Start it in Terminal with ollama serve "
        + "(or brew services start ollama), then choose Check again."

    // MARK: - Headline

    /// The section's first line. 1.1.0's exact words unless Ollama is installed, so an LM-Studio-only Mac,
    /// and one with neither app, reads exactly what it read before a second app existed.
    static func headline(presence: LLMProviderDetection.Presence?) -> String {
        guard reading(.ollama, in: presence)?.installed == true else { return LocalModelSetup.headline }
        if reading(.lmStudio, in: presence)?.installed == true {
            return "Local models run in LM Studio or Ollama, on this Mac."
        }
        return "Local models run in Ollama, on this Mac."
    }

    // MARK: - Preferred local app

    struct PreferenceChoice: Equatable {
        /// nil is Automatic.
        let value: LocalBackendID?
        let title: String
        let isSelected: Bool
    }

    static let preferenceTitle = "Preferred local app"

    static let preferenceHint =
        "Which app new routes and staff picks use, and the one ViddyDictate may start in the background. "
        + "Automatic follows what is installed, and picks LM Studio when both or neither are."

    /// Automatic, LM Studio, Ollama, with the explicit choice selected. Automatic names what it resolves to
    /// (`LocalBackendPreference.effective`) once the installs are measured, and reads plain "Automatic" until
    /// then rather than guessing.
    static func preferenceChoices(explicit: LocalBackendID?,
                                  presence: LLMProviderDetection.Presence?) -> [PreferenceChoice] {
        var automatic = "Automatic"
        if let installed = installedApps(presence) {
            let effective = LocalBackendPreference.effective(explicit: nil, installed: installed)
            automatic += " (\(effective.displayName))"
        }
        return [PreferenceChoice(value: nil, title: automatic, isSelected: explicit == nil)]
            + order.map { PreferenceChoice(value: $0, title: $0.displayName, isSelected: explicit == $0) }
    }

    /// The installed apps, or nil when they were not measured.
    static func installedApps(_ presence: LLMProviderDetection.Presence?) -> Set<LocalBackendID>? {
        var installed = Set<LocalBackendID>()
        for backend in order {
            guard let reading = reading(backend, in: presence) else { return nil }
            if reading.installed { installed.insert(backend) }
        }
        return installed
    }

    // MARK: - Installs

    /// The install row each app's Install queues: the app alone, exactly the descriptor the point-of-use
    /// offer queues for it, so both surfaces drive one row in one queue.
    static func installDescriptor(_ backend: LocalBackendID) -> InstallerComponentDescriptor {
        switch backend {
        case .lmStudio: return BootstrapInstallPlan.lmStudio
        case .ollama: return BootstrapInstallPlan.ollama
        }
    }

    /// The row's install activity from the shared queue's durable record and what the running step last
    /// reported. A pending record is idle: a fresh snapshot lists every component as pending, so "pending"
    /// cannot say this app is queued. An `installing` record left behind by a run that is no longer going is
    /// idle too.
    static func activity(record: BootstrapComponentRecord?, queueRunning: Bool,
                         reported: InstallerLocalActivity?) -> Activity {
        guard let record else { return .idle }
        switch record.phase {
        case .installing:
            guard queueRunning else { return .idle }
            return .installing(detail: InstallProgress.statusText(for: record, activity: reported))
        case .failed:
            return .installFailed(message: record.failureMessage ?? "it stopped before it finished")
        case .pending, .installed:
            return .idle
        }
    }

    // MARK: - Identity

    enum RowPart: String, CaseIterable {
        case row
        case state
        case title
        case tag
        case status
        case detail
    }

    static func identifier(_ part: RowPart, _ backend: LocalBackendID) -> String {
        "local-apps-\(part.rawValue)|\(backend.rawValue)"
    }

    static func buttonIdentifier(_ action: Action, _ backend: LocalBackendID) -> String {
        "local-apps-button|\(backend.rawValue)|\(action.rawValue)"
    }

    /// The (app, action) a button identifier names, or nil for anything else.
    static func button(fromIdentifier raw: String?) -> (LocalBackendID, Action)? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "local-apps-button",
              let backend = LocalBackendID(rawValue: parts[1]),
              let action = Action(rawValue: parts[2]) else { return nil }
        return (backend, action)
    }

    static let cardIdentifier = "local-apps-card"
    static let cardTitleIdentifier = "local-apps-card-title"
    static let preferenceTitleIdentifier = "local-apps-preferred-title"
    static let preferencePopupIdentifier = "local-apps-preferred"
    static let preferenceHintIdentifier = "local-apps-preferred-hint"
}
