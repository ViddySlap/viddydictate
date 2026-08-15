import Foundation

enum CodexModelUpdaterSelfTest {
    static func run(_ check: (String, Bool) -> Void) {
        checkCatalogSourceSeam(check)
        checkBatchCAS(check)
        checkUpdater(check)
        checkCorrectiveHoldSurfaces(check)
        checkOutcomeRecordAndSurfaces(check)
        checkScheduledToastGate(check)
        checkScheduler(check)
    }

    /// Pins the Codex conformance of the provider-neutral seam. A second provider lands on this same
    /// protocol, so the contract each member has to honour is asserted here rather than inferred from
    /// the updater's behaviour: retirement is positive evidence in the catalog (a hidden row), never
    /// mere absence, and the policy member is the existing planner rather than a second copy of it.
    private static func checkCatalogSourceSeam(_ check: (String, Bool) -> Void) {
        print("--- catalog source seam (Codex conformance) ---")
        let source = CodexModelCatalogSource()
        let catalog = ModelCatalog(
            rows: [
                row(id: "retired-id", model: "retired", hidden: true,
                    efforts: ["high"], upgrade: "live-id"),
                row(id: "live-id", model: "live", hidden: false, efforts: ["high"]),
            ],
            pageMetadata: [])

        check("seam reports a hidden row as retired",
              source.isRetired(model: "retired", in: catalog))
        check("seam reports a visible row as not retired",
              !source.isRetired(model: "live", in: catalog))
        check("seam does not infer retirement from absence",
              !source.isRetired(model: "never-listed", in: catalog))

        let requests = [
            ModelMigrationRequest(model: "retired", effort: "high"),
            ModelMigrationRequest(model: "live", effort: "high"),
            ModelMigrationRequest(model: "never-listed", effort: nil),
        ]
        check("seam policy is the planner, not a second copy",
              source.plan(requests: requests, catalog: catalog)
                == CodexModelMigrationPlanner.plan(
                    requests: requests, catalog: catalog))

        let stub = CodexModelCatalogSource(discover: { checkedAt in
            ModelCatalogCheckResult(
                catalog: catalog, checkedAt: checkedAt,
                isStale: false, diagnostic: .current)
        })
        check("seam discovery returns what the source acquired",
              stub.discover(checkedAt: "2026-07-29T00:00:00Z")
                == ModelCatalogCheckResult(
                    catalog: catalog, checkedAt: "2026-07-29T00:00:00Z",
                    isStale: false, diagnostic: .current))
    }

