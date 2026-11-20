#!/bin/zsh
# Imports a signing identity exported with tools/export_cert.sh into the login
# keychain of this Mac, so that builds made here have the same designated
# requirement as builds made on the Mac the identity comes from.
# Usage: tools/import_cert.sh <file.p12> ["Certificate name"]
# The password is asked for in the terminal (or taken from P12_PASSWORD).
set -euo pipefail
IN="${1:?usage: tools/import_cert.sh <file.p12> [\"Certificate name\"]}"
NAME="${2:-WE Screenshot Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" is already in the login keychain."
  echo "Remove it first if it is a different one (Keychain Access > login > My Certificates)."
  security find-certificate -c "$NAME" -Z "$KEYCHAIN" | grep "SHA-1" || true
  exit 1
fi
if [[ -z "${P12_PASSWORD:-}" ]]; then
  read -rs "P12_PASSWORD?Password of the .p12 file: "; echo
fi
security import "$IN" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign
echo "Imported \"$NAME\""
security find-certificate -c "$NAME" -Z "$KEYCHAIN" | grep "SHA-1" || true
echo "The first signing may ask once for permission to use the key: choose Always Allow."
