import CryptoKit
import Darwin
import Foundation

/// A package the first-run installer can hand to pip.
///
/// The package name and version constraint are deliberately separate from the command line. The
/// component plan is data, so adding or removing torch is one entry in a package list rather than a
/// second installer implementation. `pipRequirement` is the only place that turns that data into
/// pip's spelling.
struct InstallerPackage: Equatable {
    let name: String
    let versionConstraint: String

    init(name: String, versionConstraint: String = "") {
        self.name = name
        self.versionConstraint = versionConstraint
    }

    var pipRequirement: String { name + versionConstraint }
}

/// One file hash supplied by a model's published Hugging Face metadata, or by a fixture that stands
/// in for that metadata in a deterministic self-test.
struct InstallerModelFile: Equatable {
    let relativePath: String
    let sha256: String

    init(relativePath: String, sha256: String) {
        self.relativePath = relativePath
        self.sha256 = sha256
    }
}

/// A model snapshot to download with `huggingface_hub`.
///
/// `snapshot_download` owns the cache, partial-file resume, and transport handling. The helper
/// script also reads the repository's published LFS SHA-256 values and checks every such file before
/// it exits successfully. `expectedFiles` is an additional narrow seam for callers that have a
/// pinned manifest (and for the small deterministic artifact proof); it is never a size-only check.
struct InstallerModelArtifact: Equatable {
    let repository: String
    let revision: String?
    let expectedFiles: [InstallerModelFile]
    let verifyPublishedHashes: Bool

    init(repository: String, revision: String? = nil,
         expectedFiles: [InstallerModelFile] = [], verifyPublishedHashes: Bool = true) {
        self.repository = repository
        self.revision = revision
        self.expectedFiles = expectedFiles
        self.verifyPublishedHashes = verifyPublishedHashes
    }
}

/// One independent row in the first-run bootstrap queue.
///
/// The engine has one execution shape for every descriptor: create/reuse the venv, install the
/// descriptor's package list, then download and verify its model artifacts. An empty list means the
/// step is not part of that row; it does not create a hidden hardcoded special case.
struct InstallerComponentDescriptor: Equatable {
    let id: String
    let title: String
    let detail: String
    let virtualEnvironmentRelativePath: String
    let packages: [InstallerPackage]
    let modelArtifacts: [InstallerModelArtifact]

    init(id: String, title: String, detail: String = "",
         virtualEnvironmentRelativePath: String,
         packages: [InstallerPackage], modelArtifacts: [InstallerModelArtifact] = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.virtualEnvironmentRelativePath = virtualEnvironmentRelativePath
        self.packages = packages
        self.modelArtifacts = modelArtifacts
    }
}

/// The first two rows owned by the headless installer. Later links can add UI and additional model
/// rows by consuming these descriptors; they do not need to invent another package command.
enum BootstrapInstallPlan {
    static let mlxWhisper = InstallerPackage(name: "mlx-whisper", versionConstraint: "~=0.4.3")
    static let ddgs = InstallerPackage(name: "ddgs")

    /// The speech model is cached under the app's own Application Support root. Its exact files and
    /// hashes come from the repository's published Hugging Face metadata at download time, rather
    /// than a stale hand-maintained list for a 1.5 GB snapshot.
    static let whisperModel = InstallerModelArtifact(
        repository: "mlx-community/whisper-large-v3-turbo")

    static let sttDaemon = InstallerComponentDescriptor(
        id: "stt-daemon",
        title: "Transcription engine",
        detail: "Local speech-to-text and its voice model",
        virtualEnvironmentRelativePath: "stt-venv",
        packages: [mlxWhisper],
        modelArtifacts: [whisperModel])

    static let webSearch = InstallerComponentDescriptor(
        id: "web-search",
        title: "Web search",
        detail: "The local search helper used by Option+L",
        virtualEnvironmentRelativePath: "web-search-venv",
        packages: [ddgs])

    static let mandatoryCore = [sttDaemon, webSearch]

    /// The user-facing entry point for installing a component. Keep this beside the descriptors so
    /// remedies name the same component the in-app installer presents, rather than drifting into a
    /// repository-only command that a DMG user cannot run.
    static func installPrompt(for component: InstallerComponentDescriptor) -> String {
        "open Settings > Setup and choose Install now for \(component.title)"
    }
}

