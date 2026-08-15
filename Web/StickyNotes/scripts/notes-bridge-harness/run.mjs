// Headless DOM-level real-path harness for the refine2 BUG 2 fix (Option+P over a sticky-note selection: no
// tint, insert-at-point instead of replace). It drives the ACTUAL shipping bridge — the real
// Web/StickyNotes/src/actions.js handlers (snapshotTarget / replaceHighlight / insertAtTarget) over the real
// dictation-target.js store — through the exact bug interleaving, with editor.js/render.js/drag-rail.js
// redirected to faithful headless stand-ins (see hooks.mjs). The pure-logic Swift probe cannot see this class
// (it never runs the JS collapse-then-re-read); this is the committed regression fixture that can.
//
//   THE SEQUENCE: set a real selection -> snapshotTarget (take-start) ->
//   replaceHighlight/collapse (the tint collapses the live selection) -> snapshotTarget re-read (now collapsed)
//   -> insertAtTarget. ASSERT the result REPLACES the original range (not insert-at-point) and the tint sat on a
//   non-empty range. Plus the generation-guard store semantics and the restore-selection-on-teardown fix.

import { ChangeSet } from "@codemirror/state";
import { clearPostedMessages, postedMessages } from "./globals.mjs";
import {
  handleEditorDocChanged,
  insertAtBullseye,
  insertAtTarget,
  insertText,
  noteToHandoff,
  replaceHighlight,
  replaceNoteDelivery,
  revealBullseye,
  setBullseye,
  snapshotTarget,
  undoNoteDelivery,
} from "../../src/actions.js";
import {
  externalAppend,
  externalClose,
  externalCreate,
  externalFocus,
  externalInsert,
  externalSetBody,
} from "../../src/external-control.js";
import {
  clearBullseye,
  clearLastDelivery,
  clearReplaceHighlight,
  clearSnapshot,
  getBullseye,
  getLastDelivery,
  getSnapshot,
  setSnapshot,
} from "../../src/dictation-target.js";
import { state } from "../../src/state.js";
import { renderStickySkillMenu } from "../../src/sticky-skill-menu.js";
import { __model } from "./editor-model.mjs";

let failures = 0;
function check(name, ok, detail = "") {
  if (!ok) failures += 1;
  console.log(`  [${ok ? "ok " : "FAIL"}] ${name}${detail ? ": " + detail : ""}`);
}

const ID = "note-1";
// "bravo" is the selected range: indices [6, 11) in "alpha bravo charlie".
const BODY = "alpha bravo charlie";
const SEL_FROM = 6;
const SEL_TO = 11;

function resetNote() {
  // Clear every transient store so each case starts clean (production tears these down per take).
  clearSnapshot(ID);
  clearReplaceHighlight();
  clearLastDelivery();
  state.tabs = [{ id: ID, body: BODY, title: "" }];
  state.activeId = ID;
  state.showingHistory = false;
  __model.setDoc(BODY);
  __model.setSelection(SEL_FROM, SEL_TO);
  clearPostedMessages();
}

console.log("--- notes bridge harness: refine2 BUG 2 real-path DOM check (Option+P over a note selection) ---\n");

// ===== Case 1: the full BUG 2 interleaving through the real actions.js handlers ============================
console.log("Case 1: replaceHighlight collapse -> snapshotTarget re-read must not clobber -> insertAtTarget replaces");
resetNote();
const GEN = 7;

// take-START: capture the live selection as the note-target snapshot.
snapshotTarget({ id: ID, generation: GEN });
const afterStart = getSnapshot(ID);
check("take-start snapshot is the live selection range", !!afterStart && afterStart.from === SEL_FROM && afterStart.to === SEL_TO,
  afterStart ? JSON.stringify(afterStart) : "null");

// the BT4 replace-highlight tint: renders from the snapshot AND collapses the live selection.
replaceHighlight({ id: ID, level: "cleanup", generation: GEN });
check("replace highlight tints a NON-EMPTY range (the selection shows, not an empty caret)",
  !!__model.lastTint && __model.lastTint.from < __model.lastTint.to,
  __model.lastTint ? JSON.stringify(__model.lastTint) : "null (no tint — the bug)");
check("the tint collapsed the live selection (reproducing the bug precondition)",
  __model.selection.from === __model.selection.to, JSON.stringify(__model.selection));

