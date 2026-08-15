# Local STT daemon

ViddyDictate never sends audio anywhere. Every transcript comes from `viddydictate_whisperd.py`,
a small localhost-bound HTTP service that holds an mlx-whisper model resident and answers on
`127.0.0.1:8765`. `Sources/App/DaemonClient.swift` is its only client in this app; it wakes the
daemon through the LaunchAgent label `com.viddydictate.whisperd`.

## What ships and what does not

The daemon **source** is vendored at the repository root, so a clone is self-sufficient. The
**model weights are not** — mlx-whisper downloads `mlx-community/whisper-large-v3-turbo` (~1.5 GB)
into the Hugging Face cache on the daemon's first transcribe. Until that finishes `/health`
answers with `"ready": false` and `/transcribe` returns 503.

`ffmpeg` is a genuine prerequisite: mlx-whisper shells out to it by name to decode the recorded
clip. The daemon starts and answers `/health` without it, but every transcribe fails, so
`install-daemon.sh` warns up front when it is missing.

## What install-daemon.sh does

1. Picks a Python (first of `python3.12`, `python3.13`, `python3.11`, `python3.10`, `python3` that
   is >= 3.9; `VD_STT_PYTHON` forces one). mlx publishes wheels for CPython 3.10-3.14, and 3.9 —
   all a bare Command-Line-Tools Mac has — still resolves to an older working mlx.
2. Creates ViddyDictate's **own** venv at `~/Library/Application Support/ViddyDictate/stt-venv` and
   installs `mlx-whisper~=0.4.3` into it. The bound is a compatible-release bound on purpose: a
   minor bump of the STT stack should be a deliberate change to this repo, not something that
   happens to a user months from now.
3. Copies the daemon to `~/Library/Application Support/ViddyDictate/viddydictate_whisperd.py`. It
   runs from that copy rather than in place because a launchd agent invoking `python` directly
   cannot open TCC-protected locations such as `~/Documents` — no grant, and no prompt to grant it.
4. Writes `~/Library/LaunchAgents/com.viddydictate.whisperd.plist`, substituting `__HOME__`.
5. Bootstraps and kickstarts the agent, then polls `/health` and reports what it found.

`--no-bootstrap` performs steps 1-4 and stops, for verification runs and for installs that must not
disturb a live agent.

## Source and installed copy

The repository copy is canonical for ViddyDictate. `install-daemon.sh` refreshes the installed
copy whenever it runs. To diagnose a stale local install, compare the repository source with the
copy under Application Support:

```
diff viddydictate_whisperd.py "$HOME/Library/Application Support/ViddyDictate/viddydictate_whisperd.py"
```

The LaunchAgent label is `com.viddydictate.whisperd`, the same string `DaemonClient.swift` names.
An install that predates the rename was bootstrapped under an older label; `install-daemon.sh` boots
that one out and removes its plist before bootstrapping this one, so only one agent is ever
registered.
