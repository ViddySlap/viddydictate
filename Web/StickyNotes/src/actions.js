import { MSG, post } from "./bridge.js";
import {
  clearReplaceHighlightDeco,
  collapseEditorSelection,
  currentEditorDoc,
  currentSelection,
  editorSlice,
  forgetEditorState,
  focusEditor,
  hasEditor,
  insertIntoEditor,
  selectAllEditor,
  setEditorSelection,
  setReplaceHighlightDeco,
} from "./editor.js";
import {
  clearReplaceHighlight,
  getBullseye,
  getReplaceHighlight,
  getSnapshot,
  mapBullseyeThroughChanges,
  mapLastDeliveryThroughChanges,
  mapReplaceHighlightThroughChanges,
  mapSnapshotThroughChanges,
  recordDelivery,
  setBullseyeAnchor,
  setBullseyeArmed,
  setReplaceHighlight,
  setReplaceHighlightLevel,
} from "./dictation-target.js";
import {
  endTabDragSelectionGuard,
  hideDropIndicator,
  insertionIndexForX,
  setDraggingTabId,
} from "./drag-rail.js";
import { flushActive, saveTabNow, scheduleSave } from "./persistence.js";
import {
  activeAttachments,
  activeTab,
  applyFileSyncAck,
  applySettingsState,
  displayTitle,
  newId,
  receiveHistoryPayload,
  receiveStatePayload,
  resolveFileReload,
  state,
  tabFromWire,
  tabOrder,
} from "./state.js";
import {
  applyCheatSheetButton,
  hideTabMenu,
  render,
  renderSettingsStrip,
  renderTabs,
  showToast,
} from "./render.js";
import {
  activateNoteInPlace,
  insertAtBullseye,
  insertAtTarget,
  replaceEditorForTab,
  replaceNoteDelivery,
  requireEditable,
  revealBullseye,
  setBullseye,
  snapshotTarget,
  syncBullseyeMarker,
  undoNoteDelivery,
} from "./actions-dictation.js";

export {
  activateNoteInPlace,
  insertAtBullseye,
  insertAtTarget,
  replaceEditorForTab,
  replaceNoteDelivery,
  requireEditable,
  revealBullseye,
  setBullseye,
  snapshotTarget,
  syncBullseyeMarker,
  undoNoteDelivery,
};

// Reconcile the four-color replace highlight (notes-bullseye BT4) with the current state: tint the stored
// range at its level ONLY while it belongs to the note shown in the editor (the active tab, not history);
// clear the mark otherwise. Called after every state change that can flip the answer (the highlight push, and
// every editor swap). Between calls the mark self-maps through edits (like the bullseye marker); the store's
// range self-maps too, so a rebuild after a swap re-tints exactly the right range.
export function syncReplaceHighlight() {
  const hi = getReplaceHighlight();
  const visible = !state.showingHistory && !!hi && hi.noteId === state.activeId;
  if (visible) setReplaceHighlightDeco(hi.from, hi.to, "cm-replace-" + hi.level);
  else clearReplaceHighlightDeco();
}

// The single editor-swap reconciler (wired via setEditorSwapHandler): both view-scoped note decorations — the
// inline bullseye marker (BT3) and the replace highlight (BT4) — are meaningless once mapped through a
// full-document swap, so both rebuild from their JS stores after every tab switch / external body load.
export function syncNoteDecorations() {
  syncBullseyeMarker();
  syncReplaceHighlight();
}

