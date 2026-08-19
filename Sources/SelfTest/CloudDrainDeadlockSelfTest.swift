import Darwin
import Foundation

/// Falsifying gate for the UNBOUNDED PIPE DRAIN in `CloudCleanupClient.runProcess`.
///
/// WHAT IT PROVES. `runProcess` bounds the KILL with `timeout` and `grace`, but the three drain
/// waits have no deadline at all:
///
///     writerDone.wait()
///     outputDone.wait()
///     errorDone.wait()
///
/// A descendant that `setsid`s OUT of the spawned process group while still holding stdout defeats
/// the whole teardown by construction. `kill(-pid, ...)` cannot reach it, `processGroupIsEmpty`
/// therefore reports the group EMPTY so `residualProcessGroup` is false and the cleanup reads
/// CLEAN, and the pipe never sees EOF - so the drain never returns. The calling thread parks
/// forever: no `.timedOut`, no raw fallback, no log line. ADR 0017's hang watchdog cannot catch it
/// either, because it watches the MAIN thread while this parks a global-queue thread.
///
/// Measured 3/3 by `vdd-F2`, pinned with two `sample` captures 12 s apart, identical at 0% CPU.
/// Method, numbers and the original fixture scripts:
/// `Projects/viddydictate/wiki/reference/process-group-reaping.md`.
///
/// TWO CASES, AND THE FIRST ONE IS THE CONTROL. `contained` runs a SIGTERM-ignoring pipe holder
/// that stays INSIDE the group: the bounded cleanup reaches it, the pipe closes, the drain returns,
/// and the check is green. `escaped` runs the same holder after `setsid`. Without the control a
/// red result would be indistinguishable from a harness that cannot report green at all, and this
/// gate is built before the fix precisely so its verdict can be trusted afterwards.
///
/// HOW IT IS RUN. Opt-in sub-flag of `--text-transform-selftest`, never a manifest flag of its own:
///
///     ViddyDictateTests --text-transform-selftest --cloud-drain-deadlock-repro
///
/// THE `escaped` CASE IS EXPECTED TO FAIL UNTIL THE DRAINS ARE BOUNDED. That is the entire point of
/// building it first - a gate that passed against the unfixed transport would prove nothing about
/// the fix. It is therefore deliberately OUT of every `verify.sh` tier for now, exactly like
/// `--audio-retention-deadlock-repro` was while `vdd-L1` proved the retained-take deadlock red.
/// Once the drains carry a deadline, wire it in permanently beside the other transport gates in
/// `tier_deterministic`, immediately after the `--text-transform-selftest` gate:
///
///     run_gate deterministic "Claude transport escaped-pipe-holder drain deadline repro" \
///         env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
///         "$TEST_APP" --text-transform-selftest --cloud-drain-deadlock-repro || true
///
/// NOTHING HERE MAY WEDGE THE SUITE. `vdd-F2`'s throwaway probe had to be killed externally at
/// 20-25 s against a 5 s budget, and a test that can do that is not acceptable. So each case runs
/// in a disposable child, and each is bounded TWICE: the child stops observing at
/// `drainObservationBudget` and reports the hang itself, and the parent SIGKILLs it at
/// `hardTimeout` regardless. The parent never waits on anything unbounded.
///
/// THE ORPHAN IS DELIBERATE AND IS CLEANED UP HERE. The `escaped` fixture's holder survives a
/// process-group kill by design; leaving it behind while testing an orphan leak would be both
/// ironic and confusing for whoever looks next. The parent kills it by the pid the fixture
/// recorded, polls until `kill(pid, 0)` reports ESRCH, and fails the check if it is still there.
/// The holder also self-limits after `escapeeLifetimeSeconds` as a backstop, never as the primary
/// mechanism.
enum CloudDrainDeadlockSelfTest {
    private static let reproFlag = CloudDrainDeadlockFlag.repro.rawValue
    private static let childFlag = CloudDrainDeadlockFlag.child.rawValue
    private static let scratchRootFlag = CloudDrainDeadlockFlag.scratchRoot.rawValue

