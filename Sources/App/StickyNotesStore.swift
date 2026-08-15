import Foundation

enum StickyNotesRetention: String, CaseIterable, Codable {
    case oneDay
    case oneWeek
    case forever

    var label: String {
        switch self {
        case .oneDay: return "24 hours"
        case .oneWeek: return "1 week"
        case .forever: return "Indefinitely"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .oneDay: return 24 * 60 * 60
        case .oneWeek: return 7 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}

enum StickyNoteKind: String, Codable, Equatable {
    case scratch
    case fileBacked
}

enum FileBackedTier: String, Codable, Equatable {
    case looseReadWrite
    case vaultReadWrite
    case failClosedReadOnly

    var canRename: Bool { self == .looseReadWrite }
    var canEdit: Bool { self != .failClosedReadOnly }

    init?(decision: PathClassifierDecision) {
        switch decision {
        case .refuseDeniedRoot: return nil
        case .readOnlyVault: self = .vaultReadWrite
        case .readOnlyFailClosed: self = .failClosedReadOnly
        case .readWriteLoose: self = .looseReadWrite
        }
    }
}

struct FileBackedOriginRecord: Codable, Equatable {
    var path: String
    var tier: FileBackedTier
}

/// The concurrency token for one exact version of a file. Both halves are required: mtime cheaply catches
/// normal replacement, while the content hash still catches a same-tick/same-mtime rewrite. A write is never
/// allowed merely because one half happens to match.
struct FileBackedFingerprint: Equatable {
    let modificationTime: TimeInterval
    let contentHash: String
}

struct FileBackedConflict: Equatable {
    let noteId: String
    let mine: String
    let theirs: String
    let diskFingerprint: FileBackedFingerprint
}

enum FileBackedConflictChoice: Equatable {
    case keepMine
    case takeTheirs
    case saveMineAsCopy
}

enum FileBackedSyncResult: Equatable {
    case unchanged(body: String)
    case saved(body: String)
    case merged(body: String)
    case reloaded(body: String)
    case conflict(FileBackedConflict)
    case copiedAndReloaded(body: String, copyURL: URL)
    case readOnly
    case missing
    case failed

    var permitsClose: Bool {
        switch self {
        case .unchanged, .saved, .merged, .reloaded, .copiedAndReloaded:
            return true
        case .conflict, .readOnly, .missing, .failed:
            return false
        }
    }
}

struct StickyNoteWire: Codable, Equatable {
    let id: String
    let body: String
    let title: String
    let kind: StickyNoteKind
    let filePath: String?
    let canRename: Bool
    let canEdit: Bool

    init(id: String, body: String, title: String, kind: StickyNoteKind = .scratch,
         filePath: String? = nil, canRename: Bool = true, canEdit: Bool = true) {
        self.id = id
        self.body = body
        self.title = title
        self.kind = kind
        self.filePath = filePath
        self.canRename = canRename
        self.canEdit = canEdit
    }
}

struct FileBackedOpenResult: Equatable {
    let note: StickyNoteWire
    let focusedExisting: Bool
}

enum FileBackedRenameResult: Equatable {
    case renamed(StickyNoteWire)
    case unchanged(StickyNoteWire)
    case collision
    case locked
    case illegalName
    case missing
    case failed
}

struct StickyNotesHistoryWire: Codable {
    let id: String
    let title: String
    let preview: String
    let closedAt: String
    let expiresAt: String?
}

/// One notes window's membership (L6): its ordered note ids, its active tab, and — for a
/// SECONDARY window — its saved frame. Persisted to `windows.json` so the multi-window arrangement
/// survives a restart. The PRIMARY window's frame is owned by the AppKit frame-autosave (see
/// `NotesWindowController.build`), so its `frame` here is nil.
///
/// windows.json is persisted as an ORDERED array of these records (window-then-tab order for the
/// aggregate is inherent in the array order, primary first). Each element still carries its own
/// `id`, so the on-disk shape is semantically `{windowId: {noteIds, activeId, frame}}` per the L6 spec,
/// with the array giving a deterministic, restart-stable window order that a plain JSON object cannot.
struct WindowMembership: Codable, Equatable {
    let id: String
    var noteIds: [String]
    var activeId: String?
    var frame: String?
    /// The window's persisted MANUAL mini-view flag (notes-miniview A2). ONLY the manual half of the
    /// effective-mini state (`manual OR width < 560`) is persisted; the size-derived half recomputes from the
    /// live window width on load. Defaults to false, so a fresh window opens full.
    var manualMini: Bool = false
}

extension WindowMembership {
    private enum CodingKeys: String, CodingKey { case id, noteIds, activeId, frame, manualMini }

    /// Lenient decode so an older `windows.json` written before the mini flag existed still loads (the missing
    /// key defaults to false) instead of failing the whole arrangement. Declared in an extension so the
    /// synthesized memberwise initializer is preserved for the existing call sites.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        noteIds = try c.decodeIfPresent([String].self, forKey: .noteIds) ?? []
        activeId = try c.decodeIfPresent(String.self, forKey: .activeId)
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        manualMini = try c.decodeIfPresent(Bool.self, forKey: .manualMini) ?? false
    }
}

/// Disk-backed store for the Option+N sticky-notes surface.
///
/// Open notes live as one `.md` file per materialized tab under:
/// `~/Library/Application Support/ViddyDictate/sticky-notes/`.
/// Empty tabs are intentionally lazy: no file, no history entry, no aggregate entry.
final class StickyNotesStore {
    static let shared = StickyNotesStore()

