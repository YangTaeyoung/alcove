// Core tools beyond the basic actions: held mouse buttons and keys, text search,
// condition waits and batches.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { actionResult, actionTimeout, batchResult, observeParams, observePayload, waitForResult, type ObserveArgs } from "../observation.js";
import { fail, text, vmName, type Registrar } from "../toolkit.js";

const buttonEnum = z.enum(["left", "right", "middle"]);
const regionSchema = z.object({ x: z.number().int(), y: z.number().int(), w: z.number().int(), h: z.number().int() });

/** Converts snake_case object keys to camelCase, recursively through objects and arrays. */
export function camelKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(camelKeys);
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase())] = camelKeys(val);
    }
    return out;
  }
  return v;
}

const STEP_OPS: Record<string, { op: string; rename?: Record<string, string> }> = {
  click: { op: "vm.mouse.click" },
  move: { op: "vm.mouse.move" },
  drag: { op: "vm.mouse.drag" },
  scroll: { op: "vm.mouse.scroll" },
  type: { op: "vm.type", rename: { delay_ms: "delay" } },
  press_keys: { op: "vm.key.press", rename: { hold_ms: "hold" } },
  mouse_down: { op: "vm.mouse.down" },
  mouse_up: { op: "vm.mouse.up" },
  key_down: { op: "vm.key.down" },
  key_up: { op: "vm.key.up" },
  wait_idle: { op: "vm.wait_idle", rename: { timeout_s: "timeout" } },
  wait_for: { op: "vm.wait_for", rename: { timeout_s: "timeout" } },
  sleep: { op: "sleep" },
};

/** Control step for an `alcove_batch` step; throws naming the valid ops for an unknown one. */
export function mapBatchStep(step: Record<string, unknown>, index: number): Record<string, unknown> {
  const spec = STEP_OPS[String(step.op)];
  if (!spec) {
    throw new ControlError(`step ${index}: unknown op '${String(step.op)}'; valid ops: ${Object.keys(STEP_OPS).join(", ")}`);
  }
  const { op: _op, ...params } = step;
  const renamed: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params)) renamed[spec.rename?.[k] ?? k] = v;
  return { op: spec.op, ...(camelKeys(renamed) as Record<string, unknown>) };
}

const optX = z.number().int().optional().describe("Guest pixel X; the pointer moves here first");
const optY = z.number().int().optional().describe("Guest pixel Y; the pointer moves here first");

