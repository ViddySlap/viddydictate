import Foundation

/// `--staff-pick-follows-app-selftest` (Ollama lane S3d, spec D1/D4): an UNTOUCHED Local route runs the
/// effective Preferred local app's staff pick, decided at resolution time and never written to storage; a
/// route the user customized keeps its exact (app, model); and an LM-Studio-only Mac resolves and stores
/// exactly what 1.1.0 did.
///
/// Real code throughout: real `ModelsPowerSettingsStore`s under a fresh temporary folder with an injected
/// catalog, injected capacity facts (fixed ref-keyed sizes, nothing wired, one 40 GB budget, so both staff
/// picks fit and a fit decision never reads the kernel) and an injected EXPLICIT Preferred local app (so no
/// live preference reaches a fixture). The picker rows and badges come from the real `StaffPicks` and
/// `LocalModelPickerItems`.
///
/// The fixture Ollama catalog holds both of Ollama's staff picks, qwen3-coder:30b (19 GB) and gemma4:e4b
/// (6.6 GB), so a resolver that ignores the Preferred app and lets D2's step-down choose takes the LARGEST
/// fitting model, qwen3-coder:30b, for email, and the email check sees it.
///
/// Negative controls: the contract is re-run against four broken policies, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (1) no follow: resolution reads the stored LM Studio staff pick as a pin (the pre-S3d store);
/// (2) customized routes follow too, overriding the user's (app, model);
/// (4) opening an LM-Studio-only store writes the effective app into every untouched route.
enum StaffPickFollowsAppFixtureSelfTest {
    private static let ollamaCoder = BootstrapInstallPlan.ollamaCleanupModelID
    private static let ollamaGemma = BootstrapInstallPlan.ollamaEmailModelID
    private static let lmCoder = LLMProviderDefaults.localCleanupModelID
    private static let lmGemma = LLMProviderDefaults.localEmailModelID
    private static let ollamaCustom = "ollama-follow-fixture-custom:8b"
    private static let lmCustom = "lmstudio-follow-fixture-custom"

    private static let budgetBytes: UInt64 = 40_000_000_000
    private static let sizes: [LocalModelRef: Int64] = [
        LocalModelRef(backend: .ollama, modelID: ollamaCoder): 19_000_000_000,
        LocalModelRef(backend: .ollama, modelID: ollamaGemma): 6_600_000_000,
        LocalModelRef(backend: .ollama, modelID: ollamaCustom): 4_900_000_000,
        LocalModelRef(backend: .lmStudio, modelID: lmCoder): 17_200_000_000,
        LocalModelRef(backend: .lmStudio, modelID: lmGemma): 6_300_000_000,
        LocalModelRef(backend: .lmStudio, modelID: lmCustom): 2_000_000_000,
    ]
    private static let facts = LLMLocalCapacityFacts(
        sizeBytes: { _ in nil }, wiredBytes: 0, budgetBytes: budgetBytes, sizeBytesByRef: { sizes[$0] })

    private static func option(_ backend: LocalBackendID, _ id: String) -> LMStudioModelOption {
        LMStudioModelOption(modelID: id, label: id, sizeBytes: sizes[LocalModelRef(backend: backend, modelID: id)],
                            backend: backend)
    }

    /// Ollama's catalog order puts the small model first, so "first row" is not "largest" either.
    private static let ollamaModels = [
        option(.ollama, ollamaGemma), option(.ollama, ollamaCoder), option(.ollama, ollamaCustom),
    ]
    private static let lmStudioModels = [
        option(.lmStudio, lmCoder), option(.lmStudio, lmGemma), option(.lmStudio, lmCustom),
    ]

    /// The explicit Preferred local app the fixture stores read. nil is Automatic.
    private final class PreferenceBox {
        var explicit: LocalBackendID?
    }

    // MARK: - The seams the mutants replace

