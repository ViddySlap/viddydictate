final class NotesTransientTabs {
    private var notesById: [String: StickyNoteWire]

    init(initialNotes: [StickyNoteWire]) {
        self.notesById = Dictionary(uniqueKeysWithValues: initialNotes.map { ($0.id, $0) })
    }

    func remember(_ note: StickyNoteWire) {
        notesById[note.id] = note
    }

    func resolve(allOpen: [StickyNoteWire], desired: [String]) -> (ids: [String], notes: [StickyNoteWire]) {
        Self.resolveInitialNotes(allOpen: allOpen, desired: desired, transient: notesById)
    }

    func prune(liveIds: Set<String>, materializedIds: Set<String>) {
        notesById = notesById.filter { liveIds.contains($0.key) && !materializedIds.contains($0.key) }
    }

    static func resolveActiveId(lastActive: String?, noteIds: [String]) -> String? {
        if let last = lastActive, noteIds.contains(last) { return last }
        return noteIds.first
    }

    static func resolveInitialNotes(allOpen: [StickyNoteWire], desired: [String],
                                    transient: [String: StickyNoteWire]) -> (ids: [String], notes: [StickyNoteWire]) {
        var byId: [String: StickyNoteWire] = [:]
        for note in allOpen { byId[note.id] = note }
        for (id, note) in transient where byId[id] == nil { byId[id] = note }
        let ids = desired.filter { byId[$0] != nil }
        return (ids, ids.compactMap { byId[$0] })
    }
}
