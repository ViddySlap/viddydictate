import Darwin
import Foundation

/// Streaming stdio adapter for the catalog-only app-server session. It owns a fresh process group,
/// never retains stderr content, and exposes only bounded JSONL lines plus content-free exit evidence.
final class CodexCatalogPOSIXSession: CodexCatalogProcessSession {
    private let pid: pid_t
    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let stdoutLineLimit: Int
    private let stdoutTotalLimit: Int
    private let stderrLimit: Int
    private let drainCompletionDelayForTesting: TimeInterval
    private let processOperationRecorder:
        ((CodexCatalogProcessOperation) -> Void)?
    private let processSignal:
        (pid_t, Int32) -> Int32
    private let absoluteDeadline: TimeInterval
    private let monotonicNow: () -> TimeInterval

    private let writeLock = NSLock()
    private var inputClosed = false

    private let outputCondition = NSCondition()
    private var outputLines: [Data] = []
    private var outputEOF = false
    private var outputOverflow = false
    private var outputFailure = false
    private var outputPendingBytes = 0
    private var capturedStdoutBytes = 0

    private let stderrLock = NSLock()
    private var capturedStderrBytes = 0
    private var stderrOverflow = false
    private var stderrEOF = false

    private let drains = DispatchGroup()
    private let reapLock = NSLock()
    private enum ReapState {
        case running(termSent: Bool, killSent: Bool)
        case treeGone(waitStatus: Int32, timedOut: Bool)
        case complete(CodexCatalogProcessExit)
    }
    private var reapState: ReapState =
        .running(termSent: false, killSent: false)
    private var leaderReaped = false
    private var waitStatus: Int32 = 0
    private var observedTimeout = false

    private init(
        pid: pid_t,
        input: FileHandle,
        output: FileHandle,
        error: FileHandle,
        stdoutLineLimit: Int,
        stdoutTotalLimit: Int,
        stderrLimit: Int,
        drainCompletionDelayForTesting: TimeInterval,
        processOperationRecorder:
            ((CodexCatalogProcessOperation) -> Void)?,
        processSignal:
            @escaping (pid_t, Int32) -> Int32,
        absoluteDeadline: TimeInterval,
        monotonicNow: @escaping () -> TimeInterval
    ) {
        self.pid = pid
        self.input = input
        self.output = output
        self.error = error
        self.stdoutLineLimit = stdoutLineLimit
        self.stdoutTotalLimit = stdoutTotalLimit
        self.stderrLimit = stderrLimit
        self.drainCompletionDelayForTesting =
            drainCompletionDelayForTesting
        self.processOperationRecorder = processOperationRecorder
        self.processSignal = processSignal
        self.absoluteDeadline = absoluteDeadline
        self.monotonicNow = monotonicNow
        startDrains()
    }

