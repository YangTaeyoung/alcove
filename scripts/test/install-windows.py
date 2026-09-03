#!/usr/bin/env python3
"""Unattended Windows 11 ARM64 installation under QEMU/HVF (SP0 spike).

Usage: install-windows.py [--fresh | --selftest]

--fresh (destructive, ~15 min): builds the answer-file ISO, creates a new
disk, starts QEMU with the alcove display backend (so this script can press a
key for the "Press any key to boot from CD" prompt), takes periodic
screenshots through QMP and waits until the guest's OpenSSH server answers
with the ready marker written by setup.ps1.

Without --fresh the installed disk is booted again with the virtio-win and
answer-file CDs still attached (setup.ps1 runs from them at the first logon,
so an interrupted install can still finish) and the readiness check is
repeated; a missing disk is an error, never an implicit reinstall.
--selftest runs the offline checks of the helpers below (no QEMU).

Result: build/test-windows/disk.qcow2 holds an installed, SSH-reachable
Windows 11 Pro ARM64 with virtio drivers. Exit status 0 on success.
Env: SSH_PORT (2222), TIMEOUT_MIN (120), KEEP_RUNNING=1 (leave the VM and
swtpm up after success), TPM=1 (swtpm + tpm-tis-device; off by default).
"""
import json, os, re, select, signal, socket, subprocess, sys, time, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLD = os.path.join(ROOT, "build", "qemu-build")
QEMU = os.path.join(BLD, "qemu-system-aarch64")
QIMG = os.path.join(BLD, "qemu-img")
FW = os.path.join(BLD, "pc-bios", "edk2-aarch64-code.fd")
WIN_ISO = os.path.join(ROOT, "images", "Win11_25H2_English_Arm64_v2.iso")
VIRTIO_ISO = os.path.join(ROOT, "images", "virtio-win.iso")
WORK = os.path.join(ROOT, "build", "test-windows")
UNATTEND_ISO = os.path.join(WORK, "unattend.iso")
SSH_PORT = int(os.environ.get("SSH_PORT", "2222"))
TIMEOUT_MIN = float(os.environ.get("TIMEOUT_MIN", "120"))
KEEP_RUNNING = os.environ.get("KEEP_RUNNING") == "1"
# tpm-tis-device fails under HVF on this host (HV_BAD_ARGUMENT); off by default.
USE_TPM = os.environ.get("TPM") == "1"

# The guest's sshd shell is PowerShell (setup.ps1 sets DefaultShell). Under
# `powershell -Command` the exit code reflects only the last statement, and a
# missing file is a non-terminating error, so the marker must be tested
# explicitly: otherwise the check passes as soon as key auth works, before
# setup.ps1 has finished.
READY_CMD = ("if (-not (Test-Path C:\\alcove-ready.txt)) { exit 1 }; "
             "Get-Content C:\\alcove-ready.txt; "
             "systeminfo | findstr /B /C:\"OS Name\" /C:\"System Type\"")
# setup.ps1 writes the marker with `Get-Date -Format o` (ISO 8601).
READY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", re.M)


def is_ready(returncode, stdout):
    """The guest is ready only when READY_CMD exited 0 and printed both the
    marker's ISO-8601 line and the systeminfo lines."""
    return returncode == 0 and bool(READY_RE.search(stdout)) and "OS Name" in stdout


def cdrom_args(fresh):
    """USB CD-ROMs on the xHCI bus. The Windows ISO is the only bootable one
    (El Torito) and is attached for the first boot only: later boots must not
    boot it. virtio-win and the answer-file ISO are attached on every boot,
    because setup.ps1 runs from them at the first logon -- which happens on a
    later run if the install was interrupted after the disk was created."""
    cds = [("cd0", WIN_ISO)] if fresh else []
    cds += [("cd1", VIRTIO_ISO), ("cd2", UNATTEND_ISO)]
    args = []
    for cid, path in cds:
        args += ["-drive", f"if=none,id={cid},format=raw,readonly=on,media=cdrom,file.locking=off,file={path}",
                 "-device", f"usb-storage,drive={cid},bus=xhci.0"]
    return args


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


