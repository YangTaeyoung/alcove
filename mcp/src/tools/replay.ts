// The replay toolset: scripts saved from a recording and replayed without a model.
import fs from "node:fs";
import { z } from "zod";
import { type ControlClient } from "../control.js";
import { fail, text, SCRIPT_RUN_TIMEOUT_MS, SCRIPT_SAVE_TIMEOUT_MS, MODEL_IMAGE_MAX_WIDTH, type Registrar, type ToolResult } from "../toolkit.js";

type Obj = Record<string, unknown>;

/** Whether a variable of this name holds a secret: its name contains password, key, token or secret. */
export function isSecretName(name: string): boolean {
  const lowered = name.toLowerCase();
  return ["password", "key", "token", "secret"].some((part) => lowered.includes(part));
}

/** `variables: name=value, ...` in name order with `<hidden>` for secrets; empty without variables. */
export function variablesLine(variables: Record<string, string>): string[] {
  const names = Object.keys(variables).sort();
  if (names.length === 0) return [];
  return [`variables: ${names.map((n) => `${n}=${isSecretName(n) ? "<hidden>" : variables[n]}`).join(", ")}`];
}

/** A secret value this long is also hidden where it occurs inside a longer string. */
const MIN_SUBSTRING_SECRET = 8;

/** `value` with `<hidden>` in place of each string that equals the value of a secret variable and of each occurrence of a value of 8 or more characters inside a longer string; other values are kept. */
export function maskValue<T>(value: T, variables: Record<string, string>): T {
  const secrets = Object.entries(variables)
    .filter(([n, v]) => isSecretName(n) && v !== "")
    .map(([, v]) => v)
    .sort((a, b) => b.length - a.length);
  if (secrets.length === 0) return value;
  const walk = (item: unknown): unknown => {
    if (typeof item === "string") {
      if (secrets.includes(item)) return "<hidden>";
      return secrets.filter((v) => v.length >= MIN_SUBSTRING_SECRET).reduce((out, v) => out.split(v).join("<hidden>"), item);
    }
    if (Array.isArray(item)) return item.map(walk);
    if (item && typeof item === "object") return Object.fromEntries(Object.entries(item).map(([k, v]) => [k, walk(v)]));
    return item;
  };
  return walk(value) as T;
}

/** `s` hidden like `maskValue`. */
export function maskSecrets(s: string, variables: Record<string, string>): string {
  return maskValue(s, variables);
}

/** `ok` or `FAIL`, number, label (the op without one), milliseconds and `[fallback]`, `[alt selector]`, `[positional]`; then the warning and `PASSED` or `FAILED`. */
export function runLines(unmasked: Obj, variables: Record<string, string>): string[] {
  const reply = maskValue(unmasked, variables);
  const out: string[] = [];
  for (const entry of (reply.steps as Obj[] | undefined) ?? []) {
    const ok = entry.ok === true;
    const markers = [
      entry.usedFallback === true ? " [fallback]" : "",
      entry.usedAltSelector === true ? " [alt selector]" : "",
      entry.positional === true ? " [positional]" : "",
    ].join("");
    const milliseconds = Math.round(Number(entry.seconds ?? 0) * 1000);
    out.push(`${ok ? "ok  " : "FAIL"} ${entry.step} ${entry.label ?? entry.op ?? "step"} ${milliseconds} ms${markers}`);
    if (!ok && typeof entry.error === "string") out.push(`     ${entry.error}`);
  }
  if (typeof reply.error === "string") out.push(`error: ${reply.error}`);
  if (typeof reply.warning === "string") out.push(`warning: ${reply.warning}`);
  const seconds = Number(reply.seconds ?? 0).toFixed(1);
  const count = Number(reply.stepsRun ?? 0);
  out.push(
    reply.passed === true
      ? `PASSED: ${count} step${count === 1 ? "" : "s"} in ${seconds} s`
      : `FAILED: ${typeof reply.failedStep === "number" ? `step ${reply.failedStep} failed` : "the run stopped"} after ${seconds} s`,
  );
  return out;
}

/** `saved <path>`, the step count, the skipped trace lines when there are any, then each warning on its own line. */
export function saveLines(reply: Obj): string[] {
  const steps = Number(reply.steps ?? 0);
  const skipped = Number(reply.skipped ?? 0);
  return [
    `saved ${reply.path}`,
    `${steps} step${steps === 1 ? "" : "s"}`,
    ...(skipped > 0 ? [`skipped ${skipped} trace line${skipped === 1 ? "" : "s"}`] : []),
    ...((reply.warnings as string[] | undefined) ?? []).map((w) => `warning: ${w}`),
  ];
}

/** The `variables` defaults of the script file at `path`; empty when it cannot be read as a script. */
export function scriptDefaults(path: string): Record<string, string> {
  try {
    const variables = (JSON.parse(fs.readFileSync(path, "utf8")) as { variables?: unknown }).variables;
    if (!variables || typeof variables !== "object") return {};
    return Object.fromEntries(Object.entries(variables).filter((e): e is [string, string] => typeof e[1] === "string"));
  } catch {
    return {};
  }
}

