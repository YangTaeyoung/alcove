// Rendering of the `observation` object that control action results carry, and
// the parameters that ask for it.
import { z } from "zod";
import type { ToolResult } from "./toolkit.js";

export interface TextContent { type: "text"; text: string }
export interface ImageContent { type: "image"; data: string; mimeType: string }

export type ObserveLevel = "none" | "summary" | "diff" | "image";

export const DEFAULT_SETTLE_TIMEOUT_MS = 2000;

type Rect = { x: number; y: number; w: number; h: number };

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
    const scale = Math.round(Number(o.imageScale ?? 1) * 1000) / 1000;
    lines.push(`image shows guest (${rect.x},${rect.y}) ${rect.w}x${rect.h} at scale ${scale}`);
  }
  if (typeof o.foreground === "string" && o.foreground) lines.push(`foreground: ${o.foreground}`);
  if (typeof o.focused === "string" && o.focused) lines.push(`focused: ${o.focused}`);
  if (typeof o.events === "string" && o.events) lines.push(`events: ${o.events}`);
  if (typeof o.tree === "string" && o.tree) lines.push(o.tree);
  const out: Array<TextContent | ImageContent> = [{ type: "text", text: lines.join("\n") }];
  if (png) out.push({ type: "image", data: png, mimeType: "image/png" });
  return out;
}

/** Tool result: `line` followed by the rendered `observation` of the control reply, when it has one. */
export function actionResult(line: string, reply: Record<string, unknown>, settleTimeoutMs?: number): ToolResult {
  const obs = renderObservation(reply.observation as Record<string, unknown> | undefined, settleTimeoutMs);
  if (obs.length === 0) return { content: [{ type: "text", text: line }] };
  const [head, ...rest] = obs;
  return { content: [{ type: "text", text: `${line}\n${(head as TextContent).text}` }, ...rest] };
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
