#!/bin/bash
# Creates a self-signed code-signing certificate ("Heads Down Local Signing") in the login keychain.
#
# Why: ad-hoc signed builds get a new identity on every rebuild, so macOS forgets the Screen
# Recording / Accessibility grants each time. Signing every build with this one certificate keeps
# the app's designated requirement stable, so grants survive rebuilds.
#
# Local development only: the certificate isn't trusted by anyone else and can't be used to
# distribute the app. Safe to re-run; it does nothing if the certificate already exists.
# Remove later with: security delete-identity -c "Heads Down Local Signing"
set -euo pipefail
name="Heads Down Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "Certificate \"$name\" already exists."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
# -legacy: OpenSSL 3 defaults to a PKCS#12 encryption macOS `security import` can't read.
legacy=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then legacy="-legacy"; fi
# shellcheck disable=SC2086
openssl pkcs12 -export $legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
    -out "$tmp/identity.p12" -passout pass:headsdown
# -T lets codesign use the private key without a keychain prompt on every build.
security import "$tmp/identity.p12" -k "$keychain" -P headsdown -T /usr/bin/codesign >/dev/null
echo "Created certificate \"$name\" in the login keychain."
