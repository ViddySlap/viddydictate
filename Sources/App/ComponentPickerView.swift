import Cocoa

/// The first-run welcome and component picker, drawn (spec B1-B6, B18's line above Continue).
///
/// It holds no judgement and no measurement. `ComponentPicker` decides what the rows say, what they
/// cost, and what this Mac can run; this view turns that into controls and hands clicks back. The one
/// thing it does own is that a core row is drawn WITHOUT a checkbox - which is not a styling choice,
/// it is B2: the mandatory core is not a thing the user can switch off, so there must be nothing on
/// screen that looks like it could be.
final class ComponentPickerView: NSView {
    override var isFlipped: Bool { true }

    /// Fired after any tick or install-choice change, with the new selection. The host re-renders and
    /// owns persistence; the view stores no preference of its own.
    var onSelectionChanged: ((ComponentPicker.Selection) -> Void)?
    var onContinue: (() -> Void)?
    var onWaitForWiFi: (() -> Void)?
    var onSetUpLater: (() -> Void)?

    private(set) var selection: ComponentPicker.Selection
    private var facts: ComponentPicker.MachineFacts
    private var environment: ComponentPicker.Environment
    private var sizes: ComponentPicker.SizeCatalog
    private var path: NetworkPathState
    private var gateState: NetworkDownloadGateState

    private let W: CGFloat
    private let L: CGFloat = 20
    /// One gutter for the state word, so a core row and a tick row line up as one list rather than as
    /// two lists that happen to be stacked.
    private let gutter: CGFloat = 96
    private let sizeColumn: CGFloat = 112

    init(width: CGFloat = 620,
         selection: ComponentPicker.Selection = .init(),
         facts: ComponentPicker.MachineFacts = .live,
         environment: ComponentPicker.Environment = .init(),
         sizes: ComponentPicker.SizeCatalog = .measured,
         path: NetworkPathState = NetworkPathState(isSatisfied: true),
         gateState: NetworkDownloadGateState = .ready) {
        self.W = width
        self.selection = selection
        self.facts = facts
        self.environment = environment
        self.sizes = sizes
        self.path = path
        self.gateState = gateState
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier(ComponentPicker.surfaceIdentifier)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Re-render against new facts. Returns the height it needs, so a host laying out a window can size
    /// to the content rather than to a guess.
    @discardableResult
    func apply(selection: ComponentPicker.Selection? = nil,
               facts: ComponentPicker.MachineFacts? = nil,
               environment: ComponentPicker.Environment? = nil,
               path: NetworkPathState? = nil,
               gateState: NetworkDownloadGateState? = nil) -> CGFloat {
        if let selection { self.selection = selection }
        if let facts { self.facts = facts }
        if let environment { self.environment = environment }
        if let path { self.path = path }
        if let gateState { self.gateState = gateState }
        rebuild()
        return frame.height
    }

    var rows: [ComponentPicker.Row] {
        ComponentPicker.rows(selection: selection, facts: facts, environment: environment,
                             sizes: sizes)
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        let contentW = W - L - 20
        let rows = self.rows

        let headline = SettingsSectionKit.label(ComponentPicker.headline, x: L, y: y, width: contentW,
                                                size: 19, weight: .semibold, color: .labelColor)
        headline.frame.size.height = 26
        headline.identifier = NSUserInterfaceItemIdentifier(ComponentPicker.headlineIdentifier)
        addSubview(headline)
        y = headline.frame.maxY + 6

        let subtitle = SettingsSectionKit.wrapped(ComponentPicker.subtitle, x: L, y: y,
                                                  width: contentW, size: 11,
                                                  color: .secondaryLabelColor)
        subtitle.identifier = NSUserInterfaceItemIdentifier(ComponentPicker.subtitleIdentifier)
        addSubview(subtitle)
        y = subtitle.frame.maxY + 18

        y = addSection(ComponentPicker.coreHeader, note: ComponentPicker.coreNote,
                       rows: rows.filter { $0.id.isCore }, at: y, width: contentW)
        y += 10
        y = addSection(ComponentPicker.optionalHeader, note: ComponentPicker.optionalNote,
                       rows: rows.filter { !$0.id.isCore }, at: y, width: contentW)

        y = addFooter(rows, at: y + 14, width: contentW)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y + 18)
    }

    private func addSection(_ header: String, note: String, rows: [ComponentPicker.Row],
                            at originY: CGFloat, width: CGFloat) -> CGFloat {
        var y = originY
        let title = SettingsSectionKit.sectionHeader(header, x: L, y: y, width: width)
        addSubview(title)
        y = title.frame.maxY + 3
        let subtitle = SettingsSectionKit.wrapped(note, x: L, y: y, width: width, size: 10.5,
                                                  color: .tertiaryLabelColor)
        addSubview(subtitle)
        y = subtitle.frame.maxY + 8
        for row in rows { y = addRow(row, at: y, width: width) + 8 }
        return y
    }

