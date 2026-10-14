#!/usr/bin/env python3
"""Tiny client for the Alcove control socket (docs/control-protocol.md).
Usage: ctl.py OP [key=value ...]   e.g. ctl.py vm.exec name="Windows 11" command=hostname
Values that parse as JSON (numbers, true/false) are sent typed; others as strings.
An image in the reply (`png` or `jpeg`) is saved to the path in `out=` (not sent to the server),
else to a new file in the current directory, and the reply shows `saved`.
Starts `alcovectl serve` when nothing answers (needs ALCOVE_CTL or a dev build)."""
import base64, json, os, sys, tempfile

sys.dont_write_bytecode = True
from alcove_ctl import Client, ControlError


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    op, params = sys.argv[1], {}
    for kv in sys.argv[2:]:
        if "=" not in kv:
            raise SystemExit(f"'{kv}' is not key=value; write every parameter as key=value")
        k, v = kv.split("=", 1)
        try:
            params[k] = json.loads(v)
        except ValueError:
            params[k] = v
    out = params.pop("out", None)
    try:
        client = Client()
        r = client.wait(client.send(op, **params), None)
        client.close()
    except ControlError as e:
        raise SystemExit(str(e))
    for kind in ("png", "jpeg"):
        if isinstance(r.get(kind), str):
            data = base64.b64decode(r.pop(kind))
            if out:
                path = out
                with open(path, "wb") as f:
                    f.write(data)
            else:
                fd, path = tempfile.mkstemp(prefix="alcove-ctl-", suffix="." + ("jpg" if kind == "jpeg" else kind), dir=os.getcwd())
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
            r["saved"] = path
    print(json.dumps(r, indent=2, ensure_ascii=False))
    sys.exit(0 if r.get("ok") else 1)


if __name__ == "__main__":
    main()
