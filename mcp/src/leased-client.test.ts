import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { ControlError } from "./control.js";
import { LeasedControlClient, isLeaseLost } from "./leases.js";

type Request = { id: number; op: string; [key: string]: unknown };

/** A control server on a temporary unix socket that records requests and answers each with `answer(request)`. */
async function serve(answer: (request: Request) => Record<string, unknown>) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alcove-mcp-"));
  const socketPath = path.join(dir, "c.sock");
  const requests: Request[] = [];
  const sockets: net.Socket[] = [];
  let connections = 0;
  const server = net.createServer((s) => {
    connections++;
    sockets.push(s);
    let buffer = "";
    s.setEncoding("utf8");
    s.on("data", (chunk: string) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, nl)) as Request;
        buffer = buffer.slice(nl + 1);
        requests.push(request);
        s.write(JSON.stringify({ id: request.id, ...answer(request) }) + "\n");
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  const client = new LeasedControlClient(socketPath);
  return {
    client,
    requests,
    connections: () => connections,
    sent: () => requests.map(({ id: _id, ...rest }) => rest),
    close: async () => {
      client.close();
      for (const s of sockets) s.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

const refusal = "VM 'A' is leased by someone for another 12 s; pass its lease token, wait, or ask the owner to release it";

test("call sends the stored lease with requests that name its VM and only with those", async () => {
  const s = await serve(() => ({ ok: true }));
  try {
    s.client.leases.set("A", "tok-a");
    await s.client.call("vm.mouse.move", { name: "A", x: 1, y: 2 });
    await s.client.call("vm.mouse.move", { name: "B", x: 1, y: 2 });
    await s.client.call("vm.list");
    await s.client.call("vm.lease.release", { name: "A", lease: "explicit" });
    assert.deepEqual(s.sent(), [
      { op: "vm.mouse.move", name: "A", x: 1, y: 2, lease: "tok-a" },
      { op: "vm.mouse.move", name: "B", x: 1, y: 2 },
      { op: "vm.list" },
      { op: "vm.lease.release", name: "A", lease: "explicit" },
    ]);
  } finally {
    await s.close();
  }
});

test("call drops the stored lease when the server says another owner holds the VM", async () => {
  const s = await serve((r) => (r.lease === "tok-a" ? { ok: false, error: refusal } : { ok: true }));
  try {
    s.client.leases.set("A", "tok-a");
    s.client.leases.set("B", "tok-b");
    await assert.rejects(s.client.call("vm.mouse.move", { name: "A", x: 1, y: 2 }), (e: Error) => e instanceof ControlError && e.message === refusal);
    assert.equal(s.client.leases.get("A"), undefined);
    assert.equal(s.client.leases.get("B"), "tok-b");
    await s.client.call("vm.mouse.move", { name: "A", x: 3, y: 4 });
    assert.deepEqual(s.sent()[1], { op: "vm.mouse.move", name: "A", x: 3, y: 4 });
  } finally {
    await s.close();
  }
});

test("call drops the stored lease when the server says the token does not match", async () => {
  const s = await serve(() => ({ ok: false, error: "lease token does not match; only the holder can release 'A'" }));
  try {
    s.client.leases.set("A", "tok-a");
    await assert.rejects(s.client.call("vm.mouse.move", { name: "A", x: 1, y: 2 }), ControlError);
    assert.equal(s.client.leases.get("A"), undefined);
  } finally {
    await s.close();
  }
});

test("call keeps the stored lease when the caller passed its own lease and it is refused", async () => {
  const s = await serve(() => ({ ok: false, error: refusal }));
  try {
    s.client.leases.set("A", "tok-a");
    await assert.rejects(s.client.call("vm.mouse.move", { name: "A", x: 1, y: 2, lease: "other" }), ControlError);
    assert.equal(s.client.leases.get("A"), "tok-a");
  } finally {
    await s.close();
  }
});

test("isLeaseLost matches the two lease sentences only at the start of the message", () => {
  assert.equal(isLeaseLost("lease token does not match; only the holder can release 'A'"), true);
  assert.equal(isLeaseLost(refusal), true);
  assert.equal(isLeaseLost("cannot read C:\\lease token does not match; only the holder can release 'A'.txt"), false);
  assert.equal(isLeaseLost("exec failed: VM 'A' is leased by someone"), false);
});

test("call keeps the stored lease when the request fails for another reason", async () => {
  const s = await serve(() => ({ ok: false, error: "VM 'A' is stopped; call vm.start first" }));
  try {
    s.client.leases.set("A", "tok-a");
    await assert.rejects(s.client.call("vm.mouse.move", { name: "A", x: 1, y: 2 }), ControlError);
    assert.equal(s.client.leases.get("A"), "tok-a");
  } finally {
    await s.close();
  }
});

test("call leaves the book untouched when a lease refusal names a VM without a stored lease", async () => {
  const s = await serve(() => ({ ok: false, error: refusal }));
  try {
    s.client.leases.set("B", "tok-b");
    await assert.rejects(s.client.call("vm.mouse.move", { name: "A", x: 1, y: 2 }), ControlError);
    assert.deepEqual(s.client.leases.entries(), [["B", "tok-b"]]);
  } finally {
    await s.close();
  }
});

test("releaseAll releases every stored lease and empties the book", async () => {
  const s = await serve(() => ({ ok: true }));
  try {
    await s.client.call("vm.list");
    s.client.leases.set("A", "tok-a");
    s.client.leases.set("B", "tok-b");
    await s.client.releaseAll();
    const sent = s.sent().filter((r) => r.op === "vm.lease.release").sort((x, y) => String(x.name).localeCompare(String(y.name)));
    assert.deepEqual(sent, [
      { op: "vm.lease.release", name: "A", lease: "tok-a" },
      { op: "vm.lease.release", name: "B", lease: "tok-b" },
    ]);
    assert.deepEqual(s.client.leases.entries(), []);
  } finally {
    await s.close();
  }
});

test("releaseAll empties the book when a release fails", async () => {
  const s = await serve((r) => (r.name === "A" ? { ok: false, error: "no VM named 'A'; call vm.list" } : { ok: true }));
  try {
    await s.client.call("vm.list");
    s.client.leases.set("A", "tok-a");
    s.client.leases.set("B", "tok-b");
    await s.client.releaseAll();
    assert.equal(s.requests.filter((r) => r.op === "vm.lease.release").length, 2);
    assert.deepEqual(s.client.leases.entries(), []);
  } finally {
    await s.close();
  }
});

test("releaseAll without a connection opens none, sends nothing and empties the book", async () => {
  const s = await serve(() => ({ ok: true }));
  try {
    s.client.leases.set("A", "tok-a");
    await s.client.releaseAll();
    assert.equal(s.connections(), 0);
    assert.deepEqual(s.client.leases.entries(), []);
  } finally {
    await s.close();
  }
});
