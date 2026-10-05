"""Protected tests for tailcheck.eval_set. Gate author: vdtga. Do not edit
to make a later link's implementation pass -- edit the implementation.

All text here is invented in this file; nothing is read from any corpus,
and `generate`/`run` are exercised against their documented real contract,
not their current stub behaviour.
"""

from __future__ import annotations

import unittest

import core
import eval_set


class GenerateTests(unittest.TestCase):
    def test_count_trap_share_and_determinism(self):
        """Red: stub returns [], so the count assertion fails first and
        names the stub. (The determinism assertion below would be
        vacuously true on two empty lists on its own -- it rides along
        with the count assertion so the test as a whole is red for the
        right reason, not for a reason that would survive a correct
        implementation returning a different list each call.)"""
        items = eval_set.generate(seed=0)
        clean_or_trap = [i for i in items if i["kind"] in ("clean", "trap")]
        self.assertGreaterEqual(len(clean_or_trap), 200)
        traps = [i for i in clean_or_trap if i["kind"] == "trap"]
        self.assertGreaterEqual(len(traps), len(clean_or_trap) * 0.5)
        self.assertEqual(eval_set.generate(seed=0), eval_set.generate(seed=0))

    def test_covers_every_family(self):
        """Red: stub returns [], so no family is covered."""
        items = eval_set.generate(seed=0)
        fabricated_families = {
            i["family"] for i in items if i["kind"] == "fabricated"
        }
        self.assertEqual(fabricated_families, set(core.ALL_REASONS))

    def test_no_trap_or_clean_text_collides_with_a_fabrication_suffix(self):
        """Fixture-quality guard, not a red/green test of `generate` per se:
        every trap/clean string the module ships must differ from every
        fabrication suffix, stripped or not, else a trap could be
        misjudged as a known fabrication by content alone -- EXCEPT the
        `bare_single_segment` family (gate review vdtga-GJ finding (d)): a
        bare whole-dictation "Thank you." is deliberately identical,
        stripped, to the `outro_filler_after_gap` suffix. For THAT family
        the distinguishing signal is structural, not lexical -- it is the
        single-segment WHOLE dictation, with nothing preceding it, so
        `check()`'s own context/tail split (see
        test_core.BareSingleSegmentTrapTests) never has real content to
        confuse with a fabrication's preceding speech. A content-only
        collision there is the deliberately sharp case being tested, not
        a defect this guard should catch."""
        suffixes = set()
        for variants in eval_set.FABRICATION_SUFFIXES_BY_FAMILY.values():
            for suffix in variants:
                suffixes.add(suffix)
                suffixes.add(suffix.strip())
        for family, variants in eval_set._TRAP_FAMILIES.items():
            if family == "bare_single_segment":
                continue
            for text in variants:
                self.assertNotIn(text, suffixes)
                self.assertNotIn(text.strip(), suffixes)

    def test_bare_single_segment_trap_family_present(self):
        """Gate review vdtga-GJ finding (d): the bare, whole-dictation
        single-segment trap ("No, no, no.", "Very, very good.", "Yes.",
        "Thank you.", "Bye.") must be a real fixture `generate()` can draw
        from, not just described in prose. Red: the family does not exist
        in `_TRAP_FAMILIES` yet."""
        self.assertIn("bare_single_segment", eval_set._TRAP_FAMILIES)
        self.assertEqual(
            set(eval_set._TRAP_FAMILIES["bare_single_segment"]),
            {"No, no, no.", "Very, very good.", "Yes.", "Thank you.", "Bye."},
        )

    def test_seed_changes_output_but_not_shape(self):
        """Gate review vdtga-GJ finding (c): the existing determinism
        assertion only checks `generate(0) == generate(0)`, which a
        `generate` that ignores `seed` entirely (always returning the same
        hardcoded list) would also satisfy. Different seeds must produce a
        DIFFERENT item list, while each seed stays internally deterministic
        and keeps the same counts/ratios.

        Red (for the right reason): the stub returns `[]` for every seed,
        so `items_0a` and `items_1` are both `[]` -- equal -- and
        `assertNotEqual` fails, exactly the defect this test exists to
        catch."""
        items_0a = eval_set.generate(seed=0)
        items_0b = eval_set.generate(seed=0)
        items_1a = eval_set.generate(seed=1)
        items_1b = eval_set.generate(seed=1)
        self.assertEqual(items_0a, items_0b)
        self.assertEqual(items_1a, items_1b)
        self.assertNotEqual(items_0a, items_1a)

        def _counts(items: list[dict]) -> tuple[int, int, int]:
            clean_or_trap = [i for i in items if i["kind"] in ("clean", "trap")]
            traps = [i for i in clean_or_trap if i["kind"] == "trap"]
            fabricated = [i for i in items if i["kind"] == "fabricated"]
            return len(clean_or_trap), len(traps), len(fabricated)

        self.assertEqual(_counts(items_0a), _counts(items_1a))


