#!/usr/bin/env bash
# Install the ViddyDictate web-search backend: a DEDICATED production venv with `ddgs` (the robust
# DuckDuckGo client the process-shape bench used) plus the search helper, both at stable absolute
# paths the app shells to. Separate from the throwaway bench venv. Run once; re-run to refresh the
# helper or repair the venv. Idempotent.
#
#   venv   -> ~/.local/share/viddydictate/venv
#   helper -> ~/.local/share/viddydictate/websearch.py   (copied from this repo's bin/)
#
# Kept OUT of the Obsidian-synced vault (heavy venv assets never sync). Mirrors the spotdl/yt-dlp
# isolated-venv pattern.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/bin/websearch.py"
DEST_DIR="$HOME/.local/share/viddydictate"
VENV="$DEST_DIR/venv"
HELPER="$DEST_DIR/websearch.py"

[ -f "$SRC" ] || { echo "[install] missing $SRC"; exit 1; }

mkdir -p "$DEST_DIR"

# Find a python3 to build the venv from (prefer Homebrew, fall back to system).
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "[install] no python3 on PATH"; exit 1; }

if [ ! -x "$VENV/bin/python" ]; then
  echo "[install] creating venv at $VENV (from $PY)"
  "$PY" -m venv "$VENV"
fi

echo "[install] installing/upgrading ddgs into the venv"
"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python" -m pip install --quiet --upgrade ddgs

echo "[install] copying helper -> $HELPER"
cp "$SRC" "$HELPER"

echo "[install] smoke test"
if printf '%s\n' '{"query":"what year did the chernobyl disaster happen","maxResults":2}' \
    | "$VENV/bin/python" "$HELPER" | grep -q '"title"'; then
  echo "[install] OK — search backend live (venv + ddgs + helper)."
else
  echo "[install] WARNING: smoke test returned no results (DuckDuckGo may be throttling right now)."
  echo "[install]          The venv + helper are installed; retry the smoke test in a minute."
fi
