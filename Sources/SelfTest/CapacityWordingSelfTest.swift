import Foundation

/// Capacity wording (`--capacity-wording-selftest`): a RAM-capacity refusal must name the bundle
/// model, and the Option+L / Option+G search timeouts must name the model that timed out while every
/// other search sentence stays byte-identical to base. Pure: no AppKit, no store, no socket, no model.
/// The `new:` rows drive a real production seam — the search landing in `OneShotRegistry` fed by the
/// real `SearchClient` pipeline over a scripted `LocalChatTransport` — and the `guard:` rows pin the
/// unchanged constants, capacity sentences, log line, and the no-cross-run-leak invariant.
enum CapacityWordingSelfTest {
    static func run() -> Bool {
        print("=== Capacity wording selftest ===")
        let reporter = SelfTestReporter()

        checkOverBudgetNamesModel(reporter)
        checkOverBudgetEmptyModelID(reporter)
        checkNoProviderText(reporter)
        checkConstantsByteIdentical(reporter)
        checkFactsSentenceUnchanged(reporter)
        checkSourceShapeRequestBuilders(reporter)

        checkSearchTimeoutOptionLSynthesisNamesModel(reporter)
        checkSearchTimeoutOptionGSynthesisNamesModel(reporter)
        checkSearchTimeoutOptionLRetrievalNamesModel(reporter)
        checkSearchTimeoutRetryNamesRetryModel(reporter)
        checkSearchTimeoutGeminiGroundingStaysGeneric(reporter)
        checkSearchCapacitySentencesUnchanged(reporter)
        checkSearchNonTimeoutFailuresUnchanged(reporter)
        checkSearchFailureLogLineUnchanged(reporter)
        checkSearchNewRunNeverShowsEarlierModel(reporter)

        print(reporter.passed
            ? "[capacity-wording-selftest] PASS"
            : "[capacity-wording-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - production-seam helpers

    /// One scripted Local synthesis transport: the LM Studio send returns the supplied timed-out error
    /// (optionally with a provider body), never touching a socket or a model.
    private static func synthesisTimeoutTransport(
        _ error: Error, body: Data? = nil
    ) -> LocalChatTransport {
        LocalChatTransport(
            sendLMStudio: { _, completion in completion(body, nil, error) },
            prepareLMStudio: { _, _ in (.ready, false) },
            unloadLMStudio: { _ in },
            prepareOllama: { _, context, _ in (.ready, context, false) },
            chatOllama: { _, _, _, _, _ in (nil, nil, nil) },
            unloadOllama: { _ in },
            keepAliveSeconds: { 30 },
            beginRequest: { _ in },
            endRequest: { _ in })
    }

    /// A generic scripted Local transport with a caller-supplied LM Studio send path. `prepareOllama`
    /// can be overridden to refuse before any Ollama chat.
    private static func localTransport(
        send: @escaping (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void,
        prepareOllama: ((LocalModelRef, Int, Int)
            -> (result: ModelManager.ReadinessResult, contextTokens: Int, coldLoaded: Bool))? = nil
    ) -> LocalChatTransport {
        LocalChatTransport(
            sendLMStudio: send,
            prepareLMStudio: { _, _ in (.ready, false) },
            unloadLMStudio: { _ in },
            prepareOllama: prepareOllama ?? { _, context, _ in (.ready, context, false) },
            chatOllama: { _, _, _, _, _ in (nil, nil, nil) },
            unloadOllama: { _ in },
            keepAliveSeconds: { 30 },
            beginRequest: { _ in },
            endRequest: { _ in })
    }

    private static func httpResponse(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://127.0.0.1:9")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// A Local transport whose LM Studio send times out (NSURLErrorDomain / NSURLErrorTimedOut).
    private static func timeoutLocalTransport() -> LocalChatTransport {
        localTransport(send: { _, completion in
            completion(nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        })
    }

    /// A Local transport whose LM Studio send succeeds with one chat message and no tool calls, so the
    /// retrieval loop completes with zero collected results and proceeds to synthesis.
    private static func successLocalTransport() -> LocalChatTransport {
        let body = Data("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}".utf8)
        return localTransport(send: { _, completion in
            completion(body, httpResponse(), nil)
        })
    }

    /// A Local transport whose LM Studio send fails with a non-timeout transport error.
    private static func unavailableLocalTransport() -> LocalChatTransport {
        localTransport(send: { _, completion in
            completion(nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        })
    }

    /// A Local transport whose Ollama readiness refuses with `.capacityRefused(.overBudget)` before any
    /// Ollama chat, for the capacity-refusal-inside-the-request arm.
    private static func ollamaCapacityRefusalTransport() -> LocalChatTransport {
        localTransport(
            send: { _, completion in
                completion(nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
            },
            prepareOllama: { _, context, _ in
                (.capacityRefused(.overBudget), context, false)
            })
    }

    /// A genuine `NSURLErrorDomain` / `NSURLErrorTimedOut` error carrying the fired verdict (so the
    /// classifier decodes the limit) plus a stderr marker in its localized description.
    private static func timedOutError(
        verdict: LocalStreamStallPolicy.Verdict,
        policy: LocalStreamStallPolicy,
        stderr: String
    ) -> NSError {
        let seconds: TimeInterval = verdict == .ceiling ? policy.hardCeiling : policy.stallWindow
        let verdictName = verdict == .ceiling ? "ceiling" : "stall"
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            LocalStreamTimeoutDetail.verdictKey: verdictName,
            LocalStreamTimeoutDetail.secondsKey: seconds,
            NSLocalizedDescriptionKey: stderr,
        ])
    }

    private static func sourceContains(_ path: String, _ needle: String) -> Bool {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(needle)
    }

    /// Build a scripted `LocalAnswerDependencies` whose production defaults are replaced by fixtures.
    private static func localSearchDeps(
        retrievalModelID: String = "retrieval-fixture",
        retrievalTransport: LocalChatTransport,
        synthesisTransport: LocalChatTransport,
        synthesisResolution: @escaping (LLMRouteID) -> LLMRouteResolution,
        retrievalReadiness: @escaping (LocalModelRef) -> CleanupClient.Result? = { _ in nil }
    ) -> SearchClient.LocalAnswerDependencies {
        SearchClient.LocalAnswerDependencies(
            backendInstalled: { true },
            retrievalModelRef: { LocalModelRef(backend: .lmStudio, modelID: retrievalModelID) },
            retrievalReadiness: retrievalReadiness,
            synthesisResolution: synthesisResolution,
            prepareSynthesis: { _ in nil },
            retrievalTransport: retrievalTransport,
            webSearch: { _ in [] },
            synthesisTransport: synthesisTransport)
    }

    // MARK: - headless fixtures

    /// A headless HUD that records every `toast` message and no-ops the rest of `HUDPresenting`.
    private final class RecordingHUDPresenter: HUDPresenting {
        var toasts: [String] = []
        var onLock: (() -> Void)?
        var onStop: (() -> Void)?
        var onSettings: (() -> Void)?
        var samplesProvider: (() -> [Float])?
        var onSetLevel: ((Int) -> Void)?

        func show() {}
        func hide() {}
        func setTakeActive(_ active: Bool) {}
        func setRecoveryPending(takeID: UUID, pending: Bool) {}
        func setHotkeyMap(_ map: HotkeyMap) {}
        func flashModeBadge(glyph: String, label: String) {}
        func flashCleanupBadge(label: String) {}
        func setThinking(_ on: Bool) {}
        func setCleanup(enabled: Bool, level: Int) {}
        func setArmedMode(glyph: String?) {}
        func setBullseyeArmed(_ armed: Bool) {}
        func update(state: String, target: String?, text: String, locked: Bool) {}
        func toast(_ message: String, duration: TimeInterval, forceFull: Bool, action: (() -> Void)?) {
            toasts.append(message)
        }
        func answer(_ text: String) {}
    }

    /// A headless `OneShotContext` that returns the recording HUD and no-ops/nil for everything else.
    /// It names the module's own types but never constructs an AppKit object.
    private final class FakeOneShotContext: OneShotContext {
        let hud: HUDPresenting
        var readyHint: String = "ready"
        var stateLabel: String = "idle"
        var levelPickerActive: Bool = false
        var takeHasSpeech: Bool = false
        var currentTakeGeneration: Int = 0
        var onOpenSearchResultNote: ((String, String) -> Void)?
        var targetLabel: String = "Test"

        init(hud: HUDPresenting) { self.hud = hud }

        func note(_ s: String) {}
        func discardIncidentalAudio() {}
        func rejectOneShotIfBusy(_ label: String) -> Bool { false }
        func landInPlaceTransform(_ result: CleanupClient.Result, input: String, mode: HistoryMode,
                                  level: Int?, wireUndo: Bool, uiNoun: String, logNoun: String,
                                  levelLabel: String?, inputSource: NotesBullseyeLogic.InputSource,
                                  noteTarget: NotesDictationTarget?,
                                  foreignTarget: DictationTarget?, historyID: UUID?,
                                  lateRecovery: Bool) {}
        func finalizeTakeAndTranscribe(noteLabel: String,
                                       completion: @escaping (String?, String?, UUID, Bool) -> Void) {}
        func retryRetainedTake(takeID: UUID, retentionWasEnabled: Bool, generation: Int,
                               completion: @escaping (RetainedTakeRecoveryResult) -> Void) {}
        func markTakeConsumed() {}
        func showReplaceHighlight(level: String) -> String? { nil }
        func updateReplaceHighlight(noteId: String, level: String) {}
        func clearReplaceHighlight(noteId: String) {}
        func authoritativeNoteTargetForGesture() -> NotesDictationTarget? { nil }
        func authoritativeForeignTargetForGesture() -> DictationTarget? { nil }
    }

    /// Keeps the HUD, the fake context and the registry alive together. `OneShotRegistry` stores its
    /// context `unowned`, so the caller must retain the context for the life of the registry.
    private final class SearchHarness {
        let hud = RecordingHUDPresenter()
        let context: FakeOneShotContext
        let registry: OneShotRegistry

        init() {
            context = FakeOneShotContext(hud: hud)
            registry = OneShotRegistry(context: context)
        }

        func seam(_ mode: OneShotRegistry.Mode) -> OneShotRegistry.SearchRunSeam {
            registry.searchRunSeamForTest(mode: mode)
        }
    }

    // MARK: - new behaviour

    private static func checkOverBudgetNamesModel(_ reporter: SelfTestReporter) {
        let box = LocalStreamTimeoutDetail()
        box.modelID = "qwen3-coder:30b"
        let shown = TextTransformClient.safeFailurePresentation(
            for: .unavailable(CleanupClient.overBudgetMessage),
            timeoutDetail: box)!.userMessage
        reporter.record(
            "capacity-wording: new: over-budget names the model",
            shown == "qwen3-coder:30b does not fit in the memory free right now. Try a smaller model.",
            shown)
    }

    private static func checkOverBudgetEmptyModelID(_ reporter: SelfTestReporter) {
        // Pair an empty model id with a NON-empty id, so the row proves the NEW behaviour: empty
        // keeps the old sentence while non-empty names the model.
        func render(modelID: String) -> String {
            let box = LocalStreamTimeoutDetail()
            box.modelID = modelID
            return TextTransformClient.safeFailurePresentation(
                for: .unavailable(CleanupClient.overBudgetMessage),
                timeoutDetail: box)!.userMessage
        }
        let empty = render(modelID: "")
        let named = render(modelID: "qwen3-coder:30b")
        reporter.record(
            "capacity-wording: new: over-budget with empty model id keeps the old sentence",
            empty == CleanupClient.overBudgetMessage
                && named == "qwen3-coder:30b does not fit in the memory free right now. Try a smaller model."
                && empty != named,
            "empty=\(empty) named=\(named)")
    }

    private static func checkNoProviderText(_ reporter: SelfTestReporter) {
        // The capacity seam interpolates only the bundle model id into fixed words: there is no
        // channel for provider body/stderr text. Use a marker as the model id and require the shown
        // sentence to be exactly the fixed template and nothing else.
        let marker = "VDMARKER-\(UUID().uuidString)"
        let box = LocalStreamTimeoutDetail()
        box.modelID = marker
        let shown = TextTransformClient.safeFailurePresentation(
            for: .unavailable(CleanupClient.overBudgetMessage),
            timeoutDetail: box)!.userMessage
        let expected = "\(marker) does not fit in the memory free right now. Try a smaller model."
        reporter.record(
            "capacity-wording: new: no provider text",
            shown == expected,
            shown)
    }

    // MARK: - search-timeout new rows

    private static func searchTimeoutToast(modelID: String) -> String {
        "⚠️ Search: \(TextTransformClient.timeoutSentence(modelID: modelID, limit: .unknown)) — no answer inserted."
    }

    private static func checkSearchTimeoutOptionLSynthesisNamesModel(_ reporter: SelfTestReporter) {
        let harness = SearchHarness()
        let seam = harness.seam(.searchLocal)
        let model = "synth-model-A"
        let dependencies = localSearchDeps(
            retrievalTransport: successLocalTransport(),
            synthesisTransport: timeoutLocalTransport(),
            synthesisResolution: { _ in .pinned(.local(model)) })
        let result = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seam.timeoutDetail, dependencies: dependencies)
        seam.landNonDestructive(result, "fixture question", nil)
        reporter.record(
            "search-timeout: new: Option+L synthesis timeout names the synthesis model",
            harness.hud.toasts.last == searchTimeoutToast(modelID: model),
            harness.hud.toasts.last ?? "nil")
    }

    private static func checkSearchTimeoutOptionGSynthesisNamesModel(_ reporter: SelfTestReporter) {
        let harness = SearchHarness()
        let seam = harness.seam(.searchGemini)
        let model = "synth-model-B"
        let dependencies = SearchClient.GeminiAnswerDependencies(
            resolveKey: { "fixture-key" },
            synthesisResolution: { .pinned(.local(model)) },
            capacityPrecheck: { _ in nil },
            grounded: { _, _ in ("fixture grounded answer", nil) },
            prepareSynthesis: { _ in nil },
            synthesisTransport: timeoutLocalTransport())
        let result = SearchClient.geminiAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seam.timeoutDetail, dependencies: dependencies)
        seam.landNonDestructive(result, "fixture question", nil)
        reporter.record(
            "search-timeout: new: Option+G synthesis timeout names the synthesis model",
            harness.hud.toasts.last == searchTimeoutToast(modelID: model),
            harness.hud.toasts.last ?? "nil")
    }

    private static func checkSearchTimeoutOptionLRetrievalNamesModel(_ reporter: SelfTestReporter) {
        let harness = SearchHarness()
        let seam = harness.seam(.searchLocal)
        let model = "retrieval-fixture"
        let dependencies = localSearchDeps(
            retrievalModelID: model,
            retrievalTransport: timeoutLocalTransport(),
            synthesisTransport: successLocalTransport(),
            synthesisResolution: { _ in .pinned(.local("synth-fixture")) })
        let result = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seam.timeoutDetail, dependencies: dependencies)
        seam.landNonDestructive(result, "fixture question", nil)
        reporter.record(
            "search-timeout: new: Option+L retrieval timeout names the retrieval model",
            harness.hud.toasts.last == searchTimeoutToast(modelID: model),
            harness.hud.toasts.last ?? "nil")
    }

    private static func checkSearchTimeoutRetryNamesRetryModel(_ reporter: SelfTestReporter) {
        let harness = SearchHarness()
        let seam = harness.seam(.searchLocal)
        let firstModel = "first-attempt-model"
        let retryModel = "retry-model-B"
        let dependencies = localSearchDeps(
            retrievalTransport: successLocalTransport(),
            synthesisTransport: timeoutLocalTransport(),
            synthesisResolution: { _ in .pinned(.local(firstModel)) })

        let retrySemaphore = DispatchSemaphore(value: 0)
        var retryToast: String?
        let retryCompletion: (CleanupClient.Result) -> Void = { result in
            seam.landNonDestructive(result, "fixture question", nil)
            retryToast = harness.hud.toasts.last
            retrySemaphore.signal()
        }

        let firstResult = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: retryCompletion,
            timeoutDetail: seam.timeoutDetail, dependencies: dependencies)
        seam.landNonDestructive(firstResult, "fixture question", nil)

        // Pump the main run loop so the retry center's main-async capture runs. Loop in small slices:
        // the capture is enqueued from the transform's background completion and must be observed
        // before the retry can be confirmed.
        let deadline = Date().addingTimeInterval(1.0)
        while TextTransformRetryCenter.shared.summary == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let summary = TextTransformRetryCenter.shared.summary else {
            reporter.record("search-timeout: new: retry timeout names the retry model", false,
                            "no retry summary armed")
            return
        }
        guard TextTransformRetryCenter.shared.retry(
            summaryID: summary.id, explicitlyUsing: .local(retryModel)) else {
            reporter.record("search-timeout: new: retry timeout names the retry model", false,
                            "retry() returned false")
            return
        }
        _ = retrySemaphore.wait(timeout: .now() + 5)
        reporter.record(
            "search-timeout: new: retry timeout names the retry model",
            retryToast == searchTimeoutToast(modelID: retryModel),
            retryToast ?? "nil")
    }

    // MARK: - search-timeout guards

    private static func checkSearchTimeoutGeminiGroundingStaysGeneric(_ reporter: SelfTestReporter) {
        let harness = SearchHarness()
        let seam = harness.seam(.searchGemini)
        let dependencies = SearchClient.GeminiAnswerDependencies(
            resolveKey: { "fixture-key" },
            synthesisResolution: { .pinned(.local("synth-fixture")) },
            capacityPrecheck: { _ in nil },
            grounded: { _, _ in ("", .timedOut) },
            prepareSynthesis: { _ in nil },
            synthesisTransport: successLocalTransport())
        let result = SearchClient.geminiAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seam.timeoutDetail, dependencies: dependencies)
        seam.landNonDestructive(result, "fixture question", nil)
        let expected = "⚠️ Search: Selected provider timed out — no answer inserted."
        reporter.record(
            "search-timeout: guard: Gemini grounding timeout stays generic",
            harness.hud.toasts.last == expected,
            harness.hud.toasts.last ?? "nil")
    }

