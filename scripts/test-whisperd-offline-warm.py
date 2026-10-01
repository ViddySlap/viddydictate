#!/usr/bin/env python3
"""Pins the offline-first warm of the speech daemon, with negative controls.

The incident this guards: on a user's Mac the daemon took 306.9 s to warm instead of about one
second. The app retried silently ("daemon not ready") and the user saw dictation as broken. The warm
handed mlx_whisper the Hugging Face REPO ID, so mlx_whisper's load_model called snapshot_download,
and snapshot_download asks huggingface.co for repo info with no timeout BEFORE it looks at the local
cache. Right after the Mac woke from sleep, that request stalled the warm for five minutes while the
model sat complete on disk.

The fix resolves the local snapshot directory itself (pure path reads), sets HF_HUB_OFFLINE=1 before
huggingface_hub is imported, and hands mlx_whisper the LOCAL PATH, which its loader uses directly.

What this gate asserts, with no mlx, no numpy and no huggingface_hub installed (it runs on any host):
  (a) a complete fake hub cache resolves to its snapshot directory, by huggingface_hub's own cache
      precedence, including the symlinked blob layout and the app's own model-cache;
  (b) an incomplete snapshot (no weights, empty weights, a dangling blob link, no refs/main) is None;
  (c) the REAL warm path, with stub mlx_whisper/numpy modules whose loader mirrors mlx-whisper 0.4.3's
      load_model, under a socket guard that raises on ANY connect or getaddrinfo, finishes in under
      2 s, hands the loader the local path, makes zero network attempts, imports mlx_whisper with
      HF_HUB_OFFLINE=1 already set, and transcribe reuses the exact string the warm primed;
  (d) /health from the real Handler keeps ready/model/idle_s/error first and adds phase/phase_s;
  (e) NEGATIVE CONTROLS: the same warm assertion run against two mutants of the real source - one
      that hands the loader the repo id, and the released shape that skips local resolution
      entirely - must be caught by the socket guard. If a mutant passes, this gate fails;
  (f) the first-install path (nothing on disk) probes the Hub with an explicit timeout, reports
      "downloading" / "waiting for the network" while it retries, bounds the huggingface_hub
      timeouts through its env vars without overriding a user's values, and still loads from the
      downloaded local path.
"""

import contextlib
import importlib.abc
import importlib.util
import io
import json
import os
import pathlib
import shutil
import socket
import sys
import tempfile
import time
import types
import wave
from typing import Optional


sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent.parent
DAEMON_PATH = ROOT / "viddydictate_whisperd.py"
REPO_ID = "mlx-community/whisper-large-v3-turbo"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
TAG = "[whisperd-offline-warm]"

FAILURES: list = []


def check(message: str, condition, detail: str = "") -> bool:
    if not isinstance(condition, bool):
        # Guard against a swapped call: a non-empty message string would otherwise count as a pass.
        raise TypeError(f"check({message!r}, ...) needs a bool condition, got {type(condition).__name__}")
    print(f"{TAG} {'ok  ' if condition else 'FAIL'} {message}" + (f" ({detail})" if detail else ""))
    if not condition:
        FAILURES.append(message)
    return condition


# ---------------------------------------------------------------------------------------------
# Environment isolation
# ---------------------------------------------------------------------------------------------

HF_ENV_KEYS = ("HF_HOME", "HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "XDG_CACHE_HOME",
               "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_ETAG_TIMEOUT",
               "HF_HUB_DOWNLOAD_TIMEOUT", "VIDDYDICTATE_WHISPER_MODEL")


@contextlib.contextmanager
def clean_env(**overrides: str):
    """Run with every Hugging Face / daemon env var cleared, then restore the caller's exactly."""
    saved = dict(os.environ)
    for key in HF_ENV_KEYS:
        os.environ.pop(key, None)
    os.environ.update(overrides)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


