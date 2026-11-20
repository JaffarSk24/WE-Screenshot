#!/bin/zsh
# Exports the signing identity (certificate and private key) into a
# password protected .p12 file, to import it on another Mac with
# tools/import_cert.sh. Every Mac that builds releases must sign with the same
# identity: the app's designated requirement contains the certificate hash, and
# both the macOS permissions and the self-updater depend on it.
# Usage: tools/export_cert.sh <file.p12> ["Certificate name"]
# The password is asked for in the terminal (or taken from P12_PASSWORD).
set -euo pipefail
OUT="${1:?usage: tools/export_cert.sh <file.p12> [\"Certificate name\"]}"
NAME="${2:-WE Screenshot Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || { echo "Certificate \"$NAME\" not found"; exit 1; }
if [[ -z "${P12_PASSWORD:-}" ]]; then
  read -rs "P12_PASSWORD?Password for the .p12 file: "; echo
  read -rs "AGAIN?Repeat the password: "; echo
  [[ "$P12_PASSWORD" == "$AGAIN" ]] || { echo "The passwords differ"; exit 1; }
fi
[[ ${#P12_PASSWORD} -ge 8 ]] || { echo "Use at least 8 characters"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# "security export" writes every identity of the keychain; the wanted one is
# picked out of that file and packed again on its own.
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$TMP/all.p12"
O=/usr/bin/openssl
$O pkcs12 -in "$TMP/all.p12" -passin "pass:$P12_PASSWORD" -nodes -out "$TMP/all.pem" 2>/dev/null
/usr/bin/python3 - "$TMP/all.pem" "$NAME" "$TMP" <<'PY'
import re, subprocess, sys
pem, name, out = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
keys = re.findall(r"-----BEGIN (?:RSA )?PRIVATE KEY-----.*?-----END (?:RSA )?PRIVATE KEY-----", pem, re.S)
def modulus(kind, text):
    cmd = ["/usr/bin/openssl", "x509" if kind == "cert" else "rsa", "-noout", "-modulus"]
    return subprocess.run(cmd, input=text.encode(), capture_output=True).stdout
for cert in certs:
    subject = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject"], input=cert.encode(), capture_output=True).stdout.decode()
    if name not in subject:
        continue
    for key in keys:
        if modulus("cert", cert) == modulus("key", key):
            open(out + "/cert.pem", "w").write(cert + "\n")
            open(out + "/key.pem", "w").write(key + "\n")
            sys.exit(0)
sys.exit("The identity was not found in the export")
PY
$O pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$OUT" -passout "pass:$P12_PASSWORD"
chmod 600 "$OUT"
echo "Exported \"$NAME\" to $OUT"
echo "SHA-1 of the certificate: $($O x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
