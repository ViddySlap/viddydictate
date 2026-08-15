#!/usr/bin/env bash
# S1-only unauthenticated Codex isolation preflight. Never performs login or a model call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/ViddyDictateTests.app/Contents/MacOS/ViddyDictateTests"
RUNNER="$ROOT/build/ViddyDictate.app/Contents/Helpers/CodexContainmentRunner"

cd "$ROOT"

usage() {
    printf 'Usage: ./scripts/codex-isolation-preflight.sh scratch|stage-production\n' >&2
}

if [[ $# -ne 1 ]]; then usage; exit 2; fi
if [[ ! -x "$APP" || ! -x "$RUNNER" ]]; then
    printf '[codex-s1] FAIL: build artifact missing; run ./build.sh first\n' >&2
    exit 1
fi

case "$1" in
    scratch)
        "$APP" --codex-isolation-selftest --runner "$RUNNER"
        "$APP" --codex-isolation-preflight --runner "$RUNNER"
        ;;
    stage-production)
        # Shipping gate: always rerun every local/scratch check immediately before app-owned staging.
        "$APP" --codex-isolation-selftest --runner "$RUNNER"
        "$APP" --codex-isolation-preflight --runner "$RUNNER"
        "$APP" --codex-isolation-preflight --stage-production --runner "$RUNNER"
        ;;
    *) usage; exit 2 ;;
esac
