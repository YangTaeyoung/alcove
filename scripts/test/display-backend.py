#!/usr/bin/env python3
"""Engine integration test for the `alcove` display backend.

Boots qemu-system-aarch64 under HVF with only the EDK2 firmware (no OS),
speaks the Alcove display protocol over a unix socket, maps the shared
framebuffer and checks that:
  1. hello/switch/update arrive and the frame is not blank (TianoCore draws),
  2. a key press (Escape -> firmware setup) changes the frame,
  3. pointer messages are accepted and QEMU stays alive,
  4. QEMU exits cleanly with `bye` on SIGTERM.
Exit status 0 on success. Uses only the standard library.
"""
import hashlib, json, mmap, os, select, signal, socket, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
QEMU = os.path.join(ROOT, "build", "qemu-build", "qemu-system-aarch64")
FW = os.path.join(ROOT, "build", "qemu-build", "pc-bios", "edk2-aarch64-code.fd")
DEADLINE = float(os.environ.get("TIMEOUT", "90"))


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


class Proto:
    def __init__(self, conn):
        self.conn = conn
        self.buf = b""
        self.log = []

    def send(self, obj):
        self.conn.sendall((json.dumps(obj) + "\n").encode())

    def recv(self, timeout):
        """Return the next message or None on timeout."""
        end = time.monotonic() + timeout
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line, self.buf = self.buf[:nl], self.buf[nl + 1:]
                if not line:
                    continue
                msg = json.loads(line)
                self.log.append(msg)
                return msg
            remaining = end - time.monotonic()
            if remaining <= 0:
                return None
            r, _, _ = select.select([self.conn], [], [], remaining)
            if not r:
                return None
            chunk = self.conn.recv(65536)
            if not chunk:
                fail("socket closed by QEMU")
            self.buf += chunk

    def wait_for(self, kind, timeout):
        end = time.monotonic() + timeout
        while True:
            msg = self.recv(max(0.01, end - time.monotonic()))
            if msg is None:
                return None
            if msg.get("t") == kind:
                return msg
            if time.monotonic() > end:
                return None


def frame_digest(fb, switch):
    h = hashlib.sha256()
    stride, w, hgt = switch["stride"], switch["w"], switch["h"]
    for y in range(hgt):
        h.update(fb[y * stride:y * stride + w * 4])
    return h.hexdigest()


def snapshot(fb, switch):
    stride, w, hgt = switch["stride"], switch["w"], switch["h"]
    return [bytes(fb[y * stride:y * stride + w * 4]) for y in range(hgt)]


def changed_rows(a, b):
    if len(a) != len(b):
        return 1.0
    return sum(1 for x, y in zip(a, b) if x != y) / max(1, len(a))


