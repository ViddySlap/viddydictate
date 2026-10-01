import Foundation

/// Where the vendor Codex CLI lives inside ChatGPT.app, in the order ViddyDictate tries them.
///
/// ChatGPT 26.924 (codex-cli 0.158) moved the CLI from a standalone Mach-O at `Resources/codex` into a
/// provisioned, entitled app bundle, `Resources/codex-cli/CodexCLI.app`, whose executable is
/// `Contents/MacOS/codex`, plus a `bin/codex` sh shim. The single pinned path vanished and every Codex
/// route refused with "Codex CLI is not installed" while the CLI sat one directory over.
///
/// Rules, each load-bearing:
/// - The bundle's Mach-O is tried first, the old standalone path second. Both are snapshotted and
///   bound by the same compatibility receipt; only the snapshot SHAPE differs (whole bundle versus one
///   file), because a bundle-signed CLI is killed by the kernel when copied out of its bundle.
/// - The `bin/codex` shim is NEVER a candidate. It is a shell script, and the containment runner's
///   process-exec literal correctly refuses to run a script; resolving to it would only move the
///   refusal later and blame the sandbox for it.
/// - "Found" means a candidate path holds something executable. Everything after that (regular file,
///   signature, bundle seal, containment) is the boundary's job, so a candidate that exists but cannot
///   be verified reports "could not be sandboxed", never "not found".
///
/// Foundation-only and free of the boundary's process machinery, so the resolution and retention
/// rules can be driven over a scratch fake ChatGPT.app by the offline suite.
enum CodexCLILocation {
    static let chatGPTAppRoot = "/Applications/ChatGPT.app"
    static let cliBundleRelativePath = "Contents/Resources/codex-cli/CodexCLI.app"
    /// Relative to the CLI bundle root. The runner pins the same suffix for a bundle snapshot.
    static let bundleExecutableRelativePath = "Contents/MacOS/codex"
    static let standaloneRelativePath = "Contents/Resources/codex"
    /// Named so the refusal is explicit and testable, not because it is ever tried.
    static let refusedShimRelativePath = "Contents/Resources/codex-cli/bin/codex"

    enum Layout: String, Codable, Equatable {
        /// Snapshot the whole `CodexCLI.app` and execute its `Contents/MacOS/codex`.
        case appBundle
        /// Snapshot the single Mach-O file (ChatGPT builds before 26.924).
        case standalone
    }

    struct Candidate: Equatable {
        let layout: Layout
        /// The Mach-O whose sha256, cdHash, and team id the receipt binds.
        let executable: String
        /// The bundle that is copied whole, for `.appBundle`; nil for `.standalone`.
        let bundleRoot: String?
    }

    enum Resolution: Equatable {
        case found(Candidate)
        case notFound(checked: [String])

        var candidate: Candidate? {
            if case .found(let candidate) = self { return candidate }
            return nil
        }
    }

    static func candidates(appRoot: String = chatGPTAppRoot) -> [Candidate] {
        let root = appRoot.hasSuffix("/") ? String(appRoot.dropLast()) : appRoot
        let bundle = root + "/" + cliBundleRelativePath
        return [
            Candidate(layout: .appBundle,
                      executable: bundle + "/" + bundleExecutableRelativePath,
                      bundleRoot: bundle),
            Candidate(layout: .standalone,
                      executable: root + "/" + standaloneRelativePath,
                      bundleRoot: nil),
        ]
    }

    /// The first candidate is the path every diagnostic names when nothing resolves.
    static var primaryExecutable: String { candidates()[0].executable }

