import Cocoa

/// Owns the set of Sticky Notes windows (L6). Retires the old singleton assumption: there is
/// now a PRIMARY window (hide-on-close, blank-home, AppKit frame-autosave — today's behavior, unchanged)
/// plus zero or more SECONDARY windows. Secondaries are created by the drag rail (L8); L6 builds the
/// registry so they CAN exist and persist, while the live single-primary path stays behaviorally identical
/// to before.
///
/// The registry is the SINGLE writer of `_open-notes.md` and `windows.json`. Each per-window
/// `NotesWindowController` reports its membership up here via `onMembershipChanged`; the registry then
/// re-persists the arrangement and rewrites the aggregate concatenating every window in window order
/// (primary first) with exactly one global `(active)` marker on the most-recently-key window's active tab.
///
/// Focus / dictation / search routing all resolve against the most-recently-key window (`activeWindowId`),
/// EXCEPT dictation landing, which targets whichever window is actually key right now (so the clipboard
/// fallback fires correctly when NO notes window is key).
final class NotesWindowRegistry {
    /// The primary window's stable id. Its frame is owned by the AppKit frame-autosave, not `windows.json`.
    static let primaryWindowId = "window-primary"

    private let store: StickyNotesStore
    /// BT2 (notes-bullseye): fired once when a membership change auto-disarms the bullseye because its note was
    /// closed/deleted, so the controller can toast the user. Wired by AppDelegate.
    var onBullseyeAutoDisarmed: (() -> Void)?
    /// Window order (primary first). Drives the concatenation order of `_open-notes.md` and `windows.json`.
    private var controllers: [NotesWindowController] = []
    /// Window ids in most-recently-key-first order. Resolves the active window for focus / search / the
    /// single aggregate marker.
    private var mru: [String] = []
    /// Whether we have already attempted to restore the saved arrangement this launch (lazy, on first use).
    private var restored = false
    /// The in-flight tab drag, if any (L7). At most one at a time; a `tabDragStart` while one
    /// is live is ignored.
    private var activeDrag: NotesTabDrag?
    /// AppDelegate installs the one shared app-open shell here so drag-in cannot bypass classification or the
    /// frozen backup-on-open snapshot.
    var onMarkdownFileRequest: ((URL, String) -> Void)?

    init(store: StickyNotesStore = .shared) {
        self.store = store
    }

    private func controller(holding noteId: String) -> NotesWindowController? {
        controllers.first { $0.membership.noteIds.contains(noteId) }
    }

    // MARK: - App-facing API

    /// Option+N / the status-menu item: focus the most-recently-active notes window, opening the primary if
    /// none exist yet.
    func show() {
        ensureRestored()
        if controllers.isEmpty { openPrimary() }
        NSApp.activate(ignoringOtherApps: true)
        (mruController() ?? controllers.first)?.focus()
    }

    /// Open one already-classified/backed-up markdown path as a file-backed tab. The store reclassifies as a
    /// defense-in-depth boundary and returns the existing opaque id for a double-open, which this method then
    /// focuses instead of creating a second live buffer.
    func openFileBackedNote(at url: URL, preferredWindowId: String? = nil) throws -> FileBackedOpenResult {
        ensureRestored()
        let result = try store.openFileBackedNote(at: url)
        NSApp.activate(ignoringOtherApps: true)
        if let owner = controller(holding: result.note.id) {
            owner.focusTab(noteId: result.note.id)
            return FileBackedOpenResult(note: result.note, focusedExisting: true)
        }
        if controllers.isEmpty { openPrimary() }
        let target = preferredWindowId.flatMap { preferred in
            controllers.first { $0.windowId == preferred }
        } ?? mruController() ?? controllers.first
        target?.openFileBackedTab(result.note)
        return FileBackedOpenResult(note: result.note, focusedExisting: false)
    }

    /// True when ANY notes window is key. Gates dictation routing (see `insertIntoKeyWindow`).
    var isAnyKey: Bool { controllers.contains { $0.isKey } }

    /// Land dictation / a selection-transform result into whichever window is KEY right now. When no notes
    /// window is key we return `.noWindow` so the caller's clipboard fallback fires (unchanged).
    @discardableResult
    func insertIntoKeyWindow(_ text: String) -> NoteInsertOutcome {
        guard let controller = controllers.first(where: { $0.isKey }) else { return .noWindow }
        return controller.insertDictation(text)
    }

