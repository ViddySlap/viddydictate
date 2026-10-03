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

/// Seam only (gap G-RELAUNCH). No production call site reads this yet - `AppDelegate` still does nothing
/// when a grant lands mid-session - so the stub always answers `.none`, reproducing 42eec8e exactly. A
/// later link wires this into the permissions walkthrough's poll.
enum PostLaunchGrantPolicy {
    static func respond(accessibilityGranted: Bool, inputMonitoringGranted: Bool,
                        tapLive: Bool) -> PostLaunchGrantResponse {
        guard accessibilityGranted, inputMonitoringGranted, !tapLive else { return .none }
        return .offerRelaunch
    }
}

/// Relaunching ViddyDictate in place (spec item 5's one-click "Relaunch ViddyDictate" button). Injectable
/// so a selftest can spy on it without ever spawning a second process; production's default actually
/// does it. No production call site invokes this yet - it is wired up once `PostLaunchGrantPolicy` ever
/// answers `.offerRelaunch`.
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
