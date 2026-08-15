import Foundation

/// The PINNED dictation target inside a sticky note (notes-bullseye BT2). Unlike the TRANSIENT snapshot
/// (`NotesDictationTarget`, BT1) — which lasts one take — the bullseye is PERSISTENT: set/moved by Option+N
/// with the caret in a note, toggled armed/disarmed by Option+B, and remembered across restarts. There is
/// exactly one bullseye. While armed, a fresh dictation whose requested landing is in-place delivers HERE
/// regardless of focus. Selection transforms and non-destructive note landings keep their own destination.
///
/// The anchored POSITION lives in the note's live CodeMirror editor (only CM can map a position through
/// changes, so the anchor follows edits) — this Swift value carries just the note id, the last-known
/// anchor offset (for persistence + restore), and the armed flag. The web island owns the live anchor and
/// the delivery landing; Swift owns the arm state, the precedence, the info-pill glyph, and persistence.
struct NotesBullseye: Codable, Equatable {
    var noteId: String
    /// Last-known character offset of the anchor in the note body. Reported back by the web island on set
    /// and on each follow-edits remap; persisted so a restart can re-place the bullseye. Not the live
    /// anchor (which lives in CodeMirror) — a durable approximation for restore.
    var anchor: Int
    var armed: Bool
}

/// Pure decision + modelling logic for the BT2 bullseye flow. Carries NO AppKit / CodeMirror / persistence
/// state so the `--notes-probe` seam can lock the contract headlessly; the live `NotesBullseyeState`
/// singleton drives the same rules against UserDefaults + the web island, and the probe pins these funcs.
enum NotesBullseyeLogic {
    /// The descriptor's requested landing shape. Raw / `?` delivery is an in-place dictation landing too,
    /// which lets it and one-shot in-place delivery consult the same precedence rule.
    enum LandingKind: Equatable {
        case inPlace
        case nonDestructive
    }

    /// The input source latched from `takeHasSpeech` before a one-shot consumes the recording state. A
    /// selection transform must keep replacing its selection even when a bullseye is armed.
    enum InputSource: Equatable {
        case dictation
        case selection
    }

    /// Option+B with no bullseye set yet — the pill toast the spec pins.
    static let noneSetToast = "No bullseye set"
    /// Set/move + arm confirmation (Option+N in a note).
    static let setToast = "Bullseye set + armed"
    /// Option+B armed / disarmed confirmations (feedback outside a take, where the info pill is not visible).
    static let armedToast = "Bullseye armed"
    static let disarmedToast = "Bullseye disarmed"
    /// The target note was closed/deleted while the bullseye pointed at it — auto-disarm notice.
    static let goneToast = "Bullseye note closed — disarmed"
    /// The target note was gone at DELIVERY (a race): the take is parked on the clipboard, never lost.
    static let deliverGoneToast = "Bullseye note gone, copied to clipboard"
    /// BT6 (Option+Shift+N reveal): a bullseye is set but no live window holds its note, so there is nowhere to
    /// navigate to. Honest failure — say so rather than silently doing nothing. Deliberately does NOT reopen the
    /// note: restart/reopen durability is out of scope for the reveal chord.
    static let revealNoteClosedToast = "Bullseye note is closed"

    /// Restore a persisted bullseye on launch: KEPT (with its persisted armed flag) iff its note is still
    /// open; otherwise DROPPED (its note is gone, so the anchor addresses nothing — a dropped bullseye reads
    /// as "no bullseye set", which is the safe "else disarmed" outcome). This is a silent restore-time
    /// decision — no toast (distinct from a runtime auto-disarm).
    static func restored(_ persisted: NotesBullseye?, openNoteIds: Set<String>) -> NotesBullseye? {
        guard let b = persisted, openNoteIds.contains(b.noteId) else { return nil }
        return b
    }

    /// The outcome of Option+B, given the current bullseye. `.toggled` preserves the location and flips
    /// only `armed`; `.noneSet` means no bullseye exists yet (drives the "No bullseye set" toast).
    enum ToggleOutcome: Equatable {
        case toggled(NotesBullseye)
        case noneSet
    }

    static func toggled(_ current: NotesBullseye?) -> ToggleOutcome {
        guard var b = current else { return .noneSet }
        b.armed.toggle()
        return .toggled(b)
    }

    /// Whether the bullseye is armed-and-present — drives the info-pill glyph AND the delivery precedence.
    static func isArmed(_ b: NotesBullseye?) -> Bool { b?.armed == true }

