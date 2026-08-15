// Note-target snapshot targeting (notes-bullseye BT1). The TRANSIENT dictation destination inside a sticky
// note: captured at take-START (Swift -> snapshotTarget) as a CodeMirror-anchored range in the ACTIVE note's
// live editor, remapped through every edit so it FOLLOWS EDITS, and consumed at completion (Swift ->
// insertAtTarget) so the dictation lands exactly there even if focus/selection moved during the take.
//
// The anchor lives here (not in Swift) because only CodeMirror can map a position through changes. There is a
// single editor swapped per tab, so we remap ONLY the snapshot belonging to the currently-live note on each
// edit; a non-live note is never typed into, so its stored offsets stay valid against its unchanged body. One
// snapshot per note id; cleared on delivery (transient).

const snapshots = Object.create(null); // noteId -> { from, to, generation }

// Record a snapshot for `noteId` spanning [from, to] (normalized), tagged with the monotonic take/gesture
// `generation` Swift stamps at take-START. from === to is a bare caret (insert point); from < to is a selection
// (range to replace).
//
// GENERATION GUARD (refine2 BUG 2 fix): refuse a write that would CLOBBER a fresher, non-empty snapshot for the
// same note. Option+P over a note selection first tinted + COLLAPSED the live selection, then the command chord
// re-read that collapsed caret and overwrote the good `{from,to}` with a degenerate `{X,X}`, so delivery
// inserted-at-a-point instead of replacing. The rule: an OLDER-generation write never wins; within the SAME
// generation an EMPTY (from === to, collapsed re-read) write never overwrites a non-empty snapshot; a NEWER
// generation ALWAYS wins (a fresh take legitimately re-snapshots, even to a bare caret, so a genuine new
// bare-caret gesture is never blocked by a stale range). This mirrors `NotesTargetLogic.acceptsSnapshotWrite`
// (pinned headlessly by `--notes-probe`) and makes the whole bridge robust to this interleaving class.
export function setSnapshot(noteId, from, to, generation) {
  if (!noteId) return;
  const lo = Math.min(from, to);
  const hi = Math.max(from, to);
  const gen = Number.isFinite(generation) ? generation : 0;
  const prev = snapshots[noteId];
  if (prev) {
    const prevGen = Number.isFinite(prev.generation) ? prev.generation : 0;
    if (gen < prevGen) return;                                       // older gesture never wins
    if (gen === prevGen && lo === hi && prev.from !== prev.to) return; // same gesture: empty never clobbers a range
  }
  snapshots[noteId] = { from: lo, to: hi, generation: gen };
}

export function getSnapshot(noteId) {
  return noteId && noteId in snapshots ? snapshots[noteId] : null;
}

export function clearSnapshot(noteId) {
  if (noteId) delete snapshots[noteId];
}

// Remap the live note's snapshot through one CodeMirror ChangeSet so the anchor follows edits: typing above it
// shifts it down, deleting above shifts it up. assoc -1 on `from` keeps the insert point stable when text lands
// exactly at the anchor (insert where I was, not after what I just typed); assoc 1 on `to` lets a selection's
// tail grow with text appended at its end.
export function mapSnapshotThroughChanges(noteId, changes) {
  const snap = getSnapshot(noteId);
  if (!snap || !changes || typeof changes.mapPos !== "function") return;
  snapshots[noteId] = {
    from: changes.mapPos(snap.from, -1),
    to: changes.mapPos(snap.to, 1),
    generation: snap.generation,   // the remap keeps the snapshot's gesture id so the guard still compares it
  };
}

// --- Bullseye: the PERSISTENT pinned target (notes-bullseye BT2) ---------------------------------------
// Distinct from the transient snapshot above: there is exactly ONE bullseye, it is NOT cleared after a take,
// and it follows edits until it is moved (Option+N) or dropped (its note closed). A caret-offset anchor in
// one note. Swift owns the arm state + persistence; this holds the live CodeMirror-mapped anchor for delivery
// landing PLUS a mirror of the armed flag (BT3) so the inline marker can gate on it locally (Swift pushes the
// armed flag over `bullseyeArmed`; Option+N's `setBullseye` arms directly).
let bullseye = null; // { noteId, anchor, armed } — anchor is a caret offset (insert point)

// Pin / move the bullseye anchor to `pos` in `noteId` (Option+N, a delivery advance, or a restore). Preserves
// the armed flag when re-anchoring within the same note; a move to a different note starts disarmed until the
// caller arms it (Option+N does, immediately after).
export function setBullseyeAnchor(noteId, pos) {
  if (!noteId) return;
  const armed = bullseye && bullseye.noteId === noteId ? bullseye.armed : false;
  bullseye = { noteId, anchor: Math.max(0, pos), armed };
}

export function getBullseye() {
  return bullseye;
}

export function clearBullseye() {
  bullseye = null;
}

