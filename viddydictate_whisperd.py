#!/usr/bin/env python3
"""Local Whisper transcription daemon for ViddyDictate.

This long-running, localhost-bound HTTP service keeps an mlx-whisper model resident so the app
can request low-latency partial and final transcriptions. Loading the model once takes about two
seconds cold; a short clip then transcribes in about 0.4 seconds warm.

Audio is transcribed only on this Mac. The service listens on 127.0.0.1 and does not send audio
to a remote transcription endpoint. Language is auto-detected for code-switched speech.

The app wakes the daemon on demand. It self-exits after VIDDYDICTATE_WHISPER_IDLE_S (default 1800 seconds)
with no transcribe activity. Health polling does not count as activity, so an idle engine still
shuts itself off.

ANTI-HALLUCINATION (large-v3-turbo is a heavy end-of-audio repeater): decode-time guard
(condition_on_previous_text off by default + the no_speech/logprob/compression thresholds) plus an
output cleanup pass that drops fabricated non-speech segments and collapses repeated word/phrase
loops before returning. ViddyDictate can override these settings per request; callers that omit
the headers receive the daemon defaults.

Endpoints (all 127.0.0.1 only):
  GET  /health      -> {"ready": bool, "model": str, "idle_s": float, "error": str|null,
                        "phase": str, "phase_s": float, "phase_detail": str|null}
                       `phase` is one of starting|resolving|downloading|loading|ready|error and
                       `phase_s` the seconds spent in it, so a caller can say what a slow warm is
                       doing. The first four keys are unchanged; older callers ignore the rest.
  POST /transcribe  -> body = raw audio bytes (webm/mp4/ogg/wav); X-Audio-Format header gives the
                       container; X-Condition-Previous-Text (0/1) and X-Clean (0/1) override the
                       anti-hallucination defaults for this request; X-Initial-Prompt-B64 (base64
                       UTF-8) supplies an optional per-request whisper initial_prompt bias for
                       ViddyDictate's correction dictionary; callers that omit it are unaffected;
                       returns {"transcript": "..."}
  POST /shutdown    -> graceful exit

Config (env):
  VIDDYDICTATE_WHISPER_PORT             listen port (default 8765)
  VIDDYDICTATE_WHISPER_MODEL            mlx-whisper HF repo id (default mlx-community/whisper-large-v3-turbo)
  VIDDYDICTATE_WHISPER_IDLE_S           idle-shutdown seconds (default 1800)
  VIDDYDICTATE_WHISPER_LANG             force a language code (default: auto-detect for code-switched jerga)
  VIDDYDICTATE_WHISPER_CONDITION_PREV   condition_on_previous_text default for header-less callers (default 1)
  VIDDYDICTATE_WHISPER_CLEAN            run output cleanup for header-less callers (default 0)
  VIDDYDICTATE_WHISPER_NOSPEECH_THOLD   no_speech_threshold (default 0.6)
  VIDDYDICTATE_WHISPER_LOGPROB_THOLD    logprob_threshold (default -1.0)
  VIDDYDICTATE_WHISPER_COMPRESSION_THOLD compression_ratio_threshold (default 2.4)
  VIDDYDICTATE_WHISPER_MAX_REPEATS      collapse a word/short-phrase run repeated >= this many times (default 3)

OFFLINE-FIRST WARM: the model is loaded from its local Hugging Face snapshot directory whenever one is
complete on disk, with HF_HUB_OFFLINE=1 set before huggingface_hub is imported, so a cold start never
waits on huggingface.co. Handing mlx_whisper a repo id instead makes it call snapshot_download, which
asks the Hub for repo info with no timeout before it looks at the cache; right after a Mac wakes, that
one request stalled a warm for five minutes. Only a model that is not on disk at all goes to the
network, and then behind a bounded reachability probe (see _download_snapshot).

The turbo model handles both partials and the final pass. A separate final-pass model remains an
optional future extension.
"""
import base64
import http.server
import json
import os
import re
import socketserver
import sys
import tempfile
import threading
import time
import wave
from typing import Optional

HOST = "127.0.0.1"
PORT = int(os.environ.get("VIDDYDICTATE_WHISPER_PORT", "8765"))
IDLE_S = float(os.environ.get("VIDDYDICTATE_WHISPER_IDLE_S", "1800"))
LANG = os.environ.get("VIDDYDICTATE_WHISPER_LANG") or None

