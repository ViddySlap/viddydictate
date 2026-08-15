import { ChangeSet, Compartment, EditorState, StateEffect, StateField } from "@codemirror/state";
import { EditorView, keymap, Decoration, ViewPlugin, WidgetType, drawSelection } from "@codemirror/view";
import { defaultKeymap, history, historyField, historyKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxTree } from "@codemirror/language";

import { editorEl } from "./dom.js";
import { needsLeadingSeparator, stripLeadingInlineWhitespace } from "./dictation-separator.js";
import { appendRange } from "./sticky-skill-append.js";

let editor = null;
let onDocChanged = () => {};
let onEditorSwap = () => {};
const editableCompartment = new Compartment();
const noteEditorStates = new Map();
let editorNoteId = null;

// Mirrors the editable compartment's live value. A note swap replaces the whole EditorState (see
// replaceEditorDoc), and `setState` reinitialises EVERY compartment from its declared value — which would
// silently hand a read-only file-backed tab back as editable for the instant before the caller re-applies it.
// Seeding the new state from this instead keeps read-only read-only across the swap with no window at all.
let editorEditable = true;

// --- Inline armed-bullseye marker (notes-bullseye BT3) --------------------------------------------
// A zero-width CodeMirror widget rendering a bullseye glyph inline at the armed bullseye's anchor. Shown
// ONLY while the bullseye is armed AND its note is the note in the editor (the caller — syncBullseyeMarker —
// gates that and passes the anchor, or null to hide). The TRANSIENT snapshot never gets a marker. The field
// owns a CodeMirror-mapped anchor so it follows edits exactly as the JS bullseye store does (assoc -1), and
// rebuilds the zero-width widget after every document change. Rebuilding is intentional: the glyph is an
// absolutely-positioned pseudo-element, and reusing one eq()-stable DOM node leaves it frozen at its old pixel
// coordinate while text moves underneath it. Discontinuous moves (a delivery advance, a tab swap, arm/disarm)
// are re-pushed via setBullseyeMarker.
const setBullseyeMarkerEffect = StateEffect.define(); // value: number (anchor) | null (hide)

// One-shot attention cue on the marker that is ALREADY shown (notes-bullseye BT6, the Option+Shift+N reveal):
// the glyph arrives oversized and springs down to its resting size, so the eye is told where in the note the
// bullseye sits. Carries no value — it neither moves nor shows the marker, it only asks the next rebuild of the
// widget to come up wearing the animation class. Deliberately NOT sent by any ordinary sync: a marker that
// pulsed on every dictation delivery would be noise rather than a cue.
const pulseBullseyeMarkerEffect = StateEffect.define(); // value: none

// Slightly longer than the CSS animation (`.cm-bullseye-pulse::after`, 560ms), so the flag is cleared from the
// field AFTER the animation has finished rather than cutting it short. See pulseBullseyeMarker.
const BULLSEYE_PULSE_CLEAR_MS = 700;
let bullseyePulseClearTimer = null;

class BullseyeMarkerWidget extends WidgetType {
  constructor(pulse = false) {
    super();
    this.pulse = pulse === true;
  }
  toDOM() {
    const span = document.createElement("span");
    span.className = this.pulse ? "cm-bullseye-marker cm-bullseye-pulse" : "cm-bullseye-marker";
    span.setAttribute("aria-hidden", "true");
    return span;
  }
  ignoreEvent() { return true; }
}

function clampPos(pos, len) {
  return Math.max(0, Math.min(pos, len));
}

function makeBullseyeMarkerState(anchor, docLength, pulse = false) {
  const mappedAnchor = anchor == null ? null : clampPos(anchor, docLength);
  const decorations = mappedAnchor == null
    ? Decoration.none
    : Decoration.set([
        Decoration.widget({ widget: new BullseyeMarkerWidget(pulse), side: -1 }).range(mappedAnchor),
      ]);
  return { anchor: mappedAnchor, decorations };
}

