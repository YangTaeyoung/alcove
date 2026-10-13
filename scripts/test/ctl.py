#!/usr/bin/env python3
"""Tiny client for the Alcove control socket (docs/control-protocol.md).
Usage: ctl.py OP [key=value ...]   e.g. ctl.py vm.exec name="Windows 11" command=hostname
Values that parse as JSON (numbers, true/false) are sent typed; others as strings.
Starts `alcovectl serve` when nothing answers (needs ALCOVE_CTL or a dev build)."""
import json, sys

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError


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
    try:
        client = Client()
        r = client.wait(client.send(op, **params), None)
        client.close()
    except ControlError as e:
        raise SystemExit(str(e))
    if "png" in r:
        path = params.get("out", "/tmp/alcove-ctl-shot.png")
        import base64
        open(path, "wb").write(base64.b64decode(r.pop("png")))
        r["saved"] = path
    print(json.dumps(r, indent=2, ensure_ascii=False))
    sys.exit(0 if r.get("ok") else 1)


if __name__ == "__main__":
    main()