    /// BT3 (inline marker): whether the inline armed-bullseye marker should render in the editor right now. It
    /// shows ONLY when the bullseye is armed AND its note is the note currently shown in the editor (the active
    /// tab, not the history view). The TRANSIENT snapshot (BT1) is not a bullseye, so it never reaches here —
    /// hence never a marker. Pure mirror of the JS `syncBullseyeMarker` gate so the probe can lock the
    /// present-only-when-armed rule headlessly; the CodeMirror widget render itself needs live GUI verification.
    static func markerVisible(armed: Bool, bullseyeNoteId: String?,
                              activeNoteId: String?, showingHistory: Bool) -> Bool {
        guard armed, !showingHistory,
              let bullseyeNoteId = bullseyeNoteId, !bullseyeNoteId.isEmpty,
              let activeNoteId = activeNoteId else { return false }
        return bullseyeNoteId == activeNoteId
    }

    /// BT6 (Option+Shift+N reveal): what the reveal chord should do, given the current bullseye and the notes
    /// actually held by live windows.
    enum RevealOutcome: Equatable {
        /// Navigate to `noteId`. `arm` is true when the bullseye was disarmed and the reveal is arming it, so
        /// the caller knows to refresh the info-pill glyph as well as navigate.
        case reveal(noteId: String, arm: Bool)
        /// Nothing is set — reuse the Option+B "No bullseye set" toast.
        case noneSet
        /// Set, but its note is not open in any live window — toast and stop. Never reopens the note.
        case noteClosed
    }

    /// The reveal decision. Reveal is a NAVIGATION act, not a visibility one: the inline marker already renders
    /// persistently, but only while its note is the active tab in a visible window, so "show me the bullseye"
    /// means front that window, select that tab, and scroll to the anchor. Arming a disarmed bullseye rides
    /// along because a disarmed bullseye renders no marker, and revealing an invisible thing is not a reveal.
    static func reveal(_ b: NotesBullseye?, liveNoteIds: Set<String>) -> RevealOutcome {
        guard let b = b else { return .noneSet }
        guard liveNoteIds.contains(b.noteId) else { return .noteClosed }
        return .reveal(noteId: b.noteId, arm: !b.armed)
    }

    /// Whether the bullseye survives the current set of open notes: true when there is no bullseye (nothing
    /// to disarm) or its note is still open; false when its note is gone (closed/deleted) and it must
    /// auto-disarm.
    static func survives(_ b: NotesBullseye?, openNoteIds: Set<String>) -> Bool {
        guard let b = b else { return true }
        return openNoteIds.contains(b.noteId)
    }

    /// Where a completed delivery lands. An armed bullseye wins only for an in-place result sourced from a
    /// fresh dictation. Selection transforms keep their snapshot/focus destination, while non-destructive
    /// modes keep the mode-owned landing and leave the bullseye armed.
    enum Delivery: Equatable {
        case bullseye(noteId: String)
        case snapshot(noteId: String)
        case requested
    }

    static func delivery(bullseye: NotesBullseye?, snapshotNoteId: String?,
                         landingKind: LandingKind, inputSource: InputSource) -> Delivery {
        guard landingKind == .inPlace else { return .requested }
        if inputSource == .dictation, let b = bullseye, b.armed {
            return .bullseye(noteId: b.noteId)
        }
        if let id = snapshotNoteId, !id.isEmpty { return .snapshot(noteId: id) }
        return .requested
    }

    /// BT5c (item 5c): after a take delivers `textLength` characters at the pinned anchor `at`, the anchor
    /// advances PAST the inserted text so successive takes stack in reading order. `textLength` is the actual
    /// inserted span, including a separator generated by the bare-caret landing rule.
    static func advancedAnchor(at: Int, textLength: Int) -> Int { at + textLength }

    /// BT5c (item 5c): where the inline marker must render AFTER a delivery — at the ADVANCED anchor (the END
    /// of the just-delivered text), NOT at `at` (the START, where the `side: -1` widget self-maps). The JS
    /// re-pushes the marker from this position as the last word so the glyph does not trail one dictation
    /// behind. Same value as `advancedAnchor`; named for the marker contract the probe pins.
    static func postDeliveryMarkerAnchor(at: Int, textLength: Int) -> Int {
        advancedAnchor(at: at, textLength: textLength)
    }

    /// BT5 (items 5a/5b): arming (Option+N set) or disarming (Option+B toggle) the bullseye is a MODE change
    /// tied to the CURRENT dictation — like the `?` cleanup toggle, it must NOT cancel the in-flight take. The
    /// pure contract: arm/disarm never cancels (never idles) the take, so the controller no longer discards the
    /// incidental audio on `notes()` / `toggleBullseye()`; the take keeps recording and state-at-release decides
    /// how it lands.
    static func armDisarmCancelsTake() -> Bool { false }
}

/// The live, persistent bullseye state (notes-bullseye BT2). One process-wide holder, mirroring
/// `CleanupState.shared`: it owns the single `NotesBullseye`, persists it to UserDefaults, confirms the
/// persisted value against currently-open notes exactly once on first use (restore), and exposes the
/// mutations the controller / registry drive (set-at-caret + arm, Option+B toggle, anchor updates from the
/// web island, runtime auto-disarm when the note is gone). The pure rules live in `NotesBullseyeLogic`;
/// this class is the stateful, side-effecting shell around them (UserDefaults + the store), so it is NOT
/// exercised by the headless probe (which pins the pure logic instead).
final class NotesBullseyeState {
    static let shared = NotesBullseyeState(store: .shared)