const bullseyeMarkerField = StateField.define({
  create() { return makeBullseyeMarkerState(null, 0); },
  update(marker, tr) {
    let anchor = marker.anchor;
    let rebuild = tr.docChanged;
    // Declared inside update() and never read off `marker`, so it is false for EVERY transaction that does not
    // itself carry the pulse effect. A pulse can therefore never ride along on an unrelated marker rebuild — a
    // doc edit, a delivery advance or a tab swap re-creates the widget in its resting state.
    let pulse = false;
    if (anchor != null && tr.docChanged) anchor = tr.changes.mapPos(anchor, -1);
    for (const effect of tr.effects) {
      if (effect.is(setBullseyeMarkerEffect)) {
        anchor = effect.value;
        rebuild = true;
      }
      if (effect.is(pulseBullseyeMarkerEffect)) {
        pulse = true;
        rebuild = true;
      }
    }
    return rebuild ? makeBullseyeMarkerState(anchor, tr.state.doc.length, pulse) : marker;
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
});

// Show the inline bullseye marker at `pos`, or hide it when `pos` is null (notes-bullseye BT3). Idempotent
// against a missing editor; the effect-only transaction never scrolls or moves the selection.
export function setBullseyeMarker(pos) {
  if (!editor) return;
  editor.dispatch({ effects: setBullseyeMarkerEffect.of(pos == null ? null : pos) });
}

// Play the one-shot reveal cue on the marker (notes-bullseye BT6). Read-only: no edit, no anchor move, no
// selection change — the effect only asks the widget to be re-created wearing the animation class, and the
// glyph is an absolutely-positioned pseudo-element animated purely in transform/opacity, so nothing reflows.
// No-op when this island shows no marker (the bullseye is unarmed, or armed in a different note), which is the
// same gate syncBullseyeMarker applies.
//
// The follow-up timer is what makes this genuinely ONE-shot. CodeMirror only builds widget DOM for lines inside
// its viewport and re-runs toDOM() when a line scrolls back in, so a pulse flag left sitting in the field would
// replay the animation every time the marker re-entered view. Clearing it after the animation has run costs one
// rebuild of a zero-width widget — which is what every doc edit already does — and is invisible.
export function pulseBullseyeMarker() {
  if (!editor) return;
  if (editor.state.field(bullseyeMarkerField).anchor == null) return;
  editor.dispatch({ effects: pulseBullseyeMarkerEffect.of(null) });
  if (bullseyePulseClearTimer != null) clearTimeout(bullseyePulseClearTimer);
  bullseyePulseClearTimer = setTimeout(() => {
    bullseyePulseClearTimer = null;
    if (!editor) return;
    // Re-push the LIVE anchor rather than the one the pulse was played at: the bullseye may have advanced or
    // been disarmed in the meantime, and this must not resurrect or move anything.
    editor.dispatch({ effects: setBullseyeMarkerEffect.of(editor.state.field(bullseyeMarkerField).anchor) });
  }, BULLSEYE_PULSE_CLEAR_MS);
}

// Scroll `pos` into view WITHOUT editing the document or moving the selection (notes-bullseye BT6, the
// Option+Shift+N reveal). Centred vertically so the bullseye lands where the eye already is rather than
// scraping the top or bottom edge. Clamped to the doc; returns false when there is no editor, so the caller can
// report an honest failure instead of a silent no-op.
export function scrollPositionIntoView(pos) {
  if (!editor) return false;
  const at = clampPos(pos, editor.state.doc.length);
  editor.dispatch({ effects: EditorView.scrollIntoView(at, { y: "center" }) });
  return true;
}

// --- Four-color replace highlight (notes-bullseye BT4) --------------------------------------------
// A CodeMirror `mark` decoration tinting the note range a pending level-based operation will REPLACE, in one
// of four colors keyed to Raw / Cleanup / Tighten / Summarize (the CSS class `cm-replace-<level>`). The caller
// (syncReplaceHighlight) owns WHICH range + level and WHEN it shows/clears; this field just renders the range
// and maps it through edits (so typing above the range shifts the tint with it), matching how the JS-side
// range follows edits. Level changes swap the class while keeping the range; null clears it. Non-empty ranges
// only — a bare caret has nothing to replace.
const setReplaceHighlightEffect = StateEffect.define(); // value: { from, to, cls } | null (hide)

const replaceHighlightField = StateField.define({
  create() { return Decoration.none; },
  update(deco, tr) {
    deco = deco.map(tr.changes);
    for (const effect of tr.effects) {
      if (effect.is(setReplaceHighlightEffect)) {
        const v = effect.value;
        if (v == null) {
          deco = Decoration.none;
        } else {
          const len = tr.state.doc.length;
          const from = clampPos(v.from, len);
          const to = clampPos(v.to, len);
          deco = from < to
            ? Decoration.set([Decoration.mark({ class: v.cls }).range(from, to)])
            : Decoration.none;
        }
      }
    }
    return deco;
  },
  provide: (field) => EditorView.decorations.from(field),
});

// Tint [from, to] with the level class `cls` (notes-bullseye BT4), or clear via `clearReplaceHighlightDeco`.
// Idempotent against a missing editor; the effect-only transaction never scrolls or moves the selection.
export function setReplaceHighlightDeco(from, to, cls) {
  if (!editor) return;
  editor.dispatch({ effects: setReplaceHighlightEffect.of({ from, to, cls }) });
}

export function clearReplaceHighlightDeco() {
  if (!editor) return;
  editor.dispatch({ effects: setReplaceHighlightEffect.of(null) });
}

// --- Live markdown preview (Obsidian-style, line-level reveal) ------------------------------------
// Renders markdown inline - headings sized, bold / italic / strikethrough / inline-code / links styled
// with their markers hidden - EXCEPT on the line(s) the cursor or selection currently touches, which
// show the raw markers so they can be edited. Click/arrow onto a line to reveal its markers; move away
// and it re-renders. Bullet + numbered lists are intentionally left as-is (they already read well).
const hideMark = Decoration.replace({});
const strongMark = Decoration.mark({ class: "cm-md-strong" });
const emMark = Decoration.mark({ class: "cm-md-em" });
const strikeMark = Decoration.mark({ class: "cm-md-strike" });
const codeMark = Decoration.mark({ class: "cm-md-code" });
const linkMark = Decoration.mark({ class: "cm-md-link" });

function selectedLineNumbers(state) {
  const set = new Set();
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.to).number;
    for (let n = first; n <= last; n += 1) set.add(n);
  }
  return set;
}