// the command chord's re-snapshot: re-reads the NOW-COLLAPSED selection. The guard must keep the good range.
snapshotTarget({ id: ID, generation: GEN });
const afterReread = getSnapshot(ID);
check("collapsed same-gesture re-read does NOT clobber the live range (generation guard)",
  !!afterReread && afterReread.from === SEL_FROM && afterReread.to === SEL_TO,
  afterReread ? JSON.stringify(afterReread) : "null");

// delivery: must REPLACE the original selection, not insert at the collapsed point.
insertAtTarget({ id: ID, text: "XX" });
check("insertAtTarget REPLACES the selected range (delivery lands over 'bravo')",
  __model.doc === "alpha XX charlie", JSON.stringify(__model.doc));
check("regression sentinel: delivery did NOT insert-at-point (the pre-fix bug output)",
  __model.doc !== "alpha bravoXX charlie", JSON.stringify(__model.doc));

// ===== Case 2: restore-selection-on-teardown (BUG 2 fix #3) ================================================
console.log("\nCase 2: tearing down the tint WITHOUT delivering restores the original selection");
resetNote();
const GEN2 = 8;
snapshotTarget({ id: ID, generation: GEN2 });
replaceHighlight({ id: ID, level: "raw", generation: GEN2 });
check("precondition: the tint collapsed the selection", __model.selection.from === __model.selection.to,
  JSON.stringify(__model.selection));
// teardown = a clear push (empty level), as discardIncidentalAudio / cancelTake issue.
replaceHighlight({ id: ID, level: "", generation: GEN2 });
check("teardown restored the ORIGINAL selection from the still-valid snapshot",
  __model.selection.from === SEL_FROM && __model.selection.to === SEL_TO, JSON.stringify(__model.selection));
check("teardown cleared the tint", __model.lastTint === null, JSON.stringify(__model.lastTint));

// ===== Case 3: generation-guard store semantics (fix #2, exercised directly on the real store) ============
console.log("\nCase 3: snapshot store generation guard");
clearSnapshot(ID);
setSnapshot(ID, 6, 11, 5);
check("first write for a note is accepted", snapEq(getSnapshot(ID), 6, 11, 5), dump());

setSnapshot(ID, 3, 3, 6); // NEWER gesture, bare caret
check("a NEWER-gesture bare-caret write WINS (a fresh take re-snapshots)", snapEq(getSnapshot(ID), 3, 3, 6), dump());

setSnapshot(ID, 100, 100, 4); // OLDER gesture
check("an OLDER-gesture write never wins", snapEq(getSnapshot(ID), 3, 3, 6), dump());

setSnapshot(ID, 8, 8, 6); // same gen, empty over empty
check("a same-gesture empty-over-empty write is accepted", snapEq(getSnapshot(ID), 8, 8, 6), dump());

setSnapshot(ID, 2, 9, 6); // same gen, non-empty over empty
check("a same-gesture non-empty update is accepted", snapEq(getSnapshot(ID), 2, 9, 6), dump());

setSnapshot(ID, 5, 5, 6); // same gen, empty over NON-empty -> the core guard
check("a same-gesture EMPTY write never clobbers a live non-empty range (THE guard)", snapEq(getSnapshot(ID), 2, 9, 6), dump());

// ===== Case 4: explicit retry restores the exact mapped note landing =====================================
console.log("\nCase 4: explicit retry replaces the raw fallback at the original note range");
resetNote();
snapshotTarget({ id: ID, generation: 9 });
insertAtTarget({ id: ID, text: "RAW" });
check("failed cleanup raw fallback replaced the selected range",
  __model.doc === "alpha RAW charlie", JSON.stringify(__model.doc));
replaceNoteDelivery({ id: ID, text: "CLEAN" });
const retryDelivery = getLastDelivery();
check("retry output replaces that exact delivery range instead of appending at current focus",
  __model.doc === "alpha CLEAN charlie", JSON.stringify(__model.doc));
check("retry replacement preserves the original overwritten text as the next undo source",
  !!retryDelivery && retryDelivery.from === SEL_FROM && retryDelivery.len === 5
    && retryDelivery.replaced === "bravo",
  retryDelivery ? JSON.stringify(retryDelivery) : "null");
undoNoteDelivery({ id: ID });
check("Option+Z after retry still restores the pre-failure selection",
  __model.doc === BODY, JSON.stringify(__model.doc));

// ===== Case 5: loopback external-control round-trips ====================================================
console.log("\nCase 5: external create/set-body/insert/focus/close preserve state and bridge round-trips");
resetNote();
const EXTERNAL_ID = "note-external";

