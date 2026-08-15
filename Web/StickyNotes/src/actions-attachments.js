import { MSG, post } from "./bridge.js";
import { renderTray } from "./render.js";
import { receiveAttachmentsState, state } from "./state.js";

// Inline attachment rename: begin renders an input, commit posts the new name, and cancel re-renders.
export function beginAttachmentRename(attachmentId) {
  state.editingAttachmentId = attachmentId;
  renderTray();
}

export function commitAttachmentRename(noteId, attachmentId, rawName) {
  state.editingAttachmentId = null;
  const newName = rawName.trim();
  if (newName) post(MSG.inbound.renameAttachment, { noteId, attachmentId, newName });
  renderTray();
}

export function cancelAttachmentRename() {
  state.editingAttachmentId = null;
  renderTray();
}

// Store a note's current attachment set and refresh the tray when that note is active.
export function receiveAttachments(payload) {
  if (receiveAttachmentsState(payload)) renderTray();
}