    struct HistoryEntry: Codable, Equatable {
        let id: String
        let filename: String
        let closedAt: Date
    }

    /// One sidecar media attachment on a note (L3/L2). Attachments are sidecar FILES kept in
    /// their original format under `attachments/<note-id>/`, never markdown embeds — the note body never
    /// references them. `id` IS the on-disk filename (a zero-padded ordering prefix + the original name,
    /// e.g. `01-screenshot.png`), stable for the life of the file so the web island can address it for
    /// remove/open. `name` is the original filename shown to the user; `index` is the numeric order key.
    enum AttachmentKind: String, Equatable {
        case image
        case video
    }

    struct AttachmentInfo: Equatable {
        let id: String
        let name: String
        let url: URL
        let index: Int
        let kind: AttachmentKind
    }

    /// Outcome of an add attempt, so the caller can toast the right thing (L3): the soft cap
    /// (20/note) and the media-only rule are enforced here, in the store, not by each caller.
    enum AttachmentAddResult: Equatable {
        case added(AttachmentInfo)
        case rejectedCap
        case rejectedNotMedia
        case failed
    }

    /// Soft cap on attachments per note. Adding beyond this is rejected with a toast.
    static let attachmentSoftCap = 20

    /// Image formats accepted as attachments (kept as-is, no conversion). `jpeg` and `jpg` both allowed.
    static let allowedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Video formats accepted as attachments by extension. Raw video bytes are not sniffed; drag/drop videos
    /// arrive as file URLs or file promises, and the sidecar keeps those files byte-for-byte.
    static let allowedVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "webm"]

    static var allowedMediaExtensions: Set<String> {
        allowedImageExtensions.union(allowedVideoExtensions)
    }

