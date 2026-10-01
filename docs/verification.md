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

One deterministic gate is a host gate. `--codex-bundle-snapshot-host-selftest` installs an ad hoc signed
fixture bundle through the real Codex bundle-snapshot path into a scratch store under the rail's TMPDIR,
using the host `codesign`. On the Mac that is APFS, the filesystem production installs into. Without
`codesign` (Linux, the Boxx) the gate abstains with `[precondition-missing]` and is counted as SKIP, never
PASS. On macOS an abstain from this gate is a failure, so the Mac's deterministic tier cannot skip it.

`--list-selftest-flags` prints the ordered pre-AppKit test/probe manifest with tier tags; the
deterministic rail first requires at least one deterministic entry, then fails its drift check if any
deterministic flag lacks a `verify.sh` gate.

The rail creates a disposable home and temp root under `/private/tmp`. Deterministic and GUI commands use it for `HOME`, CoreFoundation preferences, logs, and outputs. Both bundles produced by the deterministic build are therefore ad-hoc signed verification artifacts; a live deployment must still use the normal `./build.sh` signing environment. Services retain the caller's real `HOME` only so existing Claude subscription and LM Studio tooling remain discoverable, while CoreFoundation preferences and app data stay isolated. The two Codex gates that would write the live Codex store use the scratch home unless `VD_ALLOW_LIVE_CODEX_STORE=1` (see below).

`build-web.sh` normally installs dependencies when `node_modules` is absent. The deterministic tier refuses that fallback so it cannot make an accidental package-network call. Install dependencies deliberately before running the rail.

Failures from required service commands are red and named by dependency. The Claude and contained Codex smokes are red if their required CLI/auth/containment path is missing or unavailable. A failed notes HTTP bind is marked `UNVERIFIED` only when the selftest fails at listener startup and an independent loopback bind is also denied by the sandbox; any host-capable route or assertion failure remains red. GUI/AppKit environment-denial messages are likewise reported as `UNVERIFIED`, never silently called green. The conductor/final host must clear unverified gates.

An abstaining service gate is never a PASS. A `normal` gate that cannot run because its apparatus or a precondition is missing exits 0 with a `[skip] ... SKIPPED: <reason>` line (gates print the shared `[precondition-missing]` marker). verify.sh reports it as `[verify][service][SKIP] <label>: <reason>`, counts it, and the tier and full summaries say how many gates were skipped rather than passed. A `required` gate that abstains is red. After the services tier, a meta-gate fails any service gate whose log shows both a PASS line and `[precondition-missing]`. The classifier lives in `scripts/service-gate-classify.sh` and has its own deterministic selftest.

The Codex service gate invokes the shipped `CodexProviderSmoke` helper with
`--all-shipped-pairs`. It derives the exact distinct pair inventory from canonical source defaults,
uses fixed synthetic prompt/input/output bytes, runs pairs sequentially through the shipping containment
runner, and never reads user settings or content. The installed-bundle deployment gate reruns the same
command against the installed helper and runner.

### The live Codex store is opt-in

The Codex all-shipped-pair verifier and the live catalog handshake (`--codex-catalog-live`) run the
production boundary. Pointed at a HOME, that boundary snapshots the installed Codex CLI into
`~/Library/Application Support/ViddyDictate/codex-executables/`, installs a runner snapshot into
`codex-runners/`, rewrites the compatibility receipt in `codex-home/`, and prunes `codex-executables/`
to the current snapshot plus one previous. verify.sh therefore never runs them against the real HOME
unless asked:

- Default (`VD_ALLOW_LIVE_CODEX_STORE` unset, or any value other than `1`): both gates run with
  `HOME` and `CFFIXED_USER_HOME` set to the rail's scratch home. Resolution, the bundle snapshot,
  `codesign --verify --strict`, the quarantine inside the containment runner, and the receipt are all
  exercised for real, and any refusal on that path is red. The scratch home is not logged in, so the
  smoke (run with `--abstain-if-not-logged-in`, as a `normal` gate) and the catalog gate each abstain
  with `[precondition-missing]` and are reported as SKIP, never PASS. The authenticated model calls,
  the staged-image pair, and the catalog handshake are not exercised. The scratch copy (about 230 MB
  for the real CLI) is deleted with the scratch root when the rail exits.
- `VD_ALLOW_LIVE_CODEX_STORE=1 ./scripts/verify.sh services` (or `full`): the two gates run against
  the real HOME and its logged-in dedicated Codex home, exactly as before, and the smoke is `required`
  again. verify.sh prints a `[verify][service][LIVE-CODEX-STORE]` line saying it will modify and prune
  the live Codex store before the services tier and again before the Codex gates.

The device-auth gate is unaffected: it runs the CLI in place with its own throwaway Codex home. Any
other value of the variable is ignored, and verify.sh says so.

The first launch of a build that can snapshot the bundle CLI does the same to an existing install, once:
it installs the bundle snapshot (about 230 MB) and prunes the old flat snapshots down to one. On the
maintainer's Mac that deletes 11 of 12 flat snapshots, about 2.5 GB. This is the retention design, and
the count is `CodexSnapshotRetention.retainedSnapshotCount`; whether a release may do it without asking
the user is pending ruling (a).

The rail intentionally excludes:

- `--mic-capture-test` and `--recorder-test`: real microphone capture.
- `--emit-theme-css`: internal build step already exercised by `build.sh`.
