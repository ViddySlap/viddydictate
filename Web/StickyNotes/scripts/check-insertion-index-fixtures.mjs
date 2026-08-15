import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "../../..");
const fixturesPath = path.join(repoRoot, "Web/StickyNotes/fixtures/insertion-index.json");

const fixtureSet = JSON.parse(fs.readFileSync(fixturesPath, "utf8"));
if (!fixtureSet || !Array.isArray(fixtureSet.cases) || fixtureSet.cases.length === 0) {
  throw new Error(`Insertion-index fixtures are missing cases: ${fixturesPath}`);
}

let currentRects = [];
function inertElement(id) {
  return {
    id,
    hidden: false,
    style: {},
    classList: { add() {}, remove() {}, toggle() {} },
    parentElement: { getBoundingClientRect: () => ({ left: 0 }) },
    addEventListener() {},
    removeEventListener() {},
    querySelectorAll: () => [],
  };
}

const tabsEl = {
  ...inertElement("tabs"),
  querySelectorAll(selector) {
    if (selector !== ".tab") return [];
    return currentRects.map((rect) => ({ getBoundingClientRect: () => rect }));
  },
};

globalThis.document = {
  documentElement: { style: {} },
  body: { style: {}, classList: { toggle() {} } },
  addEventListener() {},
  removeEventListener() {},
  createElement: () => inertElement("created"),
  getElementById(id) {
    return id === "tabs" ? tabsEl : inertElement(id);
  },
};
globalThis.window = {
  navigator: globalThis.navigator,
  webkit: null,
  addEventListener() {},
  removeEventListener() {},
  getSelection: () => null,
};

const { insertionIndexForX } = await import("../src/drag-rail.js");

let failures = 0;
for (const testCase of fixtureSet.cases) {
  if (!testCase || typeof testCase.name !== "string" || !Array.isArray(testCase.tabs)) {
    throw new Error(`Invalid insertion-index fixture case: ${JSON.stringify(testCase)}`);
  }
  // `scrollOffset` (round-5 R3, item-9): the fixture `tabs` are content-frame (scroll-invariant) positions, so
  // the LIVE viewport rects the JS side reads via getBoundingClientRect are shifted left by the strip's scroll.
  // Reconstruct those live rects (left - scrollOffset) and drive insertionIndexForX with the viewport cursor x —
  // it must land the same index the scroll-aware Swift insertionIndex does (parity holds under scroll).
  const scrollOffset = typeof testCase.scrollOffset === "number" ? testCase.scrollOffset : 0;
  currentRects = testCase.tabs.map((tab) => {
    if (typeof tab.left !== "number" || typeof tab.width !== "number") {
      throw new Error(`Invalid tab geometry in fixture "${testCase.name}"`);
    }
    return { left: tab.left - scrollOffset, width: tab.width };
  });
  const actual = insertionIndexForX(testCase.x);
  if (actual !== testCase.expected) {
    failures += 1;
    console.error(
      `[insertion-index-fixtures] FAIL ${testCase.name}: expected ${testCase.expected}, got ${actual}`
    );
  }
}

if (failures > 0) {
  process.exit(1);
}
console.log(`[insertion-index-fixtures] OK ${fixtureSet.cases.length} cases`);