    /// Render an external content write into the live island. The control endpoint has
    /// ALREADY persisted the body to the store; this pushes the matching render so the WKWebView never shows
    /// stale text (a persist-without-render would let JS's next autosave clobber the write). Returns whether a
    /// live window rendered it (`.delivered`) or only disk holds it for now (`.persistedOnly`). Runs on the
    /// main thread (it touches AppKit-owned window state). In the persist-only case we still rewrite the
    /// aggregate so `_open-notes.md` reflects the store without waiting for the next window event.
    @discardableResult
    func renderExternalWrite(_ intent: NotesRenderIntent) -> NotesRenderOutcome {
        func outcome(after delivered: Bool) -> NotesRenderOutcome {
            switch intent.aggregateRewritePolicy {
            case .always:
                rewriteAggregate()
            case .onlyOnMiss:
                if !delivered { rewriteAggregate() }
            case .never:
                break
            }
            return delivered ? .delivered : .persistedOnly
        }

        switch intent {
        case .create(let id, let body, let title):
            let target = mruController() ?? controllers.first
            let delivered = target?.renderExternalCreate(id: id, body: body, title: title) ?? false
            return outcome(after: delivered)
        case .setBody(let id, let body):
            let delivered = controller(holding: id)?
                .renderExternalSetBody(id: id, body: body) ?? false
            return outcome(after: delivered)
        case .insertAtCaret(let id, let text):
            // The route already persisted the caret-at-end floor; a live editor inserts at the true caret and
            // re-persists via its save round-trip (which drives our aggregate rewrite). With no live window the
            // floor stands, so refresh the aggregate here.
            let delivered = controller(holding: id)?
                .renderExternalInsert(id: id, text: text) ?? false
            return outcome(after: delivered)
        case .rename(let id, let title):
            // The store override is already written. The live `renamed` push relabels the tab but posts no
            // inbound message, so rewrite the aggregate here regardless of whether a window rendered it.
            let delivered = controller(holding: id)?
                .renderExternalRename(id: id, title: title) ?? false
            return outcome(after: delivered)
        case .close(let id):
            // The store already soft-closed the note; a live window drops the tab and round-trips membership
            // (rewriting the aggregate). With no window, refresh the aggregate here.
            // A file-backed close that hit the fingerprint conflict gate deliberately leaves its origin
            // mapping alive; keep the live tab visible and let the owning controller resolve-then-close it.
            if store.isFileBackedNote(id: id),
               let controller = controller(holding: id) {
                return outcome(after: controller.requestFileBackedClose(id: id))
            }
            let delivered = controller(holding: id)?
                .renderExternalClose(id: id) ?? false
            return outcome(after: delivered)
        case .restore(let id, let body, let title):
            let target = mruController() ?? controllers.first
            let delivered = target?.renderExternalRestore(id: id, body: body, title: title) ?? false
            return outcome(after: delivered)
        case .duplicate(let id, let body, let title):
            let target = mruController() ?? controllers.first
            let delivered = target?.renderExternalDuplicate(id: id, body: body, title: title) ?? false
            return outcome(after: delivered)
        case .focus(let id):
            // Pure focus: raise the window that holds the note and select its tab. No store mutation, so no
            // aggregate rewrite here (the tab selection round-trips membership on its own when delivered).
            var delivered = false
            if let controller = controller(holding: id) {
                controller.focus()
                delivered = controller.renderExternalFocus(id: id)
            }
            return outcome(after: delivered)
        case .attachmentsChanged(let id):
            // The store already copied the file into the note's sidecar. The live `attachments` push refreshes
            // the tray but posts no inbound message, so rewrite the aggregate here regardless of delivery (the
            // additive **Attachments:** line reads the sidecar files).
            let delivered = controller(holding: id)?
                .renderExternalAttachments(id: id) ?? false
            return outcome(after: delivered)
        }
    }

    /// S2's `.appendToSource` landing seam: push a Sticky Skill append onto the END of note `noteId`'s LIVE
    /// document, in whichever window HOLDS it right now.
    ///
    /// Resolving by holder is the load-bearing part. A skill can run for a minute, and a tab can be dragged
    /// to another window while it does. Rendering into the window that STARTED the run would then report
    /// `.delivered` to a window that no longer holds the note, its island would find no tab, and the append
    /// would vanish with no store fallback to catch it. `.persistedOnly` is returned only when NO window
    /// holds the note, which is the one case where disk is authoritative and a Swift-side write is safe.
    /// Must be called on the main thread (it reads AppKit-owned window state).
    func appendToLiveNote(noteId: String, text: String) -> NotesRenderOutcome {
        let delivered = controller(holding: noteId)?
            .renderExternalAppend(id: noteId, text: text) ?? false
        return delivered ? .delivered : .persistedOnly
    }

