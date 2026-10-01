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
/// map, the page's live readout, its Settings link, and the footer. Flipped, top to bottom, in the setup windows'
/// `SettingsSectionKit` idiom.
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
        build(minimumHeight: minimumHeight)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    // MARK: - build

    private func build(minimumHeight: CGFloat) {
        let contentW = W - 2 * L
        let map = facts.hotkeys
        var y: CGFloat = 20

        let step = SettingsSectionKit.label(FeatureTour.stepText(index, of: count), x: L, y: y, width: contentW,
                                            size: 11, weight: .medium, color: .secondaryLabelColor)
        step.identifier = NSUserInterfaceItemIdentifier(ID.step)
        addSubview(step)
        y = step.frame.maxY + 4

        let title = SettingsSectionKit.label(page.title, x: L, y: y, width: contentW, size: 20,
                                             weight: .semibold, color: .labelColor)
        title.frame.size.height = 28
        title.identifier = NSUserInterfaceItemIdentifier(ID.title)
        addSubview(title)
        y = title.frame.maxY + 10

        for (line, text) in page.renderedBody(map: map).enumerated() {
            let field = SettingsSectionKit.wrapped(text, x: L, y: y, width: contentW, size: 13,
                                                   color: .labelColor)
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
            let button = NSButton(title: FeatureTour.settingsButtonTitle(tab), target: self,
                                  action: #selector(openSettingClicked))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(ID.openSetting)
            button.sizeToFit()
            button.frame = NSRect(x: L - 6, y: y + 12, width: button.frame.width + 16, height: 28)
            addSubview(button)
            y = button.frame.maxY
        }

        naturalHeight = y + 20 + Self.footerHeight
        let footerY = max(y + 20, minimumHeight - Self.footerHeight)
        addFooter(at: footerY, width: contentW)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: footerY + Self.footerHeight)
    }

    /// A card with a section header; `fill` lays the contents out from `y` inside it and returns the bottom.
    private func addCard(_ header: String, identifier: String, at originY: CGFloat, width: CGFloat,
                         fill: (NSView, CGFloat, CGFloat) -> CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: identifier)
        addSubview(card)
        let heading = SettingsSectionKit.sectionHeader(header, x: 14, y: 11, width: width - 28)
        card.addSubview(heading)
        let bottom = fill(card, heading.frame.maxY + 6, width - 28)
        card.frame.size.height = bottom + 12
        return card.frame.maxY
    }

    private func addNonObvious(_ note: String, at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.nonObviousHeader, identifier: ID.nonObvious, at: y, width: width) { card, y, w in
            let field = SettingsSectionKit.wrapped(note, x: 14, y: y, width: w, size: 12.5, color: .labelColor)
            card.addSubview(field)
            return field.frame.maxY
        }
    }

    /// Each slot the page teaches, with its key as the Hotkeys tab draws it, and the Hotkeys tab's own row label.
    private func addKeys(at y: CGFloat, width: CGFloat) -> CGFloat {
        addCard(FeatureTour.keysHeader, identifier: ID.keysCard, at: y, width: width) { card, y, w in
            var row = y
            let chipW: CGFloat = 104
            for slot in page.commands {
                let chip = SettingsSectionKit.label(FeatureTour.chordLabel(slot, map: facts.hotkeys), x: 14, y: row,
                                                    width: chipW, size: 12, weight: .medium, color: Phosphor.green)
                chip.font = NSFont(name: Phosphor.font, size: 12) ?? chip.font
                chip.identifier = NSUserInterfaceItemIdentifier(ID.chord(slot))
                card.addSubview(chip)
                let name: String
                switch slot {
                case .wakeup: name = FeatureTour.wakeupRowLabel
                case .command(let command): name = command.label
                }
                card.addSubview(SettingsSectionKit.label(name, x: 14 + chipW + 8, y: row, width: w - chipW - 8,
                                                         size: 12, weight: .regular, color: .labelColor))
                row += 20
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
                let color: NSColor = granted ? Phosphor.green : .systemOrange
                card.addSubview(SettingsSectionKit.label(granted ? "\u{2713}" : "\u{2717}", x: 14, y: row,
                                                         width: 22, size: 13, weight: .bold, color: color))
                card.addSubview(SettingsSectionKit.label(permission.title, x: 40, y: row, width: w - 146,
                                                         size: 12.5, weight: .medium, color: .labelColor))
                let word = SettingsSectionKit.label(
                    granted ? PermissionsScreen.grantedText : PermissionsScreen.pendingText,
                    x: w - 100 + 14, y: row + 2, width: 100, size: 10, weight: .semibold, color: color)
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
                let color: NSColor = running ? Phosphor.green
                    : (app.needsAttention ? .systemOrange : .secondaryLabelColor)
                card.addSubview(SettingsSectionKit.label(app.title, x: 14, y: row, width: w - 140, size: 12.5,
                                                         weight: .medium, color: .labelColor))
                let word = SettingsSectionKit.label(app.stateWord, x: w - 120 + 14, y: row + 2, width: 120,
                                                    size: 10, weight: .semibold, color: color)
                word.alignment = .right
                word.identifier = NSUserInterfaceItemIdentifier(ID.localState(app.backend))
                card.addSubview(word)
                let status = SettingsSectionKit.wrapped(app.status, x: 14, y: row + 19, width: w, size: 11,
                                                        color: .secondaryLabelColor)
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
            let note = SettingsSectionKit.wrapped(FeatureTourPractice.note(facts.practice, map: facts.hotkeys),
                                                  x: 14, y: y, width: w, size: 12, weight: ready ? .regular : .medium,
                                                  color: ready ? .secondaryLabelColor : .systemOrange)
            note.identifier = NSUserInterfaceItemIdentifier(ID.practiceNote)
            card.addSubview(note)

            let box = NSScrollView(frame: NSRect(x: 14, y: note.frame.maxY + 8, width: w, height: 58))
            box.borderType = .bezelBorder
            box.hasVerticalScroller = true
            box.autohidesScrollers = true
            let text = NSTextView(frame: NSRect(origin: .zero, size: box.contentSize))
            text.isRichText = false
            text.font = .systemFont(ofSize: 13)
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
    private func addFooter(at originY: CGFloat, width: CGFloat) {
        let line = NSBox(frame: NSRect(x: L, y: originY, width: width, height: 1))
        line.boxType = .separator
        addSubview(line)
        let y = originY + 15

        let skip = NSButton(title: FeatureTour.skipTitle, target: self, action: #selector(skipClicked))
        skip.bezelStyle = .rounded
        skip.identifier = NSUserInterfaceItemIdentifier(ID.skip)
        skip.sizeToFit()
        skip.frame = NSRect(x: L - 6, y: y, width: max(skip.frame.width + 16, 90), height: 28)
        addSubview(skip)

        let last = index == count - 1
        let next = NSButton(title: last ? FeatureTour.doneTitle : FeatureTour.nextTitle, target: self,
                            action: #selector(nextClicked))
        next.bezelStyle = .rounded
        next.identifier = NSUserInterfaceItemIdentifier(ID.next)
        // Return pages forward, except where Return belongs to the practice box.
        if page.liveStatus != .practice { next.keyEquivalent = "\r" }
        next.frame = NSRect(x: L + width - 90 + 6, y: y, width: 90, height: 28)
        addSubview(next)

        let back = NSButton(title: FeatureTour.backTitle, target: self, action: #selector(backClicked))
        back.bezelStyle = .rounded
        back.identifier = NSUserInterfaceItemIdentifier(ID.back)
        back.isEnabled = index > 0
        back.frame = NSRect(x: next.frame.minX - 90 - 8, y: y, width: 90, height: 28)
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

/// The page dots: one per page, the current one filled in the theme accent.
final class FeatureTourDotsView: NSView {
    private let count: Int
    private let current: Int
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

    override func draw(_ dirtyRect: NSRect) {
        for dot in 0..<count {
            let x = CGFloat(dot) * (Self.diameter + Self.gap)
            let circle = NSBezierPath(ovalIn: NSRect(x: x, y: 0, width: Self.diameter, height: Self.diameter))
            (dot == current ? Phosphor.green : NSColor.tertiaryLabelColor).setFill()
            circle.fill()
        }
    }
}
