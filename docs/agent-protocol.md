# Alcove guest agent protocol

Version 1, with request/response layer 2. The agent (`alcove-agent`, Go) runs
inside the guest and listens on TCP port 7645. The engine forwards a host
loopback port to it (`hostfwd=tcp:127.0.0.1:<port>-:7645`); the app connects
from the host. Newline-delimited JSON objects in both directions, discriminated
by `t`.

## Handshake

Agent → host on connect:

```
{"t":"hello","v":1,"proto":2,"os":"windows"|"linux","agent":"0.2.0","token":"<uuid>","caps":["files","shutdown","resolution","clipboard","exec","rpc","jobs","proc","fs","ui"]}
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
| `jobs`, `proc`, `fs` | started with `--allow-exec` | `exec.*`, `proc.*`, `fs.*` and `app.launch` operations |
| `ui` | Windows agents | `win.*` and `ui.*` operations and the window events |

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
- The `exec.*`, `proc.*` and `fs.*` operations and `app.launch` answer
  `exec disabled; start alcove-agent with --allow-exec` unless the agent was
  started with `--allow-exec`. `ping`, `win.*` and `ui.*` do not need it.
- `ev` messages are not replies. They go to every open connection. The events
  are `job.exited` ([Jobs](#jobs-execstart-execread-execwrite-execkill-execlist)),
  `process.exited` ([App launch](#app-launch-applaunch)), the window events
  ([Window events](#window-events)) and `events.dropped` (a connection's event
  queue overflowed; it carries only `count`, the number of events dropped at
  that place in the stream).

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
| `app.launch` | `path`; `args` ([string]); `cwd`; `env` (object of strings); `wait_window_ms` (default 15000, 0 skips the wait, cap 300000) | `pid`, `window` (a window object, when a window was found) |
| `win.list` | — | `windows`: [window object] |
| `win.action` | `window`, `action` (`focus`, `minimize`, `maximize`, `restore`, `close`, `move`, `resize`); `x`, `y` for `move`; `w`, `h` for `resize` | `window` (after the action, `null` when it is gone); `closed` (bool, for `close`) |
| `ui.tree` | `window` (default `foreground`), `root` (ref), `depth` (default 12, at most 256), `max` (default 300, cap 2000), `filter` (`interactive` default, `all`) | `window`, `nodes`, `truncated` |
| `ui.find` | selector fields, `limit` (default 20, cap 2000) | `nodes` (depth 0); `truncated: true` when the search ended early |
| `ui.text` | `ref` or selector fields, `mode` (`auto` default, `pattern`, `descendants`), `offset`, `length` (default and cap 200000; 0 returns `total` alone) | `text`, `total`, `source` (`text`, `value`, `name`, `descendants`) |
| `ui.rect` | `ref` or selector fields, `scroll` (bool) | `node`, `cx`, `cy`, `clickable`; `blocked` (a sentence, when not clickable) |
| `ui.act` | `ref` or selector fields, `action` (`invoke`, `toggle`, `expand`, `collapse`, `select`, `set_value`, `focus`, `scroll_into_view`), `value` (for `set_value`) | `node`; `unresponsive: true`, `gone: true` or `pending: true` when the node could not be read after the action |
| `ui.focused` | — | `node`, `window` |
| `ui.ping` | — | `pong`, `pid`, `session`, `integrity`, `dpi`, `clr`, `refs` |

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

### App launch (`app.launch`)

- `path` is the program. A bare file name that is not on the search path is
  looked up under `HKCU` and `HKLM`
  `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\<name>` and the 32-bit
  view `SOFTWARE\WOW6432Node\…\App Paths\<name>` (`.exe` added when the name
  has no extension), so `msedge.exe` starts Edge; a `REG_EXPAND_SZ` value has
  its `%VAR%` references expanded.
- The program starts directly with `args` as its arguments and with a normal
  window. Without `cwd` it runs in the directory of the program file; `cwd`
  resolves like the `cwd` of `exec.run`. `env` adds variables to the agent's
  environment; a name given there replaces one of the same name
  (case-insensitive on Windows), and an empty name or one that contains `=`
  answers `env names cannot be empty or contain '='`. Its standard input,
  output and error are the null device, so a console program that reads its
  input ends at once.
- A program that cannot be started answers
  `cannot start '<path>': <system error>; check the path with fs.stat`.
- When the process ends the agent sends
  `{"t":"ev","name":"process.exited","pid":<int>,"code":<int>,"path":"<program file>"}`.
  `code` is the unsigned exit code: a process killed by `proc.kill` reports
  1, a fail-fast crash 3221227010 (`0xC0000602`). For a launcher that hands
  over to another process (`notepad.exe`, `calc.exe`, `msedge.exe` when Edge
  already runs) the event names the launcher and arrives within a second, so
  `process.exited` can arrive before the `app.launch` reply. The process is
  not a job, and it keeps running when the agent restarts; `process.exited`
  is then not sent.
- With `wait_window_ms` above 0 on an agent with the `ui` capability, the
  agent lists the windows before the start and then every 150 ms:
  - candidates are the titled windows that were not listed before the start
    and not already claimed by another in-flight or finished `app.launch` (a
    claim ends when its window closes and when a helper starts; the agent
    keeps the 1024 newest claims);
  - a candidate of the started process or one of its descendants is chosen,
    and beats a candidate of any other process whatever their sizes;
  - when the started process has exited, or 2 s after the start, a candidate
    of any process is chosen;
  - of several candidates the one with the largest rectangle is chosen, after
    one more listing 150 ms later, so that windows which open together compete;
  - a frame window of a packaged app that still reports
    `ApplicationFrameHost.exe` is read again for up to 3 s until it reports the
    app's process.

  Without a candidate within `wait_window_ms` the reply has `pid` alone. When
  the windows cannot be listed before the start the program is not started:
  `'<path>' was not started because the windows could not be listed: <reason>`.
  Measured: the fixture app answers after 0.4–0.65 s, `notepad.exe` after
  0.9 s (window of `Notepad.exe`, another pid), `calc.exe` after 0.7 s
  (`CalculatorApp.exe`).

### Windows and UI Automation (`win.*`, `ui.*`)

A Windows agent runs a helper (C# compiled by Windows PowerShell 5.1, .NET
Framework UI Automation) as a child process in the agent's logon session and
passes these operations to it. Other agents answer
`UI Automation is only available on Windows guests`.

**Helper process.** The agent starts the helper on the first `win.*` or
`ui.*` operation, and again on the next operation after the helper ended; it
does not start on connect, so a wait for a window event must be preceded by
`ui.ping` (and `app.launch` with `wait_window_ms: 0` does not start it). The
helper runs in the agent's logon session. Its files are in
`C:\ProgramData\Alcove\uia`: `bootstrap.ps1`, `helper.cs`, `helper.log` and
`helper.log.1` (1 MiB each), and a `tmp` folder the compile uses. Every start
compiles `helper.cs` in memory; no compiled helper is stored. That
folder and its parent `C:\ProgramData\Alcove` are given the owner
Administrators and the access list "Administrators and SYSTEM: full control"
with inheritance removed (`icacls` reads it back as
`BUILTIN\Administrators:(OI)(CI)(F)` and `NT AUTHORITY\SYSTEM:(OI)(CI)(F)`),
so `agent.log`, `install.log` and `helper.log` are readable by administrators
only. Each folder is opened without following a reparse point, and its owner
and access list are checked and set on that handle (`SetSecurityInfo`). The lock is applied first thing at install and at
agent start, before a log file is opened, and again at every helper start; the
parent keeps the agent's logs, the uia folder keeps only its logs (every other
entry is deleted at each start), and a reparse point in either folder,
including one at the uia path, is removed rather than followed and the uia
folder is created again. The agent opens no log file that is a reparse point
and none inside a folder it could not lock. When a folder cannot be locked the
helper does not start:
`the UI helper folder <dir> could not be locked (<reason>); fix its owner and access list, then retry`.
A reparse point at `C:\ProgramData\Alcove` itself gives the reason
`C:\ProgramData\Alcove is a reparse point; remove it`; something at a folder
path that is not a directory gives
`<dir> is not a directory; remove it and restart alcove-agent`. Before a start
the agent waits up to 10 s for the previous helper process to end
(`the previous UI helper process has not ended after 10 s; retry`). A helper
whose files cannot be written or compiled answers
`the UI helper could not be prepared in <dir>: <reason>; check free space and the folder's access list`.
On the wire these start failures follow
`could not start the UI helper through PowerShell: ` (lock, wait and file
failures) or `UI helper failed to start through PowerShell: ` (a failure the
bootstrap script reports).
The helper's environment is the agent's without `COR_*`, `COMPlus_*`,
`DOTNET_*` and `PSModulePath`, and `TEMP`/`TMP` point inside the locked
folder. Measured on the Windows 11 ARM64 test guest: the first `ui.ping` after
an agent start answers after 0.59–0.60 s (1.1–1.3 s for the first one after a
boot), of which the compile takes 0.35 s; a helper that was killed is replaced
in 0.6–0.85 s. The helper, and an app launched through `app.launch`, inherit
the agent's elevated token. `alcove-agent --install` locks the folders before
it copies or registers anything and fails when they cannot be locked
(`the Alcove data folder <dir> could not be locked (<reason>); fix its owner and access list with icacls, then run alcove-agent --install again`)
or when `%ProgramData%` is empty; it then writes no `install.log`.

