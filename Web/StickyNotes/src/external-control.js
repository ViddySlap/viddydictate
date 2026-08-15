import { MSG, post } from "./bridge.js";
import { appendToEditorEnd, focusEditor, forgetEditorState, insertIntoEditor } from "./editor.js";
import { flushActive, saveTabNow } from "./persistence.js";
import { render } from "./render.js";
import { activeTab, state, tabFromWire, tabOrder } from "./state.js";
import {
  activateNoteInPlace,
  replaceEditorForTab,
  requireEditable,
  selectTab,
} from "./actions.js";

// Swift -> JS: render a note already created and persisted by the loopback control endpoint.
export function externalCreate(payload) {
  if (!payload || !payload.id) return;
  flushActive();
  state.showingHistory = false;
  const existing = state.tabs.find((tab) => tab.id === payload.id);
  const incoming = tabFromWire(payload);
  if (existing) {
    Object.assign(existing, incoming);
  } else {
    state.tabs.push(incoming);
  }
  state.activeId = payload.id;
  if (existing) forgetEditorState(existing.id);
  replaceEditorForTab(existing || incoming, incoming.body, { resetHistory: Boolean(existing) });
  render();
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  focusEditor();
}

// Swift -> JS: replace a live note body already persisted by the loopback control endpoint.
export function externalSetBody(payload) {
  if (!payload || !payload.id) return;
  const tab = state.tabs.find((candidate) => candidate.id === payload.id);
  if (!tab) return;
  forgetEditorState(tab.id);
  tab.body = payload.body || "";
  if (state.activeId === tab.id) replaceEditorForTab(tab, null, { resetHistory: true });
  render();
  post(MSG.inbound.save, { id: tab.id, body: tab.body, tabOrder: tabOrder(), activeId: state.activeId });
}

// Swift -> JS: insert text at the target note's live caret and persist the resulting body.
export function externalInsert(payload) {
  if (!payload || !payload.id) return;
  const text = typeof payload.text === "string" ? payload.text : "";
  if (!text) return;
  const tab = state.tabs.find((candidate) => candidate.id === payload.id);
  if (!tab || !requireEditable(tab)) return;
  if (state.showingHistory) state.showingHistory = false;
  if (state.activeId !== tab.id) activateNoteInPlace(tab.id, tab);
  const body = insertIntoEditor(text);
  if (body === null) return;
  tab.body = body;
  saveTabNow(tab);
  focusEditor();
  render();
}

// Swift -> JS: append a Sticky Skill result to the END of note `id` (S2, the .appendToSource landing).
//
// This is the SAFE half of the append. Swift never computes or writes the body while this island is live:
// it hands over the addition only, and the append lands here as an ordinary CodeMirror transaction against
// the LIVE document, after which we re-persist the exact result through the normal save round-trip (JS as
// authoritative last writer, identical to how dictation persists). So a lost update is structurally
// impossible - nothing typed since the last 180 ms debounce can be overwritten by a Swift-side stale read -
// and, unlike externalSetBody, the note's EditorState is not replaced, so its per-note undo stack survives.
//
// Deliberately does NOT focusEditor(): every other Swift-driven insertion here is the landing of a gesture
// the user just made, whereas an append is a background job completing, possibly while they are typing.
// appendToEditorEnd leaves the selection alone for the same reason.
export function externalAppend(payload) {
  if (!payload || !payload.id) return;
  const text = typeof payload.text === "string" ? payload.text : "";
  if (!text) return;
  const tab = state.tabs.find((candidate) => candidate.id === payload.id);
  if (!tab || !requireEditable(tab)) return;
  if (state.showingHistory) state.showingHistory = false;
  // There is one EditorView per window, so the target note has to be the one in it for a transaction to
  // reach it - the same swap every focus-independent seam here already performs (insertAtTarget,
  // insertAtBullseye, undoNoteDelivery). activateNoteInPlace flushes the outgoing tab first, so the swap
  // itself loses nothing.
  if (state.activeId !== tab.id) activateNoteInPlace(tab.id, tab);
  const body = appendToEditorEnd(text);
  if (body === null) return;
  tab.body = body;
  saveTabNow(tab);
  render();
}

// Swift -> JS: drop a tab whose note was already soft-closed by the loopback control endpoint.
export function externalClose(payload) {
  const id = payload && payload.id;
  const idx = state.tabs.findIndex((tab) => tab.id === id);
  if (idx < 0) return;
  forgetEditorState(id);
  state.tabs.splice(idx, 1);
  if (state.activeId === id) {
    state.activeId = state.tabs[Math.min(idx, state.tabs.length - 1)]?.id || null;
    replaceEditorForTab(activeTab());
  }
  post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  render();
}

// Swift -> JS: focus a live tab after native code raises its window.
export function externalFocus(payload) {
  const id = payload && payload.id;
  if (!id) return;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  if (!tab) return;
  if (state.activeId !== id || state.showingHistory) {
    selectTab(id);
  } else {
    focusEditor();
  }
}
