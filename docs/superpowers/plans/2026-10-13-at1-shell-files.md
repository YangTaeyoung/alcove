# AT1 — agent RPC, shell, processes, files: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A coding agent can run long commands, background jobs and file transfers in a guest without blocking screenshots or input, and can move whole directories in both directions.

**Architecture:** The guest agent gains a request/response layer (`req`/`res` with numeric ids, one goroutine per request) next to the v1 messages. `AgentClient` gains `call(op, params)`. `ControlHandler` gains shell, process and file ops; `ControlServer` runs those ops outside the per-connection serial chain. The MCP server exposes them as tools grouped into toolsets.

**Tech Stack:** Go 1.22 language level, no external modules (`guest-tools/`). Swift 6 language mode, macOS 15 (`AlcoveKit/`). TypeScript, `@modelcontextprotocol/sdk` ^1.30, zod (`mcp/`). Python 3 standard library for end-to-end scripts.

**Spec:** `docs/superpowers/specs/2026-10-13-ai-testing-tools-design.md`

## Global Constraints

- `guest-tools/go.mod` stays without `require` lines.
- v1 agent messages (`docs/agent-protocol.md` table) keep their exact behaviour; `hello` keeps `"v":1`.
- One agent message is at most 1 MiB (`proto.MaxLine`); binary payloads travel as base64 in pieces of at most 256 KiB decoded.
- Everything as powerful as a shell (exec, jobs, processes, `fs.*`) answers `exec disabled; start alcove-agent with --allow-exec` unless `Options.AllowExec` is set.
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

1. A command whose output is not valid UTF-8 or contains Korean text: stdout and stderr arrive as valid JSON strings with the Korean text intact (Task 2 test `TestExecRunUTF8`, Task 7 check 2).
2. A command that outlives its timeout and has child processes: the whole tree is gone and the reply says `timed_out` (Task 2 `TestExecRunTimeoutKillsTree`, Task 7 check 3).
3. A job that prints more than the retained buffer: `exec.read` reports `dropped` and offsets keep increasing (Task 2 `TestJobBufferDropsOldest`).
4. A file path with spaces, Korean characters, `~` or a missing parent directory: push, pull and sync handle it (Task 3 `TestFsPathForms`, Task 7 check 6).
5. The host disconnecting during a transfer or a job: the agent keeps serving new connections, jobs stay listed, partial files do not replace the destination (Task 3 `TestWriteToPartThenRename`, Task 4 `testDisconnectFailsPendingCalls`).

---

## Wire contract (shared by Tasks 1–5)

`hello` gains `"proto":2`. Capabilities gain `"rpc"`, and with `--allow-exec` also `"jobs"`, `"proc"`, `"fs"`.

Request `{"t":"req","id":<int>,"op":"<op>", ...params}` → reply `{"t":"res","id":<int>,"ok":true, ...result}` or `{"t":"res","id":<int>,"ok":false,"error":"<sentence>"}`. Unknown op → `unknown op '<op>'; update alcove-agent`. Event `{"t":"ev","name":"<name>", ...fields}`.

| op | params | result |
|---|---|---|
| `exec.run` | `cmd` (string) or `argv` ([string]); `shell` (`powershell` default on Windows, `cmd`, `sh` default elsewhere, `none` requires `argv`); `cwd`; `env` (object); `stdin` (string); `timeout_ms` (default 120000) | `code`, `stdout`, `stderr`, `timed_out`, `truncated` |
| `exec.start` | same as `exec.run` without `timeout_ms` | `job` (string), `pid` |
| `exec.read` | `job`; `out_offset`, `err_offset` (default 0); `max` (bytes per stream, default and cap 262144) | `state` (`running`/`exited`), `code` (when exited), `pid`, `out`, `err`, `out_next`, `err_next`, `dropped` |
| `exec.write` | `job`, `data` (string), `eof` (bool) | — |
| `exec.kill` | `job` | `state` |
| `exec.list` | — | `jobs`: [{`job`, `pid`, `state`, `code`, `cmd`, `started` (RFC 3339)}] |
| `proc.list` | `name` (case-insensitive substring) | `procs`: [{`pid`, `ppid`, `name`, `path`, `cmd`, `mem_kb`}] |
| `proc.kill` | `pid` or `name`; `tree` (bool) | `killed` (int) |
| `fs.stat` | `path`; `sha256` (bool) | `exists`, `dir`, `size`, `mtime` (RFC 3339), `sha256`, `path` (absolute) |
| `fs.list` | `path`; `recursive` (bool); `sha256` (bool) | `entries`: [{`name` (relative, `/` separators), `dir`, `size`, `mtime`, `sha256`}], `truncated` (more than 5000 entries) |
| `fs.read` | `path`, `offset`, `length` (≤ 262144) | `data` (base64), `size`, `eof` |
| `fs.tail` | `path`, `lines` (default 200) | `data` (base64 of the last lines, read from at most the last 262144 bytes), `size` |
| `fs.write` | `path`, `data` (base64), `offset` (default 0), `truncate` (bool), `append` (bool), `mkdirs` (bool) | `size` |
| `fs.rename` | `from`, `to`, `overwrite` (bool) | `path` |
| `fs.mkdir` | `path` | `path` |
| `fs.delete` | `path`, `recursive` (bool) | `deleted` (bool) |

