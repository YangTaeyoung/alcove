# Alcove

Alcove is a native macOS virtual machine app for Apple silicon, built the way
Parallels and VMware Fusion are built: a hardware-accelerated engine underneath
(QEMU on Apple's Hypervisor.framework) and everything the user touches written
from scratch on top of it — the app, the display path, the guest integration
tools, snapshots, USB, and eventually Coherence-style window integration and
GPU acceleration.

Status: **early development**. See `docs/superpowers/specs/` for the design and
`docs/superpowers/plans/` for the roadmap.

## Layout

| Path | What |
|---|---|
| `docs/` | design spec, roadmap, research notes on QEMU internals |
| `qemu-patches/` | the out-of-tree patch series applied on top of a pinned QEMU tag |
| `scripts/` | reproducible build of the QEMU engine, image tooling, test helpers |
| `Alcove/` | the Swift macOS app (AppKit + SwiftUI + Metal) |
| `AlcoveKit/` | Swift package: display protocol, QMP client, engine (VM bundles, controller), agent client, `alcovectl` CLI |
| `guest-tools/` | Go guest agent for Windows and Linux (clipboard, file drop, exec, shutdown) |
| `build/`, `images/` | ignored: QEMU source/build trees, disk images, ISOs |

## Engine

Alcove pins QEMU `v11.1.1` and applies `qemu-patches/*.patch` at build time
(`scripts/build-qemu.sh`). QEMU is GPL-2.0-only; the patches are published
under the same license. The Alcove app runs QEMU as a separate process and
talks to it over sockets, so the app itself is licensed independently
(license to be decided before the first public release).

## Building

```
scripts/build-qemu.sh                 # engine: build/qemu-build/qemu-system-aarch64 (+ alcove display patch)
python3 scripts/test/display-backend.py   # boots EDK2 only and drives the display protocol end to end
scripts/test/boot-ubuntu.sh           # Ubuntu cloud image under HVF, waits for the serial login prompt
python3 scripts/test/install-windows.py --fresh   # unattended Windows 11 ARM64 install (needs images/Win11_*.iso)
(cd AlcoveKit && swift test)          # library tests (the VMController tests boot the real engine)
(cd guest-tools && go test ./...)     # guest agent tests
xcodegen generate && xcodebuild -project Alcove.xcodeproj -scheme Alcove build
scripts/test/all.sh                   # everything above except the Windows install
```

VM bundles live in `~/Library/Application Support/Alcove/VMs` (override with
`ALCOVE_VM_DIR`); the engine is found through `ALCOVE_QEMU_DIR`, the app
bundle, or `build/qemu-build`. `alcovectl` (`swift build --product alcovectl`
in `AlcoveKit`) creates, lists and runs bundles from the command line.

Guest agent: `cd guest-tools && GOOS=windows GOARCH=arm64 go build ./cmd/alcove-agent`
(or `GOOS=linux`), copy it into the guest and run `alcove-agent --install`.
`scripts/test/agent-windows.py` and `agent-linux.py` do this over SSH against the
test VMs and check clipboard sync, file push and exec.

## Requirements

- Apple silicon Mac, macOS 15 or later (developed on macOS 26)
- Xcode 26
- Homebrew packages: `meson pkgconf ninja glib pixman dtc libslirp capstone libusb zstd swtpm xcodegen go`
- Python 3.11+ for QEMU's configure (Homebrew `python3`)
- A Windows 11 ARM64 ISO from Microsoft for Windows guests (see `scripts/fetch-windows-iso.sh`)