/// A command result that keeps the vendor's real stderr/stdout available to the row that failed.
///
/// `exitCode == nil` means the process could not be launched. The result is value-shaped so tests can
/// inject transport, HTTP, timeout, and success outcomes without running pip or a model download.
struct InstallerCommandResult: Equatable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let launchError: String?

    init(exitCode: Int32?, stdout: String = "", stderr: String = "",
         timedOut: Bool = false, launchError: String? = nil) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.launchError = launchError
    }

    var succeeded: Bool { exitCode == 0 && !timedOut && launchError == nil }

    /// Keep both streams. pip and huggingface_hub put useful HTTP and checksum detail on stderr, while
    /// the snapshot helper's published-hash manifest is on stdout.
    var output: String {
        switch (stdout.isEmpty, stderr.isEmpty) {
        case (true, true): return launchError ?? (timedOut ? "command timed out" : "command failed")
        case (false, true): return stdout
        case (true, false): return stderr
        case (false, false): return stdout + "\n" + stderr
        }
    }
}

protocol InstallerProcessRunning {
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval) -> InstallerCommandResult
}

/// The production Process adapter. It drains stdout and stderr concurrently, then waits for the
/// process, so a verbose pip failure cannot deadlock the installer while the row is waiting.
final class FoundationInstallerProcessRunner: InstallerProcessRunning {
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval) -> InstallerCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.isEmpty ? nil : environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            return InstallerCommandResult(exitCode: nil, launchError: String(describing: error))
        }

        var stdout = Data()
        var stderr = Data()
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }

        let completed = termination.wait(timeout: .now() + max(0.1, timeout)) == .success
        var timedOut = false
        if !completed {
            timedOut = true
            if process.isRunning { process.terminate() }
            if termination.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }

        // The child is gone (or has been forcibly reaped) before these reads, so both pipes reach EOF.
        _ = stdoutDone.wait(timeout: .now() + 5)
        _ = stderrDone.wait(timeout: .now() + 5)
        return InstallerCommandResult(
            exitCode: process.terminationReason == .exit ? process.terminationStatus : nil,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut)
    }
}

enum InstallerFailureCategory: Equatable {
    case invalidPlan
    case process
    case transport
    case server(Int)
    case client(Int)
    case checksumMismatch
}

struct InstallerFailure: Equatable, Error {
    let category: InstallerFailureCategory
    /// This is deliberately not replaced with a generic setup message. The UI can present the exact
    /// vendor detail and the user can act on a DNS, permission, or HTTP diagnosis.
    let message: String

    var isRetryable: Bool {
        switch category {
        case .transport, .server: return true
        case .invalidPlan, .process, .client, .checksumMismatch: return false
        }
    }
}

enum InstallerComponentState: Equatable {
    case installed
    case failed(InstallerFailure, attempts: Int)
}

struct InstallerComponentResult: Equatable {
    let componentID: String
    let title: String
    let state: InstallerComponentState

    var succeeded: Bool {
        if case .installed = state { return true }
        return false
    }

    var attempts: Int {
        if case .failed(_, let count) = state { return count }
        return 1
    }
}

/// The retry rule left open as O5: three total attempts with backoff, but only for transport failures
/// and HTTP 5xx. A 4xx is an actionable request/credential/repository problem, and a hash mismatch is
/// a trust failure; neither is retried automatically.
enum InstallerRetryPolicy {
    static let maxAttempts = 3
    static let backoffSeconds: [TimeInterval] = [1, 2]

    static func delayBeforeAttempt(_ attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let index = min(attempt - 2, backoffSeconds.count - 1)
        return backoffSeconds[index]
    }

    static func shouldRetry(_ failure: InstallerFailure, attempt: Int) -> Bool {
        failure.isRetryable && attempt < maxAttempts
    }
}

struct InstallerPaths: Equatable {
    let python: URL
    let applicationSupport: URL
    let modelCache: URL
    /// pip's own download and wheel cache, kept beside the model cache rather than left in
    /// `~/Library/Caches/pip`. Two reasons, both of them the engine's own goals: B10's resume works off
    /// a cache that survives a failed attempt, and a cache the app owns is one whose growth is the
    /// honest byte source for B7's per-row progress (see `InstallProgress`).
    let packageCache: URL

