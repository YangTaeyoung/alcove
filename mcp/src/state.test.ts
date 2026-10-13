import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerState } from "./tools/state.js";
import { ControlError } from "./control.js";
import { LeaseBook, type LeasedControlClient } from "./leases.js";
import type { Registrar, ToolHandler, ToolResult } from "./toolkit.js";

type Call = { op: string; params: Record<string, unknown> };

/** The state tools over a client that answers every call with `reply`, or throws it when it is an Error. */
function rig(reply: Record<string, unknown> | Error = {}) {
  const calls: Call[] = [];
  const leases = new LeaseBook();
  const handlers = new Map<string, ToolHandler>();
  const registrar: Registrar = { tool: (_set, name, _config, handler) => void handlers.set(name, handler) };
  const client = {
    leases,
    call: async (op: string, params: Record<string, unknown> = {}) => {
      calls.push({ op, params });
      if (reply instanceof Error) throw reply;
      return reply;
    },
  } as unknown as LeasedControlClient;
  registerState(registrar, client);
  return { calls, leases, run: (tool: string, args: Record<string, unknown>): Promise<ToolResult> => handlers.get(tool)!(args) };
}

const textOf = (r: ToolResult) => r.content.map((c) => (c.type === "text" ? c.text : "")).join("\n");

test("alcove_snapshot_restore reports a synced clock when clockSynced is true", async () => {
  const { run } = rig({ snapshot: "s", tools: true, clockSynced: true });
  const r = await run("alcove_snapshot_restore", { name: "Win", snapshot: "s" });
  assert.equal(textOf(r), "restored 'Win' to snapshot 's'; guest tools reconnected; guest clock synced");
  assert.notEqual(r.isError, true);
});

test("alcove_snapshot_restore reports an unsynced clock when the tools reconnected and clockSynced is false", async () => {
  const { run } = rig({ snapshot: "s", tools: true, clockSynced: false });
  const r = await run("alcove_snapshot_restore", { name: "Win", snapshot: "s" });
  assert.equal(
    textOf(r),
    "restored 'Win' to snapshot 's'; guest tools reconnected; guest clock not synced; call alcove_set_environment with clock \"host\"",
  );
});

test("alcove_snapshot_restore reports an unsynced clock when the reply has no clockSynced", async () => {
  const { run } = rig({ snapshot: "s", tools: true });
  assert.match(textOf(await run("alcove_snapshot_restore", { name: "Win", snapshot: "s" })), /guest tools reconnected; guest clock not synced/);
});

test("alcove_snapshot_restore reports missing tools and an unsynced clock", async () => {
  const { run } = rig({ snapshot: "s", tools: false, clockSynced: false });
  const r = await run("alcove_snapshot_restore", { name: "Win", snapshot: "s" });
  assert.equal(
    textOf(r),
    "restored 'Win' to snapshot 's'; guest tools did not reconnect in time; guest clock not synced; " +
      "call alcove_vm_status until the tools are connected, then alcove_set_environment with clock \"host\"",
  );
});

test("alcove_snapshot_restore sends waitTools only when wait_tools_s is given", async () => {
  const { run, calls } = rig({ tools: true, clockSynced: true });
  await run("alcove_snapshot_restore", { name: "Win", snapshot: "s" });
  await run("alcove_snapshot_restore", { name: "Win", snapshot: "s", wait_tools_s: 5 });
  assert.deepEqual(calls.map((c) => c.params), [{ name: "Win", snapshot: "s" }, { name: "Win", snapshot: "s", waitTools: 5 }]);
});

test("alcove_set_environment is an error result when a row has ok false", async () => {
  const applied = [
    { setting: "timeZone", ok: false, detail: "The specified time zone ID was not found", takesEffect: "now" },
    { setting: "theme", ok: true, detail: "theme: dark", takesEffect: "now" },
  ];
  const { run } = rig({ applied });
  const r = await run("alcove_set_environment", { name: "Win", theme: "dark", time_zone: "Nowhere" });
  assert.equal(r.isError, true);
  assert.equal(
    textOf(r),
    "timeZone: FAILED — The specified time zone ID was not found (takes effect: now)\ntheme: ok — theme: dark (takes effect: now)",
  );
  assert.deepEqual(r.structuredContent, { applied });
});

test("alcove_set_environment is not an error result when every row has ok true", async () => {
  const applied = [{ setting: "dpiScale", ok: true, detail: "scale: 125 %", takesEffect: "now" }];
  const { run } = rig({ applied });
  const r = await run("alcove_set_environment", { name: "Win", dpi_scale: 125 });
  assert.notEqual(r.isError, true);
  assert.equal(textOf(r), "dpiScale: ok — scale: 125 % (takes effect: now)");
  assert.deepEqual(r.structuredContent, { applied });
});

test("alcove_lease_acquire stores the token and alcove_lease_release sends and clears it", async () => {
  const { run, leases, calls } = rig({ lease: "tok-1", expiresIn: 300 });
  await run("alcove_lease_acquire", { name: "Win" });
  assert.equal(leases.get("Win"), "tok-1");
  const r = await run("alcove_lease_release", { name: "Win" });
  assert.notEqual(r.isError, true);
  assert.deepEqual(calls[calls.length - 1], { op: "vm.lease.release", params: { name: "Win", lease: "tok-1" } });
  assert.equal(leases.get("Win"), undefined);
});

test("alcove_lease_release clears the stored token when the VM does not exist", async () => {
  const { run, leases } = rig(new ControlError("no VM named 'Win'; call vm.list"));
  leases.set("Win", "tok-1");
  const r = await run("alcove_lease_release", { name: "Win" });
  assert.equal(r.isError, true);
  assert.equal(textOf(r), "no VM named 'Win'; call vm.list");
  assert.equal(leases.get("Win"), undefined);
});

test("alcove_lease_release clears the stored token when the lease is lost", async () => {
  const { run, leases } = rig(new ControlError("lease token does not match; only the holder can release 'Win'"));
  leases.set("Win", "tok-1");
  const r = await run("alcove_lease_release", { name: "Win" });
  assert.equal(r.isError, true);
  assert.equal(leases.get("Win"), undefined);
});

test("alcove_lease_release keeps the stored token when the release times out or the connection closes", async () => {
  for (const message of ["vm.lease.release timed out after 120s", "control connection closed"]) {
    const { run, leases } = rig(new ControlError(message));
    leases.set("Win", "tok-1");
    const r = await run("alcove_lease_release", { name: "Win" });
    assert.equal(r.isError, true);
    assert.equal(leases.get("Win"), "tok-1");
  }
});

test("alcove_lease_release without a stored token names alcove_lease_acquire and sends nothing", async () => {
  const { run, calls } = rig();
  const r = await run("alcove_lease_release", { name: "Win" });
  assert.equal(r.isError, true);
  assert.match(textOf(r), /holds no lease on 'Win'; call alcove_lease_acquire first/);
  assert.equal(calls.length, 0);
});
