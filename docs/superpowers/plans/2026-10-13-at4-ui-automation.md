# AT4 — UI Automation: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A coding agent finds controls of a Windows app by name, reads their text, acts on them and waits on them, all as text, and gets an app from a Mac build directory to a visible window in one call.

**Architecture:** The Windows agent starts one hidden `powershell.exe` child that compiles an embedded C# file with `Add-Type` and runs its request loop; the C# code uses the managed UI Automation client (`System.Windows.Automation`). The Go agent forwards `win.*` and `ui.*` requests to it and re-emits its events. Mouse and keyboard still go through the hypervisor: the host asks the guest for an element's rectangle and clicks there. `AlcoveControl` adds window, UI, launch, deploy and event ops and feeds UI facts into observations and waits.

**Tech Stack:** Go 1.22 language level without external modules; C# 5 (the compiler behind `Add-Type` on .NET Framework 4.8) with `UIAutomationClient`, `UIAutomationTypes`, `WindowsBase`; Swift 6; TypeScript MCP server; Python 3 standard library for end-to-end scripts.

**Spec:** `docs/superpowers/specs/2026-10-13-ai-testing-tools-design.md`

## Global Constraints

- The C# helper compiles with C# 5: no string interpolation, no `?.`, no expression-bodied members, no `nameof`, no tuples.
- `guest-tools/go.mod` stays without `require` lines; Windows-only code sits behind `//go:build windows` with a stub for other systems so `go vet ./...` and `go test ./...` pass on macOS.
- UI ops need capability `ui` (Windows agents only). `app.launch` needs `--allow-exec`. Other guests answer `UI Automation is only available on Windows guests`.
- Input for `ui_click` and `ui_type` goes through the display protocol, never through UI Automation patterns. Pattern calls happen only in `ui.act`.
- Rectangles are guest pixels of the full frame.
- A ref is `e<number>`, stable for one element while it exists (keyed by its runtime id). A ref whose element is gone answers `element <ref> no longer exists; call ui.tree again`.
- Selector object: `{window?, role?, name?, nameContains?, automationId?, index?}`; `role` is the control type name without the `ControlType.` prefix, compared case-insensitively; `window` is a window id, `foreground`, or a title substring. No match → `no element matches <selector as JSON>; call ui.tree to see what exists`.
- Error strings are plain sentences that name the next step.
- Comments, test names and test comments describe what the code does now. No history, rationale, measurements or review notes in code.
- Code, identifiers and repository docs are English.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01SKM8m5iFzR5Kkhm3MsJdU1
  ```
- Work happens on branch `ai-testing-tools` in `/Users/giraffewithcode/dev/personal/alcove`. Commit only the files of the task. Do not push.

## Review Focus

1. The helper process dies or hangs mid-request: the pending request fails with a clear error within its timeout, the next request starts a fresh helper, and refs issued by the dead helper answer the stale-ref error (Task 1 `TestHelperRestartsAfterExit`, `TestHelperTimeoutKillsAndRestarts`).
2. A window with thousands of elements: `ui.tree` stops at `max`, says it was truncated and returns within the request timeout (Task 2 VM check on File Explorer in `C:\Windows\System32`).
3. An element that is off screen or has an empty rectangle: `ui_click` scrolls it into view first and refuses with the reason when it still has no clickable point (Task 4 `testUIClickRefusesOffscreen`).
4. Text with Korean characters, quotes and newlines in names, values and typed input: it survives the C#/Go/Swift/TypeScript hops unchanged (Task 2 VM check, Task 6 check 3).
5. The app under test closes while a wait or text read is in flight: the call ends with the stale-ref or no-match error instead of hanging (Task 4 `testTextStableEndsWhenElementGone`).

---

## Helper contract (Tasks 1–3)

The helper reads one JSON object per line on stdin and writes one per line on stdout, UTF-8 without BOM. Request `{"id":n,"op":"...",...}` → `{"id":n,"ok":true,...}` or `{"id":n,"ok":false,"error":"..."}`. Events `{"ev":"<name>",...}`. Agent ops carry the same names and fields; the agent passes them through.

Node object: `{ref, depth, role, name, value?, aid?, x, y, w, h, flags: [..]}` with flags from `focused`, `disabled`, `offscreen`, `selected`, `checked`, `expanded`, `collapsed`, `password`. `value` is the value-pattern value (omitted for password fields), cut at 200 characters with `…`.

Window object: `{id, title, pid, process, class, x, y, w, h, state: "normal"|"minimized"|"maximized", foreground, responding, modal}`; `id` is the native window handle as `0x<hex>`.

| op | params | result |
|---|---|---|
| `win.list` | — | `windows` (top-level windows that are visible or minimized and have a title or are the foreground window) |
| `win.action` | `window`, `action` (`focus`, `minimize`, `maximize`, `restore`, `close`, `move`, `resize`), `x`, `y`, `w`, `h` | `window` (after the action) |
| `ui.tree` | `window` (default `foreground`), `root?` (ref), `depth?` (default 12), `max?` (default 300, cap 2000), `filter?` (`interactive` default: elements with a name, a value or a keyboard-focusable/invokable control type; `all`) | `window`, `nodes`, `truncated` |
| `ui.find` | selector fields, `limit?` (default 20) | `nodes` (depth 0) |
| `ui.text` | `ref` or selector fields, `mode?` (`auto` default, `pattern`, `descendants`), `offset?`, `length?` (default and cap 200000) | `text`, `total`, `source` (`text`, `value`, `name`, `descendants`) |
| `ui.rect` | `ref` or selector fields, `scroll?` (bool: scroll into view first) | `node`, `cx`, `cy`, `clickable` (bool) |
| `ui.act` | `ref` or selector fields, `action` (`invoke`, `toggle`, `expand`, `collapse`, `select`, `set_value`, `focus`, `scroll_into_view`), `value?` | `node` (after the action) |
| `ui.focused` | — | `node`, `window` |

`ui.text` in `auto` mode uses the text pattern's document range, then the value pattern, then, when the element has descendants, their names joined by newlines in tree order (text, list item, edit and document elements), then the element name.

Events (the helper compares the window list every 300 ms): `window.opened`, `window.closed`, `window.foreground`, `window.title` — each with the window object; `dialog.opened` in addition for a window that is modal or of class `#32770`.

