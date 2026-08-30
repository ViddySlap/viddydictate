# Backing up your data, and removing ViddyDictate

Two scripts, both in `scripts/`. One only reads, one only removes, and neither does the other's job.

```sh
./scripts/backup-user-data.sh      # copy your transcripts, recordings and notes somewhere safe
./scripts/uninstall.sh             # show what is installed; removes nothing until you say which
```

## Where ViddyDictate keeps things

| Path | What it holds | Survives `--app-only`? |
|---|---|---|
| `~/Applications/ViddyDictate.app` | the app | no |
| `~/Library/LaunchAgents/com.viddydictate.app.plist` | starts the app at login | no |
| `~/Library/LaunchAgents/com.viddydictate.whisperd.plist` | starts the transcription daemon | no |
| `~/Library/Application Support/ViddyDictate/` | history, recordings, sticky notes, dictionary, the Python environments | yes |
| `~/.local/share/viddydictate/` | the web-search helper and its environment | yes |
| `~/Library/Preferences/com.viddydictate.app.plist` | every setting | yes |
| `~/Library/Caches/ViddyDictate*` | scratch | no |
| `~/Library/Logs/ViddyDictate.log` | the app log | no |

Two things live outside all of that and neither script touches them: **LM Studio** and any models you
downloaded through it, and the **Hugging Face cache** at `~/.cache/huggingface`, where the Whisper
model lands. The cache is shared with every other tool on your Mac that uses Hugging Face, so
removing it is your call and not an uninstaller's. It is also the reason a *second* install is much
faster than the first one.

## Backing up

```sh
./scripts/backup-user-data.sh --list
```

prints exactly what would be copied and what would not, and copies nothing. Then:

```sh
./scripts/backup-user-data.sh
```

writes `~/Desktop/ViddyDictate-backup-<timestamp>/`, or pass a path of your own. It copies your
dictation history and the audio behind it, your sticky notes with their attachments and version
history, your correction dictionary, your custom modes, and your settings.

It does **not** copy the Python environments or the vendored provider binaries — a couple of
gigabytes that the app rebuilds by itself — and it does **not** copy `codex-home`, because that is a
provider login. Signing in again is one click. A login sitting in a folder on your Desktop is a
different kind of problem.

The list of what to copy is an allow list rather than "everything except". That means a file a
future version starts writing will show up in the backup's `MANIFEST.txt` under **NOT COPIED** as
*not in the allow list* rather than being quietly swept into a folder you might share. If you see
that line, look at the file.

`MANIFEST.txt` also carries the restore procedure. The short version: install, launch once so the
folders exist, **quit**, copy back, `killall cfprefsd`, launch again. Quitting matters — a running
app rewrites those files underneath you, and macOS caches preferences in `cfprefsd`, so restoring a
settings file without flushing that cache gets silently undone a few minutes later.

## Removing it

Run it with no arguments first. It prints an inventory and removes nothing:

```sh
./scripts/uninstall.sh
```

Then pick one:

```sh
./scripts/uninstall.sh --app-only     # app, launchd jobs, caches, logs. Your data stays.
./scripts/uninstall.sh --everything   # all of that plus your data. Asks you to type a confirmation.
```

`--app-only` is the right one for "this isn't for me" or for moving to a different install method:
reinstalling later picks your history, notes and settings straight back up.

`--everything` is for a genuine clean slate. It also resets the Accessibility, Input Monitoring and
Microphone grants, so the next install runs the real first-run permission flow instead of inheriting
one. Pass `--keep-permissions` if you would rather not re-grant them — but if you are testing what a
new user experiences, inheriting those grants is the one thing that would make the test lie to you.

### Why the order matters

ViddyDictate holds a `CGEventTap` on the keyboard, which is how a global push-to-talk hotkey works at
all. Deleting the app bundle out from under a running instance takes that tap away without letting
the app tear it down, and a held modifier can be left stranded — the keyboard stops responding until
you log out. That is a real report from 2026-08-15, not a hypothetical.

So `uninstall.sh` boots out the launchd jobs, sends `SIGTERM` (never `SIGKILL`, because the tap is
released in a termination handler that a killed process never runs), waits up to ten seconds, and
**refuses to delete anything** if the process is still alive. If you ever see that refusal, quit
ViddyDictate from its menu-bar icon and run the script again.

### If macOS still lists it

System Settings → Privacy & Security sometimes keeps a stale row for an app that no longer exists.
Select ViddyDictate there and press the minus button. It is cosmetic, but it is confusing to leave.
