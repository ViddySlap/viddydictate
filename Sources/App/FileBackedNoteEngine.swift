import CryptoKit
import Foundation

/// Queue-confined file-backed note state and persistence. StickyNotesStore owns the serial queue and calls
/// this engine only while holding it, so the engine deliberately has no synchronization of its own.
final class FileBackedNoteEngine {
    private struct PendingFileBackedMerge {
        /// The exact editor bytes that requested this merge. A keystroke racing the conditional reload is a
        /// descendant of these bytes, so they become its correct diff3 base (not the older loaded file).
        let editorBaseBody: String
        let mergedBody: String
        let fingerprint: FileBackedFingerprint
    }

    private struct FileBackedSessionState {
        var baseBody: String
        var bufferBody: String
        var fingerprint: FileBackedFingerprint
        /// A clean diff3 result is already durable on disk but does not become the tab's new base until the
        /// web editor conditionally applies it. Retaining the old base during that round trip lets a racing
        /// keystroke be merged again instead of making it look based on bytes the editor never loaded.
        var pendingMerge: PendingFileBackedMerge? = nil
    }

    private struct FileBackedDiskSnapshot {
        let body: String
        let fingerprint: FileBackedFingerprint
    }

    private let fileOriginsURL: URL
    private let fm: FileManager
    private let pathClassifier: PathClassifier
    /// Runtime-only editor state. Persisted origin identity belongs in file-origins.json; a fingerprint/base is
    /// valid only for this process and is rebuilt from the exact bytes read on open/restore.
    private var fileSessions: [String: FileBackedSessionState] = [:]

    init(
        fileOriginsURL: URL,
        fileManager: FileManager = .default,
        pathClassifier: PathClassifier
    ) {
        self.fileOriginsURL = fileOriginsURL
        self.fm = fileManager
        self.pathClassifier = pathClassifier
    }

    func openFileBackedNote(at candidate: URL) throws -> FileBackedOpenResult {
        let classification = pathClassifier.classification(for: candidate)
        guard let tier = FileBackedTier(decision: classification.decision) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let url = classification.resolvedURL
        guard url.isFileURL, url.pathExtension.lowercased() == "md" else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        let snapshot = try readFileBackedSnapshotLocked(at: url)

        var origins = loadFileOriginsLocked()
        if let existing = origins.first(where: { Self.sameCanonicalPath($0.value.path, url.path) }) {
            let body: String
            if let session = fileSessions[existing.key] {
                body = session.bufferBody
            } else {
                fileSessions[existing.key] = FileBackedSessionState(
                    baseBody: snapshot.body, bufferBody: snapshot.body,
                    fingerprint: snapshot.fingerprint)
                body = snapshot.body
            }
            let note = fileBackedWire(id: existing.key, origin: existing.value, body: body)
            return FileBackedOpenResult(note: note, focusedExisting: true)
        }

        let id = Self.newFileBackedNoteId(existing: Set(origins.keys))
        origins[id] = FileBackedOriginRecord(path: url.path, tier: tier)
        try saveFileOriginsLocked(origins)
        fileSessions[id] = FileBackedSessionState(
            baseBody: snapshot.body, bufferBody: snapshot.body,
            fingerprint: snapshot.fingerprint)
        return FileBackedOpenResult(
            note: fileBackedWire(id: id, origin: origins[id]!, body: snapshot.body),
            focusedExisting: false)
    }

    func isFileBackedNote(id: String) -> Bool {
        decodeFileOriginsLocked()[id] != nil
    }

    func fileBackedOrigin(id: String) -> FileBackedOriginRecord? {
        loadFileOriginsLocked()[id]
    }

    func observeFileBackedBuffer(id rawId: String, body: String) {
        guard let id = Self.validatedNoteId(rawId), var state = fileSessions[id],
              decodeFileOriginsLocked()[id] != nil else { return }
        state.bufferBody = body
        fileSessions[id] = state
    }

    func syncFileBackedNote(id rawId: String, body: String) -> FileBackedSyncResult {
        guard let id = Self.validatedNoteId(rawId) else { return .missing }
        return syncFileBackedLocked(id: id, body: body)
    }

    func flushFileBackedNote(id rawId: String) -> FileBackedSyncResult {
        guard let id = Self.validatedNoteId(rawId), let state = fileSessions[id] else { return .missing }
        return syncFileBackedLocked(id: id, body: state.bufferBody)
    }

