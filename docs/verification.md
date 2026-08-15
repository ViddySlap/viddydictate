# Verification rail

Run the rail from the repository root:

```sh
./scripts/verify.sh deterministic
./scripts/verify.sh services
./scripts/verify.sh gui
./scripts/verify.sh full
```

| Tier | What it runs | External dependencies |
| --- | --- | --- |
| `deterministic` | Web/native builds; custom-mode, typed-routing, Models & Power storage, provider-neutral transport, synthetic Codex provider, a synthetic/offline Codex isolation selftest (UNVERIFIED-graceful under nested-sandbox denial), Power Mode, history, notes, and notes-HTTP checks; `git diff --check` | Preinstalled `node_modules`; no model, web, mic, live-app, real-note, or real-preference access |
| `services` | Cleanup/email LM Studio tests, the legacy-named `--cloudmode-selftest` Claude subscription smoke, the all-distinct-shipped-pair contained Codex verifier, web-search pipeline, and residency test | LM Studio, Claude subscription CLI/auth, dedicated Codex subscription auth + external containment, installed search helper/network, and `lms` |
| `gui` | Models & Power UI probe, HUD probe/render, and `--mic-probe` | Logged-in GUI/AppKit session and enumerated input devices; no capture |
| `full` | All three tiers, then `git diff --check` and a clean-worktree gate | Everything above |

`build.sh` creates the shipped `build/ViddyDictate.app` plus a sibling verification bundle,
`build/ViddyDictateTests.app`. All selftest/probe manifest flags, including
`--list-selftest-flags`, are answered by the test bundle. The shipped app remains the build/launch
target and owns the Codex runner/smoke helpers used by the rail; the sibling test bundle is never
installed by `install-app-agent.sh`.

`--list-selftest-flags` prints the ordered pre-AppKit test/probe manifest with tier tags; the
deterministic rail first requires at least one deterministic entry, then fails its drift check if any
deterministic flag lacks a `verify.sh` gate.

The rail creates a disposable home and temp root under `/private/tmp`. Deterministic and GUI commands use it for `HOME`, CoreFoundation preferences, logs, and outputs. Both bundles produced by the deterministic build are therefore ad-hoc signed verification artifacts; a live deployment must still use the normal `./build.sh` signing environment. Services retain the caller's real `HOME` only so existing Claude subscription and LM Studio tooling remain discoverable, while CoreFoundation preferences and app data stay isolated.

`build-web.sh` normally installs dependencies when `node_modules` is absent. The deterministic tier refuses that fallback so it cannot make an accidental package-network call. Install dependencies deliberately before running the rail.

Failures from required service commands are red and named by dependency. The Claude and contained Codex smokes are red if their required CLI/auth/containment path is missing or unavailable. A failed notes HTTP bind is marked `UNVERIFIED` only when the selftest fails at listener startup and an independent loopback bind is also denied by the sandbox; any host-capable route or assertion failure remains red. GUI/AppKit environment-denial messages are likewise reported as `UNVERIFIED`, never silently called green. The conductor/final host must clear unverified gates.

The Codex service gate invokes the shipped `CodexProviderSmoke` helper with
`--all-shipped-pairs`. It derives the exact distinct pair inventory from canonical source defaults,
uses fixed synthetic prompt/input/output bytes, runs pairs sequentially through the shipping containment
runner, and never reads user settings or content. The installed-bundle deployment gate reruns the same
command against the installed helper and runner.

The rail intentionally excludes:

- `--mic-capture-test` and `--recorder-test`: real microphone capture.
- `--emit-theme-css`: internal build step already exercised by `build.sh`.
