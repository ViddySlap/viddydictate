import Cocoa

/// The point-of-use offer, in place, where the result would have been (B13, B14).
///
/// It is the third panel in the family `ABPickerPanel` and `LevelPickerPanel` established, and it is
/// deliberately the same shape rather than a new kind of window. Borderless, non-activating,
/// keyboard-driven over the global tap (`HotkeyMonitor.installOfferActive`), so the user's text field
/// keeps focus and whatever already landed there stays put. That matters more here than for the other
/// two: this panel appears immediately AFTER a raw transcript has been pasted into the user's document,
/// and a panel that stole focus would leave them typing into ViddyDictate instead.
///
/// Pages, one panel, because B13 says so outright: "the same panel offers that install first". The
/// chooser, the install offer, the local-app choice and the running install are states of one surface, not
/// four windows.
final class InstallOfferPanel: NSObject {

    enum State: Equatable {
        case offer(PointOfUseOffer)
        /// Which local app to install, on a Mac with neither (spec D3): LM Studio first as the simple,
        /// recommended install, Ollama second as the advanced one. Opened from `offer`'s install button, and
        /// carries that offer so the picked app's components come from the same decision.
        case appChoice(PointOfUseOffer, PointOfUseLocalAppChoice)
        /// The install is running. Rows come from the SHARED bootstrap state, so this page shows exactly
        /// what the setup surface shows for the same component - one mechanism observed twice.
        case running(PointOfUseInstallOffer, [BootstrapComponentRecord])
    }

    /// What a running row last reported (`BootstrapInstallCoordinator.activity(for:)`), keyed by component id:
    /// an Ollama pull's real bytes, or the wait for Ollama's macOS prompt. The presenter wires it to the
    /// shared queue; the default reports nothing, which renders every row by phase alone.
    var activity: (String) -> InstallerLocalActivity? = { _ in nil }

    private(set) var selectedIndex = 0
    private(set) var state: State?