    static func start(_ launch: CodexCatalogProcessLaunch) throws
        -> CodexCatalogProcessSession {
        guard launch.executable.hasPrefix("/"),
              launch.arguments == ["app-server"],
              launch.currentDirectory.path.hasPrefix("/"),
              launch.stdoutLineLimit > 0,
              launch.stdoutTotalLimit >= launch.stdoutLineLimit,
              launch.stderrLimit > 0,
              launch.monotonicNow() < launch.operationDeadline,
              try CodexIsolationFoundation.strongFileIdentity(
                at: URL(fileURLWithPath: launch.executable),
                includeCodeSigning:
                    launch.expectedExecutableIdentity.codeSigning != nil)
                == launch.expectedExecutableIdentity else {
            throw CodexCatalogFailure(.processLaunch)
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let childStdin = stdinPipe.fileHandleForReading.fileDescriptor
        let parentStdin = stdinPipe.fileHandleForWriting.fileDescriptor
        let parentStdout = stdoutPipe.fileHandleForReading.fileDescriptor
        let childStdout = stdoutPipe.fileHandleForWriting.fileDescriptor
        let parentStderr = stderrPipe.fileHandleForReading.fileDescriptor
        let childStderr = stderrPipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(parentStdin, F_SETNOSIGPIPE, 1)

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0,
              posix_spawn_file_actions_init(&actions) == 0 else {
            throw CodexCatalogFailure(.processLaunch)
        }
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        guard posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, childStdin, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, childStdout, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(
                &actions, childStderr, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, parentStdin) == 0,
              posix_spawn_file_actions_addclose(&actions, parentStdout) == 0,
              posix_spawn_file_actions_addclose(&actions, parentStderr) == 0,
              posix_spawn_file_actions_addchdir_np(
                &actions, launch.currentDirectory.path) == 0 else {
            throw CodexCatalogFailure(.processLaunch)
        }

        let argv = [launch.executable] + launch.arguments
        let envp = launch.environment.map { "\($0.key)=\($0.value)" }.sorted()
        guard launch.monotonicNow() < launch.operationDeadline else {
            throw CodexCatalogFailure(.processLaunch)
        }
        var pid: pid_t = 0
        let spawnStatus = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { environmentPointers in
                posix_spawn(
                    &pid, launch.executable, &actions, &attributes,
                    argvPointers, environmentPointers)
            }
        }
        guard spawnStatus == 0 else {
            throw CodexCatalogFailure(.processLaunch)
        }
        launch.spawnedPIDRecorder?(pid)
        _ = setpgid(pid, pid)

        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let session = CodexCatalogPOSIXSession(
            pid: pid,
            input: stdinPipe.fileHandleForWriting,
            output: stdoutPipe.fileHandleForReading,
            error: stderrPipe.fileHandleForReading,
            stdoutLineLimit: launch.stdoutLineLimit,
            stdoutTotalLimit: launch.stdoutTotalLimit,
            stderrLimit: launch.stderrLimit,
            drainCompletionDelayForTesting:
                launch.drainCompletionDelayForTesting,
            processOperationRecorder: launch.processOperationRecorder,
            processSignal: launch.processSignal,
            absoluteDeadline: launch.absoluteDeadline,
            monotonicNow: launch.monotonicNow)

        launch.postSpawnBeforeIdentityValidation?()
        let launchIdentityMatches: Bool
        do {
            launchIdentityMatches =
                try CodexIsolationFoundation.strongFileIdentity(
                at: URL(fileURLWithPath: launch.executable),
                includeCodeSigning:
                    launch.expectedExecutableIdentity.codeSigning != nil)
                    == launch.expectedExecutableIdentity
        } catch {
            launchIdentityMatches = false
        }
        guard launchIdentityMatches else {
            session.closeInput()
            let cleanupDeadline = min(
                launch.absoluteDeadline,
                launch.monotonicNow()
                    + min(2, launch.immediateCleanupSeconds))
            launch.launchCleanupDeadlineRecorder?(
                cleanupDeadline)
            let cleanup = session.reap(
                forceTerminate: true,
                absoluteDeadline: cleanupDeadline)
            launch.launchCleanupEvidenceRecorder?(cleanup)
            guard cleanup.leaderReaped,
                  !cleanup.residualProcessGroup,
                  cleanup.drainsComplete,
                  cleanup.stdoutEOF,
                  cleanup.stderrEOF else {
                throw CodexCatalogFailure(.processLaunch)
            }
            throw CodexCatalogFailure(.processLaunch)
        }

        return session
    }