    static var live: InstallerPaths {
        let support = AppPaths.applicationSupportDirectory()
        return InstallerPaths(
            python: BundledPython.interpreterURL,
            applicationSupport: support,
            modelCache: support.appendingPathComponent("model-cache", isDirectory: true),
            packageCache: support.appendingPathComponent("package-cache", isDirectory: true))
    }
}

/// Headless, data-driven first-run installer engine.
///
/// This type deliberately owns no AppKit state and performs no UI work. Call its synchronous methods
/// off the main thread; `installAllAsync` is a convenience for the future picker. Each descriptor is
/// converted to a result, never thrown out of the queue, so one failed row cannot stop its siblings.
final class InstallerEngine {
    typealias Sleep = (TimeInterval) -> Void

    private struct CommandOutcome {
        let result: InstallerCommandResult
        let attempts: Int
    }

    private struct AttemptedFailure: Error {
        let failure: InstallerFailure
        let attempts: Int
    }

    private let paths: InstallerPaths
    private let runner: InstallerProcessRunning
    private let sleep: Sleep
    private let fileManager: FileManager
    private let environment: [String: String]

    init(paths: InstallerPaths = .live,
         runner: InstallerProcessRunning = FoundationInstallerProcessRunner(),
         sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
         fileManager: FileManager = .default) {
        self.paths = paths
        self.runner = runner
        self.sleep = sleep
        self.fileManager = fileManager
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HOME"] = paths.modelCache.path
        environment["HUGGINGFACE_HUB_CACHE"] = paths.modelCache.appendingPathComponent("hub").path
        environment["PIP_CACHE_DIR"] = paths.packageCache.path
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        self.environment = environment
    }

    /// Install one row. The row's result retains the final real error and the number of command
    /// attempts used; no error is swallowed into a generic "setup failed" string.
    func install(_ descriptor: InstallerComponentDescriptor) -> InstallerComponentResult {
        var attempts = 0
        do {
            try validate(descriptor)
            try fileManager.createDirectory(at: paths.applicationSupport,
                                             withIntermediateDirectories: true)
            let venv = paths.applicationSupport
                .appendingPathComponent(descriptor.virtualEnvironmentRelativePath, isDirectory: true)
            let venvPython = venv.appendingPathComponent("bin/python", isDirectory: false)
            if !fileManager.isExecutableFile(atPath: venvPython.path) {
                let outcome = try runWithRetry(
                    executable: paths.python,
                    arguments: ["-m", "venv", venv.path])
                attempts += outcome.attempts
                guard outcome.result.succeeded else {
                    throw failure(for: outcome.result)
                }
                guard fileManager.isExecutableFile(atPath: venvPython.path) else {
                    throw InstallerFailure(
                        category: .process,
                        message: "python -m venv completed, but the environment has no executable at "
                            + venvPython.path)
                }
            }

            if !descriptor.packages.isEmpty {
                let outcome = try runWithRetry(
                    executable: venvPython,
                    arguments: Self.pipArguments(for: descriptor.packages))
                attempts += outcome.attempts
                guard outcome.result.succeeded else {
                    throw failure(for: outcome.result)
                }
            }

            for artifact in descriptor.modelArtifacts {
                try fileManager.createDirectory(at: paths.modelCache,
                                                 withIntermediateDirectories: true)
                let outcome = try runWithRetry(
                    executable: venvPython,
                    arguments: Self.modelDownloadArguments(for: artifact,
                                                           cacheDirectory: paths.modelCache))
                attempts += outcome.attempts
                guard outcome.result.succeeded else {
                    throw failure(for: outcome.result)
                }
                if artifact.verifyPublishedHashes {
                    guard Self.snapshotPath(from: outcome.result.stdout, inside: paths.modelCache) != nil,
                          outcome.result.stdout.contains("VIDDYDICTATE_HASHES=") else {
                        throw InstallerFailure(
                            category: .checksumMismatch,
                            message: "huggingface_hub did not return its published SHA-256 manifest")
                    }
                }
                try verifyExpectedFiles(artifact.expectedFiles,
                                        snapshotRoot: Self.snapshotPath(from: outcome.result.stdout,
                                                                        inside: paths.modelCache))
            }

            return InstallerComponentResult(componentID: descriptor.id, title: descriptor.title,
                                            state: .installed)
        } catch let error as AttemptedFailure {
            return InstallerComponentResult(componentID: descriptor.id, title: descriptor.title,
                                            state: .failed(error.failure, attempts: error.attempts))
        } catch let error as InstallerFailure {
            return InstallerComponentResult(componentID: descriptor.id, title: descriptor.title,
                                            state: .failed(error, attempts: max(1, attempts)))
        } catch {
            let failure = InstallerFailure(category: .process, message: String(describing: error))
            return InstallerComponentResult(componentID: descriptor.id, title: descriptor.title,
                                            state: .failed(failure, attempts: max(1, attempts)))
        }
    }

