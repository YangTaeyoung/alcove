# Final e2e results: the AI testing tools program on the guest (2026-10-14)

The runs below were executed on an Apple M5 Pro (18 cores, 64 GiB RAM, macOS
27.0.1, Swift 6.4, Go 1.25.0, Node 26.10, Python 3, QEMU 11.1.1 with
`qemu-patches/0001` to `0003`, engine in `build/qemu-build`, not rebuilt)
against the VM `Windows 11` (Windows 11 Pro ARM64 25H2, build 26200, user
`alcove`, 4 vCPUs, 6 GiB, 1280x800, agent host port 17532) through
`alcovectl serve` (debug build of this tree in `AlcoveKit/.build-ctl`), with
`build/alcove-agent-windows-arm64.exe`, `build/alcove-fixture-windows-arm64.exe`
and `build/alcove-proxy` built from this tree. The data volume had 383 GiB to
394 GiB free. Base: 7d2e9e1; the fixes of this pass are c88ffdd..f0490bd.

A standard user `alcovetest` (member of Users only, medium integrity) was
created for the security checks, reached over the guest's ssh with the test
key, and deleted with its profile at the end.

## What ran

| Step | Command | Result |
|---|---|---|
| Builds | `go build` of the agent (Windows, Linux), the fixture and `alcove-proxy`; `swift build --product alcovectl --scratch-path .build-ctl` | ok |
| Old agent refused | `vm.start` of `Windows 11` under the new server (SMBIOS `alcove-hostkey`), guest still on the agent without auth | `vm.status` `tools: false` with `toolsRefused`: `the guest tools do not ask the host for the VM's key, so the host does not use them; reinstall the guest tools from this version of Alcove (scripts/test/install-agent.py)`; `vm.doctor` row `tools` not ok with that sentence and hint |
| Install | `scripts/test/install-agent.py` | PASS (hello `auth: "key"`, `authenticated with the agentKey of 'Windows 11'`), first with 7d2e9e1, then with the fixed agent (twice) |
| `agent-rpc-windows.py` | | 17 of 17, twice on the fixed agent |
| `uia-helper-check.py` | | 29 of 29, twice on the fixed agent |
| `at1-e2e.py` | | 9 of 9, twice; SIGTERM run below |
| `at2-e2e.py` | | 10 of 10 (188 s) |
| `at3-e2e.py` | | 7 of 7 (36 s) |
| `at4-e2e.py` | | 16 of 16, 0 skipped (105 s) |
| `at5-e2e.py` | | first run FAIL 3 (stale expectation, fixed in 9b64f89), then 11 of 11 (298 s) |
| `at6-e2e.py` | | first run FAIL 9 (racy check, fixed in cb0a8f1), then `--only 9` PASS and the full script 13 of 13, 0 skipped (246 s) |
| `at7-e2e.py` | | first run FAIL 2 (fixture closed the body unread, fixed in 25f58a2), then 8 of 8; after the control fix f0490bd 8 of 8 twice more |
| `mcp-smoke.py --vm "Windows 11"` | | `PASS: MCP end to end` (27 s; start, screenshot, exec, press, type, clipboard, right click, stop) |
| SIGTERM | `at1-e2e.py`, SIGTERM 9 s in (after PASS 4) | `interrupted; cleaning up...`, exit 143, no `C:\alcove-e2e`, no PING process, no host temp folder |
| Go tests on the guest | `GOOS=windows go test -c` of every package, run in the guest as `alcove` | `cmd/alcove-agent` 17 pass 1 skip (the ProgramData and exclusive-bind tests ran on Windows for the first time), clipboard, proto, token pass; `internal/server` 19 and `internal/uia` 2 failures, all in tests written for a Unix host (see Not verified) |
| Unit suites after the last code change | see the last section | |

## Security checks (W1r3 G1–G12, rereview-w1, rereview-w1r3)

