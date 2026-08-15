// Per-note undo lifetime and isolation (VDPF L1 + repair/ship-ready L3).
//
// This gate uses the real vendored CodeMirror history implementation. The harness below is only the app's
// one-view/many-notes shell: every edit and undo is an actual EditorState transaction / command. The source
// scan at the bottom binds the shipping editor and lifecycle paths to the proved design.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ChangeSet, EditorState, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { history, historyField, undo } from "@codemirror/commands";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../../..");
const EDITOR_JS = path.join(ROOT, "Web/StickyNotes/src/editor.js");
const ACTIONS_JS = path.join(ROOT, "Web/StickyNotes/src/actions.js");
const EXTERNAL_JS = path.join(ROOT, "Web/StickyNotes/src/external-control.js");
const DRAG_JS = path.join(ROOT, "Web/StickyNotes/src/drag-rail.js");
const BRIDGE_SWIFT = path.join(ROOT, "Sources/App/NotesBridgeMessages.swift");

let clock = 1_000_000;
const nextTime = () => (clock += 10_000);

function makeHarness(mode = "per-note") {
  let editorState = EditorState.create({ doc: "", extensions: [history()] });
  let activeId = null;
  const states = new Map();
  const persisted = new Map();

  const view = {
    get state() { return editorState; },
    dispatch(tr) {
      editorState = tr.state;
      if (tr.docChanged && activeId != null) persisted.set(activeId, editorState.doc.toString());
    },
  };

  function fresh(body) {
    const previous = editorState;
    const changes = ChangeSet.of({ from: 0, to: previous.doc.length, insert: body }, previous.doc.length);
    const main = previous.selection.main;
    return EditorState.create({
      doc: body,
      selection: { anchor: changes.mapPos(main.anchor), head: changes.mapPos(main.head) },
      extensions: [history()],
    });
  }

  return {
    view,
    persisted,
    get doc() { return editorState.doc.toString(); },
    get state() { return editorState; },

    openNote(id, body, serialized = null) {
      if (mode === "shared-view") {
        activeId = id;
        view.dispatch(editorState.update({
          changes: { from: 0, to: editorState.doc.length, insert: body },
          annotations: Transaction.time.of(nextTime()),
        }));
        return;
      }
      if (activeId != null && activeId !== id) states.set(activeId, editorState);
      let next = null;
      if (serialized) {
        next = EditorState.fromJSON(JSON.parse(serialized), { extensions: [history()] },
          { history: historyField });
        if (next.doc.toString() !== body) next = null;
      }
      if (!next && activeId === id && editorState.doc.toString() === body) next = editorState;
      if (!next) {
        const cached = states.get(id);
        if (cached && cached.doc.toString() === body) next = cached;
      }
      editorState = next || fresh(body);
      states.set(id, editorState);
      activeId = id;
      persisted.set(id, body);
    },

    type(at, text) {
      view.dispatch(editorState.update({
        changes: { from: at, insert: text },
        selection: { anchor: at + text.length },
        annotations: Transaction.time.of(nextTime()),
      }));
      if (activeId != null) states.set(activeId, editorState);
    },

    undo() {
      const changed = undo(view);
      if (activeId != null) states.set(activeId, editorState);
      return changed;
    },

    serialize(id) {
      const state = id === activeId ? editorState : states.get(id);
      return state ? JSON.stringify(state.toJSON({ history: historyField })) : null;
    },

    close(id) {
      states.delete(id);
      if (activeId === id) activeId = null;
    },

    reset(id, body) {
      states.delete(id);
      if (activeId === id) {
        activeId = null;
        this.openNote(id, body);
      }
    },
  };
}

// Returning from the hamburger History/settings surface selects the same still-open note. The live state,
// not an older map entry, must win there too.
{
  const h = makeHarness();
  h.openNote("A", "");
  h.type(0, "HELLO FROM NOTE ONE");
  h.openNote("A", "HELLO FROM NOTE ONE");
  assert.equal(h.undo(), true, "same-note navigation keeps the live undo stack");
  assert.equal(h.doc, "");
}

// The retired shared-state design reproduces the data-loss bug that L3 must never bring back.
{
  const h = makeHarness("shared-view");
  h.openNote("A", "note one");
  h.type(8, " edited");
  h.openNote("B", "note two");
  assert.equal(h.undo(), true);
  assert.equal(h.doc, "note one edited", "OLD: note A crosses into note B");
  assert.equal(h.persisted.get("B"), "note one edited", "OLD: crossing text is persisted under note B");
}

