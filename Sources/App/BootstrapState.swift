import Foundation

/// The durable lifecycle of first-run local setup.
///
/// There is deliberately one degraded state. A user who chooses Set up later and a user whose row
/// exhausts its retries both get the same reduced app and the same recovery path. The reason remains
/// on the failed row (or in `degradedDetail`) so the UI can be honest without inventing another state.
enum BootstrapLifecycle: String, Codable, Equatable {
    case idle
    case downloading
    case degraded
    case complete
}

/// A component is usable as soon as its own row reaches `installed`. The aggregate queue is not a gate:
/// an installed speech engine is available while a later row is still pending or downloading.
enum BootstrapComponentPhase: String, Codable, Equatable {
    case pending
    case installing
    case installed
    case failed
}

struct BootstrapComponentRecord: Codable, Equatable {
    let id: String
    let title: String
    var phase: BootstrapComponentPhase
    var attempts: Int
    var failureMessage: String?

    init(id: String, title: String,
         phase: BootstrapComponentPhase = .pending,
         attempts: Int = 0,
         failureMessage: String? = nil) {
        self.id = id
        self.title = title
        self.phase = phase
        self.attempts = max(0, attempts)
        self.failureMessage = failureMessage
    }

    var isUsable: Bool { phase == .installed }

    mutating func markInstalling() {
        phase = .installing
        failureMessage = nil
    }

    mutating func apply(_ result: InstallerComponentResult) {
        attempts = max(1, result.attempts)
        switch result.state {
        case .installed:
            phase = .installed
            failureMessage = nil
        case .failed(let failure, _):
            phase = .failed
            // Keep the vendor's real diagnostic. The B10 surface may bound it for a particular control,
            // but the lifecycle must not replace it with "Setup failed. Please try again.".
            failureMessage = failure.message
        }
    }
}

/// The complete first-run setup state. This is Foundation-only so the later picker and the point-of-use
/// panels can consume exactly the same state without making the installer depend on AppKit.
struct BootstrapSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let mandatoryCoreIDs = BootstrapInstallPlan.mandatoryCore.map(\.id)
    static let degradedBanner = "Local transcription is not installed - Resume setup"

    let version: Int
    let mandatoryComponentIDs: [String]
    var lifecycle: BootstrapLifecycle
    var components: [BootstrapComponentRecord]

    init(version: Int = BootstrapSnapshot.currentVersion,
         mandatoryComponentIDs: [String] = BootstrapSnapshot.mandatoryCoreIDs,
         lifecycle: BootstrapLifecycle = .idle,
         components: [BootstrapComponentRecord]) {
        self.version = version
        self.mandatoryComponentIDs = mandatoryComponentIDs
        self.lifecycle = lifecycle
        self.components = components
    }

    static func fresh(descriptors: [InstallerComponentDescriptor] = BootstrapInstallPlan.mandatoryCore)
        -> BootstrapSnapshot {
        BootstrapSnapshot(components: descriptors.map {
            BootstrapComponentRecord(id: $0.id, title: $0.title)
        })
    }

    var mandatoryCoreComplete: Bool {
        !mandatoryComponentIDs.isEmpty && mandatoryComponentIDs.allSatisfy { id in
            components.first(where: { $0.id == id })?.isUsable == true
        }
    }

    var isReduced: Bool { !mandatoryCoreComplete }

    /// B12: until the mandatory core is complete, setup reappears on every launch. Dismissing the window
    /// is not a durable opt-out and does not change this answer.
    var shouldPresentSetupOnLaunch: Bool { !mandatoryCoreComplete }

    /// The persistent banner is the recovery path for the single degraded state. During an active queue,
    /// the setup surface itself is the status surface; once deferred or failed, this banner is required.
    var persistentBanner: String? {
        lifecycle == .degraded && isReduced ? Self.degradedBanner : nil
    }

    var failedComponents: [BootstrapComponentRecord] {
        components.filter { $0.phase == .failed }
    }

    /// Content for a row or a detail panel. It is intentionally absent for cancellation, where there is no
    /// vendor error to quote; the exact banner still tells the user how to resume.
    var degradedDetail: String? {
        let details = failedComponents.compactMap { row -> String? in
            guard let message = row.failureMessage, !message.isEmpty else { return nil }
            return "\(row.title): \(message)"
        }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    func component(_ id: String) -> BootstrapComponentRecord? {
        components.first { $0.id == id }
    }

    func isComponentUsable(_ id: String) -> Bool {
        component(id)?.isUsable == true
    }

    mutating func beginDownload() {
        guard !mandatoryCoreComplete else {
            lifecycle = .complete
            return
        }
        // A retry starts the failed row over while retaining the other rows' real state. Installed rows
        // remain installed and are never needlessly re-downloaded.
        for index in components.indices where components[index].phase == .failed {
            components[index].phase = .pending
            components[index].attempts = 0
            components[index].failureMessage = nil
        }
        lifecycle = .downloading
    }

    mutating func markInstalling(componentID: String) {
        guard let index = components.firstIndex(where: { $0.id == componentID }) else { return }
        guard !components[index].isUsable else { return }
        components[index].markInstalling()
        if lifecycle != .degraded { lifecycle = .downloading }
    }

    /// Publish one row as soon as it completes, before the next descriptor is attempted.
    mutating func apply(_ result: InstallerComponentResult) {
        guard let index = components.firstIndex(where: { $0.id == result.componentID }) else { return }
        components[index].apply(result)
        if case .failed = result.state {
            lifecycle = .degraded
        } else if failedComponents.isEmpty && mandatoryCoreComplete {
            lifecycle = .complete
        } else if lifecycle != .degraded {
            lifecycle = .downloading
        }
    }

    /// B9 distinguishes closing the window from cancelling setup. This transition is only for the latter:
    /// the worker may finish its current process, but no future queue work should be required to reach the
    /// reduced state.
    mutating func cancel() {
        guard !mandatoryCoreComplete else { return }
        lifecycle = .degraded
    }
}