# The Whisper repos this daemon will run. Matching this hard-coded list is what stops a stale,
# hand-edited, or hostile `whisper-model` file from steering the daemon at an arbitrary Hub repo.
# Ordered default-first. Medium/Small are deliberately NOT offered yet (part 3 may add them).
OFFERED_MODELS = (
    "mlx-community/whisper-large-v3-turbo",
    "mlx-community/whisper-large-v3-mlx",
    "mlx-community/whisper-large-v2-mlx",
    "mlx-community/whisper-large-mlx",
)
DEFAULT_MODEL = OFFERED_MODELS[0]
_MODEL_CHOICE_NAME = "whisper-model"
_MODEL_REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")


def _model_choice_file() -> Optional[str]:
    """<Application Support>/ViddyDictate/whisper-model, which is the directory this daemon is
    installed into. None when loaded from a string (a test harness), matching _app_model_cache_dirs."""
    here = globals().get("__file__")
    if not isinstance(here, str) or not os.path.isabs(here):
        return None
    return os.path.join(os.path.dirname(here), _MODEL_CHOICE_NAME)


def _choose_model(environ=None, choice_path=None) -> str:
    """The model repo to run, decided once at start.

    Precedence is the contract: an explicit VIDDYDICTATE_WHISPER_MODEL always wins, unchanged (it
    may name a local directory, so it is not validated here). Otherwise the app's one-line
    `whisper-model` file is used only when its first line is a syntactically valid repo id AND one
    of the offered repos. Anything else falls back to the default turbo repo, so a stale, malformed,
    or unvetted file never points the daemon at an arbitrary model. PURE: only the mapping and the
    file path it is given are read; imports nothing and touches no network."""
    env = os.environ if environ is None else environ
    # Key PRESENCE, not truthiness: the base daemon is `os.environ.get(key, default)`, so an
    # explicitly present value wins even when it is the empty string, and the choice file is then
    # ignored. `if env_model:` would let an empty value fall through to the file and change that.
    if "VIDDYDICTATE_WHISPER_MODEL" in env:
        return env["VIDDYDICTATE_WHISPER_MODEL"]
    path = _model_choice_file() if choice_path is None else choice_path
    if path:
        try:
            with open(path, "r", encoding="utf-8") as f:
                line = f.readline()
        except OSError:
            line = ""
        # Remove ONLY the line ending (a trailing \r\n, \n, or \r); spaces and tabs are content and
        # must make the first line fail the exact repo-id pattern, so a space-padded offered repo
        # falls back to the default. `.strip()` would wrongly accept it.
        if line.endswith("\r\n"):
            line = line[:-2]
        elif line.endswith("\n") or line.endswith("\r"):
            line = line[:-1]
        if _MODEL_REPO_RE.match(line) and line in OFFERED_MODELS:
            return line
    return DEFAULT_MODEL


MODEL = _choose_model()


def _envbool(name: str, default: bool) -> bool:
    v = os.environ.get(name)
    return default if v is None else v.strip().lower() in ("1", "true", "yes", "on")