    private static let storeKey = "notesBullseye"

    private let store: StickyNotesStore
    private let defaults: UserDefaults
    private var bullseye: NotesBullseye?
    private var didRestore = false

    init(store: StickyNotesStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.bullseye = Self.loadPersisted(defaults)
    }

    // MARK: reads (all confirm the restore first)

    /// The current bullseye (nil = none set), after confirming the persisted value against open notes.
    var current: NotesBullseye? { ensureRestored(); return bullseye }

    /// True when a bullseye is set AND armed — the info-pill glyph gate + the delivery precedence gate.
    var armed: Bool { NotesBullseyeLogic.isArmed(current) }

    /// The armed bullseye's note id (for routing delivery), or nil when nothing is armed/set.
    var noteId: String? { current?.noteId }

    // MARK: mutations

    /// Set/move the bullseye to note `id` and ARM it (Option+N in a note). The precise caret offset is
    /// reported back asynchronously by the web island (`updateAnchor`); we seed an anchor of 0 so the armed
    /// state + note id persist immediately even if the app quits before the report lands.
    func setAtCaret(noteId id: String) {
        ensureRestored()
        bullseye = NotesBullseye(noteId: id, anchor: 0, armed: true)
        persist()
    }

    /// Update the last-known anchor offset for `noteId` (the web island reports it on set and on each
    /// follow-edits remap). Ignored when the bullseye moved to another note in the meantime.
    func updateAnchor(noteId id: String, anchor: Int) {
        ensureRestored()
        guard var b = bullseye, b.noteId == id, b.anchor != anchor else { return }
        b.anchor = anchor
        bullseye = b
        persist()
    }

    /// Option+B: pure toggle of the armed flag, preserving location. Returns the outcome so the caller can
    /// toast + refresh the info pill (`.noneSet` = "No bullseye set").
    func toggle() -> NotesBullseyeLogic.ToggleOutcome {
        ensureRestored()
        let outcome = NotesBullseyeLogic.toggled(bullseye)
        if case .toggled(let b) = outcome { bullseye = b; persist() }
        return outcome
    }

    /// BT6 (reveal): ARM the bullseye in place, without moving it. Distinct from `toggle()` (which flips) and
    /// from `setAtCaret` (which relocates): the reveal chord must leave a disarmed bullseye armed and an
    /// already-armed one untouched. Returns true only when it actually changed the flag, so the caller can
    /// refresh the info pill exactly once.
    @discardableResult
    func arm() -> Bool {
        ensureRestored()
        guard var b = bullseye, !b.armed else { return false }
        b.armed = true
        bullseye = b
        persist()
        return true
    }

    /// Runtime auto-disarm: drop the bullseye iff its note is no longer open (closed/deleted). Returns true
    /// ONLY when it just dropped a live bullseye, so the caller fires the toast exactly once (a
    /// restore-time drop happens silently inside `ensureRestored` and returns false here).
    @discardableResult
    func autoDisarmIfGone(openNoteIds: Set<String>) -> Bool {
        ensureRestored()
        guard let b = bullseye, !NotesBullseyeLogic.survives(b, openNoteIds: openNoteIds) else { return false }
        bullseye = nil
        persist()
        return true
    }

    /// Drop the bullseye unconditionally (the delivery-time gone race: the note vanished between arming and
    /// landing). Persists the cleared state.
    func drop() {
        ensureRestored()
        bullseye = nil
        persist()
    }

    // MARK: restore + persistence

    /// Confirm the persisted bullseye against currently-open notes exactly once, lazily, before any read or
    /// mutation. A bullseye whose note is gone (deleted between sessions) is dropped silently; one whose
    /// note still exists is kept with its persisted armed flag. Uses `store.openNotes()` — the persisted
    /// truth — so it is independent of whether any web view has materialized yet.
    private func ensureRestored() {
        guard !didRestore else { return }
        didRestore = true
        let openIds = Set(store.openNotes().map(\.id))
        let restored = NotesBullseyeLogic.restored(bullseye, openNoteIds: openIds)
        if restored != bullseye {
            bullseye = restored
            persist()
        }
    }

    private func persist() {
        if let b = bullseye, let data = try? JSONEncoder().encode(b) {
            defaults.set(data, forKey: Self.storeKey)
        } else {
            defaults.removeObject(forKey: Self.storeKey)
        }
    }

    private static func loadPersisted(_ defaults: UserDefaults) -> NotesBullseye? {
        guard let data = defaults.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(NotesBullseye.self, from: data)
    }
}
