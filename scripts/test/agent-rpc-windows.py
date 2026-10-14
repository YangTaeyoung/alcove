#!/usr/bin/env python3
"""Checks the agent's request/response operations against a running Windows VM.

Talks docs/agent-protocol.md directly on the forwarded agent port: reads hello,
pairs or authenticates with the agentKey of the VM's config.json (--vm), sends
welcome, then req/res with ids. Needs the agent installed with
--allow-exec (scripts/test/install-agent.py). Each check prints
`PASS <n> <title>`; the first failing check prints `FAIL <n>: <reason>` and the
script exits 1. Files go under C:\\alcove-e2e\\rpc. However the run ends, a
second connection kills the jobs the script started, which include the
Character Map windows it opened, and deletes that directory. The run refuses to
start when C:\\alcove-e2e exists. SIGTERM, SIGHUP and SIGINT print
`interrupted; cleaning up...`, run the same cleanup and exit with 128 plus the
signal's number (143, 129, 130); SIGHUP stays ignored when the script was
started with it ignored (nohup).

Usage: agent-rpc-windows.py [--vm NAME] [--agent-port N] [--only N[,N...]]
"""
import argparse, base64, hashlib, json, ntpath, os, select, signal, socket, sys, time

sys.dont_write_bytecode = True
from alcove_ctl import ignore_stop_signals, stop_signal_handlers
from agent_key import AgentKeyError, agent_key, check_answer, first_message

BASE = r"C:\alcove-e2e\rpc"
CHUNK = 262144
WINDOW_CHECK = (
    "Add-Type -Namespace AlcoveE2E -Name Win -MemberDefinition '"
    '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); '
    '[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);'
    "'; $h = [AlcoveE2E.Win]::GetConsoleWindow(); "
    '"console=$h visible=$([AlcoveE2E.Win]::IsWindowVisible($h))"'
)


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


