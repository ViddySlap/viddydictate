import Cocoa

/// The ask-back question card (VDASK-3). A dark phosphor panel like the A/B picker, but clickable: it is a
/// non-activating panel that accepts mouse events without ever becoming key, so the user's text field keeps
/// focus. Keyboard (up / down / Return / Esc) and right-Option taps arrive through the global event tap, not
/// through this panel. A small grip at the top drags it with `performDrag(with:)`, which does not activate the
/// app. One card shows at a time; the panel stays where it is when the next card of the same take replaces it.
/// Text comes from `AskCardText` and placement from `AskCardGeometry` (both pure, both tested off-device).
final class AskCardPanel: NSObject {
    /// (card id, option index) from a click on an option row.
    var onChoose: ((UUID, Int) -> Void)?

    private final class CardWindow: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Accepts the first click, so a click on an option works while another app is frontmost.
    private final class CardContentView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class GripView: NSView {
        var onDragEnd: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            onDragEnd?()
        }
        override func draw(_ dirtyRect: NSRect) {
            Phosphor.green.withAlphaComponent(0.45).setFill()
            let w: CGFloat = 36, h: CGFloat = 4
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h),
                         xRadius: 2, yRadius: 2).fill()
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    private final class OptionRow: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private let panel: NSPanel
    private let container = CardContentView()
    private var rows: [(view: OptionRow, label: NSTextField)] = []
    private var model: AskCardModel?

    private static let width: CGFloat = 460

    override init() {
        panel = CardWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Phosphor.configureFloatingPanel(panel)
        panel.ignoresMouseEvents = false        // unlike the A/B picker: this one is clickable
        panel.becomesKeyOnlyIfNeeded = true
        Phosphor.styleContainer(container)
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }
    var currentCardID: UUID? { model?.cardID }

    /// Show `card`. `anchor` is the take's paste target (or the pointer) in AppKit screen coordinates; it only
    /// matters for the first card of a take. A card that replaces a visible one keeps its left edge and top
    /// edge, so a card the user dragged stays where they put it.
    func show(_ card: AskCardModel, anchor: CGPoint) {
        model = card
        build(card)
        let size = container.frame.size
        let screens = NSScreen.screens.map { $0.visibleFrame }
        var frame: NSRect
        if panel.isVisible {
            let old = panel.frame
            frame = AskCardGeometry.clamp(NSRect(x: old.minX, y: old.maxY - size.height,
                                                 width: size.width, height: size.height), to: screens)
        } else {
            frame = AskCardGeometry.frame(size: size, anchor: anchor, screens: screens)
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()            // never makeKey: the user's field keeps focus
    }

    func setHighlight(cardID: UUID, index: Int) {
        guard model?.cardID == cardID, rows.indices.contains(index), var m = model else { return }
        m.highlighted = index
        model = m
        for (i, row) in rows.enumerated() { style(row, number: i + 1, text: m.question.options[i], on: i == index) }
    }

    func hide() {
        model = nil
        panel.orderOut(nil)
    }

    // MARK: layout

    private func build(_ card: AskCardModel) {
        container.subviews.forEach { $0.removeFromSuperview() }
        rows = []
        let pad: CGFloat = 18
        let inner = Self.width - pad * 2
        let green = Phosphor.green

        func text(_ s: String, size: CGFloat, bold: Bool, alpha: CGFloat) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: s)
            f.font = NSFont(name: Phosphor.font + (bold ? " Bold" : ""), size: size)
                ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
            f.textColor = green.withAlphaComponent(alpha)
            f.maximumNumberOfLines = 0
            f.isSelectable = false
            f.preferredMaxLayoutWidth = inner
            return f
        }
        func height(_ f: NSTextField) -> CGFloat {
            let h = f.attributedStringValue.boundingRect(
                with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            return ceil(h) + 2
        }

        let question = text(card.question.question, size: 14, bold: true, alpha: 0.95)
        let said = text(AskCardText.youSaid(card.question.quote), size: 12, bold: false, alpha: 0.85)
        let why = text(card.question.why, size: 11, bold: false, alpha: 0.5)
        let footer = text(AskCardText.footer, size: 11, bold: false, alpha: 0.5)
        footer.maximumNumberOfLines = 1
        let progress = AskCardText.progress(index: card.index, total: card.total)
            .map { text($0, size: 11, bold: false, alpha: 0.6) }

        let gripH: CGFloat = 16, rowH: CGFloat = 28, gap: CGFloat = 8
        let hQ = height(question), hS = height(said), hW = card.question.why.isEmpty ? 0 : height(why)
        let hF: CGFloat = 16
        let optionsH = rowH * CGFloat(card.question.options.count)
        var total = 8 + gripH + gap + hQ + 4 + hS + (hW > 0 ? 4 + hW : 0) + gap + optionsH + gap + hF + 12
        total = ceil(total)
        container.frame = NSRect(x: 0, y: 0, width: Self.width, height: total)

        var y = total - 8 - gripH
        let grip = GripView(frame: NSRect(x: 0, y: y, width: Self.width, height: gripH))
        grip.onDragEnd = { [weak self] in self?.clampAfterDrag() }
        container.addSubview(grip)
        if let progress = progress {
            progress.sizeToFit()
            progress.frame.origin = NSPoint(x: Self.width - pad - progress.frame.width, y: y)
            container.addSubview(progress)
        }
        y -= gap + hQ
        question.frame = NSRect(x: pad, y: y, width: inner, height: hQ); container.addSubview(question)
        y -= 4 + hS
        said.frame = NSRect(x: pad, y: y, width: inner, height: hS); container.addSubview(said)
        if hW > 0 {
            y -= 4 + hW
            why.frame = NSRect(x: pad, y: y, width: inner, height: hW); container.addSubview(why)
        }
        y -= gap
        for (i, option) in card.question.options.enumerated() {
            y -= rowH
            let row = OptionRow(frame: NSRect(x: pad - 6, y: y, width: inner + 12, height: rowH - 2))
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 8, y: 4, width: row.frame.width - 16, height: rowH - 10)
            label.isSelectable = false
            row.addSubview(label)
            let cardID = card.cardID
            row.onClick = { [weak self] in self?.onChoose?(cardID, i) }
            container.addSubview(row)
            rows.append((row, label))
            style(rows[i], number: i + 1, text: option, on: i == card.highlighted)
        }
        y -= gap + hF
        footer.frame = NSRect(x: pad, y: y, width: inner, height: hF)
        container.addSubview(footer)
    }

    private func style(_ row: (view: OptionRow, label: NSTextField), number: Int, text: String, on: Bool) {
        let green = Phosphor.green
        row.label.attributedStringValue = NSAttributedString(
            string: AskCardText.optionLine(number: number, text: text, highlighted: on),
            attributes: [.font: NSFont(name: Phosphor.font, size: 13) ?? .systemFont(ofSize: 13),
                         .foregroundColor: green.withAlphaComponent(on ? 0.98 : 0.7)])
        row.view.layer?.backgroundColor = on ? green.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
    }

    private func clampAfterDrag() {
        let screens = NSScreen.screens.map { $0.visibleFrame }
        let clamped = AskCardGeometry.clamp(panel.frame, to: screens)
        if clamped != panel.frame { panel.setFrame(clamped, display: true, animate: false) }
    }
}
