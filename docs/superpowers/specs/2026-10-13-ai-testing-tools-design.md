# AI testing tools design

Date: 2026-10-13. Status: draft for review.

## Goal

A coding agent on the Mac (Claude Code first) builds a Windows application,
puts it into an Alcove VM, drives it, sees what happened and collects the
evidence it needs to debug a failure, with few round trips and few image
tokens. The first target application is a Windows `.exe` AI agent chatbot, so
streaming text output, long transcripts and outbound HTTPS calls to model APIs
are first-class cases.

Decisions taken with the user on 2026-10-13:

| Decision | Choice |
|---|---|
| Scope | every idea from the ideation round, built as ordered sub-projects |
| Guest | Windows 11 ARM64 first; OS-neutral pieces also work on Linux |
| Tool surface | a wide tool set is wanted for debugging; tools are grouped and selectable |

Assumption (not stated by the user): the UI framework of the target app is
not fixed yet. The design therefore covers both native UI (UI Automation) and
embedded Chromium (DevTools protocol through a forwarded port).

## Non-goals

- Linux accessibility tree (AT-SPI). The Linux agent runs as a systemd system
  unit (`guest-tools/cmd/alcove-agent/install_other.go:11,34`), outside the
  graphical session; this needs its own design.
- Host folder sharing. It stays in SP2 of `2026-09-03-alcove-design.md`. This
  design moves files through the guest agent only.
- Latency and packet-loss shaping. v1 offers link up/down only.
- Attaching a debugger (cdb/WinDbg) to the app under test.

## Starting point

Facts read from the tree on 2026-10-13:

| Area | Today | Reference |
|---|---|---|
| Observation | full-frame PNG through QMP `screendump`, `maxWidth` only | `docs/control-protocol.md:29`, `VMController.swift:414-417` |
| Idle detection | polls `screendump` every 500 ms and compares thumbnails | `ControlHandler.swift:183-201` |
| Exec | one shot, stdout+stderr merged, no cwd/env/timeout in the agent, runs inline in the agent read loop | `guest-tools/internal/server/server.go:212-218,280-296` |
| Agent requests | no request id; replies are matched by message type | `AgentClient.swift:111-113` |
| Files | host to guest only, Desktop or Downloads only | `docs/agent-protocol.md:32-35`, `server.go:153-158` |
| Control concurrency | requests on one connection run sequentially | `ControlServer.swift:6` |
| Snapshots | engine has create/restore/delete/list; no control op | `VMController.swift:306-367`, `ControlHandler.swift:45-183` |
| Pause/resume, resolution | control or agent support exists; no MCP tool | `ControlHandler.swift:70-74`, `docs/agent-protocol.md:30` |
| Port forwards | fixed at boot from the VM config | `QEMUCommandBuilder.swift:100-101` |
| Windows agent session | scheduled task at logon, interactive session, highest privileges | `install_windows.go:13-16,54` |
| Windows display | ramfb re-sends full-screen updates every refresh | `2026-09-03-sp0-results.md:41-42` |

Enablers confirmed locally:

- Runtime port forwarding: HMP `hostfwd_add` / `hostfwd_remove`
  (`build/qemu-src/hmp-commands.hx:1375,1389`), reachable through QMP
  `human-monitor-command` (`docs/research/qemu-11.1.1-qmp-commands.md:332-336`).
- Link up/down: QMP `set_link` (`build/qemu-src/qapi/net.json:37`).
- Host OCR: `VNRecognizeTextRequest.supportedRecognitionLanguages()` on this
  host lists `ko-KR`, `en-US`, `ja-JP` among others (run on 2026-10-13).
- Agent messages are bounded at 1 MiB per line
  (`guest-tools/internal/proto/proto.go:42`).

## Principles

1. **Text before pixels.** UI structure, window lists, text content, logs and
   events come back as text. Images are opt-in and cropped.
2. **Every action reports what changed.** Action tools settle briefly and
   return a text summary, so the common click-wait-look cycle is one call.
3. **Input stays at the hypervisor.** Mouse and keyboard keep going through
   the display protocol. The guest agent supplies meaning (element bounds);
   QEMU supplies input. The secure desktop, the lock screen and firmware
   screens stay drivable.
