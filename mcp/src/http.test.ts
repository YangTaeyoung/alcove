import { test } from "node:test";
import assert from "node:assert/strict";
import { register, exchangeLine, exchangeDetail } from "./tools/http.js";
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

const textOf = (r: { content: Array<{ type: string; text?: string }> }) => r.content.map((c) => c.text ?? "").join("\n");

test("exchangeLine prints the documented list format", () => {
  assert.equal(
    exchangeLine({ id: 7, time: "12:00:01.250", kind: "http", method: "GET", url: "https://a.test/x", status: 503, ms: 40, reqBytes: 10, resBytes: 20, rule: 2 }),
    "#7 12:00:01.250 GET https://a.test/x -> 503 (40 ms, 10/20 bytes) [rule 2]",
  );
});

test("exchangeDetail puts headers, a blank line and the body together", () => {
  const out = exchangeDetail(3, "response", { headers: [["content-type", "text/plain"]], body: "hi", total: 2 }, 0);
  assert.equal(out, "#3 response: 2 bytes in total, body from 0\ncontent-type: text/plain\n\nhi");
});

test("exchangeDetail clips a long body with an offset hint", () => {
  const out = exchangeDetail(1, "request", { headers: [], body: "a".repeat(60001), total: 60001 }, 0);
  assert.match(out, /\.\.\.\[truncated; use offset 60000 and length to read further\]$/);
});

test("alcove_http_requests with id reads one exchange part", async () => {
  const t = rig({ headers: [], body: "x", total: 1 });
  await t.run("alcove_http_requests", { name: "vm", id: 4, part: "request", offset: 5, length: 9 });
  assert.deepEqual(t.calls[0], { op: "vm.http.request", params: { name: "vm", id: 4, part: "request", offset: 5, length: 9 } });
});

test("alcove_http_requests shows the pending count when it is not zero", async () => {
  const t = rig({ exchanges: [], next: 0, pending: 2 });
  const r = await t.run("alcove_http_requests", { name: "vm", status: "4xx" });
  assert.equal(t.calls[0].op, "vm.http.requests");
  assert.match(textOf(r), /2 more request\(s\) still in flight/);
});

test("alcove_http_rule add maps response to the rule action", async () => {
  const t = rig({ rule: 1 });
  await t.run("alcove_http_rule", { name: "vm", action: "add", match: { host: "a.test" }, response: { status: 500, delay_ms: 20, times: 1 } });
  assert.deepEqual(t.calls[0].params, { name: "vm", match: { host: "a.test" }, action: { status: 500, times: 1, delayMs: 20 } });
});

test("alcove_http_rule add without a response fails before calling the control op", async () => {
  const t = rig({});
  const r = await t.run("alcove_http_rule", { name: "vm", action: "add", match: { host: "a.test" } });
  assert.equal(r.isError, true);
  assert.equal(t.calls.length, 0);
});
