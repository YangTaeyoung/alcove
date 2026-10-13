# AT7 — HTTP capture and fault injection: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A coding agent sees the HTTP and HTTPS requests an app in the guest makes (including streamed model-API responses) and can make chosen requests fail, stall or return canned answers.

**Architecture:** A host-side Go program, `alcove-proxy`, is an intercepting proxy built on the standard library: it accepts `CONNECT`, terminates TLS with leaf certificates signed by a per-user Alcove CA, forwards through `http.Transport`, streams bodies, records exchanges in memory and applies rules. `AlcoveControl` runs it as a child process speaking JSON lines (the pattern of the UI helper), installs the CA and proxy settings in the guest through recipes, and injects proxy environment variables into apps it launches while a capture is active. The guest reaches the proxy at `10.0.2.2:<port>`.

**Tech Stack:** Go 1.22 language level, standard library only (`crypto/x509`, `crypto/tls`, `net/http`, `net/http/httputil` not required); Swift 6; TypeScript MCP server; Python 3 standard library for end-to-end scripts.

**Spec:** `docs/superpowers/specs/2026-10-13-ai-testing-tools-design.md`

## Global Constraints

- The proxy lives in the existing Go module: `guest-tools/cmd/alcove-proxy` and `guest-tools/internal/mitm`; `go.mod` stays without `require` lines.
- The proxy listens on `127.0.0.1` only.
- The CA key and certificate live in `~/Library/Application Support/Alcove/proxy-ca/` (`ca.pem`, `ca.key`, mode 0600), created on first use, valid 5 years; leaf certificates are valid 7 days and cached in memory per host.
- Captured bodies are kept up to 2 MiB per direction per exchange (`bodyTruncated` beyond); at most 2000 exchanges are kept, oldest dropped.
- `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `x-api-key` and `api-key` header values are stored as `<redacted n chars>` unless the capture was started with `secrets: true`.
- Streaming responses are forwarded as they arrive (flush after every upstream read); capture never delays them.
- Hosts outside `hosts` (when given) are tunnelled without interception and recorded as `tunnel` rows with byte counts only.
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

1. A server-sent-events response: the client receives each event when the upstream sends it, not at the end, and the capture holds the whole body (Task 1 `TestStreamingIsForwardedIncrementally`).
2. A client that does not trust the CA (pinned or missing root): the proxy records a `tlsError` row for that host naming the cause, and other hosts keep working (Task 1 `TestClientRejectingCAIsRecorded`).
3. The control host dies while a capture is active: the guest is left with proxy settings pointing at a dead port — `vm.http.stop` and `vm.doctor` detect and clear stale settings (Task 2 `testStaleProxyIsReportedAndCleared`).
4. A rule with `times: 1`: exactly one request is affected under concurrency (Task 1 `TestRuleTimesIsExactUnderConcurrency`).
5. A large upload or download: memory stays bounded by the body cap and the forwarded bytes are complete (Task 1 `TestLargeBodiesAreForwardedWholeAndCappedInCapture`).

---

## Proxy contract (Tasks 1–2)

`alcove-proxy --ca-dir DIR [--listen 127.0.0.1:0]` prints `{"ev":"ready","port":n,"ca":"<path to ca.pem>"}` and then serves requests on stdin, one JSON object per line: `{"id":n,"op":"...",...}` → `{"id":n,"ok":true,...}` or `{"id":n,"ok":false,"error":"..."}`. It exits when stdin closes.

| op | params | result |
|---|---|---|
| `config` | `hosts?` ([glob], empty intercepts all), `secrets?` (bool), `bodies?` (bool, default true) | — |
| `list` | `since?` (exchange id), `host?` (substring), `path?` (substring), `status?` (number or class like `4xx`), `limit?` (default 50, cap 500) | `exchanges`: [{`id`, `time`, `kind` (`http`, `tunnel`, `tlsError`), `method`, `url`, `status`, `ms`, `reqBytes`, `resBytes`, `rule?`, `error?`}], `next` |
| `get` | `id`, `part` (`request` or `response`), `offset?`, `length?` (default and cap 200000) | `headers` ([[name, value]]), `body` (text; base64 when not UTF-8 text, with `base64: true`), `total`, `bodyTruncated`, `encoding?` (the removed content encoding) |
| `clear` | — | — |
| `rule.add` | `match` {`host?` (glob), `path?` (glob), `method?`}, `action` {`status?`, `headers?` (object), `body?` (string), `delayMs?`, `drop?` (bool: close the connection without a response), `times?`} | `rule` (id) |
| `rule.list` | — | `rules`: [{`id`, `match`, `action`, `hits`, `remaining?`}] |
| `rule.remove` | `rule` | — |
| `rule.clear` | — | — |

A rule with `status` or `body` answers without contacting the upstream (default status 200, `content-type: application/json` when the body parses as JSON, else `text/plain; charset=utf-8`). `delayMs` alone delays and then forwards. `get` decodes `gzip` and `deflate` bodies; a body with another content encoding is returned as base64 with `encoding` set.

---

### Task 1: The proxy

**Files:**
- Create: `guest-tools/internal/mitm/ca.go`, `proxy.go`, `store.go`, `rules.go`, `control.go` (JSON-lines loop), tests `ca_test.go`, `proxy_test.go`, `rules_test.go`, `control_test.go`
- Create: `guest-tools/cmd/alcove-proxy/main.go`
- Modify: `scripts/test/all.sh` (build `build/alcove-proxy` for the host), `.github/workflows/ci.yml` comment only if a step description names the binaries

**Interfaces:**
- Produces:
  ```go
  package mitm
  type CA struct{ /* ... */ }
  func LoadOrCreateCA(dir string) (*CA, error)
  func (c *CA) Leaf(host string) (*tls.Certificate, error)
  func (c *CA) PEMPath() string
  type Proxy struct{ /* ... */ }
  func NewProxy(ca *CA) *Proxy
  func (p *Proxy) Serve(l net.Listener) error
  func (p *Proxy) Handle(op string, params map[string]any) (map[string]any, error)   // the contract table
  ```
- Plain `http://` proxy requests (absolute-form) are forwarded and captured too. Inside an intercepted TLS connection the proxy serves HTTP/1.1 and HTTP/2 (ALPN `h2`, `http/1.1`) by running an `http.Server` on a one-connection listener. Upstream requests use one shared `http.Transport` with `Proxy: nil`, `ForceAttemptHTTP2: true` and response header timeout 120 s; hop-by-hop headers are removed in both directions. WebSocket upgrades are tunnelled and recorded as `kind: "tunnel"`.

