import Foundation

/// A local-model substitution that keeps a route useful without hiding that the preferred model was not
/// the one that ran. The identifiers come from route settings and LM Studio's installed catalog, never
/// from dictated text or provider output.
struct LLMRouteUpgradeOffer: Equatable {
    let preferredModelID: String
    let runningModelID: String

    var message: String {
        "Running on \(runningModelID). Install \(preferredModelID) for the preferred local model."
    }

    var logToken: String {
        "preferred=\(preferredModelID) running=\(runningModelID)"
    }
}

/// What actually runs a route on this attempt, decided at execution time rather than stored.
///
/// Every string here is an app-authored classification. Resolution is given a pin, the route's configured
/// bundles, and the live availability map; it never sees transcript, prompt, or provider response text, so
/// an off/degraded reason cannot carry user content by construction.
enum LLMRouteResolution: Equatable {
    /// The pinned provider is available. Its bundle runs byte-for-byte as configured.
    case pinned(LLMProviderBundle)
    /// The pin cannot run, so the highest-preference available provider runs its configured bundle for the
    /// same route. `from` is the pin that was skipped and `reason` is why it could not run. The durable pin
    /// is NOT rewritten: the route returns to it the moment that provider is available again.
    case degraded(LLMProviderBundle, from: LLMProvider, reason: String,
                  upgradeOffer: LLMRouteUpgradeOffer?)
    /// No configured provider can run this route. The mode reports itself off with `reason` and the caller's
    /// ordinary raw-fallback landing takes over, so a transcript is never eaten by a missing provider.
    case off(reason: String)

    /// The bundle to execute, or nil when the route is off.
    var bundle: LLMProviderBundle? {
        switch self {
        case .pinned(let bundle): return bundle
        case .degraded(let bundle, _, _, _): return bundle
        case .off: return nil
        }
    }

    var upgradeOffer: LLMRouteUpgradeOffer? {
        if case .degraded(_, _, _, let offer) = self { return offer }
        return nil
    }

    var offReason: String? {
        if case .off(let reason) = self { return reason }
        return nil
    }

    /// Content-safe one-line record of the decision, for the app log and for the Settings surface that
    /// P11 will build on top of it.
    var logToken: String {
        switch self {
        case .pinned(let bundle):
            return "provider=\(bundle.provider.rawValue) source=pin"
        case .degraded(let bundle, let from, let reason, let offer):
            let offerToken = offer.map { " offer=\($0.logToken)" } ?? ""
            return "provider=\(bundle.provider.rawValue) source=degraded from=\(from.rawValue) why=\(reason)\(offerToken)"
        case .off(let reason):
            return "provider=none source=off why=\(reason)"
        }
    }
}

/// Local-model capacity facts needed to judge fit, injected so LLMAvailabilityRouting itself never
/// spawns a process or reads the kernel. `fits` runs the identical arithmetic
/// ModelManager.fits/estimatedIncomingBytes already implement rather than a second copy.
///
/// `residentModelIDs` is what LM Studio holds RIGHT NOW, by `lms ps` identifier. Live wired memory already
/// contains every resident model, so charging a resident model's size again on top of it counts it twice:
/// with qwen3-coder-30b and gemma resident on a 64 GB Mac, neither "fit" the default budget and routing
/// stepped a working route down or off. `ModelManager.prepareCapacity` never charges a resident model (it
/// returns `.alreadyResident`), and this agrees with it: a resident model's incoming cost is 0, so it fits
/// whenever the machine already holds it. The set defaults to empty, which is the old arithmetic exactly,
/// and an unreadable resident set is empty too, so a failed read can only ever refuse more, never less.
struct LLMLocalCapacityFacts {
    let sizeBytes: (String) -> Int64?
    let wiredBytes: UInt64
    let budgetBytes: UInt64
    /// LM Studio identifiers from the same `lms ps` read `ModelManager` matches a request against.
    let residentModelIDs: Set<String>

    init(sizeBytes: @escaping (String) -> Int64?, wiredBytes: UInt64, budgetBytes: UInt64,
         residentModelIDs: Set<String> = []) {
        self.sizeBytes = sizeBytes
        self.wiredBytes = wiredBytes
        self.budgetBytes = budgetBytes
        self.residentModelIDs = residentModelIDs
    }

    /// Is `modelID` loaded in LM Studio right now? Then it allocates nothing new.
    func isResident(_ modelID: String) -> Bool {
        residentModelIDs.contains(modelID)
    }

    func fits(_ modelID: String) -> Bool {
        if isResident(modelID) { return true }
        guard let size = sizeBytes(modelID), size > 0,
              let incoming = ModelManager.estimatedIncomingBytes(sizeBytes: size)
        else { return true } // unmeasured: do not block a model we cannot size
        return ModelManager.fits(wiredBytes: wiredBytes, incomingBytes: incoming, budgetBytes: budgetBytes)
    }

