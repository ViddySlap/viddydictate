import Foundation

/// The endless spinner after a long take, both halves of the fix and the cap that ends it.
///
/// The daemon's success body can carry Python's non-JSON `NaN`/`Infinity`/`-Infinity` tokens when a
/// segment metric is non-finite; Apple's `JSONSerialization` rejects the whole body, so the app logs
/// `bad response` and `RetainedTakeRecovery` retried an unreadable clip forever. `parseTranscribeBody`
/// retries with `.json5Allowed`, `parseSegments` defaults a non-finite metric exactly like a missing
/// one, and `RetainedTakeRecovery.maxTranscribeFailures` gives up after a bounded number of
/// ready-daemon failures so the spinner ends.
///
/// Deterministic: synthetic bytes and injected recovery closures only. No daemon, no socket, no real
/// dictation, history or recordings, and no AppKit.
enum SttNonFiniteSelfTest {
    /// How many times an injected `schedule` will synchronously run queued work. A real recovery that
    /// never gives up would recurse forever, so this bound lets the OLD behaviour stop and be observed
    /// as a failed assertion instead of overflowing the stack.
    private static let scheduleLimit = 25

    static func run() -> Bool {
        print("=== ViddyDictate STT non-finite body and retained-recovery cap selftest ===")
        let reporter = SelfTestReporter()

        parserChecks(reporter)
        recoveryChecks(reporter)
        reusedInstanceChecks(reporter)
        staleThenFreshChecks(reporter)

        print(reporter.summaryLine(prefix: "[stt-nonfinite-selftest]"))
        return reporter.passed
    }

    // MARK: - parser

    private static func data(_ json: String) -> Data { Data(json.utf8) }

