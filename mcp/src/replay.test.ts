import { test } from "node:test";
import assert from "node:assert/strict";
import { register, isSecretName, runLines, maskSecrets } from "./tools/replay.js";
import { CALL_MARGIN_MS, SCRIPT_RUN_TIMEOUT_MS, SCRIPT_STEPS_BUDGET_MS, SNAPSHOT_RESTORE_MS, SCREENSHOT_CALL_MS } from "./toolkit.js";
import { ControlError } from "./control.js";
import type { ToolHandler } from "./toolkit.js";
import { rig, textOf } from "./test-rig.js";

const step = (n: number, extra: Record<string, unknown> = {}) => ({ step: n, op: "vm.ui.click", seconds: 0.25, ok: true, ...extra });

test("alcove_script_save sends its parameters under the control op's names", async () => {
  const t = rig(register, { path: "/s/a.json", steps: 3, skipped: 0 });
  await t.run("alcove_script_save", { dir: "/rec", path: "/s/a.json", name: "Win", from: 2, to: 9, overwrite: true });
  assert.deepEqual(t.calls[0], { op: "script.save", params: { dir: "/rec", path: "/s/a.json", name: "Win", from: 2, to: 9, overwrite: true } });
  const only = rig(register, { path: "/s/a.json", steps: 1, skipped: 0 });
  await only.run("alcove_script_save", { trace: "/rec/trace.jsonl", path: "/s/a.json" });
  assert.deepEqual(only.calls[0].params, { trace: "/rec/trace.jsonl", path: "/s/a.json" });
});

test("alcove_script_save prints the path, the steps, the skipped lines and each warning", async () => {
  const t = rig(register, { path: "/s/a.json", steps: 1, skipped: 2, warnings: ["first warning", "second warning"] });
  const r = await t.run("alcove_script_save", { dir: "/rec", path: "/s/a.json" });
  assert.equal(textOf(r), "saved /s/a.json\n1 step\nskipped 2 trace lines\nwarning: first warning\nwarning: second warning");
  assert.deepEqual(r.structuredContent, { path: "/s/a.json", steps: 1, skipped: 2, warnings: ["first warning", "second warning"] });
  const quiet = rig(register, { path: "/s/a.json", steps: 4, skipped: 0 });
  assert.equal(textOf(await quiet.run("alcove_script_save", { dir: "/rec", path: "/s/a.json" })), "saved /s/a.json\n4 steps");
});

test("alcove_script_run sends path, variables, snapshot and name", async () => {
  const t = rig(register, { passed: true, stepsRun: 1, seconds: 1, steps: [step(1)] });
  await t.run("alcove_script_run", { path: "/s/a.json", variables: { message: "hi" }, snapshot: "clean", name: "Win" });
  assert.deepEqual(t.calls[0], { op: "script.run", params: { path: "/s/a.json", name: "Win", variables: { message: "hi" }, snapshot: "clean", maxWidth: 1280 } });
  const bare = rig(register, { passed: true, stepsRun: 1, seconds: 1, steps: [step(1)] });
  await bare.run("alcove_script_run", { path: "/s/a.json" });
  assert.deepEqual(bare.calls[0].params, { path: "/s/a.json", maxWidth: 1280 });
});

test("a passed run prints one line per step with its markers and a PASSED line", async () => {
  const t = rig(register, { passed: true, stepsRun: 2, seconds: 1.5, steps: [step(1, { label: "open", seconds: 0.34, usedFallback: true, usedAltSelector: true }), step(2, { positional: true })] });
  const r = await t.run("alcove_script_run", { path: "/s/a.json" });
  assert.equal(textOf(r), "ok   1 open 340 ms [fallback] [alt selector]\nok   2 vm.ui.click 250 ms [positional]\nPASSED: 2 steps in 1.5 s");
  assert.equal(r.isError, undefined);
  assert.equal(r.content.length, 1);
  assert.equal(r.structuredContent?.passed, true);
});

