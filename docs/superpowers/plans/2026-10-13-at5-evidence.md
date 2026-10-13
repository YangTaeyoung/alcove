# AT5 — evidence: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a test fails, one call leaves a host directory with what happened: a video, a step-by-step trace with frames, guest logs, crash dumps and the UI state.

**Architecture:** `ControlHandler` gets a per-VM `Recording` that, while active, writes every control op to a JSONL trace with before/after frames and feeds a video writer from the frame source. Guest log and dump access are host-side recipes over `exec.run` and the file ops. A collector op gathers everything into one directory.

**Tech Stack:** Swift 6, AVFoundation (`AVAssetWriter`, H.264), CoreGraphics; TypeScript MCP server; Python 3 standard library for end-to-end scripts.

**Spec:** `docs/superpowers/specs/2026-10-13-ai-testing-tools-design.md`

## Global Constraints

- Recordings live in `~/Library/Application Support/Alcove/Recordings/<vm>-<yyyyMMdd-HHmmss>/` unless `dir` is given: `trace.jsonl`, `video.mp4`, `frames/`.
- A trace line is one JSON object: `seq`, `time` (ISO 8601 with milliseconds), `ms` (since the recording started), `op`, `params`, `ok`, `error?`, `result`, `durationMs`, `before?`, `after?` (paths relative to the recording directory). `params` and `result` never contain `lease`, base64 images or strings longer than 2000 characters (cut with `…` and a `truncated` marker field).
- Frames in a trace are JPEG at half size, quality 0.6, written only for action ops (`vm.mouse.*`, `vm.key.*`, `vm.type`, `vm.ui.click`, `vm.ui.type`, `vm.ui.action`, `vm.batch`).
- A recording stops by itself after `maxSeconds` (default 900) and when its VM stops.
- Guest recipes go through `exec.run`; this plan adds no agent ops.
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

1. The guest changes resolution during a recording: the video keeps its first size and later frames are fitted into it; no crash, no torn file (Task 2 `testFramesOfDifferentSizeAreFitted`).
2. The control host exits or the VM stops while recording: the video file is finalized and playable up to that point, the trace has whole lines only (Task 2 `testStopFinalizesFile`, Task 1 `testTraceLinesAreWholeAfterAbruptStop`).
3. A failing op: the trace line carries `ok: false` and the error, and the after-frame is still written (Task 1 `testFailedOpIsTraced`).
4. Secrets in params: lease tokens and `env` values named like secrets (`*KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`) are masked in the trace (Task 1 `testTraceMasksSecrets`).
5. A guest with no matching log entries or no dump folder: empty lists, not errors (Task 3 `testEventLogEmpty`, `testDumpListWithoutFolder`).

---

### Task 1: Trace recorder

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/Trace.swift`, `Recording.swift`, `ControlHandler+Record.swift`, `AlcoveKit/Tests/AlcoveControlTests/TraceTests.swift`
- Modify: `ControlHandler.swift` (wrap `handle` so an active recording sees each op; `vm.record.*` dispatch; `knownOps`; read-only classification for `vm.record.status`)

**Interfaces:**
- Produces:
  ```swift
  struct TraceEntry { /* fields of a trace line */ }
  enum TraceSanitizer {
      /// Removes `lease`, image payloads and long strings; masks secret-looking env values.
      static func sanitize(_ value: JSON) -> JSON
  }
  final class TraceWriter: @unchecked Sendable {
      init(directory: URL) throws
      func append(_ entry: TraceEntry) throws        // one line, flushed
      func writeFrame(_ frame: Frame, name: String) throws -> String   // returns the relative path
      func close()
  }
  actor Recording {
      init(vm: String, directory: URL, fps: Int, video: Bool, maxSeconds: Int, frames: @escaping @Sendable () async -> Frame?)
      func start() throws
      func record(op: String, params: JSON, outcome: Result<JSON, Error>, started: Date, duration: Duration, before: Frame?, after: Frame?)
      func stop() async -> Summary                   // {directory, video?, trace, frames, seconds, ops}
      var isActive: Bool { get }
  }
  ```
- Control ops: `vm.record.start` (`name`, `fps?` 1...30 default 5, `video?` default true, `maxSeconds?`, `dir?`) → `{dir}`; a second start while active → `'<vm>' is already recording to <dir>; call vm.record.stop first`. `vm.record.stop` (`name`) → `{dir, video?, trace, frames, seconds, ops}`. `vm.record.status` (`name`) → `{recording, dir?, seconds?, ops?}`.
- The video part of `Recording` calls a `VideoSink` protocol (`append(frame:at:)`, `finish() async`) that Task 2 implements; this task ships a no-op sink.

- [ ] **Step 1: Write failing tests:** `testSanitizerRemovesLeaseAndImages`; `testSanitizerCutsLongStrings`; `testTraceMasksSecrets`; `testTraceLineShape` (decode the written line; `seq` increases; `ms` non-decreasing); `testActionOpsGetFrames` (files exist, JPEG magic, half size); `testNonActionOpsHaveNoFrames`; `testFailedOpIsTraced`; `testTraceLinesAreWholeAfterAbruptStop` (drop the writer without `close`, every line parses); `testRecordStartStopOps`; `testDoubleStartRefused`; `testRecordingStopsWhenVMStops`; `testMaxSecondsStops` (injected clock).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: op trace with before/after frames"`.

