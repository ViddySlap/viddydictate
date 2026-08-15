import Foundation

enum AggregateRewritePolicy: Equatable {
    case always
    case onlyOnMiss
    case never
}

/// A live-render request produced by a control-endpoint write. The server is
/// transport-thin and off the main thread, so it never touches AppKit itself; instead it hands one of these
/// to an injected render sink (the live `NotesWindowRegistry` in production, a spy in the selftest). Persistence
/// to `StickyNotesStore` has ALREADY happened by the time the sink is called — the intent carries the exact
/// bytes on disk so the rendered DOM lands in lockstep with the store.
enum NotesRenderIntent: Equatable {
    /// A freshly created note (Swift-minted id, body, optional title override) to render as the active tab.
    case create(id: String, body: String, title: String?)
    /// Replace an open note's full body by id — used for update `set` AND for the full post-`append` body, so
    /// the render is always a whole-body replace that matches what was persisted.
    case setBody(id: String, body: String)
    /// Insert `text` at the target note's LIVE caret (the dictation seam). Unlike
    /// `setBody`, the resulting body is not known to Swift up front — only the live editor knows the caret — so
    /// the route persists a caret-at-end floor first and this render lets the live editor insert at the true
    /// caret and re-persist the exact result (JS is the authoritative last-writer, exactly like dictation).
    case insertAtCaret(id: String, text: String)
    /// Relabel an open note's live tab. `title` is the resolved display title, or `""`
    /// to clear the override (the tab reverts to its body-derived title). The store override is written first.
    case rename(id: String, title: String)
    /// Drop an open note's live tab. The store has ALREADY soft-closed the note to
    /// history; this only removes the tab from the live island (no second history close).
    case close(id: String)
    /// Render a restored note back as a live tab. The store has already reopened it from
    /// history under `id` (which may differ from the archived id); this adds it as the active tab.
    case restore(id: String, body: String, title: String)
    /// Render a duplicated note as a live tab. The store has already minted `id`, saved
    /// the body, applied the `"<title> copy"` override, and copied the source's attachments; this adds the
    /// duplicate as the active tab AND pushes its attachment tray.
    case duplicate(id: String, body: String, title: String)
    /// Make an open note the active tab / key window. Pure live-window focus - no store
    /// mutation; the native window is raised on the Swift side and the tab is selected in the island.
    case focus(id: String)
    /// An attachment was added to an open note via the control endpoint. The store has
    /// ALREADY copied the file into the note's `attachments/<id>/` sidecar; this pushes the note's attachment
    /// tray to the live island (the existing `attachments` bridge msg, the same one drag/drop and duplicate use)
    /// so the thumbnails update in lockstep with disk. Like `.rename`, it posts no inbound message, so the
    /// aggregate is rewritten regardless of delivery (its additive `**Attachments:**` line reads the sidecar).
    case attachmentsChanged(id: String)

    var aggregateRewritePolicy: AggregateRewritePolicy {
        switch self {
        case .rename, .attachmentsChanged:
            return .always
        case .create, .setBody, .insertAtCaret, .close, .restore, .duplicate:
            return .onlyOnMiss
        case .focus:
            return .never
        }
    }
}

/// What the render sink did with an intent. `delivered` means a live window rendered it; `persistedOnly` means
/// no live window was available so only the store write stands (the note surfaces on the next window open).
enum NotesRenderOutcome: String {
    case delivered
    case persistedOnly = "persisted_only"
}