    /// A conservative stand-in for a caller that has not wired in live capacity facts.
    /// ModelsPowerSettingsStore.resolveRoute always injects the real machine's facts instead; this
    /// default is only reached by a bare policy call (the self-tests call resolve() directly).
    /// Sized to a 16 GB Mac at the shipped default budget slider position (54) - the same
    /// conservative machine ComponentPicker's own O2 arithmetic already treats as unable to hold
    /// qwen - so a caller that supplies nothing still refuses an unmanageable model instead of
    /// defaulting open. This is a fixed constant, NOT a live kernel read.
    static let conservativeDefault: LLMLocalCapacityFacts = {
        let assumedPhysicalBytes: UInt64 = 16 * 1_073_741_824
        let assumedWireLimit = Double(assumedPhysicalBytes) * 0.82
        let assumedBudget = UInt64(assumedWireLimit * SystemMemory.realFraction(forSliderPosition: 54.0))
        return LLMLocalCapacityFacts(
            sizeBytes: { modelID in
                ComponentPicker.RowID.allCases
                    .first { $0.modelID == modelID }
                    .flatMap { ComponentPicker.bytes(for: $0) }
                    .map(Int64.init)
            },
            wiredBytes: 0,
            budgetBytes: assumedBudget)
    }()
}

/// A typed per-run Local failure. `failedProviders` is keyed by PROVIDER, so on its own it cannot say
/// "this model could not be made resident for capacity" without also taking the whole Local arm off.
/// A size refusal is answerable - it means try another installed model that fits - so it carries the
/// failed model id and is kept distinct from an ordinary connectivity/load failure, which stays terminal.
enum LLMLocalRouteFailure: Equatable {
    /// The named model's estimated incoming allocation exceeded the live wire budget.
    case overBudget(modelID: String)
}

/// Availability-resolved routing (Public V1 locked decision 4): the explicit user pin if it is set and
/// available, else the highest-preference available provider, else the route reports itself off with a
/// specific reason.
enum LLMAvailabilityRouting {
    /// The declared provider fallback ladder, used ONLY when a cloud pin cannot run. Local is last on
    /// purpose: a cloud pin may fall back to a capable local model, but a local pin is never allowed to
    /// climb into a cloud provider automatically. Claude before Codex is a stable declared order, not a
    /// quality judgement.
    ///
    /// Local model discovery is supplied separately from provider availability. That distinction lets the
    /// same policy tell "LM Studio is running" from "the preferred model is not installed" and select the
    /// best installed catalog entry without confusing the two states.
    static let fallbackOrder: [LLMProvider] = [.claude, .codex, .local]

    /// A Local pin's off reason when local models ARE installed but none of them fits the memory budget right
    /// now. Distinct from "local pin has no installed model", which stays the reason for an empty catalog.
    static let nothingFitsReason =
        "no installed local model fits the memory budget; free memory or adjust it on the Setup tab"

