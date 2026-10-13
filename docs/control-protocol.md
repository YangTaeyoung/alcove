# Alcove control protocol (automation API)

Version 1. Lets automation on the Mac — the `alcove-mcp` server for Claude
Code and other agents, `alcovectl`, scripts — drive VMs: list and start them,
take screenshots, move the mouse, click, type, press keys, run shell commands
and background jobs in the guest, list and kill guest processes, exchange
clipboard text, and copy, sync, read and write guest files.

The same server runs inside the Alcove app (which owns the VMs while it is
running) and inside `alcovectl serve` (headless, when the app is not running).
Clients connect to the unix socket
`~/Library/Application Support/Alcove/control.sock`; a client that cannot
connect may start `alcovectl serve` itself.

Transport: newline-delimited JSON. Request `{"id": n, "op": "...", ...params}`;
response `{"id": n, "ok": true, ...result}` or `{"id": n, "ok": false, "error": "message"}`.
A request line is at most 8 MiB; a longer one closes the connection.
Coordinates are guest pixels at the resolution of the last screenshot /
`vm.status`.

## Lanes

Each connection has two lanes.

- **Concurrent lane**: every op whose name starts with `vm.exec`,
  `vm.process.` or `vm.fs.`, and `vm.push_file`, `vm.pull_file`,
  `vm.sync_dir`. Such a request starts as soon as it arrives and answers when
  it finishes, so several can be in flight and their replies arrive in any
  order. Match replies by `id`. Pipelined requests of this lane are unordered
  among themselves: two `vm.fs.write` requests to one file sent back to back
  may be applied in either order. A caller that needs an order sends the
  second request after the reply to the first.
- **Serial lane**: every other op (`hello`, `vm.list`, `vm.status`, power,
  screenshot, mouse, keyboard, clipboard, `vm.wait_idle`). These run one after
  another in the order they arrived, and their replies come in that order.

The lanes do not wait for each other: a screenshot or a click is answered
while a `vm.exec` of the same connection is still running. Mouse and keyboard
ops for one VM run one at a time across all connections.

Closing a connection discards the replies to its unfinished requests. A
command that `vm.exec` already started in the guest keeps running until it
ends or reaches its `timeout`; jobs started with `vm.exec.start` are not
affected. The control socket carries no events: a job's exit is seen through
`vm.exec.read` or `vm.exec.list`.

## Operations

