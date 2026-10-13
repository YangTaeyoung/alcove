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

/** Longest a control op waits for its turn at the guest's UI helper, in ms. */
export const HELPER_QUEUE_MS = 60000;
/** Longest the control server waits for the answer to one call to the guest's UI helper, in ms. */
export const HELPER_CALL_MS = 215000;
/** Longest an observation spends on the UI facts of the guest, in ms. */
export const UI_FACTS_BUDGET_MS = 20000;
/** Allowance in ms for the way of a control reply back to this server. */
export const CALL_MARGIN_MS = 5000;

/**
 * `client.call` timeout in ms of a tool whose control op makes `helperCalls` calls to the guest's UI helper one after
 * another and may observe the screen afterwards: for each call the wait for the helper and its answer, then the UI
 * facts of the observation and the margin. `actionTimeout` adds the time the screen takes to settle.
 */
export function uiCallTimeout(helperCalls = 1): number {
  return helperCalls * (HELPER_QUEUE_MS + HELPER_CALL_MS) + UI_FACTS_BUDGET_MS + CALL_MARGIN_MS;
}

/** Longest `vm.find_text` waits for its turn in the control server's line of text recognitions, in ms. */
export const TEXT_TURN_MS = 60000;
/** Allowance in ms for the recognition of `vm.find_text` once its turn has come. */
export const TEXT_READING_MS = 10000;
/** `client.call` timeout in ms of `alcove_find_text`: the wait for its turn, the recognition and the margin. */
export const FIND_TEXT_TIMEOUT_MS = TEXT_TURN_MS + TEXT_READING_MS + CALL_MARGIN_MS;

/** `uiCallTimeout` of a control op that makes one helper call. */
export const UI_CALL_TIMEOUT_MS = uiCallTimeout(1);
/** `client.call` timeout in ms of `alcove_deploy`: copy, installer, launch and window wait. */
export const DEPLOY_TIMEOUT_MS = 5400000;
/** Longest the steps of one `script.run` are waited for, in ms: two hours. The control op has no limit on the number of steps; each step is held to 600 s of expectations plus its op. */
export const SCRIPT_STEPS_BUDGET_MS = 7200000;
/** `client.call` timeout in ms of `vm.snapshot.restore`. */
export const SNAPSHOT_RESTORE_MS = 660000;
/** `client.call` timeout in ms of a screenshot without marks, which `script.run` takes after a failing step. */
export const SCREENSHOT_CALL_MS = 60000;
/** `client.call` timeout in ms of `alcove_script_run`: the optional snapshot restore, the steps, the failure screenshot and the margin. */
export const SCRIPT_RUN_TIMEOUT_MS = SNAPSHOT_RESTORE_MS + SCRIPT_STEPS_BUDGET_MS + SCREENSHOT_CALL_MS + CALL_MARGIN_MS;
/** `client.call` timeout in ms of `alcove_script_save`, which reads a trace file on the Mac. */
export const SCRIPT_SAVE_TIMEOUT_MS = 120000;

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
