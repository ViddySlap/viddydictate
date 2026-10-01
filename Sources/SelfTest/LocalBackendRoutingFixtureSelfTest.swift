import Foundation

/// G3 (`--local-backend-routing-selftest`): a Local route resolves by `(app, model)`, and when its pinned
/// app cannot run it, steps ONCE to the other local app (spec D2), never into the cloud (B16).
///
/// Everything goes through the real policy, `LLMAvailabilityRouting.resolve`, over a two-app catalog and
/// injected capacity facts (fixed ref-keyed sizes, zero wired bytes, one 8 GB budget), so no fit decision
/// reads the kernel. The store half drives real `ModelsPowerSettingsStore`s under a fresh temporary
/// directory. Distinct values everywhere, so a default cannot pass by accident:
/// - `shared-id-on-both` is installed in BOTH apps, at different sizes (5 GB in LM Studio, 3 GB in Ollama),
///   so matching on the id alone names the wrong app;
/// - each app also has a model only it holds, and a 20 GB model that fits nowhere;
/// - Claude and Codex are available with configured bundles in every fixture, so a policy that climbs out
///   of Local has somewhere to go and is seen doing it.
///
/// The LM-Studio-only arm compares against what 1.1.0 produced, written out from the `ModelFitSelfTest`
/// arms' own expectations (qwen over the fixture budget, gemma under it, the measured ComponentPicker sizes)
/// and the exact 1.1.0 reason and offer strings, never against this slice's code.
///
/// Negative controls: the contract is re-run against three broken policies, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) resolution by id alone (the first catalog row with the pinned id runs);
/// (b) no cross-app step (only the pinned app's models are ever considered);
/// (c) a Local pin that climbs to Claude when both local apps are down.
enum LocalBackendRoutingFixtureSelfTest {
    private static let sharedID = "shared-id-on-both"
    private static let lmOnlyID = "lmstudio-fixture-only"
    private static let lmTooBigID = "lmstudio-fixture-too-big"
    private static let ollamaOnlyID = "ollama-fixture-only:latest"
    private static let ollamaTooBigID = "ollama-fixture-too-big:30b"

    private static let budgetBytes: UInt64 = 8_000_000_000
    /// Ref-keyed on purpose: the shared id has a different size in each app.
    private static let sizes: [LocalModelRef: Int64] = [
        LocalModelRef(backend: .lmStudio, modelID: sharedID): 5_000_000_000,
        LocalModelRef(backend: .lmStudio, modelID: lmOnlyID): 2_000_000_000,
        LocalModelRef(backend: .lmStudio, modelID: lmTooBigID): 20_000_000_000,
        LocalModelRef(backend: .ollama, modelID: sharedID): 3_000_000_000,
        LocalModelRef(backend: .ollama, modelID: ollamaOnlyID): 1_500_000_000,
        LocalModelRef(backend: .ollama, modelID: ollamaTooBigID): 20_000_000_000,
    ]

    private static let fixtureCapacity = LLMLocalCapacityFacts(
        sizeBytes: { _ in nil }, wiredBytes: 0, budgetBytes: budgetBytes,
        sizeBytesByRef: { sizes[$0] })

    private static func option(_ backend: LocalBackendID, _ id: String) -> LMStudioModelOption {
        LMStudioModelOption(modelID: id, label: id, sizeBytes: sizes[LocalModelRef(backend: backend, modelID: id)],
                            backend: backend)
    }

    private static let lmStudioModels = [
        option(.lmStudio, sharedID), option(.lmStudio, lmOnlyID), option(.lmStudio, lmTooBigID),
    ]
    private static let ollamaModels = [
        option(.ollama, sharedID), option(.ollama, ollamaOnlyID), option(.ollama, ollamaTooBigID),
    ]

    private static func pin(_ backend: LocalBackendID?, _ id: String) -> LLMProviderBundle {
        LLMProviderBundle(provider: .local, modelID: id, localBackend: backend)
    }

    private static let claudeBundle = LLMProviderBundle.claude("claude-fixture-must-not-run")
    private static let codexBundle = LLMProviderBundle.codex("codex-fixture-must-not-run")

