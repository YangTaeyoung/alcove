# AT3 — frames and smart actions: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One action call tells the agent what changed on screen; the agent can read screen text, wait on conditions and send several steps at once, and pay for image tokens only when it asks for them.

**Architecture:** `DisplayConnection` remembers the current surface, so `AlcoveControl` can copy frames out of the shared framebuffer without QMP. A `Frame` value type carries BGRA pixels; pure functions crop, scale, encode and compare frames by tile. `ControlHandler` builds observations, OCR, waits and batches on top. The MCP action tools default to a text summary.

**Tech Stack:** Swift 6 language mode, macOS 15, CoreGraphics, ImageIO, Vision (`AlcoveKit/`). TypeScript MCP server. Python 3 standard library for end-to-end scripts.

**Spec:** `docs/superpowers/specs/2026-10-13-ai-testing-tools-design.md`

## Global Constraints

- Coordinates in every result are guest pixels of the full frame, also when the returned image is cropped or scaled.
- Control-protocol action ops default to `observe: "none"`; MCP action tools default to `observe: "summary"`.
- Settle rule: no tile changes for `settleMs` (default 300), give up after `settleTimeoutMs` (default 2000); samples every 50 ms.
- Tiles are 32×32 guest pixels; a tile counts as changed when any pixel differs by more than 24 in a colour channel.
- `screendump` stays the fallback when no surface is mapped.
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

1. The guest changes resolution between two samples: comparison reports the whole frame as changed and nothing reads past the new mapping (Task 1 `testCompareDifferentSizes`, `testFrameAfterSurfaceSwitch`).
2. A region or scale outside the frame (negative origin, zero size, larger than the frame): clamped to the frame or refused with the valid range (Task 1 `testCropClampsAndRefuses`).
3. A screen that never settles (animation): the action still returns after `settleTimeoutMs` with `settled: false` (Task 2 `testObservationTimesOutUnsettled`).
4. A batch whose third step fails: steps one and two have run, the result says which step failed and why, and later steps did not run (Task 2 `testBatchStopsAtFirstFailure`).
5. OCR on a frame with no text, and a query that is an invalid regular expression: empty matches and a clear error respectively (Task 3 `testFindTextNoText`, `testFindTextBadRegex`).

---

### Task 1: Frames from shared memory, image operations, extended screenshot

**Files:**
- Modify: `AlcoveKit/Sources/AlcoveDisplayProtocol/DisplayConnection.swift` (`currentSurface`)
- Create: `AlcoveKit/Sources/AlcoveControl/Frame.swift` (type, PNG/JPEG encode, PNG decode, crop, scale), `FrameDiff.swift` (tiles), `FrameSource.swift` (surface → `Frame`, mapping cache)
- Modify: `AlcoveKit/Sources/AlcoveControl/VMTarget.swift` (`frame()`), `ControlHandler.swift` (`vm.screenshot`, `vm.wait_idle`), `HeadlessRegistry.swift` (drain display messages), `PNGInfo.swift` (remove what `Frame` replaces)
- Tests: `AlcoveKit/Tests/AlcoveDisplayProtocolTests/DisplayConnectionTests.swift`, `AlcoveKit/Tests/AlcoveControlTests/FrameTests.swift`, `ControlHandlerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // DisplayConnection: latest valid `switch` for console 0, nil before the first one.
  public var currentSurface: FromQEMU.SurfaceSwitch? { get }

  public struct Frame: Sendable, Equatable {
      public let width: Int, height: Int
      public let pixels: Data                 // BGRA, row pitch width * 4
      public init(width: Int, height: Int, pixels: Data)
      public init?(png: Data)
      public struct Rect: Sendable, Equatable { public var x, y, w, h: Int }
      public var bounds: Rect { get }
      /// Intersection with the frame; nil when empty.
      public func clamp(_ r: Rect) -> Rect?
      public func crop(_ r: Rect) -> Frame                       // r must lie inside the frame
      public func scaled(by factor: Double) -> Frame             // 0 < factor <= 1
      public enum Format: String, Sendable { case png, jpeg }
      public func encoded(_ format: Format, quality: Double = 0.8) -> Data
  }
  public struct FrameDiff: Sendable, Equatable {
      public static let tile = 32
      public let changedTiles: Int, totalTiles: Int
      public let rect: Frame.Rect?            // bounding box of changed tiles in guest pixels
      public var fraction: Double { get }
      /// Frames of different size count as fully changed.
      public static func between(_ a: Frame, _ b: Frame) -> FrameDiff
  }
  final class FrameSource: @unchecked Sendable {
      /// Copies the current surface into a Frame; nil when `surface` is nil or cannot be mapped.
      func frame(for surface: FromQEMU.SurfaceSwitch?) -> Frame?
  }
  // VMTarget
  func frame() async throws -> Frame     // ControllerTarget: FrameSource, else screendump PNG decoded; FakeTarget: Frame(png:)
  ```
