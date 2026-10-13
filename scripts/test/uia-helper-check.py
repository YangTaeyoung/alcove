#!/usr/bin/env python3
"""Checks the agent's win.*, ui.* and app.launch operations and its window
events against a running Windows VM.

Talks docs/agent-protocol.md directly on the forwarded agent port and drives
Notepad, File Explorer and the fixture app (build/alcove-fixture-windows-arm64.exe,
built by scripts/test/all.sh) in the guest. Needs the agent installed with
--allow-exec (scripts/test/install-agent.py) and neither Notepad nor the
fixture running. Each check prints `PASS <n> <title>` or `FAIL <n>: <reason>`;
the script exits 1 when a check failed. Files go under C:\\alcove-e2e.

Before Notepad starts, the files of its saved tabs are copied to a temporary
directory on the host, whose path is printed. However the run ends, a second
connection ends the Notepad and fixture processes the script started, puts
Notepad's saved tabs back, closes the File Explorer window the script opened
and deletes the files it wrote. The host copy is deleted after the tabs were
put back; when that fails it stays and the script prints how to restore them.

Usage: uia-helper-check.py [--agent-port N] [--only N[,N...]] [--kill-helper]

--kill-helper ends the running UI helper process first, twice, and requires
that a ref of the first replacement is unknown to the second; the checks then
run against the helper the agent started for the next operation.
"""
import argparse, base64, hashlib, json, ntpath, os, re, select, shutil, signal, socket, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURE_BUILD = os.path.join(ROOT, "build", "alcove-fixture-windows-arm64.exe")
E2E = r"C:\alcove-e2e"
FIXTURE = E2E + r"\alcove-fixture.exe"
FIXTURE_TITLE = "Alcove Fixture"
HELD_TITLE = "Alcove Fixture held"
MESSAGE = '안녕 "fixture"'
SECRET = "hunter2-비밀-7Q"
CHUNK = 262144

BASE = r"C:\alcove-e2e\uia"
NOTE_NAME = "alcove-uia-check.txt"
NOTE = BASE + "\\" + NOTE_NAME
NOTE_TEXT = 'first line\r\n둘째 줄 "quoted"'
SHOWN_TEXT = 'first line\n둘째 줄 "quoted"'
NOTEPAD_STATE = "~/AppData/Local/Packages/Microsoft.WindowsNotepad_8wekyb3d8bbwe/LocalState"
FOLDER = r"C:\Windows\System32"
FOLDER_ITEM = "notepad.exe"
ITEM_NAMES = (FOLDER_ITEM, ntpath.splitext(FOLDER_ITEM)[0])
REF = re.compile(r"e[1-9][0-9]*")
WINDOW_ID = re.compile(r"0x[0-9a-f]+")
FRAME_PS = ("$v = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1; "
            '"frame=$($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution)"')
NODE_KEYS = {"ref", "depth", "role", "name", "x", "y", "w", "h", "flags"}
NODE_FLAGS = {"focused", "disabled", "offscreen", "selected", "checked", "expanded", "collapsed", "password"}
WINDOW_KEYS = {"id", "title", "pid", "process", "class", "x", "y", "w", "h", "state", "foreground", "responding", "modal"}
FIXTURE_LOG = BASE + r"\fixture.log"
CRASH_CODE = 3221227010
WER_DIRS = (r"C:\ProgramData\Microsoft\Windows\WER\ReportArchive", r"C:\ProgramData\Microsoft\Windows\WER\ReportQueue")
HELPER_EXITED = "UI helper exited; retry"


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


class Agent:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""
        self.next_id = 0
        self.events = []
        self.hello = self._next(10)
        expect(self.hello and self.hello.get("t") == "hello", f"expected hello, got {self.hello!r}")
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

    def _file(self, m):
        """Answers a ping and keeps an event with its arrival time."""
        if m.get("t") == "ping":
            self.send({"t": "pong"})
        elif m.get("t") == "ev":
            m["at"] = time.time()
            self.events.append(m)

    def ask(self, op, timeout=150, **params):
        """Sends a request and returns its reply as the agent sent it; answers pings and keeps events while waiting."""
        self.next_id += 1
        rid = self.next_id
        self.send({"t": "req", "id": rid, "op": op, **params})
        end = time.time() + timeout
        while True:
            m = self._next(max(0, end - time.time()))
            expect(m is not None, f"no reply to {op} within {timeout} s")
            if m.get("t") == "res" and m.get("id") == rid:
                return m
            self._file(m)

    def event(self, name, pick, what, timeout=10):
        """Returns the first kept or arriving event of that name for which pick(event) is true."""
        end = time.time() + timeout
        seen = 0
        while True:
            for e in self.events[seen:]:
                if e.get("name") == name and pick(e):
                    return e
            seen = len(self.events)
            m = self._next(max(0, end - time.time()))
            expect(m is not None, f"no {name} event {what} within {timeout} s; events since the check began: "
                                  f"{[(e.get('name'), (e.get('window') or {}).get('title', e.get('pid'))) for e in self.events]!r}")
            self._file(m)

    def call(self, op, timeout=150, **params):
        """Sends a request and returns its result; a failed reply fails the check."""
        res = self.ask(op, timeout, **params)
        expect(res.get("ok") is True, f"{op} failed: {res.get('error')}")
        return res

    def pump(self, seconds):
        """Reads and keeps events for the given time."""
        end = time.time() + seconds
        while True:
            left = end - time.time()
            if left <= 0:
                return
            m = self._next(left)
            if m is not None:
                self._file(m)


def check_node(n, where):
    """Fails unless n has the fields and value types of a node object."""
    expect(isinstance(n, dict) and NODE_KEYS <= set(n), f"{where}: node lacks fields: {n!r}")
    expect(set(n) <= NODE_KEYS | {"value", "aid"}, f"{where}: node has unknown fields: {n!r}")
    expect(isinstance(n["ref"], str) and REF.fullmatch(n["ref"]), f"{where}: ref is {n['ref']!r}")
    expect(all(type(n[k]) is int for k in ("depth", "x", "y", "w", "h")), f"{where}: depth or rectangle is not whole numbers: {n!r}")
    expect(isinstance(n["role"], str) and n["role"] and not n["role"].startswith("ControlType."), f"{where}: role is {n['role']!r}")
    expect(isinstance(n["name"], str), f"{where}: name is {n['name']!r}")
    expect(isinstance(n["flags"], list) and set(n["flags"]) <= NODE_FLAGS, f"{where}: flags are {n['flags']!r}")


