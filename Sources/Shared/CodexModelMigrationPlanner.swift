import Foundation

struct ModelMigrationRequest: Equatable {
    let model: String
    let effort: String?
}

struct ModelMigrationPlannerBounds: Equatable {
    let maxStringBytes: Int
    let maxUpgradeHops: Int

    init(
        maxStringBytes: Int = 65_536,
        maxUpgradeHops: Int = 8
    ) {
        precondition(maxStringBytes > 0)
        precondition(maxUpgradeHops > 0)
        self.maxStringBytes = maxStringBytes
        self.maxUpgradeHops = maxUpgradeHops
    }
}

enum ModelMigrationHoldReason: String, Codable, Error, Equatable, CaseIterable {
    case invalidStoredModel = "invalid_stored_model"
    case invalidStoredEffort = "invalid_stored_effort"
    case invalidCatalogIdentifier = "invalid_catalog_identifier"
    case duplicateCatalogID = "duplicate_catalog_id"
    case duplicateCatalogModel = "duplicate_catalog_model"
    case invalidEffortCatalog = "invalid_effort_catalog"
    case unknownSource = "unknown_source"
    case conflictingUpgradeTargets = "conflicting_upgrade_targets"
    case missingUpgrade = "missing_upgrade"
    case invalidUpgradeTarget = "invalid_upgrade_target"
    case selfUpgrade = "self_upgrade"
    case missingTarget = "missing_target"
    case hiddenTerminal = "hidden_terminal"
    case cycle
    case depthExceeded = "depth_exceeded"
    case nonTextTerminal = "non_text_terminal"
    case missingDefaultEffort = "missing_default_effort"
    case inconsistentDefaultEffort = "inconsistent_default_effort"
    case unsupportedEffort = "unsupported_effort"
}

enum ModelMigrationEffortResolution: String, Codable, Equatable {
    case stored
    case advertisedDefault = "advertised_default"
}

/// Exact metadata inputs from which later links can derive honest auto-update provenance. Untrusted
/// display names, descriptions, upgrade copy, URLs, markdown, and unknown fields never enter it.
struct ModelMigrationProvenance: Equatable {
    let sourcePresetID: String
    let sourceModel: String
    let explicitTargetPresetIDs: [String]
    let terminalPresetID: String
    let terminalModel: String
    let effortResolution: ModelMigrationEffortResolution
}

struct ModelMigrationDestination: Equatable {
    let model: String
    let effort: String
    /// Preserves the catalog's advertised order exactly for later picker/status work.
    let supportedEfforts: [String]
    let provenance: ModelMigrationProvenance
}

enum ModelMigrationAction: Equatable {
    case unchanged
    case recommend(ModelMigrationDestination)
    case migrate(ModelMigrationDestination)
    case hold(ModelMigrationHoldReason)
}

struct ModelMigrationDecision: Equatable {
    /// Stable request order is the only route correlation emitted by this content-free planner.
    let inputIndex: Int
    let action: ModelMigrationAction
}

struct ModelQualification: Hashable {
    let model: String
    let effort: String
}

struct ModelMigrationPlan: Equatable {
    let decisions: [ModelMigrationDecision]
    /// Exact first-use order, deduplicated by the complete executable pair.
    let qualifications: [ModelQualification]
}

/// Pure policy over an already acquired metadata catalog. This type has no provider, process, disk,
/// settings, clock, auth, network, logging, or user-content capability.
enum CodexModelMigrationPlanner {
    private struct CatalogIndex {
        let rowsByID: [String: ModelCatalogRow]
        let rowsByModel: [String: ModelCatalogRow]
    }

    private enum EdgeResult {
        case target(String)
        case noEdge
        case hold(ModelMigrationHoldReason)
    }

    private enum DestinationResult {
        case destination(ModelMigrationDestination)
        case hold(ModelMigrationHoldReason)
    }

