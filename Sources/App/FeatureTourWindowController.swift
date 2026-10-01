import Cocoa

/// What the tour's live readouts show at one moment (D7: read, never acted on). Injected as closures into the
/// controller, so `--feature-tour-render` photographs every readout from stubbed facts and launches nothing.
struct FeatureTourLiveFacts: Equatable {
    /// The map the Hotkeys tab edits. Every chord on every page is read from here.
    var hotkeys: HotkeyMap
    /// The first-run permissions screen's own reading.
    var permissions: PermissionsStatus
    /// S3a's merged `.local` presence, nil until the first measurement lands (the rows then read CHECKING).
    var localPresence: LLMProviderDetection.Presence?
    var practice: FeatureTourPractice.State
}

/// The Feature Tour window (spec section 7): a paged window in `FirstRunSetupWindowController`'s pattern, with a
/// page index and a swapped `documentView`. Each page is built by `makePageView(_:)`, so the render gate builds
/// every page without a window.
///
/// It explains and links (D7). The only things it does are move between pages, open a Settings tab through the
/// host's `onOpenSettings` (the Settings window's own `show(tab:)`), and read: the permissions, the local apps
/// (measured off the main thread with the starter that never opens an app), and whether this launch's hotkey
/// tap is live.
final class FeatureTourWindowController: NSObject, NSWindowDelegate {
    typealias LocalMeasurer = (@escaping (LLMProviderDetection.Presence) -> Void) -> Void

    /// A page's "Open the ... tab" button. The host opens its Settings window there.
    var onOpenSettings: ((SettingsTab) -> Void)?

    let pages: [FeatureTourPage]
    private(set) var index = 0

    private let hotkeys: () -> HotkeyMap
    private let readPermissions: () -> PermissionsStatus
    private let hotkeysLive: () -> Bool
    private let measureLocal: LocalMeasurer
    private var localPresence: LLMProviderDetection.Presence?
    private var measuring = false

    private var window: NSWindow?
    private var scroll: NSScrollView?
    private var shownFacts: FeatureTourLiveFacts?
    private var pageHeight: CGFloat = 0

    static let contentWidth: CGFloat = 620
    /// The tour is drawn in the HUD's phosphor language (the point-of-use offer panel's): green type and cells on
    /// the dark phosphor panel, whatever the Mac is set to. Its own colours are fixed, so the system setting does
    /// not touch them; this pin covers what AppKit still draws for it - the title bar, the scroller, the practice
    /// box's text view, and the amber `systemOrange` - so those are the dark variants too. Set on the window AND
    /// on every page, because the render gate builds pages without the window.
    static let drawingAppearance = NSAppearance(named: .darkAqua)
    /// The phosphor panel fill (`Phosphor.panelBG`), opaque: nothing the system draws behind it can show through.
    static var panelColor: NSColor { Phosphor.panelBG.withAlphaComponent(1) }
    /// The window grows to the tallest page so Back and Next never move between pages, up to this cap; a page
    /// taller than the cap scrolls rather than pushing the window off a small screen.
    static let minimumPageHeight: CGFloat = 520
    static let maximumPageHeight: CGFloat = 760

    init(pages: [FeatureTourPage] = FeatureTour.pages,
         hotkeys: @escaping () -> HotkeyMap = { HotkeyMap.load() },
         readPermissions: @escaping () -> PermissionsStatus = { .live },
         hotkeysLive: @escaping () -> Bool,
         measureLocal: @escaping LocalMeasurer = FeatureTourWindowController.measureLocalLive) {
        self.pages = pages
        self.hotkeys = hotkeys
        self.readPermissions = readPermissions
        self.hotkeysLive = hotkeysLive
        self.measureLocal = measureLocal
        super.init()
    }

