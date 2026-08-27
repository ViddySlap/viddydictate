import Cocoa

/// Offscreen render-to-PNG seam for the point-of-use offer (`--point-of-use-render <outdir>`), the B13 /
/// B14 surface.
///
/// In-process render, not a screen capture: screen capture from an agent shell is TCC-blocked, so this is
/// how the link that builds a panel can actually look at what it built. Every state below is synthetic,
/// which is the only way to photograph the states that matter - a Mac with nothing installed, and an
/// install whose second row failed with a real vendor error - without arranging for them on a real
/// machine.
///
/// PNGs written under `<outdir>`:
///   - `offer-chooser.png`      - B14's four buttons on a machine with no local model and no CLI.
///   - `offer-install.png`      - B13's in-place offer with the LM Studio prerequisite ahead of the model.
///   - `offer-install-model.png`- the same offer where only the model is missing, quoting its MEASURED size.
///   - `offer-running.png`      - the install running, one row done, one row failed with the real error.
///   - `offer-selection.png`    - the same chooser with the selection moved, so the highlight is visible.
///
/// What a screenshot cannot assert, and this gate does: that every line the policy produced actually
/// reached a control rather than being dropped by the layout, that no line is clipped by the box it was
/// given, that the four chooser cells are equal in size and sit in the drawn order, that moving the
/// selection changes which cell is lit and changes the pixels, and that the panel never renders a cloud
/// button on a surface the policy did not put one on.
enum PointOfUseOfferRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func presence(_ installed: Bool, _ state: LLMProviderAvailabilityState,
                                 models: [LMStudioModelOption]? = nil)
        -> LLMProviderDetection.Presence {
        LLMProviderDetection.Presence(installed: installed, state: state, availableLocalModels: models)
    }

    private static var bareMachine: [LLMProvider: LLMProviderDetection.Presence] {
        [.local: presence(false, .unavailable("LM Studio is not installed")),
         .claude: presence(false, .unavailable("CLI unavailable")),
         .codex: presence(false, .unavailable("the codex CLI is not installed"))]
    }

    private static var claudeOnly: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = bareMachine
        providers[.claude] = presence(true, .available)
        return providers
    }

    private static var lmStudioWithoutTheModel: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = bareMachine
        providers[.local] = presence(true, .available,
                                     models: [LMStudioModelOption(modelID: "llama-3.2-1b-instruct",
                                                                  label: "llama")])
        return providers
    }

    private static var coreInstalled: BootstrapSnapshot {
        var snapshot = BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents)
        for descriptor in BootstrapInstallPlan.mandatoryCore {
            snapshot.apply(InstallerComponentResult(componentID: descriptor.id,
                                                    title: descriptor.title, state: .installed))
        }
        return snapshot
    }

    static func run(outDir: String) -> Bool {
        failures = 0
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        } catch {
            print("[point-of-use-render] cannot create \(outDir): \(error)")
            return false
        }

        guard let chooser = PointOfUsePolicy.offer(for: .email, presences: bareMachine,
                                                   bootstrap: coreInstalled),
              let chained = PointOfUsePolicy.offer(for: .email, presences: claudeOnly,
                                                   bootstrap: coreInstalled),
              let modelOnly = PointOfUsePolicy.offer(for: .email,
                                                     presences: lmStudioWithoutTheModel,
                                                     bootstrap: coreInstalled) else {
            print("[point-of-use-render] the policy produced no offer to render")
            return false
        }

        print("--- what the point of use produced BEFORE this surface existed ---")
        renderPriorToast(outDir: outDir)
        print("--- B14: the four-button chooser ---")
        renderChooser(chooser, outDir: outDir)
        print("--- B13: the in-place install offer ---")
        renderOffer(chained, name: "offer-install", outDir: outDir,
                    expectPrerequisite: true)
        renderOffer(modelOnly, name: "offer-install-model", outDir: outDir,
                    expectPrerequisite: false)
        print("--- the install running, including a row that failed ---")
        renderRunning(modelOnly, outDir: outDir)

        print("[point-of-use-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - states

    private static func renderChooser(_ offer: PointOfUseOffer, outDir: String) {
        let panel = InstallOfferPanel()
        let view = panel.renderForSeam(.offer(offer))
        SelfTestRenderCapture.capture(view, to: outDir + "/offer-chooser.png", name: "chooser",
                                      report: check)
        assertLinesReached(offer, in: view, label: "chooser")
        assertButtonsReached(offer, in: view, label: "chooser")

        // The four cells are one row: equal widths, in the drawn order, left to right.
        let cells = offer.buttons.compactMap {
            SelfTestRenderCapture.find(PointOfUsePolicy.buttonIdentifier($0.id), in: view)
        }
        check("every chooser button reached a cell", cells.count == offer.buttons.count,
              "\(cells.count) of \(offer.buttons.count)")
        if cells.count == offer.buttons.count {
            let widths = Set(cells.map { Int($0.frame.width.rounded()) })
            check("the four cells are the same width", widths.count == 1,
                  widths.map(String.init).joined(separator: ","))
            check("they are laid out left to right in the order the policy declared",
                  zip(cells, cells.dropFirst()).allSatisfy { $0.frame.minX < $1.frame.minX })
            check("they sit on one row", Set(cells.map { Int($0.frame.minY.rounded()) }).count == 1)
        }

        // Moving the selection has to change the picture, not just an index. This is the check that
        // would have caught a highlight wired to a variable nothing draws.
        let firstInk = ink(view)
        panel.moveRight()
        let moved = panel.renderForSeam(.offer(offer))
        SelfTestRenderCapture.capture(moved, to: outDir + "/offer-selection.png", name: "selection",
                                      report: check)
        check("the selection starts on the first button and moves right",
              panel.selectedButton?.id == offer.buttons[1].id,
              panel.selectedButton?.id ?? "nil")
        check("moving the selection changes the rendered pixels",
              abs(ink(moved) - firstInk) > 0.0001,
              "\(String(format: "%.4f", firstInk)) -> \(String(format: "%.4f", ink(moved)))")

        // Left from the second button returns to the first; left again must not fall off the row.
        panel.moveLeft()
        panel.moveLeft()
        check("the selection cannot run off the left end",
              panel.selectedButton?.id == offer.buttons[0].id)
        for _ in 0..<10 { panel.moveRight() }
        check("or off the right end",
              panel.selectedButton?.id == offer.buttons[offer.buttons.count - 1].id)
    }

    private static func renderOffer(_ offer: PointOfUseOffer, name: String, outDir: String,
                                    expectPrerequisite: Bool) {
        let panel = InstallOfferPanel()
        let view = panel.renderForSeam(.offer(offer))
        SelfTestRenderCapture.capture(view, to: "\(outDir)/\(name).png", name: name, report: check)
        assertLinesReached(offer, in: view, label: name)
        assertButtonsReached(offer, in: view, label: name)

        check("\(name) offers no cloud button",
              !offer.buttons.contains { $0.route.kind == .guidedProvider })
        let mentionsLMStudio = offer.lines.contains { $0.contains("LM Studio is not installed yet") }
        check("\(name) names the LM Studio prerequisite only when there is one",
              mentionsLMStudio == expectPrerequisite)
        if !expectPrerequisite {
            check("\(name) quotes the measured model size on screen",
                  (SelfTestRenderCapture.label(PointOfUsePolicy.lineIdentifier(0), in: view)?
                      .stringValue ?? "").contains("6.86 GB"),
                  SelfTestRenderCapture.label(PointOfUsePolicy.lineIdentifier(0), in: view)?
                      .stringValue ?? "")
        }
    }

    private static func renderRunning(_ offer: PointOfUseOffer, outDir: String) {
        guard case .install(let install) = offer else {
            check("the running page needs an install offer", false)
            return
        }
        var done = BootstrapComponentRecord(id: BootstrapInstallPlan.lmStudio.id, title: "LM Studio")
        done.apply(InstallerComponentResult(componentID: done.id, title: done.title, state: .installed))
        var failed = BootstrapComponentRecord(id: BootstrapInstallPlan.gemma.id,
                                              title: LMStudioInstaller.gemmaModelID)
        failed.apply(InstallerComponentResult(
            componentID: failed.id, title: failed.title,
            state: .failed(InstallerFailure(category: .transport,
                                            message: "Could not resolve host: huggingface.co"),
                           attempts: 3)))

        let panel = InstallOfferPanel()
        let view = panel.renderForSeam(.running(install, [done, failed]))
        SelfTestRenderCapture.capture(view, to: outDir + "/offer-running.png", name: "running",
                                      report: check)
        let rendered = (0..<2).compactMap {
            SelfTestRenderCapture.label(PointOfUsePolicy.lineIdentifier($0), in: view)?.stringValue
        }
        check("both rows reached the panel", rendered.count == 2, rendered.joined(separator: " | "))
        check("a finished row reads done", rendered.first?.contains("done") == true,
              rendered.first ?? "")
        check("a failed row shows the vendor's own text, not a generic message",
              rendered.last?.contains("Could not resolve host: huggingface.co") == true,
              rendered.last ?? "")
        check("the running page offers no buttons to arrow through", panel.buttons.isEmpty)
        check("the running heading names the feature, not its internal id",
              SelfTestRenderCapture.label(PointOfUsePolicy.headerIdentifier, in: view)?.stringValue
                == "INSTALLING - EMAIL MODE",
              SelfTestRenderCapture.label(PointOfUsePolicy.headerIdentifier, in: view)?
                .stringValue ?? "missing")
        assertNotClipped(in: view, label: "running")
    }

    /// The whole answer a user used to get when a mode had no model: one toast, and then nothing.
    ///
    /// It is captured as the honest BEFORE half of this link's before/after pair, and it carries a real
    /// assertion rather than being decoration: the toast names a Settings tab, and if the offer panel
    /// were ever removed this capture would be the whole story again. So it asserts that the panel says
    /// something the toast does not - that the missing piece can be installed from where the user is.
    private static func renderPriorToast(outDir: String) {
        let snapshot = HUDDefaultsSnapshot()
        defer { snapshot.restore() }
        Settings.powerMode = .finalOnly
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .bottomCenter

        let message = "⚠️ Email writer: "
            + TextTransformRetryDescriptor.Failure.unavailable.userMessage
            + " — pasted raw. Retry under Models on the Hotkeys tab."
        guard let image = HUDPanel().renderToastForSeam(message: message, forceFull: false) else {
            check("the prior point-of-use toast rendered", false)
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            check("the prior point-of-use toast rendered", false, "PNG encode failed")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: outDir + "/offer-before-toast.png"))
        } catch {
            check("the prior point-of-use toast rendered", false, error.localizedDescription)
            return
        }
        check("the prior point-of-use toast rendered", true, "\(rep.pixelsWide)x\(rep.pixelsHigh) px")
        check("the toast alone offers no way to install the missing piece",
              !message.lowercased().contains("install"))

        guard case .install(let offer)? = PointOfUsePolicy.offer(
            for: .email, presences: lmStudioWithoutTheModel, bootstrap: coreInstalled) else {
            check("the panel now offers one", false)
            return
        }
        check("the panel now offers one",
              offer.buttons.contains { $0.route.kind == .install && $0.title == "Install now" })
    }

    // MARK: - shared assertions

    /// Every line the policy produced must have reached a control, with its text intact. A layout that
    /// silently drops the second line is the failure a screenshot review is worst at catching.
    private static func assertLinesReached(_ offer: PointOfUseOffer, in view: NSView, label: String) {
        for (index, line) in offer.lines.enumerated() {
            let field = SelfTestRenderCapture.label(PointOfUsePolicy.lineIdentifier(index), in: view)
            check("\(label) line \(index) reached the panel intact", field?.stringValue == line,
                  field?.stringValue ?? "missing")
        }
        check("\(label) drew no line the policy did not produce",
              SelfTestRenderCapture.label(PointOfUsePolicy.lineIdentifier(offer.lines.count),
                                          in: view) == nil)
        let header = SelfTestRenderCapture.label(PointOfUsePolicy.headerIdentifier, in: view)
        check("\(label) header reached the panel", header?.stringValue == offer.header,
              header?.stringValue ?? "missing")
        assertNotClipped(in: view, label: label)
    }

    private static func assertButtonsReached(_ offer: PointOfUseOffer, in view: NSView, label: String) {
        for button in offer.buttons {
            let cell = SelfTestRenderCapture.find(PointOfUsePolicy.buttonIdentifier(button.id), in: view)
            check("\(label) button \(button.id) reached the panel", cell != nil)
        }
    }

    /// No text field may be shorter than the text it was given. The copy names a real model id and a real
    /// vendor error, and neither has a length this panel gets to assume.
    private static func assertNotClipped(in view: NSView, label: String) {
        var clipped: [String] = []
        for candidate in SelfTestRenderCapture.allViews(in: view) {
            guard let field = candidate as? NSTextField, !field.stringValue.isEmpty,
                  field.frame.width > 1 else { continue }
            let needed = field.attributedStringValue.boundingRect(
                with: NSSize(width: field.frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if field.frame.height + 0.5 < needed {
                // Name the control by the nearest identified ancestor. A bare "?" was what the first
                // failing run printed, and it cost a round trip to find out which cell it meant.
                var owner = field.identifier?.rawValue
                var ancestor: NSView? = field
                while owner == nil, let current = ancestor?.superview {
                    owner = current.identifier?.rawValue
                    ancestor = current
                }
                clipped.append("\(owner ?? "unidentified") needs \(Int(needed.rounded())) "
                    + "has \(Int(field.frame.height.rounded()))")
            }
        }
        check("\(label) clips no text", clipped.isEmpty, clipped.joined(separator: "; "))
    }

    private static func ink(_ view: NSView) -> Double {
        view.layoutSubtreeIfNeeded()
        for subview in SelfTestRenderCapture.allViews(in: view) { subview.needsDisplay = true }
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        return SelfTestRenderCapture.inkFraction(rep)
    }
}
