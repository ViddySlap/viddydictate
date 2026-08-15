import Cocoa

/// The complete notes JS-bridge surface. Supplying this bundle at construction makes a missing registry
/// wire a compile-time error instead of silently degrading through an optional callback.
struct NotesDeliveryCallbacks {
    /// BT1: snapshot the note target at take-START (the caret's `{note id, anchor}` when a notes window is key
    /// and holds an active note), or nil to keep today's key-window delivery. The `Int` is the gesture generation
    /// stamped onto the `snapshotTarget` payload for the JS store's write guard (refine2 BUG 2).
    let onSnapshotNoteTarget: (Int) -> NotesDictationTarget?
    /// BT1: deliver a completed take to its snapshotted target by note id (focus-independent). `.noWindow` means
    /// the target is gone (closed to history / deleted) — the take is parked on the clipboard.
    let onDeliverToNoteTarget: (NotesDictationTarget, String) -> NoteInsertOutcome
    /// Dictation into the Notes window inserts through the JS bridge at the editor caret (we own the WKWebView).
    let onInsertIntoActiveNote: (String) -> NoteInsertOutcome
    /// BT2: Option+N dual-purpose sets/moves the pinned bullseye at the active note's caret. Returns the note id
    /// when gated in, or nil to keep Option+N's open/focus behavior.
    let onSetBullseyeAtCaret: () -> String?
    /// BT2: deliver an armed take to the pinned bullseye's note by id (focus-independent).
    let onDeliverToBullseye: (String) -> NoteInsertOutcome
    /// BT3: refresh the inline bullseye marker after its armed state changes.
    let onBullseyeStateChanged: () -> Void
    /// BT6: Option+Shift+N reveal — front the bullseye's window, select its tab, arm it if disarmed, and scroll
    /// its anchor into view. Returns what happened so the caller can toast the two honest failures.
    let onRevealBullseye: () -> NotesBullseyeLogic.RevealOutcome
    /// BT4: resolve the note that would receive an Option+P replace highlight.
    let onResolveReplaceHighlightTarget: () -> String?
    /// BT4: show or live-update the four-color replace highlight.
    let onShowReplaceHighlight: (String, String, Int) -> Void
    /// BT4: clear the replace highlight on a note.
    let onClearReplaceHighlight: (String) -> Void
    /// BT5: undo the last ViddyDictate delivery in the note with this id.
    let onUndoNoteDelivery: (String) -> Bool
    /// Explicit provider retry: replace the mapped last note delivery with the confirmed output.
    let onReplaceNoteDelivery: (String, String) -> Bool
    /// BT5: resolve the key notes window's active note id for the plain key-window insertion path.
    let onCurrentNoteId: () -> String?
}

/// The Family-3 notes-delivery collaborator (ADR 0012).
///
/// ADR 0010 lifted the Family-2 one-shot command flows off `DictationController` into `OneShotRegistry`.
/// The notes-bullseye / replace-highlight / note-target / cross-focus-undo family (BT1–BT5) then landed
/// directly on the controller with none of that discipline, regrowing it 723 → 1075. This type applies the
/// 0010 playbook to that third family: it OWNS the family's state (the three fields below), the notes
/// JS-bridge callbacks (wired by `AppDelegate`, exactly as they used to be wired onto the controller), and
/// the notes-delivery LOGIC (bullseye set/toggle, replace-highlight refresh/teardown, note-target snapshot,
/// cross-focus note-undo routing, and the `finalize()` notes-routing arms).
///
/// It is an **extract-class collaborator, NOT a data-driven registry** — there is exactly one bullseye and
/// one note-target concept, not N interchangeable modes, so a descriptor table would be a registry of one.
///
/// **Seam boundary (ADR 0012, load-bearing):** the coordinator owns state + the notes JS-bridge decisions,
/// and it NEVER touches the HUD. The Option+N / Option+B hotkey entry points stay thin on the controller and
/// keep their `hud.toast(...)` there; `finalize()` keeps its `hud.hide()`/`hud.toast()` tail on the
/// controller and applies the landing this type returns. That is what lets a later link gate the mid-take
/// toast at the controller without reaching in here. Every method below is a verbatim move of the
/// controller's pre-extraction code (same callbacks, same order, same conditions) — a zero-behavior refactor.
final class NotesDeliveryCoordinator {

    private let callbacks: NotesDeliveryCallbacks
    private let bullseyeState: NotesBullseyeState
    private let copyToClipboard: (String) -> Void

    init(callbacks: NotesDeliveryCallbacks,
         bullseyeState: NotesBullseyeState = .shared,
         copyToClipboard: @escaping (String) -> Void = TargetResolver.copyToClipboard) {
        self.callbacks = callbacks
        self.bullseyeState = bullseyeState
        self.copyToClipboard = copyToClipboard
    }

