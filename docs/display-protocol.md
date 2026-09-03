# Alcove display protocol (QEMU `-display alcove`)

Version 1. Transport: one unix stream socket per VM, created by the app
(listening) and passed to QEMU as `-display alcove,socket=<path>`. QEMU connects
once at display init. Both directions carry newline-delimited JSON objects
(UTF-8, one object per line, no embedded newlines). Pixel data never crosses
the socket: it lives in shared memory files that QEMU creates and the app maps.

The backend runs entirely on QEMU's main loop thread (fd handler), so every
callback below executes under the Big QEMU Lock. There are no threads in the
backend.

## QEMU → app

| `t` | Fields | Meaning |
|---|---|---|
| `hello` | `v` (int, protocol version = 1), `consoles` (int), `abs` (bool: the guest pointer device is absolute) | Sent once after connect. |
| `switch` | `con` (int), `w`, `h`, `stride` (bytes), `fmt` ("bgra8" only in v1), `shm` (absolute path), `size` (bytes) | A new guest surface. The app must `mmap` `shm` read-only; previous mapping for this console is stale. Region is page-aligned; pixel (x,y) is at `y*stride + x*4`, byte order B,G,R,A (little-endian `0xAARRGGBB`). |
| `update` | `con`, `x`, `y`, `w`, `h` | Rectangle changed in shared memory. Coalesce freely. |
| `cursor` | `con`, `w`, `h`, `hx`, `hy`, `shm`, `size` | New cursor image (ARGB32 premultiplied? no: straight alpha, QEMU `QEMUCursor` format), hot spot `hx,hy`. |
| `mouse` | `con`, `x`, `y`, `on` (bool) | Guest-driven cursor position and visibility (absolute pointer). |
| `bye` | — | Backend is shutting down. |

QEMU reuses a shared-memory file across `switch` events when the new surface
fits; the app must always honor the `shm` and `size` fields rather than assume.

## App → QEMU

| `t` | Fields | Meaning |
|---|---|---|
| `key` | `mac` (int, macOS virtual keycode, the `kVK_*` value from `NSEvent.keyCode`) or `q` (int, QKeyCode ordinal from qapi `QKeyCode`), `down` (bool) | Key press/release. QEMU maps `mac` through its built-in `qemu_input_map_osx_to_linux` table, so the app sends raw macOS keycodes and needs no table of its own. `q` is honored when `mac` is absent. Unknown codes are dropped. |
| `abs` | `con`, `x`, `y` | Absolute pointer in 0..32767 on both axes, scaled to the surface size by QEMU. Used when the guest has an absolute device (usb-tablet). |
| `rel` | `con`, `dx`, `dy` | Relative motion in pixels. |
| `btn` | `con`, `b` (int: 0 left, 1 middle, 2 right, 3 wheel-up, 4 wheel-down, 5 side, 6 extra, 7 wheel-left, 8 wheel-right — the qapi `InputButton` ordinals), `down` (bool) | Button. Wheel is expressed as a press+release pair per notch. |
| `sync` | — | Flush queued pointer events (QEMU `qemu_input_event_sync`). The app sends one after each batch of `abs`/`rel`/`btn`. |
| `ui` | `con`, `w`, `h` | Request the guest to switch resolution (`dpy_set_ui_info`). Honored by virtio-gpu guests with a driver; ignored otherwise. |
| `refresh` | `con` | Ask QEMU to re-send an `update` for the whole surface (after the app re-maps). |
| `lift` | — | Release every key QEMU believes is held (send when the display view loses focus). |

## Errors and lifecycle

- Unknown `t` values are ignored by both sides (forward compatibility).
- If the socket closes, QEMU keeps running headless; the app may reconnect
  only by restarting the VM (v1). The app treats EOF as "display lost".
- Shared-memory files live in `shmdir` (default: the socket's directory,
  i.e. the VM bundle's `run/` directory) and are unlinked by QEMU when
  superseded and on exit; the app removes stragglers on VM start.
- When the socket is backpressured (256 KiB queued) QEMU coalesces `update`
  messages into one bounding rectangle until the socket drains.
- QEMU option: `-display alcove,socket=<path>[,shmdir=<dir>]` (the socket
  option is required; QEMU exits if it cannot connect).