Rules:

- Output streams of `exec.run` keep the last 200000 bytes each; `truncated` is true when bytes were dropped. Invalid UTF-8 is replaced with U+FFFD.
- A job keeps the last 1 MiB per stream. Offsets count bytes since the job started; reading below the retained window sets `dropped` and returns from the oldest retained byte. The server keeps 64 jobs and forgets the oldest exited job first. Jobs belong to the server, not to a connection. A job exit emits `{"t":"ev","name":"job.exited","job":..,"code":..}` on every open connection.
- On Windows every child process starts without a console window, and PowerShell commands run as `[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; <cmd>` through `powershell.exe -NoProfile -NonInteractive -Command`.
- A timeout or kill removes the process tree: Windows `taskkill /F /T /PID <pid>`; elsewhere the child runs in its own process group and the group receives SIGKILL.
- Paths: `~` and `~/x` resolve against `Options.HomeDir`; a relative path resolves against `Options.HomeDir`; results report absolute paths.

---

### Task 1: Agent RPC dispatcher

**Files:**
- Modify: `guest-tools/internal/proto/proto.go` (helpers), `guest-tools/internal/proto/proto_test.go`
- Create: `guest-tools/internal/server/rpc.go`, `guest-tools/internal/server/rpc_test.go`
- Modify: `guest-tools/internal/server/server.go` (hello, caps, dispatch `req`, event fan-out, `AgentVersion = "0.2.0"`)

**Interfaces:**
- Produces (package `proto`): `const RPCVersion = 2`; `func (m Message) Bool(key string) bool`; `func (m Message) Has(key string) bool`; `func (m Message) Strings(key string) []string` (JSON array of strings, else nil); `func (m Message) StringMap(key string) map[string]string`.
- Produces (package `server`):
  ```go
  // Handler serves one request; the returned message carries result fields only.
  type Handler func(req proto.Message) (proto.Message, error)

  // register adds an op; gated ops need Options.AllowExec.
  func (s *Server) register(op string, gated bool, h Handler)

  // emit sends an event to every open connection.
  func (s *Server) emit(name string, fields proto.Message)
  ```
  `Server` gains `ops map[string]opEntry`, `conns map[*conn]struct{}` guarded by a mutex. `New` calls `s.registerBuiltins()`; Tasks 2 and 3 add their registrations there through `s.registerShell()` and `s.registerFiles()`, which Task 1 defines as empty methods in `rpc.go`.
- Built-in op registered by this task: `ping` (ungated) → `{"pong": true}`.

- [ ] **Step 1: Write failing tests** in `rpc_test.go` using the existing `startServer` and `expect` helpers from `server_test.go`:
  - `TestHelloAnnouncesRPC`: `hello` has `v == 1`, `proto == 2`, caps contain `rpc`; with `AllowExec` also `jobs`, `proc`, `fs`; without it none of the three.
  - `TestReqResRoundTrip`: `{"t":"req","id":7,"op":"ping"}` → `res` with `id == 7`, `ok == true`, `pong == true`.
  - `TestUnknownOp`: `ok == false`, error contains `unknown op 'nope'`.
  - `TestGatedOpWithoutAllowExec`: register a gated test op through `New(...)` then `s.register("t.gated", true, ...)`; reply error is exactly `exec disabled; start alcove-agent with --allow-exec`.
  - `TestRequestsRunConcurrently`: register `t.slow` (blocks on a channel) and `t.fast`; send slow then fast; the fast `res` arrives first; then release slow and its `res` arrives.
  - `TestHandlerPanicBecomesError`: a handler that panics yields `ok == false` and the connection keeps answering `ping`.
  - `TestEmitReachesAllConnections`: two connections both receive `{"t":"ev","name":"x","n":1}` after `s.emit("x", proto.Message{"n": 1})`.
  - `TestV1MessagesStillWork`: `clipboard.get` → `clipboard.text` on the same connection after a `req`.
  - `proto_test.go`: `TestMessageAccessors` for `Bool`, `Has`, `Strings`, `StringMap`.

  For tests that need the `*Server`, add a helper `startServerS(t, opt) (*Server, *proto.Reader, *proto.Writer, net.Conn)` in `rpc_test.go`.

