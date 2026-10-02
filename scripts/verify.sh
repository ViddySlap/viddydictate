#!/usr/bin/env bash
# Tiered ViddyDictate verification rail. Run from the repository root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/service-gate-classify.sh
source "$ROOT/scripts/service-gate-classify.sh"

APP="$ROOT/build/ViddyDictate.app/Contents/MacOS/ViddyDictate"
TEST_APP="$ROOT/build/ViddyDictateTests.app/Contents/MacOS/ViddyDictateTests"
CODEX_RUNNER="$ROOT/build/ViddyDictate.app/Contents/Helpers/CodexContainmentRunner"
CODEX_AUDIT="$ROOT/build/ViddyDictate.app/Contents/Helpers/CodexIsolationAuthenticatedAudit"
CODEX_SMOKE="$ROOT/build/ViddyDictate.app/Contents/Helpers/CodexProviderSmoke"
ORIGINAL_HOME="${HOME:-/Users/$(id -un)}"
SCRATCH="$(mktemp -d /private/tmp/viddydictate-verify.XXXXXX)"
SCRATCH_HOME="$SCRATCH/home"
SCRATCH_TMP="$SCRATCH/tmp"
VERIFY_BUNDLE_ID="com.viddydictate.app.verify.$(basename "$SCRATCH")"
mkdir -p "$SCRATCH_HOME/Library/Logs" "$SCRATCH_HOME/Library/Preferences" "$SCRATCH_TMP"
cleanup_scratch() {
    defaults delete "$VERIFY_BUNDLE_ID" >/dev/null 2>&1 || true
    # A Codex bundle snapshot in the scratch home is read-only all the way down (about 230 MB for the
    # real CLI), and rm cannot unlink inside a 0500 directory. find does not follow the symlinks the
    # services tier plants into the real HOME, and -type d never matches one.
    find "$SCRATCH" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup_scratch EXIT

FAILURES=0
UNVERIFIED=0
SKIPPED=0

usage() {
    cat <<'EOF'
Usage: ./scripts/verify.sh deterministic|services|gui|full

  deterministic  Offline build plus pure/scratch-only selftests.
  services       Real LM Studio, Claude subscription, web-search, and residency checks.
  gui            HUD render/probe plus non-capture input-device diagnostics.
  full           deterministic + services + gui, then clean diff/worktree gates.

  VD_ALLOW_LIVE_CODEX_STORE=1  run the two Codex store-writing service gates against the real HOME.
                               This MODIFIES and PRUNES the live Codex store. Default: scratch home.

Host-only Codex pin audit after a deterministic build:
  build/ViddyDictateTests.app/Contents/MacOS/ViddyDictateTests --codex-feature-inventory [--binary <absolute-path>]
EOF
}

banner() {
    printf '\n[verify][%s] %s\n' "$1" "$2"
}

record_failure() {
    FAILURES=$((FAILURES + 1))
    printf '[verify][%s][FAIL] %s\n' "$1" "$2"
}

record_unverified() {
    UNVERIFIED=$((UNVERIFIED + 1))
    printf '[verify][%s][UNVERIFIED] %s\n' "$1" "$2"
}

# A gate that abstained: not a failure, and never a PASS.
record_skip() {
    SKIPPED=$((SKIPPED + 1))
    printf '[verify][%s][SKIP] %s\n' "$1" "$2"
}

run_gate() {
    local kind="$1"
    local label="$2"
    shift 2
    banner "$kind" "$label"
    "$@"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '[verify][%s][PASS] %s\n' "$kind" "$label"
    else
        record_failure "$kind" "$label (exit $rc)"
    fi
    return "$rc"
}

run_service_gate() {
    local label="$1"
    local require_execution="$2"
    shift 2
    local log="$SCRATCH/service-${label//[^a-zA-Z0-9]/-}.log"
    banner service "$label"
    "$@" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        record_failure service "$label: dependency or product gate failed (exit $rc)"
        return "$rc"
    fi
    case "$(classify_service_gate_log "$log" "$require_execution")" in
        REQUIRED_SKIPPED)
            record_failure service "$label: required external smoke was skipped"
            return 1
            ;;
        SKIP)
            record_skip service "$label: $(service_gate_skip_reason "$log")"
            return 0
            ;;
    esac
    printf '[verify][service][PASS] %s\n' "$label"
    return 0
}

# Meta-gate after the services tier: no gate may report a missing precondition AND a PASS.
check_service_gate_contradictions() {
    local log bad=0
    for log in "$SCRATCH"/service-*.log; do
        [[ -f "$log" ]] || continue
        if service_gate_log_contradicts "$log"; then
            printf '[verify][service][FAIL] %s prints both a PASS line and %s\n' \
                "$(basename "$log")" "$PRECONDITION_MISSING_MARKER"
            bad=1
        fi
    done
    return "$bad"
}

