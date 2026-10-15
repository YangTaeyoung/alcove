import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { register, exchangeLine, exchangeDetail, pendingLine, START_WORST_MS, STOP_WORST_MS, CAPTURE_MARGIN_MS } from "./tools/http.js";
import { ControlClient } from "./control.js";
import { rig, textOf } from "./test-rig.js";
import type { Registrar, ToolHandler } from "./toolkit.js";

/** A control server on a unix socket in a new temporary folder; it records every request line and answers it with `reply` under the line's own id. */
async function controlServer(reply: Record<string, unknown>) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alcove-mcp-"));
  const socketPath = path.join(dir, "control.sock");
  const lines: Array<Record<string, unknown>> = [];
  const server = net.createServer((sock) => {
    let buffer = "";
    sock.setEncoding("utf8");
    sock.on("data", (chunk: string) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, nl));
        buffer = buffer.slice(nl + 1);
        lines.push(request);
        sock.write(JSON.stringify({ ...reply, ok: true, id: request.id }) + "\n");
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  const close = () => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); };
  return { socketPath, lines, close };
}

test("exchangeLine prints the documented list format", () => {
  assert.equal(
    exchangeLine({ id: 7, time: "12:00:01.250", kind: "http", method: "GET", url: "https://a.test/x", status: 503, ms: 40, reqBytes: 10, resBytes: 20, rule: 2 }),
    "#7 12:00:01.250 GET https://a.test/x -> 503 (40 ms, 10/20 bytes) [rule 2]",
  );
});

test("exchangeDetail puts headers, a blank line and the body together", () => {
  const out = exchangeDetail(3, "response", { headers: [["content-type", "text/plain"]], body: "hi", total: 2 }, 0);
  assert.equal(out, "#3 response: 2 bytes in total, body from byte 0\ncontent-type: text/plain\n\nhi");
});

test("exchangeDetail hints the next byte offset of clipped text from its UTF-8 length", () => {
  const body = "\u00e9".repeat(60001);
  const out = exchangeDetail(1, "request", { headers: [], body, total: 200000 }, 10);
  assert.match(out, /\.\.\.\[truncated; offsets count bytes; use offset 120010 to read further\]$/);
});

test("exchangeDetail hints 45000-byte pages for a clipped base64 body", () => {
  const out = exchangeDetail(1, "response", { headers: [], body: "A".repeat(80000), base64: true, total: 60000 }, 5);
  assert.match(out, /use offset 45005 and length 45000 to read further\]$/);
});

test("exchangeDetail counts the bytes of the returned body for the next offset when more remains", () => {
  const out = exchangeDetail(1, "response", { headers: [], body: "ab\u00e9", length: 99, total: 10 }, 2);
  assert.match(out, /\n\nab\u00e9\n\.\.\.\[more; offsets count bytes; use offset 6 to read further\]$/);
  const binary = exchangeDetail(1, "response", { headers: [], body: "AAECAw==", base64: true, total: 10 }, 0);
  assert.match(binary, /use offset 4 to read further\]$/);
});

test("exchangeDetail shows trailers and says when the capture dropped the bodies", () => {
  const out = exchangeDetail(3, "response", { headers: [["content-type", "text/plain"]], trailers: [["x-checksum", "9"]], body: "", total: 0, bodyDropped: true }, 0);
  assert.equal(out, "#3 response: 0 bytes in total, body from byte 0; the capture dropped the bodies of this exchange to make room for newer ones\ncontent-type: text/plain\ntrailer x-checksum: 9\n\n");
});

test("exchangeLine marks a row whose bodies were dropped", () => {
  assert.equal(
    exchangeLine({ id: 7, time: "t", kind: "http", method: "GET", url: "https://a.test/x", status: 200, ms: 1, reqBytes: 0, resBytes: 5, bodyDropped: true }),
    "#7 t GET https://a.test/x -> 200 (1 ms, 0/5 bytes) [bodies dropped]",
  );
});

test("pendingLine prints a request that has not finished", () => {
  assert.equal(pendingLine({ time: "t", kind: "http", method: "POST", url: "https://a.test/x", ms: 1200, reqBytes: 10, resBytes: 0, rule: 2 }),
    "in flight: t POST https://a.test/x (1200 ms so far, 10/0 bytes) [rule 2]");
});

