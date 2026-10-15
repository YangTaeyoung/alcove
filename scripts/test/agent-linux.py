#!/usr/bin/env python3
"""End-to-end test of the guest agent inside an Ubuntu desktop bundle
(Ubuntu 26.04.1 with a desktop, autologin of the user alcove and wl-clipboard;
ssh forward 2223->22 with the test key, agent forward 7647->7645). The host
side authenticates with the agentKey of the bundle's config.json. The file
drop is checked after the agent listed clipboard, i.e. once it found the
desktop session: it must land in the home that session.info reports for the
desktop user, owned by that user.

Usage: agent-linux.py [--vm NAME]   (default VM name: Ubuntu)
"""
import argparse, base64, hashlib, json, os, socket, subprocess, sys, time

sys.dont_write_bytecode = True
from agent_key import AgentKeyError, agent_key, check_answer, first_message

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CTL = os.path.join(ROOT, "AlcoveKit", ".build-ctl", "debug", "alcovectl")
AGENT = os.path.join(ROOT, "build", "alcove-agent-linux-arm64")
KEY = os.path.expanduser("~/Library/Application Support/Alcove/test_id_ed25519")
SSH = ["ssh", "-i", KEY, "-p", "2223", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "alcove@127.0.0.1"]
AGENT_PORT = 7647
VM = "Ubuntu"
SESSION_WAIT_S = 120


def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)
def fail(msg): print("FAIL:", msg); sys.exit(1)
def ssh(cmd, timeout=120): return subprocess.run(SSH + [cmd], capture_output=True, text=True, timeout=timeout)


class Agent:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30); self.f = self.s.makefile("rb")
    def send(self, m): self.s.sendall((json.dumps(m) + "\n").encode())
    def next(self):
        line = self.f.readline()
        if not line: fail("agent closed")
        return json.loads(line)
    def recv(self, typ, timeout=30, on_timeout=None):
        end = time.time() + timeout
        while time.time() < end:
            line = self.f.readline()
            if not line: fail("agent closed")
            m = json.loads(line)
            if m.get("t") == typ: return m
            if m.get("t") == "refused": fail(f"the agent refused the connection: {m.get('error')}")
            if m.get("t") == "ping": self.send({"t": "pong"})
        fail(on_timeout or f"timeout waiting for {typ}")
    def exec(self, cmd):
        self.send({"t": "exec", "cmd": cmd}); r = self.recv("exec.result", 60); return r.get("code"), r.get("out", "")


def main():
    global VM
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm", default=VM)
    VM = ap.parse_args().vm
    vm = subprocess.Popen([CTL, "run", VM, "--seconds", "400"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(60):
            if ssh("hostname").returncode == 0: break
            if vm.poll() is not None: fail("VM exited: " + vm.stdout.read())
            time.sleep(5)
        else:
            fail("ssh never came up")
        log("ssh up; installing agent")
        scp = subprocess.run(["scp", "-i", KEY, "-P", "2223", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                              "-o", "LogLevel=ERROR", AGENT, "alcove@127.0.0.1:/tmp/alcove-agent"], capture_output=True, text=True)
        if scp.returncode != 0: fail("scp: " + scp.stderr)
        r = ssh("chmod +x /tmp/alcove-agent && sudo /tmp/alcove-agent --install --allow-exec && sleep 1 && systemctl is-active alcove-agent && sudo cat /sys/firmware/dmi/tables/DMI | strings | grep -c alcove-token || true")
        log("install:", r.returncode, (r.stdout + r.stderr).strip()[:300])
        if r.returncode != 0: fail("agent install failed")
        agent = None
        for _ in range(20):
            try: agent = Agent(AGENT_PORT); break
            except OSError: time.sleep(2)
        if not agent: fail("could not connect to the agent port")
        hello = agent.recv("hello")
        log("hello:", {k: hello.get(k) for k in ("os", "agent", "caps", "token")})
        if hello.get("os") != "linux": fail("unexpected hello")
        try:
            agent.send(first_message(hello, agent_key(VM)))
            check_answer(agent.next())
        except AgentKeyError as e:
            fail(str(e))
        agent.send({"t": "welcome", "v": 1})
        caps = hello.get("caps") or []
        if "clipboard" not in caps:
            log("waiting for the desktop session (clipboard in a caps message)")
            no_session = (f"no desktop session within {SESSION_WAIT_S} s: the agent never listed clipboard; "
                          "check the autologin and wl-clipboard")
            end = time.time() + SESSION_WAIT_S
            while "clipboard" not in caps:
                left = end - time.time()
                if left <= 0: fail(no_session)
                caps = agent.recv("caps", left, on_timeout=no_session).get("caps") or []
            log("caps:", caps)
        agent.send({"t": "req", "id": 1, "op": "session.info"})
        info = agent.recv("res")
        home = info.get("home")
        if not info.get("ok") or not home:
            fail(f"session.info named no home of a desktop user: {info}; check the autologin")
        log("session:", info.get("user"), home)
        code, out = agent.exec("id -un; uname -m")
        log("exec:", code, out.strip().replace("\n", " | "))
        if "aarch64" not in out: fail("exec output unexpected")
        payload = os.urandom(300_000); digest = hashlib.sha256(payload).hexdigest()
        agent.send({"t": "file.begin", "id": "f1", "name": "drop.bin", "size": len(payload), "dest": "downloads"})
        for i in range(0, len(payload), 200_000):
            agent.send({"t": "file.chunk", "id": "f1", "data": base64.b64encode(payload[i:i + 200_000]).decode()})
        agent.send({"t": "file.end", "id": "f1", "sha256": digest})
        done = agent.recv("file.done")
        if done.get("error"): fail("file push: " + done["error"])
        code, out = agent.exec(f"sha256sum '{done['path']}'")
        if digest not in out: fail(f"digest mismatch: {out!r}")
        code, owner = agent.exec(f"stat -c %U '{done['path']}'; rm -f '{done['path']}'")
        if not done["path"].startswith(home.rstrip("/") + "/"): fail(f"the drop landed outside the desktop user's home {home}: {done['path']}")
        if owner.strip() == "root": fail(f"the drop {done['path']} belongs to root, not to the desktop user")
        log("file push OK ->", done["path"], "owner", owner.strip())
        print("PASS: guest agent verified in Ubuntu")
    finally:
        try: ssh("sudo systemctl poweroff", timeout=20)
        except Exception: pass
        try: vm.wait(timeout=120)
        except subprocess.TimeoutExpired: vm.kill()


if __name__ == "__main__":
    main()
