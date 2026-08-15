import Foundation

enum ModelFreshnessSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate cloud preset freshness - selftest ===")
        let reporter = SelfTestReporter()

        checkParsing(reporter.record)
        checkCache(reporter.record)
        checkVersionProbe(reporter.record)
        checkClaudePresetPolicy(reporter.record)
        checkUpdateSurfaces(reporter.record)
        CodexModelUpdaterSelfTest.run(reporter.record)

        print("\n=== RESULT ===")
        print("model freshness:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nMODEL FRESHNESS GREEN" : "\nMODEL FRESHNESS FAILED")
        return reporter.passed
    }

    private static func checkParsing(_ check: (String, Bool) -> Void) {
        print("--- result JSON modelUsage parsing ---")
        let mixedFamilyFixtureURL = URL(fileURLWithPath:
            "Sources/SelfTest/Fixtures/model-freshness-sonnet.json")
        let singleKeyFixtureURL = URL(fileURLWithPath:
            "Sources/SelfTest/Fixtures/model-freshness-single-key.json")
        let ambiguousFixtureURL = URL(fileURLWithPath:
            "Sources/SelfTest/Fixtures/model-freshness-ambiguous-sonnet.json")
        let mixedFamilyFixture =
            (try? String(contentsOf: mixedFamilyFixtureURL, encoding: .utf8)) ?? ""
        let singleKeyFixture =
            (try? String(contentsOf: singleKeyFixtureURL, encoding: .utf8)) ?? ""
        let ambiguousFixture =
            (try? String(contentsOf: ambiguousFixtureURL, encoding: .utf8)) ?? ""
        check("mixed-family modelUsage resolves the probed sonnet family",
              ModelFreshnessProbe.resolvedModelID(
                fromJSON: mixedFamilyFixture, alias: "sonnet")
                == "claude-sonnet-6-20260715")
        check("a warning prefix before result JSON remains parseable",
              ModelFreshnessProbe.resolvedModelID(
                fromJSON: "warning\n\(mixedFamilyFixture)", alias: "sonnet")
                == "claude-sonnet-6-20260715")
        check("single-key modelUsage resolves its one family match",
              ModelFreshnessProbe.resolvedModelID(
                fromJSON: singleKeyFixture, alias: "haiku")
                == "claude-haiku-4-5-20251001")
        check("two same-family modelUsage keys fail closed as ambiguous",
              ModelFreshnessProbe.resolvedModelID(
                fromJSON: ambiguousFixture, alias: "sonnet") == nil)
        check("missing or zero-family modelUsage matches fail closed",
              ModelFreshnessProbe.resolvedModelID(
                fromJSON: #"{"result":"OK"}"#, alias: "sonnet") == nil
                && ModelFreshnessProbe.resolvedModelID(
                    fromJSON: mixedFamilyFixture, alias: "opus") == nil)
        check("only explicit model-registry errors signal deprecation",
              ModelFreshnessProbe.explicitlyReportsUnknownModel(
                stdout: "", stderr: "Error: unknown model claude-old")
                && !ModelFreshnessProbe.explicitlyReportsUnknownModel(
                    stdout: #"{"is_error":true,"result":"transform failed"}"#, stderr: ""))
    }

    private static func checkCache(_ check: (String, Bool) -> Void) {
        print("--- app-local cache round trip ---")
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-model-freshness-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("model-freshness.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ModelFreshnessCache(
            checkedAt: "2026-07-19T23:59:00Z",
            resolutions: ["sonnet": .resolved("claude-sonnet-6")])
        do { try ModelFreshnessProbe.save(cache, to: url) }
        catch { check("freshness cache writes", false) }
        check("freshness results and timestamp round-trip",
              ModelFreshnessProbe.loadCache(from: url) == cache)

        // A file written before ADR 0014 still carries the held-candidate map. Decoding must ignore
        // it rather than fail, or an upgrading install loses its alias resolutions.
        let legacy = """
        {"version":1,"checkedAt":"2026-07-19T23:59:00Z",\
        "resolutions":{"sonnet":{"state":"resolved","modelID":"claude-sonnet-6"}},\
        "failedCandidates":{"cleanupL3":{"modelID":"x","checkedAt":"2026-07-19T23:59:00Z"}}}
        """
        let legacyURL = root.appendingPathComponent("legacy.json")
        do { try Data(legacy.utf8).write(to: legacyURL) }
        catch { check("legacy freshness fixture writes", false) }
        check("a pre-ADR-0014 cache file still decodes, dropping the held-candidate map",
              ModelFreshnessProbe.loadCache(from: legacyURL) == cache)
    }

    private static func checkVersionProbe(_ check: (String, Bool) -> Void) {
        print("--- bounded CLI version probe ---")
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-version-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func executable(_ name: String, body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }

        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let normal = try executable(
                "normal-version", body: "printf ' \\n  codex-cli 9.9  \\n'")
            check("version probe returns the first nonempty trimmed line",
                  CloudUpdateChecker.versionForTest(
                    executable: normal.path, timeout: 1) == "codex-cli 9.9")

            let hanging = try executable(
                "hanging-version", body: "sleep 10\nprintf 'too late\\n'")
            let started = Date()
            let timedOut = CloudUpdateChecker.versionForTest(
                executable: hanging.path, timeout: 0.1)
            check("version probe timeout returns nil without hanging",
                  timedOut == nil && Date().timeIntervalSince(started) < 2)

            let stdoutOverflow = try executable(
                "stdout-overflow", body: "/usr/bin/yes x | /usr/bin/head -c 65537")
            let stderrOverflow = try executable(
                "stderr-overflow", body: "/usr/bin/yes x | /usr/bin/head -c 65537 >&2")
            check("version probe rejects stdout and stderr beyond their capture limits",
                  CloudUpdateChecker.versionForTest(
                    executable: stdoutOverflow.path, timeout: 1) == nil
                    && CloudUpdateChecker.versionForTest(
                        executable: stderrOverflow.path, timeout: 1) == nil)
        } catch {
            check("bounded CLI version probe fixture setup", false)
        }
    }

    /// The Claude preset truth table under ADR 0014. Every row here is a product claim: what the app
    /// does to a user's pinned route when the Claude catalog says a particular thing.
    private static func checkClaudePresetPolicy(_ check: (String, Bool) -> Void) {
        print("--- Claude preset policy truth table (ADR 0014) ---")
        let checkedAt = "2026-07-29T00:05:00Z"
        let liveSonnet = "claude-sonnet-5"
        let olderLiveSonnet = "claude-sonnet-4-5-20250929"
        let liveHaiku = "claude-haiku-4-5-20251001"
        let retiredSonnet = "claude-sonnet-4-20240101"
        let retiredLegacyHaiku = "claude-3-5-haiku-20241022"
        let catalog = ClaudeCatalogFixture.catalog(
            (liveSonnet, ["low", "medium", "high"]),
            (olderLiveSonnet, []),
            (liveHaiku, []),
            ("claude-opus-5", ["low", "medium", "high", "xhigh", "max"]))
        let provenance = LLMRatificationProvenance(
            modelID: retiredSonnet, date: "2026-07-07", evidence: "fixture ratification")

        func claude(_ id: String, effort: String? = "medium",
                    ratified: LLMRatificationProvenance? = nil) -> LLMProviderBundle {
            LLMProviderBundle(provider: .claude, modelID: id, effort: effort, ratified: ratified)
        }

        let routes: [PresetUpdateRoute] = [
            PresetUpdateRoute(route: .cleanupL1,
                              bundle: claude(retiredSonnet, ratified: provenance)),
            PresetUpdateRoute(route: .cleanupL2, bundle: claude(olderLiveSonnet)),
            PresetUpdateRoute(route: .cleanupL3,
                              bundle: claude(retiredLegacyHaiku, effort: nil)),
            PresetUpdateRoute(route: .promptPrep, bundle: claude("claude-fable-2")),
            PresetUpdateRoute(route: .email, bundle: claude("sonnet-latest")),
            PresetUpdateRoute(route: .searchLocalSynth, bundle: .local("local-fixture")),
            PresetUpdateRoute(route: .searchGeminiSynth, bundle: .codex("gpt-fixture")),
        ]

        let source = ClaudeModelCatalogSource(discover: { at in
            ModelCatalogCheckResult(
                catalog: catalog, checkedAt: at, isStale: false, diagnostic: .current)
        })
        let refreshed = source.discover(checkedAt: checkedAt)
        check("the Claude catalog populates from what the source acquired",
              refreshed.diagnostic == .current && !refreshed.isStale
                && refreshed.catalog?.rows.count == 4)

        let actions = CloudUpdateChecker.migrationActions(
            routes: routes, catalog: catalog, source: source)
        let decisions = Dictionary(uniqueKeysWithValues: PresetUpdatePolicy.decide(
            routes: routes, checkedAt: checkedAt, migration: actions).map { ($0.route, $0) })

        let migrated = decisions[.cleanupL1]
        check("a retired pin migrates to the newest live model in its own family",
              migrated?.disposition == .swapped(.deprecation)
                && migrated?.resultingBundle.modelID == liveSonnet)
        check("a migrated pin is marked unratified auto-updated with exact provenance",
              migrated?.resultingBundle.autoUpdated == LLMAutoUpdateProvenance(
                fromModelID: retiredSonnet, date: checkedAt, reason: .deprecation)
                && CloudUpdateSurface.provenanceBadge(bundle: migrated!.resultingBundle)
                    == "AUTO-UPDATED \(checkedAt) unratified")
        check("a migration preserves the superseded ratification claim and the stored effort",
              migrated?.resultingBundle.ratified == provenance
                && migrated?.resultingBundle.effort == "medium")

        check("a live pin is left alone even though the same catalog lists a newer model",
              decisions[.cleanupL2]?.disposition == .unchanged
                && decisions[.cleanupL2]?.resultingBundle == routes[1].bundle
                && decisions[.cleanupL2]?.resultingBundle.autoUpdated == nil)

        let legacy = decisions[.cleanupL3]
        check("a retired legacy-spelling pin migrates and keeps carrying no effort",
              legacy?.disposition == .swapped(.deprecation)
                && legacy?.resultingBundle.modelID == liveHaiku
                && legacy?.resultingBundle.effort == nil)

        check("an absent family is held, never promoted into another family",
              decisions[.promptPrep]?.disposition == .held(.unknownSource)
                && decisions[.promptPrep]?.resultingBundle == routes[3].bundle)
        check("an unparseable pin is held rather than guessed at",
              decisions[.email]?.disposition == .held(.unknownSource)
                && decisions[.email]?.resultingBundle == routes[4].bundle)
        check("Local routes remain untouched",
              decisions[.searchLocalSynth]?.disposition == .unchanged
                && decisions[.searchLocalSynth]?.resultingBundle == .local("local-fixture"))
        check("Codex routes stay detect-only; CodexModelUpdater owns their rail",
              decisions[.searchGeminiSynth]?.disposition == .codexDetectOnly
                && decisions[.searchGeminiSynth]?.resultingBundle == .codex("gpt-fixture"))

        check("the index-keyed plan correlates back onto exactly the Claude routes",
              actions.keys.sorted { $0.rawValue < $1.rawValue }
                == [LLMRouteID.cleanupL1, .cleanupL2, .cleanupL3, .email, .promptPrep]
                    .sorted { $0.rawValue < $1.rawValue })

        let blind = Dictionary(uniqueKeysWithValues: PresetUpdatePolicy.decide(
            routes: routes, checkedAt: checkedAt, migration: [:]).map { ($0.route, $0) })
        check("with no usable catalog no Claude route moves and none is judged",
              blind[.cleanupL1]?.disposition == .catalogUnavailable
                && blind[.cleanupL1]?.resultingBundle == routes[0].bundle
                && blind[.cleanupL3]?.disposition == .catalogUnavailable)

        // The end of the product path: the migrated bundle actually lands in the durable store and
        // reads back unratified, rather than only existing as a decision.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-claude-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("models-power.json"))
        try? store.setRememberedBundle(routes[0].bundle, for: .claude, route: .cleanupL1)
        try? store.setRememberedBundle(
            migrated?.resultingBundle ?? routes[0].bundle, for: .claude, route: .cleanupL1)
        let persisted = store.rememberedBundle(for: .claude, route: .cleanupL1)
        check("the migrated Claude pin persists as the route's remembered bundle",
              persisted?.modelID == liveSonnet
                && persisted?.autoUpdated?.reason == .deprecation
                && persisted?.autoUpdated?.fromModelID == retiredSonnet)
    }

    private static func checkUpdateSurfaces(_ check: (String, Bool) -> Void) {
        print("--- update surface labels and toast assembly ---")
        let checkedAt = "2026-07-20T08:15:00Z"
        let ratified = LLMProviderBundle(
            provider: .claude, modelID: "claude-sonnet-5", effort: "medium",
            ratified: LLMRatificationProvenance(
                modelID: "claude-sonnet-5", date: "2026-07-07", evidence: "fixture"))
        var updated = ratified
        updated.modelID = "claude-sonnet-6"
        updated.autoUpdated = LLMAutoUpdateProvenance(
            fromModelID: "claude-sonnet-5", date: checkedAt, reason: .deprecation)
        let heldCache = ModelFreshnessCache(
            checkedAt: checkedAt,
            resolutions: ["sonnet": .resolved("claude-sonnet-6")])

        check("ratified route badge names the ratified model",
              CloudUpdateSurface.provenanceBadge(bundle: ratified)
                == "RATIFIED claude-sonnet-5")
        check("auto-updated route badge is visibly unratified",
              CloudUpdateSurface.provenanceBadge(bundle: updated)
                == "AUTO-UPDATED 2026-07-20T08:15:00Z unratified")
        // The provenance ROW composes the bundle's badge with the store's derived verdict (item P11). The
        // badge alone cannot see a prompt override, which is how a route kept showing a green RATIFIED line
        // after the user replaced the prompt bytes while the store said the slate was no longer covered.
        check("a ratified slate with no derived objection reads exactly as its badge",
              CloudUpdateSurface.provenanceRow(
                bundle: ratified, ratification: .ratified(ratified.ratified!))
                == "RATIFIED claude-sonnet-5")
        check("a prompt override turns a ratified row unratified and says why",
              CloudUpdateSurface.provenanceRow(
                bundle: ratified, ratification: .unratified([.promptOverridden]))
                == "UNRATIFIED claude-sonnet-5 - your prompt edit replaced the tested wording")
        check("evidence that covers another model is named rather than left as a bare UNRATIFIED",
              CloudUpdateSurface.provenanceRow(
                bundle: updated, ratification: .unratified([.evidenceCoversAnotherModel]))
                == "AUTO-UPDATED 2026-07-20T08:15:00Z unratified - "
                    + "the tested slate covers a different model")
        check("co-occurring reasons are both reported, in declaration order",
              CloudUpdateSurface.provenanceRow(
                bundle: ratified,
                ratification: .unratified([.evidenceCoversAnotherModel, .promptOverridden]))
                == "UNRATIFIED claude-sonnet-5 - the tested slate covers a different model; "
                    + "your prompt edit replaced the tested wording")
        // Local arms never carry ratification evidence, so restating noEvidence would append a clause to
        // every Local row without adding a fact the badge does not already carry.
        check("a bare no-evidence verdict adds no clause to the badge",
              CloudUpdateSurface.provenanceRow(
                bundle: LLMProviderBundle(provider: .local, modelID: "gemma", effort: nil),
                ratification: .unratified([.noEvidence])) == "LOCAL gemma")
        check("every unratified reason has its own user-facing wording",
              Set(LLMUnratifiedReason.allCases.map(CloudUpdateSurface.unratifiedReasonText)).count
                == LLMUnratifiedReason.allCases.count)
        check("last-checked line distinguishes never from a cached check",
              CloudUpdateSurface.lastCheckedText(cache: nil)
                == "Cloud presets: last checked never"
                && CloudUpdateSurface.lastCheckedText(cache: heldCache)
                    == "Cloud presets: last checked 2026-07-20T08:15:00Z")
        check("restart cloud preset auto-check defaults on",
              Settings.cloudUpdateAutoCheckDefault)

        let healthy = CloudUpdateCheckResult(
            checkedAt: checkedAt, claudeVersion: "2.1.214",
            aliasResolutions: ["sonnet": .resolved("claude-sonnet-5")],
            codexVendoredVersion: "codex-cli 0.144.2",
            codexPinnedVersion: "codex-cli 0.144.2", changes: [], failures: [],
            claudeAvailability: .available)
        check("healthy unchanged check gets the compact success toast",
              CloudUpdateSurface.toastLines(for: healthy) == ["Cloud presets up to date"]
                && !CloudUpdateSurface.requiresFullToast(healthy))

        let changed = CloudUpdateCheckResult(
            checkedAt: checkedAt, claudeVersion: "2.1.214",
            aliasResolutions: ["sonnet": .resolved("claude-sonnet-6")],
            codexVendoredVersion: "codex-cli 0.145.0-alpha.18",
            codexPinnedVersion: "codex-cli 0.144.2",
            changes: [CloudPresetChange(
                route: .cleanupL1, fromModelID: "claude-sonnet-5",
                toModelID: "claude-sonnet-6", reason: .deprecation)],
            failures: [
                "Claude sonnet: live probe failed (fixture)",
            ], claudeAvailability: .available)
        let changedLines = CloudUpdateSurface.toastLines(for: changed)
        check("changes and failures assemble into the full outcome toast",
              CloudUpdateSurface.requiresFullToast(changed)
                && changedLines == [
                    "cleanup L1 -> claude-sonnet-6 (unratified - auto-updated)",
                    "Claude sonnet: live probe failed (fixture)",
                ])
        let pending = CodexUpdateOutcomeRecord(
            state: .compatibilityQuarantinePending,
            lastAttempt: checkedAt,
            lastSuccessfulCatalogTime: nil,
            reasonCode: "compatibility_pending",
            nextRetry: nil)
        let failed = CodexUpdateOutcomeRecord(
            state: .compatibilityQuarantineFailed,
            lastAttempt: checkedAt,
            lastSuccessfulCatalogTime: nil,
            reasonCode: "compatibility_boundary",
            nextRetry: nil)
        check("provider live status exposes Claude resolution and compatible newer Codex",
              CloudUpdateSurface.providerLiveStatus(
                .claude, latest: changed, cache: heldCache)
                == "Live 2.1.214: sonnet -> claude-sonnet-6"
                && CloudUpdateSurface.providerLiveStatus(
                    .codex,
                    latest: changed,
                    cache: heldCache,
                    codexAvailability: .available)
                    == "Live: compatible newer CLI codex-cli 0.145.0-alpha.18")
        check("Codex live status distinguishes compatibility pending and failed",
              CloudUpdateSurface.providerLiveStatus(
                .codex,
                latest: changed,
                cache: heldCache,
                codexOutcome: pending,
                codexAvailability: .available)
                == "Live: compatibility quarantine pending"
                && CloudUpdateSurface.providerLiveStatus(
                    .codex,
                    latest: changed,
                    cache: heldCache,
                    codexOutcome: failed,
                    codexAvailability: .unavailable("fixture"))
                    == "Live: compatibility quarantine failed")
    }
}
