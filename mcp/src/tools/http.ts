// The http toolset: HTTP(S) capture through a proxy with a guest CA, exchange
// listing and reading, and response rules.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { clip, fail, text, vmName, withoutEnvelope, type Registrar } from "../toolkit.js";

type Obj = Record<string, unknown>;

/** Longest `vm.http.start` runs before it answers, in ms: a cleanup after an earlier capture that holds the VM (three guest recipes, 30 s each), the wait for guest tools (31 s), the proxy becoming ready (15 s) and taking its settings (30 s), the CA copy (24 s), two guest recipes (30 s each), and after a failed last step the undo (three recipes, 15 s each) and the end of the proxy (6 s). */
export const START_WORST_MS = 301000;
/** Longest `vm.http.stop` runs before it answers, in ms: a cleanup that holds the VM (90 s), the exchange count (30 s), the wait for guest tools (31 s), three guest recipes (30 s each) and the end of the proxy (6 s). */
export const STOP_WORST_MS = 247000;
/** What `client.call` waits beyond the longest run of a capture op, in ms. */
export const CAPTURE_MARGIN_MS = 15000;

/** `#id time METHOD url -> status (ms, req/res bytes) [rule n]`; tunnel and TLS error rows say so, and a row whose bodies the capture dropped says `[bodies dropped]`. */
export function exchangeLine(e: Obj): string {
  const kind = e.kind === "tunnel" ? "TUNNEL" : e.kind === "tlsError" ? "TLS-ERROR" : String(e.method ?? "?");
  const status = e.status === undefined || e.status === null || e.status === 0 ? "-" : String(e.status);
  const parts = [`#${e.id} ${e.time} ${kind} ${e.url} -> ${status} (${e.ms ?? 0} ms, ${e.reqBytes ?? 0}/${e.resBytes ?? 0} bytes)`];
  if (e.rule !== undefined && e.rule !== null) parts.push(`[rule ${e.rule}]`);
  if (e.bodyDropped === true) parts.push("[bodies dropped]");
  if (e.error) parts.push(`error: ${e.error}`);
  return parts.join(" ");
}

/** `in flight: time METHOD url (ms so far, req/res bytes) [rule n]` for a request or tunnel that has not finished. */
export function pendingLine(e: Obj): string {
  const kind = e.kind === "tunnel" ? "TUNNEL" : String(e.method ?? "?");
  const rule = e.rule !== undefined && e.rule !== null ? ` [rule ${e.rule}]` : "";
  return `in flight: ${e.time} ${kind} ${e.url} (${e.ms ?? 0} ms so far, ${e.reqBytes ?? 0}/${e.resBytes ?? 0} bytes)${rule}`;
}

const DETAIL_CHARS = 60000;
const BASE64_BYTES_PER_PAGE = 45000;

/** A notes line, headers, trailers as `trailer name: value`, a blank line, then the body clipped at 60000 characters; the paging hint counts bytes of the part. */
export function exchangeDetail(id: number, part: string, r: Obj, offset: number): string {
  const headers = ((r.headers as string[][]) ?? []).map(([k, v]) => `${k}: ${v}`);
  const trailers = ((r.trailers as string[][]) ?? []).map(([k, v]) => `trailer ${k}: ${v}`);
  const body = String(r.body ?? "");
  const base64 = r.base64 === true;
  const total = Number(r.total ?? 0);
  const notes = [`#${id} ${part}: ${total} bytes in total, body from byte ${offset}`];
  if (base64) notes.push("body is base64 (not text)");
  if (r.encoding) notes.push(`content encoding ${r.encoding} not decoded`);
  if (r.bodyTruncated === true) notes.push("the capture kept only the first 2 MiB of this body");
  if (r.bodyDropped === true) notes.push("the capture dropped the bodies of this exchange to make room for newer ones");
  if (r.headersTruncated === true) notes.push("the capture left out the header and trailer pairs of this exchange beyond 64 KiB");
  const returned = base64 ? Buffer.from(body, "base64").length : Buffer.byteLength(body, "utf8");
  let hint = "";
  if (body.length > DETAIL_CHARS) {
    hint = base64
      ? `offsets and length count bytes; use offset ${offset + BASE64_BYTES_PER_PAGE} and length ${BASE64_BYTES_PER_PAGE} to read further`
      : `offsets count bytes; use offset ${offset + Buffer.byteLength(body.slice(0, DETAIL_CHARS), "utf8")} to read further`;
  } else if (offset + returned < total) {
    hint = `offsets count bytes; use offset ${offset + returned} to read further`;
  }
  const shown = body.length > DETAIL_CHARS ? clip(body, DETAIL_CHARS, hint) : body;
  const tail = body.length <= DETAIL_CHARS && hint ? `\n...[more; ${hint}]` : "";
  return [notes.join("; "), ...headers, ...trailers, "", shown + tail].join("\n");
}

function ruleLine(rule: Obj): string {
  const remaining = rule.remaining !== undefined ? `, ${rule.remaining} left` : "";
  return `rule ${rule.id}: match ${JSON.stringify(rule.match)} action ${JSON.stringify(rule.action)} (${rule.hits ?? 0} hits${remaining})`;
}

