#!/usr/bin/env python3
"""Isolation test for the deterministic tier's test-domain defaults reset.

Python 3 standard library only; no build, no AppKit. Every row is named
`defaults-reset: new:` or `defaults-reset: guard:`.

The reset script is the thing under test. This gate seeds two throwaway defaults domains, runs the
reset through a `bash` subprocess exactly as `scripts/verify.sh` does, and checks that only the
selected domain is cleared. A managed sandbox can refuse `defaults write` for every domain, so when
the real command cannot seed a domain the test installs a small `defaults` shim backed by a temp
store. The reset script is still the real script; only the storage backend is controlled.
"""

import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RESET_SH = os.path.join(HERE, "verify-defaults-reset.sh")
VERIFY_SH = os.path.join(HERE, "verify.sh")

INSTALLED_ID = "com.viddydictate.app"

# Exactly two throwaway domains for the whole file; both are always cleaned up.
DOMAIN_A = "com.viddydictate.app.tests.selftest.%s" % uuid.uuid4()
DOMAIN_B = "com.viddydictate.app.tests.selftest.%s" % uuid.uuid4()

WORK = tempfile.mkdtemp(prefix="vd-defaults-reset-")
SHIM_DIR = os.path.join(WORK, "bin")
SHIM_STORE = os.path.join(WORK, "store.tsv")
USE_REAL = False

FAILURES = []

SHIM_SOURCE = '''#!/usr/bin/env python3
import os
import sys

STORE = os.environ["VD_DEFAULTS_STORE"]


def load():
    data = {}
    if os.path.exists(STORE):
        with open(STORE, encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\\n")
                if not line:
                    continue
                domain, key, value = line.split("\\t")
                data.setdefault(domain, {})[key] = value
    return data


def save(data):
    with open(STORE, "w", encoding="utf-8") as handle:
        for domain, values in data.items():
            for key, value in values.items():
                handle.write("%s\\t%s\\t%s\\n" % (domain, key, value))


def main():
    args = sys.argv[1:]
    if not args:
        return 2
    command = args[0]
    if command == "write" and len(args) >= 4:
        domain, key = args[1], args[2]
        value = args[4] if len(args) >= 5 and args[3] == "-bool" else args[3]
        data = load()
        data.setdefault(domain, {})[key] = "1" if value.lower() in ("true", "1", "yes") else "0"
        save(data)
        return 0
    if command == "read" and len(args) >= 2:
        data = load()
        domain = args[1]
        if len(args) >= 3:
            key = args[2]
            if domain in data and key in data[domain]:
                print(data[domain][key])
                return 0
            return 1
        if data.get(domain):
            for key in sorted(data[domain]):
                print("%s = %s" % (key, data[domain][key]))
            return 0
        return 1
    if command == "delete" and len(args) >= 2:
        data = load()
        domain = args[1]
        if domain in data:
            del data[domain]
            save(data)
            return 0
        return 1
    return 2


sys.exit(main())
'''


def run(*args, env=None):
    return subprocess.run(args, capture_output=True, text=True, env=env)


def shim_env():
    env = os.environ.copy()
    env["PATH"] = SHIM_DIR + os.pathsep + env.get("PATH", "")
    env["VD_DEFAULTS_STORE"] = SHIM_STORE
    return env


def defaults_env():
    return os.environ.copy() if USE_REAL else shim_env()


def defaults(*args):
    return run("defaults", *args, env=defaults_env())


def install_shim():
    os.makedirs(SHIM_DIR, exist_ok=True)
    shim = os.path.join(SHIM_DIR, "defaults")
    with open(shim, "w", encoding="utf-8") as handle:
        handle.write(SHIM_SOURCE)
    os.chmod(shim, 0o755)


def detect_mode():
    global USE_REAL
    probe = run("defaults", "write", DOMAIN_A, "providerOnboardingSatisfied", "-bool", "true")
    if probe.returncode == 0:
        run("defaults", "delete", DOMAIN_A)
        USE_REAL = True
        return
    USE_REAL = False
    install_shim()


def seed(domain, key="providerOnboardingSatisfied", value="true"):
    return defaults("write", domain, key, "-bool", value)


def read_key(domain, key="providerOnboardingSatisfied"):
    proc = defaults("read", domain, key)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def domain_exists(domain):
    return defaults("read", domain).returncode == 0


def call_reset(root, override=None):
    env = defaults_env()
    env["ROOT"] = root
    if override is None:
        env.pop("VD_RESET_DOMAIN_OVERRIDE", None)
    else:
        env["VD_RESET_DOMAIN_OVERRIDE"] = override
    return run(
        "bash",
        "-c",
        'source "$ROOT/scripts/verify-defaults-reset.sh"; vd_reset_test_defaults',
        env=env,
    )


