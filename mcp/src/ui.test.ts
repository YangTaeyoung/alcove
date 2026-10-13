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

test("alcove_launch_app says that no window appeared only when the reply carries windowTimedOut", async () => {
  const timedOut = rig(register, { pid: 4, windowTimedOut: true, eventSeq: 12 });
  const late = await timedOut.run("alcove_launch_app", { name: "vm", path: "C:\\a.exe", wait_window_s: 7 });
  assert.equal(textOf(late), "started pid 4\nno window appeared within 7 s; check alcove_list_windows\neventSeq 12");
  assert.deepEqual(late.structuredContent, { pid: 4, window: undefined, windowTimedOut: true, eventSeq: 12 });
  const byDefault = await timedOut.run("alcove_launch_app", { name: "vm", path: "C:\\a.exe" });
  assert.match(textOf(byDefault), /no window appeared within 20 s;/);

  const unwaited = rig(register, { pid: 4 });
  const quiet = await unwaited.run("alcove_launch_app", { name: "vm", path: "C:\\a.exe", wait_window_s: 0 });
  assert.equal(textOf(quiet), "started pid 4");
  const w = { id: "0x1", title: "T", process: "p.exe", pid: 4, x: 0, y: 0, w: 5, h: 6, state: "normal" };
  const shown = await rig(register, { pid: 4, window: w }).run("alcove_launch_app", { name: "vm", path: "C:\\a.exe" });
  assert.equal(textOf(shown), 'started pid 4\n0x1 "T" p.exe (4) 0,0 5x6');
});

test("alcove_deploy says that no window appeared only when the reply carries windowTimedOut", async () => {
  const base = { guestDir: "C:\\a", sent: ["x"], skipped: 0, bytes: 3, pid: 9, eventSeq: 5 };
  const timedOut = await rig(register, { ...base, windowTimedOut: true }).run("alcove_deploy", { name: "vm", path: "/b", launch: { exe: "a.exe" }, wait_window_s: 5 });
  assert.equal(textOf(timedOut), "deployed to C:\\a: sent 1 file(s), skipped 0 unchanged, 3 bytes\nstarted pid 9\nno window appeared within 5 s; check alcove_list_windows\neventSeq 5");
  const unwaited = await rig(register, base).run("alcove_deploy", { name: "vm", path: "/b", launch: { exe: "a.exe" }, wait_window_s: 0 });
  assert.equal(textOf(unwaited), "deployed to C:\\a: sent 1 file(s), skipped 0 unchanged, 3 bytes\nstarted pid 9\neventSeq 5");
  const copied = await rig(register, { guestDir: "C:\\a", sent: [], skipped: 2, bytes: 0 }).run("alcove_deploy", { name: "vm", path: "/b" });
  assert.equal(textOf(copied), "deployed to C:\\a: sent 0 file(s), skipped 2 unchanged, 0 bytes");
});

test("alcove_events prints the title of window events, the code and path of exits, and a gap", async () => {
  const win = { id: "0x1", title: "Fixture Dialog", process: "p.exe", pid: 4 };
  const events = [
    { seq: 41, time: "T1", name: "dialog.opened", window: win },
    { seq: 42, time: "T2", name: "window.foreground", window: { ...win, title: "" } },
    { seq: 43, time: "T3", name: "process.exited", pid: 7140, code: 3221227010, path: "C:\\apps\\crash me.exe" },
    { seq: 44, time: "T4", name: "job.exited", job: "j7", code: 0 },
  ];
  const gapped = rig(register, { events, next: 44, first: 41 });
  const r = await gapped.run("alcove_events", { name: "vm", since: 10 });
  assert.equal(textOf(r), [
    "4 events",
    "events 11 to 40 are no longer kept; the list starts at 41",
    '41 T1 dialog.opened "Fixture Dialog"',
    '42 T2 window.foreground ""',
    "43 T3 process.exited code 3221227010 C:\\apps\\crash me.exe",
    "44 T4 job.exited code 0 job j7",
    "next: 44",
  ].join("\n"));
  assert.deepEqual(r.structuredContent, { events, next: 44, first: 41 });
  const whole = await rig(register, { events, next: 44, first: 41 }).run("alcove_events", { name: "vm", since: 40 });
  assert.doesNotMatch(textOf(whole), /no longer kept/);
  const fromTheStart = await rig(register, { events: [], next: 0, first: 0 }).run("alcove_events", { name: "vm" });
  assert.equal(textOf(fromTheStart), "no new events\nnext: 0");
  const rolled = await rig(register, { events, next: 44, first: 41 }).run("alcove_events", { name: "vm" });
  assert.match(textOf(rolled), /events 1 to 40 are no longer kept/);
});

test("the ui tools wait longer than the control op can take", async () => {
  const t = rig(register, { windows: [], tree: "", nodes: [], text: "", node: { ref: "e1" }, x: 1, y: 2, guestDir: "C:\\a", sent: [] });
  await t.run("alcove_list_windows", { name: "vm" });
  await t.run("alcove_ui_tree", { name: "vm" });
  await t.run("alcove_ui_find", { name: "vm", role: "Button" });
  await t.run("alcove_ui_get_text", { name: "vm", ref: "e1" });
  await t.run("alcove_ui_click", { name: "vm", ref: "e1" });
  await t.run("alcove_ui_type", { name: "vm", ref: "e1", text: "abcde" });
  await t.run("alcove_ui_action", { name: "vm", ref: "e1", action: "invoke", settle_timeout_ms: 5000 });
  await t.run("alcove_window_action", { name: "vm", window: "T", action: "focus" });
  await t.run("alcove_deploy", { name: "vm", path: "/b" });
  assert.deepEqual(t.timeouts, [250000, 250000, 250000, 250000, 252000, 252100, 255000, 252000, 5400000]);
});

test("alcove_window_action and alcove_ui_action tell what the action left behind", async () => {
  const closed = await rig(register, { window: null, closed: true, eventSeq: 3 }).run("alcove_window_action", { name: "vm", window: "Dialog", action: "close" });
  assert.equal(textOf(closed), "close Dialog: the window closed\neventSeq 3");
  const open = await rig(register, { window: { id: "0x1", title: "T", process: "p", pid: 1, x: 0, y: 0, w: 5, h: 6, state: "normal" }, closed: false })
    .run("alcove_window_action", { name: "vm", window: "T", action: "close" });
  assert.equal(textOf(open), 'close T: the window is still open\n0x1 "T" p (1) 0,0 5x6');
  const node = { ref: "e1", role: "Button", name: "Crash", flags: [] };
  const gone = await rig(register, { node, gone: true }).run("alcove_ui_action", { name: "vm", ref: "e1", action: "invoke" });
  assert.equal(textOf(gone), 'invoke e1 Button "Crash"\nthe element is gone after the action; the line above shows it as it was before');
  const hung = await rig(register, { node, unresponsive: true }).run("alcove_ui_action", { name: "vm", ref: "e1", action: "invoke" });
  assert.match(textOf(hung), /\nits window stopped responding during the action; /);
});

test("marksLegend lists marks and is empty without them", () => {
  assert.equal(marksLegend(undefined), "");
  assert.equal(marksLegend([{ n: 1, ref: "e2", role: "Button", name: "OK", x: 1, y: 2, w: 3, h: 4 }]), '\nmarked elements:\n1: e2 Button "OK" (1,2 3x4)');
});
