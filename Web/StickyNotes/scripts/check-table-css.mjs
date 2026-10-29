import { readFileSync } from 'node:fs';

function fail(what) {
  console.error(`[check-table-css] FAIL: ${what}`);
  process.exit(1);
}

const staticPath = 'Web/StickyNotes/static/app.css';
const distPath = 'Web/StickyNotes/dist/app.css';

let staticCss;
let distCss;
try {
  staticCss = readFileSync(staticPath, 'utf8');
} catch {
  fail(`cannot read ${staticPath}`);
}
try {
  distCss = readFileSync(distPath, 'utf8');
} catch {
  fail(`cannot read ${distPath}`);
}

if (staticCss !== distCss) {
  fail('dist/app.css is not byte-identical to static/app.css');
}

function ruleBody(selector) {
  const m = staticCss.match(selector);
  if (!m) {
    fail(`missing rule: ${selector}`);
  }
  const open = staticCss.indexOf('{', m.index);
  const close = staticCss.indexOf('}', open);
  if (open < 0 || close < 0) {
    fail(`malformed rule: ${selector}`);
  }
  return staticCss.slice(open + 1, close);
}

const tableBody = ruleBody(/\.vd-md-table\s*\{/);
const cellBody = ruleBody(/\.vd-md-table\s+th\s*,\s*\.vd-md-table\s+td\s*\{/);
const wrapBody = ruleBody(/\.vd-md-table-wrap\s*\{/);

if (!tableBody.split('\n').some((line) => line === '  width: 100%;')) {
  fail('table rule has no line exactly "  width: 100%;"');
}
for (const banned of ['max-content', 'min-width', 'table-layout']) {
  if (tableBody.includes(banned)) {
    fail(`table rule contains ${banned}`);
  }
}
if (tableBody.includes('white-space') || cellBody.includes('white-space')) {
  fail('white-space present in table or cell rule');
}
if (!cellBody.includes('overflow-wrap: anywhere')) {
  fail('cell rule lacks overflow-wrap: anywhere');
}
if (!wrapBody.includes('overflow-x: auto')) {
  fail('wrap rule lacks overflow-x: auto');
}

console.log('[check-table-css] OK');
