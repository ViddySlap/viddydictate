#!/usr/bin/env bash
# Remove ViddyDictate from this account, completely and in the order that is safe to do it in.
#
#   ./scripts/uninstall.sh                 -> show everything that would be removed, remove nothing
#   ./scripts/uninstall.sh --app-only      -> remove the app, keep transcripts, notes and settings
#   ./scripts/uninstall.sh --everything    -> remove all of it, including your data
#
# It never removes anything without being told which of those two you mean, and --everything asks
# you to type a confirmation, because dictation history and sticky notes exist nowhere else.
# Back them up first:  ./scripts/backup-user-data.sh
#
# ORDER IS NOT COSMETIC. ViddyDictate holds a CGEventTap on the keyboard. Deleting the bundle out
# from under a running instance takes the tap away without letting it tear down, and a real user's
# keyboard stopped responding that way (2026-08-15). So: stop launchd first, let the process exit on
# its own with SIGTERM, confirm it is gone, and only then touch a file.
set -euo pipefail

APP="$HOME/Applications/ViddyDictate.app"
SUPPORT="$HOME/Library/Application Support/ViddyDictate"
SHARE="$HOME/.local/share/viddydictate"
UID_NUM="$(id -u)"

LABELS="com.viddydictate.app com.viddydictate.whisperd com.viddyslap.viddydictate"
# Both the current bundle id and the one it was renamed from, because TCC keeps a row per bundle id
# and a stale row is exactly what makes a "clean" reinstall behave unlike a real first run.
BUNDLE_IDS="com.viddydictate.app com.viddyslap.viddydictate"

MODE=""
ASSUME_YES=0
KEEP_PERMISSIONS=0
for arg in "$@"; do
  case "$arg" in
    --app-only) MODE="app" ;;
    --everything) MODE="all" ;;
    --yes) ASSUME_YES=1 ;;
    --keep-permissions) KEEP_PERMISSIONS=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[uninstall] unknown option: $arg" >&2; exit 2 ;;
  esac
done

human() { du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "-"; }
present() { [ -e "$1" ] && echo yes || echo no; }

# ---- Inventory ---------------------------------------------------------------------------------
echo "[uninstall] What is on this account:"
echo "[uninstall]"
printf '[uninstall]   %-52s %s\n' "$APP" "$( [ -d "$APP" ] && human "$APP" || echo 'not present')"
for lbl in $LABELS; do
  p="$HOME/Library/LaunchAgents/$lbl.plist"
  [ -f "$p" ] && printf '[uninstall]   %-52s %s\n' "$p" "launchd job"
done
printf '[uninstall]   %-52s %s\n' "$SUPPORT" "$( [ -d "$SUPPORT" ] && human "$SUPPORT" || echo 'not present')"
printf '[uninstall]   %-52s %s\n' "$SHARE" "$( [ -d "$SHARE" ] && human "$SHARE" || echo 'not present')"
PREF_COUNT="$(find "$HOME/Library/Preferences" -maxdepth 1 \
  \( -name 'com.viddydictate.*' -o -name 'com.viddyslap.viddydictate*' -o -name 'ViddyDictate*.plist' \
     -o -name 'test.viddydictate.*' \) 2>/dev/null | wc -l | tr -d ' ')"
printf '[uninstall]   %-52s %s\n' "~/Library/Preferences (ViddyDictate entries)" "$PREF_COUNT file(s)"
CACHE_COUNT="$(find "$HOME/Library/Caches" -maxdepth 1 \
  \( -name 'ViddyDictate*' -o -name 'com.viddydictate.*' -o -name 'com.viddyslap.viddydictate*' \
     -o -name 'viddydictate-*' \) 2>/dev/null | wc -l | tr -d ' ')"
printf '[uninstall]   %-52s %s\n' "~/Library/Caches (ViddyDictate entries)" "$CACHE_COUNT item(s)"
printf '[uninstall]   %-52s %s\n' "~/Library/Logs/ViddyDictate.log" "$(present "$HOME/Library/Logs/ViddyDictate.log")"

RUNNING="$(pgrep -f 'ViddyDictate\.app/Contents/MacOS/ViddyDictate' 2>/dev/null || true)"
echo "[uninstall]"
if [ -n "$RUNNING" ]; then
  echo "[uninstall]   running now: PID(s) $(echo $RUNNING | tr '\n' ' ')"
