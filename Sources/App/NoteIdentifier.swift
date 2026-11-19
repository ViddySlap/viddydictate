import Foundation

enum NoteIdentifier {
    static func validatedScratchNoteId(_ raw: String) -> String? {
        guard raw.range(of: #"^note-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    static func validatedFileBackedNoteId(_ raw: String) -> String? {
        guard raw.range(of: #"^file-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    static func validatedNoteId(_ raw: String) -> String? {
        guard validatedScratchNoteId(raw) != nil || validatedFileBackedNoteId(raw) != nil else { return nil }
        return raw
    }
}
