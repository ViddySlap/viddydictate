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

# The Team ID is the parenthesised suffix of a Developer ID common name, and it is what every signed
# Mach-O in the shipped bundle has to carry. Extracted here so the nested sweep below can assert it.
TEAM_ID="$(printf '%s\n' "$SIGN_DESC" | sed -n 's/.*(\([A-Z0-9]\{10\}\))"*$/\1/p')"
[ -n "$TEAM_ID" ] || die "could not read a Team ID out of the identity name: $SIGN_DESC"
echo "[release] team identifier: $TEAM_ID"

command -v xcrun >/dev/null || die "xcrun not found (install Apple Command Line Tools)"
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode or recent Command Line Tools)"
xcrun --find stapler   >/dev/null 2>&1 || die "stapler not found (needs Xcode or recent Command Line Tools)"

# Check the credential profile BEFORE spending a build on it — and check the thing that matters,
# which is whether notarytool can authenticate, not whether a keychain item exists.
#
# This used to grep the login keychain for a "com.apple.gke.notary.tool" generic password. That check
# is obsolete and was a permanent false negative here (measured 2026-08-29: the profile authenticates
# and submits, and `security find-generic-password` finds nothing in any keychain on the search
# list). notarytool stores profiles in the data-protection keychain, which the `security` CLI cannot
# see at all. A preflight that always warns teaches the operator to ignore preflight warnings, which
# is worse than having none.
#
# `notarytool history` is one authenticated round trip, seconds, and it is the same credential path
# the two submissions below use. An auth failure is fatal here — it costs a whole build otherwise —
# but a network failure is not, because the release may well be cut on bad hotel wifi and the
# submissions do their own retrying.
step "checking the notarization credential"
NOTARY_CHECK="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)" && NOTARY_RC=0 || NOTARY_RC=$?
if [ "$NOTARY_RC" -eq 0 ]; then
  echo "[release] notarytool profile '$NOTARY_PROFILE' authenticates"
elif printf '%s' "$NOTARY_CHECK" | grep -iE "could not find|no keychain profile|unable to (find|load)|not found" >/dev/null; then
  echo "[release] No stored notarytool credential profile named '$NOTARY_PROFILE'."
  echo "[release]"
  echo "[release] Create it once, and type the password into its prompt yourself — never put an"
  echo "[release] app-specific password into a script, a file, or a chat window:"
  echo "[release]     xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
  echo "[release]       --apple-id <your-apple-id> --team-id <your-team-id>"
  echo "[release]"
  printf '%s\n' "$NOTARY_CHECK" | sed 's/^/[release]     /'
  exit 1
elif printf '%s' "$NOTARY_CHECK" | grep -iE "unauthorized|authentication|invalid|forbidden|password" >/dev/null; then
  echo "[release] The notarytool profile '$NOTARY_PROFILE' exists but Apple rejected it."
  echo "[release] Re-create it (app-specific passwords are revoked when the Apple ID password changes):"
  echo "[release]     xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id <team>"
  echo "[release]"
  printf '%s\n' "$NOTARY_CHECK" | sed 's/^/[release]     /'
  exit 1
else
  echo "[release] WARNING: could not reach Apple to check the notarization credential."
  echo "[release]          Continuing — the submissions below will surface the real problem."
  printf '%s\n' "$NOTARY_CHECK" | sed 's/^/[release]     /'
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

# Captured, then matched. NOT `codesign -dv | grep -q`, which is what this was and which failed a
# perfectly good 1.0.0 build on the first real run of this pipeline: `grep -q` exits the moment it
# matches, closing the pipe; codesign is still writing the seven lines that follow CodeDirectory and
# dies of SIGPIPE; `pipefail` then reports 141 for the pipeline, so a SUCCESSFUL match arrives as a
# failure. The bundle was hardened the whole time. Worse, `2>&1` had fed codesign's own stderr into
# grep, so the error message that would have explained it was swallowed too.
#
# Every `producer | grep -q` under `set -o pipefail` has this shape. See install-app-agent.sh, where
# the same construct inverted a safety check rather than merely tripping one.
APP_SIG_INFO="$(codesign -dv "$APP" 2>&1 || true)"
case "$APP_SIG_INFO" in
  *"flags=0x10000(runtime)"*) ;;
  *)
    printf '%s\n' "$APP_SIG_INFO" | sed 's/^/[release]     /'
    die "hardened runtime missing; notarization would reject this"
    ;;
esac
echo "[release] hardened runtime confirmed"

