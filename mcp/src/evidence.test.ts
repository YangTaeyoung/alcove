import { test } from "node:test";
import assert from "node:assert/strict";
import { register, eventLogText, EVENT_LOG_CUT } from "./tools/evidence.js";
import { rig, textOf } from "./test-rig.js";

test("eventLogText prints a header line and the indented message per entry", () => {
  assert.equal(
    eventLogText([{ time: "2026-01-01T00:00:00Z", level: "error", provider: "Application Error", id: 1000, message: "line one\nline two" }]),
    "2026-01-01T00:00:00Z error Application Error (1000)\n  line one\n  line two",
  );
  assert.equal(eventLogText([]), "no matching entries");
});

test("alcove_crash_dumps refuses enable without exe before calling the control op", async () => {
  const t = rig(register);
  const r = await t.run("alcove_crash_dumps", { name: "vm", action: "enable" });
  assert.equal(r.isError, true);
  assert.equal(t.calls.length, 0);
});

test("alcove_crash_dumps list and pull map to their control ops", async () => {
  const list = rig(register, { dumps: [{ file: "a.dmp", exe: "a.exe", bytes: 5, time: "t" }] });
  assert.equal(textOf(await list.run("alcove_crash_dumps", { name: "vm", action: "list" })), "a.dmp a.exe 5 bytes t");
  assert.deepEqual(list.calls[0], { op: "vm.crash_dumps.list", params: { name: "vm" } });
  const pull = rig(register, { path: "/tmp/a.dmp", bytes: 5, sha256: "ab" });
  await pull.run("alcove_crash_dumps", { name: "vm", action: "pull", file: "a.dmp", path: "/tmp/a.dmp" });
  assert.deepEqual(pull.calls[0], { op: "vm.crash_dumps.pull", params: { name: "vm", file: "a.dmp", path: "/tmp/a.dmp" } });
});

test("alcove_event_log maps since_minutes", async () => {
  const t = rig(register, { entries: [] });
  await t.run("alcove_event_log", { name: "vm", since_minutes: 5, level: "error" });
  assert.deepEqual(t.calls[0], { op: "vm.event_log", params: { name: "vm", level: "error", sinceMinutes: 5 } });
});

test("alcove_event_log says that older entries were left out when the guest cut the list", async () => {
  const entry = { time: "t", level: "error", provider: "p", id: 1, message: "m" };
  const cut = rig(register, { entries: [entry], truncated: true });
  assert.equal(textOf(await cut.run("alcove_event_log", { name: "vm" })), `t error p (1)\n  m\n${EVENT_LOG_CUT}`);
  const whole = rig(register, { entries: [entry] });
  assert.equal(textOf(await whole.run("alcove_event_log", { name: "vm" })), "t error p (1)\n  m");
});

test("alcove_crash_dumps list leaves out the image name of a dump that has none", async () => {
  const t = rig(register, { dumps: [{ file: "noexe.dmp", exe: "", bytes: 5, time: "t" }] });
  assert.equal(textOf(await t.run("alcove_crash_dumps", { name: "vm", action: "list" })), "noexe.dmp 5 bytes t");
});

test("alcove_record_start maps max_seconds to maxSeconds", async () => {
  const t = rig(register, { dir: "/d" });
  await t.run("alcove_record_start", { name: "vm", fps: 10, video: false, max_seconds: 60, dir: "/d" });
  assert.deepEqual(t.calls[0], { op: "vm.record.start", params: { name: "vm", fps: 10, video: false, maxSeconds: 60, dir: "/d" } });
});

test("alcove_record_status reports a running and an idle recording", async () => {
  const on = rig(register, { recording: true, dir: "/d", seconds: 12, ops: 3 });
  assert.equal(textOf(await on.run("alcove_record_status", { name: "vm" })), "recording to /d; 12 s, 3 operations so far");
  assert.equal(on.calls[0].op, "vm.record.status");
  const off = rig(register, { recording: false });
  assert.equal(textOf(await off.run("alcove_record_status", { name: "vm" })), "not recording");
});

test("alcove_collect_diagnostics maps log_files and process_name and lists the files", async () => {
  const t = rig(register, { dir: "/d", files: ["screenshot.png"], summary: "ok" });
  const r = await t.run("alcove_collect_diagnostics", { name: "vm", since_minutes: 10, log_files: ["C:\\a.log"], process_name: "a.exe" });
  assert.deepEqual(t.calls[0].params, { name: "vm", sinceMinutes: 10, logFiles: ["C:\\a.log"], processName: "a.exe" });
  assert.equal(textOf(r), "ok\ndirectory: /d\nfiles:\n  screenshot.png");
});
