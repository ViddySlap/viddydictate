import { MSG, post } from "./bridge.js";
import {
  currentEditorDoc,
  currentSelection,
  editorSlice,
  focusEditor,
  insertAtRange,
  insertIntoEditor,
  pulseBullseyeMarker,
  replaceEditorDoc,
  scrollPositionIntoView,
  setBullseyeMarker,
  setEditorEditable,
} from "./editor.js";
import {
  clearLastDelivery,
  clearSnapshot,
  getBullseye,
  getLastDelivery,
  getSnapshot,
  isBullseyeArmed,
  recordDelivery,
  setBullseyeAnchor,
  setBullseyeArmed,
  setSnapshot,
} from "./dictation-target.js";
import { flushActive, saveTabNow } from "./persistence.js";
import { state, tabOrder } from "./state.js";
import { render, showToast } from "./render.js";

// Reconcile the inline bullseye marker (notes-bullseye BT3) with the current state: show the glyph at the
// pinned anchor ONLY while the bullseye is armed AND its note is the one shown in the editor (the active tab,
// not the history view); hide it otherwise. Called after every state change that can flip the answer - the
// bullseye set/deliver, an armed-state push from Swift, and every editor swap (via setEditorSwapHandler).
// The transient snapshot never reaches here, so it never gets a marker. Between these calls the marker
// self-maps through edits inside the editor, matching how the JS bullseye anchor follows edits.
export function syncBullseyeMarker() {
  const bull = getBullseye();
  const visible = !state.showingHistory && isBullseyeArmed() && !!bull && bull.noteId === state.activeId;
  setBullseyeMarker(visible ? bull.anchor : null);
}

export function replaceEditorForTab(tab, body = null, { resetHistory = false } = {}) {
  const serializedState = tab?.editorState || null;
  if (tab) tab.editorState = null;
  replaceEditorDoc(tab?.id || null, body == null ? (tab?.body || "") : body,
    { serializedState, resetHistory });
  setEditorEditable(tab?.canEdit !== false);
}

export function requireEditable(tab) {
  if (tab?.canEdit !== false) return true;
  showToast("This file is read-only");
  return false;
}

export function activateNoteInPlace(id, tab) {
  flushActive();
  state.activeId = id;
  replaceEditorForTab(tab);
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
}

// Swift -> JS (snapshotTarget, notes-bullseye BT1): capture the dictation target for note `id` at take-START.
// When `id` is the active, non-history editor note, snapshot the live selection (a bare caret = insert point,
// a non-empty selection = range to replace); the anchor then follows edits until delivery. When the note is
// not the live editor (history shown / another tab), snapshot an end-of-body floor so delivery still lands in
// the note. No editor mutation - snapshotting is read-only.
export function snapshotTarget(payload) {
  const id = payload && payload.id;
  if (!id) return;
  // The monotonic take/gesture id Swift stamps at take-START; the store's guard uses it so a same-gesture
  // collapsed re-read (from the replace-highlight tint) can never clobber this live range, while a genuinely
  // newer gesture always wins. Absent (older Swift / a non-take caller) => generation 0.
  const generation = payload && Number.isFinite(payload.generation) ? payload.generation : 0;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (!state.showingHistory && state.activeId === id) {
    const sel = currentSelection();
    if (sel) {
      setSnapshot(id, sel.from, sel.to, generation);
      return;
    }
  }
  const end = (tab.body || "").length;
  setSnapshot(id, end, end, generation);
}

