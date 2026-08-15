import Cocoa

/// GUI-tier contract probe for U1. It instantiates the real AppKit settings controls against injected
/// scratch stores, exercises disclosure/provider/retry actions, and verifies Hotkeys no longer contains
/// model/prompt routing controls. No window is launched, no provider runs, and no live preference or
/// custom-mode file is read.
enum ModelsPowerUIProbe {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)")
        if !ok { failures += 1 }
    }

    static func run() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-models-power-ui-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            print("[models-power-ui-probe] scratch setup failed: \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("models-power.json"))
        let custom = CustomModeStore(url: root.appendingPathComponent("custom-modes.json"),
                                     routingStore: routing)
        let outcomeURL = root.appendingPathComponent("codex-outcome.json")
        let codexOutcome = CodexUpdateOutcomeStore(url: outcomeURL)
        let catalog = CodexModelCatalogCache(
            checkedAt: "2026-07-27T12:00:00Z",
            catalog: ModelCatalog(
                rows: [
                    row(
                        id: "preset-id-not-executable",
                        model: "future/model-exec",
                        displayName: "Future Display Label",
                        hidden: false,
                        efforts: ["wild effort", "x/y"]),
                    row(
                        id: "retired-preset",
                        model: "retired-hidden-model",
                        displayName: "Must Stay Hidden",
                        hidden: true,
                        efforts: ["low"]),
                ],
                pageMetadata: []))
        let customMode = CustomMode(
            id: "probe-custom", name: "Polish quote",
            chord: .regular(keyCode: 8, label: "C"), prompt: "Polish the selected quote.",
            input: .selection,
            model: LLMProviderDefaults.testedBundle(for: .local, route: .custom("probe-custom"))!,
            landing: .inPlace)
        do { try custom.upsert(customMode) }
        catch {
            print("[models-power-ui-probe] custom setup failed: \(error.localizedDescription)")
            return false
        }

        let view = ModelsPowerSettingsView(
            width: 640,
            settingsStore: routing,
            customStore: custom,
            codexOutcomeStore: codexOutcome,
            codexCatalogLoader: { catalog })
        let powerView = PowerSettingsView(width: 640)
        checkPowerStructureAndCallbacks(powerView)
        checkStructure(view)
        checkAdvancedCleanup(view)
        checkAdvancedPromptPrepAndCustom(view)
        checkDisconnectedSelection(view, routing: routing)
        checkCodexDefaultActions(view, routing: routing)
        checkDynamicCodexPicker(
            view,
            routing: routing,
            custom: custom,
            outcome: codexOutcome)
        checkCodexOutcomeRefresh(
            view, store: codexOutcome, outcomeURL: outcomeURL)
        checkMixedAndPromptState(view, routing: routing)
        checkPromptResetControl(view, routing: routing)
        checkProvenanceFoldsEveryPromptVariant(view, routing: routing)
        checkPromptEditorRestore(view, routing: routing)
        checkPromptWorkstation(view, custom: custom, mode: customMode)
        checkPromptTestBench(custom: custom, mode: customMode)
        checkRetry(view)
        checkMergedHotkeysTab(root: root)
        checkHotkeysToggleableCheckboxes(root: root)
        checkDeviceCodeIsRenderable()
        checkClaudeSignInCountdownIsRenderable()

        print("[models-power-ui-probe] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    /// The Connect flow's one-time code arrives AFTER its sheet is already on screen. An `NSAlert`
    /// freezes its layout when presented, so a code delivered through `informativeText` is silently
    /// clipped and the user sees a verification page with nothing to type. The code therefore lives in
    /// a fixed-size accessory field, and the contract that matters is that the field is already big
    /// enough for a code before any code exists. "It fits" is the assertion, because "it did not fit"
    /// was the defect.
    private static func checkDeviceCodeIsRenderable() {
        let field = CodexDeviceCodePresentation.makeCodeField()
        check("device-code field renders its placeholder inside its own frame",
              CodexDeviceCodePresentation.textFits(field))
        check("device-code field is selectable so the code can be copied rather than retyped",
              field.isSelectable)

        // Real shapes the vendor has issued, plus generous headroom on both group lengths.
        for code in ["ABCD-EFGH", "Y8OL-V15MK", "ABCDEFGH-IJKLMNOP"] {
            field.stringValue = code
            check("device-code field renders a \(code.count)-character code inside its own frame",
                  CodexDeviceCodePresentation.textFits(field))
            check("device-code field actually adopts the delivered code",
                  field.stringValue == code)
        }

        field.stringValue = CodexDeviceCodePresentation.noCodeText
        check("the no-code fallback also renders inside the field's frame",
              CodexDeviceCodePresentation.textFits(field))
    }

    /// The Claude sign-in flow's countdown is the same class of defect as the device code: it arrives every
    /// two seconds while its sheet is already on screen, so it lives in a pre-sized accessory field rather
    /// than in `informativeText`, which an `NSAlert` will not re-lay-out. The contract is that the field is
    /// already wide enough for the LONGEST countdown before the first one exists.
    private static func checkClaudeSignInCountdownIsRenderable() {
        let field = ClaudeSignInWaitPresentation.makeStatusField()
        check("Claude wait field renders its placeholder inside its own frame",
              ClaudeSignInWaitPresentation.textFits(field))
        check("Claude wait field starts on the placeholder, not on a fabricated countdown",
              field.stringValue == ClaudeConnectionFlow.awaitingFieldText)

        // The bound itself, one second in, a minute-boundary value, and the last tick.
        for remaining in [ClaudeConnectionFlow.defaultPolling.deadline, 899, 600, 61, 9, 0] {
            field.stringValue = ClaudeConnectionFlow.waitingFieldText(remaining: remaining)
            check("Claude wait field renders \(field.stringValue) inside its own frame",
                  ClaudeSignInWaitPresentation.textFits(field))
        }
    }

    private static func checkStructure(_ view: ModelsPowerSettingsView) {
        check("combined Models & Power heading",
              texts(in: view).contains("Models")
                && !texts(in: view).contains("Models & Power"))
        check("routing surface no longer owns the Power Mode control", find("power-mode", in: view) == nil)
        for provider in LLMProvider.allCases {
            check("\(provider.rawValue) availability state", find("availability|\(provider.rawValue)", in: view) != nil)
            check("\(provider.rawValue) global action", find("bulk|\(provider.rawValue)", in: view) is NSButton)
        }
        // L4 moved every provider connect button to the Setup tab. This surface points at it instead - and
        // the pointer took a button's place in a hand-laid-out card, so it has to be readable and has to
        // clear its neighbours. It is a truncating single-line label, which fails silently by design.
        let pointer = find("provider-signin-pointer", in: view) as? NSTextField
        check("provider sign-in pointer to the Setup tab", pointer != nil)
        if let pointer = pointer, let card = find("card.providers", in: view) {
            let needed = pointer.sizeThatFits(
                NSSize(width: .greatestFiniteMagnitude, height: pointer.frame.height)).width
            check("the sign-in pointer is not truncated by its own frame",
                  needed <= pointer.frame.width + 0.5)
            check("the sign-in pointer does not land on top of another control",
                  card.subviews.allSatisfy { $0 === pointer || !$0.frame.intersects(pointer.frame) })
        }
        check("derived global provider state", find("bulk-derived-state", in: view) is NSTextField)
        check("Codex global action declares the shipped unratified Cleanup replacement",
              (find("bulk|codex", in: view) as? NSButton)?.toolTip?.contains(
                "Cleanup is auto-updated and unratified") == true)

        let cardIDs = [
            "card.cleanup", "card.promptPrep", "card.email", "card.searchLocalSynth",
            "card.searchGeminiSynth", "card.custom:probe-custom",
        ]
        for id in cardIDs { check("route card \(id)", find(id, in: view) != nil) }
        check("Option+L retrieval stays visibly fixed",
              texts(in: view).contains { $0.contains("local web-search pipeline (fixed)") })
        check("Option+G retrieval stays visibly fixed",
              texts(in: view).contains { $0.contains("Gemini grounding (fixed)") })
        let emailProvider = find("provider|email", in: view) as? NSPopUpButton
        check("per-route provider control", emailProvider != nil)
        check("email exposes Codex as a complete tested default",
              emailProvider?.itemArray.first(where: {
                  ($0.representedObject as? String) == "codex"
              })?.title == "Codex")
        check("per-route model control", find("model|email", in: view) is NSPopUpButton)
        check("per-route effort control", find("effort|email", in: view) is NSPopUpButton)
        check("prompt state is visible", find("prompt-summary|email", in: view) is NSTextField)
        let retry = find("retry|email", in: view) as? NSButton
        check("retry affordance is present and failure-gated", retry != nil && retry?.isEnabled == false)
        check("collapsed cards keep every control inside their bounds", cardsHaveNoOverflow(view))
    }

    private static func checkPowerStructureAndCallbacks(_ view: PowerSettingsView) {
        check("Display power card", find("card.power", in: view) != nil)
        guard let segmented = find("power-mode", in: view) as? NSSegmentedControl else {
            check("manual Live / Final-only control", false)
            check("power callback fires exactly once", false)
            return
        }
        check("manual Live / Final-only control", true)
        check("battery advisory surface", find("battery-advisory", in: view) is NSTextField)

        let originalMode = Settings.powerMode
        defer { Settings.powerMode = originalMode }
        var callbackCount = 0
        view.onPowerModeChanged = { callbackCount += 1 }
        segmented.selectedSegment = originalMode == .live ? 1 : 0
        _ = segmented.sendAction(segmented.action, to: segmented.target)
        check("power action flips Settings.powerMode",
              Settings.powerMode == (originalMode == .live ? .finalOnly : .live))
        check("power callback fires exactly once", callbackCount == 1)

        Settings.powerMode = .live
        callbackCount = 0
        let sentBatteryAction = NSApp.sendAction(NSSelectorFromString("useFinalOnly"),
                                                 to: view, from: nil)
        check("battery action selects Final-only",
              sentBatteryAction && Settings.powerMode == .finalOnly)
        check("battery action callback fires exactly once", callbackCount == 1)

        // The Appearance tab owns this view's placement (it sits below the HUD block), so a rebuild must
        // resize without moving. Every refresh() -- show(), the menubar toggle, any mode change --
        // would otherwise stack the card back on top of the HUD controls.
        let ownerOrigin = NSPoint(x: 0, y: 116)
        view.frame.origin = ownerOrigin
        view.refresh()
        check("refresh keeps the owner-assigned origin", view.frame.origin == ownerOrigin)
    }

    private static func checkAdvancedCleanup(_ view: ModelsPowerSettingsView) {
        guard let advanced = find("advanced|cleanup", in: view) as? NSButton else {
            check("Cleanup Advanced disclosure", false)
            return
        }
        advanced.performClick(nil)
        for route in [LLMRouteID.cleanupL1, .cleanupL2, .cleanupL3] {
            check("\(route.rawValue) advanced model", find("model|\(route.rawValue)", in: view) is NSPopUpButton)
            check("\(route.rawValue) advanced effort", find("effort|\(route.rawValue)", in: view) is NSPopUpButton)
            check("\(route.rawValue) custom model escape hatch",
                  find("custom-model|\(route.rawValue)", in: view) is NSTextField)
            check("\(route.rawValue) prompt editor",
                  allViews(in: view).contains { $0.identifier?.rawValue.hasPrefix("edit-prompt|\(route.rawValue)|") == true })
        }
        for provider in LLMProvider.allCases {
            let restore = find("restore|cleanup|\(provider.rawValue)", in: view) as? NSButton
            check("Restore \(provider.rawValue) default button", restore != nil)
            if provider == .codex {
                check("Cleanup Codex Restore is enabled for all three shipped strengths",
                      restore?.isEnabled == true)
                check("Cleanup Codex Restore no longer reports a skipped strength",
                      restore?.toolTip == nil)
            }
        }
        check("expanded Cleanup keeps every control inside its card", cardsHaveNoOverflow(view))
    }

    /// D6, and the half of L4 this tab keeps: the inline rescue. Picking a disconnected provider for a route
    /// does not change the route; it opens the shared connect flow for THAT provider. It used to be
    /// hardcoded to Codex, so a user who picked a disconnected Claude got a refusal and no way forward.
    private static func checkDisconnectedSelection(_ view: ModelsPowerSettingsView,
                                                    routing: ModelsPowerSettingsStore) {
        var opened: [LLMProvider] = []
        view.onConnectProvider = { opened.append($0) }

        // L4: the Connect/Reconnect button MOVED to the Setup tab. Not a copy of it - it is gone from here,
        // because two buttons for one outcome are how the two start behaving differently.
        check("the Models tab hosts no provider connect button of its own",
              allViews(in: view).allSatisfy {
                  $0.identifier?.rawValue.hasPrefix("connect|") != true
              })
        check("the Models tab says where signing in lives now",
              (find("provider-signin-pointer", in: view) as? NSTextField)?
                .stringValue.contains("Setup tab") == true)

        for provider in [LLMProvider.codex, .claude] {
            routing.setAvailabilityState(.disconnected, for: provider)
            view.refresh()
            guard let popup = find("provider|email", in: view) as? NSPopUpButton,
                  let item = popup.itemArray.first(where: {
                      ($0.representedObject as? String) == provider.rawValue
                  }) else {
                check("disconnected \(provider.rawValue) selection opens its own connect flow", false)
                continue
            }
            let before = opened.count
            popup.select(item)
            _ = popup.sendAction(popup.action, to: popup.target)
            check("disconnected \(provider.rawValue) selection opens its own connect flow",
                  opened.count == before + 1 && opened.last == provider)
            check("disconnected \(provider.rawValue) selection does not mutate the route",
                  routing.selectedBundle(for: .email).provider == .local)
            check("the rescue says what it opened and that the route is unchanged",
                  (find("models-power-status", in: view) as? NSTextField)?.stringValue
                    == ModelsPowerSettingsView.inlineRescueStatus(for: provider))
        }
        check("the rescue entered the one shared flow once per pick, for the provider that was picked",
              opened == [.codex, .claude])

        // Positive control, so the two checks above mean "because it was disconnected" rather than "on any
        // pick at all": connected, the same gesture routes the route and opens nothing.
        for provider in [LLMProvider.codex, .claude] {
            routing.setAvailabilityState(.available, for: provider)
        }
        view.refresh()
        if let popup = find("provider|email", in: view) as? NSPopUpButton,
           let codex = popup.itemArray.first(where: { ($0.representedObject as? String) == "codex" }) {
            popup.select(codex)
            _ = popup.sendAction(popup.action, to: popup.target)
            check("a connected provider is applied to the route and opens no connect flow",
                  routing.selectedBundle(for: .email).provider == .codex && opened.count == 2)
        } else {
            check("a connected provider is applied to the route and opens no connect flow", false)
        }
    }

    private static func checkAdvancedPromptPrepAndCustom(_ view: ModelsPowerSettingsView) {
        (find("advanced|promptPrep", in: view) as? NSButton)?.performClick(nil)
        for variant in [LLMPromptVariant.cleanupL1, .cleanupL2, .cleanupL3] {
            check("Option+P \(variant.rawValue) prompt state",
                  allViews(in: view).contains {
                      $0.identifier?.rawValue.hasPrefix("prompt-state|promptPrep|") == true
                        && $0.identifier?.rawValue.hasSuffix("|\(variant.rawValue)") == true
                  })
        }
        check("prompt prep Codex Restore is enabled with the rescue default",
              (find("restore|promptPrep|codex", in: view) as? NSButton)?.isEnabled == true)
        (find("advanced|custom:probe-custom", in: view) as? NSButton)?.performClick(nil)
        check("custom route model escape hatch", find("custom-model|custom:probe-custom", in: view) is NSTextField)
        check("custom route effort escape hatch", find("custom-effort|custom:probe-custom", in: view) is NSTextField)
        check("custom route shared prompt editor", find("edit-custom-prompt|probe-custom", in: view) is NSButton)
        check("custom route Codex Restore is enabled with the ratified bundle",
              (find("restore|custom:probe-custom|codex", in: view) as? NSButton)?.isEnabled == true)
        check("all expanded route cards keep controls inside bounds", cardsHaveNoOverflow(view))
    }

    private static func checkCodexDefaultActions(_ view: ModelsPowerSettingsView,
                                                  routing: ModelsPowerSettingsStore) {
        (find("bulk|codex", in: view) as? NSButton)?.performClick(nil)
        let installed = LLMRouteID.builtIns + [LLMRouteID.custom("probe-custom")]
        check("Codex global button installs all eight shipped route defaults",
              installed.allSatisfy {
                  routing.selectedBundle(for: $0)
                    == LLMProviderDefaults.testedBundle(for: .codex, route: $0)
              })
        check("Codex global button reports a complete all-route application",
              (find("models-power-status", in: view) as? NSTextField)?.stringValue
                .contains("All provider-capable routes") == true)
    }

    private static func checkDynamicCodexPicker(
        _ view: ModelsPowerSettingsView,
        routing: ModelsPowerSettingsStore,
        custom: CustomModeStore,
        outcome: CodexUpdateOutcomeStore
    ) {
        guard let popup = find("model|email", in: view) as? NSPopUpButton,
              let executable = popup.itemArray.first(where: {
                  ($0.representedObject as? String) == "future/model-exec"
              }) else {
            check("visible last-known-good Codex row appears in the model picker", false)
            return
        }
        check("display name is label-only and the represented value is exact row.model",
              executable.title.contains("Future Display Label")
                && executable.title.contains("future/model-exec")
                && executable.representedObject as? String == "future/model-exec")
        check("hidden catalog rows never enter the picker",
              !popup.itemArray.contains {
                  ($0.representedObject as? String) == "retired-hidden-model"
              })
        popup.select(executable)
        _ = popup.sendAction(popup.action, to: popup.target)
        check("id != model selection persists and dispatches the exact executable row.model",
              routing.selectedBundle(for: .email).modelID == "future/model-exec"
                && routing.selectedBundle(for: .email).modelID
                    != "preset-id-not-executable")

        guard let effort = find("effort|email", in: view) as? NSPopUpButton else {
            check("selected catalog model exposes advertised effort strings", false)
            return
        }
        let represented = effort.itemArray.compactMap {
            $0.representedObject as? String
        }
        // effortPopup appends a persisted effort the catalog does not advertise so an
        // open-string value a user already saved is never silently dropped. Derive that
        // tail from the live bundle instead of hard-coding the shipped default's effort.
        let persistedEffort = routing.selectedBundle(for: .email).effort ?? ""
        let advertisedEfforts = ["", "wild effort", "x/y"]
        let expectedEfforts = advertisedEfforts.contains(persistedEffort)
            ? advertisedEfforts
            : advertisedEfforts + [persistedEffort]
        check("selected catalog model exposes advertised effort strings in exact order, "
                + "then any persisted escape hatch",
              represented == expectedEfforts)
        if let opaqueEffort = effort.itemArray.first(where: {
            ($0.representedObject as? String) == "x/y"
        }) {
            effort.select(opaqueEffort)
            _ = effort.sendAction(effort.action, to: effort.target)
        }
        check("advertised effort persistence is exact and remains an open string",
              routing.selectedBundle(for: .email).effort == "x/y")
        (find("advanced|email", in: view) as? NSButton)?.performClick(nil)
        check("the advanced custom-id escape hatch remains present with catalog data",
              find("custom-model|email", in: view) is NSTextField)

        let offline = ModelsPowerSettingsView(
            width: 640,
            settingsStore: routing,
            customStore: custom,
            codexOutcomeStore: outcome,
            codexCatalogLoader: { nil })
        let offlineModels = (find("model|email", in: offline) as? NSPopUpButton)?
            .itemArray.compactMap { $0.representedObject as? String } ?? []
        let offlineEfforts = (find("effort|email", in: offline) as? NSPopUpButton)?
            .itemArray.compactMap { $0.representedObject as? String } ?? []
        check("offline picker keeps the persisted custom model and effort escape hatches",
              offlineModels.contains("future/model-exec")
                && offlineEfforts.contains("x/y"))
    }

    private static func checkCodexOutcomeRefresh(
        _ view: ModelsPowerSettingsView,
        store: CodexUpdateOutcomeStore,
        outcomeURL: URL
    ) {
        store.beginAttempt(
            at: "2026-07-27T12:01:00Z",
            nextRetry: "2026-07-27T12:06:00Z")
        store.markCompatibilityQuarantinePending(
            at: "2026-07-27T12:01:01Z")
        check("an already-open settings view refreshes to compatibility-pending status",
              (find("codex-update-status", in: view) as? NSTextField)?
                .stringValue.contains("compatibility quarantine pending") == true)
        let outcome = CodexModelUpdateOutcome(
            status: .current,
            checkedAt: "2026-07-27T12:02:00Z",
            applied: [],
            skipped: [],
            held: [],
            recommendations: [],
            plannerHolds: [:])
        store.complete(outcome, nextRetry: "2026-07-27T18:02:00Z")
        check("the same open settings view refreshes after a completed check",
              (find("codex-update-status", in: view) as? NSTextField)?
                .stringValue.contains("routes unchanged") == true)
        check("outcome status reloads after a simulated app relaunch",
              CodexUpdateOutcomeStore(url: outcomeURL).latest == store.latest)
    }

    private static func checkMixedAndPromptState(_ view: ModelsPowerSettingsView,
                                                 routing: ModelsPowerSettingsStore) {
        do {
            try routing.selectProvider(.claude, for: .email)
            try routing.setPromptOverride("probe customized prompt", for: .email, provider: .claude)
        } catch {
            check("scratch Mixed/customized setup", false)
            return
        }
        view.refresh()
        check("Mixed remains derived/display-only",
              (find("bulk-derived-state", in: view) as? NSTextField)?.stringValue == "All routes: Mixed")
        check("Customized prompt state is visible",
              (find("prompt-summary|email", in: view) as? NSTextField)?.stringValue == "Prompt: Customized")
    }

    /// P10: resetting a prompt is prompt-only. "Restore <provider> default" reinstalls the whole tested
    /// bundle and selects that provider; a user who only retuned wording must be able to undo exactly that,
    /// so the model/effort comparison below is the assertion that matters, not the state label.
    private static func checkPromptResetControl(_ view: ModelsPowerSettingsView,
                                                routing: ModelsPowerSettingsStore) {
        // Give the pinned provider a model/effort that is NOT its shipped default first. Without that, a
        // whole-bundle restore and a prompt-only delete leave identical state and the assertion below
        // cannot tell them apart.
        var custom = routing.selectedBundle(for: .email)
        custom.modelID = "probe-reset-model"
        custom.effort = "high"
        do { try routing.setSelectedBundle(custom, for: .email) }
        catch {
            check("prompt reset scratch setup", false)
            return
        }
        let id = "reset-prompt|email|claude|primary"
        guard let reset = find(id, in: view) as? NSButton else {
            check("customized prompt exposes a Reset prompt control", false)
            return
        }
        check("customized prompt exposes a Reset prompt control", true)
        check("Reset prompt is enabled only while an override exists", reset.isEnabled)
        check("the prompt row names the provider whose overlay it edits",
              (find("prompt-state|email|claude|primary", in: view) as? NSTextField)?
                .stringValue.contains("Claude") == true)

        // P11: the provenance row reads the store's DERIVED verdict, not just the bundle's own badge. The
        // badge cannot see a prompt override, so before this the row kept its green RATIFIED line while the
        // store already considered the slate uncovered. This drives the whole wiring - override, per-variant
        // fold, row text - rather than the pure composition the freshness gate covers.
        let overriddenRow = (find("provenance|email", in: view) as? NSTextField)?.stringValue ?? ""
        check("an overridden prompt turns the route's provenance row unratified",
              overriddenRow.hasPrefix("Claude preset: UNRATIFIED"))
        check("the provenance row names the prompt edit as the reason",
              overriddenRow.contains(CloudUpdateSurface.unratifiedReasonText(.promptOverridden)))

        let before = routing.selectedBundle(for: .email)
        reset.performClick(nil)
        check("clearing the override drops the prompt-edit reason from the provenance row",
              (find("provenance|email", in: view) as? NSTextField)?.stringValue
                .contains(CloudUpdateSurface.unratifiedReasonText(.promptOverridden)) == false)
        check("Reset prompt deletes the overlay entry",
              routing.promptCustomizationState(for: .email, provider: .claude) == .testedDefault)
        check("Reset prompt runs the bytes this build ships",
              routing.effectivePrompt(for: .email, provider: .claude)
                == routing.factoryPrompt(for: .email, provider: .claude))
        check("Reset prompt leaves model, effort, and provider byte-identical",
              routing.selectedBundle(for: .email) == before)
        check("Reset prompt reports that it touched only the prompt",
              (find("models-power-status", in: view) as? NSTextField)?
                .stringValue.contains("Model and effort unchanged") == true)
        check("Reset prompt disables itself once there is nothing to reset",
              (find(id, in: view) as? NSButton)?.isEnabled == false)
        check("the reset row still keeps every control inside its card", cardsHaveNoOverflow(view))
    }

    /// Option+P is the one route carrying three prompt variants, so it is the only one that can prove the
    /// row's verdict is a fold rather than a read of the first variant. Editing Tighten alone has to mark the
    /// route, because Tighten is what runs when the user picks Tighten.
    private static func checkProvenanceFoldsEveryPromptVariant(_ view: ModelsPowerSettingsView,
                                                               routing: ModelsPowerSettingsStore) {
        // The row describes the selected provider only. Overriding another provider's prompt would correctly
        // leave it alone, so the probe targets the provider that will actually run.
        let displayed = routing.selectedBundle(for: .promptPrep).provider
        let clean = (find("provenance|promptPrep", in: view) as? NSTextField)?.stringValue ?? ""
        check("Option+P provenance names the selected provider",
              clean.hasPrefix("\(ModelsPowerSettingsView.displayName(for: displayed)) preset: "))
        check("Option+P starts with no prompt-edit objection",
              !clean.contains(CloudUpdateSurface.unratifiedReasonText(.promptOverridden)))
        do {
            try routing.setPromptOverride("probe tighten prompt", for: .promptPrep,
                                          provider: displayed, variant: .cleanupL2)
        } catch {
            check("prompt-variant fold scratch setup", false)
            return
        }
        check("editing one of Option+P's three prompts marks the route unratified",
              (find("provenance|promptPrep", in: view) as? NSTextField)?.stringValue
                .contains(CloudUpdateSurface.unratifiedReasonText(.promptOverridden)) == true)
        do {
            try routing.setPromptOverride(nil, for: .promptPrep, provider: displayed, variant: .cleanupL2)
        } catch {
            check("prompt-variant fold teardown", false)
        }
    }

    /// The editor's own Restore control: it SHOWS the shipped bytes rather than requiring the user to
    /// blank the field and trust that empty means default, and saving them clears the override because the
    /// store treats shipped-identical text as no override.
    private static func checkPromptEditorRestore(_ view: ModelsPowerSettingsView,
                                                 routing: ModelsPowerSettingsStore) {
        let shipped = routing.factoryPrompt(for: .email, provider: .claude)
        do { try routing.setPromptOverride("probe editor prompt", for: .email, provider: .claude) }
        catch {
            check("editor restore scratch setup", false)
            return
        }
        var saved: String?
        let sheet = PromptEditorSheet.makeForTesting(
            title: "Claude · Email (Option+M) · Email",
            text: routing.effectivePrompt(for: .email, provider: .claude),
            shippedDefault: shipped,
            onSave: { saved = $0 })
        let root = sheet.contentViewForTesting
        check("the editor opens on the text that actually runs",
              sheet.editorTextForTesting == "probe editor prompt")
        guard let restore = find("prompt-editor-restore", in: root) as? NSButton else {
            check("the editor exposes Restore shipped default", false)
            return
        }
        check("the editor exposes Restore shipped default", restore.isEnabled)
        restore.performClick(nil)
        check("Restore shows the shipped bytes without saving them",
              sheet.editorTextForTesting == shipped
                && routing.promptCustomizationState(for: .email, provider: .claude) == .customized)
        check("Restore disables itself once the editor holds the shipped bytes", !restore.isEnabled)
        (find("prompt-editor-save", in: root) as? NSButton)?.performClick(nil)
        check("saving the restored bytes hands them back verbatim", saved == shipped)
        // The same handler the presented sheet calls, so this is the production save path, not a copy of it.
        if let saved = saved {
            view.applyPromptEdit(saved, route: .email, provider: .claude, variant: .primary)
        }
        check("saving the shipped bytes clears the override rather than storing a copy",
              routing.promptCustomizationState(for: .email, provider: .claude) == .testedDefault)

        // S8: an existing custom mode opts in only after Restore default and Save. Opening the editor and
        // pressing Restore alone do not touch its stored prompt.
        var savedCustom: String?
        let custom = PromptEditorSheet.makeForTesting(
            title: "Polish quote · Shared task prompt", text: "Polish the selected quote.",
            shippedDefault: defaultCustomModeTaskPrompt,
            restoreButtonTitle: "Restore default",
            onSave: { savedCustom = $0 })
        guard let customRestore = find(
            "prompt-editor-restore", in: custom.contentViewForTesting) as? NSButton else {
            check("a custom task prompt exposes Restore default", false)
            return
        }
        check("a custom task prompt exposes Restore default",
              customRestore.title == "Restore default" && customRestore.isEnabled)
        customRestore.performClick(nil)
        check("custom Restore loads the new-mode default without saving",
              custom.editorTextForTesting == defaultCustomModeTaskPrompt && savedCustom == nil)
        (find("prompt-editor-save", in: custom.contentViewForTesting) as? NSButton)?
            .performClick(nil)
        check("custom Restore saves the locked default only after explicit Save",
              savedCustom == defaultCustomModeTaskPrompt)
    }

    /// W1, the prompt workstation. The Edit-task-prompt panel renders the ASSEMBLED prompt, so the two
    /// things worth gating are that the composition on screen is the one a run would send, and that the
    /// scaffold travels in one direction only: the marker text is drawn, never saved.
    ///
    /// The byte-identity check is the one no visual inspection could catch. Opening the panel on one of
    /// the user's existing hotkeys and saving without typing has to leave its stored prompt untouched; a panel
    /// that folded its scaffold into the saved bytes would rewrite every custom mode it was opened on.
    private static func checkPromptWorkstation(_ view: ModelsPowerSettingsView,
                                               custom: CustomModeStore, mode: CustomMode) {
        let stored = mode.prompt
        var saved: String?
        let sheet = PromptEditorSheet.customModeWorkstation(
            title: ModelsPowerSettingsView.customPromptTitle(for: mode),
            mode: mode, onSave: { saved = $0 })
        let root = sheet.contentViewForTesting

        check("the workstation opens on the bytes the mode actually stores",
              sheet.editorTextForTesting == stored)

        // Read the composition back out of the live views, in visual order, and compare it to what the
        // runtime would send. This is the anti-drift gate: a hand-written copy of the marker format
        // would satisfy a marker-spotting check and fail this one the moment the assembly moved.
        guard let displayed = sheet.displayedAssemblyForTesting else {
            check("the workstation renders an assembled composition", false)
            return
        }
        check("what the panel shows IS the system message a run sends",
              displayed.system == CustomModeClient.systemPrompt(for: mode))
        check("what the panel shows IS the user message a run sends",
              displayed.user == CleanupClient.wrap(PromptAssembly.defaultTranscriptPlaceholder))
        check("the marker block is shown verbatim, both ends",
              displayed.user.contains(transcriptStartMarker)
                && displayed.user.contains(transcriptEndMarker))
        check("the transcript placeholder sits between the markers",
              (find("prompt-editor-transcript-placeholder", in: root) as? NSTextField)?.stringValue
                == PromptAssembly.defaultTranscriptPlaceholder)
        check("the panel states that the composition is what gets sent",
              (find("prompt-editor-assembly-note", in: root) as? NSTextField)?.stringValue
                == PromptEditorSheet.assemblyNote)

        // Show-and-teach: the editable region stays fully editable, and the scaffold around it is
        // display text the user cannot type into and Save cannot pick up.
        guard let editor = find("prompt-editor-text", in: root) as? NSTextView else {
            check("the workstation exposes its editable region", false)
            return
        }
        check("the editable region stays fully editable", editor.isEditable && editor.isSelectable)
        check("the editable region holds the stored prompt and nothing the app added",
              editor.string == stored)
        let scaffold = allViews(in: root).compactMap { $0 as? NSTextField }
            .filter { $0.identifier?.rawValue.hasPrefix("prompt-editor-scaffold-") == true }
        check("the scaffold is presentation: shown, selectable, never editable",
              !scaffold.isEmpty && scaffold.allSatisfy { !$0.isEditable && $0.isSelectable })

        // Restore stays reachable in every state: it sits in the fixed footer rather than in the
        // scrolling composition, and it comes back after a restore-then-edit.
        guard let restore = find("prompt-editor-restore", in: root) as? NSButton else {
            check("the workstation keeps Restore default", false)
            return
        }
        check("the workstation keeps Restore default, enabled on a customized prompt",
              restore.title == "Restore default" && restore.isEnabled)
        check("Restore cannot scroll out of reach", !isInsideScrollView(restore))
        restore.performClick(nil)
        check("Restore loads the new-mode default without saving it",
              sheet.editorTextForTesting == defaultCustomModeTaskPrompt && saved == nil
                && custom.mode(id: mode.id)?.prompt == stored)
        check("Restore disables itself once the editor holds the default", !restore.isEnabled)
        editor.insertText(" One more sentence.",
                          replacementRange: NSRange(location: editor.string.count, length: 0))
        check("Restore comes back the moment the prompt diverges again", restore.isEnabled)

        // The round trip that matters: reopen on the untouched mode, save without typing, and drive the
        // result through the production apply path.
        var untouched: String?
        let reopened = PromptEditorSheet.customModeWorkstation(
            title: ModelsPowerSettingsView.customPromptTitle(for: mode),
            mode: mode, onSave: { untouched = $0 })
        (find("prompt-editor-save", in: reopened.contentViewForTesting) as? NSButton)?.performClick(nil)
        check("saving with no edit hands back the stored bytes verbatim", untouched == stored)
        view.applyCustomPromptEdit(untouched ?? "", id: mode.id)
        check("opening and saving an existing hotkey leaves its prompt byte-identical",
              custom.mode(id: mode.id)?.prompt == stored)
    }

    /// W2, the Test bench. Driven through the REAL Test button on the REAL sheet, with the provider call
    /// stubbed - the only thing a probe cannot do is run a model, so that seam and only that seam is
    /// injected, and the sheet the production presenter builds is separately asserted to use the real
    /// `CustomModeClient.run`.
    ///
    /// **The negative is the point.** A leaking Test looks identical to an inert one from the output
    /// field, so the assertions that carry weight are the ones about what did NOT happen: no History
    /// entry in either store, no clipboard write, no write to the mode's stored prompt, no Save. The
    /// remaining landing surfaces - paste, note, bullseye, undo - are unreachable rather than merely
    /// unused: they live in `OneShotRegistry`'s land closures, and the bench holds no reference to a
    /// delivery collaborator at all, calling only the transform half. The retry lifecycle, the one
    /// mutation the shared seam WOULD have made on a test's behalf, is gated deterministically in
    /// `TextTransformSelfTest` where a pending retry can be armed without a provider.
    private static func checkPromptTestBench(custom: CustomModeStore, mode: CustomMode) {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let recent = "synthetic probe take: tighten this sentence for me"
        let history = [
            // Newest first. The monologue is over the cap, so the walk-back skips it.
            entryFixture(String(repeating: "b", count: 2524), at: now),
            entryFixture(recent, at: now.addingTimeInterval(-90)),
        ]

        var ran: (mode: CustomMode, input: String)?
        var deliver: ((CleanupClient.Result) -> Void)?
        var saved: String?
        let sheet = PromptEditorSheet.customModeWorkstation(
            title: ModelsPowerSettingsView.customPromptTitle(for: mode),
            mode: mode,
            bench: PromptTestBenchConfig(
                mode: mode,
                history: { history },
                // Deliberately does NOT call back: holding the completion is how "a slow run does not
                // block the panel" becomes an assertion rather than a hope.
                runner: { candidate, input, done in ran = (candidate, input); deliver = done }),
            onSave: { saved = $0 })
        let root = sheet.contentViewForTesting

        check("the bench states, before the button is pressed, that nothing lands",
              (find("prompt-test-note", in: root) as? NSTextField)?.stringValue
                == PromptEditorSheet.testBenchNote)

        // Input sourcing, read off the live controls.
        check("the sample seeds from the newest History take that fits the cap",
              sheet.sampleTextForTesting == recent)
        check("the panel says the sample came from History",
              sheet.sourceTextForTesting
                == PromptTestBench.sourceLabel(.history(now.addingTimeInterval(-90))))
        guard let sample = find("prompt-test-sample", in: root) as? NSTextView,
              let testButton = find("prompt-test-run", in: root) as? NSButton,
              let reseed = find("prompt-test-reseed", in: root) as? NSButton else {
            check("the bench exposes its sample field, Test button and reseed control", false)
            return
        }
        check("the sample field is free text: always editable, never capped",
              sample.isEditable && sample.isSelectable)
        check("Test is enabled once a sample exists", testButton.isEnabled)
        check("reseed is idle while the sample still IS the History take", !reseed.isEnabled)

        sample.insertText(" and add a closing line.",
                          replacementRange: NSRange(location: sample.string.count, length: 0))
        check("one edit stops the sample claiming to be the History take",
              sheet.sourceTextForTesting == PromptTestBench.sourceLabel(.typed))
        check("reseed lights up once the sample has diverged", reseed.isEnabled)
        let typed = sample.string

        // A test runs the prompt on screen. Edit the prompt, not the store, and press the real button.
        guard let editor = find("prompt-editor-text", in: root) as? NSTextView else {
            check("the bench can reach the editable prompt region", false)
            return
        }
        editor.insertText(" Keep every proper noun.",
                          replacementRange: NSRange(location: editor.string.count, length: 0))
        let editedPrompt = editor.string

        let historyBefore = TranscriptionHistory.shared.all().count
        let clipboardBefore = NSPasteboard.general.changeCount
        let fullHistoryBefore = fullHistoryFingerprint()

        testButton.performClick(nil)

        check("Test runs the prompt currently on screen, not the stored one",
              ran?.mode.prompt == editedPrompt && ran?.mode.prompt != mode.prompt)
        check("Test runs the sample currently in the field", ran?.input == typed)
        check("Test keeps the mode's route, so it hits the hotkey's configured provider and model",
              ran?.mode.routeID == mode.routeID && ran?.mode.model == mode.model)
        check("a slow run does not block the panel: the button returns before any result",
              testButton.isEnabled == false && sheet.resultTextForTesting.isEmpty
                && !sheet.statusTextForTesting.isEmpty)
        check("editing the prompt to test it does not write it to the store",
              custom.mode(id: mode.id)?.prompt == mode.prompt && saved == nil)

        // The result arrives. This is the moment a leak would happen.
        deliver?(.ok("Tightened sentence, closing line added."))
        pump()
        check("the answer is shown in the panel",
              sheet.resultTextForTesting == "Tightened sentence, closing line added.")
        check("the status says on screen that nothing landed",
              sheet.statusTextForTesting == PromptTestBench.Outcome.output("x").statusText)

        TranscriptionHistory.shared.flush()
        check("a Test run adds nothing to the rolling History",
              TranscriptionHistory.shared.all().count == historyBefore)
        check("a Test run adds nothing to the full-history store",
              fullHistoryFingerprint() == fullHistoryBefore)
        check("a Test run writes nothing to the clipboard",
              NSPasteboard.general.changeCount == clipboardBefore)
        check("a Test run never saves the prompt it tested",
              saved == nil && custom.mode(id: mode.id)?.prompt == mode.prompt)
        check("Test is usable again once the run is done", testButton.isEnabled)

        // Failures wear the real path's words. Not new error text invented for this panel.
        testButton.performClick(nil)
        deliver?(.timedOut)
        pump()
        check("a timeout is reported in the same sentence a failed take toasts",
              sheet.statusTextForTesting == TextTransformRetryDescriptor.Failure.timedOut.userMessage)
        check("a failure leaves the result area empty", sheet.resultTextForTesting.isEmpty)

        // Reseed, now that the sample has been edited and tested against: the History take comes back
        // and the provenance line comes back with it.
        reseed.performClick(nil)
        check("reseed puts the History take back, and the label with it",
              sheet.sampleTextForTesting == recent
                && sheet.sourceTextForTesting
                    == PromptTestBench.sourceLabel(.history(now.addingTimeInterval(-90))))

        // Close the panel with a run still on the wire. Its result has nowhere to land by construction;
        // this pins that it is not drawn into a dismissed panel either.
        testButton.performClick(nil)
        (find("prompt-editor-cancel", in: root) as? NSButton)?.performClick(nil)
        deliver?(.ok("LATE ANSWER FROM A DISMISSED PANEL"))
        pump()
        check("a result arriving after the panel closed is dropped, not drawn",
              !sheet.resultTextForTesting.contains("LATE ANSWER"))
        check("and it still lands nowhere else",
              saved == nil && custom.mode(id: mode.id)?.prompt == mode.prompt
                && TranscriptionHistory.shared.all().count == historyBefore
                && NSPasteboard.general.changeCount == clipboardBefore)

        // Nothing in History fits: the field starts EMPTY rather than showing a truncated take.
        let starved = PromptEditorSheet.customModeWorkstation(
            title: "Starved · Shared task prompt", mode: mode,
            bench: PromptTestBenchConfig(
                mode: mode,
                history: { [entryFixture(String(repeating: "c", count: 1001), at: now)] },
                runner: { _, _, _ in check("a starved bench must not dispatch", false) }),
            onSave: { _ in })
        let starvedRoot = starved.contentViewForTesting
        check("nothing under the cap means an empty field, not a truncated entry",
              starved.sampleTextForTesting.isEmpty)
        check("and the panel says the sample is empty rather than claiming a source",
              starved.sourceTextForTesting == PromptTestBench.sourceLabel(.empty))
        check("Test is inert with no sample",
              (find("prompt-test-run", in: starvedRoot) as? NSButton)?.isEnabled == false)
        check("reseed is inert with nothing to reseed from",
              (find("prompt-test-reseed", in: starvedRoot) as? NSButton)?.isEnabled == false)
        (find("prompt-test-run", in: starvedRoot) as? NSButton)?.performClick(nil)

        // The seam that makes "runs the REAL model" true of the shipping sheet: the one the production
        // presenter builds injects no runner, so Test dispatches through CustomModeClient.run.
        let production = PromptEditorSheet.customModeWorkstation(
            title: ModelsPowerSettingsView.customPromptTitle(for: mode), mode: mode, onSave: { _ in })
        check("the shipping workstation tests through the real transform client, not a stub",
              production.usesProductionRunnerForTesting)
    }

    private static func entryFixture(_ raw: String, at date: Date) -> TranscriptionHistory.Entry {
        TranscriptionHistory.Entry(id: UUID(), date: date, text: raw, app: "Probe",
                                   raw: raw, cleaned: nil, mode: HistoryMode.raw.rawValue, level: nil)
    }

    /// Names + sizes of every per-day file in the opt-in infinite history store. Compared before and
    /// after a Test run, so an append to it is caught whether or not the toggle happens to be on.
    private static func fullHistoryFingerprint() -> [String] {
        let dir = DictationHistoryStore.defaultDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().map { name in
            let size = (try? FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? nil
            return "\(name):\(size ?? -1)"
        }
    }

    /// The bench hops to main to draw a result, so let the run loop turn before reading the panel back.
    private static func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private static func isInsideScrollView(_ view: NSView) -> Bool {
        var parent = view.superview
        while let current = parent {
            if current is NSScrollView || current is NSClipView { return true }
            parent = current.superview
        }
        return false
    }

    private static func checkRetry(_ view: ModelsPowerSettingsView) {
        var retried: (LLMRouteID, LLMProvider)?
        view.onRetry = { retried = ($0, $1) }
        view.setRetryAvailable(true, for: .email, provider: .claude)
        let retry = find("retry|email", in: view) as? NSButton
        check("failed route enables explicit Retry", retry?.isEnabled == true)
        retry?.performClick(nil)
        check("Retry preserves exact failed route/provider",
              retried?.0 == .email && retried?.1 == .claude)
    }

    /// L9's contract: ONE tab. Every hotkey that runs a model carries its chord, its traits, and its
    /// provider/model/effort/prompt in the SAME card, and there is no second surface to switch to.
    ///
    /// The bar is stated as a gesture — "if I want to make a custom hotkey I have to go to the hotkeys
    /// tab to add it and then switch back to the models tab to dial in its settings" — so the last block
    /// performs that gesture on the real composed page rather than asserting a layout that could be true
    /// while the gesture still fails.
    private static func checkMergedHotkeysTab(root: URL) {
        let routing = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("merged-models-power.json"))
        let custom = CustomModeStore(
            url: root.appendingPathComponent("merged-custom-modes.json"), routingStore: routing)
        let seeded = CustomMode(
            id: "merged-custom", name: "Spellcheck",
            chord: .regular(keyCode: 1, label: "S"), prompt: "Fix the spelling.",
            input: .selection,
            model: LLMProviderDefaults.testedBundle(for: .local, route: .custom("merged-custom"))!,
            landing: .inPlace)
        do { try custom.upsert(seeded) } catch {
            check("merged Hotkeys tab seeds a custom hotkey", false)
            return
        }

        let hotkeys = HotkeysSettingsView(width: 640, customStore: custom)
        let routingView = ModelsPowerSettingsView(
            width: 640, settingsStore: routing, customStore: custom,
            codexCatalogLoader: { nil })
        let tab = HotkeysTabView(hotkeys: hotkeys, routing: routingView)

        check("merged tab carries the hotkey legend and the global provider section",
              texts(in: tab).contains { $0.hasPrefix("LEGEND") }
                && find("card.providers", in: tab) != nil)
        check("merged tab is as tall as both halves stacked",
              tab.frame.height >= hotkeys.frame.height + routingView.frame.height)

        // NOTHING WAS REMOVED. The global half kept every control it owned on its own tab...
        check("the global half survived the merge intact",
              find("bulk-derived-state", in: tab) != nil
                && find("cloud-update-check", in: tab) != nil
                && find("cloud-update-auto-check", in: tab) != nil
                && find("provider-signin-pointer", in: tab) != nil
                && find("codex-update-status", in: tab) != nil
                && LLMProvider.allCases.allSatisfy {
                    find("availability|\($0.rawValue)", in: tab) != nil
                        && find("bulk|\($0.rawValue)", in: tab) is NSButton
                })
        // ...and every chord in the whole namespace is still rebindable, exactly once, somewhere on it.
        check("the dictation wakeup is still rebindable on the merged tab",
              find("chord|wakeup", in: tab) is KeycapButton)
        let chordCounts = HotkeyCommand.allCases.map { command in
            allViews(in: tab).filter {
                $0.identifier?.rawValue == "chord|builtin:\(command.rawValue)"
            }.count
        }
        check("every built-in hotkey has exactly one rebindable chord on the merged tab",
              chordCounts.allSatisfy { $0 == 1 })

        // Every model-running hotkey: chord + Advanced + routing, all inside its own card.
        let routed: [(key: String, route: LLMRouteID, owner: String)] = [
            ("promptPrep", .promptPrep, "builtin:cleanupSelection"),
            ("email", .email, "builtin:email"),
            ("searchLocalSynth", .searchLocalSynth, "builtin:searchLocal"),
            ("searchGeminiSynth", .searchGeminiSynth, "builtin:searchGemini"),
            ("custom:merged-custom", .custom("merged-custom"), "custom:merged-custom"),
        ]
        for entry in routed {
            guard let card = find("card.\(entry.key)", in: tab) else {
                check("merged tab renders a card for \(entry.key)", false)
                continue
            }
            check("\(entry.key) card hosts its own hotkey binding row",
                  find("hotkey-binding|\(entry.key)", in: card) != nil
                    && find("chord|\(entry.owner)", in: card) is KeycapButton)
            guard let advanced = find("advanced|\(entry.key)", in: card) as? NSButton else {
                check("\(entry.key) card offers an Advanced disclosure", false)
                continue
            }
            advanced.performClick(nil)
            guard let open = find("card.\(entry.key)", in: tab) else {
                check("\(entry.key) card survives its own disclosure", false)
                continue
            }
            let ids = allViews(in: open).compactMap { $0.identifier?.rawValue }
            check("\(entry.key) Advanced reveals model + effort in the same card",
                  find("model|\(entry.route.rawValue)", in: open) is NSPopUpButton
                    && find("effort|\(entry.route.rawValue)", in: open) is NSPopUpButton)
            check("\(entry.key) Advanced reveals its prompt editor in the same card",
                  entry.key == "custom:merged-custom"
                    ? find("edit-custom-prompt|merged-custom", in: open) is NSButton
                    : ids.contains { $0.hasPrefix("edit-prompt|\(entry.route.rawValue)|") })
            check("\(entry.key) keeps chord and routing in one card while expanded",
                  find("hotkey-binding|\(entry.key)", in: open) != nil
                    && find("chord|\(entry.owner)", in: open) is KeycapButton)
            // A hand-laid-out row inside a hand-laid-out card fails silently when it overflows, so the
            // fit is asserted rather than eyeballed: the row inside its card, its controls inside it.
            if let row = find("hotkey-binding|\(entry.key)", in: open) {
                check("\(entry.key) binding row and its controls fit inside the card",
                      row.frame.minX >= -0.5 && row.frame.minY >= -0.5
                        && row.frame.maxX <= open.bounds.maxX + 0.5
                        && row.frame.maxY <= open.bounds.maxY + 0.5
                        && row.subviews.allSatisfy {
                            $0.frame.minX >= -0.5 && $0.frame.minY >= -0.5
                                && $0.frame.maxX <= row.bounds.maxX + 0.5
                                && $0.frame.maxY <= row.bounds.maxY + 0.5
                        })
            }
            (find("advanced|\(entry.key)", in: open) as? NSButton)?.performClick(nil)
        }

        // Dictation cleanup has no chord of its own — it rides the wakeup plus the level keys — so it
        // honestly renders no binding row rather than borrowing someone else's.
        check("the dictation cleanup card claims no hotkey of its own",
              find("card.cleanup", in: tab) != nil
                && find("hotkey-binding|cleanup", in: tab) == nil)

        let copy = texts(in: tab)
        check("no cross-reference to a separate Models tab survives the merge",
              !copy.contains { $0.contains("Models & Power") }
                && !copy.contains { $0.contains("routing: Models") }
                && !copy.contains { $0.contains("prompts on Models") })

        // the user's bar, as a gesture: add a hotkey, then dial it in, without leaving the tab.
        guard let add = find("add-new-hotkey", in: tab) as? NSButton else {
            check("Add new hotkey sits beside the cards it creates", false)
            return
        }
        let before = Set(custom.modes.map(\.id))
        add.performClick(nil)
        pump()
        guard let created = custom.modes.map(\.id).first(where: { !before.contains($0) }) else {
            check("Add new hotkey creates a custom hotkey", false)
            return
        }
        let key = LLMRouteID.custom(created).rawValue
        check("the new hotkey's card appears on the same tab, carrying its chord",
              find("hotkey-binding|\(key)", in: tab) != nil
                && find("chord|custom:\(created)", in: tab) is KeycapButton)
        guard let newAdvanced = find("advanced|\(key)", in: tab) as? NSButton else {
            check("the new hotkey offers Advanced without leaving the tab", false)
            return
        }
        newAdvanced.performClick(nil)
        check("the new hotkey is fully configurable without leaving the tab",
              find("model|\(key)", in: tab) is NSPopUpButton
                && find("effort|\(key)", in: tab) is NSPopUpButton
                && find("edit-custom-prompt|\(created)", in: tab) is NSButton
                && find("input|\(created)", in: tab) is NSPopUpButton
                && find("landing|\(created)", in: tab) is NSPopUpButton
                && find("name|custom:\(created)", in: tab) is NSTextField)
        check("the new hotkey also reaches the legend, which only the binding half draws",
              texts(in: tab).contains { $0.contains("(custom)") })
    }

    /// S3's GUI contract: render the real Hotkeys page over synthetic modes and prove that the
    /// Toggleable checkbox exists only for modes that consume a take and land in place. Since L9 the
    /// checkbox rides its hotkey's routing card, so the probe drives the composed page — the same
    /// controls, built by the same code, asserted where the user actually meets them.
    private static func checkHotkeysToggleableCheckboxes(root: URL) {
        let originalToggleIDs = Settings.persistentToggleModeIDs
        Settings.persistentToggleModeIDs = []
        defer { Settings.persistentToggleModeIDs = originalToggleIDs }

        let routing = ModelsPowerSettingsStore(
            url: root.appendingPathComponent("hotkeys-toggle-routing.json"))
        let store = CustomModeStore(
            url: root.appendingPathComponent("hotkeys-toggle-modes.json"), routingStore: routing)
        func mode(_ id: String, _ input: CustomInput, _ landing: CustomLanding) -> CustomMode {
            CustomMode(
                id: id, name: id,
                chord: .regular(keyCode: Int64(100 + id.count), label: "K"),
                prompt: "Synthetic transform.", input: input,
                model: .local("synthetic-model"), landing: landing)
        }
        do {
            try store.upsert(mode("dictation-in-place", .dictation, .inPlace))
            try store.upsert(mode("both-in-place", .both, .inPlace))
            try store.upsert(mode("selection-in-place", .selection, .inPlace))
            try store.upsert(mode("dictation-note", .dictation, .note))
        } catch {
            check("Hotkeys toggleable synthetic rows save", false)
            return
        }

        func page() -> HotkeysTabView {
            HotkeysTabView(
                hotkeys: HotkeysSettingsView(width: 640, customStore: store),
                routing: ModelsPowerSettingsView(
                    width: 640, settingsStore: routing, customStore: store,
                    codexCatalogLoader: { nil }))
        }
        let hotkeys = page()
        let toggleIDs = allViews(in: hotkeys).compactMap { child -> String? in
            guard child is NSButton,
                  let id = child.identifier?.rawValue,
                  id.hasPrefix("toggleable|") else { return nil }
            return id
        }
        check("Hotkeys renders Toggleable on Option+M",
              toggleIDs.contains("toggleable|\(OneShotMode.email.id)"))
        check("Hotkeys omits Toggleable from Option+P",
              !toggleIDs.contains("toggleable|\(OneShotMode.cleanupSelection.id)"))
        check("Hotkeys renders Toggleable on eligible custom rows",
              toggleIDs.contains("toggleable|custom:dictation-in-place")
              && toggleIDs.contains("toggleable|custom:both-in-place"))
        check("Hotkeys omits Toggleable from ineligible custom rows",
              !toggleIDs.contains("toggleable|custom:selection-in-place")
              && !toggleIDs.contains("toggleable|custom:dictation-note"))
        check("Hotkeys renders exactly the three eligible Toggleable controls",
              toggleIDs.count == 3)
        check("Hotkeys Toggleable controls render inside the page bounds",
              allViews(in: hotkeys)
                .filter { $0.identifier?.rawValue.hasPrefix("toggleable|") == true }
                .allSatisfy {
                    let framed = $0.convert($0.bounds, to: hotkeys)
                    return framed.minX >= 0 && framed.minY >= 0
                        && framed.maxX <= hotkeys.bounds.maxX
                        && framed.maxY <= hotkeys.bounds.maxY
                })

        if let email = find("toggleable|\(OneShotMode.email.id)", in: hotkeys) as? NSButton {
            check("Hotkeys Toggleable defaults off", email.state == .off)
            email.performClick(nil)
            check("Hotkeys Toggleable click persists its setting",
                  Settings.persistentToggleEnabled(for: OneShotMode.email.id))
            let reopenedEmail =
                find("toggleable|\(OneShotMode.email.id)", in: page()) as? NSButton
            check("Hotkeys Toggleable persisted state renders checked after rebuild",
                  reopenedEmail?.state == .on)
        } else {
            check("Hotkeys Option+M Toggleable is actionable", false)
        }
    }

    private static func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews(in: $0) }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        allViews(in: root).first { $0.identifier?.rawValue == id }
    }

    private static func texts(in root: NSView) -> [String] {
        allViews(in: root).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private static func cardsHaveNoOverflow(_ root: NSView) -> Bool {
        allViews(in: root).filter { $0.identifier?.rawValue.hasPrefix("card.") == true }.allSatisfy { card in
            card.subviews.allSatisfy { child in
                child.frame.minX >= -0.5 && child.frame.minY >= -0.5
                    && child.frame.maxX <= card.bounds.maxX + 0.5
                    && child.frame.maxY <= card.bounds.maxY + 0.5
            }
        }
    }

    private static func row(
        id: String,
        model: String,
        displayName: String,
        hidden: Bool,
        efforts: [String]
    ) -> ModelCatalogRow {
        ModelCatalogRow(
            id: id,
            model: model,
            displayName: displayName,
            description: "untrusted metadata not used by the picker",
            hidden: hidden,
            defaultReasoningEffort: efforts.first,
            supportedReasoningEfforts: efforts.map {
                ModelCatalogReasoningEffort(
                    reasoningEffort: $0,
                    description: "untrusted effort copy",
                    unknownFields: [:])
            },
            inputModalities: ["text"],
            supportsPersonality: nil,
            isDefault: nil,
            upgrade: nil,
            upgradeInfo: nil,
            unknownFields: [:])
    }
}
