import Cocoa

/// Ollama lane S3b: render cases for the Local model dropdown over the merged, app-tagged catalog, run by
/// `--models-power-render` (the Hotkeys routing grid's Email card) and `--sticky-skills-render` (the
/// built-in Sticky Skill card).
///
/// Each view is built against a scratch store with an INJECTED catalog loader, then driven through its real
/// `refreshAvailableLocalModels()` (the background load and main-thread rebuild production runs when Settings
/// opens). Two catalogs:
///   - one app (LM Studio only), pinned to an LM Studio model: must look exactly like the pre-Ollama picker;
///   - both apps, including `shared-id-on-both` in each, pinned to OLLAMA's copy.
/// A closed popup shows only its selected title, so every case also prints the whole menu into the render
/// log (`[menu]` lines: index, title, the item's ref identifier, which row is selected) and asserts the
/// titles and the selected row. The two-app case is the app-first picker: an app popup, then a model popup
/// that holds only the shown app's rows with plain labels. It drives the real clicks (the app popup, then the
/// model row) for LM Studio's and Ollama's copy of the shared id and for each app's own coder row, and checks
/// every stage: the app click stores nothing and leaves the model popup on its placeholder with only that
/// app's rows, and the model click writes the picked row's own id and app (LM Studio writes no
/// `localBackend`, Ollama writes `ollama`). The scratch store carries a fixed LM Studio Preferred local app,
/// so no inherited setting changes which rows a card shows. A click that cannot find its row is a FAIL row,
/// not a no-op.
enum LocalPickerMergeRenderCases {
    typealias Report = SelfTestRenderCapture.Report

    private static let sharedID = "shared-id-on-both"
    private static let lmsCoder = "picker-render-fixture/lms-coder-30b"
    private static let ollamaCoder = "picker-render-fixture-coder:30b"

    private static let lmsCoderLabel = "LMS Coder 30B (18.56 GB)"
    private static let lmsSharedLabel = "Shared On Both 8B (4.92 GB)"
    private static let ollamaCoderLabel = "picker-render-fixture-coder:30b (19.00 GB)"
    private static let ollamaSharedLabel = "shared-id-on-both (5.20 GB)"

    private static let oneApp: [LMStudioModelOption] = [
        LMStudioModelOption(modelID: lmsCoder, label: lmsCoderLabel, sizeBytes: 18_560_000_000),
        LMStudioModelOption(modelID: sharedID, label: lmsSharedLabel, sizeBytes: 4_920_000_000),
    ]
    private static let twoApps: [LMStudioModelOption] = oneApp + [
        LMStudioModelOption(modelID: ollamaCoder, label: ollamaCoderLabel, sizeBytes: 19_000_000_000,
                            backend: .ollama),
        LMStudioModelOption(modelID: sharedID, label: ollamaSharedLabel, sizeBytes: 5_200_000_000,
                            backend: .ollama),
    ]

    private static let ollamaShared = LocalModelRef(backend: .ollama, modelID: sharedID)
    private static let lmsShared = LocalModelRef(backend: .lmStudio, modelID: sharedID)
    private static let ollamaCoderRef = LocalModelRef(backend: .ollama, modelID: ollamaCoder)
    private static let lmsCoderRef = LocalModelRef(backend: .lmStudio, modelID: lmsCoder)

    // MARK: - Hotkeys routing grid (--models-power-render)

