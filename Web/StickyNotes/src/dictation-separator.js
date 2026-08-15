// Pure separator rule for bare-caret dictation inserts. Kept DOM-free so the headless notes bridge harness
// exercises the exact production predicate rather than a test-only reimplementation.
const OPENING_DELIMITERS = "([{\u201c\u2018";
const ATTACHING_PUNCTUATION = ",.;:!?)]}\u201d\u2019";

// Raw-mode providers may return an already-prefixed space. Remove leading inline whitespace before deciding
// whether to add the one canonical ASCII separator. Preserve line breaks: a deliberate leading newline is an
// attaching boundary of its own and must not be replaced with a space.
export function stripLeadingInlineWhitespace(insertedText) {
  return insertedText.replace(/^[^\S\r\n]+/u, "");
}

export function needsLeadingSeparator(precedingChar, insertedText) {
  if (!precedingChar || !insertedText) return false;
  if (/\s/u.test(precedingChar) || OPENING_DELIMITERS.includes(precedingChar)) return false;
  const first = insertedText[0];
  if (first === "\r" || first === "\n" || ATTACHING_PUNCTUATION.includes(first)) return false;
  return true;
}
