#!/usr/bin/env python3
"""B20 / O6: prove the STT runtime is genuinely torch-free, or prove that it is not.

This is the *unsandboxed* re-run of the proof `vdb-L11` could only take as far as the MLX
import boundary.  L11 ran inside the Codex seatbelt, which has no Metal device, so native
MLX aborted before a single checkpoint was loaded and the honest verdict was INCONCLUSIVE.
It also overlaid an already-installed runtime rather than building a venv, which is not the
bar B20 sets.  Both are fixed here: the caller supplies a venv built COLD from the app's
bundled interpreter with the torch-free package list, and every phase runs against real
Metal, the real cached checkpoint, real speech audio, and the real daemon over HTTP.

The bar, from B20: every mode, every checkpoint format the app can reach, a cold venv built
from scratch, and `ImportError` surfaced rather than swallowed.

Nothing here downloads a model, writes to the user's caches, or touches either of the app's
working virtual environments.  The daemon it starts binds a caller-supplied port so it can
never collide with the live one on 8765 or the app's control server on 8766.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import importlib.metadata
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Every distribution that exists in the with-torch closure and in no other. If the cut is real,
# none of these may be installed: torch is the prize, the rest are torch's exclusive subtree.
TORCH_SUBTREE = ["torch", "sympy", "mpmath", "networkx", "jinja2", "markupsafe"]

# The sentence the proof speaks and expects back. Chosen so a hallucination-gated daemon cannot
# pass by emitting one of its blocklisted silence phrases.
SPOKEN = "The quick brown fox jumps over the lazy dog near the riverbank."
EXPECTED_WORDS = ["quick", "brown", "fox", "lazy", "dog"]

FFMPEG_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

_failures: list[str] = []
_checks = 0


def check(label: str, ok: bool, detail: str = "") -> bool:
    global _checks
    _checks += 1
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{(' — ' + detail) if detail else ''}", flush=True)
    if not ok:
        _failures.append(f"{label}{(': ' + detail) if detail else ''}")
    return ok


def phase(title: str) -> None:
    print(f"\n=== {title} ===", flush=True)


def assert_torch_unloaded(where: str) -> None:
    loaded = [m for m in sys.modules if m == "torch" or m.startswith("torch.")]
    check(f"torch absent from sys.modules after {where}", not loaded, ", ".join(loaded))


# ---------------------------------------------------------------------------
# P0 — the environment really is a cold, torch-free venv from the bundled runtime
# ---------------------------------------------------------------------------

def phase_environment(app_python: Path | None) -> None:
    phase("P0  cold venv built from the bundled interpreter, torch-free")

    check("running inside a venv", sys.prefix != sys.base_prefix,
          f"prefix={sys.prefix}")

    cfg = Path(sys.prefix) / "pyvenv.cfg"
    home = ""
    if cfg.is_file():
        for line in cfg.read_text().splitlines():
            if line.startswith("home"):
                home = line.split("=", 1)[1].strip()
    if app_python is not None:
        # `home` is the interpreter's *directory*, which is why this compares against the parent.
        check("venv was created by the app's BUNDLED interpreter",
              Path(home) == app_python.resolve().parent, f"pyvenv.cfg home={home!r}")
    else:
        print(f"  note  venv home={home!r} (no --app-python given, not asserted)", flush=True)

    installed = {d.metadata["Name"].lower() for d in importlib.metadata.distributions()
                 if d.metadata["Name"]}
    for name in TORCH_SUBTREE:
        check(f"{name} is not installed", name not in installed)

    try:
        import torch  # noqa: F401
    except ModuleNotFoundError as exc:
        check("`import torch` raises a real ModuleNotFoundError", True, str(exc))
    except ImportError as exc:
        check("`import torch` raises a real ImportError", True, str(exc))
    else:
        check("`import torch` raises", False, "torch imported — this venv is NOT torch-free")


# ---------------------------------------------------------------------------
# P1 — the reachable import surface of mlx_whisper needs no torch
# ---------------------------------------------------------------------------

def phase_imports() -> None:
    phase("P1  mlx_whisper's reachable surface, and the torch adapter's ImportError")

    import mlx.core as mx
    check("MLX has a real Metal device", str(mx.default_device()).startswith("Device(gpu"),
          str(mx.default_device()))
    a = mx.ones((8, 8))
    check("MLX executes a GPU matmul", float((a @ a).sum()) == 512.0)

    import mlx_whisper
    check("`import mlx_whisper` succeeds", True, mlx_whisper.__version__)
    assert_torch_unloaded("importing mlx_whisper")

    import mlx_whisper.transcribe  # noqa: F401
    import mlx_whisper.decoding  # noqa: F401
    import mlx_whisper.load_models  # noqa: F401
    import mlx_whisper.audio  # noqa: F401
    import mlx_whisper.timing  # noqa: F401
    import mlx_whisper.tokenizer  # noqa: F401
    import mlx_whisper.whisper  # noqa: F401
    import mlx_whisper.writers  # noqa: F401
    check("every mlx_whisper module the daemon can reach imports", True,
          "transcribe, decoding, load_models, audio, timing, tokenizer, whisper, writers")
    assert_torch_unloaded("importing the whole reachable package")

    # The one module that does need torch. It must fail LOUDLY, naming torch, rather than
    # importing a degraded stand-in. Nothing inside mlx_whisper imports it; this proves the
    # adapter is unreachable *and* that reaching for it is a visible error, not a silent one.
    try:
        import mlx_whisper.torch_whisper  # noqa: F401
    except ImportError as exc:
        check("mlx_whisper.torch_whisper raises ImportError naming torch",
              "torch" in str(exc), str(exc))
    else:
        check("mlx_whisper.torch_whisper raises ImportError", False,
              "the torch adapter imported — torch is present after all")

    # Static confirmation that torch_whisper is the ONLY torch importer, so the dynamic result
    # above is not an accident of which code paths this run happened to touch.
    pkg = Path(mlx_whisper.__file__).parent
    importers = sorted(p.name for p in pkg.glob("*.py")
                       if "import torch" in p.read_text(encoding="utf-8", errors="replace"))
    check("torch_whisper.py is the only module in the package that imports torch",
          importers == ["torch_whisper.py"], ", ".join(importers) or "none")

    referrers = sorted(p.name for p in pkg.glob("*.py")
                       if "torch_whisper" in p.read_text(encoding="utf-8", errors="replace")
                       and p.name != "torch_whisper.py")
    check("no module in the package imports torch_whisper",
          not referrers, ", ".join(referrers))


# ---------------------------------------------------------------------------
# P2 — every checkpoint format load_model can reach
# ---------------------------------------------------------------------------

def _reference_tensor(weights: dict):
    key = sorted(weights)[0]
    return key, weights[key]


def phase_checkpoints(model_dir: Path, work: Path) -> dict[str, Path]:
    phase("P2  every checkpoint format load_models.load_model can reach")

    import mlx.core as mx
    import mlx.nn as nn
    from mlx_whisper.load_models import load_model

    formats: dict[str, Path] = {}

    # --- safetensors: the format the shipped model actually uses -------------------------
    st = model_dir / "weights.safetensors"
    check("the cached checkpoint is safetensors", st.is_file(), str(st))
    model = load_model(str(model_dir))
    check("safetensors checkpoint loads", model.dims.n_vocab > 0,
          f"n_vocab={model.dims.n_vocab} n_text_layer={model.dims.n_text_layer}")
    assert_torch_unloaded("loading the safetensors checkpoint")
    formats["safetensors"] = model_dir

    source = mx.load(str(st))
    ref_key, ref_val = _reference_tensor(source)

    # --- npz: load_model's documented fallback ------------------------------------------
    # Built from the SAME real weights, so this exercises a real weight load rather than an
    # empty archive that would load a randomly-initialised skeleton and prove nothing.
    npz_dir = work / "npz-model"
    npz_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(model_dir / "config.json", npz_dir / "config.json")
    mx.savez(str(npz_dir / "weights.npz"), **source)
    check("npz checkpoint written from the real weights",
          (npz_dir / "weights.npz").is_file(),
          f"{(npz_dir / 'weights.npz').stat().st_size / 1e9:.2f} GB")
    npz_model = load_model(str(npz_dir))
    check("npz checkpoint loads", npz_model.dims.n_vocab == model.dims.n_vocab,
          f"n_vocab={npz_model.dims.n_vocab}")
    round_trip = mx.load(str(npz_dir / "weights.npz"))[ref_key]
    check("npz weights are the real weights, not a skeleton",
          bool(mx.all(round_trip == ref_val).item()), ref_key)
    assert_torch_unloaded("loading the npz checkpoint")
    formats["npz"] = npz_dir

    # --- quantized: load_model's third branch --------------------------------------------
    # Reachable because VIDDYDICTATE_WHISPER_MODEL is user-settable and mlx-community publishes
    # quantized whisper repos. Built locally so the branch is exercised without a download.
    q_dir = work / "quantized-model"
    q_dir.mkdir(parents=True, exist_ok=True)
    from mlx.utils import tree_flatten
    q_model = load_model(str(model_dir))
    nn.quantize(q_model, group_size=64, bits=4,
                class_predicate=lambda _p, m: isinstance(m, (nn.Linear, nn.Embedding)))
    flat = dict(tree_flatten(q_model.parameters()))
    mx.save_safetensors(str(q_dir / "weights.safetensors"), flat)
    config = json.loads((model_dir / "config.json").read_text())
    config["quantization"] = {"group_size": 64, "bits": 4}
    (q_dir / "config.json").write_text(json.dumps(config))
    quantized = load_model(str(q_dir))
    check("quantized checkpoint loads through load_model's quantization branch",
          quantized.dims.n_vocab == model.dims.n_vocab,
          f"n_vocab={quantized.dims.n_vocab}, 4-bit group 64")
    assert_torch_unloaded("loading the quantized checkpoint")
    formats["quantized"] = q_dir

    return formats


# ---------------------------------------------------------------------------
# P3 — real speech, decoded end to end, on each reachable format
# ---------------------------------------------------------------------------

def make_speech_wav(work: Path) -> Path:
    aiff = work / "speech.aiff"
    wav = work / "speech.wav"
    subprocess.run(["/usr/bin/say", "-o", str(aiff), SPOKEN], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff),
                    "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)],
                   check=True, env={**os.environ, "PATH": FFMPEG_PATH})
    return wav


def _hits(text: str) -> int:
    low = text.lower()
    return sum(1 for w in EXPECTED_WORDS if w in low)


def phase_transcription(formats: dict[str, Path], wav: Path) -> None:
    phase("P3  real speech transcribed end to end, on every reachable format")

    import mlx_whisper
    for name, path in formats.items():
        result = mlx_whisper.transcribe(str(wav), path_or_hf_repo=str(path))
        text = (result.get("text") or "").strip()
        check(f"{name}: real speech transcribes correctly",
              _hits(text) >= 4, f"{_hits(text)}/5 keywords — {text!r}")
        assert_torch_unloaded(f"transcribing through the {name} checkpoint")


# ---------------------------------------------------------------------------
# P4 — the real daemon, over HTTP, across its whole control matrix
# ---------------------------------------------------------------------------

class Daemon:
    def __init__(self, script: Path, model: Path, port: int, log: Path,
                 env_extra: dict[str, str] | None = None):
        self.port, self.log = port, log
        env = {**os.environ, "PATH": FFMPEG_PATH,
               "VIDDYDICTATE_WHISPER_MODEL": str(model),
               "VIDDYDICTATE_WHISPER_PORT": str(port),
               "VIDDYDICTATE_WHISPER_IDLE_S": "3600",
               "HF_HUB_OFFLINE": "1"}
        env.update(env_extra or {})
        self.fh = open(log, "w")
        self.proc = subprocess.Popen([sys.executable, str(script)],
                                     stdout=self.fh, stderr=subprocess.STDOUT, env=env)

    def health(self, timeout: float = 3.0) -> dict | None:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
            conn.request("GET", "/health")
            return json.loads(conn.getresponse().read())
        except Exception:
            return None
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def wait_settled(self, deadline_s: float = 300.0) -> dict | None:
        """Wait until warmup reaches a terminal state — ready, or ready-with-an-error."""
        end = time.monotonic() + deadline_s
        while time.monotonic() < end:
            h = self.health()
            if h is not None and (h.get("ready") or h.get("error")):
                return h
            if self.proc.poll() is not None:
                return None
            time.sleep(0.5)
        return None

    def transcribe(self, wav: bytes, headers: dict[str, str]) -> tuple[int, dict]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=180)
        h = {"Content-Type": "application/octet-stream", "X-Audio-Format": "wav", **headers}
        conn.request("POST", "/transcribe", body=wav, headers=h)
        resp = conn.getresponse()
        code, body = resp.status, resp.read()
        conn.close()
        try:
            return code, json.loads(body)
        except Exception:
            return code, {"raw": body[:400].decode("utf-8", "replace")}

    def stop(self) -> None:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
            conn.request("POST", "/shutdown", body=b"")
            conn.getresponse().read()
            conn.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.fh.close()


def phase_daemon(script: Path, model: Path, wav: Path, port: int, work: Path) -> None:
    phase("P4  the real daemon over HTTP: warmup, health, and all 18 control cases")

    audio = wav.read_bytes()
    daemon = Daemon(script, model, port, work / "daemon.log")
    try:
        health = daemon.wait_settled()
        if not check("daemon warms up and answers /health", health is not None,
                     json.dumps(health) if health else "no response — see daemon.log"):
            return
        check("warmup reported no load error", health.get("error") is None,
              str(health.get("error")))
        check("daemon reports ready", bool(health.get("ready")))
        check("daemon reports the model it actually loaded",
              health.get("model") == str(model), str(health.get("model")))

        bias = base64.b64encode("riverbank, ViddyDictate".encode()).decode()
        cases = [(c, cl, p)
                 for c in (None, "0", "1")
                 for cl in (None, "0", "1")
                 for p in (None, bias)]
        check("the control matrix is the daemon's complete header surface",
              len(cases) == 18, f"3 condition x 3 clean x 2 prompt = {len(cases)}")

        ok = 0
        for cond, clean, prompt in cases:
            headers: dict[str, str] = {}
            if cond is not None:
                headers["X-Condition-Previous-Text"] = cond
            if clean is not None:
                headers["X-Clean"] = clean
            if prompt is not None:
                headers["X-Initial-Prompt-B64"] = prompt
            code, body = daemon.transcribe(audio, headers)
            label = (f"cond={cond or 'omitted'} clean={clean or 'omitted'} "
                     f"prompt={'present' if prompt else 'omitted'}")
            if code != 200:
                check(f"case {label}", False, f"HTTP {code}: {body}")
                continue
            text = body.get("transcript", "")
            params = body.get("parameters", {})
            good = (_hits(text) >= 4
                    and params.get("condition_on_previous_text")
                        == (True if cond is None else cond == "1")
                    and params.get("clean") == (False if clean is None else clean == "1")
                    and params.get("initial_prompt_chars") == (0 if prompt is None else 23)
                    and isinstance(body.get("raw_transcript"), str)
                    and isinstance(body.get("segments"), list))
            if good:
                ok += 1
            else:
                check(f"case {label}", False, f"{text!r} params={params}")
        check("all 18 control cases transcribe correctly and echo their parameters",
              ok == 18, f"{ok}/18")

        code, body = daemon.transcribe(b"", {})
        check("an empty body is refused rather than transcribed", code == 400, f"HTTP {code}")
    finally:
        daemon.stop()

    log = (work / "daemon.log").read_text(errors="replace")
    check("nothing in the daemon's own output mentions torch",
          "torch" not in log.lower(), log[-300:] if "torch" in log.lower() else "")


# ---------------------------------------------------------------------------
# P5 — ImportError is SURFACED, proven by reproducing the exact --no-deps accident
# ---------------------------------------------------------------------------

def phase_import_error_surfaced(script: Path, model: Path, port: int, work: Path,
                                app_python: Path) -> None:
    phase("P5  a broken import is surfaced, not swallowed (the real --no-deps accident)")

    broken = work / "broken-venv"
    if broken.exists():
        shutil.rmtree(broken)
    subprocess.run([str(app_python), "-m", "venv", str(broken)], check=True)
    py = broken / "bin" / "python"
    # B20's named failure shape, reproduced exactly: mlx-whisper installed with --no-deps and
    # nothing else. It "installs cleanly" — and must then fail VISIBLY, not degrade quietly.
    r = subprocess.run([str(py), "-m", "pip", "install", "--quiet", "--no-deps",
                        "--disable-pip-version-check", "mlx-whisper~=0.4.3"],
                       capture_output=True, text=True,
                       env={**os.environ, "PIP_CACHE_DIR": os.environ.get("PIP_CACHE_DIR", "")})
    check("mlx-whisper installs cleanly with --no-deps and no dependencies",
          r.returncode == 0, r.stderr[-200:])

    env = {**os.environ, "PATH": FFMPEG_PATH, "VIDDYDICTATE_WHISPER_MODEL": str(model),
           "VIDDYDICTATE_WHISPER_PORT": str(port), "HF_HUB_OFFLINE": "1"}
    log = work / "broken-daemon.log"
    with open(log, "w") as fh:
        proc = subprocess.Popen([str(py), str(script)], stdout=fh,
                                stderr=subprocess.STDOUT, env=env)
    try:
        health = None
        end = time.monotonic() + 60
        while time.monotonic() < end:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                conn.request("GET", "/health")
                health = json.loads(conn.getresponse().read())
                conn.close()
                if health.get("ready") or health.get("error"):
                    break
            except Exception:
                pass
            if proc.poll() is not None:
                break
            time.sleep(0.4)

        if not check("the broken daemon still answers /health", health is not None,
                     "" if health else "no response"):
            return
        check("/health does NOT claim ready", not health.get("ready"), json.dumps(health))
        err = health.get("error") or ""
        check("/health carries the real import error text", "module named" in err or "import" in err.lower(),
              err)

        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("POST", "/transcribe", body=b"\x00" * 64,
                     headers={"Content-Type": "application/octet-stream"})
        resp = conn.getresponse()
        code, body = resp.status, json.loads(resp.read())
        conn.close()
        check("/transcribe fails with 500 rather than returning empty text", code == 500,
              f"HTTP {code}")
        check("/transcribe reports the load failure verbatim",
              "model load failed" in body.get("error", ""), body.get("error", "")[:160])
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=10)
        except Exception:
            proc.kill()

    text = log.read_text(errors="replace")
    check("the daemon logged WARMUP FAILED rather than starting silently",
          "WARMUP FAILED" in text, text[-240:])


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, required=True,
                    help="a LOCAL checkpoint directory; never a repo id, so no download can occur")
    ap.add_argument("--daemon", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--port", type=int, default=8791)
    ap.add_argument("--app-python", type=Path, default=None,
                    help="the app's bundled interpreter, asserted as this venv's creator")
    args = ap.parse_args()

    model = args.model.resolve(strict=True)
    script = args.daemon.resolve(strict=True)
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)

    if args.port in (8765, 8766):
        print("REFUSING: 8765 is the live daemon and 8766 is the app's control server",
              file=sys.stderr)
        return 2

    os.environ["HF_HUB_OFFLINE"] = "1"

    phase_environment(args.app_python)
    phase_imports()
    formats = phase_checkpoints(model, work)
    wav = make_speech_wav(work)
    phase_transcription(formats, wav)
    phase_daemon(script, model, wav, args.port, work)
    if args.app_python:
        phase_import_error_surfaced(script, model, args.port, work, args.app_python)

    print(f"\n{'=' * 68}")
    if _failures:
        print(f"TORCH-FREE PROOF FAIL — {len(_failures)} of {_checks} checks failed:")
        for f in _failures:
            print(f"  - {f}")
        return 1
    print(f"TORCH-FREE PROOF PASS — {_checks}/{_checks} checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
