import Foundation

/// A local-model substitution in the OTHER local app (spec D2): the pinned app was not answering or
/// nothing installed in it fit, so the route ran in the other one. The message says which app was
/// skipped and why. The identifiers come from route settings and the local apps' installed catalogs,
/// never from dictated text or provider output.
///
/// This is only the honest crossing notice. The staff-pick "Install …" nudge that used to accompany a
/// same-app substitution was removed with the offer that carried it: a same-app substitution now runs
/// with no offer at all, so no crossing-less offer can exist.
struct LLMRouteUpgradeOffer: Equatable {
    let preferredModelID: String
    let runningModelID: String
    let crossing: LocalBackendCrossing

    init(preferredModelID: String, runningModelID: String, crossing: LocalBackendCrossing) {
        self.preferredModelID = preferredModelID
        self.runningModelID = runningModelID
        self.crossing = crossing
    }

    var message: String {
        let opening = crossing.cause.clause(pinned: crossing.from, sentenceStart: true)
        return "\(opening), so this ran on \(runningModelID) in \(crossing.to.displayName)."
    }

    var logToken: String {
        "preferred=\(preferredModelID) running=\(runningModelID) "
            + "crossed=\(crossing.from.rawValue)>\(crossing.to.rawValue)"
    }
}

/// One step from the pinned local app to the other one (spec D2): taken only when the pinned app is not
/// answering after its start attempt, or nothing installed in it fits. Never a step out of Local.
struct LocalBackendCrossing: Equatable {
    enum Cause: Equatable {
        /// The pinned app contributed no model to the catalog: not running (after the start attempt), not
        /// installed, or empty.
        case pinnedAppNotRunning
        /// The pinned app answered, but this model (the pin, or the model that just refused) did not fit.
        case modelDidNotFit(modelID: String)
        /// The pinned app answered, but none of its installed models fits.
        case nothingFits

        /// The half-sentence naming the pinned app. `sentenceStart` capitalizes the one clause that opens
        /// with an ordinary word; an app name or a model id is left exactly as it is spelled.
        func clause(pinned: LocalBackendID, sentenceStart: Bool = false) -> String {
            switch self {
            case .pinnedAppNotRunning: return "\(pinned.displayName) wasn't running"
            case .modelDidNotFit(let modelID):
                return "\(modelID) didn't fit in memory on \(pinned.displayName)"
            case .nothingFits:
                return "\(sentenceStart ? "Nothing" : "nothing") installed in \(pinned.displayName) fit in memory"
            }
        }
    }

    let from: LocalBackendID
    let to: LocalBackendID
    let cause: Cause

    /// The degraded reason. It names both apps, in the house's lower-case diagnostic register:
    /// "ran on LM Studio, Ollama wasn't running".
    var reason: String { "ran on \(to.displayName), \(cause.clause(pinned: from))" }
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
/// Sizes come in two shapes. `sizeBytes` is keyed by bare model id, as it always was, and means LM Studio's
/// model. `sizeBytesByRef`, when present, is keyed by `(backend, id)` and is the ONLY answer for every ref:
/// the same id on two apps is two files, so neither may borrow the other's size. Without it, an LM Studio
/// ref reads `sizeBytes` and any other app's ref is unmeasured. Full per-backend capacity is the next slice.
///
/// `residentRefs` is what the local apps hold RIGHT NOW, by `(app, id)`. Live wired memory already contains
/// every resident model, so charging a resident model's size again on top of it counts it twice: with
/// qwen3-coder-30b and gemma resident on a 64 GB Mac, neither "fit" the default budget and routing stepped
/// a working route down or off. `ModelManager.prepareCapacity` never charges a resident model (it returns
/// `.alreadyResident`), and this agrees with it: a resident model's incoming cost is 0, so it fits whenever
/// the machine already holds it. The set defaults to empty, which is the old arithmetic exactly, and an
/// unreadable resident set is empty too, so a failed read can only ever refuse more, never less.
struct LLMLocalCapacityFacts {
    let sizeBytes: (String) -> Int64?
    let wiredBytes: UInt64
    let budgetBytes: UInt64
    let sizeBytesByRef: ((LocalModelRef) -> Int64?)?
    /// Canonical refs (`ModelManager.canonical`), so Ollama's implicit `:latest` matches either spelling.
    let residentRefs: Set<LocalModelRef>

