// Test helper: registers one toolset against a fake control client that records calls.
import type { ControlClient } from "./control.js";
import type { Registrar, ToolHandler, ToolResult } from "./toolkit.js";

export type Call = { op: string; params: Record<string, unknown> };

export function rig(register: (r: Registrar, c: ControlClient) => void, reply: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const timeouts: Array<number | undefined> = [];
  const handlers = new Map<string, ToolHandler>();
  const descriptions = new Map<string, string>();
  const schemas = new Map<string, Record<string, unknown>>();
  const annotations = new Map<string, Record<string, unknown>>();
  const registrar: Registrar = {
    tool: (_set, name, config, handler) => {
      handlers.set(name, handler);
      descriptions.set(name, config.description ?? "");
      schemas.set(name, (config.inputSchema ?? {}) as Record<string, unknown>);
      annotations.set(name, config.annotations ?? {});
    },
  };
  const client = {
    call: async (op: string, params: Record<string, unknown> = {}, timeout?: number) => (calls.push({ op, params }), timeouts.push(timeout), reply),
  } as unknown as ControlClient;
  register(registrar, client);
  return { calls, timeouts, descriptions, schemas, annotations, run: (tool: string, args: Record<string, unknown>) => handlers.get(tool)!(args) };
}

export const textOf = (r: ToolResult) => r.content.map((c) => (c.type === "text" ? c.text : "")).join("\n");
