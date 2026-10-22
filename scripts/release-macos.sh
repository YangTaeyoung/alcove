#!/usr/bin/env bash
# Build local, notarized release artifacts with Sparkle 2 automatic update support.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != arm64 ]]; then
  echo 'This release script currently supports Apple Silicon (arm64) only.' >&2
  exit 1
fi

SIGN_IDENTITY="${ALCOVE_SIGN_IDENTITY:-Developer ID Application: Taeyoung Yang (G54PSSU8W5)}"
NOTARY_PROFILE="${ALCOVE_NOTARY_PROFILE:-kiln-notary}"

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "A Developer ID Application identity is required for release (got: $SIGN_IDENTITY)" >&2
  exit 1
fi

CONFIG="scripts/release-config.json"
KEY_ACCOUNT=$(python3 -c 'import json; print(json.load(open("'"$CONFIG"'"))["sparkle_key_account"])')
EXPECTED_PUBKEY=$(python3 -c 'import json; print(json.load(open("'"$CONFIG"'"))["sparkle_public_key"])')

# Read version and build from Alcove/Info.plist
VERSION=$(python3 -c 'import plistlib; print(plistlib.load(open("Alcove/Info.plist", "rb"))["CFBundleShortVersionString"])')
BUILD=$(python3 -c 'import plistlib; print(plistlib.load(open("Alcove/Info.plist", "rb"))["CFBundleVersion"])')

if [[ -n "${1:-}" && "${1:-}" != "--install" && "${1:-}" != "$VERSION" ]]; then
  echo "Usage: $0 [VERSION] [--install] (current version is $VERSION, build $BUILD)" >&2
  exit 1
fi

echo "==> Verifying notarytool credentials with profile '$NOTARY_PROFILE'..."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null

echo "==> Fetching Sparkle and checking EdDSA signing key for '$KEY_ACCOUNT'..."
python3 scripts/fetch-sparkle.py
PUBLIC_KEY=$(build/vendor/sparkle/bin/generate_keys --account "$KEY_ACCOUNT" -p)
if [[ "${PUBLIC_KEY//[$'\t\r\n ']/}" != "${EXPECTED_PUBKEY//[$'\t\r\n ']/}" ]]; then
  echo "ERROR: Sparkle public key mismatch for account $KEY_ACCOUNT." >&2
  echo "  Keychain: $PUBLIC_KEY" >&2
  echo "  Config:   $EXPECTED_PUBKEY" >&2
  exit 1
fi

echo "==> Building helper binaries (alcove-proxy, alcovectl)..."
mkdir -p build
( cd guest-tools && go build -o ../build/alcove-proxy ./cmd/alcove-proxy )
( cd AlcoveKit && swift build -c release --product alcovectl )

echo "==> Regenerating Xcode project and building Alcove $VERSION ($BUILD) in Release configuration..."
xcodegen generate > /dev/null
xcodebuild -project Alcove.xcodeproj -scheme Alcove -configuration Release -derivedDataPath build/DerivedData build

APP="build/DerivedData/Build/Products/Release/Alcove.app"
if [[ ! -d "$APP" ]]; then
  echo "ERROR: $APP was not created." >&2
  exit 1
fi

# Ensure alcovectl and alcove-proxy are copied into the bundle
cp -f AlcoveKit/.build/release/alcovectl "$APP/Contents/MacOS/alcovectl"
cp -f build/alcove-proxy "$APP/Contents/MacOS/alcove-proxy"

echo "==> Signing bundle with '$SIGN_IDENTITY' and hardened runtime..."
python3 scripts/sign-nested.py "$APP" "$SIGN_IDENTITY"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Submitting $APP to Apple Notary Service..."
OUT="build/distribution/$VERSION"
mkdir -p "$OUT"
NOTARIZE_ZIP="$OUT/Alcove-$VERSION-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/notarization-result.json"
python3 - "$OUT/notarization-result.json" <<'PY'
import json, sys
from pathlib import Path
res = json.loads(Path(sys.argv[1]).read_text())
status = res.get('status')
if status != 'Accepted':
    print(json.dumps(res, indent=2))
    raise SystemExit(f'Notarization failed with status: {status}')
print(f"Notarization Accepted! Submission ID: {res.get('id')}")
PY

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ARCH=$(uname -m)
ARCHIVE="$OUT/Alcove-$VERSION-macos-$ARCH.zip"
echo "==> Creating release archive $ARCHIVE..."
ditto -c -k --keepParent "$APP" "$ARCHIVE"

echo "==> Signing Sparkle update..."
build/vendor/sparkle/bin/sign_update --account "$KEY_ACCOUNT" "$ARCHIVE" > "$OUT/signature.txt"
python3 scripts/make-appcast.py "$VERSION" "$BUILD" "$ARCHIVE" "$OUT/signature.txt"

( cd "$OUT" && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt )
rm -f "$NOTARIZE_ZIP"

echo "=========================================================="
echo "Release artifacts ready in: $OUT"
echo "  - Archive:   $ARCHIVE"
echo "  - Appcast:   $OUT/appcast.xml"
echo "  - Checksums: $OUT/SHA256SUMS.txt"
echo "=========================================================="

if [[ "${1:-}" == "--install" || "${2:-}" == "--install" ]]; then
  echo "==> Installing $APP to /Applications/Alcove.app..."
  rm -rf /Applications/Alcove.app.new
  cp -R "$APP" /Applications/Alcove.app.new
  rm -rf /Applications/Alcove.app
  mv /Applications/Alcove.app.new /Applications/Alcove.app
  echo "Installed /Applications/Alcove.app successfully."
fi
