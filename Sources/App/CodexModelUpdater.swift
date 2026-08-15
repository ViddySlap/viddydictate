import Foundation

enum CodexModelUpdateStatus: Equatable {
    case current
    case held
    case catalogFailed(ModelCatalogDiagnostic)
    case persistenceFailed
    case coalesced
}

struct CodexModelUpdateOutcome: Equatable {
    let status: CodexModelUpdateStatus
    let checkedAt: String?
    let applied: [LLMRouteID]
    let skipped: [LLMRouteID]
    let held: [LLMRouteID]
    let recommendations: [LLMRouteID]
    let plannerHolds: [LLMRouteID: ModelMigrationHoldReason]
    var blockingPlannerHolds: [LLMRouteID] = []

    static let coalesced = CodexModelUpdateOutcome(
        status: .coalesced,
        checkedAt: nil,
        applied: [],
        skipped: [],
        held: [],
        recommendations: [],
        plannerHolds: [:])

    var scheduleCompletion: CodexModelUpdateScheduleCompletion {
        switch status {
        case .current: return .success
        case .coalesced: return .coalesced
        case .held:
            return held.isEmpty && blockingPlannerHolds.isEmpty ? .success : .failure
        case .catalogFailed, .persistenceFailed:
            return .failure
        }
    }
}

/// Application adapter driving one `ModelCatalogSource` through discover -> plan -> qualify ->
/// compare-and-swap. Catalog source, prompt audit, synthetic smoke, clock, and settings persistence
/// are all injected. The only production inputs admitted to qualification are the exact opaque
/// target model/effort pair and fixed source-owned synthetic bytes.
///
/// The loop below is provider-neutral, but persistence is not yet: `compareAndSwapCodexBundles`
/// also maintains the snapshot's `codexDefaults`, which has no counterpart for another provider.
/// That is the next seam to cut, and cutting it changes the persisted schema, so this type stays
/// Codex-scoped and reads Codex bundles explicitly rather than pretending otherwise.
final class CodexModelUpdater {
    typealias PromptAudit =
        (_ qualification: ModelQualification) -> CodexModelPromptAuditReceipt?
    typealias Smoke =
        (_ qualification: ModelQualification,
         _ receipt: CodexModelPromptAuditReceipt) -> Bool
    typealias Clock = () -> Date

    static let shared = CodexModelUpdater()

    private let inFlightLock = NSLock()
    private var inFlight = false
    private let settings: ModelsPowerSettingsStore
    private let source: ModelCatalogSource
    private let promptAudit: PromptAudit
    private let smoke: Smoke
    private let now: Clock

    init(
        settings: ModelsPowerSettingsStore = Settings.modelsPower,
        source: ModelCatalogSource = CodexModelCatalogSource(),
        promptAudit: @escaping PromptAudit = {
            CodexProviderRuntime.auditModelQualification(
                model: $0.model, effort: $0.effort)
        },
        smoke: @escaping Smoke = {
            CodexProviderRuntime.smokeModelQualification(
                model: $0.model, effort: $0.effort, auditReceipt: $1)
        },
        now: @escaping Clock = Date.init
    ) {
        self.settings = settings
        self.source = source
        self.promptAudit = promptAudit
        self.smoke = smoke
        self.now = now
    }

    func run() -> CodexModelUpdateOutcome {
        inFlightLock.lock()
        guard !inFlight else {
            inFlightLock.unlock()
            return .coalesced
        }
        inFlight = true
        inFlightLock.unlock()
        defer {
            inFlightLock.lock()
            inFlight = false
            inFlightLock.unlock()
        }

        let checkedAt = ModelFreshnessProbe.checkedAtString(now())
        let routes: [(route: LLMRouteID, bundle: LLMProviderBundle)] =
            settings.routeIDs().compactMap { route in
                settings.rememberedBundle(for: .codex, route: route)
                    .map { (route: route, bundle: $0) }
            }
        let refreshed = source.discover(checkedAt: checkedAt)
        guard !refreshed.isStale,
              refreshed.diagnostic == .current,
              let catalog = refreshed.catalog else {
            return CodexModelUpdateOutcome(
                status: .catalogFailed(refreshed.diagnostic),
                checkedAt: checkedAt,
                applied: [],
                skipped: [],
                held: [],
                recommendations: [],
                plannerHolds: [:])
        }

        let plan = source.plan(
            requests: routes.map {
                ModelMigrationRequest(
                    model: $0.bundle.modelID,
                    effort: $0.bundle.effort)
            },
            catalog: catalog)
        var accepted: [ModelQualification: Bool] = [:]
        for qualification in plan.qualifications {
            guard let receipt = promptAudit(qualification),
                  receipt.model == qualification.model,
                  receipt.effort == qualification.effort else {
                accepted[qualification] = false
                continue
            }
            accepted[qualification] = smoke(qualification, receipt)
        }

        var updates: [CodexBundleCASUpdate] = []
        var held: [LLMRouteID] = []
        var recommendations: [LLMRouteID] = []
        var plannerHolds: [LLMRouteID: ModelMigrationHoldReason] = [:]
        var blockingPlannerHolds: [LLMRouteID] = []
        for decision in plan.decisions {
            guard routes.indices.contains(decision.inputIndex) else { continue }
            let route = routes[decision.inputIndex]
            switch decision.action {
            case .unchanged:
                break
            case .recommend:
                recommendations.append(route.route)
            case .hold(let reason):
                plannerHolds[route.route] = reason
                if source.isRetired(model: route.bundle.modelID, in: catalog) {
                    blockingPlannerHolds.append(route.route)
                }
            case .migrate(let destination):
                let qualification = ModelQualification(
                    model: destination.model,
                    effort: destination.effort)
                guard accepted[qualification] == true else {
                    held.append(route.route)
                    continue
                }
                var replacement = route.bundle
                replacement.version = LLMProviderBundle.currentVersion
                replacement.modelID = destination.model
                replacement.effort = destination.effort
                replacement.autoUpdated = LLMAutoUpdateProvenance(
                    fromModelID: route.bundle.modelID,
                    date: refreshed.checkedAt ?? checkedAt,
                    reason: .deprecation)
                updates.append(CodexBundleCASUpdate(
                    route: route.route,
                    expected: route.bundle,
                    replacement: replacement))
            }
        }

        let applied: [LLMRouteID]
        let skipped: [LLMRouteID]
        do {
            let result = try settings.compareAndSwapCodexBundles(updates)
            applied = result.applied
            skipped = result.skipped
        } catch {
            return CodexModelUpdateOutcome(
                status: .persistenceFailed,
                checkedAt: refreshed.checkedAt ?? checkedAt,
                applied: [],
                skipped: [],
                held: (held + updates.map(\.route))
                    .sorted { $0.rawValue < $1.rawValue },
                recommendations: recommendations.sorted { $0.rawValue < $1.rawValue },
                plannerHolds: plannerHolds,
                blockingPlannerHolds: blockingPlannerHolds.sorted {
                    $0.rawValue < $1.rawValue
                })
        }

        return CodexModelUpdateOutcome(
            status: held.isEmpty && plannerHolds.isEmpty ? .current : .held,
            checkedAt: refreshed.checkedAt ?? checkedAt,
            applied: applied,
            skipped: skipped,
            held: held.sorted { $0.rawValue < $1.rawValue },
            recommendations: recommendations.sorted { $0.rawValue < $1.rawValue },
            plannerHolds: plannerHolds,
            blockingPlannerHolds: blockingPlannerHolds.sorted {
                $0.rawValue < $1.rawValue
            })
    }
}