### Task 2: Video

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/VideoRecorder.swift`, `AlcoveKit/Tests/AlcoveControlTests/VideoRecorderTests.swift`
- Modify: `Recording.swift` (uses `VideoRecorder` when `video` is true; samples frames at `fps`)

**Interfaces:**
- Produces: `final class VideoRecorder: VideoSink` — `init(url: URL, width: Int, height: Int, fps: Int) throws`; H.264 in an MP4 container; `append(frame:at:)` fits a frame of another size into the first size preserving aspect on black; `finish()` finalizes the file. Even dimensions are enforced by rounding down.

- [ ] **Step 1: Write failing tests:** `testWritesPlayableFile` (append 15 frames; `AVURLAsset` reports one video track, natural size equal to the first frame, duration within 0.3 s of expected); `testFramesOfDifferentSizeAreFitted`; `testOddDimensionsAreRoundedDown`; `testStopFinalizesFile` (file readable after `finish`); `testRecordingProducesVideo` (through `Recording` with a scripted frame provider).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.** Check once that `alcovectl serve` started from a terminal records (`python3 scripts/test/ctl.py vm.record.start name="Windows 11"`, wait 5 s, `vm.record.stop`, open the file with `ffprobe` or `AVURLAsset` in a Swift snippet) and note the result in the report.
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: H.264 recording of the guest screen"`.

### Task 3: Event log and crash dumps

**Files:**
- Modify: `AlcoveKit/Sources/AlcoveControl/GuestRecipes.swift`, `ControlHandler+Guest.swift`, `ControlHandler.swift`
- Create: `AlcoveKit/Tests/AlcoveControlTests/GuestEvidenceTests.swift`

**Interfaces:**
- Produces recipes `eventLog(log:level:provider:sinceMinutes:contains:max:os:)`, `enableDumps(exe:full:os:)`, `disableDumps(exe:os:)`, `listDumps(os:)`; each prints JSON.
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.event_log` | `name`, `log?` (default `Application`), `level?` (`critical`, `error`, `warning`, `info`; the level and everything more severe), `provider?`, `sinceMinutes?` (default 60), `contains?`, `max?` (default 50, cap 500) | `{entries: [{time, id, level, provider, message}]}` newest first; message cut at 2000 characters |
| `vm.crash_dumps.enable` | `name`, `exe` (image name), `full?` (default false) | `{folder}` — Windows Error Reporting local dumps for that image into `C:\alcove-dumps`, 5 kept |
| `vm.crash_dumps.disable` | `name`, `exe` | `{}` |
| `vm.crash_dumps.list` | `name` | `{dumps: [{file, exe, bytes, time}]}` |
| `vm.crash_dumps.pull` | `name`, `file`, `path` (host) | `{path, bytes, sha256}` |

  Linux: `vm.event_log` reads `journalctl -o json`; the dump ops answer `crash dumps are only collected on Windows guests`.

- [ ] **Step 1: Write failing tests** with a fake agent returning canned recipe output: `testEventLogMapsEntries`; `testEventLogSingleObjectResult` (PowerShell prints one object, not an array); `testEventLogEmpty`; `testEventLogLevelMapping` (level `error` → levels 1 and 2 in the script); `testEnableDumpsWritesKeysForExe` (script text names the image and folder); `testDumpListWithoutFolder`; `testDumpPullUsesFileOps`; `testDumpsOnLinux`.
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement,** trying each recipe once in the running VM through `python3 scripts/test/ctl.py vm.exec ...`.
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: guest event log and crash dump collection"`.

