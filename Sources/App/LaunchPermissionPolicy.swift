import Foundation

/// A fresh launch's permission-request timing (spec item 5 / gap G-PROMPTS): whether `AppDelegate`
/// should request Accessibility, Input Monitoring and Microphone access during
/// `applicationDidFinishLaunching`, before the first-run setup window has had a chance to explain why.
///
/// Pure, so a selftest can drive the decision without AppKit or TCC. `AppDelegate.requestPermissions()`
/// asks this during launch: a fresh install, whose setup window is about to explain and collect the
/// three grants itself, must not prompt at launch, so the answer is the negation of
/// `setupWindowWillShow`. A launch that returns to an already-set-up Mac still requests the grants up
/// front, exactly as before the walkthrough existed.
enum LaunchPermissionPolicy {
    static func shouldRequestAtLaunch(setupWindowWillShow: Bool) -> Bool {
        !setupWindowWillShow
    }
}

/// The actual TCC calls `AppDelegate.requestPermissions()` makes, pulled into one injectable value so a
/// selftest can spy on them without ever touching the real TCC store. Every default is exactly today's
/// call.
struct LaunchPermissionRequester {
    var accessibility: (Bool) -> Bool = { Permissions.accessibility(prompt: $0) }
    var inputMonitoring: (Bool) -> Bool = { Permissions.inputMonitoring(prompt: $0) }
    var microphone: (@escaping (Bool) -> Void) -> Void = { Permissions.microphone($0) }
}

/// `AppDelegate.requestPermissions()`'s body, pulled out pure so a selftest can drive it without
/// constructing an `AppDelegate` or an `NSApplication`. When `shouldRequest` is true it asks for all
/// three permissions, in the same order, and returns the Accessibility/Input Monitoring results the
/// caller uses to decide whether to start the controller. When false (a fresh install whose setup
/// window is about to collect the grants itself) it asks for nothing and returns nil.
enum LaunchPermissionSequence {
    static func run(shouldRequest: Bool,
                    requester: LaunchPermissionRequester = LaunchPermissionRequester(),
                    log: @escaping (String) -> Void = { Log.write($0) })
        -> (accessibility: Bool, inputMonitoring: Bool)? {
        guard shouldRequest else { return nil }
        let ax = requester.accessibility(true)
        let im = requester.inputMonitoring(true)
        requester.microphone { granted in log("mic permission granted=\(granted)") }
        log("perms ax=\(ax) im=\(im)")
        return (ax, im)
    }
}
