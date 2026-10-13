import { test } from "node:test";
import assert from "node:assert/strict";
import { renderObservation, actionResult } from "./observation.js";
import { camelKeys, mapBatchStep } from "./tools/actions.js";

const base = { settled: true, changedFraction: 0, width: 1920, height: 1080 };

test("settled observation with no change", () => {
  const out = renderObservation(base);
  assert.equal(out.length, 1);
  assert.deepEqual(out[0], { type: "text", text: "screen settled\nnothing changed" });
});

test("unsettled observation names the wait", () => {
  const out = renderObservation({ ...base, settled: false, changedFraction: 1 }, 2500);
  assert.equal(out[0].type, "text");
  assert.match((out[0] as { text: string }).text, /^screen still changing after 2500 ms/);
});

test("changed rectangle and percentage", () => {
  const out = renderObservation({ ...base, changed: { x: 10, y: 20, w: 300, h: 40 }, changedFraction: 0.0123 });
  assert.equal((out[0] as { text: string }).text, "screen settled\nchanged (10,20) 300x40 = 1.2% of the frame");
});

test("png yields one image content and a mapping line", () => {
  const out = renderObservation({ ...base, png: "QUJD", imageRect: { x: 0, y: 0, w: 1920, h: 1080 }, imageScale: 0.5 });
  assert.equal(out.length, 2);
  assert.match((out[0] as { text: string }).text, /image shows guest \(0,0\) 1920x1080 at scale 0.5/);
  assert.deepEqual(out[1], { type: "image", data: "QUJD", mimeType: "image/png" });
});

test("optional foreground, focused, events and tree lines", () => {
  const out = renderObservation({ ...base, foreground: "Notepad", focused: "Edit", events: "dialog opened", tree: "window\n  button" });
  assert.equal((out[0] as { text: string }).text, "screen settled\nnothing changed\nforeground: Notepad\nfocused: Edit\nevents: dialog opened\nwindow\n  button");
});

test("undefined observation yields no content", () => {
  assert.deepEqual(renderObservation(undefined), []);
});

test("actionResult joins the action line with the observation text", () => {
  const r = actionResult("clicked", { observation: base });
  assert.deepEqual(r.content, [{ type: "text", text: "clicked\nscreen settled\nnothing changed" }]);
  assert.deepEqual(actionResult("clicked", {}).content, [{ type: "text", text: "clicked" }]);
});

test("camelKeys converts nested snake_case keys", () => {
  assert.deepEqual(
    camelKeys({ type: "process_started", process_name: "a_b", region: { x: 1 }, list: [{ some_key: 1 }] }),
    { type: "process_started", processName: "a_b", region: { x: 1 }, list: [{ someKey: 1 }] },
  );
});

test("batch step mapping", () => {
  assert.deepEqual(mapBatchStep({ op: "click", x: 1, y: 2 }, 0), { op: "vm.mouse.click", x: 1, y: 2 });
  assert.deepEqual(mapBatchStep({ op: "press_keys", keys: "enter", hold_ms: 5 }, 0), { op: "vm.key.press", keys: "enter", hold: 5 });
  assert.deepEqual(mapBatchStep({ op: "drag", from_x: 1, from_y: 2, to_x: 3, to_y: 4 }, 0), { op: "vm.mouse.drag", fromX: 1, fromY: 2, toX: 3, toY: 4 });
  assert.deepEqual(mapBatchStep({ op: "type", text: "a", delay_ms: 3 }, 0), { op: "vm.type", text: "a", delay: 3 });
  assert.deepEqual(mapBatchStep({ op: "sleep", ms: 100 }, 0), { op: "sleep", ms: 100 });
  assert.deepEqual(mapBatchStep({ op: "wait_idle", seconds: 1, timeout_s: 5 }, 0), { op: "vm.wait_idle", seconds: 1, timeout: 5 });
  assert.deepEqual(
    mapBatchStep({ op: "wait_for", conditions: [{ type: "process_started", process_name: "x" }], timeout_s: 9 }, 0),
    { op: "vm.wait_for", conditions: [{ type: "process_started", processName: "x" }], timeout: 9 },
  );
});

test("unknown batch op throws naming the valid ones", () => {
  assert.throws(() => mapBatchStep({ op: "teleport" }, 3), /step 3: unknown op 'teleport'.*click.*press_keys.*sleep/);
});
