import Foundation
import Darwin

/// Pure/scratch-only A2 coverage for the provider-neutral dispatch seam and Claude process transport.
/// No installed provider, credentials, preferences, live app, or user data is consulted.
enum TextTransformSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate provider-neutral transform — selftest ===")
        let reporter = SelfTestReporter()
        func okText(_ result: CleanupClient.Result) -> String? {
            if case .ok(let text) = result { return text }
            return nil
        }
        func isUnavailable(_ result: CleanupClient.Result) -> Bool {
            if case .unavailable = result { return true }
            return false
        }

        checkTranscriptContentGate(reporter.record)
        checkLocalChatResponseClassifier(reporter.record)
        checkCodexOutcomeMapping(reporter.record, okText: okText, isUnavailable: isUnavailable)
        checkDispatchAndRetry(reporter.record, okText: okText, isUnavailable: isUnavailable)
        checkSyncRetryArming(reporter.record, okText: okText, isUnavailable: isUnavailable)
        checkInertArming(reporter.record, okText: okText, isUnavailable: isUnavailable)
        checkPendingRetryOwnership(reporter.record)
        checkCapturedTargetRetryLanding(reporter.record)
        checkCustomAndSearchRequestRoutes(reporter.record)
        checkClaudePrivateTransport(reporter.record, okText: okText)
        checkTransientExitHelperCleanup(reporter.record)
        checkProcessGroupTimeout(reporter.record)
        checkTimeoutPathTeardownEvidence(reporter.record, okText: okText)
        checkLogPrivacy(reporter.record)

        print("\n=== RESULT ===")
        print(reporter.passed ? "TEXT TRANSFORM GREEN" : "TEXT TRANSFORM FAILED")
        return reporter.passed
    }

    private static func checkTranscriptContentGate(_ check: (String, Bool) -> Void) {
        print("--- transcript letter-or-digit gate ---")
        check("blank transcript is nothing heard",
              !CleanupLogic.transcriptHasLettersOrDigits(" \t\n"))
        check("ASCII punctuation-only transcript is nothing heard",
              !CleanupLogic.transcriptHasLettersOrDigits(" !?.,;:'\"- "))
        check("typographic punctuation-only transcript is nothing heard",
              !CleanupLogic.transcriptHasLettersOrDigits(
                " \u{2014} \u{2026} \u{201C}\u{201D} \u{2018}\u{2019} "))
        check("CJK punctuation-only transcript is nothing heard",
              !CleanupLogic.transcriptHasLettersOrDigits(
                " \u{3002}\u{3001}\u{FF01}\u{FF1F} "))
        check("Latin letters remain real content",
              CleanupLogic.transcriptHasLettersOrDigits(" Hello! "))
        check("ASCII digits remain real content",
              CleanupLogic.transcriptHasLettersOrDigits(" ... 7 ... "))
        check("non-Latin letters remain real content",
              CleanupLogic.transcriptHasLettersOrDigits(
                " \u{6F22} \u{0434} \u{0628} "))
        check("non-ASCII digits remain real content",
              CleanupLogic.transcriptHasLettersOrDigits(" \u{0667} "))
    }

    private static func checkLocalChatResponseClassifier(_ check: (String, Bool) -> Void) {
        print("--- local chat response classifier ---")
        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        func response(_ statusCode: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        }
        func content(_ classification: CleanupClient.ChatResponseClassification) -> String? {
            if case .content(let value) = classification { return value }
            return nil
        }
        func unavailable(_ classification: CleanupClient.ChatResponseClassification) -> String? {
            if case .failure(.unavailable(let reason)) = classification { return reason }
            return nil
        }
        func isTimedOut(_ classification: CleanupClient.ChatResponseClassification) -> Bool {
            if case .failure(.timedOut) = classification { return true }
            return false
        }
        func toolMessage(_ classification: CleanupClient.ToolCapableChatResponseClassification)
            -> (content: String, calls: [[String: Any]])? {
            if case .message(let content, let calls) = classification { return (content, calls) }
            return nil
        }

        let validData = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "synthetic content"]]],
        ])
        let valid = CleanupClient.classifyChatResponse(
            data: validData, response: response(200), error: nil,
            logPrefix: "selftest", elapsed: 0.01)
        let non2xx = CleanupClient.classifyChatResponse(
            data: validData, response: response(503), error: nil,
            logPrefix: "selftest", elapsed: 0.01)
        let timedOut = CleanupClient.classifyChatResponse(
            data: nil, response: nil,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            logPrefix: "selftest", elapsed: 1.25)
        let badJSON = CleanupClient.classifyChatResponse(
            data: Data("not json".utf8), response: response(200), error: nil,
            logPrefix: "selftest", elapsed: 0.01)
        let toolOnlyData = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": [
                "content": NSNull(),
                "tool_calls": [["id": "call_1", "function": ["name": "web_search"]]],
            ]]],
        ])
        let toolOnly = CleanupClient.classifyToolCapableChatResponse(
            data: toolOnlyData, response: response(200), error: nil,
            logPrefix: "selftest", elapsed: 0.01)
        let contentOnly = CleanupClient.classifyToolCapableChatResponse(
            data: validData, response: response(200), error: nil,
            logPrefix: "selftest", elapsed: 0.01)

        check("2xx chat response extracts content without network access",
              content(valid) == "synthetic content")
        check("non-2xx chat response preserves the HTTP failure classification",
              unavailable(non2xx) == "HTTP 503")
        check("NSURLErrorTimedOut preserves the timed-out classification", isTimedOut(timedOut))
        check("undecodable chat response preserves the bad-shape classification",
              unavailable(badJSON) == "bad response shape")
        check("2xx tool response accepts null content and extracts tool calls",
              toolMessage(toolOnly)?.content == ""
                && (toolMessage(toolOnly)?.calls.first?["id"] as? String) == "call_1")
        check("2xx content response remains valid when tool calls are absent",
              toolMessage(contentOnly)?.content == "synthetic content"
                && toolMessage(contentOnly)?.calls.isEmpty == true)
    }

    private static func checkCodexOutcomeMapping(
        _ check: (String, Bool) -> Void,
        okText: (CleanupClient.Result) -> String?,
        isUnavailable: (CleanupClient.Result) -> Bool
    ) {
        print("--- Codex outcome mapping and availability ---")
        let settings = Settings.modelsPower
        let priorAvailability = settings.availabilityState(for: .codex)
        defer { settings.setAvailabilityState(priorAvailability, for: .codex) }
        let request = TextTransformRequest(
            route: .cleanupL2, bundle: .codex("synthetic-codex", effort: "medium"),
            sourceText: "source", systemPrompt: "system", userMessage: "synthetic input",
            timeout: 5)

        settings.setAvailabilityState(.disconnected, for: .codex)
        let success = CodexTransformResult.resolve(.success(CodexRuntimeSuccess(
            result: " synthetic output ", profileHash: String(repeating: "a", count: 64),
            stdoutBytes: 21, stderrBytes: 0, elapsed: 0.25)), request: request)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("Codex success maps output and marks the provider available",
              okText(success) == "synthetic output"
                && settings.availabilityState(for: .codex) == .available)

        settings.setAvailabilityState(.available, for: .codex)
        let disconnected = CodexTransformResult.resolve(.disconnected, request: request)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("Codex disconnected failure maps result and availability together",
              isUnavailable(disconnected)
                && settings.availabilityState(for: .codex) == .disconnected)

        let codexFlag = "--synthetic-codex-\(UUID().uuidString)"
        let codexPrivate = "PRIVATE_CODEX_INPUT_\(UUID().uuidString)"
        let codexStderr = "error: unexpected argument '\(codexFlag)' for \(codexPrivate)"
        let processFailure = CodexProviderRuntime.classifyCapturedForTest(
            status: 9, stdout: Data(), stderr: Data(codexStderr.utf8),
            sensitiveValues: [codexPrivate])
        let failed = CodexTransformResult.resolve(processFailure, request: request)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        Log.flushForTest()
        let processLog = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("Codex nonzero exit keeps unavailable routing and logs bounded safe stderr",
              isUnavailable(failed)
                && processLog.contains("classification=unavailable")
                && processLog.contains(codexFlag)
                && !processLog.contains(codexPrivate))
    }

    private static func checkPendingRetryOwnership(_ check: (String, Bool) -> Void) {
        print("--- functional explicit retry ownership + content safety ---")
        let canary = "SYNTHETIC_PRIVATE_RETRY_\(UUID().uuidString)"
        let failed = TextTransformRequest(
            route: .promptPrep, bundle: .local("failed-local"), sourceText: canary,
            systemPrompt: "system-\(canary)", userMessage: "wrapped-\(canary)", timeout: 5)
        let descriptor = TextTransformClient.retryDescriptor(
            for: failed, after: .unavailable("provider echoed \(canary)"))!
        check("retry descriptor drops provider detail into a fixed content-safe classification",
              descriptor.failure == .unavailable
                && !descriptor.failure.userMessage.contains(canary)
                && !descriptor.failure.logToken.contains(canary))

        let center = TextTransformRetryCenter()
        let epoch = center.beginNewRequest()
        var executedProviders: [LLMProvider] = []
        var restoredLanding: String?
        center.capture(descriptor, expectedEpoch: epoch) { bundle, executionID in
            executedProviders.append(bundle.provider)
            if center.acceptResult(executionID: executionID) != nil {
                // Models the immutable target/note closure captured by the production call site.
                restoredLanding = "captured-note-range"
            }
        }
        let pending = center.summary
        check("one pending owner exposes route/provider/classification but no request text",
              pending?.route == .promptPrep && pending?.failedProvider == .local
                && pending?.safeFailureText == "Selected provider is unavailable"
                && !String(describing: pending).contains(canary))
        let settingsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-retry-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: settingsURL) }
        let settings = ModelsPowerSettingsStore(url: settingsURL, legacy: .empty)
        let unavailableChoices = pending.map {
            TextTransformRetryCenter.eligibleProviderBundles(for: $0, settings: settings).map { $0.0 }
        } ?? []
        let timeoutSummary = TextTransformRetryCenter.Summary(
            id: UUID(), route: .promptPrep, failedProvider: .local, failure: .timedOut)
        let timeoutChoices = TextTransformRetryCenter.eligibleProviderBundles(
            for: timeoutSummary, settings: settings).map { $0.0 }
        check("confirmation offers only configured available providers and excludes the failed unavailable arm",
              unavailableChoices == [.claude] && timeoutChoices == [.local, .claude])
        let chosen = LLMProviderBundle.claude("explicit-claude", effort: "medium")
        let started = pending.map { center.retry(summaryID: $0.id, explicitlyUsing: chosen) } ?? false
        check("explicit retry consumes pending state and runs exactly the confirmed provider once",
              started && center.summary == nil && executedProviders == [.claude])
        check("captured landing state is restored only after the leased result is accepted",
              restoredLanding == "captured-note-range")
        check("consumed retry cannot be replayed and has no fallback attempt",
              pending.map { !center.retry(summaryID: $0.id, explicitlyUsing: .codex("other", effort: "low")) } ?? false
                && executedProviders == [.claude])

        let invalidatedCenter = TextTransformRetryCenter()
        let invalidatedEpoch = invalidatedCenter.beginNewRequest()
        var staleExecution = false
        invalidatedCenter.capture(descriptor, expectedEpoch: invalidatedEpoch) { _, _ in staleExecution = true }
        let staleID = invalidatedCenter.summary!.id
        invalidatedCenter.invalidate()
        check("app/provider invalidation drops pending state instead of auto-running it",
              invalidatedCenter.summary == nil
                && !invalidatedCenter.retry(summaryID: staleID, explicitlyUsing: chosen)
                && !staleExecution)

        let leaseCenter = TextTransformRetryCenter()
        let leaseEpoch = leaseCenter.beginNewRequest()
        var leaseID: UUID?
        leaseCenter.capture(descriptor, expectedEpoch: leaseEpoch) { _, executionID in leaseID = executionID }
        let leaseSummary = leaseCenter.summary!
        _ = leaseCenter.retry(summaryID: leaseSummary.id, explicitlyUsing: chosen)
        leaseCenter.invalidate()
        check("state invalidation revokes an in-flight retry before its late result can land",
              leaseID.map { leaseCenter.acceptResult(executionID: $0) == nil } ?? false)

        let routes = LLMRouteID.builtIns + [.custom("retry-custom")]
        let covered = routes.allSatisfy { route in
            let routeCenter = TextTransformRetryCenter()
            let request = TextTransformRequest(
                route: route, bundle: .claude("fixture", effort: "low"), sourceText: "source",
                systemPrompt: "system", userMessage: "wrapped", timeout: 9)
            let routeDescriptor = TextTransformClient.retryDescriptor(for: request, after: .timedOut)!
            let routeEpoch = routeCenter.beginNewRequest()
            routeCenter.capture(routeDescriptor, expectedEpoch: routeEpoch) { _, _ in }
            return routeCenter.summary?.route == route
        }
        check("pending retry ownership covers cleanup L1/L2/L3, P, M, L, G, and custom routes", covered)
    }

    private static func checkSyncRetryArming(
        _ check: (String, Bool) -> Void,
        okText: (CleanupClient.Result) -> String?,
        isUnavailable: (CleanupClient.Result) -> Bool
    ) {
        print("--- synchronous retry arming contract ---")
        let center = TextTransformRetryCenter.shared
        center.invalidate()
        let request = TextTransformRequest(
            route: .searchLocalSynth, bundle: .local("sync-local"), sourceText: "source",
            systemPrompt: "system", userMessage: "user", timeout: 5)
        let callsLock = NSLock()
        var suppliedCalls = 0
        var suppliedLanding: CleanupClient.Result?
        let suppliedLandingDone = DispatchSemaphore(value: 0)
        let suppliedInitial = TextTransformClient.transformSync(
            request,
            local: { _ in
                let call = callsLock.withLock { () -> Int in
                    suppliedCalls += 1
                    return suppliedCalls
                }
                return call == 1 ? .unavailable("synthetic first failure") : .ok("retry raw")
            },
            resultMap: { result in
                if case .ok(let text) = result { return .ok("mapped: \(text)") }
                return result
            },
            retryCompletion: { result in
                suppliedLanding = result
                suppliedLandingDone.signal()
            })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let suppliedPending = center.summary
        let suppliedStarted = suppliedPending.map {
            center.retry(summaryID: $0.id, explicitlyUsing: .local("sync-retry-local"))
        } ?? false
        let suppliedFinished = suppliedLandingDone.wait(timeout: .now() + 2) == .success
        let suppliedCallCount = callsLock.withLock { suppliedCalls }
        check("sync transform with retry landing arms one explicit mapped retry",
              isUnavailable(suppliedInitial)
                && suppliedPending?.route == .searchLocalSynth
                && suppliedStarted && suppliedFinished && suppliedCallCount == 2
                && suppliedLanding.flatMap(okText) == "mapped: retry raw")

        center.invalidate()
        var absentCalls = 0
        let absentInitial = TextTransformClient.transformSync(request, local: { _ in
            absentCalls += 1
            return .unavailable("synthetic no-retry failure")
        })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("sync transform without retry landing never arms retry state",
              isUnavailable(absentInitial) && absentCalls == 1 && center.summary == nil)
        center.invalidate()
    }

    /// `TextTransformArming.inert` — the seam that lets the prompt workstation's Test button (W2) run the
    /// REAL transform without disturbing the delivery path.
    ///
    /// `transform` calls `beginNewRequest()` on every dispatch, which wipes any pending Retry: correct for
    /// a real take (a new user action supersedes an old failure), wrong for a test the user did not
    /// deliver. Pressing Test would silently disarm the Retry button the user was about to press. The
    /// armed half of each pair below is what gives the inert half teeth: if arming stopped mattering
    /// entirely, the armed assertions go red rather than the inert ones going quietly vacuous.
    private static func checkInertArming(
        _ check: (String, Bool) -> Void,
        okText: (CleanupClient.Result) -> String?,
        isUnavailable: (CleanupClient.Result) -> Bool
    ) {
        print("--- inert dispatch leaves the retry lifecycle alone ---")
        let center = TextTransformRetryCenter.shared
        let request = TextTransformRequest(
            route: .custom("inert-selftest"), bundle: .local("inert-local"), sourceText: "source",
            systemPrompt: "system", userMessage: "user", timeout: 5)

        /// Put a real pending Retry in the center the way a failed take does.
        func armPendingRetry() -> UUID? {
            center.invalidate()
            _ = TextTransformClient.transformSync(
                request, local: { _ in .unavailable("synthetic failure to be retried") },
                retryCompletion: { _ in })
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            return center.summary?.id
        }

        guard let pendingID = armPendingRetry() else {
            check("a pending retry can be armed for the inert contract", false)
            return
        }
        check("a pending retry can be armed for the inert contract", true)

        var inertResult: CleanupClient.Result?
        TextTransformClient.transform(
            request, local: { _, done in done(.ok("inert output")) },
            arming: .inert, completion: { inertResult = $0 })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("an inert dispatch still runs and returns its result",
              inertResult.flatMap(okText) == "inert output")
        check("an inert dispatch leaves the user's pending Retry exactly where it was",
              center.summary?.id == pendingID)

        // Same call, armed: the pending retry goes. Without this the check above could pass for the
        // wrong reason.
        TextTransformClient.transform(
            request, local: { _, done in done(.ok("armed output")) },
            arming: .armed, completion: { _ in })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("an armed dispatch does supersede it, which is what the inert case is avoiding",
              center.summary == nil)

        // An inert dispatch arms nothing of its own either, even asked to: a failed test must not leave
        // a Retry button pointing at a run the user never delivered.
        center.invalidate()
        var inertFailure: CleanupClient.Result?
        TextTransformClient.transform(
            request, local: { _, done in done(.unavailable("synthetic inert failure")) },
            arming: .inert, retryCompletion: { _ in }, completion: { inertFailure = $0 })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("a failed inert dispatch arms no retry of its own",
              isUnavailable(inertFailure ?? .ok("")) && center.summary == nil)

        // The off-route path is the commonest way a test finishes (LM Studio not running), and it
        // advances the center separately from the dispatching path.
        guard let offPendingID = armPendingRetry() else {
            check("a pending retry survives an inert off-route resolution", false)
            return
        }
        var offResult: CleanupClient.Result?
        TextTransformClient.transformResolved(
            .off(reason: "synthetic route off"), route: .custom("inert-selftest"),
            requestForBundle: { _ in request },
            local: { _, done in done(.ok("must not run")) },
            arming: .inert, completion: { offResult = $0 })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("a pending retry survives an inert off-route resolution",
              isUnavailable(offResult ?? .ok("")) && center.summary?.id == offPendingID)

        TextTransformClient.transformResolved(
            .off(reason: "synthetic route off"), route: .custom("inert-selftest"),
            requestForBundle: { _ in request },
            local: { _, done in done(.ok("must not run")) },
            arming: .armed, completion: { _ in })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        check("an armed off-route resolution still supersedes it", center.summary == nil)
        center.invalidate()
    }

    private static func checkCapturedTargetRetryLanding(_ check: (String, Bool) -> Void) {
        print("--- destination-pinned foreign-app retry landing ---")
        let deadApp = TargetResolver.capturedTargetValidation(
            appIsRunning: false,
            elementIdentityAvailable: false,
            focusedDestinationAvailable: false,
            sameElement: false,
            selectionIdentityRequired: false,
            selectionIdentityAvailable: false,
            selectionMatches: false)
        let deadOutcome = TargetResolver.CapturedTargetLandingOutcome.clipboardOnly(deadApp!)
        check("terminated captured app is a classified non-landing",
              deadApp == .targetAppUnavailable && !deadOutcome.didLand)

        let movedFocus = TargetResolver.capturedTargetValidation(
            appIsRunning: true,
            elementIdentityAvailable: true,
            focusedDestinationAvailable: true,
            sameElement: false,
            selectionIdentityRequired: true,
            selectionIdentityAvailable: true,
            selectionMatches: true)
        let unreadableFocus = TargetResolver.capturedTargetValidation(
            appIsRunning: true,
            elementIdentityAvailable: true,
            focusedDestinationAvailable: false,
            sameElement: false,
            selectionIdentityRequired: false,
            selectionIdentityAvailable: false,
            selectionMatches: false)
        let movedSelection = TargetResolver.capturedTargetValidation(
            appIsRunning: true,
            elementIdentityAvailable: true,
            focusedDestinationAvailable: true,
            sameElement: true,
            selectionIdentityRequired: true,
            selectionIdentityAvailable: true,
            selectionMatches: false)
        check("moved focus, unreadable focus, and changed selection fail closed distinctly",
              movedFocus == .destinationChanged
                && unreadableFocus == .destinationUnverifiable
                && movedSelection == .selectionChanged)

        let validDestination = TargetResolver.capturedTargetValidation(
            appIsRunning: true,
            elementIdentityAvailable: true,
            focusedDestinationAvailable: true,
            sameElement: true,
            selectionIdentityRequired: true,
            selectionIdentityAvailable: true,
            selectionMatches: true)
        check("only a live exact field and available matching selection clears validation",
              validDestination == nil)

        let clipboardOutcome = TargetResolver.CapturedTargetLandingOutcome
            .clipboardOnly(.destinationChanged)
        check("clipboard fallback has its own content-safe classification and is never a landing",
              !clipboardOutcome.didLand
                && clipboardOutcome.logToken == "clipboard_only_destination_changed"
                && clipboardOutcome.userMessage == "Focus moved to a different field — output copied to clipboard")
        check("retry state owner records only the validated landing outcome",
              DictationController.shouldRecordForeignRetryLanding(.landed)
                && !DictationController.shouldRecordForeignRetryLanding(deadOutcome)
                && !DictationController.shouldRecordForeignRetryLanding(clipboardOutcome))
    }

    private static func checkCustomAndSearchRequestRoutes(_ check: (String, Bool) -> Void) {
        print("--- request-builder call-site route coverage ---")
        let cleanupBundle = LLMProviderBundle.claude("cleanup-c", effort: "medium")
        let cleanupRequest = DictationController.makeCleanupRequest(
            route: .cleanupL2, input: "CLEANUP INPUT", selected: cleanupBundle,
            systemPrompt: "CLEANUP SYSTEM", timeout: 13)
        check("dictation cleanup request preserves its route, provider, prompt, and cleanup wrapper",
              cleanupRequest.route == .cleanupL2
                && cleanupRequest.bundle == cleanupBundle
                && cleanupRequest.sourceText == "CLEANUP INPUT"
                && cleanupRequest.systemPrompt == "CLEANUP SYSTEM"
                && cleanupRequest.userMessage == CleanupClient.wrap("CLEANUP INPUT")
                && cleanupRequest.timeout == 13)

        let prepBundle = LLMProviderBundle.codex("prep-codex", effort: "high")
        let prepRequest = OneShotRegistry.makeCleanupSelectionRequest(
            input: "PREP INPUT", selected: prepBundle,
            systemPrompt: "PREP SYSTEM", timeout: 19)
        check("Option+P request preserves the prompt-prep route, provider, prompt, and cleanup wrapper",
              prepRequest.route == .promptPrep
                && prepRequest.bundle == prepBundle
                && prepRequest.sourceText == "PREP INPUT"
                && prepRequest.systemPrompt == "PREP SYSTEM"
                && prepRequest.userMessage == CleanupClient.wrap("PREP INPUT")
                && prepRequest.timeout == 19)

        let emailBundle = LLMProviderBundle.local("email-local")
        let emailRequest = OneShotRegistry.makeEmailRequest(
            input: "EMAIL INPUT", selected: emailBundle,
            systemPrompt: "EMAIL SYSTEM", timeout: 23)
        check("Option+M request preserves the email route, provider, prompt, and notes wrapper",
              emailRequest.route == .email
                && emailRequest.bundle == emailBundle
                && emailRequest.sourceText == "EMAIL INPUT"
                && emailRequest.systemPrompt == "EMAIL SYSTEM"
                && emailRequest.userMessage == EmailClient.wrap("EMAIL INPUT")
                && emailRequest.timeout == 23)

        let custom = CustomMode(
            id: "h1-custom", name: "H1", chord: .regular(keyCode: 3, label: "F"),
            prompt: "provider-neutral task", input: .selection, model: .local("legacy"),
            landing: .inPlace)
        let customBundle = LLMProviderBundle.codex("custom-codex", effort: "low")
        let customRequest = CustomModeClient.makeRequest(
            mode: custom, input: "CUSTOM INPUT", selected: customBundle,
            systemPrompt: "CUSTOM SYSTEM", timeout: 17)
        check("custom mode request preserves its durable namespaced route and provider-neutral wrapper",
              customRequest.route == .custom("h1-custom")
                && customRequest.bundle == customBundle
                && customRequest.sourceText == "CUSTOM INPUT"
                && customRequest.systemPrompt == "CUSTOM SYSTEM"
                && customRequest.userMessage == CleanupClient.wrap("CUSTOM INPUT")
                && customRequest.timeout == 17)

        let localBundle = LLMProviderBundle.claude("search-l", effort: "high")
        let geminiBundle = LLMProviderBundle.codex("search-g", effort: "low")
        let localRequest = SearchClient.makeSynthesisRequest(
            route: .searchLocalSynth, question: "same question", resultsBlock: "same results",
            selected: localBundle, systemPrompt: "shared prompt", timeout: 31)
        let geminiRequest = SearchClient.makeSynthesisRequest(
            route: .searchGeminiSynth, question: "same question", resultsBlock: "same results",
            selected: geminiBundle, systemPrompt: "shared prompt", timeout: 47)
        check("Option+L/G synthesis keeps distinct route/provider bundles while sharing prompt/input bytes",
              localRequest.route == .searchLocalSynth
                && geminiRequest.route == .searchGeminiSynth
                && localRequest.bundle == localBundle && geminiRequest.bundle == geminiBundle
                && localRequest.sourceText == geminiRequest.sourceText
                && localRequest.systemPrompt == geminiRequest.systemPrompt
                && localRequest.userMessage == geminiRequest.userMessage
                && localRequest.timeout == 31 && geminiRequest.timeout == 47)
    }

    private static func checkDispatchAndRetry(
        _ check: (String, Bool) -> Void,
        okText: (CleanupClient.Result) -> String?,
        isUnavailable: (CleanupClient.Result) -> Bool
    ) {
        print("--- provider-neutral equivalence + strict retry ---")
        let local = TextTransformRequest(
            route: .promptPrep, bundle: .local("local-model"), sourceText: "source",
            systemPrompt: "system", userMessage: "wrapped-source", timeout: 5)
        let claude = local.explicitlyRetrying(with: .claude("claude-model", effort: "medium"),
                                              timeout: 90)
        var localCalls = 0, claudeCalls = 0
        var localRequestPreserved = false, claudeRequestPreserved = false
        var localResult: CleanupClient.Result = .unavailable("unset")
        TextTransformClient.transform(local, local: { request, done in
            localCalls += 1
            localRequestPreserved = request == local
            done(.ok("same-output"))
        }, claude: { _, done in
            claudeCalls += 1
            done(.ok("wrong-provider"))
        }, completion: { localResult = $0 })

        var claudeResult: CleanupClient.Result = .unavailable("unset")
        TextTransformClient.transform(claude, local: { _, done in
            localCalls += 1
            done(.ok("wrong-provider"))
        }, claude: { request, done in
            claudeCalls += 1
            claudeRequestPreserved = request.route == local.route && request.sourceText == local.sourceText
                && request.systemPrompt == local.systemPrompt && request.userMessage == local.userMessage
                && request.bundle == claude.bundle && request.timeout == claude.timeout
            done(.ok("same-output"))
        }, completion: { claudeResult = $0 })
        check("Local adapter receives the complete unchanged route/prompt/envelope contract",
              localRequestPreserved)
        check("Claude adapter receives the same route/prompt/envelope with only its explicit bundle/timeout",
              claudeRequestPreserved)
        check("Local and Claude dispatch return the existing Result contract equivalently",
              okText(localResult) == "same-output" && okText(claudeResult) == "same-output"
                  && localCalls == 1 && claudeCalls == 1)

        localCalls = 0; claudeCalls = 0
        let failure = CleanupClient.Result.unavailable("selected provider offline")
        var firstResult: CleanupClient.Result = .ok("unset")
        TextTransformClient.transform(local, local: { _, done in
            localCalls += 1
            done(failure)
        }, claude: { _, done in
            claudeCalls += 1
            done(.ok("implicit fallback"))
        }, completion: { firstResult = $0 })
        check("a selected-provider failure never auto-invokes another provider",
              isUnavailable(firstResult) && localCalls == 1 && claudeCalls == 0)
        check("failure landing remains the existing raw-fallback invariant",
              CleanupLogic.landing(for: firstResult) == .rawFallback)

        let descriptor = TextTransformClient.retryDescriptor(for: local, after: firstResult)
        check("failure exposes a strict retry descriptor with the exact failed route/provider",
              descriptor?.route == .promptPrep && descriptor?.failedProvider == .local
                  && descriptor?.failedBundle == local.bundle)
        check("success exposes no retry descriptor",
              TextTransformClient.retryDescriptor(for: local, after: .ok("done")) == nil)

        var retryResult: CleanupClient.Result = .unavailable("unset")
        if let descriptor = descriptor {
            let explicit = descriptor.request(explicitlyUsing: claude.bundle, timeout: claude.timeout)
            TextTransformClient.transform(explicit, local: { _, done in
                localCalls += 1
                done(.ok("wrong-provider"))
            }, claude: { _, done in
                claudeCalls += 1
                done(.ok("explicit-retry"))
            }, completion: { retryResult = $0 })
        }
        check("another provider runs only after its bundle is explicitly supplied",
              okText(retryResult) == "explicit-retry" && localCalls == 1 && claudeCalls == 1)

        var codexLocalCalls = 0, codexClaudeCalls = 0, codexCalls = 0
        var codexRoutes: [LLMRouteID] = []
        for route in LLMRouteID.builtIns + [.custom("c1-fixture")] {
            let codex = TextTransformRequest(
                route: route,
                bundle: .codex("synthetic-codex", effort: "medium"),
                sourceText: local.sourceText,
                systemPrompt: local.systemPrompt,
                userMessage: local.userMessage,
                timeout: 90)
            var codexResult: CleanupClient.Result = .unavailable("unset")
            TextTransformClient.transform(codex, local: { _, done in
                codexLocalCalls += 1; done(.ok("wrong"))
            }, claude: { _, done in
                codexClaudeCalls += 1; done(.ok("wrong"))
            }, codex: { request, done in
                codexCalls += 1
                codexRoutes.append(request.route)
                done(.ok("codex-output"))
            }, completion: { codexResult = $0 })
            check("Codex dispatch preserves route \(route.rawValue)",
                  okText(codexResult) == "codex-output")
        }
        check("every built-in/custom route reaches only the explicit Codex adapter",
              codexRoutes == LLMRouteID.builtIns + [.custom("c1-fixture")]
                && codexCalls == LLMRouteID.builtIns.count + 1
                && codexLocalCalls == 0 && codexClaudeCalls == 0)

        var codexFailure: CleanupClient.Result = .ok("unset")
        let codex = local.explicitlyRetrying(
            with: .codex("synthetic-codex", effort: "medium"), timeout: 90)
        TextTransformClient.transform(codex, local: { _, done in
            codexLocalCalls += 1; done(.ok("wrong"))
        }, claude: { _, done in
            codexClaudeCalls += 1; done(.ok("wrong"))
        }, codex: { _, done in
            done(.unavailable("selected Codex failed"))
        }, completion: { codexFailure = $0 })
        check("Codex failure stays fail-closed without a Local/Claude hop",
              isUnavailable(codexFailure) && codexLocalCalls == 0 && codexClaudeCalls == 0)
    }

    private static func checkClaudePrivateTransport(
        _ check: (String, Bool) -> Void,
        okText: (CleanupClient.Result) -> String?
    ) {
        print("--- Claude stdin + restrictive prompt-file transport ---")
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-a2-transport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("fake-claude")
            let script = """
            #!/bin/sh
            args="$CAPTURE_ROOT/argv"
            : > "$args"
            prompt_file=""
            while [ "$#" -gt 0 ]; do
              arg="$1"
              /usr/bin/printf '%s\n' "$arg" >> "$args"
              shift
              if [ "$arg" = "--system-prompt-file" ] && [ "$#" -gt 0 ]; then
                prompt_file="$1"
                /usr/bin/printf '%s\n' "$1" >> "$args"
                shift
              fi
            done
            /bin/cat > "$CAPTURE_ROOT/stdin"
            /bin/cat "$prompt_file" > "$CAPTURE_ROOT/prompt"
            /usr/bin/stat -f '%Lp' "$prompt_file" > "$CAPTURE_ROOT/prompt-mode"
            /usr/bin/stat -f '%Lp' "$(/usr/bin/dirname "$prompt_file")" > "$CAPTURE_ROOT/prompt-dir-mode"
            /usr/bin/printf '%s\n' '{"type":"result","is_error":false,"result":"synthetic-ok"}'
            """
            try SelfTestFixtureExecutable.install(
                script: script, at: executable, mode: 0o700)

            let promptCanary = "SYNTHETIC_PROMPT_\(UUID().uuidString)"
            let inputCanary = "SYNTHETIC_INPUT_\(UUID().uuidString)"
            let result = CloudCleanupClient.spawnSyncForTest(
                executable: executable.path, systemPrompt: promptCanary, userMessage: inputCanary,
                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                              "CAPTURE_ROOT": root.path])
            let argv = (try? String(contentsOf: root.appendingPathComponent("argv"), encoding: .utf8)) ?? ""
            let stdin = (try? String(contentsOf: root.appendingPathComponent("stdin"), encoding: .utf8)) ?? ""
            let prompt = (try? String(contentsOf: root.appendingPathComponent("prompt"), encoding: .utf8)) ?? ""
            let promptMode = ((try? String(contentsOf: root.appendingPathComponent("prompt-mode"), encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dirMode = ((try? String(contentsOf: root.appendingPathComponent("prompt-dir-mode"), encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = argv.split(separator: "\n").map(String.init)
            let promptPath: String? = lines.firstIndex(of: "--system-prompt-file").flatMap {
                $0 + 1 < lines.count ? lines[$0 + 1] : nil
            }
            check("synthetic Claude transport returns the ordinary CleanupClient.Result",
                  okText(result) == "synthetic-ok")
            check("wrapped input arrives only on stdin and is absent from argv",
                  stdin == inputCanary && !argv.contains(inputCanary))
            check("effective prompt arrives only through the prompt file and is absent from argv",
                  prompt == promptCanary && !argv.contains(promptCanary)
                      && lines.contains("--system-prompt-file") && !lines.contains("--system-prompt"))
            check("ephemeral prompt file and directory are restrictive (0600/0700)",
                  promptMode == "600" && dirMode == "700")
            check("ephemeral effective-prompt file is removed after the child is reaped",
                  promptPath.map { !FileManager.default.fileExists(atPath: $0) } == true)
        } catch {
            check("synthetic Claude transport fixture setup", false)
        }
    }

    private static func checkTransientExitHelperCleanup(_ check: (String, Bool) -> Void) {
        print("--- clean leader exit with transient same-group helper ---")
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-a2-exit-helper-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("exit-helper-fixture")
            let pidFile = root.appendingPathComponent("helper.pid")
            let script = """
            #!/bin/sh
            /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
            child=$!
            /usr/bin/printf '%s\n' "$child" > "$1"
            exit 0
            """
            try SelfTestFixtureExecutable.install(
                script: script, at: executable, mode: 0o700)

            let run = CloudCleanupClient.runProcessForTest(
                executable: executable.path, arguments: [pidFile.path], timeout: 5, grace: 0.2)
            check("a helper present at the first sample is accepted only after bounded cleanup clears it",
                  run?.timedOut == false && run?.terminatedBySignal == false
                    && run?.leaderReaped == true && run?.hadResidualProcessGroup == true
                    && run?.residualProcessGroup == false
                    && CloudCleanupClient.processGroupExitWasClean(
                        leaderReaped: run?.leaderReaped == true,
                        residualProcessGroup: run?.residualProcessGroup == true))
            check("a final surviving descendant or unreaped leader remains a hard failure",
                  !CloudCleanupClient.processGroupExitWasClean(
                      leaderReaped: true, residualProcessGroup: true)
                    && !CloudCleanupClient.processGroupExitWasClean(
                        leaderReaped: false, residualProcessGroup: false))
            // The drain half of the same contract. A clean teardown does NOT imply closed pipes: the
            // escaped-pipe-holder shape reads clean above and unfinished here, which is the whole reason
            // the drains carry their own deadline and their own evidence.
            check("a healthy run reports all three drains finished at EOF",
                  run?.drainsComplete == true && run?.stdinWriterComplete == true
                    && run?.stdoutEOF == true && run?.stderrEOF == true)
            check("an unfinished drain on ANY of the three streams is a hard failure",
                  CloudCleanupClient.drainsWereComplete(
                      stdinWriterComplete: true, stdoutEOF: true, stderrEOF: true)
                    && !CloudCleanupClient.drainsWereComplete(
                        stdinWriterComplete: false, stdoutEOF: true, stderrEOF: true)
                    && !CloudCleanupClient.drainsWereComplete(
                        stdinWriterComplete: true, stdoutEOF: false, stderrEOF: true)
                    && !CloudCleanupClient.drainsWereComplete(
                        stdinWriterComplete: true, stdoutEOF: true, stderrEOF: false))
        } catch {
            check("transient exit-helper fixture setup", false)
        }
    }

    private static func checkProcessGroupTimeout(_ check: (String, Bool) -> Void) {
        print("--- process-group TERM/grace/KILL/reap ---")
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-a2-watchdog-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("watchdog-fixture")
            let pidFile = root.appendingPathComponent("descendant.pid")
            let script = """
            #!/bin/sh
            trap '' TERM
            /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
            child=$!
            /usr/bin/printf '%s\n' "$child" > "$1"
            while :; do /bin/sleep 1; done
            """
            try SelfTestFixtureExecutable.install(
                script: script, at: executable, mode: 0o700)
            let run = CloudCleanupClient.runProcessForTest(
                executable: executable.path, arguments: [pidFile.path], timeout: 0.2, grace: 0.2)
            let descendant = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            var descendantGone = false
            if let descendant = descendant {
                for _ in 0..<100 {
                    errno = 0
                    if kill(descendant, 0) != 0 && errno == ESRCH { descendantGone = true; break }
                    usleep(20_000)
                }
            }
            check("watchdog timeout is classified and escalates past ignored SIGTERM to group SIGKILL",
                  run?.timedOut == true && run?.escalatedToSIGKILL == true)
            check("timeout path reaps the process-group leader",
                  run?.leaderReaped == true)
            check("timeout leaves no surviving descendant or residual process group",
                  descendantGone && run?.residualProcessGroup == false)
        } catch {
            check("process-group timeout fixture setup", false)
        }
    }

    /// EVIDENCE ON THE TIMEOUT PATH. `spawnSync` returns `.timedOut` before `processGroupExitWasClean` is
    /// ever consulted, so an unclean process-group exit on that path -- a real leak -- used to produce no
    /// log line at all: the comment above that check described an intent the early return made
    /// unreachable. The fix is evidence, not routing, so this pins BOTH halves -- the log now says what it
    /// tore down, and every outcome is exactly the one it was before.
    ///
    /// The unclean teardown is forced through the ECHILD branch `runProcess` documents: with SIGCHLD set
    /// to SIG_IGN the kernel auto-reaps, `waitpid` answers ECHILD, and the run is classified
    /// `timedOut=true, leaderReaped=false` -- an unclean group exit that returns on the TIMEOUT path and
    /// so never reaches the cleanliness check. That is precisely the shape the hole hid. The lever is
    /// scoped to the one call and the previous disposition is restored immediately.
    private static func checkTimeoutPathTeardownEvidence(_ check: (String, Bool) -> Void,
                                                         okText: (CleanupClient.Result) -> String?) {
        print("--- timeout-path teardown evidence ---")
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-d3-timeout-evidence-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("evidence-fixture")
            let script = """
            #!/bin/sh
            /bin/cat > /dev/null
            /usr/bin/printf '%s\n' '{"type":"result","is_error":false,"result":"synthetic-ok"}'
            """
            try SelfTestFixtureExecutable.install(script: script, at: executable, mode: 0o700)

            // Only the lines this run appended, so a phrase left in the log by an earlier case can never
            // stand in for one this call was supposed to emit.
            func appendedLog(_ body: () -> CleanupClient.Result) -> (CleanupClient.Result, String) {
                Log.flushForTest()
                let before = ((try? String(contentsOf: Log.url, encoding: .utf8)) ?? "").count
                let result = body()
                Log.flushForTest()
                let after = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
                return (result, String(after.dropFirst(before)))
            }
            func line(_ log: String, containing needle: String) -> String {
                log.split(separator: "\n").first { $0.contains(needle) }.map(String.init) ?? ""
            }

            let (healthy, healthyLog) = appendedLog {
                CloudCleanupClient.spawnSyncForTest(
                    executable: executable.path, systemPrompt: "synthetic-prompt",
                    userMessage: "synthetic-input")
            }
            check("a clean teardown keeps its outcome and stays silent -- evidence is not noise",
                  okText(healthy) == "synthetic-ok"
                    && !healthyLog.contains("did not exit cleanly")
                    && !healthyLog.contains("timed out / killed"))

            let previousSIGCHLD = signal(SIGCHLD, SIG_IGN)
            let (forced, forcedLog) = appendedLog {
                CloudCleanupClient.spawnSyncForTest(
                    executable: executable.path, systemPrompt: "synthetic-prompt",
                    userMessage: "synthetic-input")
            }
            _ = signal(SIGCHLD, previousSIGCHLD)
            var forcedTimedOut = false
            if case .timedOut = forced { forcedTimedOut = true }
            let residualLine = line(forcedLog, containing: "did not exit cleanly")
            let timeoutLine = line(forcedLog, containing: "timed out / killed after")

            check("an unclean process-group exit still returns on the timeout path, outcome unchanged",
                  forcedTimedOut && !timeoutLine.isEmpty)
            check("that unclean exit is no longer invisible: the residual line is emitted before the "
                    + "timeout return, not after the check the return skips",
                  residualLine.contains("claude: process group did not exit cleanly")
                    && residualLine.contains("leaderReaped=false"))
            check("both lines carry reap evidence AND D2's drain evidence, which is the pair that "
                    + "separates a clean kill from an escaped pipe holder",
                  [residualLine, timeoutLine].allSatisfy {
                      $0.contains("leaderReaped=") && $0.contains("residual=")
                        && $0.contains("drainsComplete=true") && $0.contains("stdinWriter=true")
                        && $0.contains("stdoutEOF=true") && $0.contains("stderrEOF=true")
                  })

            // The one shape no fixture can stage -- a descendant that survives the bounded group cleanup.
            // Rendering is pinned directly so the leak reads as a leak whenever it does happen.
            let leaked = CloudCleanupClient.ProcessRunResult(
                exitCode: 137, stdout: Data(), stderr: Data(),
                timedOut: true, terminatedBySignal: true,
                leaderReaped: true, escalatedToSIGKILL: true,
                hadResidualProcessGroup: true, residualProcessGroup: true,
                drainsComplete: false, stdinWriterComplete: true,
                stdoutEOF: false, stderrEOF: true)
            let leakedEvidence = CloudCleanupClient.teardownEvidence(leaked)
            check("a genuine residual group with an unfinished drain renders as exactly that",
                  leakedEvidence.contains("residual=true") && leakedEvidence.contains("sigkill=true")
                    && leakedEvidence.contains("drainsComplete=false")
                    && leakedEvidence.contains("stdoutEOF=false"))
        } catch {
            check("timeout-path evidence fixture setup", false)
        }
    }

    private static func checkLogPrivacy(_ check: (String, Bool) -> Void) {
        print("--- provider error/log privacy ---")
        let stderrCanary = "SYNTHETIC_STDERR_\(UUID().uuidString)"
        let providerCanary = "SYNTHETIC_PROVIDER_ERROR_\(UUID().uuidString)"
        _ = CloudCleanupClient.parseResult(stdout: "not-json", exitCode: 1, stderrText: stderrCanary)
        let providerResult = CloudCleanupClient.parseResult(
            stdout: "{\"is_error\":true,\"result\":\"\(providerCanary)\"}")
        Log.flushForTest()
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("Claude request-shaped stderr and provider payload contents never enter the app log",
              !log.contains(stderrCanary) && !log.contains(providerCanary))
        let returnedReason: String
        if case .unavailable(let why) = providerResult { returnedReason = why } else { returnedReason = "" }
        check("provider payload contents cannot re-enter logs through downstream failure reasons",
              !returnedReason.contains(providerCanary))
        checkStderrDiagnostic(check)
    }

    /// Safe stderr diagnostics are always on: recognizable CLI errors survive while request content,
    /// secrets, paths, multiline payloads, and pathological output remain redacted or bounded.
    private static func checkStderrDiagnostic(_ check: (String, Bool) -> Void) {
        print("--- paste-safe provider stderr diagnostic ---")
        let flag = "--synthetic-flag-\(UUID().uuidString)"
        let privateInput = "PRIVATE_NOTE_\(UUID().uuidString)"
        let stderr = "noise\nerror: unexpected argument '\(flag)' for \(privateInput)\nusage: tool"
        let head = CloudCleanupClient.diagnosticStderrHead(
            stderr, sensitiveValues: [privateInput])
        check("a diagnostic-looking stderr line reaches the log with CLI flags intact",
              head.contains(flag) && head.hasPrefix(" stderrHead=error:"))
        check("exact request content is redacted before the stderr line is rendered",
              !head.contains(privateInput) && head.contains("<redacted-input>"))

        let secret = CloudCleanupClient.diagnosticStderrHead(
            "error: token=sk-synthetic-secret /Users/synthetic/private.txt person@example.com")
        check("secret, path, and email shapes are redacted from provider stderr",
              !secret.contains("sk-synthetic-secret")
                && !secret.contains("/Users/synthetic")
                && !secret.contains("person@example.com")
                && secret.contains("<redacted>"))

        let long = "error: " + String(repeating: "A", count: 5_000)
        let bounded = CloudCleanupClient.diagnosticStderrHead(long)
        check("released stderr is bounded to \(ProviderStderrDiagnostic.maxRenderedBytes) ASCII bytes",
              bounded.utf8.count <= ProviderStderrDiagnostic.maxRenderedBytes + 32)
        check("unrecognized stderr is replaced rather than copied",
              CloudCleanupClient.diagnosticStderrHead(privateInput)
                == " stderrHead=<redacted-unrecognized-stderr>")
        check("empty stderr renders nothing",
              CloudCleanupClient.diagnosticStderrHead("").isEmpty)

        // ── the frame-carrying invocation (the 2026-08-12 cloud sticky-skill defect) ──────────────
        //
        // A note with an attachment makes the Claude transform switch its input to `stream-json` so the
        // frames and the wrapped text ride one user turn. The output format stayed `json`, and the CLI
        // rejects that pair while PARSING ARGV: 70 bytes on stderr, exit 1, in well under a second,
        // before any model work. That is the `no parseable JSON (exit 1, stderrBytes=70)` line every
        // cloud sticky skill over a note with an attachment produced, and it is why the same route,
        // model and note went through from the selection hotkey - that path carries no images, so its
        // input never left `text`.
        let framePromptFile = "/private/tmp/viddydictate-synthetic-frame-prompt.txt"
        let textArgs = CloudCleanupClient.buildArgs(systemPromptFilePath: framePromptFile)
        let frameArgs = CloudCleanupClient.buildArgs(
            systemPromptFilePath: framePromptFile,
            inputFormat: CloudCleanupClient.streamingInputFormat)
        func value(_ flag: String, in argv: [String]) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        check("frames on stdin force the matching stream-json OUTPUT format the CLI demands",
              value("--input-format", in: frameArgs) == "stream-json"
                && value("--output-format", in: frameArgs) == "stream-json")
        check("streamed output also carries --verbose, the CLI's second requirement under -p",
              frameArgs.contains("--verbose"))
        check("the text path keeps buffered json and stays verbose-free (every old caller unchanged)",
              value("--output-format", in: textArgs) == "json" && !textArgs.contains("--verbose"))
        check("nothing but the format flags differs between the text and frame invocations",
              frameArgs.filter { $0 != "--verbose" && $0 != "stream-json" }
                == textArgs.filter { $0 != "json" && $0 != "text" })

        // The other half of that path: streamed stdout is one object PER LINE and the outcome is the
        // final `type: "result"` line. Reading the first object would report a blank transform on a run
        // that actually succeeded, so fixing the argv alone would have swapped one silent failure for
        // another.
        let streamed = [
            #"{"type":"system","subtype":"init","session_id":"s","cwd":"/private/tmp"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Handoff"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Handoff\n\n### item one"}"#,
        ].joined(separator: "\n")
        func isOK(_ result: CleanupClient.Result, _ text: String) -> Bool {
            if case .ok(let value) = result { return value == text }
            return false
        }
        func isUnavailable(_ result: CleanupClient.Result) -> Bool {
            if case .unavailable = result { return true }
            return false
        }
        check("streamed frame output resolves the final result line, not the session banner",
              isOK(CloudCleanupClient.parseResult(stdout: streamed), "Handoff\n\n### item one"))
        check("a streamed run that reports an error stays .unavailable, never pasted",
              isUnavailable(CloudCleanupClient.parseResult(
                stdout: #"{"type":"system","subtype":"init"}"# + "\n"
                    + #"{"type":"result","subtype":"error","is_error":true,"result":"boom"}"#)))
        check("a streamed run with no result line at all -> .unavailable, never silently empty",
              isUnavailable(CloudCleanupClient.parseResult(
                stdout: #"{"type":"system","subtype":"init"}"# + "\n"
                    + #"{"type":"assistant","message":{"role":"assistant"}}"#, exitCode: 1)))

        let loggedFlag = "--logged-claude-\(UUID().uuidString)"
        _ = CloudCleanupClient.parseResult(
            stdout: "not-json", exitCode: 2,
            stderrText: "error: unexpected argument '\(loggedFlag)' found")
        Log.flushForTest()
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("Claude parse failure writes the safe stderr message into the real app log",
              log.contains("claude: no parseable JSON (exit 2") && log.contains(loggedFlag))
    }
}