def check_window(w, where):
    """Fails unless w has the fields and value types of a window object."""
    expect(isinstance(w, dict) and set(w) == WINDOW_KEYS, f"{where}: window fields are {sorted(w) if isinstance(w, dict) else w!r}")
    expect(isinstance(w["id"], str) and WINDOW_ID.fullmatch(w["id"]), f"{where}: id is {w['id']!r}")
    expect(all(type(w[k]) is int for k in ("pid", "x", "y", "w", "h")), f"{where}: pid or rectangle is not whole numbers: {w!r}")
    expect(all(isinstance(w[k], str) for k in ("title", "process", "class")), f"{where}: title, process or class is not text: {w!r}")
    expect(w["state"] in ("normal", "minimized", "maximized"), f"{where}: state is {w['state']!r}")
    expect(all(type(w[k]) is bool for k in ("foreground", "responding", "modal")), f"{where}: foreground, responding or modal is not a boolean: {w!r}")


class Run:
    def __init__(self, agent):
        self.a = agent
        self.frame = None
        self.notepad_before = None
        self.notepad_state = None
        self.notepad_copy = None
        self.notepad_window = None
        self.document = None
        self.document_role = None
        self.explorer_before = None
        self.explorer_window = None
        self.fixture_pushed = False
        self.fixture_pids = []
        self.fixture = None
        self.wer_since = None

    def windows(self):
        return self.a.call("win.list")["windows"]

    def wait_window(self, pick, what, timeout=30):
        """Polls win.list until pick(window) is true for one window and returns it."""
        end = time.time() + timeout
        while True:
            found = [w for w in self.windows() if pick(w)]
            if found:
                return found[0]
            expect(time.time() < end, f"no {what} appeared in win.list within {timeout} s")
            time.sleep(0.3)

    def read_file(self, path):
        data, off = b"", 0
        while True:
            r = self.a.call("fs.read", path=path, offset=off)
            piece = base64.b64decode(r["data"])
            data, off = data + piece, off + len(piece)
            if r["eof"] or not piece:
                return data

    def snapshot(self, root):
        """Copies the files under root to a new temporary directory on the host and
        returns (the directory, the relative names), or (the directory, None) when
        root does not exist in the guest."""
        copy = tempfile.mkdtemp(prefix="alcove-notepad-state-")
        try:
            if not self.a.call("fs.stat", path=root)["exists"]:
                return copy, None
            entries = self.a.call("fs.list", path=root, recursive=True)["entries"]
            names = [e["name"] for e in entries if not e["dir"]]
            for name in names:
                target = os.path.join(copy, *name.split("/"))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as f:
                    f.write(self.read_file(root + "/" + name))
            return copy, names
        except BaseException:
            shutil.rmtree(copy, ignore_errors=True)
            raise

    def notepad_pids(self):
        return {p["pid"] for p in self.a.call("proc.list", name="notepad")["procs"]}

    def push_fixture(self):
        """Writes the fixture build to FIXTURE unless the guest already holds those bytes."""
        expect(os.path.exists(FIXTURE_BUILD), f"missing {FIXTURE_BUILD}; build it with scripts/test/all.sh")
        data = open(FIXTURE_BUILD, "rb").read()
        digest = hashlib.sha256(data).hexdigest()
        self.fixture_pushed = True
        st = self.a.call("fs.stat", path=FIXTURE, sha256=True)
        if st["exists"] and st.get("sha256") == digest:
            return
        for off in range(0, len(data), CHUNK):
            self.a.call("fs.write", path=FIXTURE, offset=off, truncate=off == 0, mkdirs=True,
                        data=base64.b64encode(data[off:off + CHUNK]).decode())
        st = self.a.call("fs.stat", path=FIXTURE, sha256=True)
        expect(st.get("sha256") == digest, f"{FIXTURE} has SHA-256 {st.get('sha256')!r} after the upload, the build has {digest}")

    def launch_fixture(self):
        """Starts the fixture through app.launch and returns the reply."""
        expect(self.a.call("proc.list", name="alcove-fixture")["procs"] == [],
               "alcove-fixture.exe runs already; end it in the guest before this check")
        self.push_fixture()
        r = self.a.call("app.launch", path=FIXTURE, args=["--log", FIXTURE_LOG])
        expect(type(r.get("pid")) is int and r["pid"] > 0, f"app.launch returned pid {r.get('pid')!r}")
        self.fixture_pids.append(r["pid"])
        return r

    def fixture_log(self):
        return self.read_file(FIXTURE_LOG).decode("utf-8", "replace").splitlines()


def restore(a, root, copy, names):
    """Makes the files under root equal to the host copy: writes the copied files
    and deletes every other file; with names None it deletes root."""
    if names is None:
        a.call("fs.delete", path=root, recursive=True)
        return
    entries = a.call("fs.list", path=root, recursive=True)["entries"]
    now = {e["name"] for e in entries if not e["dir"]}
    for name in now - set(names):
        a.call("fs.delete", path=root + "/" + name)
    for name in names:
        with open(os.path.join(copy, *name.split("/")), "rb") as f:
            a.call("fs.write", path=root + "/" + name, truncate=True, mkdirs=True, data=base64.b64encode(f.read()).decode())


def explorer_windows(a):
    return {w["id"] for w in a.call("win.list")["windows"] if w["class"] == "CabinetWClass"}


def close_explorer(a, ids):
    """Closes the File Explorer windows with the given window ids."""
    if not ids:
        return
    handles = ",".join(str(int(i, 16)) for i in ids)
    a.call("exec.run", cmd=f"$ids = @({handles}); (New-Object -ComObject Shell.Application).Windows() | "
                           "Where-Object { $ids -contains [int64]$_.HWND } | ForEach-Object { $_.Quit() }")
    end = time.time() + 10
    while explorer_windows(a) & set(ids) and time.time() < end:
        time.sleep(0.3)


def by_identity(nodes):
    """Returns {(role, name, automation id): ref} for the nodes whose triple occurs once."""
    seen = {}
    for n in nodes:
        seen.setdefault((n["role"], n["name"], n.get("aid")), []).append(n["ref"])
    return {k: refs[0] for k, refs in seen.items() if len(refs) == 1}


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


@check("win.list shows the Notepad window with its rectangle inside the frame")
def _(a, run):
    expect(a.call("proc.list", name="notepad")["procs"] == [], "notepad.exe runs already; close it in the guest before this check")
    out = a.call("exec.run", cmd=FRAME_PS)["stdout"]
    m = re.search(r"frame=(\d+)x(\d+)", out)
    expect(m, f"the guest did not report its frame size: {out!r}")
    run.frame = (int(m.group(1)), int(m.group(2)))
    run.notepad_copy, run.notepad_state = run.snapshot(NOTEPAD_STATE)
    print(f"Notepad's saved tabs are copied to {run.notepad_copy} on the host", flush=True)
    a.call("fs.write", path=NOTE, mkdirs=True, truncate=True, data=base64.b64encode(NOTE_TEXT.encode()).decode())
    run.notepad_before = run.notepad_pids()
    a.call("exec.start", shell="none", argv=["notepad.exe", NOTE])
    w = run.wait_window(lambda w: NOTE_NAME in w["title"], f"window with {NOTE_NAME} in its title")
    for each in run.windows():
        check_window(each, "win.list")
    expect(w["process"].lower() == "notepad.exe" and w["pid"] > 0 and w["class"], f"process, pid or class are wrong: {w!r}")
    expect(w["state"] != "minimized" and w["responding"] is True and w["modal"] is False, f"state, responding or modal are wrong: {w!r}")
    fw, fh = run.frame
    expect(w["w"] > 0 and w["h"] > 0, f"the rectangle is empty: {w!r}")
    expect(w["x"] >= 0 and w["y"] >= 0 and w["x"] + w["w"] <= fw and w["y"] + w["h"] <= fh,
           f"the rectangle {w['x']},{w['y']} {w['w']}x{w['h']} is not inside the {fw}x{fh} frame")
    run.notepad_window = w
    return f"{w['id']} {w['title']!r} at {w['x']},{w['y']} {w['w']}x{w['h']} in {fw}x{fh}, foreground {w['foreground']}"