// Swift -> JS (replaceHighlight, notes-bullseye BT4): show / live-update / clear the four-color replace
// highlight for note `id`. An empty `level` CLEARS. A level for the note already highlighted just swaps the
// color, keeping the captured range (the Option+P pick moving, or the ?-cleanup level changing mid-take). A
// first push CAPTURES the range to tint from the note's DETERMINISTIC snapshot (taken while the selection was
// live) — but only when `id` is the active, non-history note AND the range is non-empty (a bare caret has
// nothing to REPLACE, so no tint). It then collapses the live selection so the tint shows rather than hiding
// under the selection background. Keyed on the STORED range, not the live selection at push time, so the tint
// survives the Option+P picker stealing focus. CodeMirror-only, scoped to a real replace target.
export function replaceHighlight(payload) {
  const id = payload && payload.id;
  const level = payload && typeof payload.level === "string" ? payload.level : "";
  const generation = payload && Number.isFinite(payload.generation) ? payload.generation : 0;
  if (!id) return;
  if (!level) {
    // BUG 2 fix (restore-selection-on-teardown): tearing the tint down WITHOUT delivering (Option+P picking up a
    // note selection, an Esc-cancel) must bring the ORIGINAL selection back — the first push collapsed it so the
    // color would show, and leaving it collapsed makes the follow-up synthetic Cmd+C copy nothing. Re-select the
    // still-valid snapshot's range BEFORE clearing the tint; a delivery path already cleared its snapshot, so
    // this no-ops there.
    restoreSelectionFromSnapshot(id);
    clearReplaceHighlight();
    syncReplaceHighlight();
    return;
  }
  const existing = getReplaceHighlight();
  if (existing && existing.noteId === id) {
    setReplaceHighlightLevel(level);
  } else {
    if (state.showingHistory || state.activeId !== id) return;
    // Capture the range to tint from the DETERMINISTIC snapshot taken while the selection was live (a
    // dictation take's beginRecording, or the Option+P selection-capture BEFORE the level-picker churn), NOT
    // the live selection at push time: by the time an Option+P push lands, the level picker has taken over and
    // the note selection is stale/collapsed, so a live-selection read bails and no tint shows. A snapshot from an
    // OLDER gesture is a stale leftover (a fresh take never wrote one) — ignore it and fall back to the live
    // selection, matching the reload case. A bare-caret range has nothing to REPLACE, so skip it.
    const snap = getSnapshot(id);
    const snapFresh = snap && (!Number.isFinite(snap.generation) || snap.generation >= generation);
    const range = snap && snapFresh && snap.from !== snap.to ? snap : currentSelection();
    if (!range || range.from === range.to) return;
    setReplaceHighlight(id, range.from, range.to, level);
    // Auto-unhighlight: collapse the live selection so the applied tint SHOWS instead of the blue
    // .cm-selectionBackground sitting over it. Safe because the tint renders from the STORED range (a
    // selection change does not touch it) and delivery/landing route through the snapshot, not the live
    // selection; teardown restores the selection from that same snapshot.
    collapseEditorSelection();
  }
  syncReplaceHighlight();
}

// BUG 2 fix (restore-selection-on-teardown): re-select note `id`'s still-valid snapshot range so a tint teardown
// that did NOT deliver leaves the original selection live (the tint push collapsed it). Only when `id` is the
// active, non-history editor note and the snapshot is a non-empty range — a bare caret has nothing to restore,
// and a delivered take already cleared its snapshot (so this no-ops on the commit/finalize paths).
function restoreSelectionFromSnapshot(id) {
  if (state.showingHistory || state.activeId !== id) return;
  const snap = getSnapshot(id);
  if (!snap || snap.from === snap.to) return;
  setEditorSelection(snap.from, snap.to);
}

// Swift -> JS (bullseyeArmed, notes-bullseye BT3): the armed state (and last-known anchor) changed outside a
// set — Option+B toggle, runtime auto-disarm, delivery-time drop, or a restart/reload restore. Mirror the
// armed flag locally so the inline marker can gate on it, seeding the anchor from Swift's persisted value
// ONLY when this island has no live anchor for the note yet (a reload/restore); otherwise the live,
// follow-edits anchor is fresher and is kept. Then reconcile the marker.
export function bullseyeArmed(payload) {
  const id = payload && payload.id;
  const anchor = payload && typeof payload.anchor === "number" ? payload.anchor : 0;
  const armed = !!(payload && payload.enabled);
  if (armed && id) {
    const cur = getBullseye();
    if (!cur || cur.noteId !== id) setBullseyeAnchor(id, anchor);
    setBullseyeArmed(true);
  } else {
    setBullseyeArmed(false);
  }
  syncBullseyeMarker();
}