| Check | Result | Evidence |
|---|---|---|
| G1 agent start line names the host key | PASS | `alcove-agent 0.2.0 listening on [::]:7645 for 10.0.2.2/32 (token 4ca3...409a, host key abf5...952e, exec true)`; `alcovectl agent-sign --public-key` prints `abf51980…4b952e` |
| Standard user → `127.0.0.1:7645` and `10.0.2.15:7645` | PASS | first line `refused`: `alcove-agent serves only connections from 10.0.2.2/32 and this one comes from 127.0.0.1; …`, then EOF |
| G5 standard user → `10.0.2.2:17532` (the guest-local bypass) | PASS | hello with `auth: "key"` and a nonce; `req exec.run` (a `cmd /c echo > C:\Users\Public\…`) answered `res ok:false` with `this alcove-agent serves only a host that proves the VM's key; …` then `refused`; v1 `exec` answered `exec.result code -1`; the file was not created |
| `pair` refused | PASS | `pair` → `refused` with the unauthenticated sentence |
| Wrong signature | PASS | all-zero signature → the signature-mismatch sentence |
| G10 64 KiB line | PASS | 70000 bytes without newline → `a line before auth is longer than 65536 bytes; …`; a 65535-byte line is read (the next `pair` gets the unauthenticated sentence) |
| G10 16 handshakes (7d2e9e1) | PASS as designed, then changed | 16 held → 17th refused `16 connections are authenticating; …`; reworked per rereview-w1r3 N1 (below) |
| N1 handshake cap no longer locks the host out (fixed agent) | PASS | 16 held → the 17th gets a hello and the oldest gets `this connection was closed for a newer one because 16 connections were authenticating; …`; a standard-user loop that kept 16 idle handshakes open for 60 s (112 connections) did not keep the host out: after an agent restart during the loop the host was served 1 s after the bind |
| G7 exclusive bind | PASS | while the agent listens (Go dual-stack `[::]:7645`), a standard user's bind of `127.0.0.1`, `10.0.2.15`, `0.0.0.0` and `[::]` port 7645, each with and without `SO_REUSEADDR`, fails with `AccessDenied` |
| G8 listen retry | PASS | a standard user held `0.0.0.0:7645` during an agent restart: `listen on 0.0.0.0:7645 failed (…); trying again in 1 s`, 2, 4, 8, 16, 30 s (7d2e9e1), and 1, 2, 4, 5, 5 s with the fixed agent (N5); the agent bound right after the port was released |
| G9 refusal log rate | PASS | 40 refused connections from 127.0.0.2 … 127.0.0.21 within a second → one line; the next line a minute later ends `(39 more refused for this reason since the last line)`; each other reason (timeout, unauthenticated, signature, long line, busy) one line |
| G6 `HKCU\Environment` `ProgramData` override, relogon | PASS | `ProgramData=C:\Users\alcove\pd` in the agent's environment after a reboot; the agent still logs and locks `C:\ProgramData\Alcove`; the UI helper started from `C:\ProgramData\Alcove\uia` (`compiled helper.cs`); nothing under `pd\Alcove` |
| G6 `SystemDrive` override, relogon | FAIL at 7d2e9e1 → fixed (c88ffdd) → PASS | see Defects D1 |
| icacls `C:\ProgramData\Alcove`, `…\uia` | PASS | `BUILTIN\Administrators:(OI)(CI)(F)`, `NT AUTHORITY\SYSTEM:(OI)(CI)(F)`, no `(I)` entry |
| icacls `C:\alcove-apps` | PASS | the two above plus `BUILTIN\Users:(OI)(CI)(RX)`, no `(I)` entry; the folder did not exist before the first start of the new agent, which created it |
| Second agent start keeps the deploy root | PASS | several restarts; no `was moved to` line for a root the agent had locked |
| G11 old `host.key` | n/a | no `host.key` in `C:\ProgramData\Alcove` before or after |
| G4 clones (two linked clones, relay) | PASS | `alcovectl args`: template `token 4ca36ba4… hostkey abf51980…`, C1 `69bd8808… 3aec1dc2…`, C2 `22b17820… 202adfba…`; in C1 a standard-user process (`Start-Process -Credential`) read C2's hello through `10.0.2.2:17807` (token `22b17820…`); on C2's port a signature made by `agent-sign --vm C1` (what the host signs for C1) and one by `--vm "Windows 11"` were refused with the signature-mismatch sentence, `--vm C2` got `authed`; both clones deleted |
| G3 VM without `alcove-hostkey` | not run on the guest | the no-key `refused` is unit-tested; the host-side display of a refusal (`toolsRefused`, doctor row) was seen with the old agent |
| Helper module path | PASS (weak) | a `Microsoft.PowerShell.Management` module planted in `Documents\WindowsPowerShell\Modules` was not loaded by the helper; a normal PowerShell 5.1 session of the user did not load it either (it loads that module from `System32`), so this plant does not tell the allowlist from a denylist |