---

### Task 1: Helper process manager in the agent

**Files:**
- Create: `guest-tools/internal/uia/helper.go` (process manager, portable), `helper_test.go`, `launch_windows.go` (command line and embedded files), `launch_other.go` (`//go:build !windows`, reports unavailable), `assets/bootstrap.ps1`, `assets/helper.cs` (a minimal loop answering `ping` in this task)
- Modify: `guest-tools/internal/server/rpc.go` (`registerUI`), `server.go` (cap `ui`, `Options.UI`), `guest-tools/cmd/alcove-agent/main.go` (wire the helper)

**Interfaces:**
- Produces:
  ```go
  package uia
  // Launcher starts the helper child and returns its pipes.
  type Launcher func() (stdin io.WriteCloser, stdout io.ReadCloser, kill func(), err error)
  type Helper struct{ /* ... */ }
  func New(launch Launcher, onEvent func(name string, fields map[string]any)) *Helper
  // Call sends one request and waits for its reply; starts or restarts the child as needed.
  func (h *Helper) Call(op string, params map[string]any, timeout time.Duration) (map[string]any, error)
  func (h *Helper) Close()
  // Available reports whether this build can start a helper.
  func Available() bool
  // DefaultLauncher writes the embedded files below dir and starts powershell.exe hidden.
  func DefaultLauncher(dir string) Launcher
  ```
  `server.Options.UI` is an interface `{ Call(op string, params map[string]any, timeout time.Duration) (map[string]any, error) }`; nil means no `ui` capability. `registerUI` registers the eight helper ops ungated and passes params through with a 20 s timeout (`ui.tree` and `ui.text` 30 s).
