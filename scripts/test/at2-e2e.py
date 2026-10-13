#!/usr/bin/env python3
"""End-to-end run of the VM state operations against a running Windows VM:
doctor, snapshots, port forwards, the network link, leases, guest environment
settings, resolution, linked clones, sessions that discard changes, and the
state tools of the MCP server (docs/control-protocol.md, mcp/).

Needs the VM running with the agent installed with --allow-exec
(scripts/test/install-agent.py), a headless control server built from this
tree (`alcovectl serve`; the script moves a clone's bundle on disk, so the VM
directory must be the one that server uses) and `npm run build` in mcp/.
Checks 8 and 9 stop and start the VM. Checks 2 and 8 need 8 GiB of free disk.

Each check prints `PASS <n> <title>`; the first failing check prints
`FAIL <n>: <reason>` and the script exits 1. However the run ends, a second
connection releases the lease, moves a hidden clone back and deletes the
clones it created, starts the VM when it is stopped, deletes the snapshot, removes the
forwards and the firewall rule, restores theme, time zone, clock, display
scale and resolution, kills the jobs and deletes C:\\alcove-e2e.

Usage: at2-e2e.py [--vm NAME] [--vm-dir DIR] [--only N[,N...]]
"""
import argparse, base64, glob, json, os, re, shutil, signal, socket, struct, subprocess, sys, tempfile, time

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError, ControlTimeout
from mcp_stdio import MCP, MCPError

GUEST = r"C:\alcove-e2e"
MARKER = GUEST + r"\marker.txt"
SNAPSHOT = "at2-e2e"
GUEST_PORT = 18080
FIREWALL_RULE = "alcove-e2e-forward"
SSH_HOST_PORT = 2222
GIB = 1 << 30
MIN_FREE_GIB = 8
LISTENER = (
    f"$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, {GUEST_PORT}); $l.Start(); 'listening'; "
    "while ($true) { $c = $l.AcceptTcpClient(); $b = [Text.Encoding]::ASCII.GetBytes('alcove-forward-ok'); "
    "$c.GetStream().Write($b, 0, $b.Length); $c.Close() }"
)
UTC_MS = "[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()"
CLOCK_CHANGES = (
    "Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=1} -MaxEvents 4 | ForEach-Object { "
    "'{0} {1}' -f [int](((Get-Date).ToUniversalTime() - $_.TimeCreated.ToUniversalTime()).TotalSeconds), "
    "[int](($_.Properties[0].Value - $_.Properties[1].Value).TotalSeconds) }"
)
THEME_VALUES = (
    "$p = Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'; "
    "'{0} {1}' -f $p.AppsUseLightTheme, $p.SystemUsesLightTheme"
)
LEASE_REFUSAL = r"VM '{vm}' is leased by {owner} for another \d+ s; pass its lease token, wait, or ask the owner to release it"
TEMPLATE_REFUSAL = "start failed: '{vm}' is a template with clones ({clone}); delete the clones first or start a clone"


class Failure(Exception):
    pass


def expect(cond, reason):
    if not cond:
        raise Failure(reason)


def lines(text):
    return [l for l in text.replace("\r\n", "\n").split("\n") if l]


def png_size(data):
    """Width and height from the header of a PNG."""
    expect(data[:8] == b"\x89PNG\r\n\x1a\n", "the screenshot is not a PNG")
    return struct.unpack(">II", data[16:24])


def connect_text(port, timeout=5):
    """What a TCP connection to 127.0.0.1:port delivers until the peer closes: the bytes, or the error as a string."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    except OSError as e:
        return f"connect failed: {e}"
    s.settimeout(timeout)
    data = b""
    try:
        while True:
            piece = s.recv(4096)
            if not piece:
                break
            data += piece
    except OSError as e:
        return f"read failed after {data!r}: {e}"
    finally:
        s.close()
    return data


def agent_hello(port, timeout=5):
    """The `t` of the first line the guest agent sends on a connection to 127.0.0.1:port, or the error as a string."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
            s.settimeout(timeout)
            line = s.makefile("rb").readline()
        return json.loads(line).get("t")
    except (OSError, ValueError) as e:
        return f"failed: {e}"


