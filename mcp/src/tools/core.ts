// The core toolset: VM lifecycle, screen, pointer, keyboard, clipboard, exec and file push.
import { z } from "zod";
import type { ControlClient } from "../control.js";
import { clip, commandParams, commandPayload, fail, streamSections, text, vmName, type Registrar } from "../toolkit.js";

export function register(r: Registrar, client: ControlClient): void {
  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
    "alcove_exec",
    {
      title: "Run a shell command in the guest",
      description:
        "Run a command inside the guest through the Alcove guest tools and return its output and exit code. Windows guests run PowerShell, Linux guests /bin/sh. Requires the guest tools (alcove-agent) to be installed and started with exec allowed. Use this for anything scriptable instead of clicking around.",
      inputSchema: { name: vmName, ...commandParams, timeout_s: z.number().int().min(1).max(3600).optional().describe("Default 120") },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true },
    },
    async ({ name, timeout_s, ...cmd }) => {
      try {
        const timeout = timeout_s ?? 120;
        const r = await client.call("vm.exec", { name, ...commandPayload(cmd), timeout }, (timeout + 30) * 1000);
        const hasStreams = r.stdout !== undefined || r.stderr !== undefined;
        const stdout = String(r.stdout ?? "");
        const stderr = String(r.stderr ?? "");
        const output = String(r.output ?? "");
        const head = `exit code ${r.code}${r.timedOut ? " (timed out)" : ""}${r.truncated ? " (output truncated)" : ""}`;
        const body = hasStreams ? streamSections(stdout, stderr) : output ? `output:\n${clip(output)}` : "";
        return text(body ? `${head}\n${body}` : head, { code: r.code, stdout, stderr, output, timedOut: r.timedOut === true, truncated: r.truncated === true });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("core",
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

  r.tool("core",
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

  r.tool("core",
    "alcove_push_file",
    {
      title: "Copy a file into the guest",
      description: "Copy a file from the Mac into the guest (needs guest tools). Without guest_path the file lands in the guest's Desktop or Downloads folder; with guest_path it is written to that exact path inside the guest. Returns the path inside the guest.",
      inputSchema: {
        name: vmName,
        path: z.string().describe("Absolute path on the Mac"),
        dest: z.enum(["desktop", "downloads"]).optional(),
        guest_path: z.string().optional().describe("Exact destination path inside the guest; replaces dest"),
        overwrite: z.boolean().optional().describe("Replace an existing file at guest_path"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, path: p, dest, guest_path, overwrite }) => {
      try {
        const params: Record<string, unknown> = guest_path
          ? { name, path: p, guestPath: guest_path, ...(overwrite !== undefined ? { overwrite } : {}) }
          : { name, path: p, dest: dest ?? "desktop", ...(overwrite !== undefined ? { overwrite } : {}) };
        const r = await client.call("vm.push_file", params, 1800000);
        return text(`copied to ${r.guestPath}${r.bytes !== undefined ? ` (${r.bytes} bytes${r.sha256 ? `, sha256 ${r.sha256}` : ""})` : ""}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("core",
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
}