4. **Capabilities, not assumptions.** Every guest-side feature is a capability
   in the agent `hello`. A missing capability produces an error that says what
   to do next. `alcove_doctor` lists them in one call.
5. **One implementation, three hosts.** Features live in `AlcoveControl` and
   the guest agent. The app, `alcovectl serve` and the MCP server expose the
   same operations; `alcovectl run-script` replays them without a model.

## Architecture

```
Claude Code ── MCP (stdio) ── alcove-mcp ── control socket ── AlcoveControl
                                                              │  ├─ FrameSource   (shared framebuffer: crop, diff, OCR, video)
                                                              │  ├─ Trace         (every op, timestamps, before/after frames)
                                                              │  ├─ EventBuffer   (guest events, per VM ring buffer)
                                                              │  ├─ Leases        (who may send input)
                                                              │  └─ ScriptRunner  (replay)
                                                              ├─ QMP            (snapshots, hostfwd, set_link)
                                                              ├─ display socket (input)
                                                              └─ agent TCP ── alcove-agent (guest)
                                                                              ├─ jobs, processes, files
                                                                              ├─ UI Automation, windows
                                                                              └─ event hooks
```

### Agent protocol v2

- Host requests are `{"t":"req","id":n,"op":"...",...}`. The agent answers
  `{"t":"res","id":n,"ok":true,...}` or `{"t":"res","id":n,"ok":false,"error":"..."}`.
- Each request runs in its own goroutine; a long `exec` no longer delays
  `ui.tree` or keepalives.
- Unsolicited messages are `{"t":"ev","name":"window.opened",...}`.
- Large payloads are paged by the operation (`offset`/`length`), so every
  message stays under the line bound.
- `hello` keeps `v: 1` and adds `proto: 2` plus the `rpc` capability. v1
  message types keep working against a new agent, an older host still accepts
  a new agent, and a new host talking to an older agent uses v1 messages and
  reports the missing capabilities.
- Capability gates: `exec` covers everything as powerful as a shell (jobs,
  process kill, file access outside Desktop/Downloads, launch, deploy,
  environment changes) and stays behind `--allow-exec`. `ui` and `events` give
  a client nothing beyond what screenshots and input already allow, and are
  always on.

### Control protocol changes

- Two lanes per connection, replies matched by `id`. Input, screenshot,
  status and wait operations keep running in arrival order, so a pipelined
  click-then-screenshot stays ordered. Shell, process and file operations run
  concurrently beside that lane. Input for one VM is serialized across
  connections.
- New operations mirror the MCP tools below, `vm.<group>.<verb>`.
- Action operations accept `observe` and return an `observation` object.

### FrameSource

`AlcoveControl` maps the shared framebuffer named by the display `switch`
message read-only and serves BGRA frames from memory: crop, scale, PNG/JPEG
encode, tile hashing for change detection. `screendump` remains the fallback
when no surface is mapped. Idle detection and diffing compare tile hashes,
because ramfb marks the whole frame dirty on every refresh.

### Observation object

Returned by every action tool. `observe` selects the level:

| `observe` | Content |
|---|---|
| `none` | nothing; returns immediately |
| `summary` (default) | settled or not, changed rectangle, foreground window title, focused element, guest events since the previous call |
| `diff` | `summary` plus a crop of the changed rectangle |
| `image` | `summary` plus the full frame |
| `ui` | `summary` plus the UI tree of the foreground window |

Settle rule: wait until tile hashes are stable for 300 ms, at most 2 s;
both are parameters.

### UI references

`ui.tree` assigns short refs (`e12`) bound to UI Automation runtime ids. A ref
is valid until the element goes away; a stale ref returns an error that asks
for a new tree. Scripts use selectors instead of refs:
`{window, role, name, automation_id, index}`.

Tree text format, one element per line, indentation for depth:

```
[e3] Window "Chatbot" (120,80 1024x720)
  [e7] Edit "Message" (140,730 860x40) focused
  [e8] Button "Send" (1010,730 96x40)
  [e9] Document "Transcript" (140,120 966x590) text=1843 chars
```

Defaults: named or interactive elements only, depth 12, 300 nodes, a
truncation line when cut.

## Tool catalog

