## What and why

<!-- What changes, and what problem it solves. Link the issue if there is one. -->

## How it was tested

<!-- Which of the boxes below you ticked, on which guest, and what you could
     not test here (no Windows ISO, no second display, etc.). -->

## Checklist

CI builds and tests the Swift package, the Go guest tools and the MCP server.
Everything that needs the QEMU engine, a guest or the app build is covered only
by this list. Tick what you ran, delete what does not apply.

- [ ] `scripts/test/all.sh` passes (engine build, `display-backend.py`,
      `install-windows.py --selftest`, `swift build --product alcovectl && swift test`,
      `go vet ./... && go test ./...` plus the agent cross-builds, `xcodegen generate` and `xcodebuild`)
- [ ] Swift only: `(cd AlcoveKit && swift test)`
- [ ] Go only: `(cd guest-tools && go vet ./... && go test ./...)`
- [ ] MCP: `(cd mcp && npm install && npm run build)` and `python3 scripts/test/mcp-smoke.py --list-only`
- [ ] Guest tools against a real VM: `python3 scripts/test/agent-rpc-windows.py` (after `python3 scripts/test/install-agent.py`) and/or `python3 scripts/test/agent-linux.py`
- [ ] Automation against a real VM: `python3 scripts/test/mcp-smoke.py --vm "<name>"`
- [ ] Guest boot: `scripts/test/boot-ubuntu.sh` and/or `python3 scripts/test/install-windows.py` (`--fresh` for a full install)
- [ ] Engine change: patch regenerated
      (`git -C build/qemu-src add -A && git -C build/qemu-src diff --cached HEAD > qemu-patches/0001-ui-add-alcove-display-backend.patch`)
      and a fresh `scripts/build-qemu.sh` reports the tree as already patched
- [ ] Wire-format change: the matching `docs/*-protocol.md` updated in the same commit
- [ ] New public Swift API has `///` doc comments; new behaviour has a test beside it
- [ ] No new third-party Swift dependency
- [ ] Nothing generated or downloaded is staged (`build/`, `images/`, `Alcove.xcodeproj/`, `mcp/dist/`, `mcp/node_modules/`)
