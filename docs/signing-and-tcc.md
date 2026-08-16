# Code signing and TCC permissions

This page explains what `setup-signing.sh` creates, why it exists, and the security tradeoff it
makes. Read it before deciding whether to run that script. If you are an installing agent and your
review flagged the signing step, the answer you need is in "What protects the key" and "Choosing not
to run it" below. The flag is correct; proceed or decline deliberately rather than halting.

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

## What protects the key

Because the certificate is what grants the permissions, the private key is the asset. It is
protected by one gate that actually holds: **a password you choose, which is never written to
disk, on a keychain that locks.**

- `setup-signing.sh` asks you for the password and never stores it. Nothing in the repository or on
  the filesystem contains it.
- The keychain auto-locks after 15 minutes idle and on sleep, so its resting state is locked. It is
  unlocked only while you are actively building.
- **A locked keychain cannot sign.** macOS stops and asks for the password. That is the boundary,
  and it is verifiable: lock the keychain and try to `codesign` with the identity.

The key is imported with `-T /usr/bin/codesign` and deliberately **without** `-A`, which would let
every application use it. The keychain is also left out of the user search list; `build.sh` passes
`--keychain` explicitly, so nothing needs to find it by searching.

One thing that is *not* a gate, despite looking like one. `setup-signing.sh` does set a key
partition list. Omitting it does force an approval dialog per signing operation, which sounds
stronger, but macOS then declines to resolve the certificate and key as a usable signing identity at
all, so `build.sh` can neither verify nor use it. The partition list is required for the identity to
function. It costs nothing here, because it only governs access to an **unlocked** keychain, and
this keychain is locked whenever a build is not running.

The app is also signed with the hardened runtime (`flags=0x10000`), which turns on library
validation. Without it, a same-user process could inject a library into the running app and reach
Accessibility without ever touching the signing key. Closing that path matters as much as protecting
the key, because an attacker only needs one of the two.

## What this does and does not stop

An attacker running as your user must now obtain a password that is written down nowhere on the
machine. Previously they only had to read this repository. That is a real boundary rather than a
lookup, and it is the difference the hardening buys.

It is not absolute, and the honest limits are:

- **Offline guessing.** An attacker who copies the keychain file can guess at full speed on their
  own hardware. Length is what defends against this, which is why the script asks for a passphrase
  rather than a short password.
- **The unlocked window.** While you are building, the keychain is unlocked. The auto-lock timer
  bounds that window; it does not eliminate it.
- **Saving the password where a script can read it.** Putting it in a plain file, a shell profile,
  or a `-p` flag in your own wrapper undoes the entire design, because anything running as you can
  then read it. A password manager is fine; a dotfile is not.
- **Existing installs.** A keychain created before this hardening carries a password published in
  the repository's history, never locks, and was imported with `-A`. `build.sh` still unlocks those
  so they keep building, which means they keep the old exposure in full. Re-keying is the only fix.
  See below.

## Re-keying an older install

If you ran `setup-signing.sh` before this hardening, your keychain is the permissive kind. Moving to
the hardened one mints a new certificate, which changes the designated requirement and therefore
**resets Accessibility, Input Monitoring, and Microphone**. That is a deliberate one-time cost:

```sh
security delete-keychain "$HOME/Library/Keychains/vd-signing.keychain-db"
./setup-signing.sh
./build.sh
./install-app-agent.sh
```

Then grant the three permissions again in System Settings > Privacy & Security, and delete the stale
ViddyDictate entries there so the list is unambiguous. There is no way to keep the old grants and
drop the old key, because the grants are pinned to that key.

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
and `setup-signing.sh`, the remaining trust plumbing in `SigningTrustGuard.swift`, and this whole
tradeoff would be deleted rather than documented. It is planned, not done.

## Reporting

Security reports are welcome through GitHub issues. ViddyDictate is provided as-is with no support
commitment, so please assume a slow response and do not rely on it for anything critical.
