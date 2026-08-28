# L11 torch-free proof

Date: 2026-08-27

## Result

The proof is inconclusive in the Codex deterministic seatbelt. The installer therefore remains on the 1.0 path with `torch`; no cutover was made.

The cold proof venv was created from the bundled Python under a temporary directory. Its package overlay linked the already-installed non-torch MLX runtime read-only, with `torch`, `torchaudio`, and `torchvision` excluded. No model or user audio was downloaded or read.

The first import of `mlx_whisper` aborted in native MLX before the loader or daemon could run:

    [metal::load_device] No Metal device available

This is an executor limitation in the headless sandbox, not evidence that the runtime is torch-free. The proof harness records this as `INCONCLUSIVE` and exits without claiming a cut.

## Required proof surface

The measured app reaches one daemon model path. The loader supports the cached `weights.safetensors` checkpoint and its `weights.npz` fallback. The daemon has one warmup path and one transcribe path; its complete control matrix is 3 `condition_on_previous_text` values (omitted, off, on) x 3 cleanup values (omitted, off, on) x 2 initial-prompt values (omitted, present), or 18 cases. The harness also checks that an unavailable torch adapter raises `ImportError` and that the daemon retains that error for health reporting.

The native MLX denial occurred before all of those cases, so the following remain unverified in this environment:

- safetensors load and every daemon mode;
- npz fallback load;
- torch adapter `ImportError` propagation after the MLX import boundary.

The proof can be rerun on a Metal-capable executor with:

    python scripts/torch-free-proof.py --model <cached-model-directory> --daemon viddydictate_whisperd.py

Only a complete `TORCH-FREE PROOF PASS` permits the no-torch installer cut. Until then, `mlx-whisper` keeps its declared dependency closure intact.
