#!/usr/bin/env bash
# Test gate for the credential scan in scripts/backup-user-data.sh.
#
# Runs the script under test against a FAKE HOME only; the live source and any
# real user data are never read or modified. Env BACKUP_SCRIPT (default
# scripts/backup-user-data.sh) selects the script under test, so the same file
# shows RED against the base script and GREEN once the scan exists.
#
# One "ok <case>" or "FAIL <case> <reason>" row per case, then a last line
# "BACKUP-SCAN: ALL PASS" or "BACKUP-SCAN: FAILED <n>"; exit 0 only on all pass.

BACKUP_SCRIPT="${BACKUP_SCRIPT:-scripts/backup-user-data.sh}"

T="$(mktemp -d "${TMPDIR:-/tmp}/vdbackup-scan.XXXXXX")"
SUPPORT="$T/home/Library/Application Support/ViddyDictate"
CORPUS="$T/home/.local/share/viddydictate/regression-corpus"
FB="$SUPPORT/file-backups"
TS="1700000000"

OUT="$T/out"
MANIFEST="$OUT/MANIFEST.txt"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
chrun() { printf "$1"'%.0s' $(seq 1 "$2"); }

rel_dest() {
  case "$1" in
    "$SUPPORT/"*) printf 'application-support/%s' "${1#"$SUPPORT"/}" ;;
    "$CORPUS/"*)  printf 'regression-corpus/%s' "${1#"$CORPUS"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

fb_name() { printf '%s-%s-%s' "$TS" "$(uuidgen)" "$1"; }

same_bytes() { [ "$(shasum "$1" | awk '{print $1}')" = "$(shasum "$2" | awk '{print $1}')" ]; }

run_script() {
  local script="$1" so="$2" se="$3"; shift 3
  HOME="$T/home" bash "$script" "$@" >"$so" 2>"$se"
}

tree_listing() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum "$f"; done )
}