class Run:
    """The control connection, the VM, its bundle on disk and what the checks created."""

    def __init__(self, client, vm, vm_dir):
        self.c = client
        self.vm = vm
        self.vm_dir = vm_dir
        self.bundle = self.bundle_of(vm)
        self.clone_names = [vm + " e2e clone", vm + " e2e clone 2"]
        self.hidden = None
        self.clones_made = []
        self.jobs = []
        self.forwards = []
        self.leases = []
        self.clients = []
        self.mcps = []
        self.snapshot_made = False
        self.firewall_rule = False
        self.theme = None
        self.time_zone = None
        self.clock_ahead = False
        self.dpi = None
        self.resolution = None
        self.link_down = False
        self.template_agent_port = None

    def bundle_of(self, name):
        """The bundle directory in the VM directory whose config.json has `name`."""
        for config in glob.glob(os.path.join(glob.escape(self.vm_dir), "*.alcovevm", "config.json")):
            try:
                if json.load(open(config)).get("name") == name:
                    return os.path.dirname(config)
            except (OSError, ValueError):
                pass
        return None

    def bundle_kib(self):
        return int(subprocess.run(["du", "-sk", self.bundle], capture_output=True, text=True).stdout.split()[0])

    def free_gib(self):
        return shutil.disk_usage(self.vm_dir).free / GIB

    def need_disk(self):
        free = self.free_gib()
        expect(free >= MIN_FREE_GIB, f"{free:.1f} GiB free on the volume of {self.vm_dir}; this check needs {MIN_FREE_GIB} GiB")

    def call(self, op, reply_timeout=120, **params):
        return self.c.call(op, reply_timeout, name=self.vm, **params)

    def refusal(self, op, client=None, **params):
        """The error message of an operation that must fail."""
        params.setdefault("name", self.vm)
        try:
            reply = (client or self.c).call(op, 120, **params)
        except ControlTimeout:
            raise
        except ControlError as e:
            return str(e)
        raise Failure(f"{op} {params!r} succeeded with {reply!r}; it must fail")

    def exec(self, command, timeout=60):
        r = self.call("vm.exec", timeout + 30, command=command, timeout=timeout)
        expect(r["code"] == 0, f"guest command {command!r} exited with {r['code']}: {r['stderr'].strip() or r['stdout'].strip()}")
        return r["stdout"].strip()

    def start_job(self, command):
        r = self.call("vm.exec.start", command=command)
        self.jobs.append(r["job"])
        return r["job"]

    def job_output(self, job, wanted, timeout=30):
        """Polls vm.exec.read until the job's stdout contains `wanted`."""
        end = time.time() + timeout
        while True:
            r = self.call("vm.exec.read", job=job)
            if wanted in r["out"]:
                return
            expect(r["state"] == "running", f"job {job} exited with {r.get('code')}: {r['err'].strip()}")
            expect(time.time() < end, f"job {job} did not print {wanted!r} within {timeout} s")
            time.sleep(0.3)

    def guest_skew(self):
        """Guest UTC minus host UTC in seconds."""
        before = time.time()
        guest = int(self.exec(UTC_MS)) / 1000
        return guest - (before + time.time()) / 2

    def clock_moved(self, timeout=20):
        """The largest change of the guest clock that Windows logged in the last 15 s, in seconds."""
        end = time.time() + timeout
        while True:
            rows = [tuple(int(v) for v in line.split()) for line in lines(self.exec(CLOCK_CHANGES))]
            recent = [moved for age, moved in rows if age <= 15]
            if recent:
                return max(recent, key=abs)
            expect(time.time() < end, f"the guest logged no clock change in the last 15 s (age and seconds of the latest: {rows!r})")
            time.sleep(1)

    def doctor_row(self, row_id):
        return [r for r in self.call("vm.doctor")["checks"] if r["id"] == row_id][0]

    def wait_tools(self, name=None, timeout=300):
        """Polls vm.status until the guest tools are connected; returns the seconds waited."""
        name = name or self.vm
        began = time.monotonic()
        while True:
            s = self.c.call("vm.status", 60, name=name)
            if s.get("tools") is True:
                return time.monotonic() - began
            expect(s.get("state") == "running", f"'{name}' is {s.get('state')} while waiting for its guest tools: {s.get('error', '')}")
            expect(time.monotonic() - began < timeout, f"the guest tools of '{name}' did not connect within {timeout} s")
            time.sleep(2)

    def start_vm(self, name=None, **params):
        """vm.start; returns the reply and the seconds until the op answered."""
        began = time.monotonic()
        r = self.c.call("vm.start", 300, name=name or self.vm, **params)
        return r, time.monotonic() - began

    def stop_vm(self, name=None):
        r = self.c.call("vm.stop", 300, name=name or self.vm)
        expect(r["state"] == "stopped", f"vm.stop left '{name or self.vm}' {r['state']}")

    def vm_row(self, name):
        for row in self.c.call("vm.list", 60)["vms"]:
            if row["name"] == name:
                return row
        return None

    def client(self):
        c = Client(self.c.socket_path)
        self.clients.append(c)
        return c

    def mcp(self):
        env = dict(os.environ)
        env.pop("ALCOVE_MCP_TOOLSETS", None)
        m = MCP(env)
        self.mcps.append(m)
        m.initialize("at2-e2e")
        return m

    def cleanup(self):
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
        if self.hidden and os.path.isdir(self.hidden[0]) and not os.path.exists(self.hidden[1]):
            try:
                os.rename(self.hidden[0], self.hidden[1])
            except OSError as e:
                print(f"cleanup warning: could not move {self.hidden[0]} back to {self.hidden[1]} ({e}); move it by hand")
        if self.hidden:
            try:
                shutil.rmtree(os.path.dirname(self.hidden[0]))
            except OSError as e:
                print(f"cleanup warning: could not remove {os.path.dirname(self.hidden[0])} ({e}); remove it by hand")
        try:
            with Client(self.c.socket_path) as c:
                self.restore(c)
        except ControlError as e:
            print(f"cleanup: the control server failed ({e}); check vm.list for the clones '{self.clone_names[0]}' and '{self.clone_names[1]}', "
                  f"vm.snapshot.list for '{SNAPSHOT}' and {GUEST} in the guest by hand")

    def restore(self, c):
        def attempt(op, reply_timeout=120, **params):
            params.setdefault("name", self.vm)
            try:
                return c.call(op, reply_timeout, **params)
            except ControlError:
                return None

        for token in self.leases:
            attempt("vm.lease.release", lease=token)
        names = {row["name"]: row for row in c.call("vm.list", 60)["vms"]}
        for clone in self.clones_made:
            if clone in names and names[clone].get("cloneOf") == self.vm:
                attempt("vm.stop", 300, name=clone, force=True)
                if attempt("vm.delete", name=clone) is None:
                    print(f"cleanup: could not delete the clone '{clone}'; delete it with vm.delete")
        status = c.call("vm.status", 60, name=self.vm)
        end = time.time() + 10
        while status.get("leasedBy") and time.time() < end:
            time.sleep(1)
            status = c.call("vm.status", 60, name=self.vm)
        if status.get("leasedBy"):
            print(f"cleanup warning: '{self.vm}' is still leased by '{status['leasedBy']}'; the guest restore will be refused until the lease ends")
        if status.get("ephemeral"):
            attempt("vm.stop", 300)
            status = c.call("vm.status", 60, name=self.vm)
        if status.get("state") != "running":
            if attempt("vm.start", 300) is None:
                print(f"cleanup: could not start '{self.vm}'; start it with vm.start")
                return
        if self.link_down:
            attempt("vm.set_network", up=True)
        end = time.time() + 300
        while not (attempt("vm.status", 60) or {}).get("tools"):
            if time.time() > end:
                print(f"cleanup: the guest tools of '{self.vm}' are not connected; the guest was not cleaned")
                return
            time.sleep(2)
        if self.snapshot_made:
            attempt("vm.snapshot.delete", 660, snapshot=SNAPSHOT)
        listed = {f["hostPort"] for f in (attempt("vm.forward.list") or {}).get("forwards", []) if f["kind"] == "runtime"}
        for port in self.forwards:
            if port in listed:
                attempt("vm.forward.remove", hostPort=port)
        for job in self.jobs:
            attempt("vm.exec.kill", job=job)
        settings = {}
        if self.theme:
            settings["theme"] = self.theme
        if self.time_zone:
            settings["timeZone"] = self.time_zone
        if self.clock_ahead:
            settings["clock"] = "host"
        if self.dpi:
            settings["dpiScale"] = self.dpi
        if settings:
            attempt("vm.set_environment", 200, **settings)
        if self.resolution:
            attempt("vm.set_resolution", width=self.resolution[0], height=self.resolution[1])
        if self.firewall_rule:
            attempt("vm.exec", command=f"Remove-NetFirewallRule -DisplayName '{FIREWALL_RULE}' -ErrorAction SilentlyContinue", timeout=60)
        attempt("vm.fs.delete", path=GUEST, recursive=True)


