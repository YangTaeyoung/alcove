import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerShell } from "./tools/shell.js";
import { register as registerCore } from "./tools/core.js";
import { register as registerActions } from "./tools/actions.js";
import { rig, textOf } from "./test-rig.js";

test("alcove_exec shows eventSeq after the exit code", async () => {
  const t = rig(registerCore, { code: 0, stdout: "done\n", stderr: "", eventSeq: 12 });
  const r = await t.run("alcove_exec", { name: "vm", command: "build" });
  assert.equal(textOf(r), "exit code 0\neventSeq 12\nstdout:\ndone\n");
  assert.deepEqual(r.structuredContent, { code: 0, stdout: "done\n", stderr: "", output: "", timedOut: false, truncated: false, eventSeq: 12 });
  const silent = await rig(registerCore, { code: 3, eventSeq: 0 }).run("alcove_exec", { name: "vm", command: "x" });
  assert.equal(textOf(silent), "exit code 3\neventSeq 0");
  const older = await rig(registerCore, { code: 0, stdout: "", stderr: "" }).run("alcove_exec", { name: "vm", command: "x" });
  assert.equal(textOf(older), "exit code 0");
  assert.equal((older.structuredContent as Record<string, unknown>).eventSeq, undefined);
});

test("the job and process tools that change the guest show eventSeq", async () => {
  const started = await rig(registerShell, { job: "j1", pid: 44, eventSeq: 7 }).run("alcove_exec_start", { name: "vm", command: "serve" });
  assert.equal(textOf(started), "started job j1 (pid 44)\neventSeq 7");
  assert.deepEqual(started.structuredContent, { job: "j1", pid: 44, eventSeq: 7 });
  const written = await rig(registerShell, { eventSeq: 8 }).run("alcove_exec_write", { name: "vm", job: "j1", data: "yes\n", eof: true });
  assert.equal(textOf(written), "wrote 4 characters and closed stdin\neventSeq 8");
  assert.deepEqual(written.structuredContent, { eventSeq: 8 });
  const killed = await rig(registerShell, { state: "exited", eventSeq: 9 }).run("alcove_exec_kill", { name: "vm", job: "j1" });
  assert.equal(textOf(killed), "job j1: exited\neventSeq 9");
  assert.deepEqual(killed.structuredContent, { eventSeq: 9 });
  const stopped = await rig(registerShell, { killed: 2, eventSeq: 10 }).run("alcove_process_kill", { name: "vm", process_name: "app.exe", tree: true });
  assert.equal(textOf(stopped), "killed 2 process(es)\neventSeq 10");
  assert.deepEqual(stopped.structuredContent, { killed: 2, eventSeq: 10 });
});

test("the job tools print no eventSeq line for a reply without one", async () => {
  const started = await rig(registerShell, { job: "j1", pid: 44 }).run("alcove_exec_start", { name: "vm", command: "serve" });
  assert.equal(textOf(started), "started job j1 (pid 44)");
  assert.deepEqual(started.structuredContent, { job: "j1", pid: 44 });
  const written = await rig(registerShell, {}).run("alcove_exec_write", { name: "vm", job: "j1", data: "y" });
  assert.equal(textOf(written), "wrote 1 characters");
  assert.equal(written.structuredContent, undefined);
});

test("alcove_exec_read asks for at most 60000 bytes per stream and shows all of them with the next offsets", async () => {
  const out = "a".repeat(60000);
  const t = rig(registerShell, { state: "running", pid: 5, out, err: "", outNext: 60000, errNext: 0 });
  const r = await t.run("alcove_exec_read", { name: "vm", job: "j1", out_offset: 0 });
  await t.run("alcove_exec_read", { name: "vm", job: "j1", max: 1000 });
  assert.equal(t.calls[0].params.max, 60000);
  assert.equal(t.calls[1].params.max, 1000);
  assert.equal(textOf(r), `running\nnext offsets: out_offset=60000 err_offset=0\nstdout:\n${out}`);
});

test("alcove_wait_for waits for the observation that follows the wait", async () => {
  const t = rig(registerActions, { matched: -1, waited: 5 });
  await t.run("alcove_wait_for", { name: "vm", conditions: [{ type: "screen_idle" }], timeout_s: 5 });
  await t.run("alcove_wait_for", { name: "vm", conditions: [{ type: "screen_idle" }], timeout_s: 5, observe: "ui", settle_timeout_ms: 30000 });
  await t.run("alcove_wait_for", { name: "vm", conditions: [{ type: "screen_idle" }], observe: "none", settle_timeout_ms: 30000 });
  assert.deepEqual(t.timeouts, [35000, 85000, 60000]);
});
