# Follow-ups after 0.2.0: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the review findings that are still open after the 0.2.0 release (final whole-program review, fix waves FW1–FW8 and W1–W3, re-reviews, the final guest e2e pass and the AT1–AT7 ledgers). Each item below was checked against the code at `7339e86`. The fixes ship as 0.2.1.

**Base:** branch `followups-0.2.1` (= `main` 7339e86, released as 0.2.0).

**Sources:** `.superpowers/sdd/final-wave.md`, `.superpowers/sdd/final-review/*.md` (layer reviews, `FW1`–`FW8-report.md`, `W1/W2/W3/W1r3-report.md`, `rereview-*.md`, `final-e2e-report.md`, `review-final-fixes.md`, rulings in `progress.md`), `.superpowers/sdd/2026-10-13-at*/progress.md`, `docs/superpowers/plans/2026-10-1*-results.md`. Item sources are named in brackets, e.g. `[FW3 skip M6]`, `[final-wave AT1:66]`.

**Classes:** FIX (a change verified with unit tests on the Mac, or on the Windows test VM where stated), LINUX (needs a Linux guest; cross-reference for the Linux verification), WONT (design limit or not worth the cost; becomes a documented known limit where marked *(doc)*).

## Global Constraints

- Work on branch `followups-0.2.1` in `/Users/giraffewithcode/dev/personal/alcove`. Commit only the files of the task. Do not push. Commit trailers are given in each dispatch.
- Comments and test names say only what the code does now: no history, no rationale, no measurements, no review narratives. Those go in commit messages.
- Error strings are sentences that name the next step.
- Docs (`docs/control-protocol.md`, `docs/agent-protocol.md`, `README.md`) are updated in the sections of the behaviour a task changes, in the same task. `docs/control-protocol.md` is edited by several tasks: each task touches only its own sections.
- Code, identifiers and repository docs are English.
- Go (`guest-tools/`): `go vet ./...`, `GOOS=linux GOARCH=arm64 go vet ./...`, `GOOS=windows GOARCH=arm64 go vet -unsafeptr=false ./...`, `go test ./...`; `go test -race` for the packages a task touches; `GOOS=windows GOARCH=arm64 go build ./...` and the same for linux.
- Swift (`AlcoveKit/`): `swift build --build-tests && swift test --skip-build`, no new warnings. CI runs Swift 6.3.3: avoid closures whose parameter type is ambiguous across overloads (name the type, e.g. `UnsafeMutableRawBufferPointer`). Wall-clock upper bounds in tests are avoided; wait on a condition with a deadline that fails the test instead.
- App target (`Alcove/`): `xcodegen generate && xcodebuild -project Alcove.xcodeproj -scheme Alcove build` after `build/alcove-proxy` exists (`scripts/test/all.sh` builds it).
- MCP (`mcp/`): `npm run build && npm test`; `python3 scripts/test/mcp-smoke.py --list-only`.
- Python scripts: `python3 -m py_compile` on each changed script; delete `__pycache__/` afterwards.
- Tasks marked **Windows VM** use the Windows 11 test VM (one task at a time on the VM; leave it stopped and clean, as the e2e scripts do). No task touches the Linux VM.
- Test first: write the test that fails on the current code, see it fail, then fix.

## Task order and ownership