    /// How long the child watches `runProcess` before calling the drain unbounded.
    ///
    /// This MUST stay above the production drain deadline, and it is NOT the same clock as the
    /// caller's `timeout`/`grace`. If the bound chosen for the drains ever exceeds this, RAISE this
    /// number - never trim the production bound to fit this test. Pre-fix nothing bounds the drain
    /// at all, so this is simply how long the `escaped` case spends proving that.
    private static let drainObservationBudget: TimeInterval = 15

    /// Hard external bound on the whole child: the backstop that makes this safe in a suite.
    private static let hardTimeout: TimeInterval = 20

    /// The spawn watchdog the child hands `runProcess`. Both fixtures' leaders exit as soon as
    /// their holder is up, so this is never reached on any healthy path; it exists so a fixture
    /// that somehow fails to exit still gets torn down rather than becoming a second hang.
    private static let spawnTimeout: TimeInterval = 5
    private static let spawnGrace: TimeInterval = 0.25

    /// How long the child waits for the fixture to report its holder up. A miss here is a FIXTURE
    /// fault, reported as one, never as evidence of the bug.
    private static let readySeconds: TimeInterval = 5

    /// How long the child watches production's own `processGroupIsEmpty` predicate after the leader
    /// exits. Only the `escaped` case can ever satisfy it; the `contained` case leaves this loop
    /// early the moment its drain returns.
    private static let groupObservationSeconds: TimeInterval = 3

    /// Backstop lifetime for the deliberate orphan. Long enough that the holder is unambiguously
    /// alive for the whole measured window, short enough that a catastrophically interrupted run
    /// cannot leave it on the machine for long. Explicit cleanup remains the primary mechanism.
    private static let escapeeLifetimeSeconds = 90

    private static let fixtureName = "pipe-holder-fixture"
    private static let leaderPIDName = "leader.pid"
    private static let holderPIDName = "holder.pid"
    private static let readyName = "holder.ready"
    private static let verdictName = "child-verdict.txt"

    private struct Case {
        let key: String
        let label: String
        /// True when the holder leaves the process group, which is the shape under test.
        let escapes: Bool
        /// The holder's real executable, checked before any kill so a recycled pid is never hit.
        let holderBinary: String
    }

    private static let cases = [
        Case(key: "contained",
             label: "CONTROL: a same-group pipe holder is cleaned and runProcess returns",
             escapes: false, holderBinary: "/bin/sh"),
        Case(key: "escaped",
             label: "an escaped pipe holder must not park runProcess forever",
             escapes: true, holderBinary: "/usr/bin/perl"),
    ]

