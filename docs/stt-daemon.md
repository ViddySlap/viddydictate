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

**The daemon decodes audio itself and needs no external tools.** mlx-whisper shells out to `ffmpeg`
only when it is handed a file PATH; the daemon hands it a decoded float32 array instead, so that
branch is never reached. The app sends 16 kHz mono audio (`AudioRecorder.resampleForModel`), which
makes the daemon's decode an exact `int16 -> float32` conversion with nothing to approximate —
measured bit-identical to ffmpeg's own decode, `max|diff| = 0.0`, across the whole regression corpus.
A clip that arrives at some other rate (one retained by an older build, or a corpus file) is
resampled in Python instead, and the daemon logs that it did so.

This used to be a real prerequisite, and its absence was the worst-shaped failure the app had: the
daemon started, `/health` answered, the 1.5 GB model downloaded and warmed, every indicator went
green, and every single transcribe failed. macOS ships no `ffmpeg` and nothing in the app installed
one, so that was the out-of-the-box experience for anyone without Homebrew.

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
