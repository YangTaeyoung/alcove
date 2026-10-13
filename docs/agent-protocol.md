# Alcove guest agent protocol

Version 1, with request/response layer 2. The agent (`alcove-agent`, Go) runs
inside the guest and listens on TCP port 7645. The engine forwards a host
loopback port to it (`hostfwd=tcp:127.0.0.1:<port>-:7645`); the app connects
from the host. Newline-delimited JSON objects in both directions, discriminated
by `t`.

## Handshake

Agent → host on connect:

```
{"t":"hello","v":1,"proto":2,"os":"windows"|"linux","agent":"0.2.0","token":"<uuid>","caps":["files","shutdown","resolution","clipboard","exec","rpc","jobs","proc","fs"]}
```

`token` is read by the agent from the SMBIOS OEM strings (type 11) that the
engine passes with `-smbios type=11,value=alcove-token=<uuid>`. The app
compares it with the token stored in the VM's `config.json` and drops the
connection on mismatch. The host replies `{"t":"welcome","v":1}`.

`v` stays 1. `proto` is the revision of the request/response layer described
under [Requests and responses](#requests-and-responses); an agent without the
field has none, and the host then uses only the messages of the next section.

Capabilities:

| `caps` entry | Present when | Meaning |
|---|---|---|
| `files`, `shutdown`, `resolution` | always | `file.*`, `shutdown`, `resolution.set` |
| `clipboard` | the guest has a usable clipboard | `clipboard.*` |
| `exec` | started with `--allow-exec` | the v1 `exec` message |
| `rpc` | always (agents with `proto` 2) | `req` / `res` / `ev` |
| `jobs`, `proc`, `fs` | started with `--allow-exec` | `exec.*`, `proc.*`, `fs.*` operations |

## Messages

| Direction | `t` | Fields | Meaning |
|---|---|---|---|
| both | `ping` / `pong` | — | keepalive every 10 s |
| host → agent | `clipboard.set` | `text` (string) | put text on the guest clipboard |
| host → agent | `clipboard.get` | — | ask for the current text; answered with `clipboard.text` |
| agent → host | `clipboard.text` | `text` | reply to `clipboard.get`; text longer than 700000 bytes of UTF-8 is cut to that size on a character boundary |
| agent → host | `clipboard.changed` | `text` | the guest clipboard changed (text only in v1; polled via the clipboard sequence number on Windows, `wl-paste --watch`/`xclip` polling on Linux); text longer than 700000 bytes of UTF-8 is cut to that size on a character boundary |
| host → agent | `resolution.set` | `w`, `h` | ask the guest to switch its primary display mode |
| agent → host | `resolution` | `w`, `h` | current primary display mode (sent after hello and on change) |
| host → agent | `file.begin` | `id`, `name`, `size`, `dest` ("desktop"/"downloads") | start a file push |
| host → agent | `file.chunk` | `id`, `data` (base64, ≤ 256 KiB decoded) | file bytes |
| host → agent | `file.end` | `id`, `sha256` | finish; the agent verifies the digest |
| agent → host | `file.done` | `id`, `path` or `error` | result |
| host → agent | `shutdown` | — | graceful OS shutdown (`shutdown /s /t 0` or `systemctl poweroff`) |
| host → agent | `exec` | `cmd` (string) | run a command with the default shell and no time limit; answered with `exec.result` (`code` -1 and `out` "exec disabled" unless the agent was started with `--allow-exec`) |
| agent → host | `exec.result` | `code`, `out` | exit code and combined stdout and stderr of `exec`; `out` keeps the last 200000 bytes, starting on a character boundary when older bytes were dropped (there is no `truncated` field) |

Unknown `t` values are ignored. Strings are UTF-8; the guest clipboard is
converted from/to UTF-16 on Windows by the agent.

## Requests and responses

```
host → agent   {"t":"req","id":7,"op":"exec.run","cmd":"hostname"}
agent → host   {"t":"res","id":7,"ok":true,"code":0,"stdout":"alcove-win\r\n","stderr":"","timed_out":false,"truncated":false}
agent → host   {"t":"res","id":8,"ok":false,"error":"no job 'j9'; call exec.list"}
agent → host   {"t":"ev","name":"job.exited","job":"j3","code":0}
```

- A request carries its parameters next to `t`, `id` and `op`. The reply
  repeats `id` unchanged and carries the result fields next to `ok`, or
  `ok: false` and `error`, a sentence that names the next step.
- Requests on one connection run at the same time; replies arrive in the
  order the operations finish. The host matches them by `id`.
- An unknown `op` answers `unknown op '<op>'; update alcove-agent`.
- Every operation except `ping` answers
  `exec disabled; start alcove-agent with --allow-exec` unless the agent was
  started with `--allow-exec`.
- `ev` messages are not replies. They go to every open connection.

### Operations

| `op` | Params | Result |
|---|---|---|
| `ping` | — | `pong` (true) |
| `exec.run` | `cmd` (string) or `argv` ([string]); `shell` (`powershell`, `cmd`, `sh`, `none`); `cwd`; `env` (object of strings); `stdin` (string); `timeout_ms` (default 120000) | `code`, `stdout`, `stderr`, `timed_out`, `truncated` |
| `exec.start` | `cmd` or `argv`, `shell`, `cwd`, `env` as for `exec.run` | `job` (string), `pid` |
| `exec.read` | `job`; `out_offset`, `err_offset` (default 0); `max` (bytes per stream, default and cap 262144) | `state` (`running`/`exited`), `code` (when exited), `pid`, `out`, `err`, `out_next`, `err_next`, `dropped` |
| `exec.write` | `job`, `data` (string), `eof` (bool) | — |
| `exec.kill` | `job` | `state` |
| `exec.list` | — | `jobs`: [{`job`, `pid`, `state`, `code` (when exited), `cmd`, `started` (RFC 3339)}] |
| `proc.list` | `name` (case-insensitive substring of the process name) | `procs`: [{`pid`, `ppid`, `name`, `path`, `cmd`, `mem_kb`}] |
| `proc.kill` | `pid`, or `name` (exact process name); `tree` (bool) | `killed` (int) |
| `fs.stat` | `path`; `sha256` (bool) | `exists`, `path` (absolute); for an existing entry also `dir`, `size`, `mtime` (RFC 3339, UTC), and `sha256` when asked for a file |
| `fs.list` | `path`; `recursive` (bool); `sha256` (bool) | `entries`: [{`name` (relative, `/` separators), `dir`, `size`, `mtime`, `sha256`}], `truncated` (more than 5000 entries) |
| `fs.read` | `path`, `offset` (default 0), `length` (default and cap 262144) | `data` (base64), `size` (of the file), `eof`, `encoding` |
| `fs.tail` | `path`, `lines` (default 200) | `data` (base64 of the last lines, taken from at most the last 262144 bytes), `size`, `encoding` |
| `fs.write` | `path`, `data` (base64), `offset` (default 0), `truncate` (bool), `append` (bool), `mkdirs` (bool) | `size` (of the file afterwards) |
| `fs.rename` | `from`, `to`, `overwrite` (bool) | `path` |
| `fs.mkdir` | `path` | `path` |
| `fs.delete` | `path`, `recursive` (bool) | `deleted` (bool) |

### Commands (`exec.run`, `exec.start`)

- With `argv` the program `argv[0]` starts directly with the remaining
  elements as arguments, and `shell` is not consulted. `shell: "none"` without
  `argv` is an error.
- With `cmd` the text runs through `shell`; the default is `powershell` on
  Windows and `sh` elsewhere:

  | `shell` | Command line |
  |---|---|
  | `powershell` (Windows only) | `powershell.exe -NoProfile -NonInteractive -Command "<prefix><cmd>"` with the prefix `[Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; ` |
  | `cmd` (Windows only) | `cmd.exe /S /C "<cmd>"`, passed to the process verbatim, so `cmd.exe` removes exactly the outer quotes and runs `<cmd>` as typed |
  | `sh` | `/bin/sh -c <cmd>` |

- `cwd` is the working directory; `~`, `~/x` and relative paths resolve
  against the home directory of the agent's user. `env` adds variables to the
  agent's environment.
- On Windows every child starts with `CREATE_NO_WINDOW`: it has no console
  window, and a GUI program started directly shows its own windows.
- `exec.run` gives the child a pipe that carries the `stdin` text and then
  ends; without the field the child reads end-of-file at once. It waits for
  the child, at most `timeout_ms`. On timeout the process tree is killed,
  `timed_out` is true and `code` is -1.
- `exec.run` keeps the last 200000 bytes of each stream; `truncated` is true
  when either stream lost earlier bytes. A character split by the cut is
  dropped, so a truncated stream starts on a character boundary. Other
  invalid UTF-8 becomes U+FFFD.
- Killing a tree (timeout, `exec.kill`, `proc.kill` with `tree`) runs
  `taskkill /F /T /PID <pid>` on Windows; elsewhere each child leads its own
  process group and the group receives SIGKILL.

### Jobs (`exec.start`, `exec.read`, `exec.write`, `exec.kill`, `exec.list`)

- A job belongs to the agent process, not to a connection: it keeps running
  when the host disconnects and any connection can read it by id (`j1`,
  `j2`, …). Restarting the agent empties the table.
- A job keeps the last 1 MiB of each stream. `out_offset` and `err_offset`
  count bytes since the job started. `exec.read` returns up to `max` bytes per
  stream from the given offsets and the offsets to pass next. A read below the
  retained window starts at the oldest retained byte and sets `dropped`. A
  piece does not end inside a UTF-8 sequence; the bytes of an unfinished
  sequence come with the next read. Only the read that reaches the end of an
  exited job's output returns the bytes as they are.
- The job's stdin stays open. `exec.write` writes `data` and, with `eof`,
  closes it; it fails for an exited job, for a closed stdin, and after 10 s
  when the job does not read.
- `exec.kill` kills the job's process tree, waits up to 5 s for the exit and
  answers the state; for an exited job it answers `exited` at once.
- The table holds 64 jobs. Starting one more forgets the oldest exited job;
  with 64 running jobs `exec.start` fails and names `exec.kill`.
- `exec.list` reports each job's `cmd` text (for `argv`, the elements joined
  by spaces) cut to 4096 characters with a trailing `…` when longer, and
  `started` in the guest's local time with its offset.