/// Loopback HTTP control surface for external Sticky Notes tools.
///
/// This is the inbound control endpoint local tools POST to. It exists so an external process can
/// drive the RUNNING ViddyDictate - the `.md` note files are a one-way, app-owned mirror, so an outside
/// file write while the app runs is invisible and gets clobbered; the control path must go through the live
/// process. It is a sibling in spirit to the :8765 STT daemon ViddyDictate already talks to.
///
/// Security model (v1): bind `127.0.0.1` ONLY. Loopback IS the boundary; there is no auth token. Anything
/// that can reach this socket already runs as the current user on this Mac.
///
/// L1 scope is READS ONLY — health + `list_sticky_notes` + `read_sticky_note`. Reads first proves the
/// transport reaches the running process before any write route is added (writes land in later links).
///
/// The server is deliberately transport-thin and testable: it takes a `StickyNotesStore` (the real shared
/// store in production, a scratch store in the selftest) plus an `activeNoteId` provider (the live registry
/// in production, a fixed value in the selftest). It never reaches into AppKit itself, so
/// `--notes-http-selftest` can spin it on a scratch port + scratch store with zero UI and never touch the
/// real notes dir or the live app.
final class NotesControlServer {

    struct Config {
        /// The port to try first. `0` asks the OS for a free ephemeral port (used by the selftest so it can
        /// NEVER collide with — or bind — the real default port).
        var preferredPort: UInt16
        /// How many consecutive ports to try (preferredPort ... preferredPort + scanRange - 1) before giving
        /// up when `preferredPort` is non-zero and already taken. Ignored when `preferredPort == 0`.
        var scanRange: Int

        /// Production default: the loopback control port expected by local tooling.
        static let defaultPort: UInt16 = 8766

        static let production = Config(preferredPort: defaultPort, scanRange: 32)
    }

    private let store: StickyNotesStore
    private let activeNoteIdProvider: () -> String?
    /// Pushes a write's live-render intent into the running app. Injected so the server
    /// stays transport-thin and testable: production hops to the main thread and drives the registry; the
    /// selftest passes a spy. The default is a no-op that reports `persistedOnly` (used by read-only callers /
    /// L1-era construction).
    private let renderSink: (NotesRenderIntent) -> NotesRenderOutcome
    private let config: Config

    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false

    /// The port actually bound once `start()` succeeds (0 until then).
    private(set) var boundPort: UInt16 = 0

    init(store: StickyNotesStore,
         config: Config = .production,
         activeNoteId: @escaping () -> String? = { nil },
         renderSink: @escaping (NotesRenderIntent) -> NotesRenderOutcome = { _ in .persistedOnly }) {
        self.store = store
        self.config = config
        self.activeNoteIdProvider = activeNoteId
        self.renderSink = renderSink
    }

    // MARK: - Lifecycle

    /// Bind loopback + start the accept loop on a background thread. Returns the bound port, or nil if no
    /// candidate port could be bound.
    @discardableResult
    func start() -> UInt16? {
        guard listenFD < 0 else { return boundPort }
        guard let (fd, port) = bindLoopback() else { return nil }
        listenFD = fd
        boundPort = port
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = AppIdentity.queueLabel("notes-control")
        thread.stackSize = 512 * 1024
        acceptThread = thread
        thread.start()
        return port
    }

    /// Stop accepting and close the listening socket. Idempotent. In-flight connections finish or time out.
    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - Binding

