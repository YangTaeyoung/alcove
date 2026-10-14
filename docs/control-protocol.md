# Alcove control protocol (automation API)

Version 1. Lets automation on the Mac — the `alcove-mcp` server for Claude
Code and other agents, `alcovectl`, scripts — drive VMs: list and start them,
take screenshots, move the mouse, click, type, press keys, run shell commands
and background jobs in the guest, list and kill guest processes, exchange
clipboard text, copy, sync, read and write guest files, read the text on the
screen, list and act on windows, read and operate the UI elements of a
Windows guest, launch and deploy apps, read guest events, wait for
conditions, record what was done, read the guest's event log, collect crash
dumps, write a diagnostics bundle, take and restore snapshots, forward ports,
cut the guest's network link, lease a VM, change guest settings, diagnose a
VM, create linked clones and sessions that discard their changes, and capture
the guest's HTTP and HTTPS traffic with canned, delayed or dropped answers.

The same server runs inside the Alcove app (which owns the VMs while it is
running) and inside `alcovectl serve` (headless, when the app is not running).
Clients connect to the unix socket
`~/Library/Application Support/Alcove/control.sock`; a client that cannot
connect may start `alcovectl serve` itself.

Transport: newline-delimited JSON. Request `{"id": n, "op": "...", ...params}`;
response `{"id": n, "ok": true, ...result}` or `{"id": n, "ok": false, "error": "message"}`.
A request line is at most 8 MiB; a longer one closes the connection. A line
that cannot be read as JSON (broken syntax, or a `\u` escape of half a
surrogate pair) is answered with `the request line is not JSON that can be
read (broken syntax, or a \u escape of half a surrogate pair); send one JSON
object per line`. That reply carries the request's `id` when the line begins
as an object whose top-level key `"id"` holds a number or a string and
everything before that key is JSON syntax: UTF-8 strings with valid escapes (a `\u`
escape with four hex digits, half a surrogate pair included), numbers, `true`,
`false`, `null`, and objects and arrays of these nested at most 512 deep.
Otherwise its `id` is `null`.
Coordinates are guest pixels of the guest frame as it is when the op runs:
each pointer op reads the frame size once, so the ops follow a guest that
changed its resolution.

## Lanes

Each connection has two lanes.

- **Concurrent lane**: every op whose name starts with `vm.exec`,
  `vm.process.` or `vm.fs.`, and `vm.push_file`, `vm.pull_file`,
  `vm.sync_dir`, `vm.find_text`, `vm.window.list`, `vm.ui.tree`,
  `vm.ui.find`, `vm.ui.text`, `vm.app.launch`, `vm.deploy`,
  `vm.crash_dumps.pull`, `vm.collect_diagnostics`, `script.run`. Such a request starts as soon as it arrives and answers when
  it finishes, so several can be in flight and their replies arrive in any
  order. Match replies by `id`. Pipelined requests of this lane are unordered
  among themselves: two `vm.fs.write` requests to one file sent back to back
  may be applied in either order. A caller that needs an order sends the
  second request after the reply to the first.
- **Serial lane**: every other op (`hello`, `vm.list`, `vm.status`, power,
  screenshot, mouse, keyboard, clipboard, `vm.batch`, `vm.wait_idle`,
  `vm.wait_for`, snapshots, forwards, `vm.set_network`, leases,
  `vm.set_resolution`, `vm.set_environment`, `vm.doctor`, `vm.clone`,
  `vm.delete`, `vm.window.action`, `vm.ui.click`, `vm.ui.type`,
  `vm.ui.action`, `vm.events`, `vm.record.*`, `vm.event_log`,
  `vm.crash_dumps.enable`, `vm.crash_dumps.disable`, `vm.crash_dumps.list`,
  `vm.http.*`). These run one after another in the order they arrived, and
  their replies come in that order; a long `vm.wait_for` or `vm.batch` holds
  back the later requests of the serial lane of its connection.

The lanes do not wait for each other: a screenshot or a click is answered
while a `vm.exec` of the same connection is still running. Mouse and keyboard
ops, `vm.batch`, `vm.window.action`, `vm.ui.click`, `vm.ui.type` and
`vm.ui.action` for one VM run one at a time across all connections. Such an op
that is cancelled while it waits for its turn (its connection closed, or the
`script.run` or batch it belongs to was cancelled) sends nothing, and the VM's
lease is checked again when its turn comes. A click, drag, key press or typing
that is cancelled or fails while it holds a button or keys releases them
before it ends.

