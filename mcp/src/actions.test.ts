import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerActions } from "./tools/actions.js";
import { register as registerCore } from "./tools/core.js";
import type { ControlClient } from "./control.js";
import type { Registrar, ToolHandler } from "./toolkit.js";

type Call = { op: string; params: Record<string, unknown> };

function rig(reply: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const handlers = new Map<string, ToolHandler>();
  const registrar: Registrar = { tool: (_set, name, _config, handler) => void handlers.set(name, handler) };
  const client = { call: async (op: string, params: Record<string, unknown> = {}) => (calls.push({ op, params }), reply) } as unknown as ControlClient;
  registerActions(registrar, client);
  registerCore(registrar, client);
  return {
    calls,
    run: async (tool: string, args: Record<string, unknown>) => {
      await handlers.get(tool)!(args);
      return calls[calls.length - 1];
    },
  };
}

const sent = (c: Call) => ({ op: c.op, params: c.params });

test("alcove_mouse_down and alcove_mouse_up send the button and omit x and y when not given", async () => {
  const { run } = rig();
  assert.deepEqual(sent(await run("alcove_mouse_down", { name: "Win" })), { op: "vm.mouse.down", params: { name: "Win", button: "left", observe: "none" } });
  assert.deepEqual(sent(await run("alcove_mouse_up", { name: "Win", button: "right" })), { op: "vm.mouse.up", params: { name: "Win", button: "right", observe: "none" } });
  assert.deepEqual(sent(await run("alcove_mouse_down", { name: "Win", x: 5, y: 6, observe: "summary", settle_ms: 100 })),
    { op: "vm.mouse.down", params: { name: "Win", button: "left", x: 5, y: 6, observe: "summary", settleMs: 100 } });
});

test("alcove_key_down and alcove_key_up send the single parameter key", async () => {
  const { run } = rig();
  assert.deepEqual(sent(await run("alcove_key_down", { name: "Win", key: "shift" })), { op: "vm.key.down", params: { name: "Win", key: "shift", observe: "none" } });
  assert.deepEqual(sent(await run("alcove_key_up", { name: "Win", key: "a", observe: "diff" })), { op: "vm.key.up", params: { name: "Win", key: "a", observe: "diff" } });
});

test("the basic action tools send the parameter names the control ops read", async () => {
  const { run } = rig();
  assert.deepEqual(sent(await run("alcove_click", { name: "W", x: 1, y: 2 })), { op: "vm.mouse.click", params: { name: "W", x: 1, y: 2, button: "left", count: 1, observe: "summary" } });
  assert.deepEqual(sent(await run("alcove_move_mouse", { name: "W", x: 1, y: 2 })), { op: "vm.mouse.move", params: { name: "W", x: 1, y: 2, observe: "summary" } });
  assert.deepEqual(sent(await run("alcove_drag", { name: "W", from_x: 1, from_y: 2, to_x: 3, to_y: 4 })),
    { op: "vm.mouse.drag", params: { name: "W", fromX: 1, fromY: 2, toX: 3, toY: 4, button: "left", observe: "summary" } });
  assert.deepEqual(sent(await run("alcove_scroll", { name: "W", x: 1, y: 2, dy: 3 })), { op: "vm.mouse.scroll", params: { name: "W", x: 1, y: 2, dy: 3, dx: 0, observe: "summary" } });
  assert.deepEqual(sent(await run("alcove_type", { name: "W", text: "hi", delay_ms: 5 })), { op: "vm.type", params: { name: "W", text: "hi", delay: 5, observe: "summary" } });
  assert.deepEqual(sent(await run("alcove_press_keys", { name: "W", keys: "ctrl+c", hold_ms: 7 })), { op: "vm.key.press", params: { name: "W", keys: "ctrl+c", hold: 7, observe: "summary" } });
});

test("find_text, screenshot, wait_for and batch send the parameter names the control ops read", async () => {
  const { run } = rig({ matches: [], sentWidth: 1, sentHeight: 1, scale: 1 });
  assert.deepEqual(sent(await run("alcove_find_text", { name: "W", query: "ok", regex: true, region: { x: 1, y: 2, w: 3, h: 4 }, languages: ["en-US"] })),
    { op: "vm.find_text", params: { name: "W", query: "ok", regex: true, region: { x: 1, y: 2, w: 3, h: 4 }, languages: ["en-US"] } });
  assert.deepEqual(sent(await run("alcove_screenshot", { name: "W", region: { x: 1, y: 2, w: 3, h: 4 }, scale: 0.5, format: "jpeg", quality: 0.7, max_width: 640 })),
    { op: "vm.screenshot", params: { name: "W", maxWidth: 640, region: { x: 1, y: 2, w: 3, h: 4 }, scale: 0.5, format: "jpeg", quality: 0.7 } });
  assert.deepEqual(sent(await run("alcove_wait_for", { name: "W", conditions: [{ type: "process_exited", process_name: "a.exe" }], timeout_s: 5, settle_timeout_ms: 500 })),
    { op: "vm.wait_for", params: { name: "W", conditions: [{ type: "process_exited", processName: "a.exe" }], timeout: 5, observe: "none", settleTimeoutMs: 500 } });
  assert.deepEqual(sent(await run("alcove_batch", { name: "W", steps: [{ op: "key_down", key: "shift" }, { op: "mouse_up", x: 1, y: 2 }] })),
    { op: "vm.batch", params: { name: "W", steps: [{ op: "vm.key.down", key: "shift" }, { op: "vm.mouse.up", x: 1, y: 2 }], observe: "summary" } });
});

test("alcove_screenshot states the guest area from areaWidth and areaHeight", async () => {
  const reply = { width: 1920, height: 1080, sentWidth: 200, sentHeight: 100, x: 40, y: 50, scale: 0.5, areaWidth: 400, areaHeight: 201, png: "QUJD" };
  const handlers = new Map<string, ToolHandler>();
  const registrar: Registrar = { tool: (_set, name, _config, handler) => void handlers.set(name, handler) };
  registerCore(registrar, { call: async () => reply } as unknown as ControlClient);
  const result = await handlers.get("alcove_screenshot")!({ name: "Win" });
  assert.match((result.content[0] as { text: string }).text, /image 200x100 shows guest \(40,50\) 400x201 at scale 0\.5;/);
});
