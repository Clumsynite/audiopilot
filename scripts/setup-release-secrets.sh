#!/bin/bash
# One-time: stores UPDATE_SIGNING_KEY (signs update.json) and SIGNING_P12[_PASSWORD] (keeps permissions across
# updates) as GitHub secrets. Without a .p12 argument it exports the login keychain's only Apple Development or
# Developer ID identity (macOS asks to allow it):   scripts/setup-release-secrets.sh [identity.p12]
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_FILE="${UPDATE_KEY_FILE:-$HOME/.config/audiopilot/update-signing-key}"

[[ -f "$KEY_FILE" ]] || { echo "error: $KEY_FILE not found (swift scripts/update-key.swift generate $KEY_FILE)" >&2; exit 1; }
gh secret set UPDATE_SIGNING_KEY < "$KEY_FILE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSWORD="$(openssl rand -base64 24)"
if [[ $# -ge 1 ]]; then
    read -rsp "Password for $1: " SOURCE_PASSWORD; echo
    openssl pkcs12 -in "$1" -passin "pass:$SOURCE_PASSWORD" -nodes -out "$WORK/identity.pem"
else
    IDENTITIES="$(security find-identity -v -p codesigning | grep -E '"(Apple Development|Developer ID Application):' || true)"
    COUNT="$(printf '%s' "$IDENTITIES" | grep -c . || true)"
    if [[ "$COUNT" != 1 ]]; then
        echo "error: found $COUNT signing identities; export the one to use from Keychain Access and pass the .p12" >&2
        exit 1
    fi
    echo "Exporting: $(echo "$IDENTITIES" | awk -F'"' '{print $2}')"
    security export -t identities -f pkcs12 -P "$PASSWORD" -o "$WORK/all.p12"
    openssl pkcs12 -in "$WORK/all.p12" -passin "pass:$PASSWORD" -nodes -out "$WORK/identity.pem"
fi
# Re-pack with a fresh password in a format the runner's keychain imports.
openssl pkcs12 -export -legacy -in "$WORK/identity.pem" -out "$WORK/identity.p12" -passout "pass:$PASSWORD" 2>/dev/null \
    || openssl pkcs12 -export -in "$WORK/identity.pem" -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
base64 -i "$WORK/identity.p12" | gh secret set SIGNING_P12
printf '%s' "$PASSWORD" | gh secret set SIGNING_P12_PASSWORD
echo "Set UPDATE_SIGNING_KEY, SIGNING_P12 and SIGNING_P12_PASSWORD."