function buildMarkdownDecorations(view) {
  const decos = [];
  const state = view.state;
  const doc = state.doc;
  const activeLines = selectedLineNumbers(state);
  const isActive = (pos) => activeLines.has(doc.lineAt(pos).number);

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const name = node.name;
        // Heading: size the whole line always; hide the "### " marker unless the line is being edited.
        const heading = /^ATXHeading([1-6])$/.exec(name);
        if (heading) {
          const line = doc.lineAt(node.from);
          decos.push(Decoration.line({ class: `cm-md-h${heading[1]}` }).range(line.from));
          return undefined;
        }
        if (name === "HeaderMark" && !isActive(node.from)) {
          let end = node.to;
          if (doc.sliceString(node.to, node.to + 1) === " ") end += 1;
          decos.push(hideMark.range(node.from, end));
          return undefined;
        }
        // Inline spans: style the whole span; hide its markers off the active line (they descend to us).
        if (name === "StrongEmphasis") { decos.push(strongMark.range(node.from, node.to)); return undefined; }
        if (name === "Emphasis") { decos.push(emMark.range(node.from, node.to)); return undefined; }
        if (name === "Strikethrough") { decos.push(strikeMark.range(node.from, node.to)); return undefined; }
        if (name === "InlineCode") { decos.push(codeMark.range(node.from, node.to)); return undefined; }
        if ((name === "EmphasisMark" || name === "StrikethroughMark" || name === "CodeMark") && !isActive(node.from)) {
          decos.push(hideMark.range(node.from, node.to));
          return undefined;
        }
        // Link [text](url): style the node (only the text shows), hide "[" and "](url)" off the active line.
        if (name === "Link") {
          decos.push(linkMark.range(node.from, node.to));
          if (!isActive(node.from)) {
            const marks = [];
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              if (c.name === "LinkMark") marks.push(c);
            }
            if (marks.length >= 2) {
              if (marks[0].to > marks[0].from) decos.push(hideMark.range(marks[0].from, marks[0].to));
              if (node.to > marks[1].from) decos.push(hideMark.range(marks[1].from, node.to));
            }
          }
          return false; // handled here; don't descend into the link's marks / url
        }
        return undefined;
      },
    });
  }
  return Decoration.set(decos, true);
}