    /// Pure policy. `bundle` supplies a provider's configured bundle for the route (nil when the route has
    /// no bundle for it), `availability` supplies live provider state, and `localModels` is the measured
    /// installed-model catalog when Local has been probed. `localCapacity` carries the machine's
    /// wired/budget facts and per-model sizes so a Local substitution cannot hand LM Studio a model this
    /// Mac cannot hold. The provider map and catalog are only read for a provider the ladder reaches.
    static func resolve(pin: LLMProviderBundle,
                        bundle: (LLMProvider) -> LLMProviderBundle?,
                        availability: (LLMProvider) -> LLMProviderAvailabilityState,
                        localModels: [LMStudioModelOption]? = nil,
                        localCapacity: LLMLocalCapacityFacts? = .conservativeDefault,
                        localFailure: LLMLocalRouteFailure? = nil,
                        failedProviders: [LLMProvider: String] = [:]) -> LLMRouteResolution {
        let pinState = availability(pin.provider)

        /// Resolve the configured Local arm against the measured installed catalog, preferring the
        /// configured model only when this machine can actually hold it. When it cannot, the largest
        /// installed model that DOES fit runs instead; the substitution still carries the upgrade offer.
        /// `localCapacity` is injected (never read here) so this stays a pure policy function.
        /// `excludingModelIDs` is the single-retry seam: a model that just refused for capacity is not
        /// offered again, so the substitute is a genuinely different installed model. An empty exclusion
        /// set keeps the ordinary first-attempt behavior byte-for-byte.
        func localCandidate(
            excludingModelIDs: Set<String> = []
        ) -> (bundle: LLMProviderBundle, offer: LLMRouteUpgradeOffer?)? {
            guard let configured = bundle(.local) else { return nil }
            guard let localModels, !localModels.isEmpty else { return nil }

            func fits(_ modelID: String) -> Bool { localCapacity?.fits(modelID) ?? true }

            if !excludingModelIDs.contains(configured.modelID),
               localModels.contains(where: { $0.modelID == configured.modelID }),
               fits(configured.modelID) {
                return (configured, nil)
            }
            guard let replacement = localModels
                .filter({ !excludingModelIDs.contains($0.modelID) && fits($0.modelID) })
                .max(by: {
                    (localCapacity?.sizeBytes($0.modelID) ?? 0) < (localCapacity?.sizeBytes($1.modelID) ?? 0)
                })
            else { return nil }
            return (
                .local(replacement.modelID),
                LLMRouteUpgradeOffer(
                    preferredModelID: configured.modelID, runningModelID: replacement.modelID))
        }

        // B16: Local is an explicit privacy boundary. When it is the user's pin, an unavailable or
        // empty Local arm reports off; the general cloud fallback ladder is not consulted.
        if pin.provider == .local {
            // A capacity refusal is not terminal. The model that just ran does not fit RIGHT NOW, so step
            // down ONCE to the largest OTHER installed model that fits, still inside Local (B16: this can
            // never climb into cloud). Every other Local failure, and a retry that finds nothing, keeps
            // the existing off behavior so the raw transcript still lands.
            if pinState.canRun, case .overBudget(let failedModelID)? = localFailure,
               let refusal = failedProviders[.local],
               let retry = localCandidate(excludingModelIDs: [failedModelID]) {
                return .degraded(
                    retry.bundle, from: .local, reason: refusal, upgradeOffer: retry.offer)
            }
            guard failedProviders[.local] == nil, pinState.canRun else {
                return .off(reason: "local pin is unavailable; automatic cloud fallback is disabled - "
                    + detail(for: .local, state: pinState, localModels: localModels,
                             bundle: bundle, failedProviders: failedProviders))
            }
            guard let candidate = localCandidate() else {
                // A configured Local arm over a non-empty catalog only comes back empty-handed when nothing
                // in it fits, so say that rather than claiming nothing is installed.
                let opening = bundle(.local) != nil && !(localModels ?? []).isEmpty
                    ? nothingFitsReason : "local pin has no installed model"
                return .off(reason: opening + "; automatic cloud fallback is disabled - "
                    + detail(for: .local, state: pinState, localModels: localModels,
                             bundle: bundle, failedProviders: failedProviders))
            }
            if let offer = candidate.offer {
                return .degraded(
                    candidate.bundle, from: .local,
                    reason: "preferred local model \(pin.modelID) is not installed",
                    upgradeOffer: offer)
            }
            return .pinned(candidate.bundle)
        }

        if failedProviders[pin.provider] == nil, pinState.canRun { return .pinned(pin) }

        for candidate in fallbackOrder
            where candidate != pin.provider && failedProviders[candidate] == nil {
            guard availability(candidate).canRun else { continue }
            let replacement: LLMProviderBundle
            let offer: LLMRouteUpgradeOffer?
            if candidate == .local {
                guard let local = localCandidate() else { continue }
                replacement = local.bundle
                offer = local.offer
            } else {
                guard let configured = bundle(candidate) else { continue }
                replacement = configured
                offer = nil
            }
            let why = failedProviders[pin.provider] ?? reason(for: pinState)
            return .degraded(replacement, from: pin.provider, reason: why, upgradeOffer: offer)
        }

        // Report every provider, pin first, so the off message says which arms were considered and why each
        // one was rejected rather than a bare "unavailable".
        let ordered = [pin.provider] + fallbackOrder.filter { $0 != pin.provider }
        let detail = ordered.map { provider -> String in
            if let failure = failedProviders[provider] {
                return "\(provider.rawValue): failed during this run (\(failure))"
            }
            let state = availability(provider)
            if provider == .local, let localModels, localModels.isEmpty {
                return "local: no local models installed"
            }
            if state.canRun && bundle(provider) == nil {
                return "\(provider.rawValue): no configured bundle for this route"
            }
            return "\(provider.rawValue): \(reason(for: state))"
        }
        return .off(reason: "no provider is available - " + detail.joined(separator: "; "))
    }

    private static func detail(
        for provider: LLMProvider,
        state: LLMProviderAvailabilityState,
        localModels: [LMStudioModelOption]?,
        bundle: (LLMProvider) -> LLMProviderBundle?,
        failedProviders: [LLMProvider: String]
    ) -> String {
        if let failure = failedProviders[provider] {
            return "\(provider.rawValue): failed during this run (\(failure))"
        }
        if provider == .local, let localModels, localModels.isEmpty {
            return "local: no local models installed"
        }
        if state.canRun && bundle(provider) == nil {
            return "\(provider.rawValue): no configured bundle for this route"
        }
        return "\(provider.rawValue): \(reason(for: state))"
    }

    private static func reason(for state: LLMProviderAvailabilityState) -> String {
        switch state {
        case .available: return "available"
        case .disconnected: return "not connected"
        case .unavailable(let why): return why
        }
    }
}
