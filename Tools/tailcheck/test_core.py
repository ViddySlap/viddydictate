"""Protected tests for tailcheck.core. Gate author: vdtga. Do not edit to
make a later link's implementation pass -- edit the implementation.

Every assertion below is against the REAL contract documented in
core.py's docstrings, not against the stub's actual behaviour. Reds are
expected right now; each one is the stub returning a wrong/neutral answer,
named in the test's own docstring.
"""

from __future__ import annotations

import re
import socket
import unittest

import core


def _confident_segment(start: float, end: float, raw_text: str) -> dict:
    return {
        "start": start,
        "end": end,
        "raw_text": raw_text,
        "no_speech_prob": 0.05,
        "avg_logprob": -0.2,
        "compression_ratio": 1.0,
    }


class SpyJudge:
    """Test double that records every (context, tail) pair it is actually
    asked about, then answers a fixed `answer` dict. Lets a test assert on
    what `check()` hands the judge, not just on `check()`'s own return
    value (gate review vdtga-GJ finding (a) / hard-coding risk: none of
    `MockJudge`/`OracleJudge`/`AdversarialJudge` could previously notice an
    oversized or wrong `context`/`tail` pair)."""

    def __init__(self, answer: dict) -> None:
        self._answer = answer
        self.calls: list[tuple[str, str]] = []

    def answer(self, context: str, tail: str, timeout_ms: int) -> dict:
        self.calls.append((context, tail))
        return dict(self._answer)


class TriggerTests(unittest.TestCase):
    def test_does_not_fire_on_clean_single_segment(self):
        """Stub returns [] always -> this happens to already match the
        expected [] for a genuinely clean take. Not stub-caused red."""
        text = "The fix that landed for the sticky note tabs looks pretty good."
        segments = [_confident_segment(0.0, 5.0, text)]
        self.assertEqual(core.trigger(segments, text, text), [])

    def test_fires_on_outro_filler_after_gap(self):
        """Red: stub always returns [], never REASON_OUTRO_FILLER_AFTER_GAP."""
        segments = [
            _confident_segment(0.0, 5.0, "I approve."),
            {
                "start": 6.5,
                "end": 7.0,
                "raw_text": "Thank you.",
                "no_speech_prob": 0.3,
                "avg_logprob": -0.3,
                "compression_ratio": 1.0,
            },
        ]
        text = "I approve. Thank you."
        reasons = core.trigger(segments, text, text)
        self.assertIn(core.REASON_OUTRO_FILLER_AFTER_GAP, reasons)

    def test_fires_on_doubled_token(self):
        """Red: stub always returns [], never REASON_DOUBLED_TOKEN."""
        segments = [
            _confident_segment(0.0, 5.0, "Send it over."),
            _confident_segment(5.1, 5.4, "fuck fuck"),
        ]
        text = "Send it over. fuck fuck"
        reasons = core.trigger(segments, text, text)
        self.assertIn(core.REASON_DOUBLED_TOKEN, reasons)

    def test_fires_on_repeat_loop(self):
        """Red: stub always returns [], never REASON_REPEAT_LOOP."""
        loop_tail = " ".join(["primarily"] * 8)
        segments = [
            _confident_segment(0.0, 5.0, "Checking in now."),
            _confident_segment(5.1, 12.0, loop_tail),
        ]
        text = f"Checking in now. {loop_tail}"
        reasons = core.trigger(segments, text, text)
        self.assertIn(core.REASON_REPEAT_LOOP, reasons)

    def test_fires_on_lone_punctuation_tail(self):
        """Red: stub always returns [], never REASON_LONE_PUNCTUATION_TAIL."""
        segments = [
            _confident_segment(0.0, 5.0, "That's the plan."),
            _confident_segment(5.1, 5.2, "..."),
        ]
        text = "That's the plan. ..."
        reasons = core.trigger(segments, text, text)
        self.assertIn(core.REASON_LONE_PUNCTUATION_TAIL, reasons)

    def test_fires_on_low_confidence_tail(self):
        """Red: stub always returns [], never REASON_LOW_CONFIDENCE_TAIL."""
        segments = [
            _confident_segment(0.0, 5.0, "Let's wrap up."),
            {
                "start": 5.1,
                "end": 5.6,
                "raw_text": "mmstuff",
                "no_speech_prob": 0.8,
                "avg_logprob": -1.5,
                "compression_ratio": 1.0,
            },
        ]
        text = "Let's wrap up. mmstuff"
        reasons = core.trigger(segments, text, text)
        self.assertIn(core.REASON_LOW_CONFIDENCE_TAIL, reasons)

    def test_fires_on_cleanup_added_suffix(self):
        """Red: stub always returns [], never REASON_CLEANUP_ADDED_SUFFIX."""
        raw_text = "The release is ready."
        final_text = "The release is ready. We'll be right back."
        segments = [_confident_segment(0.0, 5.0, raw_text)]
        reasons = core.trigger(segments, raw_text, final_text)
        self.assertIn(core.REASON_CLEANUP_ADDED_SUFFIX, reasons)

    def test_low_confidence_tail_never_fires_on_single_segment(self):
        """The single-segment safety floor: low confidence on the ONLY
        segment must never fire low_confidence_tail (mirrors the daemon's
        own `not single` guard). Stub returns [] -> matches, not red."""
        segments = [
            {
                "start": 0.0,
                "end": 1.0,
                "raw_text": "use",
                "no_speech_prob": 0.9,
                "avg_logprob": -2.0,
                "compression_ratio": 1.0,
            }
        ]
        self.assertEqual(core.trigger(segments, "use", "use"), [])


