import Cocoa
import WebKit

private typealias BridgeKey = NotesBridgePayloadKey

extension NotesWindowController {
    // MARK: - Tab drag rail (L7) - registry-driven helpers

    func tabStripScreenRect() -> NSRect? {
        guard let window = window, let webView = webView, window.isVisible else { return nil }
        let viewInWindow = webView.convert(webView.bounds, to: nil)
        let screen = window.convertToScreen(viewInWindow)
        // Mini windows (notes bug 3c) hide the tab strip (#tabbar is display:none — since L8 it returns on hover
        // as a 30pt floating band, but a drop target that exists only while the pointer already sits over the
        // window is no target at all), so the 42pt top band is an invisible drop target covering only ~22% of
        // the 190pt mini floor. Return the FULL content rect as the
        // hit-zone instead: NotesDropCoordinator already forgives any hit inside a mini WindowGeo to
        // `.dock(..., toIndex: tabMids.count)`, so a tab dropped ANYWHERE in a mini note's body docks to its end.
        // Non-mini windows keep the 42pt band - the coordinator needs it to resolve the reorder index against the
        // visible tab slots.
        if isEffectiveMini { return screen }
        let stripHeight: CGFloat = 42
        return NSRect(x: screen.minX, y: screen.maxY - stripHeight, width: screen.width, height: stripHeight)
    }

    /// This window's index in `ordered` (front-to-back, 0 = frontmost), or nil if it is not currently in the
    /// order (not yet built / off-screen). Lets the drop coordinator's shell rank overlapping strips by true
    /// visual front-to-back order so the frontmost window wins an overlap-region drop (round-5 R2 z-order flip).
    func orderedFrontIndex(in ordered: [NSWindow]) -> Int? {
        guard let window = window else { return nil }
        return ordered.firstIndex(of: window)
    }

    /// Snapshot the source strip's tab midpoints and its live horizontal scroll, once at drag start. The
    /// midpoints are returned in the strip's CONTENT frame (each viewport mid plus `#tabs` scrollLeft) so they
    /// are SCROLL-INVARIANT: `#tabs` is a horizontal scroller (wave-1 notes), and the drop coordinator folds the
    /// live `scrollOffset` back in when it computes the committed index (round-5 R3, item-9). `scrollOffset` is
    /// the strip's `scrollLeft` at capture; a fully-live re-query of the offset mid-drag needs real-app GUI
    /// verification. With an unscrolled strip (scrollLeft 0) the content mids equal the viewport mids and the offset is
    /// 0, so this is behavior-identical to the pre-R3 capture.
    func queryTabMids(_ completion: @escaping (_ mids: [CGFloat], _ scrollOffset: CGFloat) -> Void) {
        guard let webView = webView, pageReady else { completion([], 0); return }
        let js = "(function(){var s=document.getElementById('tabs');var sl=s?s.scrollLeft:0;" +
                 "var t=document.querySelectorAll('#tabs .tab');var m=[];" +
                 "for(var i=0;i<t.length;i++){var r=t[i].getBoundingClientRect();m.push(r.left+r.width/2+sl);}" +
                 "return {mids:m,scroll:sl};})()"
        webView.evaluateJavaScript(js) { result, _ in
            let obj = result as? [String: Any]
            let mids = (obj?["mids"] as? [Any])?.compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } } ?? []
            let scroll = (obj?["scroll"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            completion(mids, scroll)
        }
    }

    func sendDragIndicator(localX: CGFloat?) {
        guard pageReady else { return }
        call(.dragIndicator, payload: [BridgeKey.x: localX.map { Double($0) } as Any? ?? NSNull()])
    }

    func sendReorder(noteId: String, toIndex: Int) {
        guard pageReady else { return }
        call(.reorderTab, payload: [BridgeKey.noteId: noteId, BridgeKey.toIndex: toIndex])
    }

    func sendDragCancel(noteId: String) {
        guard pageReady else { return }
        call(.reorderTab, payload: [BridgeKey.noteId: noteId, BridgeKey.toIndex: -1])
    }

    var canReceiveTab: Bool { pageReady }

    func rememberTransientTab(_ note: StickyNoteWire) { transientTabs.remember(note) }

    /// Snapshot every tab for a title-bar-close migration. Materialized notes come from the shared store;
    /// JS-only empty tabs come from the transient table. A final empty scratch fallback preserves a newly
    /// created lazy tab that has reported membership but has never needed a body/file or drag payload.
    func tabsForWindowMigration() -> [StickyNoteWire] {
        let resolved = transientTabs.resolve(allOpen: store.openNotes(), desired: lastTabOrder)
        let byId = Dictionary(uniqueKeysWithValues: resolved.notes.map { ($0.id, $0) })
        return lastTabOrder.map { id in
            byId[id] ?? StickyNoteWire(id: id, body: "", title: "")
        }
    }

    /// Adopt tabs from a closing window without taking the tab-close/history path. Native membership changes
    /// eagerly so windows.json cannot lose the tabs while the target island catches up. If the target already
    /// has an active tab it stays selected; an empty target inherits the closing window's active tab.
    func adoptMigratedTabs(_ notes: [StickyNoteWire], preferredActiveId: String?) {
        let priorActive = lastActiveNoteId.flatMap { lastTabOrder.contains($0) ? $0 : nil }
        var inserted: [StickyNoteWire] = []
        for note in notes where !lastTabOrder.contains(note.id) {
            transientTabs.remember(note)
            lastTabOrder.append(note.id)
            inserted.append(note)
        }
        lastActiveNoteId = priorActive
            ?? preferredActiveId.flatMap { lastTabOrder.contains($0) ? $0 : nil }
            ?? lastTabOrder.first

        guard pageReady else { return }
        for note in inserted {
            var payload = NotesWirePayload.note(note)
            payload[BridgeKey.makeActive] = false
            call(.insertTab, payload: payload)
            sendAttachments(noteId: note.id)
        }
        if let activeId = lastActiveNoteId {
            call(.externalFocus, payload: [BridgeKey.id: activeId])
        }
    }

    func insertDockedTab(_ note: StickyNoteWire, editorState: String? = nil, localX: CGFloat) {
        guard pageReady else { return }
        var payload = NotesWirePayload.note(note)
        payload[BridgeKey.x] = Double(localX)
        payload[BridgeKey.makeActive] = true
        if let editorState { payload[BridgeKey.editorState] = editorState }
        call(.insertTab, payload: payload)
        sendAttachments(noteId: note.id)
    }

    /// Add or focus a file-backed tab while preserving its second-kind metadata across page load/reload.
    func openFileBackedTab(_ note: StickyNoteWire) {
        transientTabs.remember(note)
        if !lastTabOrder.contains(note.id) { lastTabOrder.append(note.id) }
        lastActiveNoteId = note.id
        focus()
        if pageReady { call(.externalCreate, payload: NotesWirePayload.note(note)) }
        onMembershipChanged?()
    }

    func focusTab(noteId: String) {
        guard lastTabOrder.contains(noteId) else { return }
        lastActiveNoteId = noteId
        focus()
        if pageReady { call(.externalFocus, payload: [BridgeKey.id: noteId]) }
        onMembershipChanged?()
    }

    func removeDockedTab(noteId: String) {
        guard pageReady else { return }
        call(.removeTab, payload: [BridgeKey.noteId: noteId])
    }
}
