# Linux guest results: guest tools and the AI testing tools on Ubuntu (2026-10-15)

The runs below were executed on an Apple M5 Pro (18 cores, 64 GiB RAM, macOS
27.0.1, Swift 6.4, Go 1.25.0, Node 26.10, Python 3, QEMU 11.1.1 with
`qemu-patches/0001` to `0003`, engine in `build/qemu-build`, not rebuilt)
against a new VM `Ubuntu` through `alcovectl serve` (debug build of this tree
in `AlcoveKit/.build-ctl`), with `build/alcove-agent-linux-arm64` and
`build/alcove-proxy` built from this tree. Base: 7339e86 (0.2.0 plus two test
commits). The commits 25c508c..6b9333f landed on the branch during the run;
they touch the proxy, its tests and docs, and were not in the binaries tested.
The data volume had 334 GiB free.

## Setup

| Item | Value |
|---|---|
| Image | `ubuntu-26.04.1-live-server-arm64.iso` from `cdimage.ubuntu.com/ubuntu/releases/26.04.1/release/`, SHA-256 `af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168`, equal to its line in `SHA256SUMS`, whose signature `SHA256SUMS.gpg` is good by the Ubuntu CD Image Automatic Signing Key (2012) |
| Why server plus desktop | The server installer takes autoinstall without a person; the desktop matters for the clipboard, `vm.type` beyond the US layout, `vm.app.launch` and screen text. The autoinstall installed `ubuntu-desktop-minimal` (GNOME 50 on Wayland, GDM autologin of `alcove`), `wl-clipboard`, `xclip`, `binutils`, `iproute2`, `curl` |
| VM | `alcovectl create --name Ubuntu --os linux --iso <iso> --disk-gib 40 --cpus 4 --memory-mib 6144 --forward 2223:22 --forward 7647:7645` (virtio-blk, virtio-gpu 1280x800, agent host port 17441) |
| Install | a NoCloud seed (`cidata`, `#cloud-config` with `autoinstall:`) added to `config.json` as CD `seed` with `bus: virtio` (no `create` flag exists for a second CD); `vm.start`, `vm.wait_for` `text_visible` "Install Ubuntu" on the GRUB menu, `vm.key.press` `e`, three `down`, `end`, `vm.type` ` autoinstall`, `ctrl+x`; the installer powered the VM off after 15 min. Both CDs were then removed from `config.json` |
| Guest | Ubuntu 26.04.1 LTS, kernel 7.0.0-38-generic aarch64, uutils coreutils 0.8.0, Python 3.14; user `alcove` with passwordless sudo; ssh key `~/Library/Application Support/Alcove/ubuntu_id_ed25519` and the harness key; screen blanking and lock off (`gsettings`) |
| Agent install | as `agent-linux.py` does it: `scp` to `/tmp`, `sudo alcove-agent --install --allow-exec` → `/usr/local/bin/alcove-agent` and the system unit `alcove-agent.service` (`ExecStart=/usr/local/bin/alcove-agent --port 7645 --allow-exec`) |

The VM is kept, stopped, for later runs. Ad-hoc drivers for the checks below
lived outside the repository (control socket through `scripts/test/alcove_ctl.py`,
MCP through `scripts/test/mcp_stdio.py`).

## Scripts and which guests they serve

