import Foundation

/// The correction Dictionary (ADR 0002): two hand-authored columns over three correction mechanisms.
///
///  - **Hard-coded replacements** (Layer 1): deterministic find-replace on every fresh STT transcript.
///  - **Context-aware replacements** (Layer 2): a glossary block injected into every post-dictation
///    LLM-pass system prompt (cleanup levels, email, future modes).
///  - **Whisper bias** (Layer 0): a hidden `initial_prompt` derived from BOTH columns' intended forms,
///    carried per-request to the STT daemon. Never a user surface — always mirrors the two columns.
///
/// The store is app-local JSON (parallel to history.json / clipboard-history.json). The transforms are
/// pure + static so they unit-test headlessly (`--selftest`) without touching disk or the network.

/// One correction pair. `heard` is what the transcription produces; `intended` is the right form.
struct CorrectionEntry: Codable, Equatable {
    var heard: String
    var intended: String

    /// A usable entry needs both sides non-blank (blank rows in the editor are ignored, not saved).
    var isUsable: Bool {
        !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !intended.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    /// Posted when the lists change, so any open consumer can refresh. (UI edits + load.)
    static let didChange = Notification.Name("VDDictionaryDidChange")

    private(set) var hardCoded: [CorrectionEntry] = []
    private(set) var contextAware: [CorrectionEntry] = []

    private let url: URL
    private let queue = DispatchQueue(label: "viddydictate.dictionary")

    private init() {
        let dir = AppPaths.ensureApplicationSupportDirectory()
        url = dir.appendingPathComponent("dictionary.json")
        load()
    }

    // MARK: persistence

    private struct Store: Codable { var hardCoded: [CorrectionEntry]; var contextAware: [CorrectionEntry] }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        hardCoded = store.hardCoded
        contextAware = store.contextAware
    }

    /// Replace both lists (the editor hands back the full edited set), drop unusable rows, persist.
    func update(hardCoded newHard: [CorrectionEntry], contextAware newContext: [CorrectionEntry]) {
        hardCoded = newHard.filter { $0.isUsable }
        contextAware = newContext.filter { $0.isUsable }
        let store = Store(hardCoded: hardCoded, contextAware: contextAware)
        queue.async { [url] in
            do { try JSONEncoder().encode(store).write(to: url, options: .atomic) }
            catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "correction dictionary", operation: "save", url: url, error: error)
            }
        }
        NotificationCenter.default.post(name: CorrectionDictionary.didChange, object: nil)
    }

    // MARK: live consumers (used by the pipeline)

    /// Layer 1: run the hard-coded replacements on a fresh transcript.
    func applyHardCoded(_ text: String) -> String {
        CorrectionDictionary.applyHardCoded(text, entries: hardCoded)
    }

    /// Layer 2: the glossary suffix to append to an LLM-pass system prompt ("" when no context entries).
    func contextGlossarySuffix() -> String {
        CorrectionDictionary.contextGlossarySuffix(contextAware)
    }

    /// The single owned way to attach Layer 2 (the context-aware glossary) to a mode's system prompt.
    /// Every post-dictation LLM pass builds its system prompt through this, so a new mode cannot silently
    /// forget the glossary the way search did (review item 6). A no-op suffix when the context column is
    /// empty, so an empty dictionary leaves every prompt byte-identical.
    func augment(_ systemPrompt: String) -> String {
        systemPrompt + contextGlossarySuffix()
    }

    /// Layer 0: the derived whisper `initial_prompt` bias ("" when both columns are empty).
    func whisperBias() -> String {
        CorrectionDictionary.whisperBias(hardCoded: hardCoded, contextAware: contextAware)
    }

    // MARK: - pure transforms (unit-tested)

    /// Layer 1 — deterministic find-replace. **Case-insensitive, whole-word/phrase boundary, no regex
    /// semantics for the user** (they type plain strings; metacharacters are matched literally). The
    /// output is rendered in the intended form's stored casing. Internally we use NSRegularExpression
    /// purely to get reliable word boundaries — every user string is `escapedPattern`-escaped so it is
    /// matched literally, and the replacement is `escapedTemplate`-escaped so a `$` in the intended form
    /// is inserted verbatim. Longer `heard` phrases are applied first so a multi-word fix wins over a
    /// single-word one it contains.
    static func applyHardCoded(_ text: String, entries: [CorrectionEntry]) -> String {
        var out = text
        let usable = entries.filter { $0.isUsable }
            .sorted { $0.heard.count > $1.heard.count }
        for e in usable {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: e.heard) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: e.intended)
            let ns = out as NSString
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
        }
        return out
    }

    /// Layer 2 — the glossary block. A short instruction plus the (heard -> intended) pairs, fenced so
    /// it reads as a vocabulary aid in the SYSTEM prompt (separate from the user's fenced transcript),
    /// never as content. Returns "" when there are no usable context entries (so an empty dictionary is
    /// a perfect no-op on the existing prompts and the golden tests stay deterministic).
    static func contextGlossarySuffix(_ entries: [CorrectionEntry]) -> String {
        let usable = entries.filter { $0.isUsable }
        guard !usable.isEmpty else { return "" }
        let pairs = usable.map { "  \"\($0.heard)\" -> \"\($0.intended)\"" }.joined(separator: "\n")
        return """


        CORRECTION GLOSSARY. The speech-to-text step sometimes mishears certain words or phrases. When \
        the text clearly intends the left form below, substitute the right form; apply each correction \
        only where it fits the meaning, and never force one. Do not mention this glossary in your output.
        \(pairs)
        """
    }

    /// Layer 0 — derive the whisper `initial_prompt` from BOTH columns' INTENDED forms (the correct
    /// vocabulary). Deduped, context-aware forms ordered LAST (whisper weights the tail of the prompt
    /// most, and the context-aware forms are the ones the deterministic pass cannot save). Capped near
    /// whisper's 224-token budget — approximated conservatively by word count — dropping from the FRONT
    /// (the hard-coded proper nouns) when it overflows, so the highest-value terms survive at the tail.
    static func whisperBias(hardCoded: [CorrectionEntry], contextAware: [CorrectionEntry],
                            maxWords: Int = 200) -> String {
        var seen = Set<String>()
        var terms: [String] = []
        // hard-coded intended forms first, context-aware last (tail = highest weight).
        for e in (hardCoded + contextAware) where e.isUsable {
            let term = e.intended.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.lowercased()
            if term.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            terms.append(term)
        }
        guard !terms.isEmpty else { return "" }
        // Trim from the front to honor the budget while keeping the tail (context-aware) terms.
        func wordCount(_ list: [String]) -> Int { list.reduce(0) { $0 + $1.split(separator: " ").count } }
        while terms.count > 1 && wordCount(terms) > maxWords { terms.removeFirst() }
        return "Vocabulary: " + terms.joined(separator: ", ") + "."
    }
}
