import Foundation

/// Timeout wording (`--timeout-wording-selftest`): a local-model timeout must say WHICH model timed out
/// and WHICH limit fired. The stall-based streaming sender (`LocalStreamSender`) already knows the
/// verdict (`.stalled` vs `.ceiling`) and reports it as the same `URLError.timedOut`; the new wording
/// is carried beside the result in a `LocalStreamTimeoutDetail` box on the request, never inside the
/// provider's response text.
///
/// Pure: no AppKit, no store, no socket, no model. Rows 1-6 assert the new behaviour (RED by assertion
/// on today's generic sentence, which the stubs reproduce); rows 7-8 guard the `Failure` raw values and
/// the unchanged capacity/other sentences.
enum TimeoutWordingSelfTest {
    static func run() -> Bool {
        print("=== Timeout wording selftest ===")
        let reporter = SelfTestReporter()

        checkCeilingSentence(reporter)
        checkStallSentence(reporter)
        checkUnknownLimitSentence(reporter)
        checkEmptyModelID(reporter)
        checkNoProviderText(reporter)
        checkRealSenderPath(reporter)
        checkSourceShapeNoUnlabelledCall(reporter)
        checkOneShotSite(reporter)
        checkFailureRawValues(reporter)
        checkOtherSentences(reporter)

        print(reporter.passed
            ? "[timeout-wording-selftest] PASS"
            : "[timeout-wording-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - new behaviour

    private static func checkCeilingSentence(_ reporter: SelfTestReporter) {
        let sentence = TextTransformClient.timeoutSentence(
            modelID: "qwen3-coder:30b", limit: .ceiling(seconds: 45))
        reporter.record(
            "timeout-wording: new: ceiling verdict",
            sentence == "qwen3-coder:30b timed out after 45 seconds. It may be too slow for this task. Try a different model.",
            sentence)
    }

    private static func checkStallSentence(_ reporter: SelfTestReporter) {
        let sentence = TextTransformClient.timeoutSentence(
            modelID: "qwen3-coder:30b", limit: .stall(seconds: 12))
        reporter.record(
            "timeout-wording: new: stall verdict",
            sentence == "qwen3-coder:30b stopped responding for 12 seconds. Try a different model.",
            sentence)
    }

    private static func checkUnknownLimitSentence(_ reporter: SelfTestReporter) {
        let sentence = TextTransformClient.timeoutSentence(
            modelID: "qwen3-coder:30b", limit: .unknown)
        reporter.record(
            "timeout-wording: new: unknown limit",
            sentence == "qwen3-coder:30b timed out. It may be too slow for this task. Try a different model.",
            sentence)
    }

    private static func checkEmptyModelID(_ reporter: SelfTestReporter) {
        // Pair an empty model id with a NON-empty id of the SAME detail/limit, so the row proves the
        // NEW behaviour: empty falls back to today's generic sentence while non-empty names the model.
        func render(modelID: String) -> String {
            let box = LocalStreamTimeoutDetail()
            box.modelID = modelID
            box.limit = .ceiling(seconds: 45)
            let request = TextTransformRequest(
                route: .cleanupL1, bundle: .local(modelID), sourceText: "",
                systemPrompt: "", userMessage: "", timeout: 45,
                timeoutDetail: box)
            let descriptor = TextTransformClient.retryDescriptor(
                for: request, after: .timedOut)!
            return descriptor.safeFailureText
        }
        let empty = render(modelID: "")
        let named = render(modelID: "qwen3-coder:30b")
        reporter.record(
            "timeout-wording: new: empty model id",
            empty == "Selected provider timed out"
                && named == "qwen3-coder:30b timed out after 45 seconds. It may be too slow for this task. Try a different model."
                && empty != named,
            "empty=\(empty) named=\(named)")
    }

    private static func checkNoProviderText(_ reporter: SelfTestReporter) {
        // The `.timedOut` Result carries no provider payload; a provider body/stderr that echoes the
        // marker must have nowhere to leak into the shown sentence.
        let marker = "VDMARKER-\(UUID().uuidString)"
        let body = Data("provider body echo \(marker)".utf8)
        let stderr = "provider stderr echo \(marker)"
        let box = LocalStreamTimeoutDetail()
        box.modelID = "qwen3-coder:30b"
        box.limit = .unknown
        let shown = TextTransformClient.safeFailurePresentation(
            for: .timedOut, timeoutDetail: box)!.userMessage
        _ = (body, stderr)
        reporter.record(
            "timeout-wording: new: no provider text",
            !shown.contains(marker)
                && shown == "qwen3-coder:30b timed out. It may be too slow for this task. Try a different model.",
            shown)
    }

    private static func checkRealSenderPath(_ reporter: SelfTestReporter) {
        // Drive the REAL stall clock and the production carrier: verdict -> URLError with verdict
        // userInfo -> CleanupClient classification (which decodes the limit into the request box) ->
        // retry descriptor -> safeFailurePresentation. The row never formats a sentence itself.
        let policy = LocalStreamStallPolicy(stallWindow: 10)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = LocalStreamProgressClock(policy: policy, startedAt: t0)

        func rendered(for verdict: LocalStreamStallPolicy.Verdict)
            -> (shown: String, descriptor: String) {
            let box = LocalStreamTimeoutDetail()
            box.modelID = "qwen3-coder:30b"
            let error = LocalStreamStallPolicy.timedOutError(verdict: verdict, policy: policy)
            let classification = CleanupClient.classifyChatResponse(
                data: nil, response: nil, error: error,
                logPrefix: "timeout-wording", elapsed: 0, timeoutDetail: box)
            let result: CleanupClient.Result
            switch classification {
            case .content:
                result = .ok("unreachable")
            case .failure(let r):
                result = r
            }
            let request = TextTransformRequest(
                route: .cleanupL1, bundle: .local("qwen3-coder:30b"),
                sourceText: "", systemPrompt: "", userMessage: "",
                timeout: policy.hardCeiling, timeoutDetail: box)
            let descriptor = TextTransformClient.retryDescriptor(for: request, after: result)!
            let presentation = TextTransformClient.safeFailurePresentation(
                for: result, timeoutDetail: box)!
            return (presentation.userMessage, descriptor.safeFailureText)
        }

        let stallVerdict = clock.verdict(at: t0.addingTimeInterval(policy.stallWindow))
        let ceilingVerdict = clock.verdict(at: t0.addingTimeInterval(policy.hardCeiling))
        let stall = rendered(for: stallVerdict ?? .stalled)
        let ceiling = rendered(for: ceilingVerdict ?? .ceiling)
        let expectedStall = "qwen3-coder:30b stopped responding for \(Int(policy.stallWindow.rounded())) seconds. Try a different model."
        let expectedCeiling = "qwen3-coder:30b timed out after \(Int(policy.hardCeiling.rounded())) seconds. It may be too slow for this task. Try a different model."

        reporter.record(
            "timeout-wording: new: real sender path",
            stallVerdict == .stalled
                && ceilingVerdict == .ceiling
                && stall.shown == expectedStall
                && ceiling.shown == expectedCeiling
                && stall.shown != ceiling.shown
                && stall.descriptor == stall.shown
                && ceiling.descriptor == ceiling.shown,
            "stall=\(stall.shown) ceiling=\(ceiling.shown) stallDesc=\(stall.descriptor) ceilingDesc=\(ceiling.descriptor)")
    }

    private static func checkSourceShapeNoUnlabelledCall(_ reporter: SelfTestReporter) {
        // Source-shape guard (the picker arm's pattern): every production call to
        // safeFailurePresentation(for:) must pass timeoutDetail: explicitly. Multi-line calls are
        // normalized by removing whitespace so the needle and the timeoutDetail: label stay findable.
        let files = [
            "Sources/App/DictationController.swift",
            "Sources/App/OneShotRegistry.swift",
            "Sources/App/EmailClient.swift",
        ]
        let needle = "safeFailurePresentation(for:"
        let openParenOffset = "safeFailurePresentation".count
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
            var cursor = compact.startIndex
            var index = 0
            while let range = compact.range(of: needle, range: cursor..<compact.endIndex) {
                // Find the matching close paren of THIS call (the '(' sits inside the needle), so an
                // unrelated `timeoutDetail:` in a later function cannot mask an unlabelled call.
                let open = compact.index(range.lowerBound, offsetBy: openParenOffset)
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
                    failures.append("\(path) call #\(index) missing timeoutDetail:")
                }
                index += 1
                cursor = range.upperBound
            }
        }
        reporter.record(
            "timeout-wording: new: source shape no unlabelled call",
            failures.isEmpty,
            failures.joined(separator: "; "))
    }