test("the envelope id of a call is the client's own, whatever the parameters hold", async () => {
  const server = await controlServer({ headers: [], body: "x", total: 1, bodyTruncated: false });
  const client = new ControlClient(server.socketPath);
  try {
    await client.call("hello", {});
    const handlers = new Map<string, ToolHandler>();
    const registrar: Registrar = { tool: (_set, name, _config, handler) => { handlers.set(name, handler); } };
    register(registrar, client);
    const r = await handlers.get("alcove_http_requests")!({ name: "vm", id: 4, part: "request" });
    assert.equal(r.isError, undefined);
    assert.deepEqual(server.lines[1], { id: 2, op: "vm.http.request", name: "vm", exchange: 4, part: "request", length: 60000 });

    const reply = await client.call("vm.http.request", { id: 99, op: "other", name: "vm" });
    assert.equal(reply.id, 3);
    assert.deepEqual(server.lines[2], { id: 3, op: "vm.http.request", name: "vm" });
  } finally {
    client.close();
    server.close();
  }
});

test("alcove_http_requests with id reads one exchange part with a default length and metadata-only structuredContent", async () => {
  const t = rig(register, { headers: [["a", "b"]], body: "x", total: 1, bodyTruncated: false });
  const r = await t.run("alcove_http_requests", { name: "vm", id: 4, part: "request", offset: 5 });
  assert.deepEqual(t.calls[0], { op: "vm.http.request", params: { name: "vm", exchange: 4, part: "request", offset: 5, length: 60000 } });
  assert.deepEqual(r.structuredContent, {
    total: 1, bodyTruncated: false, base64: undefined, encoding: undefined, bodyDropped: undefined, headersTruncated: undefined,
  });
});

test("alcove_http_requests detail names header pairs the capture left out", async () => {
  const t = rig(register, { headers: [["a", "b"]], body: "", total: 0, bodyTruncated: false, headersTruncated: true });
  const r = await t.run("alcove_http_requests", { name: "vm", id: 4 });
  assert.equal(textOf(r).split("\n")[0],
    "#4 response: 0 bytes in total, body from byte 0; the capture left out the header and trailer pairs of this exchange beyond 64 KiB");
  assert.equal(r.structuredContent!.headersTruncated, true);
});

test("alcove_http_requests lists the requests that are still in flight", async () => {
  const pending = [{ time: "t", kind: "http", method: "GET", url: "https://a.test/slow", ms: 900, reqBytes: 0, resBytes: 0 }];
  const t = rig(register, { exchanges: [], next: 0, pending });
  const r = await t.run("alcove_http_requests", { name: "vm", status: "4xx" });
  assert.equal(t.calls[0].op, "vm.http.requests");
  assert.equal(textOf(r), "no captured exchanges\nin flight: t GET https://a.test/slow (900 ms so far, 0/0 bytes)\nnext: 0");
});

test("no http tool sends a parameter named like a field of the envelope", async () => {
  const t = rig(register, { rule: 1, rules: [] });
  await t.run("alcove_http_capture_start", { name: "vm", hosts: ["a"], secrets: true, bodies: true, system_proxy: true });
  await t.run("alcove_http_capture_stop", { name: "vm" });
  await t.run("alcove_http_requests", { name: "vm", id: 1, part: "request", offset: 1, length: 2 });
  await t.run("alcove_http_requests", { name: "vm", since: 1, host: "a", path: "/", status: 404, limit: 5 });
  await t.run("alcove_http_requests", { name: "vm", clear: true });
  for (const action of ["add", "list", "remove", "clear"]) {
    await t.run("alcove_http_rule", { name: "vm", action, match: { host: "a" }, response: { status: 500 }, rule: 1 });
  }
  assert.equal(t.calls.length, 9);
  for (const call of t.calls) {
    for (const field of ["id", "op", "ok", "error"]) assert.equal(field in call.params, false, `${call.op} sends ${field}`);
  }
});

test("capture start and stop wait 15 s longer than the op may take", async () => {
  const t = rig(register, { proxy: "10.0.2.2:1", env: {} });
  await t.run("alcove_http_capture_start", { name: "vm" });
  await t.run("alcove_http_capture_stop", { name: "vm" });
  assert.deepEqual(t.timeouts, [316000, 262000]);
  assert.equal(START_WORST_MS + CAPTURE_MARGIN_MS, 316000);
  assert.equal(STOP_WORST_MS + CAPTURE_MARGIN_MS, 262000);
});

