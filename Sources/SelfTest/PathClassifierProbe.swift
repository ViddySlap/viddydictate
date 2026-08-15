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