PASS_COUNT=0
FAIL_COUNT=0
ok()  { echo "ok $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL $1 $2"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ---------------------------------------------------------------------------
# fake fixtures (assembled at run time; no complete token shape in this source)
# ---------------------------------------------------------------------------
CLEAN_BODY="ordinary note body"

C2_DEST=(); C2_LABEL=(); BODIES=()
N3_DEST=(); N3_SIBLING=()
C1_SRC=(); C1_REL=()
C4_REVIEW_REL=(); C4_REVIEW_LABEL=()
C4_EXCL_REL=(); C4_EXCL_LABEL=()

mkdir -p "$FB" "$SUPPORT/sticky-notes/notes-history" "$SUPPORT/recordings" "$SUPPORT/history" "$CORPUS" "$SUPPORT/codex-home"

A36="$(chrun A 36)"; A40="$(chrun A 40)"; A16="$(chrun A 16)"; A35="$(chrun A 35)"
A20="$(chrun A 20)"; A22="$(chrun A 22)"; A10="$(chrun A 10)"; A12="$(chrun A 12)"
B36="$(chrun B 36)"

PEM_A="$(printf '%s%s%s' '-----BEGIN ' '' 'PRIVATE KEY-----')"
PEM_B="$(printf '%s%s%s' '-----BEGIN ' 'RSA ' 'PRIVATE KEY-----')"
GH_P="$(printf 'gh%s_%s' p "$A36")"
GH_O="$(printf 'gh%s_%s' o "$A36")"
GH_U="$(printf 'gh%s_%s' u "$A36")"
GH_S="$(printf 'gh%s_%s' s "$A36")"
GH_R="$(printf 'gh%s_%s' r "$A36")"
GH_PAT="$(printf 'github_%s_%s' pat "$A22")"
ANT="$(printf 'sk-%s-%s' ant "$A20")"
OAI="$(printf 'sk-%s' "$A40")"
AWS="$(printf 'AK%s%s' IA "$A16")"
GOO="$(printf 'AI%s%s' za "$A35")"
SL_A="$(printf 'xox%s-%s' a "$A10")"
SL_B="$(printf 'xox%s-%s' b "$A10")"
SL_P="$(printf 'xox%s-%s' p "$A10")"
SL_R="$(printf 'xox%s-%s' r "$A10")"
SL_S="$(printf 'xox%s-%s' s "$A10")"
JWT="$(printf 'ey%s%s.ey%s%s.%s' J "$A12" J "$A12" "$A12")"

ASG_VAL="$(chrun A 16)"
ASG1="$(printf '%s_%s: %s' api key "$ASG_VAL")"
ASG2="$(printf '%s-%s= %s' api key "$ASG_VAL")"
ASG3="$(printf '%s%s: %s' api key "$ASG_VAL")"
ASG4="$(printf '%s: %s' secret "$ASG_VAL")"
ASG5="$(printf '%s= %s' token "$ASG_VAL")"
ASG6="$(printf '%s: %s' password "$ASG_VAL")"
ASG7="$(printf '%s= %s' passwd "$ASG_VAL")"
ASG8="$(printf '%s= %s' authorization "$ASG_VAL")"

TWO_LABEL="$(printf '%s: %s' token "$GH_P")"
WAV_TOK="$(printf 'gh%s_%s' p "$B36")"

# C2: one fixture per content alternative, innocent names, first-match label.
c2() {
  printf '%s' "$3" > "$1"
  C2_DEST+=("$(rel_dest "$1")")
  C2_LABEL+=("$2")
  BODIES+=("$3")
}

c2 "$FB/$(fb_name 'doc-01.txt')" pem-private-key "$PEM_A"
c2 "$FB/$(fb_name 'doc-02.txt')" pem-private-key "$PEM_B"
c2 "$FB/$(fb_name 'doc-03.txt')" github-token "$GH_O"
c2 "$FB/$(fb_name 'doc-04.txt')" github-token "$GH_U"
c2 "$FB/$(fb_name 'doc-05.txt')" github-token "$GH_S"
c2 "$FB/$(fb_name 'doc-06.txt')" github-token "$GH_R"
c2 "$FB/$(fb_name 'doc-07.txt')" github-token "$GH_PAT"
c2 "$FB/$(fb_name 'doc-08.txt')" anthropic-key "$ANT"
c2 "$FB/$(fb_name 'doc-09.txt')" openai-style-key "$OAI"
c2 "$FB/$(fb_name 'doc-10.txt')" aws-key-id "$AWS"
c2 "$FB/$(fb_name 'doc-11.txt')" slack-token "$SL_A"
c2 "$FB/$(fb_name 'doc-12.txt')" slack-token "$SL_B"
c2 "$FB/$(fb_name 'doc-13.txt')" slack-token "$SL_P"
c2 "$FB/$(fb_name 'doc-14.txt')" slack-token "$SL_R"
c2 "$FB/$(fb_name 'doc-15.txt')" slack-token "$SL_S"
c2 "$FB/$(fb_name 'doc-16.txt')" jwt "$JWT"
c2 "$FB/$(fb_name 'doc-17.txt')" credential-assignment "$ASG1"
c2 "$FB/$(fb_name 'doc-18.txt')" credential-assignment "$ASG2"
c2 "$FB/$(fb_name 'doc-19.txt')" credential-assignment "$ASG3"
c2 "$FB/$(fb_name 'doc-20.txt')" credential-assignment "$ASG4"
c2 "$FB/$(fb_name 'doc-21.txt')" credential-assignment "$ASG5"
c2 "$FB/$(fb_name 'doc-22.txt')" credential-assignment "$ASG6"
c2 "$FB/$(fb_name 'doc-23.txt')" credential-assignment "$ASG7"
c2 "$FB/$(fb_name 'doc-24.txt')" credential-assignment "$ASG8"
c2 "$FB/$(fb_name 'doc-25.txt')" github-token "$TWO_LABEL"
c2 "$SUPPORT/sticky-notes/notes-history/meeting-note.txt" github-token "$GH_P"
c2 "$CORPUS/corpus-sample.txt" google-api-key "$GOO"

# C3: one fixture per name line, clean body, mixed case; innocent sibling kept.
n3() {
  printf '%s' "$CLEAN_BODY" > "$1"
  printf '%s' "$CLEAN_BODY" > "$2"
  N3_DEST+=("$(rel_dest "$1")")
  N3_SIBLING+=("$(rel_dest "$2")")
}

n3 "$FB/$(fb_name 'MySeCrEt.txt')"       "$FB/$(fb_name 'clean1-notes.md')"
n3 "$FB/$(fb_name 'MyCrEdEnTiAl.txt')"   "$FB/$(fb_name 'clean2-notes.md')"
n3 "$FB/$(fb_name 'MyToKeN.txt')"        "$FB/$(fb_name 'clean3-notes.md')"
n3 "$FB/$(fb_name 'MyPaSsW.txt')"        "$FB/$(fb_name 'clean4-notes.md')"
n3 "$FB/$(fb_name 'MyKeYcHaIn.txt')"     "$FB/$(fb_name 'clean5-notes.md')"
n3 "$FB/$(fb_name 'myauth.json')"        "$FB/$(fb_name 'clean6-notes.md')"
n3 "$FB/$(fb_name 'id_rsa')"             "$FB/$(fb_name 'clean7-notes.md')"
n3 "$FB/$(fb_name 'id_ed25519')"         "$FB/$(fb_name 'clean8-notes.md')"
n3 "$FB/$(fb_name 'config.ENV')"         "$FB/$(fb_name 'clean9-notes.md')"
n3 "$FB/$(fb_name 'cert.PEM')"           "$FB/$(fb_name 'clean10-notes.md')"
n3 "$FB/$(fb_name 'private.KEY')"        "$FB/$(fb_name 'clean11-notes.md')"
n3 "$FB/$(fb_name 'identity.P12')"       "$FB/$(fb_name 'clean12-notes.md')"
n3 "$FB/$(fb_name 'bundle.PFX')"         "$FB/$(fb_name 'clean13-notes.md')"
n3 "$FB/$(fb_name 'login.NETRC')"        "$FB/$(fb_name 'clean14-notes.md')"

# C4: history is report-only for content, name hits still removed.
printf '{"entry": "%s"}' "$GH_P" > "$SUPPORT/history.json"
printf '{"entry": "%s"}' "$GH_O" > "$SUPPORT/history/transcript-1.json"
printf '%s' "$CLEAN_BODY" > "$SUPPORT/history/notes-secret.txt"
HIST_FB="$FB/$(fb_name 'history.json')"
printf '%s' "$GH_R" > "$HIST_FB"

C4_REVIEW_REL=("application-support/history.json" "application-support/history/transcript-1.json")
C4_REVIEW_LABEL=("github-token" "github-token")
C4_EXCL_REL=("application-support/history/notes-secret.txt" "$(rel_dest "$HIST_FB")")
C4_EXCL_LABEL=("name-rule" "github-token")
BODIES+=("$GH_P" "$GH_O" "$GH_R")

# A hit under a SKIP item (codex-home) must never be scanned or listed.
CODEX_BODY="$(printf 'gh%s_%s' o "$B36")"
printf '%s' "$CODEX_BODY" > "$SUPPORT/codex-home/session.txt"
BODIES+=("$CODEX_BODY")

# C1: binary fixture judged on name only; contains a runtime token, name is innocent.
printf 'RIFF' > "$SUPPORT/recordings/x.wav"
printf '\x00\x00\x00\x00\x00\x00' >> "$SUPPORT/recordings/x.wav"
printf '%s' "$WAV_TOK" >> "$SUPPORT/recordings/x.wav"
BODIES+=("$WAV_TOK")

CLEAN_FB="$FB/$(fb_name 'clean-notes.txt')"
STICKY_CLEAN="$SUPPORT/sticky-notes/notes-history/clean-sticky.txt"
CORPUS_CLEAN="$CORPUS/clean-corpus.txt"
printf '%s' "$CLEAN_BODY" > "$CLEAN_FB"
printf '%s' "$CLEAN_BODY" > "$STICKY_CLEAN"
printf '%s' "$CLEAN_BODY" > "$CORPUS_CLEAN"
printf '%s' '{"words":["hello","world"]}' > "$SUPPORT/dictionary.json"

C1_SRC=("$CLEAN_FB" "$STICKY_CLEAN" "$CORPUS_CLEAN" "$SUPPORT/dictionary.json" "$SUPPORT/recordings/x.wav")
C1_REL=("$(rel_dest "$CLEAN_FB")" "$(rel_dest "$STICKY_CLEAN")" "$(rel_dest "$CORPUS_CLEAN")" \
        "application-support/dictionary.json" "application-support/recordings/x.wav")

# ---------------------------------------------------------------------------
# case checks
# ---------------------------------------------------------------------------
check_c1() {
  local i n="${#C1_SRC[@]}"
  for ((i=0;i<n;i++)); do
    local src="${C1_SRC[$i]}" rel="${C1_REL[$i]}"
    [ -f "$RUN_OUT/$rel" ] || return 1
    same_bytes "$src" "$RUN_OUT/$rel" || return 1
    if grep -F -q "$rel" "$RUN_MANIFEST"; then return 1; fi
  done
  return 0
}

check_c2() {
  local i n="${#C2_DEST[@]}"
  for ((i=0;i<n;i++)); do
    local rel="${C2_DEST[$i]}" label="${C2_LABEL[$i]}"
    [ ! -e "$RUN_OUT/$rel" ] || return 1
    grep -F -q "$rel  $label" "$RUN_MANIFEST" || return 1
  done
  return 0
}

check_c3() {
  local i n="${#N3_DEST[@]}"
  for ((i=0;i<n;i++)); do
    local rel="${N3_DEST[$i]}"
    [ ! -e "$RUN_OUT/$rel" ] || return 1
    grep -F -q "$rel  name-rule" "$RUN_MANIFEST" || return 1
  done
  for ((i=0;i<n;i++)); do
    [ -e "$RUN_OUT/${N3_SIBLING[$i]}" ] || return 1
  done
  return 0
}

check_c4() {
  local i n
  n="${#C4_REVIEW_REL[@]}"
  for ((i=0;i<n;i++)); do
    local rel="${C4_REVIEW_REL[$i]}" label="${C4_REVIEW_LABEL[$i]}"
    [ -e "$RUN_OUT/$rel" ] || return 1
    grep -F -q "$rel  $label" "$RUN_MANIFEST" || return 1
  done
  n="${#C4_EXCL_REL[@]}"
  for ((i=0;i<n;i++)); do
    local rel="${C4_EXCL_REL[$i]}" label="${C4_EXCL_LABEL[$i]}"
    [ ! -e "$RUN_OUT/$rel" ] || return 1
    grep -F -q "$rel  $label" "$RUN_MANIFEST" || return 1
  done
  return 0
}

check_c5() {
  local i n="${#BODIES[@]}"
  for ((i=0;i<n;i++)); do
    if grep -R -F -q -e "${BODIES[$i]}" "$RUN_MANIFEST" "$RUN_STDOUT" "$RUN_STDERR"; then return 1; fi
  done
  return 0
}

check_c6() {
  [ "$LIST_SUPPORT_BEFORE" = "$LIST_SUPPORT_AFTER" ] || return 1
  [ "$LIST_CORPUS_BEFORE" = "$LIST_CORPUS_AFTER" ] || return 1
}

check_c7() {
  local i n
  n="${#C2_DEST[@]}"
  for ((i=0;i<n;i++)); do
    grep -F -q "WOULD EXCLUDE ${C2_DEST[$i]} (${C2_LABEL[$i]})" "$C7_LIST_OUT" || return 1
  done
  n="${#N3_DEST[@]}"
  for ((i=0;i<n;i++)); do
    grep -F -q "WOULD EXCLUDE ${N3_DEST[$i]} (name-rule)" "$C7_LIST_OUT" || return 1
  done
  n="${#C4_REVIEW_REL[@]}"
  for ((i=0;i<n;i++)); do
    grep -F -q "WOULD KEEP FOR REVIEW ${C4_REVIEW_REL[$i]} (${C4_REVIEW_LABEL[$i]})" "$C7_LIST_OUT" || return 1
  done
  n="${#C4_EXCL_REL[@]}"
  for ((i=0;i<n;i++)); do
    grep -F -q "WOULD EXCLUDE ${C4_EXCL_REL[$i]} (${C4_EXCL_LABEL[$i]})" "$C7_LIST_OUT" || return 1
  done
  [ -z "$(find "$T" -type d -name 'ViddyDictate-backup-*' -print -quit)" ] || return 1
  if grep -F -q "application-support/codex-home/" "$C7_LIST_OUT"; then return 1; fi
  return 0
}

c3_index() {
  local type="$1" text="$2" i n="${#N3_DEST[@]}" bn
  for ((i=0;i<n;i++)); do
    bn="$(basename "${N3_DEST[$i]}" | tr '[:upper:]' '[:lower:]')"
    case "$type" in
      contains) case "$bn" in *"$text"*) printf '%s' "$i"; return 0 ;; esac ;;
      endswith) case "$bn" in *"$text") printf '%s' "$i"; return 0 ;; esac ;;
    esac
  done
  return 1
}