@check("ui.tree of Notepad has a document node, at most 300 nodes and the same refs on a second call")
def _(a, run):
    expect(run.notepad_window, "check 1 did not find the Notepad window")
    wid = run.notepad_window["id"]
    end = time.time() + 15
    while True:
        r = a.call("ui.tree", window=wid)
        docs = [n for n in r["nodes"] if n["role"] in ("Document", "Edit")]
        if docs or time.time() > end:
            break
        time.sleep(0.5)
    expect(docs, f"no Document or Edit node among roles {sorted({n['role'] for n in r['nodes']})}")
    nodes = r["nodes"]
    for n in nodes:
        check_node(n, "ui.tree")
    expect(len(nodes) <= 300 and r["truncated"] is False, f"{len(nodes)} nodes, truncated {r['truncated']!r}")
    refs = [n["ref"] for n in nodes]
    expect(len(set(refs)) == len(refs), "a ref occurs twice in one tree")
    expect(nodes[0]["depth"] == 0 and all(n["depth"] >= 1 for n in nodes[1:]), "the first node is not the only one at depth 0")
    expect(all(b["depth"] <= a_["depth"] + 1 for a_, b in zip(nodes, nodes[1:])), "a node is more than one level below the node before it")
    check_window(r["window"], "ui.tree window")
    expect(r["window"]["id"] == wid, f"ui.tree reports window {r['window']['id']}, asked for {wid}")
    again = a.call("ui.tree", window=wid)["nodes"]
    first, second = by_identity(nodes), by_identity(again)
    moved = [(k, first[k], second[k]) for k in first if k in second and first[k] != second[k]]
    expect(len(first) > 5 and not moved, f"{len(first)} elements compared, changed refs between two calls: {moved[:3]!r}")
    same_doc = [n for n in again if n["ref"] == docs[0]["ref"]]
    expect(same_doc and same_doc[0]["role"] == docs[0]["role"], f"the second tree lacks {docs[0]['ref']} as {docs[0]['role']}")
    run.document, run.document_role = docs[0]["ref"], docs[0]["role"]
    return f"{len(nodes)} nodes, {docs[0]['role']} {docs[0]['name']!r} is {run.document}"


@check("ui.text returns the document text and a slice of it")
def _(a, run):
    expect(run.document, "check 2 did not find the document node")
    r = a.call("ui.text", ref=run.document)
    expect(r["text"] == SHOWN_TEXT, f"text is {r['text']!r}, expected {SHOWN_TEXT!r}")
    expect(r["total"] == len(SHOWN_TEXT) and r["source"] == "text", f"total {r['total']!r}, source {r['source']!r}")
    part = a.call("ui.text", ref=run.document, offset=6, length=4)
    expect(part["text"] == "line" and part["total"] == len(SHOWN_TEXT), f"offset 6 length 4 gave {part['text']!r}, total {part['total']!r}")
    tail = a.call("ui.text", ref=run.document, offset=11)
    expect(tail["text"] == SHOWN_TEXT[11:], f"offset 11 gave {tail['text']!r}")
    by_selector = a.call("ui.text", window=run.notepad_window["id"], role=run.document_role.lower())
    expect(by_selector["text"] == SHOWN_TEXT, f"the selector form gave {by_selector['text']!r}")
    return f"{r['total']} characters from source {r['source']}"


@check("ui.find finds the File menu item and ui.rect reports it clickable inside the window")
def _(a, run):
    expect(run.notepad_window, "check 1 did not find the Notepad window")
    wid = run.notepad_window["id"]
    nodes = a.call("ui.find", window=wid, role="MenuItem", name="File")["nodes"]
    expect(len(nodes) == 1, f"{len(nodes)} nodes match: {[(n['role'], n['name']) for n in nodes]!r}")
    item = nodes[0]
    check_node(item, "ui.find")
    expect(item["depth"] == 0 and item["role"] == "MenuItem" and item["name"] == "File", f"the node is {item!r}")
    r = a.call("ui.rect", ref=item["ref"])
    check_node(r["node"], "ui.rect")
    expect(r["node"]["ref"] == item["ref"], f"ui.rect answered for {r['node']['ref']}, asked for {item['ref']}")
    expect(r["clickable"] is True, f"clickable is {r['clickable']!r}: {r.get('blocked')!r}")
    w = next((w for w in run.windows() if w["id"] == wid), None)
    expect(w, f"window {wid} left win.list")
    n = r["node"]
    expect(n["x"] <= r["cx"] < n["x"] + n["w"] and n["y"] <= r["cy"] < n["y"] + n["h"], f"centre {r['cx']},{r['cy']} is outside the node {n!r}")
    expect(w["x"] <= r["cx"] < w["x"] + w["w"] and w["y"] <= r["cy"] < w["y"] + w["h"],
           f"centre {r['cx']},{r['cy']} is outside the window {w['x']},{w['y']} {w['w']}x{w['h']}")
    by_selector = a.call("ui.rect", window=NOTE_NAME, role="menuitem", name="File")
    expect(by_selector["node"]["ref"] == item["ref"] and (by_selector["cx"], by_selector["cy"]) == (r["cx"], r["cy"]),
           f"the selector form with a title part gave {by_selector!r}")
    none = a.ask("ui.rect", window=wid, role="MenuItem", name="No Such Menu")
    want = 'no element matches {"window":"' + wid + '","role":"MenuItem","name":"No Such Menu"}; call ui.tree to see what exists'
    expect(none.get("ok") is False and none.get("error") == want, f"a selector without a match answered {none!r}")
    return f"{item['ref']} centre {r['cx']},{r['cy']}"


@check("a ref of the closed Notepad answers that the element no longer exists")
def _(a, run):
    expect(run.document, "check 2 did not find the document node")
    wid = run.notepad_window["id"]
    a.call("proc.kill", pid=run.notepad_window["pid"])
    end = time.time() + 15
    while any(w["id"] == wid for w in run.windows()):
        expect(time.time() < end, f"window {wid} is still in win.list 15 s after Notepad was killed")
        time.sleep(0.3)
    r = a.ask("ui.text", ref=run.document)
    want = f"element {run.document} no longer exists; call ui.tree again"
    expect(r.get("ok") is False and r.get("error") == want, f"ui.text answered {r!r}")
    r = a.ask("ui.tree", window=wid)
    expect(r.get("ok") is False and "win.list" in r.get("error", ""), f"ui.tree of the closed window answered {r!r}")
    return want


