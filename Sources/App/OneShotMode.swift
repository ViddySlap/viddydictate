import Foundation

/// How a one-shot mode obtains the text it transforms.
///
/// The three shapes the existing one-shot modes already exhibit — kept as an explicit taxonomy so a
/// mode's acquisition path is a value its method reads, not a branch it re-derives:
///  - `.transcript` acts on the freshly dictated transcript, gated to a real utterance by a word-count
///    floor (web search: dictate-the-question).
///  - `.selection` acts on the current selection (clipboard fallback), with no dictation at all
///    (Option+P Cleanup-selection).
///  - `.transcriptOrSelection` is dual: the dictated transcript when the take carried real speech
///    (>= `minWords`), otherwise the selection (Option+M email).
enum OneShotInput: Equatable {
    case transcript(minWords: Int)
    case selection
    case transcriptOrSelection(minWords: Int)
}

/// Where a one-shot mode's RESULT lands.
///  - `.inPlace` pastes the transformed text back over the selection / at the caret through the piece-2
///    `landInPlaceTransform` tail. `wireUndo` registers the raw word-vomit as the tier-1 smart-undo
///    source (email does; Cleanup-selection does not — native Cmd+Z is enough there).
///  - `.nonDestructive` surfaces the result in a note / HUD and NEVER pastes into the focused field
///    (web search — the answer is read-only, so it keeps a bespoke landing rather than the shared tail).
enum OneShotLanding: Equatable {
    case inPlace(wireUndo: Bool)
    case nonDestructive
}

/// A declarative descriptor for a one-shot mode — the ADR-0008 middle ground made concrete.
///
/// A "one-shot mode" is a chord that runs a single transform-and-land cycle off one activation:
/// Option+M email, Option+L / Option+G web search, Option+P Cleanup-selection. Historically each lived
/// as a bespoke method on `DictationController` that hand-coded the same cross-cutting constants inline
/// - its History taxonomy, its word-count gate floor, whether it acts on the dictated transcript or the
/// current selection, and whether its result pastes in place or lands non-destructively. Adding mode #N
/// meant re-deriving all of that by hand at a fresh call site (the fan-out ADR 0008 catalogued).
///
/// This value type is the ONE place those constants live: a shared SCAFFOLD the per-mode methods
/// consult, NOT a data-driven registry that carries each mode's whole step-sequence as data for a
/// generic dispatcher to iterate. That fuller registry is deferred in ADR 0008 (it needs the God-object
/// split finished first, and only earns its cost when the app is opened to third-party plug-ins). The
/// per-mode methods stay; they just read their structural constants and route-decisions from here
/// instead of hand-coding them. It is introduced here as a pure addition (item-4 piece 3); the migrations
/// that route Cleanup-selection / email / search onto it are pieces 4-6. See ADR 0009 for the shape
/// rationale and why the scaffold lands one piece ahead of its consumers.
///
/// Pure and side-effect-free, so it lives on the headless `--selftest` surface alongside `CleanupLogic`.
struct OneShotMode {
    /// Stable identifier for logs / tests (mirrors `ProcessingMode.id`). Not the History rawValue.
    let id: String
    /// Stable LLM routing identity. Kept separate from the existing log id so A1 does not rewrite logs,
    /// history provenance, hotkeys, or any fixed Option+L/G retrieval behavior.
    let routeID: LLMRouteID
    /// The mode's short human noun, as used in its log / note / toast lines ("email", "search").
    let label: String
    /// The History taxonomy row this mode records under (see `HistoryMode`).
    let historyMode: HistoryMode
    /// How the mode acquires its input (transcript / selection / dual).
    let input: OneShotInput
    /// Where the mode's result lands (shared in-place tail / bespoke non-destructive).
    let landing: OneShotLanding

    /// The word-count floor a dictated take must clear, or nil for a pure-selection mode (which has no
    /// transcript to gate). For the dual mode this is the floor above which the take is a real dictation
    /// rather than a stray word or two uttered during a selection transform.
    var minWords: Int? {
        switch input {
        case .transcript(let m), .transcriptOrSelection(let m): return m
        case .selection: return nil
        }
    }

    /// The transcript-take word gate: a dictated take clears iff it carries at least `minWords` words.
    /// For a pure-selection mode (no transcript) this is vacuously false — there is no take to clear.
    /// This is the parameterized generalization of `CleanupLogic.isDictationEmail` /
    /// `isSearchQuestion`; the predefined descriptors below carry the same floors those funcs default to,
    /// so migrating a mode onto `clearsWordGate` is behavior-preserving (asserted in `--selftest`).
    func clearsWordGate(wordCount: Int) -> Bool {
        guard let minWords = minWords else { return false }
        return wordCount >= minWords
    }

    /// Dictation-capable modes consume the held take and therefore arm until release. Pure selection
    /// modes have no take input and keep their immediate command behavior.
    var consumesTake: Bool {
        switch input {
        case .transcript, .transcriptOrSelection: return true
        case .selection: return false
        }
    }

    /// A persistent toggle is safe only when the mode consumes the current take and returns its result
    /// to the field being dictated into. Selection-only commands have no take to keep armed, while
    /// non-destructive modes would silently redirect every later dictation away from that field.
    var supportsPersistentToggle: Bool {
        guard consumesTake else { return false }
        if case .inPlace = landing { return true }
        return false
    }

}

/// The predefined one-shot descriptors. Each mirrors the constants its bespoke method hand-codes today;
/// pieces 4-6 point those methods at these instead of re-deriving them inline.
extension OneShotMode {
    /// Option+P — Cleanup-selection: transform the selection with a picked cleanup level, paste back in
    /// place. Native Cmd+Z is the undo, so no smart-undo wiring.
    static let cleanupSelection = OneShotMode(
        id: "prompt-prep", routeID: .promptPrep,
        label: "Cleanup selection", historyMode: .cleanupSelection,
        input: .selection, landing: .inPlace(wireUndo: false))

    /// Option+M — email: dual-mode. Dictate the gist (>= 3 words) or transform the selection, then paste
    /// the finished email in place with the raw word-vomit wired as the smart-undo source.
    static let email = OneShotMode(
        id: "email", routeID: .email, label: "email", historyMode: .email,
        input: .transcriptOrSelection(minWords: 3), landing: .inPlace(wireUndo: true))

    /// Option+L — local web search: dictate the question (>= 2 words), land the answer read-only.
    static let searchLocal = OneShotMode(
        id: "search-local", routeID: .searchLocalSynth, label: "search", historyMode: .search,
        input: .transcript(minWords: 2), landing: .nonDestructive)

    /// Option+G — Gemini web search: same shape as local, different pipeline + History row.
    static let searchGemini = OneShotMode(
        id: "search-gemini", routeID: .searchGeminiSynth,
        label: "Gemini search", historyMode: .searchGemini,
        input: .transcript(minWords: 2), landing: .nonDestructive)
}
