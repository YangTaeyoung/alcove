// The ui toolset: windows, the UI Automation tree of Windows guests, element
// actions, app launch, deploy and guest events.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { actionResult, actionTimeout, observeParams, observePayload, type ObserveArgs } from "../observation.js";
import { selectorParams, toSelector } from "../selector.js";
import { clip, fail, text, vmName, type Registrar } from "../toolkit.js";

type Obj = Record<string, unknown>;

/** `<id> "<title>" <process> (pid) x,y WxH [foreground] [minimized] [modal] [NOT RESPONDING]` */
export function windowLine(w: Obj): string {
  const flags = [
    w.foreground ? "[foreground]" : "",
    w.state === "minimized" ? "[minimized]" : "",
    w.modal ? "[modal]" : "",
    w.responding === false ? "[NOT RESPONDING]" : "",
  ].filter(Boolean);
  return [`${w.id} "${w.title}" ${w.process} (${w.pid}) ${w.x},${w.y} ${w.w}x${w.h}`, ...flags].join(" ");
}

function nodeLabel(n: Obj | undefined): string {
  if (!n) return "element";
  return `${n.ref ?? ""} ${n.role ?? ""} "${n.name ?? ""}"`.trim();
}

const WAIT_WINDOW_DEFAULT_S = 20;

const windowRef = z.string().min(1).describe("Window id from alcove_list_windows, \"foreground\", or a part of the title");

