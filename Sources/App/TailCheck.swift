import Foundation

/// `TailCheck` — the Swift port of `Tools/tailcheck/core.py`'s trigger + cut-acceptance contract.
/// Design note: `Projects/viddydictate/notes/trailing-gibberish-check-design-20261003.md`, section
/// 2A (trigger), section 2B (accept-cut rules), and the 2026-10-06 "NEXT: Swift integration plan"
/// (Phase 1, observe-only).
///
/// Every function below is a pure namespace function: no file I/O, no socket, no AppKit, and never
/// a carrier of dictation text into anything that gets logged (`TailCheckObserver` below is the only
/// thing that may write, and only lengths/flags/timings, never text). `core.py`'s docstrings are the
/// real contract; `Tools/tailcheck/parity-fixture.json` (exported FROM core.py) is the oracle this
/// port is measured against, via `TailCheckSelfTest`'s `trigger-parity` / `cutrules-parity` arms.
///
/// I2 landed the real port of `trigger`/`acceptCut`/`observeRecord` and the text-free SOURCE
/// ATTRIBUTION fields. I3 lands the three Phase-1 seams: a LOCAL-ONLY `LocalRouteTailJudge` that
/// sends one bounded request through the injected local transport, a `RealTailCheckFlagPresenter`
/// that hands the truncated suffix to the HUD sink on the main thread, and a
/// `NullTailCheckDictationHook` that dispatches the observe work to a utility queue and returns
/// before the paste waits on it. Phase 1 stays observe-only: it may flag a trailing-junk suffix in
/// the HUD, but it never edits, trims or delays the pasted text.
enum TailCheck {
    /// One entry from the daemon's pre-collapse per-segment diagnostics (see `_clean_segments` in
    /// `viddydictate_whisperd.py`; `DaemonClient.parseSegments` decodes them and the
    /// `daemon-segments-decoded` arm round-trips these fields). Mirrors `core.py`'s contract field
    /// for field.
    struct Segment {
        let start: Double
        let end: Double
        let rawText: String
        let noSpeechProb: Double
        let avgLogprob: Double
        let compressionRatio: Double

        init(start: Double, end: Double, rawText: String,
             noSpeechProb: Double, avgLogprob: Double, compressionRatio: Double) {
            self.start = start
            self.end = end
            self.rawText = rawText
            self.noSpeechProb = noSpeechProb
            self.avgLogprob = avgLogprob
            self.compressionRatio = compressionRatio
        }
    }

    // --- trigger reason vocabulary (core.py `ALL_REASONS`) -------------------------------------
    static let reasonOutroFillerAfterGap = "outro_filler_after_gap"
    static let reasonDoubledToken = "doubled_token"
    static let reasonRepeatLoop = "repeat_loop"
    static let reasonLonePunctuationTail = "lone_punctuation_tail"
    static let reasonLowConfidenceTail = "low_confidence_tail"
    static let reasonCleanupAddedSuffix = "cleanup_added_suffix"

    static let allReasons: [String] = [
        reasonOutroFillerAfterGap, reasonDoubledToken, reasonRepeatLoop,
        reasonLonePunctuationTail, reasonLowConfidenceTail, reasonCleanupAddedSuffix,
    ]

    // --- accept_cut refusal vocabulary (core.py refusal constants) -----------------------------
    static let refusalNotSuffix = "not_suffix"
    static let refusalBodyEdit = "body_edit"
    static let refusalWholeText = "whole_text"
    static let refusalMidWord = "mid_word"
    static let refusalTooManyWords = "too_many_words"
    static let refusalShareTooHigh = "share_too_high"
    static let refusalNoSentenceRemains = "no_sentence_remains"
    static let accepted = "accepted"

    // --- tunable thresholds (mirrors core.py) --------------------------------------------------
    static let gapThresholdS = 0.8
    static let doubledTokenMaxWords = 4
    static let repeatLoopMinRun = 6
    static let nospeechTrigger = 0.5
    static let logprobTrigger = -1.0
    static let maxContextSentences = 2
    static let maxContextChars = 600
    static let outroPhrases: Set<String> = [
        "thank you", "thanks", "thanks for watching",
        "we will be right back", "we will see you next week", "bye", "goodbye",
    ]

    /// Safe default for a segment-diagnostic metric (`no_speech_prob`/`avg_logprob`/`compression_ratio`)
    /// missing or JSON `null` on the wire (`_clean_segments` can omit it; see `viddydictate_whisperd.py`).
    /// Named here as the single source of truth `DaemonClient.parseSegments` uses, and what the
    /// `daemon-segments-decoded` arm checks a decoded segment against.
    static let missingSegmentMetricDefault: Double = 0.0

