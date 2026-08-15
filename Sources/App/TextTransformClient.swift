import Foundation

/// One app-owned image supplied to a provider in the same transform call as the user message.
/// Callers supply bytes, never arbitrary provider-visible paths.
struct TextTransformImage: Equatable {
    let data: Data
    let mediaType: String
    let label: String
}

/// The one provider-neutral contract for ViddyDictate's single-turn text transforms. Call sites keep
/// owning their route-specific Local request shape (cleanup, email, search synthesis), while this seam
/// owns the provider decision and guarantees that exactly one selected provider is invoked.
///
/// The request deliberately carries the already-effective system prompt and provider envelope. Neither
/// value is logged here. Claude sends them through its private stdin/prompt-file transport; Codex
/// consumes the same contract through its dedicated-home containment runner without changing
/// landing or raw-fallback code.
struct TextTransformRequest: Equatable {
    let route: LLMRouteID
    let bundle: LLMProviderBundle
    let sourceText: String
    let systemPrompt: String
    let userMessage: String
    let timeout: TimeInterval
    let images: [TextTransformImage]

    init(route: LLMRouteID, bundle: LLMProviderBundle, sourceText: String,
         systemPrompt: String, userMessage: String, timeout: TimeInterval,
         images: [TextTransformImage] = []) {
        self.route = route
        self.bundle = bundle
        self.sourceText = sourceText
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.timeout = timeout
        self.images = images
    }

    func explicitlyRetrying(with bundle: LLMProviderBundle,
                            timeout: TimeInterval) -> TextTransformRequest {
        TextTransformRequest(route: route, bundle: bundle, sourceText: sourceText,
                             systemPrompt: systemPrompt, userMessage: userMessage, timeout: timeout,
                             images: images)
    }
}

/// A failure-only descriptor for a user-authorized retry. It intentionally contains no candidate,
/// fallback order, or "best available" provider: callers must supply the exact provider bundle and
/// timeout through `request(explicitlyUsing:timeout:)` before another transform can run.
struct TextTransformRetryDescriptor: Equatable {
    /// Fixed, content-safe categories only. Provider stderr / response text is deliberately discarded:
    /// it may echo user input and is not needed to decide or present an explicit retry.
    enum Failure: String, Equatable {
        case unavailable
        case timedOut
        case badOutput

        var logToken: String { rawValue }

        var userMessage: String {
            switch self {
            case .unavailable: return "Selected provider is unavailable"
            case .timedOut: return "Selected provider timed out"
            case .badOutput: return "Selected provider returned unusable output"
            }
        }

        /// An unavailable provider is not an eligible same-provider retry until its availability changes.
        /// Timeouts and rejected output still came from a reachable provider, so an explicit same-provider
        /// retry remains a valid user choice.
        var permitsFailedProvider: Bool { self != .unavailable }
    }

    let failedRequest: TextTransformRequest
    let failure: Failure

    var route: LLMRouteID { failedRequest.route }
    var failedProvider: LLMProvider { failedRequest.bundle.provider }
    var failedBundle: LLMProviderBundle { failedRequest.bundle }

    func request(explicitlyUsing bundle: LLMProviderBundle,
                 timeout: TimeInterval) -> TextTransformRequest {
        failedRequest.explicitlyRetrying(with: bundle, timeout: timeout)
    }
}

/// Process-memory-only owner for the one failed transform that may be retried. The pending value contains
/// the provider-neutral request inside `descriptor` plus the call site's captured landing closure inside
/// `execute`; it is never encoded, logged, or posted in a notification payload. A retry is consumed before
/// it starts and receives a single execution lease. Any app/settings/provider invalidation revokes both the
/// pending value and an in-flight lease, so a late provider result cannot land into stale state.
final class TextTransformRetryCenter {
    static let didChange = Notification.Name("VDTextTransformRetryDidChange")
    static let shared = TextTransformRetryCenter(observeAppState: true)

    struct Summary: Equatable {
        let id: UUID
        let route: LLMRouteID
        let failedProvider: LLMProvider
        let failure: TextTransformRetryDescriptor.Failure

