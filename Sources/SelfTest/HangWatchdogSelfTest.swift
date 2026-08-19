import Cocoa
import CoreFoundation
import Darwin
import Foundation

/// Gates for the in-process hang watchdog (ADR 0017).
///
/// Three layers, cheapest first:
///
/// 1. **Policy** — the threshold and the verdict table, as pure values. No timer, no thread, no clock.
/// 2. **Live mechanism** — the real `Timer` + real detached `Thread` + real lock, driven at an injected
///    fast policy so a stopped heartbeat is proven to fire a verdict in about a second.
/// 3. **Source rules** — the properties that make the mechanism work at all and that a well-meaning
///    refactor would quietly break: a real thread rather than a dispatch queue, a `.common`-mode timer,
///    the reason logged BEFORE the abort, and no new LaunchAgent.
///
/// What none of these can do is prove the abort actually lands and that launchd relaunches on it.
/// That is `--hang-watchdog-selftest --hang-watchdog-abort-proof`, which is opt-in because it kills its
/// own process at the real 45s threshold and leaves a crash report behind by design.
enum HangWatchdogSelfTest {
    private static let abortProofFlag = HangWatchdogFlag.abortProof.rawValue
    private static let adrReference =
        "Projects/viddydictate/decisions/0017-hang-watchdog-aborts-into-keepalive.md"
    private static let deadlockReference =
        "Projects/viddydictate/wiki/reference/retained-take-deadlock.md"

    /// Beats to let land before wedging, so the abort is provably caused by the heartbeat STOPPING
    /// rather than by it never having started.
    private static let healthySeconds: TimeInterval = 10

    // MARK: - Opt-in end-to-end abort proof

    /// Deliberately wedges main and lets the SHIPPED watchdog abort this process.
    ///
    /// It is the only way to prove the whole chain the ADR depends on: the reason reaches the log
    /// first, SIGABRT gives a non-zero exit, `KeepAlive: SuccessfulExit=false` relaunches, and
    /// ReportCrash writes a real `.ips` with every thread stack. Never wired into a verify.sh tier.
    ///
    /// Returning at all is a FAILURE: it means main woke up because the watchdog never fired.
    static func abortProofExit(arguments: [String]) -> Int32? {
        guard arguments.contains(abortProofFlag) else { return nil }
        guard Thread.isMainThread else {
            print("[hang-watchdog-abort-proof] FAIL: entrypoint is not on main")
            return 2
        }
        let policy = HangWatchdogPolicy.production
        let watchdog = HangWatchdog.productionWatchdog()
        watchdog.start()
        print("[hang-watchdog-abort-proof] armed pid=\(getpid()) "
                + "threshold=\(Int(policy.threshold))s log=\(Log.url.path)")
        fflush(stdout)

        // Real beats first, through the real main run loop. This also proves the `.common`-mode
        // registration actually fires, since `run(until:)` runs in `.default`.
        RunLoop.main.run(until: Date().addingTimeInterval(healthySeconds))

        let wedgeSeconds = policy.threshold + 60
        print(String(format: "[hang-watchdog-abort-proof] wedging main for %.0fs at uptime=%.1f; "
                        + "abort expected in ~%.0fs",
                     wedgeSeconds, ProcessInfo.processInfo.systemUptime, policy.threshold))
        fflush(stdout)
        Thread.sleep(forTimeInterval: wedgeSeconds)

        print("[hang-watchdog-abort-proof] FAIL: main woke up — the watchdog never fired")
        return 1
    }

    // MARK: - Deterministic gate

    static func run() -> Bool {
        print("--- hang watchdog: policy, live mechanism, and source rules ---")
        let reporter = SelfTestReporter()

        checkPolicy(reporter)
        checkLiveMechanism(reporter)
        checkSourceRules(reporter)

        print(reporter.summaryLine(prefix: "[hang-watchdog-selftest]"))
        return reporter.passed
    }

    // MARK: - 1. Policy

