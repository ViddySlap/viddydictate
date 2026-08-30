#!/usr/bin/env bash
# Copy everything ViddyDictate holds that a person would be sorry to lose, into one folder they can
# put somewhere safe before uninstalling, migrating to a new Mac, or reinstalling from a DMG.
#
#   ./scripts/backup-user-data.sh                     -> ~/Desktop/ViddyDictate-backup-<timestamp>
#   ./scripts/backup-user-data.sh /Volumes/Backup/vd  -> that folder
#   ./scripts/backup-user-data.sh --list              -> print what would be copied, copy nothing
#
# Nothing here is destructive: it only reads the live data and writes to the destination.
#
# What gets copied is an ALLOW LIST, not everything minus a few exclusions, and that is deliberate in
# two directions. It keeps 2.7 GB of rebuildable machinery (the Python venvs, the vendored Codex
# binaries) out of a backup that is supposed to be portable, and — the part that matters more — it
# means a file a future version starts writing cannot silently end up in a folder the user drops in
# Dropbox. `codex-home` is the concrete case: it holds a provider login, and a login does not belong
# in a backup folder. Re-authenticating costs one click; leaking a token does not.
#
# Everything NOT copied is still named in MANIFEST.txt with the reason, so a new unclassified file
# shows up as a visible "skipped" line rather than disappearing quietly.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/ViddyDictate"
SHARE="$HOME/.local/share/viddydictate"
PREFS="$HOME/Library/Preferences/com.viddydictate.app.plist"

# name:reason for everything under Application Support that we deliberately leave behind.
SKIP_REASONS="
stt-venv:rebuilt by the app on first run (1 GB+)
venv:rebuilt by the app on first run
codex-executables:vendored provider binaries, re-downloaded on demand (1.5 GB+)
codex-home:CONTAINS A PROVIDER LOGIN - never copied into a backup folder
codex-runners:scratch state for in-flight provider runs
codex-cwd:scratch working directory
codex-model-catalog.json:regenerated from the provider on demand
codex-update-outcome.json:regenerated from the provider on demand
model-freshness.json:regenerated from the provider on demand
viddydictate_whisperd.py:installed from the repo, not user data
claude-sign-in.command:generated helper, not user data
.codex-compatibility.lock:lock file
.DS_Store:Finder metadata
"

# The things worth keeping, in the order a person would care about them.
KEEP="
history.json
history
recordings
sticky-notes
dictionary.json
custom-modes.json
sticky-skills.json
models-power.json
clipboard-history.json
file-backups
bootstrap.json
"

LIST_ONLY=0
DEST=""
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "[backup] unknown option: $arg" >&2; exit 2 ;;
    *) DEST="$arg" ;;
  esac
done

if [ ! -d "$SUPPORT" ]; then
  echo "[backup] Nothing to back up: $SUPPORT does not exist."
  echo "[backup] ViddyDictate has either never run on this account or has already been removed."
  exit 0
fi

human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

skip_reason() {
  printf '%s\n' "$SKIP_REASONS" | while IFS=: read -r name reason; do
    [ -n "$name" ] || continue
    if [ "$name" = "$1" ]; then printf '%s' "$reason"; return; fi
  done
}

# ---- Report ------------------------------------------------------------------------------------
echo "[backup] source: $SUPPORT ($(human "$SUPPORT"))"
echo "[backup]"
echo "[backup] WILL COPY"
for name in $KEEP; do
  if [ -e "$SUPPORT/$name" ]; then
    printf '[backup]     %-24s %s\n' "$name" "$(human "$SUPPORT/$name")"
  fi
done
[ -f "$PREFS" ] && printf '[backup]     %-24s %s\n' "settings.plist" "$(human "$PREFS")"
[ -d "$SHARE/regression-corpus" ] && \
  printf '[backup]     %-24s %s\n' "regression-corpus" "$(human "$SHARE/regression-corpus")"

