import Foundation

enum LLMProviderAvailabilityState: Equatable {
    case available
    case disconnected
    case unavailable(String)

    var canRun: Bool {
        if case .available = self { return true }
        return false
    }

    var requiresConnection: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

enum LLMBulkProviderState: Equatable {
    case provider(LLMProvider)
    case mixed
}

enum LLMPromptVariant: String, Codable, CaseIterable {
    case primary
    case cleanupL1
    case cleanupL2
    case cleanupL3

    static func cleanup(_ level: CleanupLevel) -> LLMPromptVariant {
        switch level {
        case .cleanup: return .cleanupL1
        case .tighten: return .cleanupL2
        case .summarize: return .cleanupL3
        }
    }
}

enum LLMPromptCustomizationState: Equatable {
    case testedDefault
    case customized
}

/// Why an execution slate reads as unratified. The reasons are independent and can co-occur - a
/// deprecation-migrated model AND a user prompt edit both invalidate the sealed evidence in different
/// ways - so reporting only the first would hide the other.
enum LLMUnratifiedReason: String, Equatable, CaseIterable {
    /// The bundle carries no ratification provenance at all (every Local arm, and any model the user picked).
    case noEvidence
    /// The provenance names a different model than the one this route runs today. That is how a migrated
    /// shipped default stays honest: the evidence keeps pointing at the model it actually covered.
    case evidenceCoversAnotherModel
    /// The user replaced the shipped prompt bytes, so the evidence no longer covers what actually runs.
    case promptOverridden
}

/// Ratification is DERIVED, never stored. See `ModelsPowerSettingsStore.ratificationState(for:provider:variant:)`.
enum LLMRatificationState: Equatable {
    case ratified(LLMRatificationProvenance)
    case unratified([LLMUnratifiedReason])

    var isRatified: Bool {
        if case .ratified = self { return true }
        return false
    }

    func hasReason(_ reason: LLMUnratifiedReason) -> Bool {
        guard case .unratified(let reasons) = self else { return false }
        return reasons.contains(reason)
    }
}

enum ModelsPowerSettingsError: Error, Equatable, CustomStringConvertible {
    case noTestedDefault(provider: LLMProvider, route: LLMRouteID)
    case invalidBundle(expected: LLMProvider, actual: LLMProvider)
    case customRoutePrompt(LLMRouteID)
    case writeFailed(String)

    var description: String {
        switch self {
        case .noTestedDefault(let provider, let route):
            return "No tested \(provider.rawValue) default exists for \(route.rawValue)"
        case .invalidBundle(let expected, let actual):
            return "Expected a \(expected.rawValue) bundle, got \(actual.rawValue)"
        case .customRoutePrompt(let route):
            return "\(route.rawValue) uses one provider-neutral custom task prompt"
        case .writeFailed(let detail):
            return "Models settings could not be written: \(detail)"
        }
    }
}

extension ModelsPowerSettingsError: LocalizedError {
    var errorDescription: String? { description }
}

/// Exact pre-A4 state used to seed the new routing authority once. Tests inject fixtures; production
/// builds it from the existing UserDefaults keys and the inert legacy Low-Power bundle map.
struct ModelsPowerLegacyState {
    var selectedBundles: [LLMRouteID: LLMProviderBundle] = [:]
    var rememberedBundles: [LLMRouteID: [LLMProvider: LLMProviderBundle]] = [:]
    var promptOverrides: [LLMRouteID: [LLMProvider: [LLMPromptVariant: String]]] = [:]
    /// The pre-A1 store had one shared Claude arm for every custom mode. It is consumed only by the
    /// first custom-mode reconciliation after a new Models & Power store is created.
    var sharedCustomRememberedBundles: [LLMProvider: LLMProviderBundle] = [:]