    private struct Policy {
        /// What runs `route` right now.
        let resolve: (ModelsPowerSettingsStore, LLMRouteID) -> LLMRouteResolution
        /// Open the store at `url`, recording every write.
        let open: (URL, @escaping ModelsPowerSettingsStore.Writer, PreferenceBox) -> ModelsPowerSettingsStore
    }

    private static func makeStore(_ url: URL, writer: @escaping ModelsPowerSettingsStore.Writer,
                                  preference: PreferenceBox) -> ModelsPowerSettingsStore {
        ModelsPowerSettingsStore(url: url, legacy: .empty, writer: writer, localCapacity: { _ in facts },
                                 preferredLocalBackend: { preference.explicit })
    }

    private static let realPolicy = Policy(
        resolve: { store, route in store.resolveRoute(route) },
        open: { url, writer, preference in makeStore(url, writer: writer, preference: preference) })

    /// What `resolveRoute` was before this slice: the stored bundles read as pins, with D2 left to choose.
    private static func resolveStored(_ store: ModelsPowerSettingsStore, _ route: LLMRouteID,
                                      map: (LLMProviderBundle) -> LLMProviderBundle = { $0 }) -> LLMRouteResolution {
        LLMAvailabilityRouting.resolve(
            pin: map(store.selectedBundle(for: route)),
            bundle: { provider in
                (store.rememberedBundle(for: provider, route: route)
                    ?? LLMProviderDefaults.testedBundle(for: provider, route: route)).map(map)
            },
            availability: { store.availabilityState(for: $0) },
            localModels: store.availableLocalModelOptions(),
            localCapacity: facts, localFailure: nil, failedProviders: [:])
    }