class Agent:
    def __init__(self, port, key):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""
        self.next_id = 0
        self.results = {}
        self.events = []
        self.other = []
        self.hello = self._next(10)
        expect(self.hello and self.hello.get("t") == "hello", f"expected hello, got {self.hello!r}")
        first = first_message(self.hello, key)
        if first:
            self.send(first)
            try:
                check_answer(self._next(10))
            except AgentKeyError as e:
                raise Failure(str(e)) from None
        self.send({"t": "welcome", "v": 1})

    def send(self, m):
        self.s.sendall((json.dumps(m) + "\n").encode())

    def _next(self, timeout):
        """Returns the next message, or None when the timeout passes."""
        end = time.time() + timeout
        while b"\n" not in self.buf:
            left = end - time.time()
            if left <= 0 or not select.select([self.s], [], [], left)[0]:
                return None
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise Failure("the agent closed the connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def pump(self, done, timeout):
        """Reads messages until done() is true; answers ping, files the rest."""
        end = time.time() + timeout
        while not done():
            m = self._next(max(0, end - time.time()))
            if m is None:
                return False
            t = m.get("t")
            if t == "ping":
                self.send({"t": "pong"})
            elif t == "res":
                self.results[m.get("id")] = m
            elif t == "ev":
                self.events.append(m)
            else:
                self.other.append(m)
        return True

    def request(self, op, **params):
        self.next_id += 1
        self.send({"t": "req", "id": self.next_id, "op": op, **params})
        return self.next_id

    def wait(self, rid, timeout=60):
        expect(self.pump(lambda: rid in self.results, timeout), f"no reply to request {rid} within {timeout} s")
        return self.results.pop(rid)

    def call(self, op, timeout=60, **params):
        """Sends a request and returns its result; a failed reply fails the check."""
        res = self.wait(self.request(op, **params), timeout)
        expect(res.get("ok") is True, f"{op} failed: {res.get('error')}")
        return res

    def v1(self, typ, timeout=60):
        """Returns the next v1 message of the given type."""
        def find():
            return any(m.get("t") == typ for m in self.other)
        expect(self.pump(find, timeout), f"no {typ} within {timeout} s")
        for i, m in enumerate(self.other):
            if m.get("t") == typ:
                return self.other.pop(i)

    def event(self, name, job, timeout=10):
        def find():
            return any(e.get("name") == name and e.get("job") == job for e in self.events)
        expect(self.pump(find, timeout), f"no {name} event for job {job} within {timeout} s")
        return next(e for e in self.events if e.get("name") == name and e.get("job") == job)


class Run:
    def __init__(self, agent, key):
        self.a = agent
        self.key = key
        self.home = ""
        self.user = ""
        self.jobs = []
        self.markers = []

    def start(self, **params):
        r = self.a.call("exec.start", **params)
        self.jobs.append(r["job"])
        return r["job"], r["pid"]

    def read_until(self, job, done, timeout=30):
        """Polls exec.read with advancing offsets until done(out, err, last reply)."""
        out = err = ""
        out_off = err_off = 0
        end = time.time() + timeout
        while True:
            r = self.a.call("exec.read", job=job, out_offset=out_off, err_offset=err_off)
            expect(not r["dropped"], f"exec.read of job {job} dropped output")
            out, err = out + r["out"], err + r["err"]
            advanced = r["out_next"] != out_off or r["err_next"] != err_off
            out_off, err_off = r["out_next"], r["err_next"]
            if not advanced and done(out, err, r):
                return out, err, r
            if time.time() > end:
                return out, err, None
            if not advanced:
                time.sleep(0.2)

    def procs(self, name=None):
        return self.a.call("proc.list", **({"name": name} if name else {}))["procs"]

    def cleanup(self, port):
        """On a new connection: kills the started jobs and the PowerShell
        processes whose command line holds a registered marker, then deletes
        BASE and its parent when that is empty."""
        previous = ignore_stop_signals()
        try:
            self.cleanup_steps(port)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)

    def cleanup_steps(self, port):
        try:
            a = Agent(port, self.key)
        except (Failure, OSError, ValueError) as e:
            print(f"cleanup did not run: {e}; jobs {self.jobs} and {BASE} may remain in the guest", file=sys.stderr)
            return
        steps = [("exec.kill", {"job": job}) for job in self.jobs]
        if self.markers:
            try:
                for p in a.call("proc.list", name="powershell")["procs"]:
                    if any(marker in p["cmd"] for marker in self.markers):
                        steps.append(("proc.kill", {"pid": p["pid"], "tree": True}))
            except (Failure, OSError, ValueError, KeyError, TypeError):
                pass
        steps += [("fs.delete", {"path": BASE, "recursive": True}), ("fs.delete", {"path": ntpath.dirname(BASE)})]
        for op, params in steps:
            try:
                a.wait(a.request(op, **params), 30)
            except (Failure, OSError, ValueError):
                pass


def exited(out, err, r):
    return r["state"] == "exited"


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l != ""]


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


@check("exec.run returns UTF-8 stdout, stderr and the exit code")
def _(a, run):
    r = a.call("exec.run", cmd="Write-Output '한글 ok'; [Console]::Error.WriteLine('에러'); exit 5")
    expect("한글 ok" in r["stdout"], f"stdout is {r['stdout']!r}")
    expect("에러" in r["stderr"], f"stderr is {r['stderr']!r}")
    expect(r["code"] == 5, f"code is {r['code']!r}")
    expect(r["timed_out"] is False and r["truncated"] is False, f"timed_out/truncated are {r['timed_out']!r}/{r['truncated']!r}")


@check("exec.run applies cwd, env and stdin")
def _(a, run):
    r = a.call("exec.run", cwd="C:\\Windows", env={"ALCOVE_E2E": "값 1"}, stdin="표준 입력\n",
               cmd="(Get-Location).Path; $env:ALCOVE_E2E; [Console]::In.ReadLine()")
    expect(lines(r["stdout"]) == ["C:\\Windows", "값 1", "표준 입력"], f"stdout is {r['stdout']!r}, stderr {r['stderr']!r}")
    expect(r["code"] == 0, f"code is {r['code']!r}")


@check("exec.run shows no console window")
def _(a, run):
    r = a.call("exec.run", cmd=WINDOW_CHECK)
    expect(r["code"] == 0 and "visible=" in r["stdout"], f"code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")
    expect("visible=False" in r["stdout"], f"the console window is visible: {r['stdout'].strip()!r}")