    // MARK: state (moved off DictationController)

    /// BT1 (notes-bullseye): the transient note target snapshotted at take-START — set only when the take began
    /// with the caret in a sticky note. When present, delivery routes to this note BY ID (even if focus moved
    /// during the take) instead of the key-window path. Cleared after each take.
    var noteTarget: NotesDictationTarget?

    /// BT4 (notes-bullseye): the note currently showing a dictation-take replace highlight (a take that began
    /// overwriting a selection in a sticky note), or nil. Held so a mid-take `?`-cleanup level change can
    /// live-update the tint color, and so cancel/commit can clear it. Set at take-START, cleared at teardown.
    var replaceHighlightNoteId: String?

    /// BT5 (notes-bullseye): the note id of the LAST delivery that landed in a sticky note, or nil when the last
    /// delivery was a foreign-app / clipboard landing. Option+Z reverts this by reaching back into the note by id
    /// (a note is a controlled surface, so the bridge can undo it even when focus has moved away). Mutually
    /// exclusive with the controller's `pendingUndo`: every delivery records exactly one, so Option+Z routing is
    /// unambiguous. Every successful landing tail enforces this: `landDelivery` (the finalize tail) and
    /// `landInPlaceTransform` (the email / Cleanup-selection in-place tail) each reset it to nil when the landing
    /// does not target a note.
    var pendingNoteUndo: String?

    /// The monotonic take/gesture id (refine2 BUG 2). The controller bumps it once per take at `beginRecording`;
    /// this coordinator stamps it onto every `snapshotTarget` + `replaceHighlight` bridge payload it sends, so
    /// the JS snapshot store can guard on it: a same-gesture collapsed re-read (the replace-highlight tint
    /// collapses the live selection) never clobbers the live range captured at take-start, while a genuinely
    /// newer gesture always wins. One authoritative note-selection range per gesture, owned here.
    var gestureGeneration = 0

    // MARK: bullseye (Option+N set/arm, Option+B toggle)

    /// The Option+B toggle outcome the thin controller entry point switches on. `.noneSet` toasts on the
    /// controller side (there is nothing to reflect); `.toggled` refreshes the info-pill + rebroadcasts the
    /// inline marker (both driven from the controller so the HUD call stays there).
    enum BullseyeToggle { case toggled, noneSet }

    /// BT2: Option+N set/move + arm the pinned bullseye at the key window's active-note caret. Returns the note
    /// id (armed) or nil (keep Option+N's open/focus behavior). The registry broadcasts the inline marker itself.
    func setBullseyeAtCaret() -> String? { callbacks.onSetBullseyeAtCaret() }

    /// Option+B: pure toggle of the pinned bullseye's ARMED state (location preserved). Logs like the pre-move
    /// controller body; the info-pill refresh + marker rebroadcast + the "No bullseye set" toast stay on the
    /// controller so no HUD call moves here.
    func toggleBullseye() -> BullseyeToggle {
        switch NotesBullseyeState.shared.toggle() {
        case .toggled(let b):
            Log.write("bullseye toggle -> \(b.armed ? "armed" : "disarmed") (note \(b.noteId))")
            return .toggled
        case .noneSet:
            Log.write("bullseye toggle: none set")
            return .noneSet
        }
    }

    /// BT3: rebroadcast the inline bullseye marker to the notes islands (the registry side). Called by the
    /// controller after an Option+B toggle / a delivery-time drop.
    func broadcastBullseyeState() { callbacks.onBullseyeStateChanged() }

    /// Option+Shift+N (BT6): reveal where the bullseye is. All four navigation steps happen on the registry
    /// side (it owns the windows); the two failure toasts stay on the controller, keeping this seam HUD-free.
    func revealBullseye() -> NotesBullseyeLogic.RevealOutcome { callbacks.onRevealBullseye() }

    // MARK: replace highlight (BT4)

    /// BT4: (re)push the dictation-take replace highlight at the CURRENT `?`-cleanup level, so a mid-take
    /// toggle/level change live-updates the tint color. No-op when no take is showing a replace highlight
    /// (`replaceHighlightNoteId` nil), so it is safe to call from the idle cleanup-change handlers too.
    func refreshReplaceHighlightLevel() {
        guard let id = replaceHighlightNoteId else { return }
        let level = NotesReplaceHighlightLogic.level(cleanupEnabled: CleanupState.shared.cleanupEnabled,
                                                     cleanupLevel: CleanupState.shared.cleanupLevel)
        callbacks.onShowReplaceHighlight(id, level.rawValue, gestureGeneration)
    }

    /// BT4: clear the dictation-take replace highlight, if any (take canceled or committed). Idempotent.
    func teardownReplaceHighlight() {
        guard let id = replaceHighlightNoteId else { return }
        replaceHighlightNoteId = nil
        callbacks.onClearReplaceHighlight(id)
    }

