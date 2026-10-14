// The evidence toolset: recordings of agent actions, guest event log, crash
// dumps and the one-call diagnostics bundle.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { clip, fail, text, vmName, withoutEnvelope, type Registrar } from "../toolkit.js";

type Obj = Record<string, unknown>;

/** The line after the entries of a list the guest cut to its output budget. */
export const EVENT_LOG_CUT = "older matching entries were left out to keep the output within its budget; narrow with level, provider, contains or since_minutes";

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
  const errors = Number(r.writeErrors ?? 0);
  if (errors > 0) lines.push(`write errors: ${errors}${typeof r.lastWriteError === "string" ? ` (last: ${r.lastWriteError})` : ""}`);
  if (r.videoSeconds !== undefined) lines.push(`video seconds: ${r.videoSeconds}`);
  const dropped = Number(r.droppedFrames ?? 0);
  if (dropped > 0) lines.push(`dropped video frames: ${dropped}`);
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
    description: "Stop the recording of a VM and finish the video file. Returns the directory, the trace and video paths, the number of operations, frames and seconds recorded, and failed writes, video seconds and dropped video frames; a recording with failed writes misses trace lines or frames.",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async ({ name }) => {
    try {
      const reply = await client.call("vm.record.stop", { name }, 300000);
      return text(summaryLines(reply).join("\n"), withoutEnvelope(reply));
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("evidence", "alcove_record_status", {
    title: "Recording status",
    description: "Say whether a VM is being recorded and, if so, the directory, the seconds recorded so far, the number of operations traced, failed writes and a video that stopped. Use it to check that a recording is still running before relying on it.",
    inputSchema: { name: vmName },
    annotations: { readOnlyHint: true, openWorldHint: false },
  }, async ({ name }) => {
    try {
      const reply = await client.call("vm.record.status", { name }, 60000);
      if (reply.recording !== true) return text("not recording", { recording: false });
      const errors = Number(reply.writeErrors ?? 0);
      const notes = [
        `recording to ${reply.dir}`,
        `${reply.seconds ?? 0} s, ${reply.ops ?? 0} operations so far`,
        ...(errors > 0 ? [`${errors} write errors${typeof reply.lastWriteError === "string" ? ` (last: ${reply.lastWriteError})` : ""}`] : []),
        ...(typeof reply.videoError === "string" ? [`video: ${reply.videoError}`] : []),
      ];
      return text(notes.join("; "), {
        recording: true, dir: reply.dir, seconds: reply.seconds, ops: reply.ops,
        ...(reply.writeErrors !== undefined ? { writeErrors: reply.writeErrors } : {}),
        ...(reply.lastWriteError !== undefined ? { lastWriteError: reply.lastWriteError } : {}),
        ...(reply.videoError !== undefined ? { videoError: reply.videoError } : {}),
      });
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
      provider: z.string().optional().describe("Only entries of this provider/source: its exact name in any case, no wildcards"),
      since_minutes: z.number().int().min(1).max(5256000).optional().describe("Only entries of the last N minutes (default 60)"),
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
      const truncated = reply.truncated === true;
      const body = eventLogText(entries) + (truncated ? `\n${EVENT_LOG_CUT}` : "");
      return text(clip(body, 60000, "lower max or narrow with level, provider or contains"), { entries, ...(truncated ? { truncated } : {}) });
    } catch (e) {
      return fail(e);
    }
  });

  r.tool("evidence", "alcove_crash_dumps", {
    title: "Collect crash dumps",
    description: "Manage crash dumps of a Windows guest. enable (needs exe) makes Windows write a dump when that program crashes, into C:\\alcove-dumps (Windows keeps the newest 5 dumps of that folder, counted over all enabled programs); disable (needs exe) turns it off; list shows the dumps taken; pull (needs file and path) copies one dump to the Mac and replaces a file already at path. Enable before the run that may crash.",
    inputSchema: {
      name: vmName,
      action: z.enum(["enable", "disable", "list", "pull"]),
      exe: z.string().optional().describe("Image name such as MyApp.exe (enable, disable)"),
      full: z.boolean().optional().describe("enable: full memory dumps instead of mini dumps (default false)"),
      file: z.string().optional().describe("pull: dump file name as listed by the list action, without a folder"),
      path: z.string().optional().describe("pull: destination path on the Mac"),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
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
          const body = dumps.length === 0 ? "no crash dumps" : dumps.map((d) => `${d.file}${d.exe ? ` ${d.exe}` : ""} ${d.bytes} bytes ${d.time}`).join("\n");
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
    description: "Write everything useful about the VM's current state into one directory on the Mac: screenshot, windows, UI tree, processes, event logs, guest events, job output, requested log file tails, recent crash dumps, doctor report, and the trace, frames and video of the running recording or of one that ended within since_minutes. Returns the summary (windows not responding, dumps, error counts per log, failed jobs, foreground window), then the directory and the file list. Call it when a test fails, before changing anything.",
    inputSchema: {
      name: vmName,
      dir: z.string().optional().describe("Absolute Mac directory to write into, missing or empty (default ~/Library/Application Support/Alcove/Diagnostics/<vm>-<timestamp>)"),
      since_minutes: z.number().int().min(1).max(5256000).optional().describe("How far back event logs, dumps and an ended recording reach (default 30)"),
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
      }, 1800000);
      const files = (reply.files as string[]) ?? [];
      const body = [String(reply.summary ?? ""), `directory: ${reply.dir}`, "files:", ...files.map((f) => `  ${f}`)].join("\n");
      return text(clip(body, 60000, `the full files are in ${reply.dir}`), { dir: reply.dir, files, summary: reply.summary });
    } catch (e) {
      return fail(e);
    }
  });
}