    init(sizeBytes: @escaping (String) -> Int64?, wiredBytes: UInt64, budgetBytes: UInt64,
         sizeBytesByRef: ((LocalModelRef) -> Int64?)? = nil,
         residentRefs: Set<LocalModelRef> = []) {
        self.sizeBytes = sizeBytes
        self.wiredBytes = wiredBytes
        self.budgetBytes = budgetBytes
        self.sizeBytesByRef = sizeBytesByRef
        self.residentRefs = Set(residentRefs.map(ModelManager.canonical))
    }

    /// Is `ref` loaded in ITS app right now? The same id resident in the other app is a different model.
    func isResident(_ ref: LocalModelRef) -> Bool {
        !residentRefs.isEmpty && residentRefs.contains(ModelManager.canonical(ref))
    }

    func fits(_ modelID: String) -> Bool {
        isResident(LocalModelRef(backend: .lmStudio, modelID: modelID)) || fits(size: sizeBytes(modelID))
    }

    /// The on-disk size of `ref`, never another app's model that happens to share its id.
    func sizeBytes(of ref: LocalModelRef) -> Int64? {
        if let sizeBytesByRef { return sizeBytesByRef(ref) }
        return ref.backend == .lmStudio ? sizeBytes(ref.modelID) : nil
    }

    func fits(_ ref: LocalModelRef) -> Bool {
        isResident(ref) || fits(size: sizeBytes(of: ref))
    }

