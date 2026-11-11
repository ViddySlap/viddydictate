struct NotesQueuedSearchResult {
    let question: String
    let answer: String
}

final class NotesOutboundQueue {
    private var queuedSearchResults: [NotesQueuedSearchResult] = []
    private var queuedInsertions: [String] = []

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

    func drainSearchResults() -> [NotesQueuedSearchResult] {
        let searches = queuedSearchResults
        queuedSearchResults = []
        return searches
    }
}
