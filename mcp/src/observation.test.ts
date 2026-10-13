import { test } from "node:test";
import assert from "node:assert/strict";
import { z } from "zod";
import { observeParams, renderObservation, actionResult, screenshotCaption, waitForResult, batchResult } from "./observation.js";
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

const textOf = (r: { content: Array<{ type: string; text?: string }> }) => r.content[0].text;

test("observationError renders as a line after the action line without isError", () => {
  const r = actionResult("clicked", { observationError: "the screen could not be read after vm.mouse.click; call vm.screenshot to see the result" });
  assert.equal(textOf(r), "clicked\nscreen not read after the action: the screen could not be read after vm.mouse.click; call vm.screenshot to see the result");
  assert.equal((r as { isError?: boolean }).isError, undefined);
});

test("batch renders observationError and keeps isError for a failed step only", () => {
  const sent = [{ op: "click" }, { op: "type" }];
  const ok = batchResult(sent, { completed: 2, observationError: "gone" });
  assert.equal(textOf(ok), "ok 0 click\nok 1 type\nscreen not read after the action: gone");
  assert.equal((ok as { isError?: boolean }).isError, undefined);
  const bad = batchResult(sent, { completed: 1, failedStep: 1, error: "boom", observationError: "gone" });
  assert.equal(textOf(bad), "ok 0 click\nFAILED 1 type: boom\nscreen not read after the action: gone");
  assert.equal((bad as { isError?: boolean }).isError, true);
});

test("wait_for renders observationError on a match", () => {
  const r = waitForResult({ matched: 0, type: "file_exists", waited: 1.5, observationError: "gone" }, 30);
  assert.equal(textOf(r), "matched condition 0 (file_exists) after 1.5 s\nscreen not read after the action: gone");
});

test("wait_for without a match names the detail", () => {
  const r = waitForResult({ matched: -1, detail: "job exited", waited: 12.3 }, 30);
  assert.equal(textOf(r), "no condition matched: job exited (after 12.3 s)");
});

test("wait_for without a match and without detail names the timeout", () => {
  assert.equal(textOf(waitForResult({ matched: -1, waited: 30 }, 30)), "no condition matched within 30 s");
});

test("wait_for lists the conditions that could not be evaluated", () => {
  const r = waitForResult({
    matched: -1, waited: 30,
    problems: [
      { condition: 0, type: "port_listening", error: "ss is not installed in the guest", failures: 12 },
      { condition: 2, type: "text_visible", error: "text recognition failed", failures: 3 },
    ],
  }, 30);
  assert.equal(textOf(r), [
    "no condition matched within 30 s",
    "condition 0 (port_listening) could not be evaluated: ss is not installed in the guest (12 times in a row)",
    "condition 2 (text_visible) could not be evaluated: text recognition failed (3 times in a row)",
  ].join("\n"));
});

test("wait_for puts the detail and problems before the observation", () => {
  const r = waitForResult({ matched: -1, detail: "job exited", waited: 2, problems: [{ condition: 1, type: "file_exists", error: "x", failures: 2 }], observation: base }, 30);
  assert.equal(textOf(r), "no condition matched: job exited (after 2 s)\ncondition 1 (file_exists) could not be evaluated: x (2 times in a row)\nscreen settled\nnothing changed");
});

test("image line shows the scale with four decimals and the guest area", () => {
  const out = renderObservation({ ...base, png: "QUJD", imageRect: { x: 5, y: 6, w: 1920, h: 1080 }, imageScale: 2 / 3 });
  assert.match((out[0] as { text: string }).text, /image shows guest \(5,6\) 1920x1080 at scale 0\.6667$/);
});

test("screenshot caption gives the scale with four decimals and the guest area", () => {
  const caption = screenshotCaption("Win", { width: 1920, height: 1080, sentWidth: 1280, sentHeight: 720, x: 0, y: 0, scale: 1280 / 1920, areaWidth: 1920, areaHeight: 1080 });
  assert.equal(caption, "Win: guest frame 1920x1080; image 1280x720 shows guest (0,0) 1920x1080 at scale 0.6667; guest = origin + image_pixel / scale");
  const region = screenshotCaption("Win", { width: 1920, height: 1080, sentWidth: 200, sentHeight: 100, x: 40, y: 50, scale: 0.5, areaWidth: 400, areaHeight: 200 });
  assert.match(region, /image 200x100 shows guest \(40,50\) 400x200 at scale 0\.5;/);
});

test("non-string foreground, focused, events and tree render as compact JSON", () => {
  const out = renderObservation({
    ...base,
    foreground: { title: "Notepad", pid: 4 },
    focused: { role: "edit", name: "Body" },
    events: [{ type: "dialog", title: "Save" }],
    tree: { role: "window", children: [{ role: "button" }] },
  });
  assert.equal((out[0] as { text: string }).text, [
    "screen settled", "nothing changed",
    'foreground: {"title":"Notepad","pid":4}',
    'focused: {"role":"edit","name":"Body"}',
    'events: [{"type":"dialog","title":"Save"}]',
    '{"role":"window","children":[{"role":"button"}]}',
  ].join("\n"));
});

test("screenshot caption derives the area from the image size and scale when the area fields are absent", () => {
  const caption = screenshotCaption("Win", { width: 1920, height: 1080, sentWidth: 200, sentHeight: 100, x: 40, y: 50, scale: 0.5 });
  assert.match(caption, /image 200x100 shows guest \(40,50\) 400x200 at scale 0\.5;/);
  assert.doesNotMatch(caption, /undefined|NaN/);
});

test("settle parameters accept the ranges of the control ops", () => {
  const schema = z.object(observeParams);
  assert.ok(schema.safeParse({ settle_timeout_ms: 100 }).success);
  assert.ok(schema.safeParse({ settle_timeout_ms: 30000 }).success);
  assert.ok(!schema.safeParse({ settle_timeout_ms: 99 }).success);
  assert.ok(!schema.safeParse({ settle_timeout_ms: 30001 }).success);
  assert.ok(schema.safeParse({ settle_ms: 0 }).success);
  assert.ok(schema.safeParse({ settle_ms: 10000 }).success);
  assert.ok(!schema.safeParse({ settle_ms: 10001 }).success);
});
