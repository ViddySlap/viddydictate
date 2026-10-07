#!/usr/bin/env python3
"""Mechanical differential fuzz gate. Gate author: vdtpfuzz GF (master directive: catch a 4th
Swift-vs-Python Unicode mismatch in `verify.sh` itself, not by a judge re-generating cases by hand).

Generates synthetic trigger/accept_cut cases -- plain ASCII, isolated/combined Unicode combining
marks, NFC/NFD pairs of the SAME visible text, multi-scalar ZWJ emoji and skin-tone/flag sequences,
CJK ideographs, RTL (Arabic/Hebrew) text, and punctuation runs at segment/suffix edges -- computes
the expected answer for each by calling `core.py` directly (the oracle), then builds and runs the
Swift port's `--tailcheck-fuzz-io` CLI seam (`TailCheckFuzzIO.swift`) over the same cases and
compares every one.

Seed is FIXED (1337) and never time-based: a mismatch must reproduce byte-for-byte on a rerun.
Every string generated here is synthetic; none of it is, or is derived from, real dictation.

Exit 0: all cases agree. Exit 1: at least one case disagrees (prints the first 5 diffs).
"""

from __future__ import annotations

import json
import os
import pathlib
import random
import subprocess
import sys
import tempfile
import unicodedata

import core

SEED = 1337
TRIGGER_CASE_COUNT = 1000
ACCEPT_CUT_CASE_COUNT = 1000

ROOT = pathlib.Path(__file__).resolve().parents[2]

# --- synthetic word banks (none of this is real dictation) -------------------------------------

ASCII_WORDS = [
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "thank", "you",
    "please", "review", "draft", "approve", "hello", "world", "test", "note", "correct",
    "wrong", "ship", "it", "later", "today", "again", "stop", "go", "yes", "no", "maybe",
]

# Sorted so iteration order never depends on Python's per-process string-hash seed.
OUTRO_PHRASE_LIST = sorted(core.OUTRO_PHRASES)

CJK_WORDS = ["你好", "谢谢", "测试", "文档", "审查", "再见", "朋友", "工作", "早上好", "没问题"]

RTL_WORDS = [
    "شكرا",      # Arabic: thanks
    "مرحبا",      # Arabic: hello
    "من فضلك",    # Arabic: please
    "תודה",       # Hebrew: thanks
    "שלום",       # Hebrew: hello
    "בבקשה",      # Hebrew: please
]

# Combining diacritics (Mn category) applied to a bare ASCII base letter.
COMBINING_MARKS = [
    "́",  # combining acute accent
    "̀",  # combining grave accent
    "̈",  # combining diaeresis
    "̧",  # combining cedilla
    "̣",  # combining dot below
]

# NFC-form base letters that have an NFD decomposition, so (nfc, nfd) differ scalar-for-scalar
# while remaining the SAME visible text.
NFC_DECOMPOSABLE = ["é", "ü", "ñ", "ç", "å", "ô", "ê", "ö"]

# Multi-scalar emoji sequences: ZWJ family/profession sequences, skin-tone modifiers, flag
# sequences (regional-indicator pairs), and a ZWJ + variation-selector flag.
EMOJI_SEQUENCES = [
    "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466",  # family: man, woman, girl, boy (ZWJ)
    "\U0001F44D\U0001F3FD",                                          # thumbs up, medium skin tone
    "\U0001F469\U0001F3FE‍\U0001F4BB",                          # woman medium-dark skin tone + ZWJ + laptop
    "\U0001F1FA\U0001F1F8",                                          # flag: regional indicators U+S
    "\U0001F3F3️‍\U0001F308",                              # rainbow flag: white flag + VS16 + ZWJ + rainbow
    "\U0001F600‍\U0001F600",                                     # not a real sequence: ZWJ between two plain emoji
]

PUNCTUATION_RUNS = [
    "...", "!?!", "--", "—", "。。。", "؟؟", "!!!", "…", "·.·", "？！", "¿¿¿", "״״",
]

WHITESPACE_LIKE = [" ", "\t", " ", " ", "　", "​", " "]


