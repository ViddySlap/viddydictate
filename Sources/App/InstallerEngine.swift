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
    /// `false` installs this package with `--no-deps`, which means the descriptor - not pip - now
    /// owns its dependency closure. B20's whole reasoning is that this is the dangerous spelling: it
    /// installs cleanly, runs cleanly on the tested path, and throws an `ImportError` months later on
    /// a stranger's machine. So a package that opts out of resolution MUST carry `importCheck`.
    let resolvesDependencies: Bool
    /// The module that proves this package's closure is actually complete, imported in the finished
    /// environment right after pip returns. This is what converts the `--no-deps` risk from a silent
    /// runtime failure into a loud install-time one, in the row that caused it, with pip's real error
    /// text - which is the same rule B10 applies to every other failure.
    let importCheck: String?

    init(name: String, versionConstraint: String = "",
         resolvesDependencies: Bool = true, importCheck: String? = nil) {
        self.name = name
        self.versionConstraint = versionConstraint
        self.resolvesDependencies = resolvesDependencies
        self.importCheck = importCheck
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

/// One bounded local-app operation a descriptor performs, expressed as DATA for the same reason the
/// package list is: adding a model row is one entry in a list, not a second installer.
///
/// The mechanisms stay in `LMStudioInstaller` and `OllamaInstaller`, which own the DMG verification, the
/// `lms` delegation and the `/api/pull` stream, and deliberately own no queue, retry policy, or persistence.
/// This enum is the only thing that binds them to the engine, so there is one engine driving every row
/// rather than a python queue beside a queue per local app.
enum InstallerLocalStep: Equatable {
    /// Acquire, verify, and install the app itself. Never overwrites an existing install.
    case app(LocalBackendID)
    /// Make the app usable by the steps after it. LM Studio: its `lms` CLI exists, which only happens once
    /// the app has been opened (a fresh install has none, and a model row used to fail on it). Ollama: its
    /// server answers, which on a fresh install waits for the user to approve a macOS prompt.
    case ready(LocalBackendID)
    /// Acquire one exact model through its app: `lms get` for LM Studio, a streamed `/api/pull` for Ollama.
    case model(LocalModelRef)

    var backend: LocalBackendID {
        switch self {
        case .app(let backend), .ready(let backend): return backend
        case .model(let ref): return ref.backend
        }
    }
}

/// One independent row in the first-run bootstrap queue.
///
/// The engine has one execution shape for every descriptor: create/reuse the venv, install the
/// descriptor's package list, download and verify its model artifacts, then run its local-app steps.
/// An empty list (or a nil venv path) means the step is not part of that row; it does not create a
/// hidden hardcoded special case.
struct InstallerComponentDescriptor: Equatable {
    let id: String
    let title: String
    let detail: String
    /// nil for a row that owns no python environment at all - a local-app row. Required whenever the
    /// row installs packages or downloads model artifacts, because both run through the venv.
    let virtualEnvironmentRelativePath: String?
    let packages: [InstallerPackage]
    let modelArtifacts: [InstallerModelArtifact]
    let localSteps: [InstallerLocalStep]
    /// What this row costs to download, MEASURED, or nil when nobody has measured it. Never a guess:
    /// O1 is explicit that an estimate must not ship as a user-facing byte count, so a nil here makes
    /// every surface omit the number rather than invent one.
    let downloadBytes: Int64?

    init(id: String, title: String, detail: String = "",
         virtualEnvironmentRelativePath: String? = nil,
         packages: [InstallerPackage] = [], modelArtifacts: [InstallerModelArtifact] = [],
         localSteps: [InstallerLocalStep] = [],
         downloadBytes: Int64? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.virtualEnvironmentRelativePath = virtualEnvironmentRelativePath
        self.packages = packages
        self.modelArtifacts = modelArtifacts
        self.localSteps = localSteps
        self.downloadBytes = downloadBytes
    }
}

/// The first two rows owned by the headless installer. Later links can add UI and additional model
/// rows by consuming these descriptors; they do not need to invent another package command.
enum BootstrapInstallPlan {
    /// mlx-whisper installed WITHOUT its declared dependencies, because exactly one of them - torch -
    /// is 106 MiB of wheel and 638 MiB on disk that the shipped runtime never executes.
    ///
    /// This is B20's cut, and it ships only because `scripts/torch-free-proof.py` passed 48/48 on a
    /// Metal-capable Mac: `torch_whisper.py` is the sole module in the package that imports torch and
    /// nothing in the package imports it, so the reachable surface is torch-free; all three checkpoint
    /// formats `load_models.load_model` can reach (safetensors, npz, quantized) load and transcribe
    /// real speech; and all 18 of the daemon's control cases answer correctly over HTTP.
    ///
    /// `importCheck` is the guard on the risk this creates. Naming the closure here means a future
    /// mlx-whisper that adds a dependency would otherwise install cleanly and fail at transcribe time;
    /// instead the row fails at install time with pip's own error.
    static let mlxWhisper = InstallerPackage(name: "mlx-whisper", versionConstraint: "~=0.4.3",
                                             resolvesDependencies: false,
                                             importCheck: "mlx_whisper")
    /// mlx-whisper's own `Requires-Dist` list, measured from the 0.4.3 wheel, minus torch. Each of
    /// these still resolves its OWN dependencies normally, so the `--no-deps` blast radius is exactly
    /// one package rather than the whole tree.
    static let mlxWhisperDependencies = [
        InstallerPackage(name: "mlx", versionConstraint: ">=0.11"),
        InstallerPackage(name: "numba"),
        InstallerPackage(name: "numpy"),
        InstallerPackage(name: "tqdm"),
        InstallerPackage(name: "more-itertools"),
        InstallerPackage(name: "tiktoken"),
        InstallerPackage(name: "huggingface_hub"),
        InstallerPackage(name: "scipy"),
    ]
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
        packages: mlxWhisperDependencies + [mlxWhisper],
        modelArtifacts: [whisperModel])

    static let webSearch = InstallerComponentDescriptor(
        id: "web-search",
        title: "Web search",
        detail: "The local search helper used by Option+L",
        virtualEnvironmentRelativePath: "web-search-venv",
        packages: [ddgs])

    static let mandatoryCore = [sttDaemon, webSearch]

    /// LM Studio itself. It has no venv and no pip line: its whole execution is the DMG mechanism L3
    /// exposed, then one open so its CLI exists (see `InstallerLocalStep.ready`). Its download size is
    /// deliberately nil - the DMG's byte count is not known until its URL is resolved at run time (O4), and
    /// quoting a guess is exactly what O1 forbids.
    static let lmStudio = InstallerComponentDescriptor(
        id: "lm-studio",
        title: "LM Studio",
        detail: "The local model runner the optional modes use",
        localSteps: [.app(.lmStudio), .ready(.lmStudio)])

    /// Ollama itself, the advanced option (spec D3). The same trust-checked DMG flow as LM Studio, then a wait
    /// for its server, which on a fresh install waits for the user to approve Ollama's macOS prompt. Its
    /// size is nil for the same reason LM Studio's is. Added in the Ollama lane; the id is new, so no
    /// existing `bootstrap.json` row changes meaning.
    static let ollama = InstallerComponentDescriptor(
        id: "ollama",
        title: "Ollama",
        detail: "The advanced local model runner, installed from Ollama's own download",
        localSteps: [.app(.ollama), .ready(.ollama)])

    /// One model row for either app. The app is made ready first, so a model row works whether it follows
    /// the app's install in the same queue, or is queued on its own against an app that is installed but
    /// was never opened (LM Studio) or is not running (Ollama).
    ///
    /// This is the mechanism for Ollama's models (`ollamaGemma`, `ollamaQwen` below), each listed in
    /// `allComponents` so the durable state tracks it.
    static func localModel(_ ref: LocalModelRef, title: String? = nil, detail: String,
                           downloadBytes: Int64?) -> InstallerComponentDescriptor {
        InstallerComponentDescriptor(
            id: componentID(for: ref),
            title: title ?? ref.modelID,
            detail: detail,
            localSteps: [.ready(ref.backend), .model(ref)],
            downloadBytes: downloadBytes)
    }

    /// A model row's durable id. LM Studio keeps 1.1.0's `model:<id>`, which is already on users' disks in
    /// `bootstrap.json`; Ollama's gets its own prefix so the same model id on both apps is two rows.
    static func componentID(for ref: LocalModelRef) -> String {
        switch ref.backend {
        case .lmStudio: return "model:\(ref.modelID)"
        case .ollama: return "ollama-model:\(ref.modelID)"
        }
    }

    /// The two optional local models, by the exact identifiers O3 resolved. `downloadBytes` is MEASURED,
    /// not estimated: `lms ls --llm --json` reported these `sizeBytes` for the two model keys on
    /// 2026-08-27, which is the same measurement O1 asks for and the same figure the component picker
    /// row carries. If the picker ships its own copy of these numbers, collapse the two into this
    /// descriptor rather than keeping a second owner - the spec's "~4 GB" for gemma was out by 1.7x, and
    /// the way that gets found again is two places disagreeing.
    static let gemma = localModel(
        LocalModelRef(backend: .lmStudio, modelID: LMStudioInstaller.gemmaModelID),
        detail: "The local model email mode runs on",
        downloadBytes: 6_861_935_454)

    static let qwen = localModel(
        LocalModelRef(backend: .lmStudio, modelID: LMStudioInstaller.qwenModelID),
        detail: "The local model cleanup and prompt prep prefer",
        downloadBytes: 17_190_793_452)

    /// D4's model families on Ollama (agreed 2026-09-30): the cleanup, prompt-prep and search-retrieval model,
    /// and the email and search-synthesis one, which also reads images and so covers the vision helper. The
    /// tags are the Ollama library's, confirmed by the lane's Mac probe. How the pickers LABEL a pick
    /// is a separate, still-open part of D4, and nothing here names one.
    static let ollamaEmailModelID = "gemma4:e4b"
    static let ollamaCleanupModelID = "qwen3-coder:30b"

    /// The first-run window's Ollama model rows (D8). Sized from the picker's own catalog, so the queue row and
    /// the picker row can never quote two numbers for one download.
    static let ollamaGemma = localModel(
        LocalModelRef(backend: .ollama, modelID: ollamaEmailModelID),
        detail: "The local model email mode and web answers run on, in Ollama",
        downloadBytes: ComponentPicker.SizeCatalog.measured.ollamaGemma.flatMap { Int64(exactly: $0) })

    static let ollamaQwen = localModel(
        LocalModelRef(backend: .ollama, modelID: ollamaCleanupModelID),
        detail: "The local model cleanup and prompt prep prefer, in Ollama",
        downloadBytes: ComponentPicker.SizeCatalog.measured.ollamaQwen.flatMap { Int64(exactly: $0) })

    /// LM Studio first: a model row cannot run before the CLI that fetches it exists. Ollama and then its two
    /// models are appended, so every existing row keeps its place in `bootstrap.json`.
    static let optionalLocalModels = [lmStudio, gemma, qwen, ollama, ollamaGemma, ollamaQwen]

    /// Every component the app can install, in one list. The durable bootstrap state is keyed off this,
    /// so a surface that installs an optional row records it in the same file the core rows use.
    static let allComponents = mandatoryCore + optionalLocalModels

    /// The user-facing entry point for installing a component. Keep this beside the descriptors so
    /// remedies name the same component the in-app installer presents, rather than drifting into a
    /// repository-only command that a DMG user cannot run.
    ///
    /// It names the Setup tab's real button by its constant, never a copied literal: the Setup tab has no
    /// per-row "Install now" for the core. True for the mandatory core only (its callers: the transcription
    /// engine and web search), because first-run setup always queues the core whatever else is picked (B2).
    static func installPrompt(for component: InstallerComponentDescriptor) -> String {
        "open Settings > Setup, choose \"\(FirstRunSetupPresenter.rerunTitle)\" and then "
            + "\(ComponentPicker.continueTitle) to install \(component.title)"
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

/// The engine's seam onto the local-app mechanisms. Production drives `LMStudioInstaller` and
/// `OllamaInstaller`; the deterministic rail injects a double, so no gate ever attaches a disk image,
/// writes to `/Applications`, opens an app, or spends a gigabyte of the tester's bandwidth to prove the queue works.
///
/// `report` carries what a running step is doing that its phase cannot say (`InstallerLocalActivity`):
/// real bytes from an Ollama pull, or the wait for Ollama's macOS prompt. It is never persisted.
protocol InstallerLocalPerforming {
    /// Acquire, verify, and install the app. An existing install is reported, never replaced.
    func installApplication(_ backend: LocalBackendID,
                            report: @escaping (InstallerLocalActivity) -> Void) throws
    /// Make the app usable by a model step (`InstallerLocalStep.ready`). Idempotent: an app that is already
    /// ready returns at once.
    func makeReady(_ backend: LocalBackendID, report: @escaping (InstallerLocalActivity) -> Void) throws
    func installModel(_ ref: LocalModelRef, report: @escaping (InstallerLocalActivity) -> Void) throws
}

/// The production adapter. It adds no policy of its own: resolution, verification, the no-overwrite
/// guard, the `lms` delegation and the pull all stay in the two installers, and retry/backoff stays in the
/// engine that calls this.
struct LiveInstallerLocalPerformer: InstallerLocalPerforming {
    let downloadDirectory: URL
    private let fileManager: FileManager

    init(downloadDirectory: URL, fileManager: FileManager = .default) {
        self.downloadDirectory = downloadDirectory
        self.fileManager = fileManager
    }

    func installApplication(_ backend: LocalBackendID,
                            report: @escaping (InstallerLocalActivity) -> Void) throws {
        switch backend {
        case .lmStudio:
            // A per-attempt filename, because `downloadDMG` refuses to write over anything that already
            // exists - including a half-finished file from a previous attempt. The disk image is scratch:
            // it is removed whether the install succeeds or fails.
            let dmg = downloadDirectory
                .appendingPathComponent("LMStudio-\(UUID().uuidString).dmg", isDirectory: false)
            defer { try? fileManager.removeItem(at: dmg) }
            let source = try LMStudioInstaller.resolveOfficialDMG()
            _ = try LMStudioInstaller.downloadDMG(source: source, to: dmg)
            _ = try LMStudioInstaller.installDMG(at: dmg, expectedBytes: source.expectedBytes)
        case .ollama:
            let dmg = downloadDirectory
                .appendingPathComponent("Ollama-\(UUID().uuidString).dmg", isDirectory: false)
            defer { try? fileManager.removeItem(at: dmg) }
            let source = try OllamaInstaller.resolveOfficialDMG()
            _ = try OllamaInstaller.downloadDMG(source: source, to: dmg, fileManager: fileManager)
            _ = try OllamaInstaller.installDMG(at: dmg, expectedBytes: source.expectedBytes,
                                              fileManager: fileManager)
        }
    }

    func makeReady(_ backend: LocalBackendID, report: @escaping (InstallerLocalActivity) -> Void) throws {
        switch backend {
        case .lmStudio:
            _ = try LMStudioInstaller.ensureCLIReady(fileManager: fileManager)
        case .ollama:
            _ = try OllamaInstaller.ensureServerReady(onAwaitingApproval: { report(.awaitingApproval(.ollama)) })
        }
    }

    func installModel(_ ref: LocalModelRef, report: @escaping (InstallerLocalActivity) -> Void) throws {
        switch ref.backend {
        case .lmStudio:
            _ = try LMStudioInstaller.installModel(ref.modelID)
        case .ollama:
            _ = try OllamaInstaller.pullModel(ref.modelID, progress: { report(.bytes($0)) })
        }
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
    /// One install pass of the bundled transcription daemon. Injected so the deterministic rail never
    /// reaches the real home or the real launchd domain: production supplies `DaemonInstaller`,
    /// tests leave it nil.
    typealias DaemonInstallPerforming = () -> DaemonInstallResult
    /// Seam only (gap G-UNCHANGED): a hook that would ensure the whisperd agent is loaded and running,
    /// independent of what `daemonInstaller` reports. `install()` does not call it yet, so a
    /// `daemonInstaller` result of `.unchanged` still means exactly what it means at 42eec8e - the
    /// post-setup install path never re-arms an agent a launch-time write may have left unstarted. A
    /// later link wires this in for the `.unchanged` case.
    typealias DaemonAgentEnsureLoaded = () -> Void

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
    private let local: InstallerLocalPerforming
    private let sleep: Sleep
    private let fileManager: FileManager
    private let daemonInstaller: DaemonInstallPerforming?
    private let daemonAgentEnsureLoaded: DaemonAgentEnsureLoaded?
    private let environment: [String: String]

    init(paths: InstallerPaths = .live,
         runner: InstallerProcessRunning = FoundationInstallerProcessRunner(),
         local: InstallerLocalPerforming? = nil,
         sleep: @escaping Sleep = { Thread.sleep(forTimeInterval: $0) },
         fileManager: FileManager = .default,
         daemonInstaller: DaemonInstallPerforming? = nil,
         daemonAgentEnsureLoaded: DaemonAgentEnsureLoaded? = nil) {
        self.paths = paths
        self.runner = runner
        self.local = local ?? LiveInstallerLocalPerformer(
            downloadDirectory: paths.applicationSupport
                .appendingPathComponent("downloads", isDirectory: true),
            fileManager: fileManager)
        self.sleep = sleep
        self.fileManager = fileManager
        self.daemonInstaller = daemonInstaller
        self.daemonAgentEnsureLoaded = daemonAgentEnsureLoaded
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
    ///
    /// `activity` hears what a running local step reports (bytes, or the approval wait), on the calling
    /// thread, while the row runs. It is presentation only and never changes the result.
    func install(_ descriptor: InstallerComponentDescriptor,
                 activity: ((InstallerLocalActivity) -> Void)? = nil) -> InstallerComponentResult {
        var attempts = 0
        do {
            try validate(descriptor)
            try fileManager.createDirectory(at: paths.applicationSupport,
                                             withIntermediateDirectories: true)
            if let venvPath = descriptor.virtualEnvironmentRelativePath {
                let venv = paths.applicationSupport
                    .appendingPathComponent(venvPath, isDirectory: true)
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

                for arguments in Self.pipInvocations(for: descriptor.packages) {
                    let outcome = try runWithRetry(executable: venvPython, arguments: arguments)
                    attempts += outcome.attempts
                    guard outcome.result.succeeded else {
                        throw failure(for: outcome.result)
                    }
                }

                // The `--no-deps` guard. Not retried: a missing module is a resolution fact, not a
                // transport one, so O5's rule says trying twice more can only waste the user's time.
                for arguments in Self.importCheckArguments(for: descriptor.packages) {
                    let result = runner.run(executable: venvPython, arguments: arguments,
                                            environment: environment, timeout: 5 * 60)
                    attempts += 1
                    guard result.succeeded else {
                        throw InstallerFailure(
                            category: .process,
                            message: "the installed packages are incomplete: " + result.output)
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
            }

            // The daemon ships inside the app, so the STT row must also stage it into the user's home
            // and its LaunchAgent directory. Only the STT row does this, and only when production (or a
            // test that explicitly opts in) injected an installer: an engine built by a test has none,
            // so no existing selftest can write into a real home or poke a real launchd domain.
            if descriptor.id == BootstrapInstallPlan.sttDaemon.id, let daemonInstaller {
                switch daemonInstaller() {
                case .installed, .upgraded, .unchanged:
                    daemonAgentEnsureLoaded?()
                case .stagedWithoutAgent:
                    // The venv did not exist, so there is deliberately no plist to load yet. First-run
                    // setup builds the environment and calls this row again.
                    break
                case .failed(let daemonFailure):
                    throw InstallerFailure(category: .process, message: daemonFailure.message)
                }
            }

            for step in descriptor.localSteps {
                attempts += try runLocalWithRetry(step, report: activity ?? { _ in })
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
        descriptors.map { install($0) }
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
    static func pipArguments(for packages: [InstallerPackage],
                             resolvingDependencies: Bool = true) -> [String] {
        ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "--no-input",
         "--retries", String(InstallerRetryPolicy.maxAttempts), "--timeout", "30"]
            + (resolvingDependencies ? [] : ["--no-deps"])
            + packages.map(\.pipRequirement)
    }

    /// One pip command per resolution mode, because `--no-deps` is a property of the invocation and
    /// not of a requirement. The resolving group runs FIRST so the explicitly-named dependencies are
    /// already present when the `--no-deps` package lands; the reverse order would leave the
    /// environment correct only by the resolver's accident.
    static func pipInvocations(for packages: [InstallerPackage]) -> [[String]] {
        let resolving = packages.filter(\.resolvesDependencies)
        let pinned = packages.filter { !$0.resolvesDependencies }
        var invocations: [[String]] = []
        if !resolving.isEmpty { invocations.append(pipArguments(for: resolving)) }
        if !pinned.isEmpty {
            invocations.append(pipArguments(for: pinned, resolvingDependencies: false))
        }
        return invocations
    }

    /// `python -c "import <module>"` for every package that opted out of dependency resolution.
    /// Run after pip, in the environment pip just built, so an incomplete hand-owned closure fails the
    /// row it belongs to instead of surfacing as a dead daemon later.
    static func importCheckArguments(for packages: [InstallerPackage]) -> [[String]] {
        packages.compactMap(\.importCheck).map { ["-c", "import \($0)"] }
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
        siblings = HfApi().model_info(repo_id=repo, \(revisionLine)files_metadata=True).siblings
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

    /// `model_info` omits per-file `lfs` metadata unless it is asked for: without `files_metadata=True`
    /// every sibling comes back with `lfs = None`, so `published` is empty and the verification below
    /// aborts the row with "huggingface_hub returned no published SHA-256 values" AFTER the model has
    /// already been fetched. Measured cold against huggingface_hub 1.29.0 on 2026-08-27: the mandatory
    /// voice-model row downloaded 1.5 GiB and then failed on every install. Asking for the metadata is
    /// what makes the hash check real rather than vacuous.
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

    /// The local-app twin of `runWithRetry`. Same policy object, same three attempts, same backoff:
    /// O5's rule is a property of the engine, not of the transport, so an `lms get` or a pull that died on
    /// a dead socket is retried and a 404 is not.
    private func runLocalWithRetry(_ step: InstallerLocalStep,
                                   report: @escaping (InstallerLocalActivity) -> Void) throws -> Int {
        var attempt = 1
        while true {
            if attempt > 1 { sleep(InstallerRetryPolicy.delayBeforeAttempt(attempt)) }
            do {
                switch step {
                case .app(let backend): try local.installApplication(backend, report: report)
                case .ready(let backend): try local.makeReady(backend, report: report)
                case .model(let ref): try local.installModel(ref, report: report)
                }
                return attempt
            } catch {
                let failure = Self.failure(forLocal: error)
                if !InstallerRetryPolicy.shouldRetry(failure, attempt: attempt) {
                    throw AttemptedFailure(failure: failure, attempts: attempt)
                }
                attempt += 1
            }
        }
    }

    /// Classify a local-app failure by the installer that threw it.
    static func failure(forLocal error: Error) -> InstallerFailure {
        if let ollamaError = error as? OllamaInstaller.InstallerError {
            return failure(forOllama: ollamaError)
        }
        return failure(forLMStudio: error)
    }

    /// Ollama's errors through the same rule as LM Studio's. Two are Ollama's own:
    /// - an unanswered macOS prompt is `.process`, never retried: the engine asking again would only put the
    ///   same question to a user who is not there, and the message already says what to do;
    /// - a pull that ended early is `.transport`, retried: Ollama resumes the blobs it already has. A pull
    ///   stalled for the whole idle bound is not, since two more full bounds would be most of an hour.
    static func failure(forOllama error: OllamaInstaller.InstallerError) -> InstallerFailure {
        let message = error.description
        switch error {
        case .network, .pullIncomplete:
            return InstallerFailure(category: .transport, message: message)
        case .httpStatus(let status):
            if (500...599).contains(status) {
                return InstallerFailure(category: .server(status), message: message)
            }
            return InstallerFailure(category: .client(status), message: message)
        case .invalidPublishedResponse, .invalidDMG, .invalidMountedImage, .invalidApplication:
            return InstallerFailure(category: .checksumMismatch, message: message)
        case .invalidModelIdentifier:
            return InstallerFailure(category: .invalidPlan, message: message)
        case .command(_, let result):
            let classified = InstallerCommandResult(
                exitCode: result.status, stdout: result.stdout, stderr: result.stderr)
            return InstallerFailure(category: Self.category(forOutput: classified.output), message: message)
        case .pullFailed(_, let reason):
            return InstallerFailure(category: Self.category(forOutput: reason), message: message)
        case .destinationExists, .approvalTimedOut, .serverNotRunning, .pullStalled, .operation:
            return InstallerFailure(category: .process, message: message)
        }
    }

    /// Classify an LM Studio failure through the SAME rule the pip and model-download rows use.
    ///
    /// A CLI failure is handed to `failure(for:)` as a command result rather than pattern-matched here,
    /// because "was this transport or a 4xx" is one question with one answer in this file. What this
    /// function decides is only the part `LMStudioInstaller` already answered with a typed case: a
    /// refused download endpoint, an unverifiable disk image, or a signature that did not check out is a
    /// TRUST failure, and repeating it three times cannot turn it into a pass.
    static func failure(forLMStudio error: Error) -> InstallerFailure {
        guard let installerError = error as? LMStudioInstaller.InstallerError else {
            return InstallerFailure(category: .process, message: String(describing: error))
        }
        let message = installerError.description
        switch installerError {
        case .network:
            return InstallerFailure(category: .transport, message: message)
        case .httpStatus(let status):
            if (500...599).contains(status) {
                return InstallerFailure(category: .server(status), message: message)
            }
            return InstallerFailure(category: .client(status), message: message)
        case .invalidPublishedResponse, .invalidDMG, .invalidMountedImage, .invalidApplication:
            return InstallerFailure(category: .checksumMismatch, message: message)
        case .invalidModelIdentifier:
            return InstallerFailure(category: .invalidPlan, message: message)
        case .command(_, let result):
            let classified = InstallerCommandResult(
                exitCode: result.status, stdout: result.stdout, stderr: result.stderr)
            return InstallerFailure(category: Self.category(forOutput: classified.output),
                                    message: message)
        case .commandLaunch, .destinationExists, .operation:
            return InstallerFailure(category: .process, message: message)
        }
    }

    private func validate(_ descriptor: InstallerComponentDescriptor) throws {
        guard !descriptor.id.isEmpty, !descriptor.title.isEmpty,
              descriptor.virtualEnvironmentRelativePath.map(Self.isSafeRelativePath) ?? true else {
            throw InstallerFailure(category: .invalidPlan,
                                   message: "installer component has an invalid identity or venv path")
        }
        // Packages and model artifacts both execute through the venv, so a row that asks for either
        // without one is a plan bug, not a runtime failure to discover halfway through a download.
        guard descriptor.virtualEnvironmentRelativePath != nil
                || (descriptor.packages.isEmpty && descriptor.modelArtifacts.isEmpty) else {
            throw InstallerFailure(
                category: .invalidPlan,
                message: "installer component has packages or model artifacts but no environment")
        }
        // A row that does nothing would report itself installed. That is the one outcome a first-run
        // queue must never produce, because every surface downstream reads "installed" as usable.
        guard descriptor.virtualEnvironmentRelativePath != nil || !descriptor.localSteps.isEmpty else {
            throw InstallerFailure(category: .invalidPlan,
                                   message: "installer component has no work to do")
        }
        for step in descriptor.localSteps {
            if case .model(let ref) = step, ref.modelID.isEmpty {
                throw InstallerFailure(category: .invalidPlan,
                                       message: "installer component has an empty model identifier")
            }
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
        if result.timedOut {
            return InstallerFailure(category: .transport, message: output)
        }
        return InstallerFailure(category: Self.category(forOutput: output), message: output)
    }

    /// O5's rule, in one place: a hash mismatch is a trust failure, an HTTP status decides itself, a
    /// recognizable transport symptom retries, and everything else is an ordinary non-retryable process
    /// failure. Shared by the pip/model rows and the LM Studio CLI rows so the two cannot drift.
    static func category(forOutput output: String) -> InstallerFailureCategory {
        if output.contains("VIDDYDICTATE_HASH_MISMATCH") { return .checksumMismatch }
        if let status = httpStatus(in: output) {
            if (500...599).contains(status) { return .server(status) }
            if (400...499).contains(status) { return .client(status) }
        }
        if looksLikeTransportFailure(output) { return .transport }
        return .process
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
        let data = try! JSONSerialization.data(withJSONObject: value,
                                               options: [.fragmentsAllowed, .withoutEscapingSlashes])
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