| `op` | Params | Result |
|---|---|---|
| `hello` | — | `{version: 1, host: "app"|"headless"}` |
| `vm.list` | — | `{vms: [{name, guestOS, state, width, height, tools: bool}]}` |
| `vm.status` | `name` | `{state, width, height, tools, agentCaps: [...], suspended: bool}` |
| `vm.start` | `name` | `{state}` after the guest is running |
| `vm.stop` | `name`, `force?` | `{state}` after the engine exited (graceful ACPI first) |
| `vm.pause` / `vm.resume` | `name` | `{state}` |
| `vm.screenshot` | `name`, `format?` ("png"), `maxWidth?` | `{png: base64, width, height}` — the full guest frame via QMP screendump; `maxWidth` downsamples (aspect kept) to save tokens |
| `vm.mouse.move` | `name`, `x`, `y` | `{}` |
| `vm.mouse.click` | `name`, `x`, `y`, `button?` ("left"/"right"/"middle"), `count?` (1 or 2), `hold?` ms | `{}` — moves, presses, releases |
| `vm.mouse.drag` | `name`, `fromX`, `fromY`, `toX`, `toY`, `button?` | `{}` |
| `vm.mouse.scroll` | `name`, `x`, `y`, `dx?`, `dy?` (notches, +down) | `{}` |
| `vm.key.press` | `name`, `keys` (string like "ctrl+alt+delete", "enter", "win+r"), `hold?` ms | `{}` — presses modifiers then the key, releases in reverse |
| `vm.key.down` / `vm.key.up` | `name`, `key` | `{}` |
| `vm.type` | `name`, `text`, `delay?` ms per key | `{}` — US-layout text typing; characters outside the layout use the guest clipboard + paste when tools are connected |
| `vm.exec` | `name`, `command` or `argv`, `timeout?` s, `cwd?`, `env?`, `stdin?`, `shell?` | `{code, output, stdout, stderr, timedOut, truncated}` — runs a command through the guest agent and waits for it; `output` is `stdout` followed by `stderr` |
| `vm.exec.start` | `name`, `command` or `argv`, `cwd?`, `env?`, `shell?` | `{job, pid}` — starts a background job and returns at once |
| `vm.exec.read` | `name`, `job`, `outOffset?`, `errOffset?`, `max?` | `{state, code?, pid, out, err, outNext, errNext, dropped}` — output from the given byte offsets |
| `vm.exec.write` | `name`, `job`, `data`, `eof?` | `{}` — writes to the job's stdin; `eof` closes it |
| `vm.exec.kill` | `name`, `job` | `{state}` — kills the job's process tree |
| `vm.exec.list` | `name` | `{jobs: [{job, pid, state, code?, cmd, started}]}` |
| `vm.process.list` | `name`, `filter?` | `{processes: [{pid, ppid, name, path, command, memoryKB}]}` — `filter` is a case-insensitive substring of the process name |
| `vm.process.kill` | `name`, `pid?` or `processName?`, `tree?` | `{killed}` — `tree` also kills child processes |
| `vm.clipboard.get` / `vm.clipboard.set` | `name` / `name`, `text` | `{text}` / `{}` |
| `vm.push_file` | `name`, `path` (host), `dest?` ("desktop"/"downloads") or `guestPath?`, `overwrite?` | `{guestPath}`; with `guestPath` also `{bytes, sha256}` |
| `vm.pull_file` | `name`, `guestPath`, `path` (host) | `{path, bytes, sha256}` |
| `vm.sync_dir` | `name`, `path` (host directory), `guestPath`, `delete?` | `{sent: [..], skipped, deleted: [..], bytes}` |
| `vm.fs.list` | `name`, `path`, `recursive?` | `{entries: [{name, dir, size, mtime}], truncated}` |
| `vm.fs.read` | `name`, `path`, `offset?`, `length?` (≤ 262144), `tail?` (lines) | `{text, size, eof}` |
| `vm.fs.write` | `name`, `path`, `text`, `append?` | `{size}` |
| `vm.fs.delete` | `name`, `path`, `recursive?` | `{deleted}` |
| `vm.wait_idle` | `name`, `seconds?` (stable period), `timeout?` | `{}` — returns when the frame stops changing |

