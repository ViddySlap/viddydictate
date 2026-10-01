import Foundation

/// Ollama lane D11 (`--staff-picks-copy-selftest`): every built-in default reads as a **Staff pick** wherever the
/// user can see it, and ratification stays internal. Deterministic: it calls the real label-producing functions
/// (`StaffPicks`, `LocalModelPickerItems`, `CodexUpdateSurface`, `CloudUpdateSurface`, `LocalAppRows`, the store's
/// error copy) and one scratch `ModelsPowerSettingsStore` under a temporary folder. No view, no window, no
/// LM Studio, no Ollama, no network.
///
/// What it scans: the preset badge and row for a ratified, an unratified and an auto-updated default and for an
/// Ollama default; a user's own model; the prompt state label and summary for a default and a customized
/// prompt; the global control title; both pickers' qualifiers; the Codex migration status and toast lines; the
/// cloud preset toast; the Preferred local app hint; the prompt editor's Restore title. Every one must say Staff
/// pick (or Custom / Customized for the user's own choice) exactly, and none may contain "ratif" (any case),
/// "Tested default" or "AUTO-UPDATED".
///
/// The surface-only rule: a ratified bundle still carries its `ratified` provenance after a store round-trip
/// (written, reopened from disk, read back), and the store still derives `.ratified` for it.
///
/// Negative controls: the contract is re-run against two broken label sets, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) a badge function that still returns "UNRATIFIED <model>" for an unratified default;
/// (b) a prompt label that still returns "Tested default".
enum StaffPicksCopyFixtureSelfTest {

    // Assertion names the negative controls look up.
    private static let unratifiedBadgeCheck = "an unratified default (a Local arm) reads STAFF PICK"
    private static let promptLabelCheck = "an unedited prompt reads Staff pick, an edited one Customized"

    private static let forbidden = ["Tested default", "AUTO-UPDATED"]

    /// The label functions under test, so a mutant can stand in for either.
    struct Subject {
        let badge: (LLMProviderBundle, LLMRouteID) -> String
        let promptLabel: (LLMPromptCustomizationState) -> String
    }

    private static let real = Subject(badge: { StaffPicks.badge(bundle: $0, route: $1) },
                                      promptLabel: { StaffPicks.promptStateLabel($0) })

    static func run() -> Bool {
        print("=== D11: every built-in default reads as a Staff pick, and ratification stays internal ===")
        let reporter = SelfTestReporter()

        print("--- badges, rows and prompt labels (real StaffPicks) ---")
        checkContract(real, reporter)
        print("--- the rest of the user-visible copy ---")
        checkSurfaces(reporter)
        print("--- ratification survives a store round-trip ---")
        checkProvenanceSurvives(reporter)
        print("--- negative controls ---")
        checkNegativeControls(reporter)

        print(reporter.summaryLine(prefix: "[staff-picks-copy-selftest]"))
        return reporter.passed
    }

    // MARK: - Contract