    /// Writes `local-picker-one-app.png` and `local-picker-two-apps.png` (the Email card) into `outDir`.
    static func runRoutingGrid(outDir: String, report: Report) {
        guard let root = scratchRoot("routing") else { report("local picker scratch root", false, ""); return }
        defer { try? FileManager.default.removeItem(at: root) }

        // (a) One app, pinned to an LM Studio model. The pre-Ollama picker: the rows' own labels, the pin
        // marked Custom, no app names, no separator.
        do {
            let routing = scratchStore(root.appendingPathComponent("one-app.json"))
            guard pin(.local(lmsCoder), route: .email, in: routing, report: report) else { return }
            let view = routingView(routing: routing, root: root, name: "one-app", catalog: oneApp)
            let host = mount(view)
            loadCatalog(view, popupID: "model|email", catalog: oneApp)
            let popup = SelfTestRenderCapture.find("model|email", in: view) as? NSPopUpButton
            dumpMenu(popup, label: "routing grid, one app")
            // The routing grid never appends the shipped default to a Local list; it only qualifies a row
            // that is already there, and neither fixture row is it.
            let expected = [lmsCoderLabel + "  ·  Custom", lmsSharedLabel]
            report("routing grid, one app: titles are the pre-Ollama picker's, byte for byte",
                   titles(popup) == expected, titles(popup).joined(separator: " | "))
            report("routing grid, one app: the LM Studio pin is the selected row",
                   selectedRef(popup) == LocalModelRef(backend: .lmStudio, modelID: lmsCoder),
                   popup?.titleOfSelectedItem ?? "<none>")
            // S3c: the full selected title rides on the tooltip, and the preset line names no app.
            report("routing grid, one app: the popup's tooltip is its full selected title",
                   popup?.toolTip != nil && popup?.toolTip == popup?.titleOfSelectedItem, popup?.toolTip ?? "nil")
            report("routing grid, one app: the Local preset line reads Custom and names no app",
                   presetLine(view) == "Local preset: CUSTOM \(lmsCoder)", presetLine(view))
            SelfTestRenderCapture.capture(view, card: "card.email", to: outDir + "/local-picker-one-app.png",
                                          name: "local picker one app", report: report)
            host.orderOut(nil)
        }

        // (b) Both apps, pinned to Ollama's copy of the shared id.
        do {
            let routing = scratchStore(root.appendingPathComponent("two-apps.json"))
            guard pin(LLMProviderBundle.local(ref: ollamaShared), route: .email, in: routing,
                      report: report) else { return }
            let view = routingView(routing: routing, root: root, name: "two-apps", catalog: twoApps)
            let host = mount(view)
            loadCatalog(view, popupID: "model|email", catalog: twoApps)
            var popup = SelfTestRenderCapture.find("model|email", in: view) as? NSPopUpButton
            var appPopup = SelfTestRenderCapture.find("local-app|email", in: view) as? NSPopUpButton
            dumpMenu(appPopup, label: "routing grid, two apps, app popup")
            dumpMenu(popup, label: "routing grid, two apps, Ollama pin")
            report("routing grid, two apps: the app popup lists LM Studio then Ollama and shows the pin's app",
                   titles(appPopup) == ["LM Studio", "Ollama"] && appPopup?.titleOfSelectedItem == "Ollama",
                   titles(appPopup).joined(separator: " | ") + " / " + (appPopup?.titleOfSelectedItem ?? "<none>"))
            // The model popup holds only the shown app's rows, plain labels, the pin marked Custom.
            let expected = [ollamaCoderLabel, ollamaSharedLabel + "  ·  Custom"]
            report("routing grid, two apps: the model popup holds only the shown app's rows, plain labels, the pin Custom",
                   titles(popup) == expected, titles(popup).joined(separator: " | "))
            report("routing grid, two apps: the shared-id-on-both Ollama pin selects Ollama's row",
                   selectedRef(popup) == ollamaShared, popup?.titleOfSelectedItem ?? "<none>")
            // S3c: a 250 pt popup truncates "shared-id-on-both (5.20 GB)  ·  Custom" when closed, so the full
            // title is on the tooltip; the preset line names the app as the picker does.
            report("routing grid, two apps: the model popup's tooltip is its full selected title",
                   popup?.toolTip == ollamaSharedLabel + "  ·  Custom", popup?.toolTip ?? "nil")
            report("routing grid, two apps: the Local preset line names the app",
                   presetLine(view) == "Local preset: CUSTOM · Ollama · \(sharedID)", presetLine(view))

            // The real clicks, both ways. Each pick is the app click, a check of the stage between (nothing
            // stored yet, the model popup on its placeholder with only that app's rows), then the model click.
            // LM Studio's copy of the shared id first.
            choose(lmsShared, appPopupID: "local-app|email", modelPopupID: "model|email", in: view,
                   store: routing, route: .email, appRows: [lmsCoderLabel, lmsSharedLabel],
                   label: "routing grid, click LM Studio then its shared-id-on-both: both popups carry the rows to click",
                   afterApp: "routing grid, LM Studio app click before its shared-id-on-both: the store is unchanged and the model popup shows its placeholder",
                   menu: "routing grid, LM Studio app click before its shared-id-on-both: the model popup lists only LM Studio's rows with plain titles",
                   report: report)
            view.refresh()
            let toLMS = routing.selectedBundle(for: .email)
            report("routing grid: choosing LM Studio's shared-id-on-both writes no localBackend",
                   toLMS.provider == .local && toLMS.modelID == sharedID && toLMS.localBackend == nil,
                   bundleText(toLMS))
            popup = SelfTestRenderCapture.find("model|email", in: view) as? NSPopUpButton
            appPopup = SelfTestRenderCapture.find("local-app|email", in: view) as? NSPopUpButton
            report("routing grid: after that choice LM Studio's row is the selected one",
                   selectedRef(popup) == lmsShared, popup?.titleOfSelectedItem ?? "<none>")
            report("routing grid: after that choice the app popup shows LM Studio",
                   appPopup?.titleOfSelectedItem == "LM Studio", appPopup?.titleOfSelectedItem ?? "<none>")
            // The routing grid marks the PIN's row "  ·  Custom" (LocalModelPickerItems.routingGridSuffix), and
            // the choice just made LM Studio's copy the pin, so its full title carries the qualifier, exactly
            // as Ollama's did above. The model popup holds plain labels, no app prefix.
            report("routing grid: the tooltip and the preset line follow the choice",
                   popup?.toolTip != nil && popup?.toolTip == popup?.titleOfSelectedItem
                       && popup?.toolTip == lmsSharedLabel + "  ·  Custom"
                       && presetLine(view) == "Local preset: CUSTOM · LM Studio · \(sharedID)",
                   "\(popup?.toolTip ?? "nil") / \(presetLine(view))")
            // Each app's own coder row next: its id differs from the id stored at that moment, so a write that
            // keeps the stored id (or the stored app) fails here, where the equal shared ids could not show it.
            choose(ollamaCoderRef, appPopupID: "local-app|email", modelPopupID: "model|email", in: view,
                   store: routing, route: .email, appRows: [ollamaCoderLabel, ollamaSharedLabel],
                   label: "routing grid, click Ollama then its coder row: both popups carry the rows to click",
                   afterApp: "routing grid, Ollama app click before its coder row: the store is unchanged and the model popup shows its placeholder",
                   menu: "routing grid, Ollama app click before its coder row: the model popup lists only Ollama's rows with plain titles",
                   report: report)
            view.refresh()
            let toOllamaCoder = routing.selectedBundle(for: .email)
            report("routing grid: choosing Ollama's coder row writes its own model id and localBackend ollama",
                   toOllamaCoder.provider == .local && toOllamaCoder.modelID == ollamaCoder
                       && toOllamaCoder.localBackend == .ollama, bundleText(toOllamaCoder))
            choose(lmsCoderRef, appPopupID: "local-app|email", modelPopupID: "model|email", in: view,
                   store: routing, route: .email, appRows: [lmsCoderLabel, lmsSharedLabel],
                   label: "routing grid, click LM Studio then its coder row: both popups carry the rows to click",
                   afterApp: "routing grid, LM Studio app click before its coder row: the store is unchanged and the model popup shows its placeholder",
                   menu: "routing grid, LM Studio app click before its coder row: the model popup lists only LM Studio's rows with plain titles",
                   report: report)
            view.refresh()
            let toLMSCoder = routing.selectedBundle(for: .email)
            report("routing grid: choosing LM Studio's coder row writes its own model id and no localBackend",
                   toLMSCoder.provider == .local && toLMSCoder.modelID == lmsCoder
                       && toLMSCoder.localBackend == nil, bundleText(toLMSCoder))
            choose(ollamaShared, appPopupID: "local-app|email", modelPopupID: "model|email", in: view,
                   store: routing, route: .email, appRows: [ollamaCoderLabel, ollamaSharedLabel],
                   label: "routing grid, click Ollama then its shared-id-on-both: both popups carry the rows to click",
                   afterApp: "routing grid, Ollama app click before its shared-id-on-both: the store is unchanged and the model popup shows its placeholder",
                   menu: "routing grid, Ollama app click before its shared-id-on-both: the model popup lists only Ollama's rows with plain titles",
                   report: report)
            view.refresh()
            let toOllama = routing.selectedBundle(for: .email)
            report("routing grid: choosing Ollama's shared-id-on-both writes localBackend ollama",
                   toOllama.modelID == sharedID && toOllama.localBackend == .ollama, bundleText(toOllama))
            popup = SelfTestRenderCapture.find("model|email", in: view) as? NSPopUpButton
            dumpMenu(popup, label: "routing grid, two apps, after choosing Ollama again")
            report("routing grid: Ollama's row is selected again", selectedRef(popup) == ollamaShared,
                   popup?.titleOfSelectedItem ?? "<none>")
            SelfTestRenderCapture.capture(view, card: "card.email", to: outDir + "/local-picker-two-apps.png",
                                          name: "local picker two apps", report: report)
            host.orderOut(nil)
        }
    }