    /// Sub-flag dispatch, mirroring `AudioRetentionSelfTest.deadlockReproExit`. Returns nil when no
    /// sub-flag is present so the ordinary `--text-transform-selftest` gate runs untouched.
    static func reproExit(arguments: [String]) -> Int32? {
        if arguments.contains(childFlag) {
            guard let index = arguments.firstIndex(of: scratchRootFlag),
                  index + 1 < arguments.count else {
                print("[cloud-drain-deadlock-child] FAIL: scratch root is required")
                return 2
            }
            return runChild(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
        guard arguments.contains(reproFlag) else { return nil }
        return runRepro() ? 0 : 1
    }

    // MARK: - parent

    private static func runRepro() -> Bool {
        print("--- Claude transport: pipe holder vs unbounded drain (subprocess repro) ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-cloud-drain-deadlock-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        guard let executable = Bundle.main.executableURL else {
            reporter.record("repro harness can launch a disposable child", false,
                            "test executable path unavailable")
            print(reporter.summaryLine(prefix: "[cloud-drain-deadlock-selftest]"))
            return false
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            reporter.record("repro harness can create its scratch root", false, "\(error)")
            print(reporter.summaryLine(prefix: "[cloud-drain-deadlock-selftest]"))
            return false
        }

        for item in cases {
            run(case: item, under: root, executable: executable, reporter: reporter)
        }
        if !reporter.passed {
            print("[cloud-drain-deadlock-selftest] EXPECTED PRE-FIX: the drain waits in "
                + "CloudCleanupClient.runProcess have no deadline, so an escaped pipe holder parks "
                + "the caller permanently. This gate turns green when they are bounded.")
        }
        print(reporter.summaryLine(prefix: "[cloud-drain-deadlock-selftest]"))
        return reporter.passed
    }

    private static func run(case item: Case, under parent: URL, executable: URL,
                            reporter: SelfTestReporter) {
        print("--- case: \(item.key) ---")
        let fm = FileManager.default
        let root = parent.appendingPathComponent(item.key, isDirectory: true)
        let fixture = root.appendingPathComponent(fixtureName)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            // Installed HERE, in the parent, so macOS's one-time first-execution assessment is
            // charged outside the child's measured window. See SelfTestFixtureExecutable and
            // Projects/viddydictate/wiki/reference/selftest-fixture-gatekeeper-trap.md.
            try SelfTestFixtureExecutable.install(script: fixtureScript(root: root,
                                                                       escapes: item.escapes),
                                                  at: fixture)
        } catch {
            reporter.record(item.label, false, "fixture setup: \(error)")
            return
        }

        let childLog = root.appendingPathComponent("child.log")
        guard fm.createFile(atPath: childLog.path, contents: nil),
              let childLogHandle = try? FileHandle(forWritingTo: childLog) else {
            reporter.record(item.label, false, "child log could not be created")
            return
        }
        defer { try? childLogHandle.close() }

        let child = Process()
        child.executableURL = executable
        child.arguments = [
            SelfTestManifestFlag.textTransformSelftest.rawValue,
            childFlag,
            scratchRootFlag, root.path,
        ]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = childLogHandle
        child.standardError = childLogHandle
        let childExited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in childExited.signal() }
        do {
            try child.run()
        } catch {
            reporter.record(item.label, false, "child launch: \(error)")
            return
        }

        let started = Date()
        let deadline = started.addingTimeInterval(hardTimeout)
        let readyFile = root.appendingPathComponent(readyName)
        let sampleFile = root.appendingPathComponent("drain.sample.txt")
        var childDidExit = false
        var sampler: Process?
        var samplerExited: DispatchSemaphore?
        var samplingAttempted = false

        while Date() < deadline {
            if childExited.wait(timeout: .now()) == .success { childDidExit = true; break }
            // Only the case that can park is worth sampling; the control returns in milliseconds.
            if item.escapes, !samplingAttempted,
               Date().timeIntervalSince(started) >= 2,
               fm.fileExists(atPath: readyFile.path) {
                samplingAttempted = true
                (sampler, samplerExited) = startSampler(pid: child.processIdentifier,
                                                        root: root, sampleFile: sampleFile)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !childDidExit, childExited.wait(timeout: .now()) == .success { childDidExit = true }

        let timedOut = !childDidExit
        if timedOut {
            _ = kill(child.processIdentifier, SIGKILL)
            childDidExit = childExited.wait(timeout: .now() + 1) == .success
        }
        if let sampler, sampler.isRunning { _ = kill(sampler.processIdentifier, SIGKILL) }
        if let samplerExited { _ = samplerExited.wait(timeout: .now() + 0.5) }
        let elapsed = Date().timeIntervalSince(started)

        printPinnedStacks(at: sampleFile)
        for line in readLines(root.appendingPathComponent(verdictName)) { print("  \(line)") }
        for line in readLines(childLog) { print("  [child] \(line)") }

        // The deliberate orphan, cleared by the pid the fixture recorded rather than by pattern.
        let holder = pid(in: root.appendingPathComponent(holderPIDName))
        let leader = pid(in: root.appendingPathComponent(leaderPIDName))
        let holderClear = clearProcess(holder, expecting: item.holderBinary)
        let leaderClear = clearProcess(leader, expecting: fixture.path)

        let exitOK = childDidExit && child.terminationReason == .exit
            && child.terminationStatus == 0
        let detail = String(
            format: "elapsed=%.2fs child_budget=%.0fs hard_timeout=%.0fs child_exit=%@ sample=%@ "
                + "holder_pid=%@ holder=%@ leader=%@",
            elapsed, drainObservationBudget, hardTimeout,
            childDidExit ? (timedOut ? "SIGKILL-after-hard-timeout" : "\(child.terminationStatus)")
                         : "never-exited",
            fm.fileExists(atPath: sampleFile.path) ? "captured" : "not-taken",
            holder.map(String.init) ?? "unrecorded",
            holderClear.note, leaderClear.note)
        reporter.record(item.label, exitOK && holderClear.cleared && leaderClear.cleared, detail)
    }

    private static func startSampler(pid: pid_t, root: URL,
                                     sampleFile: URL) -> (Process?, DispatchSemaphore?) {
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(pid), "1", "-file", sampleFile.path]
        sampler.standardInput = FileHandle.nullDevice
        let sampleLog = root.appendingPathComponent("sample.log")
        if FileManager.default.createFile(atPath: sampleLog.path, contents: nil),
           let handle = try? FileHandle(forWritingTo: sampleLog) {
            sampler.standardOutput = handle
            sampler.standardError = handle
            sampler.terminationHandler = { _ in try? handle.close() }
        }
        let exited = DispatchSemaphore(value: 0)
        let priorHandler = sampler.terminationHandler
        sampler.terminationHandler = { process in priorHandler?(process); exited.signal() }
        do {
            try sampler.run()
            return (sampler, exited)
        } catch {
            print("[cloud-drain-deadlock-selftest] sample unavailable: \(error)")
            return (nil, nil)
        }
    }

    /// The frames that make this diagnosis unambiguous: the caller parked in the semaphore under
    /// `runProcess`, and both reader threads parked in `read()` under `NSConcreteFileHandle`.
    private static func printPinnedStacks(at sampleFile: URL) {
        guard let sample = try? String(contentsOf: sampleFile, encoding: .utf8) else { return }
        let pinned = sample.split(separator: "\n")
            .filter {
                $0.contains("CloudCleanupClient.runProcess")
                    || $0.contains("semaphore_wait_trap")
                    || $0.contains("readDataOfLength")
            }
            .prefix(12)
        guard !pinned.isEmpty else { return }
        print("[cloud-drain-deadlock-selftest] sampled blocked stacks:")
        for line in pinned { print("  \(line)") }
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    private static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil }
    }

