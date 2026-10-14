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

/** The instructions the server gives MCP clients: one sentence per enabled toolset, naming only tools of enabled toolsets. */
export function serverInstructions(enabled: Set<Toolset>): string {
  const on = (set: Toolset) => enabled.has(set);
  const textTools = [on("core") ? "alcove_exec" : "", on("files") ? "alcove_fs_*" : "", on("shell") ? "alcove_process_*" : ""].filter(Boolean);
  const parts = ["Alcove drives virtual machines."];
  if (textTools.length) {
    parts.push(`Text tools (${textTools.join(", ")}) are cheaper and more reliable than screenshots: prefer them whenever the guest tools are connected.`);
  }
  if (on("shell")) {
    parts.push(`Run long commands such as builds and test suites with alcove_exec_start and follow them with alcove_exec_read${on("core") ? " instead of blocking in alcove_exec" : ""}.`);
  }
  if (on("core")) {
    parts.push("Action tools report what changed on screen; ask for observe: \"diff\" or \"image\" only when the text summary is not enough, and use alcove_find_text to read the screen.");
  }
  if (on("files")) parts.push("Move build output into the guest with alcove_sync_dir.");
  if (on("ui")) {
    parts.push(`On Windows guests read the UI with alcove_ui_tree before taking screenshots and act with alcove_ui_click and alcove_ui_type${on("core") ? "; wait for streamed output with alcove_wait_for ui_text_stable" : ""}.`);
  }
  if (on("state")) {
    parts.push("Take a snapshot with alcove_snapshot_create before risky changes and return to it with alcove_snapshot_restore; alcove_clone_vm gives a linked clone for parallel work; alcove_lease_acquire keeps other agents off a VM.");
  }
  if (on("evidence")) parts.push("alcove_record_start captures a test run as a trace and video, and alcove_collect_diagnostics gathers evidence when something fails.");
  if (on("http")) parts.push("alcove_http_capture_start records the guest's HTTP(S) traffic for alcove_http_requests, and alcove_http_rule fakes server answers.");
  if (on("replay")) parts.push("alcove_script_save turns a recording into a script and alcove_script_run replays it without a model.");
  parts.push("When neither the Alcove app nor another control server answers, this server starts a headless control server, and the VMs it runs shut down when this session ends.");
  return parts.join(" ");
}

export function text(t: string, structured?: Record<string, unknown>): ToolResult {
  return { content: [{ type: "text", text: t }], ...(structured ? { structuredContent: structured } : {}) };
}

export function fail(e: unknown): ToolResult {
  const msg = e instanceof ControlError ? e.message : `unexpected error: ${String(e)}`;
  return { content: [{ type: "text", text: msg }], isError: true };
}

/** A control reply without the envelope fields `ok` and `id`. */
export function withoutEnvelope(reply: Record<string, unknown>): Record<string, unknown> {
  const { ok: _ok, id: _id, ...rest } = reply;
  return rest;
}

/** The most entries of a file list that structured content carries. */
export const STRUCTURED_LIST_MAX = 50;

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
/**
 * `client.call` timeout in ms of `alcove_find_text`: `vm.find_text` reads the screen a second time after a failed
 * recognition, so two waits for a turn with their recognitions, then the margin.
 */
export const FIND_TEXT_TIMEOUT_MS = 2 * (TEXT_TURN_MS + TEXT_READING_MS) + CALL_MARGIN_MS;

/** Most key events `vm.type` sends per character: a change of the shift key, the key down and the key up. */
export const KEY_EVENTS_PER_CHAR = 3;
/** Allowance in ms for sending one key event beyond the delay `vm.type` waits after it. */
export const KEY_EVENT_MS = 10;
/** Allowance in ms of `vm.type` besides its key events: the frame read, or the clipboard paste through the guest tools. */
export const TYPE_BASE_MS = 60000;

/** Longest `vm.type` takes, in ms, for `chars` characters with `delayMs` after each key event, the shift release included. */
export function typeMs(chars: number, delayMs: number): number {
  return TYPE_BASE_MS + (KEY_EVENTS_PER_CHAR * chars + 1) * (delayMs + KEY_EVENT_MS);
}

/** Longest one guest recipe of the control server runs, in ms: 60 s in the guest and 15 s more on the host. */
export const RECIPE_MS = 75000;
/** Longest the control server waits for the guest tools before a recipe, in ms. */
export const TOOLS_WAIT_MS = 25000;
/** Allowance in ms for reading one frame of the guest screen. */
export const FRAME_MS = 30000;
/** Allowance in ms for the way of a long control op's reply back to this server. */
export const LONG_MARGIN_MS = 15000;
/**
 * `client.call` timeout in ms of `alcove_doctor`: the screen, the 5 s wait for the guest tools, the probe recipe and
 * the proxy recipe, then the margin.
 */
export const DOCTOR_TIMEOUT_MS = FRAME_MS + 5000 + 2 * RECIPE_MS + LONG_MARGIN_MS;

