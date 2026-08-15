import Cocoa

private typealias BridgeKey = NotesBridgePayloadKey

extension NotesWindowController {
    // MARK: - File-backed conflict handling

    func handleFileBackedRename(id: String, stem: String, payload: [String: Any]) {
        func restoreCurrentTitle(with message: String?) {
            if let current = store.openNotes().first(where: { $0.id == id }) {
                call(.renamed, payload: NotesWirePayload.note(current))
            }
            if let message { call(.toast, payload: [BridgeKey.message: message]) }
        }

        switch store.renameFileBackedNote(id: id, stem: stem) {
        case .renamed(let note), .unchanged(let note):
            rewriteAggregate(from: payload)
            call(.renamed, payload: NotesWirePayload.note(note))
        case .collision:
            restoreCurrentTitle(with: "A file with that name already exists")
        case .locked:
            restoreCurrentTitle(with: "Rename is locked for vault files")
        case .illegalName:
            restoreCurrentTitle(with: "That filename is not allowed")
        case .missing, .failed:
            restoreCurrentTitle(with: "Could not rename the file")
        }
    }

    func handleFileBackedClose(id: String, body: String) {
        let result = store.closeFileBackedNote(id: id, body: body)
        if result.permitsClose {
            call(.externalClose, payload: [BridgeKey.id: id])
            return
        }
        if case .conflict(let conflict) = result {
            presentFileConflict(conflict, closeAfterResolution: true)
        } else {
            call(.toast, payload: [BridgeKey.message: fileSyncFailureMessage(result)])
        }
    }

    /// The loopback close route has no web payload. Use the last native-observed buffer, keep the tab visible
    /// on conflict/failure, and complete the externalClose render only after the gated close is safe.
    func requestFileBackedClose(id: String) -> Bool {
        let result = store.flushFileBackedNote(id: id)
        if result.permitsClose {
            guard store.dropFileBackedNote(id: id) else {
                call(.toast, payload: [BridgeKey.message: "Could not safely close this file"])
                return false
            }
            call(.externalClose, payload: [BridgeKey.id: id])
            return true
        }
        if case .conflict(let conflict) = result {
            presentFileConflict(conflict, closeAfterResolution: true)
            return true
        }
        call(.toast, payload: [BridgeKey.message: fileSyncFailureMessage(result)])
        return false
    }

    /// Translate a store result into the web-island contract. Clean live reloads are conditional on the exact
    /// buffer that requested the sync; explicit conflict choices force their selected outcome.
    func handleFileSyncResult(
        _ result: FileBackedSyncResult, id: String, expectedBody: String?,
        forceReload: Bool = false, message: String? = nil
    ) {
        switch result {
        case .unchanged:
            break
        case .saved(let body):
            call(.fileSaved, payload: [BridgeKey.id: id, BridgeKey.body: body])
        case .merged(let body), .reloaded(let body):
            var payload: [String: Any] = [
                BridgeKey.id: id,
                BridgeKey.body: body,
                "force": forceReload,
            ]
            if let expectedBody { payload["expectedBody"] = expectedBody }
            if let message { payload[BridgeKey.message] = message }
            call(.fileReload, payload: payload)
        case .conflict(let conflict):
            presentFileConflict(conflict, closeAfterResolution: false)
        case .copiedAndReloaded(let body, let copyURL):
            call(.fileReload, payload: [
                BridgeKey.id: id,
                BridgeKey.body: body,
                "force": true,
                BridgeKey.message: "Saved your edits as \(copyURL.lastPathComponent)",
            ])
        case .readOnly, .missing, .failed:
            call(.toast, payload: [BridgeKey.message: fileSyncFailureMessage(result)])
        }
    }

    private func fileSyncFailureMessage(_ result: FileBackedSyncResult) -> String {
        switch result {
        case .readOnly: return "This file is read-only"
        case .missing: return "The file-backed tab is no longer available"
        default: return "Could not safely save this file"
        }
    }

