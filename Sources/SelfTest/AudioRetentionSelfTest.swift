import Darwin
import Foundation

/// Scratch-only proof for the local 100-take WAV ring. No mic, daemon, preferences, or real history.
enum AudioRetentionSelfTest {
    private static let deadlockReproFlag = AudioRetentionDeadlockFlag.repro.rawValue
    private static let deadlockChildFlag = AudioRetentionDeadlockFlag.child.rawValue
    private static let deadlockScratchRootFlag = AudioRetentionDeadlockFlag.scratchRoot.rawValue
    private static let deadlockTimeout: TimeInterval = 3

    /// Opt-in red-first regression mode for the retained-take AB-BA deadlock. The ordinary
    /// `--history-selftest` remains the green deterministic gate while vdd-L1 proves the unfixed
    /// production code red; vdd-L2 and the review link invoke this mode again after the fix.
    static func deadlockReproExit(arguments: [String]) -> Int32? {
        if arguments.contains(deadlockChildFlag) {
            guard let index = arguments.firstIndex(of: deadlockScratchRootFlag),
                  index + 1 < arguments.count else {
                print("[audio-retention-deadlock-child] FAIL: scratch root is required")
                return 2
            }
            let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            return runDeadlockChild(root: root) ? 0 : 1
        }
        guard arguments.contains(deadlockReproFlag) else { return nil }
        return runDeadlockRepro() ? 0 : 1
    }

