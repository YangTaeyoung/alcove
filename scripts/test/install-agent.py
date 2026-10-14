#!/usr/bin/env python3
"""Installs build/alcove-agent-windows-arm64.exe into a running Windows VM and
checks the agent's hello.

A stopped VM is started through the control socket; a starting VM is awaited.
The binary is copied over SSH and installed with
`alcove-agent.exe --install --allow-exec`, which replaces the running copy and
restarts the scheduled task. An installer that does not exit with 0 ends the
script with the line the installer wrote to stderr, or the line it wrote to
install.log during this run. The script then requires, in this order:

1. the installed file has the SHA-256 of the build,
2. the agent process at the installed path started after the installer was
   launched and owns the listening agent port in the guest,
3. hello on the forwarded agent port matches
   guest-tools/internal/server/server.go and asks for the host key,
4. a second connection sends the signature of the VM's token and the hello's
   nonce by the agentKey of the VM's config.json, and the agent answers
   authed.

Usage: install-agent.py [--vm NAME] [--user NAME] [--ssh-port N] [--agent-port N]
"""
import argparse, hashlib, json, os, re, socket, subprocess, sys, time

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError
from agent_key import AgentKeyError, agent_key, check_answer, first_message

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AGENT = os.path.join(ROOT, "build", "alcove-agent-windows-arm64.exe")
SERVER_GO = os.path.join(ROOT, "guest-tools", "internal", "server", "server.go")
KEY = os.path.expanduser("~/Library/Application Support/Alcove/test_id_ed25519")
SSH_OPTS = ["-i", KEY, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR"]
USER = "alcove"
INSTALLED = r"C:\Program Files\Alcove\alcove-agent.exe"
GUEST_AGENT_PORT = 7645
REQUIRED_CAPS = ("rpc", "jobs", "proc", "fs")

INSTALL_LOG = r"C:\ProgramData\Alcove\install.log"


def guest_copy():
    return f"C:/Users/{USER}/alcove-agent.exe"


def install_ps():
    """The guest command that prints the installer's exit code, the first line it wrote to stderr, and the
    last line of install.log when the installer wrote that file during this run."""
    stderr = rf"C:\Users\{USER}\alcove-agent-install.err"
    return (
        '$before = (Get-Date).ToUniversalTime().Ticks; "before=$before"; '
        rf'$p = Start-Process -FilePath "C:\Users\{USER}\alcove-agent.exe" -ArgumentList "--install","--allow-exec" -Wait -PassThru '
        f'-RedirectStandardError "{stderr}"; '
        '"exit=$($p.ExitCode)"; '
        f'"stderr=$(Get-Content -LiteralPath "{stderr}" -ErrorAction SilentlyContinue | Select-Object -First 1)"; '
        f'Remove-Item -LiteralPath "{stderr}" -Force -ErrorAction SilentlyContinue; '
        f'"sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath "{INSTALLED}").Hash.ToLower())"; '
        f'$log = Get-Item -LiteralPath "{INSTALL_LOG}" -ErrorAction SilentlyContinue; '
        'if ($log -and $log.LastWriteTimeUtc.Ticks -ge $before) { "log=$(Get-Content -LiteralPath $log.FullName -Tail 1)" }'
    )


PROCESS_PS = (
    f'$p = Get-Process alcove-agent -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -eq "{INSTALLED}" }} '
    '| Sort-Object StartTime | Select-Object -Last 1; '
    'if ($p) { "pid=$($p.Id)"; "start=$($p.StartTime.ToUniversalTime().Ticks)" }; '
    f'"listener=$((Get-NetTCPConnection -LocalPort {GUEST_AGENT_PORT} -State Listen -ErrorAction SilentlyContinue '
    '| Select-Object -First 1).OwningProcess)"'
)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def run(what, argv, timeout):
    """Runs a host command; a timeout ends the script with FAIL."""
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f"{what} did not finish within {timeout} s")


