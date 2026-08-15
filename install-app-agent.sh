#!/usr/bin/env bash
# Deploy the built app to the STABLE live path (~/Applications) and (re)install the auto-start
# LaunchAgent. Run after build.sh; re-run for every deploy.
#
# The live app deliberately does NOT run from build/ (2026-07-13 incident): agent/chain rebuilds
# of build/ used to replace the running app in place, and while the stable identity was broken
# they ad-hoc-signed it, silently voiding the Accessibility / Input-Monitoring TCC grants
# (no-paste, clipboard-park fallback). Shipping is now this explicit copy, nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILT="$ROOT/build/ViddyDictate.app"
LIVE="$HOME/Applications/ViddyDictate.app"
PLIST_SRC="$ROOT/com.viddydictate.app.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.viddydictate.app.plist"
OLD_PLIST_DST="$HOME/Library/LaunchAgents/com.viddyslap.viddydictate.plist"
OLD_LABEL="com.viddyslap.viddydictate"
LABEL="com.viddydictate.app"
U="$(id -u)"

[ -x "$BUILT/Contents/MacOS/ViddyDictate" ] || { echo "[deploy] build first — missing $BUILT"; exit 1; }

# Refuse to deploy an ad-hoc-signed build: its TCC identity changes every rebuild, which is the
# exact failure this topology exists to prevent. Check the signature flags, NOT the Authority=
# line — codesign omits Authority when the trust store is wiped, and a cert-signed build is still
# deployable then (the launch-time SigningTrustGuard heals the trust store afterwards).
if codesign -dv "$BUILT" 2>&1 | grep -Eq 'Signature=adhoc|flags=0x2\(adhoc\)'; then
  echo "[deploy] ERROR: build is ad-hoc signed — refusing to deploy."
  echo "[deploy]        Fix signing (build.sh self-heals trust; see setup-signing.sh) and rebuild."
  exit 1
fi

echo "[deploy] copy -> $LIVE"
mkdir -p "$HOME/Applications"
rm -rf "$LIVE"
cp -R "$BUILT" "$LIVE"
xattr -dr com.apple.quarantine "$LIVE" 2>/dev/null || true

echo "[deploy] stop any hand-launched UI instance (CLI seam runs with flags are untouched)"
pkill -f 'ViddyDictate\.app/Contents/MacOS/ViddyDictate$' 2>/dev/null || true
sleep 1

echo "[deploy] install + (re)bootstrap LaunchAgent -> $PLIST_DST"
# macOS does not create ~/Library/LaunchAgents for a fresh account, and the sed redirect below
# cannot create it. Without this the very first install on a clean machine dies here.
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
launchctl bootout "gui/$U/$OLD_LABEL" 2>/dev/null || true
rm -f "$OLD_PLIST_DST"
launchctl bootout "gui/$U/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$U" "$PLIST_DST"
launchctl kickstart "gui/$U/$LABEL" 2>/dev/null || true

echo "[deploy] OK — live app: $LIVE (auto-starts at login, relaunches on crash)"
echo "[deploy] launchd logs: /tmp/viddydictate.err.log ; app log: ~/Library/Logs/ViddyDictate.log"
echo "[deploy] Re-grant Microphone, Accessibility, and Input Monitoring for the new bundle id."
