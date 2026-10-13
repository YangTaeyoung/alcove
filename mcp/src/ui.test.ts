import { test } from "node:test";
import assert from "node:assert/strict";
import { register } from "./tools/ui.js";
import { marksLegend } from "./observation.js";
import type { ControlClient } from "./control.js";
import type { Registrar, ToolHandler } from "./toolkit.js";

type Call = { op: string; params: Record<string, unknown> };

function rig(reply: Record<string, unknown>) {
  const calls: Call[] = [];
  const handlers = new Map<string, ToolHandler>();
  const registrar: Registrar = { tool: (_set, name, _config, handler) => void handlers.set(name, handler) };
  const client = { call: async (op: string, params: Record<string, unknown> = {}) => (calls.push({ op, params }), reply) } as unknown as ControlClient;
  register(registrar, client);
  return { calls, run: (tool: string, args: Record<string, unknown>) => handlers.get(tool)!(args) };
}

const textOf = (r: { content: Array<{ type: string; text?: string }> }) => r.content.map((c) => c.text ?? "").join("\n");

test("alcove_list_windows prints one line per window with flags", async () => {
  const t = rig({ windows: [{ id: "0x1A", title: "Notepad", process: "notepad.exe", pid: 12, x: 1, y: 2, w: 300, h: 200, state: "minimized", foreground: true, responding: false }] });
  const r = await t.run("alcove_list_windows", { name: "vm" });
  assert.equal(textOf(r), '0x1A "Notepad" notepad.exe (12) 1,2 300x200 [foreground] [minimized] [NOT RESPONDING]');
});

test("alcove_ui_click sends the camelCase selector and renders the observation", async () => {
  const t = rig({ x: 10, y: 20, node: { ref: "e3", role: "Button", name: "OK" }, observation: { settled: true } });
  const r = await t.run("alcove_ui_click", { name: "vm", name_contains: "O", role: "Button", element_name: "OK" });
  assert.deepEqual(t.calls[0].params, { name: "vm", selector: { role: "Button", name: "OK", nameContains: "O" }, button: "left", count: 1, observe: "summary" });
  assert.match(textOf(r), /clicked left e3 Button "OK" at \(10, 20\)\nscreen settled/);
});

test("alcove_ui_click reports observationError after the click", async () => {
  const t = rig({ x: 1, y: 2, node: { ref: "e1", role: "Button", name: "A" }, observationError: "boom" });
  const r = await t.run("alcove_ui_click", { name: "vm", ref: "e1" });
  assert.match(textOf(r), /screen not read after the action: boom/);
  assert.ok(!r.isError);
});

test("a ui tool without a selector fails with the selector sentence", async () => {
  const t = rig({});
  const r = await t.run("alcove_ui_type", { name: "vm", text: "x" });
  assert.equal(r.isError, true);
  assert.match(textOf(r), /pass ref or at least one of role/);
  assert.equal(t.calls.length, 0);
});

test("alcove_ui_tree appends a truncation line", async () => {
  const t = rig({ tree: "[e1] Window \"A\"", count: 300, truncated: true });
  const r = await t.run("alcove_ui_tree", { name: "vm" });
  assert.match(textOf(r), /^\[e1\] Window "A"\n\.\.\.tree truncated at 300 elements/);
});

test("alcove_window_action maps width and height", async () => {
  const t = rig({ window: { id: "0x1", title: "T", process: "p", pid: 1, x: 0, y: 0, w: 5, h: 6, state: "normal" } });
  await t.run("alcove_window_action", { name: "vm", window: "T", action: "resize", width: 5, height: 6 });
  assert.equal(t.calls[0].op, "vm.window.action");
  assert.equal(t.calls[0].params.width, 5);
});

test("alcove_deploy maps snake_case fields", async () => {
  const t = rig({ guestDir: "C:\\a", sent: ["x"], skipped: 0, bytes: 3, pid: 9 });
  const r = await t.run("alcove_deploy", { name: "vm", path: "/b", guest_dir: "C:\\a", wait_window_s: 5, kill_running: false });
  assert.deepEqual(t.calls[0].params, { name: "vm", path: "/b", guestDir: "C:\\a", waitWindow: 5, killRunning: false });
  assert.match(textOf(r), /sent 1 file\(s\)/);
});

test("marksLegend lists marks and is empty without them", () => {
  assert.equal(marksLegend(undefined), "");
  assert.equal(marksLegend([{ n: 1, ref: "e2", role: "Button", name: "OK", x: 1, y: 2, w: 3, h: 4 }]), '\nmarked elements:\n1: e2 Button "OK" (1,2 3x4)');
});