    // --- cleanup-level vocabulary for source attribution ---------------------------------------
    //
    // Deliberately reuses the app's REAL `CleanupLevel` axis (`Sources/App/CleanupState.swift`:
    // cleanup/tighten/summarize, wired to `LLMRouteID.cleanupL1/L2/L3` in `LLMRouting.swift`)
    // rather than inventing a second vocabulary -- the design note's own "(L1/L2)" phrasing is
    // 2026-08-14-era history, from before the strength slider shipped a third level. `none` is the
    // one value the Raw/Cleanup toggle itself can produce that `CleanupLevel` cannot: no cleanup
    // LLM pass touched this take at all.
    static let cleanupLevelNone = "none"
    static let cleanupLevelL1 = "l1"
    static let cleanupLevelL2 = "l2"
    static let cleanupLevelL3 = "l3"
    static let allCleanupLevels = [cleanupLevelNone, cleanupLevelL1, cleanupLevelL2, cleanupLevelL3]

    /// `nil` means the cleanup LLM did not run on this take (Raw mode) -> `cleanupLevelNone`.
    static func cleanupLevelString(for level: CleanupLevel?) -> String {
        switch level {
        case nil:            return cleanupLevelNone
        case .cleanup:       return cleanupLevelL1
        case .tighten:       return cleanupLevelL2
        case .summarize:     return cleanupLevelL3
        }
    }

    /// Decide whether the tail is worth asking a judge about. Never a verdict by itself.
    /// Real contract: `core.trigger` in `core.py`.
    static func trigger(segments: [Segment], rawText: String, finalText: String) -> [String] {
        var reasons: [String] = []
        let last = segments.last
        let lastText = last?.rawText ?? ""

        // Signals that need the single-segment safety floor (>= 2 segments):
        // outro_filler_after_gap and low_confidence_tail both compare the LAST
        // segment against its predecessor.
        if segments.count >= 2, let last, let prev = segments.dropLast().last {
            let gap = last.start - prev.end
            if gap > gapThresholdS && outroPhrases.contains(depunctuate(lastText)) {
                reasons.append(reasonOutroFillerAfterGap)
            }
            if last.noSpeechProb > nospeechTrigger || last.avgLogprob < logprobTrigger {
                reasons.append(reasonLowConfidenceTail)
            }
        }

        if last != nil {
            let tokens = whitespaceTokens(lastText)
            if tokens.count >= 2 && tokens.count <= doubledTokenMaxWords
                && loweredScalarsEqual(tokens[tokens.count - 1], tokens[tokens.count - 2]) {
                reasons.append(reasonDoubledToken)
            }
            if hasRepeatRun(tokens, minRun: repeatLoopMinRun) {
                reasons.append(reasonRepeatLoop)
            }
            let stripped = pythonStrip(lastText)
            if !stripped.isEmpty && isPunctuationOnly(stripped) {
                reasons.append(reasonLonePunctuationTail)
            }
        }

        // cleanup_added_suffix is segment-independent, and uses exact scalar
        // (code point) equality/prefix/length, never Swift String's canonical
        // equivalence or grapheme counts.
        let finalScalars = Array(finalText.unicodeScalars)
        let rawScalars = Array(rawText.unicodeScalars)
        if !scalarArraysEqual(finalScalars, rawScalars)
            && scalarHasPrefix(finalScalars, prefix: rawScalars)
            && finalScalars.count > rawScalars.count {
            reasons.append(reasonCleanupAddedSuffix)
        }

        return reasons
    }

    /// App-enforced cut-acceptance rules. The judge only proposes `junkSuffix`; this function is
    /// the only thing allowed to decide whether the proposal is safe to act on.
    /// Real contract: `core.accept_cut` in `core.py`.
    static func acceptCut(
        text: String,
        junkSuffix: String,
        boundaries: [Int]? = nil,
        maxWords: Int = 8,
        maxShare: Double = 0.4
    ) -> (Bool, String) {
        let textScalars = Array(text.unicodeScalars)
        let suffixScalars = Array(junkSuffix.unicodeScalars)

        // Rule 1: cutting the whole take is never allowed.
        if scalarArraysEqual(textScalars, suffixScalars) {
            return (false, refusalWholeText)
        }

        // Rule 2: the proposal must be an exact trailing suffix. A substring that
        // occurs anywhere else is an attempted body edit, which is a stronger
        // violation than unrelated non-suffix noise.
        if !scalarHasSuffix(textScalars, suffix: suffixScalars) {
            if !suffixScalars.isEmpty && scalarContains(textScalars, substring: suffixScalars) {
                return (false, refusalBodyEdit)
            }
            return (false, refusalNotSuffix)
        }

        let cutPoint = textScalars.count - suffixScalars.count

        // Rule 3: the cut must land on a token/word boundary, unless it is a known
        // segment boundary from the daemon's diagnostics. Both neighbours are
        // classified as individual scalars, exactly like Python's per-code-point
        // `str.isalnum()`.
        var splitsToken = false
        if cutPoint > 0 && cutPoint < textScalars.count {
            splitsToken = isAlnumScalar(textScalars[cutPoint - 1])
                && isAlnumScalar(textScalars[cutPoint])
        }
        let onBoundary = !splitsToken || (boundaries != nil && boundaries!.contains(cutPoint))
        if !onBoundary {
            return (false, refusalMidWord)
        }

        // Rule 4: a suffix is short by definition.
        let junkWords = whitespaceTokens(junkSuffix).count
        if junkWords > maxWords {
            return (false, refusalTooManyWords)
        }

        // Rule 5: never remove a large share of the take.
        let textWords = whitespaceTokens(text).count
        if Double(junkWords) / Double(max(1, textWords)) > maxShare {
            return (false, refusalShareTooHigh)
        }

        // Rule 6: at least one non-empty, word-bearing sentence must remain.
        let remainder = pythonStrip(stringFromScalars(textScalars[0..<cutPoint]))
        if remainder.isEmpty {
            return (false, refusalNoSentenceRemains)
        }
        var remainderHasAlnum = false
        for scalar in remainder.unicodeScalars where isAlnumScalar(scalar) {
            remainderHasAlnum = true
            break
        }
        if !remainderHasAlnum {
            return (false, refusalNoSentenceRemains)
        }

        return (true, accepted)
    }

