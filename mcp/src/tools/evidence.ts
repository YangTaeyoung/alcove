// The evidence toolset: recordings of agent actions, guest event log, crash
// dumps and the one-call diagnostics bundle.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { clip, fail, text, vmName, type Registrar } from "../toolkit.js";

type Obj = Record<string, unknown>;

/** One block per entry: `time level provider (id)` followed by the indented message. */
export function eventLogText(entries: Obj[]): string {
  if (entries.length === 0) return "no matching entries";
  return entries
    .map((e) => {
      const message = String(e.message ?? "").split("\n").map((l) => `  ${l}`).join("\n");
      return `${e.time} ${e.level} ${e.provider} (${e.id})\n${message}`;
    })
    .join("\n");
}

function summaryLines(r: Obj): string[] {
  const lines = [`directory: ${r.dir}`];
  if (r.trace !== undefined) lines.push(`trace: ${r.trace}`);
  if (r.video !== undefined) lines.push(`video: ${r.video}`);
  if (r.frames !== undefined) lines.push(`frames: ${r.frames}`);
  if (r.ops !== undefined) lines.push(`ops: ${r.ops}`);
  if (r.seconds !== undefined) lines.push(`seconds: ${r.seconds}`);
  return lines;
}

export function register(r: Registrar, client: ControlClient): void {
  r.tool("evidence", "alcove_record_start", {
    title: "Start recording",
    description: "Record every control operation on a VM into a directory on the Mac: trace.jsonl (one line per operation with parameters, result and timing), frames/ (before and after screenshots of input actions) and, unless video is false, video.mp4 of the screen. Returns the directory. Start it before a test run and call alcove_record_stop at the end; it also stops by itself after max_seconds or when the VM stops.",
    inputSchema: {
      name: vmName,
      fps: z.number().int().min(1).max(30).optional().describe("Video frames per second (default 5)"),
      video: z.boolean().optional().describe("Also write video.mp4 (default true)"),
      max_seconds: z.number().int().min(1).max(86400).optional().describe("Stop automatically after this long (default 900)"),
      dir: z.string().optional().describe("Absolute Mac directory to write into (default ~/Library/Application Support/Alcove/Recordings/<vm>-<timestamp>)"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.record.start", {
        name: a.name,
        ...(a.fps !== undefined ? { fps: a.fps } : {}),
        ...(a.video !== undefined ? { video: a.video } : {}),
        ...(a.max_seconds !== undefined ? { maxSeconds: a.max_seconds } : {}),
        ...(a.dir !== undefined ? { dir: a.dir } : {}),
      }, 60000);
      return text(`recording to ${reply.dir}`, { dir: reply.dir });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("evidence", "alcove_record_stop", {
    title: "Stop recording",
    description: "Stop the recording of a VM and finish the video file. Returns the directory, the trace and video paths, and the number of operations, frames and seconds recorded.",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async ({ name }) => {
    try {
      const reply = await client.call("vm.record.stop", { name }, 300000);
      return text(summaryLines(reply).join("\n"), reply);
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("evidence", "alcove_event_log", {
    title: "Read the guest event log",
    description: "Read entries of the guest's event log (Windows event log, Linux journal), newest first, as blocks of `time level provider (id)` with the message indented. Use it to find crashes and errors an application logged. Needs guest tools with exec allowed.",
    inputSchema: {
      name: vmName,
      log: z.string().optional().describe("Log name (default Application; also System, Security or any channel)"),
      level: z.enum(["critical", "error", "warning", "info"]).optional().describe("This level and everything more severe (default: all levels)"),
      provider: z.string().optional().describe("Only entries from this provider/source"),
      since_minutes: z.number().int().min(1).max(100000).optional().describe("Only entries of the last N minutes (default 60)"),
      contains: z.string().optional().describe("Only entries whose message contains this text"),
      max: z.number().int().min(1).max(500).optional().describe("Most entries to return (default 50)"),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.event_log", {
        name: a.name,
        ...(a.log !== undefined ? { log: a.log } : {}),
        ...(a.level !== undefined ? { level: a.level } : {}),
        ...(a.provider !== undefined ? { provider: a.provider } : {}),
        ...(a.since_minutes !== undefined ? { sinceMinutes: a.since_minutes } : {}),
        ...(a.contains !== undefined ? { contains: a.contains } : {}),
        ...(a.max !== undefined ? { max: a.max } : {}),
      }, 180000);
      const entries = (reply.entries as Obj[]) ?? [];
      return text(clip(eventLogText(entries), 60000, "lower max or narrow with level, provider or contains"), { entries });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("evidence", "alcove_crash_dumps", {
    title: "Collect crash dumps",
    description: "Manage crash dumps of a Windows guest. enable (needs exe) makes Windows write a dump when that program crashes, into C:\\alcove-dumps (newest 5 kept); disable (needs exe) turns it off; list shows the dumps taken; pull (needs file and path) copies one dump to the Mac. Enable before the run that may crash.",
    inputSchema: {
      name: vmName,
      action: z.enum(["enable", "disable", "list", "pull"]),
      exe: z.string().optional().describe("Image name such as MyApp.exe (enable, disable)"),
      full: z.boolean().optional().describe("enable: full memory dumps instead of mini dumps (default false)"),
      file: z.string().optional().describe("pull: dump file name or path as listed by the list action"),
      path: z.string().optional().describe("pull: destination path on the Mac"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const needs = (field: "exe" | "file" | "path") => {
        if (!a[field]) throw new ControlError(`the ${a.action} action needs ${field}`);
      };
      switch (a.action) {
        case "enable": {
          needs("exe");
          const reply = await client.call("vm.crash_dumps.enable", { name: a.name, exe: a.exe, ...(a.full !== undefined ? { full: a.full } : {}) }, 120000);
          return text(`crash dumps enabled for ${a.exe}${a.full ? " (full)" : ""}; folder ${reply.folder}`, { folder: reply.folder });
        }
        case "disable": {
          needs("exe");
          await client.call("vm.crash_dumps.disable", { name: a.name, exe: a.exe }, 120000);
          return text(`crash dumps disabled for ${a.exe}`);
        }
        case "list": {
          const reply = await client.call("vm.crash_dumps.list", { name: a.name }, 120000);
          const dumps = (reply.dumps as Obj[]) ?? [];
          const body = dumps.length === 0 ? "no crash dumps" : dumps.map((d) => `${d.file} ${d.exe} ${d.bytes} bytes ${d.time}`).join("\n");
          return text(body, { dumps });
        }
        default: {
          needs("file");
          needs("path");
          const reply = await client.call("vm.crash_dumps.pull", { name: a.name, file: a.file, path: a.path }, 1800000);
          return text(`copied to ${reply.path} (${reply.bytes} bytes, sha256 ${reply.sha256})`, { path: reply.path, bytes: reply.bytes, sha256: reply.sha256 });
        }
      }
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("evidence", "alcove_collect_diagnostics", {
    title: "Collect a diagnostics bundle",
    description: "Write everything useful about the VM's current state into one directory on the Mac: screenshot, windows, UI tree, processes, event logs, guest events, job output, requested log file tails, recent crash dumps, doctor report and, while recording, the trace and video. Returns the summary (windows not responding, dumps, error counts per log, failed jobs, foreground window), then the directory and the file list. Call it when a test fails, before changing anything.",
    inputSchema: {
      name: vmName,
      dir: z.string().optional().describe("Absolute Mac directory to write into (default ~/Library/Application Support/Alcove/Diagnostics/<vm>-<timestamp>)"),
      since_minutes: z.number().int().min(1).max(100000).optional().describe("How far back event logs and dumps reach (default 30)"),
      log_files: z.array(z.string()).optional().describe("Guest log file paths; the last 2000 lines of each are copied"),
      process_name: z.string().optional().describe("Narrow the process list to this program and mark it"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (a) => {
    try {
      const reply = await client.call("vm.collect_diagnostics", {
        name: a.name,
        ...(a.dir !== undefined ? { dir: a.dir } : {}),
        ...(a.since_minutes !== undefined ? { sinceMinutes: a.since_minutes } : {}),
        ...(a.log_files !== undefined ? { logFiles: a.log_files } : {}),
        ...(a.process_name !== undefined ? { processName: a.process_name } : {}),
      }, 600000);
      const files = (reply.files as string[]) ?? [];
      const body = [String(reply.summary ?? ""), `directory: ${reply.dir}`, "files:", ...files.map((f) => `  ${f}`)].join("\n");
      return text(clip(body, 60000), { dir: reply.dir, files, summary: reply.summary });
    } catch (e) {
      return fail(e);
    }
  });
}
