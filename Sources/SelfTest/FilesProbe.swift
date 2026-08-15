import Foundation

/// Scratch-only Stage 0 proof for file-backed tabs. Every path and vault registry is injected below a fresh
/// temporary root; no production vault, registry, sticky-note store, or backup directory is inspected.
enum FilesProbe {
    static func run() -> Bool {
        print("--- files mode foundation scratch probe ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-files-foundation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        do {
            try runFixtures(base: base, fileManager: fm, reporter: reporter)
        } catch {
            reporter.record("scratch fixture setup completes", false, String(describing: error))
        }

        print(reporter.summaryLine(prefix: "[files-probe]"))
        return reporter.passed
    }

    private static func runFixtures(
        base: URL, fileManager fm: FileManager, reporter: SelfTestReporter
    ) throws {
        let deniedRoot = base.appendingPathComponent("synthetic-denied", isDirectory: true)
        let vaultRoot = base.appendingPathComponent("registered-vault", isDirectory: true)
        let looseRoot = base.appendingPathComponent("loose", isDirectory: true)
        let supportRoot = base.appendingPathComponent("support", isDirectory: true)
        for directory in [deniedRoot, vaultRoot, looseRoot, supportRoot] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ name: String, in directory: URL, body: String = "fixture body\n") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(body.utf8).write(to: url)
            return url
        }

        let deniedFile = try write("denied.md", in: deniedRoot)
        let vaultFile = try write("vault-note.md", in: vaultRoot, body: "vault body\n")
        let looseFile = try write("loose-note.md", in: looseRoot, body: "loose body sentinel\n")
        let configurationURL = base.appendingPathComponent("obsidian.json")
        try JSONSerialization.data(withJSONObject: [
            "vaults": ["fixture": ["path": vaultRoot.path, "open": true]],
        ]).write(to: configurationURL)
        let classifier = PathClassifier(
            deniedRoots: [deniedRoot], obsidianConfigurationURL: configurationURL)

        reporter.record("classification: denied-root arm refuses",
                        classifier.classify(deniedFile) == .refuseDeniedRoot)
        reporter.record("classification: registered vault arm is identified",
                        classifier.classify(vaultFile) == .readOnlyVault)
        reporter.record("classification: loose arm is identified",
                        classifier.classify(looseFile) == .readWriteLoose)

        let missingClassifier = PathClassifier(
            deniedRoots: [deniedRoot],
            obsidianConfigurationURL: base.appendingPathComponent("missing-obsidian.json"))
        reporter.record("classification: unreadable registry fails closed",
                        missingClassifier.classify(looseFile) == .readOnlyFailClosed)
        let malformedURL = base.appendingPathComponent("malformed-obsidian.json")
        try Data("{not-json".utf8).write(to: malformedURL)
        let malformedClassifier = PathClassifier(
            deniedRoots: [deniedRoot], obsidianConfigurationURL: malformedURL)
        reporter.record("classification: malformed registry fails closed",
                        malformedClassifier.classify(looseFile) == .readOnlyFailClosed)

        let store = StickyNotesStore(root: supportRoot, pathClassifier: classifier)
        let opened = try store.openFileBackedNote(at: looseFile)
        reporter.record("open: loose markdown becomes a file-backed tab with filename title",
                        opened.note.kind == .fileBacked
                            && opened.note.title == "loose-note.md"
                            && opened.note.body == "loose body sentinel\n"
                            && opened.note.filePath == looseFile.path
                            && opened.note.canRename
                            && opened.note.canEdit)
        reporter.record("open: file-backed id uses the opaque second id shape",
                        opened.note.id.hasPrefix("file-") && !opened.note.id.contains("loose-note"))
        reporter.record("Finder reveal: file-backed tab resolves its real origin",
                        store.revealableFileURL(id: opened.note.id) == looseFile)
        store.saveOpenNote(id: "note-reveal", body: "scratch reveal fixture\n")
        let scratchReveal = supportRoot.appendingPathComponent("note-reveal.md")
        reporter.record("Finder reveal: scratch tab resolves its store-owned markdown file",
                        store.revealableFileURL(id: "note-reveal") == scratchReveal)
        try fm.removeItem(at: scratchReveal)
        reporter.record("Finder reveal: missing and invalid backing files resolve to nil",
                        store.revealableFileURL(id: "note-reveal") == nil
                            && store.revealableFileURL(id: "not-a-note") == nil)
        let secondOpen = try store.openFileBackedNote(at: looseFile)
        reporter.record("open: double-open returns the existing tab instead of a second buffer",
                        secondOpen.focusedExisting && secondOpen.note.id == opened.note.id
                            && store.openNotes().filter { $0.filePath == looseFile.path }.count == 1)

        store.saveWindows([
            WindowMembership(id: "window-primary", noteIds: [opened.note.id],
                             activeId: opened.note.id, frame: nil),
        ])
        let restoredStore = StickyNotesStore(root: supportRoot, pathClassifier: classifier)
        let restoredWindows = restoredStore.loadWindows()
        let restoredNotes = restoredStore.openNotes()
        reporter.record("restore: file id survives windows.json + origin side table",
                        restoredWindows.first?.noteIds == [opened.note.id]
                            && restoredNotes.first(where: { $0.id == opened.note.id })?.filePath == looseFile.path)
        reporter.record("restore: resolveActiveId accepts the file-backed second id shape",
                        NotesTransientTabs.resolveActiveId(
                            lastActive: opened.note.id, noteIds: restoredNotes.map(\.id)) == opened.note.id)

        store.rewriteAggregate(tabOrder: [opened.note.id], activeId: opened.note.id)
        let aggregateURL = supportRoot.appendingPathComponent("_open-notes.md")
        let aggregate = try String(contentsOf: aggregateURL, encoding: .utf8)
        reporter.record("aggregate: file-backed tab emits the absolute File pointer",
                        aggregate.contains("## loose-note.md (active)\n\n**File:** \(looseFile.path)\n"))
        reporter.record("aggregate: file-backed body is never inlined",
                        !aggregate.contains("loose body sentinel"))

        store.saveOpenNote(id: opened.note.id, body: "")
        store.purgeExpiredHistory(retention: .oneDay)
        let afterEmptySave = try Data(contentsOf: looseFile)
        reporter.record("retention: empty save writes an empty real file without evaporating it",
                        fm.fileExists(atPath: looseFile.path)
                            && afterEmptySave.isEmpty)
        store.closeNote(id: opened.note.id, body: "")
        let afterClose = try Data(contentsOf: looseFile)
        reporter.record("retention: close drops only the tab mapping, never archives the real file",
                        fm.fileExists(atPath: looseFile.path)
                            && afterClose.isEmpty
                            && !store.openNotes().contains { $0.id == opened.note.id }
                            && store.history(retention: .forever).isEmpty)

        let renameSource = try write("rename-source.md", in: looseRoot, body: "rename bytes\n")
        let renameOpen = try store.openFileBackedNote(at: renameSource)
        let renameResult = store.renameFileBackedNote(id: renameOpen.note.id, stem: "renamed.md")
        let renamedURL = looseRoot.appendingPathComponent("renamed.md")
        let renamedNote: StickyNoteWire? = {
            if case .renamed(let note) = renameResult { return note }
            return nil
        }()
        let renamedBody = try? String(contentsOf: renamedURL, encoding: .utf8)
        reporter.record("rename: loose move preserves exactly one .md extension and the bytes",
                        renamedNote?.title == "renamed.md"
                            && renamedNote?.filePath == renamedURL.path
                            && !fm.fileExists(atPath: renameSource.path)
                            && renamedBody == "rename bytes\n")
        reporter.record("rename: note-titles.json remains scratch-only",
                        !fm.fileExists(atPath: supportRoot.appendingPathComponent("note-titles.json").path))
        store.rewriteAggregate(tabOrder: [renameOpen.note.id], activeId: renameOpen.note.id)
        let renamedAggregate = try String(contentsOf: aggregateURL, encoding: .utf8)
        reporter.record("rename: aggregate pointer follows the moved file",
                        renamedAggregate.contains("**File:** \(renamedURL.path)")
                            && !renamedAggregate.contains("**File:** \(renameSource.path)"))

        let collision = try write("collision.md", in: looseRoot, body: "collision target\n")
        let collisionBody = try String(contentsOf: collision, encoding: .utf8)
        reporter.record("rename: collision refuses without overwriting or moving",
                        store.renameFileBackedNote(
                            id: renameOpen.note.id, stem: collision.deletingPathExtension().lastPathComponent)
                            == .collision
                            && fm.fileExists(atPath: renamedURL.path)
                            && collisionBody == "collision target\n")
        reporter.record("rename: illegal path characters are refused",
                        store.renameFileBackedNote(id: renameOpen.note.id, stem: "bad/name") == .illegalName)

        let vaultOpen = try store.openFileBackedNote(at: vaultFile)
        reporter.record("rename: vault tab is locked while remaining editable",
                        !vaultOpen.note.canRename && vaultOpen.note.canEdit
                            && store.renameFileBackedNote(id: vaultOpen.note.id, stem: "moved-vault") == .locked
                            && fm.fileExists(atPath: vaultFile.path))

        // Review R4: decision 3's headline requirement. A vault-tier edit must genuinely reach the real
        // vault file through the gated sync, not just be permitted in the wire flags.
        let vaultEdited = "vault body\nvault write sentinel\n"
        reporter.record("store: a vault-tier edit is genuinely written to the vault file",
                        store.syncFileBackedNote(id: vaultOpen.note.id, body: vaultEdited)
                            == .saved(body: vaultEdited)
                            && (try? String(contentsOf: vaultFile, encoding: .utf8)) == vaultEdited)

        // Review R1-R3: the enforcement point for the denied root is the STORE (spec decision 9 makes the
        // app enforce per-path), so pin it there, not only at the classifier.
        let deniedOpen = try? store.openFileBackedNote(at: deniedFile)
        let originsRaw = (try? String(
            contentsOf: supportRoot.appendingPathComponent("file-origins.json"), encoding: .utf8)) ?? ""
        reporter.record("store: denied-root open is refused at the store, not just the classifier",
                        deniedOpen == nil)
        reporter.record("store: a refused open leaves no tab and no origin mapping",
                        !store.openNotes().contains { $0.filePath == deniedFile.path }
                            && !originsRaw.contains(deniedFile.lastPathComponent))
        let overlapURL = base.appendingPathComponent("overlap-obsidian.json")
        try JSONSerialization.data(withJSONObject: [
            "vaults": ["overlap": ["path": deniedRoot.path, "open": true]],
        ]).write(to: overlapURL)
        let overlapClassifier = PathClassifier(
            deniedRoots: [deniedRoot], obsidianConfigurationURL: overlapURL)
        let overlapStore = StickyNotesStore(
            root: base.appendingPathComponent("overlap-support", isDirectory: true),
            pathClassifier: overlapClassifier)
        reporter.record("store: the denied root beats a registered-vault claim on the same path",
                        overlapClassifier.classify(deniedFile) == .refuseDeniedRoot
                            && (try? overlapStore.openFileBackedNote(at: deniedFile)) == nil)

        let failClosedRoot = base.appendingPathComponent("fail-closed-support", isDirectory: true)
        let failClosedStore = StickyNotesStore(root: failClosedRoot, pathClassifier: missingClassifier)
        let failClosedOpen = try failClosedStore.openFileBackedNote(at: renamedURL)
        reporter.record("fail-closed tab is readable but editing and rename are locked",
                        failClosedOpen.note.kind == .fileBacked
                            && !failClosedOpen.note.canEdit && !failClosedOpen.note.canRename
                            && failClosedStore.renameFileBackedNote(
                                id: failClosedOpen.note.id, stem: "must-not-move") == .locked)
        reporter.record("store: fail-closed tier refuses the write and leaves disk untouched",
                        failClosedStore.syncFileBackedNote(
                            id: failClosedOpen.note.id, body: "fail-closed write attempt") == .readOnly
                            && (try? String(contentsOf: renamedURL, encoding: .utf8)) == "rename bytes\n")

        let pasteRoute = NotesPasteRouter.decide(
            NotesPasteDescriptor(fileURLExtensions: ["md"], hasRawImage: false))
        let dropOutcome = NotesDropCoordinator.decide(NotesDropCoordinator.DropQuery(
            endpoint: .zero, sourceWindowId: "window-primary",
            kind: .markdownFiles([renamedURL]), windows: []))
        reporter.record("entry: notes-window markdown paste/drop selects the file-backed arm",
                        pasteRoute == .markdownFiles
                            && dropOutcome == .openMarkdownFiles(
                                windowId: "window-primary", urls: [renamedURL]))

        try probeDocumentRegistration(base: base, reporter: reporter)
    }

    private static func probeDocumentRegistration(base: URL, reporter: SelfTestReporter) throws {
        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let types = plist["CFBundleDocumentTypes"] as? [[String: Any]],
              let markdown = types.first,
              let extensions = markdown["CFBundleTypeExtensions"] as? [String]
        else {
            reporter.record("entry: Info.plist markdown registration is readable", false)
            return
        }
        reporter.record("entry: LSUIElement app registers editable markdown open events",
                        plist["LSUIElement"] as? Bool == true
                            && extensions.contains("md")
                            && markdown["CFBundleTypeRole"] as? String == "Editor")
    }
}