def _fabricated_item(item_id: str, family: str, body: str) -> dict:
    suffix = eval_set.FABRICATION_SUFFIXES_BY_FAMILY[family][0]
    return {
        "id": item_id,
        "kind": "fabricated",
        "family": family,
        "text": body + suffix,
        "expected_junk_suffix": suffix,
    }


def _clean_item(item_id: str, text: str) -> dict:
    return {"id": item_id, "kind": "clean", "family": None, "text": text, "expected_junk_suffix": ""}


def _trap_item(item_id: str, family: str, text: str) -> dict:
    return {"id": item_id, "kind": "trap", "family": family, "text": text, "expected_junk_suffix": ""}


def _build_items() -> list[dict]:
    body = "I reviewed the draft and I approve"
    items = [
        _clean_item("clean-1", "The fix that landed for the sticky note tabs looks pretty good."),
        _clean_item("clean-2", "The export script is ready to ship today."),
        _trap_item("trap-real-repetition", "real_repetition", "No, no, no, that is not what I meant at all."),
        _trap_item("trap-one-word", "one_word_affirmative", "Yes."),
        _trap_item("trap-signoff", "email_signoff", "Thanks again, talk soon."),
    ]
    for family in core.ALL_REASONS:
        items.append(_fabricated_item(f"fab-{family}", family, body))
    return items


class OracleJudge:
    """A test oracle: knows the ground truth for every item in `items` and
    answers accordingly, regardless of how `run` phrases `tail` (stripped
    or with the leading separator space the fabrication suffixes carry)."""

    def __init__(self, items: list[dict]):
        self._lookup: dict[str, dict] = {}
        for item in items:
            if item["kind"] == "fabricated":
                suffix = item["expected_junk_suffix"]
                answer = {"tail": "junk", "junk_suffix": suffix}
                self._lookup[suffix] = answer
                self._lookup[suffix.strip()] = answer
            else:
                self._lookup[item["text"]] = {"tail": "clean"}

    def answer(self, context: str, tail: str, timeout_ms: int) -> dict:
        return self._lookup.get(tail, {"tail": "clean"})


class AdversarialJudge:
    """Always proposes an unsafe cut: alternately a whole-text cut attempt
    and a body-edit attempt (a middle slice of `context`, not a suffix at
    all). `accept_cut`'s rules must refuse every single one."""

    def __init__(self) -> None:
        self._count = 0

    def answer(self, context: str, tail: str, timeout_ms: int) -> dict:
        self._count += 1
        if self._count % 2 == 1:
            return {"tail": "junk", "junk_suffix": (context + " " + tail).strip()}
        midpoint = len(context) // 2
        return {"tail": "junk", "junk_suffix": context[:midpoint] or "x"}


