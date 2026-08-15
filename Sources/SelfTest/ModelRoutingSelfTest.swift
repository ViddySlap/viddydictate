import Foundation

/// Pure A1 coverage: typed providers, stable route ids, exact incumbent defaults, bundle versioning, and
/// lossless migration of every pre-A1 ownership store. The verification rail runs this with a scratch HOME;
/// the targeted UserDefaults domain is also restored byte-for-byte before return.
enum ModelRoutingSelfTest {
    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate typed provider/route/bundle model — selftest ===")
        let reporter = SelfTestReporter()

        checkProviderIdentities(reporter.record)
        checkRouteIDs(reporter.record)
        checkPinnedDefaults(reporter.record)
        checkBundleMigration(reporter.record)
        checkSettingsMigration(reporter.record)
        checkCustomModeMigration(reporter.record)

        print("\n=== RESULT ===")
        print("typed routing model:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nTYPED ROUTING MODEL GREEN" : "\nTYPED ROUTING MODEL FAILED")
        return reporter.passed
    }

    private static func checkProviderIdentities(_ check: (String, Bool) -> Void) {
        print("--- typed provider identities ---")
        check("the provider set is exactly Local / Claude / Codex",
              LLMProvider.allCases.map(\.rawValue) == ["local", "claude", "codex"])
        check("legacy cloud migrates to Claude", LLMProvider.decodeStored("cloud") == .claude)
        check("canonical provider values round-trip without aliases",
              LLMProvider.allCases.allSatisfy { LLMProvider.decodeStored($0.rawValue) == $0 })
    }

    private static func checkRouteIDs(_ check: (String, Bool) -> Void) {
        print("--- stable LLM route ids ---")
        let expected = [
            "cleanupL1", "cleanupL2", "cleanupL3", "promptPrep", "email",
            "searchLocalSynth", "searchGeminiSynth",
        ]
        check("built-in route ids are exact and ordered", LLMRouteID.builtIns.map(\.rawValue) == expected)
        let custom = LLMRouteID.custom("A1-user-choice")
        check("each custom route is namespaced by its durable mode id",
              custom.rawValue == "custom:A1-user-choice")
        check("route raw values round-trip exactly",
              (LLMRouteID.builtIns + [custom]).allSatisfy { LLMRouteID(rawValue: $0.rawValue) == $0 })
        check("OneShot routes preserve fixed P/M/L/G identities",
              OneShotMode.cleanupSelection.routeID == .promptPrep
                && OneShotMode.email.routeID == .email
                && OneShotMode.searchLocal.routeID == .searchLocalSynth
                && OneShotMode.searchGemini.routeID == .searchGeminiSynth)
    }

    private static func checkPinnedDefaults(_ check: (String, Bool) -> Void) {
        print("--- byte-pinned Local and Claude defaults ---")
        let custom = LLMRouteID.custom("fixture")
        let routes = LLMRouteID.builtIns + [custom]
        let qwen = "qwen3-coder-30b-a3b-instruct-mlx"
        let gemma = "google/gemma-4-e4b"
        let sonnet = "claude-sonnet-5"
        let haiku = "claude-haiku-4-5-20251001"
        let localExpected: [LLMRouteID: LLMProviderBundle] = [
            .cleanupL1: .local(qwen), .cleanupL2: .local(qwen), .cleanupL3: .local(qwen),
            .promptPrep: .local(qwen), .email: .local(gemma),
            .searchLocalSynth: .local(gemma), .searchGeminiSynth: .local(gemma),
            custom: .local(qwen),
        ]
        let claudeExpected: [LLMRouteID: LLMProviderBundle] = [
            .cleanupL1: .claude(sonnet, effort: "medium"),
            .cleanupL2: .claude(sonnet, effort: "medium"),
            .cleanupL3: .claude(sonnet, effort: "medium"),
            .promptPrep: .claude(sonnet, effort: "medium"),
            .email: .claude(sonnet, effort: "medium"),
            .searchLocalSynth: .claude(haiku, effort: "high"),
            .searchGeminiSynth: .claude(haiku, effort: "medium"),
            custom: .claude(sonnet, effort: "high"),
        ]
        func sameExecutionChoice(_ a: LLMProviderBundle?, _ b: LLMProviderBundle?) -> Bool {
            a?.provider == b?.provider && a?.modelID == b?.modelID && a?.effort == b?.effort
        }
        check("every Local route execution choice is byte-for-byte the pre-A1 incumbent",
              routes.allSatisfy { sameExecutionChoice(
                  LLMProviderDefaults.testedBundle(for: .local, route: $0), localExpected[$0]) })
        check("every Claude route arm keeps the byte-for-byte ratified pre-A1 model/effort",
              routes.allSatisfy { sameExecutionChoice(
                  LLMProviderDefaults.testedBundle(for: .claude, route: $0), claudeExpected[$0]) })
        check("the existing explicit Claude dropdown keeps Sonnet with no effort argv",
              sameExecutionChoice(LLMProviderDefaults.currentClaudeSelection, .claude(sonnet)))
        let shippedClaudeDefaults = routes.compactMap {
            LLMProviderDefaults.testedBundle(for: .claude, route: $0)
        } + [LLMProviderDefaults.currentClaudeSelection]
        check("shipped Claude defaults carry exact ratification provenance",
              shippedClaudeDefaults.allSatisfy { bundle in
                  bundle.ratified?.modelID == bundle.modelID
                    && bundle.ratified?.date == LLMProviderDefaults.claudeRatificationDate
                    && bundle.ratified?.evidence == LLMProviderDefaults.claudeRatificationEvidence
                    && bundle.autoUpdated == nil
              })
        let envelope = "viddydictate-transform-v1"
        var codexExpected: [LLMRouteID: LLMProviderBundle] = [
            .cleanupL1: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-luna", effort: "low",
                basePromptVersion: "cleanup-l1-v1",
                basePromptHash: "e65dcaab45927d5eecb5c08e1bc6d26114cb462e1a6ef61edb52ae04e7809334",
                envelopeVersion: envelope),
            .cleanupL2: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.5", effort: "medium",
                basePromptVersion: "cleanup-l2-v1",
                basePromptHash: "a648ee725f01bdbbf60e8cd9676a2254664eff2d14ab0a8afa806952a8f021c8",
                envelopeVersion: envelope),
            .cleanupL3: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-luna", effort: "low",
                basePromptVersion: "qualifier-lock",
                basePromptHash: "724ce8dfdc9c9f3872a3f0ffcc31feaf7aef375ae753beaeb2fa67809f6f42f7",
                envelopeVersion: envelope),
            .promptPrep: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-sol", effort: "medium",
                basePromptVersion: "minimal-edit",
                basePromptHash: "a94d90e7e05480f266766f7a1313de668106dc6318a658ec9c253090fcad74aa",
                envelopeVersion: envelope),
            .email: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-luna", effort: "low",
                basePromptVersion: "final-format-audit",
                basePromptHash: "df664e1016fc18d892ef345de0ec0adcbd5329874fa66690e590e798874cc521",
                envelopeVersion: envelope),
            custom: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-terra", effort: "low",
                basePromptVersion: "custom-shared-task-v1",
                basePromptHash: "58967a6a5a0da7a53d50a4807a40f99d09d9d48b42d93ad3ea2905ac74662cad",
                envelopeVersion: envelope),
            .searchLocalSynth: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-luna", effort: "low",
                basePromptVersion: "search-synthesis-v1",
                basePromptHash: "ae106bbe1ac41a6a1d59496f17d1b81e2ea8caa35b66cf738313ad09273a7262",
                envelopeVersion: envelope),
            .searchGeminiSynth: LLMProviderBundle(
                provider: .codex, modelID: "gpt-5.6-luna", effort: "low",
                basePromptVersion: "search-synthesis-v1",
                basePromptHash: "ae106bbe1ac41a6a1d59496f17d1b81e2ea8caa35b66cf738313ad09273a7262",
                envelopeVersion: envelope),
        ]
        for route in codexExpected.keys {
            var bundle = codexExpected[route]!
            bundle.ratified = LLMRatificationProvenance(
                modelID: bundle.modelID,
                date: LLMProviderDefaults.codexRatificationDate,
                evidence: LLMProviderDefaults.codexRatificationEvidence)
            codexExpected[route] = bundle
        }
        codexExpected[.cleanupL1]?.ratified = LLMRatificationProvenance(
            modelID: "gpt-5.4-mini",
            date: LLMProviderDefaults.codexRatificationDate,
            evidence: LLMProviderDefaults.codexRatificationEvidence)
        codexExpected[.cleanupL1]?.autoUpdated = LLMAutoUpdateProvenance(
            fromModelID: "gpt-5.4-mini",
            date: "2026-07-27",
            reason: .deprecation)
        check("all eight shipped Codex route bundles are exact",
              codexExpected.allSatisfy {
                  LLMProviderDefaults.testedBundle(for: .codex, route: $0.key) == $0.value
              })
        check("Cleanup L1 retains only superseded ratification and is visibly auto-updated",
              LLMProviderDefaults.testedBundle(for: .codex, route: .cleanupL1)
                == codexExpected[.cleanupL1])
        check("unchanged shipped Codex defaults carry the sealed-bakeoff provenance",
              routes.filter { $0 != .cleanupL1 }.allSatisfy { route in
                  let bundle = LLMProviderDefaults.testedBundle(for: .codex, route: route)
                  return bundle?.ratified?.modelID == bundle?.modelID
                    && bundle?.ratified?.date == LLMProviderDefaults.codexRatificationDate
                    && bundle?.ratified?.evidence == LLMProviderDefaults.codexRatificationEvidence
                    && bundle?.autoUpdated == nil
              })
        let frozenD1Routes: [LLMRouteID] = [
            .cleanupL1, .cleanupL2, custom, .searchLocalSynth, .searchGeminiSynth,
        ]
        check("the D1 route identities remain exact while Cleanup L1 receives only its locked replacement",
              frozenD1Routes.allSatisfy {
                  LLMProviderDefaults.testedBundle(for: .codex, route: $0) == codexExpected[$0]
              })
        let shippedPairs = Set(routes.compactMap {
            LLMProviderDefaults.testedBundle(for: .codex, route: $0)
        }.compactMap { bundle in
            bundle.effort.map {
                CodexShippedModelPair(model: bundle.modelID, effort: $0)
            }
        })
        check("the fixed-synthetic host inventory equals every distinct shipped production pair",
              shippedPairs == Set(CodexShippedDefaults.distinctPairs)
                && Set(CodexShippedDefaults.distinctPairs).count
                    == CodexShippedDefaults.distinctPairs.count)
        check("the five D1 base-prompt hashes still match the shipped prompt bytes",
              CodexIsolationFoundation.sha256Hex(Data(firmCleanupPrompt.utf8))
                == codexExpected[.cleanupL1]?.basePromptHash
                && CodexIsolationFoundation.sha256Hex(Data(tightenCleanupPrompt.utf8))
                    == codexExpected[.cleanupL2]?.basePromptHash
                && CodexIsolationFoundation.sha256Hex(Data(defaultSearchSynthPrompt.utf8))
                    == codexExpected[.searchLocalSynth]?.basePromptHash
                && CodexIsolationFoundation.sha256Hex(
                    Data("viddydictate-custom-shared-task-prompt".utf8))
                    == codexExpected[custom]?.basePromptHash)
        let rescueRoutes: [LLMRouteID] = [.cleanupL3, .promptPrep, .email]
        check("the three sealed rescue developer-instruction texts match their ratified SHA-256 values",
              rescueRoutes.allSatisfy { route in
                  guard let text = CodexRatifiedPromptDefaults.sealedDeveloperInstructions(for: route),
                        let variant = CodexRatifiedPromptDefaults.variant(for: route) else { return false }
                  return CodexIsolationFoundation.sha256Hex(Data(text.utf8)) == variant.contentHash
                    && codexExpected[route]?.basePromptVersion == variant.id
                    && codexExpected[route]?.basePromptHash == variant.contentHash
              })
        check("ratified Codex envelope matches the isolated runtime envelope",
              LLMProviderDefaults.ratifiedCodexEnvelopeVersion == envelope
                && LLMProviderDefaults.ratifiedCodexEnvelopeVersion
                    == CodexIsolationFoundation.envelopeVersion)
        check("all installed bundles remain schema version 2 with complete Restore metadata",
              routes.allSatisfy {
                  let local = LLMProviderDefaults.testedBundle(for: .local, route: $0)
                  let claude = LLMProviderDefaults.testedBundle(for: .claude, route: $0)
                  let codex = LLMProviderDefaults.testedBundle(for: .codex, route: $0)
                  return local?.version == LLMProviderBundle.currentVersion
                    && claude?.version == LLMProviderBundle.currentVersion
                    && local?.basePromptHash?.count == 64 && claude?.basePromptHash?.count == 64
                    && local?.envelopeVersion != nil && claude?.envelopeVersion != nil
                    && codex?.version == LLMProviderBundle.currentVersion
                    && codex?.basePromptHash?.count == 64 && codex?.envelopeVersion == envelope
              })
    }

    private static func checkBundleMigration(_ check: (String, Bool) -> Void) {
        print("--- versioned provider-bundle decoding/migration ---")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let legacyCloud = Data(#"{"kind":"cloud","id":"claude-sonnet-5"}"#.utf8)
        let migrated = try? decoder.decode(LLMProviderBundle.self, from: legacyCloud)
        check("legacy ModeModel cloud/id decodes as Claude without changing the model id",
              migrated == .claude("claude-sonnet-5"))
        let canonical = migrated.flatMap { try? encoder.encode($0) }
        let canonicalObject = canonical.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        check("canonical re-encode writes version/provider/modelID and no legacy kind",
              canonicalObject?["version"] as? Int == LLMProviderBundle.currentVersion
                && canonicalObject?["provider"] as? String == "claude"
                && canonicalObject?["modelID"] as? String == "claude-sonnet-5"
                && canonicalObject?["kind"] == nil)

        let legacyArm = Data(#"{"model":"claude-opus-4-8","effort":"high"}"#.utf8)
        let migratedArm = try? decoder.decode(LLMProviderBundle.self, from: legacyArm)
        check("legacy Low Power model/effort decodes losslessly into a Claude bundle",
              migratedArm == .claude("claude-opus-4-8", effort: "high"))
        check("legacy bundles decode identically with nil update provenance",
              migrated?.ratified == nil && migrated?.autoUpdated == nil
                && migratedArm?.ratified == nil && migratedArm?.autoUpdated == nil)

        let provenanceBundle = LLMProviderBundle(
            provider: .claude, modelID: "claude-sonnet-6", effort: "medium",
            ratified: LLMRatificationProvenance(
                modelID: "claude-sonnet-5", date: "2026-07-07", evidence: "fixture evidence"),
            autoUpdated: LLMAutoUpdateProvenance(
                fromModelID: "claude-sonnet-5", date: "2026-07-20", reason: .freshness))
        let provenanceData = try? encoder.encode(provenanceBundle)
        let provenanceRoundTrip = provenanceData.flatMap {
            try? decoder.decode(LLMProviderBundle.self, from: $0)
        }
        let provenanceObject = provenanceData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let ratifiedObject = provenanceObject?["ratified"] as? [String: Any]
        let autoUpdatedObject = provenanceObject?["autoUpdated"] as? [String: Any]
        check("optional ratified and autoUpdated objects encode and decode exactly",
              provenanceRoundTrip == provenanceBundle
                && ratifiedObject?["modelID"] as? String == "claude-sonnet-5"
                && ratifiedObject?["date"] as? String == "2026-07-07"
                && ratifiedObject?["evidence"] as? String == "fixture evidence"
                && autoUpdatedObject?["fromModelID"] as? String == "claude-sonnet-5"
                && autoUpdatedObject?["date"] as? String == "2026-07-20"
                && autoUpdatedObject?["reason"] as? String == "freshness")
    }

    private static func checkSettingsMigration(_ check: (String, Bool) -> Void) {
        print("--- UserDefaults cloud -> claude migration + choice preservation ---")
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let before = defaults.persistentDomain(forName: domain)
        defer {
            if let before = before { defaults.setPersistentDomain(before, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }

        defaults.set("keep-p-local", forKey: "promptPrepModel")
        defaults.set("cloud", forKey: "promptPrepModelKind")
        defaults.set("keep-m-local", forKey: "emailModel")
        defaults.set("cloud", forKey: "emailModelKind")
        defaults.set("cleanup-local-fixture", forKey: "cleanupModel")
        defaults.set("search-synth-local-fixture", forKey: "searchSynthModel")
        defaults.set("cleanup override fixture", forKey: "cleanupSystemPrompt")
        defaults.set("tighten override fixture", forKey: "cleanupPromptLevel1")
        defaults.set("summarize override fixture", forKey: "cleanupPromptLevel2")
        defaults.set("email override fixture", forKey: "emailSystemPrompt")
        defaults.set("search synth override fixture", forKey: "searchSynthPrompt")
        check("P/M stored cloud values resolve to typed Claude",
              Settings.promptPrepProvider == .claude && Settings.emailProvider == .claude)
        check("P/M provider scalars are canonicalized to claude",
              defaults.string(forKey: "promptPrepModelKind") == "claude"
                && defaults.string(forKey: "emailModelKind") == "claude")
        check("P/M last-used Local model choices survive provider migration",
              Settings.promptPrepModel == "keep-p-local" && Settings.emailModel == "keep-m-local")

        // Exercise the old Low Power Claude memory independently from the active P/M provider choice.
        Settings.emailProvider = .local
        let legacyPolicy = Data(#"{"cleanupL2":{"model":"claude-cleanup-fixture","effort":"low"},"email":{"model":"claude-opus-4-8","effort":"high"},"searchGeminiSynth":{"model":"claude-search-fixture","effort":"medium"},"custom":{"model":"claude-sonnet-5","effort":"medium"}}"#.utf8)
        defaults.set(legacyPolicy, forKey: "lowPowerPolicy")
        let legacy = Settings.modelsPowerLegacyState()
        check("legacy cleanup routes keep selected Local and remembered provider bundles",
              LLMRouteID.cleanupRoutes.allSatisfy {
                  legacy.selectedBundles[$0] == .local("cleanup-local-fixture")
                    && legacy.rememberedBundles[$0]?[.local] == .local("cleanup-local-fixture")
              }
                && legacy.rememberedBundles[.cleanupL2]?[.claude]
                    == .claude("claude-cleanup-fixture", effort: "low"))
        let promptPrepSelection = legacy.selectedBundles[.promptPrep]
        check("legacy prompt-prep selection keeps Claude active and Local remembered",
              promptPrepSelection?.provider == .claude
                && legacy.rememberedBundles[.promptPrep]?[.claude] == promptPrepSelection
                && legacy.rememberedBundles[.promptPrep]?[.local] == .local("keep-p-local"))
        check("legacy search synthesis routes keep selected Local and remembered provider bundles",
              [LLMRouteID.searchLocalSynth, .searchGeminiSynth].allSatisfy {
                  legacy.selectedBundles[$0] == .local("search-synth-local-fixture")
                    && legacy.rememberedBundles[$0]?[.local] == .local("search-synth-local-fixture")
              }
                && legacy.rememberedBundles[.searchGeminiSynth]?[.claude]
                    == .claude("claude-search-fixture", effort: "medium"))
        check("legacy prompt overrides copy into every intended route and provider arm",
              [.local, .claude].allSatisfy { provider in
                  legacy.promptOverrides[.cleanupL1]?[provider]?[.primary] == "cleanup override fixture"
                    && legacy.promptOverrides[.cleanupL2]?[provider]?[.primary] == "tighten override fixture"
                    && legacy.promptOverrides[.cleanupL3]?[provider]?[.primary] == "summarize override fixture"
                    && legacy.promptOverrides[.promptPrep]?[provider]?[.cleanupL1] == "cleanup override fixture"
                    && legacy.promptOverrides[.promptPrep]?[provider]?[.cleanupL2] == "tighten override fixture"
                    && legacy.promptOverrides[.promptPrep]?[provider]?[.cleanupL3] == "summarize override fixture"
                    && legacy.promptOverrides[.email]?[provider]?[.primary] == "email override fixture"
                    && legacy.promptOverrides[.searchLocalSynth]?[provider]?[.primary]
                        == "search synth override fixture"
                    && legacy.promptOverrides[.searchGeminiSynth]?[provider]?[.primary]
                        == "search synth override fixture"
              })
        let email = legacy.rememberedBundles[.email]?[.claude]
        let custom = legacy.sharedCustomRememberedBundles[.claude]
        check("legacy per-route Claude choices survive bundle migration",
              email == .claude("claude-opus-4-8", effort: "high")
                && custom == .claude("claude-sonnet-5", effort: "medium"))
        let rewritten = defaults.data(forKey: "lowPowerPolicy").flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let emailObject = rewritten?["email"] as? [String: Any]
        check("Low Power storage rewrites to canonical versioned Claude bundles",
              emailObject?["version"] as? Int == LLMProviderBundle.currentVersion
                && emailObject?["provider"] as? String == "claude"
                && emailObject?["modelID"] as? String == "claude-opus-4-8"
                && emailObject?["effort"] as? String == "high"
                && emailObject?["model"] == nil)
    }

    private static func checkCustomModeMigration(_ check: (String, Bool) -> Void) {
        print("--- custom-mode cloud -> claude migration + choice preservation ---")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-a1-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let cloud = CustomMode(
            id: "cloud-choice", name: "Keep Cloud Choice",
            chord: .regular(keyCode: 3, label: "F"), prompt: "Keep this exact prompt.",
            input: .selection, model: .claude("claude-opus-4-8"), landing: .inPlace)
        let local = CustomMode(
            id: "local-choice", name: "Keep Local Choice",
            chord: .regular(keyCode: 5, label: "G"), prompt: "Keep local too.",
            input: .both, model: .local("user/custom-local-model"), landing: .note)

        let encoder = JSONEncoder()
        guard let canonical = try? encoder.encode([cloud, local]),
              var rows = try? JSONSerialization.jsonObject(with: canonical) as? [[String: Any]] else {
            check("legacy custom fixture can be prepared", false)
            return
        }
        rows[0]["model"] = ["kind": "cloud", "id": "claude-opus-4-8"]
        rows[1]["model"] = ["kind": "local", "id": "user/custom-local-model"]
        guard let legacy = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]),
              (try? legacy.write(to: url, options: .atomic)) != nil else {
            check("legacy custom fixture can be written", false)
            return
        }

        let store = CustomModeStore(url: url)
        let loadedCloud = store.mode(id: "cloud-choice")
        let loadedLocal = store.mode(id: "local-choice")
        check("legacy custom cloud choice becomes typed Claude with the same exact model",
              loadedCloud?.model == .claude("claude-opus-4-8"))
        check("custom Local model, prompt, input, landing, chord, and id are preserved",
              loadedLocal?.model == .local("user/custom-local-model")
                && loadedLocal?.prompt == "Keep local too."
                && loadedLocal?.input == .both && loadedLocal?.landing == .note
                && loadedLocal?.chord == .regular(keyCode: 5, label: "G"))
        check("each loaded custom mode has its own stable route id",
              loadedCloud?.routeID.rawValue == "custom:cloud-choice"
                && loadedLocal?.routeID.rawValue == "custom:local-choice")

        let rewrittenRows = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
        }
        let rewrittenModel = rewrittenRows?.first?["model"] as? [String: Any]
        check("custom store is rewritten with canonical Claude bundle ownership",
              rewrittenModel?["version"] as? Int == LLMProviderBundle.currentVersion
                && rewrittenModel?["provider"] as? String == "claude"
                && rewrittenModel?["modelID"] as? String == "claude-opus-4-8"
                && rewrittenModel?["kind"] == nil)
    }
}