    private let panel: NSPanel
    private let container = NSView()

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 260),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Phosphor.configureFloatingPanel(panel)
        Phosphor.styleContainer(container)
        panel.contentView = container
    }

    /// The buttons of the current state, in the order they are drawn.
    var buttons: [PointOfUseButton] {
        switch state {
        case .offer(let offer): return offer.buttons
        case .appChoice(_, let choice): return choice.buttons
        // Nothing to arrow through while the queue works; Retry and Close once it finished with a failure.
        case .running(_, let records): return PointOfUsePolicy.runningButtons(records)
        case .none: return []
        }
    }

    var selectedButton: PointOfUseButton? {
        guard selectedIndex >= 0, selectedIndex < buttons.count else { return nil }
        return buttons[selectedIndex]
    }

    func show(_ state: State) {
        // A state change never silently keeps a stale highlight: the running page has no buttons, and the
        // offer page always opens on its first one.
        if !isSameKind(state, as: self.state) { selectedIndex = 0 }
        self.state = state
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = layout(state, screen: screen)
        Phosphor.presentCentered(panel, container: container, width: size.width, height: size.height,
                                 on: screen)
    }

    func hide() {
        panel.orderOut(nil)
        state = nil
    }

    func moveLeft() {
        guard !buttons.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        applySelection()
    }

    func moveRight() {
        guard !buttons.isEmpty else { return }
        selectedIndex = min(buttons.count - 1, selectedIndex + 1)
        applySelection()
    }

    /// Render one state offscreen and hand back the container, for the render gate. It runs the exact
    /// production layout - there is no second drawing path that could look right while the shipped one
    /// does not.
    func renderForSeam(_ state: State,
                       screen: NSRect = NSRect(x: 0, y: 0, width: 1440, height: 900)) -> NSView {
        if !isSameKind(state, as: self.state) { selectedIndex = 0 }
        self.state = state
        let size = layout(state, screen: screen)
        container.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        return container
    }

    private func isSameKind(_ lhs: State, as rhs: State?) -> Bool {
        guard let rhs else { return false }
        switch (lhs, rhs) {
        case (.offer(let a), .offer(let b)): return a.featureID == b.featureID && a.buttons == b.buttons
        case (.appChoice(let a, _), .appChoice(let b, _)): return a.featureID == b.featureID
        case (.running, .running): return true
        default: return false
        }
    }

    // MARK: - layout

    private var cells: [OfferCell] = []

    @discardableResult
    private func layout(_ state: State, screen: NSRect) -> NSSize {
        container.subviews.forEach { $0.removeFromSuperview() }
        cells = []

        // A four-up row of cells needs more room than a two-up one, and the titles are the spec's own
        // words rather than anything this panel gets to shorten. Widen for the chooser instead.
        let preferred: CGFloat = buttons.count > 2 ? 780 : 640
        let W = min(preferred, max(420, screen.width - 120))
        let padX: CGFloat = 22
        let textW = W - padX * 2

        let header = kernedLabel(headerText(state), size: 13, kern: 2.5, alpha: 0.92)
        let footer = kernedLabel(footerText(state), size: 11, kern: 1.5, alpha: 0.55)

        // Measure the body first: the copy names a real model id and a real vendor error, and neither has
        // a length this panel gets to assume. The panel grows; the text is never clipped.
        var bodyFields: [NSTextField] = []
        for (index, line) in lines(state).enumerated() {
            let field = wrappingLabel(line, width: textW, size: 12, alpha: 0.9)
            field.identifier = NSUserInterfaceItemIdentifier(PointOfUsePolicy.lineIdentifier(index))
            bodyFields.append(field)
        }
        let lineGap: CGFloat = 6
        let bodyH = bodyFields.reduce(CGFloat(0)) { $0 + $1.frame.height + lineGap }
            - (bodyFields.isEmpty ? 0 : lineGap)

        let cellGap: CGFloat = 12
        let buttonRow = cellContents(state)
        // Cells are measured, not guessed. The detail lines name a real model id and a real byte count,
        // and the first render of this panel clipped every one of the chooser's four - a fixed height
        // cannot know how tall the copy it was handed is.
        let cellW = buttonRow.isEmpty ? 0
            : (W - padX * 2 - cellGap * CGFloat(buttonRow.count - 1)) / CGFloat(buttonRow.count)
        let cellH = buttonRow.isEmpty ? 0
            : buttonRow.map {
                OfferCell.height(badge: $0.badge, title: $0.button.title, detail: $0.detail, width: cellW)
            }.max()!
        let contentH = bodyH + (buttonRow.isEmpty ? 0 : 16 + cellH)

        let geometry = Phosphor.headerContentFooterLayout(
            width: W, contentH: contentH, padX: padX, headerH: 22, footerH: 18,
            padTop: 16, padMid: 14, padBottom: 14)
        let H = geometry.totalHeight

        header.frame = geometry.headerFrame
        header.identifier = NSUserInterfaceItemIdentifier(PointOfUsePolicy.headerIdentifier)
        container.addSubview(header)

        // The panel's own coordinate space is bottom-up, so the body is laid out downward from the top of
        // the content band.
        var y = geometry.contentY + contentH
        for field in bodyFields {
            y -= field.frame.height
            field.frame.origin = NSPoint(x: padX, y: y)
            container.addSubview(field)
            y -= lineGap
        }

        if !buttonRow.isEmpty {
            for (index, content) in buttonRow.enumerated() {
                let cell = OfferCell(badge: content.badge, title: content.button.title, detail: content.detail)
                cell.identifier = NSUserInterfaceItemIdentifier(
                    PointOfUsePolicy.buttonIdentifier(content.button.id))
                cell.frame = NSRect(x: padX + (cellW + cellGap) * CGFloat(index),
                                    y: geometry.contentY, width: cellW, height: cellH)
                container.addSubview(cell)
                cells.append(cell)
            }
        }

        footer.frame = geometry.footerFrame
        footer.identifier = NSUserInterfaceItemIdentifier(PointOfUsePolicy.footerIdentifier)
        container.addSubview(footer)

        applySelection()
        container.frame = NSRect(x: 0, y: 0, width: W, height: H)
        return NSSize(width: W, height: H)
    }

    private func applySelection() {
        for (index, cell) in cells.enumerated() { cell.setSelected(index == selectedIndex) }
    }

    /// What each cell draws: the button, plus on the choice page the option's label above its title and its
    /// whole description (the Ollama warning included) under it.
    private func cellContents(_ state: State) -> [PointOfUseLocalAppChoice.Cell] {
        if case .appChoice(_, let choice) = state { return choice.cells }
        return buttons.map { PointOfUseLocalAppChoice.Cell(button: $0, badge: nil, detail: $0.detail) }
    }

    private func headerText(_ state: State) -> String {
        switch state {
        case .offer(let offer): return offer.header
        case .appChoice(_, let choice): return choice.header
        case .running(let offer, _): return "INSTALLING - \(offer.featureTitle.uppercased())"
        }
    }

    private func lines(_ state: State) -> [String] {
        switch state {
        case .offer(let offer): return offer.lines
        case .appChoice(_, let choice): return choice.lines
        case .running(_, let records): return PointOfUsePolicy.runningLines(records, activity: activity)
        }
    }

    private func footerText(_ state: State) -> String {
        switch state {
        case .offer, .appChoice: return PointOfUsePolicy.keyHint
        // B9's promise, restated where it is actually being relied on: closing this does not cancel
        // anything. No time estimate appears here or anywhere else (B7). Once the queue has finished with a
        // failure there is nothing left to keep going, and the page has Retry and Close to choose between.
        case .running(_, let records):
            return PointOfUsePolicy.runningButtons(records).isEmpty
                ? "esc closes this      the download keeps going" : PointOfUsePolicy.keyHint
        }
    }

    // MARK: - view helpers

    private func kernedLabel(_ value: String, size: CGFloat, kern: CGFloat,
                             alpha: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = Phosphor.kerned(
            value, color: Phosphor.green.withAlphaComponent(alpha), size: size, kern: kern)
        return field
    }

    private func wrappingLabel(_ value: String, width: CGFloat, size: CGFloat,
                               alpha: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        field.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: NSFont(name: Phosphor.font, size: size) ?? .systemFont(ofSize: size),
            .foregroundColor: Phosphor.green.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ])
        field.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        field.frame.size.height = ceil(
            field.attributedStringValue.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        return field
    }
}

