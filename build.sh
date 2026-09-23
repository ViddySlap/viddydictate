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
PY_ENTITLEMENTS="$ROOT/PythonRuntime.entitlements"

# ---- The bundled Python runtime ---------------------------------------------------------------
# macOS ships no usable Python. /usr/bin/python3 is a Command-Line-Tools stub that prompts instead of
# running, so a stranger who drags this app across from a DMG has no interpreter and no repository to
# run an installer script from. Both environments the app depends on — the STT daemon venv and the
# web-search helper venv — therefore have to be created by an interpreter the app brought with it.
#
# Spec B3, and it is a promise the first-run picker makes to the user in words: the runtime lives
# INSIDE the bundle, nothing lands in /usr/local, nothing runs at login, and deleting the app deletes
# it. Nothing here may grow a fallback that installs outside the bundle.
#
# 3.12 because that is the line Ben's working stt-venv runs (3.12.13) and the one mlx-whisper is
# proven on here; the distribution is astral-sh/python-build-standalone, whose `install_only` builds
# are relocatable (the interpreter is static and carries an @executable_path/../lib rpath).
#
# Pinned by release date AND by SHA-256. The spec's O4 reasoning — never install something unverified,
# fail loudly with the real error instead — applies with more force here than it does to LM Studio,
# because this tarball is something we then sign with a Developer ID and ship to strangers.
PY_RELEASE="20260825"
PY_VERSION="3.12.14"
PY_ASSET="cpython-$PY_VERSION+$PY_RELEASE-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_SHA256="8b0f1fa71eab7ca644e482c631807a1116fa848491051cd1c8d9429491de63a6"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/$PY_ASSET"
VENDOR="$ROOT/vendor"
PY_TARBALL="$VENDOR/$PY_ASSET"
PY_UNPACKED_PARENT="$VENDOR/cpython-$PY_VERSION+$PY_RELEASE"
PY_UNPACKED="$PY_UNPACKED_PARENT/python"

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

# Prove the identity can SIGN. Measured 2026-08-29: `security find-identity -v -p codesigning
# <keychain>` lists the identity of a LOCKED keychain just as happily as an unlocked one, so the
# listing is not evidence that codesign will work — it enumerates certificates, which need no key
# material, while signing needs the private key the lock is protecting. That is why the old
# find-identity probe below never reached its own unlock branch, and why an unattended build against
# a locked keychain died with errSecInternalComponent minutes later, inside the signing step, with
# no mention of a keychain anywhere in the error.
#
# Signing a throwaway Mach-O is the only check whose success means what the caller needs it to mean.
# /usr/bin/true rather than a compiled probe: it is a real signable Mach-O, it is always present, and
# it needs no toolchain, so this works in the scratch-HOME verification tier too.
signing_identity_can_sign() {
  probe_dir="$(mktemp -d)"
  cp /usr/bin/true "$probe_dir/probe" 2>/dev/null || { rm -rf "$probe_dir"; return 1; }
  chmod u+w "$probe_dir/probe"
  if codesign --force --sign "$SIGN_ID" --keychain "$KC" "$probe_dir/probe" >/dev/null 2>&1; then
    rm -rf "$probe_dir"
    return 0
  fi
  rm -rf "$probe_dir"
  return 1
}