    /// The active/key window's active note id, or nil when no notes window exists yet. Read-only: does NOT
    /// trigger the lazy restore or create any window, so the loopback control endpoint can resolve its
    /// `"open"` target (and the `list_sticky_notes` active flag) without side effects. Must be called on the
    /// main thread (it reads AppKit-owned window state).
    func currentActiveNoteId() -> String? {
        mruController()?.membership.activeId
    }

    /// NSApplication termination gate: every live file-backed buffer flushes through the fingerprint model.
    /// Any conflict/failure cancels this quit attempt; the controller raises the non-silent choice sheet and
    /// The user can quit again after resolving it.
    func prepareForApplicationTermination() -> Bool {
        controllers.reduce(true) { safe, controller in
            controller.flushFileBackedNotesForClose(presentReloads: false) && safe
        }
    }

    // MARK: - Note-target snapshot delivery (notes-bullseye BT1)

    /// Snapshot the dictation target at take-START. Returns the transient note target when a notes window is
    /// KEY right now AND holds an active materialized note (the caret is in a note), and tells that note's live
    /// editor to register a CodeMirror-mapped anchor at the current caret/selection so the anchor follows edits
    /// until delivery. Returns nil otherwise (blank home / history view / no key window), so delivery falls back
    /// to today's key-window behavior. Main thread (reads AppKit window state + drives the webview).
    func snapshotDictationTarget(generation: Int) -> NotesDictationTarget? {
        guard let controller = controllers.first(where: { $0.isKey }) else { return nil }
        guard let target = Self.dictationTarget(keyWindowActiveNoteId: controller.membership.activeId) else {
            return nil
        }
        controller.snapshotNoteTarget(id: target.noteId, generation: generation)
        return target
    }

    /// Deliver a completed take to its snapshotted target BY NOTE ID, reaching the note even when its window is
    /// not key (the target-by-note-id path — reuses the same "find the window that holds this id" routing as the
    /// loopback control renders, NOT `insertIntoKeyWindow`). `.noWindow` means the target is gone (no live
    /// window holds the note anymore — closed to history or deleted); the caller parks the take on the clipboard
    /// with a toast so the dictation is never lost. Main thread.
    @discardableResult
    func deliverToTarget(_ target: NotesDictationTarget, text: String) -> NoteInsertOutcome {
        guard let controller = controller(holding: target.noteId) else {
            return .noWindow
        }
        return controller.insertAtNoteTarget(id: target.noteId, text: text)
    }

    // MARK: - Bullseye set/arm delivery (notes-bullseye BT2)

    /// Option+N dual-purpose: set/move the PINNED bullseye at the KEY window's active-note caret and ARM it.
    /// Returns the note id when gated in (a notes window is key AND holds an active materialized note — the
    /// caret is in a note), or nil otherwise (so the caller keeps Option+N's open/focus behavior). Seeds the
    /// persistent bullseye state (armed) and tells the live editor to pin the anchor (which reports its offset
    /// back for persistence). Main thread.
    @discardableResult
    func setBullseyeAtCaret() -> String? {
        guard let controller = controllers.first(where: { $0.isKey }) else { return nil }
        guard let target = Self.dictationTarget(keyWindowActiveNoteId: controller.membership.activeId) else {
            return nil
        }
        NotesBullseyeState.shared.setAtCaret(noteId: target.noteId)
        controller.setBullseyeAtCaret(id: target.noteId)
        // BT3: the key window's `setBullseye` arms + shows the marker at the live caret; broadcast so any other
        // window that held a stale marker (the bullseye just moved off its note) clears it.
        broadcastBullseyeState()
        return target.noteId
    }

    /// BT3 (inline marker): push the current bullseye state to EVERY window's island so each shows or hides the
    /// inline armed-bullseye marker. The island renders it only for its own active tab when armed, so a
    /// broadcast lands the marker in exactly the one window/tab where the note is visible and clears it
    /// everywhere else. Called after every arm-state transition (set/move, toggle, auto-disarm, drop).
    func broadcastBullseyeState() {
        let bullseye = NotesBullseyeState.shared.current
        for controller in controllers {
            controller.pushBullseyeArmed(bullseye)
        }
    }

