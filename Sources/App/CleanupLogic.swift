import Foundation

/// Pure, side-effect-free decision logic for Cleanup mode, factored out of `DictationController` so
/// it can be unit-tested headlessly (the `--selftest` seam) without audio, the event tap, or the UI.
/// The selftest asserts on these — but check call sites before treating a function here as the
/// executed policy. Notably, the silent-tap skip and the state-at-release guard are NOT here; they
/// are inline one-liners in `DictationController` (`finish()` / `deliver()`).
enum CleanupLogic {

    /// Two-tier undo routing for `right-Option + Z`.
    enum UndoTier: Equatable { case inPlace, clipboard, none }
    static func undoTier(hasPending: Bool, canRevertInPlace: Bool,
                         ageSeconds: TimeInterval, staleAfter: TimeInterval = 25) -> UndoTier {
        guard hasPending else { return .none }
        return (canRevertInPlace && ageSeconds <= staleAfter) ? .inPlace : .clipboard
    }

    /// Length gate for the strength levels. Tighten and Summarize have nothing meaningful to condense
    /// in a short single utterance, where they instead over-compress and drift the meaning (live
    /// evidence: "It's just really starting to boost it." -> "It's really starting to help."). Below
    /// the word threshold we fall back to plain Cleanup (disfluency removal only); at/above it the
    /// selected level applies in full, where Summarize genuinely earns its keep. Cleanup (L0) is never
    /// gated — it is already the gentle floor.
    static func effectiveLevel(for level: CleanupLevel, wordCount: Int,
                               minWordsToCondense: Int = 25) -> CleanupLevel {
        guard level != .cleanup else { return .cleanup }
        return wordCount < minWordsToCondense ? .cleanup : level
    }

    /// Option+P prompt-prep input resolution: prefer the copy-captured SELECTION, fall back to the
    /// clipboard contents, and return nil when both are blank (-> a no-op + toast). The whitespace
    /// trim only decides the blank test; the original text is returned untouched for the transform.
    /// Note: the `?`-path short-utterance length gate (`effectiveLevel`) does NOT apply to Option+P —
    /// the user picked the level explicitly in the panel, so it is honored exactly.
    static func promptPrepInput(selection: String?, clipboard: String?) -> String? {
        if let s = selection, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        if let c = clipboard, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return c }
        return nil
    }

    /// Dual-mode gate for Option+M. Holding right-Option always captures audio, so a take that carried
    /// real speech is ambiguous: either the user dictated an email fresh, or they uttered a stray word
    /// or two while doing a selection transform. More than a couple of dictated words (>= `minWords`)
    /// means a real dictation -> the dictation-email path; at or below it the take is treated as
    /// incidental and the selection path runs instead. Pairs with the controller's `detectedSpeech`
    /// pre-gate, which keeps a purely silent take off the transcribe path entirely.
    static func isDictationEmail(wordCount: Int, minWords: Int = 3) -> Bool {
        wordCount >= minWords
    }

    /// Gate for the web-search modes (Option+L / Option+G). These are dictate-the-question only (V1),
    /// so a take must carry a real spoken question. Two words is the floor ("define onomatopoeia",
    /// "chernobyl year"); below it the take is incidental noise and the chord no-ops with a prompt to
    /// speak the question. Pairs with the controller's `detectedSpeech` pre-gate (a silent take never
    /// reaches the transcribe path).
    static func isSearchQuestion(wordCount: Int, minWords: Int = 2) -> Bool {
        wordCount >= minWords
    }

    /// Sanity guard on cleanup OUTPUT (the prompt-injection backstop). None of the three modes should
    /// ever make the text meaningfully LONGER — Cleanup stays about the same, Tighten shrinks,
    /// Summarize shrinks a lot. So "the model returned noticeably more text than was dictated" is a
    /// clean, level-agnostic signal that it went off the rails (e.g. it answered instead of cleaning:
    /// the live failure was 210 chars in -> 549 out). When this trips, the controller does NOT auto-
    /// paste; it shows the A/B picker so the user chooses raw vs the suspect output. The absolute
    /// margin keeps tiny inputs ("ok thanks" -> "Okay, thanks.") from ever tripping it.
    static func cleanupSuspect(rawCount: Int, cleanedCount: Int,
                               ratio: Double = 1.2, absoluteMargin: Int = 40) -> Bool {
        cleanedCount > Int(Double(rawCount) * ratio) && (cleanedCount - rawCount) > absoluteMargin
    }

    /// Where a take lands given the cleanup attempt's outcome: the cleaned text on success, the raw
    /// transcript on every failure mode (down / timeout / bad output all collapse to raw fallback).
    enum Landing: Equatable { case cleaned, rawFallback }
    static func landing(for result: CleanupClient.Result) -> Landing {
        switch result {
        case .ok: return .cleaned
        case .unavailable, .timedOut, .badOutput: return .rawFallback
        }
    }

    /// Undo-eligibility: a delivered take is revertable by `right-Option + Z` only when a DISTINCT
    /// cleaned/transformed version actually replaced the raw. Raw passthrough (`cleaned == nil`) or a
    /// no-op transform (`cleaned == raw`) has nothing to revert to, so it wires no undo. Centralizes
    /// the policy `finalize` applied inline so it lives on the headlessly unit-tested surface.
    static func isRevertable(raw: String, cleaned: String?) -> Bool {
        guard let cleaned = cleaned else { return false }
        return cleaned != raw
    }

    /// Whether an STT transcript contains anything that can be real dictated content. Foundation's
    /// `alphanumerics` set is Unicode-aware, so letters and digits in every script survive while
    /// punctuation-only output (including typographic and CJK punctuation) is treated as nothing heard.
    static func transcriptHasLettersOrDigits(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.rangeOfCharacter(from: .alphanumerics) != nil
    }

    /// Collapse consecutive repeated word/phrase runs (the classic Whisper loop) to a single copy.
    /// Conservative: only fires on >=3 repeats (>=2 for phrases of >=4 words) so genuine short
    /// repetition ("no no") survives. The daemon is the primary filter; this is a safety net.
    /// Pure, so it lives here on the headlessly unit-tested surface rather than in the stateful
    /// orchestrator.
    static func cleanRepeats(_ s: String) -> String {
        let words = s.split(separator: " ").map(String.init)
        let n = words.count
        if n < 2 { return s }
        let punct = CharacterSet(charactersIn: ".,!?;:")
        let keys = words.map { $0.lowercased().trimmingCharacters(in: punct) }
        var out: [String] = []
        var i = 0
        while i < n {
            var collapsed = false
            var plen = min(6, (n - i) / 2)
            while plen >= 1 {
                var reps = 1
                var j = i + plen
                while j + plen <= n && Array(keys[j..<j + plen]) == Array(keys[i..<i + plen]) {
                    reps += 1; j += plen
                }
                let threshold = plen >= 4 ? 2 : 3
                if reps >= threshold {
                    out.append(contentsOf: words[i..<i + plen])   // keep one copy
                    i = j
                    collapsed = true
                    break
                }
                plen -= 1
            }
            if !collapsed { out.append(words[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }
}