@check("shell cmd runs pipelines and commands that start with a quoted path")
def _(a, run):
    r = a.call("exec.run", shell="cmd", cmd='echo hello & dir "C:\\Program Files" | findstr /C:"Common Files"')
    expect("hello" in r["stdout"] and "Common Files" in r["stdout"], f"stdout is {r['stdout']!r}, stderr {r['stderr']!r}")
    r = a.call("exec.run", shell="cmd", cmd='"C:\\Windows\\System32\\cmd.exe" /C "echo quoted ok"')
    expect(lines(r["stdout"]) == ["quoted ok"] and r["code"] == 0, f"code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")


@check("shell none runs argv directly")
def _(a, run):
    r = a.call("exec.run", shell="none", argv=["C:\\Windows\\System32\\whoami.exe"])
    out = lines(r["stdout"])
    expect(len(out) == 1 and run.user.lower() in out[0].lower() and r["code"] == 0, f"code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")


@check("exec.run timeout kills the process tree")
def _(a, run):
    t0 = time.time()
    r = a.call("exec.run", timeout=15, shell="cmd", cmd="ping -n 60 127.0.0.1", timeout_ms=3000)
    took = time.time() - t0
    expect(r["timed_out"] is True, f"timed_out is {r['timed_out']!r} after {took:.1f} s (code {r['code']!r})")
    expect(took >= 2.5, f"the command returned after {took:.1f} s, before its timeout")
    left = run.procs("PING")
    expect(left == [], f"ping survived the timeout: {left!r}")


@check("exec.run keeps the last 200000 bytes of a stream")
def _(a, run):
    r = a.call("exec.run", cmd="'a' * 300000; 'END'")
    expect(r["truncated"] is True, f"truncated is {r['truncated']!r} with {len(r['stdout'])} characters of stdout")
    expect(r["stdout"].endswith("END\r\n"), f"stdout ends with {r['stdout'][-12:]!r}")
    expect(len(r["stdout"].encode()) <= 200000, f"stdout has {len(r['stdout'].encode())} bytes")
    expect(len(r["stdout"].encode()) == 200000, f"stdout has {len(r['stdout'].encode())} bytes, expected the full 200000")


@check("requests on one connection run concurrently")
def _(a, run):
    t0 = time.time()
    slow = a.request("exec.run", cmd="Start-Sleep 6")
    ping = a.request("ping")
    quick = a.request("exec.run", cmd="hostname")
    a.send({"t": "ping"})
    r = a.wait(ping, 3)
    expect(r.get("ok") is True and r.get("pong") is True, f"ping answered {r!r}")
    r = a.wait(quick, max(0.1, 3 - (time.time() - t0)))
    expect(r.get("ok") is True and lines(r["stdout"]) != [], f"hostname answered {r!r}")
    a.v1("pong", max(0.1, 3 - (time.time() - t0)))
    expect(slow not in a.results, "the sleeping command answered before the quick ones")
    r = a.wait(slow, 30)
    took = time.time() - t0
    expect(r.get("ok") is True and r["code"] == 0, f"sleep answered {r!r}")
    expect(took >= 5, f"the sleeping command answered after {took:.1f} s")


@check("a job streams output through exec.read, exits by itself and emits job.exited")
def _(a, run):
    job, pid = run.start(cmd="1..6 | % { $_; Start-Sleep -Milliseconds 400 }")
    expect(isinstance(pid, int) and pid > 0, f"pid is {pid!r}")
    out, err, r = run.read_until(job, exited, 30)
    expect(r is not None, f"job {job} is still running after 30 s with its stdin never written; output so far {out!r}")
    expect(lines(out) == ["1", "2", "3", "4", "5", "6"], f"output is {out!r}, stderr {err!r}")
    expect(r["code"] == 0 and r["pid"] == pid, f"code {r.get('code')!r}, pid {r.get('pid')!r}")
    ev = a.event("job.exited", job)
    expect(ev.get("code") == 0, f"job.exited carried {ev!r}")
    listed = [j for j in a.call("exec.list")["jobs"] if j["job"] == job]
    expect(len(listed) == 1, f"exec.list has {len(listed)} entries for {job}")
    j = listed[0]
    expect(j["state"] == "exited" and j["code"] == 0 and j["pid"] == pid and "Start-Sleep" in j["cmd"] and j["started"],
           f"exec.list entry is {j!r}")