    private static func checkSearchCapacitySentencesUnchanged(_ reporter: SelfTestReporter) {
        let overBudget = CleanupClient.overBudgetMessage
        let expected = "⚠️ Search: \(overBudget) — no answer inserted."

        // (a) Early-out refusal: retrieval readiness returns the base over-budget sentence before any
        // request runs.
        let harnessA = SearchHarness()
        let seamA = harnessA.seam(.searchLocal)
        let depsA = localSearchDeps(
            retrievalTransport: successLocalTransport(),
            synthesisTransport: successLocalTransport(),
            synthesisResolution: { _ in .pinned(.local("synth-fixture")) },
            retrievalReadiness: { _ in .unavailable(overBudget) })
        let resultA = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seamA.timeoutDetail, dependencies: depsA)
        seamA.landNonDestructive(resultA, "fixture question", nil)

        // (b) Capacity refusal returned INSIDE the synthesis request after dispatch labelled the box:
        // an Ollama bundle whose transport refuses `.capacityRefused(.overBudget)`.
        let harnessB = SearchHarness()
        let seamB = harnessB.seam(.searchLocal)
        let ollamaBundle = LLMProviderBundle.local(
            ref: LocalModelRef(backend: .ollama, modelID: "ollama-synth-fixture"))
        let depsB = localSearchDeps(
            retrievalTransport: successLocalTransport(),
            synthesisTransport: ollamaCapacityRefusalTransport(),
            synthesisResolution: { _ in .pinned(ollamaBundle) })
        let resultB = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seamB.timeoutDetail, dependencies: depsB)
        seamB.landNonDestructive(resultB, "fixture question", nil)

        reporter.record(
            "search-timeout: guard: search capacity sentences unchanged",
            harnessA.hud.toasts.last == expected && harnessB.hud.toasts.last == expected,
            "earlyOut=\(harnessA.hud.toasts.last ?? "nil") inRequest=\(harnessB.hud.toasts.last ?? "nil")")
    }

    private static func checkSearchNonTimeoutFailuresUnchanged(_ reporter: SelfTestReporter) {
        let harness = SearchHarness()
        let seam = harness.seam(.searchLocal)
        let dependencies = localSearchDeps(
            retrievalTransport: successLocalTransport(),
            synthesisTransport: unavailableLocalTransport(),
            synthesisResolution: { _ in .pinned(.local("synth-fixture")) })
        let result = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seam.timeoutDetail, dependencies: dependencies)
        seam.landNonDestructive(result, "fixture question", nil)
        let expected = "⚠️ Search: Selected provider is unavailable — no answer inserted."
        reporter.record(
            "search-timeout: guard: non-timeout search failures unchanged",
            harness.hud.toasts.last == expected,
            harness.hud.toasts.last ?? "nil")
    }

    private static func checkSearchFailureLogLineUnchanged(_ reporter: SelfTestReporter) {
        let localLine = OneShotRegistry.searchFailureLogLine(for: .timedOut, mode: .searchLocal)
        let geminiLine = OneShotRegistry.searchFailureLogLine(for: .timedOut, mode: .searchGemini)
        let expectedLocal = "search fallback classification=timedOut - search"
        let expectedGemini = "search fallback classification=timedOut - Gemini search"
        reporter.record(
            "search-timeout: guard: search failure log line unchanged and names no model",
            localLine == expectedLocal && geminiLine == expectedGemini
                && !localLine.contains("model") && !geminiLine.contains("model"),
            "local=\(localLine) gemini=\(geminiLine)")
    }

    private static func checkSearchNewRunNeverShowsEarlierModel(_ reporter: SelfTestReporter) {
        let firstModel = "first-run-model"

        // Run 1: the real pipeline labels run 1's own box with `firstModel` (after the fix); landing
        // run 1 exercises that path. Its toast is not the assertion here — run 2's is.
        let harness1 = SearchHarness()
        let seam1 = harness1.seam(.searchLocal)
        let dependencies1 = localSearchDeps(
            retrievalTransport: successLocalTransport(),
            synthesisTransport: timeoutLocalTransport(),
            synthesisResolution: { _ in .pinned(.local(firstModel)) })
        let result1 = SearchClient.localAnswerSync(
            question: "fixture question", retryCompletion: nil,
            timeoutDetail: seam1.timeoutDetail, dependencies: dependencies1)
        seam1.landNonDestructive(result1, "fixture question", nil)

        // Run 2: take the seam from run 1's harness (same OneShotRegistry) so a registry-level leak is
        // caught. A `.timedOut` landing must stay generic and must not show run 1's model.
        let seam2 = harness1.seam(.searchLocal)
        seam2.landNonDestructive(.timedOut, "fixture question", nil)

        let expected = "⚠️ Search: Selected provider timed out — no answer inserted."
        reporter.record(
            "search-timeout: guard: a new run never shows an earlier run's model",
            harness1.hud.toasts.last == expected
                && harness1.hud.toasts.last != searchTimeoutToast(modelID: firstModel),
            "run2 toast=\(harness1.hud.toasts.last ?? "nil")")
    }

    // MARK: - guards

    private static func checkConstantsByteIdentical(_ reporter: SelfTestReporter) {
        let overBudget = CleanupClient.overBudgetMessage
        let facts = CleanupClient.memoryFactsUnavailableMessage
        let refusalOverBudget = CleanupClient.capacityRefusalMessage(
            for: .unavailable(CleanupClient.overBudgetMessage))
        let refusalFacts = CleanupClient.capacityRefusalMessage(
            for: .unavailable(CleanupClient.memoryFactsUnavailableMessage))
        reporter.record(
            "capacity-wording: guard: constants byte-identical",
            overBudget == "Not enough space in RAM. Adjust local model settings under the Setup tab."
                && facts == "Memory facts could not be read, so the model was not loaded."
                && refusalOverBudget == CleanupClient.overBudgetMessage
                && refusalFacts == CleanupClient.memoryFactsUnavailableMessage,
            "overBudget=\(overBudget) facts=\(facts)")
    }

    private static func checkFactsSentenceUnchanged(_ reporter: SelfTestReporter) {
        // The memory-facts sentence must stay unchanged even with a non-empty model id.
        let box = LocalStreamTimeoutDetail()
        box.modelID = "qwen3-coder:30b"
        let shown = TextTransformClient.safeFailurePresentation(
            for: .unavailable(CleanupClient.memoryFactsUnavailableMessage),
            timeoutDetail: box)!.userMessage
        reporter.record(
            "capacity-wording: guard: facts sentence unchanged",
            shown == CleanupClient.memoryFactsUnavailableMessage,
            shown)
    }

    private static func checkSourceShapeRequestBuilders(_ reporter: SelfTestReporter) {
        // The custom-mode request builder must pass `timeoutDetail:` into the TextTransformRequest it
        // constructs. It is the single `TextTransformRequest(` call in its file, so find that call and
        // require the label inside its argument list.
        let files = [
            "Sources/App/CustomModeClient.swift",
        ]
        var failures: [String] = []
        for path in files {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(path, isDirectory: false)
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if source.isEmpty {
                failures.append("\(path): unreadable")
                continue
            }
            let compact = source.components(separatedBy: .whitespacesAndNewlines).joined()
            let needle = "TextTransformRequest("
            guard let range = compact.range(of: needle) else {
                failures.append("\(path): no TextTransformRequest(")
                continue
            }
            let open = compact.index(range.lowerBound, offsetBy: "TextTransformRequest".count)
            var depth = 0
            var close = open
            var scan = open
            while scan < compact.endIndex {
                let ch = compact[scan]
                if ch == "(" { depth += 1 }
                else if ch == ")" {
                    depth -= 1
                    if depth == 0 { close = scan; break }
                }
                scan = compact.index(after: scan)
            }
            let call = compact[range.lowerBound...close]
            if !call.contains("timeoutDetail:") {
                failures.append("\(path): TextTransformRequest( missing timeoutDetail:")
            }
        }
        reporter.record(
            "capacity-wording: guard: request builders pass timeoutDetail",
            failures.isEmpty,
            failures.joined(separator: "; "))
    }
}
