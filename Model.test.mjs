// Run from this directory: node --test Model.test.mjs
// Model.js is a QML JavaScript library (".pragma library"), so it is loaded
// into a plain VM context here instead of imported as a module.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("./Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "");
const Model = vm.createContext({});
vm.runInContext(source, Model);
// Objects built inside the VM belong to another realm; compare them as plain data.
const plain = (value) => JSON.parse(JSON.stringify(value));

const DIR = "/themes/example/backgrounds";
const BACKGROUNDS = ["a", "b", "c", "d"].map((name, i) => `${DIR}/${i + 1}-${name}.jpg`);
const [A, B, C, D] = BACKGROUNDS;
const ELSEWHERE = "/pictures/mine.png";

test("workspace N shows the Nth background and wraps past the end", () => {
  assert.deepEqual([1, 2, 3, 4, 5, 9].map((ws) => Model.defaultBackground(BACKGROUNDS, ws)), [A, B, C, D, A, A]);
});

test("workspace ids at or below zero still map to a background", () => {
  assert.equal(Model.defaultBackground(BACKGROUNDS, 0), D);
  assert.equal(Model.defaultBackground(BACKGROUNDS, -98), B);
});

test("a theme without backgrounds maps every workspace to nothing", () => {
  assert.equal(Model.defaultBackground([], 1), "");
  assert.equal(Model.backgroundFor([], {}, 3), "");
});

test("a pin overrides its workspace only", () => {
  const pins = { 2: ELSEWHERE };
  assert.equal(Model.backgroundFor(BACKGROUNDS, pins, 2), ELSEWHERE);
  assert.equal(Model.backgroundFor(BACKGROUNDS, pins, 3), C);
});

test("showing a background on a workspace pins it there", () => {
  assert.deepEqual(plain(Model.pinned(BACKGROUNDS, {}, 3, A)), { 3: A });
});

test("showing a workspace its default drops the pin instead", () => {
  assert.deepEqual(plain(Model.pinned(BACKGROUNDS, { 3: A, 4: B }, 3, C)), { 4: B });
});

test("pinning leaves the old pins object untouched", () => {
  const pins = { 1: B };
  Model.pinned(BACKGROUNDS, pins, 2, ELSEWHERE);
  assert.deepEqual(pins, { 1: B });
});

test("an image that fails to load is unpinned from every workspace", () => {
  assert.deepEqual(plain(Model.unpinned({ 1: ELSEWHERE, 2: B, 5: ELSEWHERE }, ELSEWHERE)), { 2: B });
});

test("the scan reads the theme name and then one path per line", () => {
  assert.deepEqual(plain(Model.parseScan(`example\n${A}\n${B}\n\n`)), { theme: "example", backgrounds: [A, B] });
});

test("an empty scan has no theme and no backgrounds", () => {
  assert.deepEqual(plain(Model.parseScan("")), { theme: "", backgrounds: [] });
});

test("saved pins round-trip for the same theme", () => {
  const text = Model.serialized("example", { 3: ELSEWHERE });
  assert.deepEqual(plain(Model.restoredPins(text, "example")), { 3: ELSEWHERE });
});

test("saved pins from another theme are dropped", () => {
  const text = Model.serialized("other", { 3: ELSEWHERE });
  assert.deepEqual(plain(Model.restoredPins(text, "example")), {});
});

test("missing or malformed state restores no pins", () => {
  for (const text of ["", "{", "null", "[]", '"example"']) {
    assert.deepEqual(plain(Model.restoredPins(text, "example")), {}, text);
  }
});

test("restoring keeps only well-formed pins", () => {
  const text = JSON.stringify({ theme: "example", pins: { 1: A, two: B, 3: "", 4: 7, "-5": C } });
  assert.deepEqual(plain(Model.restoredPins(text, "example")), { 1: A, "-5": C });
});

test("a size key needs both dimensions", () => {
  assert.equal(Model.sizeKey(2560, 1600), "2560x1600");
  assert.equal(Model.sizeKey(0, 1600), "");
});

test("a screen copy line maps size and path to the copy", () => {
  const line = `2560x1600|${A}\t/cache/ab12-2560x1600.jpg`;
  assert.deepEqual(plain(Model.parseScreenCopy(line)), { key: Model.copyKey("2560x1600", A), path: "/cache/ab12-2560x1600.jpg" });
});

test("malformed screen copy lines are ignored", () => {
  for (const line of ["", "no tab", `2560x1600|${A}\t`, `\t/cache/x.jpg`, `big|${A}\t/cache/x.jpg`]) {
    assert.equal(Model.parseScreenCopy(line), null, line);
  }
});

test("copy paths are the theme's backgrounds, then pinned images from elsewhere, once each", () => {
  assert.deepEqual(plain(Model.copyPaths(BACKGROUNDS, { 2: ELSEWHERE, 3: A, 7: ELSEWHERE })), [...BACKGROUNDS, ELSEWHERE]);
});

test("a copy that failed to load is dropped for its size only", () => {
  const copies = { [Model.copyKey("2560x1600", A)]: "/cache/a.jpg", [Model.copyKey("1920x1080", A)]: "/cache/a-small.jpg" };
  assert.deepEqual(plain(Model.withoutCopy(copies, "2560x1600", A)), { [Model.copyKey("1920x1080", A)]: "/cache/a-small.jpg" });
  assert.equal(Object.keys(copies).length, 2);
});