| Task | Component | Items | VM |
|---|---|---|---|
| 1 | Go agent: server, proto, cmd | 10 | Windows VM for 1.1, 1.5, 1.6 |
| 2 | UI helper (C#) and guest security checks | 7 | Windows VM |
| 3 | Go proxy | 3 | none |
| 4 | Control: waits, text, frames | 14 | none |
| 5 | Control: agent link, files, error sentences | 10 | none (5.1 optional on the Windows VM) |
| 6 | Control: guest-facing (HTTP, journal, state, recipes) | 7 | none |
| 7 | Evidence and scripts | 6 | none |
| 8 | Engine and app | 6 | none (8.5 real engine, 8.6 engine build) |
| 9 | MCP | 5 | Windows VM for 9.5 |
| 10 | e2e scripts and repository docs | 11 | Windows VM for 10.1–10.3, 10.9 |
| 11 | Windows VM check session | 13 | Windows VM |
| 12 | App checks with a person | 6 | Windows VM + a person (or computer use) |

Tasks 1–9 own disjoint source files and can run in parallel worktrees. Task 10 follows Tasks 1–9 (it documents the known limits and reruns scripts against the new code). Task 11 runs on the integrated tree after Task 10. Task 12 runs last.

---

### Task 1: Go agent — server, proto, cmd

**Files:** `guest-tools/internal/server/**`, `guest-tools/internal/proto/**`, `guest-tools/cmd/alcove-agent/**`, `docs/agent-protocol.md`, their tests.

- [ ] **1.1 Go tests that fail on Windows** [final-e2e-report "검증 안 됨"; final-e2e-results "Not verified"] — **Windows VM**
  - Where: `internal/server/{jobs,shell,launch,procs,rpc,server,ui,bounds,auth}_test.go` and `internal/uia/helper_test.go` call `sh`, `sleep`, `touch`, `true` and rely on Unix file semantics (removing an open file's folder, a second appending handle across a start-over). On the guest, 19 tests of `internal/server` and 2 of `internal/uia` fail.
  - Expected: `go test ./...` passes on the Windows guest. Unix-only tests move to `*_unix_test.go` (as `pid_unix_test.go` and `fifo_unix_test.go` already are), or take a Windows command.
  - Lock: first run `go test ./... 2>&1` on the guest to collect the failing names (they were not recorded); afterwards the suite passes there and on the Mac.
- [ ] **1.2 Test gap: an `auth` line read before the connection was replaced** [review-final-fixes M3, bd51e5b]
  - Where: `internal/server/auth.go:148-160` (`join`), `:240-245` (served path). The code serves such a connection; no test locks it.
  - Test: `auth_test.go` `TestAHandshakeReplacedAfterItsSignatureArrivedIsServed`.
- [ ] **1.3 A line that is not JSON before auth waits for the 10 s deadline** [final-e2e-report 우려]
  - Where: `internal/proto/proto.go:113-115` skips lines that do not parse; `auth.go:216` reads through it.
  - Expected: before auth, such a line gets the unauthenticated refusal sentence at once and the connection closes; after auth the reader keeps skipping.
  - Test: `auth_test.go` `TestAMalformedLineBeforeAuthIsRefusedAtOnce`.
- [ ] **1.4 `agent.log` grows without bound** [W1-report concern 2]
  - Where: `cmd/alcove-agent/main.go:166-177` (`openLog`) opens a plain append file; `helper.log` uses the capped writer `internal/uia/logfile.go:25` (`openCappedLog`).
  - Expected: `agent.log` is capped the same way (move the capped writer to a package both use, e.g. `internal/logfile`).
  - Test: `TestTheAgentLogIsCappedLikeTheHelperLog` (writes past the cap, checks the size and that the newest lines are kept).
- [ ] **1.5 `proc.kill` by name counts `SUCCESS`/`성공` lines** [final-wave AT1:66; FW1 skip] — **Windows VM**
  - Where: `internal/server/sys_windows.go:91-111`. On another display language `killed` is 0; a refused kill also answers `killed: 0` without an error.
  - Expected: the count does not read taskkill's text (list the matching processes before and after, or use the exit code); a refused kill answers a sentence that names elevation. Update `docs/agent-protocol.md:390-397`.
  - Test: Windows test `TestProcKillByNameCountsWithoutReadingTaskkillText`; run on the guest.
- [ ] **1.6 `fs.delete` refusal of home and drive roots is passed by admin-share aliases** [FW1 skip; final-wave AT1:131] — **Windows VM**
  - Where: `internal/server/files.go` `fsDelete` guard (~:611-631), `withoutLongPrefix` :105. `\\localhost\C$\Users\<u>`, `\\127.0.0.1\C$\…` and `\\?\UNC\…` reach a recursive delete of home.
  - Expected: the guard also compares the target with home, its ancestors and the drive roots by file identity (`os.SameFile`). Remove the docs sentence that names the alias as a limit.
  - Test: Windows test `TestFsDeleteRefusesTheHomeDirectoryThroughTheAdminShare` (skips when the Server service is off); run on the guest.
- [ ] **1.7 Load-sensitive Go tests** [final-wave AT1:66 "flaky-prone tests"; FW1 skip]
  - Where: `pid_unix_test.go:7` treats a zombie as alive (`kill(pid,0)`), used at `shell_test.go:273` and `shell_unix_test.go:37`; `shell_test.go:325-346` busy-spins an emitter.
  - Expected: `pidAlive` reports a zombie as gone (`ps -o stat=` or `waitid` with `WNOWAIT`); the emitter yields.
  - Lock: the same tests pass under `go test -race -count=20 ./internal/server/`.
- [ ] **1.8 Measurements in `docs/agent-protocol.md`** [guest-agent §3]
  - Where: `docs/agent-protocol.md:606-611` ("0.59–0.60 s", "of 84 kills … 8").
  - Expected: the section states the behaviour only.
- [ ] **1.9 Install errors without a next step** (found during triage)
  - Where: `cmd/alcove-agent/install_windows.go:83-107` (`copy to %s verification failed`, `schtasks: %v: %s`, `netsh: …`).
  - Expected: each names what to do (run the installer elevated, delete the named file, rerun `--install`).
  - Test: unit test of the sentence builder where the error text is formed; compile for windows.
- [ ] **1.10 `AgentVersion` is still `0.2.0`** [at1-results "Open"]
  - Where: `internal/server/server.go:26`.
  - Expected: `0.2.1`, matching the release; the hello carries it. Update `docs/agent-protocol.md` where the version is shown.
  - Test: existing hello tests read the constant.

### Task 2: UI helper (C#) and guest security checks — **Windows VM**

**Files:** `guest-tools/internal/uia/assets/helper.cs`, `guest-tools/internal/uia/**` (only where a check finds a defect), `scripts/test/uia-helper-check.py`, `docs/agent-protocol.md` (UI sections).

The helper is compiled in the guest; build and run `uia-helper-check.py` there after each change.

- [ ] **2.1 `ui.at` counts in one window, a replay resolves another** [final-wave AT4:116 helper M1]
  - Where: `helper.cs:2949-2950` (window), `:2975-2990` (count inside `top`), `ResolveWindow` `:1049-1056` (first title match wins).
  - Expected: `ui.at` answers null counts when `ResolveWindow(title)` is not `top`.
  - Test: `uia-helper-check.py` check with two windows whose titles share the text.
- [ ] **2.2 A ghost window of a hung app is not detected in point mode** [helper M2]
  - Where: `helper.cs:2741` checks `IsHungAppWindow(top)` only.
  - Expected: a ghost window (`HungWindowFromGhostWindow` non-null) gets the same `late` sentence as a hung window.
  - Test: `uia-helper-check.py` with the hung fixture window, pointing at it.
- [ ] **2.3 Ref edges** [helper M5]
  - Where: `helper.cs:2919-2933`. A ref whose element has no native window handle answers `gone: true`; an element that removes itself after an action in a live window answers an error although the action ran.
  - Expected: such a ref resolves its window through `TopWindow(element)`; an action whose element disappears afterwards answers ok.
  - Test: `uia-helper-check.py` checks for both.
- [ ] **2.4 `ui.at {ref}` with a `Win32Exception` gives the generic sentence** [helper M6]
  - Where: `helper.cs:2907-2911`.
  - Expected: a sentence that says the element is gone and to take a new ref with `vm.ui.find`.
  - Test: `uia-helper-check.py` (ref of a closed window).
- [ ] **2.5 `desktop.ToInt32()`** [helper M7]
  - Where: `helper.cs:2930`. Compare handles as `IntPtr`/`long`.
  - Lock: compiled and exercised by 2.1–2.4.
- [ ] **2.6 Check: a handle opened before the lock** [guest-agent §4 "pre-opened directory handles", never run]
  - Where: `internal/uia/acl_windows.go` `LockHelperFolders`, `LockDeployRoot`.
  - Check: as a standard user open a directory handle in `C:\ProgramData\Alcove\uia` and `C:\alcove-apps` before the agent starts (folder moved aside and recreated by the agent), restart the agent, try to create a file through the old handle. If it succeeds, the lock also moves aside a folder it did not create in this start; add a Windows test for that.
- [ ] **2.7 Check: the helper does not load a module planted in the user's module path** [guest-agent §4 PSModulePath; final-e2e-report "약함"]
  - Check: plant a module that exists only under `Documents\WindowsPowerShell\Modules` of the logged-in user with a side effect (writes a file), start a UI op, confirm the side effect did not happen and `helper.log` shows no load. Record the result in the results doc of Task 11.

### Task 3: Go proxy

**Files:** `guest-tools/internal/mitm/**`, `guest-tools/cmd/alcove-proxy/**`, `docs/control-protocol.md` (HTTP capture section only).

- [ ] **3.1 A client that closes right after the headers records `resBytes` 0 and no body** [final-e2e-report 우려]
  - Where: `internal/mitm/handler.go:411-418`: `resCap.Write` runs only after `w.Write` succeeds.
  - Expected: the chunk read from the upstream is captured before the client write; the row shows the bytes read from the upstream with error `clientClosed`. `resBytes` in `docs/control-protocol.md` (~:1834) says it counts bytes read from the upstream.
  - Test: `robustness_test.go` `TestClientClosingAfterTheHeadersKeepsTheBodyReadFromTheUpstream`.
- [ ] **3.2 The Close/transport race has no test** [FW2 "not verified"]
  - Where: `proxy.go:70`, `:105-106`, `:197-199` (`tmu`).
  - Test: `proxy_test.go` `TestCloseDuringFirstUpstreamRequestsIsRaceFree` (Close while many first requests start; run with `-race -count=20`).
- [ ] **3.3 Redaction list: other credential headers are kept in clear** [proxy M6; ruling: no code change, document]
  - Where: `docs/control-protocol.md:1737`.
  - Expected: one sentence that headers outside the six names (e.g. `X-Auth-Token`, `X-Amz-Security-Token`, `X-Goog-Api-Key`) and query strings are stored as sent; one sentence that the number of concurrent proxy connections is not limited and headers of exchanges in flight count outside the body budget (Known limits, Proxy).

### Task 4: Control — waits, text, frames

**Files:** `AlcoveKit/Sources/AlcoveControl/{ControlHandler+Wait.swift, WaitConditions.swift, ScreenText.swift, RecognitionQueue.swift, Frame*.swift}`, `AlcoveKit/Tests/AlcoveControlTests/{WaitTests, ScreenTextTests, ObservationTests, FrameTests, ControlServerTests}.swift`, `docs/control-protocol.md` (Finding text, Waiting).

- [ ] **4.1 `AgentSilence` names a stale op** [final-wave AT4:99 N7]
  - Where: `WaitConditions.swift:42-48`. When the evaluation in flight has no open call, the sentence names the previous timed-out op and counts from its start.
  - Expected: no silence sentence while the evaluation in flight has made no unanswered call.
  - Test: `WaitTests.testSilenceIsNotReportedWhileTheEvaluationInFlightHasNoOpenCall`.
- [ ] **4.2 Conditions that need commands run to the timeout on tools without `--allow-exec`** [final-wave AT3:60]
  - Where: `ControlHandler+Wait.swift:161-165` has no capability check; the agent answers `exec disabled; start alcove-agent with --allow-exec`, which `settle` (`:231-237`) counts as a failure.
  - Expected: `port_listening`, `job_output_matches` and `process_*` conditions are refused before the wait starts when `hello.capabilities` lacks what they need, with the agent's next step.
  - Test: `WaitTests.testAConditionThatNeedsCommandsIsRefusedWhenTheToolsDoNotAllowThem`.
- [ ] **4.3 Failed frames keep the `screen_idle` quiet clock running** [final-wave AT3:67]
  - Where: `ControlHandler+Wait.swift:384-389`.
  - Expected: a frame that could not be read resets the quiet clock.
  - Test: `WaitTests.testScreenIdleCountsQuietTimeOnlyAcrossFramesThatWereRead`.
- [ ] **4.4 A text condition whose `region` lies outside the frame is retried until the timeout** [AT3 task-6 re-review N10c]
  - Where: `ControlHandler+Wait.swift:522` throws a plain error that `settle` counts as a failure; `docs/control-protocol.md:567` says the wait ends, as `region_changed` does (`:206`).
  - Expected: the wait ends with `condition <i>: region is outside the WxH frame`.
  - Test: `WaitTests.testATextConditionWhoseRegionIsOutsideTheFrameEndsTheWait`.
- [ ] **4.5 The last collection waits the recognition grace before it looks at agent and UI answers** [AT3 task-6 N4]
  - Where: `ControlHandler+Wait.swift:279-292`.
  - Expected: agent and UI conditions are looked at first; the grace is waited only when none ended the wait.
  - Test: `WaitTests.testAnAnswerAfterTheLastTickEndsTheWaitWithoutTheRecognitionGrace`.
- [ ] **4.6 The error of the supported-languages list is not a sentence** [final-wave AT3:33]
  - Where: `ScreenText.swift:125-133` passes the raw `NSError`.
  - Expected: `the text recognizer could not list its languages (<reason>); call vm.find_text again` (or the agreed next step).
  - Test: `ScreenTextTests.testALanguageListThatCannotBeReadIsReportedWithASentence` (through `WaitTiming.supportedLanguages`).
- [ ] **4.7 Docs of Finding text and Waiting** [AT3 task-6 N3, N6, N10]
  - `docs/control-protocol.md` ~:512-520: the frame a text match is judged on is the one read when the recognition was asked for, and can be older when recognitions queue.
  - `:389`: the font sizes match the tested line boxes.
  - `problems`: a condition with counted failures is listed with its `failures`.
  - `:426-427`: the warm-up runs at raised priority while a request waits behind it.
- [ ] **4.8 Flaky: two `ControlServerTests` concurrency tests** [final-wave AT1:94]
  - Where: `ControlServerTests.swift:214` (`testConcurrentOpDoesNotBlockSerialLane`, 1 s reply delay against `vm.status`), `:236` (`testConcurrentOpsAnswerInCompletionOrder`, 0.6 s vs 0.1 s).
  - Expected: ordering is driven by gates the test opens, not by delays.
- [ ] **4.9 Flaky: wall-clock bounds in `WaitTests`** [final-wave AT3:47, :60, :74]
  - Where: `WaitTests.swift:141`, `:1200`, `:1234`, `:1254`, `:1265`, frame-count bound `:190`; `recognitionsEnded()` (`:39-41`) waits without a limit.
  - Expected: assertions on order and outcome, a deadline that fails the test with `XCTFail` in `recognitionsEnded()`.
- [ ] **4.10 Flaky: `testRecognitionFailuresAreRetried` falls through to real Vision** [final-wave AT3:67]
  - Where: `WaitTests.swift:547-559`.
  - Expected: the seam returns canned lines on the retry.
- [ ] **4.11 Flaky: real-Vision tests fail under memory pressure** [final-wave AT3:74]
  - Where: `ScreenTextTests` that call Vision; `ObservationTests.swift:99` (`< 800 ms`).
  - Expected: the test helper retries a `recognitionFailed` once as the product does; the observation bound becomes an ordering assertion.
- [ ] **4.12 Test gap: `Frame(png:)` refuses an image above `maxDimension`** [final-wave AT3:29]
  - Where: `Frame.swift:26-29`. Test: `FrameTests.testAPNGLargerThanTheMaximumDimensionIsRefused`.
- [ ] **4.13 Test gap: channel order of an encoded frame** [final-wave AT3:24]
  - `FrameTests.testAPureRedFrameIsRedAfterEncoding` (decode through ImageIO and check the pixel).
- [ ] **4.14 Test gap: cancelling a wait whose text reading waits for its turn** [AT3 task-6 N9a]
  - `WaitTests.testCancellingAWaitWhoseReadingWaitsForItsTurnEndsAtOnce`.

### Task 5: Control — agent link, files, error sentences

**Files:** `AlcoveKit/Sources/AlcoveAgent/**`, `AlcoveKit/Sources/AlcoveControl/{VMTarget.swift, ControlHandler.swift, ControlHandler+UI.swift (helper gate only), ControlHandler+Guest.swift (refusal row only), ControlHandler+Files.swift, GuestText.swift}`, `AlcoveKit/Sources/AlcoveQMP/JSON.swift`, `Alcove/Sources/VM/VMWindowView.swift` (refusal label only), their tests, `docs/control-protocol.md` (agent/tools, files sections).

- [ ] **5.1 The adoption `ui.ping` bypasses the helper gate** [control-core M6; FW3 skip] — Windows VM optional
  - Where: `VMTarget.swift:284` starts `ui.ping` outside `helperGate` (`ControlHandler+UI.swift:333`).
  - Defect: a gated call queued in the guest behind the start ping counts that time as "sent"; waits and observations can report the helper silent while it starts.
  - Expected: a gated helper call waits for the adoption ping before its turn starts.
  - Test: `ControlUITests.testAHelperCallWaitsForTheAdoptionPingBeforeItsTurnStarts` (fake agent holds `ui.ping`). Optional guest check: first `vm.ui.tree` after an agent restart.
- [ ] **5.2 Agent sentences name agent ops to control callers** [at1-results "Open"; final-wave AT1:112; FW3/FW7 skip M4]
  - Where: `ControlHandler.swift:554` passes `.remote` text unchanged; the agent says `call exec.list` (`guest-tools/internal/server/jobs.go:172,331,372`).
  - Expected: the host rewrites the agent op names it knows to control ops (`exec.list` → `vm.exec.list`, `fs.stat` → `vm.fs.stat`, …) in agent sentences it passes on.
  - Test: `ControlShellFilesTests.testAgentSentencesNameControlOps`.
- [ ] **5.3 Push detects a refused rename by `text.contains("exists")`** [final-wave AT1:131]
  - Where: `AgentFiles.swift:155`. A refusal for another reason whose text contains "exists" (e.g. a path with `exists` in it) is reported as "exists in the guest; pass overwrite".
  - Expected: match the agent's sentence suffix `exists; pass overwrite to replace it` (`files.go:610`).
  - Test: `AgentFilesTests.testAPushRenameRefusedForAnotherReasonKeepsTheAgentSentence`.
- [ ] **5.4 A UTF-32LE mark is read as UTF-16LE** [final-wave AT1:117; FW3 skip]
  - Where: `GuestText.swift:10-11`; the agent's `fs.tail` excludes `FF FE 00 00` (`docs/agent-protocol.md:987-988`).
  - Expected: the host follows the agent's rule (UTF-32LE decoded as UTF-32LE). Update `docs/control-protocol.md:2560`.
  - Test: `GuestTextTests.testAUTF32LEMarkIsNotReadAsUTF16`.
- [ ] **5.5 `ControllerTarget` reads the next-start config** [final-wave AT2:38]
  - Where: `VMTarget.swift:331-334` (endpoint, token, agentKey), `:396` (`agentHostPort`), `:401-404` (`staticForwards`) read `controller.config`, which the app's config save changes while the VM runs (`VMSession.swift:247`).
  - Expected: they read `controller.runningConfig ?? controller.config` (`VMController.swift:60`).
  - Test: `testAControllerTargetUsesTheConfigurationTheEngineRunsWith` (fake engine; save a config with another port while running).
- [ ] **5.6 A refusal by the host is worded as a refusal by the guest** [W1r3 concern 1; progress.md "final polish list"]
  - Where: `AgentClient.swift:36,431`, `ControlHandler.swift:542`, `ControlHandler+Guest.swift:220`, `VMWindowView.swift:280-287`. For `agentWithoutAuth` the text reads "the guest tools in '<vm>' refused the connection: …" and the app shows "Tools refused".
  - Expected: a host-side refusal reads "the guest tools in '<vm>' cannot be used: …" in `vm.status` `toolsRefused`, the doctor row and the app label (a label that does not name the guest as the refusing side); agent-side refusals keep their wording.
  - Test: `AgentKeyLinkTests.testAHelloWithoutAuthIsNamedAsRefusedByTheHost` and a doctor-row variant.
- [ ] **5.7 `pullFile` exposes a test clock in its public signature** [final-wave AT5:80; FW5 skip]
  - Where: `AgentFiles.swift:175-177` (`now:`).
  - Expected: the public method has no `now:`; an internal overload takes it.
  - Lock: `AgentFilesTests` compile against the internal overload (`@testable import`).
- [ ] **5.8 Test gap: sync of a file with the same size and other content** [final-wave AT1:117]
  - Where: `AgentFiles.swift:283`. Test: `AgentFilesTests.testSyncSendsAFileOfTheSameSizeWithOtherContent`.
- [ ] **5.9 Test gap: the case-collision sync refusal never runs on the Mac or CI** [AT1 fix wave]
  - Where: `AgentFilesTests.swift:415`, `ControlUITests.swift:1479` skip on case-insensitive volumes.
  - Expected: the refusal is tested with an injected local listing.
- [ ] **5.10 Deeply nested request JSON** (triage; the "parser bounds depth" claim of FW5 was not checked)
  - Where: `AlcoveQMP/JSON.swift:94` (`JSONDecoder`), recursive `TraceSanitizer` (`Trace.swift:103-130`).
  - Expected: a request line with 100000 nested `[` is answered with the unreadable-request sentence, no crash. Write the test first; add a depth bound in `JSON` decoding only if it fails.
  - Test: `AlcoveQMPTests/JSONTests.testDeeplyNestedInputIsRefusedWithoutCrashing` (`ControlServerTests` belongs to Task 4 and is not edited here).

### Task 6: Control — guest-facing (HTTP, journal, state, recipes)

**Files:** `AlcoveKit/Sources/AlcoveControl/{ProxyProcess.swift, CaptureJournal.swift, ControlHandler+HTTP.swift, ControlHandler+State.swift, GuestRecipes.swift}`, their tests (`ControlHTTPTests`, `ProxyProcessTests`, `ControlStateTests`, `GuestRecipeTests`), `docs/control-protocol.md`, `docs/agent-protocol.md` (UI refs paragraph).

- [ ] **6.1 The proxy's fatal sentence carries two next steps** [FW2 concern; proxy-side duplicate of the same item]
  - Where: `ProxyProcess.swift:73`, `:446-447`, `:492-496` wrap `the proxy stopped accepting connections (x); stop the capture and start a new one` (`guest-tools/internal/mitm/control.go:67`) and add `call vm.http.stop, then vm.http.start…`; the lost-capture warning repeats it.
  - Expected: the host keeps the reason (text before the proxy's `; `) and adds its own next step once. The Go side is unchanged.
  - Test: `ProxyProcessTests.testAFatalLineOfTheProxyIsNamedWithOneNextStep`, plus the lost-capture warning in `ControlHTTPTests`.
- [ ] **6.2 A stale cleanup removes an entry a restore wrote again when both are equal** [FW4 concern 3]
  - Where: `CaptureJournal.swift:119-123` (`remove(_:)` compares by value), `ControlHandler+State.swift:187-188` (`afterRestore` records the snapshot's note again).
  - Expected: each record carries a generation (decoded as absent for old files); a cleanup removes only the record it read.
  - Test: `ControlHTTPTests.testAStaleCleanupKeepsTheEntryARestoreWroteAgainWhileItRan`.
- [ ] **6.3 Test gap: a cancelled `vm.http.start` whose running guest step then fails** [review-final-fixes M3, f0490bd]
  - Where: `ControlHandler+HTTP.swift:236-257`; `ControlHTTPTests.swift:534` covers only a step that succeeds.
  - Test: `ControlHTTPTests.testTheUndoOfACancelledStartRunsWhenTheRecipeThatWasRunningFails` (undo runs, journal entry removed).
- [ ] **6.4 `vm.set_resolution` to a mode the guest does not offer** [at2-results "Open"]
  - Where: `ControlHandler+State.swift:61-80`, `docs/control-protocol.md:1268-1274`. The guest picks another mode (2560x1600 asked, 1920x1200 set); the reply does not say it differs.
  - Expected: the reply carries `warning: "the guest set <w>x<h>, not <W>x<H>; it does not offer that mode"`; the docs say the guest may pick another mode.
  - Test: `ControlStateTests.testSetResolutionWarnsWhenTheGuestSetsAnotherSize`.
- [ ] **6.5 Flaky: `ControlStateTests.swift:288` (`< 4 s`)** [final-wave AT3:47]
  - Expected: a condition wait with a failing deadline instead of a wall-clock bound.
- [ ] **6.6 Helper refs after `vm.snapshot.restore`** [control-guest M1; FW4 skip as design]
  - Where: `docs/control-protocol.md:648-652`, `docs/agent-protocol.md:722`. The helper's ref counter is restored with the guest memory, so a ref issued after the snapshot can name another element after the restore.
  - Expected (docs): refs from before a restore may name other elements; call `vm.ui.find`/`vm.ui.tree` again. Code change: WONT (see Known limits).
- [ ] **6.7 The Linux doctor probe writes the user name into JSON unescaped** (triage; cross-reference LINUX)
  - Where: `GuestRecipes.swift:218` `printf '{"user":"%s",…' "$(id -un)"`. A name with `"` or `\` breaks the JSON.
  - Expected: the name is escaped (`sed 's/\\/\\\\/g; s/"/\\"/g'`) before it is printed.
  - Test: `GuestRecipeTests.testTheLinuxProbeEscapesTheUserName` runs the rendered script under `/bin/sh` with a shadowing `id` on `PATH` that prints `a"b\c`, and parses the line. Confirm on the Linux guest.

### Task 7: Evidence and scripts

**Files:** `AlcoveKit/Sources/AlcoveControl/{ControlHandler+Diagnostics.swift, ControlHandler+Record.swift, Recording.swift, Trace.swift, VideoRecorder.swift, ScriptRunner.swift, ControlHandler+Actions.swift (HeldInput only)}`, their tests (`DiagnosticsTests`, `TraceTests`, `VideoRecorderTests`, `ScriptTests`), `docs/control-protocol.md` (Recording, Diagnostics, Event log, Scripts).

- [ ] **7.1 A run does not release keys a passed `vm.batch` step left down** [W2 concern]
  - Where: `ControlHandler+Actions.swift:125-136` (`HeldInput.note` ignores `vm.batch`); `ScriptRunner.swift:154`, `:227`.
  - Expected: `note` walks the `steps` of a `vm.batch` in order, so a failed or cancelled run releases them.
  - Test: `ScriptTests.testAFailedRunReleasesWhatAPassedBatchStepLeftPressed`.
- [ ] **7.2 Diagnostics says "(running)" when a recording ends during the video copy but its end wait times out** [final-wave AT5:80 M-C3]
  - Where: `ControlHandler+Diagnostics.swift:870` (`(running)`), `:1080-1083`, `:1046`.
  - Expected: `summary.txt` reads `(ending)` on that path.
  - Tests: `DiagnosticsTests.testRecordingThatEndsDuringTheCopyIsWaitedForAndCopiedWhole`, `…ButDoesNotFinishIsNamedEndingInTheSummary` (hook through `DiagnosticsTiming`).
- [ ] **7.3 The last video frame is never shown** [final-wave AT5:87 M7]
  - Where: `VideoRecorder.swift:200` `endSession(atSourceTime: last)`; `docs/control-protocol.md:1443-1445`.
  - Expected: the session ends one frame interval after the last frame; update the docs.
  - Test: `VideoRecorderTests.testTheFrameReadAtTheEndIsShownForOneFrameInterval`.
- [ ] **7.4 A rename ends the VM's recording, undocumented and untested** [FW5 concern]
  - Where: `ControlHandler+HTTP.swift:585-590` (`vmRenamed` → `forget(vm:)` → `forgetRecording`, `ControlHandler+Record.swift:281-289`); `docs/control-protocol.md:1387-1389` names only delete.
  - Expected: the docs say a rename ends the recording like a delete. (Test lives in `TraceTests`; `ControlHandler+HTTP.swift` is not edited.)
  - Test: `TraceTests.testRenamingTheVMEndsItsRecordingAndForgetsIt`.
- [ ] **7.5 The diagnostics bundle names no HTTP capture state** [integration-3 concern 3; control-guest; FW5 skip as feature]
  - Where: `ControlHandler+Diagnostics.swift` (no capture or journal reference).
  - Expected: one summary line: capture active (port, since), lost (reason), or a journal entry not yet restored; a row in the Diagnostics docs.
  - Test: `DiagnosticsTests.testSummaryNamesTheHTTPCaptureState`.
- [ ] **7.6 Evidence docs** [final-wave AT5:87 M8c, M8d]
  - `docs/control-protocol.md:1614` `dumps/<file>`: dumps without a readable time are collected too (`ControlHandler+Diagnostics.swift:792`).
  - `:1490-1491` `truncated`: entries cut by `max` do not set it (`GuestRecipes.swift:324`).

### Task 8: Engine and app

**Files:** `AlcoveKit/Sources/AlcoveEngine/**`, `AlcoveKit/Sources/AlcoveQMP/QMPCommands.swift`, their tests, `docs/control-protocol.md` (snapshots, suspend, limits).

- [ ] **8.1 Flaky: `testCDROMVirtioBusOption`** [final-wave AT2:53; reopened by the SMBIOS host key]
  - Where: `QEMUCommandBuilderTests.swift:156-167` pins the token and MAC, but `agentKey` is random; `QEMUCommandBuilder.swift:120-121` puts `alcove-hostkey=<64 hex>` on the command line, and `:167` asserts the whole line has no `cd0`.
  - Expected: pin `agentKey` (as `testWindowsProfileGolden` does) and assert on the `-drive`/`-device` arguments only.
- [ ] **8.2 Test gap: the agentKey refusal on the resume path** [review-final-fixes M3, e15a02c]
  - Where: `VMController.swift:175-179` (guard before the resume branches at :181/:196); `VMControllerFakeEngineTests.swift:996` covers cold start and `discardChanges`.
  - Test: `VMControllerFakeEngineTests.testResumeIsRefusedWhenTheAgentKeyIsNot64HexadecimalDigits` (suspended session survives, no engine starts).
- [ ] **8.3 Fixed sleeps before exact state assertions** [same class as 7339e86]
  - Where: `VMControllerFakeEngineTests.swift:177-179`, `:199-201`, `:226-229` (`Task.sleep(500 ms)` then an exact `log.states`); `DisplayDrainTests.swift:46` (assumes 10 000 updates drained in 500 ms).
  - Expected: `waitUntil` on the expected last state, then the "no further state" check; the drain test waits for a sentinel message.
- [ ] **8.4 Suspend to disk runs at the default migration bandwidth** [at2-results "Open"]
  - Where: `VMController.swift:377-378` (`qmp.stop()` then `qmp.migrate(uri: "file:…")`), no `migrate-set-parameters` in `QMPCommands.swift`.
  - Expected: suspend sets `max-bandwidth` to the largest accepted value before `migrate`. Confirm the parameter and its effect on `file:` migration in `build/qemu-src/qapi/migration.json` and `migration/` first.
  - Test: `VMControllerFakeEngineTests.testSuspendRaisesTheMigrationBandwidthFirst` (command order); optional timing check in the real-engine `testSuspendToDiskAndResume`.
- [ ] **8.5 Check: a template start while a clone outside its list runs** [final-wave AT2:79; engine-app §2] — real engine, no guest OS
  - Where: `VMController.swift:162-166` sees listed and sibling clones only; the rest relies on QEMU image locking on macOS.
  - Test: `VMControllerTests.testTemplateStartFailsWhileACloneOutsideItsListRuns`. If the lock does not hold, add the limit to `docs/control-protocol.md:2608-2616`.
- [ ] **8.6 Check: `scripts/build-qemu.sh` after the comment-only change of patch 0003** [final-e2e-results "Not verified"]
  - Run the script on a tree patched before 69d1291; the re-patch rebuilds and the real-engine tests pass. If the warning about "edits that are not exactly qemu-patches" fires for a patch-only change, make the script name that case.

### Task 9: MCP

**Files:** `mcp/**`, `scripts/test/mcp-smoke.py`, `scripts/test/mcp_stdio.py`.

- [ ] **9.1 `alcove_http_requests` drops `headersTruncated`** [FW2 concern]
  - Where: `mcp/src/tools/http.ts:36-60` (notes), `:159` (structured fields); proxy field `guest-tools/internal/mitm/ops.go:286`.
  - Expected: a note that the capture left out header pairs beyond 64 KiB, and the field in the structured result.
  - Test: `http.test.ts` "alcove_http_requests detail names header pairs the capture left out".
- [ ] **9.2 `alcove_start_vm` keeps waiting on refusing tools; `alcove_vm_status` does not describe `toolsRefused`** [W1 concern 4]
  - Where: `mcp/src/tools/core.ts:85-93` (wait loop and final text "no tools installed, or still booting"), `:36` (description).
  - Expected: when `vm.status` carries `toolsRefused`, the wait stops and prints that sentence; the description names the field.
  - Test: `core.test.ts` "alcove_start_vm stops waiting and prints the sentence when the guest tools refuse the host"; `results.test.ts` description check.
- [ ] **9.3 A serial call's timer runs while it waits behind earlier serial calls** [FW7 concern]
  - Where: `mcp/src/control.ts:135-160` (timer starts at send); server rule `ControlHandler.swift:209` (`isConcurrent`), `docs/control-protocol.md:61-63`.
  - Expected: a serial call's timer starts when the serial call before it on the connection has answered or failed; concurrent ops start at send. The TS op set mirrors `isConcurrent`.
  - Tests: `control.test.ts` "a serial call's timeout counts from the answer of the serial call before it", "a concurrent call's timeout counts from its send", and a test that reads the case labels of `isConcurrent` from `AlcoveKit/Sources/AlcoveControl/ControlHandler.swift` and compares them with the TS set.
- [ ] **9.4 Server sentences name control ops and camelCase parameters** [mcp M4; FW7 skip]
  - Where: `mcp/src/toolkit.ts:72-75` (`fail` passes `e.message` through).
  - Expected: `fail` maps the `vm.*` op names it knows to tool names (`vm.start` → `alcove_start_vm`) and `parameter '<camelCase>'` to the tool's snake_case name. Together with 5.2 an agent sentence reaches the model with tool names.
  - Test: `toolkit.test.ts` "fail names tools and tool parameters in server sentences".
- [ ] **9.5 MCP checks nobody ran** [FW7 guest list; final-e2e-results MCP R7] — **Windows VM**
  - Extend `mcp-smoke.py --vm`: (a) two parallel first calls share one control connection (count connections in the server log or with `lsof`); (b) `alcove_script_run` without `name` while this session holds the script VM's lease passes; (c) `alcove_script_save` from a recording with `alcove_http_*` calls prints the capture warning and saves no http steps; (d) `alcove_script_run` with a failing script shows the failure image [at6-results].

### Task 10: e2e scripts and repository docs

**Files:** `scripts/test/at4-e2e.py`, `at5-e2e.py`, `agent-windows.py`, `README.md`, `CONTRIBUTING.md`, `docs/superpowers/plans/2026-10-14-handoff.md`, `.github/workflows/ci.yml` (comments only), `docs/control-protocol.md` and `docs/agent-protocol.md` (Limits / known-limit sentences).

- [ ] **10.1 `at5-e2e.py` masking check is vacuous** [final-wave AT5:87 M1] — **Windows VM**
  - Where: `at5-e2e.py:609-610`. Expected: take the one `vm.ui.type` trace line and expect `params.text == MESSAGE` masked as documented.
- [ ] **10.2 `at5-e2e.py` check 5 never asserts the hung-window sentence** [M2] — **Windows VM**
  - Where: `:752-763`. Expected: `ui-tree.txt`, or `ui-tree.error.txt` containing `is not responding`.
- [ ] **10.3 `at5-e2e.py` copies the check-3 mini dump into three bundles; dead variables** [M3, M8b] — **Windows VM**
  - Where: `:747`, `:772`; `framed` `:599`, `clicked` `:608`, `statuses` `:885`. Expected: checks 5 and 6 pass a `sinceMinutes` that leaves the dump out; unused variables removed.
- [ ] **10.4 Limits text on recording without a window server session** [docs-e2e]
  - Where: `docs/control-protocol.md:2631-2633` ("from a Terminal"). Expected: the spec's wording (detached with `nohup` in the Aqua session; an SSH login or launchd daemon not tried). Task 11 check 11.3 updates it again with the result.
- [ ] **10.5 `vm.type` refusal sentence in the docs** [docs-e2e]
  - Where: `docs/control-protocol.md:111`. Expected: the "names itself" note covers every sentence of the row, as the code names the calling op.
- [ ] **10.6 README quick start fails without `build/alcove-proxy`** (triage)
  - Where: `README.md:62-70`; `project.yml:36-40` refuses the build; `CONTRIBUTING.md:144-147` has the step. Expected: the README builds `alcove-proxy` before `xcodebuild`.
- [ ] **10.7 Handoff doc is stale** [progress.md "Handoff doc stale"]
  - Where: `docs/superpowers/plans/2026-10-14-handoff.md:20-21` (`git checkout ai-testing-tools`, Swift 6.4). Expected: `main`/current branch and the CI toolchain (Swift 6.3.3).
- [ ] **10.8 CI comment with stale counts** (triage)
  - Where: `.github/workflows/ci.yml` comment above the Swift Test step ("3 end-to-end cases", "119 tests"). Expected: the comment says what the step does, without counts.
- [ ] **10.9 at4-e2e checks nobody ran** [at4-results "What is not verified"] — **Windows VM**
  - Add checks: `vm.deploy` of a single file as `path`; `vm.deploy` with `install` of a small exe or msi fixture; the event baseline after `vm.stop`/`vm.start` and after `vm.snapshot.restore` (the restore check runs only when the free-space rule of at6 allows a snapshot).
- [ ] **10.10 `agent-windows.py` hard-codes user, port and VM name and has not run since host authentication** [final-wave AT1:97, :117]
  - Where: `scripts/test/agent-windows.py:22,93,97`; README:220 lists it.
  - Expected: if `agent-rpc-windows.py` and `install-agent.py` cover its checks, delete it and repoint README:220; otherwise give it `--user`, the agent key through `agent_key.py`, and the signal-safe cleanup of `alcove_ctl.py`.
- [ ] **10.11 Document the known limits** (WONT items marked *(doc)* below)
  - Add each to the Limits/known-limit sentences of the section it belongs to, in one sentence with the next step where one exists.

### Task 11: Windows VM check session — **Windows VM**

Run on the integrated tree after Tasks 1–10, with the rebuilt agent installed (`install-agent.py`). Record each result in `docs/superpowers/plans/2026-10-15-followups-results.md`. A check that finds a defect gets a test-first fix in the file's owning area.

- [ ] **11.1** `vm.doctor` `session` row with a non-ASCII local user name (create a user such as `테스트`, log on, run doctor; delete the user afterwards) [final-wave AT2:50; FW4 skip].
- [ ] **11.2** Capture journal: two hosts (app socket and `alcovectl serve --dir …`) with equally named VMs; a symbolic link as `--dir` [at7-results "Not run"].
- [ ] **11.3** Recording, text recognition and video with `alcovectl serve` started without a window server session (an SSH login to the Mac); skip and note it when no SSH login to this Mac is set up [at5-results "Not verified"].
- [ ] **11.4** A full dump in a bundle; the 500 MiB budget with a dump above it [at5-results].
- [ ] **11.5** SIGINT and SIGTERM to `run-script --in-process` during a `--snapshot` restore, only when ≥ 18 GiB are free [at6-results].
- [ ] **11.6** SIGHUP, SIGINT and `nohup` on at1, at2, at3, at5, agent-rpc-windows and uia-helper-check [final-e2e-results "Not verified"].
- [ ] **11.7** Each of at2, at3, agent-rpc-windows and uia-helper-check refuses to start on a leftover `C:\alcove-e2e`.
- [ ] **11.8** `install-agent.py --user` with a non-default user, and its `starting`, `paused` and `stopped` branches [at1-results "Not exercised"].
- [ ] **11.9** `ctl.py vm.screenshot format=jpeg`; a screenshot and a `vm.find_text` above 1280x800 [final-e2e-results; at3-results].
- [ ] **11.10** Evidence file modes: recording folder 0700; trace, frames, video, diagnostics bundle files and `*.failure.png` 0600 [ruling in final-review progress.md].
- [ ] **11.11** `vm.snapshot.create` and `vm.snapshot.delete` whose caller is cancelled (the guest runs on, no QEMU job left in `query-jobs`); `vm.snapshot.delete` during a restore [at6-results; final-e2e-results].
- [ ] **11.12** `dpiScale` on a guest whose recommended scale is not 100 % (set 125 % in the guest, run `vm.set_environment dpiScale`, read it back) [at2-results].
- [ ] **11.13** `vm.record.stop` issued while `vm.collect_diagnostics` copies the video (exercises 7.2 on a real recording) [at5-results].

### Task 12: App checks with a person — **Windows VM + a person (or computer use)**

The app has no test target; each is a manual check, recorded in the results doc of Task 11. A defect found gets a fix in `Alcove/Sources/**` with a unit test where the logic lives in AlcoveKit.

- [ ] **12.1** The refusal label and popover for refusing guest tools (`VMWindowView.swift:280-287`, after 5.6).
- [ ] **12.2** Quit with an active recording, with a VM running and with none (`AlcoveApp.swift:168-177`): the video is kept and plays.
- [ ] **12.3** Rename and delete of a VM whose engine was left by an earlier session (`AppModel.swift:16`, `:232-240`): refused with the sentence naming the next step.
- [ ] **12.4** `vm.http.start` with the app as host, using `Contents/MacOS/alcove-proxy`.
- [ ] **12.5** Rename of a VM with a capture journal entry (`AppControlServer.swift:98-107`); then the next tools connection restores the guest.
- [ ] **12.6** The app's window paths during a capture: boot, restore, Suspend All, Reset, the snapshot sheet [at7-results "Not run"]; the app as one of the two hosts of at6 checks 10 and 13 [at6-results].

---

## LINUX (cross-reference for the Linux guest verification)

| id | item | where |
|---|---|---|
| L1 | The agent reads `alcove-token` and `alcove-hostkey` from `/sys/firmware/dmi/tables/DMI`; `agent-linux.py` passes | `guest-tools/internal/token` |
| L2 | A real install writes its log under `/var/log/alcove` (0700, no-follow) | `cmd/alcove-agent/install_other.go:16-55` |
| L3 | exec, fs and jobs ops end to end; `proc.list` `name` (base name of the first argument) against `ps comm` | `internal/server/sys_unix.go:57` |
| L4 | CA removal with `update-ca-certificates --fresh` (does plain `update-ca-certificates` drop the moved `.crt`; `--fresh` also drops hand-made links) | `GuestRecipes.swift:690,723` |
| L5 | `vm.set_environment` sh recipes, the doctor probe (incl. `freeBytes: null` when `df` fails, and 6.7), `vm.deploy` to a Linux guest | `GuestRecipes.swift`, `ControlHandler+Deploy.swift` |
| L6 | `vm.event_log` journal recipe, case of `provider`, message cut; the Linux path of `vm.collect_diagnostics` | `GuestRecipes.swift`, `docs/control-protocol.md:1478-1488` |
| L7 | HTTP capture on Linux: CA install and proxy environment | `GuestRecipes.swift` HTTP recipes |
| L8 | `vm.wait_for` conditions against a Linux guest | `ControlHandler+Wait.swift` |

## Known limits (WONT)

*(doc)* = not documented yet; Task 10.11 documents it. Items without the mark are documented already or internal.

**Agent**
- Killing a tree misses grandchildren whose parent already exited (Job Objects need a suspended start, which `os/exec` does not offer, and nesting under Task Scheduler); documented with `proc.kill` as the next step (`docs/agent-protocol.md:343-348`).
- The exec timeout or `exec.kill` can hit a reused pid in the instant between reaping and stopping the timer; closing it needs `waitid(WNOWAIT)` or a second process handle. *(doc)*
- A job id is reused after a failed start; the failed job is never listed (`docs/agent-protocol.md:373-374`).
- `timeout_ms` has no upper bound; a closed connection ends `exec.run`, and jobs are meant to outlive connections. *(doc)*
- On Windows the port stays taken briefly after the agent ends; the listen retry covers it. *(doc)*
- The 16-handshake cap yields to a program that opens connections faster than one host round trip (`docs/agent-protocol.md` "What it does not prevent").
- One-way authentication: a program holding 7645 while the agent is down receives the host's requests (ruling in progress.md; documented).

**Proxy**
- `SetReadDeadline` errors are ignored; they occur only on a closed connection, which the next read or write reports.
- Concurrent proxy connections are not limited and in-flight headers sit outside the body budget (1 MiB per request). *(doc, with 3.3)*
- Programs with their own trust store (Node, Python, Java, Firefox) were not tried in the guest; the docs cover own trust stores (`docs/control-protocol.md:1820-1824`).

**Control**
- A password typed through the clipboard stays in the guest clipboard (`docs/control-protocol.md:766-770`); a restore would race the app's read of ctrl+v.
- Helper refs are not tracked across `vm.snapshot.restore` in code (docs in 6.6).
- `UITiming`/`WaitTiming` seams are `nonisolated(unsafe)` globals; test-only.
- One `win.list` can be sent at the instant of a cancel; read-only.
- `proxyEnded` holds the capture gate during its restore; serialising guest restores is the gate's purpose.
- `afterRestore`, `vmDeleted`, `vmRenamed` end host-side capture state outside the gate; the guest restores run in their own tasks.
- The app's rename journal update is not awaited; the next tools connection runs the cleanup.
- WinINET's auto-detect flag is not recorded; WinINET derives that blob and every recorded value came back in the AT7 trial.
- Double masking of the `vm.http.request` trace; both masks hide the value.
- The nested-link and 5000-entry deploy refusals come after the stop step and the marker write (`docs/control-protocol.md:906-907`).
- `.remote` used for host-side refusals; the reply text is the same.
- Sync folds names with `lowercased()`, not the NTFS upcase table; only exotic characters differ.
- An extra `fs.stat` in sync tells a missing root from a listing error.
- Push, pull and sync time out per request, not per transfer; a size-dependent deadline is a design change.
- `FrameDiff` has no row fast path; `FrameSource` zero-fills its buffer; the engine never truncates the frame file. Performance only.
- `imageScale` is horizontal only; the aspect ratio is kept.
- The action-op list exists in three places; refactor without behaviour change.
- `.remote` from `exec.read` is a hard failure; those errors do not heal.
- `TCPLineTransport.close()` uses `queue.sync`; nothing calls it on its own queue.
- A running Vision call cannot be stopped (Vision API); callers leave the queue.
- A request line over 8 MiB closes the connection (`docs/control-protocol.md:26`).
- No cap on concurrent tasks per connection; socket clients are trusted. *(doc)*
- `HeadlessRegistry` caches controllers by name (`docs/control-protocol.md:2608-2610`); `HeadlessRegistry.stopAll` failure collection is unreachable for a live VM.
- The `KEY` marker over-masks (`sort --key=2`, `MONKEY=1`); the safe side.
- Secret names `pwd`/`passwd`/`pin` and secrets under 8 characters inside longer strings are not masked (`docs/control-protocol.md:2380-2388`); MCP and Swift share the rule.
- No server-side total bound for `script.run`; each step is bounded, closing the connection cancels it, the MCP caps at two hours.
- `.partial-<uuid>` can be left by a write at the instant of `rmdir`; hidden from the file list.
- No seam for the second cancellation check before the `ui.at` question; nothing is sent either way.
- `record()` work runs inside the input gate and frames are captured twice with observe; performance by design.
- Child processes of `alcovectl` inherit ignored SIGINT/SIGTERM; QEMU sets its own handlers and `alcove-proxy` ends with stdin.
- `AppControlServer.endCaptures()` also ends recordings; the name is narrower than the behaviour.

**Engine and app**
- A qcow2 image does not shrink when a snapshot is deleted. *(doc)*
- No control op suspends a VM; a feature, not a defect.
- AT6 N1 "window A" and the shutdown QMP timeout bound have no test; ordering needs an actor hook, the bound a 30 s load.
- Closed-source and upstream questions (`hv_vm_protect`/`hv_vm_unmap`, EDK2 writing a variable on every boot, upstream status of patches 0002/0003) cannot be checked locally.
- `alcove-proxy` is ad-hoc signed inside the bundle; a notarised release must sign it separately. *(doc, release notes)*

**MCP**
- `alcove_start_vm` resume with `wait_timeout_s` is not run in a guest: no control op suspends a VM; unit-tested.

**e2e and coverage**
- Windows coverage not planned: a window of higher integrity, the UAC secure desktop, Electron/WebView2, several monitors, a locked session, release-build timings, a guest without an English message table, a helper replaced after a timeout, more than 500 events, `marksTruncated` (each needs a separate guest setup; host logic is unit-tested).
- The debug `alcovectl` spends half a core on `screen_idle` waits; the scripts use the debug build.
- at1 moves the pointer to 640,400; every guest display contains that point.
- A failed at2 run leaves exited jobs listed until the agent forgets them.
- Notepad keeps a tab-state file written by the scripts' Notepad steps.

## Appendix: already fixed (evidence at 7339e86)

**Agent:** guest-agent I1 and rereview-go N1, rereview-w1 I1–I3/M1–M6 — SMBIOS host key and Ed25519 v2 signature (b6fb354 and the W1 round 3 commits); m1 `proto.go:143-156`, `rpc.go:231-238`; m2 61f5acb; m3 e5026c0; m6 a9be3a0; m7 1454a3b; review-final-fixes M1 9b998fa (`auth.go:198-199`, test `auth_test.go:386`), M2 7f5b2e3 (`main.go:136-142`), resolveProgram dbc18c1; rereview-w1r3 N1–N6 bd51e5b, 4ea80e9, d6e50c1, e15a02c, b095d1d; rereview-go N3 `files.go:129-143` (`ensureDeployRoot`, `locked`), N7 `rpc.go:231-238`; AT1:32–41 clipboard mutex, hello before `addConn`, per-connection queue, 256 in flight, rpc_test send helper, no-id refusal `rpc.go:211-213`; AT1:66 argv vs shell, ring, exec.read below 4, empty cwd, taskkill from the system folder (11f1430, 45f7b23); AT1:69/70/90 fixed; AT1:71 link root, skipped count, write offset, `C:foo`/`\x`, ENOTDIR, FIFO (4683dee); AT1:75 pid 0, stdin pipe, exec.write sentence (`jobs.go` `markStarted`); AT1:112/117/122 UTF-32 BOM, 256 KiB piece, surrogate tail test, invalid UTF-8 cut, recursive fs.list bounded by the reply refusal; AT4:24 helper.log cap, stdin timer, emit, Close; AT4 Go M1–M12 (`acl_windows.go:182,344`, launch gate, claim eviction, launcher stop; docs M4/M5/M9); helper M3/M4 documented (949022c); HKCU App Paths a5cac28; helper environment allowlist 773a497; D1 ProgramData c88ffdd.

**Proxy:** I1 `ca.go:202-208` and parseCA checks, `makePrivate` `ca.go:104`; I2 `handler.go:150-154,264-267` (`TestCloseEndsARuleDelay`); I3 `websocket.go:14`, `handler.go:107`; M1 leaf cache `ca.go:302`; M2 store reserve/release/capHeaders; M3 `proxy.go:303`; M4 `proxy.go:147,173`; M5 sentences in control.go/ops.go; M7 docs `control-protocol.md:1694-1697`; M8 tests split; N4 `store.go:147`; N5 `proxy.go:314-315`; AT7 Expect 100-continue `proxy.go:115`, 1xx `handler.go:287`, User-Agent/Date `handler.go:361-362`, drain test `drain_test.go:46`, idle tunnel text `tunnel.go:84`, 400-drain and trailer tests.

**Control core:** control-core C1, C2, I1–I3, M1–M5, M7, M8 (6961e04, ffbccdd, 846a2c8, 4e362c5, 0c7a2ad, 08a1a30, ccc3d88); rereview-core N1–N7 (f30593b, 06890f8, ded154e, 0077e4a, ca1a6f4, d029a05); AT1:57 local part leak `AgentFiles.swift:207-212`, `joinGuestPath`, pull edge tests; AT1:81 deinit trap and AT1:94 call cancellation (0c7a2ad); v1 exec swap closed by refusing agents without auth (`AgentClient.swift:136-140`); reply over 8 MiB `replyTooLong`; request parsed once (`ControlServer.swift:182`); AT2:33 forward race (`ControlHandler+State.swift:133,144`); AT2:42 release without default `now` (`Leases.swift:36`), `set_resolution` injected clock; AT3:29 `Frame.swift:19`; AT3:33 regex without query refused; AT3:46 `Observation` renamed; AT3:47 env read once (11ff1a4), gate cancellation, close cancels all tasks, batch releases keys; AT3:52 settle sentence; AT3:60 overshoot, docs for `process_exited`; AT3:63/67 retry, first-frame sentence `Wait.swift:198`; AT3:74 languages validated at parse (`WaitConditions.swift:210`); AT3:92 N1/N2 46d10ff; integration-3 concern 4 (`ControlServerTests:170-173`); AT4:99 attempts comment; AT4:130 `requestID` tail, `setClipboard` comment; AT5:68 lone surrogate (`unreadableRequest`), frame size read per call (`ControlHandler.swift:582-584`).

**Control guest-facing:** control-guest I1 67b9188; I2 b7533e7, 7c6324e (`ControlHandler+Deploy.swift:377-396`); I3 d49730f; M2/M3 60b9334; M4 and engine-app I1 cbf676c; M5 d49730f; M7 b7533e7; M9 340c20e; M10 and M11 tests in `ControlUITests`; rereview-guest N1 ded154e, N2 df13507, N3/N6 7c6324e, N4 f30593b, N5 0ca7dbc; AT6 N2 f5aed5d; AT2:50 engine row, state hint; AT2:56 not-checked rows; AT4:90 M1/M3/M4/M6; AT5:68 launch sentence maps `fs.stat`; AT5 M6 Linux message cut; FW4 owner `unknown` refused.

**Evidence and scripts:** evidence I1 (`VideoRecorder` deinit, `endRecordings` in shutdown), R1 f0e959a; I2 e7e79c5; M1 e644857; M2 bc90abf; M3 e7e79c5, 5c126b4, dc3eb42; M4–M6 dc3eb42; M7 5c126b4; AT5 T2 stuck frame provider dbb3bf6; AT5 T4 kept file named, M-B3 3d87c1b, M-C3 note, M-D2 5c126b4; AT5 T6 M4/M5/M6, M8a; AT5 T1 test gaps; AT6 T1 lease-lost flake 26a2f43, docs 8f2f700; AT6 T4 unbounded waits, cancelled `vm.exec` lease (`AgentClient.swift:305-315`); AT6 T2 click cancelled during hold (`ControlHandler+Actions.swift:247-249`); SIGTERM to serve documented 17abb16.

**Engine and app:** M1/AT6 N1 1455ece (`VMController.swift:496`, `:331`); M2 and rereview-guest N8 1455ece, b8af004; cancelled snapshot jobs dismissed (`QMPCommands.swift:185`); M3/AT4:130 6f7013b, fake-engine teardown by process group; M4 38aedce, rereview-guest N7 96917db; M5 comments; M6 38aedce, 9c0bfd0; M7 69d1291; M8/AT3:41/AT6 N5 `waitUntil` (`VMControllerFakeEngineTests.swift:103,425`); AT6 N4 fbabbda; shutdown QMP timeouts `VMController.swift:331,336`; AT2:64 base disk and UEFI hash checks, deleteClone by recorded path, port selection (bcccd1d); AT3 drain wiring 71e7c47; `ALCOVE_QEMU_DIR` 1eec3ed.

**MCP:** I1 8963a99; I2 c63069e; I3 and M1 cfd4e93; M2 and the mismatch table 426caa3; M3, M5–M7, M9–M12, M14 ffe029f, c63069e; M8 41dc09c; M13 66a20fd; R2/R3 and the shell.ts comment 3e453ea; AT1:46 handler tests; AT1:47 ffe029f; AT2:25–28 (`state.ts:124,382`, `leases.ts:43-55`, `leased-client.test.ts`); AT3:38/39/46 (`observation.ts`); start_vm `resumed`/`clockSynced` (`core.ts:56,74-81`).

**e2e and docs:** docs-e2e I1 and M1–M8 c54a9e2; M9 `at7-e2e.py:494,518`; M10 ed796fd; M11 CP:1694, :2262, :2324-2328; M12 d029a05; M13 CP:116; at4 inherited SIGHUP ignore `at4-e2e.py:1366`; AT6 N3/N6 `at6-e2e.py:187,471,748`; AT1 check deadlines, console-window check, ssh status, host name, traceback; README tool count 76.