## Guest checks owed by the fix groups

| Check | Result | Evidence |
|---|---|---|
| Proxy death restores the guest (FW4 I1) | PASS | `kill -9` of `alcove-proxy` during a `systemProxy` capture: WinINET `ProxyEnable 0`, WinHTTP `Direct access`, CA gone, state file gone 1.5 s later; doctor `proxy` row ok (`no system proxy`); `vm.http.requests` answers `the HTTP capture of 'Windows 11' ended because alcove-proxy was ended by signal 9; call vm.http.start to capture again`; `vm.http.stop` then answers ok with `warning: the HTTP capture of 'Windows 11' had already ended because …` (W2 #3); a new `vm.http.start` works |
| Interrupted `vm.http.stop` still restores (core N1) | PASS | the stop's connection closed 0.3 s in; guest restored 0.3 s later, no proxy process |
| Interrupted `vm.http.start` is undone (W2 #1) | FAIL at 7d2e9e1 → fixed (f0490bd) → PASS | see Defects D7; after the fix, 14 interruptions from 0.05 s to 0.5 s left proxy, guest proxy, CA and capture consistent (all undone) |
| `vm.http.stop` during a 60 s `delayMs` POST (FW2) | PASS | stop answered in 0.66 s (no 3 s SIGTERM fallback); curl in the guest ended with `(56) server closed abruptly` |
| WebSocket through a capture (proxy I3) | PASS | .NET `ClientWebSocket` in the guest to a host echo server via the system proxy: open, send, echo, close; one row `kind tunnel, method GET, status 101, reqBytes 48, resBytes 35, url http://10.0.2.2:51706/chat` |
| CA files | PASS | `proxy-ca/ca.key`, `ca.pem`, `captures.json` are 0600, the folder 0700; the CA from an earlier build loaded |
| Pull onto a host folder (core C1) | PASS | refused with `… is a folder on the host; pass the path of the file to create, such as …/win.ini`; the folder and its file kept; a pull over an existing file replaced it (92 bytes); a relative path refused (`path must be an absolute path on the host, …`) |
| Cancelled key press / batch / type (core I1, W2 #7) | PASS | read with `GetAsyncKeyState` in the agent's session: `vm.key.press shift+a hold 5000` — during `A,SHIFT`, 1.5 s after the connection closed nothing down; a batch holding `ctrl` and the left button — during `CTRL,LBUTTON`, after the close nothing; `vm.type` of 400 characters — nothing after the close; a `script.run` whose `vm.key.down shift` step was followed by a wait, cancelled by closing its connection — nothing down after (the lease blocks `vm.exec` during the run, so its held state was not read) |
| Interrupted push leaves no `.alcove-part` (core N2) | PASS | 300 MiB push: `alcove-big.bin.alcove-part` of 203948032 bytes 2 s in; 3 s after the close nothing; closes at 0.5, 1.5 and 3 s left nothing |
| Dump folder (FW4 I3) | PASS | `vm.crash_dumps.enable` exit ok (the `icacls /L` lines ran); `C:\alcove-dumps` owner Administrators, `BUILTIN\Users:(RX,WD)`, `Users:(OI)(CI)(IO)(M)`, SYSTEM and Administrators F; the standard user cannot rename it (`Access … denied`); a fail-fast crash of a standard-user program wrote `alcove-crasher.exe.6580.dmp` (720806 bytes), listed by `vm.crash_dumps.list` |
| `vm.deploy` recreates a deleted `C:\alcove-apps` locked (W1 #6) | PASS | root deleted as administrator → deploy ok, root with the locked ACL, the app folder inherits it |
| User-made root refused and moved aside (FW1 #3, FW4 I2) | PASS | root created by `alcovetest` (inherited `Authenticated Users:(M)`): deploy refused `'C:\alcove-apps' in the guest belongs to S-1-5-21-…-1003, not to Administrators or SYSTEM, …`; agent restart → `moved to C:\alcove-apps.untrusted-20261014142217` and a locked root |
| Junction root refused and moved aside | PASS | junction `C:\alcove-apps` → a user folder: deploy refused `'C:\alcove-apps' is a link in the guest; …`; nothing written into the target; agent restart moved the junction aside |
| Paused VM status (core M1) | PASS | `vm.status` of a paused VM answered at once (`state paused`) |
| Client that stops reading (core I2) | PASS | a client that sent 40 `vm.screenshot` requests and was SIGSTOPped: another client's `vm.status` answered in 0.03 s; the stopped client's socket was closed by the server within 40 s |
| Snapshot create during a restore (FW6) | PASS (order inferred) | `vm.snapshot.create e2e-conc2` sent 0.5 s after `vm.snapshot.restore e2e-conc`: both ok; the create answered 11.2 s and the restore 11.7 s after the restore was sent (the restore waits for the tools after its load); the new snapshot's date is about 3 s after the restore began; both snapshots deleted |
| Graceful stop during a snapshot load (FW6) | PASS | `vm.stop` 1 s into a restore: the restore answered `snapshot restore failed: the VM is not running; check vm.status`, the stop `stopped` after 5.9 s; no Kernel-Power 41 event at the next boot |
| Refuse to start on leftovers (FW8) | PASS | with `C:\alcove-e2e` present `at3-e2e.py` printed `FAIL 0: the guest already holds the folder C:\alcove-e2e; remove it and run this script again` and left it |
| MCP over stdio (rest R7) | PASS (part) | `alcove_list_vms` and `alcove_vm_status` sent back to back as the first calls both answered; `alcove_exec_read` of a job that wrote 600000 bytes: 11 reads, every one of 20000 lines seen, offsets continued; the rest of R7 is in Not verified |
| FW1 #6/#7, rest #1 (launch names, default cwd, argv) | PASS through the scripts | at4 launches `msedge.exe`, `charmap.exe`, `mmc.exe`, `notepad.exe`; at7 runs `curl.exe` by argv; every script uses `vm.exec` without `cwd` |
| FW5 at5/at6 items | PASS through the scripts | recordings into fresh paths, the copied trace, script save and run-script (at5 11/11, at6 13/13) |

## Defects found

| # | Defect | Cause | Fix | Test |
|---|---|---|---|---|
| D1 | A `SystemDrive` set in the user's `HKCU\Environment` moved the agent's data folder: with `SystemDrive=C:\Users\alcove\sd` and that folder's `ProgramData` present, the agent locked `C:\Users\alcove\sd\ProgramData\Alcove` and ran the elevated UI helper from its `uia` folder, under a parent the unelevated user controls; without the folder, the agent ran with no log and no helper (`the UI helper cannot start because the ProgramData folder could not be located`) | `SHGetKnownFolderPath(FOLDERID_ProgramData)` expands the ProfileList value `%SystemDrive%\ProgramData` with the calling process's environment (seen: `[Environment]::GetFolderPath("CommonApplicationData")` in a child process with that variable answers the override) | c88ffdd: read the raw `ProgramData` value of `HKLM\…\ProfileList` and expand only `%SystemDrive%`, `%SystemRoot%`, `%windir%` from `GetSystemWindowsDirectoryW`; any other variable is refused | `TestTheProgramDataFolderIsNotOnTheSystemDriveOfTheEnvironment` (child process with `SystemDrive` set; failed on the guest before the fix with the temp folder's `ProgramData`), the ProgramData test moved to a child process, two portable expansion tests; on the guest the fixed agent kept `C:\ProgramData\Alcove` with the override active |
| D2 (rereview-w1r3 N1) | 16 idle pre-auth connections kept the host out | the 17th connection was refused while a slot stayed taken for 30 s | bd51e5b: a new handshake closes the oldest pending one (`refused` with a sentence), 10 s from hello to auth | `TestAHostThatSignsAtOnceIsAuthedWhile16IdleHandshakesAreOpen`, `TestAServedConnectionIsNotClosedForANewerHandshake`; guest flood above |
| D3 (N2) | a read failure before auth was logged once per connection | logged outside the refusal log | bd51e5b: through the refusal log under `read error` | `TestReadErrorsBeforeAuthAreLoggedOncePerMinute` (20 resets gave 20 lines before) |
| D4 (N3) | the SMBIOS parser lost its place after a structure without strings | skipped one zero byte of the `\0\0` pair | 4ea80e9 | `TestAStructureWithoutStringsBeforeTheOEMStructureIsSkipped` |
| D5 (N4) | install-agent.py reported the no-key `refused` as `no hello`; a malformed `agentKey` started the VM without `alcove-hostkey` and the agent's sentence named the wrong fix | | b095d1d: the scripts print the agent's sentence; e15a02c: `vm.start` refuses such a VM with `the agentKey in <path>/config.json is not 64 hexadecimal digits, …` | `testStartIsRefusedWhenTheAgentKeyIsNot64HexadecimalDigits`; `read_hello` returned a fake refusal line |
| D6 (N5, N6) | listen retry up to 30 s; a test name about pairing | | d6e50c1 (5 s); bd51e5b (rename) | listen test; guest retry lines 1, 2, 4, 5, 5 s |
| D7 | an interrupted `vm.http.start` left the guest's system proxy pointing at the stopped capture's port, with the CA removed, no journal entry and no capture; the doctor flagged it and only a `vm.http.stop` cleared it | the agent call of the cancelled start ended at once while its PowerShell recipe kept running in the guest; the undo ran first and the recipe then set the proxy | f0490bd: the guest steps of `vm.http.start` run in an unstructured task to their end, then a cancellation is checked and the undo runs | `testTheUndoOfACancelledStartWaitsForTheRecipeThatWasRunning` (failed before: `clearProxy` was sent while `setProxy` was still held); guest matrix above |
| D8 | `app.launch` of a bare name expanded the `%VAR%` of the machine `Path` and of `HKLM\…\App Paths` with the agent's environment, which carries the user's `HKCU\Environment` | `ExpandEnvironmentStringsW` on the REG_EXPAND_SZ values in the agent process | dbc18c1: the new package `internal/sysfolder` expands only `%SystemDrive%`, `%SystemRoot%`, `%windir%` from `GetSystemWindowsDirectoryW` and the Program Files variables from their `…Dir` values under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion`; anything else is skipped | `TestABareNameResolvesInTheSystemFolderWhateverTheEnvironmentSays` (on the guest, 2a3506d with only this test resolved `notepad` to `…\Temp\TestABareNameResolves…\001\system32\notepad.exe`; passes at dbc18c1), `TestAnAppPathsProgramResolvesToAnExistingFile`, the four `internal/sysfolder` tests; over the wire the HKCU route did not reach a launch (see the section below) |
| T1 | at5 check 3 expected the image key without `AlcoveCreated` | the protocol (`vm.crash_dumps.enable`) marks an image key it creates | 9b64f89 (script) | at5 11/11 |
| T2 | at6 check 9 read the fixture log right after run-script exited | `vm.ui.click` answers once the input is sent; the send line, and the reply's `done` 2.4 s later, arrived after the read and the `done` fell into the SIGINT run | cb0a8f1 (script waits up to 10 s for both) | at6 13/13 |
| T3 | at7 check 2 found an empty captured body | the fixture closed the response body unread; the proxy's write to the guest failed before it captured the chunk it had read | 25f58a2 (fixture reads the body) | at7 8/8 three times |

## Not verified, and why

- The Alcove app: not launched (no person to drive it). App-only items: the
  `Tools refused` label and popover, app quit with an active recording (with and
  without a running VM), rename/delete with an orphan engine, `vm.http.start`
  with the app as host using `Contents/MacOS/alcove-proxy`, a rename of a VM
  with a capture journal entry.
- Linux guest (agent-linux.py, `/sys/firmware/dmi/tables/DMI`): no Linux VM.
- G3 on the guest: starting a VM without `alcove-hostkey` needs an engine
  command line this build no longer produces (the malformed-key path now refuses
  to start).
- `scripts/build-qemu.sh` re-patch of 0003: the engine was not rebuilt, as
  instructed.
- MCP R7 rest: `alcove_start_vm` resume with `wait_timeout_s`,
  `alcove_script_run` without `name` while holding a lease, a script saved from a
  recording with `vm.http.*` steps (unit-tested only); whether the two parallel
  first calls shared one control connection was not observed.
- Signals other than SIGTERM on at1 (SIGHUP, SIGINT, `nohup`) and on the other
  early scripts.
- `vm.snapshot.delete` during a restore; a full-resolution screenshot above
  1280x800.
- The Go tests of `internal/server` (19) and `internal/uia` (2) fail when run on
  Windows: they use `/bin/sh` commands and Unix file semantics (removing an open
  file's folder, a second appending handle across a start-over). They pass on
  the macOS host, where they are meant to run.

## Concerns

- One-way authentication remains (accepted earlier): a program that holds 7645
  while the agent is down gets the host's requests. The exclusive bind and the
  5 s retry narrow the gap; on Windows the port stays taken for a short time
  after the agent ends (a standard user's bind failed with `AccessDenied` right
  after an `/End`).
- The handshake cap still yields to a program that opens connections faster
  than one host round trip (documented in agent-protocol.md).
- A malformed JSON line before auth is skipped silently; the connection then
  waits for the 10 s deadline.
- A capture whose client closes right after the headers records `resBytes 0`
  and no body, even when the proxy had read the body from upstream (seen with
  the fixture before T3).
- Notepad keeps a tab state file written during the scripts' Notepad steps
  (at3 and at4 save and restore Notepad's state; mcp-smoke types into a new
  Notepad window).

## Unit suites on the final tree

After the last code change (f0490bd):

| Suite | Command | Result |
|---|---|---|
| Swift build | `cd AlcoveKit && swift build --build-tests`, and once into a fresh scratch path | no warning |
| Swift tests | `ALCOVE_QEMU_DIR=$PWD/../build/qemu-build swift test --skip-build` | 1307 tests, 0 failures, 2 skipped (the two case-insensitive-volume tests): QMP 32, Engine 118, DisplayProtocol 42, Control 1052, Agent 63 |
| Go | `cd guest-tools && go vet ./... && GOOS=windows go vet ./... && GOOS=linux go vet ./... && go test ./...` | clean, every package ok |
| MCP | `cd mcp && npm run build && npm test` | 192 of 192 |
| Python | `python3 -m py_compile scripts/test/*.py` | clean (`__pycache__` removed) |

End state: `Windows 11` stopped through `vm.stop`; one `alcovectl serve` from
this tree's build on the default socket; no `alcove-proxy`; no snapshot, clone,
capture, journal entry, `C:\alcove-e2e`, `C:\alcove-dumps` or `LocalDumps` key;
`HKCU\Environment` without the test overrides; the user `alcovetest` and its
profile deleted. The guest keeps the new agent and the locked folders
`C:\ProgramData\Alcove` and `C:\alcove-apps` (empty).

## After the last review (2026-10-15)

Same host, VM and `alcovectl serve` (built from 2a3506d; the host side did
not change). Under test: dbc18c1 (app.launch resolution, D8), 9b998fa
(handshake auth deadline before the queue) and 7f5b2e3 (UI answer of an
agent without a ProgramData folder). The agent reports `0.2.0` before and
after; the builds are told apart by `go version -m` (`vcs.revision`).

| Check | Result | Evidence |
|---|---|---|
| Agent in the guest before | b095d1d build | `C:\Program Files\Alcove\alcove-agent.exe` SHA-256 `a04ff91b…e3b934`, equal to `build/alcove-agent-windows-arm64.exe` with `vcs.revision=b095d1d`; b095d1d..2a3506d changes only `cmd/alcove-fixture` in `guest-tools` |
| Old agent, `HKCU\Environment` `SystemRoot=C:\Users\alcove\sr` (REG_EXPAND_SZ), `sr\System32\notepad.exe` = the fixture, task `AlcoveAgent` ended and run | override reaches the task's environment; the agent does not serve | a probe task with the same settings (`/RL HIGHEST /IT`, run in the session) wrote `SystemRoot=C:\Users\alcove\sr`, `windir=C:\WINDOWS`, `SystemDrive=C:`; agent.log every 5 s: `listen on 0.0.0.0:7645 failed (listen tcp 0.0.0.0:7645: socket: The requested service provider could not be loaded or initialized.); trying again in 5 s`; `vm.status` `tools: false`, so no `vm.app.launch` could be sent |
| Old agent, `HKCU\Environment` `ProgramFiles=C:\Users\alcove\pf`, `pf\Windows Mail\wab.exe` = the fixture (App Paths `wab.exe` is `%ProgramFiles%\Windows Mail\wab.exe`) | override does not reach the agent | `vm.exec` `set ProgramFiles` in the restarted agent: `C:\Program Files`; `vm.app.launch path=wab waitWindow=0` → `process.exited` path `C:\Program Files\Windows Mail\wab.exe` (the real one; Contacts window closed) |
| Install of the new agent (7f5b2e3) | PASS | `install-agent.py`: SHA-256 `6ce7e182…15bc264`, `vcs.revision=7f5b2e3`, hello `auth: "key"`, authenticated |
| New agent, same `SystemRoot` override, task restarted | same as the old agent | the same `listen … failed (… service provider could not be loaded or initialized.)` lines; `tools: false` |
| New agent, `vm.app.launch path=notepad waitWindow=0` | PASS | `process.exited` path `C:\WINDOWS\system32\notepad.exe`, its child `…\WindowsApps\Microsoft.WindowsNotepad_11.2607.14.0_arm64__8wekyb3d8bbwe\Notepad\Notepad.exe`; window closed |
| New agent, `vm.app.launch path=msedge waitWindow=0` (App Paths, Edge already running) | PASS | `process.exited` path `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`, window `New tab - Profile 1 - Microsoft Edge` opened and closed |
| Revert | PASS | `SystemRoot` and `ProgramFiles` values deleted from `HKCU\Environment` (left: `Path`, `TEMP`, `TMP`, `OneDrive`), `C:\Users\alcove\sr`, `pf` and the probe task deleted, task restarted; `vm.exec` `set SystemRoot` → `C:\WINDOWS` |
| Go tests on the guest, `internal/sysfolder` | PASS | 4 of 4 |
| Go tests on the guest, `internal/server` (`-test.run` the bare name, App Paths, replaced handshake, 16 idle handshakes, served connection tests) | PASS | 5 of 5 |
| Go tests on the guest, `cmd/alcove-agent` | PASS | 15 pass, 1 skip (`TestInstallLogIsNotWrittenThroughALink`: symbolic links need a privilege); the two expansion tests now run in `internal/sysfolder` |
| `TestABareNameResolvesInTheSystemFolderWhateverTheEnvironmentSays` on 2a3506d (the test file alone, `sysfolder.WindowsFolder` replaced by an inline `GetSystemWindowsDirectoryW`) | FAILS as expected | `notepad resolves to "C:\Users\alcove\AppData\Local\Temp\TestABareNameResolvesInTheSystemFolderWhateverTheEnvironmentSays978700886\001\system32\notepad.exe", <nil>; expected "C:\WINDOWS\System32\notepad.exe"` |
| `agent-rpc-windows.py` | PASS | 17 of 17 |
| `at4-e2e.py` | PASS | 16 of 16, 0 skipped (104 s) |
| `mcp-smoke.py --vm "Windows 11"` | PASS | `PASS: MCP end to end` (27 s) |

Concern: a `SystemRoot` in the user's `HKCU\Environment` keeps the agent from
listening after its next start (the agent log names the Winsock error, not
the variable); the same value made PowerShell over ssh fail
(`Loading managed Windows PowerShell failed with error 8009001d`) and
`MoNotificationUx.exe` and `OneDriveLauncher.exe` crash in the session. It
was cleared from an elevated PowerShell opened through the guest display.

End state: `Windows 11` stopped through `vm.stop` (`mcp-smoke.py` had stopped
it); the `alcovectl serve` from 2a3506d still running; no `alcove-proxy`; no
temporary worktree; the guest keeps the agent built from 7f5b2e3.
