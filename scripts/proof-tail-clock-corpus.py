#!/usr/bin/env python3
"""Compare current and candidate tail-cleaning behavior on both frozen corpora.

The client decodes each WAV once by default, then gives independent deep copies of
that raw result to the current and candidate `_clean_segments` functions. A second
decoder URL may be supplied for a mechanism that changes decoding itself, including
the word-timestamp rung. The assertions stay the same either way.

The GPU decoder can run outside a restricted shell as an isolated loopback daemon:

    python scripts/proof-tail-clock-corpus.py --serve 8798

Then run the comparison client with the ViddyDictate Python environment:

    python scripts/proof-tail-clock-corpus.py \
        --decode-url http://127.0.0.1:8798 \
        --current git:c94df5d \
        --candidate file:viddydictate_whisperd.py

No assertion keys on decoded words. Corpus A is judged by segment timestamps relative
to its measured speech-end fixtures. Corpus B is judged by exact preservation of the
last kept segment's text, start, and end.
"""

from __future__ import annotations

import argparse
import base64
import copy
import datetime as dt
import hashlib
import http.server
import importlib.util
import inspect
import json
import math
import os
import pathlib
import re
import socketserver
import subprocess
import sys
import tempfile
import threading
import types
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import Any, Callable, Optional


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CORPUS_A = pathlib.Path.home() / (
    ".local/share/viddydictate/regression-corpus/tail-hallucination-20260813"
)
DEFAULT_CORPUS_B = pathlib.Path.home() / (
    ".local/share/viddydictate/regression-corpus/promptstop-safety-20260814"
)
DEFAULT_DICTIONARY = pathlib.Path.home() / "Library/Application Support/ViddyDictate/dictionary.json"
DEFAULT_CURRENT = "git:c94df5d"
DEFAULT_CANDIDATE = "file:viddydictate_whisperd.py"
SPEECH_END_EPSILON_S = 0.01

CORPUS_A_CASES = [
    {"file": "thankyou-A-30.4s.wav", "finding": "finding2", "speech_ends_s": 29.98},
    {"file": "expletive-A-31.6s.wav", "finding": "finding2", "speech_ends_s": 29.20},
    {"file": "thankyou-B-74.3s.wav", "finding": "finding2", "speech_ends_s": 71.94},
    {"file": "loop-204.1s.wav", "finding": "finding4", "speech_ends_s": 16.84},
]


def load_module(name: str, source: str) -> types.ModuleType:
    spec = importlib.util.spec_from_loader(name, loader=None)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    module.__file__ = f"<{name}>"
    exec(compile(source, f"<{name}>", "exec"), module.__dict__)  # noqa: S102
    return module


