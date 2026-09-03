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
python3 scripts/test/install-windows.py --fresh   # unattended Windows 11 ARM64 install (needs the images below); without --fresh: boot + re-check the installed disk
(cd AlcoveKit && swift test)          # library tests (the VMController tests boot the real engine)
(cd guest-tools && go test ./...)     # guest agent tests
xcodegen generate && xcodebuild -project Alcove.xcodeproj -scheme Alcove build
scripts/test/all.sh                   # everything above except the Windows install (re-runnable; the engine step is a no-op when the tree is already patched)
```

`scripts/build-qemu.sh` resets `build/qemu-src` to the pinned tag and re-applies
the patches on every run; edits made directly in that tree are not lost silently
but saved to `build/qemu-src-discarded-<time>.diff` before the reset, so export
them to `qemu-patches/` first (`git -C build/qemu-src diff HEAD`).

### Images

The test scripts expect these files in `images/` (git-ignored):

| File | Used by | Source |
|---|---|---|
| `noble-server-cloudimg-arm64.img` | `scripts/test/boot-ubuntu.sh` | https://cloud-images.ubuntu.com/noble/current/ |
| `virtio-win.iso` | `scripts/test/install-windows.py` | https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/ (stable ISO, includes `w11/ARM64` drivers) |
| `Win11_25H2_English_Arm64_v2.iso` | `scripts/test/install-windows.py` (file name is hard-coded) | Microsoft; `scripts/fetch-windows-iso.sh` resolves the SKU, the signed link must be fetched in a browser |

VM bundles live in `~/Library/Application Support/Alcove/VMs` (override with
`ALCOVE_VM_DIR`); the engine is found through `ALCOVE_QEMU_DIR`, the app
bundle, or `build/qemu-build`. `alcovectl` (`swift build --product alcovectl`
in `AlcoveKit`) creates, lists and runs bundles from the command line.

Guest agent: `cd guest-tools && GOOS=windows GOARCH=arm64 go build ./cmd/alcove-agent`
(or `GOOS=linux`), copy it into the guest and run `alcove-agent --install`.
`scripts/test/agent-windows.py` and `agent-linux.py` do this over SSH against the
test VMs and check clipboard sync, file push and exec.

## Automation and MCP (for Claude Code and other agents)

Alcove exposes every running VM to automation through a local control socket
(`docs/control-protocol.md`): screenshots, mouse, keyboard, typing, shell
commands in the guest (PowerShell or sh via the guest tools), clipboard and
file push. `mcp/` wraps it as an MCP server so Claude Code can drive a Windows
or Linux VM directly:

```
cd mcp && npm install && npm run build
claude mcp add alcove -- node "$PWD/dist/index.js"       # or add to .mcp.json
```

Tools: `alcove_list_vms`, `alcove_start_vm`, `alcove_stop_vm`, `alcove_vm_status`,
`alcove_screenshot`, `alcove_click`, `alcove_move_mouse`, `alcove_drag`,
`alcove_scroll`, `alcove_type`, `alcove_press_keys`, `alcove_exec`,
`alcove_get_clipboard`, `alcove_set_clipboard`, `alcove_push_file`, `alcove_wait_idle`.
When the Alcove app is not running the MCP server starts `alcovectl serve`
(headless engine) itself; set `ALCOVE_CTL` if `alcovectl` is not in a standard
place. `scripts/test/mcp-smoke.py --vm "Windows 11"` exercises the whole chain
against a real guest (screenshot, exec, Win+R, typing into Notepad, clipboard).

## Requirements

- Apple silicon Mac, macOS 15 or later (developed on macOS 26)
- Xcode 26
- Homebrew packages: `meson pkgconf ninja glib pixman dtc libslirp capstone libusb zstd libpng swtpm xcodegen go`
  (`libpng` for QMP `screendump` in PNG, the default of `install-windows.py` and `AlcoveQMP`; `build-qemu.sh` passes `--enable-png`)
- Python 3.11+ for QEMU's configure (Homebrew `python3`, a dependency of `meson`; `PYTHON=` overrides) — the macOS system `python3` (3.9) has no `tomllib` and cannot run it
- A short checkout path: unix socket paths are limited to 104 bytes on macOS and the
  test scripts create their sockets under `build/test-*/` and `$TMPDIR`; the app itself uses
  `/tmp/alcove-<uid>/<hash>/` for its sockets, so only the scripts are affected
- A Windows 11 ARM64 ISO from Microsoft for Windows guests (see `scripts/fetch-windows-iso.sh`)
