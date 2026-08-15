import { MSG, post } from "./bridge.js";
import {
  cheatSheetEl,
  cheatSheetToggle,
  copyAssetsButton,
  dropOverlayEl,
  historyEl,
  infoButton,
  retentionSelect,
  stickySkillsMenuItems,
  stickySkillsMenuSection,
  stickySkillsMenuSeparator,
  tabMenuEl,
  tabsEl,
  toastEl,
  trayEl,
} from "./dom.js";
import { beginTabDragTracking, consumeSuppressNextTabClick, getDraggingTabId } from "./drag-rail.js";
import { currentEditorDoc } from "./editor.js";
import {
  activeAttachments,
  displayTitle,
  state,
} from "./state.js";
import { renderStickySkillMenu } from "./sticky-skill-menu.js";

let actionHandlers = null;

export function setRenderActionHandlers(handlers) {
  actionHandlers = handlers;
}

function actions() {
  if (!actionHandlers) throw new Error("render action handlers not installed");
  return actionHandlers;
}

export function hideTabMenu() {
  state.menuTabId = null;
  tabMenuEl.hidden = true;
}

export function showTabMenu(id, event) {
  state.menuTabId = id;
  const tab = state.tabs.find((candidate) => candidate.id === id);
  const hasAttachments = (tab && state.attachmentsByNote[tab.id] || []).length > 0;
  const body = tab?.id === state.activeId ? currentEditorDoc() : (tab?.body || "");
  const rename = tabMenuEl.querySelector('[data-action="rename"]');
  if (rename) rename.disabled = tab?.canRename === false;
  const skillButtons = tabMenuEl.querySelectorAll('[data-action="stickySkill"]');
  for (const button of skillButtons) {
    button.disabled = !tab || (!body.trim() && !hasAttachments);
  }
  const openInFinder = tabMenuEl.querySelector('[data-action="openInFinder"]');
  if (openInFinder) {
    const canReveal = tab?.kind === "fileBacked"
      ? !!tab.filePath
      : !!tab && (!!tab.body.trim() || hasAttachments);
    openInFinder.disabled = !canReveal;
  }
  tabMenuEl.hidden = false;
  const x = Math.min(event.clientX, window.innerWidth - tabMenuEl.offsetWidth - 8);
  const y = Math.min(event.clientY, window.innerHeight - tabMenuEl.offsetHeight - 8);
  tabMenuEl.style.left = `${Math.max(8, x)}px`;
  tabMenuEl.style.top = `${Math.max(8, y)}px`;
}

function createInlineEditor({ className, ariaLabel, value, commit, cancel, stopDoubleClick = false }) {
  const input = document.createElement("input");
  input.className = className;
  input.type = "text";
  input.autocomplete = "off";
  input.setAttribute("aria-label", ariaLabel);
  input.value = value;
  let done = false;
  const finish = (shouldCommit) => {
    if (done) return;
    done = true;
    if (shouldCommit) commit(input.value);
    else cancel();
  };
  input.addEventListener("mousedown", (event) => event.stopPropagation());
  input.addEventListener("click", (event) => event.stopPropagation());
  if (stopDoubleClick) input.addEventListener("dblclick", (event) => event.stopPropagation());
  input.addEventListener("keydown", (event) => {
    event.stopPropagation();
    if (event.key === "Enter") { event.preventDefault(); finish(true); }
    else if (event.key === "Escape") { event.preventDefault(); finish(false); }
  });
  input.addEventListener("blur", () => finish(true));
  requestAnimationFrame(() => { input.focus(); input.select(); });
  return input;
}

// Inline tab rename: the title element becomes a text input in place (select-all prefilled, Enter
// commits, Esc cancels, blur commits). Retires the old #rename-dialog overlay. renderTabs() renders the
// editing tab as an input so a mid-edit re-render preserves it. Commit reuses MSG.inbound.rename.
function makeTitleEditor(tab) {
  const displayed = displayTitle(tab, currentEditorDoc());
  const value = tab.kind === "fileBacked" && displayed.toLowerCase().endsWith(".md")
    ? displayed.slice(0, -3)
    : displayed;
  return createInlineEditor({
    className: "tab-title-input",
    ariaLabel: "Note title",
    value,
    commit: (newValue) => actions().commitInlineRename(tab.id, newValue),
    cancel: () => actions().cancelInlineRename(),
    stopDoubleClick: true,
  });
}

