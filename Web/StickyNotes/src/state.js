export const state = {
  tabs: [],
  activeId: null,
  historyEntries: [],
  showingHistory: false,
  // Attachments per note id -> [{id, name, kind, thumb}], pushed from Swift via the `attachments` message.
  // The tray + copy-assets button render from the ACTIVE note's entry (L4).
  attachmentsByNote: Object.create(null),
  // Hamburger settings strip (L5). Swift owns both settings; these mirror the last-pushed
  // values so the strip renders in sync. `preHamburgerActiveId` is the tab that was active when the
  // hamburger was opened, so Back can return to it.
  cheatSheetButton: true,
  retention: "oneDay",
  preHamburgerActiveId: null,
  menuTabId: null,
  editingTabId: null,
  // notes-8-rename: the attachment id currently in inline-rename (its tray thumb renders a name input in
  // place, mirroring editingTabId for the tab strip). null when no attachment rename is in flight.
  editingAttachmentId: null,
};

export function newId() {
  const rand = Math.random().toString(36).slice(2, 10);
  return `note-${Date.now()}-${rand}`;
}

export function activeTab() {
  return state.tabs.find((tab) => tab.id === state.activeId) || null;
}

export function tabOrder() {
  return state.tabs.map((tab) => tab.id);
}

export function strippedTitle(body) {
  const lines = body.split(/\r?\n/);
  for (const line of lines) {
    let s = line.trim();
    if (!s) continue;
    s = s.replace(/^#+\s*/, "");
    s = s.replace(/^[-*+>]\s+/, "");
    s = s.replace(/^\d+\.\s+/, "");
    s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
    s = s.replace(/[`*_]/g, "").trim();
    if (s) {
      return s.length > 20 ? `${s.slice(0, 17).trim()}...` : s;
    }
  }
  return "Untitled";
}

export function displayTitle(tab, activeBody = null) {
  if (tab.kind === "fileBacked") return tab.title || "Untitled.md";
  if (tab.title && tab.title.trim()) return tab.title.trim();
  const body = tab.id === state.activeId && typeof activeBody === "string" ? activeBody : tab.body;
  return strippedTitle(body || "");
}

export function activeAttachments() {
  return (state.activeId && state.attachmentsByNote[state.activeId]) || [];
}

export function receiveAttachmentsState(payload) {
  if (!payload || !payload.noteId) return false;
  const items = Array.isArray(payload.items) ? payload.items : [];
  if (items.length) state.attachmentsByNote[payload.noteId] = items;
  else delete state.attachmentsByNote[payload.noteId];
  return payload.noteId === state.activeId;
}

export function applySettingsState(payload) {
  if (!payload) return;
  if (typeof payload.cheatSheetButton === "boolean") state.cheatSheetButton = payload.cheatSheetButton;
  if (typeof payload.retention === "string") state.retention = payload.retention;
}

export function receiveStatePayload(payload) {
  state.tabs = (payload.notes || []).map(tabFromWire);
  state.activeId = payload.activeId && state.tabs.some((tab) => tab.id === payload.activeId)
    ? payload.activeId
    : (state.tabs[0]?.id || null);
  state.historyEntries = payload.history || [];
  // L5: the settings are carried in the initial state so the cheat-sheet button + strip are correct
  // immediately (and after a crash+reload), before the first standalone settings push.
  applySettingsState(payload);
  state.showingHistory = false;
}

export function applyFileSyncAck(tab, body) {
  tab.fileSyncedBody = typeof body === "string" ? body : tab.fileSyncedBody;
}

export function resolveFileReload(tab, payload, liveBody) {
  const expected = typeof payload.expectedBody === "string" ? payload.expectedBody : tab.fileSyncedBody;
  if (!payload.force && liveBody !== expected) {
    tab.body = liveBody;
    return false;
  }
  tab.body = payload.body;
  tab.fileSyncedBody = payload.body;
  return true;
}

export function tabFromWire(note) {
  const body = note.body || "";
  return {
    id: note.id,
    body,
    title: note.title || "",
    kind: note.kind || "scratch",
    filePath: typeof note.filePath === "string" ? note.filePath : null,
    canRename: note.canRename !== false,
    canEdit: note.canEdit !== false,
    // Ephemeral CodeMirror state transferred only while dragging an open tab between windows. Consumed on
    // first activation; never persisted in a note or windows.json.
    editorState: typeof note.editorState === "string" ? note.editorState : null,
    // The last body native confirmed as the file's loaded/saved version. Newer edits remain dirty when an
    // older save acknowledgement arrives because tab.body will differ from this baseline.
    fileSyncedBody: (note.kind || "scratch") === "fileBacked" ? body : null,
  };
}

export function receiveHistoryPayload(payload) {
  state.historyEntries = payload.history || [];
}
