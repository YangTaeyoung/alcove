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
| `Alcove/` | the Swift macOS app (created in SP1) |
| `AlcoveKit/` | Swift package: VM model, QMP client, display protocol (created in SP1) |
| `guest-tools/` | Go guest agent for Linux and Windows (created in SP2) |
| `build/`, `images/` | ignored: QEMU source/build trees, disk images, ISOs |

## Engine

Alcove pins QEMU `v11.1.1` and applies `qemu-patches/*.patch` at build time
(`scripts/build-qemu.sh`). QEMU is GPL-2.0-only; the patches are published
under the same license. The Alcove app runs QEMU as a separate process and
talks to it over sockets, so the app itself is licensed independently
(license to be decided before the first public release).

## Building

```
scripts/build-qemu.sh          # engine: build/qemu-build/qemu-system-aarch64
scripts/test/boot-ubuntu.sh    # engine smoke test (Ubuntu cloud image, HVF, serial login prompt)
(cd AlcoveKit && swift test)   # library tests
xcodegen generate && xcodebuild -project Alcove.xcodeproj -scheme Alcove build
```

## Requirements

- Apple silicon Mac, macOS 15 or later (developed on macOS 26)
- Xcode 26
- Homebrew packages: `meson pkgconf ninja glib pixman dtc libslirp capstone libusb zstd swtpm xcodegen`