    // MARK: - Unicode-scalar string arithmetic
    //
    // Python's `str` indexes, counts, compares, and searches by exact Unicode
    // code point (== Unicode scalar). Swift's `String` does neither: `count`,
    // `prefix`, `suffix`, and slicing use grapheme clusters, and `==`,
    // `.hasSuffix`, `.hasPrefix`, and `.contains` use canonical equivalence.
    // Every decision above therefore works on `Array(text.unicodeScalars)`,
    // where `Unicode.Scalar` equality is exact scalar-value equality and no
    // normalization happens.

    private static func scalarArraysEqual(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        a == b
    }

    private static func scalarHasPrefix(
        _ text: [Unicode.Scalar], prefix: [Unicode.Scalar]
    ) -> Bool {
        guard prefix.count <= text.count else { return false }
        for i in 0..<prefix.count where text[i] != prefix[i] { return false }
        return true
    }

    private static func scalarHasSuffix(
        _ text: [Unicode.Scalar], suffix: [Unicode.Scalar]
    ) -> Bool {
        guard suffix.count <= text.count else { return false }
        let offset = text.count - suffix.count
        for i in 0..<suffix.count where text[offset + i] != suffix[i] { return false }
        return true
    }

    /// Manual, Foundation-free substring scan: true iff `substring` occurs at
    /// any start index of `text` as an exact scalar-for-scalar slice.
    private static func scalarContains(
        _ text: [Unicode.Scalar], substring: [Unicode.Scalar]
    ) -> Bool {
        if substring.isEmpty { return true }
        guard substring.count <= text.count else { return false }
        let lastStart = text.count - substring.count
        for start in 0...lastStart {
            var matched = true
            for j in 0..<substring.count where text[start + j] != substring[j] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private static func stringFromScalars<S: Sequence>(_ scalars: S) -> String
    where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func isWhitespaceScalar(_ scalar: Unicode.Scalar) -> Bool {
        Character(scalar).isWhitespace
    }

    /// Python `str.strip()` equivalent at scalar granularity.
    private static func pythonStrip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end && isWhitespaceScalar(scalars[start]) { start += 1 }
        while end > start && isWhitespaceScalar(scalars[end - 1]) { end -= 1 }
        return stringFromScalars(scalars[start..<end])
    }

    /// Python `\w`: a letter, a number, or the underscore. Classified per
    /// scalar so a bare combining mark (its own code point is not `\w`) is
    /// stripped even when it sits on a base letter in the same grapheme.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        let character = Character(scalar)
        return character.isLetter || character.isNumber
    }

    /// Python `str.isalnum()` at scalar granularity.
    private static func isAlnumScalar(_ scalar: Unicode.Scalar) -> Bool {
        let character = Character(scalar)
        return character.isLetter || character.isNumber
    }

    /// `_PUNCT_ONLY = ^[^\w]+$`: non-empty and every scalar is a non-word scalar.
    private static func isPunctuationOnly(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where isWordScalar(scalar) { return false }
        return true
    }