// Inline attachment rename (notes-8-rename): right-clicking a tray thumb turns its name band into a text
// input in place, modeled on makeTitleEditor. Prefilled with the full current name (extension included) and
// select-all, Enter commits, Esc cancels, blur commits. renderTray() renders the editing thumb with this
// input so a mid-edit re-render (e.g. a settings/attachments push) preserves it. Swift keeps the NN- prefix
// and the media extension and re-pushes the tray, so the new name shows once the round-trip lands.
function makeAttachmentNameEditor(noteId, item) {
  return createInlineEditor({
    className: "attachment-name-input",
    ariaLabel: "Attachment name",
    value: item.name || "attachment",
    commit: (newValue) => actions().commitAttachmentRename(noteId, item.id, newValue),
    cancel: () => actions().cancelAttachmentRename(),
  });
}

// #tabs is the sole horizontal scroller (notes-9-layout). Translate a vertical wheel over the strip into
// horizontal tab scrolling so a mouse wheel / trackpad reaches off-screen tabs; only consume the wheel when
// there is actual overflow, so an in-bounds strip leaves page/editor scrolling untouched. Installed once.
let tabsWheelInstalled = false;
function ensureTabsWheelScroll() {
  if (tabsWheelInstalled) return;
  tabsWheelInstalled = true;
  tabsEl.addEventListener("wheel", (event) => {
    if (tabsEl.scrollWidth <= tabsEl.clientWidth) return;
    const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
    if (delta === 0) return;
    tabsEl.scrollLeft += delta;
    event.preventDefault();
  }, { passive: false });
  tabsEl.addEventListener("scroll", updateTabStripClip, { passive: true });
  // The strip's width is flexbox's to decide, not ours: it shrinks when the window shrinks, and it goes from
  // 0 to real when the mini band is revealed. Both change whether there is a clip while the tab COUNT stays
  // put, so observing the element covers what a render-time call cannot.
  if (typeof ResizeObserver === "function") new ResizeObserver(updateTabStripClip).observe(tabsEl);
}

// The strip's clip state, published as two body classes for the CSS to hang the pinned-lane
// surface and the trailing fade off (see `body.tabs-overflow` / `body.tabs-clipped` in app.css). Read from
// the live scroller rather than from state.tabs.length, because whether the tabs fit is a question about
// pixels - tab titles, window width, full vs mini metrics - that a count cannot answer.
//
// The two are deliberately not the same flag. `tabs-overflow` says the strip scrolls at all, which is when
// the lane is a lane worth drawing; `tabs-clipped` additionally says there are pixels still to the right of
// the viewport, which is the only moment a tab is actually being cut. Scrolled hard right they diverge: the
// last tab sits whole against the lane, and fading it there would invent the defect this item removes.
function updateTabStripClip() {
  const slack = tabsEl.scrollWidth - tabsEl.clientWidth;
  const overflowing = slack > 1;
  document.body.classList.toggle("tabs-overflow", overflowing);
  document.body.classList.toggle("tabs-clipped", overflowing && slack - tabsEl.scrollLeft > 1);
}

// Keep the active tab in view when the strip overflows (notes-9-layout). inline:'nearest' scrolls only the
// horizontal strip; block:'nearest' avoids nudging the page/editor vertically. Shared with the mini hover
// reveal (L8), which needs to re-run it because a scroll performed while the strip is display:none is a no-op.
function scrollActiveTabIntoView() {
  const activeEl = tabsEl.querySelector(".tab.active");
  if (activeEl) activeEl.scrollIntoView({ inline: "nearest", block: "nearest" });
}

export function renderTabs() {
  tabsEl.innerHTML = "";
  ensureTabsWheelScroll();
  const draggingTabId = getDraggingTabId();
  for (const tab of state.tabs) {
    const el = document.createElement("div");
    el.className = `tab${tab.id === state.activeId ? " active" : ""}${tab.id === draggingTabId ? " dragging" : ""}`;
    el.addEventListener("mousedown", (event) => beginTabDragTracking(event, tab, el));
    el.addEventListener("click", () => {
      if (consumeSuppressNextTabClick()) return;
      actions().selectTab(tab.id);
    });
    el.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      showTabMenu(tab.id, event);
    });

    if (tab.id === state.editingTabId) {
      el.appendChild(makeTitleEditor(tab));
    } else {
      const title = document.createElement("div");
      title.className = "tab-title";
      title.textContent = displayTitle(tab, currentEditorDoc());
      title.addEventListener("dblclick", (event) => {
        event.stopPropagation();
        if (tab.canRename !== false) actions().beginInlineRename(tab.id);
      });
      el.appendChild(title);
    }

    const close = document.createElement("button");
    close.className = "tab-close";
    close.textContent = "x";
    close.title = "Close sticky note";
    close.addEventListener("click", (event) => {
      event.stopPropagation();
      actions().closeTab(tab.id);
    });
    el.appendChild(close);
    tabsEl.appendChild(el);
  }
  scrollActiveTabIntoView();
  updateTabStripClip();
}

