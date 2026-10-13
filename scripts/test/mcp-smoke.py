#!/usr/bin/env python3
"""Drive the alcove-mcp server over stdio JSON-RPC like an MCP client would.

  mcp-smoke.py --list-only        initialize + tools/list (no VM needed)
  mcp-smoke.py --vm "Windows 11"  also: list VMs, start, screenshot (image), exec, click, type, stop
"""
import base64, os, sys, time

sys.dont_write_bytecode = True
from mcp_stdio import MCP, MCPError, ROOT


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
        "alcove_record_start", "alcove_record_stop", "alcove_event_log", "alcove_crash_dumps", "alcove_collect_diagnostics",
    }
    http = {"alcove_http_capture_start", "alcove_http_capture_stop", "alcove_http_requests", "alcove_http_rule"}
    toolsets = {"core": core, "shell": shell, "files": files, "state": state, "ui": ui, "evidence": evidence, "http": http}
    selected = [s.strip() for s in env.get("ALCOVE_MCP_TOOLSETS", "").split(",") if s.strip()]
    expected = set().union(*(toolsets[s] for s in selected)) if selected else core | shell | files | state | ui | evidence | http
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
    try:
        main()
    except MCPError as e:
        raise SystemExit(str(e))
