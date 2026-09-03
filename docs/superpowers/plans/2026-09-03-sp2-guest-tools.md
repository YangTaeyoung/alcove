# SP2 — Guest tools and integration basics

Goal: clipboard sync, resolution follow, shared folders and file drop between
macOS and the Windows 11 / Ubuntu guests, with no dependency on SPICE.

## Transport

The guest agent listens on TCP port 7645 inside the guest; the engine adds a
user-network port forward `hostfwd=tcp:127.0.0.1:<per-VM port>-:7645` and the
app connects from the host. User-mode networking never exposes guest ports
except through explicit forwards, so the agent is reachable only from the app.
Protocol: newline-delimited JSON, same style as the display protocol, with a
`hello` handshake carrying agent version and capabilities. Authentication: a
per-VM random token written into the guest at install time (SMBIOS type 11
string `alcove-token=<uuid>` passed with `-smbios`) that the agent must echo
in `hello`; the app refuses agents without it.

Why not vsock: vhost-vsock is Linux-only, no vsock device exists on macOS
hosts (docs/research/qemu-11.1.1-virt-machine-devices.md).

## Agent

One Go module `guest-tools/` producing `alcove-agent` for `windows/arm64` and
`linux/arm64` (cross-compiled from macOS with `GOOS`/`GOARCH`). Installed as a
Windows service (`sc create`) or a systemd unit. Features, in build order:

1. **Clipboard**: text both ways. Windows: user32 clipboard via syscall in a
   session-1 helper (services cannot read the interactive clipboard: the
   service launches a per-session helper through `CreateProcessAsUser`).
   Linux: `wl-copy`/`xclip` when a session exists.
2. **Resolution follow**: for virtio-gpu guests the display backend's `ui`
   message already works with viogpudo (Windows) and virtio_gpu KMS (Linux);
   the agent only reports the current mode back. ramfb guests cannot resize.
3. **Shared folders**: Linux mounts `virtio-9p` (`-fsdev local,...` +
   `virtio-9p-pci`, already enabled in the engine build) via the agent.
   Windows has no 9p client, so the app runs a WebDAV server on the host
   loopback (forwarded like the agent port) and the agent maps it with the
   inbox WebDAV redirector (`net use`), the same approach SPICE uses.
4. **File drop**: host → guest file push over the agent connection into the
   guest's Desktop or Downloads; guest → host later.
5. **Time sync** after resume from suspend and **graceful shutdown** hook.

## Windows guest prerequisites (already true for the SP0 image)

virtio-win 0.1.302 ARM64 drivers installed (`NetKVM`, `viogpudo`,
`vioserial`, `viofs`, ...); OpenSSH Server for the test harness.

## Tests

- Agent unit tests in Go (`go test ./...`).
- Host-side `AgentClient` in AlcoveKit with a fake agent.
- End-to-end: `scripts/test/agent-windows.sh` installs the agent over SSH into
  the SP0 Windows image, restarts the VM through `alcovectl`, and checks
  clipboard round trip and a shared folder listing.