def load_daemon(source: Optional[str] = None) -> types.ModuleType:
    """A FRESH daemon module (its warm state is module-global). The real file is loaded exactly as
    test-whisper-tail-clock.py loads it; a mutant is the real text with one substitution."""
    if source is None:
        spec = importlib.util.spec_from_file_location("viddydictate_whisperd", DAEMON_PATH)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    module = types.ModuleType("viddydictate_whisperd_mutant")
    module.__file__ = str(DAEMON_PATH)
    exec(compile(source, str(DAEMON_PATH), "exec"), module.__dict__)  # noqa: S102
    return module


def mutate(old: str, new: str) -> str:
    text = DAEMON_PATH.read_text(encoding="utf-8")
    count = text.count(old)
    # A mutation that silently matches nothing would make the negative control vacuous.
    if count != 1:
        raise SystemExit(f"{TAG} FAIL mutant anchor {old!r} matched {count} times, expected exactly 1")
    return text.replace(old, new)


# ---------------------------------------------------------------------------------------------
# Network guard: any socket connect or name lookup is recorded and refused
# ---------------------------------------------------------------------------------------------

class NetworkBlocked(OSError):
    pass


@contextlib.contextmanager
def socket_guard():
    attempts: list = []
    saved = (socket.socket.connect, socket.socket.connect_ex, socket.create_connection,
             socket.getaddrinfo)

    def refuse(kind: str):
        def guarded(*args, **_kwargs):
            target = args[1] if kind.startswith("socket.") and len(args) > 1 else (args[0] if args else None)
            attempts.append((kind, repr(target)))
            raise NetworkBlocked(f"socket guard: {kind}({target!r}) refused - the Hub is unreachable")
        return guarded

    socket.socket.connect = refuse("socket.connect")
    socket.socket.connect_ex = refuse("socket.connect_ex")
    socket.create_connection = refuse("create_connection")
    socket.getaddrinfo = refuse("getaddrinfo")
    try:
        yield attempts
    finally:
        (socket.socket.connect, socket.socket.connect_ex, socket.create_connection,
         socket.getaddrinfo) = saved


# ---------------------------------------------------------------------------------------------
# Stub modules: numpy, mlx_whisper (loader mirrors mlx-whisper 0.4.3), huggingface_hub
# ---------------------------------------------------------------------------------------------