    static func run() -> Bool {
        print("--- retained dictation audio: off switch, UUID join, cap, and purge ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-audio-retention-selftest-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let offDir = root.appendingPathComponent("off", isDirectory: true)
        let off = AudioRetentionStore(directory: offDir, enabled: { false })
        off.retain(Data("RIFF-off".utf8), id: UUID())
        off.flush()
        reporter.record("off switch has zero filesystem side effects",
                        !fm.fileExists(atPath: offDir.path))

        let onDir = root.appendingPathComponent("on", isDirectory: true)
        let on = AudioRetentionStore(directory: onDir, enabled: { true })
        var ids: [UUID] = []
        for index in 0...AudioRetentionStore.maxTakes {
            let id = UUID()
            ids.append(id)
            on.retain(Data("RIFF-\(index)".utf8), id: id,
                      at: Date(timeIntervalSince1970: TimeInterval(index + 1)))
        }
        on.flush()

        let retained = Set(on.retainedIDs())
        reporter.record("ring keeps exactly the 100 newest take UUIDs",
                        retained.count == AudioRetentionStore.maxTakes)
        reporter.record("oldest take is evicted and the next-oldest remains",
                        !retained.contains(ids[0]) && retained.contains(ids[1]))
        let newestURL = on.recordingURL(for: ids.last!)
        reporter.record("WAV filename is the take UUID used by History",
                        newestURL?.lastPathComponent == "\(ids.last!.uuidString).wav")
        reporter.record("retained bytes are the exact supplied post-trim payload",
                        newestURL.flatMap { try? Data(contentsOf: $0) } == Data("RIFF-100".utf8))

        // The enabled decision is captured at take finalization. A setting flip while the async retain is
        // queued must not erase a take that was enabled at release.
        let capturedDir = root.appendingPathComponent("captured-enabled", isDirectory: true)
        let captured = AudioRetentionStore(directory: capturedDir, enabled: { false })
        let capturedID = UUID()
        let capturedBytes = Data("RIFF-captured".utf8)
        captured.retain(capturedBytes, id: capturedID, enabled: true)
        captured.flush()
        // Wait on the completion, not on the store queue. This assertion was written against the
        // PRE-FIX contract, where `loadRecording` invoked its completion with the queue held and so
        // `flush()` implied delivery. Fix A (a133621) correctly broke that: the completion now hops to
        // a global queue, `flush()` drains the store queue only, and reading the result straight after
        // it passed only when the global queue happened to win the race. The wait is bounded so a
        // completion that never arrives fails this check rather than hanging the suite.
        let capturedDelivered = DispatchSemaphore(value: 0)
        var loadedCaptured: Data?
        captured.loadRecording(id: capturedID) { loadedCaptured = $0; capturedDelivered.signal() }
        let capturedArrived = capturedDelivered.wait(timeout: .now() + 5) == .success
        reporter.record("take-release retention decision survives a later setting change",
                        capturedArrived && loadedCaptured == capturedBytes,
                        capturedArrived ? "" : "completion never arrived within 5s")

        on.purge()
        on.flush()
        reporter.record("purge removes retained audio but leaves no replacement directory",
                        !fm.fileExists(atPath: onDir.path) && on.retainedIDs().isEmpty)

        let defPath = AudioRetentionStore.defaultDirectory().path
        reporter.record("production recordings directory is app-local beside history",
                        defPath.hasSuffix("/Library/Application Support/ViddyDictate/recordings")
                            && !defPath.contains("ViddyVault")
                            && !defPath.lowercased().contains("obsidian"),
                        defPath)

        let controller = (try? String(contentsOfFile: "Sources/App/DictationController.swift",
                                      encoding: .utf8)) ?? ""
        let sharedSnapshot = slice(controller,
                                   from: "private func transcribeAudioSnapshot(",
                                   to: "/// Finalize an in-flight take")
        let partial = slice(controller, from: "private func tickPartial() {",
                            to: "private func finishNothingHeard(")
        let finish = slice(controller, from: "private func finish() {",
                           to: "private func deliver(text rawText:")
        let oneShotFinal = slice(controller, from: "func finalizeTakeAndTranscribe(",
                                 to: "// MARK: hotkey")
        let retainIndex = sharedSnapshot.range(of: "AudioRetentionStore.shared.retain")?.lowerBound
        let postIndex = sharedSnapshot.range(of: "DaemonClient.transcribe")?.lowerBound
        reporter.record("retention enqueue is before the transcribe POST on a separate store queue",
                        retainIndex != nil && postIndex != nil && retainIndex! < postIndex!)
        reporter.record("partial-preview snapshot never supplies a persistence UUID",
                        partial.contains("transcribeAudioSnapshot {")
                            && !partial.contains("retainingAs:"))
        reporter.record("both real finalization paths mint and retain one take UUID",
                        [finish, oneShotFinal].allSatisfy {
                            $0.contains("UUID()")
                                && $0.contains("transcribeAudioSnapshot(retainingAs: takeID")
                        })

        let deadlockReference = "Projects/viddydictate/wiki/reference/retained-take-deadlock.md"
        let retentionStore = (try? String(contentsOfFile: "Sources/App/AudioRetentionStore.swift",
                                           encoding: .utf8)) ?? ""
        let retainMethod = slice(retentionStore, from: "func retain(",
                                 to: "/// Read a retained take back")
        let loadMethod = slice(retentionStore, from: "func loadRecording(",
                               to: "/// Return the retained file")
        let enabledCall = retainMethod.range(of: "isEnabled()")?.lowerBound
        let retainEnqueue = retainMethod.range(of: "queue.async")?.lowerBound
        let completionHop = loadMethod.range(
            of: "DispatchQueue.global(qos: .utility).async")?.lowerBound
        let completionCall = loadMethod.range(of: "completion(data)")?.lowerBound
        let escapingClosureInventoryIsKnown =
            retentionStore.components(separatedBy: "@escaping").count - 1 == 2
                && retentionStore.contains("enabled: @escaping () -> Bool")
                && retentionStore.contains("completion: @escaping (Data?) -> Void")
        let knownClosureCallsAreUnique =
            retentionStore.components(separatedBy: "isEnabled()").count - 1 == 1
                && retentionStore.components(separatedBy: "completion(data)").count - 1 == 1
        let enabledCallPrecedesQueue: Bool
        if let enabledCall, let retainEnqueue {
            enabledCallPrecedesQueue = enabledCall < retainEnqueue
        } else {
            enabledCallPrecedesQueue = false
        }
        let completionCallFollowsHop: Bool
        if let completionHop, let completionCall {
            completionCallFollowsHop = completionHop < completionCall
        } else {
            completionCallFollowsHop = false
        }
        let escapingClosureRuleHolds = !retentionStore.isEmpty
            && escapingClosureInventoryIsKnown
            && knownClosureCallsAreUnique
            && enabledCallPrecedesQueue
            && completionCallFollowsHop
        reporter.record(
            "AudioRetentionStore queue blocks never invoke caller-supplied escaping closures",
            escapingClosureRuleHolds,
            escapingClosureRuleHolds ? "" :
                "BROKEN RULE: never invoke caller-supplied escaping closures inside queue.async/queue.sync; "
                    + "unknown code can wait on main while main waits on the store queue, recreating the "
                    + "2026-08-18 AB-BA deadlock. See \(deadlockReference)"
        )

        let retryRetainedTake = slice(controller, from: "func retryRetainedTake(",
                                      to: "/// Pure request builder")
        let stillCurrent = slice(retryRetainedTake, from: "let stillCurrent: () -> Bool",
                                 to: "retainedTakeRecovery.recover(")
        let stillCurrentRuleHolds = !stillCurrent.isEmpty
            && !stillCurrent.contains("DispatchQueue.main.sync")
        reporter.record(
            "DictationController stillCurrent contains no DispatchQueue.main.sync",
            stillCurrentRuleHolds,
            stillCurrentRuleHolds ? "" :
                "BROKEN RULE: stillCurrent must never synchronously hop to main; doing so can wait on main "
                    + "while main waits on AudioRetentionStore, recreating the 2026-08-18 AB-BA deadlock. "
                    + "See \(deadlockReference)"
        )

        var loadCalls = 0
        var ensureCalls = 0
        var transcribeCalls = 0
        var scheduleCalls = 0
        var observedPayload: Data?
        var recoveryResult: RetainedTakeRecoveryResult?
        var recoveryProgress: [Bool] = []
        let recovery = RetainedTakeRecovery(
            load: { _, done in loadCalls += 1; done(capturedBytes) },
            ensureReady: { done in ensureCalls += 1; done(true) },
            transcribe: { wav, _, done in
                transcribeCalls += 1
                observedPayload = wav
                if transcribeCalls == 1 { done(nil, "model loading") }
                else { done("recovered words", nil) }
            },
            schedule: { work in scheduleCalls += 1; work() },
            progress: { _, pending in recoveryProgress.append(pending) }
        )
        recovery.recover(takeID: capturedID, retentionWasEnabled: true,
                         stillCurrent: { true }) { recoveryResult = $0 }
        reporter.record("model-loading response retries the exact retained bytes after readiness",
                        recoveryResult == .recovered("recovered words")
                            && observedPayload == capturedBytes
                            && loadCalls == 1 && ensureCalls == 2
                            && transcribeCalls == 2 && scheduleCalls == 1
                            && recoveryProgress == [true, false])

        var disabledLoaded = false
        var disabledResult: RetainedTakeRecoveryResult?
        var disabledProgress: [Bool] = []
        let disabledRecovery = RetainedTakeRecovery(
            load: { _, _ in disabledLoaded = true },
            ensureReady: { _ in }, transcribe: { _, _, _ in }, schedule: { _ in },
            progress: { _, pending in disabledProgress.append(pending) }
        )
        disabledRecovery.recover(takeID: UUID(), retentionWasEnabled: false,
                                 stillCurrent: { true }) { disabledResult = $0 }
        reporter.record("retention-off recovery is honest and never reads or transcribes",
                        disabledResult == .unavailable("audio retention was off") && !disabledLoaded
                            && disabledProgress == [true, false])

        reporter.record("production recovery progress is wired to the shared HUD ring",
                        controller.contains("RetainedTakeRecovery(progress:")
                            && controller.contains("hud.setRecoveryPending(takeID: takeID, pending: pending)"))

        let targetResolver = (try? String(contentsOfFile: "Sources/App/TargetResolver.swift",
                                           encoding: .utf8)) ?? ""
        reporter.record("late foreign landing posts to the captured pid without activating its app",
                        targetResolver.contains("pasteIntoCapturedTargetWithoutActivation")
                            && targetResolver.contains("down.postToPid(pid)")
                            && !slice(targetResolver,
                                      from: "static func pasteIntoCapturedTargetWithoutActivation(",
                                      to: "private static func pasteIntoProcess(")
                                .contains("app.activate()"))

        let historyWindow = (try? String(contentsOfFile: "Sources/App/HistoryWindow.swift",
                                         encoding: .utf8)) ?? ""
        reporter.record("History playback joins rows to WAVs by entry UUID",
                        historyWindow.contains("recordingURL(for: entry.id)")
                            && historyWindow.contains("AVAudioPlayer(contentsOf: url)"))

        print(reporter.summaryLine(prefix: "[audio-retention-selftest]"))
        return reporter.passed
    }

    /// The child deliberately recreates the shipped interleaving with the real store:
    ///
    /// 1. `loadRecording` invokes this completion on the store queue.
    /// 2. The completion enqueues main's `recordingURL` call first.
    /// 3. The same completion then takes the production `stillCurrent` path into `main.sync`.
    ///
    /// Dispatch FIFO ordering makes main enter `recordingURL` before it can service the sync block.
    /// On the unfixed store, main waits for the store queue while the store queue waits for main.
    private static func runDeadlockChild(root: URL) -> Bool {
        guard Thread.isMainThread else {
            print("[audio-retention-deadlock-child] FAIL: entrypoint is not on main")
            return false
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("[audio-retention-deadlock-child] FAIL: scratch setup: \(error)")
            return false
        }

        let directory = root.appendingPathComponent("recordings", isDirectory: true)
        let marker = root.appendingPathComponent("completion-entered.txt")
        let store = AudioRetentionStore(directory: directory, enabled: { true })
        let takeID = UUID()
        let payload = Data("RIFF-deadlock-repro".utf8)
        store.retain(payload, id: takeID)
        store.flush()

        let state = AudioRetentionDeadlockChildState()
        let work = DispatchGroup()
        work.enter() // recordingURL main-queue block
        work.enter() // loadRecording completion

        store.loadRecording(id: takeID) { loaded in
            defer { work.leave() }
            if loaded != payload { state.fail("loadRecording returned different bytes") }

            DispatchQueue.main.async {
                defer { work.leave() }
                if store.recordingURL(for: takeID) == nil {
                    state.fail("recordingURL lost the retained take")
                }
            }

            let entered = """
            pid=\(getpid())
            completion_on_main=\(Thread.isMainThread)
            recording_url_enqueued=true
            off_main_still_current_uses_main_sync=true
            """
            do {
                try Data(entered.utf8).write(to: marker, options: .atomic)
            } catch {
                state.fail("could not write interleaving marker: \(error)")
            }

            let stillCurrent: () -> Bool = {
                if Thread.isMainThread { return true }
                return DispatchQueue.main.sync { true }
            }
            if !stillCurrent() { state.fail("synthetic generation changed") }
        }

        let fixedPathDeadline = Date().addingTimeInterval(1)
        while work.wait(timeout: .now()) == .timedOut {
            if Date() >= fixedPathDeadline {
                state.fail("fixed path did not finish within 1.0s")
                break
            }
            _ = RunLoop.main.run(mode: .default,
                                 before: Date().addingTimeInterval(0.01))
        }

        let completed = work.wait(timeout: .now()) == .success
        let failures = state.failures
        if completed && failures.isEmpty {
            print("[audio-retention-deadlock-child] PASS")
            return true
        }
        print("[audio-retention-deadlock-child] FAIL: \(failures.joined(separator: "; "))")
        return false
    }

    /// Run the real interleaving in a disposable child. No result path waits indefinitely: the child
    /// gets SIGKILL at the hard deadline, and the optional `sample` subprocess shares the same bound.
    private static func runDeadlockRepro() -> Bool {
        print("--- retained dictation audio: load/main deadlock subprocess repro ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-audio-deadlock-selftest-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
        } catch {
            reporter.record("deadlock repro child completes before the hard timeout", false,
                            "scratch setup: \(error)")
            print(reporter.summaryLine(prefix: "[audio-retention-deadlock-selftest]"))
            return false
        }

        guard let executable = Bundle.main.executableURL else {
            reporter.record("deadlock repro child completes before the hard timeout", false,
                            "test executable path unavailable")
            print(reporter.summaryLine(prefix: "[audio-retention-deadlock-selftest]"))
            return false
        }

        let childLog = root.appendingPathComponent("child.log")
        guard fm.createFile(atPath: childLog.path, contents: nil),
              let childLogHandle = try? FileHandle(forWritingTo: childLog) else {
            reporter.record("deadlock repro child completes before the hard timeout", false,
                            "child log could not be created")
            print(reporter.summaryLine(prefix: "[audio-retention-deadlock-selftest]"))
            return false
        }
        defer { try? childLogHandle.close() }

        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "--history-selftest",
            deadlockChildFlag,
            deadlockScratchRootFlag, root.path,
        ]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = childLogHandle
        child.standardError = childLogHandle
        let childExited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in childExited.signal() }