def _nfc_nfd_pair(base: str) -> tuple[str, str]:
    return unicodedata.normalize("NFC", base), unicodedata.normalize("NFD", base)


def _synthetic_word(rng: random.Random) -> str:
    bucket = rng.randrange(6)
    if bucket == 0:
        return rng.choice(ASCII_WORDS)
    if bucket == 1:
        return rng.choice(CJK_WORDS)
    if bucket == 2:
        return rng.choice(RTL_WORDS)
    if bucket == 3:
        base = rng.choice("abcdefghij")
        return base + rng.choice(COMBINING_MARKS)
    if bucket == 4:
        form = rng.choice(_nfc_nfd_pair(rng.choice(NFC_DECOMPOSABLE)))
        return form
    return rng.choice(EMOJI_SEQUENCES)


def _synthetic_phrase(rng: random.Random, min_words: int = 1, max_words: int = 6) -> str:
    n = rng.randint(min_words, max_words)
    return " ".join(_synthetic_word(rng) for _ in range(n))


def _segment(start: float, end: float, raw_text: str, no_speech_prob: float,
             avg_logprob: float, compression_ratio: float = 1.0) -> dict:
    return {
        "start": start,
        "end": end,
        "raw_text": raw_text,
        "no_speech_prob": no_speech_prob,
        "avg_logprob": avg_logprob,
        "compression_ratio": compression_ratio,
    }


# --- trigger_cases generation --------------------------------------------------------------

def _gen_trigger_case(rng: random.Random, index: int) -> dict:
    kind = rng.randrange(7)
    label = f"trigger_{index:04d}_{kind}"

    if kind == 0:
        # outro_filler_after_gap candidate: a random (sometimes mismatched-case, sometimes
        # punctuation-decorated, sometimes RTL-mixed) rendering of an outro phrase after a gap.
        phrase = rng.choice(OUTRO_PHRASE_LIST)
        decorated = "".join(
            ch.upper() if rng.random() < 0.3 else ch for ch in phrase
        )
        if rng.random() < 0.5:
            decorated = decorated + rng.choice(PUNCTUATION_RUNS)
        gap = rng.choice([0.1, 0.5, 0.8, 0.81, 1.5, 3.0])
        prev_end = rng.uniform(0.0, 5.0)
        segments = [
            _segment(0.0, prev_end, _synthetic_phrase(rng), 0.05, -0.2),
            _segment(prev_end + gap, prev_end + gap + 1.0, decorated, rng.uniform(0.0, 1.0), rng.uniform(-3.0, 0.0)),
        ]
    elif kind == 1:
        # doubled_token candidate, including Unicode-cased and NFC/NFD doubles.
        word = _synthetic_word(rng)
        other_case = word.upper() if rng.random() < 0.5 else word
        text = f"{_synthetic_phrase(rng, 0, 2)} {other_case} {word}".strip()
        segments = [_segment(0.0, 2.0, text, 0.05, -0.2)]
    elif kind == 2:
        # repeat_loop candidate: one token repeated >= REPEAT_LOOP_MIN_RUN times, sometimes
        # multi-scalar (emoji/CJK/combining) tokens.
        word = _synthetic_word(rng)
        run = rng.randint(3, 10)
        text = " ".join([word] * run)
        segments = [_segment(0.0, 2.0, text, 0.05, -0.2)]
    elif kind == 3:
        # lone_punctuation_tail candidate: punctuation-only (sometimes RTL/CJK punctuation).
        text = rng.choice(PUNCTUATION_RUNS) + rng.choice(WHITESPACE_LIKE) + rng.choice(PUNCTUATION_RUNS)
        segments = [_segment(0.0, 2.0, text, 0.05, -0.2)]
    elif kind == 4:
        # low_confidence_tail candidate: >=2 segments, last one low-confidence.
        segments = [
            _segment(0.0, 2.0, _synthetic_phrase(rng), 0.05, -0.2),
            _segment(2.1, 3.0, _synthetic_phrase(rng), rng.uniform(0.0, 1.0), rng.uniform(-5.0, 1.0)),
        ]
    elif kind == 5:
        # cleanup_added_suffix candidate: final_text extends raw_text, sometimes by an
        # NFC/NFD-mismatched or multi-scalar-emoji suffix.
        base = _synthetic_phrase(rng)
        suffix = _synthetic_word(rng)
        segments = [_segment(0.0, 2.0, base, 0.05, -0.2)]
    else:
        # A clean, unremarkable take: must trigger nothing, including on exotic scripts.
        base = _synthetic_phrase(rng, 1, 8)
        segments = [_segment(0.0, 2.0, base, rng.uniform(0.0, 0.3), rng.uniform(-0.8, 0.0))]

    raw_text = " ".join(s["raw_text"] for s in segments)
    if kind == 5:
        final_text = raw_text + " " + suffix
    elif rng.random() < 0.1:
        # Occasionally feed a final_text that LOOKS like an appended suffix under NFC/NFD but is
        # not an exact scalar-prefix match -- the exact-scalar-prefix guard's own negative control.
        nfc, nfd = _nfc_nfd_pair(rng.choice(NFC_DECOMPOSABLE))
        final_text = (raw_text + nfd) if raw_text.endswith(nfc) else raw_text
    else:
        final_text = raw_text

    return {
        "label": label,
        "segments": segments,
        "raw_text": raw_text,
        "final_text": final_text,
    }


