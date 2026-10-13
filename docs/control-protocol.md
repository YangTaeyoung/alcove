# Alcove control protocol (automation API)

Version 1. Lets automation on the Mac — the `alcove-mcp` server for Claude
Code and other agents, `alcovectl`, scripts — drive VMs: list and start them,
take screenshots, move the mouse, click, type, press keys, run shell commands
and background jobs in the guest, list and kill guest processes, exchange
clipboard text, copy, sync, read and write guest files, take and restore
snapshots, forward ports, cut the guest's network link, lease a VM, change
guest settings, diagnose a VM, and create linked clones and sessions that
discard their changes.

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
  `vm.wait_for`, snapshots, forwards, `vm.set_network`, leases,
  `vm.set_resolution`, `vm.set_environment`, `vm.doctor`, `vm.clone`,
  `vm.delete`). These run one after another in the order they arrived, and
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
| `vm.list` | — | `{vms: [{name, guestOS, state, suspended, width?, height?, error?, leasedBy?, cloneOf?, ephemeral?}]}` — see [VM rows](#vm-rows) |
| `vm.status` | `name` | the VM's row plus, while it is running or paused, `tools: bool` and, with tools, `agentCaps: [...]` |
| `vm.start` | `name`, `discardChanges?`, `waitTools?` | `{state, ephemeral}` after the guest is running; `{state, ephemeral, resumed, tools, clockSynced}` when it resumed a session saved to disk — see [Starting](#starting) |
| `vm.stop` | `name`, `force?` | `{state}` after the engine exited (graceful ACPI first) |
| `vm.clone` | `name` (the template), `newName` | `{name}` — see [Linked clones](#linked-clones) |
| `vm.delete` | `name` (a clone) | `{}` — see [Linked clones](#linked-clones) |
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
| `vm.snapshot.list` | `name` | `{snapshots: [{name, date, vmStateBytes}]}` — see [Snapshots](#snapshots) |
| `vm.snapshot.create` | `name`, `snapshot` | `{snapshot}` |
| `vm.snapshot.restore` | `name`, `snapshot`, `waitTools?` s (default 30) | `{snapshot, tools: bool, clockSynced: bool}` |
| `vm.snapshot.delete` | `name`, `snapshot` | `{}` |
| `vm.forward.add` | `name`, `guestPort`, `hostPort?` | `{hostPort, guestPort}` — see [Port forwards](#port-forwards) |
| `vm.forward.remove` | `name`, `hostPort` | `{}` |
| `vm.forward.list` | `name` | `{forwards: [{hostPort, guestPort, kind: "config"|"agent"|"runtime"}]}` |
| `vm.set_network` | `name`, `up` (bool) | `{up}` — see [Network link](#network-link) |
| `vm.lease.acquire` | `name`, `owner?`, `ttl?` s (default 300), `lease?` (to renew) | `{lease, expiresIn}` — see [Leases and read-only ops](#leases-and-read-only-ops) |
| `vm.lease.release` | `name`, `lease` | `{}` |
| `vm.set_resolution` | `name`, `width`, `height` | `{width, height}` — see [Resolution](#resolution) |
| `vm.set_environment` | `name`, any of `theme`, `timeZone`, `clock`, `locale`, `keyboardLayouts`, `dpiScale` | `{applied: [{setting, ok, detail, takesEffect}]}` — see [Guest environment](#guest-environment) |
| `vm.doctor` | `name` | `{checks: [{id, ok, detail, hint?}]}` — see [Doctor](#doctor) |

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

## VM rows

`vm.list` and `vm.status` describe a VM with the same fields:

| field | meaning |
|---|---|
| `name`, `guestOS` | the VM's name and `windows`, `linux` or `other` |
| `state` | `stopped`, `starting`, `running`, `paused`, `suspending`, `stopping` or `failed` |
| `suspended` | a session saved to disk exists; the next `vm.start` resumes it |
| `width`, `height` | the size of the latest frame read through this server; `vm.status` reads a frame of a running VM when none is known |
| `error` | with `failed`: the engine's message |
| `leasedBy` | the owner of the lease, while one is active |
| `cloneOf` | on a linked clone: the name of its template |
| `ephemeral` | `true` while a session started with `discardChanges` runs; absent otherwise |

`vm.status` adds `tools` for a running or paused VM (it waits up to 2 s for
the guest tools) and `agentCaps` when they are connected.

## Starting

`vm.start` on a VM in any state except `stopped` and `failed` (`starting`,
`running`, `paused`, `suspending`, `stopping`) answers its state without doing
anything, except with `discardChanges: true`, which then
answers `VM '<vm>' is already running; stop it first to start a session that
discards changes`. `ephemeral` in the result says whether the running session
discards its changes.

A VM with a session saved to disk (`suspended: true` in its row) resumes that
session: the guest continues where it was saved, with its clock at the time of
the save. The server then connects to the guest tools for up to `waitTools`
seconds (default 30; below 0 counts as 0; with `waitTools: 0` it still tries
once to reach them) and, when they can run commands, sets the guest clock to
the host's. A guest without a clock recipe (a guest of kind `other`) is not
waited for: the result has `resumed: true`, `tools` as known at once and
`clockSynced: false`. The result carries `resumed: true`,
`tools` (whether they connected) and `clockSynced` (whether the clock was
set); with `clockSynced: false`, call `vm.set_environment` with `clock:
"host"` once the tools are connected. A start that boots the VM has none of
the three fields and does not wait for the guest tools.

`discardChanges` (a boolean, default `false`) starts a session whose disk
writes go to qcow2 overlays (`run/ephemeral-<disk>.qcow2` in the bundle) and
whose UEFI variable writes go to a copy (`run/ephemeral-efi-vars.fd`). When
the session ends, by `vm.stop`, a guest shutdown or an engine crash seen by
the server, these files are removed and the VM's disks are as they were before
the start; the next start empties `run/` in any case. Snapshot ops work during such a session and act on the overlay, so
its snapshots end with it. The session cannot be suspended to disk.

A start that is refused answers `start failed: <reason>`. The reasons the
server checks before it launches the engine:

| reason | when |
|---|---|
| `the configuration of '<vm>' at <path>/config.json cannot be read; restore or repair config.json before starting` | the bundle's `config.json` is missing or does not decode |
| `'<vm>' is a template with clones (<a>, <b>); delete the clones first or start a clone` | a linked clone of the VM exists (see [Linked clones](#linked-clones)) |
| `'<vm>' has a suspended session; resume it or discard the suspended state before starting a session that discards changes` | `discardChanges` on a VM with a session saved to disk |
| `the template of '<clone>' was not found at <path>; the clone cannot run without it` | a clone whose template bundle is gone or unreadable |
| `the VM at <path> is not the template '<clone>' was cloned from; the clone cannot run` | another VM is stored at the template's path |
| `the template '<template>' was started after '<clone>' was cloned from it, so the clone's disk no longer matches; delete the clone and clone again` | the template ran a session that keeps its changes after the clone was made |
| `'<vm>' has been cloned, so each start is recorded in <path>/config.json, and that file could not be saved; make the bundle folder writable and start it again` | a VM that was cloned before cannot save its `config.json` (the system's description follows on a second line) |

Other failures carry the engine's own output after `start failed: `.

## Linked clones

`vm.clone` creates a new VM named `newName` (surrounding whitespace is
removed) next to the stopped VM `name`, its template:

- Each disk of the clone is a qcow2 overlay backed by the template's disk
  file, which it references by absolute path. The clone stores only its own
  writes.
- The clone has a copy of the template's UEFI variables, the template's CPU,
  memory, display and shared folders, a new guest-tools token, a new MAC
  address and a guest-tools port that no VM in the directory uses. It has no
  CD-ROMs, USB passthrough or configured port forwards.
- Its row carries `cloneOf`.

Refusals of `vm.clone`:

```
'<vm>' is running; stop it before cloning it
'<vm>' has a suspended session; resume and shut it down, or discard the suspended state, before cloning it
'<vm>' is a clone of '<template>'; clone '<template>' instead
cannot clone a VM with a TPM
'<newName>' cannot be used as a VM name; choose a non-empty name without '/', ':' or ','
a VM named '<newName>' already exists; choose another name
qemu-img could not create the clone's disk (<message>); check the template's disk images and the free space, then clone again
```

**The template guard.** A clone reads every block it has not written from the
template's disk, so the template must not change while a clone exists. For as
long as a VM has a clone, `vm.start` of that VM is refused with the `is a
template with clones` sentence, whether the clone is stopped or running, and
also with `discardChanges`. The clones of a VM are the bundles in its
directory, or listed in its `clones.json`, whose configuration names it as
`cloneOf`.

**Stale clones.** When a VM is cloned for the first time, its `config.json`
receives a `diskID` and a `diskEpoch`, and every later cold start of that VM
that keeps its changes (not a `discardChanges` session, not the resume of a
suspended session) raises `diskEpoch` by one. A clone records both values and
the template's path. A clone that was not visible to the template guard (its
bundle was moved away, for example) and comes back after the template ran is
refused by `vm.start` with one of the three clone sentences under
[Starting](#starting); the way out is to delete it and clone again. Saving a
VM's configuration never lowers or removes these values.

`vm.delete` deletes the stopped clone `name`: its bundle directory with its
disks and its entry in the template's clone list. With the last clone gone the
template starts again. Refusals:

```
'<vm>' is not a clone; delete it in the Alcove app
'<vm>' is running; stop it before deleting it
```

`vm.delete` also drops the VM's lease, its runtime forwards and its cached
frame size. Both ops answer `no VM named '<vm>'; call vm.list` for an unknown
`name`, and `this control host cannot clone or delete VMs` on a host without
VM provisioning (the app and `alcovectl serve` both have it).

## Snapshots

A snapshot is an internal qcow2 snapshot of every disk of the VM plus the
memory and device state, stored in the first disk's image. The four ops need a
running or paused VM. A snapshot's memory state takes about as much disk space
as the guest's used memory; deleting a snapshot frees that space inside the
image for later writes, and the image file keeps its size.

- `vm.snapshot.list` reads the snapshots of the first disk: `name`, `date`
  (ISO 8601, UTC) and `vmStateBytes`, the size of the memory state.
- `vm.snapshot.create` saves the snapshot `snapshot`: a name of 1 to 128
  characters without a line break (`snapshot name must be 1 to 128 characters
  without a line break; choose another name`) that is not in use (`a snapshot
  named '<s>' already exists in '<vm>'; call vm.snapshot.delete first or
  choose another name`). The guest is stopped while the state is written.
- `vm.snapshot.restore` returns the VM to `snapshot`. A running guest is
  stopped for the load and runs again afterwards, also when the load fails; a
  paused VM stays paused. Everything since the snapshot is lost: disk contents,
  running programs, guest jobs started later. The server then drops its
  connection to the guest tools, connects again for up to `waitTools` seconds
  (default 30; it tries once even with 0) and, when the tools are connected and
  can run commands, sets the guest clock to the host's. `tools` says whether
  they connected, `clockSynced` whether the clock was set. With
  `clockSynced: false`, call `vm.set_environment` with `clock: "host"` once
  `vm.status` shows the tools. Runtime port forwards stay in place.
- `vm.snapshot.delete` deletes `snapshot`.
- `vm.snapshot.restore` and `vm.snapshot.delete` of a name that is not listed
  answer `no snapshot '<s>' in '<vm>'; call vm.snapshot.list`.
- A failure of the engine answers `snapshot create failed: <message>`,
  `snapshot restore failed: <message>` or `snapshot delete failed: <message>`
  with the engine's message, or `the engine closed the connection (<reason>);
  check vm.status` when the engine went away.

## Port forwards

A forward listens on `127.0.0.1:<hostPort>` on the Mac and connects to
`<guestPort>` in the guest (TCP, user-mode networking). `vm.forward.list`
shows three kinds:

| `kind` | what it is |
|---|---|
| `config` | the TCP forwards of the VM's configuration; they exist for the whole run |
| `agent` | the forward the guest tools use (guest port 7645) |
| `runtime` | forwards added with `vm.forward.add`, in the order they were added |

- `vm.forward.add` takes `guestPort` (1 to 65535) and `hostPort` (0 to 65535;
  0, `null` or absent lets the server pick a free port). A `hostPort` that a
  `config`, `agent` or `runtime` forward of the VM uses, or that the engine
  cannot listen on, answers `host port <n> is taken; pass hostPort: 0 to let
  Alcove choose`. Out-of-range values answer `guestPort must be between 1 and
  65535` / `hostPort must be between 1 and 65535`.
- `vm.forward.remove` removes the runtime forward on `hostPort` (1 to 65535).
  Any other port answers `no runtime forward on host port <n> in '<vm>'; call
  vm.forward.list (forwards from the VM configuration cannot be removed while
  it runs)`.
- When the engine reports that it no longer has the forward, `vm.forward.remove`
  drops it from the list and succeeds.
- Runtime forwards belong to the engine process they were added to. They are
  gone when the VM stops, and the server forgets them when the VM is started
  again, by this server or by anything else.
- A guest firewall decides whether the guest port answers: a forward to a port
  that Windows Firewall blocks connects on the Mac and then delivers nothing.
- The three ops need a running or paused VM.

## Network link

`vm.set_network` with `up: false` takes the link of the guest's network
adapter down (the guest sees an unplugged cable); `up: true` brings it back.
`up` must be a boolean; without it, or with another type, the op answers
`missing or invalid parameter 'up'`. The guest tools connect through the same adapter:

- While the link is down, an op that needs the guest tools waits for its
  reply and then answers `guest tools in '<vm>' did not answer <op> in time;
  check vm.status and retry`. `vm.status` keeps reporting `tools: true`,
  because the host side of the connection stays open. Jobs already started in
  the guest keep running.
- After `up: true`, the first op that needs the guest tools can answer `guest
  tools in '<vm>' disconnected during <op>; retry once the guest is back`; the
  server connects again on the next op, so retry it.

## Leases and read-only ops

A lease reserves a VM for one holder. An op that is not read-only and names
the VM in `name` is refused while a lease is active, unless it passes the
lease's token as `lease`:

```
VM '<vm>' is leased by <owner> for another <n> s; pass its lease token, wait, or ask the owner to release it
```

- `vm.lease.acquire` grants the lease when the VM has none: `owner` is free
  text shown to others (default `unknown`), `ttl` the duration in seconds
  (default 300; values below 1 count as 1, values above 3600 as 3600). The
  result holds the token `lease` and `expiresIn`, the seconds granted.
- With the holder's token as `lease`, `vm.lease.acquire` renews: the lease
  keeps its token and owner and runs for `ttl` seconds from now. Without the
  token, or with another one, it answers the refusal above.
- `vm.lease.release` with the token ends the lease. On a VM without a lease it
  does nothing; with a token that is not the holder's it answers `lease token
  does not match; only the holder can release '<vm>'`.
- A lease ends by itself when its time is up. Leases live in the server: a
  server restart ends them all, and `vm.delete` ends the lease of the VM it
  deletes.
- The token is a capability, not an identity: any connection that passes it
  acts as the holder. `vm.status` and `vm.list` show `leasedBy`.

The read-only ops, which ignore leases, are `hello`, `vm.list`, `vm.status`,
`vm.screenshot`, `vm.wait_idle`, `vm.wait_for`, `vm.find_text`,
`vm.clipboard.get`, `vm.exec.read`, `vm.exec.list`, `vm.process.list`,
`vm.fs.list`, `vm.fs.read`, `vm.pull_file`, `vm.snapshot.list`,
`vm.forward.list`, `vm.lease.acquire`, `vm.lease.release`, `vm.doctor` and
`vm.record.status`. Every other op is guarded, among them the power ops,
`vm.clone` (through its template's lease) and `vm.delete`. The action ops and
`vm.batch` are not read-only; a batch checks the lease once, for the whole
batch.

## Resolution

`vm.set_resolution` asks the guest tools to switch the guest's primary display
to `width` x `height` (320 to 7680 by 200 to 4320, otherwise `width must be
320...7680 and height 200...4320`). It then reads the frame every 500 ms for
up to 8 s, until its size changes or equals the request, and answers the size
of the last frame read. A guest that does not offer the mode leaves the size
as it was, and the result then shows the unchanged size. The op needs a running VM with connected
guest tools.

## Guest environment

`vm.set_environment` changes guest settings by running a script through the
guest tools (PowerShell on Windows, `sh` on Linux; each script may take 60 s).
It needs guest tools that run commands (`--allow-exec`). At least one setting
is required (`pass at least one of theme, timeZone, clock, locale,
keyboardLayouts, dpiScale`); a setting given as `null` counts as absent. All
values are checked before anything is applied; the settings are then applied
in the order of this table.

| setting | value | guests | `takesEffect` |
|---|---|---|---|
| `clock` | `"host"` (the host's time now) or an ISO 8601 time with an offset, e.g. `2026-10-13T09:30:00Z`, with or without fractional seconds | Windows, Linux | `now` |
| `timeZone` | a zone id of the guest OS: a Windows id such as `Korea Standard Time`, an IANA name such as `Asia/Seoul` on Linux; 1 to 64 characters from letters, digits, space and `_ - + / ( ) . :`, not starting with `-` | Windows, Linux | `now` |
| `locale` | a language tag such as `ko-KR`: letters, digits and `-`, 2 to 35 characters, not starting with `-`. Sets the regional format and adds the language to the user's language list | Windows | `app restart` |
| `keyboardLayouts` | a non-empty array of language tags; the user's input languages become exactly these, in this order | Windows | `now` |
| `theme` | `dark` or `light`, for apps and for the system | Windows | `now` |
| `dpiScale` | a whole percentage from 100 to 500; Windows is asked for the nearest of 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500, as a number of steps from the display's recommended scale, and redraws the desktop and open windows without a sign-out. See [Display scale](#display-scale) | Windows | `now` |

The result lists one row per requested setting: `setting`, `ok`, `detail` (what
the script printed, e.g. the new time or zone id; the script's error text when
`ok` is false) and `takesEffect` — `now` or `app restart` (programs started
afterwards see it). A setting
the guest OS has no script for is a row with `ok: false` and `detail` `not
supported on <os> guests`. The op itself succeeds when a row fails, so read
the rows.

### Display scale

The `dpiScale` row reports the scale Windows applied, read as the system DPI
by a process started after the change: `ok: true` with `detail` `scale: 125 %`
when that is the requested percentage. Windows offers only the scales that fit
the display's resolution (100 and 125 on a 1280x800 display, more on a larger
one) and applies the nearest offered one, and a percentage between two steps
becomes the nearest step. In both cases the row
has `ok: false` and a `detail` that names the applied scale and the nearest
offered ones, e.g. `scale: 125 % was applied, not 150 %; the largest scale the
guest offers at its resolution is 125 %; request it, or set a larger
resolution with vm.set_resolution first` or `scale: 125 % was applied, not
130 %; the nearest scales the guest offers are 125 % and 150 %; request one of
them`. The applied scale is then the guest's stored setting, so a later change
of resolution keeps it. A guest whose display reports no scale range gives
`ok: false` with `the guest did not report the scale range of its display;
sign in to the guest desktop and set dpiScale again`; when Windows refuses the
change, `Windows refused the display scale; sign in to the guest desktop and
set dpiScale again`.

Refusals for values: `theme must be 'dark' or 'light'`, `dpiScale must be
between 100 and 500`, `clock must be 'host' or an ISO 8601 time such as
2026-10-13T09:30:00Z`, `timeZone must be 1 to 64 characters: letters, digits,
space and _ - + / ( ) . :, not starting with '-'`, `locale must be a language
tag such as ko-KR (letters, digits and '-', 2 to 35 characters, not starting
with '-')`, `keyboardLayouts must be a non-empty list of language tags such as
en-US`, `keyboardLayouts entries must be language tags such as en-US (...)`.

## Doctor

`vm.doctor` reports measured facts about a VM as rows `{id, ok, detail}`; a
row that is not ok carries `hint`, the next step. It works on a stopped VM and
ignores leases. Rows come in this order and the list ends at the first row
that makes the later ones impossible:

| `id` | `detail` | not ok when | ends the list |
|---|---|---|---|
| `engine` | the engine binary the server runs VMs with, or `managed by the Alcove app` | never | |
| `host` | `app` or `headless` | never | |
| `state` | the VM's state | not `running` (hint `call vm.start`, or `call vm.resume` when paused) | when not running |
| `display` | `<W>x<H>` of the current frame | no frame can be read | |
| `tools` | `alcove-agent <version>` | the guest tools do not connect within 5 s | when not ok |
| `rpc` | `proto <n>` | below 2 | when `rpc` or `exec` is not ok |
| `exec` | `enabled` or `disabled` | the tools were started without `--allow-exec` | |
| `probe` | why the guest probe gave nothing | present only on failure: the guest OS has no probe script, the script failed or printed no JSON | always |
| `session` | `<user>, unlocked` / `<user>, locked` / `<user>, lock state not checked on this guest` | locked, or the guest reported no user | |
| `disk` | `<n> bytes free` on the system drive | below 2 GiB, or not reported | |
| `clock` | `skew <n> s` between guest and host | above 5 s (hint `vm.set_environment clock=host`), or no valid time reported | |
| `network` | `example.com resolves` / `does not resolve` | the name does not resolve in the guest | |
| `scale` | `<p> %` or `not checked on this guest` | never | |

`session` is `locked` on Windows while a `LogonUI` process exists. `scale` is
the system DPI a newly started DPI-aware process reads on Windows, as a
percentage of 96. A fact the guest cannot measure reads `not checked on this
guest` and counts as ok.

## Scripts

`script.run` replays a JSON script of control ops without a model. It runs in
the concurrent lane.

Parameters: `path` (script file on the host; use an absolute path, a relative
one resolves against the server's working directory), `name` (VM; overrides the
script's `vm`), `variables` (object of strings that override the script's
defaults), `snapshot` (restored before the first step) and `lease`. The VM
comes from `name` or the script's `vm`; with neither the op fails.

Leases: without `lease` the run holds a lease of its own (owner
`script:<file name>`, 600 s, renewed every 200 s), checks before each step that
it still holds it and releases it at the end, also after a failure. When the
run loses its lease it stops before the next step. If the final release fails,
`warning` says so and that the lease expires by itself within 600 s; when the
run's lease was lost during the last step, `warning` says that instead. A passed
`lease` must be a string and the VM's current token; otherwise the op fails with
`lease token is not the current lease of '<vm>' (expired, released or unknown);
acquire a new lease or omit lease`. A passed lease is used for every step and
is neither renewed nor released; the caller keeps it alive. It is checked
before every step: when it is no longer the VM's current token the run stops
before that step with `the lease on '<vm>' is no longer the one passed to
script.run (expired, released or taken over) before step N; renew the lease
and run the script again` (an error when N is 1, otherwise `passed: false`). A VM leased by someone
else is refused with the owner's name, whether the VM came from `name` or from
the script.

Script format version 1: `{"version": 1, "vm", "variables": {name: text},
"steps": [{"label", "op", "params", "expect", "timeout"}]}`. Unknown keys are
refused. `${name}` in any string of `params` and `expect` is replaced (a value
is not expanded again); `$${` stands for a literal `${`. `vm` and `label` are
not substituted. `params` never holds `name` or `lease`. A step may use any
control op except `vm.lease.*`, `vm.record.*`, `script.*`, `vm.clone` and
`vm.delete`. Each `expect` entry is a `vm.wait_for` condition, checked with the
condition parser of `vm.wait_for` (like the `conditions` of a `vm.wait_for`
step, and the `observe` options of the steps that take them) before any step
runs; problems are reported as `step N expectation M: …` or `step N condition
M: …`, counted from 1. Every expectation must hold: each is waited for
with its own `vm.wait_for`, for up to the step's `timeout` (default 10 s, 1 to
600) counted from the end of the op, and at least 1 s. A `vm.wait_for` step
fails when it matches nothing. The run stops at the first failing step.

Errors and results: everything that prevents step 1 from starting answers with
an error (`ok: false`): an unreadable, oversized (over 4 MiB) or malformed
script, an undefined variable, a condition that does not parse, no VM, a lease
refusal, a failed snapshot restore, a cancellation before step 1. Otherwise the
op answers with `{passed, stepsRun, steps, failedStep?, label?, error?, warning?,
seconds, failure?: {png, width, height}}`; `passed: false` means a step ran and
failed (or the run was cancelled or lost its lease before its last step
finished); `error` is present only then. A cancellation after every step
passed leaves `passed: true`. `warning` is present only when there is
something to report that did not change the outcome. Step numbers, condition
numbers and expectation numbers start at 1. `stepsRun` counts the steps that started, including the failed one.
`failure` is a screenshot taken after the failing step and is complete.

Each entry of `steps` is `{step, op, label?, seconds, ok, result?, error?}`.
`result` is a copy of the op's result in which a string under a key named `png`
becomes `<omitted: N bytes>` and any other string over 2048 characters is cut
to its first 2048 characters followed by `… (N more characters)`. Once the
encoded entries pass 256 KiB, later entries keep only `{step, op, label?, ok,
seconds}` (and `error` for the failing step). An entry whose encoded size
alone exceeds 64 KiB is replaced by that lean form plus `resultOmitted: "<N
bytes>"`.

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
VM 'Win' is leased by ci-agent for another 240 s; pass its lease token, wait, or ask the owner to release it
no snapshot 'clean' in 'Win'; call vm.snapshot.list
host port 8080 is taken; pass hostPort: 0 to let Alcove choose
start failed: 'Win' is a template with clones (Win clone); delete the clones first or start a clone
```

## Limits

- One process owns a VM directory. Two control hosts (the Alcove app and
  `alcovectl serve`, or two `alcovectl serve`) that manage the same directory
  are not supported: each keeps its own VM states, leases and forwards.
- The template guard and the stale-clone check read the bundles at the moment
  of a start. A clone that another process creates between the moment a
  template's `diskEpoch` is raised and the moment its engine takes over the
  disks is not detected.
- A linked clone references its template's disk files by absolute path: a
  template bundle that is moved or renamed on disk leaves its clones without
  their backing files.
