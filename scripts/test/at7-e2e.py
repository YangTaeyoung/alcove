#!/usr/bin/env python3
"""End-to-end run of HTTP capture against a running Windows VM: vm.http.start
with the CA and the system proxy, the fixture's Fetch button (a Go client that
uses the proxy environment of vm.deploy), PowerShell through the system proxy,
a canned 429, a delayed answer, a server-sent-events stream forwarded as it
arrives, vm.http.stop putting the guest's proxy settings back, and the http
tools of the MCP server (docs/control-protocol.md "HTTP capture", mcp/).

Needs the VM running with the agent installed as the scheduled task
AlcoveAgent with --allow-exec (scripts/test/install-agent.py), a control
server that finds build/alcove-proxy, `npm run build` in mcp/, the fixture
build build/alcove-fixture-windows-arm64.exe (scripts/test/all.sh) and
internet access to example.com from the Mac. The guest must hold no
C:\\alcove-apps\\alcove-at7-app, run no fixture, show no window of the
fixture, have no capture running and no proxy-previous.json left by one; the
script refuses to start otherwise.

Each check prints `PASS <n> <title>`; the first failing check prints
`FAIL <n>: <reason>` and the script exits 1. A run without a failure ends with
`<p> passed`.

Before check 1 the script reads the guest's proxy settings: the WinINET
values ProxyEnable, ProxyServer, ProxyOverride and AutoConfigURL of the user,
the WinHTTP proxy (WinHttpSettings) and the thumbprints in
Cert:\\LocalMachine\\Root. Check 7 and the cleanup compare the guest with that
reading; WinINET stores ProxyEnable as REG_DWORD and ProxyOverride as REG_SZ
whenever it rereads its settings, so those two compare by value.

However the run ends, the cleanup closes the MCP server, stops the
server-sent-events server, clears the rules and calls vm.http.stop when a
capture of the run may be running, ends the fixture processes of the run,
deletes C:\\alcove-apps\\alcove-at7-app (and C:\\alcove-apps when the run
created it), and compares the guest's proxy settings and Root store with the
reading. When a step of that cannot finish, the script prints
`cleanup failed: ...` with what to do by hand and exits 1. SIGTERM, SIGHUP and
SIGINT print `interrupted; restoring the guest...`, run the same cleanup and
exit with 128 plus the signal's number (143, 129, 130); SIGHUP stays ignored
when the script was started with it ignored (nohup).

Usage: at7-e2e.py [--vm NAME] [--only N[,N...]]
"""
import argparse, http.server, json, os, re, shutil, signal, socketserver, sys, tempfile, threading, time

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout
from mcp_stdio import MCP, MCPError

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURE_BUILD = os.path.join(ROOT, "build", "alcove-fixture-windows-arm64.exe")
MCP_BUILD = os.path.join(ROOT, "mcp", "dist", "index.js")
APPS = r"C:\alcove-apps"
APP_NAME = "alcove-at7-app"
APP_DIR = APPS + "\\" + APP_NAME
EXE = "alcove-fixture.exe"
TITLE = "Alcove Fixture"
HOST = "example.com"
URL = "https://example.com/"
PAGE_TEXT = "Example Domain"
STATE_FILE = r"C:\ProgramData\Alcove\proxy-previous.json"
TRANSCRIPT = {"window": TITLE, "role": "Document", "name": "Transcript"}
FETCH = {"window": TITLE, "role": "Button", "name": "Fetch"}
RATE_LIMITED = '{"error":"rate_limited"}'
DELAY_MS = 3000
EVENTS = 5
EVENT_GAP_S = 0.4
STREAM_SPREAD_S = 1.0
STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
NORMALIZED_KINDS = {"ProxyEnable", "ProxyOverride"}

