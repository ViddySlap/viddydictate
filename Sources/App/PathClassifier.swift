import Foundation

extension AppPaths {
    /// Privacy boundary: this deny is deliberately independent of Obsidian's mutable registry.
    /// Constructing the URL does not inspect the denied root.
    static var deniedRoots: [URL] {
        [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("private", isDirectory: true)]
    }

    static func obsidianConfigurationURL(fileManager fm: FileManager = .default) -> URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian", isDirectory: true)
            .appendingPathComponent("obsidian.json", isDirectory: false)
    }
}

enum PathClassifierDecision: Equatable {
    case refuseDeniedRoot
    case readOnlyVault
    case readOnlyFailClosed
    case readWriteLoose
}

struct PathClassifierResult: Equatable {
    let resolvedURL: URL
    let decision: PathClassifierDecision
}

/// Classifies one handed-in path at a time. Denied roots are checked before the Obsidian registry is
/// read, and both candidates and roots are resolved/standardized before component-prefix matching.
struct PathClassifier {
    private let deniedRoots: [URL]
    private let obsidianConfigurationURL: URL

    init(
        deniedRoots: [URL] = AppPaths.deniedRoots,
        obsidianConfigurationURL: URL = AppPaths.obsidianConfigurationURL()
    ) {
        self.deniedRoots = deniedRoots
        self.obsidianConfigurationURL = obsidianConfigurationURL
    }

    func classify(_ candidate: URL) -> PathClassifierDecision {
        classification(for: candidate).decision
    }

    func classification(for candidate: URL) -> PathClassifierResult {
        guard candidate.isFileURL else {
            return PathClassifierResult(resolvedURL: candidate, decision: .readOnlyFailClosed)
        }
        let resolvedCandidate = Self.resolved(candidate)

        if deniedRoots.lazy.map(Self.resolved).contains(where: {
            Self.isEqualToOrInside(resolvedCandidate, root: $0)
        }) {
            return PathClassifierResult(resolvedURL: resolvedCandidate, decision: .refuseDeniedRoot)
        }

        do {
            let data = try Data(contentsOf: obsidianConfigurationURL)
            let configuration = try JSONDecoder().decode(PathClassifierObsidianConfiguration.self, from: data)
            let vaultRoots = try configuration.vaults.values.map { vault -> URL in
                guard !vault.path.isEmpty, NSString(string: vault.path).isAbsolutePath else {
                    throw PathClassifierConfigurationError.invalidVaultPath
                }
                return Self.resolved(URL(fileURLWithPath: vault.path, isDirectory: true))
            }
            if vaultRoots.contains(where: { Self.isEqualToOrInside(resolvedCandidate, root: $0) }) {
                return PathClassifierResult(resolvedURL: resolvedCandidate, decision: .readOnlyVault)
            }
            return PathClassifierResult(resolvedURL: resolvedCandidate, decision: .readWriteLoose)
        } catch {
            return PathClassifierResult(resolvedURL: resolvedCandidate, decision: .readOnlyFailClosed)
        }
    }

    /// `resolvingSymlinksInPath()` also collapses `.` and `..`; the final standardization makes the
    /// prefix comparison operate only on canonical path components.
    private static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isEqualToOrInside(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(candidateComponents.prefix(rootComponents.count), rootComponents).allSatisfy { pair in
            pair.0.compare(pair.1, options: [.caseInsensitive, .literal]) == .orderedSame
        }
    }
}

private struct PathClassifierObsidianConfiguration: Decodable {
    let vaults: [String: PathClassifierObsidianVault]
}

private struct PathClassifierObsidianVault: Decodable {
    let path: String
}

private enum PathClassifierConfigurationError: Error {
    case invalidVaultPath
}
