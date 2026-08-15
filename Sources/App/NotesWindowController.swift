import Cocoa
import WebKit

private typealias BridgeKey = NotesBridgePayloadKey

final class NotesWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    /// Stable id used by the registry for persistence and MRU ordering.
    let windowId: String
    /// Primary windows hide on close and use AppKit frame autosave; secondaries are persisted in windows.json.
    /// Closing either kind is a WINDOW operation. The registry migrates a secondary's tabs before teardown;
    /// only the web island's explicit tab-X path closes a note to History.
    let isPrimary: Bool
    var onMembershipChanged: (() -> Void)?
    var onBecameKey: (() -> Void)?
    var onWindowClosing: (() -> Void)?
    var onWindowShouldClose: (() -> Bool)?
    /// Fired when the web island reports a tab drag has begun in this window.
    var onTabDragStart: ((_ note: StickyNoteWire, _ editorState: String?, _ grabOffset: CGPoint) -> Void)?
    /// Existing markdown dropped on this notes window. AppDelegate owns the shared classify + backup + open
    /// shell, so drag-in follows the same privacy path as Finder Open With and `open -a`.
    var onMarkdownFileDrop: ((URL) -> Void)?
    /// BT2 (notes-bullseye): fired when the web island reports the pinned bullseye's captured/remapped anchor
    /// offset, so Swift can persist it for restart-restore.
    var onBullseyeAnchorReported: ((_ noteId: String, _ anchor: Int) -> Void)?
    /// S2 (`.appendToSource`): push a Sticky Skill append into whichever window HOLDS the note right now.
    /// Set by the registry, because only the registry can answer "which window holds this note" - and a tab
    /// can be dragged to another window while a skill is in flight, at which point rendering into THIS
    /// window would silently drop the append.
    var onAppendToLiveNote: ((_ noteId: String, _ text: String) -> NotesRenderOutcome)?
    /// Consumed on first load; nil means the primary fallback adopts every open note.
    private var pendingInitialIds: [String]?
    /// One-shot in-memory CodeMirror states for notes arriving with a newly-created drag-out window.
    private var pendingInitialEditorStates: [String: String]
    private let savedFrame: String?

    var window: NSWindow?
    var webView: WKWebView?
    let store: StickyNotesStore
    private let attachments: NotesAttachmentCoordinator
    private let stickySkillCoordinator: StickySkillCoordinator
    let transientTabs: NotesTransientTabs
    let outboundQueue = NotesOutboundQueue()
    var pageReady = false
    /// Last active tab reported by JS; used to restore crash/reload and queue flush target identity.
    var lastActiveNoteId: String?
    /// Last tab order reported by JS; also keeps attachment-only updates in page order.
    var lastTabOrder: [String] = []
    /// One native conflict sheet per file id. Repeated timer ticks reuse it; a later tab-close request upgrades
    /// the pending action so the tab closes only after the user's explicit resolution succeeds.
    var pendingFileConflicts: [String: FileBackedConflict] = [:]
    var conflictCloseAfter: [String: Bool] = [:]
    var conflictQueue: [String] = []
    var activeConflictId: String?
    /// One run at a time per (skill, note). Keyed by both since S3, because a note can now be the source
    /// for more than one sticky skill and blocking a DIFFERENT skill because one is already running would
    /// be a surprise rather than a safeguard.
    private var skillRunsInFlight = Set<String>()

    /// This window's persisted MANUAL mini-view flag (notes-miniview A2). Only this half is stored; the
    /// size-derived half recomputes from the window width. `effective mini = manualMini OR width < 560`.
    private var manualMini: Bool
    /// The last effective-mini value pushed to the web island, to dedupe resize spam (nil = not yet pushed).
    private var lastEffectiveMini: Bool?
    /// Mini-view hover (S8): dedupes the pointer-inside pushes, so a tracking-area rebuild that re-reads the
    /// same state (every live-resize tick) pushes nothing.
    private var hoverLatch = NotesHoverLatch()

    private var themeToken: NSObjectProtocol?
    private var stickySkillsToken: NSObjectProtocol?

    init(store: StickyNotesStore = .shared,
         windowId: String = NotesWindowRegistry.primaryWindowId,
         isPrimary: Bool = true,
         initialNoteIds: [String]? = nil,
         initialNotes: [StickyNoteWire] = [],
         initialEditorStates: [String: String] = [:],
         initialActiveId: String? = nil,
         savedFrame: String? = nil,
         initialManualMini: Bool = false,
         stickySkillCoordinator: StickySkillCoordinator? = nil) {
        self.store = store
        self.windowId = windowId
        self.isPrimary = isPrimary
        self.pendingInitialIds = initialNoteIds
        self.pendingInitialEditorStates = initialEditorStates
        self.attachments = NotesAttachmentCoordinator(store: store)
        self.stickySkillCoordinator = stickySkillCoordinator ?? StickySkillCoordinator(store: store)
        self.transientTabs = NotesTransientTabs(initialNotes: initialNotes)
        self.savedFrame = savedFrame
        self.lastActiveNoteId = initialActiveId
        self.lastTabOrder = initialNoteIds ?? []
        self.manualMini = initialManualMini
        super.init()
        // S2: wire the output slot's live-append seam. It has to happen after `super.init()` because the
        // closure needs `self`. Without it the `.appendToSource` handler would see `.persistedOnly` while a
        // live island held the note and would write the body to disk behind the editor - the exact lost
        // update the handler is built to make impossible - so a selftest pins this line structurally.
        self.stickySkillCoordinator.outputSeam.appendToLiveNote = { [weak self] noteId, text in
            self?.onAppendToLiveNote?(noteId, text) ?? .persistedOnly
        }
        themeToken = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyThemeToWeb()
            self?.sendSettingsToWeb()
        }
        // S5: the catalog is live Settings data, just like the existing notes settings push above. Observe
        // its own store change and project it into every open island; a not-yet-ready page is seeded by
        // `sendInitialState()` instead.
        stickySkillsToken = NotificationCenter.default.addObserver(
            forName: StickySkillStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.sendStickySkillsToWeb()
        }
    }

    deinit {
        if let t = themeToken { NotificationCenter.default.removeObserver(t) }
        if let t = stickySkillsToken { NotificationCenter.default.removeObserver(t) }
    }

    private func applyThemeToWeb() { NotesSettingsBridge.applyTheme(to: webView, pageReady: pageReady) }

    var isKey: Bool { window?.isKeyWindow == true }

    /// This window's active note id (the content-drop / drag-geometry target). A light read of the same field
    /// `membership` exposes, without building the whole `WindowMembership`.
    var activeNoteId: String? { lastActiveNoteId }

    var membership: WindowMembership {
        WindowMembership(id: windowId, noteIds: lastTabOrder, activeId: lastActiveNoteId,
                         frame: isPrimary ? nil : window.map { NSStringFromRect($0.frame) },
                         manualMini: manualMini)
    }

    /// True when this window is in mini view right now: manual toggle on, OR content narrower than the
    /// auto-flip width. The single source of truth the chrome-hide reflects.
    var isEffectiveMini: Bool {
        NotesMiniState.effectiveMini(manual: manualMini, contentWidth: currentContentWidth())
    }

    /// Flip this window's MANUAL mini flag (notes-miniview A2; the A3 hover-overlay toggle drives this). Persists
    /// the flag via the registry (single writer) and re-pushes the effective-mini state to the web island. The
    /// size-derived half is untouched — a manual flip to full while the window is still narrow stays mini.
    func setManualMini(_ on: Bool) {
        guard manualMini != on else { return }
        manualMini = on
        onMembershipChanged?()
        updateMiniState()
    }

    func focus() { if window == nil { build() }; window?.makeKeyAndOrderFront(nil) }

    func teardown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: NotesBridge.scriptHandler)
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        pageReady = false
    }

    func openSearchResult(question: String, answer: String) {
        focus()
        let body = "# \(question)\n\n\(answer)"
        if pageReady {
            call(.openSearchResult, payload: [BridgeKey.id: StickyNotesStore.newNoteId(), BridgeKey.body: body])
        } else {
            outboundQueue.enqueueSearch(question: question, answer: answer)
        }
    }

    @discardableResult
    func insertDictation(_ text: String) -> NoteInsertOutcome {
        guard window != nil else {
            Log.write("sticky notes insert requested but window is nil")
            return .noWindow
        }
        if pageReady {
            Log.write("sticky notes insert -> JS (\(text.count) chars)")
            call(.insertText, payload: [BridgeKey.text: text])
            return .delivered
        }
        Log.write("sticky notes insert queued until page ready (\(text.count) chars)")
        outboundQueue.enqueueInsertion(text)
        return .queued
    }

    private func build() {
        let size = NSSize(width: 900, height: 640)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered,
                         defer: false)
        w.title = "Sticky Notes"
        w.isReleasedWhenClosed = false
        // notes-miniview A2: the mini floor. Lowered from 560x380 so a window can shrink into mini view; at
        // this width the content is always below the 560 auto-flip threshold, so the floor is always mini.
        w.minSize = NSSize(width: NotesMiniState.minWidth, height: NotesMiniState.minHeight)
        w.delegate = self

        // Primary uses AppKit autosave; secondaries restore their windows.json frame.
        if isPrimary {
            let frameAutosaveName: NSWindow.FrameAutosaveName = "ViddyDictateStickyNotes"
            if !w.setFrameUsingName(frameAutosaveName) {
                w.center()
            }
            w.setFrameAutosaveName(frameAutosaveName)
        } else {
            let rect = savedFrame.map(NSRectFromString) ?? .zero
            if rect.width > 0, rect.height > 0 {
                w.setFrame(rect, display: false)
            } else {
                w.center()
            }
        }

        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        content.add(self, name: NotesBridge.scriptHandler)
        config.userContentController = content
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let web = FirstMouseWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.onDropEnter = { [weak self] in self?.sendDragSignal(entered: true) }
        web.onDropExit = { [weak self] in self?.sendDragSignal(entered: false) }
        web.onDrop = { [weak self] items in self?.handleDrop(items) }
        // Mini-view hover (S8): the pointer latch is Swift-driven so it survives this window not being key.
        web.onPointerHoverChanged = { [weak self] inside in self?.pushPointerHover(inside) }
        w.contentView = web
        window = w
        webView = web

        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("StickyNotes", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
            let fallback = NSTextField(labelWithString: "Sticky Notes resources missing. Rebuild the app.")
            fallback.alignment = .center
            fallback.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            fallback.autoresizingMask = [.width, .height]
            w.contentView = fallback
            Log.write("sticky notes: web resources missing")
            return
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page sends an explicit ready message after defining window.ViddyNotes.
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("sticky notes web content process terminated; reloading")
        pageReady = false
        webView.reload()
    }

    func windowDidBecomeKey(_ notification: Notification) { onBecameKey?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { onWindowShouldClose?() ?? true }

    func windowWillClose(_ notification: Notification) { onWindowClosing?() }

    /// Live resize drives the size-derived half of mini state (notes-miniview A2): recompute effective-mini
    /// from the current content width and push it to the web island only when it actually flips at the 560pt
    /// threshold. The manual half is unchanged by resize.
    func windowDidResize(_ notification: Notification) { updateMiniState() }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == NotesBridge.scriptHandler,
              let payload = message.body as? [String: Any],
              let typeStr = payload[BridgeKey.type] as? String else { return }
        guard let type = NotesInbound(rawValue: typeStr) else {
            Log.write("sticky notes: unknown bridge message type '\(typeStr)'")
            return
        }
        switch type {
        case .ready:
            handleReadinessBridgeMessage()
        case .save, .active, .close, .copy, .rename, .saveAs, .revealInFinder:
            handlePersistenceBridgeMessage(type, payload: payload)
        case .noteToHandoff:
            handleNoteToHandoffBridgeMessage(payload)
        case .fileBufferChanged:
            guard let id = payload[BridgeKey.id] as? String,
                  let body = payload[BridgeKey.body] as? String else { return }
            store.observeFileBackedBuffer(id: id, body: body)
        case .fileSync:
            guard let id = payload[BridgeKey.id] as? String,
                  let body = payload[BridgeKey.body] as? String else { return }
            handleFileSyncResult(
                store.syncFileBackedNote(id: id, body: body), id: id, expectedBody: body)
        case .fileReloadApplied:
            guard let id = payload[BridgeKey.id] as? String,
                  let body = payload[BridgeKey.body] as? String else { return }
            handleFileSyncResult(
                store.acceptFileBackedReload(id: id, body: body), id: id, expectedBody: body)
        case .restore, .deleteHistory:
            handleHistoryBridgeMessage(type, payload: payload)
        case .removeAttachment, .copyAssets, .openAttachment, .duplicateAttachments, .renameAttachment:
            handleAttachmentBridgeMessage(type, payload: payload)
        case .setRetention, .setCheatSheetButton:
            handleSettingsBridgeMessage(type, payload: payload)
        case .tabDragStart:
            handleTabDragBridgeMessage(payload)
        case .setManualMini:
            // Mini view (notes-miniview A3): the JS toggle posts the requested MANUAL flag; A2's setManualMini
            // owns the state (flip, persist, re-derive effective mini, push setMini back to the island).
            if let enabled = payload[BridgeKey.enabled] as? Bool { setManualMini(enabled) }
        case .bullseyeAnchor:
            // Bullseye (notes-bullseye BT2): the island reports the pinned anchor offset (on set + on each
            // follow-edits remap) so Swift persists it for restart-restore.
            if let id = payload[BridgeKey.id] as? String,
               let anchor = (payload[BridgeKey.anchor] as? NSNumber)?.intValue {
                onBullseyeAnchorReported?(id, anchor)
            }
        }
    }

    // MARK: - Bridge inbound handlers

    private func handleReadinessBridgeMessage() {
        pageReady = true
        sendInitialState()
        flushQueues()
        applyThemeToWeb()
        updateMiniState(force: true)
        // S8: a fresh page carries no `body.mini-hover`, so the deduped latch is no longer true of it. Forget
        // the last push and re-read the pointer, which seeds the correct hover state on load and after a
        // WebContent crash+reload even though no enter event will arrive under a stationary pointer.
        hoverLatch.reset()
        (webView as? FirstMouseWebView)?.syncPointerHover()
        // BT3: seed the inline bullseye marker for this freshly-loaded island (restart / WebContent reload).
        // The active note was just loaded by sendInitialState -> receiveState, so the marker lands correctly
        // if this window shows the bullseye's note.
        pushBullseyeArmed(NotesBullseyeState.shared.current)
    }

    /// The whole-note tab-menu action. Since S5 the dynamic menu carries the selected skill id; the built-in
    /// fallback preserves the pre-S5 bridge call and keeps an older/reloading island safe during rollout.
    private func handleNoteToHandoffBridgeMessage(_ payload: [String: Any]) {
        if let skillID = payload[BridgeKey.skillId] as? String,
           !skillID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runStickySkill(skillID, payload: payload)
        } else {
            runStickySkill(StickySkillRegistry.builtInSkillID, payload: payload)
        }
    }

    private func runStickySkill(_ skillID: String, payload: [String: Any]) {
        guard let id = payload[BridgeKey.id] as? String,
              let body = payload[BridgeKey.body] as? String else { return }
        // The skill's own name is what every toast below says, so a user running three skills can tell
        // which one just finished. The registry's fallback keeps the built-in nameable even if the skills
        // file is missing; a user skill that is gone falls through to the coordinator's fail-closed path.
        let skill = StickySkillRegistry.skill(skillID, in: StickySkillStore.shared.skills)
        let skillName = skill?.name ?? "Sticky skill"
        let inFlightKey = "\(skillID)|\(id)"
        guard !skillRunsInFlight.contains(inFlightKey) else {
            call(.toast, payload: [BridgeKey.message: "\(skillName) is already running for this note"])
            return
        }

        let title = (payload[BridgeKey.title] as? String) ?? StickyNotesStore.title(for: body)
        let attachmentInfo = store.listAttachments(noteId: id)
        let evidence = attachmentInfo.map {
            NoteToHandoffAttachmentEvidence(filename: $0.name)
        }
        let media = attachmentInfo.map {
            NoteToHandoffMediaAttachment(filename: $0.name, url: $0.url, kind: $0.kind)
        }
        let request = NoteToHandoffRequest(
            sourceNoteId: id, title: title, body: body, attachments: evidence,
            mediaAttachments: media)
        skillRunsInFlight.insert(inFlightKey)
        call(.toast, payload: [BridgeKey.message: "Running \(skillName)..."])

        stickySkillCoordinator.run(skillID: skillID, request) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.skillRunsInFlight.remove(inFlightKey)
                switch outcome {
                case .created(let newId, let newTitle, let output, let ran):
                    let rendered = self.renderExternalCreate(id: newId, body: output, title: newTitle)
                    if !rendered {
                        if !self.lastTabOrder.contains(newId) { self.lastTabOrder.append(newId) }
                        self.lastActiveNoteId = newId
                        self.onMembershipChanged?()
                    }
                    // Name the provider that actually ran. This toast is the only moment a silent
                    // reroute off the pinned provider is visible while the run is still in mind.
                    if let ran, ran.isDegraded {
                        Log.write("sticky skill \(skillID) ran degraded: \(ran.provider.rawValue) "
                            + "from=\(ran.degradedFrom?.rawValue ?? "?")")
                    }
                    self.call(.toast, payload: [
                        BridgeKey.message: Self.stickySkillSuccessToast(
                            noun: "\(skillName) created a note", ran: ran)
                    ])
                case .landed(let noun, _, let renderedLive, let ran):
                    // A landing that created no note (S2's append / clipboard). Only membership needs a
                    // nudge, and only when nothing live took the render - the live path re-persists through
                    // the ordinary save round-trip, which already refreshes membership.
                    if !renderedLive { self.onMembershipChanged?() }
                    self.call(.toast, payload: [
                        BridgeKey.message: Self.stickySkillSuccessToast(noun: noun, ran: ran)
                    ])
                case .failed(let userMessage, let detail):
                    Log.write("sticky skill \(skillID) failed for \(id): \(detail)")
                    self.call(.toast, payload: [BridgeKey.message: userMessage])
                }
            }
        }
    }

    /// Pure renderer for the success toast. Keeping the provider label here makes the user-visible
    /// evidence directly testable while both created-note and non-note landings share the exact wording.
    static func stickySkillSuccessToast(noun: String, ran: CustomModeRunProvider?) -> String {
        let on = ran.map { " (\($0.shortLabel))" } ?? ""
        return "\(noun)\(on)"
    }

    // MARK: - Mini view (notes-miniview A2)

    /// The window's current content width (points) — the input to the size-derived half of mini state. The
    /// content view is the WKWebView (autoresized to fill), so its width is the layout width the 560 threshold
    /// compares against.
    private func currentContentWidth() -> CGFloat {
        window?.contentView?.bounds.width ?? 0
    }

    /// Recompute effective-mini and push it to the web island when it changes (or always, on `force`, so
    /// page-ready seeds the initial state even if it matches the last pushed value). The JS side toggles
    /// `body.mini-mode`, which hides the tab strip, the button row, and the hamburger.
    private func updateMiniState(force: Bool = false) {
        let effective = NotesMiniState.effectiveMini(manual: manualMini, contentWidth: currentContentWidth())
        if !force && effective == lastEffectiveMini { return }
        lastEffectiveMini = effective
        // S8: the mini/full flip is a state change AppKit cannot see, and it can land while the pointer is
        // already over the window (the overlay's own "Full" button is under the pointer when it is clicked).
        // Rebuild the tracking area and re-read the pointer so the latch is right on the other side of a flip.
        (webView as? FirstMouseWebView)?.refreshHoverTracking()
        guard pageReady else { return }
        call(.setMini, payload: [BridgeKey.enabled: effective])
    }

    /// Push the pointer's inside/outside state to the web island, which reflects it onto `body.mini-hover` —
    /// the one latch every mini reveal (overlay, grab handle, tray band, tab strip) hangs off. Fired by an
    /// `.activeAlways` tracking area, so it works while this window is not key and while ViddyDictate is not
    /// the frontmost app; that IS the fix. Deliberately does not raise, activate, or make the window key: a
    /// hover that foregrounded the window would be a worse bug than the one being fixed.
    ///
    /// Not gated on mini view. The latch is a no-op in full view (every reveal rule is `body.mini-mode` AND
    /// `body.mini-hover`), and gating here would need the latch re-evaluated on each flip for no gain.
    private func pushPointerHover(_ inside: Bool) {
        guard pageReady else { return }
        guard let push = hoverLatch.update(inside: inside) else { return }
        call(.miniHover, payload: [BridgeKey.enabled: push])
    }

    private func handlePersistenceBridgeMessage(_ type: NotesInbound, payload: [String: Any]) {
        switch type {
        case .save:
            guard let id = payload[BridgeKey.id] as? String,
                  let body = payload[BridgeKey.body] as? String else { return }
            if store.isFileBackedNote(id: id) {
                handleFileSyncResult(
                    store.syncFileBackedNote(id: id, body: body), id: id, expectedBody: body)
                rewriteAggregate(from: payload)
                return
            }
            store.saveOpenNote(id: id, body: body)
            rewriteAggregate(from: payload)
        case .active:
            rewriteAggregate(from: payload)
        case .close:
            guard let id = payload[BridgeKey.id] as? String,
                  let body = payload[BridgeKey.body] as? String else { return }
            if store.isFileBackedNote(id: id) {
                handleFileBackedClose(id: id, body: body)
                return
            }
            store.closeNote(id: id, body: body)
            rewriteAggregate(from: payload)
            sendHistory()
        case .copy:
            guard let body = payload[BridgeKey.body] as? String else { return }
            TargetResolver.copyToClipboard(body)
            call(.toast, payload: [BridgeKey.message: "Copied"])
        case .rename:
            guard let id = payload[BridgeKey.id] as? String,
                  let title = payload[BridgeKey.title] as? String else { return }
            if store.isFileBackedNote(id: id) {
                handleFileBackedRename(id: id, stem: title, payload: payload)
                return
            }
            if let body = payload[BridgeKey.body] as? String,
               !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.saveOpenNote(id: id, body: body)
            }
            let displayTitle = store.renameNote(id: id, title: title) ?? StickyNotesStore.title(for: "")
            rewriteAggregate(from: payload)
            let explicitTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : displayTitle
            call(.renamed, payload: [BridgeKey.id: id, BridgeKey.title: explicitTitle])
        case .saveAs:
            saveAs(payload)
        case .revealInFinder:
            guard let id = payload[BridgeKey.id] as? String,
                  let url = store.revealableFileURL(id: id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            return
        }
    }

    private func handleHistoryBridgeMessage(_ type: NotesInbound, payload: [String: Any]) {
        switch type {
        case .restore:
            // 3b-lite (diagnostic): the reopen-from-history path shows a ~1s felt lag with no confirmed single
            // cause (likely WKWebView occlusion / background-JS throttling — a runtime behavior). Do the two
            // unambiguously-correct things and MEASURE, rather than chase the throttle blind:
            //  (1) fire rewriteAggregate so registry membership (windows.json / _open-notes.md / MRU) updates in
            //      the SAME tick — every other mutating handler already calls it (.close/.rename), .restore did
            //      not, so membership lagged by one JS<->native round trip.
            //  (2) HH:mm:ss.SSS-stamped Log lines around entry/exit + the .restored render-call return (see
            //      call()), so live verification can localize the lag to pre- vs post-Swift-dispatch.
            let restoreId = payload[BridgeKey.id] as? String ?? "?"
            Log.write("notes restore: enter (id \(restoreId))")
            guard let id = payload[BridgeKey.id] as? String,
                  let note = store.restoreHistory(id: id) else {
                Log.write("notes restore: no-op (missing id or history entry for \(restoreId))")
                return
            }
            Log.write("notes restore: store reopened (id \(id)); dispatching .restored to island")
            call(.restored, payload: NotesWirePayload.note(note))
            sendAttachments(noteId: id)
            rewriteAggregate(from: payload)
            sendHistory()
            Log.write("notes restore: swift dispatch complete (id \(id))")
        case .deleteHistory:
            guard let id = payload[BridgeKey.id] as? String else { return }
            store.deleteHistory(id: id)
            sendHistory()
        default:
            return
        }
    }

    private func handleAttachmentBridgeMessage(_ type: NotesInbound, payload: [String: Any]) {
        switch type {
        case .removeAttachment:
            guard let noteId = payload[BridgeKey.noteId] as? String,
                  let attachmentId = payload[BridgeKey.attachmentId] as? String else { return }
            attachments.removeAttachment(noteId: noteId, attachmentId: attachmentId)
            sendAttachments(noteId: noteId)
            onMembershipChanged?()
        case .renameAttachment:
            // notes-8-rename: rename keeps the NN- prefix + media extension, so the id changes -> re-push the
            // note's attachments so the tray reflects the new name (and the addressable id). No membership change.
            guard let noteId = payload[BridgeKey.noteId] as? String,
                  let attachmentId = payload[BridgeKey.attachmentId] as? String,
                  let newName = payload[BridgeKey.newName] as? String else { return }
            attachments.renameAttachment(noteId: noteId, attachmentId: attachmentId, newName: newName)
            sendAttachments(noteId: noteId)
        case .copyAssets:
            guard let noteId = payload[BridgeKey.noteId] as? String else { return }
            copyAssets(noteId: noteId)
        case .openAttachment:
            guard let noteId = payload[BridgeKey.noteId] as? String,
                  let attachmentId = payload[BridgeKey.attachmentId] as? String else { return }
            attachments.openAttachment(noteId: noteId, attachmentId: attachmentId)
        case .duplicateAttachments:
            guard let fromNoteId = payload[BridgeKey.fromNoteId] as? String,
                  let toNoteId = payload[BridgeKey.toNoteId] as? String else { return }
            attachments.duplicateAttachments(fromNoteId: fromNoteId, toNoteId: toNoteId)
            sendAttachments(noteId: toNoteId)
            onMembershipChanged?()
        default:
            return
        }
    }

    private func handleSettingsBridgeMessage(_ type: NotesInbound, payload: [String: Any]) {
        switch NotesSettingsBridge.applyInbound(type, payload: payload, store: store) {
        case .refresh:
            sendHistory()
        case .none:
            break
        }
    }

    private func handleTabDragBridgeMessage(_ payload: [String: Any]) {
        guard let noteId = payload[BridgeKey.noteId] as? String else { return }
        let gx = (payload[BridgeKey.grabOffsetX] as? NSNumber)?.doubleValue ?? 0
        let gy = (payload[BridgeKey.grabOffsetY] as? NSNumber)?.doubleValue ?? 0
        let body = payload[BridgeKey.body] as? String ?? ""
        let title = payload[BridgeKey.title] as? String ?? ""
        let kind = (payload[BridgeKey.kind] as? String).flatMap(StickyNoteKind.init(rawValue:)) ?? .scratch
        let filePath = payload[BridgeKey.filePath] as? String
        let canRename = payload[BridgeKey.canRename] as? Bool ?? true
        let canEdit = payload[BridgeKey.canEdit] as? Bool ?? true
        let editorState = payload[BridgeKey.editorState] as? String
        onTabDragStart?(
            StickyNoteWire(id: noteId, body: body, title: title, kind: kind, filePath: filePath,
                           canRename: canRename, canEdit: canEdit),
            editorState,
            CGPoint(x: gx, y: gy))
    }

    private func sendSettingsToWeb() {
        guard pageReady else { return }
        call(.settings, payload: NotesSettingsBridge.payload())
    }

    /// Push the menu-safe projection only. This deliberately does not serialize `StickySkill`: that would
    /// leak its output mode/timeout today and would make it tempting to push its backing prompt/route later.
    private func sendStickySkillsToWeb() {
        guard pageReady else { return }
        let items = StickySkillMenuProjection.items(from: StickySkillStore.shared.skills)
            .map(\.payload)
        call(.stickySkills, payload: [BridgeKey.items: items])
    }

    private func copyAssets(noteId: String) {
        let count = attachments.copyAssetsToPasteboard(noteId: noteId)
        guard count > 0 else { return }
        call(.toast, payload: [BridgeKey.message: "\(count) asset\(count == 1 ? "" : "s") copied"])
    }

    private func handleDrop(_ items: [NoteDropItem]) {
        let markdownURLs = items.compactMap { item -> URL? in
            guard case .fileURL(let url) = item, url.pathExtension.lowercased() == "md" else { return nil }
            return url
        }
        var remaining = items
        if !markdownURLs.isEmpty {
            let outcome = NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
                endpoint: .zero, sourceWindowId: windowId, kind: .markdownFiles(markdownURLs),
                windows: []))
            if case .openMarkdownFiles(_, let urls) = outcome {
                for url in urls { onMarkdownFileDrop?(url) }
            }
            remaining.removeAll { item in
                guard case .fileURL(let url) = item else { return false }
                return url.pathExtension.lowercased() == "md"
            }
        }
        guard !remaining.isEmpty else { return }
        // Route the WHERE decision (which window's active note receives the content) through the single drop
        // coordinator (ADR 0011). Content is per-window: the outcome is always THIS window's active note,
        // regardless of key — behavior-identical to the pre-round-5 direct call.
        let outcome = NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
            endpoint: .zero,
            sourceWindowId: windowId,
            kind: .content(remaining),
            windows: [NotesDropCoordinator.WindowGeo(
                id: windowId, stripRect: .zero, isMini: isEffectiveMini, tabMids: [],
                scrollOffset: 0, zIndex: 0, activeNoteId: lastActiveNoteId)]))
        guard case let .attachContent(_, activeId) = outcome else { return }
        guard let result = attachments.handleDrop(remaining, activeId: activeId, tabOrder: lastTabOrder) else {
            return
        }
        if result.added > 0 {
            lastActiveNoteId = result.activeId
            lastTabOrder = result.tabOrder
            if result.shouldSendInitialState { sendInitialState() }
            sendAttachments(noteId: result.targetId)
            onMembershipChanged?()
        }
        if result.capHit {
            call(.toast, payload: [BridgeKey.message: "Attachment limit reached (20)"])
        } else if result.notMedia > 0 {
            call(.toast, payload: [BridgeKey.message: "Only image or video files can be attached"])
        }
    }

    private func sendDragSignal(entered: Bool) {
        guard pageReady else { return }
        call(entered ? .dragEnter : .dragExit, payload: [:])
    }

    func sendAttachments(noteId: String) {
        guard pageReady else { return }
        let items = attachments.payload(noteId: noteId)
        call(.attachments, payload: [BridgeKey.noteId: noteId, BridgeKey.items: items])
    }

    private func sendAllAttachments() {
        guard pageReady else { return }
        for id in attachments.noteIdsWithAttachments(in: lastTabOrder) {
            sendAttachments(noteId: id)
        }
    }

    private func saveAs(_ payload: [String: Any]) {
        guard let id = payload[BridgeKey.id] as? String,
              let body = payload[BridgeKey.body] as? String else { return }
        do {
            let dest = Settings.stickyNotesSaveDirectoryURL
            let saved = try store.saveAs(id: id, body: body, destination: dest)
            call(.toast, payload: [BridgeKey.message: "Saved to \(saved.lastPathComponent)"])
        } catch {
            Log.write("sticky notes save-as failed: \(error.localizedDescription)")
            call(.toast, payload: [BridgeKey.message: "Save failed"])
        }
    }

    private func sendInitialState() {
        guard pageReady else { return }
        store.purgeExpiredHistory(retention: Settings.stickyNotesRetention)
        let allOpen = store.openNotes()
        let desired: [String]
        if let pending = pendingInitialIds { desired = pending }
        else if !lastTabOrder.isEmpty { desired = lastTabOrder }
        else { desired = allOpen.map(\.id) }
        pendingInitialIds = nil
        let resolved = transientTabs.resolve(allOpen: allOpen, desired: desired)
        let ids = resolved.ids
        let notes = resolved.notes.map { note -> [String: Any] in
            var payload = NotesWirePayload.note(note)
            if let editorState = pendingInitialEditorStates[note.id] {
                payload[BridgeKey.editorState] = editorState
            }
            return payload
        }
        pendingInitialEditorStates.removeAll()
        let history = store.history(retention: Settings.stickyNotesRetention).map(NotesWirePayload.history)
        let activeId = NotesTransientTabs.resolveActiveId(lastActive: lastActiveNoteId, noteIds: ids)
        call(.receiveState, payload: [
            BridgeKey.notes: notes,
            BridgeKey.history: history,
            BridgeKey.activeId: activeId ?? NSNull() as Any,
            BridgeKey.newId: StickyNotesStore.newNoteId(),
            BridgeKey.cheatSheetButton: Settings.stickyNotesCheatSheetButton,
            BridgeKey.retention: Settings.stickyNotesRetention.rawValue,
        ])
        // S5: seed the same standalone catalog push the store observer uses. Keeping it out of
        // `receiveState` prevents note/session state from becoming another owner of Sticky Skill data.
        sendStickySkillsToWeb()
        lastTabOrder = ids
        lastActiveNoteId = activeId
        let materializedIds = Set(allOpen.map(\.id))
        let liveIds = Set(ids)
        transientTabs.prune(liveIds: liveIds, materializedIds: materializedIds)
        onMembershipChanged?()
        sendAllAttachments()
    }

    private func sendHistory() {
        call(.receiveHistory,
             payload: [BridgeKey.history: store.history(retention: Settings.stickyNotesRetention)
                .map(NotesWirePayload.history)])
    }

    func rewriteAggregate(from payload: [String: Any]) {
        if let tabOrder = payload[BridgeKey.tabOrder] as? [String] { lastTabOrder = tabOrder }
        if let active = payload[BridgeKey.activeId] as? String { lastActiveNoteId = active }
        onMembershipChanged?()
    }

    private func flushQueues() {
        guard pageReady else { return }
        for text in outboundQueue.drainInsertions() {
            call(.insertText, payload: [BridgeKey.text: text])
        }

        for item in outboundQueue.drainSearchResults() {
            call(.openSearchResult, payload: [BridgeKey.id: StickyNotesStore.newNoteId(),
                                               BridgeKey.body: "# \(item.question)\n\n\(item.answer)"])
        }
    }

    func call(_ call: NotesOutbound, payload: Any) {
        guard let webView = webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "\(NotesBridge.webObject) && \(NotesBridge.webObject).\(call.rawValue)(\(json));"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                Log.write("sticky notes JS call \(call.rawValue) failed: \(error.localizedDescription)")
            } else if call == .insertText {
                Log.write("sticky notes JS call insertText OK")
            } else if call == .restored {
                // 3b-lite (diagnostic): stamp when the island's .restored render call actually returned. A large
                // gap between this and "notes restore: enter" points the felt lag at post-Swift-dispatch (the
                // WKWebView render/throttle), not the native path.
                Log.write("notes restore: island .restored render call returned")
            }
        }
    }
}
