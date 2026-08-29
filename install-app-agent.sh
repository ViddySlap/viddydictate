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

# `bootout` returns before launchd has finished tearing the job down, and bootstrapping into that
# window fails with "Bootstrap failed: 5: Input/output error". Measured 2026-08-27: the identical
# command succeeded on the very next attempt. Under `set -e` that one-line race aborted the deploy
# AFTER the live app had already been replaced and unloaded — so the failure mode was not "the deploy
# did not happen", it was "the app the user dictates with is now gone and nothing says so".
#
# Wait for the job to actually leave the domain, then bootstrap, and retry once if it still races.
for _ in $(seq 1 50); do
  launchctl print "gui/$U/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
if ! launchctl bootstrap "gui/$U" "$PLIST_DST"; then
  echo "[deploy] launchd refused the first bootstrap; settling and retrying once"
  sleep 2
  launchctl bootstrap "gui/$U" "$PLIST_DST"
fi
launchctl kickstart "gui/$U/$LABEL" 2>/dev/null || true

# Never end this script leaving the user without their app. If the agent is not loaded here, say so
# in the terms that matter and hand back the one command that fixes it.
if ! launchctl print "gui/$U/$LABEL" >/dev/null 2>&1; then
  echo "[deploy] ERROR: the LaunchAgent is not loaded, so ViddyDictate is NOT running."
  echo "[deploy]        Load it by hand:  launchctl bootstrap gui/$U \"$PLIST_DST\""
  exit 1
fi

echo "[deploy] OK — live app: $LIVE (auto-starts at login, relaunches on crash)"
echo "[deploy] launchd logs: /tmp/viddydictate.err.log ; app log: ~/Library/Logs/ViddyDictate.log"
echo "[deploy] Re-grant Microphone, Accessibility, and Input Monitoring for the new bundle id."