**One request at a time.** The agent hands requests to the helper one by one
in the order they arrived. An operation's time limit (20 s; 30 s for
`ui.tree` and `ui.text`) starts when the helper receives it. Waiting for a
turn is limited to 60 s and then answers
`the UI helper is busy with '<op>'; retry` (`<op>` is the helper operation
holding the helper); the helper keeps running. Each request is cancelled when
its connection closes: one still waiting for its turn leaves the queue without
reaching the helper (`the request was cancelled`), while one already handed to
the helper runs to its end. A
request the helper does not answer within its limit answers
`UI helper did not answer '<op>' within <n> s; it was restarted`: the helper
is killed, requests that waited behind it run in the next helper, and every
ref is forgotten. A request that was inside a helper that ended answers
`UI helper exited; retry`. A helper that does not start within 120 s answers
`UI helper did not start within 120 s; see <helper.log>`.

**Window object.**

```
{"id":"0xd0368","title":"Alcove Fixture","pid":7140,"process":"alcove-fixture.exe","class":"AlcoveFixtureWindow",
 "x":40,"y":40,"w":800,"h":600,"state":"normal","foreground":true,"responding":true,"modal":false}
```

- `id` is the window handle. `x`, `y`, `w`, `h` are guest pixels of the
  visible frame (without the invisible resize border); a minimized window has
  `0,0 0x0`. `state` is `normal`, `minimized` or `maximized`.