@check("ui.tree of File Explorer stops at max within 30 s and ui.find matches a part of a name")
def _(a, run):
    run.explorer_before = explorer_windows(a)
    a.call("exec.start", shell="none", argv=["explorer.exe", f"/select,{FOLDER}\\{FOLDER_ITEM}"])
    folder = ntpath.basename(FOLDER)
    w = run.wait_window(lambda w: w["class"] == "CabinetWClass" and w["id"] not in run.explorer_before and folder in w["title"],
                        f"File Explorer window with {folder} in its title")
    run.explorer_window = w["id"]
    end = time.time() + 30
    while True:
        found = a.call("ui.find", window=w["id"], nameContains="notepad", limit=5)["nodes"]
        items = [n for n in found if n["role"] == "ListItem" and n["name"] in ITEM_NAMES]
        if (items and "selected" in items[0]["flags"]) or time.time() > end:
            break
        time.sleep(0.5)
    expect(1 <= len(found) <= 5, f"ui.find returned {len(found)} nodes for nameContains 'notepad' with limit 5")
    for n in found:
        check_node(n, "ui.find")
    expect(all("notepad" in n["name"].lower() and n["depth"] == 0 for n in found), f"a node does not match: {[n['name'] for n in found]!r}")
    expect(len(items) == 1, f"no single ListItem named {' or '.join(ITEM_NAMES)}: {[(n['role'], n['name']) for n in found]!r}")
    expect("selected" in items[0]["flags"], f"the item File Explorer was opened to select lacks the selected flag: {items[0]!r}")
    shown = a.call("ui.rect", ref=items[0]["ref"], scroll=True)
    expect(shown["clickable"] is True and "offscreen" not in shown["node"]["flags"],
           f"after ui.rect with scroll the item is not clickable: {shown!r}")
    expect(w["x"] <= shown["cx"] < w["x"] + w["w"] and w["y"] <= shown["cy"] < w["y"] + w["h"],
           f"after ui.rect with scroll the centre {shown['cx']},{shown['cy']} is outside the window {w['x']},{w['y']} {w['w']}x{w['h']}")
    row = a.call("ui.text", ref=items[0]["ref"], mode="descendants")
    expect(row["source"] == "descendants" and row["text"].split("\n")[0] in ITEM_NAMES and "Application" in row["text"].split("\n"),
           f"the text below the item is {row!r}")

    t0 = time.time()
    r = a.call("ui.tree", window=w["id"], max=2000, filter="all")
    whole_s = time.time() - t0
    whole = len(r["nodes"])
    expect(r["truncated"] is False and whole > 110, f"the whole tree has {whole} nodes, truncated {r['truncated']!r}")
    limit = 100
    t0 = time.time()
    r = a.call("ui.tree", window=w["id"], max=limit, filter="all")
    cut_s = time.time() - t0
    expect(r["truncated"] is True and len(r["nodes"]) == limit, f"max {limit} gave {len(r['nodes'])} nodes, truncated {r['truncated']!r}")
    expect(cut_s < 30 and whole_s < 30, f"ui.tree took {cut_s:.1f} s with max {limit} and {whole_s:.1f} s for the whole tree")
    for n in r["nodes"]:
        check_node(n, "ui.tree")
    r = a.call("ui.tree", window=w["id"], max=2000)
    expect(r["truncated"] is False and len(r["nodes"]) < whole, f"filter interactive gave {len(r['nodes'])} of {whole} nodes")
    fitting = a.call("ui.tree", window=w["id"], max=len(r["nodes"]))
    expect(fitting["truncated"] is False and len(fitting["nodes"]) == len(r["nodes"]),
           f"max equal to the {len(r['nodes'])} listed nodes gave {len(fitting['nodes'])} nodes, truncated {fitting['truncated']!r}")
    size_only = a.call("ui.text", ref=items[0]["ref"], mode="descendants", length=0)
    expect(size_only["text"] == "" and size_only["total"] == row["total"], f"ui.text with length 0 answered {size_only!r}")
    return (f"{whole} nodes with filter all in {whole_s:.2f} s, {len(r['nodes'])} with interactive; max {limit} answered in {cut_s:.2f} s; "
            f"found {[(n['role'], n['name'], n['flags']) for n in found]!r}")


@check("ui.focused returns the focused node and its window")
def _(a, run):
    r = a.call("ui.focused")
    check_node(r["node"], "ui.focused")
    check_window(r["window"], "ui.focused window")
    expect(r["node"]["depth"] == 0, f"depth is {r['node']['depth']!r}")
    expect("focused" in r["node"]["flags"], f"the node lacks the focused flag: {r['node']!r}")
    listed = [w for w in run.windows() if w["id"] == r["window"]["id"]]
    expect(not listed or listed[0]["foreground"] is True, f"the focused element is in window {r['window']['id']}, which win.list does not show in the foreground")
    root = a.call("ui.tree", root=r["node"]["ref"], depth=0)
    expect([n["ref"] for n in root["nodes"]] == [r["node"]["ref"]], f"ui.tree with the focused ref as root gave {root['nodes']!r}")
    return f"{r['node']['role']} {r['node']['name']!r} in {r['window']['title']!r}"


def same_window(a, wid):
    """Returns the win.list entry with that id, or None."""
    return next((w for w in a.call("win.list")["windows"] if w["id"] == wid), None)


def act(a, run, action, **selector):
    """Runs ui.act on an element of the fixture window and returns the reply."""
    r = a.call("ui.act", window=run.fixture["id"], action=action, **selector)
    check_node(r["node"], f"ui.act {action}")
    expect(set(r) <= {"t", "id", "ok", "node", "gone", "unresponsive", "pending"}, f"ui.act {action} returned unknown fields: {sorted(r)!r}")
    return r


@check("app.launch starts the fixture, returns its window and a window.opened event arrives")
def _(a, run):
    seen = len(a.events)
    t0 = time.time()
    r = run.launch_fixture()
    took = time.time() - t0
    w = r.get("window")
    expect(w is not None, f"app.launch returned no window: {r!r}")
    check_window(w, "app.launch window")
    expect(w["title"] == FIXTURE_TITLE and w["process"].lower() == "alcove-fixture.exe" and w["pid"] == r["pid"],
           f"the window is {w!r} for pid {r['pid']}")
    expect(w["state"] == "normal" and w["responding"] is True and w["w"] > 300 and w["h"] > 300, f"the window is {w!r}")
    ev = a.event("window.opened", lambda e: e in a.events[seen:] and e["window"]["id"] == w["id"], f"for window {w['id']}")
    check_window(ev["window"], "window.opened")
    expect(ev["window"]["title"] == FIXTURE_TITLE, f"the event carries {ev['window']!r}")
    listed = same_window(a, w["id"])
    expect(listed and listed["title"] == FIXTURE_TITLE, f"win.list does not show window {w['id']}")
    label = a.call("ui.find", window=w["id"], role="Text", name="한글 라벨")["nodes"]
    expect(len(label) == 1, f"{len(label)} Text elements are named 한글 라벨")
    run.fixture = w
    return f"pid {r['pid']}, window {w['id']} {w['w']}x{w['h']} after {took:.2f} s, foreground {w['foreground']}, event {ev['at'] - t0:.2f} s after the request"


