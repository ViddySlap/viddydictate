import Foundation

/// The request ceiling one custom-mode run is allowed, per provider class.
///
/// It exists because the seam used to derive the ceiling from the PROVIDER alone: local runs always got
/// `Settings.cleanupTimeout`, a constant whose own comment scopes it to short dictation cleanup
/// ("~4.5s worst seen"). Provider is the wrong axis. A one-sentence cleanup and a whole-note handoff run
/// on the same provider and differ by more than an order of magnitude in cost, so the budget belongs to
/// the CALLER, which is the only thing that knows how big its job is.
///
/// Every budget is still a HARD ceiling. Nothing here makes a request unbounded.
///
/// `Codable` so a Sticky Skill can persist its own ceiling as `{"cloud":180,"local":90}` rather than a
/// second pair of loose scalars. Nothing else encodes it, so the conformance is purely additive.
struct CustomModeTimeoutBudget: Codable, Equatable {
    let local: TimeInterval
    let cloud: TimeInterval

    func timeout(for provider: LLMProvider) -> TimeInterval {
        provider == .local ? local : cloud
    }

    /// The historical dictation ceiling, unchanged: exactly what every custom-mode run got before this
    /// type existed. Computed rather than stored so a live `Settings.cleanupTimeout` edit still takes
    /// effect on the next run, which is how the old inline expression behaved.
    static var dictation: CustomModeTimeoutBudget {
        CustomModeTimeoutBudget(local: Settings.cleanupTimeout,
                                cloud: CloudCleanupClient.defaultTimeout)
    }
}

/// Which provider ACTUALLY executed a run. Reporting only — producing this changes no routing decision.
///
/// Content-free by construction: provider identity and the route bundle's model id are app-owned
/// configuration, and `degradedReason` comes from `LLMAvailabilityRouting`, which is handed only a pin,
/// the route's bundles, and the availability map. None of them ever sees transcript, prompt, or provider
/// response text, so this is safe to put in a toast and to write into a generated note.
struct CustomModeRunProvider: Equatable {
    let provider: LLMProvider
    let modelID: String
    /// The pin that was SKIPPED because it could not run, or nil when the user's pin is what ran.
    let degradedFrom: LLMProvider?
    /// Why the pin could not run. Non-nil only alongside `degradedFrom`.
    let degradedReason: String?

    /// nil when the route resolved `.off`: no provider executed, so there is nothing to report.
    init?(_ resolution: LLMRouteResolution) {
        switch resolution {
        case .pinned(let bundle):
            provider = bundle.provider
            modelID = bundle.modelID
            degradedFrom = nil
            degradedReason = nil
        case .degraded(let bundle, let from, let reason):
            provider = bundle.provider
            modelID = bundle.modelID
            degradedFrom = from
            degradedReason = reason
        case .off:
            return nil
        }
    }

    var isDegraded: Bool { degradedFrom != nil }

    /// Parenthetical for a toast: "Claude", or "Claude, switched from Codex" when the pin was skipped.
    var shortLabel: String {
        guard let from = degradedFrom else { return provider.displayName }
        return "\(provider.displayName), switched from \(from.displayName)"
    }
}

/// Re-resolves one sticky-skill route after a provider failure, using the same availability policy and
/// fallback order as every other route. Failed providers are excluded only for this run; the durable pin
/// and the live availability map are never rewritten here. Local is terminal, so a cloud run can descend
/// through both cloud arms and finish locally but can never climb back into the cloud after Local fails.
enum StickySkillDegradationLadder {
    typealias Resolver = ([LLMProvider: String]) -> LLMRouteResolution
    typealias Attempt = (LLMRouteResolution, TextTransformArming,
                         @escaping (CustomModeRunProvider?, CleanupClient.Result) -> Void) -> Void

    static func run(resolve: @escaping Resolver, attempt: @escaping Attempt,
                    completion: @escaping (CustomModeRunProvider?, CleanupClient.Result) -> Void) {
        func advance(failedProviders: [LLMProvider: String], arming: TextTransformArming) {
            let resolution = resolve(failedProviders)
            attempt(resolution, arming) { ran, result in
                guard let ran,
                      ran.provider != .local,
                      let failure = TextTransformClient.safeFailure(for: result)
                else {
                    completion(ran, result)
                    return
                }

                var nextFailures = failedProviders
                nextFailures[ran.provider] = failure.logToken
                let next = resolve(nextFailures)
                guard next.bundle != nil else {
                    completion(ran, result)
                    return
                }
                advance(failedProviders: nextFailures, arming: .inert)
            }
        }

        advance(failedProviders: [:], arming: .armed)
    }
}

/// Resolves a custom route through the provider-neutral transform seam. The Local adapter still owns the
/// LM Studio request, while Claude/Codex use their strict provider adapters. Every provider receives the
/// same augmented custom task and transcript wrapper and returns the shared `CleanupClient.Result`, so
/// landing/raw-fallback behavior stays identical and a failure never pastes empty.
enum CustomModeClient {
    /// The system prompt a custom-mode run actually sends: the mode's stored task prompt plus the
    /// correction glossary (Layer 2). `run` builds its request through this and the prompt
    /// workstation renders through it, so the panel cannot show a system message the run would not
    /// send — the one-owner rule that keeps the display from drifting into a confident lie.
    static func systemPrompt(taskPrompt: String) -> String {
        CorrectionDictionary.shared.augment(taskPrompt)
    }