echo "[backup]"
echo "[backup] WILL NOT COPY"
for entry in "$SUPPORT"/* "$SUPPORT"/.[!.]*; do
  [ -e "$entry" ] || continue
  name="$(basename "$entry")"
  case " $(echo $KEEP) " in *" $name "*) continue ;; esac
  reason="$(skip_reason "$name")"
  [ -n "$reason" ] || reason="NOT IN THE ALLOW LIST - check whether this is user data worth keeping"
  printf '[backup]     %-24s %-8s %s\n' "$name" "$(human "$entry")" "$reason"
done

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "[backup]"
  echo "[backup] --list: nothing was copied."
  exit 0
fi

# ---- Copy --------------------------------------------------------------------------------------
if [ -z "$DEST" ]; then
  DEST="$HOME/Desktop/ViddyDictate-backup-$(date +%Y%m%d-%H%M%S)"
fi
if [ -e "$DEST" ]; then
  echo "[backup] ERROR: $DEST already exists. Refusing to write into an existing folder," >&2
  echo "[backup]        because merging two backups produces one that is neither." >&2
  exit 1
fi

mkdir -p "$DEST/application-support"
MANIFEST="$DEST/MANIFEST.txt"

{
  echo "ViddyDictate user-data backup"
  echo "created         $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "account         $(id -un) on $(scutil --get ComputerName 2>/dev/null || hostname)"
  echo "macOS           $(sw_vers -productVersion)"
  if [ -d "$HOME/Applications/ViddyDictate.app" ]; then
    echo "app version     $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      "$HOME/Applications/ViddyDictate.app/Contents/Info.plist" 2>/dev/null || echo unknown)"
  fi
  echo
  echo "COPIED"
} > "$MANIFEST"

for name in $KEEP; do
  src="$SUPPORT/$name"
  [ -e "$src" ] || continue
  echo "[backup] copying $name ..."
  ditto "$src" "$DEST/application-support/$name"
  printf '  %-24s %s\n' "$name" "$(human "$src")" >> "$MANIFEST"
done

if [ -f "$PREFS" ]; then
  # Both forms: the binary plist restores byte-for-byte, the xml one can be read by a human in five
  # years when the binary format has moved on and this backup is all that is left.
  cp "$PREFS" "$DEST/settings.plist"
  plutil -convert xml1 -o "$DEST/settings.xml.plist" "$PREFS" 2>/dev/null || true
  printf '  %-24s %s\n' "settings.plist" "$(human "$PREFS")" >> "$MANIFEST"
fi

if [ -d "$SHARE/regression-corpus" ]; then
  echo "[backup] copying regression-corpus ..."
  ditto "$SHARE/regression-corpus" "$DEST/regression-corpus"
  printf '  %-24s %s\n' "regression-corpus" "$(human "$SHARE/regression-corpus")" >> "$MANIFEST"
fi

{
  echo
  echo "NOT COPIED"
  for entry in "$SUPPORT"/* "$SUPPORT"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    case " $(echo $KEEP) " in *" $name "*) continue ;; esac
    reason="$(skip_reason "$name")"
    [ -n "$reason" ] || reason="NOT IN THE ALLOW LIST - check whether this is user data worth keeping"
    printf '  %-24s %-8s %s\n' "$name" "$(human "$entry")" "$reason"
  done
  echo
  echo "TO RESTORE"
  echo "  Install ViddyDictate, launch it once so it creates its folders, quit it, then:"
  echo "    ditto \"<this folder>/application-support/\" \"\$HOME/Library/Application Support/ViddyDictate/\""
  echo "    cp \"<this folder>/settings.plist\" \"\$HOME/Library/Preferences/com.viddydictate.app.plist\""
  echo "    killall cfprefsd    # macOS caches preferences; without this the copy is overwritten"
  echo "  Then launch it again. Quitting first matters: a running app rewrites both while you copy."
} >> "$MANIFEST"

TOTAL="$(human "$DEST")"
echo "[backup]"
echo "[backup] OK -> $DEST  ($TOTAL)"
echo "[backup] manifest: $MANIFEST  (it also carries the restore procedure)"
echo "[backup]"
echo "[backup] This folder contains your dictation transcripts, their audio, and your notes."
echo "[backup] Put it somewhere you would be comfortable putting those."
