#!/usr/bin/env python3
"""End-to-end run of replay against a running Windows VM: a recording of the
fixture scenario saved with script.save, alcovectl run-script through the
control server and with --in-process, its exit statuses, failure screenshot,
secret variables and signals, alcove_script_run through the MCP server, and the
refusal of a second Alcove host (docs/control-protocol.md "Scripts", mcp/).

Needs the VM running with the agent installed as the scheduled task
AlcoveAgent with --allow-exec (scripts/test/install-agent.py), a control
server built from this tree (alcovectl serve, not the app: checks 10 to 13
read the engine's parent process), the alcovectl build in
AlcoveKit/.build-ctl (or ALCOVE_CTL), `npm run build` in mcp/ and the fixture
build build/alcove-fixture-windows-arm64.exe (scripts/test/all.sh). The guest
must hold no C:\\alcove-e2e and no C:\\alcove-apps\\alcove-e2e-app, run no
fixture and show no window of the fixture, and the VM must not be recording;
the script refuses to start otherwise.

Each check prints `PASS <n> <title>`, or `SKIP <n> <title>: <reason>` when
the host cannot provide what it needs; the first failing check prints
`FAIL <n>: <reason>` and the script exits 1. A run without a failure ends with
`<p> passed, <s> skipped` and the numbers of the skipped checks.

Check 1 takes the snapshot at6-base only when the data volume has at least
18 GiB free; without it check 3 starts each run from a new fixture process and
check 7 is skipped. Checks 11 to 13 stop the VM through the control server,
start and stop it through alcovectl run-script --in-process, kill a second
alcovectl serve that started it, and start it again through the control
server. Every VM start needs 10 GiB free on the data volume.

However the run ends, the cleanup ends the run-script and alcovectl serve
processes the run started, starts the VM through the control server when the
run left it stopped, stops the recording of the run, ends the processes that
run from the two guest folders, puts the clipboard text back, deletes the
snapshot at6-base when the run took it, deletes the two folders and the host
directory of the run. When a
step of that cannot finish, the script prints `cleanup failed: ...` with what
to do by hand and exits 1. SIGTERM, SIGHUP and SIGINT print
`interrupted; restoring the guest...`, run the same cleanup and exit with 128
plus the signal's number (143, 129, 130); SIGHUP stays ignored when the script
was started with it ignored (nohup).

Usage: at6-e2e.py [--vm NAME] [--only N[,N...]]
"""
import argparse, json, os, shutil, signal, socket, subprocess, sys, tempfile, time

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout
from mcp_stdio import MCP, MCPError

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURE_BUILD = os.path.join(ROOT, "build", "alcove-fixture-windows-arm64.exe")
CTL = os.environ.get("ALCOVE_CTL") or os.path.join(ROOT, "AlcoveKit", ".build-ctl", "debug", "alcovectl")
VM_DIR = os.environ.get("ALCOVE_VM_DIR") or os.path.expanduser("~/Library/Application Support/Alcove/VMs")
DATA_VOLUME = "/System/Volumes/Data"
GUEST = r"C:\alcove-e2e"
APPS = r"C:\alcove-apps"
APP_NAME = "alcove-e2e-app"
APP_DIR = APPS + "\\" + APP_NAME
EXE = "alcove-fixture.exe"
APP_EXE = APP_DIR + "\\" + EXE
FIXTURE_LOG = GUEST + r"\fixture.log"
AFTER_SIGNAL = GUEST + r"\after-signal.txt"
TITLE = "Alcove Fixture"
MESSAGE = 'replay "테스트" 1'
SECRET = "Pw-at6-Replay-77"
SNAPSHOT = "at6-base"
SNAPSHOT_FREE_GIB = 18
START_FREE_GIB = 10
MOVE = (150, 90)
MISSING = "Sned"
NOTHING = "No Such Element 4711"
SIGNAL_WAIT_S = 15
BOOT_TEXT = "Search"
BOOT_READY = r"C:\Windows\win.ini"
TRANSCRIPT = {"window": TITLE, "role": "Document", "name": "Transcript"}
STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
EXIT_FOR = {signal.SIGINT: 130, signal.SIGTERM: 143, signal.SIGHUP: 129}
KERNEL_POWER = ("@(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; "
                "StartTime=[DateTime]::Parse('SINCE').ToUniversalTime()} -ErrorAction SilentlyContinue).Count")
GUEST_NOW = "[DateTime]::UtcNow.ToString('o')"
BOOTED_AT = "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')"


class Failure(Exception):
    pass


class Skipped(Exception):
    """Raised by a check that cannot run on this host; its text is the reason."""


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


def free_gib():
    s = os.statvfs(DATA_VOLUME)
    return s.f_bavail * s.f_frsize / (1 << 30)


def centre(node):
    return node["x"] + node["w"] // 2, node["y"] + node["h"] // 2


def engine():
    """(pid, parent pid, parent command) of the engine named by the VM's pidfile while it runs, or None."""
    path = os.path.join(VM_DIR, VM_BUNDLE, "run", "qemu.pid")
    try:
        with open(path) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return None
    r = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    ppid, _, comm = r.stdout.strip().partition(" ")
    if "qemu-system" not in comm:
        return None
    parent = subprocess.run(["ps", "-o", "comm=", "-p", ppid], capture_output=True, text=True).stdout.strip()
    return pid, int(ppid), parent


