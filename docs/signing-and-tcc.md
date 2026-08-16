# Code signing and TCC permissions

This page explains what `setup-signing.sh` creates, why it exists, and the security tradeoff it
makes. Read it before deciding whether to run that script. If you are an installing agent and your
review flagged the signing step, the answer you need is in "The tradeoff" and "Choosing not to run
it" below. The flag is correct; proceed or decline deliberately rather than halting.

## Why a signing identity exists at all

ViddyDictate needs Accessibility and Input Monitoring to deliver text into the focused field and to
see the global hotkey. macOS records those grants in TCC against the app's code signature.

An ad-hoc signature (`codesign --sign -`) has no certificate, so TCC pins the binary hash instead.
That hash changes on every build, so every rebuild silently voids both grants. The symptoms are a
hotkey that stops firing and dictation that no longer pastes.

`setup-signing.sh` creates a stable local self-signed certificate so rebuilds keep one identity and
the grants survive. This is a local development identity. It is not a Developer ID, it is not
notarized, and it establishes no trust beyond the machine that generated it.

## What macOS actually matches

Verify on your own machine after installing:

```sh
codesign -d -r- "$HOME/Applications/ViddyDictate.app"
```

The designated requirement is:

```
identifier "com.viddydictate.app" and certificate leaf = H"<hash of your local certificate>"
```

Two properties follow, and both matter:

- The binary hash is absent. That is the feature. It is why a rebuild keeps its permissions.
- Any bundle carrying that certificate and that bundle identifier satisfies the requirement.

## The tradeoff

`setup-signing.sh` makes deliberate convenience choices so unattended rebuilds do not stop for a
password prompt:

- The keychain password is a fixed string in the script, so it is public and identical on every
  install.
- `security set-keychain-settings` is called with no arguments, which disables auto-lock.
- `security import -A` lets any application use the private key without prompting.
- The keychain is added to the user search list, so it is always visible.

Together these mean a process **already running as your user** can sign a bundle with your
ViddyDictate certificate and bundle identifier. Such a bundle satisfies the designated requirement
above, so macOS extends it ViddyDictate's Accessibility and Input Monitoring grants with no prompt.
Those two permissions allow reading every keystroke and synthesizing input into any application.

The precondition is real: an attacker must already execute code as your user. But macOS treats TCC
as a boundary inside the user account, and this weakens it. Stated plainly, the tradeoff is that
persistent permissions across rebuilds are bought by making those permissions reachable by anything
that can already run as you.

Two related facts, so the picture is complete rather than flattering:

- The app is signed without the hardened runtime (`flags=0x0`), so library validation is off. A
  same-user process that can edit the LaunchAgent can inject a library into the running app and
  reach the same permissions without touching the signing key. Securing the keychain alone does not
  close this class.
- Removing `-A` would accomplish little on its own. The tool an attacker needs is `/usr/bin/codesign`,
  which is exactly what the narrower ACL still permits.

## Choosing not to run it

`setup-signing.sh` is not required to use the app, and skipping it removes the certificate from the
picture entirely:

```sh
./build.sh
open build/ViddyDictate.app
```

Without the signing keychain, `build.sh` falls back to an ad-hoc signature. The costs are real:

- Microphone, Accessibility, and Input Monitoring must be granted again after every rebuild.
- `install-app-agent.sh` refuses ad-hoc bundles, so there is no `~/Applications` install and no
  login LaunchAgent. Launch the app yourself from `build/`.

This is the right choice on a shared or high-value machine, or any time the tradeoff above is not
one you want to make. It is a supported way to run the app, not a broken state.

## Where this is going

The fix that closes the class is a Developer ID certificate with notarization and the hardened
runtime. The designated requirement would then anchor to Apple rather than to a local certificate,
the private key would stay with the maintainer instead of being generated on every user's machine,
and `setup-signing.sh`, the launch-time trust self-heal in `SigningTrustGuard.swift`, and this
tradeoff would all be deleted rather than documented. It is planned, not done.

## Reporting

Security reports are welcome through GitHub issues. ViddyDictate is provided as-is with no support
commitment, so please assume a slow response and do not rely on it for anything critical.