export function handleEditorDocChanged(body, changes) {
  const tab = activeTab();
  if (!tab) return;
  tab.body = body;
  if (changes && tab.kind === "fileBacked") {
    // Native keeps this runtime-only buffer so window/app close can flush without waiting for the timer. This
    // message never writes disk; only fileSync crosses the fingerprint gate.
    post(MSG.inbound.fileBufferChanged, { id: tab.id, body });
  }
  // BT1: keep the live note's dictation snapshot anchored through this edit so it follows edits.
  if (changes) mapSnapshotThroughChanges(tab.id, changes);
  // BT2: keep the pinned bullseye anchored through this edit when its note is the live editor, and report
  // the moved anchor back so Swift's persisted offset stays fresh for restart-restore (only when it moved).
  if (changes) {
    const before = getBullseye();
    mapBullseyeThroughChanges(tab.id, changes);
    const after = getBullseye();
    if (before && after && after.noteId === tab.id && after.anchor !== before.anchor) {
      post(MSG.inbound.bullseyeAnchor, { id: tab.id, anchor: after.anchor });
    }
  }
  // BT4: keep the replace-highlight range anchored through this edit so the tint follows edits.
  if (changes) mapReplaceHighlightThroughChanges(tab.id, changes);
  // BT5: keep the last-delivery undo range anchored through this edit so typing above it does not misplace the
  // notes cross-focus undo.
  if (changes) mapLastDeliveryThroughChanges(tab.id, changes);
  scheduleSave(tab);
  renderTabs();
}

export function selectTab(id) {
  flushActive();
  state.showingHistory = false;
  state.activeId = id;
  const tab = activeTab();
  replaceEditorForTab(tab);
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  render();
}

export function createTab(body = "") {
  flushActive();
  const tab = { id: newId(), body };
  state.tabs.push(tab);
  state.activeId = tab.id;
  state.showingHistory = false;
  replaceEditorForTab(tab, body);
  if (body.trim()) {
    post(MSG.inbound.save, { id: tab.id, body, tabOrder: tabOrder(), activeId: state.activeId });
  } else {
    post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  }
  render();
  focusEditor();
}

export function closeTab(id) {
  const idx = state.tabs.findIndex((tab) => tab.id === id);
  if (idx < 0) return;
  const closing = state.tabs[idx];
  if (closing.id === state.activeId) {
    closing.body = currentEditorDoc();
  }
  if (closing.kind === "fileBacked") {
    // Native must gate the close write before the tab disappears. It calls externalClose only after a safe
    // write/reload or after the user resolves a conflict; on failure/conflict the live tab stays recoverable.
    post(MSG.inbound.fileBufferChanged, { id: closing.id, body: closing.body });
    post(MSG.inbound.close, {
      id: closing.id,
      body: closing.body,
      tabOrder: tabOrder(),
      activeId: state.activeId,
    });
    return;
  }
  forgetEditorState(closing.id);
  state.tabs.splice(idx, 1);
  post(MSG.inbound.close, { id: closing.id, body: closing.body, tabOrder: tabOrder(), activeId: state.activeId });
  if (state.activeId === id) {
    state.activeId = state.tabs[Math.min(idx, state.tabs.length - 1)]?.id || null;
    replaceEditorForTab(activeTab());
  }
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  render();
}

export function saveAs(id) {
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (tab.id === state.activeId) tab.body = currentEditorDoc();
  if (!tab.body.trim()) {
    showToast("Nothing to save");
    return;
  }
  post(MSG.inbound.saveAs, { id: tab.id, body: tab.body });
}

export function openInFinder(id) {
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (tab.id === state.activeId) tab.body = currentEditorDoc();
  const hasAttachments = (state.attachmentsByNote[tab.id] || []).length > 0;
  if (tab.kind === "fileBacked") {
    if (!tab.filePath) return;
  } else {
    // An empty, attachment-free scratch tab has not materialized a backing file yet. For an attachment-only
    // note, save first so the store creates its legitimate empty note-<id>.md before Finder is asked to reveal it.
    if (!tab.body.trim() && !hasAttachments) return;
    post(MSG.inbound.save, {
      id: tab.id,
      body: tab.body,
      tabOrder: tabOrder(),
      activeId: state.activeId,
    });
  }
  post(MSG.inbound.revealInFinder, { id: tab.id });
}