### Task 4: Diagnostics bundle

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/ControlHandler+Diagnostics.swift`, `AlcoveKit/Tests/AlcoveControlTests/DiagnosticsTests.swift`
- Modify: `ControlHandler.swift`

**Interfaces:**
- Produces `vm.collect_diagnostics`: `name`, `dir?` (default `~/Library/Application Support/Alcove/Diagnostics/<vm>-<timestamp>`), `sinceMinutes?` (default 30), `logFiles?` ([guest paths]; the last 2000 lines of each), `processName?` (narrows the process list and marks the app) → `{dir, files: [..], summary}`.
- Files written, each step independent (a failing step writes `<name>.error.txt` and the bundle continues): `screenshot.png`, `windows.json`, `ui-tree.txt`, `processes.json`, `eventlog-application.json`, `eventlog-system.json` (errors and worse), `events.json` (guest events), `jobs/<job>.txt` (last 256 KiB of each job stream), `logs/<base name>`, `dumps/<file>` (dumps newer than `sinceMinutes`, largest total 500 MB), `doctor.json`, `trace.jsonl` and `video.mp4` copied when a recording is active (the recording continues), `summary.txt`.
- `summary` lists, one per line: windows that are not responding, dumps found, the count of error entries per log with the newest message of each, exited jobs with non-zero codes, and the foreground window title.

- [ ] **Step 1: Write failing tests** with fakes: `testBundleContainsEveryFile`; `testStepFailureWritesErrorFile` (fake agent fails `win.list`; `windows.error.txt` exists, other files present); `testSummaryNamesHangDumpAndErrors`; `testLogFilesArePulledAsTails`; `testDumpBudget`; `testWorksWithoutGuestTools` (screenshot and doctor only, summary says tools are missing).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: one-call diagnostics bundle"`.

### Task 5: MCP `evidence` toolset

**Files:**
- Create: `mcp/src/tools/evidence.ts`
- Modify: `mcp/src/index.ts`, `scripts/test/mcp-smoke.py`

**Interfaces:**
- Tools (toolset `evidence`): `alcove_record_start` (`fps`, `video`, `max_seconds`, `dir`), `alcove_record_stop`, `alcove_event_log` (`log`, `level`, `provider`, `since_minutes`, `contains`, `max`), `alcove_crash_dumps` (`action`: `enable`, `disable`, `list`, `pull`; `exe`, `full`, `file`, `path`), `alcove_collect_diagnostics` (`dir`, `since_minutes`, `log_files`, `process_name`). All toolsets together list 69 tools.
- `alcove_collect_diagnostics` text: the summary, then the directory and file list. `alcove_event_log` text: one block per entry `time level provider (id)` and the message indented.

- [ ] **Step 1: Implement** (thin mapping; no new pure logic to unit test) and update `mcp-smoke.py` expectations.
- [ ] **Step 2: Run** `cd mcp && npm run build && npm test && cd .. && python3 scripts/test/mcp-smoke.py --list-only && ALCOVE_MCP_TOOLSETS=core python3 scripts/test/mcp-smoke.py --list-only` — PASS.
- [ ] **Step 3: Commit** `git commit -m "MCP: evidence toolset"`.

### Task 6: Documentation and end-to-end run

**Files:**
- Modify: `docs/control-protocol.md`, `README.md`, spec "Needs verification" row for video without a window server session
- Create: `scripts/test/at5-e2e.py`, `docs/superpowers/plans/2026-10-13-at5-results.md`

- [ ] **Step 1: Write `at5-e2e.py`** (VM `Windows 11`, fixture deployed as in AT4); each check prints `PASS <n> <title>` or exits 1:
  1. `vm.record.start`; type a message and send through `vm.ui.type`/`vm.ui.click`; `vm.record.stop` → `video.mp4` exists, larger than 20 KiB, and a Swift or `ffprobe` check reports a video track with duration ≥ 2 s; `trace.jsonl` has lines for both ops with `before`/`after` files that exist.
  2. `vm.event_log level=error sinceMinutes=1440` → a list (possibly empty) without error; write a test entry with `eventcreate /T ERROR /ID 999 /L APPLICATION /SO AlcoveE2E /D "alcove e2e marker"` and find it with `provider="AlcoveE2E"`.
  3. Crash: `vm.crash_dumps.enable exe="alcove-fixture.exe"`; `vm.ui.click` on `Crash`; `vm.wait_for` `event process.exited` matched; within 30 s `vm.crash_dumps.list` has a dump for the fixture; `vm.crash_dumps.pull` → file starts with `MDMP`.
  4. `vm.collect_diagnostics logFiles=["C:\\alcove-e2e\\fixture.log"] processName="alcove-fixture"` during an active recording → directory contains `screenshot.png`, `windows.json`, `processes.json`, `eventlog-application.json`, `logs/fixture.log`, `dumps/` with the dump, `trace.jsonl`, `summary.txt`; the summary names the dump.
  5. Hang: relaunch the fixture, `vm.ui.click` on `Hang`, wait 8 s, `vm.collect_diagnostics` → the summary names a window that is not responding. Kill the fixture.
  6. MCP: over stdio call `alcove_event_log` and `alcove_collect_diagnostics`.
- [ ] **Step 2: Build, restart the control server, start the VM.**
- [ ] **Step 3: Run** `python3 scripts/test/at5-e2e.py`; fix through superpowers:systematic-debugging with reproducing unit tests; rerun until six PASS lines.
- [ ] **Step 4: Write docs and the results file.**
- [ ] **Step 5: Commit** `git commit -m "AT5: protocol docs and end-to-end run"`.
