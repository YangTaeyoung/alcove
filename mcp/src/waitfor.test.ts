import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerActions } from "./tools/actions.js";
import { register as registerCore } from "./tools/core.js";
import { rig } from "./test-rig.js";

test("alcove_wait_for describes the ui condition types", () => {
  const t = rig(registerActions);
  const d = t.descriptions.get("alcove_wait_for")!;
  for (const type of ["ui_exists", "ui_gone", "ui_enabled", "ui_text_stable", "window_title", "event {event, title_contains}", "quiet_ms"]) {
    assert.ok(d.includes(type), type);
  }
});

test("a ui_text_stable condition reaches the control op with quietMs and flat selector fields", async () => {
  const t = rig(registerActions, { matched: -1, waited: 1 });
  await t.run("alcove_wait_for", { name: "W", conditions: [{ type: "ui_text_stable", role: "Document", name_contains: "Log", quiet_ms: 2000 }], timeout_s: 5 });
  assert.deepEqual(t.calls[0].params.conditions, [{ type: "ui_text_stable", role: "Document", nameContains: "Log", quietMs: 2000 }]);
});

test("alcove_screenshot sends window and marks and lists the marked elements", async () => {
  const reply = { width: 100, height: 100, sentWidth: 100, sentHeight: 100, scale: 1, png: "QUJD", marks: [{ n: 1, ref: "e4", role: "Button", name: "OK", x: 1, y: 2, w: 3, h: 4 }] };
  const t = rig(registerCore, reply);
  const r = await t.run("alcove_screenshot", { name: "W", window: "Notepad", marks: true });
  assert.equal(t.calls[0].params.window, "Notepad");
  assert.equal(t.calls[0].params.marks, true);
  assert.match((r.content[0] as { text: string }).text, /\n1: e4 Button "OK" \(1,2 3x4\)$/);
});