// Whole-note companion to the existing right-Option+. selection mode. Snapshot the selected tab's current
// body + displayed title; Swift reads the authoritative attachment filenames and owns model routing/output.
export function noteToHandoff(id, skillId = null) {
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (tab.id === state.activeId) tab.body = currentEditorDoc();
  const hasAttachments = (state.attachmentsByNote[tab.id] || []).length > 0;
  if (!tab.body.trim() && !hasAttachments) {
    showToast("Nothing to hand off");
    return;
  }
  const payload = {
    id: tab.id,
    title: displayTitle(tab, tab.body),
    body: tab.body,
  };
  if (typeof skillId === "string" && skillId) payload.skillId = skillId;
  post(MSG.inbound.noteToHandoff, payload);
}

export function copyTab(id) {
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (tab.id === state.activeId) tab.body = currentEditorDoc();
  if (!tab.body.trim()) {
    showToast("Nothing to copy");
    return;
  }
  post(MSG.inbound.copy, { body: tab.body });
}

export function beginInlineRename(id) {
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || tab.canRename === false) return;
  hideTabMenu();
  state.editingTabId = id;
  renderTabs();
}

export function commitInlineRename(id, rawTitle) {
  state.editingTabId = null;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) { render(); return; }
  if (tab.id === state.activeId) tab.body = currentEditorDoc();
  const title = rawTitle.trim();
  tab.title = title;
  post(MSG.inbound.rename, {
    id: tab.id,
    title,
    body: tab.body,
    tabOrder: tabOrder(),
    activeId: state.activeId,
  });
  render();
}

export function cancelInlineRename() {
  state.editingTabId = null;
  render();
}

// Select all: switch to the tab if needed, then select the note's full text and focus the editor so a
// selection-transform chord can act on it immediately. Pure CodeMirror; no bridge message.
export function selectAllInTab(id) {
  if (id !== state.activeId) selectTab(id);
  selectAllEditor();
}

// Duplicate note: create a new tab immediately right of the source with the same body and a
// "<source title> copy" rename override, made active. Reuses the new-tab (MSG.inbound.save) + rename bridge
// flow; a fresh id is minted the normal way. If the source has attachments, MSG.inbound.duplicateAttachments
// tells Swift to copy the whole sidecar set onto the duplicate (L3 store.copyAttachments), which then
// re-pushes the `attachments` message for the new note so its tray populates.
export function duplicateTab(id) {
  const idx = state.tabs.findIndex((tab) => tab.id === id);
  if (idx < 0) return;
  const source = state.tabs[idx];
  const body = source.id === state.activeId ? currentEditorDoc() : source.body || "";
  const copyTitle = `${displayTitle(source, body)} copy`;
  const hasAttachments = (state.attachmentsByNote[source.id] || []).length > 0;
  flushActive();
  const hasBody = body.trim().length > 0;
  const dup = { id: newId(), body, title: hasBody ? copyTitle : "" };
  state.tabs.splice(idx + 1, 0, dup);
  state.activeId = dup.id;
  state.showingHistory = false;
  replaceEditorForTab(dup, body);
  if (hasBody) {
    post(MSG.inbound.save, { id: dup.id, body, tabOrder: tabOrder(), activeId: state.activeId });
    post(MSG.inbound.rename, { id: dup.id, title: copyTitle, body, tabOrder: tabOrder(), activeId: state.activeId });
  } else {
    post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  }
  if (hasAttachments) {
    post(MSG.inbound.duplicateAttachments, { fromNoteId: source.id, toNoteId: dup.id });
  }
  render();
  focusEditor();
}

// Swift -> JS (reorderTab): end the drag on the source window. toIndex >= 0 moves the tab and persists the
// new order; toIndex < 0 cancels/snaps back. Either way the lifted style clears.
export function applyReorder(payload) {
  const noteId = payload && payload.noteId;
  const toIndex = payload ? payload.toIndex : -1;
  endTabDragSelectionGuard();
  setDraggingTabId(null);
  hideDropIndicator();
  if (!noteId || typeof toIndex !== "number" || toIndex < 0) { renderTabs(); return; }
  const srcIdx = state.tabs.findIndex((tab) => tab.id === noteId);
  if (srcIdx < 0) { renderTabs(); return; }
  const [moved] = state.tabs.splice(srcIdx, 1);
  // toIndex is an insertion index over the tabs array WITH the source still present; adjust for its removal.
  let insertAt = toIndex > srcIdx ? toIndex - 1 : toIndex;
  insertAt = Math.max(0, Math.min(insertAt, state.tabs.length));
  state.tabs.splice(insertAt, 0, moved);
  renderTabs();
  // Persist the new order (reorder does not change the active tab or any body; MSG.inbound.active carries tabOrder).
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
}

