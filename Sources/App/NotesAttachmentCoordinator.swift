import Cocoa

struct NotesDropResult {
    let targetId: String
    let activeId: String
    let tabOrder: [String]
    let added: Int
    let capHit: Bool
    let notMedia: Int
    let shouldSendInitialState: Bool
}

final class NotesAttachmentCoordinator {
    private let store: StickyNotesStore

    init(store: StickyNotesStore) {
        self.store = store
    }

    func removeAttachment(noteId: String, attachmentId: String) {
        store.removeAttachment(noteId: noteId, attachmentId: attachmentId)
    }

    func renameAttachment(noteId: String, attachmentId: String, newName: String) {
        store.renameAttachment(noteId: noteId, attachmentId: attachmentId, newName: newName)
    }

    func duplicateAttachments(fromNoteId: String, toNoteId: String) {
        store.copyAttachments(fromNoteId: fromNoteId, toNoteId: toNoteId)
    }

    func openAttachment(noteId: String, attachmentId: String) {
        guard let info = store.listAttachments(noteId: noteId).first(where: { $0.id == attachmentId }) else {
            return
        }
        NSWorkspace.shared.open(info.url)
    }

    func copyAssetsToPasteboard(noteId: String) -> Int {
        let urls = store.listAttachments(noteId: noteId).map { $0.url }
        guard !urls.isEmpty else { return 0 }
        SyntheticPasteboard.writeURLs(urls)
        return urls.count
    }

    func handleDrop(_ items: [NoteDropItem], activeId: String?, tabOrder: [String]) -> NotesDropResult? {
        guard !items.isEmpty else { return nil }
        let hadActive = activeId != nil
        let targetId = activeId ?? StickyNotesStore.newNoteId()
        var added = 0
        var capHit = false
        var notMedia = 0

        for item in items {
            let result: StickyNotesStore.AttachmentAddResult
            switch item {
            case .fileURL(let url):
                result = store.addAttachment(noteId: targetId, fileURL: url)
            case .imageData(let data, let name):
                result = store.addAttachment(noteId: targetId, data: data, suggestedName: name)
            }
            switch result {
            case .added: added += 1
            case .rejectedCap: capHit = true
            case .rejectedNotMedia: notMedia += 1
            case .failed: break
            }
        }

        let updatedOrder = tabOrder.contains(targetId) ? tabOrder : (tabOrder + [targetId])
        return NotesDropResult(targetId: targetId, activeId: targetId, tabOrder: updatedOrder,
                               added: added, capHit: capHit, notMedia: notMedia,
                               shouldSendInitialState: !hadActive)
    }

    func payload(noteId: String) -> [[String: Any]] {
        store.listAttachments(noteId: noteId).map { info in
            ["id": info.id, "name": info.name, "kind": info.kind.rawValue,
             "thumb": Self.thumbnailDataURL(for: info.url) ?? ""]
        }
    }

    func noteIdsWithAttachments(in noteIds: [String]) -> [String] {
        noteIds.filter { store.hasAttachments(id: $0) }
    }

    private static func thumbnailDataURL(for url: URL, maxDimension: CGFloat = 128) -> String? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