Key names: letters, digits, `enter return tab space esc escape backspace delete
insert home end pageup pagedown up down left right f1..f20 capslock
printscreen`, modifiers `ctrl control alt option shift win cmd meta super`,
punctuation by character (`-` `=` `[` `]` `;` `'` `,` `.` `/` `` ` `` `\`).
Combos use `+`. Names are case-insensitive.

## Shell, processes and files

These ops need the guest tools started with `--allow-exec`
(`vm.status` → `agentCaps` contains `rpc`, `jobs`, `proc`, `fs`). They map onto
the agent operations of [`agent-protocol.md`](agent-protocol.md), which has
the exact rules; an error of the agent is passed on unchanged, so it can name
an agent operation such as `exec.list` (here `vm.exec.list`).

**Commands** (`vm.exec`, `vm.exec.start`)

- `command` runs through `shell`: `powershell` (the default on Windows),
  `cmd`, or `sh` (the default elsewhere). `argv` (a non-empty array of
  strings) starts a program directly. One of the two is required.
- `timeout` is a whole number of seconds from 1 to 86400; the default is 120.
  Any other value answers `timeout must be between 1 and 86400 seconds`. When
  the time is up the guest process tree is killed and the reply has
  `timedOut: true` and `code: -1`.
- `cwd` is the working directory, `env` an object of extra environment
  variables, `stdin` text the command reads from its standard input. Without
  `stdin` the command reads end-of-file.
- `stdout` and `stderr` hold the last 200000 bytes of each stream as UTF-8;
  `truncated` says that earlier output was dropped.
- With guest tools older than the request/response layer, `vm.exec` accepts
  `name`, `command` and `timeout` only and answers `{code, output}`; every
  other op of this section answers
  `guest tools in '<vm>' are too old for <op>; update alcove-agent in the guest`.

**Jobs** (`vm.exec.start`, `.read`, `.write`, `.kill`, `.list`)

- A job has no time limit and lives in the guest agent: it keeps running
  when the connection that started it closes, and any connection can read it.
- `vm.exec.read` returns up to `max` bytes per stream (default and cap 262144)
  starting at `outOffset` / `errOffset` and the offsets to pass next. Start
  with 0. `state` is `running` or `exited`; `code` is present once exited;
  `dropped` is true when the offsets pointed below the retained last 1 MiB.
- The agent keeps 64 jobs and forgets the oldest exited one first.

**Processes**

- `vm.process.kill` takes `pid` or the exact `processName` (on Windows the
  image name, e.g. `notepad.exe`); with both, `pid` is used.

**File transfer**

- `vm.push_file` with `guestPath` writes the host file to that exact guest
  path, creating missing folders, through `<guestPath>.alcove-part`, and
  compares SHA-256 digests before it renames. An existing file is refused
  (`'<path>' exists in the guest; pass overwrite`) unless `overwrite` is true.
  Without `guestPath` the file goes to the Desktop or Downloads folder under a
  name that does not clash, and the reply has only `guestPath`.
- `vm.pull_file` copies a guest file to the host `path` through
  `<path>.alcove-part` with the same digest check and replaces an existing
  file. The host folder must exist.
- `vm.sync_dir` uploads every regular file under the host directory whose
  size or SHA-256 differs from the guest copy. `sent` and `deleted` are
  relative paths with `/`; file names are sent in Unicode NFC; symbolic links
  are skipped; empty directories are not created. With `delete: true`, guest
  files without a host counterpart are deleted (directories stay). A guest
  directory with more than 5000 entries is refused.

**Guest files as text**

- `vm.fs.read` returns up to `length` bytes (default and cap 262144) from
  `offset` as text; `eof` says that the range reached the end of the file.
  With `tail`, it returns the last lines instead (taken from at most the last
  262144 bytes; `offset` and `length` are not used) and `eof` is true. `size`
  is the file size in bytes.
- Text is decoded as UTF-16LE when the file begins with the bytes `FF FE`
  (what Windows PowerShell writes with `>` and `Out-File`), otherwise as
  UTF-8; a byte order mark at the start is left out and invalid sequences
  become U+FFFD. A range is cut by bytes, so a character that straddles two
  ranges reads as U+FFFD in both; use even offsets in a UTF-16 file.
- `vm.fs.write` writes `text` as UTF-8 without a byte order mark, creates
  missing folders and replaces the file unless `append` is true.
- `vm.fs.list` reports `mtime` as RFC 3339 in UTC and `name` relative to
  `path` with `/` separators; `truncated` is true beyond 5000 entries.
- Paths: `~`, `~/x` and relative paths resolve against the home directory of
  the guest user the agent runs as.

## Errors

Errors are plain strings that say what to do next:

```
VM 'Win' is stopped; call vm.start first
guest tools are not connected in 'Win'; install alcove-agent in the guest
missing parameter; pass 'command' or 'argv'
missing or invalid parameter 'env'
parameter 'append' must be a boolean
parameter 'offset' must be an integer
timeout must be between 1 and 86400 seconds
no job 'j9'; call exec.list
'C:\out\app.exe' exists in the guest; pass overwrite
guest tools in 'Win' did not answer vm.fs.read in time; check vm.status and retry
```
