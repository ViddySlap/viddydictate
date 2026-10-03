import Foundation

/// What a Dock/Finder reopen of an already-running ViddyDictate should do (spec item 5 / gap G-VISIBLE).
///
/// Seam only: 42eec8e implements no `applicationShouldHandleReopen` at all, so a reopen while the app is
/// already running shows nothing. The stub here always answers `.openSettings`, which is the wrong route
/// while setup is incomplete - the selftest that drives it against that case is how the gap stays
/// provably red until a later link both implements the selector and makes this routing real.
enum ReopenRoutingPolicy {
    enum Route: Equatable {
        case openSettings
        case openSetupWindow
    }

    static func route(setupComplete: Bool) -> Route {
        setupComplete ? .openSettings : .openSetupWindow
    }
}
