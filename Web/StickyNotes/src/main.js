import { MSG, post } from "./bridge.js";
import {
  applyReorder,
  applySettings,
  beginInlineRename,
  bullseyeArmed,
  cancelInlineRename,
  closeTab,
  commitInlineRename,
  copyTab,
  duplicateTab,
  fileReload,
  fileSaved,
  handleEditorDocChanged,
  insertAtBullseye,
  insertAtTarget,
  insertTab,
  insertText,
  noteToHandoff,
  setBullseye,
  snapshotTarget,
  undoNoteDelivery,
  openSearchResult,
  openInFinder,
  receiveHistory,
  receiveState,
  removeTab,
  renamed,
  replaceHighlight,
  replaceNoteDelivery,
  restored,
  revealBullseye,
  saveAs,
  selectAllInTab,
  selectTab,
  syncNoteDecorations,
} from "./actions.js";
import {
  beginAttachmentRename,
  cancelAttachmentRename,
  commitAttachmentRename,
  receiveAttachments,
} from "./actions-attachments.js";
import {
  externalAppend,
  externalClose,
  externalCreate,
  externalFocus,
  externalInsert,
  externalSetBody,
} from "./external-control.js";
import { showDropIndicator } from "./drag-rail.js";
import { makeEditor, setEditorChangeHandler, setEditorSwapHandler } from "./editor.js";
import { installEventHandlers } from "./events.js";
import { startFileAutosave } from "./persistence.js";
import {
  applyMini,
  receiveStickySkills,
  setDropActive,
  setMiniHover,
  setRenderActionHandlers,
  showToast,
} from "./render.js";

setRenderActionHandlers({
  beginAttachmentRename,
  beginInlineRename,
  cancelAttachmentRename,
  cancelInlineRename,
  closeTab,
  commitAttachmentRename,
  commitInlineRename,
  copyTab,
  duplicateTab,
  noteToHandoff,
  openInFinder,
  saveAs,
  selectAllInTab,
  selectTab,
});
setEditorChangeHandler(handleEditorDocChanged);
// Rebuild the view-scoped note decorations after every editor swap (tab switch / external body load): the
// inline bullseye marker (BT3) and the four-color replace highlight (BT4).
setEditorSwapHandler(syncNoteDecorations);
installEventHandlers();

