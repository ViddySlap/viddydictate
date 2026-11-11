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