export function renderHistory() {
  historyEl.innerHTML = "";
  const title = document.createElement("h1");
  title.className = "history-title";
  title.textContent = "Notes History";
  historyEl.appendChild(title);

  if (!state.historyEntries.length) {
    const empty = document.createElement("div");
    empty.className = "history-empty";
    empty.textContent = "No closed sticky notes in history.";
    historyEl.appendChild(empty);
    return;
  }

  for (const entry of state.historyEntries) {
    const row = document.createElement("div");
    row.className = "history-entry";

    const main = document.createElement("div");
    main.className = "history-entry-main";
    main.addEventListener("click", () => post(MSG.inbound.restore, { id: entry.id }));

    const name = document.createElement("div");
    name.className = "history-entry-title";
    name.textContent = entry.title;
    main.appendChild(name);

    const meta = document.createElement("div");
    meta.className = "history-entry-meta";
    meta.textContent = historyMeta(entry);
    main.appendChild(meta);

    const preview = document.createElement("div");
    preview.className = "history-entry-preview";
    preview.textContent = entry.preview;
    main.appendChild(preview);
    row.appendChild(main);

    const del = document.createElement("button");
    del.className = "history-delete";
    del.textContent = "Delete";
    del.addEventListener("click", () => post(MSG.inbound.deleteHistory, { id: entry.id }));
    row.appendChild(del);
    historyEl.appendChild(row);
  }
}

function historyMeta(entry) {
  const closed = new Date(entry.closedAt);
  const closedText = Number.isFinite(closed.valueOf()) ? closed.toLocaleString() : "closed";
  if (!entry.expiresAt) return `${closedText} - kept indefinitely`;
  const expires = new Date(entry.expiresAt);
  if (!Number.isFinite(expires.valueOf())) return closedText;
  const ms = expires.valueOf() - Date.now();
  if (ms <= 0) return `${closedText} - expiring soon`;
  const hours = Math.ceil(ms / 3600000);
  return `${closedText} - ${hours}h left`;
}

// The per-note thumbnail strip pinned at the bottom of the editor area. Hidden when the active note has
// no attachments (the editor flexes to fill); the copy-assets button mirrors the same visibility.
export function renderTray() {
  const items = state.showingHistory ? [] : activeAttachments();
  const has = items.length > 0;
  trayEl.hidden = !has;
  copyAssetsButton.hidden = !has;
  document.body.classList.toggle("tray-mode", has);
  trayEl.innerHTML = "";
  if (!has) return;
  const noteId = state.activeId;
  for (const item of items) {
    const thumb = document.createElement("div");
    thumb.className = "attachment-thumb";
    const name = item.name || "attachment";
    const kind = item.kind === "video" ? "video" : "image";
    thumb.title = `Open ${name}`;
    thumb.setAttribute("aria-label", `Open ${kind} asset ${name}`);

    if (item.thumb) {
      const img = document.createElement("img");
      img.className = "attachment-image";
      img.src = item.thumb;
      img.alt = name;
      img.draggable = false;
      thumb.appendChild(img);
    } else {
      const tile = document.createElement("div");
      tile.className = `attachment-file-tile ${kind}`;
      const icon = document.createElement("div");
      icon.className = "attachment-file-icon";
      icon.textContent = kind === "video" ? "VIDEO" : "IMAGE";
      const label = document.createElement("div");
      label.className = "attachment-file-name";
      label.textContent = name;
      tile.appendChild(icon);
      tile.appendChild(label);
      thumb.appendChild(tile);
    }

    const remove = document.createElement("button");
    remove.className = "attachment-remove";
    remove.type = "button";
    remove.textContent = "x";
    remove.title = "Remove attachment";
    remove.addEventListener("click", (event) => {
      event.stopPropagation();
      post(MSG.inbound.removeAttachment, { noteId, attachmentId: item.id });
    });
    thumb.appendChild(remove);

    // Right-click opens the inline rename; left-click opens the asset (suppressed while this thumb is being
    // renamed so a stray click doesn't launch the file mid-edit).
    thumb.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      actions().beginAttachmentRename(item.id);
    });
    if (item.id === state.editingAttachmentId) {
      thumb.appendChild(makeAttachmentNameEditor(noteId, item));
    } else {
      thumb.addEventListener("click", () => {
        post(MSG.inbound.openAttachment, { noteId, attachmentId: item.id });
      });
    }
    trayEl.appendChild(thumb);
  }
}