    private static func checkOneShotSite(_ reporter: SelfTestReporter) {
        // Drive the real OneShotRegistry presentation seam with a fixture box: a one-shot timeout must
        // name the bundle model. No network, no store, no AppKit.
        let box = LocalStreamTimeoutDetail()
        box.modelID = "qwen3-coder:30b"
        box.limit = .stall(seconds: 12)
        let presentation = OneShotRegistry.failurePresentation(
            for: .timedOut, timeoutDetail: box)
        reporter.record(
            "timeout-wording: new: one-shot site",
            presentation?.userMessage
                == "qwen3-coder:30b stopped responding for 12 seconds. Try a different model.",
            presentation?.userMessage ?? "nil")
    }

    // MARK: - guards

    private static func checkFailureRawValues(_ reporter: SelfTestReporter) {
        let timedOut = TextTransformRetryDescriptor.Failure.timedOut
        let unavailable = TextTransformRetryDescriptor.Failure.unavailable
        let badOutput = TextTransformRetryDescriptor.Failure.badOutput
        reporter.record(
            "timeout-wording: guard: failure raw values",
            timedOut.logToken == "timedOut"
                && timedOut.rawValue == "timedOut"
                && unavailable.rawValue == "unavailable"
                && badOutput.rawValue == "badOutput",
            "timedOut=\(timedOut.rawValue) unavailable=\(unavailable.rawValue) badOutput=\(badOutput.rawValue)")
    }

    private static func checkOtherSentences(_ reporter: SelfTestReporter) {
        let unavailable = TextTransformClient.safeFailurePresentation(
            for: .unavailable("x"), timeoutDetail: nil)!.userMessage
        let badOutput = TextTransformClient.safeFailurePresentation(
            for: .badOutput("x"), timeoutDetail: nil)!.userMessage
        let overBudget = TextTransformClient.safeFailurePresentation(
            for: .unavailable(CleanupClient.overBudgetMessage), timeoutDetail: nil)!.userMessage
        let memoryFacts = TextTransformClient.safeFailurePresentation(
            for: .unavailable(CleanupClient.memoryFactsUnavailableMessage), timeoutDetail: nil)!.userMessage
        reporter.record(
            "timeout-wording: guard: other sentences",
            unavailable == "Selected provider is unavailable"
                && badOutput == "Selected provider returned unusable output"
                && overBudget == CleanupClient.overBudgetMessage
                && memoryFacts == CleanupClient.memoryFactsUnavailableMessage,
            "unavailable=\(unavailable) badOutput=\(badOutput) overBudget=\(overBudget) memoryFacts=\(memoryFacts)")
    }
}