    func acceptFileBackedReload(id rawId: String, body: String) -> FileBackedSyncResult {
        guard let id = Self.validatedNoteId(rawId), var state = fileSessions[id],
              let origin = loadFileOriginsLocked()[id] else { return .missing }
        do {
            let disk = try readFileBackedSnapshotLocked(at: URL(fileURLWithPath: origin.path))

            if let pending = state.pendingMerge, pending.mergedBody == body {
                // The editor now really has these bytes, so they become its base even if disk changed yet
                // again during the round trip. A newer disk body is offered as the next clean live reload.
                state.baseBody = body
                state.bufferBody = body
                state.fingerprint = pending.fingerprint
                state.pendingMerge = nil
                if disk.body == body {
                    state.fingerprint = disk.fingerprint
                    fileSessions[id] = state
                    return .unchanged(body: body)
                }
                fileSessions[id] = state
                return .reloaded(body: disk.body)
            }
            if state.bufferBody != state.baseBody {
                return syncFileBackedLocked(id: id, body: state.bufferBody)
            }
            guard disk.body == body else { return .reloaded(body: disk.body) }
            state.baseBody = disk.body
            state.bufferBody = disk.body
            state.fingerprint = disk.fingerprint
            state.pendingMerge = nil
            fileSessions[id] = state
            return .unchanged(body: disk.body)
        } catch {
            return .failed
        }
    }

    func resolveFileBackedConflict(
        _ conflict: FileBackedConflict, choice: FileBackedConflictChoice
    ) -> FileBackedSyncResult {
        resolveFileBackedConflictLocked(conflict, choice: choice)
    }

    @discardableResult
    func dropFileBackedNote(id rawId: String) -> Bool {
        guard let id = Self.validatedNoteId(rawId) else { return false }
        return dropFileBackedNoteLocked(id: id)
    }

    func closeFileBackedNote(id rawId: String, body: String) -> FileBackedSyncResult {
        guard let id = Self.validatedNoteId(rawId) else { return .missing }
        return closeFileBackedLocked(id: id, body: body)
    }

    func closeFileBackedLocked(id: String, body: String) -> FileBackedSyncResult {
        let result = syncFileBackedLocked(id: id, body: body)
        if result.permitsClose, !dropFileBackedNoteLocked(id: id) { return .failed }
        return result
    }

    func bufferBodyLocked(id: String) -> String? {
        fileSessions[id]?.bufferBody
    }

    func renameFileBackedNote(id rawId: String, stem rawStem: String) -> FileBackedRenameResult {
        guard let id = Self.validatedNoteId(rawId) else { return .missing }
        var origins = loadFileOriginsLocked()
        guard var origin = origins[id] else { return .missing }
        guard origin.tier.canRename else { return .locked }

        let currentURL = URL(fileURLWithPath: origin.path).standardizedFileURL
        var stem = rawStem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".md") { stem.removeLast(3) }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty {
            let body = fileSessions[id]?.bufferBody
                ?? (try? String(contentsOf: currentURL, encoding: .utf8)) ?? ""
            return .unchanged(fileBackedWire(id: id, origin: origin, body: body))
        }
        guard Self.isLegalFileStem(stem) else { return .illegalName }