// Swift -> JS (insertAtTarget, notes-bullseye BT1): land a completed dictation take at note `id`'s snapshotted
// anchor, reaching the note even when it is not the active tab / the window is not key. Brings the target's
// editor live if needed (its stored body is unchanged, so the mapped offsets are valid), then REPLACES the
// snapshotted range (a selection) or INSERTS at the caret, re-persists via the save round-trip, and clears the
// snapshot (transient). With no snapshot (page reloaded / never captured) it falls back to a live-caret insert
// so text is never lost.
export function insertAtTarget(payload) {
  const id = payload && payload.id;
  const text = payload && typeof payload.text === "string" ? payload.text : "";
  if (!id || !text) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || !requireEditable(tab)) return;
  if (state.showingHistory) state.showingHistory = false;
  if (state.activeId !== id) {
    // Bring the target's editor live so the anchor lands in it (focus/select first). Its body is unchanged, so
    // the snapshot offsets still address it correctly.
    activateNoteInPlace(id, tab);
  }
  const snap = getSnapshot(id);
  // BT5: capture the overwritten text + insertion point BEFORE the edit so Option+Z can restore it. A snapshot
  // range overwrites [from, to]; a live-caret fallback inserts at the caret (nothing overwritten).
  const at = snap ? { from: snap.from, to: snap.to } : (currentSelection() || { from: 0, to: 0 });
  const replaced = editorSlice(at.from, at.to);
  const beforeLength = currentEditorDoc().length;
  const body = snap ? insertAtRange(snap.from, snap.to, text) : insertIntoEditor(text);
  clearSnapshot(id);
  if (body === null) return;
  const insertedLength = body.length - beforeLength + replaced.length;
  recordDelivery(id, at.from, insertedLength, replaced);
  tab.body = body;
  saveTabNow(tab);
  focusEditor();
  render();
}

// Swift -> JS (setBullseye, notes-bullseye BT2): pin the PERSISTENT bullseye at note `id`'s current caret
// (Option+N with the caret in a note). Unlike the transient snapshot, it is not cleared after a take and
// follows edits until moved/dropped. Reports the captured anchor back (MSG.inbound.bullseyeAnchor) so Swift
// can persist it for restart-restore. When the note is not the live editor, pin an end-of-body floor so a
// later delivery still lands in the note.
export function setBullseye(payload) {
  const id = payload && payload.id;
  if (!id) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  let pos;
  if (!state.showingHistory && state.activeId === id) {
    const sel = currentSelection();
    pos = sel ? sel.from : (tab.body || "").length;
  } else {
    pos = (tab.body || "").length;
  }
  setBullseyeAnchor(id, pos);
  // Option+N always ARMS (BT2); mirror that locally so the inline marker (BT3) shows immediately at the caret.
  setBullseyeArmed(true);
  post(MSG.inbound.bullseyeAnchor, { id, anchor: pos });
  syncBullseyeMarker();
}

// Swift -> JS (insertAtBullseye, notes-bullseye BT2): land a completed take at the pinned bullseye anchor by
// note id (focus-independent - armed delivery reaches the bullseye regardless of which window is key). Brings
// the target's editor live if needed, INSERTS at the anchor (never clears the bullseye - it is persistent),
// advances the anchor past the inserted text so successive takes stack in reading order, re-persists via the
// save round-trip, and reports the advanced anchor to Swift. Falls back to the note's end if no live anchor
// exists (e.g. a mid-session page reload) so text is never lost.
export function insertAtBullseye(payload) {
  const id = payload && payload.id;
  const text = payload && typeof payload.text === "string" ? payload.text : "";
  if (!id || !text) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || !requireEditable(tab)) return;
  if (state.showingHistory) state.showingHistory = false;
  if (state.activeId !== id) {
    // Bring the target's editor live so the anchor lands in it. Its body is unchanged, so the mapped offset
    // still addresses it correctly.
    activateNoteInPlace(id, tab);
  }
  const bull = getBullseye();
  const at = bull && bull.noteId === id ? bull.anchor : (tab.body || "").length;
  const beforeLength = currentEditorDoc().length;
  const body = insertAtRange(at, at, text);
  if (body === null) return;
  const insertedLength = body.length - beforeLength;
  // BT5: an armed take inserts at the pinned anchor (nothing overwritten), so Option+Z removes exactly the
  // delivered text (empty `replaced`).
  recordDelivery(id, at, insertedLength, "");
  const advanced = at + insertedLength;
  setBullseyeAnchor(id, advanced);
  post(MSG.inbound.bullseyeAnchor, { id, anchor: advanced });
  tab.body = body;
  saveTabNow(tab);
  focusEditor();
  render();
  // BT5c: re-push the inline marker from the ADVANCED anchor as the LAST word - after the doc change, any
  // focus-independent editor swap, and render() have all settled. Two things would otherwise leave the glyph
  // one dictation behind: the marker field self-maps the side:-1 widget to the START of the insert (assoc -1,
  // = the end of the PREVIOUS dictation), and the focus-independent path already ran syncBullseyeMarker during
  // the swap from the stale pre-advance anchor. Clear first so CodeMirror re-creates the widget at the advanced
  // offset rather than reusing the eq()-stable node in place; syncBullseyeMarker then re-pushes it from the
  // (now advanced) store anchor, preserving the BT3 present-only-when-armed gate.
  setBullseyeMarker(null);
  syncBullseyeMarker();
}