    static let empty = ModelsPowerLegacyState()
}

private struct ModelsPowerRouteState: Codable, Equatable {
    var selectedProvider: LLMProvider
    /// Canonical provider raw values are used only as JSON object keys. Public/runtime APIs remain
    /// typed by `LLMProvider`; legacy `cloud` keys are canonicalized at this persistence boundary.
    var bundles: [String: LLMProviderBundle]
    var promptOverrides: [String: [String: String]]
}

private struct ModelsPowerSnapshot: Codable, Equatable {
    /// Version 4 persists each route's qualified current Codex default separately from its manual
    /// selected/remembered bundle, so Restore and missing-bundle seeding cannot resurrect a source.
    static let currentVersion = 4
    var version: Int
    var routes: [String: ModelsPowerRouteState]
    var codexDefaults: [String: LLMProviderBundle]?
}

struct CodexBundleCASUpdate: Equatable {
    let route: LLMRouteID
    let expected: LLMProviderBundle
    let replacement: LLMProviderBundle
}

struct CodexBundleCASResult: Equatable {
    let applied: [LLMRouteID]
    let skipped: [LLMRouteID]
}

/// Durable Models & Power settings authority. Every mutation is copy -> encode -> atomic write ->
/// publish, so a failed write leaves both the in-memory and on-disk state unchanged and is surfaced
/// through `UserDataWriteFailureCenter`. Provider availability is deliberately live/runtime state;
/// manual provider/model/prompt choices are durable.
final class ModelsPowerSettingsStore {
    static let didChange = Notification.Name("VDModelsPowerSettingsDidChange")
    typealias Writer = (Data, URL) throws -> Void

    static let shared: ModelsPowerSettingsStore = {
        let url = AppPaths.applicationSupportDirectory()
            .appendingPathComponent("models-power.json", isDirectory: false)
        return ModelsPowerSettingsStore(url: url, legacy: Settings.modelsPowerLegacyState())
    }()

    private let lock = NSLock()
    private let url: URL
    private let writer: Writer
    private var snapshot: ModelsPowerSnapshot
    private var mutationBlockDetail: String?
    private var pendingLegacyCustomRememberedBundles: [LLMProvider: LLMProviderBundle]
    private var availability: [LLMProvider: LLMProviderAvailabilityState] = [
        .local: .available,
        .claude: .available,
        .codex: .disconnected,
    ]

    init(url: URL, legacy: ModelsPowerLegacyState = .empty,
         writer: @escaping Writer = ModelsPowerSettingsStore.atomicWriter) {
        self.url = url
        self.writer = writer
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        pendingLegacyCustomRememberedBundles = fileExists
            ? [:] : legacy.sharedCustomRememberedBundles

        if fileExists {
            let decoded: ModelsPowerSnapshot
            do {
                let data = try Data(contentsOf: url)
                decoded = try JSONDecoder().decode(ModelsPowerSnapshot.self, from: data)
            } catch {
                snapshot = Self.seeded(from: legacy)
                mutationBlockDetail = error.localizedDescription
                UserDataWriteFailureCenter.report(
                    subsystem: "Models settings", operation: "load", url: url, error: error)
                return
            }
            let canonical = Self.canonicalized(decoded)
            snapshot = canonical
            if canonical != decoded {
                do { try persist(canonical) }
                catch {
                    UserDataWriteFailureCenter.report(
                        subsystem: "Models settings", operation: "migrate", url: url, error: error)
                }
            }
        } else {
            snapshot = Self.seeded(from: legacy)
            do {
                try persist(snapshot)
            } catch {
                UserDataWriteFailureCenter.report(
                    subsystem: "Models settings", operation: "initial migration", url: url, error: error)
            }
        }
    }

