import Foundation

/// A user-defined one-shot mode (glossary "Custom mode"), created from the Hotkeys page "Add new
/// hotkey" form instead of Swift. It is the data-driven half of the OneShotRegistry seam: a persisted
/// descriptor (chord + name + prompt + input + model + landing) that becomes a live `OneShotMode`
/// without a rebuild (`oneShotMode`, below). The registry drives it through the SAME shared flow the
/// compiled-in built-ins use — a custom descriptor is not a second engine, just another descriptor.
///
/// Plain shape only (locked 2026-07-06 grill): no level picker, no tool loop. "both" input means
/// prefer-the-dictation-else-transform-the-selection (Option+M's dual-mode gate as the standard
/// behavior). Pure value type + pure mapping, so it lives on the headless `--custommode-selftest`
/// surface with no disk / network / AppKit.

// MARK: - Model field

/// The local models the app already uses, the existing Claude option, and the human labels the dropdowns
/// show. Ownership is typed by `LLMProvider`; A1 deliberately keeps the existing visible options unchanged.
enum ModeModelCatalog {
    /// The EXPLICIT Claude id, never the `sonnet` alias (which can lag the CLI registry). The dropdown's
    /// current invocation intentionally has no effort flag, preserving its existing argv byte-for-byte.
    static let claudeId = LLMProviderDefaults.claudeSonnetModelID
    static let claudeModel = LLMProviderDefaults.currentClaudeSelection

    /// The local models the app already runs, deduped in first-seen order (cleanup, email, then the two
    /// search legs). Sourced from `Settings` so a model swap there flows through without a second literal.
    static var localModels: [ModeModel] {
        var seen = Set<String>()
        var out: [ModeModel] = []
        for id in [Settings.cleanupModel, Settings.emailModel, Settings.searchModel, Settings.searchSynthModel]
        where !id.isEmpty && seen.insert(id).inserted {
            out.append(.local(id))
        }
        return out
    }

    /// The compatibility catalog remains Local + Claude. Models & Power prepends each route's tested
    /// bundle, including a ratified Codex default where one exists, and keeps the custom-ID escape hatch.
    static var options: [ModeModel] { localModels + [claudeModel] }

    /// A short human label for a model id (drop the org prefix, keep it readable in a narrow popup). The
    /// Claude option carries its full spoken label so the user sees exactly what it is and where it runs.
    static func displayName(_ m: ModeModel) -> String {
        if m.provider == .claude { return "Sonnet 5 (Claude subscription)" }
        return m.id.contains("/") ? String(m.id.split(separator: "/").last!) : m.id
    }

    /// Resolve only the pre-A4 P/M scalar providers beside the existing last-used Local id. Codex has no
    /// scalar-era representation and is route-specific, so it returns nil instead of manufacturing an
    /// invalid empty model id or silently substituting another provider.
    static func legacySelection(provider: LLMProvider, localId: String) -> ModeModel? {
        switch provider {
        case .local:  return .local(localId)
        case .claude: return claudeModel
        case .codex:  return nil
        }
    }
}

// MARK: - Input / landing (UI-facing enums; mapped to the engine's OneShotInput / OneShotLanding)

/// How a custom mode obtains its input. UI-facing (a dropdown of three), mapped to the engine's
/// `OneShotInput` in `CustomMode.oneShotMode`.
enum CustomInput: String, Codable, CaseIterable {
    case dictation, selection, both
    var label: String {
        switch self {
        case .dictation: return "Dictation"
        case .selection: return "Selection"
        case .both:      return "Dictation or selection"
        }
    }
}

/// Where a custom mode's result lands. UI-facing, mapped to the engine's `OneShotLanding`.
///  - `.inPlace` reuses the selection-transform landing (paste back over the selection / at the caret,
///    smart-undo wired).
///  - `.note` reuses the sticky-note landing the web-search modes use (question heading + answer body).
enum CustomLanding: String, Codable, CaseIterable {
    case inPlace, note
    var label: String {
        switch self {
        case .inPlace: return "Replace in place"
        case .note:    return "Output to a note"
        }
    }
}

// MARK: - The descriptor

struct CustomMode: Codable, Equatable {
    /// Stable identity (a UUID string). NEVER the chord — the chord can be rebound without breaking the
    /// mode's identity, its history provenance, or a conflict exclusion.
    var id: String
    /// The mode's human noun, used in its log / note / toast lines and as the row title.
    var name: String
    /// The bound chord key (the same `KeySpec` the built-in rebind UI captures).
    var chord: KeySpec
    /// The mode's system prompt (the transform instruction). Augmented with the correction glossary at
    /// run time exactly like every other post-dictation pass.
    var prompt: String
    /// How it acquires input (dictation / selection / both).
    var input: CustomInput
    /// Lossless pre-A4 model selection used to seed the Models & Power route on migration. Runtime
    /// selection now comes from that route authority; keeping this field preserves old custom-mode JSON.
    var model: ModeModel
    /// Where its result lands (replace in place / output to a note).
    var landing: CustomLanding