/// One button of the offer panel: the title, and under it the one line saying what pressing it does.
/// The consequence is part of the button rather than a legend elsewhere, because a choice whose result
/// the user did not read is not the informed choice B1 is asking for.
private final class OfferCell: NSView {
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let badge: String?
    private let title: String
    private let detail: String

    /// `badge` is the local-app choice's "SIMPLE - RECOMMENDED" / "ADVANCED", drawn small above the title so
    /// the two apps never read as equals (D3). nil draws exactly the two-line cell every other page uses.
    init(badge: String? = nil, title: String, detail: String) {
        self.badge = badge
        self.title = title
        self.detail = detail
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        titleLabel.alignment = .center
        // Two lines, because "Set up local models" is the spec's own button title and truncating it to
        // "Set up local" is the panel deciding what B14 said.
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.wraps = true
        titleLabel.cell?.isScrollable = false
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.cell?.wraps = true
        detailLabel.cell?.isScrollable = false
        badgeLabel.alignment = .center
        badgeLabel.identifier = NSUserInterfaceItemIdentifier("point-of-use-badge")
        if badge != nil { addSubview(badgeLabel) }
        addSubview(titleLabel)
        addSubview(detailLabel)
        setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 8
    private static let titleGap: CGFloat = 3
    private static let badgeSize: CGFloat = 9
    private static let badgeKern: CGFloat = 1.2

    /// The height this cell needs for the copy it was given, at the width it will be drawn at. Uses the
    /// same fonts the cell draws with, so the measurement and the drawing cannot disagree.
    static func height(badge: String? = nil, title: String, detail: String, width: CGFloat) -> CGFloat {
        let inner = max(20, width - horizontalPadding * 2)
        // Each part is rounded UP the same way `layout` rounds it. Rounding the sum instead left the
        // detail label one point short of its own text on three of the four chooser cells.
        let titleH = ceil(measure(title, font: font(size: 13), width: inner))
        let detailH = ceil(measure(detail, font: font(size: 9.5), width: inner))
        return verticalPadding * 2 + badgeHeight(badge, width: inner) + titleH + titleGap + detailH
    }

    /// The badge's line plus its gap to the title, or nothing when the cell has no badge.
    private static func badgeHeight(_ badge: String?, width: CGFloat) -> CGFloat {
        guard let badge else { return 0 }
        return ceil(badgeString(badge, alpha: 1).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + titleGap
    }

    private static func badgeString(_ badge: String, alpha: CGFloat) -> NSAttributedString {
        NSAttributedString(string: badge, attributes: [
            .font: font(size: badgeSize), .kern: badgeKern,
            .foregroundColor: Phosphor.green.withAlphaComponent(alpha),
        ])
    }

    private static func font(size: CGFloat) -> NSFont {
        NSFont(name: Phosphor.font, size: size) ?? .systemFont(ofSize: size)
    }

    private static func measure(_ value: String, font: NSFont, width: CGFloat) -> CGFloat {
        NSAttributedString(string: value, attributes: [.font: font]).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    }

    func setSelected(_ on: Bool) {
        if let badge {
            badgeLabel.attributedStringValue = Self.badgeString(badge, alpha: on ? 0.9 : 0.5)
        }
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont(name: Phosphor.font, size: 13) ?? .systemFont(ofSize: 13),
            .foregroundColor: Phosphor.green.withAlphaComponent(on ? 0.98 : 0.6), .kern: 1.2,
        ])
        detailLabel.attributedStringValue = NSAttributedString(string: detail, attributes: [
            .font: NSFont(name: Phosphor.font, size: 9.5) ?? .systemFont(ofSize: 9.5),
            .foregroundColor: Phosphor.green.withAlphaComponent(on ? 0.72 : 0.42),
        ])
        Phosphor.styleCell(self, selected: on)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Self.horizontalPadding
        let vpad = Self.verticalPadding
        let inner = max(20, bounds.width - pad * 2)
        let badgeH = Self.badgeHeight(badge, width: inner)
        if badge != nil {
            badgeLabel.frame = NSRect(x: pad, y: bounds.height - vpad - (badgeH - Self.titleGap),
                                      width: inner, height: badgeH - Self.titleGap)
        }
        let titleH = ceil(Self.measure(title, font: Self.font(size: 13), width: inner))
        titleLabel.frame = NSRect(x: pad, y: bounds.height - vpad - badgeH - titleH, width: inner,
                                  height: titleH)
        detailLabel.frame = NSRect(x: pad, y: vpad, width: inner,
                                   height: max(0, bounds.height - vpad * 2 - badgeH - titleH - Self.titleGap))
    }
}
