import Foundation

/// Scratch-only characterization of the capped rolling transcription history.
enum TranscriptionHistorySelfTest {
    static func run(encoderSamplesDirectory: URL?) -> Bool {
        print("--- rolling transcription history: JSON persistence and retention ---")
        Settings.registerDefaults()

        let reporter = SelfTestReporter()
        let check = reporter
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let before = defaults.persistentDomain(forName: domain)
        defer {
            if let before = before { defaults.setPersistentDomain(before, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }

        Settings.keepFullHistory = false
        Settings.dictationHistoryMax = 4

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-rolling-history-selftest-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            check("record persists a real history.json file", false, String(describing: error))
            print(reporter.summaryLine(prefix: "[transcription-history-selftest]"))
            return false
        }

        let history = TranscriptionHistory(
            directory: root,
            maxEntries: { Settings.dictationHistoryMax })
        let retainedTakeID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        history.record(delivered: "raw landed", raw: "raw landed", cleaned: nil,
                       mode: .raw, app: "RawApp", id: retainedTakeID)
        history.record(delivered: "cleaned landed", raw: "rough original", cleaned: "cleaned landed",
                       mode: .cleanup, level: 1, app: "CleanApp")
        history.record(delivered: "search answer", raw: "search query", cleaned: "search answer",
                       mode: .search, level: 2, app: "SearchApp")
        history.record(delivered: "search answer", raw: "search query", cleaned: "search answer",
                       mode: .search, level: 2, app: "SearchApp")
        history.flush()

        let recorded = history.all()
        check("record appends every nonblank delivery without deduplication",
              recorded.count == 4 && recorded.filter { $0.text == "search answer" }.count == 2)
        check("record persists a real history.json file",
              fm.fileExists(atPath: root.appendingPathComponent("history.json").path))
        check("caller-supplied take UUID is preserved for retained-audio playback",
              recorded.last?.id == retainedTakeID)

        history.setMaxEntries(3)
        history.flush()
        check("setMaxEntries persists the requested cap", Settings.dictationHistoryMax == 3)
        check("lowering the cap trims the oldest entry immediately",
              history.all().count == 3 && !history.all().contains { $0.text == "raw landed" })

        let reloaded = TranscriptionHistory(
            directory: root,
            maxEntries: { Settings.dictationHistoryMax })
        let entries = reloaded.all()
        let cleanup = entries.first { $0.mode == HistoryMode.cleanup.rawValue }
        let search = entries.first { $0.mode == HistoryMode.search.rawValue }
        check("reload preserves delivered and original text",
              cleanup?.text == "cleaned landed" && cleanup?.raw == "rough original")
        check("reload preserves cleaned text, mode, and cleanup level",
              cleanup?.cleaned == "cleaned landed"
                && cleanup?.mode == HistoryMode.cleanup.rawValue
                && cleanup?.level == 1)
        check("reload preserves search raw, cleaned, mode, and level",
              search?.raw == "search query" && search?.cleaned == "search answer"
                && search?.mode == HistoryMode.search.rawValue && search?.level == 2)
        check("reload preserves newest-first order and duplicate deliveries",
              entries.count == 3 && entries[0].text == "search answer"
                && entries[1].text == "search answer" && entries[2].text == "cleaned landed")

        reloaded.clear()
        reloaded.flush()
        let cleared = TranscriptionHistory(
            directory: root,
            maxEntries: { Settings.dictationHistoryMax })
        check("clear persists an empty history across reload", cleared.all().isEmpty)

        if let encoderSamplesDirectory = encoderSamplesDirectory {
            do {
                check("frozen encoder config and decode equivalence hold for both stores",
                      try verifyFrozenFormats(in: encoderSamplesDirectory))
            } catch {
                check("frozen encoder config and decode equivalence hold for both stores",
                      false, String(describing: error))
            }
        }

        print(reporter.summaryLine(prefix: "[transcription-history-selftest]"))
        return reporter.passed
    }

    private static func verifyFrozenFormats(in directory: URL) throws -> Bool {
        let fm = FileManager.default
        let incumbentDirectory = directory.appendingPathComponent("incumbent", isDirectory: true)
        let refactoredDirectory = directory.appendingPathComponent("refactored", isDirectory: true)
        try fm.createDirectory(at: incumbentDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: refactoredDirectory, withIntermediateDirectories: true)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let historyEntry = TranscriptionHistory.Entry(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            date: date,
            text: "cleaned sample",
            app: "SampleApp",
            raw: "raw sample",
            cleaned: "cleaned sample",
            mode: HistoryMode.cleanup.rawValue,
            level: 1)
        let storedType = PasteboardSnapshot.StoredItem.StoredType(
            name: "public.utf8-plain-text",
            data: Data("clipboard sample".utf8))
        let clipboardEntry = ClipboardHistory.Entry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            date: date,
            preview: "clipboard sample",
            detail: "Text - 1 KB",
            types: ["public.utf8-plain-text"],
            snapshot: PasteboardSnapshot(
                items: [.init(types: [storedType])],
                totalBytes: 16))

        guard hasFrozenConfiguration(TranscriptionHistory.Entry.self),
              hasFrozenConfiguration(ClipboardHistory.Entry.self) else { return false }

        let incumbentHistoryURL = incumbentDirectory.appendingPathComponent("history.json")
        let incumbentClipboardURL = incumbentDirectory.appendingPathComponent("clipboard-history.json")
        let incumbentEncoder = JSONEncoder()
        incumbentEncoder.dateEncodingStrategy = .iso8601
        incumbentEncoder.outputFormatting = [.prettyPrinted]
        try incumbentEncoder.encode([historyEntry]).write(to: incumbentHistoryURL, options: .atomic)
        try incumbentEncoder.encode([clipboardEntry]).write(to: incumbentClipboardURL, options: .atomic)

        let loadedHistoryLog = PersistedJSONLog<TranscriptionHistory.Entry>(
            url: incumbentHistoryURL,
            queueLabel: AppIdentity.queueLabel("selftest.history-load"),
            maxEntries: { 1 },
            didChange: Notification.Name("VDHistoryFormatLoadDidChange"),
            failureSubsystem: "dictation history",
            failureOperation: "save rolling history")
        let loadedClipboardLog = PersistedJSONLog<ClipboardHistory.Entry>(
            url: incumbentClipboardURL,
            queueLabel: AppIdentity.queueLabel("selftest.clipboard-load"),
            maxEntries: { 1 },
            didChange: Notification.Name("VDClipboardFormatLoadDidChange"),
            failureSubsystem: "clipboard history",
            failureOperation: "save")
        guard let loadedHistory = loadedHistoryLog.all().first,
              let loadedClipboard = loadedClipboardLog.all().first,
              historyEntriesEqual(loadedHistory, historyEntry),
              clipboardEntriesEqual(loadedClipboard, clipboardEntry) else { return false }

        let refactoredHistoryURL = refactoredDirectory.appendingPathComponent("history.json")
        let refactoredClipboardURL = refactoredDirectory.appendingPathComponent("clipboard-history.json")
        let refactoredHistoryLog = PersistedJSONLog<TranscriptionHistory.Entry>(
            url: refactoredHistoryURL,
            queueLabel: AppIdentity.queueLabel("selftest.history-save"),
            maxEntries: { 1 },
            didChange: Notification.Name("VDHistoryFormatSaveDidChange"),
            failureSubsystem: "dictation history",
            failureOperation: "save rolling history")
        refactoredHistoryLog.append(loadedHistory)
        refactoredHistoryLog.flush()
        let refactoredClipboardLog = PersistedJSONLog<ClipboardHistory.Entry>(
            url: refactoredClipboardURL,
            queueLabel: AppIdentity.queueLabel("selftest.clipboard-save"),
            maxEntries: { 1 },
            didChange: Notification.Name("VDClipboardFormatSaveDidChange"),
            failureSubsystem: "clipboard history",
            failureOperation: "save")
        refactoredClipboardLog.append(loadedClipboard)
        refactoredClipboardLog.flush()

        let incumbentDecoder = JSONDecoder()
        incumbentDecoder.dateDecodingStrategy = .iso8601
        let historyRoundTrip = try incumbentDecoder.decode(
            [TranscriptionHistory.Entry].self, from: Data(contentsOf: refactoredHistoryURL))
        let clipboardRoundTrip = try incumbentDecoder.decode(
            [ClipboardHistory.Entry].self, from: Data(contentsOf: refactoredClipboardURL))
        return historyRoundTrip.count == 1
            && clipboardRoundTrip.count == 1
            && historyEntriesEqual(historyRoundTrip[0], historyEntry)
            && clipboardEntriesEqual(clipboardRoundTrip[0], clipboardEntry)
    }

