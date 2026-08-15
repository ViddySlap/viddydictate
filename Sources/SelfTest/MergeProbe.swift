import Foundation

/// Stage 2 ship gate. Pure base/mine/theirs fixtures pin line/block diff3 behavior, then synthetic store
/// fixtures prove the real fingerprint-gated autosave path writes clean merges and preserves Stage 1 fallback.
/// No production vault, note, backup, or registry is read.
enum MergeProbe {
    static func run() -> Bool {
        print("--- files mode merge scratch probe ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        do {
            try runFixtures(root: root, fileManager: fm, reporter: reporter)
        } catch {
            reporter.record("scratch merge fixtures complete", false, String(describing: error))
        }

        print(reporter.summaryLine(prefix: "[merge-probe]"))
        return reporter.passed
    }

    private static func runFixtures(
        root: URL, fileManager fm: FileManager, reporter: SelfTestReporter
    ) throws {
        let canonicalBase = """
        # Files mode

        ## Plan
        Build the safe editor.

        ## Status
        Draft.

        ## Log
        - 2026-07-16 Started.

        """
        let canonicalMine = canonicalBase.replacingOccurrences(of: "Draft.", with: "Ready for review.")
        let canonicalTheirs = canonicalBase + "- 2026-07-17 Agent appended the gate result.\n"
        let canonicalMerged = canonicalMine + "- 2026-07-17 Agent appended the gate result.\n"

        reporter.record("MERGE: agent Log append + buffer edit in another section merges without prompt",
                        MarkdownDiff3.merge(
                            base: canonicalBase, mine: canonicalMine, theirs: canonicalTheirs)
                            == .merged(canonicalMerged))

        let lineBase = "alpha\nbeta\ngamma\n"
        reporter.record("different lines in one markdown block merge cleanly",
                        MarkdownDiff3.merge(
                            base: lineBase,
                            mine: "ALPHA\nbeta\ngamma\n",
                            theirs: "alpha\nbeta\nGAMMA\n")
                            == .merged("ALPHA\nbeta\nGAMMA\n"))

        reporter.record("an insertion at a changed block boundary stays non-overlapping",
                        MarkdownDiff3.merge(
                            base: "# A\nbody\n# B\n",
                            mine: "# A\nbody mine\n# B\n",
                            theirs: "# A\ncontext\nbody\n# B\n")
                            == .merged("# A\ncontext\nbody mine\n# B\n"))

        reporter.record("the same line edit made by both sides is applied once",
                        MarkdownDiff3.merge(
                            base: "# Status\nDraft\n",
                            mine: "# Status\nReady\n",
                            theirs: "# Status\nReady\n")
                            == .merged("# Status\nReady\n"))

        reporter.record("true same-line replacement falls back to detect-and-choose",
                        MarkdownDiff3.merge(
                            base: "Status: draft\n",
                            mine: "Status: mine\n",
                            theirs: "Status: agent\n") == .conflict)
        reporter.record("separate word edits on one source line still conflict (never fixed word chunks)",
                        MarkdownDiff3.merge(
                            base: "The quick brown fox.\n",
                            mine: "A quick brown fox.\n",
                            theirs: "The quick brown dog.\n") == .conflict)

        let files = root.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("obsidian.json")
        try JSONSerialization.data(withJSONObject: ["vaults": [:]]).write(to: registry)
        let classifier = PathClassifier(deniedRoots: [], obsidianConfigurationURL: registry)
        func makeStore(_ name: String) -> StickyNotesStore {
            StickyNotesStore(
                root: root.appendingPathComponent(name, isDirectory: true),
                pathClassifier: classifier)
        }
        func makeFile(_ name: String, body: String) throws -> URL {
            let url = files.appendingPathComponent(name)
            try Data(body.utf8).write(to: url, options: .atomic)
            return url
        }
        func writeAgent(_ body: String, to url: URL) throws {
            try Data(body.utf8).write(to: url, options: .atomic)
        }
        func readBody(_ url: URL) throws -> String {
            try String(contentsOf: url, encoding: .utf8)
        }

        // Canonical real-path case: the timer sees a dirty section edit plus an agent Log append. The store
        // writes the merged file, returns a reload (not a conflict), and advances the base only on UI ack.
        let canonicalURL = try makeFile("canonical.md", body: canonicalBase)
        let canonicalStore = makeStore("support-canonical")
        let canonicalOpen = try canonicalStore.openFileBackedNote(at: canonicalURL)
        canonicalStore.observeFileBackedBuffer(id: canonicalOpen.note.id, body: canonicalMine)
        try writeAgent(canonicalTheirs, to: canonicalURL)
        let canonicalResult = canonicalStore.syncFileBackedNote(
            id: canonicalOpen.note.id, body: canonicalMine)
        reporter.record("MERGE-PROBE: real autosave path writes the canonical clean merge with no conflict",
                        canonicalResult == .merged(body: canonicalMerged)
                            && (try? readBody(canonicalURL)) == canonicalMerged)
        // Race the conditional reload with one more key on the line the user had already changed. Relative to the
        // editor version that requested the first merge, that key and the agent Log append remain disjoint.
        let racingMine = canonicalMine.replacingOccurrences(
            of: "Ready for review.", with: "Ready for review!")
        let racingMerged = canonicalMerged.replacingOccurrences(
            of: "Ready for review.", with: "Ready for review!")
        canonicalStore.observeFileBackedBuffer(id: canonicalOpen.note.id, body: racingMine)
        let racingResult = canonicalStore.syncFileBackedNote(
            id: canonicalOpen.note.id, body: racingMine)
        reporter.record("a keystroke racing the merge re-merges from the editor version without a false prompt",
                        racingResult == .merged(body: racingMerged)
                            && (try? readBody(canonicalURL)) == racingMerged)

        let canonicalAck = canonicalStore.acceptFileBackedReload(
            id: canonicalOpen.note.id, body: racingMerged)
        reporter.record("merged bytes become the next base only after the editor applies them",
                        canonicalAck == .unchanged(body: racingMerged)
                            && canonicalStore.openNotes().first { $0.id == canonicalOpen.note.id }?.body
                                == racingMerged)

        // A second merge after acknowledgement proves the retained snapshot advanced to the bytes last loaded.
        let secondMine = racingMerged.replacingOccurrences(
            of: "Build the safe editor.", with: "Ship the safe editor.")
        let secondTheirs = racingMerged + "- 2026-07-17 Agent appended review evidence.\n"
        let secondMerged = secondMine + "- 2026-07-17 Agent appended review evidence.\n"
        canonicalStore.observeFileBackedBuffer(id: canonicalOpen.note.id, body: secondMine)
        try writeAgent(secondTheirs, to: canonicalURL)
        let secondResult = canonicalStore.syncFileBackedNote(
            id: canonicalOpen.note.id, body: secondMine)
        reporter.record("the acknowledged merge is retained as the base for the next three-way merge",
                        secondResult == .merged(body: secondMerged)
                            && (try? readBody(canonicalURL)) == secondMerged)

        // True overlap still returns the exact Stage 1 conflict object and leaves the agent's disk bytes alone.
        let overlapURL = try makeFile("overlap.md", body: "Status: draft\n")
        let overlapStore = makeStore("support-overlap")
        let overlapOpen = try overlapStore.openFileBackedNote(at: overlapURL)
        let overlapMine = "Status: mine\n"
        let overlapTheirs = "Status: agent\n"
        overlapStore.observeFileBackedBuffer(id: overlapOpen.note.id, body: overlapMine)
        try writeAgent(overlapTheirs, to: overlapURL)
        let overlapResult = overlapStore.syncFileBackedNote(
            id: overlapOpen.note.id, body: overlapMine)
        let overlapConflict: FileBackedConflict? = {
            if case .conflict(let conflict) = overlapResult { return conflict }
            return nil
        }()
        reporter.record("MERGE-PROBE: only true same-line overlap reaches Stage 1 detect-and-choose",
                        overlapConflict?.mine == overlapMine
                            && overlapConflict?.theirs == overlapTheirs
                            && (try? readBody(overlapURL)) == overlapTheirs)
        let resolved = overlapConflict.map {
            overlapStore.resolveFileBackedConflict($0, choice: .takeTheirs)
        }
        reporter.record("same-line fallback retains the existing take-theirs choice path",
                        resolved == .reloaded(body: overlapTheirs)
                            && (try? readBody(overlapURL)) == overlapTheirs)

        reporter.record("probe privacy: every file and registry fixture stays under the synthetic root",
                        classifier.classify(canonicalURL) == .readWriteLoose
                            && classifier.classify(overlapURL) == .readWriteLoose)
    }
}