// Swift -> JS (insertTab, L8): dock a note dragged in from another window. The insertion index
// is computed from the strip-local x against THIS window's live tab geometry (same formula as the indicator
// the user saw). The note becomes the active tab; MSG.inbound.active persists the new membership. If the note is
// somehow already present, it is repositioned rather than duplicated.
export function insertTab(payload) {
  if (!payload || !payload.id) return;
  endTabDragSelectionGuard();
  flushActive();
  const tab = tabFromWire(payload);
  let index = (typeof payload.x === "number" && isFinite(payload.x))
    ? insertionIndexForX(payload.x)
    : state.tabs.length;
  const existing = state.tabs.findIndex((t) => t.id === tab.id);
  if (existing >= 0) {
    state.tabs.splice(existing, 1);
    if (existing < index) index -= 1;
  }
  index = Math.max(0, Math.min(index, state.tabs.length));
  state.tabs.splice(index, 0, tab);
  state.showingHistory = false;
  const makeActive = payload.makeActive !== false;
  if (makeActive) {
    state.activeId = tab.id;
    replaceEditorForTab(tab);
  }
  render();
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  if (makeActive) focusEditor();
}

// Swift -> JS (removeTab, L8): the note moved to another window. Detach its tab WITHOUT closing
// it to history (the note lives on in the target window / new window). Reselect a neighbor if it was active,
// clear any lifted style, and post the new tabOrder so the registry re-persists (and prunes this window if it
// was an emptied secondary).
export function removeTab(payload) {
  const noteId = payload && payload.noteId;
  endTabDragSelectionGuard();
  setDraggingTabId(null);
  hideDropIndicator();
  const idx = state.tabs.findIndex((tab) => tab.id === noteId);
  if (idx < 0) { renderTabs(); return; }
  // A cross-window move is not a close, but this island no longer owns the state after Swift has handed its
  // serialized copy to the destination. Drop the source copy without turning the move into D3's close boundary.
  forgetEditorState(noteId);
  state.tabs.splice(idx, 1);
  if (state.activeId === noteId) {
    state.activeId = state.tabs[Math.min(idx, state.tabs.length - 1)]?.id || null;
    replaceEditorForTab(activeTab());
  }
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  render();
}

// Swift -> JS: the current Settings-owned values (cheat-sheet button on/off + retention). Pushed on
// page-ready (carried in receiveState too) and on every Settings.didChange, so the strip and the native
// Settings -> Notes tab never disagree.
export function applySettings(payload) {
  if (!payload) return;
  applySettingsState(payload);
  applyCheatSheetButton();
  renderSettingsStrip();
}

// Back: leave the history view and return to the note that was active when the hamburger was opened
// (or the first tab if that note was closed meanwhile), else the blank home screen when no notes remain.
export function goBack() {
  if (state.tabs.length === 0) {
    state.showingHistory = false;
    render();
    return;
  }
  const target = (state.preHamburgerActiveId && state.tabs.some((tab) => tab.id === state.preHamburgerActiveId))
    ? state.preHamburgerActiveId
    : state.tabs[0].id;
  selectTab(target);
}

export function showHistory() {
  flushActive();
  // Remember the note active before opening the hamburger so Back can return to it (L5).
  state.preHamburgerActiveId = state.activeId;
  state.showingHistory = true;
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  render();
}

function insertionText(payload) {
  return payload && typeof payload.text === "string" ? payload.text : "";
}

export function insertText(payload) {
  const insert = insertionText(payload);
  if (!insert) return;
  if (state.showingHistory) state.showingHistory = false;
  if (!activeTab()) createTab("");
  const tab = activeTab();
  if (!tab || !requireEditable(tab)) return;
  // BT5: capture what this take is about to overwrite (the live selection) so Option+Z can restore it later.
  const sel = currentSelection();
  const replaced = sel ? editorSlice(sel.from, sel.to) : "";
  const beforeLength = currentEditorDoc().length;
  const body = insertIntoEditor(insert);
  if (body === null) return;
  if (sel) {
    const insertedLength = body.length - beforeLength + replaced.length;
    recordDelivery(tab.id, sel.from, insertedLength, replaced);
  }
  tab.body = body;
  saveTabNow(tab);
  focusEditor();
  render();
}

