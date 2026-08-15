import Cocoa

// MARK: - HUD home position

/// Where the HUD (full or Final-only pill) anchors itself each time it appears. Persisted as the
/// rawValue in Settings; `origin(for:in:)` turns the anchor into a concrete bottom-left origin for
/// the current panel size, so the same setting drives both HUD shapes.
enum HUDPosition: String, CaseIterable {
    case topLeft, topCenter, topRight
    case centerLeft, center, centerRight
    case bottomLeft, bottomCenter, bottomRight

    var label: String {
        switch self {
        case .topLeft:      return "Top Left"
        case .topCenter:    return "Top Middle"
        case .topRight:     return "Top Right"
        case .centerLeft:   return "Left Middle"
        case .center:       return "Center"
        case .centerRight:  return "Right Middle"
        case .bottomLeft:   return "Bottom Left"
        case .bottomCenter: return "Bottom Middle"
        case .bottomRight:  return "Bottom Right"
        }
    }

    /// Bottom-left origin for a panel of `size` inside the visible frame `vf`. The bottom margin
    /// keeps the historical bottom-center home (80pt above the dock line); sides and top sit a
    /// little tighter.
    func origin(for size: NSSize, in vf: NSRect) -> NSPoint {
        let mx: CGFloat = 48, mTop: CGFloat = 48, mBottom: CGFloat = 80
        let x: CGFloat
        switch self {
        case .topLeft, .centerLeft, .bottomLeft:    x = vf.minX + mx
        case .topCenter, .center, .bottomCenter:    x = vf.midX - size.width / 2
        case .topRight, .centerRight, .bottomRight: x = vf.maxX - mx - size.width
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight:          y = vf.maxY - mTop - size.height
        case .centerLeft, .center, .centerRight:       y = vf.midY - size.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = vf.minY + mBottom
        }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - shared pill base size

/// The base (scale=1.0) footprint of the Final-only scope/info pill — the floor every scaled pill
/// size (`round(_ * Settings.hudPillScale)`) derives from. HUDProbe.swift's golden-value pixel
/// assertions are intentionally left as literal 300/64 (NOT wired to this constant) so they still
/// catch accidental drift here — do not touch HUDProbe.swift in this change.
enum HUDPillMetrics {
    static let baseWidth: CGFloat = 300
    static let baseHeight: CGFloat = 64
}

// MARK: - Drag handle (grip dots; moves the panel, persists position)

final class DragHandle: NSView {
    var onMoved: ((NSPoint) -> Void)?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        let c = Phosphor.green.withAlphaComponent(0.4)
        c.setFill()
        let r: CGFloat = 1.4
        for col in 0..<2 {
            for row in 0..<3 {
                let x = bounds.midX - 3 + CGFloat(col) * 6
                let y = bounds.midY - 5 + CGFloat(row) * 5
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let now = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: startOrigin.x + (now.x - startMouse.x),
                                   y: startOrigin.y + (now.y - startMouse.y)))
    }
    override func mouseUp(with event: NSEvent) {
        if let o = window?.frame.origin { onMoved?(o) }
    }
}

// MARK: - CRT display box (translucent green + scanlines + radial glow)

/// The phosphor CRT box (translucent green fill + radial glow + scanlines). Internal (not file-private)
/// so the low-power info pill can reuse the exact same CRT language in its own capsule. `borderColor`
/// is nil for the full HUD box and the scope pill (unchanged look); the info pill sets a thin green
/// border so the smaller second capsule reads as its own bounded surface.
final class DisplayView: NSView {
    override var isFlipped: Bool { false }
    /// Corner rounding — 10 for the full HUD box; the low-power pill sets height/2 for a capsule.
    var cornerRadius: CGFloat = 10 { didSet { needsDisplay = true } }
    /// Optional thin border stroked inside the rounded rect (info pill only; nil = no border).
    var borderColor: NSColor? = nil { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        Phosphor.panelBG.withAlphaComponent(0.80).setFill()   // themed CRT fill (default rgba(0,22,8,.8))
        bounds.fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let cols = [Phosphor.green.withAlphaComponent(0.04).cgColor,
                        Phosphor.green.withAlphaComponent(0.0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 1]) {
                let c = CGPoint(x: bounds.midX, y: bounds.midY)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                       endRadius: bounds.width * 0.45, options: [])
            }
        }
        NSColor(white: 0, alpha: 0.10).setFill()
        var y: CGFloat = 0
        while y < bounds.height { NSRect(x: 0, y: y, width: bounds.width, height: 1).fill(); y += 4 }
        NSGraphicsContext.restoreGraphicsState()
        if let bc = borderColor, borderWidth > 0 {
            let inset = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            let br = max(0, cornerRadius - borderWidth / 2)
            let bp = NSBezierPath(roundedRect: inset, xRadius: br, yRadius: br)
            bc.setStroke(); bp.lineWidth = borderWidth; bp.stroke()
        }
    }
}

// MARK: - Frosted-glass button (hover glow; green or red tint)

final class GlassButton: NSButton {
    private let isStop: Bool
    private var titleText: String
    private var hovering = false { didSet { updateStyle() } }
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String, isStop: Bool, target: AnyObject?, action: Selector) {
        self.isStop = isStop
        self.titleText = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    func set(title: String, symbol: String) {
        titleText = title
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        updateStyle()
    }

    private func base() -> NSColor { isStop ? NSColor(srgbRed: 1, green: 0.39, blue: 0.39, alpha: 0.8) : NSColor(white: 1, alpha: 0.65) }
    private func hot()  -> NSColor { isStop ? NSColor(srgbRed: 1, green: 0.33, blue: 0.33, alpha: 1)   : Phosphor.green }

    private func updateStyle() {
        let color = hovering ? hot() : base()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        attributedTitle = NSAttributedString(string: titleText, attributes: [
            .font: NSFont(name: Phosphor.font, size: 11) ?? .systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: color, .kern: 2.0, .paragraphStyle: para,
        ])
        contentTintColor = color
        let bg = hovering
            ? (isStop ? NSColor(srgbRed: 0.12, green: 0.02, blue: 0.02, alpha: 0.7) : Phosphor.themed(NSColor(srgbRed: 0, green: 0.08, blue: 0.03, alpha: 0.7)))
            : NSColor(white: 0, alpha: 0.55)
        let border = hovering
            ? (isStop ? NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 0.6) : Phosphor.green.withAlphaComponent(0.4))
            : (isStop ? NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 0.25) : NSColor(white: 1, alpha: 0.10))
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = border.cgColor
        if hovering {
            layer?.shadowColor = hot().cgColor; layer?.shadowRadius = 7
            layer?.shadowOpacity = 0.5; layer?.shadowOffset = .zero; layer?.masksToBounds = false
        } else {
            layer?.shadowOpacity = 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 26, height: 28) }
}