    private func presentFileConflict(_ conflict: FileBackedConflict, closeAfterResolution: Bool) {
        if let alreadyClosing = conflictCloseAfter[conflict.noteId] {
            conflictCloseAfter[conflict.noteId] = alreadyClosing || closeAfterResolution
            // Keep the token for the conflict already visible: if disk changes again while its sheet is open,
            // Keep Mine must fail that stale token and surface a fresh sheet. A queued, not-yet-visible item can
            // safely coalesce to the latest disk version.
            if activeConflictId != conflict.noteId { pendingFileConflicts[conflict.noteId] = conflict }
            return
        }
        pendingFileConflicts[conflict.noteId] = conflict
        conflictCloseAfter[conflict.noteId] = closeAfterResolution
        conflictQueue.append(conflict.noteId)
        presentNextFileConflict()
    }

    private func presentNextFileConflict() {
        guard activeConflictId == nil else { return }
        while let id = conflictQueue.first {
            conflictQueue.removeFirst()
            guard let conflict = pendingFileConflicts[id] else { continue }
            activeConflictId = id
            presentFileConflictSheet(conflict)
            return
        }
    }

    private func presentFileConflictSheet(_ conflict: FileBackedConflict) {
        let filename = store.fileBackedOrigin(id: conflict.noteId)
            .map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "This file"
        focus()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(filename) changed on disk"
        alert.informativeText = "Your tab also has edits. Choose which version to keep; ViddyDictate has not overwritten the disk change."
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Take Theirs")
        alert.addButton(withTitle: "Save Mine as a Copy")
        guard let window else {
            pendingFileConflicts.removeValue(forKey: conflict.noteId)
            conflictCloseAfter.removeValue(forKey: conflict.noteId)
            activeConflictId = nil
            presentNextFileConflict()
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.pendingFileConflicts.removeValue(forKey: conflict.noteId)
            let closeAfter = self.conflictCloseAfter.removeValue(forKey: conflict.noteId) ?? false
            self.activeConflictId = nil
            defer { self.presentNextFileConflict() }
            let choice: FileBackedConflictChoice
            switch response {
            case .alertFirstButtonReturn: choice = .keepMine
            case .alertSecondButtonReturn: choice = .takeTheirs
            default: choice = .saveMineAsCopy
            }
            let result = self.store.resolveFileBackedConflict(conflict, choice: choice)
            if closeAfter, result.permitsClose {
                if self.store.dropFileBackedNote(id: conflict.noteId) {
                    self.call(.externalClose, payload: [BridgeKey.id: conflict.noteId])
                } else {
                    self.call(.toast, payload: [BridgeKey.message: "Could not safely close this file"])
                }
                return
            }
            self.handleFileSyncResult(
                result, id: conflict.noteId, expectedBody: conflict.mine,
                forceReload: true)
        }
    }

    /// Window/app close uses the latest native-observed buffer and the same fingerprint gate as the timer.
    /// Conflicts keep the close/quit pending and surface the same three-way choice.
    func flushFileBackedNotesForClose(presentReloads: Bool) -> Bool {
        var safe = true
        for id in lastTabOrder where store.isFileBackedNote(id: id) {
            let result = store.flushFileBackedNote(id: id)
            switch result {
            case .conflict(let conflict):
                safe = false
                presentFileConflict(conflict, closeAfterResolution: false)
            case .readOnly, .missing, .failed:
                safe = false
                call(.toast, payload: [BridgeKey.message: fileSyncFailureMessage(result)])
            case .saved(let body):
                if presentReloads { call(.fileSaved, payload: [BridgeKey.id: id, BridgeKey.body: body]) }
            case .merged, .reloaded:
                if presentReloads {
                    handleFileSyncResult(result, id: id, expectedBody: nil)
                }
            case .unchanged, .copiedAndReloaded:
                break
            }
        }
        return safe
    }
}