const markdownLivePreview = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = buildMarkdownDecorations(view);
    }
    update(update) {
      if (update.docChanged || update.selectionSet || update.viewportChanged) {
        this.decorations = buildMarkdownDecorations(update.view);
      }
    }
  },
  { decorations: (v) => v.decorations }
);

export function setEditorChangeHandler(handler) {
  onDocChanged = typeof handler === "function" ? handler : () => {};
}

// Fires after the editor is swapped to a different note's body (a tab switch / external body load), so the
// caller can rebuild view-scoped decorations that do not survive a swap — the inline bullseye marker (BT3).
export function setEditorSwapHandler(handler) {
  onEditorSwap = typeof handler === "function" ? handler : () => {};
}

// The single extension list every EditorState in this window is built from — by makeEditor once at startup, and
// again by EVERY note swap, because a swap now replaces the whole EditorState rather than editing the old one
// (see replaceEditorDoc). Built fresh per call so the editable compartment picks up its live value; the state
// fields and the view plugin are module-level singletons, so reusing them across states is intentional and the
// per-state value each one gets is whatever its own create() mints.
function editorExtensions() {
  return [
    history(),
    markdown({ base: markdownLanguage }),
    markdownLivePreview,
    bullseyeMarkerField,
    replaceHighlightField,
    // BUG 3a (refine2): a CM6-managed caret so the replace-highlight collapse-then-restore (BT4) and the
    // dictation-target relocate never leave a stale NATIVE caret beside the redrawn one. `drawSelection()`
    // hides the browser's native selection and draws CM's own — the standard CM6 fix for native/custom caret
    // desync, which the double-caret was.
    drawSelection(),
    keymap.of([...defaultKeymap, ...historyKeymap]),
    EditorView.lineWrapping,
    editableCompartment.of(EditorView.editable.of(editorEditable)),
    EditorView.updateListener.of((update) => {
      if (!update.docChanged) return;
      // Every doc-changing transaction that reaches this listener is now a real edit of the note currently in
      // the editor, so its ChangeSet is always safe to remap the dictation-target anchors through. The
      // programmatic note swap — the one case whose ChangeSet spanned TWO different notes and had to be
      // excluded here — is no longer a transaction at all; replaceEditorDoc notifies out of band instead.
      onDocChanged(update.state.doc.toString(), update.changes);
    }),
  ];
}

export function makeEditor(doc) {
  editor = new EditorView({
    parent: editorEl,
    state: EditorState.create({ doc, extensions: editorExtensions() }),
  });
}

export function hasEditor() {
  return Boolean(editor);
}

export function currentEditorDoc() {
  return editor ? editor.state.doc.toString() : "";
}

export function setEditorEditable(enabled) {
  editorEditable = enabled !== false;
  if (!editor) return;
  editor.dispatch({ effects: editableCompartment.reconfigure(EditorView.editable.of(editorEditable)) });
}

function freshEditorState(body, previous = null) {
  if (!previous) return EditorState.create({ doc: body, extensions: editorExtensions() });
  const changes = ChangeSet.of({ from: 0, to: previous.doc.length, insert: body }, previous.doc.length);
  const main = previous.selection.main;
  return EditorState.create({
    doc: body,
    selection: { anchor: changes.mapPos(main.anchor), head: changes.mapPos(main.head) },
    extensions: editorExtensions(),
  });
}

function deserializeEditorState(serialized, body) {
  if (typeof serialized !== "string" || !serialized) return null;
  try {
    const restored = EditorState.fromJSON(
      JSON.parse(serialized),
      { extensions: editorExtensions() },
      { history: historyField }
    );
    return restored.doc.toString() === body ? restored : null;
  } catch (_) {
    return null;
  }
}

// The cross-window drag rail carries this string through Swift memory and directly into the destination
// island. It is never persisted. CodeMirror explicitly exposes historyField for this exact state-transfer
// use; serializing only that custom field keeps the note's document, selection, undo, and redo branches while
// excluding view-only decorations and every ViddyDictate transient target.
export function serializeEditorState(noteId) {
  const state = noteId === editorNoteId && editor ? editor.state : noteEditorStates.get(noteId);
  if (!state) return null;
  return JSON.stringify(state.toJSON({ history: historyField }));
}

