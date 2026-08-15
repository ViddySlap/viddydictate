import Foundation

/// The rebindable hotkey grammar (ADR 0003, retired the fixed-grammar invariant). Pure, persistable,
/// and unit-testable: the `HotkeyMonitor` reads a `HotkeyMap` to decide what the wakeup key is and
/// which command each chord key fires, and the Settings "Hotkeys" tab edits it. No live tap / UI here
/// so the conflict + default logic can be asserted headlessly (`--selftest`).
///
/// Grammar: hold the **wakeup** key, tap a **chord** key. The wakeup may be a modifier (the clean
/// default) OR a regular key (consumed for dictation). Every chord — and the wakeup itself — is
/// rebindable; the only invariant the map enforces is that no two slots share a key.

// MARK: - Key spec

/// One physical key. A modifier is identified by its device-dependent flag mask (the low byte of
/// `CGEventFlags.rawValue`, e.g. 0x40 for right-Option); a regular key by its virtual keycode.
struct KeySpec: Codable, Equatable {
    var isModifier: Bool
    /// Device modifier mask when `isModifier`, else the virtual keycode.
    var code: Int64
    /// Display label, e.g. "right ⌥", "Space", "P", "`", "⇧N". Not part of identity.
    var label: String
    /// Shift QUALIFIER on a regular chord key: true means the chord is "hold the wakeup, hold Shift, tap this
    /// key" (Option+Shift+N, the bullseye reveal). It is part of the binding's identity, so `⇧N` and `N` are two
    /// distinct, non-conflicting chords. Meaningless (always false) for a modifier key — a modifier IS the key.
    /// Absent from every pre-shift saved map, so decoding defaults it to false (see `init(from:)`).
    var shift: Bool = false

    /// Two keys are the same binding iff same kind + same code + same shift qualifier (label is cosmetic).
    static func == (lhs: KeySpec, rhs: KeySpec) -> Bool {
        lhs.isModifier == rhs.isModifier && lhs.code == rhs.code && lhs.shift == rhs.shift
    }

    /// Decode tolerantly: maps saved before the shift qualifier existed carry no `shift` key, and a missing
    /// qualifier is exactly an unshifted chord. Swift's synthesized decoder would throw on the absent key, so
    /// the flag is read with `decodeIfPresent` instead. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isModifier = try c.decode(Bool.self, forKey: .isModifier)
        code = try c.decode(Int64.self, forKey: .code)
        label = try c.decode(String.self, forKey: .label)
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
    }

    init(isModifier: Bool, code: Int64, label: String, shift: Bool = false) {
        self.isModifier = isModifier
        self.code = code
        self.label = label
        self.shift = shift
    }

    static func modifier(mask: Int64, label: String) -> KeySpec {
        KeySpec(isModifier: true, code: mask, label: label)
    }
    static func regular(keyCode: Int64, label: String, shift: Bool = false) -> KeySpec {
        KeySpec(isModifier: false, code: keyCode, label: label, shift: shift)
    }

    /// The compact glyph drawn inside HUD keycaps. Persisted labels may describe a physical
    /// dual-legend key (for example `?/`), while ProcessingMode's rendering contract is the clean
    /// active glyph only (`?`). Keep the full label for Settings and normalize only at the keycap seam.
    var keycapGlyph: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLegend = trimmed.split(separator: "/", maxSplits: 1,
                                              omittingEmptySubsequences: false).first,
              !firstLegend.isEmpty else {
            return trimmed
        }
        return String(firstLegend)
    }
}

// MARK: - Commands

/// The chord commands (everything tapped while the wakeup is held). The wakeup is NOT in here — it is
/// the held key, stored separately on the map.
enum HotkeyCommand: String, CaseIterable, Codable {
    case lock, cleanupToggle, undo, levelUp, levelDown, cleanupSelection, email, searchLocal, searchGemini, notes, dictionary, bullseyeToggle, bullseyeReveal

    /// User-facing row label in the Hotkeys table.
    var label: String {
        switch self {
        case .lock:             return "Lock / latch"
        case .cleanupToggle:    return "Cleanup toggle"
        case .undo:             return "Undo"
        case .levelUp:          return "Level up"
        case .levelDown:        return "Level down"
        case .cleanupSelection: return "Cleanup selection"   // renamed from "prompt-prep" 2026-06-30
        case .email:            return "Email"
        case .searchLocal:      return "Search (local)"
        case .searchGemini:     return "Search (Gemini)"
        case .notes:            return "Sticky notes"
        case .dictionary:       return "Dictionary"
        case .bullseyeToggle:   return "Bullseye toggle"
        case .bullseyeReveal:   return "Bullseye reveal"
        }
    }

