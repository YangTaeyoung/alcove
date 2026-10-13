# Notice — licences in this repository

Alcove is two things in one tree: an app written from scratch, and a patch to
QEMU. They are not under the same licence.

| Path | Licence | File |
|---|---|---|
| `AlcoveKit/`, `Alcove/`, `guest-tools/`, `mcp/`, `scripts/`, `docs/`, `project.yml` | MIT | [`LICENSE`](LICENSE) |
| `qemu-patches/` | GPL-2.0-or-later as written; GPL-2.0-only as applied | [`qemu-patches/LICENSE`](qemu-patches/LICENSE) |

Everything outside `qemu-patches/` is original work by the repository owner.
`build/` and `images/` are git-ignored (see `.gitignore`): no QEMU binary, no
firmware, no guest OS image and no driver ISO is committed here or
redistributed by this repository.

## Why `qemu-patches/` is GPL

`qemu-patches/0001-ui-add-alcove-display-backend.patch` adds `ui/alcove.c`
(844 lines) and modifies five existing QEMU files — `meson.build`,
`meson_options.txt`, `qapi/ui.json`, `qemu-options.hx`, `ui/meson.build`.
`qemu-patches/0002-hw-nvme-reset-the-controller-before-loading-its-state.patch`
modifies `hw/nvme/ctrl.c`.
`qemu-patches/0003-accel-hvf-log-dirty-pages-of-writable-ram-only.patch`
modifies `accel/hvf/hvf-all.c`. `scripts/build-qemu.sh` applies all three to
QEMU `v11.1.1` (`QEMU_TAG`).

`ui/alcove.c` declares `SPDX-License-Identifier: GPL-2.0-or-later` in its own
header (patch line 136). None of the five files modified by patch 0001 carries
a per-file licence header; `hw/nvme/ctrl.c` (patch 0002) carries its own, which
reads "This code is licensed under the GNU GPL v2 or later.", and so does
`accel/hvf/hvf-all.c` (patch 0003): "This work is licensed under the terms of
the GNU GPL, version 2. [...] Contributions after 2012-01-13 are licensed under
the terms of the GNU GPL, version 2 or (at your option) any later version."
For the files
without a header, QEMU's `LICENSE` clause 2 says source files with no
licensing information are GPL "version 2 or (at your option) any later
version" — so the whole series is GPL-2.0-or-later.

Clause 1 of the same file says "The QEMU emulator as a whole is released under
the GNU General Public License, version 2", and QEMU's `COPYING` is the GNU
GPL version 2, June 1991. Applied, the patch becomes part of that whole: the
`qemu-system-aarch64` you build from the patched tree is a GPL-2.0-only work.
Distributing that binary carries the GPL's obligations, including offering the
corresponding source — the pinned upstream tag plus `qemu-patches/`.

## The app runs QEMU, it does not link it

No QEMU source or header is compiled into AlcoveKit or Alcove.app. QEMU is
launched as a separate process and talked to over sockets:

- `AlcoveKit/Sources/AlcoveEngine/QEMUProcess.swift:8` — `ChildProcess` wraps a
  `Foundation.Process`, constructed from an executable path and an argument
  list (line 14).
- `AlcoveKit/Sources/AlcoveEngine/VMController.swift:146` —
  `ChildProcess(executable: engine.qemuSystem, arguments: args, …)` then
  `q.start()`, i.e. `fork`/`exec` of the QEMU binary.
- `AlcoveKit/Sources/AlcoveEngine/EngineLocator.swift:76` — `engine.qemuSystem`
  is `<root>/qemu-system-aarch64`, a binary found on disk, never built in.
- The two processes exchange a framebuffer over file-backed shared memory and
  newline-delimited JSON on a unix socket (`docs/display-protocol.md`), plus
  QMP on a second unix socket.

One caveat, stated plainly: `EngineLocator.swift:40` also searches the app
bundle's `Resources/qemu`. This repository's `project.yml` puts no QEMU there
(the bundle's `Resources/` holds only the asset catalogue), but if you ship an
app bundle with a QEMU build inside it, you are distributing a GPL binary and
owe its corresponding source. This is a description of the code, not legal
advice.

`swtpm` (optional, `VMController.swift:129`) is likewise an external binary
found at `/opt/homebrew/bin/swtpm` or next to the engine, spawned as a child
process. It is not bundled here and its licence is **not verified** in this
repository.

## Windows is your responsibility

Alcove ships no Windows media, no product key and no licence. You supply your
own copy and your own licence, and Microsoft's terms govern how you may use it
in a VM. `scripts/fetch-windows-iso.sh` only resolves Microsoft's own download
SKU and prints it — the signed link must still be fetched from Microsoft in a
browser; the ISO lands in the git-ignored `images/`.

## virtio-win guest drivers

`scripts/windows/setup.ps1:16` installs the guest drivers with
`pnputil /add-driver` from the attached virtio-win CD (`NetKVM`, `viostor`,
`vioscsi`, `vioserial`, `viogpudo`, `vioinput`, `Balloon`, `viorng`, `viofs`,
`pvpanic`, `viosock`, `viomem`, from each driver's `w11\ARM64` directory).
The ISO comes from the virtio-win project
(<https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/>) and is
downloaded by the user into `images/`; this repository does not redistribute
it.

Licence: the ISO carries `virtio-win_license.txt` at its root, a 3-clause BSD
licence with copyrights held by Red Hat (2009–2022), Google (2016), Virtuozzo
(2016) and IBM (2007). Verified by reading that file out of the local
`images/virtio-win.iso`. Whether every file on the ISO is covered by that one
text is **not verified** here — consult the virtio-win project.

## Third-party code used by this repository's own targets

- **AlcoveKit** — no external package dependencies; `AlcoveKit/Package.swift`
  declares none, and the targets depend only on each other and on Apple's SDK.
- **guest-tools** — Go standard library only. `guest-tools/go.mod` declares no
  requirements and there is no `go.sum`.
- **mcp/** — `@modelcontextprotocol/sdk` 1.30.0 (MIT, © 2024 Anthropic, PBC)
  and `zod` 3.25.76 (MIT, © 2025 Colin McDonnell), verified from their
  `package.json` and `LICENSE` files in `mcp/node_modules/`. Their transitive
  dependencies are installed by npm, are git-ignored, and are **not audited**
  here. `mcp/package.json` itself declares `"license": "MIT"`.
