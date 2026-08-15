import Foundation

/// Scratch-only proof for the local 100-take WAV ring. No mic, daemon, preferences, or real history.
enum AudioRetentionSelfTest {
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
        var loadedCaptured: Data?
        captured.loadRecording(id: capturedID) { loadedCaptured = $0 }
        captured.flush()
        reporter.record("take-release retention decision survives a later setting change",
                        loadedCaptured == capturedBytes)

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

    private static func slice(_ source: String, from start: String, to end: String) -> String {
        guard let a = source.range(of: start),
              let b = source.range(of: end, range: a.upperBound..<source.endIndex) else { return "" }
        return String(source[a.lowerBound..<b.lowerBound])
    }
}
