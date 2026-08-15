import Cocoa

/// One in-flight, Swift-mediated tab drag (L7 + L8). Owns a local NSEvent monitor (drag +
/// mouseUp keep flowing to the initiating app until mouseUp, even over a WKWebView) and an Escape monitor, plus
/// a borderless ghost panel that follows the cursor. On each move it hit-tests every notes window's tab strip
/// in screen coords and drives that window's JS drop indicator; on mouseUp the drop location decides the
/// outcome: over the SOURCE strip = reorder (L7); over ANOTHER window's strip = dock (L8); outside every notes
/// window = a new window holding just that note (L8); Escape or a failed geometry query snaps back. The
/// cross-window outcomes call back into the registry (only it can create windows / mutate the window set). A
/// WKWebView can't track a drag across windows, which is the whole reason this lives in AppKit rather than JS.
final class NotesTabDrag {
    private weak var source: NotesWindowController?
    private let windows: [NotesWindowController]
    private let note: StickyNoteWire
    private let editorState: String?
    private let grabOffset: CGPoint
    private let ghost: NotesDragGhostPanel
    /// L8 outcome callbacks into the registry (only it can create windows / mutate the window set).
    private let onDock: (_ note: StickyNoteWire, _ editorState: String?, _ target: NotesWindowController,
                         _ localX: CGFloat) -> Void
    private let onNewWindow: (_ note: StickyNoteWire, _ editorState: String?, _ dropPoint: NSPoint,
                              _ grabOffset: CGPoint) -> Void
    private let onEnd: () -> Void

    /// Tab midpoints (strip CONTENT-frame x, scroll-invariant) captured once from the source window at start;
    /// the authoritative geometry for the committed drop index. `sourceScrollOffset` is the source strip's live
    /// horizontal scroll at capture — the coordinator folds it back in so the committed index is scroll-aware
    /// A fully-live re-query of the offset mid-drag is covered by real-app GUI verification.
    private var mids: [CGFloat] = []
    private var sourceScrollOffset: CGFloat = 0
    private var moveMonitor: Any?
    private var keyMonitor: Any?
    /// The window whose strip currently shows the indicator, so we can clear it when the cursor leaves.
    private weak var indicatorWindow: NotesWindowController?
    private var finished = false

    init(source: NotesWindowController, windows: [NotesWindowController], note: StickyNoteWire,
         editorState: String?,
         grabOffset: CGPoint, title: String,
         onDock: @escaping (_ note: StickyNoteWire, _ editorState: String?, _ target: NotesWindowController,
                            _ localX: CGFloat) -> Void,
         onNewWindow: @escaping (_ note: StickyNoteWire, _ editorState: String?, _ dropPoint: NSPoint,
                                 _ grabOffset: CGPoint) -> Void,
         onEnd: @escaping () -> Void) {
        self.source = source
        self.windows = windows
        self.note = note
        self.editorState = editorState
        self.grabOffset = grabOffset
        self.onDock = onDock
        self.onNewWindow = onNewWindow
        self.onEnd = onEnd
        self.ghost = NotesDragGhostPanel(title: title)
        start()
    }

