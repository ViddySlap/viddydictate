# Releasing ViddyDictate

Maintainer-facing. This is how a distributable build is produced: a notarized, stapled `.dmg` that
any Apple Silicon Mac can download and open with no Gatekeeper warning, no Xcode, no signing setup,
and no build step.

That artifact is the point. A released `.dmg` replaces the entire clone-and-compile path for
ordinary users, and with it `setup-signing.sh`, the local self-signed identity, and the security
tradeoff documented in [signing-and-tcc.md](signing-and-tcc.md). Building from source stays
supported for contributors; it stops being what a normal user has to do.

## One-time setup

Both steps are human-only. An agent cannot do either, and should not be asked to.

### 1. A Developer ID Application certificate

Requires membership of the Apple Developer Program ($99/yr). Enroll as **Individual / Sole
Proprietor** unless you specifically need an organization: Organization enrollment requires a D-U-N-S
number and takes one to two weeks, where Individual is usually hours.

1. In Keychain Access: **Certificate Assistant > Request a Certificate From a Certificate
   Authority**. Enter your Apple ID email, leave CA Email blank, choose **Saved to disk**.
2. At [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates),
   create a certificate of type **Developer ID Application**, upload the request from step 1, and
   download the resulting `.cer`.
3. Double-click the `.cer` to install it into your login keychain.

Confirm it landed:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Exactly one line is the happy case. `release.sh` refuses to guess if there are several, and tells
you how to name the one you mean.

### 2. A stored notarization credential

Notarization needs an app-specific password, which is **not** your Apple ID password. Create one at
[appleid.apple.com](https://appleid.apple.com) under Sign-In and Security > App-Specific Passwords,
then store it in the keychain once:

```sh
xcrun notarytool store-credentials "viddydictate-notary" --apple-id <your-apple-id> --team-id <your-team-id>
```

It prompts for the app-specific password. **Type it into that prompt yourself.** It must never go
into a script, a file, an environment variable, a commit, or a chat window. Your Team ID is on the
[membership page](https://developer.apple.com/account) and is also the parenthesised suffix of the
identity name from step 1.

Override the profile name with `VD_NOTARY_PROFILE` if you use a different one.

## Cutting a release

```sh
./release.sh 1.0.0
```

That runs, in order: the deterministic verification gate, a hardened-runtime build signed with the
Developer ID, a signature check, notarization and stapling of the app, DMG packaging, signing,
notarization and stapling of the DMG, and finally a Gatekeeper check of both artifacts the way a
downloader's Mac would perform it. Output lands in `dist/`.

Two notarization round-trips means the run takes a few minutes, mostly waiting on Apple. Both are
deliberate: a DMG-only staple validates while Gatekeeper can reach Apple, but a stapled `.app`
validates offline and keeps working after the user drags it out of the disk image.

The script refuses rather than degrading, on: a dirty working tree, a missing or ambiguous Developer
ID, a designated requirement that does not anchor to Apple, a missing hardened runtime, a failed gate,
or a failed notarization. **A release that cannot be signed properly must not silently become a
locally-signed or ad-hoc one**, because that difference is invisible downstream and lands on the
user as a Gatekeeper block.

Afterwards, deliberately and by hand:

```sh
git tag -a v1.0.0 -m "ViddyDictate 1.0.0"
git push origin v1.0.0
```

then attach the `.dmg` to a GitHub release.

**Test it as a stranger would before publishing.** Copy the DMG to a different Mac, or a fresh user
account, open it, drag the app across, and launch it. A Gatekeeper prompt there means the staple did
not take, and finding that yourself is much better than a first-time user finding it.

## Notes

**Version numbers are stamped, not committed.** `release.sh` passes `VD_APP_VERSION` to `build.sh`,
which writes it into the built bundle's `Info.plist` before signing. The source `Info.plist` keeps
its development value, so cutting a release never dirties the tree.

**Identities are selected by SHA-1 hash, never by name.** Two certificates can share a common name,
and `--keychain` does not disambiguate them — a sign explicitly scoped to one keychain was observed
using a same-named certificate from the search list instead, detectable only in the leaf hash of the
designated requirement. `release.sh` resolves the identity to its hash and passes that.

**Local builds are unaffected.** `build.sh` with no `VD_SIGN_IDENTITY` behaves exactly as before,
using the self-signed keychain if present and ad-hoc if not. Contributors need none of this page.

**What a Developer ID retires.** Once releases are the normal way in, `setup-signing.sh` and the
launch-time trust plumbing exist only for people building from source. The designated requirement
anchors to Apple rather than to a certificate generated on each user's machine, the private key stays
with the maintainer, and users stop being asked to create a local signing identity at all.

## Troubleshooting

Notarization failures come back with a submission id. The rejection reason is in the log, not the
submit output:

```sh
xcrun notarytool log <submission-id> --keychain-profile "viddydictate-notary"
```

The common causes are a missing hardened runtime, a missing secure timestamp, or an unsigned nested
binary — `release.sh` checks the first two before submitting, and `codesign --verify --deep --strict`
catches the third.

If `spctl` rejects the app while `stapler validate` passes, the ticket is attached but the signature
itself is the problem; re-read the designated requirement and confirm it anchors to Apple.