    static func plan(
        requests: [ModelMigrationRequest],
        catalog: ModelCatalog,
        bounds: ModelMigrationPlannerBounds =
            ModelMigrationPlannerBounds()
    ) -> ModelMigrationPlan {
        let indexResult = makeIndex(catalog.rows, bounds: bounds)
        let decisions: [ModelMigrationDecision]

        switch indexResult {
        case .failure(let reason):
            decisions = requests.indices.map {
                ModelMigrationDecision(
                    inputIndex: $0,
                    action: .hold(reason))
            }
        case .success(let index):
            decisions = requests.enumerated().map { inputIndex, request in
                ModelMigrationDecision(
                    inputIndex: inputIndex,
                    action: action(
                        for: request,
                        index: index,
                        bounds: bounds))
            }
        }

        var seenQualifications: Set<ModelQualification> = []
        var qualifications: [ModelQualification] = []
        for decision in decisions {
            guard case .migrate(let destination) = decision.action else { continue }
            let qualification = ModelQualification(
                model: destination.model,
                effort: destination.effort)
            if seenQualifications.insert(qualification).inserted {
                qualifications.append(qualification)
            }
        }
        return ModelMigrationPlan(
            decisions: decisions,
            qualifications: qualifications)
    }

    private static func makeIndex(
        _ rows: [ModelCatalogRow],
        bounds: ModelMigrationPlannerBounds
    ) -> Result<CatalogIndex, ModelMigrationHoldReason> {
        var rowsByID: [String: ModelCatalogRow] = [:]
        var rowsByModel: [String: ModelCatalogRow] = [:]

        for row in rows {
            guard isBoundedNonempty(row.id, bounds: bounds),
                  isBoundedNonempty(row.model, bounds: bounds) else {
                return .failure(.invalidCatalogIdentifier)
            }
            guard rowsByID[row.id] == nil else {
                return .failure(.duplicateCatalogID)
            }
            guard rowsByModel[row.model] == nil else {
                return .failure(.duplicateCatalogModel)
            }
            guard effortsAreValid(row.supportedReasoningEfforts, bounds: bounds) else {
                return .failure(.invalidEffortCatalog)
            }
            rowsByID[row.id] = row
            rowsByModel[row.model] = row
        }
        return .success(CatalogIndex(
            rowsByID: rowsByID,
            rowsByModel: rowsByModel))
    }

    private static func action(
        for request: ModelMigrationRequest,
        index: CatalogIndex,
        bounds: ModelMigrationPlannerBounds
    ) -> ModelMigrationAction {
        guard isBoundedNonempty(request.model, bounds: bounds) else {
            return .hold(.invalidStoredModel)
        }
        if let effort = request.effort,
           !isBoundedNonempty(effort, bounds: bounds) {
            return .hold(.invalidStoredEffort)
        }
        guard let source = index.rowsByModel[request.model] else {
            return .hold(.unknownSource)
        }
        if source.hidden {
            return hiddenSourceAction(
                source: source,
                storedEffort: request.effort,
                index: index,
                bounds: bounds)
        }
        return visibleSourceAction(
            source: source,
            storedEffort: request.effort,
            index: index,
            bounds: bounds)
    }

    private static func visibleSourceAction(
        source: ModelCatalogRow,
        storedEffort: String?,
        index: CatalogIndex,
        bounds: ModelMigrationPlannerBounds
    ) -> ModelMigrationAction {
        switch explicitEdge(from: source, bounds: bounds) {
        case .noEdge:
            return .unchanged
        case .hold(let reason):
            return .hold(reason)
        case .target(let targetID):
            if targetID == source.id {
                return .hold(.selfUpgrade)
            }
            guard let target = index.rowsByID[targetID] else {
                return .hold(.missingTarget)
            }
            guard !target.hidden else {
                return .hold(.hiddenTerminal)
            }
            return destinationAction(
                source: source,
                terminal: target,
                explicitTargetPresetIDs: [target.id],
                storedEffort: storedEffort,
                recommendationOnly: true,
                bounds: bounds)
        }
    }