@check("ui.act sets the message, presses Send and ui.text reads the finished transcript")
def _(a, run):
    expect(run.fixture, "check 8 did not start the fixture")
    r = act(a, run, "set_value", role="Edit", name="Message", value=MESSAGE)
    expect(r["node"].get("value") == MESSAGE, f"after set_value the node is {r['node']!r}")
    r = act(a, run, "invoke", role="Button", name="Send")
    expect(r["node"]["name"] == "Send", f"ui.act invoke returned {r['node']!r}")
    t0 = time.time()
    lengths = []
    while True:
        t = a.call("ui.text", window=run.fixture["id"], role="Document", name="Transcript")
        lengths.append(t["total"])
        if "[done]" in t["text"]:
            break
        expect(time.time() - t0 < 20, f"the transcript has no [done] after 20 s: {t['text']!r}")
        time.sleep(0.1)
    text = t["text"]
    expect(f"You: {MESSAGE}\n" in text, f"the transcript lacks the sent line: {text!r}")
    bot = [l for l in text.split("\n") if l.startswith("Bot: ")]
    expect(len(bot) == 1, f"the transcript has {len(bot)} Bot lines: {text!r}")
    words = bot[0][len("Bot: "):].split()
    expect(words == (["echo"] + MESSAGE.split()) * 10, f"the reply is {words!r}")
    expect(len(set(lengths)) > 3, f"ui.text saw the transcript at only {len(set(lengths))} lengths while it was written")
    sent = [l for l in run.fixture_log() if " send " in l]
    expect(sent and sent[-1].endswith(" send " + MESSAGE), f"the fixture log has no send line for the message: {sent!r}")
    wrong = a.ask("ui.act", window=run.fixture["id"], role="Button", name="Send", action="toggle")
    expect(wrong.get("ok") is False and "does not support toggle" in wrong.get("error", "") and "invoke" in wrong["error"],
           f"ui.act toggle on a button answered {wrong!r}")
    return f"{len(text)} characters, {len(words)} reply words, read at {len(set(lengths))} lengths in {time.time() - t0:.1f} s"


@check("the Dialog button raises dialog.opened and win.action close raises window.closed")
def _(a, run):
    expect(run.fixture, "check 8 did not start the fixture")
    seen = len(a.events)
    t0 = time.time()
    act(a, run, "invoke", role="Button", name="Dialog")
    ev = a.event("dialog.opened", lambda e: e in a.events[seen:] and e["window"]["title"] == "Fixture Dialog", "titled Fixture Dialog")
    opened_after = ev["at"] - t0
    d = ev["window"]
    check_window(d, "dialog.opened")
    expect(d["class"] == "#32770" and d["modal"] is True and d["pid"] == run.fixture["pid"], f"the dialog is {d!r}")
    expect(any(e.get("name") == "window.opened" and e["window"]["id"] == d["id"] for e in a.events[seen:]),
           f"no window.opened event for the dialog {d['id']}")
    body = a.call("ui.find", window=d["id"], role="Text", name="Dialog body")["nodes"]
    expect(len(body) == 1, f"the dialog has {len(body)} Text elements named Dialog body")
    seen = len(a.events)
    t0 = time.time()
    r = a.call("win.action", window=d["id"], action="close")
    expect(r.get("closed") is True and r.get("window") is None, f"win.action close answered {r!r}")
    ev = a.event("window.closed", lambda e: e in a.events[seen:] and e["window"]["id"] == d["id"], f"for window {d['id']}")
    expect(same_window(a, d["id"]) is None, f"win.list still shows the dialog {d['id']}")
    gone = a.ask("win.action", window=d["id"], action="close")
    expect(gone.get("ok") is False and "win.list" in gone.get("error", ""), f"win.action on the closed dialog answered {gone!r}")
    return f"dialog {d['id']}; dialog.opened {opened_after:.2f} s after the request, window.closed {ev['at'] - t0:.2f} s after the request"


@check("win.action minimizes, restores, moves, resizes and focuses the fixture window")
def _(a, run):
    expect(run.fixture, "check 8 did not start the fixture")
    wid = run.fixture["id"]

    def do(action, **params):
        r = a.call("win.action", window=wid, action=action, **params)
        check_window(r["window"], f"win.action {action}")
        expect(r["window"]["id"] == wid, f"win.action {action} answered for {r['window']['id']}")
        listed = same_window(a, wid)
        expect(listed and all(listed[k] == r["window"][k] for k in ("x", "y", "w", "h", "state")),
               f"after {action} win.list shows {listed!r}, win.action returned {r['window']!r}")
        return r["window"]

    w = do("minimize")
    expect(w["state"] == "minimized" and (w["w"], w["h"]) == (0, 0) and w["foreground"] is False, f"after minimize: {w!r}")
    w = do("restore")
    expect(w["state"] == "normal" and w["w"] > 0, f"after restore: {w!r}")
    w = do("maximize")
    fw, fh = run.frame or (None, None)
    expect(w["state"] == "maximized" and (fw is None or (w["x"], w["y"], w["w"]) == (0, 0, fw)), f"after maximize: {w!r}")
    w = do("restore")
    expect(w["state"] == "normal", f"after the second restore: {w!r}")
    w = do("move", x=40, y=40)
    expect((w["x"], w["y"]) == (40, 40), f"after move to 40,40: {w!r}")
    w = do("resize", w=800, h=600)
    expect((w["x"], w["y"], w["w"], w["h"]) == (40, 40, 800, 600), f"after resize to 800x600: {w!r}")
    send = a.call("ui.rect", window=wid, role="Button", name="Send")
    expect(40 < send["cx"] < 840 and 40 < send["cy"] < 640, f"the Send button is at {send['cx']},{send['cy']}, outside the moved window")

    other = a.call("win.action", window="Program Manager", action="focus")["window"]
    expect(other["foreground"] is True, f"the desktop did not come to the foreground: {other!r}")
    behind = same_window(a, wid)
    expect(behind["foreground"] is False, f"the fixture is still in the foreground after the desktop was focused: {behind!r}")
    w = do("focus")
    expect(w["foreground"] is True, f"after focus: {w!r}")
    expect(same_window(a, wid)["foreground"] is True, "win.list does not show the fixture in the foreground after focus")
    r = act(a, run, "focus", role="Edit", name="Message")
    expect("focused" in r["node"]["flags"], f"after ui.act focus the node is {r['node']!r}")
    f = a.call("ui.focused")
    expect(f["node"]["ref"] == r["node"]["ref"] and f["window"]["id"] == wid, f"ui.focused reports {f['node']!r} in {f['window']['title']!r}")
    bad = a.ask("win.action", window=wid, action="resize", w=800)
    expect(bad.get("ok") is False and bad.get("error") == "resize needs w and h", f"resize without h answered {bad!r}")
    return f"window {wid} at {w['x']},{w['y']} {w['w']}x{w['h']}, foreground {w['foreground']}"