    private let fm = FileManager.default
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("sticky-notes"))
    let root: URL
    private let historyDir: URL
    private let historyURL: URL
    private let titlesURL: URL
    private let aggregateURL: URL
    private let windowsURL: URL
    private let fileBacked: FileBackedNoteEngine
    private let attachments: NotesAttachmentEngine
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(root: URL? = nil, pathClassifier: PathClassifier = PathClassifier()) {
        if let root = root {
            self.root = root
        } else {
            let base = AppPaths.applicationSupportDirectory(fileManager: fm)
            self.root = base.appendingPathComponent("sticky-notes", isDirectory: true)
        }
        self.historyDir = self.root.appendingPathComponent("notes-history", isDirectory: true)
        self.historyURL = self.root.appendingPathComponent("notes-history.json")
        self.titlesURL = self.root.appendingPathComponent("note-titles.json")
        self.aggregateURL = self.root.appendingPathComponent("_open-notes.md")
        self.windowsURL = self.root.appendingPathComponent("windows.json")
        self.fileBacked = FileBackedNoteEngine(
            fileOriginsURL: self.root.appendingPathComponent("file-origins.json"),
            fileManager: fm,
            pathClassifier: pathClassifier)
        self.attachments = NotesAttachmentEngine(
            root: self.root,
            historyDir: self.historyDir,
            fileManager: fm)
        ensureDirectories()
        purgeExpiredHistory(retention: Settings.stickyNotesRetention)
    }

    func openNotes() -> [StickyNoteWire] {
        queue.sync {
            ensureDirectories()
            return openNotesLocked()
        }
    }

    /// Materialize an existing markdown file as a second note kind. The classifier is rerun here even when
    /// the app-open shell already classified the path, so crash-restore and every future caller retain the
    /// same in-app privacy boundary. The opaque id is what flows through windows.json and tab drag payloads;
    /// the canonical origin path lives only in file-origins.json.
    func openFileBackedNote(at candidate: URL) throws -> FileBackedOpenResult {
        try queue.sync {
            ensureDirectories()
            return try fileBacked.openFileBackedNote(at: candidate)
        }
    }

    func isFileBackedNote(id: String) -> Bool {
        queue.sync { fileBacked.isFileBackedNote(id: id) }
    }

    func fileBackedOrigin(id: String) -> FileBackedOriginRecord? {
        queue.sync { fileBacked.fileBackedOrigin(id: id) }
    }

    /// Resolve the real on-disk file Finder should reveal. File-backed tabs use their classified origin;
    /// scratch tabs use the store-owned note-<id>.md path. Missing files are not revealable.
    func revealableFileURL(id rawId: String) -> URL? {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return nil }
            let url: URL
            if let origin = fileBacked.decodeFileOriginsLocked()[id] {
                url = URL(fileURLWithPath: origin.path)
            } else {
                guard Self.validatedScratchNoteId(id) != nil else { return nil }
                url = openURL(for: id)
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }
            return url
        }
    }

    /// Capture the freshest web-island buffer without touching disk. This makes native close/app-quit flushes
    /// independent of JavaScript timer delivery; the next gated sync still performs the disk comparison.
    func observeFileBackedBuffer(id rawId: String, body: String) {
        queue.sync {
            fileBacked.observeFileBackedBuffer(id: rawId, body: body)
        }
    }

    /// Timer/blur sync with an explicit buffer snapshot from the web island.
    func syncFileBackedNote(id rawId: String, body: String) -> FileBackedSyncResult {
        queue.sync {
            fileBacked.syncFileBackedNote(id: rawId, body: body)
        }
    }

    /// Native close/app-quit sync using the last buffer observed from the web island.
    func flushFileBackedNote(id rawId: String) -> FileBackedSyncResult {
        queue.sync {
            fileBacked.flushFileBackedNote(id: rawId)
        }
    }

    /// Commit a clean live-reload baseline only after JavaScript confirms it actually replaced the editor. If
    /// the user typed between the timer request and the native push, no acknowledgement arrives and the old
    /// base/fingerprint remain in force, so the next sync becomes a conflict instead of a clobber.
    func acceptFileBackedReload(id rawId: String, body: String) -> FileBackedSyncResult {
        queue.sync {
            fileBacked.acceptFileBackedReload(id: rawId, body: body)
        }
    }

    func resolveFileBackedConflict(
        _ conflict: FileBackedConflict, choice: FileBackedConflictChoice
    ) -> FileBackedSyncResult {
        queue.sync { fileBacked.resolveFileBackedConflict(conflict, choice: choice) }
    }

    /// Remove only the tab identity after a successful gated close. The real file is never removed or moved.
    @discardableResult
    func dropFileBackedNote(id rawId: String) -> Bool {
        queue.sync {
            fileBacked.dropFileBackedNote(id: rawId)
        }
    }

    /// Close is itself a write trigger. A conflict or write failure leaves the mapping/session alive so the UI
    /// can resolve it; only a safe sync result permits the tab identity to be dropped.
    func closeFileBackedNote(id rawId: String, body: String) -> FileBackedSyncResult {
        queue.sync {
            fileBacked.closeFileBackedNote(id: rawId, body: body)
        }
    }

    func saveOpenNote(id rawId: String, body: String) {
        queue.sync {
            ensureDirectories()
            guard let id = Self.validatedNoteId(rawId) else { return }
            if fileBacked.decodeFileOriginsLocked()[id] != nil {
                _ = fileBacked.syncFileBackedLocked(id: id, body: body)
                return
            }
            let url = openURL(for: id)
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Evaporation is attachment-aware: a note with attachments but no text is NOT empty, so
                // persist an empty body rather than deleting it. Only a truly empty note (no text AND no
                // attachments) loses its file (L3).
                if attachments.hasAttachmentsLocked(id: id) {
                    writeStringLocked("", to: url, operation: "save attachment-only note")
                } else {
                    try? fm.removeItem(at: url)
                }
                return
            }
            writeStringLocked(body, to: url, operation: "save note")
        }
    }

    func closeNote(id rawId: String, body: String) {
        queue.sync {
            ensureDirectories()
            guard let id = Self.validatedNoteId(rawId) else { return }
            if fileBacked.decodeFileOriginsLocked()[id] != nil {
                _ = fileBacked.closeFileBackedLocked(id: id, body: body)
                return
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let open = openURL(for: id)
            let hasAtt = attachments.hasAttachmentsLocked(id: id)
            // Empty ONLY when there is no text AND no attachments — then the note evaporates. Otherwise it
            // soft-deletes to history and its attachment dir follows it (L3).
            guard !trimmed.isEmpty || hasAtt else {
                try? fm.removeItem(at: open)
                removeTitleOverrideLocked(id: id)
                return
            }
            // Write the body (possibly empty for an attachment-only note) so there is a file to archive.
            guard writeStringLocked(body, to: open, operation: "save note before close") else { return }
            let dest = uniqueHistoryURL(filename: open.lastPathComponent)
            guard moveOrRewriteLocked(
                from: open, to: dest, fallbackBody: body, operation: "archive note") else { return }
            var history = loadHistoryLocked()
            let historyId = dest.deletingPathExtension().lastPathComponent
            // The attachment dir follows the note into history under the archived (history) id.
            if hasAtt {
                attachments.moveDirLocked(
                    from: attachments.attachmentsDir(for: id),
                    to: attachments.historyAttachmentsDir(for: historyId))
            }
            if historyId != id {
                var titles = loadTitleOverridesLocked()
                if let title = titles[id] { titles[historyId] = title }
                saveTitleOverridesLocked(titles)
            }
            history.insert(HistoryEntry(id: historyId, filename: dest.lastPathComponent, closedAt: Date()), at: 0)
            saveHistoryLocked(history)
        }
    }

    func restoreHistory(id: String) -> StickyNoteWire? {
        queue.sync {
            ensureDirectories()
            var history = loadHistoryLocked()
            guard let idx = history.firstIndex(where: { $0.id == id }) else { return nil }
            let entry = history.remove(at: idx)
            let src = historyDir.appendingPathComponent(entry.filename)
            guard let body = try? String(contentsOf: src, encoding: .utf8) else {
                saveHistoryLocked(history)
                return nil
            }
            let openId = Self.validatedNoteId(src.deletingPathExtension().lastPathComponent)
                ?? Self.newNoteId()
            let dest = nextAvailableOpenURL(preferredId: openId)
            guard moveOrRewriteLocked(
                from: src, to: dest, fallbackBody: body, operation: "restore note") else { return nil }
            saveHistoryLocked(history)
            let restoredId = dest.deletingPathExtension().lastPathComponent
            // Bring the archived attachment dir back to the open side under the restored id.
            attachments.moveDirLocked(
                from: attachments.historyAttachmentsDir(for: entry.id),
                to: attachments.attachmentsDir(for: restoredId))
            if restoredId != entry.id {
                var titles = loadTitleOverridesLocked()
                if let title = titles[entry.id] {
                    titles[restoredId] = title
                    titles.removeValue(forKey: entry.id)
                    saveTitleOverridesLocked(titles)
                }
            }
            let titles = loadTitleOverridesLocked()
            return StickyNoteWire(id: restoredId, body: body,
                                  title: Self.displayTitle(id: restoredId, body: body, overrides: titles))
        }
    }

    func deleteHistory(id: String) {
        queue.sync {
            var history = loadHistoryLocked()
            guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
            let entry = history.remove(at: idx)
            try? fm.removeItem(at: historyDir.appendingPathComponent(entry.filename))
            try? fm.removeItem(at: attachments.historyAttachmentsDir(for: entry.id))
            removeTitleOverrideLocked(id: id)
            saveHistoryLocked(history)
        }
    }

    func history(retention: StickyNotesRetention) -> [StickyNotesHistoryWire] {
        queue.sync {
            purgeExpiredHistoryLocked(retention: retention)
            let titles = loadTitleOverridesLocked()
            return loadHistoryLocked().compactMap { entry in
                let url = historyDir.appendingPathComponent(entry.filename)
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let expiresAt = retention.seconds.map { iso.string(from: entry.closedAt.addingTimeInterval($0)) }
                return StickyNotesHistoryWire(id: entry.id,
                                              title: Self.displayTitle(id: entry.id, body: body, overrides: titles),
                                              preview: Self.preview(for: body),
                                              closedAt: iso.string(from: entry.closedAt),
                                              expiresAt: expiresAt)
            }
        }
    }

    @discardableResult
    func renameNote(id rawId: String, title rawTitle: String) -> String? {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return nil }
            if let origin = fileBacked.decodeFileOriginsLocked()[id] {
                return URL(fileURLWithPath: origin.path).lastPathComponent
            }
            var titles = loadTitleOverridesLocked()
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                titles.removeValue(forKey: id)
            } else {
                titles[id] = Self.truncatedTitle(trimmed)
            }
            saveTitleOverridesLocked(titles)
            let body = (try? String(contentsOf: openURL(for: id), encoding: .utf8)) ?? ""
            return Self.displayTitle(id: id, body: body, overrides: titles)
        }
    }

    /// Rename a loose file-backed tab by moving its real file in place. The extension is always `.md`; vault
    /// and fail-closed tabs are locked. The side-table update is atomic and rolls the file move back if it
    /// cannot be persisted, so a failed rename leaves the original path authoritative.
    func renameFileBackedNote(id rawId: String, stem rawStem: String) -> FileBackedRenameResult {
        queue.sync {
            fileBacked.renameFileBackedNote(id: rawId, stem: rawStem)
        }
    }

    func rewriteAggregate(tabOrder: [String], activeId: String?) {
        queue.sync {
            ensureDirectories()
            let materialized = openNotesLocked()
            let byId = Dictionary(uniqueKeysWithValues: materialized.map { ($0.id, $0) })
            var seen = Set<String>()
            var notes: [StickyNoteWire] = []
            for rawId in tabOrder {
                guard let id = Self.validatedNoteId(rawId), !seen.contains(id),
                      let note = byId[id] else { continue }
                seen.insert(id)
                notes.append(note)
            }
            let known = Set(notes.map(\.id))
            for note in materialized where !known.contains(note.id) {
                notes.append(note)
            }
            var attachmentsByNote: [String: [String]] = [:]
            for note in notes {
                let paths = attachments.attachmentFilesLocked(for: note.id).map(\.path)
                if !paths.isEmpty { attachmentsByNote[note.id] = paths }
            }
            let filePaths = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
                note.filePath.map { (note.id, $0) }
            })
            let markdown = Self.aggregateMarkdown(
                notes: notes, activeId: activeId, attachmentsByNote: attachmentsByNote,
                filePathsByNote: filePaths)
            writeStringLocked(markdown, to: aggregateURL, operation: "rewrite open-notes aggregate")
        }
    }

    // MARK: - Multi-window membership (L6)

    /// Persist the current window arrangement to `windows.json` (ordered, primary first). Called by the
    /// registry whenever a window's membership changes so the arrangement survives a restart.
    func saveWindows(_ windows: [WindowMembership]) {
        queue.sync {
            ensureDirectories()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try enc.encode(windows).write(to: windowsURL, options: .atomic) }
            catch {
                reportStickyNotesWriteFailure(operation: "save windows", url: windowsURL, error: error)
            }
        }
    }

    /// Load the saved window arrangement, sanitized: each note id is validated, a note appears in at most
    /// ONE window (first-writer wins — dedupe across windows), and an `activeId` that no longer belongs to
    /// its window is dropped. An empty array means "no saved arrangement" (fresh install or pre-L6 upgrade),
    /// in which case the registry creates a single primary that adopts every open note.
    func loadWindows() -> [WindowMembership] {
        queue.sync {
            guard let data = try? Data(contentsOf: windowsURL),
                  let decoded = try? JSONDecoder().decode([WindowMembership].self, from: data) else { return [] }
            var seen = Set<String>()
            return decoded.map { win in
                var ids: [String] = []
                for raw in win.noteIds {
                    guard let id = Self.validatedNoteId(raw), !seen.contains(id) else { continue }
                    seen.insert(id)
                    ids.append(id)
                }
                let active = win.activeId.flatMap { ids.contains($0) ? $0 : nil }
                return WindowMembership(id: win.id, noteIds: ids, activeId: active, frame: win.frame,
                                        manualMini: win.manualMini)
            }
        }
    }

    /// Rewrite `_open-notes.md` across ALL windows (L6). Sections are concatenated in
    /// window-then-tab order; exactly ONE global `(active)` marker is placed on the active tab of the
    /// most-recently-key window (`activeWindowId`). The per-note header/body/attachments format is
    /// byte-for-byte identical to the single-window path, so the `read_open_notes` tool and agents keep
    /// parsing unchanged. A materialized open note not claimed by any window is still emitted (defensively,
    /// at the end, without a marker) so a note is never silently lost from the aggregate.
    func rewriteAggregate(windows: [WindowMembership], activeWindowId: String?) {
        queue.sync {
            ensureDirectories()
            let materialized = openNotesLocked()
            var byId: [String: StickyNoteWire] = [:]
            for note in materialized { byId[note.id] = note }
            let activeWin = windows.first { $0.id == activeWindowId } ?? windows.first
            let globalActiveId = activeWin?.activeId
            var seen = Set<String>()
            var notes: [StickyNoteWire] = []
            for win in windows {
                for rawId in win.noteIds {
                    guard let id = Self.validatedNoteId(rawId), !seen.contains(id), let note = byId[id] else { continue }
                    seen.insert(id)
                    notes.append(note)
                }
            }
            for note in materialized where !seen.contains(note.id) {
                seen.insert(note.id)
                notes.append(note)
            }
            var attachmentsByNote: [String: [String]] = [:]
            for note in notes {
                let paths = attachments.attachmentFilesLocked(for: note.id).map(\.path)
                if !paths.isEmpty { attachmentsByNote[note.id] = paths }
            }
            let filePaths = Dictionary(uniqueKeysWithValues: notes.compactMap { note in
                note.filePath.map { (note.id, $0) }
            })
            let markdown = Self.aggregateMarkdown(
                notes: notes, activeId: globalActiveId, attachmentsByNote: attachmentsByNote,
                filePathsByNote: filePaths)
            writeStringLocked(markdown, to: aggregateURL, operation: "rewrite open-notes aggregate")
        }
    }

    func saveAs(id rawId: String, body: String, destination: URL) throws -> URL {
        guard let id = Self.validatedNoteId(rawId) else { throw CocoaError(.fileWriteInvalidFileName) }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let displayTitle = Self.displayTitle(id: id, body: body, overrides: loadTitleOverrides())
        let stem = Self.filenameStem(forTitle: displayTitle)
        var candidate = destination.appendingPathComponent("\(stem).md")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(stem)-\(counter).md")
            counter += 1
        }
        try body.write(to: candidate, atomically: true, encoding: .utf8)
        // When the note has attachments, export a sibling `<exported-name>-attachments/` folder holding the
        // files under their original names (deduped on collision) (L3).
        let attachments = listAttachments(noteId: id)
        if !attachments.isEmpty {
            let exportedStem = candidate.deletingPathExtension().lastPathComponent
            let folder = destination.appendingPathComponent("\(exportedStem)-attachments", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for info in attachments {
                let ext = (info.name as NSString).pathExtension
                let stem = (info.name as NSString).deletingPathExtension
                var target = folder.appendingPathComponent(info.name)
                var counter = 2
                while fm.fileExists(atPath: target.path) {
                    let dedup = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                    target = folder.appendingPathComponent(dedup)
                    counter += 1
                }
                try? fm.copyItem(at: info.url, to: target)
            }
        }
        return candidate
    }

    /// Persist the new retention setting, then purge history against it in one step — the settings
    /// popup (macOS) and the web-island hamburger bridge both need exactly this sequence.
    func setRetention(_ retention: StickyNotesRetention) {
        Settings.stickyNotesRetention = retention
        purgeExpiredHistory(retention: retention)
    }

    func purgeExpiredHistory(retention: StickyNotesRetention) {
        queue.sync { purgeExpiredHistoryLocked(retention: retention) }
    }

    static func newNoteId(now: Date = Date()) -> String {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "note-\(ms)-\(suffix)"
    }

    static func title(for body: String) -> String {
        for line in body.components(separatedBy: .newlines) {
            let stripped = stripMarkdown(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return truncatedTitle(stripped)
            }
        }
        return "Untitled"
    }

    static func displayTitle(id: String, body: String, overrides: [String: String]) -> String {
        if let override = overrides[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return truncatedTitle(override)
        }
        return title(for: body)
    }

    /// `attachmentsByNote` maps a note id to the absolute paths of its attachment files. A note with
    /// attachments gets an ADDITIVE `**Attachments:**` line plus one bulleted absolute path per file, after
    /// its body inside its own section (L3). The existing header/body format is byte-for-byte
    /// unchanged for notes without attachments, so agents and the `read_open_notes` tool keep parsing.
    static func aggregateMarkdown(notes: [StickyNoteWire], activeId: String?,
                                  attachmentsByNote: [String: [String]] = [:],
                                  filePathsByNote: [String: String] = [:]) -> String {
        var out = "<!-- Auto-generated by ViddyDictate. Read-only. Open sticky notes, in tab order. -->\n\n"
        for note in notes {
            out += "## \(note.title)\(note.id == activeId ? " (active)" : "")\n\n"
            if let path = filePathsByNote[note.id] ?? note.filePath {
                out += "**File:** \(path)\n"
            } else {
                out += note.body
                if !note.body.hasSuffix("\n") { out += "\n" }
            }
            if let paths = attachmentsByNote[note.id], !paths.isEmpty {
                out += "\n**Attachments:**\n"
                for path in paths { out += "- \(path)\n" }
            }
            out += "\n"
        }
        return out
    }

    static func stripMarkdown(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- ", "* ", "+ ", "> "] where s.hasPrefix(marker) {
            s = String(s.dropFirst(marker.count))
        }
        s = s.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "_", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatedTitle(_ s: String) -> String {
        let limit = 20
        guard s.count > limit else { return s }
        return String(s.prefix(limit - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func preview(for body: String) -> String {
        let oneLine = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.isEmpty ? "Empty" : String(oneLine.prefix(140))
    }

    private static func filenameStem(forTitle title: String) -> String {
        let lower = stripMarkdown(title).lowercased()
        let replaced = lower.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = replaced.isEmpty || replaced == "untitled" ? "sticky-note" : String(replaced.prefix(48))
        let stamp = DateFormatter.stickyNotesStamp.string(from: Date())
        return "\(base)-\(stamp)"
    }

    private static func validatedScratchNoteId(_ raw: String) -> String? {
        guard raw.range(of: #"^note-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    private static func validatedFileBackedNoteId(_ raw: String) -> String? {
        guard raw.range(of: #"^file-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    private static func validatedNoteId(_ raw: String) -> String? {
        guard validatedScratchNoteId(raw) != nil || validatedFileBackedNoteId(raw) != nil else { return nil }
        return raw
    }

    private func openURL(for id: String) -> URL {
        root.appendingPathComponent("\(id).md")
    }

    private func nextAvailableOpenURL(preferredId: String) -> URL {
        var candidate = openURL(for: preferredId)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = openURL(for: "\(preferredId)-\(counter)")
            counter += 1
        }
        return candidate
    }

    private func uniqueHistoryURL(filename: String) -> URL {
        var candidate = historyDir.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        var counter = 2
        repeat {
            candidate = historyDir.appendingPathComponent("\(stem)-closed-\(counter).md")
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    /// The materialized open notes: scratch files/attachment-only notes plus every readable external origin,
    /// including an empty external file. File-backed titles come only from the filename and never consult the
    /// scratch-only title override map.
    private func openNotesLocked() -> [StickyNoteWire] {
        let titles = loadTitleOverridesLocked()
        var bodyById: [String: String] = [:]
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "md" && url.lastPathComponent != "_open-notes.md" {
            guard let body = try? String(contentsOf: url, encoding: .utf8),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            guard Self.validatedScratchNoteId(id) != nil else { continue }
            bodyById[id] = body
        }
        for id in attachments.attachmentNoteIdsLocked() where bodyById[id] == nil {
            guard Self.validatedScratchNoteId(id) != nil else { continue }
            bodyById[id] = ""   // attachment-only scratch note: empty body, still a real note
        }
        var notes = bodyById.keys.sorted()
            .compactMap { id -> StickyNoteWire? in
                let body = bodyById[id] ?? ""
                return StickyNoteWire(id: id, body: body,
                                      title: Self.displayTitle(id: id, body: body, overrides: titles))
        }
        notes.append(contentsOf: fileBacked.openNotesLocked())
        return notes
    }

    private func loadHistoryLocked() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func saveHistoryLocked(_ entries: [HistoryEntry]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        do { try enc.encode(entries).write(to: historyURL, options: .atomic) }
        catch {
            reportStickyNotesWriteFailure(operation: "save history", url: historyURL, error: error)
        }
    }

    private func loadTitleOverrides() -> [String: String] {
        queue.sync { loadTitleOverridesLocked() }
    }

    private func loadTitleOverridesLocked() -> [String: String] {
        guard let data = try? Data(contentsOf: titlesURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded.filter { Self.validatedScratchNoteId($0.key) != nil && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func saveTitleOverridesLocked(_ titles: [String: String]) {
        let clean = titles
            .filter { Self.validatedScratchNoteId($0.key) != nil && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .mapValues { Self.truncatedTitle($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let data: Data
        do { data = try JSONEncoder().encode(clean) }
        catch {
            reportStickyNotesWriteFailure(operation: "encode titles", url: titlesURL, error: error)
            return
        }
        if clean.isEmpty {
            try? fm.removeItem(at: titlesURL)
        } else {
            do { try data.write(to: titlesURL, options: .atomic) }
            catch {
                reportStickyNotesWriteFailure(operation: "save titles", url: titlesURL, error: error)
            }
        }
    }

    private func removeTitleOverrideLocked(id: String) {
        var titles = loadTitleOverridesLocked()
        if titles.removeValue(forKey: id) != nil {
            saveTitleOverridesLocked(titles)
        }
    }

    private func purgeExpiredHistoryLocked(retention: StickyNotesRetention) {
        guard let seconds = retention.seconds else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        var kept: [HistoryEntry] = []
        var changed = false
        for entry in loadHistoryLocked() {
            if entry.closedAt < cutoff {
                try? fm.removeItem(at: historyDir.appendingPathComponent(entry.filename))
                try? fm.removeItem(at: attachments.historyAttachmentsDir(for: entry.id))
                removeTitleOverrideLocked(id: entry.id)
                changed = true
            } else {
                kept.append(entry)
            }
        }
        if changed { saveHistoryLocked(kept) }
    }

    // MARK: - Attachments (L3)

    /// True when the note has at least one attachment. Public wrapper for callers outside the queue.
    func hasAttachments(id rawId: String) -> Bool {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return false }
            return attachments.hasAttachmentsLocked(id: id)
        }
    }

    /// The note's attachments in display order (ascending numeric prefix).
    func listAttachments(noteId rawId: String) -> [AttachmentInfo] {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return [] }
            return attachments.attachmentInfosLocked(for: id)
        }
    }

    /// Add a media file (a dropped/on-disk file URL or a resolved file promise). The extension must be an
    /// accepted image or video type; the file is copied as-is (no conversion). Enforces the per-note soft cap.
    @discardableResult
    func addAttachment(noteId rawId: String, fileURL: URL) -> AttachmentAddResult {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return .failed }
            return attachments.addAttachmentLocked(id: id, fileURL: fileURL)
        }
    }

    /// Add raw image data (e.g. an image dragged from a browser, or pasteboard image bytes). The format is
    /// sniffed from the magic bytes; non-image data is rejected. Enforces the per-note soft cap.
    @discardableResult
    func addAttachment(noteId rawId: String, data: Data, suggestedName: String) -> AttachmentAddResult {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return .failed }
            return attachments.addAttachmentLocked(id: id, data: data, suggestedName: suggestedName)
        }
    }

    /// Remove one attachment by its id (its on-disk filename). Cleans up the note's attachment dir when the
    /// last one goes, so `hasAttachments` and evaporation stay correct.
    func removeAttachment(noteId rawId: String, attachmentId: String) {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return }
            attachments.removeAttachmentLocked(id: id, attachmentId: attachmentId)
        }
    }

    /// Rename one attachment's original name in place, KEEPING its `NN-` ordering prefix and its on-disk
    /// media extension — so display order stays stable but the `id` (the filename) changes, which means the
    /// caller MUST re-push `attachments` afterward (mirror the duplicate flow). The web island posts the
    /// user's desired name; the numeric prefix and the stored extension are authoritative and preserved here.
    /// An attempt to change the extension / swap the media type is rejected, as is any path-traversal shape
    /// (in either the source id or the new name), a missing source, or a name that already exists.
    func renameAttachment(noteId rawId: String, attachmentId: String, newName rawNewName: String) {
        queue.sync {
            guard let id = Self.validatedNoteId(rawId) else { return }
            attachments.renameAttachmentLocked(
                id: id, attachmentId: attachmentId, newName: rawNewName)
        }
    }

    /// Copy every attachment from one note to another, preserving filenames and order (used by duplicate).
    func copyAttachments(fromNoteId rawSrc: String, toNoteId rawDst: String) {
        queue.sync {
            guard let src = Self.validatedNoteId(rawSrc), let dst = Self.validatedNoteId(rawDst) else { return }
            attachments.copyAttachmentsLocked(fromNoteId: src, toNoteId: dst)
        }
    }

    private func moveOrRewriteLocked(
        from src: URL, to dest: URL, fallbackBody: String, operation: String
    ) -> Bool {
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: src, to: dest)
            return true
        } catch {
            do {
                try fallbackBody.write(to: dest, atomically: true, encoding: .utf8)
                try fm.removeItem(at: src)
                return true
            } catch {
                reportStickyNotesWriteFailure(operation: operation, url: dest, error: error)
                return false
            }
        }
    }

    private func ensureDirectories() {
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        } catch {
            reportStickyNotesWriteFailure(operation: "create directories", url: root, error: error)
        }
    }

    @discardableResult
    private func writeStringLocked(_ value: String, to url: URL, operation: String) -> Bool {
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)
            return true
        }
        catch {
            reportStickyNotesWriteFailure(operation: operation, url: url, error: error)
            return false
        }
    }
}

private extension DateFormatter {
    static let stickyNotesStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
