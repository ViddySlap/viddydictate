import Foundation

// VDASK-2: the ask-back review call, pure parts. Foundation-only so the Linux oracle compiles this file
// on its own. Nothing here is wired to a take yet; the app-type glue lives in AskBackReviewRunner.swift.

/// Careful leans toward asking; Fast asks only about things said two ways. The tier changes only the
/// review rules, never the model.
enum AskBackTier: String, CaseIterable {
    case careful
    case fast
}

enum AskBackSource: String, CaseIterable {
    case dictation
    case selection
}

/// Mirrors `CleanupLevel` without depending on it, so this file stays Foundation-only.
enum AskBackLevel: String, CaseIterable {
    case cleanup
    case tighten
    case summarize
}

/// Mirrors `LLMProvider` for the same reason.
enum AskBackProvider: String, CaseIterable {
    case local
    case claude
    case codex
}

struct AskBackSpot: Equatable {
    let quote: String
    let issue: String
    let impact: String
}

struct AskBackQuestion: Equatable {
    let question: String
    let quote: String
    let why: String
    let options: [String]
}

struct AskBackReviewResult: Equatable {
    let spots: [AskBackSpot]
    let questions: [AskBackQuestion]
}

/// The fixed review model per provider (bakeoff picks, 2026-11-13). Never the route's selected bundle.
struct AskBackModel: Equatable {
    let modelID: String
    let effort: String?
}

enum AskBackReview {

    // MARK: models

    static let claudeModelID = "claude-sonnet-5-5"
    static let codexModelID = "gpt-6.1-sol"
    static let codexEffort = "medium"

    /// Same model for both tiers. Local has no review model: no ask-back on a local path in v1.
    static func model(for provider: AskBackProvider) -> AskBackModel? {
        switch provider {
        case .claude: return AskBackModel(modelID: claudeModelID, effort: nil)
        case .codex: return AskBackModel(modelID: codexModelID, effort: codexEffort)
        case .local: return nil
        }
    }

    // MARK: gate

    /// Words are counted exactly as `DictationController.deliver` counts them for `CleanupLogic`:
    /// split on whitespace, count the pieces. (CleanupLogic takes the count as an argument and has no
    /// counting function of its own, so the rule is copied here; a self-test row pins the agreement.)
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static let minWords = 50

    /// The review runs only when ask-back is on, the level is Tighten or Summarize, the provider is
    /// Claude or Codex (never local) and the input has at least 50 words.
    static func gate(wordCount: Int, level: AskBackLevel, provider: AskBackProvider, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard level == .tighten || level == .summarize else { return false }
        guard provider == .claude || provider == .codex else { return false }
        return wordCount >= minWords
    }

    // MARK: prompt

    /// Port of the prototype's `reviewPrompt` (there `tier === "default"` is Careful). `system` holds the
    /// instructions and the reply format; `input` holds the TEXT block. `system + "\n\n" + input` is the
    /// prototype's single string, byte for byte.
    static func reviewPrompt(text: String, level: AskBackLevel, tier: AskBackTier,
                             source: AskBackSource) -> (system: String, input: String) {
        let tighten = level == .tighten
        let careful = tier == .careful
        let subject = source == .selection ? "a piece of selected text" : "a raw voice-dictation transcript"
        let verb = tighten ? "tightened" : "summarized"
        var system = "You review " + subject + " before it gets " + verb + ". Your only job here is to find what the writer would have to GUESS. Do not rewrite or summarize it.\n\nList every spot where (a) two statements pull in different directions, (b) the speaker changed their mind and the final position is not stated, (c) a request is too vague to act on, or (d) 'this', 'that', 'it', 'the previous one' could mean two different things. For each, say how much a wrong guess would change the result (high, medium, low).\n\n"
        if careful {
            system += "Careful mode: the speaker wants to be grilled, so lean toward asking. When in doubt, ask. But never ask about things the reader can see while reading (what is on screen, screenshots, 'this spot', 'the thing', an icon they point at) or about a word that is probably a speech-to-text slip; the reader settles those. Ask about what only the speaker knows: what they want, which of two things they said they meant, what they finally decided. Skip questions only when the text is truly clear throughout. A short take (a few sentences) rarely needs a question; only ask there if it plainly contradicts itself. Ask up to " + (tighten ? "1" : "3") + ". Count as a reason to ask anything they leaned two ways on and never clearly settled, places they went in circles, and any choice where your guess would change the result. Most important first. "
        } else {
            system += "Rules for questions. Ask ONLY about something the speaker said two ways, took back without a clear final answer, or referred to so that it could mean two different things. Never ask about: decisions the speaker did not raise (scope, length, formats, next steps they never mentioned); things the reader can see (screenshots, what is on screen, 'this view'); things the reader can settle later on their own. Most takes need zero or one question; zero is a normal, good answer. Never ask just to fill the quota. "
            system += tighten
                ? "Then turn at most ONE spot into a question, and only if it is a high-impact contradiction or reversal (a or b). Otherwise ask nothing."
                : "Then ask about the high-impact spots that pass these rules, at most 3, most important first."
        }
        system += " Each question covers a different topic: if two spots are about the same thing, ask ONE question that settles both. Each question is one short sentence, with 2 to 4 answer options of 2 to 5 words each (like '5:45 to 6:45', 'Last change wins', 'Doesn't matter'), most likely answer first, a \"quote\" field with the speaker's exact words from the text that the question is about (copied verbatim, under 25 words), and a one-line why. The speaker reads them in a second and picks by tapping a key, so keep them short and clearly different.\n\nReply with ONLY JSON, no code fence: {\"spots\":[{\"quote\":\"...\",\"issue\":\"...\",\"impact\":\"high|medium|low\"}],\"questions\":[{\"question\":\"...\",\"quote\":\"...\",\"why\":\"...\",\"options\":[\"...\",\"...\"]}]}"
        let input = "TEXT:\n<<<\n" + text + "\n>>>"
        return (system, input)
    }

