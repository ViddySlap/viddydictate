#!/usr/bin/env python3
"""Pins the daemon's JSON-safe encoding, the fix for Ben's endless spinner after a long take.

The daemon answers every error path with valid JSON, but a SUCCESS body is not always valid JSON:
`_clean_segments` copies `no_speech_prob`/`avg_logprob`/`compression_ratio` straight from the model
into `segments`, and `json.dumps(obj)`'s default `allow_nan=True` writes `NaN`, `Infinity` or
`-Infinity` for a non-finite value. Those tokens are not JSON, and Apple's `JSONSerialization`
rejects the whole body, which the app logs as `bad response`. A 30.5 s take on 2026-10-09 hit exactly
this and the retained-take recovery retried an unreadable clip forever.

The fix is defence in depth at the daemon end: `_json_safe` recursively replaces every non-finite
float with `None`, and `Handler._send` encodes through `_encode_json`, which also passes
`allow_nan=False` so a non-finite value can never slip onto the wire silently.

This file loads the daemon by path (as `scripts/test-whisper-tail-clock.py` does) and never starts a
server, reads a recording, or touches the user's daemon.
"""

import importlib.util
import io
import json
import math
import pathlib
import sys


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "viddydictate_whisperd", ROOT / "viddydictate_whisperd.py")
assert SPEC is not None and SPEC.loader is not None
DAEMON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DAEMON)


def _reject_constant(token):
    raise AssertionError(f"non-JSON constant leaked onto the wire: {token!r}")


def strict_loads(body: bytes):
    """`json.loads` that REFUSES `NaN`/`Infinity`/`-Infinity`, the way Apple's parser does."""
    return json.loads(body.decode("utf-8"), parse_constant=_reject_constant)


def _old_encode(obj):
    """The pre-fix encoder: `json.dumps`'s `allow_nan=True` default, for RED-before-fix evidence."""
    return json.dumps(obj).encode("utf-8")


def _encode(obj):
    """The production encoder when it exists; the OLD encoder otherwise.

    On unfixed code this makes the new checks fail by ASSERTION (strict parse rejects the body),
    not by an AttributeError compile error.
    """
    return getattr(DAEMON, "_encode_json", _old_encode)(obj)


class _FakeHandler:
    """Minimal stand-in for the parts of `Handler` that `_send` touches."""

    def __init__(self):
        self.wfile = io.BytesIO()
        self.status = None
        self.headers = []
        self.ended = False

    def send_response(self, code):
        self.status = code

    def send_header(self, key, value):
        self.headers.append((key, value))

    def end_headers(self):
        self.ended = True


