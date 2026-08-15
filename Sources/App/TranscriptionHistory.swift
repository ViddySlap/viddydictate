import Foundation

/// Shared persistence engine for capped, newest-first JSON histories.
final class PersistedJSONLog<Entry: Codable> {
    private let queue: DispatchQueue
    private let url: URL
    private let maxEntries: () -> Int
    private let didChange: Notification.Name
    private let failureSubsystem: String
    private let failureOperation: String
    private var entries: [Entry] = []

    init(url: URL,
         queueLabel: String,
         maxEntries: @escaping () -> Int,
         didChange: Notification.Name,
         failureSubsystem: String,
         failureOperation: String) {
        self.url = url
        self.queue = DispatchQueue(label: queueLabel)
        self.maxEntries = maxEntries
        self.didChange = didChange
        self.failureSubsystem = failureSubsystem
        self.failureOperation = failureOperation
        load()
    }

    func all() -> [Entry] { queue.sync { entries } }

    /// The caller-owned predicate runs on the serial queue against the live head before insertion.
    func append(_ entry: Entry, if shouldAppend: @escaping (Entry?) -> Bool = { _ in true }) {
        queue.async {
            guard shouldAppend(self.entries.first) else { return }
            self.entries.insert(entry, at: 0)
            let cap = self.maxEntries()
            if self.entries.count > cap {
                self.entries.removeLast(self.entries.count - cap)
            }
            self.save()
            self.postChange()
        }
    }

    func trimToCap() {
        queue.async {
            let cap = self.maxEntries()
            if self.entries.count > cap {
                self.entries.removeLast(self.entries.count - cap)
                self.save()
            }
            self.postChange()
        }
    }

    func clear() {
        queue.async {
            self.entries.removeAll()
            self.save()
            self.postChange()
        }
    }

    func flush() { queue.sync {} }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var writeOptions: Data.WritingOptions { [.atomic] }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? Self.makeDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        do {
            try Self.makeEncoder().encode(entries).write(to: url, options: Self.writeOptions)
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: failureSubsystem, operation: failureOperation, url: url, error: error)
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: self.didChange, object: nil)
        }
    }
}

/// Rolling, persisted log of delivered transcriptions so a lost dictation can be recovered.
///
/// Stored as JSON at `~/Library/Application Support/ViddyDictate/history.json` — app-local,
/// plaintext, never in the vault. Capped to the most recent `maxEntries`, kept newest-first.
/// Posts `didChange` on every mutation so an open history window can live-refresh.
/// The closed taxonomy of dictation modes recorded in history. Replaces the six ad hoc string literals
/// that were scattered across the finalize/record sites (review item 2: `Entry.mode` was an untyped
/// `String?` whose doc comment claimed only "raw | cleanup" while six literals were really in use, so a
/// typo or a `search` / `search-gemini`-style collision was uncaught). Raw values are the exact legacy
/// strings, so existing history.json entries keep decoding and the History window keeps displaying them.
/// Adding a mode #N means adding one case here, not inventing a fresh literal at the call site.
enum HistoryMode: String {
    case raw
    case cleanup
    case cleanupSelection = "prompt-prep"   // Option+P; legacy string preserved for history compatibility
    case email
    case search
    case searchGemini = "search-gemini"
    case custom   // user-defined custom modes (Hotkeys page); one shared taxonomy row in v1
}

final class TranscriptionHistory {
    static let shared = TranscriptionHistory()
    static let didChange = Notification.Name("VDHistoryDidChange")

    struct Entry: Codable {
        let id: UUID
        let date: Date
        let text: String  // the text that actually landed (== cleaned when cleanup ran, else raw)
        let app: String   // target app label at delivery time ("" if unknown)
        // Cleanup mode adds the dual record so a lost dictation can be recovered either way. All
        // optional so pre-cleanup history.json decodes cleanly (missing keys -> nil).
        let raw: String?      // the original transcript before any LLM cleanup
        let cleaned: String?  // the cleaned text, when cleanup ran (nil in Raw mode / on fallback)
        let mode: String?     // HistoryMode.rawValue (raw | cleanup | prompt-prep | email | search | search-gemini)
        let level: Int?       // effective CleanupLevel rawValue (0/1/2) when cleanup ran; nil for raw + pre-existing entries

        /// True when both an original and a distinct cleaned version exist — drives the dual
        /// "copy original" / "copy cleaned" buttons in the history window.
        var hasBothVersions: Bool {
            guard let raw = raw, let cleaned = cleaned else { return false }
            return raw != cleaned
        }
        /// Back-compat: old entries (and Raw-mode entries) expose the delivered text as the original.
        var original: String { raw ?? text }
    }

    /// Retention cap, user-tunable per tab (persisted in Settings). Read live so a change applies
    /// to the next insert without a relaunch.
    private let log: PersistedJSONLog<Entry>

    init(directory: URL = AppPaths.ensureApplicationSupportDirectory(),
         maxEntries: @escaping () -> Int = { Settings.dictationHistoryMax }) {
        log = PersistedJSONLog(
            url: directory.appendingPathComponent("history.json"),
            queueLabel: AppIdentity.queueLabel("history"),
            maxEntries: maxEntries,
            didChange: Self.didChange,
            failureSubsystem: "dictation history",
            failureOperation: "save rolling history")
    }

    /// Snapshot of all entries, newest-first.
    func all() -> [Entry] { log.all() }

    /// Record a delivery with the full raw/cleaned/mode provenance. `delivered` is what landed in
    /// the field. `level` is the effective CleanupLevel rawValue when cleanup ran (nil for raw).
    /// No-ops on blank delivered text.
    func record(delivered: String, raw: String, cleaned: String?, mode: HistoryMode,
                level: Int? = nil, app: String, id: UUID = UUID()) {
        let trimmed = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Interop L4: `record()` is the single delivery chokepoint for every mode, so it is also where the
        // opt-in infinite history feeds. The store gates itself on Settings.keepFullHistory and writes
        // nothing when off — this line adds nothing to the rolling window's behavior below.
        DictationHistoryStore.shared.append(text: delivered, mode: mode.rawValue)
        log.append(Entry(id: id, date: Date(), text: delivered, app: app,
                         raw: raw, cleaned: cleaned, mode: mode.rawValue, level: level))
    }

    /// Update the retention cap: persist it and trim immediately if the new cap is lower than the
    /// current count. Posts `didChange` so an open window refreshes.
    func setMaxEntries(_ newMax: Int) {
        Settings.dictationHistoryMax = newMax
        log.trimToCap()
    }

    func clear() { log.clear() }

    /// Test-only sync barrier so scratch selftests can observe prior mutations deterministically.
    func flush() { log.flush() }
}