# Every check above inspects the OUTER bundle only, and that is not enough. Notarization refuses a
# submission in which any nested Mach-O is unsigned, signed by another identity, or missing the
# hardened runtime — and `codesign --verify --deep --strict` reports such a bundle VALID. That is not
# hypothetical: on 5391750 the three Contents/Helpers binaries were linker-signed ad-hoc, --deep
# --strict passed, and Apple would have rejected the release (see build.sh sign_nested_mach_o).
#
# build.sh signs them correctly now. This re-checks the artifact actually being shipped rather than
# trusting the script that produced it, because the whole cost of being wrong lands minutes later on
# an Apple round trip, and the failure Apple reports names a file, not a cause.
step "verifying every nested Mach-O in the bundle"
NESTED_LIST="$(mktemp)"
find "$APP/Contents" -type f -not -path "$APP/Contents/MacOS/*" -print0 \
  | xargs -0 file -F '|' --no-dereference \
  | awk -F '|' '$2 ~ /Mach-O/ { print $1 }' > "$NESTED_LIST"

NESTED_TOTAL=0
NESTED_BAD=0
while IFS= read -r macho; do
  [ -n "$macho" ] || continue
  NESTED_TOTAL=$((NESTED_TOTAL + 1))
  info="$(codesign -dv --verbose=4 "$macho" 2>&1 || true)"
  rel="${macho#"$APP/"}"
  case "$info" in
    *"flags=0x10000(runtime)"*) ;;
    *) echo "[release]     NO HARDENED RUNTIME: $rel"; NESTED_BAD=$((NESTED_BAD + 1)); continue ;;
  esac
  # Identity, not by name. `codesign -dv` never prints the certificate's SHA-1, so the hash the
  # identity was SELECTED by is not available here; the two facts that ARE available and cannot be
  # produced by a local or ad-hoc signature are the Apple anchor in the designated requirement and
  # the Team ID. A self-signed nested binary anchors to its own leaf and carries "TeamIdentifier=not
  # set" — measured on the stable-signed build, which is exactly the mistake being guarded against.
  case "$info" in
    *"TeamIdentifier=$TEAM_ID"*) ;;
    *) echo "[release]     WRONG OR MISSING TEAM IDENTIFIER: $rel"; NESTED_BAD=$((NESTED_BAD + 1)); continue ;;
  esac
  nested_dr="$(codesign -d -r- "$macho" 2>&1 || true)"
  case "$nested_dr" in
    *"anchor apple generic"*) ;;
    *) echo "[release]     DESIGNATED REQUIREMENT DOES NOT ANCHOR TO APPLE: $rel"; NESTED_BAD=$((NESTED_BAD + 1)) ;;
  esac
done < "$NESTED_LIST"
rm -f "$NESTED_LIST"

[ "$NESTED_TOTAL" -gt 0 ] || die "found no nested Mach-O files at all — the bundle scan is broken, not the bundle"
[ "$NESTED_BAD" -eq 0 ] || die "$NESTED_BAD of $NESTED_TOTAL nested Mach-O file(s) would fail notarization"
echo "[release] $NESTED_TOTAL nested Mach-O file(s): hardened runtime + release identity, all of them"

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

# Retried, because this step is not reliable and it fails EXPENSIVELY. hdiutil builds the image by
# mounting a scratch volume under /Volumes and copying the source into it, and that copy can come
# back "Operation not permitted" against a freshly notarized-and-stapled bundle - observed
# 2026-08-30, then succeeding immediately on an identical retry with the same staged input. The cost
# of not retrying is not a rerun of this line: by the time packaging starts, the app notarization has
# already been submitted, waited on, and stapled, so a transient failure here throws away a complete
# Apple round trip.
#
# Bounded and loud. A permission problem that is real must still fail the release rather than be
# papered over by three attempts, so every retry says so and the last failure is fatal.
dmg_created=0
for attempt in 1 2 3; do
  if hdiutil_err="$(hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
       -ov -format UDZO "$DMG" 2>&1 >/dev/null)"; then
    dmg_created=1
    [ "$attempt" -eq 1 ] || echo "[release] disk image created on attempt $attempt"
    break
  fi
  echo "[release] hdiutil attempt $attempt/3 failed:"
  printf '%s\n' "$hdiutil_err" | sed 's/^/[release]     /'
  rm -f "$DMG"
  sleep 5
done
[ "$dmg_created" -eq 1 ] || die "could not create the disk image after 3 attempts (the app notarization above is already spent; re-running this script is safe)"

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