| Script | Linux guest |
|---|---|
| `agent-linux.py` | yes; it hard-coded the VM name `Ubuntu 24.04` and now takes `--vm` (9ef8f14) |
| `install-agent.py`, `agent-rpc-windows.py`, `uia-helper-check.py` | Windows only (PowerShell, `C:\` paths, scheduled task) |
| `at1-e2e.py` … `at7-e2e.py` | Windows only (`C:\alcove-e2e`, PowerShell, Notepad, Edge, the Windows fixture, WinINET) |
| `mcp-smoke.py --vm` | Windows only after the exec step (`win+r`, Notepad); the MCP tools were driven by hand instead |

The control ops of those scripts that have a Linux meaning were run by hand.

## Results

| Check | Result | Evidence |
|---|---|---|
| `agent-linux.py --vm Ubuntu` | PASS | `install: 0 installed / active / 1` (one `alcove-token` string in the DMI table); `hello: {'os': 'linux', 'agent': '0.2.0', 'caps': ['files', 'shutdown', 'resolution', 'exec', 'rpc', 'jobs', 'proc', 'fs'], 'token': '2a043e94-…'}`; `exec: 0 root \| aarch64`; `file push OK -> Downloads/drop.bin` (see D1 for where that is) |
| SMBIOS host key (L1) | PASS | DMI holds `alcove-token=2a043e94-…` and `alcove-hostkey=ff990ddd…`; `alcovectl agent-sign --vm Ubuntu --public-key` prints `ff990ddd…ca92`; the agent's start line: `alcove-agent 0.2.0 listening on [::]:7645 for 10.0.2.2/32 (token 2a04...6760, host key ff99...ca92, exec true)` |
| Hello and auth | PASS | hello `{"auth":"key","nonce":<64 hex>,"os":"linux","proto":2,…}`; an all-zero signature → `refused` with the signature-mismatch sentence; the right one → `authed` |
| Guest-local peers | PASS | as user `alcove` in the guest: `127.0.0.1:7645` → `refused` (`alcove-agent serves only connections from 10.0.2.2/32 …`); `10.0.2.2:17441` → hello, then `req exec.run` → `this alcove-agent serves only a host that proves the VM's key; …` |
| Install log (L2) | PASS (part) | `/var/log/alcove` is `drwx------ root root` with `install.log` (`… installed`); the no-follow refusal was not tried |
| Reinstall over a running agent | FAIL | D3 |
| Clipboard (`vm.clipboard.*`, `vm.type` beyond US) | FAIL | D2; the agent has no clipboard under the documented install (D1) |
| `vm.exec` (sh, `cwd`, `env`, `stdin`, `argv`, timeout, exit code) | PASS | `id -un; pwd` → `root`, `/` (D1); `cwd: /etc` with stdin `표준 입력` round trip; `argv` `/usr/bin/uname -m` → `aarch64`; `argv` with `shell: sh` and `shell: powershell` refused with the documented sentences; `sleep 30` with `timeout: 2` → `code -1`, `timedOut: true`; `exit 7` with stderr → `code 7` |
| Relative `cwd` | FAIL | D1: `cwd: "etc"` runs in `/etc`; `cwd: "sub"` → `cannot start the command: fork/exec /bin/sh: no such file or directory; check cmd, argv, cwd and shell` |
| Jobs (L3) | PASS | `vm.exec.start` of a loop → `exec.read` `line1..3` while `running`; `exec.write` `hello` with `eof` → `got:hello`, `exited` code 0; `exec.list` both jobs; `exec.kill` of `sleep 600 & sleep 601; wait` → no `sleep 60x` left |
| `vm.process.list` / `.kill` (L3) | PASS with a finding | 222 processes; `sleep` row `{name: sleep, path: /usr/bin/sleep, ppid: 1204}`; kill by `processName: sleep` → `killed: 1`; a missing pid → `cannot kill pid 999999: os: process already finished; call proc.list to check it`. Finding D9 (names from rewritten argv) |
| File transfer | PASS (except D1) | `push_file` 3 MiB + 17 B to `guestPath` (digest equal), refusal without `overwrite`, overwrite; `pull_file` digest equal; relative host path and missing guest file refused with the documented sentences; `sync_dir` sent 3 (one NFC Korean name), then 3 skipped, then `delete: true` deleted `sub/b.txt` and sent the changed file |
| `push_file` with `dest` | FAIL | D1: `guestPath: "Desktop/big.bin"`, written to `/Desktop` |
| `vm.fs.*` | PASS (except D1) | write, append, read, range (`two`), `tail: 2` with Korean text; recursive list; delete refused for a non-empty folder without `recursive`; `fs.list ~` lists `/` (D1) |
| `vm.doctor` (L5) | PASS with a finding | 13 rows ok: `session: root, lock state not checked on this guest`, `disk: 28180369408 bytes free`, `clock: skew 0 s`, `network: example.com resolves`, `scale: not checked`, `proxy: no system proxy`; after a clock set 52 min ahead `clock` not ok, `skew 3144 s`, hint `vm.set_environment clock=host`. Finding D8 (session user) |
| `vm.set_environment` (L5) | PASS with a finding | `clock` (a fixed time, then `host`) and `timeZone: Asia/Seoul` applied (`date -u`, `timedatectl show`), `ok: true`, `detail: ""` (D7); `theme`, `locale`, `keyboardLayouts`, `dpiScale` → `not supported on linux guests` |
| `vm.set_resolution` | FAIL | D6: 1440x900 → `{width: 1280, height: 800}`, ok |
| Screenshots | PASS | PNG 1280x800; JPEG `quality 0.5`, `maxWidth 640` → 640x400; region with `scale 0.5`; `marks` and `window` → `UI Automation is only available on Windows guests …` (as documented) |
| `vm.find_text`, `vm.wait_idle` | PASS | the GNOME welcome screen read line by line (`Welcome to Ubuntu 26.04.1 LTS!`, `Next`, the clock); `query`, `regex`, `languages: [ko-KR]`; `wait_idle` → `idle: true` |
| `vm.wait_for` (L8) | PASS | `screen_idle`, `text_visible`, `text_gone`, `process_started gnome-shell`, `process_exited` of a missing name, `file_exists`, `port_listening 22` and `7645`, `port_listening 9` → `matched: -1` at 3 s, `log_matches` `READY-42` after 2.1 s, `job_output_matches` after 2.1 s, `job exited` with `matched: -1` at once, `event job.exited`; `window_title` and `ui_exists` → the UI Automation sentence |
| Input on the GNOME desktop | PASS | click on `Next` with `observe: diff` (24.8 % changed, PNG), `mouse.move` with `summary` and `ui` (`uiError` the UI Automation sentence), `ctrl+alt+t` opened Ptyxis, `vm.type` of `echo typed-OK $((6*7)) > /tmp/…` → file `typed-OK 42`, scroll, drag, `mouse.down`/`up`, `key.down`/`up` |
| `vm.batch` | PASS | type, `wait_for` (regex `BATCH-\s?43`) matched in 0.2 s, `ctrl+l`; a `vm.exec` step refused `step 0: 'vm.exec' cannot run in a batch`. A plain `text_visible "BATCH-42"` did not match: text recognition reads the terminal font as `BATCH- 42` (Notes) |
| `vm.window.*`, `vm.ui.*`, `vm.events` | PASS (as documented) | window and UI ops answer the UI Automation sentence; `vm.events` lists the `job.exited` events |
| `vm.app.launch` | FAIL | D1 and D5: `gnome-text-editor` → `{pid, windowTimedOut: true}` at once, the process exits; run through `vm.exec` it prints `Gtk-WARNING **: Failed to open display` |
| `vm.deploy` (L5) | FAIL | without `guestDir` → `pass guestDir; the default C:\alcove-apps\deployapp only fits Windows guests` (as documented); with `guestDir` and `launch` of a script → D4 |
| Forwards | PASS | `forward.list` config, agent rows; `forward.add` guest 8765 → host 52246, a guest `python3 -m http.server` answered `alcove-ubuntu` through it; runtime row; removed |
| `vm.set_network` | PASS (as documented) | down → `vm.exec` answers `guest tools in 'Ubuntu' did not answer vm.exec in time; check vm.status and retry`; up → `example.com` resolves |
| Leases | PASS | under a lease another client's `fs.write` → `VM 'Ubuntu' is leased by linux-check for another 60 s; …`, its `fs.list` answered |
| Pause, resume | PASS | `paused`, `running` |
| Snapshots | PASS | create with 2.47 GB VM state; a file written after it is gone after `snapshot.restore` (`tools: true`, `clockSynced: true`, guest clock equal to the host's); delete |
| Linked clone | PASS | `vm.clone` → `Ubuntu clone` (`cloneOf: Ubuntu`); started, tools after 10 s with its own token `bbfd9d25-…`; `vm.start` of the template → `'Ubuntu' is a template with clones (Ubuntu clone); …`; clone stopped and deleted |
| `discardChanges` | PASS | `ephemeral: true`; `/root/ephemeral-marker.txt` written, gone after stop and a normal start |
| `vm.event_log` (L6) | PASS | newest first; a `logger -t alcove-linux-check -p user.err` entry found by `provider` + `level: error`, by `contains: "ENTRY 7"` (any case), with `log: System` ignored; `id` is the pid. Provider case and the message cut were not tried |
| `vm.crash_dumps.*` | PASS (as documented) | `list` → `crash dumps are only collected on Windows guests`; `enable` with `foo.exe` the same; with `foo` the image-name sentence first |
| Recording | PASS | `record.start` fps 5 → `record.status` → 5 ops, 4 frames, `video.mp4` 14.2 s, 0 dropped |
| `vm.collect_diagnostics` (L6) | PASS | during the recording, 22 files: `doctor.json`, `eventlog-system.json` (the journal), `events.json`, frames, `jobs/j1..j8.txt`, `logs/hostname`, `logs/install.log`, `processes.json`, `screenshot.png`, `summary.txt`, `trace.jsonl`, `video.mp4`; summary ends `windows, UI tree and crash dumps are collected on Windows guests only; skipped on this linux guest` / `steps that failed: none` |
| `script.save` / `script.run` / `alcovectl run-script` | PASS | 3 steps saved (the `wait_for` that did not match left out, as documented); `script.run` passed in 0.7 s; `run-script --vm Ubuntu` → `PASSED: 3 steps in 0.8 s`, exit 0 |
| HTTP capture (L4, L7) | PASS | `vm.http.start` → `caInstalled: true`, `systemProxySet: false`, `guestCAPath /usr/local/share/ca-certificates/alcove-proxy.crt`, `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` `/etc/ssl/certs/ca-certificates.crt`; the bundle went from 121 to 122 certificates with the link `alcove-proxy.pem`; doctor `capturing through 10.0.2.2:55371, system proxy not set`; `curl` HTTPS and HTTP and Python `urllib` HTTPS with `env` captured (200, 404, 404), `curl` without `env` not captured; rule 429 `slow down` once, then 404; `vm.app.launch` of `sh` got the eight proxy variables; `vm.http.stop` → `exchanges: 5`, CA file, link and `.removing` gone, bundle back to 121, doctor `no system proxy`; a second stop → `'Ubuntu' is not capturing; call vm.http.start first` (as documented) |
| MCP tools | PASS (except D2) | `alcove_list_vms`, `vm_status`, `start_vm` (`guest tools connected (desktop ready)`), `screenshot` (1 image), `find_text`, `exec` (`Linux aarch64 / root`), `fs_list`, `process_list`, `doctor`, `wait_for`, `event_log`, `set_environment` (`clock: ok —  (takes effect: now)`, theme `FAILED — not supported on linux guests`), `collect_diagnostics`, `http_capture_start`/`stop`, `press_keys`; `list_windows` and `type` of `ü` answer the documented sentences; `alcove_set_clipboard` → `clipboard set (1 characters)` while nothing was set (D2) |
| `alcovectl agent Ubuntu --command "uname -sm"` | PASS | `connected on port 17441: os=linux agent=0.2.0 …`, `exit 0`, `Linux aarch64` |
| Go tests on the guest | PASS | `GOOS=linux GOARCH=arm64 go test -c` of every package, copied with `vm.sync_dir`, run as `alcove` and as root: `cmd/alcove-agent`, `cmd/alcove-proxy`, `clipboard`, `mitm`, `proto`, `server`, `sysfolder`, `token`, `uia` all `PASS` both times |
| End state | ok | `vm.stop` → `stopped`; `captures.json` empty; SIGTERM ended `alcovectl serve`; no `alcovectl`, `qemu-system-aarch64`, `alcove-proxy` or MCP process left; the guest folders the run made (`/Desktop`, `/Downloads`, `/tmp/…`, `/opt/alcove-deploy-test`) and the host `Diagnostics` folder removed |

## Defects

| # | Op and input | Output | Cause | Suggested fix |
|---|---|---|---|---|
| D1 | The documented Linux install (`alcove-agent --install --allow-exec`), then `vm.exec` `echo HOME=$HOME; pwd`, `vm.push_file` with `dest: desktop`, `vm.fs.list path=~`, `vm.exec` with `cwd: "sub"`, `vm.app.launch` of a GUI program | `HOME=` and `/`; `guestPath: "Desktop/big.bin"` written to `/Desktop/big.bin` (owner root; `agent-linux.py` reports `Downloads/drop.bin` and passes); `fs.list ~` lists `/`; relative `cwd` taken below `/`; GUI programs start without a display | The unit `install_other.go:73-82` has no `User=`, `Environment=` or session; systemd gives a root service no `HOME`, so `os.UserHomeDir()` fails and `server.go:111-113` leaves `HomeDir` empty, which `server.go:293-295` (`file.begin`), `shell.go:123-129` (`newCommand`) and `resolveHomePath` use as is. The service also has no `WAYLAND_DISPLAY`/`DISPLAY`/`XDG_RUNTIME_DIR` | Give the service a home (`Environment=HOME=/root`) or fail the start when it is missing; resolve the desktop user (the active seat0 session from `loginctl`) for `dest` drops, and run GUI launches and the clipboard tools in that session's environment (`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR=/run/user/<uid>`, as that user). Checked by hand: `sudo env WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 wl-copy` / `wl-paste` round-trip under GNOME 50, so the tools work once the agent has the session's environment |
| D2 | `vm.clipboard.set text=hello-linux`, then `vm.clipboard.get`, on a guest whose `agentCaps` lack `clipboard` | `{ok: true}`, then `{ok: true, text: ""}`; the guest journal logs `clipboard.set: no clipboard in this session`; MCP `alcove_set_clipboard` says `clipboard set (1 characters)`. `vm.type` of `한글` refuses correctly with `the guest tools in 'Ubuntu' have no clipboard …` | `ControlHandler.swift:366-374` sends `clipboard.get`/`clipboard.set` without the capability check that `ControlHandler+Actions.swift:332` does for `vm.type`; the agent (`server.go:272-283`) answers an unavailable clipboard with empty text and drops a set silently | Refuse both ops (and the MCP tools) with the `vm.type` sentence when `clipboard` is not in the hello's caps |
| D3 | Reinstall: `sudo /tmp/alcove-agent-new --install --allow-exec` with the service running (a `-trimpath` build, other digest) | `installed`, exit 0, `install.log` gains `… installed`; `/usr/local/bin/alcove-agent` keeps the old digest (`f6869bfa…`), the service keeps pid 1146 and its start time. `cat new > /usr/local/bin/alcove-agent` → `Text file busy` | `install_other.go:64` ignores the `os.WriteFile` error (ETXTBSY on the running binary); `systemctl enable --now` (`:87`) does not restart an active unit | Write to a temporary file in `/usr/local/bin` and `rename(2)` it over the binary, report a failed copy, then `systemctl daemon-reload` and `systemctl restart alcove-agent` |
| D4 | `vm.deploy path=<host dir with run.sh, mode 755> guestDir=/opt/alcove-deploy-test launch={exe: run.sh, args: [a1]}` | `the files were copied to /opt/alcove-deploy-test, but starting /opt/alcove-deploy-test/run.sh failed: cannot start '/opt/alcove-deploy-test/run.sh': fork/exec …: permission denied; check the path with vm.fs.list`; the file is `-rw-r--r--`. `vm.sync_dir` of test binaries gave the same mode | `fs.write` creates files with 0644 (`files.go:567`) and the host sends no mode, so a deployed Linux program never has its execute bit | Carry the host file's execute bit through `vm.sync_dir`/`vm.push_file`/`vm.deploy` (a `mode` or `executable` field on `fs.write` for non-Windows guests), or `chmod +x` `launch.exe` and `install.file` on Linux guests before starting them |
| D5 | `vm.app.launch path=/usr/bin/gnome-text-editor waitWindow=3` | `{pid: 3216, windowTimedOut: true}` in 0.03 s | `ControlHandler+UI.swift:624-628` sets `windowTimedOut` whenever `waitMs > 0`, though without the `ui` capability nothing is waited for (docs: "without the `ui` capability no window is waited for") | Leave `windowTimedOut` out when the guest tools lack `ui` |
| D6 | `vm.set_resolution width=1440 height=900` | `{width: 1280, height: 800}`, ok | The Linux agent advertises `resolution` (`server.go:138`) while `setResolution` always fails with `resolution change not supported on this platform` (`platform_other.go:19-21`, logged only) | Drop `resolution` from the Linux caps and have `vm.set_resolution` refuse with a sentence, or implement it (for virtio-gpu, `xrandr`/`gnome-randr` in the session, or the host's display size hint) |
| D7 | `vm.set_environment clock=host timeZone=Etc/UTC` | rows `ok: true` with `detail: ""` (MCP: `clock: ok —  (takes effect: now)`) | `GuestRecipes.swift:57` `date -u -s @<n>` prints nothing with uutils coreutils 0.8.0 (the default `date` of Ubuntu 26.04); `:66` `timedatectl set-timezone` prints nothing on any distribution. The docs say `detail` is what the script printed, "e.g. the new time or zone id" | End the recipes with `date -u +%Y-%m-%dT%H:%M:%SZ` and `timedatectl show -p Timezone --value` |
| D8 | `vm.doctor` | `session: root, lock state not checked on this guest` | The Linux probe prints `id -un` of the agent (`GuestRecipes.swift:218`), which is root, not the desktop user (`alcove`, autologin on seat0) | Report the user of the active seat0 session (`loginctl`), and its lock state (`LockedHint`) |
| D9 | `vm.process.list` (MCP `alcove_process_list filter=sshd`) | `2420 ppid 1 sshd: … sshd: /usr/sbin/sshd -D [listener] …`: `name` is `sshd:` | `sys_unix.go:57` names a process by the base of the first word of `ps args`; programs that rewrite their argv (sshd, postgres, Chromium children) get names like `sshd:`, so the exact matches of `vm.process.kill processName` and `vm.wait_for process_started` (`killByName` `:76`) miss them | Take the name from `ps comm=` (or `/proc/<pid>/comm`, cut to 15 bytes) and keep `args` for `command` |

## Notes

- Text recognition reads `BATCH-42` and `recorded-2` in the Ptyxis terminal
  font as `BATCH- 42` / `recorded- 2`, so a plain `text_visible` for them does
  not match; `regex: true` with `BATCH-\s?43` does. Seen twice. A matcher that
  ignores whitespace differences would avoid it.
- `vm.start` of a VM that boots does not wait for the guest tools (documented);
  the tools connected 4 s to 10 s after `state: running`.
- The cloud-config seed had to be added to `config.json` by hand: `alcovectl
  create` takes one `--iso` and no seed, although `VMConfig.CDROM` supports
  `bus: virtio` for exactly that.

## Not verified, and why

- The Alcove app (no person to drive it): the Linux VM window, display modes
  that follow the window, suspend to disk, USB passthrough.
- A clipboard that works: the documented install gives the agent none (D1);
  the fix was only checked by running `wl-copy`/`wl-paste` by hand.
- `vm.type` of text outside the US layout and the clipboard paste path, for
  the same reason.
- The no-follow refusal of `/var/log/alcove` (L2), provider case and the
  message cut of the journal recipe (L6), `freeBytes: null` when `df` fails
  and the JSON escaping of 6.7 (L5), a guest without `ss`, `journalctl` or
  `update-ca-certificates`.
- `--allow-peer` on Linux, the agent restart loop after a crash
  (`Restart=always`), several agent connections at the 16-handshake cap.
- Other distributions (X11 sessions with `xclip`, systems without systemd).