- [ ] **Step 2: Run** `cd guest-tools && go test ./...` — the new tests fail to compile or fail.

- [ ] **Step 3: Implement.** In `handle`, a message with `t == "req"` is dispatched in a new goroutine: look up the op, check the gate, run the handler under `recover`, send `res` with `id` copied from the request (`m["id"]` passed through unchanged) and the handler's fields merged in. `hello` gains `"proto": proto.RPCVersion`. `caps()` appends `rpc`, and `jobs`, `proc`, `fs` when `AllowExec`. The connection registers itself in `s.conns` for `emit` and removes itself on close.

- [ ] **Step 4: Run** `cd guest-tools && go vet ./... && go test ./... && GOOS=windows GOARCH=arm64 go vet -unsafeptr=false ./... && GOOS=linux GOARCH=arm64 go vet ./...` — all pass.

- [ ] **Step 5: Commit** `git add guest-tools && git commit -m "Agent: request/response layer with concurrent dispatch"` (with the trailer lines).

### Task 2: Agent shell, jobs and processes

**Files:**
- Create: `guest-tools/internal/server/shell.go` (command building, `exec.run`, registration), `jobs.go` (job table, ring buffers, `exec.start/read/write/kill/list`), `procs.go` (`proc.list`, `proc.kill` op handlers), `sys_windows.go` and `sys_unix.go` (`//go:build !windows`) for `hideWindow(*exec.Cmd)`, `prepareTree(*exec.Cmd)`, `killTree(pid int) error`, `listProcesses() ([]procInfo, error)`, `killByName(name string, tree bool) (int, error)`.
- Create tests: `shell_test.go`, `jobs_test.go`, `procs_test.go`
- Modify: `guest-tools/internal/server/rpc.go` (`registerShell` body), `server.go` (v1 `exec` uses the same command builder and hidden window)

**Interfaces:**
- Consumes: `register`, `emit`, `Handler`, `proto.Message` accessors from Task 1.
- Produces: the `exec.*` and `proc.*` rows of the wire contract. Internal:
  ```go
  type procInfo struct { PID, PPID int; Name, Path, Cmd string; MemKB int }
  // buildCommand turns request fields into a command for the current OS.
  func buildCommand(req proto.Message, goos string) (*exec.Cmd, error)
  // ring keeps the newest max bytes and the count of bytes written overall.
  type ring struct{ /* ... */ }
  func newRing(max int) *ring
  func (r *ring) Write(p []byte) (int, error)
  func (r *ring) ReadFrom(offset, max int) (data []byte, next int, dropped bool)
  ```
- Windows process listing runs `powershell.exe -NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,WorkingSetSize | ConvertTo-Json -Compress"` with the UTF-8 prefix and parses the JSON (a single object when one process matches). Unix runs `ps axo pid=,ppid=,rss=,args=` and derives `Name` from the base name of the first argument.

- [ ] **Step 1: Write failing tests** (they run on the macOS host with `sh`; use `runtime.GOOS` only to skip nothing):
  - `TestBuildCommandForms` (table, `goos` passed explicitly): Windows default → `powershell.exe` with `-Command` and the UTF-8 prefix; `shell: "cmd"` → `cmd.exe /C <cmd>`; `shell: "none"` with `argv` → argv unchanged; `shell: "none"` without `argv` → error `shell 'none' needs argv`; Linux default → `/bin/sh -c`; `cwd` and `env` land in `Cmd.Dir` and appended `Cmd.Env`; neither `cmd` nor `argv` → error `missing cmd or argv`.
  - `TestExecRunSeparatesStreams`: `echo out; echo err 1>&2; exit 3` → `stdout == "out\n"`, `stderr == "err\n"`, `code == 3`, `timed_out == false`.
  - `TestExecRunStdinCwdEnv`: `cat; pwd; echo $FOO` with `stdin`, `cwd` (a temp dir), `env`.
  - `TestExecRunUTF8`: `printf '한글\377'` → stdout starts with `한글` and is valid UTF-8 (`utf8.ValidString`).
  - `TestExecRunTimeoutKillsTree`: `sleep 30 & echo $!; wait` with `timeout_ms: 300` → `timed_out == true` within 3 s and the printed child pid no longer exists (`syscall.Kill(pid, 0)` fails).
  - `TestExecRunTruncatesToTail`: `head -c 300000 /dev/zero | tr '\0' 'a'; echo END` → `truncated == true`, stdout ends with `END\n`, length ≤ 200000.
  - `TestRingOffsets`: write 10 bytes into a ring of 4 → `ReadFrom(0, 10)` returns the last 4, `next == 10`, `dropped == true`; `ReadFrom(8, 10)` returns 2, `dropped == false`; `ReadFrom(10, 10)` returns empty with `next == 10`.
  - `TestJobLifecycle`: start `for i in 1 2 3; do echo $i; sleep 0.1; done`; poll `exec.read` with advancing `out_offset` until `state == "exited"`; concatenated output is `1\n2\n3\n`; `code == 0`; `exec.list` contains the job with `state == "exited"`; a `job.exited` event arrived.
  - `TestJobStdinAndKill`: start `cat`; `exec.write` `hi\n`; read shows `hi\n`; `exec.kill` → `state == "exited"`; unknown job → error `no job '<id>'; call exec.list`.
  - `TestJobBufferDropsOldest`: with the job ring size overridden to 1024 through a package variable `jobBufferBytes`, a job printing 5000 bytes read from offset 0 reports `dropped == true` and `out_next == 5000`.
  - `TestJobTableForgetsOldestExited`: with `maxJobs` overridden to 3, starting five short jobs leaves 3 listed and the oldest are gone.
  - `TestProcListAndKill`: start `sleep 30` as a job; `proc.list` with `name: "sleep"` contains its pid with `ppid`, `name == "sleep"`; `proc.kill` with that pid → `killed == 1`; the job reaches `exited`.
  - `TestV1ExecStillWorks`: v1 `exec` → `exec.result` with code and combined output.

