import Foundation

/// Pure/scratch-only A4 contract coverage. It never reads live preferences, custom modes, providers,
/// notes, or user data; every store is injected under a fresh temporary root.
enum ModelsPowerSettingsSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate Models & Power settings domain — selftest ===")
        let reporter = SelfTestReporter()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-models-power-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            reporter.record("scratch root", false, error.localizedDescription)
            return reporter.passed
        }

        checkBulkMixedMemoryAndCleanup(root: root, reporter.record)
        checkSelectedProviderProvenance(root: root, reporter.record)
        checkPromptsAvailabilityAndRestore(root: root, reporter.record)
        checkMigration(root: root, reporter.record)
        checkCodexPickerPolicy(root: root, reporter.record)
        checkSurfacedWriteFailures(root: root, reporter.record)

        print("\n=== RESULT ===")
        print("Models & Power settings:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nMODELS & POWER SETTINGS GREEN" : "\nMODELS & POWER SETTINGS FAILED")
        return reporter.passed
    }

    private static func store(_ root: URL, _ name: String,
                              legacy: ModelsPowerLegacyState = .empty) -> ModelsPowerSettingsStore {
        ModelsPowerSettingsStore(url: root.appendingPathComponent(name), legacy: legacy)
    }

    private static func checkBulkMixedMemoryAndCleanup(
        root: URL, _ check: (String, Bool) -> Void
    ) {
        print("--- global defaults, Mixed, provider memory, per-strength Cleanup ---")
        let s = store(root, "bulk.json")
        let custom = LLMRouteID.custom("fixture-custom")
        do { try s.syncCustomRoutes([custom: .local("legacy-custom")]) }
        catch { check("custom route registration succeeds", false) }
        try? s.setRememberedBundle(.local("remember-local"), for: .local, route: custom)
        try? s.setRememberedBundle(.claude("remember-claude", effort: "low"), for: .claude, route: custom)

        try? s.selectProvider(.claude, for: custom)
        try? s.selectProvider(.local, for: custom)
        check("normal provider switching restores the per-provider remembered custom bundle",
              s.selectedBundle(for: custom).modelID == "remember-local"
                && s.rememberedBundle(for: .claude, route: custom)?.modelID == "remember-claude")

        do { try s.applyGlobalProvider(.claude) }
        catch { check("Claude global action succeeds", false) }
        check("global Claude is derived as one provider, including custom routes",
              s.bulkProviderState() == .provider(.claude))
        check("global action is tested-default-driven, not remembered-choice-driven",
              s.selectedBundle(for: custom)
                == LLMProviderDefaults.testedBundle(for: .claude, route: custom))
        check("global action preserves the other providers' remembered bundles",
              s.rememberedBundle(for: .local, route: custom)?.modelID == "remember-local")

        try? s.selectProvider(.local, for: .email)
        check("Mixed is derived after one route diverges", s.bulkProviderState() == .mixed)

        do { try s.applyGlobalProvider(.codex) }
        catch { check("Codex global action succeeds for all shipped routes", false) }
        let ratified = LLMRouteID.builtIns + [custom]
        check("Codex global action installs all eight exact shipped defaults",
              ratified.allSatisfy {
                  s.selectedBundle(for: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
              })
        check("complete Codex global routing is truthfully derived as Codex",
              s.bulkProviderState() == .provider(.codex))

        let strengths: [(LLMRouteID, String)] = [
            (.cleanupL1, "cleanup-user"), (.cleanupL2, "tighten-user"), (.cleanupL3, "summarize-user"),
        ]
        for (route, model) in strengths {
            try? s.setRememberedBundle(.local(model), for: .local, route: route)
        }
        try? s.applyCleanupProvider(.claude)
        try? s.applyCleanupProvider(.local)
        check("the simple Cleanup provider control preserves all three advanced strength bundles",
              strengths.allSatisfy { s.selectedBundle(for: $0.0).modelID == $0.1 })
        check("Cleanup provider status is independently derivable",
              s.bulkProviderState(routes: strengths.map(\.0)) == .provider(.local))
        do { try s.applyCleanupProvider(.codex) }
        catch { check("complete Cleanup Codex action succeeds", false) }
        check("Cleanup Codex action selects all three shipped defaults",
              strengths.map(\.0).allSatisfy {
                  s.selectedBundle(for: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
              })
        check("complete Cleanup Codex routing is derived as Codex",
              s.bulkProviderState(routes: strengths.map(\.0)) == .provider(.codex))
    }

    private static func checkSelectedProviderProvenance(
        root: URL, _ check: (String, Bool) -> Void
    ) {
        print("--- selected-provider provenance ---")
        let s = store(root, "selected-provider-provenance.json")
        let route = LLMRouteID.email
        let rememberedClaude = LLMProviderDefaults.testedBundle(for: .claude, route: route)!
        do {
            try s.setRememberedBundle(rememberedClaude, for: .claude, route: route)
            try s.setSelectedBundle(.local("user-picked-local-model"), for: route)
        } catch {
            check("selected-provider provenance fixture writes", false)
            return
        }

        let presentation = ModelsPowerSettingsView.provenancePresentation(
            for: route, store: s
        ) { provider in
            s.ratificationState(for: route, provider: provider)
        }
        check("Local provenance uses the selected provider and model, not remembered Claude",
              presentation.bundle.provider == .local
                && presentation.bundle.modelID == "user-picked-local-model"
                && presentation.badge == "LOCAL user-picked-local-model")
        check("a user-selected Local model carries no ratification badge",
              !presentation.badge.contains("RATIFIED"))
    }

    private static func checkPromptsAvailabilityAndRestore(
        root: URL, _ check: (String, Bool) -> Void
    ) {
        print("--- provider prompts, custom shared task, availability, complete Restore ---")
        let s = store(root, "prompts.json")
        do {
            try s.setPromptOverride("LOCAL EMAIL OVERRIDE", for: .email, provider: .local)
            try s.setPromptOverride("CLAUDE EMAIL OVERRIDE", for: .email, provider: .claude)
            try s.setPromptOverride("P TIGHTEN OVERRIDE", for: .promptPrep, provider: .claude,
                                    variant: .cleanupL2)
            try s.setPromptOverride("LOCAL L ONLY", for: .searchLocalSynth, provider: .local)
        } catch { check("prompt overrides write", false) }

        check("built-in prompt overrides are independent by provider",
              s.effectivePrompt(for: .email, provider: .local)
                == "LOCAL EMAIL OVERRIDE"
                && s.effectivePrompt(for: .email, provider: .claude)
                == "CLAUDE EMAIL OVERRIDE")
        check("Option+P keeps independent per-strength provider prompt values",
              s.effectivePrompt(for: .promptPrep, provider: .claude,
                                variant: .cleanupL2)
                == "P TIGHTEN OVERRIDE"
                && s.effectivePrompt(for: .promptPrep, provider: .claude,
                                     variant: .cleanupL1)
                == firmCleanupPrompt)
        check("L/G keep separate route profiles while sharing tested prompt bytes",
              s.effectivePrompt(for: .searchLocalSynth, provider: .local) == "LOCAL L ONLY"
                && s.effectivePrompt(for: .searchGeminiSynth, provider: .local) == defaultSearchSynthPrompt)
        check("prompt state reports Tested default versus Customized",
              s.promptCustomizationState(for: .email, provider: .local) == .customized
                && s.promptCustomizationState(for: .searchGeminiSynth, provider: .local) == .testedDefault)

        s.setAvailabilityState(.unavailable("LM Studio offline"), for: .local)
        s.setAvailabilityState(.available, for: .claude)
        s.setAvailabilityState(.disconnected, for: .codex)
        check("provider availability distinguishes available, unavailable, and disconnected",
              !s.availabilityState(for: .local).canRun
                && s.availabilityState(for: .claude).canRun
                && s.availabilityState(for: .codex).requiresConnection)

        try? s.setSelectedBundle(.claude("user-email", effort: "high"), for: .email)
        let dynamicGlossary = CorrectionDictionary.contextGlossarySuffix([
            CorrectionEntry(heard: "viddy", intended: "Viddy"),
        ])
        do { try s.restoreProviderDefault(.claude, for: .email) }
        catch { check("Claude Restore succeeds", false) }
        let restored = s.selectedBundle(for: .email)
        check("Restore reinstalls model, effort, prompt hash/version, and envelope version",
              restored == LLMProviderDefaults.testedBundle(for: .claude, route: .email)
                && restored.basePromptVersion != nil && restored.basePromptHash?.count == 64
                && restored.envelopeVersion != nil)
        check("Restore clears only that provider's built-in prompt customization",
              s.promptCustomizationState(for: .email, provider: .claude) == .testedDefault
                && s.promptCustomizationState(for: .email, provider: .local) == .customized)
        let augmentedAfterRestore = s.effectivePrompt(
            for: .email, provider: .claude) + dynamicGlossary
        check("Restore never overwrites the dynamic correction glossary",
              !dynamicGlossary.isEmpty && augmentedAfterRestore.hasSuffix(dynamicGlossary))

        let cleanupRoutes: [LLMRouteID] = [.cleanupL1, .cleanupL2, .cleanupL3]
        for route in cleanupRoutes {
            try? s.setSelectedBundle(.local("user-\(route.rawValue)"), for: route)
            try? s.setPromptOverride("custom \(route.rawValue)", for: route, provider: .claude)
        }
        do { try s.restoreProviderDefault(.claude, for: cleanupRoutes) }
        catch { check("Cleanup multi-route Restore succeeds", false) }
        check("the simple Cleanup card restores all three complete bundles in one transaction",
              cleanupRoutes.allSatisfy {
                  s.selectedBundle(for: $0) == LLMProviderDefaults.testedBundle(for: .claude, route: $0)
                    && s.promptCustomizationState(for: $0, provider: .claude) == .testedDefault
              })
        try? s.setSelectedBundle(.codex("custom-l1", effort: "high"), for: .cleanupL1)
        try? s.setSelectedBundle(.codex("custom-l2", effort: "high"), for: .cleanupL2)
        try? s.setSelectedBundle(.local("keep-l3"), for: .cleanupL3)
        try? s.setPromptOverride("CODEX L1 OVERRIDE", for: .cleanupL1, provider: .codex)
        try? s.setPromptOverride("CODEX L3 OVERRIDE", for: .cleanupL3, provider: .codex)
        do { try s.restoreProviderDefault(.codex, for: cleanupRoutes) }
        catch { check("complete Cleanup Codex Restore succeeds", false) }
        check("Cleanup Codex Restore reinstalls all three complete shipped bundles",
              cleanupRoutes.allSatisfy {
                  s.selectedBundle(for: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
              })
        check("Cleanup Codex Restore clears every restored Codex prompt override",
              [.cleanupL1, .cleanupL3].allSatisfy {
                  s.promptCustomizationState(for: $0, provider: .codex) == .testedDefault
              })
        let liveL3Instructions = s.effectiveDeveloperInstructions(
            for: .cleanupL3, provider: .codex,
            glossarySuffix: dynamicGlossary)
        check("the rescue Cleanup L3 default keeps the dynamic glossary inside its ratified recipe",
              liveL3Instructions
                == CodexRatifiedPromptDefaults.cleanupL3.developerInstructions(
                    glossarySuffix: dynamicGlossary)
                && liveL3Instructions.contains("\"viddy\" -> \"Viddy\"")
                && liveL3Instructions.hasSuffix(CodexRatifiedPromptDefaults.cleanupL3.constraint))

        let custom = CustomMode(
            id: "shared-prompt", name: "Shared", chord: .regular(keyCode: 3, label: "F"),
            prompt: "ONE PROVIDER-NEUTRAL USER TASK", input: .selection,
            model: .local("legacy"), landing: .inPlace)
        do { try s.syncCustomRoutes([custom.routeID: custom.model]) }
        catch { check("custom route synchronization succeeds", false) }
        try? s.restoreProviderDefault(.codex, for: custom.routeID)
        check("custom-mode Codex Restore installs the ratified bundle without overwriting the shared task prompt",
              custom.prompt == "ONE PROVIDER-NEUTRAL USER TASK"
                && s.selectedBundle(for: custom.routeID)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: custom.routeID))
        var customPromptRejected = false
        do { try s.setPromptOverride("provider fork", for: custom.routeID, provider: .claude) }
        catch ModelsPowerSettingsError.customRoutePrompt { customPromptRejected = true }
        catch {}
        check("custom routes reject provider-specific user-task prompt forks", customPromptRejected)

        let rescuedRoutes: [LLMRouteID] = [.cleanupL3, .promptPrep, .email]
        for route in rescuedRoutes {
            try? s.setSelectedBundle(.codex("custom-\(route.rawValue)", effort: "high"), for: route)
            try? s.setPromptOverride("CUSTOM RESCUE PROMPT", for: route, provider: .codex)
            do { try s.restoreProviderDefault(.codex, for: route) }
            catch { check("I1 route Restore succeeds for \(route.rawValue)", false) }
        }
        check("Restore Codex default carries each exact rescue bundle and clears its prompt override",
              rescuedRoutes.allSatisfy {
                  s.selectedBundle(for: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
                    && s.promptCustomizationState(for: $0, provider: .codex) == .testedDefault
              })
    }

    private static func checkMigration(root: URL, _ check: (String, Bool) -> Void) {
        print("--- legacy settings and bundle metadata migration ---")
        let route = LLMRouteID.promptPrep
        let legacyBundle = LLMProviderBundle(
            version: 1, provider: .claude, modelID: "claude-user-kept", effort: "high")
        var legacy = ModelsPowerLegacyState.empty
        legacy.selectedBundles[route] = legacyBundle
        legacy.rememberedBundles[route] = [
            .local: LLMProviderBundle(version: 1, provider: .local, modelID: "local-user-kept"),
            .claude: legacyBundle,
        ]
        legacy.promptOverrides[route] = [
            .claude: [.cleanupL1: "KEPT LEGACY PROMPT"],
        ]
        let url = root.appendingPathComponent("migration.json")
        _ = ModelsPowerSettingsStore(url: url, legacy: legacy)
        let reopened = ModelsPowerSettingsStore(url: url)
        let selected = reopened.selectedBundle(for: route)
        check("legacy selected provider/model/effort migrate losslessly",
              selected.provider == .claude && selected.modelID == "claude-user-kept"
                && selected.effort == "high")
        check("legacy per-provider remembered bundle survives migration",
              reopened.rememberedBundle(for: .local, route: route)?.modelID == "local-user-kept")
        check("legacy provider-neutral prompt data becomes the correct provider/strength override",
              reopened.effectivePrompt(for: route, provider: .claude,
                                       variant: .cleanupL1)
                == "KEPT LEGACY PROMPT")
        check("version-1 bundles gain complete version-2 metadata with nil provenance",
              selected.version == LLMProviderBundle.currentVersion
                && selected.basePromptHash?.count == 64 && selected.envelopeVersion != nil
                && selected.ratified == nil && selected.autoUpdated == nil)
        let object = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        check("canonical migration file advances to the durable-default snapshot version",
              object?["version"] as? Int == 4)

        let i1URL = root.appendingPathComponent("i1-codex-migration.json")
        let i1Fixture = Data(#"""
        {
          "version": 2,
          "routes": {
            "cleanupL1": {
              "selectedProvider": "local",
              "bundles": {
                "local": {"version": 2, "provider": "local", "modelID": "kept-l1"},
                "claude": {
                  "version": 2,
                  "provider": "claude",
                  "modelID": "kept-pre-provenance-claude",
                  "effort": "high"
                }
              },
              "promptOverrides": {}
            },
            "cleanupL3": {
              "selectedProvider": "local",
              "bundles": {
                "local": {"version": 2, "provider": "local", "modelID": "kept-l3-local"}
              },
              "promptOverrides": {}
            },
            "promptPrep": {
              "selectedProvider": "local",
              "bundles": {
                "local": {"version": 2, "provider": "local", "modelID": "kept-p"}
              },
              "promptOverrides": {}
            },
            "email": {
              "selectedProvider": "local",
              "bundles": {
                "local": {"version": 2, "provider": "local", "modelID": "kept-m"}
              },
              "promptOverrides": {}
            },
            "custom:existing": {
              "selectedProvider": "local",
              "bundles": {
                "local": {"version": 2, "provider": "local", "modelID": "kept-custom"}
              },
              "promptOverrides": {}
            }
          }
        }
        """#.utf8)
        guard (try? i1Fixture.write(to: i1URL, options: .atomic)) != nil else {
            check("I1 migration fixture writes", false)
            return
        }
        let i1 = ModelsPowerSettingsStore(url: i1URL)
        let installedRoutes = LLMRouteID.builtIns + [LLMRouteID.custom("existing")]
        check("I1 migration installs every missing D1 and rescue Codex provider memory",
              installedRoutes.allSatisfy {
                  i1.rememberedBundle(for: .codex, route: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
              })
        check("I1 no-default-to-default migration pins the three exact rescue bundles",
              [LLMRouteID.cleanupL3, .promptPrep, .email].allSatisfy {
                  i1.rememberedBundle(for: .codex, route: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
              })
        check("I1 migration never changes existing selected Local model choices",
              i1.selectedBundle(for: .cleanupL1).modelID == "kept-l1"
                && i1.selectedBundle(for: .cleanupL3).modelID == "kept-l3-local"
                && i1.selectedBundle(for: .promptPrep).modelID == "kept-p"
                && i1.selectedBundle(for: .email).modelID == "kept-m")
        let preProvenance = i1.rememberedBundle(for: .claude, route: .cleanupL1)
        check("pre-provenance stored bundle decodes identically with nil provenance",
              preProvenance?.modelID == "kept-pre-provenance-claude"
                && preProvenance?.effort == "high"
                && preProvenance?.ratified == nil
                && preProvenance?.autoUpdated == nil)
        let i1Object = (try? Data(contentsOf: i1URL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        check("I1 Codex-default migration is durably versioned",
              i1Object?["version"] as? Int == 4)

        let retiredURL = root.appendingPathComponent("retired-cleanup-l1.json")
        let retiredFixture = Data(#"""
        {
          "version": 3,
          "routes": {
            "cleanupL1": {
              "selectedProvider": "codex",
              "bundles": {
                "codex": {
                  "version": 2,
                  "provider": "codex",
                  "modelID": "gpt-5.4-mini",
                  "effort": "low",
                  "ratified": {
                    "modelID": "gpt-5.4-mini",
                    "date": "2026-07-14",
                    "evidence": "sealed bakeoffs 20260714"
                  }
                }
              },
              "promptOverrides": {"codex": {"primary": "KEEP RETIRED MIGRATION PROMPT"}}
            },
            "custom:escape": {
              "selectedProvider": "codex",
              "bundles": {
                "codex": {
                  "version": 2,
                  "provider": "codex",
                  "modelID": "gpt-5.4-mini",
                  "effort": "wild effort"
                }
              },
              "promptOverrides": {}
            }
          }
        }
        """#.utf8)
        guard (try? retiredFixture.write(to: retiredURL, options: .atomic)) != nil else {
            check("retired Cleanup L1 migration fixture writes", false)
            return
        }
        let retired = ModelsPowerSettingsStore(url: retiredURL)
        let migratedL1 = retired.selectedBundle(for: .cleanupL1)
        check("stored shipped Cleanup L1 retirement migrates without resurrecting the old id",
              migratedL1.modelID == LLMProviderDefaults.cleanupL1CodexModelID
                && migratedL1.effort == CodexShippedDefaults.lunaLow.effort
                && migratedL1.ratified?.modelID
                    == LLMProviderDefaults.retiredCleanupL1CodexModelID
                && migratedL1.autoUpdated?.fromModelID
                    == LLMProviderDefaults.retiredCleanupL1CodexModelID
                && retired.effectivePrompt(
                    for: .cleanupL1,
                    provider: .codex)
                    == "KEEP RETIRED MIGRATION PROMPT")
        check("the custom-id escape hatch remains exact instead of applying a hardcoded global map",
              retired.selectedBundle(for: .custom("escape")).modelID == "gpt-5.4-mini"
                && retired.selectedBundle(for: .custom("escape")).effort == "wild effort")

        let preserveURL = root.appendingPathComponent("i1-preserve-existing-codex.json")
        let preserveFixture = Data(#"""
        {
          "version": 2,
          "routes": {
            "cleanupL3": {
              "selectedProvider": "codex",
              "bundles": {
                "local": {"version": 2, "provider": "local", "modelID": "kept-l3-local"},
                "codex": {"version": 2, "provider": "codex", "modelID": "user-l3", "effort": "high"}
              },
              "promptOverrides": {"codex": {"primary": "KEEP L3 CODEX PROMPT"}}
            }
          }
        }
        """#.utf8)
        guard (try? preserveFixture.write(to: preserveURL, options: .atomic)) != nil else {
            check("I1 preservation fixture writes", false)
            return
        }
        let preserved = ModelsPowerSettingsStore(url: preserveURL)
        let keptL3 = preserved.rememberedBundle(for: .codex, route: .cleanupL3)
        check("I1 migration preserves an explicit pre-existing Codex choice and prompt override",
              keptL3?.modelID == "user-l3" && keptL3?.effort == "high"
                && preserved.selectedBundle(for: .cleanupL3).provider == .codex
                && preserved.effectivePrompt(for: .cleanupL3, provider: .codex)
                    == "KEEP L3 CODEX PROMPT")

        var customLegacy = ModelsPowerLegacyState.empty
        let sharedClaude = LLMProviderBundle.claude("legacy-shared-custom", effort: "high")
        customLegacy.sharedCustomRememberedBundles[.claude] = sharedClaude
        let customMigration = store(root, "custom-adoption.json", legacy: customLegacy)
        let existingCustom = LLMRouteID.custom("pre-a4")
        let secondExistingCustom = LLMRouteID.custom("also-pre-a4")
        do {
            try customMigration.syncCustomRoutes([
                existingCustom: .local("kept-custom-local"),
                secondExistingCustom: .local("kept-second-local"),
            ])
        }
        catch { check("legacy custom routes synchronize", false) }
        check("the legacy shared custom Claude arm is adopted by each pre-existing custom route",
              customMigration.selectedBundle(for: existingCustom).modelID == "kept-custom-local"
                && customMigration.rememberedBundle(for: .claude, route: existingCustom)?.modelID
                    == "legacy-shared-custom"
                && customMigration.rememberedBundle(for: .claude, route: existingCustom)?.effort == "high"
                && customMigration.rememberedBundle(
                    for: .claude, route: secondExistingCustom)?.modelID == "legacy-shared-custom")

        let newCustom = LLMRouteID.custom("created-after-adoption")
        do {
            try customMigration.syncCustomRoutes([
                existingCustom: .local("kept-custom-local"),
                secondExistingCustom: .local("kept-second-local"),
                newCustom: .local("new-custom-local"),
            ])
        } catch { check("post-adoption custom route synchronizes", false) }
        check("the one-time legacy custom arm is not applied to later user-created routes",
              customMigration.rememberedBundle(for: .claude, route: newCustom)
                == LLMProviderDefaults.testedBundle(for: .claude, route: newCustom))
    }

    private static func checkSurfacedWriteFailures(root: URL, _ check: (String, Bool) -> Void) {
        print("--- surfaced settings, custom-mode, and user-data write failures ---")
        let settingsURL = root.appendingPathComponent("write-failure-settings.json")
        _ = ModelsPowerSettingsStore(url: settingsURL)
        let failingSettings = ModelsPowerSettingsStore(url: settingsURL, writer: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let before = failingSettings.selectedBundle(for: .email)
        var failures: [UserDataWriteFailure] = []
        var threw = false
        UserDataWriteFailureCenter.withTestObserver({ failures.append($0) }) {
            do { try failingSettings.setSelectedBundle(.local("must-not-stick"), for: .email) }
            catch ModelsPowerSettingsError.writeFailed { threw = true }
            catch {}
        }
        let reopened = ModelsPowerSettingsStore(url: settingsURL)
        check("settings write failure throws, reports, and leaves memory/disk unchanged",
              threw && failures.count == 1
                && failures[0].subsystem == "Models settings"
                && failingSettings.selectedBundle(for: .email) == before
                && reopened.selectedBundle(for: .email) == before)

        let corruptURL = root.appendingPathComponent("corrupt-settings.json")
        let corruptBytes = Data("{ definitely-not-valid-json".utf8)
        do { try corruptBytes.write(to: corruptURL, options: .atomic) }
        catch { check("corrupt settings fixture writes", false) }
        failures = []
        let corruptStore = UserDataWriteFailureCenter.withTestObserver({ failures.append($0) }) {
            ModelsPowerSettingsStore(url: corruptURL)
        }
        var corruptMutationBlocked = false
        do { try corruptStore.setSelectedBundle(.local("must-not-overwrite"), for: .email) }
        catch ModelsPowerSettingsError.writeFailed { corruptMutationBlocked = true }
        catch {}
        check("a corrupt settings file is reported and blocks every overwrite attempt",
              failures.count == 1 && failures[0].operation == "load"
                && corruptMutationBlocked && (try? Data(contentsOf: corruptURL)) == corruptBytes)

        let initialFailureURL = root.appendingPathComponent("initial-write-failure.json")
        failures = []
        let initialFailureStore = UserDataWriteFailureCenter.withTestObserver({ failures.append($0) }) {
            ModelsPowerSettingsStore(url: initialFailureURL, writer: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            })
        }
        let initialBefore = initialFailureStore.selectedBundle(for: .email)
        let initialFailureSurfaced = failures.count == 1 && failures[0].operation == "initial migration"
        failures = []
        threw = false
        UserDataWriteFailureCenter.withTestObserver({ failures.append($0) }) {
            do { try initialFailureStore.setSelectedBundle(.local("must-not-stick"), for: .email) }
            catch ModelsPowerSettingsError.writeFailed { threw = true }
            catch {}
        }
        check("initial settings creation failure is surfaced and later mutations remain fail-closed",
              initialFailureSurfaced && threw && failures.count == 1
                && initialFailureStore.selectedBundle(for: .email) == initialBefore
                && !FileManager.default.fileExists(atPath: initialFailureURL.path))

        let customURL = root.appendingPathComponent("write-failure-custom.json")
        let failingCustom = CustomModeStore(url: customURL, writer: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let mode = CustomMode(
            id: "no-write", name: "No write", chord: .regular(keyCode: 4, label: "H"),
            prompt: "test", input: .selection, model: .local("m"), landing: .inPlace)
        failures = []
        threw = false
        UserDataWriteFailureCenter.withTestObserver({ failures.append($0) }) {
            do { try failingCustom.upsert(mode) }
            catch { threw = true }
        }
        check("custom-mode write failure throws, reports, and does not publish the mutation",
              threw && failures.count == 1 && failures[0].subsystem == "custom modes"
                && failingCustom.modes.map(\.id)
                    == [StickySkillRegistry.noteToHandoffCustomModeID]
                && failingCustom.mode(id: mode.id) == nil
                && !FileManager.default.fileExists(atPath: customURL.path))
        var userDataFailures: [UserDataWriteFailure] = []
        UserDataWriteFailureCenter.withTestObserver({ userDataFailures.append($0) }) {
            UserDataWriteFailureCenter.report(
                subsystem: "dictation history", operation: "append",
                url: root.appendingPathComponent("history.md"),
                error: CocoaError(.fileWriteNoPermission))
        }
        check("the same surfaced failure seam covers non-settings user-data stores",
              userDataFailures.count == 1 && userDataFailures[0].subsystem == "dictation history"
                && userDataFailures[0].operation == "append")
        check("write failures expose a user-facing, content-free message",
              failures.first?.userMessage == "Could not save custom modes. Your last change may not persist."
                && failures.first?.detail.isEmpty == false)
    }

    private static func checkCodexPickerPolicy(
        root: URL,
        _ check: (String, Bool) -> Void
    ) {
        print("--- last-known-good Codex picker represented values ---")
        let visible = ModelCatalogRow(
            id: "preset-id-not-executable",
            model: "future/model-exec",
            displayName: "Future Display Label",
            description: "untrusted description",
            hidden: false,
            defaultReasoningEffort: "wild effort",
            supportedReasoningEfforts: [
                ModelCatalogReasoningEffort(
                    reasoningEffort: "wild effort",
                    description: "untrusted effort copy",
                    unknownFields: [:]),
                ModelCatalogReasoningEffort(
                    reasoningEffort: "x/y",
                    description: nil,
                    unknownFields: [:]),
            ],
            inputModalities: ["text"],
            supportsPersonality: nil,
            isDefault: nil,
            upgrade: nil,
            upgradeInfo: nil,
            unknownFields: [:])
        let hidden = ModelCatalogRow(
            id: "retired-id",
            model: "retired-hidden-model",
            displayName: "Must Stay Hidden",
            description: nil,
            hidden: true,
            defaultReasoningEffort: "low",
            supportedReasoningEfforts: [
                ModelCatalogReasoningEffort(
                    reasoningEffort: "low",
                    description: nil,
                    unknownFields: [:]),
            ],
            inputModalities: ["text"],
            supportsPersonality: nil,
            isDefault: nil,
            upgrade: nil,
            upgradeInfo: nil,
            unknownFields: [:])
        let catalog = ModelCatalog(rows: [visible, hidden], pageMetadata: [])
        let options = CodexPickerCatalog.visibleOptions(catalog)
        check("picker includes only visible text rows and uses display name as label only",
              options.count == 1
                && options[0].model == "future/model-exec"
                && options[0].label.contains("Future Display Label")
                && options[0].efforts == ["wild effort", "x/y"])

        let pickerStore = store(root, "picker.json")
        let selected = CodexPickerCatalog.applyingModelSelection(
            options[0].model,
            to: LLMProviderDefaults.testedBundle(for: .codex, route: .email)!)
        try? pickerStore.setSelectedBundle(selected, for: .email)
        check("id != model selection persists the exact row.model used by dispatch",
              pickerStore.selectedBundle(for: .email).modelID == "future/model-exec"
                && pickerStore.selectedBundle(for: .email).modelID
                    != "preset-id-not-executable"
                && pickerStore.selectedBundle(for: .email).ratified == nil
                && pickerStore.selectedBundle(for: .email).autoUpdated == nil)
        let effort = CodexPickerCatalog.applyingEffortSelection(
            options[0].efforts[1],
            to: pickerStore.selectedBundle(for: .email))
        try? pickerStore.setSelectedBundle(effort, for: .email)
        check("advertised effort strings persist exactly and remain open values",
              pickerStore.selectedBundle(for: .email).effort == "x/y")

        let custom = CodexPickerCatalog.applyingModelSelection(
            "offline/custom-model",
            to: pickerStore.selectedBundle(for: .email))
        check("offline custom model escape hatch remains exact without a catalog",
              CodexPickerCatalog.visibleOptions(nil).isEmpty
                && custom.modelID == "offline/custom-model")
    }
}
