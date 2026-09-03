#!/bin/bash
# Windows 11 ARM64 ISO: Microsoft's software-download-connector API.
# Step 1 (session tag) and step 2 (SKU list) work from curl; step 3 (the
# signed download link) is rejected by Microsoft's "Sentinel" bot check for
# non-browser clients as of 2026-09. This script performs steps 1-2 and prints
# the SKU so a human (or a browser automation) can finish on
#   https://www.microsoft.com/en-us/software-download/windows11arm64
# Usage: scripts/fetch-windows-iso.sh [language-display-name]   (default: "English (United States)")
# Exit: 0 with the download URL(s) on stdout; 1 on a lookup error (edition or
# language not found); 2 when step 3 was rejected (finish in a browser).
set -euo pipefail
LANG_NAME="${1:-English (United States)}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
PAGE="https://www.microsoft.com/en-us/software-download/windows11arm64"
API="https://www.microsoft.com/software-download-connector/api"
PROFILE="606624d44113"
SID="$(uuidgen | tr 'A-Z' 'a-z')"
# `|| true`: with pipefail a page without the <option> match would make grep's
# exit 1 abort the script before the message below.
EDITION="$(curl -sS -A "$UA" "$PAGE" | grep -Eo '<option value="[0-9]+">Windows 11' | head -1 | cut -d'"' -f2 || true)"
[ -n "$EDITION" ] || { echo "could not find product edition id on $PAGE" >&2; exit 1; }
curl -sS -A "$UA" -o /dev/null "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$SID"
SKUS="$(curl -sS -A "$UA" -H "Referer: $PAGE" -H "Accept: application/json" \
  "$API/getskuinformationbyproductedition?profile=$PROFILE&ProductEditionId=$EDITION&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$SID")"
# Resolve the SKU once: id on stdout, details on stderr, exit 1 if the
# language is not offered (so the script stops instead of querying SKU=).
SKU="$(python3 - "$SKUS" "$LANG_NAME" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); d = json.loads(d) if isinstance(d, str) else d
want = sys.argv[2]
if not isinstance(d, dict) or "Skus" not in d:
    print("unexpected SKU response:", json.dumps(d)[:400], file=sys.stderr)
    sys.exit(1)
for s in d["Skus"]:
    if s.get("LocalizedLanguage") == want or s.get("Language") == want:
        print(f"edition={d.get('ProductEditionId','?')} sku={s['Id']} product={s['ProductDisplayName']} language={s['LocalizedLanguage']}", file=sys.stderr)
        print(s["Id"])
        break
else:
    print(f"language {want!r} not found; available:", [s.get("LocalizedLanguage") for s in d["Skus"]], file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1
[ -n "$SKU" ] || { echo "no SKU for language '$LANG_NAME'" >&2; exit 1; }
echo "session=$SID sku=$SKU" >&2
LINKS="$(curl -sS -A "$UA" -H "Referer: $PAGE" -H "Accept: application/json" \
  "$API/GetProductDownloadLinksBySku?profile=$PROFILE&ProductEditionId=$EDITION&SKU=$SKU&friendlyFileName=undefined&Locale=en-US&sessionID=$SID")"
echo "$LINKS" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read()); d=json.loads(d) if isinstance(d,str) else d
errs=d.get('Errors') or d.get('ValidationContainer',{}).get('Errors')
if errs: print('download-link step rejected:', errs[0].get('Value'), file=sys.stderr); print('finish in a browser at $PAGE', file=sys.stderr); sys.exit(2)
for o in d.get('ProductDownloadOptions',[]): print(o.get('Uri'))
"
