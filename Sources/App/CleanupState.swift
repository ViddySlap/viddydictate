import Foundation

/// A processing mode = a label + a keycap glyph + an optional cleanup prompt.
///
/// Scope note (review item 2): this record models ONLY the two *persistent processing modes* flipped by
/// the `?` toggle - Raw and Cleanup - which share the badge + menubar-indicator UI. It is NOT a general
/// mode-plugin substrate. The one-shot command keys (Option+M email, Option+L/G search, Option+P
/// Cleanup-selection) are deliberately NOT `ProcessingMode` records: they are the Family 2 flows, driven
/// by the `OneShotMode` descriptors and (per ADR 0010) the `OneShotRegistry` engine, not this Family 1
/// state holder. An earlier comment here promised a dead `oneShot` seam that email/search would "slot
/// into"; that was never load-bearing (grep-confirmed unread) and is removed.
struct ProcessingMode {
    let id: String
    /// Label shown beside the keycap badge and on the menubar indicator ("Cleanup", "Raw").
    let label: String
    /// The single glyph centered in the keycap badge — the clean glyph for the key, NOT the literal
    /// dual-legend key (so `?`, never `?/`). Empty = no transform (Raw).
    let glyph: String
    /// The firm cleanup system prompt for this mode; nil = pass the raw transcript straight through.
    let systemPrompt: String?

    var transformsText: Bool { systemPrompt != nil }
}

/// A dictation-capable Family-2 mode held in the universal transform slot. Its lifetime says whether
/// release consumes it or leaves it armed for later takes. The source is enough for DictationController
/// to route the exact built-in/custom descriptor through OneShotRegistry after release; the presentation
/// fields keep the HUD independent of that engine.
enum OneShotArmSource {
    case builtIn(OneShotRegistry.Mode)
    case custom(CustomMode)
}

enum OneShotArmLifetime: Equatable {
    case perTake
    case persistent
}

struct ArmedOneShot {
    let source: OneShotArmSource
    let id: String
    let label: String
    let glyph: String
    let lifetime: OneShotArmLifetime

    init(source: OneShotArmSource, id: String, label: String, glyph: String,
         lifetime: OneShotArmLifetime = .perTake) {
        self.source = source
        self.id = id
        self.label = label
        self.glyph = glyph
        self.lifetime = lifetime
    }
}

/// The one armed-transform slot from ADR 0015.
///
/// It holds exactly one state: Raw, Cleanup, or one Family-2 mode. A normal arm is consumed on release
/// or cleared on cancel; an opted-in persistent arm remains until its chord toggles it off or another
/// transform replaces it. Every slot state is session-lived. The payload deliberately includes the exact
/// custom-mode snapshot selected at tap time, so a Settings edit during a held take cannot change what
/// that take runs.
final class TransformArmState {
    static let shared = TransformArmState()

    private enum Slot {
        case raw
        case cleanup
        case oneShot(ArmedOneShot)
    }

    /// A one-shot may displace one persistent base occupant, never another arm. Replacing M with L keeps
    /// the original Raw/Cleanup occupant here instead of building an arm stack.
    private enum DisplacedOccupant {
        case raw
        case cleanup
    }

    private var slot: Slot = .raw
    private var displacedOccupant: DisplacedOccupant?

    /// Internal initializer lets deterministic tests prove the slot lifecycle without mutating live state.
    init() {}

    var cleanupEnabled: Bool {
        if case .cleanup = slot { return true }
        return false
    }

    var armedOneShot: ArmedOneShot? {
        if case .oneShot(let arm) = slot { return arm }
        return nil
    }

    /// Cleanup is the other occupant of this same slot. Turning it on replaces any one-shot arm; turning
    /// it off returns to Raw.
    @discardableResult
    func toggleCleanup() -> Bool {
        if case .cleanup = slot {
            slot = .raw
            displacedOccupant = nil
            return false
        }
        slot = .cleanup
        displacedOccupant = nil
        return true
    }

    /// Flip one per-take Family-2 occupant. A repeated chord restores the Raw/Cleanup occupant that the
    /// first tap displaced; a different arm replaces only the active arm and preserves that one base.
    @discardableResult
    func armOneShot(_ arm: ArmedOneShot) -> Bool {
        precondition(arm.lifetime == .perTake)
        return toggleOneShot(arm)
    }

    /// Flip one persistent Family-2 occupant using the same displacement rule as a per-take arm.
    @discardableResult
    func togglePersistentOneShot(_ arm: ArmedOneShot) -> Bool {
        precondition(arm.lifetime == .persistent)
        return toggleOneShot(arm)
    }

    /// Release consumes a per-take arm before its existing OneShotRegistry flow begins. A persistent
    /// arm is returned without vacating the slot, so it applies to the next take too.
    func takeOneShotForRelease() -> ArmedOneShot? {
        guard case .oneShot(let arm) = slot else { return nil }
        if arm.lifetime == .perTake { restoreDisplacedOccupant() }
        return arm
    }

    /// Escape cancels only a per-take arm. Cleanup is persistent and is not a take-scoped cancellation.
    @discardableResult
    func cancelPerTakeArm() -> ArmedOneShot? {
        guard case .oneShot(let arm) = slot, arm.lifetime == .perTake else { return nil }
        slot = .raw
        displacedOccupant = nil
        return arm
    }

    /// A checkbox removal or eligibility edit must not leave a now-unreachable persistent arm behind.
    @discardableResult
    func disarmPersistentOneShot(id: String) -> ArmedOneShot? {
        guard case .oneShot(let arm) = slot,
              arm.lifetime == .persistent,
              arm.id == id else { return nil }
        slot = .raw
        displacedOccupant = nil
        return arm
    }