    private static func checkContract(_ subject: Subject, _ r: SelfTestReporter) {
        guard let ratified = LLMProviderDefaults.testedBundle(for: .claude, route: .email),
              let unratified = LLMProviderDefaults.testedBundle(for: .local, route: .email),
              let autoUpdated = LLMProviderDefaults.testedBundle(for: .codex, route: .cleanupL1) else {
            r.record("the shipped defaults this gate reads exist", false)
            return
        }
        r.record("the fixtures are what they claim: ratified, unratified, and auto-updated",
                 ratified.ratified?.modelID == ratified.modelID && ratified.autoUpdated == nil
                    && unratified.ratified == nil && unratified.autoUpdated == nil
                    && autoUpdated.autoUpdated != nil && autoUpdated.ratified != nil
                    && autoUpdated.ratified?.modelID != autoUpdated.modelID,
                 "\(ratified.modelID) / \(unratified.modelID) / \(autoUpdated.modelID)")

        let ratifiedBadge = subject.badge(ratified, .email)
        let unratifiedBadge = subject.badge(unratified, .email)
        let autoBadge = subject.badge(autoUpdated, .cleanupL1)
        r.record("a ratified default reads STAFF PICK",
                 ratifiedBadge == "STAFF PICK \(ratified.modelID)", ratifiedBadge)
        r.record(unratifiedBadgeCheck, unratifiedBadge == "STAFF PICK \(unratified.modelID)", unratifiedBadge)
        r.record("an auto-updated default reads STAFF PICK, naming the model it runs now",
                 autoBadge == "STAFF PICK \(autoUpdated.modelID)", autoBadge)

        let ollamaPick = LLMProviderBundle.local(
            ref: LocalModelRef(backend: .ollama, modelID: BootstrapInstallPlan.ollamaEmailModelID))
        let ollamaBadge = subject.badge(ollamaPick, .email)
        r.record("Ollama's own tag for the route's family reads STAFF PICK too",
                 ollamaBadge == "STAFF PICK \(BootstrapInstallPlan.ollamaEmailModelID)", ollamaBadge)

        let userCloud = CodexPickerCatalog.applyingModelSelection("staff-picks-fixture-model", to: ratified)
        let userEffort = CodexPickerCatalog.applyingEffortSelection("low", to: ratified)
        let userLocal = LLMProviderBundle.local("staff-picks-fixture/local-model")
        r.record("a user's own model or effort reads CUSTOM",
                 subject.badge(userCloud, .email) == "CUSTOM staff-picks-fixture-model"
                    && subject.badge(userEffort, .email) == "CUSTOM \(ratified.modelID)"
                    && subject.badge(userLocal, .email) == "CUSTOM staff-picks-fixture/local-model",
                 "\(subject.badge(userCloud, .email)) / \(subject.badge(userEffort, .email))")

        let defaultLabel = subject.promptLabel(.testedDefault)
        let customLabel = subject.promptLabel(.customized)
        r.record(promptLabelCheck, defaultLabel == "Staff pick" && customLabel == "Customized",
                 "\(defaultLabel) / \(customLabel)")

        let shown = [ratifiedBadge, unratifiedBadge, autoBadge, ollamaBadge, defaultLabel, customLabel]
        r.record("no badge or prompt label carries an evidence word", shown.allSatisfy(isClean),
                 shown.filter { !isClean($0) }.joined(separator: " | "))
    }

    // MARK: - Every other surface

