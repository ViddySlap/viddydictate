import Foundation

/// Headless verification seam for the loopback Sticky Notes control endpoint.
/// Run with `--notes-http-selftest`. No LM Studio, audio, or UI, and — critically — it NEVER binds the real
/// default port 8766, never touches the user's real
/// `~/Library/Application Support/ViddyDictate/sticky-notes/` store, and never disturbs the live app.
///
/// It spins a `NotesControlServer` on a SCRATCH ephemeral port (`preferredPort: 0`, OS-assigned) bound to a
/// SCRATCH `StickyNotesStore` under the OS temp dir, with a FIXED active-note provider standing in for the
/// live window registry. It then exercises the L1 routes over real loopback HTTP round-trips (proving the
/// transport reaches the running listener) and asserts the JSON contract:
///   - `/health` returns ok + the service name + the bound port
///   - `/list_sticky_notes` returns every open note with id/title and the active flag on the active note
///   - `/read_sticky_note` returns the full body for a note-id target
///   - `/read_sticky_note` with `target: "open"` resolves to the active note's body
///   - an unknown target returns ok:false / not_found, and a missing target is a 400
///
/// L2 adds the content-write routes on top: `/create_sticky_note` and `/update_sticky_note` (set + append).
/// Every write must do BOTH — persist to the store AND push a live-render intent — so the server is built here
/// with a SPY render sink standing in for the live registry (there is no window in a headless selftest). Each
/// write case then asserts two things: the scratch store persisted the expected body, and the spy captured the
/// matching `NotesRenderIntent`. That render-side assertion is via the injected seam, not a fake, exactly as
/// the L2 verification contract requires when no live window exists to render into.
///
/// L3 adds the insert + lifecycle/focus routes on top: `/insert_sticky_note` (the dictation seam),
/// `/rename_sticky_note`, `/close_sticky_note`, `/restore_sticky_note`, `/duplicate_sticky_note`, and
/// `/focus_sticky_note`. Each store-affecting route asserts the scratch store mutated as expected (floor
/// persisted / override written / archived to history / restored / duplicated with attachments copied), and —
/// because there is no live window headlessly — asserts the matching `NotesRenderIntent` via the SAME spy seam
/// L2 established (`insertAtCaret` / `rename` / `close` / `restore` / `duplicate` / `focus`) rather than faking
/// a render. `focus` mutates no store state, so it is verified purely through the spy + the route contract.
///
/// L4 adds the attachment routes on top: `/attach_media_to_sticky_note` (image OR video, type inferred from
/// the extension) and `/read_sticky_note_attachments` (pure read). The attach route asserts the scratch store
/// copied a REAL temp image/video file into the note's sidecar (name/type by extension) and — because there is
/// no live window headlessly — asserts the matching `attachmentsChanged` `NotesRenderIntent` via the SAME spy
/// seam, rather than faking a tray render. It also fills a scratch note to the attachment soft cap and asserts
/// the next HTTP attach returns the frozen 409 `attachment_cap` response. The read route asserts the returned
/// name/type/path against the scratch store with no render. Reuses the existing `attachments` outbound bridge
/// msg, so no new wire name.
///
/// The complementary `--notes-probe` (store + bridge contract) stays the store-level verification; this seam
/// owns the HTTP transport contract on top of it.
enum NotesControlSelfTest {

