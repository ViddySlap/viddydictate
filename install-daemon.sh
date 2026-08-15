#!/usr/bin/env bash
# Install the on-demand local STT LaunchAgent (com.viddydictate.whisperd) that ViddyDictate
# talks to on 127.0.0.1:8765.
#
# Everything this needs ships in the repo: `viddydictate_whisperd.py` sits beside this script and
# the installer builds its OWN Python virtualenv under ~/Library/Application Support/ViddyDictate.
# Nothing outside the repo and the user's own home is read.
#
# The Whisper weights are NOT vendored (~1.5 GB). mlx-whisper downloads them into the Hugging Face
# cache on the daemon's first transcribe, so the first wake after a fresh install is slow and every
# later one is warm.
#
# The daemon runs from a COPY under ~/Library/Application Support rather than in place: a launchd
# agent running `python` directly cannot open TCC-protected locations like ~/Documents (no grant,
# no prompt), and the copy is self-contained (stdlib + mlx-whisper, reads $TMPDIR and the HF cache
# only). Re-run this script after pulling to refresh the copy.
#
# Usage: ./install-daemon.sh [--no-bootstrap]
#   --no-bootstrap   Stage the daemon, venv, and plist but leave launchd alone. For verification
#                    runs and for installs that must not disturb a live agent.
set -euo pipefail

BOOTSTRAP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-bootstrap) BOOTSTRAP=0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) printf '[install] unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/viddydictate_whisperd.py"
SUPPORT="$HOME/Library/Application Support/ViddyDictate"
DEST="$SUPPORT/viddydictate_whisperd.py"
VENV="$SUPPORT/stt-venv"
PLIST_SRC="$ROOT/com.viddydictate.whisperd.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.viddydictate.whisperd.plist"
LABEL="com.viddydictate.whisperd"
PORT="${VIDDYDICTATE_WHISPER_PORT:-8765}"
# Compatible-release bound, not an open range: a minor bump of the STT stack must be a deliberate
# repo change, because "install this app" has to keep working months from now.
REQUIREMENT="mlx-whisper~=0.4.3"
U="$(id -u)"

[ -r "$SRC" ] || { echo "[install] FATAL: daemon source missing at $SRC"; exit 1; }

# mlx publishes wheels for CPython 3.10-3.14; 3.9 still resolves to an older, working mlx, and a
# bare Command-Line-Tools Mac has only 3.9. Prefer a mid-range interpreter, fall back to whatever
# `python3` is, and let the user force one with VD_STT_PYTHON.
PY=""
if [ -n "${VD_STT_PYTHON:-}" ]; then
    PY="$VD_STT_PYTHON"
    command -v "$PY" >/dev/null 2>&1 || { echo "[install] FATAL: VD_STT_PYTHON=$PY not found"; exit 1; }
else
    for candidate in python3.12 python3.13 python3.11 python3.10 python3; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null || continue
        PY="$candidate"
        break
    done
fi
[ -n "$PY" ] || { echo "[install] FATAL: no Python >= 3.9 on PATH. Set VD_STT_PYTHON=/path/to/python3."; exit 1; }

mkdir -p "$SUPPORT"

if [ ! -x "$VENV/bin/python" ]; then
    echo "[install] creating STT venv -> $VENV ($("$PY" -V 2>&1), $(command -v "$PY"))"
    "$PY" -m venv "$VENV"
else
    echo "[install] reusing STT venv -> $VENV"
fi

echo "[install] installing $REQUIREMENT into the venv (first run pulls a few hundred MB)"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet --upgrade "$REQUIREMENT"

# mlx-whisper shells out to ffmpeg by name to decode the recorded clip. launchd's PATH is set in
# the plist below; if ffmpeg is not on it the daemon still starts and /health still answers, but
# every transcribe fails, so say so now rather than at first dictation.
if ! PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v ffmpeg >/dev/null 2>&1; then
    echo "[install] WARNING: ffmpeg not found on the daemon's PATH. Transcribes will fail until you"
    echo "          install it (brew install ffmpeg)."
fi

echo "[install] daemon -> $DEST"
cp "$SRC" "$DEST"

echo "[install] LaunchAgent -> $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"

if [ "$BOOTSTRAP" -eq 0 ]; then
    echo "[install] --no-bootstrap: launchd untouched. Load it later with:"
    echo "          launchctl bootstrap gui/$U $PLIST_DST"
    exit 0
fi

launchctl bootout "gui/$U/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$U" "$PLIST_DST"
launchctl kickstart "gui/$U/$LABEL" >/dev/null

echo "[install] confirming the daemon answers on 127.0.0.1:$PORT"
HEALTH=""
for _ in $(seq 1 30); do
    HEALTH="$(curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
    [ -n "$HEALTH" ] && break
    sleep 1
done
if [ -z "$HEALTH" ]; then
    echo "[install] FAIL: no answer on 127.0.0.1:$PORT — see /tmp/viddydictate-whisperd.err.log"
    exit 1
fi

echo "[install] health: $HEALTH"
case "$HEALTH" in
    *'"ready": true'*) echo "[install] OK — model warm, dictation is ready." ;;
    *) echo "[install] OK — daemon up. The Whisper model (~1.5 GB) downloads on first use;"
       echo "          the first dictation after that download is the slow one." ;;
esac
echo "[install] wake it any time with: launchctl kickstart gui/$U/$LABEL"
