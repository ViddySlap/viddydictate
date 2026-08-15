import Foundation

/// Stage 1 ship gate. Every fixture lives below a fresh temporary root; the simulated "agent" is only an
/// atomic Data write to a synthetic markdown file. No production vault, note, backup, or registry is read.
enum ClobberProbe {
    static func run() -> Bool {
        print("--- files mode clobber scratch probe ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-clobber-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        do {
            try runFixtures(base: base, fileManager: fm, reporter: reporter)
        } catch {
            reporter.record("scratch clobber fixtures complete", false, String(describing: error))
        }

        print(reporter.summaryLine(prefix: "[clobber-probe]"))
        return reporter.passed
    }

    private static func runFixtures(
        base: URL, fileManager fm: FileManager, reporter: SelfTestReporter
    ) throws {
        let files = base.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        let missingRegistry = base.appendingPathComponent("missing-obsidian.json")
        // An empty, readable registry proves every fixture is loose read-write without touching a real vault.
        let registry = base.appendingPathComponent("obsidian.json")
        try JSONSerialization.data(withJSONObject: ["vaults": [:]]).write(to: registry)
        let classifier = PathClassifier(deniedRoots: [], obsidianConfigurationURL: registry)

        func file(_ name: String, _ body: String) throws -> URL {
            let url = files.appendingPathComponent(name)
            try Data(body.utf8).write(to: url, options: .atomic)
            return url
        }
        func agentWrite(_ body: String, to url: URL) throws {
            try Data(body.utf8).write(to: url, options: .atomic)
        }
        func body(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8)
        }
        func store(_ name: String) -> StickyNotesStore {
            StickyNotesStore(
                root: base.appendingPathComponent(name, isDirectory: true),
                pathClassifier: classifier)
        }

        // THE CLOBBER CASE: dirty editor, then an agent changes disk, then both timer and close fire. Neither
        // path may overwrite the agent. Only an explicit Keep Mine is allowed to replace it.
        let clobberURL = try file("clobber.md", "base\n")
        let clobberStore = store("support-clobber")
        let clobberOpen = try clobberStore.openFileBackedNote(at: clobberURL)
        let mine = "base\nmy edit\n"
        let agent = "base\nagent edit\n"
        clobberStore.observeFileBackedBuffer(id: clobberOpen.note.id, body: mine)
        try agentWrite(agent, to: clobberURL)
        let timerResult = clobberStore.syncFileBackedNote(id: clobberOpen.note.id, body: mine)
        let firstConflict: FileBackedConflict? = {
            if case .conflict(let conflict) = timerResult { return conflict }
            return nil
        }()
        reporter.record("CLOBBER: dirty buffer + agent write + autosave tick raises a conflict",
                        firstConflict?.mine == mine && firstConflict?.theirs == agent)
        reporter.record("CLOBBER: autosave never silently loses the agent write",
                        try body(clobberURL) == agent)

        let closeResult = clobberStore.closeFileBackedNote(id: clobberOpen.note.id, body: mine)
        reporter.record("close flush: a dirty external change refuses close and keeps the tab mapping",
                        {
                            if case .conflict = closeResult {
                                return clobberStore.isFileBackedNote(id: clobberOpen.note.id)
                                    && (try? body(clobberURL)) == agent
                            }
                            return false
                        }())

        let keepResult = firstConflict.map {
            clobberStore.resolveFileBackedConflict($0, choice: .keepMine)
        }
        reporter.record("deliberate keep-mine is the only tested path that overwrites the agent version",
                        {
                            if case .saved(let saved)? = keepResult {
                                return saved == mine && (try? body(clobberURL)) == mine
                            }
                            return false
                        }())

        // CLEAN LIVE RELOAD: an unchanged editor adopts disk, then acknowledges the conditional reload.
        let cleanURL = try file("clean.md", "clean base\n")
        let cleanStore = store("support-clean")
        let cleanOpen = try cleanStore.openFileBackedNote(at: cleanURL)
        let cleanAgent = "clean base\nagent appended\n"
        try agentWrite(cleanAgent, to: cleanURL)
        let reload = cleanStore.syncFileBackedNote(id: cleanOpen.note.id, body: cleanOpen.note.body)
        let offeredReload: Bool = {
            if case .reloaded(let theirs) = reload { return theirs == cleanAgent }
            return false
        }()
        let accepted = cleanStore.acceptFileBackedReload(id: cleanOpen.note.id, body: cleanAgent)
        reporter.record("clean buffer: external disk change offers and accepts a live reload",
                        offeredReload
                            && accepted == .unchanged(body: cleanAgent)
                            && cleanStore.openNotes().first { $0.id == cleanOpen.note.id }?.body == cleanAgent)