CHECKS = []


def check(title):
    def add(fn):
        CHECKS.append((len(CHECKS) + 1, title, fn))
        return fn
    return add


@check("vm.doctor reports every check ok")
def _(run):
    rows = run.call("vm.doctor")["checks"]
    ids = [r["id"] for r in rows]
    expected = ["engine", "host", "state", "display", "tools", "rpc", "exec", "session", "disk", "clock", "network", "scale"]
    expect(ids == expected, f"vm.doctor rows are {ids}, expected {expected}")
    bad = [f"{r['id']}: {r['detail']} ({r.get('hint', 'no hint')})" for r in rows if r["ok"] is not True]
    expect(not bad, "vm.doctor rows that are not ok: " + "; ".join(bad))
    expect(all("hint" not in r for r in rows), f"an ok row carries a hint: {rows!r}")
    return "; ".join(f"{r['id']}={r['detail']}" for r in rows)


@check("a snapshot is created, restored twice with tools and clock, listed and deleted")
def _(run):
    run.need_disk()
    expect(SNAPSHOT not in [s["name"] for s in run.call("vm.snapshot.list")["snapshots"]],
           f"a snapshot named '{SNAPSHOT}' exists already; delete it with vm.snapshot.delete")
    run.call("vm.fs.write", path=MARKER, text="before")
    size_before = run.bundle_kib()
    taken = began = time.monotonic()
    created = run.call("vm.snapshot.create", 660, snapshot=SNAPSHOT)
    create_s = time.monotonic() - began
    run.snapshot_made = True
    expect(created["snapshot"] == SNAPSHOT, f"vm.snapshot.create answered {created!r}")
    growth_mib = (run.bundle_kib() - size_before) / 1024

    message = run.refusal("vm.snapshot.create", snapshot=SNAPSHOT)
    expect(message == f"a snapshot named '{SNAPSHOT}' already exists in '{run.vm}'; call vm.snapshot.delete first or choose another name",
           f"creating an existing snapshot failed with {message!r}")
    message = run.refusal("vm.snapshot.create", snapshot="")
    expect(message == "snapshot name must be 1 to 128 characters without a line break; choose another name",
           f"creating a snapshot with an empty name failed with {message!r}")
    hint = f"no snapshot 'at2-e2e-missing' in '{run.vm}'; call vm.snapshot.list"
    for op in ("vm.snapshot.restore", "vm.snapshot.delete"):
        message = run.refusal(op, snapshot="at2-e2e-missing")
        expect(message == hint, f"{op} of an unknown snapshot failed with {message!r}")

    row = [s for s in run.call("vm.snapshot.list")["snapshots"] if s["name"] == SNAPSHOT]
    expect(len(row) == 1 and row[0]["vmStateBytes"] > 0 and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", row[0]["date"]),
           f"vm.snapshot.list shows {row!r}")
    state_mib = row[0]["vmStateBytes"] / (1 << 20)

    forward = run.call("vm.forward.add", guestPort=7645)["hostPort"]
    run.forwards.append(forward)
    expect(agent_hello(forward) == "hello", f"a forward to the agent port delivers {agent_hello(forward)!r} before the restores")
    restores = []
    for attempt in (1, 2):
        run.call("vm.fs.write", path=MARKER, text=f"after {attempt}")
        expect(run.call("vm.fs.read", path=MARKER)["text"] == f"after {attempt}", "the marker file did not take the new text")
        time.sleep(5)
        began = time.monotonic()
        r = run.call("vm.snapshot.restore", 660, snapshot=SNAPSHOT)
        restore_s = time.monotonic() - began
        behind = time.monotonic() - taken
        expect(r["snapshot"] == SNAPSHOT and r["tools"] is True and r["clockSynced"] is True,
               f"restore {attempt} answered {r!r}; tools and clockSynced must be true")
        text = run.call("vm.fs.read", path=MARKER)["text"]
        expect(text == "before", f"after restore {attempt} the marker file holds {text!r}, expected 'before'")
        skew = run.guest_skew()
        expect(abs(skew) <= 5, f"after restore {attempt} the guest clock is {skew:+.1f} s from the host")
        moved = run.clock_moved()
        expect(abs(moved - behind) <= 10, f"restore {attempt} moved the guest clock by {moved} s; the snapshot was {behind:.0f} s old")
        restores.append(f"restore {attempt} {restore_s:.1f} s, clock moved {moved:+d} s to {skew:+.1f} s of the host")
    expect(agent_hello(forward) == "hello", f"the forward added before the restores delivers {agent_hello(forward)!r} after them")
    listed = [f for f in run.call("vm.forward.list")["forwards"] if f["hostPort"] == forward]
    expect(listed == [{"hostPort": forward, "guestPort": 7645, "kind": "runtime"}], f"after the restores vm.forward.list shows {listed!r}")
    run.call("vm.forward.remove", hostPort=forward)

    m = run.mcp()
    err, out, _ = m.call("alcove_snapshot_restore", {"name": run.vm, "snapshot": SNAPSHOT}, 700)
    expect(not err and out == f"restored '{run.vm}' to snapshot '{SNAPSHOT}'; guest tools reconnected; guest clock synced",
           f"alcove_snapshot_restore answered error={err} {out!r}")
    m.close()

    run.call("vm.snapshot.delete", 660, snapshot=SNAPSHOT)
    run.snapshot_made = False
    expect(SNAPSHOT not in [s["name"] for s in run.call("vm.snapshot.list")["snapshots"]], "the deleted snapshot is still listed")
    kept_mib = (run.bundle_kib() - size_before) / 1024
    return (f"create {create_s:.1f} s, memory state {state_mib:.0f} MiB, bundle +{growth_mib:.0f} MiB; " + "; ".join(restores)
            + f"; bundle +{kept_mib:.0f} MiB after the delete")


