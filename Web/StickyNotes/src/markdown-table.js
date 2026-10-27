// Markdown table model for the sticky notes editor (slice VDTBL). DOM-free, no imports.

// Number of consecutive backslashes ending just before index i.
function countBackslashes(text, i) {
  let n = 0;
  for (let j = i - 1; j >= 0 && text[j] === "\\"; j -= 1) n += 1;
  return n;
}

// Length of the backtick run starting at index i (0 if text[i] !== "`").
function backtickRunLen(text, i) {
  if (text[i] !== "`") return 0;
  let j = i;
  while (j < text.length && text[j] === "`") j += 1;
  return j - i;
}

// Start index of the next backtick run of EXACTLY `len` backticks at or after `from`, or -1.
function findBacktickRun(text, len, from) {
  let i = from;
  while (i < text.length) {
    if (text[i] === "`") {
      const run = backtickRunLen(text, i);
      if (run === len) return i;
      i += run;
    } else {
      i += 1;
    }
  }
  return -1;
}

// True when the pipe at index i is escaped by an odd run of backslashes.
function pipeEscaped(text, i) {
  return countBackslashes(text, i) % 2 === 1;
}

// Scan one table row. Returns { ranges, hasPipe }:
//   ranges  = [start, end) raw cell ranges (a leading pipe is not a cell, a trailing pipe is not a cell)
//   hasPipe = whether the row has any unescaped pipe outside a code span (leading/trailing pipes count).
function scanRow(text) {
  const n = text.length;
  let i = 0;
  while (i < n && text[i] === " ") i += 1;
  let hasPipe = false;
  let cellStart = i;
  if (i < n && text[i] === "|") {
    hasPipe = true;
    i += 1;
    cellStart = i;
  }
  const separators = [];
  let inCode = false;
  let codeLen = 0;
  while (i < n) {
    const ch = text[i];
    if (ch === "`") {
      const run = backtickRunLen(text, i);
      if (!inCode) {
        const close = findBacktickRun(text, run, i + run);
        if (close !== -1) {
          inCode = true;
          codeLen = run;
        }
      } else if (run === codeLen) {
        inCode = false;
      }
      i += run;
      continue;
    }
    if (ch === "|") {
      if (!inCode && !pipeEscaped(text, i)) {
        hasPipe = true;
        separators.push(i);
      }
    }
    i += 1;
  }
  const ranges = [];
  if (separators.length === 0) {
    ranges.push([cellStart, n]);
  } else {
    ranges.push([cellStart, separators[0]]);
    for (let k = 0; k < separators.length - 1; k += 1) {
      ranges.push([separators[k] + 1, separators[k + 1]]);
    }
    ranges.push([separators[separators.length - 1] + 1, n]);
  }
  if (separators.length > 0) {
    const last = ranges[ranges.length - 1];
    let allSpaces = true;
    for (let k = last[0]; k < last[1]; k += 1) {
      if (text[k] !== " ") {
        allSpaces = false;
        break;
      }
    }
    if (allSpaces) ranges.pop();
  }
  return { ranges, hasPipe };
}

// Display text of the raw slice [from, to): an escaped pipe drops its escape backslash.
function displayText(text, from, to) {
  let out = "";
  for (let i = from; i < to; i += 1) {
    if (text[i] === "\\" && i + 1 < to && text[i + 1] === "|" && pipeEscaped(text, i + 1)) {
      continue;
    }
    out += text[i];
  }
  return out;
}

export function tokenizeTableRow(text, offset) {
  const { ranges } = scanRow(text);
  const cells = [];
  for (const [rs, re] of ranges) {
    let s = rs;
    let e = re;
    while (s < e && text[s] === " ") s += 1;
    while (e > s && text[e - 1] === " ") e -= 1;
    cells.push({ from: offset + s, to: offset + e, text: displayText(text, s, e) });
  }
  return cells;
}

export function parseDelimiterRow(text) {
  const cells = tokenizeTableRow(text, 0);
  const alignments = [];
  for (const cell of cells) {
    const t = cell.text;
    if (!/^:?-+:?$/.test(t)) return null;
    const left = t[0] === ":";
    const right = t[t.length - 1] === ":";
    alignments.push(left && right ? "center" : left ? "left" : right ? "right" : "default");
  }
  return alignments;
}

export function tableModel(lines) {
  if (!Array.isArray(lines) || lines.length < 2) return null;
  const headerLine = lines[0];
  const delimLine = lines[1];
  if (!scanRow(headerLine.text).hasPipe) return null;
  const header = tokenizeTableRow(headerLine.text, headerLine.from);
  if (header.length === 0) return null;
  const alignments = parseDelimiterRow(delimLine.text);
  if (alignments == null || alignments.length !== header.length) return null;

  const rows = [];
  let lineCount = 2;
  for (let k = 2; k < lines.length; k += 1) {
    const line = lines[k];
    const t = line.text;
    const trimmed = t.trim();
    if (trimmed === "") break;
    if (/^`{3,}/.test(trimmed) || /^~{3,}/.test(trimmed)) break;
    if (!scanRow(t).hasPipe) break;
    const cells = tokenizeTableRow(t, line.from);
    const row = [];
    for (let c = 0; c < header.length; c += 1) {
      if (c < cells.length) {
        row.push(cells[c]);
      } else {
        const end = line.from + t.length;
        row.push({ from: end, to: end, text: "" });
      }
    }
    rows.push(row);
    lineCount += 1;
  }
  return { columns: header.length, alignments, header, rows, lineCount };
}
