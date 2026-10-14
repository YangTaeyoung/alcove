<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.png">
  <img src="docs/assets/banner-light.png" alt="Alcove — Windows and Linux on Apple silicon, built from the metal up." width="820">
</picture>

<p>
  <a href="#quick-start"><img alt="platform" src="https://img.shields.io/badge/platform-macOS%2015%2B%20·%20Apple%20silicon-0B84FF?style=flat-square"></a>
  <a href="https://github.com/YangTaeyoung/alcove/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/YangTaeyoung/alcove/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="licence" src="https://img.shields.io/badge/licence-MIT%20·%20GPL--2.0%20patches-6E7681?style=flat-square"></a>
  <a href="#automate-it-from-claude-code"><img alt="MCP" src="https://img.shields.io/badge/MCP-76%20tools-E8952E?style=flat-square"></a>
</p>

<p><b>A virtual machine app for the Mac, written from scratch on top of QEMU and Apple's Hypervisor framework —<br>and the first one your coding agent can drive by itself.</b></p>

</div>

---

Alcove runs Windows 11 ARM and Linux on Apple silicon. QEMU does the CPU and
device emulation; everything you touch above it is this repository: the app,
the display path, the guest tools, the automation API, and an MCP server so
Claude Code can take a screenshot, click a button, type, and run PowerShell
inside the guest.

<div align="center">
  <img src="docs/assets/screenshot-vm.png" alt="A Windows 11 ARM guest running in an Alcove window, with Notepad showing text typed through the MCP server" width="900">
  <br><sub>Windows 11 ARM in an Alcove window. The text in Notepad was typed by Claude Code through the MCP server.</sub>
  <br><br>
  <img src="docs/assets/screenshot-library.png" alt="The Alcove library window listing two virtual machines" width="520">
  <br><sub>Your machines, their state, one click to start.</sub>
</div>

## Why another VM app

Because the interesting part is not running a guest — it is what an agent can
do with one. Alcove exposes every running VM through a local socket and an MCP
server, so an assistant can test a Windows build, click through an installer,
or read a log inside the guest, without a human moving the mouse.

The rest is what you would expect, done properly: near-native ARM guests
through Apple's hypervisor, snapshots, suspend to disk, USB passthrough,
clipboard and file sharing.

## Features

| | |
|---|---|
| **Windows 11 ARM and Linux** | Apple silicon guests at near-native speed through `-accel hvf`. Unattended Windows install included. |
| **Our own display path** | A QEMU display backend written for this project shares the framebuffer through memory; the app draws it with Metal and sends input back over a unix socket. |
| **Guest tools** | A small Go agent for Windows and Linux: clipboard both ways, file drop, shell commands and background jobs, processes, file access, display modes that follow the window. |
| **Snapshots and suspend** | qcow2 snapshots with VM state, plus suspend-to-disk that resumes where you left off. |
| **USB passthrough** | Hot-plug host USB devices into a running guest. |
| **Agent automation** | A documented control protocol and an MCP server: screenshot, click, drag, scroll, type, key combos, shell commands and background jobs, processes, clipboard, file push, pull and folder sync, guest file read and write, recordings with a trace and a video, the guest event log, crash dumps, a one-call diagnostics bundle, and HTTP and HTTPS capture with canned, delayed or dropped answers. |
| **No black boxes** | The engine is a pinned QEMU tag plus three readable patches (`qemu-patches/`). Build it yourself in one command. |

Tested on an M3 Pro running macOS 26 with Windows 11 Pro ARM 25H2 and Ubuntu
24.04 arm64 guests.

## Quick start

```bash
brew install meson pkgconf ninja glib pixman dtc libslirp capstone libusb zstd swtpm xcodegen go
git clone git@github.com:YangTaeyoung/alcove.git && cd alcove

scripts/build-qemu.sh              # QEMU 11.1.1 + the Alcove display backend
xcodegen generate                  # generate Alcove.xcodeproj
xcodebuild -project Alcove.xcodeproj -scheme Alcove build
```

