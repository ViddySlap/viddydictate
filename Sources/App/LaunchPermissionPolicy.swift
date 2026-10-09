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

    /// The whole launch-time permission path, injected so a selftest can drive it without constructing an
    /// `AppDelegate` or touching real TCC. On a launch whose first-run Setup window will show, it checks
    /// Accessibility and Input Monitoring SILENTLY (`prompt: false`), arms the tap only when BOTH are
    /// already granted, and never requests the Microphone. When either is missing it does exactly what it
    /// did before: prompt nothing and leave the explanation to the Setup window. A launch with no Setup
    /// window keeps the old full prompting sequence.
    static func runLaunch(setupWindowWillShow: Bool,
                          requester: LaunchPermissionRequester = LaunchPermissionRequester(),
                          startController: () -> Void,
                          setStatus: (String) -> Void = { _ in },
                          log: @escaping (String) -> Void = { Log.write($0) }) {
        if setupWindowWillShow {
            let ax = requester.accessibility(false)
            let im = requester.inputMonitoring(false)
            if LaunchPermissionPolicy.shouldStartControllerWithoutPrompt(
                setupWindowWillShow: setupWindowWillShow,
                accessibilityGranted: ax,
                inputMonitoringGranted: im) {
                startController()
            }
            return
        }
        guard let result = run(shouldRequest: true, requester: requester, log: log) else { return }
        if result.accessibility && result.inputMonitoring {
            startController()
        } else {
            setStatus("Dictation: grant Accessibility + Input Monitoring, then relaunch")
        }
    }
}

/// The setup-window launch decision, kept pure so a selftest can drive it without AppKit or TCC. The tap
/// is armed only when the Setup window is about to show AND Accessibility and Input Monitoring are both
/// already granted; a missing grant leaves the old behaviour (no prompt, no tap) to the Setup window.
extension LaunchPermissionPolicy {
    static func shouldStartControllerWithoutPrompt(setupWindowWillShow: Bool,
                                                   accessibilityGranted: Bool,
                                                   inputMonitoringGranted: Bool) -> Bool {
        setupWindowWillShow && accessibilityGranted && inputMonitoringGranted
    }
}
