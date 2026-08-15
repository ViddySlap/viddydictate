import Foundation
import AppKit

extension NotesProbe {
    static func probeAttachmentsBackend(fm: FileManager, base: URL, freshRoot: () -> URL, check: Check) -> Bool {
        // --- 10. attachments backend (L3/L2 media assets) ----------------------------------------
        // Sidecar media attachments: add (file URL + raw image data), ordered list with zero-padded prefixes,
        // remove, non-media rejection, the 20/note soft cap, attachment-aware evaporation, the
        // close->history->restore + hard-delete + retention-purge lifecycle (attachment dir follows the
        // note), copy-all-for-note (duplicate), save-as sibling export, and the additive aggregate line.
        func isAdded(_ r: StickyNotesStore.AttachmentAddResult) -> Bool { if case .added = r { return true }; return false }
        func isCap(_ r: StickyNotesStore.AttachmentAddResult) -> Bool { r == .rejectedCap }
        func isNotMedia(_ r: StickyNotesStore.AttachmentAddResult) -> Bool { r == .rejectedNotMedia }
        // Magic-byte-valid image payloads (only the signature matters to the store's sniffer).
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00])
        let gifData = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x00, 0x00])
        let videoData = Data("not-real-video-but-a-preserved-file-asset".utf8)

        // Pin the attachment-copy writer contract without asking the sandboxed pasteboard server
        // to accept a write; the conductor's pasteboard tier exercises the real AppKit write.
        do {
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name(AppIdentity.queueLabel("notes-probe-\(UUID().uuidString)")))
            defer { pasteboard.releaseGlobally() }
            let originalURL = base.appendingPathComponent("pasteboard-fidelity.png")
            try? pngData.write(to: originalURL)
            let writer = SyntheticPasteboard.makeURLWriter(originalURL)
            let types = writer.writableTypes(for: pasteboard)
            let markerPayload = writer.pasteboardPropertyList(
                forType: SyntheticPasteboard.markerType) as? Data
            let filePropertyList = writer.pasteboardPropertyList(forType: .fileURL)
            let roundTrippedURL = filePropertyList.flatMap {
                NSURL(pasteboardPropertyList: $0, ofType: .fileURL)
            } as URL?
            check("attach copy: synthetic URL writer carries the clipboard-history marker",
                  types.contains(SyntheticPasteboard.markerType) && markerPayload == Data())
            check("attach copy: synthetic URL writer preserves NSURL file-URL fidelity",
                  types.contains(.fileURL) && roundTrippedURL == originalURL)
        }

        // 10a. add (file URL + data), list order, zero-pad, names/kinds, remove, non-media reject
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-att", body: "# Has media\nbody")
            let drops = base.appendingPathComponent("drops", isDirectory: true)
            try? fm.createDirectory(at: drops, withIntermediateDirectories: true)
            let alpha = drops.appendingPathComponent("alpha.png")
            try? pngData.write(to: alpha)
            check("attach add: image file URL accepted",
                  isAdded(store.addAttachment(noteId: "note-att", fileURL: alpha)))
            check("attach add: raw image data accepted (magic-sniffed)",
                  isAdded(store.addAttachment(noteId: "note-att", data: gifData, suggestedName: "pasted.gif")))
            let clip = drops.appendingPathComponent("clip.mp4")
            try? videoData.write(to: clip)
            check("attach add: video file URL accepted",
                  isAdded(store.addAttachment(noteId: "note-att", fileURL: clip)))
            let list = store.listAttachments(noteId: "note-att")
            check("attach list: ordered, zero-padded prefixes, original names preserved",
                  list.count == 3
                  && list[0].id == "01-alpha.png" && list[0].name == "alpha.png"
                  && list[1].id == "02-pasted.gif" && list[1].name == "pasted.gif"
                  && list[2].id == "03-clip.mp4" && list[2].name == "clip.mp4")
            check("attach list: image/video kinds are explicit",
                  list.map(\.kind) == [.image, .image, .video])
            let videoNames = ["sample.mov", "sample.mp4", "sample.m4v", "sample.webm"]
            let videoResults = videoNames.map { name -> StickyNotesStore.AttachmentAddResult in
                let url = drops.appendingPathComponent(name)
                try? videoData.write(to: url)
                return store.addAttachment(noteId: "note-video", fileURL: url)
            }
            let videos = store.listAttachments(noteId: "note-video")
            check("attach add: common video file URL extensions accepted",
                  videoResults.allSatisfy(isAdded)
                  && videos.map(\.name) == videoNames
                  && videos.allSatisfy { $0.kind == .video })
            let txt = drops.appendingPathComponent("notes.txt")
            try? Data("hi".utf8).write(to: txt)
            check("attach reject: non-media file URL rejected",
                  isNotMedia(store.addAttachment(noteId: "note-att", fileURL: txt)))
            check("attach reject: non-image bytes rejected even with an image-looking name",
                  isNotMedia(store.addAttachment(noteId: "note-att", data: Data("plain".utf8), suggestedName: "x.png")))
            store.removeAttachment(noteId: "note-att", attachmentId: "01-alpha.png")
            let after = store.listAttachments(noteId: "note-att")
            check("attach remove: drops the named attachment, keeps the rest",
                  after.count == 2 && after.map(\.id) == ["02-pasted.gif", "03-clip.mp4"])
        }

        // 10b. soft cap of 20/note
        do {
            let store = StickyNotesStore(root: freshRoot())
            for i in 1...20 { _ = store.addAttachment(noteId: "note-cap", data: pngData, suggestedName: "p\(i).png") }
            check("attach cap: 20 attachments accepted", store.listAttachments(noteId: "note-cap").count == 20)
            check("attach cap: the 21st is rejected with the cap result",
                  isCap(store.addAttachment(noteId: "note-cap", data: pngData, suggestedName: "p21.png")))
            check("attach cap: still exactly 20 after the rejected add",
                  store.listAttachments(noteId: "note-cap").count == 20)
        }

        // 10c. attachment-aware evaporation
        do {
            let store = StickyNotesStore(root: freshRoot())
            _ = store.addAttachment(noteId: "note-evap", data: pngData, suggestedName: "a.png")
            store.saveOpenNote(id: "note-evap", body: "   \n ")
            check("attach evaporation: empty text but has an attachment -> note survives",
                  store.openNotes().contains { $0.id == "note-evap" })
            let attId = store.listAttachments(noteId: "note-evap").first?.id ?? ""
            store.removeAttachment(noteId: "note-evap", attachmentId: attId)
            store.saveOpenNote(id: "note-evap", body: "   ")
            check("attach evaporation: no text AND no attachment -> evaporates",
                  !store.openNotes().contains { $0.id == "note-evap" })
        }

        // 10d. lifecycle: close -> history -> restore, and hard-delete purges the history attachment dir
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-life", body: "# Keep\ntext")
            _ = store.addAttachment(noteId: "note-life", data: pngData, suggestedName: "k.png")
            let drops = base.appendingPathComponent("lifecycle-drops", isDirectory: true)
            try? fm.createDirectory(at: drops, withIntermediateDirectories: true)
            let clip = drops.appendingPathComponent("keep.mov")
            try? videoData.write(to: clip)
            _ = store.addAttachment(noteId: "note-life", fileURL: clip)
            store.closeNote(id: "note-life", body: "# Keep\ntext")
            check("attach lifecycle: close moves the attachment off the open side",
                  store.openNotes().isEmpty && !store.hasAttachments(id: "note-life"))
            guard let histId = store.history(retention: .forever).first?.id else {
                check("attach lifecycle: a history row exists", false); return false }
            guard let restored = store.restoreHistory(id: histId) else {
                check("attach lifecycle: restore returns the note", false); return false }
            check("attach lifecycle: restore brings the attachment back with the note",
                  store.hasAttachments(id: restored.id)
                  && store.listAttachments(noteId: restored.id).map(\.kind) == [.image, .video])
            store.closeNote(id: restored.id, body: restored.body)
            guard let delId = store.history(retention: .forever).first?.id else {
                check("attach lifecycle: a re-closed history row exists", false); return false }
            store.deleteHistory(id: delId)
            check("attach lifecycle: hard-delete purges the history attachment dir",
                  !fm.fileExists(atPath: store.root.appendingPathComponent("notes-history/attachments/\(delId)").path))
        }

        // 10d-ii. Per-window tray manifests come from the coordinator, not from window-local state. Pin the
        // exact BMO-tests shape (three mixed-media attachments), then close/restore the note and prove the
        // coordinator can immediately rebuild the restored note's manifest for its new host window.
        do {
            let store = StickyNotesStore(root: freshRoot())
            let coordinator = NotesAttachmentCoordinator(store: store)
            store.saveOpenNote(id: "note-window-move", body: "# BMO tests\nbody")
            _ = store.addAttachment(noteId: "note-window-move", data: pngData,
                                    suggestedName: "first-screen.png")
            let drops = base.appendingPathComponent("window-move-drops", isDirectory: true)
            try? fm.createDirectory(at: drops, withIntermediateDirectories: true)
            let clip = drops.appendingPathComponent("middle-recording.mov")
            try? videoData.write(to: clip)
            _ = store.addAttachment(noteId: "note-window-move", fileURL: clip)
            _ = store.addAttachment(noteId: "note-window-move", data: gifData,
                                    suggestedName: "last-screen.gif")

            let movePayload = coordinator.payload(noteId: "note-window-move")
            check("attach manifest: coordinator rebuilds all three assets for a destination window",
                  movePayload.compactMap { $0["name"] as? String }
                    == ["first-screen.png", "middle-recording.mov", "last-screen.gif"]
                  && movePayload.compactMap { $0["kind"] as? String }
                    == ["image", "video", "image"]
                  && coordinator.noteIdsWithAttachments(in: ["note-empty", "note-window-move"])
                    == ["note-window-move"])

            store.closeNote(id: "note-window-move", body: "# BMO tests\nbody")
            guard let historyId = store.history(retention: .forever).first?.id,
                  let restored = store.restoreHistory(id: historyId) else {
                check("attach manifest: history restore returns a note", false)
                return false
            }
            let restoredPayload = coordinator.payload(noteId: restored.id)
            check("attach manifest: coordinator rebuilds all three assets immediately after History restore",
                  restoredPayload.compactMap { $0["name"] as? String }
                    == ["first-screen.png", "middle-recording.mov", "last-screen.gif"]
                  && restoredPayload.compactMap { $0["kind"] as? String }
                    == ["image", "video", "image"])
        }

        // The UI-bearing WKWebView calls cannot run inside the deterministic probe, so pin the delivery wiring
        // at the native boundary: every path that inserts an already-attached note into an existing island must
        // follow the tab render with a coordinator-backed `sendAttachments` push.
        do {
            let repo = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            let tabDrag = (try? String(contentsOf: repo.appendingPathComponent(
                "Sources/App/NotesWindowController+TabDrag.swift"), encoding: .utf8)) ?? ""
            let controller = (try? String(contentsOf: repo.appendingPathComponent(
                "Sources/App/NotesWindowController.swift"), encoding: .utf8)) ?? ""
            let external = (try? String(contentsOf: repo.appendingPathComponent(
                "Sources/App/NotesWindowController+ExternalRenders.swift"), encoding: .utf8)) ?? ""

            let migrateBody = sourceSlice(tabDrag, from: "func adoptMigratedTabs(",
                                          to: "func insertDockedTab(")
            let dockBody = sourceSlice(tabDrag, from: "func insertDockedTab(",
                                       to: "func openFileBackedTab(")
            let historyRestoreBody = sourceSlice(controller, from: "case .restore:",
                                                  to: "case .deleteHistory:")
            let externalRestoreBody = sourceSlice(external, from: "func renderExternalRestore(",
                                                   to: "func renderExternalDuplicate(")
            let externalCreateBody = sourceSlice(external, from: "func renderExternalCreate(",
                                                  to: "func renderExternalSetBody(")
            check("attach delivery: title-bar migration pushes each inserted note's manifest",
                  migrateBody.contains("sendAttachments(noteId: note.id)"))
            check("attach delivery: cross-window docking pushes the moved note's manifest",
                  dockBody.contains("sendAttachments(noteId: note.id)"))
            check("attach delivery: in-window History restore pushes the restored note's manifest",
                  historyRestoreBody.contains("sendAttachments(noteId: id)"))
            check("attach delivery: external History restore pushes the restored note's manifest",
                  externalRestoreBody.contains("sendAttachments(noteId: id)"))
            check("attach delivery: an externally created note pushes its attachment manifest",
                  externalCreateBody.contains("call(.externalCreate")
                  && externalCreateBody.contains("sendAttachments(noteId: id)"))
        }

        // 10e. retention purge removes the history attachment dir with the expired row
        do {
            let store = StickyNotesStore(root: freshRoot())
            let now = Date()
            seedHistory(root: store.root,
                        entries: [("note-old", "note-old.md", now.addingTimeInterval(-240 * 3600))])
            let attDir = store.root.appendingPathComponent("notes-history/attachments/note-old", isDirectory: true)
            try? fm.createDirectory(at: attDir, withIntermediateDirectories: true)
            try? videoData.write(to: attDir.appendingPathComponent("01-old-clip.mp4"))
            _ = store.history(retention: .oneDay)   // triggers the purge
            check("attach retention: expired history row takes its attachment dir with it",
                  !fm.fileExists(atPath: attDir.path))
        }

        // 10f. duplicate copies all attachments (copy-all-for-note)
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-dsrc", body: "# Src\nbody")
            _ = store.addAttachment(noteId: "note-dsrc", data: pngData, suggestedName: "one.png")
            let drops = base.appendingPathComponent("duplicate-drops", isDirectory: true)
            try? fm.createDirectory(at: drops, withIntermediateDirectories: true)
            let clip = drops.appendingPathComponent("two.webm")
            try? videoData.write(to: clip)
            _ = store.addAttachment(noteId: "note-dsrc", fileURL: clip)
            let dupId = StickyNotesStore.newNoteId()
            store.saveOpenNote(id: dupId, body: "# Src\nbody")
            store.copyAttachments(fromNoteId: "note-dsrc", toNoteId: dupId)
            let srcList = store.listAttachments(noteId: "note-dsrc")
            let dupList = store.listAttachments(noteId: dupId)
            check("attach duplicate: copy-all replicates every attachment (ids + order preserved)",
                  dupList.count == 2
                  && dupList.map(\.id) == srcList.map(\.id)
                  && dupList.map(\.kind) == [.image, .video])
            check("attach duplicate: the source keeps its attachments",
                  store.listAttachments(noteId: "note-dsrc").count == 2)
        }

        // 10g. save-as exports a sibling <name>-attachments folder
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-sax", body: "# Report\ncontent")
            _ = store.addAttachment(noteId: "note-sax", data: pngData, suggestedName: "chart.png")
            let drops = base.appendingPathComponent("saveas-drops", isDirectory: true)
            try? fm.createDirectory(at: drops, withIntermediateDirectories: true)
            let clip = drops.appendingPathComponent("demo.m4v")
            try? videoData.write(to: clip)
            _ = store.addAttachment(noteId: "note-sax", fileURL: clip)
            let dest = base.appendingPathComponent("att-exports", isDirectory: true)
            do {
                let md = try store.saveAs(id: "note-sax", body: "# Report\ncontent", destination: dest)
                let folder = dest.appendingPathComponent("\(md.deletingPathExtension().lastPathComponent)-attachments",
                                                         isDirectory: true)
                let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                check("attach save-as: exports a sibling <name>-attachments folder with the files (original names)",
                      fm.fileExists(atPath: folder.path)
                      && Set(files.map(\.lastPathComponent)) == Set(["chart.png", "demo.m4v"]))
            } catch {
                check("attach save-as: did not throw", false, "\(error)")
            }
        }

        // 10h. additive aggregate **Attachments:** line, header/body unchanged, image/video paths visible
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-agg", body: "# Visible\nbody")
            _ = store.addAttachment(noteId: "note-agg", data: pngData, suggestedName: "pic.png")
            let drops = base.appendingPathComponent("aggregate-drops", isDirectory: true)
            try? fm.createDirectory(at: drops, withIntermediateDirectories: true)
            let clip = drops.appendingPathComponent("screen-recording.mp4")
            try? videoData.write(to: clip)
            _ = store.addAttachment(noteId: "note-agg", fileURL: clip)
            store.rewriteAggregate(tabOrder: ["note-agg"], activeId: "note-agg")
            let agg = (try? String(contentsOf: store.root.appendingPathComponent("_open-notes.md"), encoding: .utf8)) ?? ""
            let assets = store.listAttachments(noteId: "note-agg")
            let imagePath = assets.first { $0.kind == .image }?.url.path ?? ""
            let videoPath = assets.first { $0.kind == .video }?.url.path ?? ""
            check("attach aggregate: additive **Attachments:** header appears for the note",
                  agg.contains("**Attachments:**"))
            check("attach aggregate: lists image and video absolute file paths as bullets",
                  !imagePath.isEmpty && !videoPath.isEmpty
                  && imagePath.hasPrefix("/")
                  && videoPath.hasPrefix("/")
                  && agg.contains("- \(imagePath)")
                  && agg.contains("- \(videoPath)"))
            check("attach aggregate: existing header/body format unchanged for the section",
                  agg.contains("## Visible (active)\n\n# Visible\nbody"))
        }

        // 10i. rename an attachment (notes-8-rename): keeps the NN- prefix + media extension, the id updates,
        // order is preserved, and extension-change / path-traversal attempts are rejected.
        do {
            let store = StickyNotesStore(root: freshRoot())
            store.saveOpenNote(id: "note-ren", body: "# Rename\nbody")
            _ = store.addAttachment(noteId: "note-ren", data: pngData, suggestedName: "first.png")
            _ = store.addAttachment(noteId: "note-ren", data: gifData, suggestedName: "second.gif")
            // add -> rename the SECOND -> list reflects the new name; order (numeric prefix) is stable.
            store.renameAttachment(noteId: "note-ren", attachmentId: "02-second.gif", newName: "renamed.gif")
            let renamed = store.listAttachments(noteId: "note-ren")
            check("attach rename: add->rename->list reflects the new name, order preserved (prefix stable)",
                  renamed.count == 2
                  && renamed[0].id == "01-first.png" && renamed[0].name == "first.png"
                  && renamed[1].id == "02-renamed.gif" && renamed[1].name == "renamed.gif")
            // an attempt to change the extension / swap the media type is rejected (no-op).
            store.renameAttachment(noteId: "note-ren", attachmentId: "02-renamed.gif", newName: "hijack.png")
            check("attach rename: extension-change / media-swap attempt rejected (media extension enforced)",
                  store.listAttachments(noteId: "note-ren").map(\.id) == ["01-first.png", "02-renamed.gif"])
            // a bare new name (no extension) keeps the original media extension.
            store.renameAttachment(noteId: "note-ren", attachmentId: "02-renamed.gif", newName: "bare")
            let bare = store.listAttachments(noteId: "note-ren").last
            check("attach rename: a name with no extension keeps the original media extension",
                  bare?.id == "02-bare.gif" && bare?.name == "bare.gif")
            // a path-traversal new name is sanitized and stays inside the note's attachment dir.
            store.renameAttachment(noteId: "note-ren", attachmentId: "02-bare.gif", newName: "../evil.gif")
            let traversed = store.listAttachments(noteId: "note-ren").last
            check("attach rename: a path-traversal new name is sanitized and stays in the note dir",
                  store.listAttachments(noteId: "note-ren").count == 2
                  && traversed?.id == "02-_evil.gif"
                  && traversed?.url.deletingLastPathComponent().lastPathComponent == "note-ren")
            // a path-traversal SOURCE id is rejected outright (mirrors removeAttachment's guard).
            store.renameAttachment(noteId: "note-ren", attachmentId: "../01-first.png", newName: "x.gif")
            check("attach rename: a path-traversal source attachment id is rejected (no-op)",
                  store.listAttachments(noteId: "note-ren").map(\.id) == ["01-first.png", "02-_evil.gif"])
        }

        return true
    }

}