    /// SIGKILL the recorded pid and its group, then VERIFY death with `kill(pid, 0)` rather than
    /// trusting the kill's own exit status. `waitpid` is useless for the escapee: it is reparented
    /// to launchd, so it is nobody's child to reap.
    ///
    /// The `expecting` guard exists because a pid is only a name. The escaped holder is alive
    /// continuously, so its pid cannot have been recycled - but the fixture's leader is reaped by
    /// production code seconds before this runs, and signalling a stranger who inherited its number
    /// would be a far worse bug than the one under test. So the pid's real executable is read back
    /// first, and a mismatch means our process is already gone: nothing to kill, nothing leaked.
    private static func clearProcess(_ target: pid_t?,
                                     expecting binary: String) -> (cleared: Bool, note: String) {
        guard let target, target > 0 else { return (true, "unrecorded") }
        errno = 0
        if kill(target, 0) != 0 && errno == ESRCH { return (true, "gone") }
        if let path = executablePath(of: target), path != binary {
            return (true, "pid-recycled-left-alone")
        }
        _ = kill(-target, SIGKILL)
        _ = kill(target, SIGKILL)
        var status: Int32 = 0
        while waitpid(target, &status, WNOHANG) < 0 && errno == EINTR {}
        for _ in 0..<100 {
            errno = 0
            if kill(target, 0) != 0 && errno == ESRCH { return (true, "killed") }
            usleep(20_000)
        }
        return (false, "SURVIVED")
    }