    /// The same assembly for a stored mode.
    static func systemPrompt(for mode: CustomMode) -> String {
        systemPrompt(taskPrompt: mode.prompt)
    }

    /// Pure request builder shared by runtime and deterministic H1 route-coverage tests.
    static func makeRequest(mode: CustomMode, input: String, selected: LLMProviderBundle,
                            systemPrompt: String, timeout: TimeInterval,
                            images: [TextTransformImage] = []) -> TextTransformRequest {
        TextTransformRequest(
            route: mode.routeID, bundle: selected, sourceText: input,
            systemPrompt: systemPrompt, userMessage: CleanupClient.wrap(input), timeout: timeout,
            images: images)
    }

    /// Run a custom mode's transform on `input`, calling back with the shared `CleanupClient.Result`.
    /// Callback on an arbitrary queue; the registry hops to main before landing.
    ///
    /// This is the transform half only — nothing here lands, records history, or touches the pasteboard;
    /// the registry's land closures own all of that. That is what lets the prompt workstation's Test
    /// button (W2) run the REAL provider and model through this very function and simply not land the
    /// answer. A test passes `.inert` so the run also leaves the explicit-retry lifecycle alone.
    static func run(_ mode: CustomMode, input: String,
                    images: [TextTransformImage] = [],
                    arming: TextTransformArming = .armed,
                    budget: CustomModeTimeoutBudget = .dictation,
                    completion: @escaping (CleanupClient.Result) -> Void) {
        runReportingProvider(mode, input: input, images: images, arming: arming,
                             budget: budget) { _, result in completion(result) }
    }

    /// The same single dispatch, additionally reporting the provider that ACTUALLY executed.
    ///
    /// This exists because a route can silently resolve away from the user's pin: one unavailable
    /// provider reroutes every later attempt, and until now the only trace was a log line. Reporting
    /// the executed provider changes NO routing behavior — `resolution` is computed exactly as before
    /// and handed to the same seam; the report is derived from it, never the other way around.
    ///
    /// The report describes the FIRST dispatch. That is exact for every caller here, because an
    /// explicit retry can only run through `retryCompletion`, which no `CustomModeClient` caller
    /// passes; a caller that later adopts one must report its retry's provider from its own landing.
    static func runReportingProvider(
        _ mode: CustomMode, input: String,
        images: [TextTransformImage] = [],
        arming: TextTransformArming = .armed,
        budget: CustomModeTimeoutBudget = .dictation,
        completion: @escaping (CustomModeRunProvider?, CleanupClient.Result) -> Void
    ) {
        // The Models & Power row is authoritative; `mode.model` is only the lossless pre-A4 migration
        // fallback carried by the custom-mode descriptor. The provider-neutral task prompt remains on
        // the descriptor and is shared across providers. Which provider runs is resolved against live
        // availability at execution, never rewritten into the row.
        let resolution = Settings.modelsPower.resolveRoute(mode.routeID, fallback: mode.model)
        runResolvedReportingProvider(
            mode, input: input, images: images, arming: arming, budget: budget,
            resolution: resolution, completion: completion)
    }

    /// Sticky skills use the route policy as a failure ladder, not only as a pre-dispatch availability
    /// choice. Each failed cloud provider is excluded for this run and the route is resolved again. The
    /// final provider report remains degraded from the durable pin, which keeps both the toast and the
    /// pinned-cloud service gate honest about which provider actually completed the work.
    static func runReportingProviderWithDegradation(
        _ mode: CustomMode, input: String,
        images: [TextTransformImage] = [],
        budget: CustomModeTimeoutBudget = .dictation,
        completion: @escaping (CustomModeRunProvider?, CleanupClient.Result) -> Void
    ) {
        StickySkillDegradationLadder.run(
            resolve: { failures in
                Settings.modelsPower.resolveRoute(
                    mode.routeID, fallback: mode.model, failedProviders: failures)
            },
            attempt: { resolution, arming, done in
                runResolvedReportingProvider(
                    mode, input: input, images: images, arming: arming, budget: budget,
                    resolution: resolution, completion: done)
            },
            completion: completion)
    }

    private static func runResolvedReportingProvider(
        _ mode: CustomMode, input: String,
        images: [TextTransformImage],
        arming: TextTransformArming,
        budget: CustomModeTimeoutBudget,
        resolution: LLMRouteResolution,
        completion: @escaping (CustomModeRunProvider?, CleanupClient.Result) -> Void
    ) {
        // Captured immutably before any dispatch, so the landing closure reads it on whatever queue
        // the provider answers on without a race.
        let ran = CustomModeRunProvider(resolution)
        let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
            makeRequest(
                mode: mode, input: input, selected: bundle,
                systemPrompt: systemPrompt(for: mode),
                timeout: budget.timeout(for: bundle.provider), images: images)
        }
        TextTransformClient.transformResolved(
            resolution, route: mode.routeID, requestForBundle: requestForBundle,
            local: { req, done in
                CleanupClient.cleanup(req.sourceText, timeout: req.timeout,
                                      model: req.bundle.modelID,
                                      systemPrompt: req.systemPrompt,
                                      completion: done)
            }, arming: arming) { result in completion(ran, result) }
    }
}
