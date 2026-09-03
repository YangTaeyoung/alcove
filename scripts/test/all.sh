#!/bin/bash
# Full local verification: engine build, backend protocol test, library tests, app build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
scripts/build-qemu.sh
python3 scripts/test/display-backend.py
( cd AlcoveKit && swift test )
xcodegen generate >/dev/null
xcodebuild -project Alcove.xcodeproj -scheme Alcove -configuration Debug -derivedDataPath build/DerivedData build | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
