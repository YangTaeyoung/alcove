#!/usr/bin/env python3
"""Drive the alcove-mcp server over stdio JSON-RPC like an MCP client would.

  mcp-smoke.py --list-only        initialize + tools/list (no VM needed)
  mcp-smoke.py --vm "Windows 11"  also: list VMs, start, screenshot (image), exec, click, type, stop
"""
import base64, json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SERVER = os.path.join(ROOT, "mcp", "dist", "index.js")


class MCP:
    def __init__(self, env):
        self.p = subprocess.Popen(["node", SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
        self.n = 0

    def request(self, method, params=None, timeout=300):
        self.n += 1
        msg = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            msg["params"] = params
        self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()
        end = time.time() + timeout
        while time.time() < end:
            line = self.p.stdout.readline()
            if not line:
                raise SystemExit("server closed stdout; stderr: " + self.p.stderr.read())
            try:
                reply = json.loads(line)
            except json.JSONDecodeError:
                raise SystemExit("non-JSON on stdout (protocol violation): " + line[:200])
            if reply.get("id") == self.n:
                if "error" in reply:
                    raise SystemExit(f"{method}: {reply['error']}")
                return reply["result"]
        raise SystemExit(f"{method}: timeout")

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()

    def call(self, name, args, timeout=300):
        r = self.request("tools/call", {"name": name, "arguments": args}, timeout)
        texts = [c["text"] for c in r.get("content", []) if c["type"] == "text"]
        images = [c for c in r.get("content", []) if c["type"] == "image"]
        return r.get("isError", False), "\n".join(texts), images

    def close(self):
        self.p.stdin.close()
        try:
            self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.kill()


def main():
    env = dict(os.environ)
    vm = None
    if "--vm" in sys.argv:
        vm = sys.argv[sys.argv.index("--vm") + 1]
    m = MCP(env)
    init = m.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}})
    print("server:", init["serverInfo"], "protocol:", init["protocolVersion"])
    m.notify("notifications/initialized")
    tools = m.request("tools/list")["tools"]
    names = sorted(t["name"] for t in tools)
    print("tools:", ", ".join(names))
    core = {
        "alcove_list_vms", "alcove_vm_status", "alcove_start_vm", "alcove_stop_vm", "alcove_screenshot", "alcove_click",
        "alcove_move_mouse", "alcove_drag", "alcove_scroll", "alcove_type", "alcove_press_keys", "alcove_exec",
        "alcove_get_clipboard", "alcove_set_clipboard", "alcove_push_file", "alcove_wait_idle",
    }
    shell = {
        "alcove_exec_start", "alcove_exec_read", "alcove_exec_write", "alcove_exec_kill", "alcove_exec_list",
        "alcove_process_list", "alcove_process_kill",
    }
    files = {"alcove_pull_file", "alcove_sync_dir", "alcove_fs_list", "alcove_fs_read", "alcove_fs_write", "alcove_fs_delete"}
    toolsets = {"core": core, "shell": shell, "files": files}
    selected = [s.strip() for s in env.get("ALCOVE_MCP_TOOLSETS", "").split(",") if s.strip()]
    expected = set().union(*(toolsets[s] for s in selected)) if selected else core | shell | files
    missing = expected - set(names)
    extra = set(names) - expected
    if missing or extra:
        raise SystemExit(f"tool list mismatch: missing {sorted(missing)}, unexpected {sorted(extra)}")
    print(f"{len(names)} tools as expected")
    for t in tools:
        assert t["inputSchema"]["type"] == "object", t["name"]
        assert t["description"], t["name"]
    if not vm:
        print("PASS (list-only)")
        m.close()
        return

    err, out, _ = m.call("alcove_list_vms", {})
    print("list_vms:", err, out)
    if err or vm not in out:
        raise SystemExit("VM not listed")
    err, out, _ = m.call("alcove_start_vm", {"name": vm}, 400)
    print("start:", err, out)
    if err:
        raise SystemExit("start failed")
    err, out, _ = m.call("alcove_wait_idle", {"name": vm, "seconds": 3, "timeout_s": 120}, 200)
    print("wait_idle:", err, out)
    err, out, imgs = m.call("alcove_screenshot", {"name": vm, "max_width": 800})
    print("screenshot:", err, out, "images:", len(imgs))
    if err or not imgs:
        raise SystemExit("screenshot failed")
    png = base64.b64decode(imgs[0]["data"])
    assert png[:4] == b"\x89PNG", "not a PNG"
    open(os.path.join(ROOT, "build", "mcp-shot.png"), "wb").write(png)
    # the guest may still be booting/logging in: wait for the tools to connect
    for _ in range(36):
        err, out, _ = m.call("alcove_vm_status", {"name": vm})
        if '"tools": true' in out:
            break
        time.sleep(5)
    print("status:", err, out.replace("\n", " ")[:300])
    err, out, _ = m.call("alcove_exec", {"name": vm, "command": "hostname"}, 200)
    print("exec hostname:", err, out.strip())
    if err:
        raise SystemExit("exec failed")
    err, out, _ = m.call("alcove_press_keys", {"name": vm, "keys": "win+r"})
    print("press win+r:", err, out)
    time.sleep(1.5)
    err, out, _ = m.call("alcove_type", {"name": vm, "text": "notepad\n"})
    print("type:", err, out)
    time.sleep(4)
    marker = f"typed via MCP {int(time.time())}"
    err, out, _ = m.call("alcove_type", {"name": vm, "text": marker})
    time.sleep(1)
    err, out, _ = m.call("alcove_press_keys", {"name": vm, "keys": "ctrl+a"})
    err, out, _ = m.call("alcove_press_keys", {"name": vm, "keys": "ctrl+c"})
    time.sleep(1)
    err, out, _ = m.call("alcove_get_clipboard", {"name": vm})
    print("clipboard after typing in notepad:", err, out.strip())
    if marker not in out:
        raise SystemExit("typed text did not round-trip through Notepad and the clipboard")
    err, out, imgs = m.call("alcove_screenshot", {"name": vm, "max_width": 800})
    open(os.path.join(ROOT, "build", "mcp-shot-notepad.png"), "wb").write(base64.b64decode(imgs[0]["data"]))
    # close notepad without saving: alt+f4 then "n" (Don't save)
    m.call("alcove_press_keys", {"name": vm, "keys": "alt+f4"}); time.sleep(1)
    m.call("alcove_press_keys", {"name": vm, "keys": "n"}); time.sleep(1)
    err, out, _ = m.call("alcove_click", {"name": vm, "x": 20, "y": 20, "button": "right"})
    print("right click:", err, out)
    m.call("alcove_press_keys", {"name": vm, "keys": "esc"})
    err, out, _ = m.call("alcove_stop_vm", {"name": vm}, 200)
    print("stop:", err, out)
    print("PASS: MCP end to end")
    m.close()


if __name__ == "__main__":
    main()
