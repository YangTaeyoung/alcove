#!/usr/bin/env python3
"""End-to-end run of the window, element, launch, deploy and event operations
against a running Windows VM: vm.deploy and its folder rules, vm.ui.tree,
vm.ui.find, vm.ui.text, vm.ui.click, vm.ui.type, vm.window.list,
vm.window.action, vm.app.launch, vm.events, the element, window and event
conditions of vm.wait_for, marks on screenshots, observations with the facts
of the UI, a recording that masks a password, and the same through the MCP
server (docs/control-protocol.md, mcp/).

Needs the VM running with the agent installed as the scheduled task
AlcoveAgent with --allow-exec (scripts/test/install-agent.py), a control
server built from this tree, `npm run build` in mcp/ and the fixture build
build/alcove-fixture-windows-arm64.exe (scripts/test/all.sh). The guest must
hold no C:\\alcove-e2e and no C:\\alcove-apps\\alcove-e2e-app, run no fixture,
and show no window of the fixture, of the test page in Edge, of Character Map
or of the Services console; the script refuses to start otherwise.

Each check prints `PASS <n> <title>`; the first failing check prints
`FAIL <n>: <reason>` and the script exits 1. The checks start the fixture app
from C:\\alcove-apps\\alcove-e2e-app, Edge with the profile folder
C:\\alcove-e2e\\edge-profile, Notepad, Character Map and the Services console,
create junctions under C:\\alcove-e2e and restart the guest agent once through
its scheduled task. Before Notepad starts, the files of its saved tabs are
copied to a temporary directory on the host. However the run ends, a second
connection stops the recording of the run, ends the processes the run started
(the ones that run from the two folders, the Edge processes of that profile,
and the Notepad, Character Map and console processes that were not running
before), puts Notepad's saved tabs and the clipboard text back, removes the
junctions with rmdir and deletes the two folders and the host directory of the
run. When a step of that cannot finish, the script prints
`cleanup failed: ...` with what to do by hand and exits 1.

Usage: at4-e2e.py [--vm NAME] [--only N[,N...]]
"""
import argparse, base64, hashlib, json, os, re, shutil, signal, stat, struct, sys, tempfile, time, urllib.parse, zlib

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout
from mcp_stdio import MCP, MCPError

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURE_BUILD = os.path.join(ROOT, "build", "alcove-fixture-windows-arm64.exe")
GUEST = r"C:\alcove-e2e"
APPS = r"C:\alcove-apps"
APP_NAME = "alcove-e2e-app"
APP_DIR = APPS + "\\" + APP_NAME
EXE = "alcove-fixture.exe"
APP_EXE = APP_DIR + "\\" + EXE
FIXTURE_LOG = GUEST + r"\fixture.log"
MARKER = ".alcove-deploy"
MARKER_TEXT = "vm.deploy of Alcove copied the files of this folder and replaces them on the next deploy.\n"
TITLE = "Alcove Fixture"
DIALOG = "Fixture Dialog"
MESSAGE = '스트리밍 "테스트" 1'
SECRET = "hunter2-Q7x"
SECOND_SECRET = "Zx9-second"
MASK = "<masked>"
PASSWORD_SENTENCE = "the element is a password field; its text is not read; it cannot be read through UI Automation"
BUSY_FACTS = "the UI helper is busy with another request; call vm.ui.tree when you need the tree"
MISSING_WINDOW = "No Such Window 4711"
MISSING_NAME = "No Such Element 4711"
EDGE_PROFILE = GUEST + r"\edge-profile"
EDGE_TITLE = "alcove-edge"
EDGE_PAGE = ('<title>alcove-edge</title><body><input aria-label="Edge field"> '
             "<button onclick=\"document.title='alcove-edge-clicked'\">Edge button</button></body>")
CONSOLE_TITLE = "Services"
CHARMAP_TITLE = "Character Map"
ELEVATED_FILE = GUEST + r"\elevated.txt"
ELEVATED_TEXT = "elevated window"
HIGH_INTEGRITY = 0x3000
NOTEPAD_STATE = "~/AppData/Local/Packages/Microsoft.WindowsNotepad_8wekyb3d8bbwe/LocalState"
NOTEPAD_STATE_EXISTS = r"Test-Path -LiteralPath (Join-Path $HOME 'AppData\Local\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState')"
TRACKED = {"notepad": "notepad.exe", "mmc": "mmc.exe", "charmap": "charmap.exe"}
MARK_COLOURS = [(230, 0, 92), (0, 122, 255), (0, 153, 68), (255, 128, 0), (153, 51, 204), (0, 163, 163)]
TREE_LINE = re.compile(r'^ *\[e\d+\] [A-Za-z]+ ".*"( \(-?\d+,-?\d+ \d+x\d+\))?( [a-z]+)*( value=".*")?$')
SLOW_SEARCH_S = 4.5
BUSY_CLICK_LIMIT_S = 6.5
TICK_S = 0.25
RESTART_AGENT = ("$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "
                 "'cmd.exe /c schtasks /End /TN AlcoveAgent & ping -n 3 127.0.0.1 >nul & schtasks /Run /TN AlcoveAgent' }; "
                 "\"created=$($r.ReturnValue)\"")
INTEGRITY = r'''
Add-Type -Namespace AlcoveE2E -Name Token -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("advapi32.dll")] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
[DllImport("advapi32.dll")] public static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr info, int length, out int needed);
[DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthority(IntPtr sid, int index);
[DllImport("advapi32.dll")] public static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
public static int Level(int pid) {
  IntPtr process = OpenProcess(0x1000, false, pid);
  if (process == IntPtr.Zero) return -1;
  IntPtr token;
  if (!OpenProcessToken(process, 8, out token)) { CloseHandle(process); return -1; }
  int length;
  GetTokenInformation(token, 25, IntPtr.Zero, 0, out length);
  IntPtr info = System.Runtime.InteropServices.Marshal.AllocHGlobal(length);
  int level = -1;
  if (GetTokenInformation(token, 25, info, length, out length)) {
    IntPtr sid = System.Runtime.InteropServices.Marshal.ReadIntPtr(info);
    int count = System.Runtime.InteropServices.Marshal.ReadByte(GetSidSubAuthorityCount(sid));
    level = System.Runtime.InteropServices.Marshal.ReadInt32(GetSidSubAuthority(sid, count - 1));
  }
  System.Runtime.InteropServices.Marshal.FreeHGlobal(info);
  CloseHandle(token);
  CloseHandle(process);
  return level;
}
"@
foreach ($id in @(PIDS)) { "$id=" + [AlcoveE2E.Token]::Level($id) }
'''


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l]


