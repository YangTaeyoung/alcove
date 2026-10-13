#!/usr/bin/env python3
"""End-to-end run of the screen operations against a running Windows VM:
screenshots with scale, region and format, text recognition, observations
after input, batches, waits for conditions, and the same through the MCP
server (docs/control-protocol.md, mcp/).

Needs the VM running with the agent installed with --allow-exec
(scripts/test/install-agent.py), no Notepad running in the guest, a control
server built from this tree and `npm run build` in mcp/.

Each check prints `PASS <n> <title>`; the first failing check prints
`FAIL <n>: <reason>` and the script exits 1. The checks open the guest's
Notepad on C:\\alcove-e2e\\ocr.txt. Before Notepad starts for the first time,
the files of its saved tabs are copied to a temporary directory on the host,
whose path is printed. However the run ends, a second connection kills the
jobs and the Notepad processes the run started, puts Notepad's saved tabs
back once those processes are gone and deletes C:\\alcove-e2e. The host copy is
deleted after the tabs were put back; when a step of that cannot finish, the
script prints `cleanup failed: ...` with what to do by hand and exits 1.

Usage: at3-e2e.py [--vm NAME] [--only N[,N...]]
"""
import argparse, base64, hashlib, os, re, shutil, signal, struct, sys, tempfile, time

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout
from mcp_stdio import MCP, MCPError

GUEST = r"C:\alcove-e2e"
OCR_FILE = GUEST + r"\ocr.txt"
ENGLISH = "Alcove OCR check"
KOREAN = "한글 인식 확인"
OCR_TEXT = ENGLISH + "\r\n" + KOREAN + "\r\n"
NOTEPAD_STATE = "~/AppData/Local/Packages/Microsoft.WindowsNotepad_8wekyb3d8bbwe/LocalState"
NOTEPAD_STATE_EXISTS = r"Test-Path -LiteralPath (Join-Path $HOME 'AppData\Local\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState')"
NOTEPAD_WINDOWS = ("Get-Process -Name Notepad -ErrorAction SilentlyContinue | "
                   "Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { $_.Id }")
LATIN = ["en-US"]
AGENT_GUEST_PORT = 7645
CLOSED_GUEST_PORT = 1
SHOTS = 20
MAX_MEAN_SHOT_MS = 60
MAX_UNSETTLED_CLICK_S = 2.0
TILE = 32
ROW_SLACK = 20
MOVE_WINDOW = (
    "Add-Type -Namespace Alcove -Name Win -MemberDefinition "
    "'[DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr h, int c);'; "
    "$h = (Get-Process -Id {pid}).MainWindowHandle; if ($h -eq 0) {{ throw 'process {pid} has no window' }}; "
    "'moving'; $end = (Get-Date).AddSeconds({seconds}); $max = $true; "
    "while ((Get-Date) -lt $end) {{ [void][Alcove.Win]::ShowWindow($h, $(if ($max) {{ 3 }} else {{ 9 }})); "
    "$max = -not $max; Start-Sleep -Milliseconds 100 }}; "
    "[void][Alcove.Win]::ShowWindow($h, 9); 'done'"
)
LANGUAGE_REFUSAL = r"condition 0: language 'xx-XX' is not supported; supported: .*\ben-US\b.*"
LANGUAGES_TYPE_REFUSAL = 'languages must be an array of language codes such as ["en-US","ko-KR"]'


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l]


def png_size(data):
    """Width and height from the header of a PNG."""
    expect(data[:8] == b"\x89PNG\r\n\x1a\n", "the image is not a PNG")
    return struct.unpack(">II", data[16:24])


