import Foundation

enum NotesWirePayload {
    static func note(_ note: StickyNoteWire) -> [String: Any] {
        [
            NotesBridgePayloadKey.id: note.id,
            NotesBridgePayloadKey.body: note.body,
            NotesBridgePayloadKey.title: note.title,
            NotesBridgePayloadKey.kind: note.kind.rawValue,
            NotesBridgePayloadKey.filePath: note.filePath ?? NSNull(),
            NotesBridgePayloadKey.canRename: note.canRename,
            NotesBridgePayloadKey.canEdit: note.canEdit,
        ]
    }

    static func history(_ entry: StickyNotesHistoryWire) -> [String: Any] {
        [
            NotesBridgePayloadKey.id: entry.id,
            NotesBridgePayloadKey.title: entry.title,
            NotesBridgePayloadKey.preview: entry.preview,
            NotesBridgePayloadKey.closedAt: entry.closedAt,
            NotesBridgePayloadKey.expiresAt: entry.expiresAt ?? NSNull(),
        ]
    }
}
