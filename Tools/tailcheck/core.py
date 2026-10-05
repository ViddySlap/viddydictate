"""tailcheck.core — the tail-check contract (STUB, gate author: vdtga).

Boxx-side prototype for the end-of-recording-hallucination semantic judge
(design note Option B): "Trailing-gibberish check on every dictation"
`Projects/viddydictate/notes/trailing-gibberish-check-design-20261003.md`,
section 2A (trigger), section 2B (accept-cut rules), section 4 (eval/acceptance
bar), and the 2026-10-05 UPDATE (local judge, judge-agnostic client).

Every function below is a STUB: the signature is FINAL, the behaviour is NOT.
Each stub returns a wrong or neutral answer on purpose, so that
`test_core.py` is red for a named reason rather than erroring on import.
Later links implement against this contract; they must not change these
signatures, and must not touch `test_core.py` (protected).

Background a later implementer must respect, from the project's locked
history (`specs/2026-08-14-tail-hallucination.md`,
`wiki/reference/model-selection.md` findings 9-13):

- Five structural filters already failed to separate fabricated tails from
  real speech on literal scores (duration clock, raw repeat+compression
  ratio, the vendor's own `hallucination_silence_threshold`, a prompt-
  ablation oracle). This prototype does NOT repeat that approach: `trigger`
  below is a high-recall gate that decides whether to ASK A JUDGE, never a
  verdict by itself (design note S2A). The judge supplies precision;
  `accept_cut` supplies the safety net under the judge.
- Six of seven real promptly-ended takes decode as a SINGLE segment, and a
  real human repeating a word for real ("no no no", "very very good") is
  the obvious false positive a reviewer must go looking for. `trigger` is
  therefore allowed to fire on a single confident segment that merely LOOKS
  like a trap (repetition, lone punctuation) -- the false-trim guarantee
  comes from `accept_cut` and the judge, never from `trigger` being
  conservative. The one case `trigger` must never fire on is an ordinary,
  unremarkable, single-segment CLEAN take with nothing suspicious in it.
- Never assert on literal fabricated text (temperature fallback makes it
  nondeterministic across processes); assert structurally.
- "Trim, never rewrite": the app enforces the cut-acceptance rules in code;
  the judge only proposes. Fail-open on any doubt, including timeout.

Segment dict contract (one entry per diagnostic record the daemon already
produces in `_clean_segments`, see `viddydictate_whisperd.py`, BEFORE
`_collapse_repeats` runs and before any guard drops anything):

    {
        "start": float,              # seconds, absolute
        "end": float,                # seconds, absolute
        "raw_text": str,             # this segment's decoded text, pre-collapse
        "no_speech_prob": float,
        "avg_logprob": float,
        "compression_ratio": float,
    }

`raw_text` (the module-level parameter, distinct from a segment's own
`raw_text` field) is the full transcript text as the daemon returns it:
post whisper-level cleanup/collapse, PRE cleanup-LLM (L1/L2). `final_text`
is the text as it stands right before paste, i.e. after the cleanup LLM.
On a take the cleanup LLM did not touch, `raw_text == final_text`.
"""

from __future__ import annotations

import re
from typing import Any, Optional, Protocol

# --- trigger reason vocabulary (design note S1 / S2A) -----------------------
#
# Fixed, finite vocabulary. These strings are the only values `trigger` may
# return, and `observe_record` treats them (and `verdict` strings below) as
# safe to log verbatim: they never carry dictation content.

REASON_OUTRO_FILLER_AFTER_GAP = "outro_filler_after_gap"
REASON_DOUBLED_TOKEN = "doubled_token"
REASON_REPEAT_LOOP = "repeat_loop"
REASON_LONE_PUNCTUATION_TAIL = "lone_punctuation_tail"
REASON_LOW_CONFIDENCE_TAIL = "low_confidence_tail"
REASON_CLEANUP_ADDED_SUFFIX = "cleanup_added_suffix"

ALL_REASONS = (
    REASON_OUTRO_FILLER_AFTER_GAP,
    REASON_DOUBLED_TOKEN,
    REASON_REPEAT_LOOP,
    REASON_LONE_PUNCTUATION_TAIL,
    REASON_LOW_CONFIDENCE_TAIL,
    REASON_CLEANUP_ADDED_SUFFIX,
)

# --- accept_cut refusal vocabulary (design note S2B) -------------------------

REFUSAL_NOT_SUFFIX = "not_suffix"
REFUSAL_BODY_EDIT = "body_edit"
REFUSAL_WHOLE_TEXT = "whole_text"
REFUSAL_MID_WORD = "mid_word"
REFUSAL_TOO_MANY_WORDS = "too_many_words"
REFUSAL_SHARE_TOO_HIGH = "share_too_high"
REFUSAL_NO_SENTENCE_REMAINS = "no_sentence_remains"
ACCEPTED = "accepted"