    /// `_depunctuate`: keep only scalar word characters and whitespace, lower,
    /// strip.
    private static func depunctuate(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) || isWhitespaceScalar(scalar) {
                kept.append(scalar)
            }
        }
        return pythonStrip(String(kept)).lowercased()
    }

    /// Python `str.split()` (no argument): split on scalar whitespace runs,
    /// dropping empty tokens.
    private static func whitespaceTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isWhitespaceScalar(scalar) {
                if !current.isEmpty {
                    tokens.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    private static func loweredScalarsEqual(_ a: String, _ b: String) -> Bool {
        scalarArraysEqual(Array(a.lowercased().unicodeScalars), Array(b.lowercased().unicodeScalars))
    }

    private static func hasRepeatRun(_ tokens: [String], minRun: Int) -> Bool {
        guard !tokens.isEmpty else { return false }
        var run = 1
        var i = 1
        while i < tokens.count {
            if loweredScalarsEqual(tokens[i], tokens[i - 1]) {
                run += 1
                if run >= minRun { return true }
            } else {
                run = 1
            }
            i += 1
        }
        return false
    }

    /// Build the observe-only log record. MUST NEVER contain dictation text or any substring of it.
    ///
    /// Real contract (extends `core.observe_record`; `core.py` has no Swift-only cleanup-level
    /// concept to port, so this is this port's own addition, not a parity gap): beyond the
    /// `core.py`-mirrored keys, the record carries three SOURCE ATTRIBUTION fields, each derived
    /// only from `reasons`/`cleanupLevel` -- text-free by construction, answering Ben's design-note
    /// fork 1 ("is the gibberish Whisper's tail, the cleanup model's, or both?") with data:
    ///   - `tail_in_raw` (Bool): `true` iff `reasons` contains any reason OTHER than
    ///     `reasonCleanupAddedSuffix` -- i.e. the raw Whisper decode/segments themselves triggered.
    ///   - `tail_added_by_cleanup` (Bool): `true` iff `reasons` contains `reasonCleanupAddedSuffix`.
    ///   - `cleanup_level` (String): `cleanupLevel` passed straight through, verbatim, from the
    ///     fixed vocabulary above (`cleanupLevelNone`/`l1`/`l2`/`l3`) -- never free text.
    static func observeRecord(
        text: String,
        reasons: [String],
        verdict: String,
        junkSuffixLen: Int,
        latencyMs: Double,
        judgeName: String,
        cleanupLevel: String = cleanupLevelNone
    ) -> [String: Any] {
        var tailInRaw = false
        var tailAddedByCleanup = false
        for reason in reasons {
            if reason == reasonCleanupAddedSuffix {
                tailAddedByCleanup = true
            } else {
                tailInRaw = true
            }
        }
        return [
            "text_len": text.unicodeScalars.count,
            "reasons": reasons,
            "verdict": verdict,
            "junk_suffix_len": junkSuffixLen,
            "latency_ms": latencyMs,
            "judge_name": judgeName,
            "tail_in_raw": tailInRaw,
            "tail_added_by_cleanup": tailAddedByCleanup,
            "cleanup_level": cleanupLevel,
        ]
    }

    /// Derive the judge's bounded context from the text preceding the suspicious tail. Mirrors
    /// `core.py`'s `_bound_context` exactly: last `maxContextSentences` sentences, then truncated
    /// to the trailing `maxContextChars` characters (the END nearest the tail, never the start).
    /// This is pure string arithmetic with no judge/accuracy concern, faithfully porting the Python
    /// reference, which already has this exact behavior GREEN today (`test_core.py`'s
    /// `test_check_bounds_context_to_last_two_sentences_and_a_char_cap`).
    static func boundedContext(preceding: String) -> String {
        let trimmed = preceding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sentences = sentenceSplitKeepingTerminators(trimmed)
        guard !sentences.isEmpty else { return "" }
        var context = sentences.suffix(maxContextSentences).joined(separator: " ")
        if context.count > maxContextChars {
            context = String(context.suffix(maxContextChars))
        }
        return context
    }

    /// Mirrors `core.py`'s `_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")`: splits after a
    /// sentence terminator followed by whitespace, keeping the terminator attached to the sentence
    /// it ends (unlike `String.components(separatedBy:)`, which would discard it).
    private static func sentenceSplitKeepingTerminators(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<=[.!?])\\s+") else { return [text] }
        let fullRange = NSRange(text.startIndex..., in: text)
        var pieces: [String] = []
        var cursor = text.startIndex
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            let piece = String(text[cursor..<matchRange.lowerBound])
            if !piece.isEmpty { pieces.append(piece) }
            cursor = matchRange.upperBound
        }
        let tail = String(text[cursor...])
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.isEmpty ? [text] : pieces
    }

    /// Derive `(tail, preceding)` from `text`/`rawText`/`segments`/already-computed `reasons`.
    /// Mirrors `core.py`'s `check()` steps exactly (the only two shapes there are): when `reasons`
    /// is `[reasonCleanupAddedSuffix]` alone, the tail is the cleanup-added suffix with no segment
    /// covering it; otherwise the tail is the last segment's raw text. Pure string arithmetic, same
    /// reasoning as `boundedContext` above -- implemented for real.
    static func tailAndPreceding(
        text: String, rawText: String, segments: [Segment], reasons: [String]
    ) -> (tail: String, preceding: String) {
        if reasons == [reasonCleanupAddedSuffix] {
            let tail = String(text.dropFirst(min(rawText.count, text.count)))
            return (tail, rawText)
        }
        let tail = segments.last?.rawText ?? ""
        let precedingLength = max(0, text.count - tail.count)
        let preceding = String(text.prefix(precedingLength))
        return (tail, preceding)
    }
}

/// Judge-agnostic answer, mirroring `core.py`'s `{"tail": "clean"}` / `{"tail": "junk",
/// "junk_suffix": s}` wire shape as a typed value.
extension TailCheck {
    struct JudgeAnswer: Equatable {
        let isJunk: Bool
        let junkSuffix: String

        static let clean = JudgeAnswer(isJunk: false, junkSuffix: "")
        static func junk(_ suffix: String) -> JudgeAnswer { JudgeAnswer(isJunk: true, junkSuffix: suffix) }
    }
}

