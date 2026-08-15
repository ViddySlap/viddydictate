import Cocoa

/// The cleanup-suspect A/B picker. When the sanity guard flags a cleanup output as likely-rogue
/// (`CleanupLogic.cleanupSuspect`), the app does NOT auto-paste it. Instead this panel pops with the
/// raw transcript on the LEFT and the suspect cleaned output on the RIGHT, so the user reads both and
/// chooses. Left/Right arrows move the selection, Return commits, Escape commits the safe (raw) side.
///
/// Keyboard-driven via the global event tap (`HotkeyMonitor.abPickerActive`), NOT by taking key focus
/// — so the user's text field stays focused and the chosen text pastes straight back into it. The
/// panel therefore ignores mouse events and never activates the app. RAW (left) is pre-selected,
/// because the panel only appears when the cleaned side is already suspect: a reflexive Return is safe.
/// Shares the CRT-phosphor theme + panel chrome with `LevelPickerPanel` via `Phosphor`.
final class ABPickerPanel: NSObject {
    /// Which side is currently highlighted. RAW is the safe default.
    enum Side { case raw, cleaned }
    private(set) var selection: Side = .raw

    private let panel: NSPanel
    private let container = NSView()
    private let header = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let rawPane = PaneBox(title: "RAW")
    private let cleanedPane = PaneBox(title: "CLEANED")

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 360),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Phosphor.configureFloatingPanel(panel)
        Phosphor.styleContainer(container)

        header.attributedStringValue = Phosphor.kerned("CLEANUP LOOKS OFF - PICK WHAT TO PASTE",
                                              color: Phosphor.green.withAlphaComponent(0.92), size: 13, kern: 2.5)
        footer.attributedStringValue = Phosphor.kerned("left / right to choose      return to paste      esc keeps raw",
                                              color: Phosphor.green.withAlphaComponent(0.55), size: 11, kern: 1.5)

        container.addSubview(header)
        container.addSubview(footer)
        container.addSubview(rawPane)
        container.addSubview(cleanedPane)
        panel.contentView = container
    }

    /// Show the picker centered on the main screen with the two candidates. Resets selection to RAW.
    func show(raw: String, cleaned: String) {
        selection = .raw
        rawPane.setBody(raw)
        cleanedPane.setBody(cleaned)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let W = min(CGFloat(820), screen.width - 120)
        let padX: CGFloat = 22, gap: CGFloat = 18
        let headerH: CGFloat = 22, footerH: CGFloat = 18
        let padTop: CGFloat = 16, padMid: CGFloat = 12, padBottom: CGFloat = 14
        let paneW = (W - padX * 2 - gap) / 2
        let paneH: CGFloat = min(300, max(120, screen.height * 0.4))
        let layout = Phosphor.headerContentFooterLayout(
            width: W,
            contentH: paneH,
            padX: padX,
            headerH: headerH,
            footerH: footerH,
            padTop: padTop,
            padMid: padMid,
            padBottom: padBottom
        )
        let H = layout.totalHeight

        header.frame = layout.headerFrame
        let paneY = layout.contentY
        rawPane.frame = NSRect(x: padX, y: paneY, width: paneW, height: paneH)
        cleanedPane.frame = NSRect(x: padX + paneW + gap, y: paneY, width: paneW, height: paneH)
        footer.frame = layout.footerFrame

        applySelection()
        Phosphor.presentCentered(panel, container: container, width: W, height: H, on: screen)
    }

    func selectRaw()     { selection = .raw;     applySelection() }
    func selectCleaned() { selection = .cleaned; applySelection() }

    private func applySelection() {
        rawPane.setSelected(selection == .raw)
        cleanedPane.setSelected(selection == .cleaned)
    }

    func hide() { panel.orderOut(nil) }
}

/// One side of the A/B picker: a titled, bordered phosphor box that brightens + glows when selected.
private final class PaneBox: NSView {
    private let title: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        layer?.masksToBounds = true
        titleLabel.maximumNumberOfLines = 1
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        body.cell?.isScrollable = false
        addSubview(titleLabel)
        addSubview(body)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    func setBody(_ text: String) {
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont(name: Phosphor.font, size: 11) ?? .systemFont(ofSize: 11),
            .foregroundColor: Phosphor.green.withAlphaComponent(0.85), .kern: 2.0,
        ])
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        body.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: Phosphor.font, size: 13) ?? .systemFont(ofSize: 13),
            .foregroundColor: Phosphor.green.withAlphaComponent(0.92), .paragraphStyle: para,
        ])
        needsLayout = true
    }

    func setSelected(_ on: Bool) {
        Phosphor.styleCell(self, selected: on)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14, titleH: CGFloat = 16, gap: CGFloat = 8
        titleLabel.frame = NSRect(x: pad, y: bounds.height - pad - titleH, width: bounds.width - pad * 2, height: titleH)
        body.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2,
                            height: bounds.height - pad * 2 - titleH - gap)
    }
}
