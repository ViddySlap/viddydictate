# Model residency: the local model app owns eviction (one app TTL setting)

This file describes ViddyDictate's model-residency behavior. It replaced the earlier app-managed
idle-unload timer while keeping its intent: an idle Mac must not keep large models pinned overnight.

Most of it is about LM Studio, where the mechanism started. Ollama, the second local model app,
follows the same contract over its HTTP API; see [Ollama](#ollama-the-same-contract-over-its-http-api)
below, and [local-model-apps.md](local-model-apps.md) for how the two apps compare.

## The change

**LM Studio owns model eviction, not the app.** Every time a mode makes a model resident it loads it
with the app's configured idle `--ttl`, and LM Studio unloads the model on its own after that idle window. There
is **no app-side unload timer and no keep-alive ping** for the LLMs.

Why the reversal: ViddyDictate and external consumers share the same two local models (qwen for cleanup /
retrieval, gemma for email / synthesis). If each process ran its own unload timer they would fight over a
shared resource - one process could evict a model another just loaded. Making LM Studio the single
eviction owner lets every consumer load on demand and rely on JIT semantics; any consumer's use resets LM
Studio's idle clock, and eviction happens only on genuine global idle. (ADR 0006 rejected `--ttl` for a
single-app world on observability grounds; the multi-consumer world changes the trade-off and single-ownership
wins.)

### What moved

- `ModelResidency.ensureLoaded(_:ttlSeconds:)` — the cold-load path now shells
  `lms load <model> -y --ttl <seconds>`. (Was: `lms load <model> -y` with no TTL.)
- `ModelManager` — the idle-unload timer machinery (`start()`, the repeating `Timer`, `evictIfIdle()`,
  the `lastUse` / `evicted` latch) is **deleted**. What remains is the policy: the working set and the
  one persisted TTL (`ttl(for:)`), plus `ensureReady` as the load-on-demand entry point.
- `AppDelegate.applicationDidFinishLaunching` — the `ModelManager.shared.start()` call is removed;
  nothing needs arming at launch (the LM Studio server is started lazily on the first load).
- The `ensureReady` call sites (CleanupClient / EmailClient / SearchClient) are unchanged in shape —
  their comments were updated to describe LM Studio-owned eviction.

### One idle-unload setting

`Settings.modelIdleUnloadSeconds` is the single idle window ViddyDictate applies at load time:

- The default is 600 seconds (10 minutes).
- `ModelManager.ttl(for:)` returns that one value for every model; there is no role-specific branch.
- The user controls the value from the Setup tab's Local models section.

`ensureReady` keeps its test-only `ttlOverrideSeconds` seam so the self-test can observe eviction in
seconds instead of waiting for the configured production interval.

Bootstrap wrinkle: a model that is already resident **without** a TTL (loaded manually in the LM Studio
GUI, or by an older ViddyDictate build) is left as-is by `ensureLoaded` — it is not yanked out from under
whoever loaded it (re-loading a resident model spawns a duplicate `model:2` instance). It picks up its
TTL on its next cold load. This is benign: worst case a model stays warm a little longer than intended.

## Hard constraint: unrelated resident models must stay safe

The acceptance test uses `text-embedding-bge-m3` as a representative model that was loaded outside
ViddyDictate. It must never be evicted as a side effect of loading or evicting the app's LLMs. It is
safe for layered reasons:

1. **The test never manages bge-m3.** It records the model's initial residency, never loads,
   unloads, or assigns a TTL to it, then requires the final residency to match.
2. **LM Studio's `unloadPreviousJITModelOnLoad: true` only evicts the previous *JIT-loaded* model** — it
   keeps one JIT model at a time. An explicitly-loaded model (bge-m3, and ViddyDictate's own
   `lms load --ttl` loads) is never its victim. This is the "JIT auto-evict setting is not 'keep only
   last model'" check the interop spec requires: it is scoped to JIT models, not all models.
3. **ViddyDictate only ever loads its own working set** ({qwen, gemma}); it never loads or unloads
   bge-m3, and it never gives bge-m3 a TTL.
4. **Empirical:** qwen (17 GB) and bge-m3 coexist in `lms ps` today, both with `ttlMs: null`; loading a
   third model (gemma) evicts neither. Verified with a probe and again by the self-test (below), which
   asserts bge-m3's residency is unchanged across a full qwen load → TTL-evict → reload cycle.

### Relevant LM Studio config (as found, unchanged by this link)