    private static func checkPolicy(_ reporter: SelfTestReporter) {
        let policy = HangWatchdogPolicy.production

        let thresholdHolds = policy.threshold == 45
        reporter.record(
            "shipped hang threshold is exactly 45s",
            thresholdHolds,
            thresholdHolds ? "" :
                "BROKEN RULE: the threshold is 45s by Ben's decision of 2026-08-19 and is a "
                    + "floor-with-margin, not a precision target. Shaving it ships a NEW failure mode "
                    + "that destroys a real dictation; a generous one only delays a recovery that "
                    + "previously took 3.5 hours. Raise it with evidence, never trim it. "
                    + "See \(adrReference). Found \(policy.threshold)")

        reporter.record("policy is well formed: >=3 beats per threshold, watcher polls at least as "
                            + "often as main ticks, jump tolerance above scheduling slop",
                        policy.isWellFormed,
                        policy.isWellFormed ? "" : String(describing: policy))

        // The measured worst LEGITIMATE main-thread block in this codebase is the Accessibility chain
        // in TargetResolver.captureFocused(): five sequential AXUIElement round trips, each bounded by
        // the default AX messaging timeout measured at 1.51s on 2026-08-19, so ~7.6s. The threshold
        // must keep a wide margin over that or an ordinary unresponsive frontmost app becomes an abort.
        let measuredWorstLegitimateBlock: TimeInterval = 7.6
        reporter.record("threshold keeps at least 5x margin over the measured worst legitimate "
                            + "main-thread block (AX chain, 7.6s)",
                        policy.threshold >= measuredWorstLegitimateBlock * 5)

        reporter.record("a gap just under the threshold is healthy",
                        policy.verdict(gap: policy.threshold - 0.1, pollOvershoot: 0) == .healthy)
        reporter.record("a gap at the threshold is a hang",
                        policy.verdict(gap: policy.threshold, pollOvershoot: 0) == .hung)
        reporter.record("a gap far past the threshold is a hang",
                        policy.verdict(gap: 3600, pollOvershoot: 0) == .hung)

        // The morning-after case: an overnight sleep leaves main's last beat hours old while nothing
        // is wrong. A watchdog that aborted every morning would be worse than the bug it was built for.
        reporter.record("a clock jump outranks a hang, so a machine waking from sleep is never a verdict",
                        policy.verdict(gap: 32_400, pollOvershoot: 32_400) == .clockJumped)
        reporter.record("ordinary scheduling slop inside the tolerance is not treated as a jump",
                        policy.verdict(gap: 3600, pollOvershoot: policy.clockJumpTolerance) == .hung)

        reporter.record("stall reporting starts above one full beat-plus-poll cycle, so jitter is "
                            + "never logged as a stall",
                        policy.reportFloor > policy.beatInterval + policy.pollInterval)
    }

    // MARK: - 2. Live mechanism

