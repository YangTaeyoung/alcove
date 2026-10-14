import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerCore } from "./tools/core.js";
import { register as registerActions } from "./tools/actions.js";
import { register as registerShell } from "./tools/shell.js";
import { observePayload } from "./observation.js";
import { rig, textOf } from "./test-rig.js";

test("alcove_exec_start offers no stdin and alcove_exec does", () => {
  assert.equal("stdin" in rig(registerShell).schemas.get("alcove_exec_start")!, false);
  assert.equal("stdin" in rig(registerCore).schemas.get("alcove_exec")!, true);
});

test("alcove_exec_start never sends stdin", async () => {
  const t = rig(registerShell, { job: "j1", pid: 3 });
  await t.run("alcove_exec_start", { name: "vm", command: "serve", stdin: "x" });
  assert.deepEqual(t.calls[0].params, { name: "vm", command: "serve" });
});

test("alcove_exec sends stdin", async () => {
  const t = rig(registerCore, { code: 0 });
  await t.run("alcove_exec", { name: "vm", command: "more", stdin: "x" });
  assert.equal(t.calls[0].params.stdin, "x");
});

test("alcove_screenshot refuses region together with window and sends nothing", async () => {
  const t = rig(registerCore, {});
  const r = await t.run("alcove_screenshot", { name: "vm", region: { x: 0, y: 0, w: 5, h: 5 }, window: "foreground" });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "pass region or window, not both");
  assert.equal(t.calls.length, 0);
});

test("alcove_mouse_down and alcove_mouse_up refuse x without y and y without x", async () => {
  const t = rig(registerActions, {});
  for (const tool of ["alcove_mouse_down", "alcove_mouse_up"]) {
    for (const point of [{ x: 1 }, { y: 1 }]) {
      const r = await t.run(tool, { name: "vm", ...point });
      assert.equal(r.isError, true);
      assert.equal(textOf(r), "pass x and y together, or neither");
    }
  }
  assert.equal(t.calls.length, 0);
});

test("a settle timeout below the default settle time sends a settle time equal to it", () => {
  assert.deepEqual(observePayload({ settle_timeout_ms: 200 }, "summary"), { observe: "summary", settleMs: 200, settleTimeoutMs: 200 });
  assert.deepEqual(observePayload({ settle_timeout_ms: 300 }, "summary"), { observe: "summary", settleTimeoutMs: 300 });
  assert.deepEqual(observePayload({ settle_ms: 50, settle_timeout_ms: 200 }, "none"), { observe: "none", settleMs: 50, settleTimeoutMs: 200 });
});

test("a settle time above the settle timeout is refused with the tool's parameter names", async () => {
  assert.throws(() => observePayload({ settle_ms: 500, settle_timeout_ms: 200 }, "summary"),
    (e: Error) => e.message === "settle_ms (500) must not exceed settle_timeout_ms (200); lower settle_ms or raise settle_timeout_ms");
  const t = rig(registerCore, {});
  const r = await t.run("alcove_click", { name: "vm", x: 1, y: 2, settle_ms: 500, settle_timeout_ms: 200 });
  assert.equal(r.isError, true);
  assert.equal(t.calls.length, 0);
});