    /// Stable LLM route identity; the custom mode UUID survives chord/name edits and app restarts.
    var routeID: LLMRouteID { .custom(id) }

    /// Word floors, reusing the built-ins' gates so custom behavior matches the shipped modes:
    ///  - dictation-only clears at the web-search floor (a real spoken take, not a stray word).
    ///  - "both" clears at Option+M's dual-mode gate (spoke more than a couple words -> use the
    ///    dictation; else transform the selection) — the standard "both" behavior locked in the grill.
    static let dictationMinWords = 2
    static let bothMinWords = 3   // Option+M's gate, reused verbatim as the standard "both" semantics

    /// The live `OneShotMode` this descriptor drives. The registry consumes it exactly like a built-in
    /// descriptor — this is the whole "becomes a live OneShotMode without a rebuild" mechanic.
    var oneShotMode: OneShotMode {
        let mappedInput: OneShotInput
        switch input {
        case .dictation: mappedInput = .transcript(minWords: CustomMode.dictationMinWords)
        case .selection: mappedInput = .selection
        case .both:      mappedInput = .transcriptOrSelection(minWords: CustomMode.bothMinWords)
        }
        let mappedLanding: OneShotLanding
        switch landing {
        case .inPlace: mappedLanding = .inPlace(wireUndo: true)   // selection-transform landing + smart-undo
        case .note:    mappedLanding = .nonDestructive
        }
        return OneShotMode(id: "custom:\(id)", routeID: routeID, label: name, historyMode: .custom,
                           input: mappedInput, landing: mappedLanding)
    }

    /// A blank template for the "Add new hotkey" form: a fresh id, an unbound chord, sensible defaults.
    static func blank(id: String) -> CustomMode {
        CustomMode(id: id, name: "", chord: KeySpec.regular(keyCode: -1, label: "set a key"),
                   prompt: defaultCustomModeTaskPrompt, input: .selection,
                   model: ModeModelCatalog.localModels.first ?? .local(Settings.cleanupModel),
                   landing: .inPlace)
    }

    /// A chord is bound once it carries a real key (the blank template's sentinel keycode -1 is unbound).
    var hasChord: Bool { chord.isModifier || chord.code >= 0 }

    /// A mode fires from the live tap only once it has a bound chord AND a non-blank prompt, so a
    /// half-built row (just added, not yet filled in) never dispatches an empty-prompt transform.
    var isDispatchable: Bool {
        hasChord && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ready to persist: a name, a bound chord, and a non-blank prompt.
    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasChord
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Combined-namespace conflict detection (built-ins + custom modes)

/// Identity of a key's owner across the WHOLE hotkey namespace — the wakeup, the built-in chords
/// (`HotkeyMap`), and the custom modes (`CustomModeStore`). `HotkeyMap.conflict` only knows the first
/// two; the Hotkeys page assigns keys across all three, so conflict reporting has to span them. Pure so
/// it is asserted headlessly (custom-vs-builtin, custom-vs-wakeup, custom-vs-custom).
enum HotkeyOwner: Equatable {
    case wakeup
    case builtin(HotkeyCommand)
    case custom(id: String, name: String)

    var label: String {
        switch self {
        case .wakeup:            return "Dictation wakeup"
        case .builtin(let c):    return c.label
        case .custom(_, let n):  return n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "a custom hotkey" : n
        }
    }

    /// Same owner by IDENTITY (custom compares id only; the display name is cosmetic). Used to exclude
    /// the slot being (re)assigned from its own conflict check.
    func isSame(as other: HotkeyOwner) -> Bool {
        switch (self, other) {
        case (.wakeup, .wakeup):                       return true
        case (.builtin(let a), .builtin(let b)):       return a == b
        case (.custom(let a, _), .custom(let b, _)):   return a == b
        default:                                       return false
        }
    }
}

enum HotkeyConflicts {
    /// The owner already using `key` across the built-in map + the custom modes, excluding `excluding`
    /// (the slot being assigned — rebinding a slot to its own key is never a conflict). nil = the key is
    /// free. The single conflict authority the Hotkeys page routes every capture through, so a custom
    /// chord can never silently collide with a built-in, the wakeup, or another custom mode.
    static func owner(of key: KeySpec, in map: HotkeyMap, custom: [CustomMode],
                      excluding: HotkeyOwner?) -> HotkeyOwner? {
        func skip(_ o: HotkeyOwner) -> Bool { excluding?.isSame(as: o) ?? false }

        if !skip(.wakeup), map.wakeup == key { return .wakeup }
        for c in HotkeyCommand.allCases {
            let o = HotkeyOwner.builtin(c)
            if skip(o) { continue }
            if map.key(for: c) == key { return o }
        }
        for m in custom {
            let o = HotkeyOwner.custom(id: m.id, name: m.name)
            if skip(o) { continue }
            if m.chord == key { return o }
        }
        return nil
    }
}