    static func atomicWriter(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: reads

    func routeIDs() -> [LLMRouteID] {
        lock.withLock {
            snapshot.routes.keys.compactMap(LLMRouteID.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
        }
    }

    func selectedBundle(for route: LLMRouteID, fallback: LLMProviderBundle? = nil) -> LLMProviderBundle {
        lock.withLock {
            if let state = snapshot.routes[route.rawValue],
               let bundle = state.bundles[state.selectedProvider.rawValue] {
                return Self.canonicalBundle(bundle, route: route)
            }
            if let fallback = fallback { return Self.canonicalBundle(fallback, route: route) }
            return LLMProviderDefaults.testedBundle(for: .local, route: route)!
        }
    }

    func rememberedBundle(for provider: LLMProvider, route: LLMRouteID) -> LLMProviderBundle? {
        lock.withLock {
            snapshot.routes[route.rawValue]?.bundles[provider.rawValue]
                .map { Self.canonicalBundle($0, route: route) }
        }
    }

    func bulkProviderState(routes: [LLMRouteID]? = nil) -> LLMBulkProviderState {
        lock.withLock {
            let ids = routes ?? snapshot.routes.keys.compactMap(LLMRouteID.init(rawValue:))
            let providers = Set(ids.map { route -> LLMProvider in
                snapshot.routes[route.rawValue]?.selectedProvider
                    ?? LLMProviderDefaults.testedBundle(for: .local, route: route)!.provider
            })
            return providers.count == 1 ? .provider(providers.first!) : .mixed
        }
    }

    /// The shipped prompt for a route/provider/variant. The factory bundle lives in the app binary
    /// (`LLMProviderDefaults`), never in the overlay file, so a build that retunes a prompt reaches every
    /// user who has not overridden that route, and Reset returns the bytes THIS build ships.
    func factoryPrompt(for route: LLMRouteID, provider: LLMProvider,
                       variant: LLMPromptVariant = .primary) -> String {
        LLMProviderDefaults.testedPrompt(for: route, provider: provider, variant: variant)
    }

    /// Overlay, then factory. There is no third layer and no caller-supplied default: call sites used to
    /// pass their own "tested default" read from the legacy provider-neutral UserDefaults prompt keys, which
    /// made those keys a hidden middle layer - so on a machine that carried one, deleting the overlay entry
    /// fell back to the user's old prompt instead of the shipped one. One owner, one fallback.
    func effectivePrompt(for route: LLMRouteID, provider: LLMProvider,
                         variant: LLMPromptVariant = .primary) -> String {
        let overlay = lock.withLock {
            snapshot.routes[route.rawValue]?.promptOverrides[provider.rawValue]?[variant.rawValue]
        }
        return overlay ?? factoryPrompt(for: route, provider: provider, variant: variant)
    }

    /// Ratification is DERIVED from the stored provenance rather than stamped into it, so an override never
    /// destroys sealed evidence and Reset is symmetric: delete the overlay entry and the ratified bytes are
    /// what runs again, so the route reads ratified again without anything being rewritten.
    func ratificationState(for route: LLMRouteID, provider: LLMProvider,
                           variant: LLMPromptVariant = .primary) -> LLMRatificationState {
        let overridden = promptCustomizationState(
            for: route, provider: provider, variant: variant) == .customized
        guard let bundle = rememberedBundle(for: provider, route: route)
                ?? LLMProviderDefaults.testedBundle(for: provider, route: route) else {
            return .unratified(overridden ? [.noEvidence, .promptOverridden] : [.noEvidence])
        }
        var reasons: [LLMUnratifiedReason] = []
        if let evidence = bundle.ratified {
            if evidence.modelID != bundle.modelID { reasons.append(.evidenceCoversAnotherModel) }
        } else {
            reasons.append(.noEvidence)
        }
        if overridden { reasons.append(.promptOverridden) }
        if reasons.isEmpty, let evidence = bundle.ratified { return .ratified(evidence) }
        return .unratified(reasons)
    }

    /// Resolve the actual provider instruction bytes while keeping the correction glossary outside
    /// durable Models & Power state. The three rescue defaults were judged with the glossary between
    /// their stable base and exact constraint suffix, so production preserves that ordering with the
    /// current live suffix. A user-customized provider prompt keeps the normal prompt-plus-glossary shape.
    func effectiveDeveloperInstructions(
        for route: LLMRouteID,
        provider: LLMProvider,
        variant: LLMPromptVariant = .primary,
        glossarySuffix: String
    ) -> String {
        let state = promptCustomizationState(for: route, provider: provider, variant: variant)
        if provider == .codex, state == .testedDefault,
           let ratified = CodexRatifiedPromptDefaults.variant(for: route) {
            return ratified.developerInstructions(glossarySuffix: glossarySuffix)
        }
        return effectivePrompt(for: route, provider: provider, variant: variant) + glossarySuffix
    }

    func promptCustomizationState(for route: LLMRouteID, provider: LLMProvider,
                                  variant: LLMPromptVariant = .primary) -> LLMPromptCustomizationState {
        lock.withLock {
            snapshot.routes[route.rawValue]?.promptOverrides[provider.rawValue]?[variant.rawValue] == nil
                ? .testedDefault : .customized
        }
    }

    func availabilityState(for provider: LLMProvider) -> LLMProviderAvailabilityState {
        lock.withLock { availability[provider] ?? .unavailable("availability unknown") }
    }

    /// Resolve who actually runs `route` right now (locked decision 4). Read-only by contract: a provider
    /// hop is an execution decision, never a durable one, so `selectedBundle` keeps returning the user's
    /// pin and the route snaps back to it the moment that provider is available again.
    ///
    /// The three reads below each take the lock separately rather than as one transaction. Availability is
    /// live state that can change between any two instructions anyway, so a resolution is a snapshot of the
    /// moment it was taken, and the durable half it reads cannot be mutated by an availability change.
    func resolveRoute(_ route: LLMRouteID, fallback: LLMProviderBundle? = nil,
                      failedProviders: [LLMProvider: String] = [:]) -> LLMRouteResolution {
        LLMAvailabilityRouting.resolve(
            pin: selectedBundle(for: route, fallback: fallback),
            bundle: { provider in
                rememberedBundle(for: provider, route: route)
                    ?? LLMProviderDefaults.testedBundle(for: provider, route: route)
            },
            availability: { availabilityState(for: $0) },
            failedProviders: failedProviders)
    }

    // MARK: durable mutations

    /// Reconcile the routing rows with the successfully decoded custom-mode file in one durable write.
    /// Existing route/provider memories win; `legacySelection` seeds only a never-before-seen route.
    /// On first adoption only, the old shared custom Claude arm is copied into every custom mode that
    /// already exists. A later user-created route receives current tested defaults, not that stale arm.
    func syncCustomRoutes(_ selections: [LLMRouteID: LLMProviderBundle]) throws {
        precondition(selections.keys.allSatisfy { if case .custom = $0 { return true }; return false })
        let legacyRemembered = lock.withLock { pendingLegacyCustomRememberedBundles }
        try mutate(operation: "sync custom routes") { candidate in
            let active = Set(selections.keys.map(\.rawValue))
            for raw in Array(candidate.routes.keys) where raw.hasPrefix("custom:") && !active.contains(raw) {
                candidate.routes.removeValue(forKey: raw)
                candidate.codexDefaults?.removeValue(forKey: raw)
            }
            for (route, selected) in selections where candidate.routes[route.rawValue] == nil {
                let codexDefault = Self.currentDefaultBundle(
                    for: .codex, route: route, snapshot: candidate)
                candidate.routes[route.rawValue] = Self.seededRoute(
                    route: route,
                    selected: selected,
                    remembered: legacyRemembered,
                    prompts: [:],
                    codexDefault: codexDefault)
                if let codexDefault {
                    candidate.codexDefaults?[route.rawValue] = codexDefault
                }
            }
        }
        lock.withLock { pendingLegacyCustomRememberedBundles.removeAll() }
    }

    /// Normal per-route provider switching uses the remembered bundle first; only a never-used provider
    /// falls back to its tested default. No provider hop or execution occurs here.
    func selectProvider(_ provider: LLMProvider, for route: LLMRouteID) throws {
        try mutate(operation: "select provider") { candidate in
            var state = Self.state(for: route, in: candidate)
            if state.bundles[provider.rawValue] == nil {
                guard let tested = Self.currentDefaultBundle(
                    for: provider, route: route, snapshot: candidate) else {
                    throw ModelsPowerSettingsError.noTestedDefault(provider: provider, route: route)
                }
                state.bundles[provider.rawValue] = tested
            }
            state.selectedProvider = provider
            candidate.routes[route.rawValue] = state
        }
    }

    func setSelectedBundle(_ bundle: LLMProviderBundle, for route: LLMRouteID) throws {
        try mutate(operation: "set route bundle") { candidate in
            var state = Self.state(for: route, in: candidate)
            let canonical = Self.canonicalBundle(bundle, route: route)
            state.bundles[bundle.provider.rawValue] = canonical
            state.selectedProvider = bundle.provider
            candidate.routes[route.rawValue] = state
        }
    }

    func setRememberedBundle(_ bundle: LLMProviderBundle, for provider: LLMProvider,
                             route: LLMRouteID) throws {
        guard bundle.provider == provider else {
            throw ModelsPowerSettingsError.invalidBundle(expected: provider, actual: bundle.provider)
        }
        try mutate(operation: "remember route bundle") { candidate in
            var state = Self.state(for: route, in: candidate)
            state.bundles[provider.rawValue] = Self.canonicalBundle(bundle, route: route)
            candidate.routes[route.rawValue] = state
        }
    }

    /// Apply a qualified Codex migration set as one true store-level compare-and-swap. The complete
    /// canonical Codex bundle comparison and the one persistence write happen while `lock` is held by
    /// `mutate`; there is no read/check/write gap in which a probe can clobber a user edit. Missing
    /// routes and changed bundles are skipped, never seeded or resurrected.
    func compareAndSwapCodexBundles(
        _ updates: [CodexBundleCASUpdate]
    ) throws -> CodexBundleCASResult {
        for update in updates {
            guard update.expected.provider == .codex else {
                throw ModelsPowerSettingsError.invalidBundle(
                    expected: .codex, actual: update.expected.provider)
            }
            guard update.replacement.provider == .codex else {
                throw ModelsPowerSettingsError.invalidBundle(
                    expected: .codex, actual: update.replacement.provider)
            }
        }
        let ordered = updates.sorted { $0.route.rawValue < $1.route.rawValue }
        precondition(Set(ordered.map(\.route)).count == ordered.count)
        var applied: [LLMRouteID] = []
        var skipped: [LLMRouteID] = []
        try mutate(operation: "auto-update Codex routes") { candidate in
            for update in ordered {
                guard var state = candidate.routes[update.route.rawValue],
                      let stored = state.bundles[LLMProvider.codex.rawValue],
                      Self.canonicalBundle(stored, route: update.route)
                        == Self.canonicalBundle(update.expected, route: update.route) else {
                    skipped.append(update.route)
                    continue
                }
                let replacement = Self.canonicalBundle(
                    update.replacement, route: update.route)
                state.bundles[LLMProvider.codex.rawValue] = replacement
                candidate.routes[update.route.rawValue] = state
                candidate.codexDefaults?[update.route.rawValue] = replacement
                applied.append(update.route)
            }
        }
        return CodexBundleCASResult(applied: applied, skipped: skipped)
    }

    /// Header bulk actions are intentionally default-driven: every provider-capable route receives the
    /// tested bundle in stable route-id order. Routes with no tested default are left byte-for-byte
    /// unchanged, so a partial Codex slate can never substitute another model/provider for them.
    func applyGlobalProvider(_ provider: LLMProvider) throws {
        try mutate(operation: "apply global provider") { candidate in
            let routes = candidate.routes.keys.compactMap(LLMRouteID.init(rawValue:))
                .sorted { $0.rawValue < $1.rawValue }
            var tested: [LLMRouteID: LLMProviderBundle] = [:]
            for route in routes {
                if let bundle = Self.currentDefaultBundle(
                    for: provider, route: route, snapshot: candidate) {
                    tested[route] = bundle
                }
            }
            guard !tested.isEmpty else {
                throw ModelsPowerSettingsError.noTestedDefault(
                    provider: provider, route: routes.first ?? .cleanupL1)
            }
            for route in routes where tested[route] != nil {
                var state = Self.state(for: route, in: candidate)
                state.bundles[provider.rawValue] = tested[route]!
                state.selectedProvider = provider
                candidate.routes[route.rawValue] = state
            }
        }
    }

    /// The simple Cleanup card applies one provider across its three strength routes, while the three
    /// remembered bundles remain independently editable through `setRememberedBundle`.
    func applyCleanupProvider(_ provider: LLMProvider) throws {
        let routes = LLMRouteID.cleanupRoutes
        try mutate(operation: "apply cleanup provider") { candidate in
            var selectedAny = false
            for route in routes {
                var state = Self.state(for: route, in: candidate)
                if state.bundles[provider.rawValue] == nil {
                    guard let tested = Self.currentDefaultBundle(
                        for: provider, route: route, snapshot: candidate) else {
                        continue
                    }
                    state.bundles[provider.rawValue] = tested
                }
                state.selectedProvider = provider
                candidate.routes[route.rawValue] = state
                selectedAny = true
            }
            if !selectedAny {
                throw ModelsPowerSettingsError.noTestedDefault(provider: provider, route: .cleanupL1)
            }
        }
    }

    /// The overlay holds ONLY what changed. Blank text and text identical to the shipped prompt are both
    /// "no override" and are normalized to a delete here rather than in each caller, so Reset has exactly
    /// one meaning whichever side of the editor it arrives from, and an empty system prompt can never be
    /// persisted as if it were a deliberate choice.
    func setPromptOverride(_ prompt: String?, for route: LLMRouteID, provider: LLMProvider,
                           variant: LLMPromptVariant = .primary) throws {
        if case .custom = route { throw ModelsPowerSettingsError.customRoutePrompt(route) }
        var prompt = prompt
        if let candidate = prompt,
           candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || candidate == factoryPrompt(for: route, provider: provider, variant: variant) {
            prompt = nil
        }
        try mutate(operation: "set prompt override") { candidate in
            var state = Self.state(for: route, in: candidate)
            var providerPrompts = state.promptOverrides[provider.rawValue] ?? [:]
            if let prompt = prompt { providerPrompts[variant.rawValue] = prompt }
            else { providerPrompts.removeValue(forKey: variant.rawValue) }
            if providerPrompts.isEmpty { state.promptOverrides.removeValue(forKey: provider.rawValue) }
            else { state.promptOverrides[provider.rawValue] = providerPrompts }
            candidate.routes[route.rawValue] = state
        }
    }

    /// Restore is the only operation that clears that provider's built-in prompt customizations. It
    /// reinstalls the complete tested bundle (model, effort, prompt version/hash, envelope version),
    /// selects that provider, and never touches the dynamic correction glossary or a custom task prompt.
    func restoreProviderDefault(_ provider: LLMProvider, for route: LLMRouteID) throws {
        try restoreProviderDefault(provider, for: [route])
    }

    /// Multi-route twin used by the simple Cleanup card. Every available tested bundle is resolved before
    /// the single copy/write/publish transaction. Routes with no tested default stay untouched; a request
    /// containing no restorable route still fails explicitly.
    func restoreProviderDefault(_ provider: LLMProvider, for routes: [LLMRouteID]) throws {
        let routes = Array(Set(routes)).sorted { $0.rawValue < $1.rawValue }
        var tested: [LLMRouteID: LLMProviderBundle] = [:]
        for route in routes {
            if let bundle = LLMProviderDefaults.testedBundle(for: provider, route: route) {
                tested[route] = bundle
            }
        }
        guard !tested.isEmpty else {
            throw ModelsPowerSettingsError.noTestedDefault(
                provider: provider, route: routes.first ?? .cleanupL1)
        }
        try mutate(operation: "restore provider default") { candidate in
            for route in routes where tested[route] != nil {
                var state = Self.state(for: route, in: candidate)
                state.bundles[provider.rawValue] = Self.currentDefaultBundle(
                    for: provider, route: route, snapshot: candidate)!
                state.selectedProvider = provider
                if case .custom = route {
                    // Provider-neutral custom task text lives in CustomModeStore and is intentionally untouched.
                } else {
                    state.promptOverrides.removeValue(forKey: provider.rawValue)
                }
                candidate.routes[route.rawValue] = state
            }
        }
    }

    // MARK: live availability

    func setAvailabilityState(_ state: LLMProviderAvailabilityState, for provider: LLMProvider) {
        let changed = lock.withLock { () -> Bool in
            guard availability[provider] != state else { return false }
            availability[provider] = state
            return true
        }
        guard changed else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: persistence + migration

    private func mutate(operation: String, _ body: (inout ModelsPowerSnapshot) throws -> Void) throws {
        lock.lock()
        if let detail = mutationBlockDetail {
            lock.unlock()
            throw ModelsPowerSettingsError.writeFailed(
                "the existing settings file could not be decoded; refusing to overwrite it (\(detail))")
        }
        var candidate = snapshot
        do {
            try body(&candidate)
            candidate = Self.canonicalized(candidate)
            if candidate == snapshot {
                lock.unlock()
                return
            }
            try persist(candidate)
            snapshot = candidate
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } catch {
            lock.unlock()
            if let typed = error as? ModelsPowerSettingsError { throw typed }
            UserDataWriteFailureCenter.report(
                subsystem: "Models settings", operation: operation, url: url, error: error)
            throw ModelsPowerSettingsError.writeFailed(error.localizedDescription)
        }
    }

    private func persist(_ value: ModelsPowerSnapshot) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer(enc.encode(value), url)
    }

    private static func seeded(from legacy: ModelsPowerLegacyState) -> ModelsPowerSnapshot {
        var routes: [String: ModelsPowerRouteState] = [:]
        for route in LLMRouteID.builtIns {
            let selected = legacy.selectedBundles[route]
                ?? LLMProviderDefaults.testedBundle(for: .local, route: route)!
            routes[route.rawValue] = seededRoute(
                route: route, selected: selected,
                remembered: legacy.rememberedBundles[route] ?? [:],
                prompts: legacy.promptOverrides[route] ?? [:])
        }
        return canonicalized(ModelsPowerSnapshot(
            version: ModelsPowerSnapshot.currentVersion,
            routes: routes,
            codexDefaults: [:]))
    }

    private static func seededRoute(
        route: LLMRouteID,
        selected: LLMProviderBundle,
        remembered: [LLMProvider: LLMProviderBundle],
        prompts: [LLMProvider: [LLMPromptVariant: String]],
        codexDefault: LLMProviderBundle? = nil
    ) -> ModelsPowerRouteState {
        var bundles: [String: LLMProviderBundle] = [:]
        for provider in LLMProvider.allCases {
            let tested = provider == .codex
                ? codexDefault ?? LLMProviderDefaults.testedBundle(for: provider, route: route)
                : LLMProviderDefaults.testedBundle(for: provider, route: route)
            if let tested {
                bundles[provider.rawValue] = tested
            }
        }
        for (provider, bundle) in remembered {
            bundles[provider.rawValue] = canonicalBundle(bundle, route: route)
        }
        bundles[selected.provider.rawValue] = canonicalBundle(selected, route: route)

        var encodedPrompts: [String: [String: String]] = [:]
        for (provider, variants) in prompts {
            encodedPrompts[provider.rawValue] = Dictionary(
                uniqueKeysWithValues: variants.map { ($0.key.rawValue, $0.value) })
        }
        return ModelsPowerRouteState(
            selectedProvider: selected.provider, bundles: bundles, promptOverrides: encodedPrompts)
    }

    private static func state(for route: LLMRouteID, in snapshot: ModelsPowerSnapshot) -> ModelsPowerRouteState {
        snapshot.routes[route.rawValue] ?? seededRoute(
            route: route,
            selected: LLMProviderDefaults.testedBundle(for: .local, route: route)!,
            remembered: [:],
            prompts: [:],
            codexDefault: currentDefaultBundle(
                for: .codex, route: route, snapshot: snapshot))
    }

    /// The route's qualified default is independent of its later manual selected/remembered bundle.
    /// Version-3 stores adopt an existing deprecation migration once; version 4 then preserves that
    /// authority across manual picker changes, Restore, global actions, and missing-bundle seeding.
    private static func currentDefaultBundle(
        for provider: LLMProvider,
        route: LLMRouteID,
        snapshot: ModelsPowerSnapshot
    ) -> LLMProviderBundle? {
        guard let shipped = LLMProviderDefaults.testedBundle(
            for: provider, route: route) else {
            return nil
        }
        if provider == .codex,
           let current = snapshot.codexDefaults?[route.rawValue],
           current.provider == .codex {
            return canonicalBundle(current, route: route)
        }
        return shipped
    }

    private static func canonicalized(_ input: ModelsPowerSnapshot) -> ModelsPowerSnapshot {
        var out = input
        out.version = ModelsPowerSnapshot.currentVersion
        var codexDefaults: [String: LLMProviderBundle] = Dictionary(uniqueKeysWithValues:
            (out.codexDefaults ?? [:]).compactMap { raw, bundle in
                guard let route = LLMRouteID(rawValue: raw),
                      LLMRouteID.builtIns.contains(route) || out.routes[raw] != nil,
                      bundle.provider == .codex else {
                    return nil
                }
                return (raw, canonicalBundle(bundle, route: route))
            })
        let defaultRoutes = Set(
            LLMRouteID.builtIns + out.routes.keys.compactMap(LLMRouteID.init(rawValue:)))
        for route in defaultRoutes where codexDefaults[route.rawValue] == nil {
            let stored = out.routes[route.rawValue]?.bundles[LLMProvider.codex.rawValue]
            if let stored,
               stored.provider == .codex,
               stored.autoUpdated?.reason == .deprecation,
               stored.autoUpdated?.fromModelID != stored.modelID {
                codexDefaults[route.rawValue] = canonicalBundle(stored, route: route)
            } else if let shipped = LLMProviderDefaults.testedBundle(
                for: .codex, route: route) {
                codexDefaults[route.rawValue] = shipped
            }
        }
        out.codexDefaults = codexDefaults
        out.routes = Dictionary(uniqueKeysWithValues: out.routes.compactMap { raw, state in
            guard let route = LLMRouteID(rawValue: raw) else { return nil }
            var canonical = state
            canonical.bundles = Dictionary(uniqueKeysWithValues: state.bundles.compactMap { providerRaw, bundle in
                guard let provider = LLMProvider.decodeStored(providerRaw), provider == bundle.provider else { return nil }
                return (provider.rawValue, canonicalBundle(bundle, route: route))
            })
            for provider in LLMProvider.allCases where canonical.bundles[provider.rawValue] == nil {
                let tested = provider == .codex
                    ? codexDefaults[route.rawValue]
                    : LLMProviderDefaults.testedBundle(for: provider, route: route)
                if let tested {
                    canonical.bundles[provider.rawValue] = tested
                }
            }
            if canonical.bundles[canonical.selectedProvider.rawValue] == nil {
                canonical.selectedProvider = .local
            }
            canonical.promptOverrides = Dictionary(uniqueKeysWithValues: canonical.promptOverrides.compactMap {
                providerRaw, variants in
                guard let provider = LLMProvider.decodeStored(providerRaw) else { return nil }
                let clean = Dictionary(uniqueKeysWithValues: variants.compactMap { variantRaw, prompt in
                    LLMPromptVariant(rawValue: variantRaw).map { ($0.rawValue, prompt) }
                })
                return clean.isEmpty ? nil : (provider.rawValue, clean)
            })
            return (route.rawValue, canonical)
        })
        for route in LLMRouteID.builtIns where out.routes[route.rawValue] == nil {
            out.routes[route.rawValue] = seededRoute(
                route: route,
                selected: LLMProviderDefaults.testedBundle(for: .local, route: route)!,
                remembered: [:],
                prompts: [:],
                codexDefault: codexDefaults[route.rawValue])
        }
        return out
    }

    private static func canonicalBundle(_ bundle: LLMProviderBundle, route: LLMRouteID) -> LLMProviderBundle {
        LLMProviderDefaults.withTestedMetadata(
            LLMProviderDefaults.replacingRetiredShippedDefault(bundle, route: route),
            route: route)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
