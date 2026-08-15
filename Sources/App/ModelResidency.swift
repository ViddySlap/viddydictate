import Foundation

/// The LM Studio CLI primitives: load (with a TTL), unload, server-start, and the loaded-set checks.
/// This is the stateless "talk to lms" layer. The lifecycle POLICY (which models the app manages — the
/// working set — and the per-model idle TTL each is loaded with) lives in `ModelManager`, which calls
/// these. Splitting it this way keeps each file single-purpose: primitives here, policy there.
///
/// Eviction is owned by LM Studio, not the app (interop ADR 0004, reversing the app-timer mechanism of
/// ViddyDictate ADR 0006): every load carries an `--ttl`, so LM Studio unloads the model on its own
/// after that many idle seconds. There is no app-side unload timer and no keep-alive. See
/// `docs/model-residency.md`.
///
/// All calls shell the LM Studio CLI synchronously and are best-effort: any failure returns
/// false/nil and the caller surfaces its own original error. Run them OFF the main thread (the
/// request clients already do their network work on background queues).
enum ModelResidency {

    /// The LM Studio CLI (same path the RAG keep-alive uses).
    private static let lmsPath = "\(NSHomeDirectory())/.lmstudio/bin/lms"
    /// Installed-model discovery, deliberately distinct from the resident-only `lms ps` command.
    static let availableModelArguments = ["ls", "--llm", "--json"]

