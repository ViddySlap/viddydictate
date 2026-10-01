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

## Local model apps gates (Ollama, first-run window, Feature Tour)

The tier table above predates these gates and does not list them; they run in the tiers named
here. Each deterministic gate and the GUI gate carries built-in negative controls: deliberately
broken variants (mutants) of the code under test, run inside the gate, each of which the gate must
catch or it fails. The two services gates use a real Ollama and have no mutants; they abstain with a
`[skip] ... SKIPPED` line when Ollama, or the model they need, is absent, and never unload a model
they did not load.

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
| `--ollama-client-wiring-selftest` | deterministic | Each surface's real client sends `/api/chat` with that surface's `num_ctx`, `think`, and `keep_alive` on an Ollama route, and LM Studio's unchanged request on an LM Studio route; a warm vision helper is not unloaded | Clients that ignore the resolved app; retrieval at 8,192 tokens; cleanup with `think` on; a vision pass that always unloads |
| `--feature-tour-selftest` | deterministic | Every built-in hotkey is taught by some page; chords come from the live hotkey map; a fresh install sees the tour once and an upgrade never automatically; the menu item exists; no retired wording | A page list missing a command; a renderer that always draws the latch key as Space; a page that types a chord; a first-show rule that owes every install the tour |
| `--feature-tour-render` | gui | Every page renders non-blank from stubbed facts, with no clipped or truncated text, the footer below the content, one height that fits without scrolling, live rows on pages 2 and 6, and the practice states on page 3 | An empty page of the same size must fail the ink check |
| `--ollama-live` | services | A real Ollama: a clean catalog; a model loaded with a 20-second window shows the right expiry in `/api/ps`, unloads, and leaves every model it did not load resident | None; abstains when Ollama is absent, stopped, or has no usable model |
| `--ollama-transforms-live` | services | One real cleanup and one real email on `gemma4:e4b` with a 20-second window, with no reasoning text in the output, then the model leaves `/api/ps` on its own | None; abstains when Ollama or `gemma4:e4b` is absent, the model is already resident, or the memory guard refuses the load |
