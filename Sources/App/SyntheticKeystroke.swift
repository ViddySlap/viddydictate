import Cocoa
import CoreGraphics

/// The one place ViddyDictate builds synthetic keyboard events, and the marker it stamps on them
/// so its own hotkey tap can tell them apart from the user's real keystrokes.
enum SyntheticKeystroke {
    /// "VDKY" in ASCII, stamped into `.eventSourceUserData` of every event this app posts.
    static let marker: Int64 = 0x5644_4B59

    static func make(virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags) -> CGEvent? {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: keyDown) else {
            return nil
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    static func isOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