/// Judge seam (2026-10-06 scope addition, part B). Completion-handler-shaped, matching this
/// codebase's existing LLM-client idiom (`CleanupClient.cleanupSync`, `SearchClient`, ...) rather
/// than introducing `async`/`await` as a first for this file. `nil` in a `.success` answer means
/// "no well-formed verdict, treat as clean" (mirrors `core.py`'s "anything that is not a
/// well-formed junk answer is treated as clean"); `.failure` means the judge threw.
///
/// The caller (`TailCheckObserver`) enforces its own hard wall-clock bound around this call --
/// `timeoutMs` is advisory to the judge, never load-bearing by itself, exactly like `core.py`'s
/// `ThreadPoolExecutor(...).result(timeout=...)` not actually killing a slow judge's thread.
protocol TailJudge {
    func judge(
        context: String, tail: String, timeoutMs: Int,
        completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void
    )
}

/// Production default `TailJudge` (part B): resolves `ModelsPowerSettings.resolveRoute(.custom(Self
/// .routeName), ...)` to an ALREADY-INSTALLED local LM Studio/Ollama model; installs nothing and
/// cold-loads nothing beyond the transport's own `prepare*` for that app.
///
/// LOCAL ONLY, hard rule: unless the resolution is `resolution.bundle?.provider == .local`, `judge`
/// answers `.success(nil)` with zero calls to `transport` (dictation text must never leave the Mac;
/// a claude/codex/none resolution answers clean). Otherwise it sends exactly one non-streaming chat
/// request whose single `user` message is the bounded `context` plus the `tail` and nothing else,
/// through the same injected `LocalChatTransport` every local route uses (`ollamaChat` for Ollama,
/// `sendLMStudio` for LM Studio), and parses the documented `{"tail":"clean"}` / `{"tail":"junk",
/// "junk_suffix":...}` wire shape. Anything malformed, non-local, not-ready or failed answers clean
/// (`.success(nil)`); a transport error answers `.failure`. The caller's own hard wall clock still
/// fails open on a cold or slow model.
final class LocalRouteTailJudge: TailJudge {
    /// The route this judge resolves through `routeResolver()` is
    /// `LLMRouteID.custom(Self.routeName)`; `LLMRouteID` stays untouched (its `custom(String)` case
    /// already covers this without adding a case to that closed, widely-switched-over enum).
    static let routeName = "tailCheck"

    /// Injectable so a test can resolve to any provider (or "off") without touching
    /// `Settings.modelsPower`'s real, persisted state. Default is the real app call.
    private let routeResolver: () -> LLMRouteResolution
    /// Injectable so a test can spy on / fake the local chat call without a real LM Studio/Ollama
    /// process running. NO DEFAULT (vdtpwg2 repair, part A): a default value here would let any new
    /// construction site silently inherit a real, network-capable transport without anyone choosing
    /// that -- a construction-time proof, not a runtime spy. The production call site (this class's
    /// only caller inside the app, `TailCheckObserver`'s own `judge` default below) still gets the
    /// real local transport by default; injection stays a test seam.
    private let transport: LocalChatTransport

    init(
        routeResolver: @escaping () -> LLMRouteResolution = {
            Settings.modelsPower.resolveRoute(.custom(LocalRouteTailJudge.routeName))
        },
        transport: LocalChatTransport
    ) {
        self.routeResolver = routeResolver
        self.transport = transport
    }

    func judge(
        context: String, tail: String, timeoutMs: Int,
        completion: @escaping (Result<TailCheck.JudgeAnswer?, Error>) -> Void
    ) {
        let resolution = routeResolver()
        // Local only: a cloud/off resolution is answered clean without touching any transport, so
        // dictation text can never leave the Mac on this path.
        guard let bundle = resolution.bundle, bundle.provider == .local else {
            completion(.success(nil))
            return
        }
        let ref = bundle.localRef
        let requestTimeout = Double(max(0, timeoutMs)) / 1000.0
        let body = Self.requestBody(ref: ref, context: context, tail: tail)

        if ref.backend == .ollama {
            switch transport.ollamaChat(ref, body: body, profile: .tailCheck, timeout: requestTimeout) {
            case .notReady:
                completion(.success(nil))
            case .response(let data, let response, let error, _):
                completion(Self.answer(data: data, response: response, error: error, tail: tail))
            }
            return
        }

        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.success(nil))
            return
        }
        var request = URLRequest(url: Settings.searchEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<TailCheck.JudgeAnswer?, Error> = .success(nil)
        transport.sendLMStudio(request) { data, response, error in
            outcome = Self.answer(data: data, response: response, error: error, tail: tail)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + requestTimeout)
        completion(outcome)
    }

    /// The one chat body this surface ever sends: a short fixed system line, and exactly one `user`
    /// message carrying the bounded context followed by the tail and nothing else.
    private static func requestBody(ref: LocalModelRef, context: String, tail: String) -> [String: Any] {
        [
            "model": ref.modelID,
            "messages": [
                ["role": "system", "content": "Reply with JSON only: {\"tail\":\"clean\"} or "
                    + "{\"tail\":\"junk\",\"junk_suffix\":\"...\"}."],
                ["role": "user", "content": context + tail],
            ],
            "temperature": 0.0,
            "max_tokens": 128,
            "stream": false,
        ]
    }

    /// Classify one transport response. A transport error or a non-2xx status fails; every other
    /// miss (no data, a non-JSON body, a shape that is not the documented wire object, an empty or
    /// non-trailing `junk_suffix`) answers clean, so a confused model can only ever fail open.
    private static func answer(
        data: Data?, response: URLResponse?, error: Error?, tail: String
    ) -> Result<TailCheck.JudgeAnswer?, Error> {
        if let error { return .failure(error) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failure(NSError(domain: "tailcheck", code: http.statusCode))
        }
        guard let data, let object = answerObject(from: data) else { return .success(nil) }
        guard (object["tail"] as? String) == "junk",
              let suffix = object["junk_suffix"] as? String, !suffix.isEmpty,
              tail.hasSuffix(suffix)
        else { return .success(nil) }
        return .success(.junk(suffix))
    }

    /// The documented wire object, whether the transport handed it back directly or wrapped it in an
    /// OpenAI-shaped `choices[0].message.content` / Ollama-shaped `message.content` string. Tolerates
    /// surrounding whitespace and one fenced code block.
    private static func answerObject(from data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if root["tail"] != nil { return root }
        if let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return parseWireObject(content)
        }
        if let content = (root["message"] as? [String: Any])?["content"] as? String {
            return parseWireObject(content)
        }
        return nil
    }

    /// Parse a model-authored string as the wire object, dropping one surrounding Markdown fence.
    private static func parseWireObject(_ text: String) -> [String: Any]? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            if let newline = body.firstIndex(of: "\n") {
                body = String(body[body.index(after: newline)...])
            } else {
                body = String(body.dropFirst(3))
            }
            if let closing = body.range(of: "```", options: .backwards) {
                body = String(body[..<closing.lowerBound])
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        else { return nil }
        return object
    }
}