test("a failed run prints the error and the warning and returns the failure screenshot as an image", async () => {
  const t = rig(register, {
    passed: false, stepsRun: 2, failedStep: 2, seconds: 3, label: "send",
    error: "step 2 (send) failed: no element matches", warning: "the lease on 'Win' could not be released",
    steps: [step(1, { label: "open" }), step(2, { label: "send", ok: false, seconds: 2, error: "no element matches" })],
    failure: { png: "QUJD", width: 800, height: 600 },
  });
  const r = await t.run("alcove_script_run", { path: "/s/a.json" });
  assert.deepEqual(r.content[0], { type: "text", text: [
    "ok   1 open 250 ms",
    "FAIL 2 send 2000 ms",
    "     no element matches",
    "error: step 2 (send) failed: no element matches",
    "warning: the lease on 'Win' could not be released",
    "FAILED: step 2 failed after 3.0 s",
  ].join("\n") });
  assert.deepEqual(r.content[1], { type: "image", data: "QUJD", mimeType: "image/png" });
  assert.deepEqual(r.structuredContent?.failure, { width: 800, height: 600 });
  assert.equal(r.structuredContent?.failedStep, 2);
});

test("variables with secret names are printed as <hidden> and their values are removed from the output", async () => {
  const t = rig(register, {
    passed: false, stepsRun: 1, failedStep: 1, seconds: 1, error: "step 1 (type hunter2-long) failed: typed hunter2-long",
    steps: [step(1, { label: "type hunter2-long", ok: false, error: "typed hunter2-long", result: { text: "hunter2-long" } })],
  });
  const r = await t.run("alcove_script_run", { path: "/s/a.json", variables: { message: "hello", password: "hunter2-long" } });
  assert.equal(textOf(r).split("\n")[0], "variables: message=hello, password=<hidden>");
  assert.doesNotMatch(textOf(r), /hunter2-long/);
  assert.doesNotMatch(JSON.stringify(r.structuredContent), /hunter2-long/);
  assert.match(textOf(r), /typed <hidden>/);
  assert.deepEqual(t.calls[0].params.variables, { message: "hello", password: "hunter2-long" });
});

test("secret variable names", () => {
  for (const n of ["password", "password2", "apiKey", "API_TOKEN", "clientSecret"]) assert.equal(isSecretName(n), true, n);
  for (const n of ["message", "user"]) assert.equal(isSecretName(n), false, n);
});

test("a run that stopped without a failed step says so", () => {
  assert.deepEqual(runLines({ passed: false, stepsRun: 0, seconds: 0, steps: [], error: "x" }, {}), ["error: x", "FAILED: the run stopped after 0.0 s"]);
});

test("a control error is returned as a tool error", async () => {
  const client = { call: async () => { throw new ControlError("cannot read the script '/x'; check that it is a file on the host and use an absolute path"); } };
  const handlers = new Map<string, ToolHandler>();
  register({ tool: (_set, name, _config, handler) => { handlers.set(name, handler); } }, client as never);
  const r = await handlers.get("alcove_script_run")!({ path: "/x" });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "cannot read the script '/x'; check that it is a file on the host and use an absolute path");
});

test("alcove_script_run waits for the snapshot restore, two hours of steps, the failure screenshot and the margin", async () => {
  assert.deepEqual([SNAPSHOT_RESTORE_MS, SCRIPT_STEPS_BUDGET_MS, SCREENSHOT_CALL_MS, CALL_MARGIN_MS], [660000, 7200000, 60000, 5000]);
  assert.equal(SCRIPT_RUN_TIMEOUT_MS, 660000 + 7200000 + 60000 + 5000);
  const run = rig(register, { passed: true, stepsRun: 1, seconds: 1, steps: [step(1)] });
  await run.run("alcove_script_run", { path: "/s/a.json" });
  const save = rig(register, { path: "/s/a.json", steps: 1, skipped: 0 });
  await save.run("alcove_script_save", { dir: "/rec", path: "/s/a.json" });
  assert.deepEqual([run.timeouts[0], save.timeouts[0]], [7925000, 120000]);
});

