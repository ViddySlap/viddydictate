import Foundation

/// The input the dictation recorder is recording from right now, published by `AudioRecorder` after a
/// take's capture started and cleared when it stops. Settings reads it to say which mic is in use.
enum DictationInputState {
    struct Active: Equatable {
        let name: String?
        let followsDefault: Bool
        let viaDeck: Bool
        let differsFromPicker: Bool
    }

    static let didChange = Notification.Name("DictationInputStateDidChange")

    private static let lock = NSLock()
    private static var value: Active?

    static var current: Active? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    static func set(_ active: Active) { update(active) }
    static func clear() { update(nil) }

    /// The new value is in place before the post is queued; the post happens only on a change.
    private static func update(_ new: Active?) {
        lock.lock()
        let changed = value != new
        value = new
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}