# Prints one JSON object with the proxy values of the agent's user, the WinHTTP proxy and the Root thumbprints.
PROXY_READING = r"""
$ErrorActionPreference = 'Stop'
function Val($key, $name) {
  if ($null -eq $key) { return $null }
  $v = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  if ($null -eq $v) { return $null }
  $kind = [string]$key.GetValueKind($name)
  if ($v -is [byte[]]) { return @{ kind = $kind; value = (($v | ForEach-Object { $_.ToString('X2') }) -join '') } }
  return @{ kind = $kind; value = [string]$v }
}
$hkcu = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64')
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
$inet = $hkcu.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
$conn = $hklm.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections')
$out = [ordered]@{}
foreach ($n in 'ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL') { $out[$n] = Val $inet $n }
$out['WinHttpSettings'] = Val $conn 'WinHttpSettings'
$out['root'] = @(Get-ChildItem Cert:\LocalMachine\Root | ForEach-Object { $_.Thumbprint } | Sort-Object)
$out['stateFile'] = Test-Path -LiteralPath 'STATE'
$out | ConvertTo-Json -Compress -Depth 4
""".replace("STATE", STATE_FILE)


class Failure(Exception):
    pass


def say(line):
    """Prints `line`; a terminal that is gone (after SIGHUP) does not stop the run or its cleanup."""
    try:
        print(line, flush=True)
    except OSError:
        pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l]


def under(path, folder):
    """Whether the guest path lies below the guest folder."""
    return path.lower().startswith(folder.lower() + "\\")


def proxy_differences(before, after):
    """The proxy values and Root certificates that differ between two readings, as sentences."""
    found = []
    for name in ("ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL", "WinHttpSettings"):
        a, b = before.get(name), after.get(name)
        if a is None or b is None:
            same = a == b
        elif name in NORMALIZED_KINDS:
            same = a["value"] == b["value"]
        else:
            same = a == b
        if not same:
            found.append(f"{name} was {a!r} and is {b!r}")
    gone = sorted(set(before["root"]) - set(after["root"]))
    added = sorted(set(after["root"]) - set(before["root"]))
    if gone:
        found.append(f"Root lost {gone}")
    if added:
        found.append(f"Root gained {added}")
    if after.get("stateFile") and not before.get("stateFile"):
        found.append(f"{STATE_FILE} exists")
    return found