// Drop affordance: Swift signals drag-enter/exit of an attachable drag; render a highlight overlay.
export function setDropActive(active) {
  dropOverlayEl.hidden = !active;
  document.body.classList.toggle("drop-active", active);
}

// Mini view (notes-miniview A2): Swift pushes the window's effective-mini boolean. Mini hides the tab strip,
// the button row, and the hamburger (all CSS-driven off body.mini-mode), leaving only the active note's editor
// edge-to-edge — still fully editable, still the dictation target. Swift owns the decision (manual toggle OR
// content width < 560) and pushes only on change; JS just reflects the flag onto body.mini-mode.
export function applyMini(enabled) {
  document.body.classList.toggle("mini-mode", !!enabled);
}

// Mini view hover (notes-miniview A3): the hover overlay is the ONLY chrome in mini, and only while the pointer
// is over the window. `body.mini-hover` is the hover latch; the CSS reveals #mini-overlay (and any open cheat
// sheet) only when both mini-mode and mini-hover are set, so this class is harmless in full view. L8 hangs the
// tab strip off this same latch, so the reveal stays one lifecycle rather than two competing ones.
let miniHoverLatched = false;
export function setMiniHover(active) {
  const on = !!active;
  document.body.classList.toggle("mini-hover", on);
  // L8: in mini the strip is display:none off-hover, so renderTabs' scroll-active-into-view was a no-op and the
  // active tab can be parked outside the visible band the instant the strip appears. Re-run it on the RISING
  // edge only — every mousemove calls this, and re-scrolling on each one would fight a manual scroll of the
  // strip. Gated on mini-mode so a pointer entering a FULL-view window never yanks its strip either.
  if (on && !miniHoverLatched && document.body.classList.contains("mini-mode")) scrollActiveTabIntoView();
  // L12: same rising edge, same reason. Off-hover the mini strip is display:none, so it measures 0 wide and
  // reads as "no overflow"; the clip state is only knowable once the band is on screen. The ResizeObserver
  // catches this too, but it lands a frame later, and this is the frame the band appears in.
  if (on !== miniHoverLatched) updateTabStripClip();
  miniHoverLatched = on;
}

// Swift owns whether the floating "i" button exists at all. OFF removes the button and hides any open
// cheat sheet; the button's per-mode CSS still hides it in history/blank views when it does exist.
export function applyCheatSheetButton() {
  infoButton.hidden = !state.cheatSheetButton;
  // Mini view (A3): the overlay's "i" button is CSS-gated on this class, so it appears only when the cheat-sheet
  // setting is enabled — the same condition that shows the full-view floating "i" button.
  document.body.classList.toggle("cheatsheet-enabled", state.cheatSheetButton);
  if (!state.cheatSheetButton) hideCheatSheet();
}

// Keep the strip controls showing the current values (called on render + on a settings push).
export function renderSettingsStrip() {
  if (cheatSheetToggle) cheatSheetToggle.checked = state.cheatSheetButton;
  if (retentionSelect) retentionSelect.value = state.retention;
}

export function render() {
  renderTabs();
  renderHistory();
  renderTray();
  renderSettingsStrip();
  document.body.classList.toggle("history-mode", state.showingHistory);
  document.body.classList.toggle("blank-mode", !state.showingHistory && state.tabs.length === 0);
}

export function showToast(message) {
  toastEl.textContent = message;
  toastEl.classList.add("show");
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toastEl.classList.remove("show"), 1400);
}

export function hideCheatSheet() {
  cheatSheetEl.hidden = true;
}

export function handleTabMenuAction(action, id, skillId = null) {
  const handler = actions();
  if (action === "rename") handler.beginInlineRename(id);
  if (action === "selectAll") handler.selectAllInTab(id);
  if (action === "duplicate") handler.duplicateTab(id);
  if (action === "stickySkill") {
    if (skillId) handler.noteToHandoff(id, skillId);
  }
  if (action === "copy") handler.copyTab(id);
  if (action === "saveAs") handler.saveAs(id);
  if (action === "openInFinder") handler.openInFinder(id);
  if (action === "close") handler.closeTab(id);
}

// Swift -> JS: refresh the bottom Sticky Skills section from the menu-safe projection. The header,
// separator, button elements and empty-catalog behavior all stay here in the web island.
export function receiveStickySkills(payload) {
  renderStickySkillMenu(payload, {
    section: stickySkillsMenuSection,
    separator: stickySkillsMenuSeparator,
    items: stickySkillsMenuItems,
  });
}