else
  echo "[uninstall]   not running"
fi

echo "[uninstall]"
echo "[uninstall] NOT touched by this script, because it is not ours to remove:"
echo "[uninstall]   LM Studio and any models you downloaded through it"
echo "[uninstall]   the Hugging Face cache (~/.cache/huggingface) - shared with other tools"
echo "[uninstall]   Homebrew, ffmpeg, Node, or anything else installed as a prerequisite"

if [ -z "$MODE" ]; then
  echo "[uninstall]"
  echo "[uninstall] Nothing was removed. Say which you mean:"
  echo "[uninstall]"
  echo "[uninstall]   ./scripts/uninstall.sh --app-only     the app, its launchd jobs, caches and logs."
  echo "[uninstall]                                         Transcripts, recordings, notes, dictionary"
  echo "[uninstall]                                         and settings all stay, and a reinstall"
  echo "[uninstall]                                         picks them straight back up."
  echo "[uninstall]"
  echo "[uninstall]   ./scripts/uninstall.sh --everything   all of the above plus your data. Back it"
  echo "[uninstall]                                         up first:  ./scripts/backup-user-data.sh"
  exit 0
fi

# ---- Confirm -----------------------------------------------------------------------------------
if [ "$MODE" = "all" ] && [ "$ASSUME_YES" -eq 0 ]; then
  echo "[uninstall]"
  echo "[uninstall] --everything DELETES your dictation history, the audio behind it, your sticky"
  echo "[uninstall] notes and their attachments, and your correction dictionary. They are not stored"
  echo "[uninstall] anywhere else and this is not undoable."
  echo "[uninstall]"
  echo "[uninstall] If you have not run ./scripts/backup-user-data.sh, stop and do that now."
  echo "[uninstall]"
  printf '[uninstall] Type DELETE MY DATA to continue: '
  read -r reply
  if [ "$reply" != "DELETE MY DATA" ]; then
    echo "[uninstall] Not confirmed. Nothing was removed."
    exit 1
  fi
fi

# ---- 1. Stop it, before removing a single file -------------------------------------------------
echo "[uninstall]"
echo "[uninstall] === stopping ==="
for lbl in $LABELS; do
  if launchctl print "gui/$UID_NUM/$lbl" >/dev/null 2>&1; then
    echo "[uninstall] booting out $lbl"
    launchctl bootout "gui/$UID_NUM/$lbl" 2>/dev/null || true
  fi
done

# SIGTERM, never SIGKILL: the app releases the event tap in its termination handler, and a killed
# process does not run one. This is the whole reason the script is ordered the way it is.
if pgrep -f 'ViddyDictate\.app/Contents/MacOS/ViddyDictate' >/dev/null 2>&1; then
  echo "[uninstall] asking ViddyDictate to quit (SIGTERM, so it releases the keyboard tap)"
  pkill -TERM -f 'ViddyDictate\.app/Contents/MacOS/ViddyDictate' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f 'ViddyDictate\.app/Contents/MacOS/ViddyDictate' >/dev/null 2>&1 || break
    sleep 1
  done
fi
pkill -TERM -f 'viddydictate_whisperd' 2>/dev/null || true
sleep 1

if pgrep -f 'ViddyDictate\.app/Contents/MacOS/ViddyDictate' >/dev/null 2>&1; then
  echo "[uninstall] ERROR: ViddyDictate is still running after 10s." >&2
  echo "[uninstall]        Refusing to delete the bundle out from under a live event tap - that is" >&2
  echo "[uninstall]        how a keyboard stops responding. Quit it from the menu bar and re-run." >&2
  exit 1
fi
echo "[uninstall] stopped"

# ---- 2. launchd jobs ---------------------------------------------------------------------------
echo "[uninstall] === launchd ==="
for lbl in $LABELS; do
  p="$HOME/Library/LaunchAgents/$lbl.plist"
  if [ -f "$p" ]; then
    rm -f "$p"
    echo "[uninstall] removed $p"
  fi
done

# ---- 3. The app --------------------------------------------------------------------------------
echo "[uninstall] === app ==="
for candidate in "$APP" "/Applications/ViddyDictate.app"; do
  if [ -d "$candidate" ]; then
    rm -rf "$candidate"
    echo "[uninstall] removed $candidate"
  fi
