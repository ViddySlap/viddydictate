"""tailcheck.eval_set — synthetic eval set + runner (STUB, gate author: vdtga).

Design note S4: "All evaluation runs on the Mac, locally. Audio corpora and
real dictation text never enter a frontier session." This module builds its
own text, entirely in code, with a module-level `random.Random(seed)` -- it
never reads a file under `~/` or the vault, and never reads any real
dictation, history, recording, note, or dictionary content. Every word
below was invented for this prototype to describe failure SHAPES, per the
house rules, not transcribed from any real corpus.

Both public functions are stubs: final signatures, wrong/neutral bodies.
`test_eval_set.py` (protected) encodes the real contract below and is red
against these stubs for a named reason.
"""

from __future__ import annotations

import random
from typing import Any

import core

# --- synthetic vocabulary (invented for this prototype; not from any file) --

_SUBJECTS = (
    "the sticky note tabs",
    "the release notes",
    "the onboarding flow",
    "the dashboard layout",
    "the retry logic",
    "the export script",
    "the calendar sync",
    "the invoice template",
    "the search index",
    "the login screen",
    "the backup job",
    "the color palette",
    "the test harness",
    "the icon set",
    "the changelog",
    "the sidebar width",
    "the error banner",
    "the autosave timer",
    "the tooltip copy",
    "the keyboard shortcut",
)

_VERDICTS = (
    "looks pretty good",
    "needs one more pass",
    "is ready to ship",
    "should wait until Monday",
    "is a quick fix",
    "is worth revisiting",
    "can go out today",
    "is close, not quite there",
)

_NAMES = ("Brian", "Dana", "Theo", "Marisol", "Keane", "Odalys")
_NUMBERS = ("42", "17", "203", "9", "1200", "6")

# clean bodies: one unremarkable sentence each, used both as standalone
# clean items and as the base that trap endings / fabrications attach to.
_BODY_TEMPLATE = "The fix that landed for {subject} {verdict}."

# trap endings: real, legitimate ways a short dictation ends that LOOK
# suspicious on paper (design note S4). Deliberately distinct from every
# string in _FABRICATION_SUFFIXES below so no trap text can ever collide
# with a fabrication suffix.
_TRAP_FAMILIES: dict[str, tuple[str, ...]] = {
    "email_signoff": (
        "Appreciate it, thank you so much for your help today.",
        "Thanks again, talk soon.",
        "Bye for now, see you at the standup.",
    ),
    "real_repetition": (
        "No, no, no, that is not what I meant at all.",
        "Very, very good, let's keep that version.",
        "So, so close, just one more pass.",
    ),
    "one_word_affirmative": ("Yes.", "Approved.", "Agreed."),
    "name_ending": tuple(f"Send the final draft to {n}." for n in _NAMES),
    "number_ending": tuple(f"The ticket count came out to {n}." for n in _NUMBERS),
    "ends_on_so": (
        "I was going to mention the deploy window, but never mind, so",
        "We can revisit the pricing page later, so",
    ),
    # Gate review vdtga-GJ finding (d): the sharpest false-trim case the
    # locked spec and core.py's own docstring single out by name is a BARE
    # repeated-word or outro-sounding phrase as the WHOLE dictation, not
    # softened into a longer sentence the way `real_repetition` above is.
    # Deliberately overlaps, by content, with `one_word_affirmative`
    # ("Yes.") and with the outro_filler_after_gap fabrication suffix
    # ("Thank you.", stripped) -- see test_eval_set.py's collision guard
    # for why that overlap is expected, not a defect, for this one family.
    "bare_single_segment": (
        "No, no, no.",
        "Very, very good.",
        "Yes.",
        "Thank you.",
        "Bye.",
    ),
}

# fabrication suffixes per S1 family: appended to a clean body to build a
# "fabricated" item. Each is distinct from every trap string above.
FABRICATION_SUFFIXES_BY_FAMILY: dict[str, tuple[str, ...]] = {
    core.REASON_OUTRO_FILLER_AFTER_GAP: (" Thank you.", " We will see you next week."),
    core.REASON_DOUBLED_TOKEN: (" fuck fuck", " yes yes"),
    core.REASON_REPEAT_LOOP: (" " + " ".join(["primarily"] * 8),),
    core.REASON_LONE_PUNCTUATION_TAIL: (" .", " ..."),
    core.REASON_LOW_CONFIDENCE_TAIL: (" mmstuff",),
    core.REASON_CLEANUP_ADDED_SUFFIX: (" We'll be right back.",),
}

