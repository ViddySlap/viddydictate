#!/usr/bin/env bash
# Build ViddyDictate.app — a hand-rolled menu-bar app bundle.
# No Xcode required: uses the Command Line Tools `swiftc` + ad-hoc codesign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ViddyDictate"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
HELPERS="$APP/Contents/Helpers"
RES="$APP/Contents/Resources"
ENTITLEMENTS="$ROOT/ViddyDictate.entitlements"

# ---- Pre-existing-install guard ---------------------------------------------------------------
# The live app must run from ~/Applications (see install-app-agent.sh). An earlier ViddyDictate
# topology ran it straight out of build/, and on such a machine the `rm -rf` below deletes the
# RUNNING app: launchd loses its target and the CGEventTap dies without tearing down, which can
# strand a held modifier and leave the keyboard unresponsive. That is a real report, not a
# hypothetical (external installer, 2026-08-15), and it lands before anyone reads a warning because
# ./scripts/verify.sh calls this script. Refuse before touching anything and hand back the fix.
CANONICAL_LIVE="$HOME/Applications/$APP_NAME.app"
LEGACY_LABELS=()
LEGACY_TARGETS=()
if [ -d "$HOME/Library/LaunchAgents" ]; then
  for plist in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$plist" ] || continue
    # Convert first so binary plists are covered, then look for any ViddyDictate executable path
    # regardless of which key holds it (Program, ProgramArguments, or a shell wrapper).
    target="$(plutil -convert xml1 -o - "$plist" 2>/dev/null \
      | grep -oE "/[^<>[:space:]]*${APP_NAME}\.app/Contents/MacOS/${APP_NAME}" \
      | head -n 1 || true)"
    [ -n "$target" ] || continue
    case "$target" in
      "$CANONICAL_LIVE"/*) continue ;;   # correct topology, nothing to migrate
    esac
    LEGACY_LABELS+=("$(basename "$plist" .plist)")
    LEGACY_TARGETS+=("$target")
  done
fi

if [ "${#LEGACY_LABELS[@]}" -gt 0 ]; then
  echo "[build] ERROR: an existing ViddyDictate install runs from a non-standard path."
  echo "[build]"
  echo "[build] These LaunchAgents point outside $CANONICAL_LIVE:"
  for i in "${!LEGACY_LABELS[@]}"; do
    echo "[build]     ${LEGACY_LABELS[$i]} -> ${LEGACY_TARGETS[$i]}"
  done
  echo "[build]"
  echo "[build] Building now would delete a live app out from under launchd. If that app holds the"
  echo "[build] keyboard event tap, the keyboard can stop responding until you log out."
  echo "[build]"
  echo "[build] Retire the old install first, then rerun this script:"
  echo "[build]"
  for lbl in "${LEGACY_LABELS[@]}"; do
    echo "[build]     launchctl bootout \"gui/\$(id -u)/$lbl\" 2>/dev/null || true"
    echo "[build]     rm -f \"\$HOME/Library/LaunchAgents/$lbl.plist\""
  done
  echo "[build]"
  echo "[build] Then: ./build.sh && ./install-app-agent.sh"
  echo "[build] The new topology installs to $CANONICAL_LIVE and survives rebuilds."
  echo "[build] See \"Upgrading from an earlier install\" in README.md."
  exit 1
fi

# A hand-launched instance from build/ (the README's `open build/ViddyDictate.app`) would also be
# destroyed by the rm -rf below. SIGTERM lets it tear the event tap down; yanking the bundle does not.
if pgrep -f "^${BUILD}/.*\.app/Contents/MacOS/" >/dev/null 2>&1; then
  echo "[build] stopping instance running from build/ (clean shutdown before rebuild)"
  pkill -TERM -f "^${BUILD}/.*\.app/Contents/MacOS/" 2>/dev/null || true
  sleep 1
fi

KC="$HOME/Library/Keychains/vd-signing.keychain-db"
SIGN_ID="ViddyDictate Self-Signed"

# Make the signing keychain usable, prompting only when it is actually necessary.
#
# Order matters. A LOCKED keychain resolves to zero identities, indistinguishable from the
# 2026-07-13 trust-settings wipe, so check first, unlock only if the identity is not already
# resolvable, and re-check before concluding trust is broken. Without that, a hardened (lockable)
# keychain would trigger the trust heal on every single build.
prepare_signing_keychain() {
  # Explicit ifs, not && chains: under `set -e` a failing && list is a foot-gun here.
  if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    return 0
  fi

  # Legacy keychains (pre-hardening) carry a password published in this repo's history, so try it
  # and keep those installs building unattended. A hardened keychain rejects it, and macOS then asks
  # the user for the password they chose at setup.
  if ! security unlock-keychain -p "vd-signing-local" "$KC" 2>/dev/null; then
    security unlock-keychain "$KC"
  fi

  if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    return 0
  fi

  # Still unresolvable with the keychain unlocked, so this is the trust-settings wipe. Re-bless the
  # existing cert. NEVER mint a new one; that resets the TCC grants.
  echo "[build] stable identity not trusted (trust-settings wipe?) — restoring trust"
  HEAL_PEM="$(mktemp)"
  security find-certificate -c "$SIGN_ID" -p "$KC" > "$HEAL_PEM"
  security add-trusted-cert -p codeSign -k "$KC" "$HEAL_PEM" || true
  rm -f "$HEAL_PEM"
}

echo "[build] cleaning"
rm -rf "$APP"
mkdir -p "$MACOS" "$HELPERS" "$RES"

echo "[build] compiling Swift sources"
swiftc -O \
  "$ROOT"/Sources/App/*.swift "$ROOT"/Sources/Shared/*.swift \
  -o "$MACOS/$APP_NAME" \
  -framework Cocoa \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework IOKit \
  -framework WebKit

echo "[build] compiling external Codex containment runner"
swiftc -O \
  "$ROOT/Tools/CodexContainmentRunner.swift" \
  -o "$HELPERS/CodexContainmentRunner"

echo "[build] compiling authenticated Codex isolation audit"
swiftc -O \
  "$ROOT/Sources/Shared/CodexIsolationFoundation.swift" \
  "$ROOT/Sources/App/AppPaths.swift" \
  "$ROOT/Sources/App/UserDataWriteFailure.swift" \
  "$ROOT/Sources/App/Log.swift" \
  "$ROOT/Sources/Shared/CodexProviderRuntime.swift" \
  "$ROOT/Tools/CodexIsolationAuthenticatedAudit.swift" \
  -o "$HELPERS/CodexIsolationAuthenticatedAudit"

echo "[build] compiling production Codex provider smoke"
swiftc -O \
  "$ROOT/Sources/Shared/CodexShippedDefaults.swift" \
  "$ROOT/Sources/Shared/CodexIsolationFoundation.swift" \
  "$ROOT/Sources/App/AppPaths.swift" \
  "$ROOT/Sources/App/UserDataWriteFailure.swift" \
  "$ROOT/Sources/App/Log.swift" \
  "$ROOT/Sources/Shared/CodexProviderRuntime.swift" \
  "$ROOT/Tools/CodexProviderSmoke.swift" \
  -o "$HELPERS/CodexProviderSmoke"

echo "[build] copying sticky-notes web bundle"
WEB_DIST="$ROOT/Web/StickyNotes/dist"
if [ ! -f "$WEB_DIST/index.html" ] || [ ! -f "$WEB_DIST/app.js" ] || [ ! -f "$WEB_DIST/app.css" ]; then
  echo "[build] ERROR: sticky-notes web bundle missing."
  echo "[build]        Run ./build-web.sh, commit Web/StickyNotes/dist, then rebuild."
  exit 1
fi
mkdir -p "$RES/StickyNotes"
cp "$WEB_DIST/index.html" "$WEB_DIST/app.js" "$WEB_DIST/app.css" "$RES/StickyNotes/"
"$MACOS/$APP_NAME" --emit-theme-css > "$RES/StickyNotes/theme.css"

echo "[build] writing Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "[build] codesign"
if [ -f "$KC" ]; then
  prepare_signing_keychain
  if codesign --force --sign "$SIGN_ID" --keychain "$KC" \
       -o runtime --entitlements "$ENTITLEMENTS" "$APP"; then
    echo "[build] signed with STABLE identity ($SIGN_ID) — TCC grants persist across rebuilds"
  else
    echo "[build] ERROR: signing keychain present but stable-identity signing FAILED."
    echo "[build]        Aborting instead of ad-hoc signing, which would silently void the app's"
    echo "[build]        Accessibility / Input-Monitoring grants. Fix the keychain and rebuild."
    echo "[build]        Do NOT re-run setup-signing.sh — that mints a NEW identity and also"
    echo "[build]        resets the grants."
    exit 1
  fi
else
  codesign --force --sign - -o runtime --entitlements "$ENTITLEMENTS" "$APP"
  echo "[build] ad-hoc signed (no signing keychain — run ./setup-signing.sh once for persistent TCC grants)"
fi

echo "[build] OK -> $APP"
echo "[build] run (GUI):     open \"$APP\""
echo "[build] run (console):  \"$MACOS/$APP_NAME\""

# ---- Verification-only sibling bundle ---------------------------------------
# Keep this outside ViddyDictate.app: install-app-agent.sh copies only the
# shipped app, so ViddyDictateTests.app can never ride along with a deployment.
TEST_APP_NAME="ViddyDictateTests"
TEST_APP="$BUILD/$TEST_APP_NAME.app"
TEST_MACOS="$TEST_APP/Contents/MacOS"
TEST_RES="$TEST_APP/Contents/Resources"

echo "[build][tests] cleaning"
rm -rf "$TEST_APP"
mkdir -p "$TEST_MACOS" "$TEST_RES"

echo "[build][tests] compiling Swift sources"
swiftc -O -D SELFTEST \
  "$ROOT"/Sources/App/*.swift "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/SelfTest/*.swift \
  -o "$TEST_MACOS/$TEST_APP_NAME" \
  -framework Cocoa \
  -framework AVFoundation \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework IOKit \
  -framework WebKit

echo "[build][tests] copying sticky-notes web bundle"
mkdir -p "$TEST_RES/StickyNotes"
cp "$WEB_DIST/index.html" "$WEB_DIST/app.js" "$WEB_DIST/app.css" "$TEST_RES/StickyNotes/"
cp "$RES/StickyNotes/theme.css" "$TEST_RES/StickyNotes/theme.css"

echo "[build][tests] writing Info.plist"
cp "$ROOT/Info-Tests.plist" "$TEST_APP/Contents/Info.plist"

echo "[build][tests] codesign"
if [ -f "$KC" ]; then
  prepare_signing_keychain
  if codesign --force --sign "$SIGN_ID" --keychain "$KC" \
       -o runtime --entitlements "$ENTITLEMENTS" "$TEST_APP"; then
    echo "[build][tests] signed with STABLE identity ($SIGN_ID) — TCC grants persist across rebuilds"
  else
    echo "[build][tests] ERROR: signing keychain present but stable-identity signing FAILED."
    echo "[build][tests]        Aborting instead of ad-hoc signing, which would silently void the"
    echo "[build][tests]        test bundle's microphone grant. Fix the keychain and rebuild."
    echo "[build][tests]        Do NOT re-run setup-signing.sh — that mints a NEW identity and also"
    echo "[build][tests]        resets the grants."
    exit 1
  fi
else
  codesign --force --sign - -o runtime --entitlements "$ENTITLEMENTS" "$TEST_APP"
  echo "[build][tests] ad-hoc signed (no signing keychain — run ./setup-signing.sh once for persistent TCC grants)"
fi

echo "[build][tests] OK -> $TEST_APP"