    /// Option+Shift+N (notes-bullseye BT6): REVEAL where the bullseye currently is. Four steps, in order —
    /// foreground the window holding its note, select that note's tab, arm the bullseye if it was disarmed
    /// (a disarmed bullseye draws no marker, so revealing it would show nothing), and scroll the live anchor
    /// into view. Reveal is navigation, not visibility: the marker already renders persistently, but only while
    /// its note is the active tab in a visible window.
    ///
    /// Never reopens a closed note — restart/reopen durability is explicitly out of scope. The "live" set is
    /// the notes actually held by materialized windows, since a reveal has to have somewhere to navigate to.
    /// Main thread.
    @discardableResult
    func revealBullseye() -> NotesBullseyeLogic.RevealOutcome {
        ensureRestored()
        let liveNoteIds = Set(controllers.flatMap { $0.membership.noteIds })
        let outcome = NotesBullseyeLogic.reveal(NotesBullseyeState.shared.current, liveNoteIds: liveNoteIds)
        guard case .reveal(let noteId, let arm) = outcome else {
            Log.write("bullseye reveal: \(outcome == .noneSet ? "none set" : "note closed")")
            return outcome
        }
        guard let controller = controller(holding: noteId) else { return .noteClosed }
        if arm { NotesBullseyeState.shared.arm() }
        NSApp.activate(ignoringOtherApps: true)
        controller.focusTab(noteId: noteId)
        // Push the (possibly just-armed) marker state BEFORE scrolling, so the glyph is already painted at the
        // anchor when the island scrolls it into view rather than appearing a frame later.
        broadcastBullseyeState()
        controller.revealBullseye(id: noteId)
        Log.write("bullseye reveal: fronted note \(noteId)\(arm ? " (armed it)" : "")")
        return outcome
    }

    /// Deliver an armed take to the pinned bullseye's note BY ID (focus-independent — reaches the bullseye
    /// regardless of which window is key). `.noWindow` means the bullseye's note is gone (no live window holds
    /// it) or nothing is armed; the caller then auto-disarms + parks the take on the clipboard so it is never
    /// lost. Main thread.
    @discardableResult
    func deliverToBullseye(text: String) -> NoteInsertOutcome {
        guard let noteId = NotesBullseyeState.shared.noteId else { return .noWindow }
        guard let controller = controller(holding: noteId) else {
            return .noWindow
        }
        return controller.insertAtBullseye(id: noteId, text: text)
    }

    /// After any store-changing membership event, auto-disarm the bullseye if its note was closed/deleted (no
    /// longer open in the store), firing the one-shot notice exactly once. Uses `store.openNotes()` — the
    /// persisted truth — so a note open in the store but not yet materialized in a live window is NOT treated
    /// as gone. A restore-time drop (note deleted between sessions) happens silently and does not fire here.
    private func checkBullseyeSurvival() {
        let openIds = Set(store.openNotes().map(\.id))
        if NotesBullseyeState.shared.autoDisarmIfGone(openNoteIds: openIds) {
            broadcastBullseyeState()   // BT3: clear the inline marker in every window
            onBullseyeAutoDisarmed?()  // BT2: HUD info-pill refresh + toast
        }
    }

    // MARK: - Four-color replace highlight (notes-bullseye BT4)

    /// The note that would receive a replace highlight for an Option+P pick: the KEY window's active
    /// materialized note (the caret is in a note). nil when no notes window is key or none is active — the pick
    /// is over a foreign-app selection, which is not tinted (CodeMirror-only). Same resolution as the BT1
    /// snapshot target. Main thread.
    func replaceHighlightTargetNoteId() -> String? {
        guard let controller = controllers.first(where: { $0.isKey }) else { return nil }
        return Self.dictationTarget(keyWindowActiveNoteId: controller.membership.activeId)?.noteId
    }

    /// Show / live-update the replace highlight at `level` on note `id`'s island, reaching the note BY ID (the
    /// dictation-take flow's target may not be key). The island tints the note's DETERMINISTIC snapshot range
    /// (captured while the selection was live, so an Option+P pick tints even after the picker stole focus),
    /// collapsing the live selection so the tint shows; it swaps the color of an already-tinted range and
    /// no-ops when the snapshot range is empty (a bare caret has nothing to replace). Main thread.
    func showReplaceHighlight(noteId id: String, level: String, generation: Int) {
        controller(holding: id)?.showReplaceHighlight(id: id, level: level, generation: generation)
    }

    /// Clear the replace highlight on note `id`'s island (a pick or take canceled/committed). Main thread.
    func clearReplaceHighlight(noteId id: String) {
        controller(holding: id)?.showReplaceHighlight(id: id, level: "")
    }

    // MARK: - Notes cross-focus undo (notes-bullseye BT5)

    /// Revert the last ViddyDictate dictation edit in note `id` by reaching the window that holds it (BY ID, even
    /// when it is not key). Returns `true` when a live window holds the note and the reach-back was issued;
    /// `false` when the note is gone (closed to history / deleted — no live window holds it), so the caller can
    /// toast that it cannot be undone. Main thread.
    @discardableResult
    func undoNoteDelivery(noteId id: String) -> Bool {
        guard let controller = controller(holding: id) else {
            return false
        }
        return controller.undoNoteDelivery(id: id)
    }