    static func resolve(
        appRoot: String = chatGPTAppRoot,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Resolution {
        let ordered = candidates(appRoot: appRoot)
        for candidate in ordered where isExecutableFile(candidate.executable) {
            return .found(candidate)
        }
        return .notFound(checked: ordered.map(\.executable))
    }

    /// Classifies an explicit executable path (the host inventory tool's `--binary`). A Mach-O at
    /// `<name>.app/Contents/MacOS/<file>` is bundle-signed and must be snapshotted with its bundle.
    static func candidate(forExecutable path: String) -> Candidate {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.count >= 4,
           components[components.count - 2] == "MacOS",
           components[components.count - 3] == "Contents",
           components[components.count - 4].hasSuffix(".app") {
            let bundle = "/" + components.dropLast(3).joined(separator: "/")
            return Candidate(layout: .appBundle, executable: path, bundleRoot: bundle)
        }
        return Candidate(layout: .standalone, executable: path, bundleRoot: nil)
    }

    /// Operator-facing cause for the not-found case. Names only the fixed vendor locations.
    static func notFoundDescription(checked: [String]) -> String {
        "Codex CLI not found: no executable at "
            + checked.joined(separator: " or ")
            + " (the bin/codex shim is never used)"
    }
}

/// How many content-addressed Codex executable snapshots stay on disk.
///
/// A bundle snapshot is a ~240 MB `ditto` of `CodexCLI.app`, one per Codex update. Keeping the current
/// snapshot plus exactly one previous bounds the store at roughly 0.5 GB while leaving the last known
/// good build on disk across one update. Ruling (a), assumed until Ben answers: change the count here
/// and nowhere else.
enum CodexSnapshotRetention {
    static let retainedSnapshotCount = 2

    /// Only receipt-addressable snapshot entries are ever candidates for pruning: a flat
    /// `codex-<sha256>` file or a `codex-<sha256>.app` bundle. Staging leftovers, runner snapshots, and
    /// anything else in the store are never touched.
    static func isSnapshotEntryName(_ name: String) -> Bool {
        name.range(of: #"^codex-[0-9a-f]{64}(\.app)?$"#, options: .regularExpression) != nil
    }

    /// Pure selection. Keeps `current` unconditionally (it may be an older snapshot that was reused)
    /// and then the most recent others until `keep` entries remain. Ties break by name so the choice
    /// is deterministic.
    static func entriesToPrune(
        _ entries: [(name: String, recency: Int64)],
        current: String,
        keep: Int = retainedSnapshotCount
    ) -> [String] {
        let others = entries
            .filter { $0.name != current && isSnapshotEntryName($0.name) }
            .sorted { $0.recency != $1.recency ? $0.recency > $1.recency : $0.name > $1.name }
        let keepOthers = max(0, keep - 1)
        return others.dropFirst(keepOthers).map(\.name).sorted()
    }

    /// Removes every snapshot entry `entriesToPrune` selects from `store` and returns their names.
    /// `recency` is injected: production passes the entry's status-change time, which the install's own
    /// chmod refreshes; the offline suite passes fixed values.
    @discardableResult
    static func prune(
        store: URL,
        current: String,
        keep: Int = retainedSnapshotCount,
        recency: (URL) throws -> Int64,
        fileManager fm: FileManager = .default
    ) throws -> [String] {
        let names = try fm.contentsOfDirectory(atPath: store.path).filter(isSnapshotEntryName)
        var entries: [(name: String, recency: Int64)] = []
        for name in names {
            entries.append((name, try recency(store.appendingPathComponent(name))))
        }
        let doomed = entriesToPrune(entries, current: current, keep: keep)
        for name in doomed {
            try removeSnapshotEntry(store.appendingPathComponent(name), fileManager: fm)
        }
        return doomed
    }

    /// Bundle snapshots are installed with read-only directories, so owner write is restored on every
    /// directory before removal. Symlinks inside a bundle are removed as links, never followed.
    static func removeSnapshotEntry(_ url: URL, fileManager fm: FileManager = .default) throws {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
            for child in try fm.contentsOfDirectory(atPath: url.path) {
                let childURL = url.appendingPathComponent(child)
                let childAttributes = try fm.attributesOfItem(atPath: childURL.path)
                if childAttributes[.type] as? FileAttributeType == .typeDirectory {
                    try removeSnapshotEntry(childURL, fileManager: fm)
                }
            }
        }
        try fm.removeItem(at: url)
    }
}
