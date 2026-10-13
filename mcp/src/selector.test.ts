import { test } from "node:test";
import assert from "node:assert/strict";
import { toControlSelector, toolSelector } from "./selector.js";
import { ControlError } from "./control.js";

test("selector fields map to camelCase control fields", () => {
  assert.deepEqual(
    toControlSelector({ window: "Notepad", role: "Button", name: "OK", name_contains: "O", automation_id: "btnOk", index: 1 }),
    { window: "Notepad", role: "Button", name: "OK", nameContains: "O", automationId: "btnOk", index: 1 },
  );
});

test("a ref alone is accepted", () => {
  assert.deepEqual(toControlSelector({ ref: "e7" }), { ref: "e7" });
});

test("a call with only window and index is refused", () => {
  assert.throws(() => toControlSelector({ window: "foreground", index: 0 }), (e: Error) =>
    e instanceof ControlError && e.message === "pass ref or at least one of role, name, name_contains, automation_id");
});

test("an empty call is refused", () => {
  assert.throws(() => toControlSelector({}), ControlError);
});

test("each single selector field is accepted", () => {
  for (const a of [{ role: "Edit" }, { name: "x" }, { name_contains: "x" }, { automation_id: "a" }]) {
    assert.doesNotThrow(() => toControlSelector(a));
  }
});

test("toolSelector keeps ref at top level and nests the other fields with element_name as name", () => {
  assert.deepEqual(toolSelector({ ref: "e2" }), { ref: "e2" });
  assert.deepEqual(toolSelector({ role: "Edit", element_name: "Search", automation_id: "q" }), { selector: { role: "Edit", name: "Search", automationId: "q" } });
});
