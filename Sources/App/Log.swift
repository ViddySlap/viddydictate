import Foundation

/// Ultra-light append-only file log at ~/Library/Logs/ViddyDictate.log.
/// Event-level only (never per-frame), written off the main thread on a utility queue, and
/// auto-trimmed — so it stays cheap even when the Mac is under heavy GPU/CPU load.
enum Log {
    static let url: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ViddyDictate.log")
    }()

    private static let q = DispatchQueue(label: AppIdentity.queueLabel("log"), qos: .utility)
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// Trim on launch if the log has grown past ~200 KB, so it never bloats.
    static func rotateIfNeeded() {
        q.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > 200_000 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func write(_ msg: String) {
        let line = "\(stamp.string(from: Date())) \(msg)\n"
        q.async {
            guard let data = line.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                fh.seekToEndOfFile()
                fh.write(data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Headless deterministic-test barrier. Production never calls this; it lets privacy tests inspect
    /// the scratch log only after every queued classification line has been persisted.
    static func flushForTest() { q.sync {} }
}
