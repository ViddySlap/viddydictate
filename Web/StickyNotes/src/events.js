import {
  backButton,
  blankNewButton,
  cheatSheetEl,
  cheatSheetToggle,
  copyAssetsButton,
  copyButton,
  historyButton,
  infoButton,
  miniCopyAssetsButton,
  miniCopyButton,
  miniEnterButton,
  miniGrabHandle,
  miniInfoButton,
  miniToggleButton,
  newTabButton,
  retentionSelect,
  tabMenuEl,
} from "./dom.js";
import { beginMiniGrabDragTracking } from "./drag-rail.js";
import {
  cancelInlineRename,
  copyActiveAssets,
  copyActiveTab,
  createTab,
  goBack,
  setManualMini,
  showHistory,
  updateCheatSheetButton,
  updateRetention,
} from "./actions.js";
import {
  handleTabMenuAction,
  hideCheatSheet,
  hideTabMenu,
  setMiniHover,
} from "./render.js";
import { flushActive } from "./persistence.js";
import { state } from "./state.js";

export function installEventHandlers() {
  newTabButton.addEventListener("click", () => createTab(""));
  blankNewButton.addEventListener("click", () => createTab(""));
  historyButton.addEventListener("click", showHistory);
  // Hamburger settings strip (L5): Back returns to the pre-hamburger note; the toggle + popup post their
  // new inbound messages (Swift owns both settings and echoes them back via the `settings` push).
  backButton.addEventListener("click", goBack);
  cheatSheetToggle.addEventListener("change", () => {
    updateCheatSheetButton(cheatSheetToggle.checked);
  });
  retentionSelect.addEventListener("change", () => {
    updateRetention(retentionSelect.value);
  });
  copyButton.addEventListener("click", copyActiveTab);
  copyAssetsButton.addEventListener("click", copyActiveAssets);
  infoButton.addEventListener("click", (event) => {
    event.stopPropagation();
    cheatSheetEl.hidden = !cheatSheetEl.hidden;
  });
  // Mini view (notes-miniview A3): the full-view collapse button flips manual mini ON; the overlay toggle flips
  // it OFF (Swift owns the effective decision). The overlay's copy / copy-assets / "i" reuse the same actions as
  // their full-view counterparts, acting on the active note.
  miniEnterButton.addEventListener("click", () => setManualMini(true));
  miniToggleButton.addEventListener("click", () => setManualMini(false));
  miniCopyButton.addEventListener("click", copyActiveTab);
  miniCopyAssetsButton.addEventListener("click", copyActiveAssets);
  miniInfoButton.addEventListener("click", (event) => {
    event.stopPropagation();
    cheatSheetEl.hidden = !cheatSheetEl.hidden;
  });
  // Mini drag-out (7b): grabbing the hover-revealed top-edge handle starts a Swift-mediated drag of the active
  // note out of the mini window (there is no visible tab to grab — the mini strip is display:none).
  miniGrabHandle.addEventListener("mousedown", beginMiniGrabDragTracking);
  // The overlay only exists while the pointer is over the window; body.mini-hover is the latch (CSS gates it to
  // mini-mode). mousemove keeps it up (idempotent) even if a mouseenter was missed; mouseleave drops it.
  // S8: these are now the FALLBACK, not the source of truth. AppKit never routes mouse-moved events to a
  // window that is not key, so a JS-only latch tracked window focus rather than the pointer and the mini
  // chrome appeared only after clicking the note. Swift's .activeAlways tracking area drives the same setter
  // over the miniHover bridge message. The two cannot fight: both are idempotent writes of the same class,
  // and the pointer being outside means no mousemove arrives to contradict Swift's exit.
  document.body.addEventListener("mousemove", () => setMiniHover(true));
  document.body.addEventListener("mouseleave", () => setMiniHover(false));
  tabMenuEl.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button || !state.menuTabId) return;
    const id = state.menuTabId;
    const action = button.dataset.action;
    const skillId = button.dataset.skillId || null;
    hideTabMenu();
    handleTabMenuAction(action, id, skillId);
  });
  window.addEventListener("mousedown", (event) => {
    if (!tabMenuEl.hidden && !tabMenuEl.contains(event.target)) hideTabMenu();
    if (!cheatSheetEl.hidden && !cheatSheetEl.contains(event.target)
        && event.target !== infoButton && event.target !== miniInfoButton) {
      hideCheatSheet();
    }
  });
  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      hideTabMenu();
      if (state.editingTabId) cancelInlineRename();
      hideCheatSheet();
    }
  });
  window.addEventListener("blur", () => {
    hideTabMenu();
    flushActive("windowBlur");
  });
}
