import Foundation

/// LM Studio as a `LocalModelBackend`: a thin adapter over the EXISTING `ModelResidency` CLI primitives and
/// the `LMStudioModelCatalog` parser, which it wraps unchanged. It adds no behaviour of its own; it only
/// maps LM Studio's types into the backend-neutral ones and refuses refs that name another backend.
///
/// The load goes through `ModelManager.CapacityDependencies.live.ensureLoaded`, never to the residency
/// primitive directly. `ModelCapacitySelfTest` pins `ModelManager.swift` as the only production file that
/// may reach LM Studio's load primitive, which is what keeps every cold load behind the capacity policy.
///
/// Every dependency is injected so the mapping can be driven from fixtures with no `lms` process at all.
/// Production uses `live`.
struct LMStudioBackend: LocalModelBackend {
    struct Dependencies {
        let isInstalled: () -> Bool
        let serverResponds: () -> Bool
        let installedCatalog: () -> [LMStudioInstalledModel]?
        let residentSnapshot: () -> [ModelResidency.ResidentModel]?
        let ensureLoaded: (String, Int) -> Bool
        let unload: (String) -> Void

        static let live = Dependencies(
            isInstalled: { ModelResidency.isInstalled },
            serverResponds: { ModelResidency.serverResponds() },
            installedCatalog: { ModelResidency.availableInstalledModels() },
            residentSnapshot: { ModelResidency.residentModels() },
            ensureLoaded: ModelManager.CapacityDependencies.live.ensureLoaded,
            unload: { ModelResidency.unload($0) })
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    var id: LocalBackendID { .lmStudio }

    func isInstalled() -> Bool { dependencies.isInstalled() }

    func serverResponds() -> Bool { dependencies.serverResponds() }

    func installedModels() -> [LocalInstalledModel]? {
        dependencies.installedCatalog()?.map(Self.installedModel(from:))
    }

    func residentModels() -> [LocalResidentModel]? {
        dependencies.residentSnapshot()?.map(Self.residentModel(from:))
    }

    /// LM Studio's load takes no context argument on this path today, so `contextTokens` is ignored: passing
    /// `--context-length` would change what every existing load does, which is not this adapter's call.
    func ensureLoaded(_ ref: LocalModelRef, ttlSeconds: Int, contextTokens: Int?) -> Bool {
        guard ref.backend == id else { return false }
        return dependencies.ensureLoaded(ref.modelID, ttlSeconds)
    }

    func unload(_ ref: LocalModelRef) {
        guard ref.backend == id else { return }
        dependencies.unload(ref.modelID)
    }

    /// The `llm` rows of the same `lms ls --llm --json` read, mapped exactly as `LMStudioModelCatalog.parse`
    /// maps them, so presence and routing see the list `ModelResidency.availableModels()` produced before
    /// backends existed: same rows, same order, same labels and sizes, a `vlm` row still excluded.
    func routableModelOptions() -> [LMStudioModelOption]? {
        dependencies.installedCatalog()?.compactMap(Self.routableOption(from:))
    }

    static func routableOption(from model: LMStudioInstalledModel) -> LMStudioModelOption? {
        guard model.type == "llm" else { return nil }
        return LMStudioModelOption(modelID: model.modelID, label: model.label, sizeBytes: model.sizeBytes)
    }

    /// Never started by observation. LM Studio's server comes up lazily through `lms server start` inside
    /// `ModelResidency.ensureLoaded`, exactly as in 1.1.0; this adapter does not add a second way.
    var backgroundLaunchPath: String? { nil }

    // MARK: - Pure mappings (the fixture seam)

    /// One `lms ls --llm --json` row. Vision is `isVisionCapable`, i.e. EITHER provider marker (`type ==
    /// "vlm"` or the boolean `vision` flag), for the reason `LMStudioModelCatalog.smallestVisionModel`
    /// documents. The catalog does not report tool or thinking capability, so both stay unanswered (nil).
    static func installedModel(from model: LMStudioInstalledModel) -> LocalInstalledModel {
        LocalInstalledModel(
            ref: LocalModelRef(backend: .lmStudio, modelID: model.modelID),
            label: model.label,
            sizeBytes: model.sizeBytes,
            isVision: model.isVisionCapable,
            supportsTools: nil,
            supportsThinking: nil)
    }

    /// One `lms ps --json` row. `lastUsedTime` is epoch milliseconds (as `LocalModelSetup.residencyTTL`
    /// reads it). LM Studio's TTL is idle-based, so the expiry is last use plus the TTL, and it is unknown
    /// while either half is missing (a generating model has no `lastUsedTime`; a GUI-loaded one no TTL).
    /// `ModelResidency.ResidentModel` carries no context length, so it is nil here rather than read through a
    /// second command that could describe a different resident set.
    static func residentModel(from model: ModelResidency.ResidentModel) -> LocalResidentModel {
        let lastUsed = model.lastUsedTime.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
        let expiresAt: Date?
        if let lastUsed, let ttl = model.ttlSeconds {
            expiresAt = lastUsed.addingTimeInterval(Double(ttl))
        } else {
            expiresAt = nil
        }
        return LocalResidentModel(
            ref: LocalModelRef(backend: .lmStudio, modelID: model.identifier),
            residentBytes: model.sizeBytes,
            lastUsed: lastUsed,
            isIdle: model.isIdle,
            expiresAt: expiresAt,
            contextLength: nil)
    }
}