c3_others_pass() {
  local tgt="$1" j n="${#N3_DEST[@]}"
  for ((j=0;j<n;j++)); do
    [ "$j" -eq "$tgt" ] && continue
    [ ! -e "$RUN_OUT/${N3_DEST[$j]}" ] || return 1
    grep -F -q "${N3_DEST[$j]}  name-rule" "$RUN_MANIFEST" || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# C6 before-listing, then the main run
# ---------------------------------------------------------------------------
LIST_SUPPORT_BEFORE="$(tree_listing "$SUPPORT")"
LIST_CORPUS_BEFORE="$(tree_listing "$CORPUS")"

run_script "$BACKUP_SCRIPT" "$T/stdout.log" "$T/stderr.log" "$OUT"
RUN_OUT="$OUT"; RUN_MANIFEST="$MANIFEST"; RUN_STDOUT="$T/stdout.log"; RUN_STDERR="$T/stderr.log"

LIST_SUPPORT_AFTER="$(tree_listing "$SUPPORT")"
LIST_CORPUS_AFTER="$(tree_listing "$CORPUS")"

if check_c1; then ok C1; else fail C1 "clean control failed"; fi
if check_c2; then ok C2; else fail C2 "content fixtures not excluded"; fi
if check_c3; then ok C3; else fail C3 "name fixtures not excluded"; fi
if check_c4; then ok C4; else fail C4 "history report-only handling wrong"; fi
if check_c5; then ok C5; else fail C5 "a fake body leaked"; fi
if check_c6; then ok C6; else fail C6 "live source tree changed"; fi

# ---------------------------------------------------------------------------
# C7 --list (read-only)
# ---------------------------------------------------------------------------
run_script "$BACKUP_SCRIPT" "$T/list.out" "$T/list.err" --list
C7_LIST_OUT="$T/list.out"
if check_c7; then ok C7; else fail C7 "--list did not report the hit set"; fi

# ---------------------------------------------------------------------------
# C8 negative control (mutants of the script under test)
# ---------------------------------------------------------------------------
C8_REASON=""
if grep -q -E '^credential_scan "\$DEST"$' "$BACKUP_SCRIPT"; then
  # m0: drop the single call line.
  sed 's/^credential_scan "\$DEST"$/:/' "$BACKUP_SCRIPT" > "$T/m0.sh"
  run_script "$T/m0.sh" "$T/m0.out" "$T/m0.err" "$T/out-m0"
  RUN_OUT="$T/out-m0"; RUN_MANIFEST="$T/out-m0/MANIFEST.txt"; RUN_STDOUT="$T/m0.out"; RUN_STDERR="$T/m0.err"
  if check_c2; then C8_REASON="m0 did not bite"; fi
  if [ -z "$C8_REASON" ] && check_c3; then C8_REASON="m0 did not bite"; fi
  if [ -z "$C8_REASON" ] && check_c4; then C8_REASON="m0 did not bite"; fi

  # m1: remove each name-rule line; only that rule's C3 fixture may break.
  if [ -z "$C8_REASON" ]; then
    awk '/# CRED-NAMES-BEGIN/{f=1;next} /# CRED-NAMES-END/{f=0} f' "$BACKUP_SCRIPT" > "$T/name-lines.txt"
    idx=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      idx=$((idx+1))
      type="${line%%@@*}"; text="${line#*@@}"
      tgt="$(c3_index "$type" "$text")"
      if [ -z "$tgt" ]; then C8_REASON="m1 could not map a name rule"; break; fi
      awk -v t="$line" '$0 == t && !done { done=1; next } { print }' "$BACKUP_SCRIPT" > "$T/m1.sh"
      run_script "$T/m1.sh" "$T/m1.out" "$T/m1.err" "$T/out-m1-$idx"
      RUN_OUT="$T/out-m1-$idx"; RUN_MANIFEST="$T/out-m1-$idx/MANIFEST.txt"; RUN_STDOUT="$T/m1.out"; RUN_STDERR="$T/m1.err"
      if [ ! -e "$RUN_OUT/${N3_DEST[$tgt]}" ]; then C8_REASON="m1 did not bite"; break; fi
      if ! c3_others_pass "$tgt"; then C8_REASON="m1 broke another C3 fixture"; break; fi
    done < "$T/name-lines.txt"
  fi

  # m2: remove each content-pattern line; at least one fixture for that label must break.
  if [ -z "$C8_REASON" ]; then
    awk '/# CRED-PATTERNS-BEGIN/{f=1;next} /# CRED-PATTERNS-END/{f=0} f' "$BACKUP_SCRIPT" > "$T/pat-lines.txt"
    idx=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      idx=$((idx+1))
      label="${line%%@@*}"
      grep -v -F -x -- "$line" "$BACKUP_SCRIPT" > "$T/m2.sh"
      run_script "$T/m2.sh" "$T/m2.out" "$T/m2.err" "$T/out-m2-$idx"
      RUN_OUT="$T/out-m2-$idx"; RUN_MANIFEST="$T/out-m2-$idx/MANIFEST.txt"; RUN_STDOUT="$T/m2.out"; RUN_STDERR="$T/m2.err"
      found=0
      for ((j=0;j<${#C2_DEST[@]};j++)); do
        if [ "${C2_LABEL[$j]}" = "$label" ]; then
          if [ -e "$RUN_OUT/${C2_DEST[$j]}" ]; then found=1; break; fi
        fi
      done
      if [ "$found" -eq 0 ]; then C8_REASON="m2 did not bite"; break; fi
    done < "$T/pat-lines.txt"
  fi

  # m3: remove the grep -I so the binary wav is content-scanned and excluded.
  if [ -z "$C8_REASON" ]; then
    sed -E 's/(^|[[:space:]])-I([[:space:]]|$)/\1\2/g' "$BACKUP_SCRIPT" > "$T/m3.sh"
    run_script "$T/m3.sh" "$T/m3.out" "$T/m3.err" "$T/out-m3"
    if [ -e "$T/out-m3/application-support/recordings/x.wav" ]; then C8_REASON="m3 did not bite"; fi
  fi

  if [ -z "$C8_REASON" ]; then ok C8; else fail C8 "$C8_REASON"; fi
else
  fail C8 "mutation point missing"
fi

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "BACKUP-SCAN: ALL PASS"
  exit 0
else
  echo "BACKUP-SCAN: FAILED $FAIL_COUNT"
  exit 1
fi