@check("a job reads exec.write input and exits on eof")
def _(a, run):
    # Writes two lines to findstr, closes its stdin, then reads the output.
    job, _pid = run.start(shell="cmd", cmd="findstr x")
    a.call("exec.write", job=job, data="axb\r\nnope\r\n")
    expect(a.call("exec.read", job=job)["state"] == "running", "findstr exited before eof")
    a.call("exec.write", job=job, data="", eof=True)
    out, err, r = run.read_until(job, exited, 10)
    expect(r is not None, "findstr did not exit within 10 s of eof")
    expect(r["code"] == 0 and lines(out) == ["axb"], f"code {r['code']!r}, out {out!r}, err {err!r}")
    res = a.wait(a.request("exec.write", job=job, data="late\r\n"))
    expect(res.get("ok") is False and "exec.start" in res.get("error", ""), f"exec.write after exit answered {res!r}")

    job, _pid = run.start(cmd="while ($null -ne ($l = [Console]::In.ReadLine())) { if ($l -match 'x') { $l } }")
    a.call("exec.write", job=job, data="axb\r\nnope\r\n")
    out, err, r = run.read_until(job, lambda o, e, r: "axb" in o or r["state"] == "exited", 10)
    expect(r is not None and r["state"] == "running" and lines(out) == ["axb"],
           f"exec.read did not show 'axb' from the running job; state {r and r['state']!r}, out {out!r}, err {err!r}")
    a.call("exec.write", job=job, data="한글 x 줄\r\n아님\r\n")
    out, err, r = run.read_until(job, lambda o, e, r: len(lines(o)) >= 2 or r["state"] == "exited", 10)
    expect(r is not None and r["state"] == "running" and lines(out) == ["axb", "한글 x 줄"],
           f"exec.read did not show the Korean line from the running job; state {r and r['state']!r}, out {out!r}, err {err!r}")
    a.call("exec.write", job=job, data="cxd\r\n", eof=True)
    out, err, r = run.read_until(job, exited, 10)
    expect(r is not None, "the line filter did not exit within 10 s of eof")
    expect(r["code"] == 0 and lines(out) == ["axb", "한글 x 줄", "cxd"], f"code {r['code']!r}, out {out!r}, err {err!r}")


@check("exec.kill ends a job and its process tree")
def _(a, run):
    job, _pid = run.start(shell="cmd", cmd="ping -t 127.0.0.1")
    out, err, r = run.read_until(job, lambda o, e, r: "Reply from" in o, 10)
    expect(r is not None, f"ping printed nothing within 10 s; out {out!r}, err {err!r}")
    expect(run.procs("PING") != [], "proc.list shows no PING while the job runs")
    r = a.call("exec.kill", job=job)
    expect(r["state"] == "exited", f"state is {r['state']!r}")
    left = run.procs("PING")
    expect(left == [], f"ping survived exec.kill: {left!r}")
    a.event("job.exited", job)


@check("proc.list reports processes and proc.kill ends one by name")
def _(a, run):
    procs = run.procs()
    expect(len(procs) > 20, f"proc.list returned {len(procs)} processes")
    bad = [p for p in procs if not isinstance(p.get("pid"), int) or not p.get("name")]
    expect(bad == [], f"{len(bad)} entries lack pid or name, e.g. {bad[:2]!r}")
    agents = [p for p in procs if p["name"].lower() == "alcove-agent.exe"]
    expect(agents and all(p["path"].lower().endswith("alcove-agent.exe") for p in agents), f"alcove-agent.exe entries: {agents!r}")
    expect(any(p["mem_kb"] > 0 and p["ppid"] > 0 and "--allow-exec" in p["cmd"] for p in agents), f"alcove-agent.exe entries: {agents!r}")
    expect(len(run.procs("alcove-agent")) >= 1, "proc.list name=alcove-agent returned nothing")
    expect(run.procs("no-such-process-name") == [], "proc.list with an unknown name returned processes")

    gui = "charmap.exe"
    expect(run.procs("charmap") == [], f"{gui} runs already; close it in the guest before this check")
    _job, pid = run.start(shell="none", argv=["C:\\Windows\\System32\\" + gui])
    end = time.time() + 10
    while time.time() < end and not run.procs("charmap"):
        time.sleep(0.5)
    started = run.procs("charmap")
    expect([p["pid"] for p in started] == [pid], f"proc.list shows {started!r} after exec.start returned pid {pid}")
    r = a.call("proc.kill", name=gui, tree=True)
    expect(r["killed"] == 1, f"killed is {r['killed']!r}")
    left = run.procs("charmap")
    expect(left == [], f"{gui} survived proc.kill: {left!r}")
    r = a.call("proc.kill", name=gui, tree=True)
    expect(r["killed"] == 0, f"proc.kill of an absent name reported killed={r['killed']!r}")
    return f"GUI process: {gui} pid {pid}"