    private static func checkBatchCAS(_ check: (String, Bool) -> Void) {
        print("--- Codex store-level batch CAS ---")
        let root = scratch("vd-codex-batch-cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("models-power.json")
        var writes = 0
        let store = ModelsPowerSettingsStore(url: url, writer: { data, destination in
            writes += 1
            try ModelsPowerSettingsStore.atomicWriter(data, destination)
        })
        let oldL1 = LLMProviderBundle.codex("old-a", effort: "high")
        let oldL2 = LLMProviderBundle.codex("old-b", effort: "medium")
        try? store.setRememberedBundle(oldL1, for: .codex, route: .cleanupL1)
        try? store.setRememberedBundle(oldL2, for: .codex, route: .cleanupL2)
        try? store.selectProvider(.local, for: .cleanupL1)
        try? store.setPromptOverride(
            "KEEP EXACT CODEX PROMPT", for: .cleanupL1, provider: .codex)
        let custom = LLMRouteID.custom("deleted-before-cas")
        let migratedCustom = LLMRouteID.custom("migrated-custom")
        try? store.syncCustomRoutes([
            custom: .local("custom-local"),
            migratedCustom: .local("custom-local"),
        ])
        let oldCustom = LLMProviderBundle.codex("old-custom", effort: "low")
        try? store.setRememberedBundle(oldCustom, for: .codex, route: custom)
        try? store.setRememberedBundle(
            oldCustom, for: .codex, route: migratedCustom)
        try? store.syncCustomRoutes([
            migratedCustom: .local("custom-local"),
        ])

        var newL1 = oldL1
        newL1.modelID = "target-a"
        newL1.autoUpdated = LLMAutoUpdateProvenance(
            fromModelID: oldL1.modelID, date: "2026-07-27T18:00:00Z",
            reason: .deprecation)
        var newL2 = oldL2
        newL2.modelID = "target-b"
        newL2.autoUpdated = LLMAutoUpdateProvenance(
            fromModelID: oldL2.modelID, date: "2026-07-27T18:00:00Z",
            reason: .deprecation)
        var newCustom = oldCustom
        newCustom.modelID = "target-custom"
        newCustom.autoUpdated = LLMAutoUpdateProvenance(
            fromModelID: oldCustom.modelID, date: "2026-07-27T18:00:00Z",
            reason: .deprecation)
        var deletedCustomReplacement = oldCustom
        deletedCustomReplacement.modelID = "must-not-resurrect"

        writes = 0
        let result = try? store.compareAndSwapCodexBundles([
            CodexBundleCASUpdate(
                route: .cleanupL1, expected: oldL1, replacement: newL1),
            CodexBundleCASUpdate(
                route: .cleanupL2, expected: oldL2, replacement: newL2),
            CodexBundleCASUpdate(
                route: custom,
                expected: oldCustom,
                replacement: deletedCustomReplacement),
            CodexBundleCASUpdate(
                route: migratedCustom,
                expected: oldCustom,
                replacement: newCustom),
        ])
        check("batch CAS applies every unchanged bundle in one settings persistence",
              result?.applied == [.cleanupL1, .cleanupL2, migratedCustom]
                && writes == 1)
        check("batch CAS skips an absent custom route without resurrecting it",
              result?.skipped == [custom]
                && !store.routeIDs().contains(custom)
                && store.rememberedBundle(for: .codex, route: custom) == nil)
        check("batch CAS preserves selected provider and exact prompt bytes",
              store.selectedBundle(for: .cleanupL1).provider == .local
                && store.effectivePrompt(
                    for: .cleanupL1, provider: .codex) == "KEEP EXACT CODEX PROMPT")
        let reopened = ModelsPowerSettingsStore(url: url)
        check("all successful batch migrations survive settings reopen",
              reopened.rememberedBundle(for: .codex, route: .cleanupL1)
                    == store.rememberedBundle(for: .codex, route: .cleanupL1)
                && reopened.rememberedBundle(for: .codex, route: .cleanupL2)
                    == store.rememberedBundle(for: .codex, route: .cleanupL2)
                && reopened.rememberedBundle(for: .codex, route: migratedCustom)
                    == store.rememberedBundle(for: .codex, route: migratedCustom))
        try? reopened.setSelectedBundle(
            .codex("manual-custom", effort: "wild"),
            for: migratedCustom)
        try? reopened.restoreProviderDefault(.codex, for: migratedCustom)
        check("custom-route Restore uses its qualified default without resurrecting the source",
              reopened.selectedBundle(for: migratedCustom).modelID == "target-custom"
                && reopened.selectedBundle(for: migratedCustom)
                    .autoUpdated?.fromModelID == "old-custom")

        let canonicalNewL1 = store.rememberedBundle(for: .codex, route: .cleanupL1)
        let staleExpected = oldL1
        let stale = try? store.compareAndSwapCodexBundles([
            CodexBundleCASUpdate(
                route: .cleanupL1, expected: staleExpected,
                replacement: LLMProviderBundle.codex("stale-overwrite", effort: "high")),
        ])
        check("a full-bundle mismatch makes the user's newer edit win",
              stale?.applied.isEmpty == true
                && stale?.skipped == [.cleanupL1]
                && store.rememberedBundle(for: .codex, route: .cleanupL1)
                    == canonicalNewL1)

        let failing = ModelsPowerSettingsStore(url: url, writer: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let beforeL1 = failing.rememberedBundle(for: .codex, route: .cleanupL1)
        let beforeL2 = failing.rememberedBundle(for: .codex, route: .cleanupL2)
        var writeFailed = false
        do {
            _ = try failing.compareAndSwapCodexBundles([
                CodexBundleCASUpdate(
                    route: .cleanupL1, expected: beforeL1!,
                    replacement: .codex("none-l1", effort: "high")),
                CodexBundleCASUpdate(
                    route: .cleanupL2, expected: beforeL2!,
                    replacement: .codex("none-l2", effort: "medium")),
            ])
        } catch ModelsPowerSettingsError.writeFailed {
            writeFailed = true
        } catch {}
        check("batch write failure applies none in memory or on disk",
              writeFailed
                && failing.rememberedBundle(for: .codex, route: .cleanupL1) == beforeL1
                && failing.rememberedBundle(for: .codex, route: .cleanupL2) == beforeL2
                && ModelsPowerSettingsStore(url: url)
                    .rememberedBundle(for: .codex, route: .cleanupL1) == beforeL1)
    }

    private static func checkUpdater(_ check: (String, Bool) -> Void) {
        print("--- exact Codex updater qualification and transactional application ---")
        let root = scratch("vd-codex-updater")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("models-power.json"))

        let oldA = LLMProviderBundle.codex("old-a", effort: "high")
        let oldB = LLMProviderBundle.codex("old-b", effort: "low")
        let oldC = LLMProviderBundle.codex("old-c", effort: "medium")
        let visible = LLMProviderBundle.codex("visible-source", effort: "high")
        let visibleHold =
            LLMProviderBundle.codex("visible-held-source", effort: "medium")
        try? store.setRememberedBundle(oldA, for: .codex, route: .cleanupL1)
        try? store.setRememberedBundle(oldA, for: .codex, route: .cleanupL2)
        try? store.setRememberedBundle(oldB, for: .codex, route: .cleanupL3)
        try? store.setRememberedBundle(oldC, for: .codex, route: .promptPrep)
        try? store.setRememberedBundle(visible, for: .codex, route: .email)
        let canonicalVisible =
            store.rememberedBundle(for: .codex, route: .email)
        try? store.setSelectedBundle(visibleHold, for: .searchLocalSynth)
        let canonicalVisibleHold =
            store.rememberedBundle(for: .codex, route: .searchLocalSynth)
        let deletedCustom = LLMRouteID.custom("deleted-during-qualification")
        try? store.syncCustomRoutes([deletedCustom: .local("custom-local")])
        try? store.setRememberedBundle(oldC, for: .codex, route: deletedCustom)

        let catalog = ModelCatalog(
            rows: [
                row(id: "old-a-id", model: "old-a", hidden: true,
                    efforts: ["high"], upgrade: "target-a-id"),
                row(id: "target-a-id", model: "target-a", hidden: false,
                    efforts: ["high"]),
                row(id: "old-b-id", model: "old-b", hidden: true,
                    efforts: ["low"], upgrade: "target-b-id"),
                row(id: "target-b-id", model: "target-b", hidden: false,
                    efforts: ["low"]),
                row(id: "old-c-id", model: "old-c", hidden: true,
                    efforts: ["medium"], upgrade: "target-c-id"),
                row(id: "target-c-id", model: "target-c", hidden: false,
                    efforts: ["medium"]),
                row(id: "visible-id", model: "visible-source", hidden: false,
                    efforts: ["high"], upgrade: "visible-next-id"),
                row(id: "visible-next-id", model: "visible-next", hidden: false,
                    efforts: ["high"]),
                row(id: "visible-held-id", model: "visible-held-source", hidden: false,
                    efforts: ["medium"], upgrade: "visible-held-next-a",
                    structuredUpgrade: "visible-held-next-b"),
                row(id: "visible-held-next-a", model: "visible-held-next-a-model",
                    hidden: false, efforts: ["medium"]),
                row(id: "visible-held-next-b", model: "visible-held-next-b-model",
                    hidden: false, efforts: ["medium"]),
            ],
            pageMetadata: [])
        var events: [String] = []
        var overlap: CodexModelUpdateOutcome?
        var updater: CodexModelUpdater!
        updater = CodexModelUpdater(
            settings: store,
            source: CodexModelCatalogSource(discover: { checkedAt in
                events.append("catalog:\(checkedAt)")
                return ModelCatalogCheckResult(
                    catalog: catalog, checkedAt: checkedAt,
                    isStale: false, diagnostic: .current)
            }),
            promptAudit: { pair in
                events.append("audit:\(pair.model):\(pair.effort)")
                if pair.model == "target-a" {
                    try? store.selectProvider(.local, for: .cleanupL1)
                    try? store.setPromptOverride(
                        "PROMPT CHANGED DURING AUDIT",
                        for: .cleanupL1, provider: .codex)
                }
                if pair.model == "target-c" {
                    try? store.syncCustomRoutes([:])
                    overlap = updater.run()
                }
                return CodexModelPromptAuditReceipt(
                    model: pair.model, effort: pair.effort,
                    boundaryIdentity: "identity-\(pair.model)")
            },
            smoke: { pair, receipt in
                events.append("smoke:\(pair.model):\(pair.effort)")
                guard receipt.model == pair.model,
                      receipt.effort == pair.effort else { return false }
                if pair.model == "target-a" {
                    try? store.setRememberedBundle(
                        .codex("user-edited-during-smoke", effort: "ultra"),
                        for: .codex, route: .cleanupL2)
                }
                return pair.model != "target-b"
            },
            now: { Date(timeIntervalSince1970: 1_775_000_000) })

        let outcome = updater.run()
        check("catalog is acquired first and every smoke follows its exact-pair prompt audit",
              events.first?.hasPrefix("catalog:") == true
                && ordered(events, "audit:target-a:high", before: "smoke:target-a:high")
                && ordered(events, "audit:target-b:low", before: "smoke:target-b:low")
                && ordered(events, "audit:target-c:medium", before: "smoke:target-c:medium"))
        check("qualification deduplicates by exact model and effort pair",
              events.filter { $0 == "audit:target-a:high" }.count == 1
                && events.filter { $0 == "smoke:target-a:high" }.count == 1)
        check("one failed pair holds only routes that depend on that exact pair",
              outcome.held == [.cleanupL3]
                && outcome.applied == [.cleanupL1, .promptPrep])
        check("a user bundle edit wins while unrelated selected-provider and prompt edits survive",
              outcome.skipped == [.cleanupL2, deletedCustom]
                && store.rememberedBundle(for: .codex, route: .cleanupL2)?.modelID
                    == "user-edited-during-smoke"
                && store.selectedBundle(for: .cleanupL1).provider == .local
                && store.effectivePrompt(
                    for: .cleanupL1, provider: .codex) == "PROMPT CHANGED DURING AUDIT")
        check("a custom route deleted during qualification stays deleted",
              !store.routeIDs().contains(deletedCustom)
                && store.rememberedBundle(for: .codex, route: deletedCustom) == nil)
        check("visible recommendations remain runnable and untouched",
              outcome.recommendations == [.email]
                && store.rememberedBundle(for: .codex, route: .email)
                    == canonicalVisible
                && !events.contains("audit:visible-next:high")
                && !events.contains("smoke:visible-next:high"))
        check("a visible-route planner hold is classification only and never rewrites or gates it",
              outcome.plannerHolds[.searchLocalSynth]
                    == .conflictingUpgradeTargets
                && !outcome.held.contains(.searchLocalSynth)
                && store.selectedBundle(for: .searchLocalSynth).provider == .codex
                && store.rememberedBundle(for: .codex, route: .searchLocalSynth)
                    == canonicalVisibleHold
                && !events.contains { $0.contains("visible-held-next") })
        let classificationOnly = CodexModelUpdateOutcome(
            status: .held,
            checkedAt: outcome.checkedAt,
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [.searchLocalSynth: .conflictingUpgradeTargets])
        check("classification-only holds on visible runnable routes keep the success cadence",
              classificationOnly.scheduleCompletion == .success)
        check("overlapping updater runs coalesce without a second catalog acquisition",
              overlap?.status == .coalesced
                && events.filter { $0.hasPrefix("catalog:") }.count == 1)
        let migrated = store.rememberedBundle(for: .codex, route: .cleanupL1)
        check("successful migrations retain old ratification and add honest unratified provenance",
              migrated?.modelID == "target-a"
                && migrated?.effort == "high"
                && migrated?.ratified == oldA.ratified
                && migrated?.autoUpdated?.fromModelID == "old-a"
                && migrated?.autoUpdated?.reason == .deprecation)
        try? store.restoreProviderDefault(.codex, for: .cleanupL1)
        check("Restore uses the qualified migrated default and cannot resurrect its source id",
              store.selectedBundle(for: .cleanupL1).modelID == "target-a"
                && store.selectedBundle(for: .cleanupL1).autoUpdated?.fromModelID
                    == "old-a")
        try? store.applyGlobalProvider(.codex)
        check("global Codex selection also preserves each qualified migrated default",
              store.selectedBundle(for: .cleanupL1).modelID == "target-a")
        try? store.setSelectedBundle(
            .codex("manual-after-migration", effort: "wild"),
            for: .cleanupL1)
        let reopenedAfterManual = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("models-power.json"))
        try? reopenedAfterManual.restoreProviderDefault(.codex, for: .cleanupL1)
        check("Restore retains qualified default authority after relaunch and a later manual selection",
              reopenedAfterManual.selectedBundle(for: .cleanupL1).modelID == "target-a"
                && reopenedAfterManual.selectedBundle(for: .cleanupL1)
                    .autoUpdated?.fromModelID
                    == "old-a")

        let staleRoot = scratch("vd-codex-stale")
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        var staleWrites = 0
        let staleStore = ModelsPowerSettingsStore(
            url: staleRoot.appendingPathComponent("models-power.json"),
            writer: { data, destination in
                staleWrites += 1
                try ModelsPowerSettingsStore.atomicWriter(data, destination)
            })
        try? staleStore.setRememberedBundle(
            oldA, for: .codex, route: .cleanupL1)
        staleWrites = 0
        var staleAuditCalls = 0
        var staleSmokeCalls = 0
        let staleUpdater = CodexModelUpdater(
            settings: staleStore,
            source: CodexModelCatalogSource(discover: { _ in
                ModelCatalogCheckResult(
                    catalog: catalog, checkedAt: "prior",
                    isStale: true, diagnostic: .timeout)
            }),
            promptAudit: { pair in
                staleAuditCalls += 1
                return CodexModelPromptAuditReceipt(
                    model: pair.model, effort: pair.effort,
                    boundaryIdentity: "must-not-run")
            },
            smoke: { _, _ in staleSmokeCalls += 1; return true },
            now: { Date(timeIntervalSince1970: 1_775_000_100) })
        let stale = staleUpdater.run()
        check("catalog failure performs zero prompt audits, smokes, and settings writes",
              stale.status == .catalogFailed(.timeout)
                && staleAuditCalls == 0 && staleSmokeCalls == 0
                && staleWrites == 0
                && stale.applied.isEmpty && stale.skipped.isEmpty)

        let pairRoot = scratch("vd-codex-exact-pairs")
        defer { try? FileManager.default.removeItem(at: pairRoot) }
        let pairStore = ModelsPowerSettingsStore(
            url: pairRoot.appendingPathComponent("models-power.json"))
        try? pairStore.setRememberedBundle(
            .codex("pair-source-high", effort: "high"),
            for: .codex, route: .cleanupL1)
        try? pairStore.setRememberedBundle(
            .codex("pair-source-low", effort: "low"),
            for: .codex, route: .cleanupL2)
        try? pairStore.setRememberedBundle(
            .codex("prompt-fail-source", effort: "medium"),
            for: .codex, route: .cleanupL3)
        let pairCatalog = ModelCatalog(
            rows: [
                row(id: "pair-source-high-id", model: "pair-source-high", hidden: true,
                    efforts: ["high"], upgrade: "shared-target-id"),
                row(id: "pair-source-low-id", model: "pair-source-low", hidden: true,
                    efforts: ["low"], upgrade: "shared-target-id"),
                row(id: "shared-target-id", model: "shared-target", hidden: false,
                    efforts: ["high", "low"]),
                row(id: "prompt-fail-source-id", model: "prompt-fail-source", hidden: true,
                    efforts: ["medium"], upgrade: "prompt-fail-target-id"),
                row(id: "prompt-fail-target-id", model: "prompt-fail-target", hidden: false,
                    efforts: ["medium"]),
            ], pageMetadata: [])
        var auditedPairs: [ModelQualification] = []
        var smokedPairs: [ModelQualification] = []
        let pairUpdater = CodexModelUpdater(
            settings: pairStore,
            source: CodexModelCatalogSource(discover: {
                ModelCatalogCheckResult(
                    catalog: pairCatalog, checkedAt: $0,
                    isStale: false, diagnostic: .current)
            }),
            promptAudit: { pair in
                auditedPairs.append(pair)
                guard pair.model != "prompt-fail-target" else { return nil }
                return CodexModelPromptAuditReceipt(
                    model: pair.model, effort: pair.effort,
                    boundaryIdentity: "pair-\(pair.effort)")
            },
            smoke: { pair, _ in smokedPairs.append(pair); return true },
            now: { Date(timeIntervalSince1970: 1_775_000_150) })
        let pairOutcome = pairUpdater.run()
        check("qualification identity includes effort when one target model has two exact pairs",
              Set(auditedPairs) == Set([
                ModelQualification(model: "shared-target", effort: "high"),
                ModelQualification(model: "shared-target", effort: "low"),
                ModelQualification(model: "prompt-fail-target", effort: "medium"),
              ])
                && Set(smokedPairs) == Set([
                    ModelQualification(model: "shared-target", effort: "high"),
                    ModelQualification(model: "shared-target", effort: "low"),
                ])
                && pairOutcome.applied == [.cleanupL1, .cleanupL2])
        check("a failed no-inference prompt audit withholds smoke and holds only that pair's route",
              !smokedPairs.contains(
                ModelQualification(
                    model: "prompt-fail-target", effort: "medium"))
                && pairOutcome.held == [.cleanupL3]
                && pairStore.rememberedBundle(
                    for: .codex, route: .cleanupL3)?.modelID
                    == "prompt-fail-source")

        let idempotentRoot = scratch("vd-codex-idempotent")
        defer { try? FileManager.default.removeItem(at: idempotentRoot) }
        var writes = 0
        let idempotentStore = ModelsPowerSettingsStore(
            url: idempotentRoot.appendingPathComponent("models-power.json"),
            writer: { data, destination in
                writes += 1
                try ModelsPowerSettingsStore.atomicWriter(data, destination)
            })
        try? idempotentStore.setRememberedBundle(
            oldA, for: .codex, route: .cleanupL1)
        writes = 0
        let idempotentUpdater = CodexModelUpdater(
            settings: idempotentStore,
            source: CodexModelCatalogSource(discover: { checkedAt in
                ModelCatalogCheckResult(
                    catalog: ModelCatalog(
                        rows: [
                            self.row(
                                id: "old-a-id", model: "old-a", hidden: true,
                                efforts: ["high"], upgrade: "target-a-id"),
                            self.row(
                                id: "target-a-id", model: "target-a", hidden: false,
                                efforts: ["high"]),
                        ], pageMetadata: []),
                    checkedAt: checkedAt, isStale: false, diagnostic: .current)
            }),
            promptAudit: {
                CodexModelPromptAuditReceipt(
                    model: $0.model, effort: $0.effort,
                    boundaryIdentity: "stable")
            },
            smoke: { _, _ in true },
            now: { Date(timeIntervalSince1970: 1_775_000_200) })
        let first = idempotentUpdater.run()
        let firstWrites = writes
        let second = idempotentUpdater.run()
        check("successful unchanged candidates persist once and a second check is idempotent",
              first.applied == [.cleanupL1] && firstWrites == 1
                && second.applied.isEmpty && writes == firstWrites
                && ModelsPowerSettingsStore(
                    url: idempotentRoot.appendingPathComponent("models-power.json"))
                    .rememberedBundle(for: .codex, route: .cleanupL1)?.modelID == "target-a")
    }