def call_test_domain(root):
    env = defaults_env()
    env["ROOT"] = root
    env.pop("VD_RESET_DOMAIN_OVERRIDE", None)
    return run(
        "bash",
        "-c",
        'source "$ROOT/scripts/verify-defaults-reset.sh"; vd_test_domain',
        env=env,
    )


def expect(condition, kind, name, assertion):
    label = "defaults-reset: %s: %s" % (kind, name)
    if condition:
        print("PASS %s" % label)
        return
    print("FAIL %s | %s" % (label, assertion))
    if kind == "new":
        print("RED before fix: %s | %s" % (label, assertion))
    FAILURES.append(label)


def write_plists(directory, installed_id, tests_id):
    with open(os.path.join(directory, "Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": installed_id}, handle)
    with open(os.path.join(directory, "Info-Tests.plist"), "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": tests_id}, handle)


def test_throwaway_reset():
    kind = "new"
    name = "throwaway domain reset by override empties it and prints existed: yes"
    if not os.path.isfile(RESET_SH):
        expect(False, kind, name, "scripts/verify-defaults-reset.sh is absent")
        return
    seed(DOMAIN_A)
    proc = call_reset(ROOT, DOMAIN_A)
    expected = "[verify][deterministic] test-domain defaults reset: %s (existed: yes)" % DOMAIN_A
    present = domain_exists(DOMAIN_A)
    ok = proc.returncode == 0 and not present and proc.stdout.strip() == expected
    expect(
        ok,
        kind,
        name,
        "rc=%r stdout=%r domain_present=%r" % (proc.returncode, proc.stdout.strip(), present),
    )


def test_second_domain_untouched():
    kind = "new"
    name = "reset leaves a second throwaway domain untouched"
    if not os.path.isfile(RESET_SH):
        expect(False, kind, name, "scripts/verify-defaults-reset.sh is absent")
        return
    seed(DOMAIN_A)
    seed(DOMAIN_B)
    proc = call_reset(ROOT, DOMAIN_A)
    a_present = domain_exists(DOMAIN_A)
    b_key = read_key(DOMAIN_B)
    ok = proc.returncode == 0 and not a_present and b_key == "1"
    expect(
        ok,
        kind,
        name,
        "rc=%r domain_a_present=%r domain_b_key=%r" % (proc.returncode, a_present, b_key),
    )


def test_refusals_delete_nothing():
    kind = "new"
    name = "refuses a non-throwaway override and an installed-id test domain"
    if not os.path.isfile(RESET_SH):
        expect(False, kind, name, "scripts/verify-defaults-reset.sh is absent")
        return
    checks = []

    # A non-throwaway override must be refused, and a seeded throwaway domain must survive.
    seed(DOMAIN_B)
    invalid = call_reset(ROOT, "com.viddydictate.app.tests")
    checks.append(
        (
            "invalid-override",
            invalid.returncode != 0
            and invalid.stdout.strip() == ""
            and read_key(DOMAIN_B) == "1",
        )
    )

    # The test domain naming the installed id must be refused. The spec-literal id has no `.tests`
    # suffix; the synthetic one keeps the suffix so the installed-id equality guard is exercised.
    # Each fixture carries a real copy of the reset script so a missing file (rc 127) cannot stand
    # in for an actual refusal; the exact status 2 and a clean stderr pin the refusal path.
    cases = [
        (INSTALLED_ID, INSTALLED_ID, "installed-id-substituted"),
        (
            "com.viddydictate.app.selftest.tests",
            "com.viddydictate.app.selftest.tests",
            "installed-id-with-tests-suffix",
        ),
    ]
    for installed_id, tests_id, label in cases:
        tmp = tempfile.mkdtemp(prefix="vd-defaults-reset-plist-")
        try:
            os.makedirs(os.path.join(tmp, "scripts"), exist_ok=True)
            shutil.copy(RESET_SH, os.path.join(tmp, "scripts", "verify-defaults-reset.sh"))
            write_plists(tmp, installed_id, tests_id)
            proc = call_reset(tmp, None)
            refused = (
                proc.returncode == 2
                and proc.stdout.strip() == ""
                and "No such file" not in proc.stderr
                and "command not found" not in proc.stderr
            )
            checks.append((label, refused))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    ok = all(result for _, result in checks)
    expect(ok, kind, name, "; ".join("%s=%s" % (label, result) for label, result in checks))


