import Foundation

/// `--search-retrieval-local-only-selftest`: the Option+L retrieval leg is an LM Studio tool loop, so the
/// model id `SearchClient.retrievalModelID(store:)` hands onward (to `ModelManager.ensureReady` and to
/// `/v1/chat/completions`) must be an installed Local model that fits, whatever the durable route says.
///
/// The defect it grades: `.searchRetrieval` has no Models & Power card, but it carries Claude and Codex
/// tested bundles like every route, and the header's "Set every provider-capable route to its tested
/// default" action (`applyGlobalProvider`) pins it to them. With Claude available the route resolves
/// `.pinned(claude-haiku)`, and the pre-fix accessor handed that Claude id to LM Studio. Falling back to
/// `Settings.searchModel` instead is not a fix either: on a small Mac that is the 17 GB model 7b704b0
/// stopped handing LM Studio, so the leg must resolve the route's Local choice with the Local-pin policy.
///
/// Scratch-only: real `ModelsPowerSettingsStore`s under a fresh temporary directory, each with an
/// injected Local catalog and injected capacity facts (the `LLMLocalCapacityFacts` seam routing already
/// takes: fixed sizes, zero wired bytes, a fixed budget), so no fit decision reads the live kernel. The
/// installed model that fits is `retrieval-fixture-actually-installed` and the configured one that does
/// not is `retrieval-fixture-too-big`; neither is a shipped default or `Settings.searchModel`, so the right
/// answer can only come from really resolving the Local route against this catalog and these facts.
///
/// Negative controls, in the house style of the Ollama gates: the contract is re-run against three broken
/// accessors, and the gate FAILS unless the assertion aimed at each one reports it:
/// (a) the pre-fix accessor, `resolution.bundle?.modelID` handed onward unconditionally;
/// (b) the pre-route accessor, `Settings.searchModel` read directly (the route never consulted);
/// (c) a Local-only filter that falls back to `Settings.searchModel` whenever the provider is not Local.
enum SearchRetrievalLocalOnlyFixtureSelfTest {
    private static let installedID = "retrieval-fixture-actually-installed"
    private static let tooBigID = "retrieval-fixture-too-big"

    /// Distinct sizes against one fixed budget: 4 GB fits (x1.15 incoming = 4.6 GB <= 8 GB), 20 GB does not.
    private static let installedSizeBytes: Int64 = 4_000_000_000
    private static let tooBigSizeBytes: Int64 = 20_000_000_000
    private static let fixtureBudgetBytes: UInt64 = 8_000_000_000

    private static let fixtureCapacity = LLMLocalCapacityFacts(
        sizeBytes: { modelID in
            switch modelID {
            case installedID: return installedSizeBytes
            case tooBigID: return tooBigSizeBytes
            default: return nil
            }
        },
        wiredBytes: 0,
        budgetBytes: fixtureBudgetBytes)

    // Assertion names the negative controls look up.
    private static let localRouteCheck =
        "with the route on Local, the retrieval leg hands onward the installed fixture model"
    private static let globalClaudeCheck =
        "after the global Claude action with Claude available, the retrieval leg hands onward the installed "
            + "Local model, never a Claude or Codex id"
    private static let degradedOntoClaudeCheck =
        "after the global Codex action with Codex disconnected (the route degrades onto Claude), "
            + "the retrieval leg hands onward the installed Local model"
    private static let smallMacCheck =
        "small Mac: after the global Claude action, a configured Local model that does not fit steps down "
            + "to the installed model that does"

    /// The one seam a mutant replaces: store in, the id the retrieval leg hands onward out.
    private typealias RetrievalSubject = (ModelsPowerSettingsStore) -> String

