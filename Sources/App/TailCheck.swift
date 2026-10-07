import Foundation

/// `TailCheck` — the Swift port of `Tools/tailcheck/core.py`'s trigger + cut-acceptance contract
/// (STUB, gate author: vdtpga). Design note: `Projects/viddydictate/notes/
/// trailing-gibberish-check-design-20261003.md`, section 2A (trigger), section 2B (accept-cut
/// rules), and the 2026-10-06 "NEXT: Swift integration plan" (Phase 1, observe-only).
///
/// Every function below is a pure namespace function: no file I/O, no socket, no AppKit, and never
/// a carrier of dictation text into anything that gets logged (`TailCheckObserver` below is the only
/// thing that may write, and only lengths/flags/timings, never text). `core.py`'s docstrings are the
/// real contract; `Tools/tailcheck/parity-fixture.json` (exported FROM core.py) is the oracle this
/// port is measured against, via `TailCheckSelfTest`'s `trigger-parity` / `cutrules-parity` arms.
///
/// This file ships STUBS on purpose: `trigger` always returns `[]`, `acceptCut` always refuses with
/// `"stub"`, `observeRecord` always returns `[:]`. Every arm red against these stubs is expected and
/// traces to exactly one of the three lines below -- a later link (not this one) replaces each stub
/// with the real port, never editing `TailCheckSelfTest.swift` to make the stub pass.
///
/// SCOPE ADDITION (2026-10-06, lane orchestrator + Ben, after GP launched): Phase 1 also carries
/// (A) text-free SOURCE ATTRIBUTION on the observe record (answers Ben's design-note fork 1 with
/// data, never a guess), (B) a judge seam (`TailJudge`) whose production default routes through the
/// app's existing local-model machinery, and (C) a HUD flag seam that may only ever flag, never
/// trim. `TailCheck.trigger`/`acceptCut`/`observeRecord` stay the three stubs above; the new pieces
/// below (`LocalRouteTailJudge.judge`, `NullTailCheckFlagPresenter.showFlag`) are STUBS in the same
/// sense -- "no flag, no judge call" is today's real, observable behavior, not a placeholder that
/// happens to look right.
enum TailCheck {
    /// One entry from the daemon's pre-collapse per-segment diagnostics (see `_clean_segments` in
    /// `viddydictate_whisperd.py`, and the `daemon-diagnostics` arm that will carry these fields
    /// once a later link wires them). Mirrors `core.py`'s segment dict contract field for field.
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

    // --- tunable thresholds (mirrors core.py; a later link tunes against measurement) ----------
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
    /// Named here as the single source of truth `DaemonClient.parseSegments`'s real contract (a later
    /// link, not this one) must use, and what the `daemon-segments-decoded` arm checks a decoded
    /// segment against.
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
    /// Real contract: `core.trigger` in `core.py`. STUB: always `[]`.
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
    /// Real contract: `core.accept_cut` in `core.py`. STUB: always `(false, "stub")`.
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
    /// STUB: always `[:]`, so none of the above is observable yet.
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
    /// This is pure string arithmetic with no judge/accuracy concern, so -- unlike the three named
    /// stubs above -- it is implemented for real, faithfully porting the Python reference, which
    /// already has this exact behavior GREEN today (`test_core.py`'s
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

/// Production default `TailJudge` (STUB, part B): a later link wires this through
/// `ModelsPowerSettings.resolveRoute(.custom(Self.routeName), ...)` -- an ALREADY-INSTALLED local
/// LM Studio/Ollama model; installs nothing. Kev-0.8B is a later go (design note, 2026-10-05
/// update). Mirrors `core.py`'s `KevClient`: a real-shaped placeholder client, never a model call.
///
/// GATE AUTHOR (vdtpwg, part A): `routeResolver`/`transport` below are the real app seams (house
/// rules: "find them, do not invent a new HTTP client") -- `Settings.modelsPower.resolveRoute`, the
/// same call `SearchClient.retrievalModelRef` already makes for `.searchRetrieval`, and
/// `LocalChatTransport`, the same transport `CleanupClient`/`SearchClient` send every local-route
/// request through. Injecting them here is the ONLY change this link makes to this class: `judge()`'s
/// BODY is untouched and never reads either one. STUB: always answers `.success(nil)` with ZERO calls
/// to `transport` -- no judge call happens yet, which is today's real, observable behavior, not a
/// placeholder standing in for a wrong one (the `judge-local-only` guardrail pins this for every
/// resolution, not only a non-local one). A later I3 link replaces the body with: resolve the route;
/// unless `resolution.bundle?.provider == .local`, answer `.success(nil)` with zero transport calls
/// (dictation text must never leave the Mac on any path); otherwise build exactly one request whose
/// user content is `context` + `tail` and nothing else, send it through `transport`, and parse the
/// documented `{"tail":"clean"}` / `{"tail":"junk","junk_suffix":...}` wire shape.
final class LocalRouteTailJudge: TailJudge {
    /// `LLMRouteID.custom(Self.routeName)` once a later link wires the real route; `LLMRouteID`
    /// stays untouched by this gate-author link (its `custom(String)` case already covers this
    /// without adding a case to that closed, widely-switched-over enum).
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
        completion(.success(nil))
    }
}

