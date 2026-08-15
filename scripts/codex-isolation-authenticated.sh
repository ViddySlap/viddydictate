#!/usr/bin/env bash
# S2 authenticated production-equivalent isolation rail. Synthetic data only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$ROOT/build/ViddyDictate.app/Contents/Helpers/CodexIsolationAuthenticatedAudit"
RUNNER="$ROOT/build/ViddyDictate.app/Contents/Helpers/CodexContainmentRunner"

cd "$ROOT"

if [[ $# -ne 0 ]]; then
    printf 'Usage: ./scripts/codex-isolation-authenticated.sh\n' >&2
    exit 2
fi
if [[ ! -x "$AUDIT" || ! -x "$RUNNER" ]]; then
    printf '[codex-s2] FAIL: build artifacts missing; run ./build.sh first\n' >&2
    exit 1
fi

"$AUDIT" --runner "$RUNNER"