- [ ] **Step 2: Run** `cd guest-tools && go test ./internal/server/` — new tests fail.
- [ ] **Step 3: Implement** to the contract and rules above.
- [ ] **Step 4: Run** the same four commands as Task 1 Step 4 — all pass.
- [ ] **Step 5: Commit** `git commit -m "Agent: exec with separate streams, background jobs, process list and kill"`.

### Task 3: Agent file operations

**Files:**
- Create: `guest-tools/internal/server/files.go`, `files_test.go`
- Modify: `guest-tools/internal/server/rpc.go` (`registerFiles` body)

**Interfaces:**
- Consumes: `register`, accessors from Task 1.
- Produces: the `fs.*` rows of the wire contract. Internal: `func (s *Server) resolvePath(p string) (string, error)` (empty path → error `missing path`).

- [ ] **Step 1: Write failing tests** (temp dir as `HomeDir`):
  - `TestFsPathForms`: `~`, `~/a b/한글.txt`, a relative path and an absolute path all resolve as specified; `fs.write` with `mkdirs: true` creates missing parents; without it the error names `mkdirs`.
  - `TestFsWriteReadRoundTrip`: write 600000 random bytes in three `fs.write` calls at offsets 0, 262144, 524288 (first with `truncate: true`); read back in `fs.read` pieces; bytes match; last piece has `eof == true`; `fs.read` with `length` above 262144 returns at most 262144.
  - `TestFsAppend`: two `append: true` writes concatenate.
  - `TestFsStat`: missing file → `exists == false` with no error; file → `size`, `mtime`, `sha256` equal to an independently computed digest; directory → `dir == true`.
  - `TestFsListRecursive`: nested tree → relative names with `/`, directories flagged, digests present only when asked; a tree of 5001 files → `truncated == true` and 5000 entries (create empty files).
  - `TestFsTail`: a file with 1000 lines → `lines: 5` returns the last five lines exactly; a file without a trailing newline keeps its last partial line.
  - `TestWriteToPartThenRename`: write `x.part`, `fs.rename` to `x` with `overwrite: false` when `x` exists → error contains `exists`; with `overwrite: true` → content replaced and `x.part` gone.
  - `TestFsDelete`: non-empty directory without `recursive` → error names `recursive`; with it → `deleted == true`; missing path → `deleted == false`.
  - `TestFsGated`: without `AllowExec`, `fs.stat` → the gate error.

- [ ] **Step 2: Run** `cd guest-tools && go test ./internal/server/` — new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the four commands of Task 1 Step 4 — all pass. Also build both agents: `GOOS=windows GOARCH=arm64 go build -ldflags "-H windowsgui" -o ../build/alcove-agent-windows-arm64.exe ./cmd/alcove-agent && GOOS=linux GOARCH=arm64 go build -o ../build/alcove-agent-linux-arm64 ./cmd/alcove-agent`.
- [ ] **Step 5: Commit** `git commit -m "Agent: file stat, list, read, tail, write, rename, delete"`.

### Task 4: AgentClient RPC and file transfer helpers

**Files:**
- Modify: `AlcoveKit/Sources/AlcoveAgent/AgentClient.swift`
- Create: `AlcoveKit/Sources/AlcoveAgent/AgentFiles.swift`
- Modify: `AlcoveKit/Tests/AlcoveAgentTests/AgentClientTests.swift`; create `AlcoveKit/Tests/AlcoveAgentTests/AgentFilesTests.swift`

