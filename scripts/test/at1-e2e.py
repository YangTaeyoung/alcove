#!/usr/bin/env python3
"""End-to-end run of the shell, process and file operations against a running
Windows VM: control socket -> guest agent -> guest, and MCP server -> control
socket (docs/control-protocol.md, mcp/).

Needs the VM running with the agent installed with --allow-exec
(scripts/test/install-agent.py), a control server built from this tree and
`npm run build` in mcp/. Each check prints `PASS <n> <title>`; the first
failing check prints `FAIL <n>: <reason>` and the script exits 1. Guest files
go under C:\\alcove-e2e (in, ctl, mcp), host files under a temporary directory.
The run refuses to start when C:\\alcove-e2e or a PING.EXE process exists in the guest.
However the run ends, a second connection kills the jobs the script started,
deletes the guest directories, and the host directory is removed. SIGTERM,
SIGHUP and SIGINT print `interrupted; cleaning up...`, run the same cleanup and
exit with 128 plus the signal's number (143, 129, 130); SIGHUP stays ignored
when the script was started with it ignored (nohup).

Usage: at1-e2e.py [--vm NAME] [--only N[,N...]]
"""
import argparse, hashlib, os, re, shutil, signal, sys, tempfile, time, unicodedata

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout, ignore_stop_signals, stop_signal_handlers
from mcp_stdio import MCP, MCPError

GUEST = r"C:\alcove-e2e"
G_IN = GUEST + r"\in"
G_CTL = GUEST + r"\ctl"
G_MCP = GUEST + r"\mcp"
MIB = 1 << 20
WINDOW_CHECK = (
    "Add-Type -Namespace AlcoveE2E -Name Win -MemberDefinition '"
    '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); '
    '[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);'
    "'; $h = [AlcoveE2E.Win]::GetConsoleWindow(); "
    '"console=$h visible=$([AlcoveE2E.Win]::IsWindowVisible($h))"'
)
LINE_FILTER = "while ($null -ne ($l = [Console]::In.ReadLine())) { \"got:$l\" }"


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for piece in iter(lambda: f.read(MIB), b""):
            h.update(piece)
    return h.hexdigest()


class Run:
    """The control connection, the VM name and what the checks created."""

    def __init__(self, client, vm):
        self.c = client
        self.vm = vm
        self.jobs = []
        self.hostname = ""
        self.user = ""
        self.cleanup_failed = False
        self.host = tempfile.mkdtemp(prefix="alcove-e2e-")
        self.mcps = []

    def call(self, op, reply_timeout=120, **params):
        return self.c.call(op, reply_timeout, name=self.vm, **params)

    def send(self, op, **params):
        return self.c.send(op, name=self.vm, **params)

    def refusal(self, op, **params):
        """The error message of an operation that must fail."""
        try:
            reply = self.call(op, **params)
        except ControlTimeout:
            raise
        except ControlError as e:
            return str(e)
        raise Failure(f"{op} {params!r} succeeded with {reply!r}; it must fail")

    def exec(self, command, timeout=60, **params):
        return self.call("vm.exec", timeout + 30, command=command, timeout=timeout, **params)

    def start(self, command, **params):
        r = self.call("vm.exec.start", command=command, **params)
        self.jobs.append(r["job"])
        return r["job"], r["pid"]

    def start_ping(self):
        """Starts an endless ping as a job; cleanup kills the job's process tree."""
        expect(self.pings() == [], "PING.EXE runs already in the guest; stop it before this check")
        return self.start("ping -t 127.0.0.1")

    def pings(self):
        return self.call("vm.process.list", filter="PING")["processes"]

    def read_until(self, job, done, timeout=30):
        """Polls vm.exec.read with advancing offsets until done(out, err, last reply); returns them and the replies."""
        out = err = ""
        out_off = err_off = 0
        replies = []
        end = time.time() + timeout
        while True:
            r = self.call("vm.exec.read", job=job, outOffset=out_off, errOffset=err_off)
            expect(not r["dropped"], f"vm.exec.read of job {job} dropped output")
            out, err = out + r["out"], err + r["err"]
            out_off, err_off = r["outNext"], r["errNext"]
            replies.append(r)
            if done(out, err, r):
                return out, err, replies
            expect(time.time() < end, f"job {job} did not get there within {timeout} s: state {r['state']}, out {out!r}, err {err!r}")
            time.sleep(0.2)

    def host_dir(self, name):
        path = os.path.join(self.host, name)
        os.makedirs(path)
        return path

    def mcp(self, toolsets=None):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        if toolsets:
            env["ALCOVE_MCP_TOOLSETS"] = toolsets
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at1-e2e")
        return m

    def cleanup(self):
        previous = ignore_stop_signals()
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
        try:
            self.c.close()
        except Exception:
            pass
        try:
            with Client(self.c.socket_path, spawn=False) as c:
                steps = [("vm.exec.kill", {"job": j}) for j in self.jobs]
                steps += [("vm.fs.delete", {"path": p, "recursive": True}) for p in (G_IN, G_CTL, G_MCP)]
                steps.append(("vm.fs.delete", {"path": GUEST}))
                for op, params in steps:
                    try:
                        c.call(op, 60, name=self.vm, **params)
                    except ControlError:
                        pass
        except ControlError as e:
            self.cleanup_failed = True
            print(f"cleanup failed: cannot reach the control server ({e}); kill the jobs {self.jobs!r} and delete {GUEST} in the guest by hand")
        shutil.rmtree(self.host, ignore_errors=True)


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