Then open the app, press **+**, pick a guest OS and an ISO. For Windows you
need an ARM64 ISO from Microsoft — `scripts/fetch-windows-iso.sh` finds the
right SKU and tells you where to download it.

Prefer the command line?

```bash
cd AlcoveKit && swift build --product alcovectl
.build/debug/alcovectl create --name "Ubuntu" --os linux --iso ~/Downloads/ubuntu.iso
.build/debug/alcovectl run "Ubuntu"
```

## Automate it from Claude Code

```bash
cd mcp && npm install && npm run build
claude mcp add alcove -- node "$PWD/dist/index.js"
```

That is it. The MCP server talks to the app when it is running and starts a
headless engine when it is not.

```
> Start the Windows VM, open Notepad and type a note, then show me the screen.

  alcove_start_vm    Windows 11: running; guest tools connected
  alcove_press_keys  pressed win+r
  alcove_type        typed 8 characters
  alcove_screenshot  1440x900 guest pixels
```

<details>
<summary><b>All 76 tools</b></summary>

| Toolset | Tool | What it does |
|---|---|---|
| `core` | `alcove_list_vms` | Every VM with state and screen size |
| `core` | `alcove_vm_status` | One VM, including whether the guest tools are connected |
| `core` | `alcove_start_vm` / `alcove_stop_vm` | Boot (waiting for the tools) or shut down |
| `core` | `alcove_screenshot` | The guest screen, a region or one window as an image, downscaled to save tokens, optionally with numbered marks on the elements to act on |
| `core` | `alcove_click` / `alcove_move_mouse` / `alcove_drag` / `alcove_scroll` | Pointer, in guest pixels |
| `core` | `alcove_type` / `alcove_press_keys` | Text and combos like `ctrl+alt+delete`, `win+r` |
| `core` | `alcove_exec` | A command in PowerShell, `cmd` or `sh`, or a program by `argv`, with working directory, environment, stdin and timeout; returns exit code, stdout and stderr |
| `core` | `alcove_get_clipboard` / `alcove_set_clipboard` | Clipboard both ways |
| `core` | `alcove_push_file` | Copy a file from the Mac into the guest, to the Desktop or to an exact path |
| `core` | `alcove_wait_idle` | Wait until the screen stops changing |
| `core` | `alcove_find_text` | Read the screen with OCR: lines of text with the point to click |
| `core` | `alcove_wait_for` | Wait for text on screen, a process, a file, a listening port, a log line or job output; on Windows guests also for a UI element, a window title or a guest event |
| `core` | `alcove_batch` | A sequence of input steps without interruption from other callers, with one screen report |
| `core` | `alcove_mouse_down` / `alcove_mouse_up` / `alcove_key_down` / `alcove_key_up` | Hold and release a mouse button or a key |
| `shell` | `alcove_exec_start` | Start a build, test run or server as a background job |
| `shell` | `alcove_exec_read` / `alcove_exec_write` | Follow a job's output by offset; write to its stdin |
| `shell` | `alcove_exec_kill` / `alcove_exec_list` | Stop a job with its process tree; list jobs and exit codes |
| `shell` | `alcove_process_list` / `alcove_process_kill` | Guest processes by name; kill by pid or name |
| `files` | `alcove_pull_file` | Copy a file from the guest to the Mac |
| `files` | `alcove_sync_dir` | Send the changed files of a Mac folder into a guest folder |
| `files` | `alcove_fs_list` / `alcove_fs_read` / `alcove_fs_write` / `alcove_fs_delete` | List a guest folder; read a text file by range or its last lines; write text; delete |
| `state` | `alcove_pause_vm` / `alcove_resume_vm` | Freeze a running VM in memory; continue it |
| `state` | `alcove_snapshot_list` / `alcove_snapshot_create` / `alcove_snapshot_restore` / `alcove_snapshot_delete` | Named disk and memory snapshots; restoring waits for the guest tools and syncs the guest clock |
| `state` | `alcove_clone_vm` / `alcove_delete_vm` | A linked clone of a stopped VM; permanently delete a clone |
| `state` | `alcove_lease_acquire` / `alcove_lease_release` | Keep other agents' state-changing calls off a VM until the lease ends |
| `state` | `alcove_port_forward_add` / `alcove_port_forward_remove` / `alcove_port_forward_list` | Forward a host port on 127.0.0.1 to a guest port |
| `state` | `alcove_set_network` / `alcove_set_resolution` / `alcove_set_environment` | Guest network link, screen resolution; theme, time zone, clock, locale, keyboard layouts and display scale |
| `state` | `alcove_doctor` | Check why a VM may not be automatable, line by line with the next step |
| `ui` | `alcove_list_windows` / `alcove_window_action` | The windows of a Windows guest with title, process and rectangle; focus, minimize, maximize, restore, close, move or resize one |
| `ui` | `alcove_ui_tree` / `alcove_ui_find` / `alcove_ui_get_text` | The UI Automation tree of a window as text with element refs; elements by role, name or automation id; the text of one element |
| `ui` | `alcove_ui_click` / `alcove_ui_type` / `alcove_ui_action` | Click an element or type into it with real input; invoke, toggle, expand, select or set a value through UI Automation |
| `ui` | `alcove_launch_app` / `alcove_deploy` | Start a program and wait for its window; copy a Mac build into the guest, run its installer and start it |
| `ui` | `alcove_events` | Window, dialog and process events of the guest in order, from a sequence number on |
| `evidence` | `alcove_record_start` / `alcove_record_stop` / `alcove_record_status` | Record every operation on a VM as a trace with frames and a video |
| `evidence` | `alcove_event_log` / `alcove_crash_dumps` | Entries of the guest's event log; crash dumps of a Windows program, copied to the Mac |
| `evidence` | `alcove_collect_diagnostics` | Screenshot, windows, UI tree, processes, logs and dumps of a VM in one directory |
| `replay` | `alcove_script_save` / `alcove_script_run` | Turn a recording into a script; replay it without a model |
| `http` | `alcove_http_capture_start` / `alcove_http_capture_stop` | Capture the HTTP and HTTPS traffic of a VM through a proxy on the Mac: the guest trusts the proxy's CA and uses it as its system proxy until the capture stops, and apps started with `alcove_launch_app` or `alcove_deploy` get the proxy environment |
| `http` | `alcove_http_requests` / `alcove_http_rule` | List captured exchanges and read their headers and bodies, streams included; answer, delay or drop matching requests to test error handling |

