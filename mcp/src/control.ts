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

export class ControlClient {
  private sock: net.Socket | null = null;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, { resolve: (r: ControlReply) => void; reject: (e: Error) => void }>();
  private headless: ChildProcess | null = null;

  constructor(readonly socketPath = process.env.ALCOVE_CONTROL_SOCKET ?? DEFAULT_SOCKET) {}

  /** Connect, starting `alcovectl serve` when nothing answers. */
  async connect(): Promise<void> {
    if (this.sock) return;
    try {
      await this.dial();
      return;
    } catch {
      /* fall through */
    }
    await this.startHeadless();
    const deadline = Date.now() + 15000;
    let lastErr: unknown;
    while (Date.now() < deadline) {
      try {
        await this.dial();
        return;
      } catch (e) {
        lastErr = e;
        await new Promise((r) => setTimeout(r, 300));
      }
    }
    throw new ControlError(`cannot reach the Alcove control socket at ${this.socketPath}: ${String(lastErr)}`);
  }

  private dial(): Promise<void> {
    return new Promise((resolve, reject) => {
      const s = net.createConnection(this.socketPath);
      s.setEncoding("utf8");
      s.once("connect", () => {
        this.sock = s;
        s.on("data", (chunk: string) => this.onData(chunk));
        s.on("close", () => this.onClose(new ControlError("control connection closed")));
        s.on("error", (e) => this.onClose(e));
        resolve();
      });
      s.once("error", (e) => reject(e));
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

  private onClose(err: Error) {
    this.sock = null;
    for (const [, p] of this.pending) p.reject(err);
    this.pending.clear();
  }

  /** Send one request and await its reply; throws ControlError on `ok: false`. The request's `id` and `op` are the envelope's, whatever `params` holds under those names. */
  async call(op: string, params: Record<string, unknown> = {}, timeoutMs = 600000): Promise<ControlReply> {
    await this.connect();
    const id = this.nextId++;
    const line = JSON.stringify({ ...params, id, op }) + "\n";
    const reply = await new Promise<ControlReply>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new ControlError(`${op} timed out after ${timeoutMs / 1000}s`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (r) => { clearTimeout(timer); resolve(r); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.sock!.write(line);
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

  close() {
    this.sock?.destroy();
    this.sock = null;
    if (this.headless) {
      this.headless.kill("SIGTERM");
      this.headless = null;
    }
  }
}

export function findAlcovectl(): string | null {
  const candidates = [
    process.env.ALCOVE_CTL,
    "/Applications/Alcove.app/Contents/MacOS/alcovectl",
    path.join(os.homedir(), "Applications", "Alcove.app", "Contents", "MacOS", "alcovectl"),
    // development checkouts: <repo>/mcp/dist/index.js -> <repo>/AlcoveKit/.build*/debug/alcovectl
    ...["", "-ctl", "-app", "-wp4"].map((suffix) => path.resolve(new URL(".", import.meta.url).pathname, "..", "..", "AlcoveKit", `.build${suffix}`, "debug", "alcovectl")),
  ];
  for (const c of candidates) {
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