@check("vm.status reports the guest tools with rpc, jobs, proc and fs")
def _(run):
    s = run.call("vm.status")
    expect(s.get("tools") is True, f"tools is {s.get('tools')!r}; run scripts/test/install-agent.py")
    missing = {"rpc", "jobs", "proc", "fs"} - set(s.get("agentCaps", []))
    expect(not missing, f"agentCaps {s.get('agentCaps')!r} lacks {sorted(missing)}; run scripts/test/install-agent.py")


@check("vm.exec returns UTF-8 stdout, stderr and the exit code")
def _(run):
    r = run.exec("Write-Output '한글 ok'; [Console]::Error.WriteLine('to-err'); exit 5")
    expect("한글 ok" in r["stdout"], f"stdout is {r['stdout']!r}")
    expect("to-err" in r["stderr"], f"stderr is {r['stderr']!r}")
    expect(r["code"] == 5, f"code is {r['code']!r}")
    expect(r["output"] == r["stdout"] + r["stderr"], f"output is {r['output']!r}")
    expect(r["timedOut"] is False and r["truncated"] is False, f"timedOut {r['timedOut']!r}, truncated {r['truncated']!r}")

    r = run.exec("$z = [string]::new([char]0, 200000); [Console]::Out.Write($z); [Console]::Error.Write($z)")
    expect(r["stdout"] == "\0" * 200000 and r["stderr"] == "\0" * 200000 and r["truncated"] is False,
           f"200000 NUL characters per stream: stdout {len(r['stdout'])}, stderr {len(r['stderr'])}, truncated {r['truncated']!r}")
    r = run.exec("[Console]::Out.Write('head' + [string]::new([char]60, 250000) + 'tail')")
    expect(r["stdout"] == "<" * 199996 + "tail" and r["truncated"] is True and r["code"] == 0,
           f"250008 characters on stdout: {len(r['stdout'])} kept, ends {r['stdout'][-8:]!r}, truncated {r['truncated']!r}")


@check("vm.exec applies cwd, env and stdin; a timeout kills the process tree")
def _(run):
    r = run.exec("(Get-Location).Path; $env:ALCOVE_E2E; [Console]::In.ReadLine()", cwd="C:\\Windows",
                 env={"ALCOVE_E2E": "yes 값"}, stdin="표준 입력\n")
    expect(lines(r["stdout"]) == ["C:\\Windows", "yes 값", "표준 입력"] and r["code"] == 0,
           f"code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")
    r = run.exec("echo %CD%&echo %ALCOVE_E2E%", shell="cmd", cwd="C:\\Windows", env={"ALCOVE_E2E": "from-cmd"})
    expect(lines(r["stdout"]) == ["C:\\Windows", "from-cmd"], f"shell cmd: stdout {r['stdout']!r}, stderr {r['stderr']!r}")
    r = run.call("vm.exec", argv=["C:\\Windows\\System32\\whoami.exe"], shell="none", timeout=30)
    expect([l.lower() for l in lines(r["stdout"])] == [f"{run.hostname}\\{run.user}".lower()] and r["code"] == 0, f"argv: code {r['code']!r}, stdout {r['stdout']!r}")
    expect(run.pings() == [], "PING.EXE runs already in the guest; stop it before this check")
    began = time.monotonic()
    r = run.call("vm.exec", 15, command="ping -n 60 127.0.0.1", timeout=3)
    took = time.monotonic() - began
    expect(r["timedOut"] is True, f"timedOut is {r['timedOut']!r} after {took:.1f} s, code {r['code']!r}")
    expect(2.5 <= took < 15, f"the timed-out command answered after {took:.1f} s")
    expect("Pinging 127.0.0.1" in r["stdout"], f"the output before the timeout is {r['stdout']!r}")
    left = run.pings()
    expect(left == [], f"ping survived the timeout: {left!r}")


@check("vm.exec shows no console window")
def _(run):
    r = run.exec(WINDOW_CHECK)
    expect(r["code"] == 0 and "visible=False" in r["stdout"], f"code {r['code']!r}, stdout {r['stdout']!r}, stderr {r['stderr']!r}")
    return r["stdout"].strip()


