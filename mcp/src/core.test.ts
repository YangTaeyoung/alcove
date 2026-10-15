import { test } from "node:test";
import assert from "node:assert/strict";
import { register } from "./tools/core.js";
import { rig, textOf } from "./test-rig.js";

test("alcove_start_vm reports a resumed session with the tools and a synced clock", async () => {
  const { run, calls } = rig(register, { state: "running", ephemeral: false, resumed: true, tools: true, clockSynced: true });
  const r = await run("alcove_start_vm", { name: "Win" });
  assert.equal(textOf(r), "Win: running; resumed a suspended session; guest tools reconnected; guest clock synced");
  assert.deepEqual(calls, [{ op: "vm.start", params: { name: "Win", waitTools: 180 } }]);
});

test("alcove_start_vm names alcove_set_environment when a resumed session has an unsynced clock", async () => {
  const { run } = rig(register, { state: "running", resumed: true, tools: true, clockSynced: false });
  assert.equal(
    textOf(await run("alcove_start_vm", { name: "Win" })),
    "Win: running; resumed a suspended session; guest tools reconnected; guest clock not synced; call alcove_set_environment with clock \"host\"",
  );
});

test("alcove_start_vm names alcove_vm_status first when a resumed session has no tools", async () => {
  const { run } = rig(register, { state: "running", resumed: true, tools: false, clockSynced: false });
  assert.equal(
    textOf(await run("alcove_start_vm", { name: "Win" })),
    "Win: running; resumed a suspended session; guest tools did not reconnect in time; guest clock not synced; " +
      "call alcove_vm_status until the tools are connected, then alcove_set_environment with clock \"host\"",
  );
});

test("alcove_start_vm of a session that was not resumed has no resume text", async () => {
  const { run } = rig(register, { state: "running", ephemeral: false, tools: true });
  assert.equal(textOf(await run("alcove_start_vm", { name: "Win" })), "Win: running; guest tools connected (desktop ready)");
});

test("alcove_start_vm sends waitTools 0 when wait_for_tools is false", async () => {
  const { run, calls } = rig(register, { state: "running", resumed: true, tools: false, clockSynced: false });
  await run("alcove_start_vm", { name: "Win", wait_for_tools: false });
  assert.deepEqual(calls, [{ op: "vm.start", params: { name: "Win", waitTools: 0 } }]);
});

test("alcove_start_vm stops waiting and prints the sentence when the guest tools refuse the host", async () => {
  const sentence = "this alcove-agent serves nothing because the VM's SMBIOS strings lack alcove-hostkey or alcove-token; start the VM with Alcove 0.2 or later";
  const { run, calls } = rig(register, { state: "running", ephemeral: false, tools: false, toolsRefused: sentence });
  const r = await run("alcove_start_vm", { name: "Win", wait_timeout_s: 1 });
  assert.equal(textOf(r), `Win: running; guest tools refused the connection: ${sentence}`);
  assert.deepEqual(calls.map((c) => c.op), ["vm.start", "vm.status"]);
});
