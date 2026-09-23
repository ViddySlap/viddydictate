import Foundation

/// RTY1's retry, graded END TO END through the seam production actually dispatches on.
///
/// `ModelFitSelfTest`'s `retry` arm proves the pure policy: given a capacity refusal, a second
/// `resolveRoute` returns a different installed model. It could not prove the thing that made the
/// friend's Mac paste raw text, because nothing in production ever asked for that second resolve. This
/// arm drives `TextTransformClient.transformResolved` with the exact `capacityStepDown` closure
/// `DictationController` now builds, over stub adapters, and asserts on WHICH model ids reach the
/// adapter and HOW MANY TIMES.
///
/// Deliberately a separate file and a separate flag: `ModelFitSelfTest` is protected by chain `vdfit`
/// and is not edited here.
///
/// No capacity facts are injected anywhere below. `ModelsPowerSettingsStore.resolveRoute` reads live
/// machine memory, which differs between a 16 GB mini and this machine, so every case here turns on
/// EXCLUSION and on catalog membership only. That keeps the arm's verdict identical on any Mac.
enum ModelFitRetryWiringSelfTest {

    private static let qwenID = LLMProviderDefaults.localCleanupModelID
    private static let gemmaID = LLMProviderDefaults.localEmailModelID
    private static let route = LLMRouteID.cleanupL1