    // MARK: parse

    static func questionCap(for level: AskBackLevel) -> Int {
        switch level {
        case .summarize: return 3
        case .tighten: return 1
        case .cleanup: return 0   // Cleanup never asks
        }
    }

    /// Lowercase, straight quotes, collapsed whitespace: the form two quotes are compared in.
    static func normalizedForMatch(_ s: String) -> String {
        var t = s.lowercased()
        for c in ["\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}"] {
            t = t.replacingOccurrences(of: c, with: "'")
        }
        for c in ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}"] {
            t = t.replacingOccurrences(of: c, with: "\"")
        }
        return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Byte-identical copy of `CleanupClient.asciiPunctuationNormalized` (that type is not Foundation-only);
    /// the Mac self-test checks the two agree. Both adapters run every reply through it, so the transcript
    /// and the quote are folded with it before they are compared.
    static func asciiPunctuationNormalized(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("\u{2014}", " - "),  // em dash -> spaced hyphen
            ("\u{2015}", " - "),  // horizontal bar -> spaced hyphen
            ("\u{2013}", "-"),    // en dash -> hyphen
            ("\u{2012}", "-"),    // figure dash -> hyphen
            ("\u{2018}", "'"),    // left single quote
            ("\u{2019}", "'"),    // right single quote / apostrophe
            ("\u{201A}", "'"),    // single low-9 quote
            ("\u{201C}", "\""),   // left double quote
            ("\u{201D}", "\""),   // right double quote
            ("\u{201E}", "\""),   // double low-9 quote
            ("\u{2026}", "..."),  // ellipsis
            ("\u{00A0}", " "),    // non-breaking space
            ("\u{2022}", "-"),    // bullet
            ("`", ""),            // markdown backtick -> removed (no-markdown guard; ` is never wanted)
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    /// The transcript in match form (ASCII-folded, lowercase, collapsed whitespace), each folded character
    /// remembering the span of the original it came from, so a match returns the speaker's own words.
    struct FoldedTranscript {
        private let source: String
        private var chars: [Character] = []
        private var starts: [String.Index] = []
        private var ends: [String.Index] = []

        init(_ transcript: String) {
            source = transcript
            var pendingSpace: (String.Index, String.Index)?
            var i = transcript.startIndex
            while i < transcript.endIndex {
                let next = transcript.index(after: i)
                let c = transcript[i]
                // Fold this one character exactly as the quote is folded, keeping the spaces a dash adds.
                for ch in AskBackReview.asciiPunctuationNormalized(String(c)) {
                    if ch.isWhitespace {
                        if !chars.isEmpty { pendingSpace = (pendingSpace?.0 ?? i, next) }
                    } else {
                        if let (s0, e0) = pendingSpace { chars.append(" "); starts.append(s0); ends.append(e0); pendingSpace = nil }
                        for f in AskBackReview.normalizedForMatch(String(ch)) { chars.append(f); starts.append(i); ends.append(next) }
                    }
                }
                i = next
            }
        }

        private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" }

        /// The transcript's own text for the first whole-word occurrence of `needle` (already in match form).
        func find(_ needle: String) -> String? {
            let n = Array(needle)
            guard !n.isEmpty, n.count <= chars.count else { return nil }
            let startsWord = Self.isWordChar(n[0]), endsWord = Self.isWordChar(n[n.count - 1])
            var i = 0
            while i + n.count <= chars.count {
                if chars[i] == n[0] && Array(chars[i..<(i + n.count)]) == n {
                    let leftOK = !startsWord || i == 0 || !Self.isWordChar(chars[i - 1])
                    let j = i + n.count
                    let rightOK = !endsWord || j == chars.count || !Self.isWordChar(chars[j])
                    if leftOK && rightOK { return String(source[starts[i]..<ends[j - 1]]) }
                }
                i += 1
            }
            return nil
        }
    }

    /// The body of the first ``` fence, without its language line, or nil when there is no fence.
    static func fencedBody(in s: String) -> String? {
        guard let open = s.range(of: "```") else { return nil }
        var rest = s[open.upperBound...]
        if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] } else { return nil }
        if let close = rest.range(of: "```") { return String(rest[..<close.lowerBound]) }
        return String(rest)
    }

    /// The first balanced top-level `{...}` in `s`, honoring JSON strings and escapes; nil if none.
    /// `lenient` repairs the bare `"` the adapters leave when the model copied curly double quotes inside a
    /// string (CleanupClient.asciiPunctuationNormalized maps them to `"`): inside a string, a `"` closes it
    /// only when the next non-blank byte is one of `, } ] :`; any other `"` is escaped and kept as text.
    static func firstBalancedObject(in s: String, lenient: Bool = false) -> String? {
        let bytes = Array(s.utf8)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var out: [UInt8] = []
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped { escaped = false; out.append(b) }
                else if b == UInt8(ascii: "\\") { escaped = true; out.append(b) }
                else if b == UInt8(ascii: "\"") {
                    if lenient {
                        var j = i + 1
                        while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D { j += 1 }
                        let closes = j >= bytes.count || [UInt8(ascii: ","), UInt8(ascii: "}"),
                                                           UInt8(ascii: "]"), UInt8(ascii: ":")].contains(bytes[j])
                        if closes { inString = false; out.append(b) }
                        else { out.append(UInt8(ascii: "\\")); out.append(b) }
                    } else {
                        inString = false; out.append(b)
                    }
                } else { out.append(b) }
            } else if b == UInt8(ascii: "\"") {
                inString = true; out.append(b)
            } else if b == UInt8(ascii: "{") {
                depth += 1; out.append(b)
            } else if b == UInt8(ascii: "}") {
                depth -= 1; out.append(b)
                if depth == 0 { return String(decoding: out, as: UTF8.self) }
            } else { out.append(b) }
            i += 1
        }
        return nil
    }

    /// nil on anything invalid. A missing `questions` or `spots` key is an empty list, not nil.
    static func parse(_ reply: String, transcript: String, level: AskBackLevel) -> AskBackReviewResult? {
        func extract(lenient: Bool) -> String? {
            if let body = fencedBody(in: reply) { if let o = firstBalancedObject(in: body, lenient: lenient) { return o } }
            return firstBalancedObject(in: reply, lenient: lenient)
        }
        func decode(_ object: String?) -> [String: Any]? {
            guard let json = object,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
            return parsed as? [String: Any]
        }
        guard let root = decode(extract(lenient: false)) ?? decode(extract(lenient: true)) else { return nil }

        var spots: [AskBackSpot] = []
        if let rawSpots = root["spots"] {
            guard let list = rawSpots as? [Any] else { return nil }
            for entry in list {
                guard let d = entry as? [String: Any] else { continue }
                spots.append(AskBackSpot(quote: d["quote"] as? String ?? "",
                                         issue: d["issue"] as? String ?? "",
                                         impact: d["impact"] as? String ?? ""))
            }
        }

        let folded = FoldedTranscript(transcript)
        var kept: [AskBackQuestion] = []
        var keptQuotes: [String] = []
        if let rawQuestions = root["questions"] {
            guard let list = rawQuestions as? [Any] else { return nil }
            for entry in list {
                guard let d = entry as? [String: Any],
                      let question = d["question"] as? String,
                      !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let quote = d["quote"] as? String else { continue }
                let needle = normalizedForMatch(asciiPunctuationNormalized(quote))
                guard !needle.isEmpty, let spoken = folded.find(needle) else { continue }
                let options = ((d["options"] as? [Any]) ?? [])
                    .compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard options.count >= 2 else { continue }
                guard !keptQuotes.contains(needle) else { continue }
                keptQuotes.append(needle)
                kept.append(AskBackQuestion(question: question, quote: spoken,
                                            why: d["why"] as? String ?? "",
                                            options: Array(options.prefix(4))))
            }
        }
        return AskBackReviewResult(spots: spots, questions: Array(kept.prefix(questionCap(for: level))))
    }
}