    /// Replace the mapped last ViddyDictate delivery in a live note with explicit-retry output.
    @discardableResult
    func replaceNoteDelivery(noteId id: String, text: String) -> Bool {
        guard let controller = controller(holding: id) else {
            return false
        }
        return controller.replaceNoteDelivery(id: id, text: text)
    }

    /// Web-search results (Option+L / Option+G) open a tab in the most-recently-active window, opening the
    /// primary if none exist.
    func openSearchResult(question: String, answer: String) {
        ensureRestored()
        if controllers.isEmpty { openPrimary() }
        NSApp.activate(ignoringOtherApps: true)
        (mruController() ?? controllers.first)?.openSearchResult(question: question, answer: answer)
    }

    // MARK: - Restore / create

    /// Recreate the saved window arrangement on first use. A fresh install / pre-L6 upgrade has no
    /// `windows.json`; in that case nothing is built here and the caller creates a single primary that
    /// adopts every open note (see `NotesWindowController.sendInitialState`). When an arrangement IS saved,
    /// each window is rebuilt with its own note subset; any open note not claimed by a saved window joins
    /// the primary so no note is lost, and an empty non-primary window is dropped.
    private func ensureRestored() {
        guard !restored else { return }
        restored = true
        let saved = store.loadWindows()
        guard !saved.isEmpty else { return }

        let openIds = Set(store.openNotes().map(\.id))
        let claimed = Set(saved.flatMap { $0.noteIds })
        let orphans = openIds.subtracting(claimed).sorted()
        let hasNamedPrimary = saved.contains { $0.id == Self.primaryWindowId }

        for (index, win) in saved.enumerated() {
            let isPrimary = (win.id == Self.primaryWindowId) || (!hasNamedPrimary && index == 0)
            var ids = win.noteIds.filter { openIds.contains($0) }
            if isPrimary { ids += orphans.filter { !ids.contains($0) } }
            if ids.isEmpty && !isPrimary { continue }
            let controller = makeController(windowId: isPrimary ? Self.primaryWindowId : win.id,
                                            isPrimary: isPrimary, initialNoteIds: ids,
                                            initialActiveId: win.activeId, savedFrame: win.frame,
                                            initialManualMini: win.manualMini)
            controllers.append(controller)
            controller.focus()
        }
        // Guarantee a primary exists even if the saved file was malformed / all-secondary.
        if !controllers.contains(where: { $0.isPrimary }) {
            openPrimary()
        }
        if mru.isEmpty { mru = controllers.map(\.windowId) }
        persist()
        rewriteAggregate()
    }

    /// Create the primary window fresh. `initialNoteIds` is nil so the window adopts every open note
    /// (today's single-window behavior + the pre-L6 upgrade path).
    private func openPrimary() {
        let controller = makeController(windowId: Self.primaryWindowId, isPrimary: true,
                                        initialNoteIds: nil, initialActiveId: nil, savedFrame: nil)
        controllers.insert(controller, at: 0)
        if !mru.contains(controller.windowId) { mru.append(controller.windowId) }
        controller.focus()
        persist()
    }

    private func makeController(windowId: String, isPrimary: Bool, initialNoteIds: [String]?,
                                initialNotes: [StickyNoteWire] = [],
                                initialEditorStates: [String: String] = [:],
                                initialActiveId: String?, savedFrame: String?,
                                initialManualMini: Bool = false) -> NotesWindowController {
        let controller = NotesWindowController(store: store, windowId: windowId, isPrimary: isPrimary,
                                               initialNoteIds: initialNoteIds, initialNotes: initialNotes,
                                               initialEditorStates: initialEditorStates,
                                               initialActiveId: initialActiveId,
                                               savedFrame: savedFrame,
                                               initialManualMini: initialManualMini)
        controller.onMembershipChanged = { [weak self] in self?.membershipChanged() }
        controller.onBecameKey = { [weak self, weak controller] in
            guard let controller = controller else { return }
            self?.markKey(controller.windowId)
        }
        controller.onWindowClosing = { [weak self, weak controller] in
            guard let controller = controller else { return }
            self?.windowClosing(controller)
        }
        controller.onWindowShouldClose = { [weak controller] in
            controller?.flushFileBackedNotesForClose(presentReloads: true) ?? true
        }
        controller.onTabDragStart = { [weak self, weak controller] note, editorState, grabOffset in
            guard let self = self, let controller = controller else { return }
            self.beginTabDrag(source: controller, note: note, editorState: editorState,
                              grabOffset: grabOffset)
        }
        controller.onMarkdownFileDrop = { [weak self, weak controller] url in
            guard let controller else { return }
            self?.onMarkdownFileRequest?(url, controller.windowId)
        }
        // BT2: the island reports the pinned bullseye's anchor offset; persist it for restart-restore.
        controller.onBullseyeAnchorReported = { noteId, anchor in
            NotesBullseyeState.shared.updateAnchor(noteId: noteId, anchor: anchor)
        }
        // S2 (`.appendToSource`): resolve the append by note HOLDER, not by the window that started the run.
        controller.onAppendToLiveNote = { [weak self] noteId, text in
            self?.appendToLiveNote(noteId: noteId, text: text) ?? .persistedOnly
        }
        return controller
    }