    private static func freshStore() -> ModelsPowerSettingsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-modelfit-wiring-\(UUID().uuidString).json")
        return ModelsPowerSettingsStore(url: url, legacy: .empty)
    }

    private static func store(installed: [String]) -> ModelsPowerSettingsStore {
        let s = freshStore()
        s.setLocalAvailabilityState(.available, models: installed.map {
            LMStudioModelOption(modelID: $0, label: $0)
        })
        return s
    }

    /// The step-down closure exactly as `DictationController.deliver` builds it: re-resolve the same
    /// route, marking Local failed with the app-authored over-budget sentence, and naming the model that
    /// ACTUALLY RAN rather than the pin.
    private static func stepDown(
        for store: ModelsPowerSettingsStore
    ) -> TextTransformClient.CapacityStepDown {
        { ranModelID in
            store.resolveRoute(route, fallback: .local(qwenID),
                               failedProviders: [.local: CleanupClient.overBudgetMessage],
                               failedLocalModelID: ranModelID)
        }
    }

    private static func request(_ bundle: LLMProviderBundle) -> TextTransformRequest {
        TextTransformRequest(route: route, bundle: bundle, sourceText: "raw take",
                             systemPrompt: "system", userMessage: "raw take", timeout: 5)
    }

    /// Run one dispatch through the production seam and report every model id the local adapter saw, in
    /// order, plus the single result the caller's landing closure received. `refusing` names the models
    /// the stub answers with the over-budget sentence; anything else succeeds.
    private static func dispatch(
        store: ModelsPowerSettingsStore,
        refusing: Set<String>,
        otherFailure: CleanupClient.Result? = nil,
        wired: Bool = true
    ) -> (seen: [String], result: CleanupClient.Result) {
        var seen: [String] = []
        var landed: CleanupClient.Result = .unavailable("no result")
        let resolution = store.resolveRoute(route, fallback: .local(qwenID))
        let semaphore = DispatchSemaphore(value: 0)
        TextTransformClient.transformResolved(
            resolution, route: route, requestForBundle: request,
            local: { req, done in
                seen.append(req.bundle.modelID)
                if let otherFailure {
                    done(otherFailure)
                } else if refusing.contains(req.bundle.modelID) {
                    done(.unavailable(CleanupClient.overBudgetMessage))
                } else {
                    done(.ok("cleaned"))
                }
            },
            // `.inert` keeps the shared retry center out of this arm: an armed dispatch mutates a
            // process-wide singleton, and what is under test here is the step-down, not retry arming.
            arming: .inert,
            capacityStepDown: wired ? stepDown(for: store) : nil,
            completion: { landed = $0; semaphore.signal() })
        _ = semaphore.wait(timeout: .now() + 10)
        return (seen, landed)
    }

    static func run() -> Int32 {
        print("=== ViddyDictate modelfit — retry-wiring arm ===")
        Settings.registerDefaults()
        let reporter = SelfTestReporter()

        // 1. The friend's case, end to end. Both models installed, the pin is the oversized one, and the
        //    load refuses it. Production must land cleaned text off the smaller model, not raw.
        let both = store(installed: [qwenID, gemmaID])
        let steppedDown = dispatch(store: both, refusing: [qwenID])
        reporter.record(
            "a capacity refusal re-dispatches once, on a DIFFERENT installed model",
            steppedDown.seen == [qwenID, gemmaID], "adapter saw=\(steppedDown.seen)")
        var landedOK = false
        if case .ok = steppedDown.result { landedOK = true }
        reporter.record(
            "the caller's landing closure sees the second attempt's success, and only it",
            landedOK, "result=\(steppedDown.result)")

        // 2. The same fixture with the wiring absent. This is the arm's negative control: it fails if
        //    someone removes `capacityStepDown` from the cleanup call site, which is exactly the state
        //    this whole item existed to leave behind.
        let unwired = dispatch(store: store(installed: [qwenID, gemmaID]), refusing: [qwenID],
                               wired: false)
        reporter.record(
            "without the step-down the same refusal dispatches once and falls to the raw transcript",
            unwired.seen == [qwenID], "adapter saw=\(unwired.seen)")

        // 3. `failedLocalModelID` plumbing. When the pin is not installed, routing already substituted,
        //    so the model that refused is NOT the pin. Keying the step-down on the pin re-offers the
        //    model that just failed; keying it on what ran does not. Measured both ways in one session.
        let substituted = store(installed: [gemmaID])
        let firstRan = substituted.resolveRoute(route, fallback: .local(qwenID)).bundle?.modelID
        reporter.record(
            "with the pin absent, the first attempt runs a SUBSTITUTE, not the pin (fixture sanity)",
            firstRan == gemmaID, "ran=\(firstRan ?? "nil")")
        let blamingThePin = substituted.resolveRoute(
            route, fallback: .local(qwenID),
            failedProviders: [.local: CleanupClient.overBudgetMessage])
        reporter.record(
            "blaming the pin would re-offer the very model that just refused (the trap being closed)",
            blamingThePin.bundle?.modelID == gemmaID, "resolution=\(blamingThePin)")
        let blamingWhatRan = substituted.resolveRoute(
            route, fallback: .local(qwenID),
            failedProviders: [.local: CleanupClient.overBudgetMessage],
            failedLocalModelID: gemmaID)
        reporter.record(
            "naming the model that actually ran never re-offers it",
            blamingWhatRan.bundle?.modelID != gemmaID, "resolution=\(blamingWhatRan)")

        // 4. Nothing else installed: one dispatch, and the byte-exact refusal sentence still reaches the
        //    caller, which is what makes the raw transcript land.
        let nothingElse = dispatch(store: store(installed: [gemmaID]), refusing: [gemmaID])
        reporter.record(
            "when no other model is installed the step-down declines and does not re-dispatch",
            nothingElse.seen == [gemmaID], "adapter saw=\(nothingElse.seen)")
        var refusalSentence: String?
        if case .unavailable(let reason) = nothingElse.result { refusalSentence = reason }
        reporter.record(
            "the over-budget sentence still reaches the caller byte-for-byte",
            refusalSentence == "Not enough space in RAM. Adjust local model settings under the Setup tab.",
            "got=\(refusalSentence ?? "nil")")

        // 5. Only a capacity refusal earns the step-down. A timeout or a bad output means the model RAN,
        //    so a smaller one answers nothing, and an ordinary unavailable is not a size problem.
        for (label, failure) in [
            ("a timeout", CleanupClient.Result.timedOut),
            ("a bad output", CleanupClient.Result.badOutput("empty")),
            ("an ordinary unavailable", CleanupClient.Result.unavailable("LM Studio is not running")),
        ] {
            let other = dispatch(store: store(installed: [qwenID, gemmaID]), refusing: [],
                                 otherFailure: failure)
            reporter.record(
                "\(label) does not re-dispatch onto another model",
                other.seen == [qwenID], "adapter saw=\(other.seen)")
        }

        checkCallSiteIsWired(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "retry-wiring"))
        return reporter.passed ? 0 : 1
    }

    /// Everything above proves the SEAM. It cannot prove the seam is still plugged in, because the arm
    /// supplies its own closure rather than reaching into a UI controller, so deleting the wiring at the
    /// cleanup call site would leave all of it green. That is the exact shape of the gap this whole item
    /// existed to close - correct code nothing calls - so the call site is asserted directly, the way
    /// `HangWatchdogSelfTest` asserts its own source rules. Reads code with comments stripped, because
    /// the comments at that call site name these very symbols while explaining them.
    private static func checkCallSiteIsWired(_ reporter: SelfTestReporter) {
        let path = "Sources/App/DictationController.swift"
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        reporter.record("the cleanup call site is readable from the worktree root", !source.isEmpty,
                        source.isEmpty ? "run this gate from the repository root" : path)
        guard !source.isEmpty else { return }
        let code = codeOnly(source)

        func rule(_ name: String, _ holds: Bool, _ why: String) {
            reporter.record(name, holds, holds ? "" : "BROKEN RULE: \(why) \(path)")
        }
        rule("the cleanup dispatch still passes capacityStepDown",
             code.contains("capacityStepDown: capacityStepDown"),
             "without this argument the step-down is dead code again and a capacity refusal on a "
                 + "small Mac goes straight to the raw transcript.")
        rule("the step-down blames the model that RAN, not the pin",
             code.contains("failedLocalModelID: ranModelID"),
             "routing substitutes a smaller model when the pin does not fit, so blaming the pin "
                 + "re-offers the model that just refused.")
        rule("the step-down marks Local failed with the app-authored over-budget sentence",
             code.contains("failedProviders: [.local: CleanupClient.overBudgetMessage]"),
             "that exact sentence is what localCapacityRefusal classifies on; any other reason "
                 + "keeps the route off.")
    }

    /// Strip `//` comments so a forbidden- or required-token rule reads code rather than prose. Line
    /// comments only: this file's rules never look for tokens that appear inside a block comment.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let i = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<i.lowerBound])
            }
            .joined(separator: "\n")
    }
}
