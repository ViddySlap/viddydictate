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

    init(
        directory: URL = AppPaths.fileBackupsDirectory(),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "\(formatter.string(from: date))-\(UUID().uuidString)-\(source.lastPathComponent)"
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try fileManager.copyItem(at: resolvedSource, to: destination)
        return destination
    }
}