    private static func checkScheduler(_ check: (String, Bool) -> Void) {
        print("--- Codex-only recurring schedule and bounded backoff ---")
        let policy = CodexModelUpdateSchedulePolicy(
            initialDelay: 60, successInterval: 3_600,
            idleRetryInterval: 30, failureBackoff: [120, 300])
        let schedule = CodexModelUpdateSchedule(policy: policy)

        schedule.launched(enabled: true, now: 0)
        check("post-launch Codex check is armed at the pinned delay",
              schedule.nextCheckAt == 60)
        check("first idle post-launch due time fires",
              schedule.takeDue(now: 60, isIdle: true))
        schedule.completed(.success, now: 60)
        check("success re-arms the first recurring interval",
              schedule.nextCheckAt == 3_660
                && schedule.takeDue(now: 3_660, isIdle: true))
        schedule.completed(.success, now: 3_660)
        check("a second recurring successful interval is pinned",
              schedule.nextCheckAt == 7_260
                && schedule.takeDue(now: 7_260, isIdle: true))

        schedule.completed(.failure, now: 7_260)
        check("failure uses the first bounded backoff and re-arms",
              schedule.nextCheckAt == 7_380
                && schedule.takeDue(now: 7_380, isIdle: true))
        schedule.completed(.failure, now: 7_380)
        check("repeated failure advances to the bounded maximum backoff",
              schedule.nextCheckAt == 7_680
                && schedule.takeDue(now: 7_680, isIdle: true))
        schedule.completed(.success, now: 7_680)
        check("recovery resets backoff and restores the success interval",
              schedule.nextCheckAt == 11_280)

        check("active dictation defers a due metadata check without running it",
              !schedule.takeDue(now: 11_280, isIdle: false)
                && schedule.nextCheckAt == 11_310)
        schedule.becameIdle(now: 11_281)
        check("becoming idle advances a deferred check and it can fire immediately",
              schedule.nextCheckAt == 11_281
                && schedule.takeDue(now: 11_281, isIdle: true))
        schedule.completed(.coalesced, now: 11_281)
        check("a coalesced overlap still re-arms deterministically",
              schedule.nextCheckAt == 11_311)

        schedule.setEnabled(false, now: 12_000)
        check("disable cancels the Codex periodic rail",
              schedule.nextCheckAt == nil
                && !schedule.takeDue(now: 99_999, isIdle: true))
        schedule.setEnabled(true, now: 12_000)
        check("enable after launch arms a fresh idle-gated check",
              schedule.nextCheckAt == 12_060)
        schedule.woke(now: 12_010)
        check("wake re-arms immediately and remains idle-gated",
              schedule.nextCheckAt == 12_010
                && !schedule.takeDue(now: 12_010, isIdle: false))
        schedule.clockChanged(now: 50_000)
        check("a wall-clock jump re-arms from the new clock without extending stale deadlines",
              schedule.nextCheckAt == 50_000
                && schedule.takeDue(now: 50_000, isIdle: true))
        schedule.completed(.failure, now: 50_000)
        check("every clock-jump outcome re-arms through bounded backoff",
              schedule.nextCheckAt == 50_120)
    }

