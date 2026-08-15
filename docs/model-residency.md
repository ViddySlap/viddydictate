# Model residency: LM Studio owns eviction (per-model TTL)

This file describes ViddyDictate's shipped model-residency behavior. It replaced the earlier
app-managed idle-unload timer while keeping its intent: an idle Mac must not keep large models
pinned overnight.

## The change

**LM Studio owns model eviction, not the app.** Every time a mode makes a model resident it loads it
with a per-model idle `--ttl`, and LM Studio unloads the model on its own after that idle window. There
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
  per-model TTL (`ttl(for:)`), plus `ensureReady` as the load-on-demand entry point.
- `AppDelegate.applicationDidFinishLaunching` — the `ModelManager.shared.start()` call is removed;
  nothing needs arming at launch (the LM Studio server is started lazily on the first load).
- The `ensureReady` call sites (CleanupClient / EmailClient / SearchClient) are unchanged in shape —
  their comments were updated to describe LM Studio-owned eviction.

### Per-model TTL

Set in `ModelManager` and applied at load time:

| Model (role)                                  | Idle TTL |
|-----------------------------------------------|----------|
| `qwen3-coder-30b-a3b-instruct-mlx` (cleanup / search retrieval) | 900 s (15 min) |
| `google/gemma-4-e4b` (email / search synthesis)                 | 300 s (5 min)  |

The IDs are not hardcoded twice — `ttl(for:)` derives them from the same `Settings` model keys the
working set uses. `ensureReady` takes a test-only `ttlOverrideSeconds` seam so the self-test can observe
eviction in seconds instead of 15 minutes.

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

None of these global settings are modified by this link — per-model TTL is expressed at load time via
`--ttl`, which a single global value cannot express anyway.

## Acceptance test: `--residency-selftest`

```
./build.sh
./build/ViddyDictateTests.app/Contents/MacOS/ViddyDictateTests --residency-selftest
```

`ModelResidencySelfTest` runs the locked **interleaved eviction acceptance test** from the verification bundle,
on qwen (the named model), with a short (20 s) test TTL so eviction is observable in ~35 s instead of 15
minutes. It asserts, in order:

1. the per-model TTL policy is the locked one (qwen 900 s, gemma 300 s) — pure unit check;
2. clean slate: qwen unloaded;
3. **ViddyDictate cleanup-path** load: `ensureReady(qwen, ttlOverride: 20)` → resident, and `lms ps
   --json` shows the 20 s TTL actually reached LM Studio;
4. **External-consumer seam**: a real qwen `/v1/chat/completions` turn succeeds against the shared instance;
5. a second cleanup-path `ensureReady` reuses the SAME resident instance (no reload);
6. idle past the TTL with the app doing **nothing** → LM Studio evicts qwen on its own (the app issues
   zero `unload` calls in steps 3–7, so the eviction can only be LM Studio's), while **bge-m3's
   residency is unchanged**;
7. the next request JIT-reloads qwen.

Production TTLs are 900 s / 300 s; the test uses 20 s only to keep the idle wait short. The mechanism is
identical at any TTL value.

### Evidence captured while building this link

- Probe: `lms load "google/gemma-4-e4b" -y --ttl 15` → `lms ps --json` showed `"ttlMs":15000`; after 30 s
  idle (no unload call) gemma was gone, while `text-embedding-bge-m3` (`"ttlMs":null`) and qwen stayed
  resident throughout.
- `--residency-selftest`, `--selftest` (cleanup, also exercises the clipboard layer), and
  `--email-selftest` all cleared green after the change; bge-m3's residency was unchanged.

## Current status

This mechanism shipped in ViddyDictate on 2026-07-06. Rebuilding and reinstalling the app preserves
the same LM Studio-owned eviction behavior.