    /// The sole arm transition owner. The first arm snapshots Raw/Cleanup; later replacement arms leave
    /// that snapshot alone. Repeating the active id restores the snapshot and ends the arm.
    private func toggleOneShot(_ arm: ArmedOneShot) -> Bool {
        if case .oneShot(let current) = slot, current.id == arm.id {
            restoreDisplacedOccupant()
            return false
        }

        switch slot {
        case .raw:
            displacedOccupant = .raw
        case .cleanup:
            displacedOccupant = .cleanup
        case .oneShot:
            break
        }
        slot = .oneShot(arm)
        return true
    }

    private func restoreDisplacedOccupant() {
        switch displacedOccupant {
        case .cleanup:
            slot = .cleanup
        case .raw, nil:
            slot = .raw
        }
        displacedOccupant = nil
    }
}

/// Cleanup strength levels. The `?` toggle gates cleanup on/off; when on, the strength slider picks
/// one of these. Each maps to a system prompt (a tuning surface, overridable via Settings). The
/// spectrum was verified on qwen against the golden set + the user's real dictations: monotonic, faithful
/// at every level, no answer-the-question failures. See `v2-strength-slider-spec.md`.
enum CleanupLevel: Int, CaseIterable {
    case cleanup = 0     // basic, verbatim-faithful (current behavior)
    case tighten = 1     // collapse redundant restatements + minor asides, keep every distinct point
    case summarize = 2   // condense toward a tight summary, may drop minor incidental detail

    /// Short label shown beside the keycap (the slider ends read "cleanup" / "summarize").
    var label: String {
        switch self {
        case .cleanup: return "Cleanup"
        case .tighten: return "Tighten"
        case .summarize: return "Summarize"
        }
    }

    static func clamped(_ raw: Int) -> CleanupLevel { CleanupLevel(rawValue: min(2, max(0, raw))) ?? .cleanup }
}

/// Holds the Family-1 persistent processing-mode toggle and the cleanup strength level.
///
/// Renamed from `ModeRegistry` by item-4 piece 7 (ADR 0010): this is mutable Family-1 CLEANUP STATE (the
/// Raw/Cleanup toggle + the level + the prompt lookup), not a mode lookup table - the misleading
/// "registry" name is now reserved for the real Family-2 engine (`OneShotRegistry`). The default prompt
/// constants that used to squat in this file moved to `Prompts.swift`.
///
/// **Default state at launch: OFF (Raw).** The toggle is intentionally *not persisted* — every
/// launch starts in Raw to match v1's baseline behavior, so a stale "Cleanup ON" can never surprise
/// the user after a relaunch. The *level* IS remembered across launches (it only applies once toggled
/// on), so the user does not have to re-pick their strength every session.
final class CleanupState {
    static let shared = CleanupState()

    let raw: ProcessingMode

    /// Persistent processing-mode toggle projected from the universal mutually-exclusive slot.
    /// In-memory only (default off).
    var cleanupEnabled: Bool { TransformArmState.shared.cleanupEnabled }

    /// Cleanup strength level (0 Cleanup / 1 Tighten / 2 Summarize). Persisted via Settings; applies
    /// only when `cleanupEnabled`.
    private(set) var cleanupLevel: CleanupLevel

    private init() {
        raw = ProcessingMode(id: "raw", label: "Raw", glyph: "?", systemPrompt: nil)
        cleanupLevel = CleanupLevel.clamped(Settings.cleanupLevel)
    }

    /// The system prompt for a given strength level (Settings override, else the built-in default).
    func prompt(for level: CleanupLevel) -> String { Settings.cleanupPrompt(level) }

    /// The Cleanup mode record for the current level (label reflects the level; glyph is always `?`).
    var cleanup: ProcessingMode {
        ProcessingMode(id: "cleanup", label: cleanupLevel.label, glyph: "?",
                       systemPrompt: prompt(for: cleanupLevel))
    }

    /// The mode the *next* dictation will use given the current toggle state.
    var current: ProcessingMode { cleanupEnabled ? cleanup : raw }

    /// Flip the persistent toggle. Returns the new enabled state.
    @discardableResult
    func toggleCleanup() -> Bool {
        let enabled = TransformArmState.shared.toggleCleanup()
        Log.write("mode toggle -> \(enabled ? "Cleanup(\(cleanupLevel.label))" : "Raw")")
        return enabled
    }

    /// Step the strength level by `delta` (clamped 0..2), persist it. No-op when cleanup is OFF (the
    /// slider is not shown then). Returns the new level.
    @discardableResult
    func stepLevel(_ delta: Int) -> CleanupLevel {
        guard cleanupEnabled else { return cleanupLevel }
        setLevel(CleanupLevel.clamped(cleanupLevel.rawValue + delta))
        return cleanupLevel
    }

    /// Set the strength level directly (slider / Settings), clamp + persist.
    func setLevel(_ level: CleanupLevel) {
        guard level != cleanupLevel else { return }
        cleanupLevel = level
        Settings.cleanupLevel = level.rawValue
        Log.write("cleanup level -> \(level.label)")
    }

    /// The mode record to surface on the badge for a given toggle state. The badge always shows the
    /// `?` keycap (the key that was pressed); the *label* reflects the resulting mode/level.
    func badgeMode(forEnabled enabled: Bool) -> ProcessingMode { enabled ? cleanup : raw }
}
