// Rendering of the `observation` object that control action results carry, and
// the parameters that ask for it.
import { z } from "zod";
import { ControlError } from "./control.js";
import { UI_FACTS_BUDGET_MS, toolSentence, type ToolResult } from "./toolkit.js";

export interface TextContent { type: "text"; text: string }
export interface ImageContent { type: "image"; data: string; mimeType: string }

export type ObserveLevel = "none" | "summary" | "diff" | "image" | "ui";

export const DEFAULT_SETTLE_TIMEOUT_MS = 2000;

type Rect = { x: number; y: number; w: number; h: number };

/** An image scale with four decimals. */
export function formatScale(scale: unknown): string {
  return String(Math.round(Number(scale ?? 1) * 10000) / 10000);
}

/** A string as is, an array of strings joined with `; `, any other present value as compact JSON, nothing for an absent or empty one. */
function field(v: unknown): string | undefined {
  if (v === undefined || v === null || v === "") return undefined;
  if (Array.isArray(v) && v.every((i) => typeof i === "string")) {
    const items = (v as string[]).filter((i) => i !== "");
    return items.length === 0 ? undefined : items.join("; ");
  }
  return typeof v === "string" ? v : JSON.stringify(v);
}

/** The text part of an `alcove_screenshot` result. */
export function screenshotCaption(name: string, r: Record<string, unknown>): string {
  const x = Number(r.x ?? 0), y = Number(r.y ?? 0);
  const scale = Number(r.scale ?? 1);
  const sentWidth = Number(r.sentWidth), sentHeight = Number(r.sentHeight);
  const w = r.areaWidth ?? Math.round(sentWidth / scale), h = r.areaHeight ?? Math.round(sentHeight / scale);
  return `${name}: guest frame ${r.width}x${r.height}; image ${sentWidth}x${sentHeight} shows guest (${x},${y}) ${w}x${h} at scale ${formatScale(scale)}; guest = origin + image_pixel / scale`;
}

/**
 * Lines `n: ref Role "name" (x,y WxH)` for the `marks` of a `vm.screenshot` reply, preceded by a newline; empty without marks.
 * With `truncated` a last line says that more elements exist than are marked.
 */
export function marksLegend(marks: unknown, truncated = false): string {
  const more = "more elements exist than are marked; capture a smaller region or read the window with alcove_ui_tree";
  if (!Array.isArray(marks) || marks.length === 0) return truncated ? `\n${more}` : "";
  const lines = (marks as Array<Record<string, unknown>>).map((m) => `${m.n}: ${m.ref} ${m.role} "${m.name ?? ""}" (${m.x},${m.y} ${m.w}x${m.h})`);
  if (truncated) lines.push(more);
  return `\nmarked elements:\n${lines.join("\n")}`;
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
  const uiError = field(o.uiError);
  if (uiError) lines.push(`UI facts missing: ${uiError}`);
  const out: Array<TextContent | ImageContent> = [{ type: "text", text: lines.join("\n") }];
  if (png) out.push({ type: "image", data: png, mimeType: "image/png" });
  return out;
}

/** `eventSeq <n>` for a control reply that carries the event sequence number of its start; nothing otherwise. */
export function eventSeqLine(reply: Record<string, unknown>): string | undefined {
  return typeof reply.eventSeq === "number" ? `eventSeq ${reply.eventSeq}` : undefined;
}

/**
 * Tool result of a tool that changes the guest without observing it: `head`, the reply's `eventSeq` when it has one,
 * then `body`; `structured` with that `eventSeq` as structured content, none when both are absent.
 */
export function changeResult(head: string, reply: Record<string, unknown>, structured?: Record<string, unknown>, body = ""): ToolResult {
  const seq = eventSeqLine(reply);
  const lines = [head, ...(seq ? [seq] : []), ...(body ? [body] : [])];
  const content = seq ? { ...structured, eventSeq: reply.eventSeq } : structured;
  return { content: [{ type: "text", text: lines.join("\n") }], ...(content ? { structuredContent: content } : {}) };
}