    // MARK: - Tab drag rail (L7)

    private func resolveWire(_ note: StickyNoteWire) -> StickyNoteWire {
        let storeWire = store.openNotes().first { $0.id == note.id }
        return note.kind == .fileBacked ? note : (storeWire ?? note)
    }

    /// Start a Swift-mediated tab drag from `source`. The registry owns it because only the registry can
    /// hit-test every window's strip in screen coords (a WKWebView cannot follow a drag across windows).
    /// Full outcome set (L7 + L8): a drop on the SOURCE window's strip reorders (L7); a drop on
    /// ANOTHER window's strip docks the note there (L8); a drop outside every notes window spawns a new window
    /// holding just that note (L8); Escape or a failed geometry query snaps back.
    private func beginTabDrag(source: NotesWindowController, note: StickyNoteWire, editorState: String?,
                              grabOffset: CGPoint) {
        guard activeDrag == nil else { return }
        // A file-backed drag payload comes directly from the live editor and can be one bridge turn fresher
        // than the runtime buffer mirrored in the store. Scratch notes keep their store-authoritative path.
        let wire = resolveWire(note)
        let title = Self.dragTitle(for: wire)
        activeDrag = NotesTabDrag(
            source: source, windows: controllers, note: wire, editorState: editorState,
            grabOffset: grabOffset, title: title,
            onDock: { [weak self, weak source] note, editorState, target, localX in
                guard let self = self, let source = source else { return }
                self.dockNote(note, editorState: editorState, from: source, to: target, localX: localX)
            },
            onNewWindow: { [weak self, weak source] note, editorState, dropPoint, grabOffset in
                guard let self = self, let source = source else { return }
                self.detachNoteToNewWindow(note, editorState: editorState, from: source,
                                           at: dropPoint, grabOffset: grabOffset)
            },
            onEnd: { [weak self] in self?.activeDrag = nil })
    }

    private static func dragTitle(for note: StickyNoteWire) -> String {
        let explicit = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicit.isEmpty ? StickyNotesStore.title(for: note.body) : explicit
    }

    /// L8 DOCK: the drag ended over ANOTHER notes window's strip. Move the note's membership from `source` into
    /// `target` at the strip-local `x` (the target computes the insertion index from its own live tab geometry,
    /// exactly matching the indicator the user saw). The target inserts + activates the tab and becomes the key
    /// window; the source detaches the tab (NOT a history close — the note is moving, not being deleted). Both
        /// windows post MSG.inbound.active, which drives the registry (single writer) to re-persist `windows.json`, rewrite
    /// the aggregate, and prune the source if it was an emptied secondary. A target mid-crash-reload snaps back.
    private func dockNote(_ note: StickyNoteWire, editorState: String?, from source: NotesWindowController,
                          to target: NotesWindowController, localX: CGFloat) {
        guard source !== target else { source.sendDragCancel(noteId: note.id); return }
        guard target.canReceiveTab else { source.sendDragCancel(noteId: note.id); return }
        let wire = resolveWire(note)
        target.rememberTransientTab(wire)
        target.focus()                                             // become key -> MRU front -> active window
        target.insertDockedTab(wire, editorState: editorState, localX: localX)
        source.removeDockedTab(noteId: wire.id)
    }

