// The core toolset: VM lifecycle, screen, pointer, keyboard, clipboard, exec and file push.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { actionResult, actionTimeout, changeResult, observeParams, observePayload, marksLegend, screenshotCaption, type ObserveArgs } from "../observation.js";
import { clip, commandParams, commandPayload, fail, regionSchema, startTimeout, stdinParam, streamSections, text, toolSentence, typeMs, uiCallTimeout, vmName, type Registrar } from "../toolkit.js";

/** What the text of a clipped command output says to read the rest. */
const EXEC_CUT_HINT = "write the output to a file in the guest and read it in parts with alcove_fs_read, or run the command with alcove_exec_start and page it with alcove_exec_read";

export function register(r: Registrar, client: ControlClient): void {
  r.tool("core",
    "alcove_list_vms",
    {
      title: "List Alcove VMs",
      description:
        "List the virtual machines managed by Alcove with their guest OS (windows/linux), state (stopped, starting, running, paused, suspending, stopping, failed), whether a session is suspended to disk and, when known, screen size. Call this first to learn VM names.",
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
      description: "Detailed status of one VM: state, screen size, whether the guest tools (agent) are connected and which capabilities they offer (exec, clipboard, files). When the guest tools refused the host or the host refused them, `toolsRefused` holds a sentence that says which side refused (`… refused the connection: …` for the guest tools, `… cannot be used: …` for the host) and names the fix.",
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
        "Boot a VM (or resume it from suspend). A resumed session is reported with whether the guest tools reconnected and the guest clock was synced. By default waits until the guest tools connect (the OS has booted and a user is logged in), up to wait_timeout_s; when the guest tools refuse the host, or the host refuses them, it returns at once with the sentence that says which side refused and names the fix; when the guest has no tools it returns after the wait and you should use alcove_wait_idle / screenshots to judge readiness. When neither the Alcove app nor another control server answers, this MCP session starts a headless control server, and the VMs it runs shut down when the session ends.",
      inputSchema: {
        name: vmName,
        wait_for_tools: z.boolean().optional().describe("Wait for the guest tools to connect (default true)"),
        wait_timeout_s: z.number().int().min(0).max(900).optional().describe("How long to wait for the guest (default 180)"),
        discard_changes: z.boolean().optional().describe("Run this boot as a throwaway session: disk changes are discarded when the VM stops"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, wait_for_tools, wait_timeout_s, discard_changes }) => {
      try {
        const wait = wait_for_tools ?? true;
        const waitS = wait ? wait_timeout_s ?? 180 : 0;
        const r = await client.call(
          "vm.start",
          { name, ...(discard_changes !== undefined ? { discardChanges: discard_changes } : {}), waitTools: waitS },
          startTimeout(waitS),
        );
        if (r.resumed === true) {
          const next = r.tools === true
            ? "call alcove_set_environment with clock \"host\""
            : "call alcove_vm_status until the tools are connected, then alcove_set_environment with clock \"host\"";
          return text(
            `${name}: ${r.state}; resumed a suspended session; ` +
              (r.tools === true ? "guest tools reconnected; " : "guest tools did not reconnect in time; ") +
              (r.clockSynced === true ? "guest clock synced" : `guest clock not synced; ${next}`),
          );
        }
        const deadline = Date.now() + waitS * 1000;
        let tools = false;
        let refused: string | undefined;
        if (wait) {
          while (Date.now() < deadline) {
            const st = await client.call("vm.status", { name }, 60000);
            if (st.tools === true) { tools = true; break; }
            if (typeof st.toolsRefused === "string") { refused = st.toolsRefused; break; }
            await new Promise((res) => setTimeout(res, 3000));
          }
        }
        const toolsPart = !wait ? ""
          : tools ? "; guest tools connected (desktop ready)"
          : refused !== undefined ? `; ${refused.replace(`the guest tools in '${name}' `, "the guest tools ")}`
          : "; guest tools did not connect in time (no tools installed, or still booting) — use alcove_wait_idle and alcove_screenshot";
        return text(`${name}: ${r.state}${r.ephemeral === true ? " (changes will be discarded when it stops)" : ""}${toolsPart}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("core",
    "alcove_stop_vm",
    {
      title: "Stop VM",
      description: "Shut a VM down. By default it presses the ACPI power button and, when the guest has not shut down after 60 s, ends the engine (unsaved guest work is lost); force=true ends the engine at once. Returns the state, and a warning when the guest keeps the proxy settings of an HTTP capture that the stop ended.",
      inputSchema: { name: vmName, force: z.boolean().optional().describe("Kill immediately instead of a graceful shutdown") },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, force }) => {
      try {
        const r = await client.call("vm.stop", { name, force: force ?? false }, 180000);
        const warning = typeof r.warning === "string" ? `\nwarning: ${toolSentence(r.warning)}` : "";
        return text(`${name}: ${r.state}${warning}`);
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
        "Capture the VM screen as a PNG or JPEG image. Coordinates for click/move/drag tools are guest pixels in the full-resolution frame. The text part gives the guest frame size and where the returned image sits: guest = origin + image_pixel / scale. Use region to capture one rectangle or window to capture one window (Windows guests); region and window exclude each other. marks numbers the interactive elements on the image and lists them in the text; scale or max_width shrink the image.",
      inputSchema: {
        name: vmName,
        region: regionSchema.optional().describe("Capture only this guest-pixel rectangle {x, y, w, h}; not together with window"),
        scale: z.number().min(0.1).max(1).optional().describe("Scale the captured area by this factor (0.1 to 1)"),
        max_width: z.number().int().min(64).max(4096).optional().describe("Downscale the returned image to this width (default 1280) to save tokens; coordinates stay in full guest pixels"),
        format: z.enum(["png", "jpeg"]).optional().describe("Image format (default png); jpeg is smaller"),
        quality: z.number().min(0.1).max(1).optional().describe("JPEG quality (default 0.8)"),
        window: z.string().optional().describe("Crop to this window: a window id from alcove_list_windows, \"foreground\", or a part of the title (Windows guests); not together with region"),
        marks: z.boolean().optional().describe("Draw numbered rectangles over the interactive elements and list them (number, ref, role, name) in the text; pass the ref to alcove_ui_click (Windows guests)"),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name, region, scale, max_width, format, quality, window, marks }) => {
      try {
        if (region !== undefined && window !== undefined) throw new ControlError("pass region or window, not both");
        const helperCalls = (window !== undefined ? 1 : 0) + (marks ? 1 : 0);
        const r = await client.call("vm.screenshot", {
          name,
          maxWidth: max_width ?? 1280,
          ...(region ? { region } : {}),
          ...(scale !== undefined ? { scale } : {}),
          ...(format ? { format } : {}),
          ...(quality !== undefined ? { quality } : {}),
          ...(window !== undefined ? { window } : {}),
          ...(marks !== undefined ? { marks } : {}),
        }, helperCalls > 0 ? uiCallTimeout(helperCalls) : 60000);
        const jpeg = typeof r.jpeg === "string";
        return {
          content: [
            { type: "text", text: screenshotCaption(name, r) + marksLegend(r.marks, r.marksTruncated === true) },
            jpeg ? { type: "image", data: r.jpeg as string, mimeType: "image/jpeg" } : { type: "image", data: r.png as string, mimeType: "image/png" },
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
      inputSchema: { name: vmName, ...point, button: z.enum(["left", "right", "middle"]).optional(), count: z.number().int().min(1).max(3).optional(), ...observeParams },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, x, y, button, count, ...obs }) => {
      try {
        const r = await client.call("vm.mouse.click", { name, x, y, button: button ?? "left", count: count ?? 1, ...observePayload(obs as ObserveArgs, "summary") }, actionTimeout(obs as ObserveArgs));
        return actionResult(`clicked ${button ?? "left"}${count && count > 1 ? ` x${count}` : ""} at (${x}, ${y})`, r, obs.settle_timeout_ms);
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
      inputSchema: { name: vmName, ...point, ...observeParams },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, x, y, ...obs }) => {
      try {
        const r = await client.call("vm.mouse.move", { name, x, y, ...observePayload(obs as ObserveArgs, "summary") }, actionTimeout(obs as ObserveArgs));
        return actionResult(`moved to (${x}, ${y})`, r, obs.settle_timeout_ms);
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
        ...observeParams,
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, from_x, from_y, to_x, to_y, button, ...obs }) => {
      try {
        const r = await client.call("vm.mouse.drag", { name, fromX: from_x, fromY: from_y, toX: to_x, toY: to_y, button: button ?? "left", ...observePayload(obs as ObserveArgs, "summary") }, actionTimeout(obs as ObserveArgs));
        return actionResult(`dragged (${from_x}, ${from_y}) -> (${to_x}, ${to_y})`, r, obs.settle_timeout_ms);
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
      inputSchema: { name: vmName, ...point, dy: z.number().int().optional(), dx: z.number().int().optional(), ...observeParams },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, x, y, dy, dx, ...obs }) => {
      try {
        const r = await client.call("vm.mouse.scroll", { name, x, y, dy: dy ?? 0, dx: dx ?? 0, ...observePayload(obs as ObserveArgs, "summary") }, actionTimeout(obs as ObserveArgs));
        return actionResult(`scrolled dy=${dy ?? 0} dx=${dx ?? 0} at (${x}, ${y})`, r, obs.settle_timeout_ms);
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
      inputSchema: { name: vmName, text: z.string().min(1).max(20000), delay_ms: z.number().int().min(0).max(500).optional().describe("Delay between keys (default 12 ms)"), ...observeParams },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, text: t, delay_ms, ...obs }) => {
      try {
        const r = await client.call("vm.type", { name, text: t, delay: delay_ms ?? 12, ...observePayload(obs as ObserveArgs, "summary") }, actionTimeout(obs as ObserveArgs, typeMs(t.length, delay_ms ?? 12)));
        return actionResult(`typed ${t.length} characters`, r, obs.settle_timeout_ms);
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
      inputSchema: { name: vmName, keys: z.string().min(1), hold_ms: z.number().int().min(0).max(5000).optional().describe("Hold the final key this long before releasing"), ...observeParams },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, keys, hold_ms, ...obs }) => {
      try {
        const r = await client.call("vm.key.press", { name, keys, hold: hold_ms ?? 0, ...observePayload(obs as ObserveArgs, "summary") }, actionTimeout(obs as ObserveArgs));
        return actionResult(`pressed ${keys}`, r, obs.settle_timeout_ms);
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
      inputSchema: { name: vmName, ...commandParams, ...stdinParam, timeout_s: z.number().int().min(1).max(3600).optional().describe("Default 120") },
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
        const body = hasStreams ? streamSections(stdout, stderr, EXEC_CUT_HINT) : output ? `output:\n${clip(output, 60000, EXEC_CUT_HINT)}` : "";
        return changeResult(head, r, { code: r.code, stdout, stderr, output, timedOut: r.timedOut === true, truncated: r.truncated === true }, body);
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
      description: "Copy a file from the Mac into the guest (needs guest tools). Without guest_path the file lands in the guest's Desktop or Downloads folder; with guest_path it is written to that exact path inside the guest, and overwrite replaces a file already there. Returns the path inside the guest.",
      inputSchema: {
        name: vmName,
        path: z.string().describe("Absolute path on the Mac"),
        dest: z.enum(["desktop", "downloads"]).optional(),
        guest_path: z.string().optional().describe("Exact destination path inside the guest; replaces dest"),
        overwrite: z.boolean().optional().describe("Replace an existing file at guest_path"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
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