def png_image(data):
    """Width, height and the rows of an 8-bit RGB or RGBA PNG without interlacing; a row holds `channels` bytes per pixel."""
    expect(data[:8] == b"\x89PNG\r\n\x1a\n", "the image is not a PNG")
    at, packed, header = 8, b"", None
    while at + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        body = data[at + 8:at + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            packed += body
        at += 12 + length
    expect(header is not None, "the PNG has no header")
    width, height, depth, colour, _, _, interlace = header
    expect(depth == 8 and colour in (2, 6) and interlace == 0, f"the PNG has bit depth {depth}, colour type {colour}, interlace {interlace}")
    channels = 3 if colour == 2 else 4
    stride = width * channels
    flat = zlib.decompress(packed)
    expect(len(flat) == height * (stride + 1), f"the PNG holds {len(flat)} bytes for {width}x{height} pixels")
    rows, above = [], bytearray(stride)
    for y in range(height):
        kind = flat[y * (stride + 1)]
        row = bytearray(flat[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if kind == 1:
            for i in range(channels, stride):
                row[i] = (row[i] + row[i - channels]) & 255
        elif kind == 2:
            for i in range(stride):
                row[i] = (row[i] + above[i]) & 255
        elif kind == 3:
            for i in range(stride):
                row[i] = (row[i] + ((row[i - channels] if i >= channels else 0) + above[i]) // 2) & 255
        elif kind == 4:
            for i in range(stride):
                a = row[i - channels] if i >= channels else 0
                b = above[i]
                c = above[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        else:
            expect(kind == 0, f"row {y} of the PNG has the filter {kind}")
        rows.append(row)
        above = row
    return width, height, channels, rows


def pixel(image, x, y):
    """The (red, green, blue) of one pixel of a `png_image`."""
    _, _, channels, rows = image
    return tuple(rows[y][x * channels:x * channels + 3])


def inside(inner, outer):
    """Whether the rectangle `inner` with x, y, w, h is not empty and lies in the rectangle `outer`."""
    return (inner["w"] > 0 and inner["h"] > 0 and inner["x"] >= outer["x"] and inner["y"] >= outer["y"]
            and inner["x"] + inner["w"] <= outer["x"] + outer["w"] and inner["y"] + inner["h"] <= outer["y"] + outer["h"])


def centre(node):
    return node["x"] + node["w"] // 2, node["y"] + node["h"] // 2


def under(path, folder):
    """Whether the guest path lies below the guest folder."""
    return path.lower().startswith(folder.lower() + "\\")


class Run:
    """The control connection, the VM and what the checks started or changed in the guest and on the host."""

    def __init__(self, client, vm, apps_existed):
        self.c = client
        self.vm = vm
        self.apps_existed = apps_existed
        self.clients = []
        self.mcps = []
        self.host = None
        self.cleanup_failed = False
        self.wrote_guest = False
        self.deployed = False
        self.fixture_pids = set()
        self.edge_started = False
        self.before = {}
        self.junctions = []
        self.clipboard = None
        self.recording = False
        self.agent_restarted = False
        self.notepad_copy = None
        self.notepad_names = None
        self.notepad_dirs = []
        self.title_bar_clicks = 0

    # calls

    def call(self, op, reply_timeout=120, **params):
        return self.c.call(op, reply_timeout, name=self.vm, **params)

    def refusal(self, op, **params):
        """The error message of an operation that must fail."""
        try:
            reply = self.call(op, **params)
        except ControlTimeout:
            raise
        except ControlError as e:
            return str(e)
        raise Failure(f"{op} {params!r} succeeded with {sorted(reply)!r}; it must fail")

    def exec(self, command, timeout=60):
        r = self.call("vm.exec", timeout + 30, command=command, timeout=timeout)
        expect(r["code"] == 0, f"guest command {command[:120]!r} exited with {r['code']}: {r['stderr'].strip() or r['stdout'].strip()}")
        return r["stdout"].strip()

    def wait_for(self, conditions, timeout=30, **params):
        return self.call("vm.wait_for", timeout + 60, conditions=conditions, timeout=timeout, **params)

    def client(self):
        """A further connection to the control server, closed by the cleanup."""
        c = Client(self.c.socket_path)
        self.clients.append(c)
        return c

    def mcp(self):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at4-e2e")
        return m

    # host and guest folders

    def host_dir(self, *parts):
        """A directory below the run's temporary directory on the host, created when missing."""
        if self.host is None:
            self.host = tempfile.mkdtemp(prefix="alcove-at4-")
        path = os.path.join(self.host, *parts)
        os.makedirs(path, exist_ok=True)
        return path

    def app_source(self):
        """The host directory that holds the fixture build under the name the deploy starts."""
        folder = self.host_dir("apps", APP_NAME)
        target = os.path.join(folder, EXE)
        if not os.path.exists(target):
            expect(os.path.exists(FIXTURE_BUILD), f"missing {FIXTURE_BUILD}; build it with scripts/test/all.sh")
            shutil.copyfile(FIXTURE_BUILD, target)
        return folder

    def small_source(self, name, files):
        """A host directory with the given files: relative path to text."""
        folder = self.host_dir("small", name)
        for relative, text in files.items():
            target = os.path.join(folder, *relative.split("/"))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w") as f:
                f.write(text)
        return folder

    def prepare_guest(self):
        """Creates the run's work folder in the guest."""
        if not self.wrote_guest:
            self.wrote_guest = True
            self.call("vm.fs.write", path=GUEST + r"\run.txt", text="at4-e2e\n")

    def read(self, path):
        return self.call("vm.fs.read", path=path)["text"]

    def names(self, path, recursive=False):
        """The entry names of a guest folder."""
        listing = self.call("vm.fs.list", path=path, recursive=recursive)
        expect(not listing["truncated"], f"{path} holds more entries than vm.fs.list returns")
        return sorted(e["name"] for e in listing["entries"])

    def log(self):
        return lines(self.read(FIXTURE_LOG))

    def log_grows(self, before, wanted, timeout=5):
        """The log lines added after the first `before` lines once one of them ends with `wanted`."""
        end = time.time() + timeout
        while True:
            added = self.log()[before:]
            if any(l.endswith(wanted) for l in added):
                return added
            expect(time.time() < end, f"the fixture log has no line ending in {wanted!r} {timeout} s after the action; new lines: {added!r}")
            time.sleep(0.2)

    # processes

    def processes(self, c=None, **params):
        return (c or self.c).call("vm.process.list", 60, name=self.vm, **params)["processes"]

    def own_processes(self, c=None):
        """The processes that run from the two guest folders of the run."""
        return [p for p in self.processes(c) if under(p["path"] or "", APP_DIR) or under(p["path"] or "", GUEST)]

    def edge_processes(self, c=None):
        """The Edge processes whose command line names the run's profile folder."""
        return [p for p in self.processes(c, filter="msedge") if EDGE_PROFILE.lower() in (p["command"] or "").lower()]

    def tracked(self, kind, c=None):
        return {p["pid"] for p in self.processes(c, filter=kind) if p["name"].lower() == TRACKED[kind]}

    def started(self, kind, c=None):
        """The processes of a tracked program that were not running before the run's first launch of it."""
        if kind not in self.before:
            return set()
        return self.tracked(kind, c) - self.before[kind]

    def track(self, kind):
        """Notes the processes of a tracked program that run before the run starts one."""
        if kind not in self.before:
            self.before[kind] = self.tracked(kind)

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
        self.kill(c, [p if isinstance(p, int) else p["pid"] for p in running()])
        end = time.time() + seconds
        while True:
            left = running()
            if not left or time.time() > end:
                return left
            time.sleep(0.3)

    def end_fixtures(self):
        left = self.end(self.c, self.own_processes)
        expect(not left, f"the processes {[p['pid'] for p in left]} of this run still run 15 s after vm.process.kill")

    def agent_pid(self, c=None):
        agents = [p["pid"] for p in self.processes(c, filter="alcove-agent") if p["name"].lower() == "alcove-agent.exe"]
        expect(len(agents) == 1, f"the guest runs {len(agents)} alcove-agent.exe processes: {agents!r}")
        return agents[0]

    def integrity(self, pids):
        """The integrity level of each process: the last number of its integrity SID, -1 when it cannot be read."""
        out = self.exec(INTEGRITY.replace("PIDS", ",".join(str(p) for p in sorted(set(pids)))))
        return {int(k): int(v) for k, v in (l.split("=") for l in lines(out))}

    # windows and the fixture

    def windows(self, c=None):
        return (c or self.c).call("vm.window.list", 120, name=self.vm)["windows"]

    def fixture_window(self):
        for w in self.windows():
            if w["title"] == TITLE and w["pid"] in self.fixture_pids and w["responding"]:
                return w
        return None

    def deploy_fixture(self, **extra):
        """Deploys the fixture folder and starts the fixture; returns the reply of vm.deploy."""
        self.prepare_guest()
        source = self.app_source()
        self.deployed = True
        r = self.call("vm.deploy", 600, path=source, launch={"exe": EXE, "args": ["--log", FIXTURE_LOG]}, **extra)
        self.fixture_pids.add(r["pid"])
        return r

    def launch_fixture(self, path=APP_EXE, log=FIXTURE_LOG, **extra):
        r = self.call("vm.app.launch", path=path, args=["--log", log], **extra)
        self.fixture_pids.add(r["pid"])
        return r

    def fixture(self, fresh=False):
        """The window of the run's fixture: the one that is open and responding, or the one of a new process.
        With `fresh` the running fixtures are ended first."""
        if fresh:
            self.end_fixtures()
        window = self.fixture_window()
        if window is None:
            self.end_fixtures()
            r = self.launch_fixture() if self.deployed else self.deploy_fixture()
            expect(r.get("window") and r["window"]["title"] == TITLE, f"the fixture started without its window: {r!r}")
            window = r["window"]
        return window

    def focus(self, window=TITLE):
        """Brings a window to the foreground and returns it: through vm.window.action focus, and through a click on
        its title bar when the guest answers that the window did not come to the foreground."""
        try:
            found = self.call("vm.window.action", window=window, action="focus")["window"]
        except ControlTimeout:
            raise
        except ControlError as e:
            if "did not come to the foreground; click its title bar through the display" not in str(e):
                raise
            behind = [w for w in self.windows() if window in (w["id"], w["title"])][0]
            self.call("vm.mouse.click", x=behind["x"] + behind["w"] // 2, y=behind["y"] + 12)
            self.title_bar_clicks += 1
            time.sleep(0.5)
            found = [w for w in self.windows() if w["id"] == behind["id"]][0]
        expect(found["foreground"] is True, f"the window {window!r} is not in the foreground after vm.window.action focus and a click on its "
                                            f"title bar; in front is {self.front()}; move that window out of the way and run this script again")
        return found

    def front(self):
        """What vm.ui.tree says about the window in the foreground."""
        try:
            window = self.call("vm.ui.tree", window="foreground", depth=0)["window"]
            return f"{window['title']!r} of {window['process']}"
        except ControlTimeout:
            raise
        except ControlError as e:
            return f"no window ({e})"

    def element(self, **selector):
        """The one element of the fixture window the selector fields name."""
        nodes = self.call("vm.ui.find", selector={"window": TITLE, **selector})["nodes"]
        expect(len(nodes) == 1, f"vm.ui.find {selector!r} returned {len(nodes)} nodes: {[(n['role'], n['name']) for n in nodes]!r}")
        return nodes[0]

    def click(self, name, **params):
        return self.call("vm.ui.click", selector={"window": TITLE, "role": "Button", "name": name}, **params)

    def close_dialog(self):
        r = self.call("vm.window.action", window=DIALOG, action="close")
        expect(r.get("closed") is True and r["window"] is None, f"vm.window.action close of the dialog answered {r!r}")
        return r

    def launch(self, kind, **params):
        """Starts a tracked program through vm.app.launch."""
        self.track(kind)
        return self.call("vm.app.launch", **params)

    def junction(self, link, target):
        """Creates a junction in the guest that the cleanup removes."""
        self.junctions.append(link)
        self.exec(f'cmd /c mklink /J "{link}" "{target}"')

    def remove_junction(self, c, link):
        """Removes one junction with rmdir and reports whether its path is gone."""
        r = c.call("vm.exec", 90, name=self.vm, timeout=60,
                   command=f'if (Test-Path -LiteralPath "{link}") {{ cmd /c rmdir "{link}" }}; Test-Path -LiteralPath "{link}"')
        return r["code"] == 0 and lines(r["stdout"])[-1:] == ["False"]

    # Notepad

    def snapshot_notepad(self):
        """Copies the files of Notepad's saved tabs to the run's host directory and notes the folders."""
        copy = self.host_dir("notepad-state")
        names, dirs = None, []
        if self.exec(NOTEPAD_STATE_EXISTS) == "True":
            entries = self.call("vm.fs.list", path=NOTEPAD_STATE, recursive=True)
            expect(not entries["truncated"], f"{NOTEPAD_STATE} holds more files than vm.fs.list returns")
            names = [e["name"] for e in entries["entries"] if not e["dir"]]
            dirs = [e["name"] for e in entries["entries"] if e["dir"]]
            for name in names:
                target = os.path.join(copy, *name.split("/"))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                self.call("vm.pull_file", guestPath=NOTEPAD_STATE + "/" + name, path=target)
        self.notepad_copy, self.notepad_names, self.notepad_dirs = copy, names, dirs

    def restore_notepad(self, c):
        """Makes the files of Notepad's saved tabs equal to the host copy and removes the folders that were not there
        before the run; deletes the whole folder when it did not exist."""
        if self.notepad_names is None:
            c.call("vm.fs.delete", 120, name=self.vm, path=NOTEPAD_STATE, recursive=True)
            return
        entries = c.call("vm.fs.list", 120, name=self.vm, path=NOTEPAD_STATE, recursive=True)["entries"]
        for name in {e["name"] for e in entries if not e["dir"]} - set(self.notepad_names):
            c.call("vm.fs.delete", 120, name=self.vm, path=NOTEPAD_STATE + "/" + name)
        added = {e["name"] for e in entries if e["dir"]} - set(self.notepad_dirs)
        for name in sorted(added):
            if name.rpartition("/")[0] not in added:
                c.call("vm.fs.delete", 120, name=self.vm, path=NOTEPAD_STATE + "/" + name, recursive=True)
        for name in self.notepad_names:
            source = os.path.join(self.notepad_copy, *name.split("/"))
            pushed = c.call("vm.push_file", 120, name=self.vm, path=source, guestPath=NOTEPAD_STATE + "/" + name, overwrite=True)
            with open(source, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            expect(pushed["sha256"] == digest, f"{NOTEPAD_STATE}/{name} has SHA-256 {pushed['sha256']} after the upload, the copy has {digest}")

    def put_notepad_back(self, c):
        """Ends the Notepad processes of the run and puts the saved tabs back; returns what went wrong, or None."""
        left = self.end(c, lambda: self.started("notepad", c))
        if left:
            return f"the Notepad processes {sorted(left)} still run, so Notepad's saved tabs were not put back"
        self.restore_notepad(c)
        self.notepad_copy = None
        return None

    # cleanup

    def cleanup_error(self, what):
        self.cleanup_failed = True
        print(f"cleanup failed: {what}", flush=True)

    def cleanup(self):
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGINT)}
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
        for c in self.clients + [self.c]:
            try:
                c.close()
            except Exception:
                pass
        touched = self.wrote_guest or self.deployed or self.before or self.junctions or self.notepad_copy or self.recording
        by_hand = (f"end the processes that run from {APP_DIR} and {GUEST}, remove the junctions {self.junctions!r} with rmdir, "
                   f"then delete the two folders")
        if self.notepad_copy:
            by_hand += (f"; end the Notepad of this run, then make {NOTEPAD_STATE} equal to the copy in {self.notepad_copy} "
                        "(delete the files that are not in the copy" + ("" if self.notepad_names is not None else "; the folder did not exist before the run") + ")")
        try:
            with Client(self.c.socket_path) as c:
                restored = self.restore(c, touched, by_hand)
        except ControlError as e:
            restored = False
            self.cleanup_error(f"the control server failed ({e}); {by_hand}")
        if self.host and restored and not self.notepad_copy:
            shutil.rmtree(self.host, ignore_errors=True)
        elif self.host:
            print(f"the host directory {self.host} of this run is kept", flush=True)

    def restore(self, c, touched, by_hand):
        """Puts the guest back; returns whether the guest could be reached."""
        end = time.time() + (120 if self.agent_restarted else 0)
        while True:
            status = c.call("vm.status", 60, name=self.vm)
            if status.get("state") != "running" or status.get("tools") is True or time.time() > end:
                break
            time.sleep(1)
        if status.get("state") != "running" or status.get("tools") is not True:
            if touched:
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
        clean = True
        for what, running in (("processes from the folders of this run", lambda: self.own_processes(c)),
                              ("Edge processes of the profile of this run", lambda: self.edge_processes(c) if self.edge_started else []),
                              ("console processes of this run", lambda: self.started("mmc", c)),
                              ("Character Map processes of this run", lambda: self.started("charmap", c))):
            try:
                left = self.end(c, running)
                if left:
                    clean = False
                    self.cleanup_error(f"the {what} still run: {[p if isinstance(p, int) else p['pid'] for p in left]!r}; end them in the guest")
            except ControlError as e:
                clean = False
                self.cleanup_error(f"the {what} could not be ended ({e}); end them in the guest")
        if self.notepad_copy:
            try:
                problem = self.put_notepad_back(c)
                if problem:
                    self.cleanup_error(f"{problem}; {by_hand}")
            except (ControlError, Failure, OSError) as e:
                self.cleanup_error(f"Notepad's saved tabs were not put back ({e}); {by_hand}")
        for link in self.junctions:
            try:
                if not self.remove_junction(c, link):
                    clean = False
                    self.cleanup_error(f"the junction {link} could not be removed; remove it in the guest with rmdir")
            except ControlError as e:
                clean = False
                self.cleanup_error(f"the junction {link} could not be removed ({e}); remove it in the guest with rmdir")
        if not clean:
            self.cleanup_error(f"{APP_DIR} and {GUEST} were not deleted; {by_hand}")
            return True
        if self.deployed:
            self.delete(c, APP_DIR)
            if not self.apps_existed:
                try:
                    if not c.call("vm.fs.list", 60, name=self.vm, path=APPS)["entries"]:
                        c.call("vm.fs.delete", 60, name=self.vm, path=APPS)
                except ControlError as e:
                    self.cleanup_error(f"{APPS} could not be removed ({e}); delete the empty folder in the guest")
        if self.wrote_guest or self.junctions:
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


@check("vm.deploy copies the fixture folder, starts the app with its window, and a second deploy sends nothing and restarts it")
def _(run):
    size = os.path.getsize(FIXTURE_BUILD)
    began = time.monotonic()
    first = run.deploy_fixture()
    took = time.monotonic() - began
    window = first.get("window") or {}
    expect(first["guestDir"] == APP_DIR and first["sent"] == [EXE] and first["skipped"] == 0 and first["bytes"] == size,
           f"the first deploy answered guestDir {first.get('guestDir')!r}, sent {first.get('sent')!r}, skipped {first.get('skipped')!r}, "
           f"bytes {first.get('bytes')!r}; the folder holds one file of {size} bytes")
    expect(window.get("title") == TITLE and window.get("pid") == first["pid"] and window.get("process", "").lower() == EXE
           and "windowTimedOut" not in first and type(first.get("eventSeq")) is int,
           f"the first deploy answered pid {first.get('pid')!r}, window {window!r}, fields {sorted(first)!r}")
    expect(run.names(APP_DIR) == [MARKER, EXE] and run.read(APP_DIR + "\\" + MARKER) == MARKER_TEXT,
           f"{APP_DIR} holds {run.names(APP_DIR)!r} after the deploy and its marker reads {run.read(APP_DIR + chr(92) + MARKER)!r}")

    second = run.deploy_fixture()
    again = second.get("window") or {}
    expect(second["sent"] == [] and second["skipped"] == 1 and second["bytes"] == 0,
           f"a deploy of the unchanged folder answered sent {second.get('sent')!r}, skipped {second.get('skipped')!r}, bytes {second.get('bytes')!r}")
    expect(second["pid"] != first["pid"] and again.get("title") == TITLE and again.get("pid") == second["pid"],
           f"the second deploy answered pid {second.get('pid')!r} (first: {first['pid']}) and window {again!r}")
    running = {p["pid"] for p in run.own_processes()}
    expect(first["pid"] not in running and second["pid"] in running,
           f"after the second deploy the processes from the folders are {sorted(running)}; the first app was pid {first['pid']}, the second is {second['pid']}")
    starts = [l for l in run.log() if " start pid " in l]
    expect([l.split(" start pid ")[1].split()[0] for l in starts] == [str(first["pid"]), str(second["pid"])],
           f"the fixture log holds the start lines {starts!r}; the deploys started pids {first['pid']} and {second['pid']}")
    return f"{size} bytes to {APP_DIR} in {took:.1f} s, window {window['id']} of pid {first['pid']}; then sent nothing and restarted as pid {second['pid']}"


@check("vm.ui.tree lists the fixture window with its edit, its button and its Korean label in fewer than 60 lines")
def _(run):
    window = run.fixture()
    r = run.call("vm.ui.tree", window=TITLE)
    rows = r["tree"].split("\n")
    for wanted in ('Edit "Message"', 'Button "Send"', "한글 라벨"):
        expect(any(wanted in row for row in rows), f"the tree has no line with {wanted!r}: {rows!r}")
    expect(len(rows) < 60 and r["count"] == len(rows) and r["truncated"] is False,
           f"the tree has {len(rows)} lines, count {r['count']!r}, truncated {r['truncated']!r}")
    odd = [row for row in rows if not TREE_LINE.fullmatch(row)]
    expect(not odd, f"tree lines that are not '[ref] Role \"name\" (x,y WxH) flags': {odd!r}")
    expect(rows[0].startswith("[") and f'Window "{TITLE}"' in rows[0] and all(row.startswith("  ") for row in rows[1:]),
           f"the tree does not start with the window at depth 0: {rows[:2]!r}")
    expect(r["window"]["id"] == window["id"] and r["window"]["title"] == TITLE, f"the tree names the window {r['window']!r}, the fixture is {window['id']}")
    secret = [row for row in rows if row.rstrip().endswith("password")]
    expect(len(secret) == 1 and 'Edit ""' in secret[0], f"the tree shows the password field as {secret!r}")
    return f"{len(rows)} lines for window {window['id']}"


@check("typing a Korean message, clicking Send and waiting for a stable transcript shows the reply, and the log has the send line")
def _(run):
    run.fixture(fresh=True)
    if run.clipboard is None:
        run.clipboard = run.call("vm.clipboard.get")["text"]
    before = len(run.log())
    typed = run.call("vm.ui.type", selector={"window": TITLE, "role": "Edit", "name": "Message"}, text=MESSAGE)
    expect(typed["node"]["role"] == "Edit" and typed["node"]["name"] == "Message" and type(typed.get("eventSeq")) is int,
           f"vm.ui.type answered {typed!r}")
    field = run.element(role="Edit", name="Message")
    expect(field.get("value") == MESSAGE, f"the Message field holds {field.get('value')!r} after vm.ui.type, expected {MESSAGE!r}")

    clicked = run.click("Send", observe="summary")
    seen, node = clicked["observation"], clicked["node"]
    expect(node["role"] == "Button" and node["name"] == "Send" and node["x"] <= clicked["x"] < node["x"] + node["w"]
           and node["y"] <= clicked["y"] < node["y"] + node["h"], f"vm.ui.click answered node {node!r} and the point {clicked.get('x')},{clicked.get('y')}")
    expect(seen.get("foreground") == TITLE, f"the observation of the click names the foreground window {seen.get('foreground')!r}: {seen!r}")
    expect(isinstance(seen.get("events"), list) and "uiError" not in seen and "changed" in seen,
           f"the observation of the click has the fields {sorted(seen)!r} and uiError {seen.get('uiError')!r}")

    transcript = {"window": TITLE, "role": "Document", "name": "Transcript"}
    stable = run.wait_for([{"type": "ui_text_stable", **transcript}], timeout=30)
    expect(stable["matched"] == 0 and stable["type"] == "ui_text_stable", f"vm.wait_for ui_text_stable answered {stable!r}")
    text = run.call("vm.ui.text", selector=transcript)
    expect(f"You: {MESSAGE}" in text["text"] and "[done]" in text["text"] and text["total"] == stable["detail"] == len(text["text"]),
           f"vm.ui.text returned {text!r}; the wait reported {stable['detail']!r} characters")
    sent = [l for l in run.log()[before:] if l.endswith(" send " + MESSAGE)]
    expect(len(sent) == 1, f"the fixture log has {len(sent)} send lines for the message: {run.log()[before:]!r}")
    return f"transcript of {text['total']} characters stable after {stable['waited']} s; foreground {seen['foreground']!r}, focused {seen.get('focused')!r}"


@check("the Dialog button raises dialog.opened, the dialog is listed and closed, and vm.events holds opened and closed in order")
def _(run):
    run.fixture()
    run.focus()
    clicked = run.click("Dialog")
    since = clicked["eventSeq"]
    opened = run.wait_for([{"type": "event", "event": "dialog.opened"}], timeout=15)
    expect(opened["matched"] == 0 and opened["type"] == "event" and opened["detail"]["name"] == "dialog.opened"
           and opened["detail"]["window"]["title"] == DIALOG and opened["detail"]["seq"] > since,
           f"vm.wait_for event dialog.opened after eventSeq {since} answered {opened!r}")
    listed = [w for w in run.windows() if w["title"] == DIALOG]
    expect(len(listed) == 1 and listed[0]["modal"] is True and listed[0]["id"] == opened["detail"]["window"]["id"],
           f"vm.window.list shows the dialog as {listed!r}; the event names {opened['detail']['window']['id']}")
    closed = run.close_dialog()
    gone = run.wait_for([{"type": "event", "event": "window.closed", "titleContains": DIALOG, "since": since}], timeout=15)
    expect(gone["matched"] == 0, f"vm.wait_for event window.closed for the dialog answered {gone!r}")
    events = run.call("vm.events", since=since)
    mine = [(e["seq"], e["name"]) for e in events["events"] if (e.get("window") or {}).get("title") == DIALOG]
    names = [name for _, name in mine]
    expect(all(n in names for n in ("window.opened", "dialog.opened", "window.closed"))
           and names.index("window.opened") < names.index("dialog.opened") < names.index("window.closed"),
           f"vm.events since {since} holds for the dialog {mine!r}")
    seqs = [e["seq"] for e in events["events"]]
    expect(seqs == list(range(since + 1, since + 1 + len(seqs))) and events["next"] == seqs[-1] and 1 <= events["first"] <= since + 1,
           f"vm.events since {since} returned the sequence numbers {seqs!r}, next {events['next']!r}, first {events['first']!r}")
    expect(not [w for w in run.windows() if w["title"] == DIALOG], "the dialog is still listed after it was closed")
    return f"dialog {listed[0]['id']} opened {opened['waited']} s after the click; events {mine!r}; close answered eventSeq {closed.get('eventSeq')}"


@check("vm.screenshot of the fixture window with marks has the size of the window and outlines Send inside it")
def _(run):
    run.fixture()
    window = run.focus()
    send = run.element(role="Button", name="Send")
    plain = run.call("vm.screenshot", window=TITLE)
    shot = run.call("vm.screenshot", window=TITLE, marks=True)
    image = png_image(base64.b64decode(shot["png"]))
    expect((shot["sentWidth"], shot["sentHeight"]) == (window["w"], window["h"]) == image[:2] and shot["scale"] == 1,
           f"the marked screenshot is {image[0]}x{image[1]}, sent {shot['sentWidth']}x{shot['sentHeight']} at scale {shot['scale']!r}; "
           f"the window is {window['w']}x{window['h']}")
    expect((shot["x"], shot["y"], shot["areaWidth"], shot["areaHeight"]) == (window["x"], window["y"], window["w"], window["h"])
           and shot["window"]["id"] == window["id"],
           f"the screenshot reports the area {shot['x']},{shot['y']} {shot['areaWidth']}x{shot['areaHeight']} of window {shot['window']['id']}; "
           f"the fixture is {window['id']} at {window['x']},{window['y']} {window['w']}x{window['h']}")
    marks = shot["marks"]
    expect([m["n"] for m in marks] == list(range(1, len(marks) + 1)) and "marksTruncated" not in shot and "marks" not in plain,
           f"the marks are numbered {[m['n'] for m in marks]!r}, marksTruncated {shot.get('marksTruncated')!r}; a screenshot without marks has {sorted(plain)!r}")
    named = [m for m in marks if m["name"] == "Send" and m["role"] == "Button"]
    expect(len(named) == 1 and inside(named[0], window) and named[0]["ref"] == send["ref"]
           and all(named[0][k] == send[k] for k in ("x", "y", "w", "h")),
           f"the marks named Send are {named!r}; vm.ui.find reports {send!r} in the window {window!r}")
    mark = named[0]
    at = (mark["x"] - window["x"], mark["y"] - window["y"] + mark["h"] // 2)
    colour = MARK_COLOURS[(mark["n"] - 1) % len(MARK_COLOURS)]
    drawn, bare = pixel(image, *at), pixel(png_image(base64.b64decode(plain["png"])), *at)
    expect(all(abs(a - b) <= 3 for a, b in zip(drawn, colour)) and any(abs(a - b) > 3 for a, b in zip(bare, colour)),
           f"the left edge of mark {mark['n']} at image pixel {at} is {drawn} with marks and {bare} without; the outline colour is {colour}")
    return f"{image[0]}x{image[1]} image, {len(marks)} marks, Send is number {mark['n']} at {mark['x']},{mark['y']} {mark['w']}x{mark['h']}, outline pixel {drawn}"


@check("after Hang the window list reports the fixture as not responding, and killing it raises process.exited")
def _(run):
    window = run.fixture(fresh=True)
    pid = window["pid"]
    run.focus()
    began = time.monotonic()
    run.click("Hang")
    while True:
        listed = [w for w in run.windows() if w["id"] == window["id"]]
        if listed and listed[0]["responding"] is False:
            break
        expect(time.monotonic() - began < 10, f"vm.window.list still reports the fixture window as {listed!r} 10 s after the click on Hang")
        time.sleep(0.5)
    hung = time.monotonic() - began
    message = run.refusal("vm.ui.tree", window=window["id"])
    expect(message.startswith(f'window {window["id"]} "{TITLE}" is not responding; '), f"vm.ui.tree of the hung window failed with {message!r}")
    killed = run.call("vm.process.kill", pid=pid)
    expect(killed["killed"] >= 1 and type(killed.get("eventSeq")) is int, f"vm.process.kill of pid {pid} answered {killed!r}")
    exited = run.wait_for([{"type": "event", "event": "process.exited"}], timeout=30)
    detail = exited.get("detail") or {}
    expect(exited["matched"] == 0 and detail.get("pid") == pid and detail.get("code") == 1 and detail.get("path", "").lower() == APP_EXE.lower(),
           f"vm.wait_for event process.exited after the kill of pid {pid} answered {exited!r}")
    return f"responding false {hung:.1f} s after the click; process.exited for pid {pid} with code {detail['code']} {exited['waited']} s after the kill"


@check("Edge with its own profile shows a page whose button vm.ui.find returns and vm.ui.click presses")
def _(run):
    run.prepare_guest()
    expect(not run.edge_processes(), f"Edge processes with the profile {EDGE_PROFILE} run already")
    run.edge_started = True
    began = time.monotonic()
    launched = run.call("vm.app.launch", path="msedge.exe", waitWindow=60,
                        args=["--user-data-dir=" + EDGE_PROFILE, "--no-first-run", "--new-window", "data:text/html," + urllib.parse.quote(EDGE_PAGE)])
    window = launched.get("window") or {}
    expect(window.get("process", "").lower() == "msedge.exe", f"vm.app.launch of Edge answered {launched!r}")
    titled = run.wait_for([{"type": "window_title", "contains": EDGE_TITLE}], timeout=30)
    expect(titled["matched"] == 0 and titled["detail"]["id"] == window["id"], f"vm.wait_for window_title for the page's title answered {titled!r}; the launch returned window {window['id']}")
    browser = [p for p in run.edge_processes() if p["pid"] == window["pid"]]
    expect(len(browser) == 1, f"the window's process {window['pid']} is not an Edge process of the profile {EDGE_PROFILE}")
    run.focus(window["id"])
    there = run.wait_for([{"type": "ui_exists", "window": window["id"], "name": "Edge button"}], timeout=60)
    expect(there["matched"] == 0, f"vm.wait_for ui_exists for the page's button answered {there!r}")
    ready = time.monotonic() - began
    found = run.call("vm.ui.find", selector={"window": EDGE_TITLE, "name": "Edge button"})["nodes"]
    expect(len(found) == 1 and found[0]["role"] == "Button" and inside(found[0], window),
           f"vm.ui.find for the page's button returned {found!r}; the window is {window!r}")
    field = run.call("vm.ui.find", selector={"window": window["id"], "role": "Edit", "name": "Edge field"})["nodes"]
    expect(len(field) == 1, f"vm.ui.find for the page's input returned {field!r}")
    run.call("vm.ui.type", ref=field[0]["ref"], text="edge 123")
    value = run.call("vm.ui.find", ref=field[0]["ref"])["nodes"][0].get("value")
    expect(value == "edge 123", f"the page's input holds {value!r} after vm.ui.type")

    clicked = run.call("vm.ui.click", selector={"window": window["id"], "name": "Edge button"}, observe="summary")
    expect(clicked["node"]["name"] == "Edge button" and EDGE_TITLE in (clicked["observation"].get("foreground") or ""),
           f"vm.ui.click on the page's button answered {clicked!r}")
    title = run.wait_for([{"type": "window_title", "contains": "alcove-edge-clicked"}], timeout=15)
    expect(title["matched"] == 0 and title["detail"]["id"] == window["id"], f"the page's title after the click: vm.wait_for answered {title!r}")
    count = run.call("vm.ui.tree", window=window["id"])["count"]

    left = run.end(run.c, lambda: [p for p in run.edge_processes() if p["pid"] == window["pid"]])
    expect(not left, f"the Edge process {window['pid']} still runs 15 s after vm.process.kill with tree")
    left = run.end(run.c, run.edge_processes)
    expect(not left, f"Edge processes of the profile still run: {[p['pid'] for p in left]!r}")
    return (f"window {titled['detail']['title']!r} of pid {window['pid']} (launched pid {launched['pid']}), button found {ready:.1f} s after the launch at "
            f"{found[0]['x']},{found[0]['y']}, tree of {count} elements, title after the click {title['detail']['title']!r}")


@check("the tree of a Notepad that the elevated agent started is read, and no window has a higher integrity level than the agent")
def _(run):
    run.prepare_guest()
    before = run.tracked("notepad")
    expect(not before, f"notepad.exe runs already (pids {sorted(before)}); close it in the guest before this run")
    run.snapshot_notepad()
    print(f"Notepad's saved tabs are copied to {run.notepad_copy} on the host", flush=True)
    run.call("vm.fs.write", path=ELEVATED_FILE, text=ELEVATED_TEXT + "\r\n")
    launched = run.launch("notepad", path="notepad.exe", args=[ELEVATED_FILE], waitWindow=60)
    window = launched.get("window") or {}
    expect(window.get("pid") in run.started("notepad"),
           f"vm.app.launch of Notepad answered {launched!r}; the Notepad processes of this run are {sorted(run.started('notepad'))}")
    titled = run.wait_for([{"type": "window_title", "contains": "elevated.txt"}], timeout=30)
    expect(titled["matched"] == 0 and titled["detail"]["id"] == window["id"], f"vm.wait_for window_title for the file's name answered {titled!r}; the launch returned window {window['id']}")
    listed = run.windows()
    agent = run.agent_pid()
    levels = run.integrity([w["pid"] for w in listed] + [agent])
    expect(levels[agent] >= HIGH_INTEGRITY and levels[window["pid"]] >= HIGH_INTEGRITY,
           f"the agent runs at integrity level {levels[agent]:#x} and the Notepad it started at {levels[window['pid']]:#x}; "
           f"this check needs both at {HIGH_INTEGRITY:#x} (high) or above")
    tree = run.call("vm.ui.tree", window=window["id"])
    rows = tree["tree"].split("\n")
    expect(tree["count"] >= 5 and tree["window"]["id"] == window["id"] and any(row.lstrip().startswith("[") and " Document " in row for row in rows),
           f"vm.ui.tree of the elevated Notepad returned {tree['count']} elements: {rows[:6]!r}")
    text = run.call("vm.ui.text", selector={"window": window["id"], "role": "Document"})
    expect(text["text"].strip() == ELEVATED_TEXT, f"vm.ui.text of the elevated Notepad returned {text['text']!r}")
    higher = [w for w in listed if levels.get(w["pid"], -1) > levels[agent]]
    answers = []
    for w in higher:
        try:
            answers.append(f"{w['title']!r} ({levels[w['pid']]:#x}): {run.call('vm.ui.tree', window=w['id'])['count']} elements")
        except ControlTimeout:
            raise
        except ControlError as e:
            answers.append(f"{w['title']!r} ({levels[w['pid']]:#x}): {e}")
    problem = run.put_notepad_back(run.c)
    expect(problem is None, problem)
    above = "; windows above the agent's level: " + "; ".join(answers) if answers else f"; none of the {len(listed)} windows is above the agent's level"
    return (f"Notepad pid {window['pid']} at integrity {levels[window['pid']]:#x}, agent at {levels[agent]:#x}, tree of {tree['count']} elements"
            + above + f" (levels {sorted(set(levels.values()))!r})")


@check("the MCP server reads the tree of the fixture window and lists the windows")
def _(run):
    window = run.fixture()
    m = run.mcp()
    err, out, images = m.call("alcove_ui_tree", {"name": run.vm, "window": TITLE})
    rows = lines(out)
    expect(not err and not images and f'Window "{TITLE}"' in rows[0] and any('Button "Send"' in r for r in rows) and any("한글 라벨" in r for r in rows)
           and all(TREE_LINE.fullmatch(r) for r in rows), f"alcove_ui_tree answered error={err} {out!r}")
    err, out, images = m.call("alcove_list_windows", {"name": run.vm})
    wanted = f'{window["id"]} "{TITLE}" {EXE} ({window["pid"]}) '
    mine = [r for r in lines(out) if r.startswith(wanted)]
    expect(not err and not images and len(mine) == 1 and re.fullmatch(re.escape(wanted) + r"-?\d+,-?\d+ \d+x\d+( \[foreground\])?", mine[0]),
           f"alcove_list_windows answered error={err} {out!r}; expected one line starting with {wanted!r}")
    m.close()
    return f"{len(rows)} tree lines; {mine[0]}"


@check("vm.deploy refuses a linked folder, a link below its folder, a foreign folder and the apps root, and marks a folder it deployed to")
def _(run):
    run.prepare_guest()
    flat = run.small_source("alcove-e2e-flat", {"a.txt": "one\n"})
    small = run.small_source("alcove-e2e-small", {"a.txt": "one\n", "sub/inner.txt": "inner\n"})
    for folder in ("junction-target", "nested-target", "foreign"):
        run.call("vm.fs.write", path=f"{GUEST}\\{folder}\\keep.txt", text="keep\n")

    link = GUEST + r"\junction"
    run.junction(link, GUEST + r"\junction-target")
    message = run.refusal("vm.deploy", path=small, guestDir=link)
    expect(message == f"'{link}' is a link in the guest; pass the folder it points to", f"a deploy to a junction failed with {message!r}")
    expect(run.names(GUEST + r"\junction-target") == ["keep.txt"], f"the junction's target holds {run.names(GUEST + chr(92) + 'junction-target')!r} after the refusal")

    nested = GUEST + r"\nested"
    first = run.call("vm.deploy", path=flat, guestDir=nested)
    expect(first["sent"] == ["a.txt"] and first["guestDir"] == nested and "pid" not in first, f"the deploy of one file to a new folder answered {first!r}")
    run.junction(nested + r"\sub", GUEST + r"\nested-target")
    message = run.refusal("vm.deploy", path=small, guestDir=nested)
    expect(message == f"'{nested}\\sub' in the guest is a link; remove it or deploy to another folder", f"a deploy over a junction below the folder failed with {message!r}")
    expect(run.names(GUEST + r"\nested-target") == ["keep.txt"] and run.names(nested, recursive=True) == [MARKER, "a.txt", "sub"],
           f"after the refusal the junction's target holds {run.names(GUEST + chr(92) + 'nested-target')!r} and the folder {run.names(nested, recursive=True)!r}")

    outside = GUEST + r"\outside"
    deployed = run.call("vm.deploy", path=small, guestDir=outside)
    expect(sorted(deployed["sent"]) == ["a.txt", "sub/inner.txt"] and deployed["skipped"] == 0, f"the deploy to a new folder outside {APPS} answered {deployed!r}")
    expect(run.read(outside + "\\" + MARKER) == MARKER_TEXT and run.read(outside + r"\sub\inner.txt") == "inner\n",
           f"{outside} holds {run.names(outside, recursive=True)!r} after the deploy")
    again = run.call("vm.deploy", path=small, guestDir=outside)
    expect(again["sent"] == [] and again["skipped"] == 2, f"a second deploy to the marked folder answered {again!r}")

    foreign = GUEST + r"\foreign"
    message = run.refusal("vm.deploy", path=small, guestDir=foreign)
    expect(message == f"'{foreign}' already holds files that Alcove did not deploy; choose an empty or new folder, or one under {APPS}",
           f"a deploy to a folder with a foreign file failed with {message!r}")
    expect(run.names(foreign, recursive=True) == ["keep.txt"], f"the foreign folder holds {run.names(foreign, recursive=True)!r} after the refusal")

    for spelling in (APPS, "c:/ALCOVE-APPS/"):
        message = run.refusal("vm.deploy", path=small, guestDir=spelling)
        expect(message == f"guestDir '{spelling}' holds every deployed app; pass a folder below it such as {APPS}\\alcove-e2e-small",
               f"a deploy to {spelling!r} failed with {message!r}")

    for path in list(run.junctions):
        expect(run.remove_junction(run.c, path), f"the junction {path} could not be removed with rmdir")
        run.junctions.remove(path)
    expect(run.names(GUEST + r"\junction-target") == ["keep.txt"] and run.names(GUEST + r"\nested-target") == ["keep.txt"],
           "a junction's target lost its file when the junction was removed")
    return "junction as guestDir, junction below the folder, foreign folder and apps root refused; nothing written through a junction; marker read back"


@check("vm.deploy to the folder of the running fixture stops that process and leaves a copy from another folder and the agent running")
def _(run):
    window = run.fixture(fresh=True)
    other_exe = GUEST + "\\other\\" + EXE
    run.call("vm.push_file", 300, path=os.path.join(run.app_source(), EXE), guestPath=other_exe, overwrite=True)
    other = run.launch_fixture(path=other_exe, log=GUEST + r"\other.log")
    expect((other.get("window") or {}).get("title") == TITLE and other["pid"] != window["pid"], f"the copy in another folder started as {other!r}")
    agent = run.agent_pid()
    source = run.app_source()
    extra = os.path.join(source, "version.txt")
    with open(extra, "w") as f:
        f.write("2\n")
    try:
        began = time.monotonic()
        r = run.deploy_fixture()
        took = time.monotonic() - began
    finally:
        os.remove(extra)
    expect(r["sent"] == ["version.txt"] and r["skipped"] == 1 and r["pid"] not in (window["pid"], other["pid"]) and (r.get("window") or {}).get("title") == TITLE,
           f"the deploy over the running fixture answered {r!r}")
    running = {p["pid"]: p["path"] for p in run.own_processes()}
    expect(window["pid"] not in running and r["pid"] in running and other["pid"] in running,
           f"after the deploy the processes from the folders are {running!r}; the stopped one was pid {window['pid']}, the other copy is {other['pid']}")
    status = run.call("vm.status")
    expect(status["tools"] is True and run.agent_pid() == agent and run.exec("'alive'") == "alive",
           f"after the deploy the agent is pid {run.agent_pid()} (before: {agent}) and vm.status reports tools {status.get('tools')!r}")
    left = run.end(run.c, lambda: [p for p in run.own_processes() if p["pid"] == other["pid"]])
    expect(not left, f"the copy in the other folder (pid {other['pid']}) still runs 15 s after vm.process.kill")
    return f"pid {window['pid']} stopped and pid {r['pid']} started in {took:.1f} s; the copy pid {other['pid']} and the agent pid {agent} kept running"


@check("after an agent restart vm.events of a new client receives window.opened without a UI op; since and two clients read the same sequence")
def _(run):
    run.fixture()
    run.end_fixtures()
    old = run.agent_pid()
    run.agent_restarted = True
    expect(run.exec(RESTART_AGENT) == "created=0", "the guest did not start the command that restarts the scheduled task AlcoveAgent")
    second = run.client()
    began = time.monotonic()
    quiet = second.call("vm.events", 60, name=run.vm)
    agent = helper = None
    while helper is None:
        expect(time.monotonic() - began < 120,
               f"120 s after the restart the agent is pid {agent} (before: {old}) and has no UI helper process; "
               "this check needs the agent installed as the scheduled task AlcoveAgent (scripts/test/install-agent.py)")
        time.sleep(0.5)
        try:
            if second.call("vm.status", 60, name=run.vm).get("tools") is not True:
                continue
            listed = run.processes(second)
        except ControlTimeout:
            raise
        except ControlError:
            continue
        agents = [p["pid"] for p in listed if p["name"].lower() == "alcove-agent.exe"]
        if len(agents) != 1 or agents[0] == old:
            continue
        agent = agents[0]
        helpers = [p["pid"] for p in listed if p["ppid"] == agent and r"uia\bootstrap.ps1" in (p["command"] or "").lower()]
        helper = helpers[0] if helpers else None
    woke = time.monotonic() - began
    time.sleep(3)
    launched = second.call("vm.app.launch", 120, name=run.vm, path=APP_EXE, args=["--log", FIXTURE_LOG], waitWindow=0)
    run.fixture_pids.add(launched["pid"])
    expect("window" not in launched and "windowTimedOut" not in launched, f"vm.app.launch with waitWindow 0 answered {launched!r}")
    opened = second.call("vm.wait_for", 120, name=run.vm, timeout=30,
                         conditions=[{"type": "event", "event": "window.opened", "titleContains": TITLE, "since": launched["eventSeq"]}])
    expect(opened["matched"] == 0 and opened["detail"]["window"]["pid"] == launched["pid"] and opened["detail"]["seq"] > launched["eventSeq"] >= quiet["next"],
           f"with no window or element op since the agent restarted, vm.wait_for event window.opened after eventSeq {launched['eventSeq']} answered {opened!r}")

    run.focus()
    clicked = run.click("Dialog")
    since = clicked["eventSeq"]
    there = run.wait_for([{"type": "ui_exists", "window": DIALOG, "role": "Button", "name": "OK"}], timeout=15)
    expect(there["matched"] == 0, f"the dialog did not open: {there!r}")
    time.sleep(1)
    expect(run.exec("'moved'") == "moved", "vm.exec did not run")
    late = run.wait_for([{"type": "event", "event": "dialog.opened"}], timeout=2)
    expect(late["matched"] == -1 and "problems" not in late, f"after a vm.exec, vm.wait_for event dialog.opened without since answered {late!r}")
    exact = run.wait_for([{"type": "event", "event": "dialog.opened", "since": since}], timeout=10)
    expect(exact["matched"] == 0 and exact["detail"]["seq"] > since and exact["detail"]["window"]["title"] == DIALOG and exact["waited"] < 2,
           f"vm.wait_for event dialog.opened since {since} answered {exact!r}")
    further = run.wait_for([{"type": "event", "event": "dialog.opened", "since": exact["detail"]["seq"]}], timeout=1)
    expect(further["matched"] == -1, f"vm.wait_for event dialog.opened since the matched event {exact['detail']['seq']} answered {further!r}")

    mark = run.call("vm.events")["next"]
    run.close_dialog()
    gone = run.wait_for([{"type": "event", "event": "window.closed", "titleContains": DIALOG, "since": mark}], timeout=15)
    expect(gone["matched"] == 0, f"vm.wait_for event window.closed since {mark} answered {gone!r}")
    time.sleep(1.5)
    mine, theirs = run.call("vm.events", since=mark), second.call("vm.events", 60, name=run.vm, since=mark)
    shared = min(len(mine["events"]), len(theirs["events"]))
    expect(shared >= 1 and mine["events"][:shared] == theirs["events"][:shared] and mine["first"] == theirs["first"],
           f"two clients read different events since {mark}: {[(e['seq'], e['name']) for e in mine['events']]!r} and "
           f"{[(e['seq'], e['name']) for e in theirs['events']]!r}; first {mine['first']!r} and {theirs['first']!r}")
    seqs = [e["seq"] for e in theirs["events"]]
    expect(seqs == list(range(mark + 1, mark + 1 + len(seqs))) and theirs["next"] == seqs[-1]
           and any(e["name"] == "window.closed" and e["window"]["title"] == DIALOG for e in theirs["events"]),
           f"vm.events since {mark} returned the sequence numbers {seqs!r} with next {theirs['next']!r}")
    everything = second.call("vm.events", 60, name=run.vm)
    beyond = second.call("vm.events", 60, name=run.vm, since=everything["next"] + 1000)
    expect(everything["events"][0]["seq"] == everything["first"] and beyond["first"] == everything["first"]
           and [e["seq"] for e in beyond["events"]][:len(everything["events"])] == [e["seq"] for e in everything["events"]],
           f"vm.events with a since above next returned {len(beyond['events'])} events from {beyond['first']!r}; without since there are "
           f"{len(everything['events'])} from {everything['first']!r}")
    empty = second.call("vm.events", 60, name=run.vm, since=beyond["next"])
    expect(empty["events"] == [] or empty["events"][0]["seq"] == beyond["next"] + 1, f"vm.events since its own next returned {empty!r}")
    message = run.refusal("vm.events", since=-1)
    expect(message == "since must be an integer of 0 or more; pass the next value of an earlier vm.events reply", f"vm.events since -1 failed with {message!r}")
    return (f"agent pid {old} replaced by {agent}, helper pid {helper} seen {woke:.1f} s after the restart without a UI op; window.opened as event "
            f"{opened['detail']['seq']}; dialog.opened found with since {since} after the baseline had moved; events {seqs[0]} to {seqs[-1]} equal for two clients")


@check("vm.wait_for holds on ui_exists, ui_gone, ui_enabled and window_title, runs out of time without problems, and reports a missing window as designed")
def _(run):
    run.fixture(fresh=True)
    run.focus()
    began = time.monotonic()
    never = run.wait_for([{"type": "ui_exists", "window": TITLE, "name": MISSING_NAME}], timeout=3)
    took = time.monotonic() - began
    expect(never["matched"] == -1 and "problems" not in never and "type" not in never and 3 <= never["waited"] <= 3 + TICK_S + 0.1 and took < 3 + TICK_S + 1,
           f"ui_exists for an element that never appears answered {never!r} after {took:.2f} s with timeout 3")

    missing = {"window": MISSING_WINDOW, "role": "Button"}
    for kind in ("ui_exists", "ui_enabled"):
        r = run.wait_for([{"type": kind, **missing}], timeout=2)
        expect(r["matched"] == -1 and "problems" not in r and r["waited"] <= 2 + TICK_S + 0.1, f"{kind} in a window that does not exist answered {r!r}")
    r = run.wait_for([{"type": "ui_gone", **missing}], timeout=5)
    expect(r["matched"] == 0 and r["type"] == "ui_gone" and r["waited"] < 1, f"ui_gone in a window that does not exist answered {r!r}")
    r = run.wait_for([{"type": "ui_text_stable", "window": MISSING_WINDOW, "role": "Document"}], timeout=2)
    problems = r.get("problems") or [{}]
    expect(r["matched"] == -1 and len(problems) == 1 and problems[0].get("condition") == 0 and problems[0].get("type") == "ui_text_stable"
           and problems[0].get("failures", 0) >= 1 and problems[0].get("error", "").startswith(f'no window has "{MISSING_WINDOW}" in its title; '),
           f"ui_text_stable in a window that does not exist answered {r!r}")
    r = run.wait_for([{"type": "window_title", "contains": MISSING_WINDOW}], timeout=2)
    expect(r["matched"] == -1 and "problems" not in r, f"window_title for a title no window has answered {r!r}")

    send = {"window": TITLE, "role": "Button", "name": "Send"}
    run.call("vm.ui.type", selector={"window": TITLE, "role": "Edit", "name": "Message"}, text="wait", clear=True)
    run.click("Send")
    busy = run.element(role="Button", name="Send")
    expect("disabled" in busy["flags"], f"the Send button has the flags {busy['flags']!r} right after the click")
    enabled = run.wait_for([{"type": "ui_enabled", **send}], timeout=30)
    expect(enabled["matched"] == 0 and enabled["type"] == "ui_enabled" and "disabled" not in enabled["detail"]["flags"] and enabled["waited"] >= 1,
           f"ui_enabled for the Send button answered {enabled!r}")

    run.click("Titles")
    numbered = run.wait_for([{"type": "window_title", "regex": r"^Alcove Fixture \d+$"}], timeout=10)
    expect(numbered["matched"] == 0 and re.fullmatch(r"Alcove Fixture \d+", numbered["detail"]["title"]) and set(numbered["detail"]) == {"id", "title", "foreground"},
           f"window_title with a regex for the numbered title answered {numbered!r}")
    base = run.wait_for([{"type": "window_title", "regex": "^Alcove Fixture$"}, {"type": "window_title", "contains": MISSING_WINDOW}], timeout=30)
    expect(base["matched"] == 0 and base["detail"]["title"] == TITLE and base["waited"] >= 1, f"window_title for the base title answered {base!r}")

    run.click("Dialog")
    ok = {"window": DIALOG, "role": "Button", "name": "OK"}
    there = run.wait_for([{"type": "ui_exists", "window": TITLE, "name": MISSING_NAME}, {"type": "ui_exists", **ok}], timeout=15)
    expect(there["matched"] == 1 and there["type"] == "ui_exists" and there["detail"]["name"] == "OK" and there["detail"]["role"] == "Button",
           f"ui_exists for the dialog's OK button answered {there!r}")
    ref = there["detail"]["ref"]
    still = run.wait_for([{"type": "ui_gone", "ref": ref}], timeout=2)
    expect(still["matched"] == -1 and "problems" not in still, f"ui_gone for the OK button of the open dialog answered {still!r}")
    run.call("vm.ui.click", ref=ref)
    gone = run.wait_for([{"type": "ui_gone", "ref": ref}], timeout=15)
    expect(gone["matched"] == 0 and gone["type"] == "ui_gone", f"ui_gone for the ref of the closed dialog's button answered {gone!r}")
    closed = run.wait_for([{"type": "ui_gone", **ok}], timeout=15)
    expect(closed["matched"] == 0, f"ui_gone for the selector of the closed dialog's button answered {closed!r}")
    return (f"never: waited {never['waited']} s for timeout 3; ui_enabled after {enabled['waited']} s; title {numbered['detail']['title']!r}, "
            f"base title after {base['waited']} s; OK button {ref} exists after {there['waited']} s and is gone after the click")


@check("while the UI helper serves a slow search, a click with observe summary returns within its budget with uiError, and the click arrives")
def _(run):
    run.fixture()
    launched = run.launch("mmc", path="mmc.exe", args=["services.msc"], waitWindow=60)
    console = launched.get("window") or {}
    expect(console.get("title") == CONSOLE_TITLE and console["pid"] in run.started("mmc"), f"vm.app.launch of the Services console answered {launched!r}")
    miss = {"window": console["id"], "name": MISSING_NAME}
    time.sleep(2)
    began = time.monotonic()
    found = run.call("vm.ui.find", 300, selector=miss)
    slow = time.monotonic() - began
    expect(found["nodes"] == [], f"vm.ui.find for a name nothing has returned {found!r}")
    if slow < SLOW_SEARCH_S:
        left = run.end(run.c, lambda: run.started("mmc"))
        expect(not left, f"the console processes {sorted(left)} still run 15 s after vm.process.kill")
        return f"skipped: the search of the Services console took {slow:.1f} s, less than the {SLOW_SEARCH_S} s this check needs"

    run.focus()
    same = run.call("vm.ui.find", selector={"window": TITLE, "role": "Button", "name": "Same", "index": 0})["nodes"][0]
    x, y = centre(same)
    before = len(run.log())
    second = run.client()
    searching = second.send("vm.ui.find", name=run.vm, selector=miss)
    time.sleep(0.5)
    began = time.monotonic()
    clicked = run.call("vm.mouse.click", x=x, y=y, observe="summary")
    took = time.monotonic() - began
    returned = time.monotonic()
    seen = clicked["observation"]
    expect(seen.get("uiError") == BUSY_FACTS and "foreground" not in seen and "focused" not in seen and "tree" not in seen and isinstance(seen.get("events"), list),
           f"the observation of a click while the helper searches is {seen!r}")
    expect(took <= BUSY_CLICK_LIMIT_S, f"the click with observe summary took {took:.1f} s while the helper was busy, more than {BUSY_CLICK_LIMIT_S} s")
    added = run.log_grows(before, " same 1")
    reply = second.wait(searching, 120)
    expect(reply.get("ok") is True and reply["nodes"] == [] and second.arrival(searching)[1] > returned,
           f"the search answered {reply!r} {second.arrival(searching)[1] - returned:.1f} s after the click returned; it must still run when the click returns")
    listed = run.call("vm.ui.find", selector={"window": TITLE, "role": "Button", "name": "Same"})["nodes"]
    expect(len(listed) == 2, f"after the search the helper returned {len(listed)} Same buttons")
    left = run.end(run.c, lambda: run.started("mmc"))
    expect(not left, f"the console processes {sorted(left)} still run 15 s after vm.process.kill")
    return (f"a search of the Services console without a match takes {slow:.1f} s; the click returned after {took:.1f} s with uiError, "
            f"{second.arrival(searching)[1] - returned:.1f} s before the search; the log gained {added!r}")


@check("text typed into the password field is in no result, the trace of a recording holds the mask, and a saved script reads it from variables")
def _(run):
    run.fixture(fresh=True)
    run.focus()
    secret = {"window": TITLE, "role": "Edit", "name": "Secret"}
    before = len(run.log())
    typed = run.call("vm.ui.type", selector=secret, text=SECRET, clear=True, observe="ui")
    node = typed["node"]
    expect("password" in node["flags"] and node["name"] == "" and "value" not in node, f"vm.ui.type into the password field answered the node {node!r}")
    run.log_grows(before, f" secret {len(SECRET)}")
    lengths = [l.rsplit(" ", 1)[1] for l in run.log()[before:] if " secret " in l]
    expect(lengths[-1] == str(len(SECRET)), f"the fixture logged secret lengths {lengths!r}; {len(SECRET)} characters were typed")
    replies = {"vm.ui.type": typed, "vm.ui.tree": run.call("vm.ui.tree", window=TITLE, filter="all"),
               "vm.ui.find": run.call("vm.ui.find", selector={"window": TITLE, "automationId": node["aid"]}),
               "vm.window.list": run.call("vm.window.list"), "vm.events": run.call("vm.events"),
               "vm.mouse.move": run.call("vm.mouse.move", x=node["x"] + 5, y=node["y"] + 5, observe="ui"),
               "vm.find_text": run.call("vm.find_text", languages=["en-US"])}
    leaked = [op for op, reply in replies.items() if SECRET in json.dumps(reply, ensure_ascii=False)]
    expect(not leaked, f"the typed text is in the reply of {leaked!r}")
    expect("password" in replies["vm.ui.find"]["nodes"][0]["flags"] and f'Edit "" ({node["x"]},{node["y"]}' in typed["observation"]["tree"],
           f"the password field is not in the results as a password element: {replies['vm.ui.find']!r}")
    message = run.refusal("vm.ui.text", selector=secret)
    expect(message == PASSWORD_SENTENCE, f"vm.ui.text of the password field failed with {message!r}")

    folder = os.path.join(run.host_dir("recordings"), "password")
    run.recording = True
    started = run.call("vm.record.start", dir=folder, video=False)
    expect(started["dir"] == folder, f"vm.record.start answered {started!r}")
    run.call("vm.ui.type", selector=secret, text=SECRET, clear=True)
    px, py = node["x"] + node["w"] - 20, node["y"] + node["h"] // 2
    run.call("vm.mouse.click", x=px, y=py)
    run.call("vm.type", text=SECOND_SECRET)
    send = run.element(role="Button", name="Send")
    sx, sy = centre(send)
    run.call("vm.mouse.click", x=sx, y=sy)
    stopped = run.call("vm.record.stop")
    run.recording = False
    expect(stopped["dir"] == folder and stopped["ops"] >= 4 and stopped["writeErrors"] == 0, f"vm.record.stop answered {stopped!r}")
    with open(stopped["trace"], encoding="utf-8") as f:
        trace = f.read()
    expect(SECRET not in trace and SECOND_SECRET not in trace, "the trace of the recording holds text typed into the password field")
    entries = [json.loads(l) for l in lines(trace)]
    by_op = {}
    for e in entries:
        by_op.setdefault(e["op"], []).append(e)
    expect([e["params"]["text"] for e in by_op.get("vm.ui.type", [])] == [MASK] and [e["params"]["text"] for e in by_op.get("vm.type", [])] == [MASK],
           f"the trace holds the typed texts {[(e['op'], e['params'].get('text')) for e in entries if 'text' in e['params']]!r}")
    clicks = by_op.get("vm.mouse.click", [])
    aimed = [e.get("target") or {} for e in clicks]
    expect(len(clicks) == 2 and aimed[0].get("password") is True and aimed[0].get("role") == "Edit" and aimed[0].get("name") == ""
           and (by_op["vm.type"][0].get("target") or {}).get("password") is True,
           f"the trace names the targets {aimed!r} for the clicks and {by_op['vm.type'][0].get('target')!r} for vm.type")
    expect(aimed[1].get("role") == "Button" and aimed[1].get("name") == "Send" and aimed[1].get("window") == TITLE
           and aimed[1].get("rect") == {k: send[k] for k in ("x", "y", "w", "h")} and aimed[1].get("byName") == {"matches": 1, "index": 0},
           f"the trace names the target {aimed[1]!r} for the click on Send at {sx},{sy}; vm.ui.find reports {send!r}")

    script_path = os.path.join(run.host_dir("recordings"), "password.json")
    saved = run.call("script.save", dir=folder, path=script_path)
    with open(script_path, encoding="utf-8") as f:
        text = f.read()
    script = json.loads(text)
    expect(SECRET not in text and SECOND_SECRET not in text and MASK not in text and stat.S_IMODE(os.stat(script_path).st_mode) == 0o600,
           f"the saved script holds typed text or the mask, or has the mode {stat.S_IMODE(os.stat(script_path).st_mode):o}")
    steps = {(s["op"], json.dumps(s["params"], sort_keys=True)) for s in script["steps"]}
    texts = [s["params"]["text"] for s in script["steps"] if "text" in s["params"]]
    expect(texts == ["${password}", "${password2}"] and saved["steps"] == len(script["steps"])
           and sum("variable 'password" in w for w in saved.get("warnings", [])) == 2,
           f"the saved script types {texts!r} in {saved['steps']} steps with the warnings {saved.get('warnings')!r}")
    pressed = [s for s in script["steps"] if s["op"] == "vm.ui.click"]
    selector = pressed[0]["params"].get("selector") if len(pressed) == 1 else None
    expect(selector == {"window": TITLE, "role": "Button", "automationId": send["aid"]} and pressed[0]["params"].get("altSelector") == {"window": TITLE, "role": "Button", "name": "Send"},
           f"the click on Send became {pressed!r} in the saved script ({len(steps)} distinct steps)")
    shutil.rmtree(folder)
    os.remove(script_path)
    return (f"{len(replies)} replies without the text; fixture logged {lengths[-1]} characters; trace of {stopped['ops']} ops with {MASK} twice; "
            f"script of {saved['steps']} steps with ${{password}}, ${{password2}} and vm.ui.click {selector!r}")


@check("the MCP server finds and clicks an element, launches an app, reads events, waits for an element and marks a screenshot")
def _(run):
    window = run.fixture(fresh=True)
    run.focus()
    m = run.mcp()
    err, out, images = m.call("alcove_ui_find", {"name": run.vm, "window": TITLE, "role": "Button", "element_name": "Send"})
    rows = lines(out)
    found = re.fullmatch(r'\[(e\d+)\] Button "Send" \((\d+),(\d+) (\d+)x(\d+)\)', rows[1]) if len(rows) == 2 else None
    expect(not err and not images and rows[0] == "1 matches" and found, f"alcove_ui_find answered error={err} {out!r}")
    ref = found.group(1)
    box = {"x": int(found.group(2)), "y": int(found.group(3)), "w": int(found.group(4)), "h": int(found.group(5))}

    err, out, images = m.call("alcove_ui_click", {"name": run.vm, "ref": ref})
    rows = lines(out)
    head = re.fullmatch(rf'clicked left {ref} Button "Send" at \((\d+), (\d+)\)', rows[0])
    expect(not err and not images and head and inside({"x": int(head.group(1)), "y": int(head.group(2)), "w": 1, "h": 1}, box)
           and re.fullmatch(r"eventSeq \d+", rows[1]) and rows[2] in ("screen settled", "screen still changing after 2000 ms")
           and f"foreground: {TITLE}" in rows, f"alcove_ui_click with the default observe answered error={err} {out!r}")
    since = int(rows[1].split()[1])

    run.track("charmap")
    err, out, images = m.call("alcove_launch_app", {"name": run.vm, "path": "charmap.exe"})
    rows = lines(out)
    started = re.fullmatch(r"started pid (\d+)", rows[0])
    expect(not err and started and len(rows) >= 2 and re.fullmatch(rf'0x[0-9a-f]+ "{CHARMAP_TITLE}" charmap\.exe \(\d+\) -?\d+,-?\d+ \d+x\d+.*', rows[1]),
           f"alcove_launch_app answered error={err} {out!r}")
    expect(int(started.group(1)) in run.started("charmap"), f"alcove_launch_app reports pid {started.group(1)}; the Character Map processes of this run are {sorted(run.started('charmap'))}")

    err, out, images = m.call("alcove_wait_for", {"name": run.vm, "timeout_s": 20,
                                                  "conditions": [{"type": "ui_exists", "window": CHARMAP_TITLE, "role": "Button", "name": "Select"}]})
    expect(not err and re.match(r"matched condition 0 \(ui_exists\) after [\d.]+ s: \{", out) and '"name":"Select"' in out.replace(" ", ""),
           f"alcove_wait_for with a ui_exists condition answered error={err} {out!r}")

    err, out, images = m.call("alcove_events", {"name": run.vm, "since": since})
    rows = lines(out)
    expect(not err and re.fullmatch(r"\d+ events", rows[0]) and re.fullmatch(r"next: \d+", rows[-1])
           and any(re.fullmatch(rf'\d+ \S+ window\.opened "{CHARMAP_TITLE}"', r) for r in rows), f"alcove_events since {since} answered error={err} {out!r}")

    left = run.end(run.c, lambda: run.started("charmap"))
    expect(not left, f"the Character Map processes {sorted(left)} still run 15 s after vm.process.kill")
    run.focus()
    err, out, images = m.call("alcove_screenshot", {"name": run.vm, "window": TITLE, "marks": True})
    rows = lines(out)
    legend = rows.index("marked elements:") if "marked elements:" in rows else -1
    marked = [r for r in rows[legend + 1:] if re.fullmatch(rf'\d+: e\d+ Button "Send" \({box["x"]},{box["y"]} {box["w"]}x{box["h"]}\)', r)]
    expect(not err and legend >= 1 and len(marked) == 1 and len(images) == 1 and images[0]["mimeType"] == "image/png"
           and png_image(base64.b64decode(images[0]["data"]))[:2] == (window["w"], window["h"]),
           f"alcove_screenshot with marks answered error={err} {out!r} with {len(images)} images; the window is {window['w']}x{window['h']}")
    m.close()
    return f"found {ref}; clicked; Character Map pid {started.group(1)}; events since {since}; {marked[0]}"


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
        if any(part in w["title"] for part in (TITLE, DIALOG, EDGE_TITLE, CHARMAP_TITLE)) or (w["title"] == CONSOLE_TITLE and w["process"].lower() == "mmc.exe"):
            found.append(f"the window {w['title']!r} of {w['process']} (pid {w['pid']})")
    for p in client.call("vm.process.list", 60, name=vm, filter="alcove-fixture")["processes"]:
        found.append(f"the process {p['name']} (pid {p['pid']})")
    if client.call("vm.record.status", 60, name=vm).get("recording") is True:
        found.append("a recording of the VM")
    return found, answers[2] == "True"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}

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
    run = Run(client, args.vm, apps_existed)

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
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
                print(failed, flush=True)
                break
            print(f"PASS {n} {title}" + (f" ({note})" if note else ""), flush=True)
    except (KeyboardInterrupt, SystemExit):
        interrupted = True
        raise
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if interrupted:
            print("interrupted; restoring the guest...", flush=True)
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
