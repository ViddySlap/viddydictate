import Cocoa

/// The first-run permissions screen (spec B19).
///
/// Three grants stand between a finished download and an app that does anything: microphone,
/// accessibility, and input monitoring. B19 puts them DURING the download rather than before or after
/// it, because the download is two minutes of dead time and this is the only other thing in the way.
///
/// This file owns which three, what they are for, and where each one lives in System Settings.
/// `Permissions` already answers whether a grant has landed; nothing here re-implements that.
enum SetupPermission: String, CaseIterable {
    case microphone
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    /// What the grant buys, named as the thing the user will press rather than as a capability. O7:
    /// the spec's tone is plain and specific, and "required for full functionality" is the string it
    /// exists to prevent.
    var detail: String {
        switch self {
        case .microphone:
            return "So ViddyDictate can hear you. Without it, holding the dictation key records silence."
        case .accessibility:
            return "So dictated text can be typed into the app you are working in. Without it, "
                + "ViddyDictate can transcribe but cannot deliver."
        case .inputMonitoring:
            return "So the dictation hotkey works while another app is in front. Without it, the key "
                + "only works when ViddyDictate itself is frontmost."
        }
    }

    /// The System Settings anchor for this pane.
    ///
    /// **Measured on macOS 15.6.1 (24G90), not remembered.** The names come from Apple's own
    /// `TCCServiceList.plist` inside `SecurityPrivacyExtension.appex`, where Input Monitoring is
    /// declared as `revealElementKeyName = Privacy_ListenEvent` against `kTCCServiceListenEvent`;
    /// `Privacy_Microphone` and `Privacy_Accessibility` are string constants in that extension's own
    /// binary. Guessing here is not a cosmetic risk: a wrong anchor opens System Settings to its root
    /// and B19's whole claim is that the button lands on the exact pane.
    var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }

    /// The pane identifier, which is the part folklore gets wrong.
    ///
    /// Every snippet on the internet still says `com.apple.preference.security`, which was the
    /// System Preferences pane bundle id. That string appears NOWHERE in System Settings.app on
    /// 15.6.1 - checked across the whole bundle - while `com.apple.settings.PrivacySecurity.extension`
    /// is in its binary and is the real bundle id of the extension that draws these panes.
    static let privacyPaneIdentifier = "com.apple.settings.PrivacySecurity.extension"

    var settingsURL: URL {
        // Force-unwrapped against a constant scheme, host and anchor with no user input in it; if this
        // is nil the string above was edited into something malformed, which is a build-time mistake.
        URL(string: "x-apple.systempreferences:\(Self.privacyPaneIdentifier)?\(settingsAnchor)")!
    }

    func isGranted(_ status: PermissionsStatus) -> Bool { status.isGranted(self) }
}

/// A reading of all three grants at one moment.
struct PermissionsStatus: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool

    init(microphone: Bool = false, accessibility: Bool = false, inputMonitoring: Bool = false) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    /// The live read. `microphoneAuthorization()` is the status-only reader: a screen that shows state
    /// must not be the thing that triggers the prompt, or every launch prompts.
    static var live: PermissionsStatus {
        PermissionsStatus(
            microphone: Permissions.microphoneAuthorization() == .authorized,
            accessibility: Permissions.accessibility(prompt: false),
            inputMonitoring: Permissions.inputMonitoring(prompt: false))
    }

    func isGranted(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .microphone: return microphone
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }

    mutating func set(_ permission: SetupPermission, _ value: Bool) {
        switch permission {
        case .microphone: microphone = value
        case .accessibility: accessibility = value
        case .inputMonitoring: inputMonitoring = value
        }
    }

    var ungranted: [SetupPermission] { SetupPermission.allCases.filter { !isGranted($0) } }
    var allGranted: Bool { ungranted.isEmpty }

    /// B19: an ungranted permission gets the same treatment as an unfinished download, which starts
    /// with being NAMED. The degraded banner is `BootstrapSnapshot`'s, so this is the line it can put
    /// beside its own rather than a second banner.
    var bannerLine: String? {
        let missing = ungranted
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.title)
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = names.joined(separator: " and ")
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "ViddyDictate still needs \(list) - Open setup"
    }
}

/// Pressing Grant.
///
/// **Not every row is a deep link, and that is deliberate.** The microphone is the one grant macOS
/// will hand over from a prompt the app can raise itself, so the first press asks - one dialog, one
/// click, no System Settings at all. Once it has been refused, the prompt is spent and the pane is the
/// only route left. Accessibility and Input Monitoring cannot be granted from a prompt at any point;
/// their system dialogs only offer to open the same pane this opens directly, and macOS suppresses
/// them after the first dismissal, so the pane IS the honest button.
enum PermissionsGrant {
    enum Action: Equatable {
        case requestMicrophonePrompt
        case openSettings(SetupPermission)
    }

    static func action(for permission: SetupPermission,
                       microphoneAuthorization: MicrophoneAuthorization) -> Action {
        if permission == .microphone, microphoneAuthorization == .notDetermined {
            return .requestMicrophonePrompt
        }
        return .openSettings(permission)
    }

    @discardableResult
    static func perform(_ action: Action, opener: (URL) -> Bool = { NSWorkspace.shared.open($0) },
                        request: @escaping (@escaping (Bool) -> Void) -> Void = Permissions.microphone,
                        completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        switch action {
        case .requestMicrophonePrompt:
            request { granted in completion(granted) }
            return true
        case .openSettings(let permission):
            let opened = opener(permission.settingsURL)
            completion(false)
            return opened
        }
    }
}

/// Copy and identity for the permissions screen.
enum PermissionsScreen {
    static let headline = "Three permissions"

    /// Says why they are being asked now, which is the question a stranger has at this exact moment.
    static let subtitle =
        "macOS grants these individually, and it will not let ViddyDictate ask for two of them at all "
        + "- you turn them on yourself. Doing it here costs you nothing: the download below keeps "
        + "running while you do."

    static let grantTitle = "Grant"
    static let grantedText = "GRANTED"
    static let pendingText = "NEEDED"
    static let continueTitle = "Continue"
    static let allGrantedNote = "All three are on. Nothing else here needs you."

    enum Part: String, CaseIterable {
        case title
        case detail
        case status
        case grant
    }

    static func identifier(_ part: Part, _ permission: SetupPermission) -> String {
        "permissions-\(permission.rawValue)-\(part.rawValue)"
    }

    static func cardIdentifier(_ permission: SetupPermission) -> String {
        "permissions-card-\(permission.rawValue)"
    }

    static let surfaceIdentifier = "permissions-screen"
    static let headlineIdentifier = "permissions-headline"
    static let subtitleIdentifier = "permissions-subtitle"
    static let continueIdentifier = "permissions-continue"
    static let stripIdentifier = "permissions-progress-strip"
}
