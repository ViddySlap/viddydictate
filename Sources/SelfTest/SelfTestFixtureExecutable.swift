import Darwin
import Foundation

/// Writes an executable shell fixture and pays macOS's one-time first-execution security
/// assessment BEFORE the caller opens its measured window.
///
/// WHY THIS TYPE EXISTS. On macOS the first execution of a newly written executable costs a
/// one-time security assessment. Measured on Ben's MacBook 2026-08-19 over 32 fresh execs at
/// load 4.1: 94-633 ms to first output for a fresh file at a fresh path (median 100 ms),
/// against 2.4-5.3 ms for every later exec of the SAME file. That is roughly a 30x cliff, paid
/// once per file. A self-test that writes a fixture to a fresh UUID path and then launches it
/// inside a sub-second budget therefore measures the assessment and not the code under test:
/// `--codex-model-catalog-selftest` was 8/8 red with `elapsed_ms=553-670` against a 500 ms
/// bound, and `--text-transform-selftest` was the "load-sensitive flake" for the same reason
/// against a 200 ms one. Full diagnosis:
/// `Projects/viddydictate/wiki/reference/selftest-fixture-gatekeeper-trap.md`.
///
/// THE ASSESSMENT CACHE IS KEYED BY FILE, NOT BY CONTENT. Byte-identical bytes at a second
/// fresh path pay the full cost again (measured 4/4, ~100 ms each). So the only warm-up that
/// works is executing the very file the test is about to launch, which is what `install` does.
///
/// THE WARM-UP MUST BE SIDE-EFFECT FREE, because these fixtures write PID files, fork
/// descendants, and spin forever. `install` therefore injects one guard line straight after the
/// shebang that exits 0 when argv[1] is `warmupArgument`. No production launch passes that
/// sentinel, so every real invocation runs the script exactly as its author wrote it.
///
/// NO BUDGET IS RAISED ANYWHERE, and none may be. These tests assert that deadlines are
/// *bounded*; widening a 200 ms bound to cover a 783 ms assessment would be 5-20x the intended
/// limit and would stop testing boundedness at all. Warming removes an environmental variable
/// that was never part of the subject. Fixing this by moving a number is the wrong fix.
///
/// ONE OWNER, NOT ONE FIX PER SITE. Every executable fixture in `CodexModelCatalogSelfTest` and
/// `TextTransformSelfTest` is materialised through `install`, and
/// `--codex-model-catalog-selftest` carries a source rule that fails if either file starts
/// writing and chmod-ing its own fixtures again.
enum SelfTestFixtureExecutable {
    /// Passed as argv[1] by `warm(_:)` and by nothing else. The injected guard matches on this
    /// exact string, so a fixture only ever short-circuits for a warm-up.
    static let warmupArgument = "--viddydictate-fixture-warmup"

    /// A warm-up that does not complete cleanly is a REAL failure and is surfaced as one. It is
    /// never swallowed: a helper that silently no-ops on error would recreate exactly the class
    /// of invisible problem this type exists to remove.
    struct Failure: Error, CustomStringConvertible {
        let reason: String
        var description: String { "selftest fixture executable: \(reason)" }
    }

    /// Write `script` to `url`, make it executable at `mode`, and execute it once with the
    /// warm-up sentinel so macOS charges its assessment here rather than inside the caller's
    /// timed window.
    ///
    /// Throws on any failure - a missing shebang, a failed chmod, a warm-up that cannot spawn,
    /// exits non-zero, is signalled, or does not return within `warmupTimeout`.
    static func install(
        script: String,
        at url: URL,
        mode: mode_t = 0o500,
        warmupTimeout: TimeInterval = 10
    ) throws {
        let guarded = try warmupGuarded(script, at: url)
        do {
            try Data(guarded.utf8).write(to: url)
        } catch {
            throw fault(
                "could not write \(url.lastPathComponent): \(error)")
        }
        guard chmod(url.path, mode) == 0 else {
            throw fault(
                "chmod 0\(String(mode, radix: 8)) failed on "
                    + "\(url.lastPathComponent): errno \(errno)")
        }
        try warm(url, timeout: warmupTimeout)
    }

    /// Insert the warm-up guard immediately after the shebang, so it runs before the fixture's
    /// first side effect - the PID-file write, the backgrounded descendant, the infinite loop.
    private static func warmupGuarded(
        _ script: String, at url: URL
    ) throws -> String {
        guard script.hasPrefix("#!"),
              let shebangEnd = script.firstIndex(of: "\n") else {
            throw fault(
                "\(url.lastPathComponent) has no shebang line, so the warm-up guard "
                    + "cannot be placed ahead of the fixture's first statement")
        }
        let shebang = String(script[script.startIndex..<shebangEnd])
        let body = String(script[script.index(after: shebangEnd)...])
        return shebang + "\n"
            + "[ \"$1\" = \"\(warmupArgument)\" ] && exit 0\n"
            + body
    }

    /// Execute the fixture once, in its own process group, with stdio on /dev/null, and require
    /// a clean exit inside `timeout`. The guard makes this a no-op for the fixture; the point is
    /// purely that the kernel and syspolicyd assess the file now.
    private static func warm(_ url: URL, timeout: TimeInterval) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawn_file_actions_init(&actions) == 0 else {
            throw fault("warm-up spawn initialization failed")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        // Own process group so a fixture that ignores the guard can be torn down whole rather
        // than leaving a descendant behind - the very leak these self-tests exist to catch.
        guard posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(
                &actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(
                &actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw fault("warm-up spawn configuration failed")
        }

        var pid: pid_t = 0
        let spawnStatus = withCStringArray([url.path, warmupArgument]) { argv in
            withCStringArray(["PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C"]) { envp in
                posix_spawn(&pid, url.path, &actions, &attributes, argv, envp)
            }
        }
        guard spawnStatus == 0 else {
            throw fault(
                "warm-up could not launch \(url.lastPathComponent): "
                    + "posix_spawn status \(spawnStatus)")
        }
        _ = setpgid(pid, pid)

        // Every path out of here tears the group down first. A helper that leaked a process on
        // its own error path would be leaving behind exactly what these self-tests exist to
        // catch, and it would do it while nobody was looking.
        func killGroup() {
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            var discarded: Int32 = 0
            _ = waitpid(pid, &discarded, 0)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var waitStatus: Int32 = 0
        var reaped = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result == pid {
                reaped = true
                break
            }
            if result < 0 && errno != EINTR {
                let failed = errno
                killGroup()
                throw fault(
                    "warm-up could not reap \(url.lastPathComponent): errno \(failed)")
            }
            usleep(2_000)
        }
        guard reaped else {
            killGroup()
            throw fault(
                "warm-up of \(url.lastPathComponent) did not exit within "
                    + "\(timeout)s; the guard line did not take effect")
        }
        // WIFEXITED / WEXITSTATUS, which Swift does not import.
        let exitedNormally = (waitStatus & 0x7f) == 0
        let exitCode = (waitStatus >> 8) & 0xff
        guard exitedNormally, exitCode == 0 else {
            throw fault(
                "warm-up of \(url.lastPathComponent) ended badly: "
                    + (exitedNormally
                        ? "exit \(exitCode)"
                        : "signal \(waitStatus & 0x7f)"))
        }
    }

    /// Print before throwing. A fixture failure that lands in a caller's `catch` prints no
    /// `[diag]` line of its own, and that silence is precisely what made the original bug read
    /// as an assertion failure for a month. See the wiki page named above.
    private static func fault(_ reason: String) -> Failure {
        print("  [diag] fixture warm-up FAILED: \(reason)")
        return Failure(reason: reason)
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