    private func fits(size: Int64?) -> Bool {
        guard let size, size > 0,
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
    /// The named model's estimated incoming allocation exceeded the live wire budget. `backend` names the app
    /// it ran in when the caller knows it; nil (a caller that only has the bare id) excludes that id in EVERY
    /// local app, which is the conservative reading and is exactly the old behaviour on one app.
    case overBudget(modelID: String, backend: LocalBackendID? = nil)

    /// Whether the step-down must skip `ref`.
    func excludes(_ ref: LocalModelRef) -> Bool {
        switch self {
        case .overBudget(let modelID, let backend):
            return ref.modelID == modelID && (backend == nil || backend == ref.backend)
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

    /// A Local pin's off reason when local models ARE installed but none of them fits the memory budget right
    /// now. Distinct from "local pin has no installed model", which stays the reason for an empty catalog.
    static let nothingFitsReason =
        "no installed local model fits the memory budget; free memory or adjust it on the Setup tab"

    /// Pure policy. `bundle` supplies a provider's configured bundle for the route (nil when the route has
    /// no bundle for it), `availability` supplies live provider state, and `localModels` is the measured
    /// installed-model catalog when Local has been probed: every running local app's models, each tagged
    /// with its app. `localCapacity` carries the machine's wired/budget facts and per-model sizes so a Local
    /// substitution cannot hand a local app a model this Mac cannot hold. The provider map and catalog are
    /// only read for a provider the ladder reaches.
    ///
    /// `crossAppStaffPick` names, per app, the model a D2 crossing INTO that app should try first: the
    /// route's staff pick there, for a route still on its staff pick (`StaffPicks.crossAppStaffPick`). It is
    /// taken when installed and fitting; otherwise the crossing takes that app's largest fitting model as
    /// before. The default (nil everywhere) is the plain D2 rule, which a customized route keeps.
    static func resolve(pin: LLMProviderBundle,
                        bundle: (LLMProvider) -> LLMProviderBundle?,
                        availability: (LLMProvider) -> LLMProviderAvailabilityState,
                        localModels: [LMStudioModelOption]? = nil,
                        localCapacity: LLMLocalCapacityFacts? = .conservativeDefault,
                        localFailure: LLMLocalRouteFailure? = nil,
                        failedProviders: [LLMProvider: String] = [:],
                        crossAppStaffPick: (LocalBackendID) -> LocalModelRef? = { _ in nil })
        -> LLMRouteResolution {
        let pinState = availability(pin.provider)

        /// Resolve the configured Local arm against the measured installed catalog, preferring the
        /// configured model only when this machine can actually hold it. When it cannot, the largest
        /// installed model that DOES fit runs instead; the substitution is still reported as degraded but
        /// carries no offer (the staff-pick install nudge was removed).
        /// `localCapacity` is injected (never read here) so this stays a pure policy function.
        ///
        /// A Local pin is `(app, model)`: the configured bundle's `resolvedLocalBackend` and its id, and
        /// "installed" and "fits" match on BOTH, so the same id in two apps is never confused. The step-down
        /// looks in the pinned app first. Only when that app contributed nothing (not running after its start
        /// attempt) or nothing in it fits does it take the largest fitting model in the OTHER app (spec D2),
        /// and that step names both apps through `crossing`. It is still one step, still inside Local.
        ///
        /// `exclusion` is the single-retry seam: a model that just refused for capacity is not offered
        /// again, so the substitute is a genuinely different installed model. No exclusion keeps the
        /// ordinary first-attempt behavior byte-for-byte.
        func localCandidate(
            excluding exclusion: LLMLocalRouteFailure? = nil
        ) -> (bundle: LLMProviderBundle, offer: LLMRouteUpgradeOffer?,
              crossing: LocalBackendCrossing?, substituted: Bool)? {
            guard let configured = bundle(.local) else { return nil }
            guard let localModels, !localModels.isEmpty else { return nil }

            let pinnedRef = configured.localRef
            func excluded(_ ref: LocalModelRef) -> Bool { exclusion?.excludes(ref) ?? false }
            func fits(_ ref: LocalModelRef) -> Bool { localCapacity?.fits(ref) ?? true }
            func size(_ option: LMStudioModelOption) -> Int64 {
                localCapacity?.sizeBytes(of: option.ref) ?? 0
            }
            /// The largest runnable model in one app, in that app's catalog order on a size tie, exactly as
            /// the single-app policy always chose.
            func largestFitting(in backend: LocalBackendID) -> LMStudioModelOption? {
                localModels
                    .filter { $0.backend == backend && !excluded($0.ref) && fits($0.ref) }
                    .max(by: { size($0) < size($1) })
            }

            if !excluded(pinnedRef),
               localModels.contains(where: { $0.ref == pinnedRef }),
               fits(pinnedRef) {
                return (configured, nil, nil, false)
            }
            if let replacement = largestFitting(in: pinnedRef.backend) {
                return (.local(ref: replacement.ref), nil, nil, true)
            }

            // D2: the pinned app cannot run this route. Say why in terms of that app, then take the largest
            // fitting model in the other one.
            let pinnedAppAnswered = localModels.contains { $0.backend == pinnedRef.backend }
            let cause: LocalBackendCrossing.Cause
            if !pinnedAppAnswered {
                cause = .pinnedAppNotRunning
            } else if case .overBudget(let refusedID, _)? = exclusion {
                cause = .modelDidNotFit(modelID: refusedID)
            } else if localModels.contains(where: { $0.ref == pinnedRef }) {
                cause = .modelDidNotFit(modelID: pinnedRef.modelID)
            } else {
                cause = .nothingFits
            }
            /// The route's staff pick in `other` when it is installed there and runs, else nil.
            func staffPick(in other: LocalBackendID) -> LMStudioModelOption? {
                guard let pick = crossAppStaffPick(other), pick.backend == other,
                      !excluded(pick), fits(pick) else { return nil }
                return localModels.first { $0.ref == pick }
            }
            for other in LocalBackendID.allCases where other != pinnedRef.backend {
                guard let replacement = staffPick(in: other) ?? largestFitting(in: other) else { continue }
                let crossing = LocalBackendCrossing(from: pinnedRef.backend, to: other, cause: cause)
                return (
                    .local(ref: replacement.ref),
                    LLMRouteUpgradeOffer(
                        preferredModelID: configured.modelID, runningModelID: replacement.modelID,
                        crossing: crossing),
                    crossing, true)
            }
            return nil
        }

        // B16: Local is an explicit privacy boundary. When it is the user's pin, an unavailable or
        // empty Local arm reports off; the general cloud fallback ladder is not consulted.
        if pin.provider == .local {
            // A capacity refusal is not terminal. The model that just ran does not fit RIGHT NOW, so step
            // down ONCE to the largest OTHER installed model that fits, still inside Local (B16: this can
            // never climb into cloud; the other local app is still Local). Every other Local failure, and a
            // retry that finds nothing, keeps the existing off behavior so the raw transcript still lands.
            if pinState.canRun, let failure = localFailure,
               let refusal = failedProviders[.local],
               let retry = localCandidate(excluding: failure) {
                return .degraded(
                    retry.bundle, from: .local, reason: retry.crossing?.reason ?? refusal,
                    upgradeOffer: retry.offer)
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
            if candidate.substituted {
                return .degraded(
                    candidate.bundle, from: .local,
                    reason: candidate.crossing?.reason
                        ?? "preferred local model \(pin.modelID) is not installed",
                    upgradeOffer: candidate.offer)
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