    private static func hasFrozenConfiguration<Entry: Codable>(_ type: Entry.Type) -> Bool {
        let encoder = PersistedJSONLog<Entry>.makeEncoder()
        guard encoder.outputFormatting == [.prettyPrinted] else { return false }
        guard case .iso8601 = encoder.dateEncodingStrategy else { return false }
        let decoder = PersistedJSONLog<Entry>.makeDecoder()
        guard case .iso8601 = decoder.dateDecodingStrategy else { return false }
        return PersistedJSONLog<Entry>.writeOptions == [.atomic]
    }

    private static func historyEntriesEqual(_ lhs: TranscriptionHistory.Entry,
                                            _ rhs: TranscriptionHistory.Entry) -> Bool {
        lhs.id == rhs.id
            && lhs.date == rhs.date
            && lhs.text == rhs.text
            && lhs.app == rhs.app
            && lhs.raw == rhs.raw
            && lhs.cleaned == rhs.cleaned
            && lhs.mode == rhs.mode
            && lhs.level == rhs.level
    }

    private static func clipboardEntriesEqual(_ lhs: ClipboardHistory.Entry,
                                              _ rhs: ClipboardHistory.Entry) -> Bool {
        lhs.id == rhs.id
            && lhs.date == rhs.date
            && lhs.preview == rhs.preview
            && lhs.detail == rhs.detail
            && lhs.types == rhs.types
            && lhs.snapshot.items == rhs.snapshot.items
            && lhs.snapshot.totalBytes == rhs.snapshot.totalBytes
    }
}
