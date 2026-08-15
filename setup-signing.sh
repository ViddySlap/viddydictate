#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity in a dedicated keychain so every rebuild keeps
# the same signature. macOS then preserves the Accessibility / Input-Monitoring grants across
# rebuilds (ad-hoc signatures change each build and lose the grant). Run once.

CN="ViddyDictate Self-Signed"
KC="$HOME/Library/Keychains/vd-signing.keychain-db"
KCPASS="vd-signing-local"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "[signing] identity already present — nothing to do"
  exit 0
fi

echo "[signing] creating dedicated keychain"
security delete-keychain "$KC" 2>/dev/null
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"             # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KC"

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

echo "[signing] importing identity"
security import "$TMP/id.p12" -k "$KC" -P x -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
rm -rf "$TMP"

# add our keychain to the user search list, keeping the existing ones
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')
security list-keychains -d user -s "$KC" $EXISTING >/dev/null 2>&1

echo "[signing] codesigning identities:"
security find-identity -v -p codesigning