// MARK: - review identity

/// What the provider call reports back, free of app types.
enum AskBackProviderReply: Equatable {
    case text(String)
    case timedOut
    case failed(String)
}

/// Exactly one of these is delivered per review id.
enum AskBackOutcome: Equatable {
    case result(AskBackReviewResult)
    case skipped
    case timedOut
    case failed(String)
}

/// Starts reviews and delivers exactly one outcome per review id. The provider's answer, a skip and the
/// timeout all funnel through `finish`, which runs at most once per id: whichever lands first wins, and a
/// late provider answer after a skip or timeout is dropped. The clock and the provider are injected, so
/// tests drive it with a fake clock and a fake provider. `deliver` may run on any thread; the caller hops
/// to main.
final class AskBackReviewRunner {
    typealias ReviewID = UUID
    typealias Cancel = () -> Void
    typealias Schedule = (_ after: TimeInterval, _ fire: @escaping () -> Void) -> Cancel
    typealias Provider = (_ system: String, _ input: String,
                          _ completion: @escaping (AskBackProviderReply) -> Void) -> Void
    typealias Deliver = (ReviewID, AskBackOutcome) -> Void

    private struct Pending {
        let transcript: String
        let level: AskBackLevel
    }

    private let timeout: TimeInterval
    private let schedule: Schedule
    private let provider: Provider
    private let deliver: Deliver
    private let lock = NSLock()
    private var pending: [ReviewID: Pending] = [:]
    private var cancels: [ReviewID: Cancel] = [:]
    private var used: Set<ReviewID> = []
    /// A review in flight keeps its runner alive (released by `finish`), so a caller that drops its
    /// reference still gets exactly one outcome.
    private var retainers: [ReviewID: AskBackReviewRunner] = [:]

