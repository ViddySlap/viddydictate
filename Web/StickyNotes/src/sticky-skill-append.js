// Pure join rule for a Sticky Skill "Append to the source note" landing (S2). Kept DOM-free so the headless
// surface pins the exact production predicate rather than a test-only reimplementation, exactly as
// dictation-separator.js is.
//
// MIRRORED BY StickySkillAppendLogic in Sources/App/StickySkillOutput.swift. The live path (this rule, as a
// CodeMirror transaction) and the no-live-window fallback (the Swift mirror, as a store write) must produce
// byte-identical text, otherwise where the appended block starts depends on whether a window happened to be
// open. Change one, change both.
//
// The rule: the appended block starts after the note's last non-whitespace character, separated by exactly
// one blank line; an empty or all-whitespace note simply becomes the addition. Trailing whitespace already
// in the note is absorbed by the replaced range, so repeated appends cannot accumulate blank lines.
//
// Whitespace is the four ASCII characters only - space, tab, CR, LF - deliberately NOT the `\s` class,
// because `\s` and Swift's `.whitespacesAndNewlines` disagree on unicode (U+00A0, U+FEFF and friends) and
// this rule is only correct if both languages agree exactly.
export function appendRange(doc, insert) {
  const trimmed = doc.replace(/[ \t\r\n]+$/, "");
  return {
    from: trimmed.length,
    to: doc.length,
    insert: trimmed.length === 0 ? insert : `\n\n${insert}`,
  };
}
