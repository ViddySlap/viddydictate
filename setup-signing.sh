#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity in a dedicated keychain so every rebuild keeps
# the same signature. macOS then preserves the Accessibility / Input-Monitoring grants across
# rebuilds (ad-hoc signatures change each build and lose the grant). Run once.
#
# Security posture, in full in docs/signing-and-tcc.md. The short version: macOS pins those grants
# to this CERTIFICATE plus the bundle id, not to the binary hash. That is what lets a rebuild keep
# its permissions, and it also means anything signed with this key inherits ViddyDictate's
# Accessibility and Input Monitoring. So the key is protected by a password that YOU choose and that
# is never written to disk, on a keychain that auto-locks. A locked keychain cannot sign: macOS
# stops and asks for the password. That is the boundary.
#
# The previous version of this script used a fixed password published in this file, on a keychain
# configured never to lock. Any process running as you could read the password here and sign
# silently. If you set up before that change, see "Re-keying an older install" in the doc.
set -uo pipefail

CN="ViddyDictate Self-Signed"
KC="$HOME/Library/Keychains/vd-signing.keychain-db"
MIN_LEN=12

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "[signing] identity already present - nothing to do"
  exit 0
fi

if [ -f "$KC" ]; then
  echo "[signing] ERROR: $KC exists but holds no usable identity."
  echo "[signing]        Remove it deliberately before re-running. A NEW identity resets the"
  echo "[signing]        Accessibility / Input Monitoring grants:"
  echo "[signing]            security delete-keychain \"$KC\""
  exit 1
fi

if [ ! -t 0 ]; then
  echo "[signing] ERROR: this step is interactive and must be run by a human in a terminal."
  echo "[signing]        It asks you to choose a keychain password that is never stored."
  exit 1
fi

cat <<NOTE
[signing]
[signing] Choose a password for a new keychain that will hold ViddyDictate's code-signing key.
[signing]
[signing]   - It is NOT saved anywhere. Put it in your password manager now.
[signing]   - Anyone who reaches this Mac can copy the keychain file and guess offline at full
[signing]     speed, so LENGTH is what protects it. Four unrelated words is strong and memorable,
[signing]     for example: cinder-walnut-transit-oyster
[signing]   - Minimum $MIN_LEN characters.
[signing]   - Losing it does not brick anything. Delete the keychain, re-run this script, rebuild,
[signing]     and re-grant the three macOS permissions once.
[signing]
NOTE

printf '[signing] keychain password: '
read -rs KCPASS; echo
printf '[signing] confirm password:  '
read -rs KCPASS2; echo

if [ "$KCPASS" != "$KCPASS2" ]; then
  echo "[signing] ERROR: passwords did not match. Nothing was created."
  exit 1
fi
unset KCPASS2
if [ "${#KCPASS}" -lt "$MIN_LEN" ]; then
  echo "[signing] ERROR: password is shorter than $MIN_LEN characters. Nothing was created."
  exit 1
fi

cleanup() { unset KCPASS; rm -rf "${TMP:-}"; }
trap cleanup EXIT

echo "[signing] creating dedicated keychain"
security create-keychain -p "$KCPASS" "$KC" || { echo "[signing] ERROR: create failed"; exit 1; }

# Auto-lock after 15 minutes idle AND on sleep. The stock behaviour was to never lock, which left
# the signing key usable for the whole login session.
security set-keychain-settings -t 900 -l "$KC"
security unlock-keychain -p "$KCPASS" "$KC" || { echo "[signing] ERROR: unlock failed"; exit 1; }

echo "[signing] generating self-signed code-signing cert"
TMP="$(mktemp -d)"
cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=v3
[dn]
CN=$CN
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" >/dev/null 2>&1
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CN" -passout pass:x 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$CN" -passout pass:x

# -T names codesign as the tool allowed to use this key. Deliberately NO -A, which would let every
# application on the machine use it.
echo "[signing] importing identity"
security import "$TMP/id.p12" -k "$KC" -P x -T /usr/bin/codesign

# Required: without a partition list macOS will not resolve this as a usable signing identity at
# all (`find-identity` reports zero), so build.sh could neither verify nor use it. It does NOT
# weaken the password gate. An attacker still cannot sign while the keychain is locked.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1

# The keychain is deliberately NOT added to the user search list. build.sh passes --keychain
# explicitly, which keeps it off the path every other tool walks.

echo "[signing] codesigning identities in this keychain:"
security find-identity -v -p codesigning "$KC"

echo "[signing] locking the keychain"
security lock-keychain "$KC"

cat <<'DONE'
[signing]
[signing] Done. ./build.sh will ask for this password when the keychain is locked. If you lose it,
[signing] see "Re-keying an older install" in docs/signing-and-tcc.md.
[signing]
DONE