def source_for(spec: str) -> str:
    if spec.startswith("git:"):
        revision = spec.removeprefix("git:")
        if not revision:
            raise ValueError("git source needs a revision")
        matches = subprocess.run(
            ["git", "-C", str(ROOT), "grep", "-l", "^def _clean_segments", revision, "--", "*.py"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        paths = [match.split(":", 1)[1] for match in matches if ":" in match]
        if len(paths) != 1:
            raise ValueError(
                f"git source {revision!r} has {len(paths)} daemon candidates; expected exactly one"
            )
        return subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{revision}:{paths[0]}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    if spec.startswith("file:"):
        path = pathlib.Path(spec.removeprefix("file:"))
        if not path.is_absolute():
            path = ROOT / path
        return path.read_text(encoding="utf-8")
    raise ValueError(f"source must begin with git: or file:, got {spec!r}")


def cleaner_for(name: str, spec: str) -> Callable[..., Any]:
    module = load_module(name, source_for(spec))
    cleaner = getattr(module, "_clean_segments", None)
    if not callable(cleaner):
        raise ValueError(f"{spec} has no callable _clean_segments")
    return cleaner


def whisper_bias(dictionary_path: pathlib.Path, max_words: int = 200) -> str:
    """Mirror CorrectionDictionary.whisperBias without exposing dictionary contents."""
    store = json.loads(dictionary_path.read_text(encoding="utf-8"))
    seen: set[str] = set()
    terms: list[str] = []
    for entry in (store.get("hardCoded") or []) + (store.get("contextAware") or []):
        heard = (entry.get("heard") or "").strip()
        term = (entry.get("intended") or "").strip()
        if not heard or not term or term.lower() in seen:
            continue
        seen.add(term.lower())
        terms.append(term)
    if not terms:
        return ""
    while len(terms) > 1 and sum(len(term.split(" ")) for term in terms) > max_words:
        terms.pop(0)
    return "Vocabulary: " + ", ".join(terms) + "."


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def expected_checksums(corpus: pathlib.Path) -> dict[str, str]:
    sums_path = corpus / "SHA256SUMS.txt"
    expected: dict[str, str] = {}
    for line in sums_path.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?(.+)", line.strip())
        if not match:
            raise ValueError(f"invalid checksum line in {sums_path}: {line!r}")
        expected[match.group(2)] = match.group(1).lower()
    return expected


def verify_checksums(corpus: pathlib.Path) -> dict[str, Any]:
    expected = expected_checksums(corpus)
    files = []
    for name, wanted in expected.items():
        path = corpus / name
        actual = sha256_file(path) if path.is_file() else None
        files.append({"file": name, "expected": wanted, "actual": actual, "ok": actual == wanted})
    return {
        "sha256sums_file": "SHA256SUMS.txt",
        "ok": bool(files) and all(item["ok"] for item in files),
        "verified_files": len(files),
        "files": files,
    }


def json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, Mapping):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    item = getattr(value, "item", None)
    if callable(item):
        return json_safe(item())
    return str(value)


def wav_duration_seconds(path: pathlib.Path) -> float:
    import wave

    with wave.open(str(path), "rb") as wav:
        rate = wav.getframerate()
        if rate <= 0:
            raise ValueError(f"invalid WAV frame rate: {path.name}")
        return wav.getnframes() / rate


def raw_segment_record(segment: dict[str, Any]) -> dict[str, Any]:
    record = {
        "start": json_safe(segment.get("start")),
        "end": json_safe(segment.get("end")),
        "text": segment.get("text") or "",
        "compression_ratio": json_safe(segment.get("compression_ratio")),
        "no_speech_prob": json_safe(segment.get("no_speech_prob")),
        "avg_logprob": json_safe(segment.get("avg_logprob")),
    }
    if isinstance(segment.get("words"), list):
        record["words"] = [
            {
                "word": word.get("word") or "",
                "start": json_safe(word.get("start")),
                "end": json_safe(word.get("end")),
                "probability": json_safe(word.get("probability")),
            }
            for word in segment["words"]
            if isinstance(word, Mapping)
        ]
    return record


def call_cleaner(
    cleaner: Callable[..., Any], result: dict[str, Any], duration: float
) -> tuple[str, list[dict[str, Any]]]:
    parameters = inspect.signature(cleaner).parameters
    if "audio_duration" in parameters:
        cleaned = cleaner(copy.deepcopy(result), True, audio_duration=duration)
    else:
        cleaned = cleaner(copy.deepcopy(result), True)
    if isinstance(cleaned, tuple) and len(cleaned) == 2:
        text, diagnostics = cleaned
    else:
        text, diagnostics = cleaned, []
    if not isinstance(text, str) or not isinstance(diagnostics, list):
        raise TypeError("_clean_segments must return text or (text, diagnostics)")
    return text, json_safe(diagnostics)


def segment_key(segment: dict[str, Any]) -> tuple[Any, Any, Any]:
    return (segment.get("start"), segment.get("end"), segment.get("text") or "")


def kept_segments(diagnostics: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        segment
        for segment in diagnostics
        if segment.get("kept", True) and (segment.get("text") or "").strip()
    ]


def final_kept_segment(diagnostics: list[dict[str, Any]]) -> Optional[dict[str, Any]]:
    kept = kept_segments(diagnostics)
    if not kept:
        return None
    segment = kept[-1]
    return {"start": segment.get("start"), "end": segment.get("end"), "text": segment.get("text") or ""}


def compare_outputs(
    current_text: str,
    current_segments: list[dict[str, Any]],
    candidate_text: str,
    candidate_segments: list[dict[str, Any]],
) -> dict[str, Any]:
    current_keys = [segment_key(item) for item in kept_segments(current_segments)]
    candidate_keys = [segment_key(item) for item in kept_segments(candidate_segments)]
    return {
        "text_changed": current_text != candidate_text,
        "current_kept_segments": len(current_keys),
        "candidate_kept_segments": len(candidate_keys),
        "removed_kept_segments": [list(item) for item in current_keys if item not in candidate_keys],
        "added_kept_segments": [list(item) for item in candidate_keys if item not in current_keys],
        "no_delta": current_text == candidate_text and current_keys == candidate_keys,
    }


def evaluate_a(
    speech_ends_s: float,
    current_text: str,
    current_segments: list[dict[str, Any]],
    candidate_text: str,
    candidate_segments: list[dict[str, Any]],
) -> dict[str, Any]:
    threshold = speech_ends_s - SPEECH_END_EPSILON_S
    current_tail = [
        item for item in kept_segments(current_segments)
        if isinstance(item.get("start"), (int, float)) and item["start"] >= threshold
    ]
    candidate_tail = [
        item for item in kept_segments(candidate_segments)
        if isinstance(item.get("start"), (int, float)) and item["start"] >= threshold
    ]
    return {
        "contract": "no kept segment starts at or after measured speech end",
        "speech_ends_s": speech_ends_s,
        "epsilon_s": SPEECH_END_EPSILON_S,
        "current_post_speech_kept": len(current_tail),
        "candidate_post_speech_kept": len(candidate_tail),
        "candidate_has_surviving_text": bool(candidate_text.strip()),
        "current_pass": bool(current_text.strip()) and not current_tail,
        "candidate_pass": bool(candidate_text.strip()) and not candidate_tail,
    }


def evaluate_b(
    current_text: str,
    current_segments: list[dict[str, Any]],
    candidate_text: str,
    candidate_segments: list[dict[str, Any]],
) -> dict[str, Any]:
    current_final = final_kept_segment(current_segments)
    candidate_final = final_kept_segment(candidate_segments)
    return {
        "contract": "last kept segment text, start, and end are unchanged",
        "current_final_segment": current_final,
        "candidate_final_segment": candidate_final,
        "candidate_pass": current_final is not None and current_final == candidate_final,
        "candidate_has_surviving_text": bool(candidate_text.strip()),
        "whole_text_changed": current_text != candidate_text,
    }


def decode_url(url: str, wav_path: pathlib.Path, prompt: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url.rstrip("/") + "/decode",
        data=wav_path.read_bytes(),
        method="POST",
        headers={
            "Content-Type": "application/octet-stream",
            "X-Audio-Format": "wav",
            "X-Initial-Prompt-B64": base64.b64encode(prompt.encode("utf-8")).decode("ascii"),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            decoded = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"decoder HTTP {error.code}: {body}") from error
    if not isinstance(decoded, dict) or not isinstance(decoded.get("segments"), list):
        raise ValueError(f"decoder returned no segment list for {wav_path.name}")
    return decoded


def load_b_cases(corpus: pathlib.Path) -> list[dict[str, Any]]:
    manifest = json.loads((corpus / "manifest.json").read_text(encoding="utf-8"))
    return [
        {"file": take["file"], "final_word": take.get("final_word")}
        for take in manifest.get("takes", [])
    ]


def corpus_report(
    corpus_id: str,
    corpus_path: pathlib.Path,
    cases: list[dict[str, Any]],
    current_cleaner: Callable[..., Any],
    candidate_cleaner: Callable[..., Any],
    decode_endpoint: str,
    candidate_decode_endpoint: Optional[str],
    prompt: str,
) -> dict[str, Any]:
    before = verify_checksums(corpus_path)
    if not before["ok"]:
        raise RuntimeError(f"{corpus_id} checksum verification failed before decode")

    take_reports = []
    for case in cases:
        name = case["file"]
        wav_path = corpus_path / name
        duration = wav_duration_seconds(wav_path)
        current_raw = decode_url(decode_endpoint, wav_path, prompt)
        candidate_raw = (
            decode_url(candidate_decode_endpoint, wav_path, prompt)
            if candidate_decode_endpoint
            else current_raw
        )
        current_text, current_segments = call_cleaner(current_cleaner, current_raw, duration)
        candidate_text, candidate_segments = call_cleaner(candidate_cleaner, candidate_raw, duration)
        delta = compare_outputs(current_text, current_segments, candidate_text, candidate_segments)
        assertion = (
            evaluate_a(
                case["speech_ends_s"],
                current_text,
                current_segments,
                candidate_text,
                candidate_segments,
            )
            if corpus_id == "A"
            else evaluate_b(current_text, current_segments, candidate_text, candidate_segments)
        )
        record = {
            "file": name,
            "wav_sha256": sha256_file(wav_path),
            "audio_duration_s": round(duration, 6),
            "raw_decode": {
                "text": current_raw.get("text") or "",
                "segments": [raw_segment_record(item) for item in current_raw.get("segments", [])],
            },
            "current_post_clean": {
                "text": current_text,
                "segments": current_segments,
            },
            "candidate_post_clean": {
                "text": candidate_text,
                "segments": candidate_segments,
            },
            "delta": delta,
            "assertion": assertion,
        }
        if candidate_decode_endpoint:
            record["candidate_raw_decode"] = {
                "text": candidate_raw.get("text") or "",
                "segments": [
                    raw_segment_record(item) for item in candidate_raw.get("segments", [])
                ],
            }
        if corpus_id == "A":
            record["finding"] = case["finding"]
            record["speech_ends_s"] = case["speech_ends_s"]
            record["speech_end_source"] = "locked fixture confirmed against raw segment boundary"
        else:
            record["final_word_hint_not_asserted"] = case.get("final_word")
        take_reports.append(record)

        if corpus_id == "A":
            print(
                f"[proof][A] {name}: speech_ends_s={case['speech_ends_s']:.2f} "
                f"current_tail={assertion['current_post_speech_kept']} "
                f"candidate_tail={assertion['candidate_post_speech_kept']} "
                f"candidate={'PASS' if assertion['candidate_pass'] else 'FAIL'}"
            )
        else:
            final = assertion["current_final_segment"]
            print(
                f"[proof][B] {name}: final={json.dumps(final, ensure_ascii=True)} "
                f"candidate={'PASS' if assertion['candidate_pass'] else 'FAIL'}"
            )

    after = verify_checksums(corpus_path)
    if not after["ok"]:
        raise RuntimeError(f"{corpus_id} checksum verification failed after decode")
    return {
        "corpus": corpus_id,
        "integrity_before": before,
        "integrity_after": after,
        "takes": take_reports,
    }


def self_test() -> int:
    raw_a = {
        "text": "real fake",
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "real"},
            {"start": 1.0, "end": 2.0, "text": "fake", "drop_me": True},
        ],
    }
    raw_b = {
        "text": "keep final",
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "keep"},
            {"start": 1.0, "end": 2.0, "text": "final"},
        ],
    }

    def cleaner(result: dict[str, Any], _do_clean: bool, audio_duration: float = 0.0):
        del audio_duration
        diagnostics = [dict(item, kept=True, drop_reason=None) for item in result["segments"]]
        return " ".join(item["text"] for item in diagnostics), diagnostics

    def dropping_candidate(result: dict[str, Any], _do_clean: bool, audio_duration: float = 0.0):
        del audio_duration
        diagnostics = []
        kept = []
        for item in result["segments"]:
            dropped = bool(item.get("drop_me"))
            diagnostics.append(dict(item, kept=not dropped, drop_reason="fixture" if dropped else None))
            if not dropped:
                kept.append(item["text"])
        return " ".join(kept), diagnostics

    def clipping_candidate(result: dict[str, Any], _do_clean: bool, audio_duration: float = 0.0):
        del audio_duration
        diagnostics = [dict(item, kept=True, drop_reason=None) for item in result["segments"][:-1]]
        return result["segments"][0]["text"], diagnostics

    def emptying_candidate(result: dict[str, Any], _do_clean: bool, audio_duration: float = 0.0):
        """The exact shape `_clean_segments` returns when the DECODER erased every segment.

        This is not hypothetical. mlx-whisper 0.4.3's `hallucination_silence_threshold`
        executes `current_segments[si:] = []` at transcribe.py:488, and the loop above it
        starts at si == 0, so a window whose FIRST word-bearing segment scores as anomalous
        loses every segment in that window. Those segments' tokens are dropped before
        `all_tokens` is extended, so `transcribe` returns text="" AND segments=[], and
        `_clean_segments` then falls through its empty-segment branch to ("", []).

        Six of the seven Corpus B takes are a single segment, so for them that is the whole
        dictation, not a trailing word. It did not fire on this corpus only because these
        takes end promptly (`silence_after` needs a >2.0s gap between the segment end and the
        end of audio content, or a segment ending within 2.0s of the 30s window edge). Takes
        with above-floor non-speech after the last word DO clear that bar - Corpus A measures
        2.40s and 2.36s on two takes.

        So: any future rung that turns this vendor feature on must carry its own no-empty
        floor, and this apparatus has to be able to FAIL such a candidate. Pin that here.
        """
        del result, audio_duration
        return "", []

    current_a_text, current_a_segments = call_cleaner(cleaner, raw_a, 2.0)
    safe_a_text, safe_a_segments = call_cleaner(dropping_candidate, raw_a, 2.0)
    a = evaluate_a(1.0, current_a_text, current_a_segments, safe_a_text, safe_a_segments)
    if a["current_pass"] or not a["candidate_pass"]:
        raise AssertionError("Corpus A structural tail assertion did not distinguish the candidate")

    current_b_text, current_b_segments = call_cleaner(cleaner, raw_b, 2.0)
    same_b_text, same_b_segments = call_cleaner(dropping_candidate, raw_b, 2.0)
    clipped_b_text, clipped_b_segments = call_cleaner(clipping_candidate, raw_b, 2.0)
    if not evaluate_b(
        current_b_text, current_b_segments, same_b_text, same_b_segments
    )["candidate_pass"]:
        raise AssertionError("Corpus B rejected an unchanged final segment")
    if evaluate_b(
        current_b_text, current_b_segments, clipped_b_text, clipped_b_segments
    )["candidate_pass"]:
        raise AssertionError("Corpus B accepted a clipped final segment")

    empty_text, empty_segments = call_cleaner(emptying_candidate, raw_b, 2.0)
    if evaluate_b(
        current_b_text, current_b_segments, empty_text, empty_segments
    )["candidate_pass"]:
        raise AssertionError(
            "Corpus B accepted a candidate that returned an EMPTY transcript. A decoder-side "
            "mechanism can erase every segment of a take (see emptying_candidate); this "
            "apparatus must fail that candidate, not pass it."
        )
    if evaluate_a(
        1.0, current_a_text, current_a_segments, empty_text, empty_segments
    )["candidate_pass"]:
        raise AssertionError(
            "Corpus A accepted a candidate that returned an EMPTY transcript. Removing the "
            "fabricated tail by deleting the whole transcript is not a pass."
        )
    if not compare_outputs(
        current_b_text, current_b_segments, current_b_text, current_b_segments
    )["no_delta"]:
        raise AssertionError("identical current and candidate outputs did not report no delta")

    print(
        "[tail-corpus-harness][PASS] A tail removal, B final preservation, empty-transcript "
        "rejection on both corpora, and no-delta checks"
    )
    return 0


class DecodeHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    transcribe_lock = threading.Lock()
    daemon_module: types.ModuleType
    word_timestamps = False
    hallucination_silence_threshold: Optional[float] = None

    def log_message(self, *_args: Any) -> None:
        pass

    def send_json(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(json_safe(payload), allow_nan=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path.startswith("/health"):
            self.send_json(200, {"ready": True, "model": self.daemon_module.MODEL})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path.startswith("/shutdown"):
            self.send_json(200, {"ok": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not self.path.startswith("/decode"):
            self.send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        audio = self.rfile.read(length) if length else b""
        if not audio:
            self.send_json(400, {"error": "empty audio"})
            return
        prompt = ""
        encoded_prompt = self.headers.get("X-Initial-Prompt-B64")
        if encoded_prompt:
            prompt = base64.b64decode(encoded_prompt).decode("utf-8").strip()
        fmt = "".join(
            char for char in (self.headers.get("X-Audio-Format") or "wav") if char.isalnum()
        ) or "wav"
        tmp_path = ""
        try:
            with tempfile.NamedTemporaryFile(suffix=f".{fmt}", delete=False) as handle:
                handle.write(audio)
                tmp_path = handle.name
            import mlx_whisper

            kwargs = {
                "path_or_hf_repo": self.daemon_module.MODEL,
                "condition_on_previous_text": False,
                "no_speech_threshold": self.daemon_module.NOSPEECH_THOLD,
                "logprob_threshold": self.daemon_module.LOGPROB_THOLD,
                "compression_ratio_threshold": self.daemon_module.COMPRESSION_THOLD,
                "word_timestamps": self.word_timestamps,
            }
            if self.hallucination_silence_threshold is not None:
                kwargs["hallucination_silence_threshold"] = (
                    self.hallucination_silence_threshold
                )
            if self.daemon_module.LANG:
                kwargs["language"] = self.daemon_module.LANG
            if prompt:
                kwargs["initial_prompt"] = prompt
            with self.transcribe_lock:
                result = mlx_whisper.transcribe(tmp_path, **kwargs)
            self.send_json(200, result)
        except Exception as error:  # noqa: BLE001
            self.send_json(500, {"error": str(error)})
        finally:
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass


class DecodeServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(port: int) -> int:
    if port == 8765:
        raise ValueError("port 8765 is reserved for the live ViddyDictate daemon")
    DecodeHandler.daemon_module = load_module(
        "decode_daemon", (ROOT / "viddydictate_whisperd.py").read_text(encoding="utf-8")
    )
    DecodeHandler.word_timestamps = os.environ.get(
        "VDTH_DECODER_WORD_TIMESTAMPS", "0"
    ).strip().lower() in ("1", "true", "yes", "on")
    threshold = os.environ.get("VDTH_DECODER_HALLUCINATION_SILENCE_THRESHOLD")
    DecodeHandler.hallucination_silence_threshold = (
        float(threshold) if threshold not in (None, "") else None
    )
    if DecodeHandler.hallucination_silence_threshold is not None:
        if not DecodeHandler.word_timestamps:
            raise ValueError("hallucination silence threshold requires word timestamps")
        if DecodeHandler.hallucination_silence_threshold < 0:
            raise ValueError("hallucination silence threshold must be nonnegative")
    server = DecodeServer(("127.0.0.1", port), DecodeHandler)
    print(
        f"[tail-corpus-decoder] listening on 127.0.0.1:{port} "
        f"model={DecodeHandler.daemon_module.MODEL} "
        f"word_timestamps={DecodeHandler.word_timestamps} "
        f"hallucination_silence_threshold="
        f"{DecodeHandler.hallucination_silence_threshold}",
        flush=True,
    )
    server.serve_forever()
    print("[tail-corpus-decoder] stopped", flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--serve", type=int, metavar="PORT")
    parser.add_argument("--corpus-a", type=pathlib.Path, default=DEFAULT_CORPUS_A)
    parser.add_argument("--corpus-b", type=pathlib.Path, default=DEFAULT_CORPUS_B)
    parser.add_argument("--dictionary", type=pathlib.Path, default=DEFAULT_DICTIONARY)
    parser.add_argument("--current", default=DEFAULT_CURRENT, help="git:REV or file:PATH")
    parser.add_argument("--candidate", default=DEFAULT_CANDIDATE, help="git:REV or file:PATH")
    parser.add_argument("--decode-url", default="http://127.0.0.1:8798")
    parser.add_argument(
        "--candidate-decode-url",
        default=None,
        help="optional decoder for a mechanism that changes raw decoding; default reuses one decode",
    )
    parser.add_argument("--initial-prompt-b64", default=None)
    parser.add_argument("--json-out", type=pathlib.Path, default=None)
    parser.add_argument(
        "--expect-no-delta",
        action="store_true",
        help="baseline mode: require current and candidate outputs to be identical",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.serve is not None:
        return serve(args.serve)
    if not args.corpus_a.is_dir() or not args.corpus_b.is_dir():
        print("[proof][FAIL] both corpus directories are required")
        return 1

    prompt = (
        base64.b64decode(args.initial_prompt_b64).decode("utf-8").strip()
        if args.initial_prompt_b64
        else whisper_bias(args.dictionary)
    )
    if not prompt:
        print("[proof][FAIL] empty initial_prompt; the regression corpus requires the bias")
        return 1

    current_cleaner = cleaner_for("current_cleaner", args.current)
    candidate_cleaner = cleaner_for("candidate_cleaner", args.candidate)
    print(f"[proof] current={args.current}")
    print(f"[proof] candidate={args.candidate}")
    print(f"[proof] decode_url={args.decode_url}")
    print(f"[proof] candidate_decode_url={args.candidate_decode_url or 'shared single decode'}")
    print(f"[proof] initial_prompt_chars={len(prompt)} enabled")

    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    report = {
        "schema_version": 1,
        "generated_at": generated_at,
        "baseline_revision": "c94df5d",
        "current_source": args.current,
        "candidate_source": args.candidate,
        "decoder": {
            "current_url": args.decode_url,
            "candidate_url": args.candidate_decode_url or args.decode_url,
            "single_decode_shared": args.candidate_decode_url is None,
            "condition_on_previous_text": False,
            "clean_requested": True,
            "initial_prompt_enabled": True,
            "initial_prompt_chars": len(prompt),
            "initial_prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
        },
        "corpora": [],
    }
    corpus_a = corpus_report(
        "A",
        args.corpus_a,
        CORPUS_A_CASES,
        current_cleaner,
        candidate_cleaner,
        args.decode_url,
        args.candidate_decode_url,
        prompt,
    )
    corpus_b = corpus_report(
        "B",
        args.corpus_b,
        load_b_cases(args.corpus_b),
        current_cleaner,
        candidate_cleaner,
        args.decode_url,
        args.candidate_decode_url,
        prompt,
    )
    report["corpora"] = [corpus_a, corpus_b]

    a_takes = corpus_a["takes"]
    b_takes = corpus_b["takes"]
    a_current_passes = sum(item["assertion"]["current_pass"] for item in a_takes)
    a_candidate_passes = sum(item["assertion"]["candidate_pass"] for item in a_takes)
    b_candidate_passes = sum(item["assertion"]["candidate_pass"] for item in b_takes)
    no_delta = all(item["delta"]["no_delta"] for item in a_takes + b_takes)
    report["summary"] = {
        "corpus_a_current_passes": a_current_passes,
        "corpus_a_current_total": len(a_takes),
        "corpus_a_candidate_passes": a_candidate_passes,
        "corpus_a_candidate_total": len(a_takes),
        "corpus_b_candidate_passes": b_candidate_passes,
        "corpus_b_candidate_total": len(b_takes),
        "no_delta": no_delta,
        "candidate_contract_pass": (
            a_candidate_passes == len(a_takes) and b_candidate_passes == len(b_takes)
        ),
    }

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps(json_safe(report), indent=2, ensure_ascii=True, allow_nan=False) + "\n",
            encoding="ascii",
        )
        print(f"[proof] wrote {args.json_out}")

    print(f"[proof] Corpus A current: {a_current_passes}/{len(a_takes)}")
    print(f"[proof] Corpus A candidate: {a_candidate_passes}/{len(a_takes)}")
    print(f"[proof] Corpus B candidate final-segment preservation: {b_candidate_passes}/{len(b_takes)}")
    print(f"[proof] no_delta={no_delta}")

    if args.expect_no_delta:
        if not no_delta:
            print("[proof][FAIL] expected identical current and candidate outputs")
            return 1
        print("[proof][PASS] baseline no-delta comparison completed on both corpora")
        return 0
    if report["summary"]["candidate_contract_pass"]:
        print("[proof][PASS] candidate clears both corpus contracts")
        return 0
    print("[proof][FAIL] candidate does not clear both corpus contracts")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