        do {
            try child.run()
        } catch {
            reporter.record("deadlock repro child completes before the hard timeout", false,
                            "child launch: \(error)")
            print(reporter.summaryLine(prefix: "[audio-retention-deadlock-selftest]"))
            return false
        }

        let started = Date()
        let deadline = started.addingTimeInterval(deadlockTimeout)
        let marker = root.appendingPathComponent("completion-entered.txt")
        let sampleFile = root.appendingPathComponent("deadlock.sample.txt")
        let sampleLog = root.appendingPathComponent("sample.log")
        var childDidExit = false
        var sampler: Process?
        var samplerExited: DispatchSemaphore?
        var samplingAttempted = false

        while Date() < deadline {
            if childExited.wait(timeout: .now()) == .success {
                childDidExit = true
                break
            }
            let elapsed = Date().timeIntervalSince(started)
            if !samplingAttempted,
               elapsed >= 0.25,
               fm.fileExists(atPath: marker.path) {
                samplingAttempted = true
                let sampleProcess = Process()
                sampleProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sampleProcess.arguments = [String(child.processIdentifier), "1", "-file", sampleFile.path]
                sampleProcess.standardInput = FileHandle.nullDevice
                if fm.createFile(atPath: sampleLog.path, contents: nil),
                   let logHandle = try? FileHandle(forWritingTo: sampleLog) {
                    sampleProcess.standardOutput = logHandle
                    sampleProcess.standardError = logHandle
                    sampleProcess.terminationHandler = { _ in try? logHandle.close() }
                }
                let exited = DispatchSemaphore(value: 0)
                let priorHandler = sampleProcess.terminationHandler
                sampleProcess.terminationHandler = { process in
                    priorHandler?(process)
                    exited.signal()
                }
                do {
                    try sampleProcess.run()
                    sampler = sampleProcess
                    samplerExited = exited
                } catch {
                    print("[audio-retention-deadlock-selftest] sample unavailable: \(error)")
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        if !childDidExit, childExited.wait(timeout: .now()) == .success {
            childDidExit = true
        }
        let timedOut = !childDidExit
        if timedOut {
            _ = kill(child.processIdentifier, SIGKILL)
            childDidExit = childExited.wait(timeout: .now() + 1) == .success
        }

        if let sampler, sampler.isRunning {
            _ = kill(sampler.processIdentifier, SIGKILL)
        }
        if let samplerExited { _ = samplerExited.wait(timeout: .now() + 0.5) }

        if let sample = try? String(contentsOf: sampleFile, encoding: .utf8) {
            let pinned = sample.split(separator: "\n")
                .filter {
                    $0.contains("AudioRetentionStore.recordingURL")
                        || $0.contains("AudioRetentionStore.loadRecording")
                        || $0.contains("__DISPATCH_WAIT_FOR_QUEUE__")
                }
                .prefix(12)
            if !pinned.isEmpty {
                print("[audio-retention-deadlock-selftest] sampled blocked stacks:")
                for line in pinned { print("  \(line)") }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        let markerReached = fm.fileExists(atPath: marker.path)
        let exitOK = childDidExit
            && child.terminationReason == .exit
            && child.terminationStatus == 0
        let detail = String(
            format: "elapsed=%.2fs timeout=%.1fs marker=%@ sample=%@ exit=%@",
            elapsed, deadlockTimeout,
            markerReached ? "reached" : "missing",
            fm.fileExists(atPath: sampleFile.path) ? "captured" : "unavailable",
            exitOK ? "0" : (timedOut ? "SIGKILL-after-timeout" : "nonzero"))
        reporter.record("deadlock repro child completes before the hard timeout",
                        !timedOut && exitOK, detail)
        print(reporter.summaryLine(prefix: "[audio-retention-deadlock-selftest]"))
        return reporter.passed
    }

    private static func slice(_ source: String, from start: String, to end: String) -> String {
        guard let a = source.range(of: start),
              let b = source.range(of: end, range: a.upperBound..<source.endIndex) else { return "" }
        return String(source[a.lowerBound..<b.lowerBound])
    }
}

private final class AudioRetentionDeadlockChildState {
    private let lock = NSLock()
    private var storedFailures: [String] = []

    func fail(_ message: String) {
        lock.lock()
        storedFailures.append(message)
        lock.unlock()
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedFailures
    }
}