# Make the signing keychain usable, prompting only when it is actually necessary.
#
# Order matters. Probe first, unlock only if the probe fails, and re-probe before concluding trust is
# broken. Without that, a hardened (lockable) keychain would trigger the trust heal on every build.
prepare_signing_keychain() {
  # codesign resolves identities through the keychain SEARCH LIST; `--keychain` does not add one
  # (measured 2026-08-16). A keychain missing from the list signs nothing and reports the very
  # confusing "no identity found" while find-identity happily lists it. Ensure membership first,
  # appending so login/System/other signing keychains survive. Needs no keychain password.
  # Exact-line membership by shell pattern rather than `| grep -qxF`, which under `pipefail`
  # reports 141 when grep matches and exits before its producer has finished writing.
  kc_list="$(security list-keychains -d user | sed 's/[[:space:]]*"//;s/"$//')"
  case "
$kc_list
" in
    *"
$KC
"*) ;;
    *)
      echo "[build] adding the signing keychain to the search list"
      # shellcheck disable=SC2046,SC2086
      security list-keychains -d user -s $(printf '%s ' $kc_list) "$KC"
      ;;
  esac

  # Explicit ifs, not && chains: under `set -e` a failing && list is a foot-gun here.
  if signing_identity_can_sign; then
    return 0
  fi

  # Legacy keychains (pre-hardening) carry a password published in this repo's history, so try it
  # and keep those installs building unattended. A hardened keychain rejects it, and macOS then asks
  # the user for the password they chose at setup.
  if ! security unlock-keychain -p "vd-signing-local" "$KC" 2>/dev/null; then
    security unlock-keychain "$KC"
  fi

  if signing_identity_can_sign; then
    return 0
  fi

  # Still unable to sign with the keychain unlocked, so this is the trust-settings wipe. Re-bless the
  # existing cert. NEVER mint a new one; that resets the TCC grants.
  echo "[build] stable identity not trusted (trust-settings wipe?) — restoring trust"
  HEAL_PEM="$(mktemp)"
  security find-certificate -c "$SIGN_ID" -p "$KC" > "$HEAL_PEM"
  # -r trustRoot: the cert IS the root, so it must be blessed as one. No -k: trust settings belong
  # in the user trust domain where evaluation happens, not inside the app-specific keychain, which
  # is where this used to write them. Failure is reported rather than swallowed by `|| true`.
  if ! security add-trusted-cert -r trustRoot -p codeSign "$HEAL_PEM"; then
    echo "[build] WARNING: could not restore trust for $SIGN_ID (needs your authorization)."
  fi
  rm -f "$HEAL_PEM"

  # Say so here rather than letting the build die inside codesign. Every remedy this function has is
  # spent by now, so a third failure is a real problem the person running the build has to see.
  if ! signing_identity_can_sign; then
    echo "[build] WARNING: $SIGN_ID still cannot sign after unlocking and restoring trust."
    echo "[build]          The signing step below will fail. See docs/signing-and-tcc.md."
  fi
}

# Put the pinned interpreter in vendor/ (gitignored), verified, exactly once. Cached like
# node_modules is: present after the first build, so every later build — including the deterministic
# verification tier, which is meant to be offline — needs no network. VD_PYTHON_TARBALL lets an
# air-gapped or CI build supply the same file by hand; it is still hash-checked, because a local file
# is not more trustworthy than a downloaded one, only more convenient.
fetch_bundled_python() {
  if [ -x "$PY_UNPACKED/bin/python3" ]; then
    return 0
  fi
  mkdir -p "$VENDOR"

  if [ ! -f "$PY_TARBALL" ]; then
    if [ -n "${VD_PYTHON_TARBALL:-}" ]; then
      echo "[build] using VD_PYTHON_TARBALL -> $VD_PYTHON_TARBALL"
      cp "$VD_PYTHON_TARBALL" "$PY_TARBALL"
    else
      echo "[build] downloading the bundled Python runtime (~25 MB, cached in vendor/)"
      echo "[build]     $PY_URL"
      if ! curl -fSL --retry 3 --connect-timeout 15 -o "$PY_TARBALL.part" "$PY_URL"; then
        rm -f "$PY_TARBALL.part"
        echo "[build] ERROR: could not download the bundled Python runtime."
        echo "[build]        The app cannot be built without it — macOS has no usable python3 and the"
        echo "[build]        bundle is where ours lives. Either restore network access, or hand the"
        echo "[build]        tarball over directly:"
        echo "[build]            VD_PYTHON_TARBALL=/path/to/$PY_ASSET ./build.sh"
        exit 1
      fi
      mv "$PY_TARBALL.part" "$PY_TARBALL"
    fi
  fi

  actual_sha="$(shasum -a 256 "$PY_TARBALL" | awk '{print $1}')"
  if [ "$actual_sha" != "$PY_SHA256" ]; then
    rm -f "$PY_TARBALL"
    echo "[build] ERROR: SHA-256 mismatch on the bundled Python runtime. The cached copy was deleted."
    echo "[build]        expected $PY_SHA256"
    echo "[build]        actual   $actual_sha"
    echo "[build]        Refusing to bundle an unverified interpreter into an app we sign and ship."
    exit 1
  fi

  echo "[build] unpacking the bundled Python runtime -> $PY_UNPACKED"
  rm -rf "$PY_UNPACKED_PARENT"
  mkdir -p "$PY_UNPACKED_PARENT"
  tar -xzf "$PY_TARBALL" -C "$PY_UNPACKED_PARENT"
  if [ ! -x "$PY_UNPACKED/bin/python3" ]; then
    echo "[build] ERROR: the unpacked runtime has no bin/python3 at $PY_UNPACKED"
    exit 1
  fi
}