</details>

The server lists every toolset by default. `ALCOVE_MCP_TOOLSETS` selects some
of `core`, `shell`, `files`, `state`, `ui`, `evidence`, `replay` and `http`.
`core` has 23 tools: VM lifecycle,
screenshot, pointer, keyboard, held buttons and keys, `alcove_batch`,
`alcove_exec`, the clipboard, `alcove_push_file`, `alcove_wait_idle`,
`alcove_wait_for` and `alcove_find_text`. For example, `core` and `files`:

```bash
claude mcp add alcove -e ALCOVE_MCP_TOOLSETS=core,files -- node "$PWD/dist/index.js"
```

## How it works

```
┌──────────────────────────────────────────────────────────┐
│  Alcove.app          SwiftUI · AppKit · Metal            │
│  library · VM windows · settings · snapshots · USB       │
├───────────────┬──────────────────────┬───────────────────┤
│  AlcoveKit    │  AlcoveControl       │  alcove-mcp       │
│  engine, QMP, │  automation API      │  MCP server       │
│  display, VMs │  over a unix socket  │  (TypeScript)     │
├───────────────┴──────────────────────┴───────────────────┤
│  qemu-system-aarch64        our ui/alcove.c backend      │
│  shared-memory framebuffer · JSON input · QMP control    │
├──────────────────────────────────────────────────────────┤
│  Hypervisor.framework                       macOS        │
└──────────────────────────────────────────────────────────┘
        ▲                                    ▲
        │ TCP over user-mode networking      │
   alcove-agent (Go, in the guest): clipboard, files, shell, display modes
```