# --- accept_cut_cases generation -----------------------------------------------------------

def _gen_accept_cut_case(rng: random.Random, index: int) -> dict:
    kind = rng.randrange(6)
    label = f"accept_cut_{index:04d}_{kind}"

    body = _synthetic_phrase(rng, 2, 10)
    tail_word = _synthetic_word(rng)

    boundaries = None
    max_words = 8
    max_share = 0.4

    if kind == 0:
        # A true trailing suffix at a word boundary (space before the suffix).
        text = f"{body} {tail_word}"
        junk_suffix = f" {tail_word}"
    elif kind == 1:
        # Whole-text cut: suffix == text exactly.
        text = body
        junk_suffix = body
    elif kind == 2:
        # Body edit: the "suffix" actually occurs mid-text, not at the end.
        text = f"{tail_word} {body} {_synthetic_word(rng)}"
        junk_suffix = tail_word
    elif kind == 3:
        # Mid-word split: suffix is a true trailing substring, but its start scalar is
        # alphanumeric and so is the scalar right before it (splits a token), unless a declared
        # boundary excuses it. Built directly from scalars so NFC/NFD and emoji ZWJ sequences
        # land mid-cluster rather than only mid-ASCII-word.
        base_word = rng.choice(NFC_DECOMPOSABLE + ASCII_WORDS + CJK_WORDS)
        text = f"{body} {base_word}"
        cut_at = len(text) - max(1, len(base_word) // 2)
        junk_suffix = text[cut_at:]
        if rng.random() < 0.5:
            boundaries = [cut_at]
    elif kind == 4:
        # Too-many-words / share-too-high: a long suffix relative to a short body.
        long_suffix_words = [_synthetic_word(rng) for _ in range(rng.randint(5, 12))]
        text = f"{body} {' '.join(long_suffix_words)}"
        n = rng.randint(1, len(long_suffix_words))
        junk_suffix = " " + " ".join(long_suffix_words[-n:])
        if rng.random() < 0.5:
            max_words = rng.choice([1, 2, 3])
        if rng.random() < 0.5:
            max_share = rng.choice([0.05, 0.1, 0.9])
    else:
        # Not-suffix noise: a fabricated/hallucinated suffix unrelated to the text, sometimes
        # drawn from emoji/RTL/CJK banks so the mismatch is scalar-for-scalar, not just ASCII.
        text = body
        junk_suffix = _synthetic_word(rng) + rng.choice(PUNCTUATION_RUNS)

    return {
        "label": label,
        "text": text,
        "junk_suffix": junk_suffix,
        "boundaries": boundaries,
        "max_words": max_words,
        "max_share": max_share,
    }


def _build_test_app() -> tuple[pathlib.Path, dict]:
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="vdtpfuzz-build-"))
    home = scratch / "home"
    tmp = scratch / "tmp"
    home.mkdir(parents=True, exist_ok=True)
    tmp.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    env["HOME"] = str(home)
    env["CFFIXED_USER_HOME"] = str(home)
    env["TMPDIR"] = str(tmp) + "/"

    subprocess.run(["./build.sh"], cwd=str(ROOT), env=env, check=True)

    test_app = ROOT / "build" / "ViddyDictateTests.app" / "Contents" / "MacOS" / "ViddyDictateTests"
    return test_app, env


