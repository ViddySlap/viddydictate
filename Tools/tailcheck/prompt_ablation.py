"""tailcheck.prompt_ablation — Mac-LATER prompt-ablation harness (STUB).

Design note S4 point 3 / UPDATE point 3: measures option D (drop or
shorten the Whisper `initial_prompt` bias) against Corpus A (the
fabrication must go) and Corpus B (the last kept segment's text must
survive byte-identical), per prompt variant `full` | `short` | `none`.

This module is PURE and never decodes audio itself: it takes an already
decoded-elsewhere JSON structure (`decodes_json`) and computes per-variant
structural metrics only. It is written and dry-run tested on the Boxx
against a FAKE fixture; it is run for real only on the Mac, after Ben's
login, and only against fixture WAVs -- never against the live daemon or
Ben's real corpus (house rules: no Mac work, no network, nothing
installed).

`run` is a stub: final signature, body returns `{}` unconditionally.
"""

from __future__ import annotations

from typing import Any

VARIANTS = ("full", "short", "none")

# decodes_json schema (a later Mac-side link produces this by decoding each
# corpus WAV once per variant and dumping the structural fields below; this
# module never touches audio or the decoder):
#
#   {
#     "corpus_a": {
#       "<take_id>": {
#         "<variant>": {
#           "segments": [{"start": float, "end": float, "text": str}, ...],
#           "speech_end_s": float,   # ground truth, from Corpus A's own
#                                     # DIAGNOSIS.md-style measurement, NOT
#                                     # derived from this decode
#         }, ...
#       }, ...
#     },
#     "corpus_b": {
#       "<take_id>": {
#         "<variant>": {
#           "segments": [{"start": float, "end": float, "text": str}, ...],
#           "expected_last_text": str,  # ground truth last-segment text
#         }, ...
#       }, ...
#     }
#   }


def run(decodes_json: dict) -> dict:
    """Stub: returns `{}` unconditionally.

    Real contract: for each variant in `VARIANTS` present in the fixture,
    returns

        {
            "<variant>": {
                "fabricated_tail_present": int,  # count of corpus_a takes
                                                   # where some segment's
                                                   # `start >= speech_end_s`
                                                   # (structural presence,
                                                   # never a literal-text
                                                   # check -- per the locked
                                                   # spec's "assert
                                                   # structurally" rule)
                "fabricated_tail_total": int,     # len(corpus_a takes present
                                                   # for this variant)
                "last_segment_preserved": int,    # count of corpus_b takes
                                                   # whose final segment's
                                                   # `text` ==
                                                   # `expected_last_text`,
                                                   # byte-identical
                "last_segment_total": int,        # len(corpus_b takes present
                                                   # for this variant)
            },
            ...
        }

    A take missing a given variant in the fixture is simply excluded from
    that variant's totals (never counted as a failure). An empty
    `"segments"` list has no fabricated tail (count 0) and no preservable
    last segment (excluded from `last_segment_total`, since there is
    nothing to compare).
    """
    corpus_a = decodes_json.get("corpus_a") or {}
    corpus_b = decodes_json.get("corpus_b") or {}

    # A variant is "present" if any take in either corpus carries it.
    present: set[str] = set()
    for corpus in (corpus_a, corpus_b):
        for take in corpus.values():
            if not isinstance(take, dict):
                continue
            for variant in VARIANTS:
                if variant in take:
                    present.add(variant)

    result: dict[str, dict[str, int]] = {}
    for variant in VARIANTS:
        if variant not in present:
            continue

        # Corpus A: structural fabricated-tail presence. A segment that
        # starts at or after the measured speech end is a fabricated tail.
        fabricated_tail_present = 0
        fabricated_tail_total = 0
        for take in corpus_a.values():
            if not isinstance(take, dict) or variant not in take:
                continue
            payload = take[variant]
            fabricated_tail_total += 1
            segments = payload.get("segments") or []
            speech_end_s = payload.get("speech_end_s")
            if speech_end_s is not None and any(
                seg.get("start", 0.0) >= speech_end_s for seg in segments
            ):
                fabricated_tail_present += 1

        # Corpus B: the last KEPT segment's text must survive byte-exact.
        # An empty segment list has nothing to compare, so it contributes
        # to neither the numerator nor the denominator.
        last_segment_preserved = 0
        last_segment_total = 0
        for take in corpus_b.values():
            if not isinstance(take, dict) or variant not in take:
                continue
            payload = take[variant]
            segments = payload.get("segments") or []
            if not segments:
                continue
            last_segment_total += 1
            if segments[-1].get("text") == payload.get("expected_last_text"):
                last_segment_preserved += 1

        result[variant] = {
            "fabricated_tail_present": fabricated_tail_present,
            "fabricated_tail_total": fabricated_tail_total,
            "last_segment_preserved": last_segment_preserved,
            "last_segment_total": last_segment_total,
        }

    return result
