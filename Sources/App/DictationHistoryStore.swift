import Foundation

/// Infinite, append-only, per-day dictation log — the store behind Settings' "Keep full dictation
/// history" toggle (interop ADR 0004, link L4).
///
/// This is a DISTINCT store from `TranscriptionHistory` (the rolling, capped JSON recovery window,
/// which L4 leaves untouched). When the toggle is ON, every delivered transcript is appended — all
/// modes, labeled with its mode + a timestamp — to one Markdown file per local day:
///
///     ~/Library/Application Support/ViddyDictate/history/YYYY-MM-DD.md
///
/// Append-only, no retention cap (infinite is the point of this explicit opt-in). The `history/` DIRECTORY sits
/// beside — and never collides with — the rolling window's `history.json` FILE under the same
/// ViddyDictate folder.
///
/// The store lives OUTSIDE Obsidian vaults on purpose: no Obsidian Sync and no accidental workspace
/// indexing. External tools may read it through a read-only file seam; ViddyDictate is the only writer.
///
/// Testability seams (mirroring the codebase's injectable-store idiom, e.g. `StickyNotesStore(root:)`):
/// the target `directory` and the `enabled` gate are both injectable, so the headless selftest drives a
/// scratch directory and flips the toggle without touching the user's real prefs or the real app-local store.
final class DictationHistoryStore {

    /// Production singleton: the real app-local directory, gated by the live `Settings.keepFullHistory`.
    static let shared = DictationHistoryStore()

    /// App-local base directory for the infinite store. A DIRECTORY named `history`, distinct from the
    /// rolling window's `history.json` FILE that TranscriptionHistory writes in the same ViddyDictate
    /// folder. Static + pure so the selftest can assert it points outside any vault.
    static func defaultDirectory() -> URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("history", isDirectory: true)
    }

    private let directory: URL
    private let isEnabled: () -> Bool
    private let fm = FileManager.default
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("fullhistory"))
    private let dayFormatter: DateFormatter    // YYYY-MM-DD (the filename + the file header)
    private let stampFormatter: DateFormatter  // YYYY-MM-DD HH:mm:ss (each entry heading)

    /// - Parameters:
    ///   - directory: where per-day files land. Defaults to the app-local store; the selftest injects a
    ///     scratch dir.
    ///   - enabled: consulted live on every `append`. Defaults to the persisted toggle so a production
    ///     flip takes effect on the next delivery; the selftest injects a fixed value.
    init(directory: URL = DictationHistoryStore.defaultDirectory(),
         enabled: @escaping () -> Bool = { Settings.keepFullHistory }) {
        self.directory = directory
        self.isEnabled = enabled
        // Local-time formatting: the per-day file is the USER's day. POSIX locale so the format is stable
        // regardless of the machine's locale; `.current` timezone so both the filename and the stamps
        // reflect the user's local wall-clock time.
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        dayFormatter = day
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = .current
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        stampFormatter = stamp
    }

    /// Append one delivered transcript to today's file, IF the store is enabled. No-ops entirely (no
    /// dispatch, no directory creation, zero filesystem side effects) when disabled or when the text is
    /// blank. `mode` is a `HistoryMode.rawValue` (raw | cleanup | prompt-prep | email | search |
    /// search-gemini) so the log's vocabulary matches the rolling window's. Non-blocking: the write runs
    /// on a private serial queue, so it never stalls the delivery path.
    func append(text: String, mode: String, at date: Date = Date()) {
        guard isEnabled() else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let day = dayFormatter.string(from: date)
        let stamp = stampFormatter.string(from: date)
        queue.async {
            let url = self.directory.appendingPathComponent("\(day).md")
            let isNewFile = !self.fm.fileExists(atPath: url.path)
            var chunk = ""
            if isNewFile {
                // Seed a new day file with a human-readable header. ASCII only (no em dashes / emoji);
                // human readers use these files and local search tools index them.
                chunk += "# Dictation history \(day)\n\n"
            }
            // One entry: an H2 carrying the full timestamp + mode (so a single RAG chunk is
            // self-describing), then the verbatim delivered text, then a blank-line separator.
            chunk += "## \(stamp)  (\(mode))\n\n\(body)\n\n"
            guard let data = chunk.data(using: .utf8) else { return }
            do {
                if isNewFile {
                    try self.fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "full dictation history", operation: "append", url: url, error: error)
            }
        }
    }

    /// Test-only sync barrier: block until every previously-enqueued `append` has finished writing, so a
    /// selftest can assert the on-disk state deterministically. Harmless (and unused) in production.
    func flush() { queue.sync {} }
}
