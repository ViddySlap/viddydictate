import Cocoa

/// Offscreen render-to-PNG seam for the Feature Tour (`--feature-tour-render <outdir>`), G8.
///
/// In-process render, not a screen capture (screen capture from an agent shell is TCC-blocked), built through the
/// controller's own `makePageView(_:)` with every live fact stubbed: the hotkey map, the permissions, the hotkey
/// tap, and the local apps. The stubs answer from memory, so nothing is measured, started or opened.
///
/// Every page and variant is rendered twice, under the light and the dark system appearance (`NSApp.appearance`
/// = `.aqua`, then `.darkAqua`), because what the user's Mac is set to must not change what the tour shows, and
/// the two renders must come out the same. Each is hosted in a window, as in the app. The page paints its own
/// opaque phosphor panel, so the capture is what the window shows. (The S7 gate captured a page that painted no
/// backdrop onto transparency, so its PNGs showed white-on-nothing: a blank top, blank white pills for Back, Skip
/// tour and the Settings link, and only the green dot of eleven.)
///
/// PNGs written under `<outdir>`, each as `<name>-light.png` and `<name>-dark.png`, plus `<name>.png` (the dark
/// pass, the name earlier runs used):
///   - `tour-page-01-welcome` ... `tour-page-11-staying-current` - every page at the default UI size.
///     Stubbed facts: Microphone not granted, Accessibility and Input Monitoring granted, no hotkey tap in this
///     launch (so page 3's practice box reads "Relaunch ViddyDictate, then try here."), LM Studio running with
///     two models and Ollama installed but not running.
///   - `tour-page-01-welcome-largest-ui`, `tour-page-06-local-models-largest-ui` - pages 1 and 6 with the
///     app's UI size settings (HUD and pill) at their largest. The tour has no size setting of its own, so these
///     must match the default layout point for point.
///   - `tour-page-03-dictation-ready` - the practice box live (tap installed), editable.
///   - `tour-page-03-dictation-grant-first` - Input Monitoring still off: grant first, then relaunch.
///   - `tour-page-03-dictation-rebound` - lock rebound to K: the body and the keys card both say K.
///   - `tour-page-06-local-models-checking` - before the local apps measurement lands: CHECKING.
///
/// What a screenshot cannot assert, and this gate does: every page carries ink; no text is clipped or truncated
/// by its own frame (after the layout pass AppKit runs before a draw); every page has Back, Next (Done on the
/// last), Skip tour and the dots, below its content; all pages share one height that fits the window without
/// scrolling; and pages 2 and 6 show their live rows in the words of the surfaces they come from.
///
/// And that the text is VISIBLE, which page-wide ink never proved (the cards alone supply it):
///   - every label, by colour resolution (`SelfTestRenderCapture.textContrast`): its text colour and every fill
///     behind it, resolved under the appearance it is drawn in, at 4.5:1 or better;
///   - the page title, present, non-empty, and 4.5:1 both by colour resolution and in the rendered pixels;
///   - every button title, non-empty, and 4.5:1 against its own bezel in the rendered pixels (a bezel's colour is
///     not readable from AppKit). A disabled button (Back on page 1) is exempt from the ratio, as WCAG exempts
///     inactive controls, and its ratio is printed;
///   - the capture is opaque, so the PNG is what the window shows, and the light and dark renders are the same
///     pixels, so the system appearance does not reach the tour;
///   - no empty title, body line or button title;
///   - exactly as many page dots as pages, counted in the rendered pixels at 3:1 against the backdrop, with the
///     current one a different colour from the rest.
///
/// Negative controls, each of which must FAIL its check or the gate fails: an empty page (ink); a white title on a
/// white page (colour resolution and pixels); a page drawn on nothing, the S7 failure (title and button pixels,
/// dot count, opacity); and a one-dot strip (dots).
enum FeatureTourRenderCases {
    private static var failures = 0
    /// The pass running now, so every check line says which appearance it was judged under.
    private static var pass = Pass.dark

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] [\(pass.rawValue)] \(name)\(detail.isEmpty ? "" : " - \(detail)")")
        if !ok { failures += 1 }
    }

    /// The two system appearances every surface is rendered under. Dark runs last, so the unsuffixed PNG (the
    /// name earlier runs wrote) is the dark one, as it always was.
    enum Pass: String, CaseIterable {
        case light, dark
        var appearance: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
    }

    /// Body text's WCAG floor. Applied to every label and button title on the page, not only the body.
    static let minimumTextContrast: CGFloat = 4.5
    /// WCAG's floor for a UI shape (1.4.11): each page dot against the backdrop.
    static let minimumDotContrast: CGFloat = 3

    private typealias ID = FeatureTourPageView.ID

    // MARK: - Stubbed facts (distinct values for distinct roles)

    static let permissions = PermissionsStatus(microphone: false, accessibility: true, inputMonitoring: true)

    private static func reading(_ backend: LocalBackendID, installed: Bool, responding: Bool, models count: Int)
        -> LLMProviderDetection.LocalBackendReading {
        let models = (0..<count).map {
            LMStudioModelOption(modelID: "\(backend.rawValue)-tour-fixture-\($0)", label: "fixture \($0)",
                                backend: backend)
        }
        return LLMProviderDetection.LocalBackendReading(
            backend: backend, installed: installed, responding: responding, models: responding ? models : nil,
            startable: backend == .ollama && installed)
    }

    private static let presence = LLMProviderDetection.mergedLocalPresence([
        reading(.lmStudio, installed: true, responding: true, models: 2),
        reading(.ollama, installed: true, responding: false, models: 0),
    ])

    private static var measurements = 0

    /// The tour with every live fact stubbed. Also the on-screen proof's (`--feature-tour-onscreen-proof`).
    static func controller(map: HotkeyMap = .defaults(),
                           permissions: PermissionsStatus = FeatureTourRenderCases.permissions,
                           tapLive: Bool = false,
                           answers: Bool = true) -> FeatureTourWindowController {
        FeatureTourWindowController(
            hotkeys: { map }, readPermissions: { permissions }, hotkeysLive: { tapLive },
            measureLocal: { done in
                measurements += 1
                if answers { done(presence) }
            })
    }

    // MARK: - run

    static func run(outDir: String) -> Bool {
        failures = 0
        measurements = 0
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[feature-tour-render] cannot create \(outDir): \(error)")
            return false
        }
        for each in Pass.allCases {
            pass = each
            // Each pass pins the system appearance, so a capture does not silently change meaning with whatever
            // this Mac is set to, and the two passes together show the setting does not matter.
            app.appearance = each.appearance
            print("=== system appearance: \(each.rawValue) ===")
            renderPass(outDir: outDir)
        }
        print("--- negative controls ---")
        negativeControls()

        print("[feature-tour-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    private static func renderPass(outDir: String) {
        print("--- every page, default UI size ---")
        let tour = controller()
        var heights: [CGFloat] = []
        var defaultViews: [Int: FeatureTourPageView] = [:]
        for index in tour.pages.indices {
            let view = hosted(tour.makePageView(index))
            defaultViews[index] = view
            heights.append(view.frame.height)
            assertPage(view, index: index, of: tour.pages, map: .defaults(), label: name(tour.pages, index))
            photograph(view, index: index, pages: tour.pages, name: name(tour.pages, index), outDir: outDir)
        }
        check("every page shares one height, so Back and Next never move", Set(heights).count == 1,
              heights.map { "\(Int($0))" }.joined(separator: ","))
        check("every page fits the window without scrolling",
              heights.allSatisfy { $0 <= FeatureTourWindowController.maximumPageHeight },
              "tallest \(Int(heights.max() ?? 0)) of \(Int(FeatureTourWindowController.maximumPageHeight))")

        print("--- page 2: permissions, live ---")
        if let view = defaultViews[1] { assertPermissions(view) }
        print("--- page 6: local apps, live ---")
        if let view = defaultViews[5] { assertLocalApps(view) }
        print("--- page 3: the practice box (D9) ---")
        if let view = defaultViews[2] {
            assertPractice(view, note: FeatureTourPractice.relaunchNote, editable: false, label: "relaunch needed")
        }
        renderPracticeVariants(outDir: outDir)
        print("--- page 6 before the measurement lands ---")
        renderChecking(outDir: outDir)
        print("--- pages 1 and 6 at the largest UI size ---")
        renderLargest(outDir: outDir, defaults: defaultViews)
        print("--- the stubs launched nothing ---")
        check("the only local measurements were the stub's", measurements >= 1, "\(measurements) stub call(s)")
    }

    private static func name(_ pages: [FeatureTourPage], _ index: Int) -> String {
        String(format: "tour-page-%02d-", index + 1) + pages[index].id
    }

    /// Borderless host windows, held for the gate's lifetime: a host released mid-render takes the hierarchy
    /// being photographed with it.
    private static var hosts: [NSWindow] = []

    /// The page in a window, as in the app, so its controls draw as they do on screen and colour resolution has a
    /// window to start from. No backdrop is added: the page paints its own opaque phosphor panel, and a capture
    /// that came out transparent would be a page that stopped doing so.
    private static func hosted(_ view: FeatureTourPageView) -> FeatureTourPageView {
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        hosts.append(host)
        return view
    }

    /// The light pass's pixels, by PNG name, compared with the dark pass's.
    private static var lightRenders: [String: SelfTestRenderCapture.Pixels] = [:]

    /// Writes `<name>-<pass>.png` (and `<name>.png` on the dark pass), then judges what was written: opaque,
    /// every piece of text visible, every dot there.
    private static func photograph(_ view: FeatureTourPageView, index: Int, pages: [FeatureTourPage], name: String,
                                   outDir: String) {
        let path = outDir + "/\(name)-\(pass.rawValue).png"
        let rep = SelfTestRenderCapture.capture(view, to: path, name: "\(name)-\(pass.rawValue)",
                                                report: { check($0, $1, $2) })
        if pass == .dark {
            let stable = outDir + "/\(name).png"
            try? FileManager.default.removeItem(atPath: stable)
            do { try FileManager.default.copyItem(atPath: path, toPath: stable) }
            catch { check("[\(name)] the stable-named PNG is written", false, error.localizedDescription) }
        }
        let pixels = rep.flatMap { SelfTestRenderCapture.Pixels($0, of: view) }
        check("[\(name)] draws in the tour's own dark appearance, whatever the system's",
              view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
              view.effectiveAppearance.name.rawValue)
        let opaque = pixels.map(opaqueProblems) ?? ["no pixels"]
        check("[\(name)] the capture is opaque, as the window is", opaque.isEmpty, opaque.joined(separator: "; "))
        switch pass {
        case .light:
            lightRenders[name] = pixels
        case .dark:
            if let light = lightRenders[name], let pixels {
                let differing = pixels.fractionDiffering(from: light)
                check("[\(name)] looks the same under the light and the dark system appearance", differing <= 0.001,
                      String(format: "%.4f of pixels differ", differing))
            } else {
                check("[\(name)] looks the same under the light and the dark system appearance", false,
                      "no light render to compare")
            }
        }
        let bodies = SelfTestRenderCapture.allViews(in: view).compactMap { candidate -> NSTextField? in
            guard let id = candidate.identifier?.rawValue, id.hasPrefix("feature-tour-body-") else { return nil }
            return candidate as? NSTextField
        }
        check("[\(name)] has body text, and no body line is empty",
              !bodies.isEmpty && bodies.allSatisfy { !$0.stringValue.trimmingCharacters(in: .whitespaces).isEmpty },
              "\(bodies.count) line(s)")
        let title = titleProblems(in: view, pixels: pixels)
        check("[\(name)] the page title is there, non-empty, and visible (\(minimumTextContrast):1, colours and "
                + "pixels)", title.isEmpty, title.joined(separator: "; "))
        let text = labelProblems(in: view)
        check("[\(name)] every label is visible (\(minimumTextContrast):1 by colour resolution)",
              text.problems.isEmpty, text.problems.isEmpty ? text.summary : text.problems.joined(separator: "; "))
        let buttons = buttonProblems(in: view, pixels: pixels)
        check("[\(name)] every button title is non-empty and visible against its bezel (\(minimumTextContrast):1, "
                + "pixels)", buttons.problems.isEmpty,
              buttons.problems.isEmpty ? buttons.summary : buttons.problems.joined(separator: "; "))
        let dots = dotProblems(in: view, pixels: pixels, expected: pages.count, current: index)
        check("[\(name)] shows \(pages.count) page dots, page \(index + 1) the distinct one", dots.isEmpty,
              dots.joined(separator: "; "))
    }

    // MARK: - one page

    private static func assertPage(_ view: FeatureTourPageView, index: Int, of pages: [FeatureTourPage],
                                   map: HotkeyMap, label: String) {
        let page = pages[index]
        view.layoutSubtreeIfNeeded()
        let title = SelfTestRenderCapture.label(ID.title, in: view)?.stringValue
        let body = page.renderedBody(map: map).indices.map {
            SelfTestRenderCapture.label(ID.body($0), in: view)?.stringValue ?? "missing"
        }
        check("[\(label)] the title and every body line reached the page, chords filled in",
              title == page.title && body == page.renderedBody(map: map) && !body.joined().contains("{"))

        let next = SelfTestRenderCapture.find(ID.next, in: view) as? NSButton
        let back = SelfTestRenderCapture.find(ID.back, in: view) as? NSButton
        let skip = SelfTestRenderCapture.find(ID.skip, in: view) as? NSButton
        let dots = SelfTestRenderCapture.find(ID.dots, in: view)
        let last = index == pages.count - 1
        check("[\(label)] the footer has Back, \(last ? "Done" : "Next"), Skip tour and the dots",
              next?.title == (last ? FeatureTour.doneTitle : FeatureTour.nextTitle)
                && back?.title == FeatureTour.backTitle && back?.isEnabled == (index > 0)
                && skip?.title == FeatureTour.skipTitle && dots != nil)
        if let next {
            let footerParts: Set<String> = [ID.next, ID.back, ID.skip, ID.dots]
            let contentBottom = view.subviews
                .filter { !($0 is NSBox) && !footerParts.contains($0.identifier?.rawValue ?? "") }
                .map(\.frame.maxY).max() ?? 0
            check("[\(label)] the footer sits below everything on the page", contentBottom + 14 <= next.frame.minY,
                  "content ends \(Int(contentBottom)), footer at \(Int(next.frame.minY))")
        }

        let link = SelfTestRenderCapture.find(ID.openSetting, in: view) as? NSButton
        check("[\(label)] the Settings link is there exactly when the page has one",
              link?.title == page.settingsLink.map(FeatureTour.settingsButtonTitle))
        let chords = page.commands.map {
            SelfTestRenderCapture.label(ID.chord($0), in: view)?.stringValue ?? "missing"
        }
        check("[\(label)] the keys card draws each chord from the map",
              chords == page.commands.map { FeatureTour.chordLabel($0, map: map) }, chords.joined(separator: " "))
        assertNotClipped(in: view, label: label)
    }

    /// No text may be shorter or narrower than what it was given. Measured after the layout pass AppKit runs before
    /// any draw, so a field is measured at the frame it is drawn at (the S3c lesson), and the owner is named by the
    /// nearest identified ancestor.
    private static func assertNotClipped(in view: NSView, label: String) {
        view.layoutSubtreeIfNeeded()
        var clipped: [String] = []
        for candidate in SelfTestRenderCapture.allViews(in: view) {
            guard let field = candidate as? NSTextField, !field.stringValue.isEmpty,
                  field.frame.width > 1, let cell = field.cell else { continue }
            let needed: CGFloat
            let has: CGFloat
            if cell.wraps {
                needed = field.attributedStringValue.boundingRect(
                    with: NSSize(width: field.frame.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                has = field.frame.height
            } else {
                needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude,
                                                         height: field.frame.height)).width
                has = field.frame.width
            }
            if has + 0.5 < needed {
                clipped.append("\(SelfTestRenderCapture.owner(of: field)) \"\(field.stringValue.prefix(24))\" needs "
                    + "\(Int(needed.rounded())) has \(Int(has.rounded()))")
            }
        }
        check("[\(label)] clips no text", clipped.isEmpty, clipped.joined(separator: "; "))
    }

    // MARK: - live rows

    private static func assertPermissions(_ view: FeatureTourPageView) {
        let words = SetupPermission.allCases.map {
            SelfTestRenderCapture.label(ID.permission($0), in: view)?.stringValue ?? "missing"
        }
        check("page 2 shows Microphone NEEDED, Accessibility and Input Monitoring GRANTED, in the permissions "
                + "screen's words",
              words == [PermissionsScreen.pendingText, PermissionsScreen.grantedText, PermissionsScreen.grantedText],
              words.joined(separator: ","))
    }

    private static func assertLocalApps(_ view: FeatureTourPageView) {
        let rows = LocalAppRows.build(presence: presence)
        let words = LocalAppRows.order.map {
            SelfTestRenderCapture.label(ID.localState($0), in: view)?.stringValue ?? "missing"
        }
        let statuses = LocalAppRows.order.map {
            SelfTestRenderCapture.label(ID.localStatus($0), in: view)?.stringValue ?? "missing"
        }
        check("page 6 shows LM Studio and Ollama in the Setup tab's own state words",
              words == rows.map(\.stateWord) && words == ["RUNNING", "NOT RUNNING"], words.joined(separator: ","))
        check("and the Setup tab's own status lines", statuses == rows.map(\.status),
              statuses.joined(separator: " | "))
    }

    private static func assertPractice(_ view: FeatureTourPageView, note: String, editable: Bool, label: String) {
        let shown = SelfTestRenderCapture.label(ID.practiceNote, in: view)?.stringValue
        let field = SelfTestRenderCapture.find(ID.practiceField, in: view) as? NSTextView
        check("[\(label)] the practice box says what to do, and is editable only when the tap is live",
              shown == note && field != nil && field?.isEditable == editable, shown ?? "missing")
    }

    private static func renderPracticeVariants(outDir: String) {
        let readyTour = controller(tapLive: true)
        let ready = hosted(readyTour.makePageView(2))
        assertPractice(ready, note: FeatureTourPractice.note(.ready, map: .defaults()), editable: true,
                       label: "tap live")
        assertNotClipped(in: ready, label: "tap live")
        photograph(ready, index: 2, pages: readyTour.pages, name: "tour-page-03-dictation-ready", outDir: outDir)

        let grantTour = controller(permissions: PermissionsStatus(microphone: true, accessibility: true,
                                                                  inputMonitoring: false))
        let grant = hosted(grantTour.makePageView(2))
        assertPractice(grant, note: FeatureTourPractice.note(.grantFirst, map: .defaults()), editable: false,
                       label: "grant first")
        assertNotClipped(in: grant, label: "grant first")
        photograph(grant, index: 2, pages: grantTour.pages, name: "tour-page-03-dictation-grant-first",
                   outDir: outDir)

        var map = HotkeyMap.defaults()
        map.assign(.regular(keyCode: 40, label: "K"), to: .command(.lock))
        let tour = controller(map: map)
        let rebound = hosted(tour.makePageView(2))
        assertPage(rebound, index: 2, of: tour.pages, map: map, label: "lock rebound to K")
        let body = (SelfTestRenderCapture.label(ID.body(0), in: rebound)?.stringValue ?? "")
        check("lock rebound to K: the page says K and never Space",
              SelfTestRenderCapture.label(ID.chord(.command(.lock)), in: rebound)?.stringValue == "K"
                && body.contains(" K ") && !body.contains("Space"), body)
        photograph(rebound, index: 2, pages: tour.pages, name: "tour-page-03-dictation-rebound", outDir: outDir)
    }

    private static func renderChecking(outDir: String) {
        let checkingTour = controller(answers: false)
        let view = hosted(checkingTour.makePageView(5))
        let words = LocalAppRows.order.map {
            SelfTestRenderCapture.label(ID.localState($0), in: view)?.stringValue ?? "missing"
        }
        check("before the measurement lands both apps read CHECKING", words == ["CHECKING", "CHECKING"],
              words.joined(separator: ","))
        assertNotClipped(in: view, label: "local apps checking")
        photograph(view, index: 5, pages: checkingTour.pages, name: "tour-page-06-local-models-checking",
                   outDir: outDir)
    }

    /// The app's only UI size settings are the HUD's (Appearance > UI SIZE). The tour must not change with them.
    private static func renderLargest(outDir: String, defaults: [Int: FeatureTourPageView]) {
        let snapshot = HUDDefaultsSnapshot()
        defer { snapshot.restore() }
        Settings.hudScale = Settings.hudScaleRange.upperBound
        Settings.hudPillScale = Settings.hudPillScaleRange.upperBound
        let tour = controller()
        for index in [0, 5] {
            let view = hosted(tour.makePageView(index))
            let label = name(tour.pages, index) + "-largest-ui"
            assertPage(view, index: index, of: tour.pages, map: .defaults(), label: label)
            check("[\(label)] lays out exactly as at the default size",
                  view.frame.size == defaults[index]?.frame.size,
                  "\(view.frame.size) vs \(defaults[index]?.frame.size ?? .zero)")
            photograph(view, index: index, pages: tour.pages, name: label, outDir: outDir)
        }
    }

    // MARK: - is it visible

    private static func ratio(_ value: CGFloat) -> String { String(format: "%.1f:1", value) }

    /// The capture's corners: a page photographed over its backdrop has no transparent pixel.
    private static func opaqueProblems(_ pixels: SelfTestRenderCapture.Pixels) -> [String] {
        let corners = [(0, 0), (pixels.width - 1, 0), (0, pixels.height - 1), (pixels.width - 1, pixels.height - 1)]
        let clear = corners.filter { pixels.alpha(x: $0.0, y: $0.1) < 1 }
        return clear.isEmpty ? [] : ["\(clear.count) of 4 corners transparent: the capture has no backdrop"]
    }

    /// (c) The title: there, non-empty, and 4.5:1 by colour resolution AND in the pixels. Each problem names the
    /// way it failed ("colours" or "pixels"), which the white-on-white negative control reads.
    private static func titleProblems(in view: NSView, pixels: SelfTestRenderCapture.Pixels?) -> [String] {
        guard let title = SelfTestRenderCapture.label(ID.title, in: view) else { return ["no title label"] }
        guard !title.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return ["the title is empty"] }
        var problems: [String] = []
        let byColour = SelfTestRenderCapture.textContrast(title)
        if byColour < minimumTextContrast { problems.append("title colours \(ratio(byColour))") }
        if let pixels {
            if let seen = pixels.textContrast(in: SelfTestRenderCapture.textRect(of: title), of: title) {
                if seen < minimumTextContrast { problems.append("title pixels \(ratio(seen))") }
            } else {
                problems.append("title pixels: the title is outside the capture")
            }
        } else {
            problems.append("title pixels: no capture")
        }
        return problems
    }

    /// (a) Every label with text, by colour resolution.
    private static func labelProblems(in view: NSView) -> (problems: [String], summary: String) {
        var problems: [String] = []
        var lowest: (CGFloat, String)?
        for case let field as NSTextField in SelfTestRenderCapture.allViews(in: view)
        where !field.isHidden && !field.stringValue.isEmpty && field.frame.width > 1 {
            let value = SelfTestRenderCapture.textContrast(field)
            let who = "\(SelfTestRenderCapture.owner(of: field)) \"\(field.stringValue.prefix(24))\""
            if value < minimumTextContrast { problems.append("\(who) \(ratio(value))") }
            if lowest == nil || value < lowest!.0 { lowest = (value, who) }
        }
        let summary = lowest.map { "lowest \(ratio($0.0)): \($0.1)" } ?? "no labels"
        return (problems, summary)
    }

    /// (a) Every button: a title, and 4.5:1 against its bezel in the pixels. Disabled buttons are exempt from the
    /// ratio (WCAG 1.4.3 exempts inactive controls), not from having a title.
    private static func buttonProblems(in view: NSView, pixels: SelfTestRenderCapture.Pixels?)
        -> (problems: [String], summary: String) {
        var problems: [String] = []
        var seen: [String] = []
        for case let button as NSButton in SelfTestRenderCapture.allViews(in: view) where !button.isHidden {
            let who = SelfTestRenderCapture.owner(of: button)
            guard !button.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                problems.append("\(who) has no title")
                continue
            }
            guard let pixels else {
                problems.append("\(who) \"\(button.title)\": no capture")
                continue
            }
            guard let value = pixels.textContrast(in: SelfTestRenderCapture.titleRect(of: button), of: button) else {
                problems.append("\(who) \"\(button.title)\" is outside the capture")
                continue
            }
            if button.isEnabled {
                if value < minimumTextContrast { problems.append("\"\(button.title)\" \(ratio(value))") }
                seen.append("\(button.title) \(ratio(value))")
            } else {
                seen.append("\(button.title) \(ratio(value)) (disabled, exempt)")
            }
        }
        return (problems, seen.joined(separator: ", "))
    }

    /// (d) The dots: the view says `expected` with `current` lit, AND the pixels show `expected` separate dots
    /// along the strip's middle row at 3:1 against the backdrop, the current one a different colour from the
    /// rest. The S7 capture fails here: its ten unlit dots were white on transparency, so only the green one showed.
    private static func dotProblems(in view: NSView, pixels: SelfTestRenderCapture.Pixels?, expected: Int,
                                    current: Int) -> [String] {
        guard let dots = SelfTestRenderCapture.find(ID.dots, in: view) as? FeatureTourDotsView else {
            return ["no page dots"]
        }
        var problems: [String] = []
        if dots.count != expected { problems.append("the strip has \(dots.count) dots for \(expected) pages") }
        if dots.current != current { problems.append("dot \(dots.current + 1) is lit on page \(current + 1)") }
        guard let pixels else { return problems + ["no capture"] }
        // Six points of backdrop either side of the strip, then its middle row, left to right.
        guard let strip = pixels.bounds(of: dots.bounds.insetBy(dx: -6, dy: 0), in: dots) else {
            return problems + ["the dots are outside the capture"]
        }
        let row = (strip.y0 + strip.y1) / 2
        let backdrop = pixels.rgb(x: strip.x0, y: row)
        var runs: [SelfTestRenderCapture.RGB] = []
        var inDot = false
        var runStart = 0
        for x in strip.x0..<strip.x1 {
            let lit = SelfTestRenderCapture.contrast(pixels.rgb(x: x, y: row), backdrop) >= minimumDotContrast
            if lit && !inDot { runStart = x }
            if !lit && inDot { runs.append(pixels.rgb(x: (runStart + x - 1) / 2, y: row)) }
            inDot = lit
        }
        if inDot { runs.append(pixels.rgb(x: (runStart + strip.x1 - 1) / 2, y: row)) }
        guard runs.count == expected else {
            return problems + ["\(runs.count) of \(expected) dots visible at \(Int(minimumDotContrast)):1"]
        }
        let lit = runs[current]
        let others = runs.enumerated().filter { $0.offset != current }.map(\.element)
        if let closest = others.map({ $0.distance(to: lit) }).min(), closest < 0.25 {
            problems.append("the current dot is not distinct (colour distance \(String(format: "%.2f", closest)))")
        }
        if let first = others.first, let spread = others.map({ $0.distance(to: first) }).max(), spread > 0.12 {
            problems.append("the other dots are not alike (colour spread \(String(format: "%.2f", spread)))")
        }
        return problems
    }

    // MARK: - negative controls

    /// (e) Each mutant must FAIL the check it targets; a mutant that passes means the check cannot see the bug,
    /// and the gate fails. Mutants are judged, never written to `<outdir>`, so no mutant PNG is mistaken for a page.
    private static func negativeControls() {
        pass = .dark
        NSApplication.shared.appearance = Pass.dark.appearance
        let tour = controller()

        // An empty page: the ink check.
        let size = tour.makePageView(0).frame.size
        let empty = FlippedSectionView(frame: NSRect(origin: .zero, size: size))
        let emptyInk = SelfTestRenderCapture.render(empty).map(SelfTestRenderCapture.inkFraction) ?? 0
        check("negative control: an empty page of the same size fails the ink check", emptyInk <= 0.01,
              "ink=\(String(format: "%.3f", emptyInk))")

        // White title on a white page: the title check, by colour resolution AND by pixels.
        let whiteOnWhite = hosted(tour.makePageView(0))
        whiteOnWhite.layer?.backgroundColor = NSColor.white.cgColor
        if let title = SelfTestRenderCapture.label(ID.title, in: whiteOnWhite) {
            title.textColor = .white
            title.attributedStringValue = NSAttributedString(string: title.stringValue, attributes: [
                .foregroundColor: NSColor.white,
                .font: title.font ?? NSFont.systemFont(ofSize: 18),
            ])
        }
        let mutantPixels = SelfTestRenderCapture.render(whiteOnWhite)
            .flatMap { SelfTestRenderCapture.Pixels($0, of: whiteOnWhite) }
        let mutantTitle = titleProblems(in: whiteOnWhite, pixels: mutantPixels)
        check("negative control: a white title on a white page fails the title check by colour resolution",
              mutantTitle.contains { $0.hasPrefix("title colours") }, mutantTitle.joined(separator: "; "))
        check("negative control: ... and by pixels", mutantTitle.contains { $0.hasPrefix("title pixels") },
              mutantTitle.joined(separator: "; "))
        let mutantLabels = labelProblems(in: whiteOnWhite).problems
        check("negative control: ... and the every-label check names it",
              mutantLabels.contains { $0.hasPrefix(ID.title) }, mutantLabels.joined(separator: "; "))

        // The S7 failure: a page drawn on nothing (page 2, which has the Settings link), no window, its panel fill
        // removed, so text and cells made for the dark panel land on transparency, which a viewer shows as white.
        let bare = tour.makePageView(1)
        bare.layer?.backgroundColor = nil
        let barePixels = SelfTestRenderCapture.render(bare).flatMap { SelfTestRenderCapture.Pixels($0, of: bare) }
        let bareTitle = titleProblems(in: bare, pixels: barePixels)
        check("negative control: a page drawn on nothing (the S7 failure) fails the title check in the pixels",
              bareTitle.contains { $0.hasPrefix("title pixels") }, bareTitle.joined(separator: "; "))
        let bareButtons = buttonProblems(in: bare, pixels: barePixels).problems
        check("negative control: ... fails the button check", !bareButtons.isEmpty,
              bareButtons.joined(separator: "; "))
        let bareDots = dotProblems(in: bare, pixels: barePixels, expected: tour.pages.count, current: 1)
        check("negative control: ... fails the dot check - its dots are drawn on nothing", !bareDots.isEmpty,
              bareDots.joined(separator: "; "))
        let bareOpaque = barePixels.map(opaqueProblems) ?? []
        check("negative control: ... and the opacity check", !bareOpaque.isEmpty, bareOpaque.joined(separator: "; "))

        // One dot where there should be eleven.
        let strip = FlippedSectionView(frame: NSRect(x: 0, y: 0, width: 620, height: 58))
        strip.appearance = FeatureTourWindowController.drawingAppearance
        let stripHost = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        stripHost.contentView?.addSubview(strip)
        hosts.append(stripHost)
        strip.wantsLayer = true
        strip.layer?.backgroundColor = FeatureTourWindowController.panelColor.cgColor
        let one = FeatureTourDotsView(count: 1, current: 0)
        one.identifier = NSUserInterfaceItemIdentifier(ID.dots)
        one.frame.origin = NSPoint(x: ((620 - one.frame.width) / 2).rounded(), y: 25)
        strip.addSubview(one)
        let stripPixels = SelfTestRenderCapture.render(strip).flatMap { SelfTestRenderCapture.Pixels($0, of: strip) }
        let oneDot = dotProblems(in: strip, pixels: stripPixels, expected: tour.pages.count, current: 0)
        check("negative control: a one-dot strip fails the dot check", !oneDot.isEmpty, oneDot.joined(separator: "; "))
    }
}