class AcceptCutTests(unittest.TestCase):
    TEXT = "I reviewed the draft and I approve. Thank you."
    JUNK = " Thank you."

    def test_accepts_true_short_suffix_at_word_boundary(self):
        """Red: stub always returns (False, 'stub'), never (True, ACCEPTED)."""
        result = core.accept_cut(self.TEXT, self.JUNK)
        self.assertEqual(result, (True, core.ACCEPTED))

    def test_accepts_true_short_suffix_at_segment_boundary(self):
        """Red: same as above, exercised through the `boundaries` path."""
        cut_point = len(self.TEXT) - len(self.JUNK)
        result = core.accept_cut(self.TEXT, self.JUNK, boundaries=[cut_point])
        self.assertEqual(result, (True, core.ACCEPTED))

    def test_refuses_non_suffix(self):
        """Red: expects REFUSAL_NOT_SUFFIX, stub says 'stub'."""
        result = core.accept_cut(self.TEXT, " We'll see you next week.")
        self.assertEqual(result, (False, core.REFUSAL_NOT_SUFFIX))

    def test_refuses_body_edit(self):
        """junk_suffix appears INSIDE the text, not at its tail -- a
        proposal to edit the body, not trim a tail. Red: expects
        REFUSAL_BODY_EDIT, stub says 'stub'."""
        text = "I approve. Let's ship it today."
        junk_suffix = "approve."  # present mid-text, not a trailing suffix
        result = core.accept_cut(text, junk_suffix)
        self.assertEqual(result, (False, core.REFUSAL_BODY_EDIT))

    def test_refuses_whole_text_cut(self):
        """Red: expects REFUSAL_WHOLE_TEXT, stub says 'stub'."""
        result = core.accept_cut(self.TEXT, self.TEXT)
        self.assertEqual(result, (False, core.REFUSAL_WHOLE_TEXT))

    def test_refuses_mid_word_cut(self):
        """"approve" cut as "ap" + "prove" -- splits one token. Red:
        expects REFUSAL_MID_WORD, stub says 'stub'."""
        text = "I approve"
        result = core.accept_cut(text, "prove")
        self.assertEqual(result, (False, core.REFUSAL_MID_WORD))

    def test_refuses_too_many_words(self):
        """Red: expects REFUSAL_TOO_MANY_WORDS, stub says 'stub'."""
        text = "I approve. This has been a long and winding road to approval."
        junk = " This has been a long and winding road to approval."
        self.assertTrue(text.endswith(junk))
        result = core.accept_cut(text, junk, max_words=8)
        self.assertEqual(result, (False, core.REFUSAL_TOO_MANY_WORDS))

    def test_refuses_share_too_high(self):
        """A 3-word suffix on a 5-word text is 60% > the 40% default share
        cap, even though it is under max_words. Red: expects
        REFUSAL_SHARE_TOO_HIGH, stub says 'stub'."""
        text = "Yes I think so"
        junk = " I think so"
        self.assertTrue(text.endswith(junk))
        result = core.accept_cut(text, junk, max_words=8, max_share=0.4)
        self.assertEqual(result, (False, core.REFUSAL_SHARE_TOO_HIGH))

    def test_refuses_no_sentence_remains(self):
        """Cutting leaves only punctuation tokens, no sentence -- and
        enough of them that word-share alone would not explain the
        refusal. Red: expects REFUSAL_NO_SENTENCE_REMAINS, stub says
        'stub'."""
        remainder = "... --- ... --- ... --- ... ---"
        junk = " Thank you."
        text = remainder + junk
        self.assertTrue(text.endswith(junk))
        result = core.accept_cut(text, junk)
        self.assertEqual(result, (False, core.REFUSAL_NO_SENTENCE_REMAINS))


