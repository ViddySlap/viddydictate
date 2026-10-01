import Cocoa
import Security

/// Offscreen render-to-PNG seam for the Setup tab (`--setup-render <outdir>`), the surface that shows P8's
/// preflight report (item P11).
///
/// Like `--hud-render` and `--models-power-render` this is an in-process render, NOT a screen capture
/// (screen capture from an agent shell is TCC-blocked), so the link that builds the surface can actually
/// LOOK at it. The observation is synthetic, so nothing here depends on this machine's daemon, providers,
/// keychain, or TCC grants - which also means the "before" capture can be a machine where every single
/// check fails, a state no real Mac would helpfully be in on demand.
///
/// PNGs written:
///   - `setup-warnings.png`     - every check failing: seven rows, each with its fix and its consequence.
///   - `setup-row-provider.png` - the longest row on its own (the no-provider remedy is a menu of three).
///   - `setup-clean.png`        - after Check again on a now-healthy machine: the same surface, all OK.
///   - `setup-gemini-key.png`   - the Gemini key section with no key stored: the instructions, the URL, the
///                                warm line, the secure field (L5).
///   - `setup-gemini-saved.png` - the same section after a key was pasted and saved, which is also the proof
///                                the field was CLEARED and the value reached no label.
///   - `setup-gemini-delete-confirm.png` - the delete confirmation, mid-question, with the key still stored
///                                (L9).
///   - `setup-gemini-environment.png`    - the one state that offers no delete at all: a key arriving from
///                                the environment override, with the reason on screen (L9).
///   - `setup-local-models.png` - the Local models section as this Mac reports it: the budget slider at its
///                                shipped default with the machine's own kernel ceiling under it, the idle
///                                timer, and LM Studio's JIT timeout at the hour that pinned 28.7 GB.
///   - `setup-local-models-floor.png` / `setup-local-models-ceiling.png` - the same section at slider 0 and
///                                100, which is the proof a static capture cannot make on its own: the
///                                gigabyte line is a function of the handle, not a caption beside it.
///   - `setup-local-models-jit-ok.png`   - the LM Studio row when there is nothing to do.
///   - `setup-local-models-no-facts.png` - the machine whose kernel ceiling is unreadable, where there is no
///                                budget to state and the section says so instead of guessing one.
///   - `setup-local-apps-*.png` - the local app rows and the Preferred local app (Ollama lane S3c), listed in
///                                `LocalAppsSetupRenderCases`.
/// The pair is the before/after proof that the surface is re-runnable rather than a first-run snapshot.
enum SetupRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pin the appearance so a capture does not silently change meaning with whatever the host Mac is
        // set to. The app itself follows the system; only the render seam is pinned.
        app.appearance = NSAppearance(named: .darkAqua)

        let fm = FileManager.default
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[setup-render] cannot create \(outDir): \(error)")
            return false
        }

        // The measuring half, replaced. `calls` is what proves Check again actually re-measures instead of
        // re-rendering a cached verdict: a button that only redrew would leave this at 1.
        var observation = PreflightSelfTest.broken
        var calls = 0
        // The Local models section measures two settings and one LM Studio file rather than the tab's
        // observation, so it is driven separately. Its store is in-memory on purpose: this gate drags the
        // budget slider across its whole range, and a capture must never write the settings of the app the
        // user is running. Seeded from `Settings`, so what reaches the screen is still the SHIPPED default.
        let store = LocalModelStore(position: Settings.modelMemoryBudgetSliderPosition,
                                    seconds: Settings.modelIdleUnloadSeconds)
        check("the shipped budget default reaches the section", store.position == 54, "\(store.position)")
        check("the shipped idle timer reaches the section", store.seconds == 600, "\(store.seconds)")
        // The hour that pinned 28.7 GB on 2026-08-21, which is what this machine's LM Studio still says.
        var jit: LocalModelSetup.JITSettings? = .init(ttlSeconds: 3600, enabled: true)
        // Ben's machine at 07:40 on 2026-08-27, frozen: the 17.19 GB coder model he had loaded, plus the
        // vault's embedding model, which LM Studio holds with NO TTL at all. That pair is the exact state
        // the budget was correct and silent about, so it is the state the section is photographed in.
        let residency = LocalResidencyStub(models: Self.bensModels, wired: 21_400_000_000)
        let view = SetupSettingsView(width: 640, observer: { completion in
            calls += 1
            completion(observation)
        }, localModels: .init(store: store.store, facts: { .live }, jit: { jit },
                              residency: residency.reader, unloadAll: residency.unloader,
                              now: { Self.clock }, apps: LocalAppActionsRecorder().actions))
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        // In the app this view is a scroll-view document over the tab's own backdrop. Captured on its own it
        // has neither, and the mixed layer-backed/unlayered hierarchy that produces renders a bezelled
        // control's title onto transparency - the Check again button came out as a blank white pill. Giving
        // the captured root a layer and the window backdrop it normally sits on restores it. Same class of
        // artifact the prompt-editor capture documents in ModelsPowerRender.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("building the surface runs the check once", calls == 1, "calls=\(calls)")
        assertReport(view, Preflight.evaluate(observation), state: "warnings")
        assertLayout(view)
        assertLocalModels(view, position: 54, facts: .live,
                          status: .tooLong(ttlSeconds: 3600, appSeconds: 600),
                          residency: .models(Self.bensModels), wired: 21_400_000_000,
                          state: "warnings")
        assertLocalModelsLayout(view, state: "warnings")
        capture(view, card: nil, to: outDir + "/setup-warnings.png", name: "warnings")
        capture(view, card: PreflightSurface.cardIdentifier(.textProvider),
                to: outDir + "/setup-row-provider.png", name: "provider row")
        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models.png", name: "local models")

        // Re-run against a machine that has since been fixed. Same view, same button, new reading. LM Studio
        // was fixed too, which is what proves Check again refreshes the JIT row along with everything else -
        // it is measured on a different clock from the tab's observation and could easily have gone stale.
        observation = PreflightSelfTest.healthy
        jit = .init(ttlSeconds: 600, enabled: true)
        let button = find(PreflightSurface.recheckIdentifier, in: view) as? NSButton
        check("Check again is offered once a check has finished", button?.isEnabled == true)
        // D8: the first-run window's re-open button, beside Check again, clicked through its seam (no window).
        var rerunClicks = 0
        view.onRunFirstRunSetup = { rerunClicks += 1 }
        let rerun = find(FirstRunSetupPresenter.rerunIdentifier, in: view) as? NSButton
        rerun?.performClick(nil)
        check("Run first-run setup again sits left of Check again, clear of the title, and reaches its seam",
              rerun?.title == FirstRunSetupPresenter.rerunTitle && rerunClicks == 1
                && (rerun?.frame.maxX ?? .infinity) <= (button?.frame.minX ?? 0)
                && (rerun?.frame.width ?? 0) >= (rerun?.fittingSize.width ?? .infinity),
              "clicks=\(rerunClicks)")
        button?.performClick(nil)
        check("Check again measures the machine again", calls == 2, "calls=\(calls)")
        assertReport(view, Preflight.evaluate(observation), state: "clean")
        assertLayout(view)
        assertLocalModels(view, position: 54, facts: .live,
                          status: .matched(ttlSeconds: 600),
                          residency: .models(Self.bensModels), wired: 21_400_000_000,
                          state: "clean")
        assertLocalModelsLayout(view, state: "clean")
        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models-jit-ok.png", name: "local models (LM Studio settled)")
        check("a fixed machine leaves no stale fix on screen",
              PreflightCheck.allCases.allSatisfy {
                  find(PreflightSurface.identifier(.remedy, $0), in: view) == nil
                      && find(PreflightSurface.identifier(.reduced, $0), in: view) == nil
              })
        capture(view, card: nil, to: outDir + "/setup-clean.png", name: "clean")

        driveBudgetSlider(view, store: store, host: host, outDir: outDir)
        driveResidency(view, store: store, residency: residency, outDir: outDir)

        view.removeFromSuperview()
        driveGeminiKeySection(outDir: outDir)
        driveLocalModelsWithoutKernelFacts(outDir: outDir)
        driveResidencyPending(outDir: outDir)
        LocalAppsSetupRenderCases.run(outDir: outDir) { name, ok, detail in check(name, ok, detail) }
        print("[setup-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - The local-model budget slider (item L5, LOCKED DECISION 6)

    /// The one claim a still image cannot make for itself: that the gigabyte line is a READOUT of the handle
    /// rather than a caption printed beside it.
    ///
    /// So the slider is dragged for real - the control's value is set and its action fired, which is the
    /// same path a mouse takes - and the line is read back at each stop and compared against the budget
    /// computed independently from `SystemMemory`. Two of the stops are photographed, so the proof is
    /// legible in the PNGs as well as in this log.
    private static func driveBudgetSlider(_ view: NSView, store: LocalModelStore, host: NSWindow,
                                          outDir: String) {
        guard let slider = find(LocalModelSetup.identifier(.budgetSlider), in: view) as? NSSlider else {
            check("[budget] the section offers a slider", false)
            return
        }
        check("[budget] the slider's face is 0 to 100, not a percentage of anything",
              slider.minValue == 0 && slider.maxValue == 100,
              "\(slider.minValue)...\(slider.maxValue)")

        var seen: [String] = []
        var wrong: [String] = []
        var torn = false
        for position in [0.0, 25.0, 54.0, 60.0, 100.0] {
            drag(view, to: position)
            let expected = LocalModelSetup.budgetLine(position: position, facts: .live)
            let shown = label(LocalModelSetup.identifier(.budgetLine), in: view)?.stringValue
            if shown != expected { wrong.append("\(Int(position)): \(shown ?? "missing")") }
            if label(LocalModelSetup.identifier(.budgetLevel), in: view)?.stringValue
                != String(Int(position)) { wrong.append("\(Int(position)).level") }
            if store.position != position { wrong.append("\(Int(position)).stored=\(store.position)") }
            // The slider is continuous, so its action fires on every mouse move of a real drag. If handling
            // it rebuilds the card, the control the mouse is tracking is removed from under the pointer and
            // the drag dies after the first pixel - while still reading perfectly here, because this gate
            // sets a value and fires an action rather than holding a mouse down. So the identity of the
            // control is asserted, which is the part a programmatic drive can actually see.
            if find(LocalModelSetup.identifier(.budgetSlider), in: view) !== slider { torn = true }
            seen.append(shown ?? "")
            if position == 0 {
                capture(view, card: LocalModelSetup.sectionIdentifier,
                        to: outDir + "/setup-local-models-floor.png", name: "local models (slider 0)")
            }
            if position == 100 {
                capture(view, card: LocalModelSetup.sectionIdentifier,
                        to: outDir + "/setup-local-models-ceiling.png", name: "local models (slider 100)")
            }
        }
        check("[budget] the gigabyte line tracks the handle at every stop", wrong.isEmpty,
              wrong.joined(separator: ", "))
        check("[budget] no two stops read the same, so the line is not a fixed caption",
              Set(seen).count == seen.count, seen.joined(separator: " | "))
        check("[budget] moving the handle refreshes the readout without replacing the slider under it",
              !torn)

        // A handle resting between two integers must not render one number above the gigabytes for another.
        drag(view, to: 53.6)
        check("[budget] a handle between stops rounds the level and the gigabytes together",
              label(LocalModelSetup.identifier(.budgetLevel), in: view)?.stringValue == "54"
                && label(LocalModelSetup.identifier(.budgetLine), in: view)?.stringValue
                    == LocalModelSetup.budgetLine(position: 54, facts: .live))
        check("[budget] nothing fractional is persisted", store.position == 54, "\(store.position)")

        // The timer is the other half of the section, and the LM Studio row is measured against it. Raising
        // it above LM Studio's own has to settle that row, which is what proves the two are wired together
        // rather than each reporting its own constant.
        guard let popup = find(LocalModelSetup.identifier(.timerControl), in: view) as? NSPopUpButton else {
            check("[budget] the section offers an idle-timer control", false)
            return
        }
        check("[budget] the timer is offered in minutes, showing the shipped 10",
              popup.titleOfSelectedItem == "10 min", popup.titleOfSelectedItem ?? "nil")
        choose(popup, "60 min")
        check("[budget] choosing a timer stores its seconds", store.seconds == 3600, "\(store.seconds)")
        check("[budget] the LM Studio row is measured against the app's own timer, not a constant",
              label(LocalModelSetup.identifier(.jitStatus), in: view)?.stringValue == "OK",
              label(LocalModelSetup.identifier(.jitStatus), in: view)?.stringValue ?? "missing")

        // Put the section back the way it was photographed, so nothing downstream inherits a dragged state.
        if let popup = find(LocalModelSetup.identifier(.timerControl), in: view) as? NSPopUpButton {
            choose(popup, "10 min")
        }
        drag(view, to: 54)
        _ = host
    }

    /// Ask the section to take a fresh reading, the way its own refresh timer does. Used after changing
    /// what the stub LM Studio reports, so the section is driven through its real refresh path rather than
    /// having its labels written to directly.
    private static func refreshSection(_ view: NSView) {
        (find(LocalModelSetup.sectionIdentifier, in: view) as? LocalModelsSectionView)?.apply()
    }

    /// Move the handle the way a mouse does: set the value, then fire the control's action.
    private static func drag(_ view: NSView, to position: Double) {
        guard let slider = find(LocalModelSetup.identifier(.budgetSlider), in: view) as? NSSlider else {
            return
        }
        slider.doubleValue = position
        fire(slider)
    }

    /// Pick a menu item, then fire the action. Deliberately NOT `performClick`, which on an NSPopUpButton
    /// opens the menu and enters a modal tracking runloop - a headless gate that calls it never returns.
    private static func choose(_ popup: NSPopUpButton, _ title: String) {
        popup.selectItem(withTitle: title)
        fire(popup)
    }

    /// Send a control's action to its target, the way AppKit would once the user let go of it.
    private static func fire(_ control: NSControl) {
        guard let target = control.target, let action = control.action else { return }
        _ = target.perform(action, with: control)
    }

    // MARK: - The live resident-set readout (item L4, LOCKED DECISION 2)

    /// A fixed clock, so the TTL countdown in the capture is the same picture every run.
    static let clock = Date(timeIntervalSince1970: 1_787_849_000)

    /// Ben's machine at 07:40 on 2026-08-27. The coder model was last used two minutes before this
    /// clock and carries the shipped ten-minute TTL; the vault's embedding model carries `ttlMs: null`,
    /// which is the state that pinned 28.7 GB for an hour on 2026-08-21 and must not render as blank.
    static let bensModels: [ModelResidency.ResidentModel] = [
        .init(identifier: "qwen3-coder-30b-a3b-instruct-mlx", sizeBytes: 17_190_793_452,
              lastUsedTime: 1_787_848_880_000, status: "idle", ttlSeconds: 600),
        .init(identifier: "text-embedding-bge-m3", sizeBytes: 634_553_760,
              lastUsedTime: 1_787_848_880_000, status: "idle", ttlSeconds: nil),
    ]

    /// The claim the whole item rests on, and the one a still image cannot make for itself: that the
    /// readout is a READING of the machine rather than a caption, that the summary's denominator is the
    /// handle beside it, and that Unload all actually changes what the section then reports.
    ///
    /// Every `lms` call in production is a subprocess, so this gate also proves the section never waits
    /// on one: `driveResidencyPending` holds the answer back and photographs what is on screen meanwhile.
    private static func driveResidency(_ view: NSView, store: LocalModelStore,
                                       residency: LocalResidencyStub, outDir: String) {
        guard let list = label(LocalModelSetup.identifier(.residencyList), in: view) else {
            check("[residency] the section lists what is loaded", false)
            return
        }
        check("[residency] the list names every resident model, its size and its state",
              list.stringValue.contains("qwen3-coder-30b-a3b-instruct-mlx")
                && list.stringValue.contains("17.2 GB")
                && list.stringValue.contains("text-embedding-bge-m3")
                && list.stringValue.contains("0.6 GB"),
              list.stringValue.replacingOccurrences(of: "\n", with: " / "))
        check("[residency] the biggest model is on the first line",
              list.stringValue.hasPrefix("qwen3-coder-30b-a3b-instruct-mlx"))
        check("[residency] a model with a TTL says when it goes",
              list.stringValue.contains("unloads in 8 min"))
        check("[residency] a model LM Studio holds with no TTL says so rather than rendering blank",
              list.stringValue.contains("no timeout"))
        check("[residency] the rows are monospaced, so the padded columns line up",
              list.font == NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
              list.font?.fontName ?? "nil")

        // The sentence the item exists for. Asserted on the SURFACE, verbatim, not merely in the pure gate:
        // it is the thing Ben lost a hand test to the absence of.
        check("[residency] the section says a lowered budget does not evict what is already loaded",
              label(LocalModelSetup.identifier(.residencyNote), in: view)?.stringValue
                == "Lowering the budget applies to the next model load. Models already in memory keep "
                    + "running.",
              label(LocalModelSetup.identifier(.residencyNote), in: view)?.stringValue ?? "missing")

        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models-loaded.png", name: "local models (loaded)")

        // The summary's denominator is the handle. Drag it and the line has to follow, or the number and
        // the knob are two separate claims again - which is the exact defect LOCKED DECISION 2 addresses.
        var summaries: [String] = []
        var wrong: [String] = []
        for position in [0.0, 54.0, 100.0] {
            drag(view, to: position)
            let expected = LocalModelSetup.residencySummary(position: position, facts: .live,
                                                            wiredBytes: 21_400_000_000)
            let shown = label(LocalModelSetup.identifier(.residencySummary), in: view)?.stringValue
            if shown != expected { wrong.append("\(Int(position)): \(shown ?? "missing")") }
            summaries.append(shown ?? "")
            if position == 0 {
                capture(view, card: LocalModelSetup.sectionIdentifier,
                        to: outDir + "/setup-local-models-loaded-floor.png",
                        name: "local models (loaded, budget dragged to 0)")
            }
        }
        check("[residency] the in-use summary tracks the budget handle", wrong.isEmpty,
              wrong.joined(separator: ", "))
        // Dragging the handle BELOW what is already in use is the scenario the readout exists for, so the
        // colour has to move with the number rather than being fixed when the card was built.
        drag(view, to: 0)
        check("[residency] a budget dragged under what is in use reads as needing attention",
              label(LocalModelSetup.identifier(.residencySummary), in: view)?.textColor == .systemOrange)
        drag(view, to: 100)
        check("[residency] a budget with room to spare reads as ordinary, not as a warning",
              label(LocalModelSetup.identifier(.residencySummary), in: view)?.textColor == .labelColor)
        check("[residency] no two positions read the same, so the summary is not a fixed caption",
              Set(summaries).count == summaries.count, summaries.joined(separator: " | "))
        check("[residency] the summary reads in the established GB-of-GB style",
              summaries.allSatisfy { $0.contains(" GB of ") && $0.hasSuffix(" budget in use") },
              summaries.joined(separator: " | "))
        drag(view, to: 54)
        check("[residency] the summary states the machine's whole wired total against the budget",
              label(LocalModelSetup.identifier(.residencySummary), in: view)?.stringValue
                == "21.4 GB of 33.9 GB budget in use",
              label(LocalModelSetup.identifier(.residencySummary), in: view)?.stringValue ?? "missing")

        // Unload all: the control that makes a lowered budget true immediately.
        guard let button = find(LocalModelSetup.identifier(.unloadAll), in: view) as? NSButton else {
            check("[residency] the section offers an Unload all button", false)
            return
        }
        check("[residency] Unload all is offered while something is loaded", button.isEnabled)
        residency.reading = .init(models: [], wiredBytes: 4_100_000_000)
        fire(button)
        check("[residency] Unload all reaches the unload seam exactly once",
              residency.unloadCalls == 1, "\(residency.unloadCalls)")
        check("[residency] the section re-measures after unloading instead of believing its own request",
              residency.readCallsAfterUnload >= 1, "\(residency.readCallsAfterUnload)")
        check("[residency] an empty machine says nothing is loaded rather than rendering a blank block",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue
                .hasPrefix("Nothing is loaded right now.") == true,
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue ?? "missing")
        check("[residency] the summary falls with the freed memory",
              label(LocalModelSetup.identifier(.residencySummary), in: view)?.stringValue
                == "4.1 GB of 33.9 GB budget in use",
              label(LocalModelSetup.identifier(.residencySummary), in: view)?.stringValue ?? "missing")
        check("[residency] Unload all is disabled once there is nothing left to unload",
              (find(LocalModelSetup.identifier(.unloadAll), in: view) as? NSButton)?.isEnabled == false)
        // The columns' font travels with the columns. An empty machine's sentence left in a monospaced
        // face reads as a code dump, and this is the state that most often follows a click.
        check("[residency] an empty machine's sentence drops the columns' monospaced face",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.font
                == NSFont.systemFont(ofSize: 10.5),
              label(LocalModelSetup.identifier(.residencyList), in: view)?.font?.fontName ?? "nil")
        assertLocalModelsLayout(view, state: "unloaded")
        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models-unloaded.png", name: "local models (after Unload all)")

        // An LM Studio that cannot be asked is a different fact from an empty one, and must not read as
        // an all-clear.
        residency.reading = .init(models: nil, wiredBytes: 21_400_000_000)
        refreshSection(view)
        check("[residency] an unreadable LM Studio says so rather than claiming nothing is loaded",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue
                .contains("could not ask LM Studio") == true,
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue ?? "missing")
        check("[residency] Unload all is disabled when the resident set is unknown",
              (find(LocalModelSetup.identifier(.unloadAll), in: view) as? NSButton)?.isEnabled == false)
        assertLocalModelsLayout(view, state: "unreadable")
        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models-unreadable.png",
                name: "local models (LM Studio unreadable)")

        // Put the section back the way the earlier captures found it.
        residency.reading = .init(models: bensModels, wiredBytes: 21_400_000_000)
        refreshSection(view)
        drag(view, to: 54)
        _ = store
    }

    /// The proof that the section does not BLOCK on the LM Studio CLI.
    ///
    /// `lms ps` costs about a sixth of a second, and the 2026-07-13 freeze was a synchronous call of that
    /// kind behind the filtering event tap, which stalled every keystroke on the Mac. So this stub simply
    /// never answers: the section is built, and what is on screen afterwards is photographed. A section
    /// that waited for the CLI could not have returned from its own initialiser to be photographed at all,
    /// and one that rendered an empty list would be claiming a machine state it had not measured.
    private static func driveResidencyPending(outDir: String) {
        let store = LocalModelStore(position: 54, seconds: 600)
        let residency = LocalResidencyStub(models: bensModels, wired: 21_400_000_000)
        residency.withholdsAnswer = true
        let view = SetupSettingsView(width: 640, observer: { $0(PreflightSelfTest.healthy) },
                                     geminiKeyWriter: { _ in errSecSuccess },
                                     geminiKeyDeleter: { errSecSuccess },
                                     localModels: .init(store: store.store, facts: { .live },
                                                        jit: { nil },
                                                        residency: residency.reader,
                                                        unloadAll: residency.unloader,
                                                        now: { clock },
                                                        apps: LocalAppActionsRecorder().actions))
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 2200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("[pending] building the section asks for a reading without waiting for one",
              residency.readCalls >= 1, "\(residency.readCalls)")
        check("[pending] a reading that has not landed reads as pending, not as an empty machine",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue
                == "Reading LM Studio...",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue ?? "missing")
        check("[pending] the pending sentence is prose, not columns",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.font
                == NSFont.systemFont(ofSize: 10.5))
        check("[pending] Unload all is disabled until the machine has actually been read",
              (find(LocalModelSetup.identifier(.unloadAll), in: view) as? NSButton)?.isEnabled == false)
        check("[pending] the sentence about lowering the budget is on screen before any reading lands",
              label(LocalModelSetup.identifier(.residencyNote), in: view)?.stringValue
                == LocalModelSetup.residencyNote)
        assertLocalModelsLayout(view, state: "pending")
        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models-pending.png", name: "local models (reading)")

        // ...and once it does land, the same section fills in without being rebuilt by anyone.
        residency.withholdsAnswer = false
        residency.deliverParked()
        check("[pending] the reading fills the section in when it finally arrives",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue
                .contains("qwen3-coder-30b-a3b-instruct-mlx") == true,
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue ?? "missing")
        view.removeFromSuperview()
    }

    /// The machine whose kernel ceiling is unreadable. There is no budget to state, so the section must say
    /// so rather than substitute `hw.memsize` - which would hand models the 12 GB macOS reserves and can
    /// never lend out. Rendered on its own because the facts are fixed when the section is built.
    private static func driveLocalModelsWithoutKernelFacts(outDir: String) {
        let store = LocalModelStore(position: 54, seconds: 600)
        let residency = LocalResidencyStub(models: bensModels, wired: 21_400_000_000)
        let view = SetupSettingsView(width: 640, observer: { $0(PreflightSelfTest.healthy) },
                                     geminiKeyWriter: { _ in errSecSuccess },
                                     geminiKeyDeleter: { errSecSuccess },
                                     localModels: .init(store: store.store,
                                                        facts: { .init(userWireLimitBytes: nil,
                                                                       noUserWireBytes: nil) },
                                                        jit: { nil },
                                                        residency: residency.reader,
                                                        unloadAll: residency.unloader,
                                                        now: { clock },
                                                        apps: LocalAppActionsRecorder().actions))
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 2200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        assertLocalModels(view, position: 54,
                          facts: .init(userWireLimitBytes: nil, noUserWireBytes: nil),
                          status: .unknown, residency: .models(bensModels), wired: 21_400_000_000,
                          state: "no kernel facts")
        assertLocalModelsLayout(view, state: "no kernel facts")
        check("[no kernel facts] the section states no budget at all",
              label(LocalModelSetup.identifier(.budgetLine), in: view)?.stringValue.contains("GB of")
                == false)
        check("[no kernel facts] the reserved line is omitted rather than guessed",
              find(LocalModelSetup.identifier(.reservedLine), in: view) == nil)
        // There is no budget to be in use against, and `budgetLine` has already said so. A lone "in use"
        // figure here would be the second half of a sentence whose first half does not exist.
        check("[no kernel facts] the in-use summary is omitted rather than stated against nothing",
              find(LocalModelSetup.identifier(.residencySummary), in: view) == nil)
        check("[no kernel facts] what is loaded is still reported, because that was measured",
              label(LocalModelSetup.identifier(.residencyList), in: view)?.stringValue
                .contains("qwen3-coder-30b-a3b-instruct-mlx") == true)
        check("[no kernel facts] the sentence about lowering the budget is still on screen",
              label(LocalModelSetup.identifier(.residencyNote), in: view)?.stringValue
                == LocalModelSetup.residencyNote)
        check("[no kernel facts] the slider is still offered, so the setting can still be chosen",
              find(LocalModelSetup.identifier(.budgetSlider), in: view) is NSSlider)
        check("[no kernel facts] an unreadable LM Studio file does not read as a warning",
              label(LocalModelSetup.identifier(.jitStatus), in: view)?.stringValue == "NOT READ")
        capture(view, card: LocalModelSetup.sectionIdentifier,
                to: outDir + "/setup-local-models-no-facts.png", name: "local models (no kernel facts)")
        view.removeFromSuperview()
    }

    /// Every line the pure layer says the section shows, on screen and reading exactly what it says. This is
    /// what makes the PNGs trustworthy: a capture alone cannot tell a correct number from a plausible one.
    private static func assertLocalModels(_ view: NSView, position: Double,
                                          facts: LocalModelSetup.MemoryFacts,
                                          status: LocalModelSetup.JITStatus,
                                          residency: LocalModelSetup.Residency,
                                          wired: UInt64?, state: String) {
        check("[local models \(state)] the section is on the Setup tab",
              find(LocalModelSetup.cardIdentifier, in: view) != nil
                && find(LocalModelSetup.jitCardIdentifier, in: view) != nil)

        var wrong: [String] = []
        let expected: [(LocalModelSetup.Part, String?)] = [
            (.headline, LocalModelSetup.headline),
            (.purpose, LocalModelSetup.purpose),
            (.budgetTitle, LocalModelSetup.budgetTitle),
            (.budgetLevel, LocalModelSetup.budgetLevelText(position)),
            (.budgetLine, LocalModelSetup.budgetLine(position: position, facts: facts)),
            (.reservedLine, LocalModelSetup.reservedLine(facts: facts)),
            (.residencyTitle, LocalModelSetup.residencyTitle),
            (.residencyList, LocalModelSetup.residencyList(residency, now: clock)),
            (.residencySummary, LocalModelSetup.residencySummary(position: position, facts: facts,
                                                                 wiredBytes: wired)),
            (.residencyNote, LocalModelSetup.residencyNote),
            (.timerTitle, LocalModelSetup.timerTitle),
            (.timerHint, LocalModelSetup.timerHint),
            (.jitStatus, LocalModelSetup.jitStatusText(status)),
            (.jitTitle, LocalModelSetup.jitTitle),
            (.jitSummary, LocalModelSetup.jitSummary(status)),
            (.jitRemedy, LocalModelSetup.jitRemedy(status)),
            (.jitConsequence, LocalModelSetup.jitConsequence(status)),
        ]
        // Present exactly when the pure layer has one: a settled LM Studio row that rendered a "Fix:" line
        // would be as wrong as a too-long row that dropped it.
        for (part, value) in expected
        where label(LocalModelSetup.identifier(part), in: view)?.stringValue != value {
            wrong.append(part.rawValue)
        }
        check("[local models \(state)] every line is on screen and is the pure layer's own",
              wrong.isEmpty, wrong.joined(separator: ","))

        // The load-bearing rendering rule, asserted at the surface rather than only in the pure gate: the
        // face is 0...100 but maps onto 25...90% of the wire ceiling, so a "%" here would state a falsehood.
        let level = label(LocalModelSetup.identifier(.budgetLevel), in: view)?.stringValue ?? "?"
        check("[local models \(state)] the slider's own number carries no percent sign",
              !level.contains("%"), level)
        check("[local models \(state)] the slider's own number carries no unit at all",
              Int(level) != nil, level)
        check("[local models \(state)] the gigabyte line is the only place a size is claimed",
              !(label(LocalModelSetup.identifier(.reservedLine), in: view)?.stringValue.contains("of")
                ?? false))

        // No line in this section renders at tertiary, in ANY state. Measured on the composited render
        // (`vdmg-REV`, 2026-08-24): tertiary body copy against this card's fill is 2.26:1, below the
        // 3:1 floor for even large text, while secondary is 5.72:1. The colour constant looks perfectly
        // reasonable in the source and only the render shows the problem, which is why this is asserted
        // at the surface rather than left to a reading of the file.
        let tertiary = LocalModelSetup.Part.allCases
            .filter { !$0.isControl }
            .filter { label(LocalModelSetup.identifier($0), in: view)?.textColor == .tertiaryLabelColor }
            .map(\.rawValue)
        check("[local models \(state)] no line in the section renders at tertiary",
              tertiary.isEmpty, tertiary.joined(separator: ","))
    }

    /// The layout claims a screenshot cannot make for itself. This card holds two controls and the longest
    /// line on the tab after the Gemini remedy, so a clipped line here hides a number and an overlapping
    /// control puts the level under the handle.
    private static func assertLocalModelsLayout(_ view: NSView, state: String) {
        guard let card = find(LocalModelSetup.cardIdentifier, in: view),
              let jitCard = find(LocalModelSetup.jitCardIdentifier, in: view),
              let section = find(LocalModelSetup.sectionIdentifier, in: view) else {
            check("[local models \(state)] the section has both of its cards", false)
            return
        }

        var clipped: [String] = []
        for part in LocalModelSetup.Part.allCases where !part.isControl {
            guard let field = label(LocalModelSetup.identifier(part), in: view) else { continue }
            let needed = field.sizeThatFits(
                NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
            if field.frame.height + 0.5 < needed { clipped.append(part.rawValue) }
        }
        check("[local models \(state)] no line of the section is clipped by its own frame",
              clipped.isEmpty, clipped.joined(separator: ","))

        for (name, box) in [("controls", card), ("LM Studio row", jitCard)] {
            let contentBottom = box.subviews.map(\.frame.maxY).max() ?? 0
            check("[local models \(state)] the \(name) card contains its own contents",
                  box.frame.height + 0.5 >= contentBottom,
                  "card=\(Int(box.frame.height)) content=\(Int(contentBottom))")
            check("[local models \(state)] nothing in the \(name) card runs past its width",
                  box.subviews.allSatisfy { $0.frame.maxX <= box.bounds.maxX + 0.5 },
                  box.subviews.filter { $0.frame.maxX > box.bounds.maxX + 0.5 }
                    .map { $0.identifier?.rawValue ?? "?" }.joined(separator: ","))
        }
        check("[local models \(state)] the two cards do not overlap",
              jitCard.frame.minY >= card.frame.maxY - 0.5,
              "controls end \(Int(card.frame.maxY)), row starts \(Int(jitCard.frame.minY))")
        check("[local models \(state)] the section is tall enough to hold both cards",
              section.frame.height + 0.5 >= jitCard.frame.maxY,
              "section=\(Int(section.frame.height)) row ends \(Int(jitCard.frame.maxY))")

        // The title, the slider and the level share a row, so a width change on any of them would silently
        // overlap the next.
        if let title = find(LocalModelSetup.identifier(.budgetTitle), in: view),
           let slider = find(LocalModelSetup.identifier(.budgetSlider), in: view),
           let level = find(LocalModelSetup.identifier(.budgetLevel), in: view) {
            check("[local models \(state)] the budget title, slider and level do not overlap",
                  title.frame.maxX <= slider.frame.minX + 0.5
                    && slider.frame.maxX <= level.frame.minX + 0.5,
                  "title ends \(Int(title.frame.maxX)), slider \(Int(slider.frame.minX))"
                    + "..\(Int(slider.frame.maxX)), level starts \(Int(level.frame.minX))")
        }
        if let title = find(LocalModelSetup.identifier(.timerTitle), in: view),
           let popup = find(LocalModelSetup.identifier(.timerControl), in: view) {
            check("[local models \(state)] the timer title and its control do not overlap",
                  title.frame.maxX <= popup.frame.minX + 0.5,
                  "title ends \(Int(title.frame.maxX)), control starts \(Int(popup.frame.minX))")
        }

        // The section sits below the Gemini key section, not on top of it (one document view).
        if let gemini = find(GeminiKeySetup.cardIdentifier, in: view) {
            let above = gemini.convert(gemini.bounds, to: view)
            let here = section.convert(section.bounds, to: view)
            check("[local models \(state)] the section sits below the Gemini key section",
                  here.minY >= above.maxY - 0.5,
                  "gemini ends \(Int(above.maxY)), local models starts \(Int(here.minY))")
        }
        // ...and above the read-only preflight rows, which is where a setting belongs on this tab.
        if let firstRow = find(PreflightSurface.cardIdentifier(.sttDaemon), in: view) {
            let below = firstRow.convert(firstRow.bounds, to: view)
            let here = section.convert(section.bounds, to: view)
            check("[local models \(state)] the section sits above the read-only checks",
                  here.maxY <= below.minY + 0.5,
                  "local models ends \(Int(here.maxY)), first row starts \(Int(below.minY))")
        }
    }

    // MARK: - The Gemini key section (L5, spec decision D7)

    /// The section that takes a secret, driven end to end on its own tab with a synthetic writer in place of
    /// the login keychain (an agent shell cannot write one, and this gate must not depend on machine state).
    ///
    /// What a screenshot cannot assert, and this does: that the field is a SECURE field, that a pasted key
    /// reaches the app's keychain writer, that no label anywhere on the tab carries the value afterwards,
    /// that a successful save clears the field and re-MEASURES the tab (so the preflight key row below
    /// refreshes from the same observation), and that a blank Save writes nothing at all.
    ///
    /// L9 adds the other half: that a stored key can be REMOVED, that one click asks rather than deleting,
    /// that cancelling changes nothing, that a confirmed delete reaches the app's one `SecItemDelete`, and
    /// that the section re-measures afterwards instead of announcing a result it did not verify.
    private static func driveGeminiKeySection(outDir: String) {
        var keySource: SecretStore.Source?
        var written: [String] = []
        var deletes = 0
        var calls = 0
        let view = SetupSettingsView(width: 640, observer: { completion in
            calls += 1
            var observation = PreflightSelfTest.broken
            observation.webAnswerKeySource = keySource
            completion(observation)
        }, geminiKeyWriter: { value in
            written.append(value)
            // Stored for real, as far as this surface can tell: the next measurement finds a key, exactly as
            // it would after a real SecItemAdd.
            keySource = .keychain
            return errSecSuccess
        }, geminiKeyDeleter: {
            deletes += 1
            // Gone for real, as far as this surface can tell: the next measurement finds nothing, exactly as
            // it would after a real SecItemDelete on a machine with no override exported.
            keySource = nil
            return errSecSuccess
        })
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("[gemini] the section is on the Setup tab",
              find(GeminiKeySetup.cardIdentifier, in: view) != nil)
        assertGeminiCopy(view, status: .notStored, state: "no key")
        assertGeminiLayout(view, state: "no key")
        capture(view, card: GeminiKeySetup.cardIdentifier, to: outDir + "/setup-gemini-key.png",
                name: "gemini key section")

        guard let field = find(GeminiKeySetup.identifier(.field), in: view) as? NSTextField else {
            check("[gemini] the section offers a field to paste a key into", false)
            return
        }
        // Secure by type, not by a flag: an NSSecureTextField cannot be made to display what it holds.
        check("[gemini] the key is typed into a secure field", field is NSSecureTextField,
              String(describing: type(of: field)))
        check("[gemini] the empty field prompts for the key rather than showing anything",
              field.stringValue.isEmpty && !(field.placeholderString ?? "").isEmpty)

        guard let save = find(GeminiKeySetup.identifier(.save), in: view) as? NSButton else {
            check("[gemini] the section offers a Save button", false)
            return
        }

        // A blank Save must write NOTHING: an empty write would replace a working key with an empty one.
        save.performClick(nil)
        check("[gemini] saving an empty field writes nothing", written.isEmpty, "\(written.count) write(s)")
        check("[gemini] saving an empty field says so instead of claiming a save",
              label(GeminiKeySetup.identifier(.message), in: view)?.stringValue
                == GeminiKeySetup.message(.nothingEntered))
        check("[gemini] a blank save does not re-measure the tab", calls == 1, "calls=\(calls)")

        // The real path: a canary key pasted and saved.
        let canary = "AIzaSY-RENDER-CANARY-\(UUID().uuidString)"
        (find(GeminiKeySetup.identifier(.field), in: view) as? NSTextField)?.stringValue = canary
        (find(GeminiKeySetup.identifier(.save), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] the pasted key reaches the app's own keychain writer, once",
              written == [canary], "\(written.count) write(s)")
        check("[gemini] a stored key re-measures the tab rather than trusting the section's own write",
              calls == 2, "calls=\(calls)")
        check("[gemini] the field is cleared once the key is stored",
              (find(GeminiKeySetup.identifier(.field), in: view) as? NSTextField)?.stringValue.isEmpty
                == true)
        check("[gemini] the section confirms the save",
              label(GeminiKeySetup.identifier(.message), in: view)?.stringValue
                == GeminiKeySetup.message(.stored))
        assertGeminiCopy(view, status: .stored(.keychain), state: "stored")
        assertGeminiLayout(view, state: "stored")

        // The whole point of D7's never-echo rule, asserted over the ENTIRE tab rather than the one field:
        // no label, no tooltip, and no control title anywhere may carry the value.
        check("[gemini] nothing on the tab echoes the stored key", echoes(of: canary, in: view).isEmpty,
              echoes(of: canary, in: view).joined(separator: ","))

        // The preflight row below the section reads the SAME measurement, so it has to have gone green too.
        check("[gemini] the preflight key row agrees with the section after the save",
              keyRowStatus(in: view) == expectedKeyRowStatus(.keychain))

        capture(view, card: GeminiKeySetup.cardIdentifier, to: outDir + "/setup-gemini-saved.png",
                name: "gemini key section (stored)")

        // --- Deleting the stored key (L9) ---
        //
        // The product decision overrides the earlier "Replace only" design: a stored key can be replaced OR removed
        // in the app. What follows is the whole affordance driven through the real controls - the mis-click
        // guard, the cancel, the delete, and the re-measurement that keeps the section from claiming a
        // result it did not verify.
        check("[gemini] a stored key offers a way to delete it",
              find(GeminiKeySetup.identifier(.delete), in: view) != nil)
        check("[gemini] a stored key is not asked about until Delete is clicked",
              find(GeminiKeySetup.identifier(.deletePrompt), in: view) == nil
                && find(GeminiKeySetup.identifier(.deleteConfirm), in: view) == nil)

        // A single mis-click must not drop a working key.
        (find(GeminiKeySetup.identifier(.delete), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] one click on Delete asks rather than deleting",
              deletes == 0 && calls == 2, "\(deletes) delete(s), calls=\(calls)")
        check("[gemini] the confirmation says what it is about to do",
              label(GeminiKeySetup.identifier(.deletePrompt), in: view)?.stringValue
                == GeminiKeySetup.deletePrompt)
        check("[gemini] the key still reads as stored while the question is open",
              label(GeminiKeySetup.identifier(.status), in: view)?.stringValue
                == GeminiKeySetup.statusText(.stored(.keychain)))
        assertGeminiLayout(view, state: "delete confirm")
        capture(view, card: GeminiKeySetup.cardIdentifier,
                to: outDir + "/setup-gemini-delete-confirm.png", name: "gemini key section (confirm delete)")

        // Backing out leaves the key exactly where it was.
        (find(GeminiKeySetup.identifier(.deleteCancel), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] cancelling the confirmation deletes nothing and re-measures nothing",
              deletes == 0 && calls == 2, "\(deletes) delete(s), calls=\(calls)")
        check("[gemini] cancelling takes the question off screen and offers Delete again",
              find(GeminiKeySetup.identifier(.deletePrompt), in: view) == nil
                && find(GeminiKeySetup.identifier(.delete), in: view) != nil)
        assertGeminiCopy(view, status: .stored(.keychain), state: "cancelled")

        // The real path: ask, then answer.
        (find(GeminiKeySetup.identifier(.delete), in: view) as? NSButton)?.performClick(nil)
        (find(GeminiKeySetup.identifier(.deleteConfirm), in: view) as? NSButton)?.performClick(nil)
        check("[gemini] a confirmed delete reaches the app's own keychain delete, once",
              deletes == 1, "\(deletes) delete(s)")
        check("[gemini] a delete re-measures the tab rather than trusting the section's own delete",
              calls == 3, "calls=\(calls)")
        check("[gemini] the section reports the removal",
              label(GeminiKeySetup.identifier(.message), in: view)?.stringValue
                == GeminiKeySetup.message(.removed))
        assertGeminiCopy(view, status: .notStored, state: "deleted")
        assertGeminiLayout(view, state: "deleted")
        check("[gemini] a removed key leaves nothing to delete on screen",
              GeminiKeySetup.Part.allCases
                .filter { [.delete, .deletePrompt, .deleteConfirm, .deleteCancel].contains($0) }
                .allSatisfy { find(GeminiKeySetup.identifier($0), in: view) == nil })
        check("[gemini] the field is still offered after a delete, so a new key can be pasted in",
              find(GeminiKeySetup.identifier(.field), in: view) is NSSecureTextField)
        check("[gemini] nothing on the tab echoes the deleted key either",
              echoes(of: canary, in: view).isEmpty, echoes(of: canary, in: view).joined(separator: ","))

        // The row an inch below the section read the same measurement, so it has to have gone back to a
        // warning. This is the property that makes the delete honest: the section cannot report a feature
        // off while the preflight row says it is on, because neither of them decides.
        check("[gemini] the preflight key row agrees with the section after the delete",
              keyRowStatus(in: view) == expectedKeyRowStatus(nil))
        view.removeFromSuperview()

        driveGeminiEnvironmentState(outDir: outDir)
    }

    /// The state that made this affordance worth declining until it could be built honestly: a key arriving
    /// from `VIDDYDICTATE_GEMINI_API_KEY` rather than the keychain.
    ///
    /// `SecretStore` resolves keychain first, so this state means the keychain held NOTHING - a Delete
    /// button here would delete nothing, report success, and leave Option+G answering. The section offers no
    /// control at all and says so instead. That is asserted here rather than reasoned about, because "the
    /// button is not there" is exactly the kind of claim that rots silently.
    private static func driveGeminiEnvironmentState(outDir: String) {
        let view = SetupSettingsView(width: 640, observer: { completion in
            var observation = PreflightSelfTest.broken
            observation.webAnswerKeySource = .environment
            completion(observation)
        }, geminiKeyWriter: { _ in errSecSuccess },
           geminiKeyDeleter: {
            check("[gemini override] the section never reaches the keychain delete in this state", false)
            return errSecSuccess
        })
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        check("[gemini override] an override-sourced key offers no delete control",
              GeminiKeySetup.Part.allCases
                .filter { [.delete, .deletePrompt, .deleteConfirm, .deleteCancel].contains($0) }
                .allSatisfy { find(GeminiKeySetup.identifier($0), in: view) == nil })
        check("[gemini override] the section says why, in full, where the button would have been",
              label(GeminiKeySetup.identifier(.environmentNote), in: view)?.stringValue
                == GeminiKeySetup.environmentNote)
        check("[gemini override] the field is still offered, so a key can be stored properly",
              find(GeminiKeySetup.identifier(.field), in: view) is NSSecureTextField)
        assertGeminiCopy(view, status: .stored(.environment), state: "override")
        assertGeminiLayout(view, state: "override")
        capture(view, card: GeminiKeySetup.cardIdentifier,
                to: outDir + "/setup-gemini-environment.png", name: "gemini key section (override)")
        view.removeFromSuperview()
    }

    /// Every label, tooltip, and control title on the tab that carries `value`. Empty is the only passing
    /// answer; the identifiers come back so a failure names the surface that echoed rather than just saying
    /// that one did.
    private static func echoes(of value: String, in view: NSView) -> [String] {
        var found: [String] = []
        sweep(view) { subview in
            if let text = subview as? NSTextField, !(text is NSSecureTextField),
               text.stringValue.contains(value) {
                found.append("label:\(text.identifier?.rawValue ?? "?")")
            }
            if subview.toolTip?.contains(value) == true {
                found.append("tooltip:\(subview.identifier?.rawValue ?? "?")")
            }
            if let button = subview as? NSButton, button.title.contains(value) {
                found.append("button:\(button.identifier?.rawValue ?? "?")")
            }
        }
        return found
    }

    private static func keyRowStatus(in view: NSView) -> String? {
        label(PreflightSurface.identifier(.status, .webAnswerKey), in: view)?.stringValue
    }

    private static func expectedKeyRowStatus(_ source: SecretStore.Source?) -> String {
        var observation = PreflightSelfTest.broken
        observation.webAnswerKeySource = source
        return PreflightSurface.statusText(Preflight.evaluate(observation).finding(.webAnswerKey)!)
    }

    /// Every line the pure layer says the section shows, on screen and reading exactly what it says.
    private static func assertGeminiCopy(_ view: NSView, status: GeminiKeySetup.Status, state: String) {
        var wrong: [String] = []
        let expected: [(GeminiKeySetup.Part, String)] = [
            (.status, GeminiKeySetup.statusText(status)),
            (.headline, GeminiKeySetup.headline(status)),
            (.statusLine, GeminiKeySetup.statusLine(status)),
            (.turnsOn, GeminiKeySetup.turnsOn),
            (.instructions, GeminiKeySetup.instructions),
            (.agentHelp, GeminiKeySetup.agentHelp),
            (.fieldHint, GeminiKeySetup.fieldHint(status)),
            (.fallback, GeminiKeySetup.fallback),
        ]
        for (part, value) in expected
        where label(GeminiKeySetup.identifier(part), in: view)?.stringValue != value {
            wrong.append(part.rawValue)
        }
        check("[gemini \(state)] every line of the section is on screen and is the pure layer's own",
              wrong.isEmpty, wrong.joined(separator: ","))
        // The two facts a user cannot get anywhere else, held at the surface as well as in the pure gate.
        check("[gemini \(state)] the console URL is on screen",
              label(GeminiKeySetup.identifier(.instructions), in: view)?.stringValue
                .contains("https://aistudio.google.com/apikey") == true)
        check("[gemini \(state)] the shipped script is named on screen as the fallback",
              label(GeminiKeySetup.identifier(.fallback), in: view)?.stringValue
                .contains("./scripts/set-gemini-key.sh") == true)
    }

    /// The layout claims a screenshot cannot make for itself. The section is the tallest card on the tab and
    /// it holds a control, so a clipped line here would hide the URL or leave Save under the next section.
    private static func assertGeminiLayout(_ view: NSView, state: String) {
        guard let card = find(GeminiKeySetup.cardIdentifier, in: view) else {
            check("[gemini \(state)] the section has a card", false)
            return
        }
        var clipped: [String] = []
        // Controls are excluded: they are fixed-height by design, and the claim here is about text that has
        // to be READ in full. `Part.isControl` owns that split, so a control added later cannot red this.
        for part in GeminiKeySetup.Part.allCases where !part.isControl {
            guard let field = label(GeminiKeySetup.identifier(part), in: view) else { continue }
            let needed = field.sizeThatFits(
                NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
            if field.frame.height + 0.5 < needed { clipped.append(part.rawValue) }
        }
        check("[gemini \(state)] no line of the section is clipped by its own frame",
              clipped.isEmpty, clipped.joined(separator: ","))

        let contentBottom = card.subviews.map(\.frame.maxY).max() ?? 0
        check("[gemini \(state)] the card contains its own contents",
              card.frame.height + 0.5 >= contentBottom,
              "card=\(Int(card.frame.height)) content=\(Int(contentBottom))")
        check("[gemini \(state)] the tab is tall enough to scroll to the section",
              view.frame.height >= card.convert(card.bounds, to: view).maxY,
              "height=\(Int(view.frame.height)) card ends \(Int(card.convert(card.bounds, to: view).maxY))")

        // The field and the button share a row, so a width change on either would silently overlap them.
        if let field = find(GeminiKeySetup.identifier(.field), in: view),
           let save = find(GeminiKeySetup.identifier(.save), in: view) {
            check("[gemini \(state)] the field and Save do not overlap",
                  field.frame.maxX <= save.frame.minX + 0.5,
                  "field ends \(Int(field.frame.maxX)), Save starts \(Int(save.frame.minX))")
            check("[gemini \(state)] Save is inside the card",
                  save.frame.maxX <= card.bounds.maxX + 0.5)
        }

        // The confirmation's two buttons share a row the same way, and a destructive control half-outside
        // its card is how the wrong one gets clicked.
        if let confirm = find(GeminiKeySetup.identifier(.deleteConfirm), in: view),
           let cancel = find(GeminiKeySetup.identifier(.deleteCancel), in: view) {
            check("[gemini \(state)] Delete and Cancel do not overlap",
                  confirm.frame.maxX <= cancel.frame.minX + 0.5,
                  "Delete ends \(Int(confirm.frame.maxX)), Cancel starts \(Int(cancel.frame.minX))")
            check("[gemini \(state)] the confirmation's buttons are inside the card",
                  cancel.frame.maxX <= card.bounds.maxX + 0.5)
        }

        // The section must sit below the provider sign-in section, not on top of it (one document view).
        if let providerCard = find(ProviderOnboarding.cardIdentifier(.codex), in: view) {
            let provider = providerCard.convert(providerCard.bounds, to: view)
            let gemini = card.convert(card.bounds, to: view)
            check("[gemini \(state)] the section sits below the provider sign-in section",
                  gemini.minY >= provider.maxY - 0.5,
                  "provider ends \(Int(provider.maxY)), gemini starts \(Int(gemini.minY))")
        }
    }

    private static func sweep(_ root: NSView, _ visit: (NSView) -> Void) {
        visit(root)
        root.subviews.forEach { sweep($0, visit) }
    }

    /// Every row the report describes is on screen, headed by its own title, and reading exactly what the
    /// presentation layer says it should. This is the assertion that makes the PNG trustworthy: a capture
    /// alone cannot tell a correct row from a plausible one.
    private static func assertReport(_ view: NSView, _ report: PreflightReport, state: String) {
        check("[\(state)] the headline reports the count the report carries",
              label(PreflightSurface.headlineIdentifier, in: view)?.stringValue
                == PreflightSurface.headline(report))

        var wrong: [String] = []
        for finding in report.findings {
            let target = finding.check
            if label(PreflightSurface.identifier(.title, target), in: view)?.stringValue
                != target.title { wrong.append("\(target.rawValue).title") }
            if label(PreflightSurface.identifier(.status, target), in: view)?.stringValue
                != PreflightSurface.statusText(finding) { wrong.append("\(target.rawValue).status") }
            if label(PreflightSurface.identifier(.summary, target), in: view)?.stringValue
                != finding.summary { wrong.append("\(target.rawValue).summary") }
            // Present exactly when the finding has one: a passing row that rendered a "Fix:" line would be
            // as wrong as a warning row that dropped it.
            if label(PreflightSurface.identifier(.remedy, target), in: view)?.stringValue
                != PreflightSurface.remedyLine(finding) { wrong.append("\(target.rawValue).remedy") }
            if label(PreflightSurface.identifier(.reduced, target), in: view)?.stringValue
                != PreflightSurface.reducedLine(finding) { wrong.append("\(target.rawValue).reduced") }
        }
        check("[\(state)] every check is on screen and every line of it is the finding's own",
              wrong.isEmpty, wrong.joined(separator: ","))
        check("[\(state)] one card per check, none missing",
              PreflightCheck.allCases.allSatisfy {
                  find(PreflightSurface.cardIdentifier($0), in: view) != nil
              })
    }

    /// The layout claims a screenshot cannot make for itself: nothing is clipped, nothing overlaps, and the
    /// document view is tall enough to contain what it holds. The longest remedy here is a three-option menu
    /// that wraps to several lines, and a clipped remedy is not an actionable message.
    private static func assertLayout(_ view: NSView) {
        var clipped: [String] = []
        for target in PreflightCheck.allCases {
            for part in [PreflightSurface.RowPart.summary, .remedy, .reduced] {
                guard let field = label(PreflightSurface.identifier(part, target), in: view) else { continue }
                let needed = field.sizeThatFits(
                    NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
                if field.frame.height + 0.5 < needed {
                    clipped.append("\(target.rawValue).\(part.rawValue)")
                }
            }
        }
        check("no row's text is clipped by its own frame", clipped.isEmpty, clipped.joined(separator: ","))

        let cards = PreflightCheck.allCases
            .compactMap { find(PreflightSurface.cardIdentifier($0), in: view) }
            .sorted { $0.frame.minY < $1.frame.minY }
        var overlapping = false
        for (previous, next) in zip(cards, cards.dropFirst()) where next.frame.minY < previous.frame.maxY {
            overlapping = true
        }
        check("the rows do not overlap each other", !overlapping, "\(cards.count) cards")

        let deepest = cards.map(\.frame.maxY).max() ?? 0
        check("the surface is tall enough to scroll to its last row",
              view.frame.height >= deepest,
              "height=\(Int(view.frame.height)) last row ends \(Int(deepest))")

        for target in PreflightCheck.allCases {
            guard let card = find(PreflightSurface.cardIdentifier(target), in: view) else { continue }
            let contentBottom = card.subviews.map(\.frame.maxY).max() ?? 0
            if card.frame.height < contentBottom {
                check("card \(target.rawValue) contains its own contents", false,
                      "card=\(Int(card.frame.height)) content=\(Int(contentBottom))")
                return
            }
        }
        check("every card contains its own contents", true)
    }

    /// Render `card` (or the whole view) to PNG and assert it carries real pixels. The mechanics are shared
    /// with the other capture gates (`SelfTestRenderCapture`); this gate keeps only its own check accounting.
    private static func capture(_ view: NSView, card: String?, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: card, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }

    private static func label(_ id: String, in root: NSView) -> NSTextField? {
        SelfTestRenderCapture.label(id, in: root)
    }
}

/// An in-memory stand-in for LM Studio, so this gate can drive the live readout through every state -
/// loaded, empty, unreadable, and not-yet-answered - on a machine whose real LM Studio is holding whatever
/// it happens to be holding.
///
/// It also holds the answer BACK on demand. That is the only way to photograph the `pending` state, and
/// `pending` is the state that proves the section asks for a reading rather than blocking on the CLI:
/// production spends about 0.16s in `lms ps`, and doing that on the main thread is the 2026-07-13 freeze.
final class LocalResidencyStub {
    var reading: LocalModelsSectionView.ResidencyReading
    /// Every reading the section asked for, and every unload it performed.
    var readCalls = 0
    var unloadCalls = 0
    /// Readings taken after the first unload, which is what proves the button re-measures rather than
    /// believing its own request.
    var readCallsAfterUnload = 0
    /// While true, a request is recorded and parked instead of answered.
    var withholdsAnswer = false
    private var parked: ((LocalModelsSectionView.ResidencyReading) -> Void)?

    init(models: [ModelResidency.ResidentModel]?, wired: UInt64?) {
        reading = .init(models: models, wiredBytes: wired)
    }

    var reader: LocalModelsSectionView.ResidencyReader {
        { [self] completion in
            readCalls += 1
            if unloadCalls > 0 { readCallsAfterUnload += 1 }
            if withholdsAnswer { parked = completion; return }
            completion(reading)
        }
    }

    var unloader: LocalModelsSectionView.UnloadAll {
        { [self] completion in
            unloadCalls += 1
            completion()
        }
    }

    /// Answer a request that was parked while `withholdsAnswer` was set, the way a background queue
    /// completing would. Does nothing if nothing is parked.
    func deliverParked() {
        guard let parked = parked else { return }
        self.parked = nil
        parked(reading)
    }
}

/// An in-memory stand-in for `Settings`, so this gate can drag the budget slider across its whole range and
/// switch the idle timer without reaching the defaults of the app the user is running.
///
/// It is seeded from `Settings` rather than from a literal, so what the capture shows is still the SHIPPED
/// default rather than a number this file chose.
final class LocalModelStore {
    var position: Double
    var seconds: Int
    /// The Preferred local app; nil is Automatic. Never `Settings.preferredLocalBackend`.
    var preferred: LocalBackendID?

    init(position: Double, seconds: Int) {
        self.position = position
        self.seconds = seconds
    }

    var store: LocalModelsSectionView.Store {
        LocalModelsSectionView.Store(
            budgetPosition: { [self] in position },
            setBudgetPosition: { [self] in position = $0 },
            idleSeconds: { [self] in seconds },
            setIdleSeconds: { [self] in seconds = $0 },
            preferredBackend: { [self] in preferred },
            setPreferredBackend: { [self] in preferred = $0 })
    }
}