// Closing a note is D3's lifetime boundary. Setting editorNoteId to null is load-bearing for an active close:
// the following neighbor swap must not cache the just-closed state on its way out.
export function forgetEditorState(noteId) {
  if (!noteId) return;
  noteEditorStates.delete(noteId);
  if (editorNoteId === noteId) editorNoteId = null;
}

// Load `body` for `noteId` on a tab switch or whole-body external replacement.
//
// PER-NOTE UNDO LIFETIME + ISOLATION. There is exactly ONE EditorView for the whole life of this window, but
// every OPEN note owns its own EditorState. A tab switch parks the outgoing state by note id and restores the
// incoming note's state. Thus navigation keeps that note's history, while Cmd+Z can only inspect the state
// belonging to the note currently shown and can never reach another note's body.
//
// `resetHistory` is for an authoritative whole-body external load (control-server set, file reload, etc.). It
// deliberately discards only that note's cached state and creates a fresh history boundary. Ordinary live
// mutations must remain CodeMirror transactions and must never route through this function.
//
// Adding `Transaction.addToHistory.of(false)` to the old dispatch is NOT a fix and only looks like one — per
// the vendored @codemirror/commands that flag makes the swap itself a non-undoable mapping step, leaving the
// PREVIOUS note's own edits sitting on the shared stack and still reachable by one more Cmd+Z.
export function replaceEditorDoc(noteId, body, { serializedState = null, resetHistory = false } = {}) {
  if (!editor) {
    makeEditor(body);
    editorNoteId = noteId;
    onEditorSwap();
    return;
  }
  const previous = editor.state;
  if (editorNoteId != null && editorNoteId !== noteId) noteEditorStates.set(editorNoteId, previous);
  if (resetHistory && noteId) noteEditorStates.delete(noteId);

  let next = resetHistory ? null : deserializeEditorState(serializedState, body);
  // Returning from the History/settings surface can select the SAME active note without ever swapping the
  // editor away. In that case the live state is newer than the map entry last parked on a real note switch.
  if (!next && !resetHistory && editorNoteId === noteId && previous.doc.toString() === body) next = previous;
  if (!next && !resetHistory && noteId) {
    const cached = noteEditorStates.get(noteId);
    if (cached && cached.doc.toString() === body) next = cached;
  }
  // A first open or an authoritative replacement carries the caret exactly as the retired full-document
  // transaction did. Returning to an open note instead restores that note's own selection with its history.
  if (!next) next = freshEditorState(body, previous);
  if (noteId) noteEditorStates.set(noteId, next);
  editorNoteId = noteId;
  editor.setState(next);
  // `setState` deliberately does NOT run updateListener (it produces no ViewUpdate), so the swap notification
  // the annotated transaction used to emit is sent directly, from the same point in the sequence its listener
  // call occupied. Null ChangeSet, for the original reason: the offsets on either side of a swap belong to two
  // DIFFERENT notes, so remapping the dictation-target anchors through it would corrupt them (BT1/BT2/BT4/BT5's
  // follow-edits remaps are all `if (changes)`-guarded). Without this the active tab's body, its save schedule
  // and the tab strip would silently stop updating on note switches.
  onDocChanged(body, null);
  editor.focus();
  // The swapped-in note may or may not be the bullseye's note, and `setState` reinitialises every state field,
  // so both view-scoped decorations — the inline bullseye marker (BT3) and the replace highlight (BT4) — rebuild
  // from their JS stores here, exactly as they did when the swap was a transaction.
  onEditorSwap();
}

export function focusEditor() {
  if (editor) editor.focus();
}

export function selectAllEditor() {
  if (!editor) return;
  editor.dispatch({ selection: { anchor: 0, head: editor.state.doc.length } });
  editor.focus();
}

export function collapseEditorSelection() {
  if (!editor) return;
  const main = editor.state.selection.main;
  if (main.empty && editor.state.selection.ranges.length === 1) return;
  editor.dispatch({ selection: { anchor: main.head } });
}

