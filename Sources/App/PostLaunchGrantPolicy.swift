import Foundation
import AppKit

/// What should happen when Accessibility and Input Monitoring both read granted after launch, while this
/// launch's own hotkey tap is not live (spec item 5's "grant mid-session" case).
enum PostLaunchGrantResponse: Equatable {
    /// 42eec8e: nothing. The user must quit and reopen by hand - there is no relaunch button and no
    /// in-process re-arm, so hotkeys stay dead until they do.
    case none
    case reArmTap
    case offerRelaunch
}

/// The production decision the permissions walkthrough's poll reads (`ComponentPickerView.refreshPermissions`):
/// when Accessibility and Input Monitoring both read granted after launch while this launch's own hotkey
/// tap is not live, answer `.offerRelaunch` - which the walkthrough turns into its one-click Relaunch
/// button - and otherwise `.none`. `.reArmTap` is reserved for a future in-process re-arm.
enum PostLaunchGrantPolicy {
    static func respond(accessibilityGranted: Bool, inputMonitoringGranted: Bool,
                        tapLive: Bool) -> PostLaunchGrantResponse {
        guard accessibilityGranted, inputMonitoringGranted, !tapLive else { return .none }
        return .offerRelaunch
    }
}

/// Relaunching ViddyDictate in place (spec item 5's one-click "Relaunch ViddyDictate" button). Injectable
/// so a selftest can spy on it without ever spawning a second process; production's default actually
/// does it. The walkthrough's Relaunch button (`ComponentPickerView.makePermissionsView` /
/// `makeReadyView`) invokes it once `PostLaunchGrantPolicy` answers `.offerRelaunch`.
struct AppRelauncher {
    var relaunch: () -> Void = AppRelauncher.liveRelaunch

    static func liveRelaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundlePath]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}