- `vm.screenshot` params added: `region` (`{x,y,w,h}`), `scale` (0.1...1), `format` (`png`/`jpeg`), `quality` (0.1...1). Result: `{png | jpeg (base64), mime, width, height, sentWidth, sentHeight, x, y, scale}` where `x`,`y` are the origin of the returned image in guest pixels and `scale` is returned pixels per guest pixel. `maxWidth` still applies after `scale`. A region that does not intersect the frame → `region is outside the <w>x<h> frame`.
- `vm.wait_idle` keeps its meaning (less than 0.5 % of the frame changing for `seconds`) computed as `FrameDiff.fraction < 0.005` between samples 250 ms apart.
- `HeadlessRegistry` starts a task per target that iterates `controller.display?.messages` while the VM runs, so the stream does not accumulate.

- [ ] **Step 1: Write failing tests.**
  - `DisplayConnectionTests.testCurrentSurfaceTracksSwitch`: feed a `switch` line through a connected peer → `currentSurface` equals it; an invalid one (`fmt` unknown) leaves the previous value.
  - `FrameTests`: `testPNGRoundTrip` (encode → `Frame(png:)` equal pixels); `testCropClampsAndRefuses` (`clamp` of a rect partly outside returns the intersection, fully outside nil; `crop` returns the expected pixels from a frame with a known gradient); `testScaledSize`; `testJPEGEncodes` (starts with `FF D8`); `testDiffBoundingBox` (change pixels in tiles (1,1) and (3,2) → `rect` covers both, `changedTiles == 2`); `testDiffIgnoresSmallNoise` (channel delta 10 → no change); `testCompareDifferentSizes` (`fraction == 1`, `rect == b.bounds`); `testFrameSourceMapsSharedFile` (write a BGRA file with a stride larger than `width * 4`, build a `SurfaceSwitch`, expect tight rows in the `Frame`); `testFrameAfterSurfaceSwitch` (a second surface with a smaller size yields a frame of the new size).
  - `ControlHandlerTests`: `testScreenshotRegionAndScale` (result origin, scale, `sentWidth`), `testScreenshotRegionOutside`, `testScreenshotJPEG`, existing screenshot and wait-idle tests still pass.
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: frames from the shared framebuffer, region and scaled screenshots"`.

