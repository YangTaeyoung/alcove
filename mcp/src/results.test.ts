import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { register as registerCore } from "./tools/core.js";
import { register as registerActions } from "./tools/actions.js";
import { register as registerShell } from "./tools/shell.js";
import { register as registerFiles } from "./tools/files.js";
import { register as registerState } from "./tools/state.js";
import { register as registerUi } from "./tools/ui.js";
import { register as registerEvidence } from "./tools/evidence.js";
import { register as registerReplay } from "./tools/replay.js";
import { register as registerHttp } from "./tools/http.js";
import type { LeasedControlClient } from "./leases.js";
import type { ControlClient } from "./control.js";
import { TOOLSETS, serverInstructions, type Registrar, type Toolset } from "./toolkit.js";
import { alcovectlCandidates } from "./control.js";
import { rig, textOf } from "./test-rig.js";

type Register = (r: Registrar, c: ControlClient) => void;
const registerStateAny: Register = (r, c) => registerState(r, c as unknown as LeasedControlClient);
const registers: Record<Toolset, Register[]> = {
  core: [registerCore, registerActions], shell: [registerShell], files: [registerFiles], state: [registerStateAny], ui: [registerUi],
  evidence: [registerEvidence], replay: [registerReplay], http: [registerHttp],
};

test("alcove_record_stop prints write errors, video seconds and dropped frames and leaves out the envelope", async () => {
  const t = rig(registerEvidence, {
    ok: true, id: 3, dir: "/d", trace: "/d/trace.jsonl", frames: 2, seconds: 9, ops: 4, writeErrors: 2, lastWriteError: "disk full",
    video: "/d/video.mp4", videoSeconds: 8.5, droppedFrames: 3,
  });
  const r = await t.run("alcove_record_stop", { name: "vm" });
  assert.equal(textOf(r), [
    "directory: /d", "trace: /d/trace.jsonl", "video: /d/video.mp4", "frames: 2", "ops: 4", "seconds: 9",
    "write errors: 2 (last: disk full)", "video seconds: 8.5", "dropped video frames: 3",
  ].join("\n"));
  assert.equal("ok" in r.structuredContent!, false);
  assert.equal("id" in r.structuredContent!, false);
  const clean = await rig(registerEvidence, { dir: "/d", trace: "/d/t", frames: 0, seconds: 1, ops: 0, writeErrors: 0 }).run("alcove_record_stop", { name: "vm" });
  assert.doesNotMatch(textOf(clean), /write errors|dropped/);
});

test("alcove_record_status prints write errors and a video error", async () => {
  const t = rig(registerEvidence, { recording: true, dir: "/d", seconds: 12, ops: 3, writeErrors: 1, lastWriteError: "disk full", videoError: "the video stopped" });
  const r = await t.run("alcove_record_status", { name: "vm" });
  assert.equal(textOf(r), "recording to /d; 12 s, 3 operations so far; 1 write errors (last: disk full); video: the video stopped");
  assert.deepEqual(r.structuredContent, { recording: true, dir: "/d", seconds: 12, ops: 3, writeErrors: 1, lastWriteError: "disk full", videoError: "the video stopped" });
});