@check("after Hang win.list reports the fixture as not responding and killing it raises process.exited")
def _(a, run):
    expect(run.fixture, "check 8 did not start the fixture")
    wid, pid = run.fixture["id"], run.fixture["pid"]
    t0 = time.time()
    r = act(a, run, "invoke", role="Button", name="Hang")
    act_s = time.time() - t0
    expect(r.get("unresponsive") is True, f"ui.act invoke on Hang answered {r!r}")
    while True:
        w = same_window(a, wid)
        expect(w is not None, f"window {wid} left win.list after Hang")
        if w["responding"] is False:
            break
        expect(time.time() - t0 < 10, f"win.list still reports responding for {wid} 10 s after Hang")
        time.sleep(0.3)
    hung_after = time.time() - t0
    tree = a.ask("ui.tree", window=wid)
    expect(tree.get("ok") is False and "is not responding" in tree.get("error", "") and "proc.kill" in tree["error"],
           f"ui.tree of the hung window answered {tree!r}")
    end = time.time() + 5
    while True:
        titled = [w for w in a.call("win.list")["windows"] if FIXTURE_TITLE in w["title"]]
        ghost = [w for w in titled if w["class"] == "Ghost"]
        if ghost or time.time() > end:
            break
        time.sleep(0.3)
    stray = [w for w in titled if w["pid"] != pid or w["process"].lower() != "alcove-fixture.exe"]
    expect(stray == [], f"a window titled like the fixture reports another process: {stray!r}")
    seen = len(a.events)
    t0 = time.time()
    expect(a.call("proc.kill", pid=pid)["killed"] == 1, "proc.kill did not report one killed process")
    ev = a.event("process.exited", lambda e: e in a.events[seen:] and e.get("pid") == pid, f"for pid {pid}")
    expect(type(ev.get("code")) is int and ev.get("path", "").lower() == FIXTURE.lower(), f"the event is {ev!r}")
    a.event("window.closed", lambda e: e in a.events[seen:] and e["window"]["id"] == wid, f"for window {wid}")
    run.fixture = None
    return (f"ui.act answered after {act_s:.1f} s, responding false {hung_after:.1f} s after Hang, "
            + (f"the system's {ghost[0]['title']!r} window reports pid {ghost[0]['pid']}, " if ghost else "no Ghost window appeared, ")
            + f"process.exited {ev['at'] - t0:.2f} s after proc.kill with code {ev['code']}")


@check("the text of a password field is never returned and ui.act set_value still fills it")
def _(a, run):
    r = run.launch_fixture()
    expect(r.get("window"), f"app.launch returned no window: {r!r}")
    run.fixture = r["window"]
    wid = run.fixture["id"]
    r = act(a, run, "set_value", role="Edit", name="Secret", value=SECRET)
    expect("password" in r["node"]["flags"] and "value" not in r["node"], f"after set_value the node is {r['node']!r}")
    end = time.time() + 5
    while True:
        log = run.fixture_log()
        changes = [l for l in log if " secret " in l]
        if changes and changes[-1].endswith(f" secret {len(SECRET)}"):
            break
        expect(time.time() < end, f"the fixture did not log a secret of {len(SECRET)} characters: {changes!r}")
        time.sleep(0.2)
    expect(all(SECRET not in l for l in log), "the fixture log carries the secret text")
    replies = {}
    for mode in ("auto", "pattern", "descendants"):
        replies[f"ui.text {mode}"] = a.ask("ui.text", window=wid, role="Edit", name="Secret", mode=mode)
        expect(replies[f"ui.text {mode}"].get("error") == "the element is a password field; its text is not read; it cannot be read through UI Automation",
               f"ui.text mode {mode} of the password field answered {replies[f'ui.text {mode}']!r}")
    replies["ui.text by ref"] = a.ask("ui.text", ref=r["node"]["ref"])
    replies["ui.text of the window"] = a.call("ui.text", window=wid, role="Window", mode="descendants")
    replies["ui.tree"] = a.call("ui.tree", window=wid, filter="all", max=2000)
    replies["ui.tree interactive"] = a.call("ui.tree", window=wid)
    replies["ui.find"] = a.call("ui.find", window=wid, name="Secret")
    replies["ui.rect"] = a.call("ui.rect", window=wid, role="Edit", name="Secret")
    replies["ui.focused"] = a.call("ui.focused")
    for what, reply in replies.items():
        expect(SECRET not in json.dumps(reply, ensure_ascii=False), f"{what} returned the typed secret")
    field = [n for n in replies["ui.tree interactive"]["nodes"] if n["role"] == "Edit" and n["name"] == "Secret"]
    expect(len(field) == 1 and "password" in field[0]["flags"] and "value" not in field[0], f"ui.tree lists the field as {field!r}")
    shown = replies["ui.text of the window"]["text"].split("\n")
    expect("Message" in shown and "한글 라벨" in shown, f"the text below the window is {shown!r}")
    return f"{len(replies)} replies checked; the fixture logged a secret of {len(SECRET)} characters"


def running_fixture(a, run):
    """Returns the id of the fixture window; starts the fixture when it does not run."""
    if not run.fixture or same_window(a, run.fixture["id"]) is None:
        r = run.launch_fixture()
        expect(r.get("window"), f"app.launch returned no window: {r!r}")
        run.fixture = r["window"]
    return run.fixture["id"]


@check("the Titles button raises one window.title for the held title and one, a second later, for the base title")
def _(a, run):
    wid = running_fixture(a, run)
    seen = len(a.events)
    a.call("ui.act", window=wid, role="Button", name="Titles", action="invoke")
    # The title changes every 50 ms for 5 s, is HELD_TITLE for 600 ms and then the base title.
    a.pump(9)
    titles = [e for e in a.events[seen:] if e.get("name") == "window.title" and e["window"]["id"] == wid]
    shown = [e["window"]["title"] for e in titles]
    expect(2 <= len(titles) <= 8 and shown[-2:] == [HELD_TITLE, FIXTURE_TITLE], f"the window.title events carry {shown!r}")
    gaps = [b["at"] - a_["at"] for a_, b in zip(titles, titles[1:])]
    expect(all(g >= 0.9 for g in gaps), f"window.title events arrived {[round(g, 2) for g in gaps]!r} s apart: {shown!r}")
    final = same_window(a, wid)
    expect(final and final["title"] == FIXTURE_TITLE, f"the window title did not return to {FIXTURE_TITLE!r}: {final!r}")
    return f"{len(titles)} window.title events {shown!r}, the last two {gaps[-1]:.2f} s apart"


