# B20 / O6: the torch-free proof, re-run unsandboxed

Date: 2026-08-29. Link `vdb-torch`, unsandboxed on Ben's Mac (64 GB, Metal present).
Supersedes `torch-free-proof-l11.md`, which is kept because it records a real earlier outcome.

## Result: PASS, 48/48. The cut ships.

`scripts/torch-free-proof.py` exits 0 against a venv built cold from the app's own bundled
3.12.14 interpreter with the torch-free package list.

## Why L11 could not close this, and what changed

`vdb-L11` returned INCONCLUSIVE, correctly. Two things blocked it, and both are gone here:

1. **No Metal device in the Codex seatbelt.** Native MLX aborted at `[metal::load_device]` before a
   single checkpoint was loaded, so nothing past the import boundary was ever exercised.
2. **Its harness overlaid an already-installed runtime** rather than building an environment. B20 asks
   for a cold venv built from scratch, and a symlink overlay of a working install is not that: it
   cannot show what a stranger's first run actually produces.

This run builds the venv cold, from the shipped interpreter, and every phase runs against real Metal,
the real cached checkpoint, real speech, and the real daemon over HTTP.

## What was proven, against B20's bar

**"A cold venv built from scratch."** Created by `Contents/Resources/python/bin/python3` inside the
installed `.app`, asserted from `pyvenv.cfg`. `torch`, `sympy`, `mpmath`, `networkx`, `jinja2` and
`markupsafe` are all absent as distributions, and `import torch` raises a genuine
`ModuleNotFoundError` - not a blocked import faked by a meta-path finder, which is what L11 had to do.

**"Every mode."** Measured rather than assumed: the app has exactly **one** entry point into the STT
daemon, `DaemonClient.transcribe`, reached from `DictationController` and `RetainedTakeRecovery`. The
transform modes - cleanup at each level, Option+M email, Option+L and Option+G synthesis - are
`TextTransformClient` calls on a transcript that already exists; they never touch `mlx_whisper` or the
daemon. So "every mode" at this boundary *is* the daemon's header surface, and all 18 cases of it
(3 `X-Condition-Previous-Text` x 3 `X-Clean` x 2 `X-Initial-Prompt-B64`) were driven over real HTTP
against a real daemon process. All 18 returned the spoken sentence and echoed their own parameters
back correctly. This closes the 18 daemon control cases `vdb-R` listed as unverified.

**"Every checkpoint format the app can reach."** `load_models.load_model` has three branches and all
three were loaded AND used to transcribe real speech, 5/5 keywords each:

| Format | How the app reaches it | Result |
|---|---|---|
| safetensors | the shipped `mlx-community/whisper-large-v3-turbo` | loads, transcribes |
| npz | `load_model`'s fallback when `weights.safetensors` is absent | loads, transcribes |
| quantized | a quantized repo via `VIDDYDICTATE_WHISPER_MODEL`, which is user-settable | loads, transcribes |

The npz checkpoint is built from the *real* weights and verified tensor-equal to the safetensors
source, so it is a real weight load. L11's npz fixture was an empty `np.savez` archive, which loads a
randomly-initialised skeleton and proves nothing about reading weights.

**"`ImportError` surfaced rather than swallowed."** Proven twice, and the second is the important one:

- `import mlx_whisper.torch_whisper` raises `ImportError` naming torch. Statically, `torch_whisper.py`
  is the only module in the package that imports torch, and *nothing in the package imports it*, so
  the reachable surface is torch-free by construction rather than by luck.
- **The exact `--no-deps` accident B20 names was reproduced.** A venv with mlx-whisper installed
  `--no-deps` and nothing else installs cleanly, and then the daemon fails *visibly*: `/health` returns
  `ready: false` with the real error text, `/transcribe` returns HTTP 500 with
  `model load failed: No module named 'numpy'`, and the log carries `WARMUP FAILED`. It does not
  degrade quietly, which is the failure shape this proof exists to catch.

## What it costs and what it saves, measured cold

Both closures resolved with `pip install --dry-run --report` on the bundled interpreter, summing every
resolved wheel's `Content-Length`; both venvs then built cold and measured on disk.

|  | wheels | download | on disk |
|---|---|---|---|
| with torch | 35 | 242,159,990 B (230.9 MiB) | 1132.3 MiB |
| torch-free | 28 | 121,077,755 B (115.5 MiB) | 494.4 MiB |
| **saving** | 7 | **115.5 MiB (50.0%)** | **637.9 MiB (56.3%)** |

The with-torch figure reproduces L5's O1 measurement to the byte, independently, two days later.

**The baton's "~529 MB" is a disk number, not a download number, and the two are not interchangeable.**
529 MB is what `site-packages/torch` occupies in Ben's live venv; the full disk saving is larger
(637.9 MiB, because torch's exclusive subtree goes too) and the *download* saving is smaller
(115.5 MiB, because torch ships as a 106 MiB wheel). Against B2's 1.87 GB core the download drops
about 6%; the picker's core total moves from 1.9 GB to 1.7 GB. The disk saving on a finished install
is the bigger prize and is roughly a fifth of the ~2.9 GB `vdb-R` measured.

## The cut, and the risk it creates

The package list is data, so the cut is a list edit. `InstallerPackage` gained two fields:

- `resolvesDependencies` - `false` installs with `--no-deps`. Set only on `mlx-whisper`.
- `importCheck` - the module to import in the finished venv to prove the closure is complete.

`sttDaemon.packages` is now mlx-whisper's own `Requires-Dist` list minus torch, each still resolving
its *own* dependencies normally, followed by mlx-whisper with `--no-deps`. The blast radius is exactly
one package.

**The risk is real and is not hand-waved.** `--no-deps` moves ownership of mlx-whisper's dependency
closure from pip into this repo. If a future 0.4.x adds a dependency, the install would succeed and
the daemon would fail later - which is precisely the failure B20 was written to avoid. So the engine
now runs `python -c "import mlx_whisper"` in the venv it just built, and a failure fails *that row*
with python's own error text. It is not retried: a missing module is a resolution fact, not a
transport one, so O5's rule says further attempts can only waste the user's time. `install-daemon.sh`
carries the same list and the same guard, so a developer venv and a stranger's venv are one thing.

## Re-running it

    <cold-venv>/bin/python scripts/torch-free-proof.py \
      --model <local checkpoint dir> --daemon viddydictate_whisperd.py \
      --work <scratch> --port 8791 \
      --app-python ~/Applications/ViddyDictate.app/Contents/Resources/python/bin/python3

`--model` takes a local directory, never a repo id, so the proof cannot download a model. The port is
required to be neither 8765 (the live daemon) nor 8766 (the app's control server).

## Not covered

- The **installed** app performing this install for real. The proof builds the venv with the same
  interpreter and the same package list, but it does not drive `InstallerEngine` end to end against
  PyPI; that is the fresh-install rehearsal, and it belongs in a hand test.
- Whether a *future* mlx-whisper still works. That is what `importCheck` is for: it converts that
  question from a silent risk into a loud install-time failure.
