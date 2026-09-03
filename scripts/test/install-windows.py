#!/usr/bin/env python3
"""Unattended Windows 11 ARM64 installation under QEMU/HVF (SP0 spike).

Builds the answer-file ISO, starts swtpm and QEMU with the alcove display
backend (so this script can press a key for the "Press any key to boot from
CD" prompt), takes periodic screenshots through QMP, and waits until the
guest's OpenSSH server answers with the ready marker written by setup.ps1.

Result: build/test-windows/disk.qcow2 holds an installed, SSH-reachable
Windows 11 Pro ARM64 with virtio drivers. Exit status 0 on success.
"""
import json, os, select, signal, socket, subprocess, sys, time, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLD = os.path.join(ROOT, "build", "qemu-build")
QEMU = os.path.join(BLD, "qemu-system-aarch64")
QIMG = os.path.join(BLD, "qemu-img")
FW = os.path.join(BLD, "pc-bios", "edk2-aarch64-code.fd")
WIN_ISO = os.path.join(ROOT, "images", "Win11_25H2_English_Arm64_v2.iso")
VIRTIO_ISO = os.path.join(ROOT, "images", "virtio-win.iso")
WORK = os.path.join(ROOT, "build", "test-windows")
SSH_PORT = int(os.environ.get("SSH_PORT", "2222"))
TIMEOUT_MIN = float(os.environ.get("TIMEOUT_MIN", "120"))
KEEP_RUNNING = os.environ.get("KEEP_RUNNING") == "1"
# tpm-tis-device fails under HVF on this host (HV_BAD_ARGUMENT); off by default.
USE_TPM = os.environ.get("TPM") == "1"


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.f = self.s.makefile("rwb", buffering=0)
        self.buf = b""
        self.n = 0
        greeting = self._read()
        assert "QMP" in greeting, greeting
        self.execute("qmp_capabilities")

    def _read(self):
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("QMP closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def execute(self, cmd, **args):
        self.n += 1
        self.s.sendall(json.dumps({"execute": cmd, "arguments": args, "id": self.n}).encode() + b"\n")
        while True:
            msg = self._read()
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise RuntimeError(f"{cmd}: {msg['error']}")
                return msg.get("return")


def sh(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def main():
    for p in (QEMU, QIMG, FW, WIN_ISO, VIRTIO_ISO):
        if not os.path.exists(p):
            sys.exit(f"missing {p}")
    fresh = "--fresh" in sys.argv or not os.path.exists(os.path.join(WORK, "disk.qcow2"))
    os.makedirs(os.path.join(WORK, "shots"), exist_ok=True)
    os.makedirs(os.path.join(WORK, "tpm"), exist_ok=True)
    key = os.path.join(WORK, "id_ed25519")
    if not os.path.exists(key):
        sh("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key, "-C", "alcove-test")
    if fresh:
        log("fresh install: creating disk and answer-file ISO")
        sh(QIMG, "create", "-q", "-f", "qcow2", os.path.join(WORK, "disk.qcow2"), "64G")
        with open(os.path.join(WORK, "efi-vars.fd"), "wb") as f:
            f.truncate(64 * 1024 * 1024)
        shutil.rmtree(os.path.join(WORK, "tpm"), ignore_errors=True)
        os.makedirs(os.path.join(WORK, "tpm"))
        seed = os.path.join(WORK, "seed")
        shutil.rmtree(seed, ignore_errors=True)
        os.makedirs(seed)
        shutil.copy(os.path.join(ROOT, "scripts", "windows", "autounattend.xml"), seed)
        shutil.copy(os.path.join(ROOT, "scripts", "windows", "setup.ps1"), seed)
        shutil.copy(key + ".pub", os.path.join(seed, "authorized_keys"))
        iso = os.path.join(WORK, "unattend.iso")
        if os.path.exists(iso):
            os.remove(iso)
        sh("hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "ALCOVE", "-o", iso, seed)

    for f in ("display.sock", "qmp.sock", "swtpm.sock"):
        try:
            os.remove(os.path.join(WORK, f))
        except FileNotFoundError:
            pass
    swtpm = None
    if USE_TPM:
        swtpm = subprocess.Popen([
            "swtpm", "socket", "--tpm2", "--tpmstate", f"dir={os.path.join(WORK, 'tpm')}",
            "--ctrl", f"type=unixio,path={os.path.join(WORK, 'swtpm.sock')}",
            "--log", f"file={os.path.join(WORK, 'swtpm.log')},level=1",
        ])
        for _ in range(50):
            if os.path.exists(os.path.join(WORK, "swtpm.sock")):
                break
            time.sleep(0.1)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(os.path.join(WORK, "display.sock"))
    srv.listen(1)

    cmd = [
        QEMU, "-M", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "6144",
        "-nodefaults", "-no-user-config",
        "-drive", f"if=pflash,format=raw,readonly=on,file={FW}",
        "-drive", f"if=pflash,format=raw,file={os.path.join(WORK, 'efi-vars.fd')}",
        "-device", "ramfb",
        "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd", "-device", "usb-tablet",
        "-drive", f"if=none,id=disk0,format=qcow2,file={os.path.join(WORK, 'disk.qcow2')},discard=unmap",
        "-device", "nvme,drive=disk0,serial=alcove-disk0",
        "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-device", "virtio-rng-pci",
        "-display", f"alcove,socket={os.path.join(WORK, 'display.sock')}",
        "-qmp", f"unix:{os.path.join(WORK, 'qmp.sock')},server=on,wait=off",
        "-serial", f"file:{os.path.join(WORK, 'serial.log')}", "-monitor", "none",
    ]
    if USE_TPM:
        cmd += [
            "-chardev", f"socket,id=chrtpm,path={os.path.join(WORK, 'swtpm.sock')}",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-tis-device,tpmdev=tpm0",
        ]
    if fresh:
        cmd += [
            "-drive", f"if=none,id=cd0,format=raw,readonly=on,media=cdrom,file.locking=off,file={WIN_ISO}",
            "-device", "usb-storage,drive=cd0,bus=xhci.0",
            "-drive", f"if=none,id=cd1,format=raw,readonly=on,media=cdrom,file.locking=off,file={VIRTIO_ISO}",
            "-device", "usb-storage,drive=cd1,bus=xhci.0",
            "-drive", f"if=none,id=cd2,format=raw,readonly=on,media=cdrom,file.locking=off,file={os.path.join(WORK, 'unattend.iso')}",
            "-device", "usb-storage,drive=cd2,bus=xhci.0",
        ]
    log("starting QEMU")
    qlog = open(os.path.join(WORK, "qemu.log"), "wb")
    proc = subprocess.Popen(cmd, stdout=qlog, stderr=subprocess.STDOUT)
    started = time.monotonic()
    ok = False
    try:
        srv.settimeout(30)
        conn, _ = srv.accept()
        conn.setblocking(False)
        qmp = None
        for _ in range(50):
            if os.path.exists(os.path.join(WORK, "qmp.sock")):
                try:
                    qmp = QMP(os.path.join(WORK, "qmp.sock"))
                    break
                except OSError:
                    pass
            time.sleep(0.2)
        assert qmp, "no QMP"
        log("display and QMP connected")

        def press(mac):
            for down in (True, False):
                conn.sendall((json.dumps({"t": "key", "mac": mac, "down": down}) + "\n").encode())

        last_shot = 0
        last_key = 0
        last_ssh = 0
        shot_n = 0
        while time.monotonic() - started < TIMEOUT_MIN * 60:
            r, _, _ = select.select([conn], [], [], 1.0)
            if r:
                try:
                    data = conn.recv(1 << 20)
                except BlockingIOError:
                    data = b"x"
                if not data:
                    log("display socket closed")
                    break
            now = time.monotonic()
            if proc.poll() is not None:
                log("QEMU exited with", proc.returncode)
                break
            # "Press any key to boot from CD or DVD": tap Space during the first
            # 75 s of the first boot only. Later boots must NOT boot the CD.
            if fresh and now - started < 75 and now - last_key >= 1.0:
                press(49)
                last_key = now
            if now - last_shot >= 60:
                shot_n += 1
                path = os.path.join(WORK, "shots", f"{shot_n:03d}.png")
                try:
                    qmp.execute("screendump", filename=path, format="png")
                    log(f"screenshot {path}")
                except Exception as e:  # noqa: BLE001
                    log("screendump failed:", e)
                last_shot = now
            if now - last_ssh >= 30 and now - started > 300:
                last_ssh = now
                try:
                    with socket.create_connection(("127.0.0.1", SSH_PORT), timeout=3) as s:
                        banner = s.recv(64)
                except OSError:
                    banner = b""
                if banner.startswith(b"SSH-"):
                    log("ssh banner:", banner.strip().decode(errors="replace"))
                    r = subprocess.run([
                        "ssh", "-i", key, "-p", str(SSH_PORT), "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                        "alcove@127.0.0.1", "type C:\\alcove-ready.txt; systeminfo | findstr /B /C:\"OS Name\" /C:\"System Type\"",
                    ], capture_output=True, text=True, timeout=120)
                    if r.returncode == 0 and r.stdout.strip():
                        log("guest ready:\n" + r.stdout.strip())
                        ok = True
                        break
                    log("ssh not ready yet:", (r.stderr or r.stdout).strip()[:200])
        if ok:
            qmp.execute("screendump", filename=os.path.join(WORK, "shots", "final.png"), format="png")
            if not KEEP_RUNNING:
                log("powering down")
                qmp.execute("system_powerdown")
                try:
                    proc.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    log("powerdown timed out, killing")
                    proc.kill()
            print("PASS: Windows installed; disk at", os.path.join(WORK, "disk.qcow2"))
        else:
            print("FAIL: guest not ready within timeout; see", os.path.join(WORK, "shots"))
    finally:
        if proc.poll() is None and not (ok and KEEP_RUNNING):
            proc.kill()
        if swtpm:
            swtpm.terminate()
        srv.close()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