/// When the first-run setup window opens by itself at launch (spec D8, on top of B12).
///
/// **The rule:** it opens on a launch where the mandatory core is not installed, and never on a Mac where it
/// is. That is B12's `shouldPresentSetupOnLaunch`, kept: on a fresh Mac the first launch shows it, and it comes
/// back on later launches only while dictation still cannot transcribe, because this window is the one place
/// the core is installed from. Once the core lands it never opens by itself again (the Setup tab re-opens it).
///
/// **Upgrading users.** B12 alone reads `bootstrap.json`, and no 1.1.0 code path ever ran the core through the
/// install queue: a 1.1.0 Mac that dictates got its transcription environment from `install-daemon.sh`, into
/// the same Application Support folder, and its `bootstrap.json` (when it has one) still says the core is
/// pending. So a second persisted fact decides for a queue that has never touched the core: the environment an
/// earlier install left on disk. When the queue HAS run the core rows, its own record is the authority, so a
/// half-built environment from a failed attempt cannot hide the window.
enum FirstRunSetupLaunchRule {
    struct Facts: Equatable {
        /// `bootstrap.json` as the store read it (a missing file reads as fresh).
        var snapshot: BootstrapSnapshot
        /// `coreEnvironmentOnDisk`: an earlier install's speech-to-text environment is in Application Support.
        var earlierCoreOnDisk: Bool
    }

    static func shouldPresent(_ facts: Facts) -> Bool {
        guard facts.snapshot.shouldPresentSetupOnLaunch else { return false }
        if facts.earlierCoreOnDisk && !queueHasTouchedCore(facts.snapshot) { return false }
        return true
    }

    /// Whether the install queue has ever worked on a core row: an attempt counted, or a phase other than
    /// pending. A 1.1.0 `bootstrap.json` (or none) has neither.
    static func queueHasTouchedCore(_ snapshot: BootstrapSnapshot) -> Bool {
        snapshot.mandatoryComponentIDs.contains { id in
            guard let record = snapshot.component(id) else { return false }
            return record.attempts > 0 || record.phase != .pending
        }
    }

