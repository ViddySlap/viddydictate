import { MSG, post } from "./bridge.js";
import { dragIndicatorEl, tabsEl } from "./dom.js";
import { collapseEditorSelection, serializeEditorState } from "./editor.js";
import { flushActive } from "./persistence.js";
import { state } from "./state.js";

// Tab drag rail (L7). The drag itself is Swift-mediated (a WKWebView cannot track a drag
// across windows): the island posts tabDragStart once a mousedown-on-tab crosses ~4px, then Swift drives the
// ghost + indicator + drop. `draggingTabId` is the lifted tab (survives re-renders); `dragTracking` holds the
// in-progress mousedown gesture until the threshold; `suppressNextTabClick` swallows the click that follows a
// completed drag so it does not also select the tab. `tabDragSelectionGuardActive` is scoped to a real tab drag
// only; normal text selection inside the note body stays untouched outside that gesture.
let draggingTabId = null;
let dragTracking = null;
let suppressNextTabClick = false;
let tabDragSelectionGuardActive = false;
let clearingTabDragSelection = false;
const DRAG_THRESHOLD = 4;
const TAB_DRAG_SELECTION_GUARD_CLASS = "tab-drag-selection-guard";

export function getDraggingTabId() {
  return draggingTabId;
}

export function setDraggingTabId(id) {
  draggingTabId = id;
}

export function consumeSuppressNextTabClick() {
  if (!suppressNextTabClick) return false;
  suppressNextTabClick = false;
  return true;
}

function collapseNativeSelection() {
  const selection = window.getSelection ? window.getSelection() : null;
  if (!selection || selection.rangeCount === 0) return;
  clearingTabDragSelection = true;
  selection.removeAllRanges();
  clearingTabDragSelection = false;
}

function clearTabDragSelection() {
  collapseNativeSelection();
  collapseEditorSelection();
}

function onTabDragSelectStart(event) {
  if (!tabDragSelectionGuardActive) return;
  event.preventDefault();
  clearTabDragSelection();
}

function onTabDragSelectionChange() {
  if (!tabDragSelectionGuardActive || clearingTabDragSelection) return;
  collapseNativeSelection();
}

function setTabDragSelectionGuard(active) {
  if (tabDragSelectionGuardActive === active) {
    clearTabDragSelection();
    return;
  }
  tabDragSelectionGuardActive = active;
  document.body.classList.toggle(TAB_DRAG_SELECTION_GUARD_CLASS, active);
  const action = active ? "addEventListener" : "removeEventListener";
  document[action]("selectstart", onTabDragSelectStart, true);
  document[action]("selectionchange", onTabDragSelectionChange, true);
  clearTabDragSelection();
}

function armTabDragSelectionGuard() {
  setTabDragSelectionGuard(true);
}

export function endTabDragSelectionGuard() {
  setTabDragSelectionGuard(false);
}

// Pointer-based (NOT HTML5 draggable, which suppresses text selection and fights the rebuild-on-render
// strip). A mousedown on a tab starts tracking; once movement passes DRAG_THRESHOLD we post tabDragStart
// and hand off to Swift, which owns the ghost, the cross-window hit-test, and the drop. Swift drives the
// insertion bar via dragIndicator and ends the drag via reorderTab.
function startDragTracking(event, id, el, lift) {
  event.preventDefault();                              // drag gestures must never seed a native selection
  clearTabDragSelection();
  // `lift` marks the source element to raise out of the strip on threshold cross (a real tab); the mini
  // grab-out has no visible tab to lift, so it passes false.
  dragTracking = { id, el, startX: event.clientX, startY: event.clientY, started: false, lift };
  window.addEventListener("mousemove", onDragTrackingMove, true);
  window.addEventListener("mouseup", onDragTrackingUp, true);
}

export function beginTabDragTracking(event, tab, el) {
  if (event.button !== 0) return;
  if (state.editingTabId === tab.id) return;           // don't drag while renaming
  if (event.target.closest(".tab-close")) return;      // the close button owns its own click
  startDragTracking(event, tab.id, el, true);
}