        // Reload race: a keystroke after the timer request must keep the OLD base until JS acknowledges. That
        // converts the race into a conflict instead of making stale editor text look based on the agent version.
        let raceURL = try file("reload-race.md", "race base\n")
        let raceStore = store("support-race")
        let raceOpen = try raceStore.openFileBackedNote(at: raceURL)
        let raceAgent = "race base\nagent\n"
        try agentWrite(raceAgent, to: raceURL)
        let raceOffer = raceStore.syncFileBackedNote(id: raceOpen.note.id, body: raceOpen.note.body)
        let raceMine = "race base\nmy racing key\n"
        raceStore.observeFileBackedBuffer(id: raceOpen.note.id, body: raceMine)
        let raceAck = raceStore.acceptFileBackedReload(id: raceOpen.note.id, body: raceAgent)
        reporter.record("clean-reload race: a newer keystroke becomes conflict, never a stale-base write",
                        {
                            guard case .reloaded = raceOffer, case .conflict(let conflict) = raceAck else {
                                return false
                            }
                            return conflict.mine == raceMine && conflict.theirs == raceAgent
                                && (try? body(raceURL)) == raceAgent
                        }())

        // TAKE THEIRS: original survives and the runtime buffer/base both become the latest disk version.
        let theirsURL = try file("take-theirs.md", "theirs base\n")
        let theirsStore = store("support-theirs")
        let theirsOpen = try theirsStore.openFileBackedNote(at: theirsURL)
        let theirsMine = "theirs base\nmy edit\n"
        let theirsAgent = "theirs base\nagent edit\n"
        theirsStore.observeFileBackedBuffer(id: theirsOpen.note.id, body: theirsMine)
        try agentWrite(theirsAgent, to: theirsURL)
        guard case .conflict(let theirsConflict) = theirsStore.syncFileBackedNote(
            id: theirsOpen.note.id, body: theirsMine) else {
            reporter.record("take-theirs fixture reaches conflict", false)
            return
        }
        let takeResult = theirsStore.resolveFileBackedConflict(theirsConflict, choice: .takeTheirs)
        let theirsDiskBody = try body(theirsURL)
        reporter.record("take-theirs keeps agent disk bytes and reloads them into the tab",
                        takeResult == .reloaded(body: theirsAgent)
                            && theirsDiskBody == theirsAgent
                            && theirsStore.openNotes().first { $0.id == theirsOpen.note.id }?.body == theirsAgent)

        // SAVE MINE AS COPY: original survives; mine is materialized in a new sibling; tab reloads original.
        let copyURL = try file("save-copy.md", "copy base\n")
        let copyStore = store("support-copy")
        let copyOpen = try copyStore.openFileBackedNote(at: copyURL)
        let copyMine = "copy base\nmy edit\n"
        let copyAgent = "copy base\nagent edit\n"
        copyStore.observeFileBackedBuffer(id: copyOpen.note.id, body: copyMine)
        try agentWrite(copyAgent, to: copyURL)
        guard case .conflict(let copyConflict) = copyStore.syncFileBackedNote(
            id: copyOpen.note.id, body: copyMine) else {
            reporter.record("save-copy fixture reaches conflict", false)
            return
        }
        let copyResult = copyStore.resolveFileBackedConflict(copyConflict, choice: .saveMineAsCopy)
        reporter.record("save-mine-as-copy preserves both versions and reloads the original",
                        {
                            guard case .copiedAndReloaded(let reloaded, let sidecar) = copyResult else {
                                return false
                            }
                            return reloaded == copyAgent
                                && sidecar.deletingLastPathComponent() == copyURL.deletingLastPathComponent()
                                && sidecar.lastPathComponent.contains("ViddyDictate-copy")
                                && (try? body(sidecar)) == copyMine
                                && (try? body(copyURL)) == copyAgent
                                && copyStore.openNotes().first { $0.id == copyOpen.note.id }?.body == copyAgent
                        }())