    /// BT4 (Option+P pick): resolve the key window's active note (nil for a foreign-app selection — not tinted,
    /// CodeMirror-only), push the tint at `level`, and return the note id so the flow can live-update / clear it.
    func showReplaceHighlight(level: String) -> String? {
        guard let id = callbacks.onResolveReplaceHighlightTarget() else { return nil }
        callbacks.onShowReplaceHighlight(id, level, gestureGeneration)
        return id
    }

    /// BT4: recolor the Option+P replace highlight as the pick moves (Cleanup / Tighten / Summarize).
    func updateReplaceHighlight(noteId: String, level: String) {
        callbacks.onShowReplaceHighlight(noteId, level, gestureGeneration)
    }

    /// BT4: clear the Option+P replace highlight (the pick was canceled or committed).
    func clearReplaceHighlight(noteId: String) { callbacks.onClearReplaceHighlight(noteId) }

    // MARK: note-target snapshot (BT1)

    /// BT1: snapshot the take's note target at take-START into `noteTarget` (nil keeps today's key-window path),
    /// stamping the current `gestureGeneration` onto the `snapshotTarget` payload. This is now the SINGLE writer
    /// of the note-selection snapshot per gesture (refine2 BUG 2): the one-shot selection-transform flow reuses
    /// THIS captured `noteTarget` instead of re-snapshotting the (by-then collapsed) live selection. Returns its
    /// id for the caller's begin log line. Paired with `armReplaceHighlightForTake()` so the caller's begin-log
    /// line keeps its original position between the snapshot and the tint.
    func captureNoteTargetForTake() -> String? {
        noteTarget = callbacks.onSnapshotNoteTarget(gestureGeneration)
        return noteTarget?.noteId
    }

    /// BT4: a take that started overwriting a selection in a note tints that range by the active `?`-cleanup
    /// level (Raw when cleanup is off) so the user sees what will be replaced. Gated on NOT armed: an armed
    /// bullseye take delivers to the bullseye (an insert point), so nothing is overwritten and nothing is tinted.
    /// The island no-ops on a bare-caret snapshot. No-op when the take did not start in a note.
    func armReplaceHighlightForTake() {
        guard let nt = noteTarget, !NotesBullseyeState.shared.armed else { return }
        replaceHighlightNoteId = nt.noteId
        refreshReplaceHighlightLevel()
    }

    // MARK: cross-focus note undo (BT5)

    /// The Option+Z note-undo outcome the thin controller `undo()` switches on. `.reverted`/`.gone` each toast on
    /// the controller side; `.notNote` falls through to the controller's foreign-app undo tier.
    enum NoteUndoResult { case reverted, gone, notNote }

    /// BT5: if the last delivery landed in a note (a non-empty pending note id), reach BACK into that note by id
    /// and revert the edit even when focus has moved away. Clears `pendingNoteUndo` when it owned the last
    /// landing. `.notNote` means the last landing was foreign-app (the controller's existing tier decides).
    func undoLastNoteDelivery() -> NoteUndoResult {
        guard case let .note(noteId) = NotesUndoLogic.route(pendingNoteId: pendingNoteUndo) else { return .notNote }
        pendingNoteUndo = nil
        if callbacks.onUndoNoteDelivery(noteId) {
            Log.write("undo: reverted last note delivery in \(noteId)")
            return .reverted
        } else {
            Log.write("undo: note \(noteId) gone — cannot revert")
            return .gone
        }
    }

    func replaceLastNoteDelivery(noteId: String, text: String) -> Bool {
        callbacks.onReplaceNoteDelivery(noteId, text)
    }

    // MARK: one-shot selection-transform landing helpers (for the controller's landSelectionTransform)

    /// Insert into the key notes window's active note through the JS bridge. `.noWindow` when no window is live.
    func insertIntoActiveNote(_ text: String) -> NoteInsertOutcome {
        callbacks.onInsertIntoActiveNote(text)
    }

    // MARK: shared delivery routing

    /// What `routeNotesDelivery` decided, applied by the controller (which owns the HUD + the foreign-app
    /// `pendingUndo`). See ADR 0012: the coordinator never touches the HUD.
    enum NotesLanding: Equatable {
        /// Delivered/queued into a note. Controller: `pendingUndo = nil`, `pendingNoteUndo = noteUndo`, hide.
        case landed(noteUndo: String?)
        /// The take routed to a note whose note was gone at delivery: this coordinator already parked it on the
        /// clipboard (and, for a gone armed bullseye, dropped it + rebroadcast the marker). Controller:
        /// `refreshBullseyeIndicator()` iff `refreshBullseye`, `pendingUndo = makePendingUndo(…, false)`,
        /// `pendingNoteUndo = nil`, then toast.
        case parked(toast: String, refreshBullseye: Bool)
        /// Not a notes take — the controller continues to its foreign-app delivery path.
        case notNotes
    }