@check("a runtime forward reaches a guest listener, is listed, refuses taken ports and is removed")
def _(run):
    blocks = run.exec("@(Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue | "
                      "Where-Object { ($_ | Get-NetFirewallApplicationFilter).Program -like '*powershell.exe' }).Count")
    expect(blocks == "0", f"Windows Firewall holds {blocks} inbound Block rules for powershell.exe, which silence the guest listener; "
           "remove them (Get-NetFirewallRule -DisplayName 'Windows PowerShell' | Remove-NetFirewallRule) and run this check again")
    run.firewall_rule = True
    run.exec(f"Remove-NetFirewallRule -DisplayName '{FIREWALL_RULE}' -ErrorAction SilentlyContinue; "
             f"New-NetFirewallRule -DisplayName '{FIREWALL_RULE}' -Direction Inbound -Protocol TCP -LocalPort {GUEST_PORT} -Action Allow | Out-Null")
    job = run.start_job(LISTENER)
    run.job_output(job, "listening")

    added = run.call("vm.forward.add", guestPort=GUEST_PORT)
    port = added["hostPort"]
    run.forwards.append(port)
    expect(added["guestPort"] == GUEST_PORT and 1024 <= port <= 65535, f"vm.forward.add answered {added!r}")
    for attempt in (1, 2):
        got = connect_text(port)
        expect(got == b"alcove-forward-ok", f"connection {attempt} to 127.0.0.1:{port} delivered {got!r}")

    forwards = run.call("vm.forward.list")["forwards"]
    expect({"hostPort": port, "guestPort": GUEST_PORT, "kind": "runtime"} in forwards, f"vm.forward.list lacks the runtime forward: {forwards!r}")
    agent = [f for f in forwards if f["kind"] == "agent"]
    expect(len(agent) == 1 and agent[0]["guestPort"] == 7645, f"vm.forward.list shows the agent forward as {agent!r}")
    expect({"hostPort": SSH_HOST_PORT, "guestPort": 22, "kind": "config"} in forwards, f"vm.forward.list lacks the config forward {SSH_HOST_PORT}: {forwards!r}")
    run.template_agent_port = agent[0]["hostPort"]

    for taken in (port, SSH_HOST_PORT, agent[0]["hostPort"]):
        message = run.refusal("vm.forward.add", guestPort=GUEST_PORT, hostPort=taken)
        expect(message == f"host port {taken} is taken; pass hostPort: 0 to let Alcove choose", f"adding host port {taken} again failed with {message!r}")
    busy = socket.socket()
    busy.bind(("127.0.0.1", 0))
    busy.listen(1)
    try:
        message = run.refusal("vm.forward.add", guestPort=GUEST_PORT, hostPort=busy.getsockname()[1])
        expect(message == f"host port {busy.getsockname()[1]} is taken; pass hostPort: 0 to let Alcove choose",
               f"adding a host port another process listens on failed with {message!r}")
    finally:
        busy.close()
    for fixed in (SSH_HOST_PORT, agent[0]["hostPort"]):
        message = run.refusal("vm.forward.remove", hostPort=fixed)
        expect(message == f"no runtime forward on host port {fixed} in '{run.vm}'; call vm.forward.list "
               "(forwards from the VM configuration cannot be removed while it runs)", f"removing host port {fixed} failed with {message!r}")

    expect(run.call("vm.forward.remove", hostPort=port) is not None, "vm.forward.remove failed")
    got = connect_text(port, timeout=3)
    expect(isinstance(got, str) and got.startswith("connect failed"), f"after vm.forward.remove a connection to 127.0.0.1:{port} gave {got!r}")
    forwards = run.call("vm.forward.list")["forwards"]
    expect(not [f for f in forwards if f["kind"] == "runtime"], f"after vm.forward.remove the list still has runtime forwards: {forwards!r}")
    run.call("vm.exec.kill", job=job)
    return f"127.0.0.1:{port} -> guest {GUEST_PORT}; agent forward on {agent[0]['hostPort']}"


@check("vm.set_network takes the guest link down and up")
def _(run):
    flag = GUEST + r"\link.txt"
    run.call("vm.fs.write", path=flag, text="unset")
    expect(run.exec("Test-Connection 10.0.2.2 -Count 1 -Quiet") == "True", "the guest cannot ping 10.0.2.2 before the link goes down")
    run.start_job(f"Start-Sleep 3; $r = Test-Connection 10.0.2.2 -Count 1 -Quiet; Set-Content -Path '{flag}' -Value $r -Encoding ascii")
    run.link_down = True
    down = run.call("vm.set_network", up=False)
    expect(down["up"] is False, f"vm.set_network up=false answered {down!r}")
    time.sleep(10)
    up = run.call("vm.set_network", up=True)
    expect(up["up"] is True, f"vm.set_network up=true answered {up!r}")
    run.link_down = False
    end = time.time() + 90
    retried = []
    while True:
        try:
            seen = lines(run.call("vm.fs.read", 60, path=flag)["text"])
            break
        except ControlTimeout:
            raise
        except ControlError as e:
            expect("guest tools" in str(e) and time.time() < end, f"reading a guest file after the link came up failed with {str(e)!r}")
            retried.append(str(e))
            time.sleep(1)
    expect(seen == ["False"], f"with the link down the guest's ping of 10.0.2.2 wrote {seen!r}, expected ['False']")
    while run.exec("Test-Connection 10.0.2.2 -Count 1 -Quiet") != "True":
        expect(time.time() < end, "the guest cannot ping 10.0.2.2 within 90 s of the link coming up")
        time.sleep(2)
    return f"ping of 10.0.2.2: True, False with the link down, True again; {len(retried)} guest-tools calls retried after the link came up"


