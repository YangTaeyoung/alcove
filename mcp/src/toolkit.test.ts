import test from "node:test";
import assert from "node:assert/strict";
import { TOOLSETS, selectedToolsets, clip, registrar, text, fail } from "./toolkit.js";
import { ControlError } from "./control.js";

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

test("text carries structured content and fail marks errors", () => {
  assert.deepEqual(text("hi", { a: 1 }).structuredContent, { a: 1 });
  assert.equal(fail(new ControlError("nope")).isError, true);
  assert.equal(fail(new ControlError("nope")).content[0].type, "text");
});
