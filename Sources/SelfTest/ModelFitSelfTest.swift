import Foundation

/// GA1 of chain `vdfit`: the graders for the model-fit chain. Six arms, each driving the REAL
/// resolution and capacity path — `LLMAvailabilityRouting.resolve`, `ModelsPowerSettingsStore.resolveRoute`,
/// and `ModelManager`'s injected `CapacityDependencies` seam — over synthetic fixtures, and asserting
/// which model id is finally handed to LM Studio. No network, no real LM Studio, no AppKit.
///
/// This file is PROTECTED: no later link in chain `vdfit` may edit it. Later links are measured by it.
///
/// Fixtures: `google/gemma-4-e4b` (installed and fitting) and `qwen3-coder-30b-a3b-instruct-mlx`
/// (absent in one variant, present-but-over-budget in the other), using the same measured byte counts
/// `ComponentPicker.SizeCatalog.measured` already ships, so a fixture never disagrees with production
/// about what these two models actually weigh.
///
/// `preference` is the control arm and must stay green today and forever: it is what stops a later
/// link from "fixing" the bug by always picking the smallest installed model.
enum ModelFitSelfTest {
    enum Arm: String, CaseIterable {
        case searchRetrieval = "search-retrieval"
        case fit
        case retry
        case catalog
        case seed
        case preference
    }

    static func run(arguments: [String]) -> Int32 {
        Settings.registerDefaults()
        guard let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count,
              let arm = Arm(rawValue: arguments[i + 1])
        else {
            let names = Arm.allCases.map(\.rawValue).joined(separator: "|")
            print("[modelfit-selftest] FAIL: --only <\(names)> is required")
            return 2
        }
        let ok: Bool
        switch arm {
        case .searchRetrieval: ok = runSearchRetrieval()
        case .fit:              ok = runFit()
        case .retry:             ok = runRetry()
        case .catalog:           ok = runCatalog()
        case .seed:              ok = runSeed()
        case .preference:        ok = runPreference()
        }
        return ok ? 0 : 1
    }

    // MARK: - Shared fixtures

    private static let qwenID = LLMProviderDefaults.localCleanupModelID
    private static let gemmaID = LLMProviderDefaults.localEmailModelID

    /// The same measured byte counts ComponentPicker ships (O1), so a fixture here can never quietly
    /// disagree with the machine-fit arithmetic that already exists.
    private static let qwenSizeBytes = Int64(ComponentPicker.SizeCatalog.measured.qwen!)
    private static let gemmaSizeBytes = Int64(ComponentPicker.SizeCatalog.measured.gemma!)

    /// gemma fits here, qwen does not — this is the one fact every arm below reasons from.
    private static let fixtureBudgetBytes: UInt64 = 8_000_000_000
    /// Neither model fits here, for the "nothing installed fits" case.
    private static let nothingFitsBudgetBytes: UInt64 = 2_000_000_000

    private static func fitsBudget(_ sizeBytes: Int64, budget: UInt64) -> Bool {
        guard let incoming = ModelManager.estimatedIncomingBytes(sizeBytes: sizeBytes) else { return false }
        return ModelManager.fits(wiredBytes: 0, incomingBytes: incoming, budgetBytes: budget)
    }

    private static func sizeFor(_ modelID: String) -> Int64? {
        if modelID == qwenID { return qwenSizeBytes }
        if modelID == gemmaID { return gemmaSizeBytes }
        return nil
    }

    private static func installedModel(_ id: String, sizeBytes: Int64) -> LMStudioInstalledModel {
        .init(modelID: id, label: id, type: "llm", sizeBytes: sizeBytes, visionFlag: false)
    }

    private static func capacityDependencies(
        installedSizes: [String: Int64], budget: UInt64
    ) -> ModelManager.CapacityDependencies {
        .init(
            availableInstalledModels: {
                installedSizes.map { installedModel($0.key, sizeBytes: $0.value) }
            },
            residentModels: { [] },
            wiredBytes: { 0 },
            budgetBytes: { _ in budget },
            ensureLoaded: { _, _ in true },
            unload: { _ in },
            log: { _ in })
    }