# ditto rather than cp -R: it preserves the symlinks (bin/python3 -> python3.12) and the exec bits
# that make the tree relocatable, and copying those wrong is a failure that only shows up at the
# first dictation on somebody else's Mac.
stage_bundled_python() {
  res="$1"; tag="$2"
  fetch_bundled_python
  rm -rf "$res/python"
  ditto "$PY_UNPACKED" "$res/python"

  # Precompile the stdlib BEFORE signing, because otherwise the interpreter breaks the app's own seal
  # the first time it runs. Measured here, not guessed: a single `python -m venv` dropped 171 .pyc
  # files into the signed bundle and turned `codesign --verify` from OK into "a sealed resource is
  # missing or invalid". That is not a theoretical Gatekeeper problem — install-app-agent.sh deploys
  # to ~/Applications, which the user can write, so it is the app's own first run that does it.
  #
  # unchecked-hash rather than the default timestamp invalidation: copying the tree changes mtimes,
  # and a .pyc that looks stale gets rewritten, which is the same broken seal by a slower route. With
  # this, re-running the whole flow leaves the tree byte-for-byte identical (verified).
  echo "$tag precompiling the bundled stdlib (a signed bundle must not be written to at runtime)"
  "$res/python/bin/python3" -m compileall -q -f --invalidation-mode unchecked-hash \
    "$res/python/lib/python${PY_VERSION%.*}" >/dev/null

  echo "$tag bundled Python $PY_VERSION -> Contents/Resources/python ($(du -sh "$res/python" | awk '{print $1}'))"
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

# The transcription daemon ships INSIDE the app: a DMG-only Mac has no repository to run
# install-daemon.sh from, so the app itself stages this script and its LaunchAgent template and
# installs them into the user's home on first run / update. Plain cp, byte-identical to the repo copy.
mkdir -p "$RES/daemon"
cp "$ROOT/viddydictate_whisperd.py" "$ROOT/com.viddydictate.whisperd.plist" "$RES/daemon/"

echo "[build] writing Info.plist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# release.sh stamps a version here rather than committing one, so the source Info.plist stays the
# single development value and a release is not a dirty tree. Stamped BEFORE signing, because the
# plist is part of what the signature covers.
if [ -n "${VD_APP_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VD_APP_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VD_APP_VERSION" "$APP/Contents/Info.plist"
  echo "[build] stamped version $VD_APP_VERSION"
fi

# Sign one bundle. Three paths, highest priority first:
#
#   1. VD_SIGN_IDENTITY is set  -> RELEASE signing. release.sh sets this to a Developer ID cert's
#      SHA-1 hash. It passes a HASH and not a name deliberately: two certs can share a common name,
#      and `--keychain` does NOT disambiguate them. Proven 2026-08-16 - a sign explicitly scoped to
#      one keychain used a same-named cert from the search list instead, and the only tell was the
#      leaf hash in the designated requirement. A hash cannot be ambiguous.
#      Adds `--timestamp`, which notarization requires and the local path does not need.
#   2. the self-signed keychain exists -> the stable LOCAL identity (TCC grants survive rebuilds).
#   3. neither -> ad-hoc, and the grants reset every build.
#
# Resolved ONCE per build, into SIGN_MODE plus the codesign arguments that select the identity, so
# the bundle, the helper executables and the bundled Python runtime cannot end up signed by three
# different identities. Explicit ifs, not && chains: under `set -e` a failing && list is a foot-gun.
SIGN_MODE=""
SIGN_ARGS=()

resolve_signing_mode() {
  if [ -n "$SIGN_MODE" ]; then
    return 0
  fi
  if [ -n "${VD_SIGN_IDENTITY:-}" ]; then
    SIGN_MODE="release"
    SIGN_ARGS=(--sign "$VD_SIGN_IDENTITY" --timestamp)
    return 0
  fi
  if [ -f "$KC" ]; then
    prepare_signing_keychain
    SIGN_MODE="stable"
    SIGN_ARGS=(--sign "$SIGN_ID" --keychain "$KC")
    return 0
  fi
  SIGN_MODE="adhoc"
  SIGN_ARGS=(--sign -)
}

sign_failure_note() {
  tag="$1"
  case "$SIGN_MODE" in
    release)
      echo "$tag ERROR: VD_SIGN_IDENTITY is set but release signing FAILED."
      echo "$tag        Refusing to fall back to a local or ad-hoc identity, which would produce a"
      echo "$tag        bundle that cannot be notarized and would not be obvious downstream."
      ;;
    stable)
      echo "$tag ERROR: signing keychain present but stable-identity signing FAILED."
      echo "$tag        Aborting instead of ad-hoc signing, which would silently void the app's"
      echo "$tag        Accessibility / Input-Monitoring grants. Fix the keychain and rebuild."
      echo "$tag        Do NOT re-run setup-signing.sh — that mints a NEW identity and also"
      echo "$tag        resets the grants."
      ;;
    *)
      echo "$tag ERROR: ad-hoc signing FAILED."
      ;;
  esac
}