        var safeFailureText: String { failure.userMessage }
    }

    typealias Executor = (LLMProviderBundle, UUID) -> Void

    private struct Pending {
        let summary: Summary
        let execute: Executor
    }

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var pending: Pending?
    private var activeExecutionID: UUID?
    private var epoch: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init(observeAppState: Bool = false, notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        guard observeAppState else { return }
        let invalidate: (Notification) -> Void = { [weak self] _ in self?.invalidate() }
        observers.append(notificationCenter.addObserver(
            forName: ModelsPowerSettingsStore.didChange, object: nil, queue: nil, using: invalidate))
        observers.append(notificationCenter.addObserver(
            forName: CustomModeStore.didChange, object: nil, queue: nil, using: invalidate))
        observers.append(notificationCenter.addObserver(
            forName: CorrectionDictionary.didChange, object: nil, queue: nil, using: invalidate))
        observers.append(notificationCenter.addObserver(
            forName: Settings.didChange, object: nil, queue: nil, using: invalidate))
        observers.append(notificationCenter.addObserver(
            forName: Settings.dictationActive, object: nil, queue: nil) { [weak self] note in
                if (note.object as? NSNumber)?.boolValue == true { self?.invalidate() }
            })
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    var summary: Summary? { lock.withLock { pending?.summary } }

    /// Resolve confirmation choices without mutating the saved route. Only configured, currently available
    /// bundles are offered; the provider that just reported `.unavailable` is excluded until state changes.
    static func eligibleProviderBundles(for summary: Summary,
                                        settings: ModelsPowerSettingsStore) -> [(LLMProvider, LLMProviderBundle)] {
        LLMProvider.allCases.compactMap { provider in
            guard summary.failure.permitsFailedProvider || provider != summary.failedProvider,
                  settings.availabilityState(for: provider).canRun,
                  let bundle = settings.rememberedBundle(for: provider, route: summary.route)
            else { return nil }
            return (provider, bundle)
        }
    }

    /// A brand-new user action supersedes any prior failure and revokes a retry already in flight.
    /// The returned epoch pins a later failure capture to this exact request lifetime.
    @discardableResult
    func beginNewRequest() -> UInt64 {
        let next = lock.withLock { () -> UInt64 in
            epoch &+= 1
            pending = nil
            activeExecutionID = nil
            return epoch
        }
        notifyChange()
        return next
    }

    func invalidate() {
        let changed = lock.withLock { () -> Bool in
            epoch &+= 1
            let changed = pending != nil || activeExecutionID != nil
            pending = nil
            activeExecutionID = nil
            return changed
        }
        if changed { notifyChange() }
    }

    /// Capture one failed request only if no newer app/request state superseded it.
    func capture(_ descriptor: TextTransformRetryDescriptor, expectedEpoch: UInt64,
                 execute: @escaping Executor) {
        let captured = lock.withLock { () -> Bool in
            guard epoch == expectedEpoch, activeExecutionID == nil else { return false }
            pending = Pending(
                summary: Summary(id: UUID(), route: descriptor.route,
                                 failedProvider: descriptor.failedProvider,
                                 failure: descriptor.failure),
                execute: execute)
            return true
        }
        if captured { notifyChange() }
    }

    /// Consume the exact pending generation and start exactly the explicitly supplied provider bundle.
    /// There is no provider list or fallback loop here. Returns false for a stale alert/button.
    @discardableResult
    func retry(summaryID: UUID, explicitlyUsing bundle: LLMProviderBundle) -> Bool {
        let start: (Executor, UUID)? = lock.withLock {
            guard let pending = pending, pending.summary.id == summaryID else { return nil }
            let executionID = UUID()
            self.pending = nil
            activeExecutionID = executionID
            return (pending.execute, executionID)
        }
        guard let (execute, executionID) = start else { return false }
        notifyChange()
        execute(bundle, executionID)
        return true
    }

    /// Accept one terminal provider result only while its lease remains current. The returned epoch is
    /// used to re-arm a failed explicit retry after its content-safe landing has run.
    func acceptResult(executionID: UUID) -> UInt64? {
        lock.withLock {
            guard activeExecutionID == executionID else { return nil }
            activeExecutionID = nil
            return epoch
        }
    }

    private func notifyChange() {
        let post = { [notificationCenter] in
            notificationCenter.post(name: Self.didChange, object: self)
        }
        if Thread.isMainThread { post() }
        else { DispatchQueue.main.async(execute: post) }
    }
}

/// Whether a dispatch participates in the explicit-retry lifecycle.
///
/// Every real transform is `.armed`: it supersedes any earlier failure (a new user action means the old
/// Retry button is stale) and can arm a retry of its own. `.inert` is for a run the user did not deliver
/// — today, the prompt workstation's Test button (item W2). A test must leave the delivery path exactly
/// as it found it, and `beginNewRequest()` is the one mutation the shared seam would otherwise make on
/// its behalf: it would silently clear a pending Retry the user was about to press. An inert dispatch
/// touches the retry center not at all.
enum TextTransformArming {
    case armed
    case inert