@check("a lease refuses other connections' changes, lets reads through, is released and expires")
def _(run):
    b = run.client()
    pattern = LEASE_REFUSAL.format(vm=re.escape(run.vm), owner="at2-e2e-a")
    acquired = run.call("vm.lease.acquire", owner="at2-e2e-a")
    token = acquired["lease"]
    run.leases.append(token)
    expect(acquired["expiresIn"] == 300, f"vm.lease.acquire without ttl answered {acquired!r}")

    message = run.refusal("vm.mouse.move", client=b, x=640, y=400)
    expect(re.fullmatch(pattern, message), f"another connection's vm.mouse.move failed with {message!r}")
    message = run.refusal("vm.lease.acquire", client=b, owner="at2-e2e-b")
    expect(re.fullmatch(pattern, message), f"another connection's vm.lease.acquire failed with {message!r}")
    message = run.refusal("vm.lease.release", client=b, lease="not-the-token")
    expect(message == f"lease token does not match; only the holder can release '{run.vm}'", f"a release with a wrong token failed with {message!r}")
    shot = b.call("vm.screenshot", 60, name=run.vm, scale=0.25)
    expect(shot["width"] > 0, "vm.screenshot of the other connection returned no frame")
    for source in (b.call("vm.status", 60, name=run.vm), run.vm_row(run.vm)):
        expect(source.get("leasedBy") == "at2-e2e-a", f"leasedBy is {source.get('leasedBy')!r} in {sorted(source)}")
    b.call("vm.mouse.move", 60, name=run.vm, x=640, y=400, lease=token)
    renewed = run.call("vm.lease.acquire", owner="ignored", ttl=99999, lease=token)
    expect(renewed["lease"] == token and renewed["expiresIn"] == 3600, f"renewing with ttl 99999 answered {renewed!r}")

    run.call("vm.lease.release", lease=token)
    run.leases.remove(token)
    b.call("vm.mouse.move", 60, name=run.vm, x=641, y=400)
    expect("leasedBy" not in b.call("vm.status", 60, name=run.vm), "vm.status still shows leasedBy after the release")

    short = run.call("vm.lease.acquire", owner="at2-e2e-a", ttl=2)
    run.leases.append(short["lease"])
    expect(short["expiresIn"] == 2 and short["lease"] != token, f"vm.lease.acquire with ttl 2 answered {short!r}")
    message = run.refusal("vm.mouse.move", client=b, x=640, y=400)
    expect(re.fullmatch(pattern, message), f"during the 2 s lease vm.mouse.move failed with {message!r}")
    time.sleep(3)
    b.call("vm.mouse.move", 60, name=run.vm, x=640, y=400)
    expect("leasedBy" not in b.call("vm.status", 60, name=run.vm), "vm.status still shows leasedBy after the lease expired")
    run.leases.remove(short["lease"])
    return message