    private static func checkSurfaces(_ r: SelfTestReporter) {
        guard let ratified = LLMProviderDefaults.testedBundle(for: .claude, route: .email),
              let autoUpdated = LLMProviderDefaults.testedBundle(for: .codex, route: .cleanupL1),
              let tested = LLMProviderDefaults.testedBundle(for: .local, route: .email) else {
            r.record("the shipped defaults this gate reads exist", false)
            return
        }
        var shown: [String] = []
        func expect(_ name: String, _ actual: String, _ expected: String) {
            shown.append(actual)
            r.record(name, actual == expected, actual)
        }

        expect("a staff pick with the shipped prompt is its badge alone",
               StaffPicks.provenanceRow(bundle: ratified, route: .email,
                                        ratification: .ratified(ratified.ratified!)),
               "STAFF PICK \(ratified.modelID)")
        expect("a prompt edit keeps STAFF PICK and notes the custom prompt",
               StaffPicks.provenanceRow(bundle: ratified, route: .email,
                                        ratification: .unratified([.promptOverridden])),
               "STAFF PICK \(ratified.modelID) - custom prompt")
        expect("evidence covering another model stays internal",
               StaffPicks.provenanceRow(bundle: autoUpdated, route: .cleanupL1,
                                        ratification: .unratified([.evidenceCoversAnotherModel])),
               "STAFF PICK \(autoUpdated.modelID)")
        expect("the prompt summary reads Staff pick", StaffPicks.promptSummary(customized: false),
               "Prompt: Staff pick")
        expect("the prompt summary reads Customized once edited", StaffPicks.promptSummary(customized: true),
               "Prompt: Customized")
        expect("the global control reads Set every route to its staff pick", StaffPicks.globalControlTitle,
               "Set every route to its staff pick:")
        expect("the Codex global button's tooltip names staff picks", StaffPicks.codexGlobalToolTip,
               "Uses Codex's staff pick on all eight routes.")
        expect("a provider with no default for the route says No staff pick",
               StaffPicks.providerCoverageSuffix(defaults: 0, of: 3), " · No staff pick")
        expect("a provider with some defaults counts staff picks",
               StaffPicks.providerCoverageSuffix(defaults: 2, of: 3), " · 2/3 staff picks")
        expect("the prompt editor's Restore button reads Restore staff pick", StaffPicks.restorePromptTitle,
               "Restore staff pick")
        expect("the customized editor subtitle names the Restore button",
               StaffPicks.customizedPromptSubtitle,
               "Customized. Restore staff pick, then Save, clears your override.")
        expect("the Preferred local app hint says staff picks",
               LocalAppRows.preferenceHint,
               "Which app new routes and staff picks use, and the one ViddyDictate may start in the background. "
                + "Automatic follows what is installed, and picks LM Studio when both or neither are.")
        expect("the store's no-default error says staff pick",
               ModelsPowerSettingsError.noTestedDefault(provider: .codex, route: .searchRetrieval).description,
               "No codex staff pick exists for searchRetrieval")

        // The pickers: the routing grid qualifies each app's copy of the default, the Sticky Skill card its row.
        let ollamaRef = LocalModelRef(backend: .ollama, modelID: BootstrapInstallPlan.ollamaEmailModelID)
        let catalog = [
            LMStudioModelOption(modelID: tested.modelID, label: "staff-picks-fixture-lms"),
            LMStudioModelOption(modelID: ollamaRef.modelID, label: "staff-picks-fixture-ollama", backend: .ollama),
            LMStudioModelOption(modelID: "staff-picks-fixture/pin", label: "staff-picks-fixture-pin"),
        ]
        let grid = LocalModelPickerItems.routingGrid(
            catalog: catalog, pinned: .local("staff-picks-fixture/pin"), tested: tested).map(\.title)
        shown += grid
        r.record("the routing grid marks both apps' staff picks and the user's pin Custom",
                 grid == [
                    "LM Studio · staff-picks-fixture-lms  ·  Staff pick",
                    "LM Studio · staff-picks-fixture-pin  ·  Custom",
                    "",
                    "Ollama · staff-picks-fixture-ollama  ·  Staff pick",
                 ], grid.joined(separator: " | "))
        let sticky = LocalModelPickerItems.stickySkill(
            catalog: [LMStudioModelOption(modelID: "staff-picks-fixture/other", label: "staff-picks-fixture-other")],
            pinned: .local("staff-picks-fixture/pin"), tested: tested).map(\.title)
        shown += sticky
        let stickyName = tested.modelID.contains("/")
            ? String(tested.modelID.split(separator: "/").last!) : tested.modelID
        r.record("the Sticky Skill picker's default row reads Staff pick, the pin Current",
                 sticky == ["staff-picks-fixture-other", stickyName + " - Staff pick", "pin - Current"],
                 sticky.joined(separator: " | "))

        // Codex and Claude update copy.
        let migratedRecord = CodexUpdateOutcomeRecord(
            state: .routesMigrated, lastAttempt: "2026-09-30T12:00:00Z",
            lastSuccessfulCatalogTime: "2026-09-30T12:00:00Z", reasonCode: nil, nextRetry: nil)
        expect("the Codex status line after a migration names new staff picks",
               CodexUpdateSurface.statusText(migratedRecord), "Codex routes migrated to new staff picks")
        let migrated = CodexModelUpdateOutcome(
            status: .current, checkedAt: "2026-09-30T12:00:00Z", applied: [.cleanupL1], skipped: [],
            held: [], recommendations: [], plannerHolds: [:])
        let codexToast = CodexUpdateSurface.toastLines(for: migrated)
        shown += codexToast
        r.record("the Codex migration toast names new staff picks",
                 codexToast == ["Codex routes migrated to new staff picks"], codexToast.joined(separator: " | "))
        let cloud = CloudUpdateCheckResult(
            checkedAt: "2026-09-30T12:00:00Z", claudeVersion: nil, aliasResolutions: [:],
            codexVendoredVersion: nil, codexPinnedVersion: "staff-picks-fixture", changes: [CloudPresetChange(
                route: .email, fromModelID: "staff-picks-fixture-old", toModelID: "staff-picks-fixture-new",
                reason: .deprecation)], failures: [], claudeAvailability: .available)
        let cloudToast = CloudUpdateSurface.toastLines(for: cloud)
        shown += cloudToast
        r.record("the cloud preset toast calls a moved route a new staff pick",
                 cloudToast.count == 1 && cloudToast[0].hasSuffix("-> staff-picks-fixture-new (new staff pick)"),
                 cloudToast.joined(separator: " | "))

        r.record("no scanned surface carries an evidence word", shown.allSatisfy(isClean),
                 shown.filter { !isClean($0) }.joined(separator: " | "))
    }

