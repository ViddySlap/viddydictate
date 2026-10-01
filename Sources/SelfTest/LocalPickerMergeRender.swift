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
/// titles and the selected row. The two-app case also drives the popup's real action: choosing LM Studio's
/// copy of the shared id writes no `localBackend`, and choosing Ollama's writes `ollama`.
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

    // MARK: - Hotkeys routing grid (--models-power-render)

    /// Writes `local-picker-one-app.png` and `local-picker-two-apps.png` (the Email card) into `outDir`.
    static func runRoutingGrid(outDir: String, report: Report) {
        guard let root = scratchRoot("routing") else { report("local picker scratch root", false, ""); return }
        defer { try? FileManager.default.removeItem(at: root) }

        // (a) One app, pinned to an LM Studio model. The pre-Ollama picker: the rows' own labels, the pin
        // marked Custom, no app names, no separator.
        do {
            let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("one-app.json"))
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
            SelfTestRenderCapture.capture(view, card: "card.email", to: outDir + "/local-picker-one-app.png",
                                          name: "local picker one app", report: report)
            host.orderOut(nil)
        }

        // (b) Both apps, pinned to Ollama's copy of the shared id.
        do {
            let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("two-apps.json"))
            guard pin(LLMProviderBundle.local(ref: ollamaShared), route: .email, in: routing,
                      report: report) else { return }
            let view = routingView(routing: routing, root: root, name: "two-apps", catalog: twoApps)
            let host = mount(view)
            loadCatalog(view, popupID: "model|email", catalog: twoApps)
            var popup = SelfTestRenderCapture.find("model|email", in: view) as? NSPopUpButton
            dumpMenu(popup, label: "routing grid, two apps, Ollama pin")
            let expected = [
                "LM Studio · " + lmsCoderLabel,
                "LM Studio · " + lmsSharedLabel,
                "",
                "Ollama · " + ollamaCoderLabel,
                "Ollama · " + ollamaSharedLabel + "  ·  Custom",
            ]
            report("routing grid, two apps: LM Studio's group, a separator, Ollama's, every row named",
                   titles(popup) == expected && popup?.item(at: 2)?.isSeparatorItem == true,
                   titles(popup).joined(separator: " | "))
            report("routing grid, two apps: the shared-id-on-both Ollama pin selects Ollama's row",
                   selectedRef(popup) == ollamaShared, popup?.titleOfSelectedItem ?? "<none>")

            // The real action, both ways.
            choose(lmsShared, in: popup)
            view.refresh()
            let toLMS = routing.selectedBundle(for: .email)
            report("routing grid: choosing LM Studio's shared-id-on-both writes no localBackend",
                   toLMS.provider == .local && toLMS.modelID == sharedID && toLMS.localBackend == nil,
                   bundleText(toLMS))
            popup = SelfTestRenderCapture.find("model|email", in: view) as? NSPopUpButton
            report("routing grid: after that choice LM Studio's row is the selected one",
                   selectedRef(popup) == lmsShared, popup?.titleOfSelectedItem ?? "<none>")
            choose(ollamaShared, in: popup)
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
                expected.append(shortName(tested.modelID) + " - Shipped default")
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
            dumpMenu(popup, label: "sticky skill, two apps, Ollama pin")
            var expected = ["LM Studio · " + lmsCoderLabel, "LM Studio · " + lmsSharedLabel]
            if let tested = LLMProviderDefaults.testedBundle(for: .local, route: route) {
                expected.append("LM Studio · " + shortName(tested.modelID) + " - Shipped default")
            }
            expected += ["", "Ollama · " + ollamaCoderLabel, "Ollama · " + ollamaSharedLabel]
            report("sticky skill, two apps: LM Studio's group, a separator, Ollama's, every row named",
                   titles(popup) == expected, titles(popup).joined(separator: " | "))
            report("sticky skill, two apps: the shared-id-on-both Ollama pin selects Ollama's row",
                   selectedRef(popup) == ollamaShared, popup?.titleOfSelectedItem ?? "<none>")

            choose(lmsShared, in: popup)
            view.refresh()
            let toLMS = routing.selectedBundle(for: route)
            report("sticky skill: choosing LM Studio's shared-id-on-both writes no localBackend",
                   toLMS.provider == .local && toLMS.modelID == sharedID && toLMS.localBackend == nil,
                   bundleText(toLMS))
            popup = SelfTestRenderCapture.find(popupID, in: view) as? NSPopUpButton
            choose(ollamaShared, in: popup)
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
        let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("\(name)-models-power.json"))
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

    /// Select the row for `ref` and send the popup's action, exactly as a click on that row does.
    private static func choose(_ ref: LocalModelRef, in popup: NSPopUpButton?) {
        guard let popup,
              let item = popup.itemArray.first(where: {
                  $0.identifier?.rawValue == LocalModelPickerItems.itemIdentifier(for: ref)
              }) else { return }
        popup.select(item)
        _ = popup.sendAction(popup.action, to: popup.target)
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

    private static func bundleText(_ bundle: LLMProviderBundle) -> String {
        "stored \(bundle.provider.rawValue) \(bundle.modelID), localBackend "
            + (bundle.localBackend?.rawValue ?? "absent")
    }

    private static func shortName(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last!) : id
    }
}