**Interfaces:**
- Consumes: the wire contract.
- Produces:
  ```swift
  extension AgentClient.AgentError { case unsupported(String) }   // add the case to the enum
  public struct Hello { /* existing */ public let rpcVersion: Int }   // 1 when `proto` is absent
  public enum Event { /* existing */ case agent(name: String, payload: JSON) }

  /// Send `{"t":"req","id":n,"op":op, ...params}` and return the `res` object.
  /// Throws `.remote(error)` on `ok:false`, `.unsupported(op)` when the agent has no RPC layer.
  public func call(_ op: String, _ params: [String: JSON] = [:], timeout: Duration = .seconds(30)) async throws -> JSON

  // AgentFiles.swift
  public struct TransferResult: Sendable, Equatable { public let guestPath: String; public let bytes: Int; public let sha256: String }
  public struct SyncResult: Sendable, Equatable { public let sent: [String]; public let skipped: Int; public let deleted: [String]; public let bytes: Int }
  public func pushFile(_ url: URL, toGuestPath path: String, overwrite: Bool, timeout: Duration = .seconds(1800)) async throws -> TransferResult
  public func pullFile(guestPath: String, to url: URL, timeout: Duration = .seconds(1800)) async throws -> TransferResult
  public func syncDirectory(_ directory: URL, toGuestPath path: String, deleteExtras: Bool, timeout: Duration = .seconds(3600)) async throws -> SyncResult
  ```
- Behaviour: `connect` accepts `v == 1`; `rpcVersion = h["proto"]?.intValue ?? 1`. `pushFile(toGuestPath:)` refuses when the destination exists and `overwrite` is false (error `'<path>' exists in the guest; pass overwrite`), writes `<path>.alcove-part` in 256 KiB pieces with `mkdirs`, compares `fs.stat` `sha256` with the local digest, renames over the destination, deletes the part file on mismatch (error `digest mismatch after upload`). `pullFile` reads in 256 KiB pieces into `<url>.alcove-part`, compares the digest from `fs.stat`, renames. `syncDirectory` lists the guest directory recursively with digests (missing directory counts as empty), sends files whose size or digest differ, skips symbolic links, and with `deleteExtras` removes guest files that have no local counterpart. Relative names use `/`; the guest path is joined with `/` unless the guest path contains `\`, in which case `\` is used.

- [ ] **Step 1: Write failing tests.** Extend `FakeAgent` with an in-memory file system handler (`[String: Data]`) answering `fs.stat`, `fs.list`, `fs.read`, `fs.write`, `fs.rename`, `fs.delete`, and make its `hello` configurable (`proto` present or absent).
  - `testCallRoundTrip`: `call("ping")` → `pong == true`; the request carried a numeric `id` and `t == "req"`.
  - `testCallsAreMatchedByID`: two concurrent calls whose replies arrive in reverse order each get their own reply.
  - `testCallRemoteError`: `ok:false` → `.remote("boom")`.
  - `testCallUnsupportedOnV1Agent`: hello without `proto` → `.unsupported("ping")`, nothing sent.
  - `testCallTimeout`: no reply → `.timeout("ping")`, and a late reply is ignored.
  - `testDisconnectFailsPendingCalls`: `drop()` during a call → `.disconnected`.
  - `testAgentEvent`: `{"t":"ev","name":"job.exited","job":"j1","code":0}` → `.agent(name: "job.exited", payload:)` on `events`.
  - `testPushFileToGuestPath`: 700000 random bytes arrive intact at the destination; the part file is gone; a second push with `overwrite: false` throws; with `true` replaces.
  - `testPushDigestMismatch`: fake corrupts one byte → throws and no destination file.
  - `testPullFile`: guest file of 700000 bytes lands at the URL with matching digest.
  - `testSyncDirectory`: local tree with `a.txt`, `sub/b.bin`, `한글 파일.txt`; guest has `a.txt` identical, `sub/b.bin` different, `old.txt` extra → `sent == ["sub/b.bin", "한글 파일.txt"]` (sorted), `skipped == 1`, `deleted == ["old.txt"]` with `deleteExtras`, `[]` without.
  - `testSyncUsesBackslashForWindowsPaths`: guest path `C:\\e2e\\in` → writes go to `C:\\e2e\\in\\sub\\b.bin.alcove-part`.

- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails to compile.
- [ ] **Step 3: Implement.** Pending calls live in `[Int: CheckedContinuation<JSON, Error>]` keyed by a counter; `handleEnd` fails them; `handle(line:)` routes `res` by `id` and `ev` to `events`.
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build --filter AlcoveAgentTests 2>&1 | tail -15` — all pass, then `swift test --skip-build 2>&1 | grep -E "Executed|error|failed" | tail -5`.
- [ ] **Step 5: Commit** `git commit -m "AgentClient: request/response calls and file transfer helpers"`.

