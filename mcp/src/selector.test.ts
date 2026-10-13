import { test } from "node:test";
import assert from "node:assert/strict";
import { toSelector } from "./selector.js";
import { ControlError } from "./control.js";

test("selector fields map to a nested camelCase selector", () => {
  assert.deepEqual(
    toSelector({ window: "Notepad", role: "Button", element_name: "OK", name_contains: "O", automation_id: "btnOk", index: 1 }),
    { selector: { window: "Notepad", role: "Button", name: "OK", nameContains: "O", automationId: "btnOk", index: 1 } },
  );
});

test("a ref alone is accepted and sent without a selector", () => {
  assert.deepEqual(toSelector({ ref: "e7" }), { ref: "e7" });
});

test("a ref wins over the other selector fields", () => {
  assert.deepEqual(toSelector({ ref: "e7", role: "Edit", window: "W", index: 2 }), { ref: "e7" });
});

test("a call with only window and index is refused with the next step", () => {
  assert.throws(() => toSelector({ window: "foreground", index: 0 }), (e: Error) =>
    e instanceof ControlError && e.message === "pass ref or at least one of role, element_name, name_contains, automation_id");
});

test("an empty call is refused", () => {
  assert.throws(() => toSelector({}), ControlError);
});

test("each single selector field is accepted", () => {
  for (const a of [{ role: "Edit" }, { element_name: "x" }, { name_contains: "x" }, { automation_id: "a" }]) {
    assert.doesNotThrow(() => toSelector(a));
  }
});