        let destination = currentURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).md", isDirectory: false)
            .standardizedFileURL
        if Self.sameCanonicalPath(currentURL.path, destination.path) {
            let body = fileSessions[id]?.bufferBody
                ?? (try? String(contentsOf: currentURL, encoding: .utf8)) ?? ""
            return .unchanged(fileBackedWire(id: id, origin: origin, body: body))
        }
        guard !fm.fileExists(atPath: destination.path) else { return .collision }

        let previous = origin
        do {
            try fm.moveItem(at: currentURL, to: destination)
            origin.path = destination.path
            origins[id] = origin
            do {
                try saveFileOriginsLocked(origins)
            } catch {
                try? fm.moveItem(at: destination, to: currentURL)
                origins[id] = previous
                return .failed
            }
            let body = fileSessions[id]?.bufferBody
                ?? (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            return .renamed(fileBackedWire(id: id, origin: origin, body: body))
        } catch {
            return .failed
        }
    }

    /// The readable external origins, including an empty external file. File-backed titles come only from
    /// the filename and never consult the scratch-only title override map.
    func openNotesLocked() -> [StickyNoteWire] {
        var notes: [StickyNoteWire] = []
        for (id, origin) in loadFileOriginsLocked().sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: origin.path)
            guard let snapshot = try? readFileBackedSnapshotLocked(at: url) else { continue }
            let body: String
            if let session = fileSessions[id] {
                body = session.bufferBody
            } else {
                fileSessions[id] = FileBackedSessionState(
                    baseBody: snapshot.body, bufferBody: snapshot.body,
                    fingerprint: snapshot.fingerprint)
                body = snapshot.body
            }
            notes.append(fileBackedWire(id: id, origin: origin, body: body))
        }
        return notes
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

    private static func newFileBackedNoteId(existing: Set<String>) -> String {
        var id = "file-\(UUID().uuidString.lowercased())"
        while existing.contains(id) { id = "file-\(UUID().uuidString.lowercased())" }
        return id
    }

    private static func sameCanonicalPath(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().standardizedFileURL.path
        return left.compare(right, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    private static func isLegalFileStem(_ stem: String) -> Bool {
        guard stem != ".", stem != ".." else { return false }
        let illegal = CharacterSet(charactersIn: "/:\0\n\r")
            .union(.controlCharacters)
        return stem.rangeOfCharacter(from: illegal) == nil
    }

    private func fileBackedWire(id: String, origin: FileBackedOriginRecord, body: String) -> StickyNoteWire {
        let url = URL(fileURLWithPath: origin.path)
        return StickyNoteWire(
            id: id, body: body, title: url.lastPathComponent, kind: .fileBacked,
            filePath: url.path, canRename: origin.tier.canRename, canEdit: origin.tier.canEdit)
    }

    private func readFileBackedSnapshotLocked(at url: URL) throws -> FileBackedDiskSnapshot {
        let data = try Data(contentsOf: url)
        guard let body = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FileBackedDiskSnapshot(
            body: body,
            fingerprint: FileBackedFingerprint(modificationTime: modified, contentHash: hash))
    }

    /// The one and only original-file write gate. Callers supply the latest editor buffer; this method reads
    /// disk first, compares it with the exact version last loaded, and only writes on an unchanged fingerprint.
    func syncFileBackedLocked(
        id: String, body: String, externalWriteRetry: Int = 0
    ) -> FileBackedSyncResult {
        guard let origin = loadFileOriginsLocked()[id] else { return .missing }
        let url = URL(fileURLWithPath: origin.path)
        if !fm.fileExists(atPath: url.path) {
            return recreateVanishedFileBackedLocked(
                id: id, body: body, origin: origin, url: url, externalWriteRetry: externalWriteRetry)
        }
        let disk: FileBackedDiskSnapshot
        do { disk = try readFileBackedSnapshotLocked(at: url) }
        catch {
            reportStickyNotesWriteFailure(
                operation: "read file-backed note before save", url: url, error: error)
            return .failed
        }

        guard var state = fileSessions[id] else {
            // A missing base token is never permission to write. Recover only when the caller's buffer exactly
            // matches disk (clean); a divergent buffer fails closed so it cannot become a blind overwrite.
            fileSessions[id] = FileBackedSessionState(
                baseBody: disk.body, bufferBody: disk.body, fingerprint: disk.fingerprint)
            return body == disk.body ? .unchanged(body: disk.body) : .failed
        }
        state.bufferBody = body
        fileSessions[id] = state

        if let pending = state.pendingMerge {
            guard origin.tier.canEdit else { return .readOnly }
            return autoMergeFileBackedLocked(
                id: id, state: state, base: pending.editorBaseBody, mine: body,
                disk: disk, url: url, externalWriteRetry: externalWriteRetry)
        }
        let dirty = body != state.baseBody

        if disk.fingerprint == state.fingerprint {
            guard dirty else { return .unchanged(body: body) }
            guard origin.tier.canEdit else { return .readOnly }
            return writeFileBackedLocked(id: id, body: body, url: url)
        }

        if !dirty {
            // Do not advance the base yet. The web island conditionally applies this reload only if its buffer
            // still equals the request body, then acknowledges via acceptFileBackedReload. Advancing here
            // would let a keystroke racing this response make the old editor text look based on new disk.
            return .reloaded(body: disk.body)
        }
        guard origin.tier.canEdit else { return .readOnly }
        return autoMergeFileBackedLocked(
            id: id, state: state, base: state.baseBody, mine: body,
            disk: disk, url: url, externalWriteRetry: externalWriteRetry)
    }

    private func autoMergeFileBackedLocked(
        id: String, state initialState: FileBackedSessionState, base: String, mine: String,
        disk: FileBackedDiskSnapshot, url: URL, externalWriteRetry: Int
    ) -> FileBackedSyncResult {
        var state = initialState
        switch MarkdownDiff3.merge(base: base, mine: mine, theirs: disk.body) {
        case .merged(let merged):
            do {
                // Recheck immediately before the atomic replacement. If another writer won the interval
                // between our first read and this point, recompute from its version instead of overwriting it.
                let latest = try readFileBackedSnapshotLocked(at: url)
                guard latest.fingerprint == disk.fingerprint else {
                    guard externalWriteRetry < 3 else { return .failed }
                    return syncFileBackedLocked(
                        id: id, body: mine, externalWriteRetry: externalWriteRetry + 1)
                }
                let written: FileBackedDiskSnapshot
                if merged == latest.body {
                    written = latest
                } else {
                    try Data(merged.utf8).write(to: url, options: .atomic)
                    written = try readFileBackedSnapshotLocked(at: url)
                }
                // Keep the ordinary base/fingerprint on the bytes the editor last loaded. The pending token
                // separately retains the editor bytes that requested this merge so a racing keystroke uses
                // that exact descendant base; only fileReloadApplied advances the ordinary loaded base.
                state.pendingMerge = PendingFileBackedMerge(
                    editorBaseBody: mine, mergedBody: written.body, fingerprint: written.fingerprint)
                fileSessions[id] = state
                return .merged(body: written.body)
            } catch {
                reportStickyNotesWriteFailure(
                    operation: "auto-merge file-backed note", url: url, error: error)
                return .failed
            }
        case .conflict:
            state.pendingMerge = nil
            fileSessions[id] = state
        }
        return .conflict(FileBackedConflict(
            noteId: id, mine: mine, theirs: disk.body, diskFingerprint: disk.fingerprint))
    }

    /// The backing file vanished under an open tab (a Finder delete, or a rename, which is a delete from
    /// this path's point of view). The buffer is the only surviving copy, so a divergent buffer recreates
    /// the file at the origin path on the next write; a clean buffer has nothing to persist and must not
    /// resurrect a deliberate delete, so it stays a no-op that still permits close/quit to drop the tab.
    private func recreateVanishedFileBackedLocked(
        id: String, body: String, origin: FileBackedOriginRecord, url: URL, externalWriteRetry: Int
    ) -> FileBackedSyncResult {
        // A missing base token is never permission to write, even at a path with nothing to overwrite.
        guard var state = fileSessions[id] else { return .failed }
        state.bufferBody = body
        fileSessions[id] = state
        if state.pendingMerge == nil, body == state.baseBody { return .unchanged(body: body) }
        guard origin.tier.canEdit else { return .readOnly }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            reportStickyNotesWriteFailure(
                operation: "recreate vanished file-backed note", url: url, error: error)
            return .failed
        }
        guard !fm.fileExists(atPath: url.path) else {
            // Another writer recreated the path first; re-enter the ordinary fingerprint-gated path
            // against that new file instead of overwriting it.
            guard externalWriteRetry < 3 else { return .failed }
            return syncFileBackedLocked(id: id, body: body, externalWriteRetry: externalWriteRetry + 1)
        }
        return writeFileBackedLocked(id: id, body: body, url: url)
    }

    private func writeFileBackedLocked(id: String, body: String, url: URL) -> FileBackedSyncResult {
        do {
            try Data(body.utf8).write(to: url, options: .atomic)
            let written = try readFileBackedSnapshotLocked(at: url)
            fileSessions[id] = FileBackedSessionState(
                baseBody: written.body, bufferBody: written.body, fingerprint: written.fingerprint)
            return .saved(body: written.body)
        } catch {
            reportStickyNotesWriteFailure(operation: "save file-backed note", url: url, error: error)
            return .failed
        }
    }

    private func resolveFileBackedConflictLocked(
        _ conflict: FileBackedConflict, choice: FileBackedConflictChoice
    ) -> FileBackedSyncResult {
        guard let id = Self.validatedNoteId(conflict.noteId), var state = fileSessions[id],
              let origin = loadFileOriginsLocked()[id] else { return .missing }
        let url = URL(fileURLWithPath: origin.path)
        let disk: FileBackedDiskSnapshot
        do { disk = try readFileBackedSnapshotLocked(at: url) }
        catch {
            reportStickyNotesWriteFailure(operation: "read file-backed conflict", url: url, error: error)
            return .failed
        }

        switch choice {
        case .keepMine:
            guard origin.tier.canEdit else { return .readOnly }
            // The choice applies to the disk version the user was shown. If another writer lands while the
            // alert is open, surface a fresh conflict rather than silently including that new write in the
            // deliberate overwrite.
            guard disk.fingerprint == conflict.diskFingerprint else {
                return syncFileBackedLocked(id: id, body: state.bufferBody)
            }
            return writeFileBackedLocked(id: id, body: state.bufferBody, url: url)

        case .takeTheirs:
            state.baseBody = disk.body
            state.bufferBody = disk.body
            state.fingerprint = disk.fingerprint
            state.pendingMerge = nil
            fileSessions[id] = state
            return .reloaded(body: disk.body)

        case .saveMineAsCopy:
            guard origin.tier.canEdit else { return .readOnly }
            do {
                let copyURL = try writeFileBackedCopyLocked(body: state.bufferBody, beside: url)
                // Reload the latest original after the sidecar is safely materialized. The original is never
                // written on this branch, even if an agent changes it again while the choice is being made.
                let latest = try readFileBackedSnapshotLocked(at: url)
                fileSessions[id] = FileBackedSessionState(
                    baseBody: latest.body, bufferBody: latest.body, fingerprint: latest.fingerprint)
                return .copiedAndReloaded(body: latest.body, copyURL: copyURL)
            } catch {
                reportStickyNotesWriteFailure(
                    operation: "save file-backed conflict copy", url: url, error: error)
                return .failed
            }
        }
    }

    private func writeFileBackedCopyLocked(body: String, beside original: URL) throws -> URL {
        let directory = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var counter = 1
        var candidate = directory.appendingPathComponent("\(stem)-ViddyDictate-copy-\(stamp).md")
        while fm.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = directory.appendingPathComponent(
                "\(stem)-ViddyDictate-copy-\(stamp)-\(counter).md")
        }

        let temporary = directory.appendingPathComponent(".viddydictate-copy-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try Data(body.utf8).write(to: temporary, options: .atomic)
        // moveItem refuses an existing destination, so a same-tick collision cannot overwrite a sidecar.
        try fm.moveItem(at: temporary, to: candidate)
        return candidate
    }

    func dropFileBackedNoteLocked(id: String) -> Bool {
        var origins = decodeFileOriginsLocked()
        guard origins.removeValue(forKey: id) != nil else { return false }
        do {
            try saveFileOriginsLocked(origins)
            fileSessions.removeValue(forKey: id)
            return true
        } catch {
            reportStickyNotesWriteFailure(
                operation: "close file-backed tab", url: fileOriginsURL, error: error)
            return false
        }
    }

    /// Decode and reclassify every persisted origin before it is allowed to become a live tab. A sidecar
    /// edited behind the app cannot bypass the denied-root arm, and ambiguous registry state becomes read-only.
    func loadFileOriginsLocked() -> [String: FileBackedOriginRecord] {
        var clean: [String: FileBackedOriginRecord] = [:]
        for (id, record) in decodeFileOriginsLocked() {
            let classification = pathClassifier.classification(for: URL(fileURLWithPath: record.path))
            guard classification.resolvedURL.pathExtension.lowercased() == "md",
                  let tier = FileBackedTier(decision: classification.decision) else { continue }
            clean[id] = FileBackedOriginRecord(path: classification.resolvedURL.path, tier: tier)
        }
        return clean
    }

    /// Decode the side table without resolving or reading any origin path. Retention/close guards use this
    /// identity-only view so a mapping that later becomes denied can still be dropped as a tab without ever
    /// falling through to the scratch lifecycle or opening the external file.
    func decodeFileOriginsLocked() -> [String: FileBackedOriginRecord] {
        guard let data = try? Data(contentsOf: fileOriginsURL),
              let decoded = try? JSONDecoder().decode([String: FileBackedOriginRecord].self, from: data)
        else { return [:] }
        return decoded.filter {
            Self.validatedFileBackedNoteId($0.key) != nil
                && NSString(string: $0.value.path).isAbsolutePath
        }
    }

    private func saveFileOriginsLocked(_ origins: [String: FileBackedOriginRecord]) throws {
        let clean = origins.filter { Self.validatedFileBackedNoteId($0.key) != nil }
        if clean.isEmpty {
            if fm.fileExists(atPath: fileOriginsURL.path) { try fm.removeItem(at: fileOriginsURL) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(clean).write(to: fileOriginsURL, options: .atomic)
    }
}