CLEAN_COUNT = 100
TRAP_COUNT = 120
# 220 clean-or-trap items total, trap share 120/220 ~= 54.5% >= 50%.


def _clean_bodies(rng: random.Random, count: int) -> list[str]:
    bodies = []
    subjects = list(_SUBJECTS)
    verdicts = list(_VERDICTS)
    for i in range(count):
        subject = subjects[i % len(subjects)]
        verdict = verdicts[(i // len(subjects)) % len(verdicts)]
        bodies.append(_BODY_TEMPLATE.format(subject=subject, verdict=verdict))
    rng.shuffle(bodies)
    return bodies


def generate(seed: int = 0) -> list[dict]:
    """Stub: returns `[]` unconditionally.

    Real contract: deterministic for a given `seed` (same `seed` ->
    byte-identical list, including order), built from
    `random.Random(seed)` only -- never from any file. Returns a list of:

        {
            "id": str,                      # unique, stable for the seed
            "kind": "clean" | "trap" | "fabricated",
            "family": str | None,            # trap subtype, or one of
                                              # core.ALL_REASONS for
                                              # "fabricated"; None for "clean"
            "text": str,                     # the dictation-like text
            "expected_junk_suffix": str,      # "" unless kind == "fabricated"
        }

    At least `CLEAN_COUNT + TRAP_COUNT` (>= 200) items have
    `kind in ("clean", "trap")`, with traps >= 50% of that subset
    (`TRAP_COUNT / (CLEAN_COUNT + TRAP_COUNT) >= 0.5`). Every family in
    `FABRICATION_SUFFIXES_BY_FAMILY` (== every S1 family) is covered by at
    least one "fabricated" item, built by appending one of that family's
    suffixes to a clean body (`expected_junk_suffix` is exactly that
    suffix). No trap or clean text may equal any string in
    `FABRICATION_SUFFIXES_BY_FAMILY` (collision would make a legitimate
    trap indistinguishable from a known fabrication by content alone).
    """
    return []


def run(judge: Any, items: list[dict]) -> dict:
    """Stub: returns `{}` unconditionally.

    Real contract: exercises the full pipeline (`core.check`, mode=`"trim"`)
    once per item via a synthesized `segments`/`raw_text` pair (see below),
    and tallies:

        {
            "false_trims": int,  # kind in (clean, trap) AND paste_text != text
            "caught": int,       # kind == fabricated AND paste_text ==
                                  # text with expected_junk_suffix removed
            "missed": int,       # kind == fabricated AND NOT caught
            "clean_ok": int,     # kind in (clean, trap) AND paste_text == text
            "total": int,        # len(items)
        }

    Segment synthesis per item (single source of truth both `run` and the
    test oracle must agree on -- see `test_eval_set.py`):

    - `kind in ("clean", "trap")`: ONE segment, confident stats
      (`no_speech_prob=0.05`, `avg_logprob=-0.2`, `compression_ratio=1.0`),
      `raw_text == final_text == text`. This is the single-segment safety
      case (six of seven real safety takes decode this way).
    - `kind == "fabricated"`, family `cleanup_added_suffix`: ONE segment
      (the clean body only, confident stats) -- the whisper decode itself
      is clean; `raw_text = body`, `final_text = text = body +
      expected_junk_suffix`. This is the "the cleanup LLM did it, not
      whisper" shape from the design note's open question.
    - `kind == "fabricated"`, every other family: TWO segments -- the body
      (confident stats as above) followed by a tail segment whose
      `raw_text == expected_junk_suffix.strip()` and whose timing/
      confidence fields match that family's trigger condition (a > 0.8s
      gap for `outro_filler_after_gap`; contiguous and short for
      `doubled_token`; contiguous with a long repeated run for
      `repeat_loop`; contiguous, punctuation-only for
      `lone_punctuation_tail`; contiguous with `no_speech_prob=0.8,
      avg_logprob=-1.5` for `low_confidence_tail`). `raw_text == final_text
      == text` for all of these (whisper produced the junk; the cleanup
      LLM passed it through unchanged).

    `judge.answer` is called with `context` = the text before the tail
    segment(s) and `tail` = the tail segment's (or, for single-segment
    items, the whole) `raw_text`.
    """
    return {}