    /// L8 NEW WINDOW: the drag ended outside every notes window. Spawn a new SECONDARY window at the drop point
    /// holding just this note. Materialized notes load from the shared store; JS-only empty tabs ride along as
    /// transient initial payloads so they can remain visible without creating a `.md`. The new window is
    /// persisted immediately (its membership is known before its webview loads), then the source detaches the
    /// tab and prunes itself if it was an emptied secondary.
    private func detachNoteToNewWindow(_ note: StickyNoteWire, editorState: String?,
                                       from source: NotesWindowController,
                                       at dropPoint: NSPoint, grabOffset: CGPoint) {
        let frame = Self.newWindowFrame(at: dropPoint, grabOffset: grabOffset)
        let windowId = Self.mintWindowId(existing: controllers.map(\.windowId))
        let wire = resolveWire(note)
        let editorStates = editorState.map { [wire.id: $0] } ?? [:]
        let controller = makeController(windowId: windowId, isPrimary: false, initialNoteIds: [wire.id],
                                        initialNotes: [wire], initialEditorStates: editorStates,
                                        initialActiveId: wire.id,
                                        savedFrame: NSStringFromRect(frame))
        controllers.append(controller)
        mru.insert(windowId, at: 0)
        controller.focus()
        source.removeDockedTab(noteId: wire.id)
        persist()
        rewriteAggregate()
    }

    /// A fresh, collision-free secondary window id (never the primary id). Secondary ids are opaque — only the
    /// primary id is semantically special — so a UUID suffix is sufficient and restart-stable via windows.json.
    private static func mintWindowId(existing: [String]) -> String {
        let taken = Set(existing)
        var id = "window-\(UUID().uuidString.prefix(8).lowercased())"
        while taken.contains(id) || id == primaryWindowId {
            id = "window-\(UUID().uuidString.prefix(8).lowercased())"
        }
        return id
    }