test("the replay tools are described for the model", () => {
  const t = rig(register);
  const save = t.descriptions.get("alcove_script_save") ?? "";
  const run = t.descriptions.get("alcove_script_run") ?? "";
  for (const phrase of ["dir", "trace", "coordinates kept as a fallback", "whatever is at that position", "never stored", "variables"]) assert.ok(save.includes(phrase), phrase);
  for (const phrase of ["whatever is at that position", "variables", "restores that snapshot", "mouse and keyboard"]) assert.ok(run.includes(phrase), phrase);
});

test("short secret values hide only whole strings and never break the structured result", async () => {
  const t = rig(register, {
    passed: false, stepsRun: 1, failedStep: 1, seconds: 1, error: "step 1 failed: 1 of 11",
    steps: [step(1, { label: "1", ok: false, error: "1", result: { count: 1, flag: true, text: "11" } })],
  });
  const r = await t.run("alcove_script_run", { path: "/s/a.json", variables: { pin_key: "1", other_token: "true" } });
  assert.notEqual(r.isError, true);
  assert.equal(textOf(r), [
    "variables: other_token=<hidden>, pin_key=<hidden>",
    "FAIL 1 <hidden> 250 ms",
    "     <hidden>",
    "error: step 1 failed: 1 of 11",
    "FAILED: step 1 failed after 1.0 s",
  ].join("\n"));
  const steps = r.structuredContent?.steps as Array<Record<string, unknown>>;
  assert.deepEqual(steps[0].result, { count: 1, flag: true, text: "11" });
  assert.equal(steps[0].step, 1);
});

test("a secret of eight characters or more is hidden inside longer strings and inside the structured result", async () => {
  const t = rig(register, {
    passed: false, stepsRun: 1, failedStep: 1, seconds: 1, error: "step 1 failed: typed S3cret-value",
    steps: [step(1, { ok: false, error: "typed S3cret-value", result: { nested: ["S3cret-value", "x S3cret-value y"] } })],
  });
  const r = await t.run("alcove_script_run", { path: "/s/a.json", variables: { password: "S3cret-value" } });
  assert.doesNotMatch(textOf(r), /S3cret/);
  assert.doesNotMatch(JSON.stringify(r.structuredContent), /S3cret/);
  assert.deepEqual((r.structuredContent?.steps as Array<Record<string, unknown>>)[0].result, { nested: ["<hidden>", "x <hidden> y"] });
  assert.equal(maskSecrets("a S3cret-value b", { password: "S3cret-value" }), "a <hidden> b");
});

test("a control error sentence is returned with secret values hidden", async () => {
  const client = { call: async () => { throw new ControlError("cannot use S3cret-value here"); } };
  const handlers = new Map<string, ToolHandler>();
  register({ tool: (_set, name, _config, handler) => { handlers.set(name, handler); } }, client as never);
  const r = await handlers.get("alcove_script_run")!({ path: "/x", variables: { password: "S3cret-value" } });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "cannot use <hidden> here");
});

test("a client timeout says that the run may still be going in the guest", async () => {
  const client = { call: async () => { throw new ControlError("script.run timed out after 7925s"); } };
  const handlers = new Map<string, ToolHandler>();
  register({ tool: (_set, name, _config, handler) => { handlers.set(name, handler); } }, client as never);
  const r = await handlers.get("alcove_script_run")!({ path: "/x" });
  assert.equal(r.isError, true);
  assert.equal(
    textOf(r),
    "script.run timed out after 7925s. The run may still be going in the guest and holding the VM's lease; look with alcove_vm_status or alcove_screenshot, wait for it to end, then run the script again.",
  );
});