- [ ] **Step 1: Write failing tests** with `httptest.NewTLSServer` upstreams and an `http.Client` that uses the proxy and trusts the test CA (the upstream's own certificate is trusted by the proxy through a `Proxy.UpstreamRoots` field used only in tests):
  - `TestCALoadOrCreateIsStable` (second load returns the same certificate; files have mode 0600); `TestLeafMatchesHostAndChainsToCA` (also for an IP address host).
  - `TestHTTPSExchangeIsCaptured` (method, URL, status, request and response body through `get`); `TestPlainHTTPIsCaptured`; `TestHTTP2ClientWorks`.
  - `TestSecretsAreRedactedByDefault` and `TestSecretsKeptWhenAsked`.
  - `TestStreamingIsForwardedIncrementally` (upstream writes three events 150 ms apart with flushes; the client reads the first before the upstream wrote the last; capture holds all three).
  - `TestLargeBodiesAreForwardedWholeAndCappedInCapture` (8 MiB each way, digests equal, `bodyTruncated`).
  - `TestGzipBodyIsDecodedForGet`; `TestBinaryBodyIsBase64`.
  - `TestHostsFilterTunnelsOthers` (a host outside `hosts` works, its certificate is the upstream's own, the row kind is `tunnel`).
  - `TestClientRejectingCAIsRecorded`.
  - `TestRuleStatusAndBody`; `TestRuleDelayThenForward`; `TestRuleDrop` (client gets a transport error); `TestRuleTimesIsExactUnderConcurrency` (20 parallel requests, `times: 1` → exactly one affected); `TestRuleMatchByHostPathMethod` (table); `TestRuleRemoveAndClear`.
  - `TestListFilters` (`since`, `host`, `path`, `status` number and class, `limit`); `TestStoreDropsOldest`.
  - `TestControlLoop` (drive `control.go` with pipes: `ready` line, a `config`, a `list`, unknown op error, exit on EOF).
- [ ] **Step 2: Run** `cd guest-tools && go test ./internal/mitm/` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd guest-tools && go vet ./... && go test ./... && go test -race ./internal/mitm/ && GOOS=windows GOARCH=arm64 go vet -unsafeptr=false ./... && GOOS=linux GOARCH=arm64 go vet ./... && go build -o ../build/alcove-proxy ./cmd/alcove-proxy`.
- [ ] **Step 5: Commit** `git commit -m "alcove-proxy: intercepting HTTP(S) proxy with capture and rules"`.

### Task 2: Control operations and guest setup

**Files:**
- Create: `AlcoveKit/Sources/AlcoveControl/ProxyProcess.swift` (child process, JSON lines), `ControlHandler+HTTP.swift`, `AlcoveKit/Tests/AlcoveControlTests/ControlHTTPTests.swift`
- Modify: `GuestRecipes.swift` (`installProxyCA`, `removeProxyCA`, `setSystemProxy`, `clearSystemProxy`, `readSystemProxy`), `ControlHandler.swift` (dispatch, `knownOps`, read-only classification), `ControlHandler+UI.swift`/`+Deploy.swift` (`vm.app.launch` and `vm.deploy` add proxy environment variables while a capture is active), `ControlHandler+Guest.swift` (`vm.doctor` check `proxy`), `AlcoveKit/Sources/AlcoveEngine/EngineLocator.swift` or a small `ToolLocator` (find `alcove-proxy`: `ALCOVE_PROXY`, next to the running executable, `<repo>/build/alcove-proxy`)

**Interfaces:**
- Produces:
  ```swift
  protocol ProxyControlling: Sendable {
      func start() async throws -> (port: Int, caPath: String)
      func call(_ op: String, _ params: [String: JSON]) async throws -> JSON
      func stop() async
  }
  final class ProxyProcess: ProxyControlling   // one per VM capture
  ```
  `ControlHandler.init` gains `makeProxy: @Sendable () -> ProxyControlling` (default builds `ProxyProcess`) for tests.
- Control ops:

| `op` | Params | Result |
|---|---|---|
| `vm.http.start` | `name`, `hosts?`, `secrets?`, `bodies?`, `systemProxy?` (default true) | `{proxy: "10.0.2.2:<port>", env: {HTTP_PROXY, HTTPS_PROXY, ALL_PROXY, NO_PROXY, NODE_EXTRA_CA_CERTS, SSL_CERT_FILE, REQUESTS_CA_BUNDLE}, caInstalled, systemProxySet, guestCAPath}` |
| `vm.http.stop` | `name` | `{exchanges}` — clears guest proxy settings set by start, removes the CA from the guest, stops the proxy |
| `vm.http.requests` | `name`, filters of `list` | `{exchanges, next}` |
| `vm.http.request` | `name`, `id`, `part`, `offset?`, `length?` | result of `get` |
| `vm.http.clear` | `name` | `{}` |
| `vm.http.rule.add` / `.list` / `.remove` / `.clear` | `name`, fields of the proxy contract | results of the proxy contract |

- Guest setup on Windows: push `ca.pem` to `C:\ProgramData\Alcove\proxy-ca.pem`; `Import-Certificate` into `Cert:\LocalMachine\Root`; with `systemProxy`, set the per-user WinINET proxy (`ProxyEnable`, `ProxyServer`, `ProxyOverride` = `<local>` under `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`, followed by the `InternetSetOption` refresh calls) and `netsh winhttp set proxy`; remember the previous values in `C:\ProgramData\Alcove\proxy-previous.json` and restore them on stop. Linux: copy the CA to `/usr/local/share/ca-certificates/alcove-proxy.crt` and run `update-ca-certificates`; no system proxy (environment variables only).
- `vm.http.*` without `alcove-proxy` on the host → `alcove-proxy was not found; build it with scripts/test/all.sh or set ALCOVE_PROXY`. A second `vm.http.start` on a capturing VM → `'<vm>' is already capturing on port <n>; call vm.http.stop first`.
- `vm.doctor` check `proxy`: ok when no system proxy is set, or it points at this VM's live capture; otherwise not ok with the hint `vm.http.stop clears stale proxy settings`. `vm.http.stop` on a VM without a capture clears stale settings when `proxy-previous.json` exists.
- A VM that stops ends its capture (proxy process stopped).

- [ ] **Step 1: Write failing tests** with a fake `ProxyControlling` and the fake agent: `testStartInstallsCAAndSetsProxy` (order: start proxy, `config`, push CA, CA recipe, proxy recipe; result fields); `testStartWithoutSystemProxy`; `testStartTwiceRefused`; `testStopRestoresAndStops`; `testRequestsAndRequestPassThrough`; `testRuleOpsPassThrough`; `testLaunchGetsProxyEnvWhileCapturing` (and not after stop; caller-supplied `env` keys win); `testMissingProxyBinary`; `testStaleProxyIsReportedAndCleared`; `testCaptureEndsWhenVMStops`; `ProxyProcess` against a tiny stand-in script (`/bin/sh` printing the ready line and echoing ids): `testProxyProcessReadyAndCall`, `testProxyProcessExitFailsPendingCalls`.
- [ ] **Step 2: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -5` — fails.
- [ ] **Step 3: Implement,** trying the Windows recipes once in the running VM through `python3 scripts/test/ctl.py vm.exec ...` and restoring the settings afterwards.
- [ ] **Step 4: Run** `cd AlcoveKit && swift build --build-tests 2>&1 | tail -3 && swift test --skip-build 2>&1 | grep -E "Executed|error:|failed" | tail -8` — 0 failures.
- [ ] **Step 5: Commit** `git commit -m "Control: HTTP capture with guest CA and proxy setup, rules"`.

### Task 3: MCP `http` toolset

**Files:**
- Create: `mcp/src/tools/http.ts`
- Modify: `mcp/src/index.ts`, `scripts/test/mcp-smoke.py`

**Interfaces:**
- Tools (toolset `http`): `alcove_http_capture_start` (`hosts`, `secrets`, `bodies`, `system_proxy`), `alcove_http_capture_stop`, `alcove_http_requests` (list filters; or `id` with `part`, `offset`, `length` to read one exchange), `alcove_http_rule` (`action`: `add`, `list`, `remove`, `clear`; `match`, `response` (`status`, `headers`, `body`, `delay_ms`, `drop`, `times`), `rule`). All toolsets together list 75 tools.
- `alcove_http_requests` list text: one line per exchange `#id time METHOD url -> status (ms, req/res bytes) [rule n]`; detail text: headers, a blank line, the body clipped at 60000 characters with an `offset`/`length` hint.
- `alcove_http_capture_start` text states the proxy address, whether the CA and system proxy were set, and that apps started with `alcove_launch_app` or `alcove_deploy` receive the proxy environment automatically.

- [ ] **Step 1: Implement** and update `mcp-smoke.py` expectations.
- [ ] **Step 2: Run** `cd mcp && npm run build && npm test && cd .. && python3 scripts/test/mcp-smoke.py --list-only && ALCOVE_MCP_TOOLSETS=core python3 scripts/test/mcp-smoke.py --list-only` — PASS.
- [ ] **Step 3: Commit** `git commit -m "MCP: http toolset"`.

### Task 4: Documentation and end-to-end run

**Files:**
- Modify: `docs/control-protocol.md`, `README.md`, spec "Needs verification" row for the proxy CA
- Create: `scripts/test/at7-e2e.py`, `docs/superpowers/plans/2026-10-13-at7-results.md`

- [ ] **Step 1: Write `at7-e2e.py`** (VM `Windows 11`, fixture deployed); each check prints `PASS <n> <title>` or exits 1:
  1. `vm.http.start` → `caInstalled` and `systemProxySet` true; `vm.doctor` check `proxy` ok.
  2. Fixture: `vm.deploy` launch with `args: ["--url", "https://example.com/"]`, `vm.ui.click` on `Fetch`, `vm.wait_for` `ui_text_stable` on the transcript → transcript line `Fetch: 200`; `vm.http.requests host="example.com"` has one `http` exchange with status 200; `vm.http.request part=response` body contains `Example Domain`.
  3. PowerShell stack: `vm.exec` `(Invoke-WebRequest -UseBasicParsing https://example.com/).StatusCode` → 200 and a second exchange appears (system proxy path, CA trusted by WinHTTP/.NET).
  4. Fault: `vm.http.rule.add match={host:"example.com"} action={status:429, body:"{\"error\":\"rate_limited\"}", times:1}`; click `Fetch` → transcript line `Fetch: 429`; the exchange row carries the rule id; a further `Fetch` → 200.
  5. Stall: rule `delayMs: 3000`; `Fetch` takes ≥ 3 s by the exchange `ms`; `vm.http.rule.clear`.
  6. Streaming: start a host-side Python server on `127.0.0.1:<port>` that sends five server-sent events 400 ms apart (the guest reaches it as `http://10.0.2.2:<port>/sse`); in the guest run `curl.exe -N -x http://10.0.2.2:<proxy port> http://10.0.2.2:<port>/sse` as a job; `vm.exec.read` polled every 200 ms sees the first event at least 1 s before the last; the captured response body holds all five.
  7. `vm.http.stop` → guest proxy settings equal the values from before the capture (compare the registry values read before step 1), the CA is gone from `Cert:\LocalMachine\Root`, and `Invoke-WebRequest https://example.com/` still returns 200 directly.
  8. MCP: over stdio `alcove_http_capture_start`, `alcove_http_requests`, `alcove_http_capture_stop`.
- [ ] **Step 2: Build everything (`scripts/test/all.sh` lines after the QEMU build), restart the control server.**
- [ ] **Step 3: Run** `python3 scripts/test/at7-e2e.py`; fix through superpowers:systematic-debugging with reproducing unit tests; rerun until every line is PASS or a justified SKIP.
- [ ] **Step 4: Write docs and the results file;** update the spec row with which HTTP stacks honoured the proxy and CA.
- [ ] **Step 5: Commit** `git commit -m "AT7: protocol docs and end-to-end run"`.