- When a job's process exits the agent sends
  `{"t":"ev","name":"job.exited","job":"<id>","code":<int>}` to every open
  connection.

### Processes (`proc.list`, `proc.kill`)

- Windows lists `Win32_Process` (`mem_kb` is the working set); elsewhere
  `ps axo pid=,ppid=,rss=,args=` (`name` is the base name of the first
  argument, `path` is set when that argument is absolute). Each `cmd` is cut to
  8192 characters with a trailing `…` when longer.
- `proc.kill` with `pid` answers `killed: 1` or an error. With `name` it kills
  every process of that exact name: on Windows through
  `taskkill /F [/T] /IM <name>` (`.exe` is added to a name without an
  extension) and `killed` counts the processes `taskkill` reports, which with
  `tree` includes children; elsewhere by case-insensitive name comparison.
  No match answers `killed: 0`.

### Files (`fs.*`)

- Paths: `~`, `~/x`, `~\x` and relative paths resolve against the home
  directory of the agent's user; results report absolute paths.
- `fs.stat` of a missing path answers `exists: false` without an error.
  `fs.list`, `fs.read` and `fs.tail` of a missing path are errors that name
  the path.
- `fs.list` lists the direct children, or with `recursive` the whole tree, in
  lexical order, at most 5000 entries. `sha256` (lower-case hex) is present
  only when asked for, and only for regular files the agent could read: a
  file another process holds open is listed without it.
