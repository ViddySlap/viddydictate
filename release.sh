#!/usr/bin/env bash
# Build, sign, notarize, staple and package a distributable ViddyDictate release.
#
#   ./release.sh 1.0.0
#
# Produces dist/ViddyDictate-<version>.dmg, notarized and stapled, that any Apple Silicon Mac can
# download and open with no Gatekeeper warning, no Xcode, no signing setup, and no build step.
# That is the whole point: a released .dmg replaces the entire clone-and-compile path for ordinary
# users, and with it setup-signing.sh, the self-signed identity, and its security tradeoff
# (docs/signing-and-tcc.md).
#
# Requires a Developer ID Application certificate and a stored notarytool credential profile.
# Both are one-time, human-only setup steps; see docs/releasing.md. This script refuses clearly
# rather than falling back when either is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ViddyDictate"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
DIST="$ROOT/dist"
NOTARY_PROFILE="${VD_NOTARY_PROFILE:-viddydictate-notary}"
STAGE="$DIST/stage"

die() { echo "[release] ERROR: $*" >&2; exit 1; }
step() { echo; echo "[release] ===== $* ====="; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: ./release.sh <version>   (e.g. ./release.sh 1.0.0)"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "version should look like 1.0.0, got '$VERSION'" ;;
esac

# ---- Preflight ---------------------------------------------------------------------------------
step "preflight"

[ "$(uname -m)" = "arm64" ] || die "releases are built on Apple Silicon only"

# A release must be reproducible from a commit, so refuse to ship uncommitted work.
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null || true)" ]; then
  die "working tree is dirty. Commit or stash first; a release must be traceable to a commit."
fi
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Resolve the Developer ID identity to its SHA-1 HASH, never its name. Two certs can share a common
# name and `--keychain` does NOT disambiguate them (proven 2026-08-16: a sign scoped to one keychain
# silently used a same-named cert from the search list, detectable only in the leaf hash of the
# designated requirement). A hash cannot be ambiguous, so that whole class of mistake disappears.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
COUNT="$(printf '%s\n' "$IDENTITIES" | grep -c . || true)"

if [ "$COUNT" -eq 0 ]; then
  echo "[release] No 'Developer ID Application' certificate is installed."
  echo "[release]"
  echo "[release] This is the one thing a release cannot be faked without. See docs/releasing.md;"
  echo "[release] the short version is: enroll in the Apple Developer Program, create a Developer ID"
  echo "[release] Application certificate, and install it. Then re-run this script."
  echo "[release]"
  echo "[release] For a LOCAL build with no Developer ID, use ./build.sh instead - it self-signs."
  exit 1
fi

if [ -n "${VD_RELEASE_IDENTITY:-}" ]; then
  SIGN_HASH="$VD_RELEASE_IDENTITY"
elif [ "$COUNT" -eq 1 ]; then
  SIGN_HASH="$(printf '%s\n' "$IDENTITIES" | grep -oE '[0-9A-F]{40}' | head -n 1)"
else
  echo "[release] More than one Developer ID Application certificate is installed:"
  printf '%s\n' "$IDENTITIES" | sed 's/^/[release]     /'
  echo "[release]"
  echo "[release] Refusing to guess. Re-run with the one you mean, by hash:"
  echo "[release]     VD_RELEASE_IDENTITY=<40-char-hash> ./release.sh $VERSION"
  exit 1
fi
SIGN_DESC="$(printf '%s\n' "$IDENTITIES" | grep -F "$SIGN_HASH" | sed 's/^ *[0-9]*) *//')"
echo "[release] signing identity: $SIGN_DESC"

command -v xcrun >/dev/null || die "xcrun not found (install Apple Command Line Tools)"
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode or recent Command Line Tools)"
xcrun --find stapler   >/dev/null 2>&1 || die "stapler not found (needs Xcode or recent Command Line Tools)"

