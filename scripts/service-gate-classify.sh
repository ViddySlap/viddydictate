# shellcheck shell=bash
# Sourced by scripts/verify.sh. Pure functions over one service gate's captured log; no side effects
# beyond the fixture directory the selftest is given. Written for the macOS /bin/bash 3.2.
#
# An abstaining gate is never a PASS. A gate that cannot run because its apparatus or a precondition is
# missing exits 0 and prints a `[skip] ... SKIPPED: <reason>` line carrying PRECONDITION_MISSING_MARKER.
# verify.sh counts that as SKIP. Until 2026-10-01 a `normal` gate that abstained was reported as
# `[verify][service][PASS]`, and the Codex catalog and device-auth gates read green through a two-week
# Codex outage.

# Must equal SelfTestAbstain.preconditionMissingMarker (Sources/SelfTest/SelfTestAbstain.swift).
PRECONDITION_MISSING_MARKER='[precondition-missing]'

service_gate_log_abstained() {
    grep -Eq '\[skip\].*SKIPPED' "$1" || grep -Fq -- "$PRECONDITION_MISSING_MARKER" "$1"
}

# A PASS line in the gate's own output: the token PASS standing alone ("[PASS]", "] PASS ...").
service_gate_log_has_pass() {
    grep -Eq '(^|[^A-Za-z])PASS([^A-Za-z]|$)' "$1"
}

service_gate_log_has_precondition_marker() {
    grep -Fq -- "$PRECONDITION_MISSING_MARKER" "$1"
}

# The meta-gate's predicate: a gate that says a precondition is missing AND passes is lying about one.
service_gate_log_contradicts() {
    service_gate_log_has_precondition_marker "$1" && service_gate_log_has_pass "$1"
}

# Verdict for a gate that exited 0: PASS, SKIP, or REQUIRED_SKIPPED.
classify_service_gate_log() {
    local log="$1" require_execution="$2"
    if service_gate_log_abstained "$log"; then
        if [[ "$require_execution" == "required" ]]; then
            printf 'REQUIRED_SKIPPED\n'
        else
            printf 'SKIP\n'
        fi
        return 0
    fi
    printf 'PASS\n'
}

# The abstain reason: text after SKIPPED (or the marker line), without the marker or a leading colon.
service_gate_skip_reason() {
    local line reason
    line="$(grep -m1 -E '\[skip\].*SKIPPED' "$1" || grep -m1 -F -- "$PRECONDITION_MISSING_MARKER" "$1" || true)"
    case "$line" in
        *SKIPPED*) reason="${line#*SKIPPED}" ;;
        *) reason="$line" ;;
    esac
    # awk index(), not ${var//pattern/}: the marker's brackets are a glob class to bash 3.2.
    reason="$(printf '%s' "$reason" | awk -v m="$PRECONDITION_MISSING_MARKER" \
        '{ i = index($0, m); while (i > 0) { $0 = substr($0, 1, i - 1) substr($0, i + length(m)); i = index($0, m) } print }')"
    reason="$(printf '%s' "$reason" | sed -e 's/^[[:space:]]*//' -e 's/^://' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s\n' "${reason:-no reason given}"
}

# The 1.1.0 rule, kept only as the selftest's negative control: a normal gate that exited 0 was PASS
# whatever it printed, and only a `required` gate treated a SKIPPED line as a failure.
legacy_classify_service_gate_log() {
    local log="$1" require_execution="$2"
    if [[ "$require_execution" == "required" ]] && grep -Eq '\[skip\].*SKIPPED' "$log"; then
        printf 'REQUIRED_SKIPPED\n'
        return 0
    fi
    printf 'PASS\n'
}

# Deterministic selftest: fixture gate logs in "$1", Swift marker source at "$2".
service_gate_classifier_selftest() {
    local dir="$1" swift_source="$2" fail=0 lying_verdict honest_verdict marker_verdict
    mkdir -p "$dir" || return 1
    local abstain="$dir/abstain.log" pass="$dir/pass.log" lying="$dir/lying.log"
    local partial="$dir/partial.log" bare="$dir/bare-marker.log"
    printf '%s\n' \
        "[skip] [codex-catalog-live] SKIPPED: apparatus unavailable: Codex was not found in ChatGPT.app. $PRECONDITION_MISSING_MARKER" \
        >"$abstain"
    printf '%s\n' '[codex-catalog-live] diagnostic=current stale=false rows=9 visible=7' \
        '[codex-catalog-live] PASS real app-server handshake produced a current catalog' >"$pass"
    printf '%s\n' \
        "[skip] [codex-device-auth-live] SKIPPED: Codex CLI not found at any supported ChatGPT.app location $PRECONDITION_MISSING_MARKER" \
        '[codex-device-auth-live] PASS real device-auth output yielded host=auth.openai.com' >"$lying"
    printf '%s\n' '[lmstudio-model-catalog-live] [skip] SKIPPED vision-helper assertion: none loaded' \
        '[lmstudio-model-catalog-live] PASS models=3' >"$partial"
    printf '%s\n' "lms CLI is not installed $PRECONDITION_MISSING_MARKER" >"$bare"

    expect() {
        if [[ "$2" == "$3" ]]; then
            printf '  [ok ] %s\n' "$1"
        else
            printf '  [FAIL] %s: expected %s, got %s\n' "$1" "$3" "$2"
            fail=1
        fi
    }
    expect "abstain with a missing precondition is SKIP, not PASS" \
        "$(classify_service_gate_log "$abstain" normal)" SKIP
    expect "abstain reason is extracted without the marker" \
        "$(service_gate_skip_reason "$abstain")" \
        "apparatus unavailable: Codex was not found in ChatGPT.app."
    expect "abstain on a required gate is a failure" \
        "$(classify_service_gate_log "$abstain" required)" REQUIRED_SKIPPED
    expect "a bare precondition marker is SKIP" "$(classify_service_gate_log "$bare" normal)" SKIP
    expect "a bare marker still yields its reason" "$(service_gate_skip_reason "$bare")" \
        "lms CLI is not installed"
    expect "a gate that ran and passed is PASS" "$(classify_service_gate_log "$pass" normal)" PASS
    expect "a partial skip is not a full PASS" "$(classify_service_gate_log "$partial" normal)" SKIP
    if service_gate_log_contradicts "$lying"; then lying_verdict=FAIL; else lying_verdict=PASS; fi
    expect "meta-gate: PASS beside the precondition marker fails" "$lying_verdict" FAIL
    if service_gate_log_contradicts "$abstain" || service_gate_log_contradicts "$pass" \
        || service_gate_log_contradicts "$partial"; then honest_verdict=FAIL; else honest_verdict=PASS; fi
    expect "meta-gate: honest abstains and honest passes are not contradictions" "$honest_verdict" PASS
    # Negative control: the 1.1.0 classifier, which must be what this selftest tells apart.
    expect "mutant: the 1.1.0 classifier reported the abstain as PASS" \
        "$(legacy_classify_service_gate_log "$abstain" normal)" PASS
    expect "mutant: the 1.1.0 classifier reported the lying gate as PASS" \
        "$(legacy_classify_service_gate_log "$lying" normal)" PASS
    # The Swift gates and this classifier must agree on the marker byte for byte.
    if grep -Fq -- "static let preconditionMissingMarker = \"$PRECONDITION_MISSING_MARKER\"" "$swift_source"; then
        marker_verdict=same
    else
        marker_verdict=drifted
    fi
    expect "the Swift abstain marker equals the shell marker" "$marker_verdict" same
    return "$fail"
}
