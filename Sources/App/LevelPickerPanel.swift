import Cocoa

/// The Option+P prompt-prep level picker: three horizontal cells - Cleanup / Tighten / Summarize -
/// labelled with the exact shipped `CleanupLevel.label` strings. Left/Right arrows move the
/// selection, Return runs the chosen level, Escape cancels (text untouched).
///
/// Keyboard-driven via the global event tap (`HotkeyMonitor.levelPickerActive`), NOT by taking key
/// focus — so the user's text field stays focused and the transformed text pastes straight back into
/// it. The panel ignores mouse events and never activates the app. This is the same UX shape as
/// `ABPickerPanel`, generalized to a 3-way pick (and sharing its CRT-phosphor theme + panel chrome
/// via `Phosphor`); the default selection is the sticky last-used level.
final class LevelPickerPanel: NSObject {
    /// The currently highlighted level index (0 Cleanup / 1 Tighten / 2 Summarize).
    private(set) var selectedIndex = CleanupLevel.tighten.rawValue

    private let panel: NSPanel
    private let container = NSView()
    private let header = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var cells: [LevelCell] = []

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Phosphor.configureFloatingPanel(panel)
        Phosphor.styleContainer(container)

        header.attributedStringValue = Phosphor.kerned("PROMPT PREP - PICK A LEVEL",
                                              color: Phosphor.green.withAlphaComponent(0.92), size: 13, kern: 2.5)
        footer.attributedStringValue = Phosphor.kerned("left / right to choose      return to run      esc cancels",
                                              color: Phosphor.green.withAlphaComponent(0.55), size: 11, kern: 1.5)

        for level in CleanupLevel.allCases {
            cells.append(LevelCell(title: level.label))
        }
        container.addSubview(header)
        container.addSubview(footer)
        cells.forEach { container.addSubview($0) }
        panel.contentView = container
    }

    /// Show the picker centered on the main screen with `selected` pre-highlighted (the sticky level).
    func show(selected: Int) {
        selectedIndex = CleanupLevel.clamped(selected).rawValue

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let W = min(CGFloat(560), screen.width - 120)
        let padX: CGFloat = 22, gap: CGFloat = 14
        let headerH: CGFloat = 22, footerH: CGFloat = 18
        let padTop: CGFloat = 18, padMid: CGFloat = 16, padBottom: CGFloat = 14
        let cellH: CGFloat = 64
        let cellW = (W - padX * 2 - gap * 2) / 3
        let layout = Phosphor.headerContentFooterLayout(
            width: W,
            contentH: cellH,
            padX: padX,
            headerH: headerH,
            footerH: footerH,
            padTop: padTop,
            padMid: padMid,
            padBottom: padBottom
        )
        let H = layout.totalHeight

        header.frame = layout.headerFrame
        let cellY = layout.contentY
        for (i, cell) in cells.enumerated() {
            cell.frame = NSRect(x: padX + (cellW + gap) * CGFloat(i), y: cellY, width: cellW, height: cellH)
        }
        footer.frame = layout.footerFrame

        applySelection()
        Phosphor.presentCentered(panel, container: container, width: W, height: H, on: screen)
    }

    func moveLeft()  { selectedIndex = CleanupLevel.clamped(selectedIndex - 1).rawValue; applySelection() }
    func moveRight() { selectedIndex = CleanupLevel.clamped(selectedIndex + 1).rawValue; applySelection() }

    private func applySelection() {
        for (i, cell) in cells.enumerated() { cell.setSelected(i == selectedIndex) }
    }

    func hide() { panel.orderOut(nil) }
}

/// One cell of the level picker: a titled, bordered phosphor box that brightens + glows when selected.
private final class LevelCell: NSView {
    private let title: String
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        label.alignment = .center
        label.maximumNumberOfLines = 1
        addSubview(label)
        setSelected(false)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    func setSelected(_ on: Bool) {
        label.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont(name: Phosphor.font, size: 15) ?? .systemFont(ofSize: 15),
            .foregroundColor: Phosphor.green.withAlphaComponent(on ? 0.98 : 0.6), .kern: 1.5,
        ])
        Phosphor.styleCell(self, selected: on)
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 20
        label.frame = NSRect(x: 6, y: (bounds.height - h) / 2, width: bounds.width - 12, height: h)
    }
}
