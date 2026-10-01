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

The services tier records what LM Studio (`lms ps`) and Ollama (`/api/ps`) are holding when it starts:
that is your working set, and the tier never unloads it. After each gate that can load a model, and
before the residency gate, it unloads only the models resident now that were not resident at the start
(`lms unload <identifier>` one at a time, never `--all`; Ollama `keep_alive: 0`), logs each one, and
waits for wired memory to settle, so every gate sees the memory state the tier started with. An app
whose resident set could not be read at the start is left alone.

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

## Local model apps gates (Ollama, first-run window, Feature Tour)

The tier table above predates these gates and does not list them; they run in the tiers named
here. Each deterministic gate and the GUI gate carries built-in negative controls: deliberately
broken variants (mutants) of the code under test, run inside the gate, each of which the gate must
catch or it fails. The two services gates use a real Ollama and have no mutants; they abstain with a
`[skip] ... SKIPPED: <reason> [precondition-missing]` line when Ollama, or the model they need, is
absent, which verify.sh counts as SKIP, never PASS, and never unload a model they did not load.
`--ollama-live`'s two load/unload abstains (every usable model already resident; the target does not
fit the budget) are partial: its catalog checks ran and print PASS, so that line has no marker and is
still counted as SKIP.

| Flag | Tier | What it asserts | Negative controls (each must be caught) |
| --- | --- | --- | --- |
| `--ollama-catalog-selftest` | deterministic | `/api/tags`, `/api/show`, and `/api/ps` parse; vision, tools, and thinking come from capabilities only; cloud and embedding-only models stay out of the Local list; the KV-cache upper bound | A name-based vision detector; a parser that keeps cloud rows |
| `--ollama-transport-selftest` | deterministic | OpenAI-shaped requests become native `/api/chat` bodies (`keep_alive` is the configured window, `num_ctx`, `think` only for a thinking model, bare base64 images) and replies come back in the shape the existing clients parse | A translator that forwards the body unchanged; `keep_alive` hard-coded to 600; tool arguments left as an object |
| `--local-backend-codec-selftest` | deterministic | A 1.1.0 `models-power.json` round-trips byte-identical with no `localBackend` key; an Ollama pin survives; an unknown app decodes to LM Studio without losing the bundle; the same model id in two apps is two identities | `nil` written as `null`; a strict decoder; identity by model id alone |
| `--ollama-backend-selftest` | deterministic | The Ollama backend over a scripted server: server probe, catalog and `/api/show` cache, load with `keep_alive` and `num_ctx`, no reload of a model already resident with enough context, unload as `keep_alive: 0`, native chat bodies, error mapping, `OLLAMA_HOST` parsing, requests to a loopback `OLLAMA_HOST` and none to another machine | A load that always sends `/api/generate`; chat over `/v1`; no `/api/show` cache |
| `--search-retrieval-local-only-selftest` | deterministic | Web-search retrieval hands the local app a local model that fits, even after a global switch to Claude or Codex | The pre-fix accessor; an accessor that ignores the route; a Local-only filter that falls back to the configured search model |
| `--local-backend-routing-selftest` | deterministic | Routes resolve by app and model; the same id in both apps runs on the pinned app; fallback crosses to the other app, naming both, and never to Claude or Codex; an LM-Studio-only Mac resolves as 1.1.0 did | Resolution by id alone; no cross-app step; crossing to Claude when both apps are down |
| `--staff-pick-follows-app-selftest` | deterministic | An untouched Local route runs the effective Preferred local app's staff pick (on an Ollama-only Mac, email `gemma4:e4b`, cleanup and retrieval `qwen3-coder:30b`) and moves when the Preferred app changes, with nothing written; a customized route keeps its app and model; "Set every route to its staff pick" leaves routes following the app; an LM-Studio-only Mac resolves as 1.1.0 did and its `models-power.json` is byte-identical after load and save; an untouched route that must cross apps lands on the other app's staff pick, a customized one on the largest fit; an `OLLAMA_HOST` on another machine leaves Ollama unavailable with its reason and receives no request (chat, load, pull and start included), while `localhost` is accepted | No follow (email takes the largest fitting model); customized routes following too; a backend that accepts a non-loopback `OLLAMA_HOST`; opening the store writing the app into untouched routes; an untouched route crossing apps to the largest fit instead of the other app's staff pick |
| `--local-presence-selftest` | deterministic | One merged Local presence from both apps; Ollama alone is available; a pinned Ollama.app is opened once by path; a command-line Ollama is never started; the Preferred local app rule | Presence that reads LM Studio only; a starter that opens a command-line install; a preference that ignores what is installed |
| `--local-picker-merge-selftest` | deterministic | Route pickers: one app is byte-identical to the pre-Ollama picker; two apps are grouped and labelled; selection by app and model; an LM Studio pick writes no `localBackend` key | Selection by id alone; always naming the app; writing `localBackend` for LM Studio |
| `--ollama-installer-selftest` | deterministic | Every redirect hop is checked against the allowlist before it is requested; disk-image type and length; bundle id, `codesign`, and Team ID; no overwrite; the approval wait; pull progress never goes backward | An allowlist that checks only the first host; no Team ID check; progress that reports raw bytes and goes backward |
| `--installer-local-steps-selftest` | deterministic | Local install plans; LM Studio's CLI is ready before its first model row; the app choice lists LM Studio first; the point-of-use offer's model follows the app: the Ollama choice queues Ollama then the feature's Ollama staff pick (email `gemma4:e4b`, cleanup and prompt prep `qwen3-coder:30b`), an Ollama-only Mac is offered that pull alone with no LM Studio row, an LM-Studio-only Mac's offer matches 29e3f47's literals, and a 16 GB Mac is never offered `qwen3-coder:30b` | A plan with no CLI-ready step; Ollama listed first, or as LM Studio's equal; an Ollama choice that queues no model; an Ollama-only Mac offered LM Studio; an Ollama pull with no fit check |
| `--local-apps-setup-selftest` | deterministic | The Setup tab's Local model apps rows: states, buttons, no Start or Open for a command-line Ollama, the Ollama install warning, LM Studio recommended only when neither app is installed, the Preferred choices | Start on a command-line Ollama; Ollama listed first; Ollama recommended; an app-neutral headline on an LM-Studio-only Mac |
| `--first-run-setup-selftest` | deterministic | The first-run window's LM Studio / Ollama / Skip choice, Ollama's rows and queue, Skip, the memory-fit check on Ollama rows, and the launch rule (fresh install shows the window; a working earlier install does not) | Ollama listed first; Ollama recommended; a launch rule that shows the window to upgraders; a rule that is always true; a fit check keyed on LM Studio's model id |
| `--staff-picks-copy-selftest` | deterministic | The exact Staff pick strings, none of the retired ratified wording on screen, and ratification provenance still stored | A badge that still says UNRATIFIED; a prompt label that still says Tested default |
| `--local-capacity-backends-selftest` | deterministic | The Ollama estimate is tags size plus KV times 1.15; eviction never touches a model ViddyDictate did not load, in either app; recency by ViddyDictate's own stamps; a larger resident context is reused; LM-Studio-only decisions are unchanged | An estimate sized from `/api/ps`; eviction keyed by id alone; a policy that reloads a larger resident context |
| `--resident-fit-selftest` | deterministic | Route resolution does not charge an already-resident local model twice: with the cleanup model (17.2 GB) and the email model (6.9 GB) resident and wired at 3.4 + 17.2 + 6.9 GB against a 33.87 GB budget, cleanup and retrieval stay pinned on the first and email and synthesis on the second; the same models not resident still step down; residency is per app; when nothing installed fits, the reason says it does not fit the memory budget, and an empty catalog keeps "local pin has no installed model"; the resident read is reused only while fresh (on the never-waiting main thread, a last known answer up to 300 s old while wired memory has not moved), never blocks the main thread, and a slow or failed read is the empty set; after a scripted `ModelManager` loads both models, a main-thread resolution with no live read keeps all four routes pinned (`RecentLocalLoads`), a use restarts a model's idle window, an unused model's ends, and ViddyDictate's own unload and Unload all end it at once; web search's retrieval-then-synthesis sequence resolves the same pinned models on a second question; a stale record is refused by `ModelManager` past the budget and dropped | The 1.1.0 double-counting fit (no resident set); a backend-blind resident set; the live read alone, `ModelManager`'s record not consulted (ffa0a3c); a record that never expires |
| `--ollama-client-wiring-selftest` | deterministic | Each surface's real client sends `/api/chat` with that surface's `num_ctx`, `think`, and `keep_alive` on an Ollama route, and LM Studio's unchanged request on an LM Studio route; a warm vision helper is not unloaded | Clients that ignore the resolved app; retrieval at 8,192 tokens; cleanup with `think` on; a vision pass that always unloads |
| `--feature-tour-selftest` | deterministic | Every built-in hotkey is taught by some page; chords come from the live hotkey map; a fresh install sees the tour once and an upgrade never automatically; the menu item exists; no retired wording | A page list missing a command; a renderer that always draws the latch key as Space; a page that types a chord; a first-show rule that owes every install the tour |
| `--feature-tour-render` | gui | Every page renders from stubbed facts under both the light and the dark system appearance (`-light`/`-dark` PNGs plus the stable dark name), and the two renders are the same pixels; the page paints its own opaque phosphor panel, so every capture is opaque; no clipped or truncated text, the footer below the content, one height that fits without scrolling, live rows on pages 2 and 6, and the practice states on page 3; no empty title, body line or button title; every label is 4.5:1 by colour resolution (each text colour and every fill behind it, resolved under the drawing appearance); the title is 4.5:1 by colours and by pixels; every enabled button title is 4.5:1 against its own cell in the pixels; all 11 page dots are counted in the pixels at 3:1, the current one distinct | An empty page must fail the ink check; a white title on a white page must fail the title check by colours and by pixels; a page drawn on nothing (the S7 failure) must fail the title, button, dot and opacity checks; a one-dot strip must fail the dot check |
| `--feature-tour-onscreen-proof <dir> [seconds]` | gui (opt-in, not run by `verify.sh`) | The real tour window, in the test app with stubbed facts, steps through all 11 pages; each page prints its window number for an outside `screencapture -o -l <n>` and is held for the given seconds (default 1); an in-process `CGWindowListCreateImage` capture is attempted and reported | None: it is a photography aid, and exits non-zero only if a page never reached the screen |
| `--ollama-live` | services | A real Ollama: a clean catalog; a model loaded with a 20-second window shows the right expiry in `/api/ps`, unloads, and leaves every model it did not load resident | None; abstains when Ollama is absent, stopped, or has no usable model |
| `--ollama-transforms-live` | services | One real cleanup and one real email on `gemma4:e4b` with a 20-second window, with no reasoning text in the output, then the model leaves `/api/ps` on its own | None; abstains when Ollama or `gemma4:e4b` is absent, the model is already resident, or the memory guard refuses the load |
