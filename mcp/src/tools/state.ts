// The state toolset: pause, snapshots, clones, leases, port forwards, network, resolution, environment and diagnostics.
import { z } from "zod";
import { ControlError } from "../control.js";
import type { LeasedControlClient } from "../leases.js";
import { fail, text, vmName, type Registrar } from "../toolkit.js";

const snapshotName = z.string().min(1).max(128).describe("Snapshot name (non-empty, at most 128 characters, no newline)");
const LONG_MS = 660000;

interface SnapshotRow { name: string; date: string; vmStateBytes: number }
interface ForwardRow { hostPort: number; guestPort: number; kind: string }
interface EnvRow { setting: string; ok: boolean; detail: string; takesEffect: string }
interface CheckRow { id: string; ok: boolean; detail: string; hint?: string }

export function register(r: Registrar, client: LeasedControlClient): void {
  r.tool("state",
    "alcove_pause_vm",
    {
      title: "Pause VM",
      description: "Freeze a running VM in memory. Resume it with alcove_resume_vm.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const res = await client.call("vm.pause", { name });
        return text(`${name}: ${res.state}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_resume_vm",
    {
      title: "Resume VM",
      description: "Continue a VM paused with alcove_pause_vm.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const res = await client.call("vm.resume", { name });
        return text(`${name}: ${res.state}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_snapshot_list",
    {
      title: "List snapshots",
      description: "List the snapshots of a VM with their date and saved memory-state size.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const res = await client.call("vm.snapshot.list", { name });
        const snaps = (res.snapshots as SnapshotRow[]) ?? [];
        const lines = snaps.map((s) => `${s.name}  ${s.date}  ${(s.vmStateBytes / 1048576).toFixed(1)} MiB`);
        return text(lines.length ? lines.join("\n") : "no snapshots", { snapshots: snaps });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_snapshot_create",
    {
      title: "Create snapshot",
      description: "Save the VM's disk and memory state under a name so alcove_snapshot_restore can return to it.",
      inputSchema: { name: vmName, snapshot: snapshotName },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    async ({ name, snapshot }) => {
      try {
        await client.call("vm.snapshot.create", { name, snapshot }, LONG_MS);
        return text(`created snapshot '${snapshot}' of '${name}'`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_snapshot_restore",
    {
      title: "Restore snapshot",
      description:
        "Return a VM to a snapshot. Everything since the snapshot is lost. Waits for the guest tools to reconnect and syncs the guest clock when they do.",
      inputSchema: {
        name: vmName,
        snapshot: snapshotName,
        wait_tools_s: z.number().int().min(0).max(600).optional().describe("How long to wait for the guest tools after the restore (default 30)"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, snapshot, wait_tools_s }) => {
      try {
        const res = await client.call(
          "vm.snapshot.restore",
          { name, snapshot, ...(wait_tools_s !== undefined ? { waitTools: wait_tools_s } : {}) },
          LONG_MS,
        );
        const tools = res.tools === true;
        const clock = res.clockSynced === true;
        const next = tools
          ? "call alcove_set_environment with clock \"host\""
          : "call alcove_vm_status until the tools are connected, then alcove_set_environment with clock \"host\"";
        return text(
          `restored '${name}' to snapshot '${snapshot}'; ` +
            (tools ? "guest tools reconnected; " : "guest tools did not reconnect in time; ") +
            (clock ? "guest clock synced" : `guest clock not synced; ${next}`),
        );
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_snapshot_delete",
    {
      title: "Delete snapshot",
      description: "Delete a snapshot of a VM.",
      inputSchema: { name: vmName, snapshot: snapshotName },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    },
    async ({ name, snapshot }) => {
      try {
        await client.call("vm.snapshot.delete", { name, snapshot }, LONG_MS);
        return text(`deleted snapshot '${snapshot}' of '${name}'`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_clone_vm",
    {
      title: "Clone VM",
      description: "Create a linked clone of a stopped VM under a new name. The clone shares the template's disk and stores only its own changes.",
      inputSchema: { name: vmName, new_name: z.string().min(1).describe("Name of the new VM") },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    async ({ name, new_name }) => {
      try {
        await client.call("vm.clone", { name, newName: new_name }, LONG_MS);
        return text(`created '${new_name}' as a linked clone of '${name}'`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_delete_vm",
    {
      title: "Delete VM",
      description: "Permanently delete a stopped linked clone and its disk. A VM that is not a clone is refused.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        await client.call("vm.delete", { name });
        return text(`deleted '${name}'`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_lease_acquire",
    {
      title: "Lease a VM",
      description:
        "Reserve a VM so other agents' state-changing calls are refused until the lease expires or is released. Calls from this session carry the lease automatically. Acquiring again renews it.",
      inputSchema: {
        name: vmName,
        ttl_s: z.number().int().min(1).max(3600).optional().describe("Lease duration in seconds (default 300, max 3600)"),
        owner: z.string().min(1).optional().describe("Free-text owner shown to other agents (default mcp-<pid>)"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, ttl_s, owner }) => {
      try {
        const res = await client.call("vm.lease.acquire", {
          name,
          owner: owner ?? `mcp-${process.pid}`,
          ...(ttl_s !== undefined ? { ttl: ttl_s } : {}),
        });
        client.leases.set(name, String(res.lease));
        return text(`leased '${name}' for ${res.expiresIn} s; this session's calls carry the lease`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_lease_release",
    {
      title: "Release a VM lease",
      description: "Release the lease this session holds on a VM.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const lease = client.leases.get(name);
        if (lease === undefined) throw new ControlError(`this session holds no lease on '${name}'; call alcove_lease_acquire first`);
        try {
          await client.call("vm.lease.release", { name, lease });
        } finally {
          client.leases.clear(name);
        }
        return text(`released the lease on '${name}'`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_port_forward_add",
    {
      title: "Add a port forward",
      description:
        "Forward a host port on 127.0.0.1 to a guest port of a running VM, e.g. to reach a dev server inside the guest. Host port 0 or omitted picks a free port.",
      inputSchema: {
        name: vmName,
        guest_port: z.number().int().min(1).max(65535).describe("Port inside the guest"),
        host_port: z.number().int().min(0).max(65535).optional().describe("Port on 127.0.0.1; 0 or omitted picks a free one"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    async ({ name, guest_port, host_port }) => {
      try {
        const res = await client.call("vm.forward.add", {
          name,
          guestPort: guest_port,
          ...(host_port !== undefined ? { hostPort: host_port } : {}),
        });
        return text(`127.0.0.1:${res.hostPort} -> guest ${res.guestPort}`, { hostPort: res.hostPort, guestPort: res.guestPort });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_port_forward_remove",
    {
      title: "Remove a port forward",
      description: "Remove a port forward added with alcove_port_forward_add.",
      inputSchema: { name: vmName, host_port: z.number().int().min(1).max(65535).describe("Host port of the forward") },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, host_port }) => {
      try {
        await client.call("vm.forward.remove", { name, hostPort: host_port });
        return text(`removed forward on 127.0.0.1:${host_port}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_port_forward_list",
    {
      title: "List port forwards",
      description: "List the port forwards of a VM; kind is config (saved with the VM), agent (the forward the guest tools use) or runtime (added with alcove_port_forward_add, until the VM stops).",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const res = await client.call("vm.forward.list", { name });
        const forwards = (res.forwards as ForwardRow[]) ?? [];
        const lines = forwards.map((f) => `127.0.0.1:${f.hostPort} -> guest ${f.guestPort} (${f.kind})`);
        return text(lines.length ? lines.join("\n") : "no port forwards", { forwards });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_set_network",
    {
      title: "Set guest network link",
      description: "Bring the guest's network link up or down, e.g. to test offline behavior.",
      inputSchema: { name: vmName, up: z.boolean().describe("true connects the guest network, false disconnects it") },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, up }) => {
      try {
        const res = await client.call("vm.set_network", { name, up });
        return text(`${name}: network link ${res.up ? "up" : "down"}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_set_resolution",
    {
      title: "Set screen resolution",
      description: "Change the guest screen resolution and report the size a screenshot has afterwards.",
      inputSchema: {
        name: vmName,
        width: z.number().int().min(320).max(7680).describe("Width in pixels"),
        height: z.number().int().min(200).max(4320).describe("Height in pixels"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, width, height }) => {
      try {
        const res = await client.call("vm.set_resolution", { name, width, height });
        return text(`${name}: screen is now ${res.width}x${res.height}`);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_set_environment",
    {
      title: "Set guest environment",
      description:
        "Change guest settings for testing: theme, time zone, clock, locale, keyboard layouts and display scale. Each applied setting reports whether it took effect now or for programs started afterwards (app restart).",
      inputSchema: {
        name: vmName,
        theme: z.enum(["dark", "light"]).optional(),
        time_zone: z.string().min(1).optional().describe("Time zone id, e.g. \"Europe/Berlin\" or \"Pacific Standard Time\""),
        clock: z.string().min(1).optional().describe("ISO 8601 date-time, or \"host\" to copy the host clock"),
        locale: z.string().min(1).optional().describe("Locale tag, e.g. \"de-DE\""),
        keyboard_layouts: z.array(z.string().min(1)).min(1).optional().describe("Keyboard layout tags, e.g. [\"en-US\", \"de-DE\"]"),
        dpi_scale: z.number().int().min(100).max(500).optional().describe("Display scale in percent (100-500)"),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, theme, time_zone, clock, locale, keyboard_layouts, dpi_scale }) => {
      try {
        const params: Record<string, unknown> = { name };
        if (theme !== undefined) params.theme = theme;
        if (time_zone !== undefined) params.timeZone = time_zone;
        if (clock !== undefined) params.clock = clock;
        if (locale !== undefined) params.locale = locale;
        if (keyboard_layouts !== undefined) params.keyboardLayouts = keyboard_layouts;
        if (dpi_scale !== undefined) params.dpiScale = dpi_scale;
        const res = await client.call("vm.set_environment", params, 180000);
        const rows = (res.applied as EnvRow[]) ?? [];
        const lines = rows.map((a) => `${a.setting}: ${a.ok ? "ok" : "FAILED"} — ${a.detail} (takes effect: ${a.takesEffect})`);
        const result = text(lines.length ? lines.join("\n") : "no settings given", { applied: rows });
        return rows.some((a) => !a.ok) ? { ...result, isError: true } : result;
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool("state",
    "alcove_doctor",
    {
      title: "Diagnose a VM",
      description:
        "Check why a VM may not be automatable: engine, state, display, guest tools, exec, user session, disk, clock, network and display scale. Each line is ok or PROBLEM with a detail and, when known, the next step.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const res = await client.call("vm.doctor", { name }, 120000);
        const checks = (res.checks as CheckRow[]) ?? [];
        const lines = checks.flatMap((c) => [
          `${c.ok ? "ok     " : "PROBLEM"} ${c.id}: ${c.detail}`,
          ...(c.hint ? [`        hint: ${c.hint}`] : []),
        ]);
        return text(lines.join("\n"), { checks });
      } catch (e) {
        return fail(e);
      }
    },
  );
}