Existing 16 tools keep their names and defaults except where marked
*extended*. Toolsets can be limited with `ALCOVE_MCP_TOOLSETS`
(`core,shell,files,state,ui,evidence,replay,http`; default all). The MCP
server `instructions` describe the recommended loop: doctor, restore snapshot,
deploy, act with `observe`, wait, collect.

### AT1 — shell, processes, files

| Tool | Purpose |
|---|---|
| `alcove_exec` *extended* | adds `cwd`, `env`, `stdin`, `shell` (`powershell`, `cmd`, `none` with argv); returns `stdout`, `stderr`, `code`, `timed_out`; a timeout kills the process tree |
| `alcove_exec_start` | start a background job, returns `job` |
| `alcove_exec_read` | output since an offset or the last N lines, plus state and exit code |
| `alcove_exec_write` | write to a job's stdin |
| `alcove_exec_kill` | kill a job's process tree |
| `alcove_exec_list` | jobs with state, pid, start time, command |
| `alcove_process_list` | pid, name, path, command line, memory, CPU time; filter by name |
| `alcove_process_kill` | by pid or name, optional tree |
| `alcove_push_file` *extended* | adds `guest_path` and `overwrite` |
| `alcove_pull_file` | guest file to a host path |
| `alcove_sync_dir` | host directory to guest directory, sends only files whose size or SHA-256 differ, optional delete of extras |
| `alcove_fs_list` | entries with size and mtime; also answers "does this exist" |
| `alcove_fs_read` | text file by byte range or last N lines |
| `alcove_fs_write` | write or append a text file |
| `alcove_fs_delete` | file or directory |

### AT2 — VM state and plumbing

| Tool | Purpose |
|---|---|
| `alcove_pause_vm`, `alcove_resume_vm` | existing control ops as tools |
| `alcove_snapshot_list` / `_create` / `_restore` / `_delete` | engine snapshots; restore reconnects the agent and resyncs the guest clock |
| `alcove_clone_vm` | linked clone on a qcow2 overlay with a new token, MAC and ports; the source becomes a template that cannot start while clones exist |
| `alcove_delete_vm` | only VMs created by `alcove_clone_vm` |
| `alcove_start_vm` *extended* | `discard_changes` runs on a throwaway overlay |
| `alcove_lease_acquire`, `alcove_lease_release` | exclusive input for one client with a TTL; other clients keep read-only access |
| `alcove_port_forward_add` / `_remove` / `_list` | runtime host-to-guest TCP forwards on loopback |
| `alcove_set_network` | link up or down |
| `alcove_set_resolution` | guest display mode through the agent |
| `alcove_set_environment` | theme, time zone, clock, locale, keyboard layout, DPI scale; implemented as host-side recipes over `exec` |
| `alcove_doctor` | host engine and control host, VM state, agent version and capabilities, exec allowed, session logged in or locked, resolution and scale, free disk, clock skew, network reachability, each with a hint |

### AT3 — frames and smart actions

| Tool | Purpose |
|---|---|
| `alcove_screenshot` *extended* | `region`, `window`, `scale`, `format` (png/jpeg), `marks` (numbered boxes for UI elements, available from AT4) |
| `alcove_find_text` | host OCR over the frame or a region; returns matches with rectangles |
| `alcove_wait_for` | first of several conditions: `screen_idle`, `region_changed`, `text_visible` (OCR), `process_exited`, `process_started`, `file_exists`, `port_listening`, `log_matches`, `job_output_matches`; AT4 adds `ui_exists`, `ui_gone`, `ui_enabled`, `window_title`, `ui_text_stable` |
| `alcove_batch` | ordered list of action and wait steps, stops at the first failure, one observation at the end |
| `alcove_mouse_down`, `alcove_mouse_up`, `alcove_key_down`, `alcove_key_up` | low-level holds |
| click, move, drag, scroll, type, press keys *extended* | `observe`, `settle_ms`, `settle_timeout_ms` |

### AT4 — UI Automation