# Cheap local check that the credential profile exists at all, before spending a build on it.
if ! security find-generic-password -s "com.apple.gke.notary.tool" >/dev/null 2>&1; then
  echo "[release] WARNING: no stored notarytool credentials found in the login keychain."
  echo "[release]          If submission fails with an auth error, create the profile once with:"
  echo "[release]              xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
  echo "[release]                --apple-id <your-apple-id> --team-id <your-team-id>"
  echo "[release]          It will prompt for an app-specific password from appleid.apple.com."
  echo "[release]          Type it into that prompt yourself; never put it in a script or a file."
fi

# ---- Gate --------------------------------------------------------------------------------------
if [ "${VD_SKIP_VERIFY:-0}" = "1" ]; then
  echo "[release] SKIPPING the verification gate (VD_SKIP_VERIFY=1). Do not ship this."
else
  step "verification gate (deterministic tier)"
  ( cd "$ROOT" && ./scripts/verify.sh deterministic ) || die "verification gate failed; not releasing"
fi

# ---- Build + sign ------------------------------------------------------------------------------
step "building and signing $VERSION with the Developer ID"
rm -rf "$DIST"
mkdir -p "$STAGE"
VD_SIGN_IDENTITY="$SIGN_HASH" VD_APP_VERSION="$VERSION" "$ROOT/build.sh"

step "verifying the signature before we spend a notarization on it"
codesign --verify --deep --strict --verbose=2 "$APP" || die "signature verification failed"

# The designated requirement must now anchor to Apple, not to a local leaf hash. This is the single
# clearest signal that the release identity was actually used and not silently swapped.
DR="$(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
echo "[release] DR: $DR"
case "$DR" in
  *"anchor apple generic"*) : ;;
  *) die "designated requirement does not anchor to Apple. The Developer ID was not used: $DR" ;;
esac

codesign -dv "$APP" 2>&1 | grep -q "flags=0x10000(runtime)" \
  || die "hardened runtime missing; notarization would reject this"
echo "[release] hardened runtime confirmed"

# ---- Notarize the app itself -------------------------------------------------------------------
# Done in addition to the DMG so the .app carries its own stapled ticket. A DMG-only staple still
# validates, but only while Gatekeeper can reach Apple; a stapled .app validates offline and keeps
# working after the user drags it out of the disk image.
step "notarizing the app"
APP_ZIP="$DIST/$APP_NAME-$VERSION-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  || die "app notarization failed (run: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE)"
xcrun stapler staple "$APP" || die "stapling the app failed"
rm -f "$APP_ZIP"
echo "[release] app notarized and stapled"

# ---- Package the DMG ---------------------------------------------------------------------------
step "packaging the disk image"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # the familiar drag-to-install layout
DMG="$DIST/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --sign "$SIGN_HASH" --timestamp "$DMG" || die "signing the DMG failed"

step "notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
  || die "DMG notarization failed (run: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE)"
xcrun stapler staple "$DMG" || die "stapling the DMG failed"

# ---- Verify the artifact the way a downloader's Mac will ---------------------------------------
step "verifying as an end user's Mac would"
xcrun stapler validate "$DMG" || die "stapler validate failed on the DMG"
xcrun stapler validate "$APP" || die "stapler validate failed on the app"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/[release]     /' \
  || die "Gatekeeper rejected the DMG"
spctl -a -vvv "$APP" 2>&1 | sed 's/^/[release]     /' || die "Gatekeeper rejected the app"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
cat <<DONE

[release] ===== DONE =====
[release] artifact : $DMG  ($SIZE)
[release] version  : $VERSION   commit: $COMMIT
[release] identity : $SIGN_DESC
[release]
[release] Notarized and stapled, both the app and the disk image, so it opens with no warning and
[release] validates offline. Nothing about this build depends on setup-signing.sh.
[release]
[release] Next, and both are yours to do deliberately:
[release]   git tag -a v$VERSION -m "ViddyDictate $VERSION" && git push origin v$VERSION
[release]   then attach $(basename "$DMG") to a GitHub release.
[release]
[release] Sanity-check it the way a stranger would before publishing: copy the DMG to a different
[release] Mac (or a fresh account), open it, drag the app across, and launch. A Gatekeeper prompt
[release] there means the staple did not take, and it is far better to find that yourself.
DONE
