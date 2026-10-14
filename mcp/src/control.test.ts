import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { ControlClient, ControlError } from "./control.js";

type Request = { id: number; op: string; [key: string]: unknown };

/**
 * A control server on a temporary unix socket. `answer` gives the reply fields of a request, or null for no reply;
 * replies are written in chunks of `chunk` characters with a pause between them.
 */
async function serve(answer: (request: Request, socket: net.Socket) => Record<string, unknown> | null, chunk = 0) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alcove-ctl-"));
  const socketPath = path.join(dir, "c.sock");
  const sockets: net.Socket[] = [];
  let open = 0;
  const server = net.createServer((s) => {
    sockets.push(s);
    open++;
    s.on("close", () => open--);
    let buffer = "";
    s.setEncoding("utf8");
    s.on("data", async (data: string) => {
      buffer += data;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const request = JSON.parse(buffer.slice(0, nl)) as Request;
        buffer = buffer.slice(nl + 1);
        const fields = answer(request, s);
        if (fields === null) continue;
        const line = JSON.stringify({ id: request.id, ...fields }) + "\n";
        if (chunk <= 0) { s.write(line); continue; }
        for (let i = 0; i < line.length; i += chunk) {
          s.write(line.slice(i, i + chunk));
          await new Promise((r) => setTimeout(r, 1));
        }
      }
    });
    s.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  const client = new ControlClient(socketPath);
  return {
    client,
    connections: () => sockets.length,
    open: () => open,
    close: async () => {
      client.close();
      for (const s of sockets) s.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

const until = async (check: () => boolean) => {
  for (let i = 0; i < 200 && !check(); i++) await new Promise((r) => setTimeout(r, 5));
};

test("parallel first calls share one connection and each gets its own reply", async () => {
  const s = await serve((r) => ({ ok: true, echo: r.op, data: "x".repeat(20000) }), 4096);
  try {
    const replies = await Promise.all(["vm.list", "vm.status", "vm.screenshot"].map((op) => s.client.call(op)));
    assert.deepEqual(replies.map((r) => r.echo), ["vm.list", "vm.status", "vm.screenshot"]);
    assert.equal(s.connections(), 1);
  } finally {
    await s.close();
  }
});

test("close ends the one connection the client opened", async () => {
  const s = await serve(() => ({ ok: true }));
  try {
    await Promise.all([s.client.call("vm.list"), s.client.call("vm.status"), s.client.call("vm.list")]);
    s.client.close();
    await until(() => s.open() === 0);
    assert.equal(s.open(), 0);
  } finally {
    await s.close();
  }
});

test("a call after the server closed the connection opens a new one", async () => {
  const s = await serve((r, socket) => {
    if (r.op === "drop") { socket.destroy(); return null; }
    return { ok: true };
  });
  try {
    await assert.rejects(s.client.call("drop"), ControlError);
    await s.client.call("vm.list");
    assert.equal(s.connections(), 2);
  } finally {
    await s.close();
  }
});

test("a closed connection fails the pending call with a sentence that names alcove_vm_status", async () => {
  const s = await serve((r, socket) => { socket.destroy(); return null; });
  try {
    await assert.rejects(s.client.call("vm.type"), (e: Error) =>
      e instanceof ControlError &&
      e.message === "the connection to the Alcove control server closed before vm.type answered; check the VM with alcove_vm_status, then call the tool again");
  } finally {
    await s.close();
  }
});

test("a call without an answer in time fails with a sentence that says the server may still run it", async () => {
  const s = await serve(() => null);
  try {
    await assert.rejects(s.client.call("vm.type", {}, 50), (e: Error) =>
      e instanceof ControlError &&
      e.message === "vm.type timed out after 0.05 s; the control server may still be running it: check alcove_vm_status before you call the tool again");
  } finally {
    await s.close();
  }
});

test("connected says whether the client holds a connection", async () => {
  const s = await serve(() => ({ ok: true }));
  try {
    assert.equal(s.client.connected, false);
    await s.client.call("vm.list");
    assert.equal(s.client.connected, true);
    s.client.close();
    assert.equal(s.client.connected, false);
  } finally {
    await s.close();
  }
});