    /// Install all rows in order, collecting every outcome. A failed descriptor is not a reason to
    /// skip the next descriptor: B10's failure boundary is one row.
    func installAll(_ descriptors: [InstallerComponentDescriptor]) -> [InstallerComponentResult] {
        descriptors.map(install)
    }

    func installAllAsync(_ descriptors: [InstallerComponentDescriptor],
                         completion: @escaping ([InstallerComponentResult]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.installAll(descriptors))
        }
    }

    /// Kept public to the same module so the deterministic self-test can pin the actual command shape:
    /// pip keeps its wheel cache and own resume/retry implementation, and the model path goes through
    /// huggingface_hub rather than a hand-written HTTP downloader.
    static func pipArguments(for packages: [InstallerPackage]) -> [String] {
        ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "--no-input",
         "--retries", String(InstallerRetryPolicy.maxAttempts), "--timeout", "30"]
            + packages.map(\.pipRequirement)
    }

    static func modelDownloadArguments(for artifact: InstallerModelArtifact,
                                       cacheDirectory: URL) -> [String] {
        var revisionLine = ""
        if let revision = artifact.revision {
            revisionLine = "revision=\(pythonString(revision)), "
        }
        let verifyLine = artifact.verifyPublishedHashes ? publishedHashVerification : ""
        let script = """
        from huggingface_hub import HfApi, snapshot_download
        import hashlib, json, pathlib, sys
        repo = \(pythonString(artifact.repository))
        cache = \(pythonString(cacheDirectory.path))
        siblings = HfApi().model_info(repo_id=repo, \(revisionLine)).siblings
        published = {}
        for sibling in siblings:
            lfs = getattr(sibling, "lfs", None)
            value = lfs.get("sha256") if isinstance(lfs, dict) else getattr(lfs, "sha256", None)
            if value:
                published[sibling.rfilename] = value
        snapshot_root = snapshot_download(repo_id=repo, \(revisionLine)cache_dir=cache)
        \(verifyLine)
        print("VIDDYDICTATE_SNAPSHOT=" + str(snapshot_root))
        print("VIDDYDICTATE_HASHES=" + json.dumps(published, sort_keys=True))
        """
        return ["-c", script]
    }

    /// Streaming SHA-256 keeps a large model out of memory while checking its published digest.
    static func sha256(ofFileAt url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw InstallerFailure(category: .checksumMismatch,
                                   message: "model file is not readable: \(url.path)")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func runWithRetry(executable: URL, arguments: [String]) throws -> CommandOutcome {
        var attempt = 1
        while true {
            if attempt > 1 { sleep(InstallerRetryPolicy.delayBeforeAttempt(attempt)) }
            let result = runner.run(executable: executable, arguments: arguments,
                                    environment: environment, timeout: 30 * 60)
            if result.succeeded { return CommandOutcome(result: result, attempts: attempt) }
            let failure = failure(for: result)
            if !InstallerRetryPolicy.shouldRetry(failure, attempt: attempt) {
                throw AttemptedFailure(failure: failure, attempts: attempt)
            }
            attempt += 1
        }
    }

    private func validate(_ descriptor: InstallerComponentDescriptor) throws {
        guard !descriptor.id.isEmpty, !descriptor.title.isEmpty,
              Self.isSafeRelativePath(descriptor.virtualEnvironmentRelativePath) else {
            throw InstallerFailure(category: .invalidPlan,
                                   message: "installer component has an invalid identity or venv path")
        }
        let packageNames = descriptor.packages.map(\.name)
        guard descriptor.packages.allSatisfy({ !$0.name.isEmpty && !$0.pipRequirement.contains("\n") }),
              Set(packageNames).count == packageNames.count else {
            throw InstallerFailure(category: .invalidPlan,
                                   message: "installer component has an invalid or duplicate package")
        }
        for artifact in descriptor.modelArtifacts {
            guard !artifact.repository.isEmpty else {
                throw InstallerFailure(category: .invalidPlan,
                                       message: "model artifact has no repository")
            }
            for expected in artifact.expectedFiles {
                guard Self.isSafeRelativePath(expected.relativePath), Self.isSHA256(expected.sha256) else {
                    throw InstallerFailure(category: .invalidPlan,
                                           message: "model artifact has an invalid published hash entry")
                }
            }
        }
    }

    private func verifyExpectedFiles(_ expected: [InstallerModelFile], snapshotRoot: URL?) throws {
        guard !expected.isEmpty else { return }
        guard let snapshotRoot else {
            throw InstallerFailure(category: .checksumMismatch,
                                   message: "model download did not identify its snapshot directory")
        }
        for entry in expected {
            let url = snapshotRoot.appendingPathComponent(entry.relativePath)
            let actual = try Self.sha256(ofFileAt: url, fileManager: fileManager)
            guard actual.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                throw InstallerFailure(
                    category: .checksumMismatch,
                    message: "SHA-256 mismatch for \(entry.relativePath): expected \(entry.sha256), "
                        + "got \(actual)")
            }
        }
    }

    private func failure(for result: InstallerCommandResult) -> InstallerFailure {
        let output = result.output
        if output.contains("VIDDYDICTATE_HASH_MISMATCH") {
            return InstallerFailure(category: .checksumMismatch, message: output)
        }
        if let status = Self.httpStatus(in: output) {
            if (500...599).contains(status) {
                return InstallerFailure(category: .server(status), message: output)
            }
            if (400...499).contains(status) {
                return InstallerFailure(category: .client(status), message: output)
            }
        }
        if result.timedOut || Self.looksLikeTransportFailure(output) {
            return InstallerFailure(category: .transport, message: output)
        }
        return InstallerFailure(category: .process, message: output)
    }

    private static func httpStatus(in text: String) -> Int? {
        let pattern = #"(?i)(?:HTTP(?:/\d(?:\.\d)?)?(?:\s+error)?|status(?:\s+code)?|response)\s*[:=]?\s+([45]\d\d)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func looksLikeTransportFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["could not resolve host", "name or service not known", "network is unreachable",
                "connection reset", "connection refused", "connection aborted", "temporary failure",
                "timed out", "timeout", "dns", "tls", "ssl", "socket error", "urlsession"]
            .contains { lower.contains($0) }
    }

    private static func snapshotPath(from output: String, inside cache: URL) -> URL? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("VIDDYDICTATE_SNAPSHOT=") })
        else { return nil }
        let path = String(line.dropFirst("VIDDYDICTATE_SNAPSHOT=".count))
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = cache.standardizedFileURL.path
        return candidate.path == root || candidate.path.hasPrefix(root + "/") ? candidate : nil
    }

    private static func pythonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            guard let lowered = String(scalar).lowercased().unicodeScalars.first else { return false }
            return "0123456789abcdef".unicodeScalars.contains(lowered)
        }
    }

    private static let publishedHashVerification = """
        if not published:
            print("huggingface_hub returned no published SHA-256 values", file=sys.stderr)
            raise SystemExit(1)
        for filename, expected in published.items():
            path = pathlib.Path(snapshot_root, filename)
            if not path.is_file():
                print("VIDDYDICTATE_HASH_MISMATCH missing=" + filename, file=sys.stderr)
                raise SystemExit(42)
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            actual = digest.hexdigest()
            if actual.lower() != expected.lower():
                print("VIDDYDICTATE_HASH_MISMATCH file=" + filename + " expected=" + expected
                      + " actual=" + actual, file=sys.stderr)
                raise SystemExit(42)
        """
}
