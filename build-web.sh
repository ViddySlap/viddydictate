#!/usr/bin/env bash
# Regenerate the bundled static Sticky Notes web island.
# Runtime remains node-free: build.sh copies Web/StickyNotes/dist into the app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [ ! -d node_modules ]; then
  npm install
fi

node --no-warnings Web/StickyNotes/scripts/check-insertion-index-fixtures.mjs
# Per-note undo isolation (VDPF L1, the data-loss bug): proves against the real vendored @codemirror history
# that a note swap cannot leave the previous note's edits on a shared undo stack, and pins src/editor.js to
# the pattern that proof covers.
node --no-warnings Web/StickyNotes/scripts/check-undo-isolation.mjs
# refine2 BUG 2 real-path DOM harness: drives the real actions.js/dictation-target.js bridge through the exact
# Option+P-over-a-note-selection interleaving (asserts REPLACE + tint + generation guard + restore-on-teardown).
node --no-warnings --import ./Web/StickyNotes/scripts/notes-bridge-harness/register.mjs Web/StickyNotes/scripts/notes-bridge-harness/run.mjs
npm run build:notes
cp Web/StickyNotes/static/index.html Web/StickyNotes/dist/index.html
cp Web/StickyNotes/static/app.css Web/StickyNotes/dist/app.css

echo "[build-web] OK -> Web/StickyNotes/dist"
