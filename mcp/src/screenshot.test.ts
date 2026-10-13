import { test } from "node:test";
import assert from "node:assert/strict";
import { register as registerCore } from "./tools/core.js";
import { rig } from "./test-rig.js";

test("alcove_screenshot sends window and marks and lists the marked elements", async () => {
  const reply = { width: 100, height: 100, sentWidth: 100, sentHeight: 100, scale: 1, png: "QUJD", marks: [{ n: 1, ref: "e4", role: "Button", name: "OK", x: 1, y: 2, w: 3, h: 4 }] };
  const t = rig(registerCore, reply);
  const r = await t.run("alcove_screenshot", { name: "W", window: "Notepad", marks: true });
  assert.equal(t.calls[0].params.window, "Notepad");
  assert.equal(t.calls[0].params.marks, true);
  assert.match((r.content[0] as { text: string }).text, /\n1: e4 Button "OK" \(1,2 3x4\)$/);
  assert.equal(t.timeouts[0], 575000);
});

test("alcove_screenshot says when more elements exist than are marked", async () => {
  const reply = { width: 100, height: 100, sentWidth: 100, sentHeight: 100, scale: 1, png: "QUJD", marksTruncated: true,
    marks: [{ n: 1, ref: "e4", role: "Button", name: "OK", x: 1, y: 2, w: 3, h: 4 }] };
  const t = rig(registerCore, reply);
  const r = await t.run("alcove_screenshot", { name: "W", marks: true });
  assert.match((r.content[0] as { text: string }).text,
    /\n1: e4 Button "OK" \(1,2 3x4\)\nmore elements exist than are marked; capture a smaller region or read the window with alcove_ui_tree$/);
  const plain = await rig(registerCore, { ...reply, marksTruncated: undefined, marks: undefined }).run("alcove_screenshot", { name: "W" });
  assert.doesNotMatch((plain.content[0] as { text: string }).text, /more elements/);
});