    /// The transcription environment an earlier install left: the venv's interpreter AND the `mlx_whisper`
    /// package in its site-packages. pip installs `mlx_whisper` last (after its dependencies), so a venv that
    /// has it finished its package step; an interpreter alone is a venv that was only begun. Files only - no
    /// process is run and the daemon is not asked anything, so the launch pays one directory listing.
    static func coreEnvironmentOnDisk(applicationSupport: URL,
                                      fileManager: FileManager = .default) -> Bool {
        guard let relative = BootstrapInstallPlan.sttDaemon.virtualEnvironmentRelativePath else { return false }
        let venv = applicationSupport.appendingPathComponent(relative, isDirectory: true)
        let python = venv.appendingPathComponent("bin/python", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: python.path) else { return false }
        let lib = venv.appendingPathComponent("lib", isDirectory: true)
        let versions = (try? fileManager.contentsOfDirectory(atPath: lib.path)) ?? []
        return versions.contains { version in
            guard version.hasPrefix("python") else { return false }
            var isDirectory: ObjCBool = false
            let package = lib.appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("site-packages/mlx_whisper", isDirectory: true)
            return fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

/// Atomic, app-local persistence for the bootstrap state. It stores no transcript, prompt, or provider
/// response - only component identities, phases, attempts, and bounded-by-the-row failure diagnostics.
final class BootstrapStateStore {
    typealias Writer = (Data, URL) throws -> Void
    static let fileName = "bootstrap.json"

    private let lock = NSLock()
    private let url: URL
    private let writer: Writer
    private var state: BootstrapSnapshot

    /// Defaults to EVERY shipped component, not just the mandatory core. The store rebuilds its row list
    /// from the descriptors it is handed, so two stores opened with different lists would take turns
    /// deleting each other's rows out of the same file. The mandatory SET is unchanged - it comes from
    /// `BootstrapSnapshot.mandatoryCoreIDs` - so what an optional row gains here is progress bookkeeping,
    /// never a vote on whether setup is complete.
    init(url: URL = AppPaths.applicationSupportDirectory()
            .appendingPathComponent(BootstrapStateStore.fileName, isDirectory: false),
         descriptors: [InstallerComponentDescriptor] = BootstrapInstallPlan.allComponents,
         writer: @escaping Writer = BootstrapStateStore.atomicWriter) {
        self.url = url
        self.writer = writer
        let fresh = BootstrapSnapshot.fresh(descriptors: descriptors)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(BootstrapSnapshot.self, from: data),
           decoded.version == BootstrapSnapshot.currentVersion {
            // The descriptor list is source-of-truth for names and the required core. Existing status is
            // kept field-for-field for known ids; a newly shipped row begins pending rather than guessing.
            let old = Dictionary(uniqueKeysWithValues: decoded.components.map { ($0.id, $0) })
            self.state = BootstrapSnapshot(
                mandatoryComponentIDs: decoded.mandatoryComponentIDs,
                lifecycle: decoded.lifecycle,
                components: descriptors.map { descriptor in
                    old[descriptor.id]
                        ?? BootstrapComponentRecord(id: descriptor.id, title: descriptor.title)
                })
        } else {
            // A malformed file is not overwritten. The in-memory fresh state lets setup remain usable and
            // leaves the original bytes recoverable for the user or a later migration.
            self.state = fresh
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            persist(fresh)
        }
    }

    static func atomicWriter(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func snapshot() -> BootstrapSnapshot {
        lock.withLock { state }
    }

    func beginDownload() { mutate { $0.beginDownload() } }
    func markInstalling(componentID: String) { mutate { $0.markInstalling(componentID: componentID) } }
    func apply(_ result: InstallerComponentResult) { mutate { $0.apply(result) } }
    func cancel() { mutate { $0.cancel() } }

    private func mutate(_ body: (inout BootstrapSnapshot) -> Void) {
        var published: BootstrapSnapshot?
        lock.lock()
        var candidate = state
        body(&candidate)
        do {
            let data = try JSONEncoder.bootstrap.encode(candidate)
            try writer(data, url)
            state = candidate
            published = candidate
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "bootstrap setup", operation: "save", url: url, error: error)
        }
        lock.unlock()
        // No callback is held by this store. The coordinator publishes after each mutation, and future UI
        // owners can observe the same snapshots without introducing caller code under the lock.
        _ = published
    }

    private func persist(_ value: BootstrapSnapshot) {
        do {
            let data = try JSONEncoder.bootstrap.encode(value)
            try writer(data, url)
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "bootstrap setup", operation: "initial save", url: url, error: error)
        }
    }
}

private extension JSONEncoder {
    static var bootstrap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// The queue owner used by the later setup UI. It publishes each completed component to durable state
/// before moving on, so installed features become usable individually. Closing the UI calls `dismiss()`;
/// that intentionally leaves the worker alone. "Set up later" calls `cancel()` and enters the one degraded
/// state. The engine itself remains headless and is not coupled to this lifecycle owner.
final class BootstrapInstallCoordinator {
    typealias SnapshotHandler = (BootstrapSnapshot) -> Void
    typealias Completion = ([InstallerComponentResult]) -> Void

    /// One queue for the whole app. The setup surface and the point-of-use install panel are two entry
    /// points into ONE installer, which is what B13 requires; two coordinators would be two queues that
    /// could run the same descriptor at the same time against the same venv.
    static let shared = BootstrapInstallCoordinator()

    /// Posted after every durable state change, so more than one surface can watch the same queue. The
    /// `onChange` closure remains for the single owner that constructed a coordinator itself.
    static let didChange = Notification.Name("ViddyDictate.bootstrapInstallDidChange")

    /// Posted when a running row reports activity (`activity(for:)`): real bytes from an Ollama pull, or the
    /// wait for Ollama's macOS prompt. Separate from `didChange` because nothing durable changed; at most a
    /// few times a second, since the pull throttles its own reports.
    static let didReportActivity = Notification.Name("ViddyDictate.bootstrapInstallDidReportActivity")

    private let engine: InstallerEngine
    private let store: BootstrapStateStore
    private let worker = DispatchQueue(label: AppIdentity.queueLabel("bootstrap-install"),
                                       qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var running = false
    private var setupPresented = false
    private var activities: [String: InstallerLocalActivity] = [:]
    private let onChange: SnapshotHandler?

    // Production supplies the daemon installer so the STT row also stages the bundled daemon into the
    // user's home. Tests pass their own engine (or none) and never reach the real home via this path.
    init(engine: InstallerEngine = InstallerEngine(
             daemonInstaller: { DaemonInstaller.installForCurrentUser() }),
         store: BootstrapStateStore = BootstrapStateStore(),
         onChange: SnapshotHandler? = nil) {
        self.engine = engine
        self.store = store
        self.onChange = onChange
    }

    var snapshot: BootstrapSnapshot { store.snapshot() }

    var isRunning: Bool { lock.withLock { running } }

    /// What the running row last reported, or nil when it reported nothing (or is not running). Cleared
    /// the moment the row finishes, so a finished row never shows a stale byte count or approval wait.
    func activity(for componentID: String) -> InstallerLocalActivity? {
        lock.withLock { activities[componentID] }
    }
    var isSetupPresented: Bool { lock.withLock { setupPresented } }

    @discardableResult
    func presentSetup() -> Bool {
        guard snapshot.shouldPresentSetupOnLaunch else { return false }
        lock.withLock { setupPresented = true }
        return true
    }

    /// B9: closing is not cancellation. The queue continues and components may go live in the background.
    func dismiss() {
        lock.withLock { setupPresented = false }
    }

    /// B11: cancellation is the same aggregate state as a three-attempt row failure.
    func cancel() {
        lock.withLock { cancelled = true; setupPresented = false }
        store.cancel()
        publish()
    }

    @discardableResult
    func start(descriptors: [InstallerComponentDescriptor] = BootstrapInstallPlan.mandatoryCore,
               completion: Completion? = nil) -> Bool {
        lock.lock()
        guard !running else {
            lock.unlock()
            return false
        }
        cancelled = false
        running = true
        lock.unlock()

        store.beginDownload()
        publish()
        let work = descriptors.filter { !snapshot.isComponentUsable($0.id) }
        worker.async { [weak self] in
            guard let self = self else { return }
            var results: [InstallerComponentResult] = []
            for descriptor in work {
                guard !self.isCancelled() else { break }
                self.store.markInstalling(componentID: descriptor.id)
                self.publish()
                let result = self.engine.install(descriptor) { activity in
                    self.lock.withLock { self.activities[descriptor.id] = activity }
                    NotificationCenter.default.post(name: Self.didReportActivity, object: self)
                }
                self.lock.withLock { self.activities[descriptor.id] = nil }
                results.append(result)
                self.store.apply(result)
                self.publish()
            }
            self.lock.withLock { self.running = false }
            completion?(results)
        }
        return true
    }

    private func isCancelled() -> Bool { lock.withLock { cancelled } }

    private func publish() {
        let current = store.snapshot()
        if current.lifecycle == .degraded {
            // B10: a terminal row failure turns the modal picker into the reduced-app banner state while
            // the worker is still allowed to finish independent rows.
            lock.withLock { setupPresented = false }
        }
        onChange?(current)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
