#!/bin/bash
# One-time, local-only signing identity. Never regenerate an existing certificate:
# macOS tracks the certificate + designated requirement across app rebuilds.
# Reference: Apple TN2206, Self-signed Identities and Code Designated Requirement.
set -euo pipefail
umask 077
IDENTITY="Tivano Local Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tivano-signing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

if security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$WORK/cert.pem" 2>/dev/null; then
    echo "Reusing $IDENTITY; the certificate will not be regenerated."
else
    /usr/bin/openssl req -new -newkey rsa:3072 -nodes \
        -keyout "$WORK/key.pem" -out "$WORK/request.pem" \
        -subj "/CN=$IDENTITY/" > /dev/null 2>&1
    printf '%s\n' \
        '[codesign]' \
        'basicConstraints=critical,CA:false' \
        'keyUsage=critical,digitalSignature' \
        'extendedKeyUsage=critical,codeSigning' > "$WORK/extensions.cnf"
    /usr/bin/openssl x509 -req -sha256 -days 3650 \
        -in "$WORK/request.pem" -signkey "$WORK/key.pem" \
        -extfile "$WORK/extensions.cnf" -extensions codesign \
        -out "$WORK/cert.pem" > /dev/null 2>&1
    /usr/bin/openssl rand -hex 32 > "$WORK/password"
    /usr/bin/openssl pkcs12 -export -name "$IDENTITY" \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -out "$WORK/identity.p12" -passout "file:$WORK/password"
    # Only codesign gets access, not every application (-A). The temporary PKCS#12
    # password never enters the repo or output; security import requires -P.
    security import "$WORK/identity.p12" -k "$KEYCHAIN" \
        -P "$(< "$WORK/password")" -T /usr/bin/codesign
fi

# User-domain trust, scoped to code signing. No System keychain or global
# Gatekeeper/TCC changes. macOS may ask the owner to authorize this once.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY\"" \
    || { echo "No usable private key for $IDENTITY. Check Keychain Access; do not regenerate the certificate." >&2; exit 1; }
echo "Ready. Keep this login keychain identity for every local development build."