### Task 2: Observations, low-level mouse, batch

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/Observation.swift`, `ControlHandler+Actions.swift` (observe wrapper, `vm.mouse.down`, `vm.mouse.up`, `vm.batch`), `AlcoveKit/Tests/AlcoveControlTests/ObservationTests.swift`
- Modify: `ControlHandler.swift` (action ops return through the wrapper; `knownOps`; lease classification), `InputGate.swift` if the batch needs a re-entrant hold

**Interfaces:**
- Consumes: `Frame`, `FrameDiff`, `VMTarget.frame()` from Task 1.
- Produces:
  ```swift
  enum ObserveLevel: String { case none, summary, diff, image }
  struct Observation {
      var settled: Bool
      var changed: Frame.Rect?
      var changedFraction: Double
      var width: Int, height: Int
      var image: Data?            // PNG
      var imageRect: Frame.Rect?  // what the image shows, guest pixels
      var imageScale: Double?
      func json() -> JSON
  }
  /// Samples frames until the settle rule holds, compares the settled frame with `before`.
  func observe(_ t: VMTarget, before: Frame, level: ObserveLevel, settleMs: Int, settleTimeoutMs: Int) async throws -> Observation
  ```
- Action ops (`vm.mouse.move`, `.click`, `.drag`, `.scroll`, `.down`, `.up`, `vm.key.press`, `.down`, `.up`, `vm.type`) accept `observe`, `settleMs`, `settleTimeoutMs` and add `observation` to their result unless the level is `none`. `diff` returns the changed rectangle grown by 16 pixels and clamped, scaled so its width is at most 1280; when nothing changed there is no image. `image` returns the full frame scaled to at most 1280 wide.
- `vm.mouse.down` / `vm.mouse.up`: `name`, `button?`, optional `x`,`y` (moves first).
- `vm.batch`: `name`, `steps` (array of objects with `op` and that op's params without `name`), `observe?`, settle params. Allowed step ops: the action ops above, `vm.wait_idle`, `vm.wait_for` (when it exists), and `sleep` with `ms` (1...10000). The batch holds the VM's input gate for its whole run. Result `{completed, results: [...], failedStep?, error?, observation?}`; the observation compares the frame before the first step with the settled frame after the last executed step. A disallowed step op → `step <i>: '<op>' cannot run in a batch` before anything runs. At most 50 steps.

- [ ] **Step 1: Write failing tests** with a `FakeTarget` whose frames come from a scripted queue (`frames: [Frame]`, last one repeats): `testObservationSummary` (queue: before, changed, changed… → `settled == true`, `changed` rect, fraction); `testObservationTimesOutUnsettled` (every sample differs; returns within `settleTimeoutMs + 500` ms with `settled == false`); `testObservationDiffImageCropsChange`; `testObservationImageFullFrame`; `testObserveNoneAddsNothing`; `testClickWithObserveReturnsObservation`; `testMouseDownUpSendButtons`; `testBatchRunsStepsInOrder` (display messages in order, one observation); `testBatchStopsAtFirstFailure`; `testBatchRejectsDisallowedOpBeforeRunning`; `testBatchStepLimit`; `testBatchHoldsInputGate` (a concurrent `vm.mouse.click` completes after the batch).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: action observations, mouse down/up, batch"`.

### Task 3: Screen text through host OCR

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/ScreenText.swift`, `AlcoveKit/Tests/AlcoveControlTests/ScreenTextTests.swift`
- Modify: `ControlHandler.swift` (`vm.find_text`, read-only), `AlcoveKit/Package.swift` only if linking Vision needs a setting

**Interfaces:**
- Produces:
  ```swift
  struct TextMatch: Sendable, Equatable { let text: String; let rect: Frame.Rect; let confidence: Double }
  enum ScreenText {
      /// Recognized lines in reading order with rectangles in the coordinates of `frame`.
      static func recognize(_ frame: Frame, languages: [String]) throws -> [TextMatch]
      /// Lines that contain `query` (case-insensitive) or match it as a regular expression.
      static func filter(_ lines: [TextMatch], query: String, regex: Bool) throws -> [TextMatch]
  }
  ```
- `vm.find_text`: `name`, `query?`, `regex?` (bool), `region?`, `languages?` (default `["ko-KR", "en-US"]`). Result `{matches: [{text, x, y, w, h, cx, cy, confidence}], lines}` where `lines` is the count of recognized lines and `cx`,`cy` the centre to click; rectangles are full-frame guest pixels also when a region was given. Without `query` all lines are returned. A region narrower than 400 pixels is upscaled 2× before recognition. Recognition uses `VNRecognizeTextRequest` at the accurate level with language correction off.
- Invalid regular expression → `'<query>' is not a valid regular expression`.

- [ ] **Step 1: Write failing tests.** A helper draws black text on white with CoreText into a `Frame` (system font, 28 pt): `testRecognizesEnglishAndKorean` (lines contain `Send message` and `메시지 보내기`; each rect lies within 12 pixels of where the text was drawn); `testFilterSubstringIsCaseInsensitive`; `testFilterRegex`; `testFindTextBadRegex`; `testFindTextNoText` (blank frame → empty, `lines == 0`); `testFindTextRegionOffsetsRects` (text drawn at (600, 400), region `{500,350,400,200}` → rect x ≥ 590); `testFindTextOpMapsResult` through `ControlHandler`.
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: find text on screen with host OCR"`.