externalCreate({ id: EXTERNAL_ID, body: "delta", title: "Created" });
check("externalCreate adds the exact note and makes its body active",
  state.tabs.length === 2 && state.activeId === EXTERNAL_ID && __model.doc === "delta"
    && state.tabs[1].id === EXTERNAL_ID && state.tabs[1].title === "Created",
  JSON.stringify({ tabs: state.tabs, activeId: state.activeId, doc: __model.doc }));
check("externalCreate round-trip saves the old tab then posts the new membership",
  messageTypesEqual("save", "active")
    && lastPostedMessage()?.activeId === EXTERNAL_ID
    && arraysEqual(lastPostedMessage()?.tabOrder, [ID, EXTERNAL_ID]),
  JSON.stringify(postedMessages()));

clearPostedMessages();
externalSetBody({ id: EXTERNAL_ID, body: "delta updated" });
check("externalSetBody replaces the stored and active editor body",
  state.tabs[1].body === "delta updated" && __model.doc === "delta updated",
  JSON.stringify({ tab: state.tabs[1], doc: __model.doc }));
check("externalSetBody round-trip posts the exact persisted body",
  messageTypesEqual("save") && lastPostedMessage()?.id === EXTERNAL_ID
    && lastPostedMessage()?.body === "delta updated",
  JSON.stringify(postedMessages()));

clearPostedMessages();
externalInsert({ id: ID, text: "XX " });
check("externalInsert activates the target and inserts through its live editor",
  state.activeId === ID && state.tabs[0].body === "XX " + BODY && __model.doc === "XX " + BODY,
  JSON.stringify({ tab: state.tabs[0], activeId: state.activeId, doc: __model.doc }));
check("externalInsert round-trip flushes, activates, then saves the target",
  messageTypesEqual("save", "active", "save")
    && lastPostedMessage()?.id === ID && lastPostedMessage()?.body === "XX " + BODY,
  JSON.stringify(postedMessages()));

clearPostedMessages();
externalFocus({ id: EXTERNAL_ID });
check("externalFocus activates the requested note and loads its body",
  state.activeId === EXTERNAL_ID && __model.doc === "delta updated",
  JSON.stringify({ activeId: state.activeId, doc: __model.doc }));
check("externalFocus round-trip flushes the old tab then posts active membership",
  messageTypesEqual("save", "active") && lastPostedMessage()?.activeId === EXTERNAL_ID,
  JSON.stringify(postedMessages()));

clearPostedMessages();
externalClose({ id: EXTERNAL_ID });
check("externalClose drops the active note and selects the remaining neighbor",
  state.tabs.length === 1 && state.tabs[0].id === ID && state.activeId === ID && __model.doc === "XX " + BODY,
  JSON.stringify({ tabs: state.tabs, activeId: state.activeId, doc: __model.doc }));
check("externalClose round-trip posts only the surviving membership",
  messageTypesEqual("active") && lastPostedMessage()?.activeId === ID
    && arraysEqual(lastPostedMessage()?.tabOrder, [ID]),
  JSON.stringify(postedMessages()));

// ===== Case 6: bare-caret dictation separator truth table (VDPF L2) =====================================
console.log("\nCase 6: bare-caret dictation inserts use exactly one contextual separator");

function resetCaretDoc(doc, anchor = doc.length, head = anchor) {
  clearLastDelivery();
  state.tabs = [{ id: ID, body: doc, title: "" }];
  state.activeId = ID;
  state.showingHistory = false;
  __model.setDoc(doc);
  __model.setSelection(anchor, head);
  clearPostedMessages();
}

const separatorCases = [
  ["position 0", "release", 0, "Thank you", "Thank yourelease"],
  ["whitespace preceded", "release ", 8, "Thank you", "release Thank you"],
  ["newline preceded", "release\n", 8, "Thank you", "release\nThank you"],
  ["mid-word alphanumeric preceded", "release", 7, "Thank you", "release Thank you"],
  ["provider-leading whitespace", "release", 7, " \t Thank you", "release Thank you"],
  ["provider-leading Unicode whitespace", "release", 7, "\u00a0Thank you", "release Thank you"],
  ["newline led", "release", 7, "\nThank you", "release\nThank you"],
];
for (const [name, doc, at, text, expected] of separatorCases) {
  resetCaretDoc(doc, at);
  insertText({ text });
  check(`separator ${name}`, __model.doc === expected, JSON.stringify(__model.doc));
}

