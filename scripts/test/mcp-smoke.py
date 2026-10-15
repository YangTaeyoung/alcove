#!/usr/bin/env python3
"""Drive the alcove-mcp server over stdio JSON-RPC like an MCP client would.

  mcp-smoke.py --list-only        initialize + tools/list (no VM needed)
  mcp-smoke.py --vm "Windows 11"  also: two parallel first calls on one control connection, list VMs, start,
                                  screenshot (image), exec, click, type, a recording with an HTTP capture saved
                                  as a script, that script run under this session's lease without `name`,
                                  a failing script with its failure image, stop
"""
import base64, json, os, shutil, subprocess, sys, tempfile, time

sys.dont_write_bytecode = True
from mcp_stdio import MCP, MCPError, ROOT

DEFAULT_SOCKET = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Alcove", "control.sock")
CAPTURE_REASON = "an HTTP capture and its rules belong to the setup of a run, not to its steps"
MISSING_WINDOW = "alcove-smoke-no-such-window"


def control_connections(pid, socket_path):
    """The unix sockets of process `pid` whose peer is a socket bound to `socket_path`, as lsof lists them."""
    rows = subprocess.run(["lsof", "-nP", "-U"], capture_output=True, text=True).stdout.splitlines()
    server_ends = {row.split()[5] for row in rows if row.endswith(socket_path) and len(row.split()) > 5}
    count = 0
    for row in rows:
        fields = row.split()
        if len(fields) > 5 and fields[1] == str(pid) and fields[-1].startswith("->") and fields[-1][2:] in server_ends:
            count += 1
    return count


def check(ok, message):
    if not ok:
        raise SystemExit(message)


def capture_script(m, vm, work):
    """Records a key press inside an HTTP capture and saves the recording as a script; returns the script path."""
    rec = os.path.join(work, "recording")
    script = os.path.join(work, "capture.json")
    err, out, _ = m.call("alcove_record_start", {"name": vm, "video": False, "dir": rec})
    print("record start:", err, out)
    check(not err, "record start failed")
    err, out, _ = m.call("alcove_http_capture_start", {"name": vm}, 400)
    print("http capture start:", err, out.replace("\n", " ")[:300])
    check(not err, "http capture start failed")
    err, out, _ = m.call("alcove_press_keys", {"name": vm, "keys": "esc"})
    print("press esc:", err, out)
    check(not err, "press esc failed")
    err, out, _ = m.call("alcove_http_capture_stop", {"name": vm}, 400)
    print("http capture stop:", err, out)
    check(not err, "http capture stop failed")
    err, out, _ = m.call("alcove_record_stop", {"name": vm})
    print("record stop:", err, out.replace("\n", " "))
    check(not err, "record stop failed")
    err, out, _ = m.call("alcove_script_save", {"dir": rec, "path": script}, 200)
    print("script save:", err, out)
    check(not err, "script save failed")
    warnings = [line for line in out.splitlines() if line.startswith("warning: ") and CAPTURE_REASON in line]
    check(any("vm.http.start" in w for w in warnings) and any("vm.http.stop" in w for w in warnings),
          f"alcove_script_save printed no capture warning for vm.http.start and vm.http.stop:\n{out}")
    with open(script, encoding="utf-8") as f:
        saved = json.load(f)
    ops = [step["op"] for step in saved["steps"]]
    check(saved.get("vm") == vm and "vm.key.press" in ops and not any(op.startswith("vm.http.") for op in ops),
          f"the saved script names VM {saved.get('vm')!r} and has the steps {ops}; expected {vm!r} and vm.key.press without vm.http.* steps")
    return script


def run_under_lease(m, vm, script):
    """Runs `script` without `name` while this session holds the lease of the VM the script names."""
    err, out, _ = m.call("alcove_lease_acquire", {"name": vm, "ttl_s": 600})
    print("lease acquire:", err, out)
    check(not err, "lease acquire failed")
    try:
        err, out, imgs = m.call("alcove_script_run", {"path": script}, 600)
        print("script run under the lease:", err, out.replace("\n", " | "))
        rows = out.splitlines()
        check(not err and rows and rows[-1].startswith("PASSED") and not imgs,
              f"alcove_script_run without name under this session's lease answered error={err} with {len(imgs)} images:\n{out}")
    finally:
        err, out, _ = m.call("alcove_lease_release", {"name": vm})
        print("lease release:", err, out)


def failing_script(m, vm, work):
    """Runs a script whose one step waits for a window that does not exist and checks the FAILED line and the failure image."""
    script = os.path.join(work, "failing.json")
    with open(script, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "vm": vm, "steps": [{
            "label": "missing window", "op": "vm.screenshot", "params": {},
            "expect": [{"type": "window_title", "contains": MISSING_WINDOW}], "timeout": 2,
        }]}, f)
    err, out, imgs = m.call("alcove_script_run", {"path": script, "name": vm}, 600)
    print("failing script run:", err, out.replace("\n", " | "), "images:", len(imgs))
    rows = out.splitlines()
    check(rows and rows[-1].startswith("FAILED: step 1 failed") and any(r.startswith("FAIL 1 missing window") for r in rows),
          f"the failing script did not end with FAILED: step 1 failed:\n{out}")
    check(len(imgs) == 1 and imgs[0]["mimeType"] == "image/png" and base64.b64decode(imgs[0]["data"])[:4] == b"\x89PNG",
          f"the failing script returned {len(imgs)} images; expected one PNG failure image")
    with open(os.path.join(ROOT, "build", "mcp-script-failure.png"), "wb") as f:
        f.write(base64.b64decode(imgs[0]["data"]))


