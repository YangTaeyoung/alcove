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
  `vm.sync_dir`, `vm.find_text`. Such a request starts as soon as it arrives and answers when
  it finishes, so several can be in flight and their replies arrive in any
  order. Match replies by `id`. Pipelined requests of this lane are unordered
  among themselves: two `vm.fs.write` requests to one file sent back to back
  may be applied in either order. A caller that needs an order sends the
  second request after the reply to the first.
- **Serial lane**: every other op (`hello`, `vm.list`, `vm.status`, power,
  screenshot, mouse, keyboard, clipboard, `vm.batch`, `vm.wait_idle`,
  `vm.wait_for`). These run one after another in the order they arrived, and
  their replies come in that order; a long `vm.wait_for` or `vm.batch` holds
  back the later requests of the serial lane of its connection.

The lanes do not wait for each other: a screenshot or a click is answered
while a `vm.exec` of the same connection is still running. Mouse and keyboard
ops (and `vm.batch`) for one VM run one at a time across all connections.

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
| `vm.screenshot` | `name`, `region?`, `scale?`, `format?`, `quality?`, `maxWidth?` | `{png | jpeg, mime, width, height, sentWidth, sentHeight, x, y, areaWidth, areaHeight, scale}` — see [Screenshots](#screenshots) |
| `vm.mouse.move` | `name`, `x`, `y`, observe params | `{}` or `{observation}` |
| `vm.mouse.click` | `name`, `x`, `y`, `button?` ("left"/"right"/"middle"), `count?` (1 to 3), `hold?` ms (default 60), observe params | `{}` or `{observation}` — moves, presses, releases |
| `vm.mouse.drag` | `name`, `fromX`, `fromY`, `toX`, `toY`, `button?`, observe params | `{}` or `{observation}` |
| `vm.mouse.scroll` | `name`, `x`, `y`, `dx?`, `dy?` (notches, +down), observe params | `{}` or `{observation}` |
| `vm.mouse.down` / `vm.mouse.up` | `name`, `button?` ("left" default), `x?` and `y?` together, observe params | `{}` or `{observation}` — presses or releases the button and leaves it so; with `x`/`y` the pointer moves there first |
| `vm.key.press` | `name`, `keys` (string like "ctrl+alt+delete", "enter", "win+r"), `hold?` ms, observe params | `{}` or `{observation}` — presses modifiers then the key, releases in reverse |
| `vm.key.down` / `vm.key.up` | `name`, `key`, observe params | `{}` or `{observation}` |
| `vm.type` | `name`, `text`, `delay?` ms per key (default 12), observe params | `{}` or `{observation}` — US-layout text typing; characters outside the layout use the guest clipboard + paste when tools are connected |
| `vm.batch` | `name`, `steps`, observe params | `{completed, results, failedStep?, error?, observation?}` — see [Batches](#batches) |
| `vm.find_text` | `name`, `query?`, `regex?`, `region?`, `languages?` | `{matches, lines}` — see [Finding text](#finding-text) |
| `vm.wait_for` | `name`, `conditions`, `timeout?`, observe params | `{matched, waited, type?, detail?, problems?, observation?}` — see [Waiting for conditions](#waiting-for-conditions) |
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
| `vm.wait_idle` | `name`, `seconds?` (stable period, default 2), `timeout?` (default 30) | `{idle: bool}` — `true` when fewer than 0.5% of the frame's 32x32 tiles changed between samples 250 ms apart for the whole period, `false` at the timeout |

Key names: letters, digits, `enter return tab space esc escape backspace delete
insert home end pageup pagedown up down left right f1..f20 capslock
printscreen`, modifiers `ctrl control alt option shift win cmd meta super`,
punctuation by character (`-` `=` `[` `]` `;` `'` `,` `.` `/` `` ` `` `\`).
Combos use `+`. Names are case-insensitive.

## Screenshots

`vm.screenshot` reads the current guest frame and returns it, optionally
cropped and shrunk.

- `region` `{x, y, w, h}` (guest pixels, `w` and `h` above 0) crops to the part
  inside the frame; a region partly outside is cut to the frame, one fully
  outside answers `region is outside the <W>x<H> frame`.
- `scale` is a number from 0.1 to 1 (default 1) applied to the cropped area.
- `maxWidth` shrinks the image to that width when it is below the scaled
  width; there is no default.
- `format` is `png` (default) or `jpeg`; `quality` is from 0.1 to 1 (default
  0.8) and only affects JPEG. Other values answer
  `format must be 'png' or 'jpeg'` / `quality must be between 0.1 and 1`.
- The result holds the image base64-encoded under `png` or `jpeg`, `mime`
  (`image/png` or `image/jpeg`), `width` and `height` of the whole guest frame,
  `sentWidth` and `sentHeight` of the image, `x` and `y` of the top-left corner
  of the area the image shows (0 without `region`), `areaWidth` and `areaHeight`,
  the size of that area in guest pixels (the region after clamping, or the whole
  frame), and `scale`, the image
  pixels per guest pixel (`sentWidth` divided by the width of the area).
  A guest pixel is `x + image_x / scale`, `y + image_y / scale`.

## Observing the screen after input

Every action op (`vm.mouse.move`, `.click`, `.drag`, `.scroll`, `.down`, `.up`,
`vm.key.press`, `.down`, `.up`, `vm.type`), `vm.batch` and `vm.wait_for` accept
three parameters:

- `observe`: `none` (default), `summary`, `diff` or `image`. Any other value
  answers `observe must be one of none, summary, diff, image`.
- `settleMs`: whole milliseconds from 0 to 10000 (default 300).
- `settleTimeoutMs`: whole milliseconds from 100 to 30000 (default 2000).
  `settleMs` above `settleTimeoutMs` answers
  `settleMs (<a>) must not exceed settleTimeoutMs (<b>); lower settleMs or raise settleTimeoutMs`
  before any input is sent.

With `observe` `none` the result has no observation and no frame is read.
Otherwise the op reads the frame before it sends input; if that fails it sends
nothing and answers `the screen could not be read before <op>, so no input was
sent: <reason>`. After the input it samples the screen every 50 ms; the screen
has settled once no 32x32 tile differs between consecutive samples for
`settleMs`, and sampling ends unsettled after `settleTimeoutMs`. The result
carries `observation`:

| field | meaning |
|---|---|
| `settled` | whether the screen settled before `settleTimeoutMs` |
| `changed` | `{x, y, w, h}`, the bounding box in guest pixels of the tiles that differ from the frame before the input; absent when none differ |
| `changedFraction` | share of the frame's tiles that differ, 0 to 1 |
| `width`, `height` | size of the settled frame |
| `png`, `imageRect`, `imageScale` | with `diff` (only when something changed) or `image`: the PNG, the guest rectangle it shows, and image pixels per guest pixel. `diff` shows the changed box plus 16 pixels on every side, cut to the frame; `image` shows the whole frame. An image wider than 1280 pixels is shrunk to 1280 |

When the screen cannot be read after the input was sent, the input stands and
the result carries `observationError` (a sentence of the form `the screen could
not be read after <op>: <reason>; call vm.screenshot to see the result`)
instead of `observation`.

## Batches

`vm.batch` runs `steps` (an array of 1 to 50 objects) in order for one VM
while holding that VM's input gate once, so no other connection's input
interleaves. A step is an object with `op` and the parameters of that op
without `name` (a `name` that differs from the batch's VM is refused).
Allowed `op` values: the action ops (`vm.mouse.move`, `.click`, `.drag`,
`.scroll`, `.down`, `.up`, `vm.key.press`, `.down`, `.up`, `vm.type`),
`vm.wait_idle`, `vm.wait_for` and `sleep` (`ms`, a whole number from 1 to
10000). Any other `op` is refused. The whole batch is validated before
anything runs; refusals name the step as `step <i>: ...`. Step indices count
from 0 everywhere: in refusals, in `results` and in `failedStep`.

Each step runs with `observe` `none`; `observe`, `settleMs` and
`settleTimeoutMs` on the batch itself ask for one observation after the last
step (compared with the frame before the first step), with the same
`observation` / `observationError` fields as an action op.

The result is `{completed, results, observation?}`: `completed` steps ran
and `results[i]` is the result of step `i` (`{}` for input and `sleep`,
`{idle}` for `vm.wait_idle`, the `vm.wait_for` result for `vm.wait_for`).
The first step that fails ends the batch; the reply is still a success and adds
`failedStep` (its index) and `error` (its message). Steps after it do not
run; steps before it keep their effect.

## Finding text

`vm.find_text` reads the text on the screen with the macOS Vision framework.

- `query` (default empty): a case-insensitive substring; with `regex: true`
  a case-insensitive regular expression (an invalid one answers
  `'<query>' is not a valid regular expression`). An empty query returns every
  recognized line.
- `region` is as for `vm.screenshot`.
- `languages` is a non-empty array of recognition languages, default
  `["ko-KR", "en-US"]`; an unsupported one is refused before any
  recognition and answers
  `language '<l>' is not supported; supported: ...`.
- The result is `{matches, lines}`. `matches` lists the matching lines in
  reading order (top to bottom, then left to right) as `{text, x, y, w, h, cx,
  cy, confidence}`: the rectangle in guest pixels of the whole frame, its centre
  (`cx`, `cy`, the point to click) and a confidence from 0 to 1 with two
  decimals. `lines` is the number of lines recognized in the area before the
  filter. Frames narrower than 400 pixels are enlarged twofold for recognition.
- When the Vision request itself fails (`text recognition failed: <reason>`),
  the op waits 150 ms and tries once more on the same frame; a second failure
  answers `text recognition failed twice; call vm.find_text again or use
  vm.screenshot`. Other errors, such as an unsupported language or a frame that
  cannot be read, answer at once without a retry.

## Waiting for conditions

`vm.wait_for` waits until one of 1 to 8 `conditions` holds or `timeout`
seconds (a number from 1 to 600, default 30) pass. It is an op of the serial
lane that takes no input gate. Conditions are numbered from 0.

| `type` | fields | holds when | `detail` of a match |
|---|---|---|---|
| `screen_idle` | `seconds?` (0 to 600, default 2) | fewer than 0.5% of the frame's tiles changed between consecutive samples for `seconds` | none |
| `region_changed` | `region` | a tile inside the region differs from the region at the start of the wait, or the region no longer fits the frame | none |
| `text_visible` | `text`, `regex?`, `region?`, `languages?` | a recognized line contains `text` (case-insensitive substring, or regular expression with `regex: true`) | `{text, x, y, w, h, cx, cy}` of the first matching line |
| `text_gone` | as `text_visible` | no recognized line matches | none |
| `process_started` | `processName` | a guest process with that name exists (case-insensitive, `.exe` ignored) | `{pid, name}` |
| `process_exited` | `pid` or `processName` | no guest process has that `pid` (or, without `pid`, that name) | none |
| `file_exists` | `path` | the guest file or folder exists | `{path, size}` |
| `port_listening` | `port` (1 to 65535) | a TCP port listens in the guest | none |
| `log_matches` | `path`, `pattern` | one of the last 400 lines of the guest file matches the regular expression | the line, cut to 500 characters |
| `job_output_matches` | `job`, `pattern` | the stdout or stderr of the job (last 64 KiB of each, read from the start) matches the regular expression, with `^` and `$` matching at line breaks | none |

`process_exited` with a `pid` that does not exist holds at once, because the
condition is "no such process". `screen_idle` compares each sample with the
previous sample, not with the frame at the start. The conditions that read the
screen take the screen at the start of the wait as their reference
(`region_changed`) or first sample (`screen_idle`).

Conditions are evaluated in a loop with a 250 ms tick; each condition has its
own period: 250 ms for `screen_idle` and `region_changed`, 700 ms for
`text_visible` and `text_gone`, 500 ms for the conditions that call the guest
tools. Conditions that read the screen share one frame per tick, and equal
text searches share one recognition. A condition that needs guest tools
(`process_*`, `file_exists`, `port_listening`, `log_matches`,
`job_output_matches`) answers `guest tools are not connected in '<vm>'; ...`
when they are not connected after a wait of up to 25 s. If several conditions hold on the same tick, the
one with the lowest index wins.

The result is `{matched, waited, type?, detail?, problems?, observation?}`:

- `matched` is the index of the condition that held, or `-1`. `waited` is the
  elapsed time in seconds with one decimal. `type` is its `type`; `detail` is
  as in the table. Running out of time is a success with `matched: -1`.
- `job exited`: when a `job_output_matches` condition sees the job exited and
  all its output read without a match, it can no longer become true and the wait
  ends at once with `matched: -1`, `type: "job_output_matches"` and
  `detail: "job exited"`.
- A failing evaluation (a frame, recognition or guest call that errors or times
  out) does not end the wait: the condition is tried again at its next period.
  `problems` appears only when `matched` is `-1` and lists
  `{condition, type, error, failures}` for each condition whose latest
  evaluations failed, `failures` being the number in a row. Errors that make the
  condition meaningless end the wait with an error instead: a guest-tools
  connection that is lost or too old, a `region` outside the frame
  (`condition <i>: region is outside the <W>x<H> frame`), an unknown job, a
  `port_listening` on a guest OS that is not supported.
- `observe` at a level above `none` adds `observation` or `observationError`
  as for an action op, comparing the final screen with the screen at the start
  of the wait.

## Leases and read-only ops

An op that is not read-only is refused while another connection holds a lease
on the VM, unless it passes the lease's token as `lease`. The read-only ops,
which ignore leases, are `hello`, `vm.list`, `vm.status`, `vm.screenshot`,
`vm.wait_idle`, `vm.wait_for`, `vm.find_text`, `vm.clipboard.get`,
`vm.exec.read`, `vm.exec.list`, `vm.process.list`, `vm.fs.list`, `vm.fs.read`,
`vm.pull_file`, `vm.snapshot.list`, `vm.forward.list`, `vm.lease.acquire`,
`vm.lease.release` and `vm.doctor`. The action ops and `vm.batch` are not
read-only; a batch checks the lease once, for the whole batch.

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