# --- tunable thresholds (provisional; a later link tunes against measurement,
# per the design note's own "tune against measurement, not intuition" rule
# carried over from the locked spec) ------------------------------------------

GAP_THRESHOLD_S = 0.8
"""Minimum silent gap, in seconds, between the previous segment's end and the
last segment's start, before the outro-filler-after-gap family can fire."""

DOUBLED_TOKEN_MAX_WORDS = 4
"""A doubled-token tail is short: at most this many words total."""

REPEAT_LOOP_MIN_RUN = 6
"""Minimum consecutive repeats of one token before `repeat_loop` fires.
Set well above a real doubled or tripled word (e.g. "no no no" = 3) so that
genuine emphatic repetition in the trap set does not collide with this
family; the judge, not this threshold, carries the false-trim guarantee."""

NOSPEECH_TRIGGER = 0.5
LOGPROB_TRIGGER = -1.0
"""Mirrors the daemon's own `_clean_segments` guard
(`nsp > NOSPEECH_THOLD and alp < LOGPROB_THOLD`, gated on `not single`):
low confidence on the LAST segment only matters when there is more than one
segment, which is exactly the single-segment safety floor this prototype
must not cross."""

OUTRO_PHRASES = frozenset(
    {
        "thank you",
        "thanks",
        "thanks for watching",
        "we will be right back",
        "we will see you next week",
        "bye",
        "goodbye",
    }
)
"""Known outro-filler phrase family (design note S1). Never extended into a
general word blocklist (model-selection finding 9: the filler's identity is
a function of the bias prompt, so any blocklist is permanently one
dictionary edit behind) -- it exists only to raise recall for the
outro-filler-after-gap trigger, never as a verdict by itself."""

_PUNCT_ONLY = re.compile(r"^[^\w]+$", re.UNICODE)


def _depunctuate(text: str) -> str:
    return re.sub(r"[^\w\s]", "", text).strip().lower()


def trigger(segments: list[dict], raw_text: str, final_text: str) -> list[str]:
    """Decide whether the tail is worth asking a judge about. Never a verdict.

    Real contract (to implement against; current body is a stub returning
    `[]` unconditionally):

    Returns the subset of `ALL_REASONS` that fire, in no particular order,
    `[]` if none do. `segments` is the ordered, pre-collapse per-segment
    diagnostic list described in the module docstring; it may be empty (no
    segments at all) or have exactly one entry (the common case: six of
    seven real safety takes are single-segment).

    Each reason's firing condition:

    - `outro_filler_after_gap`: there are >= 2 segments, AND the gap between
      the second-to-last segment's `end` and the last segment's `start` is
      > `GAP_THRESHOLD_S`, AND the last segment's `raw_text`, depunctuated
      and lowercased, is a member of `OUTRO_PHRASES`.
    - `doubled_token`: the last segment's `raw_text`, split on whitespace,
      has <= `DOUBLED_TOKEN_MAX_WORDS` words AND its last two tokens are
      equal case-insensitively (the raw, pre-collapse doubling that
      `_collapse_repeats` would otherwise launder -- model-selection
      finding 9 / finding 5 in the locked spec).
    - `repeat_loop`: the last segment's `raw_text` contains one token
      repeated >= `REPEAT_LOOP_MIN_RUN` times consecutively.
    - `lone_punctuation_tail`: the last segment's `raw_text`, stripped, is
      non-empty and matches no word characters at all (`_PUNCT_ONLY`).
    - `low_confidence_tail`: there are >= 2 segments (the single-segment
      safety floor: this signal never applies to the common promptly-ended
      case), AND the last segment's `no_speech_prob > NOSPEECH_TRIGGER` OR
      `avg_logprob < LOGPROB_TRIGGER`.
    - `cleanup_added_suffix`: `final_text != raw_text`, AND `final_text`
      starts with `raw_text` exactly (the body is untouched), AND
      `len(final_text) > len(raw_text)` (there is genuinely new trailing
      content appended, not a body edit or a pure deletion).

    An ordinary, unremarkable, single-segment clean take -- the hard safety
    case from the locked spec's Corpus B -- must trigger none of the above.
    """
    return []


