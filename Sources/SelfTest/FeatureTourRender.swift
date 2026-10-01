import Cocoa

/// Offscreen render-to-PNG seam for the Feature Tour (`--feature-tour-render <outdir>`), G8.
///
/// In-process render, not a screen capture (screen capture from an agent shell is TCC-blocked), built through the
/// controller's own `makePageView(_:)` with every live fact stubbed: the hotkey map, the permissions, the hotkey
/// tap, and the local apps. The stubs answer from memory, so nothing is measured, started or opened.
///
/// PNGs written under `<outdir>`:
///   - `tour-page-01-welcome.png` ... `tour-page-11-staying-current.png` - every page at the default UI size.
///     Stubbed facts: Microphone not granted, Accessibility and Input Monitoring granted, no hotkey tap in this
///     launch (so page 3's practice box reads "Relaunch ViddyDictate, then try here."), LM Studio running with
///     two models and Ollama installed but not running.
///   - `tour-page-01-welcome-largest-ui.png`, `tour-page-06-local-models-largest-ui.png` - pages 1 and 6 with the
///     app's UI size settings (HUD and pill) at their largest. The tour has no size setting of its own, so these
///     must match the default layout point for point.
///   - `tour-page-03-dictation-ready.png` - the practice box live (tap installed), editable.
///   - `tour-page-03-dictation-grant-first.png` - Input Monitoring still off: grant first, then relaunch.
///   - `tour-page-03-dictation-rebound.png` - lock rebound to K: the body and the keys card both say K.
///   - `tour-page-06-local-models-checking.png` - before the local apps measurement lands: CHECKING.
///
/// What a screenshot cannot assert, and this gate does: every page carries ink; no text is clipped or truncated
/// by its own frame (after the layout pass AppKit runs before a draw); every page has Back, Next (Done on the
/// last), Skip tour and the dots, below its content; all pages share one height that fits the window without
/// scrolling; and pages 2 and 6 show their live rows in the words of the surfaces they come from.
///
/// Negative control: an empty page of the same size must fail the ink check.
enum FeatureTourRenderCases {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " - \(detail)")")
        if !ok { failures += 1 }
    }

    private typealias ID = FeatureTourPageView.ID

    // MARK: - Stubbed facts (distinct values for distinct roles)

    private static let permissions = PermissionsStatus(microphone: false, accessibility: true, inputMonitoring: true)

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

    private static func controller(map: HotkeyMap = .defaults(),
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
        // Pinned, so a capture does not silently change meaning with whatever this Mac is set to.
        app.appearance = NSAppearance(named: .darkAqua)
        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[feature-tour-render] cannot create \(outDir): \(error)")
            return false
        }

        print("--- every page, default UI size ---")
        let tour = controller()
        var heights: [CGFloat] = []
        var defaultViews: [Int: FeatureTourPageView] = [:]
        for index in tour.pages.indices {
            let view = tour.makePageView(index)
            defaultViews[index] = view
            heights.append(view.frame.height)
            assertPage(view, index: index, of: tour.pages, map: .defaults(), label: name(tour.pages, index))
            capture(view, to: outDir + "/\(name(tour.pages, index)).png", name: name(tour.pages, index))
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
        print("--- negative control ---")
        negativeControl(size: defaultViews[0]?.frame.size ?? NSSize(width: 620, height: 520))

        print("[feature-tour-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    private static func name(_ pages: [FeatureTourPage], _ index: Int) -> String {
        String(format: "tour-page-%02d-", index + 1) + pages[index].id
    }

    private static func capture(_ view: NSView, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, to: path, name: name, report: { check($0, $1, $2) })
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
                var owner = field.identifier?.rawValue
                var ancestor: NSView? = field
                while owner == nil, let current = ancestor?.superview {
                    owner = current.identifier?.rawValue
                    ancestor = current
                }
                clipped.append("\(owner ?? "unidentified") \"\(field.stringValue.prefix(24))\" needs "
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
        let ready = controller(tapLive: true).makePageView(2)
        assertPractice(ready, note: FeatureTourPractice.note(.ready, map: .defaults()), editable: true,
                       label: "tap live")
        assertNotClipped(in: ready, label: "tap live")
        capture(ready, to: outDir + "/tour-page-03-dictation-ready.png", name: "practice ready")

        let grant = controller(permissions: PermissionsStatus(microphone: true, accessibility: true,
                                                              inputMonitoring: false)).makePageView(2)
        assertPractice(grant, note: FeatureTourPractice.note(.grantFirst, map: .defaults()), editable: false,
                       label: "grant first")
        assertNotClipped(in: grant, label: "grant first")
        capture(grant, to: outDir + "/tour-page-03-dictation-grant-first.png", name: "practice grant first")

        var map = HotkeyMap.defaults()
        map.assign(.regular(keyCode: 40, label: "K"), to: .command(.lock))
        let tour = controller(map: map)
        let rebound = tour.makePageView(2)
        assertPage(rebound, index: 2, of: tour.pages, map: map, label: "lock rebound to K")
        let body = (SelfTestRenderCapture.label(ID.body(0), in: rebound)?.stringValue ?? "")
        check("lock rebound to K: the page says K and never Space",
              SelfTestRenderCapture.label(ID.chord(.command(.lock)), in: rebound)?.stringValue == "K"
                && body.contains(" K ") && !body.contains("Space"), body)
        capture(rebound, to: outDir + "/tour-page-03-dictation-rebound.png", name: "lock rebound")
    }

    private static func renderChecking(outDir: String) {
        let view = controller(answers: false).makePageView(5)
        let words = LocalAppRows.order.map {
            SelfTestRenderCapture.label(ID.localState($0), in: view)?.stringValue ?? "missing"
        }
        check("before the measurement lands both apps read CHECKING", words == ["CHECKING", "CHECKING"],
              words.joined(separator: ","))
        assertNotClipped(in: view, label: "local apps checking")
        capture(view, to: outDir + "/tour-page-06-local-models-checking.png", name: "local apps checking")
    }

    /// The app's only UI size settings are the HUD's (Appearance > UI SIZE). The tour must not change with them.
    private static func renderLargest(outDir: String, defaults: [Int: FeatureTourPageView]) {
        let snapshot = HUDDefaultsSnapshot()
        defer { snapshot.restore() }
        Settings.hudScale = Settings.hudScaleRange.upperBound
        Settings.hudPillScale = Settings.hudPillScaleRange.upperBound
        let tour = controller()
        for index in [0, 5] {
            let view = tour.makePageView(index)
            let label = name(tour.pages, index) + "-largest-ui"
            assertPage(view, index: index, of: tour.pages, map: .defaults(), label: label)
            check("[\(label)] lays out exactly as at the default size",
                  view.frame.size == defaults[index]?.frame.size,
                  "\(view.frame.size) vs \(defaults[index]?.frame.size ?? .zero)")
            capture(view, to: outDir + "/\(label).png", name: label)
        }
    }

    // MARK: - negative control

    private static func negativeControl(size: NSSize) {
        let empty = FlippedSectionView(frame: NSRect(origin: .zero, size: size))
        empty.layoutSubtreeIfNeeded()
        empty.displayIfNeeded()
        guard let rep = empty.bitmapImageRepForCachingDisplay(in: empty.bounds) else {
            check("negative control: an empty page fails the ink check", false, "no bitmap rep")
            return
        }
        empty.cacheDisplay(in: empty.bounds, to: rep)
        let ink = SelfTestRenderCapture.inkFraction(rep)
        check("negative control: an empty page of the same size fails the ink check", ink <= 0.01,
              "ink=\(String(format: "%.3f", ink))")
    }
}