    /// The production measurement: the same `observeLocal` the first-run setup window runs, off the main thread,
    /// with its default starter, which never opens either app.
    static func measureLocalLive(_ done: @escaping (LLMProviderDetection.Presence) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let presence = LLMProviderDetection.observeLocal().presence
            DispatchQueue.main.async { done(presence) }
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Opens the window on `page` (page 1 from the menu and on first show), or brings an open one forward there.
    func show(page: Int = 0) {
        let wasVisible = isVisible
        if window == nil { build() }
        if !wasVisible {
            // macOS sends nothing when a TCC grant changes; coming back from System Settings is when to look again.
            NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                                   name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        go(to: page)
        // An accessory app has to activate itself first, or the window opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - pages

    func liveFacts() -> FeatureTourLiveFacts {
        let permissions = readPermissions()
        return FeatureTourLiveFacts(
            hotkeys: hotkeys(),
            permissions: permissions,
            localPresence: localPresence,
            practice: FeatureTourPractice.state(tapLive: hotkeysLive(),
                                                accessibility: permissions.accessibility,
                                                inputMonitoring: permissions.inputMonitoring))
    }

    /// One page, footer included, at the window's width and uniform height. No window is involved, so the render
    /// gate can build every page this way.
    func makePageView(_ index: Int) -> FeatureTourPageView {
        // A page that shows the local apps starts their measurement if none has landed yet. With an injected
        // measurer that answers at once (the render gate's), the page is built with the answer.
        if pages[index].liveStatus == .localApps, localPresence == nil { measureLocalApps() }
        return makePageView(index, facts: liveFacts())
    }

    private func makePageView(_ index: Int, facts: FeatureTourLiveFacts) -> FeatureTourPageView {
        if pageHeight == 0 { pageHeight = uniformHeight(facts: facts) }
        let view = FeatureTourPageView(page: pages[index], index: index, count: pages.count,
                                       width: Self.contentWidth, minimumHeight: pageHeight, facts: facts)
        view.onBack = { [weak self] in self?.go(to: index - 1) }
        view.onNext = { [weak self] in self?.next() }
        view.onSkip = { [weak self] in self?.window?.close() }
        view.onOpenSetting = { [weak self] tab in self?.onOpenSettings?(tab) }
        return view
    }

    /// The tallest page's natural height, clamped, so every page shares one window height.
    private func uniformHeight(facts: FeatureTourLiveFacts) -> CGFloat {
        let tallest = pages.indices.map {
            FeatureTourPageView(page: pages[$0], index: $0, count: pages.count, width: Self.contentWidth,
                                minimumHeight: 0, facts: facts).naturalHeight
        }.max() ?? Self.minimumPageHeight
        return min(Self.maximumPageHeight, max(Self.minimumPageHeight, tallest))
    }

    private func next() {
        if index + 1 < pages.count { go(to: index + 1) } else { window?.close() }
    }

    private func go(to target: Int) {
        guard pages.indices.contains(target) else { return }
        index = target
        if pages[target].liveStatus == .localApps { measureLocalApps() }
        install(facts: liveFacts())
    }

    private func install(facts: FeatureTourLiveFacts) {
        guard let scroll else { return }
        shownFacts = facts
        let view = makePageView(index, facts: facts)
        scroll.documentView = view
        scroll.contentView.scroll(to: .zero)
        // D9: a live practice box takes the focus, so the first dictation lands in it with no click.
        if let field = view.practiceField, field.isEditable { window?.makeFirstResponder(field) }
    }

    /// Re-read on every visit to the local models page, so an app started in the meantime reads RUNNING.
    private func measureLocalApps() {
        guard !measuring else { return }
        measuring = true
        measureLocal { [weak self] presence in
            guard let self else { return }
            self.measuring = false
            self.localPresence = presence
            self.refreshIfChanged()
        }
    }

    /// Rebuild the visible page only when something it shows has changed, so a practice box mid-sentence is not
    /// wiped by an unrelated app activation.
    private func refreshIfChanged() {
        guard isVisible else { return }
        let facts = liveFacts()
        guard facts != shownFacts else { return }
        install(facts: facts)
    }

    // MARK: - window

    private func build() {
        let size = NSSize(width: Self.contentWidth, height: uniformHeight(facts: liveFacts()))
        pageHeight = size.height
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = FeatureTour.windowTitle
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.appearance = Self.drawingAppearance
        // The title bar sits on the phosphor panel rather than on a grey system strip.
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Self.panelColor
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let host = NSView(frame: scroll.frame)
        host.addSubview(scroll)
        w.contentView = host
        window = w
        self.scroll = scroll
    }

    @objc private func appBecameActive() { refreshIfChanged() }

    func windowWillClose(_ notification: Notification) {
        // Closing is all Skip tour and Done do: nothing was changed, so there is nothing to undo or save. The
        // window is kept, and the next show opens it on page 1 again.
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification,
                                                  object: nil)
        shownFacts = nil
    }
}

/// One tour page, drawn: the step, the title, the body, the "worth knowing" card, the keys card read from the live
/// map, the page's live readout, its Settings link, and the footer. Flipped, top to bottom. Drawn in the point-of-use
/// offer panel's phosphor language, from its own parts: the panel fill, `Phosphor.kerned` headings, the phosphor
/// font, `Phosphor.styleCell` cards and buttons (Next is the selected, glowing one), and the HUD's glow on the
/// highlighted values.
final class FeatureTourPageView: NSView {
    override var isFlipped: Bool { true }

    var onBack: (() -> Void)?
    var onNext: (() -> Void)?
    var onSkip: (() -> Void)?
    var onOpenSetting: ((SettingsTab) -> Void)?

    /// Content plus footer, before `minimumHeight` pins the footer to the bottom.
    private(set) var naturalHeight: CGFloat = 0
    /// Page 3's practice box, when this page has one.
    private(set) weak var practiceField: NSTextView?

    private let page: FeatureTourPage
    private let index: Int
    private let count: Int
    private let W: CGFloat
    private let facts: FeatureTourLiveFacts
    private let L: CGFloat = 24
    private static let footerHeight: CGFloat = 58

    /// View identifiers, read by `--feature-tour-render`.
    enum ID {
        static let step = "feature-tour-step"
        static let title = "feature-tour-title"
        static func body(_ line: Int) -> String { "feature-tour-body-\(line)" }
        static let nonObvious = "feature-tour-non-obvious"
        static let keysCard = "feature-tour-keys"
        static func chord(_ slot: HotkeySlot) -> String { "feature-tour-chord-\(FeatureTour.token(for: slot))" }
        static let statusCard = "feature-tour-status"
        static func permission(_ permission: SetupPermission) -> String {
            "feature-tour-permission-\(permission.rawValue)"
        }
        static func localState(_ backend: LocalBackendID) -> String { "feature-tour-local-\(backend.rawValue)" }
        static func localStatus(_ backend: LocalBackendID) -> String {
            "feature-tour-local-\(backend.rawValue)-status"
        }
        static let practiceNote = "feature-tour-practice-note"
        static let practiceField = "feature-tour-practice-field"
        static let openSetting = "feature-tour-open-setting"
        static let back = "feature-tour-back"
        static let next = "feature-tour-next"
        static let skip = "feature-tour-skip"
        static let dots = "feature-tour-dots"
    }

    init(page: FeatureTourPage, index: Int, count: Int, width: CGFloat, minimumHeight: CGFloat,
         facts: FeatureTourLiveFacts) {
        self.page = page
        self.index = index
        self.count = count
        self.W = width
        self.facts = facts
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier("feature-tour-page-\(page.id)")
        appearance = FeatureTourWindowController.drawingAppearance
        build(minimumHeight: minimumHeight)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    // MARK: - build

    private func build(minimumHeight: CGFloat) {
        // The phosphor panel, opaque, so no system window colour shows through it under either appearance.
        wantsLayer = true
        layer?.backgroundColor = FeatureTourWindowController.panelColor.cgColor

        let contentW = W - 2 * L
        let map = facts.hotkeys
        var y: CGFloat = 20

        let step = Self.kernedLabel(FeatureTour.stepText(index, of: count), x: L, y: y, width: contentW,
                                    size: 11, kern: 1.5, color: Style.hint)
        step.identifier = NSUserInterfaceItemIdentifier(ID.step)
        addSubview(step)
        y = step.frame.maxY + 6

        // The offers' heading: letter-spaced phosphor green, here at page-title size.
        let title = Self.kernedLabel(page.title, x: L, y: y, width: contentW, size: 18, kern: 2.5,
                                     color: Style.heading)
        title.identifier = NSUserInterfaceItemIdentifier(ID.title)
        addSubview(title)
        y = title.frame.maxY + 12

        for (line, text) in page.renderedBody(map: map).enumerated() {
            let field = Self.wrapped(text, x: L, y: y, width: contentW, size: 13, color: Style.body)
            field.identifier = NSUserInterfaceItemIdentifier(ID.body(line))
            addSubview(field)
            y = field.frame.maxY + 8
        }

        if let note = page.renderedNonObvious(map: map) {
            y = addNonObvious(note, at: y + 6, width: contentW)
        }
        if !page.commands.isEmpty {
            y = addKeys(at: y + 10, width: contentW)
        }
        switch page.liveStatus {
        case .permissions?: y = addPermissions(at: y + 10, width: contentW)
        case .localApps?: y = addLocalApps(at: y + 10, width: contentW)
        case .practice?: y = addPractice(at: y + 10, width: contentW)
        case nil: break
        }
        if let tab = page.settingsLink {
            let button = Self.button(FeatureTour.settingsButtonTitle(tab), selected: false, target: self,
                                     action: #selector(openSettingClicked))
            button.identifier = NSUserInterfaceItemIdentifier(ID.openSetting)
            button.frame.origin = NSPoint(x: L, y: y + 12)
            addSubview(button)
            y = button.frame.maxY
        }

        naturalHeight = y + 20 + Self.footerHeight
        let footerY = max(y + 20, minimumHeight - Self.footerHeight)
        addFooter(at: footerY, width: contentW)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: footerY + Self.footerHeight)
    }

    /// The tour's phosphor palette: `Phosphor.green` at the offer panel's alphas, raised where the offer's idle
    /// alphas would fall under 4.5:1 on a card (the offer's 0.42 detail is 3.3:1 there). Amber, the setup
    /// windows' `systemOrange`, keeps meaning "needs you". Read live, so a changed theme accent recolours it.
    enum Style {
        static var heading: NSColor { Phosphor.green.withAlphaComponent(0.92) }
        static var body: NSColor { Phosphor.green.withAlphaComponent(0.9) }
        /// Card headings, the step line, secondary readouts: 5:1 or better on a card.
        static var muted: NSColor { Phosphor.green.withAlphaComponent(0.65) }
        /// Row names inside a card.
        static var row: NSColor { Phosphor.green.withAlphaComponent(0.85) }
        static var hint: NSColor { Phosphor.green.withAlphaComponent(0.6) }
        /// Highlighted values: chords, GRANTED, RUNNING, the current page dot, the selected button.
        static var lit: NSColor { Phosphor.green }
        static var attention: NSColor { .systemOrange }
        /// The unlit page dots: 4:1 on the panel, clearly dimmer than the lit one.
        static var dot: NSColor { Phosphor.green.withAlphaComponent(0.5) }

        /// The HUD's phosphor glow on a highlighted value (the Settings heading's: 0.6, 6 pt).
        static var glow: NSShadow {
            let shadow = NSShadow()
            shadow.shadowColor = Phosphor.green.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = .zero
            return shadow
        }

        static func font(_ size: CGFloat) -> NSFont { NSFont(name: Phosphor.font, size: size) ?? .systemFont(ofSize: size) }
    }

    /// One line in the offers' kerned phosphor type (`Phosphor.kerned`). Truncates rather than wraps.
    static func kernedLabel(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, kern: CGFloat,
                            color: NSColor, glow: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = color
        let line = NSMutableAttributedString(attributedString: Phosphor.kerned(value, color: color, size: size,
                                                                               kern: kern))
        if glow { line.addAttribute(.shadow, value: Style.glow, range: NSRange(location: 0, length: line.length)) }
        field.attributedStringValue = line
        field.frame = NSRect(x: x, y: y, width: width, height: ceil(size * 1.25) + 4)
        return field
    }

    /// Wrapping text in the offers' body type: the phosphor font, 3 pt line spacing. Sized to what the text needs
    /// at this width (the larger of AppKit's fit and the laid-out text), so nothing is clipped.
    static func wrapped(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                        color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.textColor = color
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        field.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: Style.font(size), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        field.preferredMaxLayoutWidth = width
        let fitted = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let laid = field.attributedStringValue.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        field.frame = NSRect(x: x, y: y, width: width, height: ceil(max(fitted.height, laid.height + 2)))
        return field
    }

    /// A phosphor button: an offer cell's chrome (`Phosphor.styleCell`: dark cell, green border, and the glow
    /// when selected) around a kerned phosphor title. `selected` is the one Return presses.
    static func button(_ title: String, selected: Bool, enabled: Bool = true, target: AnyObject?,
                       action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.isEnabled = enabled
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1.5
        Phosphor.styleCell(button, selected: selected && enabled)
        let alpha: CGFloat = !enabled ? 0.3 : (selected ? 0.98 : 0.8)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Style.font(13), .kern: 1.2, .paragraphStyle: centred,
            .foregroundColor: Phosphor.green.withAlphaComponent(alpha),
        ])
        let width = max(90, ceil(button.attributedTitle.size().width) + 32)
        button.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        return button
    }

    /// A phosphor card, an offer cell at rest (`Phosphor.styleCell`, unselected), with its kerned heading;
    /// `fill` lays the contents out from `y` inside it and returns the bottom.
    private func addCard(_ header: String, identifier: String, at originY: CGFloat, width: CGFloat,
                         fill: (NSView, CGFloat, CGFloat) -> CGFloat) -> CGFloat {
        let card = FlippedSectionView(frame: NSRect(x: L, y: originY, width: width, height: 0))
        card.identifier = NSUserInterfaceItemIdentifier(identifier)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1.5
        Phosphor.styleCell(card, selected: false)
        addSubview(card)
        let heading = Self.kernedLabel(header, x: 14, y: 11, width: width - 28, size: 10, kern: 1.2,
                                       color: Style.muted)
        card.addSubview(heading)
        let bottom = fill(card, heading.frame.maxY + 6, width - 28)
        card.frame.size.height = bottom + 12
        return card.frame.maxY
    }

    private func addNonObvious(_ note: String, at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.nonObviousHeader, identifier: ID.nonObvious, at: y, width: width) { card, y, w in
            let field = Self.wrapped(note, x: 14, y: y, width: w, size: 12.5, color: Style.body)
            card.addSubview(field)
            return field.frame.maxY
        }
    }