def accept_cut(
    text: str,
    junk_suffix: str,
    boundaries: Optional[list[int]] = None,
    max_words: int = 8,
    max_share: float = 0.4,
) -> tuple[bool, str]:
    """App-enforced cut-acceptance rules (design note S2B). The judge only
    proposes `junk_suffix`; this function is the only thing allowed to
    decide whether the proposal is safe to act on. Current body is a stub
    that always refuses with reason `"stub"`.

    Real contract: returns `(True, ACCEPTED)` only if ALL of the following
    hold, checked in this order (earlier checks take priority, so each
    negative control below maps to exactly one refusal reason):

    1. `junk_suffix == text` -> refuse `REFUSAL_WHOLE_TEXT` (cutting would
       remove the entire take).
    2. `text` does not end with `junk_suffix` ->
       - if `junk_suffix` is non-empty and appears as a substring of `text`
         somewhere OTHER than at the very end, refuse `REFUSAL_BODY_EDIT`
         (the judge is pointing at interior content, not a trailing cut --
         a stronger violation than ordinary non-suffix noise);
       - otherwise refuse `REFUSAL_NOT_SUFFIX` (the proposed suffix does
         not relate to `text` at all -- e.g. fabricated/hallucinated by the
         judge itself).
    3. Let `cut_point = len(text) - len(junk_suffix)`. The cut SPLITS A
       TOKEN only if `cut_point > 0` AND `text[cut_point - 1]` is
       alphanumeric AND `text[cut_point]` is alphanumeric (both neighbours
       of the cut belong to the same contiguous token). The cut lands on a
       boundary if it does NOT split a token, OR `boundaries` is given and
       `cut_point in boundaries` (a known segment start from the daemon's
       diagnostics -- "preferably ... a segment boundary", design note S2B
       rule 2, is an alternative way to satisfy this same rule, not an
       extra mandatory one). If neither holds, refuse `REFUSAL_MID_WORD`.
    4. `len(junk_suffix.split()) > max_words` -> refuse
       `REFUSAL_TOO_MANY_WORDS`.
    5. `len(junk_suffix.split()) / max(1, len(text.split())) > max_share`
       -> refuse `REFUSAL_SHARE_TOO_HIGH`.
    6. The remainder `text[:cut_point]`, stripped, is empty or contains no
       alphanumeric character at all -> refuse `REFUSAL_NO_SENTENCE_REMAINS`
       (design note S2B rule 4: at least one non-empty sentence must
       remain).
    7. Otherwise accept: `(True, ACCEPTED)`.

    `boundaries=None` simply removes that one alternative from rule 3; the
    whitespace/punctuation form of the boundary check is still available
    and is independent of `boundaries`.
    """
    return False, "stub"


def observe_record(
    text: str,
    reasons: list[str],
    verdict: str,
    junk_suffix: str,
    latency_ms: float,
    judge: Any,
) -> dict:
    """Build the observe-only log record. MUST NEVER contain dictation
    text or any substring of it (design note S4, observe-only mode: "no
    text leaves the Mac"). Current body is a stub that always returns `{}`.

    Real contract: returns a dict with ONLY lengths, flags, and timings,
    for example (exact key set is this implementation's choice to make,
    but no value may ever be or contain a substring of `text` of length
    >= 4):

        {
            "text_len": len(text),
            "reasons": list(reasons),          # fixed-vocabulary strings only
            "verdict": verdict,                # fixed-vocabulary string only
            "junk_suffix_len": len(junk_suffix),
            "latency_ms": latency_ms,
            "judge_name": type(judge).__name__,
        }

    `reasons` and `verdict` are safe to store verbatim because they are
    drawn from `ALL_REASONS` / a small fixed set of outcome labels, never
    derived from `text`'s content. `judge_name` is a class name, never the
    judge's actual answer payload (which could echo dictation content back).
    """
    return {}


class Judge(Protocol):
    """Judge-agnostic interface (2026-10-05 UPDATE): a resident local model
    (Kev) or a test double, both answer the same fixed contract."""

    def answer(self, context: str, tail: str, timeout_ms: int) -> dict:
        """Return `{"tail": "clean"} or {"tail": "junk", "junk_suffix": <exact
        trailing substring of `context + tail`, or of `tail`, per the
        caller's convention>}`. May raise, or run past `timeout_ms`; the
        caller (`check`) must fail open in either case."""
        ...


class MockJudge:
    """Test double. Returns a fixed `answer` dict on every call, optionally
    after `delay_ms`, optionally raising `raise_exc` instead of answering."""

    def __init__(
        self,
        answer: dict,
        delay_ms: float = 0.0,
        raise_exc: Optional[BaseException] = None,
    ) -> None:
        self._answer = answer
        self._delay_ms = delay_ms
        self._raise_exc = raise_exc

    def answer(self, context: str, tail: str, timeout_ms: int) -> dict:
        if self._raise_exc is not None:
            raise self._raise_exc
        if self._delay_ms:
            import time

            time.sleep(self._delay_ms / 1000.0)
        return dict(self._answer)