// Mini drag-out (round-5 R2, item 7b): in mini view the tab strip is display:none, so there is no tab to grab
// — the hover-revealed top-edge grab handle IS the drag-out. A mousedown on it starts a drag of the ACTIVE
// note through the SAME machinery + coordinator (Swift owns the ghost, the cross-window hit-test, and the drop
// outcome: dock / new-window / snap-back). Nothing is lifted (the strip is hidden), so `lift` is false.
export function beginMiniGrabDragTracking(event) {
  if (event.button !== 0) return;
  const id = state.activeId;
  if (!id) return;                                     // nothing active to drag out
  startDragTracking(event, id, event.currentTarget, false);
}

function onDragTrackingMove(event) {
  if (!dragTracking) return;
  event.preventDefault();
  if (!dragTracking.started) {
    const dx = event.clientX - dragTracking.startX;
    const dy = event.clientY - dragTracking.startY;
    if (Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
    dragTracking.started = true;
    const rect = dragTracking.el.getBoundingClientRect();
    draggingTabId = dragTracking.id;
    // Persist the active editor's latest body up front so a cross-window dock (L8) reads a fresh note body
    // from the store rather than a debounce-stale one; harmless for a same-window reorder.
    flushActive();
    // Lift the source tab without re-rendering the whole strip (so its geometry stays put for the drop
    // index Swift captured at start). The mini grab-out has no visible tab to lift (lift === false).
    if (dragTracking.lift) dragTracking.el.classList.add("dragging");
    armTabDragSelectionGuard();
    const tab = state.tabs.find((candidate) => candidate.id === dragTracking.id);
    post(MSG.inbound.tabDragStart, {
      noteId: dragTracking.id,
      body: tab ? (tab.body || "") : "",
      title: tab ? (tab.title || "") : "",
      kind: tab ? (tab.kind || "scratch") : "scratch",
      filePath: tab ? (tab.filePath || null) : null,
      canRename: tab ? tab.canRename !== false : true,
      canEdit: tab ? tab.canEdit !== false : true,
      editorState: serializeEditorState(dragTracking.id),
      grabOffsetX: dragTracking.startX - rect.left,
      grabOffsetY: dragTracking.startY - rect.top,
    });
  }
}

function onDragTrackingUp() {
  window.removeEventListener("mousemove", onDragTrackingMove, true);
  window.removeEventListener("mouseup", onDragTrackingUp, true);
  if (dragTracking && dragTracking.started) {
    // Swift's reorderTab (commit or cancel) clears draggingTabId + the lifted style. Swallow the click that
    // this mouseUp will fire so a completed drag never also selects the tab.
    suppressNextTabClick = true;
    setTimeout(() => { suppressNextTabClick = false; }, 0);
  }
  endTabDragSelectionGuard();
  dragTracking = null;
}

// The insertion index for a strip-local x: the count of tabs whose horizontal midpoint is left of x. Mirrors
// NotesWindowRegistry.insertionIndex on the Swift side so the rendered bar matches the committed drop.
export function insertionIndexForX(x) {
  const tabEls = tabsEl.querySelectorAll(".tab");
  let idx = 0;
  for (const el of tabEls) {
    const r = el.getBoundingClientRect();
    if (r.left + r.width / 2 < x) idx += 1;
    else break;
  }
  return idx;
}

// Swift -> JS (dragIndicator): draw the insertion bar at the boundary for strip-local x, or hide it (x null,
// sent when the cursor leaves this window's strip).
export function showDropIndicator(x) {
  if (!dragIndicatorEl) return;
  const tabEls = tabsEl.querySelectorAll(".tab");
  if (typeof x !== "number" || !isFinite(x) || tabEls.length === 0) { hideDropIndicator(); return; }
  const idx = insertionIndexForX(x);
  const boundary = idx >= tabEls.length
    ? tabEls[tabEls.length - 1].getBoundingClientRect().right
    : tabEls[idx].getBoundingClientRect().left;
  const barRect = tabsEl.parentElement.getBoundingClientRect();   // #tabbar
  dragIndicatorEl.style.left = `${Math.max(0, boundary - barRect.left)}px`;
  dragIndicatorEl.hidden = false;
}

export function hideDropIndicator() {
  if (dragIndicatorEl) dragIndicatorEl.hidden = true;
}
