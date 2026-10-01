import Foundation

/// Ollama lane S3b (`--local-picker-merge-selftest`): the Local model dropdown over the merged, app-tagged
/// catalog, as data. Pure: `LocalModelPickerItems` and the two views' compositions of it (the Hotkeys routing
/// grid and a Sticky Skill card), with no AppKit, no store, no LM Studio and no Ollama. The AppKit half (the
/// popup those rows go into, and the action that reads the chosen row back) is photographed and driven by
/// `--models-power-render` and `--sticky-skills-render` (`LocalPickerMergeRenderCases`).
///
/// The one-app expectation is never this slice's code: it is the pre-Ollama picker logic, copied verbatim
/// from the two `modelPopup`s S3b replaced (`legacyRoutingGrid`, `legacyStickySkill`), run on the same
/// inputs. Distinct values everywhere: the fixture ids are unique to this gate, the shared id is
/// `shared-id-on-both`, and its two copies carry different labels, so a row cannot pass as the other app's.
///
/// Negative controls: the contract is re-run against three broken variants, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) selection by model id only (the old `representedObject == modelID` match);
/// (b) every title always names its app, which breaks one-app byte-identity;
/// (c) an LM Studio choice writes `localBackend: lmStudio` instead of leaving the key out.
enum LocalPickerMergeFixtureSelfTest {
    private static let sharedID = "shared-id-on-both"
    private static let lmsAlpha = "picker-merge-fixture/alpha-coder-30b"
    private static let lmsTested = "picker-merge-fixture/tested-local"
    private static let ollamaCoder = "picker-merge-fixture-coder:30b"
    private static let notInstalled = "picker-merge-fixture/pinned-not-installed"

    private static let lmsAlphaLabel = "Alpha Coder 30B (18.56 GB)"
    private static let lmsSharedLabel = "Shared On Both 8B (4.92 GB)"
    private static let lmsTestedLabel = "Tested Local 12B (7.31 GB)"
    private static let ollamaCoderLabel = "picker-merge-fixture-coder:30b (19.00 GB)"
    private static let ollamaSharedLabel = "shared-id-on-both (5.20 GB)"

    /// LM Studio's catalog on a one-app Mac, in `lms ls` order.
    private static let lmStudioOnly: [LMStudioModelOption] = [
        LMStudioModelOption(modelID: lmsAlpha, label: lmsAlphaLabel, sizeBytes: 18_560_000_000),
        LMStudioModelOption(modelID: sharedID, label: lmsSharedLabel, sizeBytes: 4_920_000_000),
        LMStudioModelOption(modelID: lmsTested, label: lmsTestedLabel, sizeBytes: 7_310_000_000),
    ]

    /// Ollama's catalog on a Mac with only Ollama running.
    private static let ollamaOnly: [LMStudioModelOption] = [
        LMStudioModelOption(modelID: ollamaCoder, label: ollamaCoderLabel, sizeBytes: 19_000_000_000,
                            backend: .ollama),
        LMStudioModelOption(modelID: sharedID, label: ollamaSharedLabel, sizeBytes: 5_200_000_000,
                            backend: .ollama),
    ]

    /// Both apps, deliberately INTERLEAVED (production merges LM Studio's first), so grouping is the
    /// builder's work and not an accident of the input order.
    private static let bothApps: [LMStudioModelOption] = [
        ollamaOnly[0], lmStudioOnly[0], ollamaOnly[1], lmStudioOnly[1],
    ]

    private static let testedBundle = LLMProviderBundle.local(lmsTested)
    private static let ollamaSharedPin = LLMProviderBundle(provider: .local, modelID: sharedID,
                                                           localBackend: .ollama)

    // Assertion names the negative controls look up.
    private static let oneAppCheck =
        "one app: routing-grid and Sticky Skill titles and selection are byte-identical to the pre-Ollama pickers"
    private static let sharedPinCheck =
        "the shared-id-on-both Ollama pin selects Ollama's row and only that row, in both views"
    private static let lmStudioNilCheck =
        "an LM Studio choice on a one-app Mac writes no localBackend key, exactly the 1.1.0 bundle"

