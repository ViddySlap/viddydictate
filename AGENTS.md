# AGENTS.md

This file is the install contract for a coding agent working from the ViddyDictate repository root.
When a user says "install this", follow the sequence below, report exact results, and stop for the
human-only steps. Do not claim that built, installed, running, permissioned, and provider-connected
mean the same thing.

## Boundaries

- ViddyDictate supports Apple Silicon and macOS 13 or newer. Stop on Intel or an older macOS release.
- Never print, log, or place a credential in a command argument, file, test fixture, commit, or chat.
- Never inspect, delete, replace, or reset a user's sticky-note contents, dictation history, retained
  recordings, `custom-modes.json`, or `models-power.json`.
- Never delete `~/Library/Application Support/ViddyDictate` as an install or repair shortcut. The
  supported installers update their own daemon, virtual environment, and LaunchAgent files in place.
- Do not uninstall, run rollback scripts, reset TCC permissions, change repository visibility, or
  modify provider logins unless the user explicitly asks.
- Do not automate clicks or keystrokes for macOS permission prompts or provider authentication. Tell
  the user exactly what remains and wait.

## 1. Preflight the Mac

Run read-only checks first:

```sh
test "$(uname -m)" = arm64
sw_vers -productVersion
xcode-select -p
command -v swiftc
command -v python3
python3 -c 'import sys; assert sys.version_info >= (3, 9)'
command -v ffmpeg
command -v openssl
command -v curl
command -v node
command -v npm
```

The macOS major version must be at least 13. If Command Line Tools are absent, run
`xcode-select --install` and pause while the user completes Apple's installer. If `ffmpeg` is absent
and Homebrew is already installed, run `brew install ffmpeg`; otherwise ask the user how they want
to install it. Do not silently install a new system package manager.

Node.js and npm are verification dependencies, not runtime dependencies. If they are available, use
the deterministic gate below. If they are missing, explain that the committed web bundle can still
be built into the app, but the repository's deterministic verification gate cannot run until Node.js
and npm are installed.

## 2. Verify the checkout

From the repository root, install the locked web dependencies and run the offline gate:

```sh
npm ci
./scripts/verify.sh deterministic
```

Do not substitute a narrower check. The deterministic tier is offline with respect to model
providers, but `npm ci` itself uses the package registry on a cold checkout. If the gate changes a
committed generated file, stop and report the diff rather than discarding it.

The deterministic verifier builds ad-hoc verification bundles in its isolated environment. Always
run the normal signed build later, after stable signing is ready, before calling the app installer.

## 3. Create stable signing and build

Run:

```sh
./setup-signing.sh
./build.sh
```

`setup-signing.sh` creates a local self-signed code-signing identity. Reusing that identity is what
keeps Accessibility and Input Monitoring grants attached to the app across rebuilds. `build.sh`
creates both `build/ViddyDictate.app` and the verification-only `build/ViddyDictateTests.app`.

Confirm the shipping bundle exists and is not ad-hoc signed:

```sh
test -x build/ViddyDictate.app/Contents/MacOS/ViddyDictate
codesign --verify --deep --strict build/ViddyDictate.app
if codesign -dv build/ViddyDictate.app 2>&1 | grep -Eq 'Signature=adhoc|flags=0x2\(adhoc\)'; then
  echo "ViddyDictate build is ad-hoc signed" >&2
  exit 1
fi
```

If signing fails, stop with the exact error. Do not bypass `install-app-agent.sh` or copy an ad-hoc
bundle into place.

## 4. Install the local services and app

Run the repository's installers rather than recreating their work manually:

```sh
./install-daemon.sh
./install-websearch-helper.sh
./install-app-agent.sh
```

What these commands do:

- `install-daemon.sh` chooses Python 3.9 or newer, creates the app-owned STT virtual environment,
  installs `mlx-whisper~=0.4.3`, copies the vendored daemon, installs its LaunchAgent, and checks
  `127.0.0.1:8765/health`. Its first daemon start downloads and warms approximately 1.5 GB of model
  data.