    var armsRetry: Bool { self == .armed }
}

enum TextTransformClient {
    typealias Completion = (CleanupClient.Result) -> Void
    typealias AsyncAdapter = (TextTransformRequest, @escaping Completion) -> Void
    typealias SyncAdapter = (TextTransformRequest) -> CleanupClient.Result
    typealias RetryRequestBuilder = (LLMProviderBundle) -> TextTransformRequest
    typealias ResultMap = (CleanupClient.Result) -> CleanupClient.Result

    /// Dispatch exactly once to the selected provider. There is deliberately no fallback loop and no
    /// implicit retry. Existing call sites keep receiving the exact `CleanupClient.Result` type their
    /// landing/fallback closures already consume.
    static func transform(_ request: TextTransformRequest,
                          local: @escaping AsyncAdapter,
                          claude: @escaping AsyncAdapter = claudeTransform,
                          codex: @escaping AsyncAdapter = codexTransform,
                          resultMap: @escaping ResultMap = { $0 },
                          arming: TextTransformArming = .armed,
                          retryRequest: RetryRequestBuilder? = nil,
                          retryCompletion: Completion? = nil,
                          completion: @escaping Completion) {
        let center = TextTransformRetryCenter.shared
        let requestEpoch = arming.armsRetry ? center.beginNewRequest() : 0
        dispatch(request, local: local, claude: claude, codex: codex) { rawResult in
            let result = resultMap(rawResult)
            completion(result)
            guard arming.armsRetry, let retryLanding = retryCompletion else { return }
            let rebuild = retryRequest ?? { bundle in
                request.explicitlyRetrying(with: bundle, timeout: request.timeout)
            }
            armAsyncRetry(for: request, after: result, expectedEpoch: requestEpoch,
                          local: local, claude: claude, codex: codex,
                          resultMap: resultMap, retryRequest: rebuild,
                          retryLanding: retryLanding)
        }
    }

    /// The one owner of availability-resolved dispatch (locked decision 4). The caller supplies its route
    /// resolution and its provider-parameterized request builder, so the request is built for the provider
    /// that will actually run — prompt overlay, envelope, and timeout all follow the resolved provider
    /// instead of the pin.
    ///
    /// When the route is off, no adapter is invoked and no retry is armed (there is no available provider to
    /// retry with). The off reason is returned through the ordinary `.unavailable` Result, which leaves the
    /// existing raw-fallback landing exactly as it is: the transcript still lands.
    static func transformResolved(_ resolution: LLMRouteResolution,
                                  route: LLMRouteID,
                                  requestForBundle: @escaping RetryRequestBuilder,
                                  local: @escaping AsyncAdapter,
                                  claude: @escaping AsyncAdapter = claudeTransform,
                                  codex: @escaping AsyncAdapter = codexTransform,
                                  resultMap: @escaping ResultMap = { $0 },
                                  arming: TextTransformArming = .armed,
                                  retryCompletion: Completion? = nil,
                                  completion: @escaping Completion) {
        switch resolution {
        case .off(let reason):
            completion(resultMap(offDispatch(reason: reason, resolution: resolution, route: route,
                                             arming: arming)))
        case .pinned(let bundle), .degraded(let bundle, _, _):
            logResolution(resolution, route: route)
            transform(requestForBundle(bundle), local: local, claude: claude, codex: codex,
                      resultMap: resultMap, arming: arming, retryRequest: requestForBundle,
                      retryCompletion: retryCompletion, completion: completion)
        }
    }

