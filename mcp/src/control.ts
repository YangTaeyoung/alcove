// Client for the Alcove control protocol (docs/control-protocol.md) over the
// unix socket, with auto-start of the headless server when the app is not
// running.
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { spawn, ChildProcess } from "node:child_process";

export const DEFAULT_SOCKET = path.join(os.homedir(), "Library", "Application Support", "Alcove", "control.sock");

export interface ControlReply { ok: boolean; error?: string; [key: string]: unknown }

export class ControlError extends Error {}

/** Op name prefixes that the control server runs outside the request order of a connection (`ControlHandler.isConcurrent`). */
export const CONCURRENT_PREFIXES: readonly string[] = ["vm.exec", "vm.process.", "vm.fs."];

/** Op names besides those of `CONCURRENT_PREFIXES` that the control server runs outside the request order of a connection. */
export const CONCURRENT_OPS: ReadonlySet<string> = new Set([
  "vm.push_file", "vm.pull_file", "vm.sync_dir", "vm.find_text", "vm.crash_dumps.pull", "vm.collect_diagnostics", "script.run",
  "vm.window.list", "vm.ui.tree", "vm.ui.find", "vm.ui.text", "vm.app.launch", "vm.deploy",
]);

/** Whether the control server runs `op` outside the request order of its connection; every other op waits for the one sent before it. */
export function isConcurrent(op: string): boolean {
  return CONCURRENT_PREFIXES.some((prefix) => op.startsWith(prefix)) || CONCURRENT_OPS.has(op);
}

export class ControlClient {
  private sock: net.Socket | null = null;
  private dialing: net.Socket | null = null;
  private connecting: Promise<void> | null = null;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, { op: string; resolve: (r: ControlReply) => void; reject: (e: Error) => void }>();
  private headless: ChildProcess | null = null;
  private closes = 0;
  /** Settles when the serial call sent last has answered or failed. */
  private serialTail: Promise<void> = Promise.resolve();

  constructor(readonly socketPath = process.env.ALCOVE_CONTROL_SOCKET ?? DEFAULT_SOCKET) {}

  /** Whether the client holds a connection to the control server. */
  get connected(): boolean {
    return this.sock !== null;
  }

  /** Connect, starting `alcovectl serve` when nothing answers. Callers that arrive while a connection is being made wait for that one. */
  connect(): Promise<void> {
    if (this.sock) return Promise.resolve();
    if (!this.connecting) {
      this.connecting = this.open().finally(() => { this.connecting = null; });
    }
    return this.connecting;
  }

  private async open(): Promise<void> {
    const closes = this.closes;
    const ensureOpen = () => {
      if (this.closes !== closes) throw new ControlError("the control client was closed");
    };
    try {
      await this.dial();
      return;
    } catch {
      ensureOpen();
    }
    await this.startHeadless();
    const deadline = Date.now() + 15000;
    let lastErr: unknown;
    while (Date.now() < deadline) {
      ensureOpen();
      try {
        await this.dial();
        return;
      } catch (e) {
        ensureOpen();
        lastErr = e;
        await new Promise((r) => setTimeout(r, 300));
      }
    }
    throw new ControlError(
      `cannot reach the Alcove control socket at ${this.socketPath}: ${String(lastErr)}; open Alcove.app, or set ALCOVE_CTL to an alcovectl binary that can run \`alcovectl serve\``,
    );
  }

  /** Opens one socket and makes it the connection; its data and close events count only while it is the connection. */
  private dial(): Promise<void> {
    return new Promise((resolve, reject) => {
      const s = net.createConnection(this.socketPath);
      this.dialing = s;
      s.setEncoding("utf8");
      s.once("connect", () => {
        if (this.dialing !== s) {
          s.destroy();
          reject(new ControlError("the control client was closed"));
          return;
        }
        this.dialing = null;
        this.sock = s;
        this.buffer = "";
        s.on("data", (chunk: string) => { if (this.sock === s) this.onData(chunk); });
        s.on("close", () => { if (this.sock === s) this.onClose(); });
        s.on("error", () => { if (this.sock === s) this.onClose(); });
        resolve();
      });
      s.once("error", (e) => {
        if (this.dialing === s) this.dialing = null;
        reject(e);
      });
      s.once("close", () => {
        if (this.sock !== s) reject(new ControlError("the control client was closed"));
      });
    });
  }

