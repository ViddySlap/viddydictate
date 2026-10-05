"""Protected tests for tailcheck.prompt_ablation. Gate author: vdtga.

The fixture below is entirely synthetic (invented numbers and text, never
a real decode), matching the `decodes_json` schema documented in
`prompt_ablation.py`. It never calls a decoder and never touches audio.
"""

from __future__ import annotations

import unittest

import prompt_ablation


def _fixture() -> dict:
    return {
        "corpus_a": {
            "take1": {
                "full": {
                    "segments": [
                        {"start": 0.0, "end": 5.0, "text": "body"},
                        {"start": 5.0, "end": 6.0, "text": "Thank you."},
                    ],
                    "speech_end_s": 4.8,
                },
                "short": {
                    "segments": [
                        {"start": 0.0, "end": 5.0, "text": "body"},
                        {"start": 5.0, "end": 5.5, "text": "Bye."},
                    ],
                    "speech_end_s": 4.8,
                },
                "none": {
                    "segments": [{"start": 0.0, "end": 4.8, "text": "body"}],
                    "speech_end_s": 4.8,
                },
            }
        },
        "corpus_b": {
            "take1": {
                "full": {
                    "segments": [{"start": 0.0, "end": 1.0, "text": "I appro"}],
                    "expected_last_text": "I approve.",
                },
                "short": {
                    "segments": [{"start": 0.0, "end": 1.0, "text": "I approve."}],
                    "expected_last_text": "I approve.",
                },
                "none": {
                    "segments": [{"start": 0.0, "end": 1.0, "text": "I approve."}],
                    "expected_last_text": "I approve.",
                },
            }
        },
    }


def _second_fixture() -> dict:
    return {
        "corpus_a": {
            "take2": {
                "full": {
                    "segments": [{"start": 0.0, "end": 3.0, "text": "body"}],
                    "speech_end_s": 3.0,
                },
                "short": {
                    "segments": [
                        {"start": 0.0, "end": 3.0, "text": "body"},
                        {"start": 3.0, "end": 3.4, "text": "Bye."},
                    ],
                    "speech_end_s": 3.0,
                },
                "none": {
                    "segments": [
                        {"start": 0.0, "end": 3.0, "text": "body"},
                        {"start": 3.0, "end": 3.2, "text": "um"},
                    ],
                    "speech_end_s": 3.0,
                },
            }
        },
        "corpus_b": {
            "take2": {
                "full": {
                    "segments": [{"start": 0.0, "end": 1.0, "text": "Confirmed."}],
                    "expected_last_text": "Confirmed.",
                },
                "short": {
                    "segments": [{"start": 0.0, "end": 1.0, "text": "Confirme"}],
                    "expected_last_text": "Confirmed.",
                },
                "none": {
                    "segments": [{"start": 0.0, "end": 1.0, "text": "Confirmed."}],
                    "expected_last_text": "Confirmed.",
                },
            }
        },
    }


class RunTests(unittest.TestCase):
    def test_per_variant_metrics_on_a_fake_decodes_fixture(self):
        """Red: stub returns {}, missing every variant/key.

        `full` loses the fabricated tail nowhere (present on both full and
        short) and loses real speech once (corpus B's `full` variant
        truncates "I approve." to "I appro"); `none` is the only variant
        that is clean on corpus A.
        """
        result = prompt_ablation.run(_fixture())
        self.assertEqual(
            result,
            {
                "full": {
                    "fabricated_tail_present": 1,
                    "fabricated_tail_total": 1,
                    "last_segment_preserved": 0,
                    "last_segment_total": 1,
                },
                "short": {
                    "fabricated_tail_present": 1,
                    "fabricated_tail_total": 1,
                    "last_segment_preserved": 1,
                    "last_segment_total": 1,
                },
                "none": {
                    "fabricated_tail_present": 0,
                    "fabricated_tail_total": 1,
                    "last_segment_preserved": 1,
                    "last_segment_total": 1,
                },
            },
        )

    def test_per_variant_metrics_on_a_second_fake_decodes_fixture(self):
        """Hard-coding risk (gate review vdtga-GJ §4): the test above alone
        passes for a `run()` that returns its expected dict unconditionally,
        ignoring `decodes_json`. This SECOND, differently-shaped fixture
        (`full` is clean on corpus A here; `short` loses the tail this
        time; corpus B's `short` variant, not `full`, is the one that
        truncates) has a per-variant result that differs from the first
        fixture's for every variant, so it catches that hard-coded return.

        Red: stub returns {} regardless of fixture."""
        result = prompt_ablation.run(_second_fixture())
        self.assertEqual(
            result,
            {
                "full": {
                    "fabricated_tail_present": 0,
                    "fabricated_tail_total": 1,
                    "last_segment_preserved": 1,
                    "last_segment_total": 1,
                },
                "short": {
                    "fabricated_tail_present": 1,
                    "fabricated_tail_total": 1,
                    "last_segment_preserved": 0,
                    "last_segment_total": 1,
                },
                "none": {
                    "fabricated_tail_present": 1,
                    "fabricated_tail_total": 1,
                    "last_segment_preserved": 1,
                    "last_segment_total": 1,
                },
            },
        )

    def test_never_decodes_audio_itself(self):
        """Source-level guard: this module must stay pure given already-
        decoded JSON, never a decoder/audio dependency. Checks actual
        import statements only (prose in the module's own docstring is
        free to name "whisper" when describing what feeds it). Not
        stub-caused red: holds today because the stub imports nothing of
        the sort."""
        import pathlib
        import re

        source = pathlib.Path(prompt_ablation.__file__).read_text()
        pattern = re.compile(
            r"^\s*(import|from)\s+(whisper|wave|audioop|soundfile|mlx_whisper)\b",
            re.MULTILINE,
        )
        self.assertIsNone(pattern.search(source))


if __name__ == "__main__":
    unittest.main()