export function register(r: Registrar, client: ControlClient): void {
  r.tool("replay", "alcove_script_save", {
    title: "Save a recording as a script",
    description: "Turn the trace of a recording (alcove_record_start / alcove_record_stop) into a script file on the Mac that alcove_script_run replays without a model. A script is a JSON file of steps; each step is one control operation with its expectations, and typed text is recorded as written. Give `dir` (the recording directory those tools return) or `trace` (the path of a trace.jsonl), not both; `from` and `to` keep only the trace lines with a seq in that range. Clicks and typing are recorded by selector (role, name, automation id) with the coordinates kept as a fallback; clicks on something with no element stay coordinates. A step whose selector picks \"number k of n\" equal elements is positional and replays whatever is at that position. Text typed into a password field is never stored: the script gets a variable (`password`, `password2`, ...) without a default, which alcove_script_run needs in `variables`. Returns the path, the number of steps, the trace lines skipped and every warning; read the warnings before relying on the script. Fails when `path` exists unless overwrite is true.",
    inputSchema: {
      dir: z.string().optional().describe("Recording directory that alcove_record_start returned (holds trace.jsonl); give this or trace"),
      trace: z.string().optional().describe("Absolute path of a trace.jsonl; give this or dir"),
      path: z.string().min(1).describe("Absolute path of the script to write, ending in .json; the folder is created when its parent exists"),
      name: z.string().optional().describe("VM the script runs against (default: the VM of the trace)"),
      from: z.number().int().min(1).optional().describe("First trace seq to use (default: the start)"),
      to: z.number().int().min(1).optional().describe("Last trace seq to use (default: the end)"),
      overwrite: z.boolean().optional().describe("Replace an existing file at path (default false)"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, async (a): Promise<ToolResult> => {
    try {
      const reply = await client.call("script.save", {
        ...(a.dir !== undefined ? { dir: a.dir } : {}),
        ...(a.trace !== undefined ? { trace: a.trace } : {}),
        path: a.path,
        ...(a.name !== undefined ? { name: a.name } : {}),
        ...(a.from !== undefined ? { from: a.from } : {}),
        ...(a.to !== undefined ? { to: a.to } : {}),
        ...(a.overwrite !== undefined ? { overwrite: a.overwrite } : {}),
      }, SCRIPT_SAVE_TIMEOUT_MS);
      return text(saveLines(reply).join("\n"), { path: reply.path, steps: reply.steps, skipped: reply.skipped, warnings: reply.warnings ?? [] });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("replay", "alcove_script_run", {
    title: "Replay a script",
    description: "Replay a script file (made by alcove_script_save) on the VM without a model: it runs the steps in order, checks each step's expectations and stops at the first failure. It sends real mouse and keyboard input to the guest and, with `snapshot`, first restores that snapshot, which discards the guest's current state. Returns one line per step (ok or FAIL, number, label, milliseconds; markers: `fallback` = the element was not found and the recorded coordinates were clicked, `alt selector` = the element was found by its second selector, `positional` = the selector picks \"whatever is at that position\" and nothing checks that it is the same element), the warnings and a final PASSED or FAILED line. A failed run also returns the screenshot taken at that moment. Variables of the script without a default, such as the `password` that alcove_script_save leaves for text typed into password fields, must be passed in `variables`; a variable whose name contains password, key, token or secret is never printed. Pass `name` when this session holds a lease on the VM so the run uses it.",
    inputSchema: {
      path: z.string().min(1).describe("Absolute path of the script file on the Mac"),
      variables: z.record(z.string()).optional().describe("Values for ${name} in the script, overriding its defaults; required for variables without a default"),
      snapshot: z.string().optional().describe("Snapshot to restore before step 1 (see alcove_snapshot_list)"),
      name: z.string().optional().describe("VM to run against (default: the VM named in the script)"),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  }, async (a): Promise<ToolResult> => {
    const passed = (a.variables ?? {}) as Record<string, string>;
    const variables = { ...scriptDefaults(a.path), ...passed };
    try {
      const reply = await client.call("script.run", {
        path: a.path,
        ...(a.name !== undefined ? { name: a.name } : {}),
        ...(a.variables !== undefined ? { variables: a.variables } : {}),
        ...(a.snapshot !== undefined ? { snapshot: a.snapshot } : {}),
        maxWidth: MODEL_IMAGE_MAX_WIDTH,
      }, SCRIPT_RUN_TIMEOUT_MS);
      const failure = reply.failure as Obj | undefined;
      const lines = [...variablesLine(passed), ...runLines(reply, variables)];
      const structured: Obj = maskValue({
        passed: reply.passed,
        stepsRun: reply.stepsRun,
        seconds: reply.seconds,
        steps: reply.steps,
        ...(reply.failedStep !== undefined ? { failedStep: reply.failedStep } : {}),
        ...(reply.error !== undefined ? { error: reply.error } : {}),
        ...(reply.warning !== undefined ? { warning: reply.warning } : {}),
        ...(failure ? { failure: { width: failure.width, height: failure.height } } : {}),
      }, variables);
      const result = text(lines.join("\n"), structured);
      if (typeof failure?.png === "string") result.content.push({ type: "image", data: failure.png, mimeType: "image/png" });
      return result;
    } catch (e) {
      const failed = fail(e);
      const sentence = maskSecrets((failed.content[0] as { text: string }).text, variables);
      const timedOut = /^script\.run timed out after [^;]*/.exec(sentence);
      return { ...failed, content: [{ type: "text", text: timedOut ? `${timedOut[0]}. ${RUN_TIMEOUT_ADVICE}` : sentence }] };
    }
  });
}

const RUN_TIMEOUT_ADVICE = "The run may still be going in the guest and holding the VM's lease; look with alcove_vm_status or alcove_screenshot, wait for it to end, then run the script again.";
