import { MSG, post } from "./bridge.js";
import { currentEditorDoc, hasEditor } from "./editor.js";
import { activeTab, state, tabOrder } from "./state.js";

let saveTimer = null;
let fileAutosaveTimer = null;

// Tunable Stage 1 cadence: inside the locked 10-15 second window. The timer runs even while buffers are clean
// so an external agent write can live-reload without waiting for the user to type again.
export const FILE_AUTOSAVE_MS = 12_000;

export function startFileAutosave() {
  if (fileAutosaveTimer !== null) return;
  fileAutosaveTimer = setInterval(() => syncFileBackedTabs("timer"), FILE_AUTOSAVE_MS);
}

export function syncFileBackedTabs(reason = "timer") {
  const active = activeTab();
  if (active?.kind === "fileBacked" && hasEditor()) active.body = currentEditorDoc();
  for (const tab of state.tabs) {
    if (tab.kind !== "fileBacked") continue;
    post(MSG.inbound.fileSync, { id: tab.id, body: tab.body, reason });
  }
}

export function scheduleSave(tab) {
  clearTimeout(saveTimer);
  // File-backed tabs use the shared 12-second polling timer so CLEAN buffers also notice external writes.
  // Scratch notes retain their existing short debounce unchanged.
  if (tab.kind === "fileBacked") return;
  saveTimer = setTimeout(() => {
    saveTabNow(tab);
  }, 180);
}

export function saveTabNow(tab, reason = "immediate") {
  clearTimeout(saveTimer);
  if (tab.kind === "fileBacked") {
    post(MSG.inbound.fileSync, { id: tab.id, body: tab.body, reason });
    return;
  }
  post(MSG.inbound.save, {
    id: tab.id,
    body: tab.body,
    tabOrder: tabOrder(),
    activeId: state.activeId,
  });
}

export function flushActive(reason = "blur") {
  const tab = activeTab();
  if (!tab || !hasEditor()) return;
  tab.body = currentEditorDoc();
  if (tab.kind === "fileBacked") {
    post(MSG.inbound.fileBufferChanged, { id: tab.id, body: tab.body });
    post(MSG.inbound.fileSync, { id: tab.id, body: tab.body, reason });
    return;
  }
  if (tab.body.trim()) {
    post(MSG.inbound.save, { id: tab.id, body: tab.body, tabOrder: tabOrder(), activeId: state.activeId });
  } else {
    post(MSG.inbound.active, { tabOrder: tabOrder(), activeId: state.activeId });
  }
}
