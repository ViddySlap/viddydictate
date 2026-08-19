import Darwin
import Foundation

/// Pure decision layer for the hang watchdog, so the threshold and the verdict can be gated without
/// running a timer, a thread, or a clock. See `HangWatchdog` for the mechanism and ADR 0017 for why
/// this exists at all.
struct HangWatchdogPolicy: Equatable {
    /// How long main may go without ticking before the process is declared hung.
    ///
    /// **45 seconds, decided by Ben on 2026-08-19. It is a floor-with-margin, not a precision target,
    /// and it must never be shaved.** The trade is deliberately lopsided: too tight ships a brand new
    /// failure mode in which a working session is killed and a real dictation destroyed, while too
    /// loose only delays a recovery that on 2026-08-18 took 3.5 hours and a manual `launchctl kickstart`.
    ///
    /// Measured against what actually blocks main (2026-08-19, this codebase, macOS 15):
    ///
    /// - The longest legitimate main-thread block is the Accessibility chain in
    ///   `TargetResolver.captureFocused()`: five sequential `AXUIElement*` round trips, each bounded
    ///   only by the default AX messaging timeout, which measured 1.51s against a wedged target. That
    ///   is ~7.6s worst case, comfortably inside the threshold.
    /// - The transcription pause is NOT what this watches and cannot trip it. `DaemonClient.transcribe`
    ///   is fully async (URLSession, escaping completion, no semaphore, no `main.sync` on that path),
    ///   so the few seconds a user feels after releasing a take never block main.
    let threshold: TimeInterval

    /// How often main stamps the heartbeat. Several beats must fit inside one threshold so a single
    /// late beat is never a verdict.
    let beatInterval: TimeInterval

    /// How often the watcher thread looks. Also the resolution of every gap this can report.
    let pollInterval: TimeInterval

    /// How far the watcher's OWN sleep may overshoot before its clock reading stops being evidence.
    /// System sleep, SIGSTOP, a debugger, and an App Nap freeze all stop main and the watcher alike;
    /// none of them is a hang.
    let clockJumpTolerance: TimeInterval

    /// The one shipped configuration. `AppDelegate` and the abort proof both build from it, so the
    /// proof exercises exactly what ships.
    static let production = HangWatchdogPolicy(threshold: 45,
                                               beatInterval: 5,
                                               pollInterval: 5,
                                               clockJumpTolerance: 5)

    enum Verdict: Equatable {
        case healthy
        case clockJumped
        case hung
    }

    /// A gap smaller than one full beat-plus-poll cycle is ordinary scheduling slop, so anything at or
    /// under this is not worth a log line. Reporting starts just above it, which makes every stall this
    /// records a real missed beat rather than jitter.
    var reportFloor: TimeInterval { beatInterval + pollInterval + 2 }

    /// `gap` is how long since main last stamped the heartbeat. `pollOvershoot` is how much longer the
    /// watcher's own sleep took than it asked for.
    ///
    /// A clock jump OUTRANKS a hang deliberately. After the machine wakes from sleep, main's last beat
    /// can look arbitrarily old while nothing is wrong at all, and a watchdog that aborted every
    /// morning would be a worse bug than the one it was built for.
    func verdict(gap: TimeInterval, pollOvershoot: TimeInterval) -> Verdict {
        if pollOvershoot > clockJumpTolerance { return .clockJumped }
        return gap >= threshold ? .hung : .healthy
    }

    /// The shape the mechanism depends on: at least three beats inside a threshold, a watcher that
    /// looks at least as often as main ticks, and a jump tolerance that cannot be reached by ordinary
    /// scheduling slop.
    var isWellFormed: Bool {
        threshold > 0 && beatInterval > 0 && pollInterval > 0
            && beatInterval * 3 <= threshold
            && pollInterval <= beatInterval
            && clockJumpTolerance >= pollInterval
            && reportFloor < threshold
    }
}

/// Turns an invisible main-thread hang into a visible crash. ADR 0017.
///
/// `KeepAlive: SuccessfulExit=false` in `com.viddydictate.app.plist` relaunches the app when it EXITS
/// non-zero, and a deadlocked process never exits — so on 2026-08-18 the app froze for about 3.5 hours
/// with no crash report, no log line, and no relaunch. This makes it exit: the abort below raises
/// SIGABRT, which is a non-zero exit the existing KeepAlive already knows how to handle, and which leaves
/// ReportCrash a real `.ips` carrying every thread's stack. **No new LaunchAgent** — the whole point is
/// to make the machinery already installed able to see the failure.
///
/// A main-thread `Timer` stamps a heartbeat; a **detached real `Thread`** polls it. The watcher is a
/// Thread and deliberately NOT a `DispatchQueue`: a queue is serviced by the same libdispatch machinery
/// a deadlock can starve, so the watcher could be blocked by the very thing it is watching. A real
/// thread is scheduled by the kernel and cannot be.
///
/// This is a safety net. It fixes nothing and prevents no deadlock — the structural fix for the
/// 2026-08-18 freeze is independent (the store no longer runs caller code with its queue held, and
/// `stillCurrent` no longer blocks on main). Its only job is that the NEXT unknown hang announces
/// itself instead of costing an afternoon.
///
/// See `Projects/viddydictate/decisions/0017-hang-watchdog-aborts-into-keepalive.md` and
/// `Projects/viddydictate/wiki/reference/retained-take-deadlock.md`.
final class HangWatchdog {
    private let policy: HangWatchdogPolicy
    private let onHang: (String) -> Void

