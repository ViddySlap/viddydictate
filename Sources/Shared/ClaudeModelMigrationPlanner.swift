import Foundation

/// Family and version parsed out of a Claude model id.
///
/// Claude publishes no upgrade edge and no created-at ordering the neutral catalog row can carry, but
/// its ids are themselves structured, and that structure is the only successor evidence the catalog
/// actually gives. Both shipped spellings parse:
///
/// - `claude-opus-5` -> family `opus`, version `[5]`, no snapshot
/// - `claude-haiku-4-5-20251001` -> family `haiku`, version `[4, 5]`, snapshot `20251001`
/// - `claude-3-5-sonnet-20240620` -> family `sonnet`, version `[3, 5]`, snapshot `20240620`
///   (the legacy family-after-version spelling, which a long-lived install can still have pinned)
struct ClaudeModelIdentity: Equatable {
    let family: String
    let version: [Int]
    /// The trailing `yyyymmdd` snapshot, or nil for an evergreen alias.
    let snapshot: Int?

    private static let prefix = "claude-"
    private static let maxTokens = 8

    static func parse(_ modelID: String) -> ClaudeModelIdentity? {
        guard modelID.hasPrefix(prefix) else { return nil }
        let tokens = modelID.dropFirst(prefix.count).split(
            separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, tokens.count <= maxTokens,
              tokens.allSatisfy({ !$0.isEmpty }) else { return nil }

        guard let familyIndex = tokens.firstIndex(where: { !isNumeric($0) }) else { return nil }
        let family = tokens[familyIndex]
        guard isFamilyName(family) else { return nil }

        var numbers = tokens.enumerated().compactMap { index, token -> Int? in
            index == familyIndex ? nil : Int(token)
        }
        // Every non-family token must have been numeric; a second word means an id shape this parser
        // does not understand, and guessing a successor for it would be worse than holding.
        guard numbers.count == tokens.count - 1 else { return nil }

        var snapshot: Int?
        if let last = tokens.last, last != family, last.count == 8, isNumeric(last) {
            snapshot = numbers.removeLast()
        }
        return ClaudeModelIdentity(family: family, version: numbers, snapshot: snapshot)
    }

    /// Strict total order over one family, newest first. Version components compare element-wise, a
    /// longer equal prefix is newer (`4.5` beats `4`), and when versions tie the evergreen alias wins
    /// over a dated snapshot because an alias does not itself retire.
    static func isNewer(_ lhs: ClaudeModelIdentity, than rhs: ClaudeModelIdentity) -> Bool {
        for (left, right) in zip(lhs.version, rhs.version) where left != right {
            return left > right
        }
        if lhs.version.count != rhs.version.count {
            return lhs.version.count > rhs.version.count
        }
        switch (lhs.snapshot, rhs.snapshot) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let left?, let right?): return left > right
        }
    }

    private static func isNumeric(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isFamilyName(_ token: String) -> Bool {
        guard let first = token.first, first.isASCII, first.isLetter else { return false }
        return token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// Pure Claude policy over an already acquired catalog. This type has no provider, process, disk,
/// settings, clock, auth, network, logging, or user-content capability.
///
/// ADR 0014 in one sentence: a route moves only when Claude RETIRED its pin, and a merely newer model
/// is ignored. Claude retires a model by removing it from `GET /v1/models`, so the whole policy turns
/// on what counts as positive evidence of removal:
///
/// **The pin is gone AND its family is still served.** That pairing is the evidence. Bare absence is
/// not enough — a typo, a model the account was never entitled to, and a family this token cannot see
/// at all are all absent too, and none of them is a retirement. When the family is gone as well the
/// planner holds and the surface says so, rather than silently promoting a `haiku` route to `opus`.
enum ClaudeModelMigrationPlanner {
    private struct LiveModel {
        let row: ModelCatalogRow
        let identity: ClaudeModelIdentity
    }

    private struct CatalogIndex {
        /// Every live row, including ones whose id this parser does not understand: presence is a
        /// weaker claim than successorship and must not depend on parsing.
        let byModel: [String: ModelCatalogRow]
        /// Only the live rows whose id parses, grouped by family — the successor pool.
        let byFamily: [String: [LiveModel]]
    }

    static func plan(
        requests: [ModelMigrationRequest],
        catalog: ModelCatalog,
        bounds: ModelMigrationPlannerBounds = ModelMigrationPlannerBounds()
    ) -> ModelMigrationPlan {
        let decisions: [ModelMigrationDecision]
        switch makeIndex(catalog.rows, bounds: bounds) {
        case .failure(let reason):
            decisions = requests.indices.map {
                ModelMigrationDecision(inputIndex: $0, action: .hold(reason))
            }
        case .success(let index):
            decisions = requests.enumerated().map { inputIndex, request in
                ModelMigrationDecision(
                    inputIndex: inputIndex,
                    action: action(for: request, index: index, bounds: bounds))
            }
        }

        var seen: Set<ModelQualification> = []
        var qualifications: [ModelQualification] = []
        for decision in decisions {
            guard case .migrate(let destination) = decision.action else { continue }
            let qualification = ModelQualification(
                model: destination.model, effort: destination.effort)
            if seen.insert(qualification).inserted {
                qualifications.append(qualification)
            }
        }
        return ModelMigrationPlan(decisions: decisions, qualifications: qualifications)
    }

    /// Whether Claude has retired `model`, judged against an acquired catalog: the pin is gone and its
    /// family is still served. Shares `successor` with `plan`, so the predicate and the policy cannot
    /// drift apart — this is true for exactly the pins `plan` either migrates or holds *because the
    /// destination itself was unusable*, which is precisely when a hold is blocking rather than
    /// advisory.
    static func isRetired(
        model: String,
        in catalog: ModelCatalog,
        bounds: ModelMigrationPlannerBounds = ModelMigrationPlannerBounds()
    ) -> Bool {
        guard case .success(let index) = makeIndex(catalog.rows, bounds: bounds) else {
            return false
        }
        return successor(for: model, index: index, bounds: bounds) != nil
    }

    private static func makeIndex(
        _ rows: [ModelCatalogRow],
        bounds: ModelMigrationPlannerBounds
    ) -> Result<CatalogIndex, ModelMigrationHoldReason> {
        var byModel: [String: ModelCatalogRow] = [:]
        var byFamily: [String: [LiveModel]] = [:]
        var seen: Set<String> = []
        for row in rows {
            guard isBoundedNonempty(row.id, bounds: bounds),
                  isBoundedNonempty(row.model, bounds: bounds) else {
                return .failure(.invalidCatalogIdentifier)
            }
            guard seen.insert(row.model).inserted else {
                return .failure(.duplicateCatalogModel)
            }
            // Claude never hides a row, but a hidden one would mean "listed yet not live", so it is
            // excluded from both the presence test and the successor pool rather than trusted.
            guard !row.hidden else { continue }
            byModel[row.model] = row
            if let identity = ClaudeModelIdentity.parse(row.model) {
                byFamily[identity.family, default: []].append(
                    LiveModel(row: row, identity: identity))
            }
        }
        return .success(CatalogIndex(byModel: byModel, byFamily: byFamily))
    }

    private static func action(
        for request: ModelMigrationRequest,
        index: CatalogIndex,
        bounds: ModelMigrationPlannerBounds
    ) -> ModelMigrationAction {
        guard isBoundedNonempty(request.model, bounds: bounds) else {
            return .hold(.invalidStoredModel)
        }
        if let effort = request.effort, !isBoundedNonempty(effort, bounds: bounds) {
            return .hold(.invalidStoredEffort)
        }
        // ADR 0014's whole point: a pin the provider still serves stays exactly where it is, however
        // many newer models the same catalog also lists.
        if index.byModel[request.model] != nil {
            return .unchanged
        }
        guard let terminal = successor(
            for: request.model, index: index, bounds: bounds) else {
            return .hold(.unknownSource)
        }
        if let modalities = terminal.row.inputModalities,
           !modalities.contains("text") {
            return .hold(.nonTextTerminal)
        }
        return .migrate(destination(
            sourceModel: request.model,
            storedEffort: request.effort,
            terminal: terminal.row))
    }

    /// The live successor for a pin, or nil when the catalog gives no positive evidence of retirement
    /// (the pin is still listed, its id does not parse, or its whole family is absent).
    private static func successor(
        for model: String,
        index: CatalogIndex,
        bounds: ModelMigrationPlannerBounds
    ) -> LiveModel? {
        guard isBoundedNonempty(model, bounds: bounds),
              index.byModel[model] == nil,
              let identity = ClaudeModelIdentity.parse(model),
              let family = index.byFamily[identity.family],
              !family.isEmpty else { return nil }
        // `max(by:)` wants "is lhs ordered before rhs", i.e. is lhs the OLDER of the two. Identical
        // identities from distinct ids tie-break on the id so the choice is deterministic.
        return family.max { lhs, rhs in
            lhs.identity == rhs.identity
                ? lhs.row.model < rhs.row.model
                : ClaudeModelIdentity.isNewer(rhs.identity, than: lhs.identity)
        }
    }

    private static func destination(
        sourceModel: String,
        storedEffort: String?,
        terminal: ModelCatalogRow
    ) -> ModelMigrationDestination {
        // A Claude migration changes the model and NOTHING else. Effort is a CLI flag rather than a
        // catalog-gated capability, so the stored level rides across unchanged; a pin that carried no
        // level keeps carrying none, which the transform client spells as omitting `--effort`.
        ModelMigrationDestination(
            model: terminal.model,
            effort: storedEffort ?? "",
            supportedEfforts: terminal.supportedReasoningEfforts.map(\.reasoningEffort),
            provenance: ModelMigrationProvenance(
                sourcePresetID: sourceModel,
                sourceModel: sourceModel,
                // Claude advertises no upgrade edge, so there is no chain of explicit targets to
                // record. The empty list is the honest answer, not a missing one.
                explicitTargetPresetIDs: [],
                terminalPresetID: terminal.id,
                terminalModel: terminal.model,
                effortResolution: storedEffort == nil ? .advertisedDefault : .stored))
    }

    private static func isBoundedNonempty(
        _ value: String,
        bounds: ModelMigrationPlannerBounds
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= bounds.maxStringBytes
    }
}