class EventStream:
    """A server on 127.0.0.1 whose /sse sends EVENTS server-sent events EVENT_GAP_S apart."""

    def __init__(self):
        stream = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/sse":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                for n in range(1, EVENTS + 1):
                    self.wfile.write(f"data: event {n}\n\n".encode())
                    self.wfile.flush()
                    stream.sent.append(time.monotonic())
                    if n < EVENTS:
                        time.sleep(EVENT_GAP_S)

            def log_message(self, *args):
                pass

        self.sent = []
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Run:
    """The control connection, the VM, the reading taken before check 1 and what the checks started in the guest."""

    def __init__(self, client, vm, apps_existed, reading):
        self.c = client
        self.vm = vm
        self.apps_existed = apps_existed
        self.reading = reading
        self.mcps = []
        self.host = None
        self.cleanup_failed = False
        self.capture_may_run = False
        self.port = None
        self.ca = None
        self.deployed = False
        self.fixture_pids = set()
        self.stream = None

    # calls

    def call(self, op, reply_timeout=120, **params):
        return self.c.call(op, reply_timeout, name=self.vm, **params)

    def exec(self, command, timeout=60):
        r = self.call("vm.exec", timeout + 30, command=command, timeout=timeout)
        expect(r["code"] == 0, f"guest command {command[:120]!r} exited with {r['code']}: {r['stderr'].strip() or r['stdout'].strip()}")
        return r["stdout"].strip()

    def wait_for(self, conditions, timeout=30, **params):
        return self.call("vm.wait_for", timeout + 60, conditions=conditions, timeout=timeout, **params)

    def proxy_reading(self, c=None):
        r = (c or self.c).call("vm.exec", 120, name=self.vm, command=PROXY_READING, timeout=60)
        expect(r["code"] == 0, f"the proxy reading exited with {r['code']}: {r['stderr'].strip()}")
        reading = json.loads(lines(r["stdout"])[-1])
        reading["root"] = reading["root"] if isinstance(reading["root"], list) else [reading["root"]]
        return reading

    def mcp(self):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at7-e2e")
        return m

    def exchanges(self, since=None, **filters):
        params = dict(filters)
        if since is not None:
            params["since"] = since
        return self.call("vm.http.requests", limit=500, **params)["exchanges"]

    def newest_id(self):
        return self.call("vm.http.requests", limit=1)["next"]

    # the fixture

    def app_source(self):
        """The host directory that holds the fixture build under the name the deploy starts."""
        if self.host is None:
            self.host = tempfile.mkdtemp(prefix="alcove-at7-")
        folder = os.path.join(self.host, APP_NAME)
        os.makedirs(folder, exist_ok=True)
        target = os.path.join(folder, EXE)
        if not os.path.exists(target):
            expect(os.path.exists(FIXTURE_BUILD), f"missing {FIXTURE_BUILD}; build it with scripts/test/all.sh")
            shutil.copyfile(FIXTURE_BUILD, target)
        return folder

    def own_processes(self, c=None):
        processes = (c or self.c).call("vm.process.list", 60, name=self.vm)["processes"]
        return [p for p in processes if under(p["path"] or "", APP_DIR)]

    def transcript(self):
        return self.call("vm.ui.text", selector=TRANSCRIPT)["text"]

    def fetch_lines(self):
        return [l for l in lines(self.transcript()) if l.startswith("Fetch: ")]

    def fetch(self, timeout=60):
        """Clicks Fetch and returns the transcript line the click added, waiting up to `timeout` s for it."""
        before = len(self.fetch_lines())
        self.call("vm.ui.click", selector=FETCH)
        end = time.time() + timeout
        while True:
            found = self.fetch_lines()
            if len(found) > before:
                return found[before]
            expect(time.time() < end, f"the fixture added no Fetch line to its transcript {timeout} s after the click")
            time.sleep(0.5)

    # cleanup

    def cleanup_error(self, what):
        self.cleanup_failed = True
        say(f"cleanup failed: {what}")

    def cleanup(self):
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in STOP_SIGNALS}
        try:
            self.cleanup_steps()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)

    def cleanup_steps(self):
        for m in self.mcps:
            try:
                m.close()
            except Exception:
                pass
        if self.stream:
            self.stream.close()
            self.stream = None
        try:
            with Client(self.c.socket_path) as c:
                self.restore(c)
        except (ControlError, Failure) as e:
            self.cleanup_error(f"the control server failed ({e}); call vm.http.stop for '{self.vm}', end the processes that run from "
                               f"{APP_DIR} and delete that folder")
        try:
            self.c.close()
        except Exception:
            pass
        if self.host:
            shutil.rmtree(self.host, ignore_errors=True)

    def restore(self, c):
        if self.capture_may_run:
            try:
                c.call("vm.http.rule.clear", 60, name=self.vm)
            except ControlError:
                pass
            try:
                c.call("vm.http.stop", 400, name=self.vm)
            except ControlError as e:
                if "is not capturing" not in str(e):
                    self.cleanup_error(f"vm.http.stop answered {e}; call it again for '{self.vm}' once vm.status shows tools")
        left = self.own_processes(c)
        for p in left:
            try:
                c.call("vm.process.kill", 60, name=self.vm, pid=p["pid"], tree=True)
            except ControlError:
                pass
        end = time.time() + 15
        while left and time.time() < end:
            time.sleep(0.5)
            left = self.own_processes(c)
        if left:
            self.cleanup_error(f"the processes {[p['pid'] for p in left]} still run from {APP_DIR}; end them and delete the folder")
        elif self.deployed:
            self.delete(c, APP_DIR)
            if not self.apps_existed:
                try:
                    if not c.call("vm.fs.list", 60, name=self.vm, path=APPS)["entries"]:
                        c.call("vm.fs.delete", 60, name=self.vm, path=APPS)
                except ControlError as e:
                    self.cleanup_error(f"{APPS} could not be removed ({e}); delete the empty folder in the guest")
        try:
            differences = proxy_differences(self.reading, self.proxy_reading(c))
        except (ControlError, Failure) as e:
            self.cleanup_error(f"the guest's proxy settings could not be read ({e}); compare them with vm.doctor")
            return
        if differences:
            self.cleanup_error(f"the guest's proxy settings differ from before the run: {'; '.join(differences)}; call vm.http.stop for "
                               f"'{self.vm}', and put back by hand what it does not restore")

    def delete(self, c, folder):
        """Deletes a guest folder of the run; tries again for 20 s while a file in it is still in use."""
        end = time.time() + 20
        while True:
            try:
                c.call("vm.fs.delete", 120, name=self.vm, path=folder, recursive=True)
                return
            except ControlTimeout:
                raise
            except ControlError as e:
                if "does not exist" in str(e) or "not found" in str(e).lower():
                    return
                if time.time() > end:
                    self.cleanup_error(f"vm.fs.delete of {folder} answered {e}; delete the folder in the guest by hand")
                    return
                time.sleep(1)


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