# Sign every Mach-O nested inside the bundle, with the SAME identity and the hardened runtime.
#
# This is not belt-and-braces. Notarization refuses a submission in which any Mach-O is unsigned,
# signed by somebody else, or missing the hardened runtime — and `codesign --verify --deep --strict`
# does NOT catch that, which is the trap. Measured on 5391750, before this existed: the three
# Contents/Helpers binaries were linker-signed ad-hoc, --deep --strict reported the bundle valid, and
# Apple would have rejected the release. That is exactly the class of failure this chain exists to
# find at build time rather than at release.sh time. The bundled Python adds eleven more Mach-Os
# (fewer than the "hundreds of .so files" the findings note predicted — python-build-standalone links
# most extension modules straight into the interpreter).
#
# Order matters: nested first, bundle last. codesign seals what it finds at sign time, so re-signing
# an inner file afterwards invalidates the outer seal.
sign_nested_mach_o() {
  bundle="$1"; tag="$2"
  contents="$bundle/Contents"
  listing="$(mktemp)"

  # One `file` pass over the whole tree. On a 1,650-file Python distribution the per-file process
  # spawns cost several times what the signing itself does. -type f skips symlinks, so nothing is
  # signed twice through an alias, and Contents/MacOS is left out because the bundle signature covers
  # the main executable with the app's own entitlements.
  find "$contents" -type f -not -path "$contents/MacOS/*" -print0 \
    | xargs -0 file -F '|' --no-dereference \
    | awk -F '|' '$2 ~ /Mach-O/ { print $1 }' > "$listing"

  runtime_machos=()
  helper_machos=()
  while IFS= read -r macho; do
    [ -n "$macho" ] || continue
    if [ ! -f "$macho" ]; then
      rm -f "$listing"
      echo "$tag ERROR: the Mach-O scan produced a path that is not a file:"
      echo "$tag            $macho"
      echo "$tag        A '|' in a filename would do this. Refusing to sign a partial set, because a"
      echo "$tag        missed Mach-O is invisible until Apple rejects the notarization."
      exit 1
    fi
    case "$macho" in
      "$contents"/Resources/python/*) runtime_machos+=("$macho") ;;
      *) helper_machos+=("$macho") ;;
    esac
  done < "$listing"
  rm -f "$listing"

  # bash 3.2: expanding an empty array under `set -u` is an error, hence the counts.
  if [ "${#helper_machos[@]}" -gt 0 ]; then
    if ! codesign --force "${SIGN_ARGS[@]}" -o runtime "${helper_machos[@]}"; then
      echo "$tag ERROR: signing the nested helper executables failed."
      sign_failure_note "$tag"
      exit 1
    fi
    echo "$tag signed ${#helper_machos[@]} nested helper Mach-O file(s) — hardened runtime"
  fi

  if [ "${#runtime_machos[@]}" -gt 0 ]; then
    if ! codesign --force "${SIGN_ARGS[@]}" -o runtime --entitlements "$PY_ENTITLEMENTS" \
         "${runtime_machos[@]}"; then
      echo "$tag ERROR: signing the bundled Python runtime failed."
      sign_failure_note "$tag"
      exit 1
    fi
    echo "$tag signed ${#runtime_machos[@]} bundled-Python Mach-O file(s) — hardened runtime + PythonRuntime.entitlements"
  fi
}

sign_bundle() {
  bundle="$1"; tag="$2"
  resolve_signing_mode
  sign_nested_mach_o "$bundle" "$tag"

  if ! codesign --force "${SIGN_ARGS[@]}" -o runtime --entitlements "$ENTITLEMENTS" "$bundle"; then
    sign_failure_note "$tag"
    exit 1
  fi

  case "$SIGN_MODE" in
    release) echo "$tag signed for RELEASE ($VD_SIGN_IDENTITY), hardened runtime + secure timestamp" ;;
    stable)  echo "$tag signed with STABLE identity ($SIGN_ID) — TCC grants persist across rebuilds" ;;
    *)       echo "$tag ad-hoc signed (no signing keychain — run ./setup-signing.sh once for persistent TCC grants)" ;;
  esac

  # What notarization will do, done now. release.sh checks this too, but by then the build is spent
  # and the failure is expensive; a broken seal is cheapest to find in the build that caused it.
  if ! codesign --verify --deep --strict "$bundle"; then
    echo "$tag ERROR: the sealed bundle does not verify. Notarization would reject it."
    exit 1
  fi
  echo "$tag codesign --verify --deep --strict OK"
}

stage_bundled_python "$RES" "[build]"

echo "[build] codesign"
sign_bundle "$APP" "[build]"

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

# Same staged daemon as the shipping bundle: the selftests below assert the installed bytes match the
# bundled bytes, so the verification bundle must carry an identical copy.
mkdir -p "$TEST_RES/daemon"
cp "$ROOT/viddydictate_whisperd.py" "$ROOT/com.viddydictate.whisperd.plist" "$TEST_RES/daemon/"

echo "[build][tests] writing Info.plist"
cp "$ROOT/Info-Tests.plist" "$TEST_APP/Contents/Info.plist"

# The verification bundle gets the same runtime as the shipped one. Two bundles that differ in what
# they contain is how a gate goes green over an app that is broken: every selftest that reaches for
# the interpreter would be reaching for something the shipped app has and the test app does not.
stage_bundled_python "$TEST_RES" "[build][tests]"

echo "[build][tests] codesign"
sign_bundle "$TEST_APP" "[build][tests]"

echo "[build][tests] OK -> $TEST_APP"