done

# ---- 4. Caches, logs, saved state --------------------------------------------------------------
echo "[uninstall] === caches, logs, saved state ==="
find "$HOME/Library/Caches" -maxdepth 1 \
  \( -name 'ViddyDictate*' -o -name 'com.viddydictate.*' -o -name 'com.viddyslap.viddydictate*' \
     -o -name 'viddydictate-*' \) -exec rm -rf {} + 2>/dev/null || true
rm -f "$HOME/Library/Logs/ViddyDictate.log" /tmp/viddydictate.err.log /tmp/viddydictate.out.log
rm -rf "$HOME/Library/Saved Application State/com.viddydictate.app.savedState" \
       "$HOME/Library/Saved Application State/com.viddyslap.viddydictate.savedState"
echo "[uninstall] removed caches, log, and saved window state"

# ---- 5. Preferences ----------------------------------------------------------------------------
# `defaults delete` BEFORE removing the file, and cfprefsd afterwards. cfprefsd owns the in-memory
# copy and writes it back on its own schedule, so deleting only the file can be silently undone
# minutes later - the reinstall then inherits settings from an install that no longer exists.
if [ "$MODE" = "all" ]; then
  echo "[uninstall] === preferences ==="
  for bid in $BUNDLE_IDS; do
    defaults delete "$bid" >/dev/null 2>&1 || true
  done
  find "$HOME/Library/Preferences" -maxdepth 1 \
    \( -name 'com.viddydictate.*' -o -name 'com.viddyslap.viddydictate*' -o -name 'ViddyDictate*.plist' \
       -o -name 'test.viddydictate.*' \) -delete 2>/dev/null || true
  killall cfprefsd 2>/dev/null || true
  echo "[uninstall] removed $PREF_COUNT preference file(s) and flushed the preferences cache"
else
  echo "[uninstall] === preferences ==="
  echo "[uninstall] kept (--app-only): your settings survive the reinstall"
fi

# ---- 6. User data ------------------------------------------------------------------------------
if [ "$MODE" = "all" ]; then
  echo "[uninstall] === user data ==="
  for d in "$SUPPORT" "$SHARE"; do
    if [ -d "$d" ]; then
      rm -rf "$d"
      echo "[uninstall] removed $d"
    fi
  done
else
  echo "[uninstall] === user data ==="
  echo "[uninstall] kept (--app-only): $SUPPORT"
  [ -d "$SHARE" ] && echo "[uninstall] kept (--app-only): $SHARE"
fi

# ---- 7. Permissions ----------------------------------------------------------------------------
# A reinstall that inherits an Accessibility grant is not a first-run rehearsal, it is a warm start
# wearing a first run's clothes - and the first-run permission flow is the part most likely to be
# broken for a stranger, so it is the part most worth actually testing.
if [ "$MODE" = "all" ] && [ "$KEEP_PERMISSIONS" -eq 0 ]; then
  echo "[uninstall] === permissions ==="
  for bid in $BUNDLE_IDS; do
    for svc in Accessibility ListenEvent Microphone SystemPolicyDocumentsFolder; do
      tccutil reset "$svc" "$bid" >/dev/null 2>&1 || true
    done
  done
  echo "[uninstall] reset Accessibility, Input Monitoring, Microphone and Documents grants"
  echo "[uninstall] macOS sometimes leaves a stale row in System Settings > Privacy & Security."
  echo "[uninstall] If ViddyDictate is still listed there, select it and press the minus button."
elif [ "$MODE" = "all" ]; then
  echo "[uninstall] === permissions ==="
  echo "[uninstall] kept (--keep-permissions). Note that a reinstall will then skip the first-run"
  echo "[uninstall] permission flow, which is the part a clean-slate test most needs to exercise."
fi

# ---- Done --------------------------------------------------------------------------------------
echo "[uninstall]"
echo "[uninstall] ===== DONE ====="
if [ "$MODE" = "all" ]; then
  echo "[uninstall] ViddyDictate is gone from this account, data included."
  echo "[uninstall] The next install will behave like a first install on a new Mac."
else
  echo "[uninstall] The app is gone. Your transcripts, recordings, notes and settings are still at:"
  echo "[uninstall]     $SUPPORT"
  echo "[uninstall] Reinstalling picks them straight back up."
fi
