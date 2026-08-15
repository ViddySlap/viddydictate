import Cocoa

private typealias BridgeKey = NotesBridgePayloadKey

extension NotesWindowController {
    // MARK: - External content writes

    /// Render a note created outside the web island. Swift has already minted the id and persisted the body
    /// (+ any title override and attachments); this pushes the tab and its attachment manifest into the live
    /// island. Returns `true` when the page was ready to render it, `false` otherwise (the store write stands
    /// and the note surfaces on the next `sendInitialState`). Must be called on the main thread.
    @discardableResult
    func renderExternalCreate(id: String, body: String, title: String?) -> Bool {
        guard pageReady else { return false }
        call(.externalCreate, payload: [BridgeKey.id: id, BridgeKey.body: body,
                                        BridgeKey.title: title ?? ""])
        sendAttachments(noteId: id)
        return true
    }

    /// Render an update (set / full post-append body) landed via the control endpoint by replacing the live
    /// tab's body for `id`. Swift has already persisted the new body; this keeps the rendered DOM in lockstep
    /// so JS's next autosave cannot clobber it with stale text. Returns `true` when the page was ready. Must be
    /// called on the main thread.
    @discardableResult
    func renderExternalSetBody(id: String, body: String) -> Bool {
        guard pageReady else { return false }
        call(.externalSetBody, payload: [BridgeKey.id: id, BridgeKey.body: body])
        return true
    }

    // MARK: - External insert + lifecycle/focus renders

    /// Insert `text` at the target note's live caret (the endpoint's dictation seam). The route persisted a
    /// caret-at-end floor already; JS inserts at the TRUE caret and re-persists via its save round-trip. Returns
    /// `true` when the page was ready. Must be called on the main thread.
    @discardableResult
    func renderExternalInsert(id: String, text: String) -> Bool {
        guard pageReady else { return false }
        call(.externalInsert, payload: [BridgeKey.id: id, BridgeKey.text: text])
        return true
    }

    /// Append a finished Sticky Skill result at the END of the target note's LIVE document (S2's
    /// `.appendToSource` landing). Swift passes the ADDITION only and writes nothing: the island applies it
    /// as an ordinary CodeMirror transaction against its own live buffer and re-persists the exact result
    /// through the normal save round-trip. Returns `true` when the page was ready, which is the caller's
    /// signal that it must NOT fall back to a store write. Must be called on the main thread.
    @discardableResult
    func renderExternalAppend(id: String, text: String) -> Bool {
        guard pageReady else { return false }
        call(.externalAppend, payload: [BridgeKey.id: id, BridgeKey.text: text])
        return true
    }

    /// Relabel an open note's live tab. `title` is the resolved display title, or `""` to clear the override.
    /// The store override is already written; this only updates the tab label. Must be called on the main thread.
    @discardableResult
    func renderExternalRename(id: String, title: String) -> Bool {
        guard pageReady else { return false }
        call(.renamed, payload: [BridgeKey.id: id, BridgeKey.title: title])
        return true
    }

    /// Drop an open note's live tab after the store has soft-closed it to history. Must be called on the main
    /// thread.
    @discardableResult
    func renderExternalClose(id: String) -> Bool {
        guard pageReady else { return false }
        call(.externalClose, payload: [BridgeKey.id: id])
        return true
    }

    /// Render a restored note back as the active live tab (the store already reopened it under `id`). Must be
    /// called on the main thread.
    @discardableResult
    func renderExternalRestore(id: String, body: String, title: String) -> Bool {
        guard pageReady else { return false }
        call(.restored, payload: [BridgeKey.id: id, BridgeKey.body: body, BridgeKey.title: title])
        sendAttachments(noteId: id)
        return true
    }

    /// Render a duplicated note as the active live tab AND push its attachment tray (the store already copied
    /// the source's attachments). Reuses the `externalCreate` tab render. Must be called on the main thread.
    @discardableResult
    func renderExternalDuplicate(id: String, body: String, title: String) -> Bool {
        guard pageReady else { return false }
        call(.externalCreate, payload: [BridgeKey.id: id, BridgeKey.body: body, BridgeKey.title: title])
        sendAttachments(noteId: id)
        return true
    }

    /// Select the target note's tab so it becomes active (the native window is raised by the registry). Must be
    /// called on the main thread.
    @discardableResult
    func renderExternalFocus(id: String) -> Bool {
        guard pageReady else { return false }
        call(.externalFocus, payload: [BridgeKey.id: id])
        return true
    }

    /// Push the target note's attachment tray to the live island after the store copied in a new sidecar file.
    /// Reuses `sendAttachments` (the same `attachments` bridge msg drop-and-duplicate
    /// already drive), so no new wire name. Returns `true` when the page was ready. Must be called on the main
    /// thread.
    @discardableResult
    func renderExternalAttachments(id: String) -> Bool {
        guard pageReady else { return false }
        sendAttachments(noteId: id)
        return true
    }
}
