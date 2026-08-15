import Cocoa

private typealias BridgeKey = NotesBridgePayloadKey

extension NotesWindowController {
    // MARK: - Note-target snapshot delivery (notes-bullseye BT1)

    /// Tell this window's live editor to snapshot a dictation target at note `id` (the caret/selection becomes a
    /// CodeMirror-mapped anchor that follows edits). Called at take-START when this window is key and holds the
    /// active note. No-op when the page is not ready — the caller only snapshots a key, materialized window.
    func snapshotNoteTarget(id: String, generation: Int) {
        guard pageReady else { return }
        call(.snapshotTarget, payload: [BridgeKey.id: id, BridgeKey.generation: generation])
    }

    /// Land a completed take at note `id`'s snapshotted anchor, reaching the note even when this window is NOT
    /// key (the target-by-note-id path). Brings the target tab live if needed and replaces the snapshotted range
    /// (or inserts at the caret), then re-persists via the save round-trip. Returns `.delivered` when the page
    /// was ready, `.queued` otherwise (a rare mid-take WebContent crash — the take is queued, not lost), and
    /// `.noWindow` only when the window is already torn down. Must be called on the main thread.
    @discardableResult
    func insertAtNoteTarget(id: String, text: String) -> NoteInsertOutcome {
        guard window != nil else {
            Log.write("sticky notes target insert requested but window is nil")
            return .noWindow
        }
        if pageReady {
            call(.insertAtTarget, payload: [BridgeKey.id: id, BridgeKey.text: text])
            return .delivered
        }
        Log.write("sticky notes target insert queued until page ready (\(text.count) chars)")
        outboundQueue.enqueueInsertion(text)
        return .queued
    }

    // MARK: - Bullseye set/arm delivery (notes-bullseye BT2)

    /// Pin the persistent bullseye at note `id`'s current caret (Option+N in a note). The web island captures
    /// the caret offset as a CodeMirror-mapped anchor that follows edits, and reports it back via
    /// `bullseyeAnchor` for persistence. No-op when the page is not ready (the caller only pins on a key,
    /// materialized window). Main thread.
    func setBullseyeAtCaret(id: String) {
        guard pageReady else { return }
        call(.setBullseye, payload: [BridgeKey.id: id])
    }

    /// Land an armed take at note `id`'s pinned bullseye anchor, reaching the note even when this window is NOT
    /// key (the target-by-note-id path). Brings the target tab live if needed, inserts at the anchor WITHOUT
    /// clearing the bullseye (it is persistent), and advances the anchor so successive takes stack. Returns
    /// `.delivered`/`.queued`/`.noWindow` like the BT1 target insert. Main thread.
    @discardableResult
    func insertAtBullseye(id: String, text: String) -> NoteInsertOutcome {
        guard window != nil else {
            Log.write("sticky notes bullseye insert requested but window is nil")
            return .noWindow
        }
        if pageReady {
            call(.insertAtBullseye, payload: [BridgeKey.id: id, BridgeKey.text: text])
            return .delivered
        }
        Log.write("sticky notes bullseye insert queued until page ready (\(text.count) chars)")
        outboundQueue.enqueueInsertion(text)
        return .queued
    }

    // MARK: - Bullseye reveal (notes-bullseye BT6)

    /// Scroll note `id`'s pinned bullseye anchor into view in this window's island (Option+Shift+N). The
    /// caller has already fronted the window and selected the tab; this is the last of the four reveal steps.
    /// Read-only in the editor — no edit, no bullseye move, no selection change. Returns false when the page is
    /// not ready yet, so the caller can report an honest failure instead of a silent no-op. Main thread.
    @discardableResult
    func revealBullseye(id: String) -> Bool {
        guard window != nil, pageReady else {
            Log.write("sticky notes bullseye reveal requested but window unavailable (id \(id))")
            return false
        }
        call(.revealBullseye, payload: [BridgeKey.id: id])
        return true
    }

    // MARK: - Inline bullseye marker (notes-bullseye BT3)

    /// Push the current bullseye marker state to this window's island so it can render (or hide) the inline
    /// armed-bullseye marker. Carries the note id, last-known anchor, and the armed flag; the island shows the
    /// glyph only when armed AND the note is the active tab in THIS window (so the marker appears in exactly
    /// the one place the note is visible). Nil (no bullseye) hides it everywhere. No-op until the page is
    /// ready. Main thread.
    func pushBullseyeArmed(_ bullseye: NotesBullseye?) {
        guard pageReady else { return }
        if let b = bullseye {
            call(.bullseyeArmed, payload: [BridgeKey.id: b.noteId, BridgeKey.anchor: b.anchor,
                                           BridgeKey.enabled: b.armed])
        } else {
            call(.bullseyeArmed, payload: [BridgeKey.id: "", BridgeKey.anchor: 0, BridgeKey.enabled: false])
        }
    }

    // MARK: - Four-color replace highlight (notes-bullseye BT4)

    /// Push / live-update / clear the four-color replace highlight for note `id` in this window's island. A
    /// non-empty `level` (raw / cleanup / tighten / summarize) tints the note's current selection (first push)
    /// or swaps the color of the already-tinted range (a level change); an empty `level` clears it. The island
    /// no-ops on a bare caret (nothing to replace) or when the note is not its active tab, so this only ever
    /// tints a real replace target. No-op until the page is ready. Main thread.
    func showReplaceHighlight(id: String, level: String, generation: Int = 0) {
        guard pageReady else { return }
        call(.replaceHighlight, payload: [BridgeKey.id: id, BridgeKey.level: level, BridgeKey.generation: generation])
    }

    // MARK: - Notes cross-focus undo (notes-bullseye BT5)

    /// Revert the last ViddyDictate dictation edit in note `id`, reaching the note even when this window is NOT
    /// key (the target-by-note-id path). The island restores any text the delivery overwrote and removes the
    /// delivered text (its recorded, follow-edits `lastDelivery` range). Returns `true` when the reach-back could
    /// be issued (a live, ready window holds the note), `false` otherwise (torn down / mid-reload) so the caller
    /// can toast that the note is gone. Main thread.
    @discardableResult
    func undoNoteDelivery(id: String) -> Bool {
        guard window != nil, pageReady else {
            Log.write("sticky notes undo requested but window unavailable (id \(id))")
            return false
        }
        call(.undoNoteDelivery, payload: [BridgeKey.id: id])
        return true
    }

    /// Replace the mapped last delivery range with explicit-retry output, preserving the pre-delivery text
    /// as the next note-undo source. Same reach-by-note-id readiness gate as `undoNoteDelivery`.
    @discardableResult
    func replaceNoteDelivery(id: String, text: String) -> Bool {
        guard window != nil, pageReady else {
            Log.write("sticky notes retry landing unavailable (id \(id))")
            return false
        }
        call(.replaceNoteDelivery, payload: [BridgeKey.id: id, BridgeKey.text: text])
        return true
    }
}