# Anti-hallucination knobs. The defaults are the HEADER-LESS behavior: a caller that sends no
# headers keeps the untuned behavior (condition_on_previous_text on, no cleanup). The ViddyDictate
# hotkey app opts INTO the hardening per request via X-Condition-Previous-Text / X-Clean, so tuning
# the dictation path never silently changes transcription for any other caller of this daemon. To
# harden every caller globally, set VIDDYDICTATE_WHISPER_CONDITION_PREV=0 and
# VIDDYDICTATE_WHISPER_CLEAN=1.
COND_PREV = _envbool("VIDDYDICTATE_WHISPER_CONDITION_PREV", True)    # default preserves untuned behavior
CLEAN = _envbool("VIDDYDICTATE_WHISPER_CLEAN", False)               # default off for header-less callers
NOSPEECH_THOLD = float(os.environ.get("VIDDYDICTATE_WHISPER_NOSPEECH_THOLD", "0.6"))
LOGPROB_THOLD = float(os.environ.get("VIDDYDICTATE_WHISPER_LOGPROB_THOLD", "-1.0"))
COMPRESSION_THOLD = float(os.environ.get("VIDDYDICTATE_WHISPER_COMPRESSION_THOLD", "2.4"))
MAX_REPEATS = int(os.environ.get("VIDDYDICTATE_WHISPER_MAX_REPEATS", "3"))
# Drop the whole transcript only if it is exactly one of these known silence-hallucination phrases
# AND the clip's no_speech_prob is high — so a genuine, confidently-spoken "thank you" survives.
# Raise VIDDYDICTATE_WHISPER_BLOCKLIST_NOSPEECH above 1.0 to disable this gate entirely.
BLOCKLIST_NOSPEECH = float(os.environ.get("VIDDYDICTATE_WHISPER_BLOCKLIST_NOSPEECH", "0.5"))
_HALLUCINATION_WHOLE = {
    "thank you", "thank you very much", "thanks for watching", "thank you for watching",
    "please subscribe", "subscribe to my channel", "you", "so", "bye", "uh", "um", "mm",
    "gracias", "gracias por ver", "gracias por ver el video", "suscríbete",
}

_ready = threading.Event()          # set once the model is warm
_load_error = [None]                # holds the load exception if warmup failed
_tx_lock = threading.Lock()         # serialize transcribes (one resident MLX model)
_last_activity = [time.monotonic()] # transcribe activity only — health polls don't count
# What mlx_whisper is handed as path_or_hf_repo. The warm replaces the repo id with the local snapshot
# directory it loaded from, and every transcribe passes the SAME string: mlx_whisper's ModelHolder
# caches by that string, so a different one would load the 1.5 GB model a second time.
_model_source = [MODEL]

# Warm-up phase, reported by /health so the app can say what a slow start is doing instead of
# silently retrying. Exactly one of these names at a time; `phase_detail` qualifies it (today only
# "waiting for the network" while a first-install download cannot reach the Hub).
PHASES = ("starting", "resolving", "downloading", "loading", "ready", "error")
_phase_lock = threading.Lock()
_phase = {"name": "starting", "since": time.monotonic(), "detail": None}

# First-install download bounds (only reached when the model is not on disk). huggingface_hub reads
# HF_HUB_ETAG_TIMEOUT (per-file metadata request) and HF_HUB_DOWNLOAD_TIMEOUT (stalled file transfer)
# when it is imported; a user's own values win. Its repo_info call honours neither and has no timeout
# at all, which is why _download_snapshot probes reachability itself with an explicit timeout first.
HF_ETAG_TIMEOUT_S = "15"
HF_DOWNLOAD_TIMEOUT_S = "60"
NETWORK_PROBE_TIMEOUT_S = 10.0
NETWORK_RETRY_S = (2.0, 5.0, 10.0, 20.0, 30.0)
_sleep = time.sleep                 # injectable so the gate never really waits

# mlx_whisper.load_models.load_model (mlx-whisper 0.4.3) reads config.json and then
# weights.safetensors, falling back to weights.npz. A snapshot without both is not loadable.
SNAPSHOT_CONFIG = "config.json"
SNAPSHOT_WEIGHTS = ("weights.safetensors", "weights.npz")


def _log(msg: str) -> None:
    print(f"[viddydictate-whisperd] {msg}", flush=True)


def _set_phase(name: str, detail: Optional[str] = None) -> None:
    """Move to `name`, logging how long the previous phase lasted. A detail-only change (same phase)
    is logged too, without resetting the phase clock."""
    if name not in PHASES:
        raise ValueError(f"unknown phase {name!r}")
    now = time.monotonic()
    with _phase_lock:
        prev, since, prev_detail = _phase["name"], _phase["since"], _phase["detail"]
        if prev == name:
            _phase["detail"] = detail
        else:
            _phase.update(name=name, since=now, detail=detail)
    if prev != name:
        _log(f"warm: phase {prev} -> {name} after {now - since:.2f}s in {prev}"
             + (f" ({detail})" if detail else ""))
    elif detail != prev_detail:
        _log(f"warm: {name}: {detail or 'resumed'}")


def _phase_snapshot() -> tuple[str, float, Optional[str]]:
    with _phase_lock:
        return _phase["name"], time.monotonic() - _phase["since"], _phase["detail"]