    private static let realSubject: RetrievalSubject = { SearchClient.retrievalModelID(store: $0) }

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== search-retrieval local-only fixture selftest ===")
        let reporter = SelfTestReporter()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-search-retrieval-local-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            reporter.record("scratch root", false, error.localizedDescription)
            return reporter.passed
        }

        checkFixture(root: root, reporter)
        print("--- contract (real SearchClient.retrievalModelID) ---")
        checkContract(realSubject, root: root, reporter)
        checkNegativeControls(root: root, reporter)

        print(reporter.passed
            ? "[search-retrieval-local-only-selftest] PASS"
            : "[search-retrieval-local-only-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Fixture

    /// A real store with every route on its seeded Local pin, the injected capacity facts, `installed` as
    /// the measured Local catalog, Claude available and Codex disconnected.
    private static func freshStore(root: URL, _ name: String,
                                   installed: [String] = [installedID]) -> ModelsPowerSettingsStore {
        let store = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("\(name)-\(UUID().uuidString).json"), legacy: .empty,
            localCapacity: { _ in fixtureCapacity })
        store.setLocalAvailabilityState(.available, models: installed.map {
            LMStudioModelOption(modelID: $0, label: $0, sizeBytes: fixtureCapacity.sizeBytes($0))
        })
        store.setAvailabilityState(.available, for: .claude)
        store.setAvailabilityState(.disconnected, for: .codex)
        return store
    }

    /// Every Claude and Codex model id the shipped route table or this store could name, for any route.
    private static func cloudModelIDs(_ store: ModelsPowerSettingsStore) -> Set<String> {
        var ids = Set<String>()
        for route in LLMRouteID.builtIns {
            for provider in [LLMProvider.claude, .codex] {
                if let tested = LLMProviderDefaults.testedBundle(for: provider, route: route) {
                    ids.insert(tested.modelID)
                }
                if let remembered = store.rememberedBundle(for: provider, route: route) {
                    ids.insert(remembered.modelID)
                }
            }
        }
        return ids
    }

    private static func checkFixture(root: URL, _ reporter: SelfTestReporter) {
        let store = freshStore(root: root, "fixture")
        let cloud = cloudModelIDs(store)
        reporter.record("fixture: the route table names Claude and Codex ids for .searchRetrieval",
                        LLMProviderDefaults.testedBundle(for: .claude, route: .searchRetrieval) != nil
                            && LLMProviderDefaults.testedBundle(for: .codex, route: .searchRetrieval) != nil,
                        "cloud ids=\(cloud.sorted().joined(separator: ", "))")
        let fixtures = [installedID, tooBigID]
        reporter.record("fixture: neither fixture model is Settings.searchModel, the seeded Local pin, or a cloud id",
                        !fixtures.contains(Settings.searchModel)
                            && !fixtures.contains(store.selectedBundle(for: .searchRetrieval).modelID)
                            && cloud.isDisjoint(with: fixtures),
                        "searchModel=\(Settings.searchModel) pin=\(store.selectedBundle(for: .searchRetrieval).modelID)")
        reporter.record("fixture: the two models have distinct sizes; the installed one fits, the too-big one does not",
                        installedSizeBytes != tooBigSizeBytes
                            && fixtureCapacity.fits(installedID) && !fixtureCapacity.fits(tooBigID),
                        "budget=\(fixtureBudgetBytes)")
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(_ subject: RetrievalSubject, root: URL, _ reporter: SelfTestReporter) {
        // Local pin: the route really is read, and a Local degradation onto the installed model flows.
        let local = freshStore(root: root, "local")
        let localID = subject(local)
        reporter.record(localRouteCheck, localID == installedID, "handed onward=\(localID)")

        // The reported path: the header's global Claude action, Claude available.
        let claude = freshStore(root: root, "global-claude")
        var applied = true
        do { try claude.applyGlobalProvider(.claude) } catch { applied = false }
        let claudeResolution = claude.resolveRoute(.searchRetrieval, fallback: .local(Settings.searchModel))
        var pinnedClaude = false
        if case .pinned(let bundle) = claudeResolution, bundle.provider == .claude { pinnedClaude = true }
        reporter.record(
            "reproduction: the global Claude action pins .searchRetrieval to Claude and it resolves pinned",
            applied && claude.selectedBundle(for: .searchRetrieval).provider == .claude && pinnedClaude,
            claudeResolution.logToken)
        let claudeID = subject(claude)
        reporter.record(globalClaudeCheck, claudeID == installedID, "handed onward=\(claudeID)")

        // Global Codex while Codex is disconnected: the ladder degrades the route onto Claude.
        let codexDown = freshStore(root: root, "global-codex-disconnected")
        var codexApplied = true
        do { try codexDown.applyGlobalProvider(.codex) } catch { codexApplied = false }
        let degraded = codexDown.resolveRoute(.searchRetrieval, fallback: .local(Settings.searchModel))
        reporter.record(
            "reproduction: with Codex disconnected the Codex-pinned route degrades onto Claude",
            codexApplied && degraded.bundle?.provider == .claude, degraded.logToken)
        let degradedID = subject(codexDown)
        reporter.record(degradedOntoClaudeCheck, degradedID == installedID, "handed onward=\(degradedID)")

        // Global Codex while Codex is available: pinned Codex.
        let codexUp = freshStore(root: root, "global-codex-available")
        codexUp.setAvailabilityState(.available, for: .codex)
        try? codexUp.applyGlobalProvider(.codex)
        let codexID = subject(codexUp)
        reporter.record(
            "after the global Codex action with Codex available, the retrieval leg hands onward the installed Local model",
            codexID == installedID,
            "\(codexUp.resolveRoute(.searchRetrieval).logToken) handed onward=\(codexID)")

        // Small Mac: the configured Local model is installed but does not fit; the one that fits must run.
        let small = freshStore(root: root, "small-mac", installed: [tooBigID, installedID])
        try? small.setRememberedBundle(.local(tooBigID), for: .local, route: .searchRetrieval)
        try? small.applyGlobalProvider(.claude)
        let local2 = small.resolveLocalRoute(.searchRetrieval)
        reporter.record(
            "small Mac: the route is Claude-pinned and its Local choice is the configured too-big model",
            small.selectedBundle(for: .searchRetrieval).provider == .claude
                && small.rememberedBundle(for: .local, route: .searchRetrieval)?.modelID == tooBigID,
            "local resolution: \(local2.logToken)")
        let smallID = subject(small)
        reporter.record(smallMacCheck, smallID == installedID, "handed onward=\(smallID)")

        // A Claude pin that cannot run and whose ladder reaches Local: still the installed fixture model.
        let claudeDown = freshStore(root: root, "global-claude-unavailable")
        try? claudeDown.applyGlobalProvider(.claude)
        claudeDown.setAvailabilityState(.unavailable("fixture: claude not signed in"), for: .claude)
        let downID = subject(claudeDown)
        reporter.record(
            "a Claude pin that degrades onto Local still hands onward the installed fixture model",
            downID == installedID,
            "\(claudeDown.resolveRoute(.searchRetrieval).logToken) handed onward=\(downID)")
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(root: URL, _ reporter: SelfTestReporter) {
        // (a) The pre-fix accessor: whatever the route resolved to is handed onward, cloud or not.
        let unconditional: RetrievalSubject = { store in
            store.resolveRoute(.searchRetrieval, fallback: .local(Settings.searchModel)).bundle?.modelID
                ?? Settings.searchModel
        }
        requireCaught(reporter, mutant: "accessor that hands onward resolution.bundle?.modelID unconditionally",
                      by: globalClaudeCheck) {
            checkContract(unconditional, root: root, $0)
        }
        requireCaught(reporter, mutant: "accessor that hands onward resolution.bundle?.modelID unconditionally",
                      by: degradedOntoClaudeCheck) {
            checkContract(unconditional, root: root, $0)
        }

        // (b) The pre-route accessor: the configured scalar, the route never consulted.
        let scalarOnly: RetrievalSubject = { _ in Settings.searchModel }
        requireCaught(reporter, mutant: "accessor that reads Settings.searchModel and ignores the route",
                      by: localRouteCheck) {
            checkContract(scalarOnly, root: root, $0)
        }

        // (c) Never cloud, but never capacity-aware either: a non-Local resolution falls straight back to
        // the configured scalar, which on a small Mac is a model that does not fit.
        let scalarFallback: RetrievalSubject = { store in
            let resolution = store.resolveRoute(.searchRetrieval, fallback: .local(Settings.searchModel))
            guard let bundle = resolution.bundle, bundle.provider == .local else { return Settings.searchModel }
            return bundle.modelID
        }
        requireCaught(reporter, mutant: "Local-only filter that falls back to Settings.searchModel",
                      by: smallMacCheck) {
            checkContract(scalarFallback, root: root, $0)
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
