import AppKit
import Darwin
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

    /// vdtpwg3 repair (point 1, bounded egress directive): a tiny, self-contained canary mode, checked
    /// BEFORE the normal `--only` dispatch so it never needs a valid arm value. See
    /// `NetworkDenialSandbox`'s own doc comment for what it proves and why.
    private static let networkCanaryFlag = "--tailcheck-network-canary"
    /// vdtpwg3 repair (point 1): marks a child process already running INSIDE the deny-network
    /// sandbox-exec profile, so it runs the real, contained arm logic directly instead of re-wrapping
    /// itself (which would recurse forever).
    static let networkDeniedChildFlag = "--network-denied-child"

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains(networkCanaryFlag) {
            print("errno=\(NetworkDenialSandbox.rawConnectErrno())")
            return 0
        }
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
        case .judgeLocalOnly:         ok = runJudgeLocalOnly(arguments: arguments)
        case .judgeRequestShape:      ok = runJudgeRequestShape(arguments: arguments)
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
        // vdtpwg4 repair (JW3's real-gate-environment measurement): [100,150) was calibrated against
        // this LOCAL environment's own scheduling only (~104-110ms here). JW3 measured the SAME real
        // reference, over 5 repeats, INSIDE the actual grading environment (a sandboxed codex judge
        // process) at 274.9-299.3ms -- nearly 3x this environment's wait, from that environment's own
        // Seatbelt/scheduling overhead, not from any drift in the implementation. [100,150) therefore
        // failed the required-green reference in the environment that actually grades it. The named
        // `timeoutMs + 250ms` bypass this band exists to catch lands at a fixed ~350ms regardless of
        // environment (it is `timeoutMs` plus a hard-coded constant, not itself environment-sensitive).
        // Re-measured here (5 repeats, this link): 107.6-110.0ms. Taking JW3's real-environment ceiling
        // (299.3ms) as the authoritative one (the grading environment, not this one, is what must pass),
        // the band below widens to [100,340): ~40.7ms of real headroom above JW3's measured ceiling, and
        // still a clear ~10ms gap below the 350ms bypass -- both real margins, not a guessed tight value,
        // and still measured from OUTSIDE (`t0`/`DispatchTime.now()` wrap the arm's own call), per the
        // addendum's directive 2 -- a hard-timeout implementation cannot game this by reporting its own,
        // different elapsed time.
        reporter.record("the hard timeout bounds the wait to a tight band around the 100ms budget",
                        elapsedMs >= 100 && elapsedMs < 340, "elapsed=\(elapsedMs)ms")

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

    // MARK: - NetworkDenialSandbox (vdtpwg3 repair, point 1)
    //
    // 2026-10-07 addendum from the lane orchestrator: close the egress hole with an OS-level network
    // deny for the graded test process, not another runtime assertion -- `sandbox-exec` with a
    // deny-network profile around `judge-local-only`/`judge-request-shape`'s own invocation, so the
    // injected transport is the ONLY path a request can physically reach and a second, unobserved
    // `URLSession.shared` call cannot connect at all, full stop, no spy needed. This mirrors the
    // existing `Tools/CodexContainmentRunner.swift` precedent (`sandbox-exec -p <policy> <executable>
    // <args>`, run as a child process and its result captured) -- a DIFFERENT compiled target, so its
    // code is not reusable here, but the pattern is. Scope, per the addendum: bounded, not unbounded-
    // adversarial -- this closes the egress hole against any REAL extra network path (the data
    // physically cannot leave the Mac), not against every non-network side channel a judge could
    // invent (mach IPC, a Unix-domain socket to a co-resident daemon, writing to a shared file another
    // process reads) -- noted as a residual risk in this chain's GW3 report, not pursued here.
    private enum NetworkDenialSandbox {
        static let sandboxExec = "/usr/bin/sandbox-exec"
        /// The simplest correct deny-network profile: everything else stays allowed (this process must
        /// still read its own binary, fork/exec itself for the canary, write its observe log under a
        /// scratch HOME, etc. -- all orthogonal to egress), and only the `network*` operation family
        /// (outbound, inbound, bind -- TCP, UDP, and Unix-domain alike) is denied at the kernel/Seatbelt
        /// level, for every socket in the process, regardless of which API opened it.
        static let denyNetworkProfile = "(version 1)\n(allow default)\n(deny network*)\n"

        /// A raw BSD `connect()` to loopback port 1 (nothing listens there), classified by `errno`:
        /// `EPERM` means Seatbelt denied the attempt before it ever reached the network; any other
        /// errno (typically `ECONNREFUSED`) means the OS actually tried and the far end refused. This
        /// needs no real listener and no real destination -- the FAILURE MODE is the proof, not whether
        /// the connection succeeds. Used both unsandboxed (must NOT be `EPERM`: the differential control)
        /// and inside the sandboxed child via `--tailcheck-network-canary` (must BE `EPERM`: the proof
        /// the deny actually fires, never merely assumed -- the same "confirm the deny actually fires"
        /// discipline this codebase already applies to the Private-vault path denies).
        static func rawConnectErrno(port: UInt16 = 1) -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return errno }
            defer { Darwin.close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return rc == 0 ? 0 : errno
        }

        /// This test binary's own absolute executable path, so the wrapper can re-exec itself under
        /// `sandbox-exec` (same pattern `CodexContainmentRunner`'s selftest uses to sandbox a fixture
        /// binary, except the "fixture" here is this SAME binary with an extra marker flag).
        static func selfExecutablePath() -> String? {
            var size: UInt32 = 0
            _NSGetExecutablePath(nil, &size)
            var buffer = [Int8](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
            return String(cString: buffer)
        }

        struct Result { let status: Int32; let stdout: String; let stderr: String }

        /// Spawn `exePath arguments` under `sandbox-exec -p denyNetworkProfile`. `(allow default)` means
        /// nothing besides networking is restricted -- the child still reads its own binary/frameworks,
        /// forks/execs itself for the canary, and writes its scratch-HOME observe log exactly as an
        /// unsandboxed run would; only `(deny network*)` changes anything observable.
        static func runSandboxed(exePath: String, arguments: [String], timeoutSeconds: Double = 20) -> Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sandboxExec)
            process.arguments = ["-p", denyNetworkProfile, exePath] + arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                return Result(status: -1, stdout: "", stderr: "spawn failed: \(error)")
            }
            let deadline = DispatchTime.now() + timeoutSeconds
            let watchdog = DispatchQueue(label: "tailcheck-selftest-sandbox-watchdog")
            watchdog.asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return Result(status: process.terminationStatus,
                         stdout: String(data: outData, encoding: .utf8) ?? "",
                         stderr: String(data: errData, encoding: .utf8) ?? "")
        }

        /// Run `label`'s real, contained arm logic (`contained()`) inside the deny-network sandbox,
        /// after first proving -- with the loopback-connect differential above -- that the sandbox
        /// actually denies network for THIS binary on THIS machine right now, rather than assuming a
        /// seatbelt profile that silently failed to apply (exactly the `rg`-shim-shaped failure mode
        /// `agents-mac.md` warns about: a guard that looks present but never fires). `contained()` is
        /// reached by re-invoking this same executable with `--only <arm> --network-denied-child`, so
        /// everything the arm already does (loading the fixture, driving the stub/real judge) runs for
        /// real inside the sandbox, not in a parallel/simulated copy.
        ///
        /// vdtpwg4 repair (master ruling item iii): JW3 found this re-exec hit
        /// `sandbox-exec: sandbox_apply: Operation not permitted` (child status 71) when the OUTER
        /// grading process is ITSELF already sandboxed (a sandboxed codex judge process). The cause is
        /// not which API applies the second profile -- `runSandboxed` below already spawns the
        /// `/usr/bin/sandbox-exec` BINARY as a child process, never the in-process `sandbox_init`/
        /// `sandbox_apply` C API -- it is that Seatbelt profiles are inherited across fork/exec: a
        /// child spawned from an already-sandboxed process is itself already sandboxed before
        /// `sandbox-exec` ever runs, so `sandbox-exec`'s OWN internal `sandbox_apply()` call (needed to
        /// lay down ITS new profile before exec'ing the target) is the exact nested self-resandboxing
        /// the kernel refuses -- a child process invoking the binary cannot route around a kernel
        /// invariant that applies to the process tree, not to which call site asks. The fix is to never
        /// attempt the nested call in the first place: the SAME loopback-connect differential this
        /// wrapper already uses to prove its OWN sandbox fires also detects, with zero extra syscalls,
        /// whether the AMBIENT process is already network-denied (errno == EPERM with no wrapping at
        /// all) -- i.e. already running inside an outer sandbox that denies network for this process.
        /// When that is true, layering a second profile is both impossible (the kernel refusal above)
        /// and unnecessary (the arm's real requirement -- this process cannot physically reach the
        /// network -- already holds ambiently), so this arm runs `contained()` directly, in-process,
        /// with no re-exec and no `sandbox-exec` spawn at all. Only when the ambient process is NOT
        /// already network-denied does it fall through to the original self-wrapping path below.
        static func runArmDenyingNetwork(arm: String, label: String, contained: () -> Bool) -> Bool {
            print("=== ViddyDictate tailcheck — \(label) arm (OS-level network-denial wrapper) ===")
            let reporter = SelfTestReporter()

            let ambientErrno = rawConnectErrno()
            if ambientErrno == EPERM {
                reporter.record(
                    "ambient control: this process is ALREADY confined by an outer network-denial "
                        + "sandbox (errno == EPERM on a raw loopback connect with no wrapping at all) -- "
                        + "layering a second sandbox_apply would be the exact nested self-resandboxing "
                        + "the kernel refuses regardless of which call site asks, so this arm runs "
                        + "directly in-process under the ambient confinement instead of spawning its own",
                    true, "errno=\(ambientErrno)")
                reporter.record(
                    "[\(label)] ran to completion and passed every assertion under the AMBIENT "
                        + "deny-network confinement, where the injected transport is the only path any "
                        + "request could physically reach",
                    contained(), "")
                print("\n=== RESULT ===")
                print(reporter.summaryLine(prefix: label))
                return reporter.passed
            }
            reporter.record(
                "unsandboxed control: a raw loopback TCP connect is NOT denied by Seatbelt (errno != EPERM)",
                true, "errno=\(ambientErrno)")

            guard let exePath = selfExecutablePath() else {
                reporter.record("resolved this test binary's own absolute executable path for re-exec", false)
                print("\n=== RESULT ===")
                print(reporter.summaryLine(prefix: label))
                return reporter.passed
            }

            let canary = runSandboxed(exePath: exePath, arguments: ["--tailcheck-selftest", "--only", arm,
                                                                     TailCheckSelfTest.networkCanaryFlag])
            reporter.record(
                "sandboxed control: the SAME raw loopback TCP connect, run under sandbox-exec's deny-"
                    + "network profile, IS denied at the OS level (errno == EPERM) -- proves the deny "
                    + "actually fires for this binary on this machine, not merely assumed",
                canary.stdout.contains("errno=\(EPERM)"),
                "stdout=\(canary.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) status=\(canary.status)")

            let child = runSandboxed(exePath: exePath, arguments: ["--tailcheck-selftest", "--only", arm,
                                                                    TailCheckSelfTest.networkDeniedChildFlag])
            if !child.stdout.isEmpty { print(child.stdout) }
            if !child.stderr.isEmpty { FileHandle.standardError.write(Data(child.stderr.utf8)) }
            reporter.record(
                "[\(label)] ran to completion and passed every assertion INSIDE the deny-network "
                    + "sandbox, where the injected transport is the only path any request could "
                    + "physically reach",
                child.status == 0, "exit=\(child.status)")

            print("\n=== RESULT ===")
            print(reporter.summaryLine(prefix: label))
            return reporter.passed
        }
    }

    // MARK: - judge-local-only (vdtpwg, part A)
    //
    // Not stub-caused red -- a GUARDRAIL, explicit in the manifest brief: `LocalRouteTailJudge.judge()`
    // never reads `transport` regardless of what `routeResolver` answers, so dictation text cannot
    // leave the Mac on a non-local/off resolution TODAY, and must stay true once a later I3 link makes
    // the local branch real. Each scenario below gets a transport whose every closure `fatalError`s if
    // called at all, so a regression crashes the arm rather than silently passing.
    //
    // vdtpwg2 repair (JW hole 1, construction-time half): a runtime spy over an injected transport
    // cannot rule out a FUTURE `LocalRouteTailJudge` that reaches the network some OTHER way -- a new
    // call site that forgets to inject anything. The fix is at the type level: `transport` has no
    // default (see `TailCheck.swift`), so the compiler itself refuses `LocalRouteTailJudge()` with no
    // transport argument at ANY call site, construction-time, not a runtime observation. The two source
    // checks below pin that half of the contract directly (the compiler already proves the other half
    // -- that this file keeps compiling -- just by building at all): no default slipped back in, and
    // the one production call site that needs a real transport by default (`TailCheckObserver`'s own
    // `judge` parameter) still names `.live` explicitly rather than leaning on a removed default.
    //
    // vdtpwg3 repair (JW2 hole 1, bounded per the 2026-10-07 addendum): the source-level/spy checks
    // above rule out a known transport being bypassed, but cannot rule out a FUTURE real `judge()` body
    // making an UNOBSERVED second request (e.g. `URLSession.shared`) alongside the injected transport.
    // `runJudgeLocalOnly(arguments:)` below is the real entry point: outside the sandboxed child it
    // wraps this method in an OS-level `sandbox-exec` deny-network profile (`NetworkDenialSandbox`), so
    // a second real request cannot physically connect, full stop. This method itself is now the
    // CONTAINED body, run for real both directly (fast local iteration) and inside the sandboxed child.

    private static func runJudgeLocalOnly() -> Bool {
        print("=== ViddyDictate tailcheck — judge-local-only arm ===")
        let reporter = SelfTestReporter()

        // Sliced through the END of the init's parameter list (the first line of its body), so this
        // covers both the `transport` PROPERTY declaration (which never has a default, mutated or not --
        // checking only for that would be vacuous) and the init's own PARAMETER, which is the thing this
        // check must actually pin: no "LocalChatTransport = ..." default anywhere in this span.
        let judgeInitSlice = NotesProbe.sourceSlice(
            NotesProbe.sourceTailCheck, from: "final class LocalRouteTailJudge",
            to: "self.routeResolver = routeResolver")
        reporter.record(
            "LocalRouteTailJudge's own init has no default transport -- a bare LocalRouteTailJudge() "
                + "cannot compile, so a construction site can never silently inherit a network-capable "
                + "transport",
            !judgeInitSlice.contains("LocalChatTransport = "), judgeInitSlice)
        reporter.record(
            "the production call site (TailCheckObserver's own judge default) still names the real "
                + "live transport explicitly",
            NotesProbe.countOccurrences(
                of: "judge: TailJudge = LocalRouteTailJudge(transport: .live)",
                in: NotesProbe.sourceTailCheck) >= 1)

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

    /// The real entry point the manifest dispatches to. Inside the sandboxed child
    /// (`--network-denied-child` present), runs the contained body directly, for real, as the arm's
    /// own exit code; otherwise wraps it in `NetworkDenialSandbox`'s OS-level deny-network sandbox.
    private static func runJudgeLocalOnly(arguments: [String]) -> Bool {
        if arguments.contains(networkDeniedChildFlag) {
            return runJudgeLocalOnly()
        }
        return NetworkDenialSandbox.runArmDenyingNetwork(arm: Arm.judgeLocalOnly.rawValue, label: "judge-local-only",
                                                           contained: runJudgeLocalOnly)
    }

    /// vdtpwg3 repair (point 6): a plain word bank `judge-request-shape`/`daemon-segments-decoded` draw
    /// from at RUNTIME (`.randomElement()`, the system RNG) to build fixture context/tail/segment text,
    /// instead of a literal compile-time string. Ordinary nouns -- never anything resembling real
    /// dictation content -- so no implementation under test can contain a matching compile-time
    /// literal for any value this draws, and a value read off one run's output is wrong on the next.
    private enum RandomFixtureWords {
        static let bank = [
            "umbrella", "harbor", "canvas", "ledger", "orbit", "granite", "willow", "compass",
            "ember", "quartz", "lantern", "meadow", "cipher", "anchor", "ripple", "thicket",
            "beacon", "marble", "thistle", "copper", "driftwood", "satchel", "paddock", "kestrel",
        ]
    }

    // MARK: - judge-request-shape (vdtpwg, part A)
    //
    // Red today, traced to `LocalRouteTailJudge.judge()`'s `.success(nil)` stub line: the stub never
    // reads `transport` at all, so NONE of the scenarios below ever reach the fake LOCAL transport --
    // every "want" is the real I3 contract this arm pins for the link that replaces the stub.
    //
    // vdtpwg2 repair (JW hole 1, request-shape half + hole 6): each scenario now carries its OWN
    // distinct context/tail pair (a hard-coded single-case answer can no longer coincidentally satisfy
    // every scenario), the LM Studio and Ollama backends are BOTH covered (the design note names both
    // as valid transports, keyed off `resolution.bundle?.resolvedLocalBackend`), and "no other text" is
    // now an exact-equality check against exactly one `role == "user"` message -- not a
    // contains-then-strip-every-occurrence check that a duplicated fixture could satisfy by accident.

    /// Exactly one `role == "user"` message in an OpenAI-shaped chat body's `messages` array, or `nil`
    /// when there are zero, more than one, or the body does not parse -- never "the first one found" /
    /// "all of them joined", so a second stray user message is a visible failure, not silently ignored.
    private static func exactlyOneUserMessageContent(_ body: [String: Any]) -> String? {
        guard let messages = body["messages"] as? [[String: Any]] else { return nil }
        let userContents = messages.compactMap { ($0["role"] as? String) == "user" ? $0["content"] as? String : nil }
        return userContents.count == 1 ? userContents.first : nil
    }

    private static func runJudgeRequestShape() -> Bool {
        print("=== ViddyDictate tailcheck — judge-request-shape arm ===")
        let reporter = SelfTestReporter()

        enum Backend { case lmStudio, ollama }

        struct Scenario {
            let label: String
            let backend: Backend
            let context: String
            let tail: String
            let respondLMStudio: () -> (Data?, URLResponse?, Error?)
            let respondOllama: () -> (Data?, HTTPURLResponse?, Error?)
            let wantAnswer: TailCheck.JudgeAnswer??   // nil (outer) means "want .failure"
        }

        func httpOK(_ body: String) -> (Data?, URLResponse?, Error?) {
            let response: URLResponse? = HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)
            return (body.data(using: .utf8), response, nil)
        }
        func ollamaOK(_ body: String) -> (Data?, HTTPURLResponse?, Error?) {
            let response = HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:11434/api/chat")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)
            return (body.data(using: .utf8), response, nil)
        }
        func unreachable<T>(_ label: String) -> () -> T {
            { fatalError("judge-request-shape[\(label)]: wrong backend reached") }
        }

        // vdtpwg3 repair (point 6, JW2 hole 6): GW2 already made every scenario's context/tail
        // DISTINCT from every other, but all of it stayed literal and known at COMPILE TIME --
        // JW2's named violation is a judge body that switches on the seven exact literal strings.
        // These words are drawn via `RandomFixtureWords`'s own doc comment at RUNTIME, from the
        // system RNG, so no compile-time literal in any implementation can equal them; a fresh value
        // is drawn on every real invocation (direct or inside the sandboxed child alike), never a
        // fixed seed, so a value captured by reading one run's output is already wrong on the next.
        var usedWords: Set<String> = []
        func freshWord() -> String {
            let word = RandomFixtureWords.bank.filter { !usedWords.contains($0) }.randomElement()
                ?? RandomFixtureWords.bank.randomElement()!
            usedWords.insert(word)
            return word
        }
        func freshSentencePair(_ marker: String) -> String {
            "\(marker) \(freshWord()) meets \(freshWord()) today. The \(freshWord()) followed \(freshWord())."
        }
        let wellFormedWordLM = freshWord()
        let wellFormedWordOllama = freshWord()
        let suffixNotInTailWord = freshWord()

        let scenarios: [Scenario] = [
            Scenario(label: "LM Studio: well-formed junk, suffix ends the tail", backend: .lmStudio,
                     context: freshSentencePair("LM-1:"),
                     tail: Array(repeating: wellFormedWordLM, count: 6).joined(separator: " "),
                     respondLMStudio: { httpOK(#"{"tail":"junk","junk_suffix":"\#(wellFormedWordLM)"}"#) },
                     respondOllama: unreachable("LM Studio well-formed junk"),
                     wantAnswer: .some(.junk(wellFormedWordLM))),
            Scenario(label: "LM Studio: malformed JSON", backend: .lmStudio,
                     context: freshSentencePair("LM-2:"),
                     tail: "\(freshWord()) \(freshWord()) \(freshWord()) \(freshWord())",
                     respondLMStudio: { httpOK("not json") },
                     respondOllama: unreachable("LM Studio malformed JSON"),
                     wantAnswer: .some(nil)),
            Scenario(label: "LM Studio: empty body", backend: .lmStudio,
                     context: freshSentencePair("LM-3:"),
                     tail: "\(freshWord()) \(freshWord()) \(freshWord())",
                     respondLMStudio: { httpOK("") },
                     respondOllama: unreachable("LM Studio empty body"),
                     wantAnswer: .some(nil)),
            Scenario(label: "LM Studio: well-formed junk whose suffix is NOT in the tail", backend: .lmStudio,
                     context: freshSentencePair("LM-4:"),
                     tail: "\(freshWord()) \(freshWord()) \(freshWord())",
                     respondLMStudio: { httpOK(#"{"tail":"junk","junk_suffix":"\#(suffixNotInTailWord)"}"#) },
                     respondOllama: unreachable("LM Studio suffix not in tail"),
                     wantAnswer: .some(nil)),
            Scenario(label: "LM Studio: transport error", backend: .lmStudio,
                     context: freshSentencePair("LM-5:"),
                     tail: "\(freshWord()) \(freshWord()) \(freshWord())",
                     respondLMStudio: { (nil, nil, NSError(domain: "tailcheck-selftest-fake", code: 1)) },
                     respondOllama: unreachable("LM Studio transport error"),
                     wantAnswer: nil),
            Scenario(label: "Ollama: well-formed junk, suffix ends the tail", backend: .ollama,
                     context: freshSentencePair("Ollama-1:"),
                     tail: Array(repeating: wellFormedWordOllama, count: 4).joined(separator: " "),
                     respondLMStudio: unreachable("Ollama well-formed junk"),
                     respondOllama: { ollamaOK(#"{"tail":"junk","junk_suffix":"\#(wellFormedWordOllama)"}"#) },
                     wantAnswer: .some(.junk(wellFormedWordOllama))),
            Scenario(label: "Ollama: malformed JSON", backend: .ollama,
                     context: freshSentencePair("Ollama-2:"),
                     tail: "\(freshWord()) \(freshWord()) \(freshWord())",
                     respondLMStudio: unreachable("Ollama malformed JSON"),
                     respondOllama: { ollamaOK("not json") },
                     wantAnswer: .some(nil)),
        ]

        for s in scenarios {
            var capturedLMStudioRequests: [URLRequest] = []
            var capturedOllamaBodies: [[String: Any]] = []
            let transport = LocalChatTransport(
                sendLMStudio: { request, completion in
                    guard s.backend == .lmStudio else { fatalError("[\(s.label)]: must not reach LM Studio") }
                    capturedLMStudioRequests.append(request)
                    let (data, response, error) = s.respondLMStudio()
                    completion(data, response, error)
                },
                prepareLMStudio: { _, _ in (ModelManager.ReadinessResult.ready, false) },
                unloadLMStudio: { _ in },
                prepareOllama: { _, contextTokens, _ in
                    guard s.backend == .ollama else { fatalError("[\(s.label)]: must not reach Ollama") }
                    return (ModelManager.ReadinessResult.ready, contextTokens, false)
                },
                chatOllama: { body, _, _, _, _ in
                    guard s.backend == .ollama else { fatalError("[\(s.label)]: must not reach Ollama") }
                    capturedOllamaBodies.append(body)
                    let (data, response, error) = s.respondOllama()
                    return (data, response, error)
                },
                unloadOllama: { _ in },
                keepAliveSeconds: { 0 },
                beginRequest: { _ in },
                endRequest: { _ in })

            let resolution: LLMRouteResolution = s.backend == .lmStudio
                ? .pinned(.local("fake-local-tailcheck-model"))
                : .pinned(.local(ref: LocalModelRef(backend: .ollama, modelID: "fake-ollama-tailcheck-model")))
            let judge = LocalRouteTailJudge(routeResolver: { resolution }, transport: transport)

            var captured: Result<TailCheck.JudgeAnswer?, Error>?
            judge.judge(context: s.context, tail: s.tail, timeoutMs: 400) { captured = $0 }

            let userContent: String?
            switch s.backend {
            case .lmStudio:
                reporter.record("[\(s.label)] exactly one request was sent to the fake LOCAL transport",
                                capturedLMStudioRequests.count == 1, "calls=\(capturedLMStudioRequests.count)")
                if let request = capturedLMStudioRequests.first, let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    userContent = exactlyOneUserMessageContent(json)
                } else {
                    userContent = nil
                }
            case .ollama:
                reporter.record("[\(s.label)] exactly one request was sent to the fake LOCAL transport",
                                capturedOllamaBodies.count == 1, "calls=\(capturedOllamaBodies.count)")
                userContent = capturedOllamaBodies.first.flatMap(exactlyOneUserMessageContent)
            }

            reporter.record(
                "[\(s.label)] the request carries EXACTLY ONE user message, whose content is exactly "
                    + "the bounded context followed by the tail and nothing else",
                userContent == (s.context + s.tail), "got=\(String(describing: userContent))")

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

    /// The real entry point the manifest dispatches to -- see `runJudgeLocalOnly(arguments:)`'s
    /// identical wrapper above.
    private static func runJudgeRequestShape(arguments: [String]) -> Bool {
        if arguments.contains(networkDeniedChildFlag) {
            return runJudgeRequestShape()
        }
        return NetworkDenialSandbox.runArmDenyingNetwork(arm: Arm.judgeRequestShape.rawValue, label: "judge-request-shape",
                                                           contained: runJudgeRequestShape)
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

        // vdtpwg4 repair (JW3's real-gate-environment measurement): [400,450) was calibrated against
        // this LOCAL environment's own scheduling only (~410-411ms here). JW3 measured the SAME real
        // reference, over 5 repeats, INSIDE the actual grading environment (a sandboxed codex judge
        // process) at 588.1-603.8ms -- the same environment-overhead gap as the 100ms arm, not a drift
        // in the implementation. The named `timeoutMs + 250ms` bypass this band exists to catch lands
        // at a fixed ~650ms regardless of environment. Re-measured here (5 repeats, this link):
        // 403.3-411.9ms. Taking JW3's real-environment ceiling (603.8ms) as the authoritative one (the
        // grading environment, not this one, is what must pass), the band below widens to [400,630):
        // ~26.2ms of real headroom above JW3's measured ceiling, and still a clear ~20ms gap below the
        // 650ms bypass -- both real margins, not a guessed tight value. Still measured from OUTSIDE
        // (`t0`/`DispatchTime.now()` wrap the arm's own call to `afterFinalText`), per the addendum's
        // directive 2.
        reporter.record("a judge slower than the default 400 ms times out within a tight band around it",
                        elapsedMs >= 400 && elapsedMs < 630, "elapsed=\(elapsedMs)ms")
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
    //
    // vdtpwg2 repair (JW hole 6): a SECOND, distinct new-shaped body (different segment count, order,
    // and values) rules out a hard-coded two-segment answer, and a THIRD case exercises the doc
    // comment's other untested clause -- "segments present but not an array decodes to [] without
    // error" -- which the original fixture set never covered.

    private static func runDaemonSegmentsDecoded() -> Bool {
        print("=== ViddyDictate tailcheck — daemon-segments-decoded arm ===")
        let reporter = SelfTestReporter()

        let newBodyA: [String: Any] = [
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
        let decodedA = DaemonClient.parseSegments(from: newBodyA)
        reporter.record("[case A] a NEW-shaped response decodes one TailCheck.Segment per input segment",
                        decodedA.count == 2, "got=\(decodedA.count)")
        if decodedA.count == 2 {
            reporter.record("[case A] segment[0] keeps start/end/raw_text and its real metrics",
                            decodedA[0].start == 0.0 && decodedA[0].end == 5.0
                                && decodedA[0].rawText == "Checking in now."
                                && decodedA[0].noSpeechProb == 0.05
                                && decodedA[0].avgLogprob == -0.2
                                && decodedA[0].compressionRatio == 1.0)
            reporter.record(
                "[case A] segment[1]'s raw_text is the PRE-collapse decode, distinct from the shortened 'text' field",
                decodedA[1].rawText == "primarily primarily primarily primarily")
            let def = TailCheck.missingSegmentMetricDefault
            reporter.record("[case A] segment[1]'s missing/null metrics decode to the documented safe default",
                            decodedA[1].noSpeechProb == def && decodedA[1].avgLogprob == def
                                && decodedA[1].compressionRatio == def)
        } else {
            reporter.record("[case A] segment[0] keeps start/end/raw_text and its real metrics", false)
            reporter.record(
                "[case A] segment[1]'s raw_text is the PRE-collapse decode, distinct from the shortened 'text' field",
                false)
            reporter.record("[case A] segment[1]'s missing/null metrics decode to the documented safe default", false)
        }

        // Case B: distinct from A -- three segments, different order of present/missing metrics, a
        // non-zero start time on segment[0], and different literal values throughout.
        let newBodyB: [String: Any] = [
            "transcript": "We'll be right back. We'll be right back. Thanks for watching.",
            "raw_transcript": "We'll be right back. We'll be right back. Thanks for watching.",
            "model": "mlx-community/whisper-large-v3-turbo",
            "parameters": ["audio_duration_s": 20.0],
            "segments": [
                ["start": 1.5, "end": 6.0, "effective_end": 6.0, "text": "We'll be right back.",
                 "kept": true, "drop_reason": NSNull(), "raw_text": "We'll be right back.",
                 "no_speech_prob": NSNull(), "avg_logprob": -0.4, "compression_ratio": 1.1],
                ["start": 6.0, "end": 10.0, "effective_end": 10.0, "text": "We'll be right back.",
                 "kept": true, "drop_reason": NSNull(), "raw_text": "We'll be right back.",
                 "no_speech_prob": 0.2, "avg_logprob": NSNull(), "compression_ratio": 1.1],
                ["start": 10.1, "end": 20.0, "effective_end": 20.0, "text": "Thanks for watching.",
                 "kept": true, "drop_reason": NSNull(), "raw_text": "Thanks for watching.",
                 "no_speech_prob": 0.7, "avg_logprob": -1.2, "compression_ratio": NSNull()],
            ],
        ]
        let decodedB = DaemonClient.parseSegments(from: newBodyB)
        reporter.record("[case B] a differently-shaped NEW response decodes one Segment per input segment",
                        decodedB.count == 3, "got=\(decodedB.count)")
        if decodedB.count == 3 {
            let def = TailCheck.missingSegmentMetricDefault
            reporter.record("[case B] segment[0]'s only-null metric (no_speech_prob) decodes to the safe default",
                            decodedB[0].start == 1.5 && decodedB[0].noSpeechProb == def
                                && decodedB[0].avgLogprob == -0.4 && decodedB[0].compressionRatio == 1.1)
            reporter.record("[case B] segment[1]'s only-null metric (avg_logprob) decodes to the safe default",
                            decodedB[1].noSpeechProb == 0.2 && decodedB[1].avgLogprob == def
                                && decodedB[1].compressionRatio == 1.1)
            reporter.record("[case B] segment[2]'s only-null metric (compression_ratio) decodes to the safe "
                            + "default, and its raw_text is kept",
                            decodedB[2].rawText == "Thanks for watching." && decodedB[2].noSpeechProb == 0.7
                                && decodedB[2].avgLogprob == -1.2 && decodedB[2].compressionRatio == def)
        } else {
            reporter.record("[case B] segment[0]'s only-null metric (no_speech_prob) decodes to the safe default", false)
            reporter.record("[case B] segment[1]'s only-null metric (avg_logprob) decodes to the safe default", false)
            reporter.record("[case B] segment[2]'s only-null metric (compression_ratio) decodes to the safe "
                            + "default, and its raw_text is kept", false)
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

        // vdtpwg2 repair (JW hole 6): the doc comment's other untested clause -- `segments` present but
        // not an array (a malformed/unexpected wire shape) must also decode to [] without throwing.
        let notAnArrayBody: [String: Any] = [
            "transcript": "Checking in now.",
            "raw_transcript": "Checking in now.",
            "model": "mlx-community/whisper-large-v3-turbo",
            "parameters": ["audio_duration_s": 5.0],
            "segments": "not-an-array",
        ]
        let decodedNotAnArray = DaemonClient.parseSegments(from: notAnArrayBody)
        reporter.record(
            "a response where 'segments' is present but NOT an array decodes to [] without error",
            decodedNotAnArray.isEmpty, "got=\(decodedNotAnArray.count)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "daemon-segments-decoded"))
        return reporter.passed
    }

    // MARK: - NullHUDPresenter (vdtpwg4 repair, master ruling item iv)
    //
    // The no-op presenter the master ruling calls for: conforms to `HUDPresenting` without
    // constructing a single real AppKit control, so a headless `DictationController` fixture can
    // drive a REAL `finalize()`/`deliver()` call with zero risk of the construction-time crash
    // `vdtpwg3-JW3.md` traced to `HUDPanel.init` (`NSTextField.labelWithString` ->
    // `_RegisterApplication`) in a process with no window-server session. Every method is a plain
    // no-op; none of `hook-after-paste`/`hook-wired`'s own assertions depend on HUD content (they
    // assert the real clipboard/bullseye write and the real hook call), so nothing here needs to be
    // a spy.
    private final class NullHUDPresenter: HUDPresenting {
        var onLock: (() -> Void)?
        var onStop: (() -> Void)?
        var onSettings: (() -> Void)?
        var samplesProvider: (() -> [Float])?
        var onSetLevel: ((Int) -> Void)?

        func show() {}
        func hide() {}
        func setTakeActive(_ active: Bool) {}
        func setRecoveryPending(takeID: UUID, pending: Bool) {}
        func setHotkeyMap(_ map: HotkeyMap) {}
        func flashModeBadge(glyph: String, label: String) {}
        func flashCleanupBadge(label: String) {}
        func setThinking(_ on: Bool) {}
        func setCleanup(enabled: Bool, level: Int) {}
        func setArmedMode(glyph: String?) {}
        func setBullseyeArmed(_ armed: Bool) {}
        func update(state: String, target: String?, text: String, locked: Bool) {}
        func toast(_ message: String, duration: TimeInterval, forceFull: Bool, action: (() -> Void)?) {}
        func answer(_ text: String) {}
    }

    // MARK: - DictationController test fixture (vdtpwg2 repair, parts B/C/D)
    //
    // Shared by `hook-after-paste` and `hook-wired`: a real, fully-constructed `DictationController`
    // routed, deterministically and without AX or live-focus dependence, into `finalize()`'s
    // locked-no-target branch (`wasLocked = true`, `target` left nil, Notes routing unarmed and
    // `notesWindowIsKey` false so `routeNotesDelivery` returns `.notNotes`). That branch's real write
    // (`TargetResolver.copyToClipboard`) goes to a PRIVATE, uniquely-named pasteboard -- never
    // `.general` -- the same "private named pasteboard, never general" convention `CleanupSelfTest`'s
    // own `runClipboardTests` already established, so driving a real delivery branch here never touches
    // the user's actual clipboard. `NotesBullseyeState` gets its own fresh store + UserDefaults suite
    // per call so no scenario can observe another's state.

    private static func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(AppIdentity.queueLabel("tailcheck-selftest-\(UUID().uuidString)")))
    }

    private static func makeHookTestController(
        tailCheckHook: TailCheckDictationHook, pasteboard: NSPasteboard
    ) -> DictationController {
        let notesCallbacks = NotesDeliveryCallbacks(
            onSnapshotNoteTarget: { _ in nil },
            onDeliverToNoteTarget: { _, _ in .noWindow },
            onInsertIntoActiveNote: { _ in .noWindow },
            onSetBullseyeAtCaret: { nil },
            onDeliverToBullseye: { _ in .noWindow },
            onBullseyeStateChanged: {},
            onRevealBullseye: { .noneSet },
            onResolveReplaceHighlightTarget: { nil },
            onShowReplaceHighlight: { _, _, _ in },
            onClearReplaceHighlight: { _ in },
            onUndoNoteDelivery: { _ in false },
            onReplaceNoteDelivery: { _, _ in false },
            onCurrentNoteId: { nil })
        let bullseyeState = NotesBullseyeState(
            store: StickyNotesStore(),
            defaults: UserDefaults(suiteName: "tailcheck-selftest-bullseye-\(UUID().uuidString)")!)
        let notesDelivery = NotesDeliveryCoordinator(callbacks: notesCallbacks, bullseyeState: bullseyeState)
        let controller = DictationController(
            callbacks: DictationControllerCallbacks(
                onStateChange: { _ in }, onOpenSettings: {}, onOpenDictionary: {}, onOpenNotes: {},
                notesWindowIsKey: { false }, onCleanupModeChange: { _ in }),
            notesDelivery: notesDelivery,
            tailCheckHook: tailCheckHook,
            clipboardPasteboard: pasteboard,
            // vdtpwg4 repair (master ruling item iv): the no-op `HUDPresenting` conformer -- see its
            // own doc comment above and `vdtpwg3-JW3.md`'s crash report (abort 134 in
            // `HUDPanel.init` itself, reached via `finalize()`'s real landDelivery construction path).
            hud: NullHUDPresenter())
        controller.wasLocked = true
        return controller
    }

    /// vdtpwg3 repair (point 2): a SECOND real, AX-free, system-pasteboard-free delivery branch --
    /// `finalize()`'s notes/bullseye landing (`NotesLanding.bullseye`), which `NotesBullseyeLogic.delivery`
    /// routes to BEFORE either the `wasLocked` or `target` checks, so this is a genuinely different real
    /// branch from `makeHookTestController`'s locked-no-target one, not a relabeled copy of it. Armed
    /// deterministically via `NotesBullseyeState.setAtCaret` (no JS bridge, no real note, no AX) with
    /// `onDeliverToBullseye` answering `.delivered` -- the same "real seam, injected answer" shape as
    /// `makeHookTestController`'s clipboard pasteboard. Push-to-talk and locked-WITH-a-captured-target are
    /// NOT driven here: both require a real `DictationTarget` wrapping a live AX element with no existing
    /// fake-target seam into the REAL `finalize()` (see `LockedDeliverySelfTest`, which tests the pure
    /// `lockedDeliveryResolution` classifier plus a parallel fake harness for exactly this reason, never
    /// the real controller) -- driving them here would mean either a live AX paste-synthesis call or a
    /// write to `NSPasteboard.general`, the one thing every fixture in this file is built to avoid. Noted
    /// as a residual (see this chain's GW3 report), not closed by this link.
    private static func makeBullseyeHookTestController(
        tailCheckHook: TailCheckDictationHook, noteId: String = "tailcheck-selftest-bullseye-note"
    ) -> DictationController {
        let notesCallbacks = NotesDeliveryCallbacks(
            onSnapshotNoteTarget: { _ in nil },
            onDeliverToNoteTarget: { _, _ in .noWindow },
            onInsertIntoActiveNote: { _ in .noWindow },
            onSetBullseyeAtCaret: { nil },
            onDeliverToBullseye: { _ in .delivered },
            onBullseyeStateChanged: {},
            onRevealBullseye: { .noneSet },
            onResolveReplaceHighlightTarget: { nil },
            onShowReplaceHighlight: { _, _, _ in },
            onClearReplaceHighlight: { _ in },
            onUndoNoteDelivery: { _ in false },
            onReplaceNoteDelivery: { _, _ in false },
            onCurrentNoteId: { nil })
        let bullseyeState = NotesBullseyeState(
            store: StickyNotesStore(),
            defaults: UserDefaults(suiteName: "tailcheck-selftest-bullseye-armed-\(UUID().uuidString)")!)
        bullseyeState.setAtCaret(noteId: noteId)
        let notesDelivery = NotesDeliveryCoordinator(callbacks: notesCallbacks, bullseyeState: bullseyeState)
        let controller = DictationController(
            callbacks: DictationControllerCallbacks(
                onStateChange: { _ in }, onOpenSettings: {}, onOpenDictionary: {}, onOpenNotes: {},
                notesWindowIsKey: { false }, onCleanupModeChange: { _ in }),
            notesDelivery: notesDelivery,
            tailCheckHook: tailCheckHook,
            hud: NullHUDPresenter())
        return controller
    }

    // MARK: - hook-after-paste (vdtpwg, part D)
    //
    // The "fires within 100 ms" check is a standing guardrail: a no-op always returns before any
    // caller-visible deadline, including a deliberately tiny one, and must keep holding once a real,
    // dispatch-and-return-fast implementation replaces `NullTailCheckDictationHook`. The "ran off the
    // main thread, after the hook returned" check is red today, traced to `NullTailCheckDictationHook`'s
    // "ignores `observer` entirely and does nothing" stub line: the wrapped `TailCheckObserver` (with
    // its slow judge) never runs at all.
    //
    // vdtpwg2 repair (JW hole 2 + hole 6): the old arm called `NullTailCheckDictationHook.call(...)`
    // directly and labeled that bare call "the paste/delivery callback" -- no paste or delivery had
    // actually happened. This version drives a REAL `DictationController.finalize()` call through the
    // deterministic locked-no-target branch (a real, synchronous clipboard write; see
    // `makeHookTestController` above) and asserts the write is already observable (changeCount
    // incremented) by the time `finalize()` returns, plus that the hook's own sink work never runs on
    // the thread that performed the paste -- an ordering + thread assertion, not a timed sleep standing
    // in for proof.
    //
    // vdtpwg3 repair (JW2 hole 2, bounded per the 2026-10-07 addendum): two fixes. (a) `elapsed < 100`
    // let a hook that synchronously sleeps 90-99ms before dispatching still pass; tightened to `<= 20`
    // ms, well under any budget a real dispatch-and-return-fast implementation needs. (b) "two distinct
    // takes" never varied the DELIVERY BRANCH, only the text -- both ran through the same locked-no-
    // target path. A second real branch (`NotesLanding.bullseye`, via `makeBullseyeHookTestController`)
    // is added; its own real, synchronous write (the injected `onDeliverToBullseye` callback) is proven
    // observable by return the same way the clipboard write is, via a dedicated counter rather than a
    // pasteboard changeCount (that branch never touches any pasteboard). Push-to-talk and locked-with-
    // a-captured-target stay out of scope -- see `makeBullseyeHookTestController`'s own doc comment.
    // Elapsed is still measured from OUTSIDE the call (`t0` wraps `controller.finalize(...)` itself,
    // never a value the hook or observer reports about itself), per the addendum's directive 2.

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

        enum Branch { case lockedNoTarget, notesBullseye }
        struct Case { let label: String; let branch: Branch; let text: String; let segments: [TailCheck.Segment] }
        let cases: [Case] = [
            Case(label: "case 1 (locked, no target)", branch: .lockedNoTarget,
                 text: "I approve the plan. " + Array(repeating: "primarily", count: 8).joined(separator: " "),
                 segments: [
                    TailCheck.Segment(start: 0.0, end: 5.0, rawText: "I approve the plan.",
                                      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
                    TailCheck.Segment(start: 5.1, end: 12.0,
                                      rawText: Array(repeating: "primarily", count: 8).joined(separator: " "),
                                      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
                 ]),
            Case(label: "case 2 (locked, no target)", branch: .lockedNoTarget,
                 text: "Let's finalize the budget. " + Array(repeating: "secondary", count: 7).joined(separator: " "),
                 segments: [
                    TailCheck.Segment(start: 0.0, end: 4.0, rawText: "Let's finalize the budget.",
                                      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
                    TailCheck.Segment(start: 4.1, end: 11.0,
                                      rawText: Array(repeating: "secondary", count: 7).joined(separator: " "),
                                      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
                 ]),
            Case(label: "case 3 (notes bullseye landing)", branch: .notesBullseye,
                 text: "Add this to the shopping list. " + Array(repeating: "tertiary", count: 7).joined(separator: " "),
                 segments: [
                    TailCheck.Segment(start: 0.0, end: 4.0, rawText: "Add this to the shopping list.",
                                      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
                    TailCheck.Segment(start: 4.1, end: 11.0,
                                      rawText: Array(repeating: "tertiary", count: 7).joined(separator: " "),
                                      noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
                 ]),
        ]

        let savedEnabled = Settings.tailCheckEnabled
        defer { Settings.tailCheckEnabled = savedEnabled }
        Settings.tailCheckEnabled = true

        for c in cases {
            let lock = NSLock()
            var sinkCalls = 0
            var sinkThread: Thread?
            let observer = TailCheckObserver(
                sink: { _ in lock.lock(); sinkCalls += 1; sinkThread = Thread.current; lock.unlock() },
                judge: SlowJudge(), judgeTimeoutMs: 5_000)
            let hook: TailCheckDictationHook = NullTailCheckDictationHook(observer: observer)

            let callingThread = Thread.current
            var writeObservedByReturn = false
            var writeDetail = ""
            let elapsedMs: Double

            switch c.branch {
            case .lockedNoTarget:
                let pasteboard = scratchPasteboard()
                defer { pasteboard.releaseGlobally() }
                let controller = makeHookTestController(tailCheckHook: hook, pasteboard: pasteboard)
                let changeCountBefore = pasteboard.changeCount
                let t0 = DispatchTime.now()
                _ = controller.finalize(delivered: c.text, raw: c.text, cleaned: nil, mode: .raw,
                                        historyID: UUID(), segments: c.segments)
                elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
                let changeCountAfter = pasteboard.changeCount
                writeObservedByReturn = changeCountAfter > changeCountBefore
                writeDetail = "clipboard changeCount before=\(changeCountBefore) after=\(changeCountAfter)"
            case .notesBullseye:
                let writeLock = NSLock()
                var bullseyeWrites = 0
                let notesCallbacks = NotesDeliveryCallbacks(
                    onSnapshotNoteTarget: { _ in nil },
                    onDeliverToNoteTarget: { _, _ in .noWindow },
                    onInsertIntoActiveNote: { _ in .noWindow },
                    onSetBullseyeAtCaret: { nil },
                    onDeliverToBullseye: { _ in
                        writeLock.lock(); bullseyeWrites += 1; writeLock.unlock()
                        return .delivered
                    },
                    onBullseyeStateChanged: {},
                    onRevealBullseye: { .noneSet },
                    onResolveReplaceHighlightTarget: { nil },
                    onShowReplaceHighlight: { _, _, _ in },
                    onClearReplaceHighlight: { _ in },
                    onUndoNoteDelivery: { _ in false },
                    onReplaceNoteDelivery: { _, _ in false },
                    onCurrentNoteId: { nil })
                let bullseyeState = NotesBullseyeState(
                    store: StickyNotesStore(),
                    defaults: UserDefaults(suiteName: "tailcheck-selftest-bullseye-timing-\(UUID().uuidString)")!)
                bullseyeState.setAtCaret(noteId: "tailcheck-selftest-timing-note")
                let notesDelivery = NotesDeliveryCoordinator(callbacks: notesCallbacks, bullseyeState: bullseyeState)
                let controller = DictationController(
                    callbacks: DictationControllerCallbacks(
                        onStateChange: { _ in }, onOpenSettings: {}, onOpenDictionary: {}, onOpenNotes: {},
                        notesWindowIsKey: { false }, onCleanupModeChange: { _ in }),
                    notesDelivery: notesDelivery,
                    tailCheckHook: hook,
                    hud: NullHUDPresenter())
                let t0 = DispatchTime.now()
                _ = controller.finalize(delivered: c.text, raw: c.text, cleaned: nil, mode: .raw,
                                        historyID: UUID(), segments: c.segments)
                elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
                writeLock.lock(); let writes = bullseyeWrites; writeLock.unlock()
                writeObservedByReturn = writes == 1
                writeDetail = "onDeliverToBullseye calls=\(writes)"
            }

            reporter.record(
                "[\(c.label)] the real paste/delivery write is observable by the time finalize() returns",
                writeObservedByReturn, writeDetail)
            reporter.record(
                "[\(c.label)] finalize() itself (the real paste/delivery callback) returns within 20 ms, "
                    + "measured from OUTSIDE the call",
                elapsedMs <= 20, "elapsed=\(elapsedMs)ms")

            Thread.sleep(forTimeInterval: 1.5)
            lock.lock()
            let finalSinkCalls = sinkCalls
            let finalSinkThread = sinkThread
            lock.unlock()
            reporter.record(
                "[\(c.label)] the observe+judge work ran exactly once, strictly after the real paste write",
                finalSinkCalls == 1, "sinkCalls=\(finalSinkCalls)")
            reporter.record(
                "[\(c.label)] the hook's judge-call work ran off the thread that performed the paste",
                finalSinkThread !== callingThread,
                "sinkThread=\(String(describing: finalSinkThread)) pasteThread=\(callingThread)")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hook-after-paste"))
        return reporter.passed
    }

    // MARK: - hook-wired (vdtpwg, part D)
    //
    // vdtpwg2 repair (JW hole 3): the old arm graded `DictationController.swift`'s source TEXT --
    // a comment, `if false`, or a never-called closure containing the four strings could satisfy it,
    // and it never checked WHERE the one call site sat relative to delivery, nor what values actually
    // reached the hook. This version replaces the source-slice entirely: `DictationController` now
    // takes its tail-check hook as a constructor-injectable dependency (`DictationController.init`'s
    // `tailCheckHook` parameter, same pattern as `ModelManager.CapacityDependencies`), defaulting to
    // the real production hook (`TailCheckObserver.makeDefaultHook`); production's own call site in
    // `finalize()`'s `finish` tail is unchanged by this arm. The arm substitutes a spy hook and drives
    // an ACTUAL `finalize(...)` call -- the smallest real entry point that reaches it (see
    // `makeHookTestController` above) -- for each of `deliver()`'s three distinct calls into `finalize`
    // (raw, cleanup success, cleanup fallback; GW's own commentary names these as finalize's three
    // real entry shapes), asserting the spy received the EXACT `finalText`/`rawText`/`segments`/
    // `cleanupLevel` values that specific real call was given -- never by grepping source text. A
    // fourth case proves the `Settings.tailCheckEnabled` gate for real (flips it off, the real call
    // produces zero hook invocations) rather than merely checking the literal name appears somewhere.

    private static func runHookWired() -> Bool {
        print("=== ViddyDictate tailcheck — hook-wired arm ===")
        let reporter = SelfTestReporter()

        final class SpyHook: TailCheckDictationHook {
            struct Call: Equatable {
                let finalText: String; let rawText: String
                let segmentRawTexts: [String]; let cleanupLevel: String
            }
            private let lock = NSLock()
            private(set) var calls: [Call] = []
            func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String) {
                lock.lock(); defer { lock.unlock() }
                calls.append(Call(finalText: finalText, rawText: rawText,
                                  segmentRawTexts: segments.map(\.rawText), cleanupLevel: cleanupLevel))
            }
        }

        func segment(_ rawText: String) -> TailCheck.Segment {
            TailCheck.Segment(start: 0.0, end: 1.0, rawText: rawText,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0)
        }

        let savedEnabled = Settings.tailCheckEnabled
        defer { Settings.tailCheckEnabled = savedEnabled }

        // Branch 1: `deliver()`'s raw-mode call (`cleaned: nil, mode: .raw, level: nil`).
        //
        // vdtpwg3 repair (point 3, JW2 hole 3's shallow-wiring half): the old version called
        // `finalize(...)` directly with a hand-supplied `segs` array -- exactly the "shortcut-call
        // green" JW2 named, since it never proved deliver() (the real upstream entry point transcribe's
        // completion calls) threads anything at all. This drives `DictationController.deliver(text:
        // error:generation:takeID:retentionWasEnabled:segments:)` itself (widened `private` ->
        // `internal`, same precedent as `finalize()`'s own vdtpwg2 widening).
        //
        // vdtpwg4 repair (master ruling item v): JW3 found the PREVIOUS version of this branch asserted
        // `segmentRawTexts: []` as the CORRECT outcome -- blessing the exact missing upstream
        // propagation I3 (now this link) was supposed to add. `deliver()` now takes a real `segments:`
        // parameter and threads it into its raw-mode `finalize()` call (and `DaemonClient.transcribe` ->
        // `transcribeAudioSnapshot` -> `finish()` thread the daemon's real decoded segments into that
        // same parameter in production); this branch now drives `deliver()` with a REAL non-empty
        // segments array (the shape a decoded daemon response would carry) and requires the spy receive
        // those EXACT segments, unchanged, never `[]`.
        Settings.tailCheckEnabled = true
        do {
            let spy = SpyHook()
            let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
            let controller = makeHookTestController(tailCheckHook: spy, pasteboard: pasteboard)
            let rawText = "The raw upstream delivery text arrived safely."
            let realSegments = [
                segment("The raw upstream delivery text arrived safely."),
                segment("primarily primarily primarily"),
            ]
            controller.deliver(text: rawText, error: nil, generation: 0, takeID: UUID(),
                               retentionWasEnabled: false, segments: realSegments)
            reporter.record("[raw, via the real deliver() entry point] the hook is called exactly once",
                            spy.calls.count == 1, "calls=\(spy.calls.count)")
            reporter.record(
                "[raw, via the real deliver() entry point] the spy received this real call's exact "
                    + "finalText/rawText/cleanupLevel, and the REAL non-empty segments deliver() was "
                    + "given -- unchanged, never defaulted to []",
                spy.calls.first == SpyHook.Call(finalText: rawText, rawText: rawText,
                                                segmentRawTexts: realSegments.map(\.rawText),
                                                cleanupLevel: TailCheck.cleanupLevelNone),
                "got=\(String(describing: spy.calls.first))")
        }

        // Branch 2: `deliver()`'s cleanup-success call (`cleaned: <text>, mode: .cleanup, level:
        // effectiveLevel.rawValue`) -- here CleanupLevel.tighten, so cleanupLevel == "l2".
        do {
            let spy = SpyHook()
            let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
            let controller = makeHookTestController(tailCheckHook: spy, pasteboard: pasteboard)
            let segs = [segment("cleanup branch tail text")]
            _ = controller.finalize(delivered: "cleaned delivered text", raw: "cleanup raw source text",
                                    cleaned: "cleaned delivered text", mode: .cleanup,
                                    level: CleanupLevel.tighten.rawValue, historyID: UUID(), segments: segs)
            reporter.record("[cleanup-success] the hook is called exactly once", spy.calls.count == 1,
                            "calls=\(spy.calls.count)")
            reporter.record(
                "[cleanup-success] the spy received this real call's exact finalText/rawText/segments/"
                    + "cleanupLevel (l2, from CleanupLevel.tighten)",
                spy.calls.first == SpyHook.Call(
                    finalText: "cleaned delivered text", rawText: "cleanup raw source text",
                    segmentRawTexts: ["cleanup branch tail text"], cleanupLevel: TailCheck.cleanupLevelL2),
                "got=\(String(describing: spy.calls.first))")
        }

        // Branch 3: `deliver()`'s cleanup-fallback call -- cleanup failed, so it lands the raw transcript
        // exactly like branch 1's shape (`cleaned: nil, mode: .raw, level: nil`), but `keepHUD: true` and
        // a `completion` closure, distinguishing it as a different real call site.
        do {
            let spy = SpyHook()
            let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
            let controller = makeHookTestController(tailCheckHook: spy, pasteboard: pasteboard)
            let segs = [segment("fallback branch tail text")]
            var completionFired = false
            _ = controller.finalize(delivered: "fallback raw text", raw: "fallback raw text", cleaned: nil,
                                    mode: .raw, historyID: UUID(), keepHUD: true, segments: segs) { _ in
                completionFired = true
            }
            reporter.record("[cleanup-fallback] the hook is called exactly once", spy.calls.count == 1,
                            "calls=\(spy.calls.count)")
            reporter.record(
                "[cleanup-fallback] the spy received this real call's exact finalText/rawText/segments/cleanupLevel",
                spy.calls.first == SpyHook.Call(finalText: "fallback raw text", rawText: "fallback raw text",
                                                segmentRawTexts: ["fallback branch tail text"],
                                                cleanupLevel: TailCheck.cleanupLevelNone),
                "got=\(String(describing: spy.calls.first))")
            reporter.record("[cleanup-fallback] the completion closure this real call site uses still fires",
                            completionFired)
        }

        // Gate: `Settings.tailCheckEnabled == false` suppresses the real call site entirely.
        do {
            Settings.tailCheckEnabled = false
            let spy = SpyHook()
            let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
            let controller = makeHookTestController(tailCheckHook: spy, pasteboard: pasteboard)
            _ = controller.finalize(delivered: "gated text", raw: "gated text", cleaned: nil, mode: .raw,
                                    historyID: UUID())
            reporter.record("[gated off] Settings.tailCheckEnabled == false suppresses the real hook call",
                            spy.calls.isEmpty, "calls=\(spy.calls.count)")
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hook-wired"))
        return reporter.passed
    }

    // MARK: - hud-flag-real (vdtpwg, part C)
    //
    // Red today, traced to `RealTailCheckFlagPresenter.showFlag`'s "does nothing" stub line: the sink
    // is never called at all, so none of the checks below -- which describe the real I3 contract --
    // can pass yet.
    //
    // vdtpwg2 repair (JW hole 4 + hole 6): the old arm hand-built `TailCheckObserver(judge:presenter:
    // RealTailCheckFlagPresenter(sink:))` directly in the test -- exactly the "parallel construction"
    // JW objects to, since it never proved `DictationController`'s OWN default wiring goes through
    // that same code. This version drives `TailCheckObserver.makeDefault` -- the ONE production
    // factory `DictationController.init`'s own `tailCheckHook` default calls (tied together by the
    // source check below; the factory's hook WRAPPER is still Phase 1's inert `NullTailCheckDictation
    // Hook` stub, so the wrapped hook itself can't be driven end-to-end yet, but the observer/
    // presenter construction it shares with the hook factory can) -- substituting only the judge
    // (necessary: the real production judge is itself still a stub) and the HUD sink (the thing under
    // test), never hand-building `RealTailCheckFlagPresenter` inline. The junk suffix is now well over
    // the 60-char cap, and the check is the EXACT truncated string, not merely `count <= 60` (which a
    // no-op emitting nothing, count 0, would also satisfy).

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

        let initSlice = NotesProbe.sourceSlice(
            NotesProbe.sourceDictationController,
            from: "private let tailCheckHookOverride", to: "func startMonitoring()")
        reporter.record(
            "DictationController's own tailCheckHook default calls the production factory "
                + "(TailCheckObserver.makeDefaultHook) -- the real construction path, not a parallel copy",
            initSlice.contains("TailCheckObserver.makeDefaultHook("), initSlice)

        // vdtpwg3 repair (point 4, JW2's exact named adversary): the check above only proves the
        // CONTROLLER names `makeDefaultHook` somewhere in its init slice -- it says nothing about
        // `makeDefaultHook`'s OWN body, in TailCheck.swift. JW2's adversary keeps that controller-level
        // reference (satisfying the check above) while editing `makeDefaultHook` itself to build a hook
        // wrapping `NullTailCheckFlagPresenter`, "retaining a dead/unreachable `makeDefault(...)`
        // expression" so a bare `contains("makeDefault")`-style check still passes. Closed by slicing
        // `makeDefaultHook`'s OWN source (from its declaration to end of file -- it is the last
        // declaration in `TailCheck.swift`) and asserting BOTH that it still names the real executed
        // return shape AND that `NullTailCheckFlagPresenter` does not appear anywhere in that slice --
        // a dead/unreachable real expression sitting alongside a live `NullTailCheckFlagPresenter` swap
        // fails this second half even though it would still satisfy a bare substring-presence check.
        guard let makeDefaultHookStart = NotesProbe.sourceTailCheck.range(of: "static func makeDefaultHook(")
        else {
            reporter.record("located makeDefaultHook's own declaration in TailCheck.swift to slice it", false)
            print("\n=== RESULT ===")
            print(reporter.summaryLine(prefix: "hud-flag-real"))
            return reporter.passed
        }
        let makeDefaultHookBody = String(NotesProbe.sourceTailCheck[makeDefaultHookStart.upperBound...])
        reporter.record(
            "makeDefaultHook's OWN body (not merely the controller's reference to its name) still "
                + "returns the real, executed NullTailCheckDictationHook(observer: makeDefault(...)) shape",
            makeDefaultHookBody.contains("NullTailCheckDictationHook(observer: makeDefault("),
            makeDefaultHookBody)
        reporter.record(
            "makeDefaultHook's OWN body never constructs NullTailCheckFlagPresenter anywhere -- ruling "
                + "out a live swap to the no-op presenter sitting alongside a dead/unreachable real "
                + "makeDefault(...) expression or comment",
            !makeDefaultHookBody.contains("NullTailCheckFlagPresenter"), makeDefaultHookBody)

        let cleanText = "The fix that landed for the sticky note tabs looks pretty good."
        let cleanSegments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: cleanText,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]
        let gapTriggeringText = "I approve the plan for Monday and the budget we discussed. Thank you."
        let gapTriggeringSegments = [
            TailCheck.Segment(start: 0.0, end: 5.0,
                              rawText: "I approve the plan for Monday and the budget we discussed.",
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 6.5, end: 7.0, rawText: "Thank you.",
                              noSpeechProb: 0.3, avgLogprob: -0.3, compressionRatio: 1.0),
        ]
        // A genuinely-long (> 60 char) accepted-suffix fixture, so truncation is actually exercised
        // rather than vacuously passing against a suffix already under the cap. 8 repeated words trips
        // `reasonRepeatLoop` (`repeatLoopMinRun == 6`); 8 words is exactly `acceptCut`'s `maxWords` (not
        // over), and the 14-word lead-in keeps the 8-word cut at 8/22 ≈ 0.36, under the 40% share cap.
        let longLeadIn = "I approve the plan for Monday and the budget we discussed in today's meeting."
        let longTail = Array(repeating: "primarily", count: 8).joined(separator: " ")
        let longTriggeringText = longLeadIn + " " + longTail
        let longTriggeringSegments = [
            TailCheck.Segment(start: 0.0, end: 5.0, rawText: longLeadIn,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
            TailCheck.Segment(start: 5.5, end: 12.0, rawText: longTail,
                              noSpeechProb: 0.05, avgLogprob: -0.2, compressionRatio: 1.0),
        ]
        precondition(longTail.count > RealTailCheckFlagPresenter.maxDisplaySuffixLength,
                    "test fixture must exceed the truncation cap for this check to mean anything")

        struct Scenario { let label: String; let text: String; let segments: [TailCheck.Segment]
                          let judgeAnswer: TailCheck.JudgeAnswer?; let wantFlag: Bool }
        let scenarios: [Scenario] = [
            Scenario(label: "no trigger", text: cleanText, segments: cleanSegments,
                    judgeAnswer: .junk(" anything"), wantFlag: false),
            Scenario(label: "triggered, judge clean", text: gapTriggeringText, segments: gapTriggeringSegments,
                    judgeAnswer: .clean, wantFlag: false),
            Scenario(label: "triggered, judge junk (suffix over the truncation cap), acceptCut would accept",
                    text: longTriggeringText, segments: longTriggeringSegments,
                    judgeAnswer: .junk(longTail), wantFlag: true),
        ]

        for s in scenarios {
            let lock = NSLock()
            var sinkCalls: [String] = []
            var sinkCallsOnMain = true
            let observer = TailCheckObserver.makeDefault(
                hudSink: { suffix in
                    lock.lock()
                    sinkCalls.append(suffix)
                    sinkCallsOnMain = sinkCallsOnMain && Thread.isMainThread
                    lock.unlock()
                },
                judge: FixedJudge(s.judgeAnswer))

            let pasteboard = NSPasteboard.general
            let changeCountBefore = pasteboard.changeCount
            let paste = observer.afterFinalText(s.text, segments: s.segments, rawText: s.text)

            reporter.record("[\(s.label)] paste is byte-identical to the input even when the real "
                            + "presenter is wired", paste == s.text)
            reporter.record("[\(s.label)] the real presenter handed the display sink exactly when it "
                            + "should (want=\(s.wantFlag))",
                            (sinkCalls.count == 1) == s.wantFlag, "calls=\(sinkCalls.count)")
            reporter.record("[\(s.label)] the system pasteboard's changeCount is unchanged",
                            pasteboard.changeCount == changeCountBefore,
                            "before=\(changeCountBefore) after=\(pasteboard.changeCount)")

            if s.wantFlag {
                let wantTruncated = String(s.judgeAnswer!.junkSuffix.prefix(
                    RealTailCheckFlagPresenter.maxDisplaySuffixLength))
                reporter.record(
                    "[\(s.label)] the flagged suffix is EXACTLY the suffix truncated to "
                        + "maxDisplaySuffixLength (not merely <= the cap)",
                    sinkCalls.first == wantTruncated,
                    "want=\(wantTruncated) got=\(String(describing: sinkCalls.first))")
                reporter.record("[\(s.label)] every sink call happened on the main thread", sinkCallsOnMain)
            }
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "hud-flag-real"))
        return reporter.passed
    }
}