    /// Each slot the page teaches, with its key as the Hotkeys tab draws it (lit, with the HUD's glow), and the
    /// Hotkeys tab's own row label.
    private func addKeys(at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.keysHeader, identifier: ID.keysCard, at: y, width: width) { card, y, w in
            var row = y
            let chipW: CGFloat = 104
            for slot in page.commands {
                let chip = Self.kernedLabel(FeatureTour.chordLabel(slot, map: facts.hotkeys), x: 14, y: row,
                                            width: chipW, size: 12.5, kern: 0.5, color: Style.lit, glow: true)
                chip.identifier = NSUserInterfaceItemIdentifier(ID.chord(slot))
                card.addSubview(chip)
                let name: String
                switch slot {
                case .wakeup: name = FeatureTour.wakeupRowLabel
                case .command(let command): name = command.label
                }
                card.addSubview(Self.kernedLabel(name, x: 14 + chipW + 8, y: row, width: w - chipW - 8, size: 12,
                                                 kern: 0.3, color: Style.row))
                row += 21
            }
            return row - 4
        }
    }

    /// D7's permission ticks, in the first-run permissions screen's own words (GRANTED / NEEDED).
    private func addPermissions(at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.permissionsHeader, identifier: ID.statusCard, at: y, width: width) { card, y, w in
            var row = y
            for permission in SetupPermission.allCases {
                let granted = facts.permissions.isGranted(permission)
                let color: NSColor = granted ? Style.lit : Style.attention
                card.addSubview(Self.kernedLabel(granted ? "\u{2713}" : "\u{2717}", x: 14, y: row, width: 22,
                                                 size: 13, kern: 0, color: color, glow: granted))
                card.addSubview(Self.kernedLabel(permission.title, x: 40, y: row, width: w - 146, size: 12.5,
                                                 kern: 0.3, color: Style.row))
                let word = Self.kernedLabel(granted ? PermissionsScreen.grantedText : PermissionsScreen.pendingText,
                                            x: w - 100 + 14, y: row + 2, width: 100, size: 10, kern: 1.2,
                                            color: color)
                word.alignment = .right
                word.identifier = NSUserInterfaceItemIdentifier(ID.permission(permission))
                card.addSubview(word)
                row += 22
            }
            return row - 4
        }
    }

    /// LM Studio and Ollama, in the Setup tab's own row words (`LocalAppRows`): the state word and the status line.
    private func addLocalApps(at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.localAppsHeader, identifier: ID.statusCard, at: y, width: width) { card, y, w in
            var row = y
            for app in LocalAppRows.build(presence: facts.localPresence) {
                let running: Bool
                if case .running = app.state { running = true } else { running = false }
                let color: NSColor = running ? Style.lit : (app.needsAttention ? Style.attention : Style.muted)
                card.addSubview(Self.kernedLabel(app.title, x: 14, y: row, width: w - 140, size: 12.5, kern: 0.3,
                                                 color: Style.row))
                let word = Self.kernedLabel(app.stateWord, x: w - 120 + 14, y: row + 2, width: 120, size: 10,
                                            kern: 1.2, color: color)
                word.alignment = .right
                word.identifier = NSUserInterfaceItemIdentifier(ID.localState(app.backend))
                card.addSubview(word)
                let status = Self.wrapped(app.status, x: 14, y: row + 20, width: w, size: 11, color: Style.muted)
                status.identifier = NSUserInterfaceItemIdentifier(ID.localStatus(app.backend))
                card.addSubview(status)
                row = status.frame.maxY + 8
            }
            return row - 8
        }
    }

    /// D9's practice box. Editable only when this launch's hotkey tap is live; otherwise it says why, in place.
    private func addPractice(at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.practiceHeader, identifier: ID.statusCard, at: y, width: width) { card, y, w in
            let ready = facts.practice == .ready
            let note = Self.wrapped(FeatureTourPractice.note(facts.practice, map: facts.hotkeys), x: 14, y: y,
                                    width: w, size: 12, color: ready ? Style.muted : Style.attention)
            note.identifier = NSUserInterfaceItemIdentifier(ID.practiceNote)
            card.addSubview(note)

            // A selected offer cell's chrome around the box, so it reads as the place the words will land.
            let box = NSScrollView(frame: NSRect(x: 14, y: note.frame.maxY + 8, width: w, height: 58))
            box.borderType = .noBorder
            box.drawsBackground = false
            box.hasVerticalScroller = true
            box.autohidesScrollers = true
            box.wantsLayer = true
            box.layer?.cornerRadius = 6
            box.layer?.borderWidth = 1
            box.layer?.borderColor = Phosphor.green.withAlphaComponent(ready ? 0.5 : 0.18).cgColor
            box.layer?.backgroundColor = Phosphor.cellOn.cgColor
            let text = NSTextView(frame: NSRect(origin: .zero, size: box.contentSize))
            text.isRichText = false
            text.drawsBackground = false
            text.font = Style.font(13)
            text.textColor = Style.body
            text.insertionPointColor = Phosphor.green
            text.typingAttributes = [.font: Style.font(13), .foregroundColor: Style.body]
            text.textContainerInset = NSSize(width: 4, height: 4)
            text.isEditable = ready
            text.isSelectable = ready
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.identifier = NSUserInterfaceItemIdentifier(ID.practiceField)
            text.setAccessibilityPlaceholderValue(FeatureTourPractice.placeholder)
            box.documentView = text
            card.addSubview(box)
            practiceField = text
            return box.frame.maxY
        }
    }

    /// Skip tour on the left, the page dots in the middle, Back and Next (Done on the last page) on the right.
    /// Next is the selected, glowing button, the one Return presses.
    private func addFooter(at originY: CGFloat, width: CGFloat) {
        let line = NSBox(frame: NSRect(x: L, y: originY, width: width, height: 1))
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Phosphor.green.withAlphaComponent(0.18)
        addSubview(line)
        let y = originY + 15

        let skip = Self.button(FeatureTour.skipTitle, selected: false, target: self, action: #selector(skipClicked))
        skip.identifier = NSUserInterfaceItemIdentifier(ID.skip)
        skip.frame.origin = NSPoint(x: L, y: y)
        addSubview(skip)

        let last = index == count - 1
        let next = Self.button(last ? FeatureTour.doneTitle : FeatureTour.nextTitle, selected: true, target: self,
                               action: #selector(nextClicked))
        next.identifier = NSUserInterfaceItemIdentifier(ID.next)
        // Return pages forward, except where Return belongs to the practice box.
        if page.liveStatus != .practice { next.keyEquivalent = "\r" }
        next.frame.origin = NSPoint(x: L + width - next.frame.width, y: y)
        addSubview(next)

        let back = Self.button(FeatureTour.backTitle, selected: false, enabled: index > 0, target: self,
                               action: #selector(backClicked))
        back.identifier = NSUserInterfaceItemIdentifier(ID.back)
        back.frame.origin = NSPoint(x: next.frame.minX - back.frame.width - 10, y: y)
        addSubview(back)

        let dots = FeatureTourDotsView(count: count, current: index)
        dots.identifier = NSUserInterfaceItemIdentifier(ID.dots)
        dots.frame.origin = NSPoint(x: ((W - dots.frame.width) / 2).rounded(),
                                    y: y + (28 - dots.frame.height) / 2)
        addSubview(dots)
    }

    @objc private func backClicked() { onBack?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func skipClicked() { onSkip?() }
    @objc private func openSettingClicked() {
        guard let tab = page.settingsLink else { return }
        onOpenSetting?(tab)
    }
}

/// The page dots: one per page in phosphor green, the current one lit full and glowing, the rest dim.
final class FeatureTourDotsView: NSView {
    /// Read by `--feature-tour-render`, which also counts the dots in the rendered pixels.
    let count: Int
    let current: Int
    private static let diameter: CGFloat = 7
    private static let gap: CGFloat = 7

    init(count: Int, current: Int) {
        self.count = count
        self.current = current
        let width = CGFloat(count) * Self.diameter + CGFloat(max(0, count - 1)) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.diameter))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(FeatureTour.stepText(current, of: count))
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    func dotRect(_ dot: Int) -> NSRect {
        NSRect(x: CGFloat(dot) * (Self.diameter + Self.gap), y: 0, width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        for dot in 0..<count {
            (dot == current ? FeatureTourPageView.Style.lit : FeatureTourPageView.Style.dot).setFill()
            NSBezierPath(ovalIn: dotRect(dot)).fill()
        }
    }
}
