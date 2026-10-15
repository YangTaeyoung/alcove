import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { TOOLSETS, OP_TOOLS, selectedToolsets, clip, registrar, text, fail, type Registrar } from "./toolkit.js";
import { ControlError } from "./control.js";
import { textOf } from "./test-rig.js";
import { register as core } from "./tools/core.js";
import { register as actions } from "./tools/actions.js";
import { register as shell } from "./tools/shell.js";
import { register as files } from "./tools/files.js";
import { register as state } from "./tools/state.js";
import { register as ui } from "./tools/ui.js";
import { register as evidence } from "./tools/evidence.js";
import { register as replay } from "./tools/replay.js";
import { register as http } from "./tools/http.js";

test("unset or empty selects all toolsets", () => {
  assert.deepEqual([...selectedToolsets(undefined)].sort(), [...TOOLSETS].sort());
  assert.equal(selectedToolsets("  ").size, TOOLSETS.length);
});

test("a comma list selects exactly the named toolsets", () => {
  assert.deepEqual([...selectedToolsets("core, files")].sort(), ["core", "files"]);
});

test("an unknown toolset name throws and lists the valid names", () => {
  assert.throws(() => selectedToolsets("bogus"), (e: Error) => /bogus/.test(e.message) && TOOLSETS.every((t) => e.message.includes(t)));
});

test("clip keeps short strings unchanged", () => {
  assert.equal(clip("abc", 10), "abc");
});

test("clip cuts long strings and appends the hint line", () => {
  assert.equal(clip("a".repeat(20), 5, "use offset"), "aaaaa\n...[truncated; use offset]");
});

test("clip without a hint appends a plain truncation marker", () => {
  assert.equal(clip("a".repeat(20), 5), "aaaaa\n...[truncated]");
});

test("registrar registers tools of enabled toolsets and skips the others", () => {
  const seen: string[] = [];
  const stub = { registerTool: (name: string) => { seen.push(name); } };
  const r = registrar(stub as never, new Set(["core"]));
  const handler = async () => text("x");
  r.tool("core", "a", {}, handler);
  r.tool("shell", "b", {}, handler);
  assert.deepEqual(seen, ["a"]);
});

test("fail names tools and tool parameters in server sentences", () => {
  const said = (message: string): string => textOf(fail(new ControlError(message)));
  assert.equal(said("no VM named 'Win'; call vm.list"), "no VM named 'Win'; call alcove_list_vms");
  assert.equal(said("wait until vm.status shows stopped, then call vm.start"), "wait until alcove_vm_status shows stopped, then call alcove_start_vm");
  assert.equal(
    said("call vm.http.stop again once vm.status shows tools; vm.exec.start, vm.http.rule.add and script.run are refused."),
    "call alcove_http_capture_stop again once alcove_vm_status shows tools; alcove_exec_start, alcove_http_rule and alcove_script_run are refused.",
  );
  assert.equal(said("missing or invalid parameter 'hostPort'"), "missing or invalid parameter 'host_port'");
  assert.equal(said("parameter 'keyboardLayouts' must be an array"), "parameter 'keyboard_layouts' must be an array");
  assert.equal(said("missing or invalid parameter 'name'"), "missing or invalid parameter 'name'");
  assert.equal(said("vm.unknown failed; see C:\\vm.list and my-vm.status"), "vm.unknown failed; see C:\\vm.list and my-vm.status");
  assert.equal(said("typed vm.start2024, vm.list-of-things and vm.exec.start-x"), "typed vm.start2024, vm.list-of-things and vm.exec.start-x");
  assert.equal(textOf(fail(new Error("vm.list broke"))), "unexpected error: Error: vm.list broke");
});

test("fail keeps op names inside quoted values as the server does", () => {
  const said = (message: string): string => textOf(fail(new ControlError(message)));
  assert.equal(said("no VM named 'vm.list'; call vm.list"), "no VM named 'vm.list'; call alcove_list_vms");
  assert.equal(said('the step "vm.start" failed; call vm.start'), 'the step "vm.start" failed; call alcove_start_vm');
  assert.equal(said('the step "say \\"vm.start\\"" failed; call vm.start'), 'the step "say \\"vm.start\\"" failed; call alcove_start_vm');
  assert.equal(said("the VM's disk is busy; call vm.stop, then vm.start"), "the VM's disk is busy; call alcove_stop_vm, then alcove_start_vm");
  assert.equal(said("UI helper did not answer 'it's vm.list' in time; call vm.status"), "UI helper did not answer 'it's vm.list' in time; call alcove_vm_status");
  assert.equal(said("an unclosed 'vm.list"), "an unclosed 'alcove_list_vms");
  assert.equal(said("missing or invalid parameter 'hostPort' of vm.forward.add"), "missing or invalid parameter 'host_port' of alcove_port_forward_add");
});

test("every op the control server knows maps to a registered tool", () => {
  const swift = fs.readFileSync(new URL("../../AlcoveKit/Sources/AlcoveControl/ControlHandler.swift", import.meta.url), "utf8");
  const known = /static let knownOps: \[String\] = \[([\s\S]*?)\]/.exec(swift);
  assert.ok(known, "knownOps in ControlHandler.swift");
  const ops = [...known[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]).filter((op) => op !== "hello");
  assert.deepEqual(Object.keys(OP_TOOLS).sort(), ops.sort());
  const tools = new Set<string>();
  const stub: Registrar = { tool: (_set, name) => { tools.add(name); } };
  for (const register of [core, actions, shell, files, state, ui, evidence, replay, http]) register(stub, {} as never);
  for (const [op, tool] of Object.entries(OP_TOOLS)) assert.ok(tools.has(tool), `${op} -> ${tool}`);
});

test("text carries structured content and fail marks errors", () => {
  assert.deepEqual(text("hi", { a: 1 }).structuredContent, { a: 1 });
  assert.equal(fail(new ControlError("nope")).isError, true);
  assert.equal(fail(new ControlError("nope")).content[0].type, "text");
});
