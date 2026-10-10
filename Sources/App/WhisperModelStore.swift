import Foundation

/// Pure local-install probe for the offered Whisper models, plus the one-line `whisper-model` file
/// the app writes for the daemon (selectable Whisper versions, part 1, backend only).
///
/// `isInstalled` mirrors the daemon's `_resolve_local_snapshot` / `_snapshot_is_complete` hub layout
/// exactly: `<cache>/models--<org>--<name>/refs/main` holds a commit hash and
/// `<cache>/models--<org>--<name>/snapshots/<hash>/` must contain `config.json` AND one weights file
/// (`weights.safetensors` or `weights.npz`), each a real non-empty file. The cache roots are
/// injectable so tests never read the real home; the default roots are the Hugging Face hub cache
/// and the app's own `model-cache`. No AppKit, no network, no mlx.
enum WhisperModelStore {
    static let snapshotConfig = "config.json"
    static let snapshotWeights = ["weights.safetensors", "weights.npz"]
    /// The app's one-line choice file, read by the daemon at start.
    static let choiceFileName = "whisper-model"

    /// Default cache roots: the standard Hugging Face hub cache, then the app's own installer
    /// download directory and its `hub` variant (the daemon checks both).
    static var defaultCacheDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = AppPaths.applicationSupportDirectory()
        return [
            home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
            support.appendingPathComponent("model-cache", isDirectory: true),
            support.appendingPathComponent("model-cache/hub", isDirectory: true),
        ]
    }

    /// True when `repo` has a complete, loadable snapshot in one of `cacheDirectories` (or the
    /// default roots). A missing/incomplete snapshot means the later UI can offer to install it.
    static func isInstalled(repo: String, cacheDirectories: [URL]? = nil) -> Bool {
        snapshotDirectory(repo: repo, cacheDirectories: cacheDirectories ?? defaultCacheDirectories) != nil
    }

    /// The snapshot directory for `repo`, or nil. Pure filesystem reads only.
    static func snapshotDirectory(repo: String, cacheDirectories: [URL]) -> URL? {
        guard let folder = repoFolderName(repo: repo) else { return nil }
        for cache in cacheDirectories {
            let repoDir = cache.appendingPathComponent(folder, isDirectory: true)
            let ref = repoDir.appendingPathComponent("refs/main", isDirectory: false)
            guard let commit = try? String(contentsOf: ref, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), isValidCommit(commit)
            else { continue }
            let snapshot = repoDir.appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(commit, isDirectory: true)
            if isCompleteSnapshot(snapshot) { return snapshot }
        }
        return nil
    }

    /// `<Application Support>/ViddyDictate/whisper-model` — the file the daemon reads at start.
    static var choiceFileURL: URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent(choiceFileName, isDirectory: false)
    }

    /// Write the choice file atomically (temp file + rename), creating the directory if needed.
    /// Throws on any filesystem failure so `WhisperModelSwitch` can report `.failed` without
    /// changing the setting or restarting the daemon.
    static func writeChoice(repo: String, to url: URL? = nil) throws {
        let target = url ?? choiceFileURL
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((repo + "\n").utf8).write(to: target, options: .atomic)
    }

    private static func repoFolderName(repo: String) -> String? {
        guard !repo.isEmpty,
              !repo.hasPrefix("/"), !repo.hasPrefix("."), !repo.hasPrefix("~"),
              !repo.split(separator: "/").contains("..")
        else { return nil }
        return "models--" + repo.replacingOccurrences(of: "/", with: "--")
    }

    private static func isValidCommit(_ commit: String) -> Bool {
        !commit.isEmpty && !commit.contains("/") && commit != "." && commit != ".."
    }

    private static func isCompleteSnapshot(_ snapshot: URL) -> Bool {
        isNonEmptyFile(snapshot.appendingPathComponent(snapshotConfig, isDirectory: false))
            && snapshotWeights.contains {
                isNonEmptyFile(snapshot.appendingPathComponent($0, isDirectory: false))
            }
    }

    /// A real, non-empty regular file. Resolves symlinks first: hub snapshots are symlinks into
    /// `blobs/`, and a dangling one is a download that never finished.
    private static func isNonEmptyFile(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0
        else { return false }
        return true
    }
}