// The exact field reproduction, plus the stop-ship inverse: note one's text is never reachable from note two.
{
  const h = makeHarness();
  h.openNote("A", "");
  h.type(0, "HELLO FROM NOTE ONE");
  h.openNote("B", "");
  for (let i = 0; i < 20; i += 1) assert.equal(h.undo(), false, "note B has no note A history");
  assert.equal(h.doc, "", "note B stays empty no matter how many times Cmd+Z is held");
  assert.equal(h.persisted.get("B"), "", "note B never persists note one's text");
  h.openNote("A", "HELLO FROM NOTE ONE");
  assert.equal(h.undo(), true, "returning to open note A restores its undo stack");
  assert.equal(h.doc, "", "Cmd+Z undoes HELLO FROM NOTE ONE normally");
  h.openNote("B", "");
  assert.equal(h.doc, "", "note B remains isolated after note A's successful undo");
}

// A window move serializes the same per-note EditorState through memory and restores it in another island.
{
  const source = makeHarness();
  source.openNote("A", "");
  source.type(0, "HELLO FROM NOTE ONE");
  const transfer = source.serialize("A");
  source.close("A");
  const target = makeHarness();
  target.openNote("A", "HELLO FROM NOTE ONE", transfer);
  assert.equal(target.undo(), true, "a dragged open tab keeps its undo stack in the destination window");
  assert.equal(target.doc, "");
}

// Closing is the lifetime boundary. Reopening starts fresh, even if the id/body happen to match in this model.
{
  const h = makeHarness();
  h.openNote("A", "");
  h.type(0, "HELLO FROM NOTE ONE");
  h.close("A");
  h.openNote("A", "HELLO FROM NOTE ONE");
  assert.equal(h.undo(), false, "close discards history");
  assert.equal(h.doc, "HELLO FROM NOTE ONE");
}

// An authoritative whole-body replacement is also a fresh boundary for that note. It is not a partial edit.
{
  const h = makeHarness();
  h.openNote("A", "old");
  h.type(3, " edit");
  h.reset("A", "server body");
  assert.equal(h.undo(), false, "external whole-body load does not retain stale local history");
  assert.equal(h.doc, "server body");
}

// Structural pins on the shipping paths.
{
  const editor = readFileSync(EDITOR_JS, "utf8");
  const actions = readFileSync(ACTIONS_JS, "utf8");
  const external = readFileSync(EXTERNAL_JS, "utf8");
  const drag = readFileSync(DRAG_JS, "utf8");
  const bridge = readFileSync(BRIDGE_SWIFT, "utf8");
  const code = editor.split("\n").map((line) => line.replace(/\/\/.*$/, "")).join("\n");

  assert.match(editor, /historyField/, "shipping editor imports CodeMirror's serializable history field");
  assert.match(editor, /const noteEditorStates = new Map\(\)/, "open-note states are keyed by note id");
  assert.match(editor, /noteEditorStates\.set\(editorNoteId, previous\)/,
    "a navigation swap parks the outgoing note's whole EditorState");
  assert.match(editor, /editorNoteId === noteId && previous\.doc\.toString\(\) === body/,
    "same-note navigation keeps the newer live state instead of an older parked copy");
  assert.match(editor, /cached\.doc\.toString\(\) === body/, "cached history is accepted only for the same body");
  assert.match(editor, /EditorState\.fromJSON[\s\S]*?\{ history: historyField \}/,
    "cross-window transfer restores CodeMirror history through its supported serializer");
  assert.match(editor, /state\.toJSON\(\{ history: historyField \}\)/,
    "cross-window transfer serializes the real history field");
  assert.doesNotMatch(code, /localStorage|sessionStorage|indexedDB/,
    "undo history is memory-only and cannot survive quit");

  assert.match(actions, /forgetEditorState\(closing\.id\)/, "normal note close discards its state");
  assert.match(external, /forgetEditorState\(id\)/, "external note close discards its state");
  assert.match(external, /replaceEditorForTab\(tab, null, \{ resetHistory: true \}\)/,
    "externalSetBody creates a fresh history boundary rather than restoring stale history");
  assert.match(drag, /editorState: serializeEditorState\(dragTracking\.id\)/,
    "the real tab-drag bridge carries the source note's state");
  assert.match(bridge, /static let editorState = "editorState"/,
    "Swift and JS share an explicit ephemeral transfer key");

  const swap = /export function replaceEditorDoc\(noteId, body,[\s\S]*?\n\}/.exec(code);
  assert.ok(swap, "editor.js still exports the per-note swap");
  assert.doesNotMatch(swap[0], /editor\.dispatch\(\{\s*changes:/,
    "a note swap is never a document transaction on the outgoing note");
  assert.match(swap[0], /onDocChanged\(body, null\)/,
    "setState still notifies persistence out of band with no cross-note ChangeSet");
}

console.log("[check-undo-isolation] OK - per-note history survives navigation and remains isolated");