resolve_claude_binary() {
    local candidate
    for candidate in \
        "$ORIGINAL_HOME/.local/bin/claude" \
        "/opt/homebrew/bin/claude" \
        "/usr/local/bin/claude" \
        "$ORIGINAL_HOME/.claude/local/claude"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

loopback_bind_is_sandbox_denied() {
    command -v nc >/dev/null 2>&1 || return 1
    local err="$SCRATCH/loopback-bind.err"
    nc -l 127.0.0.1 0 >/dev/null 2>"$err" &
    local pid=$!
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 1
    fi
    wait "$pid" 2>/dev/null || true
    grep -Eqi 'operation not permitted|permission denied' "$err"
}

run_notes_http_gate() {
    local log="$SCRATCH/notes-http-selftest.log"
    banner deterministic "notes HTTP scratch-loopback selftest"
    env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        "$TEST_APP" --notes-http-selftest 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        printf '[verify][deterministic][PASS] notes HTTP scratch-loopback selftest\n'
        return 0
    fi
    if grep -Fq 'start() returned no port' "$log" && loopback_bind_is_sandbox_denied; then
        record_unverified deterministic \
            "notes HTTP transport: managed sandbox denies every loopback bind; host/conductor confirmation remains required"
        return 0
    fi
    record_failure deterministic "notes HTTP scratch-loopback selftest (exit $rc)"
    return "$rc"
}

run_codex_isolation_selftest_gate() {
    local log="$SCRATCH/codex-isolation-selftest.log"
    banner deterministic "Codex S1 isolation selftest (synthetic/offline)"
    env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        "$TEST_APP" --codex-isolation-selftest --runner "$CODEX_RUNNER" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        record_failure deterministic "Codex S1 isolation selftest (exit $rc)"
        return "$rc"
    fi
    if grep -Fq 'outer sandbox denied nested sandbox_apply' "$log" || grep -Fq 'SANDBOX GATES' "$log"; then
        record_unverified deterministic \
            "Codex S1 isolation selftest: outer sandbox denies nested sandbox_apply; host/conductor confirmation remains required"
        return 0
    fi
    printf '[verify][deterministic][PASS] Codex S1 isolation selftest (synthetic/offline)\n'
    return 0
}

# Host gate: the real Codex bundle-snapshot install on this machine's filesystem with its own codesign.
# Without codesign it abstains with [precondition-missing], which is counted as SKIP, never PASS. On macOS
# an abstain is a failure: the Mac's deterministic tier must not skip the one gate that runs on APFS,
# where rename(2) of a 0500 directory fails and Linux never shows it.
run_codex_bundle_snapshot_host_gate() {
    local label="Codex bundle snapshot install on the host filesystem (real codesign; APFS on macOS)"
    local log="$SCRATCH/codex-bundle-snapshot-host.log"
    banner deterministic "$label"
    env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        "$TEST_APP" --codex-bundle-snapshot-host-selftest 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        record_failure deterministic "$label (exit $rc)"
        return "$rc"
    fi
    if service_gate_log_abstained "$log"; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            record_failure deterministic "$label: abstained on macOS, where codesign and APFS are required"
            return 1
        fi
        record_skip deterministic "$label: $(service_gate_skip_reason "$log")"
        return 0
    fi
    printf '[verify][deterministic][PASS] %s\n' "$label"
    return 0
}

# Mirrors run_codex_isolation_selftest_gate. A seatbelted worker gets EPERM for the two
# `vm.global_*` sysctls (measured 2026-08-24) while `hw.memsize` and HOST_VM_INFO64 succeed, so an
# environment that cannot read the kernel's wire ceiling reports UNVERIFIED rather than FAIL. The
# pure slider mapping is asserted either way, and the unsandboxed review link proves the invariant.
run_system_memory_selftest_gate() {
    local log="$SCRATCH/system-memory-selftest.log"
    banner deterministic "system memory facts and budget math selftest"
    env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        "$TEST_APP" --system-memory-selftest 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        record_failure deterministic "system memory facts and budget math selftest (exit $rc)"
        return "$rc"
    fi
    if grep -Fq 'KERNEL WIRE FACTS UNAVAILABLE' "$log"; then
        record_unverified deterministic \
            "system memory facts: vm.global_* denied in this environment; the wire-ceiling invariant and budget mapping need the unsandboxed host"
        return 0
    fi
    printf '[verify][deterministic][PASS] system memory facts and budget math selftest\n'
    return 0
}

run_fresh_install_rehearsal() {
    local root="$SCRATCH/fresh-install"
    local home="$root/home"
    local tmp="$home/tmp"
    local app_support="$home/Library/Application Support/ViddyDictate"
    local log="$root/rehearsal.log"
    mkdir -p "$home/Library/Logs" "$home/Library/Preferences" "$tmp"

    banner deterministic "fresh-install production-store rehearsal"
    if [[ -e "$app_support" ]]; then
        record_failure deterministic "fresh-install rehearsal did not start clean: $app_support exists"
        return 1
    fi

    env HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$tmp/" CFPREFERENCES_AVOID_DAEMON=1 \
        VIDDYDICTATE_REAL_HOME="$ORIGINAL_HOME" \
        "$TEST_APP" --fresh-install-rehearsal 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    local populated=0
    if [[ -d "$app_support" && -n "$(find "$app_support" -mindepth 1 -print -quit)" ]]; then
        populated=1
        printf '[verify][deterministic][PASS] fresh-install scratch Application Support populated: %s\n' \
            "$app_support"
    else
        record_failure deterministic \
            "fresh-install isolation did not take: scratch Application Support is empty"
    fi

    if [[ $rc -ne 0 ]]; then
        record_failure deterministic "fresh-install production-store rehearsal (exit $rc)"
        return "$rc"
    fi
    if [[ $populated -ne 1 ]]; then return 1; fi
    printf '[verify][deterministic][PASS] fresh-install production-store rehearsal\n'
    return 0
}

check_selftest_flag_drift() {
    local manifest="$SCRATCH/selftest-flags.tsv"
    local flag tier missing=0
    env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        "$TEST_APP" --list-selftest-flags >"$manifest" || return $?
    if ! awk -F '\t' '$1 != "" && $2 == "deterministic" { found=1 } END { exit(found ? 0 : 1) }' \
        "$manifest"; then
        printf '[verify][deterministic][FAIL] selftest flag manifest contains no deterministic flags\n'
        return 1
    fi
    while IFS=$'\t' read -r flag tier; do
        [[ "$tier" == "deterministic" ]] || continue
        if ! grep -Fq -- "$flag" "$ROOT/scripts/verify.sh"; then
            printf '[verify][deterministic][FAIL] selftest flag %s not exercised by any verify.sh gate\n' "$flag"
            missing=1
        fi
    done <"$manifest"
    return "$missing"
}

assert_shipped_rejects_moved_flags() {
    local flag rc log waited pid fail=0
    while IFS=$'\t' read -r flag _tier; do
        [[ -n "$flag" ]] || continue
        log="$SCRATCH/reject-${flag//[^a-zA-Z0-9]/-}.log"
        env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$APP" "$flag" >"$log" 2>&1 &
        pid=$!
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.2
            waited=$((waited + 1))
            if (( waited >= 25 )); then
                kill -TERM "$pid" 2>/dev/null
                wait "$pid" 2>/dev/null
                printf '[verify][deterministic][FAIL] shipped app did NOT exit on %s (fell through to app.run)\n' "$flag"
                fail=1
                continue 2
            fi
        done
        wait "$pid"
        rc=$?
        if (( rc == 0 )); then
            printf '[verify][deterministic][FAIL] shipped app exited 0 on moved flag %s\n' "$flag"
            fail=1
        elif ! grep -Fq 'ViddyDictateTests.app' "$log"; then
            printf '[verify][deterministic][FAIL] shipped app rejected %s without the moved-to-test-bundle message\n' "$flag"
            fail=1
        fi
    done < <( { env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        "$TEST_APP" --list-selftest-flags; printf '%s\tmeta\n' '--list-selftest-flags'; } )
    return "$fail"
}

assert_shipped_has_no_selftest_symbols() {
    local name leak=0 nm_out types
    # Top-level declarations name every SelfTest base type; nested type symbols also contain the
    # enclosing top-level type name. Anchoring avoids extracting declaration-like prose/fixtures.
    types=$(grep -hoE '^(private |fileprivate |internal |package |public |open |final |indirect |nonisolated )*(enum|struct|class|actor|protocol) +[A-Za-z_][A-Za-z0-9_]*' \
        "$ROOT"/Sources/SelfTest/*.swift | awk '{print $NF}' | sort -u)
    if [[ -z "$types" ]]; then
        printf '[verify][deterministic][FAIL] nm gate found no SelfTest type names to check (extraction broke)\n'
        return 1
    fi
    if ! nm_out=$(nm "$APP" 2>/dev/null); then
        printf '[verify][deterministic][FAIL] nm gate could not inspect shipped binary\n'
        return 1
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if grep -q -- "$name" <<<"$nm_out"; then
            printf '[verify][deterministic][FAIL] shipped binary links SelfTest type symbol: %s\n' "$name"
            leak=1
        fi
    done <<<"$types"
    return "$leak"
}

gui_failure_is_environmental() {
    local log="$1"
    grep -Eqi \
        'no screen|WindowServer.*(denied|unavailable)|CGS.*(denied|not permitted|invalid connection)|not permitted by sandbox|operation not permitted.*(AppKit|WindowServer)' \
        "$log"
}

run_gui_gate() {
    local label="$1"
    shift
    local log="$SCRATCH/gui-${label//[^a-zA-Z0-9]/-}.log"
    banner gui "$label"
    "$@" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        printf '[verify][gui][PASS] %s\n' "$label"
        return 0
    fi
    if gui_failure_is_environmental "$log"; then
        record_unverified gui "$label: GUI/AppKit environment unavailable (exit $rc)"
        return 0
    fi
    record_failure gui "$label (exit $rc)"
    return "$rc"
}

finish_tier() {
    local tier="$1"
    local failures_before="$2"
    local unverified_before="$3"
    local skipped_before="${4:-$SKIPPED}"
    local failed=$((FAILURES - failures_before))
    local unverified=$((UNVERIFIED - unverified_before))
    local skipped=$((SKIPPED - skipped_before))
    if [[ $failed -ne 0 ]]; then
        printf '\n[verify][%s] FAIL: %d required gate(s) red; %d unverified; %d skipped\n' \
            "$tier" "$failed" "$unverified" "$skipped"
        return 1
    fi
    if [[ $skipped -ne 0 ]]; then
        printf '\n[verify][%s] PASS WITH %d SKIPPED GATE(S) (NOT PASSED) AND %d EXPLICIT UNVERIFIED SANDBOX GATE(S)\n' \
            "$tier" "$skipped" "$unverified"
    elif [[ $unverified -ne 0 ]]; then
        printf '\n[verify][%s] PASS WITH %d EXPLICIT UNVERIFIED SANDBOX GATE(S)\n' "$tier" "$unverified"
    else
        printf '\n[verify][%s] PASS\n' "$tier"
    fi
    return 0
}

tier_deterministic() {
    local failures_before=$FAILURES
    local unverified_before=$UNVERIFIED
    local skipped_before=$SKIPPED
    local build_ok=1

    run_gate deterministic "Whisper tail corpus harness structural selftest" \
        python3 "$ROOT/scripts/proof-tail-clock-corpus.py" --self-test || true

    run_gate deterministic "Whisper tail audio-clock structural selftest" \
        python3 "$ROOT/scripts/test-whisper-tail-clock.py" || true

    run_gate deterministic "Whisper daemon offline-first warm and phase health (socket-guarded, mutants)" \
        python3 "$ROOT/scripts/test-whisperd-offline-warm.py" || true

    if [[ ! -d node_modules ]]; then
        record_failure deterministic \
            "node_modules is absent; refusing build-web.sh because its fallback npm install may use the network"
        build_ok=0
    else
        run_gate deterministic "web bundle build and DOM fixtures" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            ./build-web.sh || build_ok=0
    fi

    run_gate deterministic "native app build (isolated, ad-hoc signed verification artifact)" \
        env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
        ./build.sh || build_ok=0

    if [[ -x "$APP" ]]; then
        run_gate deterministic "shipped binary carries no SelfTest symbols" \
            assert_shipped_has_no_selftest_symbols || true
    fi

    run_gate deterministic "verification test app executable" test -x "$TEST_APP" || build_ok=0

    if [[ $build_ok -eq 1 && -x "$APP" && -x "$TEST_APP" ]]; then
        run_gate deterministic "custom-mode scratch selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --custommode-selftest || true
        run_gate deterministic "sticky skill model/store/registry scratch selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --sticky-skill-selftest || true
        run_fresh_install_rehearsal || true
        run_gate deterministic "network path awareness and download gate selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --network-path-selftest || true
        run_gate deterministic "LM Studio bootstrap mechanism selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --lmstudio-installer-selftest || true
        run_gate deterministic "LM Studio installed-model catalog fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --lmstudio-model-catalog-selftest || true
        run_gate deterministic "Ollama catalog fixture selftest (tags/show/ps, negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --ollama-catalog-selftest || true
        run_gate deterministic "Ollama chat translator fixture selftest (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --ollama-transport-selftest || true
        run_gate deterministic "Ollama backend scripted-transport selftest (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --ollama-backend-selftest || true
        run_gate deterministic "typed provider/route/bundle migration selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --model-routing-selftest || true
        run_gate deterministic "local-backend identity + bundle codec fixture selftest (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-backend-codec-selftest || true
        run_gate deterministic "availability-resolved routing selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --availability-routing-selftest || true
        run_gate deterministic "Models & Power settings/storage selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --models-power-selftest || true
        run_gate deterministic "every built-in default reads Staff pick, ratification stays internal (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --staff-picks-copy-selftest || true
        run_gate deterministic "Local model picker over both local apps, labelled only when both (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-picker-merge-selftest || true
        run_system_memory_selftest_gate || true
        run_gate deterministic "local model capacity policy fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --model-capacity-selftest || true
        run_gate deterministic "local capacity across both apps: tags+KV estimate, (app, id) eviction, D5 reuse (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-capacity-backends-selftest || true
        run_gate deterministic "each local transform on the app its route resolved to: num_ctx, think, keep_alive (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --ollama-client-wiring-selftest || true
        run_gate deterministic "prompt overlay store selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --prompt-overlay-selftest || true
        run_gate deterministic "prompt workstation assembly selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --prompt-workstation-selftest || true
        run_gate deterministic "prompt workstation test bench selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --prompt-test-bench-selftest || true
        run_gate deterministic "Claude model freshness parser and preset policy selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --model-freshness-selftest || true
        run_gate deterministic "settings identifier-prefix characterization selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --settings-prefix-selftest || true
        run_gate deterministic "settings default and stored-preference selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --settings-defaults-selftest || true
        run_gate deterministic "bundled Python runtime staged, relocatable, and sealed" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --bundled-python-selftest --app "$ROOT/build/ViddyDictate.app" || true
        run_gate deterministic "headless installer engine and retry/hash policy selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --installer-engine-selftest || true
        run_gate deterministic "Ollama installer trust chain, approval wait, and pull progress (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --ollama-installer-selftest || true
        run_gate deterministic "local-app install plan, lms-ready order, and D3 app choice (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --installer-local-steps-selftest || true
        run_gate deterministic "point-of-use install offer and zero-local cloud-button selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --point-of-use-offer-selftest || true
        run_gate deterministic "bootstrap lifecycle and degraded-state selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --bootstrap-state-selftest || true
        run_gate deterministic "first-run component picker sizes, RAM tiers, and running total" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --component-picker-selftest || true
        run_gate deterministic "first-run setup LM Studio/Ollama/Skip choice, Ollama plan, first-launch rule (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --first-run-setup-selftest || true
        run_gate deterministic "Feature Tour covers every built-in hotkey, live chords, first-show rule (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --feature-tour-selftest || true
        run_gate deterministic "first-run progress bytes, speed, no-ETA pin, and permission anchors" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --install-progress-selftest || true
        run_gate deterministic "first-run preflight message and never-block selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --preflight-selftest || true
        run_gate deterministic "setup surface preflight presentation selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --preflight-surface-selftest || true
        run_gate deterministic "provider onboarding signed-out vs not-installed selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --provider-onboarding-selftest || true
        run_gate deterministic "Gemini key section copy, save policy, and never-echo selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --gemini-key-setup-selftest || true
        run_gate deterministic "local model budget rendering and LM Studio JIT reader selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-model-setup-selftest || true
        run_gate deterministic "Setup local app rows, LM Studio-first app choice, and Retry wording (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-apps-setup-selftest || true
        run_gate deterministic "secret-store resolution order and off-state selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --secret-store-selftest || true
        run_gate deterministic "provider-neutral transform privacy/process selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --text-transform-selftest || true
        run_gate deterministic "Claude transport escaped-pipe-holder drain deadline repro" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --text-transform-selftest --cloud-drain-deadlock-repro || true
        run_gate deterministic "web-search argv/stdin/log privacy selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --websearch-transport-selftest || true
        run_gate deterministic "production Codex provider synthetic selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --codex-provider-selftest || true
        run_gate deterministic "Codex feature inventory parser and diff selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --codex-feature-inventory-selftest || true
        run_gate deterministic "Codex app-server catalog transport/cache fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --codex-model-catalog-selftest || true
        run_gate deterministic "Claude /v1/models catalog transport and migration policy selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --claude-model-catalog-selftest || true
        run_gate deterministic "Claude auth-status parser and whitelist mapping selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --claude-auth-status-selftest || true
        run_gate deterministic "Claude connect flow no-reauth, poll, and bound selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --claude-connect-flow-selftest || true
        run_gate deterministic "trailing near-silence audio trim synthetic selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --audio-trim-selftest || true
        run_gate deterministic "Codex S2 separate-group cleanup fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$CODEX_AUDIT" --cleanup-selftest || true
        run_gate deterministic "Codex authenticated login runner passthrough fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$CODEX_RUNNER" audit-login-selftest || true
        run_gate deterministic "Codex containment mach-lookup allowlist and policy-widening mutants selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$CODEX_RUNNER" mach-lookup-policy-selftest || true
        run_gate deterministic "Codex S2 login AUTH-GATE fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$CODEX_AUDIT" --login-gate-selftest || true
        run_gate deterministic "Power Mode, migration, provider-independence, and battery-advisory selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --lowpower-selftest || true
        run_gate deterministic "HUD font and picker-layout characterization selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --hud-polish-selftest || true
        run_gate deterministic "dictation-history stores scratch selftests" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --history-selftest --encoder-samples "$SCRATCH/rolling-history-encoder-samples" || true
        run_gate deterministic "locked captured-target delivery recovery selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --locked-delivery-selftest || true
        run_gate deterministic "path classifier and backup scratch probe" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --path-classifier-probe || true
        run_gate deterministic "files mode foundation scratch probe" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --files-probe || true
        run_gate deterministic "files mode clobber scratch probe" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --clobber-probe || true
        run_gate deterministic "files mode diff3 merge scratch probe" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --merge-probe || true
        run_gate deterministic "notes store and bridge scratch probe" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --notes-probe || true
        run_gate deterministic "hang watchdog policy, live mechanism, and source rules" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --hang-watchdog-selftest || true
        run_notes_http_gate || true
        run_codex_isolation_selftest_gate || true
        run_gate deterministic "model-fit search-retrieval arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-selftest --only search-retrieval || true
        run_gate deterministic "model-fit fit arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-selftest --only fit || true
        run_gate deterministic "model-fit retry arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-selftest --only retry || true
        run_gate deterministic "model-fit catalog arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-selftest --only catalog || true
        run_gate deterministic "model-fit seed arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-selftest --only seed || true
        run_gate deterministic "model-fit preference control arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-selftest --only preference || true
        run_gate deterministic "model-fit retry wiring arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --modelfit-wiring-selftest || true
        run_gate deterministic "resident models are not charged twice by route fit (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --resident-fit-selftest || true
        run_gate deterministic "search-retrieval local-only selftest (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --search-retrieval-local-only-selftest || true
        run_gate deterministic "local routing by app and model, cross-app step-down (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-backend-routing-selftest || true
        run_gate deterministic "untouched routes follow the Preferred local app's staff picks (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --staff-pick-follows-app-selftest || true
        run_gate deterministic "merged local presence and pinned-app start (negative controls)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --local-presence-selftest || true
        run_gate deterministic "app-update compare arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --app-update-selftest --only compare || true
        run_gate deterministic "app-update failures arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --app-update-selftest --only failures || true
        run_gate deterministic "app-update nag arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --app-update-selftest --only nag || true
        run_gate deterministic "app-update link arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --app-update-selftest --only link || true
        run_gate deterministic "app-update control arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --app-update-selftest --only control || true
        run_gate deterministic "daemon-install bundled arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --daemon-install-selftest --only bundled || true
        run_gate deterministic "daemon-install installs arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --daemon-install-selftest --only installs || true
        run_gate deterministic "daemon-install upgrade arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --daemon-install-selftest --only upgrade || true
        run_gate deterministic "daemon-install absent arm" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --daemon-install-selftest --only absent || true
        run_gate deterministic "whisperd agent bootstrapped when not loaded, never twice (kickstart-only control)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --whisperd-agent-load-selftest || true
        run_gate deterministic "Setup install remedy names the real first-run setup button (old wording control)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --setup-remedy-copy-selftest || true
        run_gate deterministic "daemon warming HUD phase fixture selftest (ignore-phase mutant caught)" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --daemon-warming-hud-selftest || true
        run_gate deterministic "Codex restrictive config is valid TOML with dotted feature keys" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --codex-config-toml-selftest || true
        run_gate deterministic "Codex CLI location, bundle snapshot addressing, and retention" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --codex-cli-location-selftest || true
        run_gate deterministic "Codex not-found vs could-not-be-sandboxed sentences on every surface" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --codex-boundary-sentence-selftest || true
        run_codex_bundle_snapshot_host_gate || true
        run_gate deterministic "service-gate classifier: an abstaining gate is never PASS" \
            service_gate_classifier_selftest "$SCRATCH/service-gate-classifier" \
            "$ROOT/Sources/SelfTest/SelfTestAbstain.swift" "$ROOT/Tools/CodexProviderSmoke.swift" || true
    else
        record_failure deterministic "selftests skipped because the verification build did not succeed"
    fi

    run_gate deterministic "git diff whitespace check" git diff --check || true
    run_gate deterministic "selftest-flag manifest drift check" check_selftest_flag_drift || true
    if [[ -x "$APP" && -x "$TEST_APP" ]]; then
        run_gate deterministic "shipped app rejects moved selftest flags" \
            assert_shipped_rejects_moved_flags || true
    fi
    finish_tier deterministic "$failures_before" "$unverified_before" "$skipped_before"
}

require_built_app() {
    local tier="$1"
    if [[ -x "$APP" && -x "$TEST_APP" ]]; then return 0; fi
    record_failure "$tier" "shipped or test app missing; run ./scripts/verify.sh deterministic first"
    return 1
}

stage_service_home_dependencies() {
    # Service binaries use NSHomeDirectory() to find these installed user-home dependencies. Keep
    # CFFIXED_USER_HOME pointed at the scratch home so Foundation preferences, Application Support,
    # and logs stay isolated, and expose only the exact dependency paths the existing gates require.
    # The links disappear with $SCRATCH; no credential or real app-data contents are copied or read here.
    local relative target link
    local dependencies=(
        ".claude/.credentials.json"
        ".local/share/viddydictate/venv"
        ".local/share/viddydictate/websearch.py"
    )
    for relative in "${dependencies[@]}"; do
        target="$ORIGINAL_HOME/$relative"
        link="$SCRATCH_HOME/$relative"
        if [[ -e "$target" ]]; then
            mkdir -p "$(dirname "$link")"
            ln -s "$target" "$link"
        fi
    done

    # These CLIs need their installed home-owned state at execution time. Temporary wrappers give only
    # the dependency process that HOME; the ViddyDictate selftest process remains fully scratch-isolated.
    local home_bound_executables=(
        ".lmstudio/bin/lms"
        ".local/bin/claude"
    )
    for relative in "${home_bound_executables[@]}"; do
        target="$ORIGINAL_HOME/$relative"
        link="$SCRATCH_HOME/$relative"
        if [[ -x "$target" ]]; then
            mkdir -p "$(dirname "$link")"
            printf '#!/bin/sh\nHOME="%s" exec "%s" "$@"\n' "$ORIGINAL_HOME" "$target" >"$link"
            chmod 700 "$link"
        fi
    done
}

stage_service_bundle() {
    # UserDefaults.standard keys off the app bundle identifier, not HOME. Give service processes a
    # temporary copy with a per-run identifier so no live preference (including Low Power or custom
    # prompts) can enter a test. The built verification artifact is untouched; the copy is invoked only
    # through the existing headless selftest flags, never launched as the GUI app.
    local service_bundle="$SCRATCH/ViddyDictateVerify.app"
    ditto "$ROOT/build/ViddyDictateTests.app" "$service_bundle" || return 1
    plutil -replace CFBundleIdentifier -string "$VERIFY_BUNDLE_ID" \
        "$service_bundle/Contents/Info.plist" || return 1
    [[ -x "$service_bundle/Contents/MacOS/ViddyDictateTests" ]]
}

# --- Service-tier memory state -------------------------------------------------------------------------
# The LM Studio service gates each load models and leave them resident (with the app's idle TTL), so a
# later gate ran against whatever the earlier ones left behind: on a 64 GB Mac the residency gate's qwen
# load was refused over budget only because cleanup, email, per-take and web search had left qwen, gemma
# and a step-down model loaded (A/B on 2026-10-01: it passes on a clean machine at base and tip alike).
#
# The tier snapshots what is resident when it starts. That is the user's working set and is never touched.
# After each gate that can load a model, restore_service_memory_state unloads ONLY what is resident now and
# was NOT in that snapshot, one model at a time (never `lms unload --all`), then waits for wired memory to
# settle. Ollama is handled the same way through /api/ps and keep_alive 0. If a snapshot could not be taken
# (no lms, LM Studio not answering, Ollama not running) that app is left alone entirely: without a
# trustworthy baseline every resident model would look like the tier's own.
SERVICE_LMS=""
SERVICE_LMS_BASELINE_OK=0
SERVICE_LMS_BASELINE=""
SERVICE_OLLAMA_URL="http://127.0.0.1:11434"
SERVICE_OLLAMA_BASELINE_OK=0
SERVICE_OLLAMA_BASELINE=""

# Resident LM Studio identifiers, one per line; fails when `lms ps --json` cannot be read.
service_lms_resident() {
    [[ -n "$SERVICE_LMS" ]] || return 1
    local json
    json="$(HOME="$ORIGINAL_HOME" "$SERVICE_LMS" ps --json 2>/dev/null)" || return 1
    json="${json#"${json%%[![:space:]]*}"}"
    [[ "$json" == \[* ]] || return 1
    grep -oE '"identifier"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$json" \
        | sed -E 's/^"identifier"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' || true
}

# Resident Ollama model names, one per line; fails when /api/ps does not answer.
service_ollama_resident() {
    command -v curl >/dev/null 2>&1 || return 1
    local json
    json="$(curl -fsS --max-time 3 "$SERVICE_OLLAMA_URL/api/ps" 2>/dev/null)" || return 1
    [[ "$json" == *'"models"'* ]] || return 1
    grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$json" \
        | sed -E 's/^"name"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' || true
}

service_wired_bytes() {
    command -v vm_stat >/dev/null 2>&1 || return 1
    vm_stat 2>/dev/null | awk '
        /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) page = $i }
        /Pages wired down/ { gsub(/\./, "", $4); wired = $4 }
        END { if (page == "" || wired == "") exit 1; printf "%.0f\n", wired * page }'
}

snapshot_service_memory_state() {
    SERVICE_LMS=""
    if [[ -x "$ORIGINAL_HOME/.lmstudio/bin/lms" ]]; then
        SERVICE_LMS="$ORIGINAL_HOME/.lmstudio/bin/lms"
    fi
    if SERVICE_LMS_BASELINE="$(service_lms_resident)"; then
        SERVICE_LMS_BASELINE_OK=1
        local service_lms_baseline_list
        service_lms_baseline_list="$(tr '\n' ' ' <<<"${SERVICE_LMS_BASELINE:-}" | sed 's/ *$//')"
        printf '[verify][services] LM Studio working set at tier start (never unloaded): %s\n' \
            "${service_lms_baseline_list:-none}"
    else
        SERVICE_LMS_BASELINE_OK=0
        SERVICE_LMS_BASELINE=""
        printf '[verify][services] LM Studio resident set unreadable at tier start (lms %s); its models will not be restored between gates\n' \
            "$([[ -n "$SERVICE_LMS" ]] && printf 'not answering' || printf 'absent')"
    fi
    if SERVICE_OLLAMA_BASELINE="$(service_ollama_resident)"; then
        SERVICE_OLLAMA_BASELINE_OK=1
        local service_ollama_baseline_list
        service_ollama_baseline_list="$(tr '\n' ' ' <<<"${SERVICE_OLLAMA_BASELINE:-}" | sed 's/ *$//')"
        printf '[verify][services] Ollama working set at tier start (never unloaded): %s\n' \
            "${service_ollama_baseline_list:-none}"
    else
        SERVICE_OLLAMA_BASELINE_OK=0
        SERVICE_OLLAMA_BASELINE=""
        printf '[verify][services] Ollama not answering at tier start; its models will not be restored between gates\n'
    fi
}

# Unload what the tier's own gates left resident, then let wired memory settle. Never fails the tier.
restore_service_memory_state() {
    local after="$1" model unloaded=0 now
    if [[ $SERVICE_LMS_BASELINE_OK -eq 1 ]] && now="$(service_lms_resident)"; then
        while IFS= read -r model; do
            [[ -n "$model" ]] || continue
            grep -Fxq -- "$model" <<<"$SERVICE_LMS_BASELINE" && continue
            printf '[verify][services] after %s: unloading LM Studio %s (not resident at tier start)\n' "$after" "$model"
            HOME="$ORIGINAL_HOME" "$SERVICE_LMS" unload "$model" >/dev/null 2>&1 \
                || printf '[verify][services] after %s: lms unload %s failed; continuing\n' "$after" "$model"
            unloaded=$((unloaded + 1))
        done <<<"$now"
    fi
    if [[ $SERVICE_OLLAMA_BASELINE_OK -eq 1 ]] && now="$(service_ollama_resident)"; then
        while IFS= read -r model; do
            [[ -n "$model" ]] || continue
            grep -Fxq -- "$model" <<<"$SERVICE_OLLAMA_BASELINE" && continue
            printf '[verify][services] after %s: unloading Ollama %s (not resident at tier start)\n' "$after" "$model"
            curl -fsS --max-time 10 -X POST "$SERVICE_OLLAMA_URL/api/generate" \
                -H 'Content-Type: application/json' \
                -d "{\"model\":\"$model\",\"keep_alive\":0}" >/dev/null 2>&1 \
                || printf '[verify][services] after %s: Ollama keep_alive 0 for %s failed; continuing\n' "$after" "$model"
            unloaded=$((unloaded + 1))
        done <<<"$now"
    fi
    (( unloaded > 0 )) || return 0

    # `lms unload` returns before macOS unwires the pages (ModelManager measured ~0.7 s). Wait, bounded,
    # until two readings 0.25 s apart agree within 64 MiB.
    local previous="" current waited=0
    while (( waited < 40 )); do
        current="$(service_wired_bytes)" || break
        if [[ -n "$previous" ]]; then
            local delta=$(( current > previous ? current - previous : previous - current ))
            (( delta <= 67108864 )) && break
        fi
        previous="$current"
        sleep 0.25
        waited=$((waited + 1))
    done
    printf '[verify][services] after %s: unloaded %d model(s); wired now %s bytes\n' \
        "$after" "$unloaded" "$(service_wired_bytes || printf 'unreadable')"
    return 0
}

# The canonical Codex service gates run the production boundary, which snapshots the vendor CLI into,
# rewrites the compatibility receipt in, and prunes the Codex store under HOME
# (~/Library/Application Support/ViddyDictate/codex-executables, codex-runners, codex-home). On a
# working build that would delete all but two of the existing snapshots in the live store. So by
# default they run in the scratch home: the boundary is exercised for real up to "not logged in", and
# the authenticated part abstains as SKIP with [precondition-missing], never PASS. Only
# VD_ALLOW_LIVE_CODEX_STORE=1, exactly, runs them against the real HOME and its logged-in Codex home.
codex_live_store_allowed() {
    [[ "${VD_ALLOW_LIVE_CODEX_STORE:-}" == "1" ]]
}

announce_codex_store() {
    if codex_live_store_allowed; then
        printf '\n[verify][service][LIVE-CODEX-STORE] VD_ALLOW_LIVE_CODEX_STORE=1: the Codex all-shipped-pair and live catalog gates WILL MODIFY THE LIVE CODEX STORE under %s/Library/Application Support/ViddyDictate: snapshot the installed Codex CLI into codex-executables/, rewrite the compatibility receipt in codex-home/, and PRUNE codex-executables/ to the current snapshot plus one previous.\n' \
            "$ORIGINAL_HOME"
    else
        if [[ -n "${VD_ALLOW_LIVE_CODEX_STORE:-}" ]]; then
            printf '[verify][service] VD_ALLOW_LIVE_CODEX_STORE=%s is not 1; ignored\n' \
                "$VD_ALLOW_LIVE_CODEX_STORE"
        fi
        printf '\n[verify][service] Codex gates use the scratch home and never touch the live Codex store; their authenticated part will SKIP. Set VD_ALLOW_LIVE_CODEX_STORE=1 to run them against the real HOME (modifies and prunes the live store).\n'
    fi
}

tier_services() {
    local failures_before=$FAILURES
    local unverified_before=$UNVERIFIED
    local skipped_before=$SKIPPED
    announce_codex_store
    if require_built_app service; then
        stage_service_home_dependencies
        local service_app="$SCRATCH/ViddyDictateVerify.app/Contents/MacOS/ViddyDictateTests"
        local service_env=(env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" \
            CFPREFERENCES_AVOID_DAEMON=1 TMPDIR="$SCRATCH_TMP/")
        if run_gate service "scratch-isolated service bundle" stage_service_bundle; then
            snapshot_service_memory_state
            # The gate checks the named login-Keychain item without requesting its data, then runs
            # the vendor status command against the real machine HOME. A seatbelt that denies
            # Keychain makes it abstain with exit 0; unsandboxed release verification runs this same
            # gate before exercising the Claude connection flow.
            local claude_auth_binary=""
            claude_auth_binary="$(resolve_claude_binary || true)"
            local claude_auth_command=(
                /usr/bin/env -i
                HOME="$SCRATCH_HOME"
                CFFIXED_USER_HOME="$SCRATCH_HOME"
                USER="$(id -un)"
                LOGNAME="$(id -un)"
                PATH="/usr/bin:/bin"
                LANG="en_US.UTF-8"
                LC_ALL="en_US.UTF-8"
                TERM="dumb"
                CODEX_SANDBOX="${CODEX_SANDBOX:-}"
                CODEX_PERMISSION_PROFILE="${CODEX_PERMISSION_PROFILE:-}"
                "$TEST_APP"
                --claude-auth-status-live
                --status-home "$ORIGINAL_HOME"
            )
            if [[ -n "$claude_auth_binary" ]]; then
                claude_auth_command+=(--binary "$claude_auth_binary")
            fi
            run_service_gate "Claude auth status (real Keychain-backed CLI)" normal \
                "${claude_auth_command[@]}" || true
            run_service_gate "cleanup LM Studio gate" normal "${service_env[@]}" "$service_app" --selftest || true
            restore_service_memory_state "cleanup LM Studio gate"
            run_service_gate "email LM Studio gate" normal "${service_env[@]}" "$service_app" --email-selftest || true
            restore_service_memory_state "email LM Studio gate"
            run_service_gate "per-take armed transform release (live LM Studio)" normal \
                "${service_env[@]}" "$service_app" --per-take-arm-service || true
            restore_service_memory_state "per-take armed transform release"
            run_service_gate "LM Studio available-model discovery" normal \
                "${service_env[@]}" "$service_app" --lmstudio-model-catalog-live || true
            # Loads the smallest usable model that was NOT already resident (keep_alive 20 s, num_ctx 4096),
            # checks /api/ps, unloads it, and requires every foreign resident model to survive. Abstains
            # when Ollama is absent, stopped, or has no usable model. The scratch HOME hides only
            # ~/Applications/Ollama.app; /Applications and the Homebrew CLI are still detected.
            run_service_gate "Ollama live backend (catalog, keep_alive load, unload, foreign models kept)" normal \
                "${service_env[@]}" "$service_app" --ollama-live || true
            # One real cleanup and one real email on gemma4:e4b (20 s keep_alive), then the model must leave
            # /api/ps on its own. Abstains when Ollama or gemma4:e4b is absent, or gemma4:e4b is already resident.
            run_service_gate "Ollama live transforms (cleanup + email on gemma4:e4b, keep_alive unload)" normal \
                "${service_env[@]}" "$service_app" --ollama-transforms-live || true
            restore_service_memory_state "Ollama live gates"
            # Read-only: it never passes --unload-all, so it cannot change what the machine is holding.
            run_service_gate "Setup tab resident-models readout (real lms ps)" normal \
                "${service_env[@]}" "$service_app" --local-models-readout-live || true
            run_service_gate "Claude subscription smoke" required "${service_env[@]}" "$service_app" --cloudmode-selftest || true
            # The whole-note path over a note WITH an attachment, on a PINNED cloud route, with
            # degradation required NOT to fire (locked decision D7). Both cloud providers rejected that
            # invocation outright until 2026-08-12, and no offline tier could see it.
            run_service_gate "sticky skill on a pinned cloud route (whole note + attachment)" required \
                "${service_env[@]}" "$service_app" --sticky-cloud-service || true
            # Codex store: see codex_live_store_allowed. Live: the real HOME, unchanged from before, and
            # the smoke is `required`. Default: HOME and CFFIXED_USER_HOME are the scratch home, the
            # smoke abstains on a not-logged-in home, and it is `normal` so that abstain is SKIP.
            local codex_home_env codex_smoke_requirement codex_smoke_abstain=()
            if codex_live_store_allowed; then
                announce_codex_store
                codex_home_env=(HOME="$ORIGINAL_HOME")
                codex_smoke_requirement=required
            else
                codex_home_env=(HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME")
                codex_smoke_requirement=normal
                codex_smoke_abstain=(--abstain-if-not-logged-in)
            fi
            run_service_gate "Codex subscription all-shipped-pair contained verifier" \
                "$codex_smoke_requirement" \
                /usr/bin/env -i "${codex_home_env[@]}" PATH="/usr/bin:/bin" \
                LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" TERM="dumb" \
                "$CODEX_SMOKE" --all-shipped-pairs --runner "$CODEX_RUNNER" \
                ${codex_smoke_abstain[@]+"${codex_smoke_abstain[@]}"} || true
            # Real app-server handshake. The fixture catalog selftest cannot see vendor
            # protocol drift; this is the gate that does. It needs the production compatibility
            # boundary and an authenticated codex-home, so it reaches the handshake only with
            # VD_ALLOW_LIVE_CODEX_STORE=1; in the scratch home it abstains at "not logged in".
            #
            # `normal` here means EXACTLY "this gate is allowed to skip ITSELF", and nothing more.
            # run_service_gate records a failure on ANY non-zero exit regardless of this argument;
            # `required` only ADDS a failure when the log carries a SKIPPED marker. So a gate that
            # needs absent apparatus must abstain with an exit-0 `[skip] ... SKIPPED` line, which is
            # what this gate now does when the dedicated Codex home is not connected. That abstain is
            # reported as [verify][service][SKIP] and counted, never as PASS. It stays fully
            # blocking on any real handshake that violates expectations.
            run_service_gate "Codex live catalog handshake (real app-server)" normal \
                /usr/bin/env -i "${codex_home_env[@]}" PATH="/usr/bin:/bin" \
                LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" TERM="dumb" \
                "$TEST_APP" \
                --codex-catalog-live --runner "$CODEX_RUNNER" || true
            # Real `codex login --device-auth`, against a throwaway scratch home. The only prior
            # coverage of the device-code parser was a hand-authored plain-ASCII fixture, which
            # passed while production could not parse a single real code. Abstains when offline.
            run_service_gate "Codex live device-auth surfacing (real login command)" normal \
                /usr/bin/env -i HOME="$ORIGINAL_HOME" PATH="/usr/bin:/bin" \
                LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" TERM="dumb" \
                "$TEST_APP" \
                --codex-device-auth-live || true
            # Claude's counterpart to the live Codex gate. It exists because Claude expresses
            # retirement by REMOVING a model, so a response shape this parser stopped understanding
            # would not read as an error - it would read as "everything retired", which is the one
            # input that moves a user's pins. A fixture cannot catch that by construction.
            #
            # `normal` rather than `required` only affects the skip rule, NOT the failure rule: a
            # non-zero exit still reds the tier. The gate abstains (exit 0, SKIPPED) exactly when
            # the vendor is unreachable or unauthenticated, because that is the apparatus rather
            # than the product. Every claim it makes about a response it DID receive is blocking.
            run_service_gate "Claude live catalog fetch (real /v1/models)" normal \
                /usr/bin/env -i HOME="$ORIGINAL_HOME" PATH="/usr/bin:/bin" \
                LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" TERM="dumb" \
                "$TEST_APP" \
                --claude-catalog-live || true
            run_service_gate "web-search pipeline" normal "${service_env[@]}" "$service_app" --websearch-selftest || true
            # The residency gate measures a cold load against the budget, so it must start from the working
            # set the tier found, not from what the gates above left resident.
            restore_service_memory_state "web-search pipeline"
            run_service_gate "LM Studio residency gate" normal "${service_env[@]}" "$service_app" --residency-selftest || true
            restore_service_memory_state "LM Studio residency gate"
            run_gate service "no service gate both passes and reports a missing precondition" \
                check_service_gate_contradictions || true
        fi
    fi
    finish_tier services "$failures_before" "$unverified_before" "$skipped_before"
}

tier_gui() {
    local failures_before=$FAILURES
    local unverified_before=$UNVERIFIED
    if require_built_app gui; then
        local gui_env=(env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/")
        run_gui_gate "Setup tab preflight offscreen render" "${gui_env[@]}" "$TEST_APP" --setup-render "$SCRATCH/setup-render" || true
        run_gui_gate "provider onboarding offscreen render" "${gui_env[@]}" "$TEST_APP" --provider-onboarding-render "$SCRATCH/provider-onboarding-render" || true
        run_gui_gate "first-run component picker offscreen render" "${gui_env[@]}" "$TEST_APP" --component-picker-render "$SCRATCH/component-picker-render" || true
        run_gui_gate "point-of-use install offer offscreen render" "${gui_env[@]}" "$TEST_APP" --point-of-use-render "$SCRATCH/point-of-use-render" || true
        run_gui_gate "first-run progress and permissions offscreen render" "${gui_env[@]}" "$TEST_APP" --install-progress-render "$SCRATCH/install-progress-render" || true
        run_gui_gate "Feature Tour pages offscreen render" "${gui_env[@]}" "$TEST_APP" --feature-tour-render "$SCRATCH/feature-tour-render" || true
        run_gui_gate "Models & Power settings UI probe" "${gui_env[@]}" "$TEST_APP" --models-power-ui-probe || true
        run_gui_gate "Models & Power prompt-override offscreen render" "${gui_env[@]}" "$TEST_APP" --models-power-render "$SCRATCH/models-power-render" || true
        run_gui_gate "consolidated Hotkeys tab offscreen render" "${gui_env[@]}" "$TEST_APP" --hotkeys-tab-render "$SCRATCH/hotkeys-tab-render" || true
        run_gui_gate "Sticky Skills tab offscreen render" "${gui_env[@]}" "$TEST_APP" --sticky-skills-render "$SCRATCH/sticky-skills-render" || true
        run_gui_gate "Sticky Notes undo lifetime offscreen WKWebView" "${gui_env[@]}" "$TEST_APP" --notes-undo-lifetime-probe || true
        run_gui_gate "HUD layout probe" "${gui_env[@]}" "$TEST_APP" --hud-probe || true
        run_gui_gate "HUD offscreen render" "${gui_env[@]}" "$TEST_APP" --hud-render "$SCRATCH/hud-render" || true
        run_gui_gate "non-capture input-device diagnostic" "${gui_env[@]}" "$TEST_APP" --mic-probe || true
    fi
    finish_tier gui "$failures_before" "$unverified_before"
}

full_clean_gate() {
    run_gate full "final git diff whitespace check" git diff --check || true
    banner full "clean worktree check"
    local status
    status="$(git status --short)"
    if [[ -z "$status" ]]; then
        printf '[verify][full][PASS] clean worktree check\n'
    else
        printf '%s\n' "$status"
        record_failure full "worktree is not clean"
    fi
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

case "$1" in
    deterministic)
        tier_deterministic
        exit $?
        ;;
    services)
        tier_services
        exit $?
        ;;
    gui)
        tier_gui
        exit $?
        ;;
    full)
        tier_deterministic || true
        tier_services || true
        tier_gui || true
        full_clean_gate
        if [[ $FAILURES -eq 0 ]]; then
            if [[ $SKIPPED -ne 0 ]]; then
                printf '\n[verify][full] PASS WITH %d SKIPPED GATE(S) (NOT PASSED) AND %d EXPLICIT UNVERIFIED SANDBOX GATE(S)\n' \
                    "$SKIPPED" "$UNVERIFIED"
            elif [[ $UNVERIFIED -eq 0 ]]; then
                printf '\n[verify][full] PASS\n'
            else
                printf '\n[verify][full] PASS WITH %d EXPLICIT UNVERIFIED SANDBOX GATE(S)\n' "$UNVERIFIED"
            fi
            exit 0
        fi
        printf '\n[verify][full] FAIL: %d required gate(s) red; %d unverified; %d skipped\n' \
            "$FAILURES" "$UNVERIFIED" "$SKIPPED"
        exit 1
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
