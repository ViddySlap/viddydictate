import Cocoa

/// The single owner of the sticky-notes drop OUTCOME decision (round-5 R1; ADR 0011). Every drop that can
/// land a note somewhere — a tab drag released across windows, or media content dropped/pasted into a window —
/// resolves its outcome here, in one pure function, so `--notes-probe` can assert the whole truth table
/// headlessly.
///
/// Why AppKit and not JS: only AppKit can hit-test and track a drag across windows in SCREEN coordinates; a
/// WKWebView cannot follow a drag once the cursor leaves it. That is the standing `NotesTabDrag` rationale,
/// now made explicit as the coordinator's home. JS keeps render-only duties (the live insertion indicator).
///
/// The decision is PURE over a `DropQuery` value. The impure shells — `NotesTabDrag` (tab drags) and
/// `NotesWindowController.handleDrop` (content drops) — gather the live geometry, call `decide`, and dispatch
/// the returned `DropOutcome` to the EXISTING executors unchanged (`sendReorder` / `dockNote` /
/// `detachNoteToNewWindow` / `sendDragCancel` / `attachments.handleDrop`). Escape / gesture-level cancel is
/// handled by the gesture shell and never reaches `decide`: `decide` resolves only the outcome of a COMMITTED
/// drop over geometry.
///
/// Tab drops and content drops are SEPARATE arms of `decide` (a `DropKind` union). They share this entry point
/// and the window-geometry vocabulary, but their failure modes stay independent — a content drop never
/// snaps-back or spawns a window; a tab drop never attaches media.
///
/// The insertion-index FORMULA stays the shared `NotesWindowRegistry.insertionIndex` primitive (the JS
/// `insertionIndexForX` mirrors it against a shared fixture); the coordinator owns the OUTCOME SELECTION
/// (which branch, and — for overlapping strips — which window), not a second copy of the math.
///
/// ⚠️ Overlap resolution (round-5): when two windows' tab strips overlap under the cursor, `decide` picks the
/// window with the highest `zIndex`. R1 assigned `zIndex` from the registry controllers-array order (first
/// controller = highest), a zero-behavior seam preserving the pre-round-5 "first-containing-in-controllers-
/// order wins" result. R2 FLIPPED the source to true visual front-to-back: the shell now derives `zIndex`
/// from `NSApp.orderedWindows` via `overlapZIndices`, so the window the user sees on top wins an overlap-region
/// drop. `decide` itself did not change for the flip — only the shell's `zIndex` source did.
enum NotesDropCoordinator {

    /// One window's live geometry, as the shell snapshots it at decision time. `stripRect` is the tab-strip
    /// band in SCREEN coordinates (bottom-left origin); `tabMids` are that window's tab midpoints in
    /// strip-local x (matching the JS client x the indicator uses); `zIndex` orders overlapping windows
    /// (higher wins); `scrollOffset` is the strip's live horizontal `scrollLeft` (round-5 R3): the source strip
    /// is a horizontal scroller, so `decide` folds this into the tab index and `tabMids` are content-frame
    /// (scroll-invariant) rather than raw viewport x; `isMini` and `activeNoteId` feed the mini (R2) and content
    /// arms.
    struct WindowGeo: Equatable {
        let id: String
        let stripRect: NSRect
        let isMini: Bool
        let tabMids: [CGFloat]
        let scrollOffset: CGFloat
        let zIndex: Int
        let activeNoteId: String?
    }

    /// What is being dropped.
    enum DropKind {
        /// A tab drag: the dragged note id, the SOURCE strip's tab midpoints (strip-local x, captured at drag
        /// start), and the grab offset inside the tab.
        case tab(noteId: String, mids: [CGFloat], grabOffset: CGPoint)
        /// Media content dropped/pasted into a window. This is the WHERE decision (which window's active note
        /// receives it); the tray-vs-editor routing is a separate `NotesPasteRouter` concern.
        case content([NoteDropItem])
        /// Existing markdown files become file-backed tabs in the source window. Their app-level classifier
        /// and backup side effects run after this pure outcome is selected.
        case markdownFiles([URL])
    }

    /// A committed drop to resolve: where the cursor ended (screen), which window started it, what is being
    /// dropped, and every candidate window's geometry (the shell passes them topmost-first).
    struct DropQuery {
        let endpoint: NSPoint
        let sourceWindowId: String
        let kind: DropKind
        let windows: [WindowGeo]
    }

    /// The resolved outcome. `reorder`/`dock` carry the insertion index; `newWindow` the drop point;
    /// `attachContent` the target window + its active note (nil when the window has no active note).
    enum DropOutcome: Equatable {
        case reorder(windowId: String, toIndex: Int)
        case dock(windowId: String, toIndex: Int)
        case newWindow(point: NSPoint)
        case snapBack
        case attachContent(windowId: String, noteId: String?)
        case openMarkdownFiles(windowId: String, urls: [URL])
    }

