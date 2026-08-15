import Foundation

/// A content-free persistence failure. It deliberately carries only the subsystem, operation, path,
/// and OS error description; dictated text, prompts, note bodies, and other user data never enter it.
struct UserDataWriteFailure: Equatable {
    let subsystem: String
    let operation: String
    let path: String
    let detail: String

    var userMessage: String { "Could not save \(subsystem). Your last change may not persist." }
}
/// The one failure surface for app-owned settings and user-data stores. Stores report synchronously so
/// tests and callers can fail closed, while the notification is delivered on the main queue for the
/// running app to present non-destructively. The test observer is a narrow deterministic seam.
enum UserDataWriteFailureCenter {
    static let didReport = Notification.Name("VDUserDataWriteFailure")
    static let notificationKey = "failure"

    private static let lock = NSLock()
    private static var testObserver: ((UserDataWriteFailure) -> Void)?

    static func report(subsystem: String, operation: String, url: URL, error: Error) {
        let failure = UserDataWriteFailure(
            subsystem: subsystem,
            operation: operation,
            path: url.path,
            detail: error.localizedDescription)
        Log.write("write failure subsystem=\(subsystem) operation=\(operation) path=\(url.lastPathComponent) error=\(failure.detail)")

        lock.lock()
        let observer = testObserver
        lock.unlock()
        observer?(failure)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: didReport, object: nil,
                userInfo: [notificationKey: failure])
        }
    }

    static func withTestObserver<T>(_ observer: @escaping (UserDataWriteFailure) -> Void,
                                    body: () throws -> T) rethrows -> T {
        lock.lock()
        precondition(testObserver == nil, "nested UserDataWriteFailureCenter test observers are unsupported")
        testObserver = observer
        lock.unlock()
        defer {
            lock.lock()
            testObserver = nil
            lock.unlock()
        }
        return try body()
    }
}

func reportStickyNotesWriteFailure(operation: String, url: URL, error: Error) {
    UserDataWriteFailureCenter.report(
        subsystem: "sticky notes", operation: operation, url: url, error: error)
}
