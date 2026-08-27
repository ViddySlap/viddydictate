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
                     BootstrapInstallPlan.sttDaemon.packages == [BootstrapInstallPlan.mlxWhisper]
                        && BootstrapInstallPlan.sttDaemon.packages.first?.pipRequirement == "mlx-whisper~=0.4.3")
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