def _health_payload() -> dict:
    """The /health body. The first four keys are the contract every existing caller reads and stay
    exactly as they were; the phase keys are additive."""
    idle = time.monotonic() - _last_activity[0]
    name, elapsed, detail = _phase_snapshot()
    return {
        "ready": _ready.is_set() and _load_error[0] is None,
        "model": MODEL,
        "idle_s": round(idle, 1),
        "error": _load_error[0],
        "phase": name,
        "phase_s": round(elapsed, 1),
        "phase_detail": detail,
    }


def _hf_hub_cache_dir(environ=None) -> str:
    """The Hugging Face hub cache directory, by huggingface_hub's own precedence (checked against
    huggingface_hub 1.25.1 constants.py): HF_HUB_CACHE, then the legacy HUGGINGFACE_HUB_CACHE, then
    $HF_HOME/hub, where HF_HOME defaults to $XDG_CACHE_HOME/huggingface, then ~/.cache/huggingface.
    Pure: reads only the mapping it is given (os.environ by default) and imports nothing."""
    env = os.environ if environ is None else environ
    default_home = os.path.join(os.path.expanduser("~"), ".cache")
    hf_home = os.path.expandvars(os.path.expanduser(
        env.get("HF_HOME", os.path.join(env.get("XDG_CACHE_HOME", default_home), "huggingface"))))
    legacy = env.get("HUGGINGFACE_HUB_CACHE", os.path.join(hf_home, "hub"))
    return os.path.expandvars(os.path.expanduser(env.get("HF_HUB_CACHE", legacy)))


def _app_model_cache_dirs() -> list:
    """The app's own first-run installer downloads the model with cache_dir=<Application
    Support>/ViddyDictate/model-cache, which is also the directory this script is installed into. A
    DMG install therefore has its model there and not in the default hub cache."""
    here = globals().get("__file__")
    if not isinstance(here, str) or not os.path.isabs(here):
        return []                   # loaded from a string (a test harness): no install directory
    root = os.path.join(os.path.dirname(here), "model-cache")
    return [root, os.path.join(root, "hub")]


def _snapshot_is_complete(snapshot: str) -> bool:
    """config.json plus one weights file, each a real non-empty file. Following symlinks matters: hub
    snapshots are symlinks into blobs/, and a dangling one is a download that never finished."""
    def ok(name: str) -> bool:
        p = os.path.join(snapshot, name)
        try:
            return os.path.isfile(p) and os.path.getsize(p) > 0
        except OSError:
            return False
    return ok(SNAPSHOT_CONFIG) and any(ok(w) for w in SNAPSHOT_WEIGHTS)


def _resolve_local_snapshot(repo_id: str, cache_dirs=None, revision: str = "main") -> Optional[str]:
    """The local snapshot directory for `repo_id`, or None when it is missing or incomplete.

    Follows the hub cache layout: <cache>/models--<org>--<name>/refs/<revision> holds a commit hash,
    and <cache>/models--<org>--<name>/snapshots/<hash>/ holds the files. PURE: no mlx, no
    huggingface_hub, no network; only os.path reads, so it is safe to call before deciding whether
    the network may be touched at all."""
    if not repo_id or repo_id.startswith(("/", ".", "~")) or ".." in repo_id.split("/"):
        return None
    folder = "--".join(["models", *repo_id.split("/")])
    for cache in (cache_dirs if cache_dirs is not None else [_hf_hub_cache_dir(), *_app_model_cache_dirs()]):
        repo_dir = os.path.join(cache, folder)
        try:
            with open(os.path.join(repo_dir, "refs", revision), "r", encoding="utf-8") as f:
                commit = f.read().strip()
        except OSError:
            continue
        if not commit or "/" in commit or commit in (".", ".."):
            continue
        snapshot = os.path.join(repo_dir, "snapshots", commit)
        if _snapshot_is_complete(snapshot):
            return snapshot
    return None