// Swift -> JS (revealBullseye, notes-bullseye BT6): the last of the Option+Shift+N reveal's four steps. Swift
// has already fronted the window, selected the tab, and armed the bullseye; this brings the note's editor live
// if the island is still showing something else and SCROLLS the live anchor into view. Read-only: no edit, no
// bullseye move, no selection change - the caret stays wherever the user left it. Falls back to the note's end
// when this island holds no live anchor (a mid-session page reload), which is where a delivery would land too.
export function revealBullseye(payload) {
  const id = payload && payload.id;
  if (!id) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (state.showingHistory) state.showingHistory = false;
  if (state.activeId !== id) activateNoteInPlace(id, tab);
  const bull = getBullseye();
  const at = bull && bull.noteId === id ? bull.anchor : (tab.body || "").length;
  // Reconcile the marker first so the glyph is painted at the anchor before it scrolls into view rather than a
  // frame after (Swift's arm push and this call race), then scroll as the LAST word - after any editor swap and
  // render() have settled, so nothing reflows the view out from under the position we just scrolled to.
  syncBullseyeMarker();
  // Then play the one-shot attention cue on the marker that sync just painted. The reveal is the ONE place that
  // sends this: its whole job is "show me where the bullseye is", and a glyph that pulsed on ordinary syncs
  // (every delivery, every tab switch) would be a tic instead of an answer. Read-only like the rest of this
  // handler - pure transform/opacity on the glyph's pseudo-element, so it cannot disturb the position the
  // scroll below is about to settle on.
  pulseBullseyeMarker();
  render();
  scrollPositionIntoView(at);
}

// Swift -> JS (undoNoteDelivery, notes-bullseye BT5): revert the LAST ViddyDictate dictation edit in note `id`,
// reaching the note even when it is not the active tab / the window is not key (the target-by-note-id path - a
// note is a controlled surface, so the bridge reaches back in and undoes it). Replaces the recorded delivered
// range with the text it overwrote, so the delivered dictation is removed AND any overwritten text is restored;
// then clears the record (single-shot). No-op when the last delivery was not in this note (a newer edit landed
// elsewhere, or nothing is recorded) or the note is no longer open here.
export function undoNoteDelivery(payload) {
  const id = payload && payload.id;
  if (!id) return;
  const last = getLastDelivery();
  if (!last || last.noteId !== id) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || !requireEditable(tab)) return;
  if (state.showingHistory) state.showingHistory = false;
  if (state.activeId !== id) {
    // Bring the target's editor live so the undo lands in it (focus/select first). Its body is unchanged since
    // the last-delivery range was mapped against it, so the recorded offsets still address it correctly.
    activateNoteInPlace(id, tab);
  }
  const body = insertAtRange(last.from, last.from + last.len, last.replaced);
  clearLastDelivery();
  if (body === null) return;
  tab.body = body;
  saveTabNow(tab);
  focusEditor();
  render();
}

// Swift -> JS (replaceNoteDelivery, explicit provider retry): replace the LAST ViddyDictate delivery in
// note `id` with the confirmed provider's output. The last-delivery range follows intervening edits, so this
// restores the original landing rather than using current focus. Preserve `replaced` so Option+Z after the
// retry still restores the text that existed before the failed-route raw fallback.
export function replaceNoteDelivery(payload) {
  const id = payload && payload.id;
  const text = payload && typeof payload.text === "string" ? payload.text : "";
  if (!id || !text) return;
  const last = getLastDelivery();
  if (!last || last.noteId !== id) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab || !requireEditable(tab)) return;
  if (state.showingHistory) state.showingHistory = false;
  if (state.activeId !== id) {
    activateNoteInPlace(id, tab);
  }
  const body = insertAtRange(last.from, last.from + last.len, text);
  if (body === null) return;
  recordDelivery(id, last.from, text.length, last.replaced);
  tab.body = body;
  saveTabNow(tab);
  focusEditor();
  render();
}