    /// The one owner of the notes precedence ladder. Raw / `?` delivery and one-shot in-place delivery both
    /// call this method with their landing kind and input source. The pure rule decides bullseye versus snapshot
    /// versus the requested destination; this stateful shell performs the chosen bridge delivery and gone-note
    /// recovery. The controller still owns the HUD application of the returned landing.
    func routeNotesDelivery(delivered: String, mode: HistoryMode,
                            landingKind: NotesBullseyeLogic.LandingKind,
                            inputSource: NotesBullseyeLogic.InputSource,
                            noteTarget: NotesDictationTarget?,
                            shouldInsertIntoNotes: Bool,
                            startedInNotes: Bool, currentlyKey: Bool) -> NotesLanding {
        let route = NotesBullseyeLogic.delivery(
            bullseye: bullseyeState.current,
            snapshotNoteId: noteTarget?.noteId,
            landingKind: landingKind,
            inputSource: inputSource)

        switch route {
        case .bullseye(let bullseyeNoteId):
            // The target vanished between the precedence decision and the bridge delivery. Drop the persistent
            // target and park the output so the fresh dictation is never lost.
            switch callbacks.onDeliverToBullseye(delivered) {
            case .delivered, .queued:
                Log.write("deliver: landed at armed bullseye (\(delivered.count) chars, mode=\(mode))")
                return .landed(noteUndo: bullseyeNoteId)
            case .noWindow:
                Log.write("deliver: bullseye note gone at delivery, auto-disarm + clipboard park (\(delivered.count) chars, mode=\(mode))")
                bullseyeState.drop()
                callbacks.onBullseyeStateChanged()   // BT3: clear the inline marker (the bullseye just dropped)
                copyToClipboard(delivered)
                return .parked(toast: "📋 " + NotesBullseyeLogic.deliverGoneToast, refreshBullseye: true)
            }

        case .snapshot:
            guard let noteTarget = noteTarget else { return .notNotes }
            let outcome = callbacks.onDeliverToNoteTarget(noteTarget, delivered)
            switch NotesTargetLogic.landing(for: outcome) {
            case .delivered:
                Log.write("deliver: landed at snapshotted note target \(noteTarget.noteId) (\(delivered.count) chars, mode=\(mode), outcome=\(outcome))")
                return .landed(noteUndo: noteTarget.noteId)
            case .clipboardParked(let toast):
                // Selection transforms historically fall back to their captured foreign/focus path when the
                // note target is gone. Preserve that behavior; dictation takes retain the durable clipboard park.
                if inputSource == .selection {
                    Log.write("selection-transform target \(noteTarget.noteId) gone - falling back to focus path (\(delivered.count) chars)")
                    return .notNotes
                }
                Log.write("deliver: note target \(noteTarget.noteId) gone, copied to clipboard (\(delivered.count) chars, mode=\(mode))")
                copyToClipboard(delivered)
                return .parked(toast: "📋 " + toast, refreshBullseye: false)
            }

        case .requested:
            break
        }

        // Dictation into the Notes window keeps the normal mode pipeline (raw vs cleanup/email/etc.) and changes
        // only the landing: because we own the WKWebView, insert through the bridge at the editor caret instead
        // of synthesizing a paste back into our own app.
        if shouldInsertIntoNotes {
            // BT5: the key-window insert path knows its note only via the registry's active note id (the BT1/BT2
            // branches above carry their own id). Resolve it now so Option+Z can reach back into the note.
            let keyNoteId = callbacks.onCurrentNoteId()
            switch callbacks.onInsertIntoActiveNote(delivered) {
            case .delivered:
                Log.write("deliver: inserted into active sticky note (\(delivered.count) chars, mode=\(mode), startNotes=\(startedInNotes), currentNotes=\(currentlyKey))")
                return .landed(noteUndo: keyNoteId)
            case .queued:
                // The bridge deferred it (page reloading after a WebContent crash); the queue flushes on the next
                // ready. No clipboard fallback here — that would double-deliver once it flushes.
                Log.write("deliver: sticky-note insert queued until page ready (\(delivered.count) chars, mode=\(mode))")
                return .landed(noteUndo: keyNoteId)
            case .noWindow:
                Log.write("deliver: sticky-note bridge unavailable, copied to clipboard (\(delivered.count) chars, mode=\(mode))")
                copyToClipboard(delivered)
                return .parked(toast: "📋 Sticky note unavailable — transcript copied", refreshBullseye: false)
            }
        }

        return .notNotes
    }
}