class ObserveRecordTests(unittest.TestCase):
    def test_contains_no_substring_of_the_input_text(self):
        """Stub returns {} -> vacuously no leak. Not stub-caused red: this
        assertion already holds, for the wrong reason (nothing is there at
        all), which is exactly why the next test exists to prove the stub
        is not vacuously "correct"."""
        text = "Send the final draft to Brian before lunch please."
        record = core.observe_record(text, [], "clean", "", 1.2, core.MockJudge({}))
        for value in record.values():
            rendered = repr(value)
            for i in range(len(text) - 3):
                self.assertNotIn(text[i : i + 4], rendered)

    def test_has_lengths_flags_timings_shape(self):
        """Red: stub returns {}, missing every documented key."""
        text = "Send the final draft to Brian before lunch please."
        judge = core.MockJudge({"tail": "clean"})
        record = core.observe_record(
            text, [core.REASON_LOW_CONFIDENCE_TAIL], "junk", " please.", 3.5, judge
        )
        self.assertEqual(record["text_len"], len(text))
        self.assertEqual(record["reasons"], [core.REASON_LOW_CONFIDENCE_TAIL])
        self.assertEqual(record["verdict"], "junk")
        self.assertEqual(record["junk_suffix_len"], len(" please."))
        self.assertEqual(record["latency_ms"], 3.5)
        self.assertEqual(record["judge_name"], "MockJudge")


