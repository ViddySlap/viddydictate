import Foundation

/// Pure, injected-seam coverage for the local-model capacity choke point. No kernel facts, LM Studio,
/// model load, user data, or GUI are touched.
enum ModelCapacitySelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate local model capacity policy - selftest ===")
        let reporter = SelfTestReporter()

        parserChecks(reporter)
        factorAndMissingFactChecks(reporter)
        residentBypassLoggingChecks(reporter)
        clientWiringAndGeminiOrderingChecks(reporter)
        productionCallSiteChecks(reporter)
        ownershipAndEvictionChecks(reporter)
        missingRecencyEvictionChecks(reporter)
        onePassCheck(reporter)
        evictionSettleChecks(reporter)

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
            "lms ps parser retains identifier, size, last-use time, status, and TTL",
            parsed == [
                resident("foreign/embed", 634_553_760, 1_787_551_824_934, "idle"),
                resident("owned/busy", 17_190_793_452, 1_787_551_825_999, "loading", ttl: 600),
            ])
        // `ttlMs: null` is a model LM Studio holds with no timeout at all - the state that pinned 28.7 GB
        // for an hour on 2026-08-21. It is a FACT about the row, not a hole in it, so it must not fail the
        // snapshot the way a missing size does.
        reporter.record(
            "a model loaded with no TTL parses as resident without one, rather than failing the snapshot",
            parsed?.first?.ttlSeconds == nil && parsed?.count == 2)
        reporter.record(
            "the TTL comes from the same row as the size, not a second lms ps",
            parsed?.last?.ttlSeconds == 600, "\(parsed?.last?.ttlSeconds as Int? ?? -1)")
        reporter.record(
            "lms ps parser fails closed on malformed JSON",
            ModelResidency.parseResidentModelsJSON(Data("not json".utf8)) == nil)
        let generatingFixture = Data((
            "[{\"identifier\":\"generating/model\",\"sizeBytes\":1234,"
                + "\"lastUsedTime\":null,\"status\":\"generating\"}]"
        ).utf8)
        let generating = ModelResidency.parseResidentModelsJSON(generatingFixture)
        reporter.record(
            "a generating row with null last-use time remains a complete resident snapshot",
            generating?.count == 1 && generating?.first?.lastUsedTime == nil)
        reporter.record(
            "a generating row's size remains in the resident capacity total",
            generating?.reduce(UInt64.zero) { $0 + $1.sizeBytes } == 1_234,
            "residentBytes=\(generating?.reduce(UInt64.zero) { $0 + $1.sizeBytes } ?? 0)")
        for (field, json) in [
            ("identifier", "[{\"sizeBytes\":1,\"lastUsedTime\":1,\"status\":\"idle\"}]"),
            ("sizeBytes", "[{\"identifier\":\"missing-size\",\"lastUsedTime\":1,\"status\":\"idle\"}]"),
            ("status", "[{\"identifier\":\"missing-status\",\"sizeBytes\":1,\"lastUsedTime\":1}]"),
        ] {
            reporter.record(
                "lms ps parser fails closed when required \(field) is missing",
                ModelResidency.parseResidentModelsJSON(Data(json.utf8)) == nil)
        }
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
                    unload: { _ in },
                    log: { _ in }))
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

    private static func residentBypassLoggingChecks(_ reporter: SelfTestReporter) {
        let model = "fixture/already-resident"
        var catalogReads = 0
        var wiredReads = 0
        var budgetReads = 0
        var loads: [String] = []
        var unloads: [String] = []
        var logs: [String] = []

        func dependencies(budget: UInt64?) -> ModelManager.CapacityDependencies {
            ModelManager.CapacityDependencies(
                availableInstalledModels: {
                    catalogReads += 1
                    return nil
                },
                residentModels: { [resident(model, 1_200_000_000, 1, "idle")] },
                wiredBytes: {
                    wiredReads += 1
                    return nil
                },
                budgetBytes: { _ in
                    budgetReads += 1
                    return budget
                },
                ensureLoaded: { requested, _ in
                    loads.append(requested)
                    return true
                },
                unload: { unloads.append($0) },
                log: { logs.append($0) })
        }

        let overBudget = ModelManager().ensureReady(
            model, ttlOverrideSeconds: 600, dependencies: dependencies(budget: 1_000_000_000))
        reporter.record(
            "an already-resident model above the current budget remains ready without load or eviction",
            overBudget == .ready && catalogReads == 0 && wiredReads == 0
                && loads.isEmpty && unloads.isEmpty,
            "result=\(overBudget) catalogReads=\(catalogReads) wiredReads=\(wiredReads) "
                + "loads=\(loads) unloads=\(unloads)")
        reporter.record(
            "over-budget resident reuse logs the model footprint, budget, and no-new-allocation reason",
            logs == [
                "model capacity: fixture/already-resident is already resident at 1.2 GB, "
                    + "above the current 1.0 GB budget; reusing it because this request "
                    + "allocates no new model memory",
            ],
            "logs=\(logs)")

        logs.removeAll()
        let missingBudget = ModelManager().ensureReady(
            model, ttlOverrideSeconds: 600, dependencies: dependencies(budget: nil))
        reporter.record(
            "an unreadable budget cannot turn the already-resident shortcut into a refusal",
            missingBudget == .ready && logs.isEmpty && budgetReads == 2
                && catalogReads == 0 && wiredReads == 0 && loads.isEmpty && unloads.isEmpty,
            "result=\(missingBudget) budgetReads=\(budgetReads) logs=\(logs)")
    }

    private static func productionCallSiteChecks(_ reporter: SelfTestReporter) {
        let repo = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sources = repo.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            reporter.record(
                "production sources are readable for the direct ModelResidency load guard", false,
                "run the gate from the worktree root")
            return
        }

        let needle = "ModelResidency.ensureLoaded("
        var swiftFileCount = 0
        var directSites: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift",
                  !url.path.contains("/Sources/SelfTest/") else { continue }
            swiftFileCount += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                directSites.append("UNREADABLE:\(url.lastPathComponent)")
                continue
            }
            let count = text.components(separatedBy: needle).count - 1
            guard count > 0 else { continue }
            let relative = url.path.replacingOccurrences(of: repo.path + "/", with: "")
            directSites.append(contentsOf: Array(repeating: relative, count: count))
        }

        reporter.record(
            "production sources are readable for the direct ModelResidency load guard",
            swiftFileCount > 100,
            "swiftFiles=\(swiftFileCount)")
        reporter.record(
            "ModelManager is the only production call site allowed to reach ModelResidency.ensureLoaded",
            directSites == ["Sources/App/ModelManager.swift"],
            "directSites=\(directSites)")
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

    private static func clientWiringAndGeminiOrderingChecks(_ reporter: SelfTestReporter) {
        let overBudget = CleanupClient.failureResult(
            for: .capacityRefused(.overBudget), loadFailureMessage: "fixture load failed")!
        let factsUnavailable = CleanupClient.failureResult(
            for: .capacityRefused(.factsUnavailable), loadFailureMessage: "fixture load failed")!

        reporter.record(
            "over-budget refusal maps to Ben's exact unavailable string",
            unavailableMessage(overBudget) == CleanupClient.overBudgetMessage
                && CleanupClient.overBudgetMessage
                    == "Not enough space in RAM. Adjust local model settings under the Setup tab.")
        reporter.record(
            "unreadable memory facts map to a distinct honest unavailable string",
            unavailableMessage(factsUnavailable) == CleanupClient.memoryFactsUnavailableMessage
                && CleanupClient.memoryFactsUnavailableMessage
                    == "Memory facts could not be read, so the model was not loaded."
                && unavailableMessage(factsUnavailable) != unavailableMessage(overBudget))

        let overPresentation = TextTransformClient.safeFailurePresentation(for: overBudget)
        let factsPresentation = TextTransformClient.safeFailurePresentation(for: factsUnavailable)
        let quotaPresentation = TextTransformClient.safeFailurePresentation(
            for: .unavailable("gemini HTTP 429"))
        let auth401Presentation = TextTransformClient.safeFailurePresentation(
            for: .unavailable("gemini HTTP 401"))
        let auth403Presentation = TextTransformClient.safeFailurePresentation(
            for: .unavailable("gemini HTTP 403"))
        let ordinaryPresentation = TextTransformClient.safeFailurePresentation(
            for: .unavailable("fixture provider diagnostic that must stay hidden"))
        reporter.record(
            "capacity strings survive presentation intact",
            overPresentation?.userMessage == CleanupClient.overBudgetMessage
                && factsPresentation?.userMessage == CleanupClient.memoryFactsUnavailableMessage)
        reporter.record(
            "Gemini quota and auth statuses use short app-authored presentation sentences",
            quotaPresentation?.userMessage == CleanupClient.geminiSpendCapMessage
                && auth401Presentation?.userMessage == CleanupClient.geminiRejectedKeyMessage
                && auth403Presentation?.userMessage == CleanupClient.geminiRejectedKeyMessage
                && CleanupClient.geminiSpendCapMessage.contains("Google AI Studio")
                && CleanupClient.geminiSpendCapMessage.contains("spend cap")
                && CleanupClient.geminiRejectedKeyMessage.contains("Settings")
                && (CleanupClient.geminiSpendCapMessage
                    + CleanupClient.geminiRejectedKeyMessage).allSatisfy(\.isASCII))
        reporter.record(
            "ordinary provider diagnostics remain generic",
            ordinaryPresentation?.userMessage == "Selected provider is unavailable")

        // LD3: every PROVIDER FAILURE renders the same way, so this seam must carry NOTHING that could
        // route one of those sentences to a different window than another. A future field that does is
        // the regression this pins; the pill's ability to hold the longest sentence is pinned in the
        // offscreen render gate, where real font metrics exist.
        reporter.record(
            "presentation carries only the safe sentence, with no per-message rendering escape",
            Mirror(reflecting: TextTransformClient.FailurePresentation(userMessage: "x"))
                .children.compactMap(\.label) == ["userMessage"])

        let providerCanary = "PRIVATE_PROVIDER_DETAIL_\(UUID().uuidString)"
        let nonAllowlistedPresentations = [
            CleanupClient.Result.unavailable("gemini HTTP 500"),
            .unavailable("gemini HTTP 429 \(providerCanary)"),
            .unavailable("transport echoed \(providerCanary)"),
            .badOutput("provider stderr \(providerCanary)"),
        ].compactMap { TextTransformClient.safeFailurePresentation(for: $0)?.userMessage }
        reporter.record(
            "non-allowlisted Gemini and provider detail stays generic and never reaches the UI",
            nonAllowlistedPresentations.count == 4
                && nonAllowlistedPresentations.dropLast().allSatisfy {
                    $0 == "Selected provider is unavailable"
                }
                && nonAllowlistedPresentations.last
                    == "Selected provider returned unusable output"
                && nonAllowlistedPresentations.allSatisfy { !$0.contains(providerCanary) })

        let safeGeminiReasons = [
            "gemini HTTP 429", "gemini HTTP 401", "gemini HTTP 403",
            "bad gemini response shape", "encode failed",
        ]
        reporter.record(
            "Option+G logs each fixed app-authored failure reason beside its category",
            safeGeminiReasons.allSatisfy { reason in
                OneShotRegistry.searchFailureLogLine(
                    for: .unavailable(reason), mode: .searchGemini
                ).contains("classification=unavailable reason=\(reason)")
            })
        let privateGeminiLog = OneShotRegistry.searchFailureLogLine(
            for: .unavailable("transport echoed \(providerCanary)"), mode: .searchGemini)
        let decoratedHTTPLog = OneShotRegistry.searchFailureLogLine(
            for: .unavailable("gemini HTTP 429 \(providerCanary)"), mode: .searchGemini)
        let privateBadOutputLog = OneShotRegistry.searchFailureLogLine(
            for: .badOutput("provider stderr \(providerCanary)"), mode: .searchGemini)
        let localEncodeLog = OneShotRegistry.searchFailureLogLine(
            for: .unavailable("encode failed"), mode: .searchLocal)
        reporter.record(
            "transport, stderr, and local-search branches remain category-only in logs",
            !privateGeminiLog.contains(providerCanary)
                && !decoratedHTTPLog.contains(providerCanary)
                && !privateBadOutputLog.contains(providerCanary)
                && !localEncodeLog.contains("reason=")
                && [privateGeminiLog, decoratedHTTPLog, privateBadOutputLog, localEncodeLog]
                    .allSatisfy { $0.contains("classification=") })

        let cleanupSemaphore = DispatchSemaphore(value: 0)
        var cleanupResult: CleanupClient.Result = .badOutput("unset")
        CleanupClient.cleanup(
            "raw cleanup fixture", endpoint: URL(string: "http://127.0.0.1:1")!,
            readiness: { _ in .capacityRefused(.overBudget) }
        ) {
            cleanupResult = $0
            cleanupSemaphore.signal()
        }
        let cleanupReturned = cleanupSemaphore.wait(timeout: .now() + 2) == .success
        reporter.record(
            "CleanupClient returns the typed over-budget refusal without transport",
            cleanupReturned
                && unavailableMessage(cleanupResult) == CleanupClient.overBudgetMessage
                && CleanupLogic.landing(for: cleanupResult) == .rawFallback)

        let emailSemaphore = DispatchSemaphore(value: 0)
        var emailResult: CleanupClient.Result = .badOutput("unset")
        EmailClient.email(
            "raw email fixture", endpoint: URL(string: "http://127.0.0.1:1")!,
            readiness: { _ in .capacityRefused(.factsUnavailable) }
        ) {
            emailResult = $0
            emailSemaphore.signal()
        }
        let emailReturned = emailSemaphore.wait(timeout: .now() + 2) == .success
        reporter.record(
            "EmailClient returns the distinct facts-unavailable refusal without transport",
            emailReturned
                && unavailableMessage(emailResult) == CleanupClient.memoryFactsUnavailableMessage
                && CleanupLogic.landing(for: emailResult) == .rawFallback)

        var geminiRequests = 0
        var authoritativePreparations = 0
        func geminiResult(
            _ refusal: ModelManager.CapacityRefusal
        ) -> CleanupClient.Result {
            let mapped = CleanupClient.failureResult(
                for: .capacityRefused(refusal), loadFailureMessage: "fixture load failed")!
            let dependencies = SearchClient.GeminiAnswerDependencies(
                resolveKey: { "fixture-key-never-sent" },
                synthesisResolution: { .pinned(.local("fixture-gemma")) },
                capacityPrecheck: { _ in mapped },
                grounded: { _, _ in
                    geminiRequests += 1
                    return ("fixture grounded answer", nil)
                },
                prepareSynthesis: { _ in
                    authoritativePreparations += 1
                    return mapped
                })
            return SearchClient.geminiAnswerSync(
                question: "fixture question", dependencies: dependencies)
        }

        let geminiOverBudget = geminiResult(.overBudget)
        let geminiFactsUnavailable = geminiResult(.factsUnavailable)
        reporter.record(
            "Option+G refusal makes zero Gemini requests through the recorded transport",
            geminiRequests == 0 && authoritativePreparations == 0,
            "geminiRequests=\(geminiRequests) authoritativePreparations=\(authoritativePreparations)")
        reporter.record(
            "SearchClient preserves both capacity refusal messages on the early-out",
            unavailableMessage(geminiOverBudget) == CleanupClient.overBudgetMessage
                && unavailableMessage(geminiFactsUnavailable)
                    == CleanupClient.memoryFactsUnavailableMessage)

        var precheckLoads: [String] = []
        let precheck = ModelManager().capacityPrecheck(
            "incoming",
            dependencies: .init(
                availableInstalledModels: { [installedModel("incoming", size: 100)] },
                residentModels: { [] },
                wiredBytes: { 10 },
                budgetBytes: { _ in 1_000 },
                ensureLoaded: { model, _ in precheckLoads.append(model); return true },
                unload: { _ in }))
        reporter.record(
            "capacity precheck authorizes without loading the requested model",
            precheck == .ready && precheckLoads.isEmpty,
            "loads=\(precheckLoads)")
    }

    private static func missingRecencyEvictionChecks(_ reporter: SelfTestReporter) {
        let manager = ModelManager()
        var residents: [ModelResidency.ResidentModel] = []
        var unloads: [String] = []
        var wired: UInt64 = 0
        let installed = [
            installedModel("owned/missing-recency", size: 100),
            installedModel("owned/older", size: 100),
            installedModel("owned/generating", size: 100),
            installedModel("incoming", size: 100),
        ]
        let dependencies = ModelManager.CapacityDependencies(
            availableInstalledModels: { installed },
            residentModels: { residents },
            wiredBytes: { wired },
            budgetBytes: { _ in 250 },
            ensureLoaded: { model, _ in
                let lastUsedTime: UInt64? = model == "owned/older" ? 10 : nil
                let status = model == "owned/generating" ? "generating" : "idle"
                residents.append(resident(model, 100, lastUsedTime, status))
                return true
            },
            unload: { model in
                unloads.append(model)
                residents.removeAll { $0.identifier == model }
                wired = 0
            })

        _ = manager.ensureReady("owned/missing-recency", ttlOverrideSeconds: 600,
                                dependencies: dependencies)
        _ = manager.ensureReady("owned/older", ttlOverrideSeconds: 600, dependencies: dependencies)
        _ = manager.ensureReady("owned/generating", ttlOverrideSeconds: 600,
                                dependencies: dependencies)
        wired = 300
        let incoming = manager.ensureReady("incoming", ttlOverrideSeconds: 600,
                                           dependencies: dependencies)

        reporter.record(
            "missing recency is ordered after a genuinely idle older model",
            unloads == ["owned/older", "owned/missing-recency"],
            "unloads=\(unloads)")
        reporter.record(
            "a generating row with missing recency is never an eviction candidate",
            incoming == .ready && !unloads.contains("owned/generating")
                && residents.contains { $0.identifier == "owned/generating" },
            "result=\(incoming) unloads=\(unloads)")
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

    /// The recheck must survive the lag between `lms unload` returning and macOS unwiring the pages.
    ///
    /// Measured live on 2026-08-24 (`vdmg-REV`): unload returned at +0.148s with `wire_count` still
    /// reporting 10.00 of 10.43 GB, settling to 3.50 GB only at ~+0.68s. Without a settle window the
    /// recheck reads the PRE-eviction number, so the pass unloads the app's own warm model and refuses
    /// anyway - LOCKED DECISION 2's recheck could never pass on the strength of its own eviction. The
    /// stale reading below reproduces exactly that; drop the window and this case returns .overBudget.
    private static func evictionSettleChecks(_ reporter: SelfTestReporter) {
        let installed = [installedModel("owned", size: 500), installedModel("incoming", size: 100)]
        let staleReadings: [UInt64] = [950, 950, 950]   // unload has returned; the kernel has not caught up
        let settled: UInt64 = 400

        func outcome(settleSeconds: Double) -> (ModelManager.ReadinessResult, Int, [String]) {
            let manager = ModelManager()
            var residents: [ModelResidency.ResidentModel] = []
            var unloads: [String] = []
            var reads = 0
            let setup = ModelManager.CapacityDependencies(
                availableInstalledModels: { installed },
                residentModels: { residents },
                wiredBytes: { 0 },
                budgetBytes: { _ in 1_000 },
                ensureLoaded: { model, _ in residents.append(resident(model, 500, 1, "idle")); return true },
                unload: { _ in })
            _ = manager.ensureReady("owned", ttlOverrideSeconds: 600, dependencies: setup)

            let blocked = ModelManager.CapacityDependencies(
                availableInstalledModels: { installed },
                residentModels: { residents },
                wiredBytes: {
                    defer { reads += 1 }
                    return reads < staleReadings.count ? staleReadings[reads] : settled
                },
                budgetBytes: { _ in 1_000 },
                ensureLoaded: { _, _ in true },
                unload: { model in
                    unloads.append(model)
                    residents.removeAll { $0.identifier == model }
                },
                evictionSettleSeconds: settleSeconds)
            let result = manager.ensureReady(
                "incoming", ttlOverrideSeconds: 600, dependencies: blocked)
            return (result, reads, unloads)
        }

        let (withoutWindow, _, unloadedWithout) = outcome(settleSeconds: 0)
        reporter.record(
            "WITHOUT a settle window a stale wired reading refuses the load it just made room for",
            withoutWindow == .capacityRefused(.overBudget) && unloadedWithout == ["owned"],
            "result=\(withoutWindow) unloads=\(unloadedWithout)")

        let (withWindow, reads, unloadedWith) = outcome(settleSeconds: 1.0)
        reporter.record(
            "WITH the settle window the recheck sees the freed memory and the load proceeds",
            withWindow == .ready, "result=\(withWindow) wiredReads=\(reads)")
        reporter.record(
            "the settle window does not widen the pass: still exactly one unload, LRU-scoped",
            unloadedWith == ["owned"], "unloads=\(unloadedWith)")

        // A machine that never frees the memory must still refuse rather than spin to the deadline
        // and then load anyway.
        let manager = ModelManager()
        var residents: [ModelResidency.ResidentModel] = []
        let setup = ModelManager.CapacityDependencies(
            availableInstalledModels: { installed },
            residentModels: { residents },
            wiredBytes: { 0 },
            budgetBytes: { _ in 1_000 },
            ensureLoaded: { model, _ in residents.append(resident(model, 500, 1, "idle")); return true },
            unload: { _ in })
        _ = manager.ensureReady("owned", ttlOverrideSeconds: 600, dependencies: setup)
        var loads: [String] = []
        let neverFrees = ModelManager.CapacityDependencies(
            availableInstalledModels: { installed },
            residentModels: { residents },
            wiredBytes: { 950 },
            budgetBytes: { _ in 1_000 },
            ensureLoaded: { model, _ in loads.append(model); return true },
            unload: { model in residents.removeAll { $0.identifier == model } },
            evictionSettleSeconds: 0.3)
        let stuck = manager.ensureReady("incoming", ttlOverrideSeconds: 600, dependencies: neverFrees)
        reporter.record(
            "memory that never frees still refuses after the window, and never loads incoming",
            stuck == .capacityRefused(.overBudget) && loads.isEmpty,
            "result=\(stuck) loads=\(loads)")
    }

    private static func resident(
        _ identifier: String, _ sizeBytes: UInt64, _ lastUsedTime: UInt64?, _ status: String,
        ttl: Int? = nil
    ) -> ModelResidency.ResidentModel {
        .init(identifier: identifier, sizeBytes: sizeBytes,
              lastUsedTime: lastUsedTime, status: status, ttlSeconds: ttl)
    }

    private static func installedModel(_ id: String, size: Int64?) -> LMStudioInstalledModel {
        .init(modelID: id, label: id, type: "llm", sizeBytes: size, visionFlag: false)
    }

    private static func unavailableMessage(_ result: CleanupClient.Result) -> String? {
        guard case .unavailable(let message) = result else { return nil }
        return message
    }
}