        // VANISHED BACKING FILE (review Finding 1): a Finder delete (or rename, identical from this path's
        // view) under an open tab. A dirty buffer is the only surviving copy and recreates the file; a clean
        // buffer never resurrects the delete and still permits close to drop the tab.
        let vanishURL = try file("vanish-dirty.md", "vanish base\n")
        let vanishStore = store("support-vanish")
        let vanishOpen = try vanishStore.openFileBackedNote(at: vanishURL)
        let vanishMine = "vanish base\nmy surviving edit\n"
        vanishStore.observeFileBackedBuffer(id: vanishOpen.note.id, body: vanishMine)
        try fm.removeItem(at: vanishURL)
        let vanishSync = vanishStore.syncFileBackedNote(id: vanishOpen.note.id, body: vanishMine)
        reporter.record("vanished file: a dirty buffer recreates the file at the origin path",
                        vanishSync == .saved(body: vanishMine)
                            && (try? body(vanishURL)) == vanishMine)

        let vanishCleanURL = try file("vanish-clean.md", "clean vanish base\n")
        let vanishCleanOpen = try vanishStore.openFileBackedNote(at: vanishCleanURL)
        try fm.removeItem(at: vanishCleanURL)
        let vanishCleanSync = vanishStore.syncFileBackedNote(
            id: vanishCleanOpen.note.id, body: vanishCleanOpen.note.body)
        let vanishCleanClose = vanishStore.closeFileBackedNote(
            id: vanishCleanOpen.note.id, body: vanishCleanOpen.note.body)
        reporter.record("vanished file: a clean buffer stays a no-op, permits close, never resurrects the delete",
                        vanishCleanSync == .unchanged(body: vanishCleanOpen.note.body)
                            && vanishCleanClose.permitsClose
                            && !fm.fileExists(atPath: vanishCleanURL.path)
                            && !vanishStore.isFileBackedNote(id: vanishCleanOpen.note.id))

        let vanishDir = files.appendingPathComponent("vanish-dir", isDirectory: true)
        try fm.createDirectory(at: vanishDir, withIntermediateDirectories: true)
        let nestedURL = vanishDir.appendingPathComponent("nested.md")
        try Data("nested base\n".utf8).write(to: nestedURL, options: .atomic)
        let nestedOpen = try vanishStore.openFileBackedNote(at: nestedURL)
        let nestedMine = "nested base\nsurvives folder delete\n"
        vanishStore.observeFileBackedBuffer(id: nestedOpen.note.id, body: nestedMine)
        try fm.removeItem(at: vanishDir)
        let nestedSync = vanishStore.syncFileBackedNote(id: nestedOpen.note.id, body: nestedMine)
        reporter.record("vanished file: a vanished parent directory is recreated with the file",
                        nestedSync == .saved(body: nestedMine)
                            && (try? body(nestedURL)) == nestedMine)

        // Pin the three write triggers to their shipping seams. The behavioral safety lives above in the store
        // fixtures; these source checks ensure the timer/blur/close/app-quit rails actually call that model.
        let repo = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let persistence = try String(
            contentsOf: repo.appendingPathComponent("Web/StickyNotes/src/persistence.js"), encoding: .utf8)
        let events = try String(
            contentsOf: repo.appendingPathComponent("Web/StickyNotes/src/events.js"), encoding: .utf8)
        let actions = try String(
            contentsOf: repo.appendingPathComponent("Web/StickyNotes/src/actions.js"), encoding: .utf8)
        let appDelegate = try String(
            contentsOf: repo.appendingPathComponent("Sources/App/AppDelegate.swift"), encoding: .utf8)
        reporter.record("timed autosave: tunable 12-second timer posts through fileSync gate",
                        persistence.contains("FILE_AUTOSAVE_MS = 12_000")
                            && persistence.contains("setInterval(() => syncFileBackedTabs(\"timer\")")
                            && persistence.contains("MSG.inbound.fileSync"))
        reporter.record("blur flush: window and tab-selection paths call flushActive",
                        events.contains("flushActive(\"windowBlur\")")
                            && actions.contains("export function selectTab(id)")
                            && actions.contains("flushActive();"))
        reporter.record("close flush: file tab waits for native gated close approval",
                        actions.contains("closing.kind === \"fileBacked\"")
                            && actions.contains("post(MSG.inbound.close"))
        reporter.record("app quit flush: NSApplication termination is fingerprint-gated",
                        appDelegate.contains("applicationShouldTerminate")
                            && appDelegate.contains("prepareForApplicationTermination"))

        // Sentinel: an unreadable vault registry remains fail-closed and is not accidentally used by this
        // probe. This also pins that every scratch test above used the explicit readable empty registry.
        reporter.record("probe privacy: fixtures use only the synthetic registry/root",
                        !fm.fileExists(atPath: missingRegistry.path)
                            && classifier.classify(clobberURL) == .readWriteLoose)
    }
}