@check("vm.set_environment sets theme, time zone, clock and display scale, reports takesEffect and refuses bad values")
def _(run):
    def applied(**settings):
        return run.call("vm.set_environment", 200, **settings)["applied"]

    def one(setting, **settings):
        rows = applied(**settings)
        expect(len(rows) == 1 and rows[0]["setting"] == setting, f"vm.set_environment {settings!r} answered {rows!r}")
        return rows[0]

    original_theme = "light" if run.exec(THEME_VALUES).split()[0] == "1" else "dark"
    original_zone = run.exec("(Get-TimeZone).Id")
    culture = run.exec("(Get-Culture).Name")
    layouts = lines(run.exec("(Get-WinUserLanguageList).LanguageTag"))
    scale = run.doctor_row("scale")["detail"]
    percent = int(re.fullmatch(r"(\d+) %", scale).group(1))

    run.theme = original_theme
    for theme, value in (("dark", "0 0"), ("light", "1 1"), (original_theme, None)):
        row = one("theme", theme=theme)
        expect(row["ok"] is True and row["takesEffect"] == "now", f"theme={theme} answered {row!r}")
        if value:
            expect(run.exec(THEME_VALUES) == value, f"after theme={theme} the registry holds {run.exec(THEME_VALUES)!r}, expected {value!r}")

    run.time_zone = original_zone
    target = "Korea Standard Time" if original_zone != "Korea Standard Time" else "UTC"
    row = one("timeZone", timeZone=target)
    expect(row["ok"] is True and row["takesEffect"] == "now" and row["detail"] == target, f"timeZone={target} answered {row!r}")
    expect(run.exec("(Get-TimeZone).Id") == target, f"the guest time zone is {run.exec('(Get-TimeZone).Id')!r} after timeZone={target}")
    row = one("timeZone", timeZone=original_zone)
    expect(row["ok"] is True and run.exec("(Get-TimeZone).Id") == original_zone, f"restoring the time zone answered {row!r}")

    run.clock_ahead = True
    ahead = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 120))
    row = one("clock", clock=ahead)
    skew = run.guest_skew()
    expect(row["ok"] is True and row["takesEffect"] == "now" and 110 <= skew <= 130, f"clock={ahead} answered {row!r}; the guest is {skew:+.1f} s from the host")
    row = one("clock", clock="host")
    skew = run.guest_skew()
    expect(row["ok"] is True and abs(skew) <= 5, f"clock=host answered {row!r}; the guest is {skew:+.1f} s from the host")
    run.clock_ahead = False

    rows = applied(locale=culture, keyboardLayouts=layouts)
    got = [(r["setting"], r["ok"], r["takesEffect"]) for r in rows]
    expect(got == [("locale", True, "app restart"), ("keyboardLayouts", True, "now")],
           f"locale={culture}, keyboardLayouts={layouts} answered {rows!r}")
    expect(run.exec("(Get-Culture).Name") == culture and lines(run.exec("(Get-WinUserLanguageList).LanguageTag")) == layouts,
           "culture or layouts changed after setting them to their current values")

    run.dpi = percent
    other = 125 if percent != 125 else 100
    for value in (other, percent):
        row = one("dpiScale", dpiScale=value)
        expect(row["ok"] is True and row["takesEffect"] == "now" and row["detail"] == f"scale: {value} %", f"dpiScale={value} answered {row!r}")
        end = time.time() + 15
        while run.doctor_row("scale")["detail"] != f"{value} %":
            expect(time.time() < end, f"15 s after dpiScale={value} vm.doctor reports scale {run.doctor_row('scale')['detail']!r}")
            time.sleep(1)
    run.dpi = None

    row = one("timeZone", timeZone="No Such Zone")
    expect(row["ok"] is False and "No Such Zone" in row["detail"], f"an unknown time zone answered {row!r}")
    expect(run.exec("(Get-TimeZone).Id") == original_zone, "an unknown time zone changed the guest time zone")
    refusals = {
        "theme": ({"theme": "blue"}, "theme must be 'dark' or 'light'"),
        "timeZone": ({"timeZone": "UTC; calc"}, "timeZone must be 1 to 64 characters: letters, digits, space and _ - + / ( ) . :, not starting with '-'"),
        "dpiScale": ({"dpiScale": 50}, "dpiScale must be between 100 and 500"),
        "clock": ({"clock": "tomorrow"}, "clock must be 'host' or an ISO 8601 time such as 2026-10-13T09:30:00Z"),
        "none": ({}, "pass at least one of theme, timeZone, clock, locale, keyboardLayouts, dpiScale"),
    }
    for what, (settings, sentence) in refusals.items():
        message = run.refusal("vm.set_environment", **settings)
        expect(message == sentence, f"vm.set_environment {settings!r} failed with {message!r}")
    run.theme = run.time_zone = None
    return f"theme dark/light, time zone {target} and back to {original_zone}, clock +120 s and host, scale {other} % and back to {percent} % without signing out"


@check("vm.set_resolution changes the guest screen and the screenshot size")
def _(run):
    def shot_size():
        shot = run.call("vm.screenshot")
        return (shot["width"], shot["height"]), png_size(base64.b64decode(shot["png"]))

    original, _ = shot_size()
    target = (1440, 900) if original != (1440, 900) else (1280, 800)
    run.resolution = original
    r = run.call("vm.set_resolution", width=target[0], height=target[1])
    expect((r["width"], r["height"]) == target, f"vm.set_resolution {target} answered {r!r}")
    reported, image = shot_size()
    expect(reported == target and image == target, f"after vm.set_resolution {target} a screenshot reports {reported} and its PNG is {image}")
    r = run.call("vm.set_resolution", width=original[0], height=original[1])
    reported, image = shot_size()
    expect((r["width"], r["height"]) == original and reported == original and image == original,
           f"back at {original}: vm.set_resolution answered {r!r}, a screenshot reports {reported}, its PNG is {image}")
    run.resolution = None
    message = run.refusal("vm.set_resolution", width=100, height=100)
    expect(message == "width must be 320...7680 and height 200...4320", f"vm.set_resolution 100x100 failed with {message!r}")
    return f"{original[0]}x{original[1]} -> {target[0]}x{target[1]} -> {original[0]}x{original[1]}"