@check("fs operations write, hash, rename, read, list, tail and delete")
def _(a, run):
    r = a.call("fs.mkdir", path=BASE)
    expect(r["path"] == BASE, f"fs.mkdir path is {r['path']!r}")

    payload = os.urandom(600000)
    digest = hashlib.sha256(payload).hexdigest()
    part = BASE + "\\한글 dir\\b in.bin.alcove-part"
    final = BASE + "\\한글 dir\\b in.bin"
    for off in range(0, len(payload), CHUNK):
        r = a.call("fs.write", path=part, offset=off, truncate=off == 0, mkdirs=True,
                   data=base64.b64encode(payload[off:off + CHUNK]).decode())
        expect(r["size"] == min(off + CHUNK, len(payload)), f"fs.write at {off} reports size {r['size']!r}")
    r = a.call("fs.stat", path=part, sha256=True)
    expect(r["exists"] is True and r["dir"] is False and r["size"] == len(payload) and r["path"] == part and r["mtime"],
           f"fs.stat is {r!r}")
    expect(r["sha256"] == digest, f"guest digest {r['sha256']!r}, local {digest!r}")
    r = a.call("fs.rename", to=final, **{"from": part})
    expect(r["path"] == final, f"fs.rename path is {r['path']!r}")

    got, off = b"", 0
    while True:
        r = a.call("fs.read", path=final, offset=off, length=CHUNK)
        piece = base64.b64decode(r["data"])
        expect(r["size"] == len(payload), f"fs.read size is {r['size']!r}")
        got, off = got + piece, off + len(piece)
        if r["eof"]:
            break
        expect(piece != b"", f"fs.read at {off} returned no bytes without eof")
    expect(got == payload, f"read back {len(got)} bytes that differ from the {len(payload)} written")

    names = {e["name"]: e for e in a.call("fs.list", path=BASE, recursive=True)["entries"]}
    expect(set(names) == {"한글 dir", "한글 dir/b in.bin"}, f"fs.list names are {sorted(names)!r}")
    expect(names["한글 dir"]["dir"] is True and names["한글 dir/b in.bin"]["size"] == len(payload), f"fs.list entries are {names!r}")
    flat = [e["name"] for e in a.call("fs.list", path=BASE)["entries"]]
    expect(flat == ["한글 dir"], f"non-recursive fs.list names are {flat!r}")

    r = a.call("fs.stat", path="~")
    expect(r["path"] == run.home and r["dir"] is True, f"'~' resolves to {r!r}")
    r = a.call("fs.stat", path="~/Desktop")
    expect(r["path"] == run.home + "\\Desktop" and r["exists"] is True, f"'~/Desktop' resolves to {r!r}")

    text = "".join(f"line {i:04d}\r\n" for i in range(1, 1001)).encode()
    log = BASE + "\\tail.log"
    a.call("fs.write", path=log, truncate=True, data=base64.b64encode(text).decode())
    r = a.call("fs.tail", path=log, lines=5)
    tail = base64.b64decode(r["data"]).decode()
    expect(tail == "".join(f"line {i:04d}\r\n" for i in range(996, 1001)) and r["size"] == len(text), f"fs.tail is {tail!r}, size {r['size']!r}")

    src, dst = BASE + "\\new.txt", BASE + "\\old.txt"
    a.call("fs.write", path=src, data=base64.b64encode(b"new content").decode())
    a.call("fs.write", path=dst, data=base64.b64encode(b"old content, longer").decode())
    res = a.wait(a.request("fs.rename", to=dst, **{"from": src}))
    expect(res.get("ok") is False and "overwrite" in res.get("error", ""), f"fs.rename onto an existing file answered {res!r}")
    a.call("fs.rename", to=dst, overwrite=True, **{"from": src})
    r = a.call("fs.read", path=dst)
    expect(base64.b64decode(r["data"]) == b"new content" and r["eof"] is True, f"the overwritten file holds {base64.b64decode(r['data'])!r}")
    expect(a.call("fs.stat", path=src)["exists"] is False, "the renamed source still exists")

    r = a.call("fs.delete", path=BASE, recursive=True)
    expect(r["deleted"] is True, f"deleted is {r['deleted']!r}")
    expect(a.call("fs.stat", path=BASE)["exists"] is False, f"{BASE} exists after fs.delete")
    expect(a.call("fs.delete", path=BASE, recursive=True)["deleted"] is False, "fs.delete of a missing path reported deleted")