export function register(r: Registrar, client: ControlClient): void {
  const held = (
    name: string,
    title: string,
    description: string,
    inputSchema: Record<string, z.ZodTypeAny>,
    op: string,
    line: (a: Record<string, unknown>) => string,
    build: (a: Record<string, unknown>) => Record<string, unknown>,
  ) => {
    r.tool("core", name, { title, description, inputSchema, annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false } },
      async (a) => {
        try {
          const reply = await client.call(op, { name: a.name, ...build(a), ...observePayload(a as ObserveArgs, "none") }, actionTimeout(a as ObserveArgs));
          return actionResult(line(a), reply, a.settle_timeout_ms);
        } catch (e) {
          return fail(e);
        }
      });
  };

  const buttonParams = (a: Record<string, unknown>) => ({ button: a.button ?? "left", ...(a.x !== undefined ? { x: a.x, y: a.y } : {}) });
  const buttonLine = (verb: string) => (a: Record<string, unknown>) => `mouse ${a.button ?? "left"} ${verb}${a.x !== undefined ? ` at (${a.x}, ${a.y})` : ""}`;

  held("alcove_mouse_down", "Mouse button down",
    "Press a mouse button and keep it held; moves to (x, y) first when given. Pair with alcove_mouse_up. Reports nothing about the screen unless `observe` is set.",
    { name: vmName, x: optX, y: optY, button: buttonEnum.optional(), ...observeParams },
    "vm.mouse.down", buttonLine("down"), buttonParams);

  held("alcove_mouse_up", "Mouse button up",
    "Release a held mouse button; moves to (x, y) first when given. Reports nothing about the screen unless `observe` is set.",
    { name: vmName, x: optX, y: optY, button: buttonEnum.optional(), ...observeParams },
    "vm.mouse.up", buttonLine("up"), buttonParams);

  held("alcove_key_down", "Key down",
    "Press one key and keep it held, e.g. \"shift\" or \"a\" (a single key name, not a combination). Pair with alcove_key_up. Reports nothing about the screen unless `observe` is set.",
    { name: vmName, key: z.string().min(1).describe("One key name, e.g. shift, ctrl, a, enter"), ...observeParams },
    "vm.key.down", (a) => `key down ${a.key}`, (a) => ({ key: a.key }));

  held("alcove_key_up", "Key up",
    "Release the key held with alcove_key_down. Reports nothing about the screen unless `observe` is set.",
    { name: vmName, key: z.string().min(1).describe("One key name, e.g. shift, ctrl, a, enter"), ...observeParams },
    "vm.key.up", (a) => `key up ${a.key}`, (a) => ({ key: a.key }));

  r.tool("core",
    "alcove_find_text",
    {
      title: "Find text on screen",
      description:
        "Read the screen with OCR. Returns the lines of text that contain `query` (or match it as a regular expression), each with its rectangle and the centre point to click, in guest pixels. Without `query` every recognized line is returned. Prefer this over reading screenshots.",
      inputSchema: {
        name: vmName,
        query: z.string().optional().describe("Text to look for (case-insensitive substring); omit to list all text"),
        regex: z.boolean().optional().describe("Treat `query` as a regular expression"),
        region: regionSchema.optional().describe("Only search this guest-pixel rectangle {x, y, w, h}"),
        languages: z.array(z.string()).optional().describe("Recognition languages (default [\"ko-KR\", \"en-US\"])"),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name, query, regex, region, languages }) => {
      try {
        const reply = await client.call("vm.find_text", {
          name,
          ...(query !== undefined ? { query } : {}),
          ...(regex !== undefined ? { regex } : {}),
          ...(region ? { region } : {}),
          ...(languages ? { languages } : {}),
        }, 60000);
        const matches = (reply.matches as Array<Record<string, unknown>>) ?? [];
        const shown = matches.slice(0, 200).map((m) => `"${m.text}" at (${m.cx}, ${m.cy}) [${m.x},${m.y} ${m.w}x${m.h}]`);
        const more = matches.length > 200 ? [`...${matches.length - 200} more matches not shown; narrow the query or region`] : [];
        const head = matches.length === 0 ? `no matches (${reply.lines ?? 0} lines of text on screen)` : `${matches.length} matches`;
        return text([head, ...shown, ...more].join("\n"), { matches, lines: reply.lines });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("core",
    "alcove_wait_for",
    {
      title: "Wait for a condition",
      description:
        "Wait until one of several conditions becomes true, or the timeout passes. Each condition is an object with a `type` and its fields: " +
        "screen_idle {seconds}, region_changed {region}, text_visible {text, regex?, region?}, text_gone {text, regex?, region?}, " +
        "process_started {process_name}, process_exited {pid | process_name}, file_exists {path}, port_listening {port}, " +
        "log_matches {path, pattern}, job_output_matches {job, pattern}; " +
        "on Windows guests also ui_exists | ui_gone | ui_enabled {ref | window, role, name, name_contains, automation_id, index} (element conditions; here `name` is the element's accessible name), " +
        "ui_text_stable {ref | the same selector fields, quiet_ms (default 1500)} (true once the element's text has not changed for quiet_ms; detail is the final text length; an element that disappears ends the wait with the error text), " +
        "window_title {contains | regex}, event {event, title_contains}. Condition indices are 0-based. Returns the index and type of the first true condition; running out of time is not an error.",
      inputSchema: {
        name: vmName,
        conditions: z.array(z.object({ type: z.string() }).passthrough()).min(1).max(8),
        timeout_s: z.number().min(1).max(600).optional().describe("Default 30"),
        ...observeParams,
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (a) => {
      try {
        const timeout = a.timeout_s ?? 30;
        const reply = await client.call("vm.wait_for", {
          name: a.name,
          conditions: (a.conditions as unknown[]).map(camelKeys),
          timeout,
          ...observePayload(a as ObserveArgs, "none"),
        }, (timeout + 30) * 1000);
        return waitForResult(reply, timeout, a.settle_timeout_ms);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("core",
    "alcove_batch",
    {
      title: "Run several actions in one call",
      description:
        "Run a sequence of input steps against one VM without interruption from other callers, then report the screen once. Each step is an object with `op` (click, move, drag, scroll, type, press_keys, mouse_down, mouse_up, key_down, key_up, wait_idle, wait_for, sleep) and that tool's parameters without `name`; sleep takes `ms` (1-10000). Step indices in the result and in errors are 0-based. Stops at the first failing step. At most 50 steps.",
      inputSchema: {
        name: vmName,
        steps: z.array(z.object({ op: z.string() }).passthrough()).min(1).max(50),
        ...observeParams,
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async (a) => {
      try {
        const sent = a.steps as Array<Record<string, unknown>>;
        const steps = sent.map((s, i) => mapBatchStep(s, i));
        const reply = await client.call("vm.batch", { name: a.name, steps, ...observePayload(a as ObserveArgs, "summary") }, 600000);
        return batchResult(sent, reply, a.settle_timeout_ms);
      } catch (e) {
        return fail(e);
      }
    },
  );
}