| Tool | Purpose |
|---|---|
| `alcove_list_windows` | title, pid, process name, rectangle, state, foreground, responding |
| `alcove_window_action` | focus, move, resize, minimize, maximize, restore, close |
| `alcove_ui_tree` | tree of a window or a subtree, with filters |
| `alcove_ui_find` | elements by name, role, automation id, text |
| `alcove_ui_get_text` | full text of an element through the text or value pattern, with range paging |
| `alcove_ui_click`, `alcove_ui_type` | resolve the element rectangle, scroll it into view, then send hypervisor input |
| `alcove_ui_action` | pattern calls without input: invoke, toggle, expand, collapse, select, set value, focus, scroll into view |
| `alcove_launch_app` | start an executable with args, cwd and env, return pid and the first window once it appears |
| `alcove_deploy` | sync or push the artifact, optional silent install (msi or exe with arguments), launch, wait for the window |
| `alcove_events` | guest events since a cursor: window opened/closed, foreground changed, dialog shown, watched process exited |

`ui_text_stable` waits until an element's text has not changed for a quiet
period; it is the wait for a streamed chatbot answer.

For an embedded-Chromium app the same loop uses `alcove_launch_app` with a
remote debugging port and `alcove_port_forward_add`; a browser automation
client on the Mac then attaches to the forwarded port.

### AT5 — evidence

| Tool | Purpose |
|---|---|
| `alcove_record_start`, `alcove_record_stop` | H.264 video from the frame source plus a JSONL trace of every control op with timestamps and before/after frames, written to a host directory |
| `alcove_event_log` | Windows event log query by log, level, provider and time |
| `alcove_crash_dumps` | enable local dumps for an executable, list dumps, pull one |
| `alcove_collect_diagnostics` | one host directory with a screenshot, window list, UI tree, process list, event log slice, job output, chosen app log files, dumps and the trace |

### AT6 — replay

| Tool | Purpose |
|---|---|
| `alcove_script_save` | turn a trace range into a script: control ops with selectors in place of refs and coordinates, plus expectations taken from the recorded observations |
| `alcove_script_run` | run a script with variables; stops at the first failed step and returns its observation |

`alcovectl run-script <file>` runs the same scripts with no model, for
regression runs.

### AT7 — HTTP capture and fault injection

| Tool | Purpose |
|---|---|
| `alcove_http_capture_start`, `alcove_http_capture_stop` | host-side intercepting proxy; the agent sets the guest proxy and trusts the proxy CA |
| `alcove_http_requests` | captured exchanges: method, URL, status, timing, headers, bodies with paging |
| `alcove_http_rule` | per-host or per-path rules: fixed response, status code, delay, connection drop |

This group was not in the ideation list; it is proposed because the target
app is a model-API client and its failures are mostly in that traffic.

## Sub-projects

Each ends in something usable and gets its own implementation plan.

| ID | Scope | Done when |
|---|---|---|
| AT1 | agent protocol v2, concurrent control server, shell, processes, files | a long job streams output while screenshots and a second exec keep working; a directory round-trips host→guest→host with matching digests |
| AT2 | snapshots, clones, leases, port forwards, link, environment, doctor | a script restores a snapshot, runs a command and restores again with the agent reconnected each time; a guest TCP server is reachable from the Mac through a forward added at runtime |
| AT3 | FrameSource, observation object, batch, wait_for, OCR, extended screenshot | a click returns a summary with the changed rectangle in one call; `find_text` locates Korean and English labels on the fixture app |
| AT4 | windows, UI tree, UI actions, launch, deploy, events | on the fixture app: find the input by name, type, click Send by ref, wait with `ui_text_stable`, read the transcript text |
| AT5 | recording, trace, event log, crash dumps, diagnostics bundle | a forced crash of the fixture app yields a bundle with the dump, the event log entry and a video of the last steps |
| AT6 | script format, save, run, `alcovectl run-script` | a saved script of the AT4 scenario passes three runs from a restored snapshot with no model |
| AT7 | proxy, capture, rules | a fixture HTTPS call is listed with its body, and a rule turns it into a 429 that the app shows |

Order: AT1 → AT2 → AT3 → AT4 → AT5 → AT6 → AT7. AT1 is required by all;
AT3 and AT4 are independent of AT2; AT6 needs AT4 and AT5.

## Error handling

- Errors stay plain strings that name the next step, as in
  `docs/control-protocol.md:48-49`.
- A stale UI ref, a missing capability, a lease held by another client, a
  locked session and an elevated window that the agent cannot inspect each
  have a distinct message.