class StubImports(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    """Serves stub modules for the named imports, executing their factory AT IMPORT TIME so a
    factory can record the environment the daemon had set up by then."""

    def __init__(self, factories: dict):
        self.factories = factories

    def find_spec(self, fullname, path, target=None):
        if fullname in self.factories:
            return importlib.util.spec_from_loader(fullname, self)
        return None

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        self.factories[module.__name__](module)

    def __enter__(self):
        for name in self.factories:
            sys.modules.pop(name, None)
        sys.meta_path.insert(0, self)
        return self

    def __exit__(self, *_exc):
        sys.meta_path.remove(self)
        for name in self.factories:
            sys.modules.pop(name, None)


class StubMLX:
    """Stands in for mlx_whisper. `load_model` mirrors mlx_whisper/load_models.py in 0.4.3:

        model_path = Path(path_or_hf_repo)
        if not model_path.exists():
            model_path = Path(snapshot_download(repo_id=path_or_hf_repo))
        ... open(model_path / "config.json") ... weights.safetensors, else weights.npz

    and the stand-in snapshot_download does what huggingface_hub's does online: it asks the Hub for
    repo info (a name lookup, then a connection) BEFORE it consults the cache."""

    def __init__(self):
        self.loads: list = []
        self.transcribes: list = []
        self.env_at_import: dict = {}

    def snapshot_download(self, repo_id: str) -> str:
        socket.getaddrinfo("huggingface.co", 443)
        socket.create_connection(("huggingface.co", 443), timeout=None)
        raise AssertionError("unreachable: the guard refuses the lookup above")

    def load_model(self, path_or_hf_repo: str):
        model_path = pathlib.Path(path_or_hf_repo)
        if not model_path.exists():
            model_path = pathlib.Path(self.snapshot_download(repo_id=path_or_hf_repo))
        json.loads((model_path / "config.json").read_text())
        weights = model_path / "weights.safetensors"
        if not weights.exists():
            weights = model_path / "weights.npz"
        weights.read_bytes()
        self.loads.append(path_or_hf_repo)
        return object()

    def factories(self) -> dict:
        def numpy_factory(module):
            module.float32 = "float32"
            module.zeros = lambda n, dtype=None: [0.0] * n

        def mlx_factory(module):
            self.env_at_import = {k: os.environ.get(k) for k in
                                  ("HF_HUB_OFFLINE", "HF_HUB_ETAG_TIMEOUT", "HF_HUB_DOWNLOAD_TIMEOUT")}
            holder = {"path": None}

            def transcribe(audio, *, path_or_hf_repo, **_kwargs):
                self.transcribes.append(path_or_hf_repo)
                if holder["path"] != path_or_hf_repo:     # mlx_whisper's ModelHolder cache key
                    self.load_model(path_or_hf_repo)
                    holder["path"] = path_or_hf_repo
                return {"text": " ok", "segments": []}

            module.transcribe = transcribe

        return {"numpy": numpy_factory, "mlx_whisper": mlx_factory}


# ---------------------------------------------------------------------------------------------
# Fake hub caches
# ---------------------------------------------------------------------------------------------

def make_snapshot(cache: pathlib.Path, repo_id: str = REPO_ID, commit: str = COMMIT,
                  files: Optional[dict] = None, symlinked: bool = True,
                  write_ref: bool = True) -> pathlib.Path:
    """The hub cache layout: refs/main -> commit; snapshots/<commit>/<file> -> ../../blobs/<id>."""
    files = {"config.json": b'{"n_mels": 128}', "weights.safetensors": b"\x00" * 64,
             "README.md": b"x"} if files is None else files
    repo_dir = cache / ("models--" + repo_id.replace("/", "--"))
    snapshot = repo_dir / "snapshots" / commit
    snapshot.mkdir(parents=True, exist_ok=True)
    (repo_dir / "blobs").mkdir(exist_ok=True)
    if write_ref:
        (repo_dir / "refs").mkdir(exist_ok=True)
        (repo_dir / "refs" / "main").write_text(commit)
    for i, (name, data) in enumerate(files.items()):
        if data is None:                                   # a dangling link: blob never finished
            os.symlink(f"../../blobs/missing{i}", snapshot / name)
        elif symlinked:
            (repo_dir / "blobs" / f"blob{i}").write_bytes(data)
            os.symlink(f"../../blobs/blob{i}", snapshot / name)
        else:
            (snapshot / name).write_bytes(data)
    return snapshot


# ---------------------------------------------------------------------------------------------
# (a) / (b) the pure resolver
# ---------------------------------------------------------------------------------------------

def gate_resolver() -> None:
    print(f"{TAG} --- (a)/(b) pure local-snapshot resolver ---")
    with clean_env():
        daemon = load_daemon()
    check("loading the daemon imported neither mlx nor huggingface_hub",
          not any(m in sys.modules for m in ("mlx", "mlx_whisper", "huggingface_hub")))

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)

        hub = root / "hub"
        snapshot = make_snapshot(hub)
        got = daemon._resolve_local_snapshot(REPO_ID, cache_dirs=[str(hub)])
        check("(a) a complete symlinked hub snapshot resolves to its snapshot directory",
              got == str(snapshot), str(got))

        npz = root / "npz"
        npz_snapshot = make_snapshot(npz, files={"config.json": b"{}", "weights.npz": b"\x01" * 8},
                                     symlinked=False)
        check("(a) weights.npz is accepted as mlx_whisper's fallback weights file",
              daemon._resolve_local_snapshot(REPO_ID, cache_dirs=[str(npz)]) == str(npz_snapshot))

        empty = root / "empty-hub"
        empty.mkdir()
        app_cache = root / "model-cache"
        app_snapshot = make_snapshot(app_cache)
        check("(a) the app's own model-cache is found when the hub cache has nothing",
              daemon._resolve_local_snapshot(REPO_ID, cache_dirs=[str(empty), str(app_cache)])
              == str(app_snapshot))

        env_hub = root / "env-hub"
        env_snapshot = make_snapshot(env_hub)
        with clean_env(HF_HUB_CACHE=str(env_hub)):
            fresh = load_daemon()
            check("(a) with no explicit list the resolver searches HF_HUB_CACHE",
                  fresh._resolve_local_snapshot(REPO_ID) == str(env_snapshot))

        cases = [
            ({"HF_HUB_CACHE": "/c/hub-cache", "HUGGINGFACE_HUB_CACHE": "/c/legacy", "HF_HOME": "/c/home"},
             "/c/hub-cache"),
            ({"HUGGINGFACE_HUB_CACHE": "/c/legacy", "HF_HOME": "/c/home"}, "/c/legacy"),
            ({"HF_HOME": "/c/home", "XDG_CACHE_HOME": "/c/xdg"}, "/c/home/hub"),
            ({"XDG_CACHE_HOME": "/c/xdg"}, "/c/xdg/huggingface/hub"),
            ({}, os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub")),
        ]
        for env, want in cases:
            got = daemon._hf_hub_cache_dir(env)
            check(f"(a) cache precedence {sorted(env) or ['<none>']} -> {want}", got == want, got)

        incomplete = [
            ("no weights file", {"config.json": b"{}", "README.md": b"x"}, True),
            ("an empty weights file", {"config.json": b"{}", "weights.safetensors": b""}, True),
            ("a dangling weights link (blob never finished)",
             {"config.json": b"{}", "weights.safetensors": None}, True),
            ("no config.json", {"weights.safetensors": b"\x00" * 8}, True),
            ("no refs/main", None, False),
        ]
        for i, (label, files, write_ref) in enumerate(incomplete):
            cache = root / f"incomplete{i}"
            make_snapshot(cache, files=files, write_ref=write_ref)
            got = daemon._resolve_local_snapshot(REPO_ID, cache_dirs=[str(cache)])
            check(f"(b) {label} resolves to None", got is None, str(got))
        check("(b) a cache with no such repo resolves to None",
              daemon._resolve_local_snapshot(REPO_ID, cache_dirs=[str(empty)]) is None)
        check("(b) a different repo id does not resolve to this snapshot",
              daemon._resolve_local_snapshot("mlx-community/whisper-tiny", cache_dirs=[str(hub)]) is None)


# ---------------------------------------------------------------------------------------------
# (c) / (e) the warm path under the socket guard
# ---------------------------------------------------------------------------------------------

def run_warm(daemon: types.ModuleType, stub: StubMLX) -> dict:
    """Run the daemon's REAL _warmup synchronously under the socket guard."""
    out = io.StringIO()
    with StubImports(stub.factories()), socket_guard() as attempts, contextlib.redirect_stdout(out):
        t0 = time.monotonic()
        daemon._warmup()
        elapsed = time.monotonic() - t0
    return {"elapsed": elapsed, "attempts": list(attempts), "log": out.getvalue(),
            "health": daemon._health_payload()}


def warm_problems(daemon: types.ModuleType, stub: StubMLX, run: dict, snapshot: str) -> list:
    """The warm assertion, as a list of problems; empty means the warm is offline-first."""
    problems = []
    if run["attempts"]:
        problems.append(f"made {len(run['attempts'])} network attempt(s): {run['attempts'][:2]}")
    if run["elapsed"] >= 2.0:
        problems.append(f"took {run['elapsed']:.2f}s (budget 2s)")
    if stub.loads != [snapshot]:
        problems.append(f"loader was handed {stub.loads!r}, not the local snapshot path")
    if not run["health"].get("ready") or run["health"].get("phase") != "ready":
        problems.append(f"/health after warm is {run['health']}")
    return problems


def gate_warm_and_mutants() -> None:
    print(f"{TAG} --- (c) the real warm path, Hub unreachable ---")
    with tempfile.TemporaryDirectory() as tmp:
        hub = pathlib.Path(tmp) / "hub"
        snapshot = str(make_snapshot(hub))
        with clean_env(HF_HUB_CACHE=str(hub)):
            daemon = load_daemon()
            stub = StubMLX()
            run = run_warm(daemon, stub)
            problems = warm_problems(daemon, stub, run, snapshot)
            check("(c) the warm completes under the socket guard with no problems",
                  not problems, "; ".join(problems))
            check("(c) zero network attempts (connect, create_connection, getaddrinfo)",
                  run["attempts"] == [], str(run["attempts"]))
            check("(c) warm finished in under 2 s", run["elapsed"] < 2.0, f"{run['elapsed']:.3f}s")
            check("(c) the loader was handed the LOCAL PATH, never the repo id",
                  stub.loads == [snapshot] and REPO_ID not in stub.loads, repr(stub.loads))
            check("(c) HF_HUB_OFFLINE=1 was already set when mlx_whisper (and so huggingface_hub) was imported",
                  stub.env_at_import.get("HF_HUB_OFFLINE") == "1", str(stub.env_at_import))
            log = run["log"]
            for needle in ("warm: resolved local snapshot in", "warm: loading from local snapshot",
                           "model warm (", "warm: phase resolving -> loading"):
                check(f"(c) the daemon logged {needle!r}", needle in log)
            check("(c) no log line carries the cache's filesystem path", tmp not in log)

            # transcribe must hand mlx_whisper the SAME string the warm primed (ModelHolder's key),
            # or it would reload the model - from the repo id, through the network path.
            with tempfile.NamedTemporaryFile(suffix=".wav") as wav_file:
                with wave.open(wav_file.name, "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(16_000)
                    w.writeframes(b"\x00\x00" * 1600)
                daemon._load_wav = lambda _path: [0.0] * 1600   # the stub numpy cannot decode
                transcribe_error = None
                primed_calls = len(stub.transcribes)
                with StubImports(stub.factories()), socket_guard() as attempts:
                    try:
                        daemon._transcribe(wav_file.name, clean=False)
                    except Exception as e:  # noqa: BLE001 — reported as a failed check below
                        transcribe_error = e
            check("(c) transcribe completes offline", transcribe_error is None, repr(transcribe_error))
            check("(c) transcribe passes the same local path the warm primed",
                  stub.transcribes[primed_calls:] == [snapshot], repr(stub.transcribes[primed_calls:]))
            check("(c) transcribe made zero network attempts", attempts == [], str(attempts))
            print(f"{TAG}      daemon log under the guard:")
            for line in log.strip().splitlines():
                print(f"{TAG}        {line}")

        print(f"{TAG} --- (e) NEGATIVE CONTROLS: mutants of the real source ---")
        mutants = [
            ("repo id handed to the loader",
             mutate("        _prime_model(source)\n", "        _prime_model(MODEL)\n")),
            ("released 1.1.0 shape: no local resolution, no HF_HUB_OFFLINE",
             mutate("        source = _prepare_model_source()\n", "        source = MODEL\n")),
        ]
        for label, text in mutants:
            with clean_env(HF_HUB_CACHE=str(hub)):
                mutant = load_daemon(text)
                stub = StubMLX()
                run = run_warm(mutant, stub)
                problems = warm_problems(mutant, stub, run, snapshot)
                print(f"{TAG}      mutant [{label}]: guard saw {run['attempts'][:1]}; "
                      f"/health phase={run['health'].get('phase')} error={run['health'].get('error')!r}")
                check(f"(e) mutant [{label}] FAILS the warm assertion", bool(problems),
                      "; ".join(problems) or "the mutant passed - the gate is vacuous")
                check(f"(e) mutant [{label}] is caught by the socket guard",
                      len(run["attempts"]) > 0, str(run["attempts"][:1]))


# ---------------------------------------------------------------------------------------------
# (d) /health through the real Handler
# ---------------------------------------------------------------------------------------------

def health_via_handler(daemon: types.ModuleType) -> dict:
    handler = daemon.Handler.__new__(daemon.Handler)
    handler.path = "/health"
    handler.command = "GET"
    handler.request_version = "HTTP/1.1"
    handler.requestline = "GET /health HTTP/1.1"
    handler.client_address = ("127.0.0.1", 0)
    handler.close_connection = False
    handler.wfile = io.BytesIO()
    handler.do_GET()
    raw = handler.wfile.getvalue()
    head, _, body = raw.partition(b"\r\n\r\n")
    check("(d) /health answers 200", head.startswith(b"HTTP/1.1 200"), head.split(b"\r\n")[0].decode("latin-1"))
    return json.loads(body)


def gate_health() -> None:
    print(f"{TAG} --- (d) /health keeps the old fields and adds phase/phase_s ---")
    with tempfile.TemporaryDirectory() as tmp:
        hub = pathlib.Path(tmp) / "hub"
        make_snapshot(hub)
        with clean_env(HF_HUB_CACHE=str(hub)):
            daemon = load_daemon()
            before = health_via_handler(daemon)
            check("(d) the first four keys are exactly ready, model, idle_s, error, in order",
                  list(before)[:4] == ["ready", "model", "idle_s", "error"], str(list(before)))
            check("(d) the old fields keep their types",
                  isinstance(before["ready"], bool) and isinstance(before["model"], str)
                  and isinstance(before["idle_s"], float) and before["error"] is None, json.dumps(before))
            check("(d) a fresh daemon reports ready=false, phase=starting",
                  before["ready"] is False and before["phase"] == "starting", json.dumps(before))
            check("(d) phase_s is a number of seconds",
                  isinstance(before["phase_s"], (int, float)) and before["phase_s"] >= 0)
            check("(d) phase is one of the documented names", before["phase"] in daemon.PHASES)
            run_warm(daemon, StubMLX())
            after = health_via_handler(daemon)
            check("(d) after the warm: ready=true, phase=ready, error=null",
                  after["ready"] is True and after["phase"] == "ready" and after["error"] is None,
                  json.dumps(after))
            check("(d) model still reports the configured repo id, not the local path",
                  after["model"] == REPO_ID, after["model"])
            print(f"{TAG}      /health before warm: {json.dumps(before)}")
            print(f"{TAG}      /health after warm:  {json.dumps(after)}")


# ---------------------------------------------------------------------------------------------
# (f) first install: nothing on disk
# ---------------------------------------------------------------------------------------------

def gate_first_install() -> None:
    print(f"{TAG} --- (f) first install: bounded, visible download ---")
    with tempfile.TemporaryDirectory() as tmp:
        hub = pathlib.Path(tmp) / "hub"
        hub.mkdir()
        for user_etag in (None, "99"):
            env = {"HF_HUB_CACHE": str(hub)}
            if user_etag:
                env["HF_HUB_ETAG_TIMEOUT"] = user_etag
            with clean_env(**env):
                daemon = load_daemon()
                stub = StubMLX()
                seen = {"probes": [], "phases": [], "env_at_import": {}, "downloads": 0, "sleeps": []}
                failures_before_success = 2

                def hub_factory(module):
                    seen["env_at_import"] = {k: os.environ.get(k) for k in
                                             ("HF_HUB_OFFLINE", "HF_HUB_ETAG_TIMEOUT",
                                              "HF_HUB_DOWNLOAD_TIMEOUT")}

                    class HfApi:
                        def repo_info(self, repo_id, timeout=None, **_kw):
                            seen["probes"].append(timeout)
                            seen["phases"].append(daemon._health_payload())
                            if len(seen["probes"]) <= failures_before_success:
                                raise TimeoutError("simulated: the Hub did not answer")
                            return {"id": repo_id}

                    def snapshot_download(repo_id, **_kw):
                        seen["downloads"] += 1
                        seen["phases"].append(daemon._health_payload())
                        return str(make_snapshot(hub, repo_id=repo_id))

                    module.HfApi = HfApi
                    module.snapshot_download = snapshot_download

                daemon._sleep = lambda s: seen["sleeps"].append(s)
                factories = {**stub.factories(), "huggingface_hub": hub_factory}
                out = io.StringIO()
                with StubImports(factories), socket_guard() as attempts, contextlib.redirect_stdout(out):
                    daemon._warmup()
                health = daemon._health_payload()
                snapshot = daemon._resolve_local_snapshot(REPO_ID, cache_dirs=[str(hub)])
                tag = "user ETAG timeout kept" if user_etag else "defaults"

                check(f"(f/{tag}) the warm finishes ready after the Hub comes back",
                      health["ready"] is True and health["phase"] == "ready", json.dumps(health))
                check(f"(f/{tag}) every reachability probe carried an explicit timeout <= 10 s",
                      seen["probes"] and all(t is not None and 0 < t <= 10 for t in seen["probes"]),
                      str(seen["probes"]))
                waiting = [p for p in seen["phases"] if p["phase_detail"] == "waiting for the network"]
                check(f"(f/{tag}) /health said downloading / waiting for the network while it retried",
                      bool(waiting) and all(p["phase"] == "downloading" for p in waiting),
                      json.dumps(seen["phases"][:3]))
                check(f"(f/{tag}) the download itself ran in phase downloading with no stale detail",
                      seen["downloads"] == 1 and seen["phases"][-1]["phase"] == "downloading"
                      and seen["phases"][-1]["phase_detail"] is None, json.dumps(seen["phases"][-1:]))
                check(f"(f/{tag}) retries backed off through the injectable sleep, never a real wait",
                      len(seen["sleeps"]) == failures_before_success, str(seen["sleeps"]))
                check(f"(f/{tag}) HF_HUB_OFFLINE was NOT set while downloading",
                      not seen["env_at_import"].get("HF_HUB_OFFLINE"), str(seen["env_at_import"]))
                want_etag = user_etag or daemon.HF_ETAG_TIMEOUT_S
                check(f"(f/{tag}) HF_HUB_ETAG_TIMEOUT={want_etag} and HF_HUB_DOWNLOAD_TIMEOUT="
                      f"{daemon.HF_DOWNLOAD_TIMEOUT_S} were set before huggingface_hub was imported",
                      seen["env_at_import"].get("HF_HUB_ETAG_TIMEOUT") == want_etag
                      and seen["env_at_import"].get("HF_HUB_DOWNLOAD_TIMEOUT")
                      == daemon.HF_DOWNLOAD_TIMEOUT_S, str(seen["env_at_import"]))
                check(f"(f/{tag}) the model then loaded from the downloaded LOCAL PATH",
                      snapshot is not None and stub.loads == [snapshot], repr(stub.loads))
                check(f"(f/{tag}) no real socket was touched", attempts == [], str(attempts))
                check(f"(f/{tag}) the log says it is downloading",
                      "warm: downloading" in out.getvalue())
            # The next iteration needs an empty cache again.
            for child in list(hub.iterdir()):
                shutil.rmtree(child)


def main() -> int:
    gate_resolver()
    gate_warm_and_mutants()
    gate_health()
    gate_first_install()
    if FAILURES:
        print(f"{TAG}[FAIL] {len(FAILURES)} check(s) failed: " + "; ".join(FAILURES))
        return 1
    print(f"{TAG}[PASS] offline-first warm: local snapshot resolved, zero network attempts, "
          "/health phases additive, both mutants caught by the socket guard, first install bounded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