    /// A one-line "what it does" hint shown under the row label.
    var hint: String {
        switch self {
        case .lock:             return "Toggle hands-free latch"
        case .cleanupToggle:    return "Enable the cleanup pass + strength slider"
        case .undo:             return "Undo last result / discard audio"
        case .levelUp:          return "Cleanup strength up (toward Summarize)"
        case .levelDown:        return "Cleanup strength down (toward Cleanup)"
        case .cleanupSelection: return "Clean up the selected text in place"
        case .email:            return "Write an email from this dictation, else the selection"
        case .searchLocal:      return "Speak a question, search the web locally, answer it"
        case .searchGemini:     return "Speak a question, answer it with Gemini grounding"
        case .notes:            return "Open the sticky-notes scratchpad"
        case .dictionary:       return "Open Settings on the Dictionary tab"
        case .bullseyeToggle:   return "Arm/disarm the sticky-note bullseye target"
        case .bullseyeReveal:   return "Show me the bullseye — front its note, scroll to it, arm it"
        }
    }

    /// Built-in default key. Restore-default reads from here.
    var defaultKey: KeySpec {
        switch self {
        case .lock:             return .regular(keyCode: 49, label: "Space")
        case .cleanupToggle:    return .regular(keyCode: 44, label: "?")
        case .undo:             return .regular(keyCode: 6,  label: "Z")
        case .levelUp:          return .regular(keyCode: 24, label: "=")
        case .levelDown:        return .regular(keyCode: 27, label: "-")
        case .cleanupSelection: return .regular(keyCode: 35, label: "P")
        case .email:            return .regular(keyCode: 46, label: "M")
        case .searchLocal:      return .regular(keyCode: 37, label: "L")
        case .searchGemini:     return .regular(keyCode: 5,  label: "G")
        case .notes:            return .regular(keyCode: 45, label: "N")
        case .dictionary:       return .regular(keyCode: 2,  label: "D")
        case .bullseyeToggle:   return .regular(keyCode: 11, label: "B")
        // Option+Shift+N: the SHIFT-QUALIFIED sibling of Option+N. Same keycode, distinct binding — the shift
        // flag is part of KeySpec identity, so `⇧N` (reveal) and `N` (set/arm) coexist without conflicting.
        case .bullseyeReveal:   return .regular(keyCode: 45, label: "⇧N", shift: true)
        }
    }

    /// Display order in the Hotkeys table (matches the design table).
    static let displayOrder: [HotkeyCommand] =
        [.lock, .cleanupToggle, .undo, .levelUp, .levelDown, .cleanupSelection, .email, .searchLocal, .searchGemini, .notes, .dictionary, .bullseyeToggle, .bullseyeReveal]
}

// MARK: - The map

/// Which slot a key is bound to (for conflict reporting).
enum HotkeySlot: Equatable {
    case wakeup
    case command(HotkeyCommand)

    var label: String {
        switch self {
        case .wakeup: return "Dictation wakeup"
        case .command(let c): return c.label
        }
    }
}

struct HotkeyMap: Codable, Equatable {
    var wakeup: KeySpec
    /// Keyed by `HotkeyCommand.rawValue` so it round-trips through `Codable` / JSON cleanly.
    var bindings: [String: KeySpec]

    static let defaultWakeup = KeySpec.modifier(mask: 0x40, label: "right ⌥")

    /// The built-in defaults (right-Option wakeup + the v1 chord assignments).
    static func defaults() -> HotkeyMap {
        var b: [String: KeySpec] = [:]
        for c in HotkeyCommand.allCases { b[c.rawValue] = c.defaultKey }
        return HotkeyMap(wakeup: HotkeyMap.defaultWakeup, bindings: b)
    }

    /// The key currently bound to `command` (falls back to its default if somehow missing).
    func key(for command: HotkeyCommand) -> KeySpec {
        bindings[command.rawValue] ?? command.defaultKey
    }

    /// The command bound to a regular keycode with a given shift qualifier — an EXACT match on both (the
    /// keyDown chord path). Modifier chords are matched separately by mask. Returns nil when no regular chord
    /// uses that keycode at that qualifier. The monitor calls this twice: once with the shift state actually
    /// held (so Option+Shift+N reaches the reveal), then once with `false` (so a shifted press of a key nobody
    /// claimed shift-qualified still fires its plain chord, as it always has).
    func command(forKeyCode keyCode: Int64, shift: Bool) -> HotkeyCommand? {
        for c in HotkeyCommand.allCases {
            let k = key(for: c)
            if !k.isModifier && k.code == keyCode && k.shift == shift { return c }
        }
        return nil
    }

