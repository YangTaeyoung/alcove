#!/usr/bin/env python3
"""Installs build/alcove-agent-windows-arm64.exe into a running Windows VM and
checks the agent's hello.

The VM is started through the control socket when it is stopped. The binary is
copied over SSH and installed with `alcove-agent.exe --install --allow-exec`,
which replaces the running copy and restarts the scheduled task. The script
then connects to the forwarded agent port and compares hello with
guest-tools/internal/server/server.go.

Usage: install-agent.py [--vm NAME] [--ssh-port N] [--agent-port N]
"""
import argparse, json, os, re, socket, subprocess, sys, time

sys.dont_write_bytecode = True
import ctl

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AGENT = os.path.join(ROOT, "build", "alcove-agent-windows-arm64.exe")
SERVER_GO = os.path.join(ROOT, "guest-tools", "internal", "server", "server.go")
KEY = os.path.expanduser("~/Library/Application Support/Alcove/test_id_ed25519")
SSH_OPTS = ["-i", KEY, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR"]
GUEST_COPY = "C:/Users/alcove/alcove-agent.exe"
INSTALLED = r"C:\Program Files\Alcove\alcove-agent.exe"
REQUIRED_CAPS = ("rpc", "jobs", "proc", "fs")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def ssh(port, cmd, timeout=120):
    return subprocess.run(["ssh", *SSH_OPTS, "-p", str(port), "alcove@127.0.0.1", cmd],
                          capture_output=True, text=True, timeout=timeout)


def ssh_up(port):
    try:
        return ssh(port, "hostname", timeout=20).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def source_version():
    m = re.search(r'^const AgentVersion = "([^"]+)"', open(SERVER_GO).read(), re.M)
    if not m:
        fail(f"no AgentVersion constant in {SERVER_GO}")
    return m.group(1)


def ensure_running(vm, ssh_port):
    status = ctl.call(ctl.connect(), "vm.status", name=vm)
    if not status.get("ok"):
        fail(f"vm.status: {status.get('error')}")
    if status.get("state") != "running":
        log(f"{vm} is {status.get('state')}; starting it")
        started = ctl.call(ctl.connect(), "vm.start", name=vm)
        if not started.get("ok"):
            fail(f"vm.start: {started.get('error')}")
    for _ in range(60):
        if ssh_up(ssh_port):
            return
        time.sleep(5)
    fail(f"ssh on port {ssh_port} did not answer")


def read_hello(port):
    """Returns the agent's hello, or None when nothing answers on the port."""
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default="Windows 11")
    ap.add_argument("--ssh-port", type=int, default=2222)
    ap.add_argument("--agent-port", type=int, default=7646)
    args = ap.parse_args()

    for p in (AGENT, KEY):
        if not os.path.exists(p):
            fail(f"missing {p}")
    want = source_version()
    ensure_running(args.vm, args.ssh_port)

    log("copying", os.path.relpath(AGENT, ROOT))
    scp = subprocess.run(["scp", *SSH_OPTS, "-P", str(args.ssh_port), AGENT, f"alcove@127.0.0.1:{GUEST_COPY}"],
                         capture_output=True, text=True, timeout=300)
    if scp.returncode != 0:
        fail("scp: " + scp.stderr.strip())

    # The agent is a GUI-subsystem binary; Start-Process -Wait blocks until it exits.
    r = ssh(args.ssh_port,
            r'$p = Start-Process -FilePath "C:\Users\alcove\alcove-agent.exe" -ArgumentList "--install","--allow-exec" -Wait -PassThru; '
            rf'"exit=$($p.ExitCode)"; "size=$((Get-Item "{INSTALLED}").Length)"; Get-Content C:\ProgramData\Alcove\install.log -Tail 1')
    log("install:", (r.stdout + r.stderr).strip().replace("\r\n", " | ").replace("\n", " | ")[:300])
    if r.returncode != 0 or "exit=0" not in r.stdout:
        fail("the installer did not exit with 0; read C:\\ProgramData\\Alcove\\install.log in the guest")
    if f"size={os.path.getsize(AGENT)}" not in r.stdout:
        fail(f"{INSTALLED} does not have the size of the build")

    hello = None
    for _ in range(30):
        hello = read_hello(args.agent_port)
        if hello and hello.get("t") == "hello" and hello.get("agent") == want:
            break
        time.sleep(2)
    if not hello:
        fail(f"no hello on port {args.agent_port}")
    log("hello:", {k: hello.get(k) for k in ("os", "agent", "v", "proto", "caps")})
    if hello.get("agent") != want:
        fail(f"agent reports version {hello.get('agent')!r}, server.go says {want!r}")
    if hello.get("proto") != 2:
        fail(f"hello.proto is {hello.get('proto')!r}, expected 2")
    missing = [c for c in REQUIRED_CAPS if c not in hello.get("caps", [])]
    if missing:
        fail(f"hello.caps lacks {', '.join(missing)}")
    print("PASS")


if __name__ == "__main__":
    main()