@check("a linked clone runs beside its stopped template, guards it, and refuses to start once the template ran")
def _(run):
    run.need_disk()
    clone, second = run.clone_names
    for name in run.clone_names:
        expect(run.vm_row(name) is None,
               f"a VM named '{name}' exists already and this run does not touch it; delete it by hand with "
               f"scripts/test/ctl.py vm.delete name=\"{name}\" (stop it first with vm.stop) or in the Alcove app")
    refusal = TEMPLATE_REFUSAL.format(vm=run.vm, clone=clone)

    forwards = run.call("vm.forward.list")["forwards"]
    template_agent = [f["hostPort"] for f in forwards if f["kind"] == "agent"][0]
    runtime = run.call("vm.forward.add", guestPort=GUEST_PORT)["hostPort"]
    run.forwards.append(runtime)
    message = run.refusal("vm.clone", newName=clone)
    expect(message == f"'{run.vm}' is running; stop it before cloning it", f"cloning the running VM failed with {message!r}")
    run.stop_vm()

    message = run.refusal("vm.delete")
    expect(message == f"'{run.vm}' is not a clone; delete it in the Alcove app", f"vm.delete of the template failed with {message!r}")
    began = time.monotonic()
    cloned = run.call("vm.clone", 300, newName=clone)
    clone_s = time.monotonic() - began
    run.clones_made.append(clone)
    expect(cloned["name"] == clone, f"vm.clone answered {cloned!r}")
    row = run.vm_row(clone)
    expect(row and row.get("cloneOf") == run.vm and row["state"] == "stopped", f"vm.list shows the clone as {row!r}")
    clone_mib = int(subprocess.run(["du", "-sk", run.bundle_of(clone)], capture_output=True, text=True).stdout.split()[0]) / 1024
    message = run.refusal("vm.clone", newName=clone)
    expect(message == f"a VM named '{clone}' already exists; choose another name", f"cloning to an existing name failed with {message!r}")
    message = run.refusal("vm.clone", name=clone, newName=second)
    expect(message == f"'{clone}' is a clone of '{run.vm}'; clone '{run.vm}' instead", f"cloning a clone failed with {message!r}")

    message = run.refusal("vm.start")
    expect(message == refusal, f"starting the template with a stopped clone failed with {message!r}")
    _, boot_s = run.start_vm(clone)
    boot_s += run.wait_tools(clone)
    host = run.c.call("vm.exec", 90, name=clone, command="hostname", timeout=60)["stdout"].strip()
    expect(host, "hostname printed nothing in the clone")
    clone_forwards = run.c.call("vm.forward.list", 60, name=clone)["forwards"]
    clone_agent = [f["hostPort"] for f in clone_forwards if f["kind"] == "agent"]
    expect(len(clone_agent) == 1 and clone_agent[0] != template_agent and [f for f in clone_forwards if f["kind"] != "agent"] == [],
           f"the clone's forwards are {clone_forwards!r}; the template's agent port is {template_agent}")
    message = run.refusal("vm.start")
    expect(message == refusal, f"starting the template while its clone runs failed with {message!r}")
    expect(run.c.call("vm.status", 60, name=run.vm)["state"] in ("stopped", "failed"), "the template is not stopped after the refused start")
    message = run.refusal("vm.delete", name=clone)
    expect(message == f"'{clone}' is running; stop it before deleting it", f"deleting the running clone failed with {message!r}")
    run.stop_vm(clone)
    expect(run.c.call("vm.delete", 120, name=clone) is not None, "vm.delete failed")
    expect(run.vm_row(clone) is None and run.bundle_of(clone) is None, "the deleted clone is still listed or on disk")

    _, _ = run.start_vm()
    run.wait_tools()
    forwards = run.call("vm.forward.list")["forwards"]
    expect(not [f for f in forwards if f["kind"] == "runtime"], f"after the restart vm.forward.list still has runtime forwards: {forwards!r}")
    got = connect_text(runtime, timeout=3)
    expect(isinstance(got, str) and got.startswith("connect failed"), f"after the restart a connection to 127.0.0.1:{runtime} gave {got!r}")
    run.forwards.remove(runtime)
    run.stop_vm()

    run.call("vm.clone", 300, newName=second)
    run.clones_made.append(second)
    path = run.bundle_of(second)
    expect(path, f"the bundle of '{second}' is not in {run.vm_dir}")
    hidden = os.path.join(tempfile.mkdtemp(prefix="at2-e2e-hidden-", dir=os.path.dirname(run.vm_dir.rstrip("/"))), os.path.basename(path))
    run.hidden = (hidden, path)
    os.rename(path, hidden)
    _, _ = run.start_vm()
    run.wait_tools()
    run.stop_vm()
    os.rename(hidden, path)
    os.rmdir(os.path.dirname(hidden))
    run.hidden = None
    stale = run.refusal("vm.start", name=second)
    expect(stale == f"start failed: the template '{run.vm}' was started after '{second}' was cloned from it, "
           "so the clone's disk no longer matches; delete the clone and clone again", f"starting the stale clone failed with {stale!r}")
    message = run.refusal("vm.start")
    expect(message == TEMPLATE_REFUSAL.format(vm=run.vm, clone=second), f"starting the template beside the stale clone failed with {message!r}")
    run.c.call("vm.delete", 120, name=second)
    expect(run.vm_row(second) is None and run.bundle_of(second) is None, "the deleted stale clone is still listed or on disk")
    expect(not os.path.exists(os.path.join(run.bundle, "clones.json")), "the template still has a clones.json after its clones were deleted")

    _, start_s = run.start_vm()
    tools_s = run.wait_tools()
    return (f"vm.clone {clone_s:.2f} s, clone bundle {clone_mib:.0f} MiB; clone '{host}' had tools {boot_s:.0f} s after vm.start, agent port "
            f"{clone_agent[0]} (template {template_agent}); template back with tools after {start_s + tools_s:.0f} s")


@check("a session started with discardChanges leaves nothing behind")
def _(run):
    kept, dropped = GUEST + r"\kept.txt", GUEST + r"\ephemeral.txt"
    run.call("vm.fs.write", path=kept, text="kept")
    message = run.refusal("vm.start", discardChanges=True)
    expect(message == f"VM '{run.vm}' is already running; stop it first to start a session that discards changes",
           f"vm.start discardChanges on the running VM failed with {message!r}")
    run.stop_vm()

    started, start_s = run.start_vm(discardChanges=True)
    expect(started == {**started, "state": "running", "ephemeral": True}, f"vm.start discardChanges answered {started!r}")
    overlays = sorted(os.listdir(os.path.join(run.bundle, "run")))
    expect([n for n in overlays if n.startswith("ephemeral-")], f"the run directory holds no ephemeral files while the session runs: {overlays!r}")
    tools_s = run.wait_tools()
    for source in (run.call("vm.status"), run.vm_row(run.vm)):
        expect(source.get("ephemeral") is True, f"ephemeral is {source.get('ephemeral')!r} in {sorted(source)}")
    expect(run.call("vm.fs.read", path=kept)["text"] == "kept", "the session does not see a file written before it")
    run.call("vm.fs.write", path=dropped, text="gone after the stop")
    run.call("vm.fs.write", path=kept, text="changed in the session")
    run.exec("Write-VolumeCache C")
    run.stop_vm()
    left = [n for n in os.listdir(os.path.join(run.bundle, "run")) if n.startswith("ephemeral-")]
    expect(not left, f"the run directory still holds {left!r} after the stop")

    started, _ = run.start_vm()
    expect(started["ephemeral"] is False, f"the normal vm.start answered {started!r}")
    run.wait_tools()
    for source in (run.call("vm.status"), run.vm_row(run.vm)):
        expect("ephemeral" not in source, f"a normal session reports ephemeral: {source!r}")
    names = [e["name"] for e in run.call("vm.fs.list", path=GUEST)["entries"]]
    expect("ephemeral.txt" not in names and "kept.txt" in names, f"after the session {GUEST} holds {names!r}")
    expect(run.call("vm.fs.read", path=kept)["text"] == "kept", f"kept.txt holds {run.call('vm.fs.read', path=kept)['text']!r} after the session")
    return f"vm.start discardChanges answered after {start_s:.2f} s, tools after {start_s + tools_s:.0f} s; overlays {', '.join(n for n in overlays if n.startswith('ephemeral-'))}"