### Task 4: Conditional waits

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/ControlHandler+Wait.swift`, `WaitConditions.swift`, `AlcoveKit/Tests/AlcoveControlTests/WaitTests.swift`
- Modify: `ControlHandler.swift` (`vm.wait_for`, read-only, serial lane), `GuestRecipes.swift` (`portListening(_ port: Int, os:)`, `processCount(named:os:)` scripts that print a number)

**Interfaces:**
- Consumes: `Frame`, `FrameDiff`, `ScreenText`, `AgentClient.call` (`proc.list`, `fs.stat`, `fs.tail`, `exec.read`, `exec.run`).
- Produces: `vm.wait_for`: `name`, `conditions` (array, 1...8), `timeout?` s (default 30, max 600), `observe?`. Result `{matched (index or -1), type?, detail?, waited (seconds), observation?}`; `matched == -1` is not an error.

| `type` | Fields | True when |
|---|---|---|
| `screen_idle` | `seconds` (default 2) | the frame changed less than 0.5 % for that long |
| `region_changed` | `region` | the region differs from its content at the start of the wait |
| `text_visible` | `text`, `regex?`, `region?` | OCR finds it; `detail` is the first match with its centre |
| `text_gone` | `text`, `regex?`, `region?` | OCR does not find it |
| `process_started` | `processName` | `proc.list` has a match; `detail` is the pid |
| `process_exited` | `pid` or `processName` | `proc.list` has no match |
| `file_exists` | `path` | `fs.stat` reports it |
| `port_listening` | `port` | the guest has a TCP listener on it |
| `log_matches` | `path`, `pattern` | a line of `fs.tail` (400 lines) matches; `detail` is the line |
| `job_output_matches` | `job`, `pattern` | output read so far matches, or `detail: "job exited"` with `matched` unset when the job ended without a match |

- Screen conditions sample every 250 ms, OCR conditions every 700 ms, agent conditions every 500 ms. Agent conditions on a VM without guest tools fail the call with the tools error. An unknown `type` → `condition <i>: unknown type '<t>'` listing the valid types.

- [ ] **Step 1: Write failing tests** with scripted frames and a fake agent: `testFirstTrueConditionWins` (two conditions; the second becomes true first → `matched == 1`); `testTimeoutReturnsMinusOne`; `testScreenIdle`; `testRegionChanged`; `testTextVisibleAndGone` (frames drawn with the Task 3 helper); `testProcessStartedAndExited`; `testFileExists`; `testPortListeningRunsRecipe`; `testLogMatches`; `testJobOutputMatchesAndExit`; `testUnknownTypeListsValid`; `testConditionLimit`; `testAgentConditionWithoutTools`.
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: wait for screen, text, process, file, port and log conditions"`.

### Task 5: MCP tools

**Files:**
- Create: `mcp/src/tools/actions.ts`, `mcp/src/observation.ts`, `mcp/src/observation.test.ts`
- Modify: `mcp/src/tools/core.ts` (`alcove_screenshot` params; action tools take `observe`), `mcp/src/index.ts`, `scripts/test/mcp-smoke.py`

**Interfaces:**
- Produces:
  ```ts
  /** Text and optional image content for an observation object from the control protocol. */
  export function renderObservation(o: Record<string, unknown> | undefined): Array<TextContent | ImageContent>;
  ```
  Text form: `screen settled` or `screen still changing after <n> ms`; `changed (x,y) WxH = P% of the frame` or `nothing changed`; when an image is attached, `image shows guest (x,y) WxH at scale S`.
- Tools (toolset `core`): `alcove_find_text` (`query`, `regex`, `region`, `languages`), `alcove_wait_for` (`conditions`, `timeout_s`, `observe`), `alcove_batch` (`steps` with snake_case op names `click`, `move`, `drag`, `scroll`, `type`, `press_keys`, `mouse_down`, `mouse_up`, `key_down`, `key_up`, `wait_idle`, `wait_for`, `sleep`, mapped to control ops and camelCase params), `alcove_mouse_down`, `alcove_mouse_up`, `alcove_key_down`, `alcove_key_up`. `alcove_screenshot` gains `region`, `scale`, `format`, `quality`. `alcove_click`, `alcove_move_mouse`, `alcove_drag`, `alcove_scroll`, `alcove_type`, `alcove_press_keys` gain `observe` (`none`, `summary`, `diff`, `image`; default `summary`), `settle_ms`, `settle_timeout_ms`. All toolsets together list 53 tools; `core` alone 23.
- `alcove_find_text` text: one line per match `"<text>" at (cx, cy) [x,y WxH]`, capped at 200 lines.

