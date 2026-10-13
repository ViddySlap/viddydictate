import Cocoa

/// Model picker, app first (`--local-app-picker-selftest`): the two-step Local picker as data, beside the
/// flat `build` rule it must not disturb.
///
/// The `local-app-picker: new:` / `local-app-picker: guard:` rows are pure: `LocalModelPickerItems` only,
/// no AppKit, no store, no LM Studio, no Ollama. The `local-app-picker: shot:` rows run in the AppKit-linked
/// test bundle: they build the real `ModelsPowerSettingsView` preview window through
/// `PickerShotPreview.makePreviewWindow`, drive its controls over scratch stores, and assert the preview
/// writes nothing to the real defaults domain or HOME.
///
/// Every check is `local-app-picker: new: ...` (asserts the new app-first behaviour; RED by assertion on
/// the old flat behaviour, which a stub reproduced), `local-app-picker: guard: ...` (pins behaviour that
/// must not move), or `local-app-picker: shot: ...` (the AppKit preview). The fixtures are unique to this
/// gate so a row cannot pass as another gate's.
enum LocalAppPickerSelfTest {
    private static let sharedID = "local-app-picker-shared"
    private static let lmsAlpha = "local-app-picker/alpha-30b"
    private static let lmsTested = "local-app-picker/tested-local"
    private static let ollamaCoder = "local-app-picker-coder:30b"
    private static let notInstalled = "local-app-picker/pinned-not-installed"

    private static let lmsAlphaLabel = "Alpha 30B (18.56 GB)"
    private static let lmsSharedLabel = "Shared 8B (4.92 GB)"
    private static let lmsTestedLabel = "Tested 12B (7.31 GB)"
    private static let ollamaCoderLabel = "local-app-picker-coder:30b (19.00 GB)"
    private static let ollamaSharedLabel = "local-app-picker-shared (5.20 GB)"