def make_unattend_iso(key):
    """Build the ALCOVE volume: autounattend.xml, setup.ps1, authorized_keys."""
    seed = os.path.join(WORK, "seed")
    shutil.rmtree(seed, ignore_errors=True)
    os.makedirs(seed)
    shutil.copy(os.path.join(ROOT, "scripts", "windows", "autounattend.xml"), seed)
    shutil.copy(os.path.join(ROOT, "scripts", "windows", "setup.ps1"), seed)
    shutil.copy(key + ".pub", os.path.join(seed, "authorized_keys"))
    if os.path.exists(UNATTEND_ISO):
        os.remove(UNATTEND_ISO)
    sh("hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "ALCOVE", "-o", UNATTEND_ISO, seed)


def selftest():
    """Offline checks of the pure helpers; run by scripts/test/all.sh."""
    def cd_files(args):
        return [a.split("file=")[-1] for a in args if a.startswith("if=none")]
    assert cd_files(cdrom_args(True)) == [WIN_ISO, VIRTIO_ISO, UNATTEND_ISO], cdrom_args(True)
    assert cd_files(cdrom_args(False)) == [VIRTIO_ISO, UNATTEND_ISO], cdrom_args(False)
    assert all(a.endswith("bus=xhci.0") for a in cdrom_args(True) if a.startswith("usb-storage"))
    sysinfo = "OS Name:                       Microsoft Windows 11 Pro\nSystem Type:                   ARM64-based PC\n"
    marker = "2026-09-03T03:55:29.1309568+00:00\n"
    assert not is_ready(0, sysinfo), "key auth alone must not count as ready"
    assert not is_ready(0, ""), "empty output must not count as ready"
    assert not is_ready(1, marker + sysinfo), "non-zero exit must not count as ready"
    assert not is_ready(0, marker), "marker without systeminfo must not count as ready"
    assert is_ready(0, marker + sysinfo)
    assert "exit 1" in READY_CMD and "Test-Path" in READY_CMD
    print("selftest OK")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    for p in (QEMU, QIMG, FW, WIN_ISO, VIRTIO_ISO):
        if not os.path.exists(p):
            sys.exit(f"missing {p}")
    disk = os.path.join(WORK, "disk.qcow2")
    fresh = "--fresh" in sys.argv
    if not fresh and not os.path.exists(disk):
        sys.exit(f"no installed disk at {disk}; pass --fresh for the (destructive, ~15 min) unattended install")
    os.makedirs(os.path.join(WORK, "shots"), exist_ok=True)
    os.makedirs(os.path.join(WORK, "tpm"), exist_ok=True)
    key = os.path.join(WORK, "id_ed25519")
    if not os.path.exists(key):
        sh("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key, "-C", "alcove-test")
    if fresh:
        log("fresh install: creating disk and answer-file ISO")
        sh(QIMG, "create", "-q", "-f", "qcow2", disk, "64G")
        with open(os.path.join(WORK, "efi-vars.fd"), "wb") as f:
            f.truncate(64 * 1024 * 1024)
        shutil.rmtree(os.path.join(WORK, "tpm"), ignore_errors=True)
        os.makedirs(os.path.join(WORK, "tpm"))
        make_unattend_iso(key)
    elif not os.path.exists(UNATTEND_ISO):
        log("answer-file ISO missing; rebuilding it")
        make_unattend_iso(key)

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
        "-drive", f"if=none,id=disk0,format=qcow2,file={disk},discard=unmap",
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
    cmd += cdrom_args(fresh)
    log("starting QEMU")
    qlog = open(os.path.join(WORK, "qemu.log"), "wb")
    proc = subprocess.Popen(cmd, stdout=qlog, stderr=subprocess.STDOUT)
    started = time.monotonic()
    ok = False
    qmp = None
    banner_seen = False

    def stop_qemu(graceful):
        """ACPI shutdown (up to 180 s) when the disk is worth preserving and
        QMP is up; otherwise, or as the fallback, kill."""
        if proc.poll() is not None:
            return
        if graceful and qmp is not None:
            try:
                log("powering down")
                qmp.execute("system_powerdown")
                proc.wait(timeout=180)
                return
            except (Exception, KeyboardInterrupt) as e:  # noqa: BLE001
                log("graceful powerdown failed:", repr(e))
        log("killing QEMU")
        proc.kill()

    try:
        srv.settimeout(30)
        conn, _ = srv.accept()
        conn.setblocking(False)
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
            # 25 s of the first boot only (the prompt shows ~5-10 s in and the
            # setup GUI, where Space would hit Cancel, appears after ~40 s).
            # Later boots must NOT boot the CD.
            if fresh and now - started < 25 and now - last_key >= 1.0:
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
            if now - last_ssh >= 30 and (now - started > 300 or not fresh):
                last_ssh = now
                try:
                    with socket.create_connection(("127.0.0.1", SSH_PORT), timeout=3) as s:
                        banner = s.recv(64)
                except OSError:
                    banner = b""
                if banner.startswith(b"SSH-"):
                    if not banner_seen:
                        log("ssh banner:", banner.strip().decode(errors="replace"))
                    banner_seen = True
                    r = subprocess.run([
                        "ssh", "-i", key, "-p", str(SSH_PORT), "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                        "alcove@127.0.0.1", READY_CMD,
                    ], capture_output=True, text=True, timeout=120)
                    if is_ready(r.returncode, r.stdout):
                        log("guest ready:\n" + r.stdout.strip())
                        ok = True
                        break
                    log("ssh up but guest not ready yet:", (r.stderr or r.stdout).strip()[:200])
        if ok:
            try:
                qmp.execute("screendump", filename=os.path.join(WORK, "shots", "final.png"), format="png")
            except Exception as e:  # noqa: BLE001
                log("final screendump failed:", e)
            if not KEEP_RUNNING:
                stop_qemu(graceful=True)
            print("PASS: Windows installed; disk at", disk)
        else:
            print("FAIL: guest not ready within timeout; see", os.path.join(WORK, "shots"))
    finally:
        if ok and KEEP_RUNNING:
            log("leaving QEMU running (pid %d)%s" % (proc.pid, f" and swtpm (pid {swtpm.pid})" if swtpm else ""))
        else:
            # An installed disk (resume run, or a fresh run that got as far as
            # sshd) deserves an ACPI shutdown; earlier there is nothing to keep.
            stop_qemu(graceful=(not fresh or banner_seen))
            if swtpm:
                swtpm.terminate()
        srv.close()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