def test_verify_sh_static():
    kind = "new"
    name = "verify.sh sources the file and resets before the first banner"
    if not os.path.isfile(VERIFY_SH):
        expect(False, kind, name, "scripts/verify.sh is absent")
        return
    with open(VERIFY_SH, encoding="utf-8") as handle:
        text = handle.read()
    sourced = 'source "$ROOT/scripts/verify-defaults-reset.sh"' in text
    wired = "test-verify-defaults-reset.py" in text
    body = ""
    match = re.search(r"^tier_deterministic\(\)\s*\{", text, re.M)
    if match:
        end = text.find("\n}\n", match.end())
        body = text[match.end() : end if end != -1 else len(text)]
    call_at = body.find("vd_reset_test_defaults")
    first_banner = len(body)
    for token in ("banner", "run_gate"):
        idx = body.find(token)
        if idx != -1:
            first_banner = min(first_banner, idx)
    ok = sourced and wired and call_at != -1 and call_at < first_banner
    expect(
        ok,
        kind,
        name,
        "sourced=%r wired=%r call_at=%r first_banner_or_gate=%r"
        % (sourced, wired, call_at, first_banner),
    )


def test_trailing_newline_refused():
    kind = "new"
    name = "an Info-Tests.plist id with a trailing newline is refused"
    if not os.path.isfile(RESET_SH):
        expect(False, kind, name, "scripts/verify-defaults-reset.sh is absent")
        return
    tmp = tempfile.mkdtemp(prefix="vd-defaults-reset-newline-")
    try:
        os.makedirs(os.path.join(tmp, "scripts"), exist_ok=True)
        shutil.copy(RESET_SH, os.path.join(tmp, "scripts", "verify-defaults-reset.sh"))
        with open(os.path.join(tmp, "Info.plist"), "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": INSTALLED_ID}, handle)
        # PlistBuddy Add with a literal newline stores it inside the string value; Print then emits
        # the value's newline plus its own record newline, which is the whitespace that must be
        # refused (the base script's command substitution stripped it before the guard ran).
        add = run(
            "/usr/libexec/PlistBuddy",
            "-c",
            "Add :CFBundleIdentifier string com.viddydictate.app.selftest.tests\n",
            os.path.join(tmp, "Info-Tests.plist"),
        )
        if add.returncode != 0:
            expect(False, kind, name, "PlistBuddy Add failed: %r" % add.stderr.strip())
            return
        domain = call_test_domain(tmp)
        ok = domain.returncode != 0 and domain.stdout.strip() == ""
        expect(
            ok,
            kind,
            name,
            "rc=%r stdout=%r" % (domain.returncode, domain.stdout.strip()),
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_reset_script_guard():
    kind = "new"
    name = 'reset script forbids write, sudo, security, osascript, rm; one defaults delete on "$d"'
    if not os.path.isfile(RESET_SH):
        expect(False, kind, name, "scripts/verify-defaults-reset.sh is absent")
        return
    with open(RESET_SH, encoding="utf-8") as handle:
        text = handle.read()
    problems = []
    for needle in ("defaults write", "sudo", "security", "osascript"):
        if needle in text:
            problems.append("contains %r" % needle)
    if re.search(r"\brm\b", text):
        problems.append("contains a standalone rm")
    deletes = [line for line in text.splitlines() if "defaults delete" in line]
    if len(deletes) != 1:
        problems.append("defaults delete lines=%d" % len(deletes))
    elif '"$d"' not in deletes[0]:
        problems.append('defaults delete does not take "$d"')
    expect(not problems, kind, name, "; ".join(problems))


def test_verify_sh_guard():
    kind = "guard"
    name = "verify.sh adds no defaults delete beyond cleanup_scratch"
    if not os.path.isfile(VERIFY_SH):
        expect(False, kind, name, "scripts/verify.sh is absent")
        return
    with open(VERIFY_SH, encoding="utf-8") as handle:
        text = handle.read()
    deletes = [line.strip() for line in text.splitlines() if "defaults delete" in line]
    ok = len(deletes) == 1 and "VERIFY_BUNDLE_ID" in deletes[0]
    expect(ok, kind, name, "defaults delete lines=%r" % deletes)


def cleanup():
    for domain in (DOMAIN_A, DOMAIN_B):
        try:
            run("defaults", "delete", domain, env=defaults_env())
        except Exception:
            pass
    shutil.rmtree(WORK, ignore_errors=True)


def main():
    try:
        detect_mode()
        test_throwaway_reset()
        test_second_domain_untouched()
        test_refusals_delete_nothing()
        test_trailing_newline_refused()
        test_verify_sh_static()
        test_reset_script_guard()
        test_verify_sh_guard()
    finally:
        cleanup()
    if FAILURES:
        print("FAILED defaults-reset rows: %d" % len(FAILURES))
        return 1
    print("PASS defaults-reset: all rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