### Task 5: Control operations and concurrent lane

**Files:**
- Modify: `AlcoveKit/Sources/AlcoveControl/ControlServer.swift` (lanes), `ControlHandler.swift` (dispatch to the new files, `vm.exec`, `vm.push_file`)
- Create: `AlcoveKit/Sources/AlcoveControl/ControlHandler+Shell.swift`, `ControlHandler+Files.swift`, `InputGate.swift`, `GuestText.swift`
- Create tests: `AlcoveKit/Tests/AlcoveControlTests/ControlShellFilesTests.swift`, extend `ControlServerTests.swift`; move `FakeAgent` from `AgentClientTests.swift` into a shared test support target `AlcoveKit/Tests/AlcoveTestSupport/FakeAgent.swift` (add `.target(name: "AlcoveTestSupport", dependencies: ["AlcoveQMP"], path: "Tests/AlcoveTestSupport")` to `Package.swift` and make both test targets depend on it; `FakeAgent` becomes `public`).

**Interfaces:**
- Consumes: `AgentClient.call`, `pushFile(_:toGuestPath:overwrite:)`, `pullFile`, `syncDirectory`, `Hello.rpcVersion` from Task 4.
- Produces (control protocol, camelCase params as in `docs/control-protocol.md`):

| `op` | Params | Result |
|---|---|---|
| `vm.exec` | `name`, `command` or `argv`, `timeout?` s, `cwd?`, `env?`, `stdin?`, `shell?` | `{code, output, stdout, stderr, timedOut, truncated}`; `output` is `stdout` followed by `stderr`; an agent without RPC gets the v1 `exec` and returns `code`, `output` |
| `vm.exec.start` | `name`, `command` or `argv`, `cwd?`, `env?`, `shell?` | `{job, pid}` |
| `vm.exec.read` | `name`, `job`, `outOffset?`, `errOffset?`, `max?` | `{state, code?, pid, out, err, outNext, errNext, dropped}` |
| `vm.exec.write` | `name`, `job`, `data`, `eof?` | `{}` |
| `vm.exec.kill` | `name`, `job` | `{state}` |
| `vm.exec.list` | `name` | `{jobs: [...]}` |
| `vm.process.list` | `name`, `filter?` | `{processes: [{pid, ppid, name, path, command, memoryKB}]}` |
| `vm.process.kill` | `name`, `pid?` or `processName?`, `tree?` | `{killed}` |
| `vm.push_file` | `name`, `path`, `dest?` or `guestPath?`, `overwrite?` | `{guestPath, bytes?, sha256?}`; `guestPath` selects the RPC transfer |
| `vm.pull_file` | `name`, `guestPath`, `path` (host) | `{path, bytes, sha256}` |
| `vm.sync_dir` | `name`, `path` (host dir), `guestPath`, `delete?` | `{sent: [..], skipped, deleted: [..], bytes}` |
| `vm.fs.list` | `name`, `path`, `recursive?` | `{entries: [{name, dir, size, mtime}], truncated}` |
| `vm.fs.read` | `name`, `path`, `offset?`, `length?` (≤ 262144), `tail?` (lines) | `{text, size, eof}` |
| `vm.fs.write` | `name`, `path`, `text`, `append?` | `{size}` |
| `vm.fs.delete` | `name`, `path`, `recursive?` | `{deleted}` |

- `GuestText.decode(_ data: Data) -> String`: UTF-16LE when the data starts with `FF FE`, UTF-8 with a BOM stripped, otherwise lossy UTF-8.
- Lanes: `static func ControlHandler.isConcurrent(op: String) -> Bool` is true for ops with prefix `vm.exec`, `vm.process.`, `vm.fs.` and for `vm.push_file`, `vm.pull_file`, `vm.sync_dir`. `ControlServer` starts concurrent ops in their own task and keeps chaining the others per connection; all tasks of a connection are cancelled when it closes.
- `InputGate`: `actor InputGate { func withLock<T: Sendable>(_ vm: String, _ body: @Sendable () async throws -> T) async rethrows -> T }` — a FIFO async mutex per VM name. `ControlHandler` runs `vm.mouse.*`, `vm.key.*` and `vm.type` under it.
- Errors: an agent without RPC → `guest tools in '<vm>' are too old for <op>; update alcove-agent in the guest`; `AgentError.remote(m)` → `m` unchanged.