Closing a connection cancels every unfinished request of it in both lanes
and discards their replies: a serial request still queued behind another never
runs, and a running one stops at its next cancellation point (a `vm.wait_for`
at its next tick, a `vm.type` at its next key). Replies wait in a
per-connection outbox and are written as the client reads them, so a client
that stops reading holds back nobody else; a connection with more than 64 MiB
of unread replies, or one that reads none of its pending replies for 30 s, is
closed. A command that `vm.exec` already started in the guest keeps running until it
ends or reaches its `timeout`; jobs started with `vm.exec.start` are not
affected. The control socket pushes nothing to a client: a job's exit is seen
through `vm.exec.read`, `vm.exec.list` or the `job.exited` event of
`vm.events` (see [Guest events](#guest-events)).

## Operations

| `op` | Params | Result |
|---|---|---|
| `hello` | — | `{version: 1, host: "app"|"headless"}` |
| `vm.list` | — | `{vms: [{name, guestOS, state, suspended, width?, height?, error?, leasedBy?, cloneOf?, ephemeral?}]}` — see [VM rows](#vm-rows) |
| `vm.status` | `name` | the VM's row plus, while it is running or paused, `tools: bool` and, with tools, `agentCaps: [...]` |
| `vm.start` | `name`, `discardChanges?`, `waitTools?` | `{state, ephemeral}` after the guest is running; `{state, ephemeral, resumed, tools, clockSynced}` when it resumed a session saved to disk — see [Starting](#starting) |
| `vm.stop` | `name`, `force?` | `{state, captureEnded?, warning?}` after the engine exited (graceful ACPI first); see [Stopping a capture](#stopping-a-capture) for the capture fields |
| `vm.clone` | `name` (the template), `newName` | `{name}` — see [Linked clones](#linked-clones) |
| `vm.delete` | `name` (a clone) | `{}` — see [Linked clones](#linked-clones) |
| `vm.pause` / `vm.resume` | `name` | `{state}` |
| `vm.screenshot` | `name`, `region?`, `scale?`, `format?`, `quality?`, `maxWidth?`, `window?`, `marks?` | `{png | jpeg, mime, width, height, sentWidth, sentHeight, x, y, areaWidth, areaHeight, scale, window?, marks?, marksTruncated?}` — see [Screenshots](#screenshots) |
| `vm.mouse.move` | `name`, `x`, `y`, observe params | `{}` or `{observation}` |
| `vm.mouse.click` | `name`, `x`, `y`, `button?` ("left"/"right"/"middle"), `count?` (1 to 3), `hold?` ms (0 to 10000, default 60), observe params | `{}` or `{observation}` — moves, presses, releases |
| `vm.mouse.drag` | `name`, `fromX`, `fromY`, `toX`, `toY`, `button?`, observe params | `{}` or `{observation}` |
| `vm.mouse.scroll` | `name`, `x`, `y`, `dx?`, `dy?` (notches, +down, -1000 to 1000), observe params | `{}` or `{observation}` |
| `vm.mouse.down` / `vm.mouse.up` | `name`, `button?` ("left" default), `x?` and `y?` together, observe params | `{}` or `{observation}` — presses or releases the button and leaves it so; with `x`/`y` the pointer moves there first |
| `vm.key.press` | `name`, `keys` (string like "ctrl+alt+delete", "enter", "win+r"), `hold?` ms (0 to 10000, default 0), observe params | `{}` or `{observation}` — presses modifiers then the key, releases in reverse |
| `vm.key.down` / `vm.key.up` | `name`, `key`, observe params | `{}` or `{observation}` |
| `vm.type` | `name`, `text`, `delay?` ms per key (0 to 1000, default 12), observe params | `{}` or `{observation}` — US-layout text typing; text with a character outside the layout is put into the guest clipboard and pasted with `ctrl+v` when tools are connected. The paste is sent once the guest reports that text as its clipboard content (the guest reports the first 700,000 bytes of UTF-8 of a longer text, and those are compared), otherwise the op answers `the guest clipboard did not take the text, so nothing was typed; call vm.type again` (`vm.ui.type` names itself). Guest tools without a clipboard answer `the guest tools in '<vm>' have no clipboard (a Linux guest needs wl-copy or xclip in its session), so text outside the US layout cannot be typed; install one and restart the guest tools, or type US-layout text only`; text whose message to the guest tools would reach 1 MiB answers `the text is too large for the guest clipboard (<n> bytes of UTF-8; one message to the guest tools holds less than 1 MiB); split it over several vm.type calls`. The guest clipboard holds the text afterwards |
| `vm.batch` | `name`, `steps`, observe params | `{completed, results, failedStep?, error?, observation?}` — see [Batches](#batches) |
| `vm.find_text` | `name`, `query?`, `regex?`, `region?`, `languages?` | `{matches, lines}` — see [Finding text](#finding-text) |
| `vm.wait_for` | `name`, `conditions`, `timeout?`, observe params | `{matched, waited, type?, detail?, problems?, observation?}` — see [Waiting for conditions](#waiting-for-conditions) |
| `vm.exec` | `name`, `command` or `argv`, `timeout?` s, `cwd?`, `env?`, `stdin?`, `shell?` | `{code, output, stdout, stderr, timedOut, truncated}` — runs a command through the guest agent and waits for it; `output` is `stdout` followed by `stderr` |
| `vm.exec.start` | `name`, `command` or `argv`, `cwd?`, `env?`, `shell?` | `{job, pid}` — starts a background job and returns at once. `stdin` is refused (`vm.exec.start takes no stdin; start the job, then send the text with vm.exec.write (eof: true closes the job's stdin)`), and so is `timeout` (`vm.exec.start takes no timeout; a job runs until it exits or vm.exec.kill ends it`) |
| `vm.exec.read` | `name`, `job`, `outOffset?`, `errOffset?`, `max?` | `{state, code?, pid, out, err, outNext, errNext, dropped}` — output from the given byte offsets |
| `vm.exec.write` | `name`, `job`, `data`, `eof?` | `{}` — writes to the job's stdin; `eof` closes it |
| `vm.exec.kill` | `name`, `job` | `{state}` — kills the job's process tree |
| `vm.exec.list` | `name` | `{jobs: [{job, pid, state, code?, cmd, started}]}` |
| `vm.process.list` | `name`, `filter?` | `{processes: [{pid, ppid, name, path, command, memoryKB}]}` — `filter` is a case-insensitive substring of the process name |
| `vm.process.kill` | `name`, `pid?` or `processName?`, `tree?` | `{killed}` — `tree` also kills child processes |
| `vm.clipboard.get` / `vm.clipboard.set` | `name` / `name`, `text` | `{text}` / `{}` |
| `vm.push_file` | `name`, `path` (host), `dest?` ("desktop"/"downloads"; any other value answers `dest must be 'desktop' or 'downloads'; pass guestPath for another folder`) or `guestPath?`, `overwrite?` | `{guestPath}`; with `guestPath` also `{bytes, sha256}` |
| `vm.pull_file` | `name`, `guestPath`, `path` (host) | `{path, bytes, sha256}` |
| `vm.sync_dir` | `name`, `path` (host directory), `guestPath`, `delete?` | `{sent: [..], skipped, deleted: [..], bytes}` |
| `vm.fs.list` | `name`, `path`, `recursive?` | `{entries: [{name, dir, size, mtime}], truncated}` |
| `vm.fs.read` | `name`, `path`, `offset?`, `length?` (≤ 262144), `tail?` (lines) | `{text, size, eof}` |
| `vm.fs.write` | `name`, `path`, `text`, `append?` | `{size}` |
| `vm.fs.delete` | `name`, `path`, `recursive?` | `{deleted}` |
| `vm.wait_idle` | `name`, `seconds?` (stable period, 0 to 600, default 2), `timeout?` (1 to 600, default 30) | `{idle: bool}` — `true` when fewer than 0.5% of the frame's 32x32 tiles changed between samples 250 ms apart for the whole period, `false` at the timeout |
| `vm.snapshot.list` | `name` | `{snapshots: [{name, date, vmStateBytes}]}` — see [Snapshots](#snapshots) |
| `vm.snapshot.create` | `name`, `snapshot` | `{snapshot}` |
| `vm.snapshot.restore` | `name`, `snapshot`, `waitTools?` s (default 30) | `{snapshot, tools: bool, clockSynced: bool, captureEnded?, staleProxyCleared?}` |
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
| `vm.window.list` | `name` | `{windows: [window]}` — see [Windows and UI elements](#windows-and-ui-elements) |
| `vm.window.action` | `name`, `window`, `action`, `x?`, `y?`, `width?`, `height?`, observe params | `{window, closed?, observation?}` |
| `vm.ui.tree` | `name`, `window?`, `root?`, `depth?`, `max?`, `filter?` | `{tree, count, truncated, window}` |
| `vm.ui.find` | `name`, `ref` or `selector`, `limit?` | `{nodes, text, truncated?}` |
| `vm.ui.text` | `name`, `ref` or `selector`, `mode?`, `offset?`, `length?` | `{text, total, source}` |
| `vm.ui.click` | `name`, `ref` or `selector`, `button?`, `count?`, observe params | `{x, y, node, observation?}` — a mouse click on the element |
| `vm.ui.type` | `name`, `ref` or `selector`, `text`, `clear?`, `submit?`, observe params | `{node, observation?}` — a click on the element, then keys |
| `vm.ui.action` | `name`, `ref` or `selector`, `action`, `value?`, observe params | `{node, pending?, unresponsive?, gone?, observation?}` — a UI Automation pattern call |
| `vm.app.launch` | `name`, `path`, `args?`, `cwd?`, `env?`, `waitWindow?` s (default 15) | `{pid, window?, windowTimedOut?}` — see [Launching and deploying apps](#launching-and-deploying-apps) |
| `vm.deploy` | `name`, `path` (host), `guestDir?`, `install?`, `launch?`, `killRunning?`, `waitWindow?` s (default 20) | `{guestDir, sent, skipped, bytes, installCode?, pid?, window?, windowTimedOut?}` |
| `vm.events` | `name`, `since?` | `{events, next, first}` — see [Guest events](#guest-events) |
| `vm.record.start` | `name`, `fps?` (1 to 30, default 5), `video?` (default true), `maxSeconds?` (1 to 86400, default 900), `dir?` (host) | `{dir}` — see [Recordings](#recordings) |
| `vm.record.stop` | `name` | `{dir, trace, frames, seconds, ops, writeErrors, lastWriteError?, video?, videoSeconds?, droppedFrames?}` |
| `vm.record.status` | `name` | `{recording: true, dir, seconds, ops, writeErrors, lastWriteError?, videoError?}` or `{recording: false, dir?}` |
| `vm.event_log` | `name`, `log?` (default `Application`), `level?`, `provider?`, `sinceMinutes?` (default 60), `contains?`, `max?` (default 50) | `{entries: [{time, id, level, provider, message}], truncated?}` — see [Event log](#event-log) |
| `vm.crash_dumps.enable` | `name`, `exe`, `full?` (default false) | `{folder, createdKey}` — see [Crash dumps](#crash-dumps) |
| `vm.crash_dumps.disable` | `name`, `exe` | `{}` |
| `vm.crash_dumps.list` | `name` | `{dumps: [{file, exe, bytes, time}]}` |
| `vm.crash_dumps.pull` | `name`, `file`, `path` (host) | `{path, bytes, sha256}` |
| `vm.collect_diagnostics` | `name`, `dir?` (host), `sinceMinutes?` (default 30), `logFiles?`, `processName?` | `{dir, files, summary}` — see [Diagnostics bundle](#diagnostics-bundle) |
| `vm.http.start` | `name`, `hosts?`, `secrets?`, `bodies?`, `systemProxy?` (default true) | `{proxy, env, caInstalled, systemProxySet, guestCAPath?, warning?}` — see [HTTP capture](#http-capture) |
| `vm.http.stop` | `name` | `{exchanges, warning?}`; without a capture `{exchanges: 0, staleCleared: true, warning?}` |
| `vm.http.requests` | `name`, `since?`, `host?`, `path?`, `status?`, `limit?` (default 50, at most 500) | `{exchanges, next, pending}` |
| `vm.http.request` | `name`, `exchange`, `part` (`request` or `response`), `offset?`, `length?` (default and at most 200000) | `{headers, body, total, bodyTruncated, base64?, encoding?, bodyDropped?, trailers?}` |
| `vm.http.clear` | `name` | `{}` — discards the captured exchanges |
| `vm.http.rule.add` | `name`, `match` (`host?`, `path?`, `method?`), `action` (`status?`, `headers?`, `body?`, `delayMs?`, `drop?`, `times?`) | `{rule}` |
| `vm.http.rule.list` | `name` | `{rules: [{id, match, action, hits, remaining?}]}` |
| `vm.http.rule.remove` / `vm.http.rule.clear` | `name`, `rule` / `name` | `{}` |
| `script.run` | `path` (host), `name?`, `variables?`, `snapshot?`, `lease?`, `maxWidth?` | `{passed, stepsRun, steps, failedStep?, label?, error?, warning?, seconds, failure?}` — see [Scripts](#scripts) |
| `script.save` | `dir` or `trace` (host), `path` (host, `.json`), `name?`, `from?`, `to?`, `overwrite?` | `{path, steps, skipped, warnings?}` — see [Saving a script from a recording](#saving-a-script-from-a-recording) |

The reply to an op that is not read-only and names a VM also carries
`eventSeq` (see [Guest events](#guest-events)).

Key names: letters, digits, `enter return tab space esc escape backspace delete
insert home end pageup pagedown up down left right f1..f20 capslock
printscreen`, modifiers `ctrl control alt option shift win cmd meta super`,
punctuation by character (`-` `=` `[` `]` `;` `'` `,` `.` `/` `` ` `` `\`).
Combos use `+`. Names are case-insensitive.

Pointer coordinates (`x`, `y`, `fromX`, `fromY`, `toX`, `toY`) are integers
from -65536 to 65536; a point outside the frame moves the pointer to the
nearest edge. An integer parameter outside its range is refused before any
input is sent, with `<param> must be an integer between <low> and <high>`.

## Screenshots

`vm.screenshot` reads the current guest frame and returns it, optionally
cropped and shrunk. Every op that reads the screen (`vm.screenshot`,
`vm.find_text`, `vm.wait_idle`, `vm.wait_for`, the observations and the
recordings) copies the frame from the display's shared framebuffer; while no
surface is mapped it asks the engine for a `screendump` instead.
`ALCOVE_FRAME_SOURCE=screendump` in the environment of the server process
makes it use the `screendump` always.

- `region` `{x, y, w, h}` (guest pixels; `x` and `y` from -65536 to 65536, `w`
  and `h` from 1 to 65536, otherwise `region needs integer x, y, w, h with x
  and y between -65536 and 65536 and w and h between 1 and 65536`) crops to the
  part inside the frame; a region partly outside is cut to the frame, one fully
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
- `window` (Windows guests with the `ui` capability) crops to the rectangle
  of one window: a window id, `foreground`, or a part of a title (ids and
  titles compare without regard to case; of several windows with that title
  part, the one in the foreground, else the top-most). The result has
  `window`, the window object, and `x`, `y`, `areaWidth`, `areaHeight` are the
  window's rectangle cut to the frame. `window` together with `region`
  answers `pass region or window, not both; region is a rectangle of the
  frame, window crops to a window's rectangle`; no match answers `no window
  matches '<text>'; call vm.window.list`; a minimized window, or one outside
  the frame, answers `window '<title>' is minimized or has no area on the
  <W>x<H> frame; call vm.window.action restore first`. The image shows what
  the screen shows in that rectangle, including a window that covers it.
- `marks: true` draws a numbered outline on the elements of the window (of
  `window`, else of the foreground window) that a user acts on, and returns
  them as `marks`: `[{n, ref, role, name, x, y, w, h}]` with the rectangle in
  guest pixels of the frame and `ref` usable with the `vm.ui.*` ops. Marked
  are the elements of the `interactive` tree (at most 300 are read) with the
  role `Button`, `CheckBox`, `ComboBox`, `Edit`, `HeaderItem`, `Hyperlink`,
  `ListItem`, `MenuItem`, `RadioButton`, `Slider`, `Spinner`, `SplitButton`,
  `TabItem`, `TreeItem`, `DataItem` or `Document`, a rectangle that is not
  empty and reaches into the image's area, and no `offscreen` flag; the first
  100 in tree order, numbered from 1. `marksTruncated: true` says that more
  such elements exist. An outline is 2 pixels wide and the number sits in a
  filled tag above the rectangle's top-left corner (inside it when there is
  no room above); with `scale` or `maxWidth` both are drawn larger so that
  they keep their size in the sent image, the outline between 1 and 8 pixels
  and the digits between 9 and 32 pixels of the frame. The six outline
  colours repeat with the number. A screenshot with `window` and `marks`
  makes two helper requests, one with either makes one (see [Windows and UI
  elements](#windows-and-ui-elements)).

## Observing the screen after input

Every action op (`vm.mouse.move`, `.click`, `.drag`, `.scroll`, `.down`, `.up`,
`vm.key.press`, `.down`, `.up`, `vm.type`), `vm.batch`, `vm.wait_for`,
`vm.window.action`, `vm.ui.click`, `vm.ui.type` and `vm.ui.action` accept
three parameters:

- `observe`: `none` (default), `summary`, `diff`, `image` or `ui`. Any other
  value answers `observe must be one of none, summary, diff, image, ui`.
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
| `foreground` | on a guest with the `ui` capability: the title of the window in the foreground; absent when there is none |
| `focused` | the element with the keyboard focus as `Role "name"`; `Pane ""`, the desktop, when no element of a window has it (a button that disabled itself after a click, for example) |
| `events` | the guest events since the VM's previous observation, oldest first, as lines (see below) |
| `tree` | with `ui`: the tree text of the foreground window as `vm.ui.tree` returns it, at most 150 elements, followed by the line `… more elements; call vm.ui.tree to read the whole window` when elements were left out |
| `uiError` | why `foreground`, `focused` or `tree` are missing |

The last five fields are the UI facts of a Windows guest whose connected
guest tools have the `ui` capability; every level except `none` carries
them, and no image is sent with `ui`. An observation at another guest has
none of them and no `uiError`, except at level `ui`, where `uiError` says why:
`UI Automation is only available on Windows guests with current guest tools;
update alcove-agent in '<vm>'`, `the guest tools are not connected yet; the
next observation will carry the UI facts` (a connection is being made) or
`the guest tools are not connected; UI facts need alcove-agent running in the
guest`.

- `foreground` and `focused` come from one helper request; when the focused
  element lies outside the window in the foreground, a second one reads the
  window list for the title. `tree` is one more request.
- The requests take their turn at the helper like any other (see [Windows and
  UI elements](#windows-and-ui-elements)) and share one budget counted from
  the end of the settling: 3 s, or 20 s at level `ui`. What has not arrived by
  then is left out and `uiError` is `the UI helper is busy with another
  request; call vm.ui.tree when you need the tree`. An action's reply is
  therefore delayed by a busy helper for at most that budget, and the input
  is sent in any case: with a search of 7 s running in the helper, a
  `vm.mouse.click` with `observe: summary` returned after 3.8 s to 4.2 s with
  this `uiError` and the click had reached the app.
- A failed request gives `uiError` `the foreground window and focused element
  could not be read: <reason>`, `the foreground window could not be read:
  <reason>` or `the UI tree could not be read: <reason>`; the screen fields
  stay. At level `ui`, a `uiError` from the request for `foreground` and
  `focused` or from the window list (late or failed) also leaves out `tree`,
  which is not asked for then.
- `events` lists the newest 20 events as `<name> "<window title>"` (the
  process name for a window without a title), `process.exited <file> code
  <n>`, `job.exited <job> code <n>` or `events.dropped (<count>)`, preceded
  by `<n> earlier events; call vm.events` when there were more. The first
  observation of a VM starts at the event baseline (see [Guest
  events](#guest-events)); `vm.start`, `vm.stop` and `vm.snapshot.restore`
  move the position past the events received by then.

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
10000). Any other `op` is refused. Before anything runs the server checks
that every step is an object with an allowed `op`, that no step names another
VM and that every `sleep` has its `ms`; a refusal names the step as
`step <i>: ...` and no step runs. The parameters of an op are checked when its
step runs: a step with a missing or wrong parameter (an unknown key name, a
`vm.type` without `text`, a `vm.wait_for` with an unknown condition type) is a
failing step as described below. Step indices count from 0 everywhere: in
refusals, in `results` and in `failedStep`.

Each step runs with `observe` `none`; `observe`, `settleMs` and
`settleTimeoutMs` on the batch itself ask for one observation after the last
step (compared with the frame before the first step), with the same
`observation` / `observationError` fields as an action op.

The result is `{completed, results, observation?}`: `completed` steps ran
and `results[i]` is the result of step `i` (`{}` for input and `sleep`,
`{idle}` for `vm.wait_idle`, the `vm.wait_for` result for `vm.wait_for`).
The first step that fails ends the batch; the reply is still a success and adds
`failedStep` (its index) and `error` (its message). Steps after it do not
run; steps before it keep their effect, except that a batch that stops at a
failed step or is cancelled releases the buttons and keys that its
`vm.mouse.down` and `vm.key.down` steps pressed and no later step released. A
batch whose steps all ran leaves them as its steps left them.

## Finding text

`vm.find_text` reads the text on the screen with the macOS Vision framework.

- `query` (default empty): a case-insensitive substring; with `regex: true`
  a case-insensitive regular expression (an invalid one answers
  `'<query>' is not a valid regular expression`, and one without a query
  `regex: true needs the expression in query; pass a query or leave regex out
  to list every line`). An empty query returns every
  recognized line.
- `region` is as for `vm.screenshot`.
- `languages` is a non-empty array of recognition languages. Any other value
  answers
  `languages must be an array of language codes such as ["en-US","ko-KR"]`;
  an unsupported language is refused before any recognition and answers
  `language '<l>' is not supported; supported: ...`.
- Without `languages` the area is recognized twice, with `["ko-KR", "en-US"]`
  and with `["en-US"]`, and the two results are merged line by line: a line
  that contains Hangul is read by the Korean recognizer, every other line by
  the Latin recognizer. Two lines count as the same line when their rectangles
  intersect horizontally and overlap vertically by at least half the height of
  the less tall one. A line only the Korean recognizer found is kept; a line
  only the Latin recognizer found is left out. A line of the Latin recognizer
  that lies on more than one line of the Korean recognizer is left out too,
  and each of those lines keeps the Korean recognizer's text and rectangle, so
  no rectangle spans two lines. In a line that mixes both scripts the Latin
  letters are the Korean recognizer's reading. A symbol outside ASCII can come
  back as a similar ASCII character: in a line without Hangul, `✓ Done` was
  read as `v Done` and `±0.5 µm` as `+0.5 um` (system font at 15 and 20
  pixels).
- With `languages` the area is recognized once with exactly that list. Pass
  `["en-US"]` when the screen has no Hangul you need: it is one recognition
  instead of two, and it reads the Latin part of a line that also holds Hangul
  with the Latin recognizer (the Hangul part comes back as other characters).
  Pass another list for other scripts, such as `["ja-JP", "en-US"]`. In the
  measurements of `docs/superpowers/plans/2026-10-13-at3-results.md` a list
  with `ko-KR` first read Hangul well and small Latin text with mistakes
  (`Alcove OCR check` in 11-point Consolas at 100 % scale came back as
  `Alcove OR check`), and a list with `en-US` first read Latin text well and
  no Hangul.
- The result is `{matches, lines}`. `matches` lists the matching lines in
  reading order (top to bottom, then left to right) as `{text, x, y, w, h, cx,
  cy, confidence}`: the rectangle in guest pixels of the whole frame, its centre
  (`cx`, `cy`, the point to click) and a confidence from 0 to 1 with two
  decimals. Every rectangle lies inside the searched area. `lines` is the
  number of lines recognized in the area before the filter. Areas narrower
  than 400 pixels are enlarged twofold for recognition.
- Recognitions run one at a time for the whole server, in the order they were
  asked for, `vm.find_text` and the text conditions of `vm.wait_for` alike. A
  request for the frame and `languages` of a recognition that is running or
  waiting shares it. A request that is cancelled or, in a wait, runs out of
  time before its turn is taken out of the line and never recognized.
- `vm.find_text` waits for its turn for at most 60 s from the moment it was
  asked, one limit for its first recognition and the retry after a failed one.
  Then it leaves the line and answers `the text recognition is busy (another
  reading has been running for <n> s); retry in a few seconds`, `<n>` being the
  time the recognition that is running has taken so far. A `vm.find_text` that
  shared a recognition that was already running when it was asked gets the
  same answer when that recognition has not ended within the 60 s. A
  `vm.find_text` whose own recognition has begun is answered when that
  recognition ends.
- When the server starts it reads a small image with both recognizers in the
  background, which loads them; a recognizer that fails to read the image does
  not keep the other from being loaded. Loading takes a fraction of a second,
  and tens of seconds the first time a server binary runs from a path where it
  has not read text before. It runs at utility priority, and at the priority
  of a request for as long as a request waits behind it. A `vm.find_text` that
  arrives meanwhile waits behind it; a text condition of `vm.wait_for` waits
  behind it too, and is listed in `problems` when the loading outlasts its
  timeout (see [Waiting for conditions](#waiting-for-conditions)).
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
| `ui_exists` | `ref`, or selector fields | the element exists | the node |
| `ui_gone` | `ref`, or selector fields | no such element exists | none |
| `ui_enabled` | `ref`, or selector fields | the element exists and has no `disabled` flag | the node |
| `ui_text_stable` | `ref`, or selector fields; `quietMs?` (0 to 600000, default 1500) | the element's text and its full length stayed the same for `quietMs` | the full length of the text |
| `window_title` | exactly one of `contains` and `regex` | a top-level window has a title that contains `contains` (case-insensitive) or matches the regular expression | `{id, title, foreground}` |
| `event` | `event`, `titleContains?`, `since?` | a guest event named `event` arrived, of a window whose title contains `titleContains` (case-insensitive) when given | the event as `vm.events` returns it |

The six conditions of the last block need a Windows guest with the `ui`
capability (`event` needs connected guest tools only). The selector fields
are those of [Windows and UI elements](#windows-and-ui-elements) and stand in
the condition itself: `{"type": "ui_exists", "window": "Save As", "role":
"Button", "name": "Save"}`. Refusals before the wait starts: `condition <i>:
<type> needs 'ref' or at least one of role, name, nameContains,
automationId`, `condition <i>: <type> takes 'ref' or selector fields, not
both`, `condition <i>: 'quietMs' must be an integer between 0 and 600000`,
`condition <i>: window_title needs exactly one of 'contains' and 'regex'`,
`condition <i>: event needs a non-empty string 'event'`, `condition <i>:
'since' must be an integer of 0 or more; pass the eventSeq of an earlier
reply`.

- An element condition asks the helper once per evaluation (`ui.find` with a
  limit of 1, `ui.rect` for a ref, `ui.text`, `win.list`); the next request of
  a condition is made 500 ms after the answer to the previous one arrived,
  and a condition has one request in flight at most.
- `ui_gone` holds on an empty search result, on the guest's `element <ref> no
  longer exists` for that ref, and when the selector's window does not exist.
  `ui_exists` and `ui_enabled` in a window that does not exist keep waiting
  and are no problem.
- `ui_text_stable` ends the wait, like `job exited`, with `matched: -1`,
  `type: "ui_text_stable"` and the guest's sentence as `detail` when the
  element disappears: for a `ref` as soon as the ref no longer exists, for
  selector fields after the element was read once in this wait. Before that
  first read a selector that matches nothing, or whose window does not exist,
  is a failed evaluation (the page may still be loading) and is listed in
  `problems`. A password field ends the wait with the password sentence as an
  error.
- `window_title` looks at every listed window, not only the one in front.
- `event` without `since` looks at the events after the VM's event baseline,
  with `since` at the events with a higher `seq`; a `since` above the newest
  `seq` counts as 0. See [Guest events](#guest-events). A window event of a
  hung app's `(Not Responding)` twin also matches a `titleContains` of the
  app's title.
- A helper that cannot start, or is shut down, ends the wait with the guest's
  sentence as an error.

`languages` of `text_visible` and `text_gone` is as for `vm.find_text`; an
unsupported language is refused before the wait starts
(`condition <i>: language '<l>' is not supported; supported: ...`).

`process_exited` with a `pid` that does not exist holds at once, because the
condition is "no such process". `screen_idle` compares each sample with the
previous sample, not with the frame at the start. The conditions that read the
screen take the screen at the start of the wait as their reference
(`region_changed`) or first sample (`screen_idle`).

Conditions are evaluated in a loop with a 250 ms tick; each condition has its
own period: 250 ms for `screen_idle` and `region_changed`, 700 ms for
`text_visible` and `text_gone`, 500 ms for the conditions that call the guest
tools, one tick for `event`. Conditions that read the screen share one frame per tick. A text
condition does not hold the other conditions: its recognition runs beside the
loop and is looked at on every tick, like a guest call, and the other
conditions are judged on every tick meanwhile. Text conditions with the same
`region` and `languages` share one recognition, and no new one is asked for
while it runs. While the pixels of a text condition's area do not change, the
area is not recognized again: the lines of its last recognition are used. A
condition that needs guest tools
(`process_*`, `file_exists`, `port_listening`, `log_matches`,
`job_output_matches`) answers `guest tools are not connected in '<vm>'; ...`
when they are not connected after a wait of up to 25 s. If several conditions hold on the same tick, the
one with the lowest index wins.

The result is `{matched, waited, type?, detail?, problems?, observation?}`:

- `matched` is the index of the condition that held, or `-1`. `waited` is the
  elapsed time in seconds with one decimal. `type` is its `type`; `detail` is
  as in the table. Running out of time is a success with `matched: -1`.
  `waited` can exceed `timeout` by up to one second plus one tick: at the
  timeout the wait gives the text recognitions that have not finished one
  second, all of them together, whatever their number. Without a text
  condition the bound is `timeout` plus one tick: an element condition that
  never held returned after 3.0 s with `timeout: 3`.
- `job exited`: when a `job_output_matches` condition sees the job exited and
  all its output read without a match, it can no longer become true and the wait
  ends at once with `matched: -1`, `type: "job_output_matches"` and
  `detail: "job exited"`.
- A failing evaluation (a frame, recognition or guest call that errors or times
  out) does not end the wait: the condition is tried again at its next period.
  `problems` appears only when `matched` is `-1` and lists
  `{condition, type, error, failures}` for each condition whose latest
  evaluations failed, `failures` being the number in a row. A text recognition
  that has not finished one second after the timeout is given up: the wait
  ends, leaves the line of recognitions, and each condition that waited for it
  is listed, without `failures`, with `the text recognition did not finish
  within the timeout; call vm.wait_for again` when the recognition was
  running, or with `the text recognition was waiting behind other recognitions
  and did not start; call vm.wait_for again` when its turn had not come. A
  recognition that finishes within that second is still judged. A port check
  whose guest command fails or prints nothing on stdout is listed with `the
  port check failed: the guest command exited with code <n>: <line>`, `<line>`
  being the first line of what the command wrote to stderr, or to stdout when
  stderr is empty, cut at 200 characters; on a Linux guest without `ss` that
  line is `ss is not installed in the guest; install the iproute2 package`.
  When both are empty the sentence is `the port check failed: the guest
  command exited with code <n> and printed nothing; run vm.doctor to check the
  guest shell`. A condition whose request the guest has left unanswered for
  500 ms or longer when the wait ends is listed, without `failures`, with
  `the UI helper has not answered <op> for <n> s` (`<op>` is the agent op,
  such as `ui.find`), `the UI helper was busy with other requests` (the
  request did not get its turn), or, for the conditions that call the guest
  tools without the helper, `the guest agent has not answered <op> for <n>
  s`. Errors that make the
  condition meaningless end the wait with an error instead: a guest-tools
  connection that is lost or too old, a `region` outside the frame
  (`condition <i>: region is outside the <W>x<H> frame`), an unknown job, a
  `port_listening` on a guest OS that is not supported, and a screen that
  cannot be read when the wait begins (`the screen could not be read when
  vm.wait_for began: <reason>; call vm.screenshot to check the display, then
  vm.wait_for again`).
- `observe` at a level above `none` adds `observation` or `observationError`
  as for an action op, comparing the final screen with the screen at the start
  of the wait. When the wait ends while one of its own helper requests has
  been unanswered for 500 ms or longer, the observation asks the helper
  nothing and carries the busy `uiError` at once.

## Windows and UI elements

`vm.window.*` and `vm.ui.*` read and operate the windows of a Windows guest
through UI Automation. They need connected guest tools with the `ui`
capability (`vm.status` → `agentCaps` contains `ui`). Without it they answer
`UI Automation is only available on Windows guests with current guest tools;
update alcove-agent in '<vm>'`; guest tools older than the request/response
layer answer `guest tools in '<vm>' are too old for <op>; update alcove-agent
in the guest`. The ops map onto the agent's `win.*` and `ui.*` operations in
[`agent-protocol.md`](agent-protocol.md), which has the exact rules for
windows, nodes, roles and every action. A sentence of the agent is passed on
unchanged, so it can name an agent operation: `ui.tree`, `ui.find`,
`win.list`, `win.action` and `proc.kill` are `vm.ui.tree`, `vm.ui.find`,
`vm.window.list`, `vm.window.action` and `vm.process.kill` here.

**One request at a time.** One helper process in the guest serves every
window and element request, one after another. The server therefore sends one
such request per VM at a time, in the order they were asked for, across all
connections. The requests of observations, of `vm.wait_for`, of a screenshot
with `window` or `marks` and of a recording take their turn in the same line.

- A `vm.window.*` or `vm.ui.*` op waits up to 60 s for its turn and then
  answers `the UI helper is busy with other requests; retry`.
- A request that was sent is waited for until the agent answers, for at most
  215 s (the agent may spend 60 s in its own queue, 120 s on a helper start
  and 30 s on the request); then the op answers `guest tools in '<vm>' did
  not answer <op> in time; check vm.status and retry`.
- The turn ends when the agent answered, also when the caller has stopped
  waiting before (an observation whose budget ran out, a wait that ended, a
  closed connection). A slow request therefore holds up the others: a
  `vm.ui.find` without a match in the Services console (about 1,650 elements)
  takes 7 s to 8 s on the test guest.
- A request of a closed connection that still waits for its turn is not sent.
- The agent's own sentences about the helper reach the caller unchanged, among
  them `UI helper did not answer '<op>' within <n> s; it was restarted` (every
  ref is forgotten), `UI helper exited; retry` and the start failures listed
  in `agent-protocol.md`.

**Windows.** `vm.window.list` returns the top-level windows, top-most first,
as window objects:

```
{"id":"0x501fa","title":"Alcove Fixture","pid":9520,"process":"alcove-fixture.exe","class":"AlcoveFixtureWindow",
 "x":85,"y":78,"w":706,"h":513,"state":"normal","foreground":true,"responding":true,"modal":false}
```

`x`, `y`, `w`, `h` are guest pixels of the visible frame; `state` is `normal`,
`minimized` (then `0,0 0x0`) or `maximized`; `responding` turns false about
5 s after a window stopped handling messages. A window is named by its `id`,
by `foreground`, or by a part of its title (case-insensitive, the top-most
match). While a notification toast has the foreground no listed window has
`foreground: true`, because the toast is not listed (seen with the OneDrive
backup toast after a boot); `vm.ui.tree` without `window` reads it.

`vm.window.action` takes `window` and `action`: `focus`, `minimize`,
`maximize`, `restore`, `close`, `move` (`x`, `y`) or `resize` (`width`,
`height`, both above 0). The result is `{window}`, the window after the action
(`null` when it is gone), and for `close` also `closed`. Refusals before the
guest is asked: `action must be one of focus, minimize, maximize, restore,
close, move, resize`, `move needs integer 'x' and 'y' in guest pixels`,
`resize needs integer 'width' and 'height' above 0 in guest pixels`. Windows
decides whether a window may come to the foreground: `focus` can answer
`window <id> "<title>" did not come to the foreground; click its title bar
through the display` (seen while the toast above had the foreground); a
click on the title bar with `vm.mouse.click` brings it forward when the
title bar is not covered.

**Selecting an element.** An element op takes exactly one of

- `ref`: a ref such as `e12` from `vm.ui.tree` or `vm.ui.find`. It names the
  element while it exists and the helper process lives; afterwards the guest
  answers `element <ref> no longer exists; call ui.tree again`. A new helper
  process (after an agent restart, or after the agent replaced a helper that
  did not answer) knows none of the earlier refs.
- `selector`: an object with `window` (default `foreground`), `role`
  (case-insensitive, e.g. `Button`, `Edit`, `Document`), `name` (exact),
  `nameContains` (case-insensitive), `automationId` (exact) and `index`
  (0-based among the matches in tree order; without it the first match). At
  least one of `role`, `name`, `nameContains`, `automationId` is required.

A field given as `null` counts as absent. Refusals: `pass ref or selector`,
`pass ref or selector, not both`, `ref must be an element ref such as e12;
take one from vm.ui.tree or vm.ui.find`, `selector must be an object with
window, role, name, nameContains, automationId or index`, `selector has no
field '<k>'; valid fields: window, role, name, nameContains, automationId,
index`, `selector field '<k>' must be a string`, `selector field 'index' must
be an integer of 0 or more`, `selector needs at least one of role, name,
nameContains, automationId`. A selector that matches nothing answers `no
element matches {"window":"0xd0368","role":"Button","name":"Nope"}; call
ui.tree to see what exists` (`vm.ui.find` returns an empty list instead); a
`window` that does not exist answers `no window has "<text>" in its title;
call win.list to see the open windows` or `window <id> no longer exists; call
win.list again`.

**`vm.ui.tree`** reads the elements of `window` (default `foreground`) or
below the element `root` (a ref). `depth` is the number of levels (0 or more,
default 12), `max` the most elements (1 to 2000, default 300) and `filter`
`interactive` (default: elements with a name, a value, keyboard focus or an
action, and the control types people act on) or `all`. Refusals: `depth must
be 0 or more`, `max must be between 1 and 2000`, `filter must be
'interactive' or 'all'`. The result is `{tree, count, truncated, window}`:
`window` is the window object, `count` the number of lines, `truncated` says
that elements were left out, and `tree` is text with one line per element,
indented by two spaces per level:

```
[e11] Window "Alcove Fixture" (78,78 720x520)
  [e13] Edit "Message" (186,125 484x26) focused value="안녕 \"fixture\""
  [e14] Button "Send" (678,124 96x28) disabled
  [e16] Edit "" (186,159 484x26) password
```

A line is `[ref] Role "name" (x,y WxH)`, then the flags (`focused`,
`disabled`, `offscreen`, `selected`, `checked`, `expanded`, `collapsed`,
`password`), then `value="..."` when the element has a value. The rectangle
is in guest pixels of the frame; an element without one has no `(x,y WxH)`
part. Names and values are cut at 200 characters and end with `…` then;
`\`, `"`, line break, carriage return and tab are written as `\\`, `\"`,
`\n`, `\r`, `\t` and other control characters as `\u{hex}`, so one element is
always one line. The automation id is not in the text; `vm.ui.find` returns
it. The fixture window has 25 lines, the Notepad window 36, an Edge window
with a small page 27.

**`vm.ui.find`** returns the elements a selector matches: `{nodes, text}`,
`nodes` being the node objects (`ref`, `role`, `name`, `aid` when the element
has an automation id, `value` when it has one, `x`, `y`, `w`, `h`, `flags`,
`depth` 0) and `text` the same elements as tree lines. `limit` is the most
matches (1 or more, default 20; a value above 2000 counts as 2000; otherwise
`limit must be 1 or more`). With
`ref` it returns that one element as it is now. When the search ran out of
time after some matches, the result has `truncated: true` and `text` ends
with a line that says so.

**`vm.ui.text`** returns `{text, total, source}` for one element: `mode`
`auto` (default) reads the text pattern, then the value, then the names of
the elements below, then the name; `pattern` and `descendants` read one
source. `offset` (0 or more) and `length` (1 to 200000, the default) select a
part; `total` is the whole length and `source` where the text came from
(`text`, `value`, `descendants`, `name`). Line ends are `\n`. Refusals: `mode
must be one of auto, pattern, descendants`, `offset must be 0 or more`,
`length must be between 1 and 200000`.

**`vm.ui.click`** asks the guest for the element's clickable point (the
element is scrolled into view first when it can be) and sends a real mouse
click there, like `vm.mouse.click` with the same `button` and `count`. The
result is `{x, y, node}`: the point and the element. An element whose centre
cannot be clicked answers `element <ref> has no clickable point: <reason>; or
act on it with vm.ui.action`, with the guest's reason, such as `window
0x501fa "Alcove Fixture" covers the centre of the element; focus the
element's window with win.action`; without a reason from the guest it
answers `element <ref> has no clickable point (off screen or covered); use
vm.ui.action or scroll it into view`. A window that an app or `vm.app.launch`
just opened is often behind another one; `vm.window.action` with `focus`
comes first then. Two clicks on one point within the guest's double-click
time (500 ms by default) are a double click to the guest.

**`vm.ui.type`** clicks the element in the same way, waits 120 ms and types
`text` with real keys as `vm.type` does (text outside the US layout goes
through the guest clipboard and `ctrl+v`, and replaces what the clipboard
held). With `clear: true` it first selects what the element holds: on an
element whose role is `Edit` or `Document` it presses `ctrl+a`, `ctrl+home`
and `ctrl+shift+end`, so the typed text replaces the content also in controls
that ignore `ctrl+a` (a classic Win32 edit control does); on an element of
any other role (a grid cell, a list, a drop-down) it presses `ctrl+a` alone.
With `clear` and an empty `text` it presses `backspace` after them. `submit: true` presses `enter` at the end. `text` is
required and may be empty. The result is `{node}`, the element as it was
before the typing.

**`vm.ui.action`** acts on the element through a UI Automation pattern
without the mouse: `action` is `invoke`, `toggle`, `expand`, `collapse`,
`select`, `set_value` (with a string `value`), `focus` or `scroll_into_view`;
it also works on elements that are covered or off screen. The result is
`{node}` plus one of `pending: true` (the action is still running in the app,
for example because it opened a modal dialog), `unresponsive: true` (the
window stopped handling messages) or `gone: true` (the element no longer
exists) when the guest reports it; `node` is then the element as it was
before. Refusals: `action must be one of invoke, toggle, expand, collapse,
select, set_value, focus, scroll_into_view`, `set_value needs a string
'value'; pass the new text`.

`vm.window.action`, `vm.ui.click`, `vm.ui.type` and `vm.ui.action` take the
VM's input gate like the mouse and keyboard ops, and accept the observe
parameters.

**Password fields.** An element with the `password` flag has an empty `name`
and no `value` in every result, and `vm.ui.text` answers `the element is a
password field; its text is not read; it cannot be read through UI
Automation`. A selector still finds a labelled password field by `name`.
Text typed into such a field is in no result of these ops. Text outside the US
layout that `vm.ui.type` pastes into it stays in the guest clipboard, where
`vm.clipboard.get` and other programs in the guest read it; put other text
there with `vm.clipboard.set` after the typing.

**Elevated and hung windows.** The helper runs with the agent's elevated
token (high integrity) and reads windows of elevated processes: an app the
agent started is elevated itself. A window of a higher integrity level than
the agent's was not present on the test guest. The ops addressed to a window
that does not handle messages answer `window <id> "<title>" is not
responding; wait and retry, or end its process with proc.kill when win.list
still shows responding false after 10 s`.

## Launching and deploying apps

**`vm.app.launch`** starts the program `path` in the guest (a full path, or a
name on the search path or registered under `App Paths`, such as
`msedge.exe`) with `args` (array of strings), `cwd` and `env` (object of
strings), and waits up to `waitWindow` seconds (0 to 300, default 15; 0 does
not wait) for the window it opens. It needs guest tools that run commands and
runs in the concurrent lane. The result is `{pid}` and, when a window was
waited for, either `window` (a window object) or `windowTimedOut: true`.

- The program runs with the agent's elevated token and with the null device
  as standard input and output.
- While the VM has an HTTP capture, the program's environment also holds the
  capture's proxy variables (see [Starting a capture](#starting-a-capture)); the program of
  `vm.deploy`'s `launch` gets them the same way, its installer does not.
- `pid` is the process that was started. `window.pid` can be another process:
  Notepad and Edge hand over to a child or to a process that already runs
  (an Edge with a profile folder of its own is started by a launcher that
  exits with code 0 at once).
- `window.title` is the title at the moment the window was found. Edge first
  shows `Untitled - …` and Notepad `Notepad` before the document's name
  appears; wait for the title with a `window_title` condition.
- A window with an empty rectangle that is not minimized is not taken (the
  hidden `OLEChannelWnd` of `mmc.exe`); without the `ui` capability no window
  is waited for.
- The new window is not brought to the foreground.
- Refusals: `missing or invalid parameter 'path'` (also for `args`, `cwd`,
  `env` of the wrong shape), `waitWindow must be between 0 and 300 seconds`,
  `cannot start '<path>': <system error>; check the path with vm.fs.list`.

**`vm.deploy`** copies the host file or directory `path` into the guest
folder `guestDir`, optionally runs an installer, and starts a program. It
runs in the concurrent lane; a second `vm.deploy` to the same VM waits until
the first has finished. The steps, in order:

1. Parameters and host files are checked without asking the guest. `path` is
   absolute (`pass an absolute host path`) and exists (`'<path>' does not
   exist on the host; check the path`). `killRunning` is a boolean (default
   `true`), `waitWindow` as for `vm.app.launch` with a default of 20.
   `install` is `{kind: "msi" | "exe", file, args?}` and `launch` is `{exe,
   args?, env?, cwd?}`; `install.file` and `launch.exe` are paths inside
   `guestDir` (no `.` or `..` segment: `launch.exe must stay inside guestDir;
   pass an absolute path to start something else`) or absolute guest paths.
   A host directory that cannot be read, and on a Windows guest two host
   files that differ only by case (`'<a>' and '<b>' differ only by case and
   cannot both exist in a Windows guest folder`), are refused here.
2. The guest folder. Without `guestDir` a Windows guest gets
   `C:\alcove-apps\<name>`, `<name>` being the directory's name or the file's
   name without its extension; other guests need `guestDir` (`pass guestDir;
   the default C:\alcove-apps\<name> only fits Windows guests`). See the
   rules below.
3. With `killRunning`, every guest process whose executable lies below
   `guestDir` is killed with its child processes, and the op waits up to 5 s
   until none is left (`<name> (pid <n>) under '<dir>' is still running after
   vm.deploy tried to stop it; stop it with vm.process.kill or pass another
   guestDir`). Processes elsewhere are left alone. The guest agent and the
   processes that started it are never killed; when one of them runs from
   `guestDir` nothing is killed and the op answers `the guest agent or a
   process that started it (<name>, pid <n>) runs from '<dir>'; pass another
   guestDir`. When the agent's own process is not in the process list,
   nothing is killed and the op answers `vm.deploy could not find the guest
   agent's own process, so it stopped nothing under '<dir>'; stop the running
   copies with vm.process.kill, or pass killRunning: false`.
4. The marker file `.alcove-deploy` is written into `guestDir` when it is not
   there. It holds one line of text and is never deleted or replaced by a
   deploy.
5. The copy. A directory is copied like `vm.sync_dir` with `delete: true`:
   files whose size or SHA-256 differs are sent, guest files without a host
   counterpart are deleted, the marker stays. A file is written to
   `guestDir\<file name>`. `sent` lists what was sent as relative paths with
   `/`, `skipped` counts the unchanged files, `bytes` the bytes sent.
6. `install`: `msiexec.exe /i <file> /qn /norestart` followed by `args` for
   `msi`, the file followed by `args` for `exe`, with `guestDir` as working
   directory and 900 s to finish. Exit codes 0 and 3010 are a success and are
   returned as `installCode`; anything else answers `installer '<file>'
   exited with code <n>: <output>; fix the installer or its arguments and
   call vm.deploy again`, a timeout `installer '<file>' did not finish within
   900 s and was stopped; run it with vm.exec.start to see where it waits`.
7. `launch`: as `vm.app.launch` with `guestDir` as the default `cwd`; the
   result gains `pid` and `window` or `windowTimedOut`. A failure here
   answers `the files were copied to <guestDir>, but starting <exe> failed:
   <reason>`.

The result is `{guestDir, sent, skipped, bytes, installCode?, pid?, window?,
windowTimedOut?}`. A second deploy of an unchanged directory has `sent: []`
and still stops and starts the app.

Rules for `guestDir`, checked before any file is written:

| refused | sentence |
|---|---|
| a path that is not absolute, has a `.` or `..` segment, or is a filesystem root | `guestDir '<dir>' is not an absolute path; pass a full path such as <example>`, `… has a '.' or '..' segment; pass the folder's full path such as <example>`, `… is a filesystem root; pass a folder below it such as <example>` |
| Windows: `C:\Windows` and everything below, a `Program Files` folder itself, `C:\ProgramData` itself, `C:\ProgramData\Alcove` and everything below it, `C:\Users`, a profile folder, a profile's `Desktop`, `Documents`, `Downloads` and anything in its `AppData`. Other guests: `/usr`, `/etc`, `/bin`, `/sbin`, `/lib*`, `/var`, `/boot`, `/home`, `/home/<user>`, `/root`, `/opt` themselves | `guestDir '<dir>' is a system or profile folder; pass a folder of its own such as <example>` (`… a system or home folder …` on other guests) |
| `C:\alcove-apps` itself, in any spelling | `guestDir '<dir>' holds every deployed app; pass a folder below it such as <example>` |
| Windows: a device path (`\\?\`, `\\.\`) | `device paths such as \\?\ cannot be used; pass a drive or share path` |
| Windows: the administrative share of a drive on any server (`\\host\C$\…`) | `administrative shares such as \\host\C$ cannot be used; pass the drive path` |
| Windows: a segment Windows cannot use as a folder name (`<>:"|?*`, a control character, a trailing dot or space, a device name such as `NUL` or `COM1`) | `guestDir '<dir>' has the segment '<s>', which Windows cannot use as a folder name; pass a plain folder path such as <example>` |
| Windows: a segment with `~` followed by a digit | `guestDir '<dir>' has the short name '<s>'; pass the long path` |
| a guest folder that is a link (a junction or a symbolic link) | `'<dir>' is a link in the guest; pass the folder it points to` |
| a guest path that is a file | `'<dir>' is a file in the guest; pass a folder as guestDir` |
| a folder that holds entries, lies outside `C:\alcove-apps` and has no marker | `'<dir>' already holds files that Alcove did not deploy; choose an empty or new folder, or one under C:\alcove-apps` |
| a marker path that is a folder or a link | `'<dir>\.alcove-deploy' is not a plain file; remove it or deploy to another folder` |
| a link, or a file, in the guest where the host directory has a folder | `'<path>' in the guest is a link; remove it or deploy to another folder` (`… is not a folder; …` for a file) |

`<example>` is `C:\alcove-apps\<name>` on a Windows guest and `/opt/<name>`
on others. A folder that does
not exist, an empty folder, a folder below `C:\alcove-apps` and a folder with
the marker are accepted. A link in a parent of `guestDir` is not looked for.
The refusal for a link below the folder comes after the processes were
stopped and the marker was written; nothing is written through the link.
Further refusals: a host file or folder named `.alcove-deploy` (`a file named
.alcove-deploy cannot be deployed, vm.deploy keeps its own file under that
name; rename the file`), a host name that cannot be the default folder name
(`pass guestDir; '<name>' cannot be used as a folder name`, or `… has the form
of a Windows short name and cannot be used as a folder name`), and on a
Windows guest a segment of `install.file` or `launch.exe` that Windows cannot
use (`'<s>' in launch.exe cannot be used as a file or folder name on
Windows`).

## Guest events

The guest tools report what happens in the guest, and the server keeps the
newest 500 events of each VM, numbered from 1 in the order they arrived
(`seq`). The numbers keep counting when old events are dropped, and the
events stay when the VM stops or the tools reconnect; a new server process
starts at 1 again. An event whose fields take more than 64 KiB of JSON has
every string longer than 4096 bytes of UTF-8 cut to that length, and the
object that held it gets `<field>Cut: true` (for example `titleCut` in
`window`); an event still larger than 64 KiB keeps only
`payloadOmitted: <bytes>`.

| `name` | fields | sent when |
|---|---|---|
| `window.opened` | `window` | a titled window appeared |
| `dialog.opened` | `window` | in addition to `window.opened`, for a modal window or a dialog |
| `window.closed` | `window` (as last seen) | a listed window is gone |
| `window.title` | `window` | a window's title changed (at most one per window per second) |
| `window.foreground` | `window` | another window came to the foreground |
| `process.exited` | `pid`, `code`, `path` | a process started by `vm.app.launch` or the `launch` of `vm.deploy` ended; a process killed by `vm.process.kill` has code 1 |
| `job.exited` | `job`, `code` | a job of `vm.exec.start` ended |
| `events.dropped` | `count` | the agent could not deliver `count` events on its connection |

**`vm.events`** returns `{events, next, first}`: the kept events with `seq`
above `since` (default 0), oldest first, each as `{seq, time, name, ...}` with
`time` the host's arrival time (ISO 8601 with milliseconds); `next`, the
`seq` of the newest event (0 when there is none), to pass as the next
`since`; and `first`, the `seq` of the oldest event still kept. When `first`
is above `since + 1`, the events in between are gone. A `since` above `next`
(a number from an earlier server process) counts as 0. `since` is an integer
of 0 or more (`since must be an integer of 0 or more; pass the next value of
an earlier vm.events reply`). The op is read-only, works in any state of the
VM and reads without consuming: two clients that pass the same `since` get
the same events.

Window events come from the helper of [Windows and UI
elements](#windows-and-ui-elements), which compares the windows every 300 ms
while it runs. The server starts it when it connects to guest tools with the
`ui` capability, so a client gets window events without calling a window or
element op first: after a restart of the agent, a `vm.app.launch` with
`waitWindow: 0` was followed by its `window.opened`. The windows that are
open when a helper starts are not announced, and what happens while no
helper runs is not reported.

**`eventSeq`.** The reply to every op that is not read-only and names a VM
(all except `script.run` and `script.save`) carries `eventSeq`, the `seq` of
the newest event when the op began; `vm.stop` and `vm.snapshot.restore`
report the newest `seq` after the stop or the restore instead. An event
caused by the op has a higher `seq`. Pass it as `since` to `vm.events` or to
an `event` condition of `vm.wait_for` to look at exactly the events after
that op.

**The baseline.** An `event` condition without `since` looks at the events
after the VM's baseline: the newest `seq` when the latest op began that can
cause window or process events. These ops are the mouse and keyboard ops,
`vm.batch` and each of its input steps, `vm.window.action`, `vm.ui.click`,
`vm.ui.type`, `vm.ui.action`, `vm.app.launch`, `vm.deploy`, `vm.exec`,
`vm.exec.start`, `vm.exec.write`, `vm.exec.kill`, `vm.process.kill`,
`vm.start`, `vm.stop` and `vm.snapshot.restore`. Other ops, such as
`vm.fs.write`, leave it where it is. The baseline is one per VM for all
connections, so with several clients, or with an op between the action and
the wait, pass `since`. Without any such op since the server started, only
events that arrive during the wait count. `vm.start`, `vm.stop` and
`vm.snapshot.restore` also move the position from which observations list
events: events of an earlier session are in `vm.events` only.

## VM rows

`vm.list` and `vm.status` describe a VM with the same fields:

| field | meaning |
|---|---|
| `name`, `guestOS` | the VM's name and `windows`, `linux` or `other` |
| `state` | `stopped`, `starting`, `running`, `paused`, `suspending`, `stopping` or `failed` |
| `suspended` | a session saved to disk exists; the next `vm.start` resumes it |
| `width`, `height` | `vm.status` of a running or paused VM: the size of the guest frame at this moment. `vm.list`: the size this server read last, absent when it has read none since the VM stopped |
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
| `'<vm>' is running in another Alcove host (<process name> pid <ppid>); stop the VM there or quit that host, then start it here` | the engine that holds the VM's `run/qemu.pid` lock is the child of another live process (the Alcove app or another `alcovectl serve`); an engine whose host has exited (its parent is launchd) or that this server started is stopped before the start instead |
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
  address and a guest-tools port (17000–17999) that no VM in the directory
  uses as its guest-tools port or as the host port of a TCP port forward. It
  has no CD-ROMs, USB passthrough or configured port forwards.
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
every guest-tools port from 17000 to 17999 is used by a VM in <folder>; delete a VM there or move it to another folder, then clone again
```

**The template guard.** A clone reads every block it has not written from the
template's disk, so the template must not change while a clone exists. For as
long as a VM has a clone, `vm.start` of that VM is refused with the `is a
template with clones` sentence, whether the clone is stopped or running, and
also with `discardChanges`. The clones of a VM are the bundles in its
directory, or listed in its `clones.json`, whose configuration names it as
`cloneOf`, and the bundles listed in its `clones.json` whose `config.json`
exists but cannot be read.

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
  Once the guest is stopped for the load, a restore whose client disconnects
  or whose request is cancelled still runs to its end, up to the 600 s limit
  of the load, and a guest that was running runs again. A second restore, a
  `vm.snapshot.create` or a `vm.snapshot.delete` of the same VM waits until
  the restore has ended. A `vm.stop` during the load stops the VM, and the
  restore fails: it answers `snapshot restore failed: the VM is not running;
  check vm.status`, or `snapshot restore failed: the engine closed the
  connection (<reason>); check vm.status` when the engine quits before the
  load ends (a forced stop, or a graceful stop whose grace period ends first).
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
`vm.forward.list`, `vm.lease.acquire`, `vm.lease.release`, `vm.doctor`,
`vm.record.status`, `vm.window.list`, `vm.ui.tree`, `vm.ui.find`,
`vm.ui.text`, `vm.events`, `vm.event_log`, `vm.crash_dumps.list`,
`vm.crash_dumps.pull`, `vm.collect_diagnostics`, `vm.http.requests`,
`vm.http.request`, `vm.http.rule.list` and `script.save`. Every other op is guarded, among them the power ops,
`vm.window.action`, `vm.ui.click`, `vm.ui.type`, `vm.ui.action`,
`vm.app.launch`, `vm.deploy`,
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
| `proxy` | the guest's system proxy held against the VM's HTTP capture, see [Doctor row](#doctor-row) | something of an earlier capture is left in the guest, the system proxy points at another port than the capture's, or the guest printed no proxy settings | |

`session` is `locked` on Windows while a `LogonUI` process exists. `scale` is
the system DPI a newly started DPI-aware process reads on Windows, as a
percentage of 96. A fact the guest cannot measure reads `not checked on this
guest` and counts as ok.

## Recordings

`vm.record.start` begins a recording of one VM: from then on every op that
names the VM in `name` (other than `vm.record.*`) is written to a trace, and,
unless `video` is false, the screen is written to a video. A VM has at most
one recording; a second start answers `'<vm>' is already recording to <dir>;
call vm.record.stop first`.

- `dir` is an absolute host path (`dir must be an absolute path`). Without it
  the recording goes to `~/Library/Application Support/Alcove/Recordings/<vm>-<yyyyMMdd-HHmmss>`
  (a `/` in the VM name becomes `-`). A directory that already holds a
  `trace.jsonl` is refused: `'<dir>' already holds a recording; choose another
  directory`.
- The directory holds `trace.jsonl`, `frames/` and `video.mp4`.
- The recording ends by itself after `maxSeconds`, after a `vm.stop` of its VM
  succeeded, when an op finds its VM not running, and after 20 trace lines in
  a row could not be written. Its summary then waits for the next
  `vm.record.stop`, which returns it once.
- `vm.record.stop` ends the recording and answers its summary: `dir`, `trace`
  (the path of `trace.jsonl`), `frames` (frame files written), `seconds`,
  `ops` (trace lines written), `writeErrors` and `lastWriteError` (frames,
  lines or video that could not be written), and, when the video was written,
  `video` (its path), `videoSeconds` and `droppedFrames`. Without a recording
  it answers `'<vm>' is not recording`; while a start is still creating the
  directory, `'<vm>' is still starting its recording; call vm.record.stop
  again in a moment`.
- `vm.record.status` answers `recording: true` with `dir`, `seconds`, `ops`,
  `writeErrors`, `lastWriteError` and, once the video writer failed,
  `videoError`; otherwise `recording: false` and the `dir` of the VM's latest
  recording, if it had one.

**Trace.** `trace.jsonl` holds one JSON object per line, written with one
write call after the op answered, so the file holds whole lines also when the
server ends abruptly:

| field | value |
|---|---|
| `seq` | 1, 2, … in the order the lines were written |
| `time` | ISO 8601 with milliseconds: when the op began |
| `ms` | milliseconds from the start of the recording to `time` |
| `op` | the op name |
| `params` | the request without `id` and `op` |
| `ok` | whether the op succeeded |
| `result` / `error` | the reply's fields, or its error sentence |
| `durationMs` | how long the op took |
| `before`, `after` | `frames/<seq>-before.jpg` and `frames/<seq>-after.jpg`, paths relative to the directory |
| `target` | the element the op was aimed at, asked of the UI helper before the op ran: `{window?, role, name, automationId?, rect?, password?, byAutomationId?, byName?}` |
| `script` | for an op that `script.run` made: `step`, `expect`, `lease`, `snapshot` or `failure` |

`params`, `result`, `error` and `target` never hold `lease`; image payloads
(`png`, `jpeg`) read `<image omitted>`; a string longer than 2000 characters
is cut to 2000 followed by `…`, and `<key>Truncated: true` is added next to
it. Values in `env` whose names contain `KEY`, `TOKEN`, `SECRET` or
`PASSWORD` (any case) read `<masked>`. Text typed into a password element
(`vm.type`, `vm.ui.type`, `vm.ui.action` with `value`, and text keys of
`vm.key.*` aimed at such an element) reads `<masked>`; the values of a
script's secret variables are replaced the same way.

Frames are half-size JPEG files of quality 0.6, taken right before and right
after the input ops (`vm.mouse.*`, `vm.key.*`, `vm.type`, `vm.batch`,
`vm.ui.click`, `vm.ui.type`, `vm.ui.action`, `vm.window.action`),
`vm.app.launch` and `vm.deploy`. A failed op keeps its after-frame. `target`
is asked for `vm.mouse.click` and `vm.mouse.drag` (the press point), for
`vm.ui.click`, `vm.ui.type` and `vm.ui.action` given a `ref` alone, and for
`vm.type` and text keys (the focused element); it is left out when the
helper is busy or does not answer at once.

**Video.** `video.mp4` is H.264 in an MP4 file. Its size is the first frame's,
rounded down to even numbers and scaled so that the longer side is at most
1920; a frame of another size is drawn into it aspect-fit on black. The
screen is read `fps` times a second; a frame equal to the previous one is
written again only after 2 s. The frame read when the recording ends closes
the video: the video lasts until that moment and shows the last frame
sampled before it. The file is written in movie fragments of one second, so a
copy taken while the recording runs plays up to its last whole fragment; a
finished file is an ordinary MP4. When the video cannot be written the
recording continues without it, `vm.record.status` shows `videoError` at
once, and the summary has no `video` and carries the reason in
`lastWriteError` (`the video could not be written: …`, or `no frame could be
recorded for the video` when no frame could be read); a file the failed
writer left that still plays is kept in the directory. Measured on Windows
11 at 1280x800 and `fps` 5: 0.83 MB for 6 s and 35 MB for 192 s of a
changing screen, `vm.record.start` and `vm.record.stop` each answered within
0.05 s.

## Event log

`vm.event_log` reads the guest's log through the guest tools (needs
`--allow-exec`): the Windows event log with PowerShell, the journal with
`journalctl -o json` on Linux. Entries come newest first by `time`, at most
`max` of them (1 to 500, default 50), from the last `sinceMinutes` minutes
(1 to 5256000, default 60) of the guest's clock.

- `log` (Windows only; ignored on Linux) is a log name of 1 to 255
  characters from letters, digits, space and `_ - . /`, not starting with
  `-`: `Application`, `System`, `Security`,
  `Microsoft-Windows-PowerShell/Operational`.
- `level` is `critical`, `error`, `warning` or `info` and selects that level
  and every more severe one: Windows levels 1, 1–2, 1–3, and every level for
  `info`; journal priorities 0–2, 0–3, 0–4 and 0–6. Entries are labelled
  `critical` (Windows 1), `error` (2), `warning` (3) and `info` (everything
  else, also the level 0 of Security audit entries).
- `provider` is the provider's exact name in any case, without wildcards (on
  Linux the syslog identifier); a provider no entry has gives an empty list.
- `contains` keeps the entries whose message holds the text, in any case. It
  is searched in every entry of the time window, which is the slow part of a
  large log.
- `provider` and `contains` are at most 1000 characters and hold no NUL.
- `id` is the event id (on Linux the process id); `message` is cut at 2000
  UTF-16 units, one less where the cut would split a surrogate pair. `time`
  is ISO 8601 in UTC from the guest's clock.
- `truncated: true` says that more entries matched than the output holds: the
  guest prints at most 150000 bytes of entries, and the newest ones are kept.

The read has 60 s in the guest. Sentences:

| sentence | when |
|---|---|
| `the guest has no event log named '<log>'; list the logs with Get-WinEvent -ListLog *` | the log does not exist |
| `guest tools may not read the event log '<log>'; check that alcove-agent runs elevated` | the agent's user may not open the log |
| `could not read the event log '<log>': <reason>; check that alcove-agent runs elevated, or read the log with vm.exec` | the read was denied |
| `could not read the event log '<log>': <reason>; read the log with vm.exec to see the full error` | any other read failure, e.g. an analytic or debug log, which can only be read oldest first |
| `the guest took more than 60 s to read the event log; narrow it with level, provider or a smaller sinceMinutes` | the read ran out of time |
| `the guest did not finish reading the event log within 60 s; contains is searched in every entry of the time window, so pass a smaller sinceMinutes, a level or a provider` | the same with `contains` |
| `journalctl is not installed in the guest; read the logs with vm.exec instead` | Linux without `journalctl` |
| `journalctl in the guest is too old for these filters; read the logs with vm.exec instead` | Linux, an option was refused |

Measured on Windows 11 (an Application log of a few thousand entries): about
1.0 s for a read with or without `level` and `provider`, 1.5 s for a
`contains` without a match over a day, 1.2 s for 500 entries. Windows refuses
to write entries from a source whose name holds `&`, `<` or `>`; such a
`provider` gives an empty list. An entry written with an empty description
reads as a few characters that change from read to read (Windows formats it
so).

## Crash dumps

The crash dump ops use Windows Error Reporting's local dumps and exist for
Windows guests only (`crash dumps are only collected on Windows guests`).
They need guest tools that run commands, elevated.

- `vm.crash_dumps.enable` makes Windows write a dump of every crash of the
  image `exe` (a file name ending in `.exe`, no folder, no character a Windows
  file name cannot hold, not a device name such as `CON`) into
  `C:\alcove-dumps`: mini dumps, or full dumps with `full: true`. It creates
  the folder, grants the Users group modify rights on it (so a crashing
  program of any user can write there; the grant stays after `disable`), and
  writes `DumpFolder`, `DumpCount` 5 and `DumpType` under
  `HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\<exe>`
  in the 64-bit registry view, which serves ARM64, x64 and x86 programs. When
  the `LocalDumps` key did not exist, it creates it with the value
  `AlcoveCreated` (1) and answers `createdKey: true`. The result's `folder`
  is `C:\alcove-dumps`.
- While a `LocalDumps` key exists, Windows also writes a mini dump of every
  other crashing program into that user's `%LOCALAPPDATA%\CrashDumps`. Windows
  keeps the newest 5 dumps of `C:\alcove-dumps`, counted over all enabled
  images.
- `vm.crash_dumps.disable` removes the image's key with every value in it,
  then the `LocalDumps` key when its only value is `AlcoveCreated` and it has
  no subkey: a key made by someone else, one that holds another value, or
  one that still holds another image's key stays. Dumps stay in the folder. An
  image that was never enabled succeeds and changes nothing else.
- `vm.crash_dumps.list` lists the `.dmp` files of the folder, newest first and
  by name within one time: `file`, `exe` (the image of a file named
  `<image>.<pid>.dmp` or `<image>(<n>).<pid>.dmp`, the second form when the
  first name was taken; otherwise empty), `bytes` and `time` (last write, ISO
  8601 UTC on the guest's clock). Without the folder the list is empty. A dump
  that Windows is still writing is listed with its size so far.
- `vm.crash_dumps.pull` copies the dump `file`, a name from the list without
  a folder, to the host `path` like `vm.pull_file`. Sentences: `file must be
  the name of a .dmp file listed by vm.crash_dumps.list, without a folder`,
  `C:\alcove-dumps holds no dump named '<file>'; list the dumps with
  vm.crash_dumps.list`, `the dump '<file>' is still being written; retry in a
  few seconds` and `the dump changed while it was pulled; retry in a few
  seconds`.

Guest failures are sentences that end in the next step, e.g. `could not set
up crash dumps: <reason>; check that alcove-agent runs elevated`, `the crash
dump setting is still there after its removal; check that alcove-agent runs
elevated`, `C:\alcove-dumps is not a folder; remove or rename that file,
then call vm.crash_dumps.enable again`. Measured on Windows 11: a mini dump of
the fixture app (1.7 MB) is listed 2.9 s after the click that crashed it and
pulled in 0.09 s; `enable`, `disable` and `list` take 0.1 s to 0.8 s.

## Diagnostics bundle

`vm.collect_diagnostics` writes what can be learned about a VM's current
state into one host directory and answers `{dir, files, summary}`: `files`
are the paths of the bundle's files relative to `dir`, sorted, and `summary`
is `summary.txt` without its last line feed. It is read-only (no lease
needed) and runs in the concurrent lane; the recording of the VM, if any,
continues and traces the call as one line after the bundle is written.

- `dir` is an absolute host path to a missing or empty folder. Another
  folder is refused (`'<dir>' is not empty; choose a directory that is
  missing or empty, or leave dir out for a new folder`), and so is a `dir`
  another collection of this server is writing. Without `dir` the bundle goes
  to a new folder `~/Library/Application Support/Alcove/Diagnostics/<vm>-<yyyyMMdd-HHmmss>`
  (`-2`, `-3`, … when it exists).
- `sinceMinutes` (1 to 5256000, default 30) is how far back the event logs,
  the dumps and an ended recording reach.
- `logFiles` is a list of 1 to 20 guest file paths; of each, the last 2000
  lines within 262144 bytes are copied, as UTF-8 also from a UTF-16LE file.
- `processName` narrows `processes.json` to that program and adds a line
  saying whether it runs.

The steps run at the same time, each with its own time limit. A step that
fails writes `<file>.error.txt` holding its sentence, and the others go on:

| file | content | limit |
|---|---|---|
| `screenshot.png` | the screen | 10 s |
| `windows.json` | `{windows}` as `vm.window.list` gives it (Windows) | 15 s for the turn at the UI helper, 30 s for the answer |
| `ui-tree.txt` | the tree of the window in front, all elements, at most 1000 (Windows) | 40 s for the turn, 50 s for the answer; after the window list; not asked for when the window list was sent and not answered |
| `processes.json` | `{processes}` as `vm.process.list` gives it; in `command` the value of a `NAME=value` whose name contains `KEY`, `TOKEN`, `SECRET` or `PASSWORD` reads `<masked>` | 35 s |
| `eventlog-application.json`, `eventlog-system.json` | `vm.event_log` with `level: error`, the bundle's `sinceMinutes` and `max: 500` (Linux: the journal as `eventlog-system.json`) | 80 s each |
| `events.json` | the guest events the server holds | 30 s |
| `jobs/<job>.txt` | each job of `vm.exec.list`: state, code, command (masked like `processes.json`), start time, and the end of each stream, at most 262144 bytes from a line start | 45 s for all |
| `logs/<name>` | each of `logFiles`, named after the file | 45 s each |
| `dumps/<file>` | the dumps of `C:\alcove-dumps` written within `sinceMinutes` of the guest's clock, newest first, while their sizes add up to at most 500 MiB (Windows) | 100 s for all |
| `doctor.json` | `vm.doctor` | 85 s |
| `trace.jsonl` | the whole lines of the recording's trace, the newest 32 MiB | 30 s |
| `frames/<name>` | the frame files the copied trace lines name, newest first, up to 256 MiB | 30 s |
| `video.mp4` | the recording's video, at most 1 GiB | 60 s |
| `summary.txt` | see below | |

Names that come from the guest become single file names without characters
a host file name cannot hold, and names that differ only in case get `-2`,
`-3`, …. A step that ran out of time leaves nothing but its error file;
nothing is written into the folder after the op answered. A call whose client
went away removes a folder it created and leaves no error files or summary
in a folder it was given.

**The recording** is the VM's running one; else one that is ending (waited
for up to 30 s); else the one that ended last, when it ended within
`sinceMinutes`. Of a running recording, `video.mp4` is a copy of what the file
held when the copy began: it plays up to its last whole fragment (a note in
the summary says so); in the first seconds of a recording there is none yet
and `video.error.txt` says `the recording in <dir> has not written a playable
part of its video yet; collect again in a few seconds`. Measured: the copy
lasted 0.04 s to 0.7 s less than the recording's age while the screen
changed.

**Without guest tools** (not connected after 5 s), on a paused VM and on a
stopped one, the bundle holds what needs no guest: screenshot (not for a
stopped VM), doctor report, guest events and the recording's files; one line
of the summary says what was skipped. When the agent stops answering while
it stays connected, each guest step ends at its limit with its error file.
Measured on Windows 11: 2.3 s to 3.4 s for a full bundle (24 files, 5 MB with
a dump, a trace and a 10 s video), 12.8 s with the agent stopped, 76 s with
the agent suspended, 30 s while another client's call held the UI helper.
The worst case is about 110 s: 5 s for the agent, 100 s for the dumps and a
few seconds for the summary.

**summary.txt** has one fact per line:

```
VM Windows 11, collected 2026-10-14T03:31:02Z, guest windows
window not responding: 0x30216 "Alcove Fixture (Not Responding)" (pid 3340, alcove-fixture.exe)
foreground window: "Alcove Fixture (Not Responding)"
crash dump alcove-fixture.exe.1420.dmp: 1688134 bytes, 2026-10-14T03:30:31.1234567Z, collected as dumps/alcove-fixture.exe.1420.dmp
event log Application: 3 entries of level error or worse in the last 30 minutes; newest: Faulting application name: alcove-fixture.exe, …
event log System: 0 entries of level error or worse in the last 30 minutes
jobs exited with a non-zero code: none
process alcove-fixture: running, pid 3340
recording: /Users/me/rec (running)
frames: 10 of 10 copied
video.mp4: copied while recording, up to the last second may be missing
steps that failed: none
```

- `windows not responding: none`, or one line per window that is not.
- `crash dumps: none newer than <n> minutes`, or one line per dump with what
  became of it (`collected as dumps/<file>`, or `not collected: <why>; pull it
  with vm.crash_dumps.pull`), and `crash dumps older than <n> minutes: <count>
  left out, the newest from <time>`.
- `recording: <dir> (running | ended <time> | ending)`, `recording: <dir>
  (ended <time>; its folder no longer exists)`, or `recording: none in the
  last <n> minutes`.
- A fact whose step failed reads `<topic>: unknown (<step> failed)`. Notes
  follow for cut files (the trace's first lines, log tails, job streams,
  frames) and for skipped steps; the last lines list the failed steps with
  their sentences, or `steps that failed: none`.

## HTTP capture

A capture shows the HTTP and HTTPS requests the programs in a guest make and
lets a caller answer, delay or drop chosen requests. For each capturing VM the
control server runs `alcove-proxy`, an intercepting proxy, as its child
process. The proxy listens on `127.0.0.1` on a port it picks, and the guest
reaches it at `10.0.2.2:<port>`, the address of the Mac on the guest's
user-mode network. The listener takes no credentials: while the capture runs,
any process on the Mac that reaches that port, also one of another macOS
user, can send requests through it, and they are captured and answered by the
capture's rules like the guest's. HTTPS is intercepted with certificates the
proxy signs with the Alcove CA; the guest trusts that CA while the capture
runs.

The server looks for `alcove-proxy` in this order: the file `$ALCOVE_PROXY`
names (and only that file when the variable is set), `alcove-proxy` next to
the running executable (the app bundle carries it in `Contents/MacOS`, next
to the app's executable), `<repo>/build/alcove-proxy` (built by
`scripts/test/all.sh`). Without it `vm.http.start` answers `alcove-proxy was
not found; build it with scripts/test/all.sh or set ALCOVE_PROXY`.

The CA lives in `~/Library/Application Support/Alcove/proxy-ca/` (`ca.pem`
and `ca.key`, mode 0600, in a folder of mode 0700). The first capture creates
it, valid for 5 years; every capture of the Mac user uses it, and captures
that start at the same time on a Mac without a CA end with one CA. A new CA is
made by deleting both files while no capture runs. A start refuses a key that
does not belong to the certificate, a certificate that is not a CA, and one
that is expired or not yet valid; the error names the problem, e.g. `ca.pem
expired on <time>`, and ends `delete ca.pem and ca.key in <folder> to create a
new CA`. Files of the CA that group or others may read are set back to mode
0600. Leaf certificates are valid for 7 days; one proxy process keeps them for
up to 1000 hosts and drops the least recently used beyond that.

All `vm.http.*` ops run in the serial lane. `vm.http.requests`,
`vm.http.request` and `vm.http.rule.list` are read-only; the others are
guarded by a lease. One `vm.http.start`, `vm.http.stop` or cleanup of a VM
runs at a time; the others wait for it.

### Starting a capture

`vm.http.start` takes `name` and:

| Param | Default | Meaning |
|---|---|---|
| `hosts` | all hosts | array of host globs (`*` matches any run of characters), e.g. `["api.example.com", "*.corp.net"]`; other hosts are tunnelled and recorded as `tunnel` rows with byte counts only |
| `secrets` | `false` | keep the values of `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `x-api-key` and `api-key`; without it they are stored as `<redacted n chars>` |
| `bodies` | `true` | keep request and response bodies |
| `systemProxy` | `true` | point the guest's system proxy at the capture (Windows) |

The VM must be running (`VM '<vm>' is paused; call vm.resume first`), without
a capture (`'<vm>' is already capturing on port <n>; call vm.http.stop
first`). The guest tools get up to 25 s to connect. With `systemProxy` they
must connect and run commands: `guest tools are not connected in '<vm>', and
vm.http.start needs them to install the CA certificate and set the system
proxy; install alcove-agent in the guest, or pass systemProxy: false` (and
variants for tools that are too old or lack `--allow-exec`). With
`systemProxy: false` and no usable tools the capture starts with
`caInstalled: false` and a `warning` that names the host's `ca.pem`.

On a Windows guest the start, in order:

1. starts the proxy (15 s to report its port) and configures it;
2. writes the capture's entry into the capture journal (see [Cleanup after an
   earlier capture](#cleanup-after-an-earlier-capture));
3. copies the CA to `C:\ProgramData\Alcove\proxy-ca.pem` (Administrators and
   SYSTEM full control, Users read) and adds it to
   `Cert:\LocalMachine\Root`, found by its SHA-1 thumbprint;
4. with `systemProxy`, records the proxy settings it is about to change in
   `C:\ProgramData\Alcove\proxy-previous.json`, then sets the WinINET proxy of
   the agent's user (`ProxyServer` `10.0.2.2:<port>`, `ProxyOverride`
   `<local>`, `ProxyEnable` 1, `AutoConfigURL` removed, under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`), tells
   WinINET to reread its settings, and runs `netsh winhttp set proxy
   proxy-server=10.0.2.2:<port> bypass-list=<local>` (64-bit WinHTTP). With
   `systemProxy: false` it records the capture in the same file with
   `systemProxy: false` and puts back what an earlier capture left set.

On a Linux guest it copies the CA to
`/usr/local/share/ca-certificates/alcove-proxy.crt` and runs
`update-ca-certificates`; the system proxy is not changed, so only programs
started with the returned `env` are captured. A guest without
`update-ca-certificates` starts with `caInstalled: false` and a warning. Other
guest OSes start with a warning that the CA is not installed.

When a guest step fails, the start undoes the earlier ones and stops the
proxy; the error is the step's sentence. When the undo fails too, the error
adds `the guest keeps what this attempt changed, and Alcove restores it when
its guest tools next connect; call vm.http.stop to restore it now`.

The result:

```json
{"proxy": "10.0.2.2:58546", "caInstalled": true, "systemProxySet": true,
 "guestCAPath": "C:\\ProgramData\\Alcove\\proxy-ca.pem",
 "env": {"HTTP_PROXY": "http://10.0.2.2:58546", "HTTPS_PROXY": "…", "ALL_PROXY": "…",
         "NO_PROXY": "localhost,127.0.0.1,::1", "NODE_EXTRA_CA_CERTS": "C:\\ProgramData\\Alcove\\proxy-ca.pem",
         "SSL_CERT_FILE": "…", "REQUESTS_CA_BUNDLE": "…", "http_proxy": "…", "https_proxy": "…", "all_proxy": "…", "no_proxy": "…"},
 "warning": "…"}
```

`env` holds each proxy variable in upper and lower case. `NODE_EXTRA_CA_CERTS`
names the CA file. `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` name the CA bundle
on Linux and the CA file on Windows; on Windows they are left out when `hosts`
is set, because they replace a program's whole trust store (the `warning`
says so). While the capture runs, `vm.app.launch` and `vm.deploy` add `env` to
the environment of the programs they start; a variable the request names, in
any letter case, keeps the request's value. `vm.exec` and `vm.exec.start` add
nothing. Programs that were already running keep their proxy settings.

`warning` also reports a `netsh` failure (`netsh could not set the WinHTTP
proxy, so services and apps that use WinHTTP are not captured; run 'netsh
winhttp show proxy' with vm.exec to see why`) and a refresh that did not
happen (`the proxy settings were written, but Windows was not told to reread
them; restart the app under test`).

### Which programs are captured

Measured in a Windows 11 ARM64 guest (see
`docs/superpowers/plans/2026-10-13-at7-results.md`):

| Program | Reaches the proxy through | Trusts the CA |
|---|---|---|
| A Go program (`net/http`) started by `vm.deploy` | `HTTPS_PROXY` from `env` | yes (Windows root store) |
| PowerShell 5.1 `Invoke-WebRequest` (.NET Framework) | the WinINET system proxy | yes |
| WinHTTP clients (`WinHttp.WinHttpRequest.5.1`) | the `netsh winhttp` proxy | yes |
| Microsoft Edge, also one started before the capture | the WinINET system proxy | yes |
| `curl.exe` (Schannel) | only `-x` or `HTTPS_PROXY`; it ignores the system proxy | only with `--ssl-no-revoke` or `--ssl-revoke-best-effort`: without them it fails with `CRYPT_E_NO_REVOCATION_CHECK`, because the proxy's certificates name no revocation list |

Windows' own components (the connectivity probe, SmartScreen, telemetry) show
up in the capture as well. A program that pins certificates or brings its own
trust store (Firefox, Java, Python `requests` without `REQUESTS_CA_BUNDLE`)
rejects the proxy's certificate; the proxy records a `tlsError` row naming the
host and goes on serving the others.

### Reading the capture

**`vm.http.requests`** lists exchanges, oldest first: without `since` the
newest `limit` (default 50, at most 500), with `since` the first `limit` after
that exchange id. Filters: `host` and `path` (substrings of the URL), `status`
(a number, or a class such as `"4xx"`). The result is `{exchanges, next,
pending}`:

- each exchange is `{id, time, kind, method, url, status, ms, reqBytes,
  resBytes, rule?, error?, bodyDropped?}`; `kind` is `http`, `tunnel` (a host
  outside `hosts`, a plain `http://` request to such a host, a WebSocket, or a
  `CONNECT` connection that starts with neither TLS nor an HTTP request) or
  `tlsError` (the TLS handshake with the guest program failed, mostly because
  it refused the proxy's certificate; `error` ends with the next step:
  install the CA where the program looks for trusted certificates, or exclude
  the host with `hosts`); `rule` is the id of the rule that answered it;
  `error` says why the exchange did not end normally, e.g. `the upstream
  request failed: dial tcp …: connect: no route to host` for a 502 the proxy
  answered itself, or `the client gave up during the rule delay`;
- `next` is the id to pass as `since` for the following page;
- `pending` lists requests in flight and open tunnels (at most 200, oldest
  first) without an id.

**`vm.http.request`** reads one side of an exchange: `exchange` (the id),
`part` (`request` or `response`, required), `offset` and `length` (default and
at most 200,000 bytes of the body). The result is `{headers, body, total,
bodyTruncated, base64?, encoding?, bodyDropped?, headersTruncated?,
trailers?}`: `headers` and `trailers` as `[[name, value]]` (up to 64 KiB of
them per exchange; `headersTruncated: true` when pairs beyond that were left
out); a `gzip` or `deflate` body is decoded; a
body that is not UTF-8 text comes as base64 with `base64: true`, and a body
with another content encoding comes as base64 with `encoding` naming it. A
missing id answers `no exchange with id <n>; the store keeps the newest 2000
exchanges and 'clear' removes them all`.

**`vm.http.clear`** discards the captured exchanges; the capture goes on.

The proxy keeps up to 2 MiB of each body (`bodyTruncated` beyond) and the
newest 2000 exchanges. The bodies and headers of the stored exchanges and the
bodies of exchanges in flight take at most 256 MiB together; beyond that the
oldest exchanges lose their bodies and report `bodyDropped: true`, and an
exchange in flight keeps no more of its body when no stored body is left to
drop. A streamed response (server-sent events, a chunked model reply) is
passed to the guest as each piece arrives; the capture holds it once it has
ended.

A WebSocket (an HTTP/1.1 request with `Connection: upgrade` and `Upgrade:
websocket`) passes through: the upgrade request goes through the rules like
any request and is forwarded with those headers; when the server answers 101
the proxy joins the two connections until either side closes. Its row is a
`tunnel` row with status 101 and the bytes sent each way after the handshake;
for a host in `hosts` it keeps the handshake headers, never the frames. A
server that refuses the upgrade gives an `http` row. A plain `http://` request
a program sends through `CONNECT` (a `ws://` socket, or a program that sends
everything through `ALL_PROXY`) is captured as an `http` row; other protocols
through `CONNECT`, and a program that sends nothing for 5 s after connecting,
are tunnelled.

The proxy adds nothing of its own to what it forwards: no `User-Agent` when
the program sent none, no `Date` or `Content-Type` when the server sent none.
It relays the server's informational answers (such as `103 Early Hints`), and
for a request with `Expect: 100-continue` it asks the program for the body
only when the server does (or after 1 s without an answer).

A guest request to `10.0.2.2:<port>`, a server on the Mac, is captured: the
proxy connects to the Mac's `127.0.0.1:<port>` and keeps the URL. The proxy
checks upstream HTTPS certificates against the Mac's trust store, so a Mac
server with a self-signed certificate answers 502 with the reason.

In a recording's trace the six secret headers of `vm.http.request` results
read `<masked>` (a `<redacted n chars>` value stays as it is), and bodies are
cut at 2000 characters with `bodyCut: true`.

### Rules

**`vm.http.rule.add`** takes `match` (`host` glob, `path` glob, `method`; all
optional, so `{}` matches every request) and `action`:

- `status` (200 to 599), `headers` (object) and `body` (string) answer the
  request without contacting the server; the status defaults to 200 and the
  content type to `application/json` when the body parses as JSON, otherwise
  `text/plain; charset=utf-8`;
- `delayMs` (0 to 600,000) waits before answering, or before forwarding when
  the rule has no `status` or `body`. Before the delay the proxy reads the
  request body: all of it for a rule that answers or drops, up to 2 MiB of an
  HTTP/1.1 body for a rule that forwards, 30 s at most (a forwarding rule
  then answers `408`). A program that gives up during the delay ends it: the
  row's `error` reads `the client gave up during the rule delay` and nothing
  is forwarded. `vm.http.stop` ends running delays (`the proxy stopped during
  the rule delay`);
- `drop: true` closes the connection without an answer;
- `times` (at least 1) applies the rule that many times.

The result is `{rule}`, the rule's id. The first matching rule in the order
they were added applies; `times: 1` affects exactly one request also under
concurrent requests. **`vm.http.rule.list`** returns `{rules: [{id, match,
action, hits, remaining?}]}`; a rule whose `times` are used up stays listed
with `remaining: 0` and no longer applies. **`vm.http.rule.remove`** deletes
`rule` (`no rule with id <n>; run rule.list to see the ids`);
**`vm.http.rule.clear`** deletes all. An action without any of `status`,
`body`, `delayMs` or `drop` answers `the action needs at least one of status,
body, delayMs or drop`.

The ops other than `vm.http.start` and `vm.http.stop` answer `'<vm>' is not
capturing; call vm.http.start first` on a VM without a capture.

### Stopping a capture

**`vm.http.stop`** restores the guest, removes the CA from it, stops the proxy
and returns `{exchanges}`, the number of exchanges since the start. The
captured exchanges and rules are discarded; read them first. When a guest step
fails or the guest tools are not reachable, the capture still ends on the
host and `warning` says what the guest keeps; a second `vm.http.stop` then
clears it.

The restore puts back exactly the values the state file recorded, and only
while `ProxyServer` is still `10.0.2.2:<port of the state file>` (the WinHTTP
proxy: while it names that address). It writes `ProxyServer` last, so a
restore that was cut off can run again. A proxy the user set, also one at
`10.0.2.2`, or a `ProxyServer` the user changed during the capture is left as
it is (the `ProxyOverride` `<local>` of the capture then stays too). The CA is
removed by thumbprint, the journal's and the state file's, never by name; a
certificate the user had installed with the same thumbprint goes too. The
state file and a leftover `proxy-previous.json.new` are deleted. WinINET
itself stores `ProxyEnable` as `REG_DWORD` and `ProxyOverride` as `REG_SZ`
whenever it rereads its settings, and it advances the change counter of the
`DefaultConnectionSettings` blob; the values themselves are the recorded ones.

On a VM without a capture, `vm.http.stop` clears what an earlier capture left
in the guest (the state file, the journal's entry, the CA file) and answers
`{exchanges: 0, staleCleared: true}`; when it finds nothing, `'<vm>' is not
capturing; call vm.http.start first`. Its guest tools get 5 s to connect; with
an entry in the journal and no tools it answers `'<vm>' is not capturing, and
what an earlier capture left in its guest cannot be restored while its guest
tools are not reachable; call vm.http.stop again once vm.status shows tools`.

A state file that cannot be read (a read is tried three times, 200 ms apart)
is never changed or deleted. Every step that needs it, `vm.http.start` among
them, answers `the stored proxy settings in
C:\ProgramData\Alcove\proxy-previous.json cannot be read; put the proxy
settings right by hand, delete that file and call vm.http.stop again`. A start
refused this way leaves no certificate in `Root`, and the journal keeps the
entry until a later `vm.http.stop`. A state file deleted by hand during a
capture leaves the capture's proxy settings in place: `vm.http.stop` removes
the CA, and `vm.doctor` reads `system proxy 10.0.2.2:<port> (not set by
Alcove; if a capture left it, change it by hand)`.

A capture also ends when:

- `vm.stop` stops the VM: without `force` and with connected guest tools it
  restores the guest first (12 s per recipe); the result carries
  `captureEnded: true`, and `warning` when the guest was not restored (`the
  guest keeps the proxy settings and the CA certificate of the capture
  (<reason>); Alcove restores them when its guest tools next connect`, the
  reason being `the stop was forced`, `its guest tools were not connected`,
  `the VM was paused`, `the VM was not running` or a recipe's sentence); a
  stop that fails says `its HTTP capture was ended, call vm.http.start to
  capture again`;
- the VM stops by itself or runs in another engine process (checked every
  2 s), or `vm.start` starts it again;
- `vm.snapshot.restore` or a restore in the app window replaces the guest
  (`captureEnded: true`); `vm.delete` deletes the VM;
- `alcovectl serve` ends on SIGTERM or SIGINT, or the app quits: the guests
  whose tools are connected are restored (the app waits at most 20 s);
- the control server dies: the proxy exits when its input closes, and the
  guest keeps the capture's settings until the cleanup below.

### Cleanup after an earlier capture

`captures.json` in the CA folder (mode 0600) records every capture whose guest
was changed and not yet restored, and every snapshot taken while a VM had such
a capture:

```json
{"version": 1,
 "captures": [{"vm": "Win", "path": "/…/Win.alcovevm", "port": 49152, "thumbprint": "<40 hex>", "systemProxy": true, "since": "…"}],
 "snapshots": [{"vm": "Win", "path": "/…/Win.alcovevm", "snapshot": "mid-capture", "port": 49152, "thumbprint": "…", "systemProxy": true, "since": "…"}]}
```

Changes hold an exclusive lock on `captures.json.lock`. A file that is not a
readable version 1 counts as empty; the next change renames it to
`captures.json.unreadable-<UTC time>`. A journal that cannot be written
refuses `vm.http.start` before any guest step. An entry matches a VM by the
standardized path of its bundle as the host spells it (an entry without
`path` by name), so the app and `alcovectl serve --dir <other>` keep separate
entries for equally named VMs; after a rename, a move or with a symbolic link
in `--dir` the old entry no longer matches, and `vm.http.stop` still restores
the guest from its state file.

When the guest tools of a VM with an entry connect and no capture of it runs
(after a crash of the host, a forced or paused stop, a stop without tools, a
failed restore), the server restores the guest from the entry, once per
connection, and removes the entry when every step worked. Each recipe gets
25 s in the guest (30 s on the host), up to three recipes (90 s) while the
VM's capture gate is held; `vm.http.start` and `vm.http.stop` wait for it. A
cleanup that failed keeps the entry for the next connection and writes one
line to the server's stderr (`alcovectl serve`) and the system log
(subsystem `io.github.yangtaeyoung.Alcove`, category `control`): `the cleanup
after an earlier HTTP capture of '<vm>' failed to <step> (<sentence>)[ and to
<step> (<sentence>)]`, the steps being `restore the proxy settings`, `remove
the proxy CA` and `run its recipes`. When a step failed because the guest gave
no answer, the server drops that connection and asks for one more.

In the app, a window connection on a boot or resume of a VM with an entry also
makes the control target connect, and that connection runs the cleanup; a VM
without an entry gets no extra connection. A snapshot taken during a capture,
from the op or the window, is noted; restoring it (`vm.snapshot.restore` or
the window) makes the note the VM's entry again and runs the cleanup, and
`vm.snapshot.restore` answers `staleProxyCleared` (whether the cleanup removed
anything). Deleting the snapshot removes its note; deleting the VM removes its
entry and notes. The app calls these hooks only when it hosts the control
server.

### Doctor row

The `proxy` row reads the guest's proxy settings: `capturing through
10.0.2.2:<port>, system proxy set|not set` while a capture runs (not ok when
the system proxy points at another port: hint `call vm.http.stop, then
vm.http.start`); `no system proxy` or `system proxy <server>` when nothing of
a capture is left, with ` (not set by Alcove; if a capture left it, change it
by hand)` for a server at `10.0.2.2:<port>` without a state file. It is not ok
with the hint `vm.http.stop clears stale proxy settings` when no capture runs
but the system proxy still points at the port the state file records, the
state file is still there, the CA is still installed, or the state file cannot
be read.

### Time limits

Limits from the code, the longest each op can take: `vm.http.start` 160 s
when it works and 211 s when its last step fails, 250 s and 301 s behind a
running cleanup (Linux 130/151 s, 160/181 s); `vm.http.stop` 247 s; a
cleanup 90 s; `vm.stop` of a capturing VM 51 s before the engine stop. Each
proxy call has 30 s and an answer line at most 16 MiB (`alcove-proxy sent an
answer larger than 16 MiB; ask for less with limit, offset or length`). One
proxy of the server starts at a time. Measured in the guest: start about 2 to
3 s, stop about 2 s, the cleanup after a cold boot within 5 s of the tools
connecting.

### Restoring a guest by hand

Without Alcove, in an elevated PowerShell as the agent's user:

1. `Get-Content C:\ProgramData\Alcove\proxy-previous.json`. A field decodes
   with `[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('<value>'))`;
   `null` means the value was absent. With `"systemProxy":false` go to step 4.
2. `$k='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'`:
   put back the recorded `ProxyServer`, `ProxyOverride` and `AutoConfigURL`
   (`New-ItemProperty $k -Name ProxyServer -Value '<old>' -PropertyType String
   -Force`, `ExpandString` where the recorded kind says so), remove the ones
   recorded as `null` (`Remove-ItemProperty $k -Name ProxyServer -ErrorAction
   SilentlyContinue`), and set `ProxyEnable` to the recorded number.
3. WinHTTP: `netsh winhttp reset proxy`, or `netsh winhttp set proxy
   proxy-server="<server>" bypass-list="<list>"` for a recorded proxy.
4. The certificate, by the thumbprint of the state file or of `captures.json`
   on the Mac: `Remove-Item Cert:\LocalMachine\Root\<THUMBPRINT>`.
5. `Remove-Item C:\ProgramData\Alcove\proxy-ca.pem,
   C:\ProgramData\Alcove\proxy-previous.json,
   C:\ProgramData\Alcove\proxy-previous.json.new -ErrorAction
   SilentlyContinue`.
6. Linux: `rm -f /usr/local/share/ca-certificates/alcove-proxy.crt
   /usr/local/share/alcove-proxy.crt.removing && update-ca-certificates
   --fresh`.
7. On the Mac, remove the VM's entry from `captures.json` (or the file, while
   no capture runs).

Programs that are running keep the old settings until they restart.

On Linux the removal moves the CA file to
`/usr/local/share/alcove-proxy.crt.removing` and deletes it after
`update-ca-certificates --fresh` worked; a failed refresh answers
`update-ca-certificates --fresh failed in the guest, so the guest still trusts
the proxy CA; run it with vm.exec to see why, then call vm.http.stop again`,
and the next stop refreshes again.

### HTTP tools of the MCP server

The `http` toolset has `alcove_http_capture_start` (`hosts`, `secrets`,
`bodies`, `system_proxy`), `alcove_http_capture_stop`, `alcove_http_requests`
(the list filters; with `id`, `part`, `offset` and `length` one exchange as
headers, a blank line and the body clipped at 60,000 characters; `clear:
true` alone empties the list) and `alcove_http_rule` (`action` `add`, `list`,
`remove`, `clear`; `match`; `response` with `status`, `headers`, `body`,
`delay_ms`, `drop`, `times`; `rule`). List lines read `#id time METHOD url ->
status (ms, req/res bytes) [rule n]`. The client waits up to 316,000 ms for
a start and 262,000 ms for a stop.

## Scripts

`script.run` replays a JSON script of control ops without a model. It runs in
the concurrent lane.

Parameters: `path` (script file on the host; use an absolute path, a relative
one resolves against the server's working directory), `name` (VM; overrides the
script's `vm`), `variables` (object of strings that override the script's
defaults), `snapshot` (restored before the first step), `lease` and `maxWidth`
(the width of the failure screenshot, as for `vm.screenshot`: a whole number of
1 or more; any other value is ignored and the screenshot keeps the frame's
size). The VM comes from `name` or the script's `vm`; with neither the op
fails.

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
refusal, a failed snapshot restore, a cancellation before step 1. A run
cancelled during the restore of `snapshot` ends when the restore has ended
(see `vm.snapshot.restore` in [Snapshots](#snapshots)) and holds its lease
until then. Otherwise the
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

A step entry also carries `usedAltSelector: true` when its op ran again with
`altSelector`, `usedFallback: true` when it clicked its `fallback` point, and
`positional: true` when the selector that ran last has an `index` (never after
the fallback click). The entry of a step that a cancellation interrupted has
the error `the run was cancelled during step N; start it again`.

### Selectors that back each other up

- `altSelector` is a second selector in the `params` of `vm.ui.click`,
  `vm.ui.type`, `vm.ui.action`, `vm.ui.find` and `vm.ui.text`, next to
  `selector`. The step runs its op with `selector` first; only when the UI
  helper answers that no element matches does it run the op once more with
  `altSelector`. Any other failure of the first try fails the step.
- `fallback: {x, y}` is accepted by `vm.ui.click` only. When the element is
  still not found (no match, its window is gone, or the ref no longer exists),
  the step clicks the point with `vm.mouse.click`, with the step's button,
  count and observe options. When both selectors and the click fail, the
  step's error names the selector's failure and the click's.
- `index` in a selector picks the element by its position among the elements
  that match. A script that `script.save` wrote uses it when more than one
  element matched while recording; a replay whose list differs picks whatever
  is at that position, and nothing checks role or name again. Such a step
  carries `positional: true`.

### Saving a script from a recording

`script.save` writes a script from the trace of a recording. It ignores
leases and runs in the serial lane.

Parameters: `dir` (the recording directory; its `trace.jsonl` is read) or
`trace` (the path of a trace file), not both; `path` (absolute, ending in
`.json`; its folder is created when the folder above it exists); `name` (the
script's `vm`; default: the VM the trace names); `from` and `to` (the `seq`
range of the trace lines used, integers of 1 or more, `from` not above `to`);
`overwrite` (replace a file at `path`; default false, which answers `'<path>'
exists; pass overwrite: true or another path`). The result is `{path, steps,
skipped, warnings?}`.

- The trace is read one line at a time. A line that is not a JSON object with
  an integer `seq` and a string `op`, or that is longer than 8 MiB, is left
  out and counted in `skipped`. When the line after the last readable `seq`
  lies in `from`...`to` (always, without `from` and `to`), a warning says
  `trace line <n> was skipped (<reason>); a step may be missing`.
- The script must pass the checks `script.run` makes before its first step,
  and its encoded form may not exceed 4 MiB; otherwise nothing is written and
  the error names the step and its `seq`. A script that still holds the
  trace's mask marker `<masked>` is refused with the step that holds it.
- The file is written through a temporary file beside it and renamed, with
  mode 0600.
- A trace without a step to replay answers `the trace holds no op to replay;
  record clicks, keys or other changing ops first` (or names the range).

Which trace lines become steps:

- Only lines of ops that succeeded and that a client sent or a script ran as a
  step. Read-only ops are left out, except `vm.wait_for` that matched a
  condition and `vm.wait_idle`. `name` is removed from the params, `${` is
  written as `$${` in every string, and the `since` of an `event` condition is
  dropped.
- A `vm.mouse.click` without `hold` whose trace line has a `target` becomes
  `vm.ui.click` with `selector`, `altSelector` when there is one, and
  `fallback` at the clicked point, when the element can be found again and
  the point counts as a click on the element: always for `Button`,
  `CheckBox`, `RadioButton`, `MenuItem`, `TabItem`, `ListItem`, `TreeItem` and
  `Hyperlink` (a click on a part of a list or tree item that the helper does
  not list, such as an expander, replays at the item's centre); for `Edit`,
  `ComboBox`, `SplitButton`, `Spinner`, `HeaderItem`, `DataItem` and `Text`
  only within `max(6, w/4)` pixels horizontally and `max(6, h/4)` vertically
  of the centre. Any other click stays a `vm.mouse.click` at its coordinates.
- The selector holds `window` (see below), `role`, and `automationId` when the
  element has one, else `name`; `altSelector` holds the `name` when the
  selector uses the automation id and the element has both. Each carries
  `index` when more than one element matched; such a step gets the warning
  `step <n> (<label>) selects number <k> of <matches> elements that look the
  same; it replays whatever is at that position`.
- A `vm.ui.*` op that named its element by `ref` gets the selectors of its
  `target` in place of the ref; without them a `vm.ui.click` becomes a
  `vm.mouse.click` at the point it clicked and any other such op is left out.
  A `vm.window.action` on a window id names the window by the title in its
  result. Left out, each with a warning: a `vm.wait_for` whose condition names
  a ref, a `vm.batch` with a step that holds a ref, a step with a value the
  trace cut at 2000 characters, a window id without a title.
- Consecutive `vm.type` lines with the same other params and no expectation
  merge into one step.
- A step whose line shows a foreground window with another title part than the
  steps before it gains `expect: [{"type": "window_title", "contains":
  <part>}]`; switching between windows with the same part adds nothing.
- Steps that name a job id or a pid of the recorded session keep them and get
  a warning to change them by hand.

Window titles: a script names a window by the stable part of its title, the
text after the last ` - `, ` – ` or ` — ` when it has at least 3 characters,
but only when no other window title the trace shows (`target.window`, the
foreground of observations and their window events, `result.window` of any op,
the `vm.window.list` entries) contains that part, ignoring case; otherwise by
the whole title. A title shown only by windows that also showed the named
title (one window that changed its title) does not count as another window; a
title seen without a window id does. This holds for `selector.window`,
`altSelector.window`, the window expectation and the title that replaces a
window id in `vm.window.action`. Warnings: `steps name the window "<part>" by a
part of its title "<title>"; another window whose title contains "<part>"
would be used instead` (once per part) and `steps name the window "<title>";
more than one window had that title while recording, the first one found is
used`. A window that the trace never shows can still match at replay.

Passwords and masked values: no typed secret is written to a script.

- The `text` of a `vm.ui.type` and the `value` of a `vm.ui.action` aimed at a
  password element, and the `text` of a `vm.type` when the latest line that
  said what it was aimed at was a password element, become the variables
  `password`, `password2`, … without a default; `script.run` refuses the
  script until they are passed. Every value the trace masks as a whole
  becomes a variable as well (a masked env value is named after its key), and
  each gets a warning.
- A step whose value holds the mask marker inside a longer string is left out
  with `step <n> (<op>) holds a masked value inside "<key>"; write the step by
  hand with a variable`. Labels show `hidden text` in place of the marker.
- Before a `vm.key.press` or `vm.key.down` whose keys are one printable
  character (a space included), alone or after `shift+`, the recording asks
  the UI helper which element has the focus. When it is a password element,
  the key is masked in the trace, its `vm.key.up` follows it, and the steps
  are left out of the script with `step <n> pressed keys in a password field;
  type the password with vm.type and a variable instead`. Named keys (`enter`,
  `tab`, arrows, `space`), combinations with ctrl, alt, cmd or win, and keys
  inside a `vm.batch` are never masked.
- Not masked, and so written to the script in clear: a `vm.type` whose
  question about the focus got no answer in time, a selector-addressed
  `vm.ui.type` or `vm.ui.action` that failed, text inside a `vm.batch`, and
  the clipboard.

What a recording costs per action: before a click, a drag, a `vm.type`, a text
key and a ref-addressed `vm.ui.*` op, one `ui.at` question to the UI helper,
waited for 300 ms at most (the helper's own budget is 200 ms). The question is
skipped while the helper serves another request, so such a line has no
`target`: a click stays coordinates and a ref op is left out. Right after the
helper starts (up to 120 s on a new session) questions are skipped as well.

### Secrets during a run

A variable whose name contains `password`, `key`, `token` or `secret` (any
case) is a secret. While `script.run` runs, every trace line written on its
behalf (a recording may be active) has each string equal to a secret value
replaced by `<masked>`, and a secret value of 8 or more characters replaced
inside longer strings as well. Not covered: object keys, base64 content (such
as `vm.fs.write` `content`), frames and video of the recording, a secret of
fewer than 8 characters inside a longer string, and trace lines of other
clients' ops during the run. A text pasted into the guest through the
clipboard (`vm.type` and `vm.ui.type` paste text with a character outside the
US layout, such as Korean) stays in the guest clipboard after the step.

### `alcovectl run-script`

```
alcovectl run-script [--vm NAME] [--var KEY[=VALUE]]... [--snapshot NAME] [--socket PATH] [--in-process] [--] FILE
```

It sends `script.run` for FILE (made absolute) to the control server at the
socket (default: the app's socket), with `--vm` as `name`, the `--var` values
as `variables` and `--snapshot` as `snapshot`, waits for the reply and prints
one line per step, then `PASSED: <n> steps in <s> s` or `FAILED: step <n>
failed after <s> s`:

```
variables: PASSWORD=<hidden>, button=Sned
ok   1 vm.ui.type Edit "Message" 600 ms
FAIL 2 vm.ui.click Button "Send" 0 ms
     no element matches {"window":"Alcove Fixture","role":"Button","name":"Sned"}; call ui.tree to see what exists
error: step 2 (vm.ui.click Button "Send") failed: no element matches {"window":"Alcove Fixture","role":"Button","name":"Sned"}; call ui.tree to see what exists
FAILED: step 2 failed after 0.7 s
```

- A step line is `ok` or `FAIL`, the step number, its label (the op without
  one), the milliseconds, and the markers `[fallback]`, `[alt selector]` and
  `[positional]`. Lines are printed when the run has ended, not while it runs.
  A `warning:` line follows when the reply has one.
- `--var KEY=VALUE` gives `${KEY}` a value (repeatable; the last one wins and
  a repeat is reported on stderr; VALUE may contain `=`). `--var KEY` reads the
  value of the environment variable KEY; use it for secrets, since the
  arguments of a process are visible to other users. The first line lists the
  passed variables, a secret one as `KEY=<hidden>`; the values of secret
  variables, the script's defaults included, are replaced by `<hidden>` in
  every printed line.
- On a failed step the failure screenshot is written next to the script as
  `FILE.failure.png` (full size). The file is removed when a run starts, so it
  exists afterwards only when that run failed and produced a screenshot.
- Exit status: 0 passed; 1 a step failed; 2 the script could not run (bad
  arguments, unreadable script, no VM, no server, a refusal before step 1, or
  an `--in-process` run that passed but whose VM could not be stopped; the
  reason is on stderr); 130, 143 and 129 after SIGINT, SIGTERM and SIGHUP.
- Without a server at the socket the command stops with exit 2 and `no control
  server answers at <socket>; start one with alcovectl serve, or pass
  --in-process to run the script without a server`. `--in-process` while a
  server answers is refused: `a control server answers at <socket>; run the
  script without --in-process, or stop that server first`.
- `--in-process` runs the script in the command's own process with a headless
  registry of the VMs in `ALCOVE_VM_DIR` (default
  `~/Library/Application Support/Alcove/VMs`). It holds an exclusive lock on
  `run-script.lock` in the VM's bundle for the whole run (`another run-script
  --in-process is using '<vm>'; wait for it or use a control server`) and
  refuses a VM whose engine runs under another process (`'<vm>' is running
  under another process and no control server answers at <socket>; start the
  Alcove app or alcovectl serve, or stop the VM, and run the script again`).
  The lock stops only other `run-script --in-process` commands; the app or
  `alcovectl serve` may still start the VM, and the engine check of
  [Starting](#starting) then refuses one of the two hosts. A stopped VM is
  started only by a `vm.start` step of the script; every VM the run started
  is stopped when the run ends, also after a failure or a signal. The lock
  file stays in the bundle.
- SIGINT, SIGTERM and SIGHUP stop the run: through a server, the command
  closes its connection, the server cancels the run before its next step and
  releases the run's lease, and the command prints `INTERRUPTED` at once.
  When the signal arrives during the restore of `--snapshot`, the restore
  runs to its end (up to the 600 s limit of the load) and the guest is
  resumed; the run keeps its lease until then.
  In-process, the run is cancelled, the VM is stopped, the step lines up to
  the interrupted step are printed and the last line is `INTERRUPTED`. A
  second signal while the VM is being stopped ends the command at once.

### MCP tools

The `replay` toolset of the MCP server has `alcove_script_save` (`dir` or
`trace`, `path`, `name`, `from`, `to`, `overwrite`; it answers `saved <path>`,
the step count, the skipped trace lines and each warning) and
`alcove_script_run` (`path`, `variables`, `snapshot`, `name`). The run tool
sends `maxWidth: 1280`, prints the same step lines as `run-script`, ends with
`PASSED` or `FAILED`, adds the failure screenshot as image content, and hides
secret values (the passed ones and the script file's defaults) in its text and
structured content. Pass `name` when the session holds a lease on the VM so
the run uses it. The client waits up to 7,925,000 ms for a run.

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
  file with one `rename(2)`. The host folder must exist. `path` must be
  absolute (`path must be an absolute path on the host, such as
  /Users/<you>/<name>`), and a folder at `path` is refused before anything is
  read from the guest (`'<path>' is a folder on the host; pass the path of the
  file to create, such as <path>/<guest file name>`); a folder that appears
  there during the pull is kept and the pull fails (`'<path>' could not be
  replaced: <reason>; pass the path of a file that is not a folder`). A file
  that changes in the guest during the pull answers `'<guestPath>' changed in
  the guest while it was pulled, so the copy does not match; pull the file
  again`. `vm.crash_dumps.pull` takes `path` by the same rules.
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
the UI helper is busy with other requests; retry
pass ref or selector
element e12 no longer exists; call ui.tree again
element e14 has no clickable point: window 0x501fa "Alcove Fixture" covers the centre of the element; focus the element's window with win.action; or act on it with vm.ui.action
cannot start 'C:\apps\tool.exe': The system cannot find the file specified.; check the path with vm.fs.list
'C:\alcove-e2e\junction' is a link in the guest; pass the folder it points to
the request line is not JSON that can be read (broken syntax, or a \u escape of half a surrogate pair); send one JSON object per line
'Win' is already recording to /Users/me/rec; call vm.record.stop first
the dump 'app.exe.4242.dmp' is still being written; retry in a few seconds
'Win' is already capturing on port 58546; call vm.http.stop first
'Win' is not capturing; call vm.http.start first
alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY
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
- The window, element and event ops exist for Windows guests only.
- Window events are reported only while the guest's UI helper runs. After the
  agent replaced a helper that did not answer, they resume with the next
  window or element request, and what happened in between is not reported.
- A start refuses while the VM's engine runs under another live host:
  `start failed: '<vm>' is running in another Alcove host (<process name> pid
  <ppid>); stop the VM there or quit that host, then start it here`. The
  engine of a host that has exited is stopped by the next start.
- Recordings and the last ended recording a bundle may use live in the
  server: a server that exits leaves the files of a running recording as they
  were written, without `vm.record.stop`'s finishing, and a new server knows
  no recording. The crash dump settings live in the guest's registry and stay.
  Stopping `alcovectl serve` with SIGTERM also shuts down the VMs it runs.
- Video was recorded with `alcovectl serve` started from a Terminal of the
  logged-in user; a server process without a window server session (an SSH
  login, a launchd daemon) was not tried.