for (const opening of ["(", "[", "{", "\u201c", "\u2018"]) {
  const doc = `release${opening}`;
  resetCaretDoc(doc);
  insertText({ text: "Thank you" });
  check(`separator opening delimiter ${JSON.stringify(opening)} attaches`,
    __model.doc === `${doc}Thank you`, JSON.stringify(__model.doc));
}

for (const punctuation of [",", ".", ";", ":", "!", "?", ")", "]", "}", "\u201d", "\u2019"]) {
  resetCaretDoc("release");
  insertText({ text: `${punctuation} next` });
  check(`separator attaching punctuation ${JSON.stringify(punctuation)} attaches`,
    __model.doc === `release${punctuation} next`, JSON.stringify(__model.doc));
}

resetCaretDoc("release", 0, 7);
insertText({ text: "Thank you" });
check("separator never applies to a range replacement",
  __model.doc === "Thank you", JSON.stringify(__model.doc));

resetCaretDoc("release");
insertText({ text: "Thank you" });
const separatedDelivery = getLastDelivery();
check("separator is included in the note-undo delivery range",
  separatedDelivery?.from === 7 && separatedDelivery?.len === 10,
  JSON.stringify(separatedDelivery));
undoNoteDelivery({ id: ID });
check("undo removes the inserted separator with the dictation",
  __model.doc === "release", JSON.stringify(__model.doc));

// ===== Case 7: live bullseye mapping + mid-paragraph dictation landing (L6) =============================
console.log("\nCase 7: bullseye maps through edits and dictation lands mid-paragraph");

function resetBullseyeDoc(doc = "LEFTRIGHT", anchor = 4) {
  clearBullseye();
  state.tabs = [{ id: ID, body: doc, title: "" }];
  state.activeId = ID;
  state.showingHistory = false;
  __model.setDoc(doc);
  __model.setSelection(anchor, anchor);
  clearPostedMessages();
  setBullseye({ id: ID });
}

function applyUserEdit(from, to, insert) {
  const before = __model.doc;
  const changes = ChangeSet.of({ from, to, insert }, before.length);
  const after = before.slice(0, from) + insert + before.slice(to);
  __model.setDoc(after);
  handleEditorDocChanged(after, changes);
}

const mapCases = [
  ["insert above", "LEFTRIGHT", 4, 0, 0, "TOP ", 8],
  ["delete above", "xxLEFTRIGHT", 6, 0, 2, "", 4],
  ["insert AT", "LEFTRIGHT", 4, 4, 4, "NEW", 4],
  ["delete spanning", "LEFTmiddleRIGHT", 7, 4, 10, "", 4],
  ["multi-line paste above", "LEFTRIGHT", 4, 0, 0, "one\ntwo\n", 12],
  ["insert after", "LEFTRIGHT", 4, 9, 9, " tail", 4],
  ["delete after", "LEFTRIGHTxx", 4, 9, 11, "", 4],
];
for (const [name, doc, anchor, from, to, insert, expected] of mapCases) {
  resetBullseyeDoc(doc, anchor);
  applyUserEdit(from, to, insert);
  check(`bullseye ${name} maps to ${expected}`,
    getBullseye()?.anchor === expected, JSON.stringify(getBullseye()));
}

resetBullseyeDoc("LEFTRIGHT", 4);
insertAtBullseye({ id: ID, text: "DICTATED" });
check("dictation lands at the bullseye MID-PARAGRAPH rather than appending",
  __model.doc === "LEFT DICTATEDRIGHT", JSON.stringify(__model.doc));
check("dictation advances the bullseye to the end of its inserted text, still before RIGHT",
  getBullseye()?.anchor === 13 && __model.doc.slice(getBullseye().anchor) === "RIGHT",
  JSON.stringify(getBullseye()));

resetBullseyeDoc("release", 7);
insertAtBullseye({ id: ID, text: "Thank you" });
insertAtBullseye({ id: ID, text: "again" });
const consecutiveDelivery = getLastDelivery();
check("successive bullseye takes stay separated and advance past each real insertion",
  __model.doc === "release Thank you again" && getBullseye()?.anchor === 23,
  JSON.stringify({ doc: __model.doc, bullseye: getBullseye() }));