def distinct_pixels(fb, switch, sample=4096):
    stride, w, hgt = switch["stride"], switch["w"], switch["h"]
    seen = set()
    step = max(1, (w * hgt) // sample)
    for i in range(0, w * hgt, step):
        y, x = divmod(i, w)
        off = y * stride + x * 4
        seen.add(bytes(fb[off:off + 4]))
        if len(seen) > 8:
            break
    return len(seen)


def main():
    for p in (QEMU, FW):
        if not os.path.exists(p):
            fail(f"missing {p} (run scripts/build-qemu.sh)")
    tmp = tempfile.mkdtemp(prefix="alcove-test-")
    sock_path = os.path.join(tmp, "display.sock")
    vars_path = os.path.join(tmp, "efi-vars.fd")
    with open(vars_path, "wb") as f:
        f.truncate(64 * 1024 * 1024)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)

    cmd = [
        QEMU, "-M", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "2", "-m", "512",
        "-nodefaults", "-no-user-config",
        "-drive", f"if=pflash,format=raw,readonly=on,file={FW}",
        "-drive", f"if=pflash,format=raw,file={vars_path}",
        "-device", "ramfb",
        "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
        "-display", f"alcove,socket={sock_path}",
        "-serial", "none", "-monitor", "none",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    try:
        srv.settimeout(20)
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            out = proc.stdout.read().decode(errors="replace") if proc.poll() is not None else ""
            fail(f"QEMU never connected to the display socket\n{out}")
        conn.setblocking(False)
        p = Proto(conn)

        hello = p.wait_for("hello", 10)
        if not hello or hello.get("v") != 1:
            fail(f"no valid hello: {hello}")
        print("hello:", hello)

        switch = p.wait_for("switch", 10)
        if not switch:
            fail("no switch message")
        print("switch:", {k: switch[k] for k in ("con", "w", "h", "stride", "fmt", "size")})
        if switch["fmt"] != "bgra8" or switch["size"] < switch["stride"] * switch["h"]:
            fail("bad switch geometry")
        if not os.path.exists(switch["shm"]):
            fail("shared file missing: " + switch["shm"])
        fd = os.open(switch["shm"], os.O_RDONLY)
        fb = mmap.mmap(fd, switch["size"], prot=mmap.PROT_READ)
        os.close(fd)

        # 1. the first surface is QEMU's placeholder; the guest firmware
        #    programs ramfb which produces a second `switch`. Wait for it and
        #    for a non-blank frame (TianoCore logo / boot text).
        start = time.monotonic()
        updates, switches = 0, 1
        while time.monotonic() - start < DEADLINE:
            msg = p.recv(1.0)
            if msg and msg.get("t") == "switch":
                switches += 1
                fb.close()
                switch = msg
                fd = os.open(switch["shm"], os.O_RDONLY)
                fb = mmap.mmap(fd, switch["size"], prot=mmap.PROT_READ)
                os.close(fd)
                print("re-switch:", switch["w"], "x", switch["h"])
            elif msg and msg.get("t") == "update":
                updates += 1
            if switches >= 2 and updates and distinct_pixels(fb, switch) > 2:
                break
        else:
            fail(f"no guest-programmed frame (switches={switches}, updates={updates})")
        print(f"firmware drew a frame after {updates} updates, {time.monotonic() - start:.1f}s")

        # 2. wait until the firmware is idle (ramfb re-sends full updates every
        #    refresh, so idleness is judged on pixels: fewer than 10% of rows
        #    change over 2 s -- a blinking shell cursor is well under that),
        #    then type "help<Return>" at the UEFI shell and expect a large
        #    change (>= 20% of rows). This proves key injection end to end.
        def remap(msg):
            nonlocal fb, switch
            fb.close(); switch = msg
            fd = os.open(switch["shm"], os.O_RDONLY)
            fb = mmap.mmap(fd, switch["size"], prot=mmap.PROT_READ); os.close(fd)

        def drain(seconds):
            end = time.monotonic() + seconds
            while True:
                left = end - time.monotonic()
                if left <= 0:
                    return
                msg = p.recv(left)
                if msg and msg.get("t") == "switch":
                    remap(msg)

        start = time.monotonic()
        quiet = 0.0
        prev = snapshot(fb, switch)
        while time.monotonic() - start < DEADLINE:
            drain(0.5)
            cur = snapshot(fb, switch)
            if changed_rows(prev, cur) < 0.10:
                quiet += 0.5
                if quiet >= 2.0:
                    break
            else:
                quiet = 0.0
            prev = cur
        else:
            fail("firmware never became idle")
        print(f"firmware idle after {time.monotonic() - start:.1f}s")

        before = snapshot(fb, switch)
        for mac in (4, 14, 37, 35, 36):   # kVK_ANSI_H, E, L, P, Return
            p.send({"t": "key", "mac": mac, "down": True})
            p.send({"t": "key", "mac": mac, "down": False})
        start = time.monotonic()
        best = 0.0
        while time.monotonic() - start < 15:
            drain(0.5)
            best = max(best, changed_rows(before, snapshot(fb, switch)))
            if best >= 0.20:
                break
        if best < 0.20:
            fail(f"frame changed only {best:.0%} of rows after typing 'help'")
        print(f"typing 'help' changed {best:.0%} of rows in {time.monotonic() - start:.1f}s")

        # a key with no mapping must be ignored, not crash
        p.send({"t": "key", "mac": 250, "down": True})
        p.send({"t": "key", "q": 999999, "down": True})

        # 3. pointer messages must be accepted
        p.send({"t": "abs", "con": 0, "x": 16000, "y": 16000})
        p.send({"t": "btn", "con": 0, "b": 0, "down": True})
        p.send({"t": "btn", "con": 0, "b": 0, "down": False})
        p.send({"t": "sync"})
        p.send({"t": "rel", "con": 0, "dx": 3, "dy": -2})
        p.send({"t": "sync"})
        p.send({"t": "lift"})
        p.send({"t": "refresh", "con": 0})
        full = p.wait_for("update", 5)
        if not full:
            fail("no update after refresh request")
        p.send({"t": "bogus", "x": 1})  # must be ignored
        p.send({"t": "ui", "con": 0, "w": 1024, "h": 768})
        time.sleep(0.5)
        if proc.poll() is not None:
            fail("QEMU died after input messages: " + proc.stdout.read().decode(errors="replace"))
        print("input messages accepted")

        # 4. clean shutdown -> bye
        proc.send_signal(signal.SIGTERM)
        bye = p.wait_for("bye", 10)
        rc = proc.wait(timeout=15)
        print("bye:", bye, "exit:", rc)
        if not bye:
            fail("no bye on shutdown")
        if rc != 0:
            fail(f"QEMU exit code {rc}: " + proc.stdout.read().decode(errors="replace")[-2000:])
        left = [f for f in os.listdir(tmp) if f.startswith(("fb", "cursor"))]
        if left:
            fail(f"shared files not cleaned up: {left}")
        print("PASS")
    finally:
        if proc.poll() is None:
            proc.kill()
        srv.close()


if __name__ == "__main__":
    main()
