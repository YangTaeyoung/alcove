#!/usr/bin/env node
// alcove-mcp: an MCP server (stdio) exposing Alcove virtual machines to coding
// agents. Tools map onto the Alcove control protocol (docs/control-protocol.md).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { ControlClient, ControlError } from "./control.js";

const client = new ControlClient();
const server = new McpServer({ name: "alcove-mcp-server", version: "0.1.0" });

type ToolResult = { content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }>; isError?: boolean; structuredContent?: Record<string, unknown> };

function text(t: string, structured?: Record<string, unknown>): ToolResult {
  return { content: [{ type: "text", text: t }], ...(structured ? { structuredContent: structured } : {}) };
}

function fail(e: unknown): ToolResult {
  const msg = e instanceof ControlError ? e.message : `unexpected error: ${String(e)}`;
  return { content: [{ type: "text", text: msg }], isError: true };
}

const vmName = z.string().describe("VM name as shown by alcove_list_vms, e.g. \"Windows 11\"");

server.registerTool(
  "alcove_list_vms",
  {
    title: "List Alcove VMs",
    description:
      "List the virtual machines managed by Alcove with their guest OS (windows/linux), state (stopped, running, paused, suspended...) and, when known, screen size. Call this first to learn VM names.",
    inputSchema: {},
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async () => {
    try {
      const r = await client.call("vm.list");
      const vms = (r.vms as Array<Record<string, unknown>>) ?? [];
      const lines = vms.map((v) => `- ${v.name} (${v.guestOS}): ${v.state}${v.width ? `, ${v.width}x${v.height}` : ""}${v.suspended ? ", suspended to disk" : ""}`);
      return text(lines.length ? lines.join("\n") : "No VMs. Create one in the Alcove app or with `alcovectl create`.", { vms });
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_vm_status",
  {
    title: "VM status",
    description: "Detailed status of one VM: state, screen size, whether the guest tools (agent) are connected and which capabilities they offer (exec, clipboard, files).",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ name }) => {
    try {
      const r = await client.call("vm.status", { name });
      const { ok: _ok, id: _id, ...rest } = r;
      return text(JSON.stringify(rest, null, 2), rest as Record<string, unknown>);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_start_vm",
  {
    title: "Start VM",
    description:
      "Boot a VM (or resume it from suspend). By default waits until the guest tools connect (the OS has booted and a user is logged in), up to wait_timeout_s; when the guest has no tools it returns after the wait and you should use alcove_wait_idle / screenshots to judge readiness.",
    inputSchema: {
      name: vmName,
      wait_for_tools: z.boolean().optional().describe("Wait for the guest tools to connect (default true)"),
      wait_timeout_s: z.number().int().min(0).max(900).optional().describe("How long to wait for the guest (default 180)"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async ({ name, wait_for_tools, wait_timeout_s }) => {
    try {
      const r = await client.call("vm.start", { name }, 300000);
      const wait = wait_for_tools ?? true;
      const deadline = Date.now() + (wait_timeout_s ?? 180) * 1000;
      let tools = false;
      if (wait) {
        while (Date.now() < deadline) {
          const st = await client.call("vm.status", { name }, 60000);
          if (st.tools === true) { tools = true; break; }
          await new Promise((res) => setTimeout(res, 3000));
        }
      }
      return text(`${name}: ${r.state}${wait ? (tools ? "; guest tools connected (desktop ready)" : "; guest tools did not connect in time (no tools installed, or still booting) — use alcove_wait_idle and alcove_screenshot") : ""}`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_stop_vm",
  {
    title: "Stop VM",
    description: "Shut a VM down. Graceful (ACPI power button) by default; force=true kills the engine immediately (unsaved guest work is lost).",
    inputSchema: { name: vmName, force: z.boolean().optional().describe("Kill immediately instead of a graceful shutdown") },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
  async ({ name, force }) => {
    try {
      const r = await client.call("vm.stop", { name, force: force ?? false }, 180000);
      return text(`${name}: ${r.state}`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_screenshot",
  {
    title: "Screenshot",
    description:
      "Capture the VM screen as a PNG image. Coordinates for click/move/drag tools are guest pixels in the full-resolution frame (width/height in the text part), even when max_width downsamples the returned image.",
    inputSchema: {
      name: vmName,
      max_width: z.number().int().min(64).max(4096).optional().describe("Downscale the returned image to this width (default 1280) to save tokens; coordinates stay in full guest pixels"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ name, max_width }) => {
    try {
      const r = await client.call("vm.screenshot", { name, maxWidth: max_width ?? 1280 }, 60000);
      return {
        content: [
          { type: "text", text: `${name}: ${r.width}x${r.height} guest pixels (image sent at ${r.sentWidth}x${r.sentHeight})` },
          { type: "image", data: r.png as string, mimeType: "image/png" },
        ],
      };
    } catch (e) {
      return fail(e);
    }
  },
);

const point = { x: z.number().int().describe("Guest pixel X (0 = left)"), y: z.number().int().describe("Guest pixel Y (0 = top)") };

server.registerTool(
  "alcove_click",
  {
    title: "Click",
    description: "Move the pointer to guest pixel (x, y) and click. Use count=2 for a double-click, button=\"right\" for a context menu.",
    inputSchema: { name: vmName, ...point, button: z.enum(["left", "right", "middle"]).optional(), count: z.number().int().min(1).max(3).optional() },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, x, y, button, count }) => {
    try {
      await client.call("vm.mouse.click", { name, x, y, button: button ?? "left", count: count ?? 1 });
      return text(`clicked ${button ?? "left"}${count && count > 1 ? ` x${count}` : ""} at (${x}, ${y})`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_move_mouse",
  {
    title: "Move mouse",
    description: "Move the pointer to guest pixel (x, y) without clicking (hover).",
    inputSchema: { name: vmName, ...point },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, x, y }) => {
    try {
      await client.call("vm.mouse.move", { name, x, y });
      return text(`moved to (${x}, ${y})`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_drag",
  {
    title: "Drag",
    description: "Press the mouse button at (from_x, from_y), move to (to_x, to_y) and release.",
    inputSchema: {
      name: vmName,
      from_x: z.number().int(), from_y: z.number().int(), to_x: z.number().int(), to_y: z.number().int(),
      button: z.enum(["left", "right", "middle"]).optional(),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, from_x, from_y, to_x, to_y, button }) => {
    try {
      await client.call("vm.mouse.drag", { name, fromX: from_x, fromY: from_y, toX: to_x, toY: to_y, button: button ?? "left" });
      return text(`dragged (${from_x}, ${from_y}) -> (${to_x}, ${to_y})`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_scroll",
  {
    title: "Scroll",
    description: "Scroll the mouse wheel at guest pixel (x, y). dy > 0 scrolls down, dy < 0 up; dx for horizontal. Units are wheel notches.",
    inputSchema: { name: vmName, ...point, dy: z.number().int().optional(), dx: z.number().int().optional() },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, x, y, dy, dx }) => {
    try {
      await client.call("vm.mouse.scroll", { name, x, y, dy: dy ?? 0, dx: dx ?? 0 });
      return text(`scrolled dy=${dy ?? 0} dx=${dx ?? 0} at (${x}, ${y})`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_type",
  {
    title: "Type text",
    description:
      "Type text into the guest through the virtual keyboard (US layout). Newlines press Enter. For text outside the US layout the guest tools paste through the clipboard when connected.",
    inputSchema: { name: vmName, text: z.string().min(1).max(20000), delay_ms: z.number().int().min(0).max(500).optional().describe("Delay between keys (default 12 ms)") },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, text: t, delay_ms }) => {
    try {
      await client.call("vm.type", { name, text: t, delay: delay_ms ?? 12 }, 600000);
      return text(`typed ${t.length} characters`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_press_keys",
  {
    title: "Press keys",
    description:
      "Press a key or combination and release it, e.g. \"enter\", \"ctrl+c\", \"win+r\", \"alt+f4\", \"ctrl+alt+delete\", \"f5\". Modifiers: ctrl, alt, shift, win (=cmd/meta). Keys: letters, digits, punctuation, enter, tab, esc, backspace, delete, space, up/down/left/right, home, end, pageup, pagedown, f1-f20.",
    inputSchema: { name: vmName, keys: z.string().min(1), hold_ms: z.number().int().min(0).max(5000).optional().describe("Hold the final key this long before releasing") },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, keys, hold_ms }) => {
    try {
      await client.call("vm.key.press", { name, keys, hold: hold_ms ?? 0 });
      return text(`pressed ${keys}`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_exec",
  {
    title: "Run a shell command in the guest",
    description:
      "Run a command inside the guest through the Alcove guest tools and return its output and exit code. Windows guests run PowerShell, Linux guests /bin/sh. Requires the guest tools (alcove-agent) to be installed and started with exec allowed. Use this for anything scriptable instead of clicking around.",
    inputSchema: { name: vmName, command: z.string().min(1).max(100000), timeout_s: z.number().int().min(1).max(3600).optional().describe("Default 120") },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true },
  },
  async ({ name, command, timeout_s }) => {
    try {
      const r = await client.call("vm.exec", { name, command, timeout: timeout_s ?? 120 }, ((timeout_s ?? 120) + 30) * 1000);
      const out = String(r.output ?? "");
      return text(`exit code ${r.code}\n${out.length > 60000 ? out.slice(0, 60000) + "\n...[truncated]" : out}`, { code: r.code, output: out });
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_get_clipboard",
  {
    title: "Read guest clipboard",
    description: "Return the text on the guest's clipboard (needs guest tools).",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ name }) => {
    try {
      const r = await client.call("vm.clipboard.get", { name });
      return text(String(r.text ?? ""));
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_set_clipboard",
  {
    title: "Set guest clipboard",
    description: "Put text on the guest's clipboard (needs guest tools). Combine with alcove_press_keys \"ctrl+v\" to paste long or non-ASCII text.",
    inputSchema: { name: vmName, text: z.string() },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, text: t }) => {
    try {
      await client.call("vm.clipboard.set", { name, text: t });
      return text(`clipboard set (${t.length} characters)`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_push_file",
  {
    title: "Copy a file into the guest",
    description: "Copy a file from the Mac into the guest's Desktop or Downloads folder (needs guest tools). Returns the path inside the guest.",
    inputSchema: { name: vmName, path: z.string().describe("Absolute path on the Mac"), dest: z.enum(["desktop", "downloads"]).optional() },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  },
  async ({ name, path: p, dest }) => {
    try {
      const r = await client.call("vm.push_file", { name, path: p, dest: dest ?? "desktop" }, 1800000);
      return text(`copied to ${r.guestPath}`);
    } catch (e) {
      return fail(e);
    }
  },
);

server.registerTool(
  "alcove_wait_idle",
  {
    title: "Wait until the screen is idle",
    description: "Wait until the guest screen stops changing for `seconds` (default 2), or until `timeout_s` (default 30). Use after booting, clicking or launching apps before taking a screenshot.",
    inputSchema: { name: vmName, seconds: z.number().int().min(1).max(60).optional(), timeout_s: z.number().int().min(1).max(600).optional() },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ name, seconds, timeout_s }) => {
    try {
      const r = await client.call("vm.wait_idle", { name, seconds: seconds ?? 2, timeout: timeout_s ?? 30 }, ((timeout_s ?? 30) + 30) * 1000);
      return text(r.idle ? "screen is idle" : "screen kept changing until the timeout");
    } catch (e) {
      return fail(e);
    }
  },
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  const shutdown = () => { client.close(); process.exit(0); };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.stdin.on("close", shutdown);
}

main().catch((e) => {
  process.stderr.write(`alcove-mcp fatal: ${String(e)}\n`);
  process.exit(1);
});
