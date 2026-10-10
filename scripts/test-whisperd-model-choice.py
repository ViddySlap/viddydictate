#!/usr/bin/env python3
"""Deterministic gate for the whisperd model-choice helper (selectable Whisper versions, part 1).

Stdlib only: no mlx, no numpy, no network, no daemon process. The daemon's `_choose_model` is a
PURE helper -- it reads only the mapping and the file path it is handed -- so this proves the
env/file precedence and the offered-repo allowlist without reading the real environment or writing
the real `<Application Support>/ViddyDictate/whisper-model`.

How the choice reaches the daemon at START:
  * env `VIDDYDICTATE_WHISPER_MODEL`, if PRESENT (even empty), wins unchanged (it may be a local
    directory), matching the base daemon's `os.environ.get(key, default)`;
  * else the first line of the app's `whisper-model` file, only after removing the line ending
    (\\r and/or \\n) and only if the remaining content is a syntactically valid repo id AND one of
    the hard-coded offered repos;
  * else the default `mlx-community/whisper-large-v3-turbo`.

Labels: every row is `whisper-model: new: ...` (asserts NEW behaviour and MUST fail on the unfixed
daemon) or `whisper-model: guard: ...` (pins behaviour that is unchanged and passes on it).

RED before fix (observed with the daemon helper reverted to the BASE behaviour: `OFFERED_MODELS`
held only turbo, the environment used `env.get(key, DEFAULT_MODEL)`, and the choice file was never
read; run as `env -u VIDDYDICTATE_WHISPER_MODEL python3 scripts/test-whisperd-model-choice.py`):

  RED before fix: whisper-model: new: the offered list is exactly the four verified repos in default-first order | [whisper-model-choice] FAIL whisper-model: new: the offered list is exactly the four verified repos in default-first order (('mlx-community/whisper-large-v3-turbo',))
  RED before fix: whisper-model: new: no env and a valid offered file uses the file's first line | [whisper-model-choice] FAIL whisper-model: new: no env and a valid offered file uses the file's first line (mlx-community/whisper-large-v3-turbo)
  RED before fix: whisper-model: new: a space-padded file first line is not accepted as an offered repo | [whisper-model-choice] FAIL whisper-model: new: a space-padded file first line is not accepted as an offered repo (control=mlx-community/whisper-large-v3-turbo padded=mlx-community/whisper-large-v3-turbo)

Every other `guard:` row was observed PASSING on that same unfixed daemon (default repo, no-file/no-
env default, environment precedence, invalid-content fallback, traversal-looking fallback, non-
offered fallback, empty-file fallback, env over a non-offered file, and the empty-env held-out).
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import types

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
DAEMON_PATH = ROOT / "viddydictate_whisperd.py"
TAG = "[whisper-model-choice]"

TURBO = "mlx-community/whisper-large-v3-turbo"
LARGE_V3 = "mlx-community/whisper-large-v3-mlx"
LARGE_V2 = "mlx-community/whisper-large-v2-mlx"
LARGE_V1 = "mlx-community/whisper-large-mlx"
NOT_OFFERED = "mlx-community/whisper-medium-mlx"

FAILURES: list = []


def check(message: str, condition, detail: str = "") -> bool:
    if not isinstance(condition, bool):
        raise TypeError(f"check({message!r}, ...) needs a bool condition, got {type(condition).__name__}")
    print(f"{TAG} {'ok  ' if condition else 'FAIL'} {message}" + (f" ({detail})" if detail else ""))
    if not condition:
        FAILURES.append(message)
    return condition


def load_daemon() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("viddydictate_whisperd", DAEMON_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_choice(directory: str, contents: str) -> str:
    path = pathlib.Path(directory) / "whisper-model"
    path.write_text(contents, encoding="utf-8")
    return str(path)


def main() -> int:
    daemon = load_daemon()

    check("whisper-model: new: the offered list is exactly the four verified repos in default-first order",
          tuple(daemon.OFFERED_MODELS) == (TURBO, LARGE_V3, LARGE_V2, LARGE_V1),
          str(daemon.OFFERED_MODELS))
    check("whisper-model: guard: the default repo is Large V3 Turbo",
          daemon.DEFAULT_MODEL == TURBO, daemon.DEFAULT_MODEL)
    check("whisper-model: guard: importing the daemon with no file and no env keeps the default repo",
          daemon.MODEL == TURBO, daemon.MODEL)

    with tempfile.TemporaryDirectory() as tmp:
        choice = write_choice(tmp, LARGE_V2 + "\n")

        check("whisper-model: new: no env and a valid offered file uses the file's first line",
              daemon._choose_model(environ={}, choice_path=choice) == LARGE_V2,
              daemon._choose_model(environ={}, choice_path=choice))

        check("whisper-model: guard: env wins over a valid offered file (unchanged precedence)",
              daemon._choose_model(
                  environ={"VIDDYDICTATE_WHISPER_MODEL": "local/whisper-dir"},
                  choice_path=choice) == "local/whisper-dir")

        check("whisper-model: guard: a missing choice file falls back to the default",
              daemon._choose_model(environ={}, choice_path=str(pathlib.Path(tmp) / "nope")) == TURBO)

        write_choice(tmp, "not a repo at all\n")
        check("whisper-model: guard: an invalid file content is ignored and falls back to the default",
              daemon._choose_model(environ={}, choice_path=choice) == TURBO)

        write_choice(tmp, "organized/../escape\n")
        check("whisper-model: guard: a path-traversal-looking file content is ignored and falls back to the default",
              daemon._choose_model(environ={}, choice_path=choice) == TURBO)

        write_choice(tmp, NOT_OFFERED + "\n")
        check("whisper-model: guard: a valid but non-offered repo in the file is ignored and falls back to the default",
              daemon._choose_model(environ={}, choice_path=choice) == TURBO)
        check("whisper-model: guard: an env value still wins even when the file is non-offered",
              daemon._choose_model(
                  environ={"VIDDYDICTATE_WHISPER_MODEL": LARGE_V1},
                  choice_path=choice) == LARGE_V1)

        write_choice(tmp, "\n")
        check("whisper-model: guard: an empty file falls back to the default",
              daemon._choose_model(environ={}, choice_path=choice) == TURBO)

        # Held-out control (item 3): the environment key is present but empty. The BASE daemon
        # returns the empty value (`os.environ.get(key, default)`), so this is a guard: it pins that
        # an explicitly present empty value still wins over the choice file. The candidate's
        # truthiness test broke it by falling through to the file.
        write_choice(tmp, LARGE_V2 + "\n")
        empty_env = daemon._choose_model(
            environ={"VIDDYDICTATE_WHISPER_MODEL": ""}, choice_path=choice)
        check("whisper-model: guard: an explicitly present empty env value wins over a valid offered file",
              empty_env == "", f"got={empty_env!r}")

        # Held-out control (item 3): a space-padded first line is NOT a valid repo id, so it falls
        # back to the default. The valid-file control is included so the row also proves the file is
        # read at all; the BASE daemon ignores the file, so this is new, not a guard.
        valid_control = daemon._choose_model(environ={}, choice_path=choice)
        write_choice(tmp, " " + LARGE_V2 + " \n")
        padded = daemon._choose_model(environ={}, choice_path=choice)
        check("whisper-model: new: a space-padded file first line is not accepted as an offered repo",
              valid_control == LARGE_V2 and padded == TURBO,
              f"control={valid_control} padded={padded}")

    if FAILURES:
        print(f"{TAG}[FAIL] {len(FAILURES)} check(s) failed: " + "; ".join(FAILURES))
        return 1
    print(f"{TAG}[PASS] whisperd chooses env > offered file > default turbo, "
          "ignoring invalid and non-offered file content")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
