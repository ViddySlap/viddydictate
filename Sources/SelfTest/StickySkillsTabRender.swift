import Cocoa

/// Offscreen render-to-PNG seam for the Sticky Skills Settings tab (`--sticky-skills-render <outdir>`).
///
/// It exists because S4 shipped a new Settings tab without the render gate its four siblings all have
/// (`--setup-render`, `--provider-onboarding-render`, `--models-power-render`, `--hotkeys-tab-render`), so
/// every assertion about this tab was SOURCE-LEVEL: `StickySkillSelfTest` checks that `SettingsWindow.swift`
/// *contains the string* `case .stickySkills: content = scrollWrap(buildStickySkillsContent())`, which proves
/// the code was written, not that it draws. "A Settings tab fails to render" is a named no-merge condition,
/// and until this gate existed nothing in the chain could see the tab at all.
///
/// Like its siblings this is an in-process render, NOT a screen capture (screen capture from an agent shell
/// is TCC-blocked), and every store it touches is an injected scratch store under a scratch root - it never
/// reads or writes `sticky-skills.json`, `custom-modes.json` or `models-power.json` in a real Application
/// Support directory.
///
/// Five states, driven through the tab's REAL AppKit actions rather than by writing files behind it, because
/// the add/remove card layout is the half S4 built and nothing has ever exercised:
///   - `stickyskills-tab-builtin-only.png`  - a fresh install: Note to Handoff alone, collapsed.
///   - `stickyskills-tab-added.png`         - straight after `+ Add new sticky skill`: the new card opens
///                                            EXPANDED with a status line, which is the tallest state a user
///                                            reaches by one click.
///   - `stickyskills-tab-two-skills.png`    - two collapsed cards, the ordinary steady state.
///   - `stickyskills-tab-both-expanded.png` - both cards' Advanced open: the worst case for height.
///   - `stickyskills-tab-after-remove.png`  - Remove clicked: back to the built-in alone.
/// plus per-card captures of the built-in and of a user skill collapsed and expanded.
///
/// Every capture is asserted non-blank by pixel metric AND re-read from disk and asserted to be exactly the
/// captured surface's own size, so neither an empty frame nor a truncated write can pass as a screenshot.
/// Consecutive whole-page captures are asserted to be different images, because a layer-backed subtree will
/// otherwise serve the second state out of the first state's cached contents and the blank detector cannot
/// see it.
///
/// The fit question the spec flagged ("check the new tab fits rather than assuming") is measured against the
/// REAL window: the tab is hosted in the production 700x680 geometry and compared with `NSTabView.contentRect`,
/// not against a number this file invented.
enum StickySkillsTabRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pin the appearance so a capture does not silently change meaning with whatever the host Mac is set
        // to. The app itself follows the system; only the render seam is pinned.
        app.appearance = NSAppearance(named: .darkAqua)

        let fm = FileManager.default
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[sticky-skills-render] cannot create \(outDir): \(error)")
            return false
        }
        let root = fm.temporaryDirectory
            .appendingPathComponent("viddydictate-sticky-skills-render-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            print("[sticky-skills-render] scratch setup failed: \(error.localizedDescription)")
            return false
        }
        defer { try? fm.removeItem(at: root) }

        // Injected scratch stores, every one of them. A default-constructed view would reach
        // `StickySkillStore.shared` / `CustomModeStore.shared` / `Settings.modelsPower`, i.e. THE LANDMINE
        // file. The catalog loaders are stubbed to nil so the render neither reads a Codex disk cache nor
        // asks LM Studio what is installed: a gate that varies with the machine's model roster is not a gate.
        let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("models-power.json"))
        let modes = CustomModeStore(url: root.appendingPathComponent("custom-modes.json"),
                                    routingStore: routing)
        let skills = StickySkillStore(url: root.appendingPathComponent("sticky-skills.json"))
        // Seed a SCRATCH stand-in for the adopted row the built-in points at, so the five states below render
        // the tab as it looks on a machine that has one. Nothing here reads the user's `custom-modes.json`: only
        // the id is shared, and it is the id the registry already adopts. The no-backing-mode variant is
        // rendered separately at the end.
        let adoptedMode = CustomMode(
            id: StickySkillRegistry.noteToHandoffCustomModeID,
            name: "Sticky Note to Handoff Prompt",
            chord: KeySpec.regular(keyCode: 47, label: "."),
            prompt: "Turn the note into a handoff brief. Keep every fact.",
            input: .selection,
            model: LLMProviderDefaults.testedBundle(
                for: .local, route: .custom(StickySkillRegistry.noteToHandoffCustomModeID))
                ?? .local("qwen/qwen3-coder-30b"),
            landing: .inPlace)
        do { try modes.upsert(adoptedMode) }
        catch {
            print("[sticky-skills-render] scratch backing mode failed: \(error.localizedDescription)")
            return false
        }
        let view = StickySkillsSettingsView(
            width: productionContentWidth, skillStore: skills, modeStore: modes,
            settingsStore: routing, codexCatalogLoader: { nil }, localCatalogLoader: { nil })
        // The tab's backdrop comes from the window in production - the scroll wrap has drawsBackground=false
        // by design. An offscreen `cacheDisplay` of the document view alone does not draw the window, so
        // without this every direct child of the tab (the "Sticky Skills" heading, the intro, the status
        // line, the section header, the Add button's title and the footer) renders light-on-transparent and
        // photographs as blank while the layer-backed cards photograph fine. Measured, not assumed: the first
        // run of this gate produced exactly that image. Supplying the window's own colour is the same
        // correction `ModelsPowerRender` makes before capturing a sheet's content view.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        guard let host = mountInProductionSettingsWindow(view) else { return false }
        let available = host.tabView.contentRect
        check("the tab is hosted in the real fixed Settings window, and it reports a usable content area",
              available.height > 0 && available.width > 0,
              "700x680 window -> tab content area \(fmt(available.width))x\(fmt(available.height))pt")

        // The geometry above is REPLICATED from SettingsWindow, so it has to be pinned to it: if the window
        // is resized or the tab re-wrapped and this gate is not updated, every fit number below silently
        // becomes a measurement of a window that no longer exists.
        let settingsSource = source("Sources/App/SettingsWindow.swift")
        check("this render measures against the geometry production actually uses",
              settingsSource.contains("let WIN = NSSize(width: 700, height: 680)")
                && settingsSource.contains(
                    "NSRect(x: 10, y: 50, width: WIN.width - 20, height: WIN.height - 62)")
                && settingsSource.contains("private let contentWidth: CGFloat = 640")
                && settingsSource.contains("StickySkillsSettingsView(width: contentWidth)")
                && settingsSource.contains(
                    "case .stickySkills: content = scrollWrap(buildStickySkillsContent())"))
        check("this render wraps the tab the way production's scrollWrap does",
              settingsSource.contains("sv.hasVerticalScroller = true")
                && settingsSource.contains("sv.hasHorizontalScroller = false")
                && settingsSource.contains("sv.autohidesScrollers = true")
                && settingsSource.contains("sv.documentView = content"))

        var measurements: [(String, CGFloat)] = []

        // ── State A: a fresh install. The store seeds the built-in, so this is what every user opens to.
        let builtInID = StickySkillRegistry.builtInSkillID
        check("a fresh Sticky Skills tab shows exactly the built-in, and it cannot be removed",
              cardIDs(in: view) == [builtInID]
                && button("sticky-skill-remove|\(builtInID)", in: view)?.isEnabled == false
                && button("sticky-skill-add", in: view)?.title == "+ Add new sticky skill")
        measurements.append(("built-in only", view.frame.height))
        capture(view, card: nil, to: outDir + "/stickyskills-tab-builtin-only.png", name: "built-in only")
        capture(view, card: "sticky-skill-card|\(builtInID)",
                to: outDir + "/stickyskills-card-builtin.png", name: "built-in card")

        // ── State B: the real `+ Add new sticky skill` action. Driving the BUTTON rather than calling
        // `StickySkillSettingsOperations.add` directly is the point: it is the production two-store create,
        // the expanded-card default and the status line, all on the path a user's click takes.
        button("sticky-skill-add", in: view)?.performClick(nil)
        let userID = cardIDs(in: view).first { $0 != builtInID }
        check("Add creates a second card through the production two-store path",
              cardIDs(in: view).count == 2 && userID != nil
                && skills.skills.count == 2 && modes.mode(id: userID ?? "") != nil,
              "skills=\(skills.skills.count) modes=\(modes.modes.count)")
        guard let userID else {
            print("[sticky-skills-render] Add produced no user skill; nothing further to render")
            return false
        }
        check("a user skill is removable where the built-in is not, and its Advanced opened on Add",
              button("sticky-skill-remove|\(userID)", in: view)?.isEnabled == true
                && button("sticky-skill-remove|\(builtInID)", in: view)?.isEnabled == false
                && find("sticky-skill-edit-prompt|\(userID)", in: view) != nil)
        check("the Add status line is on screen rather than swallowed",
              (find("sticky-skill-status", in: view) as? NSTextField)?
                  .stringValue.contains(StickySkillSettingsOperations.newSkillName) == true)
        measurements.append(("built-in + new skill (expanded, as Add leaves it)", view.frame.height))
        capture(view, card: nil, to: outDir + "/stickyskills-tab-added.png", name: "after Add")
        capture(view, card: "sticky-skill-card|\(userID)",
                to: outDir + "/stickyskills-card-user-advanced.png", name: "user card Advanced")
        check("the expanded user card carries the whole Advanced row, not a stub",
              find("sticky-skill-custom-model|\(userID)", in: view) != nil
                && find("sticky-skill-custom-effort|\(userID)", in: view) != nil
                && find("sticky-skill-save-custom|\(userID)", in: view) != nil)

        // ── State C: both collapsed. The ordinary two-card steady state, and the shape the add/remove
        // layout is judged on.
        button("sticky-skill-advanced|\(userID)", in: view)?.performClick(nil)
        check("every card carries its own name, output and route controls",
              [builtInID, userID].allSatisfy { id in
                  find("sticky-skill-name|\(id)", in: view) != nil
                      && find("sticky-skill-output|\(id)", in: view) != nil
                      && find("sticky-skill-provider|\(id)", in: view) != nil
                      && find("sticky-skill-model|\(id)", in: view) != nil
                      && find("sticky-skill-effort|\(id)", in: view) != nil
              })
        measurements.append(("built-in + one user skill, both collapsed", view.frame.height))
        capture(view, card: nil, to: outDir + "/stickyskills-tab-two-skills.png", name: "two skills")
        capture(view, card: "sticky-skill-card|\(userID)",
                to: outDir + "/stickyskills-card-user.png", name: "user card")

        // ── State D: both Advanced open. The tallest state this tab can reach with two skills, so it is the
        // one the fixed window has to survive.
        button("sticky-skill-advanced|\(builtInID)", in: view)?.performClick(nil)
        button("sticky-skill-advanced|\(userID)", in: view)?.performClick(nil)
        check("both cards can be expanded at once",
              find("sticky-skill-custom-model|\(builtInID)", in: view) != nil
                && find("sticky-skill-custom-model|\(userID)", in: view) != nil)
        measurements.append(("built-in + one user skill, both expanded", view.frame.height))
        capture(view, card: nil, to: outDir + "/stickyskills-tab-both-expanded.png", name: "both expanded")

        // Both fit checks belong HERE, while the view is still in its tallest state - measured after it has
        // shrunk again they would be measurements of a different page.
        //
        // Horizontal is the harder failure: `scrollWrap` has no horizontal scroller, so a card wider than the
        // window is simply cut off with no way to reach it.
        let widest = cards(in: view).map(\.frame.maxX).max() ?? 0
        check("nothing in the tab is clipped horizontally by the fixed window",
              view.frame.width <= host.scroll.contentSize.width + 0.5 && widest <= view.frame.width + 0.5,
              "content \(fmt(view.frame.width))pt, widest card edge \(fmt(widest))pt, "
                + "visible \(fmt(host.scroll.contentSize.width))pt")
        // Vertically the tall states overflow BY DESIGN - that is what `scrollWrap` is for. What must be true
        // is that the scroll seam can actually REACH the bottom: a document sized wrong stops short of its own
        // last row, and the tail is then unreachable rather than merely below the fold.
        checkTailIsReachable(view: view, scroll: host.scroll, available: available.height)

        // ── State E: Remove. The other half of the layout S4 built and nothing had run.
        button("sticky-skill-remove|\(userID)", in: view)?.performClick(nil)
        check("Remove takes the user skill, its backing mode and its card away, and leaves the built-in",
              cardIDs(in: view) == [builtInID] && skills.skills.count == 1
                && modes.mode(id: userID) == nil,
              "skills=\(skills.skills.count) modes=\(modes.modes.count)")
        measurements.append(("after Remove", view.frame.height))
        capture(view, card: nil, to: outDir + "/stickyskills-tab-after-remove.png", name: "after Remove")

        // Five whole-page captures of ONE view instance. Without a forced redraw a layer-backed subtree
        // serves later captures out of cached contents, and every file would be full of ink and identical.
        let pages = ["stickyskills-tab-builtin-only.png", "stickyskills-tab-added.png",
                     "stickyskills-tab-two-skills.png", "stickyskills-tab-both-expanded.png",
                     "stickyskills-tab-after-remove.png"]
        let bytes = pages.map { fileBytes(outDir + "/" + $0) }
        var distinct = true
        for i in bytes.indices {
            for j in bytes.indices where j > i {
                if bytes[i] == nil || bytes[i] == bytes[j] { distinct = false }
            }
        }
        check("the five states are five different images, not one state photographed five times", distinct)

        captureMissingBackingRecord(root: root, outDir: outDir)
        reportFit(measurements, available: available.height)

        print("[sticky-skills-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") -> \(outDir)")
        return failures == 0
    }

    // MARK: - the fresh-install variant

    /// The tab on a machine where the built-in's backing `CustomMode` does not exist.
    ///
    /// ORIGINALLY this reached that state by building a fresh `CustomModeStore`, because the repo seeded no
    /// task prompt for the built-in and a fresh store was therefore empty. **L7 then seeded it** (a fresh
    /// install used to fail outright on the first thing a new user would try), so a fresh store is no longer
    /// empty and that route to the state is gone. The test was left asserting a precondition its own fix had
    /// removed, and reddened the `gui` tier as a result.
    ///
    /// The assertion is KEPT rather than retired, because the state is still reachable on a real machine: a
    /// user can edit or corrupt `custom-modes.json`, or a sync can lose the row, and
    /// `StickySkillsSettingsView` still renders "Missing backing record" for exactly that case. Retiring the
    /// check would drop coverage of a graceful-degradation path that still exists in the product.
    ///
    /// So the state is now CONSTRUCTED deliberately - seed, then delete the backing row - instead of relying
    /// on an empty store. That keeps the assertion at full strength and makes it independent of whatever the
    /// seed does next.
    private static func captureMissingBackingRecord(root: URL, outDir: String) {
        let routing = ModelsPowerSettingsStore(url: root.appendingPathComponent("fresh-models-power.json"))
        let modes = CustomModeStore(url: root.appendingPathComponent("fresh-custom-modes.json"),
                                    routingStore: routing)
        // Construct the missing-backing-record state explicitly. `delete` is a no-op if the seed ever stops
        // creating this row, so this stays correct in both directions.
        try? modes.delete(id: StickySkillRegistry.builtInSkillID)
        let skills = StickySkillStore(url: root.appendingPathComponent("fresh-sticky-skills.json"))
        let view = StickySkillsSettingsView(
            width: productionContentWidth, skillStore: skills, modeStore: modes,
            settingsStore: routing, codexCatalogLoader: { nil }, localCatalogLoader: { nil })
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        guard let host = mountInProductionSettingsWindow(view) else { return }

        let builtInID = StickySkillRegistry.builtInSkillID
        button("sticky-skill-advanced|\(builtInID)", in: view)?.performClick(nil)
        let prompt = SelfTestRenderCapture.allViews(in: view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .first { $0.hasPrefix("Task prompt: ") } ?? ""
        check("with no backing mode the built-in card still draws, and says so instead of lying",
              modes.mode(id: builtInID) == nil
                && prompt == "Task prompt: Missing backing record"
                && button("sticky-skill-edit-prompt|\(builtInID)", in: view)?.isEnabled == false,
              prompt.isEmpty ? "no Task prompt row found" : prompt)
        capture(view, card: nil, to: outDir + "/stickyskills-tab-no-backing-mode.png",
                name: "no backing mode")
        let available = host.tabView.contentRect.height
        check("a fresh install's tab, built-in expanded, still fits the fixed window",
              view.frame.height <= available,
              "\(fmt(view.frame.height))pt content vs \(fmt(available))pt visible")
    }

    // MARK: - fit

    /// Scroll the live scroll seam to its end and assert the document's last row came into view. Called while
    /// the tab is in its tallest state, so `view.frame.height` is the height being tested.
    private static func checkTailIsReachable(view: NSView, scroll: NSScrollView, available: CGFloat) {
        let tallest = view.frame.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, tallest - available)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let visible = scroll.documentVisibleRect
        check("the tallest state's last row is reachable by scrolling, not stranded below the window",
              tallest > available && visible.maxY + 0.5 >= tallest,
              "content \(fmt(tallest))pt, visible \(fmt(available))pt, scrolled to"
                + " \(fmt(visible.origin.y))pt showing up to \(fmt(visible.maxY))pt")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Report every measured state's content height against the real window, and fail on the one height claim
    /// worth failing over.
    private static func reportFit(_ measurements: [(String, CGFloat)], available: CGFloat) {
        for (label, height) in measurements {
            print("  [fit] \(label): \(fmt(height))pt content vs \(fmt(available))pt visible"
                  + " -> \(height <= available ? "fits" : "scrolls (+\(fmt(height - available))pt)")")
        }
        // The state EVERY user lands on has to be readable without scrolling. If a fresh install already
        // overflows a fixed 680pt window, the tab is wrong; taller states are the scroll seam's job.
        let firstOpen = measurements.first?.1 ?? .greatestFiniteMagnitude
        check("the tab a fresh install opens fits the fixed 700x680 window with no scrolling",
              firstOpen <= available,
              "\(fmt(firstOpen))pt content vs \(fmt(available))pt visible")
    }

    // MARK: - production hosting

    private static let productionContentWidth: CGFloat = 640

    private struct Host {
        let window: NSWindow
        let tabView: NSTabView
        let scroll: NSScrollView
    }

    /// Rebuild the Settings window's own geometry around the tab: a 700x680 window, the same inset tab view,
    /// the same eight tabs (the tab bar's height is what the content area is missing, so the real tab set
    /// matters), and the same scroll wrap. Nothing is ever ordered front - this is offscreen, like the
    /// sibling gates.
    private static func mountInProductionSettingsWindow(_ content: NSView) -> Host? {
        let WIN = NSSize(width: 700, height: 680)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WIN),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ViddyDictate Settings"
        let root = NSView(frame: NSRect(origin: .zero, size: WIN))
        let tabView = NSTabView(frame: NSRect(x: 10, y: 50, width: WIN.width - 20, height: WIN.height - 62))
        tabView.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: productionContentWidth + 30, height: 480))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = content

        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.rawValue
            item.view = tab == .stickySkills ? scroll : NSView(frame: .zero)
            tabView.addTabViewItem(item)
        }
        root.addSubview(tabView)
        window.contentView = root
        tabView.selectTabViewItem(withIdentifier: SettingsTab.stickySkills.rawValue)
        root.layoutSubtreeIfNeeded()
        guard content.window != nil else {
            print("[sticky-skills-render] the tab never entered the window; cannot measure or capture")
            return nil
        }
        return Host(window: window, tabView: tabView, scroll: scroll)
    }

    // MARK: - helpers

    /// Capture, then re-read the written file and assert it is exactly the captured surface's own size. The
    /// shared seam proves the in-memory bitmap had ink; this proves the PNG on disk is that bitmap.
    private static func capture(_ view: NSView, card: String?, to path: String, name: String) {
        let target = card.flatMap { find($0, in: view) } ?? view
        SelfTestRenderCapture.capture(view, card: card, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
        guard let data = fileBytes(path), let written = NSBitmapImageRep(data: data) else {
            check("\(name) PNG reads back from disk", false, path)
            return
        }
        let scale = target.window?.backingScaleFactor ?? 1
        let expectedW = Int((target.bounds.width * scale).rounded())
        let expectedH = Int((target.bounds.height * scale).rounded())
        check("\(name) PNG on disk is exactly the surface it photographed",
              written.pixelsWide == expectedW && written.pixelsHigh == expectedH,
              "\(written.pixelsWide)x\(written.pixelsHigh) px, expected \(expectedW)x\(expectedH)"
                + " (\(fmt(target.bounds.width))x\(fmt(target.bounds.height))pt @\(fmt(scale))x)")
    }

    private static func cards(in root: NSView) -> [NSView] {
        SelfTestRenderCapture.allViews(in: root)
            .filter { $0.identifier?.rawValue.hasPrefix("sticky-skill-card|") == true }
    }

    private static func cardIDs(in root: NSView) -> [String] {
        cards(in: root).compactMap {
            $0.identifier?.rawValue.components(separatedBy: "|").last
        }
    }

    private static func button(_ id: String, in root: NSView) -> NSButton? {
        find(id, in: root) as? NSButton
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }

    private static func fileBytes(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    private static func source(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
