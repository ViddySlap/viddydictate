/// The honest outcome of a bridge insertion. `insertDictation` used to return a bare `Bool` that was
/// `true` whenever the window merely existed (even when it only queued), so callers could not tell a
/// real delivery from a deferred one, and the clipboard-fallback safety net keyed off that unreliable
/// proxy. This makes the three states explicit (sticky-notes finding: misleading boolean contract).
enum NoteInsertOutcome {
    case delivered   // page was ready; text inserted into the active editor now
    case queued      // page not ready (e.g. mid crash+reload); appended to the flush queue
    case noWindow    // no notes window exists -- nothing accepted the text
}

/// The native <-> web-island bridge message contract. The raw values ARE the wire strings; keep these
/// cases in lockstep with the JS bridge names pinned by the probes.
enum NotesBridge {
    static let scriptHandler = "notes"
    static let webObject = "window.ViddyNotes"
}

enum NotesInbound: String, CaseIterable {
    case ready, save, active, close, restore
    // File-backed editor state: every real edit updates the native runtime buffer; timer/blur requests run the
    // fingerprint gate. Neither message is itself permission to blind-write.
    case fileBufferChanged, fileSync, fileReloadApplied
    case deleteHistory, copy, rename, saveAs, revealInFinder, noteToHandoff
    // Attachments (L3/L4): the web island posts these; the store owns the effect.
    // `duplicateAttachments` (L4) copies the source note's whole sidecar set onto the duplicate.
    // `renameAttachment` (notes-8-rename) renames one attachment's original name (payload `newName`),
    // keeping its `NN-` prefix + media extension; the store re-pushes `attachments` since the id changes.
    case removeAttachment, copyAssets, openAttachment, duplicateAttachments, renameAttachment
    // Hamburger settings strip (L5). Swift owns both settings.
    case setRetention, setCheatSheetButton
    // Tab drag rail (L7): the web island posts this once a tab drag begins.
    case tabDragStart
    // Mini view (notes-miniview A3): the JS hover-overlay toggle (and the full-view collapse button) posts this
    // to flip the window's MANUAL mini flag (payload `enabled`). Swift routes it to `setManualMini(_:)`, which
    // A2 owns — JS never sets mini state itself, it only requests the flip and Swift pushes `setMini` back.
    case setManualMini
    // Bullseye set/arm (notes-bullseye BT2): after Swift sets/moves the bullseye at the caret (`setBullseye`),
    // the web island reports the captured/remapped anchor offset back (payload `id` + `anchor`) so Swift can
    // persist it for restart-restore. Also reported after a delivery moves the anchor.
    case bullseyeAnchor
}

