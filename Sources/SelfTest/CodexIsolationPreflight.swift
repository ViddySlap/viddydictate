import Foundation

enum CodexIsolationPreflight {
    enum Mode { case scratch, stageProduction }

    static func run(mode: Mode, runnerPath: String) -> Bool {
        do {
            switch mode {
            case .scratch:
                let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                    .appendingPathComponent("viddydictate-codex-s1-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                try CodexIsolationFoundation.secureDirectory(root)
                print("=== Codex S1 unauthenticated scratch preflight ===")
                try prepareAndAudit(paths: CodexIsolationFoundation.scratchPaths(root: root),
                                    runnerPath: runnerPath, label: "scratch")
            case .stageProduction:
                print("=== Codex S1 production-path staging (unauthenticated) ===")
                let paths = try CodexIsolationFoundation.productionPaths()
                try prepareAndAudit(paths: paths, runnerPath: runnerPath, label: "production")
            }
            print("[codex-s1-preflight] PASS")
            return true
        } catch {
            print("[codex-s1-preflight] FAIL: \(sanitized(error))")
            return false
        }
    }

    private static func prepareAndAudit(paths: CodexIsolationFoundation.Paths,
                                        runnerPath: String, label: String) throws {
        let receipt = try CodexProviderRuntime.prepareCompatibilityBoundaryForPreflight(
            paths: paths, runnerPath: runnerPath)
        let skillsRoot = try CodexIsolationFoundation.inspectDedicatedSkillsRoot(
            skillsRoot: paths.skillsRoot)
        let tree = skillsRoot.systemTree
        let skillURLs = tree.skillFiles
        try auditConfigSkillEntries(configURL: paths.config, skillURLs: skillURLs)
        try CodexProviderRuntime.verifySterileCWD(paths: paths)
        try CodexProviderRuntime.verifyDirectoryPermissions(paths: paths)

        guard try CodexProviderRuntime.rawConnectionState(
            paths: paths, receipt: receipt) == .disconnected else {
            throw CodexIsolationError.failed("dedicated home is not in the required unauthenticated state")
        }

        print("[codex-s1-preflight][\(label)] cli=\(receipt.cliVersion)")
        print("[codex-s1-preflight][\(label)] model=\(CodexIsolationFoundation.model) effort=\(CodexIsolationFoundation.effort)")
        print("[codex-s1-preflight][\(label)] skills_disabled=\(skillURLs.count) tree_sha256=\(tree.identitySHA256)")
        print("[codex-s1-preflight][\(label)] features=\(receipt.effectiveFeatures.count) \(CodexIsolationFoundation.featureInventoryPinStatus) mcp=empty plugins=empty")
        print("[codex-s1-preflight][\(label)] prompt_roles=audited route_marker=developer-only user_marker=user-only")
        print("[codex-s1-preflight][\(label)] receipt_binary_sha256=\(receipt.executable.sha256) config_sha256=\(receipt.restrictiveConfigSHA256)")
        print("[codex-s1-preflight][\(label)] dirs=0700 immutable_files=0400 cwd=empty login=Not_logged_in")
    }

    static func auditConfigSkillEntries(configURL: URL, skillURLs: [URL]) throws {
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let pathLines = config.split(separator: "\n").filter { $0.hasPrefix("path = ") }
        guard pathLines.count == skillURLs.count else {
            throw CodexIsolationError.failed("seeded-skill config entry count mismatch")
        }
        for url in skillURLs {
            let canonicalPath = try CodexIsolationFoundation.canonicalPath(url)
            let expected =
                "path = \(CodexIsolationFoundation.tomlString(canonicalPath))"
            guard config.components(separatedBy: expected).count - 1 == 1 else {
                throw CodexIsolationError.failed("seeded skill is not disabled exactly once")
            }
        }
    }

    private static func sanitized(_ error: Error) -> String {
        if let isolation = error as? CodexIsolationError { return isolation.description }
        if let boundary = error as? CodexProviderRuntime.BoundaryError,
           let description = boundary.preflightDescription {
            return description
        }
        return "unexpected local preflight error"
    }
}
