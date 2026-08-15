# Codex transform isolation and production boundary

The unauthenticated foundation uses dedicated app-owned state, immutable hardening bytes, a
strict stdin/JSONL/schema contract, and an external deny-default macOS containment runner. The authenticated
synthetic shipping gate validates that boundary. Explicit Codex bundles route through the same boundary,
owns dedicated-home status plus Connect/Reconnect device auth, and maps every abnormal exit, timeout,
unexpected event, tool/bookkeeping item, ambiguous message, or schema failure to the existing fail-closed
result contract. Seven route defaults retain their exact ratified model/effort choices. Cleanup now ships
`gpt-5.6-luna/low`; its old `gpt-5.4-mini` ratification is retained only as superseded history and the
replacement is explicitly auto-updated and unratified.

The runtime no longer accepts or rejects a Codex binary by version text alone. It quarantines each unseen
binary without auth or user content, audits its full feature/skill/prompt/containment boundary, installs
app-owned content-addressed executable and runner snapshots, and writes a receipt bound to those identities
and generated restrictive state. Every transform and metadata check revalidates that receipt around launch.
A compatible newer CLI remains available; an incompatible identity fails closed before user text is sent.

After the receipt is accepted, a bounded app-server session calls only `initialize`, `initialized`, and
paginated `model/list(includeHidden:true)`. A validated last-known-good catalog supplies visible picker
models and their advertised effort strings while preserving exact `row.model` represented values.
`row.id` is used only for explicit upgrade-edge resolution. Hidden sources migrate only through valid
catalog edges and exact-pair qualification; visible recommendations and classification holds never rewrite
a runnable route. Failed acquisition keeps any existing picker cache and performs no smoke or settings
write; a first-run failure says explicitly that no last-known-good catalog exists.

The content-free `codex-update-outcome.json` records only the last attempt, last successful catalog time,
a fixed stale/hold reason code, the next retry, and the outcome state. It has no fields for catalog rows,
provider output, stderr, prompts, or user content. Settings observes its change notification, so an already
open window refreshes after a check and the same status reloads after relaunch.

Production ownership is fixed:

```text
~/Library/Application Support/ViddyDictate/codex-home/  mode 0700
~/Library/Application Support/ViddyDictate/codex-cwd/   mode 0700, empty
~/Library/Caches/ViddyDictate/codex-tmp/                 mode 0700
```

`config.toml`, the output schema, and content-hashed `route-<sha256>.config.toml` profiles are written
through mode-0600 same-directory temporary files, flushed, atomically renamed, and held at mode 0400.
The complete canonical route-profile bytes include model, effort, exact `developer_instructions`, and the
envelope version. User text is fenced on stdin; it never appears in the runner/Codex argv or logs.

The runner applies a deny-default `sandbox-exec` profile. Filesystem reads are confined to required macOS
runtime files plus the three dedicated roots; writes are confined to the dedicated home/temp and the
sterile cwd remains read-only. The child can reach only one ephemeral loopback TCP
port owned by the runner; a tokened CONNECT proxy on that port accepts only `chatgpt.com:443` and
`api.openai.com:443`. Direct Internet, LAN, other loopback ports, and Unix sockets have no allow rule.
`sandbox-exec` receives only the self-targeted fork permission required for its initial filtered exec;
literal process-exec remains pinned to the Codex binary, so no shell or other process image is allowed.
The runner creates a dedicated process group and enforces SIGTERM, a bounded grace period, SIGKILL, and
reap on timeout.

The deny-default profile grants metadata-only access to the exact ancestors of the three dedicated roots,
plus fixed reads for the CLI's optional `/etc/codex/requirements.toml` probe and the system CA bundle.
`SSL_CERT_FILE` is pinned to `/etc/ssl/cert.pem`. The only additional native IPC is
`com.apple.SystemConfiguration.configd`, which the installed HTTP client consults while constructing its
proxy matcher; it cannot broaden transport because direct network remains denied and only the runner's
single loopback proxy port is reachable. The dedicated CLI may create `apply_patch`, `applypatch`, and
`codex-execve-wrapper` runtime aliases under `codex-home/tmp/arg0`; the authenticated gate accepts only those exact names and
only when each symlink target is the pinned Codex executable. Any other symlink is red.

Run from the repository root after `./build.sh`:

```sh
./scripts/codex-isolation-preflight.sh scratch
```

The preflight flags run from `build/ViddyDictateTests.app`; the external containment runner remains
in the shipped app's `Contents/Helpers/` directory.

`stage-production` is an explicit maintenance mode, not a routine link check. Do not run it against a
connected production home unless its own preconditions say that is safe. Both preflight modes use only
synthetic fixtures, perform no device login, inspect no auth file, make no model call, and never consult the
normal Codex home. Preflight records the installed CLI version as evidence, enumerates every seeded system skill and
requires exactly one disable entry for each, requires every audited external-capability feature false,
requires empty MCP/plugin inventories, and audits model-visible roles for context contamination.

If the calling environment forbids nested `sandbox_apply` or loopback listeners, the runner prints an
explicit `UNVERIFIED` host gate after its deterministic policy/proxy tests pass. That is not a containment
PASS; it must be cleared on an unsandboxed final host during the authenticated containment test.

After the unauthenticated checks, stop. The user's one-time `codex login --device-auth` is the separate
AUTH-GATE. No authenticated transform is accepted until the authenticated gate proves the same containment
policy, argv privacy, strict event rejection,
timeout group kill, and no surviving descendants with synthetic data.

After AUTH-GATE reports exactly `Logged in using ChatGPT`, rebuild and run the authenticated gate from the
repository root:

```sh
./build.sh
./scripts/codex-isolation-authenticated.sh
```

The authenticated gate re-audits the receipt-bound CLI identity, all disabled features and seeded skills,
empty MCP/plugin inventories,
model-visible prompt roles, restrictive modes, sterile cwd, and the external runner. It requires an exact
host containment PASS with no `UNVERIFIED` gate; locally rejects tool/bookkeeping, malformed, partial, and
ambiguous JSONL fixtures; then sends one adversarial synthetic transcript over stdin through the production
dedicated home and containment runner. While the call is live it inspects only that runner's dedicated
process group, requires the effective prompt and transcript to be absent from argv, permits no child process,
and proves the group is empty after exit. The audit also requires the synthetic outside file to remain
unchanged, the marker-command file to remain absent, the cwd to remain empty, and changed non-auth state to
contain no synthetic marker. Auth-file contents are always excluded without inspection.

The rail never prints prompt text, result text, raw JSONL, child stderr, or argv. Its evidence is limited to
hashes, event/item counts, process counts, state-scan counts, classifications, and timing. Any tool or
bookkeeping item, unexpected lifecycle event, schema failure, nonzero exit, timeout, containment gap,
canary hit, persisted synthetic marker, or surviving descendant is a hard failure.

After the authenticated gate, exercise every distinct canonical production `(model, effort)` pair sequentially through the
same shipping containment path:

```sh
build/ViddyDictate.app/Contents/Helpers/CodexProviderSmoke \
  --all-shipped-pairs \
  --runner build/ViddyDictate.app/Contents/Helpers/CodexContainmentRunner
```

The helper derives pairs from source-owned canonical defaults and never reads settings, preferences, notes,
dictation, clipboard, or other user content. For a targeted host check it also accepts repeated
`--pair <model> <effort>` arguments; those opaque inputs are passed exactly and cannot be mixed with
`--all-shipped-pairs`.