    private static func freshStore() -> ModelsPowerSettingsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-modelfit-\(UUID().uuidString).json")
        return ModelsPowerSettingsStore(url: url, legacy: .empty)
    }

    /// Drive `LLMAvailabilityRouting.resolve` exactly as `ModelsPowerSettingsStore.resolveRoute` does for
    /// a Local pin, and return the model id the resolution would hand LM Studio, if any.
    private static func resolveLocalModelID(
        configuredID: String, installed: [LMStudioModelOption]?
    ) -> String? {
        let configured = LLMProviderBundle.local(configuredID)
        let resolution = LLMAvailabilityRouting.resolve(
            pin: configured,
            bundle: { $0 == .local ? configured : nil },
            availability: { $0 == .local ? .available : .unavailable("not tested") },
            localModels: installed)
        return resolution.bundle?.modelID
    }

    private static func unavailableMessage(_ result: CleanupClient.Result?) -> String? {
        guard case .unavailable(let message) = result else { return nil }
        return message
    }

    // MARK: - search-retrieval

    /// SearchClient's retrieval leg goes through one seam, `SearchClient.retrievalModelID(store:)`, that
    /// both production call sites (`agenticLoop`'s `lmChat` and `localAnswerSync`'s residency prep) read
    /// instead of `Settings.searchModel` directly. (A) pins qwen as the intended preference (fixture
    /// sanity, not the defect — qwen stays correct to prefer).
    ///
    /// (B) seeds a `freshStore()` the same way `runPreference()`/`runRetry()` already do, so a route
    /// resolution reading `store` has a real catalog to consult — closing the gap the un-seeded arm had
    /// before: `SearchClient.retrievalModelID()` took no store parameter, so a real
    /// `ModelsPowerSettingsStore.resolveRoute`-based fix could only ever see a nil catalog, fall back to
    /// the raw `Settings.searchModel` scalar, and fail the readiness check below for exactly the same
    /// reason the unpatched pass-through does — an unsatisfiable arm that could not tell a correct route
    /// resolution from one that never runs at all.
    ///
    /// The fixture's one installed model carries a name NEITHER `qwenID` NOR `gemmaID` — not one of the
    /// two ids production code already has memorized. This is deliberate, not incidental: seeding
    /// literally `[gemma, qwen]` cannot discriminate a route resolution that actually reads `store` from
    /// one that hardcodes its own `[qwen, gemma]` catalog inline (the exact defect a prior worker's
    /// patch shipped, and the reason this arm exists) — both would end up naming a real id this file
    /// already knows, passing either way. Naming the fixture's installed model something a hardcoded
    /// catalog cannot possibly guess is what makes (B) actually exercise "did this read the injected
    /// store", not merely "did this land on a model that fits".
    ///
    /// The fixture model is seeded with NO `sizeBytes` (unmeasured), matching how `runRetry()` and
    /// `runPreference()` already seed their catalogs, and deliberately NOT with a real measured size.
    /// `ModelsPowerSettingsStore.resolveRoute`'s capacity check is not an injectable seam — it always
    /// reads the live kernel's CURRENT wired bytes plus the configured budget
    /// (`ModelManager.fits: wiredBytes + incomingBytes <= budgetBytes`), and wired bytes is whatever
    /// else happens to be resident on the machine at test time, not a fixture value. Measured directly
    /// on this machine while writing this arm: wired was already ~41 GB against a ~34 GB budget, so
    /// EVERY model — including one the size of gemma — failed that live check regardless of its size.
    /// An unmeasured entry short-circuits `LLMLocalCapacityFacts.fits` to `true` ("unmeasured: do not
    /// block a model we cannot size"), which is what keeps this arm's outcome independent of whatever
    /// else is running on the box. The FITS/DOES-NOT-FIT distinction this arm actually cares about
    /// (readiness assertion B) is carried entirely by `capacityDependencies`/`ensureReady` below, which
    /// remains fully injectable.
    private static func runSearchRetrieval() -> Bool {
        print("=== ViddyDictate modelfit — search-retrieval arm ===")
        let reporter = SelfTestReporter()

        reporter.record(
            "Settings.searchModel is the tested-default local retrieval model in this fixture",
            Settings.searchModel == qwenID, "got=\(Settings.searchModel)")

        let installedID = "modelfit-fixture-actually-installed"
        let installedSizeBytes = gemmaSizeBytes
        let store = freshStore()
        store.setLocalAvailabilityState(.available, models: [
            LMStudioModelOption(modelID: installedID, label: "fixture-installed"),
        ])

        let resolvedModelID = SearchClient.retrievalModelID(store: store)
        reporter.record(
            "the retrieval leg resolves to the model this fixture's store actually has installed, "
                + "not a hardcoded guess at what is installed",
            resolvedModelID == installedID, "resolved=\(resolvedModelID)")

        let dependencies = capacityDependencies(
            installedSizes: [installedID: installedSizeBytes], budget: fixtureBudgetBytes)
        let readiness = ModelManager().ensureReady(
            resolvedModelID, ttlOverrideSeconds: 60, dependencies: dependencies)
        reporter.record(
            "the model the retrieval leg resolves to is loadable on this machine",
            readiness == .ready, "resolved=\(resolvedModelID) readiness=\(readiness)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "search-retrieval"))
        return reporter.passed
    }

    // MARK: - fit

    /// `LLMAvailabilityRouting.localCandidate` takes `localModels.first` with no size check when the
    /// configured model is absent, and returns the configured model verbatim with no size check when it
    /// IS installed. Both paths can hand LM Studio a model that does not fit.
    private static func runFit() -> Bool {
        print("=== ViddyDictate modelfit — fit arm ===")
        let reporter = SelfTestReporter()

        reporter.record("fixture: gemma fits the fixture budget",
                        fitsBudget(gemmaSizeBytes, budget: fixtureBudgetBytes))
        reporter.record("fixture: qwen does not fit the fixture budget",
                        !fitsBudget(qwenSizeBytes, budget: fixtureBudgetBytes))

        let bothInstalled = [
            LMStudioModelOption(modelID: qwenID, label: "qwen"),
            LMStudioModelOption(modelID: gemmaID, label: "gemma"),
        ]

        let absentChoice = resolveLocalModelID(
            configuredID: "modelfit-fixture-not-installed", installed: bothInstalled)
        let absentFits = absentChoice.flatMap(sizeFor).map { fitsBudget($0, budget: fixtureBudgetBytes) }
            ?? false
        reporter.record(
            "when the configured model is absent, the substitute LM Studio is actually asked for fits",
            absentFits, "chose=\(absentChoice ?? "nil")")

        let tooLargeChoice = resolveLocalModelID(configuredID: qwenID, installed: bothInstalled)
        let tooLargeFits = tooLargeChoice.flatMap(sizeFor).map { fitsBudget($0, budget: fixtureBudgetBytes) }
            ?? false
        reporter.record(
            "when the configured model is installed but too large, the model LM Studio is actually "
                + "asked for fits",
            tooLargeFits, "chose=\(tooLargeChoice ?? "nil")")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "fit"))
        return reporter.passed
    }

    // MARK: - retry

    /// Today's only per-attempt exclusion seam is `failedProviders: [LLMProvider: String]`, which is
    /// keyed by PROVIDER, not by model id. Marking `.local` failed after an over-budget refusal does not
    /// make routing try the next smaller installed model — for a Local pin it makes the whole route
    /// report itself off (the B16 privacy-boundary guard), so no automatic retry onto a smaller model
    /// exists. Separately: when nothing installed fits, `CleanupClient`'s refusal sentence and the
    /// raw-transcript-lands contract must still hold.
    private static func runRetry() -> Bool {
        print("=== ViddyDictate modelfit — retry arm ===")
        let reporter = SelfTestReporter()
        let route = LLMRouteID.cleanupL1

        let store = freshStore()
        store.setLocalAvailabilityState(.available, models: [
            LMStudioModelOption(modelID: qwenID, label: "qwen"),
            LMStudioModelOption(modelID: gemmaID, label: "gemma"),
        ])

        let firstResolution = store.resolveRoute(route)
        guard let firstModelID = firstResolution.bundle?.modelID else {
            reporter.record("cleanupL1 resolves to a runnable bundle in this fixture", false,
                            "resolution=\(firstResolution)")
            print("\n=== RESULT ===")
            print(reporter.summaryLine(prefix: "retry"))
            return reporter.passed
        }
        reporter.record("cleanupL1's local pin is qwen with both models installed (fixture sanity)",
                        firstModelID == qwenID, "got=\(firstModelID)")

        let firstReadiness = ModelManager().capacityPrecheck(
            firstModelID,
            dependencies: capacityDependencies(
                installedSizes: [qwenID: qwenSizeBytes, gemmaID: gemmaSizeBytes],
                budget: fixtureBudgetBytes))
        reporter.record(
            "the first attempt on the oversized configured model is refused for capacity",
            firstReadiness == .capacityRefused(.overBudget), "readiness=\(firstReadiness)")

        let retryResolution = store.resolveRoute(
            route, failedProviders: [.local: CleanupClient.overBudgetMessage])
        reporter.record(
            "an over-budget refusal retries once and lands on a smaller installed model rather than "
                + "taking the whole route off",
            retryResolution.bundle?.modelID == gemmaID, "retryResolution=\(retryResolution)")

        // When NOTHING installed fits, the refusal sentence must survive byte-for-byte and the case must
        // remain the one CleanupClient.Result documents as landing the raw transcript.
        let nothingFitsReadiness = ModelManager().capacityPrecheck(
            firstModelID,
            dependencies: capacityDependencies(
                installedSizes: [qwenID: qwenSizeBytes, gemmaID: qwenSizeBytes],
                budget: nothingFitsBudgetBytes))
        let failureResult = CleanupClient.failureResult(
            for: nothingFitsReadiness, loadFailureMessage: "cleanup model not loaded")
        let message = unavailableMessage(failureResult)
        reporter.record(
            "when nothing installed fits, the exact over-budget sentence survives byte-for-byte",
            message == "Not enough space in RAM. Adjust local model settings under the Setup tab.",
            "got=\(message ?? "nil")")

        var landsRaw = false
        if let r = failureResult, case .unavailable = r { landsRaw = true }
        reporter.record(
            "the raw transcript still lands (CleanupClient.Result stays .unavailable, never .ok)",
            landsRaw)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "retry"))
        return reporter.passed
    }

    // MARK: - catalog

    /// `localCandidate`'s `guard let localModels else { return (configured, nil) }` treats "the catalog
    /// has never been measured" as "the configured model is installed and fits". It has not been
    /// measured; it may not even exist on this machine. Exercised through both call sites that share
    /// this guard: the Local-pin path (B16) and the cloud fallback ladder's degrade-onto-Local path.
    private static func runCatalog() -> Bool {
        print("=== ViddyDictate modelfit — catalog arm ===")
        let reporter = SelfTestReporter()

        let pinChoice = resolveLocalModelID(configuredID: qwenID, installed: nil)
        reporter.record(
            "a nil (unmeasured) catalog must not be treated as though the Local pin's configured "
                + "model is installed",
            pinChoice != qwenID, "resolution modelID=\(pinChoice ?? "nil")")

        let claudePin = LLMProviderBundle.claude("claude-fixture-model")
        let ladderResolution = LLMAvailabilityRouting.resolve(
            pin: claudePin,
            bundle: { $0 == .local ? LLMProviderBundle.local(qwenID) : nil },
            availability: { provider in
                switch provider {
                case .claude, .codex: return .unavailable("not tested")
                case .local: return .available
                }
            },
            localModels: nil)
        let ladderChoice = ladderResolution.bundle?.modelID
        reporter.record(
            "the cloud fallback ladder must not degrade onto Local's configured model when its "
                + "catalog is unmeasured",
            ladderChoice != qwenID, "resolution=\(ladderResolution)")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "catalog"))
        return reporter.passed
    }

    // MARK: - seed

    /// After a real `ComponentPicker` run on a 16 GB fixture genuinely declines to install qwen (it does
    /// not fit even at the budget slider's ceiling — O2's own arithmetic), the router's local catalog is
    /// still nil: nothing has probed LM Studio yet. That nil catalog then falls into the same
    /// `guard let localModels else { ... }` gap the `catalog` arm names, and a route would show qwen —
    /// the model the picker just said this machine cannot run — as what will run.
    private static func runSeed() -> Bool {
        print("=== ViddyDictate modelfit — seed arm ===")
        let reporter = SelfTestReporter()

        let facts = mac16Facts()
        let environment = ComponentPicker.Environment()

        let qwenAvailability = ComponentPicker.availability(.qwen, facts: facts)
        reporter.record(
            "this 16 GB fixture cannot hold qwen even at the budget slider's ceiling "
                + "(the shipped O2 arithmetic)",
            qwenAvailability == .tooLarge, "\(qwenAvailability)")

        let selection = ComponentPicker.defaultSelection(facts: facts, environment: environment)
        reporter.record("the picker's own default selection never ticks a model this Mac cannot run",
                        selection.qwen == false)

        let plan = ComponentPicker.installPlan(
            selection: selection, facts: facts, environment: environment)
        reporter.record("qwen is not part of what the picker plans to install here",
                        !plan.models.contains(qwenID), "models=\(plan.models)")

        let pinChoice = resolveLocalModelID(configuredID: qwenID, installed: nil)
        reporter.record(
            "no route displays qwen as what will run right after the picker explicitly declined "
                + "to install it on this machine",
            pinChoice != qwenID, "resolution modelID=\(pinChoice ?? "nil")")

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "seed"))
        return reporter.passed
    }

    /// A 16 GiB Mac, synthesized from the same measured `vm.global_user_wire_limit` / `hw.memsize`
    /// ratio (~82%) `ComponentPickerSelfTest` uses, so this fixture's verdicts agree with the picker's
    /// own deterministic coverage rather than inventing a second reading of the same machine.
    private static func mac16Facts() -> ComponentPicker.MachineFacts {
        let physical = UInt64(16 * 1_073_741_824)
        let wireLimit = Double(physical) * 0.820
        return ComponentPicker.MachineFacts(
            physicalBytes: physical,
            budgetBytes: UInt64(wireLimit * SystemMemory.realFraction(
                forSliderPosition: Settings.modelMemoryBudgetSliderPosition)),
            maxBudgetBytes: UInt64(wireLimit * SystemMemory.realFraction(
                forSliderPosition: Settings.modelMemoryBudgetSliderRange.upperBound)),
            wiredBytes: 3_000_000_000)
    }

    // MARK: - preference (control — must stay green today and after any later fix)

    /// With both models installed and a generous budget, every route still chooses its configured
    /// preference. This is what stops a later link from "fixing" `fit`/`catalog`/`seed`/`retry` by
    /// always picking the smallest installed model instead of actually reasoning about fit.
    private static func runPreference() -> Bool {
        print("=== ViddyDictate modelfit — preference arm (control, must stay green) ===")
        let reporter = SelfTestReporter()

        let generousBudget: UInt64 = 100_000_000_000
        reporter.record(
            "fixture sanity: both models fit under the generous budget (this is the control, not "
                + "the defect)",
            fitsBudget(qwenSizeBytes, budget: generousBudget)
                && fitsBudget(gemmaSizeBytes, budget: generousBudget))

        let store = freshStore()
        store.setLocalAvailabilityState(.available, models: [
            LMStudioModelOption(modelID: qwenID, label: "qwen"),
            LMStudioModelOption(modelID: gemmaID, label: "gemma"),
        ])

        let routes = LLMRouteID.builtIns + [.custom("modelfit-preference-fixture")]
        var confirmedGemma = false
        var confirmedQwen = false
        for route in routes {
            let expected = LLMProviderDefaults.testedBundle(for: .local, route: route)!.modelID
            let resolution = store.resolveRoute(route, fallback: .local(expected))
            reporter.record(
                "\(route.rawValue) keeps its configured local preference with both models installed",
                resolution.bundle?.modelID == expected,
                "got=\(resolution.bundle?.modelID ?? "nil") want=\(expected)")
            if expected == gemmaID { confirmedGemma = true }
            if expected == qwenID { confirmedQwen = true }
        }
        reporter.record(
            "this fixture actually exercises both configured local models, not just one",
            confirmedGemma && confirmedQwen)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "preference"))
        return reporter.passed
    }
}
