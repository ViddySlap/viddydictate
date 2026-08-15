import Foundation

enum AppIdentity {
    static let bundleID = "com.viddydictate.app"
    static let legacyBundleID = "com.viddyslap.viddydictate"

    static func queueLabel(_ suffix: String) -> String {
        "\(bundleID).\(suffix)"
    }
}

/// Single owner for app-local filesystem roots.
enum AppPaths {
    private static let appSupportFolderName = "ViddyDictate"

    static func applicationSupportDirectory(fileManager fm: FileManager = .default) -> URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    static func ensureApplicationSupportDirectory(fileManager fm: FileManager = .default) -> URL {
        let dir = applicationSupportDirectory(fileManager: fm)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch {
            UserDataWriteFailureCenter.report(
                subsystem: "application data", operation: "create directory", url: dir, error: error)
        }
        return dir
    }
}