// Restore a live selection over [from, to] (BUG 2 fix, restore-selection-on-teardown): the replace-highlight
// tint collapses the live selection so the color shows; when the tint is torn down WITHOUT delivering (Option+P
// picking up a note selection, an Esc-cancel), the caret would otherwise be left collapsed and the follow-up
// synthetic Cmd+C would copy nothing. Re-selecting the snapshot's original range (anchor = from, head = to)
// brings the selection back so the copy captures it. Clamped to the doc; a bare-caret (from === to) range just
// places the caret. Effect-only-ish dispatch: it moves the selection, nothing else. No-op without an editor.
export function setEditorSelection(from, to) {
  if (!editor) return;
  const len = editor.state.doc.length;
  const anchor = Math.max(0, Math.min(from, len));
  const head = Math.max(0, Math.min(to, len));
  editor.dispatch({ selection: { anchor, head } });
}

export function insertIntoEditor(insert) {
  if (!editor) return null;
  const cursor = editor.state.selection.main;
  return insertAtRange(cursor.from, cursor.to, insert);
}

// The live editor's current main selection as {from, to} (from === to is a bare caret). Used to snapshot a
// dictation target at take-start (BT1). Null when no editor exists yet.
export function currentSelection() {
  if (!editor) return null;
  const main = editor.state.selection.main;
  return { from: main.from, to: main.to };
}

// The live editor's text over [from, to] (clamped), in CodeMirror position units. Used to capture the text a
// dictation delivery is about to OVERWRITE (BT5 undo). Empty string when no editor / an empty range.
export function editorSlice(from, to) {
  if (!editor) return "";
  const len = editor.state.doc.length;
  const f = Math.max(0, Math.min(from, len));
  const t = Math.max(f, Math.min(to, len));
  return editor.state.doc.sliceString(f, t);
}

// Replace [from, to] with `insert` (from === to inserts at the caret), clamped to the doc, leaving the caret
// after the inserted text. The dictation-target landing seam (BT1): the snapshotted anchor is where text goes,
// independent of the live caret. Returns the resulting doc string, or null when no editor exists.
export function insertAtRange(from, to, insert) {
  if (!editor) return null;
  const len = editor.state.doc.length;
  const f = Math.max(0, Math.min(from, len));
  const t = Math.max(f, Math.min(to, len));
  if (f === t) {
    insert = stripLeadingInlineWhitespace(insert);
    const precedingChar = f === 0 ? "" : editor.state.doc.sliceString(f - 1, f);
    if (needsLeadingSeparator(precedingChar, insert)) insert = ` ${insert}`;
  }
  editor.dispatch({
    changes: { from: f, to: t, insert },
    selection: { anchor: f + insert.length },
    scrollIntoView: true,
  });
  return editor.state.doc.toString();
}

// Append `insert` at the END of the LIVE document as an ordinary CodeMirror transaction, joined by the one
// pure rule in sticky-skill-append.js. Returns the resulting doc string, or null when no editor exists.
// The Sticky Skill "Append to the source note" landing (S2) is the only caller.
//
// Deliberately NOT insertAtRange, for two reasons that both matter:
//   1. insertAtRange is the DICTATION landing seam and it OWNS THE CARET - it sets the selection after the
//      inserted text and scrolls it into view. A skill can finish minutes after it was started, while the
//      user is typing somewhere else in that same note, and yanking their caret to the bottom would send
//      their next keystrokes after the appended block. This dispatch specifies no selection and no scroll,
//      so CodeMirror maps the user's caret through the change and leaves it exactly where it was.
//   2. Its bare-caret branch applies the dictation separator (one ASCII space). A markdown block joined to
//      the previous paragraph by a space is not a block at all.
// It IS a plain transaction on the live view, which is the whole point: the undo stack survives (a note's
// per-note history is chain 1's fix and an append must not spend it), and the insert is computed against
// the live buffer, so nothing typed since the last save can be lost.
export function appendToEditorEnd(insert) {
  if (!editor) return null;
  const range = appendRange(editor.state.doc.toString(), insert);
  editor.dispatch({ changes: { from: range.from, to: range.to, insert: range.insert } });
  return editor.state.doc.toString();
}