    /// Is the LM Studio CLI on disk at all? Preflight's "is Local installed" fact, kept here so there is
    /// one owner of where the CLI lives.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: lmsPath)
    }

    /// Does LM Studio's local server answer? `lms ps` exits non-zero when it is not running, which
    /// `runLMS` deliberately ignores (its callers read stdout only), so this reads the exit status
    /// instead of the text. Bounded on its own so a wedged CLI cannot stall a preflight.
    static func serverResponds(timeout: TimeInterval = 10) -> Bool {
        guard let run = runBounded(["ps"], timeout: timeout, standardError: .discard) else {
            return false
        }
        return run.exitedNormally && run.exitCode == 0
    }

    /// All LLMs registered on disk with LM Studio, not merely the currently resident `lms ps`
    /// working set. Discovery is available only while the shared server answers: Settings then
    /// treats nil (or an empty result) as a silent request to use `ModeModelCatalog.localModels`.
    ///
    /// This method is synchronous by design, like the other CLI primitives in this type. Callers
    /// must run it off the main thread.
    static func availableModels(timeout: TimeInterval = 10) -> [LMStudioModelOption]? {
        guard serverResponds(timeout: timeout),
              let data = runLMSJSON(availableModelArguments, timeout: timeout)
        else { return nil }
        return LMStudioModelCatalog.parse(data)
    }

    /// The same installed-model discovery as the Local picker, retaining `type` and `sizeBytes` so
    /// Note to Handoff can select the smallest `vlm` without a second catalog or a hardcoded model id.
    static func availableInstalledModels(timeout: TimeInterval = 10) -> [LMStudioInstalledModel]? {
        guard serverResponds(timeout: timeout),
              let data = runLMSJSON(availableModelArguments, timeout: timeout)
        else { return nil }
        return LMStudioModelCatalog.parseInstalled(data)
    }

    /// Is `model` currently resident? (Reads `lms ps`.)
    static func isLoaded(_ model: String) -> Bool {
        (runLMS(["ps"]) ?? "").contains(model)
    }

    /// The idle TTL (seconds) LM Studio currently has on the resident `model`, or nil if the model is
    /// not resident / has no TTL. Reads `lms ps --json` (the `ttlMs` field). Used by the residency
    /// self-test to prove the per-model TTL actually reached LM Studio; production paths do not need it.
    static func loadedTTLSeconds(_ model: String) -> Int? {
        guard let out = runLMS(["ps", "--json"]),
              let data = out.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        for entry in arr where (entry["identifier"] as? String) == model {
            guard let ms = entry["ttlMs"] as? Double else { return nil }  // ttlMs is null when no TTL
            return Int(ms / 1000.0)
        }
        return nil
    }

    /// Ensure `model` is resident for an imminent inference, loaded with `ttlSeconds` of idle TTL so LM
    /// Studio evicts it on its own later. A no-op if it is already resident (loading a resident model
    /// spawns a duplicate `model:2` instance, so the ps check guards every load) — the incoming request
    /// resets LM Studio's own idle clock, so re-stamping the TTL is unnecessary. Returns true if the
    /// model is resident afterward.
    ///
    /// Note: a model that was already resident WITHOUT a TTL (e.g. loaded manually in the LM Studio GUI,
    /// or by an older build) is left as-is here rather than yanked out from under whoever loaded it; it
    /// picks up its TTL on its next cold load through this path. See `docs/model-residency.md`.
    @discardableResult
    static func ensureLoaded(_ model: String, ttlSeconds: Int) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: lmsPath) else {
            Log.write("residency: lms not found at \(lmsPath)"); return false
        }
        if isLoaded(model) { return true }
        // Cold load: make sure the server is up first (idempotent), then load WITH `--ttl` so LM Studio
        // owns the eviction (interop ADR 0004). -y so the load never blocks on a prompt.
        serverStart()
        Log.write("residency: loading \(model) (ttl \(ttlSeconds)s)")
        _ = runLMS(["load", model, "-y", "--ttl", String(ttlSeconds)])
        return isLoaded(model)
    }

    /// Ensure the LM Studio HTTP server is running (idempotent; a no-op if already up).
    static func serverStart() {
        guard FileManager.default.isExecutableFile(atPath: lmsPath) else { return }
        _ = runLMS(["server", "start"])
    }

    /// Unload `model` from LM Studio. Idempotent from the caller's view: unloading a model that is not
    /// resident just fails harmlessly (we ignore the result), so there is no need to check `lms ps`
    /// first. Production paths no longer call this (LM Studio's TTL owns eviction now); it stays as a
    /// primitive for the residency self-test's clean-slate setup and for manual use.
    static func unload(_ model: String) {
        guard FileManager.default.isExecutableFile(atPath: lmsPath) else { return }
        Log.write("residency: unloading \(model)")
        _ = runLMS(["unload", model])
    }

    /// Run the LM Studio CLI synchronously, returning combined stdout+stderr (nil on launch failure).
    /// Exit status is deliberately ignored: every caller reads the text.
    private static func runLMS(_ args: [String]) -> String? {
        // A cold model load can take a few seconds; kill anything pathological at 90s.
        guard let run = runBounded(args, timeout: 90, standardError: .merge) else { return nil }
        return String(decoding: run.output, as: UTF8.self)
    }

    /// JSON-only command runner for catalog discovery. stdout stays separate from stderr so an LM
    /// Studio diagnostic cannot corrupt otherwise-valid JSON, and non-zero exits are unavailable
    /// rather than partially parsed catalogs.
    private static func runLMSJSON(_ args: [String], timeout: TimeInterval) -> Data? {
        guard let run = runBounded(args, timeout: timeout, standardError: .discard),
              run.exitedNormally, run.exitCode == 0, !run.outputTruncated else { return nil }
        return run.output
    }

    // MARK: - the bounded runner

    /// One completed (or forcibly ended) `lms` invocation.
    struct BoundedRun: Equatable {
        let exitCode: Int32
        let output: Data
        /// The leader exited on its own before the deadline, normally (not by a signal). `exitCode` is
        /// meaningful only then.
        let exitedNormally: Bool
        /// The deadline expired with the leader still running, so the watchdog ended it.
        let timedOut: Bool
        /// The watchdog had to escalate past SIGTERM. Only reachable on the timeout path.
        let escalatedToSIGKILL: Bool
        /// Something was still in the child's process group when this returned. After a CLEAN leader
        /// exit this is EXPECTED and is deliberately left alone — see `runBounded`.
        let residualProcessGroup: Bool
        /// Output hit `outputLimit`, or the pipe never reached EOF within the grace. Callers that parse
        /// the bytes must treat this as unusable.
        let outputTruncated: Bool
    }

    /// Hard cap on captured bytes. `lms` output is a small table or a kilobytes-scale JSON catalog; a
    /// CLI that starts streaming must not be able to grow this process's memory without bound.
    private static let outputLimit = 4 << 20

    enum StandardErrorDisposition { case merge, discard }

    /// Deterministic watchdog seam, mirroring `CloudCleanupClient.runProcessForTest`: drive the exact
    /// production runner against a synthetic executable, with no LM Studio and no model.
    static func runBoundedForTest(executable: String, arguments: [String], timeout: TimeInterval,
                                  grace: TimeInterval = 0.5,
                                  standardError: StandardErrorDisposition = .merge) -> BoundedRun? {
        runBounded(arguments, timeout: timeout, grace: grace, standardError: standardError,
                   executable: executable)
    }

    /// Run `lms` under a watchdog that can actually end it.
    ///
    /// What this replaces: three `Process`-based call sites whose watchdog was a lone `proc.terminate()`
    /// — a SIGTERM to the LEADER ONLY, with no SIGKILL escalation — followed by a BLOCKING
    /// `readDataToEndOfFile()`. Two independent unbounded hangs lived in that shape. A CLI that blocks
    /// or ignores SIGTERM is never escalated on, so it runs forever; and because the read waits for the
    /// pipe's write end to close rather than for the process to die, any descendant that inherited that
    /// write end keeps the read blocked forever even after the leader is gone. Either one wedges the
    /// calling thread permanently, and `ensureLoaded` runs on the thread a user transform is waiting on.
    ///
    /// The discipline here matches `CloudCleanupClient.runProcess` and
    /// `CodexIsolationFoundation.runBoundedProcess`: spawn into the child's OWN process group so signals
    /// reach descendants, then SIGTERM the group, allow a grace, and SIGKILL the group.
    ///
    /// ONE deliberate difference from those two. They treat any process surviving the leader as a leak
    /// to be cleaned. Here it is often correct: `lms server start` exists precisely to leave a
    /// long-running server behind, and killing that group would take down the LM Studio server this app
    /// (and the vault's RAG keep-alive) depends on. So group signalling happens ONLY on the timeout
    /// path, where the leader itself failed to exit. After a clean leader exit a residual group is
    /// reported and left running, and the bounded drain — not a kill — is what guarantees return.
    private static func runBounded(_ args: [String], timeout: TimeInterval,
                                   grace: TimeInterval = 2,
                                   standardError: StandardErrorDisposition,
                                   executable: String = lmsPath) -> BoundedRun? {
        let lmsPath = executable
        guard FileManager.default.isExecutableFile(atPath: lmsPath) else {
            Log.write("residency: lms not found at \(lmsPath)")
            return nil
        }
        let pipe = Pipe()
        let parentRead = pipe.fileHandleForReading.fileDescriptor
        let childWrite = pipe.fileHandleForWriting.fileDescriptor
        let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard devNull >= 0 else { return nil }
        defer { close(devNull) }

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, childWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, standardError == .merge ? childWrite : devNull, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, parentRead) == 0 else { return nil }

        var pid: pid_t = 0
        let argv = [lmsPath] + args
        let envp = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.sorted()
        let spawnStatus = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { envPointers in
                posix_spawn(&pid, lmsPath, &actions, &attributes, argvPointers, envPointers)
            }
        }
        guard spawnStatus == 0 else {
            Log.write("residency: lms launch failed (spawn \(spawnStatus))")
            return nil
        }
        _ = setpgid(pid, pid)  // harmless if the atomic spawn attribute already won the race

        // The parent MUST drop the write end or the read below can never see EOF.
        pipe.fileHandleForWriting.closeFile()
        _ = fcntl(parentRead, F_SETFL, O_NONBLOCK)
        defer { pipe.fileHandleForReading.closeFile() }

        var output = Data()
        var truncated = false
        var sawEOF = false
        var status: Int32 = 0
        var reaped = false
        var timedOut = false
        var escalated = false

        // Non-blocking drain, called from this one thread only. Draining every tick is also what keeps
        // the child from ever blocking on a full pipe, which is the deadlock the old `nullDevice`
        // workaround was avoiding by throwing the output away.
        var buffer = [UInt8](repeating: 0, count: 65_536)
        func drain() {
            while true {
                let n = buffer.withUnsafeMutableBytes { read(parentRead, $0.baseAddress, $0.count) }
                if n > 0 {
                    let room = outputLimit - output.count
                    if room > 0 { output.append(contentsOf: buffer[0..<min(n, room)]) }
                    if n > room { truncated = true }
                    continue
                }
                if n == 0 { sawEOF = true; return }
                if errno == EINTR { continue }
                return  // EAGAIN: nothing available this tick
            }
        }
        func reapIfExited() {
            guard !reaped else { return }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true }
        }

        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        while Date() < deadline {
            drain()
            reapIfExited()
            // Break on the LEADER, not on EOF. Waiting for EOF here is precisely the old bug: a
            // descendant holding the inherited write end would hold this loop for the full timeout
            // (or, in the old blocking read, forever) even though the process we launched was done.
            if reaped { break }
            usleep(20_000)
        }

        if reaped {
            // Clean exit. Anything still holding the write end is a process we deliberately do not
            // signal (see the note above), so bound the remaining drain instead of waiting for EOF.
            let graceDeadline = Date().addingTimeInterval(max(0, grace))
            while !sawEOF && Date() < graceDeadline {
                drain()
                if sawEOF { break }
                usleep(20_000)
            }
            if !sawEOF { truncated = true }
        } else {
            timedOut = true
            _ = kill(-pid, SIGTERM)
            let termDeadline = Date().addingTimeInterval(max(0, grace) / 2)
            while Date() < termDeadline {
                drain()
                reapIfExited()
                if reaped && processGroupIsEmpty(pid) { break }
                usleep(20_000)
            }
            if !processGroupIsEmpty(pid) {
                escalated = true
                _ = kill(-pid, SIGKILL)
            }
            // SIGKILL is uncatchable, so this converges; the bound only guards a pathological
            // unkillable (uninterruptible-sleep) child, which we must not block the app on either.
            let killDeadline = Date().addingTimeInterval(max(0, grace))
            while Date() < killDeadline {
                drain()
                reapIfExited()
                if reaped && sawEOF { break }
                usleep(20_000)
            }
            if !sawEOF { truncated = true }
            Log.write("residency: lms watchdog ended '\(args.first ?? "?")' after \(Int(timeout))s "
                + "(sigkill=\(escalated), reaped=\(reaped))")
        }

        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return BoundedRun(
            exitCode: Int32(exitCode),
            output: output,
            exitedNormally: reaped && !timedOut && signal == 0,
            timedOut: timedOut,
            escalatedToSIGKILL: escalated,
            residualProcessGroup: !processGroupIsEmpty(pid),
            outputTruncated: truncated)
    }

    private static func processGroupIsEmpty(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(-pid, 0) != 0 && errno == ESRCH
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