def started(run, r):
    """Checks a vm.http.start reply and the doctor row; returns the proxy port."""
    expect(r.get("caInstalled") is True and r.get("systemProxySet") is True, f"vm.http.start answered {r!r}")
    m = re.fullmatch(r"10\.0\.2\.2:(\d+)", r.get("proxy", ""))
    expect(m, f"vm.http.start answered the proxy address {r.get('proxy')!r}")
    port = int(m.group(1))
    expect(r["env"].get("HTTPS_PROXY") == f"http://10.0.2.2:{port}", f"vm.http.start answered the environment {r['env']!r}")
    rows = [row for row in run.call("vm.doctor", 300)["checks"] if row["id"] == "proxy"]
    expect(len(rows) == 1 and rows[0]["ok"] is True and f"10.0.2.2:{port}" in rows[0]["detail"],
           f"vm.doctor answered the proxy rows {rows!r}")
    return port


def response_text(run, exchange):
    r = run.call("vm.http.request", exchange=exchange, part="response")
    expect(not r.get("base64"), f"the response of exchange {exchange} came back as base64 ({r.get('encoding')!r})")
    return r["body"]


@check("vm.http.start installs the CA and sets the system proxy; vm.doctor reports the capture")
def _(run):
    run.capture_may_run = True
    r = run.call("vm.http.start", 400)
    run.port = started(run, r)
    after = run.proxy_reading()
    added = sorted(set(after["root"]) - set(run.reading["root"]))
    expect(len(added) == 1, f"Cert:\\LocalMachine\\Root gained {added} during vm.http.start")
    run.ca = added[0]
    expect(after["ProxyServer"] and after["ProxyServer"]["value"] == f"10.0.2.2:{run.port}",
           f"the guest's ProxyServer is {after['ProxyServer']!r}")
    return f"proxy 10.0.2.2:{run.port}"


@check("the fixture's Fetch goes through the proxy from the vm.deploy environment; the exchange and its body are captured")
def _(run):
    expect(run.port, "check 1 starts the capture; run it first (add 1 to --only)")
    since = run.newest_id()
    run.deployed = True
    r = run.call("vm.deploy", 600, path=run.app_source(), launch={"exe": EXE, "args": ["--url", URL]})
    run.fixture_pids.add(r["pid"])
    expect(r.get("window") and r["window"]["title"] == TITLE, f"the fixture started without its window: {r!r}")
    line = run.fetch()
    stable = run.wait_for([{"type": "ui_text_stable", **TRANSCRIPT}], timeout=30)
    expect(stable["matched"] == 0, f"vm.wait_for ui_text_stable answered {stable!r}")
    expect(line == "Fetch: 200", f"the transcript says {line!r}")
    rows = [x for x in run.exchanges(since, host=HOST) if x["kind"] == "http"]
    expect(len(rows) == 1 and rows[0]["status"] == 200 and rows[0]["url"] == URL, f"vm.http.requests host={HOST} answered {rows!r}")
    body = response_text(run, rows[0]["id"])
    expect(PAGE_TEXT in body, f"the captured response of exchange {rows[0]['id']} lacks {PAGE_TEXT!r}: {body[:200]!r}")
    return f"exchange {rows[0]['id']}, {rows[0]['ms']} ms"


