import Foundation

/// What a Dock/Finder reopen of an already-running ViddyDictate should do (spec item 5 / gap G-VISIBLE).
///
/// The real routing behind `AppDelegate.applicationShouldHandleReopen`: while setup is incomplete a
/// reopen of the already-running app brings the first-run setup window back to the front; once setup
/// is complete it opens Settings, the same route the menu-bar item takes.
enum ReopenRoutingPolicy {
    enum Route: Equatable {
        case openSettings
        case openSetupWindow
    }

    static func route(setupComplete: Bool) -> Route {
        setupComplete ? .openSettings : .openSetupWindow
    }
}