- A snapshot restore invalidates jobs, UI refs and the event cursor;
  operations that use them afterwards say so.
- Text results are capped (default 60 000 characters) with an explicit
  truncation line and a paging parameter.

## Testing strategy

- Go: table tests for the v2 dispatcher, jobs, file transfer and sync in
  `guest-tools/internal/server`; Windows-only code behind build tags with
  fakes for the UI Automation layer.
- Swift: `ControlHandlerTests` with a fake `VMTarget` and fake agent for every
  new op; `FrameSource` tests against synthetic frames; trace and script
  runner tests.
- MCP: `node --test` for argument mapping and toolset selection.
- Fixture app: a small Win32 window written in Go without cgo
  (`GOOS=windows GOARCH=arm64`) with a text box, a Send button, a transcript
  that streams text on a timer, a Korean label, an HTTPS request button, a
  crash button and a hang button. End-to-end scripts in `scripts/test/` drive
  it through the control socket, in the style of `mcp-smoke.py`.

## Needs verification

Each item is the first task of the sub-project that depends on it.

| Item | Sub-project |
|---|---|
| The Go agent does not call the UI Automation COM interfaces: it starts a helper (C# that Windows PowerShell 5.1 compiles in memory at every start, .NET Framework UI Automation) as a child process and passes the `win.*` and `ui.*` requests to it one at a time (`docs/agent-protocol.md`). Measured through the control server on Windows 11 ARM64 (build 26200), debug build of `alcovectl`: `vm.window.list` 4 ms, `vm.ui.tree` 22 ms for a window of 25 elements and 198 ms for a File Explorer window of 166, `vm.ui.find` 20 ms in the small window, 141 ms without a match in File Explorer and 6.9 s to 7.4 s without a match in the Services console (1,646 elements); a helper that was ended is replaced by the next request in 1.35 s to 1.39 s. `scripts/test/at4-e2e.py` passes its 16 checks on that guest (`docs/superpowers/plans/2026-10-13-at4-results.md`) | AT4 |
| Edge 155 (Chromium) exposes its page to UI Automation without a setting: for a page from a `data:` URL in an Edge with a profile folder of its own, `vm.ui.find` by name returned the page's button and its input (named by `aria-label`) 2.5 s to 3.3 s after `vm.app.launch`, `vm.ui.type` filled the input, `vm.ui.click` pressed the button, and the window's tree has 27 elements with the `interactive` filter. Electron and WebView2 apps were not run | AT4 |
| After QMP `snapshot-load`, a connection to the agent that was open before the load stays open on the host and never answers again (no reply to `ping` within 12 s, no close); a new connection receives `hello` at once. The guest clock continues from the snapshot's time, behind the host by the snapshot's age (17 s to 53 s in the runs), until it is set. `vm.snapshot.restore` drops its agent connection, connects again and sets the clock: 5 s to 11 s for the whole op with 6 GiB of guest memory, guest clock within 1.1 s of the host afterwards. Runtime port forwards keep working. Measured with Windows 11 ARM64 on an NVMe disk, which needs `qemu-patches/0002` for the load itself | AT2 |
| A DPI scale change through `SPI_SETLOGICALDPIOVERRIDE` applies without signing out on Windows 11 ARM64: the taskbar is redrawn at the new scale at once, a DPI-aware process started afterwards reads the new system DPI (120 after 125 %), and `GetDpiForWindow` of windows that were already open reports it too. `HKCU\Control Panel\Desktop\WindowMetrics\AppliedDPI` keeps the sign-in value | AT2 |
| Encoding video from `alcovectl serve` without a window server session | AT5 |
| Installing a proxy CA and system proxy from the agent so that the target app's HTTP stack honours them | AT7 |
| The helper inherits the agent's elevated token (high integrity, level 0x3000) and reads the windows of elevated processes: the tree of a Notepad the agent started (0x3000) has 36 elements and its text is returned, and the Services console (`mmc.exe`) and the fixture app are read the same way, as are windows at medium integrity (File Explorer, 0x2000). A launch by the agent raises no UAC prompt. No window of a higher integrity level than the agent's existed on the guest's desktop, so reading above the agent's level and the secure desktop are not observed | AT4 |
