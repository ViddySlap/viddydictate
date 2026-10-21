import Foundation

extension AppPaths {
    static func fileBackupsDirectory(fileManager fm: FileManager = .default) -> URL {
        applicationSupportDirectory(fileManager: fm)
            .appendingPathComponent("file-backups", isDirectory: true)
    }
}

/// Frozen open-time snapshots live beside (not inside) the retention-owned sticky-notes directory.
struct PathClassifierBackupStore {
    private let directory: URL
    private let fileManager: FileManager

    static let retentionDays = 30
    static let timeZoneGraceSeconds: TimeInterval = 93_600

    init(
        directory: URL = AppPaths.fileBackupsDirectory(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }

    @discardableResult
    func backup(_ source: URL, at date: Date = Date()) throws -> URL {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolvedSource.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw NSError(
                domain: "ViddyDictate.PathClassifierBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The opened path is not a regular file."])
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = "\(Self.timestampFormatter().string(from: date))-\(UUID().uuidString)-\(source.lastPathComponent)"
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try fileManager.copyItem(at: resolvedSource, to: destination)
        pruneExpired(now: date)
        return destination
    }

    @discardableResult
    func pruneExpired(now: Date = Date(), retentionDays: Int = PathClassifierBackupStore.retentionDays) -> Int {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        } catch {
            return 0
        }

        let cutoff = now - (Double(retentionDays) * 86_400 + Self.timeZoneGraceSeconds)
        let pattern = #"\A(\d{8}-\d{6}-\d{3})-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}-[\s\S]+\.[mM][dD]\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }

        var removed = 0
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink == false else { continue }

            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, range: range),
                  match.range == range,
                  match.range(at: 1).location != NSNotFound,
                  let tsRange = Range(match.range(at: 1), in: name) else { continue }
            let timestamp = String(name[tsRange])
            guard let parsed = Self.timestampFormatter().date(from: timestamp),
                  parsed < cutoff else { continue }

            if unlink(url.path) == 0 {
                removed += 1
            } else {
                Log.write("files-backup: could not remove an expired copy")
            }
        }
        if removed > 0 {
            Log.write("files-backup: removed \(removed) expired copies")
        }
        return removed
    }
}