    /// LM Studio's catalog on a one-app Mac, in `lms ls` order.
    private static let lmsOnly: [LMStudioModelOption] = [
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

    /// Both apps, deliberately INTERLEAVED, so grouping is the builder's work and not the input order's.
    private static let bothApps: [LMStudioModelOption] = [
        ollamaOnly[0], lmsOnly[0], ollamaOnly[1], lmsOnly[1], lmsOnly[2],
    ]

    private static let testedBundle = LLMProviderBundle.local(lmsTested)
    private static let ollamaSharedPin = LLMProviderBundle(provider: .local, modelID: sharedID,
                                                           localBackend: .ollama)

    static func run() -> Bool {
        print("=== Local app picker selftest (app first, then that app's own models) ===")
        let reporter = SelfTestReporter()

        print("--- the two-step shape (real model) ---")
        checkAppChoices(reporter)
        checkModelsPerApp(reporter)
        checkSelection(reporter)
        checkSwitching(reporter)
        checkSuffix(reporter)
        checkPinAppNotRunning(reporter)

        print("--- guards: the one-app and flat paths must not move ---")
        checkGuards(reporter)

        print("--- guard: the views carry the two-popup wiring ---")
        checkViewSourceShape(reporter)

        print("--- preview window (shot) ---")
        checkPreviewWindow(reporter)
        checkShotDispatchOrder(reporter)
        checkShotControlsWriteNothing(reporter)

        print(reporter.passed
            ? "[local-app-picker-selftest] PASS"
            : "[local-app-picker-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - new behaviour

    private static func checkAppChoices(_ reporter: SelfTestReporter) {
        let lm = LocalModelPickerItems.appChoices(options: lmsOnly)
        let ollama = LocalModelPickerItems.appChoices(options: ollamaOnly)
        let both = LocalModelPickerItems.appChoices(options: bothApps)
        reporter.record(
            "local-app-picker: new: appChoices lists only apps with models, LM Studio first",
            lm == [.lmStudio] && ollama == [.ollama] && both == [.lmStudio, .ollama],
            "lm=\(names(lm)) ollama=\(names(ollama)) both=\(names(both))")

        reporter.record(
            "local-app-picker: new: appChoices is empty when no app has models",
            LocalModelPickerItems.appChoices(options: []).isEmpty,
            "empty=\(names(LocalModelPickerItems.appChoices(options: [])))")
    }

    private static func checkModelsPerApp(_ reporter: SelfTestReporter) {
        let lms = LocalModelPickerItems.models(for: .lmStudio, options: bothApps, selected: nil)
        let ollama = LocalModelPickerItems.models(for: .ollama, options: bothApps, selected: nil)
        reporter.record(
            "local-app-picker: new: models(for:) returns only that app's models with plain labels",
            lms.allSatisfy { $0.ref?.backend == .lmStudio } && titles(lms) == [lmsAlphaLabel, lmsSharedLabel, lmsTestedLabel]
                && ollama.allSatisfy { $0.ref?.backend == .ollama }
                && titles(ollama) == [ollamaCoderLabel, ollamaSharedLabel],
            "lms=\(titles(lms)) ollama=\(titles(ollama))")

        // The shared id the other app also has: one row per app's list, never both in one list.
        let ollamaShared = LocalModelPickerItems.models(for: .ollama, options: bothApps, selected: nil)
            .filter { $0.ref?.modelID == sharedID }
        let lmsShared = LocalModelPickerItems.models(for: .lmStudio, options: bothApps, selected: nil)
            .filter { $0.ref?.modelID == sharedID }
        reporter.record(
            "local-app-picker: new: an Ollama copy of an id LM Studio also has stays separate",
            ollamaShared.count == 1 && ollamaShared.first?.ref?.backend == .ollama
                && lmsShared.count == 1 && lmsShared.first?.ref?.backend == .lmStudio
                && ollamaShared.first?.ref != lmsShared.first?.ref,
            "ollama=\(refText(ollamaShared.compactMap(\.ref))) lms=\(refText(lmsShared.compactMap(\.ref)))")

        // Ordering of the other app never leaks in: LM Studio's rows even when Ollama's row came first.
        let ollamaFirst: [LMStudioModelOption] = [ollamaOnly[0], lmsOnly[0], ollamaOnly[1]]
        let onlyLms = LocalModelPickerItems.models(for: .lmStudio, options: ollamaFirst, selected: nil)
        reporter.record(
            "local-app-picker: new: models(for:) ignores the other app even when that app comes first",
            titles(onlyLms) == [lmsAlphaLabel] && onlyLms.allSatisfy { $0.ref?.backend == .lmStudio },
            "rows=\(titles(onlyLms))")
    }

    private static func checkSelection(_ reporter: SelfTestReporter) {
        let ollamaRef = LocalModelRef(backend: .ollama, modelID: ollamaCoder)
        let lmsRef = LocalModelRef(backend: .lmStudio, modelID: lmsAlpha)
        let shownOllama = LocalModelPickerItems.shownApp(options: bothApps, selected: ollamaRef)
        let shownLms = LocalModelPickerItems.shownApp(options: bothApps, selected: lmsRef)
        reporter.record(
            "local-app-picker: new: the pinned ref's app is the shown app",
            shownOllama == .ollama && shownLms == .lmStudio,
            "ollama pin -> \(String(describing: shownOllama)) lms pin -> \(String(describing: shownLms))")

        let inOllama = LocalModelPickerItems.models(for: .ollama, options: bothApps, selected: ollamaRef)
        let inLms = LocalModelPickerItems.models(for: .lmStudio, options: bothApps, selected: ollamaRef)
        reporter.record(
            "local-app-picker: new: the pin's model is selected only in its own app's rows",
            selectedRefs(inOllama) == [ollamaRef] && selectedRefs(inLms).isEmpty,
            "ollama rows@\(refText(selectedRefs(inOllama))) lms rows@\(refText(selectedRefs(inLms)))")
    }

    private static func checkSwitching(_ reporter: SelfTestReporter) {
        let pin = LLMProviderBundle(provider: .local, modelID: ollamaCoder, localBackend: .ollama)
        let pinnedRef = pin.localRef
        let switched = LocalBackendID.lmStudio
        let rows = LocalModelPickerItems.models(for: switched, options: bothApps, selected: pinnedRef)
        let placeholder = LocalModelPickerItems.showsModelPlaceholder(for: switched, selected: pinnedRef)
        let untouched = pin.localRef == pinnedRef && pin.localBackend == .ollama && pin.modelID == ollamaCoder
        reporter.record(
            "local-app-picker: new: switching the app yields the placeholder and leaves the pin untouched",
            placeholder && rows.allSatisfy { !$0.isSelected }
                && rows.contains { $0.ref?.backend == .lmStudio } && untouched,
            "placeholder=\(placeholder) selected=\(refText(selectedRefs(rows))) pin=\(pin.localRef.backend.rawValue):\(pin.modelID)")

        // The user picks one of the switched app's models: only then does the pin move, to (app, id).
        let chosenRef = LocalModelRef(backend: .lmStudio, modelID: lmsAlpha)
        let chosen = LocalModelPickerItems.models(for: .lmStudio, options: bothApps, selected: nil)
            .first { $0.ref == chosenRef }
        let chosenPin = LocalModelPickerItems.applying(chosenRef, to: pin)
        reporter.record(
            "local-app-picker: new: choosing a model after switching pins (app, id)",
            chosen?.title == lmsAlphaLabel && chosenPin.localRef == chosenRef
                && chosenPin.resolvedLocalBackend == .lmStudio,
            "row=\(chosen?.title ?? "-") pin=\(chosenPin.localRef.backend.rawValue):\(chosenPin.modelID)")
    }

    private static func checkSuffix(_ reporter: SelfTestReporter) {
        let sharedOllama = LocalModelRef(backend: .ollama, modelID: sharedID)
        let suffix: (LocalModelRef) -> String = { ref in
            ref == sharedOllama ? StaffPicks.gridCustomQualifier : StaffPicks.gridQualifier
        }
        let ollamaRows = LocalModelPickerItems.models(
            for: .ollama, options: bothApps, selected: sharedOllama, suffix: suffix)
        let lmsRows = LocalModelPickerItems.models(
            for: .lmStudio, options: bothApps, selected: sharedOllama, suffix: suffix)
        let ollamaTarget = ollamaRows.first { $0.ref == sharedOllama }
        let lmsShared = lmsRows.first { $0.ref?.modelID == sharedID }
        reporter.record(
            "local-app-picker: new: suffix qualifiers per (app, id)",
            ollamaTarget?.title == ollamaSharedLabel + StaffPicks.gridCustomQualifier
                && ollamaTarget?.isSelected == true
                && lmsShared?.title == lmsSharedLabel + StaffPicks.gridQualifier
                && lmsShared?.isSelected == false,
            "ollama=\(ollamaTarget?.title ?? "-") lms=\(lmsShared?.title ?? "-")")
    }

    private static func checkPinAppNotRunning(_ reporter: SelfTestReporter) {
        // Only LM Studio runs; the route is pinned to Ollama. `routingGridOptions` appends the pin, so the
        // pin's app appears as its own app and the pin shows "  ·  Custom" under it.
        let pinned = LLMProviderBundle(provider: .local, modelID: ollamaCoder, localBackend: .ollama)
        let options = LocalModelPickerItems.routingGridOptions(catalog: lmsOnly, pinned: pinned)
        let choices = LocalModelPickerItems.appChoices(options: options)
        let shown = LocalModelPickerItems.shownApp(options: options, selected: pinned.localRef)
        let suffix = LocalModelPickerItems.routingGridSuffix(pinned: pinned, tested: nil)
        let rows = LocalModelPickerItems.models(for: .ollama, options: options,
                                                selected: pinned.localRef, suffix: suffix)
        let pinRow = rows.first { $0.ref == pinned.localRef }
        reporter.record(
            "local-app-picker: new: a pin whose app is not running still appears as Custom under its app",
            choices == [.lmStudio, .ollama] && shown == .ollama
                && pinRow?.title == shortName(ollamaCoder) + StaffPicks.gridCustomQualifier
                && pinRow?.isSelected == true,
            "choices=\(names(choices)) shown=\(String(describing: shown)) row=\(pinRow?.title ?? "-")")
    }

    // MARK: - guards

    private static func checkGuards(_ reporter: SelfTestReporter) {
        let gridSuffix: (LocalModelRef) -> String = { ref in
            if ref == LocalModelRef(backend: .lmStudio, modelID: lmsTested) {
                return StaffPicks.gridQualifier
            }
            if ref == LocalModelRef(backend: .lmStudio, modelID: lmsAlpha) {
                return StaffPicks.gridCustomQualifier
            }
            return ""
        }
        let pins: [LocalModelRef?] = [
            nil, LocalModelRef(backend: .lmStudio, modelID: lmsAlpha),
            LocalModelRef(backend: .lmStudio, modelID: notInstalled),
        ]
        var mismatches: [String] = []
        for pin in pins {
            let twoStep = LocalModelPickerItems.models(for: .lmStudio, options: lmsOnly,
                                                       selected: pin, suffix: gridSuffix)
            let flat = LocalModelPickerItems.build(options: lmsOnly, selected: pin, suffix: gridSuffix)
            if twoStep != flat {
                mismatches.append("pin=\(pin?.modelID ?? "-"): \(describe(twoStep)) vs \(describe(flat))")
            }
        }
        reporter.record(
            "local-app-picker: guard: one app present gives byte-identical items to the old build output",
            mismatches.isEmpty,
            mismatches.isEmpty ? "\(pins.count) pins" : mismatches.prefix(2).joined(separator: "; "))

        // Both apps: the old flat builder is unchanged (grouped, separated, every title app-prefixed).
        let flat = LocalModelPickerItems.build(options: bothApps, selected: ollamaSharedPin.localRef)
        let expectedFlat = [
            "LM Studio · " + lmsAlphaLabel,
            "LM Studio · " + lmsSharedLabel,
            "LM Studio · " + lmsTestedLabel,
            "",
            "Ollama · " + ollamaCoderLabel,
            "Ollama · " + ollamaSharedLabel,
        ]
        reporter.record(
            "local-app-picker: guard: both apps present, the old flat build output is unchanged",
            titles(flat) == expectedFlat && flat.map(\.isSeparator) == [false, false, false, true, false, false],
            describe(flat))

        // The existing flat pickers' rows are untouched by the two-step addition.
        let routing = LocalModelPickerItems.routingGrid(catalog: bothApps, pinned: ollamaSharedPin,
                                                        tested: testedBundle)
        let expectedRouting = [
            "LM Studio · " + lmsAlphaLabel,
            "LM Studio · " + lmsSharedLabel,
            "LM Studio · " + lmsTestedLabel + StaffPicks.gridQualifier,
            "",
            "Ollama · " + ollamaCoderLabel,
            "Ollama · " + ollamaSharedLabel + StaffPicks.gridCustomQualifier,
        ]
        let sticky = LocalModelPickerItems.stickySkill(catalog: bothApps, pinned: ollamaSharedPin,
                                                       tested: testedBundle)
        let expectedSticky = [
            "LM Studio · " + lmsAlphaLabel,
            "LM Studio · " + lmsSharedLabel,
            "LM Studio · " + lmsTestedLabel,
            "",
            "Ollama · " + ollamaCoderLabel,
            "Ollama · " + ollamaSharedLabel,
        ]
        reporter.record(
            "local-app-picker: guard: existing --local-picker-merge-selftest rows untouched",
            titles(routing) == expectedRouting && titles(sticky) == expectedSticky,
            "routing=\(describe(routing)) sticky=\(describe(sticky))")

        // Identity is the pair, never the bare id.
        let lmsCopy = LMStudioModelOption(modelID: sharedID, label: "lms")
        let ollamaCopy = LMStudioModelOption(modelID: sharedID, label: "ollama", backend: .ollama)
        reporter.record(
            "local-app-picker: guard: identity is (app, id)",
            lmsCopy.ref != ollamaCopy.ref && lmsCopy.ref.backend == .lmStudio
                && ollamaCopy.ref.backend == .ollama && lmsCopy.ref.modelID == ollamaCopy.ref.modelID,
            "\(lmsCopy.ref.backend.rawValue) vs \(ollamaCopy.ref.backend.rawValue)")
    }

    // MARK: - view source shape

    private static func checkViewSourceShape(_ reporter: SelfTestReporter) {
        let gridView = source("Sources/App/ModelsPowerSettingsView.swift")
        let stickyView = source("Sources/App/StickySkillsSettingsView.swift")
        let gridOK = gridView?.contains("local-app|\\(route.rawValue)") == true
            && gridView?.contains("populateAppModel") == true
            && gridView?.contains("populateModelPopup") == true
            && gridView?.contains("func localAppChanged") == true
            && gridView?.contains("LocalModelPickerItems.selectedRef(in: sender)") == true
        let stickyOK = stickyView?.contains("sticky-skill-local-app|\\(skill.id)") == true
            && stickyView?.contains("populateAppModel") == true
            && stickyView?.contains("populateModelPopup") == true
            && stickyView?.contains("func localAppChanged") == true
            && stickyView?.contains("LocalModelPickerItems.selectedRef(in: sender)") == true
        reporter.record(
            "local-app-picker: guard: the two views still route Local picks through their model| identifiers",
            gridOK && stickyOK,
            "grid=\(gridOK) sticky=\(stickyOK)")
    }

    // MARK: - preview window (shot)

    /// The AppKit half of the gate: the REAL `ModelsPowerSettingsView` routing-grid rows, built through
    /// `PickerShotPreview.makePreviewWindow` with an in-memory fixture catalog. These rows run directly
    /// (the test bundle is AppKit-linked), not in a codex nested sandbox, so `import Cocoa` is correct here.
    private static func checkPreviewWindow(_ reporter: SelfTestReporter) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let beforeDefaults = persistentOrGlobalKeys()
        let beforeDomain = domainKeys()
        let beforeFiles = fileSet(under: home)

        let route = PickerShotPreview.pinnedRoute
        let twoAppRoot = scratchDir("shot-two-app")
        defer { try? FileManager.default.removeItem(at: twoAppRoot) }
        let window = PickerShotPreview.makePreviewWindow(
            catalog: PickerShotPreview.fixtureCatalog,
            pinned: PickerShotPreview.pinnedBundle,
            scratchRoot: twoAppRoot)

        reporter.record(
            "local-app-picker: shot: the preview builder returns the window titled ViddyDictate Picker Preview",
            window?.title == PickerShotPreview.windowTitle,
            window.map { "title=\($0.title)" } ?? "nil")

        let appPopupCount = count("local-app|\(route.rawValue)", in: window)
        let modelPopupCount = count("model|\(route.rawValue)", in: window)
        reporter.record(
            "local-app-picker: shot: the pinned Ollama route shows an app popup and a model popup",
            appPopupCount == 1 && modelPopupCount == 1,
            "appPopups=\(appPopupCount) modelPopups=\(modelPopupCount)")

        let appPopup = self.appPopup(window, route: route)
        let modelPopup = self.modelPopup(window, route: route)
        let expectedModelTitle = PickerShotPreview.ollamaCoderLabel + StaffPicks.gridCustomQualifier
        let appOK = appPopup?.titleOfSelectedItem == "Ollama"
        let modelOK = modelPopup?.titleOfSelectedItem == expectedModelTitle
            && (modelPopup?.selectedItem?.representedObject as? String) == PickerShotPreview.pinnedRef.modelID
        reporter.record(
            "local-app-picker: shot: the app popup shows Ollama and the model popup shows the pinned model",
            appOK && modelOK,
            "app=\(appPopup?.titleOfSelectedItem ?? "nil") model=\(modelPopup?.titleOfSelectedItem ?? "nil") "
                + "represented=\(modelPopup?.selectedItem?.representedObject as? String ?? "nil")")

        let oneAppRoot = scratchDir("shot-one-app")
        defer { try? FileManager.default.removeItem(at: oneAppRoot) }
        let oneAppWindow = PickerShotPreview.makePreviewWindow(
            catalog: PickerShotPreview.lmStudioOnlyCatalog,
            pinned: PickerShotPreview.lmStudioPin,
            scratchRoot: oneAppRoot)
        let oneModelPopups = count("model|\(route.rawValue)", in: oneAppWindow)
        let oneAppPopups = count("local-app|\(route.rawValue)", in: oneAppWindow)
        reporter.record(
            "local-app-picker: shot: a one-app fixture shows one model popup and no app popup",
            oneModelPopups == 1 && oneAppPopups == 0,
            "modelPopups=\(oneModelPopups) appPopups=\(oneAppPopups)")

        let afterDefaults = persistentOrGlobalKeys()
        let afterDomain = domainKeys()
        let afterFiles = fileSet(under: home)
        let defaultsUnchanged = beforeDefaults == afterDefaults
        let domainUnchanged = beforeDomain == afterDomain
        let filesUnchanged = beforeFiles == afterFiles
        let defaultsDiff = beforeDefaults.symmetricDifference(afterDefaults)
        reporter.record(
            "local-app-picker: shot: building the preview writes no defaults and no files under HOME",
            window != nil && defaultsUnchanged && domainUnchanged && filesUnchanged,
            "window=\(window != nil) defaults=\(defaultsUnchanged) domain=\(domainUnchanged) "
                + "files=\(filesUnchanged)" + (defaultsUnchanged ? "" : " defaultsDiff=\(defaultsDiff.sorted())"))
    }

    /// The `--shot-local-picker` dispatch must be the first executable statement after the flag enums, so a
    /// launch of the SHIPPED app with the flag never reaches the real log rotation / launch-line write or the
    /// uncaught-exception handler. Read the source directly: the flag text must appear before both.
    private static func checkShotDispatchOrder(_ reporter: SelfTestReporter) {
        let name = "local-app-picker: shot: main.swift dispatches the shot flag before any Log call and the exception handler"
        guard let text = source("Sources/App/main.swift") else {
            reporter.record(name, false, "main.swift unreadable")
            return
        }
        let shot = text.range(of: "--shot-local-picker")?.lowerBound
        let log = text.range(of: "Log.")?.lowerBound
        let handler = text.range(of: "NSSetUncaughtExceptionHandler")?.lowerBound
        let beforeLog = shot != nil && log != nil && shot! < log!
        let beforeHandler = shot != nil && handler != nil && shot! < handler!
        reporter.record(name, shot != nil && beforeLog && beforeHandler,
                        "shot=\(shot != nil) beforeLog=\(beforeLog) beforeHandler=\(beforeHandler)")
    }

    /// Build the preview and drive every enabled button it shows. The auto-check checkbox must already be
    /// disabled (the M2 fix), so it is never clicked; every other enabled button acts only on the scratch
    /// stores. Snapshots of the real defaults domain, the merged defaults keys, and the file set under HOME
    /// must all be unchanged afterwards.
    private static func checkShotControlsWriteNothing(_ reporter: SelfTestReporter) {
        let name = "local-app-picker: shot: using every preview control writes no defaults and no HOME files and the auto-check is not enabled"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let beforeDefaults = persistentOrGlobalKeys()
        let beforeDomain = domainKeys()
        let beforeFiles = fileSet(under: home)

        let root = scratchDir("shot-controls")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let window = PickerShotPreview.makePreviewWindow(
            catalog: PickerShotPreview.fixtureCatalog,
            pinned: PickerShotPreview.pinnedBundle,
            scratchRoot: root),
              let content = window.contentView else {
            reporter.record(name, false, "preview window did not build")
            return
        }

        let autoCheck = SelfTestRenderCapture.find("cloud-update-auto-check", in: content) as? NSButton
        let autoCheckNotEnabled = autoCheck == nil || autoCheck?.isEnabled == false

        let promptOpeners = ["edit-prompt|", "reset-prompt|", "edit-custom-prompt|"]
        for view in SelfTestRenderCapture.allViews(in: content) {
            guard let button = view as? NSButton,
                  !(button is NSPopUpButton),
                  button.isEnabled else { continue }
            let id = button.identifier?.rawValue ?? ""
            if promptOpeners.contains(where: { id.hasPrefix($0) }) { continue }
            button.performClick(nil)
        }

        let afterDefaults = persistentOrGlobalKeys()
        let afterDomain = domainKeys()
        let afterFiles = fileSet(under: home)
        let defaultsUnchanged = beforeDefaults == afterDefaults
        let domainUnchanged = beforeDomain == afterDomain
        let filesUnchanged = beforeFiles == afterFiles
        let defaultsDiff = beforeDefaults.symmetricDifference(afterDefaults)
        reporter.record(
            name,
            autoCheckNotEnabled && defaultsUnchanged && domainUnchanged && filesUnchanged,
            "autoCheck=\(autoCheck.map { $0.isEnabled ? "enabled" : "disabled" } ?? "absent") "
                + "defaults=\(defaultsUnchanged) domain=\(domainUnchanged) files=\(filesUnchanged)"
                + (defaultsUnchanged ? "" : " defaultsDiff=\(defaultsDiff.sorted())"))
    }

    private static func appPopup(_ window: NSWindow?, route: LLMRouteID) -> NSPopUpButton? {
        guard let content = window?.contentView else { return nil }
        return SelfTestRenderCapture.find("local-app|\(route.rawValue)", in: content) as? NSPopUpButton
    }

    private static func modelPopup(_ window: NSWindow?, route: LLMRouteID) -> NSPopUpButton? {
        guard let content = window?.contentView else { return nil }
        return SelfTestRenderCapture.find("model|\(route.rawValue)", in: content) as? NSPopUpButton
    }

    private static func count(_ id: String, in window: NSWindow?) -> Int {
        guard let content = window?.contentView else { return 0 }
        return SelfTestRenderCapture.allViews(in: content)
            .filter { $0.identifier?.rawValue == id }.count
    }

    private static func domainKeys() -> Set<String> {
        let domain = Bundle.main.bundleIdentifier ?? ""
        guard !domain.isEmpty, let persisted = UserDefaults.standard.persistentDomain(forName: domain) else {
            return []
        }
        return Set(persisted.keys)
    }

    /// `UserDefaults.standard`'s merged key list with the two volatile domains AppKit owns removed. The
    /// registration domain is where AppKit lazily registers `METAL_DEVICE_WRAPPER_TYPE`, font metrics, and
    /// text-layout keys as the first window and text field are built, and the argument domain is process
    /// input; neither is a persisted defaults write by the preview builder. The app's own defaults domain
    /// is compared separately by `domainKeys`.
    private static func persistentOrGlobalKeys() -> Set<String> {
        var keys = Set(UserDefaults.standard.dictionaryRepresentation().keys)
        for domain in UserDefaults.standard.volatileDomainNames {
            keys.subtract(Set(UserDefaults.standard.volatileDomain(forName: domain).keys))
        }
        return keys
    }

    private static func fileSet(under root: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var files = Set<String>()
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                files.insert(url.path)
            }
        }
        return files
    }

    private static func scratchDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-local-app-picker-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - helpers

    private static func shortName(_ modelID: String) -> String {
        ModeModelCatalog.displayName(.local(modelID))
    }

    private static func names(_ apps: [LocalBackendID]) -> String {
        "[" + apps.map(\.rawValue).joined(separator: ",") + "]"
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

    private static func source(_ relativePath: String) -> String? {
        guard let root = repositoryRoot() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Walks up from `<repo>/build/ViddyDictateTests.app` to the directory holding the daemon script, as
    /// `DaemonInstallSelfTest` does. A missing root is a recorded failure, never a crash.
    private static func repositoryRoot() -> URL? {
        let fm = FileManager.default
        var directory = Bundle.main.bundleURL
        for _ in 0..<12 {
            if fm.fileExists(atPath: directory.appendingPathComponent("viddydictate_whisperd.py").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
