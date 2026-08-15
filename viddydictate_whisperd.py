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
  GET  /health      -> {"ready": bool, "model": str, "idle_s": float}
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
MODEL = os.environ.get("VIDDYDICTATE_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
IDLE_S = float(os.environ.get("VIDDYDICTATE_WHISPER_IDLE_S", "1800"))
LANG = os.environ.get("VIDDYDICTATE_WHISPER_LANG") or None


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


def _log(msg: str) -> None:
    print(f"[viddydictate-whisperd] {msg}", flush=True)


def _warmup() -> None:
    """Load the model once so the first real transcribe is fast. Uses the exact code path
    (mlx_whisper.transcribe with the default float16 dtype) so the ModelHolder cache is primed."""
    try:
        import numpy as np
        import mlx_whisper
        t0 = time.monotonic()
        # ~0.5 s of silence — loads + caches the model without needing ffmpeg or a file.
        mlx_whisper.transcribe(np.zeros(8000, dtype=np.float32), path_or_hf_repo=MODEL)
        _log(f"model warm ({MODEL}) in {time.monotonic() - t0:.1f}s")
        _ready.set()
    except Exception as e:  # noqa: BLE001 — surface any load failure to /health callers
        _load_error[0] = str(e)
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


def _transcribe(audio_path: str, cond_prev=None, clean=None,
                initial_prompt=None) -> tuple[str, str, list[dict], Optional[float]]:
    import mlx_whisper
    audio_duration = _wav_duration_seconds(audio_path)
    kwargs = {
        "path_or_hf_repo": MODEL,
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
    with _tx_lock:
        result = mlx_whisper.transcribe(audio_path, **kwargs)
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
            idle = time.monotonic() - _last_activity[0]
            self._send(200, {
                "ready": _ready.is_set() and _load_error[0] is None,
                "model": MODEL,
                "idle_s": round(idle, 1),
                "error": _load_error[0],
            })
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