def main() -> int:
    rng = random.Random(SEED)

    trigger_cases = [_gen_trigger_case(rng, i) for i in range(TRIGGER_CASE_COUNT)]
    accept_cut_cases = [_gen_accept_cut_case(rng, i) for i in range(ACCEPT_CUT_CASE_COUNT)]

    for c in trigger_cases:
        c["expected_reasons_sorted"] = sorted(core.trigger(c["segments"], c["raw_text"], c["final_text"]))

    for c in accept_cut_cases:
        accepted, reason = core.accept_cut(
            c["text"], c["junk_suffix"], boundaries=c["boundaries"],
            max_words=c["max_words"], max_share=c["max_share"])
        c["expected_accepted"] = accepted
        c["expected_reason"] = reason

    fixture = {
        "schema": "tailcheck-parity-fixture/1",
        "source": "generated by differential_fuzz.py, seed=1337, synthetic only",
        "trigger_cases": trigger_cases,
        "accept_cut_cases": accept_cut_cases,
    }

    work = pathlib.Path(tempfile.mkdtemp(prefix="vdtpfuzz-io-"))
    in_path = work / "fuzz-in.json"
    out_path = work / "fuzz-out.json"
    in_path.write_text(json.dumps(fixture), encoding="utf-8")

    print(f"[differential-fuzz] generated {len(trigger_cases)} trigger cases and "
          f"{len(accept_cut_cases)} accept_cut cases (seed={SEED})")

    test_app, env = _build_test_app()
    if not test_app.is_file():
        print(f"[differential-fuzz] FAIL: build did not produce {test_app}", file=sys.stderr)
        return 1

    result = subprocess.run(
        [str(test_app), "--tailcheck-fuzz-io", str(in_path), str(out_path)],
        env=env, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[differential-fuzz] FAIL: {test_app} --tailcheck-fuzz-io exited {result.returncode}",
              file=sys.stderr)
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return 1

    if not out_path.is_file():
        print(f"[differential-fuzz] FAIL: no output written to {out_path}", file=sys.stderr)
        return 1

    output = json.loads(out_path.read_text(encoding="utf-8"))
    trigger_actual = {r["label"]: r["reasons_sorted"] for r in output.get("trigger_results", [])}
    accept_cut_actual = {r["label"]: (r["accepted"], r["reason"]) for r in output.get("accept_cut_results", [])}

    mismatches = []
    for c in trigger_cases:
        got = trigger_actual.get(c["label"])
        want = c["expected_reasons_sorted"]
        if got is None or sorted(got) != want:
            mismatches.append(("trigger", c["label"], c, want, got))
    for c in accept_cut_cases:
        got = accept_cut_actual.get(c["label"])
        want = (c["expected_accepted"], c["expected_reason"])
        if got is None or tuple(got) != want:
            mismatches.append(("accept_cut", c["label"], c, want, got))

    total = len(trigger_cases) + len(accept_cut_cases)
    if mismatches:
        print(f"[differential-fuzz] MISMATCH: {len(mismatches)} / {total} cases disagree "
              f"(seed={SEED})", file=sys.stderr)
        for kind, label, case, want, got in mismatches[:5]:
            print(f"  [{kind}] {label}: input={case!r}", file=sys.stderr)
            print(f"      expected={want!r} actual={got!r}", file=sys.stderr)
        return 1

    print(f"[differential-fuzz] PASS: {total} / {total} cases agree (seed={SEED})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