- `~/.lmstudio/settings.json` → `developer.unloadPreviousJITModelOnLoad: true` (JIT-only, see above),
  `developer.jitModelTTL: { enabled: true, ttlSeconds: 3600 }` (the fallback TTL for a *pure*-JIT load
  that carries no explicit `--ttl`; ViddyDictate's explicit `lms load --ttl` overrides it per instance).
- `~/.lmstudio/.internal/http-server-config.json` → `justInTimeModelLoading: true`.

None of these global settings are modified by this feature. ViddyDictate expresses its one idle TTL at
load time via `--ttl`, scoped to each instance it loads.

The Setup tab's **Local models** section READS `developer.jitModelTTL` and reports it as a preflight row
when LM Studio holds JIT-loaded models longer than ViddyDictate's own idle timer, with the instruction to
change it in LM Studio. It is a report, not a control, and the reason is structural rather than polite:
LM Studio keeps `settings.json` in memory and rewrites it, so a write from another process is clobbered on
its next save. `LocalModelSetup` has no writer for that path, and `--local-model-setup-selftest` asserts a
read leaves the file byte-for-byte unchanged.

## Acceptance test: `--residency-selftest`

```
./build.sh
./build/ViddyDictateTests.app/Contents/MacOS/ViddyDictateTests --residency-selftest
```

`ModelResidencySelfTest` runs the locked **interleaved eviction acceptance test** from the verification bundle,
on qwen (the named model), with a short (20 s) test TTL so eviction is observable in ~35 s instead of
waiting for the configured production interval. It asserts, in order:

1. the one configured idle TTL applies to cleanup, email, search retrieval, search synthesis, and an
   otherwise unknown model ID — pure unit check;
2. clean slate: qwen unloaded;
3. **ViddyDictate cleanup-path** load: `ensureReady(qwen, ttlOverride: 20)` → resident, and `lms ps
   --json` shows the 20 s TTL actually reached LM Studio;
4. **External-consumer seam**: a real qwen `/v1/chat/completions` turn succeeds against the shared instance;
5. a second cleanup-path `ensureReady` reuses the SAME resident instance (no reload);
6. idle past the TTL with the app doing **nothing** → LM Studio evicts qwen on its own (the app issues
   zero `unload` calls in steps 3–7, so the eviction can only be LM Studio's), while **bge-m3's
   residency is unchanged**;
7. the next request JIT-reloads qwen.

The production default is 600 s; the test uses 20 s only to keep the idle wait short. The mechanism is
identical at any configured TTL value.

### Evidence captured while building this link

- Probe: `lms load "google/gemma-4-e4b" -y --ttl 15` → `lms ps --json` showed `"ttlMs":15000`; after 30 s
  idle (no unload call) gemma was gone, while `text-embedding-bge-m3` (`"ttlMs":null`) and qwen stayed
  resident throughout.
- `--residency-selftest`, `--selftest` (cleanup, also exercises the clipboard layer), and
  `--email-selftest` all cleared green after the change; bge-m3's residency was unchanged.

## Ollama: the same contract over its HTTP API

Ollama owns eviction and ViddyDictate supplies the same one idle window. ViddyDictate talks to
Ollama only over its native HTTP API (`http://127.0.0.1:11434` by default); it never shells out to
the `ollama` command for inference or residency.

### keep_alive on every request is the one idle setting

Every load and every chat carries `keep_alive` set to `Settings.modelIdleUnloadSeconds`, in whole
seconds: the same value, and the same Setup control, LM Studio's `--ttl` gets. A load is
`POST /api/generate` with an empty prompt; a chat is `POST /api/chat`. Ollama unloads the model on
its own once it has sat idle that long. There is no app-side timer.

- A model already resident with enough context gets no load request, because any request would
  reset the expiry it was loaded with. The chats ViddyDictate then sends do carry its window, so a
  model another app loaded takes ViddyDictate's window from ViddyDictate's first chat on it, as it
  would from any Ollama request.
- The Note to Handoff vision helper keeps its own 300-second window on Ollama, as on LM Studio. It is
  unloaded straight after its one call only when that pass loaded it cold, so a model another mode
  already had warm (on Ollama, `gemma4:e4b` is both the email staff pick and the smallest vision
  model) stays loaded.
- `ensureReady`'s `ttlOverrideSeconds` test seam applies to Ollama too.

### Unload is keep_alive 0

`unload` sends `POST /api/generate {"model": ..., "keep_alive": 0}` when `/api/ps` lists the model
or cannot be read. A model `/api/ps` shows Ollama is not holding gets no request.

### Why native `/api/chat`, not Ollama's `/v1`

Ollama's OpenAI-compatible `/v1` endpoint cannot carry `keep_alive` or `num_ctx`.

- **keep_alive:** a `/v1` request inherits Ollama's default keep-alive, and every such call resets
  the model's expiry to that default. The idle setting would silently stop applying.
- **num_ctx:** a `/v1` request loads the model at Ollama's own default context, which on large Macs
  is a 256k-token KV cache. ViddyDictate sets `num_ctx` on every request: 8,192 tokens for cleanup,
  prompt-prep, custom modes, email, search synthesis, and the vision helper; 16,384 for search
  retrieval. A model already resident with at least that context is reused as it is; a smaller one
  is reloaded at ViddyDictate's size.

The clients still build the OpenAI-shaped request they build for LM Studio and parse the
OpenAI-shaped reply. `OllamaChatTranslator` converts the request to the native body and the reply
back, so only the transport differs between the two apps.

### Capacity: `/api/ps` under-reports, so the estimate uses tags size plus KV

The memory guard covers Ollama as it covers LM Studio. Two measurements on one 64 GB Apple Silicon
Mac shaped it:

- **Ollama loads are wired memory.** `gemma4:e4b`, 6.58 GB on disk, added about 7.3 GB of wired
  memory when loaded at an 8k context and about 8.0 GB at 32k, and released it within a second of
  `keep_alive: 0`. So the existing whole-machine wired-memory budget sees Ollama's models, and the
  2-second settle wait after an eviction is kept for both apps.
- **`/api/ps` size under-reports.** For that same load `/api/ps` reported 0.34 GB, 10 to 20 times
  less than the memory the load actually took. ViddyDictate never uses that number.

The incoming estimate for an Ollama load is `(size from /api/tags + KV cache for num_ctx) x 1.15`,
the same 1.15 factor LM Studio's estimate uses. The KV term is a conservative upper bound computed
from `/api/show` `model_info`; when that lacks the geometry, it falls back to 0.25 x the model's
size per 8,192 tokens of context, which over-counts on purpose. The Setup tab's **Loaded now** list
and the eviction ranking also take each resident model's size from `/api/tags`.

Eviction is the existing policy, keyed by app and model together. ViddyDictate only unloads models
its own process loaded, so a model with the same name in the other app, or one the user loaded, is
never touched. Because `/api/ps` has no last-use time, Ollama recency is ViddyDictate's own stamp,
and a model with a ViddyDictate request in flight is never evicted.

### Unload all is per app

LM Studio's **Unload all** is unchanged: `lms unload --all`. When Ollama is installed the Setup tab
adds Ollama's own **Unload all**, which sends `keep_alive: 0` for every model in `/api/ps`. Each
button acts on every model in its app, including models other apps loaded, as LM Studio's always
has. With both apps listed, the buttons read "Unload all in LM Studio" and "Unload all in Ollama".

### ViddyDictate never writes Ollama's settings or environment

The idle window and the context size travel on each request and affect only that request's model.
ViddyDictate does not change Ollama's settings, its defaults, or any environment variable, so
models other apps load follow Ollama's own defaults. The one Ollama environment variable it reads
is `OLLAMA_HOST`, from its own process environment, to find the server, and only a loopback value
(`localhost`, `127.0.0.0/8`, `::1`) is used. A server on another machine is never sent anything; see
[local-model-apps.md](local-model-apps.md).

### Verification

- `--local-capacity-backends-selftest` (deterministic) covers the tags-plus-KV estimate, eviction
  keyed by app and model, recency, and context reuse, each with a negative control.
- `--ollama-live` (services) loads a real model with a 20-second window, checks the expiry
  `/api/ps` reports, unloads it, and requires every model it did not load to stay resident.
- `--ollama-transforms-live` (services) runs a real cleanup and email on `gemma4:e4b` with a
  20-second window, then requires the model to leave `/api/ps` on its own.

Both services gates abstain when Ollama, or the model they need, is absent.

## Current status

This mechanism shipped in ViddyDictate on 2026-07-06. LM Studio still owns eviction; ViddyDictate now
feeds it one user-controlled idle window for every local model. Ollama gets the same window through
`keep_alive`, as described above.