    private static func hiddenSourceAction(
        source: ModelCatalogRow,
        storedEffort: String?,
        index: CatalogIndex,
        bounds: ModelMigrationPlannerBounds
    ) -> ModelMigrationAction {
        var current = source
        var visitedPresetIDs: Set<String> = [source.id]
        var explicitTargetPresetIDs: [String] = []
        var followedHops = 0

        while current.hidden {
            switch explicitEdge(from: current, bounds: bounds) {
            case .noEdge:
                return .hold(
                    explicitTargetPresetIDs.isEmpty
                        ? .missingUpgrade
                        : .hiddenTerminal)
            case .hold(let reason):
                return .hold(reason)
            case .target(let targetID):
                if targetID == current.id {
                    return .hold(.selfUpgrade)
                }
                if visitedPresetIDs.contains(targetID) {
                    return .hold(.cycle)
                }
                guard followedHops < bounds.maxUpgradeHops else {
                    return .hold(.depthExceeded)
                }
                guard let target = index.rowsByID[targetID] else {
                    return .hold(.missingTarget)
                }
                followedHops += 1
                explicitTargetPresetIDs.append(target.id)
                visitedPresetIDs.insert(target.id)
                current = target
            }
        }

        return destinationAction(
            source: source,
            terminal: current,
            explicitTargetPresetIDs: explicitTargetPresetIDs,
            storedEffort: storedEffort,
            recommendationOnly: false,
            bounds: bounds)
    }

    private static func destinationAction(
        source: ModelCatalogRow,
        terminal: ModelCatalogRow,
        explicitTargetPresetIDs: [String],
        storedEffort: String?,
        recommendationOnly: Bool,
        bounds: ModelMigrationPlannerBounds
    ) -> ModelMigrationAction {
        switch destination(
            source: source,
            terminal: terminal,
            explicitTargetPresetIDs: explicitTargetPresetIDs,
            storedEffort: storedEffort,
            bounds: bounds
        ) {
        case .hold(let reason):
            return .hold(reason)
        case .destination(let destination):
            return recommendationOnly
                ? .recommend(destination)
                : .migrate(destination)
        }
    }

    private static func destination(
        source: ModelCatalogRow,
        terminal: ModelCatalogRow,
        explicitTargetPresetIDs: [String],
        storedEffort: String?,
        bounds: ModelMigrationPlannerBounds
    ) -> DestinationResult {
        if let modalities = terminal.inputModalities,
           !modalities.contains("text") {
            return .hold(.nonTextTerminal)
        }

        let supportedEfforts =
            terminal.supportedReasoningEfforts.map(\.reasoningEffort)
        let resolvedEffort: String
        let effortResolution: ModelMigrationEffortResolution
        if let storedEffort {
            guard supportedEfforts.contains(storedEffort) else {
                return .hold(.unsupportedEffort)
            }
            resolvedEffort = storedEffort
            effortResolution = .stored
        } else {
            guard let advertisedDefault = terminal.defaultReasoningEffort else {
                return .hold(.missingDefaultEffort)
            }
            guard isBoundedNonempty(advertisedDefault, bounds: bounds),
                  supportedEfforts.contains(advertisedDefault) else {
                return .hold(.inconsistentDefaultEffort)
            }
            resolvedEffort = advertisedDefault
            effortResolution = .advertisedDefault
        }

        return .destination(ModelMigrationDestination(
            model: terminal.model,
            effort: resolvedEffort,
            supportedEfforts: supportedEfforts,
            provenance: ModelMigrationProvenance(
                sourcePresetID: source.id,
                sourceModel: source.model,
                explicitTargetPresetIDs: explicitTargetPresetIDs,
                terminalPresetID: terminal.id,
                terminalModel: terminal.model,
                effortResolution: effortResolution)))
    }

    private static func explicitEdge(
        from row: ModelCatalogRow,
        bounds: ModelMigrationPlannerBounds
    ) -> EdgeResult {
        let legacyTarget = row.upgrade
        let structuredTarget = row.upgradeInfo?.model
        if let legacyTarget, let structuredTarget,
           legacyTarget != structuredTarget {
            return .hold(.conflictingUpgradeTargets)
        }
        guard let target = legacyTarget ?? structuredTarget else {
            return .noEdge
        }
        guard isBoundedNonempty(target, bounds: bounds) else {
            return .hold(.invalidUpgradeTarget)
        }
        return .target(target)
    }

    private static func effortsAreValid(
        _ efforts: [ModelCatalogReasoningEffort],
        bounds: ModelMigrationPlannerBounds
    ) -> Bool {
        var seen: Set<String> = []
        for effort in efforts {
            guard isBoundedNonempty(effort.reasoningEffort, bounds: bounds),
                  seen.insert(effort.reasoningEffort).inserted else {
                return false
            }
        }
        return true
    }

    private static func isBoundedNonempty(
        _ value: String,
        bounds: ModelMigrationPlannerBounds
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= bounds.maxStringBytes
    }
}
