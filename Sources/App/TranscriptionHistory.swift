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

    /// VDASK-3: insert at the head and write to disk before returning (the async `append` queues its write; a
    /// pending ask-back entry must already be on disk if the app quits a moment later). Posts `didChange`.
    func insertSync(_ entry: Entry) {
        queue.sync {
            entries.insert(entry, at: 0)
            let cap = maxEntries()
            if entries.count > cap { entries.removeLast(entries.count - cap) }
            save()
        }
        postChange()
    }

    /// VDASK-3: replace the entry whose `match` is true with `transform`'s result, saved before returning.
    /// Returns false (and writes nothing) when no entry matches or `transform` returns nil.
    @discardableResult
    func updateSync(where match: (Entry) -> Bool, _ transform: (Entry) -> Entry?) -> Bool {
        let changed: Bool = queue.sync {
            guard let i = entries.firstIndex(where: match), let next = transform(entries[i]) else { return false }
            entries[i] = next
            save()
            return true
        }
        if changed { postChange() }
        return changed
    }

    /// VDASK-3: rewrite entries once at launch (stale "asking" statuses). `transform` returns nil to leave an
    /// entry alone; the file is saved only when at least one entry changed.
    func migrateSync(_ transform: (Entry) -> Entry?) {
        queue.sync {
            var changed = false
            for i in entries.indices {
                if let next = transform(entries[i]) { entries[i] = next; changed = true }
            }
            if changed { save() }
        }
    }

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
        /// VDASK-3: the ask-back review, questions and answers for this take. Optional, so an old history.json
        /// decodes unchanged. `var` with a default keeps every existing `Entry(...)` call compiling.
        var askBack: AskBackRecord? = nil
        /// VDASK-3: "asking" | "writing" | "done" | "write failed" | "canceled" | "unanswered at quit"
        /// (`AskBackHistoryStatus`). nil for every take that never went through ask-back.
        var status: String? = nil

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
        // VDASK-3: a model call does not survive a quit, so an entry still "asking" or "writing" from an
        // earlier launch reads "unanswered at quit" from now on.
        log.migrateSync { entry in
            let relaunched = AskBackHistoryStatus.afterRelaunch(entry.status)
            guard relaunched != entry.status else { return nil }
            var next = entry
            next.status = relaunched
            return next
        }
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
        // VDASK-3: a take that already has an ask-back entry (inserted when its review returned) is UPDATED by
        // id, keeping its record; every other take appends exactly as before.
        let updated = log.updateSync(where: { $0.id == id && $0.askBack != nil }) { existing in
            var next = Entry(id: existing.id, date: existing.date, text: delivered, app: app.isEmpty ? existing.app : app,
                             raw: raw, cleaned: cleaned, mode: mode.rawValue, level: level,
                             askBack: existing.askBack, status: existing.status)
            // A raw landing keeps the status the flow set ("write failed" after a failed write); a landed
            // transform (including a later Retry) closes the take.
            if mode != .raw, next.status != AskBackHistoryStatus.canceled { next.status = AskBackHistoryStatus.done }
            return next
        }
        if updated { return }
        log.append(Entry(id: id, date: Date(), text: delivered, app: app,
                         raw: raw, cleaned: cleaned, mode: mode.rawValue, level: level))
    }

    // MARK: ask-back (VDASK-3). Each call is written to disk before it returns.

    /// An entry for a take whose review just returned, with empty delivered text and status "asking". The
    /// ordinary `record` rejects blank text, so it is not used here.
    func insertPending(id: UUID, transcript: String, askBack: AskBackRecord, app: String = "") {
        log.insertSync(Entry(id: id, date: Date(), text: "", app: app, raw: transcript, cleaned: nil,
                             mode: HistoryMode.cleanup.rawValue, level: nil,
                             askBack: askBack, status: AskBackHistoryStatus.asking))
    }

    /// Change the ask-back entry `id` in place. `delivered` nil leaves the text alone. No entry with that id
    /// (for example it was trimmed by the retention cap) does nothing.
    @discardableResult
    func update(id: UUID, askBack: AskBackRecord, status: String,
                delivered: String? = nil, raw: String? = nil, level: Int? = nil) -> Bool {
        log.updateSync(where: { $0.id == id }) { existing in
            var next = existing
            next.askBack = askBack
            next.status = status
            if let delivered = delivered {
                next = Entry(id: existing.id, date: existing.date, text: delivered, app: existing.app,
                             raw: raw ?? existing.raw,
                             cleaned: status == AskBackHistoryStatus.done ? delivered : existing.cleaned,
                             mode: HistoryMode.cleanup.rawValue, level: level ?? existing.level,
                             askBack: askBack, status: status)
            }
            return next
        }
    }

    /// The one place the flow's History events reach the store.
    func apply(_ event: AskBackHistoryEvent, app: String = "") {
        switch event {
        case .insertPending(let id, let transcript, let record):
            insertPending(id: id, transcript: transcript, askBack: record, app: app)
        case .update(let u):
            update(id: u.id, askBack: u.record, status: u.status, delivered: u.delivered, raw: u.raw, level: u.levelRaw)
        }
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
