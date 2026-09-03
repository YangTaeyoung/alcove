# Alcove design

Date: 2026-09-03. Status: approved direction, living document.

## Goal

A native macOS app for Apple silicon that runs Windows 11 ARM and Linux
guests with the polish of Parallels Desktop, built by us on top of QEMU as the
CPU/device engine. Everything above the engine is ours: the app, the display
path, guest tools, integration features, snapshots, USB, later Coherence-style
window integration and GPU acceleration.

Decisions taken with the user on 2026-09-03:

| Decision | Choice |
|---|---|
| Engine | QEMU (`-accel hvf`), pinned tag, out-of-tree patch series |
| What is "ours" | everything except CPU/device emulation |
| Guests for v1 | Windows 11 ARM64 and Linux (arm64). macOS guests are out of scope |
| v1 feature set | integration basics, Coherence, GPU 3D, snapshots/pause/USB, in that build order |
| Distribution | open source on GitHub, Developer ID signed and notarized |
| Cadence | evenings and weekends; every sub-project ends in something usable |
| Display architecture | C: QEMU fork with our own display backend, frames shared over memory, control over a unix socket |

## Non-goals for v1

- macOS guests (needs Apple Virtualization.framework backend)
- x86 emulation (TCG). Apple silicon runs ARM guests only
- Nested virtualization (WSL2, Hyper-V) — depends on QEMU HVF EL2 support, tracked separately

## Architecture

```
┌───────────────────────────────────────────────┐
│ Alcove.app  (Swift, AppKit + SwiftUI, Metal)  │
│  VM library · settings · display view · input │
│  QMP client · snapshots · USB · guest-tools   │
│  host side                                    │
└──────┬───────────────────────┬────────────────┘
       │ QMP (unix socket)     │ display protocol (unix socket + shared memory)
┌──────┴───────────────────────┴────────────────┐
│ qemu-system-aarch64 (our build of v11.1.1)    │
│  ui/alcove.m  ← our display backend           │
│  -accel hvf · virt machine · edk2 UEFI · TPM  │
└──────┬────────────────────────────────────────┘
       │ Hypervisor.framework
┌──────┴────────────────────────────────────────┐
│ macOS                                         │
└───────────────────────────────────────────────┘
```

Process model: one QEMU process per running VM, spawned by the app with
`posix_spawn`. The app never links QEMU. This keeps QEMU's GPL-2.0-only
license on the engine side and lets the app crash-isolate VMs.

### Display path (SP1)

QEMU gets a new display type, `alcove`, implemented in `ui/alcove.m` and
registered through QEMU's `QemuDisplay` interface. It is a normal
`DisplayChangeListener`:

- On `dpy_gfx_switch` it allocates a page-aligned shared memory region
  (`shm_open` + `ftruncate`, or a file in the VM bundle) big enough for the
  new surface, and tells the app `{"t":"switch", "w","h","stride","format","shm","offset"}`.
- The guest framebuffer is copied into the region on `dpy_gfx_update`
  (dirty rectangles), then `{"t":"update","x","y","w","h"}` is sent. Zero-copy
  (allocating the DisplaySurface inside the region) is an optimization for
  later.
- Cursor: `dpy_cursor_define` copies the cursor ARGB into a second region,
  `dpy_mouse_set` sends position and visibility.
- Input from the app: `{"t":"key","mac":<macOS keycode>,"down":bool}` (QEMU maps
  it with its built-in `qemu_input_map_osx_to_linux` table; `q` QKeyCode also accepted),
  `{"t":"abs","x","y"}` in 0..32767, `{"t":"rel","dx","dy"}`, `{"t":"btn","b","down"}`,
  `{"t":"scroll","dy"}`, `{"t":"ui","w","h"}` (resolution request via
  `dpy_set_ui_info`).
- Transport: one unix stream socket, newline-delimited JSON, created by the
  app and passed as `-display alcove,socket=<path>`. The backend registers the
  fd with QEMU's main loop (`qemu_set_fd_handler`) so every callback runs on the
  main loop thread under the BQL. No extra threads inside QEMU.

The app draws the shared region with Metal: the region is wrapped in an
`MTLBuffer` (`makeBuffer(bytesNoCopy:)`, page-aligned), blitted into a
`bgra8Unorm` texture on each update, presented by an `MTKView` at display
refresh. Frames are coalesced per vsync.

### Control path

QMP over a unix socket (`-qmp unix:<path>,server=on,wait=off`). The Swift QMP
client is a small actor: greeting, `qmp_capabilities`, request/response by id,
event stream. Used for: pause/resume (`stop`/`cont`), ACPI shutdown, reset,
snapshots (`snapshot-save/load/delete` jobs on qcow2), suspend to disk
(`migrate` to file + `-incoming`), media change, USB `device_add usb-host`,
`screendump`, `query-status`, and events (`SHUTDOWN`, `STOP`, `RESUME`,
`JOB_STATUS_CHANGE`, `DEVICE_DELETED`).

### VM bundle

`<name>.alcovevm/` directory:

