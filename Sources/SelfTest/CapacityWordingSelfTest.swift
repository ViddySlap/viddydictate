import Foundation

/// Capacity wording (`--capacity-wording-selftest`): a RAM-capacity refusal must name the bundle
/// model, and the search timeouts must stay generic (the dictation toasts already name the model).
/// Pure: no AppKit, no store, no socket, no model. The `new:` rows drive a real production seam —
/// the presentation seam or `SearchClient.localSynthesis` over a scripted `LocalChatTransport` — and
/// the `guard:` rows pin the byte-identical constants, the unchanged memory-facts sentence, and the
/// source shape that carries `timeoutDetail` into the custom-mode request builder.
enum CapacityWordingSelfTest {
    static func run() -> Bool {
        print("=== Capacity wording selftest ===")
        let reporter = SelfTestReporter()

        checkOverBudgetNamesModel(reporter)
        checkOverBudgetEmptyModelID(reporter)
        checkNoProviderText(reporter)
        checkSearchTimeoutsStayGeneric(reporter)
        checkConstantsByteIdentical(reporter)
        checkFactsSentenceUnchanged(reporter)
        checkSourceShapeRequestBuilders(reporter)

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

    private static func checkSearchTimeoutsStayGeneric(_ reporter: SelfTestReporter) {
        // The intentional residual: Option+L / Option+G timeouts must stay generic now that the
        // search path no longer carries the timeout-detail box. Drive the search presentation seam
        // with a stall timeout AND a ceiling timeout and assert the fixed generic sentence.
        let policy = LocalStreamStallPolicy(stallWindow: 12)
        let request = SearchClient.makeSynthesisRequest(
            route: .searchLocalSynth, question: "q", resultsBlock: "r",
            selected: .local("qwen3-coder:30b"), systemPrompt: "s",
            timeout: policy.hardCeiling)
        let box = LocalStreamTimeoutDetail()

        func rendered(_ verdict: LocalStreamStallPolicy.Verdict) -> String {
            let result = SearchClient.localSynthesis(
                request,
                transport: synthesisTimeoutTransport(
                    timedOutError(verdict: verdict, policy: policy, stderr: "fixture")))
            return OneShotRegistry.failurePresentation(for: result, timeoutDetail: box)!.userMessage
        }

        let ceiling = rendered(.ceiling)
        let stall = rendered(.stalled)
        let generic = TextTransformRetryDescriptor.Failure.timedOut.userMessage
        reporter.record(
            "capacity-wording: new: search timeouts stay generic",
            ceiling == generic && stall == generic,
            "ceiling=\(ceiling) stall=\(stall)")
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