/// HUD flag seam (2026-10-06 scope addition, part C). Called ONLY when the trigger fired AND the
/// judge said junk AND `TailCheck.acceptCut` would accept the proposed suffix -- never when any one
/// of those three does not hold. `suspectedSuffix` is for display only; implementations must never
/// use it to edit anything the dictation path pastes.
protocol TailCheckFlagPresenting {
    func showFlag(suspectedSuffix: String)
}

/// Inert default/test presenter: shows nothing. It is what a `TailCheckObserver` built without an
/// explicit presenter gets, so observation can run with no HUD wired at all.
final class NullTailCheckFlagPresenter: TailCheckFlagPresenting {
    func showFlag(suspectedSuffix: String) {}
}

/// The real HUD presenter (part C): truncates the suspected suffix to `maxDisplaySuffixLength` and
/// hands it to the injected display sink on the MAIN thread (synchronously when already there,
/// otherwise `DispatchQueue.main.async`). Display only -- it never touches `NSPasteboard`, never
/// edits text, and never blocks the caller.
final class RealTailCheckFlagPresenter: TailCheckFlagPresenting {
    /// What `showFlag` hands the suspected suffix to, already truncated to `maxDisplaySuffixLength`.
    /// Injectable so a test can spy without a real `HUDPanel`/`NSPanel`.
    typealias DisplaySink = (String) -> Void

    /// The short display length `showFlag` truncates `suspectedSuffix` to before handing it to
    /// `sink` -- one source of truth for the `hud-flag-real` arm, not a magic number duplicated into
    /// the test.
    static let maxDisplaySuffixLength = 60

    private let sink: DisplaySink

    init(sink: @escaping DisplaySink = { _ in }) {
        self.sink = sink
    }

    func showFlag(suspectedSuffix: String) {
        let truncated = String(suspectedSuffix.prefix(Self.maxDisplaySuffixLength))
        if Thread.isMainThread {
            sink(truncated)
        } else {
            DispatchQueue.main.async { self.sink(truncated) }
        }
    }
}

/// The seam the dictation path calls after delivery (2026-10-06 GW scope, part D). The caller is
/// `DictationController`'s `finalize` finish tail -- the paste/delivery callback itself -- per the
/// design note's "the paste never waits on the judge", so `call` must return as fast as a plain
/// function call: never run `TailCheckObserver.observe`/the judge on the calling thread, and never
/// block the caller on that work finishing.
protocol TailCheckDictationHook {
    func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String)
}

/// Production default (part D). Wraps a `TailCheckObserver` -- the work a real `call` dispatches --
/// so a test can inject any judge (including a slow one) through the exact constructor shape a real
/// implementation has. `call` dispatches `observer.afterFinalText` onto a dedicated utility-QoS
/// serial queue and returns immediately, so the paste/delivery path never waits on the observe+judge
/// work and a failure inside it never reaches the caller.
final class NullTailCheckDictationHook: TailCheckDictationHook {
    private let observer: TailCheckObserver
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("tailcheck-observe"), qos: .utility)

    init(observer: TailCheckObserver = TailCheckObserver()) {
        self.observer = observer
    }

    func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String) {
        queue.async {
            self.observer.afterFinalText(finalText, segments: segments, rawText: rawText,
                                         cleanupLevel: cleanupLevel)
        }
    }
}

