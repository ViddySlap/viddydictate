import Foundation

/// Prompt workstation Test-bench coverage (item W2): the sourcing rules, the provenance the panel
/// reports, what a test actually executes, and the wording of an outcome.
///
/// The positive case ("it ran and text came back") looks fine whether or not the bench leaks, so the
/// assertions that matter here are the negative and the boring ones: the walk-back never yields an
/// entry over the cap, an empty History yields an EMPTY field rather than a truncated take, a sample
/// edited on top of a History default stops claiming to be that default, a test executes the prompt
/// currently on screen rather than the stored one, and a failure is reported in the real path's own
/// three sentences rather than in new error text invented for this panel. That a run lands nowhere is
/// gated in the gui probe, where the real button can be pressed.
///
/// Every fixture is synthetic. No provider runs, no window opens, and no real history is read.
enum PromptTestBenchSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate prompt test bench - selftest ===")
        let reporter = SelfTestReporter()

        checkHistoryDefaultWalksBackToOneThatFits(reporter)
        checkNothingFittingStartsEmpty(reporter)
        checkFreeTextIsUncapped(reporter)
        checkSourceIsDerivedFromTheBytes(reporter)
        checkTheTestRunsWhatIsOnScreen(reporter)
        checkOutcomeUsesTheRealPathsWords(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Prompt test bench:"))
        print(reporter.passed ? "\nPROMPT TEST BENCH GREEN" : "\nPROMPT TEST BENCH FAILED")
        return reporter.passed
    }

    private static func entry(_ raw: String, at date: Date) -> TranscriptionHistory.Entry {
        TranscriptionHistory.Entry(id: UUID(), date: date, text: raw, app: "SelfTest",
                                   raw: raw, cleaned: nil, mode: HistoryMode.raw.rawValue, level: nil)
    }

    private static func synthetic(_ characters: Int) -> String {
        String(repeating: "a", count: characters)
    }

    /// The cap is a real number off the user's last hundred takes (median 190, p75 476, p90 925, max 2524),
    /// so the boundary is worth pinning exactly: 1000 fits, 1001 does not, and the walk continues to the
    /// newest entry that DOES rather than stopping at the first miss.
    private static func checkHistoryDefaultWalksBackToOneThatFits(_ r: SelfTestReporter) {
        r.record("the History cap is the measured 1000 characters",
                 PromptTestBench.historySampleCharacterLimit == 1000)

        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let fits = synthetic(925)      // p90 of the user's real distribution
        let entries = [
            entry(synthetic(2524), at: now),                     // newest, a monologue: skipped
            entry(synthetic(1001), at: now.addingTimeInterval(-60)),  // one over: skipped
            entry(fits, at: now.addingTimeInterval(-120)),       // the newest that fits
            entry(synthetic(190), at: now.addingTimeInterval(-180)),  // older and also fits: not chosen
        ]
        let seed = PromptTestBench.seed(from: entries)
        r.record("the default walks back to the newest entry that fits the cap",
                 seed.text == fits && seed.date == now.addingTimeInterval(-120))
        r.record("an entry over the cap is skipped, never truncated",
                 seed.text.count == 925)

        r.record("exactly 1000 characters fits",
                 PromptTestBench.seed(from: [entry(synthetic(1000), at: now)]).text.count == 1000)
        r.record("exactly 1001 characters does not",
                 PromptTestBench.seed(from: [entry(synthetic(1001), at: now)]) == .none)

        // The stored `raw` is what a prompt is tuned against, not the delivered text: a cleanup take's
        // delivered text is the model's output, which would make the bench test a transform of a
        // transform.
        let dual = TranscriptionHistory.Entry(
            id: UUID(), date: now, text: "Cleaned up output.", app: "SelfTest",
            raw: "um the raw dictation as spoken", cleaned: "Cleaned up output.",
            mode: HistoryMode.cleanup.rawValue, level: 1)
        r.record("the sample is the RAW transcript, not the delivered text",
                 PromptTestBench.seed(from: [dual]).text == "um the raw dictation as spoken")
    }

    /// The failure posture. Nothing fitting means an EMPTY field: a truncated entry would silently
    /// change what the prompt is being judged on, and a half-sentence is the worst possible sample.
    private static func checkNothingFittingStartsEmpty(_ r: SelfTestReporter) {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        r.record("an empty History starts the field empty",
                 PromptTestBench.seed(from: []) == .none)
        r.record("a History of nothing but monologues starts the field empty",
                 PromptTestBench.seed(from: [entry(synthetic(2524), at: now),
                                             entry(synthetic(1500), at: now)]) == .none)
        r.record("a blank entry is not offered as a sample",
                 PromptTestBench.seed(from: [entry("   \n  ", at: now)]) == .none)
        r.record("an empty seed reports no source rather than a stale one",
                 PromptTestBench.source(current: "", seed: .none) == .empty)
    }

    /// The free-text field is the sample field, and it carries no cap at all — the cap governs only
    /// what History is allowed to seed. Building an email-writer hotkey means testing against one
    /// specific long dictation the user types out.
    private static func checkFreeTextIsUncapped(_ r: SelfTestReporter) {
        let long = synthetic(PromptTestBench.historySampleCharacterLimit * 4)
        r.record("a typed sample far over the History cap is still runnable",
                 PromptTestBench.isRunnable(long))
        r.record("a typed sample over the cap reports as typed, not rejected",
                 PromptTestBench.source(current: long, seed: .none) == .typed)
        r.record("a blank sample is not runnable", !PromptTestBench.isRunnable("   \n\t "))
    }

    /// Provenance is derived from the bytes on every keystroke. This is the assertion that keeps a
    /// History default left in the box from ever reading as something the user typed, and its converse.
    private static func checkSourceIsDerivedFromTheBytes(_ r: SelfTestReporter) {
        let when = Date(timeIntervalSince1970: 1_785_000_000)
        let seed = PromptTestBench.Seed(text: "the recorded take", date: when)
        r.record("an untouched History default reports as History",
                 PromptTestBench.source(current: "the recorded take", seed: seed) == .history(when))
        r.record("one edit on top of the default stops it claiming to be the default",
                 PromptTestBench.source(current: "the recorded take!", seed: seed) == .typed)
        r.record("clearing the field reports empty, not a stale History claim",
                 PromptTestBench.source(current: "", seed: seed) == .empty)
        r.record("text typed with no History seed at all reports as typed",
                 PromptTestBench.source(current: "typed from scratch", seed: .none) == .typed)

        let stamp = { (_: Date) in "FIXED-STAMP" }
        let historyLabel = PromptTestBench.sourceLabel(.history(when), dateText: stamp)
        let typedLabel = PromptTestBench.sourceLabel(.typed, dateText: stamp)
        r.record("the History label names when the take was recorded",
                 historyLabel.contains("FIXED-STAMP"))
        r.record("the three sources read differently on screen",
                 historyLabel != typedLabel
                    && typedLabel != PromptTestBench.sourceLabel(.empty, dateText: stamp)
                    && historyLabel != PromptTestBench.sourceLabel(.empty, dateText: stamp))
    }

    /// A bench exists to iterate: it must run the prompt currently in the editable region, not the
    /// bytes the mode last stored. And the request that run builds has to be the request a live take
    /// would build for that same prompt, or the bench is testing something the hotkey will not do.
    private static func checkTheTestRunsWhatIsOnScreen(_ r: SelfTestReporter) {
        let route = LLMRouteID.custom("bench-selftest")
        guard let bundle = LLMProviderDefaults.testedBundle(for: .local, route: route) else {
            r.record("a local bundle exists for a custom route", false)
            return
        }
        let stored = CustomMode(
            id: "bench-selftest", name: "Bench fixture",
            chord: .regular(keyCode: 8, label: "C"),
            prompt: "Rewrite the text as a single sentence.",
            input: .dictation, model: bundle, landing: .inPlace)
        let edited = "Rewrite the text as a single sentence. Keep every proper noun."
        let candidate = PromptTestBench.candidate(stored, editedPrompt: edited)

        r.record("a test runs the prompt on screen, not the stored one", candidate.prompt == edited)
        r.record("nothing else about the mode moves",
                 PromptTestBench.candidate(candidate, editedPrompt: stored.prompt) == stored)
        r.record("the route is unchanged, so a test hits the configured provider and model",
                 candidate.routeID == stored.routeID && candidate.model == stored.model)

        // The whole request, against the one the runtime builds for the same edited prompt.
        let sample = "synthetic bench sample: tighten this line"
        let fromBench = CustomModeClient.makeRequest(
            mode: candidate, input: sample, selected: bundle,
            systemPrompt: CustomModeClient.systemPrompt(for: candidate), timeout: 30)
        let asIfLive = CustomModeClient.makeRequest(
            mode: PromptTestBench.candidate(stored, editedPrompt: edited), input: sample,
            selected: bundle, systemPrompt: CustomModeClient.systemPrompt(taskPrompt: edited),
            timeout: 30)
        r.record("a test builds the same request a live take would", fromBench == asIfLive)
        r.record("and it is the composition the panel is displaying",
                 PromptAssembly.customMode(taskPrompt: edited, transcriptPlaceholder: sample)
                    .map { PromptAssembly.rendered($0.system) == fromBench.systemPrompt
                            && PromptAssembly.rendered($0.user) == fromBench.userMessage } == true)
    }

    /// Failures are reported in the real path's own words. `OneShotRegistry` toasts
    /// `failure.userMessage` after a failed take; the bench shows the same sentence, so a user who has
    /// seen one recognizes the other.
    private static func checkOutcomeUsesTheRealPathsWords(_ r: SelfTestReporter) {
        r.record("a good run shows the model's output",
                 PromptTestBench.outcome(for: .ok("the transformed text")) == .output("the transformed text"))
        r.record("an unavailable provider reports unavailable",
                 PromptTestBench.outcome(for: .unavailable("LM Studio down")) == .failure(.unavailable))
        r.record("a timeout reports timed out",
                 PromptTestBench.outcome(for: .timedOut) == .failure(.timedOut))
        r.record("unusable output reports bad output",
                 PromptTestBench.outcome(for: .badOutput("empty output")) == .failure(.badOutput))

        for failure in [TextTransformRetryDescriptor.Failure.unavailable, .timedOut, .badOutput] {
            r.record("the \(failure.rawValue) status line is the real path's own sentence",
                     PromptTestBench.Outcome.failure(failure).statusText == failure.userMessage)
        }
        r.record("a failure leaves the result area empty rather than putting an error where output goes",
                 PromptTestBench.Outcome.failure(.timedOut).resultText.isEmpty)

        // Provider detail never reaches the panel: `.unavailable("LM Studio down")` and
        // `.unavailable("Codex model ID is required")` present identically, exactly as they do in the
        // toast, because that payload can echo user input.
        r.record("provider detail is not surfaced in the bench",
                 PromptTestBench.outcome(for: .unavailable("LM Studio down"))
                    == PromptTestBench.outcome(for: .unavailable("some other provider detail")))

        r.record("a successful run says, on screen, that nothing landed",
                 PromptTestBench.Outcome.output("x").statusText.contains("Nothing was saved"))
    }
}
