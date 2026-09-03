#!/usr/bin/env python3
"""End-to-end test of the guest agent inside the SP0 Windows 11 image.

Requires the "Windows 11" bundle in the app VM directory with port forwards
2222->22 (ssh) and 7646->7645 (agent), the SSH key from the install harness at
~/Library/Application Support/Alcove/test_id_ed25519, and the agent binary at
build/alcove-agent-windows-arm64.exe. Boots the VM through alcovectl, installs
the agent over SSH (scheduled task in the interactive session), then talks the
agent protocol from the host: clipboard both ways, file push, exec.
"""
import base64, hashlib, json, os, socket, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CTL = os.path.join(ROOT, "AlcoveKit", ".build-ctl", "debug", "alcovectl")
AGENT = os.path.join(ROOT, "build", "alcove-agent-windows-arm64.exe")
KEY = os.path.expanduser("~/Library/Application Support/Alcove/test_id_ed25519")
SSH = ["ssh", "-i", KEY, "-p", "2222", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "alcove@127.0.0.1"]
AGENT_PORT = 7646


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def ssh(cmd, timeout=120):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True, timeout=timeout)


class Agent:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=30)
        self.f = self.s.makefile("rb")

    def send(self, m):
        self.s.sendall((json.dumps(m) + "\n").encode())

    def recv(self, typ, timeout=30):
        self.s.settimeout(timeout)
        end = time.time() + timeout
        while time.time() < end:
            line = self.f.readline()
            if not line:
                fail("agent closed the connection")
            m = json.loads(line)
            if m.get("t") == typ:
                return m
            if m.get("t") == "ping":
                self.send({"t": "pong"})
        fail(f"timeout waiting for {typ}")

    def exec(self, cmd):
        self.send({"t": "exec", "cmd": cmd})
        r = self.recv("exec.result", 60)
        return r.get("code"), r.get("out", "")


def main():
    for p in (CTL, AGENT, KEY):
        if not os.path.exists(p):
            fail(f"missing {p}")
    log("booting Windows 11 through alcovectl")
    vm = subprocess.Popen([CTL, "run", "Windows 11", "--seconds", "600"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(60):
            if ssh("hostname").returncode == 0:
                break
            if vm.poll() is not None:
                fail("VM exited: " + vm.stdout.read())
            time.sleep(5)
        else:
            fail("ssh never came up")
        log("ssh up; installing agent")
        scp = subprocess.run(["scp", "-i", KEY, "-P", "2222", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                              "-o", "LogLevel=ERROR", AGENT, "alcove@127.0.0.1:C:/Users/alcove/alcove-agent.exe"], capture_output=True, text=True)
        if scp.returncode != 0:
            fail("scp: " + scp.stderr)
        # the agent is a GUI-subsystem binary, so PowerShell must be told to wait for it
        r = ssh(r'$p = Start-Process -FilePath "C:\Users\alcove\alcove-agent.exe" -ArgumentList "--install","--allow-exec" -Wait -PassThru; '
                r'"exit=$($p.ExitCode)"; (Get-Item "C:\Program Files\Alcove\alcove-agent.exe").Length')
        log("install:", r.returncode, (r.stdout + r.stderr).strip().replace("\r\n", " | ")[:300])
        if r.returncode != 0 or "exit=0" not in r.stdout or str(os.path.getsize(AGENT)) not in r.stdout:
            fail("agent install failed or the installed binary does not match the build")

        # connect from the host
        agent = None
        for _ in range(30):
            try:
                agent = Agent(AGENT_PORT)
                break
            except OSError:
                time.sleep(2)
        if not agent:
            fail("could not connect to the agent port")
        hello = agent.recv("hello")
        log("hello:", {k: hello[k] for k in ("os", "agent", "caps")})
        if hello.get("os") != "windows" or "clipboard" not in hello.get("caps", []):
            fail("unexpected hello")
        agent.send({"t": "welcome", "v": 1})

        # exec runs in the interactive session (scheduled task), so it sees the real clipboard
        code, out = agent.exec("whoami; [Environment]::UserInteractive; (Get-Process -Id $PID).SessionId")
        log("exec whoami:", code, out.strip().replace("\n", " | "))

        # host -> guest clipboard
        marker = f"hello from mac {int(time.time())}"
        agent.send({"t": "clipboard.set", "text": marker})
        time.sleep(1)
        code, out = agent.exec("Get-Clipboard -Raw")
        if marker not in out:
            fail(f"guest clipboard did not receive host text: {out!r}")
        log("host -> guest clipboard OK")

        # guest -> host clipboard
        guest_text = f"typed in guest {int(time.time())}"
        agent.exec(f"Set-Clipboard -Value '{guest_text}'")
        m = agent.recv("clipboard.changed", 15)
        if m.get("text") != guest_text:
            fail(f"clipboard.changed carried {m.get('text')!r}")
        log("guest -> host clipboard OK")

        # file push
        payload = os.urandom(300_000)
        digest = hashlib.sha256(payload).hexdigest()
        agent.send({"t": "file.begin", "id": "f1", "name": "alcove-drop.bin", "size": len(payload), "dest": "desktop"})
        for i in range(0, len(payload), 200_000):
            agent.send({"t": "file.chunk", "id": "f1", "data": base64.b64encode(payload[i:i + 200_000]).decode()})
        agent.send({"t": "file.end", "id": "f1", "sha256": digest})
        done = agent.recv("file.done")
        if done.get("error"):
            fail("file push: " + done["error"])
        code, out = agent.exec(f"(Get-FileHash -Algorithm SHA256 '{done['path']}').Hash.ToLower()")
        if digest not in out:
            fail(f"file digest mismatch in guest: {out!r}")
        log("file push OK ->", done["path"])

        # resolution change through the agent (ChangeDisplaySettings); with the
        # virtio-gpu display (viogpudo) the guest can switch modes, with ramfb it cannot
        agent.send({"t": "resolution.set", "w": 1024, "h": 768})
        res = agent.recv("resolution", 10)
        log("guest resolution after resolution.set 1024x768:", res.get("w"), "x", res.get("h"))
        cfg = json.load(open(os.path.expanduser("~/Library/Application Support/Alcove/VMs/Windows 11.alcovevm/config.json")))
        if cfg.get("display") == "virtio-gpu" and (res.get("w"), res.get("h")) != (1024, 768):
            fail("virtio-gpu guest did not switch to 1024x768")
        agent.send({"t": "resolution.set", "w": 1280, "h": 800})
        res = agent.recv("resolution", 10)
        log("guest resolution restored:", res.get("w"), "x", res.get("h"))
        print("PASS: guest agent verified in Windows 11")
    finally:
        try:
            ssh("shutdown /s /t 0", timeout=20)
        except Exception:
            pass
        try:
            vm.wait(timeout=120)
        except subprocess.TimeoutExpired:
            vm.kill()


if __name__ == "__main__":
    main()
