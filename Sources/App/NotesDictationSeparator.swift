import Foundation

/// Headless mirror of the Sticky Notes web island's bare-caret dictation separator rule. The live predicate
/// is `needsLeadingSeparator` in `Web/StickyNotes/src/dictation-separator.js`; this pure mirror lets the
/// existing `--notes-probe` surface pin the complete truth table without launching AppKit or WKWebView.
enum NotesDictationSeparatorLogic {
    private static let openingDelimiters = Set<Character>(["(", "[", "{", "\u{201C}", "\u{2018}"])
    private static let attachingPunctuation = Set<Character>([
        ",", ".", ";", ":", "!", "?", ")", "]", "}", "\u{201D}", "\u{2019}",
    ])

    static func stripLeadingInlineWhitespace(_ text: String) -> String {
        String(text.drop { character in
            character.isWhitespace && character != "\n" && character != "\r"
        })
    }

    static func needsLeadingSeparator(precedingChar: Character?, insertedText: String) -> Bool {
        guard let precedingChar, let first = insertedText.first else { return false }
        if precedingChar.isWhitespace || openingDelimiters.contains(precedingChar) { return false }
        if first == "\n" || first == "\r" || attachingPunctuation.contains(first) { return false }
        return true
    }

    static func preparedBareCaretInsert(precedingChar: Character?, insertedText: String) -> String {
        let stripped = stripLeadingInlineWhitespace(insertedText)
        return needsLeadingSeparator(precedingChar: precedingChar, insertedText: stripped)
            ? " " + stripped
            : stripped
    }
}