    // Assertion names the negative controls look up.
    private static let emailFollowsCheck =
        "fresh store, Ollama-only Mac: email runs Ollama's staff pick (ollama, gemma4:e4b), pinned"
    private static let customizedStaysCheck =
        "a customized Local route keeps its exact (app, model) when the Preferred app changes"
    private static let fileIdenticalCheck =
        "LM Studio only: the stored file is byte-identical after load, resolution and save"

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== staff pick follows the Preferred local app (fixture selftest) ===")
        let reporter = SelfTestReporter()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-staff-pick-follows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            reporter.record("scratch root", false, error.localizedDescription)
            return reporter.passed
        }

        checkPicks(reporter)
        print("--- contract (real ModelsPowerSettingsStore.resolveRoute) ---")
        checkContract(realPolicy, root: root, reporter)
        checkDisplay(root: root, reporter)
        checkNegativeControls(root: root, reporter)

        print(reporter.passed
            ? "[staff-pick-follows-app-selftest] PASS"
            : "[staff-pick-follows-app-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - The per-app staff picks (D4)

    private static func checkPicks(_ reporter: SelfTestReporter) {
        let expected: [(LLMRouteID, String, String)] = [
            (.cleanupL1, lmCoder, ollamaCoder), (.cleanupL2, lmCoder, ollamaCoder),
            (.cleanupL3, lmCoder, ollamaCoder), (.promptPrep, lmCoder, ollamaCoder),
            (.searchRetrieval, lmCoder, ollamaCoder), (.email, lmGemma, ollamaGemma),
            (.searchLocalSynth, lmGemma, ollamaGemma), (.searchGeminiSynth, lmGemma, ollamaGemma),
            (.custom("follow-fixture"), lmCoder, ollamaCoder),
        ]
        for (route, lm, ollama) in expected {
            let lmPick = LLMProviderDefaults.testedLocalBundle(for: route, on: .lmStudio)
            let ollamaPick = LLMProviderDefaults.testedLocalBundle(for: route, on: .ollama)
            reporter.record(
                "D4 staff picks for \(route.rawValue): LM Studio \(lm), Ollama \(ollama)",
                lmPick == LLMProviderDefaults.testedBundle(for: .local, route: route)
                    && lmPick?.modelID == lm && lmPick?.localBackend == nil
                    && ollamaPick?.modelID == ollama && ollamaPick?.localBackend == .ollama,
                "lm=\(lmPick?.modelID ?? "nil") ollama=\(ollamaPick?.modelID ?? "nil")")
        }
        let seeded = LLMProviderDefaults.testedBundle(for: .local, route: .email)!
        reporter.record("the seeded Local bundle is the untouched staff pick; any named app is a choice",
                        StaffPicks.followsPreferredApp(seeded, route: .email)
                            && !StaffPicks.followsPreferredApp(
                                LLMProviderDefaults.testedLocalBundle(for: .email, on: .ollama)!, route: .email)
                            && !StaffPicks.followsPreferredApp(
                                LLMProviderBundle(provider: .local, modelID: lmGemma, localBackend: .lmStudio),
                                route: .email)
                            && !StaffPicks.followsPreferredApp(.local(lmCustom), route: .email))
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func local(_ resolution: LLMRouteResolution) -> LocalModelRef? {
        guard case .pinned(let bundle) = resolution, bundle.provider == .local else { return nil }
        return bundle.localRef
    }

    private static func ref(_ backend: LocalBackendID, _ id: String) -> LocalModelRef {
        LocalModelRef(backend: backend, modelID: id)
    }

    private static func checkContract(_ policy: Policy, root: URL, _ reporter: SelfTestReporter) {
        checkOllamaOnly(policy, root: root, reporter)
        checkCustomized(policy, root: root, reporter)
        checkGlobalControl(policy, root: root, reporter)
        checkLMStudioOnly(policy, root: root, reporter)
    }

    /// A fresh store seeded on a Mac with no Ollama, then Ollama is the only app: every untouched route follows.
    private static func checkOllamaOnly(_ policy: Policy, root: URL, _ reporter: SelfTestReporter) {
        let preference = PreferenceBox()
        var writes = 0
        let store = policy.open(root.appendingPathComponent("ollama-only-\(UUID().uuidString).json"),
                                { data, url in writes += 1; try ModelsPowerSettingsStore.atomicWriter(data, url) },
                                preference)
        store.setLocalAvailabilityState(.available, models: ollamaModels, installedBackends: [.ollama])
        let seededWrites = writes

        let email = policy.resolve(store, .email)
        reporter.record(emailFollowsCheck, local(email) == ref(.ollama, ollamaGemma), email.logToken)
        let cleanup = policy.resolve(store, .cleanupL1)
        reporter.record("fresh store, Ollama-only Mac: cleanup L1 runs (ollama, qwen3-coder:30b), pinned",
                        local(cleanup) == ref(.ollama, ollamaCoder), cleanup.logToken)
        let retrieval = policy.resolve(store, .searchRetrieval)
        reporter.record("fresh store, Ollama-only Mac: search retrieval runs (ollama, qwen3-coder:30b), pinned",
                        local(retrieval) == ref(.ollama, ollamaCoder), retrieval.logToken)
        let synthesis = policy.resolve(store, .searchGeminiSynth)
        reporter.record("fresh store, Ollama-only Mac: Gemini search synthesis runs (ollama, gemma4:e4b)",
                        local(synthesis) == ref(.ollama, ollamaGemma), synthesis.logToken)
        let retrievalRef = SearchClient.retrievalModelRef(store: store)
        reporter.record("the retrieval leg hands onward Ollama's staff pick",
                        retrievalRef == ref(.ollama, ollamaCoder), "ref=\(retrievalRef)")

        // LM Studio is installed later, and the user makes it the Preferred app: today's LM Studio picks.
        store.setLocalAvailabilityState(.available, models: lmStudioModels + ollamaModels,
                                        installedBackends: [.lmStudio, .ollama])
        preference.explicit = .lmStudio
        let lmEmail = policy.resolve(store, .email)
        let lmCleanup = policy.resolve(store, .cleanupL1)
        var lmEmailBundle: LLMProviderBundle?
        if case .pinned(let bundle) = lmEmail { lmEmailBundle = bundle }
        reporter.record("the same store, LM Studio installed later and Preferred LM Studio: today's LM Studio picks",
                        lmEmailBundle?.modelID == lmGemma && lmEmailBundle?.localBackend == nil
                            && local(lmCleanup) == ref(.lmStudio, lmCoder),
                        "\(lmEmail.logToken) / \(lmCleanup.logToken)")
        preference.explicit = nil
        let automatic = policy.resolve(store, .email)
        reporter.record("both apps installed and Preferred Automatic: LM Studio's pick (D3's tie-break)",
                        local(automatic) == ref(.lmStudio, lmGemma), automatic.logToken)
        preference.explicit = .ollama
        let back = policy.resolve(store, .email)
        reporter.record("switching Preferred to Ollama moves the untouched route back to Ollama's pick",
                        local(back) == ref(.ollama, ollamaGemma), back.logToken)
        reporter.record("following the Preferred app never writes the store",
                        writes == seededWrites
                            && StaffPicks.followsPreferredApp(store.selectedBundle(for: .email), route: .email),
                        "writes after seeding=\(writes - seededWrites)")

        // D2 still applies after the choice: Ollama preferred but not running crosses to LM Studio, degraded.
        store.setLocalAvailabilityState(.available, models: lmStudioModels, installedBackends: [.lmStudio, .ollama])
        let down = policy.resolve(store, .email)
        var crossed = false
        if case .degraded(let bundle, .local, let reason, _) = down {
            crossed = bundle.resolvedLocalBackend == .lmStudio && reason == "ran on LM Studio, Ollama wasn't running"
        }
        reporter.record("Preferred Ollama while Ollama is down: D2's cross-app step-down, degraded, naming both apps",
                        crossed, down.logToken)
    }

    /// Routes the user pointed at a model or an app keep it, whichever app is preferred.
    private static func checkCustomized(_ policy: Policy, root: URL, _ reporter: SelfTestReporter) {
        let preference = PreferenceBox()
        preference.explicit = .lmStudio
        let store = policy.open(root.appendingPathComponent("customized-\(UUID().uuidString).json"),
                                ModelsPowerSettingsStore.atomicWriter, preference)
        store.setLocalAvailabilityState(.available, models: lmStudioModels + ollamaModels,
                                        installedBackends: [.lmStudio, .ollama])
        do {
            try store.setSelectedBundle(.local(ref: ref(.ollama, ollamaCustom)), for: .cleanupL2)
            try store.setSelectedBundle(.local(lmCustom), for: .cleanupL3)
            // Ollama's own staff pick, picked by name while LM Studio is preferred: a choice of Ollama.
            try store.setSelectedBundle(LocalModelPickerItems.applying(
                ref(.ollama, ollamaGemma), to: store.selectedBundle(for: .searchLocalSynth),
                route: .searchLocalSynth, preferred: .lmStudio), for: .searchLocalSynth)
            // LM Studio's copy of the staff pick, picked while Ollama is preferred: a choice of LM Studio.
            try store.setSelectedBundle(LocalModelPickerItems.applying(
                ref(.lmStudio, lmCoder), to: store.selectedBundle(for: .promptPrep),
                route: .promptPrep, preferred: .ollama), for: .promptPrep)
        } catch {
            reporter.record("customized routes are stored", false, "\(error)")
            return
        }
        let expected: [(LLMRouteID, LocalModelRef)] = [
            (.cleanupL2, ref(.ollama, ollamaCustom)), (.cleanupL3, ref(.lmStudio, lmCustom)),
            (.searchLocalSynth, ref(.ollama, ollamaGemma)), (.promptPrep, ref(.lmStudio, lmCoder)),
        ]
        var stays = true
        var detail: [String] = []
        for preferred in [LocalBackendID.lmStudio, .ollama, .lmStudio] {
            preference.explicit = preferred
            for (route, want) in expected {
                let resolution = policy.resolve(store, route)
                if local(resolution) != want { stays = false }
                detail.append("\(preferred.rawValue)/\(route.rawValue)=\(local(resolution).map { "\($0.backend.rawValue):\($0.modelID)" } ?? resolution.logToken)")
            }
        }
        reporter.record(customizedStaysCheck, stays, stays ? "" : detail.joined(separator: " "))
        let promptPrep = store.selectedBundle(for: .promptPrep)
        reporter.record("LM Studio's staff pick picked while Ollama is preferred is stored with its app spelled out",
                        promptPrep.localBackend == .lmStudio && promptPrep.modelID == lmCoder
                            && !StaffPicks.followsPreferredApp(promptPrep, route: .promptPrep))

        // Picking the staff pick that runs now keeps the route untouched, so it keeps following.
        do {
            preference.explicit = .ollama
            try store.setSelectedBundle(.local(ref: ref(.ollama, ollamaCustom)), for: .email)
            try store.setSelectedBundle(LocalModelPickerItems.applying(
                ref(.ollama, ollamaGemma), to: store.selectedBundle(for: .email),
                route: .email, preferred: store.effectiveLocalBackend()), for: .email)
        } catch { reporter.record("re-pick the running staff pick", false, "\(error)") }
        reporter.record("picking the staff pick that runs now keeps the route following the Preferred app",
                        StaffPicks.followsPreferredApp(store.selectedBundle(for: .email), route: .email))
        preference.explicit = .lmStudio
        let moved = policy.resolve(store, .email)
        reporter.record("...so switching Preferred to LM Studio moves it to LM Studio's pick",
                        local(moved) == ref(.lmStudio, lmGemma), moved.logToken)
    }

    /// "Set every route to its staff pick" (Local) on an Ollama-preferred Mac writes routes that follow.
    private static func checkGlobalControl(_ policy: Policy, root: URL, _ reporter: SelfTestReporter) {
        let preference = PreferenceBox()
        let store = policy.open(root.appendingPathComponent("global-\(UUID().uuidString).json"),
                                ModelsPowerSettingsStore.atomicWriter, preference)
        store.setLocalAvailabilityState(.available, models: ollamaModels, installedBackends: [.ollama])
        do {
            try store.setSelectedBundle(.local(ref: ref(.ollama, ollamaCustom)), for: .email)
            try store.selectProvider(.claude, for: .cleanupL1)
            try store.applyGlobalProvider(.local)
        } catch {
            reporter.record("the global Local control applies", false, "\(error)")
            return
        }
        let following = LLMRouteID.builtIns.allSatisfy {
            StaffPicks.followsPreferredApp(store.selectedBundle(for: $0), route: $0)
        }
        let email = policy.resolve(store, .email)
        let cleanup = policy.resolve(store, .cleanupL1)
        reporter.record("the global Local control on an Ollama-preferred Mac leaves every route following the app",
                        following && local(email) == ref(.ollama, ollamaGemma)
                            && local(cleanup) == ref(.ollama, ollamaCoder),
                        "\(email.logToken) / \(cleanup.logToken)")
        store.setLocalAvailabilityState(.available, models: lmStudioModels + ollamaModels,
                                        installedBackends: [.lmStudio, .ollama])
        preference.explicit = .lmStudio
        let movedEmail = policy.resolve(store, .email)
        let movedCleanup = policy.resolve(store, .cleanupL1)
        reporter.record("...and switching Preferred to LM Studio later moves them to LM Studio's picks",
                        local(movedEmail) == ref(.lmStudio, lmGemma) && local(movedCleanup) == ref(.lmStudio, lmCoder),
                        "\(movedEmail.logToken) / \(movedCleanup.logToken)")
    }

    /// LM Studio is the only app: the resolution is 1.1.0's and the file is never rewritten.
    private static func checkLMStudioOnly(_ policy: Policy, root: URL, _ reporter: SelfTestReporter) {
        let url = root.appendingPathComponent("lmstudio-only-\(UUID().uuidString).json")
        // The 1.1.0-shaped file, written by the real store through its public mutations (as the codec gate does).
        let writer = ModelsPowerSettingsStore(url: url, localCapacity: { _ in facts }, preferredLocalBackend: { nil })
        do {
            try writer.selectProvider(.claude, for: .email)
            try writer.setSelectedBundle(.local(lmCustom), for: .cleanupL2)
            try writer.setPromptOverride("Fixture override prompt.", for: .cleanupL3, provider: .local)
        } catch {
            reporter.record("the LM-Studio-only fixture file is written", false, "\(error)")
            return
        }
        guard let original = try? Data(contentsOf: url) else {
            reporter.record("the LM-Studio-only fixture file is readable", false)
            return
        }

        let preference = PreferenceBox()
        var writes: [Data] = []
        let store = policy.open(url, { data, destination in
            writes.append(data)
            try ModelsPowerSettingsStore.atomicWriter(data, destination)
        }, preference)
        store.setLocalAvailabilityState(.available, models: lmStudioModels, installedBackends: [.lmStudio])

        var identical = true
        var detail: [String] = []
        for route in LLMRouteID.builtIns {
            let now = policy.resolve(store, route)
            let before = resolveStored(store, route)
            if now != before { identical = false; detail.append("\(route.rawValue): \(now.logToken) vs \(before.logToken)") }
        }
        reporter.record("LM Studio only: every route resolves exactly as the stored bundles did in 1.1.0",
                        identical, detail.joined(separator: "; "))
        var literal = false
        if case .pinned(let cleanup) = policy.resolve(store, .cleanupL1),
           case .pinned(let synth) = policy.resolve(store, .searchLocalSynth) {
            literal = cleanup.modelID == lmCoder && cleanup.localBackend == nil
                && synth.modelID == lmGemma && synth.localBackend == nil
        }
        reporter.record("LM Studio only: cleanup L1 runs \(lmCoder) and local synthesis \(lmGemma), no app key",
                        literal)
        reporter.record("LM Studio only: the pickers show the stored bundle itself",
                        LLMRouteID.builtIns.allSatisfy { store.displayedBundle(for: $0) == store.selectedBundle(for: $0) })

        // Save: a real write that ends where it started.
        do {
            try store.setPromptOverride("Fixture second override.", for: .cleanupL1, provider: .local)
            try store.setPromptOverride(nil, for: .cleanupL1, provider: .local)
        } catch { reporter.record("LM Studio only: the save round trip runs", false, "\(error)") }
        let onDisk = (try? Data(contentsOf: url)) ?? Data()
        reporter.record(fileIdenticalCheck,
                        writes.count == 2 && onDisk == original && writes.last == original,
                        "writes=\(writes.count) (the save's two) bytes=\(original.count)/\(onDisk.count)")
        reporter.record("LM Studio only: no localBackend key anywhere in the file",
                        !String(decoding: onDisk, as: UTF8.self).contains("localBackend"))
    }

    // MARK: - Display (the pickers and the preset line show what runs)

    private static func checkDisplay(root: URL, _ reporter: SelfTestReporter) {
        let preference = PreferenceBox()
        let store = makeStore(root.appendingPathComponent("display-\(UUID().uuidString).json"),
                              writer: ModelsPowerSettingsStore.atomicWriter, preference: preference)
        store.setLocalAvailabilityState(.available, models: ollamaModels, installedBackends: [.ollama])

        let shown = store.displayedBundle(for: .email)
        let badge = LocalModelPickerItems.presetBadge(
            StaffPicks.badge(bundle: shown, route: .email), bundle: shown, catalog: ollamaModels)
        reporter.record("Ollama-only Mac: the email preset reads STAFF PICK gemma4:e4b (one app, so no app name)",
                        badge == "STAFF PICK \(ollamaGemma)", badge)

        let grid = LocalModelPickerItems.routingGrid(
            catalog: ollamaModels, pinned: shown, tested: LLMProviderDefaults.testedBundle(for: .local, route: .email))
        let selected = grid.first(where: \.isSelected)
        reporter.record("Ollama-only Mac: the routing grid selects gemma4:e4b, marked Staff pick",
                        selected?.ref == ref(.ollama, ollamaGemma)
                            && selected?.title == ollamaGemma + StaffPicks.gridQualifier,
                        selected?.title ?? "nothing selected")

        let custom = LLMRouteID.custom("follow-fixture-skill")
        let sticky = LocalModelPickerItems.stickySkill(
            catalog: ollamaModels, pinned: store.followingPreferredApp(
                LLMProviderDefaults.testedBundle(for: .local, route: custom)!, route: custom),
            tested: LLMProviderDefaults.testedLocalBundle(for: custom, on: store.effectiveLocalBackend()))
        reporter.record("Ollama-only Mac: a Sticky Skill's untouched Local route selects qwen3-coder:30b",
                        sticky.first(where: \.isSelected)?.ref == ref(.ollama, ollamaCoder),
                        sticky.first(where: \.isSelected)?.title ?? "nothing selected")

        store.setLocalAvailabilityState(.available, models: lmStudioModels + ollamaModels,
                                        installedBackends: [.lmStudio, .ollama])
        preference.explicit = .ollama
        let both = store.displayedBundle(for: .email)
        let bothBadge = LocalModelPickerItems.presetBadge(
            StaffPicks.badge(bundle: both, route: .email), bundle: both, catalog: lmStudioModels + ollamaModels)
        reporter.record("both apps, Ollama preferred: the email preset reads STAFF PICK · Ollama · gemma4:e4b",
                        bothBadge == "STAFF PICK · Ollama · \(ollamaGemma)", bothBadge)
        preference.explicit = .lmStudio
        let lm = store.displayedBundle(for: .email)
        let lmBadge = LocalModelPickerItems.presetBadge(
            StaffPicks.badge(bundle: lm, route: .email), bundle: lm, catalog: lmStudioModels + ollamaModels)
        reporter.record("both apps, LM Studio preferred: STAFF PICK · LM Studio · google/gemma-4-e4b",
                        lmBadge == "STAFF PICK · LM Studio · \(lmGemma)", lmBadge)
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(root: URL, _ reporter: SelfTestReporter) {
        // (1) No follow: the stored LM Studio staff pick is the pin, and D2 picks the largest Ollama model.
        let noFollow = Policy(resolve: { store, route in resolveStored(store, route) }, open: realPolicy.open)
        requireCaught(reporter, mutant: "resolver that never follows the Preferred app", by: emailFollowsCheck) {
            checkContract(noFollow, root: root, $0)
        }

        // (2) Every Local route follows, customized or not.
        let followsAll = Policy(resolve: { store, route in
            let preferred = store.effectiveLocalBackend()
            return resolveStored(store, route) { bundle in
                guard bundle.provider == .local,
                      let pick = LLMProviderDefaults.testedLocalBundle(for: route, on: preferred) else { return bundle }
                return pick
            }
        }, open: realPolicy.open)
        requireCaught(reporter, mutant: "resolver that moves customized routes to the Preferred app's pick too",
                      by: customizedStaysCheck) {
            checkContract(followsAll, root: root, $0)
        }

        // (4) Opening the store materializes the effective app into every untouched route.
        let materializes = Policy(resolve: realPolicy.resolve, open: { url, writer, preference in
            let store = makeStore(url, writer: writer, preference: preference)
            let preferred = store.effectiveLocalBackend()
            for route in store.routeIDs() {
                let selected = store.selectedBundle(for: route)
                guard StaffPicks.followsPreferredApp(selected, route: route),
                      var pick = LLMProviderDefaults.testedLocalBundle(for: route, on: preferred) else { continue }
                pick.localBackend = preferred
                try? store.setSelectedBundle(pick, for: route)
            }
            return store
        })
        requireCaught(reporter, mutant: "store open that writes the Preferred app into untouched routes",
                      by: fileIdenticalCheck) {
            checkContract(materializes, root: root, $0)
        }
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
