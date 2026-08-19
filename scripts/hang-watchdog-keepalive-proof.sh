#!/usr/bin/env bash
# End-to-end runtime proof for the hang watchdog (ADR 0017). Opt-in, never part of a verify.sh tier.
#
# Proves the one claim the deterministic gate structurally cannot: that a wedged main thread really
# does abort, that SIGABRT really is the non-zero exit `KeepAlive: SuccessfulExit=false` relaunches on,
# and that ReportCrash really does leave an .ips with every thread stack.
#
# SAFETY. This installs a LaunchAgent, so read this before running it:
#
#   * The agent is a THROWAWAY with its own label and is booted out on exit, including on failure.
#     It is NOT the shipped agent and NOT a second one for the product — ADR 0017 exists precisely to
#     avoid shipping a supervising LaunchAgent, and nothing here changes that.
#   * It runs build/ViddyDictateTests.app, never ~/Applications/ViddyDictate.app. The live app is
#     never rebuilt, reinstalled, kickstarted, or aborted, and this script refuses to start if the
#     label or the program would collide with it.
#   * HOME, CFFIXED_USER_HOME and TMPDIR are all redirected to a scratch tree, the same three
#     scripts/verify.sh redirects. Redirecting HOME alone does NOT isolate a macOS process:
#     Core Foundation reads CFFIXED_USER_HOME, and on 2026-08-03 an "isolated" instance of this app
#     deleted three of Ben's live sticky notes.
#   * Isolation is ASSERTED, not assumed: the run must write its hang line into the SCRATCH log, and
#     the real ~/Library/Logs/ViddyDictate.log must not gain one.
#
# The .ips is the one artifact that cannot be redirected — ReportCrash is a system daemon that files
# by uid, not by HOME — so it lands in the real ~/Library/Logs/DiagnosticReports/. That is read-only
# evidence, not app data.
#
# Usage: ./scripts/hang-watchdog-keepalive-proof.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST_APP="$ROOT/build/ViddyDictateTests.app/Contents/MacOS/ViddyDictateTests"
LIVE_LABEL="com.viddydictate.app"
LABEL="com.viddydictate.hangwatchdog.proof"
UID_NUM="$(id -u)"
FAILURES=0

pass() { printf '[watchdog-proof][PASS] %s\n' "$1"; }
fail() { printf '[watchdog-proof][FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

if [[ "$LABEL" == "$LIVE_LABEL" ]]; then
    echo "[watchdog-proof] refusing: proof label collides with the live agent"; exit 2
fi
if [[ ! -x "$TEST_APP" ]]; then
    echo "[watchdog-proof] refusing: $TEST_APP missing; run ./scripts/verify.sh deterministic first"
    exit 2
fi

LIVE_PID_BEFORE="$(launchctl print "gui/$UID_NUM/$LIVE_LABEL" 2>/dev/null \
    | awk '/^\tpid = /{print $3}')"

SCRATCH="$(mktemp -d /private/tmp/viddydictate-watchdog-proof.XXXXXX)"
SCRATCH_HOME="$SCRATCH/home"
SCRATCH_TMP="$SCRATCH/tmp"
mkdir -p "$SCRATCH_HOME/Library/Logs" "$SCRATCH_HOME/Library/Preferences" "$SCRATCH_TMP"
PLIST="$SCRATCH/$LABEL.plist"
SCRATCH_LOG="$SCRATCH_HOME/Library/Logs/ViddyDictate.log"
REAL_LOG="$HOME/Library/Logs/ViddyDictate.log"
REPORTS="$HOME/Library/Logs/DiagnosticReports"

REAL_LOG_LINES_BEFORE="$(wc -l <"$REAL_LOG" 2>/dev/null | tr -d ' ')"
REAL_LOG_LINES_BEFORE="${REAL_LOG_LINES_BEFORE:-0}"
IPS_BEFORE="$(ls "$REPORTS" 2>/dev/null | grep -c '^ViddyDictateTests-')"

# The agent always goes away; the scratch tree deliberately stays so the run's evidence (the isolated
# log, both launchd streams) is still readable afterwards. It lives in /private/tmp and the path is
# printed below.
teardown() {
    launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
    pkill -f -- "--hang-watchdog-abort-proof" >/dev/null 2>&1
}
trap teardown EXIT

cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TEST_APP</string>
    <string>--hang-watchdog-selftest</string>
    <string>--hang-watchdog-abort-proof</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- Byte-for-byte the clause the shipped com.viddydictate.app.plist carries. That is the point:
       this proves the RELAUNCH RULE THE LIVE APP ALREADY HAS is what catches the abort. -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$SCRATCH_HOME</string>
    <key>CFFIXED_USER_HOME</key><string>$SCRATCH_HOME</string>
    <key>TMPDIR</key><string>$SCRATCH_TMP/</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$SCRATCH/proof.out.log</string>
  <key>StandardErrorPath</key>
  <string>$SCRATCH/proof.err.log</string>
</dict>
</plist>
PLIST_EOF

echo "[watchdog-proof] scratch: $SCRATCH"
echo "[watchdog-proof] booting throwaway agent $LABEL"
launchctl bootstrap "gui/$UID_NUM" "$PLIST" || { echo "[watchdog-proof] bootstrap failed"; exit 2; }

# One run is ~10s of healthy beats plus the 45s threshold; launchd then throttles the respawn by 10s.
# Wait for the SECOND run to start, which is the relaunch this proof is about.
DEADLINE=$((SECONDS + 210))
RUNS=0
while (( SECONDS < DEADLINE )); do
    RUNS="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk '/^\truns = /{print $3}')"
    RUNS="${RUNS:-0}"
    (( RUNS >= 2 )) && break
    sleep 2
done
LAST_EXIT="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
    | grep -E 'last exit (code|status)' | head -1 | sed 's/^[[:space:]]*//')"
launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | grep -E '^\t(runs|state|last exit)' || true
launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1

echo "--- results ---"
(( RUNS >= 2 )) \
    && pass "KeepAlive relaunched the aborted process (runs=$RUNS)" \
    || fail "no relaunch observed within the deadline (runs=$RUNS)"

# Do NOT assert on launchd's exit wording. It varies by release and the field is absent entirely
# while the respawned run is still going, which is exactly when this script looks - an earlier version
# of this check reported a false red for that reason. The non-zero exit is proven twice over below
# without it: the .ips records SIGABRT/code 6, and a respawn under SuccessfulExit=false can ONLY
# happen on a non-zero exit, because that is the whole meaning of the key.
if (( RUNS >= 2 )); then
    pass "the exit was non-zero: SuccessfulExit=false respawns only on a non-zero exit, and launchd respawned"
fi
[[ -n "$LAST_EXIT" ]] && echo "[watchdog-proof][info] launchd reported: $LAST_EXIT"

ARMED_RUNS="$(grep -c 'hang-watchdog-abort-proof\] armed' "$SCRATCH/proof.out.log" 2>/dev/null)"
(( ARMED_RUNS >= 2 )) \
    && pass "the watchdog armed once per run, independently of launchctl (armed lines=$ARMED_RUNS)" \
    || fail "expected >=2 armed lines in the proof stdout, saw ${ARMED_RUNS:-0}"

grep -q 'FAIL: main woke up' "$SCRATCH/proof.out.log" 2>/dev/null \
    && fail "a run survived its wedge: the watchdog did not fire" \
    || pass "no run survived its wedge"

if grep -q 'HANG WATCHDOG' "$SCRATCH_LOG" 2>/dev/null; then
    pass "the hang reason reached the log: $(grep -m1 'HANG WATCHDOG' "$SCRATCH_LOG")"
    # One line per COMPLETED abort. The run that the relaunch started is still mid-wedge when this
    # script stops waiting, so expect one fewer line than $RUNS.
    HANG_LINES="$(grep -c 'HANG WATCHDOG' "$SCRATCH_LOG")"
    pass "log carries $HANG_LINES hang line(s) for $RUNS run(s); the newest is still mid-wedge at teardown, so $((RUNS - 1)) is expected"
else
    fail "no HANG WATCHDOG line in the scratch log ($SCRATCH_LOG)"
fi

REAL_LOG_LINES_AFTER="$(wc -l <"$REAL_LOG" 2>/dev/null | tr -d ' ')"
REAL_LOG_LINES_AFTER="${REAL_LOG_LINES_AFTER:-0}"
if grep -q 'HANG WATCHDOG' "$REAL_LOG" 2>/dev/null; then
    fail "ISOLATION BREACH: the real log gained a hang line ($REAL_LOG)"
else
    pass "isolation held: the real log has no hang line (before=$REAL_LOG_LINES_BEFORE after=$REAL_LOG_LINES_AFTER)"
fi

sleep 3
IPS_AFTER="$(ls "$REPORTS" 2>/dev/null | grep -c '^ViddyDictateTests-')"
if (( IPS_AFTER > IPS_BEFORE )); then
    NEWEST="$(ls -t "$REPORTS" 2>/dev/null | grep '^ViddyDictateTests-' | head -1)"
    pass "ReportCrash wrote $((IPS_AFTER - IPS_BEFORE)) new .ips (newest: $NEWEST)"
    grep -q 'SIGABRT' "$REPORTS/$NEWEST" 2>/dev/null \
        && pass "the .ips records SIGABRT" \
        || fail "the .ips does not name SIGABRT"
else
    fail "no new .ips in $REPORTS (before=$IPS_BEFORE after=$IPS_AFTER)"
fi

LIVE_PID_AFTER="$(launchctl print "gui/$UID_NUM/$LIVE_LABEL" 2>/dev/null \
    | awk '/^\tpid = /{print $3}')"
if [[ -n "$LIVE_PID_BEFORE" && "$LIVE_PID_BEFORE" == "$LIVE_PID_AFTER" ]]; then
    pass "the live app was untouched (pid $LIVE_PID_BEFORE throughout)"
else
    fail "live app pid changed: before=${LIVE_PID_BEFORE:-<none>} after=${LIVE_PID_AFTER:-<none>}"
fi

echo "--- evidence kept at $SCRATCH (remove it when done) ---"
echo "--- proof-run stdout ---"
tail -20 "$SCRATCH/proof.out.log" 2>/dev/null

if (( FAILURES == 0 )); then
    echo "[watchdog-proof] PASS"
    exit 0
fi
echo "[watchdog-proof] FAIL: $FAILURES check(s) red"
exit 1