    static func run() -> Bool {
        print("--- notes-http selftest: loopback Sticky Notes control endpoint ---\n")

        let reporter = SelfTestReporter()
        let check = reporter

        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-notes-http-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        // Scratch store, seeded with two notes; "note-beta" is the fixed "active" note for this run.
        let store = StickyNotesStore(root: base.appendingPathComponent("store", isDirectory: true))
        store.saveOpenNote(id: "note-alpha", body: "# Alpha\nfirst body")
        store.saveOpenNote(id: "note-beta", body: "Beta heading\nsecond body")
        let activeId = "note-beta"

        // Spy render sink: there is no live window in a headless selftest, so the L2 write routes push their
        // render intent here instead of into the registry. Reports `.persistedOnly` (the honest headless
        // outcome) and records every intent for the write-route assertions below.
        let spy = RenderSpy()

        // Scratch ephemeral port (preferredPort 0) — can never collide with or bind the real 8766.
        let server = NotesControlServer(store: store,
                                        config: NotesControlServer.Config(preferredPort: 0, scanRange: 1),
                                        activeNoteId: { activeId },
                                        renderSink: { spy.record($0) })
        guard let port = server.start(), port != 0 else {
            check("server binds a scratch loopback port", false, "start() returned no port")
            return finish(reporter)
        }
        defer { server.stop() }
        check("server binds a scratch loopback port (not 8766)", port != NotesControlServer.Config.defaultPort,
              "port=\(port)")

        let client = LoopbackClient(port: port)

        // --- /health -----------------------------------------------------------------------------
        if let (status, obj) = client.getJSON("/health") {
            check("health: 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("health: reports service name", (obj["service"] as? String) == "viddydictate-notes-control")
            check("health: echoes the bound port", (obj["port"] as? Int) == Int(port))
        } else {
            check("health: reachable over loopback HTTP", false, "no response")
            return finish(reporter)
        }

        // --- /list_sticky_notes ------------------------------------------------------------------
        if let (status, obj) = client.getJSON("/list_sticky_notes") {
            let notes = (obj["notes"] as? [[String: Any]]) ?? []
            check("list: 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("list: returns both open notes", notes.count == 2,
                  "count=\(notes.count)")
            let ids = Set(notes.compactMap { $0["id"] as? String })
            check("list: carries both note ids", ids == ["note-alpha", "note-beta"])
            let alpha = notes.first { ($0["id"] as? String) == "note-alpha" }
            let beta = notes.first { ($0["id"] as? String) == "note-beta" }
            check("list: derives the title from the body", (alpha?["title"] as? String) == "Alpha")
            check("list: active flag true for the active note only",
                  (beta?["active"] as? Bool) == true && (alpha?["active"] as? Bool) == false)
        } else {
            check("list: reachable", false)
        }

        // --- /read_sticky_note by id -------------------------------------------------------------
        if let (status, obj) = client.postJSON("/read_sticky_note", ["target": "note-alpha"]) {
            let note = obj["note"] as? [String: Any]
            check("read(id): 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("read(id): returns the full body", (note?["body"] as? String) == "# Alpha\nfirst body")
            check("read(id): returns id + title", (note?["id"] as? String) == "note-alpha"
                  && (note?["title"] as? String) == "Alpha")
        } else {
            check("read(id): reachable", false)
        }

        // --- /read_sticky_note target "open" resolves to the active note -------------------------
        if let (_, obj) = client.postJSON("/read_sticky_note", ["target": "open"]) {
            let note = obj["note"] as? [String: Any]
            check("read(open): resolves to the active note's body",
                  (note?["id"] as? String) == "note-beta"
                  && (note?["body"] as? String) == "Beta heading\nsecond body")
        } else {
            check("read(open): reachable", false)
        }

        // --- unknown target + missing target -----------------------------------------------------
        if let (status, obj) = client.postJSON("/read_sticky_note", ["target": "note-nope"]) {
            check("read(unknown): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("read(unknown): reachable", false)
        }
        if let (status, obj) = client.postJSON("/read_sticky_note", [:]) {
            check("read(no target): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("read(no target): reachable", false)
        }

        // --- create_sticky_note (L2 content write) -----------------------------------------------
        let createBody = "milk\neggs"
        if let (status, obj) = client.postJSON("/create_sticky_note",
                                               ["title": "Grocery", "content": createBody]) {
            let newId = obj["note_id"] as? String
            check("create: 200 + ok + returns a note id",
                  status == 200 && (obj["ok"] as? Bool) == true && (newId?.hasPrefix("note-") ?? false),
                  "id=\(newId ?? "nil")")
            check("create: chars echoes the content length", (obj["chars"] as? Int) == createBody.count)
            check("create: note_title reflects the title override", (obj["note_title"] as? String) == "Grocery")
            check("create: render reports persisted_only (no live window in selftest)",
                  (obj["render"] as? String) == "persisted_only")
            if let newId = newId {
                let persisted = store.openNotes().first { $0.id == newId }
                check("create: body persisted to the scratch store", persisted?.body == createBody)
                check("create: title override persisted", persisted?.title == "Grocery")
                check("create: pushed an externalCreate render intent to the seam",
                      spy.contains(.create(id: newId, body: createBody, title: "Grocery")))
            }
        } else {
            check("create: reachable", false)
        }

        // --- create with a missing/empty content is rejected -------------------------------------
        if let (status, obj) = client.postJSON("/create_sticky_note", ["title": "x"]) {
            check("create(no content): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("create(no content): reachable", false)
        }

        // --- update_sticky_note set (L2 locked contract) -----------------------------------------
        if let (status, obj) = client.postJSON("/update_sticky_note",
                                               ["target": "note-alpha", "mode": "set", "content": "rewritten"]) {
            check("update(set): 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("update(set): store body replaced",
                  store.openNotes().first { $0.id == "note-alpha" }?.body == "rewritten")
            check("update(set): note_title recomputed from the new body",
                  (obj["note_title"] as? String) == "rewritten")
            check("update(set): pushed a setBody render intent for the whole body",
                  spy.contains(.setBody(id: "note-alpha", body: "rewritten")))
        } else {
            check("update(set): reachable", false)
        }

        // --- update_sticky_note append (joins onto a fresh line) ---------------------------------
        if let (status, obj) = client.postJSON("/update_sticky_note",
                                               ["target": "note-alpha", "mode": "append", "content": "line2"]) {
            check("update(append): 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("update(append): body is old + newline + content",
                  store.openNotes().first { $0.id == "note-alpha" }?.body == "rewritten\nline2")
            check("update(append): render intent carries the full post-append body",
                  spy.contains(.setBody(id: "note-alpha", body: "rewritten\nline2")))
        } else {
            check("update(append): reachable", false)
        }

        // --- update target "open" resolves + appends to the active note --------------------------
        if let (status, obj) = client.postJSON("/update_sticky_note",
                                               ["target": "open", "mode": "append", "content": "appended"]) {
            check("update(open, append): 200 + ok + resolves the active note",
                  status == 200 && (obj["note_id"] as? String) == activeId)
            check("update(open, append): active note body appended",
                  store.openNotes().first { $0.id == activeId }?.body == "Beta heading\nsecond body\nappended")
        } else {
            check("update(open, append): reachable", false)
        }

        // --- update error surface: unknown target, missing target, bad mode ----------------------
        if let (status, obj) = client.postJSON("/update_sticky_note",
                                               ["target": "note-nope", "mode": "set", "content": "x"]) {
            check("update(unknown target): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("update(unknown target): reachable", false)
        }
        if let (status, obj) = client.postJSON("/update_sticky_note", ["mode": "set", "content": "x"]) {
            check("update(no target): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("update(no target): reachable", false)
        }
        if let (status, obj) = client.postJSON("/update_sticky_note",
                                               ["target": "note-alpha", "mode": "prepend", "content": "x"]) {
            check("update(bad mode): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("update(bad mode): reachable", false)
        }

        // --- writes are POST-only ----------------------------------------------------------------
        if let (status, obj) = client.getJSON("/create_sticky_note") {
            check("create(GET): 405 + ok:false", status == 405 && (obj["ok"] as? Bool) == false)
        } else {
            check("create(GET): reachable", false)
        }

        // =========================================================================================
        // L3: insert + lifecycle/focus routes
        // =========================================================================================

        // --- insert_sticky_note: caret-at-end floor persisted + insertAtCaret render intent -------
        store.saveOpenNote(id: "note-gamma", body: "gamma one")
        if let (status, obj) = client.postJSON("/insert_sticky_note", ["target": "note-gamma", "text": " two"]) {
            check("insert: 200 + ok + echoes the note id",
                  status == 200 && (obj["ok"] as? Bool) == true && (obj["note_id"] as? String) == "note-gamma")
            check("insert: chars echoes the inserted text length", (obj["chars"] as? Int) == 4)
            check("insert: store persisted the caret-at-end floor (existing + text)",
                  store.openNotes().first { $0.id == "note-gamma" }?.body == "gamma one two")
            check("insert: pushed an insertAtCaret render intent to the seam",
                  spy.contains(.insertAtCaret(id: "note-gamma", text: " two")))
            check("insert: render reports persisted_only (no live window in selftest)",
                  (obj["render"] as? String) == "persisted_only")
        } else {
            check("insert: reachable", false)
        }
        if let (status, obj) = client.postJSON("/insert_sticky_note", ["target": "note-gamma"]) {
            check("insert(no text): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("insert(no text): reachable", false)
        }
        if let (status, obj) = client.postJSON("/insert_sticky_note", ["target": "note-nope", "text": "x"]) {
            check("insert(unknown target): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("insert(unknown target): reachable", false)
        }
        if let (status, obj) = client.getJSON("/insert_sticky_note") {
            check("insert(GET): 405 + ok:false", status == 405 && (obj["ok"] as? Bool) == false)
        } else {
            check("insert(GET): reachable", false)
        }

        // --- rename_sticky_note: set + clear the title override, relabel render -------------------
        if let (status, obj) = client.postJSON("/rename_sticky_note",
                                               ["target": "note-gamma", "title": "Gamma Note"]) {
            check("rename(set): 200 + ok + note_title is the new title",
                  status == 200 && (obj["ok"] as? Bool) == true && (obj["note_title"] as? String) == "Gamma Note")
            check("rename(set): store override persisted",
                  store.openNotes().first { $0.id == "note-gamma" }?.title == "Gamma Note")
            check("rename(set): pushed a rename render intent",
                  spy.contains(.rename(id: "note-gamma", title: "Gamma Note")))
        } else {
            check("rename(set): reachable", false)
        }
        if let (status, obj) = client.postJSON("/rename_sticky_note", ["target": "note-gamma", "title": ""]) {
            check("rename(clear): 200 + reverts to the body-derived title",
                  status == 200 && (obj["note_title"] as? String) == "gamma one two"
                  && store.openNotes().first { $0.id == "note-gamma" }?.title == "gamma one two")
            check("rename(clear): pushed a rename render intent with an empty title",
                  spy.contains(.rename(id: "note-gamma", title: "")))
        } else {
            check("rename(clear): reachable", false)
        }
        if let (status, obj) = client.postJSON("/rename_sticky_note", ["target": "note-gamma"]) {
            check("rename(no title): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("rename(no title): reachable", false)
        }
        if let (status, obj) = client.postJSON("/rename_sticky_note", ["target": "note-nope", "title": "x"]) {
            check("rename(unknown target): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("rename(unknown target): reachable", false)
        }

        // --- close_sticky_note (soft to history) + restore_sticky_note ----------------------------
        store.saveOpenNote(id: "note-delta", body: "delta body")
        if let (status, obj) = client.postJSON("/close_sticky_note", ["target": "note-delta"]) {
            check("close: 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("close: note removed from open notes",
                  !store.openNotes().contains { $0.id == "note-delta" })
            check("close: note archived to history (recoverable)",
                  store.history(retention: .forever).contains { $0.title == "delta body" })
            check("close: pushed a close render intent", spy.contains(.close(id: "note-delta")))
        } else {
            check("close: reachable", false)
        }
        let deltaHistoryId = store.history(retention: .forever).first { $0.title == "delta body" }?.id
        if let histId = deltaHistoryId,
           let (status, obj) = client.postJSON("/restore_sticky_note", ["target": histId]) {
            let restoredId = obj["note_id"] as? String
            check("restore: 200 + ok + returns the restored note id",
                  status == 200 && (obj["ok"] as? Bool) == true && (restoredId?.hasPrefix("note-") ?? false))
            check("restore: note reopened with its body",
                  restoredId != nil && store.openNotes().first { $0.id == restoredId }?.body == "delta body")
            check("restore: dropped from history",
                  !store.history(retention: .forever).contains { $0.id == histId })
            if let restoredId = restoredId {
                check("restore: pushed a restore render intent",
                      spy.contains(.restore(id: restoredId, body: "delta body", title: "delta body")))
            }
        } else {
            check("restore: reachable (history id present)", false)
        }
        if let (status, obj) = client.postJSON("/restore_sticky_note", ["target": "note-nohistory"]) {
            check("restore(unknown history id): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("restore(unknown): reachable", false)
        }

        // --- duplicate_sticky_note: fresh id, "<title> copy", attachments copied ------------------
        store.saveOpenNote(id: "note-epsilon", body: "# Epsilon\nplan")
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00])
        _ = store.addAttachment(noteId: "note-epsilon", data: pngBytes, suggestedName: "shot.png")
        if let (status, obj) = client.postJSON("/duplicate_sticky_note", ["target": "note-epsilon"]) {
            let dupId = obj["note_id"] as? String
            check("duplicate: 200 + ok + fresh distinct id",
                  status == 200 && (obj["ok"] as? Bool) == true
                  && (dupId?.hasPrefix("note-") ?? false) && dupId != "note-epsilon")
            check("duplicate: note_title is '<source title> copy'",
                  (obj["note_title"] as? String) == "Epsilon copy")
            if let dupId = dupId {
                let dup = store.openNotes().first { $0.id == dupId }
                check("duplicate: copy carries the same body + the copy title",
                      dup?.body == "# Epsilon\nplan" && dup?.title == "Epsilon copy")
                check("duplicate: source note left intact",
                      store.openNotes().first { $0.id == "note-epsilon" }?.body == "# Epsilon\nplan")
                check("duplicate: attachments copied to the duplicate (store.copyAttachments)",
                      store.listAttachments(noteId: dupId).map(\.name) == ["shot.png"])
                check("duplicate: pushed a duplicate render intent",
                      spy.contains(.duplicate(id: dupId, body: "# Epsilon\nplan", title: "Epsilon copy")))
            }
        } else {
            check("duplicate: reachable", false)
        }
        if let (status, obj) = client.postJSON("/duplicate_sticky_note", ["target": "note-nope"]) {
            check("duplicate(unknown target): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("duplicate(unknown): reachable", false)
        }

        // --- focus_sticky_note: render-only (no store mutation) -----------------------------------
        if let (status, obj) = client.postJSON("/focus_sticky_note", ["target": "note-gamma"]) {
            check("focus: 200 + ok + echoes the note id",
                  status == 200 && (obj["ok"] as? Bool) == true && (obj["note_id"] as? String) == "note-gamma")
            check("focus: pushed a focus render intent", spy.contains(.focus(id: "note-gamma")))
            check("focus: render reports persisted_only (no live window)",
                  (obj["render"] as? String) == "persisted_only")
        } else {
            check("focus: reachable", false)
        }
        if let (_, obj) = client.postJSON("/focus_sticky_note", ["target": "open"]) {
            check("focus(open): resolves to the active note", (obj["note_id"] as? String) == activeId)
        } else {
            check("focus(open): reachable", false)
        }
        if let (status, obj) = client.postJSON("/focus_sticky_note", ["target": "note-nope"]) {
            check("focus(unknown target): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("focus(unknown): reachable", false)
        }

        // =========================================================================================
        // L4: attachments
        // =========================================================================================

        // Real scratch media files on disk to attach (the store copies them byte-for-byte into the sidecar).
        // A tiny PNG (image) and a tiny MP4 (video); the fileURL add path types the attachment by extension.
        let imgURL = base.appendingPathComponent("scratch-shot.png")
        let vidURL = base.appendingPathComponent("scratch-clip.mp4")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: imgURL)
        try? Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: vidURL)
        store.saveOpenNote(id: "note-zeta", body: "zeta body")

        // --- attach_media_to_sticky_note: attachment cap is a frozen 409 ------------------------
        store.saveOpenNote(id: "note-cap", body: "cap body")
        for index in 0..<StickyNotesStore.attachmentSoftCap {
            _ = store.addAttachment(noteId: "note-cap", data: pngBytes,
                                    suggestedName: "cap-\(index).png")
        }
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note",
                                               ["target": "note-cap", "path": imgURL.path]) {
            check("attach(cap): 409 + attachment_cap",
                  store.listAttachments(noteId: "note-cap").count == StickyNotesStore.attachmentSoftCap
                  && status == 409 && (obj["ok"] as? Bool) == false
                  && (obj["error"] as? String) == "attachment_cap"
                  && (obj["detail"] as? String)
                    == "note already has \(StickyNotesStore.attachmentSoftCap) attachments"
                  && Set(obj.keys) == ["ok", "error", "detail"])
        } else {
            check("attach(cap): reachable", false)
        }

        // --- attach_media_to_sticky_note: image, by note-id --------------------------------------
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note",
                                               ["target": "note-zeta", "path": imgURL.path]) {
            check("attach(image): 200 + ok + echoes the note id",
                  status == 200 && (obj["ok"] as? Bool) == true && (obj["note_id"] as? String) == "note-zeta")
            let att = obj["attachment"] as? [String: Any]
            check("attach(image): returns name + type(image) + absolute path",
                  (att?["name"] as? String) == "scratch-shot.png" && (att?["type"] as? String) == "image"
                  && ((att?["path"] as? String)?.hasSuffix("scratch-shot.png") ?? false))
            check("attach(image): store copied the file into the sidecar",
                  store.listAttachments(noteId: "note-zeta").map(\.name) == ["scratch-shot.png"])
            check("attach(image): the sidecar file exists on disk",
                  store.listAttachments(noteId: "note-zeta").first.map { fm.fileExists(atPath: $0.url.path) } == true)
            check("attach(image): pushed an attachmentsChanged render intent to the seam",
                  spy.contains(.attachmentsChanged(id: "note-zeta")))
            check("attach(image): render reports persisted_only (no live window in selftest)",
                  (obj["render"] as? String) == "persisted_only")
        } else {
            check("attach(image): reachable", false)
        }

        // --- attach_media_to_sticky_note: video, target "open" resolves the active note ----------
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note",
                                               ["target": "open", "path": vidURL.path]) {
            check("attach(video, open): 200 + resolves the active note",
                  status == 200 && (obj["note_id"] as? String) == activeId)
            let att = obj["attachment"] as? [String: Any]
            check("attach(video, open): type inferred as video from the extension",
                  (att?["type"] as? String) == "video" && (att?["name"] as? String) == "scratch-clip.mp4")
            check("attach(video, open): store copied the video into the active note's sidecar",
                  store.listAttachments(noteId: activeId).map(\.name) == ["scratch-clip.mp4"])
        } else {
            check("attach(video, open): reachable", false)
        }

        // --- attach error surfaces ---------------------------------------------------------------
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note", ["target": "note-zeta"]) {
            check("attach(no path): 400 + ok:false", status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("attach(no path): reachable", false)
        }
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note",
                                               ["target": "note-nope", "path": imgURL.path]) {
            check("attach(unknown target): 404 + ok:false", status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("attach(unknown target): reachable", false)
        }
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note",
                                               ["target": "note-zeta",
                                                "path": base.appendingPathComponent("ghost.png").path]) {
            check("attach(missing file): 404 + file_not_found",
                  status == 404 && (obj["error"] as? String) == "file_not_found")
        } else {
            check("attach(missing file): reachable", false)
        }
        // A non-media file is rejected by the store's media-only rule (415).
        let txtURL = base.appendingPathComponent("notes.txt")
        try? Data("hi".utf8).write(to: txtURL)
        if let (status, obj) = client.postJSON("/attach_media_to_sticky_note",
                                               ["target": "note-zeta", "path": txtURL.path]) {
            check("attach(non-media): 415 + not_media",
                  status == 415 && (obj["error"] as? String) == "not_media")
        } else {
            check("attach(non-media): reachable", false)
        }
        if let (status, obj) = client.getJSON("/attach_media_to_sticky_note") {
            check("attach(GET): 405 + ok:false", status == 405 && (obj["ok"] as? Bool) == false)
        } else {
            check("attach(GET): reachable", false)
        }

        // --- read_sticky_note_attachments: pure read ---------------------------------------------
        if let (status, obj) = client.postJSON("/read_sticky_note_attachments", ["target": "note-zeta"]) {
            let atts = (obj["attachments"] as? [[String: Any]]) ?? []
            check("read_attachments: 200 + ok", status == 200 && (obj["ok"] as? Bool) == true)
            check("read_attachments: lists the attached name/type/path",
                  atts.count == 1 && (atts.first?["name"] as? String) == "scratch-shot.png"
                  && (atts.first?["type"] as? String) == "image"
                  && ((atts.first?["path"] as? String)?.hasSuffix("scratch-shot.png") ?? false))
        } else {
            check("read_attachments: reachable", false)
        }
        // A note with no attachments returns an empty list (still ok:true), and read never renders.
        if let (status, obj) = client.postJSON("/read_sticky_note_attachments", ["target": "note-gamma"]) {
            check("read_attachments(none): 200 + empty list",
                  status == 200 && ((obj["attachments"] as? [[String: Any]])?.isEmpty ?? false))
        } else {
            check("read_attachments(none): reachable", false)
        }
        if let (status, obj) = client.postJSON("/read_sticky_note_attachments", ["target": "note-nope"]) {
            check("read_attachments(unknown target): 404 + ok:false",
                  status == 404 && (obj["ok"] as? Bool) == false)
        } else {
            check("read_attachments(unknown): reachable", false)
        }
        if let (status, obj) = client.postJSON("/read_sticky_note_attachments", [:]) {
            check("read_attachments(no target): 400 + ok:false",
                  status == 400 && (obj["ok"] as? Bool) == false)
        } else {
            check("read_attachments(no target): reachable", false)
        }

        return finish(reporter)
    }

    private static func finish(_ reporter: SelfTestReporter) -> Bool {
        print("\n=== notes-http-selftest RESULT ===")
        print(reporter.summaryLine(prefix: "[notes-http-selftest]"))
        return reporter.passed
    }
}

/// Records the render intents the L2 write routes push, standing in for the live `NotesWindowRegistry` in a
/// headless selftest. The sink is called on the server's background handler thread, so the recorded list is
/// guarded by a lock; the write-route assertions read it after the HTTP round-trip has fully returned (the
/// response is written only after the sink is called), so a captured intent is always visible by then.
private final class RenderSpy {
    private let lock = NSLock()
    private var intents: [NotesRenderIntent] = []

    func record(_ intent: NotesRenderIntent) -> NotesRenderOutcome {
        lock.lock(); intents.append(intent); lock.unlock()
        return .persistedOnly   // no live window exists in the selftest
    }

    func contains(_ intent: NotesRenderIntent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intents.contains(intent)
    }
}

/// Tiny synchronous loopback HTTP client for the selftest (real round-trips, not an in-process call).
private struct LoopbackClient {
    let port: UInt16

    func getJSON(_ path: String) -> (Int, [String: Any])? {
        request(path, method: "GET", body: nil)
    }

    func postJSON(_ path: String, _ payload: [String: Any]) -> (Int, [String: Any])? {
        let body = try? JSONSerialization.data(withJSONObject: payload)
        return request(path, method: "POST", body: body)
    }

    private func request(_ path: String, method: String, body: Data?) -> (Int, [String: Any])? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 5
        if let body = body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, [String: Any])? = nil
        let task = URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            out = (http.statusCode, obj)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 8)
        return out
    }
}