class KevClient:
    """Judge-agnostic client stub for Kev's `/v1/systemone` wire shape
    (2026-10-05 UPDATE: `jaredpalmer/kev`, a self-hosted drop-in for Jev's
    `/v1/systemone`). Installing Kev is a later go (house rules: install
    nothing); this client builds a request body ONLY and makes NO network
    call anywhere in this package -- there is deliberately no `urllib`,
    `socket`, or `http.client` import in this module or anywhere else in
    `tailcheck`, and `request_body` never opens a connection.

    The exact body shape below is a placeholder pending Kev's actual
    `/v1/systemone` docs (unavailable without a network fetch from here);
    a later link finalizes it against the installed service, without
    changing this class's two public names (`base_url`, `request_body`).
    """

    def __init__(self, base_url: str) -> None:
        self.base_url = base_url

    def request_body(self, context: str, tail: str) -> dict:
        """Stub: returns `{}`. Real contract: returns exactly

            {
                "context": context,
                "tail": tail,
                "task": "tail_check",
                "response_schema": {"tail": "clean|junk", "junk_suffix": "string"},
            }

        -- a plain JSON-serializable dict, no network call involved in
        building it."""
        return {}


def check(
    text: str,
    segments: list[dict],
    raw_text: str,
    judge: Judge,
    mode: str = "observe",
    timeout_ms: int = 400,
) -> dict:
    """The whole pipeline for one dictation, right before paste. Current
    body is a stub: always returns `text` unchanged, never flagged, with an
    empty record.

    Real contract:

        {
            "paste_text": str,   # == text UNLESS mode == "trim" and a cut
                                  # was accepted
            "flagged": bool,     # True iff a cut was judged junk AND
                                  # accept_cut would accept it (independent
                                  # of mode -- lets observe-only surface
                                  # what WOULD be trimmed)
            "record": dict,      # observe_record(...) output
        }

    Steps:

    1. `reasons = trigger(segments, raw_text, text)`. If `reasons == []`:
       no judge call. `paste_text = text`, `flagged = False`,
       `record = observe_record(text, [], "no_trigger", "", 0.0, judge)`.
    2. Otherwise, derive `context` and `tail` from `text` (== `final_text`
       in `trigger`'s sense). When `reasons` contains anything other than
       only `REASON_CLEANUP_ADDED_SUFFIX`, the suspicious tail is the last
       segment's span: `tail = segments[-1]["raw_text"]`, `context = text`
       with that span removed from the end. When `reasons ==
       [REASON_CLEANUP_ADDED_SUFFIX]` (the cleanup LLM added trailing
       content whisper never produced, so no segment covers it), `tail =
       text[len(raw_text):]` and `context = raw_text`. Either way, bounded
       by the time budget: call `judge.answer(context, tail, timeout_ms)`
       inside a hard wall-clock bound of `timeout_ms` (stdlib-only, e.g.
       `concurrent.futures.ThreadPoolExecutor(1).submit(...).result(timeout=...)`).
       On `TimeoutError` or any exception from the judge: FAIL OPEN --
       `paste_text = text` (unchanged, regardless of `mode`), `flagged =
       False`, `record` notes the failure (e.g. `verdict="timeout"` or
       `verdict="error"`), via `observe_record`.
    3. If the judge answers `{"tail": "clean"}` (or anything other than a
       well-formed junk answer): `paste_text = text`, `flagged = False`,
       `record` via `observe_record(..., verdict="clean", ...)`.
    4. If the judge answers `{"tail": "junk", "junk_suffix": s}`: call
       `accept_cut(text, s, boundaries=<derived from segments>)`.
       - If refused: `paste_text = text`, `flagged = False` (the judge said
         junk, but the app rules do not trust the specific proposal).
       - If accepted: `flagged = True` always; `paste_text = text` with `s`
         removed from the end ONLY if `mode == "trim"`, else `paste_text =
         text` unchanged (observe-only never edits what gets pasted, by
         construction, regardless of what the judge or accept_cut decided).
       `record` via `observe_record(..., verdict="junk", junk_suffix=s, ...)`.

    `mode` is one of `"observe"` (default, never edits `paste_text`) or
    `"trim"` (may edit `paste_text` when a cut is accepted). There is no
    third mode: the HUD-flag-only rollout (2026-10-05 UPDATE) ships
    `"observe"` first.
    """
    return {"paste_text": text, "flagged": False, "record": {}}
