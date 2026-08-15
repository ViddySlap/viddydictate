// No-op stand-ins for the DOM-only view modules (render.js, drag-rail.js). The loader hook redirects both
// imports here so the real actions.js can be exercised headlessly: the BUG 2 sequence never depends on rendering
// or the drag rail, only on the store + editor semantics, so these collapse to no-ops. Exports the UNION of the
// names actions.js imports from render.js and drag-rail.js (extra names on a module are harmless).

// render.js surface
export function applyCheatSheetButton() {}
export function hideTabMenu() {}
export function render() {}
export function renderSettingsStrip() {}
export function renderTabs() {}
export function renderTray() {}
export function showToast() {}

// drag-rail.js surface
export function endTabDragSelectionGuard() {}
export function hideDropIndicator() {}
export function insertionIndexForX() { return 0; }
export function setDraggingTabId() {}
