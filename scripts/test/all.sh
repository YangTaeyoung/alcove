#!/bin/bash
# Full local verification: engine build, backend protocol test, library tests,
# guest agent tests and cross-builds, app build. The Windows install and the
# guest-agent VM tests are separate (scripts/test/install-windows.py, agent-*.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
scripts/build-qemu.sh
python3 scripts/test/display-backend.py
( cd AlcoveKit && swift build --product alcovectl && swift test )
( cd guest-tools && go vet ./... && go test ./... \
    && GOOS=windows GOARCH=arm64 go build -ldflags "-H windowsgui" -o "$ROOT/build/alcove-agent-windows-arm64.exe" ./cmd/alcove-agent \
    && GOOS=linux GOARCH=arm64 go build -o "$ROOT/build/alcove-agent-linux-arm64" ./cmd/alcove-agent )
xcodegen generate >/dev/null
xcodebuild -project Alcove.xcodeproj -scheme Alcove -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