    private static func executablePath(of target: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(target, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - child

    /// Drives the REAL production transport against whichever fixture the parent installed, on a
    /// background queue, and watches it from main under `drainObservationBudget`. Exit codes:
    /// 0 the drain returned, 3 it did not (the bug), 2 the fixture did not set the stage.
    private static func runChild(root: URL) -> Int32 {
        guard Thread.isMainThread else {
            print("[cloud-drain-deadlock-child] FAIL: entrypoint is not on main")
            return 2
        }
        let fm = FileManager.default
        let fixture = root.appendingPathComponent(fixtureName)
        guard fm.isExecutableFile(atPath: fixture.path) else {
            print("[cloud-drain-deadlock-child] FAIL: parent installed no fixture at \(fixture.path)")
            return 2
        }
        let readyFile = root.appendingPathComponent(readyName)

        let outcome = CloudDrainDeadlockChildOutcome()
        let returned = DispatchSemaphore(value: 0)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let run = CloudCleanupClient.runProcessForTest(
                executable: fixture.path, arguments: [],
                timeout: spawnTimeout, grace: spawnGrace)
            outcome.store(run)
            returned.signal()
        }

        func drainAlreadyReturned() -> Bool {
            guard returned.wait(timeout: .now()) == .success else { return false }
            returned.signal()
            return true
        }

        // The stage is only set once the holder is up and holding the pipe.
        var holderReady = false
        let readyDeadline = Date().addingTimeInterval(readySeconds)
        while Date() < readyDeadline {
            if fm.fileExists(atPath: readyFile.path),
               (try? String(contentsOf: readyFile, encoding: .utf8))?.isEmpty == false {
                holderReady = true
                break
            }
            if drainAlreadyReturned() { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let holder = pid(in: root.appendingPathComponent(holderPIDName))
        let leader = pid(in: root.appendingPathComponent(leaderPIDName))
        let holderAlive = holder.map { kill($0, 0) == 0 } ?? false
        let holderPGID = holder.map { getpgid($0) } ?? -1
        let leftTheGroup = holder != nil && leader != nil && holderPGID != leader!

        // The sharpest edge of this bug: once the leader is gone, production's own
        // `processGroupIsEmpty` predicate reports the group EMPTY while the holder is demonstrably
        // alive on the pipe - so `residualProcessGroup` reads false and the teardown reads CLEAN.
        // Polled rather than sampled once, because the leader exits a beat after it writes the
        // ready marker and a single reading lands on either side of that by luck.
        var groupEmptyWhileHolderAlive = false
        let groupDeadline = Date().addingTimeInterval(groupObservationSeconds)
        while Date() < groupDeadline, let leader, let holder {
            errno = 0
            if kill(-leader, 0) != 0, errno == ESRCH, kill(holder, 0) == 0 {
                groupEmptyWhileHolderAlive = true
                break
            }
            if drainAlreadyReturned() { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let remaining = max(0.25, started.addingTimeInterval(drainObservationBudget)
            .timeIntervalSinceNow)
        let drainReturned = returned.wait(
            timeout: .now() + .milliseconds(Int(remaining * 1_000))) == .success
        let observed = Date().timeIntervalSince(started)

        var lines = [
            "holder_ready=\(holderReady)",
            "holder_pid=\(holder.map(String.init) ?? "unrecorded") holder_alive=\(holderAlive)",
            "holder_pgid=\(holderPGID) leader_pid=\(leader.map(String.init) ?? "unrecorded")",
            "holder_left_the_process_group=\(leftTheGroup)",
            "group_reported_empty_while_holder_alive=\(groupEmptyWhileHolderAlive)",
            "drain_returned=\(drainReturned)",
            String(format: "observed=%.2fs budget=%.0fs", observed, drainObservationBudget),
        ]
        if let run = outcome.result {
            lines.append("result timedOut=\(run.timedOut) leaderReaped=\(run.leaderReaped) "
                + "escalated=\(run.escalatedToSIGKILL) hadResidual=\(run.hadResidualProcessGroup) "
                + "residual=\(run.residualProcessGroup) stdout_bytes=\(run.stdout.count)")
        } else if outcome.completed {
            lines.append("result=nil (runProcess threw)")
        }
        let verdict = lines.joined(separator: "\n")
        try? Data(verdict.utf8).write(to: root.appendingPathComponent(verdictName),
                                      options: .atomic)
        print("[cloud-drain-deadlock-child] \(lines.joined(separator: " "))")

        guard holderReady, holderAlive else {
            print("[cloud-drain-deadlock-child] FAIL: fixture never staged a live pipe holder")
            return 2
        }
        if drainReturned {
            print("[cloud-drain-deadlock-child] PASS: the drain returned")
            return 0
        }
        print("[cloud-drain-deadlock-child] FAIL: runProcess never returned - the drain waits have "
            + "no deadline, so the escaped pipe holder parks the caller permanently")
        return 3
    }

    /// Interpolated absolute paths rather than argv, matching the sibling fixtures in
    /// `CodexModelCatalogSelfTest`, so nothing collides with the warm-up guard's argv[1] sentinel.
    /// Both variants ignore SIGTERM and hold stdout; the ONLY difference is `setsid`. The leader
    /// exits 0 the moment its holder is up, which is what makes the group read EMPTY and the
    /// teardown read CLEAN in the escaped case while the pipe is still held.
    private static func fixtureScript(root: URL, escapes: Bool) -> String {
        let leaderPIDFile = root.appendingPathComponent(leaderPIDName)
        let holderPIDFile = root.appendingPathComponent(holderPIDName)
        let readyFile = root.appendingPathComponent(readyName)
        let holder: String
        if escapes {
            holder = """
            /usr/bin/perl -e 'use POSIX qw(setsid); setsid(); $SIG{TERM}="IGNORE"; $SIG{INT}="IGNORE"; $SIG{HUP}="IGNORE"; open(F,">",$ARGV[0]); print F $$; close(F); open(R,">",$ARGV[1]); print R "ready"; close(R); sleep \(escapeeLifetimeSeconds);' "\(holderPIDFile.path)" "\(readyFile.path)" &
            """
        } else {
            holder = """
            (
              trap '' TERM INT HUP
              /usr/bin/printf 'ready' > "\(readyFile.path)"
              while :; do /bin/sleep 1; done
            ) &
            /usr/bin/printf '%s\\n' "$!" > "\(holderPIDFile.path)"
            """
        }
        return """
        #!/bin/sh
        /usr/bin/printf '%s\\n' "$$" > "\(leaderPIDFile.path)"
        \(holder)
        while [ ! -s "\(readyFile.path)" ]; do /bin/sleep 0.01; done
        /usr/bin/printf '%s\\n' '{"type":"result","is_error":false,"result":"pipe-holder-ok"}'
        exit 0
        """
    }
}

/// The background drive and the main-thread observer touch this from two threads.
private final class CloudDrainDeadlockChildOutcome {
    private let lock = NSLock()
    private var stored: CloudCleanupClient.ProcessRunResult?
    private var didComplete = false

    func store(_ result: CloudCleanupClient.ProcessRunResult?) {
        lock.lock()
        stored = result
        didComplete = true
        lock.unlock()
    }

    var result: CloudCleanupClient.ProcessRunResult? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var completed: Bool {
        lock.lock(); defer { lock.unlock() }
        return didComplete
    }
}