@check("fs.list with sha256 lists a file another process holds open, without a digest")
def _(a, run):
    d = BASE + "\\locked"
    held, free = d + "\\held.bin", d + "\\free.txt"
    a.call("fs.write", path=held, mkdirs=True, data=base64.b64encode(b"held bytes").decode())
    a.call("fs.write", path=free, data=base64.b64encode(b"free bytes").decode())
    job, _pid = run.start(cmd=f"$f = [IO.File]::Open('{held}','Open','ReadWrite','None'); 'LOCKED'; Start-Sleep 120")
    out, err, r = run.read_until(job, lambda o, e, r: "LOCKED" in o or r["state"] == "exited", 20)
    expect(r is not None and "LOCKED" in out, f"the locking job did not report LOCKED; out {out!r}, err {err!r}")
    res = a.wait(a.request("fs.list", path=d, sha256=True))
    expect(res.get("ok") is True, f"fs.list failed: {res.get('error')}")
    names = {e["name"]: e for e in res["entries"]}
    expect(set(names) == {"held.bin", "free.txt"}, f"fs.list names are {sorted(names)!r}")
    expect(names["free.txt"].get("sha256") == hashlib.sha256(b"free bytes").hexdigest(), f"free.txt entry is {names['free.txt']!r}")
    expect("sha256" not in names["held.bin"] and names["held.bin"]["size"] == 10, f"held.bin entry is {names['held.bin']!r}")
    res = a.wait(a.request("fs.stat", path=held, sha256=True))
    expect(res.get("ok") is False and "cannot hash" in res.get("error", ""), f"fs.stat sha256 of the held file answered {res!r}")
    expect(a.call("exec.kill", job=job)["state"] == "exited", "the locking job did not exit")
    r = a.call("fs.list", path=d, sha256=True)
    names = {e["name"]: e for e in r["entries"]}
    expect(names["held.bin"].get("sha256") == hashlib.sha256(b"held bytes").hexdigest(), f"held.bin entry after release is {names['held.bin']!r}")
    a.call("fs.delete", path=BASE, recursive=True)


@check("v1 clipboard.set and exec work on the same connection without a console window")
def _(a, run):
    marker = f"rpc check 한글 {int(time.time())}"
    a.send({"t": "clipboard.set", "text": marker})
    a.send({"t": "exec", "cmd": "Get-Clipboard -Raw"})
    r = a.v1("exec.result")
    expect(marker in r.get("out", "") and r.get("code") == 0, f"v1 exec returned code {r.get('code')!r}, out {r.get('out')!r}")
    a.send({"t": "exec", "cmd": WINDOW_CHECK})
    r = a.v1("exec.result")
    expect("visible=False" in r.get("out", ""), f"v1 exec console check returned code {r.get('code')!r}, out {r.get('out')!r}")
    expect(a.call("ping").get("pong") is True, "ping after the v1 messages did not answer")


