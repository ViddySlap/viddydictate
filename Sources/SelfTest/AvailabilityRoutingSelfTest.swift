import Foundation

/// Pure/scratch-only coverage for availability-resolved routing (Public V1 locked decision 4): the pin
/// when it can run, else the highest-preference available provider, else the route reports itself off with
/// a specific reason while the transcript still lands raw.
///
/// Every fixture is a scratch settings store plus a synthetic availability map. No installed provider,
/// credential, live app, or user text is consulted, and the adapters are stubs, so "runs" here means the
/// resolved provider's adapter — and only that one — was actually invoked through the production seam.
enum AvailabilityRoutingSelfTest {
    private static let routes: [LLMRouteID] = LLMRouteID.builtIns + [.custom("p6-fixture")]

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate availability-resolved routing — selftest ===")
        let reporter = SelfTestReporter()

        checkPinPrecedence(reporter.record)
        checkLocalModelFallback(reporter.record)
        checkPerRunFailureExclusions(reporter.record)
        checkSingleProviderFixtures(reporter.record)
        checkNoProviderFixture(reporter.record)
        checkPinIsNeverRewritten(reporter.record)
        checkOffReasonSpecificity(reporter.record)
        checkContentSafety(reporter.record)
        checkNoNudge(reporter)

        print("\n=== RESULT ===")
        print(reporter.passed ? "AVAILABILITY ROUTING GREEN" : "AVAILABILITY ROUTING FAILED")
        return reporter.passed
    }

    // MARK: fixtures

    /// A scratch store with an explicit availability map. `present` lists the providers a fixture user has;
    /// everything else is off with a fixed, distinguishable reason.
    private static func fixture(present: Set<LLMProvider>,
                                pin: LLMProvider,
                                localModels: [LMStudioModelOption]? = nil) -> ModelsPowerSettingsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-p6-\(UUID().uuidString).json")
        let store = ModelsPowerSettingsStore(url: url, legacy: .empty)
        for provider in LLMProvider.allCases {
            store.setAvailabilityState(
                present.contains(provider) ? .available : offState(for: provider), for: provider)
        }
        if let localModels {
            store.setLocalAvailabilityState(
                localModels.isEmpty ? .unavailable("no local models installed") : .available,
                models: localModels)
        }
        for route in routes {
            try? store.selectProvider(pin, for: route)
        }
        return store
    }

    /// Distinct shapes on purpose: `.disconnected` and `.unavailable(reason)` must reach the off message
    /// through different wording, so a user can tell "signed out" from "not installed".
    private static func offState(for provider: LLMProvider) -> LLMProviderAvailabilityState {
        switch provider {
        case .local:  return .unavailable("LM Studio is not running")
        case .claude: return .unavailable("CLI unavailable")
        case .codex:  return .disconnected
        }
    }

    private static func discard(_ store: ModelsPowerSettingsStore) {
        // Scratch stores are per-fixture; the file is inert once the fixture is done with it.
        _ = store
    }

    /// Drive one route through the production dispatch seam and report which adapter actually ran.
    private static func dispatch(_ resolution: LLMRouteResolution,
                                 route: LLMRouteID,
                                 input: String = "synthetic input")
        -> (result: CleanupClient.Result, ran: [LLMProvider], modelIDs: [String]) {
        var ran: [LLMProvider] = []
        var modelIDs: [String] = []
        var result: CleanupClient.Result = .badOutput("unset")
        let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
            TextTransformRequest(
                route: route, bundle: bundle, sourceText: input,
                systemPrompt: "system", userMessage: "wrapped-\(input)",
                timeout: bundle.provider == .local ? 11 : 22)
        }
        func adapter(_ provider: LLMProvider) -> TextTransformClient.AsyncAdapter {
            { request, done in
                ran.append(provider)
                modelIDs.append(request.bundle.modelID)
                done(.ok("\(provider.rawValue)-output"))
            }
        }
        TextTransformClient.transformResolved(
            resolution, route: route, requestForBundle: requestForBundle,
            local: adapter(.local), claude: adapter(.claude), codex: adapter(.codex),
            completion: { result = $0 })
        return (result, ran, modelIDs)
    }

    // MARK: checks

    private static func checkPinPrecedence(_ check: (String, Bool) -> Void) {
        print("--- explicit pin wins whenever it can run ---")
        let store = fixture(present: [.local, .claude, .codex], pin: .codex)
        defer { discard(store) }
        let pinnedEverywhere = routes.allSatisfy { route in
            let resolution = store.resolveRoute(route)
            guard case .pinned(let bundle) = resolution, bundle.provider == .codex else { return false }
            let run = dispatch(resolution, route: route)
            return run.ran == [.codex]
        }
        check("an available pin runs even when a higher-preference provider is also available",
              pinnedEverywhere)

        let expectedOrder = LLMAvailabilityRouting.fallbackOrder
        check("the declared fallback ladder is Claude, Codex, Local",
              expectedOrder == [.claude, .codex, .local])

        // The ladder is consulted only when the pin cannot run, and it skips the pin itself.
        let claudeAndLocal = fixture(present: [.claude, .local], pin: .codex)
        defer { discard(claudeAndLocal) }
        let degradedToLadderHead = routes.allSatisfy { route in
            guard case .degraded(let bundle, let from, _, _) = claudeAndLocal.resolveRoute(route) else {
                return false
            }
            return bundle.provider == .claude && from == .codex
        }
        check("an unavailable pin degrades to the head of the ladder, not to any available provider",
              degradedToLadderHead)

        let codexAndLocal = fixture(present: [.codex, .local], pin: .claude)
        defer { discard(codexAndLocal) }
        let skipsAbsentLadderHead = routes.allSatisfy { route in
            guard case .degraded(let bundle, let from, _, _) = codexAndLocal.resolveRoute(route) else {
                return false
            }
            return bundle.provider == .codex && from == .claude
        }
        check("the ladder skips an unavailable rung instead of stopping at it", skipsAbsentLadderHead)
    }

    private static func checkSingleProviderFixtures(_ check: (String, Bool) -> Void) {
        print("--- only-Codex and only-Claude fixtures resolve and run every route ---")
        for present: LLMProvider in [.codex, .claude] {
            let pin: LLMProvider = present == .claude ? .codex : .claude
            let store = fixture(present: [present], pin: pin)
            defer { discard(store) }
            var everyRouteRan = true
            var everyRouteUsedItsOwnBundle = true
            for route in routes {
                let resolution = store.resolveRoute(route)
                guard case .degraded(let bundle, let from, _, _) = resolution,
                      bundle.provider == present, from == pin else {
                    everyRouteRan = false
                    continue
                }
                let run = dispatch(resolution, route: route)
                guard run.ran == [present],
                      case .ok(let text) = run.result, text == "\(present.rawValue)-output" else {
                    everyRouteRan = false
                    continue
                }
                // The request is built for the provider that runs, so the model id is that provider's
                // configured bundle for this route rather than the pin's.
                let expected = LLMProviderDefaults.testedBundle(for: present, route: route)?.modelID
                if run.modelIDs != [expected] { everyRouteUsedItsOwnBundle = false }
            }
            check("only \(present.rawValue) present: every route resolves and runs on \(present.rawValue)",
                  everyRouteRan)
            check("only \(present.rawValue) present: each route executes \(present.rawValue)'s own bundle",
                  everyRouteUsedItsOwnBundle)
        }
    }

    private static func checkLocalModelFallback(_ check: (String, Bool) -> Void) {
        print("--- a missing preferred Local model uses the best installed model and offers an upgrade ---")
        let preferred = LLMProviderDefaults.testedBundle(for: .local, route: .cleanupL1)!
        let alternate = LMStudioModelOption(modelID: "google/gemma-4-e4b", label: "Gemma")
        let store = fixture(present: [.local], pin: .local, localModels: [alternate])
        defer { discard(store) }

        let resolution = store.resolveRoute(.cleanupL1)
        guard case .degraded(let bundle, let from, let reason, let offer) = resolution else {
            check("a missing preferred model degrades to an installed Local model", false)
            check("the Local substitution carries an adjacent upgrade offer", false)
            return
        }
        let run = dispatch(resolution, route: .cleanupL1)
        check("a missing preferred model degrades to an installed Local model",
              bundle.provider == .local && bundle.modelID == alternate.modelID
                && from == .local && run.ran == [.local]
                && run.modelIDs == [alternate.modelID]
                && reason.contains(preferred.modelID))
        check("the Local substitution carries no upgrade offer (the staff-pick nudge was removed)",
              offer == nil && resolution.upgradeOffer == nil)

        let pinned = fixture(
            present: [.local], pin: .local,
            localModels: [LMStudioModelOption(modelID: preferred.modelID, label: "Preferred")])
        defer { discard(pinned) }
        check("an installed preferred model remains pinned without an upgrade offer",
              pinned.resolveRoute(.cleanupL1) == .pinned(preferred)
                && pinned.resolveRoute(.cleanupL1).upgradeOffer == nil)
    }

    private static func checkPerRunFailureExclusions(_ check: (String, Bool) -> Void) {
        print("--- a running request may descend the same ladder after provider failures ---")
        let store = fixture(present: [.local, .claude, .codex], pin: .codex,
                            localModels: [LMStudioModelOption(modelID: "google/gemma-4-e4b", label: "Gemma")])
        defer { discard(store) }
        let route = LLMRouteID.custom("forced-cloud-failure")
        try? store.selectProvider(.codex, for: route)
        let pin = store.selectedBundle(for: route)

        let afterCodex = store.resolveRoute(
            route, failedProviders: [.codex: "unavailable"])
        let afterBothClouds = store.resolveRoute(
            route, failedProviders: [.codex: "unavailable", .claude: "unavailable"])
        let afterEveryProvider = store.resolveRoute(
            route, failedProviders: [
                .codex: "unavailable", .claude: "unavailable", .local: "badOutput"
            ])

        check("a forced pinned-Codex failure advances to Claude without rewriting the pin",
              afterCodex.bundle?.provider == .claude
              && CustomModeRunProvider(afterCodex)?.degradedFrom == .codex
              && store.selectedBundle(for: route) == pin)
        check("forced failures on both cloud providers advance to Local, the final rung",
              afterBothClouds.bundle?.provider == .local
              && CustomModeRunProvider(afterBothClouds)?.degradedFrom == .codex)
        check("the ladder stops after Local instead of cycling back to a failed cloud provider",
              afterEveryProvider.bundle == nil
              && afterEveryProvider.offReason?.contains("local: failed during this run") == true)
    }

    private static func checkNoProviderFixture(_ check: (String, Bool) -> Void) {
        print("--- no provider available: every mode reports off and the transcript still lands raw ---")
        let store = fixture(present: [], pin: .claude)
        defer { discard(store) }
        var everyRouteOff = true
        var noAdapterRan = true
        var landsRaw = true
        var reasons: Set<String> = []
        for route in routes {
            let resolution = store.resolveRoute(route)
            guard let reason = resolution.offReason, resolution.bundle == nil else {
                everyRouteOff = false
                continue
            }
            reasons.insert(reason)
            let run = dispatch(resolution, route: route)
            if !run.ran.isEmpty { noAdapterRan = false }
            guard case .unavailable(let carried) = run.result, carried == reason else {
                everyRouteOff = false
                continue
            }
            if CleanupLogic.landing(for: run.result) != .rawFallback { landsRaw = false }
        }
        check("every built-in and custom route reports itself off", everyRouteOff)
        check("no provider adapter is invoked for an off route", noAdapterRan)
        check("the off result keeps the existing raw-fallback landing", landsRaw)
        check("the off reason survives dispatch instead of collapsing to a generic failure",
              reasons.count == 1 && reasons.first?.hasPrefix("no provider is available - ") == true)

        // An off route has no provider to retry with, so nothing may be left armed for the retry surface.
        TextTransformRetryCenter.shared.invalidate()
        _ = dispatch(store.resolveRoute(.email), route: .email)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("an off route arms no explicit retry", TextTransformRetryCenter.shared.summary == nil)
    }

    private static func checkPinIsNeverRewritten(_ check: (String, Bool) -> Void) {
        print("--- resolution is an execution decision, never a durable one ---")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-p6-durable-\(UUID().uuidString).json")
        let store = ModelsPowerSettingsStore(url: url, legacy: .empty)
        store.setAvailabilityState(.unavailable("LM Studio is not running"), for: .local)
        store.setAvailabilityState(.available, for: .claude)
        store.setAvailabilityState(.disconnected, for: .codex)
        try? store.selectProvider(.local, for: .cleanupL1)
        let pinBefore = store.selectedBundle(for: .cleanupL1)
        let resolution = store.resolveRoute(.cleanupL1)
        let run = dispatch(resolution, route: .cleanupL1)
        let pinAfter = store.selectedBundle(for: .cleanupL1)
        check("an unavailable Local pin stays off instead of hopping to cloud",
              pinBefore == pinAfter && pinAfter.provider == .local
                && resolution.bundle == nil && run.ran.isEmpty
                && resolution.offReason?.contains("automatic cloud fallback is disabled") == true)

        // The pin is honored again the moment its provider comes back: no sticky hop.
        store.setLocalAvailabilityState(.available, models: [
            LMStudioModelOption(modelID: LLMProviderDefaults.localCleanupModelID, label: "qwen"),
        ])
        check("the route returns to its pin as soon as that provider is available again",
              store.resolveRoute(.cleanupL1) == .pinned(pinBefore))

        let reopened = ModelsPowerSettingsStore(url: url, legacy: .empty)
        check("nothing about a provider hop is persisted across a reopen",
              reopened.selectedBundle(for: .cleanupL1) == pinBefore)

        let zeroLocal = fixture(
            present: [.claude, .codex], pin: .local, localModels: [])
        defer { discard(zeroLocal) }
        let zeroResolution = zeroLocal.resolveRoute(.cleanupL1)
        let zeroRun = dispatch(zeroResolution, route: .cleanupL1)
        check("zero installed Local models cannot automatically invoke either cloud adapter",
              zeroResolution.bundle == nil && zeroRun.ran.isEmpty
                && zeroResolution.offReason?.contains("no local models installed") == true)
    }

    private static func checkOffReasonSpecificity(_ check: (String, Bool) -> Void) {
        print("--- the off reason is specific per provider ---")
        let store = fixture(present: [], pin: .claude)
        defer { discard(store) }
        let reason = store.resolveRoute(.cleanupL2).offReason ?? ""
        check("the off reason names every provider",
              LLMProvider.allCases.allSatisfy { reason.contains("\($0.rawValue): ") })
        check("the off reason leads with the pin the user chose",
              reason.contains("- claude: "))
        check("a signed-out provider and an absent one read differently",
              reason.contains("claude: CLI unavailable")
                && reason.contains("codex: not connected")
                && reason.contains("local: LM Studio is not running"))

        // A provider whose availability changes changes the message, so the reason is live state and not
        // a fixed string that merely looks specific.
        store.setAvailabilityState(.unavailable("subscription credentials unreadable"), for: .claude)
        let updated = store.resolveRoute(.cleanupL2).offReason ?? ""
        check("the off reason tracks the live availability state",
              updated.contains("claude: subscription credentials unreadable")
                && !updated.contains("claude: CLI unavailable"))
    }

    // MARK: - no-nudge: the staff-pick install offer is gone

    /// One controlled direct-policy fixture for the no-nudge checks: an explicit pin, an injected
    /// installed catalog, an injected availability map, and optional capacity facts. No store, no
    /// kernel read, no app. This is the same `LLMAvailabilityRouting.resolve` production runs.
    private static func noNudgeResolve(
        pin: LLMProviderBundle,
        catalog: [LMStudioModelOption],
        localBundle: LLMProviderBundle? = nil,
        availability: [LLMProvider: LLMProviderAvailabilityState],
        capacity: LLMLocalCapacityFacts? = nil
    ) -> LLMRouteResolution {
        LLMAvailabilityRouting.resolve(
            pin: pin,
            bundle: { provider -> LLMProviderBundle? in
                if provider == .local { return localBundle ?? pin }
                return LLMProviderDefaults.testedBundle(for: provider, route: .cleanupL1)
            },
            availability: { availability[$0] ?? .unavailable("no-nudge fixture: \($0.rawValue) off") },
            localModels: catalog,
            localCapacity: capacity)
    }

    /// Seven `new:` checks (each fails on the unfixed code) and three `guard:` checks (each passes on
    /// the unfixed code and pins a decision that must not move). None constructs an AppKit object.
    private static func checkNoNudge(_ reporter: SelfTestReporter) {
        print("--- no-nudge: the staff-pick install offer is removed ---")

        let preferred = "no-nudge-fixture-preferred"
        let installed = "no-nudge-fixture-installed"
        let alternate = LMStudioModelOption(modelID: "no-nudge-fixture-alternate", label: "Alternate")

        // 1. A Local pin whose preferred model is not installed runs the installed model, no offer.
        let substitution = noNudgeResolve(
            pin: .local(preferred),
            catalog: [LMStudioModelOption(modelID: installed, label: "Installed")],
            availability: [.local: .available])
        reporter.record(
            "no-nudge: new: a Local pin whose preferred model is unavailable runs the installed model with no upgrade offer",
            substitution.bundle?.provider == .local && substitution.bundle?.modelID == installed
                && substitution.upgradeOffer == nil,
            substitution.logToken)

        // 2. The same for an unavailable staff pick with a smaller model running.
        let smallerRunning = noNudgeResolve(
            pin: .local(LLMProviderDefaults.localCleanupModelID),
            catalog: [LMStudioModelOption(modelID: installed, label: "Installed")],
            availability: [.local: .available])
        reporter.record(
            "no-nudge: new: an unavailable staff pick with a smaller model running offers no upgrade",
            smallerRunning.bundle?.modelID == installed && smallerRunning.upgradeOffer == nil,
            smallerRunning.logToken)

        // 3. The dictation HUD path: `upgradeOffer?.message` is the exact string the cleanup landing
        //    hands to `hud.toast`. It must be nil for a Local substitution.
        let dictationToast = substitution.upgradeOffer?.message
        reporter.record(
            "no-nudge: new: the dictation HUD's upgrade toast is gone for a Local substitution",
            dictationToast == nil,
            "toast=\(dictationToast ?? "nil")")

        // 4. The sticky-skill provenance path: the real pure line builder over the real provider report.
        let ran = CustomModeRunProvider(substitution)
        let provenance = ran.map { StickySkillPrompt.providerProvenanceLine($0) } ?? ""
        reporter.record(
            "no-nudge: new: the sticky-skill note provenance records no Install or upgrade text for a Local substitution",
            !provenance.contains("Install") && !provenance.contains("for the preferred local model")
                && !provenance.contains("Upgrade available"),
            provenance.replacingOccurrences(of: "\n", with: " | "))

        // 5. The custom-mode run provider must report no nudge offer.
        reporter.record(
            "no-nudge: new: the custom-mode run provider reports no upgrade offer for a Local substitution",
            ran?.upgradeOffer == nil,
            ran?.upgradeOffer?.message ?? "offer=nil")

        // 6. A cloud pin that falls back onto a substituted local model carries no nudge either.
        let cloudToLocal = noNudgeResolve(
            pin: .claude("no-nudge-fixture-claude"),
            catalog: [LMStudioModelOption(modelID: installed, label: "Installed")],
            localBundle: .local(preferred),
            availability: [.local: .available, .claude: .unavailable("CLI unavailable")])
        reporter.record(
            "no-nudge: new: a cloud pin that falls back to a substituted local model carries no upgrade offer",
            cloudToLocal.bundle?.provider == .local && cloudToLocal.bundle?.modelID == installed
                && cloudToLocal.upgradeOffer == nil,
            cloudToLocal.logToken)

        // 7. No built-in or custom route's Local substitution carries the offer any more.
        let store = fixture(present: [.local], pin: .local, localModels: [alternate])
        defer { discard(store) }
        let noRouteNudges = routes.allSatisfy { route in
            let resolution = store.resolveRoute(route)
            guard case .degraded(let bundle, .local, _, let offer) = resolution,
                  bundle.modelID == alternate.modelID else { return true }
            return offer == nil
        }
        reporter.record(
            "no-nudge: new: no built-in or custom route's Local substitution carries a staff-pick install offer",
            noRouteNudges, "routes=\(routes.count)")

        // GUARD 1: the crossing notice is untouched, message and cause included.
        let crossing = noNudgeResolve(
            pin: .local("no-nudge-fixture-lm-pin"),
            catalog: [LMStudioModelOption(modelID: "no-nudge-fixture-ollama-model",
                                          label: "Ollama Model", backend: .ollama)],
            availability: [.local: .available])
        let expectedCrossing = LocalBackendCrossing(
            from: .lmStudio, to: .ollama, cause: .pinnedAppNotRunning)
        reporter.record(
            "no-nudge: guard: the crossing notice (pinned app not answering, ran in the other app) still yields its exact message",
            crossing.bundle?.modelID == "no-nudge-fixture-ollama-model"
                && crossing.upgradeOffer?.crossing == expectedCrossing
                && crossing.upgradeOffer?.message
                    == "LM Studio wasn't running, so this ran on no-nudge-fixture-ollama-model in Ollama.",
            crossing.upgradeOffer?.message ?? "offer=nil")

        // GUARD 2: the existing provider/bundle choice is unchanged.
        let pinnedFixture = fixture(present: [.claude], pin: .codex)
        defer { discard(pinnedFixture) }
        let pinnedResolution = pinnedFixture.resolveRoute(.email)
        let pinnedRan = CustomModeRunProvider(pinnedResolution)
        reporter.record(
            "no-nudge: guard: the existing codex-pin fixture still runs Claude with the same bundle and skipped pin",
            pinnedResolution.bundle?.provider == .claude && pinnedRan?.degradedFrom == .codex,
            pinnedResolution.logToken)

        let localFixture = fixture(present: [.local], pin: .local, localModels: [alternate])
        defer { discard(localFixture) }
        let localResolution = localFixture.resolveRoute(.cleanupL1)
        reporter.record(
            "no-nudge: guard: the existing Local-substitution fixture still chooses the installed model on Local",
            localResolution.bundle?.provider == .local
                && localResolution.bundle?.modelID == alternate.modelID,
            localResolution.logToken)

        // GUARD 3: a degraded provider hop still reports degradedFrom/degradedReason.
        let cloudFixture = fixture(
            present: [.local], pin: .codex,
            localModels: [LMStudioModelOption(modelID: alternate.modelID, label: "Alternate")])
        defer { discard(cloudFixture) }
        let cloudResolution = cloudFixture.resolveRoute(.cleanupL1)
        let cloudRan = CustomModeRunProvider(cloudResolution)
        reporter.record(
            "no-nudge: guard: a degraded cloud-to-local hop still reports degradedFrom and degradedReason",
            cloudRan?.provider == .local && cloudRan?.degradedFrom == .codex
                && cloudRan?.degradedReason == "not connected",
            cloudRan?.degradedReason ?? "nil")
    }

    private static func checkContentSafety(_ check: (String, Bool) -> Void) {
        print("--- resolution decisions carry no user content ---")
        let canary = "SYNTHETIC_P6_\(UUID().uuidString)"
        let store = fixture(present: [], pin: .local)
        defer { discard(store) }
        let resolution = store.resolveRoute(.promptPrep)
        let run = dispatch(resolution, route: .promptPrep, input: canary)
        let carried: String
        if case .unavailable(let why) = run.result { carried = why } else { carried = "" }
        check("the off reason and log token cannot echo the transform's input",
              !carried.contains(canary) && !resolution.logToken.contains(canary)
                && !String(describing: resolution).contains(canary))

        Log.flushForTest()
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("the routing decision written to the app log carries no request text",
              !log.contains(canary) && log.contains("resolved provider=none source=off"))

        let degradedStore = fixture(present: [.claude], pin: .codex)
        defer { discard(degradedStore) }
        _ = dispatch(degradedStore.resolveRoute(.email), route: .email, input: canary)
        Log.flushForTest()
        let degradedLog = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("a degraded decision is logged with its provider, its pin, and no request text",
              !degradedLog.contains(canary)
                && degradedLog.contains("resolved provider=claude source=degraded from=codex"))
    }
}