    /// Frame for a drag-out window so the dragged tab lands near the cursor: the window's top-left tracks
    /// `(cursor.x - grabOffset.x)` and its top edge tracks `cursor.y + grabOffset.y` (the same math the drag
    /// ghost used), clamped onto the visible frame of the screen under the cursor so it never opens off-screen.
    private static func newWindowFrame(at cursor: NSPoint, grabOffset: CGPoint,
                                       size: NSSize = NSSize(width: 900, height: 640)) -> NSRect {
        var frame = NSRect(x: cursor.x - grabOffset.x, y: cursor.y + grabOffset.y - size.height,
                           width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, vf.minX), max(vf.minX, vf.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, vf.minY), max(vf.minY, vf.maxY - frame.height))
        }
        return frame
    }

    /// The drop insertion index for a strip-local cursor x, given each tab's midpoint x: the count of tabs
    /// whose midpoint is left of the cursor. Pure and probe-tested; the JS `insertionIndexForX` mirrors it so
    /// the rendered indicator and the committed drop agree (L7).
    static func insertionIndex(mids: [CGFloat], x: CGFloat) -> Int {
        mids.reduce(0) { $0 + ($1 < x ? 1 : 0) }
    }

    /// The SCROLL-AWARE drop insertion index (round-5 R3, item-9): the same count-of-midpoints-left-of-cursor
    /// formula, but with the strip's live horizontal scroll folded in. `#tabs` is a horizontal scroller (wave-1
    /// notes), and the source `mids` are captured ONCE at drag start; if the strip scrolls mid-drag the cached
    /// mids/localX go stale. To stay honest, `mids` are the tab midpoints in the strip's CONTENT frame
    /// (scroll-invariant — captured with the strip's `scrollLeft` added, so a scroll does not move them), `x` is
    /// the cursor's strip-local x in the LIVE viewport frame, and `scrollOffset` is the strip's live `scrollLeft`
    /// (>= 0). A tab at content-mid `m` is drawn at viewport `m - scrollOffset`, so it sits left of the cursor
    /// iff `m < x + scrollOffset` — the plain formula evaluated at the scroll-shifted cursor x. With
    /// `scrollOffset == 0` (unscrolled) this is exactly `insertionIndex(mids:x:)`. A drop past every drawn tab
    /// yields `mids.count` — the forgiving last-tab landing for an overflowing strip. The JS `insertionIndexForX`
    /// mirrors this by reading live (already scroll-shifted) viewport rects; the shared fixture asserts parity.
    static func insertionIndex(mids: [CGFloat], x: CGFloat, scrollOffset: CGFloat) -> Int {
        insertionIndex(mids: mids, x: x + scrollOffset)
    }

    // MARK: - Membership / lifecycle callbacks

    /// A window reported that its notes / active tab changed. Destroy any secondary that just lost its last
    /// tab (its notes already soft-deleted through the normal close path), then re-persist + rewrite.
    private func membershipChanged() {
        for controller in controllers where !controller.isPrimary && controller.membership.noteIds.isEmpty {
            destroy(controller)
        }
        persist()
        rewriteAggregate()
    }

    /// A window became key: move it to the front of the MRU and rewrite the aggregate (the single active
    /// marker may have moved to this window's active tab).
    private func markKey(_ windowId: String) {
        mru.removeAll { $0 == windowId }
        mru.insert(windowId, at: 0)
        rewriteAggregate()
    }

    /// A window is closing via its title bar. This is never a note-close operation: a secondary migrates every
    /// remaining tab into the primary (or the oldest surviving window when there is no primary) before its
    /// controller is destroyed. A last window simply hides and remains available for the next `show()`.
    private func windowClosing(_ controller: NotesWindowController) {
        let snapshot = controllers.map(\.membership)
        switch Self.windowCloseAction(closing: controller.membership, windows: snapshot,
                                      primaryId: Self.primaryWindowId) {
        case .hide:
            return
        case .destroy:
            destroy(controller)
        case .migrate(let targetId):
            guard let target = controllers.first(where: { $0.windowId == targetId }) else { return }
            let notes = controller.tabsForWindowMigration()
            target.adoptMigratedTabs(notes, preferredActiveId: controller.membership.activeId)
            destroy(controller)
        }
        persist()
        rewriteAggregate()
    }

    private func destroy(_ controller: NotesWindowController) {
        controllers.removeAll { $0 === controller }
        mru.removeAll { $0 == controller.windowId }
        controller.teardown()
    }

    // MARK: - Persistence / aggregate (single writer)

    private func persist() {
        store.saveWindows(controllers.map(\.membership))
    }

    private func rewriteAggregate() {
        store.rewriteAggregate(windows: controllers.map(\.membership), activeWindowId: activeWindowId())
        // BT2: any store change that could have closed/deleted the bullseye's note funnels through here.
        checkBullseyeSurvival()
    }

    private func activeWindowId() -> String? {
        Self.resolveActiveWindowId(mru: mru, existing: controllers.map(\.windowId))
    }

    private func mruController() -> NotesWindowController? {
        guard let id = activeWindowId() else { return nil }
        return controllers.first { $0.windowId == id }
    }

    // MARK: - Pure decision helpers (probe-tested)

    enum WindowCloseAction: Equatable {
        /// Keep the controller and its tabs; AppKit's non-releasing close hides the window.
        case hide
        /// Remove an empty secondary controller.
        case destroy
        /// Move every tab to this surviving window, then remove the closing controller.
        case migrate(to: String)
    }

    /// Title-bar-close semantics. The controller array is creation ordered (primary first), so its first
    /// non-closing member is the oldest survivor when no primary exists. Notes never leave open membership.
    static func windowCloseAction(closing: WindowMembership, windows: [WindowMembership],
                                  primaryId: String) -> WindowCloseAction {
        guard closing.id != primaryId else { return .hide }
        let survivors = windows.filter { $0.id != closing.id }
        guard !survivors.isEmpty else { return .hide }
        guard !closing.noteIds.isEmpty else { return .destroy }
        let target = survivors.first { $0.id == primaryId } ?? survivors[0]
        return .migrate(to: target.id)
    }

    /// The most-recently-active window id: the first still-existing id in the MRU (most-recent-first) list,
    /// else the first existing window overall, else nil. Pure so the notes probe can assert it.
    static func resolveActiveWindowId(mru: [String], existing: [String]) -> String? {
        let existingSet = Set(existing)
        for id in mru where existingSet.contains(id) { return id }
        return existing.first
    }

    /// Secondary-close semantics (L6): a SECONDARY window with no notes is destroyed; the
    /// PRIMARY is always kept (it hides and shows a blank home instead). Returns the surviving windows in
    /// their original order. Pure so the notes probe can assert it.
    static func prunedWindows(_ windows: [WindowMembership], primaryId: String) -> [WindowMembership] {
        windows.filter { $0.id == primaryId || !$0.noteIds.isEmpty }
    }

    /// BT1 snapshot decision: the note target to capture at take-start, given the KEY notes window's active
    /// note id. A target exists only when the key window has an ACTIVE materialized note (the caret is in a
    /// note); a blank home / history view / no key window (nil or empty id) yields nil, so delivery keeps
    /// today's key-window behavior. Pure so the notes probe can assert it.
    static func dictationTarget(keyWindowActiveNoteId: String?) -> NotesDictationTarget? {
        guard let id = keyWindowActiveNoteId, !id.isEmpty else { return nil }
        return NotesDictationTarget(noteId: id)
    }

    /// BT1 delivery decision: is a snapshotted target still deliverable at completion? True iff its note is
    /// still OPEN in some live window (focus may have moved — the note-id path reaches it regardless of which
    /// window is key). False means the target is gone (closed to history / deleted): the caller parks the take
    /// on the clipboard. Pure so the notes probe can assert it.
    static func targetDeliverable(noteId: String, openNoteIds: Set<String>) -> Bool {
        openNoteIds.contains(noteId)
    }
}