export function register(r: Registrar, client: ControlClient): void {
  r.tool("http", "alcove_http_capture_start", {
    title: "Start HTTP capture",
    description: "Start capturing the HTTP and HTTPS traffic of a VM through a proxy on the Mac. Installs the proxy's CA certificate in the guest and, unless system_proxy is false, sets the guest's system proxy. Apps started afterwards with alcove_launch_app or alcove_deploy receive the proxy environment automatically; apps that were already running keep their old settings. Read the traffic with alcove_http_requests, stop with alcove_http_capture_stop.",
    inputSchema: {
      name: vmName,
      hosts: z.array(z.string()).optional().describe("Host globs to intercept, e.g. [\"api.example.com\", \"*.corp.net\"]; other hosts are tunnelled and only counted (default: intercept all)"),
      secrets: z.boolean().optional().describe("Keep Authorization, Cookie and API-key header values readable (default false: stored as <redacted n chars>)"),
      bodies: z.boolean().optional().describe("Keep request and response bodies (default true)"),
      system_proxy: z.boolean().optional().describe("Also set the guest's system proxy so apps without proxy environment variables are captured (default true)"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.http.start", {
        name: a.name,
        ...(a.hosts !== undefined ? { hosts: a.hosts } : {}),
        ...(a.secrets !== undefined ? { secrets: a.secrets } : {}),
        ...(a.bodies !== undefined ? { bodies: a.bodies } : {}),
        ...(a.system_proxy !== undefined ? { systemProxy: a.system_proxy } : {}),
      }, START_WORST_MS + CAPTURE_MARGIN_MS);
      const lines = [
        `capturing through proxy ${reply.proxy}`,
        `CA certificate ${reply.caInstalled ? "installed in the guest" : "NOT installed in the guest (HTTPS will fail certificate checks)"}`,
        `system proxy ${reply.systemProxySet ? "set" : "not set"}`,
        "apps started with alcove_launch_app or alcove_deploy receive the proxy environment automatically",
        "a process started through alcove_exec does not: set these variables in its environment yourself",
        ...Object.entries((reply.env as Record<string, unknown>) ?? {}).map(([k, v]) => `${k}=${v}`),
      ];
      if (reply.guestCAPath) lines.push(`CA file in the guest: ${reply.guestCAPath}`);
      if (reply.warning) lines.push(`warning: ${reply.warning}`);
      return text(lines.join("\n"), withoutEnvelope(reply));
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("http", "alcove_http_capture_stop", {
    title: "Stop HTTP capture",
    description: "Stop the capture of a VM: restores the guest's proxy settings, removes the CA certificate from the guest and stops the proxy. Returns how many exchanges were captured; read them with alcove_http_requests before stopping, they are discarded. To empty the list and keep capturing use alcove_http_requests with clear. On a VM without a capture it clears what an earlier capture left in the guest.",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async ({ name }) => {
    try {
      const reply = await client.call("vm.http.stop", { name }, STOP_WORST_MS + CAPTURE_MARGIN_MS);
      const lines = [reply.staleCleared === true
        ? "no capture was running; what an earlier capture left in the guest (proxy settings, CA certificate) was cleared"
        : `capture stopped; ${reply.exchanges ?? 0} exchanges were captured`];
      if (reply.warning) lines.push(`warning: ${reply.warning}`);
      return text(lines.join("\n"), withoutEnvelope(reply));
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("http", "alcove_http_requests", {
    title: "List or read captured requests",
    description: "Without id: list the newest captured exchanges (limit, default 50), one per line as `#id time METHOD url -> status (ms, request/response bytes) [rule n]`, filtered by host, path or status; tunnelled hosts appear as TUNNEL rows and requests that have not finished as `in flight:` rows. With id: read one exchange part (request or response) as headers and body, paged with offset and length, which count bytes of that part (length defaults to 60000, at most 200000; the text shows at most 60000 characters per call and ends with the offset to continue from). Prefer a list with filters over reading everything. With clear: true (alone) the captured exchanges are discarded and capture continues.",
    inputSchema: {
      name: vmName,
      id: z.number().int().min(0).optional().describe("Exchange id to read; with it the list filters are ignored"),
      part: z.enum(["request", "response"]).optional().describe("With id: which side to read (default response)"),
      offset: z.number().int().min(0).optional().describe("With id: first body byte to return (default 0)"),
      length: z.number().int().min(1).max(200000).optional().describe("With id: body bytes to return (default 60000, maximum 200000)"),
      since: z.number().int().min(0).optional().describe("List only exchanges with an id above this"),
      host: z.string().optional().describe("List only URLs containing this host text"),
      path: z.string().optional().describe("List only URLs containing this path text"),
      status: z.union([z.number().int(), z.string().regex(/^[1-5]xx$/)]).optional().describe("List only this status, e.g. 404, or a class such as 4xx"),
      limit: z.number().int().min(1).max(500).optional().describe("Most exchanges to list (default 50)"),
      clear: z.boolean().optional().describe("Discard all captured exchanges; give no id or filters"),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      if (a.clear) {
        const others = ["id", "part", "offset", "length", "since", "host", "path", "status", "limit"] as const;
        if (others.some((k) => a[k] !== undefined)) throw new ControlError("clear takes no id or filters; call it on its own");
        await client.call("vm.http.clear", { name: a.name }, 60000);
        return text("captured exchanges cleared");
      }
      if (a.id !== undefined) {
        const part = a.part ?? "response";
        const offset = a.offset ?? 0;
        const reply = await client.call("vm.http.request", {
          name: a.name,
          exchange: a.id,
          part,
          ...(a.offset !== undefined ? { offset: a.offset } : {}),
          length: a.length ?? DETAIL_CHARS,
        }, 60000);
        return text(exchangeDetail(a.id, part, reply, offset), {
          total: reply.total, bodyTruncated: reply.bodyTruncated, base64: reply.base64, encoding: reply.encoding, bodyDropped: reply.bodyDropped,
          headersTruncated: reply.headersTruncated,
        });
      }
      const reply = await client.call("vm.http.requests", {
        name: a.name,
        ...(a.since !== undefined ? { since: a.since } : {}),
        ...(a.host !== undefined ? { host: a.host } : {}),
        ...(a.path !== undefined ? { path: a.path } : {}),
        ...(a.status !== undefined ? { status: a.status } : {}),
        ...(a.limit !== undefined ? { limit: a.limit } : {}),
      }, 60000);
      const exchanges = (reply.exchanges as Obj[]) ?? [];
      const pending = Array.isArray(reply.pending) ? (reply.pending as Obj[]) : [];
      const lines = exchanges.length === 0 ? ["no captured exchanges"] : exchanges.map(exchangeLine);
      lines.push(...pending.map(pendingLine));
      if (reply.next !== undefined) lines.push(`next: ${reply.next}`);
      return text(clip(lines.join("\n"), 60000, "narrow with host, path, status or since"), { exchanges, next: reply.next, pending: reply.pending });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("http", "alcove_http_rule", {
    title: "Manage response rules",
    description: "Change what the guest's apps get back during a capture. add (needs response; match defaults to all requests) creates a rule: requests matching host/path/method are answered with the given status, headers and body without contacting the server, or delayed (delay_ms alone), or dropped (drop). list shows rules with hit counts; remove (needs rule) deletes one; clear deletes all. Use it to test error handling and timeouts.",
    inputSchema: {
      name: vmName,
      action: z.enum(["add", "list", "remove", "clear"]),
      match: z.object({
        host: z.string().optional().describe("Host glob"),
        path: z.string().optional().describe("Path glob"),
        method: z.string().optional().describe("HTTP method"),
      }).optional().describe("add: which requests the rule applies to"),
      response: z.object({
        status: z.number().int().min(200).max(599).optional().describe("Status code of the canned answer, 200 to 599 (default 200 when body is given)"),
        headers: z.record(z.string()).optional().describe("Response headers as {name: value}; they replace defaults such as content-type"),
        body: z.string().optional().describe("Response body; content-type defaults to application/json when it parses as JSON, else text/plain"),
        delay_ms: z.number().int().min(0).max(600000).optional().describe("Wait this long before answering or forwarding"),
        drop: z.boolean().optional().describe("Close the connection without a response"),
        times: z.number().int().min(1).optional().describe("Apply the rule this many times; after that it no longer applies and stays listed with 0 left until removed"),
      }).optional().describe("add: what to do with a matching request"),
      rule: z.number().int().min(0).optional().describe("remove: rule id from add or list"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      switch (a.action) {
        case "add": {
          const resp = (a.response ?? {}) as Obj;
          if (resp.status === undefined && resp.body === undefined && resp.delay_ms === undefined && resp.drop === undefined) {
            throw new ControlError("pass response with at least one of status, body, delay_ms, drop");
          }
          const { delay_ms, ...rest } = resp;
          const action = { ...rest, ...(delay_ms !== undefined ? { delayMs: delay_ms } : {}) };
          const reply = await client.call("vm.http.rule.add", { name: a.name, match: a.match ?? {}, action }, 60000);
          return text(`rule ${reply.rule} added`, { rule: reply.rule });
        }
        case "list": {
          const reply = await client.call("vm.http.rule.list", { name: a.name }, 60000);
          const rules = (reply.rules as Obj[]) ?? [];
          return text(rules.length === 0 ? "no rules" : rules.map(ruleLine).join("\n"), { rules });
        }
        case "remove": {
          if (a.rule === undefined) throw new ControlError("the remove action needs rule");
          await client.call("vm.http.rule.remove", { name: a.name, rule: a.rule }, 60000);
          return text(`rule ${a.rule} removed`);
        }
        default: {
          await client.call("vm.http.rule.clear", { name: a.name }, 60000);
          return text("all rules removed");
        }
      }
    } catch (e) {
      return fail(e);
    }
  });
}
