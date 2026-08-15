import Foundation

/// Queue-held sidecar attachment operations for `StickyNotesStore`.
///
/// The store owns serialization; this engine owns the attachment filesystem layout and all attachment
/// mutations. Every method is called while the store's serial queue is held.
final class NotesAttachmentEngine {
    private let fm: FileManager
    private let root: URL
    private let historyDir: URL

    init(root: URL, historyDir: URL, fileManager: FileManager) {
        self.root = root
        self.historyDir = historyDir
        self.fm = fileManager
    }

    private var attachmentsRootDir: URL {
        root.appendingPathComponent("attachments", isDirectory: true)
    }

    private var historyAttachmentsRootDir: URL {
        historyDir.appendingPathComponent("attachments", isDirectory: true)
    }

    func attachmentsDir(for id: String) -> URL {
        attachmentsRootDir.appendingPathComponent(id, isDirectory: true)
    }

    func historyAttachmentsDir(for id: String) -> URL {
        historyAttachmentsRootDir.appendingPathComponent(id, isDirectory: true)
    }

    func hasAttachmentsLocked(id: String) -> Bool {
        !attachmentFilesLocked(for: id).isEmpty
    }

    /// The attachment files in a note's dir, media-typed only (a stray `.DS_Store` never counts as an
    /// attachment), sorted by their zero-padded numeric prefix.
    func attachmentFilesLocked(inDir dir: URL) -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { MediaSniffer.mediaKind(forExtension: $0.pathExtension) != nil }
            .sorted { a, b in
                let pa = MediaSniffer.numericPrefix(of: a.lastPathComponent)
                let pb = MediaSniffer.numericPrefix(of: b.lastPathComponent)
                if pa != pb { return pa < pb }
                return a.lastPathComponent < b.lastPathComponent
            }
    }

    func attachmentFilesLocked(for id: String) -> [URL] {
        attachmentFilesLocked(inDir: attachmentsDir(for: id))
    }

    func attachmentInfosLocked(for id: String) -> [StickyNotesStore.AttachmentInfo] {
        attachmentFilesLocked(for: id).compactMap { url in
            guard let kind = MediaSniffer.mediaKind(forExtension: url.pathExtension) else { return nil }
            let filename = url.lastPathComponent
            return StickyNotesStore.AttachmentInfo(
                id: filename,
                name: Self.originalName(fromStored: filename),
                url: url,
                index: MediaSniffer.numericPrefix(of: filename),
                kind: kind)
        }
    }

    /// Note ids that have at least one attachment (their `attachments/<id>/` dir holds a media file). Used
    /// by `openNotesLocked` so an attachment-only note surfaces as a tab.
    func attachmentNoteIdsLocked() -> [String] {
        let dirs = (try? fm.contentsOfDirectory(
            at: attachmentsRootDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            guard !attachmentFilesLocked(inDir: url).isEmpty else { return nil }
            return url.lastPathComponent
        }
    }

    func addAttachmentLocked(id: String, fileURL: URL) -> StickyNotesStore.AttachmentAddResult {
        guard MediaSniffer.mediaKind(forExtension: fileURL.pathExtension) != nil else {
            return .rejectedNotMedia
        }
        let name = Self.sanitizeFilename(fileURL.lastPathComponent)
        return addAttachmentLocked(id: id, name: name) { dest in
            try self.fm.copyItem(at: fileURL, to: dest)
        }
    }

    func addAttachmentLocked(
        id: String, data: Data, suggestedName: String
    ) -> StickyNotesStore.AttachmentAddResult {
        guard let ext = MediaSniffer.imageExtension(forData: data) else { return .rejectedNotMedia }
        let name = Self.attachmentName(fromSuggested: suggestedName, fallbackExt: ext)
        return addAttachmentLocked(id: id, name: name) { dest in
            try data.write(to: dest, options: .atomic)
        }
    }

    func removeAttachmentLocked(id: String, attachmentId: String) {
        // The id is a bare filename; reject any path-traversal shape before touching disk.
        guard !attachmentId.isEmpty, !attachmentId.contains("/"),
              attachmentId != "..", !attachmentId.hasPrefix(".") else { return }
        let dir = attachmentsDir(for: id)
        let target = dir.appendingPathComponent(attachmentId)
        guard target.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else { return }
        try? fm.removeItem(at: target)
        if attachmentFilesLocked(inDir: dir).isEmpty { try? fm.removeItem(at: dir) }
    }

    func renameAttachmentLocked(id: String, attachmentId: String, newName rawNewName: String) {
        // The id is a bare filename; reject any path-traversal shape before touching disk (mirror remove).
        guard !attachmentId.isEmpty, !attachmentId.contains("/"),
              attachmentId != "..", !attachmentId.hasPrefix(".") else { return }
        // Keep the exact `NN-` ordering prefix so the numeric sort key (display order) stays stable.
        guard let dash = attachmentId.firstIndex(of: "-") else { return }
        let prefixPart = attachmentId[..<dash]
        guard !prefixPart.isEmpty, prefixPart.allSatisfy({ $0.isNumber }) else { return }
        // The stored extension is authoritative (attachments are always media on disk) and preserved.
        let oldExt = (attachmentId as NSString).pathExtension.lowercased()
        guard MediaSniffer.mediaKind(forExtension: oldExt) != nil else { return }
        // Sanitize the requested name. If it carries a DIFFERENT media extension, that is an attempted
        // extension / media-type change -> reject. Otherwise strip a redundant matching extension so we
        // never double it, and re-append the original extension so a media extension is always enforced.
        let sanitized = Self.sanitizeFilename(rawNewName)
        let requestedExt = (sanitized as NSString).pathExtension.lowercased()
        if MediaSniffer.mediaKind(forExtension: requestedExt) != nil, requestedExt != oldExt { return }
        let baseRaw = requestedExt == oldExt ? (sanitized as NSString).deletingPathExtension : sanitized
        let base = baseRaw.isEmpty ? "attachment" : baseRaw
        let newFilename = "\(prefixPart)-\(base).\(oldExt)"
        guard newFilename != attachmentId else { return }
        let dir = attachmentsDir(for: id)
        let src = dir.appendingPathComponent(attachmentId)
        let dest = dir.appendingPathComponent(newFilename)
        // Both endpoints must resolve directly inside the note's attachment dir (mirror remove's guard).
        guard src.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
              dest.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else { return }
        guard fm.fileExists(atPath: src.path) else { return }
        guard !fm.fileExists(atPath: dest.path) else { return }   // never clobber a sibling attachment
        do { try fm.moveItem(at: src, to: dest) }
        catch {
            reportStickyNotesWriteFailure(operation: "rename attachment", url: dest, error: error)
        }
    }

    func copyAttachmentsLocked(fromNoteId src: String, toNoteId dst: String) {
        let files = attachmentFilesLocked(for: src)
        guard !files.isEmpty else { return }
        let dstDir = attachmentsDir(for: dst)
        do { try fm.createDirectory(at: dstDir, withIntermediateDirectories: true) }
        catch {
            reportStickyNotesWriteFailure(
                operation: "create attachment directory", url: dstDir, error: error)
            return
        }
        for file in files {
            let dest = dstDir.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                do { try fm.copyItem(at: file, to: dest) }
                catch {
                    reportStickyNotesWriteFailure(operation: "copy attachment", url: dest, error: error)
                }
            }
        }
    }

    private func addAttachmentLocked(
        id: String, name: String, writer: (URL) throws -> Void
    ) -> StickyNotesStore.AttachmentAddResult {
        guard let kind = MediaSniffer.mediaKind(forExtension: (name as NSString).pathExtension) else {
            return .failed
        }
        let dir = attachmentsDir(for: id)
        let existing = attachmentFilesLocked(inDir: dir)
        guard existing.count < StickyNotesStore.attachmentSoftCap else { return .rejectedCap }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return .failed }
        let nextIndex = (existing.map { MediaSniffer.numericPrefix(of: $0.lastPathComponent) }.max() ?? 0) + 1
        let filename = String(format: "%02d-%@", nextIndex, name as NSString)
        let dest = dir.appendingPathComponent(filename)
        do { try writer(dest) } catch { return .failed }
        return .added(StickyNotesStore.AttachmentInfo(
            id: filename, name: name, url: dest, index: nextIndex, kind: kind))
    }

    func moveDirLocked(from src: URL, to dest: URL) {
        guard fm.fileExists(atPath: src.path) else { return }
        do { try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch {
            reportStickyNotesWriteFailure(
                operation: "create attachment directory", url: dest.deletingLastPathComponent(), error: error)
            return
        }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do { try fm.moveItem(at: src, to: dest) }
        catch {
            do {
                try fm.copyItem(at: src, to: dest)
                try fm.removeItem(at: src)
            } catch {
                reportStickyNotesWriteFailure(
                    operation: "move attachment directory", url: dest, error: error)
            }
        }
    }

    /// Filesystem-safe original filename: non-portable characters become `_`, leading dots stripped so we
    /// never mint a hidden or traversal name, never empty.
    private static func sanitizeFilename(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "image" : out
    }

    /// Choose the stored original name for raw image data: keep the suggested name if it already has an
    /// accepted image extension, else fall back to a base + the sniffed extension.
    private static func attachmentName(fromSuggested raw: String, fallbackExt: String) -> String {
        let sanitized = sanitizeFilename(raw)
        if StickyNotesStore.allowedImageExtensions.contains(
            (sanitized as NSString).pathExtension.lowercased()) {
            return sanitized
        }
        let base = (sanitized as NSString).deletingPathExtension
        return "\(base.isEmpty ? "pasted-image" : base).\(fallbackExt)"
    }

    /// Recover the original name from a stored filename by dropping the `NN-` ordering prefix.
    private static func originalName(fromStored filename: String) -> String {
        guard let dash = filename.firstIndex(of: "-") else { return filename }
        let prefix = filename[..<dash]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return filename }
        return String(filename[filename.index(after: dash)...])
    }
}