@check("shell and file operations answer while a command runs; other operations answer in request order")
def _(run):
    c = run.c
    began = time.monotonic()
    sleep_id = run.send("vm.exec", command="Start-Sleep 8", timeout=60)
    shot_id = run.send("vm.screenshot", maxWidth=320)
    host_id = run.send("vm.exec", command="hostname", timeout=60)
    for what, rid in (("vm.screenshot", shot_id), ("the second vm.exec", host_id)):
        try:
            r = c.wait(rid, max(0.0, began + 4 - time.monotonic()))
        except ControlTimeout:
            raise Failure(f"{what} did not answer within 4 s of a running vm.exec") from None
        expect(r.get("ok") is True, f"{what} failed: {r.get('error')}")
        if rid == host_id:
            expect(lines(r["stdout"]) == [run.hostname], f"hostname printed {r['stdout']!r}")
        else:
            expect(r.get("png"), "vm.screenshot returned no image")
    fast = max(c.arrival(shot_id)[1], c.arrival(host_id)[1]) - began
    r = c.wait(sleep_id, 30)
    slow = c.arrival(sleep_id)[1] - began
    expect(r.get("ok") is True and r["code"] == 0, f"Start-Sleep 8 failed: {r!r}")
    expect(slow >= 7, f"Start-Sleep 8 answered after {slow:.1f} s")

    move_id = run.send("vm.mouse.move", x=640, y=400)
    shot_id = run.send("vm.screenshot", maxWidth=320)
    hello_id = c.send("hello")
    replies = {rid: c.wait(rid, 30) for rid in (move_id, shot_id, hello_id)}
    for rid, what in ((move_id, "vm.mouse.move"), (shot_id, "vm.screenshot"), (hello_id, "hello")):
        expect(replies[rid].get("ok") is True, f"{what} failed: {replies[rid].get('error')}")
    order = [c.arrival(rid)[0] for rid in (move_id, shot_id, hello_id)]
    expect(order == sorted(order), f"vm.mouse.move, vm.screenshot and hello answered in positions {order}")
    return f"screenshot and second exec within {fast:.1f} s, sleep after {slow:.1f} s"


