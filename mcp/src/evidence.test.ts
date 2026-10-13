import { test } from "node:test";
import assert from "node:assert/strict";
import { register } from "./tools/evidence.js";
import { eventLogText } from "./tools/evidence.js";
import type { ControlClient } from "./control.js";
import type { Registrar, ToolHandler } from "./toolkit.js";

function rig(reply: Record<string, unknown>) {
  const calls: Array<{ op: string; params: Record<string, unknown> }> = [];
  const handlers = new Map<string, ToolHandler>();
  const registrar: Registrar = { tool: (_set, name, _config, handler) => void handlers.set(name, handler) };
  const client = { call: async (op: string, params: Record<string, unknown> = {}) => (calls.push({ op, params }), reply) } as unknown as ControlClient;
  register(registrar, client);
  return { calls, run: (tool: string, args: Record<string, unknown>) => handlers.get(tool)!(args) };
}

test("eventLogText prints a header line and the indented message per entry", () => {
  assert.equal(
    eventLogText([{ time: "2026-01-01T00:00:00Z", level: "error", provider: "Application Error", id: 1000, message: "line one\nline two" }]),
    "2026-01-01T00:00:00Z error Application Error (1000)\n  line one\n  line two",
  );
  assert.equal(eventLogText([]), "no matching entries");
});

test("alcove_crash_dumps refuses enable without exe before calling the control op", async () => {
  const t = rig({});
  const r = await t.run("alcove_crash_dumps", { name: "vm", action: "enable" });
  assert.equal(r.isError, true);
  assert.equal(t.calls.length, 0);
});

test("alcove_event_log maps since_minutes", async () => {
  const t = rig({ entries: [] });
  await t.run("alcove_event_log", { name: "vm", since_minutes: 5, level: "error" });
  assert.deepEqual(t.calls[0], { op: "vm.event_log", params: { name: "vm", level: "error", sinceMinutes: 5 } });
});
