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
KC="$HOME/Library/Keychains/vd-signing.keychain-db"
SIGN_ID="ViddyDictate Self-Signed"
if [ -f "$KC" ]; then
  # Self-heal (2026-07-13 incident): a macOS update can wipe the user trust-settings store, which
  # flips the stable identity to CSSMERR_TP_NOT_TRUSTED and would make signing fail. Re-bless the
  # existing cert (NEVER mint a new one — that resets the TCC grants) before signing.
  if ! security find-identity -v -p codesigning "$KC" | grep -q "$SIGN_ID"; then
    echo "[build] stable identity not trusted (trust-settings wipe?) — restoring trust"
    HEAL_PEM="$(mktemp)"
    security find-certificate -c "$SIGN_ID" -p "$KC" > "$HEAL_PEM"
    security add-trusted-cert -p codeSign -k "$KC" "$HEAL_PEM" || true
    rm -f "$HEAL_PEM"
  fi
  security unlock-keychain -p "vd-signing-local" "$KC"
  if codesign --force --sign "$SIGN_ID" --keychain "$KC" "$APP"; then
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
  codesign --force --sign - "$APP"
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
  # Apply the same stable-identity self-heal used by the shipped app so this bundle's own TCC
  # grants survive rebuilds. Never mint a replacement identity here.
  if ! security find-identity -v -p codesigning "$KC" | grep -q "$SIGN_ID"; then
    echo "[build][tests] stable identity not trusted (trust-settings wipe?) — restoring trust"
    HEAL_PEM="$(mktemp)"
    security find-certificate -c "$SIGN_ID" -p "$KC" > "$HEAL_PEM"
    security add-trusted-cert -p codeSign -k "$KC" "$HEAL_PEM" || true
    rm -f "$HEAL_PEM"
  fi
  security unlock-keychain -p "vd-signing-local" "$KC"
  if codesign --force --sign "$SIGN_ID" --keychain "$KC" "$TEST_APP"; then
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
  codesign --force --sign - "$TEST_APP"
  echo "[build][tests] ad-hoc signed (no signing keychain — run ./setup-signing.sh once for persistent TCC grants)"
fi

echo "[build][tests] OK -> $TEST_APP"
