#!/usr/bin/env python3
"""End-to-end run of the evidence operations against a running Windows VM:
vm.record.start, vm.record.status and vm.record.stop with the trace, its frames
and the video, vm.event_log, vm.crash_dumps.enable, disable, list and pull,
vm.collect_diagnostics during a recording, with a hung window, with an old dump
and with the guest agent stopped, and alcove_event_log and
alcove_collect_diagnostics through the MCP server (docs/control-protocol.md,
mcp/).

Needs the VM running with the agent installed as the scheduled task
AlcoveAgent with --allow-exec (scripts/test/install-agent.py), a control
server built from this tree, `npm run build` in mcp/ and the fixture build
build/alcove-fixture-windows-arm64.exe (scripts/test/all.sh), and `xcrun swiftc`,
which builds the program that decodes the videos. The guest must
hold no C:\\alcove-e2e, no C:\\alcove-apps\\alcove-e2e-app, no C:\\alcove-dumps
and no Windows Error Reporting LocalDumps key, run no fixture and show no
window of the fixture, and the VM must not be recording; the script refuses
to start otherwise.

Each check prints `PASS <n> <title>`; the first failing check prints
`FAIL <n>: <reason>` and the script exits 1. The checks start the fixture app
from C:\\alcove-apps\\alcove-e2e-app, crash it with Windows Error Reporting
writing dumps to C:\\alcove-dumps, write entries of the event source AlcoveE2E
into the Application log, write LocalDumps registry keys and stop the guest
agent once through its scheduled task, which a command started in the guest
restarts. Recordings, pulled dumps and bundles go to a temporary directory on
the host. However the run ends, a second connection stops the recording of
the run, ends the processes that run from the two folders by process id,
removes the LocalDumps key, the dump folder and the Windows Error Reporting
reports of the fixture that appeared during the run, deletes the two folders
and the host directory of the run. When a step of that cannot finish, the
script prints `cleanup failed: ...` with what to do by hand and exits 1.
SIGTERM, SIGHUP and SIGINT print `interrupted; restoring the guest...`, run the
same cleanup and exit with 128 plus the signal's number (143, 129, 130); SIGHUP
stays ignored when the script was started with it ignored (nohup).

Usage: at5-e2e.py [--vm NAME] [--only N[,N...]]
"""
import argparse, calendar, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile, time

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout, ignore_stop_signals, stop_signal_handlers
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
UTF16_LOG = GUEST + r"\utf16.log"
UTF16_TEXT = ["첫 줄: 크래시 직전 Ünïcödé 漢字", "두 번째 줄 — 끝"]
DUMPS = r"C:\alcove-dumps"
LOCAL_DUMPS = r"HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
WER_FOLDERS = [r"C:\ProgramData\Microsoft\Windows\WER\ReportArchive", r"C:\ProgramData\Microsoft\Windows\WER\ReportQueue",
               r"C:\ProgramData\Microsoft\Windows\WER\Temp"]
TITLE = "Alcove Fixture"
MESSAGE = '스트리밍 "테스트" 1'
SOURCE = "AlcoveE2E"
MARKER = "alcove e2e marker"
MARKUP_MARKER = "alcove e2e a&b <c> d>e"
MARKUP_PROVIDERS = ["a&b", "a<b", "a>b", "a]b", "a<![CDATA["]
DISABLE_IMAGES = ["alcove-e2e-a.exe", "alcove-e2e-b.exe", "alcove-e2e-x.exe"]
COPY_NOTE = "video.mp4: copied while recording; its last seconds may be missing"
LONG_RECORDING_S = 185
AGENT_STOP_S = 45
RESTART_AGENT_LATER = ("$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "
                       "'cmd.exe /d /c ping -n 4 127.0.0.1 >nul & schtasks /End /TN AlcoveAgent & ping -n SECONDS 127.0.0.1 >nul & "
                       "schtasks /Run /TN AlcoveAgent' }; \"created=$($r.ReturnValue)\"")
REG_QUERY = "$k = 'KEY'; $out = & reg.exe query $k /s /reg:64 2>$null; \"exit=$LASTEXITCODE\"; $out"
VIDEO_PROBE = r'''
import AVFoundation
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let done = DispatchSemaphore(value: 0)
Task {
    var out: [String: Any] = [:]
    do {
        let asset = AVURLAsset(url: url)
        out["playable"] = try await asset.load(.isPlayable)
        out["duration"] = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        out["videoTracks"] = tracks.count
        if let track = tracks.first {
            let size = try await track.load(.naturalSize)
            out["width"] = Int(size.width)
            out["height"] = Int(size.height)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.startReading()
            var frames = 0
            var last = -1.0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil {
                    frames += 1
                    last = max(last, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
            }
            out["decodedFrames"] = frames
            out["lastFrameAt"] = last
            out["readerCompleted"] = reader.status == .completed
            if let error = reader.error { out["readerError"] = "\(error)" }
        }
    } catch {
        out["error"] = "\(error)"
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    done.signal()
}
done.wait()
'''


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l]


def under(path, folder):
    """Whether the guest path lies below the guest folder."""
    return path.lower().startswith(folder.lower() + "\\")


def guest_time(text):
    """Seconds since the epoch of a guest timestamp such as 2026-10-13T09:30:00.1234567Z."""
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?Z", text)
    expect(m is not None, f"{text!r} is not an ISO 8601 UTC time")
    return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float(m.group(2) or 0)


