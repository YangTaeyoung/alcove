#!/bin/bash
# Full local verification: engine build, backend protocol test, library tests,
# guest agent tests and cross-builds (agent, fixture app), MCP server build and
# tests, app build. The Windows install and the VM runs are separate
# (scripts/test/install-windows.py, install-agent.py, agent-*.py,
# uia-helper-check.py, at1-e2e.py ... at7-e2e.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
scripts/build-qemu.sh
python3 scripts/test/display-backend.py
python3 scripts/test/install-windows.py --selftest
( cd AlcoveKit && swift build --product alcovectl && swift test )
( cd guest-tools && go vet ./... && GOOS=windows go vet ./... && go test ./... \
    && GOOS=windows GOARCH=arm64 go build -ldflags "-H windowsgui" -o "$ROOT/build/alcove-agent-windows-arm64.exe" ./cmd/alcove-agent \
    && GOOS=windows GOARCH=arm64 go build -ldflags "-H windowsgui" -o "$ROOT/build/alcove-fixture-windows-arm64.exe" ./cmd/alcove-fixture \
    && GOOS=linux GOARCH=arm64 go build -o "$ROOT/build/alcove-agent-linux-arm64" ./cmd/alcove-agent \
    && go build -o "$ROOT/build/alcove-proxy" ./cmd/alcove-proxy )
( cd mcp && { [ -d node_modules ] || npm ci; } && npm run build && npm test )
python3 scripts/test/mcp-smoke.py --list-only
xcodegen generate >/dev/null
xcodebuild -project Alcove.xcodeproj -scheme Alcove -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
