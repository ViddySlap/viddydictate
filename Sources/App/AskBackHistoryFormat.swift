import Foundation

/// VDASK-6: the text the History window row shows for an entry's `askBack` record. Pure (Foundation only) so a
/// headless row can pin every rule; `HistoryWindow.swift` only places the strings.
enum AskBackHistoryFormat {
    static let noQuestions = "No questions asked"

    /// The tag line: the existing tags with the ask-back tag first. No record leaves the tags exactly as they are.
    /// The tag is `?` for a finished take and `? <status>` for any other stored status, shown as stored (the store
    /// already rewrites asking/writing to "unanswered at quit" at launch, so no display rule is needed here).
    static func tags(record: AskBackRecord?, status: String?, existing: [String]) -> [String] {
        guard record != nil else { return existing }
        return [tag(status: status)] + existing
    }

    static func tag(status: String?) -> String {
        guard let status = status, !status.isEmpty, status != AskBackHistoryStatus.done else { return "?" }
        return "? \(status)"
    }

    static func tagLine(record: AskBackRecord?, status: String?, existing: [String]) -> String {
        tags(record: record, status: status, existing: existing).joined(separator: " · ")
    }

    /// The row body. A pending entry has empty delivered text; it shows the transcript, flagged so the row can
    /// paint it in the secondary colour.
    static func body(delivered: String, transcript: String?) -> (text: String, isTranscriptFallback: Bool) {
        if delivered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let transcript = transcript {
            return (transcript, true)
        }
        return (delivered, false)
    }

    /// One line per answer: unanswered when `how` is nil, agent decided when the answer is nil, else the answer
    /// and the stored `how` raw value.
    static func answerLine(_ q: AskBackRecord.Question) -> String {
        guard let how = q.how else { return "\u{2192} unanswered" }
        guard let answer = q.answer else { return "\u{2192} agent decided" }
        return "\u{2192} \(answer) (\(how))"
    }

    /// The answers block shown when a row is expanded: `Q:` and `→` lines per question, or one line when none.
    static func answerLines(_ record: AskBackRecord) -> [String] {
        guard !record.questions.isEmpty else { return [noQuestions] }
        return record.questions.flatMap { ["Q: \($0.question)", answerLine($0)] }
    }

    static func answersText(_ record: AskBackRecord) -> String {
        answerLines(record).joined(separator: "\n")
    }
}