- `install-websearch-helper.sh` creates the optional local-search virtual environment, installs
  `ddgs`, copies the helper, and performs a network smoke test. A throttled smoke warning does not
  mean the helper files failed to install.
- `install-app-agent.sh` copies only the shipping app to `~/Applications/ViddyDictate.app`, installs
  its LaunchAgent, and starts it. It intentionally refuses ad-hoc signing.

Do not use `install-daemon.sh --no-bootstrap` for a normal install; that option deliberately leaves
the service stopped. Rerunning these installers is the supported update and repair path.

## 5. Verify what the agent can verify

Run:

```sh
test -x "$HOME/Applications/ViddyDictate.app/Contents/MacOS/ViddyDictate"
codesign --verify --deep --strict "$HOME/Applications/ViddyDictate.app"
curl -fsS http://127.0.0.1:8765/health
launchctl print "gui/$(id -u)/com.viddydictate.app"
```

A health response with `"ready": false` means the daemon is running but the Whisper model is still
downloading or warming. Report that honestly; do not call transcription ready yet.

Do not run `./scripts/verify.sh full` as part of a routine install. It requires live provider,
LM Studio, GUI, and host-only capabilities and is a maintainer/release gate, not a cold-user install
check.

## 6. Hand the human the remaining steps

Ask the user to open the ViddyDictate menu-bar item, choose Settings, open Setup, and click Check
again. The human must then:

1. Connect either Claude Code or Codex. One is enough.
   - Claude requires the Claude Code CLI and a supported claude.ai subscription. The in-app button
     opens `claude auth login` in Terminal and waits for it to complete.
   - Codex requires `/Applications/ChatGPT.app`. The in-app button starts a ChatGPT subscription
     device login in ViddyDictate's dedicated Codex home. It does not reuse the normal Codex login.
2. On a Mac that will use the cloud path, open Hotkeys and use "Set every provider-capable route to
   its tested default" to select the provider just connected. Fresh routes are selected Local and
   otherwise expect the optional LM Studio models.
3. Start one dictation and approve the Microphone prompt.
4. Enable ViddyDictate in System Settings > Privacy & Security > Accessibility and Input Monitoring.
5. Quit and reopen ViddyDictate after changing Accessibility or Input Monitoring, then click Check
   again.

An optional Gemini key enables right Option+G only. The preferred path is the secure field in
Settings > Setup. Never ask the user to paste the key into chat. The terminal fallback is
`./scripts/set-gemini-key.sh`, which reads hidden standard input.

LM Studio is optional. Do not steer a 16 GB Mac toward the current 30B local cleanup/search model;
use Claude or Codex on modest hardware.

## 7. Report exact state

End with separate statements for:

- Deterministic verification: pass, fail, or not run, with the command.
- Build: whether `build/ViddyDictate.app` exists and verifies.
- Install: whether the installed bundle exists and verifies.
- Services: daemon LaunchAgent state and `/health` result; search-helper result separately.
- App: whether its LaunchAgent is loaded.
- Human permissions: confirmed in the Setup tab or still pending.
- Provider: Claude, Codex, or Local confirmed available in the Setup tab, and which provider the
  routes select in Hotkeys, or what is still pending.

Do not call the installation complete until the installed app is running, the daemon is ready, the
three macOS permissions are confirmed, and at least one provider is available for text transforms.
Raw local dictation can be reported separately if it works before a provider is connected.

## Troubleshooting order

1. Use Settings > Setup > Check again. It is the product's current preflight surface.
2. Inspect `~/Library/Logs/ViddyDictate.log`, `/tmp/viddydictate.err.log`, and
   `/tmp/viddydictate-whisperd.err.log`. Do not paste user content or secrets into chat.
3. Rerun the owning installer. Do not hand-edit generated LaunchAgent files.
4. If hotkeys fail, recheck Accessibility and Input Monitoring and relaunch the app.
5. If transcription fails while `/health` answers, confirm `ffmpeg` is on the daemon's configured
   PATH and wait for the first model warmup.
6. If Claude transforms fail, use the Setup tab and `claude auth status --json`. If Codex transforms
   fail, use the Setup tab because ViddyDictate's dedicated Codex state is intentionally separate.