def main() -> int:
    print("--- whisper daemon JSON-safe encoding (non-finite -> null, strict parse) ---")
    results = []

    def check(name, fn):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 — a failed check is data, not a crash
            results.append((name, False))
            print(f"  [FAIL] {name}: {exc}")
        else:
            results.append((name, True))
            print(f"  [ok ] {name}")

    def segments_body():
        return {
            "transcript": "hello world",
            "segments": [{
                "start": 0.0, "end": 1.0, "raw_text": "hello world",
                "no_speech_prob": float("nan"),
                "avg_logprob": float("inf"),
                "compression_ratio": float("-inf"),
            }],
        }

    def nested_body():
        return {
            "outer": [{"inner": float("inf")}, [float("nan"), 1.5]],
            "deeper": {"list": [float("-inf")]},
        }

    # ---- new: the encoder replaces every non-finite metric with null ---------------------------------
    def new_encode_segments():
        body = _encode(segments_body())
        parsed = strict_loads(body)
        assert parsed["transcript"] == "hello world", parsed
        segment = parsed["segments"][0]
        assert segment["no_speech_prob"] is None, segment
        assert segment["avg_logprob"] is None, segment
        assert segment["compression_ratio"] is None, segment
        assert segment["start"] == 0.0 and segment["raw_text"] == "hello world", segment

    check("stt-nonfinite: new: _encode_json writes NaN/Infinity/-Infinity as null and stays strict-parseable",
          new_encode_segments)

    # ---- new: Handler._send writes a strict body and an honest Content-Length ------------------------
    def new_send_strict():
        fake = _FakeHandler()
        DAEMON.Handler._send(fake, 200, segments_body())
        body = fake.wfile.getvalue()
        strict_loads(body)
        assert fake.status == 200, fake.status
        headers = dict(fake.headers)
        assert headers.get("Content-Type") == "application/json", headers
        assert int(headers["Content-Length"]) == len(body), (headers, len(body))

    check("stt-nonfinite: new: Handler._send writes a strict-parseable body with a matching Content-Length",
          new_send_strict)

    # ---- new: nesting does not hide a non-finite value -----------------------------------------------
    def new_encode_nested():
        parsed = strict_loads(_encode(nested_body()))
        assert parsed == {
            "outer": [{"inner": None}, [None, 1.5]],
            "deeper": {"list": [None]},
        }, parsed

    check("stt-nonfinite: new: nested non-finite inside lists inside dicts is replaced",
          new_encode_nested)

    # ---- guard: finite values, types and key order are untouched -------------------------------------
    def guard_finite_unchanged():
        obj = {"a": 1.5, "b": 7, "c": "s", "d": True, "e": None, "f": [1, 2.0, False]}
        parsed = strict_loads(_encode(obj))
        assert list(parsed.keys()) == list(obj.keys()), parsed
        assert parsed == obj, parsed
        assert isinstance(parsed["b"], int) and not isinstance(parsed["b"], bool), parsed["b"]

    check("stt-nonfinite: guard: finite floats, ints, strings, bools and None are unchanged and key order is preserved",
          guard_finite_unchanged)

    # ---- guard: the real success shape keeps its keys ------------------------------------------------
    def guard_real_shape():
        obj = {
            "transcript": "t", "raw_transcript": "t", "segments": [],
            "model": "mlx-community/whisper-large-v3-turbo",
            "parameters": {"clean": True},
        }
        parsed = strict_loads(_encode(obj))
        assert set(parsed.keys()) == {"transcript", "raw_transcript", "segments", "model", "parameters"}, parsed

    check("stt-nonfinite: guard: the real success shape keeps transcript/raw_transcript/segments/model/parameters",
          guard_real_shape)

    # ---- guard: allow_nan=False is not weakened ------------------------------------------------------
    def guard_allow_nan_not_weakened():
        try:
            json.dumps({"x": float("nan")}, allow_nan=False)
        except ValueError:
            pass
        else:
            raise AssertionError("json.dumps(allow_nan=False) no longer rejects NaN")
        encode = getattr(DAEMON, "_encode_json", None)
        if encode is None:
            return  # unfixed code has no helper; the stdlib half is the guard on that base
        original = DAEMON._json_safe
        DAEMON._json_safe = lambda obj: obj
        try:
            try:
                encode({"x": float("nan")})
            except ValueError:
                pass
            else:
                raise AssertionError("_encode_json emitted NaN instead of raising: allow_nan=False was weakened")
        finally:
            DAEMON._json_safe = original

    check("stt-nonfinite: guard: allow_nan=False is not weakened (a non-finite bypassing the helper raises)",
          guard_allow_nan_not_weakened)

    # ---- guard: /health-style bodies still encode ----------------------------------------------------
    def guard_health_body():
        obj = {"ready": True, "model": "m", "idle_s": 1.2, "error": None,
               "phase": "ready", "phase_s": 0.0, "phase_detail": None}
        parsed = strict_loads(_encode(obj))
        assert parsed["ready"] is True and parsed["idle_s"] == 1.2 and parsed["phase"] == "ready", parsed

    check("stt-nonfinite: guard: /health-style bodies still encode and parse", guard_health_body)

    # ---- guard: finite extremes (very large, very small, negative zero) are untouched --------------
    def guard_finite_extremes():
        obj = {"huge": 1e308, "tiny": 5e-324, "negzero": -0.0, "label": "x"}
        parsed = strict_loads(_encode(obj))
        assert parsed["huge"] == 1e308, parsed
        assert parsed["tiny"] == 5e-324, parsed
        assert math.copysign(1.0, parsed["negzero"]) == -1.0, parsed
        assert list(parsed.keys()) == list(obj.keys()), parsed

    check("stt-nonfinite: guard: very large, very small and negative-zero finite floats are unchanged by the encoder",
          guard_finite_extremes)

    passed = sum(1 for _, ok in results if ok)
    failed = len(results) - passed
    print(f"[whisperd-json-safe] checks={len(results)} passed={passed} failed={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