```
config.json      # AlcoveKit.VMConfig (versioned)
disk0.qcow2      # system disk (qcow2, node name "disk0")
efi-vars.fd      # UEFI variable store (copy of edk2-arm-vars.fd, else zero-filled 64 MiB)
tpm/             # swtpm state (only when TPM is enabled; see SP0 results)
run/             # scratch: shared framebuffer files, qemu.log, serial.log (cleared on start)
suspend.state    # present while suspended to disk (QEMU migration stream)
```

Sockets (`display.sock`, `qmp.sock`, `swtpm.sock`) are NOT in the bundle: unix
socket paths are limited to 104 bytes on macOS, so they live in
`/tmp/alcove-<uid>/<hash of bundle path>/`.

### Guest tools (SP2)

One Go binary per guest OS (`guest-tools/`), cross-compiled from macOS
(`GOOS=linux GOARCH=arm64`, `GOOS=windows GOARCH=arm64`). Transport is a
host-side listener reachable from the guest through the user-mode network
(`10.0.2.2:<port>` over slirp), chosen because it needs no guest drivers on
either OS. vsock is not available on macOS hosts (confirmed: vhost-vsock is
Linux-only), and the Windows guest already reaches `10.0.2.2` through NetKVM. Features: clipboard both ways, resolution follow, host
folder sharing (Linux: virtio-9p; Windows: WebDAV server in the app mapped
by the inbox WebDAV client), drag and drop (file push), time sync, graceful
shutdown hook.

### Automation and MCP (added 2026-09-03 on the user's request)

Coding agents on the Mac (Claude Code first) must be able to use the guests:
screenshots, mouse, keyboard, and a shell (PowerShell / sh). Design:

- `AlcoveControl` (AlcoveKit): a unix-socket JSON API
  (`docs/control-protocol.md`) implemented once and hosted by whoever owns the
  VMs: the app while it runs, or `alcovectl serve` headless. Screenshots come
  from QMP `screendump`; mouse/keyboard go through the display protocol
  (`abs`/`btn`/`key` with macOS keycodes, `KeyNames` maps names and US-layout
  characters); shell, clipboard and file push go through the guest agent.
- `mcp/` (TypeScript, `@modelcontextprotocol/sdk`): `alcove-mcp-server`, stdio,
  16 tools prefixed `alcove_`, screenshots returned as image content, auto
  starts the headless server when the app is not running.
- Guest agent auth: SMBIOS type 11 string `alcove-token=<uuid>` from the VM
  config; the agent must echo it in `hello`.
- Verified end to end on the Windows 11 image: list/start/screenshot/status/
  exec/win+r/type through an MCP client (`scripts/test/mcp-smoke.py`).

### Coherence (SP3)

Guest tool reports top-level window rects and z-order; the app shows each as
its own `NSWindow` whose content is a cropped view of the same shared
framebuffer, and asks the guest to hide desktop chrome. Input is routed by
window. Design to be written when SP3 starts.

### GPU 3D (SP4)

A paravirtual GPU device in the QEMU fork plus a Windows WDDM driver and a
host-side DirectX-to-Metal translation. This is the largest and riskiest piece
and is designed separately when SP4 starts. Linux gets virgl + ANGLE first.

## Sub-projects

| ID | Scope | Done when |
|---|---|---|
| SP0 | Spike: build engine, boot both guests headless | `scripts/build-qemu.sh` produces a signed binary; Ubuntu boots to login on serial; Windows 11 ARM installer boots |
| SP1 | Core app | Create/boot/see/type/click, pause/resume, snapshots, USB passthrough, settings; automated tests for QMP, protocol, key mapping, and a headless framebuffer test against the EDK2 boot menu |
| SP2 | Guest tools + integration basics | clipboard, resolution follow, shared folders, drag and drop on both guests |
| SP3 | Coherence | Windows apps as Mac windows |
| SP4 | GPU 3D | DirectX 11 apps run accelerated |
| SP5 | Distribution | Signed, notarized, GPL compliant release |

## Testing strategy

- AlcoveKit is a Swift package with unit tests (`swift test`): QMP codec and
  client against a fake server, display protocol codec, VM config
  migration, key mapping.
- Engine integration tests are shell scripts under `scripts/test/` that boot
  QEMU headless with the EDK2 firmware only (no OS needed): the boot menu is
  drawn into the shared framebuffer, so the display protocol and input path
  can be checked without any guest image.
- Guest-level tests use the Ubuntu cloud image with a NoCloud seed and a
  serial console; Windows tests are manual until SP2 has an agent.

## Open questions

- Windows 11 ARM64 ISO acquisition: Microsoft's bot check refuses the final
  download link from scripts; the app will guide the user to the download page
  (see `scripts/fetch-windows-iso.sh` and SP0 results).
- TPM: `tpm-tis-device` fails under HVF on this host; investigate a fix in QEMU
  (16 KiB page alignment of the TIS MMIO region) before offering TPM in the UI.
- Whether zero-copy DisplaySurface allocation inside shared memory is
  safe with all display devices (ramfb, virtio-gpu); v1 copies via pixman.
- Nested virtualization on HVF in QEMU 11.1.1.

See `docs/superpowers/plans/2026-09-03-sp0-results.md` for what SP0 verified.