- `responding` is false once the system considers the window hung (about 5 s
  without message handling). `modal` is true when the window's owner is
  disabled.
- `pid` and `process` name the process a user would name: for the frame
  window of a packaged app the process of its core window, for the `Ghost`
  window the system shows in place of a hung window (titled
  `<title> (Not Responding)`) the process of the hung window. The hung window
  itself stays listed.
- `win.list` lists, top-most first, the top-level windows that are visible,
  not cloaked and titled, and the foreground window even without a title.

**Window argument.** `window` is an id from `win.list`, `foreground`, or a
part of a title (case-insensitive; the top-most match). Errors:
`window 0x1 no longer exists; call win.list again` (also for the handle of a
child window), `"0xzz" is not a window id; ids look like 0x1a2b3c and come from win.list`,
`no window has "<text>" in its title; call win.list to see the open windows`,
`no window is in the foreground; pass a window id from win.list`,
`pass a window id, a title part, or foreground` (empty string). A window that
does not handle messages answers the `ui.*` operations addressed to it with
`window <id> "<title>" is not responding; wait and retry, or end its process with proc.kill when win.list still shows responding false after 10 s`.
A window of a higher integrity level, which denies the probe message rather
than being hung, is not reported as not responding.

**`win.action`.** `window` is required.

- `focus` restores a minimized window and brings the window to the
  foreground with `SetForegroundWindow`; when that call fails, with the same
  call while the helper's thread input is attached to the foreground window's
  thread; then with `SwitchToThisWindow`. A window that still is not in the
  foreground answers
  `window <id> "<title>" did not come to the foreground; click its title bar through the display`.