    private static func checkCorrectiveHoldSurfaces(
        _ check: (String, Bool) -> Void
    ) {
        print("--- corrective hold visibility and blocking-reason surfaces ---")

        func seededStore(_ prefix: String) -> (URL, ModelsPowerSettingsStore) {
            let root = scratch(prefix)
            let store = ModelsPowerSettingsStore(
                url: root.appendingPathComponent("models-power.json"))
            for route in LLMRouteID.builtIns {
                try? store.setRememberedBundle(
                    .codex("known-visible", effort: "low"),
                    for: .codex,
                    route: route)
            }
            return (root, store)
        }

        func updater(
            store: ModelsPowerSettingsStore,
            catalog: ModelCatalog,
            at timestamp: TimeInterval
        ) -> CodexModelUpdateOutcome {
            CodexModelUpdater(
                settings: store,
                source: CodexModelCatalogSource(discover: {
                    ModelCatalogCheckResult(
                        catalog: catalog,
                        checkedAt: $0,
                        isStale: false,
                        diagnostic: .current)
                }),
                promptAudit: { _ in nil },
                smoke: { _, _ in false },
                now: { Date(timeIntervalSince1970: timestamp) })
                .run()
        }

        let (absentRoot, absentStore) = seededStore("vd-codex-hold-absent")
        defer { try? FileManager.default.removeItem(at: absentRoot) }
        try? absentStore.setRememberedBundle(
            .codex("typed-custom-model", effort: "low"),
            for: .codex,
            route: .cleanupL1)
        let absent = updater(
            store: absentStore,
            catalog: ModelCatalog(
                rows: [
                    row(
                        id: "known-visible-id",
                        model: "known-visible",
                        hidden: false,
                        efforts: ["low"]),
                ],
                pageMetadata: []),
            at: 1_775_000_300)
        let absentOutcomeURL = absentRoot.appendingPathComponent("outcome.json")
        let absentOutcomeStore = CodexUpdateOutcomeStore(url: absentOutcomeURL)
        absentOutcomeStore.complete(absent, nextRetry: nil)
        let absentStatus = CodexUpdateSurface.statusText(absentOutcomeStore.latest)
        check("absent catalog source stays runnable without a false visibility claim",
              absent.plannerHolds[.cleanupL1] == .unknownSource
                && absent.blockingPlannerHolds.isEmpty
                && absentOutcomeStore.latest?.state == .classificationHeld
                && absentStatus.contains(
                    "route remains runnable and unchanged; catalog visibility is not established")
                && !absentStatus.contains("visible route")
                && CodexUpdateSurface.toastLines(for: absent) == [
                    "Codex route classification held (unknown_source); route remains runnable and unchanged; catalog visibility is not established",
                ])

        let (malformedRoot, malformedStore) = seededStore(
            "vd-codex-hold-malformed")
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        try? malformedStore.setRememberedBundle(
            .codex("duplicate-model", effort: "low"),
            for: .codex,
            route: .cleanupL1)
        let malformed = updater(
            store: malformedStore,
            catalog: ModelCatalog(
                rows: [
                    row(
                        id: "known-visible-id",
                        model: "known-visible",
                        hidden: false,
                        efforts: ["low"]),
                    row(
                        id: "duplicate-a",
                        model: "duplicate-model",
                        hidden: false,
                        efforts: ["low"]),
                    row(
                        id: "duplicate-b",
                        model: "duplicate-model",
                        hidden: false,
                        efforts: ["low"]),
                ],
                pageMetadata: []),
            at: 1_775_000_310)
        let malformedOutcomeStore = CodexUpdateOutcomeStore(
            url: malformedRoot.appendingPathComponent("outcome.json"))
        malformedOutcomeStore.complete(malformed, nextRetry: nil)
        let malformedStatus = CodexUpdateSurface.statusText(
            malformedOutcomeStore.latest)
        check("malformed catalog hold stays runnable without a false visibility claim",
              malformed.plannerHolds[.cleanupL1] == .duplicateCatalogModel
                && malformed.blockingPlannerHolds.isEmpty
                && malformedOutcomeStore.latest?.state == .classificationHeld
                && malformedStatus.contains(
                    "route remains runnable and unchanged; catalog visibility is not established")
                && !malformedStatus.contains("visible route")
                && CodexUpdateSurface.toastLines(for: malformed) == [
                    "Codex route classification held (duplicate_catalog_model); route remains runnable and unchanged; catalog visibility is not established",
                ])

        let (mixedRoot, mixedStore) = seededStore("vd-codex-hold-mixed")
        defer { try? FileManager.default.removeItem(at: mixedRoot) }
        try? mixedStore.setRememberedBundle(
            .codex("typed-custom-model", effort: "low"),
            for: .codex,
            route: .cleanupL1)
        try? mixedStore.setRememberedBundle(
            .codex("hidden-without-upgrade", effort: "low"),
            for: .codex,
            route: .email)
        let mixed = updater(
            store: mixedStore,
            catalog: ModelCatalog(
                rows: [
                    row(
                        id: "known-visible-id",
                        model: "known-visible",
                        hidden: false,
                        efforts: ["low"]),
                    row(
                        id: "hidden-id",
                        model: "hidden-without-upgrade",
                        hidden: true,
                        efforts: ["low"]),
                ],
                pageMetadata: []),
            at: 1_775_000_320)
        let mixedOutcomeStore = CodexUpdateOutcomeStore(
            url: mixedRoot.appendingPathComponent("outcome.json"))
        mixedOutcomeStore.complete(mixed, nextRetry: nil)
        check("blocking hold reason outranks an earlier non-blocking route",
              mixed.plannerHolds[.cleanupL1] == .unknownSource
                && mixed.plannerHolds[.email] == .missingUpgrade
                && mixed.blockingPlannerHolds == [.email]
                && mixedOutcomeStore.latest?.state == .candidateHeld
                && mixedOutcomeStore.latest?.reasonCode
                    == "planner_missing_upgrade"
                && CodexUpdateSurface.toastLines(for: mixed) == [
                    "Codex candidate held (missing_upgrade); route unchanged",
                ])
    }