// Outbound bridge surface (Swift -> JS): the functions native invokes via call(). These key names are
// the JS half of the contract; they must match NotesOutbound in Sources/NotesBridgeMessages.swift.
window.ViddyNotes = {
  [MSG.outbound.receiveState]: receiveState,
  [MSG.outbound.receiveHistory]: receiveHistory,
  [MSG.outbound.restored]: restored,
  [MSG.outbound.openSearchResult]: openSearchResult,
  [MSG.outbound.insertText]: insertText,
  [MSG.outbound.renamed]: renamed,
  [MSG.outbound.toast]: (payload) => showToast(payload.message || ""),
  [MSG.outbound.fileSaved]: (payload) => fileSaved(payload),
  [MSG.outbound.fileReload]: (payload) => fileReload(payload),
  // Attachments (L4): `attachments` refreshes a note's tray; `dragEnter`/`dragExit` toggle
  // the drop-highlight overlay on the note surface.
  [MSG.outbound.attachments]: (payload) => receiveAttachments(payload),
  [MSG.outbound.dragEnter]: () => setDropActive(true),
  [MSG.outbound.dragExit]: () => setDropActive(false),
  // Hamburger settings strip (L5): apply Swift's pushed cheat-sheet + retention values.
  [MSG.outbound.settings]: (payload) => applySettings(payload),
  // Sticky Skills menu (S5): the native store projects only id + displayName; the island owns all chrome.
  [MSG.outbound.stickySkills]: (payload) => receiveStickySkills(payload),
  // Tab drag rail (L7): `dragIndicator` draws/clears the insertion bar; `reorderTab` ends the
  // drag on the source window (commit reorder or snap back).
  [MSG.outbound.dragIndicator]: (payload) => showDropIndicator(payload && typeof payload.x === "number" ? payload.x : null),
  [MSG.outbound.reorderTab]: (payload) => applyReorder(payload),
  // Cross-window tab moves (L8): `insertTab` docks a note into this window (dock target or a
  // fresh drag-out window); `removeTab` detaches a note that moved out (no history close).
  [MSG.outbound.insertTab]: (payload) => insertTab(payload),
  [MSG.outbound.removeTab]: (payload) => removeTab(payload),
  // External content writes: `externalCreate` renders a note created via the loopback
  // control endpoint; `externalSetBody` replaces an open note's body (set / post-append) from the endpoint.
  [MSG.outbound.externalCreate]: (payload) => externalCreate(payload),
  [MSG.outbound.externalSetBody]: (payload) => externalSetBody(payload),
  // Insert + lifecycle/focus renders: `externalInsert` inserts at the target note's live
  // caret; `externalClose` drops a tab the store already soft-closed; `externalFocus` selects a tab as active.
  [MSG.outbound.externalInsert]: (payload) => externalInsert(payload),
  [MSG.outbound.externalClose]: (payload) => externalClose(payload),
  [MSG.outbound.externalFocus]: (payload) => externalFocus(payload),
  // Sticky Skill append landing (S2): append a skill result at the END of the note's LIVE document as a
  // CodeMirror transaction and re-persist here, so nothing typed since the last save is lost and the note's
  // per-note undo stack survives.
  [MSG.outbound.externalAppend]: (payload) => externalAppend(payload),
  // Mini view (notes-miniview A2): reflect the window's effective-mini flag onto body.mini-mode.
  [MSG.outbound.setMini]: (payload) => applyMini(payload && payload.enabled),
  // Mini view hover (S8): Swift's .activeAlways tracking area owns the hover latch, so the reveal works while
  // the window is not key and while another app is frontmost. Same setter the mousemove fallback calls.
  [MSG.outbound.miniHover]: (payload) => setMiniHover(payload && payload.enabled),
  // Note-target snapshot delivery (notes-bullseye BT1): `snapshotTarget` captures the mapped anchor at
  // take-START; `insertAtTarget` lands the completed take at that anchor by note id (focus-independent).
  [MSG.outbound.snapshotTarget]: (payload) => snapshotTarget(payload),
  [MSG.outbound.insertAtTarget]: (payload) => insertAtTarget(payload),
  // Bullseye set/arm/deliver (notes-bullseye BT2): `setBullseye` pins the persistent anchor at the caret;
  // `insertAtBullseye` lands an armed take at that pinned anchor by note id (focus-independent).
  [MSG.outbound.setBullseye]: (payload) => setBullseye(payload),
  [MSG.outbound.insertAtBullseye]: (payload) => insertAtBullseye(payload),
  // Bullseye reveal (notes-bullseye BT6): scroll the pinned anchor into view after Swift has fronted the
  // window, selected the tab, and armed the bullseye. Read-only in the editor.
  [MSG.outbound.revealBullseye]: (payload) => revealBullseye(payload),
  // Inline bullseye marker (notes-bullseye BT3): reflect Swift's armed-state push (Option+B toggle, auto-disarm,
  // delivery-time drop, restart/reload restore) so the inline marker shows/hides.
  [MSG.outbound.bullseyeArmed]: (payload) => bullseyeArmed(payload),
  // Four-color replace highlight (notes-bullseye BT4): tint / live-update / clear the range a pending
  // level-based operation will replace (the Option+P pick and a dictation take overwriting a selection).
  [MSG.outbound.replaceHighlight]: (payload) => replaceHighlight(payload),
  // Notes cross-focus undo (notes-bullseye BT5): revert the last ViddyDictate dictation edit in note `id`,
  // restoring any overwritten text, reaching the note by id even when its window is not key.
  [MSG.outbound.undoNoteDelivery]: (payload) => undoNoteDelivery(payload),
  [MSG.outbound.replaceNoteDelivery]: (payload) => replaceNoteDelivery(payload),
};

makeEditor("");
startFileAutosave();
post(MSG.inbound.ready);
