#!/usr/bin/env python3
"""Static source gate for the two Codex failure-diagnostic gates (chain `gate-diagnostics-20261010`).

This is a GATE, not an implementation. It is stdlib-only and runs no build: it reads the two Swift
sources and `scripts/verify.sh`, and it checks that the diagnostics designed to make a future red
run self-explanatory are actually present, while the pinned thresholds and the pinned runner
helpers are unchanged from base commit bbb26e6.

It is RED on the base commit, where the formatter and the `[codex-login-fixture][diag]` line do not
exist yet, and GREEN once the diagnostics land. It changes no product behaviour.
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources" / "SelfTest" / "CodexModelCatalogSelfTest.swift"
RUNNER = ROOT / "Tools" / "CodexContainmentRunner.swift"
VERIFY = ROOT / "scripts" / "verify.sh"
TAG = "[gate-diag]"

# SHA-256 of the exact function text at base commit bbb26e6. These helpers are outside the
# diagnostics work and must stay byte-identical; the extraction below is the same brace-counting
# used to produce these digests.
PINNED_FUNCTIONS = {
    "authenticatedAuditOutput":
        "d30c68d6d40c8525ec1a3b51600809a2a06efd49b77c4732e61d62727776084c",
    "captureBounded":
        "22cf5e42c574bf14f7414e7e44c9f96eec933cf48335901888437421a8089e51",
    "waitForProcessGroup":
        "106b6c3c90c7bfbbee5a51f9bf19a14650b01d56b3b35f81a5131166697b6d91",
}

PREDICATE_FIELDS = [
    "leader_pid_matches=",
    "first_drains_incomplete=",
    "first_leader_reaped=",
    "first_no_residual=",
    "second_leader_reaped=",
    "second_no_residual=",
    "second_drains_complete=",
    "ops_stable_after_tree_gone=",
    "no_replacement_touched=",
    "term_count=",
    "kill_count=",
    "processes_gone=",
]
MEASURED_FIELDS = [
    "launch_to_fixture_s=",
    "first_reap_s=",
    "second_reap_s=",
    "first_deadline_remaining_s=",
    "second_deadline_remaining_s=",
    "first_deadline_s=",
    "overall_deadline_s=",
    "drain_delay_s=",
]
LOGIN_FIELDS = [
    "case=",
    "status=",
    "timed_out=",
    "overflow=",
    "stdout_bytes=",
    "stderr_bytes=",
    "elapsed_s=",
    "timeout_s=",
    "limit=",
    "uptime_s=",
]

FAILURES: list = []


def check(message: str, condition, detail: str = "") -> bool:
    if not isinstance(condition, bool):
        raise TypeError(
            f"check({message!r}, ...) needs a bool condition, "
            f"got {type(condition).__name__}")
    print(f"{TAG} {'ok  ' if condition else 'FAIL'} {message}"
          + (f" ({detail})" if detail else ""))
    if not condition:
        FAILURES.append(message)
    return condition


def extract_function(source: str, name: str):
    """Return the exact `private func <name>` text, braces balanced, or None."""
    lines = source.splitlines(keepends=True)
    start = None
    pattern = re.compile(rf"private func {re.escape(name)}\b")
    for index, line in enumerate(lines):
        if pattern.match(line):
            start = index
            break
    if start is None:
        return None
    depth = 0
    started = False
    out = []
    for line in lines[start:]:
        out.append(line)
        for char in line:
            if char == "{":
                depth += 1
                started = True
            elif char == "}":
                depth -= 1
        if started and depth == 0:
            break
    return "".join(out)


def gate_catalog(catalog: str) -> None:
    print(f"{TAG} --- gate-1 retryable-reap formatter ---")
    check("gate-1 pure formatter exists", "retryableReapDiagnosticLine" in catalog)
    check(
        "gate-1 failure decision helper exists",
        "static func retryableReapDiagnostic(" in catalog)
    check(
        "gate-1 emits one line in the !retryPassed branch",
        catalog.count("if let line = retryableReapDiagnostic(") == 2)
    check(
        "gate-1 catch branch passes the thrown error description",
        "errorDescription: String(describing: error)" in catalog)
    for field in PREDICATE_FIELDS + MEASURED_FIELDS:
        check(f"gate-1 diag names {field}", field in catalog)
    check(
        "gate-1 first-deadline grace stays 0.5",
        "retryableReapFirstDeadlineGraceSeconds: TimeInterval = 0.5" in catalog)
    check(
        "gate-1 overall deadline stays 3",
        "retryableReapOverallDeadlineSeconds: TimeInterval = 3" in catalog)
    check(
        "gate-1 first-deadline offset literal stays `+ 0.5`",
        "+ 0.5" in catalog)
    check(
        "gate-1 overall-deadline offset literal stays `+ 3`",
        "+ 3" in catalog)
    check(
        "gate-1 deadline math uses the pinned first-deadline constant",
        "+ retryableReapFirstDeadlineGraceSeconds" in catalog)
    check(
        "gate-1 deadline math uses the pinned overall-deadline constant",
        "+ retryableReapOverallDeadlineSeconds" in catalog)
    check(
        "gate-1 fixture drain delay stays 1",
        "drainCompletionDelayForTesting: 1" in catalog)
    check("gate-1 has a `gate-diag: new:` row", "gate-diag: new:" in catalog)
    check("gate-1 has a `gate-diag: guard:` row", "gate-diag: guard:" in catalog)


def gate_runner(runner: str) -> None:
    print(f"{TAG} --- gate-2 login-fixture formatter ---")
    check(
        "gate-2 diag line exists",
        "[codex-login-fixture][diag]" in runner)
    for field in LOGIN_FIELDS:
        check(f"gate-2 diag names {field}", field in runner)
    check(
        "gate-2 wrapper measures elapsed time",
        "ProcessInfo.processInfo.systemUptime - started" in runner)
    check(
        "gate-2 wraps all four fixture captures",
        runner.count("captureFakeCodexDiagnosed(") >= 5)
    check(
        "gate-2 capture timeout stays 2", "timeout: 2" in runner)
    check(
        "gate-2 capture limit stays 4096", "limit: 4_096" in runner)
    check("gate-2 has a `gate-diag: new:` row", "gate-diag: new:" in runner)
    check("gate-2 has a `gate-diag: guard:` row", "gate-diag: guard:" in runner)

    print(f"{TAG} --- pinned runner helpers and policy goldens ---")
    for name, digest in PINNED_FUNCTIONS.items():
        body = extract_function(runner, name)
        actual = hashlib.sha256(body.encode()).hexdigest() if body else "missing"
        check(
            f"{name} is byte-identical to base bbb26e6",
            actual == digest,
            f"want {digest[:12]} got {actual[:12]}")
    check(
        "canonical network policy golden unchanged",
        "fa247259d221a52f97ddfbbefb78e5156f17119a7fe88b3ae2f060dcc0cd2684"
        in runner)
    check(
        "canonical quarantine policy golden unchanged",
        "68d92d7bbe6de955443abade819368132a8a86f3197159a629f0879ec03a0a60"
        in runner)


def gate_verify(verify: str) -> None:
    print(f"{TAG} --- verify.sh wiring ---")
    check(
        "verify.sh runs this gate",
        "test-gate-diagnostics.py" in verify)


def main() -> int:
    catalog = CATALOG.read_text()
    runner = RUNNER.read_text()
    verify = VERIFY.read_text()
    gate_catalog(catalog)
    gate_runner(runner)
    gate_verify(verify)
    if FAILURES:
        print(f"{TAG}[FAIL] {len(FAILURES)} check(s) failed: "
              + "; ".join(FAILURES))
        return 1
    print(f"{TAG}[PASS] Codex gate diagnostics, pinned thresholds, and pinned "
          "runner helpers are intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
