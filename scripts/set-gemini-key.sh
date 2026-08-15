#!/usr/bin/env bash
# Store your Google Gemini API key in the login keychain, where ViddyDictate reads it from.
#
# This is the FALLBACK path, for a terminal or a headless setup (spec decision D7). The normal way is
# Settings > Setup > Gemini API key, which has a secure field and the same instructions in it. Both
# end at the same keychain item, written by the same app binary.
#
# Option+G (grounded web answers) is the only feature that needs it, and it is optional: with no key
# stored, Option+G reports itself off and every other mode keeps working. Get a key at
# https://aistudio.google.com/apikey.
#
#   ./scripts/set-gemini-key.sh            # prompts, input hidden
#   ./scripts/set-gemini-key.sh --status   # is a key stored, and from where (never prints it)
#   ./scripts/set-gemini-key.sh --clear    # remove the stored key (Option+G goes off)
#   pbpaste | ./scripts/set-gemini-key.sh  # non-interactive
#
# The write is performed by the ViddyDictate binary rather than by `security add-generic-password`,
# because the process that CREATES a keychain item is the one placed on its access list: an item the
# app wrote is read back silently, one the terminal wrote makes macOS prompt on every launch.
#
# The key is passed on stdin, never as an argument — arguments are visible in `ps` to every process
# on the machine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP=""
for candidate in "$HOME/Applications/ViddyDictate.app" "$ROOT/build/ViddyDictate.app"; do
    if [ -x "$candidate/Contents/MacOS/ViddyDictate" ]; then
        APP="$candidate/Contents/MacOS/ViddyDictate"
        break
    fi
done
if [ -z "$APP" ]; then
    echo "[gemini-key] ViddyDictate is not installed or built."
    echo "[gemini-key]   run ./build.sh && ./install-app-agent.sh first"
    exit 1
fi

case "${1:-}" in
    --clear)  exec "$APP" --clear-gemini-key ;;
    --status) exec "$APP" --gemini-key-status ;;
esac

if [ -t 0 ]; then
    printf 'Gemini API key (input hidden): '
    read -rs KEY
    printf '\n'
    printf '%s' "$KEY" | "$APP" --set-gemini-key
    unset KEY
else
    "$APP" --set-gemini-key
fi

echo "[gemini-key] Option+G will use it on the next dictation; no restart needed."
