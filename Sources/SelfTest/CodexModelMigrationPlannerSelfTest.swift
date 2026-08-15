import Foundation

/// Pure deterministic fixtures for explicit Codex catalog migration policy. These fixtures contain
/// metadata only: no process, provider, cache, settings, auth, network, or user-content seam exists.
enum CodexModelMigrationPlannerSelfTest {
    static func run(_ check: (String, Bool) -> Void) {
        print("--- pure explicit Codex model migration planner ---")
        checkOpaqueExactIdentity(check)
        checkVisibilityAndTraversal(check)
        checkEdgeAndCatalogGuards(check)
        checkTerminalModality(check)
        checkOpenEffortsAndQualificationDedupe(check)
        checkContentFreeDeterminism(check)
    }

    private static func checkOpaqueExactIdentity(_ check: (String, Bool) -> Void) {
        let sourceModel = "orbital://retired runtime/β"
        let targetID = "preset channel/七"
        let targetModel = "nebula.runtime::next@☄️"
        let rows = [
            row(
                id: "source preset/α", model: sourceModel, hidden: true,
                efforts: ["wild effort", "x/y"], upgrade: targetID),
            row(
                id: targetID, model: targetModel, hidden: false,
                defaultEffort: "x/y", efforts: ["wild effort", "x/y"],
                modalities: ["text"]),
        ]
        let opaquePlan = plan([request(sourceModel, nil)], rows)
        let expected = ModelMigrationDestination(
            model: targetModel,
            effort: "x/y",
            supportedEfforts: ["wild effort", "x/y"],
            provenance: ModelMigrationProvenance(
                sourcePresetID: "source preset/α",
                sourceModel: sourceModel,
                explicitTargetPresetIDs: [targetID],
                terminalPresetID: targetID,
                terminalModel: targetModel,
                effortResolution: .advertisedDefault))

        check("future-shaped non-GPT id != model migrates by exact opaque namespaces",
              action(opaquePlan) == .migrate(expected))
        check("qualification uses executable row.model rather than target row.id",
              opaquePlan.qualifications == [
                ModelQualification(model: targetModel, effort: "x/y"),
              ])
        check("stored source preset id is not accepted as an executable model lookup",
              action(self.plan([request("source preset/α", nil)], rows))
                == .hold(.unknownSource))

        let crossedNamespaces = [
            row(
                id: "shared-token", model: "decoy-runtime", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
            row(
                id: "real-source", model: "shared-token", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "target-id"),
            row(
                id: "target-id", model: "target-runtime", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
        ]
        check("source resolution uses unique row.model even when another row.id is identical",
              destinationModel(plan([request("shared-token", "e")], crossedNamespaces))
                == "target-runtime")

        let targetModelOnly = [
            row(
                id: "source", model: "source-runtime", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "model-only-token"),
            row(
                id: "different-id", model: "model-only-token", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
        ]
        check("upgrade resolution never falls back from target row.id to row.model",
              action(plan([request("source-runtime", "e")], targetModelOnly))
                == .hold(.missingTarget))
    }

    private static func checkVisibilityAndTraversal(_ check: (String, Bool) -> Void) {
        let visibleRecommendation = [
            row(
                id: "visible-a", model: "run-a", hidden: false,
                defaultEffort: "e", efforts: ["e"], upgrade: "visible-b"),
            row(
                id: "visible-b", model: "run-b", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
        ]
        let recommendation = plan([request("run-a", "e")], visibleRecommendation)
        check("visible source recommendation is surfaced without rewrite",
              isRecommendation(recommendation, model: "run-b", effort: "e"))
        check("visible recommendation schedules no automatic qualification",
              recommendation.qualifications.isEmpty)

        check("visible source without recommendation remains unchanged",
              action(plan(
                [request("run-b", "e")], visibleRecommendation)) == .unchanged)

        let stopAtVisible = [
            row(
                id: "hidden-a", model: "run-hidden-a", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "visible-b"),
            row(
                id: "visible-b", model: "run-visible-b", hidden: false,
                defaultEffort: "e", efforts: ["e"], upgrade: "visible-c"),
            row(
                id: "visible-c", model: "run-visible-c", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
        ]
        let stopped = plan([request("run-hidden-a", "e")], stopAtVisible)
        check("hidden A -> visible B -> recommended C stops terminally at B",
              destinationModel(stopped) == "run-visible-b"
                && destinationPath(stopped) == ["visible-b"])

        let transitive = [
            row(
                id: "hidden-a", model: "run-a", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "hidden-b"),
            row(
                id: "hidden-b", model: "run-b", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "visible-c"),
            row(
                id: "visible-c", model: "run-c", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
        ]
        let transitivePlan = plan([request("run-a", "e")], transitive)
        check("hidden sources traverse explicit id edges to the first visible terminal",
              destinationModel(transitivePlan) == "run-c"
                && destinationPath(transitivePlan) == ["hidden-b", "visible-c"])
    }

    private static func checkEdgeAndCatalogGuards(_ check: (String, Bool) -> Void) {
        let baseSource = row(
            id: "source", model: "run-source", hidden: true,
            defaultEffort: "e", efforts: ["e"], upgrade: "target")
        let baseTarget = row(
            id: "target", model: "run-target", hidden: false,
            defaultEffort: "e", efforts: ["e"])

        check("conflicting legacy and structured upgrade forms hold",
              action(plan(
                [request("run-source", "e")],
                [row(
                    id: "source", model: "run-source", hidden: true,
                    defaultEffort: "e", efforts: ["e"], upgrade: "target",
                    structuredUpgrade: "other"), baseTarget]))
                == .hold(.conflictingUpgradeTargets))
        check("hidden source without an explicit edge holds",
              action(plan(
                [request("run-source", "e")],
                [row(
                    id: "source", model: "run-source", hidden: true,
                    defaultEffort: "e", efforts: ["e"])]))
                == .hold(.missingUpgrade))
        check("empty explicit target holds",
              action(plan(
                [request("run-source", "e")],
                [row(
                    id: "source", model: "run-source", hidden: true,
                    defaultEffort: "e", efforts: ["e"], upgrade: ""), baseTarget]))
                == .hold(.invalidUpgradeTarget))
        check("over-budget explicit target holds",
              action(plan(
                [request("run-source", "e")],
                [row(
                    id: "source", model: "run-source", hidden: true,
                    defaultEffort: "e", efforts: ["e"],
                    upgrade: String(repeating: "x", count: 65)), baseTarget]))
                == .hold(.invalidUpgradeTarget))
        check("missing target preset id holds",
              action(plan(
                [request("run-source", "e")], [baseSource]))
                == .hold(.missingTarget))
        check("self edge holds",
              action(plan(
                [request("run-source", "e")],
                [row(
                    id: "source", model: "run-source", hidden: true,
                    defaultEffort: "e", efforts: ["e"], upgrade: "source")]))
                == .hold(.selfUpgrade))

        let cycle = [
            row(
                id: "a", model: "run-a", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "b"),
            row(
                id: "b", model: "run-b", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "a"),
        ]
        check("transitive cycle holds",
              action(plan([request("run-a", "e")], cycle)) == .hold(.cycle))

        let depth = [
            row(
                id: "a", model: "run-a", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "b"),
            row(
                id: "b", model: "run-b", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "c"),
            row(
                id: "c", model: "run-c", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "d"),
            row(
                id: "d", model: "run-d", hidden: false,
                defaultEffort: "e", efforts: ["e"]),
        ]
        check("fixed hop bound holds before following a deeper edge",
              action(plan(
                [request("run-a", "e")], depth, maxUpgradeHops: 2))
                == .hold(.depthExceeded))
        check("a path reaching visible at the fixed hop bound remains valid",
              destinationModel(plan(
                [request("run-a", "e")], Array(depth.prefix(3)).map { candidate in
                    candidate.id == "c"
                        ? row(
                            id: "c", model: "run-c", hidden: false,
                            defaultEffort: "e", efforts: ["e"])
                        : candidate
                }, maxUpgradeHops: 2)) == "run-c")

        let hiddenTerminal = [
            baseSource,
            row(
                id: "target", model: "run-target", hidden: true,
                defaultEffort: "e", efforts: ["e"]),
        ]
        check("hidden target without a next explicit edge holds",
              action(plan([request("run-source", "e")], hiddenTerminal))
                == .hold(.hiddenTerminal))
        check("visible recommendation pointing at a hidden target holds without traversal",
              action(plan(
                [request("run-visible", "e")],
                [row(
                    id: "visible", model: "run-visible", hidden: false,
                    defaultEffort: "e", efforts: ["e"], upgrade: "target"),
                 hiddenTerminal[1]]))
                == .hold(.hiddenTerminal))

        check("duplicate preset ids make lookup ambiguous and hold",
              action(plan(
                [request("run-source", "e")],
                [baseSource, baseTarget,
                 row(
                    id: "target", model: "other-runtime", hidden: false,
                    defaultEffort: "e", efforts: ["e"])]))
                == .hold(.duplicateCatalogID))
        check("duplicate executable models make source lookup ambiguous and hold",
              action(plan(
                [request("run-source", "e")],
                [baseSource,
                 row(
                    id: "other", model: "run-source", hidden: false,
                    defaultEffort: "e", efforts: ["e"]),
                 baseTarget]))
                == .hold(.duplicateCatalogModel))
        check("empty catalog identifiers hold",
              action(plan(
                [request("run-source", "e")],
                [row(
                    id: "", model: "run-source", hidden: true,
                    defaultEffort: "e", efforts: ["e"], upgrade: "target"),
                 baseTarget]))
                == .hold(.invalidCatalogIdentifier))
        check("over-budget executable identifiers hold",
              action(plan(
                [request("run-source", "e")],
                [baseSource,
                 row(
                    id: "target",
                    model: String(repeating: "m", count: 65),
                    hidden: false, defaultEffort: "e", efforts: ["e"])]))
                == .hold(.invalidCatalogIdentifier))
        check("unknown custom source holds without guessing",
              action(plan(
                [request("custom-runtime", "e")], [baseSource, baseTarget]))
                == .hold(.unknownSource))
        check("empty stored executable identifier holds",
              action(plan([request("", "e")], [baseSource, baseTarget]))
                == .hold(.invalidStoredModel))
        check("over-budget stored executable identifier holds",
              action(plan(
                [request(String(repeating: "m", count: 65), "e")],
                [baseSource, baseTarget]))
                == .hold(.invalidStoredModel))
    }

    private static func checkTerminalModality(_ check: (String, Bool) -> Void) {
        let source = row(
            id: "source", model: "run-source", hidden: true,
            defaultEffort: "e", efforts: ["e"], upgrade: "target")
        check("terminal without text input modality holds",
              action(plan(
                [request("run-source", "e")],
                [source,
                 row(
                    id: "target", model: "run-target", hidden: false,
                    defaultEffort: "e", efforts: ["e"], modalities: ["image"])]))
                == .hold(.nonTextTerminal))
        check("modality matching is exact and does not normalize names",
              action(plan(
                [request("run-source", "e")],
                [source,
                 row(
                    id: "target", model: "run-target", hidden: false,
                    defaultEffort: "e", efforts: ["e"], modalities: ["TEXT"])]))
                == .hold(.nonTextTerminal))
        check("older-catalog omitted modalities retain the documented text fallback",
              destinationModel(plan(
                [request("run-source", "e")],
                [source,
                 row(
                    id: "target", model: "run-target", hidden: false,
                    defaultEffort: "e", efforts: ["e"], modalities: nil)]))
                == "run-target")
    }

    private static func checkOpenEffortsAndQualificationDedupe(
        _ check: (String, Bool) -> Void
    ) {
        let rows = [
            row(
                id: "source-a", model: "run-a", hidden: true,
                efforts: ["effort β", "effort/α"], upgrade: "target"),
            row(
                id: "source-b", model: "run-b", hidden: true,
                efforts: ["effort β", "effort/α"], upgrade: "target"),
            row(
                id: "target", model: "run-target", hidden: false,
                defaultEffort: "effort/α", efforts: ["effort β", "effort/α"]),
        ]
        let batched = plan([
            request("run-a", "effort β"),
            request("run-b", "effort β"),
            request("run-a", nil),
        ], rows)

        check("open stored effort is preserved exactly with advertised ordering",
              destinationEffort(batched, at: 0) == "effort β"
                && destinationSupportedEfforts(batched, at: 0)
                    == ["effort β", "effort/α"]
                && destinationEffortResolution(batched, at: 0) == .stored)
        check("nil effort resolves only to the exact advertised supported default",
              destinationEffort(batched, at: 2) == "effort/α"
                && destinationEffortResolution(batched, at: 2)
                    == .advertisedDefault)
        check("qualifications dedupe by exact model and effort in first-use order",
              batched.qualifications == [
                ModelQualification(model: "run-target", effort: "effort β"),
                ModelQualification(model: "run-target", effort: "effort/α"),
              ])

        let source = rows[0]
        check("nil effort with missing advertised default holds",
              action(plan(
                [request("run-a", nil)],
                [source,
                 row(
                    id: "target", model: "run-target", hidden: false,
                    efforts: ["effort/α"])]))
                == .hold(.missingDefaultEffort))
        check("nil effort with unsupported advertised default holds",
              action(plan(
                [request("run-a", nil)],
                [source,
                 row(
                    id: "target", model: "run-target", hidden: false,
                    defaultEffort: "other", efforts: ["effort/α"])]))
                == .hold(.inconsistentDefaultEffort))
        check("unsupported stored effort holds without downgrade",
              action(plan(
                [request("run-a", "other")], rows))
                == .hold(.unsupportedEffort))
        check("empty stored effort is invalid rather than normalized",
              action(plan(
                [request("run-a", "")], rows))
                == .hold(.invalidStoredEffort))
        check("over-budget stored effort is invalid rather than truncated",
              action(plan(
                [request("run-a", String(repeating: "e", count: 65))], rows))
                == .hold(.invalidStoredEffort))
        check("empty or duplicated advertised effort values hold as inconsistent",
              action(plan(
                [request("run-a", "effort/α")],
                [source,
                 row(
                    id: "target", model: "run-target", hidden: false,
                    defaultEffort: "effort/α",
                    efforts: ["effort/α", "effort/α", ""])]))
                == .hold(.invalidEffortCatalog))
    }

    private static func checkContentFreeDeterminism(_ check: (String, Bool) -> Void) {
        let upgradeOne = ModelCatalogUpgradeInfo(
            model: "target",
            upgradeCopy: "untrusted copy one",
            modelLink: "https://one.invalid",
            migrationMarkdown: "untrusted markdown one",
            unknownFields: ["one": .string("untrusted")])
        let upgradeTwo = ModelCatalogUpgradeInfo(
            model: "target",
            upgradeCopy: "untrusted copy two",
            modelLink: "https://two.invalid",
            migrationMarkdown: "untrusted markdown two",
            unknownFields: ["two": .integer(2)])
        let first = [
            row(
                id: "source", model: "run-source", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "target",
                upgradeInfo: upgradeOne, displayName: "display one",
                description: "description one"),
            row(
                id: "target", model: "run-target", hidden: false,
                defaultEffort: "e", efforts: ["e"],
                displayName: "target display one", description: "target description one"),
        ]
        let second = [
            row(
                id: "source", model: "run-source", hidden: true,
                defaultEffort: "e", efforts: ["e"], upgrade: "target",
                upgradeInfo: upgradeTwo, displayName: "display two",
                description: "description two"),
            row(
                id: "target", model: "run-target", hidden: false,
                defaultEffort: "e", efforts: ["e"],
                displayName: "target display two", description: "target description two"),
        ]
        check("untrusted display/copy/link/description fields cannot affect planner output",
              plan([request("run-source", "e")], first)
                == plan([request("run-source", "e")], second))
        check("hold output is an enum reason plus deterministic input index only",
              plan([request("unknown", "e")], first).decisions
                == [ModelMigrationDecision(
                    inputIndex: 0, action: .hold(.unknownSource))])
    }

    private static func request(
        _ model: String,
        _ effort: String?
    ) -> ModelMigrationRequest {
        ModelMigrationRequest(model: model, effort: effort)
    }

    private static func row(
        id: String,
        model: String,
        hidden: Bool,
        defaultEffort: String? = nil,
        efforts: [String],
        modalities: [String]? = ["text"],
        upgrade: String? = nil,
        structuredUpgrade: String? = nil,
        upgradeInfo: ModelCatalogUpgradeInfo? = nil,
        displayName: String? = nil,
        description: String? = nil
    ) -> ModelCatalogRow {
        ModelCatalogRow(
            id: id,
            model: model,
            displayName: displayName,
            description: description,
            hidden: hidden,
            defaultReasoningEffort: defaultEffort,
            supportedReasoningEfforts: efforts.map {
                ModelCatalogReasoningEffort(
                    reasoningEffort: $0,
                    description: nil,
                    unknownFields: [:])
            },
            inputModalities: modalities,
            supportsPersonality: nil,
            isDefault: nil,
            upgrade: upgrade,
            upgradeInfo: upgradeInfo ?? structuredUpgrade.map {
                ModelCatalogUpgradeInfo(
                    model: $0,
                    upgradeCopy: nil,
                    modelLink: nil,
                    migrationMarkdown: nil,
                    unknownFields: [:])
            },
            unknownFields: [:])
    }

    private static func plan(
        _ requests: [ModelMigrationRequest],
        _ rows: [ModelCatalogRow],
        maxUpgradeHops: Int = 8
    ) -> ModelMigrationPlan {
        CodexModelMigrationPlanner.plan(
            requests: requests,
            catalog: ModelCatalog(rows: rows, pageMetadata: []),
            bounds: ModelMigrationPlannerBounds(
                maxStringBytes: 64,
                maxUpgradeHops: maxUpgradeHops))
    }

    private static func action(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> ModelMigrationAction? {
        plan.decisions.first(where: { $0.inputIndex == index })?.action
    }

    private static func destination(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> ModelMigrationDestination? {
        guard let action = action(plan, at: index) else { return nil }
        switch action {
        case .migrate(let value), .recommend(let value):
            return value
        case .unchanged, .hold:
            return nil
        }
    }

    private static func destinationModel(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> String? {
        destination(plan, at: index)?.model
    }

    private static func destinationEffort(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> String? {
        destination(plan, at: index)?.effort
    }

    private static func destinationSupportedEfforts(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> [String]? {
        destination(plan, at: index)?.supportedEfforts
    }

    private static func destinationEffortResolution(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> ModelMigrationEffortResolution? {
        destination(plan, at: index)?.provenance.effortResolution
    }

    private static func destinationPath(
        _ plan: ModelMigrationPlan,
        at index: Int = 0
    ) -> [String]? {
        destination(plan, at: index)?.provenance.explicitTargetPresetIDs
    }

    private static func isRecommendation(
        _ plan: ModelMigrationPlan,
        model: String,
        effort: String
    ) -> Bool {
        guard case .recommend(let destination)? = action(plan) else { return false }
        return destination.model == model && destination.effort == effort
    }
}