/// The seam the dictation path calls after final text has been delivered (Phase 1, observe-only).
/// `DictationController.finalize` reaches it from its shared finish tail, strictly after delivery
/// and never on the paste's critical path -- the paste does not wait on it. Gated by
/// `Settings.tailCheckEnabled`.
///
/// By construction, Phase 1 never edits what gets pasted: `afterFinalText` always returns `text`
/// unchanged, whether or not observation is enabled and regardless of what the judge, the presenter
/// or the sink do with the record -- exactly what the `paste-unchanged` arm pins.
final class TailCheckObserver {
    /// Injectable sink: given one already-JSON-encoded line (no trailing newline), do whatever the
    /// caller wants with it. The production default is `defaultSink` below.
    typealias Sink = (String) -> Void

    private let sink: Sink
    private let judge: TailJudge
    private let presenter: TailCheckFlagPresenting
    let judgeTimeoutMs: Int

    /// `TailCheckObserver.init`'s own default for `judgeTimeoutMs` (design note: "gives up after
    /// 400 ms"), named so an arm can pin it directly. Closes `vdtpga-GQ.md` hole H2: "the literal `400`
    /// ms production default is never pinned by name in any arm... a silent edit of that default would
    /// pass every arm today." `judge-timeout-pinned` asserts this constant's value directly, and that
    /// `TailCheckObserver()`'s own `judgeTimeoutMs` is exactly this constant, not a second, drifted copy.
    static let defaultJudgeTimeoutMs = 400

    init(
        sink: @escaping Sink = TailCheckObserver.defaultSink,
        judge: TailJudge = LocalRouteTailJudge(transport: .live),
        presenter: TailCheckFlagPresenting = NullTailCheckFlagPresenter(),
        judgeTimeoutMs: Int = TailCheckObserver.defaultJudgeTimeoutMs
    ) {
        self.sink = sink
        self.judge = judge
        self.presenter = presenter
        self.judgeTimeoutMs = judgeTimeoutMs
    }

    /// Default production sink target: one JSON line per dictation, appended, size-bounded.
    /// `Application Support/ViddyDictate/tailcheck-observe.jsonl` (see `AppPaths.applicationSupportDirectory`).
    static let defaultLogFileName = "tailcheck-observe.jsonl"

    /// The size bound `defaultSink` enforces on the observe log (bytes). Named here so the
    /// `observe-log-bounded` arm has a single source of truth to assert against, not a magic number
    /// duplicated into the test.
    static let defaultLogMaxBytes = 1_000_000

