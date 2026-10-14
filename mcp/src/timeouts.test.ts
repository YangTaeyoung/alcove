import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerCore } from "./tools/core.js";
import { register as registerActions } from "./tools/actions.js";
import { register as registerState } from "./tools/state.js";
import type { LeasedControlClient } from "./leases.js";
import { register as registerUi } from "./tools/ui.js";
import { UI_CALL_TIMEOUT_MS } from "./toolkit.js";
import { rig } from "./test-rig.js";

const stateRig = (reply: Record<string, unknown>) => rig((r, c) => registerState(r, c as unknown as LeasedControlClient), reply);

test("alcove_type waits at least three key events per character, each with its delay", async () => {
  const t = rig(registerCore, {});
  await t.run("alcove_type", { name: "vm", text: "a".repeat(20000) });
  await t.run("alcove_type", { name: "vm", text: "a".repeat(2000), delay_ms: 200 });
  assert.ok(t.timeouts[0]! > (3 * 20000 + 1) * 12, String(t.timeouts[0]));
  assert.ok(t.timeouts[1]! > (3 * 2000 + 1) * 200, String(t.timeouts[1]));
});

test("alcove_batch waits for the sum of its steps' own limits", async () => {
  const t = rig(registerActions, { completed: 3, results: [] });
  await t.run("alcove_batch", {
    name: "vm",
    steps: [
      { op: "wait_for", conditions: [{ type: "screen_idle" }], timeout_s: 600 },
      { op: "wait_idle", timeout_s: 600 },
      { op: "type", text: "a".repeat(20000), delay_ms: 20 },
      { op: "sleep", ms: 10000 },
    ],
  });
  assert.ok(t.timeouts[0]! > 600000 + 600000 + (3 * 20000 + 1) * 20 + 10000, String(t.timeouts[0]));
});

test("alcove_find_text waits for two recognitions, each with its turn", async () => {
  const t = rig(registerActions, { matches: [] });
  await t.run("alcove_find_text", { name: "vm" });
  assert.ok(t.timeouts[0]! > 2 * 60000, String(t.timeouts[0]));
});

test("alcove_doctor waits for its two guest recipes, the tools and the screen", async () => {
  const t = stateRig({ checks: [] });
  await t.run("alcove_doctor", { name: "vm" });
  assert.ok(t.timeouts[0]! > 2 * 75000 + 5000, String(t.timeouts[0]));
});

test("alcove_set_environment waits for one guest recipe per setting after the tools", async () => {
  const t = stateRig({ applied: [] });
  await t.run("alcove_set_environment", { name: "vm", theme: "dark" });
  await t.run("alcove_set_environment", {
    name: "vm", theme: "dark", time_zone: "UTC", clock: "host", locale: "en-US", keyboard_layouts: ["en-US"], dpi_scale: 100,
  });
  assert.ok(t.timeouts[0]! > 25000 + 75000, String(t.timeouts[0]));
  assert.ok(t.timeouts[1]! > 25000 + 6 * 75000, String(t.timeouts[1]));
  assert.ok(t.timeouts[1]! > t.timeouts[0]!);
});

test("alcove_start_vm sends wait_timeout_s as waitTools and waits for a resume, that wait and the clock sync", async () => {
  const t = rig(registerCore, { state: "running", resumed: true, tools: true, clockSynced: true });
  await t.run("alcove_start_vm", { name: "vm", wait_timeout_s: 400 });
  await t.run("alcove_start_vm", { name: "vm" });
  assert.deepEqual(t.calls.map((c) => c.params.waitTools), [400, 180]);
  assert.ok(t.timeouts[0]! > 600000 + 400000 + 75000, String(t.timeouts[0]));
  assert.ok(t.timeouts[1]! > 600000 + 180000 + 75000, String(t.timeouts[1]));
});

test("alcove_ui_type waits for the helper call and three key events per character at the default delay", async () => {
  const t = rig(registerUi, { node: { ref: "e1" } });
  await t.run("alcove_ui_type", { name: "vm", ref: "e1", text: "a".repeat(100000) });
  assert.ok(t.timeouts[0]! > UI_CALL_TIMEOUT_MS + (3 * 100000 + 1) * 12, String(t.timeouts[0]));
});