test("clipped lists and command output name a way to see the rest", async () => {
  const many = Array.from({ length: 4000 }, (_, i) => ({ dir: false, size: 1, mtime: "t", name: `file-${i}-${"x".repeat(20)}` }));
  assert.match(textOf(await rig(registerFiles, { entries: many }).run("alcove_fs_list", { name: "vm", path: "C:\\" })), /\[truncated; list a subfolder/);
  const procs = Array.from({ length: 4000 }, (_, i) => ({ pid: i, ppid: 0, name: `p${i}.exe`, memoryKB: 1, command: "y".repeat(20) }));
  assert.match(textOf(await rig(registerShell, { processes: procs }).run("alcove_process_list", { name: "vm" })), /\[truncated; narrow with filter\]/);
  const out = "z".repeat(70000);
  assert.match(textOf(await rig(registerCore, { code: 0, stdout: out, stderr: "" }).run("alcove_exec", { name: "vm", command: "x" })), /\[truncated; .*alcove_fs_read/);
  assert.match(textOf(await rig(registerCore, { code: 0, output: out }).run("alcove_exec", { name: "vm", command: "x" })), /\[truncated; .*alcove_fs_read/);
});

test("tools that can replace a file say so in destructiveHint", () => {
  const files = rig(registerFiles).annotations;
  const core = rig(registerCore).annotations;
  const replay = rig(registerReplay).annotations;
  const evidence = rig(registerEvidence).annotations;
  assert.equal(files.get("alcove_pull_file")!.destructiveHint, true);
  assert.equal(core.get("alcove_push_file")!.destructiveHint, true);
  assert.equal(replay.get("alcove_script_save")!.destructiveHint, true);
  assert.equal(evidence.get("alcove_crash_dumps")!.destructiveHint, true);
});

test("deploy, sync and capture results leave out the envelope and list at most 50 sent files", async () => {
  const sent = Array.from({ length: 120 }, (_, i) => `f${i}`);
  const deploy = await rig(registerUi, { ok: true, id: 1, guestDir: "C:\\a", sent, skipped: 0, bytes: 9 }).run("alcove_deploy", { name: "vm", path: "/b" });
  assert.deepEqual(Object.keys(deploy.structuredContent!).sort(), ["bytes", "guestDir", "sent", "sentCount", "skipped"]);
  assert.equal((deploy.structuredContent!.sent as string[]).length, 50);
  assert.equal(deploy.structuredContent!.sentCount, 120);
  const sync = await rig(registerFiles, { sent, deleted: sent, skipped: 1, bytes: 9 }).run("alcove_sync_dir", { name: "vm", path: "/b", guest_path: "C:\\a" });
  assert.deepEqual(sync.structuredContent, { sent: sent.slice(0, 50), sentCount: 120, skipped: 1, deleted: sent.slice(0, 50), deletedCount: 120, bytes: 9 });
  const start = await rig(registerHttp, { ok: true, id: 2, proxy: "127.0.0.1:1", caInstalled: true }).run("alcove_http_capture_start", { name: "vm" });
  assert.deepEqual(start.structuredContent, { proxy: "127.0.0.1:1", caInstalled: true });
  const stop = await rig(registerHttp, { ok: true, id: 3, exchanges: 4 }).run("alcove_http_capture_stop", { name: "vm" });
  assert.deepEqual(stop.structuredContent, { exchanges: 4 });
});

test("alcove_script_run without name runs against the script's VM by name so this session's lease applies", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "alcove-script-"));
  try {
    const file = path.join(dir, "s.json");
    fs.writeFileSync(file, JSON.stringify({ version: 1, vm: "Win", steps: [] }));
    const t = rig(registerReplay, { passed: true, stepsRun: 0, seconds: 0, steps: [] });
    await t.run("alcove_script_run", { path: file });
    await t.run("alcove_script_run", { path: file, name: "Other" });
    await t.run("alcove_script_run", { path: path.join(dir, "missing.json") });
    assert.deepEqual(t.calls.map((c) => c.params.name), ["Win", "Other", undefined]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("alcove_script_run keeps images out of the structured step results and states its limits", async () => {
  const steps = [{ step: 1, op: "vm.screenshot", ok: true, seconds: 1, result: { jpeg: "QUJD".repeat(500), png: "<omitted: 5 bytes>", width: 4 } }];
  const t = rig(registerReplay, { passed: true, stepsRun: 1, seconds: 1, steps });
  const r = await t.run("alcove_script_run", { path: "/nowhere.json" });
  const result = (r.structuredContent!.steps as Array<Record<string, Record<string, unknown>>>)[0].result;
  assert.deepEqual(result, { jpeg: "<omitted: 2000 characters>", png: "<omitted: 5 bytes>", width: 4 });
  const description = t.descriptions.get("alcove_script_run")!;
  assert.match(description, /two hours/);
  assert.match(description, /Step numbers count from 1/);
});

test("descriptions name what the control ops need and do", () => {
  const state = rig(registerStateAny).descriptions;
  for (const tool of ["alcove_snapshot_list", "alcove_snapshot_create", "alcove_snapshot_restore", "alcove_snapshot_delete",
    "alcove_port_forward_add", "alcove_port_forward_remove", "alcove_port_forward_list", "alcove_set_network"]) {
    assert.match(state.get(tool)!, /running VM/, tool);
  }
  const core = rig(registerCore).descriptions;
  assert.match(core.get("alcove_stop_vm")!, /60 s/);
  assert.match(core.get("alcove_list_vms")!, /suspended to disk/);
  assert.doesNotMatch(core.get("alcove_list_vms")!, /paused, suspended/);
  assert.match(core.get("alcove_screenshot")!, /region and window exclude each other/);
  assert.match(core.get("alcove_start_vm")!, /session ends/);
  assert.match(core.get("alcove_start_vm")!, /refuse the host/);
  assert.match(core.get("alcove_vm_status")!, /`toolsRefused`/);
});

test("parameter descriptions carry the path rules the server enforces", () => {
  const param = (r: ReturnType<typeof rig>, tool: string, name: string) =>
    ((r.schemas.get(tool) as Record<string, { description?: string }>)[name]).description ?? "";
  const evidence = rig(registerEvidence);
  assert.match(param(evidence, "alcove_record_start", "dir"), /missing or empty/);
  assert.match(param(evidence, "alcove_crash_dumps", "path"), /absolute/);
  assert.match(param(rig(registerFiles), "alcove_pull_file", "path"), /absolute/i);
  assert.match(param(rig(registerUi), "alcove_launch_app", "path"), /machine PATH and the HKLM App Paths/);
});

test("the server instructions name only tools of the enabled toolsets", () => {
  const names = new Map<Toolset, string[]>();
  for (const set of TOOLSETS) names.set(set, registers[set].flatMap((register) => [...rig(register).descriptions.keys()]));
  for (const set of TOOLSETS) {
    const enabled = new Set<Toolset>([set]);
    const mentioned = serverInstructions(enabled).match(/alcove_[a-z_]+\*?/g) ?? [];
    for (const m of mentioned) {
      const known = m.endsWith("*") ? names.get(set)!.some((n) => n.startsWith(m.slice(0, -1))) : names.get(set)!.includes(m);
      assert.ok(known, `${m} in the instructions of ${set}`);
    }
  }
  const all = serverInstructions(new Set(TOOLSETS));
  for (const m of ["alcove_exec_start", "alcove_fs_*", "alcove_snapshot_create", "alcove_http_capture_start", "alcove_script_run", "alcove_ui_tree"]) {
    assert.ok(all.includes(m), m);
  }
  assert.match(all, /session ends/);
});

test("alcovectl is looked for in the app bundles, ALCOVE_CTL and the debug build of this checkout", () => {
  const candidates = alcovectlCandidates();
  assert.equal(candidates.filter((c) => /AlcoveKit/.test(c)).length, 1);
  assert.ok(candidates.some((c) => c.endsWith(path.join("AlcoveKit", ".build", "debug", "alcovectl"))));
});