    /// The single decision. PURE: no AppKit side effects — a function of the query alone.
    static func decide(_ query: DropQuery) -> DropOutcome {
        switch query.kind {
        case let .tab(_, mids, _):
            return decideTab(query, sourceMids: mids)
        case .content:
            // Content is per-window: it lands on the source window's active note, regardless of which window
            // is key (the standing "image attaches to that window's active note" behavior). A separate arm —
            // it never snaps back or spawns a window.
            let geo = query.windows.first { $0.id == query.sourceWindowId }
            return .attachContent(windowId: query.sourceWindowId, noteId: geo?.activeNoteId)
        case .markdownFiles(let urls):
            return .openMarkdownFiles(windowId: query.sourceWindowId, urls: urls)
        }
    }

    private static func decideTab(_ query: DropQuery, sourceMids: [CGFloat]) -> DropOutcome {
        guard let hit = hitWindow(query.windows, at: query.endpoint) else {
            return .newWindow(point: query.endpoint)                       // dropped clear of every strip
        }
        let localX = query.endpoint.x - hit.geo.stripRect.minX
        // Scroll-aware index (round-5 R3, item-9): `#tabs` is a horizontal scroller and the source mids are
        // captured once at drag start, so fold in the hit strip's live `scrollOffset` — a tab drawn at viewport
        // (contentMid - scrollOffset) sits left of the cursor iff contentMid < localX + scrollOffset. A drop
        // past the last visible tab lands at count (the forgiving last-tab default for an overflowing strip).
        if hit.geo.id == query.sourceWindowId {
            guard !sourceMids.isEmpty else { return .snapBack }           // source geometry never resolved
            return .reorder(windowId: hit.geo.id,
                            toIndex: NotesWindowRegistry.insertionIndex(mids: sourceMids, x: localX,
                                                                        scrollOffset: hit.geo.scrollOffset))
        }
        // Forgiving dock onto a MINI window (round-5 R2, item 7b): a mini strip shows no tab slots (the `.tab`
        // row is `display:none`), so there is no precise slot to aim at — any drop in its band appends to the
        // END (`.dock` at the target's tab count) and the window STAYS mini (the dock never touches
        // manualMini/effectiveMini). This is the mini case of the locked "forgiving drop": released in/near a
        // tab-bar region but off any slot -> the LAST tab, never a mid-index, never snap-back.
        if hit.geo.isMini {
            return .dock(windowId: hit.geo.id, toIndex: hit.geo.tabMids.count)
        }
        return .dock(windowId: hit.geo.id,
                     toIndex: NotesWindowRegistry.insertionIndex(mids: hit.geo.tabMids, x: localX,
                                                                 scrollOffset: hit.geo.scrollOffset))
    }

    /// Assign each window an overlap `zIndex` from its TRUE front-to-back position (round-5 R2 z-order flip).
    /// `ranks[i]` is window `i`'s index in `NSApp.orderedWindows` (0 = frontmost, `nil` = not currently
    /// ordered), positionally aligned with the shell's `windows` array. The returned zIndex orders overlapping
    /// strips so the VISUALLY FRONTMOST window wins a drop in a shared region (higher zIndex = more front),
    /// flipping R1's controllers-array-order seam. Windows absent from the front-to-back order sink behind
    /// every ordered window; their array order breaks ties among them (matching R1's controllers-order
    /// fallback, so a not-yet-ordered window never steals an overlap from an ordered one). Pure so
    /// `--notes-probe` can assert the flip without a live window server.
    static func overlapZIndices(frontToBackRanks ranks: [Int?]) -> [Int] {
        let backmost = ranks.compactMap { $0 }.max() ?? -1
        return ranks.enumerated().map { index, rank in
            // Higher zIndex = more front: negate the front-to-back rank (front rank 0 -> highest zIndex 0).
            // An unordered window sinks one step behind the backmost ordered window; its array index then
            // breaks ties among unordered windows (earlier index = higher, preserving the R1 controllers order).
            let effectiveRank = rank ?? (backmost + 1 + index)
            return -effectiveRank
        }
    }

    /// The single owner of overlap resolution: the containing window with the highest `zIndex`, plus the
    /// strip-local x at the cursor. Used by `decide` AND by the live indicator (`NotesTabDrag.update`) so both
    /// pick the same window when strips overlap. Returns nil when no strip contains the point.
    static func hitWindow(_ windows: [WindowGeo], at point: NSPoint) -> (geo: WindowGeo, localX: CGFloat)? {
        let containing = windows.filter { $0.stripRect.contains(point) }
        guard let top = containing.max(by: { $0.zIndex < $1.zIndex }) else { return nil }
        return (top, point.x - top.stripRect.minX)
    }
}
