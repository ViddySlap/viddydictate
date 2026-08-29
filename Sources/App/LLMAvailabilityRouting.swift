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

    /// Pure policy. `bundle` supplies a provider's configured bundle for the route (nil when the route has
    /// no bundle for it), `availability` supplies live provider state, and `localModels` is the measured
    /// installed-model catalog when Local has been probed. The provider map and catalog are only read for
    /// a provider the ladder reaches.
    static func resolve(pin: LLMProviderBundle,
                        bundle: (LLMProvider) -> LLMProviderBundle?,
                        availability: (LLMProvider) -> LLMProviderAvailabilityState,
                        localModels: [LMStudioModelOption]? = nil,
                        failedProviders: [LLMProvider: String] = [:]) -> LLMRouteResolution {
        let pinState = availability(pin.provider)

        /// Resolve the configured Local arm against the measured installed catalog. The provider's
        /// catalog order is intentionally preserved: LM Studio is the authority for its own model order,
        /// and a deterministic first entry is safer than inventing a size/quality heuristic here.
        func localCandidate() -> (bundle: LLMProviderBundle, offer: LLMRouteUpgradeOffer?)? {
            guard let configured = bundle(.local) else { return nil }
            guard let localModels else { return (configured, nil) }
            guard !localModels.isEmpty else { return nil }
            if localModels.contains(where: { $0.modelID == configured.modelID }) {
                return (configured, nil)
            }
            guard let replacement = localModels.first else { return nil }
            return (
                .local(replacement.modelID),
                LLMRouteUpgradeOffer(
                    preferredModelID: configured.modelID, runningModelID: replacement.modelID))
        }

        // B16: Local is an explicit privacy boundary. When it is the user's pin, an unavailable or
        // empty Local arm reports off; the general cloud fallback ladder is not consulted.
        if pin.provider == .local {
            guard failedProviders[.local] == nil, pinState.canRun else {
                return .off(reason: "local pin is unavailable; automatic cloud fallback is disabled - "
                    + detail(for: .local, state: pinState, localModels: localModels,
                             bundle: bundle, failedProviders: failedProviders))
            }
            guard let candidate = localCandidate() else {
                return .off(reason: "local pin has no installed model; automatic cloud fallback is disabled - "
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
