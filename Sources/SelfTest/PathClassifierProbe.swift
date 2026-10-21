import Foundation

/// Scratch-only verification of the Files router privacy boundary and its open-time backup store.
/// No production Obsidian registry or denied-root path is read or touched.
enum PathClassifierProbe {
    static func run() -> Bool {
        print("--- path classifier scratch probe ---")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-path-classifier-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        do {
            try runFixtures(root: root, fileManager: fm, reporter: reporter)
        } catch {
            reporter.record("scratch fixture setup completes", false, String(describing: error))
        }

        runBackupRetentionRows(root: root, fileManager: fm, reporter: reporter)

        print(reporter.summaryLine(prefix: "[path-classifier-probe]"))
        return reporter.passed
    }

    private static func runFixtures(
        root: URL,
        fileManager fm: FileManager,
        reporter: SelfTestReporter
    ) throws {
        let deniedRoot = root.appendingPathComponent("synthetic-denied", isDirectory: true)
        let vaultRoot = root.appendingPathComponent("registered-vault", isDirectory: true)
        let looseRoot = root.appendingPathComponent("loose", isDirectory: true)
        let adjacentRoot = root.appendingPathComponent("synthetic-denied-neighbor", isDirectory: true)
        for directory in [deniedRoot, vaultRoot, looseRoot, adjacentRoot] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let deniedFile = deniedRoot.appendingPathComponent("synthetic.md")
        let vaultFile = vaultRoot.appendingPathComponent("vault.md")
        let looseFile = looseRoot.appendingPathComponent("loose.md")
        let adjacentFile = adjacentRoot.appendingPathComponent("neighbor.md")
        for file in [deniedFile, vaultFile, looseFile, adjacentFile] {
            try Data("scratch fixture\n".utf8).write(to: file)
        }

        let configurationURL = root.appendingPathComponent("obsidian.json")
        let validConfiguration: [String: Any] = [
            "vaults": ["scratch-vault": ["path": vaultRoot.path, "open": true]],
        ]
        try JSONSerialization.data(withJSONObject: validConfiguration).write(to: configurationURL)
        let classifier = PathClassifier(
            deniedRoots: [deniedRoot], obsidianConfigurationURL: configurationURL)

        reporter.record("denied-root path REFUSES", classifier.classify(deniedFile) == .refuseDeniedRoot)
        reporter.record("registered-vault path is read-only", classifier.classify(vaultFile) == .readOnlyVault)
        reporter.record("outside-vault path is read-write loose", classifier.classify(looseFile) == .readWriteLoose)
        reporter.record("component boundary avoids a deny-prefix false positive",
                        classifier.classify(adjacentFile) == .readWriteLoose)

        // Production deny-list rows: the string checks never touch the filesystem, and the
        // re-rooted checks map the production roots onto this probe's scratch `root`, so nothing
        // under the real home is ever read, listed, or opened.
        let productionDeniedRoots = AppPaths.deniedRoots
        let homePath = NSHomeDirectory()
        reporter.record("private-root: new: production deny list has exactly two roots",
                        productionDeniedRoots.count == 2)
        reporter.record("private-root: guard: production deny list keeps ~/Documents/private first",
                        productionDeniedRoots.first?.path == homePath + "/Documents/private")
        reporter.record("private-root: new: production deny list includes ~/private",
                        productionDeniedRoots.dropFirst().first?.path == homePath + "/private")

        let allProductionRootsReRootable = productionDeniedRoots.allSatisfy { $0.path.hasPrefix(homePath) }
        let reRootedDeniedRoots = productionDeniedRoots.map { entry -> URL in
            guard entry.path.hasPrefix(homePath) else { return entry }
            let suffix = String(entry.path.dropFirst(homePath.count))
            return URL(fileURLWithPath: root.path + suffix, isDirectory: true)
        }

        let privateFixture = root.appendingPathComponent("private", isDirectory: true)
        let documentsPrivateFixture = root.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("private", isDirectory: true)
        let privateNotesFixture = root.appendingPathComponent("private-notes", isDirectory: true)
        for directory in [privateFixture, documentsPrivateFixture, privateNotesFixture] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let privateFixtureFile = privateFixture.appendingPathComponent("x.md")
        let documentsPrivateFixtureFile = documentsPrivateFixture.appendingPathComponent("x.md")
        let privateNotesFixtureFile = privateNotesFixture.appendingPathComponent("x.md")
        for file in [privateFixtureFile, documentsPrivateFixtureFile, privateNotesFixtureFile] {
            try Data("x\n".utf8).write(to: file)
        }

        let reRootedClassifier = PathClassifier(
            deniedRoots: allProductionRootsReRootable ? reRootedDeniedRoots : [],
            obsidianConfigurationURL: configurationURL)
        reporter.record("private-root: new: production deny list, re-rooted into the fixture, REFUSES <fixture>/private/x.md",
                        allProductionRootsReRootable
                            && reRootedClassifier.classify(privateFixtureFile) == .refuseDeniedRoot)
        reporter.record("private-root: guard: re-rooted ~/Documents/private still REFUSES",
                        reRootedClassifier.classify(documentsPrivateFixtureFile) == .refuseDeniedRoot)
        reporter.record("private-root: guard: re-rooted deny list keeps the component boundary",
                        reRootedClassifier.classify(privateNotesFixtureFile) == .readWriteLoose)

        let missingConfiguration = root.appendingPathComponent("missing-obsidian.json")
        let unreadableClassifier = PathClassifier(
            deniedRoots: [deniedRoot], obsidianConfigurationURL: missingConfiguration)
        reporter.record("unreadable obsidian.json fails closed to read-only",
                        unreadableClassifier.classify(looseFile) == .readOnlyFailClosed)

        let malformedConfiguration = root.appendingPathComponent("malformed-obsidian.json")
        try Data("{not-json".utf8).write(to: malformedConfiguration)
        let malformedClassifier = PathClassifier(
            deniedRoots: [deniedRoot], obsidianConfigurationURL: malformedConfiguration)
        reporter.record("malformed obsidian.json fails closed to read-only",
                        malformedClassifier.classify(looseFile) == .readOnlyFailClosed)

        let alias = root.appendingPathComponent("denied-alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: deniedRoot)
        let aliasCandidate = alias.appendingPathComponent(deniedFile.lastPathComponent)
        let aliasClassification = classifier.classification(for: aliasCandidate)
        reporter.record("symlink alias into denied root still REFUSES",
                        aliasClassification.decision == .refuseDeniedRoot
                            && aliasClassification.resolvedURL == deniedFile.standardizedFileURL)

        let dotDotCandidate = URL(
            fileURLWithPath: looseRoot.path + "/../" + deniedRoot.lastPathComponent
                + "/" + deniedFile.lastPathComponent)
        let dotDotClassification = classifier.classification(for: dotDotCandidate)
        reporter.record("dot-dot path into denied root still REFUSES",
                        dotDotClassification.decision == .refuseDeniedRoot
                            && dotDotClassification.resolvedURL == deniedFile.standardizedFileURL)

        let backupDirectory = root.appendingPathComponent("file-backups", isDirectory: true)
        let backupURL = try PathClassifierBackupStore(directory: backupDirectory, fileManager: fm)
            .backup(looseFile, at: Date(timeIntervalSince1970: 1_720_000_000))
        reporter.record("backup-on-open writes only to the injected scratch backup directory",
                        backupURL.deletingLastPathComponent() == backupDirectory)
        reporter.record("backup-on-open preserves the source bytes",
                        try Data(contentsOf: backupURL) == Data(contentsOf: looseFile))
        reporter.record("backup filename is timestamped and retains the original filename",
                        backupURL.lastPathComponent.range(
                            of: #"^\d{8}-\d{6}-\d{3}-[0-9A-F-]+-loose\.md$"#,
                            options: .regularExpression) != nil)
    }

    private static func runBackupRetentionRows(
        root: URL,
        fileManager fm: FileManager,
        reporter: SelfTestReporter
    ) {
        let now = Date(timeIntervalSince1970: 1_720_000_000)

        func newRowDir(_ label: String) throws
            -> (sourceDir: URL, backupDir: URL, store: PathClassifierBackupStore) {
            let dir = root.appendingPathComponent("retention-\(label)-\(UUID().uuidString)", isDirectory: true)
            let sourceDir = dir.appendingPathComponent("src", isDirectory: true)
            let backupDir = dir.appendingPathComponent("backups", isDirectory: true)
            try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            return (sourceDir, backupDir, PathClassifierBackupStore(directory: backupDir, fileManager: fm))
        }

        func sourceFile(in dir: URL, name: String = "note.md", body: String = "scratch\n") throws -> URL {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            try Data(body.utf8).write(to: url)
            return url
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r1")
            let ordinary = try sourceFile(in: sourceDir, name: "notes.md")
            let newlineSource = try sourceFile(in: sourceDir, name: "line\nbreak.md")
            let oldDate = now - 32 * 86_400
            let copyA = try store.backup(ordinary, at: oldDate)
            let copyB = try store.backup(newlineSource, at: oldDate)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a copy 32 days old is removed",
                removed == 2 && !fm.fileExists(atPath: copyA.path) && !fm.fileExists(atPath: copyB.path))
        } catch {
            reporter.record("retention: a copy 32 days old is removed", false, String(describing: error))
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r2")
            let src = try sourceFile(in: sourceDir)
            let copy = try store.backup(src, at: now - 29 * 86_400)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a copy 29 days old is kept",
                removed == 0 && fm.fileExists(atPath: copy.path))
        } catch {
            reporter.record("retention: a copy 29 days old is kept", false, String(describing: error))
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r3")
            let src = try sourceFile(in: sourceDir)
            let age: TimeInterval = 30 * 86_400 + 25 * 3_600
            let copy = try store.backup(src, at: now - age)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a copy 30 days and 25 hours old is kept inside the time zone grace",
                removed == 0 && fm.fileExists(atPath: copy.path))
        } catch {
            reporter.record("retention: a copy 30 days and 25 hours old is kept inside the time zone grace", false, String(describing: error))
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r4")
            let src = try sourceFile(in: sourceDir)
            let age: TimeInterval = 30 * 86_400 + 27 * 3_600
            let copy = try store.backup(src, at: now - age)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a copy 30 days and 27 hours old is removed just past the grace",
                removed == 1 && !fm.fileExists(atPath: copy.path))
        } catch {
            reporter.record("retention: a copy 30 days and 27 hours old is removed just past the grace", false, String(describing: error))
        }

        do {
            let (_, backupDir, store) = try newRowDir("r5")
            let names = [
                "notes.md",
                "20200101-000000-000-not-a-uuid-x.md",
                "20200101-000000-000-01234567-89ab-cdef-0123-456789abcdef-notes.md",
                "20200101-000000-000-01234567-89AB-CDEF-0123-456789ABCDEF-notes.txt",
            ]
            for name in names {
                try Data("x\n".utf8).write(to: backupDir.appendingPathComponent(name))
            }
            let removed = store.pruneExpired(now: now)
            let allSurvive = names.allSatisfy { fm.fileExists(atPath: backupDir.appendingPathComponent($0).path) }
            reporter.record(
                "retention: names that do not carry the backup pattern are never removed",
                removed == 0 && allSurvive)
        } catch {
            reporter.record("retention: names that do not carry the backup pattern are never removed", false, String(describing: error))
        }

        do {
            let (_, backupDir, store) = try newRowDir("r6")
            let folderName = "20200101-000000-000-01234567-89AB-CDEF-0123-456789ABCDEF-old.md"
            let subfolder = backupDir.appendingPathComponent(folderName, isDirectory: true)
            try fm.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let inner = subfolder.appendingPathComponent("20200101-000000-000-01234567-89AB-CDEF-0123-456789ABCDEF-inner.md")
            try Data("x\n".utf8).write(to: inner)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: subfolders and what they hold are never touched",
                removed == 0 && fm.fileExists(atPath: subfolder.path) && fm.fileExists(atPath: inner.path))
        } catch {
            reporter.record("retention: subfolders and what they hold are never touched", false, String(describing: error))
        }

        do {
            let (sourceDir, backupDir, store) = try newRowDir("r7")
            let target = sourceDir.appendingPathComponent("target.md")
            try Data("x\n".utf8).write(to: target)
            let linkName = "20200101-000000-000-01234567-89AB-CDEF-0123-456789ABCDEF-old.md"
            let link = backupDir.appendingPathComponent(linkName)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a symbolic link with an old-pattern name is not followed or removed",
                removed == 0 && fm.fileExists(atPath: target.path) && fm.fileExists(atPath: link.path))
        } catch {
            reporter.record("retention: a symbolic link with an old-pattern name is not followed or removed", false, String(describing: error))
        }

        do {
            let dir = root.appendingPathComponent("retention-r8-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let missingDir = dir.appendingPathComponent("backups", isDirectory: true)
            let store = PathClassifierBackupStore(directory: missingDir, fileManager: fm)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a missing folder returns zero and is not created",
                removed == 0 && !fm.fileExists(atPath: missingDir.path))
        } catch {
            reporter.record("retention: a missing folder returns zero and is not created", false, String(describing: error))
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r9")
            let src = try sourceFile(in: sourceDir)
            let oldDate = now - 40 * 86_400
            var copies: [URL] = []
            for _ in 0..<3 {
                copies.append(try store.backup(src, at: oldDate))
            }
            let removed = store.pruneExpired(now: now)
            let allGone = copies.allSatisfy { !fm.fileExists(atPath: $0.path) }
            reporter.record(
                "retention: the returned count equals the files removed",
                removed == copies.count && allGone)
        } catch {
            reporter.record("retention: the returned count equals the files removed", false, String(describing: error))
        }

        do {
            let (sourceDirA, _, storeA) = try newRowDir("r10a")
            let srcA = try sourceFile(in: sourceDirA)
            let day0 = now - 40 * 86_400
            let first = try storeA.backup(srcA, at: day0)
            let second = try storeA.backup(srcA, at: day0 + 33 * 86_400)
            let firstGone = !fm.fileExists(atPath: first.path)
            let secondKept = fm.fileExists(atPath: second.path)

            let (sourceDirB, _, storeB) = try newRowDir("r10b")
            let srcB = try sourceFile(in: sourceDirB)
            let made = now - 60 * 86_400
            let earlier = try storeB.backup(srcB, at: made)
            let later = try storeB.backup(srcB, at: made + 29 * 86_400)
            let earlierKept = fm.fileExists(atPath: earlier.path)
            let laterKept = fm.fileExists(atPath: later.path)

            reporter.record(
                "retention: backup(at:) prunes copies past the limit before its own date and keeps the new copy",
                firstGone && secondKept && earlierKept && laterKept)
        } catch {
            reporter.record("retention: backup(at:) prunes copies past the limit before its own date and keeps the new copy", false, String(describing: error))
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r11")
            let src = try sourceFile(in: sourceDir)
            let oldCopy = try store.backup(src, at: now - 40 * 86_400)
            let folder = sourceDir.appendingPathComponent("a-folder", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var threw = false
            do {
                _ = try store.backup(folder, at: now)
            } catch {
                threw = true
            }
            reporter.record(
                "retention: a backup that fails does not prune",
                threw && fm.fileExists(atPath: oldCopy.path))
        } catch {
            reporter.record("retention: a backup that fails does not prune", false, String(describing: error))
        }

        do {
            let (sourceDir, _, store) = try newRowDir("r12")
            let src = try sourceFile(in: sourceDir)
            var copy = try store.backup(src, at: now - 40 * 86_400)
            var values = URLResourceValues()
            values.isHidden = true
            try copy.setResourceValues(values)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a hidden file with an old pattern name is never removed",
                removed == 0 && fm.fileExists(atPath: copy.path))
        } catch {
            reporter.record("retention: a hidden file with an old pattern name is never removed", false, String(describing: error))
        }

        do {
            let (_, backupDir, store) = try newRowDir("r13")
            let name = "20201301-000000-000-01234567-89AB-CDEF-0123-456789ABCDEF-notes.md"
            let file = backupDir.appendingPathComponent(name)
            try Data("x\n".utf8).write(to: file)
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: a name whose timestamp does not parse is never removed",
                removed == 0 && fm.fileExists(atPath: file.path))
        } catch {
            reporter.record("retention: a name whose timestamp does not parse is never removed", false, String(describing: error))
        }

        do {
            let (sourceDir, backupDir, store) = try newRowDir("r14")
            let src = try sourceFile(in: sourceDir)
            _ = try store.backup(src, at: now - 40 * 86_400)
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0))], ofItemAtPath: backupDir.path)
            defer {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: backupDir.path)
            }
            let removed = store.pruneExpired(now: now)
            reporter.record(
                "retention: an unreadable folder returns zero",
                removed == 0)
        } catch {
            reporter.record("retention: an unreadable folder returns zero", false, String(describing: error))
        }
    }
}
