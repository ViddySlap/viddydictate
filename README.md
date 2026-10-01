# ViddyDictate

ViddyDictate is an Apple Silicon macOS menu-bar app for system-wide push-to-talk dictation. Hold
right Option, speak, and release. The app transcribes the recording on the Mac and delivers the
text to the focused field. It also includes configurable hotkeys, cleanup and email transforms,
grounded web answers, dictation history, a correction dictionary, and multi-window sticky notes
with reusable Sticky Skills.

Speech-to-text is local. The app sends text, and applicable sticky-note attachments, to a text
provider only when a provider-backed transform is invoked. Provider credentials remain owned by
the provider client. An optional Gemini key is stored in the macOS login keychain.

## Requirements

- An Apple Silicon Mac running macOS 13 Ventura or newer. Intel Macs are not supported.
- About 1.7 GB of downloads and roughly 15 minutes on first launch, once. See [Install](#install).
- For text transforms, either:
  - Claude Code installed and signed in with a supported claude.ai subscription, or
  - ChatGPT.app installed in `/Applications`, followed by ViddyDictate's in-app Codex device login.

Only one cloud provider is required. Raw dictation works without one. LM Studio is an optional
local-provider path, but the current local cleanup and search route uses a 30B model that does not
fit on a 16 GB Mac. On modest hardware, use Claude or Codex.

Nothing else is a prerequisite. The app brings its own Python, and you do not need Xcode, the
Command Line Tools, Homebrew, `ffmpeg`, or Node to run it. Those are needed only to
[build from source](#build-from-source).

## Install

Download `ViddyDictate-<version>.dmg` from
[Releases](https://github.com/ViddySlap/viddydictate/releases), open it, and drag ViddyDictate to
Applications. It is signed with an Apple Developer ID and notarized by Apple, so it opens without a
Gatekeeper warning and without right-click-Open.

The first launch opens a setup window, **Welcome to ViddyDictate**, rather than a progress bar you
cannot argue with. It has three parts:

- **Required to transcribe.** A mandatory core of about 1.7 GB of downloads — the speech-to-text
  environment, the `whisper-large-v3-turbo` voice model, and the web-search helper, beside the
  Python runtime the app already carries — is not a choice, because dictation without the voice
  model is a different program.
- **Local models - pick one app.** Cleanup, email, and local web answers can run in a local model
  app on your Mac. Pick one:
  - **LM Studio**, the simple install and the recommended one.
  - **Ollama**, the advanced option, for people who already use it. While it installs, macOS asks
    for Touch ID or your password because "Ollama is trying to install its command line interface
    tool". Approve it; only you can, and ViddyDictate never answers it for you.
  - **Skip for now**, which installs neither. Raw dictation does not need one, and Claude or Codex
    can run the text modes.

  You can add the other app later from **Settings > Setup**.
- **Optional.** The app you picked and its two models, each a tick row that tells you its size and
  what you lose by leaving it off. A model is ticked only if your Mac has the memory to run it.

Press **Continue** and it downloads. While it does:

- The window asks for **Microphone**, **Accessibility**, and **Input Monitoring**, with a Grant
  button for each. Grant all three; those are, respectively, recording, delivering text into the
  focused field, and noticing the hotkey. Only you can grant them — no installer or agent can do it
  for you.
- Each component starts working as it lands, rather than at the end.
- You can close the window. The download continues.

You can also choose **Set up later** and land in a working, reduced app. Nothing goes quietly
missing: a feature you skipped explains itself and offers to install itself at the moment you reach
for it. Until the core is installed, the setup window comes back at each launch; once it is, the
window stays away, and **Run first-run setup again…** on the Setup tab brings it back.

When the setup window closes, ViddyDictate helps you sign in to Claude or Codex if neither is ready
yet.

Measured cold on an empty account: **3m25s to working dictation**, and the rest of the core arrives
behind it.

To remove it again, or to back your data up first, see
[docs/uninstall-and-backup.md](docs/uninstall-and-backup.md).

## Build from source

You do not need to do this to use ViddyDictate; the release above is the same app. Build if you want
to read the code you are running, change it, or work on it.

Building additionally needs Apple Command Line Tools for `swiftc` (Xcode is not required) and
Python 3.9 or newer. Node.js and npm are needed only to rebuild the Sticky Notes web bundle or run
the deterministic verification rail; the built web bundle is committed.

```sh
./build.sh
open build/ViddyDictate.app
```

`build.sh` creates `build/ViddyDictate.app` and a verification-only sibling,
`build/ViddyDictateTests.app`. If the committed Sticky Notes bundle is missing, run
`./build-web.sh` first.

## Upgrading from an earlier install

Skip this section on a machine that has never run ViddyDictate.

Do this **before** `./scripts/verify.sh` or `./build.sh`. Verification calls the build, the build
clears `build/`, and an earlier ViddyDictate topology ran the live app straight out of `build/`.
Rebuilding on such a machine deletes the running app: launchd loses its target, and because the app
holds the keyboard event tap, the keyboard can stop responding until you log out. `build.sh` now
refuses when it detects this, but check first so the refusal is never a surprise.

Find any ViddyDictate LaunchAgent and see where it points:

```sh
for p in "$HOME"/Library/LaunchAgents/*.plist; do
  t=$(plutil -convert xml1 -o - "$p" 2>/dev/null | grep -oE '/[^<>[:space:]]*ViddyDictate\.app/Contents/MacOS/ViddyDictate' | head -n1)
  [ -n "$t" ] && echo "$(basename "$p" .plist) -> $t"
done
```

If the only result points at `~/Applications/ViddyDictate.app`, you are already on the current
topology. Pull, rebuild, and rerun the installers as usual.

If a result points anywhere else, retire that install first. Substitute the label the command above
printed:

```sh
launchctl bootout "gui/$(id -u)/com.viddyslap.viddydictate" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.viddyslap.viddydictate.plist"
```

Then follow the normal install below. Nothing else needs to be removed by hand: settings, sticky
notes, dictation history, and the speech-to-text environment live outside the app bundle and are
carried forward. The installers update the daemon and its LaunchAgent in place.

Because the current bundle identifier is `com.viddydictate.app`, macOS treats the migrated app as a
new client. Grant Microphone, Accessibility, and Input Monitoring again after installing, and remove
any stale ViddyDictate entry from System Settings > Privacy & Security so the list stays unambiguous.

## Installing a build of your own

Skip this if you installed the release DMG; it is already signed, notarized, and self-contained,
and it installs its own daemon on first launch. This section is for a build you made yourself.

For a first install, create a stable local signing identity before the final build. The stable
identity lets macOS preserve Accessibility and Input Monitoring grants across rebuilds. See
[docs/signing-and-tcc.md](docs/signing-and-tcc.md) for what that identity is, what it is trusted for,
and its security tradeoff.

`setup-signing.sh` asks you to choose a keychain password. It is not stored anywhere, so save it in
your password manager; four unrelated words is the right shape. `build.sh` will ask for it whenever
the keychain has locked, which it does after every build and after 15 minutes idle. That prompt is
the point rather than friction: a locked keychain cannot sign, which is what stops another process
on your Mac from signing a binary that would inherit ViddyDictate's Accessibility and Input
Monitoring. Never put that password in a file or a script to avoid the prompt.

```sh
./setup-signing.sh
./build.sh
./install-daemon.sh
./install-app-agent.sh
```

`install-app-agent.sh` is required for a normal installation: it copies the signed app to
`~/Applications/ViddyDictate.app` and installs its login LaunchAgent. It intentionally refuses an
ad-hoc-signed build.

The web-search helper is genuinely optional and is deliberately not part of the sequence above:

```sh
./install-websearch-helper.sh
```

It installs a private Python environment with the `ddgs` DuckDuckGo client, used only by local web
search on right Option+L. Skipping it leaves that one hotkey unavailable and changes nothing else.
Privacy-conscious users may skip it; nothing else in the app queries DuckDuckGo.

The speech-to-text installer creates a private Python environment under
`~/Library/Application Support/ViddyDictate`, installs `mlx-whisper`, copies the vendored daemon,
and installs its LaunchAgent. The daemon's first start downloads and warms the approximately 1.5 GB
`mlx-community/whisper-large-v3-turbo` model, so it can take much longer to become ready than later
starts.

## Finish setup in the app

Open the ViddyDictate menu-bar item, choose Settings, and use the Setup tab. Its Check again action
reports each missing requirement without blocking unrelated features.

1. Connect one text provider.
   - Claude Code: click Sign in to Claude Code. ViddyDictate opens Terminal with
     `claude auth login` and notices when login completes.
   - Codex: click Connect Codex and finish the ChatGPT subscription device-login flow.
     ViddyDictate uses a dedicated Codex home and does not read or change the everyday Codex login.
2. On modest hardware, open Hotkeys and use "Set every route to its staff pick" to select the
   cloud provider just connected. Fresh routes are selected Local, which expects the optional
   LM Studio models.
3. Grant the three macOS permissions when prompted:
   - Microphone, so the app can record.
   - Accessibility, so it can deliver text to the focused field.
   - Input Monitoring, so the global hotkeys work.
4. After changing Accessibility or Input Monitoring, quit and reopen ViddyDictate, then click
   Check again.

These permissions require human approval in System Settings under Privacy & Security. A script or
installing agent cannot grant them.

Gemini grounded answers on right Option+G are optional. Add a key in Settings > Setup, or run
`./scripts/set-gemini-key.sh`; the script reads it from hidden standard input and never puts it in
the process arguments. No key is needed for dictation or the other text-provider routes.

## Basic use

- Hold right Option, speak, and release to dictate into the focused field.
- While holding right Option, tap Space to latch hands-free recording. Repeat to stop and send.
- Hold right Option and tap N to open Sticky Notes.
- Hold right Option and tap P to clean up selected text in place.
- Hold right Option and tap M to create an email from a dictation or selection.
- Hold right Option and tap L for local web search, or G for Gemini grounded search.

Hotkeys, input behavior, provider/model routes, prompts, history, audio retention, and appearance are
configurable in Settings.

## Verification

For a cold checkout, install the locked npm dependencies before the offline rail:

```sh
npm ci
./scripts/verify.sh deterministic
```

The deterministic tier rebuilds both native and web artifacts and does not call a cloud provider.
The `services`, `gui`, and `full` tiers require live provider logins, LM Studio, a graphical login
session, and other host capabilities. See the [documentation index](docs/README.md) for audience
guidance and [docs/verification.md](docs/verification.md) for the exact tier contract.

## Troubleshooting

Start with Settings > Setup > Check again. It distinguishes a missing install, a signed-out provider,
a stopped daemon, missing macOS permissions, and optional search setup.

Useful checks. These need no repository and work on a DMG install:

```sh
curl -fsS http://127.0.0.1:8765/health
launchctl print "gui/$(id -u)/com.viddydictate.app"
tail -n 100 "$HOME/Library/Logs/ViddyDictate.log"
tail -n 100 /tmp/viddydictate-whisperd.err.log
tail -n 100 /tmp/viddydictate.err.log
```

- If daemon health never answers, reopen Settings > Setup and re-run the failed component. On a
  source install, `./install-daemon.sh` does the same thing and prints more.
- If health says the model is not ready, allow the first model download and warmup to finish.
- If every transcribe fails while health still answers, check the daemon's error log. Transcription
  needs no external tools; the daemon decodes the audio itself.
- If global hotkeys do nothing, recheck Accessibility and Input Monitoring, then relaunch the app.
- If the keyboard itself becomes unresponsive, a ViddyDictate process holding the event tap was
  destroyed rather than stopped, usually by rebuilding over a live install. Log out and back in to
  clear the tap, then see "Upgrading from an earlier install" above. `build.sh` now stops a running
  build instance cleanly and refuses to rebuild over a live install elsewhere.
- If a text transform is unavailable, reconnect one provider in Settings > Setup. Claude Code can
  also be checked with `claude auth status --json`; Codex connection state is checked inside the app
  because ViddyDictate uses its own dedicated login.
- If a rebuilt app loses permissions, rerun `./setup-signing.sh`, rebuild, and reinstall. Do not
  deploy the ad-hoc build directly. This cannot happen to a DMG install: the release identity does
  not change between versions, so an upgrade keeps its grants.
- To remove ViddyDictate, or to back up your transcripts and notes before you do, see
  [docs/uninstall-and-backup.md](docs/uninstall-and-backup.md). Do not delete the app bundle while
  it is running; it holds a keyboard event tap, and yanking it can leave the keyboard unresponsive
  until you log out. The uninstall script stops it properly first.

## Support and license

ViddyDictate is provided as-is. There is no support commitment, and issues may go unanswered.

Licensed under the MIT License. See [LICENSE](LICENSE).