def _describe_source(source: str) -> str:
    """A log-safe description of where the model loads from. Never a user path."""
    if source == MODEL and not os.path.isdir(source):
        return f"hub repo {MODEL}"
    if os.path.isdir(source) and os.path.basename(os.path.dirname(source)) == "snapshots":
        where = "the app's model cache" if f"{os.sep}model-cache{os.sep}" in source else "the Hugging Face cache"
        return f"local snapshot {os.path.basename(source)[:12]} of {MODEL} in {where}"
    return "a local model directory (VIDDYDICTATE_WHISPER_MODEL)"


def _download_snapshot(repo_id: str) -> str:
    """First install only: fetch the snapshot, and return its local directory.

    huggingface_hub's snapshot_download asks the Hub for repo info with NO timeout before anything
    else, so a half-up network can hang it indefinitely. Probe reachability first with an explicit
    timeout and keep retrying (reported as "waiting for the network") until the Hub answers; only
    then download. The per-file metadata and transfer timeouts are bounded through the env vars
    huggingface_hub reads at import time, set before it is imported."""
    os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", HF_ETAG_TIMEOUT_S)
    os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", HF_DOWNLOAD_TIMEOUT_S)
    from huggingface_hub import HfApi, snapshot_download
    attempt = 0
    while True:
        t0 = time.monotonic()
        try:
            HfApi().repo_info(repo_id=repo_id, timeout=NETWORK_PROBE_TIMEOUT_S)
            break
        except Exception as e:  # noqa: BLE001 — any failure to reach the Hub is a reason to wait
            wait = NETWORK_RETRY_S[min(attempt, len(NETWORK_RETRY_S) - 1)]
            attempt += 1
            _set_phase("downloading", "waiting for the network")
            _log(f"warm: the Hugging Face Hub did not answer in {time.monotonic() - t0:.1f}s "
                 f"({type(e).__name__}); retrying in {wait:.0f}s")
            _sleep(wait)
    _set_phase("downloading", None)
    _log(f"warm: downloading {repo_id} (first use; about 1.5 GB for the default model)")
    t0 = time.monotonic()
    path = snapshot_download(repo_id=repo_id)
    _log(f"warm: download finished in {time.monotonic() - t0:.1f}s")
    return str(path)


def _prepare_model_source() -> str:
    """Resolve what to load, touching the network only when the model is not on disk."""
    _set_phase("resolving")
    t0 = time.monotonic()
    if os.path.isdir(MODEL):        # VIDDYDICTATE_WHISPER_MODEL may name a local directory already
        os.environ["HF_HUB_OFFLINE"] = "1"
        return MODEL
    local = _resolve_local_snapshot(MODEL)
    if local is not None:
        # Belt and braces: even a stray repo-id call inside mlx_whisper now stays off the network.
        # huggingface_hub reads this when it is IMPORTED, which happens after this point.
        os.environ["HF_HUB_OFFLINE"] = "1"
        _log(f"warm: resolved local snapshot in {time.monotonic() - t0:.2f}s")
        return local
    _log(f"warm: no complete local snapshot of {MODEL} ({time.monotonic() - t0:.2f}s)")
    if os.environ.get("HF_HUB_OFFLINE", "").strip().lower() in ("1", "true", "yes", "on"):
        return MODEL                # the user forbade the network; let the loader report the miss
    _set_phase("downloading")
    downloaded = _download_snapshot(MODEL)
    # Load from the directory on disk either way, so the loader never calls snapshot_download again.
    return _resolve_local_snapshot(MODEL) or downloaded


def _prime_model(source: str) -> None:
    """Load + cache the model through the exact code path a transcribe takes (mlx_whisper.transcribe
    with the default float16 dtype), so mlx_whisper's ModelHolder is primed for `source`."""
    import numpy as np
    import mlx_whisper
    # ~0.5 s of silence — loads + caches the model without needing ffmpeg or a file.
    mlx_whisper.transcribe(np.zeros(8000, dtype=np.float32), path_or_hf_repo=source)


def _warmup() -> None:
    """Load the model once so the first real transcribe is fast, offline-first."""
    try:
        t0 = time.monotonic()
        source = _prepare_model_source()
        _set_phase("loading")
        _log(f"warm: loading from {_describe_source(source)}")
        _prime_model(source)
        _model_source[0] = source
        _log(f"model warm ({MODEL}) in {time.monotonic() - t0:.1f}s")
        _set_phase("ready")
        _ready.set()
    except Exception as e:  # noqa: BLE001 — surface any load failure to /health callers
        _load_error[0] = str(e)
        _set_phase("error")
        _log(f"WARMUP FAILED: {e}")
        _ready.set()  # unblock waiters; /transcribe will report the error