One QEMU process per VM, spawned by the app and never linked into it. The app
talks to it over three channels: a display socket with a shared-memory
framebuffer, QMP for control, and the guest agent for anything only the guest
can do.

| Document | What is in it |
|---|---|
| [`docs/display-protocol.md`](docs/display-protocol.md) | The wire format between QEMU's `alcove` display backend and the app |
| [`docs/control-protocol.md`](docs/control-protocol.md) | The automation API: screenshots, input, commands and jobs, processes, files, windows and UI elements, recordings, event log, crash dumps, diagnostics bundles, scripts saved from a recording and replayed (`script.save`, `script.run`, `alcovectl run-script`) |
| [`docs/agent-protocol.md`](docs/agent-protocol.md) | The guest agent protocol: SMBIOS token handshake, messages, and the request/response operations |
| [`docs/superpowers/specs/`](docs/superpowers/specs) | The design, and why each choice was made |
| [`docs/research/`](docs/research) | Verified notes on QEMU 11.1.1 internals, with citations |

## Repository layout

```
Alcove/          the macOS app
AlcoveKit/       Swift package: display protocol, QMP, engine, agent client,
                 control API, and the alcovectl command line tool
qemu-patches/    the display backend and two snapshot fixes (NVMe, HVF), applied to a pinned QEMU tag
guest-tools/     the Go agent that runs inside Windows and Linux guests
mcp/             the MCP server
scripts/         engine build, unattended Windows install, test harnesses
docs/            protocols, design, research notes
```

## Testing

```bash
scripts/test/all.sh                       # everything below, in order
scripts/build-qemu.sh                     # engine
python3 scripts/test/display-backend.py   # boots EDK2 only and drives the display protocol
(cd AlcoveKit && swift test)              # 171 tests; VM tests boot the real engine
(cd guest-tools && go test ./...)         # guest agent
(cd mcp && npm run build && npm test)     # MCP server helpers
python3 scripts/test/mcp-smoke.py --list-only
```

With a Windows guest available, `scripts/test/agent-windows.py` and
`scripts/test/mcp-smoke.py --vm "Windows 11"` exercise the whole chain against
a real desktop: clipboard round trip, file push with a checksum, typing into
Notepad and reading it back.

The shell, process and file operations have their own run against a running
Windows guest:

```bash
python3 scripts/test/install-agent.py       # copies the built agent in, installs it with --allow-exec, checks hello
python3 scripts/test/agent-rpc-windows.py   # agent operations on the forwarded agent port
python3 scripts/test/at1-e2e.py             # control socket -> agent -> guest, and MCP server -> control socket
python3 scripts/test/at5-e2e.py             # recordings, event log, crash dumps and diagnostics bundles in the guest
python3 scripts/test/at6-e2e.py             # a recording saved as a script and replayed with alcovectl run-script and alcove_script_run
python3 scripts/test/at7-e2e.py             # HTTP capture: CA and system proxy in the guest, rules, a stream, restore, MCP tools
```

`scripts/test/alcove_ctl.py` is the control-socket client these scripts import;
`scripts/test/ctl.py OP key=value ...` is its command line.

## Status

Working today: Windows 11 ARM and Linux guests, snapshots, suspend, USB
passthrough, guest tools, and the full automation surface. TPM is off by
default because `tpm-tis-device` fails under HVF on Apple silicon; Windows 11
installs without it.

Next: Coherence-style windows, GPU acceleration for the guest, and a signed,
notarised release. Plans live in [`docs/superpowers/plans/`](docs/superpowers/plans).

## Licence

The app and everything around it are MIT ([`LICENSE`](LICENSE)). The QEMU patch
series is GPL, because QEMU is — see [`NOTICE.md`](NOTICE.md) for the split and
[`qemu-patches/LICENSE`](qemu-patches/LICENSE) for the terms. Alcove runs QEMU
as a separate process and never links it.

Windows is licensed by Microsoft; bring your own. Contributions are welcome —
start with [`CONTRIBUTING.md`](CONTRIBUTING.md).
