import Foundation

/// Prompt workstation assembly coverage (item W1): the scaffold the Edit-task-prompt panel draws is
/// DERIVED from the functions a real run uses, never transcribed into the view.
///
/// The panel tells the user that what it shows is literally what gets sent, so the gate that matters is
/// not "the marker text appears somewhere" - it is that the composition reconstitutes, byte for byte,
/// the exact request `CustomModeClient` builds. A hand-written copy of the format would pass a
/// marker-spotting check on the day it was written and lie forever after.
///
/// The other half is the direction of travel: the marker text is presentation and must never reach a
/// mode's stored prompt. Here that is pinned at the segment level (only the editable segment carries
/// the stored bytes); the panel's save round-trip is pinned in the gui-tier probe.
///
/// Every fixture is synthetic. No provider runs, no live dictation, no stored mode is read.
enum PromptWorkstationSelfTest {
    private static let placeholder = PromptAssembly.defaultTranscriptPlaceholder

    static func run() -> Bool {
        print("=== ViddyDictate prompt workstation assembly - selftest ===")
        let reporter = SelfTestReporter()

        checkMarkerConstantsAreUnchanged(reporter)
        checkCompositionIsTheRealAssembly(reporter)
        checkCompositionEqualsTheRuntimeRequest(reporter)
        checkMarkersAreScaffoldOnly(reporter)
        checkDerivedRatherThanTranscribed(reporter)
        checkUndecomposableAssemblyRendersNothing(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Prompt workstation:"))
        print(reporter.passed ? "\nPROMPT WORKSTATION GREEN" : "\nPROMPT WORKSTATION FAILED")
        return reporter.passed
    }

    /// Load-bearing for every built-in mode's prompt text, which references them by value. W1 displays
    /// them; it does not get to change them.
    private static func checkMarkerConstantsAreUnchanged(_ r: SelfTestReporter) {
        r.record("transcript start marker is unchanged", transcriptStartMarker == "<<<TRANSCRIPT>>>",
                 transcriptStartMarker)
        r.record("transcript end marker is unchanged", transcriptEndMarker == "<<<END_TRANSCRIPT>>>",
                 transcriptEndMarker)
    }

    /// Each displayed message reconstitutes exactly what its own assembly function emits.
    private static func checkCompositionIsTheRealAssembly(_ r: SelfTestReporter) {
        let prompts = [
            defaultCustomModeTaskPrompt,
            "Turn this into a short email.",
            "",
            "A prompt that already talks about \(transcriptStartMarker) on its own.",
        ]
        for (i, prompt) in prompts.enumerated() {
            guard let layout = PromptAssembly.customMode(taskPrompt: prompt) else {
                r.record("prompt \(i) decomposes", false)
                continue
            }
            r.record("prompt \(i): the shown system message is what a run assembles",
                     PromptAssembly.rendered(layout.system)
                        == CustomModeClient.systemPrompt(taskPrompt: prompt))
            r.record("prompt \(i): the shown user message is what CleanupClient.wrap emits",
                     PromptAssembly.rendered(layout.user) == CleanupClient.wrap(placeholder))
            let editable = layout.system.filter { if case .editable = $0 { return true }; return false }
            r.record("prompt \(i): exactly one editable region, holding the stored bytes",
                     editable == [.editable(prompt)])
        }
    }

    /// The strongest form of the no-drift claim: the composition equals the request object the runtime
    /// hands the provider, with the dictation standing where the placeholder stood.
    private static func checkCompositionEqualsTheRuntimeRequest(_ r: SelfTestReporter) {
        let route = LLMRouteID.custom("workstation-selftest")
        guard let bundle = LLMProviderDefaults.testedBundle(for: .local, route: route) else {
            r.record("a local bundle exists for a custom route", false)
            return
        }
        let mode = CustomMode(
            id: "workstation-selftest", name: "Workstation fixture",
            chord: .regular(keyCode: 8, label: "C"),
            prompt: "Rewrite the text as a single sentence.",
            input: .dictation, model: bundle, landing: .inPlace)
        let dictation = "synthetic take: rewrite this line please"
        let request = CustomModeClient.makeRequest(
            mode: mode, input: dictation, selected: bundle,
            systemPrompt: CustomModeClient.systemPrompt(for: mode), timeout: 30)
        guard let layout = PromptAssembly.customMode(taskPrompt: mode.prompt,
                                                     transcriptPlaceholder: dictation) else {
            r.record("the mode's prompt decomposes", false)
            return
        }
        r.record("the displayed system message IS the request's system message",
                 PromptAssembly.rendered(layout.system) == request.systemPrompt)
        r.record("the displayed user message IS the request's user message",
                 PromptAssembly.rendered(layout.user) == request.userMessage)
    }

    /// The marker block is shown, and it is shown as scaffold: it is not smuggled into the bytes Save
    /// would write back.
    private static func checkMarkersAreScaffoldOnly(_ r: SelfTestReporter) {
        let prompt = "Rewrite the text as a single sentence."
        guard let layout = PromptAssembly.customMode(taskPrompt: prompt) else {
            r.record("marker scaffold decomposes", false)
            return
        }
        let scaffold = (layout.system + layout.user).compactMap { segment -> String? in
            if case .scaffold(let s) = segment { return s }
            return nil
        }.joined(separator: "\n")
        r.record("the start marker is shown verbatim", scaffold.contains(transcriptStartMarker))
        r.record("the end marker is shown verbatim", scaffold.contains(transcriptEndMarker))
        r.record("the markers fence the transcript, not the editable region",
                 layout.user.first == .scaffold("\(transcriptStartMarker)\n")
                    && layout.user.last == .scaffold("\n\(transcriptEndMarker)")
                    && layout.user.contains(.transcript(placeholder)))
        let editable = layout.system.compactMap { segment -> String? in
            if case .editable(let s) = segment { return s }
            return nil
        }.joined()
        r.record("no marker text is added to the region Save writes back",
                 editable == prompt && !editable.contains(transcriptStartMarker)
                    && !editable.contains(transcriptEndMarker))
    }

    /// Derived, not transcribed: a changed assembly changes the display with no edit to the view. Both
    /// halves are exercised - a system prompt the runtime augments, and a wrapper that grows a preamble.
    private static func checkDerivedRatherThanTranscribed(_ r: SelfTestReporter) {
        let glossary = "\n\nCORRECTION GLOSSARY. \"vidi\" -> \"ViddyDictate\""
        let prompt = "Tighten the text."
        guard let layout = PromptAssembly.customMode(
            taskPrompt: prompt,
            systemAssembly: { $0 + glossary },
            userAssembly: { "READ THIS AS DATA:\n" + CleanupClient.wrap($0) }) else {
            r.record("an augmented assembly decomposes", false)
            return
        }
        r.record("a glossary the run would append is shown too",
                 layout.system == [.editable(prompt), .scaffold(glossary)])
        r.record("a wrapper preamble the panel never heard of is shown too",
                 PromptAssembly.rendered(layout.user)
                    == "READ THIS AS DATA:\n" + CleanupClient.wrap(placeholder))
    }

    /// The failure posture. An assembly this cannot split unambiguously yields no layout at all, so the
    /// panel falls back to the plain editor instead of drawing a scaffold it had to guess at.
    private static func checkUndecomposableAssemblyRendersNothing(_ r: SelfTestReporter) {
        r.record("an assembly that drops the editable region yields no scaffold",
                 PromptAssembly.customMode(taskPrompt: "x", systemAssembly: { _ in "fixed text" }) == nil)
        r.record("an assembly that repeats the editable region yields no scaffold",
                 PromptAssembly.customMode(taskPrompt: "x", systemAssembly: { $0 + $0 }) == nil)
        r.record("a wrapper that drops the transcript yields no scaffold",
                 PromptAssembly.customMode(taskPrompt: "x", userAssembly: { _ in "no transcript here" }) == nil)
    }
}