class AlwaysCleanJudge:
    """Always answers clean, regardless of `context`/`tail`. Hard-coding
    risk (gate review vdtga-GJ §4): proves `run()` actually threads its
    `judge` argument through to `core.check` rather than returning a
    fixed tally -- an `OracleJudge` alone cannot catch a `run()` that
    ignores `judge` entirely, since the fixed tally could happen to equal
    the oracle's own correct result."""

    def answer(self, context: str, tail: str, timeout_ms: int) -> dict:
        return {"tail": "clean"}


class RunTests(unittest.TestCase):
    def test_output_shape(self):
        """Red: stub returns {}, missing every documented key."""
        items = _build_items()
        result = eval_set.run(OracleJudge(items), items)
        for key in ("false_trims", "caught", "missed", "clean_ok", "total"):
            self.assertIn(key, result)
        self.assertEqual(result["total"], len(items))

    def test_oracle_judge_zero_false_trims_and_catches_all_fabrications(self):
        """Red: stub returns {}; the real implementation must reach
        false_trims == 0 and catch every fabricated item with a perfect
        judge."""
        items = _build_items()
        fabricated_count = sum(1 for i in items if i["kind"] == "fabricated")
        result = eval_set.run(OracleJudge(items), items)
        self.assertEqual(result["false_trims"], 0)
        self.assertEqual(result["caught"], fabricated_count)
        self.assertEqual(result["missed"], 0)

    def test_adversarial_judge_still_zero_false_trims(self):
        """Red: stub returns {}; proves the SAFETY (accept_cut's rules),
        not the catch rate, survives a judge arguing in bad faith for
        whole-text cuts and body edits."""
        items = _build_items()
        result = eval_set.run(AdversarialJudge(), items)
        self.assertEqual(result["false_trims"], 0)

    def test_run_result_varies_with_which_judge_is_passed(self):
        """Hard-coding risk (gate review vdtga-GJ §4): a `run()` that
        ignores its `judge` argument and unconditionally returns one fixed
        tally would pass every `RunTests` case above unchanged, since none
        of them compares results ACROSS judges. An oracle must catch every
        fabrication; an always-clean judge must catch none.

        Red: the stub returns `{}` for every call, so both results raise
        `KeyError` rather than genuinely differing."""
        items = _build_items()
        fabricated_count = sum(1 for i in items if i["kind"] == "fabricated")
        oracle_result = eval_set.run(OracleJudge(items), items)
        clean_judge_result = eval_set.run(AlwaysCleanJudge(), items)
        self.assertEqual(oracle_result["caught"], fabricated_count)
        self.assertEqual(clean_judge_result["caught"], 0)
        self.assertEqual(clean_judge_result["missed"], fabricated_count)
        self.assertNotEqual(oracle_result["caught"], clean_judge_result["caught"])

    def test_oracle_and_adversarial_judges_on_the_real_generated_set(self):
        """Gate review vdtga-GJ finding (b): every `RunTests` case above
        exercises the hand-built 11-item `_build_items()` fixture, never
        `eval_set.generate()`'s actual >=200-item output -- so nothing in
        the protected suite proves that wiring `run()` to the REAL
        generated set holds the design S4 acceptance bar (false trims: 0,
        catch >= 90%). This wires them together for real.

        Red: the stub `generate()` returns `[]` (so `fabricated_count` is
        0) and the stub `run()` returns `{}` for both judges, raising
        `KeyError` rather than reaching the asserted bar."""
        items = eval_set.generate(seed=0)
        fabricated_count = sum(1 for i in items if i["kind"] == "fabricated")
        oracle_result = eval_set.run(OracleJudge(items), items)
        self.assertEqual(oracle_result["false_trims"], 0)
        self.assertGreaterEqual(oracle_result["caught"], fabricated_count * 0.9)
        adversarial_result = eval_set.run(AdversarialJudge(), items)
        self.assertEqual(adversarial_result["false_trims"], 0)


if __name__ == "__main__":
    unittest.main()
