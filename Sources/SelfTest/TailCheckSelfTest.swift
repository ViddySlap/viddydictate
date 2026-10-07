import AppKit
import Foundation

/// GP of chain `vdtpga`: the protected graders for the Phase 1 (observe-only) Swift port of
/// `Tools/tailcheck/core.py`. Flag `--tailcheck-selftest --only <arm>`. Tier `.excluded` until a
/// later "wire" link promotes individual arms once they are green (see `SelfTestManifestFlag`'s
/// own comment convention for `--modelfit-selftest`).
///
/// This file is PROTECTED: no later link in chain `vdtpga` may edit it to make its own stub pass.
/// Every red below traces to exactly one named stub line in `Sources/App/TailCheck.swift`
/// (`TailCheck.trigger` always `[]`, `TailCheck.acceptCut` always `(false, "stub")`,
/// `TailCheck.observeRecord` always `[:]`, `TailCheckObserver.defaultSink` writes nothing) --
/// never to this file. A later link replaces those stubs with the real port; this file is how it
/// is measured.
enum TailCheckSelfTest {
    enum Arm: String, CaseIterable {
        case triggerParity = "trigger-parity"
        case cutrulesParity = "cutrules-parity"
        case observeNoText = "observe-no-text"
        case pasteUnchanged = "paste-unchanged"
        case observeLogBounded = "observe-log-bounded"
        // 2026-10-06 scope addition: source attribution, the judge seam, the HUD flag seam.
        case sourceAttribution = "source-attribution"
        case judgeBoundedContext = "judge-bounded-context"
        case judgeFailOpen = "judge-fail-open"
        case judgeOnlyWhenTriggered = "judge-only-when-triggered"
        case hudFlagOnly = "hud-flag-only"
        // vdtpwg (gate author, Phase 1's I3 seams): the real local-route judge, the real HUD flag,
        // and the hook into the dictation path. See each `run*` function's own doc comment for which
        // named stub (or standing guardrail) each arm traces to.
        case judgeLocalOnly = "judge-local-only"
        case judgeRequestShape = "judge-request-shape"
        case judgeTimeoutPinned = "judge-timeout-pinned"
        case daemonSegmentsDecoded = "daemon-segments-decoded"
        case hookAfterPaste = "hook-after-paste"
        case hookWired = "hook-wired"
        case hudFlagReal = "hud-flag-real"
    }

    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count,
              let arm = Arm(rawValue: arguments[i + 1])
        else {
            let names = Arm.allCases.map(\.rawValue).joined(separator: "|")
            print("[tailcheck-selftest] FAIL: --only <\(names)> is required")
            return 2
        }
        let ok: Bool
        switch arm {
        case .triggerParity:     ok = runTriggerParity()
        case .cutrulesParity:    ok = runCutrulesParity()
        case .observeNoText:     ok = runObserveNoText()
        case .pasteUnchanged:    ok = runPasteUnchanged()
        case .observeLogBounded: ok = runObserveLogBounded()
        case .sourceAttribution:      ok = runSourceAttribution()
        case .judgeBoundedContext:    ok = runJudgeBoundedContext()
        case .judgeFailOpen:          ok = runJudgeFailOpen()
        case .judgeOnlyWhenTriggered: ok = runJudgeOnlyWhenTriggered()
        case .hudFlagOnly:            ok = runHudFlagOnly()
        case .judgeLocalOnly:         ok = runJudgeLocalOnly()
        case .judgeRequestShape:      ok = runJudgeRequestShape()
        case .judgeTimeoutPinned:     ok = runJudgeTimeoutPinned()
        case .daemonSegmentsDecoded:  ok = runDaemonSegmentsDecoded()
        case .hookAfterPaste:         ok = runHookAfterPaste()
        case .hookWired:              ok = runHookWired()
        case .hudFlagReal:            ok = runHudFlagReal()
        }
        return ok ? 0 : 1
    }

    // MARK: - Fixture loading (Tools/tailcheck/parity-fixture.json, exported FROM core.py)

    private static let fixturePath = "Tools/tailcheck/parity-fixture.json"

    private struct SegmentJSON: Decodable {
        let start: Double
        let end: Double
        let rawText: String
        let noSpeechProb: Double
        let avgLogprob: Double
        let compressionRatio: Double

        enum CodingKeys: String, CodingKey {
            case start, end
            case rawText = "raw_text"
            case noSpeechProb = "no_speech_prob"
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
        }

        var asTailCheckSegment: TailCheck.Segment {
            TailCheck.Segment(start: start, end: end, rawText: rawText,
                              noSpeechProb: noSpeechProb, avgLogprob: avgLogprob,
                              compressionRatio: compressionRatio)
        }
    }

    private struct TriggerCase: Decodable {
        let label: String
        let segments: [SegmentJSON]
        let rawText: String
        let finalText: String
        let expectedReasonsSorted: [String]

        enum CodingKeys: String, CodingKey {
            case label, segments
            case rawText = "raw_text"
            case finalText = "final_text"
            case expectedReasonsSorted = "expected_reasons_sorted"
        }
    }

    private struct AcceptCutCase: Decodable {
        let label: String
        let text: String
        let junkSuffix: String
        let boundaries: [Int]?
        let maxWords: Int
        let maxShare: Double
        let expectedAccepted: Bool
        let expectedReason: String

        enum CodingKeys: String, CodingKey {
            case label, text
            case junkSuffix = "junk_suffix"
            case boundaries
            case maxWords = "max_words"
            case maxShare = "max_share"
            case expectedAccepted = "expected_accepted"
            case expectedReason = "expected_reason"
        }
    }

    private struct ParityFixture: Decodable {
        let schema: String
        let triggerCases: [TriggerCase]
        let acceptCutCases: [AcceptCutCase]

        enum CodingKeys: String, CodingKey {
            case schema
            case triggerCases = "trigger_cases"
            case acceptCutCases = "accept_cut_cases"
        }
    }

    private static func loadFixture() -> ParityFixture? {
        let url = URL(fileURLWithPath: fixturePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ParityFixture.self, from: data)
    }

    // MARK: - trigger-parity

    private static func runTriggerParity() -> Bool {
        print("=== ViddyDictate tailcheck — trigger-parity arm ===")
        let reporter = SelfTestReporter()

        guard let fixture = loadFixture() else {
            reporter.record("loaded \(fixturePath)", false, "could not read/decode fixture")
            print("\n=== RESULT ===")
            print(reporter.summaryLine(prefix: "trigger-parity"))
            return reporter.passed
        }
        reporter.record("loaded \(fixture.triggerCases.count) trigger cases from \(fixturePath)", true)

        for c in fixture.triggerCases {
            let segments = c.segments.map(\.asTailCheckSegment)
            let actual = TailCheck.trigger(segments: segments, rawText: c.rawText, finalText: c.finalText)
            reporter.record(
                "trigger[\(c.label)] matches the fixture",
                actual.sorted() == c.expectedReasonsSorted,
                "want=\(c.expectedReasonsSorted) got=\(actual.sorted())")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "trigger-parity"))
        return reporter.passed
    }

    // MARK: - cutrules-parity

    private static func runCutrulesParity() -> Bool {
        print("=== ViddyDictate tailcheck — cutrules-parity arm ===")
        let reporter = SelfTestReporter()

        guard let fixture = loadFixture() else {
            reporter.record("loaded \(fixturePath)", false, "could not read/decode fixture")
            print("\n=== RESULT ===")
            print(reporter.summaryLine(prefix: "cutrules-parity"))
            return reporter.passed
        }
        reporter.record("loaded \(fixture.acceptCutCases.count) accept_cut cases from \(fixturePath)", true)

        for c in fixture.acceptCutCases {
            let (accepted, reason) = TailCheck.acceptCut(
                text: c.text, junkSuffix: c.junkSuffix, boundaries: c.boundaries,
                maxWords: c.maxWords, maxShare: c.maxShare)
            reporter.record(
                "acceptCut[\(c.label)] matches the fixture",
                accepted == c.expectedAccepted && reason == c.expectedReason,
                "want=(\(c.expectedAccepted), \(c.expectedReason)) got=(\(accepted), \(reason))")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "cutrules-parity"))
        return reporter.passed
    }

    // MARK: - observe-no-text
    //
    // Mirrors `test_core.py`'s `ObserveRecordTests.test_contains_no_substring_of_the_input_text`:
    // against the stub (`observeRecord` always `[:]`) this is a vacuous pass -- there are no values
    // to leak through because there are no values at all. Not stub-caused red. It stands as a
    // standing guardrail: a later link's real `observeRecord` must keep this green for real, by
    // never putting a substring of `text` (length >= 4) into any value it returns.

    private static func runObserveNoText() -> Bool {
        print("=== ViddyDictate tailcheck — observe-no-text arm ===")
        let reporter = SelfTestReporter()

        let text = "Send the final draft to Brian before lunch please."
        let longTriggerText = "Checking in now. " + Array(repeating: "primarily", count: 8).joined(separator: " ")
        let cases: [(String, String, [String], String, Int, Double, String)] = [
            ("clean/no_trigger", text, [], "no_trigger", 0, 1.2, "none"),
            ("triggered/repeat_loop", longTriggerText, [TailCheck.reasonRepeatLoop], "triggered",
             0, 3.5, "none"),
        ]

        for (label, inputText, reasons, verdict, junkLen, latency, judge) in cases {
            let record = TailCheck.observeRecord(
                text: inputText, reasons: reasons, verdict: verdict,
                junkSuffixLen: junkLen, latencyMs: latency, judgeName: judge)
            var leaked: String?
            for (key, value) in record {
                let rendered = "\(value)"
                leaked = substringLeak(of: inputText, in: rendered).map { "key=\(key) leak=\($0)" }
                if leaked != nil { break }
            }
            reporter.record("observeRecord[\(label)] leaks no substring >= 4 chars of the input text",
                            leaked == nil, leaked ?? "")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "observe-no-text"))
        return reporter.passed
    }

    /// First substring of `text` of length >= 4 that appears verbatim in `rendered`, or `nil`.
    private static func substringLeak(of text: String, in rendered: String) -> String? {
        guard text.count >= 4, !rendered.isEmpty else { return nil }
        let chars = Array(text)
        var i = 0
        while i + 4 <= chars.count {
            let candidate = String(chars[i..<(i + 4)])
            if rendered.contains(candidate) { return candidate }
            i += 1
        }
        return nil
    }

    // MARK: - paste-unchanged
    //
    // Not stub-caused red today: `TailCheckObserver.afterFinalText` always returns `text` itself,
    // by construction, regardless of `enabled` or what the sink does -- Phase 1 never edits the
    // paste. Stands as a standing guardrail against a later implementation that starts threading a
    // mutated string back out of the seam.

    private static func runPasteUnchanged() -> Bool {
        print("=== ViddyDictate tailcheck — paste-unchanged arm ===")
        let reporter = SelfTestReporter()

        let text = "I approve the plan for Monday and the budget we discussed. Thank you."
        let segments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: "I approve the plan for Monday and the budget we discussed.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 6.5, end: 7.0, rawText: "Thank you.",
                              noSpeechProb: 0.3, avgLogprob: -0.3, compressionRatio: 1.0),
        ]

        var spyLines: [String] = []
        let spySink: TailCheckObserver.Sink = { line in spyLines.append(line) }

        let observerOnDefaultSink = TailCheckObserver()
        let observerOnSpySink = TailCheckObserver(sink: spySink)

        let pasteWithDefaultSinkOn = observerOnDefaultSink.afterFinalText(
            text, segments: segments, rawText: text, enabled: true)
        let pasteWithSpySinkOn = observerOnSpySink.afterFinalText(
            text, segments: segments, rawText: text, enabled: true)
        let pasteWithObserverOff = observerOnSpySink.afterFinalText(
            text, segments: segments, rawText: text, enabled: false)

        reporter.record("observer ON (default sink) delivers the text unchanged",
                        pasteWithDefaultSinkOn == text, pasteWithDefaultSinkOn)
        reporter.record("observer ON (spy sink) delivers the text unchanged",
                        pasteWithSpySinkOn == text, pasteWithSpySinkOn)
        reporter.record("observer OFF delivers the text unchanged",
                        pasteWithObserverOff == text, pasteWithObserverOff)
        reporter.record("ON and OFF paste outputs are byte-identical",
                        pasteWithSpySinkOn == pasteWithObserverOff)
        reporter.record("enabling the observer actually reached the spy sink",
                        spyLines.count == 1, "calls=\(spyLines.count)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "paste-unchanged"))
        return reporter.passed
    }

    // MARK: - observe-log-bounded
    //
    // Exercises the REAL default sink and its REAL target path
    // (`AppPaths.applicationSupportDirectory()/TailCheckObserver.defaultLogFileName`), the same
    // "default production store URL under scratch HOME" pattern `FreshInstallRehearsal` already
    // uses: safe only because every build/test invocation of this binary runs with
    // HOME/CFFIXED_USER_HOME pointed at a throwaway scratch home (house rules; `build.sh`'s own
    // keychain-hang workaround). It never touches a real ~/Library/Application Support.
    //
    // Red today, traced to `TailCheckObserver.defaultSink`'s no-op line: the stub writes nothing,
    // so the file is never created. The bound-respecting assertion is written to hold regardless --
    // it is the one that stays meaningful once a later link replaces the stub with a real,
    // size-bounded JSONL writer.

    private static func runObserveLogBounded() -> Bool {
        print("=== ViddyDictate tailcheck — observe-log-bounded arm ===")
        let reporter = SelfTestReporter()

        let dir = AppPaths.ensureApplicationSupportDirectory()
        let path = dir.appendingPathComponent(TailCheckObserver.defaultLogFileName)
        try? FileManager.default.removeItem(at: path)

        let observer = TailCheckObserver()
        let text = "Checking in now. " + Array(repeating: "primarily", count: 8).joined(separator: " ")
        let segments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: "Checking in now.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 5.1, end: 12.0,
                              rawText: Array(repeating: "primarily", count: 8).joined(separator: " "),
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]

        var allUnchanged = true
        let writeCount = 50
        for _ in 0..<writeCount {
            let paste = observer.afterFinalText(text, segments: segments, rawText: text, enabled: true)
            if paste != text { allUnchanged = false }
        }
        reporter.record("the seam never mutates the paste text across \(writeCount) writes", allUnchanged)

        let fileExists = FileManager.default.fileExists(atPath: path.path)
        reporter.record("the default sink actually wrote the observe log after \(writeCount) calls",
                        fileExists, path.path)

        if fileExists {
            let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? nil
            let size = sizeBytes ?? -1
            reporter.record("the observe log stays within the documented size bound",
                            size >= 0 && size <= TailCheckObserver.defaultLogMaxBytes,
                            "size=\(size) bound=\(TailCheckObserver.defaultLogMaxBytes)")
        } else {
            reporter.record("the observe log stays within the documented size bound (vacuous: no file yet)", true)
        }

        try? FileManager.default.removeItem(at: path)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "observe-log-bounded"))
        return reporter.passed
    }

    // MARK: - source-attribution (2026-10-06 scope addition, part A)
    //
    // Red today, traced to `TailCheck.observeRecord`'s `[:]` stub line (the SAME stub the original
    // arms already trace to): synthetic Whisper-only / cleanup-only / both / neither cases, each
    // checked against the exact flags the real contract documents.

    private static func runSourceAttribution() -> Bool {
        print("=== ViddyDictate tailcheck — source-attribution arm ===")
        let reporter = SelfTestReporter()

        struct Case {
            let label: String
            let reasons: [String]
            let cleanupLevel: String
            let wantTailInRaw: Bool
            let wantTailAddedByCleanup: Bool
        }
        let cases: [Case] = [
            Case(label: "whisper-only", reasons: [TailCheck.reasonRepeatLoop],
                cleanupLevel: TailCheck.cleanupLevelNone,
                wantTailInRaw: true, wantTailAddedByCleanup: false),
            Case(label: "cleanup-only", reasons: [TailCheck.reasonCleanupAddedSuffix],
                cleanupLevel: TailCheck.cleanupLevelL1,
                wantTailInRaw: false, wantTailAddedByCleanup: true),
            Case(label: "both", reasons: [TailCheck.reasonRepeatLoop, TailCheck.reasonCleanupAddedSuffix],
                cleanupLevel: TailCheck.cleanupLevelL2,
                wantTailInRaw: true, wantTailAddedByCleanup: true),
            Case(label: "neither", reasons: [], cleanupLevel: TailCheck.cleanupLevelL3,
                wantTailInRaw: false, wantTailAddedByCleanup: false),
        ]

        for c in cases {
            let record = TailCheck.observeRecord(
                text: "placeholder text long enough to matter for this arm's own leak checks",
                reasons: c.reasons, verdict: c.reasons.isEmpty ? "no_trigger" : "triggered",
                junkSuffixLen: 0, latencyMs: 0, judgeName: "none", cleanupLevel: c.cleanupLevel)
            reporter.record("[\(c.label)] tail_in_raw == \(c.wantTailInRaw)",
                            (record["tail_in_raw"] as? Bool) == c.wantTailInRaw,
                            "got=\(String(describing: record["tail_in_raw"]))")
            reporter.record("[\(c.label)] tail_added_by_cleanup == \(c.wantTailAddedByCleanup)",
                            (record["tail_added_by_cleanup"] as? Bool) == c.wantTailAddedByCleanup,
                            "got=\(String(describing: record["tail_added_by_cleanup"]))")
            reporter.record("[\(c.label)] cleanup_level == \(c.cleanupLevel)",
                            (record["cleanup_level"] as? String) == c.cleanupLevel,
                            "got=\(String(describing: record["cleanup_level"]))")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "source-attribution"))
        return reporter.passed
    }

    // MARK: - judge-bounded-context (2026-10-06 scope addition, part B)
    //
    // Split in two: the pure bounding helpers (`TailCheck.boundedContext` / `tailAndPreceding`) are
    // implemented for real (see their own doc comments) and are green here. The end-to-end spy-judge
    // check is red today, traced to `TailCheck.trigger`'s `[]` stub: nothing ever triggers yet, so
    // the seam never reaches the judge at all, let alone with a correctly-bounded context.

    private static func runJudgeBoundedContext() -> Bool {
        print("=== ViddyDictate tailcheck — judge-bounded-context arm ===")
        let reporter = SelfTestReporter()

        // Exactly mirrors `test_core.py`'s
        // `test_check_bounds_context_to_last_two_sentences_and_a_char_cap` fixture: any two
        // consecutive sentences alone exceed `maxContextChars`, so passing requires BOTH bounds
        // enforced for real, never coincidentally satisfied by short fixture text.
        let paddingWord = "stakeholder "
        let wordsNeeded = (TailCheck.maxContextChars / 2) / paddingWord.count + 5
        func longSentence(_ marker: String) -> String {
            "\(marker) " + String(repeating: paddingWord, count: wordsNeeded) + "done."
        }
        let sentences = (0..<40).map { longSentence("Sentence\($0)") }
        let body = sentences.joined(separator: " ")
        let tailText = Array(repeating: "primarily", count: 8).joined(separator: " ")
        let text = "\(body) \(tailText)"
        let segments = [
            TailCheck.Segment(start: 0.0, end: 200.0, rawText: body,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 200.1, end: 210.0, rawText: tailText,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]
        let reasons = [TailCheck.reasonRepeatLoop]

        let (tail, preceding) = TailCheck.tailAndPreceding(
            text: text, rawText: text, segments: segments, reasons: reasons)
        reporter.record("tailAndPreceding derives the last segment's raw text as the tail",
                        tail == tailText)

        let context = TailCheck.boundedContext(preceding: preceding)
        let contextSentenceCount = context.isEmpty ? 0
            : context.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }.count
        reporter.record(
            "boundedContext keeps at most \(TailCheck.maxContextSentences) sentences worth",
            contextSentenceCount <= TailCheck.maxContextSentences, "got=\(contextSentenceCount)")
        reporter.record("boundedContext respects the char cap", context.count <= TailCheck.maxContextChars,
                        "len=\(context.count) cap=\(TailCheck.maxContextChars)")
        reporter.record("boundedContext keeps the END nearest the tail (ends with the last sentence)",
                        context.hasSuffix(sentences[sentences.count - 1]), context.suffix(40).description)

        final class SpyJudge: TailJudge {
            var calls: [(String, String)] = []
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                calls.append((context, tail))
                completion(.success(.clean))
            }
        }
        let spy = SpyJudge()
        let observer = TailCheckObserver(judge: spy)
        _ = observer.afterFinalText(text, segments: segments, rawText: text)
        reporter.record("the seam actually calls the judge once a trigger fires",
                        spy.calls.count == 1, "calls=\(spy.calls.count)")
        if let (gotContext, gotTail) = spy.calls.first {
            reporter.record("the judge received the last segment's raw text as the tail", gotTail == tailText)
            reporter.record("the judge's context stays within the char cap",
                            gotContext.count <= TailCheck.maxContextChars)
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "judge-bounded-context"))
        return reporter.passed
    }

    // MARK: - judge-fail-open (2026-10-06 scope addition, part B)
    //
    // `TailCheckObserver.callJudgeWithHardTimeout` is implemented for real (see its own doc
    // comment), so both checks below are green today -- a legitimate standing guardrail, not a
    // vacuous pass: a throwing judge and a judge that never calls back are both genuinely exercised.

    private static func runJudgeFailOpen() -> Bool {
        print("=== ViddyDictate tailcheck — judge-fail-open arm ===")
        let reporter = SelfTestReporter()

        struct Boom: Error {}
        final class ThrowingJudge: TailJudge {
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                completion(.failure(Boom()))
            }
        }
        final class HangingJudge: TailJudge {
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                // Never calls completion -- simulates a judge that exceeds the timeout.
            }
        }

        let throwOutcome = TailCheckObserver.callJudgeWithHardTimeout(
            ThrowingJudge(), context: "ctx", tail: "tail", timeoutMs: 100)
        reporter.record("a throwing judge fails open as .error",
                        {
                            if case .error = throwOutcome { return true }
                            return false
                        }(), "\(throwOutcome)")

        let t0 = DispatchTime.now()
        let hangOutcome = TailCheckObserver.callJudgeWithHardTimeout(
            HangingJudge(), context: "ctx", tail: "tail", timeoutMs: 100)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
        reporter.record("a hanging judge fails open as .timeout",
                        {
                            if case .timeout = hangOutcome { return true }
                            return false
                        }(), "\(hangOutcome)")
        reporter.record("the hard timeout actually bounds the wait (<= ~1s for a 100ms budget)",
                        elapsedMs <= 1_000, "elapsed=\(elapsedMs)ms")

        // End-to-end: the seam must paste unchanged and record "timeout"/"error"-shaped verdicts
        // even when triggered, through a judge that fails in each of these ways. Red today, same
        // trace as `judge-bounded-context`'s end-to-end check: `TailCheck.trigger` never fires, so
        // this particular judge is never even reached -- the fail-open GUARANTEE (paste unchanged)
        // still holds regardless, by `afterFinalText`'s own construction.
        let text = "I approve. Thank you."
        let segments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: "I approve.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 6.5, end: 7.0, rawText: "Thank you.",
                              noSpeechProb: 0.3, avgLogprob: -0.3, compressionRatio: 1.0),
        ]
        let observer = TailCheckObserver(judge: ThrowingJudge())
        let paste = observer.afterFinalText(text, segments: segments, rawText: text)
        reporter.record("end-to-end: paste stays unchanged even through a throwing judge", paste == text)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "judge-fail-open"))
        return reporter.passed
    }

    // MARK: - judge-only-when-triggered (2026-10-06 scope addition, part B)
    //
    // Not stub-caused red today, same standing-guardrail shape as `paste-unchanged`: an ordinary
    // clean single-segment take must never reach the judge. True today because `trigger` (whether
    // stub or real) returns `[]` for this exact input; stays true once `trigger` is real.

    private static func runJudgeOnlyWhenTriggered() -> Bool {
        print("=== ViddyDictate tailcheck — judge-only-when-triggered arm ===")
        let reporter = SelfTestReporter()

        final class ExplodingJudge: TailJudge {
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                fatalError("judge must not be called when trigger() is empty")
            }
        }

        let text = "The fix that landed for the sticky note tabs looks pretty good."
        let segments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: text,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]
        let observer = TailCheckObserver(judge: ExplodingJudge())
        let paste = observer.afterFinalText(text, segments: segments, rawText: text)
        reporter.record("a clean, non-triggering take never calls the judge (no crash)", true)
        reporter.record("paste stays unchanged", paste == text)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "judge-only-when-triggered"))
        return reporter.passed
    }

    // MARK: - hud-flag-only (2026-10-06 scope addition, part C)
    //
    // Red today, traced to `TailCheck.trigger`'s `[]` stub: the "should flag" scenario never
    // reaches the judge or the presenter at all, so the one case that should show the flag doesn't.
    // The "must never flag" scenarios and the paste-byte-identical checks are green in every case,
    // including today, because nothing in this phase ever edits the paste by construction.

    private static func runHudFlagOnly() -> Bool {
        print("=== ViddyDictate tailcheck — hud-flag-only arm ===")
        let reporter = SelfTestReporter()

        final class SpyPresenter: TailCheckFlagPresenting {
            var calls: [String] = []
            func showFlag(suspectedSuffix: String) { calls.append(suspectedSuffix) }
        }
        final class FixedJudge: TailJudge {
            let answer: TailCheck.JudgeAnswer?
            init(_ answer: TailCheck.JudgeAnswer?) { self.answer = answer }
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                completion(.success(answer))
            }
        }

        let triggeringText = "I approve the plan for Monday and the budget we discussed. Thank you."
        let triggeringSegments = [
            TailCheck.Segment(start: 0.0, end: 5.0,
                              rawText: "I approve the plan for Monday and the budget we discussed.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 6.5, end: 7.0, rawText: "Thank you.",
                              noSpeechProb: 0.3, avgLogprob: -0.3, compressionRatio: 1.0),
        ]
        let cleanText = "The fix that landed for the sticky note tabs looks pretty good."
        let cleanSegments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: cleanText,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]

        struct Scenario { let label: String; let text: String; let segments: [TailCheck.Segment]
                          let judgeAnswer: TailCheck.JudgeAnswer?; let wantFlag: Bool }
        let scenarios: [Scenario] = [
            Scenario(label: "no trigger", text: cleanText, segments: cleanSegments,
                    judgeAnswer: .junk(" anything"), wantFlag: false),
            Scenario(label: "triggered, judge clean", text: triggeringText, segments: triggeringSegments,
                    judgeAnswer: .clean, wantFlag: false),
            Scenario(label: "triggered, judge junk, acceptCut would accept", text: triggeringText,
                    segments: triggeringSegments, judgeAnswer: .junk(" Thank you."), wantFlag: true),
        ]

        for s in scenarios {
            let presenter = SpyPresenter()
            let observer = TailCheckObserver(judge: FixedJudge(s.judgeAnswer), presenter: presenter)
            let paste = observer.afterFinalText(s.text, segments: s.segments, rawText: s.text)
            reporter.record("[\(s.label)] paste is byte-identical to the input", paste == s.text)
            reporter.record("[\(s.label)] presenter called exactly when it should (want=\(s.wantFlag))",
                            (presenter.calls.count == 1) == s.wantFlag, "calls=\(presenter.calls.count)")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hud-flag-only"))
        return reporter.passed
    }

    // MARK: - judge-local-only (vdtpwg, part A)
    //
    // Not stub-caused red -- a GUARDRAIL, explicit in the manifest brief: `LocalRouteTailJudge.judge()`
    // never reads `transport` regardless of what `routeResolver` answers, so dictation text cannot
    // leave the Mac on a non-local/off resolution TODAY, and must stay true once a later I3 link makes
    // the local branch real. Each scenario below gets a transport whose every closure `fatalError`s if
    // called at all, so a regression crashes the arm rather than silently passing.

    private static func runJudgeLocalOnly() -> Bool {
        print("=== ViddyDictate tailcheck — judge-local-only arm ===")
        let reporter = SelfTestReporter()

        func explodingTransport() -> LocalChatTransport {
            LocalChatTransport(
                sendLMStudio: { _, _ in fatalError("judge-local-only: must not call sendLMStudio") },
                prepareLMStudio: { _, _ in fatalError("judge-local-only: must not call prepareLMStudio") },
                unloadLMStudio: { _ in },
                prepareOllama: { _, _, _ in fatalError("judge-local-only: must not call prepareOllama") },
                chatOllama: { _, _, _, _, _ in fatalError("judge-local-only: must not call chatOllama") },
                unloadOllama: { _ in },
                keepAliveSeconds: { 0 },
                beginRequest: { _ in },
                endRequest: { _ in })
        }

        struct Scenario { let label: String; let resolution: LLMRouteResolution }
        let scenarios: [Scenario] = [
            Scenario(label: "resolves to claude", resolution: .pinned(.claude("claude-x"))),
            Scenario(label: "resolves to codex", resolution: .pinned(.codex("codex-x"))),
            Scenario(label: "resolves to nothing (off)",
                    resolution: .off(reason: "no provider configured")),
        ]

        for s in scenarios {
            let judge = LocalRouteTailJudge(routeResolver: { s.resolution }, transport: explodingTransport())
            var captured: Result<TailCheck.JudgeAnswer?, Error>?
            judge.judge(context: "a sentence.", tail: "tail words", timeoutMs: 400) { captured = $0 }
            switch captured {
            case .some(.success(let answer)):
                reporter.record("[\(s.label)] answers .success(nil) with zero transport calls",
                                answer == nil, "got=\(String(describing: answer))")
            default:
                reporter.record("[\(s.label)] answers .success(nil) with zero transport calls", false,
                                "got=\(String(describing: captured))")
            }
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "judge-local-only"))
        return reporter.passed
    }

    // MARK: - judge-request-shape (vdtpwg, part A)
    //
    // Red today, traced to `LocalRouteTailJudge.judge()`'s `.success(nil)` stub line: the stub never
    // reads `transport` at all, so NONE of the scenarios below ever reach the fake LOCAL transport --
    // every "want" is the real I3 contract this arm pins for the link that replaces the stub.

    private static func runJudgeRequestShape() -> Bool {
        print("=== ViddyDictate tailcheck — judge-request-shape arm ===")
        let reporter = SelfTestReporter()

        struct Scenario {
            let label: String
            let respond: () -> (Data?, URLResponse?, Error?)
            let wantAnswer: TailCheck.JudgeAnswer??   // nil (outer) means "want .failure"
        }

        func httpOK(_ body: String) -> (Data?, URLResponse?, Error?) {
            let response: URLResponse? = HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)
            return (body.data(using: .utf8), response, nil)
        }

        let context = "Sentence one is here. Sentence two follows it."
        let tail = "primarily primarily primarily primarily primarily primarily"

        let scenarios: [Scenario] = [
            Scenario(label: "well-formed junk, suffix ends the tail",
                     respond: { httpOK(#"{"tail":"junk","junk_suffix":"primarily"}"#) },
                     wantAnswer: .some(.junk("primarily"))),
            Scenario(label: "malformed JSON",
                     respond: { httpOK("not json") },
                     wantAnswer: .some(nil)),
            Scenario(label: "empty body",
                     respond: { httpOK("") },
                     wantAnswer: .some(nil)),
            Scenario(label: "well-formed junk whose suffix is NOT in the tail",
                     respond: { httpOK(#"{"tail":"junk","junk_suffix":"something else entirely"}"#) },
                     wantAnswer: .some(nil)),
            Scenario(label: "transport error",
                     respond: { (nil, nil, NSError(domain: "tailcheck-selftest-fake", code: 1)) },
                     wantAnswer: nil),
        ]

        for s in scenarios {
            var capturedRequests: [URLRequest] = []
            let transport = LocalChatTransport(
                sendLMStudio: { request, completion in
                    capturedRequests.append(request)
                    let (data, response, error) = s.respond()
                    completion(data, response, error)
                },
                prepareLMStudio: { _, _ in (ModelManager.ReadinessResult.ready, false) },
                unloadLMStudio: { _ in },
                prepareOllama: { _, _, _ in
                    fatalError("judge-request-shape: this scenario resolves LM Studio, not Ollama")
                },
                chatOllama: { _, _, _, _, _ in
                    fatalError("judge-request-shape: this scenario resolves LM Studio, not Ollama")
                },
                unloadOllama: { _ in },
                keepAliveSeconds: { 0 },
                beginRequest: { _ in },
                endRequest: { _ in })

            let judge = LocalRouteTailJudge(
                routeResolver: { .pinned(.local("fake-local-tailcheck-model")) }, transport: transport)

            var captured: Result<TailCheck.JudgeAnswer?, Error>?
            judge.judge(context: context, tail: tail, timeoutMs: 400) { captured = $0 }

            reporter.record("[\(s.label)] exactly one request was sent to the fake LOCAL transport",
                            capturedRequests.count == 1, "calls=\(capturedRequests.count)")
            if let request = capturedRequests.first, let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let messages = json["messages"] as? [[String: Any]] {
                let userContent = messages
                    .compactMap { ($0["role"] as? String) == "user" ? $0["content"] as? String : nil }
                    .joined()
                reporter.record("[\(s.label)] the user content carries the bounded context",
                                userContent.contains(context))
                reporter.record("[\(s.label)] the user content carries the tail",
                                userContent.contains(tail))
                let remainder = userContent
                    .replacingOccurrences(of: context, with: "")
                    .replacingOccurrences(of: tail, with: "")
                reporter.record("[\(s.label)] the user content carries no other text",
                                remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                "content=\(userContent)")
            } else {
                reporter.record("[\(s.label)] the request body is a parseable OpenAI-shaped chat body", false)
                reporter.record("[\(s.label)] the user content carries the bounded context", false)
                reporter.record("[\(s.label)] the user content carries the tail", false)
                reporter.record("[\(s.label)] the user content carries no other text", false)
            }

            switch (captured, s.wantAnswer) {
            case (.some(.success(let got)), .some(let want)):
                reporter.record("[\(s.label)] answer matches the real contract", got == want,
                                "want=\(String(describing: want)) got=\(String(describing: got))")
            case (.some(.failure), .none):
                reporter.record("[\(s.label)] answer matches the real contract (expected .failure)", true)
            default:
                reporter.record("[\(s.label)] answer matches the real contract", false,
                                "want=\(String(describing: s.wantAnswer)) got=\(String(describing: captured))")
            }
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "judge-request-shape"))
        return reporter.passed
    }

    // MARK: - judge-timeout-pinned (vdtpwg, part B)
    //
    // Not stub-caused red -- closes `vdtpga-GQ.md` hole H2 ("the literal `400` ms production default
    // is never pinned by name in any arm... a silent edit of that default would pass every arm
    // today"). Both checks are green today: `TailCheckObserver.defaultJudgeTimeoutMs` and the hard-
    // timeout wrapper it feeds are real, pure plumbing, so this stands as a guardrail from today
    // onward -- a silent edit of the named constant is now caught by name, not invisible.

    private static func runJudgeTimeoutPinned() -> Bool {
        print("=== ViddyDictate tailcheck — judge-timeout-pinned arm ===")
        let reporter = SelfTestReporter()

        reporter.record("the named default is 400 ms",
                        TailCheckObserver.defaultJudgeTimeoutMs == 400,
                        "got=\(TailCheckObserver.defaultJudgeTimeoutMs)")
        reporter.record(
            "a default-initialized TailCheckObserver uses that exact named default, not a drifted copy",
            TailCheckObserver().judgeTimeoutMs == TailCheckObserver.defaultJudgeTimeoutMs,
            "got=\(TailCheckObserver().judgeTimeoutMs)")

        final class SlowJudge: TailJudge {
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    completion(.success(.junk(" done")))
                }
            }
        }

        let tailText = Array(repeating: "primarily", count: 8).joined(separator: " ")
        let text = "I approve the plan. " + tailText
        let segments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: "I approve the plan.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 5.1, end: 12.0, rawText: tailText,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]

        var observedLines: [String] = []
        let observer = TailCheckObserver(sink: { observedLines.append($0) }, judge: SlowJudge())
        let t0 = DispatchTime.now()
        let paste = observer.afterFinalText(text, segments: segments, rawText: text)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0

        reporter.record("a judge slower than the default 400 ms times out well under 1 s of real waiting",
                        elapsedMs < 1_000, "elapsed=\(elapsedMs)ms")
        reporter.record("the paste stays unchanged even though the trigger fired", paste == text)
        if let line = observedLines.first, let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            reporter.record("exactly one observe record was logged, with verdict=timeout",
                            observedLines.count == 1 && (obj["verdict"] as? String) == "timeout",
                            "record=\(obj)")
        } else {
            reporter.record("exactly one observe record was logged, with verdict=timeout", false,
                            "no decodable record (lines=\(observedLines.count))")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "judge-timeout-pinned"))
        return reporter.passed
    }

    // MARK: - daemon-segments-decoded (vdtpwg, part C)
    //
    // Red today, traced to `DaemonClient.parseSegments`'s `[]` stub line: a NEW-shaped response with
    // the I1 additive fields must decode to the matching `[TailCheck.Segment]`, including the
    // documented safe value for a missing/null optional metric -- the stub ignores the input entirely.
    // The OLD-shaped check is a standing guardrail (already true against `[]`, must stay true once real).

    private static func runDaemonSegmentsDecoded() -> Bool {
        print("=== ViddyDictate tailcheck — daemon-segments-decoded arm ===")
        let reporter = SelfTestReporter()

        let newBody: [String: Any] = [
            "transcript": "Checking in now. primarily primarily",
            "raw_transcript": "Checking in now. primarily primarily",
            "model": "mlx-community/whisper-large-v3-turbo",
            "parameters": ["audio_duration_s": 12.0],
            "segments": [
                ["start": 0.0, "end": 5.0, "effective_end": 5.0, "text": "Checking in now.",
                 "kept": true, "drop_reason": NSNull(), "raw_text": "Checking in now.",
                 "no_speech_prob": 0.05, "avg_logprob": -0.2, "compression_ratio": 1.0],
                ["start": 5.1, "end": 12.0, "effective_end": 12.0, "text": "primarily primarily",
                 "kept": true, "drop_reason": NSNull(),
                 "raw_text": "primarily primarily primarily primarily",
                 "no_speech_prob": NSNull(), "avg_logprob": NSNull(), "compression_ratio": NSNull()],
            ],
        ]

        let decodedNew = DaemonClient.parseSegments(from: newBody)
        reporter.record("a NEW-shaped response decodes one TailCheck.Segment per input segment",
                        decodedNew.count == 2, "got=\(decodedNew.count)")
        if decodedNew.count == 2 {
            reporter.record("segment[0] keeps start/end/raw_text and its real metrics",
                            decodedNew[0].start == 0.0 && decodedNew[0].end == 5.0
                                && decodedNew[0].rawText == "Checking in now."
                                && decodedNew[0].noSpeechProb == 0.05
                                && decodedNew[0].avgLogprob == -0.2
                                && decodedNew[0].compressionRatio == 1.0)
            reporter.record(
                "segment[1]'s raw_text is the PRE-collapse decode, distinct from the shortened 'text' field",
                decodedNew[1].rawText == "primarily primarily primarily primarily")
            let def = TailCheck.missingSegmentMetricDefault
            reporter.record("segment[1]'s missing/null metrics decode to the documented safe default",
                            decodedNew[1].noSpeechProb == def && decodedNew[1].avgLogprob == def
                                && decodedNew[1].compressionRatio == def)
        } else {
            reporter.record("segment[0] keeps start/end/raw_text and its real metrics", false)
            reporter.record(
                "segment[1]'s raw_text is the PRE-collapse decode, distinct from the shortened 'text' field",
                false)
            reporter.record("segment[1]'s missing/null metrics decode to the documented safe default", false)
        }

        let oldBody: [String: Any] = [
            "transcript": "Checking in now.",
            "raw_transcript": "Checking in now.",
            "model": "mlx-community/whisper-large-v3-turbo",
            "parameters": ["audio_duration_s": 5.0],
        ]
        let decodedOld = DaemonClient.parseSegments(from: oldBody)
        reporter.record("an OLD-shaped response with no 'segments' key decodes to [] without error",
                        decodedOld.isEmpty, "got=\(decodedOld.count)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "daemon-segments-decoded"))
        return reporter.passed
    }

    // MARK: - hook-after-paste (vdtpwg, part D)
    //
    // The "fires within 100 ms" check is a standing guardrail: a no-op always returns before any
    // caller-visible deadline, including a deliberately tiny one, and must keep holding once a real,
    // dispatch-and-return-fast implementation replaces `NullTailCheckDictationHook`. The "ran off the
    // main thread, after the hook returned" check is red today, traced to `NullTailCheckDictationHook`'s
    // "ignores `observer` entirely and does nothing" stub line: the wrapped `TailCheckObserver` (with
    // its slow judge) never runs at all.

    private static func runHookAfterPaste() -> Bool {
        print("=== ViddyDictate tailcheck — hook-after-paste arm ===")
        let reporter = SelfTestReporter()

        final class SlowJudge: TailJudge {
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                Thread.sleep(forTimeInterval: 1.0)
                completion(.success(.clean))
            }
        }

        let tailText = Array(repeating: "primarily", count: 8).joined(separator: " ")
        let text = "I approve the plan. " + tailText
        let segments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: "I approve the plan.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 5.1, end: 12.0, rawText: tailText,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]

        let lock = NSLock()
        var sinkCalls = 0
        let observer = TailCheckObserver(
            sink: { _ in lock.lock(); sinkCalls += 1; lock.unlock() },
            judge: SlowJudge(), judgeTimeoutMs: 5_000)
        let hook: TailCheckDictationHook = NullTailCheckDictationHook(observer: observer)

        let t0 = DispatchTime.now()
        hook.call(finalText: text, rawText: text, segments: segments, cleanupLevel: TailCheck.cleanupLevelNone)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0

        reporter.record("the paste/delivery callback (the hook call itself) returns within 100 ms",
                        elapsedMs < 100, "elapsed=\(elapsedMs)ms")

        Thread.sleep(forTimeInterval: 1.5)
        lock.lock()
        let finalSinkCalls = sinkCalls
        lock.unlock()
        reporter.record("the observe+judge work ran exactly once, after the hook returned",
                        finalSinkCalls == 1, "sinkCalls=\(finalSinkCalls)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hook-after-paste"))
        return reporter.passed
    }

    // MARK: - hook-wired (vdtpwg, part D)
    //
    // Red today, traced to "not yet called from DictationController": grades the production call
    // site the same way `LockedDeliverySelfTest` already grades `deliverLocked` -- by slicing the real
    // `DictationController.swift` source text, never by instantiating the real, stateful controller
    // (no AX, no pasteboard, no HUD window is ever touched by this arm). `finalize(delivered:raw:
    // cleaned:mode:...)` is the one choke point every delivered dictation passes through exactly once
    // (`deliver`'s three branches -- raw, cleanup success, cleanup fallback -- each call it once); a
    // later I3 link should put the hook call there, not duplicated across `deliver`'s three call
    // sites, so "exactly once per delivered dictation" falls out of `finalize` running exactly once
    // rather than needing its own counter.

    private static func runHookWired() -> Bool {
        print("=== ViddyDictate tailcheck — hook-wired arm ===")
        let reporter = SelfTestReporter()

        let source = NotesProbe.sourceDictationController
        let finalizeSlice = NotesProbe.sourceSlice(
            source, from: "private func finalize(delivered: String",
            to: "private func deliverPushToTalk(delivered: String")

        reporter.record("finalize(...) is gated behind Settings.tailCheckEnabled before calling the hook",
                        finalizeSlice.contains("Settings.tailCheckEnabled"), "")
        reporter.record("finalize(...) calls the tail-check hook's call(finalText:...) contract",
                        finalizeSlice.contains(".call(finalText:"), "")
        let callSiteCount = NotesProbe.countOccurrences(of: ".call(finalText:", in: finalizeSlice)
        reporter.record(
            "the hook is called exactly once per delivered dictation (one call site in finalize)",
            callSiteCount == 1, "occurrences=\(callSiteCount)")
        reporter.record("finalize(...) passes the final text, raw text, segments, and cleanup level",
                        finalizeSlice.contains("rawText:") && finalizeSlice.contains("segments:")
                            && finalizeSlice.contains("cleanupLevel:"), "")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hook-wired"))
        return reporter.passed
    }

    // MARK: - hud-flag-real (vdtpwg, part C)
    //
    // Red today, traced to `RealTailCheckFlagPresenter.showFlag`'s "does nothing" stub line: the sink
    // is never called at all, so none of the checks below -- which describe the real I3 contract --
    // can pass yet. Reuses `hud-flag-only`'s own proven "triggered, judge junk, acceptCut would
    // accept" fixture rather than inventing a new one.

    private static func runHudFlagReal() -> Bool {
        print("=== ViddyDictate tailcheck — hud-flag-real arm ===")
        let reporter = SelfTestReporter()

        final class FixedJudge: TailJudge {
            let answer: TailCheck.JudgeAnswer?
            init(_ answer: TailCheck.JudgeAnswer?) { self.answer = answer }
            func judge(context: String, tail: String, timeoutMs: Int,
                      completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void) {
                completion(.success(answer))
            }
        }

        let triggeringText = "I approve the plan for Monday and the budget we discussed. Thank you."
        let triggeringSegments = [
            TailCheck.Segment(start: 0.0, end: 5.0,
                              rawText: "I approve the plan for Monday and the budget we discussed.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 6.5, end: 7.0, rawText: "Thank you.",
                              noSpeechProb: 0.3, avgLogprob: -0.3, compressionRatio: 1.0),
        ]

        let lock = NSLock()
        var sinkCalls: [String] = []
        var sinkCallsOnMain = true
        let presenter = RealTailCheckFlagPresenter(sink: { suffix in
            lock.lock()
            sinkCalls.append(suffix)
            sinkCallsOnMain = sinkCallsOnMain && Thread.isMainThread
            lock.unlock()
        })

        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        let observer = TailCheckObserver(judge: FixedJudge(.junk(" Thank you.")), presenter: presenter)
        let paste = observer.afterFinalText(
            triggeringText, segments: triggeringSegments, rawText: triggeringText)

        reporter.record("paste is byte-identical to the input even when the real presenter is wired",
                        paste == triggeringText)
        reporter.record("the real presenter handed the display sink exactly one flag",
                        sinkCalls.count == 1, "calls=\(sinkCalls.count)")
        if let flagged = sinkCalls.first {
            reporter.record(
                "the flagged suffix is truncated to at most RealTailCheckFlagPresenter.maxDisplaySuffixLength",
                flagged.count <= RealTailCheckFlagPresenter.maxDisplaySuffixLength,
                "len=\(flagged.count) cap=\(RealTailCheckFlagPresenter.maxDisplaySuffixLength)")
        } else {
            reporter.record(
                "the flagged suffix is truncated to at most RealTailCheckFlagPresenter.maxDisplaySuffixLength",
                false, "no flag was handed to the sink")
        }
        reporter.record("every sink call happened on the main thread", sinkCallsOnMain)
        reporter.record("the system pasteboard's changeCount is unchanged",
                        pasteboard.changeCount == changeCountBefore,
                        "before=\(changeCountBefore) after=\(pasteboard.changeCount)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hud-flag-real"))
        return reporter.passed
    }
}