    func writeLine(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !inputClosed else { throw CodexCatalogFailure(.processFailure) }
        var framed = data
        framed.append(0x0A)
        try framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    input.fileDescriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CodexCatalogFailure(.processFailure)
                }
                offset += count
            }
        }
    }

    func readLine(
        absoluteDeadline: TimeInterval
    ) -> CodexCatalogReadResult {
        while true {
            guard monotonicNow() < absoluteDeadline else {
                return .timeout
            }
            outputCondition.lock()
            if !outputLines.isEmpty {
                let line = outputLines.removeFirst()
                outputCondition.unlock()
                guard monotonicNow() < absoluteDeadline else {
                    return .timeout
                }
                return .line(line)
            }
            if outputOverflow {
                outputCondition.unlock()
                return .overflow
            }
            if outputFailure {
                outputCondition.unlock()
                return .failure
            }
            if outputEOF {
                outputCondition.unlock()
                guard monotonicNow() < absoluteDeadline else {
                    return .timeout
                }
                return .eof
            }
            outputCondition.unlock()
            let remaining = absoluteDeadline - monotonicNow()
            guard remaining > 0 else { return .timeout }
            usleep(useconds_t(min(0.005, remaining) * 1_000_000))
        }
    }

    func closeInput() {
        writeLock.lock()
        if !inputClosed {
            inputClosed = true
            input.closeFile()
        }
        writeLock.unlock()
    }

    func finishAndReap(
        absoluteDeadline: TimeInterval
    ) -> CodexCatalogProcessExit {
        closeInput()
        return reap(
            forceTerminate: false,
            absoluteDeadline: absoluteDeadline)
    }

    func terminateAndReap(
        absoluteDeadline: TimeInterval
    ) -> CodexCatalogProcessExit {
        closeInput()
        return reap(
            forceTerminate: true,
            absoluteDeadline: absoluteDeadline)
    }

    private func startDrains() {
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { drains.leave() }
            var pending = Data()
            var total = 0
            while true {
                // MUST be `availableData`, never `readData(ofLength:)`. Despite reading as "up to N
                // bytes", `readData(ofLength:)` blocks until it has accumulated the FULL requested
                // length or the pipe reaches EOF. app-server is a long-lived child that answers
                // `initialize` in ~30ms with roughly 455 bytes and then waits, so a 64 KiB request
                // never completes: the drain held a valid response for the entire deadline and
                // surrendered it only when the child was killed and the pipe hit EOF. Every catalog
                // refresh therefore timed out, while the fixture transport - which never touches this
                // drain - stayed green. `availableData` returns as soon as any bytes exist.
                let chunk = output.availableData
                if chunk.isEmpty { break }
                total += chunk.count
                if total > stdoutTotalLimit {
                    outputCondition.lock()
                    outputOverflow = true
                    outputCondition.broadcast()
                    outputCondition.unlock()
                    continue
                }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    var line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if line.last == 0x0D { line.removeLast() }
                    outputCondition.lock()
                    if line.count > stdoutLineLimit {
                        outputOverflow = true
                    } else {
                        outputLines.append(line)
                    }
                    outputCondition.broadcast()
                    outputCondition.unlock()
                }
                if pending.count > stdoutLineLimit {
                    outputCondition.lock()
                    outputOverflow = true
                    outputCondition.broadcast()
                    outputCondition.unlock()
                }
            }
            if drainCompletionDelayForTesting > 0 {
                usleep(useconds_t(
                    min(drainCompletionDelayForTesting, 2) * 1_000_000))
            }
            outputCondition.lock()
            capturedStdoutBytes = total
            outputPendingBytes = pending.count
            if !pending.isEmpty { outputFailure = true }
            outputEOF = true
            outputCondition.broadcast()
            outputCondition.unlock()
        }

        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { drains.leave() }
            var total = 0
            var overflow = false
            while true {
                // Same reason as the stdout drain above: this child outlives its output, so a
                // fill-the-buffer read would park until the child dies and stall drain completion.
                let chunk = error.availableData
                if chunk.isEmpty { break }
                if total <= stderrLimit {
                    let available = max(0, stderrLimit - total)
                    total += min(available, chunk.count)
                    if chunk.count > available { overflow = true }
                } else {
                    overflow = true
                }
            }
            stderrLock.lock()
            capturedStderrBytes = total
            stderrOverflow = overflow
            stderrEOF = true
            stderrLock.unlock()
        }
    }

    private func reap(
        forceTerminate: Bool,
        absoluteDeadline requestedDeadline: TimeInterval
    ) -> CodexCatalogProcessExit {
        let callDeadline = min(
            requestedDeadline,
            absoluteDeadline)
        reapLock.lock()
        defer { reapLock.unlock() }
        if case .complete(let exit) = reapState { return exit }

        if case .running(
            let latchedTerm,
            let latchedKill
        ) = reapState {
            var termSent = latchedTerm
            var killSent = latchedKill
            let started = monotonicNow()
            let available = max(0, callDeadline - started)
            let naturalDeadline = started
                + (forceTerminate ? 0 : available * 0.2)
            let termDeadline = started + available * 0.55

            func persistEscalationLatch() {
                if case .running = reapState {
                    reapState = .running(
                        termSent: termSent,
                        killSent: killSent)
                }
            }

            func updateLeader() {
                guard !leaderReaped else { return }
                processOperationRecorder?(.wait)
                let waited = waitpid(pid, &waitStatus, WNOHANG)
                if waited == pid { leaderReaped = true }
            }
            func updateTreeGone() -> Bool {
                if case .treeGone = reapState { return true }
                updateLeader()
                guard leaderReaped else { return false }
                if processGroupIsEmpty(pid) {
                    reapState = .treeGone(
                        waitStatus: waitStatus,
                        timedOut: observedTimeout)
                    return true
                }
                return false
            }
            func waitUntil(_ deadline: TimeInterval) -> Bool {
                while monotonicNow() < min(deadline, callDeadline) {
                    if updateTreeGone() { return true }
                    usleep(5_000)
                }
                return updateTreeGone()
            }

            if !killSent {
                if !forceTerminate, !termSent,
                   waitUntil(naturalDeadline) {
                    // The app-server exited cleanly after stdin closed.
                } else if !updateTreeGone(),
                          monotonicNow() < callDeadline {
                    if !termSent {
                        if !forceTerminate {
                            observedTimeout = true
                        }
                        processOperationRecorder?(.termSignal)
                        _ = processSignal(-pid, SIGTERM)
                        termSent = true
                        persistEscalationLatch()
                    }
                    if !waitUntil(termDeadline),
                       monotonicNow() < callDeadline {
                        processOperationRecorder?(.killSignal)
                        _ = processSignal(-pid, SIGKILL)
                        killSent = true
                        persistEscalationLatch()
                        _ = waitUntil(callDeadline)
                    }
                }
            }
        }

        let treeGone: Bool
        let terminalStatus: Int32
        let terminalTimedOut: Bool
        switch reapState {
        case .treeGone(let status, let timedOut):
            treeGone = true
            terminalStatus = status
            terminalTimedOut = timedOut
        case .running:
            treeGone = false
            terminalStatus = waitStatus
            terminalTimedOut = observedTimeout
        case .complete(let exit):
            return exit
        }

        let drainRemaining = max(
            0, callDeadline - monotonicNow())
        let drainWaitCompleted = treeGone
            && drains.wait(
                timeout: .now() + drainRemaining) == .success
        stderrLock.lock()
        let stderrBytes = capturedStderrBytes
        let overflow = stderrOverflow
        let observedStderrEOF = stderrEOF
        stderrLock.unlock()
        outputCondition.lock()
        let stdoutOverflow = outputOverflow
        let stdoutBytes = capturedStdoutBytes
        let stdoutPendingBytes = outputPendingBytes
        let observedStdoutEOF = outputEOF
        let stdoutFailure = outputFailure || !observedStdoutEOF
        outputCondition.unlock()
        let drainsComplete =
            drainWaitCompleted
            && observedStdoutEOF
            && observedStderrEOF

        let signal = terminalStatus & 0x7f
        let exitCode =
            signal == 0
                ? (terminalStatus >> 8) & 0xff
                : 128 + signal
        let result = CodexCatalogProcessExit(
            exitCode: exitCode,
            timedOut: terminalTimedOut,
            terminatedBySignal: signal != 0,
            leaderReaped: treeGone,
            residualProcessGroup: !treeGone,
            stderrBytes: stderrBytes,
            stderrOverflow: overflow,
            stdoutBytes: stdoutBytes,
            stdoutOverflow: stdoutOverflow,
            stdoutPendingBytes: stdoutPendingBytes,
            stdoutFailure: stdoutFailure,
            drainsComplete: drainsComplete,
            stdoutEOF: observedStdoutEOF,
            stderrEOF: observedStderrEOF)
        if treeGone, drainsComplete {
            reapState = .complete(result)
        }
        return result
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
        return pointers.withUnsafeMutableBufferPointer {
            body($0.baseAddress!)
        }
    }

    private func processGroupIsEmpty(_ processID: pid_t) -> Bool {
        processOperationRecorder?(.groupProbe)
        errno = 0
        return kill(-processID, 0) != 0 && errno == ESRCH
    }
}