    // MARK: - Sticky Skills (--sticky-skills-render)

    /// Writes `stickyskills-local-picker-one-app.png` and `stickyskills-local-picker-two-apps.png` (the
    /// built-in card) into `outDir`.
    static func runStickySkill(outDir: String, report: Report) {
        guard let root = scratchRoot("sticky") else { report("local picker scratch root", false, ""); return }
        defer { try? FileManager.default.removeItem(at: root) }
        let builtInID = StickySkillRegistry.builtInSkillID
        let popupID = "sticky-skill-model|\(builtInID)"
        let appPopupID = "sticky-skill-local-app|\(builtInID)"
        let card = "sticky-skill-card|\(builtInID)"

        // (a) One app, pinned to an LM Studio model.
        do {
            let (view, routing, route) = stickyView(root: root, name: "one-app", catalog: oneApp)
            guard pin(.local(lmsCoder), route: route, in: routing, report: report) else { return }
            view.refresh()
            let host = mount(view)
            loadCatalog(view, popupID: popupID, catalog: oneApp)
            let popup = SelfTestRenderCapture.find(popupID, in: view) as? NSPopUpButton
            dumpMenu(popup, label: "sticky skill, one app")
            var expected = [lmsCoderLabel, lmsSharedLabel]
            if let tested = LLMProviderDefaults.testedBundle(for: .local, route: route) {
                expected.append(shortName(tested.modelID) + " - Staff pick")
            }
            report("sticky skill, one app: titles are the pre-Ollama picker's, byte for byte",
                   titles(popup) == expected, titles(popup).joined(separator: " | "))
            report("sticky skill, one app: the LM Studio pin is the selected row",
                   selectedRef(popup) == LocalModelRef(backend: .lmStudio, modelID: lmsCoder),
                   popup?.titleOfSelectedItem ?? "<none>")
            SelfTestRenderCapture.capture(view, card: card, to: outDir + "/stickyskills-local-picker-one-app.png",
                                          name: "sticky local picker one app", report: report)
            host.orderOut(nil)
        }

        // (b) Both apps, pinned to Ollama's copy of the shared id.
        do {
            let (view, routing, route) = stickyView(root: root, name: "two-apps", catalog: twoApps)
            guard pin(LLMProviderBundle.local(ref: ollamaShared), route: route, in: routing,
                      report: report) else { return }
            view.refresh()
            let host = mount(view)
            loadCatalog(view, popupID: popupID, catalog: twoApps)
            var popup = SelfTestRenderCapture.find(popupID, in: view) as? NSPopUpButton
            let appPopup = SelfTestRenderCapture.find(appPopupID, in: view) as? NSPopUpButton
            dumpMenu(appPopup, label: "sticky skill, two apps, app popup")
            dumpMenu(popup, label: "sticky skill, two apps, Ollama pin")
            // The rows each app's model popup holds once the user picks that app. LM Studio's end with the
            // shipped default's " - Staff pick" row: the card appends the default of the effective Preferred
            // local app, and the fixture's store prefers LM Studio (`scratchStore`), so Ollama gets no
            // staff pick row whatever the user's own setting is.
            var lmsRows = [lmsCoderLabel, lmsSharedLabel]
            if let tested = LLMProviderDefaults.testedBundle(for: .local, route: route) {
                lmsRows.append(shortName(tested.modelID) + " - Staff pick")
            }
            let ollamaRows = [ollamaCoderLabel, ollamaSharedLabel]
            report("sticky skill, two apps: the app popup lists LM Studio then Ollama and shows the pin's app",
                   titles(appPopup) == ["LM Studio", "Ollama"] && appPopup?.titleOfSelectedItem == "Ollama",
                   titles(appPopup).joined(separator: " | ") + " / " + (appPopup?.titleOfSelectedItem ?? "<none>"))
            // Ollama's rows only: the shipped LM Studio default and LM Studio's catalog rows are in the other
            // app, and the pin's " - Current" row folds into the catalog row for the same (app, id).
            report("sticky skill, two apps: the model popup holds only the shown app's rows, plain labels",
                   titles(popup) == ollamaRows, titles(popup).joined(separator: " | "))
            report("sticky skill, two apps: the shared-id-on-both Ollama pin selects Ollama's row",
                   selectedRef(popup) == ollamaShared, popup?.titleOfSelectedItem ?? "<none>")
            report("sticky skill, two apps: the model popup's tooltip is its full selected title",
                   popup?.toolTip == ollamaSharedLabel, popup?.toolTip ?? "nil")

            choose(lmsShared, appPopupID: appPopupID, modelPopupID: popupID, in: view,
                   store: routing, route: route, appRows: lmsRows,
                   label: "sticky skill, click LM Studio then its shared-id-on-both: both popups carry the rows to click",
                   afterApp: "sticky skill, LM Studio app click before its shared-id-on-both: the store is unchanged and the model popup shows its placeholder",
                   menu: "sticky skill, LM Studio app click before its shared-id-on-both: the model popup lists only LM Studio's rows with plain titles",
                   report: report)
            view.refresh()
            let toLMS = routing.selectedBundle(for: route)
            report("sticky skill: choosing LM Studio's shared-id-on-both writes no localBackend",
                   toLMS.provider == .local && toLMS.modelID == sharedID && toLMS.localBackend == nil,
                   bundleText(toLMS))
            popup = SelfTestRenderCapture.find(popupID, in: view) as? NSPopUpButton
            report("sticky skill: after that choice LM Studio's row is the selected one",
                   selectedRef(popup) == lmsShared, popup?.titleOfSelectedItem ?? "<none>")
            // Each app's own coder row next, as in the routing grid: a different id from the stored one.
            choose(ollamaCoderRef, appPopupID: appPopupID, modelPopupID: popupID, in: view,
                   store: routing, route: route, appRows: ollamaRows,
                   label: "sticky skill, click Ollama then its coder row: both popups carry the rows to click",
                   afterApp: "sticky skill, Ollama app click before its coder row: the store is unchanged and the model popup shows its placeholder",
                   menu: "sticky skill, Ollama app click before its coder row: the model popup lists only Ollama's rows with plain titles",
                   report: report)
            view.refresh()
            let toOllamaCoder = routing.selectedBundle(for: route)
            report("sticky skill: choosing Ollama's coder row writes its own model id and localBackend ollama",
                   toOllamaCoder.provider == .local && toOllamaCoder.modelID == ollamaCoder
                       && toOllamaCoder.localBackend == .ollama, bundleText(toOllamaCoder))
            choose(lmsCoderRef, appPopupID: appPopupID, modelPopupID: popupID, in: view,
                   store: routing, route: route, appRows: lmsRows,
                   label: "sticky skill, click LM Studio then its coder row: both popups carry the rows to click",
                   afterApp: "sticky skill, LM Studio app click before its coder row: the store is unchanged and the model popup shows its placeholder",
                   menu: "sticky skill, LM Studio app click before its coder row: the model popup lists only LM Studio's rows with plain titles",
                   report: report)
            view.refresh()
            let toLMSCoder = routing.selectedBundle(for: route)
            report("sticky skill: choosing LM Studio's coder row writes its own model id and no localBackend",
                   toLMSCoder.provider == .local && toLMSCoder.modelID == lmsCoder
                       && toLMSCoder.localBackend == nil, bundleText(toLMSCoder))
            choose(ollamaShared, appPopupID: appPopupID, modelPopupID: popupID, in: view,
                   store: routing, route: route, appRows: ollamaRows,
                   label: "sticky skill, click Ollama then its shared-id-on-both: both popups carry the rows to click",
                   afterApp: "sticky skill, Ollama app click before its shared-id-on-both: the store is unchanged and the model popup shows its placeholder",
                   menu: "sticky skill, Ollama app click before its shared-id-on-both: the model popup lists only Ollama's rows with plain titles",
                   report: report)
            view.refresh()
            let toOllama = routing.selectedBundle(for: route)
            report("sticky skill: choosing Ollama's shared-id-on-both writes localBackend ollama",
                   toOllama.modelID == sharedID && toOllama.localBackend == .ollama, bundleText(toOllama))
            popup = SelfTestRenderCapture.find(popupID, in: view) as? NSPopUpButton
            report("sticky skill: Ollama's row is selected again", selectedRef(popup) == ollamaShared,
                   popup?.titleOfSelectedItem ?? "<none>")
            SelfTestRenderCapture.capture(view, card: card, to: outDir + "/stickyskills-local-picker-two-apps.png",
                                          name: "sticky local picker two apps", report: report)
            host.orderOut(nil)
        }
    }