/// Outbound: functions native invokes on `window.ViddyNotes` (`call(_:payload:)`).
enum NotesOutbound: String, CaseIterable {
    case receiveState, receiveHistory, restored
    case openSearchResult, insertText, renamed, toast
    // Fingerprint-gated file results. fileSaved advances only the clean baseline; fileReload replaces the live
    // editor after a clean external change or an explicit take-theirs/save-copy choice.
    case fileSaved, fileReload
    // Attachments (L3): `attachments` pushes a note's thumbnails; `dragEnter`/`dragExit`
    // signal the drop highlight.
    case attachments, dragEnter, dragExit
    // Hamburger settings strip (L5).
    case settings
    // Sticky Skills menu (S5): Swift owns the catalog; JS owns the menu chrome. Payload is `items`, each
    // containing ONLY `id` + `displayName` from `StickySkillMenuProjection` - never prompts, routes,
    // output modes or budgets.
    case stickySkills
    // Tab drag rail (L7/L8).
    case dragIndicator, reorderTab
    case insertTab, removeTab
    // External content writes: the loopback control endpoint pushes these so a
    // create / update landed via the endpoint renders in the live island, not just on disk. `externalCreate`
    // materializes a Swift-minted note as the active tab; `externalSetBody` replaces an open note's body by id
    // (set OR the full post-append body). Both echo a persistence message back so the registry (single writer)
    // re-persists membership + rewrites the aggregate.
    case externalCreate, externalSetBody
    // Insert + lifecycle/focus renders: `externalInsert` inserts text at the target
    // note's live caret (the dictation seam); `externalClose` drops a tab after the store soft-closed it;
    // `externalFocus` selects a tab as active. Rename reuses `renamed`, restore reuses `restored`, and
    // duplicate reuses `externalCreate` (+ `attachments`), so those need no new wire name.
    case externalInsert, externalClose, externalFocus
    // Sticky Skill append landing (S2): append a finished skill result at the END of note `id`'s LIVE
    // CodeMirror document as an ordinary transaction, after which JS re-persists the exact result. It is
    // deliberately NOT `externalSetBody`: that replaces the whole document from a body Swift computed off
    // DISK (losing anything typed since the last 180 ms save) and, through `replaceEditorDoc`, mints a fresh
    // EditorState, which resets the note's per-note undo stack. Payload: `id` + `text` (the addition only).
    case externalAppend
    // Mini view (notes-miniview A2): pushes the window's effective-mini boolean (payload `enabled`). Mini hides
    // the tab strip, the button row, and the hamburger (all CSS-driven off `body.mini-mode`), leaving only the
    // active note's editor edge-to-edge. Swift resolves effective-mini (manual toggle OR width < 560) and only
    // pushes on change; JS just reflects the flag.
    case setMini
    // Mini view hover (S8): pushes whether the pointer is inside this window's content view (payload
    // `enabled`), which the island reflects onto `body.mini-hover` — the single latch every mini reveal hangs
    // off. Driven by an `.activeAlways` tracking area rather than the island's own `mousemove`, because AppKit
    // does not route mouse-moved events to a non-key window, so the JS-only latch tracked window FOCUS instead
    // of the pointer. The JS handlers remain as an idempotent fallback; this is the authoritative source.
    case miniHover
    // Note-target snapshot delivery (notes-bullseye BT1): `snapshotTarget` tells the live editor to capture a
    // CodeMirror-mapped anchor at note `id`'s current caret/selection at take-START (the anchor then follows
    // edits); `insertAtTarget` lands a completed take at that snapshotted anchor by note id, reaching the note
    // even when its window is not key. Both are notes-only and reuse the `id` (+ `text`) payload keys.
    case snapshotTarget, insertAtTarget
    // Bullseye set/arm/deliver (notes-bullseye BT2): `setBullseye` pins a persistent CodeMirror-mapped anchor
    // at note `id`'s current caret (the PINNED target, distinct from BT1's transient snapshot — it is NOT
    // cleared after a take and follows edits until moved/dropped); `insertAtBullseye` lands a take at that
    // pinned anchor by note id (focus-independent) WITHOUT clearing it, advancing the anchor past the inserted
    // text so successive takes stack in order.
    case setBullseye, insertAtBullseye
    // Bullseye reveal (notes-bullseye BT6, Option+Shift+N): bring note `id`'s editor live if it is not already
    // and SCROLL its pinned anchor into view. Read-only — it never edits the document, moves the bullseye, or
    // moves the selection; Swift has already fronted the window and selected the tab by the time this arrives.
    case revealBullseye
    // Inline bullseye marker (notes-bullseye BT3): push the armed state (+ last-known anchor) to the island so
    // it can render/hide the inline armed-bullseye marker on Option+B toggle, runtime auto-disarm, a
    // delivery-time drop, and a restart/reload restore. Option+N set/arm rides on `setBullseye` (which arms in
    // JS directly), so it needs no separate push to the key window. Broadcast to all windows so a stale marker
    // in another window clears when the bullseye moves. Payload: `id` + `anchor` + `enabled` (the armed flag).
    case bullseyeArmed
    // Four-color replace highlight (notes-bullseye BT4): push a note `id` + a `level` token (raw / cleanup /
    // tighten / summarize) so the island tints the range a pending level-based operation will REPLACE — the
    // Option+P selection-transform pick (live-updating as the pick moves) and a dictation take overwriting a
    // selection (tinted by the active `?`-cleanup level, or Raw when cleanup is off). An empty `level` clears;
    // a level for the already-highlighted note swaps the color. CodeMirror-only.
    case replaceHighlight
    // Notes cross-focus undo (notes-bullseye BT5): revert the LAST ViddyDictate-delivered dictation edit in note
    // `id`, reaching the note BY ID even when its window is not key (a note is a controlled surface, so the
    // bridge can reach back in). The island restores any text the delivery overwrote and removes the delivered
    // text (its recorded `lastDelivery` range, mapped through later edits). Payload: `id`.
    case undoNoteDelivery, replaceNoteDelivery
}

enum NotesBridgePayloadKey {
    static let type = "type"
    static let id = "id"
    static let body = "body"
    static let title = "title"
    static let kind = "kind"
    static let filePath = "filePath"
    static let canRename = "canRename"
    static let canEdit = "canEdit"
    /// Ephemeral JSON string produced by EditorState.toJSON({history: historyField}) for an open-tab drag.
    /// It crosses only app memory and is never written to a note or windows.json.
    static let editorState = "editorState"
    static let tabOrder = "tabOrder"
    static let activeId = "activeId"
    static let noteId = "noteId"
    static let attachmentId = "attachmentId"
    static let newName = "newName"
    static let fromNoteId = "fromNoteId"
    static let toNoteId = "toNoteId"
    static let grabOffsetX = "grabOffsetX"
    static let grabOffsetY = "grabOffsetY"
    static let text = "text"
    static let anchor = "anchor"
    static let level = "level"
    static let skillId = "skillId"
    /// The monotonic take/gesture id carried on `snapshotTarget` + `replaceHighlight` (BT1/BT4, refine2 BUG 2):
    /// the JS snapshot store guards on it so a same-gesture collapsed re-read never clobbers a live range.
    static let generation = "generation"
    static let x = "x"
    static let toIndex = "toIndex"
    static let makeActive = "makeActive"
    static let notes = "notes"
    static let history = "history"
    static let newId = "newId"
    static let cheatSheetButton = "cheatSheetButton"
    static let retention = "retention"
    static let enabled = "enabled"
    static let message = "message"
    static let items = "items"
    static let preview = "preview"
    static let closedAt = "closedAt"
    static let expiresAt = "expiresAt"
}