    /// Synchronous twin for the already-backgrounded search path.
    static func transformSyncResolved(_ resolution: LLMRouteResolution,
                                      route: LLMRouteID,
                                      requestForBundle: @escaping RetryRequestBuilder,
                                      local: @escaping SyncAdapter,
                                      claude: @escaping SyncAdapter = claudeTransformSync,
                                      codex: @escaping SyncAdapter = codexTransformSync,
                                      resultMap: @escaping ResultMap = { $0 },
                                      retryCompletion: Completion? = nil) -> CleanupClient.Result {
        switch resolution {
        case .off(let reason):
            return resultMap(offDispatch(reason: reason, resolution: resolution, route: route))
        case .pinned(let bundle), .degraded(let bundle, _, _):
            logResolution(resolution, route: route)
            return transformSync(requestForBundle(bundle), local: local, claude: claude, codex: codex,
                                 resultMap: resultMap, retryRequest: requestForBundle,
                                 retryCompletion: retryCompletion)
        }
    }

    /// Early-out for a pipeline that would otherwise do expensive retrieval work before discovering that
    /// nothing can run its transform. nil whenever the route resolves to a provider.
    static func offResult(_ resolution: LLMRouteResolution, route: LLMRouteID) -> CleanupClient.Result? {
        guard case .off(let reason) = resolution else { return nil }
        return offDispatch(reason: reason, resolution: resolution, route: route)
    }

    /// The one place a route's off state becomes a Result. No adapter runs and no retry is armed — there
    /// is no available provider to retry with — but an ARMED dispatch still advances the retry center,
    /// because a new user action supersedes any earlier failure exactly as it does on the dispatching
    /// path. An inert dispatch does not: a route being off is the commonest way a test finishes, and a
    /// test that wiped the user's pending Retry on its way to "provider unavailable" would be the exact
    /// leak this arming exists to close.
    private static func offDispatch(reason: String, resolution: LLMRouteResolution,
                                    route: LLMRouteID,
                                    arming: TextTransformArming = .armed) -> CleanupClient.Result {
        logResolution(resolution, route: route)
        if arming.armsRetry { TextTransformRetryCenter.shared.beginNewRequest() }
        return .unavailable(reason)
    }

    private static func logResolution(_ resolution: LLMRouteResolution, route: LLMRouteID) {
        Log.write("route \(route.rawValue) resolved \(resolution.logToken)")
    }

    private static func selectedAdapter<T>(for provider: LLMProvider,
                                           local: T,
                                           claude: T,
                                           codex: T) -> T {
        switch provider {
        case .local:
            return local
        case .claude:
            return claude
        case .codex:
            return codex
        }
    }

    private static func dispatch(_ request: TextTransformRequest,
                                 local: @escaping AsyncAdapter,
                                 claude: @escaping AsyncAdapter,
                                 codex: @escaping AsyncAdapter,
                                 completion: @escaping Completion) {
        let adapter = selectedAdapter(for: request.bundle.provider,
                                      local: local, claude: claude, codex: codex)
        adapter(request, completion)
    }