@check("PowerShell's Invoke-WebRequest goes through the system proxy and trusts the CA")
def _(run):
    since = run.newest_id()
    status = run.exec(f"(Invoke-WebRequest -UseBasicParsing {URL}).StatusCode")
    expect(status == "200", f"Invoke-WebRequest answered {status!r}")
    end = time.time() + 10
    while True:
        rows = [x for x in run.exchanges(since, host=HOST) if x["kind"] == "http" and x["status"] == 200]
        if rows or time.time() > end:
            break
        time.sleep(0.5)
    expect(len(rows) == 1, f"vm.http.requests host={HOST} after Invoke-WebRequest answered {rows!r}")
    return f"exchange {rows[0]['id']}"


@check("a rule with status 429 and times 1 answers one Fetch; the next Fetch reaches the server; vm.http.rule.remove deletes the used rule")
def _(run):
    rule = run.call("vm.http.rule.add", match={"host": HOST}, action={"status": 429, "body": RATE_LIMITED, "times": 1})["rule"]
    since = run.newest_id()
    line = run.fetch()
    expect(line == "Fetch: 429", f"the transcript says {line!r} after the 429 rule")
    rows = run.exchanges(since, host=HOST)
    expect(len(rows) == 1 and rows[0]["status"] == 429 and rows[0].get("rule") == rule, f"vm.http.requests answered {rows!r} for rule {rule}")
    expect(response_text(run, rows[0]["id"]) == RATE_LIMITED, f"the canned body of exchange {rows[0]['id']} differs")
    line = run.fetch()
    expect(line == "Fetch: 200", f"the transcript says {line!r} after the rule was used up")
    rules = run.call("vm.http.rule.list")["rules"]
    expect([(r["id"], r["hits"], r.get("remaining")) for r in rules] == [(rule, 1, 0)], f"vm.http.rule.list answered {rules!r} after the rule was used up")
    run.call("vm.http.rule.remove", rule=rule)
    expect(run.call("vm.http.rule.list")["rules"] == [], f"vm.http.rule.list still lists rule {rule} after vm.http.rule.remove")
    return f"rule {rule}"


@check("a rule with delayMs holds the Fetch for at least 3 s; vm.http.rule.clear removes it")
def _(run):
    run.call("vm.http.rule.add", match={"host": HOST}, action={"delayMs": DELAY_MS})
    since = run.newest_id()
    line = run.fetch()
    expect(line == "Fetch: 200", f"the transcript says {line!r} with the delay rule")
    rows = run.exchanges(since, host=HOST)
    expect(len(rows) == 1 and rows[0]["ms"] >= DELAY_MS, f"vm.http.requests answered {rows!r} with a {DELAY_MS} ms delay rule")
    run.call("vm.http.rule.clear")
    expect(run.call("vm.http.rule.list")["rules"] == [], "vm.http.rule.list still lists rules after vm.http.rule.clear")
    return f"{rows[0]['ms']} ms"