VM_BUNDLE = "Windows 11.alcovevm"


def serving(path, timeout=20):
    """Waits until a server answers on the Unix socket `path`; Client() would start a server of its own otherwise."""
    end = time.time() + timeout
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
            return
        except OSError:
            expect(time.time() < end, f"no server answers on {path} {timeout} s after alcovectl serve started")
            time.sleep(0.2)
        finally:
            s.close()


class Run:
    """The control connection, the VM and what the checks started or changed in the guest and on the host."""

    def __init__(self, client, vm, apps_existed, server_pid):
        self.c = client
        self.vm = vm
        self.apps_existed = apps_existed
        self.server_pid = server_pid
        self.mcps = []
        self.children = []
        self.host = None
        self.cleanup_failed = False
        self.wrote_guest = False
        self.deployed = False
        self.fixture_pids = set()
        self.recording = False
        self.snapshot = False
        self.vm_left_stopped = False
        self.script = None
        self.started_utc = None
        self.clipboard = None

    # calls

    def call(self, op, reply_timeout=120, **params):
        return self.c.call(op, reply_timeout, name=self.vm, **params)

    def exec(self, command, timeout=60):
        r = self.call("vm.exec", timeout + 30, command=command, timeout=timeout)
        expect(r["code"] == 0, f"guest command {command[:120]!r} exited with {r['code']}: {r['stderr'].strip() or r['stdout'].strip()}")
        return r["stdout"].strip()

    def wait_for(self, conditions, timeout=30, **params):
        return self.call("vm.wait_for", timeout + 60, conditions=conditions, timeout=timeout, **params)

    def mcp(self):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at6-e2e")
        return m

    # host files

    def host_dir(self, *parts):
        """A directory below the run's temporary directory on the host, created when missing."""
        if self.host is None:
            self.host = tempfile.mkdtemp(prefix="alcove-at6-")
        path = os.path.join(self.host, *parts)
        os.makedirs(path, exist_ok=True)
        return path

    def socket_path(self, name):
        """A socket path in the run's host directory on which no server answers."""
        path = os.path.join(self.host_dir(), name)
        expect(len(path.encode()) < 100, f"the socket path {path} is too long for a Unix socket; set TMPDIR to a shorter directory")
        return path

    def app_source(self):
        """The host directory that holds the fixture build under the name the deploy starts."""
        folder = self.host_dir("apps", APP_NAME)
        target = os.path.join(folder, EXE)
        if not os.path.exists(target):
            expect(os.path.exists(FIXTURE_BUILD), f"missing {FIXTURE_BUILD}; build it with scripts/test/all.sh")
            shutil.copyfile(FIXTURE_BUILD, target)
        return folder

    def write_script(self, name, script):
        path = os.path.join(self.host_dir("scripts"), name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(script, f, ensure_ascii=False, indent=1)
        return path

    # alcovectl processes

    def spawn(self, argv, env=None):
        """Starts an alcovectl process in its own session; the cleanup ends it when it still runs."""
        p = subprocess.Popen([CTL] + argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             env=env, start_new_session=True)
        self.children.append(p)
        return p

    def finish(self, p, timeout):
        """(exit status, stdout, stderr) of a process started by spawn, once it has ended within `timeout` s."""
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure(f"{' '.join(p.args[1:3])} did not end within {timeout} s")
        self.children.remove(p)
        return p.returncode, out, err

    def run_script(self, *argv, env=None, timeout=300):
        """(exit status, stdout, stderr) of alcovectl run-script with `argv`."""
        return self.finish(self.spawn(["run-script"] + list(argv), env=env), timeout)

    # guest folders and the fixture

    def prepare_guest(self):
        """Creates the run's work folder in the guest."""
        if not self.wrote_guest:
            self.wrote_guest = True
            self.call("vm.fs.write", path=GUEST + r"\run.txt", text="at6-e2e\n")

    def read(self, path):
        return self.call("vm.fs.read", path=path)["text"]

    def processes(self, c=None, **params):
        return (c or self.c).call("vm.process.list", 60, name=self.vm, **params)["processes"]

    def own_processes(self, c=None):
        """The processes that run from the two guest folders of the run."""
        return [p for p in self.processes(c) if under(p["path"] or "", APP_DIR) or under(p["path"] or "", GUEST)]

    def kill(self, c, pids):
        for pid in pids:
            try:
                c.call("vm.process.kill", 60, name=self.vm, pid=pid, tree=True)
            except ControlTimeout:
                raise
            except ControlError:
                pass

    def end(self, c, running, seconds=15):
        """Kills the processes `running()` returns, by process id; returns the ones that still run after `seconds`."""
        self.kill(c, [p["pid"] for p in running()])
        end = time.time() + seconds
        while True:
            left = running()
            if not left or time.time() > end:
                return left
            time.sleep(0.3)

    def end_fixtures(self):
        left = self.end(self.c, self.own_processes)
        expect(not left, f"the processes {[p['pid'] for p in left]} of this run still run 15 s after vm.process.kill")

    def fixture(self):
        """Ends the run's fixtures and starts a new one; returns its window."""
        self.end_fixtures()
        self.prepare_guest()
        if self.deployed:
            r = self.call("vm.app.launch", path=APP_EXE, args=["--log", FIXTURE_LOG])
        else:
            self.deployed = True
            r = self.call("vm.deploy", 600, path=self.app_source(), launch={"exe": EXE, "args": ["--log", FIXTURE_LOG]})
        self.fixture_pids.add(r["pid"])
        expect(r.get("window") and r["window"]["title"] == TITLE, f"the fixture started without its window: {r!r}")
        return r["window"]

    def fixture_window(self):
        found = [w for w in self.call("vm.window.list")["windows"] if w["title"] == TITLE and w["pid"] in self.fixture_pids]
        expect(len(found) == 1, f"the guest shows {len(found)} windows of the run's fixture")
        return found[0]

    def element(self, **selector):
        nodes = self.call("vm.ui.find", selector={"window": TITLE, **selector})["nodes"]
        expect(len(nodes) == 1, f"vm.ui.find {selector!r} returned {len(nodes)} nodes")
        return nodes[0]

    def transcript(self):
        return self.call("vm.ui.text", selector=TRANSCRIPT)["text"]

    def log(self):
        return lines(self.read(FIXTURE_LOG))

    # the VM

    def status(self):
        return self.call("vm.status", 60)

    def need_disk(self, what):
        free = free_gib()
        expect(free >= START_FREE_GIB, f"{free:.1f} GiB are free on {DATA_VOLUME}; {what} needs {START_FREE_GIB} GiB; free disk space and run this script again")
        return free

    def stop_vm(self):
        """Stops the VM through the control server when it runs."""
        self.vm_left_stopped = True
        if self.status().get("state") != "stopped":
            self.call("vm.stop", 300)
        end = time.time() + 120
        while self.status().get("state") != "stopped":
            expect(time.time() < end, "the VM is not stopped 120 s after vm.stop")
            time.sleep(1)
        expect(engine() is None, f"the engine {engine()!r} still runs after vm.stop")

    def start_vm(self, c=None):
        """Starts the VM through the control server and waits for the guest tools; returns the seconds until they connected."""
        c = c or self.c
        self.need_disk("a start of the VM")
        began = time.monotonic()
        c.call("vm.start", 300, name=self.vm)
        while True:
            status = c.call("vm.status", 60, name=self.vm)
            if status.get("state") == "running" and status.get("tools") is True:
                break
            expect(time.monotonic() - began < 300, f"the guest tools are not connected 300 s after vm.start: {status!r}")
            time.sleep(2)
        self.vm_left_stopped = False
        return time.monotonic() - began

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

    def end_children(self):
        """Ends the alcovectl processes of the run: SIGTERM, and SIGKILL to the ones still running after 120 s."""
        for p in self.children:
            if p.poll() is None:
                try:
                    os.kill(p.pid, signal.SIGTERM)
                except OSError:
                    pass
        end = time.time() + 120
        for p in self.children:
            try:
                p.communicate(timeout=max(1, end - time.time()))
            except subprocess.TimeoutExpired:
                p.kill()
                p.communicate()
                self.cleanup_error(f"alcovectl {' '.join(p.args[1:3])} (pid {p.pid}) did not end 120 s after SIGTERM and was killed; "
                                   f"check that '{self.vm}' is stopped or runs under the control server")
        self.children = []

    def cleanup_steps(self):
        for m in self.mcps:
            try:
                m.close()
            except Exception:
                pass
        self.end_children()
        by_hand = f"end the processes that run from {APP_DIR} and {GUEST}, then delete the two folders"
        try:
            with Client(self.c.socket_path) as c:
                restored = self.restore(c, by_hand)
        except (ControlError, Failure) as e:
            restored = False
            self.cleanup_error(f"the control server failed ({e}); {by_hand}")
        try:
            self.c.close()
        except Exception:
            pass
        if self.host and restored:
            shutil.rmtree(self.host, ignore_errors=True)
        elif self.host:
            say(f"the host directory {self.host} of this run is kept")

    def restore(self, c, by_hand):
        """Puts the guest back; returns whether the guest could be reached."""
        status = c.call("vm.status", 60, name=self.vm)
        if self.vm_left_stopped and status.get("state") != "running":
            try:
                self.start_vm(c)
            except (ControlError, Failure) as e:
                self.cleanup_error(f"'{self.vm}' was stopped by this run and could not be started again ({e}); start it with "
                                   f"scripts/test/ctl.py vm.start, then {by_hand}")
                return False
        end = time.time() + 120
        while True:
            status = c.call("vm.status", 60, name=self.vm)
            if status.get("state") != "running" or status.get("tools") is True or time.time() > end:
                break
            time.sleep(1)
        if status.get("state") != "running" or status.get("tools") is not True:
            self.cleanup_error(f"'{self.vm}' is {status.get('state')} with tools {status.get('tools')!r}, so the guest was not cleaned; start it, {by_hand}")
            return False
        if self.recording:
            try:
                c.call("vm.record.stop", 120, name=self.vm)
            except ControlError as e:
                if "is not recording" not in str(e):
                    self.cleanup_error(f"vm.record.stop answered {e}; stop the recording of '{self.vm}'")
        if self.clipboard is not None:
            try:
                c.call("vm.clipboard.set", 60, name=self.vm, text=self.clipboard)
            except ControlError as e:
                self.cleanup_error(f"vm.clipboard.set answered {e}; the guest clipboard holds text of this run")
        if self.snapshot:
            try:
                c.call("vm.snapshot.delete", 600, name=self.vm, snapshot=SNAPSHOT)
            except ControlError as e:
                self.cleanup_error(f"vm.snapshot.delete of {SNAPSHOT} answered {e}; delete the snapshot with scripts/test/ctl.py vm.snapshot.delete")
        try:
            left = self.end(c, lambda: self.own_processes(c))
        except ControlError as e:
            self.cleanup_error(f"the processes of this run could not be ended ({e}); {by_hand}")
            return True
        if left:
            self.cleanup_error(f"the processes {[p['pid'] for p in left]!r} of this run still run; {by_hand}")
            return True
        if self.deployed:
            self.delete(c, APP_DIR)
            if not self.apps_existed:
                try:
                    if not c.call("vm.fs.list", 60, name=self.vm, path=APPS)["entries"]:
                        c.call("vm.fs.delete", 60, name=self.vm, path=APPS)
                except ControlError as e:
                    self.cleanup_error(f"{APPS} could not be removed ({e}); delete the empty folder in the guest")
        if self.wrote_guest:
            self.delete(c, GUEST)
        return True

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


def boot_script(*tail):
    """A script that starts the VM, waits for the desktop and the guest tools, then runs `tail`."""
    return {"version": 1, "vm": "Windows 11", "variables": {}, "steps": [
        {"label": "start the VM", "op": "vm.start", "params": {}},
        {"label": "wait for the desktop", "op": "vm.wait_for",
         "params": {"conditions": [{"type": "text_visible", "text": BOOT_TEXT}], "timeout": 300}},
        {"label": "wait for the guest tools", "op": "vm.wait_for",
         "params": {"conditions": [{"type": "file_exists", "path": BOOT_READY}], "timeout": 60}},
        *tail]}


def saved_script(run):
    expect(run.script is not None, "check 2 saves the script the later checks replay; run it first (add 2 to --only)")
    return run.script


def expect_passed(code, out, err, what):
    rows = lines(out)
    expect(code == 0 and rows and rows[-1].startswith("PASSED: "), f"{what} exited with {code}:\n{out}{err}")
    return rows


def expect_done(run, what):
    text = run.transcript()
    expect(f"You: {MESSAGE}" in text and "[done]" in text, f"after {what} the transcript reads {text[-300:]!r}")


@check("the fixture is deployed and started, and the snapshot at6-base is taken when the disk has room for it")
def _(run):
    window = run.fixture()
    free = free_gib()
    if free < SNAPSHOT_FREE_GIB:
        return f"pid {window['pid']}; no snapshot: {free:.1f} GiB free on {DATA_VOLUME}, a snapshot needs {SNAPSHOT_FREE_GIB} GiB"
    run.snapshot = True
    run.call("vm.snapshot.create", 900, snapshot=SNAPSHOT)
    after = free_gib()
    names = [s["name"] for s in run.call("vm.snapshot.list")["snapshots"]]
    expect(SNAPSHOT in names, f"vm.snapshot.list lists {names!r} after vm.snapshot.create")
    if after < START_FREE_GIB:
        run.stop_vm()
        raise Failure(f"{after:.1f} GiB are free after the snapshot; the VM was stopped; delete the snapshot {SNAPSHOT} and free disk space")
    return f"pid {window['pid']}; snapshot {SNAPSHOT}: {free:.1f} GiB free before, {after:.1f} GiB after"


@check("a recording of typing through a ref and a coordinate click on Send is saved as a script whose click is vm.ui.click on Send with a fallback")
def _(run):
    run.fixture_window()
    message = run.element(role="Edit", name="Message")
    send = run.element(role="Button", name="Send")
    cx, cy = centre(send)
    folder = os.path.join(run.host_dir("recordings"), "scenario")
    run.recording = True
    run.call("vm.record.start", dir=folder, video=False)
    run.call("vm.ui.type", ref=message["ref"], text=MESSAGE, clear=True)
    run.call("vm.mouse.click", x=cx, y=cy)
    stable = run.wait_for([{"type": "ui_text_stable", **TRANSCRIPT}])
    expect(stable["matched"] == 0, f"the transcript did not become still after the click on Send: {stable!r}")
    stopped = run.call("vm.record.stop")
    run.recording = False
    expect(stopped["ops"] == 3 and stopped["writeErrors"] == 0, f"vm.record.stop answered {stopped!r}")
    path = os.path.join(run.host_dir("scripts"), "scenario.json")
    saved = run.call("script.save", dir=folder, path=path)
    with open(path, encoding="utf-8") as f:
        script = json.load(f)
    ops = [s["op"] for s in script["steps"]]
    expect(saved["steps"] == 3 and ops == ["vm.ui.type", "vm.ui.click", "vm.wait_for"], f"script.save answered {saved!r} with the ops {ops!r}")
    typed, click = script["steps"][0]["params"], script["steps"][1]["params"]
    expect("ref" not in typed and typed.get("text") == MESSAGE and typed.get("selector", {}).get("automationId") == message["aid"]
           and typed.get("altSelector") == {"window": TITLE, "role": "Edit", "name": "Message"},
           f"the typing step has the params {typed!r}")
    named = [s for s in (click.get("selector", {}), click.get("altSelector", {})) if s.get("name") == "Send" and s.get("role") == "Button"]
    expect(named and click.get("fallback") == {"x": cx, "y": cy} and "x" not in click,
           f"the click step has the params {click!r}; the click was at {cx},{cy}")
    run.script = path
    return f"{saved['steps']} steps; click: selector {click['selector']!r}, altSelector {click.get('altSelector')!r}, fallback {click['fallback']!r}"


@check("alcovectl run-script replays the script three times in a row with exit status 0 and the transcript ends each run with [done]")
def _(run):
    path = saved_script(run)
    notes = []
    for n in range(3):
        if run.snapshot:
            argv = ["--snapshot", SNAPSHOT, path]
        else:
            run.fixture()
            argv = [path]
        began = time.monotonic()
        code, out, err = run.run_script("--socket", run.c.socket_path, *argv)
        rows = expect_passed(code, out, err, f"run {n + 1}")
        expect(not any("[fallback]" in r for r in rows), f"run {n + 1} clicked the fallback coordinates:\n{out}")
        expect_done(run, f"run {n + 1}")
        notes.append(f"{time.monotonic() - began:.1f} s")
    return ("with --snapshot " if run.snapshot else "without --snapshot, a new fixture before each run; ") + ", ".join(notes)


@check("after the fixture window moved by (+150, +90) the script still passes through its selectors, not its coordinates")
def _(run):
    path = saved_script(run)
    window = run.fixture()
    moved = run.call("vm.window.action", window=TITLE, action="move", x=window["x"] + MOVE[0], y=window["y"] + MOVE[1])["window"]
    expect((moved["x"], moved["y"]) == (window["x"] + MOVE[0], window["y"] + MOVE[1]), f"the window is at {moved['x']},{moved['y']} after the move from {window['x']},{window['y']}")
    with open(path, encoding="utf-8") as f:
        fallback = json.load(f)["steps"][1]["params"]["fallback"]
    send = run.element(role="Button", name="Send")
    expect(not (send["x"] <= fallback["x"] < send["x"] + send["w"] and send["y"] <= fallback["y"] < send["y"] + send["h"]),
           f"the fallback point {fallback!r} still lies on Send {send!r} after the move")
    code, out, err = run.run_script("--socket", run.c.socket_path, path)
    rows = expect_passed(code, out, err, "the run after the move")
    expect(not any("[fallback]" in r for r in rows), f"the run after the move clicked the fallback coordinates:\n{out}")
    expect_done(run, "the run after the move")
    return f"window {window['x']},{window['y']} -> {moved['x']},{moved['y']}; Send now at {centre(send)}, fallback {fallback['x']},{fallback['y']}"


@check("a selector set by --var to a missing control fails with exit status 1, a FAIL line that names the step and the selector, and a failure screenshot")
def _(run):
    path = saved_script(run)
    with open(path, encoding="utf-8") as f:
        script = json.load(f)
    click = script["steps"][1]["params"]
    click["selector"] = {"window": TITLE, "role": "Button", "name": "${button}"}
    click.pop("altSelector", None)
    click.pop("fallback", None)
    script["variables"] = {"button": "Send"}
    broken = run.write_script("missing.json", script)
    run.fixture()
    code, out, err = run.run_script("--socket", run.c.socket_path, "--var", f"button={MISSING}", broken)
    rows = lines(out)
    fail = [r for r in rows if r.startswith("FAIL ")]
    selector = json.dumps({"window": TITLE, "role": "Button", "name": MISSING}, ensure_ascii=False, separators=(",", ":"))
    expect(code == 1 and fail and fail[0].startswith("FAIL 2 ") and rows[-1].startswith("FAILED: step 2 failed"),
           f"the run exited with {code}:\n{out}{err}")
    detail = rows[rows.index(fail[0]) + 1] if rows.index(fail[0]) + 1 < len(rows) else ""
    expect(selector in detail, f"the line after {fail[0]!r} is {detail!r}; it must name the selector {selector}")
    image = broken + ".failure.png"
    expect(os.path.isfile(image), f"{image} does not exist after the failed run")
    with open(image, "rb") as f:
        head = f.read(24)
    expect(head[:8] == b"\x89PNG\r\n\x1a\n", f"{image} is not a PNG")
    width, height = int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
    code2, out2, err2 = run.run_script("--socket", run.c.socket_path, broken)
    expect(code2 == 0 and not os.path.exists(image), f"the run with the default button exited with {code2} and left {image}: {out2}{err2}")
    return f"{fail[0]} / {detail.strip()}; {os.path.basename(image)} {width}x{height}, removed by the next passing run"


@check("alcove_script_run over stdio replays the script and its text ends with PASSED")
def _(run):
    path = saved_script(run)
    run.fixture()
    m = run.mcp()
    err, text, images = m.call("alcove_script_run", {"path": path, "name": run.vm}, timeout=600)
    rows = lines(text)
    expect(not err and rows and rows[-1].startswith("PASSED") and not images, f"alcove_script_run answered error={err} {text!r} with {len(images)} images")
    expect_done(run, "alcove_script_run")
    m.close()
    run.mcps.remove(m)
    return rows[-1]


@check("the snapshot at6-base is deleted")
def _(run):
    if not run.snapshot:
        raise Skipped(f"check 1 took no snapshot ({free_gib():.1f} GiB free on {DATA_VOLUME}, a snapshot needs {SNAPSHOT_FREE_GIB} GiB)")
    run.call("vm.snapshot.delete", 600, snapshot=SNAPSHOT)
    run.snapshot = False
    names = [s["name"] for s in run.call("vm.snapshot.list")["snapshots"]]
    expect(SNAPSHOT not in names, f"vm.snapshot.list lists {names!r} after vm.snapshot.delete")
    return f"{free_gib():.1f} GiB free after the delete"


@check("a password given as --var PASSWORD from the environment is typed, the run passes, and the value is in no output, trace or failure file")
def _(run):
    secret_field = {"window": TITLE, "role": "Edit", "name": "Secret"}
    typing = {"label": "type the password", "op": "vm.ui.type", "params": {"selector": secret_field, "text": "${PASSWORD}", "clear": True}}
    good = run.write_script("password.json", {"version": 1, "vm": run.vm, "variables": {}, "steps": [typing]})
    bad = run.write_script("password-missing.json", {"version": 1, "vm": run.vm, "variables": {}, "steps": [
        typing, {"label": "press the missing button", "op": "vm.ui.click", "params": {"selector": {"window": TITLE, "role": "Button", "name": MISSING}}}]})
    run.fixture()
    env = dict(os.environ, PASSWORD=SECRET)
    folder = os.path.join(run.host_dir("recordings"), "password")
    run.recording = True
    run.call("vm.record.start", dir=folder, video=False)
    before = len(run.log())
    code, out, err = run.run_script("--socket", run.c.socket_path, "--var", "PASSWORD", good, env=env)
    expect_passed(code, out, err, "the run with the password")
    expect("variables: PASSWORD=<hidden>" in lines(out), f"the run did not print the variable as hidden:\n{out}")
    logged = [l for l in run.log()[before:] if " secret " in l]
    expect(logged and logged[-1].endswith(f" secret {len(SECRET)}"), f"the fixture logged {logged!r}; {len(SECRET)} characters were typed")
    code2, out2, err2 = run.run_script("--socket", run.c.socket_path, "--var", "PASSWORD", bad, env=env)
    expect(code2 == 1, f"the failing run with the password exited with {code2}:\n{out2}{err2}")
    stopped = run.call("vm.record.stop")
    run.recording = False
    with open(stopped["trace"], encoding="utf-8") as f:
        trace = f.read()
    typed = [json.loads(l)["params"].get("text") for l in lines(trace) if json.loads(l)["op"] == "vm.ui.type"]
    files = {"stdout and stderr": out + err + out2 + err2, "trace.jsonl": trace}
    for name in ("password.json", "password-missing.json", "password-missing.json.failure.png"):
        with open(os.path.join(run.host_dir("scripts"), name), "rb") as f:
            files[name] = f.read().decode("latin-1")
    leaked = [name for name, text in files.items() if SECRET in text]
    expect(not leaked, f"the password is in {leaked!r}")
    expect(typed == ["<masked>", "<masked>"], f"the trace holds the typed texts {typed!r}")
    return f"exit 0 and 1; fixture logged {logged[-1].split(' ', 1)[1]!r}; trace of {stopped['ops']} ops types <masked> twice; {len(files)} files searched"


@check("SIGINT, SIGTERM and SIGHUP during a step end run-script with 130, 143 and 129, no step runs after the signal and the lease is released")
def _(run):
    script = run.write_script("signal.json", {"version": 1, "vm": run.vm, "variables": {}, "steps": [
        {"label": "wait for nothing", "op": "vm.wait_for",
         "params": {"conditions": [{"type": "ui_exists", "window": TITLE, "role": "Button", "name": NOTHING}], "timeout": SIGNAL_WAIT_S}},
        {"label": "press Send", "op": "vm.ui.click", "params": {"selector": {"window": TITLE, "role": "Button", "name": "Send"}}}]})
    run.fixture()
    notes = []
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        before = len(run.log())
        p = run.spawn(["run-script", "--socket", run.c.socket_path, script])
        time.sleep(4)
        os.kill(p.pid, sig)
        began = time.monotonic()
        code, out, err = run.finish(p, 60)
        took = time.monotonic() - began
        expect(code == EXIT_FOR[sig] and lines(out)[-1:] == ["INTERRUPTED"], f"{signal.Signals(sig).name} gave exit {code}:\n{out}{err}")
        time.sleep(SIGNAL_WAIT_S + 3)
        added = run.log()[before:]
        expect(not added, f"the fixture logged {added!r} after {signal.Signals(sig).name}; the step after the signal ran")
        status = run.status()
        expect(not status.get("leasedBy"), f"'{run.vm}' is still leased by {status.get('leasedBy')!r} after {signal.Signals(sig).name}")
        notes.append(f"{signal.Signals(sig).name} {code} after {took:.1f} s")
    return "; ".join(notes)


@check("while the control server runs the VM, run-script --in-process and a second alcovectl serve are refused and the VM keeps running")
def _(run):
    held = engine()
    expect(held and held[1] == run.server_pid, f"the engine {held!r} is not the child of the control server (pid {run.server_pid})")
    booted = run.exec(BOOTED_AT)
    script = run.write_script("in-process-refused.json", boot_script())
    code, out, err = run.run_script("--in-process", "--socket", run.c.socket_path, script)
    expect(code == 2 and f"a control server answers at {run.c.socket_path}; run the script without --in-process, or stop that server first" in err,
           f"--in-process with the server's socket exited with {code}:\n{out}{err}")
    other = run.socket_path("none.sock")
    code, out, err = run.run_script("--in-process", "--socket", other, script)
    expect(code == 2 and f"'{run.vm}' is running under another process and no control server answers at {other}" in err,
           f"--in-process with no server at {other} exited with {code}:\n{out}{err}")
    second_socket = run.socket_path("second.sock")
    second = run.spawn(["serve", "--socket", second_socket])
    serving(second_socket)
    with Client(second_socket) as c2:
        c2.call("hello", 60)
        try:
            reply = c2.call("vm.start", 120, name=run.vm)
            raise Failure(f"vm.start through the second server succeeded with {reply!r}")
        except ControlTimeout:
            raise
        except ControlError as e:
            refusal = str(e)
    sentence = (f"start failed: '{run.vm}' is running in another Alcove host (alcovectl pid {run.server_pid}); "
                "stop the VM there or quit that host, then start it here")
    expect(refusal == sentence, f"vm.start through the second server answered {refusal!r}; expected {sentence!r}")
    os.kill(second.pid, signal.SIGTERM)
    code, _, err = run.finish(second, 60)
    expect(code == 0, f"the second server exited with {code} after SIGTERM: {err[-500:]}")
    status = run.status()
    expect(engine() == held and status.get("state") == "running" and status.get("tools") is True,
           f"after the refusals the engine is {engine()!r} (was {held!r}) and vm.status answers {status!r}")
    expect(run.exec(BOOTED_AT) == booted, "the guest booted again during the refusals")
    power = int(run.exec(KERNEL_POWER.replace("SINCE", run.started_utc)))
    expect(power == 0, f"the System log holds {power} Kernel-Power 41 entries since the run began")
    return f"engine pid {held[0]} unchanged; {refusal}"


@check("with the VM stopped, run-script --in-process starts it, passes and leaves it stopped")
def _(run):
    run.stop_vm()
    run.need_disk("the in-process run")
    script = run.write_script("in-process.json", boot_script(
        {"label": "list the windows", "op": "vm.window.list", "params": {}}))
    began = time.monotonic()
    code, out, err = run.run_script("--in-process", "--socket", run.socket_path("none.sock"), script, timeout=600)
    took = time.monotonic() - began
    rows = expect_passed(code, out, err, "the in-process run")
    expect(engine() is None, f"the engine {engine()!r} still runs after the in-process run ended")
    status = run.status()
    expect(status.get("state") == "stopped", f"vm.status answers {status!r} after the in-process run")
    return f"{rows[-1]}; the command took {took:.1f} s with the stop"


@check("SIGTERM during a step of run-script --in-process ends it with 143, stops the VM, and no step runs after the signal")
def _(run):
    run.stop_vm()
    run.need_disk("the in-process run")
    script = run.write_script("in-process-signal.json", boot_script(
        {"label": "wait for nothing", "op": "vm.wait_for",
         "params": {"conditions": [{"type": "file_exists", "path": GUEST + r"\no-such-file"}], "timeout": 300}},
        {"label": "write after the signal", "op": "vm.fs.write", "params": {"path": AFTER_SIGNAL, "text": "after\n"}}))
    p = run.spawn(["run-script", "--in-process", "--socket", run.socket_path("none.sock"), script])
    end = time.time() + 60
    while engine() is None:
        expect(time.time() < end and p.poll() is None, "the in-process run did not start the engine within 60 s")
        time.sleep(0.5)
    time.sleep(90)
    expect(p.poll() is None, "the in-process run ended before the signal")
    os.kill(p.pid, signal.SIGTERM)
    began = time.monotonic()
    code, out, err = run.finish(p, 180)
    took = time.monotonic() - began
    rows = lines(out)
    expect(code == 143 and rows[-1:] == ["INTERRUPTED"], f"SIGTERM gave exit {code}:\n{out}{err}")
    expect("     the run was cancelled during step 4; start it again" in rows and not [r for r in rows if r.startswith("ok   5") or r.startswith("FAIL 5")],
           f"the interrupted run printed:\n{out}")
    expect(engine() is None, f"the engine {engine()!r} still runs after the interrupted in-process run")
    run.start_vm()
    exists = run.exec(f"Test-Path -LiteralPath '{AFTER_SIGNAL}'")
    expect(exists == "False", f"{AFTER_SIGNAL} exists; the step after the signal ran")
    return f"exit 143 {took:.1f} s after SIGTERM; {' | '.join(r.strip() for r in rows[-3:])}"


@check("an engine whose alcovectl serve was killed is stopped by the next vm.start of the control server, which then starts the VM")
def _(run):
    run.stop_vm()
    run.need_disk("a start of the VM")
    second_socket = run.socket_path("second.sock")
    second = run.spawn(["serve", "--socket", second_socket])
    serving(second_socket)
    with Client(second_socket) as c2:
        c2.call("hello", 60)
        c2.call("vm.start", 120, name=run.vm)
    orphan = engine()
    expect(orphan and orphan[1] == second.pid, f"the engine {orphan!r} is not the child of the second server (pid {second.pid})")
    os.kill(second.pid, signal.SIGKILL)
    run.finish(second, 30)
    end = time.time() + 10
    while (engine() or (0, 0))[1] != 1:
        expect(time.time() < end, f"the engine is {engine()!r} 10 s after its server was killed; expected a running engine with parent 1")
        time.sleep(0.2)
    took = run.start_vm()
    held = engine()
    expect(held and held[0] != orphan[0] and held[1] == run.server_pid, f"after vm.start the engine is {held!r}; the orphan was pid {orphan[0]}")
    gone = subprocess.run(["ps", "-p", str(orphan[0])], capture_output=True).returncode != 0
    expect(gone, f"the orphaned engine pid {orphan[0]} still runs")
    power = int(run.exec(KERNEL_POWER.replace("SINCE", run.started_utc)))
    return f"orphan pid {orphan[0]} stopped; engine pid {held[0]} of the control server; tools after {took:.0f} s; Kernel-Power 41 entries since the run began: {power}"


def refusal_to_start(client, vm):
    """What of this run's folders, windows and processes the guest already holds; empty when the run can start.
    Also returns whether the apps root exists."""
    found = []
    answers = lines(client.call("vm.exec", 90, name=vm, timeout=60,
                                command=f"(Test-Path -LiteralPath '{GUEST}'), (Test-Path -LiteralPath '{APP_DIR}'), (Test-Path -LiteralPath '{APPS}')")["stdout"])
    if answers[0] == "True":
        found.append(f"the folder {GUEST}")
    if answers[1] == "True":
        found.append(f"the folder {APP_DIR}")
    for w in client.call("vm.window.list", 120, name=vm)["windows"]:
        if TITLE in w["title"]:
            found.append(f"the window {w['title']!r} of {w['process']} (pid {w['pid']})")
    for p in client.call("vm.process.list", 60, name=vm, filter="alcove-fixture")["processes"]:
        found.append(f"the process {p['name']} (pid {p['pid']})")
    if client.call("vm.record.status", 60, name=vm).get("recording") is True:
        found.append("a recording of the VM")
    if SNAPSHOT in [s["name"] for s in client.call("vm.snapshot.list", 60, name=vm)["snapshots"]]:
        found.append(f"the snapshot {SNAPSHOT}")
    return found, answers[2] == "True"


def main():
    global VM_BUNDLE
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}
    VM_BUNDLE = args.vm.replace("/", "-") + ".alcovevm"

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
        held = engine()
        if not held or "alcovectl" not in held[2]:
            print(f"FAIL 0: the engine of '{args.vm}' is {held!r}; its parent must be the alcovectl serve this script talks to; "
                  "quit the Alcove app, start alcovectl serve and the VM, and run this script again")
            sys.exit(1)
        if not os.access(CTL, os.X_OK):
            print(f"FAIL 0: {CTL} is missing; build it with `swift build --product alcovectl --scratch-path .build-ctl` in AlcoveKit")
            sys.exit(1)
        found, apps_existed = refusal_to_start(client, args.vm)
        started_utc = client.call("vm.exec", 90, name=args.vm, command=GUEST_NOW, timeout=60)["stdout"].strip()
        clipboard = client.call("vm.clipboard.get", 60, name=args.vm)["text"]
    except ControlError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    if found:
        print(f"FAIL 0: the guest already holds what this run creates: {'; '.join(found)}; remove it and run this script again")
        sys.exit(1)
    run = Run(client, args.vm, apps_existed, held[1])
    run.started_utc = started_utc
    run.clipboard = clipboard
    failed = None
    interrupted = False
    passed, skipped = [], []
    try:
        for n, title, fn in CHECKS:
            if only and n not in only:
                continue
            try:
                note = fn(run)
            except Skipped as e:
                skipped.append(n)
                say(f"SKIP {n} {title}: {e}")
                continue
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
            say(f"{len(passed)} passed, {len(skipped)} skipped" + (f" ({', '.join(map(str, skipped))})" if skipped else ""))
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