- `minimize`, `maximize` and `restore` wait up to 2 s for the new state;
  `restore` ends the minimized state of a minimized window and the maximized
  state of a maximized one. A window that does not change answers
  `window <id> "<title>" was not minimized within 2 s; check responding in win.list, then retry or end its process with proc.kill`.
- `move` (`x`, `y`) and `resize` (`w`, `h`) apply to the visible frame, the
  rectangle `win.list` reports; a minimized or maximized window returns to
  its normal state first, without being activated. The window decides its
  final size (the fixture app answers `resize` to 100×100 with 506×393), and
  a position outside the screen is accepted.
- `close` posts `WM_CLOSE` and waits up to 2 s. `closed` says whether the
  window is gone; `window` is then `null`, otherwise the window as it is. A
  shell window (class `Progman`, `WorkerW`, `Shell_TrayWnd` or
  `Shell_SecondaryTrayWnd`) is refused:
  `window <id> is part of the Windows shell and is not closed; close app windows only`.
  When the message cannot be posted: a window that no longer exists answers
  `closed: true` with `window: null`; one that denies the post answers
  `window <id> belongs to a process the helper cannot send to`; any other
  failure answers `window <id> could not be asked to close (error <n>); retry`
  with the Windows error code.
- A show-state change (`minimize`, `maximize`, `restore`) that does not take
  within 2 s answers
  `window <id> "<title>" <what> within 2 s; the app may not allow it; use win.list to see its state`
  when the window still answers messages, and the
  `… check responding in win.list, then retry or end its process with proc.kill`
  form only when the window is hung.
- Errors: `action must be one of focus, minimize, maximize, restore, close, move, resize`,
  `pass window: a window id from win.list, a title part, or foreground`,
  `move needs x and y`, `resize needs w and h`, `pass w and h of at least 1`.

**Node object.**

```
{"ref":"e620","depth":0,"role":"Edit","name":"Message","value":"안녕 \"fixture\"","aid":"101","x":186,"y":125,"w":484,"h":26,"flags":["focused"]}
```

- `ref` matches `^e\d+$` and names the element while it exists; each helper
  process numbers its refs from `<number of earlier helpers> × 1000000 + 1`.
  A ref whose element is gone answers
  `element <ref> no longer exists; call ui.tree again`; other text answers
  `ref "<text>" is not a ref; refs look like e12 and come from ui.tree or ui.find`.
- `role` is the control type name (`Button`, `Edit`, `Document`, …). A
  multi-line Win32 edit control is a `Document`.
- `value` is the value-pattern value cut at 200 characters with `…`; it is
  absent when empty and for password fields. `aid` is the automation id,
  absent when empty. Line ends in `value` and in `ui.text` are LF.
- `flags` come from `focused`, `disabled`, `offscreen`, `selected`,
  `checked`, `expanded`, `collapsed`, `password`. The children of a window
  whose modal dialog is open are `disabled`.
- `depth` counts the listed ancestors.

**Selector fields.** `window` (default `foreground`), `role`
(case-insensitive; an unknown role answers `unknown role "<text>"; use one of …`),
`name` (exact), `nameContains` (case-insensitive), `automationId` (exact),
`index` (0-based among the matches in tree order). At least one of `role`,
`name`, `nameContains`, `automationId` is required:
`pass ref or at least one of role, name, nameContains, automationId`. No
match answers
`no element matches {"window":"0xd0368","role":"Button","name":"Nope"}; call ui.tree to see what exists`
(the JSON holds the selector fields that were sent); `ui.find` answers
`nodes: []` instead. A search that ended early answers one of

