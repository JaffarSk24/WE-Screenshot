#!/bin/zsh
# Turns the JSON file Google offers for download after creating an OAuth
# client of the type "Desktop app" into google-client.local, the file
# tools/build_app.sh reads. The values are never printed.
# Usage: tools/import_google_client.sh <client_secret_....json>
set -euo pipefail
cd "$(dirname "$0")/.."
JSON="${1:?usage: tools/import_google_client.sh <client_secret_....json>}"
[[ -f "$JSON" ]] || { echo "No such file: $JSON"; exit 1; }
/usr/bin/python3 - "$JSON" google-client.local <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
client = data.get("installed") or data.get("web") or data
client_id, secret = client.get("client_id"), client.get("client_secret")
if not client_id or not secret:
    sys.exit("The file has no client_id and client_secret")
if "installed" not in data:
    print('warning: this is not a client of the type "Desktop app"')
with open(sys.argv[2], "w") as out:
    out.write("# Google OAuth client built into the app by tools/build_app.sh. Not tracked by git.\n")
    out.write(f"CLIENT_ID={client_id}\nCLIENT_SECRET={secret}\n")
os.chmod(sys.argv[2], 0o600)
print("Wrote google-client.local (client ID ends with ..." + client_id[-28:] + ")")
PY
