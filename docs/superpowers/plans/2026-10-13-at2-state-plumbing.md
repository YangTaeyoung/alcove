# AT2 — VM state and plumbing: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A coding agent can reset a VM to a known state in seconds, run several isolated copies, reach guest ports from the Mac, cut the network, change guest environment settings and ask one tool what is wrong with the setup.

**Architecture:** `VMTarget` grows snapshot, monitor and link methods backed by `VMController` and QMP. `ControlHandler` adds state ops, an in-memory lease table that guards every mutating op, and host-side guest recipes (PowerShell or sh run through the agent's `exec.run`). The engine gains linked clones and throwaway sessions built on qcow2 overlays. The MCP server exposes the `state` toolset and attaches lease tokens on its own.

**Tech Stack:** Swift 6 language mode, macOS 15 (`AlcoveKit/`, `Alcove/`). TypeScript MCP server (`mcp/`). Python 3 standard library for end-to-end scripts. QEMU 11.1.1 QMP.

**Spec:** `docs/superpowers/specs/2026-10-13-ai-testing-tools-design.md`

## Global Constraints

- Control protocol names are `vm.<group>.<verb>` with camelCase params; MCP tool params are snake_case.
- Error strings are plain sentences that name the next step.
- Guest-side actions go through `AgentClient.call("exec.run", ...)`; this plan adds no agent ops.
- Runtime port forwards bind `127.0.0.1` only.
- A snapshot name follows `VMController.checkSnapshotName` (non-empty, at most 128 characters, no newline).
- Comments, test names and test comments describe what the code does now. No history, rationale, measurements or review notes in code.
- Code, identifiers and repository docs are English.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01SKM8m5iFzR5Kkhm3MsJdU1
  ```
- Work happens on branch `ai-testing-tools` in `/Users/giraffewithcode/dev/personal/alcove`. Commit only the files of the task. Do not push.

## Review Focus

1. Restoring a snapshot while the agent connection is open: the next agent call works without the caller reconnecting, and the guest clock is within 5 s of the host (Task 1 `testRestoreDropsAgentAndReportsTools`, Task 6 check 2).
2. Adding a forward for a host port that is already in use: the error says the port is taken and names `hostPort: 0` (Task 1 `testForwardAddReportsMonitorError`, Task 6 check 3).
3. A lease whose owner disappeared: it expires after its TTL and the next client can act (Task 2 `testLeaseExpires`).
4. Starting a template VM while a clone exists, or deleting a VM that is not a clone: refused with the reason (Task 4 `testTemplateRefusesToStart`, `testDeleteRefusesNonClone`).
5. A VM stopping (or crashing) with runtime forwards, a lease and a throwaway overlay: forwards are forgotten, overlay files are removed, the lease stays until TTL (Task 1 `testForwardsForgottenWhenStopped`, Task 4 `testEphemeralOverlayRemovedOnStop`).

---

### Task 1: Snapshots, monitor commands, forwards and link through the control protocol

**Files:**
- Modify: `AlcoveKit/Sources/AlcoveQMP/QMPCommands.swift`, `AlcoveKit/Sources/AlcoveEngine/VMController.swift`, `AlcoveKit/Sources/AlcoveControl/VMTarget.swift`, `ControlHandler.swift`
- Create: `AlcoveKit/Sources/AlcoveControl/ControlHandler+State.swift`
- Tests: `AlcoveKit/Tests/AlcoveQMPTests/QMPClientTests.swift` (new cases), `AlcoveKit/Tests/AlcoveControlTests/ControlStateTests.swift`, `ControlHandlerTests.swift` (`FakeTarget` gains the new requirements)

**Interfaces:**
- Produces:
  ```swift
  // QMPCommands.swift
  /// `human-monitor-command`; returns the monitor's text output.
  public func humanMonitorCommand(_ line: String) async throws -> String
  /// `set_link` for a net client name.
  public func setLink(name: String, up: Bool) async throws

  // VMController.swift
  public static let netdevID = "net0"            // QEMUCommandBuilder uses this constant for `-netdev user,id=`
  public func monitorCommand(_ line: String) async throws -> String   // notRunning unless active
  public func setNetworkLink(up: Bool) async throws

  // VMTarget.swift (protocol requirements; ControllerTarget and FakeTarget implement)
  func snapshots() async throws -> [VMController.SnapshotInfo]
  func createSnapshot(named name: String) async throws
  func restoreSnapshot(named name: String) async throws     // ControllerTarget drops its agent client first
  func deleteSnapshot(named name: String) async throws
  func monitorCommand(_ line: String) async throws -> String
  func setNetworkLink(up: Bool) async throws
  func staticForwards() async -> [VMConfig.PortForward]
  ```
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.snapshot.list` | `name` | `{snapshots: [{name, date (ISO 8601), vmStateBytes}]}` |
| `vm.snapshot.create` | `name`, `snapshot` | `{snapshot}` |
| `vm.snapshot.restore` | `name`, `snapshot`, `waitTools?` s (default 30) | `{snapshot, tools: bool}`; runtime forwards stay in place |
| `vm.snapshot.delete` | `name`, `snapshot` | `{}` |
| `vm.forward.add` | `name`, `guestPort`, `hostPort?` (0 or absent picks a free port) | `{hostPort, guestPort}` |
| `vm.forward.remove` | `name`, `hostPort` | `{}` |
| `vm.forward.list` | `name` | `{forwards: [{hostPort, guestPort, kind: "config"|"runtime"}]}` |
| `vm.set_network` | `name`, `up` (bool) | `{up}` |

- Monitor lines: `hostfwd_add net0 tcp:127.0.0.1:<host>-:<guest>` and `hostfwd_remove net0 tcp:127.0.0.1:<host>`. A non-empty monitor reply is an error; when it contains `Could not set up host forwarding rule` the message is `host port <n> is taken; pass hostPort: 0 to let Alcove choose`.
- A free host port comes from binding a TCP socket to `127.0.0.1:0`, reading the port and closing it.
- Runtime forwards are remembered per VM name in `ControlHandler` and forgotten when the VM is found not running or is stopped through `vm.stop`.
- Unknown snapshot on restore/delete → `no snapshot '<s>' in '<vm>'; call vm.snapshot.list` (checked against `snapshots()` before the QMP job).

- [ ] **Step 1: Write failing tests.**
  - QMP (against `FakeQMPServer`): `testHumanMonitorCommandReturnsText` (request is `human-monitor-command` with `command-line`), `testSetLinkSendsNameAndUp`.
  - `ControlStateTests` with `FakeTarget` recording calls: `testSnapshotListMapsFields`; `testSnapshotCreateRestoreDelete` (restore calls the target, result has `tools`); `testRestoreUnknownSnapshot` (error text above, target not called); `testRestoreDropsAgentAndReportsTools` (`FakeTarget.restoreSnapshot` swaps its agent to a fresh `FakeAgent`-backed client; the result is `tools == true` and a following `vm.exec` succeeds); `testForwardAddUsesMonitorLine` (exact line for explicit ports); `testForwardAddPicksFreePort` (`hostPort` in 1024...65535 and the monitor line carries it); `testForwardAddReportsMonitorError`; `testForwardListMergesConfigAndRuntime`; `testForwardRemove`; `testForwardsForgottenWhenStopped`; `testSetNetworkCallsTarget`; `testStateOpsNeedRunningVM` (stopped VM → the existing not-running error).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails to compile.
- [ ] **Step 3: Implement.** `QEMUCommandBuilder` uses `VMController.netdevID` in place of the literal `net0` (keep the argument output identical; `QEMUCommandBuilderTests` must still pass unchanged).
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: snapshots, runtime port forwards and network link"`.

### Task 2: Leases and resolution

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/Leases.swift`, `AlcoveKit/Tests/AlcoveControlTests/LeaseTests.swift`
- Modify: `ControlHandler.swift` (guard in `handle`, `vm.lease.*`, `vm.set_resolution`), `ControlHandler+State.swift`

**Interfaces:**
- Produces:
  ```swift
  struct LeaseTable {
      struct Lease { let token: String; let owner: String; var expires: ContinuousClock.Instant }
      /// Grants or renews; throws ControlError.failed when another token holds an unexpired lease.
      mutating func acquire(vm: String, owner: String, ttl: Duration, token: String?, now: ContinuousClock.Instant) throws -> Lease
      mutating func release(vm: String, token: String) throws
      /// nil when the op may run.
      mutating func refusal(vm: String, token: String?, now: ContinuousClock.Instant) -> String?
  }
  static func ControlHandler.isReadOnly(op: String) -> Bool
  ```
- `isReadOnly` is true for: `hello`, `vm.list`, `vm.status`, `vm.screenshot`, `vm.wait_idle`, `vm.clipboard.get`, `vm.exec.read`, `vm.exec.list`, `vm.process.list`, `vm.fs.list`, `vm.fs.read`, `vm.pull_file`, `vm.snapshot.list`, `vm.forward.list`, `vm.lease.acquire`, `vm.lease.release`, `vm.doctor`. Every other op with a `name` param is refused on a leased VM unless its `lease` param equals the token.
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.lease.acquire` | `name`, `owner` (free text), `ttl?` s (default 300, max 3600), `lease?` (renew) | `{lease, expiresIn}` |
| `vm.lease.release` | `name`, `lease` | `{}` |
| `vm.set_resolution` | `name`, `width`, `height` | `{width, height}` — the size of a screenshot taken after the guest answered, waiting up to 8 s for a change |

- Refusal text: `VM '<vm>' is leased by <owner> for another <n> s; pass its lease token, wait, or ask the owner to release it`.
- `vm.status` and `vm.list` rows gain `leasedBy` (owner) when a lease is active.
- `ControlHandler.init` gains `clock: @Sendable () -> ContinuousClock.Instant = { .now }` for tests.

- [ ] **Step 1: Write failing tests:** `testAcquireGrantsAndBlocksOthers` (a second `vm.lease.acquire` without the token fails with the refusal text; `vm.mouse.click` without token fails; with token succeeds; `vm.screenshot` without token succeeds); `testRenewWithToken`; `testReleaseNeedsToken`; `testLeaseExpires` (clock advanced past TTL → another client acquires); `testTtlIsCapped`; `testStatusShowsLeasedBy`; `testReadOnlyClassification` (table over every op name the handler knows — obtain the list from a new `static let knownOps: [String]` that the dispatcher's tests compare against the `switch`); `testSetResolutionReturnsNewSize` (fake agent records `resolution.set`; `FakeTarget` PNG swapped to the new size).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: leases guard mutating operations; set resolution"`.

### Task 3: Guest recipes — environment, clock, doctor

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/GuestRecipes.swift` (script text per guest OS), `ControlHandler+Guest.swift` (`vm.set_environment`, `vm.doctor`, clock sync), `AlcoveKit/Tests/AlcoveControlTests/GuestRecipeTests.swift`
- Modify: `ControlHandler.swift` (dispatch), `ControlHandler+State.swift` (`vm.snapshot.restore` syncs the clock)

**Interfaces:**
- Consumes: `AgentClient.call("exec.run", ["cmd": ..., "timeout_ms": ...])`.
- Produces:
  ```swift
  enum GuestRecipes {
      /// A script for the guest shell, or nil when the OS has no recipe for the setting.
      static func setClock(unixSeconds: Int, os: VMConfig.GuestOS) -> String?
      static func setTimeZone(_ id: String, os: VMConfig.GuestOS) -> String?
      static func setTheme(dark: Bool, os: VMConfig.GuestOS) -> String?
      static func setLocale(_ tag: String, os: VMConfig.GuestOS) -> String?           // BCP 47, e.g. ko-KR
      static func setKeyboardLayouts(_ tags: [String], os: VMConfig.GuestOS) -> String?
      static func setDPIScale(percent: Int, os: VMConfig.GuestOS) -> String?
      static func doctorProbe(os: VMConfig.GuestOS) -> String?                        // prints one JSON object
      /// Quotes a value for a single-quoted PowerShell or sh string.
      static func quote(_ s: String, os: VMConfig.GuestOS) -> String
  }
  ```
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.set_environment` | `name`, any of `theme` (`dark`/`light`), `timeZone`, `clock` (ISO 8601 or `host`), `locale`, `keyboardLayouts` ([string]), `dpiScale` (100–500) | `{applied: [{setting, ok, detail, takesEffect: "now"|"app restart"|"sign-out"}]}` |
| `vm.doctor` | `name` | `{checks: [{id, ok, detail, hint?}]}` |

- Doctor check ids, in order: `engine` (engine paths found), `host` (`app`/`headless`), `state`, `display` (frame size), `tools` (agent connected, version), `rpc` (agent `proto` ≥ 2), `exec` (cap present), then from the guest probe: `session` (user name, locked or not — locked when a `LogonUI` process exists on Windows), `disk` (free bytes of the system drive; not ok under 2 GiB), `clock` (skew against the host; not ok over 5 s, hint `vm.set_environment clock=host`), `network` (ok when the guest resolves `example.com`), `scale` (DPI percent). A VM that is not running yields the first three checks and a hint to start it. A missing agent yields a `tools` hint naming `scripts/test/install-agent.py`.
- Windows scripts use `Set-Date`, `Set-TimeZone -Id`, the `AppsUseLightTheme` and `SystemUsesLightTheme` values under `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` followed by a `WM_SETTINGCHANGE` broadcast of `ImmersiveColorSet`, `Set-Culture` plus `Set-WinUserLanguageList -Force`, and for DPI the first approach that works in the VM during Step 3 (try `SystemParametersInfo` with action `0x009F`; otherwise write the per-monitor `DpiValue` and report `takesEffect: "sign-out"`). Linux scripts cover `clock` (`date -u -s @<n>`) and `timeZone` (`timedatectl set-timezone`); other settings report `ok: false, detail: "not supported on linux guests"`.

- [ ] **Step 1: Write failing tests:** `testQuoteEscapesSingleQuotes` (PowerShell doubles `'`; sh uses `'\''`); `testRecipesAvailability` (table of setting × OS → nil or non-nil); `testClockRecipeCarriesSeconds`; `testSetEnvironmentRunsOneScriptPerSetting` (fake agent records `exec.run` commands; result rows in request order with `ok` from the exit code and `detail` from stderr); `testSetEnvironmentUnsupportedOnLinux`; `testClockHostUsesHostTime` (injected `now`); `testDoctorWhenStopped`; `testDoctorParsesProbe` (fake probe JSON → `session`, `disk`, `clock`, `network`, `scale` rows; skew 9 s → `clock` not ok with the hint); `testDoctorWithoutAgent`; `testRestoreSyncsClock` (after `vm.snapshot.restore` the fake agent received the clock recipe; result gains `clockSynced: true`).
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.** Try each Windows recipe once in the running VM `Windows 11` through `python3 scripts/test/ctl.py vm.exec name="Windows 11" command=...` and keep what works; record the DPI outcome in the report.
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: guest environment settings, clock sync after restore, doctor"`.

### Task 4: Linked clones and throwaway sessions

**Files:**
- Modify: `AlcoveKit/Sources/AlcoveEngine/VMConfig.swift` (`cloneOf: String?`), `VMBundle.swift` (clone, clone registry file, overlay helpers), `VMController.swift` (template guard, ephemeral start), `QEMUCommandBuilder.swift` (`Options.diskPathOverrides`, `Options.efiVarsPath`)
- Modify: `AlcoveKit/Sources/AlcoveControl/VMTarget.swift` (`VMProvisioning`, `start(discardChanges:)`), `HeadlessRegistry.swift`, `ControlHandler.swift`, `ControlHandler+State.swift`; `Alcove/Sources/Model/AppControlServer.swift` (`AppVMRegistry` conforms through `AppModel.reload()`)
- Tests: `AlcoveKit/Tests/AlcoveEngineTests/VMBundleAndLocatorTests.swift`, `VMConfigTests.swift`, `QEMUCommandBuilderTests.swift`, `VMControllerFakeEngineTests.swift`, `AlcoveKit/Tests/AlcoveControlTests/ControlStateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // VMConfig: `public var cloneOf: String?` — name of the template; absent in older configs.
  // VMBundle
  public var clonesURL: URL { url.appendingPathComponent("clones.json") }      // JSON array of clone bundle paths
  /// Bundles listed in clones.json that still exist; rewrites the file without the missing ones.
  public func liveClones(fileManager: FileManager = .default) -> [URL]
  /// New bundle whose disks are qcow2 overlays backed by this bundle's disks (absolute backing paths),
  /// with a copy of the UEFI variables, a fresh token, MAC and agent port, no static forwards, `cloneOf` set.
  public func cloneLinked(named newName: String, engine: EngineLocator.Engine, fileManager: FileManager = .default) throws -> VMBundle
  /// `qemu-img create -f qcow2 -F qcow2 -b <backing> <overlay>`
  public static func createOverlay(at overlay: URL, backing: URL, engine: EngineLocator.Engine) throws
  // VMController
  public func start(bootFromCDROM: Bool = false, discardChanges: Bool) async throws
  public private(set) var isEphemeral: Bool
  // VMTarget
  func start(discardChanges: Bool) async throws
  func isEphemeral() async -> Bool
  func cloneOf() async -> String?
  public protocol VMProvisioning: Sendable {
      func cloneVM(named name: String, as newName: String) async throws
      func deleteVM(named name: String) async throws
  }
  ```
- Rules:
  - `cloneLinked` refuses when the source is running, suspended, itself a clone, or the new name exists; errors name the condition.
  - `VMController.start` throws `engineDidNotStart("'<name>' is a template with clones (<names>); delete the clones first or start a clone")` when `liveClones()` is non-empty.
  - A throwaway session creates `run/ephemeral-<diskID>.qcow2` overlays and `run/ephemeral-efi-vars.fd`, launches with them, and removes them in `teardown()`. `suspendToDisk()` in such a session throws `engineDidNotStart("this session discards changes and cannot be suspended; stop it instead")`. A suspended bundle refuses `discardChanges`.
  - `deleteVM` refuses a VM whose `cloneOf` is nil (`'<name>' is not a clone; delete it in the Alcove app`) and a running VM; it removes the bundle directory and the entry in the template's `clones.json`.
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.clone` | `name` (template), `newName` | `{name: newName}` |
| `vm.delete` | `name` | `{}` |
| `vm.start` | adds `discardChanges?` | `{state, ephemeral}` |

  `vm.list`/`vm.status` rows gain `cloneOf` and `ephemeral` when set. A registry that is not `VMProvisioning` answers `this control host cannot clone or delete VMs`.

- [ ] **Step 1: Write failing tests.**
  - `VMConfigTests`: `cloneOf` round-trips and is absent from JSON when nil; an old config decodes with nil.
  - `VMBundleAndLocatorTests` (skip with `XCTSkipIf` when `EngineLocator` finds no `qemu-img`): `testCloneLinkedCreatesOverlay` (`qemu-img info --output=json` of the clone disk reports `backing-filename` equal to the template disk path; config has a new token, MAC and port, no forwards, `cloneOf`); `testCloneRegisteredAndPruned` (`liveClones` lists it; after removing the clone directory it is empty and the file is rewritten); `testCloneRefusals` (existing name, clone of a clone, suspended source).
  - `QEMUCommandBuilderTests`: `testDiskPathOverrides` (the `filename=` of the file node and the pflash vars path come from the options).
  - `VMControllerFakeEngineTests`: `testTemplateRefusesToStart`; `testEphemeralOverlayRemovedOnStop` (overlay files exist while running when `qemu-img` is available, and are gone after `shutdown(force: true)`); `testEphemeralRefusesSuspend`.
  - `ControlStateTests`: `testCloneAndDeleteGoThroughProvisioning` (fake registry conforming to `VMProvisioning`); `testCloneUnsupportedRegistry`; `testDeleteRefusesNonClone` (through `HeadlessRegistry` on a temp directory); `testStartDiscardChangesReportsEphemeral`.
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement.** `AppVMRegistry` clones and deletes on disk with the same `VMBundle` calls, then `await MainActor.run { AppModel.shared.reload() }`.
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures; then `cd .. && xcodegen generate >/dev/null && xcodebuild -project Alcove.xcodeproj -scheme Alcove -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"` — `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `git commit -m "Engine: linked clones and throwaway sessions; control ops to clone, delete and start discarding changes"`.

### Task 5: MCP state toolset

**Files:**
- Create: `mcp/src/tools/state.ts`, `mcp/src/leases.ts`, `mcp/src/leases.test.ts`
- Modify: `mcp/src/index.ts`, `mcp/src/tools/core.ts` (`alcove_start_vm` gains `discard_changes`; every call goes through the lease-aware caller), `scripts/test/mcp-smoke.py` (expected names)

**Interfaces:**
- Consumes: control ops of Tasks 1–4; `Registrar`, `text`, `fail` from `mcp/src/toolkit.ts`.
- Produces:
  ```ts
  // leases.ts
  /** Remembers lease tokens per VM and adds `lease` to params of calls that name that VM. */
  export class LeaseBook {
    set(vm: string, token: string): void;
    clear(vm: string): void;
    apply(params: Record<string, unknown>): Record<string, unknown>;
  }
  ```
- Tools (toolset `state`): `alcove_pause_vm`, `alcove_resume_vm`, `alcove_snapshot_list`, `alcove_snapshot_create` (`snapshot`), `alcove_snapshot_restore` (`snapshot`), `alcove_snapshot_delete` (`snapshot`), `alcove_clone_vm` (`new_name`), `alcove_delete_vm`, `alcove_lease_acquire` (`ttl_s`, `owner` default `mcp-<pid>`), `alcove_lease_release`, `alcove_port_forward_add` (`guest_port`, `host_port`), `alcove_port_forward_remove` (`host_port`), `alcove_port_forward_list`, `alcove_set_network` (`up`), `alcove_set_resolution` (`width`, `height`), `alcove_set_environment` (`theme`, `time_zone`, `clock`, `locale`, `keyboard_layouts`, `dpi_scale`), `alcove_doctor`. 17 tools; with all toolsets the server lists 46.
- `alcove_doctor` text: one line per check, `ok` or `PROBLEM`, the detail, and the hint on the next line when present. `alcove_snapshot_restore` text states whether guest tools reconnected and whether the clock was synced.
- The server releases its leases on shutdown.

- [ ] **Step 1: Write failing tests** in `leases.test.ts`: `apply` adds `lease` only for the VM that has one, leaves params without `name` untouched, and stops after `clear`.
- [ ] **Step 2: Run** `cd mcp && npm run build && npm test` — fails.
- [ ] **Step 3: Implement.** Update `mcp-smoke.py` expectations (46 with all toolsets, 16 with `core`).
- [ ] **Step 4: Run** `cd mcp && npm run build && npm test && cd .. && python3 scripts/test/mcp-smoke.py --list-only && ALCOVE_MCP_TOOLSETS=core python3 scripts/test/mcp-smoke.py --list-only` — PASS.
- [ ] **Step 5: Commit** `git commit -m "MCP: state toolset with snapshots, clones, leases, forwards, environment and doctor"`.

### Task 6: Documentation and end-to-end run

**Files:**
- Modify: `docs/control-protocol.md` (new rows, lease paragraph), `README.md` (tool list if enumerated)
- Create: `scripts/test/at2-e2e.py`, `docs/superpowers/plans/2026-10-13-at2-results.md`

- [ ] **Step 1: Write `at2-e2e.py`** using `scripts/test/alcove_ctl.py`, VM `Windows 11` running with the current agent; each check prints `PASS <n> <title>` or exits 1:
  1. `vm.doctor` → every check `ok` (print the rows).
  2. Snapshot cycle: write `C:\alcove-e2e\marker.txt` = `before`; `vm.snapshot.create snapshot=at2-e2e`; overwrite with `after`; `vm.snapshot.restore` → `tools == true`, `clockSynced == true`; `vm.fs.read` gives `before`; guest UTC from `vm.exec` is within 5 s of the host; repeat restore once more; `vm.snapshot.list` contains it; delete it; list no longer contains it. Print the seconds each restore took.
  3. Forwards: `vm.exec.start` a PowerShell `TcpListener` on guest port 18080 that answers `alcove-forward-ok` to each connection; `vm.forward.add guestPort=18080` → connect from the host to the returned port and read the text; `vm.forward.list` shows it as `runtime`; adding the same host port again → the taken-port error; `vm.forward.remove` → host connect is refused.
  4. Network: the agent connection uses the same NIC, so first `vm.exec.start` a script that sleeps 3 s, runs `Test-Connection 10.0.2.2 -Count 1 -Quiet` and writes the result to a file; then `vm.set_network up=false`; after 8 s `up=true`; wait for tools; the file holds `False`; a fresh test prints `True`.
  5. Leases: connection A acquires; connection B `vm.mouse.move` fails with the refusal text and `vm.screenshot` works; A releases; B moves.
  6. Environment: `theme=dark` then read the registry value → 0; `theme=light` → 1; `timeZone="Korea Standard Time"` then `(Get-TimeZone).Id`; restore the original zone; `clock=host`.
  7. Resolution: `vm.set_resolution 1440x900` → reported size and a screenshot of that size; back to 1280x800.
  8. Clone: stop the VM; `vm.clone newName="Windows 11 clone"`; `vm.start name="Windows 11"` fails with the template message; start the clone, wait for tools, `vm.exec hostname`; stop and `vm.delete` it; the template starts again.
  9. Throwaway session: `vm.start discardChanges=true` → write `C:\alcove-e2e\ephemeral.txt`; stop; start normally → the file does not exist.
  10. MCP: over stdio call `alcove_doctor` and `alcove_snapshot_list`.
- [ ] **Step 2: Build** `cd AlcoveKit && swift build --product alcovectl --scratch-path .build-ctl`, restart the headless control server (stop the VM first through the old server, kill `alcovectl serve`, start the VM again through `ctl.py`).
- [ ] **Step 3: Run** `python3 scripts/test/at2-e2e.py`. Fix product code for any failure through superpowers:systematic-debugging with a reproducing unit test, rerun until ten PASS lines.
- [ ] **Step 4: Write docs and the results file,** including the two measured answers this plan needed: agent connection and guest clock after `snapshot-load`, and whether DPI changes apply without signing out. Update the "Needs verification" table of the spec for those rows.
- [ ] **Step 5: Commit** `git commit -m "AT2: protocol docs and end-to-end run"`.