    /// Guards `lastBeat` only. Main takes it to stamp a number and calls nothing while holding it —
    /// running unknown code under a held lock is precisely the bug this whole chain exists to remove.
    private let lock = NSLock()
    private var lastBeat: TimeInterval = 0
    private var stopped = false

    private var timer: Timer?

    /// Watcher-thread-only state; never touched from main, so it needs no lock.
    private var lastObservedBeat: TimeInterval = 0
    private var worstObservedGap: TimeInterval = 0

    init(policy: HangWatchdogPolicy = .production, onHang: @escaping (String) -> Void) {
        self.policy = policy
        self.onHang = onHang
    }

    /// Arm from the main thread. Seeds one beat synchronously so the first window starts clean.
    func start() {
        let now = Self.uptime()
        lock.lock()
        lastBeat = now
        stopped = false
        lock.unlock()
        lastObservedBeat = now

        // `.common`, not `Timer.scheduledTimer`, which registers in `.default` only. NSMenu tracking,
        // a window drag, and any modal panel switch the main run loop out of `.default`; a heartbeat
        // that stopped during an ordinary menu interaction would abort a perfectly healthy app, which
        // is the one failure mode this must never ship.
        let beatTimer = Timer(timeInterval: policy.beatInterval, repeats: true) { [weak self] _ in
            self?.beat()
        }
        RunLoop.main.add(beatTimer, forMode: .common)
        timer = beatTimer

        let watcher = Thread { [self] in poll() }
        watcher.name = AppIdentity.queueLabel("hang-watchdog")
        watcher.qualityOfService = .utility
        watcher.stackSize = 512 * 1024
        watcher.start()
    }

    /// Disarm. The watcher notices at its next poll, so the thread outlives this call by up to one
    /// poll interval; nothing else does.
    func stop() {
        timer?.invalidate()
        timer = nil
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// Main's only job in all of this: stamp a number.
    private func beat() {
        let now = Self.uptime()
        lock.lock()
        lastBeat = now
        lock.unlock()
    }

    private func poll() {
        var expectedWake = Self.uptime()
        while true {
            Thread.sleep(forTimeInterval: policy.pollInterval)
            let now = Self.uptime()
            let overshoot = max(0, (now - expectedWake) - policy.pollInterval)
            expectedWake = now
            if isStopped() { return }

            let gap = max(0, now - observeLastBeat())
            switch policy.verdict(gap: gap, pollOvershoot: overshoot) {
            case .clockJumped:
                // Neither this thread nor main was running, so the gap is not evidence of anything.
                // Re-baseline and wait for main's next real beat rather than accusing it. `try()` for
                // the same reason `observeLastBeat` uses it: this thread never blocks on main's lock.
                lastObservedBeat = now
                if lock.try() {
                    lastBeat = now
                    lock.unlock()
                }
            case .healthy:
                noteGap(gap)
            case .hung:
                onHang(reason(gap: gap))
                return
            }
        }
    }

    /// `try()`, not `lock()`. If main ever wedged while holding this lock, a blocking read would block
    /// the watcher too and the hang would go unreported — the watchdog would have inherited the exact
    /// failure it exists to catch. A failed try keeps the previous reading, so the gap keeps growing
    /// and the verdict still lands.
    private func observeLastBeat() -> TimeInterval {
        guard lock.try() else { return lastObservedBeat }
        lastObservedBeat = lastBeat
        lock.unlock()
        return lastObservedBeat
    }

    private func isStopped() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        return stopped
    }

    /// Soak evidence. ADR 0017 sets the threshold from a measurement, and Ben runs this on his daily
    /// driver before anyone else does, so every new worst stall goes in the log and the threshold stops
    /// being a guess. Only new records above `reportFloor` are written, so a healthy app logs nothing.
    private func noteGap(_ gap: TimeInterval) {
        guard gap >= policy.reportFloor, gap > worstObservedGap else { return }
        worstObservedGap = gap
        Log.write(String(format: "hang-watchdog: worst main-thread stall so far %.1fs (threshold %.0fs)",
                         gap, policy.threshold))
    }

    private func reason(gap: TimeInterval) -> String {
        String(format: "HANG WATCHDOG: main thread has not ticked for %.1fs (threshold %.0fs). "
                + "Aborting so KeepAlive relaunches and ReportCrash captures every thread stack. "
                + "This crash report is a HANG, not a crash.",
               gap, policy.threshold)
    }

    /// The uptime clock, which on Darwin does not advance while the system is asleep — so an overnight
    /// sleep cannot look like a 9-hour hang. The watcher's own overshoot check in `poll()` is the second
    /// half of that defence, and covers the cases this clock would not.
    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

extension HangWatchdog {
    /// The one shipped wiring. Both `AppDelegate` and the opt-in abort proof build the watchdog through
    /// here, so what the proof kills is exactly what ships.
    static func productionWatchdog() -> HangWatchdog {
        HangWatchdog(policy: .production) { reason in
            // The reason is written BEFORE the abort, and synchronously. ADR 0017 accepts that crash
            // reports for this app now mean "crashed OR hung", and this line is the only thing that
            // tells the two apart afterwards. `Log.write` is an async enqueue on a utility queue, so
            // an unflushed line would die with the process.
            Log.writeBeforeCrash(reason)
            FileHandle.standardError.write(Data((reason + "\n").utf8))
            abort()
        }
    }
}