class CheckTests(unittest.TestCase):
    def _triggering_segments(self):
        return [
            _confident_segment(0.0, 5.0, "I approve."),
            {
                "start": 6.5,
                "end": 7.0,
                "raw_text": "Thank you.",
                "no_speech_prob": 0.3,
                "avg_logprob": -0.3,
                "compression_ratio": 1.0,
            },
        ]

    def test_observe_mode_never_changes_paste_text_even_when_judge_says_junk(self):
        """`paste_text == text` already holds against the stub (it always
        echoes `text` back). Red is in `flagged`/`record`: a validated junk
        verdict must set `flagged = True` and a non-empty record, which the
        stub never does."""
        text = "I approve. Thank you."
        segments = self._triggering_segments()
        judge = core.MockJudge({"tail": "junk", "junk_suffix": " Thank you."})
        result = core.check(text, segments, text, judge, mode="observe", timeout_ms=400)
        self.assertEqual(result["paste_text"], text)
        self.assertTrue(result["flagged"])
        self.assertTrue(result["record"])

    def test_trim_mode_cuts_an_accepted_junk_suffix(self):
        """Red: stub never trims, `paste_text` stays the full text."""
        text = "I approve. Thank you."
        segments = self._triggering_segments()
        judge = core.MockJudge({"tail": "junk", "junk_suffix": " Thank you."})
        result = core.check(text, segments, text, judge, mode="trim", timeout_ms=400)
        self.assertEqual(result["paste_text"], "I approve.")
        self.assertTrue(result["flagged"])

    def test_fail_open_when_judge_raises(self):
        """Red: `record` must note the failure; stub's record is always {}."""
        text = "I approve. Thank you."
        segments = self._triggering_segments()
        judge = core.MockJudge({}, raise_exc=RuntimeError("judge exploded"))
        result = core.check(text, segments, text, judge, mode="trim", timeout_ms=400)
        self.assertEqual(result["paste_text"], text)
        self.assertFalse(result["flagged"])
        self.assertTrue(result["record"])

    def test_fail_open_when_judge_exceeds_timeout(self):
        """Red: same reasoning as the raise case, via a slow judge instead."""
        text = "I approve. Thank you."
        segments = self._triggering_segments()
        judge = core.MockJudge({"tail": "junk", "junk_suffix": " Thank you."}, delay_ms=2000)
        result = core.check(text, segments, text, judge, mode="trim", timeout_ms=50)
        self.assertEqual(result["paste_text"], text)
        self.assertFalse(result["flagged"])
        self.assertTrue(result["record"])

    def test_check_bounds_context_to_last_two_sentences_and_a_char_cap(self):
        """Gate review vdtga-GJ finding (a): `check()`'s own contract must
        bound `context` to at most the last two sentences before the
        suspicious tail, AND to `core.MAX_CONTEXT_CHARS`, never the whole
        note -- the exact failure mode the project history treats as
        hardest-won (long audio, a repeat-loop tail). A spy judge records
        the (context, tail) it is actually asked about; this fixture
        makes any two consecutive sentences alone exceed the char cap, so
        passing requires BOTH bounds to be enforced for real, not just
        coincidentally satisfied by short fixture text.

        Red: the stub never calls the judge at all, so `spy.calls` stays
        empty and the first assertion fails."""
        padding_word = "stakeholder "
        words_needed = (core.MAX_CONTEXT_CHARS // 2) // len(padding_word) + 5

        def _long_sentence(marker: str) -> str:
            return f"{marker} " + padding_word * words_needed + "done."

        sentences = [_long_sentence(f"Sentence{i}") for i in range(40)]
        body = " ".join(sentences)
        tail_text = " ".join(["primarily"] * 8)
        text = f"{body} {tail_text}"
        segments = [
            _confident_segment(0.0, 200.0, body),
            {
                "start": 200.1,
                "end": 210.0,
                "raw_text": tail_text,
                "no_speech_prob": 0.05,
                "avg_logprob": -0.2,
                "compression_ratio": 1.0,
            },
        ]
        spy = SpyJudge({"tail": "clean"})
        core.check(text, segments, text, spy, mode="observe", timeout_ms=400)
        self.assertEqual(len(spy.calls), 1)
        context, tail = spy.calls[0]
        self.assertEqual(tail, tail_text)
        context_sentences = [
            s for s in re.split(r"(?<=[.!?])\s+", context.strip()) if s
        ]
        self.assertLessEqual(len(context_sentences), core.MAX_CONTEXT_SENTENCES)
        self.assertLessEqual(len(context), core.MAX_CONTEXT_CHARS)
        self.assertTrue(context.endswith(sentences[-1]))

    def test_no_trigger_means_no_judge_call(self):
        """A clean single-segment take must never even reach the judge.
        Stub already returns the input text unchanged with flagged False,
        so this particular assertion is not stub-caused red -- it is the
        `exploding` judge proving the judge was genuinely never called."""

        class ExplodingJudge:
            def answer(self, context, tail, timeout_ms):
                raise AssertionError("judge must not be called when trigger() is empty")

        text = "The fix that landed for the sticky note tabs looks pretty good."
        segments = [_confident_segment(0.0, 5.0, text)]
        result = core.check(text, segments, text, ExplodingJudge(), mode="trim")
        self.assertEqual(result["paste_text"], text)
        self.assertFalse(result["flagged"])


class BareSingleSegmentTrapTests(unittest.TestCase):
    """Gate review vdtga-GJ finding (d): the sharpest false-trim case the
    locked spec and this module's own docstring single out -- a bare
    repeated-word or outro-sounding phrase that is the WHOLE dictation,
    not softened into a longer sentence. `trigger` may or may not fire on
    these (not asserted either way -- the false-trim guarantee comes from
    `accept_cut`/`check`, per core.py's own module docstring); the one
    thing that must never happen is a cut, because the only possible cut
    here IS the whole text."""

    BARE_TRAPS = ("No, no, no.", "Very, very good.", "Yes.", "Thank you.", "Bye.")

    def test_accept_cut_refuses_the_whole_text_for_every_bare_trap(self):
        """Red: stub always returns (False, 'stub'), never
        (False, REFUSAL_WHOLE_TEXT)."""
        for bare in self.BARE_TRAPS:
            result = core.accept_cut(bare, bare)
            self.assertEqual(result, (False, core.REFUSAL_WHOLE_TEXT), bare)

    def test_check_never_cuts_a_bare_single_segment_trap_even_in_trim_mode(self):
        """Not stub-caused red today (the stub's `trigger` never fires, so
        `check` never even reaches `accept_cut`) -- stands as a standing
        guardrail against a later implementation that fires on these and
        then trusts a judge's whole-text cut proposal."""
        for bare in self.BARE_TRAPS:
            segments = [_confident_segment(0.0, 1.0, bare)]
            judge = core.MockJudge({"tail": "junk", "junk_suffix": bare})
            result = core.check(bare, segments, bare, judge, mode="trim", timeout_ms=400)
            self.assertEqual(result["paste_text"], bare, bare)


class KevClientTests(unittest.TestCase):
    def test_request_body_shape(self):
        """Red: stub returns {}, missing every documented key."""
        client = core.KevClient("http://127.0.0.1:0")
        body = client.request_body("I approve.", "Thank you.")
        self.assertEqual(
            body,
            {
                "context": "I approve.",
                "tail": "Thank you.",
                "task": "tail_check",
                "response_schema": {"tail": "clean|junk", "junk_suffix": "string"},
            },
        )

    def test_request_body_varies_with_its_arguments(self):
        """Hard-coding risk (gate review vdtga-GJ §4): the test above alone
        passes for a `request_body` that returns its expected dict
        verbatim, ignoring `context`/`tail` entirely. A SECOND, different
        pair must produce a correspondingly different body. Red: stub
        returns {} for every call."""
        client = core.KevClient("http://127.0.0.1:0")
        body = client.request_body("Let's ship it today.", "mmstuff")
        self.assertEqual(
            body,
            {
                "context": "Let's ship it today.",
                "tail": "mmstuff",
                "task": "tail_check",
                "response_schema": {"tail": "clean|junk", "junk_suffix": "string"},
            },
        )

    def test_package_source_has_no_network_imports(self):
        """No urllib/socket/http.client import anywhere in the shipped
        package source (test files excluded -- they legitimately need
        `socket` to monkeypatch it). Not stub-caused red: this is a
        standing guardrail for later links, and holds today because no
        such import exists at all."""
        import pathlib

        package_dir = pathlib.Path(__file__).parent
        pattern = re.compile(r"^\s*(import|from)\s+(urllib|socket|http\.client)\b")
        for path in sorted(package_dir.glob("*.py")):
            if path.name.startswith("test_"):
                continue
            for line in path.read_text().splitlines():
                self.assertFalse(
                    pattern.match(line),
                    f"{path.name} imports a networking module: {line.strip()!r}",
                )

    def test_tests_never_open_a_real_socket(self):
        """Monkeypatch socket.socket to raise, then exercise KevClient and
        the full check() pipeline; nothing in this package may ever touch
        a real socket."""
        original_socket = socket.socket

        def _forbidden(*args, **kwargs):
            raise AssertionError("tailcheck must never open a socket in tests")

        socket.socket = _forbidden
        try:
            client = core.KevClient("http://127.0.0.1:0")
            client.request_body("context", "tail")
            text = "The fix that landed for the sticky note tabs looks pretty good."
            segments = [_confident_segment(0.0, 5.0, text)]
            core.check(text, segments, text, core.MockJudge({"tail": "clean"}))
        finally:
            socket.socket = original_socket


if __name__ == "__main__":
    unittest.main()