@check("vm.sync_dir, vm.pull_file, vm.push_file and vm.fs.* move and edit files")
def _(run):
    tree = run.host_dir("tree")
    names = ["a.txt", "sub dir/b.bin", "한글 파일.txt"]
    os.makedirs(os.path.join(tree, "sub dir"))
    with open(os.path.join(tree, "a.txt"), "w", encoding="utf-8") as f:
        f.write("first version\n")
    with open(os.path.join(tree, "sub dir", "b.bin"), "wb") as f:
        f.write(os.urandom(3 * MIB))
    decomposed = unicodedata.normalize("NFD", "한글 파일.txt")
    with open(os.path.join(tree, decomposed), "w", encoding="utf-8") as f:
        f.write("한글 내용\n")
    expect(decomposed in os.listdir(tree) and decomposed != "한글 파일.txt", f"the host stores the name as {os.listdir(tree)!r}")
    total = sum(os.path.getsize(os.path.join(tree, n)) for n in names)

    r = run.call("vm.sync_dir", 300, path=tree, guestPath=G_IN)
    expect(sorted(r["sent"]) == sorted(names) and r["skipped"] == 0 and r["deleted"] == [] and r["bytes"] == total,
           f"first sync: {r!r}")

    pulled = run.host_dir("pulled")
    for i, n in enumerate(names):
        dest = os.path.join(pulled, f"{i}.out")
        r = run.call("vm.pull_file", 300, guestPath=G_IN + "\\" + n.replace("/", "\\"), path=dest)
        want = sha256(os.path.join(tree, n))
        expect(r["sha256"] == want and sha256(dest) == want and r["bytes"] == os.path.getsize(dest) and r["path"] == dest,
               f"pull of {n}: reply {r!r}, file digest {sha256(dest)}, source digest {want}")
        expect(not os.path.exists(dest + ".alcove-part"), f"pull of {n} left {dest}.alcove-part")

    with open(os.path.join(tree, "a.txt"), "w", encoding="utf-8") as f:
        f.write("second version, longer\n")
    r = run.call("vm.sync_dir", 300, path=tree, guestPath=G_IN)
    expect(r["sent"] == ["a.txt"] and r["skipped"] == 2 and r["deleted"] == [], f"second sync: {r!r}")
    r = run.call("vm.fs.read", path=G_IN + r"\a.txt")
    expect(r["text"] == "second version, longer\n", f"a.txt in the guest after the second sync: {r['text']!r}")

    run.call("vm.fs.write", path=G_IN + r"\sub dir\extra.txt", text="not on the host\n")
    r = run.call("vm.sync_dir", 300, path=tree, guestPath=G_IN)
    expect(r["sent"] == [] and r["skipped"] == 3 and r["deleted"] == [], f"sync without delete: {r!r}")
    r = run.call("vm.sync_dir", 300, path=tree, guestPath=G_IN, delete=True)
    expect(r["sent"] == [] and r["skipped"] == 3 and r["deleted"] == ["sub dir/extra.txt"], f"sync with delete: {r!r}")

    r = run.call("vm.fs.list", path=G_IN, recursive=True)
    listed = {e["name"]: e for e in r["entries"]}
    expect(sorted(listed) == sorted(names + ["sub dir"]) and r["truncated"] is False, f"recursive list: {r!r}")
    expect(listed["sub dir"]["dir"] is True and listed["sub dir/b.bin"]["size"] == 3 * MIB and listed["a.txt"]["dir"] is False,
           f"recursive list entries: {r['entries']!r}")
    expect(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", listed["a.txt"]["mtime"]), f"mtime is {listed['a.txt']['mtime']!r}")
    r = run.call("vm.fs.list", path=G_IN)
    expect(sorted(e["name"] for e in r["entries"]) == sorted(["a.txt", "sub dir", "한글 파일.txt"]), f"flat list: {r!r}")

    source = os.path.join(tree, "a.txt")
    target = G_CTL + r"\pushed 한글.txt"
    r = run.call("vm.push_file", 300, path=source, guestPath=target)
    expect(r["guestPath"] == target and r["bytes"] == os.path.getsize(source) and r["sha256"] == sha256(source), f"push: {r!r}")
    with open(source, "w", encoding="utf-8") as f:
        f.write("third version\n")
    message = run.refusal("vm.push_file", path=source, guestPath=target)
    expect("exists" in message, f"a second push without overwrite failed with {message!r}")
    r = run.call("vm.fs.read", path=target)
    expect(r["text"] == "second version, longer\n", f"the refused push changed the file to {r['text']!r}")
    r = run.call("vm.push_file", 300, path=source, guestPath=target, overwrite=True)
    expect(r["sha256"] == sha256(source), f"push with overwrite: {r!r}")
    r = run.call("vm.fs.read", path=target)
    expect(r["text"] == "third version\n", f"after the push with overwrite the file reads {r['text']!r}")
    r = run.call("vm.fs.list", path=G_CTL)
    expect([e["name"] for e in r["entries"]] == ["pushed 한글.txt"], f"the push left other files: {r!r}")

    notes = G_CTL + r"\notes\log.txt"
    body = "".join(f"줄 {i}\n" for i in range(1, 6))
    r = run.call("vm.fs.write", path=notes, text=body)
    expect(r["size"] == len(body.encode()), f"write: {r!r}")
    r = run.call("vm.fs.read", path=notes)
    expect(r["text"] == body and r["size"] == len(body.encode()) and r["eof"] is True, f"read: {r!r}")
    r = run.call("vm.fs.write", path=notes, text="줄 6\n", append=True)
    expect(r["size"] == len((body + "줄 6\n").encode()), f"append: {r!r}")
    r = run.call("vm.fs.read", path=notes)
    expect(r["text"] == body + "줄 6\n", f"read after append: {r!r}")
    r = run.call("vm.fs.read", path=notes, tail=2)
    expect(r["text"] == "줄 5\n줄 6\n" and r["eof"] is True, f"tail: {r!r}")
    r = run.call("vm.fs.read", path=notes, offset=len("줄 1\n".encode()), length=len("줄 2".encode()))
    expect(r["text"] == "줄 2" and r["eof"] is False, f"read with offset and length: {r!r}")
    r = run.call("vm.fs.write", path=notes, text="replaced\n")
    expect(r["size"] == 9, f"replacing write: {r!r}")

    utf16 = G_CTL + r"\utf16.txt"
    r = run.exec(f"'유니코드 한글 text' | Out-File -Encoding Unicode '{utf16}'")
    expect(r["code"] == 0, f"Out-File failed: {r['stderr']!r}")
    r = run.call("vm.fs.read", path=utf16)
    expect(r["text"] == "유니코드 한글 text\r\n" and r["size"] == 2 + 2 * len("유니코드 한글 text\r\n"), f"UTF-16LE read: {r!r}")

    redirected = G_CTL + r"\redirected.log"
    r = run.exec(f"1..5 | % {{ \"로그 줄 $_\" }} > '{redirected}'")
    expect(r["code"] == 0, f"the redirection failed: {r['stderr']!r}")
    logged = "".join(f"로그 줄 {i}\r\n" for i in range(1, 6))
    r = run.call("vm.fs.read", path=redirected)
    expect(r["text"] == logged and r["size"] == 2 + 2 * len(logged), f"read of a file PowerShell redirected into: {r!r}")
    r = run.call("vm.fs.read", path=redirected, tail=2)
    expect(r["text"] == "로그 줄 4\r\n로그 줄 5\r\n", f"tail of a file PowerShell redirected into: {r!r}")
    r = run.call("vm.fs.read", path=redirected, offset=2 + 2 * len("로그 줄 1\r\n"), length=2 * len("로그 줄 2"))
    expect(r["text"] == "로그 줄 2" and r["eof"] is False, f"read inside a file PowerShell redirected into: {r!r}")

    for path in (G_IN, G_CTL):
        message = run.refusal("vm.fs.delete", path=path)
        expect("recursive" in message, f"deleting the non-empty {path} without recursive failed with {message!r}")
        r = run.call("vm.fs.delete", path=path, recursive=True)
        expect(r["deleted"] is True, f"delete of {path}: {r!r}")
        r = run.call("vm.fs.delete", path=path, recursive=True)
        expect(r["deleted"] is False, f"second delete of {path}: {r!r}")
        message = run.refusal("vm.fs.list", path=path)
        expect("does not exist" in message, f"listing the deleted {path} failed with {message!r}")


@check("background jobs stream output, read input, are listed and killed; processes are listed and killed")
def _(run):
    job, pid = run.start("1..6 | % { $_; Start-Sleep -Milliseconds 500 }")
    out, err, replies = run.read_until(job, lambda o, e, r: r["state"] == "exited")
    expect(lines(out) == ["1", "2", "3", "4", "5", "6"], f"job output: {out!r}, stderr {err!r}")
    expect(replies[-1]["code"] == 0 and replies[-1]["pid"] == pid, f"last read: {replies[-1]!r}")
    partial = [r for r in replies if r["state"] == "running" and r["outNext"] > 0]
    expect(partial, "no vm.exec.read returned output while the job was running")
    expect("code" not in partial[0], f"a running job reports a code: {partial[0]!r}")
    r = run.call("vm.exec.read", job=job, outOffset=replies[-1]["outNext"], errOffset=replies[-1]["errNext"])
    expect(r["out"] == "" and r["outNext"] == replies[-1]["outNext"], f"a read at the end returned {r!r}")
    r = run.call("vm.exec.read", job=job, max=4)
    expect(len(r["out"].encode()) == 4 and r["outNext"] == 4, f"a read with max 4 returned {r!r}")

    filt, _pid = run.start(LINE_FILTER)
    run.call("vm.exec.write", job=filt, data="한글 줄\n")
    out, _, replies = run.read_until(filt, lambda o, e, r: "\n" in o)
    expect(lines(out) == ["got:한글 줄"] and replies[-1]["state"] == "running", f"job input: out {out!r}, state {replies[-1]['state']}")
    run.call("vm.exec.write", job=filt, data="last\n", eof=True)
    out, err, replies = run.read_until(filt, lambda o, e, r: r["state"] == "exited")
    expect(replies[-1]["code"] == 0, f"the line filter exited with {replies[-1]['code']!r}, stderr {err!r}")
    message = run.refusal("vm.exec.write", job=filt, data="late\n")
    expect("exec.start" in message, f"writing to an exited job failed with {message!r}")

    ping, _pid = run.start_ping()
    out, _, _ = run.read_until(ping, lambda o, e, r: "Reply from 127.0.0.1" in o)
    listed = {j["job"]: j for j in run.call("vm.exec.list")["jobs"]}
    expect(listed[job]["state"] == "exited" and listed[job]["code"] == 0 and listed[ping]["state"] == "running"
           and listed[ping]["cmd"] == "ping -t 127.0.0.1", f"vm.exec.list: {listed!r}")
    r = run.call("vm.exec.kill", job=ping)
    expect(r["state"] == "exited", f"vm.exec.kill: {r!r}")
    left = run.pings()
    expect(left == [], f"ping survived vm.exec.kill: {left!r}")
    r = run.call("vm.exec.read", job=ping, outOffset=10**9)
    expect(r["state"] == "exited", f"the killed job reads as {r!r}")

    ping, _pid = run.start_ping()
    run.read_until(ping, lambda o, e, r: "Reply from 127.0.0.1" in o)
    procs = run.pings()
    expect(len(procs) == 1 and procs[0]["name"].upper() == "PING.EXE" and procs[0]["pid"] > 0 and procs[0]["ppid"] > 0
           and "127.0.0.1" in procs[0]["command"] and procs[0]["memoryKB"] > 0 and procs[0]["path"].lower().endswith("ping.exe"),
           f"vm.process.list filter=PING: {procs!r}")
    r = run.call("vm.process.kill", pid=procs[0]["pid"])
    expect(r["killed"] == 1, f"vm.process.kill by pid: {r!r}")
    expect(run.pings() == [], "ping survived vm.process.kill by pid")
    run.read_until(ping, lambda o, e, r: r["state"] == "exited", 15)

    ping, _pid = run.start_ping()
    run.read_until(ping, lambda o, e, r: "Reply from 127.0.0.1" in o)
    r = run.call("vm.process.kill", processName="PING.EXE", tree=True)
    expect(r["killed"] >= 1, f"vm.process.kill by name: {r!r}")
    expect(run.pings() == [], "ping survived vm.process.kill by name")
    run.read_until(ping, lambda o, e, r: r["state"] == "exited", 15)
    message = run.refusal("vm.process.kill")
    expect("pid" in message and "processName" in message, f"vm.process.kill without a target failed with {message!r}")


def tool(m, name, args, timeout=120):
    """Calls an MCP tool that must succeed and returns its text."""
    is_error, out, _ = m.call(name, args, timeout)
    expect(not is_error, f"{name} returned an error result: {out!r}")
    return out


def changing(m, name, args, timeout=120):
    """Calls an MCP tool that changes the guest and returns its text without the `eventSeq <n>` line, its second line."""
    out = tool(m, name, args, timeout)
    rows = out.split("\n")
    expect(len(rows) >= 2 and re.fullmatch(r"eventSeq \d+", rows[1]), f"{name} has no eventSeq line after its first line: {out!r}")
    return "\n".join(rows[:1] + rows[2:])


def mcp_start(run, m, command):
    """Starts a job through alcove_exec_start, registers it for cleanup and returns its id."""
    out = changing(m, "alcove_exec_start", {"name": run.vm, **command})
    started = re.fullmatch(r"started job (\S+) \(pid (\d+)\)", out)
    expect(started, f"alcove_exec_start: {out!r}")
    run.jobs.append(started.group(1))
    return started.group(1)


def mcp_read_until(run, m, job, done, timeout=30):
    """Polls alcove_exec_read with the offsets it prints until done(all text so far, last text); returns all text."""
    seen, out_off, err_off = "", 0, 0
    end = time.time() + timeout
    while True:
        out = tool(m, "alcove_exec_read", {"name": run.vm, "job": job, "out_offset": out_off, "err_offset": err_off})
        offsets = re.search(r"next offsets: out_offset=(\d+) err_offset=(\d+)", out)
        expect(offsets, f"alcove_exec_read prints no offsets: {out!r}")
        out_off, err_off = int(offsets.group(1)), int(offsets.group(2))
        seen += out + "\n"
        if done(seen, out):
            return seen
        expect(time.time() < end, f"alcove_exec_read of job {job} did not get there within {timeout} s: {seen!r}")
        time.sleep(0.2)


@check("the MCP server runs commands, jobs and file tools; ALCOVE_MCP_TOOLSETS selects toolsets")
def _(run):
    vm = run.vm
    m = run.mcp()
    names = {t["name"] for t in m.request("tools/list")["tools"]}
    driven = {"alcove_exec", "alcove_exec_start", "alcove_exec_read", "alcove_exec_write", "alcove_exec_list", "alcove_exec_kill",
              "alcove_process_list", "alcove_process_kill", "alcove_fs_write", "alcove_fs_read", "alcove_fs_list", "alcove_fs_delete",
              "alcove_sync_dir", "alcove_pull_file", "alcove_push_file"}
    expect(driven <= names, f"the default tool list lacks {sorted(driven - names)}")

    out = changing(m, "alcove_exec", {"name": vm, "command": "(Get-Location).Path; Write-Output '한글 mcp'", "cwd": "C:\\Windows", "timeout_s": 60})
    expect(out.startswith("exit code 0") and "C:\\Windows" in out and "한글 mcp" in out, f"alcove_exec: {out!r}")

    job = mcp_start(run, m, {"command": "'job-out 한글'; Start-Sleep -Milliseconds 300; [Console]::Error.WriteLine('job-err')"})
    seen = mcp_read_until(run, m, job, lambda seen, last: "exited with code 0" in last)
    expect(seen.count("job-out 한글") == 1 and seen.count("job-err") == 1 and "stdout:" in seen and "stderr:" in seen,
           f"alcove_exec_read over all polls: {seen!r}")

    filt = mcp_start(run, m, {"command": LINE_FILTER})
    out = changing(m, "alcove_exec_write", {"name": vm, "job": filt, "data": "한글 줄\n"})
    expect(out == "wrote 5 characters", f"alcove_exec_write: {out!r}")
    seen = mcp_read_until(run, m, filt, lambda seen, last: "got:한글 줄" in seen)
    expect("exited" not in seen, f"the line filter exited before its input ended: {seen!r}")
    out = changing(m, "alcove_exec_write", {"name": vm, "job": filt, "data": "", "eof": True})
    expect(out == "wrote 0 characters and closed stdin", f"alcove_exec_write with eof: {out!r}")
    mcp_read_until(run, m, filt, lambda seen, last: "exited with code 0" in last)

    expect(run.pings() == [], "PING.EXE runs already in the guest; stop it before this check")
    ping = mcp_start(run, m, {"argv": ["C:\\Windows\\System32\\PING.EXE", "-t", "127.0.0.1"], "shell": "none"})
    mcp_read_until(run, m, ping, lambda seen, last: "Reply from 127.0.0.1" in seen)
    out = tool(m, "alcove_exec_list", {"name": vm})
    rows = {l.split(" ", 1)[0]: l for l in out.split("\n")}
    expect("exited (code 0)" in rows.get(job, "") and "running" in rows.get(ping, "") and "PING.EXE -t 127.0.0.1" in rows.get(ping, ""),
           f"alcove_exec_list: {out!r}")
    out = changing(m, "alcove_exec_kill", {"name": vm, "job": ping})
    expect(out == f"job {ping}: exited", f"alcove_exec_kill: {out!r}")
    out = tool(m, "alcove_process_list", {"name": vm, "filter": "PING"})
    expect(out == "no matching processes", f"after alcove_exec_kill, alcove_process_list filter=PING: {out!r}")

    ping = mcp_start(run, m, {"command": "ping -t 127.0.0.1"})
    mcp_read_until(run, m, ping, lambda seen, last: "Reply from 127.0.0.1" in seen)
    out = changing(m, "alcove_process_kill", {"name": vm, "process_name": "PING.EXE", "tree": True})
    killed = re.fullmatch(r"killed (\d+) process\(es\)", out)
    expect(killed and int(killed.group(1)) >= 1, f"alcove_process_kill: {out!r}")
    mcp_read_until(run, m, ping, lambda seen, last: "exited with code" in last)
    expect(run.pings() == [], "ping survived alcove_process_kill")

    note = G_MCP + r"\note 한글.txt"
    first, more = "mcp 한글 note\nsecond\n", "third\n"
    size = len((first + more).encode())
    out = tool(m, "alcove_fs_write", {"name": vm, "path": note, "text": first})
    expect(f"file is now {len(first.encode())} bytes" in out, f"alcove_fs_write: {out!r}")
    out = tool(m, "alcove_fs_write", {"name": vm, "path": note, "text": more, "append": True})
    expect(f"file is now {size} bytes" in out, f"alcove_fs_write append: {out!r}")
    out = tool(m, "alcove_fs_read", {"name": vm, "path": note})
    expect(out == f"{size} bytes, end of file\n{first}{more}", f"alcove_fs_read: {out!r}")
    out = tool(m, "alcove_fs_read", {"name": vm, "path": note, "tail": 1})
    expect(out.endswith("\nthird\n") and "second" not in out, f"alcove_fs_read tail: {out!r}")

    tree = run.host_dir("mcp-tree")
    os.makedirs(os.path.join(tree, "sub"))
    for rel, body in (("a.txt", "mcp a\n"), ("sub/한글.txt", "mcp 한글\n")):
        with open(os.path.join(tree, rel), "w", encoding="utf-8") as f:
            f.write(body)
    out = tool(m, "alcove_sync_dir", {"name": vm, "path": tree, "guest_path": G_MCP + r"\sync"}, 300)
    expect(out.startswith("sent 2 file(s), skipped 0 unchanged, deleted 0") and "  a.txt" in out and "  sub/한글.txt" in out,
           f"alcove_sync_dir: {out!r}")
    out = tool(m, "alcove_sync_dir", {"name": vm, "path": tree, "guest_path": G_MCP + r"\sync", "delete": True}, 300)
    expect(out.startswith("sent 0 file(s), skipped 2 unchanged, deleted 0"), f"second alcove_sync_dir: {out!r}")

    out = tool(m, "alcove_fs_list", {"name": vm, "path": G_MCP, "recursive": True})
    listed = [l.split(" ", 3) for l in out.split("\n")]
    expect(sorted(l[3] for l in listed) == sorted(["note 한글.txt", "sync", "sync/a.txt", "sync/sub", "sync/sub/한글.txt"]),
           f"alcove_fs_list: {out!r}")
    expect(["d", "0"] in [l[:2] for l in listed] and ["-", str(size)] in [l[:2] for l in listed], f"alcove_fs_list columns: {out!r}")

    dest = os.path.join(run.host_dir("mcp-pulled"), "한글.txt")
    out = tool(m, "alcove_pull_file", {"name": vm, "guest_path": G_MCP + r"\sync\sub\한글.txt", "path": dest}, 300)
    want = sha256(os.path.join(tree, "sub", "한글.txt"))
    expect(out == f"copied to {dest} ({os.path.getsize(dest)} bytes, sha256 {want})" and sha256(dest) == want, f"alcove_pull_file: {out!r}")

    out = tool(m, "alcove_process_list", {"name": vm, "filter": "alcove-agent"})
    expect("alcove-agent.exe" in out and "--allow-exec" in out and " KB" in out, f"alcove_process_list: {out!r}")

    pushed = G_MCP + r"\pushed.txt"
    source = os.path.join(tree, "a.txt")
    out = tool(m, "alcove_push_file", {"name": vm, "path": source, "guest_path": pushed}, 300)
    expect(out == f"copied to {pushed} ({os.path.getsize(source)} bytes, sha256 {sha256(source)})", f"alcove_push_file: {out!r}")
    is_error, out, _ = m.call("alcove_push_file", {"name": vm, "path": source, "guest_path": pushed}, 300)
    expect(is_error and "exists" in out and "overwrite" in out, f"second alcove_push_file: isError {is_error!r}, {out!r}")
    out = tool(m, "alcove_push_file", {"name": vm, "path": source, "guest_path": pushed, "overwrite": True}, 300)
    expect(out.startswith(f"copied to {pushed} "), f"alcove_push_file with overwrite: {out!r}")

    out = tool(m, "alcove_fs_delete", {"name": vm, "path": G_MCP, "recursive": True})
    expect(out == f"deleted {G_MCP}", f"alcove_fs_delete: {out!r}")
    out = tool(m, "alcove_fs_delete", {"name": vm, "path": G_MCP, "recursive": True})
    expect(out == f"{G_MCP} did not exist", f"second alcove_fs_delete: {out!r}")
    is_error, out, _ = m.call("alcove_fs_list", {"name": vm, "path": G_MCP})
    expect(is_error and G_MCP in out and "does not exist" in out, f"alcove_fs_list of the deleted folder: isError {is_error!r}, {out!r}")
    m.close()

    core = run.mcp("core")
    names = {t["name"] for t in core.request("tools/list")["tools"]}
    expect("alcove_exec" in names and "alcove_fs_list" not in names and "alcove_exec_start" not in names,
           f"with ALCOVE_MCP_TOOLSETS=core the server lists {sorted(names)}")
    core.close()
    return f"{len(driven)} driven tools in the default list; core lists alcove_exec without alcove_fs_list and alcove_exec_start"


@check("refusals say what was wrong")
def _(run):
    seen = []
    message = run.refusal("vm.exec", command="hostname", timeout=0)
    expect(message == "timeout must be between 1 and 86400 seconds", f"vm.exec with timeout 0 failed with {message!r}")
    seen.append(message)

    missing = GUEST + r"\no such file.txt"
    message = run.refusal("vm.fs.read", path=missing)
    expect(missing in message and "does not exist" in message, f"vm.fs.read of a missing file failed with {message!r}")
    seen.append(message)

    message = run.refusal("vm.exec.read", job="j999999")
    expect("j999999" in message and "exec.list" in message, f"vm.exec.read of an unknown job failed with {message!r}")
    seen.append(message)

    run.call("vm.fs.write", path=G_CTL + r"\small.txt", text="x\n")
    nowhere = os.path.join(run.host, "no such folder")
    message = run.refusal("vm.pull_file", guestPath=G_CTL + r"\small.txt", path=os.path.join(nowhere, "small.txt"))
    expect(nowhere in message and "folder" in message, f"vm.pull_file into a missing host folder failed with {message!r}")
    expect(not os.path.exists(nowhere), f"the refused pull created {nowhere}")
    seen.append(message)

    absent = os.path.join(run.host, "no such source folder")
    message = run.refusal("vm.sync_dir", path=absent, guestPath=G_CTL + r"\sync-refused")
    expect(absent in message, f"vm.sync_dir of a missing host folder failed with {message!r}")
    seen.append(message)

    count = "[Console]::In.ReadToEnd().Length"
    r = run.exec(count, stdin="x" * 1040000)
    expect(lines(r["stdout"]) == ["1040000"], f"a command given 1040000 characters of stdin counted {r['stdout']!r}, stderr {r['stderr']!r}")
    message = run.refusal("vm.exec", command=count, stdin="x" * 1100000, timeout=60)
    expect("1 MiB" in message and "file" in message, f"vm.exec with 1100000 characters of stdin failed with {message!r}")
    seen.append(message)
    began = time.monotonic()
    r = run.exec("hostname")
    expect(lines(r["stdout"]) == [run.hostname] and time.monotonic() - began < 5,
           f"after the refused request vm.exec printed {r['stdout']!r} in {time.monotonic() - began:.1f} s")
    return " | ".join(seen)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}

    try:
        client = Client()
        status = client.call("vm.status", 60, name=args.vm)
    except ControlError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    if status.get("state") != "running":
        print(f"FAIL 0: VM '{args.vm}' is {status.get('state')}; start it with scripts/test/ctl.py vm.start and run this script again")
        sys.exit(1)

    run = Run(client, args.vm)
    try:
        probe = run.exec("hostname; $env:USERNAME; (Test-Path -LiteralPath '" + GUEST + "'); @(Get-Process -Name PING -ErrorAction SilentlyContinue).Count")
        names = lines(probe["stdout"])
        run.hostname, run.user, folder_exists, ping_count = (names + ["", "", "", ""])[:4]
        found = ([f"the folder {GUEST}"] if folder_exists == "True" else []) + (["a PING.EXE process"] if ping_count not in ("", "0") else [])
    except (ControlError, KeyError) as e:
        print(f"FAIL 0: the guest could not be probed ({e}); check the guest shell with vm.doctor and run this script again")
        shutil.rmtree(run.host, ignore_errors=True)
        sys.exit(1)
    if found:
        print(f"FAIL 0: the guest already holds {' and '.join(found)}; remove it and run this script again")
        shutil.rmtree(run.host, ignore_errors=True)
        sys.exit(1)
    stop_signal_handlers()
    failed = None
    interrupted = False
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
                break
            print(f"PASS {n} {title}" + (f" ({note})" if note else ""), flush=True)
    except (KeyboardInterrupt, SystemExit):
        interrupted = True
        raise
    finally:
        ignore_stop_signals()
        if interrupted:
            print("interrupted; cleaning up...", flush=True)
        try:
            run.cleanup()
        except Exception as e:
            run.cleanup_failed = True
            print(f"cleanup failed: {type(e).__name__}: {e}")
        if interrupted and run.cleanup_failed:
            sys.exit(1)
    if failed:
        print(failed)
        sys.exit(1)
    if run.cleanup_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
