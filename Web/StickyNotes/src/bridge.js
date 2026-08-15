// Bridge message names. This is the single source on the JS side, matched by NotesInbound/NotesOutbound.
// Adding a message means one entry here plus one enum case in Sources/NotesBridgeMessages.swift.
export const MSG = Object.freeze({
  inbound: Object.freeze({
    ready: "ready",
    save: "save",
    active: "active",
    close: "close",
    fileBufferChanged: "fileBufferChanged",
    fileSync: "fileSync",
    fileReloadApplied: "fileReloadApplied",
    restore: "restore",
    deleteHistory: "deleteHistory",
    copy: "copy",
    rename: "rename",
    saveAs: "saveAs",
    revealInFinder: "revealInFinder",
    // Whole-note companion to the existing selection-only custom mode. Swift snapshots the attachment
    // filenames from the store, runs that mode's CURRENT route, and creates a separate result note.
    noteToHandoff: "noteToHandoff",
    // Attachments (L3/L4). The L4 tray posts removeAttachment/copyAssets/openAttachment;
    // duplicateAttachments (L4) tells Swift to copy the source note's attachments onto the duplicate.
    removeAttachment: "removeAttachment",
    copyAssets: "copyAssets",
    openAttachment: "openAttachment",
    duplicateAttachments: "duplicateAttachments",
    // notes-8-rename: right-click an attachment thumb -> inline rename; Swift keeps the NN- prefix + media
    // extension and re-pushes attachments (the id/filename changes). Payload: noteId, attachmentId, newName.
    renameAttachment: "renameAttachment",
    // Hamburger settings strip (L5): Swift owns both settings.
    setRetention: "setRetention",
    setCheatSheetButton: "setCheatSheetButton",
    // Tab drag rail (L7): posted once a tab drag crosses the movement threshold; Swift then
    // runs the whole pointer drag and drives dragIndicator / reorderTab back.
    tabDragStart: "tabDragStart",
    // Mini view (notes-miniview A3): the hover-overlay toggle (and the full-view collapse button) posts this to
    // flip the window's MANUAL mini flag (payload `enabled`). Swift owns effective mini and pushes setMini back;
    // JS never toggles body.mini-mode itself off this.
    setManualMini: "setManualMini",
    // Bullseye set/arm (notes-bullseye BT2): after Swift pins the bullseye at the caret (setBullseye), the island
    // reports the captured/remapped anchor offset back (payload id + anchor) so Swift persists it for restore.
    bullseyeAnchor: "bullseyeAnchor",
  }),
  outbound: Object.freeze({
    receiveState: "receiveState",
    receiveHistory: "receiveHistory",
    restored: "restored",
    openSearchResult: "openSearchResult",
    insertText: "insertText",
    renamed: "renamed",
    toast: "toast",
    fileSaved: "fileSaved",
    fileReload: "fileReload",
    // Attachments (L3): attachments pushes a note's thumbnails; dragEnter/dragExit signal
    // the drop highlight.
    attachments: "attachments",
    dragEnter: "dragEnter",
    dragExit: "dragExit",
    // Hamburger settings strip (L5).
    settings: "settings",
    // Sticky Skills menu (S5): Swift pushes only [{id, displayName}]; JS renders the menu chrome.
    stickySkills: "stickySkills",
    // Tab drag rail (L7/L8).
    dragIndicator: "dragIndicator",
    reorderTab: "reorderTab",
    insertTab: "insertTab",
    removeTab: "removeTab",
    // External content writes: the loopback control endpoint drives these so a
    // create / update that arrived over HTTP renders live. `externalCreate` adds a Swift-minted note as the
    // active tab; `externalSetBody` replaces an open note's body by id (set OR the full post-append body).
    externalCreate: "externalCreate",
    externalSetBody: "externalSetBody",
    // Insert + lifecycle/focus renders: `externalInsert` inserts text at the target
    // note's live caret (the dictation seam); `externalClose` drops a tab the store already soft-closed;
    // `externalFocus` selects a tab as active. Rename/restore/duplicate reuse `renamed`/`restored`/
    // `externalCreate`, so they add no new wire name.
    externalInsert: "externalInsert",
    externalClose: "externalClose",
    externalFocus: "externalFocus",
    // Sticky Skill append landing (S2): append a finished skill result at the END of note `id`'s LIVE
    // document as a real CodeMirror transaction, then re-persist here. Distinct from externalSetBody on
    // purpose - that one replaces the whole document from a Swift-computed body, which both loses anything
    // typed since the last save and resets the note's per-note undo stack.
    externalAppend: "externalAppend",
    // Mini view (notes-miniview A2): Swift pushes the window's effective-mini boolean (payload `enabled`). Mini
    // hides the tab strip, the button row, and the hamburger via body.mini-mode, leaving only the active note's
    // editor edge-to-edge. Swift owns the decision (manual toggle OR width < 560); JS only reflects it.
    setMini: "setMini",
    // Mini view hover (S8): Swift pushes whether the pointer is inside the window's content view (payload
    // enabled) and the island reflects it onto body.mini-hover, the single latch every mini reveal hangs off.
    // An .activeAlways tracking area drives it, so the reveal no longer requires the window to be key — AppKit
    // never routed mouse-moved events to a non-key window, so the JS-only latch tracked focus, not the pointer.
    // The mousemove/mouseleave handlers stay as an idempotent fallback; this push is authoritative.
    miniHover: "miniHover",
    // Note-target snapshot delivery (notes-bullseye BT1): `snapshotTarget` captures a CodeMirror-mapped anchor
    // at note `id`'s caret/selection at take-START (the anchor then follows edits); `insertAtTarget` lands a
    // completed take at that anchor by note id, reaching the note even when its window is not key.
    snapshotTarget: "snapshotTarget",
    insertAtTarget: "insertAtTarget",
    // Bullseye set/arm/deliver (notes-bullseye BT2): `setBullseye` pins a persistent CodeMirror-mapped anchor at
    // note `id`'s caret (distinct from BT1's transient snapshot — not cleared after a take, follows edits until
    // moved/dropped); `insertAtBullseye` lands a take at that pinned anchor by note id WITHOUT clearing it,
    // advancing the anchor past the inserted text so successive takes stack in order.
    setBullseye: "setBullseye",
    insertAtBullseye: "insertAtBullseye",
    // Bullseye reveal (notes-bullseye BT6, Option+Shift+N): scroll note `id`'s pinned anchor into view, bringing
    // its editor live first if the island is showing something else. Read-only — never edits the document,
    // moves the bullseye, or moves the selection; Swift has already fronted the window and selected the tab.
    revealBullseye: "revealBullseye",
    // Inline bullseye marker (notes-bullseye BT3): Swift pushes the armed state (+ last-known anchor) so the
    // island can show/hide the inline marker on Option+B toggle, auto-disarm, delivery-time drop, and a
    // restart/reload restore (Option+N set/arm rides on setBullseye, which arms directly).
    bullseyeArmed: "bullseyeArmed",
    // Four-color replace highlight (notes-bullseye BT4): Swift pushes the note id + level so the island tints
    // the range a pending level-based operation will REPLACE (four colors keyed to Raw / Cleanup / Tighten /
    // Summarize). An empty level clears; a level for the already-highlighted note swaps the color live. Covers
    // both replace-flows (the Option+P selection-transform pick and a dictation take overwriting a selection).
    replaceHighlight: "replaceHighlight",
    // Notes cross-focus undo (notes-bullseye BT5): revert the LAST ViddyDictate dictation edit in note `id`,
    // reaching the note BY ID even when its window is not key. The island restores any text the delivery
    // overwrote and removes the delivered text (its recorded `lastDelivery` range, mapped through later edits).
    undoNoteDelivery: "undoNoteDelivery",
    // Explicit provider retry replaces that same mapped delivery range with the confirmed retry output while
    // preserving the original overwritten text as the next Option+Z undo source.
    replaceNoteDelivery: "replaceNoteDelivery",
  }),
});

const SCRIPT_HANDLER = "notes";

export function post(type, payload = {}) {
  const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[SCRIPT_HANDLER];
  if (!bridge) return;
  bridge.postMessage({ type, ...payload });
}