check("the latest bullseye undo range includes its generated separator",
  consecutiveDelivery?.from === 17 && consecutiveDelivery?.len === 6,
  JSON.stringify(consecutiveDelivery));
undoNoteDelivery({ id: ID });
check("bullseye undo removes the latest take and its separator exactly",
  __model.doc === "release Thank you", JSON.stringify(__model.doc));

// ===== Case 8: Option+Shift+N reveal scrolls to the live anchor without editing anything (L7) ============
console.log("\nCase 8: bullseye reveal navigates to the mapped anchor and changes nothing else");

// A long doc so the anchor is genuinely off-screen territory, and a mid-paragraph bullseye so a reveal that
// merely scrolled to the end of the note would fail rather than pass by luck.
const LONG = "alpha\n" + "filler line\n".repeat(40) + "LEFTRIGHT\n" + "tail line\n".repeat(40);
const MID = LONG.indexOf("LEFTRIGHT") + 4;
resetBullseyeDoc(LONG, MID);

// The one-shot attention cue (VDPF L7) belongs to the reveal ALONE. Everything above this line is an ordinary
// path — arming the bullseye, two deliveries, seven anchor-mapping edits, an undo — and every one of them ran
// syncBullseyeMarker. If the cue could ride along on an ordinary marker rebuild, the counter is already dirty
// before the first reveal, which is the failure this measures rather than infers.
check("no ordinary path (arm, deliver, edit, undo) plays the marker cue",
  __model.pulses === 0, `${__model.pulses} pulse(s) before the first reveal`);

__model.clearScroll();
__model.clearPulses();
const docBeforeReveal = __model.doc;
const selectionBeforeReveal = __model.selection;

revealBullseye({ id: ID });
check("reveal scrolls to the bullseye anchor, not the note end",
  __model.lastScroll === MID, `${__model.lastScroll} (expected ${MID}, doc end ${LONG.length})`);
check("reveal plays the marker cue exactly once", __model.pulses === 1, `${__model.pulses}`);
check("reveal does not edit the document", __model.doc === docBeforeReveal);
check("reveal does not move the selection",
  __model.selection.from === selectionBeforeReveal.from && __model.selection.to === selectionBeforeReveal.to,
  JSON.stringify(__model.selection));
check("reveal does not move the bullseye", getBullseye()?.anchor === MID, JSON.stringify(getBullseye()));

// The anchor follows edits, so a reveal AFTER an edit above it must land on the mapped position, not the
// original offset — the same "behaves like a character in the paragraph" contract L6 fixed for the marker.
applyUserEdit(0, 0, "PREFIX ");
__model.clearScroll();
revealBullseye({ id: ID });
check("reveal follows the anchor through an edit above it",
  __model.lastScroll === MID + 7, `${__model.lastScroll} (expected ${MID + 7})`);

// Reveal from ANOTHER tab must bring the bullseye's note live first, then scroll.
const OTHER = "note-other";
state.tabs.push({ id: OTHER, body: "somewhere else", title: "" });
state.activeId = OTHER;
__model.setDoc("somewhere else");
__model.clearScroll();
revealBullseye({ id: ID });
check("reveal from another tab activates the bullseye's note first",
  state.activeId === ID && __model.doc.startsWith("PREFIX alpha"),
  JSON.stringify({ activeId: state.activeId, head: __model.doc.slice(0, 20) }));
check("reveal from another tab still scrolls to the anchor", __model.lastScroll === MID + 7,
  `${__model.lastScroll}`);

// Reveal for a note this island does not hold is a no-op, not a throw or a stray scroll.
__model.clearScroll();
__model.clearPulses();
revealBullseye({ id: "note-not-here" });
check("reveal for an unknown note is a silent no-op", __model.lastScroll === null, `${__model.lastScroll}`);
check("a no-op reveal plays no marker cue either", __model.pulses === 0, `${__model.pulses}`);

// And a delivery AFTER a reveal still does not pulse — the cue is bound to the reveal handler, not to a
// "recently revealed" mode that later syncs could inherit.
resetBullseyeDoc("LEFTRIGHT", 4);
revealBullseye({ id: ID });
__model.clearPulses();
insertAtBullseye({ id: ID, text: "DICTATED" });
applyUserEdit(0, 0, "TOP ");
check("a delivery and an edit after a reveal do not replay the cue", __model.pulses === 0, `${__model.pulses}`);