def ssh(port, what, cmd, timeout=120):
    return run(what, ["ssh", *SSH_OPTS, "-p", str(port), f"{USER}@127.0.0.1", cmd], timeout)


def ssh_up(port):
    try:
        r = subprocess.run(["ssh", *SSH_OPTS, "-p", str(port), f"{USER}@127.0.0.1", "hostname"],
                           capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return False
    return r.returncode == 0


def fields(stdout):
    """Parses `key=value` output lines into a dict."""
    out = {}
    for line in stdout.splitlines():
        m = re.fullmatch(r"(\w+)=(.*)", line.strip())
        if m:
            out[m.group(1)] = m.group(2)
    return out


def source_version():
    m = re.search(r'^const AgentVersion = "([^"]+)"', open(SERVER_GO).read(), re.M)
    if not m:
        fail(f"no AgentVersion constant in {SERVER_GO}")
    return m.group(1)


def control(op, **params):
    """One control operation on its own connection; a refusal ends the script."""
    try:
        with Client() as client:
            return client.call(op, **params)
    except ControlError as e:
        fail(f"{op}: {e}")


def vm_state(vm):
    return control("vm.status", name=vm).get("state")


def ensure_running(vm, ssh_port):
    state = vm_state(vm)
    if state == "stopped":
        log(f"{vm} is stopped; starting it")
        control("vm.start", name=vm)
        state = vm_state(vm)
    end = time.time() + 300
    while state != "running":
        if state == "paused":
            fail(f"VM '{vm}' is paused; resume it with vm.resume and run this script again")
        if state != "starting":
            fail(f"VM '{vm}' is {state}; wait until it is stopped or running and run this script again")
        if time.time() > end:
            fail(f"VM '{vm}' is still starting after 300 s")
        time.sleep(2)
        state = vm_state(vm)
    for _ in range(60):
        if ssh_up(ssh_port):
            return
        time.sleep(5)
    fail(f"ssh on port {ssh_port} did not answer")


def install_failure(got):
    """Returns the sentence for an installer that did not exit with 0: what it
    wrote to stderr, else the line it wrote to install.log during this run,
    else its exit code alone."""
    said = got.get("stderr") or got.get("log")
    if said:
        return f"the installer exited with {got.get('exit', 'no exit code')}: {said}"
    return f"the installer exited with {got.get('exit', 'no exit code')} and wrote nothing to stderr or install.log"


def install(ssh_port, digest):
    """Runs the installer in the guest and returns the guest time taken just before it."""
    r = ssh(ssh_port, "the installer over ssh", install_ps())
    got = fields(r.stdout)
    log("install:", ", ".join(f"{k}={got[k]}" for k in ("exit", "sha256", "stderr", "log") if got.get(k)) or (r.stdout + r.stderr).strip()[:300])
    if r.returncode != 0 or got.get("exit") != "0":
        fail(install_failure(got))
    if got.get("sha256") != digest:
        fail(f"{INSTALLED} has SHA-256 {got.get('sha256')!r}, the build has {digest}")
    if not got.get("before", "").isdigit():
        fail("the guest did not report the time before the install")
    return int(got["before"])


def wait_for_new_process(ssh_port, before):
    """Waits until the agent at the installed path started after `before` and listens on the agent port."""
    got = {}
    end = time.time() + 60
    while True:
        query = ssh(ssh_port, "the agent process query over ssh", PROCESS_PS, timeout=60)
        if query.returncode != 0:
            fail(f"the agent process query over ssh exited with {query.returncode}: {query.stderr.strip() or 'no error text'}; check that ssh on port {ssh_port} still answers")
        got = fields(query.stdout)
        started = got.get("start", "").isdigit() and int(got["start"]) > before
        if started and got.get("pid") and got.get("listener") == got["pid"]:
            log(f"agent process {got['pid']} started after the install and listens on guest port {GUEST_AGENT_PORT}")
            return
        if time.time() > end:
            break
        time.sleep(2)
    if not got.get("pid"):
        fail(f"no alcove-agent process runs from {INSTALLED}; run `schtasks /Run /TN AlcoveAgent` in the guest and read C:\\ProgramData\\Alcove\\agent.log")
    if not (got.get("start", "").isdigit() and int(got["start"]) > before):
        fail(f"agent process {got['pid']} started before the install; the scheduled task did not restart it")
    fail(f"guest port {GUEST_AGENT_PORT} is owned by process {got.get('listener') or 'none'}, not by the new agent process {got['pid']}")


def read_hello(port):
    """Returns the agent's first message (its hello, or a `refused` line), or None when nothing answers on the
    port."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
    except OSError:
        return None
    try:
        s.settimeout(5)
        line = s.makefile("rb").readline()
        return json.loads(line) if line else None
    except (OSError, ValueError):
        return None
    finally:
        s.close()


def authenticate(port, key):
    """Authenticates to the agent on port with key, or fails the run with the agent's answer."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
    except OSError as e:
        fail(f"cannot connect to the agent port {port} to authenticate: {e}")
    try:
        s.settimeout(10)
        f = s.makefile("rb")
        hello = json.loads(f.readline() or b"null")
        s.sendall((json.dumps(first_message(hello or {}, key)) + "\n").encode())
        line = f.readline()
        check_answer(json.loads(line) if line else None)
    except AgentKeyError as e:
        fail(str(e))
    except (OSError, ValueError) as e:
        fail(f"the agent on port {port} broke the connection while authenticating: {e}")
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--user", default="alcove", help="the guest account the ssh login uses")
    ap.add_argument("--ssh-port", type=int, default=2222)
    ap.add_argument("--agent-port", type=int, default=7646)
    args = ap.parse_args()
    global USER
    USER = args.user

    for p in (AGENT, KEY):
        if not os.path.exists(p):
            fail(f"missing {p}")
    try:
        agent_secret = agent_key(args.vm)
    except AgentKeyError as e:
        fail(str(e))
    want = source_version()
    digest = hashlib.sha256(open(AGENT, "rb").read()).hexdigest()
    ensure_running(args.vm, args.ssh_port)

    log("copying", os.path.relpath(AGENT, ROOT), "sha256", digest)
    scp = run("scp of the agent binary", ["scp", *SSH_OPTS, "-P", str(args.ssh_port), AGENT, f"{USER}@127.0.0.1:{guest_copy()}"], 300)
    if scp.returncode != 0:
        fail("scp: " + scp.stderr.strip())

    before = install(args.ssh_port, digest)
    wait_for_new_process(args.ssh_port, before)

    hello = None
    for _ in range(30):
        hello = read_hello(args.agent_port)
        if hello:
            break
        time.sleep(2)
    if hello and hello.get("t") == "refused":
        fail(f"the agent on port {args.agent_port} refused the connection: {hello.get('error')}")
    if not hello or hello.get("t") != "hello":
        fail(f"no hello on port {args.agent_port}")
    log("hello:", {k: hello.get(k) for k in ("os", "agent", "v", "proto", "caps")})
    if hello.get("agent") != want:
        fail(f"agent reports version {hello.get('agent')!r}, server.go says {want!r}")
    if hello.get("proto") != 2:
        fail(f"hello.proto is {hello.get('proto')!r}, expected 2")
    missing = [c for c in REQUIRED_CAPS if c not in hello.get("caps", [])]
    if missing:
        fail(f"hello.caps lacks {', '.join(missing)}")
    if hello.get("auth") != "key":
        fail(f"hello.auth is {hello.get('auth')!r}, expected 'key'")
    authenticate(args.agent_port, agent_secret)
    log("authenticated with the agentKey of", repr(args.vm))
    print("PASS")


if __name__ == "__main__":
    main()
