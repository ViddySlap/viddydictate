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
# B20's torch cut, kept identical to the in-app installer's descriptor in InstallerEngine.swift so a
# developer venv and a stranger's venv are the same environment. mlx-whisper declares torch, but only
# torch_whisper.py imports it and nothing in the package imports that module, so the reachable runtime
# never executes 106 MiB of wheel / 638 MiB of disk. Proven by scripts/torch-free-proof.py (48/48 on
# Metal). These are mlx-whisper's own Requires-Dist entries minus torch; each still resolves its own
# dependencies, so --no-deps applies to exactly one package.
DEPENDENCIES="mlx>=0.11 numba numpy tqdm more-itertools tiktoken huggingface_hub scipy"
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
# shellcheck disable=SC2086 -- DEPENDENCIES is a deliberate word list, one requirement per word.
"$VENV/bin/python" -m pip install --quiet --upgrade $DEPENDENCIES
"$VENV/bin/python" -m pip install --quiet --upgrade --no-deps "$REQUIREMENT"
# The --no-deps guard: this script now owns mlx-whisper's closure, so prove it is complete here
# rather than letting the daemon discover it at transcribe time.
if ! "$VENV/bin/python" -c "import mlx_whisper" 2>/tmp/vd-import-check.$$; then
    echo "[install] FATAL: the installed packages are incomplete:"; cat /tmp/vd-import-check.$$
    rm -f /tmp/vd-import-check.$$; exit 1
fi
rm -f /tmp/vd-import-check.$$

# No ffmpeg check here any more, and no ffmpeg dependency to check for. mlx-whisper only shells out
# to ffmpeg when it is handed a PATH; the daemon hands it a decoded array, and the app sends 16 kHz
# audio so that decode is exact. This used to be a warning, which meant a stranger without Homebrew
# got a daemon that started, answered /health, warmed a 1.5 GB model, and failed every transcribe.

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
