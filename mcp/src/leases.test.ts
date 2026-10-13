import test from "node:test";
import assert from "node:assert/strict";
import { LeaseBook } from "./leases.js";

test("apply adds the lease only for the VM that has one", () => {
  const book = new LeaseBook();
  book.set("A", "tok-a");
  assert.deepEqual(book.apply({ name: "A", x: 1 }), { name: "A", x: 1, lease: "tok-a" });
  assert.deepEqual(book.apply({ name: "B", x: 1 }), { name: "B", x: 1 });
});

test("apply leaves params without a name untouched", () => {
  const book = new LeaseBook();
  book.set("A", "tok-a");
  assert.deepEqual(book.apply({ x: 1 }), { x: 1 });
});

test("apply stops adding the lease after clear", () => {
  const book = new LeaseBook();
  book.set("A", "tok-a");
  book.clear("A");
  assert.deepEqual(book.apply({ name: "A" }), { name: "A" });
});

test("apply keeps a lease the caller passed explicitly", () => {
  const book = new LeaseBook();
  book.set("A", "tok-a");
  assert.deepEqual(book.apply({ name: "A", lease: "other" }), { name: "A", lease: "other" });
});

test("entries lists every held lease", () => {
  const book = new LeaseBook();
  book.set("A", "tok-a");
  book.set("B", "tok-b");
  assert.deepEqual(book.entries().sort(), [["A", "tok-a"], ["B", "tok-b"]]);
});
