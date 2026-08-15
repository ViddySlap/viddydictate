import Foundation

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
    case degraded(LLMProviderBundle, from: LLMProvider, reason: String)
    /// No configured provider can run this route. The mode reports itself off with `reason` and the caller's
    /// ordinary raw-fallback landing takes over, so a transcript is never eaten by a missing provider.
    case off(reason: String)

    /// The bundle to execute, or nil when the route is off.
    var bundle: LLMProviderBundle? {
        switch self {
        case .pinned(let bundle): return bundle
        case .degraded(let bundle, _, _): return bundle
        case .off: return nil
        }
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
        case .degraded(let bundle, let from, let reason):
            return "provider=\(bundle.provider.rawValue) source=degraded from=\(from.rawValue) why=\(reason)"
        case .off(let reason):
            return "provider=none source=off why=\(reason)"
        }
    }
}

/// Availability-resolved routing (Public V1 locked decision 4): the explicit user pin if it is set and
/// available, else the highest-preference available provider, else the route reports itself off with a
/// specific reason.
enum LLMAvailabilityRouting {
    /// The declared fallback ladder, used ONLY when the pin cannot run. Local is last on purpose: the V1
    /// baseline is local Whisper STT plus the user's own cloud provider, and LM Studio is an optional
    /// post-V1 power path (locked decision 1), so a cloud arm is the better assumption for a user whose
    /// pin just went away. Claude before Codex is a stable declared order, not a quality judgement.
    ///
    /// Known boundary for the preflight link (W5): nothing writes `.local` availability yet, so today a
    /// Local arm always reads available and is a true last resort. Provider DETECTION has one owner and it
    /// is preflight, not this policy — resolution consumes the availability map, it does not populate it.
    static let fallbackOrder: [LLMProvider] = [.claude, .codex, .local]

    /// Pure policy. `bundle` supplies a provider's configured bundle for the route (nil when the route has
    /// no bundle for it) and `availability` supplies live provider state; neither is read for a provider
    /// the ladder never reaches.
    static func resolve(pin: LLMProviderBundle,
                        bundle: (LLMProvider) -> LLMProviderBundle?,
                        availability: (LLMProvider) -> LLMProviderAvailabilityState,
                        failedProviders: [LLMProvider: String] = [:]) -> LLMRouteResolution {
        let pinState = availability(pin.provider)
        if failedProviders[pin.provider] == nil, pinState.canRun { return .pinned(pin) }

        for candidate in fallbackOrder
            where candidate != pin.provider && failedProviders[candidate] == nil {
            guard availability(candidate).canRun, let replacement = bundle(candidate) else { continue }
            let why = failedProviders[pin.provider] ?? reason(for: pinState)
            return .degraded(replacement, from: pin.provider, reason: why)
        }

        // Report every provider, pin first, so the off message says which arms were considered and why each
        // one was rejected rather than a bare "unavailable".
        let ordered = [pin.provider] + fallbackOrder.filter { $0 != pin.provider }
        let detail = ordered.map { provider -> String in
            if let failure = failedProviders[provider] {
                return "\(provider.rawValue): failed during this run (\(failure))"
            }
            let state = availability(provider)
            if state.canRun && bundle(provider) == nil {
                return "\(provider.rawValue): no configured bundle for this route"
            }
            return "\(provider.rawValue): \(reason(for: state))"
        }
        return .off(reason: "no provider is available - " + detail.joined(separator: "; "))
    }

    private static func reason(for state: LLMProviderAvailabilityState) -> String {
        switch state {
        case .available: return "available"
        case .disconnected: return "not connected"
        case .unavailable(let why): return why
        }
    }
}