/**
 * Tool result: `line`, the reply's `eventSeq` when it has one (also as structured content), then the rendered
 * `observation` of the control reply, when it has one.
 */
export function actionResult(line: string, reply: Record<string, unknown>, settleTimeoutMs?: number): ToolResult {
  const seq = eventSeqLine(reply);
  const head = seq ? `${line}\n${seq}` : line;
  const structured = seq ? { structuredContent: { eventSeq: reply.eventSeq } } : {};
  if (typeof reply.observationError === "string") {
    return { content: [{ type: "text", text: `${head}\nscreen not read after the action: ${toolSentence(reply.observationError)}` }], ...structured };
  }
  const obs = renderObservation(reply.observation as Record<string, unknown> | undefined, settleTimeoutMs);
  if (obs.length === 0) return { content: [{ type: "text", text: head }], ...structured };
  const [first, ...rest] = obs;
  return { content: [{ type: "text", text: `${head}\n${(first as TextContent).text}` }, ...rest], ...structured };
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
      const times = typeof p.failures === "number" && p.failures > 0 ? ` (${p.failures} times in a row)` : "";
      lines.push(`condition ${p.condition} (${p.type}) could not be evaluated: ${p.error}${times}`);
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
  observe: z.enum(["none", "summary", "diff", "image", "ui"]).optional().describe("What to report about the screen after the action: none, summary (settled or not, changed rectangle; on Windows guests also the foreground window, focused element and window events), diff (summary plus an image of the changed area), image (summary plus the full frame) or ui (summary plus the UI tree of the foreground window, Windows guests only)"),
  settle_ms: z.number().int().min(0).max(10000).optional().describe("The screen counts as settled after this long without change (default 300, or settle_timeout_ms when that is lower); at most settle_timeout_ms"),
  settle_timeout_ms: z.number().int().min(100).max(30000).optional().describe("Stop waiting for the screen to settle after this long (default 2000)"),
};

export interface ObserveArgs { observe?: ObserveLevel; settle_ms?: number; settle_timeout_ms?: number }

/** The settle time the control ops use when a request names none, in ms. */
export const DEFAULT_SETTLE_MS = 300;

/**
 * Control params for the observation request; `fallback` applies when the caller gave no level. A settle timeout
 * below the default settle time without a settle time sends that timeout as the settle time; a settle time above the
 * settle timeout throws a ControlError.
 */
export function observePayload(a: ObserveArgs, fallback: ObserveLevel): Record<string, unknown> {
  const p: Record<string, unknown> = { observe: a.observe ?? fallback };
  if (a.settle_ms !== undefined && a.settle_timeout_ms !== undefined && a.settle_ms > a.settle_timeout_ms) {
    throw new ControlError(`settle_ms (${a.settle_ms}) must not exceed settle_timeout_ms (${a.settle_timeout_ms}); lower settle_ms or raise settle_timeout_ms`);
  }
  if (a.settle_ms !== undefined) p.settleMs = a.settle_ms;
  else if (a.settle_timeout_ms !== undefined && a.settle_timeout_ms < DEFAULT_SETTLE_MS) p.settleMs = a.settle_timeout_ms;
  if (a.settle_timeout_ms !== undefined) p.settleTimeoutMs = a.settle_timeout_ms;
  return p;
}

/** `client.call` timeout in ms for an action: `base` plus the settle timeout. */
export function actionTimeout(a: ObserveArgs, base = 60000): number {
  return base + (a.settle_timeout_ms ?? DEFAULT_SETTLE_TIMEOUT_MS);
}

/** The time in ms an observation at the level `a` asks for can take: the settle timeout and the UI facts; 0 at level none or without a level. */
export function observationTime(a: ObserveArgs): number {
  if (a.observe === undefined || a.observe === "none") return 0;
  return (a.settle_timeout_ms ?? DEFAULT_SETTLE_TIMEOUT_MS) + UI_FACTS_BUDGET_MS;
}