@check("a server-sent-events stream reaches curl.exe through the proxy as it is sent, and the capture holds every event")
def _(run):
    run.stream = EventStream()
    target = f"http://10.0.2.2:{run.stream.port}/sse"
    since = run.newest_id()
    job = run.call("vm.exec.start", argv=["curl.exe", "-N", "-sS", "-x", f"http://10.0.2.2:{run.port}", target])["job"]
    seen, offset, text, code = {}, 0, "", None
    end = time.time() + 60
    while True:
        r = run.call("vm.exec.read", job=job, outOffset=offset)
        text += r["out"]
        offset = r["outNext"]
        for n in range(1, EVENTS + 1):
            if f"data: event {n}" in text and n not in seen:
                seen[n] = time.monotonic()
        if r["state"] != "running":
            code = r.get("code")
            break
        expect(time.time() < end, f"curl.exe still runs 60 s after it started; it printed {text[-300:]!r}")
        time.sleep(0.2)
    expect(code == 0, f"curl.exe exited with {code}: {r.get('err', '').strip()}")
    expect(sorted(seen) == list(range(1, EVENTS + 1)), f"curl.exe printed {text!r}")
    spread = seen[EVENTS] - seen[1]
    expect(spread >= STREAM_SPREAD_S, f"the guest saw the first event only {spread:.2f} s before the last; the proxy held the stream back")
    rows = [x for x in run.exchanges(since, host="10.0.2.2") if x["url"] == target]
    expect(len(rows) == 1 and rows[0]["status"] == 200, f"vm.http.requests answered {rows!r} for {target}")
    body = response_text(run, rows[0]["id"])
    missing = [n for n in range(1, EVENTS + 1) if f"data: event {n}" not in body]
    expect(not missing, f"the captured stream lacks the events {missing}: {body!r}")
    run.stream.close()
    run.stream = None
    return f"first event {spread:.2f} s before the last"


@check("vm.http.stop puts the guest's proxy settings back, removes the CA and leaves the direct path working")
def _(run):
    r = run.call("vm.http.stop", 400)
    expect(r["exchanges"] >= 6 and not r.get("warning"), f"vm.http.stop answered {r!r}")
    run.capture_may_run = False
    differences = proxy_differences(run.reading, run.proxy_reading())
    expect(not differences, f"after vm.http.stop: {'; '.join(differences)}")
    status = run.exec(f"(Invoke-WebRequest -UseBasicParsing {URL}).StatusCode")
    expect(status == "200", f"Invoke-WebRequest without the proxy answered {status!r}")
    try:
        run.call("vm.http.requests")
        raise Failure("vm.http.requests answered after vm.http.stop")
    except ControlError as e:
        expect("is not capturing" in str(e), f"vm.http.requests after vm.http.stop answered {e}")
    return f"{r['exchanges']} exchanges"


@check("alcove_http_capture_start, alcove_http_requests and alcove_http_capture_stop work over stdio")
def _(run):
    expect(os.path.exists(MCP_BUILD), f"missing {MCP_BUILD}; run npm run build in mcp/")
    m = run.mcp()
    run.capture_may_run = True
    err, text, _ = m.call("alcove_http_capture_start", {"name": run.vm}, timeout=420)
    expect(not err and re.search(r"10\.0\.2\.2:\d+", text), f"alcove_http_capture_start answered {text!r}")
    status = run.exec(f"(Invoke-WebRequest -UseBasicParsing {URL}).StatusCode")
    expect(status == "200", f"Invoke-WebRequest answered {status!r} during the MCP capture")
    end = time.time() + 10
    while True:
        err, listing, _ = m.call("alcove_http_requests", {"name": run.vm, "host": HOST}, timeout=120)
        found = re.search(r"#(\d+) \S+ GET " + re.escape(URL) + r" -> 200", listing)
        if err or found or time.time() > end:
            break
        time.sleep(0.5)
    expect(not err and found, f"alcove_http_requests answered {listing!r}")
    err, detail, _ = m.call("alcove_http_requests", {"name": run.vm, "id": int(found.group(1)), "part": "response"}, timeout=120)
    expect(not err and PAGE_TEXT in detail, f"alcove_http_requests with id answered {detail[:300]!r}")
    err, text, _ = m.call("alcove_http_capture_stop", {"name": run.vm}, timeout=300)
    expect(not err, f"alcove_http_capture_stop answered {text!r}")
    run.capture_may_run = False
    differences = proxy_differences(run.reading, run.proxy_reading())
    expect(not differences, f"after alcove_http_capture_stop: {'; '.join(differences)}")
    return f"exchange {found.group(1)}"