@check("exec.start with shell none shows the window of a GUI program")
def _(a, run):
    expect(run.procs("charmap") == [], "charmap.exe runs already; close it in the guest before this check")
    _job, pid = run.start(shell="none", argv=["C:\\Windows\\System32\\charmap.exe"])
    query = f"$p = Get-Process -Id {pid}; \"hwnd=$($p.MainWindowHandle) title=$($p.MainWindowTitle)\""
    end = time.time() + 10
    while True:
        r = a.call("exec.run", cmd=query)
        if "title=Character Map" in r["stdout"] or time.time() > end:
            break
        time.sleep(0.5)
    killed = a.call("proc.kill", pid=pid, tree=True)["killed"]
    expect("title=Character Map" in r["stdout"], f"charmap.exe has no visible main window: {r['stdout'].strip()!r} {r['stderr'].strip()!r}")
    expect(killed == 1, f"proc.kill by pid reported killed={killed!r}")
    expect(run.procs("charmap") == [], "charmap.exe survived proc.kill by pid")


@check("exec.run and v1 exec without stdin give the command an input at end-of-file")
def _(a, run):
    read_line = "$l = [Console]::In.ReadLine(); \"null=$($null -eq $l)\""
    r = a.call("exec.run", timeout=20, cmd=read_line, timeout_ms=10000)
    expect(r["timed_out"] is False and lines(r["stdout"]) == ["null=True"] and r["code"] == 0,
           f"PowerShell ReadLine: timed_out {r['timed_out']!r}, code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")
    r = a.call("exec.run", timeout=20, shell="cmd", cmd="set /p x= & echo done", timeout_ms=10000)
    expect(r["timed_out"] is False and lines(r["stdout"]) == ["done"],
           f"cmd set /p: timed_out {r['timed_out']!r}, code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")
    marker = "alcove-e2e-v1-stdin"
    run.markers.append(marker)
    a.send({"t": "exec", "cmd": f"'{marker}' | Out-Null; {read_line}"})
    r = a.v1("exec.result", 10)
    expect(lines(r.get("out", "")) == ["null=True"] and r.get("code") == 0, f"v1 exec ReadLine returned code {r.get('code')!r}, out {r.get('out')!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11", help="the VM whose config.json holds the agentKey")
    ap.add_argument("--agent-port", type=int, default=7646)
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}

    try:
        key = agent_key(args.vm)
    except AgentKeyError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    try:
        a = Agent(args.agent_port, key)
    except (OSError, Failure) as e:
        print(f"FAIL 0: cannot talk to the agent on port {args.agent_port}: {e}; run scripts/test/install-agent.py")
        sys.exit(1)
    caps = a.hello.get("caps", [])
    if a.hello.get("proto") != 2 or any(c not in caps for c in ("rpc", "jobs", "proc", "fs")):
        print(f"FAIL 0: the agent reports proto {a.hello.get('proto')!r} and caps {caps!r}; run scripts/test/install-agent.py")
        sys.exit(1)

    run = Run(a, key)
    try:
        run.home = a.call("fs.stat", path="~")["path"]
        run.user = ntpath.basename(run.home)
        existing = a.call("fs.stat", path=ntpath.dirname(BASE))["exists"]
    except (Failure, OSError, ValueError, KeyError, TypeError) as e:
        print(f"FAIL 0: the guest could not be probed ({e}); run scripts/test/install-agent.py and run this script again")
        sys.exit(1)
    if existing:
        print(f"FAIL 0: the guest already holds the folder {ntpath.dirname(BASE)}; remove it and run this script again")
        sys.exit(1)
    stop_signal_handlers()
    failed = None
    interrupted = False
    try:
        for n, title, fn in CHECKS:
            if only and n not in only:
                continue
            try:
                note = fn(a, run)
            except Failure as e:
                failed = f"FAIL {n}: {e}"
                break
            except (KeyError, TypeError) as e:
                failed = f"FAIL {n}: a reply lacks an expected field ({type(e).__name__}: {e})"
                break
            except (OSError, ValueError) as e:
                failed = f"FAIL {n}: the connection to the agent broke ({type(e).__name__}: {e})"
                break
            print(f"PASS {n} {title}" + (f" ({note})" if note else ""), flush=True)
    except (KeyboardInterrupt, SystemExit):
        interrupted = True
        raise
    finally:
        ignore_stop_signals()
        if interrupted:
            print("interrupted; cleaning up...", flush=True)
        run.cleanup(args.agent_port)
    if failed:
        print(failed)
        sys.exit(1)


if __name__ == "__main__":
    main()