    private static func checkLiveMechanism(_ reporter: SelfTestReporter) {
        let fast = HangWatchdogPolicy(threshold: 0.6, beatInterval: 0.1,
                                      pollInterval: 0.05, clockJumpTolerance: 0.5)

        // A. Heartbeat stopped. Nothing services the main run loop here, so after `start()` seeds one
        //    beat the timer never fires again — exactly the shape of a wedged main thread.
        let stalled = HangSink()
        let stalledWatchdog = HangWatchdog(policy: fast) { stalled.fire($0) }
        stalledWatchdog.start()
        let stalledDeadline = Date().addingTimeInterval(5)
        while stalled.reason == nil, Date() < stalledDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        stalledWatchdog.stop()
        let stalledReason = stalled.reason
        reporter.record("a heartbeat that stops produces exactly one hang verdict",
                        stalledReason != nil && stalled.count == 1,
                        "count=\(stalled.count)")
        reporter.record("the hang reason names the gap, the threshold, and that this is a hang",
                        (stalledReason ?? "").contains("HANG WATCHDOG")
                            && (stalledReason ?? "").contains("has not ticked")
                            && (stalledReason ?? "").contains("HANG, not a crash"),
                        stalledReason ?? "(never fired)")

        // B. Heartbeat running. Same watchdog, same threshold, but the main run loop is serviced, so
        //    the timer beats and no verdict may land. This is the spurious-abort regression.
        let healthy = HangSink()
        let healthyWatchdog = HangWatchdog(policy: fast) { healthy.fire($0) }
        healthyWatchdog.start()
        RunLoop.main.run(until: Date().addingTimeInterval(fast.threshold * 4))
        healthyWatchdog.stop()
        reporter.record("a serviced main run loop never trips the watchdog",
                        healthy.count == 0, healthy.reason ?? "")

        // D. The spurious-abort regression, behaviourally rather than by grep. NSMenu tracking and
        //    window drags run the main run loop in `.eventTracking`, where a `Timer.scheduledTimer`
        //    (which registers in `.default` only) would never fire and the watchdog would abort a
        //    perfectly healthy app mid-menu.
        //
        //    `.eventTracking` is only one of the run loop's COMMON modes once AppKit has said so, which
        //    it does at launch in the real app. This process is headless, so the precondition is
        //    installed here the same way — one CoreFoundation call, no NSApplication, no window server,
        //    so the gate stays in the deterministic tier. Measured 2026-08-19: without this the mode
        //    carries no common-mode timer at all and the check would be a false red.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(),
                               CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let tracking = HangSink()
        let trackingWatchdog = HangWatchdog(policy: fast) { tracking.fire($0) }
        trackingWatchdog.start()
        let trackingDeadline = Date().addingTimeInterval(fast.threshold * 4)
        while Date() < trackingDeadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        trackingWatchdog.stop()
        reporter.record("the heartbeat keeps beating while the main run loop is in .eventTracking, "
                            + "so menu tracking and window drags never trip the watchdog",
                        tracking.count == 0, tracking.reason ?? "")

        // C. The incident's actual shape: the main run loop is alive and servicing work, and one block
        //    ON it blocks for too long. A DispatchQueue-based watcher could be starved by exactly that;
        //    a real thread cannot be, so the verdict still lands.
        let starved = HangSink()
        let starvedWatchdog = HangWatchdog(policy: fast) { starved.fire($0) }
        starvedWatchdog.start()
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: fast.threshold * 4) }
        RunLoop.main.run(until: Date().addingTimeInterval(fast.threshold * 8))
        starvedWatchdog.stop()
        reporter.record("a single over-long block ON the main queue is reported even though the run "
                            + "loop is otherwise alive",
                        starved.count >= 1, "count=\(starved.count)")
    }

    // MARK: - 3. Source rules

    private static func checkSourceRules(_ reporter: SelfTestReporter) {
        let watchdogPath = "Sources/App/HangWatchdog.swift"
        let watchdog = (try? String(contentsOfFile: watchdogPath, encoding: .utf8)) ?? ""
        reporter.record("hang watchdog source is readable from the worktree root", !watchdog.isEmpty,
                        watchdog.isEmpty ? "run this gate from the repository root" : watchdogPath)

        // Forbidden-token rules read CODE, not prose: the doc comments in this very file name both
        // `DispatchQueue` and `Timer.scheduledTimer` while explaining why neither may be used.
        let watchdogCode = codeOnly(watchdog)
        let poll = slice(watchdog, from: "private func poll() {", to: "/// `try()`, not `lock()`")
        let watcherRuleHolds = !poll.isEmpty
            && watchdog.contains("let watcher = Thread {")
            && !watchdogCode.contains("DispatchQueue")
        reporter.record(
            "the watcher is a detached real Thread and the watchdog uses no DispatchQueue",
            watcherRuleHolds,
            watcherRuleHolds ? "" :
                "BROKEN RULE: the heartbeat must be polled by a real Thread. A DispatchQueue is "
                    + "serviced by the same libdispatch machinery a deadlock can starve, so the "
                    + "watcher would be blocked by the very thing it is watching and the hang would "
                    + "go unreported. See \(adrReference) and \(deadlockReference)")

        let startBody = slice(watchdog, from: "func start() {", to: "/// Disarm.")
        let timerRuleHolds = startBody.contains("RunLoop.main.add(beatTimer, forMode: .common)")
            && !watchdogCode.contains("Timer.scheduledTimer")
        reporter.record(
            "the heartbeat timer is registered in .common run loop modes",
            timerRuleHolds,
            timerRuleHolds ? "" :
                "BROKEN RULE: Timer.scheduledTimer registers in .default only. NSMenu tracking, a "
                    + "window drag, and any modal panel switch the main run loop out of .default, so a "
                    + "default-mode heartbeat stops during ordinary UI interaction and the watchdog "
                    + "aborts a perfectly healthy app. See \(adrReference)")

        let production = slice(watchdog, from: "static func productionWatchdog() -> HangWatchdog {",
                               to: "\n}")
        let logIndex = production.range(of: "Log.writeBeforeCrash(reason)")?.lowerBound
        let abortIndex = production.range(of: "abort()")?.lowerBound
        let orderRuleHolds = watchdogCode.components(separatedBy: "abort()").count - 1 == 1
        let logsBeforeAbort: Bool
        if let logIndex, let abortIndex {
            logsBeforeAbort = logIndex < abortIndex
        } else {
            logsBeforeAbort = false
        }
        reporter.record(
            "the hang reason is logged before abort(), and abort() appears exactly once",
            orderRuleHolds && logsBeforeAbort,
            orderRuleHolds && logsBeforeAbort ? "" :
                "BROKEN RULE: ADR 0017 accepts that this app's crash reports now mean 'crashed OR "
                    + "hung'. The logged reason is the ONLY thing that tells the two apart afterwards, "
                    + "so it must be written, and flushed, before the process dies. See \(adrReference)")

        let logSource = (try? String(contentsOfFile: "Sources/App/Log.swift", encoding: .utf8)) ?? ""
        let crashWrite = slice(logSource, from: "static func writeBeforeCrash(",
                               to: "/// Headless deterministic-test barrier")
        let boundedRuleHolds = !crashWrite.isEmpty
            && crashWrite.contains("wait(timeout:")
            && crashWrite.contains("FileHandle(forWritingTo: url)")
        reporter.record(
            "the crash-path log flush is bounded and falls back to a direct append",
            boundedRuleHolds,
            boundedRuleHolds ? "" :
                "BROKEN RULE: writeBeforeCrash is called by the watchdog itself. An unbounded barrier "
                    + "on a wedged log queue would swallow the abort and the hang would go unreported "
                    + "exactly as it did on 2026-08-18. See \(adrReference)")

        let delegate = (try? String(contentsOfFile: "Sources/App/AppDelegate.swift",
                                    encoding: .utf8)) ?? ""
        let launch = slice(delegate, from: "func applicationDidFinishLaunching(",
                           to: "/// First-run provider onboarding")
        let armRuleHolds = delegate.contains("HangWatchdog.productionWatchdog()")
            && launch.contains("hangWatchdog.start()")
        reporter.record(
            "AppDelegate arms the production watchdog during launch",
            armRuleHolds,
            armRuleHolds ? "" :
                "BROKEN RULE: an unarmed watchdog is indistinguishable from no watchdog, and every "
                    + "other gate here would still pass. See \(adrReference)")

        let willTerminate = slice(delegate, from: "func applicationWillTerminate(", to: "\n    }")
        let quitRuleHolds = willTerminate.contains("hangWatchdog.stop()")
        reporter.record(
            "a deliberate quit disarms the watchdog before teardown runs",
            quitRuleHolds,
            quitRuleHolds ? "" :
                "BROKEN RULE: teardown is the one main-thread stretch allowed to be slow, and an abort "
                    + "during it would be relaunched by KeepAlive — the app would come back from the "
                    + "quit the user just asked for. See \(adrReference)")

        // ADR 0017 chose an in-process watchdog over a supervising LaunchAgent precisely so nothing new
        // has to be installed, shipped, notarized, and supported. A second plist appearing here means
        // that decision was reversed without reversing the ADR.
        let plists = ((try? FileManager.default.contentsOfDirectory(atPath: "."))
                        ?? []).filter { $0.hasSuffix(".plist") && $0.hasPrefix("com.viddydictate.") }
            .sorted()
        let expectedPlists = ["com.viddydictate.app.plist", "com.viddydictate.whisperd.plist"]
        reporter.record(
            "the watchdog added no LaunchAgent",
            plists == expectedPlists,
            plists == expectedPlists ? "" :
                "BROKEN RULE: ADR 0017 rejected an external watchdog LaunchAgent. The watchdog turns a "
                    + "hang into a non-zero exit so the EXISTING KeepAlive relaunches it. "
                    + "See \(adrReference). Found \(plists)")

        let appPlist = (try? String(contentsOfFile: "com.viddydictate.app.plist",
                                    encoding: .utf8)) ?? ""
        let keepAliveHolds = appPlist.contains("<key>KeepAlive</key>")
            && appPlist.contains("<key>SuccessfulExit</key>")
            && appPlist.contains("<false/>")
        reporter.record(
            "the existing LaunchAgent still relaunches on a non-zero exit, which is what the abort "
                + "converts the hang into",
            keepAliveHolds,
            keepAliveHolds ? "" :
                "BROKEN RULE: without KeepAlive/SuccessfulExit=false the abort is a plain crash and the "
                    + "app never comes back, which is strictly worse than the hang. See \(adrReference)")
    }

    /// Source with comment-only lines removed, so a rule that forbids a token is not tripped by the
    /// comment that explains why the token is forbidden.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func slice(_ source: String, from start: String, to end: String) -> String {
        guard let a = source.range(of: start),
              let b = source.range(of: end, range: a.upperBound..<source.endIndex) else { return "" }
        return String(source[a.lowerBound..<b.lowerBound])
    }
}

/// Records what the watchdog decided, from the watcher thread.
private final class HangSink {
    private let lock = NSLock()
    private var storedReason: String?
    private var storedCount = 0

    func fire(_ reason: String) {
        lock.lock()
        storedReason = storedReason ?? reason
        storedCount += 1
        lock.unlock()
    }

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedReason
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }
}
