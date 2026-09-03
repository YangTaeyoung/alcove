#!/usr/bin/env python3
"""Engine integration test for the `alcove` display backend.

Boots qemu-system-aarch64 under HVF with only the EDK2 firmware (no OS),
speaks the Alcove display protocol over a unix socket, maps the shared
framebuffer and checks that:
  1. hello/switch/update arrive and the frame is not blank (TianoCore draws),
  2. key injection works end to end: once the firmware has settled at the
     UEFI shell, typing `help<Return>` and then `cls<Return>` (macOS
     keycodes in `key` messages) each change a large part of the frame; the
     screen is verified to be still before each command, so the firmware's
     own splash -> shell transition cannot be mistaken for our input,
  3. pointer and other messages are accepted and QEMU stays alive,
  4. QEMU exits cleanly with `bye` on SIGTERM and removes its shared files.
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

        # 2. key injection. After the first frame EDK2 is autonomous for a
        #    while: the splash ("Press ESCAPE for boot options", ~5 s) is
        #    replaced by the UEFI shell -- a >= 20% change of rows with no
        #    input at all -- and the shell's startup.nsh countdown then
        #    rewrites one text row per second for 5 s. ramfb re-sends full
        #    `update`s on every refresh tick, so state is judged on pixels
        #    only. To be sure that what we measure is caused by *our* keys:
        #    wait for the splash -> shell transition and for the countdown to
        #    end, check that the screen stays still for 3 s with no input
        #    (negative control), then type "help<Return>" and require >= 20%
        #    of rows to change; then repeat control + "cls<Return>". EDK2 has
        #    exactly one autonomous large transition, so two key-driven ones
        #    cannot both be explained by it. (The previous version of this
        #    test typed as soon as the splash was still for 2 s and passed on
        #    the autonomous transition even with no keys delivered.)
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

        def settle(min_quiet, label):
            """Wait until fewer than 10% of rows change in each 0.5 s sample
            for `min_quiet` s in a row; return the largest sample seen."""
            t0, quiet, peak = time.monotonic(), 0.0, 0.0
            prev = snapshot(fb, switch)
            while time.monotonic() - t0 < DEADLINE:
                drain(0.5)
                cur = snapshot(fb, switch)
                d = changed_rows(prev, cur)
                prev = cur
                peak = max(peak, d)
                quiet = quiet + 0.5 if d < 0.10 else 0.0
                if quiet >= min_quiet:
                    return peak
            fail(f"screen never settled ({label})")

        def type_and_expect(label, keys, threshold=0.20):
            ref = snapshot(fb, switch)
            drain(3.0)
            control = changed_rows(ref, snapshot(fb, switch))
            if control >= 0.10:
                fail(f"screen changed {control:.0%} of rows in 3 s with no input; "
                     f"cannot attribute changes to typing {label!r}")
            before = snapshot(fb, switch)
            for mac in keys:
                p.send({"t": "key", "mac": mac, "down": True})
                p.send({"t": "key", "mac": mac, "down": False})
            t0, best = time.monotonic(), 0.0
            while time.monotonic() - t0 < 15:
                drain(0.5)
                best = max(best, changed_rows(before, snapshot(fb, switch)))
                if best >= threshold:
                    break
            if best < threshold:
                fail(f"frame changed only {best:.0%} of rows within 15 s of typing {label!r} "
                     f"(control: {control:.0%} in 3 s with no input)")
            print(f"typing {label!r} changed {best:.0%} of rows in {time.monotonic() - t0:.1f}s "
                  f"(control {control:.0%})")

        start = time.monotonic()
        prev, quiet, transition = snapshot(fb, switch), 0.0, None
        while time.monotonic() - start < DEADLINE:
            drain(0.5)
            cur = snapshot(fb, switch)
            d = changed_rows(prev, cur)
            prev = cur
            if d >= 0.20:
                transition = d
                break
            quiet = quiet + 0.5 if d < 0.10 else 0.0
            if quiet >= 15.0:
                break   # 15 s without a transition: the first frame already was the shell
        else:
            fail("firmware never left the splash screen")
        if transition is None:
            print("no splash -> shell transition within 15 s; assuming the shell is up")
        else:
            print(f"splash -> shell transition ({transition:.0%} of rows) after {time.monotonic() - start:.1f}s")
        peak = settle(6.0, "shell prompt")
        print(f"shell settled after {time.monotonic() - start:.1f}s (largest later sample {peak:.0%})")
        type_and_expect("help", (4, 14, 37, 35, 36))   # kVK_ANSI_H, E, L, P, Return
        settle(3.0, "after help")
        type_and_expect("cls", (8, 1, 36))             # kVK_ANSI_C, S, Return

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
        # ramfb re-sends a full-surface `update` on every refresh tick, so an
        # `update` here does not prove the `refresh` handler (that needs a
        # device with dirty-rect tracking); it only proves the backend is
        # still streaming after the input burst.
        if not p.wait_for("update", 5):
            fail("no update within 5 s of the input burst (backend stalled?)")
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