    /// One component, as a card: its state word, its name, what it is, what it costs, what leaving it
    /// off means, and what this Mac says about it. The card grows to its measured text rather than a
    /// guessed height - a clipped consequence is not one the user was shown.
    private func addRow(_ row: ComponentPicker.Row, at originY: CGFloat, width: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: ComponentPicker.cardIdentifier(row.id))
        addSubview(card)

        let textX = gutter + 14
        let textW = width - textX - sizeColumn - 24
        var y: CGFloat = 12

        let status = SettingsSectionKit.label(row.state.statusText, x: 14, y: y + 2,
                                              width: gutter - 14, size: 10, weight: .semibold,
                                              color: statusColor(row))
        status.identifier = NSUserInterfaceItemIdentifier(
            ComponentPicker.identifier(.status, row.id))
        card.addSubview(status)

        // B2 and B4 differ here and nowhere else: a core row's name is a label, a tick row's name IS
        // the checkbox. There is no code path that can give a core row a control.
        if case .optional(let ticked, _, let availability) = row.state {
            // AppKit dims a disabled button's whole cell, its title included, and an attributed colour
            // does not survive that. On the runtime row that models have switched on, a greyed name
            // reads as "unavailable" - the opposite of what is true. So the locked row carries the box
            // alone and states its name in an ordinary label, the way the mandatory rows do; every
            // other row keeps the title ON the checkbox, where it is also the hit target.
            let locked = forcedOn(row)
            let box = NSButton(checkboxWithTitle: locked ? "" : row.title, target: self,
                               action: #selector(tickChanged(_:)))
            box.font = .systemFont(ofSize: 12.5, weight: .semibold)
            box.state = ticked ? .on : .off
            box.isEnabled = availability.isSelectable && !locked
            box.tag = tag(for: row.id)
            box.identifier = NSUserInterfaceItemIdentifier(
                ComponentPicker.identifier(.tick, row.id))
            box.frame = NSRect(x: textX - 20, y: y, width: locked ? 18 : textW + 20, height: 18)
            card.addSubview(box)
            if locked {
                let title = SettingsSectionKit.label(row.title, x: textX, y: y, width: textW,
                                                     size: 12.5, weight: .semibold,
                                                     color: .labelColor)
                title.identifier = NSUserInterfaceItemIdentifier(
                    ComponentPicker.identifier(.title, row.id))
                card.addSubview(title)
            }
        } else {
            let title = SettingsSectionKit.label(row.title, x: textX, y: y, width: textW, size: 12.5,
                                                 weight: .semibold, color: .labelColor)
            title.identifier = NSUserInterfaceItemIdentifier(
                ComponentPicker.identifier(.title, row.id))
            card.addSubview(title)
        }

        let size = SettingsSectionKit.label(ComponentPicker.sizeText(row),
                                            x: width - sizeColumn - 14, y: y + 1,
                                            width: sizeColumn, size: 11, weight: .medium,
                                            color: row.downloadBytes == nil
                                                ? .tertiaryLabelColor : .secondaryLabelColor)
        size.alignment = .right
        size.identifier = NSUserInterfaceItemIdentifier(ComponentPicker.identifier(.size, row.id))
        card.addSubview(size)
        y += 21

        let lines: [(ComponentPicker.Part, String?, NSColor)] = [
            (.detail, row.detail, .secondaryLabelColor),
            (.consequence, row.consequence, .tertiaryLabelColor),
            (.machineNote, row.machineNote, machineNoteColor(row)),
        ]
        for (part, value, color) in lines {
            guard let value else { continue }
            let field = SettingsSectionKit.wrapped(value, x: textX, y: y, width: textW, size: 10.5,
                                                   color: color)
            field.identifier = NSUserInterfaceItemIdentifier(
                ComponentPicker.identifier(part, row.id))
            field.toolTip = value
            card.addSubview(field)
            y += field.frame.height + 3
        }

        // B4's two options, offered only where there is a third-party install to do and only once the
        // row is actually wanted. "I'll install it myself" is a real answer, not a synonym for off: the
        // row stays ticked and simply stops contributing to the download.
        if case .optional(let ticked, let choice, _) = row.state, ticked {
            let control = NSSegmentedControl(
                labels: ComponentPicker.InstallChoice.allCases.map(\.title),
                trackingMode: .selectOne, target: self, action: #selector(choiceChanged(_:)))
            control.segmentStyle = .rounded
            control.font = .systemFont(ofSize: 11)
            control.selectedSegment = choice == .forMe ? 0 : 1
            control.tag = tag(for: row.id)
            control.identifier = NSUserInterfaceItemIdentifier(
                ComponentPicker.identifier(.choice, row.id))
            control.frame = NSRect(x: textX, y: y + 3, width: 300, height: 22)
            card.addSubview(control)
            y += 28
        }

        card.frame.size.height = y + 10
        return card.frame.maxY
    }

    private func addFooter(_ rows: [ComponentPicker.Row], at originY: CGFloat,
                           width: CGFloat) -> CGFloat {
        var y = originY
        let line = NSBox(frame: NSRect(x: L, y: y, width: width, height: 1))
        line.boxType = .separator
        addSubview(line)
        y += 14

        // B18's line, in L4's words rather than a second spelling of the same judgement.
        if let note = networkNote(rows) {
            let field = SettingsSectionKit.wrapped(note, x: L, y: y, width: width, size: 11,
                                                   weight: .medium, color: .systemOrange)
            field.identifier = NSUserInterfaceItemIdentifier(ComponentPicker.networkNoteIdentifier)
            addSubview(field)
            y = field.frame.maxY + 8
        }

        // B6 puts this line ABOVE Continue, and laying it out beside the buttons is how it ends up
        // underneath one: the button row grows by a whole button the moment the path turns metered, and
        // the longest total ("plus LM Studio") arrives at exactly the same time.
        let total = SettingsSectionKit.label(ComponentPicker.totalLine(rows), x: L, y: y,
                                             width: width, size: 13, weight: .medium,
                                             color: .labelColor)
        total.identifier = NSUserInterfaceItemIdentifier(ComponentPicker.totalIdentifier)
        addSubview(total)
        y = total.frame.maxY + 12

        var buttonX = L + width
        for (title, identifier, action, isDefault) in footerButtons() {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            if isDefault { button.keyEquivalent = "\r" }
            button.sizeToFit()
            let w = max(button.frame.width + 18, 96)
            buttonX -= w
            button.frame = NSRect(x: buttonX, y: y, width: w, height: 30)
            button.isEnabled = identifier != ComponentPicker.continueIdentifier
                || gateState != .noNetwork
            addSubview(button)
            buttonX -= 10
        }
        return y + 30
    }

    /// Which buttons the screen offers, laid out right to left. B18 puts Wait for Wi-Fi BESIDE
    /// Continue only when the path is actually expensive or constrained, and offers Set up later
    /// immediately on a dead path rather than after three retries have failed.
    private func footerButtons() -> [(String, String, Selector, Bool)] {
        var buttons: [(String, String, Selector, Bool)] = [
            (ComponentPicker.continueTitle, ComponentPicker.continueIdentifier,
             #selector(continueClicked), true),
        ]
        if gateState == .meteredOrConstrained || gateState == .waitingForWiFi {
            buttons.append((NetworkPathCopy.waitForWiFiButton, ComponentPicker.waitForWiFiIdentifier,
                            #selector(waitForWiFiClicked), false))
        }
        buttons.append((NetworkPathCopy.setUpLaterButton, ComponentPicker.setUpLaterIdentifier,
                        #selector(setUpLaterClicked), false))
        return buttons
    }

    private func networkNote(_ rows: [ComponentPicker.Row]) -> String? {
        switch gateState {
        case .ready: return nil
        case .noNetwork: return NetworkPathCopy.noNetworkMessage
        case .waitingForWiFi: return NetworkPathCopy.waitingForWiFiMessage
        case .meteredOrConstrained:
            // The total is supplied by the picker so the network seam never owns a byte count.
            return path.warningLine(
                totalDownload: ComponentPicker.downloadSize(ComponentPicker.total(rows).bytes))
        }
    }

    private func statusColor(_ row: ComponentPicker.Row) -> NSColor {
        switch row.state {
        case .bundled, .alreadyInstalled: return .systemGreen
        case .included: return .secondaryLabelColor
        case .optional(let ticked, _, let availability):
            if availability == .tooLarge { return .systemOrange }
            return ticked ? .systemGreen : .tertiaryLabelColor
        }
    }

    private func machineNoteColor(_ row: ComponentPicker.Row) -> NSColor {
        guard case .optional(_, _, let availability) = row.state else { return .tertiaryLabelColor }
        return availability == .fits ? .tertiaryLabelColor : .systemOrange
    }

    /// Whether the LM Studio row is on because a model needs it. Its box is then checked and disabled
    /// rather than silently re-ticking itself under the pointer.
    private func forcedOn(_ row: ComponentPicker.Row) -> Bool {
        row.id == .lmStudio && !selection.lmStudio
            && ComponentPicker.needsLMStudio(selection, environment: environment)
    }

    // MARK: - actions

    private func tag(for id: ComponentPicker.RowID) -> Int {
        (ComponentPicker.RowID.allCases.firstIndex(of: id) ?? 0) + 1
    }

    private func rowID(forTag tag: Int) -> ComponentPicker.RowID? {
        let index = tag - 1
        guard index >= 0, index < ComponentPicker.RowID.allCases.count else { return nil }
        return ComponentPicker.RowID.allCases[index]
    }

    @objc private func tickChanged(_ sender: NSButton) {
        guard let id = rowID(forTag: sender.tag) else { return }
        selection.setTicked(id, sender.state == .on)
        rebuild()
        onSelectionChanged?(selection)
    }

    @objc private func choiceChanged(_ sender: NSSegmentedControl) {
        guard let id = rowID(forTag: sender.tag) else { return }
        selection.setChoice(id, sender.selectedSegment == 0 ? .forMe : .myself)
        rebuild()
        onSelectionChanged?(selection)
    }

    @objc private func continueClicked() { onContinue?() }
    @objc private func waitForWiFiClicked() { onWaitForWiFi?() }
    @objc private func setUpLaterClicked() { onSetUpLater?() }
}

/// The window the picker lives in on first launch (B1, and the host L6's progress and permissions
/// screens step into).
///
/// It is an ordinary closable window on purpose. B1 says the gate is a picker and not a wall, and B9
/// says dismissing setup cancels nothing, so nothing here is modal and nothing blocks the app. The
/// rule that brings it BACK on every launch until the core is installed is B12, which belongs to the
/// link that owns the degraded state; this type only knows how to show itself and how to report what
/// the user chose.
final class FirstRunSetupWindowController: NSObject, NSWindowDelegate {
    /// Called with the plan the user assembled. The host runs it; this controller starts nothing, so
    /// there is one installer entered from here and from the point-of-use offer rather than two.
    var onContinue: ((ComponentPicker.InstallPlan) -> Void)?
    var onSetUpLater: (() -> Void)?

    private let facts: ComponentPicker.MachineFacts
    private let environment: ComponentPicker.Environment
    private let gate: NetworkDownloadGate
    private var window: NSWindow?
    private var picker: ComponentPickerView?

    private let contentWidth: CGFloat = 620

    init(facts: ComponentPicker.MachineFacts = .live,
         environment: ComponentPicker.Environment = .init(),
         gate: NetworkDownloadGate = NetworkDownloadGate(monitor: NetworkPathMonitor())) {
        self.facts = facts
        self.environment = environment
        self.gate = gate
        super.init()
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Exposed for the offscreen render gate: the picker plus its chrome, with no window involved.
    ///
    /// The network gate is wired and started HERE rather than in `show()`, so the surface behaves the
    /// same whether it is in a window or being driven offscreen. Starting it in `show()` meant the only
    /// live copy was the one the window built, and a caller holding the view it asked for was holding a
    /// dead one.
    func makeContentView() -> ComponentPickerView {
        let view = ComponentPickerView(
            width: contentWidth,
            selection: ComponentPicker.defaultSelection(facts: facts, environment: environment),
            facts: facts, environment: environment)
        view.onContinue = { [weak self] in self?.continueTapped() }
        view.onWaitForWiFi = { [weak self] in self?.waitTapped() }
        view.onSetUpLater = { [weak self] in self?.laterTapped() }
        picker = view
        gate.onStateChange = { [weak self] in self?.syncNetwork() }
        gate.startMonitoring()
        syncNetwork()
        return view
    }

    private func build() {
        let content = makeContentView()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 640),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = ComponentPicker.headline
        w.isReleasedWhenClosed = false
        w.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 640))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = content
        let host = NSView(frame: scroll.frame)
        host.addSubview(scroll)
        w.contentView = host
        window = w
    }

    private func syncNetwork() {
        picker?.apply(path: gate.path, gateState: gate.state)
    }

    private func plan() -> ComponentPicker.InstallPlan {
        ComponentPicker.installPlan(selection: picker?.selection ?? .init(), facts: facts,
                                    environment: environment)
    }

    private func continueTapped() {
        let plan = plan()
        // L4's gate decides whether this starts now, waits, or cannot start at all. The picker does not
        // second-guess the path it was handed.
        _ = gate.startDownload { [weak self] in self?.onContinue?(plan) }
    }

    private func waitTapped() {
        let plan = plan()
        _ = gate.waitForWiFi { [weak self] in self?.onContinue?(plan) }
    }

    private func laterTapped() {
        gate.setUpLater()
        onSetUpLater?()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        gate.stopMonitoring()
    }
}
