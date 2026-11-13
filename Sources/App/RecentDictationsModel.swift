import Foundation

/// The pure row model for the Option+H pop-up (item 5): at most three recent takes, newest first,
/// with a take that has both a transcript entry and retained audio collapsed into ONE row.
enum RecentDictationsModel {

    struct Row {
        let id: UUID
        let date: Date
        let preview: String
        let copyText: String
        let hasTranscript: Bool
        let playEnabled: Bool
        let canTranscribe: Bool
    }

    /// An ask-back take that has not landed yet (asking, canceled, unanswered at quit) keeps empty delivered
    /// text; its transcript is in `raw`. Show and copy that instead of a blank row.
    static func displayText(_ entry: TranscriptionHistory.Entry) -> String {
        if entry.text.isEmpty, entry.askBack != nil, let raw = entry.raw, !raw.isEmpty { return raw }
        return entry.text
    }

    static func rows(
        transcripts: [TranscriptionHistory.Entry],
        retainedTakes: [(id: UUID, date: Date)],
        hasAudio: (UUID) -> Bool
    ) -> [Row] {
        var byID: [UUID: Row] = [:]

        for entry in transcripts {
            let audio = hasAudio(entry.id)
            let shown = displayText(entry)
            byID[entry.id] = Row(
                id: entry.id,
                date: entry.date,
                preview: HistoryPreview.preview(shown),
                copyText: shown,
                hasTranscript: true,
                playEnabled: audio,
                canTranscribe: false)
        }

        for take in retainedTakes {
            if let existing = byID[take.id] {
                if take.date > existing.date {
                    byID[take.id] = Row(
                        id: existing.id,
                        date: take.date,
                        preview: existing.preview,
                        copyText: existing.copyText,
                        hasTranscript: existing.hasTranscript,
                        playEnabled: true,
                        canTranscribe: false)
                }
            } else {
                byID[take.id] = Row(
                    id: take.id,
                    date: take.date,
                    preview: "No transcript yet",
                    copyText: "No transcript yet",
                    hasTranscript: false,
                    playEnabled: true,
                    canTranscribe: true)
            }
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id.uuidString > rhs.id.uuidString
        }.prefix(3).map { $0 }
    }
}
