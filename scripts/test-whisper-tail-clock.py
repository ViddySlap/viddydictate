#!/usr/bin/env python3
"""Pins the REVERT of the file-duration segment gate, and the diagnostics that outlived it.

History, because this file's name is now misleading and the reason matters more than the name:

An earlier revision dropped any segment starting at or after `audio_duration - 0.5`, anchoring the
transcript to the end of the WAV FILE. It was reverted on 2026-08-14 on the user's call. Two reasons:

  1. It fixed 1 of the 4 known-bad corpus takes. The fabricated tail does not sit near the file end -
     on the 204s take, speech stops at 16.84s and the file runs to 204.10s, so a cutoff at 203.60s
     was 187 seconds downstream of every fabrication.
  2. Worse, it could delete REAL speech. `trimTrailingNearSilence` keeps a pad of at most 0.5s after
     the last above-floor window, so the gate's 0.5s and the trim's 0.5s only cancel when a full pad
     exists. On a take that ends promptly after the last word nothing is trimmed, the cutoff lands
     INSIDE real speech, and a final phrase can be discarded. That is the user's ordinary recording habit,
     and live corpus verification demonstrated it on a real take.

The real anchor is the end of SPEECH, not the end of the file, and the daemon has no non-circular
speech-end signal today. That remains future work.

So this file no longer asserts a gate. It asserts that there is NO file-duration gate, and that the
diagnostics a future speech-end anchor will need are still present and honest.
"""

import importlib.util
import pathlib
import sys
import tempfile
import wave


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "viddydictate_whisperd", ROOT / "viddydictate_whisperd.py")
assert SPEC is not None and SPEC.loader is not None
DAEMON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DAEMON)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def fixture_result() -> dict:
    """Three segments; the last two start inside the final 0.5s of a 2.0s clip.

    Under the reverted gate segment 2 was dropped and segment 1 was clamped. Both must now survive:
    that is the whole point of this file.
    """
    return {
        "text": "one two two two two three three three three four four four four",
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "one",
             "no_speech_prob": 0.0, "avg_logprob": 0.0, "compression_ratio": 1.0},
            {"start": 1.4, "end": 1.9, "text": "two two two two",
             "no_speech_prob": 0.0, "avg_logprob": 0.0, "compression_ratio": 3.0},
            {"start": 1.5, "end": 2.4, "text": "three three three three four four four four",
             "no_speech_prob": 0.0, "avg_logprob": 0.0, "compression_ratio": 30.0},
        ],
    }


def main() -> int:
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        with wave.open(tmp.name, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16_000)
            wav.writeframes(b"\x00\x00" * 32_000)
        duration = DAEMON._wav_duration_seconds(tmp.name)

    # The duration helper stays. A speech-end anchor will still need to know how long the audio is.
    check(duration == 2.0, "WAV duration must come from frame count and frame rate")

    cleaned, segments = DAEMON._clean_segments(fixture_result(), True, audio_duration=duration)

    # THE REVERT ITSELF. Passing audio_duration must not cause any segment to be dropped or clamped.
    check(len(segments) == 3, "diagnostics must retain every raw segment")
    check(all(s["drop_reason"] != "audio_clock" for s in segments),
          "REGRESSION: a file-duration clock gate is back. It clips real speech on takes that end "
          "promptly after the last word - see this file's docstring before reinstating it.")
    check(segments[2]["kept"] is True,
          "a segment starting inside the final 0.5s is ORDINARY SPEECH and must survive")
    check(segments[1]["effective_end"] == segments[1]["end"],
          "no segment end may be clamped to a file-duration cutoff")

    # Passing no duration at all must behave identically - proves duration is diagnostic-only.
    _, no_duration = DAEMON._clean_segments(fixture_result(), True)
    check([s["kept"] for s in no_duration] == [s["kept"] for s in segments],
          "audio_duration is diagnostics-only: passing it must not change what is kept")

    # The diagnostics a future speech-end anchor needs.
    check(all("start" in s and "end" in s and "text" in s for s in segments),
          "every segment must expose start, end and text for future speech-end work")
    check(cleaned.strip() != "", "surviving speech must still produce text")

    # Repeat collapse is unchanged and still runs.
    uncollapsed, _ = DAEMON._clean_segments(fixture_result(), False, audio_duration=duration)
    check(len(uncollapsed.split()) >= len(cleaned.split()),
          "cleanup-off path must preserve at least as much text as the cleaned path")

    fallback, segments = DAEMON._clean_segments({"text": "one one one"}, True)
    check(fallback == "one", "segment-less fallback must preserve existing repeat cleanup")
    check(segments == [], "segment-less result must expose an empty segment list")

    print("[tail-clock][PASS] no file-duration gate; duration is diagnostic-only; segments intact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
