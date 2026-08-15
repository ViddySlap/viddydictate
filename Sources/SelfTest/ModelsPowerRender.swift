import Cocoa

/// Offscreen render-to-PNG seam for the Models & Power prompt-override surface
/// (`--models-power-render <outdir>`). Like `--hud-render` this is an in-process render, NOT a screen
/// capture (screen capture from an agent shell is TCC-blocked), so a build link can actually LOOK at the
/// control it just built instead of asserting about a control it cannot see.
///
/// It drives the real view against a scratch store and writes three PNGs of the expanded Email card:
///   - `prompt-row-default.png`    — no override: Reset prompt is present but disabled.
///   - `prompt-row-customized.png` — an override in place: the row reads Customized, Reset is enabled.
///   - `prompt-row-reset.png`      — after clicking Reset: back to Tested default, model/effort untouched.
/// plus `prompt-editor-customized.png` / `prompt-editor-restored.png` for the sheet's Restore control.
/// It asserts by pixel metric that every capture is non-blank, so a silently empty render cannot pass as
/// a screenshot, and by store state that the click did the product thing.
enum ModelsPowerRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pin the appearance so a capture does not silently change meaning with whatever the host Mac
        // happens to be set to. The app itself follows the system; only the render seam is pinned.
        app.appearance = NSAppearance(named: .darkAqua)

        let fm = FileManager.default
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[models-power-render] cannot create \(outDir): \(error)")
            return false
        }

        let root = fm.temporaryDirectory
            .appendingPathComponent("viddydictate-models-power-render-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            print("[models-power-render] scratch setup failed: \(error.localizedDescription)")
            return false
        }
        defer { try? fm.removeItem(at: root) }

        let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("models-power.json"))
        let custom = CustomModeStore(url: root.appendingPathComponent("custom-modes.json"),
                                     routingStore: routing)
        let outcome = CodexUpdateOutcomeStore(url: root.appendingPathComponent("codex-outcome.json"))
        let view = ModelsPowerSettingsView(
            width: 640, settingsStore: routing, customStore: custom,
            codexOutcomeStore: outcome, codexCatalogLoader: { nil })

        // An offscreen window gives the view a real backing store at the screen's scale, so the PNGs are
        // legible at 2x rather than a 1x smear.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)

        (find("advanced|email", in: view) as? NSButton)?.performClick(nil)
        capture(view, card: "card.email", to: outDir + "/prompt-row-default.png", name: "default")

        // A non-default model/effort, so "reset touched only the prompt" is a claim the capture can fail:
        // against a shipped-default bundle a whole-bundle restore would look identical to a prompt delete.
        var pinned = routing.selectedBundle(for: .email)
        pinned.modelID = "render-probe-model"
        pinned.effort = nil
        do { try routing.setSelectedBundle(pinned, for: .email) }
        catch {
            print("[models-power-render] scratch bundle failed: \(error.localizedDescription)")
            return false
        }
        let before = routing.selectedBundle(for: .email)
        do {
            try routing.setPromptOverride(
                "Write the reply in the user's own voice. Keep it under four sentences.",
                for: .email, provider: before.provider)
        } catch {
            print("[models-power-render] scratch override failed: \(error.localizedDescription)")
            return false
        }
        view.refresh()
        if !isExpanded(view) { (find("advanced|email", in: view) as? NSButton)?.performClick(nil) }
        let resetID = "reset-prompt|email|\(before.provider.rawValue)|primary"
        let reset = find(resetID, in: view) as? NSButton
        check("Reset prompt is enabled once the route is customized", reset?.isEnabled == true)
        capture(view, card: "card.email", to: outDir + "/prompt-row-customized.png", name: "customized")

        captureEditor(routing: routing, provider: before.provider, outDir: outDir)

        reset?.performClick(nil)
        check("Reset prompt clears the override",
              routing.promptCustomizationState(for: .email, provider: before.provider) == .testedDefault)
        check("Reset prompt leaves model and effort byte-identical",
              routing.selectedBundle(for: .email) == before)
        capture(view, card: "card.email", to: outDir + "/prompt-row-reset.png", name: "reset")

        captureProvenanceRow(routing: routing, view: view, outDir: outDir)
        captureCustomModeWorkstation(outDir: outDir)

        view.removeFromSuperview()
        print("[models-power-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    /// The provenance row's two states (item P11), captured on the arm the row actually displays.
    ///
    /// The row used to be a pure function of the BUNDLE, which cannot see a prompt override, so the
    /// `provenance-row-ratified.png` line below is also exactly what the old code kept showing after the
    /// prompt bytes had been replaced - a green RATIFIED claim over a slate the store already considered
    /// uncovered. `provenance-row-unratified.png` is that same state under the fix.
    private static func captureProvenanceRow(routing: ModelsPowerSettingsStore,
                                             view: ModelsPowerSettingsView, outDir: String) {
        // Pin the route to Claude first so this capture documents both RATIFIED and prompt-overridden states.
        // Local selections now truthfully render their own model and carry no ratification badge.
        let displayed = LLMProvider.claude
        guard let claudeArm = routing.rememberedBundle(for: displayed, route: .email)
                ?? LLMProviderDefaults.testedBundle(for: displayed, route: .email) else {
            check("provenance capture needs a Claude arm for Email", false)
            return
        }
        do { try routing.setSelectedBundle(claudeArm, for: .email) }
        catch {
            check("provenance capture scratch pin", false)
            return
        }
        view.refresh()
        if !isExpanded(view) { (find("advanced|email", in: view) as? NSButton)?.performClick(nil) }
        let reason = CloudUpdateSurface.unratifiedReasonText(.promptOverridden)

        func rowText() -> String {
            (find("provenance|email", in: view) as? NSTextField)?.stringValue ?? ""
        }

        check("the provenance row starts with no prompt-edit objection", !rowText().contains(reason))
        capture(view, card: "card.email", to: outDir + "/provenance-row-ratified.png",
                name: "provenance ratified")

        do {
            try routing.setPromptOverride("Write it in the user's own voice.",
                                          for: .email, provider: displayed)
        } catch {
            check("provenance capture scratch override", false)
            return
        }
        view.refresh()
        check("an overridden prompt turns the displayed arm's provenance row unratified",
              rowText().contains("UNRATIFIED") && rowText().contains(reason))
        capture(view, card: "card.email", to: outDir + "/provenance-row-unratified.png",
                name: "provenance unratified")
    }

    /// The prompt workstation (W1): the Edit-task-prompt panel for a custom mode, rendering the
    /// assembled prompt with the marker block around the editable region. It exists as a capture
    /// because this is a surface that has to be LOOKED at - "the markers are visible and it is obvious
    /// which part is yours" is not a claim a string assertion can make.
    private static func captureCustomModeWorkstation(outDir: String) {
        guard let bundle = LLMProviderDefaults.testedBundle(
            for: .local, route: .custom("render-workstation")) else {
            check("workstation capture needs a local bundle", false)
            return
        }
        let mode = CustomMode(
            id: "render-workstation", name: "Email from notes",
            chord: .regular(keyCode: 14, label: "E"),
            prompt: "Turn the dictation into a short, direct email body. Keep every fact.",
            input: .dictation, model: bundle, landing: .inPlace)
        // A synthetic take, comfortably under the 1000-character cap, standing in for the History
        // default. Nothing here reads the machine's own history.json.
        let recentTake = "so the idea is we push the launch back a week and let marketing "
            + "catch up, and then I want to send Dana a short note about the schedule before Friday"
        let history = [
            TranscriptionHistory.Entry(
                id: UUID(), date: Date(timeIntervalSince1970: 1_785_000_000),
                text: recentTake, app: "Render", raw: recentTake, cleaned: nil,
                mode: HistoryMode.raw.rawValue, level: nil),
        ]
        var deliver: ((CleanupClient.Result) -> Void)?
        let sheet = PromptEditorSheet.customModeWorkstation(
            title: ModelsPowerSettingsView.customPromptTitle(for: mode), mode: mode,
            bench: PromptTestBenchConfig(mode: mode, history: { history },
                                         runner: { _, _, done in deliver = done }),
            onSave: { _ in })
        let root = sheet.contentViewForTesting
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        check("the workstation composition is the one a run would send",
              sheet.displayedAssemblyForTesting?.system == CustomModeClient.systemPrompt(for: mode)
                && sheet.displayedAssemblyForTesting?.user
                    == CleanupClient.wrap(PromptAssembly.defaultTranscriptPlaceholder))
        check("the bench opens seeded from History, and says so",
              sheet.sampleTextForTesting == recentTake
                && sheet.sourceTextForTesting.contains("most recent dictation"))
        capture(root, card: nil, to: outDir + "/prompt-workstation.png", name: "workstation")

        // The two states worth looking at: an answer on screen (and the line saying it went nowhere),
        // and a failure wearing the real path's words.
        (find("prompt-test-run", in: root) as? NSButton)?.performClick(nil)
        deliver?(.ok("Pushing the launch back a week so marketing can catch up. I will send Dana a "
                     + "short note about the schedule before Friday."))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("a finished test shows its answer in the panel", !sheet.resultTextForTesting.isEmpty)
        capture(root, card: nil, to: outDir + "/prompt-workstation-test-result.png",
                name: "workstation-test-result")

        (find("prompt-test-run", in: root) as? NSButton)?.performClick(nil)
        deliver?(.timedOut)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check("a failed test wears the real path's own sentence",
              sheet.statusTextForTesting == TextTransformRetryDescriptor.Failure.timedOut.userMessage)
        capture(root, card: nil, to: outDir + "/prompt-workstation-test-failure.png",
                name: "workstation-test-failure")

        // Two captures of the SAME view after a state change. A layer-backed subtree will serve the
        // second one out of cached layer contents unless the capture seam forces a redraw, and the
        // blank-detector cannot catch that: both files are full of ink, and the second silently shows
        // the first state. Byte inequality is the assertion that the seam actually re-rendered.
        check("the two test captures are different images, not one state photographed twice",
              fileBytes(outDir + "/prompt-workstation-test-result.png")
                != fileBytes(outDir + "/prompt-workstation-test-failure.png"))

        // The state a brand-new hotkey opens in: the seeded default is a multi-paragraph prompt, so this
        // is where a fixed-height editable region would clip the very text the panel is teaching. It also
        // stands in for an empty History - the sample field starts blank rather than truncated.
        var blank = mode
        blank.id = "render-workstation-seeded"
        blank.name = "New hotkey"
        blank.prompt = defaultCustomModeTaskPrompt
        let seeded = PromptEditorSheet.customModeWorkstation(
            title: "New hotkey · Shared task prompt", mode: blank,
            bench: PromptTestBenchConfig(mode: blank, history: { [] },
                                         runner: { _, _, _ in }),
            onSave: { _ in })
        let seededRoot = seeded.contentViewForTesting
        seededRoot.wantsLayer = true
        seededRoot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        check("the seeded default prompt is shown in full, not clipped",
              seeded.displayedAssemblyForTesting?.system
                == CustomModeClient.systemPrompt(taskPrompt: defaultCustomModeTaskPrompt))
        check("an empty History leaves the sample field blank rather than truncated",
              seeded.sampleTextForTesting.isEmpty)
        capture(seededRoot, card: nil, to: outDir + "/prompt-workstation-seeded.png",
                name: "workstation-seeded")
    }

    /// The sheet the Edit prompt button opens, driven through its real Restore control.
    private static func captureEditor(routing: ModelsPowerSettingsStore,
                                      provider: LLMProvider, outDir: String) {
        let shipped = routing.factoryPrompt(for: .email, provider: provider)
        let sheet = PromptEditorSheet.makeForTesting(
            title: "\(ModelsPowerSettingsView.displayName(for: provider)) · Email (Option+M) · Email",
            subtitle: "Customized. Restore shipped default, then Save, clears your override.",
            text: routing.effectivePrompt(for: .email, provider: provider),
            shippedDefault: shipped,
            onSave: { _ in })
        // A sheet gets its backdrop from its window, which an offscreen capture of the content view alone
        // does not draw — without it the label text renders onto transparency and reads as blank.
        let root = sheet.contentViewForTesting
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        capture(sheet.contentViewForTesting, card: nil,
                to: outDir + "/prompt-editor-customized.png", name: "editor-customized")
        (find("prompt-editor-restore", in: root) as? NSButton)?.performClick(nil)
        check("Restore shipped default loads the shipped bytes into the editor",
              sheet.editorTextForTesting == shipped)
        capture(sheet.contentViewForTesting, card: nil,
                to: outDir + "/prompt-editor-restored.png", name: "editor-restored")
    }

    private static func isExpanded(_ view: NSView) -> Bool {
        allViews(in: view).contains { $0.identifier?.rawValue.hasPrefix("edit-prompt|email|") == true }
    }

    /// Render `card` (or the whole view) to PNG and assert it carries real pixels. The mechanics are shared
    /// with the other capture gates (`SelfTestRenderCapture`); this gate keeps only its own check accounting.
    private static func capture(_ view: NSView, card: String?, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: card, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func fileBytes(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func allViews(in root: NSView) -> [NSView] {
        SelfTestRenderCapture.allViews(in: root)
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }
}