- [ ] **Step 1: Write failing tests.**
  - `ControlShellFilesTests` (a `FakeTarget` whose `agent(timeout:)` returns an `AgentClient` connected to `FakeAgent`): `testExecMapsParamsAndResult` (the fake records `exec.run` params: `cmd`, `cwd`, `env`, `stdin`, `shell`, `timeout_ms == timeout * 1000`; result has `stdout`, `stderr`, `output == stdout + stderr`, `timedOut`); `testExecFallsBackToV1`; `testExecStartReadWriteKillList` (param and result name mapping); `testProcessListMapsNames`; `testProcessKillNeedsPidOrName` (error names both parameters); `testPushFileWithGuestPath`; `testPullFile`; `testSyncDir`; `testFsReadTextAndTail` (UTF-16LE data with BOM decodes; `tail` uses `fs.tail`); `testFsWriteAppend`; `testOldAgentErrorNamesTheUpdate`.
  - `GuestText` tests: BOM forms and invalid UTF-8.
  - `InputGate` test `testInputGateIsFIFO`: three bodies on one VM run in order without overlap; a different VM is not blocked.
  - `ControlServerTests.testConcurrentOpDoesNotBlockSerialLane`: with a handler whose `vm.exec` waits (fake agent delays the reply 1 s), a `vm.status` sent after it on the same connection is answered first. `testSerialLaneKeepsOrder`: two serial ops answer in send order.

- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures. Then `swift build --product alcovectl --scratch-path .build-ctl 2>&1 | tail -2`.
- [ ] **Step 5: Commit** `git commit -m "Control: shell, process and file operations on a concurrent lane"`.

### Task 6: MCP tools and toolsets

**Files:**
- Create: `mcp/src/toolkit.ts` (result helpers, toolset selection, `Registrar`), `mcp/src/tools/core.ts` (the 16 existing tools moved unchanged except `alcove_exec` and `alcove_push_file`), `mcp/src/tools/shell.ts`, `mcp/src/tools/files.ts`, `mcp/src/toolkit.test.ts`
- Modify: `mcp/src/index.ts` (wiring, `instructions`, version `0.2.0`), `mcp/package.json` (version `0.2.0`), `scripts/test/mcp-smoke.py` (expected tool list)

**Interfaces:**
- Consumes: control ops of Task 5.
- Produces:
  ```ts
  // toolkit.ts
  export const TOOLSETS = ["core", "shell", "files", "state", "ui", "evidence", "replay", "http"] as const;
  export type Toolset = (typeof TOOLSETS)[number];
  /** Parses ALCOVE_MCP_TOOLSETS; unset or empty selects all; unknown names throw with the valid list. */
  export function selectedToolsets(env: string | undefined): Set<Toolset>;
  export function text(t: string, structured?: Record<string, unknown>): ToolResult;
  export function fail(e: unknown): ToolResult;
  /** Truncates to `max` characters and appends a line naming the paging parameter. */
  export function clip(s: string, max?: number, hint?: string): string;
  export interface Registrar { tool(set: Toolset, name: string, config: ToolConfig, handler: ToolHandler): void }
  export function registrar(server: McpServer, enabled: Set<Toolset>): Registrar;
  // tools/*.ts
  export function register(r: Registrar, client: ControlClient): void;
  ```
- Tools (toolset): `alcove_exec` extended with `cwd`, `env`, `stdin`, `shell`, `argv` (core); `alcove_exec_start`, `alcove_exec_read` (`out_offset`, `err_offset`, `max`), `alcove_exec_write`, `alcove_exec_kill`, `alcove_exec_list`, `alcove_process_list` (`filter`), `alcove_process_kill` (`pid`, `process_name`, `tree`) (shell); `alcove_push_file` extended with `guest_path`, `overwrite` (core); `alcove_pull_file` (`guest_path`, `path`), `alcove_sync_dir` (`path`, `guest_path`, `delete`), `alcove_fs_list`, `alcove_fs_read` (`offset`, `length`, `tail`), `alcove_fs_write` (`text`, `append`), `alcove_fs_delete` (files).
- `alcove_exec` text result: `exit code N` (plus ` (timed out)`), then `stdout:` and `stderr:` sections that are omitted when empty, each clipped at 60000 characters. `alcove_exec_read` text: state line, next offsets, then the two sections.
- Server `instructions`: a short paragraph stating that text tools are cheaper than screenshots, that long commands belong in `alcove_exec_start`, and that build output moves with `alcove_sync_dir`.

