import Foundation

/// A snapshotted dictation destination inside a sticky note (notes-bullseye BT1). Captured at take-START when
/// a notes window is key and an active note holds the caret; delivery reaches this note BY ID even if
/// focus/selection moved during the take (the target-by-note-id insert path, not the key-window path). The
/// snapshot is TRANSIENT — one take, then cleared. Notes-only.
///
/// The anchored POSITION itself lives in the note's live CodeMirror editor as a mapped position that follows
/// edits (typing above it shifts it) — only CodeMirror can map a position through changes. This Swift value
/// carries just the note id, which is all Swift needs to route delivery back to the right note; the web island
/// owns the anchor + the selection-vs-caret distinction.
struct NotesDictationTarget: Equatable {
    let noteId: String
}

/// Pure decision + modelling logic for the BT1 note-target flow. These functions carry NO AppKit / CodeMirror
/// state so the `--notes-probe` seam can lock the contract headlessly; the live editor executes the equivalent
/// CodeMirror dispatch (`insertAtTarget` / `mapSnapshotThroughChanges` in the bundled web island), and the
/// bridge-parity + string-presence probe checks assert that JS ships it.
enum NotesTargetLogic {

    /// The user-facing pill toast + the substring the probe pins when a snapshotted target is gone at delivery.
    static let targetGoneToast = "note target gone, copied to clipboard"

    /// The edit a snapshotted anchor produces at delivery: a bare caret (`from == to`) INSERTS at the anchor;
    /// a non-empty selection REPLACES the range. Mirrors the CodeMirror dispatch the web island runs, so a
    /// take started on a selection overwrites it while a bare-caret take inserts in place.
    enum TargetEdit: Equatable {
        case insert(at: Int)
        case replace(from: Int, to: Int)
    }

    static func targetEdit(from: Int, to: Int) -> TargetEdit {
        let lo = min(from, to), hi = max(from, to)
        return lo == hi ? .insert(at: lo) : .replace(from: lo, to: hi)
    }

    /// One write into the BT1 snapshot store, tagged with the monotonic take/gesture generation it belongs to.
    /// `from == to` is a bare-caret (collapsed) write; `from != to` is a live selection range.
    struct SnapshotWrite: Equatable {
        let from: Int
        let to: Int
        let generation: Int
        var isEmpty: Bool { from == to }
    }

    /// The snapshot store's write guard (mirrors dictation-target.js `setSnapshot`). Refuses a write that would
    /// CLOBBER a fresher, non-empty snapshot for the same note — the exact interleaving the Option+P-over-a-note
    /// selection bug hit: take-start captured the live selection `{from,to}` (non-empty), the replace-highlight
    /// tint then COLLAPSED the live selection, and the command chord's re-snapshot re-read that collapsed caret
    /// and overwrote the good range with a degenerate `{X,X}`, so delivery inserted-at-a-point instead of
    /// replacing. The rule: a write from an OLDER generation never wins; within the SAME generation an EMPTY
    /// (`from == to`) write never overwrites a non-empty snapshot (the collapsed re-read); a NEWER generation
    /// ALWAYS wins (a fresh take legitimately re-snapshots, even to a bare caret, so a genuinely new bare-caret
    /// gesture is not blocked by a stale range). Makes the whole bridge robust to this class, not just Option+P.
    static func acceptsSnapshotWrite(existing: SnapshotWrite?, incoming: SnapshotWrite) -> Bool {
        guard let existing = existing else { return true }
        if incoming.generation < existing.generation { return false }
        if incoming.generation == existing.generation && incoming.isEmpty && !existing.isEmpty { return false }
        return true
    }

    /// The landing decision for a note-target delivery outcome. `.delivered`/`.queued` land in the note;
    /// `.noWindow` means the target is gone (closed to history / deleted — no live window holds it), so the
    /// take is parked on the clipboard with `targetGoneToast` rather than being lost.
    enum Landing: Equatable {
        case delivered
        case clipboardParked(toast: String)
    }

    static func landing(for outcome: NoteInsertOutcome) -> Landing {
        switch outcome {
        case .delivered, .queued: return .delivered
        case .noWindow:           return .clipboardParked(toast: targetGoneToast)
        }
    }

    /// The item-4 landing route for a one-shot SELECTION-transform result (Option+P cleanup-selection, the
    /// Option+M email selection arm, custom in-place modes). A selection captured inside a sticky note is
    /// remembered as a `NotesDictationTarget` at capture-START — before focus can move to the app the user
    /// tabs to during the LLM round-trip. The transform then lands BY NOTE ID through the SAME
    /// focus-independent `deliverToTarget` -> `insertAtNoteTarget` path a dictation take uses (which REPLACES
    /// the snapshotted range — exactly a selection-transform), so the result overwrites the ORIGINAL note text
    /// instead of pasting into whatever app is focused when the model returns. With no remembered target (the
    /// selection was in a foreign app, or none was in a note) it falls back to today's key-window bridge /
    /// `pasteIntoFocus`. Pure so `--notes-probe` pins the same fact `landSelectionTransform` branches on.
    enum SelectionTransformRoute: Equatable {
        case byNoteTarget    // focus-independent: deliverToTarget -> insertAtNoteTarget (replaces the range)
        case focusFallback   // today's key-window bridge / TargetResolver.pasteIntoFocus
    }

    static func selectionTransformRoute(noteTarget: NotesDictationTarget?) -> SelectionTransformRoute {
        noteTarget == nil ? .focusFallback : .byNoteTarget
    }

    /// Map an anchored position through one edit that replaced `[changeFrom, changeTo)` with `insertedLen`
    /// characters — the "anchor follows edits" rule the CodeMirror mapping enforces. An anchor wholly BEFORE
    /// the edit is unaffected; wholly AFTER, it shifts by the net length delta (so typing above the anchor
    /// moves it down, deleting above moves it up); strictly INSIDE a replaced range, it collapses to the
    /// change's new end. A pure integer model of `ChangeSet.mapPos` for the probe.
    static func mapPosition(_ pos: Int, changeFrom: Int, changeTo: Int, insertedLen: Int) -> Int {
        if pos <= changeFrom { return pos }
        let delta = insertedLen - (changeTo - changeFrom)
        if pos >= changeTo { return pos + delta }
        return changeFrom + insertedLen
    }
}
