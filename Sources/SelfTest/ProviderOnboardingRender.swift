import Cocoa

/// Offscreen render-to-PNG seam for provider onboarding (`--provider-onboarding-render <outdir>`), the surface
/// item P9 builds for Public V1 spec W4.
///
/// Like the other capture gates this is an in-process render, NOT a screen capture (screen capture from an
/// agent shell is TCC-blocked), so the link that builds the surface can actually look at it. Every observation
/// is synthetic, which is what lets the "before" shot be a machine with one provider absent and the other
/// signed out - the exact pair W4 is about, and a state no real Mac would helpfully be in on demand.
///
/// PNGs written:
///   - `onboarding-mixed.png`     - Claude absent, Codex installed-but-signed-out: two different messages,
///                                  one connect button. This is the W4 answer, on screen.
///   - `onboarding-ready.png`     - after signing in: same surface, nothing offered.
///   - `first-run-warnings.png`   - the first-run window as a user with no provider sees it.
///   - `first-run-ready.png`      - the same window after Check again finds a provider.
///   - `setup-with-onboarding.png` - the Settings Setup tab hosting onboarding above the preflight rows.
///   - `setup-signed-in.png`      - the Setup tab with both providers connected: the two sign-in buttons
///                                  side by side, which is where the Codex button lives now (L4).
///
/// What a screenshot cannot assert, and this gate does: that the not-installed row has NO button while the
/// signed-out row does, that clicking a row's button hands back THAT row's provider, that the two providers'
/// buttons match in size and position and neither title is clipped, that a connected Claude row does not
/// offer a "Reconnect" its flow refuses to perform (D3), that Check again re-MEASURES rather than
/// re-rendering, and that driving the whole flow writes no durable Models & Power preference (locked
/// decision 5).
enum ProviderOnboardingRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    // MARK: - Fixtures

    /// Claude not installed, Codex installed but signed out, and nothing else running: the two W4 states side by
    /// side, on the machine that actually triggers first-run onboarding.
    private static var mixed: [LLMProvider: LLMProviderDetection.Presence] {
        [.claude: .init(installed: false, state: .unavailable("CLI unavailable")),
         .codex: .init(installed: true, state: .disconnected),
         .local: .init(installed: false, state: .unavailable("LM Studio is not installed"))]
    }

    /// The same two cloud states with LM Studio running. Captured separately because it is the case that
    /// reshaped this surface: the transforms already work, so onboarding must say signing in is optional rather
    /// than tell the user to fix something. It is also why nothing here may count Local as satisfying
    /// onboarding - P6 recorded that Local availability is never written, so a Local row would read available on
    /// every machine.
    private static var localRunning: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = mixed
        providers[.local] = .init(installed: true, state: .available)
        return providers
    }

    /// One signed in, the other still signed out - the realistic state after a first sign-in, and the one that
    /// proves a row loses its own button without taking the other row's away (locked decision 3: one is enough,
    /// but the second is still offered).
    private static var oneSignedIn: [LLMProvider: LLMProviderDetection.Presence] {
        [.claude: .init(installed: true, state: .available),
         .codex: .init(installed: true, state: .disconnected),
         .local: .init(installed: true, state: .available)]
    }

    private static var bothSignedIn: [LLMProvider: LLMProviderDetection.Presence] {
        [.claude: .init(installed: true, state: .available),
         .codex: .init(installed: true, state: .available),
         .local: .init(installed: true, state: .available)]
    }

    private static func observation(_ providers: [LLMProvider: LLMProviderDetection.Presence])
        -> PreflightObservation {
        var o = PreflightSelfTest.broken
        o.providers = providers
        return o
    }

    // MARK: - Run

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pin the appearance so a capture does not silently change meaning with whatever the host Mac is set
        // to. The app itself follows the system; only the render seam is pinned.
        app.appearance = NSAppearance(named: .darkAqua)
        Settings.registerDefaults()

        let fm = FileManager.default
        do { try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[provider-onboarding-render] cannot create \(outDir): \(error)")
            return false
        }

        // Force the shared store to exist BEFORE anything is driven, so the durable-write guard below compares
        // two real files rather than two absences.
        _ = Settings.modelsPower.routeIDs()
        let durablePath = AppPaths.applicationSupportDirectory()
            .appendingPathComponent("models-power.json", isDirectory: false)
        let durableBefore = try? Data(contentsOf: durablePath)
        check("the durable Models & Power file exists before the drive, so the guard means something",
              durableBefore != nil, durablePath.path)

        driveRows(outDir: outDir)
        driveFirstRunWindow(outDir: outDir)
        driveSetupTab(outDir: outDir)

        let durableAfter = try? Data(contentsOf: durablePath)
        check("driving onboarding writes no durable Models & Power preference",
              durableAfter == durableBefore,
              "\(durableBefore?.count ?? -1) -> \(durableAfter?.count ?? -1) bytes")

        print("[provider-onboarding-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - The rows themselves

    /// The shared view, driven directly. The click assertion lives here rather than on either host because the
    /// hosts wire the click to `ProviderSignInPresenter`, which presents a vendor sheet - and a modal sheet in
    /// a headless gate would hang it rather than fail it.
    private static func driveRows(outDir: String) {
        let view = ProviderOnboardingView(width: 560)
        var clicked: [LLMProvider] = []
        view.onConnect = { clicked.append($0) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 900),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        // Captured on its own, this view has neither the tab backdrop nor a layer, and the mixed
        // layer-backed/unlayered hierarchy renders a bezelled control's title onto transparency - a button
        // comes out as a blank pill. Same artifact the other capture gates document.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Nothing measured yet: a surface with no reading must not look like a verdict.
        view.apply(nil)
        check("before any measurement the headline says it is still looking",
              label(ProviderOnboarding.headlineIdentifier, in: view)?.stringValue
                == ProviderOnboarding.checkingHeadline)
        check("before any measurement no provider row is on screen",
              ProviderOnboarding.providers.allSatisfy {
                  find(ProviderOnboarding.cardIdentifier($0), in: view) == nil
              })

        let plan = ProviderOnboarding.plan(providers: mixed)
        view.apply(plan)
        assertRows(view, plan, state: "mixed")

        // The W4 assertion a screenshot cannot make for itself.
        check("[mixed] the not-installed provider is offered no button",
              find(ProviderOnboarding.identifier(.action, .claude), in: view) == nil)
        let connect = find(ProviderOnboarding.identifier(.action, .codex), in: view) as? NSButton
        check("[mixed] the installed-but-signed-out provider is offered one",
              connect != nil && connect?.title == ProviderOnboarding.actionTitle(.codex, .signedOut),
              connect?.title ?? "no button")
        check("[mixed] the two rows do not read the same",
              label(ProviderOnboarding.identifier(.opening, .claude), in: view)?.stringValue
                != label(ProviderOnboarding.identifier(.opening, .codex), in: view)?.stringValue)
        assertLayout(view, plan, state: "mixed")
        SelfTestRenderCapture.capture(view, to: outDir + "/onboarding-mixed.png", name: "mixed rows",
                                      report: check)

        connect?.performClick(nil)
        check("clicking a row's button hands back that row's provider, once",
              clicked == [.codex], clicked.map(\.rawValue).joined(separator: ","))

        let after = ProviderOnboarding.plan(providers: oneSignedIn)
        view.apply(after)
        assertRows(view, after, state: "satisfied")
        // L4/D3: the signed-in row keeps a button so the section does not go half-empty the moment one
        // provider works - but it must not promise a reconnect Claude's flow deliberately refuses to do.
        let connected = find(ProviderOnboarding.identifier(.action, .claude), in: view) as? NSButton
        check("[satisfied] the provider that just signed in keeps a button, for visual parity",
              connected != nil, connected?.title ?? "no button")
        check("[satisfied] the signed-in Claude button is not labelled Reconnect",
              connected?.title == ProviderOnboarding.actionTitle(.claude, .ready)
                && connected?.title.lowercased().contains("reconnect") == false,
              connected?.title ?? "no button")
        check("[satisfied] the other provider keeps its own, because one is enough but not exclusive",
              find(ProviderOnboarding.identifier(.action, .codex), in: view) != nil)
        check("[satisfied] no stale reason line survives the re-render",
              LLMProvider.allCases.allSatisfy {
                  find(ProviderOnboarding.identifier(.detail, $0), in: view) == nil
              })
        assertLayout(view, after, state: "satisfied")
        SelfTestRenderCapture.capture(view, to: outDir + "/onboarding-ready.png", name: "satisfied rows",
                                      report: check)

        // The same two cloud rows on a machine whose transforms already run locally. Nothing is missing, so the
        // headline must not tell the user to fix anything - the row buttons stay, because a cloud provider is
        // still the V1 baseline.
        let local = ProviderOnboarding.plan(providers: localRunning)
        view.apply(local)
        assertRows(view, local, state: "local-running")
        check("[local-running] the headline says signing in is optional rather than required",
              label(ProviderOnboarding.headlineIdentifier, in: view)?.stringValue
                == ProviderOnboarding.headline(local)
                && ProviderOnboarding.headline(local).contains("optional"))
        check("[local-running] the sign-in button is still offered for the installed provider",
              find(ProviderOnboarding.identifier(.action, .codex), in: view) != nil)
        assertLayout(view, local, state: "local-running")
        SelfTestRenderCapture.capture(view, to: outDir + "/onboarding-local-running.png",
                                      name: "local-running rows", report: check)
        view.removeFromSuperview()
    }

    // MARK: - The first-run window

    private static func driveFirstRunWindow(outDir: String) {
        var providers = mixed
        var calls = 0
        var measured: [ProviderOnboarding.Plan] = []
        let controller = ProviderOnboardingWindowController { completion in
            calls += 1
            completion(observation(providers))
        }
        controller.onMeasured = { measured.append($0) }

        let content = controller.makeContentView()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 1000),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(content)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        controller.check()
        check("the first-run window measures once when it is shown", calls == 1, "calls=\(calls)")
        // The window is only ever shown on a machine where something IS missing, so the capture below has to be
        // that machine - a capture of a state the window cannot be in would look right and prove nothing.
        check("the captured state is one that actually triggers the first-run window",
              ProviderOnboarding.shouldPresentFirstRun(
                hasEverBeenSatisfied: false, plan: ProviderOnboarding.plan(providers: providers)))
        check("the measurement is reported to the caller so it can be persisted",
              measured.count == 1 && measured.last?.isSatisfied == false)
        let recheck = find(ProviderOnboarding.recheckIdentifier, in: content) as? NSButton
        check("Check again is offered once a measurement has finished", recheck?.isEnabled == true)
        check("the window offers a way to leave without signing in, per W5",
              (find(ProviderOnboarding.dismissIdentifier, in: content) as? NSButton)?.title
                == "Start dictating")
        check("the window carries the standing copy the Setup tab does not repeat",
              label(ProviderOnboarding.subtitleIdentifier, in: content)?.stringValue
                == ProviderOnboarding.subtitle
                && label(ProviderOnboarding.footerIdentifier, in: content)?.stringValue
                == ProviderOnboarding.footer)
        assertRows(content, ProviderOnboarding.plan(providers: providers), state: "first-run")
        assertWindowLayout(content, state: "first-run")
        SelfTestRenderCapture.capture(content, to: outDir + "/first-run-warnings.png",
                                      name: "first-run window", report: check)

        // Re-run against a machine that has since been signed in. Same window, same button, new reading. Both
        // providers on purpose, so the "after" capture is the finished state a user actually ends at.
        providers = bothSignedIn
        recheck?.performClick(nil)
        check("Check again measures the machine again rather than redrawing a cached verdict",
              calls == 2, "calls=\(calls)")
        check("the second measurement is reported as satisfied",
              measured.count == 2 && measured.last?.isSatisfied == true)
        check("a signed-in machine still shows both providers' buttons, in the same place as before",
              ProviderOnboarding.providers.allSatisfy {
                  find(ProviderOnboarding.identifier(.action, $0), in: content) != nil
              })
        check("no provider onboarding does not cover grows a button on a signed-in machine",
              find(ProviderOnboarding.identifier(.action, .local), in: content) == nil)
        check("neither signed-in button offers to sign the user in again where that would cost them",
              (find(ProviderOnboarding.identifier(.action, .claude), in: content) as? NSButton)?.title
                == ProviderOnboarding.actionTitle(.claude, .ready)
                && (find(ProviderOnboarding.identifier(.action, .codex), in: content) as? NSButton)?.title
                == ProviderOnboarding.actionTitle(.codex, .ready))
        assertRows(content, ProviderOnboarding.plan(providers: providers), state: "first-run-ready")
        assertWindowLayout(content, state: "first-run-ready")
        SelfTestRenderCapture.capture(content, to: outDir + "/first-run-ready.png",
                                      name: "first-run window (ready)", report: check)
        content.removeFromSuperview()
    }

    // MARK: - The Setup tab hosting both surfaces

    private static func driveSetupTab(outDir: String) {
        var clicked: [LLMProvider] = []
        let view = SetupSettingsView(width: 640) { completion in
            completion(observation(mixed))
        }
        view.onConnect = { clicked.append($0) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1600),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let plan = ProviderOnboarding.plan(providers: mixed)
        assertRows(view, plan, state: "setup tab")
        check("[setup tab] the preflight rows are still all present beside onboarding",
              PreflightCheck.allCases.allSatisfy {
                  find(PreflightSurface.cardIdentifier($0), in: view) != nil
              })
        check("[setup tab] the tab keeps its own preflight headline, not onboarding's",
              label(PreflightSurface.headlineIdentifier, in: view)?.stringValue
                == PreflightSurface.headline(Preflight.evaluate(observation(mixed))))
        check("[setup tab] onboarding does not repeat the tab's standing copy",
              label(ProviderOnboarding.subtitleIdentifier, in: view) == nil
                && label(ProviderOnboarding.footerIdentifier, in: view) == nil)

        // The onboarding cards and the preflight cards share one document view, so a layout mistake here shows
        // up as one landing on top of the other.
        let cards = (ProviderOnboarding.providers.compactMap {
            find(ProviderOnboarding.cardIdentifier($0), in: view)
        } + PreflightCheck.allCases.compactMap {
            find(PreflightSurface.cardIdentifier($0), in: view)
        }).sorted { $0.frame.minY < $1.frame.minY }
        check("[setup tab] every card is on the surface",
              cards.count == ProviderOnboarding.providers.count + PreflightCheck.allCases.count,
              "\(cards.count) cards")
        var overlapping: [String] = []
        for (previous, next) in zip(cards, cards.dropFirst())
        where next.frame.minY < previous.frame.maxY - 0.5 {
            overlapping.append(next.identifier?.rawValue ?? "?")
        }
        check("[setup tab] the onboarding cards and the preflight cards do not overlap",
              overlapping.isEmpty, overlapping.joined(separator: ","))
        let deepest = cards.map(\.frame.maxY).max() ?? 0
        check("[setup tab] the surface is tall enough to scroll to its last row",
              view.frame.height >= deepest,
              "height=\(Int(view.frame.height)) last card ends \(Int(deepest))")
        check("[setup tab] onboarding leads the tab, above the read-only checks",
              (find(ProviderOnboarding.cardIdentifier(.claude), in: view)?.frame.minY ?? .infinity)
                < (find(PreflightSurface.cardIdentifier(.sttDaemon), in: view)?.frame.minY ?? 0))

        (find(ProviderOnboarding.identifier(.action, .codex), in: view) as? NSButton)?.performClick(nil)
        check("[setup tab] the sign-in button reaches the host's flow",
              clicked == [.codex], clicked.map(\.rawValue).joined(separator: ","))

        SelfTestRenderCapture.capture(view, to: outDir + "/setup-with-onboarding.png",
                                      name: "setup tab", report: check)
        view.removeFromSuperview()
        driveSignedInSetupTab(outDir: outDir)
    }

    /// The state L4 is really about: a machine where BOTH providers work, so the Setup tab is the one place
    /// either of them is reached from. The Codex button that used to live on Models & Power is here now, the
    /// Claude button is beside it, and both hand their own provider to the same host flow.
    private static func driveSignedInSetupTab(outDir: String) {
        var clicked: [LLMProvider] = []
        let view = SetupSettingsView(width: 640) { completion in
            completion(observation(bothSignedIn))
        }
        view.onConnect = { clicked.append($0) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 1600),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let plan = ProviderOnboarding.plan(providers: bothSignedIn)
        assertRows(view, plan, state: "setup tab signed in")
        assertButtonParity(view, plan, state: "setup tab signed in")
        for provider in ProviderOnboarding.providers {
            let button = find(ProviderOnboarding.identifier(.action, provider), in: view) as? NSButton
            check("[setup tab signed in] \(provider.rawValue) has its button on the Setup tab",
                  button != nil, button?.title ?? "no button")
            button?.performClick(nil)
        }
        // One host, one flow, two providers: each button hands back its OWN provider, in row order.
        check("[setup tab signed in] each button reaches the one host flow with its own provider",
              clicked == ProviderOnboarding.providers,
              clicked.map(\.rawValue).joined(separator: ","))
        SelfTestRenderCapture.capture(view, to: outDir + "/setup-signed-in.png",
                                      name: "setup tab (both signed in)", report: check)
        view.removeFromSuperview()
    }

    // MARK: - Shared assertions

    /// Every row the plan describes is on screen, headed by its own product name, reading exactly what the
    /// pure layer says it should. This is what makes the PNG trustworthy: a capture alone cannot tell a correct
    /// row from a plausible one.
    private static func assertRows(_ view: NSView, _ plan: ProviderOnboarding.Plan, state: String) {
        check("[\(state)] the headline is the one the plan carries",
              label(ProviderOnboarding.headlineIdentifier, in: view)?.stringValue
                == ProviderOnboarding.headline(plan))

        var wrong: [String] = []
        for step in plan.steps {
            let provider = step.provider
            if find(ProviderOnboarding.cardIdentifier(provider), in: view) == nil {
                wrong.append("\(provider.rawValue).card")
                continue
            }
            if label(ProviderOnboarding.identifier(.status, provider), in: view)?.stringValue
                != step.situation.statusText { wrong.append("\(provider.rawValue).status") }
            if label(ProviderOnboarding.identifier(.title, provider), in: view)?.stringValue
                != step.title { wrong.append("\(provider.rawValue).title") }
            if label(ProviderOnboarding.identifier(.opening, provider), in: view)?.stringValue
                != step.opening { wrong.append("\(provider.rawValue).opening") }
            if label(ProviderOnboarding.identifier(.step, provider), in: view)?.stringValue
                != step.step { wrong.append("\(provider.rawValue).step") }
            // Present exactly when the step has one: a row that invented a reason line would be as wrong as
            // one that dropped it.
            if label(ProviderOnboarding.identifier(.detail, provider), in: view)?.stringValue
                != step.detail { wrong.append("\(provider.rawValue).detail") }
            let button = find(ProviderOnboarding.identifier(.action, provider), in: view) as? NSButton
            if (button?.title) != step.actionTitle { wrong.append("\(provider.rawValue).action") }
        }
        check("[\(state)] every row is on screen and every line of it is the plan's own",
              wrong.isEmpty, wrong.joined(separator: ","))
        check("[\(state)] no provider onboarding does not cover has a row",
              find(ProviderOnboarding.cardIdentifier(.local), in: view) == nil)
    }

    /// The layout claims a screenshot cannot make for itself: nothing is clipped by its own frame, the cards do
    /// not overlap, and the surface contains what it holds. The longest line here is a next step that wraps to
    /// three lines, and a clipped next step is not actionable.
    private static func assertLayout(_ view: NSView, _ plan: ProviderOnboarding.Plan, state: String) {
        var clipped: [String] = []
        for step in plan.steps {
            for part in [ProviderOnboarding.RowPart.opening, .detail, .step] {
                guard let field = label(ProviderOnboarding.identifier(part, step.provider), in: view)
                else { continue }
                let needed = field.sizeThatFits(
                    NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
                if field.frame.height + 0.5 < needed {
                    clipped.append("\(step.provider.rawValue).\(part.rawValue)")
                }
            }
        }
        check("[\(state)] no row's text is clipped by its own frame",
              clipped.isEmpty, clipped.joined(separator: ","))

        let cards = plan.steps.compactMap { find(ProviderOnboarding.cardIdentifier($0.provider), in: view) }
            .sorted { $0.frame.minY < $1.frame.minY }
        var overlapping = false
        for (previous, next) in zip(cards, cards.dropFirst())
        where next.frame.minY < previous.frame.maxY - 0.5 { overlapping = true }
        check("[\(state)] the rows do not overlap each other", !overlapping, "\(cards.count) cards")

        var short: [String] = []
        for card in cards {
            let contentBottom = card.subviews.map(\.frame.maxY).max() ?? 0
            if card.frame.height + 0.5 < contentBottom {
                short.append(card.identifier?.rawValue ?? "?")
            }
        }
        check("[\(state)] every card contains its own contents", short.isEmpty,
              short.joined(separator: ","))

        let deepest = cards.map(\.frame.maxY).max() ?? 0
        check("[\(state)] the surface is tall enough to reach its last row",
              view.frame.height >= deepest,
              "height=\(Int(view.frame.height)) last card ends \(Int(deepest))")

        assertButtonParity(view, plan, state: state)
    }

    /// L4's visual parity, as something a gate can hold: every provider's button is the same size and sits at
    /// the same place inside its own row, and no title outgrows that shared size. The buttons are fixed-size
    /// rather than sized to their own titles precisely so this can be asserted - a button that resized itself
    /// would drift by a few points per label change and nothing would notice.
    private static func assertButtonParity(_ view: NSView, _ plan: ProviderOnboarding.Plan, state: String) {
        let buttons = plan.steps.compactMap {
            find(ProviderOnboarding.identifier(.action, $0.provider), in: view) as? NSButton
        }
        guard !buttons.isEmpty else { return }
        let geometry = Set(buttons.map {
            "x\(Int($0.frame.origin.x))w\(Int($0.frame.width))h\(Int($0.frame.height))"
        })
        check("[\(state)] every provider's button is the same size, in the same place in its row",
              geometry.count == 1, geometry.sorted().joined(separator: " vs "))

        // "It fits" is the assertion because "it was clipped" is the failure a screenshot hides: a bezelled
        // button truncates its title silently.
        var clipped: [String] = []
        for button in buttons {
            let measure = NSButton(title: button.title, target: nil, action: nil)
            measure.bezelStyle = button.bezelStyle
            measure.font = button.font
            measure.sizeToFit()
            if measure.frame.width > button.frame.width { clipped.append(button.title) }
        }
        check("[\(state)] no button's title outgrows the shared button size",
              clipped.isEmpty, clipped.joined(separator: ","))
    }

    /// The window's own chrome: the button that leaves has to sit below the rows, not under them. The rows grow
    /// with their text, so a fixed offset would put the dismiss button behind a three-line card.
    private static func assertWindowLayout(_ content: NSView, state: String) {
        guard let dismiss = find(ProviderOnboarding.dismissIdentifier, in: content) else {
            check("[\(state)] the window has a dismiss button", false)
            return
        }
        let cards = ProviderOnboarding.providers
            .compactMap { find(ProviderOnboarding.cardIdentifier($0), in: content) }
        // The cards live inside the rows view, so compare in the window's own coordinates.
        let deepest = cards.map { $0.convert($0.bounds, to: content).maxY }.max() ?? 0
        check("[\(state)] the dismiss button sits below the last row rather than under it",
              dismiss.frame.minY >= deepest - 0.5,
              "button at \(Int(dismiss.frame.minY)), rows end \(Int(deepest))")
        check("[\(state)] the window content is tall enough to contain its own button",
              content.frame.height >= dismiss.frame.maxY,
              "height=\(Int(content.frame.height)) button ends \(Int(dismiss.frame.maxY))")
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }

    private static func label(_ id: String, in root: NSView) -> NSTextField? {
        SelfTestRenderCapture.label(id, in: root)
    }
}
