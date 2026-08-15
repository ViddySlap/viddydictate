import Cocoa

/// The mini-view hover latch's pure decision surface (S8).
///
/// The defect this exists for: in mini view every reveal (the overlay, the grab handle, the attachment tray
/// band, the tab strip) hangs off `body.mini-hover`, and that class was set only by the web island's
/// `mousemove` / `mouseleave` handlers on `document.body`. AppKit does not route mouse-moved events to a
/// window that is not key, so the WKWebView never saw them and the reveal tracked WINDOW FOCUS rather than
/// pointer position: the chrome appeared only after clicking the note. Swift now drives the same latch from
/// a tracking area, and the JS handlers stay as an idempotent fallback.
enum NotesHoverTracking {
    /// `.activeAlways` is the load-bearing option and the reason this is a named constant rather than an
    /// inline literal. The two nearby options are both plausible-looking non-fixes:
    ///   - `.activeInKeyWindow` reproduces the reported bug exactly.
    ///   - `.activeInActiveApp` (and, equivalently, setting only `NSWindow.acceptsMouseMovedEvents`) looks
    ///     correct in a same-app test and still fails the user's actual case, which is hovering a mini note while
    ///     working in a DIFFERENT application.
    /// `.inVisibleRect` pins the tracked rect to the view itself, so a resize that lands before AppKit's next
    /// `updateTrackingAreas` cannot leave a stale rect behind.
    static let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]

    /// The one place a hover tracking area is constructed. `rect` is only the seed; `.inVisibleRect` owns it.
    static func makeTrackingArea(bounds: NSRect, owner: Any) -> NSTrackingArea {
        NSTrackingArea(rect: bounds, options: options, owner: owner, userInfo: nil)
    }
}

/// De-duplicating latch for the pointer-inside boolean pushed to the web island. Enter/exit events are not
/// the only input: a tracking-area rebuild (resize, mini/full flip) re-reads the pointer directly, because a
/// rebuild can land while the pointer is ALREADY inside and no enter event will follow. That re-read is
/// mostly a repeat of what was already pushed, so the latch collapses it to nothing rather than firing a
/// bridge call per resize tick.
struct NotesHoverLatch {
    private var pushed: Bool?

    /// The last value actually pushed; nil before the first push (or after `reset`).
    var current: Bool? { pushed }

    /// The value to push, or nil when it would repeat the last one.
    mutating func update(inside: Bool) -> Bool? {
        guard pushed != inside else { return nil }
        pushed = inside
        return inside
    }

    /// Forget the last push so the next one always goes out. Used when the island reloads (WebContent crash,
    /// restart): the fresh page has no `body.mini-hover` class, so the deduped state is no longer true of it.
    mutating func reset() { pushed = nil }
}
