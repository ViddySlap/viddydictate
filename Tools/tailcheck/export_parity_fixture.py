#!/usr/bin/env python3
"""Export `parity-fixture.json`: the Swift port's oracle, generated FROM `core.py` (the real
contract), never hand-written against the design note in parallel.

Gate author: vdtpga. Cases below mirror `test_core.py`'s own fixtures one-for-one (same segments,
same text, same expected outcome), so a case here can never quietly drift from what the protected
Python suite already pins; `test_parity_fixture.py` (protected) then pins core.py against this same
file, so the exported file and the Python reference can never silently diverge either.

Run with: python3 Tools/tailcheck/export_parity_fixture.py
Writes:   Tools/tailcheck/parity-fixture.json (deterministic key order, trailing newline)

Every string here is synthetic placeholder prose written for this export, never real dictation.
"""

from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import core  # noqa: E402


def _confident_segment(start: float, end: float, raw_text: str) -> dict:
    return {
        "start": start,
        "end": end,
        "raw_text": raw_text,
        "no_speech_prob": 0.05,
        "avg_logprob": -0.2,
        "compression_ratio": 1.0,
    }


# --- trigger cases: (label, segments, raw_text, final_text) -----------------------------------

_TRIGGER_CASES: list[tuple[str, list[dict], str, str]] = []


def _trigger_case(label: str, segments: list[dict], raw_text: str, final_text: str) -> None:
    _TRIGGER_CASES.append((label, segments, raw_text, final_text))


_clean_text = "The fix that landed for the sticky note tabs looks pretty good."
_trigger_case(
    "clean_single_segment_never_fires",
    [_confident_segment(0.0, 5.0, _clean_text)],
    _clean_text,
    _clean_text,
)

_outro_text = "I approve. Thank you."
_trigger_case(
    "outro_filler_after_gap",
    [
        _confident_segment(0.0, 5.0, "I approve."),
        {
            "start": 6.5, "end": 7.0, "raw_text": "Thank you.",
            "no_speech_prob": 0.3, "avg_logprob": -0.3, "compression_ratio": 1.0,
        },
    ],
    _outro_text,
    _outro_text,
)

_doubled_text = "Send it over. fuck fuck"
_trigger_case(
    "doubled_token",
    [
        _confident_segment(0.0, 5.0, "Send it over."),
        _confident_segment(5.1, 5.4, "fuck fuck"),
    ],
    _doubled_text,
    _doubled_text,
)

_loop_tail = " ".join(["primarily"] * 8)
_loop_text = f"Checking in now. {_loop_tail}"
_trigger_case(
    "repeat_loop",
    [
        _confident_segment(0.0, 5.0, "Checking in now."),
        _confident_segment(5.1, 12.0, _loop_tail),
    ],
    _loop_text,
    _loop_text,
)

_punct_text = "That's the plan. ..."
_trigger_case(
    "lone_punctuation_tail",
    [
        _confident_segment(0.0, 5.0, "That's the plan."),
        _confident_segment(5.1, 5.2, "..."),
    ],
    _punct_text,
    _punct_text,
)

_lowconf_text = "Let's wrap up. mmstuff"
_trigger_case(
    "low_confidence_tail",
    [
        _confident_segment(0.0, 5.0, "Let's wrap up."),
        {
            "start": 5.1, "end": 5.6, "raw_text": "mmstuff",
            "no_speech_prob": 0.8, "avg_logprob": -1.5, "compression_ratio": 1.0,
        },
    ],
    _lowconf_text,
    _lowconf_text,
)

_cleanup_raw = "The release is ready."
_cleanup_final = "The release is ready. We'll be right back."
_trigger_case(
    "cleanup_added_suffix",
    [_confident_segment(0.0, 5.0, _cleanup_raw)],
    _cleanup_raw,
    _cleanup_final,
)

_trigger_case(
    "low_confidence_never_fires_on_single_segment",
    [
        {
            "start": 0.0, "end": 1.0, "raw_text": "use",
            "no_speech_prob": 0.9, "avg_logprob": -2.0, "compression_ratio": 1.0,
        }
    ],
    "use",
    "use",
)

BARE_TRAPS = ("No, no, no.", "Very, very good.", "Yes.", "Thank you.", "Bye.")

for _bare in BARE_TRAPS:
    _trigger_case(
        f"bare_whole_dictation_trap[{_bare!r}]",
        [_confident_segment(0.0, 1.0, _bare)],
        _bare,
        _bare,
    )


# --- accept_cut cases: (label, text, junk_suffix, boundaries, max_words, max_share) ------------

_ACCEPT_CASES: list[tuple[str, str, str, list[int] | None, int, float]] = []


def _accept_case(
    label: str, text: str, junk_suffix: str,
    boundaries: list[int] | None = None, max_words: int = 8, max_share: float = 0.4,
) -> None:
    _ACCEPT_CASES.append((label, text, junk_suffix, boundaries, max_words, max_share))


_AC_TEXT = "I reviewed the draft and I approve. Thank you."
_AC_JUNK = " Thank you."
_accept_case("accepts_short_suffix_at_word_boundary", _AC_TEXT, _AC_JUNK)
_accept_case(
    "accepts_short_suffix_at_segment_boundary", _AC_TEXT, _AC_JUNK,
    boundaries=[len(_AC_TEXT) - len(_AC_JUNK)],
)
_accept_case("refuses_non_suffix", _AC_TEXT, " We'll see you next week.")
_accept_case(
    "refuses_body_edit", "I approve. Let's ship it today.", "approve.",
)
_accept_case("refuses_whole_text_cut", _AC_TEXT, _AC_TEXT)
_accept_case("refuses_mid_word_cut", "I approve", "prove")
_accept_case(
    "refuses_too_many_words",
    "I approve. This has been a long and winding road to approval.",
    " This has been a long and winding road to approval.",
    max_words=8,
)
_accept_case(
    "refuses_share_too_high", "Yes I think so", " I think so", max_words=8, max_share=0.4,
)
_accept_case(
    "refuses_no_sentence_remains",
    "... --- ... --- ... --- ... ---" + " Thank you.",
    " Thank you.",
)
for _bare in BARE_TRAPS:
    _accept_case(f"refuses_bare_whole_dictation_trap[{_bare!r}]", _bare, _bare)


def main() -> int:
    trigger_cases = []
    for label, segments, raw_text, final_text in _TRIGGER_CASES:
        reasons = core.trigger(segments, raw_text, final_text)
        trigger_cases.append({
            "label": label,
            "segments": segments,
            "raw_text": raw_text,
            "final_text": final_text,
            "expected_reasons_sorted": sorted(reasons),
        })

    accept_cases = []
    for label, text, junk_suffix, boundaries, max_words, max_share in _ACCEPT_CASES:
        accepted, reason = core.accept_cut(
            text, junk_suffix, boundaries=boundaries, max_words=max_words, max_share=max_share,
        )
        accept_cases.append({
            "label": label,
            "text": text,
            "junk_suffix": junk_suffix,
            "boundaries": boundaries,
            "max_words": max_words,
            "max_share": max_share,
            "expected_accepted": accepted,
            "expected_reason": reason,
        })

    fixture = {
        "schema": "tailcheck-parity-fixture/1",
        "source": "exported from Tools/tailcheck/core.py by export_parity_fixture.py",
        "trigger_cases": trigger_cases,
        "accept_cut_cases": accept_cases,
    }

    out_path = pathlib.Path(__file__).resolve().parent / "parity-fixture.json"
    out_path.write_text(json.dumps(fixture, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"wrote {out_path} ({len(trigger_cases)} trigger cases, {len(accept_cases)} accept_cut cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