/** `client.call` timeout in ms of `alcove_set_environment` with `settings` settings: the tools wait, one recipe per setting and the margin. */
export function setEnvironmentTimeout(settings: number): number {
  return TOOLS_WAIT_MS + Math.max(1, settings) * RECIPE_MS + LONG_MARGIN_MS;
}

/**
 * Longest `vm.start` takes to launch the engine, in ms: the end of an earlier capture's proxy (6 s), the TPM and QMP
 * sockets (10 s and 20 s) and the QMP commands that follow (30 s).
 */
export const ENGINE_LAUNCH_MS = 66000;
/** Longest the engine loads a session saved to disk, in ms (`VMController.resumeTimeout`). */
export const RESUME_LOAD_MS = 600000;

/** `client.call` timeout in ms of `vm.start` with `waitToolsS`: launch, the load of a saved session, the tools wait, the clock sync recipe and the margin. */
export function startTimeout(waitToolsS: number): number {
  return ENGINE_LAUNCH_MS + RESUME_LOAD_MS + waitToolsS * 1000 + RECIPE_MS + LONG_MARGIN_MS;
}

/** `uiCallTimeout` of a control op that makes one helper call. */
export const UI_CALL_TIMEOUT_MS = uiCallTimeout(1);
/** `client.call` timeout in ms of `alcove_deploy`: copy, installer, launch and window wait. */
export const DEPLOY_TIMEOUT_MS = 5400000;
/** Longest the steps of one `script.run` are waited for, in ms: two hours. */
export const SCRIPT_STEPS_BUDGET_MS = 7200000;
/** `client.call` timeout in ms of `vm.snapshot.restore`. */
export const SNAPSHOT_RESTORE_MS = 660000;
/** `client.call` timeout in ms of a screenshot without marks, which `script.run` takes after a failing step. */
export const SCREENSHOT_CALL_MS = 60000;
/** `client.call` timeout in ms of `alcove_script_run`: the optional snapshot restore, the steps, the failure screenshot and the margin. */
export const SCRIPT_RUN_TIMEOUT_MS = SNAPSHOT_RESTORE_MS + SCRIPT_STEPS_BUDGET_MS + SCREENSHOT_CALL_MS + CALL_MARGIN_MS;
/** Widest image in pixels that tools return to the model; the control op scales larger screenshots down to it. */
export const MODEL_IMAGE_MAX_WIDTH = 1280;
/** `client.call` timeout in ms of `alcove_script_save`, which reads a trace file on the Mac. */
export const SCRIPT_SAVE_TIMEOUT_MS = 120000;

export const vmName = z.string().describe("VM name as shown by alcove_list_vms, e.g. \"Windows 11\"");

/** Command parameters shared by alcove_exec and alcove_exec_start. */
export const commandParams = {
  command: z.string().min(1).max(100000).optional().describe("Command line run through the shell; give this or argv"),
  argv: z.array(z.string()).min(1).optional().describe("Program and arguments run without a shell wrapper; give this or command"),
  cwd: z.string().optional().describe("Working directory inside the guest"),
  env: z.record(z.string()).optional().describe("Extra environment variables"),
  shell: z.enum(["powershell", "cmd", "sh", "none"]).optional().describe("Shell that runs `command` (default: powershell on Windows, sh elsewhere); \"none\" requires argv"),
};

/** The `stdin` parameter of alcove_exec. */
export const stdinParam = {
  stdin: z.string().optional().describe("Text written to the command's standard input"),
};

/** A `region` parameter: a guest-pixel rectangle. */
export const regionSchema = z.object({ x: z.number().int(), y: z.number().int(), w: z.number().int(), h: z.number().int() });

export interface CommandArgs { command?: string; argv?: string[]; cwd?: string; env?: Record<string, string>; stdin?: string; shell?: string }

/** Control params for a command, with `stdin` only when `withStdin`; throws a ControlError when neither command nor argv is given. */
export function commandPayload(a: CommandArgs, withStdin = true): Record<string, unknown> {
  if (!a.command && !a.argv) throw new ControlError("give either `command` or `argv`");
  const p: Record<string, unknown> = {};
  if (a.command) p.command = a.command;
  if (a.argv) p.argv = a.argv;
  if (a.cwd !== undefined) p.cwd = a.cwd;
  if (a.env !== undefined) p.env = a.env;
  if (withStdin && a.stdin !== undefined) p.stdin = a.stdin;
  if (a.shell !== undefined) p.shell = a.shell;
  return p;
}

/** `stdout:` and `stderr:` sections, each omitted when empty and clipped at 60000 characters with `hint` on the cut. */
export function streamSections(stdout: string, stderr: string, hint?: string): string {
  const parts: string[] = [];
  if (stdout) parts.push(`stdout:\n${clip(stdout, 60000, hint)}`);
  if (stderr) parts.push(`stderr:\n${clip(stderr, 60000, hint)}`);
  return parts.join("\n");
}