    private static func checkOutcomeRecordAndSurfaces(
        _ check: (String, Bool) -> Void
    ) {
        print("--- content-free Codex outcome persistence and truthful surfaces ---")
        let root = scratch("vd-codex-outcome")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("codex-update-outcome.json")
        let store = CodexUpdateOutcomeStore(url: url)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: CodexUpdateOutcomeStore.didChange,
            object: store,
            queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.beginAttempt(
            at: "2026-07-27T18:00:00Z",
            nextRetry: "2026-07-27T18:05:00Z")
        check("a generic check-pending record does not falsely claim quarantine",
              store.latest?.state == .checkPending
                && CodexUpdateSurface.statusText(store.latest)
                    .contains("catalog/compatibility check pending"))
        store.markCompatibilityQuarantinePending(
            at: "2026-07-27T18:00:01Z")
        check("actual compatibility quarantine pending is durable and explicit",
              store.latest?.state == .compatibilityQuarantinePending
                && CodexUpdateSurface.statusText(store.latest)
                    .contains("compatibility quarantine pending"))
        store.markCompatibilityQuarantineFinished(
            success: true,
            at: "2026-07-27T18:00:02Z")
        check("successful quarantine stops claiming pending before catalog acquisition",
              store.latest?.state == .compatibilityQuarantinePassed
                && CodexUpdateSurface.statusText(store.latest)
                    .contains("quarantine passed"))

        let unchanged = outcome(status: .current)
        store.complete(unchanged, nextRetry: "2026-07-28T00:00:00Z")
        check("checked/unchanged records the successful catalog time and next retry",
              store.latest?.state == .checkedUnchanged
                && store.latest?.lastAttempt == unchanged.checkedAt
                && store.latest?.lastSuccessfulCatalogTime == unchanged.checkedAt
                && store.latest?.reasonCode == nil
                && store.latest?.nextRetry == "2026-07-28T00:00:00Z"
                && CodexUpdateSurface.toastLines(for: unchanged)
                    == ["Codex catalog checked; routes unchanged"])

        let stale = outcome(status: .catalogFailed(.timeout))
        store.complete(stale, nextRetry: "2026-07-27T18:10:00Z")
        check("stale catalog keeps the prior successful time and a fixed reason code",
              store.latest?.state == .staleCatalog
                && store.latest?.lastSuccessfulCatalogTime == unchanged.checkedAt
                && store.latest?.reasonCode == "catalog_timeout"
                && CodexUpdateSurface.toastLines(for: stale)
                    == [
                        "Codex catalog stale or unavailable (timeout); routes unchanged",
                    ])
        let firstFailureURL = root.appendingPathComponent("first-failure.json")
        let firstFailure = CodexUpdateOutcomeStore(url: firstFailureURL)
        firstFailure.complete(stale, nextRetry: "2026-07-27T18:10:00Z")
        check("first catalog failure never invents last-known-good picker data",
              firstFailure.latest?.state == .staleCatalog
                && firstFailure.latest?.lastSuccessfulCatalogTime == nil
                && CodexUpdateSurface.statusText(firstFailure.latest)
                    .contains("no last-known-good catalog is available"))
        check("a persisted outcome reloads after relaunch",
              CodexUpdateOutcomeStore(url: url).latest == store.latest)
        check("every persisted outcome publishes the refresh signal used by an open settings window",
              notifications >= 3)

        let candidate = CodexModelUpdateOutcome(
            status: .held,
            checkedAt: "2026-07-27T18:02:00Z",
            applied: [],
            skipped: [],
            held: [.cleanupL1],
            recommendations: [],
            plannerHolds: [:])
        store.complete(candidate, nextRetry: "2026-07-27T18:07:00Z")
        check("candidate-held is distinct from catalog/provider failure",
              store.latest?.state == .candidateHeld
                && store.latest?.reasonCode == "qualification_failed"
                && CodexUpdateSurface.toastLines(for: candidate)
                    == ["Codex candidate held; qualification failed"])
        let classification = CodexModelUpdateOutcome(
            status: .held,
            checkedAt: "2026-07-27T18:02:30Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [.searchLocalSynth: .conflictingUpgradeTargets])
        store.complete(classification, nextRetry: "2026-07-28T00:02:30Z")
        check("visible classification hold remains distinct and truthfully runnable",
              store.latest?.state == .classificationHeld
                && CodexUpdateSurface.statusText(store.latest)
                    .contains("visible route remains runnable and unchanged")
                && CodexUpdateSurface.toastLines(for: classification)
                    == [
                        "Codex route classification held (conflicting_upgrade_targets); visible route remains runnable and unchanged",
                    ])

        let recommendation = CodexModelUpdateOutcome(
            status: .current,
            checkedAt: "2026-07-27T18:03:00Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [.email],
            plannerHolds: [:])
        check("recommendation status says the runnable route remains unchanged",
              CodexUpdateSurface.toastLines(for: recommendation)
                == ["Codex recommendation available; route unchanged"])
        let migrated = CodexModelUpdateOutcome(
            status: .current,
            checkedAt: "2026-07-27T18:04:00Z",
            applied: [.cleanupL1],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [:])
        check("migration status says replacements are unratified",
              CodexUpdateSurface.toastLines(for: migrated)
                == ["Codex routes migrated; replacements are unratified"])
        let quarantine = outcome(status: .catalogFailed(.compatibilityBoundary))
        check("compatibility quarantine failure is distinct from stale catalog",
              CodexUpdateSurface.toastLines(for: quarantine)
                == ["Codex compatibility quarantine failed; routes unchanged"])

        let bytes = (try? Data(contentsOf: url)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: bytes))
            as? [String: Any]
        let allowedKeys: Set<String> = [
            "version", "state", "lastAttempt", "lastSuccessfulCatalogTime",
            "reasonCode", "nextRetry",
        ]
        let text = String(decoding: bytes, as: UTF8.self)
        check("outcome persistence has only the structured content-free schema",
              object.map { Set($0.keys).isSubset(of: allowedKeys) } == true
                && !text.contains("displayName")
                && !text.contains("providerMetadata")
                && !text.contains("stderr")
                && !text.contains("upgradeCopy"))
        let untrustedURL = root.appendingPathComponent("untrusted-outcome.json")
        let untrusted = Data(#"""
        {
          "version": 1,
          "state": "candidate_held",
          "lastAttempt": "2026-07-27T18:05:00Z",
          "reasonCode": "stderr_SENTINEL",
          "nextRetry": "2026-07-27T18:10:00Z"
        }
        """#.utf8)
        try? untrusted.write(to: untrustedURL, options: .atomic)
        check("outcome reload rejects non-enumerated prose instead of surfacing raw process text",
              CodexUpdateOutcomeStore(url: untrustedURL).latest == nil)
        let untrustedTimestampURL = root.appendingPathComponent("untrusted-timestamp.json")
        let untrustedTimestamp = Data(#"""
        {
          "version": 1,
          "state": "candidate_held",
          "lastAttempt": "2026-07-27T18:05:00Z",
          "reasonCode": "candidate_held",
          "nextRetry": "stderr_SENTINEL"
        }
        """#.utf8)
        try? untrustedTimestamp.write(to: untrustedTimestampURL, options: .atomic)
        check("timestamp fields reject arbitrary process text",
              CodexUpdateOutcomeStore(url: untrustedTimestampURL).latest == nil)
    }

    private static func checkScheduledToastGate(
        _ check: (String, Bool) -> Void
    ) {
        print("--- scheduled Codex toast state/reason change gate ---")
        let root = scratch("vd-codex-scheduled-toast")
        defer { try? FileManager.default.removeItem(at: root) }
        let heldStore = CodexUpdateOutcomeStore(
            url: root.appendingPathComponent("held.json"))
        var heldGate = CodexScheduledToastGate()
        let stableHeld = CodexModelUpdateOutcome(
            status: .held,
            checkedAt: "2026-07-27T18:06:00Z",
            applied: [],
            skipped: [],
            held: [.cleanupL1],
            recommendations: [],
            plannerHolds: [:])
        let repeatedHeld = CodexModelUpdateOutcome(
            status: .held,
            checkedAt: "2026-07-27T18:07:00Z",
            applied: [],
            skipped: [],
            held: [.cleanupL1],
            recommendations: [],
            plannerHolds: [:])
        let firstHeldRecord = heldStore.complete(
            stableHeld,
            nextRetry: "2026-07-27T18:11:00Z")
        let firstHeldToast = heldGate.shouldPresentFullToast(
            for: stableHeld,
            record: firstHeldRecord)
        let repeatedHeldRecord = heldStore.complete(
            repeatedHeld,
            nextRetry: "2026-07-27T18:12:00Z")
        let repeatedHeldToast = heldGate.shouldPresentFullToast(
            for: repeatedHeld,
            record: repeatedHeldRecord)
        check("scheduled held outcome toasts on first observation and suppresses an unchanged repeat",
              firstHeldToast
                && !repeatedHeldToast
                && CodexUpdateSurface.requiresFullToast(stableHeld)
                && CodexUpdateSurface.requiresFullToast(repeatedHeld))
        check("suppressed scheduled toast still publishes the current live/status-window state",
              heldStore.latest == repeatedHeldRecord
                && repeatedHeldRecord.lastAttempt == repeatedHeld.checkedAt
                && CodexUpdateSurface.statusText(heldStore.latest)
                    .contains("Codex candidate held"))

        let changedHeldReason = CodexModelUpdateOutcome(
            status: .held,
            checkedAt: "2026-07-27T18:08:00Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [.email: .missingUpgrade],
            blockingPlannerHolds: [.email])
        let changedHeldRecord = heldStore.complete(
            changedHeldReason,
            nextRetry: "2026-07-27T18:13:00Z")
        check("scheduled held outcome re-toasts when its reason code changes",
              heldGate.shouldPresentFullToast(
                for: changedHeldReason,
                record: changedHeldRecord)
                && changedHeldRecord.state == repeatedHeldRecord.state
                && changedHeldRecord.reasonCode != repeatedHeldRecord.reasonCode)

        let staleURL = root.appendingPathComponent("stale.json")
        let staleStore = CodexUpdateOutcomeStore(url: staleURL)
        var staleGate = CodexScheduledToastGate()
        let stale = outcome(status: .catalogFailed(.timeout))
        let staleRepeat = CodexModelUpdateOutcome(
            status: .catalogFailed(.timeout),
            checkedAt: "2026-07-27T18:09:00Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [:])
        let staleChanged = CodexModelUpdateOutcome(
            status: .catalogFailed(.processFailure),
            checkedAt: "2026-07-27T18:10:00Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [:])
        let staleRecord = staleStore.complete(
            stale,
            nextRetry: "2026-07-27T18:11:00Z")
        let firstStaleToast = staleGate.shouldPresentFullToast(
            for: stale,
            record: staleRecord)
        let staleRepeatRecord = staleStore.complete(
            staleRepeat,
            nextRetry: "2026-07-27T18:14:00Z")
        let repeatedStaleToast = staleGate.shouldPresentFullToast(
            for: staleRepeat,
            record: staleRepeatRecord)
        let staleChangedRecord = staleStore.complete(
            staleChanged,
            nextRetry: "2026-07-27T18:15:00Z")
        let changedStaleToast = staleGate.shouldPresentFullToast(
            for: staleChanged,
            record: staleChangedRecord)
        check("scheduled stale outcome suppresses an unchanged repeat and re-toasts on reason change",
              firstStaleToast && !repeatedStaleToast && changedStaleToast
                && staleRecord.state == staleRepeatRecord.state
                && staleRepeatRecord.state == staleChangedRecord.state
                && staleRecord.reasonCode == staleRepeatRecord.reasonCode
                && staleRepeatRecord.reasonCode != staleChangedRecord.reasonCode)

        let reloadedStore = CodexUpdateOutcomeStore(url: staleURL)
        var relaunchedGate = CodexScheduledToastGate()
        check("first scheduled observation after launch toasts even when the same state was persisted",
              reloadedStore.latest == staleChangedRecord
                && relaunchedGate.shouldPresentFullToast(
                    for: staleChanged,
                    record: staleChangedRecord))
    }

    private static func outcome(
        status: CodexModelUpdateStatus
    ) -> CodexModelUpdateOutcome {
        CodexModelUpdateOutcome(
            status: status,
            checkedAt: "2026-07-27T18:01:00Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [:])
    }

    private static func scratch(_ prefix: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func row(
        id: String,
        model: String,
        hidden: Bool,
        efforts: [String],
        upgrade: String? = nil,
        structuredUpgrade: String? = nil
    ) -> ModelCatalogRow {
        ModelCatalogRow(
            id: id,
            model: model,
            displayName: nil,
            description: nil,
            hidden: hidden,
            defaultReasoningEffort: efforts.first,
            supportedReasoningEfforts: efforts.map {
                ModelCatalogReasoningEffort(
                    reasoningEffort: $0, description: nil, unknownFields: [:])
            },
            inputModalities: ["text"],
            supportsPersonality: nil,
            isDefault: nil,
            upgrade: upgrade,
            upgradeInfo: structuredUpgrade.map {
                ModelCatalogUpgradeInfo(
                    model: $0,
                    upgradeCopy: nil,
                    modelLink: nil,
                    migrationMarkdown: nil,
                    unknownFields: [:])
            },
            unknownFields: [:])
    }

    private static func ordered(
        _ events: [String],
        _ first: String,
        before second: String
    ) -> Bool {
        guard let a = events.firstIndex(of: first),
              let b = events.firstIndex(of: second) else { return false }
        return a < b
    }
}
