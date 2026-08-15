import Foundation

enum CodexFeatureInventoryTool {
    private struct CommandResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let binary = try binaryPath(arguments: arguments)
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent(
                    "viddydictate-codex-quarantine-inventory-\(UUID().uuidString)",
                    isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try CodexIsolationFoundation.secureDirectory(root)
            let paths = CodexIsolationFoundation.scratchPaths(root: root)
            try CodexIsolationFoundation.prepareDirectories(paths)
            try CodexIsolationFoundation.stageSchema(paths: paths)
            try CodexProviderRuntime.stageBootstrapConfig(paths: paths)
            let origin = URL(fileURLWithPath: binary)
            let originIdentity = try CodexIsolationFoundation.strongFileIdentity(
                at: origin, includeCodeSigning: true)
            guard originIdentity.codeSigning != nil else {
                throw CodexIsolationError.failed(
                    "candidate Codex code-signing identity is unavailable")
            }
            let snapshot = try CodexIsolationFoundation.installExecutableSnapshot(
                from: origin,
                originIdentity: originIdentity,
                paths: paths)
            let runner = shippingRunnerPath()
            let runnerIdentity = try CodexIsolationFoundation.strongFileIdentity(
                at: URL(fileURLWithPath: runner),
                includeCodeSigning: true)

            let versionResult = try runCommand(
                runner: runner,
                operation: "version",
                snapshot: snapshot,
                runnerIdentity: runnerIdentity,
                paths: paths)
            guard versionResult.status == 0, versionResult.stderr.isEmpty else {
                throw CodexIsolationError.failed("candidate Codex version command failed")
            }
            let version = try decoded(versionResult.stdout, label: "version")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let firstResult = try runCommand(
                runner: runner,
                operation: "features",
                snapshot: snapshot,
                runnerIdentity: runnerIdentity,
                paths: paths)
            guard firstResult.status == 0, firstResult.stderr.isEmpty else {
                throw CodexIsolationError.failed("candidate Codex feature inventory command failed")
            }
            let first = try CodexIsolationFoundation.parseFeatureInventory(
                try decoded(firstResult.stdout, label: "feature inventory"))
            try CodexIsolationFoundation.stageConfig(
                CodexIsolationFoundation.baseConfig(
                    paths: paths,
                    disabledSkillPaths: [],
                    featureInventory: first),
                at: paths.config)
            let restrictiveResult = try runCommand(
                runner: runner,
                operation: "features",
                snapshot: snapshot,
                runnerIdentity: runnerIdentity,
                paths: paths)
            guard restrictiveResult.status == 0, restrictiveResult.stderr.isEmpty else {
                throw CodexIsolationError.failed(
                    "candidate Codex restrictive inventory command failed or emitted a warning")
            }
            let restrictive = try CodexIsolationFoundation.parseFeatureInventory(
                try decoded(restrictiveResult.stdout, label: "restrictive feature inventory"))
            if let failure = CodexIsolationFoundation.featureInventoryBoundaryFailure(
                firstPass: first, restrictivePass: restrictive) {
                print("[codex-feature-inventory] BLOCKED: \(failure)")
                return 3
            }

            print("[codex-feature-inventory] cli=\(version) reviewed=\(CodexIsolationFoundation.lastReviewedCLIVersion)")
            print("[codex-feature-inventory] \(CodexIsolationFoundation.featureInventoryPinStatus); first_count=\(first.count) restrictive_count=\(restrictive.count)")
            print("[codex-feature-inventory] restrictive inventory")
            for name in restrictive.keys.sorted() {
                guard let entry = restrictive[name] else { continue }
                print("  \(name) stage=\(entry.stage.rawValue) enabled=\(entry.enabled)")
            }
            print("[codex-feature-inventory] PASS: bounded two-pass compatibility inventory")
            return 0
        } catch let error as CodexIsolationError {
            fputs("[codex-feature-inventory] FAIL: \(error.description)\n", stderr)
            return 2
        } catch {
            fputs("[codex-feature-inventory] FAIL: unexpected inventory audit error\n", stderr)
            return 2
        }
    }

    private static func binaryPath(arguments: [String]) throws -> String {
        guard let flagIndex = arguments.firstIndex(of: "--codex-feature-inventory") else {
            throw CodexIsolationError.failed("missing --codex-feature-inventory mode")
        }
        let trailing = Array(arguments[(flagIndex + 1)...])
        if trailing.isEmpty { return CodexIsolationFoundation.codexBinary }
        guard trailing.count == 2, trailing[0] == "--binary", trailing[1].hasPrefix("/") else {
            throw CodexIsolationError.failed(
                "usage: --codex-feature-inventory [--binary <absolute-path>]")
        }
        guard FileManager.default.isExecutableFile(atPath: trailing[1]) else {
            throw CodexIsolationError.failed("candidate Codex binary is not executable")
        }
        return trailing[1]
    }

    static func shippingRunnerPath(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> String {
        let bundle = bundleURL.standardizedFileURL
        let shippingBundle = bundle.lastPathComponent == "ViddyDictateTests.app"
            ? bundle.deletingLastPathComponent()
                .appendingPathComponent("ViddyDictate.app", isDirectory: true)
            : bundle
        return shippingBundle
            .appendingPathComponent(
                "Contents/Helpers/CodexContainmentRunner",
                isDirectory: false)
            .path
    }

    private static func runCommand(
        runner: String,
        operation: String,
        snapshot: (
            url: URL,
            identity: CodexIsolationFoundation.StrongFileIdentity
        ),
        runnerIdentity: CodexIsolationFoundation.StrongFileIdentity,
        paths: CodexIsolationFoundation.Paths
    ) throws -> CommandResult {
        let cheap = snapshot.identity.cheap
        let arguments = [
            "quarantine",
            "--home", paths.home.path,
            "--cwd", paths.cwd.path,
            "--tmp", paths.temp.path,
            "--operation", operation,
            "--binary-path", snapshot.url.path,
            "--binary-sha256", snapshot.identity.sha256,
            "--binary-device", String(cheap.device),
            "--binary-inode", String(cheap.inode),
            "--binary-size", String(cheap.size),
            "--binary-mtime-sec", String(cheap.modifiedSeconds),
            "--binary-mtime-nsec", String(cheap.modifiedNanoseconds),
        ]
        let environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "TERM": "dumb",
        ]

        guard try CodexIsolationFoundation.strongFileIdentity(
            at: URL(fileURLWithPath: runner),
            includeCodeSigning: true) == runnerIdentity else {
            throw CodexIsolationError.failed(
                "inventory containment runner identity changed")
        }
        let bounded = try CodexIsolationFoundation.runBoundedProcess(
            executable: runner,
            arguments: arguments,
            environment: environment,
            currentDirectory: paths.cwd,
            timeout: 25,
            stdoutLimit: 1_048_576,
            stderrLimit: 1_048_576,
            postLaunch: {
                guard try CodexIsolationFoundation.strongFileIdentity(
                    at: URL(fileURLWithPath: runner),
                    includeCodeSigning: true) == runnerIdentity else {
                    throw CodexIsolationError.failed(
                        "inventory containment runner identity changed")
                }
            })
        guard bounded.leaderReaped,
              !bounded.residualProcessGroup,
              !bounded.captureFailure else {
            throw CodexIsolationError.failed(
                "candidate Codex inventory process cleanup failed")
        }
        guard !bounded.stdoutOverflow, !bounded.stderrOverflow else {
            throw CodexIsolationError.failed("candidate Codex inventory output exceeded the capture limit")
        }
        return CommandResult(
            status: bounded.status,
            stdout: bounded.stdout,
            stderr: bounded.stderr)
    }

    private static func decoded(_ data: Data, label: String) throws -> String {
        guard let output = String(data: data, encoding: .utf8) else {
            throw CodexIsolationError.failed("candidate Codex \(label) output was not UTF-8")
        }
        return output
    }

}
