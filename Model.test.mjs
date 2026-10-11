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
  assert.deepEqual([1, 2, 3, 4, 5, 9].map((ws) => Model.defaultBackground(BACKGROUNDS, 0, ws)), [A, B, C, D, A, A]);
});

test("the offset rotates the mapping, in both directions", () => {
  assert.equal(Model.defaultBackground(BACKGROUNDS, 1, 1), B);
  assert.equal(Model.defaultBackground(BACKGROUNDS, -1, 1), D);
  assert.equal(Model.defaultBackground(BACKGROUNDS, 6, 1), C);
});

test("workspace ids at or below zero still map to a background", () => {
  assert.equal(Model.defaultBackground(BACKGROUNDS, 0, 0), D);
  assert.equal(Model.defaultBackground(BACKGROUNDS, 0, -98), B);
});

test("a theme without backgrounds maps every workspace to nothing", () => {
  assert.equal(Model.defaultBackground([], 0, 1), "");
  assert.equal(Model.backgroundFor([], 0, {}, 3), "");
});

test("a pin overrides its workspace only", () => {
  const pins = { 2: ELSEWHERE };
  assert.equal(Model.backgroundFor(BACKGROUNDS, 0, pins, 2), ELSEWHERE);
  assert.equal(Model.backgroundFor(BACKGROUNDS, 0, pins, 3), C);
});

test("showing a background on a workspace pins it there", () => {
  const pins = Model.pinned(BACKGROUNDS, 0, {}, 3, A);
  assert.deepEqual(plain(pins), { 3: A });
});

test("showing a workspace its default drops the pin instead", () => {
  const pins = Model.pinned(BACKGROUNDS, 0, { 3: A, 4: B }, 3, C);
  assert.deepEqual(plain(pins), { 4: B });
});

test("pinning leaves the old pins object untouched", () => {
  const pins = { 1: B };
  Model.pinned(BACKGROUNDS, 0, pins, 2, ELSEWHERE);
  assert.deepEqual(pins, { 1: B });
});

test("an image that fails to load is unpinned from every workspace", () => {
  assert.deepEqual(plain(Model.unpinned({ 1: ELSEWHERE, 2: B, 5: ELSEWHERE }, ELSEWHERE)), { 2: B });
});

test("anchoring puts the path on the workspace and rotates the rest around it", () => {
  const { offset, pins } = Model.anchored(BACKGROUNDS, B, 3);
  assert.deepEqual(plain(pins), {});
  assert.deepEqual([1, 2, 3, 4].map((ws) => Model.defaultBackground(BACKGROUNDS, offset, ws)), [D, A, B, C]);
  assert.ok(offset >= 0 && offset < BACKGROUNDS.length);
});

test("anchoring a path outside the theme pins it over plain defaults", () => {
  assert.deepEqual(plain(Model.anchored(BACKGROUNDS, ELSEWHERE, 2)), { offset: 0, pins: { 2: ELSEWHERE } });
});

test("anchoring nothing resets to plain defaults", () => {
  assert.deepEqual(plain(Model.anchored(BACKGROUNDS, "", 2)), { offset: 0, pins: {} });
});

test("the scan reads the theme name and then one path per line", () => {
  const scan = Model.parseScan(`example\n${A}\n${B}\n\n`);
  assert.deepEqual(plain(scan), { theme: "example", backgrounds: [A, B] });
});

test("an empty scan has no theme and no backgrounds", () => {
  assert.deepEqual(plain(Model.parseScan("")), { theme: "", backgrounds: [] });
});

test("saved state round-trips for the same theme", () => {
  const text = Model.serialized("example", 2, { 3: ELSEWHERE });
  assert.deepEqual(plain(Model.restored(text, "example")), { offset: 2, pins: { 3: ELSEWHERE } });
});

test("saved state from another theme is ignored", () => {
  const text = Model.serialized("other", 2, { 3: ELSEWHERE });
  assert.deepEqual(plain(Model.restored(text, "example")), { offset: 0, pins: {} });
});

test("missing or malformed state falls back to plain defaults", () => {
  for (const text of ["", "{", "null", "[]", '"example"']) {
    assert.deepEqual(plain(Model.restored(text, "example")), { offset: 0, pins: {} }, text);
  }
});

test("restoring keeps only well-formed pins and an integer offset", () => {
  const text = JSON.stringify({
    theme: "example",
    offset: 1.5,
    pins: { 1: A, two: B, 3: "", 4: 7, "-5": C },
  });
  assert.deepEqual(plain(Model.restored(text, "example")), { offset: 0, pins: { 1: A, "-5": C } });
});
