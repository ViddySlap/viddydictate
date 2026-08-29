import Foundation

/// Headless proof for the L2 installer engine. It never contacts PyPI or Hugging Face and never
/// touches a working venv: command outcomes are injected and the checksum fixture lives in TMPDIR.
enum InstallerEngineSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate installer engine - selftest ===")
        let reporter = SelfTestReporter()
        checkPlanIsData(reporter)
        checkCommandShapes(reporter)
        checkRetryRule(reporter)
        checkChecksumAndRealError(reporter)
        checkRowsContinueAfterFailure(reporter)
        checkNoDepsGuard(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "installer engine"))
        print(reporter.passed ? "\nINSTALLER ENGINE GREEN" : "\nINSTALLER ENGINE FAILED")
        return reporter.passed
    }

    private static func checkPlanIsData(_ check: SelfTestReporter) {
        let core = BootstrapInstallPlan.mandatoryCore
        check.record("the mandatory core is represented as independent descriptors", core.map(\.id)
            == ["stt-daemon", "web-search"])
        check.record("the STT package list is data, not a pip command string",
                     BootstrapInstallPlan.sttDaemon.packages
                        == BootstrapInstallPlan.mlxWhisperDependencies + [BootstrapInstallPlan.mlxWhisper]
                        && BootstrapInstallPlan.sttDaemon.packages.last?.pipRequirement == "mlx-whisper~=0.4.3")

        // B20's cut. These pin the OUTCOME of the proof, so a later edit that quietly reinstates torch
        // - or that widens `--no-deps` past the one package the proof covered - reds the gate.
        let stt = BootstrapInstallPlan.sttDaemon.packages
        check.record("no STT package pulls torch back in",
                     !stt.contains { ["torch", "torchaudio", "torchvision"].contains($0.name) },
                     stt.map(\.pipRequirement).joined(separator: " "))
        check.record("mlx-whisper is the ONLY package that opts out of dependency resolution",
                     stt.filter { !$0.resolvesDependencies }.map(\.name) == ["mlx-whisper"],
                     stt.filter { !$0.resolvesDependencies }.map(\.name).joined(separator: ", "))
        check.record("every package that opts out of resolution carries an import check",
                     stt.allSatisfy { $0.resolvesDependencies || $0.importCheck != nil }
                        && BootstrapInstallPlan.mlxWhisper.importCheck == "mlx_whisper")
        check.record("the hand-owned closure is mlx-whisper's own Requires-Dist minus torch",
                     BootstrapInstallPlan.mlxWhisperDependencies.map(\.name)
                        == ["mlx", "numba", "numpy", "tqdm", "more-itertools", "tiktoken",
                            "huggingface_hub", "scipy"]
                        && BootstrapInstallPlan.mlxWhisperDependencies.allSatisfy(\.resolvesDependencies))
        check.record("the web-search row did not inherit the STT row's --no-deps",
                     BootstrapInstallPlan.webSearch.packages.allSatisfy(\.resolvesDependencies))
        check.record("the web-search package list is independently data-driven",
                     BootstrapInstallPlan.webSearch.packages == [BootstrapInstallPlan.ddgs]
                        && BootstrapInstallPlan.webSearch.packages.first?.pipRequirement == "ddgs")
        check.record("the STT row carries a published-hash model descriptor",
                     BootstrapInstallPlan.sttDaemon.modelArtifacts == [BootstrapInstallPlan.whisperModel]
                        && BootstrapInstallPlan.whisperModel.verifyPublishedHashes
                        && BootstrapInstallPlan.whisperModel.repository
                            == "mlx-community/whisper-large-v3-turbo")
    }

    private static func checkCommandShapes(_ check: SelfTestReporter) {
        let pip = InstallerEngine.pipArguments(for: [
            InstallerPackage(name: "mlx-whisper", versionConstraint: "~=0.4.3"),
            InstallerPackage(name: "torch")])
        check.record("pip receives a data-built package list with its own cache and retries",
                     pip.contains("--retries") && pip.contains("3") && pip.contains("mlx-whisper~=0.4.3")
                        && pip.contains("torch") && !pip.contains("--no-cache-dir"), pip.joined(separator: " "))
        check.record("a resolving package list never carries --no-deps", !pip.contains("--no-deps"))

        // `--no-deps` is a property of the INVOCATION, not of a requirement, so the split is what makes
        // the descriptor's per-package flag mean anything. Order matters: the resolving group has to
        // land before the pinned one, or the environment is only correct by the resolver's accident.
        let invocations = InstallerEngine.pipInvocations(for: BootstrapInstallPlan.sttDaemon.packages)
        check.record("the STT row installs as two pip commands, resolving first then --no-deps",
                     invocations.count == 2
                        && !invocations[0].contains("--no-deps")
                        && invocations[0].contains("mlx>=0.11") && invocations[0].contains("scipy")
                        && !invocations[0].contains("mlx-whisper~=0.4.3")
                        && invocations[1].contains("--no-deps")
                        && invocations[1].last == "mlx-whisper~=0.4.3",
                     invocations.map { $0.joined(separator: " ") }.joined(separator: " | "))
        check.record("a wholly-resolving row is still ONE pip command",
                     InstallerEngine.pipInvocations(for: BootstrapInstallPlan.webSearch.packages).count == 1)
        check.record("the import-check command is one python -c per hand-owned package",
                     InstallerEngine.importCheckArguments(for: BootstrapInstallPlan.sttDaemon.packages)
                        == [["-c", "import mlx_whisper"]])

        let modelArgs = InstallerEngine.modelDownloadArguments(
            for: InstallerModelArtifact(repository: "small/test", revision: "rev-1"),
            cacheDirectory: URL(fileURLWithPath: "/tmp/installer-model-cache", isDirectory: true))
        let script = modelArgs.last ?? ""
        check.record("model downloads use huggingface_hub snapshot_download and published SHA-256",
                     script.contains("snapshot_download") && script.contains("HfApi")
                        && script.contains("sha256") && script.contains("cache_dir")
                        && script.contains("VIDDYDICTATE_HASH_MISMATCH"))
        check.record("the model command carries no repository or revision in argv",
                     modelArgs.count == 2 && !modelArgs.contains("small/test") && !modelArgs.contains("rev-1"))
        // The check above only proves the script MENTIONS sha256, which stayed true while the script
        // could never obtain one: huggingface_hub returns `lfs = None` for every sibling unless file
        // metadata is requested, so `published` was always empty and the mandatory voice-model row
        // failed after downloading 1.5 GiB. A fixture cannot see that; this pins the one argument that
        // makes the published-hash check capable of finding a hash at all.
        check.record("the model command asks huggingface_hub for the per-file metadata the hash check needs",
                     script.contains("files_metadata=True"))
    }

    private static func checkRetryRule(_ check: SelfTestReporter) {
        let transport = InstallerFailure(category: .transport, message: "connection reset")
        let server = InstallerFailure(category: .server(503), message: "HTTP error 503")
        let client = InstallerFailure(category: .client(404), message: "HTTP error 404")
        let hash = InstallerFailure(category: .checksumMismatch, message: "hash mismatch")
        check.record("transport failures retry before the third attempt",
                     InstallerRetryPolicy.shouldRetry(transport, attempt: 1)
                        && InstallerRetryPolicy.shouldRetry(transport, attempt: 2)
                        && !InstallerRetryPolicy.shouldRetry(transport, attempt: 3))
        check.record("HTTP 5xx failures retry with bounded backoff",
                     InstallerRetryPolicy.shouldRetry(server, attempt: 1)
                        && InstallerRetryPolicy.delayBeforeAttempt(2) == 1
                        && InstallerRetryPolicy.delayBeforeAttempt(3) == 2)
        check.record("HTTP 4xx failures never retry", !InstallerRetryPolicy.shouldRetry(client, attempt: 1))
        check.record("checksum mismatches never retry", !InstallerRetryPolicy.shouldRetry(hash, attempt: 1))
    }

    private static func checkChecksumAndRealError(_ check: SelfTestReporter) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-installer-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("tiny-artifact.bin")
        let data = Data("small real artifact\n".utf8)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: file)
            let actual = try InstallerEngine.sha256(ofFileAt: file)
            check.record("a small artifact is verified by SHA-256 rather than size",
                         actual == "e0d87f244425cf8d903f3673c12c93dbe097caf0d20e4970bd98574823c32a5a",
                         actual)
        } catch {
            check.record("a small artifact is verified by SHA-256 rather than size", false,
                         String(describing: error))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let detail = "ERROR: Could not resolve huggingface.co (connection reset by peer)"
        let runner = FakeInstallerRunner(responses: [
            InstallerCommandResult(exitCode: 1, stderr: detail),
            InstallerCommandResult(exitCode: 1, stderr: detail),
            InstallerCommandResult(exitCode: 1, stderr: detail)])
        let engine = InstallerEngine(paths: testPaths(root: root), runner: runner, sleep: { _ in })
        let descriptor = InstallerComponentDescriptor(
            id: "error-row", title: "Error row", virtualEnvironmentRelativePath: "venv", packages: [])
        let result = engine.install(descriptor)
        if case .failed(let failure, _) = result.state {
            check.record("the row retains the real transport error text", failure.message.contains(detail))
            check.record("transport failure is retried three times", runner.invocations.count == 3,
                         "attempts=\(runner.invocations.count)")
        } else {
            check.record("the row retains the real transport error text", false, "row unexpectedly installed")
            check.record("transport failure is retried three times", false, "row unexpectedly installed")
        }
    }

    private static func checkRowsContinueAfterFailure(_ check: SelfTestReporter) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-installer-rows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeInstallerRunner(responses: [
            InstallerCommandResult(exitCode: 1, stderr: "HTTP error 404 Not Found"),
            InstallerCommandResult(exitCode: 0),
        ])
        let engine = InstallerEngine(paths: testPaths(root: root), runner: runner, sleep: { _ in })
        let first = InstallerComponentDescriptor(
            id: "first", title: "First", virtualEnvironmentRelativePath: "first-venv", packages: [])
        let second = InstallerComponentDescriptor(
            id: "second", title: "Second", virtualEnvironmentRelativePath: "second-venv", packages: [])
        let results = engine.installAll([first, second])
        check.record("one row's 4xx failure does not stop the next row",
                     results.count == 2 && !results[0].succeeded && results[1].succeeded)
        check.record("a 4xx row uses one attempt and preserves the response",
                     runner.invocations.count == 2 && results[0].attempts == 1,
                     "invocations=\(runner.invocations.count)")
    }

    /// The regression that guards B20's cut. `--no-deps` moves ownership of mlx-whisper's dependency
    /// closure from pip to this repo, and the failure that creates is the one B20 names: the install
    /// succeeds, and the ImportError arrives months later in a daemon on a stranger's machine. The
    /// engine must therefore convert an incomplete closure into a failure of the row that caused it.
    private static func checkNoDepsGuard(_ check: SelfTestReporter) {
        let hand = InstallerComponentDescriptor(
            id: "hand-owned", title: "Hand-owned closure",
            virtualEnvironmentRelativePath: "hand-venv",
            packages: [InstallerPackage(name: "mlx-whisper", versionConstraint: "~=0.4.3",
                                        resolvesDependencies: false, importCheck: "mlx_whisper")])

        var root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-nodeps-bad-\(UUID().uuidString)", isDirectory: true)
        // venv PASS, pip --no-deps PASS, then `python -c "import mlx_whisper"` FAILS.
        var runner = FakeInstallerRunner(responses: [
            InstallerCommandResult(exitCode: 0),
            InstallerCommandResult(exitCode: 0),
            InstallerCommandResult(exitCode: 1, stderr: "ModuleNotFoundError: No module named 'numba'"),
        ])
        var engine = InstallerEngine(paths: testPaths(root: root), runner: runner, sleep: { _ in })
        var result = engine.install(hand)
        try? FileManager.default.removeItem(at: root)
        check.record("a clean pip install with an incomplete closure still fails the row",
                     !result.succeeded)
        var message = "no failure recorded"
        if case .failed(let failure, _) = result.state { message = failure.message }
        check.record("the row carries python's real ModuleNotFoundError, not a generic message",
                     message.contains("No module named 'numba'") && message.contains("incomplete"),
                     message)
        check.record("a missing module is not retried, because it is a resolution fact not a transport one",
                     runner.invocations.filter { $0.1.contains("-c") }.count == 1,
                     "import-check invocations=\(runner.invocations.filter { $0.1.contains("-c") }.count)")

        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-nodeps-good-\(UUID().uuidString)", isDirectory: true)
        runner = FakeInstallerRunner(responses: [])
        engine = InstallerEngine(paths: testPaths(root: root), runner: runner, sleep: { _ in })
        result = engine.install(hand)
        let ordered = runner.invocations.map(\.1)
        try? FileManager.default.removeItem(at: root)
        check.record("a complete closure installs and the import check runs LAST, in the built venv",
                     result.succeeded && ordered.count == 3
                        && ordered[1].contains("--no-deps")
                        && ordered[2] == ["-c", "import mlx_whisper"],
                     ordered.map { $0.joined(separator: " ") }.joined(separator: " | "))

        // A row with no hand-owned package must not gain a check it never asked for.
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-nodeps-none-\(UUID().uuidString)", isDirectory: true)
        runner = FakeInstallerRunner(responses: [])
        engine = InstallerEngine(paths: testPaths(root: root), runner: runner, sleep: { _ in })
        _ = engine.install(BootstrapInstallPlan.webSearch)
        let webSearch = runner.invocations.map(\.1)
        try? FileManager.default.removeItem(at: root)
        check.record("a fully-resolved row runs no import check",
                     !webSearch.contains { $0.first == "-c" },
                     webSearch.map { $0.joined(separator: " ") }.joined(separator: " | "))
    }

    private static func testPaths(root: URL) -> InstallerPaths {
        InstallerPaths(
            python: URL(fileURLWithPath: "/bin/sh"),
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            modelCache: root.appendingPathComponent("model-cache", isDirectory: true),
            packageCache: root.appendingPathComponent("package-cache", isDirectory: true))
    }

    private final class FakeInstallerRunner: InstallerProcessRunning {
        var responses: [InstallerCommandResult]
        var invocations: [(URL, [String])] = []

        init(responses: [InstallerCommandResult]) {
            self.responses = responses
        }

        func run(executable: URL, arguments: [String], environment: [String: String],
                 timeout: TimeInterval) -> InstallerCommandResult {
            invocations.append((executable, arguments))
            let result = responses.isEmpty
                ? InstallerCommandResult(exitCode: 0)
                : responses.removeFirst()
            if result.succeeded, arguments.contains("-m"), arguments.contains("venv"),
               let path = arguments.last {
                let python = URL(fileURLWithPath: path).appendingPathComponent("bin/python")
                try? FileManager.default.createDirectory(at: python.deletingLastPathComponent(),
                                                          withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: python.path, contents: Data())
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: python.path)
            }
            return result
        }
    }
}