/// HUD flag seam (2026-10-06 scope addition, part C). Called ONLY when the trigger fired AND the
/// judge said junk AND `TailCheck.acceptCut` would accept the proposed suffix -- never when any one
/// of those three does not hold. `suspectedSuffix` is for display only; implementations must never
/// use it to edit anything the dictation path pastes.
protocol TailCheckFlagPresenting {
    func showFlag(suspectedSuffix: String)
}

/// Production default (STUB, part C): shows nothing. A later link wires the real HUD affordance
/// (a small "possible trailing junk" flag, per the design note's Phase 2 section) once the judge
/// seam above is real and the arms below are green.
final class NullTailCheckFlagPresenter: TailCheckFlagPresenting {
    func showFlag(suspectedSuffix: String) {}
}

/// Real-shaped (non-Null) presenter (STUB, gate author vdtpwg, part C). A later I3 link wires
/// `showFlag`'s body to actually dispatch -- likely through `DictationController`'s own
/// `HUDPanel.toast(...)`, the lightest precedent already used for every other transient dictation-path
/// notice (or a dedicated panel, `PointOfUseOfferPresenter`-style, if that turns out not to fit) --
/// per the design note's "a small 'possible trailing junk' flag with the suspected suffix." STUB:
/// `showFlag` does nothing -- the sink is never called, no main-thread hop happens, and no pasteboard
/// is ever touched, which is today's real, observable behavior (no HUD affordance exists yet), not a
/// placeholder standing in for a wrong one.
final class RealTailCheckFlagPresenter: TailCheckFlagPresenting {
    /// What the real body will hand the suspected suffix to, already truncated to
    /// `maxDisplaySuffixLength`. Injectable so a test can spy without a real `HUDPanel`/`NSPanel`.
    typealias DisplaySink = (String) -> Void

    /// The short display length a later link's real `showFlag` body truncates `suspectedSuffix` to
    /// before handing it to `sink` -- named here so the `hud-flag-real` arm has a single source of
    /// truth to assert against, not a magic number duplicated into the test.
    static let maxDisplaySuffixLength = 60

    private let sink: DisplaySink

    init(sink: @escaping DisplaySink = { _ in }) {
        self.sink = sink
    }

    func showFlag(suspectedSuffix: String) {}
}

/// The seam the dictation path will call once wired (2026-10-06 GW scope, part D -- NOT this link;
/// see `hook-wired`). The caller is the paste/delivery callback itself (`DictationController`'s
/// `finalize`, per the design note's "the paste never waits on the judge"), so `call` must return as
/// fast as a plain function call: never run `TailCheckObserver.observe`/the judge on the calling
/// thread, and never block the caller on that work finishing.
protocol TailCheckDictationHook {
    func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String)
}

/// Production default (STUB, gate author vdtpwg, part D). Wraps a `TailCheckObserver` -- the obvious
/// production shape, since that IS the work a real `call` would dispatch -- so a test can inject any
/// judge (including a slow one) through the exact constructor shape a real implementation will have.
/// `call`'s BODY ignores `observer` entirely and does nothing, synchronously, returning immediately --
/// today's real, observable behavior (nothing calls this yet; see `hook-wired`), not a placeholder
/// standing in for a wrong one. A later I3 link replaces `call`'s body with: dispatch
/// `observer.afterFinalText`'s work onto a background queue and return before that work finishes (see
/// `hook-after-paste`).
final class NullTailCheckDictationHook: TailCheckDictationHook {
    private let observer: TailCheckObserver

    init(observer: TailCheckObserver = TailCheckObserver()) {
        self.observer = observer
    }

    func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String) {}
}

/// The seam the dictation path calls after final text, right before paste (Phase 1: observe-only,
/// no judge, no UI change -- the 2026-10-06 "NEXT: Swift integration plan"). Never wired into
/// `DictationController` by this link; a later "wire" link does that once the arms below are green.
///
/// By construction, Phase 1 never edits what gets pasted: `afterFinalText` always returns `text`
/// unchanged, whether or not observation is enabled and regardless of what the sink does with the
/// record. That guarantee does not depend on `TailCheck.trigger`/`observeRecord` becoming real --
/// it already holds against the stubs today, which is exactly what the `paste-unchanged` arm pins.
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

    /// Size bound a later link's real sink enforces on the observe log (bytes). Named here so the
    /// `observe-log-bounded` arm has a single source of truth to assert against, not a magic number
    /// duplicated into the test.
    static let defaultLogMaxBytes = 1_000_000

    /// STUB: writes nothing. A later link replaces this with the real size-bounded JSONL append
    /// described above; until then every arm that exercises the default sink is red against this
    /// exact no-op, never against a partially-correct writer.
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

    /// Compute the observe record for one dictation, running the judge (bounded, hard-timeout) and
    /// the HUD flag seam when (and only when) `TailCheck.trigger` fired. STUB today: `trigger`
    /// always returns `[]`, so the `if !reasons.isEmpty` branch below never executes -- no judge
    /// call, no flag, exactly "today's real behavior" per the 2026-10-06 scope addition, not a
    /// placeholder standing in for a wrong one.
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
    /// `test_fail_open_when_judge_exceeds_timeout`), so -- unlike the three named stubs -- this is
    /// implemented for real, not stubbed.
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
/// `judge` stays overridable (defaulting to the real production judge, itself still a Phase-1 stub) so
/// a test can simulate "the judge said junk" without also having to make the judge-resolution pipeline
/// real -- that is a different, later link's job (`LocalRouteTailJudge.judge`'s own stub body).
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