// Set the armed flag on the current bullseye (BT3). No-op when no bullseye is set. The marker + Swift's
// delivery precedence both gate on armed; JS mirrors it only so the inline marker can show/hide without a
// round-trip.
export function setBullseyeArmed(armed) {
  if (!bullseye) return;
  bullseye = { noteId: bullseye.noteId, anchor: bullseye.anchor, armed: !!armed };
}

// True when a bullseye is set AND armed — the inline-marker visibility gate (BT3).
export function isBullseyeArmed() {
  return !!(bullseye && bullseye.armed);
}

// Remap the bullseye anchor through one ChangeSet when its note is the live editor, so the pinned target
// follows edits (typing above it shifts it down). assoc -1 keeps the insert point stable when text lands
// exactly at the anchor (land where the bullseye is, not after what was just typed). The armed flag is
// preserved across the remap.
export function mapBullseyeThroughChanges(noteId, changes) {
  if (!bullseye || bullseye.noteId !== noteId || !changes || typeof changes.mapPos !== "function") return;
  bullseye = { noteId, anchor: changes.mapPos(bullseye.anchor, -1), armed: bullseye.armed };
}

// --- Four-color replace highlight: the tinted range (notes-bullseye BT4) -------------------------------
// The range a pending level-based operation will REPLACE, tinted by level (Raw / Cleanup / Tighten /
// Summarize). Transient: one pick / one take, then cleared on cancel or commit. There is at most ONE (a
// dictation take and an Option+P pick never overlap). The RANGE is captured once (from the editor selection at
// show-time) and follows edits like the snapshot/bullseye; a level change swaps only the color. The live
// CodeMirror mark is rebuilt from this store after an editor swap (a decoration mapped through a full-document
// replace is meaningless), so the store is the source of truth for that rebuild.
let replaceHighlight = null; // { noteId, from, to, level }

export function getReplaceHighlight() {
  return replaceHighlight;
}

export function setReplaceHighlight(noteId, from, to, level) {
  if (!noteId) return;
  replaceHighlight = { noteId, from: Math.min(from, to), to: Math.max(from, to), level };
}

// Swap the color without touching the captured range (the Option+P pick moving, or the ?-cleanup level
// changing mid-take). No-op when nothing is highlighted.
export function setReplaceHighlightLevel(level) {
  if (replaceHighlight) replaceHighlight = { ...replaceHighlight, level };
}

export function clearReplaceHighlight() {
  replaceHighlight = null;
}

// Remap the tinted range through one ChangeSet when its note is the live editor, so the tint follows edits
// (matching the snapshot/bullseye assoc: -1 on `from`, 1 on `to`, so text appended at the tail grows it).
export function mapReplaceHighlightThroughChanges(noteId, changes) {
  if (!replaceHighlight || replaceHighlight.noteId !== noteId || !changes || typeof changes.mapPos !== "function") return;
  replaceHighlight = {
    ...replaceHighlight,
    from: changes.mapPos(replaceHighlight.from, -1),
    to: changes.mapPos(replaceHighlight.to, 1),
  };
}

// --- Last ViddyDictate delivery: the notes cross-focus undo record (notes-bullseye BT5) ----------------
// The single most-recent dictation edit landed in a note (insertText / insertAtTarget / insertAtBullseye): the
// note id, the mapped insertion range `[from, from+len)`, and the text the delivery OVERWROTE (empty for a
// bare-caret insert). Option+Z reverts exactly this edit even after focus moved away (Swift -> undoNoteDelivery
// by note id): replace `[from, from+len)` with `replaced`, removing the delivered text and restoring any
// overwritten text. Single-shot — cleared on undo (like the foreign-app tier). The range FOLLOWS later edits
// (mapped through changes like the snapshot/bullseye/highlight) so typing above it does not misplace the undo.
let lastDelivery = null; // { noteId, from, len, replaced }

// Record a delivery for `noteId`: text of length `len` inserted at `from`, overwriting `replaced` (the text
// that was in `[from, from+replacedLen)` before). Overwrites any prior record — only the LAST delivery is
// undoable.
export function recordDelivery(noteId, from, len, replaced) {
  if (!noteId) return;
  lastDelivery = { noteId, from: Math.max(0, from), len: Math.max(0, len), replaced: replaced || "" };
}

export function getLastDelivery() {
  return lastDelivery;
}

export function clearLastDelivery() {
  lastDelivery = null;
}

// Remap the last-delivery range through one ChangeSet when its note is the live editor, so the undo target
// follows edits (typing above it shifts it down). assoc -1 on `from` keeps the start stable; the end maps with
// assoc 1 and the length is recomputed so an edit inside the delivered span still bounds the undo correctly.
export function mapLastDeliveryThroughChanges(noteId, changes) {
  if (!lastDelivery || lastDelivery.noteId !== noteId || !changes || typeof changes.mapPos !== "function") return;
  const from = changes.mapPos(lastDelivery.from, -1);
  const end = changes.mapPos(lastDelivery.from + lastDelivery.len, 1);
  lastDelivery = { ...lastDelivery, from, len: Math.max(0, end - from) };
}
