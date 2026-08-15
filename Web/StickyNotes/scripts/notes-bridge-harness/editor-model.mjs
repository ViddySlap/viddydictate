// A FAITHFUL, DOM-free stand-in for editor.js, used only by the headless bridge harness (the loader hook in
// hooks.mjs redirects every `./editor.js` import to this module). It re-implements the exact editor.js contract
// the real actions.js + persistence.js depend on — a plain `{doc, anchor, head}` model with the SAME
// selection / collapse / insert / slice semantics CodeMirror gives them:
//
//   * currentSelection()        -> {from: min(anchor,head), to: max(anchor,head)}
//   * collapseEditorSelection() -> collapse to `head` (matches CM's dispatch({selection:{anchor: main.head}}))
//   * setEditorSelection(f,t)   -> re-select [f,t] (the BUG 2 restore-on-teardown primitive)
//   * insertAtRange(f,t,ins)    -> replace [f,t] with `ins`, applying the shared separator only at a bare caret
//
// The bug the harness catches lives in the STORE + the actions.js control flow (the collapsed-selection re-read
// clobbering the live range), NOT in CodeMirror itself, so a faithful position model reproduces it exactly while
// staying deterministic and browser-free. `__model` is the harness's window into the state for assertions.
//
// `replaceEditorDoc` below is a position model only, NOT a model of the real one's contract: the shipping
// replaceEditorDoc swaps the whole EditorState (per-note undo isolation) and therefore notifies the doc-changed
// and swap handlers itself. This harness registers neither handler, so there is nothing here to mirror. The
// proof for that seam is scripts/check-undo-isolation.mjs.

import {
  needsLeadingSeparator,
  stripLeadingInlineWhitespace,
} from "../../src/dictation-separator.js";
import { appendRange } from "../../src/sticky-skill-append.js";

const model = {
  doc: "",
  anchor: 0,
  head: 0,
  lastTint: null, // { from, to, cls } | null — the effective (non-empty) replace-highlight, mirroring the field
  lastScroll: null, // the position the BT6 reveal last scrolled into view, or null
  pulses: 0, // how many times the BT6 one-shot marker cue has been played (see pulseBullseyeMarker)
};

function clamp(pos) {
  return Math.max(0, Math.min(pos, model.doc.length));
}

// --- the editor.js interface the real bridge modules import ------------------------------------------------

export function currentSelection() {
  return { from: Math.min(model.anchor, model.head), to: Math.max(model.anchor, model.head) };
}

export function collapseEditorSelection() {
  if (model.anchor === model.head) return;
  model.anchor = model.head; // collapse to head, exactly like editor.js
}

export function setEditorSelection(from, to) {
  model.anchor = clamp(from);
  model.head = clamp(to);
}

export function insertAtRange(from, to, insert) {
  const f = clamp(from);
  const t = Math.max(f, clamp(to));
  if (f === t) {
    insert = stripLeadingInlineWhitespace(insert);
    const precedingChar = f === 0 ? "" : model.doc.slice(f - 1, f);
    if (needsLeadingSeparator(precedingChar, insert)) insert = ` ${insert}`;
  }
  model.doc = model.doc.slice(0, f) + insert + model.doc.slice(t);
  model.anchor = model.head = f + insert.length;
  return model.doc;
}

// The Sticky Skill append primitive (S2). Faithful to the real editor.js in the two ways that matter: it uses
// the SAME pure appendRange rule, and its transaction specifies NO selection, so the caret is only MAPPED
// through the change rather than moved to the end. CodeMirror maps a position at or before the change start to
// itself and collapses a position inside the replaced range to that start (assoc -1); the replaced range here
// is only the document's trailing whitespace, so in practice a caret anywhere in the user's text stays put.
export function appendToEditorEnd(insert) {
  const range = appendRange(model.doc, insert);
  model.doc = model.doc.slice(0, range.from) + range.insert + model.doc.slice(range.to);
  const mapped = (pos) => (pos <= range.from ? pos : range.from);
  model.anchor = mapped(model.anchor);
  model.head = mapped(model.head);
  return model.doc;
}

export function insertIntoEditor(insert) {
  const f = Math.min(model.anchor, model.head);
  const t = Math.max(model.anchor, model.head);
  return insertAtRange(f, t, insert);
}

export function editorSlice(from, to) {
  const f = clamp(from);
  const t = Math.max(f, clamp(to));
  return model.doc.slice(f, t);
}

export function setReplaceHighlightDeco(from, to, cls) {
  // The real replaceHighlightField renders a mark only for a non-empty range; mirror that so `lastTint` is the
  // tint the user would actually SEE (null for a bare caret — nothing to replace).
  model.lastTint = from < to ? { from, to, cls } : null;
}

export function clearReplaceHighlightDeco() {
  model.lastTint = null;
}

export function replaceEditorDoc(_noteId, body) {
  model.doc = body || "";
  model.anchor = model.head = 0;
}

export function forgetEditorState() {}
export function serializeEditorState() { return null; }

export function setEditorEditable() {}

export function currentEditorDoc() {
  return model.doc;
}

export function hasEditor() {
  return true;
}

export function selectAllEditor() {
  model.anchor = 0;
  model.head = model.doc.length;
}

export function focusEditor() {}
export function setBullseyeMarker() {}

// The BT6 one-shot attention cue. Purely visual in the real editor (an animation class on the marker widget's
// pseudo-element), so the only thing worth modelling is HOW OFTEN it fires: the cue belongs to the reveal alone,
// and an ordinary sync that played it would turn the glyph into a tic. Counted, never acted on.
export function pulseBullseyeMarker() {
  model.pulses += 1;
}

// The BT6 reveal primitive. Records where the reveal scrolled and asserts the real editor.js contract: it must
// NOT touch the doc or the selection, so a case can prove the reveal is read-only.
export function scrollPositionIntoView(pos) {
  model.lastScroll = clamp(pos);
  return true;
}

// --- the harness's view into the model --------------------------------------------------------------------

export const __model = {
  setDoc(s) {
    model.doc = s || "";
    model.anchor = model.head = 0;
  },
  setSelection(from, to) {
    model.anchor = from;
    model.head = to;
  },
  get doc() {
    return model.doc;
  },
  get selection() {
    return { from: Math.min(model.anchor, model.head), to: Math.max(model.anchor, model.head) };
  },
  get lastTint() {
    return model.lastTint;
  },
  get lastScroll() {
    return model.lastScroll;
  },
  clearScroll() {
    model.lastScroll = null;
  },
  get pulses() {
    return model.pulses;
  },
  clearPulses() {
    model.pulses = 0;
  },
};