- `the search for <selector> did not finish within 12 s; read the window in parts with ui.tree and root, then use a ref` (22 s for `ui.text`),
- `the search for <selector> stopped 256 levels below the window; read the deeper part with ui.tree and root, then use a ref`,
- `the search for <selector> met an element that disappeared; call the operation again`,

and `ui.find` with at least one match returns the matches with
`truncated: true`.

**`ui.tree`** lists the control view below the window or `root`. `filter:
interactive` keeps elements with a name, a value, keyboard focus support or
an invoke pattern, and the control types people act on; `all` lists the raw
view. `truncated` is true when a listed element did not fit in `max`, after
20 s, and when an element disappeared during the walk. `depth` above 256
answers `depth must be 256 or less; read deeper parts with root`. A `root`
that is a password field is listed alone, and a `root` below a password field
is refused with the password sentence of `ui.text`.

**`ui.text`** in `auto` mode returns the text pattern's document text, then
the value, then the names (for edits and documents, the values) of the text,
list item, edit and document elements below the element joined by newlines,
then the element's name. `pattern` uses the text pattern alone
(`the element has no text pattern; use mode auto or descendants`). A password
field, or an element below one, answers
`the element is a password field; its text is not read; it cannot be read through UI Automation`
in every mode; a failed password-property read counts as a password field, as
do a parent that cannot be read and a chain of more than 256 parents; and
`ui.tree`, `ui.find` and the descendant text of `ui.text` do not list what is
below a password field. A node below a password field in a `ui.rect`, `ui.act`
or `ui.focused` reply has the `password` flag, an empty `name` and no `value`.
The document text of a Chromium page shows a password field as bullets.

**`ui.rect`**: `cx`, `cy` are the centre of the element's rectangle;
`clickable` is false with a `blocked` sentence when the rectangle is empty,
the element is off screen or disabled, the centre is outside the screen or
another top-level window covers it. `scroll: true` scrolls the element into
view first when it has a scroll-item pattern.

**`ui.act`** calls a UI Automation pattern on the element:

| `action` | Pattern call |
|---|---|
| `invoke` | `InvokePattern.Invoke` |
| `toggle` | `TogglePattern.Toggle` |
| `expand`, `collapse` | `ExpandCollapsePattern` |
| `select` | `SelectionItemPattern.Select` |
| `set_value` | `ValuePattern.SetValue(value)`; a read-only element answers `the element is read-only; its value cannot be set; type into another element or change it in the app` |
| `focus` | brings the element's window to the foreground as `win.action focus` does, then `SetFocus` |
| `scroll_into_view` | `ScrollItemPattern.ScrollIntoView` |

- The reply's `node` is read 100 ms after the call. A pattern call may bring
  the element's window to the foreground (`set_value` on a Win32 edit control
  does).
- The call counts as done when it returned or when the element's window
  stopped taking input because it opened a modal window. A call that has not
  returned after 1.5 s is left running; the reply then carries the node as it
  was before the action and, when the window no longer handles a message
  within 0.5 s, `unresponsive: true` (a button that makes its window hang
  answers after about 2.1 s), otherwise `pending: true`.
- When the element is gone after the action the reply carries the node as it
  was before and `gone: true`. The same reply is given when the element's
  window no longer exists after the call and when the pattern call failed
  because the element or its app went away during it.
- A disabled element is refused before the call:
  `the element is disabled; wait until it is enabled`. More than eight `ui.act`
  calls still running in one app answer
  `<n> earlier ui.act calls are still running in the app; wait for them or end its process with proc.kill`.
- Errors: `the element does not support toggle; it supports invoke, focus; click it through the display for anything else`
  (the list names what the element supports), `the element is disabled; wait until it is enabled`,
  `set_value needs value`,
  `action must be one of invoke, toggle, expand, collapse, select, set_value, focus, scroll_into_view`,
  `<action> is not possible on the element in its present state: <reason>`.

