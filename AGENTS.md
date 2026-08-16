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
- Never build, verify, or install over a ViddyDictate install you did not just create without
  completing section 2 first. Destroying a running instance can leave the user's keyboard
  unresponsive, and a user whose keyboard is dead cannot tell you what went wrong.

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

## 2. Check for an existing ViddyDictate install

Do this before running anything that builds, including the verification gate in the next section.
`./scripts/verify.sh` calls `./build.sh`, `build.sh` clears `build/`, and an earlier ViddyDictate
topology ran the live app straight out of `build/`. Rebuilding on such a machine deletes a running
app: launchd loses its target, and because that app holds the keyboard event tap, the user's
keyboard can stop responding until they log out. This has happened to a real user.

```sh
for p in "$HOME"/Library/LaunchAgents/*.plist; do
  t=$(plutil -convert xml1 -o - "$p" 2>/dev/null | grep -oE '/[^<>[:space:]]*ViddyDictate\.app/Contents/MacOS/ViddyDictate' | head -n1)
  [ -n "$t" ] && echo "$(basename "$p" .plist) -> $t"
done
```

- No output: a clean machine. Continue.
- One result pointing at `$HOME/Applications/ViddyDictate.app`: current topology. Continue, and
  report to the user that this is an upgrade rather than a fresh install.
- Anything else: stop and show the user the labels and paths. Ask before retiring an install you did
  not create. With their approval, `launchctl bootout "gui/$(id -u)/<label>"` and remove that plist,
  then continue.

`build.sh` refuses to run in the third case, so an unchecked build fails loudly rather than breaking
the machine. Do not work around that refusal. Do not delete the old app bundle, its settings, its
sticky notes, or its dictation history as part of this; the installers migrate what they own.

## 3. Verify the checkout

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

## 4. Create stable signing and build

Run:

```sh
./setup-signing.sh
./build.sh
```

`setup-signing.sh` creates a local self-signed code-signing identity. Reusing that identity is what
keeps Accessibility and Input Monitoring grants attached to the app across rebuilds. `build.sh`
creates both `build/ViddyDictate.app` and the verification-only `build/ViddyDictateTests.app`.

If your review flags this script, the flag is correct and the tradeoff is documented in
[docs/signing-and-tcc.md](docs/signing-and-tcc.md): the keychain password is published in the repo,
auto-lock is disabled, and the TCC grants are pinned to the certificate and bundle identifier rather
than the binary hash, so a same-user process can reach those grants. Surface that page to the user
and let them decide. Do not silently harden the script, and do not halt the install over it without
telling them the supported alternative, which is skipping `setup-signing.sh` and running the ad-hoc
build from `build/` at the cost of re-granting permissions after every rebuild and losing the
`~/Applications` install and auto-start.

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

## 5. Install the local services and app

Run the repository's installers rather than recreating their work manually:

```sh
./install-daemon.sh
./install-app-agent.sh
```

The web-search helper is genuinely optional and is deliberately not in that sequence. Ask the user
before running it, because it adds a DuckDuckGo client and is the only component that queries a
search engine:

```sh
./install-websearch-helper.sh
```

Skipping it leaves local web search on right Option+L unavailable and changes nothing else. A user
who declines it has a complete, working install.

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

## 6. Verify what the agent can verify

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

## 7. Hand the human the remaining steps

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

## 8. Report exact state

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
5. If the user reports the keyboard itself is unresponsive, stop installing and say so plainly: a
   process holding the event tap was destroyed rather than stopped. Logging out and back in clears
   it. Then complete section 2 before touching the build again.
6. If transcription fails while `/health` answers, confirm `ffmpeg` is on the daemon's configured
   PATH and wait for the first model warmup.
7. If Claude transforms fail, use the Setup tab and `claude auth status --json`. If Codex transforms
   fail, use the Setup tab because ViddyDictate's dedicated Codex state is intentionally separate.
