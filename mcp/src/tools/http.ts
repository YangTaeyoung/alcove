// The http toolset: HTTP(S) capture through a proxy with a guest CA, exchange
// listing and reading, and response rules.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { clip, fail, text, vmName, type Registrar } from "../toolkit.js";

type Obj = Record<string, unknown>;

/** `#id time METHOD url -> status (ms, req/res bytes) [rule n]`; tunnel and TLS error rows say so. */
export function exchangeLine(e: Obj): string {
  const kind = e.kind === "tunnel" ? "TUNNEL" : e.kind === "tlsError" ? "TLS-ERROR" : String(e.method ?? "?");
  const status = e.status === undefined || e.status === null || e.status === 0 ? "-" : String(e.status);
  const parts = [`#${e.id} ${e.time} ${kind} ${e.url} -> ${status} (${e.ms ?? 0} ms, ${e.reqBytes ?? 0}/${e.resBytes ?? 0} bytes)`];
  if (e.rule !== undefined && e.rule !== null) parts.push(`[rule ${e.rule}]`);
  if (e.error) parts.push(`error: ${e.error}`);
  return parts.join(" ");
}

/** Headers, a blank line, then the body clipped at 60000 characters with a paging hint. */
export function exchangeDetail(id: number, part: string, r: Obj, offset: number): string {
  const headers = ((r.headers as string[][]) ?? []).map(([k, v]) => `${k}: ${v}`);
  const body = String(r.body ?? "");
  const notes = [`#${id} ${part}: ${r.total ?? body.length} bytes in total, body from ${offset}`];
  if (r.base64 === true) notes.push("body is base64 (not text)");
  if (r.encoding) notes.push(`content encoding ${r.encoding} not decoded`);
  if (r.bodyTruncated === true) notes.push("the capture kept only the first 2 MiB of this body");
  const hint = `use offset ${offset + 60000} and length to read further`;
  return [notes.join("; "), ...headers, "", clip(body, 60000, hint)].join("\n");
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
      }, 180000);
      const lines = [
        `capturing through proxy ${reply.proxy}`,
        `CA certificate ${reply.caInstalled ? "installed in the guest" : "NOT installed in the guest (HTTPS will fail certificate checks)"}`,
        `system proxy ${reply.systemProxySet ? "set" : "not set"}`,
        "apps started with alcove_launch_app or alcove_deploy receive the proxy environment automatically",
      ];
      return text(lines.join("\n"), reply);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("http", "alcove_http_capture_stop", {
    title: "Stop HTTP capture",
    description: "Stop the capture of a VM: restores the guest's proxy settings, removes the CA certificate from the guest and stops the proxy. Returns how many exchanges were captured; read them before stopping, they are discarded.",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async ({ name }) => {
    try {
      const reply = await client.call("vm.http.stop", { name }, 180000);
      return text(`capture stopped; ${reply.exchanges ?? 0} exchanges were captured`, reply);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("http", "alcove_http_requests", {
    title: "List or read captured requests",
    description: "Without id: list the newest captured exchanges (limit, default 50), one per line as `#id time METHOD url -> status (ms, request/response bytes) [rule n]`, filtered by host, path or status; tunnelled hosts appear as TUNNEL rows. With id: read one exchange part (request or response) as headers and body, paged with offset and length. Prefer a list with filters over reading everything.",
    inputSchema: {
      name: vmName,
      id: z.number().int().min(0).optional().describe("Exchange id to read; with it the list filters are ignored"),
      part: z.enum(["request", "response"]).optional().describe("With id: which side to read (default response)"),
      offset: z.number().int().min(0).optional().describe("With id: first body character to return"),
      length: z.number().int().min(1).max(200000).optional().describe("With id: body characters to return (default and maximum 200000)"),
      since: z.number().int().min(0).optional().describe("List only exchanges with an id above this"),
      host: z.string().optional().describe("List only URLs containing this host text"),
      path: z.string().optional().describe("List only URLs containing this path text"),
      status: z.union([z.number().int(), z.string().regex(/^[1-5]xx$/)]).optional().describe("List only this status, e.g. 404, or a class such as 4xx"),
      limit: z.number().int().min(1).max(500).optional().describe("Most exchanges to list (default 50)"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      if (a.id !== undefined) {
        const part = a.part ?? "response";
        const offset = a.offset ?? 0;
        const reply = await client.call("vm.http.request", {
          name: a.name,
          id: a.id,
          part,
          ...(a.offset !== undefined ? { offset: a.offset } : {}),
          ...(a.length !== undefined ? { length: a.length } : {}),
        }, 60000);
        return text(exchangeDetail(a.id, part, reply, offset), reply);
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
      const pending = Number(reply.pending ?? 0);
      const lines = exchanges.length === 0 ? ["no captured exchanges"] : exchanges.map(exchangeLine);
      if (pending > 0) lines.push(`${pending} more request(s) still in flight`);
      if (reply.next !== undefined) lines.push(`next: ${reply.next}`);
      return text(clip(lines.join("\n"), 60000, "narrow with host, path, status or since"), { exchanges, next: reply.next, pending: reply.pending });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("http", "alcove_http_rule", {
    title: "Manage response rules",
    description: "Change what the guest's apps get back during a capture. add (needs match and response) creates a rule: requests matching host/path/method are answered with the given status, headers and body without contacting the server, or delayed (delay_ms alone), or dropped (drop). list shows rules with hit counts; remove (needs rule) deletes one; clear deletes all. Use it to test error handling and timeouts.",
    inputSchema: {
      name: vmName,
      action: z.enum(["add", "list", "remove", "clear"]),
      match: z.object({
        host: z.string().optional().describe("Host glob"),
        path: z.string().optional().describe("Path glob"),
        method: z.string().optional().describe("HTTP method"),
      }).optional().describe("add: which requests the rule applies to"),
      response: z.object({
        status: z.number().int().min(100).max(599).optional().describe("Status code of the canned answer (default 200 when body is given)"),
        headers: z.record(z.string()).optional(),
        body: z.string().optional().describe("Response body; content-type defaults to application/json when it parses as JSON, else text/plain"),
        delay_ms: z.number().int().min(0).max(600000).optional().describe("Wait this long before answering or forwarding"),
        drop: z.boolean().optional().describe("Close the connection without a response"),
        times: z.number().int().min(1).optional().describe("Apply the rule this many times, then it disappears"),
      }).optional().describe("add: what to do with a matching request"),
      rule: z.number().int().min(0).optional().describe("remove: rule id from add or list"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      switch (a.action) {
        case "add": {
          if (!a.match || !a.response) throw new ControlError("the add action needs match and response");
          const { delay_ms, ...rest } = a.response as Obj;
          const action = { ...rest, ...(delay_ms !== undefined ? { delayMs: delay_ms } : {}) };
          const reply = await client.call("vm.http.rule.add", { name: a.name, match: a.match, action }, 60000);
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