    static func run() -> Bool {
        print("=== Local picker merge fixture selftest (both local apps in the route pickers) ===")
        let reporter = SelfTestReporter()

        print("--- picker contract (real builder) ---")
        checkContract(realSubject, reporter)
        checkBuilderDetails(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[local-picker-merge-selftest] PASS"
            : "[local-picker-merge-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Subject

    /// The three seams the contract exercises. The real subject is the shipped code; each negative control
    /// wraps it with exactly one fault.
    private struct Subject {
        let routingGrid: ([LMStudioModelOption]?, LLMProviderBundle, LLMProviderBundle?)
            -> [LocalModelPickerItems.Item]
        let stickySkill: ([LMStudioModelOption]?, LLMProviderBundle, LLMProviderBundle?)
            -> [LocalModelPickerItems.Item]
        let apply: (LocalModelRef, LLMProviderBundle) -> LLMProviderBundle
    }

    private static let realSubject = Subject(
        routingGrid: { LocalModelPickerItems.routingGrid(catalog: $0, pinned: $1, tested: $2) },
        stickySkill: { LocalModelPickerItems.stickySkill(catalog: $0, pinned: $1, tested: $2) },
        apply: { LocalModelPickerItems.applying($0, to: $1) })

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(_ subject: Subject, _ reporter: SelfTestReporter) {
        // One app. Every catalog shape the picker meets on an LM-Studio-only Mac (a live catalog, discovery
        // not answered, an empty catalog) against every pin shape (in the catalog, not installed, the
        // shipped default, blank), in both views, compared with the verbatim pre-Ollama logic.
        let catalogs: [(String, [LMStudioModelOption]?)] = [
            ("live catalog", lmStudioOnly), ("discovery unanswered", nil), ("empty catalog", []),
        ]
        let pins: [LLMProviderBundle] = [
            .local(lmsAlpha), .local(notInstalled), .local(lmsTested), .local(sharedID), .local(""),
        ]
        var mismatches: [String] = []
        for (catalogName, catalog) in catalogs {
            for pin in pins {
                let grid = subject.routingGrid(catalog, pin, testedBundle)
                let legacyGrid = legacyRoutingGrid(catalog: catalog, pinned: pin, tested: testedBundle)
                if !matches(grid, legacyGrid) {
                    mismatches.append("grid/\(catalogName)/pin=\(pin.modelID): "
                        + "\(describe(grid)) vs legacy \(legacyGrid.titles) @\(legacyGrid.selected.map(String.init) ?? "-")")
                }
                let sticky = subject.stickySkill(catalog, pin, testedBundle)
                let legacySticky = legacyStickySkill(catalog: catalog, pinned: pin, tested: testedBundle)
                if !matches(sticky, legacySticky) {
                    mismatches.append("sticky/\(catalogName)/pin=\(pin.modelID): "
                        + "\(describe(sticky)) vs legacy \(legacySticky.titles) @\(legacySticky.selected.map(String.init) ?? "-")")
                }
            }
        }
        reporter.record(oneAppCheck, mismatches.isEmpty,
                        mismatches.isEmpty
                            ? "\(catalogs.count * pins.count * 2) cases"
                            : "\(mismatches.count) of \(catalogs.count * pins.count * 2) cases differ, e.g. "
                                + mismatches.prefix(2).joined(separator: "; "))

        // Only Ollama running: one app too, so its rows carry no app name either.
        let ollamaGrid = subject.routingGrid(ollamaOnly, ollamaSharedPin, testedBundle)
        reporter.record("one app (Ollama only): titles are the rows' own labels, no app name, no separator",
                        titles(ollamaGrid) == [ollamaCoderLabel, ollamaSharedLabel + "  ·  Custom"],
                        describe(ollamaGrid))

        // Two apps: grouped, separated, named.
        let grid = subject.routingGrid(bothApps, ollamaSharedPin, testedBundle)
        let expectedGrid = [
            "LM Studio · " + lmsAlphaLabel,
            "LM Studio · " + lmsSharedLabel,
            "",
            "Ollama · " + ollamaCoderLabel,
            "Ollama · " + ollamaSharedLabel + "  ·  Custom",
        ]
        reporter.record("two apps (routing grid): LM Studio's group, a separator, then Ollama's, every row named",
                        titles(grid) == expectedGrid && grid.map(\.isSeparator) == [false, false, true, false, false],
                        describe(grid))
        let sticky = subject.stickySkill(bothApps, ollamaSharedPin, testedBundle)
        let expectedSticky = [
            "LM Studio · " + lmsAlphaLabel,
            "LM Studio · " + lmsSharedLabel,
            "LM Studio · tested-local - Staff pick",
            "",
            "Ollama · " + ollamaCoderLabel,
            "Ollama · " + ollamaSharedLabel,
        ]
        reporter.record("two apps (Sticky Skill): the staff pick joins LM Studio's group, not the list's tail",
                        titles(sticky) == expectedSticky, describe(sticky))

        // The shared id, pinned to Ollama, in both views; and the same id pinned to LM Studio.
        let ollamaRef = LocalModelRef(backend: .ollama, modelID: sharedID)
        let lmsRef = LocalModelRef(backend: .lmStudio, modelID: sharedID)
        let lmsPinGrid = subject.routingGrid(bothApps, .local(sharedID), testedBundle)
        reporter.record(sharedPinCheck,
                        selectedRefs(grid) == [ollamaRef] && selectedRefs(sticky) == [ollamaRef]
                            && selectedRefs(lmsPinGrid) == [lmsRef],
                        "grid \(refText(selectedRefs(grid))), sticky \(refText(selectedRefs(sticky))), "
                            + "LM Studio pin \(refText(selectedRefs(lmsPinGrid)))")

        // Choosing each two-app row pins exactly that row's (app, id).
        let chosen = grid.compactMap(\.ref).map { ($0, subject.apply($0, ollamaSharedPin).localRef) }
        reporter.record("choosing any row pins that row's (app, id)",
                        chosen.count == 4 && chosen.allSatisfy { $0.0 == $0.1 },
                        chosen.map { "\($0.0.backend.rawValue):\($0.0.modelID) -> \($0.1.backend.rawValue):\($0.1.modelID)" }
                            .joined(separator: ", "))
        let toOllama = subject.apply(ollamaRef, .local(sharedID))
        reporter.record("choosing Ollama's copy of the id LM Studio is pinned to writes localBackend ollama",
                        toOllama.localBackend == .ollama && toOllama.modelID == sharedID)

        // LM Studio on a one-app Mac: the 1.1.0 write, with no localBackend key. Also from an Ollama pin.
        let start = LLMProviderBundle.local(lmsAlpha)
        let picked = subject.apply(LocalModelRef(backend: .lmStudio, modelID: lmsTested), start)
        let legacy = CodexPickerCatalog.applyingModelSelection(lmsTested, to: start)
        let fromOllama = subject.apply(lmsRef, ollamaSharedPin)
        reporter.record(lmStudioNilCheck,
                        picked == legacy && picked.localBackend == nil && !encodesBackendKey(picked)
                            && fromOllama.localBackend == nil && !encodesBackendKey(fromOllama),
                        "json \(encoded(picked))")
    }

    // MARK: - Builder details (real code only)

    private static func checkBuilderDetails(_ reporter: SelfTestReporter) {
        // Rows collapse by (app, id), first row wins, as rows collapsed by id before a second app existed.
        let duplicated = LocalModelPickerItems.build(
            options: lmStudioOnly + [LMStudioModelOption(modelID: lmsAlpha, label: "second label")]
                + ollamaOnly + [LMStudioModelOption(modelID: sharedID, label: "second", backend: .ollama)],
            selected: nil)
        reporter.record("rows collapse by (app, id), never by id: the shared id keeps one row per app",
                        duplicated.compactMap(\.ref).count == 5
                            && duplicated.filter { $0.ref?.modelID == sharedID }.count == 2
                            && !titles(duplicated).contains { $0.contains("second") },
                        describe(duplicated))

        reporter.record("nothing is selected when the pin is in neither app",
                        selectedRefs(LocalModelPickerItems.build(
                            options: bothApps,
                            selected: LocalModelRef(backend: .ollama, modelID: lmsAlpha))).isEmpty)

        // Switching app with the same id is a different model: provenance goes. Same app, same id: kept.
        var ratified = ollamaSharedPin
        ratified.ratified = LLMRatificationProvenance(modelID: sharedID, date: "2026-09-30", evidence: "fixture")
        ratified.autoUpdated = LLMAutoUpdateProvenance(fromModelID: "picker-merge-fixture-old", date: "2026-09-30",
                                                       reason: .freshness)
        let crossed = LocalModelPickerItems.applying(
            LocalModelRef(backend: .lmStudio, modelID: sharedID), to: ratified)
        let kept = LocalModelPickerItems.applying(
            LocalModelRef(backend: .ollama, modelID: sharedID), to: ratified)
        reporter.record("the same id in the other app drops ratification and auto-update provenance",
                        crossed.ratified == nil && crossed.autoUpdated == nil && crossed.modelID == sharedID)
        reporter.record("re-choosing the pinned row leaves the bundle unchanged", kept == ratified)

        // The menu item identifier carries the full ref, and nothing else parses as one.
        let odd = LocalModelRef(backend: .ollama, modelID: "hf.co/org/model|with-bar:Q4_K_M")
        let raw = LocalModelPickerItems.itemIdentifier(for: odd)
        reporter.record("item identifiers round-trip the ref, even an id containing | and :",
                        raw == "local-model|ollama|hf.co/org/model|with-bar:Q4_K_M"
                            && LocalModelPickerItems.ref(fromItemIdentifier: raw) == odd, raw)
        reporter.record("a cloud row, a separator, an unknown app or a blank id is not a Local ref",
                        LocalModelPickerItems.ref(fromItemIdentifier: nil) == nil
                            && LocalModelPickerItems.ref(fromItemIdentifier: "model|email") == nil
                            && LocalModelPickerItems.ref(fromItemIdentifier: "local-model|vllm|x") == nil
                            && LocalModelPickerItems.ref(fromItemIdentifier: "local-model|ollama|") == nil
                            && LocalModelPickerItems.ref(fromItemIdentifier: "local-model|ollama") == nil)

        // The fallback list (discovery failed) is unchanged: LM Studio's shipped models, no app names.
        let fallback = LocalModelPickerItems.build(
            options: LMStudioModelCatalog.pickerOptions(discovered: nil), selected: nil)
        reporter.record("the fallback list is the shipped Local models with their catalog labels, unnamed",
                        titles(fallback) == ModeModelCatalog.localModels.map { ModeModelCatalog.displayName($0) }
                            && fallback.allSatisfy { $0.ref?.backend == .lmStudio },
                        describe(fallback))
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) Selection by id only: the first row whose id matches, whichever app it is in.
        func byIDOnly(_ items: [LocalModelPickerItems.Item], _ pin: LLMProviderBundle)
            -> [LocalModelPickerItems.Item] {
            let first = items.firstIndex { $0.ref?.modelID == pin.modelID }
            return items.enumerated().map { index, item in
                LocalModelPickerItems.Item(ref: item.ref, title: item.title, isSelected: index == first)
            }
        }
        let idOnly = Subject(
            routingGrid: { byIDOnly(realSubject.routingGrid($0, $1, $2), $1) },
            stickySkill: { byIDOnly(realSubject.stickySkill($0, $1, $2), $1) },
            apply: realSubject.apply)
        requireCaught(reporter, mutant: "selection by model id only", by: sharedPinCheck) {
            checkContract(idOnly, $0)
        }

        // (b) Every row always named by its app, one app or two.
        func alwaysNamed(_ items: [LocalModelPickerItems.Item]) -> [LocalModelPickerItems.Item] {
            items.map { item in
                guard let ref = item.ref else { return item }
                let prefix = ref.backend.displayName + LocalModelPickerItems.appPrefixSeparator
                return LocalModelPickerItems.Item(
                    ref: ref, title: item.title.hasPrefix(prefix) ? item.title : prefix + item.title,
                    isSelected: item.isSelected)
            }
        }
        let named = Subject(
            routingGrid: { alwaysNamed(realSubject.routingGrid($0, $1, $2)) },
            stickySkill: { alwaysNamed(realSubject.stickySkill($0, $1, $2)) },
            apply: realSubject.apply)
        requireCaught(reporter, mutant: "picker that always names the app", by: oneAppCheck) {
            checkContract(named, $0)
        }

        // (c) The app written out even for LM Studio.
        let explicit = Subject(
            routingGrid: realSubject.routingGrid,
            stickySkill: realSubject.stickySkill,
            apply: { ref, bundle in
                var out = realSubject.apply(ref, bundle)
                out.localBackend = ref.backend
                return out
            })
        requireCaught(reporter, mutant: "choice that writes localBackend lmStudio", by: lmStudioNilCheck) {
            checkContract(explicit, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }

    // MARK: - The pre-Ollama pickers, verbatim

    /// `ModelsPowerSettingsView.modelPopup`'s Local path before S3b: dedupe by id, append the pin, then the
    /// "Shipped default" / "Custom" qualifiers by id, and select the first row whose id is the pin's. D11 renamed
    /// the default's qualifier to "Staff pick" in both views, so both copies below carry the new word; the
    /// one-app comparison is about rows, order and selection, which D11 did not touch.
    private static func legacyRoutingGrid(catalog: [LMStudioModelOption]?, pinned selected: LLMProviderBundle,
                                          tested: LLMProviderBundle?) -> (titles: [String], selected: Int?) {
        var choices: [(model: String, label: String)] = []
        for option in LMStudioModelCatalog.pickerOptions(discovered: catalog) {
            if !choices.contains(where: { $0.model == option.modelID }) {
                choices.append((option.modelID, option.label))
            }
        }
        if !selected.modelID.isEmpty,
           !choices.contains(where: { $0.model == selected.modelID }) {
            choices.append((selected.modelID, compactModelName(selected.modelID)))
        }
        let testedID = tested?.modelID
        var titles: [String] = []
        for choice in choices {
            var title = choice.label
            if choice.model == testedID { title += "  ·  Staff pick" }
            else if choice.model == selected.modelID && choice.model != testedID {
                title += "  ·  Custom"
            }
            titles.append(title)
        }
        return (titles, choices.firstIndex { $0.model == selected.modelID })
    }

    /// `StickySkillsSettingsView.modelPopup`'s Local path before S3b.
    private static func legacyStickySkill(catalog: [LMStudioModelOption]?, pinned selected: LLMProviderBundle,
                                          tested: LLMProviderBundle?) -> (titles: [String], selected: Int?) {
        var choices: [(id: String, label: String)] = []
        func append(_ id: String, _ label: String) {
            guard !id.isEmpty, !choices.contains(where: { $0.id == id }) else { return }
            choices.append((id, label))
        }
        for option in LMStudioModelCatalog.pickerOptions(discovered: catalog) {
            append(option.modelID, option.label)
        }
        if let tested {
            append(tested.modelID, compactModelName(tested.modelID) + " - Staff pick")
        }
        append(selected.modelID, compactModelName(selected.modelID) + " - Current")
        return (choices.map(\.label), choices.firstIndex { $0.id == selected.modelID })
    }

    private static func compactModelName(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last!) : id
    }

    // MARK: - Helpers

    private static func matches(_ items: [LocalModelPickerItems.Item],
                                _ legacy: (titles: [String], selected: Int?)) -> Bool {
        !items.contains(where: \.isSeparator) && titles(items) == legacy.titles
            && items.indices.filter { items[$0].isSelected } == (legacy.selected.map { [$0] } ?? [])
    }

    private static func titles(_ items: [LocalModelPickerItems.Item]) -> [String] {
        items.map(\.title)
    }

    private static func selectedRefs(_ items: [LocalModelPickerItems.Item]) -> [LocalModelRef] {
        items.filter(\.isSelected).compactMap(\.ref)
    }

    private static func refText(_ refs: [LocalModelRef]) -> String {
        "[" + refs.map { "\($0.backend.rawValue):\($0.modelID)" }.joined(separator: ", ") + "]"
    }

    private static func describe(_ items: [LocalModelPickerItems.Item]) -> String {
        items.map { $0.isSeparator ? "----" : ($0.isSelected ? "[\($0.title)]" : $0.title) }
            .joined(separator: " | ")
    }

    private static func encoded(_ bundle: LLMProviderBundle) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(bundle)).flatMap { String(data: $0, encoding: .utf8) } ?? "<encode failed>"
    }

    private static func encodesBackendKey(_ bundle: LLMProviderBundle) -> Bool {
        encoded(bundle).contains("localBackend")
    }
}