**`ui.focused`** returns the element with the keyboard focus and its window
(`window` is `null` when the element has none), or
`no element has the keyboard focus; click a window or use win.action focus`.

#### Window events

While the helper runs it compares the titled windows every 300 ms and the
agent sends one event per difference, each with the window object:

```
{"t":"ev","name":"window.opened","window":{…}}
```

| `name` | Sent when |
|---|---|
| `window.opened` | a titled window is listed that was not listed before |
| `dialog.opened` | in addition to `window.opened`, when that window is modal or of class `#32770` |
| `window.closed` | a listed window is gone (the object is the last one seen, with `foreground: false`) |
| `window.title` | the title of a listed window changed |
| `window.foreground` | another window is in the foreground (also sent for a window without a title, such as the taskbar) |

- An event arrives up to 300 ms after the change, plus under 2 ms for the
  comparison (a `window.title` one comparison later). In one comparison the order is closed, opened (with
  `dialog.opened`), title, foreground.
- The first comparison of a helper process sends nothing; changes while no
  helper runs are not reported. Events flow only while the helper runs, so a
  client that wants them sends `ui.ping` first to start it.
- The first comparison of a helper also records the titles and the foreground
  window, so a helper start sends no `window.title` or `window.foreground` for
  windows that did not change.
- At most one `window.title` is sent per window per second. A new title is
  sent once it was the same in two comparisons in a row and a second has
  passed since that window's previous `window.title`; a title that changes in
  every comparison sends nothing until it rests, and a title that returns to
  the one last sent sends nothing. The fixture's `Titles` button (a new title
  every 50 ms for 5 s, then one held for 600 ms, then the base title) raises
  two events: one for the held title and one for the base title.
- At most one `window.foreground` is sent per window per second. One that
  falls inside that second is sent once the second has passed, when the
  window is still in front, so the last `window.foreground` names the window
  in front.
- Each connection has a bounded event queue of 256 messages. When it is full
  (a client that does not read) events are dropped and counted, and the agent
  puts `{"t":"ev","name":"events.dropped","count":<n>}` in the place of the
  dropped events: before the next event that is queued, or after the last
  queued message when no event follows. It carries only the count. A
  connection whose write stalls for 30 s is closed.
- A window that gets its title after it was shown is reported as opened at
  that moment. Short-lived system windows are reported like any other
  (`PopupHost` of class `Xaml_WindowedPopupClass` from the shell, the `Ghost`
  window of a hung window).
- A hung window stays listed; its `Ghost` window raises `window.opened` and
  `window.foreground` about 5 s after the hang began.

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
| One `win.*` / `ui.*` reply | 8 MiB minus 4 KiB; a larger one answers `the answer to '<op>' is larger than 8 MiB; ask for less with max, depth, limit or length` |
| `ui.tree` | `max` 2000 nodes, `depth` 256, 20 s |
| `ui.find` | `limit` 2000, 12 s, 256 levels |
| `ui.text` | 200000 UTF-16 code units per reply, 22 s |
| Node `value` | 200 characters, then `…` |
| Refs kept by a helper | 20000; beyond that the least recently used half is forgotten |
| Waiting for the helper | 60 s per request |

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
- `app.launch` chooses the window on the first listing that shows a
  candidate and the listing after it. A window that opens later (a main
  window after a splash screen) is not returned; `win.list` and
  `window.opened` show it.
- UI Automation lists only the realized rows of a virtualized list, and the
  first read of a Chromium window after a page load can lack the page.
- A Win32 edit control takes its `name` from the label before it in the
  z-order of its siblings. `ui.act set_value` sometimes moves the edit in
  front of its label; its `name` is then its own text (empty for a password
  field). A `ref` or `automationId` keeps addressing it.
- The helper serves no request while a UI Automation call into an
  unresponsive application waits; windows the system already reports as not
  responding are refused before the call.
- A connection that does not read its events loses them: the agent drops the
  overflow and reports the count with an `events.dropped` event at the place
  of the dropped events.