    private func start() {
        source?.queryTabMids { [weak self] mids, scrollOffset in
            self?.mids = mids
            self?.sourceScrollOffset = scrollOffset
        }
        ghost.move(to: NSEvent.mouseLocation, grabOffset: grabOffset)
        ghost.show()
        // Drag + up events keep reaching the app while the button is held; a local monitor sees them before
        // the webview does. We RETURN the events (don't swallow) so the island still gets its own mouseUp for
        // click suppression.
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .leftMouseUp { self.finish(commit: true) } else { self.update() }
            return event
        }
        // Escape cancels mid-drag; swallow the key so it doesn't also close menus etc.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.finish(commit: false); return nil }
            return event
        }
        update()
    }

    /// Follow the cursor and drive the indicator on whichever window's strip the cursor is over.
    private func update() {
        let p = NSEvent.mouseLocation
        ghost.move(to: p, grabOffset: grabOffset)
        if let hit = windowStrip(at: p) {
            if let prev = indicatorWindow, prev !== hit.window { prev.sendDragIndicator(localX: nil) }
            hit.window.sendDragIndicator(localX: hit.localX)
            indicatorWindow = hit.window
        } else {
            clearIndicator()
        }
    }

    /// Live window-geometry snapshot for the drop coordinator, one `WindowGeo` per notes window whose strip
    /// currently resolves. `zIndex` now comes from the TRUE front-to-back window order (round-5 R2 flip):
    /// `NSApp.orderedWindows` ranks the windows front-to-back and `overlapZIndices` turns those ranks into the
    /// overlap zIndex, so the VISUALLY FRONTMOST window wins a drop in an overlap region (R1 sourced it from the
    /// controllers-array order — a zero-behavior seam this replaces). Only the SOURCE window's `tabMids` +
    /// `scrollOffset` are populated (the authoritative reorder geometry + live scroll, captured at drag start;
    /// the coordinator folds the offset into the committed index — round-5 R3, item-9); a dock target's index is
    /// still computed by its own island (see `finish`), so its `tabMids` stay empty and its `scrollOffset` 0.
    private func windowGeos() -> [NotesDropCoordinator.WindowGeo] {
        let ordered = NSApp.orderedWindows
        let zIndices = NotesDropCoordinator.overlapZIndices(
            frontToBackRanks: windows.map { $0.orderedFrontIndex(in: ordered) })
        return windows.enumerated().compactMap { index, controller in
            guard let rect = controller.tabStripScreenRect() else { return nil }
            let isSource = controller === source
            return NotesDropCoordinator.WindowGeo(
                id: controller.windowId,
                stripRect: rect,
                isMini: controller.isEffectiveMini,
                tabMids: isSource ? mids : [],
                scrollOffset: isSource ? sourceScrollOffset : 0,
                zIndex: zIndices[index],
                activeNoteId: controller.activeNoteId)
        }
    }

    private func controller(id: String) -> NotesWindowController? {
        windows.first { $0.windowId == id }
    }

    /// The topmost notes window whose strip contains `p`, plus the strip-local x. Overlap resolution is owned
    /// by `NotesDropCoordinator.hitWindow` so the live indicator and the committed drop agree.
    private func windowStrip(at p: NSPoint) -> (window: NotesWindowController, localX: CGFloat)? {
        guard let hit = NotesDropCoordinator.hitWindow(windowGeos(), at: p),
              let window = controller(id: hit.geo.id) else { return nil }
        return (window, hit.localX)
    }

    private func clearIndicator() {
        indicatorWindow?.sendDragIndicator(localX: nil)
        indicatorWindow = nil
    }

    /// End the drag exactly once, feeding a COMMITTED drop to `NotesDropCoordinator.decide` (round-5 R1). This
    /// class is now gesture-capture-and-feed: it snapshots geometry, asks the coordinator for the outcome, and
    /// dispatches to the unchanged registry executors. Escape / gesture cancel is handled here directly and
    /// never reaches `decide` (the coordinator resolves only committed drops over geometry). The mapping is
    /// behavior-identical to the pre-round-5 in-line switch: source strip = reorder; another window's strip =
    /// dock; outside every strip = new window; source strip with unresolved mids = snap back.
    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if let m = moveMonitor { NSEvent.removeMonitor(m) }
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        moveMonitor = nil
        keyMonitor = nil
        clearIndicator()
        ghost.close()
        defer { onEnd() }

        guard commit else { source?.sendDragCancel(noteId: note.id); return }   // Escape: snap back

        let dropPoint = NSEvent.mouseLocation
        let geos = windowGeos()
        let outcome = NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
            endpoint: dropPoint,
            sourceWindowId: source?.windowId ?? "",
            kind: .tab(noteId: note.id, mids: mids, grabOffset: grabOffset),
            windows: geos))
        switch outcome {
        case let .reorder(_, toIndex):
            source?.sendReorder(noteId: note.id, toIndex: toIndex)
        case let .dock(windowId, _):
            // R1 preserves the JS-computed dock index: dispatch to the unchanged executor with the
            // target-local x, and the target's island computes the same index the coordinator would (shared
            // insertion formula). Wiring the dock to consume the coordinator's scroll-aware index is R3.
            if let target = controller(id: windowId),
               let geo = geos.first(where: { $0.id == windowId }) {
                onDock(note, editorState, target, dropPoint.x - geo.stripRect.minX)
            } else {
                source?.sendDragCancel(noteId: note.id)
            }
        case let .newWindow(point):
            onNewWindow(note, editorState, point, grabOffset)
        case .snapBack:
            source?.sendDragCancel(noteId: note.id)
        case .attachContent, .openMarkdownFiles:
            source?.sendDragCancel(noteId: note.id)                             // never from a tab drag; defensive
        }
    }
}

/// A small borderless, non-activating panel showing the dragged tab's title in the Phosphor style, following
/// the cursor during a tab drag (L7). Ignores mouse events so it never intercepts the drag.
private final class NotesDragGhostPanel {
    private let panel: NSPanel
    private static let size = NSSize(width: 168, height: 30)

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.wantsLayer = true
        if let layer = container.layer {
            layer.backgroundColor = Phosphor.cellOn.cgColor
            layer.borderColor = Phosphor.green.withAlphaComponent(0.7).cgColor
            layer.borderWidth = 1
            layer.cornerRadius = 8
            layer.shadowColor = Phosphor.green.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 10
            layer.shadowOffset = .zero
        }
        let label = NSTextField(labelWithString: title.isEmpty ? "Note" : title)
        label.font = NSFont(name: Phosphor.font, size: 12) ?? NSFont.systemFont(ofSize: 12)
        label.textColor = Phosphor.green
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 11, y: 6, width: Self.size.width - 22, height: 18)
        label.autoresizingMask = [.width]
        container.addSubview(label)
        panel.contentView = container
    }

    func show() { panel.orderFrontRegardless() }

    /// Position so the grab point (where the cursor was inside the tab) stays under the cursor. JS grab
    /// offset is top-left origin (y down); screen coords are bottom-left (y up).
    func move(to cursor: NSPoint, grabOffset: CGPoint) {
        let originX = cursor.x - grabOffset.x
        let topY = cursor.y + grabOffset.y            // the tab's top edge in screen coords
        panel.setFrameOrigin(NSPoint(x: originX, y: topY - Self.size.height))
    }

    func close() { panel.orderOut(nil) }
}