- Bootstrap: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <dir>\bootstrap.ps1`; the script loads `helper-<sha256 prefix>.dll` next to it when present, otherwise compiles `helper.cs` with `Add-Type -OutputAssembly` to that name, then calls `[Alcove.UiaHelper]::Run()`. Files live in `%ProgramData%\Alcove\uia`.
- A request that times out kills the child; the next call starts a new one. A child that exits fails every pending request with `UI helper exited; retry`.

- [ ] **Step 1: Write failing tests** with a fake launcher backed by in-process pipes and a goroutine that plays the helper: `TestCallRoundTrip`; `TestConcurrentCallsMatchedByID`; `TestErrorReply`; `TestEventsReachCallback`; `TestHelperRestartsAfterExit`; `TestHelperTimeoutKillsAndRestarts`; `TestLaunchFailureIsReported` (error names PowerShell); `TestCloseStopsChild`; in `server`: `TestUIOpsPassThrough` (fake `Options.UI`), `TestNoUICapWithoutHelper` (`ui.tree` → `UI Automation is only available on Windows guests`).
- [ ] **Step 2: Run** `cd guest-tools && go test ./...` — fails.
- [ ] **Step 3: Implement.** Verify in the VM: build the Windows agent, install it with `python3 scripts/test/install-agent.py`, and call `ping` through the helper with `python3 scripts/test/ctl.py`-level access (`vm.exec` cannot reach agent ops; use a short Python snippet over the agent port from `config.json` as `scripts/test/agent-windows.py` does). Record the cold and warm start times in the report.
- [ ] **Step 4: Run** `cd guest-tools && go vet ./... && go test ./... && GOOS=windows GOARCH=arm64 go vet -unsafeptr=false ./... && GOOS=linux GOARCH=arm64 go vet ./...`.
- [ ] **Step 5: Commit** `git commit -m "Agent: UI helper process manager"`.

### Task 2: Helper — windows, tree, find, text, rect

**Files:**
- Modify: `guest-tools/internal/uia/assets/helper.cs`
- Create: `scripts/test/uia-helper-check.py` (drives the agent's `win.*`/`ui.*` ops over the agent port against Notepad and File Explorer, prints PASS/FAIL per check)

**Interfaces:**
- Produces: `win.list`, `ui.tree`, `ui.find`, `ui.text`, `ui.rect`, `ui.focused` of the helper contract; refs and selectors per Global Constraints.

- [ ] **Step 1: Write `uia-helper-check.py` first** (it fails against the Task 1 helper):
  1. Start Notepad with a file containing `first line`, `둘째 줄 "quoted"`; `win.list` contains a window whose title includes the file name, `foreground` or not, with a non-empty rectangle inside 0..frame.
  2. `ui.tree window=<notepad id>` → a `Document` or `Edit` node; node count ≤ 300; refs are `e<number>`; calling again yields the same ref for that element.
  3. `ui.text` of that node → both lines exactly; with `offset: 6, length: 4` → `line`.
  4. `ui.find` `{window, role: "MenuItem", name: "File"}` → one node; `ui.rect` of it → `clickable == true` and the centre inside the window rectangle.
  5. Close Notepad; `ui.text` with the old ref → the stale-ref error.
  6. Open File Explorer on `C:\Windows\System32`; `ui.tree max=300 filter=all` → `truncated == true` and an answer within 30 s; `ui.find` with `nameContains: "notepad"` and `limit: 5` → at least one node.
  7. `ui.focused` → a node and a window.
- [ ] **Step 2: Implement** the helper ops. Walk with `TreeWalker.ControlViewWalker` (filter `all` uses `RawViewWalker`), breadth limited by `max`, depth by `depth`; cache requests are optional. Wrap every element access in handling for `ElementNotAvailableException`.
- [ ] **Step 3: Run** build + install + `python3 scripts/test/uia-helper-check.py` until seven PASS lines; then the Go suite of Task 1 Step 4.
- [ ] **Step 4: Commit** `git commit -m "Agent: UI helper reads windows, element trees and text"`.

### Task 3: Helper — actions and events; app launch; fixture app

**Files:**
- Modify: `guest-tools/internal/uia/assets/helper.cs` (`win.action`, `ui.act`, event thread)
- Create: `guest-tools/internal/server/launch.go` (`app.launch`, process watcher), `launch_test.go`
- Create: `guest-tools/cmd/alcove-fixture/main_windows.go`, `main_other.go`
- Modify: `guest-tools/internal/server/rpc.go`, `scripts/test/uia-helper-check.py`, `scripts/test/all.sh` (build the fixture to `build/alcove-fixture-windows-arm64.exe`)

**Interfaces:**
- Produces: `win.action`, `ui.act` and the events of the helper contract. Agent op `app.launch` (gated): `path`, `args?` ([string]), `cwd?`, `env?`, `wait_window_ms?` (default 15000, 0 skips the wait) → `{pid, window?}`; the process starts with a normal window; when it exits the agent emits `process.exited {pid, code, path}`. The window is the first top-level window whose `pid` is the process or one of its descendants.
- Fixture app `alcove-fixture.exe` (Win32 through `syscall`, window title `Alcove Fixture`, 720×520):
  - static `Message` followed by an edit control, button `Send`;
  - static `Transcript` followed by a read-only multi-line edit; `Send` appends `You: <message>\r\n`, then `Bot: ` and the reply `echo <message> ` repeated to 30 words, one word every 80 ms, then `\r\n[done]\r\n`;
  - static `한글 라벨`;
  - button `Dialog` (a message box titled `Fixture Dialog` with text `Dialog body`);
  - button `Crash` (calls `RaiseFailFastException`), button `Hang` (sleeps 60 s on the UI thread);
  - button `Fetch` (HTTPS GET of the URL in `--url`, default `https://example.com/`, on a goroutine; appends `Fetch: <status code or error>`);
  - `--log <path>` appends one line per action to a file.