export function register(r: Registrar, client: ControlClient): void {
  r.tool("ui", "alcove_list_windows", {
    title: "List windows",
    description: "List the top-level windows of a Windows guest, one per line: id, title, process, pid, rectangle in guest pixels and flags (foreground, minimized, modal, NOT RESPONDING). Prefer this over a screenshot to see which windows exist and which one has the focus.",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async ({ name }) => {
    try {
      const reply = await client.call("vm.window.list", { name }, 60000);
      const windows = (reply.windows as Obj[]) ?? [];
      const body = windows.length === 0 ? "no windows" : windows.map(windowLine).join("\n");
      return text(body, { windows });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_window_action", {
    title: "Act on a window",
    description: "Focus, minimize, maximize, restore, close, move or resize a window of a Windows guest. move needs x and y, resize needs width and height. Returns the window after the action and, unless observe is none, what changed on screen.",
    inputSchema: {
      name: vmName,
      window: windowRef,
      action: z.enum(["focus", "minimize", "maximize", "restore", "close", "move", "resize"]),
      x: z.number().int().optional().describe("Left edge for move, guest pixels"),
      y: z.number().int().optional().describe("Top edge for move, guest pixels"),
      width: z.number().int().min(1).optional().describe("Width for resize, guest pixels"),
      height: z.number().int().min(1).optional().describe("Height for resize, guest pixels"),
      ...observeParams,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      if (a.action === "move" && (a.x === undefined || a.y === undefined)) throw new ControlError("move needs x and y; pass both in guest pixels");
      if (a.action === "resize" && (a.width === undefined || a.height === undefined)) throw new ControlError("resize needs width and height; pass both in guest pixels");
      const reply = await client.call("vm.window.action", {
        name: a.name,
        window: a.window,
        action: a.action,
        ...(a.x !== undefined ? { x: a.x } : {}),
        ...(a.y !== undefined ? { y: a.y } : {}),
        ...(a.width !== undefined ? { width: a.width } : {}),
        ...(a.height !== undefined ? { height: a.height } : {}),
        ...observePayload(a as ObserveArgs, "summary"),
      }, actionTimeout(a as ObserveArgs));
      const w = reply.window as Obj | undefined;
      return actionResult(`${a.action} ${a.window}${w ? `\n${windowLine(w)}` : ""}`, reply, a.settle_timeout_ms);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_ui_tree", {
    title: "Read the UI tree",
    description: "Read the UI Automation tree of a window of a Windows guest as indented text: one line per element with its ref, role, name, rectangle, flags and value. Returns refs usable by the other alcove_ui_* tools. Prefer this over screenshots to find controls and read their state; use filter all only when an expected control is missing.",
    inputSchema: {
      name: vmName,
      window: z.string().optional().describe("Window id, \"foreground\" (default) or a part of the title"),
      root: z.string().regex(/^e\d+$/).optional().describe("Ref of the element whose subtree to read"),
      depth: z.number().int().min(0).max(40).optional().describe("Levels below the root (default 12)"),
      max: z.number().int().min(1).max(2000).optional().describe("Most elements to return (default 300)"),
      filter: z.enum(["interactive", "all"]).optional().describe("interactive (default): elements with a name, a value or an interactive control type; all: every element"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.ui.tree", {
        name: a.name,
        ...(a.window !== undefined ? { window: a.window } : {}),
        ...(a.root !== undefined ? { root: a.root } : {}),
        ...(a.depth !== undefined ? { depth: a.depth } : {}),
        ...(a.max !== undefined ? { max: a.max } : {}),
        ...(a.filter !== undefined ? { filter: a.filter } : {}),
      }, 120000);
      const tree = String(reply.tree ?? "");
      const lines = [clip(tree, 100000, "use root, depth or max to read a smaller part")];
      if (reply.truncated === true) {
        lines.push(`...tree truncated at ${reply.count} elements; pass root with a ref, a smaller depth, or a larger max to see the rest`);
      }
      return text(lines.join("\n"), { window: reply.window, count: reply.count, truncated: reply.truncated });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_ui_find", {
    title: "Find UI elements",
    description: "Find elements of a Windows guest window by role, name or automation id and return them as tree lines with refs. Use it when you know what you are looking for; use alcove_ui_tree to explore.",
    inputSchema: {
      name: vmName,
      ...selectorParams,
      limit: z.number().int().min(1).max(200).optional().describe("Most matches to return (default 20)"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      const { name, limit, ...sel } = a;
      const reply = await client.call("vm.ui.find", { name, ...toSelector(sel), ...(limit !== undefined ? { limit } : {}) }, 60000);
      const nodes = (reply.nodes as Obj[]) ?? [];
      const body = nodes.length === 0 ? "no matches" : `${nodes.length} matches\n${String(reply.text ?? "")}`;
      return text(body, { nodes });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_ui_get_text", {
    title: "Read element text",
    description: "Read the text of one element of a Windows guest: the content of a document or edit control, a value, or the joined names of its children. Returns the text, its total length and where it came from. Prefer this over OCR for text inside controls; page long text with offset and length.",
    inputSchema: {
      name: vmName,
      ...selectorParams,
      mode: z.enum(["auto", "pattern", "descendants"]).optional().describe("auto (default) tries the text pattern, the value, the children, then the name; pattern: text pattern only; descendants: names of the children"),
      offset: z.number().int().min(0).optional().describe("Start position in characters"),
      length: z.number().int().min(1).max(200000).optional().describe("Characters to return (default and maximum 200000)"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      const { name, mode, offset, length, ...sel } = a;
      const reply = await client.call("vm.ui.text", {
        name,
        ...toSelector(sel),
        ...(mode !== undefined ? { mode } : {}),
        ...(offset !== undefined ? { offset } : {}),
        ...(length !== undefined ? { length } : {}),
      }, 60000);
      const body = String(reply.text ?? "");
      const start = offset ?? 0;
      const head = `source ${reply.source}, ${reply.total} characters in total, showing from ${start}`;
      const shown = body.length > 60000 ? 60000 : body.length;
      const hint = `use offset ${start + shown} to read the rest`;
      return text(`${head}\n${clip(body, 60000, hint)}`, { total: reply.total, source: reply.source, offset: start, returned: shown });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_ui_click", {
    title: "Click an element",
    description: "Click the centre of a UI element of a Windows guest with a real mouse click, scrolling it into view first. Select the element by ref or by role, name or automation id. Returns the clicked point and what changed on screen. Prefer this over alcove_click with guessed coordinates.",
    inputSchema: {
      name: vmName,
      ...selectorParams,
      button: z.enum(["left", "right", "middle"]).optional(),
      count: z.number().int().min(1).max(3).optional().describe("2 for a double-click"),
      ...observeParams,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const { name, button, count, observe, settle_ms, settle_timeout_ms, ...sel } = a;
      const obs: ObserveArgs = { observe, settle_ms, settle_timeout_ms };
      const reply = await client.call("vm.ui.click", {
        name,
        ...toSelector(sel),
        button: button ?? "left",
        count: count ?? 1,
        ...observePayload(obs, "summary"),
      }, actionTimeout(obs));
      const line = `clicked ${button ?? "left"}${count && count > 1 ? ` x${count}` : ""} ${nodeLabel(reply.node as Obj | undefined)} at (${reply.x}, ${reply.y})`;
      return actionResult(line, reply, settle_timeout_ms);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_ui_type", {
    title: "Type into an element",
    description: "Click a UI element of a Windows guest to focus it and type text with real key presses. clear selects all existing text first; submit presses enter afterwards. Returns what changed on screen. To set a value without typing use alcove_ui_action with set_value.",
    inputSchema: {
      name: vmName,
      ...selectorParams,
      text: z.string().max(100000).describe("Text to type"),
      clear: z.boolean().optional().describe("Press ctrl+a before typing so the text replaces the content"),
      submit: z.boolean().optional().describe("Press enter after typing"),
      ...observeParams,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const { name, text: typed, clear, submit, observe, settle_ms, settle_timeout_ms, ...sel } = a;
      const obs: ObserveArgs = { observe, settle_ms, settle_timeout_ms };
      const reply = await client.call("vm.ui.type", {
        name,
        ...toSelector(sel),
        text: typed,
        ...(clear !== undefined ? { clear } : {}),
        ...(submit !== undefined ? { submit } : {}),
        ...observePayload(obs, "summary"),
      }, actionTimeout(obs, 60000 + typed.length * 20));
      const line = `typed ${typed.length} characters into ${nodeLabel(reply.node as Obj | undefined)}${clear ? " (cleared first)" : ""}${submit ? " and pressed enter" : ""}`;
      return actionResult(line, reply, settle_timeout_ms);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_ui_action", {
    title: "Run a UI pattern action",
    description: "Act on a UI element of a Windows guest through UI Automation patterns instead of the mouse: invoke, toggle, expand, collapse, select, set_value (needs value), focus or scroll_into_view. Works on covered or off-screen elements where alcove_ui_click cannot. Returns the element after the action and what changed on screen.",
    inputSchema: {
      name: vmName,
      ...selectorParams,
      action: z.enum(["invoke", "toggle", "expand", "collapse", "select", "set_value", "focus", "scroll_into_view"]),
      value: z.string().optional().describe("New value for set_value"),
      ...observeParams,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const { name, action, value, observe, settle_ms, settle_timeout_ms, ...sel } = a;
      if (action === "set_value" && value === undefined) throw new ControlError("set_value needs value; pass the new value");
      const obs: ObserveArgs = { observe, settle_ms, settle_timeout_ms };
      const reply = await client.call("vm.ui.action", {
        name,
        ...toSelector(sel),
        action,
        ...(value !== undefined ? { value } : {}),
        ...observePayload(obs, "summary"),
      }, actionTimeout(obs));
      const node = reply.node as Obj | undefined;
      const flags = Array.isArray(node?.flags) && (node?.flags as unknown[]).length ? ` [${(node?.flags as string[]).join(", ")}]` : "";
      const val = node?.value !== undefined ? ` value="${node.value}"` : "";
      return actionResult(`${action} ${nodeLabel(node)}${flags}${val}`, reply, settle_timeout_ms);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_launch_app", {
    title: "Launch a program",
    description: "Start a program that is already in the guest and wait for its first window. Returns the pid and the window id and title. Needs guest tools with exec allowed. To copy a Mac build into the guest and start it in one step use alcove_deploy.",
    inputSchema: {
      name: vmName,
      path: z.string().min(1).describe("Executable path inside the guest"),
      args: z.array(z.string()).optional().describe("Command-line arguments"),
      cwd: z.string().optional().describe("Working directory inside the guest"),
      env: z.record(z.string()).optional().describe("Extra environment variables"),
      wait_window_s: z.number().min(0).max(300).optional().describe(`Seconds to wait for a window of the new process (default ${WAIT_WINDOW_DEFAULT_S}; 0 skips the wait)`),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const wait = a.wait_window_s ?? WAIT_WINDOW_DEFAULT_S;
      const reply = await client.call("vm.app.launch", {
        name: a.name,
        path: a.path,
        ...(a.args !== undefined ? { args: a.args } : {}),
        ...(a.cwd !== undefined ? { cwd: a.cwd } : {}),
        ...(a.env !== undefined ? { env: a.env } : {}),
        waitWindow: wait,
      }, (wait + 60) * 1000);
      const w = reply.window as Obj | undefined;
      const body = `started pid ${reply.pid}${w ? `\n${windowLine(w)}` : "\nno window appeared yet; check alcove_list_windows"}`;
      return text(body, { pid: reply.pid, window: w });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_deploy", {
    title: "Deploy a build and run it",
    description: "Copy a Mac file or folder into the guest, optionally run an installer, then launch the app and wait for its window. A running copy under the target folder is stopped first. Returns the target folder, how many files were sent, the installer exit code and the new window. Use it for the build-and-test loop; use alcove_sync_dir to copy only.",
    inputSchema: {
      name: vmName,
      path: z.string().min(1).describe("Absolute file or folder path on the Mac"),
      guest_dir: z.string().optional().describe("Target folder in the guest (default C:\\alcove-apps\\<base name>)"),
      install: z.object({
        kind: z.enum(["msi", "exe"]),
        file: z.string().min(1).describe("Installer file, relative to guest_dir unless absolute"),
        args: z.array(z.string()).optional(),
      }).optional().describe("Installer to run after the copy; a non-zero exit code fails the call (3010 counts as success)"),
      launch: z.object({
        exe: z.string().min(1).describe("Executable, relative to guest_dir unless absolute"),
        args: z.array(z.string()).optional(),
        env: z.record(z.string()).optional(),
        cwd: z.string().optional(),
      }).optional().describe("Program to start after the copy and install"),
      wait_window_s: z.number().min(0).max(300).optional().describe(`Seconds to wait for the launched app's window (default ${WAIT_WINDOW_DEFAULT_S}; 0 skips the wait)`),
      kill_running: z.boolean().optional().describe("Stop processes running from guest_dir before copying (default true)"),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.deploy", {
        name: a.name,
        path: a.path,
        ...(a.guest_dir !== undefined ? { guestDir: a.guest_dir } : {}),
        ...(a.install ? { install: a.install } : {}),
        ...(a.launch ? { launch: a.launch } : {}),
        ...(a.wait_window_s !== undefined ? { waitWindow: a.wait_window_s } : {}),
        ...(a.kill_running !== undefined ? { killRunning: a.kill_running } : {}),
      }, 1800000);
      const sent = reply.sent;
      const sentCount = Array.isArray(sent) ? sent.length : Number(sent ?? 0);
      const lines = [`deployed to ${reply.guestDir}: sent ${sentCount} file(s), skipped ${reply.skipped ?? 0} unchanged, ${reply.bytes ?? 0} bytes`];
      if (reply.installCode !== undefined) lines.push(`installer exit code ${reply.installCode}`);
      if (reply.pid !== undefined) lines.push(`started pid ${reply.pid}`);
      const w = reply.window as Obj | undefined;
      if (w) lines.push(windowLine(w));
      else if (a.launch) lines.push("no window appeared yet; check alcove_list_windows");
      return text(lines.join("\n"), reply);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("ui", "alcove_events", {
    title: "Read guest events",
    description: "Read the window and dialog events of a Windows guest (window opened, closed, foreground, title changed, dialog opened) in order, newest 500 kept. Pass the `next` value of the previous call as `since` to get only new events. Use it to notice dialogs and crashes that appeared while you were not looking.",
    inputSchema: {
      name: vmName,
      since: z.number().int().min(0).optional().describe("Return events after this sequence number (default: all kept)"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.events", { name: a.name, ...(a.since !== undefined ? { since: a.since } : {}) }, 60000);
      const events = (reply.events as Obj[]) ?? [];
      const lines = events.map((e) => {
        const { seq, time, name: ev, ...rest } = e;
        const w = (rest.window ?? rest) as Obj;
        const title = w.title !== undefined ? ` "${w.title}"` : "";
        return `${seq} ${time} ${ev}${title}`;
      });
      const head = events.length === 0 ? "no new events" : `${events.length} events`;
      return text([head, ...lines, `next: ${reply.next}`].join("\n"), { events, next: reply.next });
    } catch (e) {
      return fail(e);
    }
  });
}
