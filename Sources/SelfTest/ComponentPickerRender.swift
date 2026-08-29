import Cocoa

/// Offscreen render-to-PNG seam for the first-run component picker (`--component-picker-render <dir>`).
///
/// Like `--setup-render` and `--hud-render` this is an in-process render, NOT a screen capture, because
/// screen capture from an agent shell is TCC-blocked. It is the only way the link that builds this
/// surface can look at what it built.
///
/// It also does the thing a still image cannot do for itself. The claim the picker makes is that the
/// total is a READOUT of the boxes rather than a caption printed above them, and that the rows are a
/// readout of the machine rather than a table someone typed. So the checkboxes are clicked for real,
/// the total is read back at every stop, and the whole surface is rendered against four synthetic
/// machines that this Mac is not.
///
/// PNGs written:
///   - `picker-8gb.png` / `picker-16gb.png` / `picker-32gb.png` / `picker-64gb.png` - the same screen on
///     four machines, which is the proof B5's rows are measured rather than fixed.
///   - `picker-everything.png` - every row ticked on a machine that can run them, with the total moved.
///   - `picker-install-myself.png` - a row the user will install themselves: still chosen, no longer counted.
///   - `picker-already-installed.png` - a Mac that already has LM Studio and the email model.
///   - `picker-metered.png` - B18's amber line and the Wait for Wi-Fi button beside Continue.
///   - `picker-offline.png` - no route at all: said immediately, with Set up later, Continue disabled.
enum ComponentPickerRender {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  [\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " - \(detail)")")
        if !ok { failures += 1 }
    }

    /// The same measured kernel ratio the deterministic selftest synthesizes from; see its note.
    private static let wireFraction = 0.820

    private static func mac(_ gibibytes: Double, wiredGB: Double) -> ComponentPicker.MachineFacts {
        let physical = UInt64(gibibytes * 1_073_741_824)
        let limit = Double(physical) * wireFraction
        return ComponentPicker.MachineFacts(
            physicalBytes: physical,
            budgetBytes: UInt64(limit * SystemMemory.realFraction(
                forSliderPosition: Settings.modelMemoryBudgetSliderPosition)),
            maxBudgetBytes: UInt64(limit * SystemMemory.realFraction(
                forSliderPosition: Settings.modelMemoryBudgetSliderRange.upperBound)),
            wiredBytes: UInt64(wiredGB * 1_000_000_000))
    }

    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Pinned, so a capture does not silently change meaning with whatever this Mac is set to.
        app.appearance = NSAppearance(named: .darkAqua)

        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch {
            print("[component-picker-render] cannot create \(outDir): \(error)")
            return false
        }

        let machines: [(String, ComponentPicker.MachineFacts, String, String)] = [
            ("8gb", mac(8, wiredGB: 3), "TOO BIG", "TOO BIG"),
            ("16gb", mac(16, wiredGB: 3), "OPTIONAL", "TOO BIG"),
            ("32gb", mac(32, wiredGB: 4), "SELECTED", "OPTIONAL"),
            ("64gb", mac(64, wiredGB: 5), "SELECTED", "SELECTED"),
        ]
        var totals: [String] = []
        for (name, facts, gemmaWord, qwenWord) in machines {
            let view = build(facts: facts)
            check("[\(name)] the email row states this machine's own verdict",
                  word(.gemma, in: view) == gemmaWord, word(.gemma, in: view) ?? "missing")
            check("[\(name)] the cleanup row states this machine's own verdict",
                  word(.qwen, in: view) == qwenWord, word(.qwen, in: view) ?? "missing")
            assertLayout(view, state: name)
            let total = label(ComponentPicker.totalIdentifier, in: view)?.stringValue ?? ""
            totals.append("\(name)=\(total)")
            capture(view, to: outDir + "/picker-\(name).png", name: "picker on a \(name) Mac")
        }
        check("the four machines do not all read the same total, so the line is not a caption",
              Set(totals.map { $0.split(separator: "=").last.map(String.init) ?? "" }).count > 1,
              totals.joined(separator: " | "))

        driveWindowController()
        driveTicks(outDir: outDir)
        driveInstallChoice(outDir: outDir)
        driveDetectedMachine(outDir: outDir)
        driveNetwork(outDir: outDir)

        print("[component-picker-render] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    // MARK: - what Continue actually hands on

    /// The window controller is the only place a click becomes a plan, and it is where the picker meets
    /// L4's network gate. Driven here rather than left for the link that wires it into launch, because
    /// "Continue starts the download" and "Wait for Wi-Fi holds it and releases itself" are claims this
    /// surface makes, not claims about when the window appears.
    private static func driveWindowController() {
        let monitor = PickerMonitorStub()
        let controller = FirstRunSetupWindowController(
            facts: mac(64, wiredGB: 5),
            gate: NetworkDownloadGate(monitor: monitor))
        var plans: [ComponentPicker.InstallPlan] = []
        controller.onContinue = { plans.append($0) }
        // Only makeContentView: show() would build the window's own copy and leave this one stale, which
        // is exactly the bug this drive caught the first time it ran.
        let view = controller.makeContentView()
        monitor.emit(NetworkPathState(isSatisfied: true))

        (find(ComponentPicker.continueIdentifier, in: view) as? NSButton).map(fire)
        check("[continue] Continue on a clear path hands on a plan once",
              plans.count == 1, "\(plans.count)")
        check("[continue] the plan carries the engine's core plus what the machine pre-ticked",
              plans.first?.components == BootstrapInstallPlan.mandatoryCore
                && plans.first?.models == [LLMProviderDefaults.localEmailModelID,
                                           LLMProviderDefaults.localCleanupModelID]
                && plans.first?.lmStudio == true)

        // A hotspot: Wait for Wi-Fi must start nothing now and start it later without being pressed again.
        monitor.emit(NetworkPathState(isSatisfied: true, isExpensive: true))
        (find(ComponentPicker.waitForWiFiIdentifier, in: view) as? NSButton).map(fire)
        check("[continue] Wait for Wi-Fi starts nothing while the path is still expensive",
              plans.count == 1, "\(plans.count)")
        monitor.emit(NetworkPathState(isSatisfied: true))
        check("[continue] and releases the held queue on its own once the path clears",
              plans.count == 2, "\(plans.count)")

        // A dead path spends no retries and offers the way out immediately.
        monitor.emit(.unavailable)
        (find(ComponentPicker.continueIdentifier, in: view) as? NSButton).map(fire)
        check("[continue] a dead path hands on nothing rather than failing three times first",
              plans.count == 2, "\(plans.count)")
        check("[continue] and the screen says so where the amber line goes",
              label(ComponentPicker.networkNoteIdentifier, in: view)?.stringValue
                == NetworkPathCopy.noNetworkMessage)
    }

    /// A local stand-in for the Network framework. `NetworkPathSelfTest` keeps its own private one; this
    /// gate needs an AppKit-side monitor it can step through a sequence of paths, and reaching into that
    /// file's private type to save four lines would couple two gates that test different things.
    private final class PickerMonitorStub: NetworkPathMonitoring {
        var onChange: ((NetworkPathState) -> Void)?
        func start() {}
        func cancel() {}
        func emit(_ state: NetworkPathState) { onChange?(state) }
    }

    // MARK: - the total is a readout

    /// Click the boxes the way a mouse does and read the total back at every stop. A total that was a
    /// caption would sit still through all of this while every screenshot still looked correct.
    private static func driveTicks(outDir: String) {
        // A 32 GB Mac, because it is the only class where the user has a real override to make: the
        // email model is pre-ticked and the cleanup model is offered with its warning rather than
        // disabled. Starting from nothing also proves the total's floor is the mandatory core.
        let facts = mac(32, wiredGB: 4)
        let view = build(facts: facts, selection: ComponentPicker.Selection())
        var seen: [String] = []
        var wrong: [String] = []

        func total() -> String { label(ComponentPicker.totalIdentifier, in: view)?.stringValue ?? "" }
        func expected(_ selection: ComponentPicker.Selection) -> String {
            ComponentPicker.totalLine(ComponentPicker.rows(selection: selection, facts: facts,
                                                           environment: .init()))
        }

        seen.append(total())
        if total() != expected(.init()) { wrong.append("start") }

        var selection = ComponentPicker.Selection()
        for id in [ComponentPicker.RowID.gemma, .qwen] {
            guard let box = find(ComponentPicker.identifier(.tick, id), in: view) as? NSButton else {
                check("[ticks] the \(id.rawValue) row offers a checkbox", false)
                return
            }
            box.state = .on
            fire(box)
            selection.setTicked(id, true)
            if total() != expected(selection) { wrong.append("\(id.rawValue) on") }
            seen.append(total())
        }
        check("[ticks] the total tracks the boxes at every stop", wrong.isEmpty,
              wrong.joined(separator: ", "))
        check("[ticks] no two stops read the same, so the line is not a fixed caption",
              Set(seen).count == seen.count, seen.joined(separator: " | "))
        check("[ticks] ticking a model turns its runtime on rather than leaving a broken pick",
              (find(ComponentPicker.identifier(.tick, .lmStudio), in: view) as? NSButton)?.state == .on)
        // The locked row must still read as a component that is ON. A greyed-out name beside a green
        // SELECTED is the one combination that tells the user two different things at once.
        check("[ticks] the locked runtime row states its name in full colour and says why it is locked",
              label(ComponentPicker.identifier(.title, .lmStudio), in: view)?.textColor == .labelColor
                && label(ComponentPicker.identifier(.machineNote, .lmStudio), in: view)?.stringValue
                    == "Required by the models you picked.",
              label(ComponentPicker.identifier(.machineNote, .lmStudio), in: view)?.stringValue ?? "missing")
        check("[ticks] the fully-picked total names the row nobody has measured",
              total().hasSuffix(", plus LM Studio"), total())
        assertLayout(view, state: "everything")
        capture(view, to: outDir + "/picker-everything.png", name: "everything ticked")

        // And back off again, so the line is proven to move in both directions.
        if let box = find(ComponentPicker.identifier(.tick, .qwen), in: view) as? NSButton {
            box.state = .off
            fire(box)
        }
        selection.setTicked(.qwen, false)
        check("[ticks] unticking takes the bytes back out", total() == expected(selection), total())
    }

    private static func driveInstallChoice(outDir: String) {
        let facts = mac(64, wiredGB: 5)
        let view = build(facts: facts, selection: ComponentPicker.Selection(gemma: true, qwen: true))
        let before = label(ComponentPicker.totalIdentifier, in: view)?.stringValue ?? ""
        guard let control = find(ComponentPicker.identifier(.choice, .qwen), in: view)
            as? NSSegmentedControl else {
            check("[choice] a ticked third-party row offers both options (B4)", false)
            return
        }
        check("[choice] a ticked third-party row offers both options (B4)",
              control.segmentCount == 2 && control.label(forSegment: 0) == "Install it for me"
                && control.label(forSegment: 1) == "I'll install it myself")
        control.selectedSegment = 1
        fire(control)
        let after = label(ComponentPicker.totalIdentifier, in: view)?.stringValue ?? ""
        check("[choice] I'll install it myself keeps the row chosen",
              (find(ComponentPicker.identifier(.tick, .qwen), in: view) as? NSButton)?.state == .on)
        check("[choice] and takes its bytes out of the total", before != after,
              "\(before) -> \(after)")
        assertLayout(view, state: "install-myself")
        capture(view, to: outDir + "/picker-install-myself.png", name: "install it myself")
    }

    private static func driveDetectedMachine(outDir: String) {
        let environment = ComponentPicker.Environment(
            lmStudioInstalled: true,
            installedModelIDs: [LLMProviderDefaults.localEmailModelID])
        let view = build(facts: mac(64, wiredGB: 5), environment: environment)
        check("[detected] what is already installed says so instead of offering a download",
              word(.lmStudio, in: view) == "INSTALLED" && word(.gemma, in: view) == "INSTALLED")
        check("[detected] an installed row carries no checkbox to switch it off",
              find(ComponentPicker.identifier(.tick, .gemma), in: view) == nil)
        // The machine pre-ticks the cleanup model, so what this proves is narrower and more useful than
        // a fixed string: the two rows that are already on the Mac add nothing, and the LM Studio row
        // stops being an unmeasured addendum once it is detected.
        let expected = ComponentPicker.totalLine(
            ComponentPicker.rows(selection: ComponentPicker.defaultSelection(facts: mac(64, wiredGB: 5),
                                                                             environment: environment),
                                 facts: mac(64, wiredGB: 5), environment: environment))
        let shown = label(ComponentPicker.totalIdentifier, in: view)?.stringValue ?? "missing"
        check("[detected] the total charges only for what is actually missing",
              shown == expected && shown == "Total download: 18.9 GB", "\(shown) vs \(expected)")
        assertLayout(view, state: "already-installed")
        capture(view, to: outDir + "/picker-already-installed.png", name: "already installed")
    }

    // MARK: - B18

    private static func driveNetwork(outDir: String) {
        let hotspot = build(facts: mac(64, wiredGB: 5),
                            selection: ComponentPicker.Selection(gemma: true),
                            path: NetworkPathState(isSatisfied: true, isExpensive: true),
                            gateState: .meteredOrConstrained)
        let note = label(ComponentPicker.networkNoteIdentifier, in: hotspot)?.stringValue ?? ""
        check("[metered] the line names the user's actual situation and the real number",
              note.contains("hotspot") && note.contains("8.6 GB"), note)
        check("[metered] Wait for Wi-Fi appears beside Continue, not instead of it",
              find(ComponentPicker.waitForWiFiIdentifier, in: hotspot) != nil
                && (find(ComponentPicker.continueIdentifier, in: hotspot) as? NSButton)?.isEnabled == true)
        assertLayout(hotspot, state: "metered")
        capture(hotspot, to: outDir + "/picker-metered.png", name: "on a hotspot")

        let offline = build(facts: mac(64, wiredGB: 5),
                            path: .unavailable, gateState: .noNetwork)
        check("[offline] a dead path is said immediately rather than after three retries fail",
              label(ComponentPicker.networkNoteIdentifier, in: offline)?.stringValue
                == NetworkPathCopy.noNetworkMessage)
        check("[offline] Continue cannot start a download there is no route for",
              (find(ComponentPicker.continueIdentifier, in: offline) as? NSButton)?.isEnabled == false
                && find(ComponentPicker.setUpLaterIdentifier, in: offline) != nil)
        check("[offline] and Wait for Wi-Fi is not offered for a path that is not merely expensive",
              find(ComponentPicker.waitForWiFiIdentifier, in: offline) == nil)
        assertLayout(offline, state: "offline")
        capture(offline, to: outDir + "/picker-offline.png", name: "no network")

        let waiting = build(facts: mac(64, wiredGB: 5),
                            path: NetworkPathState(isSatisfied: true, isConstrained: true),
                            gateState: .waitingForWiFi)
        check("[waiting] a held queue promises to start on its own",
              label(ComponentPicker.networkNoteIdentifier, in: waiting)?.stringValue
                == NetworkPathCopy.waitingForWiFiMessage)
    }

    // MARK: - helpers

    private static func build(facts: ComponentPicker.MachineFacts,
                              selection: ComponentPicker.Selection? = nil,
                              environment: ComponentPicker.Environment = .init(),
                              path: NetworkPathState = NetworkPathState(isSatisfied: true),
                              gateState: NetworkDownloadGateState = .ready) -> ComponentPickerView {
        let view = ComponentPickerView(
            width: 620,
            selection: selection ?? ComponentPicker.defaultSelection(facts: facts,
                                                                     environment: environment),
            facts: facts, environment: environment, path: path, gateState: gateState)
        // Captured on its own the view has neither its window backdrop nor a layer, and that mixed
        // hierarchy renders a bezelled control's title onto transparency. Same artifact SetupRender
        // documents; the same fix.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: max(200, view.frame.height)),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        hosts.append(host)
        return view
    }

    /// Held for the lifetime of the gate: a borderless host window released mid-render takes the view
    /// hierarchy being photographed with it.
    private static var hosts: [NSWindow] = []

    private static func word(_ id: ComponentPicker.RowID, in view: NSView) -> String? {
        label(ComponentPicker.identifier(.status, id), in: view)?.stringValue
    }

    /// Nothing on this surface may be clipped by its own frame. A truncated consequence is one the user
    /// was not actually shown, which is the whole premise of B1's consented reduced state.
    private static func assertLayout(_ view: NSView, state: String) {
        var clipped: [String] = []
        for id in ComponentPicker.RowID.allCases {
            for part in [ComponentPicker.Part.detail, .consequence, .machineNote] {
                guard let field = label(ComponentPicker.identifier(part, id), in: view) else { continue }
                let needed = field.sizeThatFits(
                    NSSize(width: field.frame.width, height: .greatestFiniteMagnitude)).height
                if field.frame.height + 0.5 < needed { clipped.append("\(id.rawValue).\(part.rawValue)") }
            }
        }
        check("[\(state)] no row's text is clipped by its own frame", clipped.isEmpty,
              clipped.joined(separator: ","))

        var overflowing: [String] = []
        for id in ComponentPicker.RowID.allCases {
            guard let card = find(ComponentPicker.cardIdentifier(id), in: view) else {
                overflowing.append("\(id.rawValue) missing")
                continue
            }
            for child in card.subviews where child.frame.maxY > card.frame.height + 0.5
                || child.frame.maxX > card.frame.width + 0.5 {
                overflowing.append("\(id.rawValue)/\(child.identifier?.rawValue ?? "?")")
            }
        }
        check("[\(state)] nothing spills out of the card it belongs to", overflowing.isEmpty,
              overflowing.joined(separator: ","))

        // Nothing on this screen may sit on top of anything else. This check exists because the first
        // build of the footer laid the total BESIDE the buttons, and the moment a metered path added a
        // third button the total ran straight underneath it - a collision every card-level clipping
        // check passed cleanly through, and one no ink measurement can see.
        var collisions: [String] = []
        let siblings = view.subviews
        for (index, first) in siblings.enumerated() {
            for second in siblings.dropFirst(index + 1) {
                let overlap = first.frame.intersection(second.frame)
                guard overlap.width > 0.5, overlap.height > 0.5 else { continue }
                collisions.append("\(first.identifier?.rawValue ?? "?")/\(second.identifier?.rawValue ?? "?")")
            }
        }
        check("[\(state)] nothing on the screen overlaps anything else", collisions.isEmpty,
              collisions.joined(separator: ","))

        // B6 says the total sits above Continue. Asserted as geometry rather than trusted to the layout
        // code that just got this wrong.
        if let total = label(ComponentPicker.totalIdentifier, in: view) {
            let buttons = [ComponentPicker.continueIdentifier, ComponentPicker.waitForWiFiIdentifier,
                           ComponentPicker.setUpLaterIdentifier]
                .compactMap { find($0, in: view) }
            check("[\(state)] the running total is above every button, not beside one",
                  buttons.allSatisfy { total.frame.maxY <= $0.frame.minY + 0.5 },
                  "total maxY=\(total.frame.maxY)")
        }

        // Every row the picker knows about has to be on screen. A row that silently stopped rendering
        // is a component the user was never offered and will never know about.
        let missing = ComponentPicker.RowID.allCases.filter {
            find(ComponentPicker.cardIdentifier($0), in: view) == nil
        }
        check("[\(state)] every component has a row", missing.isEmpty,
              missing.map(\.rawValue).joined(separator: ","))
    }

    private static func capture(_ view: NSView, to path: String, name: String) {
        SelfTestRenderCapture.capture(view, card: nil, to: path, name: name) { n, ok, detail in
            check(n, ok, detail)
        }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        SelfTestRenderCapture.find(id, in: root)
    }

    private static func label(_ id: String, in root: NSView) -> NSTextField? {
        SelfTestRenderCapture.label(id, in: root)
    }

    /// Send a control's action to its target, the way AppKit would once the user let go of it.
    private static func fire(_ control: NSControl) {
        guard let target = control.target, let action = control.action else { return }
        _ = target.perform(action, with: control)
    }
}