def reg_state(output):
    """The keys and values that `reg query /s` printed: key path (relative to LocalDumps, "" for it) to {value: data},
    without the line reg prints for an unset default value; None when the key does not exist."""
    rows = lines(output)
    expect(rows and rows[0].startswith("exit="), f"reg query printed {output!r}")
    if rows[0] != "exit=0":
        return None
    keys, current = {}, None
    for row in rows[1:]:
        if row.upper().startswith("HKEY_LOCAL_MACHINE\\"):
            rest = row.split("LocalDumps", 1)[1]
            current = rest.lstrip("\\")
            keys[current] = {}
        elif current is not None and row.startswith("    "):
            parts = row.strip().split(None, 2)
            data = parts[2] if len(parts) == 3 else ""
            if parts[0] != "(Default)" or data not in ("", "(value not set)"):
                keys[current][parts[0]] = data
    return keys


class Run:
    """The control connection, the VM and what the checks started or changed in the guest and on the host."""

    def __init__(self, client, vm, apps_existed, wer_before):
        self.c = client
        self.vm = vm
        self.apps_existed = apps_existed
        self.wer_before = wer_before
        self.clients = []
        self.mcps = []
        self.host = None
        self.cleanup_failed = False
        self.wrote_guest = False
        self.deployed = False
        self.fixture_pids = set()
        self.recording = False
        self.enabled = set()
        self.touched_dumps = False
        self.touched_key = False
        self.agent_restarted = False
        self.dump = None
        self.dump_listed = None
        self.probe_path = None

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

    def mcp(self):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at5-e2e")
        return m

    # host and guest folders

    def host_dir(self, *parts):
        """A directory below the run's temporary directory on the host, created when missing."""
        if self.host is None:
            self.host = tempfile.mkdtemp(prefix="alcove-at5-")
        path = os.path.join(self.host, *parts)
        os.makedirs(path, exist_ok=True)
        return path

    def fresh_path(self, *parts):
        """A path below the run's temporary directory on the host that does not exist yet; its parent exists."""
        path = os.path.join(self.host_dir(*parts[:-1]), parts[-1])
        expect(not os.path.exists(path), f"{path} exists already")
        return path

    def app_source(self):
        """The host directory that holds the fixture build under the name the deploy starts."""
        folder = self.host_dir("apps", APP_NAME)
        target = os.path.join(folder, EXE)
        if not os.path.exists(target):
            expect(os.path.exists(FIXTURE_BUILD), f"missing {FIXTURE_BUILD}; build it with scripts/test/all.sh")
            shutil.copyfile(FIXTURE_BUILD, target)
        return folder

    def prepare_guest(self):
        """Creates the run's work folder in the guest."""
        if not self.wrote_guest:
            self.wrote_guest = True
            self.call("vm.fs.write", path=GUEST + r"\run.txt", text="at5-e2e\n")

    def read(self, path):
        return self.call("vm.fs.read", path=path)["text"]

    def log(self):
        return lines(self.read(FIXTURE_LOG))

    # processes and the fixture

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

    def fixture_window(self):
        for w in self.call("vm.window.list")["windows"]:
            if w["title"] == TITLE and w["pid"] in self.fixture_pids and w["responding"]:
                return w
        return None

    def fixture(self, fresh=False):
        """The window of the run's fixture: the one that is open and responding, or the one of a new process.
        With `fresh` the running fixtures are ended first."""
        if fresh:
            self.end_fixtures()
        window = self.fixture_window()
        if window is None:
            self.end_fixtures()
            self.prepare_guest()
            if self.deployed:
                r = self.call("vm.app.launch", path=APP_EXE, args=["--log", FIXTURE_LOG])
            else:
                self.deployed = True
                r = self.call("vm.deploy", 600, path=self.app_source(), launch={"exe": EXE, "args": ["--log", FIXTURE_LOG]})
            self.fixture_pids.add(r["pid"])
            expect(r.get("window") and r["window"]["title"] == TITLE, f"the fixture started without its window: {r!r}")
            window = r["window"]
        return window

    def focus(self):
        """Brings the fixture window to the foreground, through a click on its title bar when focus is refused."""
        try:
            found = self.call("vm.window.action", window=TITLE, action="focus")["window"]
        except ControlTimeout:
            raise
        except ControlError as e:
            if "did not come to the foreground; click its title bar through the display" not in str(e):
                raise
            behind = [w for w in self.call("vm.window.list")["windows"] if w["title"] == TITLE][0]
            self.call("vm.mouse.click", x=behind["x"] + behind["w"] // 2, y=behind["y"] + 12)
            time.sleep(0.5)
            found = [w for w in self.call("vm.window.list")["windows"] if w["id"] == behind["id"]][0]
        expect(found["foreground"] is True, f"the fixture window is not in the foreground after vm.window.action focus: {found!r}")
        return found

    def click(self, name, **params):
        return self.call("vm.ui.click", selector={"window": TITLE, "role": "Button", "name": name}, **params)

    def send_message(self, text):
        """Types `text` into Message, clicks Send and waits until the transcript is still."""
        self.call("vm.ui.type", selector={"window": TITLE, "role": "Edit", "name": "Message"}, text=text, clear=True)
        self.click("Send")
        stable = self.wait_for([{"type": "ui_text_stable", "window": TITLE, "role": "Document", "name": "Transcript"}], timeout=30)
        expect(stable["matched"] == 0, f"the transcript did not become still after Send: {stable!r}")

    # evidence

    def video_probe(self, path):
        """What AVFoundation reads from a video file: playable, duration, videoTracks, width, height, and from decoding every
        frame decodedFrames, lastFrameAt (the presentation time of the last one) and readerCompleted."""
        if self.probe_path is None:
            source = os.path.join(self.host_dir("probe"), "probe.swift")
            with open(source, "w") as f:
                f.write(VIDEO_PROBE)
            binary = os.path.join(self.host_dir("probe"), "probe")
            built = subprocess.run(["xcrun", "swiftc", "-o", binary, source], capture_output=True, text=True, timeout=600)
            expect(built.returncode == 0, f"the video probe did not build: {built.stderr[-2000:]}")
            self.probe_path = binary
        r = subprocess.run([self.probe_path, path], capture_output=True, text=True, timeout=120)
        expect(r.returncode == 0, f"the video probe failed on {path}: {r.stderr[-2000:]}")
        return json.loads(r.stdout)

    def expect_video(self, path, minimum, what, last_gap=2.5):
        """Probes the video at `path` and requires one playable video track of at least `minimum` seconds whose frames all decode,
        the last one within `last_gap` seconds of the end."""
        expect(os.path.isfile(path), f"{what}: {path} does not exist")
        probe = self.video_probe(path)
        expect("error" not in probe and "readerError" not in probe and probe.get("playable") is True and probe.get("videoTracks") == 1
               and probe.get("readerCompleted") is True and probe.get("decodedFrames", 0) > 0 and probe.get("duration", 0) >= minimum
               and probe.get("lastFrameAt", -1) >= probe["duration"] - last_gap,
               f"{what}: AVFoundation reads {probe!r} from {path}; expected one playable video track of at least {minimum} s whose "
               f"frames all decode, the last one within {last_gap} s of the end")
        return probe

    def local_dumps(self):
        """The LocalDumps key as reg query shows it: subkey path to values; None when it does not exist."""
        return reg_state(self.exec(REG_QUERY.replace("KEY", LOCAL_DUMPS)))

    def enable(self, exe, **params):
        self.touched_key = self.touched_dumps = True
        r = self.call("vm.crash_dumps.enable", exe=exe, **params)
        self.enabled.add(exe)
        return r

    def disable(self, exe):
        r = self.call("vm.crash_dumps.disable", exe=exe)
        self.enabled.discard(exe)
        return r

    def dumps(self):
        return self.call("vm.crash_dumps.list")["dumps"]

    def crash(self):
        """Crashes a fresh fixture with dumps enabled; returns (pid, the listing row of its dump, seconds from the click to the
        listing)."""
        window = self.fixture(fresh=True)
        pid = window["pid"]
        if EXE not in self.enabled:
            self.enable(EXE)
        self.focus()
        began = time.monotonic()
        clicked = self.click("Crash")
        exited = self.wait_for([{"type": "event", "event": "process.exited", "since": clicked["eventSeq"]}], timeout=30)
        detail = exited.get("detail") or {}
        expect(exited["matched"] == 0 and detail.get("pid") == pid, f"vm.wait_for event process.exited after the click on Crash answered {exited!r}")
        self.fixture_pids.discard(pid)
        while True:
            rows = [d for d in self.dumps() if d["exe"] == EXE and f".{pid}.dmp" in d["file"]]
            if rows:
                break
            expect(time.monotonic() - began < 30, f"vm.crash_dumps.list has no dump of pid {pid} 30 s after the click on Crash: {self.dumps()!r}")
            time.sleep(1)
        self.dump_listed = time.monotonic()
        listed = self.dump_listed - began
        self.dump = rows[0]["file"]
        return pid, rows[0], listed

    def dated_dumps(self, files):
        """The dumps among bundle paths `files` whose time vm.crash_dumps.list reports readably; a bundle keeps a dump
        whose time the guest does not report readably whatever its sinceMinutes."""
        copied = {f[len("dumps/"):] for f in files if f.startswith("dumps/")}
        if not copied:
            return []
        return sorted(d["file"] for d in self.dumps() if d["file"] in copied and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z", d.get("time") or ""))

    def since_without_dump(self):
        """A sinceMinutes of 1 that leaves the run's dump out of a bundle: waits until the dump was listed more than 65 s ago."""
        if self.dump_listed is not None:
            left = self.dump_listed + 65 - time.monotonic()
            if left > 0:
                time.sleep(left)
        return 1

    def collect(self, reply_timeout=300, **params):
        began = time.monotonic()
        r = self.call("vm.collect_diagnostics", reply_timeout, **params)
        return r, time.monotonic() - began

    # cleanup

    def cleanup_error(self, what):
        self.cleanup_failed = True
        print(f"cleanup failed: {what}", flush=True)

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
        for c in self.clients + [self.c]:
            try:
                c.close()
            except Exception:
                pass
        touched = self.wrote_guest or self.deployed or self.recording or self.touched_key or self.touched_dumps
        by_hand = (f"end the processes that run from {APP_DIR} and {GUEST}, delete the key {LOCAL_DUMPS} (reg delete /reg:64), "
                   f"delete {DUMPS}, the WER reports of {EXE} in {', '.join(WER_FOLDERS)} and the two folders")
        try:
            with Client(self.c.socket_path, spawn=False) as c:
                restored = self.restore(c, touched, by_hand)
        except ControlError as e:
            restored = False
            self.cleanup_error(f"the control server failed ({e}); {by_hand}")
        if self.host and restored:
            shutil.rmtree(self.host, ignore_errors=True)
        elif self.host:
            print(f"the host directory {self.host} of this run is kept", flush=True)

    def restore(self, c, touched, by_hand):
        """Puts the guest back; returns whether the guest could be reached."""
        end = time.time() + (AGENT_STOP_S + 120 if self.agent_restarted else 0)
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
        clean = True
        try:
            left = self.end(c, lambda: self.own_processes(c))
            if left:
                clean = False
                self.cleanup_error(f"the processes {[p['pid'] for p in left]!r} of this run still run; end them in the guest")
        except ControlError as e:
            clean = False
            self.cleanup_error(f"the processes of this run could not be ended ({e}); end them in the guest")
        for exe in sorted(self.enabled):
            try:
                c.call("vm.crash_dumps.disable", 120, name=self.vm, exe=exe)
            except ControlError as e:
                self.cleanup_error(f"vm.crash_dumps.disable of {exe} answered {e}; {by_hand}")
        if self.touched_key:
            r = c.call("vm.exec", 90, name=self.vm, timeout=60,
                       command=f"& reg.exe delete '{LOCAL_DUMPS}' /f /reg:64 2>$null | Out-Null; & reg.exe query '{LOCAL_DUMPS}' /reg:64 2>$null | Out-Null; \"exit=$LASTEXITCODE\"")
            if lines(r["stdout"])[-1:] != ["exit=1"]:
                self.cleanup_error(f"the key {LOCAL_DUMPS} is still there ({r['stdout'].strip()} {r['stderr'].strip()}); delete it with reg delete /reg:64")
        if self.touched_dumps:
            self.delete(c, DUMPS)
        self.remove_reports(c)
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
                    if "does not exist" not in str(e):
                        self.cleanup_error(f"{APPS} could not be removed ({e}); delete the empty folder in the guest")
        if self.wrote_guest:
            self.delete(c, GUEST)
        return True

    def remove_reports(self, c):
        """Deletes the Windows Error Reporting entries that name the fixture and were not there before the run."""
        try:
            now = wer_entries(c, self.vm)
        except ControlError as e:
            self.cleanup_error(f"the WER folders could not be listed ({e}); delete the reports of {EXE} that this run left")
            return
        for path in sorted(set(now) - set(self.wer_before)):
            if "alcove-fixture" in path.lower():
                self.delete(c, path)

    def delete(self, c, path):
        """Deletes a guest file or folder of the run; tries again for 20 s while a file in it is still in use."""
        end = time.time() + 20
        while True:
            try:
                c.call("vm.fs.delete", 120, name=self.vm, path=path, recursive=True)
                return
            except ControlTimeout:
                raise
            except ControlError as e:
                if "does not exist" in str(e) or "not found" in str(e).lower():
                    return
                if time.time() > end:
                    self.cleanup_error(f"vm.fs.delete of {path} answered {e}; delete it in the guest by hand")
                    return
                time.sleep(1)


def wer_entries(c, vm):
    """The full paths of the entries of the Windows Error Reporting report folders."""
    found = []
    for folder in WER_FOLDERS:
        try:
            listing = c.call("vm.fs.list", 60, name=vm, path=folder)
        except ControlError as e:
            if "does not exist" in str(e) or "not found" in str(e).lower():
                continue
            raise
        found += [folder + "\\" + e["name"] for e in listing["entries"]]
    return found


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


@check("a recording of typing a message and clicking Send has a playable video of at least 2 s and trace lines with frames for both ops")
def _(run):
    run.fixture(fresh=True)
    run.focus()
    folder = run.fresh_path("recordings", "message")
    began = time.monotonic()
    run.recording = True
    started = run.call("vm.record.start", dir=folder)
    start_s = time.monotonic() - began
    expect(started["dir"] == folder, f"vm.record.start answered {started!r}")
    run.call("vm.ui.type", selector={"window": TITLE, "role": "Edit", "name": "Message"}, text=MESSAGE, clear=True)
    run.click("Send")
    stable = run.wait_for([{"type": "ui_text_stable", "window": TITLE, "role": "Document", "name": "Transcript"}], timeout=30)
    expect(stable["matched"] == 0, f"the transcript did not become still after Send: {stable!r}")
    while time.monotonic() - began < 3.5:
        time.sleep(0.2)
    status = run.call("vm.record.status")
    expect(status["recording"] is True and status["dir"] == folder and status["writeErrors"] == 0 and "videoError" not in status,
           f"vm.record.status answered {status!r}")
    stopping = time.monotonic()
    stopped = run.call("vm.record.stop")
    stop_s = time.monotonic() - stopping
    run.recording = False
    video = os.path.join(folder, "video.mp4")
    expect(stopped["dir"] == folder and stopped.get("video") == video and stopped["writeErrors"] == 0 and "lastWriteError" not in stopped
           and stopped["ops"] >= 2 and stopped.get("videoSeconds", 0) >= 2, f"vm.record.stop answered {stopped!r}")
    size = os.path.getsize(video)
    expect(size > 20 * 1024, f"{video} holds {size} bytes, not more than 20 KiB")
    probe = run.expect_video(video, 2, "the video of the recording")

    with open(stopped["trace"], encoding="utf-8") as f:
        entries = [json.loads(l) for l in lines(f.read())]
    seqs = [e["seq"] for e in entries]
    expect(seqs == list(range(1, len(entries) + 1)) and all(a["ms"] <= b["ms"] for a, b in zip(entries, entries[1:])),
           f"the trace lines have seq {seqs!r} and ms {[e['ms'] for e in entries]!r}")
    for op in ("vm.ui.type", "vm.ui.click"):
        ops = [e for e in entries if e["op"] == op]
        expect(len(ops) == 1 and ops[0]["ok"] is True, f"the trace has {len(ops)} lines for {op}: {ops!r}")
        for side in ("before", "after"):
            path = ops[0].get(side)
            expect(path and os.path.isfile(os.path.join(folder, path)), f"the {op} line names the {side} frame {path!r}, which is not a file in {folder}")
            with open(os.path.join(folder, path), "rb") as f:
                expect(f.read(3) == b"\xff\xd8\xff", f"the {side} frame {path} of {op} is not a JPEG")
    typed = [e for e in entries if e["op"] == "vm.ui.type"][0]
    expect(typed["params"].get("text") == MESSAGE and typed["params"].get("clear") is True,
           f"the vm.ui.type line holds the params {typed['params']!r}; the Message field is not a password element, so the trace keeps "
           f"text {MESSAGE!r} as typed")
    return (f"start {start_s:.2f} s, stop {stop_s:.2f} s; video {size} bytes, {probe['duration']:.2f} s, {probe['width']}x{probe['height']}; "
            f"{stopped['ops']} trace lines, {stopped['frames']} frames, dropped {stopped.get('droppedFrames')}")


@check("vm.event_log lists errors of the last day, and finds an entry written with eventcreate by its provider")
def _(run):
    began = time.monotonic()
    listed = run.call("vm.event_log", level="error", sinceMinutes=1440)
    took = time.monotonic() - began
    entries = listed["entries"]
    expect(isinstance(entries, list) and all(set(e) == {"time", "id", "level", "provider", "message"} and e["level"] in ("critical", "error") for e in entries),
           f"vm.event_log level error answered {listed!r}")
    times = [guest_time(e["time"]) for e in entries]
    expect(times == sorted(times, reverse=True), "the entries are not newest first")
    marker = write_marker(run, MARKER)
    return f"{len(entries)} entries in {took:.2f} s; marker at {marker['time']} found by provider {SOURCE}"


def write_marker(run, text):
    """Writes an Application log entry of the source AlcoveE2E with id 999 and the message `text` and returns it as
    vm.event_log provider=AlcoveE2E finds it."""
    written = run.exec(f"$t = (Get-Date).ToUniversalTime().ToString('o'); & eventcreate.exe /T ERROR /ID 999 /L APPLICATION /SO {SOURCE} "
                       f"/D '{text}' | Out-Null; \"exit=$LASTEXITCODE\"; $t")
    rows = lines(written)
    expect(rows[0] == "exit=0", f"eventcreate printed {written!r}")
    since = guest_time(rows[1])
    end = time.monotonic() + 15
    while True:
        found = run.call("vm.event_log", provider=SOURCE, sinceMinutes=10, max=20)["entries"]
        mine = [e for e in found if e["message"] == text and e["id"] == 999 and e["level"] == "error" and e["provider"] == SOURCE
                and guest_time(e["time"]) >= since - 1]
        if mine:
            return mine[0]
        expect(time.monotonic() < end, f"vm.event_log provider={SOURCE} has no entry {text!r} written at {rows[1]}: {found!r}")
        time.sleep(1)


@check("a crash of the fixture with dumps enabled raises process.exited, lists its dump within 30 s and pulls a file that starts with MDMP")
def _(run):
    expect(run.local_dumps() is None, f"the guest holds the key {LOCAL_DUMPS} before vm.crash_dumps.enable")
    run.fixture(fresh=True)
    enabled = run.enable(EXE)
    expect(enabled["folder"] == DUMPS and enabled["createdKey"] is True, f"vm.crash_dumps.enable answered {enabled!r}")
    key = run.local_dumps()
    expect(key == {"": {"AlcoveCreated": "0x1"}, EXE: {"AlcoveCreated": "0x1", "DumpFolder": DUMPS, "DumpCount": "0x5", "DumpType": "0x1"}},
           f"reg query of {LOCAL_DUMPS} shows {key!r}")
    pid, row, listed = run.crash()
    expect(row["bytes"] > 0 and re.fullmatch(re.escape(EXE) + r"(\(\d+\))?\." + str(pid) + r"\.dmp", row["file"]), f"the dump is listed as {row!r}")
    target = run.fresh_path("dumps", row["file"])
    began = time.monotonic()
    while True:
        try:
            pulled = run.call("vm.crash_dumps.pull", file=row["file"], path=target)
            break
        except ControlError as e:
            expect("is still being written" in str(e) and time.monotonic() - began < 30, f"vm.crash_dumps.pull answered {e}")
            time.sleep(1)
    pull_s = time.monotonic() - began
    with open(target, "rb") as f:
        data = f.read()
    expect(data[:4] == b"MDMP" and pulled["bytes"] == len(data) and pulled["sha256"] == hashlib.sha256(data).hexdigest() and pulled["path"] == target,
           f"vm.crash_dumps.pull answered {pulled!r}; the file holds {len(data)} bytes starting with {data[:4]!r}")
    os.remove(target)
    return f"pid {pid}, dump {row['file']} of {len(data)} bytes listed {listed:.1f} s after the click, pulled in {pull_s:.2f} s; LocalDumps holds AlcoveCreated"


@check("vm.collect_diagnostics during a recording writes every file with the dump, both logs, the trace with its frames and a playable copy of the video")
def _(run):
    if run.dump is None:
        run.crash()
    folder = run.fresh_path("recordings", "collect")
    run.recording = True
    run.call("vm.record.start", dir=folder)
    run.fixture()
    run.focus()
    run.send_message("collect " + MESSAGE)
    run.exec(f"Set-Content -LiteralPath '{UTF16_LOG}' -Encoding Unicode -Value @('{UTF16_TEXT[0]}', '{UTF16_TEXT[1]}')")
    head = run.exec(f"$b = [IO.File]::ReadAllBytes('{UTF16_LOG}'); '{{0:x2}}{{1:x2}}' -f $b[0], $b[1]")
    expect(head == "fffe", f"{UTF16_LOG} starts with the bytes {head}, not the UTF-16LE byte order mark")
    run.click("Titles")
    time.sleep(1)
    age = run.call("vm.record.status")["seconds"]
    bundle = run.fresh_path("bundles", "collect")
    r, took = run.collect(dir=bundle, logFiles=[FIXTURE_LOG, UTF16_LOG], processName="alcove-fixture")
    after = run.call("vm.record.status")
    expect(after["recording"] is True and after["dir"] == folder, f"the recording does not continue after the collection: {after!r}")
    files = set(r["files"])
    wanted = {"screenshot.png", "windows.json", "ui-tree.txt", "processes.json", "eventlog-application.json", "eventlog-system.json",
              "events.json", "doctor.json", "logs/fixture.log", "logs/utf16.log", f"dumps/{run.dump}", "trace.jsonl", "video.mp4", "summary.txt"}
    expect(r["dir"] == bundle and wanted <= files and not [f for f in files if f.endswith(".error.txt")],
           f"the bundle lacks {sorted(wanted - files)!r} or has error files: {sorted(files)!r}; summary:\n{r['summary']}")
    with open(os.path.join(bundle, "summary.txt"), encoding="utf-8") as f:
        summary = f.read()
    expect(summary == r["summary"] + "\n", "summary.txt differs from the summary of the result")
    rows = lines(summary)
    expect(any(l.startswith(f"crash dump {run.dump}: ") and l.endswith(f"collected as dumps/{run.dump}") for l in rows)
           and f"recording: {folder} (running)" in rows and COPY_NOTE in rows and "steps that failed: none" in rows
           and any(l.startswith("process alcove-fixture: running, pid ") for l in rows), f"the summary reads:\n{summary}")
    with open(os.path.join(bundle, "dumps", run.dump), "rb") as f:
        expect(f.read(4) == b"MDMP", f"dumps/{run.dump} does not start with MDMP")
    with open(os.path.join(bundle, "logs", "fixture.log"), encoding="utf-8") as f:
        copied = lines(f.read())
    expect(copied == run.log() or copied == run.log()[-len(copied):], "logs/fixture.log differs from the end of the guest's fixture.log")
    with open(os.path.join(bundle, "logs", "utf16.log"), encoding="utf-8") as f:
        utf16 = f.read()
    expect(lines(utf16) == UTF16_TEXT, f"logs/utf16.log reads {utf16!r}; the guest file holds {UTF16_TEXT!r} in UTF-16LE")

    with open(os.path.join(bundle, "trace.jsonl"), encoding="utf-8") as f:
        trace = [json.loads(l) for l in lines(f.read())]
    named = {e[side] for e in trace for side in ("before", "after") if e.get(side)}
    present = {"frames/" + n for n in os.listdir(os.path.join(bundle, "frames"))} if os.path.isdir(os.path.join(bundle, "frames")) else set()
    expect(named and named == present and f"frames: {len(named)} of {len(named)} copied" in rows,
           f"the copied trace names the frames {sorted(named)!r}; the bundle holds {sorted(present)!r}")
    expect(not any(e["op"] == "vm.collect_diagnostics" for e in trace), "the copied trace holds the line of the collection itself")
    probe = run.expect_video(os.path.join(bundle, "video.mp4"), 1, "the copy of the running video")
    lag = age - probe["duration"]
    expect(-1 <= lag <= 2, f"the copied video lasts {probe['duration']:.2f} s; the recording was {age:.2f} s old when the collection began")

    stopped = run.call("vm.record.stop")
    run.recording = False
    with open(stopped["trace"], encoding="utf-8") as f:
        own = [json.loads(l) for l in lines(f.read()) if '"vm.collect_diagnostics"' in l]
    expect(len(own) == 1 and own[0]["ok"] is True and "before" not in own[0], f"the recording traced the collection as {own!r}")
    run.expect_video(stopped["video"], age, "the video of the recording after vm.record.stop")
    size = sum(os.path.getsize(os.path.join(dp, n)) for dp, _, ns in os.walk(bundle) for n in ns)
    return (f"{len(files)} files, {size} bytes in {took:.1f} s; video copy {probe['duration']:.2f} s at age {age:.2f} s (lag {lag:.2f} s); "
            f"{len(named)} frames")


@check("vm.collect_diagnostics 8 s after a click on Hang names the fixture window as not responding")
def _(run):
    since = run.since_without_dump()
    window = run.fixture(fresh=True)
    run.focus()
    run.click("Hang")
    time.sleep(8)
    bundle = run.fresh_path("bundles", "hang")
    r, took = run.collect(dir=bundle, processName="alcove-fixture", sinceMinutes=since)
    rows = lines(r["summary"])
    stuck = [l for l in rows if l.startswith("window not responding: ")]
    expect(any(f'"{TITLE}" (pid {window["pid"]}, {EXE})' in l for l in stuck) and took < 115,
           f"the collection took {took:.1f} s and its summary reads:\n{r['summary']}")
    expect(not run.dated_dumps(r["files"]), f"the bundle of sinceMinutes {since} holds the dated dumps {run.dated_dumps(r['files'])!r}")
    with open(os.path.join(bundle, "windows.json"), encoding="utf-8") as f:
        listed = [w for w in json.load(f)["windows"] if w["pid"] == window["pid"]]
    expect(listed and listed[0]["responding"] is False, f"windows.json lists the fixture as {listed!r}")
    tree = "ui-tree.txt" if "ui-tree.txt" in r["files"] else "ui-tree.error.txt"
    expect(tree in r["files"], f"the bundle holds neither ui-tree.txt nor ui-tree.error.txt: {sorted(r['files'])!r}")
    with open(os.path.join(bundle, tree), encoding="utf-8") as f:
        tree_text = f.read().strip()
    expect(tree == "ui-tree.txt" or "is not responding" in tree_text,
           f"ui-tree.error.txt reads {tree_text!r}; expected the UI helper's sentence that the window is not responding")
    left = run.end(run.c, lambda: [p for p in run.own_processes() if p["pid"] == window["pid"]])
    expect(not left, f"the hung fixture pid {window['pid']} still runs 15 s after vm.process.kill")
    run.fixture_pids.discard(window["pid"])
    return f"{took:.1f} s; {stuck[0]}; {tree}: {tree_text.splitlines()[0][:160] if tree_text else '(empty)'}"


@check("the MCP server reads the marker entry through alcove_event_log and writes a bundle through alcove_collect_diagnostics")
def _(run):
    marker = write_marker(run, MARKER)
    m = run.mcp()
    err, out, images = m.call("alcove_event_log", {"name": run.vm, "provider": SOURCE, "since_minutes": 10, "max": 5})
    block = f"{marker['time']} error {SOURCE} (999)\n  {MARKER}"
    expect(not err and not images and block in out, f"alcove_event_log answered error={err} {out!r}; expected the block {block!r}")
    bundle = run.fresh_path("bundles", "mcp")
    since = run.since_without_dump()
    err, out, images = m.call("alcove_collect_diagnostics", {"name": run.vm, "dir": bundle, "since_minutes": since, "process_name": "alcove-fixture"},
                              timeout=400)
    rows = out.split("\n")
    expect(not err and not images and f"directory: {bundle}" in rows and "files:" in rows and "  summary.txt" in rows
           and not run.dated_dumps([row.strip() for row in rows]), f"alcove_collect_diagnostics answered error={err} {out!r}")
    with open(os.path.join(bundle, "summary.txt"), encoding="utf-8") as f:
        summary = f.read()
    expect(out.startswith(summary.rstrip("\n") + "\ndirectory: "), "the tool text does not start with summary.txt")
    m.close()
    return f"{len(rows) - rows.index('files:') - 1} files listed; marker block found"


@check("vm.crash_dumps.disable removes a LocalDumps key only when Alcove created it and nothing else uses it")
def _(run):
    for exe in sorted(run.enabled):
        run.disable(exe)
    expect(run.local_dumps() is None, f"the key {LOCAL_DUMPS} is still there after every image of this run was disabled: {run.local_dumps()!r}")
    a, b, x = DISABLE_IMAGES
    marker = {"AlcoveCreated": "0x1"}
    values = {**marker, "DumpFolder": DUMPS, "DumpCount": "0x5", "DumpType": "0x1"}
    run.touched_key = True
    seen = []

    def state(step, wanted):
        now = run.local_dumps()
        expect(now == wanted, f"{step}: reg query shows {now!r}, expected {wanted!r}")
        seen.append(step)

    r = run.enable(a)
    expect(r["createdKey"] is True, f"vm.crash_dumps.enable of {a} on a guest without the key answered {r!r}")
    state("a: enable A", {"": marker, a: values})
    run.disable(a)
    state("a: disable A", None)

    run.enable(a)
    run.exec(f"& reg.exe add '{LOCAL_DUMPS}' /v Other /t REG_DWORD /d 1 /f /reg:64 | Out-Null")
    state("b: user value added", {"": {**marker, "Other": "0x1"}, a: values})
    run.disable(a)
    state("b: disable A", {"": {**marker, "Other": "0x1"}})
    run.exec(f"& reg.exe delete '{LOCAL_DUMPS}' /f /reg:64 | Out-Null")

    run.exec(f"& reg.exe add '{LOCAL_DUMPS}' /f /reg:64 | Out-Null")
    state("c: user-made empty key", {"": {}})
    run.disable(x)
    state("c: disable X never enabled", {"": {}})
    r = run.enable(a)
    expect(r["createdKey"] is False, f"vm.crash_dumps.enable of {a} on a key that existed answered {r!r}")
    state("c: enable A", {"": {}, a: values})
    run.disable(a)
    state("c: disable A", {"": {}})
    run.exec(f"& reg.exe delete '{LOCAL_DUMPS}' /f /reg:64 | Out-Null")

    run.enable(a)
    r = run.enable(b)
    expect(r["createdKey"] is False, f"the second vm.crash_dumps.enable answered {r!r}")
    state("d: enable A and B", {"": marker, a: values, b: values})
    run.disable(a)
    state("d: disable A", {"": marker, b: values})
    run.disable(b)
    state("d: disable B", None)
    run.enable(a)
    run.exec(f"& reg.exe delete '{LOCAL_DUMPS}\\{a}' /f /reg:64 | Out-Null")
    state("d: A removed by hand", {"": marker})
    run.disable(a)
    state("d: disable A after its key was removed by hand", None)
    return f"{len(seen)} reg query states as expected"


@check("vm.event_log matches a provider in any case, finds a message with & < >, and answers providers with & < > ] with an empty list")
def _(run):
    marker = write_marker(run, MARKER)
    found = {}
    for provider in (SOURCE.lower(), SOURCE.upper(), "aLcOvEe2E"):
        entries = run.call("vm.event_log", provider=provider, sinceMinutes=10, max=20)["entries"]
        found[provider] = len(entries)
        expect(any(e["time"] == marker["time"] and e["provider"] == SOURCE for e in entries), f"provider {provider!r} does not find the marker: {entries!r}")
    markup = write_marker(run, MARKUP_MARKER)
    for contains in ("a&b <c>", "D>E"):
        entries = run.call("vm.event_log", contains=contains, sinceMinutes=10, max=20)["entries"]
        expect(any(e["time"] == markup["time"] and e["message"] == MARKUP_MARKER for e in entries), f"contains {contains!r} does not find {MARKUP_MARKER!r}: {entries!r}")
    for provider in MARKUP_PROVIDERS:
        r = run.call("vm.event_log", provider=provider, sinceMinutes=1440)
        expect(r["entries"] == [], f"provider {provider!r} answered {r!r}")
    return f"case variants {found}; {len(MARKUP_PROVIDERS)} markup providers answered empty lists"


@check("a crash dump older than sinceMinutes on the guest clock is left out of the bundle and counted in the summary")
def _(run):
    if run.dump is None:
        run.crash()
    rows = [d for d in run.dumps() if d["file"] == run.dump]
    expect(rows, f"vm.crash_dumps.list no longer lists {run.dump}")
    moved = run.exec(f"$f = Get-Item -LiteralPath '{DUMPS}\\{run.dump}'; $f.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-3); "
                     "$f.LastWriteTimeUtc.ToString('o')")
    relisted = [d for d in run.dumps() if d["file"] == run.dump]
    expect(relisted and relisted[0]["time"] == moved, f"the listing shows {relisted!r} after the time was set to {moved}")
    bundle = run.fresh_path("bundles", "old-dump")
    r, took = run.collect(dir=bundle, sinceMinutes=30)
    rows = lines(r["summary"])
    older = [l for l in rows if l.startswith("crash dumps older than 30 minutes: ")]
    expect(not any(f.startswith("dumps/") for f in r["files"]) and len(older) == 1 and older[0].endswith(f"the newest from {moved}"),
           f"the bundle holds {r['files']!r}; its summary reads:\n{r['summary']}")
    return f"{older[0]} ({took:.1f} s)"


@check("a recording of more than 3 minutes of screen activity stops with a video that plays to its end and no video error")
def _(run):
    run.fixture(fresh=True)
    run.focus()
    folder = run.fresh_path("recordings", "long")
    run.recording = True
    run.call("vm.record.start", dir=folder)
    began = time.monotonic()
    rounds = 0
    while time.monotonic() - began < LONG_RECORDING_S:
        rounds += 1
        run.click("Titles")
        run.send_message(f"round {rounds} " + MESSAGE)
        status = run.call("vm.record.status")
        expect(status["recording"] is True and status["writeErrors"] == 0 and "videoError" not in status and "lastWriteError" not in status,
               f"vm.record.status after {time.monotonic() - began:.0f} s answered {status!r}")
        time.sleep(3)
    stopping = time.monotonic()
    stopped = run.call("vm.record.stop", 300)
    stop_s = time.monotonic() - stopping
    run.recording = False
    expect(stopped.get("video") and stopped["writeErrors"] == 0 and "lastWriteError" not in stopped and stopped.get("videoSeconds", 0) >= 180,
           f"vm.record.stop answered {stopped!r}")
    probe = run.expect_video(stopped["video"], 180, "the long recording")
    size = os.path.getsize(stopped["video"])
    return (f"{rounds} rounds; {stopped['seconds']} s, video {probe['duration']:.1f} s, {size} bytes, dropped {stopped.get('droppedFrames')}, "
            f"stop {stop_s:.2f} s, last frame at {probe['lastFrameAt']:.2f} s")


@check("with the guest agent stopped vm.collect_diagnostics returns the screenshot and the doctor report and names the skipped guest steps")
def _(run):
    old = [p["pid"] for p in run.processes(filter="alcove-agent") if p["name"].lower() == "alcove-agent.exe"]
    run.agent_restarted = True
    expect(run.exec(RESTART_AGENT_LATER.replace("SECONDS", str(AGENT_STOP_S))) == "created=0",
           "the guest did not start the command that stops and restarts the scheduled task AlcoveAgent")
    began = time.monotonic()
    while run.call("vm.status").get("tools") is not False:
        expect(time.monotonic() - began < 30, "vm.status still reports the guest tools 30 s after the agent was told to stop")
        time.sleep(0.5)
    bundle = run.fresh_path("bundles", "agent-stopped")
    r, took = run.collect(dir=bundle, logFiles=[FIXTURE_LOG])
    files = set(r["files"])
    rows = lines(r["summary"])
    guest_steps = ("windows", "ui-tree", "processes", "eventlog-", "jobs", "logs/", "dumps")
    expect(took < 115 and {"screenshot.png", "doctor.json", "events.json", "summary.txt"} <= files
           and not [f for f in files if f.startswith(guest_steps)],
           f"the collection took {took:.1f} s and wrote {sorted(files)!r}")
    note = (f"guest tools are not connected in '{run.vm}'; install alcove-agent in the guest. Collected: screenshot, doctor report, guest events "
            "and recording files. Skipped: windows, UI tree, processes, event logs, jobs, log files and crash dumps")
    expect(note in rows, f"the summary does not name the skipped guest steps:\n{r['summary']}")
    with open(os.path.join(bundle, "doctor.json"), encoding="utf-8") as f:
        tools = [c for c in json.load(f)["checks"] if c["id"] == "tools"]
    expect(tools and tools[0]["ok"] is False, f"doctor.json reports the tools as {tools!r}")
    while True:
        status = run.call("vm.status")
        agents = [p["pid"] for p in run.processes(filter="alcove-agent") if p["name"].lower() == "alcove-agent.exe"] if status.get("tools") else []
        if agents and agents != old:
            break
        expect(time.monotonic() - began < AGENT_STOP_S + 120, f"the guest tools are not back {AGENT_STOP_S + 120} s after the agent was stopped")
        time.sleep(2)
    return f"{took:.1f} s, {len(files)} files; agent pid {old} replaced by {agents} after {time.monotonic() - began:.0f} s"


def refusal_to_start(client, vm):
    """What of this run's folders, keys, windows and processes the guest already holds; empty when the run can start.
    Also returns whether the apps root exists."""
    found = []
    answers = lines(client.call("vm.exec", 90, name=vm, timeout=60,
                                command=f"(Test-Path -LiteralPath '{GUEST}'), (Test-Path -LiteralPath '{APP_DIR}'), (Test-Path -LiteralPath '{APPS}'), "
                                        f"(Test-Path -LiteralPath '{DUMPS}'), (Test-Path -LiteralPath 'Registry::{LOCAL_DUMPS.replace('HKLM', 'HKEY_LOCAL_MACHINE')}')")["stdout"])
    for answer, what in zip(answers, (f"the folder {GUEST}", f"the folder {APP_DIR}", None, f"the folder {DUMPS}", f"the key {LOCAL_DUMPS}")):
        if what and answer == "True":
            found.append(what)
    for w in client.call("vm.window.list", 120, name=vm)["windows"]:
        if TITLE in w["title"]:
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
        wer_before = wer_entries(client, args.vm)
    except ControlError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    if found:
        print(f"FAIL 0: the guest already holds what this run creates: {'; '.join(found)}; remove it and run this script again")
        sys.exit(1)
    run = Run(client, args.vm, apps_existed, wer_before)
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
            except (OSError, subprocess.SubprocessError) as e:
                failed = f"FAIL {n}: {e}"
            if failed:
                print(failed, flush=True)
                break
            print(f"PASS {n} {title}" + (f" ({note})" if note else ""), flush=True)
    except (KeyboardInterrupt, SystemExit):
        interrupted = True
        raise
    finally:
        ignore_stop_signals()
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