    // MARK: - Surface only

    private static func checkProvenanceSurvives(_ r: SelfTestReporter) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-staff-picks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            r.record("scratch root", false, error.localizedDescription)
            return
        }
        guard let ratified = LLMProviderDefaults.testedBundle(for: .claude, route: .email),
              let evidence = ratified.ratified else {
            r.record("the Claude Email default carries ratification", false)
            return
        }
        let url = root.appendingPathComponent("models-power.json")
        do { try ModelsPowerSettingsStore(url: url).setSelectedBundle(ratified, for: .email) }
        catch {
            r.record("scratch store write", false, error.localizedDescription)
            return
        }
        let reopened = ModelsPowerSettingsStore(url: url)
        let back = reopened.selectedBundle(for: .email)
        r.record("a ratified bundle keeps its ratified provenance across a store round-trip",
                 back.provider == .claude && back.ratified == evidence && back.modelID == ratified.modelID,
                 "\(back.ratified?.date ?? "nil") \(back.ratified?.evidence ?? "nil")")
        r.record("the store still derives the ratified verdict for it",
                 reopened.ratificationState(for: .email, provider: .claude) == .ratified(evidence))
        let bytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        r.record("the persisted file keeps the internal ratified key and never the on-screen words",
                 bytes.contains("\"ratified\"") && !bytes.contains("STAFF PICK") && !bytes.contains("Staff pick"))
        r.record("the row reads STAFF PICK for the reopened bundle",
                 StaffPicks.provenanceRow(bundle: back, route: .email,
                                          ratification: reopened.ratificationState(for: .email, provider: .claude))
                    == "STAFF PICK \(ratified.modelID)")
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) The pre-D11 badge for an arm with no evidence.
        let unratifiedBadge = Subject(badge: { bundle, route in
            bundle.ratified == nil ? "UNRATIFIED \(bundle.modelID)" : real.badge(bundle, route)
        }, promptLabel: real.promptLabel)
        requireCaught(reporter, mutant: "badge that still says UNRATIFIED for an unratified default",
                      by: unratifiedBadgeCheck) { checkContract(unratifiedBadge, $0) }

        // (b) The pre-D11 prompt label.
        let testedDefaultLabel = Subject(badge: real.badge, promptLabel: { state in
            state == .testedDefault ? "Tested default" : "Customized"
        })
        requireCaught(reporter, mutant: "prompt label that still says Tested default",
                      by: promptLabelCheck) { checkContract(testedDefaultLabel, $0) }
    }

    /// Runs `contract` against a mutant into a throwaway reporter, and records whether the named assertion
    /// caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }

    private static func isClean(_ text: String) -> Bool {
        !text.lowercased().contains("ratif") && !forbidden.contains { text.contains($0) }
    }
}