def refusal_to_start(client, vm):
    """What of this run's folders, windows, processes and captures the guest already holds; empty when the run can
    start. Also returns whether the apps root exists."""
    found = []
    answers = lines(client.call("vm.exec", 90, name=vm, timeout=60,
                                command=f"(Test-Path -LiteralPath '{APP_DIR}'), (Test-Path -LiteralPath '{APPS}'), (Test-Path -LiteralPath '{STATE_FILE}')")["stdout"])
    if answers[0] == "True":
        found.append(f"the folder {APP_DIR}")
    if answers[2] == "True":
        found.append(f"{STATE_FILE}, left by an earlier capture (vm.http.stop clears it)")
    for w in client.call("vm.window.list", 120, name=vm)["windows"]:
        if TITLE in w["title"]:
            found.append(f"the window {w['title']!r} of {w['process']} (pid {w['pid']})")
    for p in client.call("vm.process.list", 60, name=vm, filter="alcove-fixture")["processes"]:
        found.append(f"the process {p['name']} (pid {p['pid']})")
    try:
        client.call("vm.http.requests", 60, name=vm, limit=1)
        found.append("a running capture (vm.http.stop ends it)")
    except ControlError as e:
        if "is not capturing" not in str(e):
            raise
    return found, answers[1] == "True"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    for sig in STOP_SIGNALS:
        if sig == signal.SIGHUP and signal.getsignal(sig) == signal.SIG_IGN:
            continue
        signal.signal(sig, terminate)

    try:
        client = Client()
        client.call("hello", 60)
        status = client.call("vm.status", 60, name=args.vm)
        caps = status.get("agentCaps") or []
        if status.get("state") != "running" or status.get("tools") is not True or any(c not in caps for c in ("rpc", "jobs", "proc", "fs", "exec", "ui")):
            print(f"FAIL 0: VM '{args.vm}' is {status.get('state')} with tools {status.get('tools')!r} and agent capabilities {caps!r}; "
                  "start it with scripts/test/ctl.py vm.start, wait for the guest tools (scripts/test/install-agent.py installs them) and run this script again")
            sys.exit(1)
        found, apps_existed = refusal_to_start(client, args.vm)
    except ControlError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    if found:
        print(f"FAIL 0: the guest already holds what this run creates: {'; '.join(found)}; remove it and run this script again")
        sys.exit(1)
    run = Run(client, args.vm, apps_existed, None)
    try:
        run.reading = run.proxy_reading()
    except (ControlError, Failure) as e:
        print(f"FAIL 0: the guest's proxy settings could not be read ({e}); check the guest shell with vm.doctor and run this script again")
        sys.exit(1)
    failed = None
    interrupted = False
    passed = []
    try:
        for n, title, fn in CHECKS:
            if only and n not in only:
                continue
            try:
                note = fn(run)
            except Failure as e:
                failed = f"FAIL {n}: {e}"
            except ControlTimeout as e:
                failed = f"FAIL {n}: the control server did not answer ({e})"
            except ControlError as e:
                failed = f"FAIL {n}: {e}"
            except MCPError as e:
                failed = f"FAIL {n}: the MCP server failed ({e})"
            except (KeyError, IndexError, TypeError, ValueError, AttributeError) as e:
                failed = f"FAIL {n}: a reply lacks an expected field ({type(e).__name__}: {e})"
            except OSError as e:
                failed = f"FAIL {n}: {e}"
            if failed:
                say(failed)
                break
            passed.append(n)
            say(f"PASS {n} {title}" + (f" ({note})" if note else ""))
        if not failed:
            say(f"{len(passed)} passed")
    except (KeyboardInterrupt, SystemExit):
        interrupted = True
        raise
    finally:
        for sig in STOP_SIGNALS:
            signal.signal(sig, signal.SIG_IGN)
        if interrupted:
            say("interrupted; restoring the guest...")
        try:
            run.cleanup()
        except Exception as e:
            run.cleanup_error(f"{type(e).__name__}: {e}")
        if interrupted and run.cleanup_failed:
            sys.exit(1)
    if failed or run.cleanup_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