export function openSearchResult(payload) {
  createTab(payload.body || "");
}

export function receiveState(payload) {
  receiveStatePayload(payload);
  applyCheatSheetButton();
  replaceEditorForTab(activeTab());
  render();
}

export function receiveHistory(payload) {
  receiveHistoryPayload(payload);
  render();
}

// Swift -> JS acknowledgement for an atomic write. Advance only the clean baseline that was written; if a
// newer edit already changed tab.body, the tab remains dirty against this older confirmed body.
export function fileSaved(payload) {
  const id = payload && payload.id;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || tab.kind !== "fileBacked") return;
  applyFileSyncAck(tab, payload.body);
}

// Swift -> JS clean live-reload / deliberate conflict resolution. A timer reload is conditional on the editor
// still matching the body that requested the sync; a racing keystroke rejects it and immediately re-syncs
// against the OLD native base, which correctly raises a conflict. Deliberate choices pass force=true.
export function fileReload(payload) {
  const id = payload && payload.id;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || tab.kind !== "fileBacked" || typeof payload.body !== "string") return;
  const liveBody = tab.id === state.activeId && hasEditor() ? currentEditorDoc() : tab.body;
  if (!resolveFileReload(tab, payload, liveBody)) {
    post(MSG.inbound.fileBufferChanged, { id: tab.id, body: liveBody });
    post(MSG.inbound.fileSync, { id: tab.id, body: liveBody, reason: "reloadRace" });
    return;
  }
  forgetEditorState(tab.id);
  if (state.activeId === tab.id) replaceEditorForTab(tab, payload.body, { resetHistory: true });
  render();
  post(MSG.inbound.fileReloadApplied, { id: tab.id, body: payload.body });
  if (payload.message) showToast(payload.message);
}

export function restored(note) {
  const tab = tabFromWire(note);
  state.tabs.push(tab);
  state.activeId = note.id;
  state.showingHistory = false;
  replaceEditorForTab(tab);
  render();
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
}

export function renamed(payload) {
  const tab = state.tabs.find((candidate) => candidate.id === payload.id);
  if (!tab) return;
  const incoming = tabFromWire({ ...tab, ...payload });
  // A Stage 0 file-backed rename may happen while its editor buffer is dirty. Rename updates origin/title
  // metadata only; replacing tab.body with the store's still-on-disk body would discard that live buffer.
  Object.assign(tab, {
    title: incoming.title,
    kind: incoming.kind,
    filePath: incoming.filePath,
    canRename: incoming.canRename,
    canEdit: incoming.canEdit,
  });
  render();
}

export function copyActiveTab() {
  const tab = activeTab();
  if (!tab) return;
  tab.body = currentEditorDoc();
  post(MSG.inbound.copy, { body: tab.body });
}

export function copyActiveAssets() {
  if (!state.activeId || !activeAttachments().length) return;
  post(MSG.inbound.copyAssets, { noteId: state.activeId });
}

export function updateCheatSheetButton(enabled) {
  state.cheatSheetButton = enabled;
  applyCheatSheetButton();
  post(MSG.inbound.setCheatSheetButton, { enabled: state.cheatSheetButton });
}

export function updateRetention(retention) {
  state.retention = retention;
  post(MSG.inbound.setRetention, { retention: state.retention });
}

// Mini view (notes-miniview A3): request a flip of THIS window's MANUAL mini flag. JS does not own mini state —
// it posts setManualMini to Swift, which flips the flag, persists it, recomputes effective mini (manual OR
// content width < 560), and pushes setMini back onto body.mini-mode. The full-view collapse button sends true;
// the overlay toggle sends false (which returns to full only if the window is also wide enough — a narrow window
// stays size-mini, per A2). Copy/cheat-sheet in the overlay reuse copyActiveTab/copyActiveAssets and the shared
// cheat-sheet element, so they need no new action here.
export function setManualMini(enabled) {
  post(MSG.inbound.setManualMini, { enabled: !!enabled });
}
