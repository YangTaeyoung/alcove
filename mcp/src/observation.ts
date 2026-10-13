// Rendering of the `observation` object that control action results carry, and
// the parameters that ask for it.
import { z } from "zod";
import type { ToolResult } from "./toolkit.js";

export interface TextContent { type: "text"; text: string }
export interface ImageContent { type: "image"; data: string; mimeType: string }

export type ObserveLevel = "none" | "summary" | "diff" | "image";

export const DEFAULT_SETTLE_TIMEOUT_MS = 2000;

type Rect = { x: number; y: number; w: number; h: number };

/** An image scale with four decimals. */
export function formatScale(scale: unknown): string {
  return String(Math.round(Number(scale ?? 1) * 10000) / 10000);
}

/** A string as is, any other present value as compact JSON, nothing for an absent or empty one. */
function field(v: unknown): string | undefined {
  if (v === undefined || v === null || v === "") return undefined;
  return typeof v === "string" ? v : JSON.stringify(v);
}

/** The text part of an `alcove_screenshot` result. */
export function screenshotCaption(name: string, r: Record<string, unknown>): string {
  const x = Number(r.x ?? 0), y = Number(r.y ?? 0);
  const scale = Number(r.scale ?? 1);
  const sentWidth = Number(r.sentWidth), sentHeight = Number(r.sentHeight);
  const w = r.areaWidth, h = r.areaHeight;
  return `${name}: guest frame ${r.width}x${r.height}; image ${sentWidth}x${sentHeight} shows guest (${x},${y}) ${w}x${h} at scale ${formatScale(scale)}; guest = origin + image_pixel / scale`;
}

/** Text and optional image content for an observation object from the control protocol. */
export function renderObservation(o: Record<string, unknown> | undefined, settleTimeoutMs = DEFAULT_SETTLE_TIMEOUT_MS): Array<TextContent | ImageContent> {
  if (!o) return [];
  const lines: string[] = [];
  lines.push(o.settled === false ? `screen still changing after ${settleTimeoutMs} ms` : "screen settled");
  const changed = o.changed as Rect | undefined;
  if (changed) {
    const pct = (Number(o.changedFraction ?? 0) * 100).toFixed(1);
    lines.push(`changed (${changed.x},${changed.y}) ${changed.w}x${changed.h} = ${pct}% of the frame`);
  } else {
    lines.push("nothing changed");
  }
  const png = typeof o.png === "string" ? o.png : undefined;
  const rect = o.imageRect as Rect | undefined;
  if (png && rect) {
    lines.push(`image shows guest (${rect.x},${rect.y}) ${rect.w}x${rect.h} at scale ${formatScale(o.imageScale)}`);
  }
  const foreground = field(o.foreground);
  if (foreground) lines.push(`foreground: ${foreground}`);
  const focused = field(o.focused);
  if (focused) lines.push(`focused: ${focused}`);
  const events = field(o.events);
  if (events) lines.push(`events: ${events}`);
  const tree = field(o.tree);
  if (tree) lines.push(tree);
  const out: Array<TextContent | ImageContent> = [{ type: "text", text: lines.join("\n") }];
  if (png) out.push({ type: "image", data: png, mimeType: "image/png" });
  return out;
}

/** Tool result: `line` followed by the rendered `observation` of the control reply, when it has one. */
export function actionResult(line: string, reply: Record<string, unknown>, settleTimeoutMs?: number): ToolResult {
  if (typeof reply.observationError === "string") {
    return { content: [{ type: "text", text: `${line}\nscreen not read after the action: ${reply.observationError}` }] };
  }
  const obs = renderObservation(reply.observation as Record<string, unknown> | undefined, settleTimeoutMs);
  if (obs.length === 0) return { content: [{ type: "text", text: line }] };
  const [head, ...rest] = obs;
  return { content: [{ type: "text", text: `${line}\n${(head as TextContent).text}` }, ...rest] };
}

/** Tool result of `alcove_wait_for` for a `vm.wait_for` reply. */
export function waitForResult(reply: Record<string, unknown>, timeoutS: number, settleTimeoutMs?: number): ToolResult {
  const matched = Number(reply.matched ?? -1);
  const lines: string[] = [];
  if (matched >= 0) {
    const d = reply.detail;
    const detail = d === undefined || d === null ? "" : `: ${typeof d === "string" ? d : JSON.stringify(d)}`;
    lines.push(`matched condition ${matched} (${reply.type ?? "?"}) after ${reply.waited} s${detail}`);
  } else {
    const d = reply.detail;
    lines.push(d === undefined || d === null
      ? `no condition matched within ${timeoutS} s`
      : `no condition matched: ${typeof d === "string" ? d : JSON.stringify(d)} (after ${reply.waited} s)`);
    for (const p of (reply.problems as Array<Record<string, unknown>> | undefined) ?? []) {
      lines.push(`condition ${p.condition} (${p.type}) could not be evaluated: ${p.error} (${p.failures} times in a row)`);
    }
  }
  return actionResult(lines.join("\n"), reply, settleTimeoutMs);
}

/** Tool result of `alcove_batch` for a `vm.batch` reply to the `sent` steps. */
export function batchResult(sent: Array<Record<string, unknown>>, reply: Record<string, unknown>, settleTimeoutMs?: number): ToolResult {
  const failedStep = typeof reply.failedStep === "number" ? reply.failedStep : undefined;
  const done = Number(reply.completed ?? (reply.results as unknown[] | undefined)?.length ?? 0);
  const lines: string[] = [];
  for (let i = 0; i < done && i < sent.length; i++) lines.push(`ok ${i} ${sent[i].op}`);
  if (failedStep !== undefined) lines.push(`FAILED ${failedStep} ${sent[failedStep]?.op}: ${reply.error ?? "step failed"}`);
  const result = actionResult(lines.join("\n"), reply, settleTimeoutMs);
  return failedStep !== undefined ? { ...result, isError: true } : result;
}

export const observeParams = {
  observe: z.enum(["none", "summary", "diff", "image"]).optional().describe("What to report about the screen after the action: none, summary (settled or not, changed rectangle), diff (summary plus an image of the changed area) or image (summary plus the full frame)"),
  settle_ms: z.number().int().min(0).max(10000).optional().describe("The screen counts as settled after this long without change (default 300)"),
  settle_timeout_ms: z.number().int().min(0).max(30000).optional().describe("Stop waiting for the screen to settle after this long (default 2000)"),
};

export interface ObserveArgs { observe?: ObserveLevel; settle_ms?: number; settle_timeout_ms?: number }

/** Control params for the observation request; `fallback` applies when the caller gave no level. */
export function observePayload(a: ObserveArgs, fallback: ObserveLevel): Record<string, unknown> {
  const p: Record<string, unknown> = { observe: a.observe ?? fallback };
  if (a.settle_ms !== undefined) p.settleMs = a.settle_ms;
  if (a.settle_timeout_ms !== undefined) p.settleTimeoutMs = a.settle_timeout_ms;
  return p;
}

/** `client.call` timeout in ms for an action: `base` plus the settle timeout. */
export function actionTimeout(a: ObserveArgs, base = 60000): number {
  return base + (a.settle_timeout_ms ?? DEFAULT_SETTLE_TIMEOUT_MS);
}