@check("ui.act invoke on Crash ends the fixture with a crash code and a WER report")
def _(a, run):
    # End the fixture earlier checks left running.
    running = {p["pid"] for p in a.call("proc.list", name="alcove-fixture")["procs"]}
    for pid in running:
        a.call("proc.kill", pid=pid)
    end = time.time() + 10
    while {p["pid"] for p in a.call("proc.list", name="alcove-fixture")["procs"]} and time.time() < end:
        time.sleep(0.3)
    run.fixture = None
    since = int(a.call("exec.run", cmd="[DateTime]::UtcNow.Ticks")["stdout"].strip())
    r = run.launch_fixture()
    expect(r.get("window"), f"app.launch returned no window: {r!r}")
    run.fixture = r["window"]
    wid, pid = run.fixture["id"], run.fixture["pid"]
    seen = len(a.events)
    run.wer_since = since
    t0 = time.time()
    act = a.ask("ui.act", window=wid, role="Button", name="Crash", action="invoke")
    if act.get("ok") is True:
        expect(act.get("gone") is True or act.get("pending") is True or act.get("unresponsive") is True,
               f"ui.act invoke on Crash answered {act!r}")
    ev = a.event("process.exited", lambda e: e in a.events[seen:] and e.get("pid") == pid, f"for pid {pid}")
    expect(ev.get("code") == CRASH_CODE, f"process.exited carries code {ev.get('code')!r}, expected {CRASH_CODE}")
    run.fixture = None
    found = wait_wer(a, since)
    expect(found, f"no AppCrash_alcove-fixture report created after the check started under {' or '.join(WER_DIRS)}")
    return (f"ui.act answered {sorted(k for k in ('gone', 'pending', 'unresponsive') if act.get(k)) or act.get('error')!r}, "
            f"process.exited code {ev['code']} {ev['at'] - t0:.2f} s after invoke; WER report {ntpath.basename(found[0])}")


@check("a helper started with several windows open sends no window.title for 3 s")
def _(a, run):
    running_fixture(a, run)
    killed = kill_helper(a)
    seen = len(a.events)
    ping = a.call("ui.ping")
    expect(ping["pid"] != killed, f"helper process {killed} answers after it was killed")
    listed = {w["id"]: w["title"] for w in run.windows() if w["title"]}
    expect(len(listed) >= 2, f"only {len(listed)} titled windows are open: {sorted(listed.values())!r}")
    a.pump(3)
    titles = [e["window"] for e in a.events[seen:] if e.get("name") == "window.title"]
    unchanged = [w["title"] for w in titles if listed.get(w["id"]) == w["title"]]
    expect(not unchanged, f"window.title arrived for {len(unchanged)} of {len(listed)} windows whose title did not change: {unchanged!r}")
    return f"helper pid {ping['pid']} with {len(listed)} titled windows open; {len(titles)} window.title events"


@check("ui.ping sent right after the helper was killed starts the next helper, 20 times in a row")
def _(a, run):
    rounds, early, slowest = 20, 0, 0.0
    pid = a.call("ui.ping")["pid"]
    for n in range(1, rounds + 1):
        a.call("proc.kill", pid=pid)
        t0 = time.time()
        r = a.ask("ui.ping")
        # A ping that reached the helper while it was ending is sent again at once.
        while r.get("ok") is False and r.get("error") == HELPER_EXITED:
            early += 1
            expect(time.time() - t0 < 30, f"round {n}: ui.ping still answers {HELPER_EXITED!r} 30 s after the kill")
            r = a.ask("ui.ping")
        expect(r.get("ok") is True, f"round {n}: ui.ping after the kill answered {r.get('error')!r}")
        expect(r["pid"] != pid, f"round {n}: helper process {pid} answers after it was killed")
        pid, slowest = r["pid"], max(slowest, time.time() - t0)
    return f"{rounds} helpers started, slowest answer after {slowest:.2f} s, {early} pings reached a helper that was ending"


@check("after the foreground goes to the fixture, the desktop and the fixture within a second the last window.foreground names the fixture")
def _(a, run):
    wid = running_fixture(a, run)
    a.call("win.action", window="Program Manager", action="focus")
    a.pump(1.5)
    seen = len(a.events)
    a.call("win.action", window=wid, action="focus")
    a.pump(0.35)
    a.call("win.action", window="Program Manager", action="focus")
    a.pump(0.35)
    a.call("win.action", window=wid, action="focus")
    a.pump(2.5)
    front = [w["id"] for w in run.windows() if w["foreground"]]
    expect(front == [wid], f"the fixture {wid} is not the foreground window after focus: {front!r}")
    events = [e for e in a.events[seen:] if e.get("name") == "window.foreground"]
    named = [e["window"]["title"] or e["window"]["id"] for e in events]
    expect(events and events[-1]["window"]["id"] == wid, f"the window.foreground events name {named!r} while the fixture is in front")
    own = [e["at"] for e in events if e["window"]["id"] == wid]
    gaps = [b - a_ for a_, b in zip(own, own[1:])]
    expect(all(g >= 0.9 for g in gaps), f"window.foreground events for the fixture arrived {[round(g, 2) for g in gaps]!r} s apart")
    return f"window.foreground named {named!r}"


def find_wer(a, since_ticks):
    """Returns the AppCrash_alcove-fixture report folders created after since_ticks."""
    dirs = ",".join(f"'{d}'" for d in WER_DIRS)
    ps = (f"Get-ChildItem -LiteralPath {dirs} -Directory -ErrorAction SilentlyContinue | "
          "Where-Object { $_.Name -like 'AppCrash_alcove-fixture*' -and $_.CreationTimeUtc.Ticks -gt "
          f"{since_ticks} }} | ForEach-Object {{ $_.FullName }}")
    out = a.call("exec.run", cmd=ps)["stdout"]
    return [line.strip() for line in out.splitlines() if line.strip()]


def wait_wer(a, since_ticks, timeout=15):
    """Polls find_wer until it returns a folder or the timeout passes."""
    end = time.time() + timeout
    while True:
        found = find_wer(a, since_ticks)
        if found or time.time() > end:
            return found
        time.sleep(0.5)


def wait_gone(a, pids, timeout=15):
    """Waits until none of the Notepad processes in pids runs; returns the ones that still do."""
    end = time.time() + timeout
    while True:
        left = {p["pid"] for p in a.call("proc.list", name="notepad")["procs"]} & pids
        if not left or time.time() > end:
            return left
        time.sleep(0.3)