- [ ] **Step 1: Write failing tests** in `observation.test.ts`: summary text for settled and unsettled; no-change wording; an observation with `image` yields one image content with `image/png`; `undefined` yields an empty array. Add a test for the batch step mapper (`{op: "click", x: 1, y: 2}` → `{op: "vm.mouse.click", x: 1, y: 2}`; `press_keys` → `vm.key.press`; unknown op throws naming the valid ones).
- [ ] **Step 2: Run** `cd mcp && npm run build && npm test` — fails.
- [ ] **Step 3: Implement.** Update `mcp-smoke.py` expectations.
- [ ] **Step 4: Run** `cd mcp && npm run build && npm test && cd .. && python3 scripts/test/mcp-smoke.py --list-only && ALCOVE_MCP_TOOLSETS=core python3 scripts/test/mcp-smoke.py --list-only` — PASS.
- [ ] **Step 5: Commit** `git commit -m "MCP: observations on actions, find text, wait for, batch, low-level input"`.

### Task 6: Documentation and end-to-end run

**Files:**
- Modify: `docs/control-protocol.md`, `README.md` (tool list if enumerated)
- Create: `scripts/test/at3-e2e.py`, `docs/superpowers/plans/2026-10-13-at3-results.md`

- [ ] **Step 1: Write `at3-e2e.py`** (VM `Windows 11` running, uses `alcove_ctl.py`); each check prints `PASS <n> <title>` or exits 1:
  1. Frame path: 20 `vm.screenshot scale=0.5 format=jpeg` calls; print the mean latency; the result reports `scale == 0.5` and half-size dimensions. A `region` screenshot returns exactly the region size.
  2. Text: write `C:\alcove-e2e\ocr.txt` containing `Alcove OCR check` and `한글 인식 확인`, open it with `notepad.exe` through `vm.exec.start` (`shell: "none"`), `vm.wait_for` `text_visible "Alcove OCR check"` → matched; `vm.find_text query="한글 인식 확인"` → one match inside the frame.
  3. Observation: `vm.mouse.click` at the centre of the OCR match with `observe: "summary"` → `observation.settled` present; `vm.type text="xyz"` with `observe: "diff"` → `changed` set and an image no larger than the frame.
  4. Batch: `press_keys ctrl+a`, `type "batch works"`, `wait_idle` → `completed == 3`; `vm.find_text query="batch works"` → a match. A batch with a bad third step reports `failedStep == 2`.
  5. Waits: `vm.wait_for` with `process_exited processName=notepad` and a 3 s timeout → `matched == -1`; `vm.process.kill processName=notepad tree=true`, then the same wait → `matched == 0`. `file_exists` on the text file → matched. `port_listening port=7645` → matched.
  6. Unsettled screen: play a moving window (`vm.exec.start` PowerShell loop that toggles Notepad maximize every 100 ms for 5 s) and click with `observe: "summary"`, `settleTimeoutMs: 800` → returns within 2 s with `settled == false`.
  7. MCP: over stdio call `alcove_find_text` and `alcove_click` (default observe) and check that the click result text contains `screen`.
- [ ] **Step 2: Build** `cd AlcoveKit && swift build --product alcovectl --scratch-path .build-ctl`, restart the headless control server, start the VM.
- [ ] **Step 3: Run** `python3 scripts/test/at3-e2e.py`. Fix failures through superpowers:systematic-debugging with a reproducing unit test; rerun until seven PASS lines.
- [ ] **Step 4: Write docs and the results file** (include the measured screenshot latency before and after, taken with the same loop against the `screendump` path by setting `ALCOVE_FRAME_SOURCE=screendump`, an environment switch `FrameSource` honours).
- [ ] **Step 5: Commit** `git commit -m "AT3: protocol docs and end-to-end run"`.
