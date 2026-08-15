import Cocoa
import WebKit

/// One resolved item from a media drop: an on-disk file (a dropped file or a resolved file promise) kept
/// in its original format, or raw image bytes (e.g. an image dragged from a browser).
enum NoteDropItem {
    case fileURL(URL)
    case imageData(Data, name: String)
}

/// A WKWebView that delivers the first click to the page even when its window is not key, and routes
/// attachable drops to the notes attachment path while allowing normal text drops to fall through.
final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onDropEnter: (() -> Void)?
    var onDropExit: (() -> Void)?
    var onDrop: (([NoteDropItem]) -> Void)?
    private var didSignalEnter = false

    /// Mini-view hover (S8): the pointer entered (true) or left (false) this view. Delivered by an
    /// `.activeAlways` tracking area, so it fires while this window is not key AND while ViddyDictate is not
    /// the active application — the case the JS `mousemove` latch structurally cannot see, because AppKit
    /// does not route mouse-moved events to a non-key window. Purely a report: nothing on this path makes the
    /// window key, orders it front, or activates the app.
    var onPointerHoverChanged: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NotesHoverTracking.makeTrackingArea(bounds: bounds, owner: self)
        addTrackingArea(area)
        hoverTracking = area
        // A rebuild can land while the pointer is ALREADY inside (a live resize, or the mini/full flip), and
        // no enter event follows an area that was installed under the pointer. Re-read the truth instead.
        syncPointerHover()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerHoverChanged?(false)
    }

    /// Rebuild the hover tracking area and re-read the pointer. AppKit calls `updateTrackingAreas` itself on a
    /// geometry change; this is the explicit hook for a state change AppKit cannot see (the mini/full flip).
    func refreshHoverTracking() { updateTrackingAreas() }

    /// Report the pointer's CURRENT inside/outside state without waiting for an event.
    /// `mouseLocationOutsideOfEventStream` is a read of the window's cached pointer location — it delivers no
    /// events and changes no window ordering or activation.
    func syncPointerHover() {
        guard let window = window else { return }
        let inView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onPointerHoverChanged?(bounds.contains(inView))
    }

    /// Intercept Cmd+V ahead of the web content (A1). When the pasteboard carries image/video content, route
    /// it to the attachment tray via the SAME `onDrop` path a drag-drop uses and consume the event so the web
    /// view never inline-embeds it; plain-text pastes fall through to CodeMirror untouched. The routing
    /// decision is the pure `NotesPasteRouter.decide`; this only reads the live pasteboard and resolves items.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NotesPasteRouter.isPasteShortcut(event) {
            let pb = NSPasteboard.general
            if NotesPasteRouter.decide(NotesPasteRouter.descriptor(for: pb)) != .editor {
                let items = Self.pasteItems(from: pb)
                if !items.isEmpty {
                    onDrop?(items)
                    return true
                }
                // Could not resolve concrete items (e.g. an unreadable image) — let the normal paste proceed.
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Resolve a pasteboard into attachable items for the paste route. Mirrors `resolveDrop`'s synchronous
    /// branches (file URLs first, then raw image bytes); paste pasteboards carry no file promises, so that
    /// async branch is intentionally absent.
    static func pasteItems(from pb: NSPasteboard) -> [NoteDropItem] {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { NoteDropItem.fileURL($0) }
        }
        if let (data, name) = rawImage(pb) {
            return [.imageData(data, name: name)]
        }
        return []
    }

    private func attachable(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard attachable(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        if !didSignalEnter { didSignalEnter = true; onDropEnter?() }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard attachable(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        if !didSignalEnter { didSignalEnter = true; onDropEnter?() }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if didSignalEnter { didSignalEnter = false; onDropExit?() }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard attachable(sender.draggingPasteboard) else { return super.prepareForDragOperation(sender) }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard attachable(pb) else { return super.performDragOperation(sender) }
        if didSignalEnter { didSignalEnter = false; onDropExit?() }
        resolveDrop(pb)
        return true
    }

    private func resolveDrop(_ pb: NSPasteboard) {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let items = urls.map { NoteDropItem.fileURL($0) }
            DispatchQueue.main.async { self.onDrop?(items) }
            return
        }
        let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty {
            let dest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("viddydictate-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let queue = OperationQueue()
            let group = DispatchGroup()
            let lock = NSLock()
            var items: [NoteDropItem] = []
            for promise in promises {
                group.enter()
                promise.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                    if error == nil { lock.lock(); items.append(.fileURL(url)); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { self.onDrop?(items) }
            return
        }
        if let (data, name) = Self.rawImage(pb) {
            DispatchQueue.main.async { self.onDrop?([.imageData(data, name: name)]) }
        }
    }

    private static func rawImage(_ pb: NSPasteboard) -> (Data, String)? {
        if let png = pb.data(forType: .png) { return (png, "pasted-image.png") }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "pasted-image.png")
        }
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return (png, "pasted-image.png")
        }
        return nil
    }
}
