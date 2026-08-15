#!/usr/bin/env bash
# Tiered ViddyDictate verification rail. Run from the repository root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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
    rm -rf "$SCRATCH"
}
trap cleanup_scratch EXIT

FAILURES=0
UNVERIFIED=0

usage() {
    cat <<'EOF'
Usage: ./scripts/verify.sh deterministic|services|gui|full

  deterministic  Offline build plus pure/scratch-only selftests.
  services       Real LM Studio, Claude subscription, web-search, and residency checks.
  gui            HUD render/probe plus non-capture input-device diagnostics.
  full           deterministic + services + gui, then clean diff/worktree gates.

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
    if [[ "$require_execution" == "required" ]] && grep -Eq '\[skip\].*SKIPPED' "$log"; then
        record_failure service "$label: required external smoke was skipped"
        return 1
    fi
    printf '[verify][service][PASS] %s\n' "$label"
    return 0
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
    if [[ -d "$app_support" ]] && find "$app_support" -mindepth 1 -print -quit | grep -q .; then
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
    local failed=$((FAILURES - failures_before))
    local unverified=$((UNVERIFIED - unverified_before))
    if [[ $failed -ne 0 ]]; then
        printf '\n[verify][%s] FAIL: %d required gate(s) red; %d unverified\n' "$tier" "$failed" "$unverified"
        return 1
    fi
    if [[ $unverified -ne 0 ]]; then
        printf '\n[verify][%s] PASS WITH %d EXPLICIT UNVERIFIED SANDBOX GATE(S)\n' "$tier" "$unverified"
    else
        printf '\n[verify][%s] PASS\n' "$tier"
    fi
    return 0
}

tier_deterministic() {
    local failures_before=$FAILURES
    local unverified_before=$UNVERIFIED
    local build_ok=1

    run_gate deterministic "Whisper tail corpus harness structural selftest" \
        python3 "$ROOT/scripts/proof-tail-clock-corpus.py" --self-test || true

    run_gate deterministic "Whisper tail audio-clock structural selftest" \
        python3 "$ROOT/scripts/test-whisper-tail-clock.py" || true

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
        run_gate deterministic "LM Studio installed-model catalog fixture selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --lmstudio-model-catalog-selftest || true
        run_gate deterministic "typed provider/route/bundle migration selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --model-routing-selftest || true
        run_gate deterministic "availability-resolved routing selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --availability-routing-selftest || true
        run_gate deterministic "Models & Power settings/storage selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --models-power-selftest || true
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
        run_gate deterministic "secret-store resolution order and off-state selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --secret-store-selftest || true
        run_gate deterministic "provider-neutral transform privacy/process selftest" \
            env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/" \
            "$TEST_APP" --text-transform-selftest || true
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
        run_notes_http_gate || true
        run_codex_isolation_selftest_gate || true
    else
        record_failure deterministic "selftests skipped because the verification build did not succeed"
    fi

    run_gate deterministic "git diff whitespace check" git diff --check || true
    run_gate deterministic "selftest-flag manifest drift check" check_selftest_flag_drift || true
    if [[ -x "$APP" && -x "$TEST_APP" ]]; then
        run_gate deterministic "shipped app rejects moved selftest flags" \
            assert_shipped_rejects_moved_flags || true
    fi
    finish_tier deterministic "$failures_before" "$unverified_before"
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

tier_services() {
    local failures_before=$FAILURES
    local unverified_before=$UNVERIFIED
    if require_built_app service; then
        stage_service_home_dependencies
        local service_app="$SCRATCH/ViddyDictateVerify.app/Contents/MacOS/ViddyDictateTests"
        local service_env=(env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" \
            CFPREFERENCES_AVOID_DAEMON=1 TMPDIR="$SCRATCH_TMP/")
        if run_gate service "scratch-isolated service bundle" stage_service_bundle; then
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
            run_service_gate "email LM Studio gate" normal "${service_env[@]}" "$service_app" --email-selftest || true
            run_service_gate "per-take armed transform release (live LM Studio)" normal \
                "${service_env[@]}" "$service_app" --per-take-arm-service || true
            run_service_gate "LM Studio available-model discovery" normal \
                "${service_env[@]}" "$service_app" --lmstudio-model-catalog-live || true
            run_service_gate "Claude subscription smoke" required "${service_env[@]}" "$service_app" --cloudmode-selftest || true
            # The whole-note path over a note WITH an attachment, on a PINNED cloud route, with
            # degradation required NOT to fire (locked decision D7). Both cloud providers rejected that
            # invocation outright until 2026-08-12, and no offline tier could see it.
            run_service_gate "sticky skill on a pinned cloud route (whole note + attachment)" required \
                "${service_env[@]}" "$service_app" --sticky-cloud-service || true
            run_service_gate "Codex subscription all-shipped-pair contained verifier" required \
                /usr/bin/env -i HOME="$ORIGINAL_HOME" PATH="/usr/bin:/bin" \
                LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" TERM="dumb" \
                "$CODEX_SMOKE" --all-shipped-pairs --runner "$CODEX_RUNNER" || true
            # Real app-server handshake. The fixture catalog selftest cannot see vendor
            # protocol drift; this is the gate that does. Runs against the real HOME because
            # it needs the production compatibility boundary and its authenticated codex-home.
            #
            # `normal` here means EXACTLY "this gate is allowed to skip ITSELF", and nothing more.
            # run_service_gate records a failure on ANY non-zero exit regardless of this argument;
            # `required` only ADDS a failure when the log carries a SKIPPED marker. So a gate that
            # needs absent apparatus must abstain with an exit-0 `[skip] ... SKIPPED` line, which is
            # what this gate now does when the dedicated Codex home is not connected. It stays fully
            # blocking on any real handshake that violates expectations.
            run_service_gate "Codex live catalog handshake (real app-server)" normal \
                /usr/bin/env -i HOME="$ORIGINAL_HOME" PATH="/usr/bin:/bin" \
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
            run_service_gate "LM Studio residency gate" normal "${service_env[@]}" "$service_app" --residency-selftest || true
        fi
    fi
    finish_tier services "$failures_before" "$unverified_before"
}

tier_gui() {
    local failures_before=$FAILURES
    local unverified_before=$UNVERIFIED
    if require_built_app gui; then
        local gui_env=(env HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" TMPDIR="$SCRATCH_TMP/")
        run_gui_gate "Setup tab preflight offscreen render" "${gui_env[@]}" "$TEST_APP" --setup-render "$SCRATCH/setup-render" || true
        run_gui_gate "provider onboarding offscreen render" "${gui_env[@]}" "$TEST_APP" --provider-onboarding-render "$SCRATCH/provider-onboarding-render" || true
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
            if [[ $UNVERIFIED -eq 0 ]]; then
                printf '\n[verify][full] PASS\n'
            else
                printf '\n[verify][full] PASS WITH %d EXPLICIT UNVERIFIED SANDBOX GATE(S)\n' "$UNVERIFIED"
            fi
            exit 0
        fi
        printf '\n[verify][full] FAIL: %d required gate(s) red; %d unverified\n' "$FAILURES" "$UNVERIFIED"
        exit 1
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