- [ ] **Step 1: Write failing tests** in `toolkit.test.ts` (`node:test`, `node:assert/strict`): `selectedToolsets(undefined)` is all eight; `"core, files"` → those two; `"bogus"` throws naming the valid sets; `clip` keeps short strings and appends the hint line when cutting; a `registrar` with only `core` enabled registers a `core` tool and skips a `shell` tool (use a stub object with a `registerTool` recorder).
- [ ] **Step 2: Run** `cd mcp && npm run build && npm test` — fails.
- [ ] **Step 3: Implement.** Update `scripts/test/mcp-smoke.py` so `--list-only` expects the 30 tool names and also passes with `ALCOVE_MCP_TOOLSETS=core` expecting 16.
- [ ] **Step 4: Run** `cd mcp && npm run build && npm test && cd .. && python3 scripts/test/mcp-smoke.py --list-only && ALCOVE_MCP_TOOLSETS=core python3 scripts/test/mcp-smoke.py --list-only` — PASS three times.
- [ ] **Step 5: Commit** `git commit -m "MCP: shell, process and file tools; selectable toolsets"`.

### Task 7: Documentation, deployment into the Windows VM, end-to-end run

**Files:**
- Modify: `docs/agent-protocol.md` (RPC section with the wire contract table and rules), `docs/control-protocol.md` (new rows, lanes paragraph replacing "handled sequentially"), `README.md` tool list if it enumerates tools, `scripts/test/all.sh` (add `npm test`)
- Create: `scripts/test/alcove_ctl.py` (importable control-socket client with concurrent ids: `Client.call(op, **params)`, `Client.send(op, **params) -> id`, `Client.wait(id, timeout)`), `scripts/test/install-agent.py` (boots the VM, copies `build/alcove-agent-windows-arm64.exe` in and runs `--install --allow-exec`, using the SSH route of `agent-windows.py`; verifies `agentCaps` contains `rpc`), `scripts/test/at1-e2e.py`
- Create: `docs/superpowers/plans/2026-10-13-at1-results.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write `at1-e2e.py`** against VM `Windows 11`, each check prints `PASS <n> <title>` or exits 1 with `FAIL`:
  1. `vm.status` reports `tools == true` and `agentCaps` ⊇ {`rpc`, `jobs`, `proc`, `fs`}.
  2. `vm.exec` `Write-Output '한글 ok'; [Console]::Error.WriteLine('to-err'); exit 5` → `stdout` contains `한글 ok`, `stderr` contains `to-err`, `code == 5`.
  3. `vm.exec` with `cwd: "C:\\Windows"`, `env: {"ALCOVE_E2E": "yes"}`, command `(Get-Location).Path; $env:ALCOVE_E2E` → both lines. Then `vm.exec` `ping -n 60 127.0.0.1` with `timeout: 3` → `timedOut == true` within 15 s and `vm.process.list filter=PING` is empty.
  4. No visible console: `vm.exec` of a PowerShell snippet that `Add-Type`s `GetConsoleWindow`/`IsWindowVisible` from `kernel32`/`user32` and prints the result → `False`.
  5. Concurrency: send `vm.exec` `Start-Sleep 8`, then `vm.screenshot` and a second `vm.exec` `hostname`; both answer within 4 s; the sleep answers after ≥ 7 s.
  6. Files: build a host temp tree (`a.txt`, `sub dir/b.bin` of 3 MiB random, `한글 파일.txt`), `vm.sync_dir` to `C:\\alcove-e2e\\in` → three sent; `vm.pull_file` each to another temp dir and compare SHA-256; change `a.txt`, sync again → `sent == ["a.txt"]`, `skipped == 2`; `vm.fs.list`, `vm.fs.write` + `vm.fs.read` with `tail`, `vm.fs.delete recursive` → gone.
  7. Jobs: `vm.exec.start` `1..6 | % { $_; Start-Sleep -Milliseconds 500 }`; `vm.exec.read` polled with offsets yields `1`..`6` once each; `state == exited`, `code == 0`. Start `ping -t 127.0.0.1`, `vm.exec.kill` → `exited`, and no `PING` process remains.
  8. MCP: start `node mcp/dist/index.js`, call `alcove_exec` and `alcove_fs_list` over stdio (reuse the JSON-RPC helper in `mcp-smoke.py`), expect non-error results.
- [ ] **Step 2: Build and deploy.** `scripts/test/all.sh` minus the QEMU build if `build/qemu-build` exists (run the remaining lines), then `python3 scripts/test/install-agent.py`.
- [ ] **Step 3: Run** `python3 scripts/test/at1-e2e.py` — eight PASS lines. Fix product code for any failure through superpowers:systematic-debugging, add a unit test that reproduces it, rerun.
- [ ] **Step 4: Write docs and the results file** (what ran, commands, outputs, anything that differed from the plan).
- [ ] **Step 5: Commit** `git commit -m "AT1: protocol docs, agent deployment script, end-to-end run"`.
