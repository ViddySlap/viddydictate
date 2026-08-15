import Foundation

/// Pure decision + modelling logic for the BT5 take controls (notes-bullseye BT5):
///   - Esc CANCELS the in-progress dictation take (abort record/processing; nothing lands; the target
///     selection + any BT4 replace highlight left untouched/cleared);
///   - Option+Z NOTES cross-focus undo: revert the last ViddyDictate-delivered edit IN A NOTE even when focus
///     has moved away. A note is a controlled surface, so the bridge can reach back in by note id and undo it,
///     restoring any overwritten text — something a foreign app's native undo cannot do cross-focus. The
///     existing foreign-app Option+Z tier (in-place backspace / raw-to-clipboard, the pending Gmail email-undo)
///     is left as-is; this only ADDS the notes reach-back when the last delivery landed in a note.
///
/// These functions carry NO AppKit / CodeMirror state so the `--notes-probe` seam can lock the contract
/// headlessly; the live editor executes the equivalent CodeMirror dispatch (`undoNoteDelivery` /
/// `mapLastDeliveryThroughChanges` in the bundled web island), and the bridge-parity + string-presence probe
/// checks assert that JS ships it.
enum NotesUndoLogic {

    /// User-facing toasts (the substrings the probe pins). Reverting reaches the note by id; a gone note (closed
    /// to history / deleted — no live window holds it) cannot be reached back into, so we say so rather than
    /// silently no-op.
    static let notesRevertToast = "Reverted note dictation"
    static let notesGoneToast = "Note is gone — can't undo"

    /// A recorded ViddyDictate note delivery: the mapped insertion range in the note (`[from, from+insertedLen)`)
    /// plus the text it OVERWROTE (empty for a bare-caret insert). The undo replaces that range with `replaced`,
    /// removing the delivered text and restoring anything it overwrote. Mirrors the JS `lastDelivery` store.
    struct Delivery: Equatable {
        let noteId: String
        let from: Int
        let insertedLen: Int
        let replaced: String
    }

    /// Which path Option+Z takes. When the last delivery landed in a note (a non-empty pending note id), the
    /// reach-back note-undo wins; otherwise the existing foreign-app tier decides (unchanged). The two are
    /// mutually exclusive by construction — each delivery records exactly one — but routing here keeps the
    /// precedence in one testable place.
    enum Route: Equatable {
        case note(id: String)
        case foreign
    }

    static func route(pendingNoteId: String?) -> Route {
        if let id = pendingNoteId, !id.isEmpty { return .note(id: id) }
        return .foreign
    }

    /// Whether Esc should ABORT the current take. Esc cancels only while a take is actually in flight (recording,
    /// hands-free locked, or the final transcribe/cleanup processing) — otherwise Esc is a normal key and passes
    /// through to the focused app. Nothing lands on an abort. Mirrors the `takeActive` gate the tap swallows on.
    static func escapeAborts(isTakeActive: Bool) -> Bool { isTakeActive }

    /// Splice: replace `doc[from, to)` (clamped) with `insert`, character-wise. A pure model of the CodeMirror
    /// `insertAtRange` dispatch the island runs (CodeMirror offsets are UTF-16 units; the probe drives ASCII,
    /// where a Character count matches, so this stays a faithful headless mirror).
    static func spliced(_ doc: String, from: Int, to: Int, insert: String) -> String {
        var chars = Array(doc)
        let lo = max(0, min(from, chars.count))
        let hi = max(lo, min(to, chars.count))
        chars.replaceSubrange(lo..<hi, with: Array(insert))
        return String(chars)
    }

    /// Model a note delivery: overwrite `doc[from, to)` with `insert`, returning the resulting doc AND the undo
    /// record (the overwritten text + the inserted length) needed to reverse it. A bare caret (`from == to`)
    /// inserts (empty `replaced`); a selection overwrites (non-empty `replaced`).
    static func applyDelivery(doc: String, from: Int, to: Int, insert: String,
                              noteId: String = "") -> (after: String, record: Delivery) {
        let chars = Array(doc)
        let lo = max(0, min(min(from, to), chars.count))
        let hi = max(lo, min(max(from, to), chars.count))
        let replaced = String(chars[lo..<hi])
        let after = spliced(doc, from: lo, to: hi, insert: insert)
        return (after, Delivery(noteId: noteId, from: lo, insertedLen: insert.count, replaced: replaced))
    }

    /// Reverse a recorded delivery: replace the delivered range `[from, from+insertedLen)` with the overwritten
    /// text. Applied to the post-delivery doc, this restores the exact pre-delivery doc (removing the dictation
    /// and putting back anything it overwrote).
    static func applyUndo(doc: String, record: Delivery) -> String {
        spliced(doc, from: record.from, to: record.from + record.insertedLen, insert: record.replaced)
    }
}