- [ ] **Step 1: Write failing tests.** Go: `TestLaunchStartsProcessAndReportsExit` (launch `sh -c "exit 3"` with `wait_window_ms: 0` → pid, then a `process.exited` event with `code == 3`); `TestLaunchGated`; `TestLaunchMissingPath` (error names the path). Extend `uia-helper-check.py`:
  8. `app.launch` the fixture (pushed to `C:\alcove-e2e\alcove-fixture.exe`) → `window.title == "Alcove Fixture"`; a `window.opened` event arrived.
  9. `ui.act set_value` on `{role: "Edit", name: "Message"}` with `안녕 "fixture"`; `ui.act invoke` on `{role: "Button", name: "Send"}`; poll `ui.text` of `{role: "Edit", name: "Transcript"}` until it contains `[done]`; it contains `You: 안녕 "fixture"`.
  10. `ui.act invoke` on `Dialog` → a `dialog.opened` event with title `Fixture Dialog`; `win.action close` on it → `window.closed`.
  11. `win.action` `minimize`, `restore`, `move` to (40, 40), `resize` to 800×600, `focus` → the returned window object reflects each step; after `focus`, `foreground == true`.
  12. `ui.act invoke` on `Hang` → within 10 s `win.list` reports `responding == false` for the fixture; `proc.kill` it → `process.exited` event.
- [ ] **Step 2: Run** `cd guest-tools && go test ./...` — the new Go tests fail.
- [ ] **Step 3: Implement.** Bring a window to the foreground with `SetForegroundWindow`, falling back to the documented attach-input sequence when it returns false; verify in the VM.
- [ ] **Step 4: Run** the Go suite of Task 1 Step 4, build agent and fixture, install, `python3 scripts/test/uia-helper-check.py` → twelve PASS lines.
- [ ] **Step 5: Commit** `git commit -m "Agent: UI actions, window events, app launch; fixture app"`.

