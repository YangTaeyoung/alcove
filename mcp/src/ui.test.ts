import { test } from "node:test";
import assert from "node:assert/strict";
import { register } from "./tools/ui.js";
import { marksLegend } from "./observation.js";
import { rig, textOf } from "./test-rig.js";

test("alcove_list_windows prints one line per window with flags", async () => {
  const t = rig(register, { windows: [
    { id: "0x1A", title: "Notepad", process: "notepad.exe", pid: 12, x: 1, y: 2, w: 300, h: 200, state: "minimized", foreground: true, responding: false, modal: true },
    { id: "0x2B", title: "Calc", process: "calc.exe", pid: 13, x: 0, y: 0, w: 5, h: 6, state: "normal", foreground: false, responding: true, modal: false },
  ] });
  const r = await t.run("alcove_list_windows", { name: "vm" });
  assert.equal(textOf(r), '0x1A "Notepad" notepad.exe (12) 1,2 300x200 [foreground] [minimized] [modal] [NOT RESPONDING]\n0x2B "Calc" calc.exe (13) 0,0 5x6');
});

test("alcove_ui_click sends a nested camelCase selector and renders the observation", async () => {
  const t = rig(register, { x: 10, y: 20, node: { ref: "e3", role: "Button", name: "OK" }, observation: { settled: true } });
  const r = await t.run("alcove_ui_click", { name: "vm", name_contains: "O", role: "Button", element_name: "OK" });
  assert.deepEqual(t.calls[0].params, { name: "vm", selector: { role: "Button", name: "OK", nameContains: "O" }, button: "left", count: 1, observe: "summary" });
  assert.match(textOf(r), /clicked left e3 Button "OK" at \(10, 20\)\nscreen settled/);
});

test("a ref is sent alone without a selector", async () => {
  const t = rig(register, { x: 1, y: 2, node: { ref: "e1", role: "Button", name: "A" } });
  await t.run("alcove_ui_click", { name: "vm", ref: "e1", role: "Edit", window: "W" });
  assert.deepEqual(t.calls[0].params, { name: "vm", ref: "e1", button: "left", count: 1, observe: "summary" });
});

test("alcove_ui_click reports observationError after the click", async () => {
  const t = rig(register, { x: 1, y: 2, node: { ref: "e1", role: "Button", name: "A" }, observationError: "boom" });
  const r = await t.run("alcove_ui_click", { name: "vm", ref: "e1" });
  assert.match(textOf(r), /screen not read after the action: boom/);
  assert.ok(!r.isError);
});

test("a ui tool without a selector fails with the selector sentence", async () => {
  const t = rig(register);
  const r = await t.run("alcove_ui_type", { name: "vm", text: "x" });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "pass ref or at least one of role, element_name, name_contains, automation_id");
  assert.equal(t.calls.length, 0);
});

test("alcove_ui_tree appends a truncation line", async () => {
  const t = rig(register, { tree: "[e1] Window \"A\"", count: 300, truncated: true });
  const r = await t.run("alcove_ui_tree", { name: "vm" });
  assert.match(textOf(r), /^\[e1\] Window "A"\n\.\.\.tree truncated at 300 elements/);
});

test("alcove_window_action maps width and height", async () => {
  const t = rig(register, { window: { id: "0x1", title: "T", process: "p", pid: 1, x: 0, y: 0, w: 5, h: 6, state: "normal" } });
  await t.run("alcove_window_action", { name: "vm", window: "T", action: "resize", width: 5, height: 6 });
  assert.equal(t.calls[0].op, "vm.window.action");
  assert.equal(t.calls[0].params.width, 5);
});

test("alcove_window_action move and resize name the missing parameters", async () => {
  const t = rig(register);
  const move = await t.run("alcove_window_action", { name: "vm", window: "T", action: "move", x: 1 });
  assert.equal(textOf(move), "move needs x and y; pass both in guest pixels");
  const resize = await t.run("alcove_window_action", { name: "vm", window: "T", action: "resize", width: 1 });
  assert.equal(textOf(resize), "resize needs width and height; pass both in guest pixels");
  assert.equal(t.calls.length, 0);
});

test("alcove_ui_action set_value without value fails before calling the control op", async () => {
  const t = rig(register);
  const r = await t.run("alcove_ui_action", { name: "vm", ref: "e1", action: "set_value" });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "set_value needs value; pass the new value");
  assert.equal(t.calls.length, 0);
});

test("alcove_ui_get_text sends vm.ui.text, names the next offset and keeps the text out of structuredContent", async () => {
  const t = rig(register, { text: "a".repeat(70000), total: 90000, source: "text" });
  const r = await t.run("alcove_ui_get_text", { name: "vm", ref: "e5", mode: "pattern", offset: 100, length: 70000 });
  assert.deepEqual(t.calls[0], { op: "vm.ui.text", params: { name: "vm", ref: "e5", mode: "pattern", offset: 100, length: 70000 } });
  assert.match(textOf(r), /\.\.\.\[truncated; use offset 60100 to read the rest\]$/);
  assert.deepEqual(r.structuredContent, { total: 90000, source: "text", offset: 100, returned: 60000 });
});

test("alcove_ui_find sends the nested selector and limit", async () => {
  const t = rig(register, { nodes: [{ ref: "e1" }], text: "[e1] Button \"OK\"" });
  const r = await t.run("alcove_ui_find", { name: "vm", role: "Button", limit: 5 });
  assert.deepEqual(t.calls[0], { op: "vm.ui.find", params: { name: "vm", selector: { role: "Button" }, limit: 5 } });
  assert.match(textOf(r), /1 matches\n\[e1\] Button "OK"/);
});

test("alcove_launch_app maps wait_window_s to waitWindow", async () => {
  const t = rig(register, { pid: 4 });
  await t.run("alcove_launch_app", { name: "vm", path: "C:\\a.exe", wait_window_s: 7 });
  assert.deepEqual(t.calls[0].params, { name: "vm", path: "C:\\a.exe", waitWindow: 7 });
});

test("alcove_launch_app always sends waitWindow: 20 by default and passes 0 through", async () => {
  const t = rig(register, { pid: 4 });
  await t.run("alcove_launch_app", { name: "vm", path: "C:\\a.exe" });
  assert.equal(t.calls[0].params.waitWindow, 20);
  await t.run("alcove_launch_app", { name: "vm", path: "C:\\a.exe", wait_window_s: 0 });
  assert.equal(t.calls[1].params.waitWindow, 0);
});

test("alcove_deploy maps snake_case fields", async () => {
  const t = rig(register, { guestDir: "C:\\a", sent: ["x"], skipped: 0, bytes: 3, pid: 9 });
  const r = await t.run("alcove_deploy", { name: "vm", path: "/b", guest_dir: "C:\\a", wait_window_s: 5, kill_running: false });
  assert.deepEqual(t.calls[0].params, { name: "vm", path: "/b", guestDir: "C:\\a", waitWindow: 5, killRunning: false });
  assert.match(textOf(r), /sent 1 file\(s\)/);
});

test("marksLegend lists marks and is empty without them", () => {
  assert.equal(marksLegend(undefined), "");
  assert.equal(marksLegend([{ n: 1, ref: "e2", role: "Button", name: "OK", x: 1, y: 2, w: 3, h: 4 }]), '\nmarked elements:\n1: e2 Button "OK" (1,2 3x4)');
});