// ===== Case 9: tab-menu Note to Handoff snapshots the whole note without mutating it (L10) ===============
console.log("\nCase 9: Note to Handoff posts the selected tab's current whole-note snapshot");
state.tabs = [{ id: ID, body: "stale body", title: "Source title" }];
state.activeId = ID;
state.showingHistory = false;
state.attachmentsByNote[ID] = [{ id: "01-proof.mov", name: "proof.mov", kind: "video", thumb: "" }];
__model.setDoc("current whole note body");
clearPostedMessages();
noteToHandoff(ID);
check("Note to Handoff posts one dedicated bridge message with id/title/current body",
  messageTypesEqual("noteToHandoff")
    && lastPostedMessage()?.id === ID
    && lastPostedMessage()?.title === "Source title"
    && lastPostedMessage()?.body === "current whole note body",
  JSON.stringify(postedMessages()));
check("Note to Handoff leaves the source tab in place and unmodified",
  state.tabs.length === 1 && state.tabs[0].id === ID && state.tabs[0].body === "current whole note body",
  JSON.stringify(state.tabs));

state.tabs[0].body = "";
delete state.attachmentsByNote[ID];
__model.setDoc("");
clearPostedMessages();
noteToHandoff(ID);
check("Note to Handoff refuses an empty attachment-free note without posting",
  postedMessages().length === 0, JSON.stringify(postedMessages()));

// ===== Case 10: the Sticky Skill append landing (S2) — the dangerous one, on the real path ===============
console.log("\nCase 10: externalAppend lands at the live document end without moving the caret or losing text");
const APPEND_NOTE = "note-append";
const TYPED = "alpha bravo charlie";
function resetAppend(body = TYPED, caret = 5) {
  state.tabs = [{ id: APPEND_NOTE, body, title: "Source" }];
  state.activeId = APPEND_NOTE;
  state.showingHistory = false;
  __model.setDoc(body);
  __model.setSelection(caret, caret);
  clearPostedMessages();
}

// The LOST UPDATE this landing exists to prevent: the tab's stored body is STALE (the 180 ms save debounce has
// not fired) while the live document already holds what the user typed. Swift only ever sends the addition, so
// the append must be computed against the LIVE document and must not resurrect the stale body.
resetAppend();
state.tabs[0].body = "stale body";
externalAppend({ id: APPEND_NOTE, text: "## Handoff\nresult" });
check("append lands on the LIVE document, not the tab's stale stored body",
  __model.doc === `${TYPED}\n\n## Handoff\nresult`, JSON.stringify(__model.doc));
check("append re-persists the exact resulting body through the ordinary save round-trip",
  messageTypesEqual("save") && lastPostedMessage()?.id === APPEND_NOTE
    && lastPostedMessage()?.body === __model.doc
    && state.tabs[0].body === __model.doc,
  JSON.stringify(postedMessages()));
check("append does not move the user's caret out from under them",
  __model.selection.from === 5 && __model.selection.to === 5, JSON.stringify(__model.selection));

// The join rule, on the real path: exactly one blank line, and repeated appends never accumulate more.
resetAppend("body\n\n\n  ", 4);
externalAppend({ id: APPEND_NOTE, text: "one" });
externalAppend({ id: APPEND_NOTE, text: "two" });
check("append absorbs existing trailing whitespace and never stacks blank lines",
  __model.doc === "body\n\none\n\ntwo", JSON.stringify(__model.doc));

resetAppend("", 0);
externalAppend({ id: APPEND_NOTE, text: "first" });
check("appending to an empty note yields just the addition", __model.doc === "first", JSON.stringify(__model.doc));

// Reaching a note that is not the active tab: the swap flushes the outgoing tab first, so nothing is lost.
resetAppend();
const OTHER_TAB = "note-other-append";
state.tabs.push({ id: OTHER_TAB, body: "second note", title: "" });
state.activeId = OTHER_TAB;
__model.setDoc("second note");
clearPostedMessages();
externalAppend({ id: APPEND_NOTE, text: "landed" });
check("append reaches a non-active note by bringing it live first",
  state.activeId === APPEND_NOTE && __model.doc === `${TYPED}\n\nlanded`
    && state.tabs.find((tab) => tab.id === OTHER_TAB)?.body === "second note",
  JSON.stringify({ activeId: state.activeId, doc: __model.doc }));