### Task 4: Control operations for windows, UI, launch, deploy and events

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/EventBuffer.swift`, `ControlHandler+UI.swift`, `ControlHandler+Deploy.swift`, `UITreeText.swift`, `AlcoveKit/Tests/AlcoveControlTests/ControlUITests.swift`, `EventBufferTests.swift`
- Modify: `VMTarget.swift` (`events(since:)`; `ControllerTarget` consumes its agent client's events into the buffer), `ControlHandler.swift` (dispatch, `knownOps`, read-only classification), `Observation.swift` (UI fields), `ControlHandler+Wait.swift` (UI conditions), `ControlHandler.swift` `vm.screenshot` (`window`, `marks`), `Frame.swift` (`drawingMarks`)

**Interfaces:**
- Consumes: agent ops of Tasks 1–3 through `AgentClient.call`; `Frame`, observation and wait machinery of AT3; `syncDirectory`/`pushFile` of AT1.
- Produces:
  ```swift
  struct GuestEvent: Sendable, Equatable { let seq: Int; let time: Date; let name: String; let payload: JSON }
  actor EventBuffer {            // keeps the newest 500 events
      func append(name: String, payload: JSON, at: Date)
      func since(_ seq: Int) -> (events: [GuestEvent], next: Int)
  }
  enum UITreeText {
      /// One line per node: indentation by depth, `[ref] Role "name" (x,y WxH) flags`, value as `value="..."`.
      static func render(_ nodes: [JSON]) -> String
  }
  // VMTarget
  func events(since seq: Int) async -> (events: [GuestEvent], next: Int)
  ```
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.window.list` | `name` | `{windows}` |
| `vm.window.action` | `name`, `window`, `action`, `x?`, `y?`, `width?`, `height?` | `{window}` |
| `vm.ui.tree` | `name`, `window?`, `root?`, `depth?`, `max?`, `filter?` | `{tree (text), count, truncated, window}` |
| `vm.ui.find` | `name`, selector fields, `limit?` | `{nodes, text}` |
| `vm.ui.text` | `name`, `ref?` or selector, `mode?`, `offset?`, `length?` | `{text, total, source}` |
| `vm.ui.click` | `name`, `ref?` or selector, `button?`, `count?`, observe params | `{x, y, node, observation?}` — `ui.rect` with `scroll: true`, then the click of `vm.mouse.click` |
| `vm.ui.type` | `name`, `ref?` or selector, `text`, `clear?` (ctrl+a first), `submit?` (enter after), observe params | `{node, observation?}` — clicks the element, then types as `vm.type` does |
| `vm.ui.action` | `name`, `ref?` or selector, `action`, `value?`, observe params | `{node, observation?}` |
| `vm.app.launch` | `name`, `path`, `args?`, `cwd?`, `env?`, `waitWindow?` s | `{pid, window?}` |
| `vm.deploy` | `name`, `path` (host file or directory), `guestDir?` (default `C:\alcove-apps\<base name>`), `install?` (`{kind: "msi"|"exe", file, args?}`), `launch?` (`{exe, args?, env?, cwd?}`), `waitWindow?` s (default 20), `killRunning?` (default true) | `{guestDir, sent, skipped, bytes, installCode?, pid?, window?}` |
| `vm.events` | `name`, `since?` | `{events: [{seq, time, name, ...payload}], next}` |

  - `vm.ui.click` on an element that is not clickable after scrolling → `element <ref> has no clickable point (off screen or covered); use vm.ui.action or scroll it into view`.
  - `vm.deploy`: with `killRunning`, processes whose path lies under `guestDir` are killed first; a directory is synced with deletion of extras, a file is pushed with overwrite; `install` runs `msiexec /i <file> /qn /norestart` or the executable with `args` and fails the call on a non-zero code (3010 counts as success); `launch.exe` is relative to `guestDir` unless absolute.
  - Observations gain `foreground` (title), `focused` (`Role "name"`) and `events` (names with window titles since the previous observation of that VM) when the agent has `ui`; level `ui` adds `tree` (text of the foreground window, 150 nodes).
  - `vm.wait_for` gains `ui_exists`, `ui_gone`, `ui_enabled` (selector fields), `window_title` (`contains` or `regex`), `ui_text_stable` (`ref` or selector, `quietMs` default 1500; `detail` is the final text length; ends with the stale-ref error text in `detail` and `matched` unset when the element disappears), `event` (`event` name, optional `titleContains`).
  - `vm.screenshot` gains `window` (crops to that window's rectangle) and `marks` (bool: draws numbered rectangles over the interactive elements of the foreground or given window and returns `marks: [{n, ref, role, name, x, y, w, h}]`).

- [ ] **Step 1: Write failing tests** with a fake agent answering the helper ops from fixtures: `EventBufferTests` (sequence numbers, `since`, cap at 500); `testUITreeTextRendering` (indentation, flags, value, quotes escaped); `testWindowListAndAction`; `testUITreeOp`; `testUIFindOp`; `testUITextPaging`; `testUIClickUsesRectCentre` (display messages carry the scaled centre; `scroll: true` sent); `testUIClickRefusesOffscreen`; `testUITypeClearsAndSubmits` (key sequence order); `testUIActionPassesValue`; `testAppLaunch`; `testDeployDirectorySyncsThenLaunches` (call order: kill, sync, launch); `testDeployInstallFailureStops`; `testEventsOp`; `testObservationCarriesUIFacts`; `testWaitUIExistsGoneEnabled`; `testWaitWindowTitle`; `testTextStableWaitsForQuiet` (text grows over three polls, then stays); `testTextStableEndsWhenElementGone`; `testWaitEvent`; `testScreenshotWindowCrop`; `testScreenshotMarksReturnsLegend`; `testUIOpsOnOldAgent` (no `ui` cap → message naming Windows guests and the agent update).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: windows, UI tree and actions, launch, deploy, guest events"`.

### Task 5: MCP `ui` toolset

**Files:**
- Create: `mcp/src/tools/ui.ts`, `mcp/src/selector.ts`, `mcp/src/selector.test.ts`
- Modify: `mcp/src/tools/core.ts` (`alcove_screenshot` `window`, `marks`; `observe` accepts `ui`), `mcp/src/tools/actions.ts` (wait condition types), `mcp/src/observation.ts`, `mcp/src/index.ts`, `scripts/test/mcp-smoke.py`

**Interfaces:**
- Produces: `selectorParams` (zod shape `ref`, `window`, `role`, `name`, `name_contains`, `automation_id`, `index`) and `toControlSelector(args)` mapping to camelCase and refusing a call with neither `ref` nor any selector field (`pass ref or at least one of role, name, name_contains, automation_id`).
- Tools (toolset `ui`): `alcove_list_windows`, `alcove_window_action`, `alcove_ui_tree`, `alcove_ui_find`, `alcove_ui_get_text`, `alcove_ui_click`, `alcove_ui_type`, `alcove_ui_action`, `alcove_launch_app`, `alcove_deploy`, `alcove_events`. All toolsets together list 64 tools.
- `alcove_list_windows` text: one line per window `<id> "<title>" <process> (pid) x,y WxH [foreground] [minimized] [NOT RESPONDING]`. `alcove_ui_tree` text is the control result's `tree` plus a truncation line. Observation text gains `foreground: <title>`, `focused: <Role "name">` and `events: ...` lines.
- The server `instructions` gain: read with `alcove_ui_tree` before taking screenshots; act with `alcove_ui_click`/`alcove_ui_type`; wait for streamed output with `alcove_wait_for` `ui_text_stable`.

- [ ] **Step 1: Write failing tests** in `selector.test.ts`: mapping, the refusal, `ref` alone accepted.
- [ ] **Step 2: Run** `cd mcp && npm run build && npm test` — fails.
- [ ] **Step 3: Implement.** Update `mcp-smoke.py` expectations.
- [ ] **Step 4: Run** `cd mcp && npm run build && npm test && cd .. && python3 scripts/test/mcp-smoke.py --list-only && ALCOVE_MCP_TOOLSETS=core python3 scripts/test/mcp-smoke.py --list-only` — PASS.
- [ ] **Step 5: Commit** `git commit -m "MCP: ui toolset"`.

### Task 6: Documentation and end-to-end run

**Files:**
- Modify: `docs/agent-protocol.md`, `docs/control-protocol.md`, `README.md`, spec "Needs verification" rows for AT4
- Create: `scripts/test/at4-e2e.py`, `docs/superpowers/plans/2026-10-13-at4-results.md`

- [ ] **Step 1: Write `at4-e2e.py`** (control socket, VM `Windows 11`); each check prints `PASS <n> <title>` or exits 1:
  1. `vm.deploy` of a host directory holding `alcove-fixture.exe` with `launch: {exe: "alcove-fixture.exe", args: ["--log", "C:\\alcove-e2e\\fixture.log"]}` → `window.title == "Alcove Fixture"`; a second deploy of the unchanged directory → `sent == []` and the app restarted (new pid).
  2. `vm.ui.tree` → text contains `Edit "Message"`, `Button "Send"`, `한글 라벨`; fewer than 60 lines.
  3. The spec scenario: `vm.ui.type` into `{role: "Edit", name: "Message"}` with text `스트리밍 "테스트" 1`, `vm.ui.click` on `{role: "Button", name: "Send"}` with `observe: "summary"` → observation has `foreground == "Alcove Fixture"`; `vm.wait_for` `ui_text_stable` on the transcript → matched; `vm.ui.text` contains `You: 스트리밍 "테스트" 1` and `[done]`; the fixture log has a `send` line.
  4. `vm.ui.click` on `Dialog` → `vm.wait_for` `event dialog.opened` matched; `vm.window.list` shows `Fixture Dialog`; `vm.window.action close`; `vm.events` since the start contains opened and closed entries in order.
  5. `vm.screenshot window="Alcove Fixture" marks=true` → image size equals the window rectangle; `marks` contains an entry named `Send` whose rectangle lies inside the window.
  6. `vm.ui.click` on `Hang`; within 10 s `vm.window.list` reports `responding == false`; `vm.process.kill`; `vm.wait_for` `event process.exited` matched.
  7. Chromium: `vm.app.launch` `msedge.exe` with a `data:` URL page (title `alcove-edge`, an input with `aria-label="Edge field"`, a button `Edge button`); `vm.ui.find` `{window: "alcove-edge", name: "Edge button"}` → a node; `vm.ui.click` on it succeeds; kill Edge.
  8. Elevated window: `vm.exec.start` `Start-Process notepad -Verb RunAs` is skipped when UAC prompts (detect a `consent.exe` process and press `alt+y` through `vm.key.press`); `vm.ui.tree` of the elevated Notepad returns nodes.
  9. MCP: over stdio call `alcove_ui_tree` and `alcove_list_windows`.
- [ ] **Step 2: Build everything, install the agent, restart the control server.**
- [ ] **Step 3: Run** `python3 scripts/test/at4-e2e.py`; fix through superpowers:systematic-debugging with reproducing unit tests; rerun until nine PASS lines.
- [ ] **Step 4: Write docs and the results file;** update the spec rows on Go-versus-helper, Chromium trees and elevated windows with what was observed.
- [ ] **Step 5: Commit** `git commit -m "AT4: protocol docs and end-to-end run"`.