_PUNCT = ".,!?;:\"'“”¿¡()[]…"


def _collapse_repeats(text: str, max_run: int = MAX_REPEATS) -> str:
    """Collapse consecutive repeated word/phrase runs (the classic Whisper loop) to one copy.
    Conservative: a 1-3-word unit collapses at >= max_run repetitions; a >=4-word phrase at >=2.
    With the default max_run=3, a double survives but a triple such as 'no no no' collapses to one
    copy, along with longer Whisper loops and repeated-sentence hallucinations."""
    words = text.split()
    n = len(words)
    if n < 2:
        return text
    keys = [w.lower().strip(_PUNCT) for w in words]
    out = []
    i = 0
    while i < n:
        collapsed = False
        for plen in range(min(8, (n - i) // 2), 0, -1):
            unit = keys[i:i + plen]
            reps = 1
            j = i + plen
            while j + plen <= n and keys[j:j + plen] == unit:
                reps += 1
                j += plen
            threshold = 2 if plen >= 4 else max_run
            if reps >= threshold:
                out.extend(words[i:i + plen])   # keep one copy
                i = j
                collapsed = True
                break
        if not collapsed:
            out.append(words[i])
            i += 1
    return " ".join(out)


def _wav_duration_seconds(audio_path: str) -> Optional[float]:
    """Return the PCM WAV duration that anchors ViddyDictate transcripts to the audio clock."""
    if not audio_path.lower().endswith(".wav"):
        return None
    with wave.open(audio_path, "rb") as wav:
        frame_rate = wav.getframerate()
        if frame_rate <= 0:
            raise ValueError("WAV frame rate must be positive")
        return wav.getnframes() / frame_rate


def _segment_timestamp(segment: dict, key: str) -> Optional[float]:
    value = segment.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def _clean_segments(result: dict, do_clean: bool,
                    audio_duration: Optional[float] = None) -> tuple[str, list[dict]]:
    """Optional confidence/repetition cleanup, plus per-segment diagnostics.

    `audio_duration` is carried for DIAGNOSTICS ONLY and is deliberately not used to drop or clamp
    anything. An earlier revision gated on `start >= audio_duration - 0.5`, anchoring to the end of
    the FILE. That was reverted on 2026-08-14 (the user's call) because the file clock is not the speech
    clock: `trimTrailingNearSilence` keeps a pad of at most 0.5s after the last above-floor window,
    so the two 0.5s constants only cancel when a full pad exists. On a take that ends promptly after
    the last word the pad is short, nothing is trimmed, and the cutoff falls INSIDE real speech - the
    live corpus verification demonstrated a real final phrase being dropped that way. It also only fixed 1 of the
    4 known-bad corpus takes, because the fabricated tail can sit far from the file end (187s out on
    one).

    The right anchor is the end of SPEECH, and the daemon has no non-circular speech-end signal
    today. That remains future work. The diagnostics below are kept because that work will need
    them: every raw segment, its start/end, and why it was dropped.
    """
    segs = result.get("segments") or []
    if not segs:
        text = (result.get("text") or "").strip()
        return (_collapse_repeats(text) if do_clean else text), []

    survivors = []
    diagnostics = []
    for raw_segment in segs:
        segment = dict(raw_segment)
        start = _segment_timestamp(segment, "start")
        end = _segment_timestamp(segment, "end")
        record = {
            "start": start,
            "end": end,
            "effective_end": end,
            "text": segment.get("text") or "",
            "kept": True,
            "drop_reason": None,
            "raw_text": segment.get("text") or "",
            "no_speech_prob": segment.get("no_speech_prob"),
            "avg_logprob": segment.get("avg_logprob"),
            "compression_ratio": segment.get("compression_ratio"),
        }
        diagnostics.append(record)

        survivors.append((segment, record))

    nonempty = []
    for segment, record in survivors:
        if not (segment.get("text") or "").strip():
            record["kept"] = False
            record["drop_reason"] = "empty"
            continue
        nonempty.append((segment, record))

    if not do_clean:
        text = re.sub(r"\s+", " ", " ".join(
            (segment.get("text") or "").strip() for segment, _record in nonempty)).strip()
        return text, diagnostics

    single = len(nonempty) == 1
    kept = []
    max_nsp = 0.0
    for s, record in nonempty:
        st = (s.get("text") or "")
        nsp = s.get("no_speech_prob") or 0.0
        alp = s.get("avg_logprob") or 0.0
        cr = s.get("compression_ratio") or 0.0
        max_nsp = max(max_nsp, nsp)
        if not single and nsp > NOSPEECH_THOLD and alp < LOGPROB_THOLD:
            record["kept"] = False
            record["drop_reason"] = "non_speech"
            _log(f"drop non-speech seg nsp={nsp:.2f} alp={alp:.2f}: {st.strip()[:48]!r}")
            continue
        if cr > COMPRESSION_THOLD:
            st = _collapse_repeats(st, max_run=2)
        kept.append(st.strip())
    text = re.sub(r"\s+", " ", _collapse_repeats(" ".join(kept))).strip()
    # Whole-output silence-hallucination gate (e.g. a tap with no speech -> "Thank you.").
    if text and max_nsp > BLOCKLIST_NOSPEECH and text.lower().strip(_PUNCT + " ") in _HALLUCINATION_WHOLE:
        _log(f"drop whole-output hallucination nsp={max_nsp:.2f}: {text[:48]!r}")
        return "", diagnostics
    return text, diagnostics


SAMPLE_RATE = 16000


def _load_wav(audio_path: str):
    """Decode a WAV to the float32 mono 16 kHz array Whisper wants, WITHOUT ffmpeg.

    mlx_whisper.transcribe() shells out to `ffmpeg` when handed a path (audio.py: `if isinstance(
    audio, str): audio = load_audio(audio)`), and only when handed a path. ffmpeg is not something
    macOS ships and not something this app installs, so for a long time a user without Homebrew got a
    daemon that started, answered /health, warmed a 1.5 GB model, and failed every single transcribe.
    Handing over an array skips that branch entirely.

    The app now sends 16 kHz (AudioRecorder.resampleForModel), so the normal path here is an exact
    int16 -> float32 conversion with no filtering and nothing to approximate. Measured against
    ffmpeg's own decode of the same files: max|diff| = 0.0 across the whole regression corpus.

    The resampling branch is for clips this daemon did not receive fresh from a current app: takes
    retained by an older build at the device's native rate, and the regression corpus itself. It is
    NOT the normal path, and it is the only place where a filter choice can make our output differ
    from ffmpeg's.
    """
    import numpy as np

    with wave.open(audio_path, "rb") as w:
        rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        frames = w.readframes(w.getnframes())

    if width != 2:
        raise ValueError(f"expected 16-bit PCM WAV, got {width * 8}-bit")

    audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    if rate != SAMPLE_RATE:
        from math import gcd
        from scipy.signal import resample_poly
        g = gcd(int(rate), SAMPLE_RATE)
        audio = resample_poly(audio, SAMPLE_RATE // g, int(rate) // g).astype(np.float32)
        _log(f"decoded {audio_path} at {rate} Hz — resampled (an older or foreign clip)")
    return np.ascontiguousarray(audio, dtype=np.float32)


def _transcribe(audio_path: str, cond_prev=None, clean=None,
                initial_prompt=None) -> tuple[str, str, list[dict], Optional[float]]:
    import mlx_whisper
    audio_duration = _wav_duration_seconds(audio_path)
    kwargs = {
        "path_or_hf_repo": _model_source[0],   # the string the warm primed; see _model_source
        "condition_on_previous_text": COND_PREV if cond_prev is None else cond_prev,
        "no_speech_threshold": NOSPEECH_THOLD,
        "logprob_threshold": LOGPROB_THOLD,
        "compression_ratio_threshold": COMPRESSION_THOLD,
    }
    if LANG:
        kwargs["language"] = LANG
    # Per-request vocabulary bias (ViddyDictate correction dictionary). Header-less callers pass None
    # and decode exactly as before.
    if initial_prompt:
        kwargs["initial_prompt"] = initial_prompt
    # An ARRAY, never the path: a path sends mlx_whisper to ffmpeg. See _load_wav.
    audio = _load_wav(audio_path)
    with _tx_lock:
        result = mlx_whisper.transcribe(audio, **kwargs)
    raw = (result.get("text") or "").strip()
    text, segments = _clean_segments(
        result, CLEAN if clean is None else clean, audio_duration=audio_duration)
    return raw, text, segments, audio_duration


def _idle_watchdog() -> None:
    """Self-exit after IDLE_S with no transcribe activity (the user may forget to stop the engine)."""
    while True:
        time.sleep(30)
        idle = time.monotonic() - _last_activity[0]
        if idle >= IDLE_S:
            _log(f"idle {idle:.0f}s >= {IDLE_S:.0f}s — shutting down")
            os._exit(0)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:  # silence default per-request stderr logging
        pass

    def do_GET(self) -> None:
        if self.path.startswith("/health"):
            self._send(200, _health_payload())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path.startswith("/shutdown"):
            self._send(200, {"ok": True})
            _log("shutdown requested")
            threading.Thread(target=lambda: (time.sleep(0.1), os._exit(0)), daemon=True).start()
            return
        if not self.path.startswith("/transcribe"):
            self._send(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length) if length else b""
        if not data:
            self._send(400, {"error": "empty audio"})
            return
        if not _ready.is_set():
            self._send(503, {"error": "model loading"})
            return
        if _load_error[0] is not None:
            self._send(500, {"error": f"model load failed: {_load_error[0]}"})
            return

        def _hdr_bool(name):
            v = self.headers.get(name)
            return None if v is None else v.strip().lower() in ("1", "true", "yes", "on")
        cond_prev = _hdr_bool("X-Condition-Previous-Text")
        clean = _hdr_bool("X-Clean")

        initial_prompt = None
        b64 = self.headers.get("X-Initial-Prompt-B64")
        if b64:
            try:
                decoded = base64.b64decode(b64).decode("utf-8").strip()
                initial_prompt = decoded or None
            except Exception as e:  # noqa: BLE001 — a bad header must never fail the transcribe
                _log(f"ignoring bad X-Initial-Prompt-B64: {e}")

        fmt = "".join(c for c in (self.headers.get("X-Audio-Format") or "webm") if c.isalnum()) or "webm"
        tmp = os.path.join(tempfile.gettempdir(), f"viddydictate-whisperd-{os.getpid()}-{time.monotonic_ns()}.{fmt}")
        try:
            with open(tmp, "wb") as f:
                f.write(data)
            raw_text, text, segments, audio_duration = _transcribe(
                tmp, cond_prev=cond_prev, clean=clean, initial_prompt=initial_prompt)
            _last_activity[0] = time.monotonic()
            # Additive diagnostics only: `transcript` remains the same model-bound behavior every caller
            # already consumes. ViddyDictate logs the raw model text beside this post-processed result and
            # the exact effective parameters; older callers ignore the extra JSON keys.
            self._send(200, {
                "transcript": text,
                "raw_transcript": raw_text,
                "segments": segments,
                "model": MODEL,
                "parameters": {
                    "condition_on_previous_text": COND_PREV if cond_prev is None else cond_prev,
                    "clean": CLEAN if clean is None else clean,
                    "no_speech_threshold": NOSPEECH_THOLD,
                    "logprob_threshold": LOGPROB_THOLD,
                    "compression_ratio_threshold": COMPRESSION_THOLD,
                    "language": LANG or "auto",
                    "initial_prompt_chars": len(initial_prompt or ""),
                    "audio_duration_s": round(audio_duration, 3) if audio_duration is not None else None,
                },
            })
        except Exception as e:  # noqa: BLE001
            _log(f"transcribe failed: {e}")
            self._send(500, {"error": str(e)})
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    threading.Thread(target=_warmup, daemon=True).start()
    threading.Thread(target=_idle_watchdog, daemon=True).start()
    try:
        httpd = Server((HOST, PORT), Handler)
    except OSError as e:
        _log(f"bind {HOST}:{PORT} failed: {e}")
        return 1
    _log(f"listening on {HOST}:{PORT} (model={MODEL}, idle={IDLE_S:.0f}s)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