    /// Bind a loopback-only TCP listener. When `preferredPort == 0` the OS assigns a free ephemeral port.
    /// When non-zero, tries preferredPort, then the next `scanRange - 1` ports, so a taken default rolls to
    /// the next free loopback port (recorded by the caller). Returns (fd, port) or nil.
    private func bindLoopback() -> (Int32, UInt16)? {
        let candidates: [UInt16]
        if config.preferredPort == 0 {
            candidates = [0]
        } else {
            let start = Int(config.preferredPort)
            candidates = (0..<max(1, config.scanRange)).compactMap { offset in
                let p = start + offset
                return p <= 65535 ? UInt16(p) : nil
            }
        }

        for candidate in candidates {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            // Loopback only: 127.0.0.1. This — not an auth token — is the security boundary.
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let bindOK = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard bindOK, listen(fd, 16) == 0 else {
                close(fd)
                continue
            }

            // Discover the actual port (needed when preferredPort was 0).
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let port: UInt16 = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                    return ptr.pointee.sin_port.bigEndian
                }
            }
            return (fd, port == 0 ? candidate : port)
        }
        return nil
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while running && listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if running { continue }   // interrupted by stop() closing the fd
                break
            }
            // Don't let a write to a client that hung up kill the whole process with SIGPIPE, and don't let a
            // stalled reader wedge the (serial) accept loop.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            handleConnection(client)
            close(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        guard let request = readRequest(fd) else {
            writeResponse(fd, status: 400, json: ["ok": false, "error": "bad_request"])
            return
        }
        let (status, body) = route(method: request.method, path: request.path, body: request.body)
        writeResponse(fd, status: status, json: body)
    }

    // MARK: - Routing (L1: reads; L2: content writes; L3: insert + lifecycle/focus; L4: attachments)

    private struct ParsedRequest {
        let method: String
        let path: String
        let body: Data
    }

    private enum TargetResolution {
        case found(StickyNoteWire)
        case rejected(status: Int, body: [String: Any])
    }

    /// Dispatch a request to a JSON response. Health answers any method; the read routes accept GET or POST
    /// (POST carries `{"target": ...}` for `read_sticky_note`; a GET may pass `?target=`); the write routes
    /// (`create_sticky_note`, `update_sticky_note`) are POST-only with a JSON body. Every write persists via
    /// the store AND pushes a live-render intent through the sink. Returns the HTTP status and the JSON object
    /// to serialize.
    private func route(method: String, path: String, body: Data) -> (Int, [String: Any]) {
        let (rawPath, query) = splitQuery(path)
        switch rawPath {
        case "/health":
            return (200, ["ok": true,
                          "service": "viddydictate-notes-control",
                          "version": 1,
                          "port": Int(boundPort)])

        case "/list_sticky_notes":
            let active = activeNoteIdProvider()
            let notes = store.openNotes().map { note -> [String: Any] in
                ["id": note.id, "title": note.title, "active": note.id == active]
            }
            return (200, ["ok": true, "notes": notes])

        case "/read_sticky_note":
            guard let target = targetArgument(body: body, query: query) else {
                return (400, ["ok": false, "error": "missing_target"])
            }
            let note: StickyNoteWire
            switch resolveTarget(target) {
            case .found(let resolved): note = resolved
            case .rejected(let status, let body): return (status, body)
            }
            return (200, ["ok": true,
                          "note": ["id": note.id, "title": note.title, "body": note.body,
                                   "active": note.id == activeNoteIdProvider()]])

        case "/create_sticky_note":
            return createStickyNote(method: method, body: body)

        case "/update_sticky_note":
            return updateStickyNote(method: method, body: body)

        case "/insert_sticky_note":
            return insertStickyNote(method: method, body: body)

        case "/rename_sticky_note":
            return renameStickyNote(method: method, body: body)

        case "/close_sticky_note":
            return closeStickyNote(method: method, body: body)

        case "/restore_sticky_note":
            return restoreStickyNote(method: method, body: body)

        case "/duplicate_sticky_note":
            return duplicateStickyNote(method: method, body: body)

        case "/focus_sticky_note":
            return focusStickyNote(method: method, body: body)

        case "/attach_media_to_sticky_note":
            return attachMediaToStickyNote(method: method, body: body)

        case "/read_sticky_note_attachments":
            return readStickyNoteAttachments(body: body, query: query)

        default:
            return (404, ["ok": false, "error": "unknown_route", "path": rawPath])
        }
    }

    // MARK: - Write routes (L2)

    /// `create_sticky_note(title?, content)` — mint a stable note-id, persist the body (+ optional title
    /// override) via the store, then push an `externalCreate` render intent. Returns the new note-id so the
    /// caller can address the note. POST-only; `content` is required (an empty body would evaporate on save,
    /// producing no note).
    private func createStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        let content = (obj["content"] as? String) ?? ""
        guard !content.isEmpty else { return (400, errorBody("missing_content")) }
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let id = StickyNotesStore.newNoteId()
        store.saveOpenNote(id: id, body: content)                 // persist FIRST (authoritative)
        if let title = title { store.renameNote(id: id, title: title) }
        let outcome = renderSink(.create(id: id, body: content, title: title))   // then render live

        let noteTitle = store.openNotes().first { $0.id == id }?.title ?? StickyNotesStore.title(for: content)
        return (200, ["ok": true, "note_id": id, "note_title": noteTitle,
                      "chars": content.count, "render": outcome.rawValue])
    }

    /// `update_sticky_note(target, mode:set|append, content)` — THE locked dataset authoring contract. Resolve
    /// `target` (a note-id or `"open"` = the active note), compute the new full body (set replaces; append
    /// joins onto a fresh line), persist it via the store, then push an `externalSetBody` render of the whole
    /// body so the live tab matches disk. POST-only; `content` is required. 404 if the target note is not open.
    private func updateStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        guard let rawTarget = obj["target"] as? String, !rawTarget.isEmpty else {
            return (400, errorBody("missing_target"))
        }
        let mode = (obj["mode"] as? String) ?? "set"
        guard mode == "set" || mode == "append" else { return (400, errorBody("bad_mode")) }
        let content = (obj["content"] as? String) ?? ""
        guard !content.isEmpty else { return (400, errorBody("missing_content")) }

        return withResolvedTarget(rawTarget) { existing in
            let id = existing.id

            let newBody: String
            if mode == "append" {
                let old = existing.body
                newBody = old.isEmpty ? content : old + (old.hasSuffix("\n") ? "" : "\n") + content
            } else {
                newBody = content
            }
            store.saveOpenNote(id: id, body: newBody)                 // persist FIRST (authoritative)
            let outcome = renderSink(.setBody(id: id, body: newBody)) // then render live

            let noteTitle = store.openNotes().first { $0.id == id }?.title
                ?? StickyNotesStore.title(for: newBody)
            return (200, ["ok": true, "note_id": id, "note_title": noteTitle,
                          "chars": newBody.count, "mode": mode, "render": outcome.rawValue])
        }
    }

    // MARK: - Insert + lifecycle/focus routes (L3)

    /// `insert_sticky_note(target, text)` — the dictation seam: land `text` at the target note's CURRENT
    /// cursor/selection. A caret insert is inherently a live-render operation (there is no caret on disk), so we
    /// keep persist-and-render in lockstep the honest way: persist a caret-at-end floor FIRST (so the text is
    /// never lost even with no live window), then push an `insertAtCaret` render. When a live editor holds the
    /// note it inserts at the TRUE caret and re-persists the exact result via the normal save round-trip (JS is
    /// the authoritative last-writer, identical to how dictation persists); with no live window the floor
    /// stands and surfaces on the next window open. POST-only; `content` (or `text`) required. 404 if not open.
    private func insertStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        guard let rawTarget = obj["target"] as? String, !rawTarget.isEmpty else {
            return (400, errorBody("missing_target"))
        }
        // Accept `text` (the tool's contract name) or `content` (for symmetry with the write routes).
        let text = (obj["text"] as? String) ?? (obj["content"] as? String) ?? ""
        guard !text.isEmpty else { return (400, errorBody("missing_text")) }

        return withResolvedTarget(rawTarget) { existing in
            let id = existing.id

            // Persist a caret-at-end floor FIRST (matches a live insert whose caret is at the end -- the common
            // dictation case). A live editor with a mid-note caret produces a different body and re-persists it,
            // winning over this floor; with no live window the floor is the honest, loss-free result.
            let floor = existing.body.isEmpty ? text : existing.body + text
            store.saveOpenNote(id: id, body: floor)
            let outcome = renderSink(.insertAtCaret(id: id, text: text))

            let noteTitle = store.openNotes().first { $0.id == id }?.title ?? StickyNotesStore.title(for: floor)
            return (200, ["ok": true, "note_id": id, "note_title": noteTitle,
                          "chars": text.count, "render": outcome.rawValue])
        }
    }

    /// `rename_sticky_note(target, title)` — set or clear the note's title override. An empty `title` CLEARS the
    /// override (the tab reverts to its body-derived title). Persist via `StickyNotesStore.renameNote` FIRST,
    /// then push a `rename` render so the live tab relabels. POST-only; the `title` key must be present (it may
    /// be an empty string to clear). 404 if the target note is not open.
    private func renameStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        guard let rawTarget = obj["target"] as? String, !rawTarget.isEmpty else {
            return (400, errorBody("missing_target"))
        }
        guard let title = obj["title"] as? String else { return (400, errorBody("missing_title")) }

        return withResolvedTarget(rawTarget) { existing in
            let id = existing.id

            let display = store.renameNote(id: id, title: title) ?? StickyNotesStore.title(for: existing.body)
            // The render carries the resolved display title, or "" to clear (the JS `renamed` handler reverts a
            // blank title to the body-derived one).
            let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : display
            let outcome = renderSink(.rename(id: id, title: explicit))
            return (200, ["ok": true, "note_id": id, "note_title": display, "render": outcome.rawValue])
        }
    }

    /// `close_sticky_note(target)` — SOFT, recoverable close: archive the note to history via
    /// `StickyNotesStore.closeNote` (restorable with `restore_sticky_note`), then push a `close` render so the
    /// live island drops the tab. POST-only. 404 if the target note is not open.
    private func closeStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        withResolvedTarget(method: method, body: body) { existing in
            let id = existing.id

            store.closeNote(id: id, body: existing.body)          // soft-delete to history (authoritative)
            let outcome = renderSink(.close(id: id))              // then drop the live tab
            return (200, ["ok": true, "note_id": id, "note_title": existing.title,
                          "render": outcome.rawValue])
        }
    }

    /// `restore_sticky_note(note-id)` — reopen a history note via `StickyNotesStore.restoreHistory`, then push a
    /// `restore` render so it returns as a live tab. `target` is the history note-id. The reopened note may get
    /// a fresh id (the store dedupes against a still-open file), so the response reports the RESTORED id.
    /// POST-only. 404 if no history row matches.
    private func restoreStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        guard let historyId = obj["target"] as? String, !historyId.isEmpty else {
            return (400, errorBody("missing_target"))
        }
        guard let note = store.restoreHistory(id: historyId) else {
            return (404, ["ok": false, "error": "not_found", "target": historyId])
        }
        let outcome = renderSink(.restore(id: note.id, body: note.body, title: note.title))
        return (200, ["ok": true, "note_id": note.id, "note_title": note.title, "render": outcome.rawValue])
    }

    /// `duplicate_sticky_note(target)` — mirror the web island's Duplicate flow: mint a fresh id, save the same
    /// body, apply a `"<title> copy"` override, and copy the source's attachments (`store.copyAttachments`),
    /// then push a `duplicate` render so the copy appears as the active tab (with its attachment tray). POST-only.
    /// 404 if the source note is not open.
    private func duplicateStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        withResolvedTarget(method: method, body: body) { source in
            let id = source.id

            let dupId = StickyNotesStore.newNoteId()
            let copyTitle = "\(source.title) copy"
            store.saveOpenNote(id: dupId, body: source.body)      // persist the copy FIRST
            store.renameNote(id: dupId, title: copyTitle)
            store.copyAttachments(fromNoteId: id, toNoteId: dupId)
            let dupTitle = store.openNotes().first { $0.id == dupId }?.title ?? copyTitle
            let outcome = renderSink(.duplicate(id: dupId, body: source.body, title: dupTitle))
            return (200, ["ok": true, "note_id": dupId, "note_title": dupTitle,
                          "source_id": id, "render": outcome.rawValue])
        }
    }

    /// `focus_sticky_note(target)` — make the target the active tab / key window. Pure live-window focus: no
    /// store mutation, so with no live window there is nothing to persist and the render reports `persisted_only`.
    /// POST-only. 404 if the target note is not open.
    private func focusStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        withResolvedTarget(method: method, body: body) { note in
            let id = note.id
            let outcome = renderSink(.focus(id: id))
            return (200, ["ok": true, "note_id": id, "note_title": note.title,
                          "render": outcome.rawValue])
        }
    }

    // MARK: - Attachment routes (L4)

    /// `attach_media_to_sticky_note(target, path)` — attach a local file (image OR video, type inferred from
    /// the extension) to the target note. Persist FIRST via `StickyNotesStore.addAttachment` (it copies the
    /// file byte-for-byte into the `attachments/<note-id>/` sidecar under a zero-padded `NN-<name>` id, enforces
    /// the 20/note soft cap + the media-only rule, and returns the outcome), then push an `attachmentsChanged`
    /// render so the live note-window tray updates in lockstep. POST-only. 404 if the target note is not open or
    /// the file is missing; 409 if the note is at the cap; 415 if the file is not an accepted media type.
    private func attachMediaToStickyNote(method: String, body: Data) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        guard let rawTarget = obj["target"] as? String, !rawTarget.isEmpty else {
            return (400, errorBody("missing_target"))
        }
        guard let path = obj["path"] as? String, !path.isEmpty else {
            return (400, errorBody("missing_path"))
        }

        return withResolvedTarget(rawTarget) { note in
            let id = note.id

            // Accept a plain absolute path or a file:// URL. Fail early with a clear error if the file is absent
            // so the store's generic `.failed` never masks a bad path.
            let fileURL = path.hasPrefix("file://") ? (URL(string: path) ?? URL(fileURLWithPath: path))
                                                    : URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return (404, ["ok": false, "error": "file_not_found", "path": path])
            }

            switch store.addAttachment(noteId: id, fileURL: fileURL) {      // persist FIRST (authoritative)
            case .added(let info):
                let outcome = renderSink(.attachmentsChanged(id: id))       // then refresh the live tray
                return (200, ["ok": true, "note_id": id, "note_title": note.title,
                              "attachment": ["name": info.name, "type": info.kind.rawValue,
                                             "path": info.url.path],
                              "render": outcome.rawValue])
            case .rejectedCap:
                return (409, ["ok": false, "error": "attachment_cap",
                              "detail": "note already has \(StickyNotesStore.attachmentSoftCap) attachments"])
            case .rejectedNotMedia:
                return (415, ["ok": false, "error": "not_media", "path": path])
            case .failed:
                return (500, errorBody("attach_failed"))
            }
        }
    }

    /// `read_sticky_note_attachments(target)` — list what is attached to the target note (name / type
    /// image|video / absolute path), via `StickyNotesStore.listAttachments`. Pure read: no render, no store
    /// mutation. Accepts a POST body `{"target": ...}` or a GET `?target=`. A note with no attachments returns
    /// an empty list (still ok). 404 if the target note is not open; 400 if no target is given.
    private func readStickyNoteAttachments(body: Data, query: [String: String]) -> (Int, [String: Any]) {
        guard let target = targetArgument(body: body, query: query) else {
            return (400, errorBody("missing_target"))
        }
        let note: StickyNoteWire
        switch resolveTarget(target) {
        case .found(let resolved): note = resolved
        case .rejected(let status, let body): return (status, body)
        }
        let id = note.id
        let attachments = store.listAttachments(noteId: id).map { info -> [String: Any] in
            ["name": info.name, "type": info.kind.rawValue, "path": info.url.path]
        }
        return (200, ["ok": true, "note_id": id, "attachments": attachments])
    }

    /// Parse a POST JSON body to an object. An empty body is treated as an empty object (so a missing field is
    /// reported as the specific missing-field error, not a generic bad_request); malformed JSON is nil.
    private func jsonBody(_ body: Data) -> [String: Any]? {
        guard !body.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private func errorBody(_ code: String) -> [String: Any] { ["ok": false, "error": code] }

    private func withResolvedTarget(
        method: String,
        body: Data,
        handler: (StickyNoteWire) -> (Int, [String: Any])
    ) -> (Int, [String: Any]) {
        guard method == "POST" else { return (405, errorBody("method_not_allowed")) }
        guard let obj = jsonBody(body) else { return (400, errorBody("bad_request")) }
        guard let rawTarget = obj["target"] as? String, !rawTarget.isEmpty else {
            return (400, errorBody("missing_target"))
        }
        return withResolvedTarget(rawTarget, handler: handler)
    }

    private func withResolvedTarget(
        _ rawTarget: String,
        handler: (StickyNoteWire) -> (Int, [String: Any])
    ) -> (Int, [String: Any]) {
        switch resolveTarget(rawTarget) {
        case .found(let note): return handler(note)
        case .rejected(let status, let body): return (status, body)
        }
    }

    private func resolveTarget(_ rawTarget: String) -> TargetResolution {
        let resolvedId = rawTarget == "open" ? activeNoteIdProvider() : rawTarget
        guard let id = resolvedId else {
            return .rejected(status: 404, body: errorBody("no_active_note"))
        }
        guard let note = store.openNotes().first(where: { $0.id == id }) else {
            return .rejected(status: 404,
                             body: ["ok": false, "error": "not_found", "target": rawTarget])
        }
        return .found(note)
    }

    /// Resolve the `target` argument from a POST JSON body (`{"target": "..."}`) or a GET query (`?target=`).
    private func targetArgument(body: Data, query: [String: String]) -> String? {
        if !body.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let t = obj["target"] as? String,
           !t.isEmpty {
            return t
        }
        if let t = query["target"], !t.isEmpty { return t }
        return nil
    }

    // MARK: - Minimal HTTP/1.1 read + write (Connection: close, no keep-alive)

    /// Read one request: headers up to the blank line, then `Content-Length` body bytes. Caps the total to
    /// 1 MiB (L1 bodies are tiny). Returns nil on malformed input or read error.
    private func readRequest(_ fd: Int32) -> ParsedRequest? {
        let maxBytes = 1 << 20
        var buffer = Data()
        var headerEnd: Range<Data.Index>? = nil
        let separator = Data("\r\n\r\n".utf8)

        // Read until we have the header terminator.
        while headerEnd == nil {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if buffer.count > maxBytes { return nil }
            headerEnd = buffer.range(of: separator)
        }
        guard let hdrRange = headerEnd,
              let headerText = String(data: buffer[..<hdrRange.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            if kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        if contentLength < 0 || contentLength > maxBytes { return nil }

        var body = Data(buffer[hdrRange.upperBound...])
        while body.count < contentLength {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
            body.append(chunk)
            if body.count > maxBytes { return nil }
        }
        if body.count > contentLength { body = body.prefix(contentLength) }
        return ParsedRequest(method: method, path: path, body: body)
    }

    private func readChunk(_ fd: Int32) -> Data? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n < 0 { return nil }
        return Data(buf.prefix(n))
    }

    private func writeResponse(_ fd: Int32, status: Int, json: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{\"ok\":false}".utf8)
        let reason = Self.reasonPhrase(status)
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(bodyData)
        writeAll(fd, out)
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    // MARK: - Small pure helpers

    private func splitQuery(_ path: String) -> (String, [String: String]) {
        guard let q = path.firstIndex(of: "?") else { return (path, [:]) }
        let rawPath = String(path[..<q])
        let queryString = String(path[path.index(after: q)...])
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            params[key] = value
        }
        return (rawPath, params)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}
