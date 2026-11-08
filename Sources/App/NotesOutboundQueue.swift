struct NotesQueuedSearchResult {
    let question: String
    let answer: String
}

/// One frozen bullseye insertion waiting for the island's page to come back (VDLAND1). It carries the note id
/// as well as the text, so a flush after a WebContent reload still lands in the note the take froze at, not in
/// whatever tab happens to be active then.
struct NotesQueuedFrozenInsertion {
    let id: String
    let text: String
}

final class NotesOutboundQueue {
    private var queuedSearchResults: [NotesQueuedSearchResult] = []
    private var queuedInsertions: [String] = []
    private var queuedFrozenInsertions: [NotesQueuedFrozenInsertion] = []

    func enqueueSearch(question: String, answer: String) {
        queuedSearchResults.append(NotesQueuedSearchResult(question: question, answer: answer))
    }

    func enqueueInsertion(_ text: String) {
        queuedInsertions.append(text)
    }

    func drainInsertions() -> [String] {
        let insertions = queuedInsertions
        queuedInsertions = []
        return insertions
    }

    func enqueueFrozenInsertion(id: String, text: String) {
        queuedFrozenInsertions.append(NotesQueuedFrozenInsertion(id: id, text: text))
    }

    func drainFrozenInsertions() -> [NotesQueuedFrozenInsertion] {
        let insertions = queuedFrozenInsertions
        queuedFrozenInsertions = []
        return insertions
    }

    func drainSearchResults() -> [NotesQueuedSearchResult] {
        let searches = queuedSearchResults
        queuedSearchResults = []
        return searches
    }
}
