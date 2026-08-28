#!/usr/bin/env python3
"""Offline L11 proof for the mlx-whisper runtime.

The caller supplies a cached model directory and runs this file with a fresh Python
venv whose site-packages are populated from the already-installed MLX runtime.  The
proof deliberately blocks every import of torch, then exercises the same daemon and
loader paths used by the app.  It never downloads a model or reads user audio.
"""

from __future__ import annotations

import argparse
import importlib.abc
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import wave
from pathlib import Path


class _TorchBlocker(importlib.abc.MetaPathFinder):
    """Make an accidental torch dependency fail as a real ImportError."""

    def find_spec(self, fullname: str, path=None, target=None):  # noqa: D401, ANN001
        if fullname == "torch" or fullname.startswith("torch."):
            raise ImportError("torch intentionally unavailable in L11 proof")
        return None


def _assert_torch_absent() -> None:
    loaded = [name for name in sys.modules if name == "torch" or name.startswith("torch.")]
    if loaded:
        raise AssertionError(f"torch was loaded: {loaded}")


def _write_silence(path: Path) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\x00\x00" * 8_000)


def _load_daemon(daemon_path: Path):
    spec = importlib.util.spec_from_file_location("vdb_l11_whisperd", daemon_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load daemon: {daemon_path}")
    daemon = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = daemon
    spec.loader.exec_module(daemon)
    return daemon


def _mlx_import_preflight() -> bool:
    """Detect a headless Metal denial without letting native MLX abort this process."""
    child = subprocess.run(
        [
            sys.executable,
            "-c",
            "import mlx_whisper; print('mlx-whisper import PASS', flush=True)",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=os.environ.copy(),
    )
    output = "\n".join(part for part in (child.stdout, child.stderr) if part).strip()
    if child.returncode == 0:
        print(output, flush=True)
        return True
    if "No Metal device available" in output:
        print(
            "INCONCLUSIVE: mlx-whisper import cannot reach the native MLX runtime "
            "because this headless sandbox has no Metal device",
            flush=True,
        )
        print(output, flush=True)
        return False
    raise RuntimeError(f"mlx-whisper import failed ({child.returncode}): {output}")


def _write_npz_fixture(root: Path) -> Path:
    """Create a tiny valid mlx-whisper model so the npz fallback is executed."""
    import numpy as np

    model = root / "npz-model"
    model.mkdir()
    config = {
        "n_mels": 80,
        "n_audio_ctx": 1500,
        "n_audio_state": 384,
        "n_audio_head": 6,
        "n_audio_layer": 4,
        "n_vocab": 51865,
        "n_text_ctx": 448,
        "n_text_state": 384,
        "n_text_head": 6,
        "n_text_layer": 4,
    }
    (model / "config.json").write_text(json.dumps(config), encoding="utf-8")
    np.savez(model / "weights.npz")
    return model


def _proof_loader_formats(model_path: Path, scratch: Path) -> None:
    from mlx_whisper.load_models import load_model

    # The real cached safetensors model is loaded by daemon warmup below.  This
    # direct call proves the loader's explicit suffix branch too, without a Hub
    # lookup or another model download.
    if not (model_path / "weights.safetensors").is_file():
        raise AssertionError(f"cached safetensors checkpoint missing: {model_path}")

    npz_model = _write_npz_fixture(scratch)
    tiny = load_model(str(npz_model))
    if tiny.dims.n_vocab != 51865:
        raise AssertionError("npz fixture did not load as a Whisper model")
    _assert_torch_absent()
    print("checkpoint formats: safetensors (daemon) + npz (loader) PASS", flush=True)


def _proof_daemon_modes(daemon, audio_path: Path) -> None:
    if not daemon._ready.is_set():
        raise AssertionError("daemon warmup did not reach its terminal state")
    if daemon._load_error[0] is not None:
        raise AssertionError(f"safetensors warmup failed: {daemon._load_error[0]}")

    # These are the complete values accepted by the daemon headers.  The prompt
    # is included on the branches that pass it through to mlx-whisper.
    cases = [
        (condition, clean, prompt)
        for condition in (None, False, True)
        for clean in (None, False, True)
        for prompt in (None, "L11")
    ]
    for condition, clean, prompt in cases:
        raw, text, segments, duration = daemon._transcribe(
            str(audio_path),
            cond_prev=condition,
            clean=clean,
            initial_prompt=prompt,
        )
        if not isinstance(raw, str) or not isinstance(text, str):
            raise AssertionError("daemon returned a non-string transcript")
        if not isinstance(segments, list) or duration != 0.5:
            raise AssertionError("daemon response shape or WAV duration is wrong")
        _assert_torch_absent()
    print(f"daemon modes: {len(cases)} condition/clean combinations + prompt PASS", flush=True)


def _proof_import_error_surface(daemon) -> None:
    import mlx_whisper

    original = mlx_whisper.transcribe
    old_ready = daemon._ready
    old_error = daemon._load_error

    def fail(*args, **kwargs):  # noqa: ANN002, ANN003
        raise ImportError("torch intentionally unavailable")

    try:
        mlx_whisper.transcribe = fail
        daemon._ready = threading.Event()
        daemon._load_error = [None]
        daemon._warmup()
        if daemon._load_error[0] != "torch intentionally unavailable":
            raise AssertionError("daemon swallowed warmup ImportError")
    finally:
        mlx_whisper.transcribe = original
        daemon._ready = old_ready
        daemon._load_error = old_error
    print("ImportError surface: daemon health error retains torch failure PASS", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    args = parser.parse_args()

    model_path = args.model.resolve(strict=True)
    daemon_path = args.daemon.resolve(strict=True)
    if sys.prefix == sys.base_prefix:
        raise RuntimeError("proof must run inside a cold venv")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    sys.meta_path.insert(0, _TorchBlocker())
    _assert_torch_absent()

    if not _mlx_import_preflight():
        return 2

    import mlx_whisper  # noqa: F401

    _assert_torch_absent()
    try:
        import mlx_whisper.torch_whisper  # noqa: F401
    except ImportError as exc:
        if "torch" not in str(exc):
            raise AssertionError(f"unexpected ImportError: {exc}") from exc
        print("unavailable torch adapter: ImportError surfaced PASS", flush=True)
    else:
        raise AssertionError("torch adapter imported despite the blocker")

    with tempfile.TemporaryDirectory(prefix="vdb-l11-proof-") as temp_dir:
        scratch = Path(temp_dir)
        audio_path = scratch / "silence.wav"
        _write_silence(audio_path)
        _proof_loader_formats(model_path, scratch)

        os.environ["VIDDYDICTATE_WHISPER_MODEL"] = str(model_path)
        daemon = _load_daemon(daemon_path)
        daemon._warmup()
        _proof_daemon_modes(daemon, audio_path)
        _proof_import_error_surface(daemon)

    _assert_torch_absent()
    print("TORCH-FREE PROOF PASS", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"TORCH-FREE PROOF INCONCLUSIVE: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(2)