    // MARK: - The seam the mutants replace

    private struct Input {
        let pin: LLMProviderBundle
        let models: [LMStudioModelOption]?
        let localState: LLMProviderAvailabilityState
        var capacity: LLMLocalCapacityFacts? = LocalBackendRoutingFixtureSelfTest.fixtureCapacity
        var failure: LLMLocalRouteFailure?
        var failedProviders: [LLMProvider: String] = [:]

        func availability(_ provider: LLMProvider) -> LLMProviderAvailabilityState {
            provider == .local ? localState : .available
        }

        func bundle(_ provider: LLMProvider) -> LLMProviderBundle? {
            switch provider {
            case .local: return pin.provider == .local ? pin : nil
            case .claude: return LocalBackendRoutingFixtureSelfTest.claudeBundle
            case .codex: return LocalBackendRoutingFixtureSelfTest.codexBundle
            }
        }
    }

    private typealias Resolver = (Input) -> LLMRouteResolution

    private static let realResolver: Resolver = { input in
        LLMAvailabilityRouting.resolve(
            pin: input.pin, bundle: input.bundle, availability: input.availability,
            localModels: input.models, localCapacity: input.capacity, localFailure: input.failure,
            failedProviders: input.failedProviders)
    }

    // Assertion names the negative controls look up.
    private static let ollamaPinCheck =
        "the same id in both apps: a route pinned (Ollama, shared-id-on-both) runs it in Ollama"
    private static let downStepCheck =
        "pinned app down: the route steps to the other app's largest fitting model, degraded, naming both apps"
    private static let neverCloudCheck =
        "both local apps down: a Local pin reports off and never runs Claude or Codex"

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== local-backend routing fixture selftest (app + model, cross-app step-down) ===")
        let reporter = SelfTestReporter()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-local-backend-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            reporter.record("scratch root", false, error.localizedDescription)
            return reporter.passed
        }

        checkFixture(reporter)
        print("--- contract (real LLMAvailabilityRouting.resolve) ---")
        checkContract(realResolver, reporter)
        checkLMStudioOnlyMatches110(reporter)
        checkStore(root: root, reporter)
        checkCapacityKeying(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[local-backend-routing-selftest] PASS"
            : "[local-backend-routing-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Fixture

    private static func checkFixture(_ reporter: SelfTestReporter) {
        let lmShared = LocalModelRef(backend: .lmStudio, modelID: sharedID)
        let ollamaShared = LocalModelRef(backend: .ollama, modelID: sharedID)
        reporter.record("fixture: shared-id-on-both is in both catalogs at different sizes, and both fit",
                        sizes[lmShared] != sizes[ollamaShared]
                            && fixtureCapacity.fits(lmShared) && fixtureCapacity.fits(ollamaShared))
        reporter.record("fixture: each app's 20 GB model fits nowhere; every other model fits",
                        !fixtureCapacity.fits(LocalModelRef(backend: .lmStudio, modelID: lmTooBigID))
                            && !fixtureCapacity.fits(LocalModelRef(backend: .ollama, modelID: ollamaTooBigID))
                            && fixtureCapacity.fits(LocalModelRef(backend: .lmStudio, modelID: lmOnlyID))
                            && fixtureCapacity.fits(LocalModelRef(backend: .ollama, modelID: ollamaOnlyID)))
        reporter.record("fixture: no fixture id is a shipped default",
                        ![sharedID, lmOnlyID, ollamaOnlyID].contains(LLMProviderDefaults.localCleanupModelID)
                            && ![sharedID, lmOnlyID, ollamaOnlyID].contains(LLMProviderDefaults.localEmailModelID))
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(_ resolve: Resolver, _ reporter: SelfTestReporter) {
        let both = lmStudioModels + ollamaModels

        // (app, id): the same id in both apps goes to the pinned app, both ways round.
        let onOllama = resolve(Input(pin: pin(.ollama, sharedID), models: both, localState: .available))
        var ollamaPinned = false
        if case .pinned(let bundle) = onOllama {
            ollamaPinned = bundle.localBackend == .ollama && bundle.modelID == sharedID
        }
        reporter.record(ollamaPinCheck, ollamaPinned, onOllama.logToken)

        for (label, lmPin) in [("explicit", pin(.lmStudio, sharedID)), ("absent (1.1.0)", pin(nil, sharedID))] {
            let onLM = resolve(Input(pin: lmPin, models: both, localState: .available))
            var lmPinned = false
            if case .pinned(let bundle) = onLM {
                lmPinned = bundle.resolvedLocalBackend == .lmStudio && bundle.modelID == sharedID
            }
            reporter.record(
                "the same id in both apps: a route pinned to LM Studio (backend \(label)) runs it in LM Studio",
                lmPinned, onLM.logToken)
        }

        // D2: the pinned app is down (not running after its start attempt: no model of it in the catalog).
        let ollamaDown = resolve(Input(pin: pin(.ollama, ollamaOnlyID), models: lmStudioModels,
                                       localState: .available))
        var stepped = false
        var why = ""
        if case .degraded(let bundle, let from, let reason, let offer) = ollamaDown {
            why = reason
            stepped = from == .local && bundle.resolvedLocalBackend == .lmStudio && bundle.modelID == sharedID
                && reason == "ran on LM Studio, Ollama wasn't running"
                && offer?.crossing == LocalBackendCrossing(from: .ollama, to: .lmStudio, cause: .pinnedAppNotRunning)
        }
        reporter.record(downStepCheck, stepped, "\(ollamaDown.logToken) reason=\(why)")

        // The pinned app is down but the OTHER app holds the same id. "Installed" must mean installed in the
        // pinned app: an id-only check would call the pin installed and send the request to a stopped app.
        let sharedDown = resolve(Input(pin: pin(.ollama, sharedID), models: lmStudioModels, localState: .available))
        var sharedStepped = false
        if case .degraded(let bundle, .local, let reason, _) = sharedDown {
            sharedStepped = bundle.resolvedLocalBackend == .lmStudio && bundle.modelID == sharedID
                && reason == "ran on LM Studio, Ollama wasn't running"
        }
        reporter.record(
            "pinned (Ollama, shared-id-on-both) with Ollama down and LM Studio holding the same id: crosses to "
                + "LM Studio's copy, degraded, never pinned to the stopped app",
            sharedStepped, sharedDown.logToken)

        let lmDown = resolve(Input(pin: pin(nil, lmOnlyID), models: ollamaModels, localState: .available))
        var reverse = false
        if case .degraded(let bundle, .local, let reason, _) = lmDown {
            reverse = bundle.localBackend == .ollama && bundle.modelID == sharedID
                && reason.contains("LM Studio") && reason.contains("Ollama")
        }
        reporter.record(
            "LM Studio pin with LM Studio down: steps to Ollama's largest fitting model (its 3 GB shared-id-on-both)",
            reverse, lmDown.logToken)

        // D2: the pinned model does not fit, and nothing else in its app does either.
        let tooBigCatalog = lmStudioModels + [option(.ollama, ollamaTooBigID)]
        let noFit = resolve(Input(pin: pin(.ollama, ollamaTooBigID), models: tooBigCatalog, localState: .available))
        var fitStep = false
        if case .degraded(let bundle, .local, let reason, _) = noFit {
            fitStep = bundle.resolvedLocalBackend == .lmStudio && bundle.modelID == sharedID
                && reason == "ran on LM Studio, \(ollamaTooBigID) didn't fit in memory on Ollama"
        }
        reporter.record("pinned model too big and nothing else in its app fits: steps to the other app",
                        fitStep, noFit.logToken)

        // The step-down prefers the pinned app even when the other app holds a bigger fitting model.
        let preferPinned = resolve(Input(pin: pin(.ollama, ollamaTooBigID), models: both, localState: .available))
        var sameApp = false
        if case .degraded(let bundle, .local, let reason, let offer) = preferPinned {
            sameApp = bundle.localBackend == .ollama && bundle.modelID == sharedID && offer?.crossing == nil
                && reason == "preferred local model \(ollamaTooBigID) is not installed"
        }
        reporter.record(
            "a pinned model that does not fit steps down inside its own app first (Ollama's 3 GB model, not "
                + "LM Studio's larger 5 GB one)",
            sameApp, preferPinned.logToken)

        // The one capacity step-down, blaming the model that refused in ITS app only.
        let refused = resolve(Input(
            pin: pin(.ollama, sharedID), models: both, localState: .available,
            failure: .overBudget(modelID: sharedID, backend: .ollama),
            failedProviders: [.local: CleanupClient.overBudgetMessage]))
        var retryStep = false
        if case .degraded(let bundle, .local, let reason, _) = refused {
            retryStep = bundle.localBackend == .ollama && bundle.modelID == ollamaOnlyID
                && reason == CleanupClient.overBudgetMessage
        }
        reporter.record("a capacity refusal of (Ollama, shared-id-on-both) steps down once, inside Ollama",
                        retryStep, refused.logToken)

        // A refusal named by ref excludes that app's copy only. Nothing else in Ollama fits, so the step
        // crosses, and LM Studio's own copy of the same id (a different file) is still a candidate.
        let refusedOnlyThere = resolve(Input(
            pin: pin(.ollama, sharedID),
            models: lmStudioModels + [option(.ollama, sharedID), option(.ollama, ollamaTooBigID)],
            localState: .available,
            failure: .overBudget(modelID: sharedID, backend: .ollama),
            failedProviders: [.local: CleanupClient.overBudgetMessage]))
        var onlyThatCopy = false
        if case .degraded(let bundle, .local, let reason, _) = refusedOnlyThere {
            onlyThatCopy = bundle.resolvedLocalBackend == .lmStudio && bundle.modelID == sharedID
                && reason == "ran on LM Studio, \(sharedID) didn't fit in memory on Ollama"
        }
        reporter.record(
            "a refusal of (Ollama, shared-id-on-both) excludes only Ollama's copy: the cross-app step may run "
                + "LM Studio's own copy",
            onlyThatCopy, refusedOnlyThere.logToken)

        // B16: both local apps down, Claude and Codex available and configured.
        let bothDown = resolve(Input(
            pin: pin(.ollama, sharedID), models: nil,
            localState: .unavailable("LM Studio and Ollama are not installed")))
        reporter.record(neverCloudCheck,
                        bothDown.bundle == nil && bothDown.offReason?.contains("cloud fallback is disabled") == true,
                        bothDown.logToken)
        let nothingFits = resolve(Input(
            pin: pin(nil, lmTooBigID), models: [option(.lmStudio, lmTooBigID), option(.ollama, ollamaTooBigID)],
            localState: .available))
        reporter.record("both apps up but nothing fits anywhere: off, never Claude or Codex",
                        nothingFits.bundle == nil, nothingFits.logToken)
    }

    // MARK: - LM Studio only: exactly 1.1.0

    /// The `ModelFitSelfTest` fixture (qwen and gemma, the measured sizes, the 8 GB fit budget) on an
    /// LM-Studio-only catalog. Expected values are what 1.1.0 returned, written out literally.
    private static func checkLMStudioOnlyMatches110(_ reporter: SelfTestReporter) {
        let qwenID = LLMProviderDefaults.localCleanupModelID
        let gemmaID = LLMProviderDefaults.localEmailModelID
        let qwenSize = Int64(ComponentPicker.SizeCatalog.measured.qwen!)
        let gemmaSize = Int64(ComponentPicker.SizeCatalog.measured.gemma!)
        let facts = LLMLocalCapacityFacts(
            sizeBytes: { $0 == qwenID ? qwenSize : $0 == gemmaID ? gemmaSize : nil },
            wiredBytes: 0, budgetBytes: 8_000_000_000)
        let catalog = [LMStudioModelOption(modelID: qwenID, label: "qwen"),
                       LMStudioModelOption(modelID: gemmaID, label: "gemma")]

        let fit = realResolver(Input(pin: .local(qwenID), models: catalog, localState: .available, capacity: facts))
        reporter.record(
            "LM Studio only, qwen over budget: 1.1.0's exact degraded result (gemma, same reason, same offer)",
            fit == .degraded(.local(gemmaID), from: .local,
                             reason: "preferred local model \(qwenID) is not installed",
                             upgradeOffer: LLMRouteUpgradeOffer(preferredModelID: qwenID, runningModelID: gemmaID)),
            fit.logToken)
        reporter.record("LM Studio only: the offer's toast is 1.1.0's sentence",
                        fit.upgradeOffer?.message
                            == "Running on \(gemmaID). Install \(qwenID) for the preferred local model.")

        let generous = LLMLocalCapacityFacts(sizeBytes: facts.sizeBytes, wiredBytes: 0,
                                             budgetBytes: 100_000_000_000)
        let preference = realResolver(Input(pin: .local(qwenID), models: catalog, localState: .available,
                                            capacity: generous))
        reporter.record("LM Studio only, generous budget: 1.1.0's exact pinned result",
                        preference == .pinned(.local(qwenID)), preference.logToken)

        let retry = realResolver(Input(
            pin: .local(qwenID), models: catalog, localState: .available, capacity: generous,
            failure: .overBudget(modelID: qwenID), failedProviders: [.local: CleanupClient.overBudgetMessage]))
        reporter.record(
            "LM Studio only, a bare-id capacity refusal: 1.1.0's exact step-down (gemma, the refusal sentence)",
            retry == .degraded(.local(gemmaID), from: .local, reason: CleanupClient.overBudgetMessage,
                               upgradeOffer: LLMRouteUpgradeOffer(preferredModelID: qwenID, runningModelID: gemmaID)),
            retry.logToken)

        let unmeasured = realResolver(Input(pin: .local(qwenID), models: nil, localState: .available))
        reporter.record("LM Studio only, unmeasured catalog: off, as 1.1.0's catalog arm requires",
                        unmeasured.bundle == nil, unmeasured.logToken)

        // A substitution must not grow a key on disk: a 1.1.0 file stays byte-identical after a write.
        let encoded = (fit.bundle).flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        reporter.record("LM Studio only: the substituted bundle encodes with no localBackend key",
                        !encoded.isEmpty && !encoded.contains("localBackend"), encoded)
    }

    // MARK: - Store (real ModelsPowerSettingsStore)

    private static func checkStore(root: URL, _ reporter: SelfTestReporter) {
        let store = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("store-\(UUID().uuidString).json"), legacy: .empty,
            localCapacity: { _ in fixtureCapacity })
        store.setLocalAvailabilityState(.available, models: lmStudioModels + ollamaModels)
        store.setAvailabilityState(.available, for: .claude)
        store.setAvailabilityState(.available, for: .codex)

        var pinned = true
        do {
            try store.setSelectedBundle(pin(.ollama, sharedID), for: .cleanupL1)
            try store.setSelectedBundle(pin(.lmStudio, sharedID), for: .email)
            try store.setSelectedBundle(pin(.ollama, sharedID), for: .searchRetrieval)
        } catch { pinned = false }
        reporter.record("store: routes pinned to (app, shared-id-on-both)", pinned)

        let cleanup = store.resolveRoute(.cleanupL1)
        reporter.record("store: cleanup pinned to Ollama resolves to Ollama",
                        cleanup.bundle?.localBackend == .ollama && cleanup.bundle?.modelID == sharedID,
                        cleanup.logToken)
        let email = store.resolveRoute(.email)
        reporter.record("store: email pinned to LM Studio resolves to LM Studio",
                        email.bundle?.resolvedLocalBackend == .lmStudio && email.bundle?.modelID == sharedID,
                        email.logToken)

        let byRef = store.resolveRoute(
            .cleanupL1, failedProviders: [.local: CleanupClient.overBudgetMessage],
            failedLocalRef: LocalModelRef(backend: .ollama, modelID: sharedID))
        reporter.record("store: failedLocalRef excludes only that app's model and steps down inside it",
                        byRef.bundle?.localBackend == .ollama && byRef.bundle?.modelID == ollamaOnlyID,
                        byRef.logToken)
        let byBareID = store.resolveRoute(
            .cleanupL1, failedProviders: [.local: CleanupClient.overBudgetMessage],
            failedLocalModelID: sharedID)
        reporter.record("store: a bare failedLocalModelID never re-offers that id in either app",
                        byBareID.bundle != nil && byBareID.bundle?.modelID != sharedID, byBareID.logToken)

        let retrieval = SearchClient.retrievalModelRef(store: store)
        reporter.record("search retrieval hands onward the app with the id (Ollama, shared-id-on-both)",
                        retrieval == LocalModelRef(backend: .ollama, modelID: sharedID)
                            && SearchClient.retrievalModelID(store: store) == sharedID,
                        "ref=\(retrieval)")
    }

    // MARK: - Capacity keying

    private static func checkCapacityKeying(_ reporter: SelfTestReporter) {
        let twin = "twin-size-fixture"
        // The live keying, fed a catalog with one id in both apps. Keyed by bare id this traps
        // (`Dictionary(uniqueKeysWithValues:)`), so reaching the assertions at all is part of the check.
        let facts = ModelsPowerSettingsStore.capacityFacts(
            models: [LMStudioModelOption(modelID: twin, label: twin, sizeBytes: 20_000_000_000),
                     LMStudioModelOption(modelID: twin, label: twin, sizeBytes: 3_000_000_000, backend: .ollama)],
            wiredBytes: 0, budgetBytes: budgetBytes)
        let lm = LocalModelRef(backend: .lmStudio, modelID: twin)
        let ol = LocalModelRef(backend: .ollama, modelID: twin)
        reporter.record("capacity: each app's copy of one id keeps its own size",
                        facts.sizeBytes(of: lm) == 20_000_000_000 && facts.sizeBytes(of: ol) == 3_000_000_000)
        reporter.record("capacity: LM Studio's 20 GB copy does not fit, Ollama's 3 GB copy does",
                        !facts.fits(lm) && facts.fits(ol))
        reporter.record("capacity: the bare-id lookup still means LM Studio's model",
                        facts.sizeBytes(twin) == 20_000_000_000)
        let idOnly = LLMLocalCapacityFacts(sizeBytes: { $0 == twin ? 20_000_000_000 : nil },
                                           wiredBytes: 0, budgetBytes: budgetBytes)
        reporter.record("capacity: without a ref lookup, an Ollama ref never borrows LM Studio's size",
                        idOnly.sizeBytes(of: ol) == nil && idOnly.sizeBytes(of: lm) == 20_000_000_000)
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) Id-only: the first catalog row with the pinned id runs, whichever app lists it.
        let idOnly: Resolver = { input in
            if input.pin.provider == .local, input.localState.canRun,
               let row = input.models?.first(where: { $0.modelID == input.pin.modelID }) {
                return .pinned(.local(ref: row.ref))
            }
            return realResolver(input)
        }
        requireCaught(reporter, mutant: "policy that resolves a Local pin by model id alone",
                      by: ollamaPinCheck) { checkContract(idOnly, $0) }

        // (b) No cross-app step: the pinned app's models are the only ones ever considered.
        let noCrossing: Resolver = { input in
            let backend = input.pin.resolvedLocalBackend
            return realResolver(Input(
                pin: input.pin, models: input.models?.filter { $0.backend == backend },
                localState: input.localState, capacity: input.capacity, failure: input.failure,
                failedProviders: input.failedProviders))
        }
        requireCaught(reporter, mutant: "policy with no cross-app step (refuses when the pinned app is down)",
                      by: downStepCheck) { checkContract(noCrossing, $0) }

        // (c) Climbs out of Local when both local apps are down.
        let climbs: Resolver = { input in
            let resolution = realResolver(input)
            guard resolution.bundle == nil, input.availability(.claude).canRun,
                  let claude = input.bundle(.claude) else { return resolution }
            return .degraded(claude, from: .local, reason: "local apps down", upgradeOffer: nil)
        }
        requireCaught(reporter, mutant: "policy that crosses to Claude when both local apps are down",
                      by: neverCloudCheck) { checkContract(climbs, $0) }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