- `fs.read` returns up to `length` bytes from `offset`; `eof` is true when
  the piece reaches the end of the file.
- `fs.tail` returns the last `lines` lines found in the last 262144 bytes.
  When that window begins inside a line, the partial line is left out.
- `encoding` is `"utf-16le"` for a file that begins with the bytes `FF FE`
  and absent otherwise. `fs.tail` of such a file starts on a code unit after
  the byte order mark and ends lines at the code unit `0A 00`; the returned
  bytes do not include the mark.
- `fs.write` creates the file when needed. With `append` the bytes go to the
  end and `offset` is not used; otherwise they are written at `offset`, after
  emptying the file when `truncate` is set. A missing parent directory is an
  error unless `mkdirs` is set.
- `fs.rename` fails when `to` exists unless `overwrite` is set, and never
  replaces a directory. `fs.mkdir` creates missing parents and succeeds for an
  existing directory.
- `fs.delete` of a missing path answers `deleted: false`. A directory with
  entries needs `recursive`. It refuses, before touching anything, the home
  directory, a file-system root (`/`, `C:\`) and any ancestor of the home
  directory, whether or not `recursive` is set.
- The host transfers a file as `fs.write` pieces to `<path>.alcove-part`,
  compares `fs.stat` with `sha256` against its own digest and then renames;
  downloads use `fs.stat` with `sha256` and `fs.read` pieces.

### Limits

| What | Limit |
|---|---|
| One message read by the agent (a line with its newline) | 1 MiB (`proto.MaxLine`); a longer line closes the connection |
| Binary payload of one `fs.read` / `fs.write` / `file.chunk` | 256 KiB (262144 bytes) before base64 |
| `exec.run` output | last 200000 bytes per stream |
| `exec` (v1) output | last 200000 bytes of the combined output, starting on a character boundary |
| `exec.list` `cmd` | 4096 characters per job, then `…` |
| `proc.list` `cmd` | 8192 characters per process, then `…` |
| `clipboard.text` / `clipboard.changed` text | 700000 bytes of UTF-8, cut on a character boundary |
| Job output | last 1 MiB per stream; `exec.read` returns at most 262144 bytes per stream |
| Jobs | 64 |
| `fs.list` | 5000 entries |
| `fs.tail` | last 262144 bytes of the file |

The host reads lines of up to 8 MiB and does not send a `req` longer than
1 MiB. JSON escaping can expand text (a NUL byte becomes six characters), so a
reply can be several megabytes long. What bounds each reply the agent writes:

- `exec.run`, `exec.read`, `fs.read` and `fs.tail` carry at most the payload
  limits in the table.
- `exec.list` is bounded by 64 jobs of at most 4096 characters of `cmd`.
- `proc.list` has one entry per process on the machine, each `cmd` at most
  8192 characters.
- `exec.result` carries at most 200000 bytes of `out`.
- `clipboard.text` and `clipboard.changed` carry at most 700000 bytes of
  text.
- `fs.list` is bounded by 5000 entries, not by bytes. A name is at most 255
  characters on the supported file systems, which keeps a listing of one
  folder under 8 MiB unless the names consist mostly of control characters.
  With `recursive` a name is a relative path and a tree of 5000 entries with
  very long paths can pass 8 MiB; the host then closes the connection.

### Known limitations

- PowerShell's `$input` does not decode non-ASCII stdin: with
  `stdin: "가\n"`, `$input` yields `Ω░Ç`, while `[Console]::In.ReadLine()`
  returns `가`. Read stdin through `[Console]::In`.
- With `shell: "cmd"` the output of `cmd.exe` built-ins goes through the OEM
  code page of the hidden console (437 on en-US), so `echo 한글` prints `??`.
  The same command started from the default shell (`cmd /c 'echo 한글'` as a
  PowerShell command) prints UTF-8.
- `findstr` and other programs that buffer until end-of-file print nothing
  to a running job until `exec.write` sends `eof`.
