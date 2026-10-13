// The shell toolset: background jobs and guest processes.
import { z } from "zod";
import { ControlError, type ControlClient } from "../control.js";
import { changeResult } from "../observation.js";
import { clip, commandParams, commandPayload, fail, streamSections, text, vmName, type Registrar } from "../toolkit.js";

const job = z.string().describe("Job id returned by alcove_exec_start");

export function register(r: Registrar, client: ControlClient): void {
  r.tool(
    "shell",
    "alcove_exec_start",
    {
      title: "Start a background command in the guest",
      description:
        "Start a command in the guest and return immediately with a job id and pid. Use this for builds, test runs and servers that take longer than a normal call; follow the output with alcove_exec_read. Takes the same command parameters as alcove_exec.",
      inputSchema: { name: vmName, ...commandParams },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true },
    },
    async ({ name, ...cmd }) => {
      try {
        const res = await client.call("vm.exec.start", { name, ...commandPayload(cmd) });
        return changeResult(`started job ${res.job} (pid ${res.pid})`, res, { job: res.job, pid: res.pid });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "shell",
    "alcove_exec_read",
    {
      title: "Read output of a background command",
      description:
        "Read new output of a job started with alcove_exec_start. Pass the out_offset and err_offset printed by the previous read to receive only what is new; start with 0. The result also says whether the job is still running or its exit code.",
      inputSchema: {
        name: vmName,
        job,
        out_offset: z.number().int().min(0).optional().describe("Byte offset in stdout to read from (default 0)"),
        err_offset: z.number().int().min(0).optional().describe("Byte offset in stderr to read from (default 0)"),
        max: z.number().int().min(1).max(262144).optional().describe("Maximum bytes returned per stream (default and cap 262144)"),
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name, job: id, out_offset, err_offset, max }) => {
      try {
        const res = await client.call("vm.exec.read", {
          name,
          job: id,
          ...(out_offset !== undefined ? { outOffset: out_offset } : {}),
          ...(err_offset !== undefined ? { errOffset: err_offset } : {}),
          ...(max !== undefined ? { max } : {}),
        });
        const state = res.state === "exited" ? `exited with code ${res.code}` : String(res.state);
        const head = `${state}${res.dropped ? " (older output was dropped)" : ""}\nnext offsets: out_offset=${res.outNext} err_offset=${res.errNext}`;
        const sections = streamSections(String(res.out ?? ""), String(res.err ?? ""));
        return text(sections ? `${head}\n${sections}` : head, {
          state: res.state, code: res.code, pid: res.pid, outNext: res.outNext, errNext: res.errNext, dropped: res.dropped === true,
        });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "shell",
    "alcove_exec_write",
    {
      title: "Write to a background command's stdin",
      description: "Send text to the standard input of a job started with alcove_exec_start. Set eof=true to close its stdin afterwards.",
      inputSchema: { name: vmName, job, data: z.string().describe("Text to write"), eof: z.boolean().optional().describe("Close stdin after writing") },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async ({ name, job: id, data, eof }) => {
      try {
        const res = await client.call("vm.exec.write", { name, job: id, data, ...(eof !== undefined ? { eof } : {}) });
        return changeResult(`wrote ${data.length} characters${eof ? " and closed stdin" : ""}`, res);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "shell",
    "alcove_exec_kill",
    {
      title: "Kill a background command",
      description: "Stop a job started with alcove_exec_start together with the processes it started.",
      inputSchema: { name: vmName, job },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, job: id }) => {
      try {
        const res = await client.call("vm.exec.kill", { name, job: id });
        return changeResult(`job ${id}: ${res.state}`, res);
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "shell",
    "alcove_exec_list",
    {
      title: "List background commands",
      description: "List the jobs started with alcove_exec_start with their state and exit code.",
      inputSchema: { name: vmName },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name }) => {
      try {
        const res = await client.call("vm.exec.list", { name });
        const jobs = (res.jobs as Array<Record<string, unknown>>) ?? [];
        const lines = jobs.map((j) => `${j.job}  pid ${j.pid}  ${j.state}${j.state === "exited" ? ` (code ${j.code})` : ""}  ${j.cmd ?? ""}`);
        return text(lines.length ? lines.join("\n") : "no jobs", { jobs });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "shell",
    "alcove_process_list",
    {
      title: "List guest processes",
      description: "List processes in the guest with pid, parent pid, name and memory. filter keeps processes whose name contains the text (case-insensitive).",
      inputSchema: { name: vmName, filter: z.string().optional().describe("Case-insensitive substring of the process name") },
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async ({ name, filter }) => {
      try {
        const res = await client.call("vm.process.list", { name, ...(filter ? { filter } : {}) });
        const procs = (res.processes as Array<Record<string, unknown>>) ?? [];
        const lines = procs.map((p) => `${p.pid}  ppid ${p.ppid}  ${p.name}  ${p.memoryKB} KB${p.command ? `  ${p.command}` : ""}`);
        return text(lines.length ? clip(lines.join("\n")) : "no matching processes", { processes: procs });
      } catch (e) {
        return fail(e);
      }
    },
  );

  r.tool(
    "shell",
    "alcove_process_kill",
    {
      title: "Kill guest processes",
      description: "Kill a guest process by pid, or every process with an exact name via process_name. tree=true also kills the processes it started.",
      inputSchema: {
        name: vmName,
        pid: z.number().int().min(1).optional().describe("Process id; give this or process_name"),
        process_name: z.string().optional().describe("Process name; give this or pid"),
        tree: z.boolean().optional().describe("Also kill child processes"),
      },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    },
    async ({ name, pid, process_name, tree }) => {
      try {
        if (pid === undefined && !process_name) return fail(new ControlError("give either `pid` or `process_name`"));
        const res = await client.call("vm.process.kill", {
          name,
          ...(pid !== undefined ? { pid } : { processName: process_name }),
          ...(tree !== undefined ? { tree } : {}),
        });
        return changeResult(`killed ${res.killed} process(es)`, res, { killed: res.killed });
      } catch (e) {
        return fail(e);
      }
    },
  );
}
