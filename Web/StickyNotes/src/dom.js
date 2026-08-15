export const tabsEl = document.getElementById("tabs");
export const editorEl = document.getElementById("editor");
export const historyEl = document.getElementById("history");
export const copyButton = document.getElementById("copy-button");
export const infoButton = document.getElementById("info-button");
export const cheatSheetEl = document.getElementById("md-cheatsheet");
export const newTabButton = document.getElementById("new-tab");
export const blankNewButton = document.getElementById("blank-new");
export const historyButton = document.getElementById("history-button");
export const toastEl = document.getElementById("toast");
export const tabMenuEl = document.getElementById("tab-menu");
export const stickySkillsMenuSeparator = document.getElementById("sticky-skills-menu-separator");
export const stickySkillsMenuSection = document.getElementById("sticky-skills-menu-section");
export const stickySkillsMenuItems = document.getElementById("sticky-skills-menu-items");
export const trayEl = document.getElementById("attachment-tray");
export const copyAssetsButton = document.getElementById("copy-assets-button");
export const dropOverlayEl = document.getElementById("drop-overlay");
export const dragIndicatorEl = document.getElementById("drag-indicator");

// Hamburger settings strip (L5).
export const backButton = document.getElementById("notes-back");
export const cheatSheetToggle = document.getElementById("cheatsheet-toggle");
export const retentionSelect = document.getElementById("retention-select");

// Mini view (notes-miniview A3): the full-view collapse button lives in the tab bar; the hover overlay (the
// only chrome visible in mini, and only on hover) carries the per-note copy buttons, the "i" cheat-sheet
// button, and the mini-toggle back to full.
export const miniEnterButton = document.getElementById("mini-enter");
export const miniOverlayEl = document.getElementById("mini-overlay");
export const miniCopyButton = document.getElementById("mini-copy");
export const miniCopyAssetsButton = document.getElementById("mini-copy-assets");
export const miniInfoButton = document.getElementById("mini-info");
export const miniToggleButton = document.getElementById("mini-toggle");
// Mini drag-out grab handle (round-5 R2, item 7b): the hover-revealed top-edge pill whose grab starts a
// Swift-mediated drag of the active note out of a mini window (the mini strip's tabs are display:none).
export const miniGrabHandle = document.getElementById("mini-grab");