def main():
    env = dict(os.environ)
    vm = None
    if "--vm" in sys.argv:
        vm = sys.argv[sys.argv.index("--vm") + 1]
    m = MCP(env)
    init = m.initialize()
    print("server:", init["serverInfo"], "protocol:", init["protocolVersion"])
    tools = m.request("tools/list")["tools"]
    names = sorted(t["name"] for t in tools)
    print("tools:", ", ".join(names))
    core = {
        "alcove_list_vms", "alcove_vm_status", "alcove_start_vm", "alcove_stop_vm", "alcove_screenshot", "alcove_click",
        "alcove_move_mouse", "alcove_drag", "alcove_scroll", "alcove_type", "alcove_press_keys", "alcove_exec",
        "alcove_get_clipboard", "alcove_set_clipboard", "alcove_push_file", "alcove_wait_idle",
        "alcove_find_text", "alcove_wait_for", "alcove_batch", "alcove_mouse_down", "alcove_mouse_up", "alcove_key_down", "alcove_key_up",
    }
    shell = {
        "alcove_exec_start", "alcove_exec_read", "alcove_exec_write", "alcove_exec_kill", "alcove_exec_list",
        "alcove_process_list", "alcove_process_kill",
    }
    files = {"alcove_pull_file", "alcove_sync_dir", "alcove_fs_list", "alcove_fs_read", "alcove_fs_write", "alcove_fs_delete"}
    state = {
        "alcove_pause_vm", "alcove_resume_vm", "alcove_snapshot_list", "alcove_snapshot_create", "alcove_snapshot_restore",
        "alcove_snapshot_delete", "alcove_clone_vm", "alcove_delete_vm", "alcove_lease_acquire", "alcove_lease_release",
        "alcove_port_forward_add", "alcove_port_forward_remove", "alcove_port_forward_list", "alcove_set_network",
        "alcove_set_resolution", "alcove_set_environment", "alcove_doctor",
    }
    ui = {
        "alcove_list_windows", "alcove_window_action", "alcove_ui_tree", "alcove_ui_find", "alcove_ui_get_text",
        "alcove_ui_click", "alcove_ui_type", "alcove_ui_action", "alcove_launch_app", "alcove_deploy", "alcove_events",
    }
    evidence = {
        "alcove_record_start", "alcove_record_stop", "alcove_record_status", "alcove_event_log", "alcove_crash_dumps", "alcove_collect_diagnostics",
    }
    replay = {"alcove_script_save", "alcove_script_run"}
    http = {"alcove_http_capture_start", "alcove_http_capture_stop", "alcove_http_requests", "alcove_http_rule"}
    toolsets = {"core": core, "shell": shell, "files": files, "state": state, "ui": ui, "evidence": evidence, "replay": replay, "http": http}
    selected = [s.strip() for s in env.get("ALCOVE_MCP_TOOLSETS", "").split(",") if s.strip()]
    expected = set().union(*(toolsets[s] for s in selected)) if selected else core | shell | files | state | ui | evidence | replay | http
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

    socket_path = env.get("ALCOVE_CONTROL_SOCKET", DEFAULT_SOCKET)
    (err, out, _), (status_err, status_out, _) = m.call_together([("alcove_list_vms", {}), ("alcove_vm_status", {"name": vm})])
    print("list_vms:", err, out)
    print("vm_status in parallel:", status_err, status_out.replace("\n", " ")[:200])
    if err or vm not in out:
        raise SystemExit("VM not listed")
    check(not status_err, "alcove_vm_status sent with the first call failed")
    connections = control_connections(m.p.pid, socket_path)
    print("control connections after two parallel first calls:", connections)
    check(connections == 1, f"the two parallel first calls left {connections} connections to {socket_path}; expected 1")
    err, out, _ = m.call("alcove_start_vm", {"name": vm}, 1000)
    print("start:", err, out)
    if err:
        raise SystemExit("start failed")
    stopped = False
    try:
        err, out, _ = m.call("alcove_wait_idle", {"name": vm, "seconds": 3, "timeout_s": 120}, 200)
        print("wait_idle:", err, out)
        err, out, imgs = m.call("alcove_screenshot", {"name": vm, "max_width": 800})
        print("screenshot:", err, out, "images:", len(imgs))
        if err or not imgs:
            raise SystemExit("screenshot failed")
        png = base64.b64decode(imgs[0]["data"])
        assert png[:4] == b"\x89PNG", "not a PNG"
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
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
        work = tempfile.mkdtemp(prefix="alcove-mcp-smoke-")
        try:
            script = capture_script(m, vm, work)
            run_under_lease(m, vm, script)
            failing_script(m, vm, work)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        err, out, _ = m.call("alcove_stop_vm", {"name": vm}, 200)
        stopped = True
        print("stop:", err, out)
    finally:
        if not stopped:
            try:
                m.call("alcove_stop_vm", {"name": vm}, 200)
            except MCPError as e:
                print(f"stopping {vm} after the failure failed too: {e}; stop it with alcove_stop_vm or in the Alcove app", file=sys.stderr)
    print("PASS: MCP end to end")
    m.close()


if __name__ == "__main__":
    try:
        main()
    except MCPError as e:
        raise SystemExit(str(e))