    /// Append one already-encoded observe line to the size-bounded JSONL log at
    /// `defaultLogFileName`. A single line that cannot fit is dropped; when appending would cross
    /// the bound the live file rotates to `.1`, and if that rotation cannot complete cleanly the
    /// line is dropped rather than appended past the bound.
    static func defaultSink(_ line: String) {
        let fm = FileManager.default
        let dir = AppPaths.ensureApplicationSupportDirectory()
        let path = dir.appendingPathComponent(defaultLogFileName)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        let limit = defaultLogMaxBytes

        // A single line that cannot fit is dropped outright: appending it would
        // put the live file past the bound with no rotation able to help.
        if data.count > limit { return }

        let currentSize: Int
        if let attributes = try? fm.attributesOfItem(atPath: path.path),
           let size = attributes[.size] as? NSNumber {
            currentSize = size.intValue
        } else {
            currentSize = 0
        }

        if currentSize > 0 && currentSize + data.count > limit {
            // Rotation is required. Only proceed if BOTH the remove of the old
            // `.1` and the move of the live file actually succeeded, and re-check
            // the live path afterward as ground truth: a `try?` that returns
            // without throwing is NOT proof the file is gone. If rotation did not
            // leave the old live path clear, drop the line rather than append past
            // the bound.
            let rotatedPath = dir.appendingPathComponent(defaultLogFileName + ".1")
            var removeSucceeded = true
            if fm.fileExists(atPath: rotatedPath.path) {
                do { try fm.removeItem(at: rotatedPath) } catch { removeSucceeded = false }
            }
            var moveSucceeded = false
            if removeSucceeded {
                do {
                    try fm.moveItem(at: path, to: rotatedPath)
                    moveSucceeded = true
                } catch {
                    moveSucceeded = false
                }
            }
            if !removeSucceeded || !moveSucceeded || fm.fileExists(atPath: path.path) {
                return
            }
        }

        if !fm.fileExists(atPath: path.path) {
            guard fm.createFile(atPath: path.path, contents: nil, attributes: nil) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    /// Compute the observe record for one dictation. Runs the judge (bounded by
    /// `callJudgeWithHardTimeout`) and, only when it answers junk with a suffix `acceptCut` accepts,
    /// asks the presenter to flag it. Never edits the text.
    func observe(
        text: String, segments: [TailCheck.Segment], rawText: String,
        cleanupLevel: String = TailCheck.cleanupLevelNone
    ) -> [String: Any] {
        let started = DispatchTime.now()
        let reasons = TailCheck.trigger(segments: segments, rawText: rawText, finalText: text)
        var verdict = reasons.isEmpty ? "no_trigger" : "triggered"
        var judgeNameForRecord = "none"
        var junkSuffixLen = 0

        if !reasons.isEmpty {
            let (tail, preceding) = TailCheck.tailAndPreceding(
                text: text, rawText: rawText, segments: segments, reasons: reasons)
            let context = TailCheck.boundedContext(preceding: preceding)
            judgeNameForRecord = String(describing: type(of: judge))
            switch TailCheckObserver.callJudgeWithHardTimeout(
                judge, context: context, tail: tail, timeoutMs: judgeTimeoutMs
            ) {
            case .timeout:
                verdict = "timeout"
            case .error:
                verdict = "error"
            case .answer(let answer):
                guard let answer, answer.isJunk else {
                    verdict = "clean"
                    break
                }
                verdict = "junk"
                junkSuffixLen = answer.junkSuffix.count
                let (accepted, _) = TailCheck.acceptCut(text: text, junkSuffix: answer.junkSuffix)
                if accepted {
                    presenter.showFlag(suspectedSuffix: answer.junkSuffix)
                }
            }
        }

        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000.0
        return TailCheck.observeRecord(
            text: text, reasons: reasons, verdict: verdict, junkSuffixLen: junkSuffixLen,
            latencyMs: latencyMs, judgeName: judgeNameForRecord, cleanupLevel: cleanupLevel)
    }

    /// The dictation-path seam. Returns the text to paste -- ALWAYS `text` itself in Phase 1, by
    /// construction, whether `enabled` is `true` or `false`, and regardless of what the judge or
    /// the flag presenter do: this phase may flag, never trim. A failure anywhere in the observe
    /// path must never reach the caller (fail-open into the paste, not into an exception).
    @discardableResult
    func afterFinalText(
        _ text: String, segments: [TailCheck.Segment], rawText: String,
        cleanupLevel: String = TailCheck.cleanupLevelNone, enabled: Bool = true
    ) -> String {
        if enabled {
            let record = observe(text: text, segments: segments, rawText: rawText, cleanupLevel: cleanupLevel)
            if let line = TailCheckObserver.encode(record) {
                sink(line)
            }
        }
        return text
    }

    /// Outcome of the hard-timeout-bounded judge call (distinct from `JudgeAnswer?` so a timeout
    /// and a well-formed "clean" answer are never confused by a caller inspecting only an Optional).
    enum JudgeCallOutcome {
        case answer(TailCheck.JudgeAnswer?)
        case timeout
        case error
    }

    /// Hard wall-clock bound around one judge call, mirroring `core.py`'s
    /// `ThreadPoolExecutor(1).submit(judge.answer, ...).result(timeout=...)`: on timeout or a
    /// thrown error, `check()`'s caller fails open identically either way. Pure concurrency
    /// plumbing (no dictation-content or judge-accuracy concern), and the Python reference already
    /// has this exact behavior GREEN today (`test_fail_open_when_judge_raises` /
    /// `test_fail_open_when_judge_exceeds_timeout`), so it is implemented for real, faithfully
    /// porting the Python reference.
    static func callJudgeWithHardTimeout(
        _ judge: TailJudge, context: String, tail: String, timeoutMs: Int
    ) -> JudgeCallOutcome {
        let sem = DispatchSemaphore(value: 0)
        var outcome: JudgeCallOutcome = .timeout
        DispatchQueue.global().async {
            judge.judge(context: context, tail: tail, timeoutMs: timeoutMs) { result in
                switch result {
                case .success(let answer): outcome = .answer(answer)
                case .failure: outcome = .error
                }
                sem.signal()
            }
        }
        let waitResult = sem.wait(timeout: .now() + .milliseconds(max(0, timeoutMs)))
        if waitResult == .timedOut { return .timeout }
        return outcome
    }

    /// JSON-encodes an observe record. `nil` on any encoding failure -- the seam fails open into
    /// "nothing was logged", never into a crash on the dictation path.
    static func encode(_ record: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Production construction path (vdtpwg2 repair, parts C/D): the ONE place that wires
/// `RealTailCheckFlagPresenter` to a real display sink. `DictationController`'s own `tailCheckHook`
/// default-parameter expression calls `makeDefaultHook` below, never a parallel hand-built copy, so a
/// test driving these two functions directly is driving the real construction path, not a stand-in.
/// `judge` stays overridable (defaulting to the real production judge) so a test can simulate "the
/// judge said junk" without a real LM Studio/Ollama process, or a non-junk answer without touching
/// the judge-resolution pipeline.
extension TailCheckObserver {
    static func makeDefault(
        hudSink: @escaping RealTailCheckFlagPresenter.DisplaySink,
        judge: TailJudge = LocalRouteTailJudge(transport: .live)
    ) -> TailCheckObserver {
        TailCheckObserver(judge: judge, presenter: RealTailCheckFlagPresenter(sink: hudSink))
    }

    static func makeDefaultHook(
        hudSink: @escaping RealTailCheckFlagPresenter.DisplaySink,
        judge: TailJudge = LocalRouteTailJudge(transport: .live)
    ) -> TailCheckDictationHook {
        NullTailCheckDictationHook(observer: makeDefault(hudSink: hudSink, judge: judge))
    }
}