test("capture start and stop print the op's warning, and stop says when it only cleared leftovers", async () => {
  const started = rig(register, { proxy: "10.0.2.2:1", env: {}, caInstalled: true, systemProxySet: true, warning: "hosts is set: no trust store variables" });
  assert.match(textOf(await started.run("alcove_http_capture_start", { name: "vm" })), /\nwarning: hosts is set: no trust store variables$/);
  const stopped = rig(register, { exchanges: 3, warning: "the guest keeps the proxy settings" });
  assert.equal(textOf(await stopped.run("alcove_http_capture_stop", { name: "vm" })), "capture stopped; 3 exchanges were captured\nwarning: the guest keeps the proxy settings");
  const stale = rig(register, { exchanges: 0, staleCleared: true });
  assert.equal(textOf(await stale.run("alcove_http_capture_stop", { name: "vm" })),
    "no capture was running; what an earlier capture left in the guest (proxy settings, CA certificate) was cleared");
});

test("alcove_http_rule takes a status from 200 to 599", async () => {
  let schema: Record<string, unknown> = {};
  const registrar: Registrar = { tool: (_set, name, config) => { if (name === "alcove_http_rule") schema = config.inputSchema as Record<string, unknown>; } };
  register(registrar, {} as ControlClient);
  const response = (schema.response as { safeParse(v: unknown): { success: boolean } });
  assert.equal(response.safeParse({ status: 199 }).success, false);
  assert.equal(response.safeParse({ status: 200 }).success, true);
  assert.equal(response.safeParse({ status: 599 }).success, true);
  assert.equal(response.safeParse({ status: 600 }).success, false);
});

test("alcove_http_requests clear calls vm.http.clear on its own", async () => {
  const t = rig(register);
  const r = await t.run("alcove_http_requests", { name: "vm", clear: true });
  assert.deepEqual(t.calls[0], { op: "vm.http.clear", params: { name: "vm" } });
  assert.equal(textOf(r), "captured exchanges cleared");
});

test("alcove_http_requests clear with an id or a filter is refused", async () => {
  const t = rig(register);
  for (const extra of [{ id: 1 }, { host: "a" }, { limit: 5 }]) {
    const r = await t.run("alcove_http_requests", { name: "vm", clear: true, ...extra });
    assert.equal(r.isError, true);
    assert.equal(textOf(r), "clear takes no id or filters; call it on its own");
  }
  assert.equal(t.calls.length, 0);
});

test("alcove_http_capture_start maps system_proxy and prints env, CA path and the exec note", async () => {
  const t = rig(register, { proxy: "10.0.2.2:8080", env: { HTTP_PROXY: "http://10.0.2.2:8080" }, caInstalled: true, systemProxySet: false, guestCAPath: "C:\\ca.pem" });
  const r = await t.run("alcove_http_capture_start", { name: "vm", hosts: ["a.test"], secrets: true, bodies: false, system_proxy: false });
  assert.deepEqual(t.calls[0].params, { name: "vm", hosts: ["a.test"], secrets: true, bodies: false, systemProxy: false });
  const out = textOf(r);
  assert.match(out, /capturing through proxy 10\.0\.2\.2:8080/);
  assert.match(out, /system proxy not set/);
  assert.match(out, /alcove_exec does not/);
  assert.match(out, /\nHTTP_PROXY=http:\/\/10\.0\.2\.2:8080/);
  assert.match(out, /CA file in the guest: C:\\ca\.pem/);
});

test("alcove_http_rule add maps response to the rule action", async () => {
  const t = rig(register, { rule: 1 });
  await t.run("alcove_http_rule", { name: "vm", action: "add", match: { host: "a.test" }, response: { status: 500, delay_ms: 20, times: 1 } });
  assert.deepEqual(t.calls[0].params, { name: "vm", match: { host: "a.test" }, action: { status: 500, times: 1, delayMs: 20 } });
});

test("alcove_http_rule add without match matches all requests", async () => {
  const t = rig(register, { rule: 1 });
  await t.run("alcove_http_rule", { name: "vm", action: "add", response: { drop: true } });
  assert.deepEqual(t.calls[0].params, { name: "vm", match: {}, action: { drop: true } });
});

test("alcove_http_rule add needs a status, body, delay or drop", async () => {
  const t = rig(register);
  for (const response of [undefined, { headers: { a: "b" } }, { times: 1 }]) {
    const r = await t.run("alcove_http_rule", { name: "vm", action: "add", match: { host: "a.test" }, response });
    assert.equal(r.isError, true);
    assert.equal(textOf(r), "pass response with at least one of status, body, delay_ms, drop");
  }
  assert.equal(t.calls.length, 0);
});