    /// The unshifted chord bound to a regular keycode. Every binding was unshifted before the reveal chord,
    /// so this keeps the pre-shift call shape (and its meaning) for callers that do not observe shift.
    func command(forKeyCode keyCode: Int64) -> HotkeyCommand? {
        command(forKeyCode: keyCode, shift: false)
    }

    /// The command bound to a modifier mask (the flagsChanged chord path, for a modifier-as-chord).
    func command(forModifierMask mask: Int64) -> HotkeyCommand? {
        for c in HotkeyCommand.allCases {
            let k = key(for: c)
            if k.isModifier && k.code == mask { return c }
        }
        return nil
    }

    /// Conflict check for assigning `key` to `slot`: returns the OTHER slot already using that key,
    /// or nil if free. A slot never conflicts with itself (rebinding to the same key is a no-op, not a
    /// conflict). The wakeup and every chord share one namespace — you cannot tap what you hold.
    func conflict(of key: KeySpec, assigningTo slot: HotkeySlot) -> HotkeySlot? {
        if slot != .wakeup, wakeup == key { return .wakeup }
        for c in HotkeyCommand.allCases {
            if slot == .command(c) { continue }
            if self.key(for: c) == key { return .command(c) }
        }
        return nil
    }

    /// Apply a binding (no conflict checking — callers conflict-check first).
    mutating func assign(_ key: KeySpec, to slot: HotkeySlot) {
        switch slot {
        case .wakeup: wakeup = key
        case .command(let c): bindings[c.rawValue] = key
        }
    }

    /// Reset one slot to its built-in default.
    mutating func restoreDefault(_ slot: HotkeySlot) {
        switch slot {
        case .wakeup: wakeup = HotkeyMap.defaultWakeup
        case .command(let c): bindings[c.rawValue] = c.defaultKey
        }
    }

    // MARK: persistence (UserDefaults, parallel to the rest of Settings)

    private static let storeKey = "hotkeyMap"

    /// Load the saved map, falling back to defaults (and back-filling any command missing from an
    /// older saved map so a newly-added command always has a key).
    static func load(_ d: UserDefaults = .standard) -> HotkeyMap {
        guard let data = d.data(forKey: storeKey),
              var map = try? JSONDecoder().decode(HotkeyMap.self, from: data) else {
            return defaults()
        }
        for c in HotkeyCommand.allCases where map.bindings[c.rawValue] == nil {
            map.bindings[c.rawValue] = c.defaultKey
        }
        return map
    }

    func save(_ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        d.set(data, forKey: HotkeyMap.storeKey)
    }
}

// MARK: - Key naming (capture-time labels)

/// Maps captured CGEvent data to display labels. Centralized so capture (HotkeyMonitor) and the
/// defaults table agree. Pure tables — no AppKit.
enum KeyNaming {
    /// Recognized device modifier masks, in capture priority order (most-specific / most-likely first).
    /// These bits live in the low part of `CGEventFlags.rawValue`; `fn` is the documented
    /// `maskSecondaryFn` bit. Used both to LABEL a captured modifier and to TEST whether it is held.
    static let modifiers: [(mask: Int64, label: String)] = [
        (0x40,      "right ⌥"),
        (0x20,      "left ⌥"),
        (0x10,      "right ⌘"),
        (0x08,      "left ⌘"),
        (0x2000,    "right ⌃"),
        (0x01,      "left ⌃"),
        (0x04,      "right ⇧"),
        (0x02,      "left ⇧"),
        (0x800000,  "fn"),
    ]

    /// Union of every recognized modifier bit (for masking off non-modifier flag noise).
    static let allModifierBits: Int64 = modifiers.reduce(Int64(0)) { $0 | $1.mask }

    static func modifierLabel(forMask mask: Int64) -> String {
        modifiers.first { $0.mask == mask }?.label ?? "mod"
    }

    /// Named non-typeable / special keys whose keycode reads better than their (often absent) char.
    static let specialKeys: [Int64: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Label for a captured regular key: a named special key, else the typed character (uppercased),
    /// else a keycode fallback so an exotic key still shows something stable. A shift-qualified chord is
    /// prefixed with `⇧` so the Hotkeys table can tell `⇧N` from `N` at a glance (the two are distinct
    /// bindings, and the label is the only thing the user sees).
    static func regularLabel(keyCode: Int64, char: String, shift: Bool = false) -> String {
        let base: String
        if let name = specialKeys[keyCode] {
            base = name
        } else {
            let c = char.trimmingCharacters(in: .whitespacesAndNewlines)
            base = c.isEmpty ? "key \(keyCode)" : c.uppercased()
        }
        return shift ? "⇧" + base : base
    }
}
