import Foundation

/// Pure, injected-seam coverage for the local-model capacity choke point. No kernel facts, LM Studio,
/// model load, user data, or GUI are touched.
enum ModelCapacitySelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate local model capacity policy - selftest ===")
        let reporter = SelfTestReporter()

        parserChecks(reporter)
        factorAndMissingFactChecks(reporter)
        ownershipAndEvictionChecks(reporter)
        onePassCheck(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Model capacity"))
        return reporter.passed
    }

    private static func parserChecks(_ reporter: SelfTestReporter) {
        let fixture = Data("""
        [
          {"identifier":"foreign/embed","sizeBytes":634553760,"ttlMs":null,
           "lastUsedTime":1787551824934,"contextLength":8192,"maxContextLength":8192,
           "status":"idle"},
          {"identifier":"owned/busy","sizeBytes":17190793452,"ttlMs":600000,
           "lastUsedTime":1787551825999,"contextLength":32768,"maxContextLength":262144,
           "status":"loading"}
        ]
        """.utf8)
        let parsed = ModelResidency.parseResidentModelsJSON(fixture)
        reporter.record(
            "lms ps parser retains identifier, size, last-use time, and status",
            parsed == [
                resident("foreign/embed", 634_553_760, 1_787_551_824_934, "idle"),
                resident("owned/busy", 17_190_793_452, 1_787_551_825_999, "loading"),
            ])
        reporter.record(
            "lms ps parser fails closed on malformed JSON",
            ModelResidency.parseResidentModelsJSON(Data("not json".utf8)) == nil)
        reporter.record(
            "lms ps parser fails closed on an incomplete resident row",
            ModelResidency.parseResidentModelsJSON(
                Data("[{\"identifier\":\"missing-last-use\",\"sizeBytes\":1,\"status\":\"idle\"}]".utf8)
            ) == nil)
    }

    private static func factorAndMissingFactChecks(_ reporter: SelfTestReporter) {
        reporter.record(
            "incoming estimate applies the shipped footprint factor and rounds upward",
            ModelManager.estimatedIncomingBytes(sizeBytes: 101) == 117,
            "factor=\(ModelManager.incomingFootprintFactor)")

        func result(
            installed: [LMStudioInstalledModel]? = [installedModel("incoming", size: 100)],
            residents: [ModelResidency.ResidentModel]? = [],
            wired: UInt64? = 10,
            budget: UInt64? = 1_000,
            loadSucceeds: Bool = true
        ) -> ModelManager.ReadinessResult {
            ModelManager().ensureReady(
                "incoming", ttlOverrideSeconds: 600,
                dependencies: .init(
                    availableInstalledModels: { installed },
                    residentModels: { residents },
                    wiredBytes: { wired },
                    budgetBytes: { _ in budget },
                    ensureLoaded: { _, _ in loadSucceeds },
                    unload: { _ in }))
        }

        reporter.record("missing resident snapshot refuses softly with a typed capacity result",
                        result(residents: nil) == .capacityRefused(.factsUnavailable))
        reporter.record("missing installed catalog refuses softly with a typed capacity result",
                        result(installed: nil) == .capacityRefused(.factsUnavailable))
        reporter.record("missing installed size refuses softly with a typed capacity result",
                        result(installed: [installedModel("incoming", size: nil)])
                            == .capacityRefused(.factsUnavailable))
        reporter.record("missing wired reading refuses softly with a typed capacity result",
                        result(wired: nil) == .capacityRefused(.factsUnavailable))
        reporter.record("missing wire-limit budget refuses softly with a typed capacity result",
                        result(budget: nil) == .capacityRefused(.factsUnavailable))
        reporter.record("LM Studio load failure remains distinct from a capacity refusal",
                        result(loadSucceeds: false) == .loadFailed)
    }

    private static func ownershipAndEvictionChecks(_ reporter: SelfTestReporter) {
        let manager = ModelManager()
        var residents: [ModelResidency.ResidentModel] = []
        var unloads: [String] = []
        var loads: [String] = []
        var wired: UInt64 = 0
        var budgetPositions: [Double] = []
        let installed = [
            installedModel("foreign/huge", size: 900),
            installedModel("owned/old", size: 10),
            installedModel("owned/new", size: 10),
            installedModel("owned/busy", size: 10),
            installedModel("incoming", size: 100),
        ]
        let dependencies = ModelManager.CapacityDependencies(
            availableInstalledModels: { installed },
            residentModels: { residents },
            wiredBytes: { wired },
            budgetBytes: { position in budgetPositions.append(position); return 1_000 },
            ensureLoaded: { model, _ in
                loads.append(model)
                let lastUse: UInt64 = [
                    "owned/old": 20, "owned/new": 30, "owned/busy": 10, "incoming": 40,
                ][model] ?? 1
                residents.append(resident(model, 10, lastUse, "idle"))
                return true
            },
            unload: { model in
                unloads.append(model)
                residents.removeAll { $0.identifier == model }
            })

        // A model found resident before any app cold load is foreign, even if its identifier could be
        // selected by ViddyDictate. Merely reusing it must not adopt it into the eviction set.
        residents = [resident("foreign/huge", 900, 1, "idle")]
        let foreignReuse = manager.ensureReady(
            "foreign/huge", ttlOverrideSeconds: 600, dependencies: dependencies)
        reporter.record("reusing a foreign resident model does not reload it",
                        foreignReuse == .ready && loads.isEmpty)

        for owned in ["owned/old", "owned/new", "owned/busy"] {
            let loaded = manager.ensureReady(
                owned, ttlOverrideSeconds: 600, dependencies: dependencies)
            reporter.record("test setup cold-loads \(owned) through ensureReady", loaded == .ready)
        }
        residents = residents.map {
            $0.identifier == "owned/busy"
                ? resident($0.identifier, $0.sizeBytes, $0.lastUsedTime, "loading")
                : $0
        }

        unloads.removeAll()
        loads.removeAll()
        wired = 900 // 900 + ceil(100 * 1.15) = 1015, so the pass is required.
        var wiredReads = 0
        let capacityDependencies = ModelManager.CapacityDependencies(
            availableInstalledModels: dependencies.availableInstalledModels,
            residentModels: dependencies.residentModels,
            wiredBytes: {
                wiredReads += 1
                return wiredReads == 1 ? 900 : 700
            },
            budgetBytes: dependencies.budgetBytes,
            ensureLoaded: dependencies.ensureLoaded,
            unload: dependencies.unload)
        let incoming = manager.ensureReady(
            "incoming", ttlOverrideSeconds: 600, dependencies: capacityDependencies)

        reporter.record("one eviction snapshot is attempted LRU-first among idle owned models",
                        unloads == ["owned/old", "owned/new"], "unloads=\(unloads)")
        reporter.record(
            "foreign and busy models survive self-eviction",
            residents.contains { $0.identifier == "foreign/huge" }
                && residents.contains { $0.identifier == "owned/busy" })
        reporter.record(
            "foreign model is pinned even when it is older and larger than every owned candidate",
            !unloads.contains("foreign/huge"))
        reporter.record("capacity is rechecked once, then the requested model loads",
                        incoming == .ready && wiredReads == 2 && loads == ["incoming"])
        reporter.record("policy reads L2's persisted budget slider position",
                        !budgetPositions.isEmpty
                            && budgetPositions.allSatisfy {
                                $0 == Settings.modelMemoryBudgetSliderPosition
                            })
    }

    private static func onePassCheck(_ reporter: SelfTestReporter) {
        let manager = ModelManager()
        var residents: [ModelResidency.ResidentModel] = []
        var unloads: [String] = []
        var loads: [String] = []
        var wiredReads = 0
        var residentReads = 0
        let installed = [
            installedModel("owned", size: 10),
            installedModel("incoming", size: 100),
        ]
        let setup = ModelManager.CapacityDependencies(
            availableInstalledModels: { installed },
            residentModels: { residents },
            wiredBytes: { 0 },
            budgetBytes: { _ in 1_000 },
            ensureLoaded: { model, _ in
                residents.append(resident(model, 10, 1, "idle")); return true
            },
            unload: { _ in })
        let setupResult = manager.ensureReady("owned", ttlOverrideSeconds: 600, dependencies: setup)
        reporter.record("one-pass setup owns one cold-loaded model", setupResult == .ready)

        let blocked = ModelManager.CapacityDependencies(
            availableInstalledModels: { installed },
            residentModels: { residentReads += 1; return residents },
            wiredBytes: { wiredReads += 1; return 950 },
            budgetBytes: { _ in 1_000 },
            ensureLoaded: { model, _ in loads.append(model); return true },
            unload: { model in unloads.append(model) })
        let outcome = manager.ensureReady(
            "incoming", ttlOverrideSeconds: 600, dependencies: blocked)
        reporter.record("still-over-budget returns the typed refusal after one pass",
                        outcome == .capacityRefused(.overBudget))
        reporter.record("the over-budget path takes one resident snapshot and two wired readings",
                        residentReads == 1 && wiredReads == 2,
                        "residentReads=\(residentReads) wiredReads=\(wiredReads)")
        reporter.record("one pass attempts each eligible owned model once and never loads incoming",
                        unloads == ["owned"] && loads.isEmpty,
                        "unloads=\(unloads) loads=\(loads)")
    }

    private static func resident(
        _ identifier: String, _ sizeBytes: UInt64, _ lastUsedTime: UInt64, _ status: String
    ) -> ModelResidency.ResidentModel {
        .init(identifier: identifier, sizeBytes: sizeBytes,
              lastUsedTime: lastUsedTime, status: status)
    }

    private static func installedModel(_ id: String, size: Int64?) -> LMStudioInstalledModel {
        .init(modelID: id, label: id, type: "llm", sizeBytes: size, visionFlag: false)
    }
}