def jpeg_size(data):
    """Width and height from the frame header of a JPEG."""
    expect(data[:2] == b"\xff\xd8", "the image is not a JPEG")
    at = 2
    while at + 9 <= len(data):
        expect(data[at] == 0xFF, f"the JPEG has no marker at byte {at}")
        marker = data[at + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", data[at + 5:at + 9])
            return width, height
        at += 2 + struct.unpack(">H", data[at + 2:at + 4])[0]
    raise Failure("the JPEG has no frame header")


def inside(rect, width, height):
    """Whether a rectangle with x, y, w, h lies in a width x height frame and is not empty."""
    return rect["w"] > 0 and rect["h"] > 0 and rect["x"] >= 0 and rect["y"] >= 0 and rect["x"] + rect["w"] <= width and rect["y"] + rect["h"] <= height


def squeezed(text):
    return "".join(text.split()).lower()


class Run:
    """The control connection, the VM and what the checks started or changed in the guest."""

    def __init__(self, client, vm):
        self.c = client
        self.vm = vm
        self.size = None
        self.jobs = []
        self.mcps = []
        self.wrote_guest = False
        self.cleanup_failed = False
        self.notepad_before = None
        self.notepad_copy = None
        self.notepad_names = None
        self.notepad_dirs = []
        self.notepad_job = None
        self.notepad_stub = None
        self.notepad_window = None
        self.notepad_dirty = False

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
        expect(r["code"] == 0, f"guest command {command!r} exited with {r['code']}: {r['stderr'].strip() or r['stdout'].strip()}")
        return r["stdout"].strip()

    def frame(self):
        """Width and height of the guest frame."""
        if self.size is None:
            shot = self.call("vm.screenshot", scale=0.1, format="jpeg")
            self.size = (shot["width"], shot["height"])
        return self.size

    def start_job(self, **params):
        r = self.call("vm.exec.start", **params)
        self.jobs.append(r["job"])
        return r

    def wait_for(self, conditions, timeout=30, **params):
        return self.call("vm.wait_for", timeout + 60, conditions=conditions, timeout=timeout, **params)

    def find(self, query, **params):
        return self.call("vm.find_text", query=query, **params)

    def find_one(self, query, **params):
        """The only line on the screen that contains `query`."""
        r = self.find(query, **params)
        expect(len(r["matches"]) == 1, f"vm.find_text {query!r} returned {len(r['matches'])} matches of {r['lines']} lines: {[m['text'] for m in r['matches']]!r}")
        return r["matches"][0]

    def mcp(self):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at3-e2e")
        return m

    # Notepad

    def notepad_pids(self, c=None):
        rows = (c or self.c).call("vm.process.list", 60, name=self.vm, filter="notepad")["processes"]
        return {p["pid"] for p in rows if p["name"].lower() in ("notepad.exe", "notepad")}

    def started_notepads(self, c=None):
        """The Notepad processes that were not running before the run's first launch."""
        if self.notepad_before is None:
            return set()
        return self.notepad_pids(c) - self.notepad_before

    def snapshot_notepad(self):
        """Copies the files of Notepad's saved tabs to a new temporary directory on the host and notes the folders."""
        copy = tempfile.mkdtemp(prefix="alcove-notepad-state-")
        try:
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
        except BaseException:
            shutil.rmtree(copy, ignore_errors=True)
            raise
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

    def end_notepads(self, c):
        """Kills the Notepad processes the run started; returns the ones that still run after 15 s."""
        for pid in self.started_notepads(c):
            try:
                c.call("vm.process.kill", 60, name=self.vm, pid=pid, tree=True)
            except ControlTimeout:
                raise
            except ControlError:
                pass
        end = time.time() + 15
        while True:
            left = self.started_notepads(c)
            if not left or time.time() > end:
                return left
            time.sleep(0.3)

    def launch_notepad(self):
        """Starts Notepad on the text file with its saved tabs as they were before the run and waits for its window."""
        if self.notepad_before is None:
            before = self.notepad_pids()
            expect(not before, f"notepad.exe runs already (pids {sorted(before)}); close it in the guest before this run")
            self.snapshot_notepad()
            print(f"Notepad's saved tabs are copied to {self.notepad_copy} on the host", flush=True)
            self.notepad_before = before
        else:
            left = self.end_notepads(self.c)
            expect(not left, f"the Notepad processes {sorted(left)} of this run still run 15 s after vm.process.kill")
            self.restore_notepad(self.c)
        self.notepad_job = self.notepad_stub = self.notepad_window = None
        self.wrote_guest = True
        self.call("vm.fs.write", path=OCR_FILE, text=OCR_TEXT)
        started = self.start_job(argv=["notepad.exe", OCR_FILE], shell="none")
        self.notepad_job, self.notepad_stub = started["job"], started["pid"]
        self.notepad_dirty = False
        end = time.time() + 60
        while True:
            windows = {int(pid) for pid in lines(self.exec(NOTEPAD_WINDOWS))} & self.started_notepads()
            if windows:
                self.notepad_window = sorted(windows)[0]
                return
            expect(time.time() < end, "no Notepad process of this run has a window 60 s after vm.exec.start")
            time.sleep(0.5)

    def notepad(self, pristine=False):
        """Makes sure the run's Notepad shows the text file; with `pristine`, with the text as written."""
        if self.notepad_window in self.started_notepads() and not (pristine and self.notepad_dirty):
            return
        self.launch_notepad()
        r = self.wait_for([{"type": "text_visible", "text": ENGLISH, "languages": LATIN}], timeout=60)
        expect(r["matched"] == 0, f"'{ENGLISH}' did not appear within 60 s of starting Notepad: {r!r}")

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
        try:
            self.c.close()
        except Exception:
            pass
        by_hand = ""
        if self.notepad_copy:
            by_hand = (f"; end the Notepad of this run in the guest, then make {NOTEPAD_STATE} equal to the copy in {self.notepad_copy} "
                       "(delete the files that are not in the copy" + ("" if self.notepad_names is not None else "; the folder did not exist before the run") + ")")
        try:
            with Client(self.c.socket_path) as c:
                self.restore(c, by_hand)
        except ControlError as e:
            self.cleanup_error(f"the control server failed ({e}); check the guest for jobs of this run in vm.exec.list and for {GUEST}{by_hand}")

    def restore(self, c, by_hand):
        status = c.call("vm.status", 60, name=self.vm)
        if status.get("state") != "running" or status.get("tools") is not True:
            if self.jobs or self.wrote_guest or self.notepad_copy:
                self.cleanup_error(f"'{self.vm}' is {status.get('state')} with tools {status.get('tools')!r}, so the guest was not cleaned; "
                                   f"start it and delete {GUEST}{by_hand}")
            return
        listed = {j["job"]: j["state"] for j in c.call("vm.exec.list", 60, name=self.vm)["jobs"]}
        for job in self.jobs:
            if listed.get(job) == "running":
                try:
                    c.call("vm.exec.kill", 120, name=self.vm, job=job)
                except ControlError as e:
                    self.cleanup_error(f"vm.exec.kill of job {job} answered {e}")
        if self.notepad_copy:
            try:
                left = self.end_notepads(c)
                if left:
                    self.cleanup_error(f"the Notepad processes {sorted(left)} still run, so Notepad's saved tabs were not put back{by_hand}")
                else:
                    self.restore_notepad(c)
                    shutil.rmtree(self.notepad_copy, ignore_errors=True)
            except (ControlError, Failure, OSError) as e:
                self.cleanup_error(f"Notepad's saved tabs were not put back ({e}){by_hand}")
        if self.wrote_guest:
            try:
                c.call("vm.fs.delete", 120, name=self.vm, path=GUEST, recursive=True)
            except ControlError as e:
                self.cleanup_error(f"vm.fs.delete of {GUEST} answered {e}; delete the folder in the guest by hand")


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


@check("vm.screenshot returns half-size JPEGs through the frame path and exactly the region asked for")
def _(run):
    width, height = run.frame()
    run.call("vm.screenshot", scale=0.5, format="jpeg")
    took = []
    for _ in range(SHOTS):
        began = time.monotonic()
        shot = run.call("vm.screenshot", scale=0.5, format="jpeg")
        took.append((time.monotonic() - began) * 1000)
        image = jpeg_size(base64.b64decode(shot["jpeg"]))
        expect(shot["scale"] == 0.5 and shot["mime"] == "image/jpeg" and "png" not in shot,
               f"scale 0.5 as JPEG answered scale {shot['scale']!r}, mime {shot['mime']!r}, fields {sorted(shot)!r}")
        expect((shot["width"], shot["height"]) == (width, height) and (shot["sentWidth"], shot["sentHeight"]) == (width // 2, height // 2)
               and image == (width // 2, height // 2),
               f"a {width}x{height} frame at scale 0.5 reports frame {shot['width']}x{shot['height']}, "
               f"image {shot['sentWidth']}x{shot['sentHeight']} and its JPEG is {image[0]}x{image[1]}")
        expect((shot["x"], shot["y"], shot["areaWidth"], shot["areaHeight"]) == (0, 0, width, height),
               f"the whole frame reports area {shot['x']},{shot['y']} {shot['areaWidth']}x{shot['areaHeight']}")
    mean = sum(took) / len(took)
    expect(mean <= MAX_MEAN_SHOT_MS, f"{SHOTS} screenshots at scale 0.5 as JPEG took {mean:.1f} ms each on average, more than {MAX_MEAN_SHOT_MS} ms")

    region = {"x": width // 8, "y": height // 8, "w": width // 4, "h": height // 4}
    shot = run.call("vm.screenshot", region=region)
    image = png_size(base64.b64decode(shot["png"]))
    expect(image == (region["w"], region["h"]) and (shot["sentWidth"], shot["sentHeight"]) == image and shot["scale"] == 1 and shot["mime"] == "image/png",
           f"region {region!r} returned a {image[0]}x{image[1]} PNG, sent {shot['sentWidth']}x{shot['sentHeight']}, scale {shot['scale']!r}")
    expect((shot["x"], shot["y"], shot["areaWidth"], shot["areaHeight"], shot["width"], shot["height"]) == (region["x"], region["y"], region["w"], region["h"], width, height),
           f"region {region!r} reports area {shot['x']},{shot['y']} {shot['areaWidth']}x{shot['areaHeight']} of a {shot['width']}x{shot['height']} frame")

    corner = {"x": width - 100, "y": height - 60, "w": 400, "h": 400}
    shot = run.call("vm.screenshot", region=corner, scale=0.5, format="jpeg")
    image = jpeg_size(base64.b64decode(shot["jpeg"]))
    expect((shot["x"], shot["y"], shot["areaWidth"], shot["areaHeight"]) == (width - 100, height - 60, 100, 60) and image == (50, 30) and shot["scale"] == 0.5,
           f"a region that leaves the frame reports area {shot['x']},{shot['y']} {shot['areaWidth']}x{shot['areaHeight']}, a {image[0]}x{image[1]} JPEG and scale {shot['scale']!r}")
    message = run.refusal("vm.screenshot", region={"x": width, "y": 0, "w": 10, "h": 10})
    expect(message == f"region is outside the {width}x{height} frame", f"a region outside the frame failed with {message!r}")
    message = run.refusal("vm.screenshot", format="gif")
    expect(message == "format must be 'png' or 'jpeg'", f"format gif failed with {message!r}")
    return f"{width}x{height} frame; {SHOTS} JPEGs at scale 0.5: mean {mean:.1f} ms, {min(took):.1f} to {max(took):.1f} ms; region {region['w']}x{region['h']} exact"


@check("Notepad opens a UTF-8 file, vm.wait_for sees its English line and vm.find_text finds its Korean line inside the frame")
def _(run):
    width, height = run.frame()
    began = time.monotonic()
    run.launch_notepad()
    seen = run.wait_for([{"type": "text_visible", "text": ENGLISH, "languages": LATIN}], timeout=60)
    opened = time.monotonic() - began
    expect(seen["matched"] == 0 and seen["type"] == "text_visible", f"vm.wait_for text_visible '{ENGLISH}' answered {seen!r}")
    detail = seen["detail"]
    expect(squeezed(ENGLISH) in squeezed(detail["text"]) and inside(detail, width, height)
           and (detail["cx"], detail["cy"]) == (detail["x"] + detail["w"] // 2, detail["y"] + detail["h"] // 2),
           f"the detail of the match is {detail!r} in a {width}x{height} frame")

    read = lines(run.exec(f"Get-Content -LiteralPath '{OCR_FILE}' -Encoding UTF8"))
    expect(read == [ENGLISH, KOREAN], f"vm.exec read {read!r} from {OCR_FILE}, expected {[ENGLISH, KOREAN]!r}")

    plain = run.find(ENGLISH)["matches"]
    expect(any(abs(m["x"] - detail["x"]) <= 16 and abs(m["y"] - detail["y"]) <= 8 for m in plain),
           f"vm.find_text '{ENGLISH}' without languages returned {plain!r}; with {LATIN} the line is at {detail['x']},{detail['y']}")

    found = run.find(KOREAN)
    expect(len(found["matches"]) == 1, f"vm.find_text '{KOREAN}' returned {[m['text'] for m in found['matches']]!r} of {found['lines']} lines")
    match = found["matches"][0]
    expect(squeezed(match["text"]) == squeezed(KOREAN) and inside(match, width, height) and 0 < match["confidence"] <= 1
           and (match["cx"], match["cy"]) == (match["x"] + match["w"] // 2, match["y"] + match["h"] // 2),
           f"the Korean match is {match!r} in a {width}x{height} frame")
    expect(match["y"] > detail["y"] and abs(match["x"] - detail["x"]) <= 16,
           f"the Korean line at {match['x']},{match['y']} is not below the English line at {detail['x']},{detail['y']}")

    everything = run.find("")
    expect(everything["lines"] == len(everything["matches"]) >= 2, f"an empty query returned {len(everything['matches'])} matches of {everything['lines']} lines")
    same_row = [m["text"] for m in everything["matches"] if abs(m["cy"] - detail["cy"]) <= 6 and abs(m["x"] - detail["x"]) <= 16]
    outside = [m for m in everything["matches"] if not inside(m, width, height)]
    expect(not outside, f"lines with a rectangle outside the {width}x{height} frame: {outside!r}")
    order = [(m["y"] + m["h"] // 2, m["x"]) for m in everything["matches"]]
    expect(all(b[0] >= a[0] - ROW_SLACK for a, b in zip(order, order[1:])), f"the lines are not in reading order (centre y, x): {order!r}")

    band = {"x": 0, "y": max(0, match["y"] - 40), "w": width, "h": match["h"] + 80}
    banded = run.find(KOREAN, region=band)
    expect(len(banded["matches"]) == 1 and abs(banded["matches"][0]["x"] - match["x"]) <= 8 and abs(banded["matches"][0]["y"] - match["y"]) <= 8
           and banded["lines"] <= everything["lines"],
           f"in the region {band!r} the Korean line is {banded['matches']!r}; in the whole frame it is at {match['x']},{match['y']}")

    began = time.monotonic()
    message = run.refusal("vm.wait_for", conditions=[{"type": "text_visible", "text": "a", "languages": ["xx-XX"]}], timeout=20)
    refused = time.monotonic() - began
    expect(re.fullmatch(LANGUAGE_REFUSAL, message) and refused < 5, f"an unsupported language failed after {refused:.1f} s with {message!r}")
    message = run.refusal("vm.find_text", languages="en-US")
    expect(message == LANGUAGES_TYPE_REFUSAL, f"languages as a string failed with {message!r}")
    return (f"'{detail['text']}' read with {LATIN} {opened:.1f} s after the launch at {detail['x']},{detail['y']}; '{match['text']}' at {match['x']},{match['y']} "
            f"{match['w']}x{match['h']}, confidence {match['confidence']}; {everything['lines']} lines on the screen; "
            f"the default languages read the English line as {same_row!r}")


@check("a click with observe summary reports a settled screen and typing with observe diff returns the changed part")
def _(run):
    width, height = run.frame()
    run.notepad(pristine=True)
    match = run.find_one(KOREAN)
    clicked = run.call("vm.mouse.click", x=match["cx"], y=match["cy"], observe="summary")
    seen = clicked["observation"]
    expect(seen["settled"] is True and (seen["width"], seen["height"]) == (width, height) and 0 <= seen["changedFraction"] <= 1
           and not {"png", "imageRect", "imageScale"} & set(seen),
           f"the click's summary observation is {sorted(seen)!r} with settled {seen.get('settled')!r}, changedFraction {seen.get('changedFraction')!r}")
    expect("changed" not in seen or inside(seen["changed"], width, height), f"the click's changed box {seen.get('changed')!r} leaves the frame")
    expect("observation" not in run.call("vm.mouse.click", x=match["cx"], y=match["cy"]), "a click without observe carries an observation")

    run.notepad_dirty = True
    typed = run.call("vm.type", text="xyz", observe="diff")
    seen = typed["observation"]
    expect(seen["settled"] is True and "changed" in seen and seen["changedFraction"] > 0, f"typing reports settled {seen.get('settled')!r} and fields {sorted(seen)!r}")
    box, shown = seen["changed"], seen["imageRect"]
    expect(inside(box, width, height) and box["x"] % TILE == 0 and box["y"] % TILE == 0, f"the changed box is {box!r} in a {width}x{height} frame")
    expect(box["x"] - TILE <= match["cx"] <= box["x"] + box["w"] + TILE and box["y"] - TILE <= match["cy"] <= box["y"] + box["h"] + TILE,
           f"the changed box {box!r} does not reach the point {match['cx']},{match['cy']} where the text was typed")
    expect(inside(shown, width, height) and shown["x"] <= box["x"] and shown["y"] <= box["y"]
           and shown["x"] + shown["w"] >= box["x"] + box["w"] and shown["y"] + shown["h"] >= box["y"] + box["h"],
           f"the image rectangle {shown!r} does not hold the changed box {box!r} inside the frame")
    data = base64.b64decode(seen["png"])
    image = png_size(data)
    scale = seen["imageScale"]
    expect(image == (round(shown["w"] * scale), round(shown["h"] * scale)) and image[0] <= width and image[1] <= height and image[0] * image[1] < width * height,
           f"the diff image is {image[0]}x{image[1]} for the rectangle {shown!r} at scale {scale!r} in a {width}x{height} frame")
    expect(run.refusal("vm.type", text="x", observe="loud") == "observe must be one of none, summary, diff, image", "an unknown observe level was not refused")
    return (f"click settled, changed {clicked['observation'].get('changed')!r}; typing changed {box['x']},{box['y']} {box['w']}x{box['h']} "
            f"({seen['changedFraction']:.3f} of the frame), diff image {image[0]}x{image[1]}, {len(data)} bytes")


@check("vm.batch runs three steps under one gate, stops at a failing step and refuses an op that is no input")
def _(run):
    run.notepad(pristine=True)
    line = run.find_one(ENGLISH, languages=LATIN)
    run.call("vm.mouse.click", x=line["cx"], y=line["cy"])
    run.notepad_dirty = True
    began = time.monotonic()
    done = run.call("vm.batch", steps=[{"op": "vm.key.press", "keys": "ctrl+a"}, {"op": "vm.type", "text": "batch works"}, {"op": "vm.wait_idle"}])
    took = time.monotonic() - began
    expect(done["completed"] == 3 and done["results"] == [{}, {}, {"idle": True}] and "failedStep" not in done and "error" not in done and "observation" not in done,
           f"the batch of three steps answered {done!r}")
    found = run.find("batch works", languages=LATIN)
    expect(len(found["matches"]) == 1, f"vm.find_text 'batch works' returned {[m['text'] for m in found['matches']]!r} of {found['lines']} lines")
    gone = run.find(ENGLISH, languages=LATIN)
    expect(not gone["matches"], f"'{ENGLISH}' is still on the screen after ctrl+a and typing: {[m['text'] for m in gone['matches']]!r}")

    failed = run.call("vm.batch", observe="summary", steps=[{"op": "vm.key.press", "keys": "end"}, {"op": "vm.type", "text": " again"},
                                                              {"op": "vm.key.press", "keys": "nosuchkey"}, {"op": "vm.type", "text": " never"}])
    expect(failed["completed"] == 2 and failed["failedStep"] == 2 and failed["results"] == [{}, {}] and "nosuchkey" in failed["error"],
           f"a batch with a bad third step answered {dict(failed, observation='...')!r}")
    expect(failed["observation"]["settled"] is True and "changed" in failed["observation"], f"the observation of the failed batch is {failed['observation']!r}")
    after = run.find("batch works", languages=LATIN)
    expect(len(after["matches"]) == 1 and "again" in after["matches"][0]["text"].lower() and "never" not in after["matches"][0]["text"].lower(),
           f"after the failed batch the line reads {[m['text'] for m in after['matches']]!r}; the steps before the failing one must stand, the one after it must not run")

    message = run.refusal("vm.batch", steps=[{"op": "vm.type", "text": " refused"}, {"op": "vm.exec", "command": "hostname"}])
    expect(message == "step 1: 'vm.exec' cannot run in a batch", f"a batch with vm.exec failed with {message!r}")
    still = run.find("refused", languages=LATIN)
    expect(not still["matches"], "the first step of a refused batch ran")
    return f"three steps in {took:.1f} s; the line reads '{after['matches'][0]['text']}'; failedStep 2: {failed['error']}"


@check("vm.wait_for follows a process until it is killed by pid and matches a file and a listening port")
def _(run):
    run.notepad()
    stub, window = run.notepad_stub, run.notepad_window
    exited = [{"type": "process_exited", "processName": "notepad"}]
    waiting = run.wait_for(exited, timeout=3)
    expect(waiting["matched"] == -1 and 3 <= waiting["waited"] < 6 and "type" not in waiting and "problems" not in waiting,
           f"with Notepad running, process_exited answered {waiting!r}")
    started = run.wait_for([{"type": "process_started", "processName": "Notepad.exe"}], timeout=10)
    expect(started["matched"] == 0 and started["detail"]["pid"] in run.started_notepads() and started["detail"]["name"].lower() == "notepad.exe",
           f"process_started answered {started!r}; the run's Notepad processes are {sorted(run.started_notepads())}")

    killed = run.call("vm.process.kill", pid=stub, tree=True)
    expect(killed["killed"] >= 1, f"vm.process.kill of pid {stub} answered {killed!r}")
    gone = run.wait_for(exited, timeout=20)
    expect(gone["matched"] == 0 and gone["type"] == "process_exited" and "detail" not in gone, f"after the kill, process_exited answered {gone!r}")
    by_pid = run.wait_for([{"type": "process_exited", "pid": window}, {"type": "process_exited", "pid": stub}], timeout=10)
    expect(by_pid["matched"] == 0, f"process_exited for the pids {window} and {stub} answered {by_pid!r}")
    run.notepad_window = None

    size = len(OCR_TEXT.encode())
    there = run.wait_for([{"type": "file_exists", "path": OCR_FILE}], timeout=10)
    expect(there["matched"] == 0 and there["type"] == "file_exists" and there["detail"]["size"] == size and there["detail"]["path"].lower() == OCR_FILE.lower(),
           f"file_exists answered {there!r}; the file has {size} bytes")
    port = run.wait_for([{"type": "file_exists", "path": GUEST + r"\missing.txt"}, {"type": "port_listening", "port": AGENT_GUEST_PORT}], timeout=30)
    expect(port["matched"] == 1 and port["type"] == "port_listening", f"a missing file and port {AGENT_GUEST_PORT} answered {port!r}")
    closed = run.wait_for([{"type": "port_listening", "port": CLOSED_GUEST_PORT}], timeout=3)
    expect(closed["matched"] == -1 and "problems" not in closed, f"port_listening on port {CLOSED_GUEST_PORT} answered {closed!r}")
    return (f"process_exited -1 after {waiting['waited']} s, 0 after the kill of pid {stub} within {gone['waited']} s; "
            f"file {size} bytes; port {AGENT_GUEST_PORT} listening after {port['waited']} s")


@check("a click on a screen that keeps changing returns unsettled within its settle timeout")
def _(run):
    width, height = run.frame()
    run.notepad()
    mover = run.start_job(command=MOVE_WINDOW.format(pid=run.notepad_window, seconds=5))
    moving = run.wait_for([{"type": "job_output_matches", "job": mover["job"], "pattern": "^moving"}], timeout=30)
    expect(moving["matched"] == 0, f"the job that moves the Notepad window answered {moving!r}: {run.call('vm.exec.read', job=mover['job'])['err'].strip()}")
    began = time.monotonic()
    clicked = run.call("vm.mouse.click", x=width // 2, y=height // 2, observe="summary", settleTimeoutMs=800)
    took = time.monotonic() - began
    seen = clicked["observation"]
    expect(seen["settled"] is False and seen["changedFraction"] > 0 and inside(seen["changed"], width, height),
           f"a click while the window is maximized and restored every 100 ms reports {seen!r}")
    expect(took <= MAX_UNSETTLED_CLICK_S, f"the click with settleTimeoutMs 800 took {took:.2f} s, more than {MAX_UNSETTLED_CLICK_S} s")

    done = run.wait_for([{"type": "job_output_matches", "job": mover["job"], "pattern": "^done"}], timeout=30)
    expect(done["matched"] == 0, f"the job that moves the window did not finish: {done!r}")
    calm = run.wait_for([{"type": "screen_idle", "seconds": 1}], timeout=20, observe="summary")
    expect(calm["matched"] == 0 and calm["type"] == "screen_idle" and calm["observation"]["settled"] is True, f"after the job, screen_idle answered {calm!r}")
    again = run.call("vm.mouse.click", x=width // 2, y=height // 2, observe="summary", settleTimeoutMs=800)
    expect(again["observation"]["settled"] is True, f"a click on the calm screen reports {again['observation']!r}")
    message = run.refusal("vm.mouse.click", x=1, y=1, observe="summary", settleMs=900, settleTimeoutMs=800)
    expect(message == "settleMs (900) must not exceed settleTimeoutMs (800); lower settleMs or raise settleTimeoutMs", f"settleMs above settleTimeoutMs failed with {message!r}")
    return f"unsettled after {took:.2f} s with {seen['changedFraction']:.2f} of the frame changed; settled again once the window stood still"


@check("the MCP server finds text and reports the screen after a click")
def _(run):
    run.notepad(pristine=True)
    m = run.mcp()
    err, out, images = m.call("alcove_find_text", {"name": run.vm, "query": KOREAN})
    rows = lines(out)
    point = re.fullmatch(r'"(.*)" at \((\d+), (\d+)\) \[(\d+),(\d+) (\d+)x(\d+)\]', rows[1]) if len(rows) == 2 else None
    expect(not err and rows[0] == "1 matches" and point and squeezed(point.group(1)) == squeezed(KOREAN) and not images,
           f"alcove_find_text answered error={err} {out!r}")
    x, y = int(point.group(2)), int(point.group(3))
    direct = run.find_one(KOREAN)
    expect(abs(direct["cx"] - x) <= 4 and abs(direct["cy"] - y) <= 4, f"alcove_find_text places the line at {x},{y}; vm.find_text at {direct['cx']},{direct['cy']}")

    err, out, images = m.call("alcove_click", {"name": run.vm, "x": x, "y": y})
    rows = lines(out)
    expect(not err and rows[0] == f"clicked left at ({x}, {y})" and len(rows) >= 3 and rows[1] == "screen settled" and not images
           and (rows[2] == "nothing changed" or re.fullmatch(r"changed \(\d+,\d+\) \d+x\d+ = \d+\.\d% of the frame", rows[2])),
           f"alcove_click with the default observe answered error={err} {out!r}")
    err, none, _ = m.call("alcove_click", {"name": run.vm, "x": x, "y": y, "observe": "none"})
    expect(not err and lines(none) == [f"clicked left at ({x}, {y})"], f"alcove_click with observe none answered error={err} {none!r}")
    err, missing, _ = m.call("alcove_find_text", {"name": run.vm, "query": "no such text on this screen"})
    expect(not err and re.fullmatch(r"no matches \(\d+ lines of text on screen\)", missing), f"alcove_find_text without a match answered error={err} {missing!r}")
    m.close()
    return "; ".join(rows[:3])


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
    except ControlError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    caps = status.get("agentCaps") or []
    if status.get("state") != "running" or status.get("tools") is not True or any(c not in caps for c in ("rpc", "jobs", "proc", "fs")):
        print(f"FAIL 0: VM '{args.vm}' is {status.get('state')} with tools {status.get('tools')!r} and agent capabilities {caps!r}; "
              "start it with scripts/test/ctl.py vm.start, wait for the guest tools (scripts/test/install-agent.py installs them) and run this script again")
        sys.exit(1)
    run = Run(client, args.vm)

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
