#!/usr/bin/env python3
"""Tiny client for the Alcove control socket (docs/control-protocol.md).
Usage: ctl.py OP [key=value ...]   e.g. ctl.py vm.exec name="Windows 11" command=hostname
Values that parse as JSON (numbers, true/false) are sent typed; others as strings.
Starts `alcovectl serve` when nothing answers (needs ALCOVE_CTL or a dev build)."""
import json, os, socket, subprocess, sys, time

SOCK = os.environ.get("ALCOVE_CONTROL_SOCKET", os.path.expanduser("~/Library/Application Support/Alcove/control.sock"))
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def connect():
    for attempt in range(40):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(SOCK)
            return s
        except OSError:
            if attempt == 0:
                ctl = os.environ.get("ALCOVE_CTL") or os.path.join(ROOT, "AlcoveKit", ".build-ctl", "debug", "alcovectl")
                subprocess.Popen([ctl, "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(0.5)
    raise SystemExit("cannot connect to " + SOCK)


def call(s, op, **params):
    s.sendall((json.dumps({"id": 1, "op": op, **params}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            raise SystemExit("connection closed")
        buf += chunk
    return json.loads(buf.split(b"\n", 1)[0])


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    op, params = sys.argv[1], {}
    for kv in sys.argv[2:]:
        k, v = kv.split("=", 1)
        try:
            params[k] = json.loads(v)
        except ValueError:
            params[k] = v
    r = call(connect(), op, **params)
    if "png" in r:
        path = params.get("out", "/tmp/alcove-ctl-shot.png")
        import base64
        open(path, "wb").write(base64.b64decode(r.pop("png")))
        r["saved"] = path
    print(json.dumps(r, indent=2, ensure_ascii=False))
    sys.exit(0 if r.get("ok") else 1)


if __name__ == "__main__":
    main()