// Refusals: a read-only tab and a note this island does not hold must change nothing and post nothing.
resetAppend();
state.tabs[0].canEdit = false;
externalAppend({ id: APPEND_NOTE, text: "nope" });
check("append refuses a read-only note and leaves the document untouched",
  __model.doc === TYPED && postedMessages().every((message) => message.type !== "save"),
  JSON.stringify({ doc: __model.doc, posted: postedMessages() }));

resetAppend();
externalAppend({ id: "note-not-here", text: "nope" });
externalAppend({ id: APPEND_NOTE, text: "" });
check("append for an unknown note, or with empty text, is a silent no-op",
  __model.doc === TYPED && postedMessages().length === 0,
  JSON.stringify({ doc: __model.doc, posted: postedMessages() }));

// ===== Case 11: Sticky Skills catalog/menu ownership + selected-id dispatch (S5) =========================
console.log("\nCase 11: Sticky Skills menu renders only the native catalog projection and dispatches its id");

class FakeMenuElement {
  constructor(ownerDocument, tagName = "div") {
    this.ownerDocument = ownerDocument;
    this.tagName = tagName;
    this.hidden = false;
    this.children = [];
    this.dataset = {};
    this.textContent = "";
    this.title = "";
    this.type = "";
  }
  replaceChildren() { this.children = []; }
  appendChild(child) { this.children.push(child); return child; }
}

function menuFixture() {
  const ownerDocument = {
    createElement(tagName) { return new FakeMenuElement(ownerDocument, tagName); },
  };
  return {
    section: new FakeMenuElement(ownerDocument),
    separator: new FakeMenuElement(ownerDocument),
    items: new FakeMenuElement(ownerDocument),
  };
}

const menu = menuFixture();
renderStickySkillMenu({ items: [] }, menu);
check("an empty catalog hides both the section and its separator",
  menu.section.hidden && menu.separator.hidden && menu.items.children.length === 0,
  JSON.stringify({ section: menu.section.hidden, separator: menu.separator.hidden }));

renderStickySkillMenu({ items: [{ id: "built-in", displayName: "Note to Handoff" }] }, menu);
check("zero custom skills renders exactly the built-in under one visible section",
  !menu.section.hidden && !menu.separator.hidden && menu.items.children.length === 1
    && menu.items.children[0].textContent === "Note to Handoff",
  JSON.stringify(menu.items.children));

renderStickySkillMenu({ items: [
  { id: "built-in", displayName: "Note to Handoff", prompt: "must stay native" },
  { id: "custom-1", displayName: " File this note ", route: "must stay native" },
  { id: "custom-1", displayName: "duplicate" },
  { id: "", displayName: "invalid" },
] }, menu);
check("catalog order is stable and invalid or duplicate ids do not mint extra actions",
  menu.items.children.length === 2
    && menu.items.children.map((button) => button.dataset.skillId).join(",") === "built-in,custom-1"
    && menu.items.children[1].textContent === "File this note",
  JSON.stringify(menu.items.children));
check("a rendered skill button carries only its action id while text uses textContent",
  Object.keys(menu.items.children[1].dataset).sort().join(",") === "action,skillId"
    && menu.items.children[1].dataset.action === "stickySkill"
    && menu.items.children[1].prompt === undefined && menu.items.children[1].route === undefined,
  JSON.stringify(menu.items.children[1]));

resetNote();
noteToHandoff(ID, "custom-1");
check("the selected skill id reaches Swift beside the current whole-note snapshot",
  messageTypesEqual("noteToHandoff")
    && lastPostedMessage()?.skillId === "custom-1"
    && lastPostedMessage()?.id === ID && lastPostedMessage()?.body === BODY,
  JSON.stringify(postedMessages()));

function snapEq(snap, from, to, generation) {
  return !!snap && snap.from === from && snap.to === to && snap.generation === generation;
}
function dump() {
  const s = getSnapshot(ID);
  return s ? JSON.stringify(s) : "null";
}
function messageTypesEqual(...types) {
  return arraysEqual(postedMessages().map((message) => message.type), types);
}
function lastPostedMessage() {
  return postedMessages().at(-1);
}
function arraysEqual(lhs, rhs) {
  return Array.isArray(lhs) && Array.isArray(rhs)
    && lhs.length === rhs.length && lhs.every((value, index) => value === rhs[index]);
}

console.log("");
if (failures > 0) {
  console.error(`[notes-bridge-harness] FAIL — ${failures} assertion(s) failed`);
  process.exit(1);
}
console.log("[notes-bridge-harness] OK - DOM landing, bullseye mapping, and external-control harness green");