  private onData(chunk: string) {
    this.buffer += chunk;
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      if (!line.trim()) continue;
      let msg: ControlReply;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      const id = typeof msg.id === "number" ? msg.id : -1;
      const p = this.pending.get(id);
      if (!p) continue;
      this.pending.delete(id);
      p.resolve(msg);
    }
  }

  /** Drops the connection and fails every pending call with a sentence that names its op. */
  private onClose() {
    this.sock?.destroy();
    this.sock = null;
    this.buffer = "";
    for (const [, p] of this.pending) {
      p.reject(new ControlError(
        `the connection to the Alcove control server closed before ${p.op} answered; check the VM with alcove_vm_status, then call the tool again`,
      ));
    }
    this.pending.clear();
  }

  /**
   * Send one request and await its reply; throws ControlError on `ok: false`. The request's `id` and `op` are the envelope's, whatever `params` holds under those names.
   * `timeoutMs` counts from the send for an op of `isConcurrent`, and for any other op from the moment the serial call sent before it has answered or failed.
   */
  async call(op: string, params: Record<string, unknown> = {}, timeoutMs = 600000): Promise<ControlReply> {
    await this.connect();
    const sock = this.sock;
    if (!sock) throw new ControlError(`the connection to the Alcove control server closed before ${op} was sent; call the tool again`);
    const id = this.nextId++;
    const line = JSON.stringify({ ...params, id, op }) + "\n";
    const before = isConcurrent(op) ? null : this.serialTail;
    let settled = () => {};
    if (before) this.serialTail = new Promise<void>((resolve) => { settled = resolve; });
    const reply = await new Promise<ControlReply>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      let done = false;
      const finish = () => {
        done = true;
        clearTimeout(timer);
        settled();
      };
      const arm = () => {
        if (done) return;
        timer = setTimeout(() => {
          this.pending.delete(id);
          finish();
          reject(new ControlError(
            `${op} timed out after ${timeoutMs / 1000} s; the control server may still be running it: check alcove_vm_status before you call the tool again`,
          ));
        }, timeoutMs);
      };
      this.pending.set(id, {
        op,
        resolve: (r) => { finish(); resolve(r); },
        reject: (e) => { finish(); reject(e); },
      });
      sock.write(line);
      if (before) void before.then(arm); else arm();
    });
    if (!reply.ok) throw new ControlError(reply.error ?? `${op} failed`);
    return reply;
  }

  /** Locate alcovectl and run `alcovectl serve` as a child of this process. */
  private async startHeadless(): Promise<void> {
    if (this.headless) return;
    const ctl = findAlcovectl();
    if (!ctl) {
      throw new ControlError(
        "the Alcove app is not running and alcovectl was not found; open Alcove.app or set ALCOVE_CTL to the alcovectl binary",
      );
    }
    const child = spawn(ctl, ["serve", "--socket", this.socketPath], { stdio: ["ignore", "ignore", "pipe"] });
    child.stderr?.on("data", (d) => process.stderr.write(`[alcovectl] ${d}`));
    child.on("exit", (code) => {
      process.stderr.write(`[alcovectl] serve exited with ${code}\n`);
      this.headless = null;
    });
    this.headless = child;
  }

  /** Ends the connection, a connection being made, and the `alcovectl serve` this client started. */
  close() {
    this.closes++;
    this.dialing?.destroy();
    this.dialing = null;
    if (this.sock) this.onClose();
    if (this.headless) {
      this.headless.kill("SIGTERM");
      this.headless = null;
    }
  }
}

/** The paths where `findAlcovectl` looks for alcovectl, in order. */
export function alcovectlCandidates(): string[] {
  return [
    process.env.ALCOVE_CTL,
    "/Applications/Alcove.app/Contents/MacOS/alcovectl",
    path.join(os.homedir(), "Applications", "Alcove.app", "Contents", "MacOS", "alcovectl"),
    // development checkout: <repo>/mcp/dist/index.js -> <repo>/AlcoveKit/.build/debug/alcovectl
    path.resolve(new URL(".", import.meta.url).pathname, "..", "..", "AlcoveKit", ".build", "debug", "alcovectl"),
  ].filter((c): c is string => Boolean(c));
}

export function findAlcovectl(): string | null {
  for (const c of alcovectlCandidates()) {
    if (c && fs.existsSync(c)) {
      try {
        fs.accessSync(c, fs.constants.X_OK);
        return c;
      } catch {
        /* not executable */
      }
    }
  }
  return null;
}
