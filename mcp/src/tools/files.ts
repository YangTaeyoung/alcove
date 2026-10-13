// The files toolset: transfers between the Mac and the guest, and guest file access.
import { z } from "zod";
import type { ControlClient } from "../control.js";
import { clip, fail, text, vmName, type Registrar } from "../toolkit.js";

const guestPath = (what: string) => z.string().min(1).describe(`${what} inside the guest; \`~\` is the guest user's home`);

export function register(r: Registrar, client: ControlClient): void {
  r.tool(
    "files",
    "alcove_pull_file",
    {
      title: "Copy a file out of the guest",
      description: "Copy a file from the guest to the Mac (needs guest tools with exec allowed). Returns the Mac path, size and SHA-256.",
      inputSchema: { name: vmName, guest_path: guestPath("Path of the file"), path: z.string().min(1).describe("Destination path on the Mac") },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, guest_path, path: p }) => {
      try {
        const res = await client.call("vm.pull_file", { name, guestPath: guest_path, path: p }, 1800000);
        return text(`copied to ${res.path} (${res.bytes} bytes, sha256 ${res.sha256})`, { path: res.path, bytes: res.bytes, sha256: res.sha256 });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "files",
    "alcove_sync_dir",
    {
      title: "Sync a Mac folder into the guest",
      description:
        "Copy a Mac folder into a guest folder, sending only files that differ. Use it to move build output into the guest. With delete=true, files in the guest folder that are not in the Mac folder are removed.",
      inputSchema: {
        name: vmName,
        path: z.string().min(1).describe("Absolute folder path on the Mac"),
        guest_path: guestPath("Destination folder"),
        delete: z.boolean().optional().describe("Remove guest files that are not in the Mac folder (default false)"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
    },
    async ({ name, path: p, guest_path, delete: del }) => {
      try {
        const res = await client.call("vm.sync_dir", { name, path: p, guestPath: guest_path, ...(del !== undefined ? { delete: del } : {}) }, 1800000);
        const sent = (res.sent as string[]) ?? [];
        const deleted = (res.deleted as string[]) ?? [];
        const lines = [`sent ${sent.length} file(s), skipped ${res.skipped ?? 0} unchanged, deleted ${deleted.length}, ${res.bytes ?? 0} bytes`];
        if (sent.length) lines.push("sent:", ...sent.slice(0, 50).map((s) => `  ${s}`));
        if (sent.length > 50) lines.push(`  ...and ${sent.length - 50} more`);
        if (deleted.length) lines.push("deleted:", ...deleted.slice(0, 50).map((s) => `  ${s}`));
        if (deleted.length > 50) lines.push(`  ...and ${deleted.length - 50} more`);
        return text(lines.join("\n"), { sent, skipped: res.skipped, deleted, bytes: res.bytes });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "files",
    "alcove_fs_list",
    {
      title: "List a guest folder",
      description: "List the entries of a guest folder: type (d for folder, - for file), size in bytes, modified time and name.",
      inputSchema: { name: vmName, path: guestPath("Folder path"), recursive: z.boolean().optional().describe("Include subfolders") },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name, path: p, recursive }) => {
      try {
        const res = await client.call("vm.fs.list", { name, path: p, ...(recursive !== undefined ? { recursive } : {}) });
        const entries = (res.entries as Array<Record<string, unknown>>) ?? [];
        const lines = entries.map((e) => `${e.dir ? "d" : "-"} ${e.size} ${e.mtime} ${e.name}`);
        if (res.truncated) lines.push("...[list truncated; list a subfolder to see more]");
        return text(lines.length ? clip(lines.join("\n")) : "empty folder", { entries, truncated: res.truncated === true });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "files",
    "alcove_fs_read",
    {
      title: "Read a guest text file",
      description:
        "Read a text file in the guest. offset and length select a byte range (length up to 262144); tail returns the last N lines, which suits log files.",
      inputSchema: {
        name: vmName,
        path: guestPath("File path"),
        offset: z.number().int().min(0).optional().describe("Byte offset to start at (default 0)"),
        length: z.number().int().min(1).max(262144).optional().describe("Bytes to read (default 262144)"),
        tail: z.number().int().min(1).optional().describe("Return the last N lines instead of a byte range"),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name, path: p, offset, length, tail }) => {
      try {
        const res = await client.call("vm.fs.read", {
          name,
          path: p,
          ...(offset !== undefined ? { offset } : {}),
          ...(length !== undefined ? { length } : {}),
          ...(tail !== undefined ? { tail } : {}),
        });
        const body = String(res.text ?? "");
        const head = `${res.size} bytes${res.eof ? ", end of file" : ""}`;
        return text(`${head}\n${clip(body, 60000, "read the rest with offset and a smaller length")}`, { size: res.size, eof: res.eof === true });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "files",
    "alcove_fs_write",
    {
      title: "Write a guest text file",
      description: "Write text to a file in the guest, creating missing folders. Replaces the file unless append=true.",
      inputSchema: {
        name: vmName,
        path: guestPath("File path"),
        text: z.string().max(200000).describe("Text to write"),
        append: z.boolean().optional().describe("Add to the end of the file instead of replacing it"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    },
    async ({ name, path: p, text: t, append }) => {
      try {
        const res = await client.call("vm.fs.write", { name, path: p, text: t, ...(append !== undefined ? { append } : {}) });
        return text(`wrote ${t.length} characters; file is now ${res.size} bytes`, { size: res.size });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "files",
    "alcove_fs_delete",
    {
      title: "Delete a guest file or folder",
      description: "Delete a file or folder in the guest. Folders need recursive=true.",
      inputSchema: { name: vmName, path: guestPath("Path to delete"), recursive: z.boolean().optional().describe("Delete a folder with its contents") },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, path: p, recursive }) => {
      try {
        const res = await client.call("vm.fs.delete", { name, path: p, ...(recursive !== undefined ? { recursive } : {}) });
        return text(res.deleted ? `deleted ${p}` : `${p} did not exist`, { deleted: res.deleted === true });
      } catch (e) {
        return fail(e);
      }
    },
  );
}