    /// A `/transcribe` success body whose `avg_logprob` carries `token` (`-Infinity`, `NaN`, ...).
    private static func nonFiniteBody(_ token: String) -> Data {
        data(#"{"transcript":"hello world","raw_transcript":"hello world","segments":[{"start":0.0,"end":1.0,"raw_text":"hello world","no_speech_prob":0.1,"avg_logprob":"#
            + token + #","compression_ratio":1.0}],"model":"m","parameters":{}}"#)
    }

    private static func parserChecks(_ reporter: SelfTestReporter) {
        let minusInfinity = DaemonClient.parseTranscribeBody(nonFiniteBody("-Infinity"))
        reporter.record(
            "stt-nonfinite: new: a body with -Infinity in a segment metric parses with the transcript intact",
            minusInfinity?["transcript"] as? String == "hello world",
            minusInfinity == nil ? "parseTranscribeBody returned nil" : "")

        let nan = DaemonClient.parseTranscribeBody(nonFiniteBody("NaN"))
        reporter.record(
            "stt-nonfinite: new: a body with NaN in a segment metric parses with the transcript intact",
            nan?["transcript"] as? String == "hello world",
            nan == nil ? "parseTranscribeBody returned nil" : "")

        let infinity = DaemonClient.parseTranscribeBody(nonFiniteBody("Infinity"))
        reporter.record(
            "stt-nonfinite: new: a body with Infinity in a segment metric parses with the transcript intact",
            infinity?["transcript"] as? String == "hello world",
            infinity == nil ? "parseTranscribeBody returned nil" : "")

        if let minusInfinity {
            let segments = DaemonClient.parseSegments(from: minusInfinity)
            reporter.record(
                "stt-nonfinite: new: that parsed body's segment decodes with the metric defaulted and the segment kept",
                segments.count == 1
                    && segments[0].rawText == "hello world"
                    && segments[0].noSpeechProb == 0.1
                    && segments[0].avgLogprob == TailCheck.missingSegmentMetricDefault
                    && segments[0].compressionRatio == 1.0,
                String(describing: segments))
        } else {
            reporter.record(
                "stt-nonfinite: new: that parsed body's segment decodes with the metric defaulted and the segment kept",
                false, "parseTranscribeBody returned nil")
        }

        let nested = DaemonClient.parseTranscribeBody(
            data(#"{"transcript":"nested","parameters":{"temps":[1,NaN,3]}}"#))
        reporter.record(
            "stt-nonfinite: new: a body with NaN in a nested position still yields transcript",
            nested?["transcript"] as? String == "nested",
            nested == nil ? "parseTranscribeBody returned nil" : "")

        // ---- guards: behaviour that must not move ------------------------------------------------
        let finite = DaemonClient.parseTranscribeBody(data(
            #"{"transcript":"hello","segments":[{"start":0.0,"end":1.0,"raw_text":"hello","no_speech_prob":0.0,"avg_logprob":-1.0,"compression_ratio":1.5}],"model":"m","parameters":{}}"#))
        let finiteSegments = finite.map(DaemonClient.parseSegments(from:)) ?? []
        reporter.record(
            "stt-nonfinite: guard: a normal finite body parses identically to before",
            finite?["transcript"] as? String == "hello"
                && finiteSegments.count == 1
                && finiteSegments[0].avgLogprob == -1.0
                && finiteSegments[0].compressionRatio == 1.5,
            String(describing: finite))

        let truncated = DaemonClient.parseTranscribeBody(data(#"{"transcript":"#))
        let empty = DaemonClient.parseTranscribeBody(Data())
        let array = DaemonClient.parseTranscribeBody(data("[1,2,3]"))
        reporter.record(
            "stt-nonfinite: guard: a truly broken body (truncated JSON, empty data, a JSON array) still returns nil",
            truncated == nil && empty == nil && array == nil,
            "truncated=\(truncated != nil) empty=\(empty != nil) array=\(array != nil)")

        let direct: [String: Any] = ["segments": [
            ["start": 0.25, "end": 1.5, "raw_text": "hello",
             "no_speech_prob": 0.1, "avg_logprob": -0.5, "compression_ratio": 2.0],
            ["start": 1.5, "end": 2.0, "raw_text": "world",
             "no_speech_prob": NSNull(), "avg_logprob": NSNull(), "compression_ratio": NSNull()],
        ]]
        let decoded = DaemonClient.parseSegments(from: direct)
        reporter.record(
            "stt-nonfinite: guard: parseSegments finite metrics decode unchanged, null metrics default as before",
            decoded.count == 2
                && decoded[0].start == 0.25 && decoded[0].end == 1.5 && decoded[0].rawText == "hello"
                && decoded[0].noSpeechProb == 0.1 && decoded[0].avgLogprob == -0.5
                && decoded[0].compressionRatio == 2.0
                && decoded[1].noSpeechProb == TailCheck.missingSegmentMetricDefault
                && decoded[1].avgLogprob == TailCheck.missingSegmentMetricDefault
                && decoded[1].compressionRatio == TailCheck.missingSegmentMetricDefault,
            String(describing: decoded))
    }

    // MARK: - recovery cap

    private struct RecoveryRun {
        var result: RetainedTakeRecoveryResult?
        var completionCalls = 0
        var transcribeCalls = 0
        var scheduleCalls = 0
        var progress: [Bool] = []
    }

    /// Run one fully synchronous recovery over injected closures. `maxFailures == nil` uses the
    /// production default; otherwise the explicit cap is injected.
    private static func runRecovery(
        ensureReady: @escaping (@escaping (Bool) -> Void) -> Void,
        maxFailures: Int? = nil,
        transcribe: @escaping (Data, UUID, @escaping (String?, String?) -> Void) -> Void
    ) -> RecoveryRun {
        var run = RecoveryRun()
        let wrappedTranscribe: RetainedTakeRecovery.Transcribe = { wav, id, done in
            run.transcribeCalls += 1
            transcribe(wav, id, done)
        }
        let schedule: RetainedTakeRecovery.Schedule = { work in
            run.scheduleCalls += 1
            if run.scheduleCalls <= scheduleLimit { work() }
        }
        let load: RetainedTakeRecovery.Load = { _, done in done(Data("RIFF".utf8)) }
        let progress: RetainedTakeRecovery.Progress = { _, pending in run.progress.append(pending) }

        let recovery: RetainedTakeRecovery
        if let maxFailures {
            recovery = RetainedTakeRecovery(load: load, ensureReady: ensureReady,
                                            transcribe: wrappedTranscribe, schedule: schedule,
                                            progress: progress,
                                            maxTranscribeFailures: maxFailures)
        } else {
            recovery = RetainedTakeRecovery(load: load, ensureReady: ensureReady,
                                            transcribe: wrappedTranscribe, schedule: schedule,
                                            progress: progress)
        }
        recovery.recover(takeID: UUID(), retentionWasEnabled: true, stillCurrent: { true }) { result in
            run.result = result
            run.completionCalls += 1
        }
        return run
    }

    private static func recoveryChecks(_ reporter: SelfTestReporter) {
        // new: default 5 ready-daemon failures end the take, once, with progress(false), no 6th try.
        let capped = runRecovery(ensureReady: { $0(true) },
                                 transcribe: { _, _, done in done(nil, "bad response") })
        reporter.record(
            "stt-nonfinite: new: after 5 consecutive non-warm-up failures with a ready daemon the recovery finishes .unavailable once, calls progress(take,false), and makes no 6th attempt",
            capped.result == .unavailable("the speech engine could not read this recording")
                && capped.completionCalls == 1
                && capped.transcribeCalls == 5
                && capped.scheduleCalls == 4
                && capped.progress == [true, false],
            "result=\(String(describing: capped.result)) completions=\(capped.completionCalls) "
                + "transcribe=\(capped.transcribeCalls) schedule=\(capped.scheduleCalls) progress=\(capped.progress)")

        // new: the cap is injected, not hard-coded.
        let cappedTwo = runRecovery(ensureReady: { $0(true) }, maxFailures: 2,
                                    transcribe: { _, _, done in done(nil, "bad response") })
        reporter.record(
            "stt-nonfinite: new: a failure count injected as 2 finishes after 2",
            cappedTwo.result == .unavailable("the speech engine could not read this recording")
                && cappedTwo.completionCalls == 1
                && cappedTwo.transcribeCalls == 2
                && cappedTwo.progress == [true, false],
            "result=\(String(describing: cappedTwo.result)) completions=\(cappedTwo.completionCalls) "
                + "transcribe=\(cappedTwo.transcribeCalls) progress=\(cappedTwo.progress)")

        retainedClipUntouched(reporter)

        // guard: a warm-up error is never a reason to give up.
        var warmCalls = 0
        let warm = runRecovery(ensureReady: { $0(true) }, transcribe: { _, _, done in
            warmCalls += 1
            if warmCalls <= 20 { done(nil, "Model Loading") } else { done("warm recovered", nil) }
        })
        reporter.record(
            "stt-nonfinite: guard: 20 consecutive model loading errors do NOT hit the cap and a later success still recovers the text",
            warm.result == .recovered("warm recovered")
                && warm.completionCalls == 1
                && warm.transcribeCalls == 21
                && warm.scheduleCalls == 20
                && warm.progress == [true, false],
            "result=\(String(describing: warm.result)) transcribe=\(warm.transcribeCalls) "
                + "schedule=\(warm.scheduleCalls)")

        // guard: a success after 4 failures recovers, and the counter it reset lets 4 more failures
        // pass without ending the take.
        var scriptIndex = 0
        var progress: [Bool] = []
        var results: [RetainedTakeRecoveryResult] = []
        let resetSchedule: RetainedTakeRecovery.Schedule = { work in work() }
        let recovery = RetainedTakeRecovery(
            load: { _, done in done(Data("RIFF".utf8)) },
            ensureReady: { $0(true) },
            transcribe: { _, _, done in
                scriptIndex += 1
                switch scriptIndex {
                case 5: done("first text", nil)
                case 10: done("second text", nil)
                default: done(nil, "bad response")
                }
            },
            schedule: resetSchedule,
            progress: { _, pending in progress.append(pending) })
        recovery.recover(takeID: UUID(), retentionWasEnabled: true, stillCurrent: { true }) {
            results.append($0)
        }
        recovery.recover(takeID: UUID(), retentionWasEnabled: true, stillCurrent: { true }) {
            results.append($0)
        }
        reporter.record(
            "stt-nonfinite: guard: a success after 4 failures recovers and the count resets (then 4 more failures do not end it)",
            results == [.recovered("first text"), .recovered("second text")]
                && progress == [true, false, true, false],
            "results=\(results) progress=\(progress)")

        // guard: the default cap is 5, and a daemon that never reports ready never counts.
        let defaultCap = RetainedTakeRecovery()
        let notReady = runRecovery(ensureReady: { $0(false) }, maxFailures: 2,
                                   transcribe: { _, _, done in done(nil, "bad response") })
        reporter.record(
            "stt-nonfinite: guard: maxTranscribeFailures default is 5 and ensureReady == false passes never count",
            defaultCap.maxTranscribeFailures == 5
                && notReady.result == nil
                && notReady.completionCalls == 0
                && notReady.transcribeCalls == 0
                && notReady.scheduleCalls == scheduleLimit + 1,
            "default=\(defaultCap.maxTranscribeFailures) result=\(String(describing: notReady.result)) "
                + "transcribe=\(notReady.transcribeCalls) schedule=\(notReady.scheduleCalls)")
    }

    /// The judge's counter-leak repro: production owns ONE long-lived `RetainedTakeRecovery`, so the
    /// same instance runs take A (which caps), take B (which must count from zero and recover), and
    /// take C (which must cap again). On the OLD stored-counter behaviour take B and take C each give
    /// up on their first failure; every loop here is bounded by the injected `schedule` attempt cap,
    /// so that wrong behaviour stops and is recorded as a failed assertion instead of hanging.
    private static func reusedInstanceChecks(_ reporter: SelfTestReporter) {
        var scheduleCalls = 0
        var transcribeCalls = 0
        var progress: [Bool] = []
        var results: [RetainedTakeRecoveryResult] = []
        var completions = 0
        var takeIndex = 0
        var attemptInTake = 0

        let recovery = RetainedTakeRecovery(
            load: { _, done in done(Data("RIFF".utf8)) },
            ensureReady: { $0(true) },
            transcribe: { _, _, done in
                transcribeCalls += 1
                attemptInTake += 1
                if takeIndex == 2 && attemptInTake == 5 {
                    done("take B recovered", nil)   // take B (second take): four failures, then a success
                } else {
                    done(nil, "bad response")         // take A and take C: cap after five
                }
            },
            schedule: { work in
                scheduleCalls += 1
                if scheduleCalls <= scheduleLimit { work() }
            },
            progress: { _, pending in progress.append(pending) })

        func runTake() {
            takeIndex += 1
            attemptInTake = 0
            recovery.recover(takeID: UUID(), retentionWasEnabled: true, stillCurrent: { true }) {
                results.append($0)
                completions += 1
            }
        }

        runTake()   // take A: five failures -> .unavailable
        runTake()   // take B: fresh count, four failures, then a success -> .recovered
        runTake()   // take C: fresh count again -> five failures -> .unavailable

        reporter.record(
            "stt-nonfinite: new: one reused RetainedTakeRecovery counts fresh per take -- A caps, B survives cap-1 failures and recovers, C caps again",
            results == [
                .unavailable("the speech engine could not read this recording"),
                .recovered("take B recovered"),
                .unavailable("the speech engine could not read this recording"),
            ]
                && completions == 3
                && progress == [true, false, true, false, true, false]
                && transcribeCalls == 15,
            "results=\(results) completions=\(completions) transcribe=\(transcribeCalls) "
                + "schedule=\(scheduleCalls) progress=\(progress)")
    }

    /// A stale/cancelled take must not leave a partial failure count behind. The stale take counts
    /// four ready-daemon failures, then the fifth readiness check cancels it (`stillCurrent` flips
    /// false). A fresh take on the SAME instance must start at zero and recover on its fifth attempt.
    /// On the OLD stored-counter behaviour the fresh take inherits four, caps on its first failure,
    /// and never recovers; the injected `schedule` attempt cap keeps the wrong behaviour finite.
    private static func staleThenFreshChecks(_ reporter: SelfTestReporter) {
        var scheduleCalls = 0
        var transcribeCalls = 0
        var progress: [Bool] = []
        var results: [RetainedTakeRecoveryResult] = []
        var completions = 0
        var isCurrent = true
        var readyCalls = 0
        var freshAttempt = 0
        var onFreshTake = false

        let recovery = RetainedTakeRecovery(
            load: { _, done in done(Data("RIFF".utf8)) },
            ensureReady: { done in
                readyCalls += 1
                // The stale take's fifth readiness check is where it is cancelled mid-recovery.
                if readyCalls == 5 { isCurrent = false }
                done(true)
            },
            transcribe: { _, _, done in
                transcribeCalls += 1
                if !onFreshTake {
                    done(nil, "bad response")   // stale take: four counted failures before cancel
                } else {
                    freshAttempt += 1
                    if freshAttempt == 5 { done("fresh recovered", nil) }
                    else { done(nil, "bad response") }
                }
            },
            schedule: { work in
                scheduleCalls += 1
                if scheduleCalls <= scheduleLimit { work() }
            },
            progress: { _, pending in progress.append(pending) })

        recovery.recover(takeID: UUID(), retentionWasEnabled: true, stillCurrent: { isCurrent }) {
            results.append($0)
            completions += 1
        }
        let staleCompletions = completions

        isCurrent = true
        onFreshTake = true
        recovery.recover(takeID: UUID(), retentionWasEnabled: true, stillCurrent: { isCurrent }) {
            results.append($0)
            completions += 1
        }

        reporter.record(
            "stt-nonfinite: guard: a stale/cancelled take does not leak its failure count into the next fresh take on the same instance",
            staleCompletions == 0
                && results == [.recovered("fresh recovered")]
                && completions == 1
                && progress == [true, false, true, false]
                && transcribeCalls == 9
                && scheduleCalls == 8,
            "staleCompletions=\(staleCompletions) results=\(results) completions=\(completions) "
                + "transcribe=\(transcribeCalls) schedule=\(scheduleCalls) progress=\(progress)")
    }

    /// A real retained clip: the recovery gives up and the WAV is still on disk, unchanged, and the
    /// store still lists it. The store is a scratch directory, never the user's recordings.
    private static func retainedClipUntouched(_ reporter: SelfTestReporter) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-stt-nonfinite-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let store = AudioRetentionStore(directory: root, enabled: { true })
        let takeID = UUID()
        let wav = Data("RIFF-nonfinite-untouched".utf8)
        store.retain(wav, id: takeID)
        store.flush()
        let url = store.recordingURL(for: takeID)

        var loadCalls = 0
        var scheduleCalls = 0
        var progress: [Bool] = []
        var result: RetainedTakeRecoveryResult?
        var completionCalls = 0
        let done = DispatchSemaphore(value: 0)
        let recovery = RetainedTakeRecovery(
            load: { id, completion in
                loadCalls += 1
                store.loadRecording(id: id, completion: completion)
            },
            ensureReady: { $0(true) },
            transcribe: { _, _, completion in completion(nil, "bad response") },
            schedule: { work in
                scheduleCalls += 1
                if scheduleCalls <= scheduleLimit { work() }
            },
            progress: { _, pending in progress.append(pending) })
        recovery.recover(takeID: takeID, retentionWasEnabled: true, stillCurrent: { true }) {
            result = $0
            completionCalls += 1
            done.signal()
        }
        _ = done.wait(timeout: .now() + 6)
        store.flush()

        let onDisk = url.flatMap { try? Data(contentsOf: $0) }
        reporter.record(
            "stt-nonfinite: new: the retained-clip loader is not asked to delete anything and the WAV is untouched",
            result == .unavailable("the speech engine could not read this recording")
                && completionCalls == 1
                && loadCalls == 1
                && onDisk == wav
                && store.retainedIDs().contains(takeID),
            "result=\(String(describing: result)) completions=\(completionCalls) loads=\(loadCalls) "
                + "onDisk=\(onDisk?.count ?? -1) retained=\(store.retainedIDs().contains(takeID))")
    }
}
