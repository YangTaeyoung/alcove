import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerActions } from "./tools/actions.js";
import { rig } from "./test-rig.js";

test("alcove_wait_for describes the ui condition types", () => {
  const t = rig(registerActions);
  const d = t.descriptions.get("alcove_wait_for")!;
  for (const type of ["ui_exists", "ui_gone", "ui_enabled", "ui_text_stable", "window_title", "event {event, title_contains, since}", "quiet_ms",
    "pass the `eventSeq` of an action result as `since`", "the `seq` of a matched event"]) {
    assert.ok(d.includes(type), type);
  }
});

test("a ui_text_stable condition reaches the control op with quietMs and flat selector fields", async () => {
  const t = rig(registerActions, { matched: -1, waited: 1 });
  await t.run("alcove_wait_for", { name: "W", conditions: [{ type: "ui_text_stable", role: "Document", name_contains: "Log", quiet_ms: 2000 }], timeout_s: 5 });
  assert.deepEqual(t.calls[0].params.conditions, [{ type: "ui_text_stable", role: "Document", nameContains: "Log", quietMs: 2000 }]);
});

test("an event condition reaches the control op with since and titleContains", async () => {
  const t = rig(registerActions, { matched: 0, type: "event", waited: 0.2, detail: { seq: 9, name: "dialog.opened", window: { title: "Save" } } });
  const r = await t.run("alcove_wait_for", { name: "W", conditions: [{ type: "event", event: "dialog.opened", title_contains: "Save", since: 7 }] });
  assert.deepEqual(t.calls[0].params.conditions, [{ type: "event", event: "dialog.opened", titleContains: "Save", since: 7 }]);
  assert.match((r.content[0] as { text: string }).text, /^matched condition 0 \(event\) after 0.2 s: .*"seq":9/);
});