    /// Synchronous twin for the already-backgrounded search/bakeoff-style paths.
    static func transformSync(_ request: TextTransformRequest,
                              local: @escaping SyncAdapter,
                              claude: @escaping SyncAdapter = claudeTransformSync,
                              codex: @escaping SyncAdapter = codexTransformSync,
                              resultMap: @escaping ResultMap = { $0 },
                              retryRequest: RetryRequestBuilder? = nil,
                              retryCompletion: Completion? = nil) -> CleanupClient.Result {
        func asynchronous(_ adapter: @escaping SyncAdapter) -> AsyncAdapter {
            { request, completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    completion(adapter(request))
                }
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: CleanupClient.Result = .unavailable("no result")
        transform(request,
                  local: asynchronous(local),
                  claude: asynchronous(claude),
                  codex: asynchronous(codex),
                  resultMap: resultMap,
                  retryRequest: retryRequest,
                  retryCompletion: retryCompletion) {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Expose retry metadata only after a failure. Producing the descriptor never starts work; a second
    /// call still requires an explicitly chosen provider bundle and timeout.
    static func retryDescriptor(for request: TextTransformRequest,
                                after result: CleanupClient.Result) -> TextTransformRetryDescriptor? {
        guard let failure = safeFailure(for: result) else { return nil }
        return TextTransformRetryDescriptor(failedRequest: request, failure: failure)
    }

    static func safeFailure(for result: CleanupClient.Result) -> TextTransformRetryDescriptor.Failure? {
        switch result {
        case .ok: return nil
        case .unavailable: return .unavailable
        case .timedOut: return .timedOut
        case .badOutput: return .badOutput
        }
    }

    private static func armAsyncRetry(for request: TextTransformRequest,
                                      after result: CleanupClient.Result,
                                      expectedEpoch: UInt64,
                                      local: @escaping AsyncAdapter,
                                      claude: @escaping AsyncAdapter,
                                      codex: @escaping AsyncAdapter,
                                      resultMap: @escaping ResultMap,
                                      retryRequest: @escaping RetryRequestBuilder,
                                      retryLanding: @escaping Completion) {
        guard let descriptor = retryDescriptor(for: request, after: result) else { return }
        let center = TextTransformRetryCenter.shared
        DispatchQueue.main.async {
            center.capture(descriptor, expectedEpoch: expectedEpoch) { bundle, executionID in
                let retried = retryRequest(bundle)
                dispatch(retried, local: local, claude: claude, codex: codex) { rawRetryResult in
                    let retryResult = resultMap(rawRetryResult)
                    guard let retryEpoch = center.acceptResult(executionID: executionID) else { return }
                    retryLanding(retryResult)
                    armAsyncRetry(for: retried, after: retryResult, expectedEpoch: retryEpoch,
                                  local: local, claude: claude, codex: codex,
                                  resultMap: resultMap, retryRequest: retryRequest,
                                  retryLanding: retryLanding)
                }
            }
        }
    }

    private static func claudeTransform(_ request: TextTransformRequest,
                                        completion: @escaping Completion) {
        CloudCleanupClient.transform(systemPrompt: request.systemPrompt,
                                     userMessage: request.userMessage,
                                     images: request.images,
                                     model: request.bundle.modelID,
                                     effort: request.bundle.effort,
                                     timeout: request.timeout,
                                     completion: completion)
    }

    private static func claudeTransformSync(_ request: TextTransformRequest) -> CleanupClient.Result {
        CloudCleanupClient.spawnSync(systemPrompt: request.systemPrompt,
                                     userMessage: request.userMessage,
                                     images: request.images,
                                     model: request.bundle.modelID,
                                     effort: request.bundle.effort,
                                     timeout: request.timeout)
    }

    private static func codexTransform(_ request: TextTransformRequest,
                                       completion: @escaping Completion) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(codexTransformSync(request))
        }
    }

    private static func codexTransformSync(_ request: TextTransformRequest) -> CleanupClient.Result {
        guard !request.bundle.modelID.isEmpty else {
            return .unavailable("Codex model ID is required")
        }
        guard let effort = request.bundle.effort, !effort.isEmpty else {
            // Choosing a fallback effort here would silently replace the explicit route bundle.
            return .unavailable("Codex effort is required")
        }
        let envelope = request.bundle.envelopeVersion ?? CodexIsolationFoundation.envelopeVersion
        let outcome = CodexProviderRuntime.execute(CodexRuntimeRequest(
            model: request.bundle.modelID,
            effort: effort,
            developerInstructions: request.systemPrompt,
            userMessage: request.userMessage,
            envelopeVersion: envelope,
            timeout: request.timeout,
            images: request.images.map {
                CodexRuntimeImage(data: $0.data, mediaType: $0.mediaType, label: $0.label)
            }))
        return CodexTransformResult.resolve(outcome, request: request)
    }
}