def restore_notepad(a, run):
    """Ends the Notepad processes the run started and puts the saved tabs back.
    Returns a sentence that says what went wrong, or None."""
    by_hand = (f"end Notepad in the guest, then make {NOTEPAD_STATE} equal to the copy in {run.notepad_copy} "
               "(delete the files that are not in the copy" + ("" if run.notepad_state is not None else "; the folder did not exist before the run") + ")")
    try:
        started = {p["pid"] for p in a.call("proc.list", name="notepad")["procs"]} - run.notepad_before
        for pid in started:
            a.ask("proc.kill", pid=pid)
        left = wait_gone(a, started)
        if left:
            return f"Notepad processes {sorted(left)} still run, so Notepad's saved tabs were not put back; {by_hand}"
        restore(a, NOTEPAD_STATE, run.notepad_copy, run.notepad_state)
    except Exception as e:
        return f"Notepad's saved tabs were not put back ({type(e).__name__}: {e}); {by_hand}"
    shutil.rmtree(run.notepad_copy, ignore_errors=True)
    return None


def cleanup(port, run):
    """On a new connection: ends the fixture and Notepad processes the run
    started, puts Notepad's saved tabs back, closes the File Explorer windows
    the run opened and deletes the files it wrote. Returns the sentences that
    say what could not be cleaned up."""
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    problems = []
    try:
        a = Agent(port)
    except Exception as e:
        problems.append(f"cleanup did not run: {e}; the fixture, Notepad, a File Explorer window and files under {E2E} may remain in the guest")
        if run.notepad_copy:
            problems.append(f"Notepad's saved tabs as they were before the run are in {run.notepad_copy} on the host")
        return problems

    def kill_fixtures():
        for pid in run.fixture_pids:
            if any(p["pid"] == pid for p in a.call("proc.list", name="alcove-fixture")["procs"]):
                a.call("proc.kill", pid=pid)
        end = time.time() + 10
        while {p["pid"] for p in a.call("proc.list", name="alcove-fixture")["procs"]} & set(run.fixture_pids) and time.time() < end:
            time.sleep(0.3)

    def remove_wer():
        for d in wait_wer(a, run.wer_since):
            a.call("exec.run", cmd=f"Remove-Item -LiteralPath '{d}' -Recurse -Force -ErrorAction SilentlyContinue")
        left = find_wer(a, run.wer_since)
        expect(not left, f"the report folders {left!r} are still there")

    steps = [("ending the fixture", kill_fixtures)]
    if run.wer_since is not None:
        steps.append(("removing the crash WER reports", remove_wer))
    if run.explorer_before is not None:
        steps.append(("closing File Explorer", lambda: close_explorer(a, explorer_windows(a) - run.explorer_before)))
    steps.append((f"deleting {BASE}", lambda: a.call("fs.delete", path=BASE, recursive=True)))
    def delete_fixture_exe():
        # Retries the delete for 15 s.
        end = time.time() + 15
        while True:
            res = a.ask("fs.delete", path=FIXTURE)
            if res.get("ok") is True or time.time() > end:
                expect(res.get("ok") is True, f"fs.delete {FIXTURE}: {res.get('error')}")
                return
            time.sleep(0.5)

    if run.fixture_pushed:
        steps.append((f"deleting {FIXTURE}", delete_fixture_exe))
    steps.append((f"deleting {E2E}", lambda: a.ask("fs.delete", path=E2E)))
    if run.notepad_before is not None:
        problem = restore_notepad(a, run)
        if problem:
            problems.append(problem)
    elif run.notepad_copy:
        shutil.rmtree(run.notepad_copy, ignore_errors=True)
    for what, step in steps:
        try:
            step()
        except Exception as e:
            problems.append(f"{what} failed ({type(e).__name__}: {e})")
    return problems


def kill_helper(a):
    """Ends the running helper process and returns its pid."""
    pid = a.call("ui.ping")["pid"]
    a.call("proc.kill", pid=pid)
    end = time.time() + 10
    while any(p["pid"] == pid for p in a.call("proc.list", name="powershell")["procs"]):
        expect(time.time() < end, f"helper process {pid} still runs 10 s after proc.kill")
        time.sleep(0.2)
    return pid


def first_ref(a):
    """Returns the ref the helper gives the root element of the first listed window."""
    wid = a.call("win.list")["windows"][0]["id"]
    return a.call("ui.tree", window=wid, depth=0)["nodes"][0]["ref"]


def restart_helper(a):
    """Kills the helper twice and returns the pid of the last killed one and how
    long the first answer of its replacement took. The ref taken from the helper
    in between must be unknown to the helper after it."""
    kill_helper(a)
    old = first_ref(a)
    killed = kill_helper(a)
    t0 = time.time()
    a.call("ui.ping")
    took = time.time() - t0
    new = first_ref(a)
    r = a.ask("ui.rect", ref=old)
    want = f"element {old} no longer exists; call ui.tree again"
    expect(r.get("ok") is False and r.get("error") == want,
           f"ref {old} of a killed helper answers {r!r} in the helper that gave out {new}")
    return killed, took


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--agent-port", type=int, default=7646)
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    ap.add_argument("--kill-helper", action="store_true", help="end the running UI helper before the checks")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}

    try:
        a = Agent(args.agent_port)
    except (OSError, Failure) as e:
        print(f"FAIL 0: cannot talk to the agent on port {args.agent_port}: {e}; run scripts/test/install-agent.py")
        sys.exit(1)
    caps = a.hello.get("caps", [])
    if a.hello.get("proto") != 2 or any(c not in caps for c in ("rpc", "jobs", "proc", "fs", "ui")):
        print(f"FAIL 0: the agent reports proto {a.hello.get('proto')!r} and caps {caps!r}; run scripts/test/install-agent.py")
        sys.exit(1)
    try:
        killed, took = restart_helper(a) if args.kill_helper else (None, None)
        t0 = time.time()
        ping = a.call("ui.ping")
        took = time.time() - t0 if took is None else took
    except (Failure, OSError, ValueError, KeyError) as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    if killed is not None and ping["pid"] == killed:
        print(f"FAIL 0: helper process {killed} answers after it was killed")
        sys.exit(1)
    print(f"helper pid {ping['pid']}" + (f" (started after pid {killed} was killed)" if killed is not None else "")
          + f", session {ping['session']}, {ping['integrity']} integrity, first answer after {took:.2f} s", flush=True)

    run = Run(a)
    failed = False

    def terminate(*_):
        raise SystemExit(1)
    signal.signal(signal.SIGTERM, terminate)
    try:
        for n, title, fn in CHECKS:
            if only and n not in only:
                continue
            try:
                note = fn(a, run)
            except Failure as e:
                reason = str(e)
            except (KeyError, TypeError, IndexError) as e:
                reason = f"a reply lacks an expected field ({type(e).__name__}: {e})"
            except (OSError, ValueError) as e:
                reason = f"the connection to the agent broke ({type(e).__name__}: {e})"
            else:
                print(f"PASS {n} {title}" + (f" ({note})" if note else ""), flush=True)
                continue
            failed = True
            print(f"FAIL {n}: {reason}", flush=True)
    finally:
        for problem in cleanup(args.agent_port, run):
            failed = True
            print(f"FAIL cleanup: {problem}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