struct CodexModelUpdateSchedulePolicy: Equatable {
    let initialDelay: TimeInterval
    let successInterval: TimeInterval
    let idleRetryInterval: TimeInterval
    let failureBackoff: [TimeInterval]

    init(
        initialDelay: TimeInterval = 60,
        successInterval: TimeInterval = 6 * 60 * 60,
        idleRetryInterval: TimeInterval = 60,
        failureBackoff: [TimeInterval] = [5 * 60, 15 * 60, 60 * 60]
    ) {
        precondition(initialDelay >= 0)
        precondition(successInterval > 0)
        precondition(idleRetryInterval > 0)
        precondition(!failureBackoff.isEmpty && failureBackoff.allSatisfy { $0 > 0 })
        self.initialDelay = initialDelay
        self.successInterval = successInterval
        self.idleRetryInterval = idleRetryInterval
        self.failureBackoff = failureBackoff
    }
}

enum CodexModelUpdateScheduleCompletion: Equatable {
    case success
    case failure
    case coalesced
}

/// Deterministic one-shot scheduler state. AppDelegate owns the Timer; this object owns every re-arm
/// decision so success, failure, overlap, idle deferral, enable/disable, wake, and clock-change paths
/// cannot silently turn the recurring metadata rail into a one-shot.
final class CodexModelUpdateSchedule {
    private let policy: CodexModelUpdateSchedulePolicy
    private(set) var nextCheckAt: TimeInterval?
    private var enabled = false
    private var deferredForIdle = false
    private var failureIndex = 0

    init(policy: CodexModelUpdateSchedulePolicy = CodexModelUpdateSchedulePolicy()) {
        self.policy = policy
    }

    func launched(enabled: Bool, now: TimeInterval) {
        self.enabled = enabled
        deferredForIdle = false
        failureIndex = 0
        nextCheckAt = enabled ? now + policy.initialDelay : nil
    }

    func setEnabled(_ enabled: Bool, now: TimeInterval) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        deferredForIdle = false
        failureIndex = 0
        nextCheckAt = enabled ? now + policy.initialDelay : nil
    }

    func takeDue(now: TimeInterval, isIdle: Bool) -> Bool {
        guard enabled, let due = nextCheckAt, now >= due else { return false }
        guard isIdle else {
            deferredForIdle = true
            nextCheckAt = now + policy.idleRetryInterval
            return false
        }
        deferredForIdle = false
        nextCheckAt = nil
        return true
    }

    func becameIdle(now: TimeInterval) {
        guard enabled, deferredForIdle else { return }
        deferredForIdle = false
        nextCheckAt = now
    }

    func completed(_ completion: CodexModelUpdateScheduleCompletion, now: TimeInterval) {
        guard enabled else {
            nextCheckAt = nil
            return
        }
        deferredForIdle = false
        switch completion {
        case .success:
            failureIndex = 0
            nextCheckAt = now + policy.successInterval
        case .failure:
            let index = min(failureIndex, policy.failureBackoff.count - 1)
            nextCheckAt = now + policy.failureBackoff[index]
            failureIndex = min(failureIndex + 1, policy.failureBackoff.count - 1)
        case .coalesced:
            nextCheckAt = now + policy.idleRetryInterval
        }
    }

    func woke(now: TimeInterval) {
        guard enabled else { return }
        deferredForIdle = false
        nextCheckAt = now
    }

    func clockChanged(now: TimeInterval) {
        guard enabled else { return }
        deferredForIdle = false
        nextCheckAt = now
    }
}
