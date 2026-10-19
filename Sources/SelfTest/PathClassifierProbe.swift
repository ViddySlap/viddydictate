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
}