@check("the MCP server runs doctor, snapshot list, forward list and leases")
def _(run):
    m = run.mcp()
    b = run.client()
    err, out, _ = m.call("alcove_doctor", {"name": run.vm})
    rows = lines(out)
    expect(not err and len(rows) == 12 and all(r.startswith("ok      ") for r in rows) and rows[0].startswith("ok      engine: "),
           f"alcove_doctor answered error={err} {out!r}")
    err, out, _ = m.call("alcove_snapshot_list", {"name": run.vm})
    expect(not err and out == "no snapshots", f"alcove_snapshot_list answered error={err} {out!r}")
    err, out, _ = m.call("alcove_port_forward_list", {"name": run.vm})
    expect(not err and f"127.0.0.1:{SSH_HOST_PORT} -> guest 22 (config)" in lines(out) and re.search(r"-> guest 7645 \(agent\)", out),
           f"alcove_port_forward_list answered error={err} {out!r}")
    err, out, _ = m.call("alcove_set_environment", {"name": run.vm, "time_zone": "No Such Zone"})
    expect(err and out.startswith("timeZone: FAILED"), f"alcove_set_environment with an unknown time zone answered error={err} {out!r}")

    err, out, _ = m.call("alcove_lease_acquire", {"name": run.vm, "owner": "at2-e2e-mcp"})
    expect(not err and out == f"leased '{run.vm}' for 300 s; this session's calls carry the lease", f"alcove_lease_acquire answered error={err} {out!r}")
    message = run.refusal("vm.mouse.move", client=b, x=640, y=400)
    expect(re.fullmatch(LEASE_REFUSAL.format(vm=re.escape(run.vm), owner="at2-e2e-mcp"), message), f"during the MCP lease vm.mouse.move failed with {message!r}")
    err, out, _ = m.call("alcove_move_mouse", {"name": run.vm, "x": 640, "y": 400})
    expect(not err, f"alcove_move_mouse of the lease holder answered {out!r}")
    err, out, _ = m.call("alcove_lease_release", {"name": run.vm})
    expect(not err and out == f"released the lease on '{run.vm}'", f"alcove_lease_release answered error={err} {out!r}")
    b.call("vm.mouse.move", 60, name=run.vm, x=641, y=400)

    err, out, _ = m.call("alcove_lease_acquire", {"name": run.vm, "owner": "at2-e2e-mcp", "ttl_s": 1})
    expect(not err, f"alcove_lease_acquire with ttl_s 1 answered {out!r}")
    time.sleep(2)
    other = b.call("vm.lease.acquire", 60, name=run.vm, owner="at2-e2e-b", ttl=60)["lease"]
    run.leases.append(other)
    err, out, _ = m.call("alcove_move_mouse", {"name": run.vm, "x": 640, "y": 400})
    expect(err and re.fullmatch(LEASE_REFUSAL.format(vm=re.escape(run.vm), owner="at2-e2e-b"), out),
           f"alcove_move_mouse under another owner's lease answered error={err} {out!r}")
    err, out, _ = m.call("alcove_lease_release", {"name": run.vm})
    expect(err and out == f"this session holds no lease on '{run.vm}'; call alcove_lease_acquire first",
           f"alcove_lease_release after the lease was lost answered error={err} {out!r}")
    b.call("vm.lease.release", 60, name=run.vm, lease=other)
    run.leases.remove(other)

    err, out, _ = m.call("alcove_lease_acquire", {"name": run.vm, "owner": "at2-e2e-mcp"})
    expect(not err, f"the last alcove_lease_acquire answered {out!r}")
    expect(b.call("vm.status", 60, name=run.vm).get("leasedBy") == "at2-e2e-mcp", "vm.status does not show the MCP server's lease")
    m.close()
    end = time.time() + 10
    while "leasedBy" in b.call("vm.status", 60, name=run.vm):
        expect(time.time() < end, "the lease of the closed MCP server is still held after 10 s")
        time.sleep(0.5)
    b.call("vm.mouse.move", 60, name=run.vm, x=640, y=400)
    return "doctor 12 rows ok; a lost lease is dropped; closing the server releases its lease"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--vm-dir", default=os.path.expanduser("~/Library/Application Support/Alcove/VMs"),
                    help="the directory the control server keeps its VMs in")
    ap.add_argument("--only", default="", help="comma-separated check numbers")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n}

    try:
        client = Client()
        host = client.call("hello", 60).get("host")
        status = client.call("vm.status", 60, name=args.vm)
    except ControlError as e:
        print(f"FAIL 0: {e}")
        sys.exit(1)
    if host != "headless":
        print(f"FAIL 0: the control socket belongs to the {host} host; quit Alcove.app so that alcovectl serve owns the VMs")
        sys.exit(1)
    if status.get("state") != "running" or status.get("tools") is not True or status.get("ephemeral"):
        print(f"FAIL 0: VM '{args.vm}' is {status.get('state')} with tools {status.get('tools')!r}"
              f"{' in a session that discards changes' if status.get('ephemeral') else ''}; "
              "start it with scripts/test/ctl.py vm.start, wait for the guest tools and run this script again")
        sys.exit(1)
    run = Run(client, args.vm, args.vm_dir)
    if not run.bundle:
        print(f"FAIL 0: no bundle of '{args.vm}' in {args.vm_dir}; pass --vm-dir")
        sys.exit(1)

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    failed = None
    cleanup_failed = False
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
    finally:
        try:
            run.cleanup()
        except Exception as e:
            cleanup_failed = True
            print(f"cleanup failed: {type(e).__name__}: {e}", flush=True)
    if failed or cleanup_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