    // MARK: - Setup

    private static func scratchRoot(_ name: String) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-local-picker-render-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return nil }
        return root
    }

    private static func routingView(routing: ModelsPowerSettingsStore, root: URL, name: String,
                                    catalog: [LMStudioModelOption]) -> ModelsPowerSettingsView {
        let custom = CustomModeStore(url: root.appendingPathComponent("\(name)-custom-modes.json"),
                                     routingStore: routing)
        let outcome = CodexUpdateOutcomeStore(url: root.appendingPathComponent("\(name)-codex-outcome.json"))
        return ModelsPowerSettingsView(
            width: 640, settingsStore: routing, customStore: custom, codexOutcomeStore: outcome,
            codexCatalogLoader: { nil }, localCatalogLoader: { catalog })
    }

    private static func stickyView(root: URL, name: String, catalog: [LMStudioModelOption])
        -> (StickySkillsSettingsView, ModelsPowerSettingsStore, LLMRouteID) {
        let routing = scratchStore(root.appendingPathComponent("\(name)-models-power.json"))
        let modes = CustomModeStore(url: root.appendingPathComponent("\(name)-custom-modes.json"),
                                    routingStore: routing)
        let skills = StickySkillStore(url: root.appendingPathComponent("\(name)-sticky-skills.json"))
        let view = StickySkillsSettingsView(
            width: 640, skillStore: skills, modeStore: modes, settingsStore: routing,
            codexCatalogLoader: { nil }, localCatalogLoader: { catalog })
        // The window supplies this backdrop in production (see `StickySkillsTabRender`).
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let route = skills.skill(id: StickySkillRegistry.builtInSkillID)?.routeID
            ?? .custom(StickySkillRegistry.noteToHandoffCustomModeID)
        return (view, routing, route)
    }

    /// The scratch store every case uses: its own JSON file AND a fixed LM Studio Preferred local app. The
    /// store would otherwise read `Settings.preferredLocalBackend` (`ModelsPowerSettings.swift:184`), and an
    /// Ollama preference there changes which staff pick row the Sticky card appends, and so which rows the
    /// model popup holds. LM Studio is also what an unset preference resolves to on a Mac with both apps.
    private static func scratchStore(_ url: URL) -> ModelsPowerSettingsStore {
        ModelsPowerSettingsStore(url: url, preferredLocalBackend: { .lmStudio })
    }

    private static func pin(_ bundle: LLMProviderBundle, route: LLMRouteID, in routing: ModelsPowerSettingsStore,
                            report: Report) -> Bool {
        do { try routing.setSelectedBundle(bundle, for: route); return true }
        catch {
            report("local picker scratch pin", false, error.localizedDescription)
            return false
        }
    }

    /// An offscreen window, so the capture has a real backing store at the screen's scale.
    private static func mount(_ view: NSView) -> NSWindow {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: max(900, view.frame.height)),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        return host
    }

    /// Production's refresh: the loader runs off the main thread and the view rebuilds on it. Spin the run
    /// loop until every row of the injected catalog is in the popup (before that it holds the shipped
    /// fallback list plus the pin), bounded, so a view that never rebuilds fails the checks that follow
    /// instead of hanging the gate.
    private static func loadCatalog(_ view: NSView, popupID: String, catalog: [LMStudioModelOption]) {
        switch view {
        case let routing as ModelsPowerSettingsView: routing.refreshAvailableLocalModels()
        case let sticky as StickySkillsSettingsView: sticky.refreshAvailableLocalModels()
        default: return
        }
        let wanted = Set(catalog.map { LocalModelPickerItems.itemIdentifier(for: $0.ref) })
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let ids = (SelfTestRenderCapture.find(popupID, in: view) as? NSPopUpButton)?
                .itemArray.compactMap { $0.identifier?.rawValue } ?? []
            if wanted.isSubset(of: Set(ids)) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // One more turn so the rebuild that delivered the catalog has finished laying out.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Menu reading

    private static func titles(_ popup: NSPopUpButton?) -> [String] {
        popup?.itemArray.map { $0.isSeparatorItem ? "" : $0.title } ?? []
    }

    private static func selectedRef(_ popup: NSPopUpButton?) -> LocalModelRef? {
        popup.flatMap { LocalModelPickerItems.selectedRef(in: $0) }
    }

    /// The app-first picker's two real clicks, in order, with the stage between them checked.
    /// (1) Pick the app in the app popup and send its action. That action refills the model popup and writes
    /// nothing, so `afterApp` asserts the stored bundle is still what it was and the model popup shows its
    /// placeholder as the selected row, and `menu` asserts the refilled popup is the placeholder then exactly
    /// `appRows` (the chosen app's rows, plain titles), every row owned by the chosen app, no separator, no
    /// app-prefixed title. (2) Only then pick the model row and send its action, whose write the caller
    /// asserts. A missing app popup, app row, model popup or model row, or an action that was not dispatched,
    /// is a FAIL row under `label`, never a silent no-op; `label` passes only after both actions were sent.
    private static func choose(_ ref: LocalModelRef, appPopupID: String, modelPopupID: String,
                               in view: NSView, store: ModelsPowerSettingsStore, route: LLMRouteID,
                               appRows: [String], label: String, afterApp: String, menu: String,
                               report: Report) {
        guard let appPopup = SelfTestRenderCapture.find(appPopupID, in: view) as? NSPopUpButton else {
            report(label, false, "no app popup \(appPopupID)")
            return
        }
        guard let appItem = appPopup.itemArray.first(where: { $0.identifier?.rawValue == ref.backend.rawValue })
        else {
            report(label, false, "the app popup has no \(ref.backend.displayName) row: "
                   + titles(appPopup).joined(separator: " | "))
            return
        }
        let before = store.selectedBundle(for: route)
        appPopup.select(appItem)
        guard appPopup.sendAction(appPopup.action, to: appPopup.target) else {
            report(label, false, "the app popup's action was not dispatched")
            return
        }
        guard let modelPopup = SelfTestRenderCapture.find(modelPopupID, in: view) as? NSPopUpButton else {
            report(label, false, "no model popup \(modelPopupID) after the app click")
            return
        }
        let after = store.selectedBundle(for: route)
        let placeholder = LocalModelPickerItems.modelPlaceholder
        report(afterApp,
               after == before && modelPopup.titleOfSelectedItem == placeholder && selectedRef(modelPopup) == nil,
               "\(bundleText(after)) / selected \"\(modelPopup.titleOfSelectedItem ?? "<none>")\"")
        let shown = Array(modelPopup.itemArray.dropFirst())
        let ownRows = shown.allSatisfy {
            !$0.isSeparatorItem
                && LocalModelPickerItems.ref(fromItemIdentifier: $0.identifier?.rawValue)?.backend == ref.backend
        }
        let plainTitles = shown.allSatisfy { item in
            !LocalBackendID.allCases.contains {
                item.title.hasPrefix($0.displayName + LocalModelPickerItems.appPrefixSeparator)
            }
        }
        report(menu, titles(modelPopup) == [placeholder] + appRows && ownRows && plainTitles,
               titles(modelPopup).joined(separator: " | "))
        let rowID = LocalModelPickerItems.itemIdentifier(for: ref)
        guard let item = modelPopup.itemArray.first(where: { $0.identifier?.rawValue == rowID }) else {
            report(label, false, "the model popup has no row \(rowID): " + titles(modelPopup).joined(separator: " | "))
            return
        }
        modelPopup.select(item)
        guard modelPopup.sendAction(modelPopup.action, to: modelPopup.target) else {
            report(label, false, "the model popup's action was not dispatched")
            return
        }
        report(label, true, "dispatched the \(ref.backend.displayName) app click, then the model row \(rowID)")
    }

    /// The whole menu as text: a closed popup photographs only its selected title.
    private static func dumpMenu(_ popup: NSPopUpButton?, label: String) {
        guard let popup else {
            print("  [menu] \(label): <no popup>")
            return
        }
        print("  [menu] \(label): \(popup.numberOfItems) items, selected \"\(popup.titleOfSelectedItem ?? "")\"")
        for (index, item) in popup.itemArray.enumerated() {
            if item.isSeparatorItem {
                print("  [menu]   \(index)  ----")
                continue
            }
            let marker = item == popup.selectedItem ? "*" : " "
            print("  [menu] \(marker) \(index)  \"\(item.title)\"  \(item.identifier?.rawValue ?? "-")")
        }
    }

    /// The Email card's provenance line ("Local preset: ...").
    private static func presetLine(_ view: NSView) -> String {
        SelfTestRenderCapture.label("provenance|\(LLMRouteID.email.rawValue)", in: view)?.stringValue ?? "missing"
    }

    private static func bundleText(_ bundle: LLMProviderBundle) -> String {
        "stored \(bundle.provider.rawValue) \(bundle.modelID), localBackend "
            + (bundle.localBackend?.rawValue ?? "absent")
    }

    private static func shortName(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last!) : id
    }
}
