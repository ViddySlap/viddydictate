import Foundation

/// Prompt overlay store coverage (Public V1 locked decision 8 / work item W3): the factory prompt bundle
/// ships inside the app, a per-route user overlay lives under Application Support and holds ONLY what the
/// user changed, resolution is overlay-then-factory, Reset deletes the overlay entry, and an override makes
/// that route read unratified.
///
/// Every fixture is a scratch store under a temporary root plus synthetic prompt text. No live provider,
/// credential, installed app, or real dictation is consulted.
enum PromptOverlaySelfTest {
    /// One overridable prompt surface: the promptPrep card carries a prompt per cleanup strength, every
    /// other built-in route carries one.
    private static let surfaces: [(route: LLMRouteID, variant: LLMPromptVariant)] =
        LLMRouteID.builtIns.flatMap { route -> [(LLMRouteID, LLMPromptVariant)] in
            route == .promptPrep
                ? [(route, .cleanupL1), (route, .cleanupL2), (route, .cleanupL3)]
                : [(route, .primary)]
        }

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate prompt overlay store - selftest ===")
        let reporter = SelfTestReporter()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-prompt-overlay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            reporter.record("scratch root", false, error.localizedDescription)
            return reporter.passed
        }

        checkFactoryBundleAndOverlayLocation(root: root, reporter.record)
        checkResolutionIsOverlayThenFactory(root: root, reporter.record)
        checkResetDeletesTheEntry(root: root, reporter.record)
        checkOverrideMarksTheRouteUnratified(root: root, reporter.record)
        checkContentSafety(root: root, reporter.record)

        print("\n=== RESULT ===")
        print("Prompt overlay store:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nPROMPT OVERLAY GREEN" : "\nPROMPT OVERLAY FAILED")
        return reporter.passed
    }

    // MARK: fixtures

    private static func store(_ root: URL, _ name: String) -> ModelsPowerSettingsStore {
        ModelsPowerSettingsStore(url: root.appendingPathComponent(name), legacy: .empty)
    }

    /// The overlay entries actually persisted, read back from the file rather than from the live object, so
    /// "the overlay holds only what changed" is asserted against bytes on disk.
    private static func storedOverlay(_ url: URL) -> [String: [String: [String: String]]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = object["routes"] as? [String: [String: Any]] else { return [:] }
        var out: [String: [String: [String: String]]] = [:]
        for (route, state) in routes {
            if let overrides = state["promptOverrides"] as? [String: [String: String]],
               !overrides.isEmpty {
                out[route] = overrides
            }
        }
        return out
    }

    private static func overlayEntryCount(_ url: URL) -> Int {
        storedOverlay(url).values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
    }

    // MARK: checks

    private static func checkFactoryBundleAndOverlayLocation(
        root: URL, _ check: (String, Bool) -> Void
    ) {
        print("--- the factory bundle ships in the app; the overlay holds only what changed ---")
        let url = root.appendingPathComponent("factory.json")
        let s = ModelsPowerSettingsStore(url: url, legacy: .empty)

        check("a fresh install persists no prompt bytes at all",
              overlayEntryCount(url) == 0)
        let everySurfaceIsFactory = surfaces.allSatisfy { surface in
            LLMProvider.allCases.allSatisfy { provider in
                s.effectivePrompt(for: surface.route, provider: provider, variant: surface.variant)
                    == LLMProviderDefaults.testedPrompt(
                        for: surface.route, provider: provider, variant: surface.variant)
            }
        }
        check("every route/provider/strength resolves to the prompt this build ships",
              everySurfaceIsFactory && surfaces.count == LLMRouteID.builtIns.count + 2)

        try? s.setPromptOverride("ONE CHANGED EMAIL PROMPT", for: .email, provider: .claude)
        let overlay = storedOverlay(url)
        check("one edit writes exactly one overlay entry and leaves every sibling absent",
              overlayEntryCount(url) == 1
                && overlay["email"]?["claude"]?["primary"] == "ONE CHANGED EMAIL PROMPT")
        let fileText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("the factory prompt bytes are never copied into the overlay file",
              !fileText.contains(defaultEmailSystemPrompt)
                && !fileText.contains(firmCleanupPrompt)
                && !fileText.contains(defaultSearchSynthPrompt))

        // Where the production overlay actually lives. Under verify.sh this resolves inside the scratch
        // HOME, so reading the authority here is isolated from the user's real settings.
        let appSupport = AppPaths.applicationSupportDirectory()
        _ = Settings.modelsPower
        check("the production overlay is a file under Application Support",
              appSupport.path.contains("/Library/Application Support/")
                && appSupport.lastPathComponent == "ViddyDictate"
                && FileManager.default.fileExists(
                    atPath: appSupport.appendingPathComponent("models-power.json").path))
    }

    private static func checkResolutionIsOverlayThenFactory(
        root: URL, _ check: (String, Bool) -> Void
    ) {
        print("--- resolution is overlay, then factory, with no third layer ---")
        let s = store(root, "resolution.json")
        try? s.setPromptOverride("CLAUDE EMAIL OVERLAY", for: .email, provider: .claude)
        try? s.setPromptOverride("CLAUDE P TIGHTEN OVERLAY", for: .promptPrep, provider: .claude,
                                 variant: .cleanupL2)

        check("the overlay entry wins for exactly the route, provider, and strength it was written for",
              s.effectivePrompt(for: .email, provider: .claude) == "CLAUDE EMAIL OVERLAY"
                && s.effectivePrompt(for: .promptPrep, provider: .claude, variant: .cleanupL2)
                    == "CLAUDE P TIGHTEN OVERLAY")
        check("no sibling provider, strength, or route inherits another surface's overlay",
              s.effectivePrompt(for: .email, provider: .local) == defaultEmailSystemPrompt
                && s.effectivePrompt(for: .promptPrep, provider: .claude, variant: .cleanupL1)
                    == firmCleanupPrompt
                && s.effectivePrompt(for: .promptPrep, provider: .local, variant: .cleanupL2)
                    == tightenCleanupPrompt
                && s.effectivePrompt(for: .cleanupL2, provider: .claude) == tightenCleanupPrompt)

        let glossary = CorrectionDictionary.contextGlossarySuffix([
            CorrectionEntry(heard: "viddy", intended: "Viddy"),
        ])
        check("the developer-instruction seam the transform actually calls resolves the same overlay",
              s.effectiveDeveloperInstructions(
                for: .email, provider: .claude, glossarySuffix: glossary)
                == "CLAUDE EMAIL OVERLAY" + glossary
                && s.effectiveDeveloperInstructions(
                    for: .email, provider: .local, glossarySuffix: glossary)
                    == defaultEmailSystemPrompt + glossary)

        // The legacy provider-neutral UserDefaults prompt keys are a MIGRATION SOURCE only. They used to be
        // passed in as the "tested default", which made them a hidden layer between overlay and factory: a
        // machine carrying one got its old prompt back from Reset instead of the shipped bytes.
        let ghost = "LEGACY GHOST PROMPT"
        let legacyKeys = ["cleanupSystemPrompt", "emailSystemPrompt", "searchSynthPrompt"]
        for key in legacyKeys { UserDefaults.standard.set(ghost, forKey: key) }
        defer { for key in legacyKeys { UserDefaults.standard.removeObject(forKey: key) } }
        check("the legacy provider-neutral prompt keys really are populated for this check",
              Settings.emailSystemPrompt == ghost && Settings.searchSynthPrompt == ghost
                && Settings.cleanupPrompt(.cleanup) == ghost)
        check("a populated legacy key cannot act as a layer between the overlay and the factory",
              s.effectivePrompt(for: .email, provider: .local) == defaultEmailSystemPrompt
                && s.effectivePrompt(for: .searchLocalSynth, provider: .local)
                    == defaultSearchSynthPrompt
                && s.effectivePrompt(for: .cleanupL1, provider: .local) == firmCleanupPrompt
                && s.effectiveDeveloperInstructions(
                    for: .cleanupL1, provider: .local, glossarySuffix: "") == firmCleanupPrompt)
    }

    private static func checkResetDeletesTheEntry(root: URL, _ check: (String, Bool) -> Void) {
        print("--- reset deletes the overlay entry ---")
        let url = root.appendingPathComponent("reset.json")
        let s = ModelsPowerSettingsStore(url: url, legacy: .empty)
        try? s.setPromptOverride("EMAIL OVERLAY TO RESET", for: .email, provider: .claude)
        try? s.setPromptOverride("SEARCH OVERLAY TO KEEP", for: .searchGeminiSynth, provider: .claude)

        try? s.setPromptOverride(nil, for: .email, provider: .claude)
        check("reset removes the entry from the file rather than storing the factory text",
              overlayEntryCount(url) == 1
                && storedOverlay(url)["email"] == nil
                && storedOverlay(url)["searchGeminiSynth"]?["claude"]?["primary"]
                    == "SEARCH OVERLAY TO KEEP")
        check("a reset route resolves to the factory prompt and reports itself as tested default",
              s.effectivePrompt(for: .email, provider: .claude) == defaultEmailSystemPrompt
                && s.promptCustomizationState(for: .email, provider: .claude) == .testedDefault)
        let reopened = ModelsPowerSettingsStore(url: url)
        check("the deletion survives a settings reopen",
              reopened.promptCustomizationState(for: .email, provider: .claude) == .testedDefault
                && reopened.effectivePrompt(for: .email, provider: .claude) == defaultEmailSystemPrompt
                && reopened.effectivePrompt(for: .searchGeminiSynth, provider: .claude)
                    == "SEARCH OVERLAY TO KEEP")

        // Reset arriving from the other side: saving text that equals the shipped prompt, or blank text, is
        // not a change, so it must not persist an entry (and blank must never become an empty system prompt).
        try? s.setPromptOverride(defaultEmailSystemPrompt, for: .email, provider: .claude)
        try? s.setPromptOverride("   \n  ", for: .cleanupL3, provider: .local)
        check("saving the shipped bytes or blank text stores no entry",
              overlayEntryCount(url) == 1
                && s.promptCustomizationState(for: .email, provider: .claude) == .testedDefault
                && s.promptCustomizationState(for: .cleanupL3, provider: .local) == .testedDefault
                && s.effectivePrompt(for: .cleanupL3, provider: .local) == summarizeCleanupPrompt)
        try? s.setPromptOverride("CUSTOMIZED AGAIN", for: .email, provider: .claude)
        try? s.setPromptOverride(defaultEmailSystemPrompt, for: .email, provider: .claude)
        check("re-saving the shipped bytes over an existing overlay deletes it",
              s.promptCustomizationState(for: .email, provider: .claude) == .testedDefault
                && storedOverlay(url)["email"] == nil)
    }

    private static func checkOverrideMarksTheRouteUnratified(
        root: URL, _ check: (String, Bool) -> Void
    ) {
        print("--- an override marks the route unratified ---")
        let url = root.appendingPathComponent("ratification.json")
        let s = ModelsPowerSettingsStore(url: url, legacy: .empty)

        let before = s.ratificationState(for: .email, provider: .claude)
        check("a shipped route with sealed evidence for the model it runs reads ratified",
              before == .ratified(
                LLMProviderDefaults.testedBundle(for: .claude, route: .email)!.ratified!)
                && before.isRatified)

        try? s.setPromptOverride("EMAIL PROMPT THE EVIDENCE NEVER COVERED", for: .email, provider: .claude)
        let after = s.ratificationState(for: .email, provider: .claude)
        check("editing the prompt makes that route read unratified, naming the override as the reason",
              after == .unratified([.promptOverridden]))
        check("only the edited surface is affected",
              s.ratificationState(for: .email, provider: .codex).isRatified
                && s.ratificationState(for: .cleanupL3, provider: .claude).isRatified
                && s.ratificationState(for: .promptPrep, provider: .claude, variant: .cleanupL2)
                    .isRatified)

        // Derived, not stamped: the sealed provenance is still on disk untouched, which is what lets Reset
        // restore the ratified reading instead of needing a second write to put evidence back.
        let stored = s.rememberedBundle(for: .claude, route: .email)
        check("the sealed provenance itself is never destroyed by an override",
              stored?.ratified == LLMProviderDefaults.testedBundle(
                for: .claude, route: .email)?.ratified
                && ModelsPowerSettingsStore(url: url).rememberedBundle(for: .claude, route: .email)
                    == stored)
        try? s.setPromptOverride(nil, for: .email, provider: .claude)
        check("resetting the prompt restores the ratified reading",
              s.ratificationState(for: .email, provider: .claude) == before)

        // The other two reasons are derived from the bundle, proving the state is read from evidence rather
        // than being a second name for "has an override".
        check("an arm with no sealed evidence reads unratified for that reason",
              s.ratificationState(for: .email, provider: .local) == .unratified([.noEvidence]))
        let migrated = s.ratificationState(for: .cleanupL1, provider: .codex)
        check("a deprecation-migrated shipped default reads unratified because its evidence covers the retired model",
              migrated == .unratified([.evidenceCoversAnotherModel])
                && s.rememberedBundle(for: .codex, route: .cleanupL1)?.ratified?.modelID
                    == LLMProviderDefaults.retiredCleanupL1CodexModelID)
        try? s.setPromptOverride("MIGRATED L1 PROMPT EDIT", for: .cleanupL1, provider: .codex)
        check("two independent causes are both reported instead of the first one hiding the second",
              s.ratificationState(for: .cleanupL1, provider: .codex)
                == .unratified([.evidenceCoversAnotherModel, .promptOverridden]))
        check("a user-picked model with an override reports no evidence and the override",
              { try? s.setSelectedBundle(.claude("user-picked-model"), for: .cleanupL2)
                try? s.setPromptOverride("USER MODEL PROMPT EDIT", for: .cleanupL2, provider: .claude)
                return s.ratificationState(for: .cleanupL2, provider: .claude)
                    == .unratified([.noEvidence, .promptOverridden]) }())
    }

    private static func checkContentSafety(root: URL, _ check: (String, Bool) -> Void) {
        print("--- overlay state carries no prompt text ---")
        let canary = "SYNTHETIC_P7_\(UUID().uuidString)"
        let s = store(root, "content-safety.json")
        try? s.setPromptOverride(canary, for: .email, provider: .claude)
        let state = s.ratificationState(for: .email, provider: .claude)
        let customization = s.promptCustomizationState(for: .email, provider: .claude)
        check("the ratification and customization states cannot echo the user's prompt text",
              !String(describing: state).contains(canary)
                && !String(describing: customization).contains(canary)
                && s.effectivePrompt(for: .email, provider: .claude) == canary)

        Log.flushForTest()
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        check("writing and reading an overlay entry writes no prompt text to the app log",
              !log.contains(canary))
    }
}
