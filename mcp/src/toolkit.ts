// Shared helpers for the MCP tool modules: result builders, toolset selection
// and the registrar that skips tools of disabled toolsets.
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z, type ZodRawShape } from "zod";
import { ControlError } from "./control.js";

export const TOOLSETS = ["core", "shell", "files", "state", "ui", "evidence", "replay", "http"] as const;
export type Toolset = (typeof TOOLSETS)[number];

export type ToolResult = {
  content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }>;
  isError?: boolean;
  structuredContent?: Record<string, unknown>;
};

export interface ToolConfig {
  title?: string;
  description?: string;
  inputSchema?: ZodRawShape;
  annotations?: Record<string, unknown>;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type ToolHandler = (args: any) => Promise<ToolResult>;

/** Parses ALCOVE_MCP_TOOLSETS; unset or empty selects all; unknown names throw with the valid list. */
export function selectedToolsets(env: string | undefined): Set<Toolset> {
  const names = (env ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (names.length === 0) return new Set(TOOLSETS);
  const out = new Set<Toolset>();
  for (const n of names) {
    if (!(TOOLSETS as readonly string[]).includes(n)) {
      throw new Error(`unknown toolset '${n}' in ALCOVE_MCP_TOOLSETS; valid toolsets: ${TOOLSETS.join(", ")}`);
    }
    out.add(n as Toolset);
  }
  return out;
}

export function text(t: string, structured?: Record<string, unknown>): ToolResult {
  return { content: [{ type: "text", text: t }], ...(structured ? { structuredContent: structured } : {}) };
}

export function fail(e: unknown): ToolResult {
  const msg = e instanceof ControlError ? e.message : `unexpected error: ${String(e)}`;
  return { content: [{ type: "text", text: msg }], isError: true };
}

/** Truncates to `max` characters and appends a line naming the paging parameter. */
export function clip(s: string, max = 60000, hint?: string): string {
  if (s.length <= max) return s;
  return `${s.slice(0, max)}\n...[truncated${hint ? `; ${hint}` : ""}]`;
}

export interface Registrar {
  tool(set: Toolset, name: string, config: ToolConfig, handler: ToolHandler): void;
}

export function registrar(server: Pick<McpServer, "registerTool">, enabled: Set<Toolset>): Registrar {
  return {
    tool(set, name, config, handler) {
      if (!enabled.has(set)) return;
      (server.registerTool as unknown as (n: string, c: ToolConfig, h: ToolHandler) => unknown)(name, config, handler);
    },
  };
}

export const vmName = z.string().describe("VM name as shown by alcove_list_vms, e.g. \"Windows 11\"");

/** Command parameters shared by alcove_exec and alcove_exec_start. */
export const commandParams = {
  command: z.string().min(1).max(100000).optional().describe("Command line run through the shell; give this or argv"),
  argv: z.array(z.string()).min(1).optional().describe("Program and arguments run without a shell wrapper; give this or command"),
  cwd: z.string().optional().describe("Working directory inside the guest"),
  env: z.record(z.string()).optional().describe("Extra environment variables"),
  stdin: z.string().optional().describe("Text written to the command's standard input"),
  shell: z.enum(["powershell", "cmd", "sh", "none"]).optional().describe("Shell that runs `command` (default: powershell on Windows, sh elsewhere); \"none\" requires argv"),
};

export interface CommandArgs { command?: string; argv?: string[]; cwd?: string; env?: Record<string, string>; stdin?: string; shell?: string }

/** Control params for a command; throws a ControlError when neither command nor argv is given. */
export function commandPayload(a: CommandArgs): Record<string, unknown> {
  if (!a.command && !a.argv) throw new ControlError("give either `command` or `argv`");
  const p: Record<string, unknown> = {};
  if (a.command) p.command = a.command;
  if (a.argv) p.argv = a.argv;
  if (a.cwd !== undefined) p.cwd = a.cwd;
  if (a.env !== undefined) p.env = a.env;
  if (a.stdin !== undefined) p.stdin = a.stdin;
  if (a.shell !== undefined) p.shell = a.shell;
  return p;
}

/** `stdout:` and `stderr:` sections, each omitted when empty and clipped at 60000 characters. */
export function streamSections(stdout: string, stderr: string): string {
  const parts: string[] = [];
  if (stdout) parts.push(`stdout:\n${clip(stdout)}`);
  if (stderr) parts.push(`stderr:\n${clip(stderr)}`);
  return parts.join("\n");
}
