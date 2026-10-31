import Foundation

/// Deterministic proof for the Option+H recent-dictations pop-up: the pure preview rule, the pure
/// row model, the pure placement helper, the default key, and the ordered retained-take accessor.
/// Runs inside the existing `--history-selftest` gate (called from TranscriptionHistorySelfTest.run)
/// so the verify count stays 149.
enum RecentDictationsSelfTest {

    static func run(_ r: SelfTestReporter) {
        preview(r)
        model(r)
        placement(r)
        defaultKey(r)
        retainedTakesOrder(r)
        copyToken(r)
    }

    private static func entry(_ id: UUID, _ date: Date, _ text: String) -> TranscriptionHistory.Entry {
        TranscriptionHistory.Entry(id: id, date: date, text: text, app: "",
                                   raw: nil, cleaned: nil, mode: nil, level: nil)
    }

    private static func preview(_ r: SelfTestReporter) {
        r.record("recent: preview short text whole", HistoryPreview.preview("short") == "short")
        let hundred = String(repeating: "x", count: 100)
        r.record("recent: preview 100 characters whole", HistoryPreview.preview(hundred) == hundred)
        let hundredOne = String(repeating: "y", count: 101)
        let expected101 = String(repeating: "y", count: 50) + "\u{2026}" + String(repeating: "y", count: 50)
        r.record("recent: preview 101 characters is 50 plus 50",
                 HistoryPreview.preview(hundredOne) == expected101)
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let emoji = String(repeating: "a", count: 51) + family + String(repeating: "b", count: 49)
        let emojiResult = HistoryPreview.preview(emoji)
        r.record("recent: preview keeps an emoji whole at the boundary",
                 emojiResult.contains(family) && !emojiResult.contains("\u{FFFD}"))
    }

    private static func model(_ r: SelfTestReporter) {
        let dates = (0..<4).map { Date(timeIntervalSince1970: TimeInterval(1000 + $0)) }
        let ids = (0..<4).map { _ in UUID() }
        let transcripts = (0..<4).map { entry(ids[$0], dates[$0], "take \($0)") }
        let limited = RecentDictationsModel.rows(transcripts: transcripts, retainedTakes: [],
                                                 hasAudio: { _ in false })
        r.record("recent: model limits to three newest first",
                 limited.count == 3 && limited.map(\.id) == [ids[3], ids[2], ids[1]])

        let audioID = UUID()
        let audioOnly = RecentDictationsModel.rows(transcripts: [],
                                                   retainedTakes: [(id: audioID, date: dates[0])],
                                                   hasAudio: { _ in true })
        r.record("recent: model audio-only row says No transcript yet",
                 audioOnly.count == 1 && !audioOnly[0].hasTranscript
                    && audioOnly[0].preview == "No transcript yet")

        let dedupeID = UUID()
        let older = Date(timeIntervalSince1970: 2000)
        let newer = Date(timeIntervalSince1970: 3000)
        let deduped = RecentDictationsModel.rows(
            transcripts: [entry(dedupeID, older, "hello")],
            retainedTakes: [(id: dedupeID, date: newer)],
            hasAudio: { _ in true })
        r.record("recent: model dedupes transcript plus audio",
                 deduped.count == 1 && deduped[0].id == dedupeID
                    && deduped[0].hasTranscript && deduped[0].date == newer
                    && deduped[0].playEnabled)

        let noAudio = RecentDictationsModel.rows(
            transcripts: [entry(UUID(), older, "hello")], retainedTakes: [],
            hasAudio: { _ in false })
        r.record("recent: model play disabled without audio",
                 noAudio.count == 1 && !noAudio[0].playEnabled)

        let bothID = UUID()
        let both = RecentDictationsModel.rows(
            transcripts: [entry(bothID, older, "hello")],
            retainedTakes: [(id: bothID, date: older)],
            hasAudio: { _ in true })
        let transcriptOnly = RecentDictationsModel.rows(
            transcripts: [entry(UUID(), older, "hello")], retainedTakes: [],
            hasAudio: { _ in false })
        let audioRow = RecentDictationsModel.rows(
            transcripts: [], retainedTakes: [(id: UUID(), date: older)],
            hasAudio: { _ in true })
        r.record("recent: model transcribe only on audio-only rows",
                 !both[0].canTranscribe && !transcriptOnly[0].canTranscribe
                    && audioRow[0].canTranscribe)
    }

    private static func placement(_ r: SelfTestReporter) {
        let size = NSSize(width: 400, height: 300)
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let rightOrigin = RecentDictationsPlacement.origin(
            for: size, pointer: NSPoint(x: 1400, y: 500), in: frame)
        let bottomOrigin = RecentDictationsPlacement.origin(
            for: size, pointer: NSPoint(x: 700, y: 10), in: frame)
        r.record("recent: placement flips at the right and bottom edges",
                 rightOrigin.x == 1400 - 18 - 400 && bottomOrigin.y == 10 + 18)

        let midOrigin = RecentDictationsPlacement.origin(
            for: size, pointer: NSPoint(x: 700, y: 5), in: frame)
        r.record("recent: placement stays inside the screen",
                 frame.contains(NSRect(origin: midOrigin, size: size)))
    }

    private static func defaultKey(_ r: SelfTestReporter) {
        let key = HotkeyCommand.recentDictations.defaultKey
        let others = HotkeyCommand.allCases.filter { $0 != .recentDictations }
        let uses4 = others.filter { !$0.defaultKey.isModifier && $0.defaultKey.code == 4 }
        r.record("recent: default key is H and unbound at the base",
                 !key.isModifier && key.code == 4 && key.label == "H" && uses4.isEmpty)
    }

    private static func retainedTakesOrder(_ r: SelfTestReporter) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-recent-retained-takes-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = AudioRetentionStore(directory: root, enabled: { true })
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            store.retain(Data("RIFF-\(i)".utf8), id: id,
                         at: Date(timeIntervalSince1970: TimeInterval(i + 1)))
        }
        store.flush()
        let takes = store.retainedTakes()
        r.record("recent: retainedTakes() is newest first",
                 takes.map { $0.id } == [ids[2], ids[1], ids[0]])
    }

    private static func copyToken(_ r: SelfTestReporter) {
        var token = CopyTitleToken()
        let a = token.press()
        let b = token.press()
        var fresh = CopyTitleToken()
        let freshToken = fresh.press()
        r.record("recent: quick double copy keeps only the newest restore",
                 !token.isCurrent(a) && token.isCurrent(b) && fresh.isCurrent(freshToken))
    }
}