    init(timeout: TimeInterval = 90, schedule: @escaping Schedule,
         provider: @escaping Provider, deliver: @escaping Deliver) {
        self.timeout = timeout
        self.schedule = schedule
        self.provider = provider
        self.deliver = deliver
    }

    /// Returns false (and does nothing) when the id was already used.
    @discardableResult
    func start(id: ReviewID = UUID(), text: String, level: AskBackLevel,
               tier: AskBackTier, source: AskBackSource) -> Bool {
        lock.lock()
        guard !used.contains(id) else { lock.unlock(); return false }
        used.insert(id)
        pending[id] = Pending(transcript: text, level: level)
        retainers[id] = self
        lock.unlock()

        let cancel = schedule(timeout) { [weak self] in self?.finish(id, .timedOut) }
        lock.lock()
        if pending[id] != nil { cancels[id] = cancel; lock.unlock() } else { lock.unlock(); cancel() }

        let prompt = AskBackReview.reviewPrompt(text: text, level: level, tier: tier, source: source)
        provider(prompt.system, prompt.input) { [weak self] reply in self?.handle(id, reply) }
        return true
    }

    /// Skip this review: its late provider answer is dropped.
    func skip(_ id: ReviewID) { finish(id, .skipped) }

    private func handle(_ id: ReviewID, _ reply: AskBackProviderReply) {
        lock.lock()
        let entry = pending[id]
        lock.unlock()
        guard let entry = entry else { return }   // already finished: a late answer is dropped
        switch reply {
        case .timedOut:
            finish(id, .timedOut)
        case .failed(let why):
            finish(id, .failed(why))
        case .text(let text):
            if let result = AskBackReview.parse(text, transcript: entry.transcript, level: entry.level) {
                finish(id, .result(result))
            } else {
                finish(id, .failed("unparseable review reply"))
            }
        }
    }

    private func finish(_ id: ReviewID, _ outcome: AskBackOutcome) {
        lock.lock()
        guard pending.removeValue(forKey: id) != nil else { lock.unlock(); return }
        let cancel = cancels.removeValue(forKey: id)
        let keepAlive = retainers.removeValue(forKey: id)
        lock.unlock()
        cancel?()
        deliver(id, outcome)
        withExtendedLifetime(keepAlive) {}
    }
}
