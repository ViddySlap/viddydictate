import Cocoa

/// The keycap-style mode badge that pops the instant the `?` chord registers (build spec "Mode
/// indicator"). A rounded MacBook-keycap rectangle with a single clean `?` glyph centered, the mode
/// label beside it ("Cleanup" / "Raw"), in the same CRT-green phosphor language as the HUD. Floats
/// just above the HUD and auto-dismisses. Glyph + label are passed in from the mode registry, so new
/// modes / editable hotkeys update it with zero rework.
final class ModeBadgePanel: NSObject {
    private let panel: NSPanel
    private let container = NSView()
    private let keycap = KeycapView()
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private var phosphor: NSColor { Phosphor.green }   // live, so a theme change recolors the badge
    private let H: CGFloat = 46

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 46),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container.wantsLayer = true
        label.font = NSFont(name: Phosphor.font, size: 14) ?? .systemFont(ofSize: 14, weight: .semibold)
        container.addSubview(keycap)
        container.addSubview(label)
        panel.contentView = container
    }

    /// Show the badge centered above `anchorFrame` (the HUD frame) with the given glyph + label.
    func flash(glyph: String, label labelText: String, above anchorFrame: NSRect) {
        keycap.glyph = glyph
        keycap.tint = phosphor
        keycap.needsDisplay = true
        label.attributedStringValue = Phosphor.kerned(
            labelText.uppercased(),
            color: phosphor.withAlphaComponent(0.92),
            size: 14,
            kern: 3.0
        )
        label.sizeToFit()

        let keycapW: CGFloat = 34, gap: CGFloat = 12, padX: CGFloat = 14
        let labelW = ceil(label.frame.width)
        let totalW = padX + keycapW + gap + labelW + padX
        keycap.frame = NSRect(x: padX, y: (H - 34) / 2, width: keycapW, height: 34)
        label.frame = NSRect(x: padX + keycapW + gap, y: (H - label.frame.height) / 2,
                             width: labelW, height: label.frame.height)

        container.frame = NSRect(x: 0, y: 0, width: totalW, height: H)
        container.layer?.backgroundColor = Phosphor.panelBG.withAlphaComponent(0.92).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = phosphor.withAlphaComponent(0.35).cgColor

        let x = anchorFrame.midX - totalW / 2
        let y = anchorFrame.maxY + 10
        panel.setFrame(NSRect(x: x, y: y, width: totalW, height: H), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    /// Offscreen render seam for `--hud-render`: lay the badge out for `glyph` / `labelText` and return
    /// a bitmap of the composite, WITHOUT leaving the panel on screen or a dismiss timer behind. The
    /// badge is the keycap REFERENCE — its proportion is the one `KeycapView.glyphToBoxRatio` encodes —
    /// so work that changes the shared renderer has to be able to prove the reference did not regress.
    /// In-process, no screen capture.
    func renderForSeam(glyph: String, label labelText: String) -> CGImage? {
        flash(glyph: glyph, label: labelText, above: NSRect(x: 200, y: 400, width: 300, height: 40))
        hideTimer?.invalidate(); hideTimer = nil
        panel.orderOut(nil)
        container.layoutSubtreeIfNeeded()
        let b = container.bounds
        guard b.width > 0, b.height > 0, let rep = container.bitmapImageRepForCachingDisplay(in: b) else { return nil }
        container.cacheDisplay(in: b, to: rep)
        return rep.cgImage
    }

    /// GUI-render seam: the badge keycap's live box, the point size it will actually draw at, its frame
    /// inside the bitmap `renderForSeam` returns, and how tall that bitmap is in points.
    var keycapGeometryForTesting: (box: NSSize, fontSize: CGFloat, frame: NSRect, canvasHeight: CGFloat) {
        (keycap.frame.size, keycap.effectiveFontSize, keycap.frame, container.bounds.height)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }
}

/// The keycap glyph box — a near-square rounded rectangle (MacBook-keycap proportions) with one
/// centered glyph, drawn in phosphor green with a soft glow. Reused by the pop-up mode badge AND by
/// the persistent keycap in the HUD info bar, so the two always match. `fontSize` / `cornerRadius` /
/// `glowRadius` let the small HUD instance share the exact same drawing code at ~13px.
final class KeycapView: NSView {
    /// Glyph point size as a fraction of the keycap box's shorter side. This is the toast badge's own
    /// long-standing proportion (a 19pt glyph in a 34x34 box) promoted to THE keycap rule, because the
    /// badge is the instance that has always looked right. The info pill drew the same 19pt glyph in a
    /// 15x16 box — about 1.19 — and the glyph bled straight past the border.
    ///
    /// The RULE is what is gated, not the numbers it happens to produce: a keycap that leaves
    /// `fontSize` nil can only ever draw in proportion, at any box size and any pill scale.
    static let glyphToBoxRatio: CGFloat = 19.0 / 34.0

    /// The glyph point size a box of `side` points earns under the ratio.
    static func glyphSize(forBox side: CGFloat) -> CGFloat { round(side * glyphToBoxRatio) }

    var glyph: String = "?"
    var tint: NSColor = .green
    /// Explicit glyph point size, overriding the ratio. `nil` — the default, and what the toast badge
    /// and the info-pill keycap both use — DERIVES the size from this view's own box, so the glyph
    /// cannot fall out of proportion when either the box or the pill scale changes. Only the cramped
    /// full-HUD status-row keycap, which is a fixed 14x15 slot in a fixed-height row, sets it.
    var fontSize: CGFloat?
    var cornerRadius: CGFloat = 7
    var glowRadius: CGFloat = 8
    /// Dim (un-lit) keycap: muted fill, no glow — used to show "cleanup is OFF" in the HUD bar.
    var lit: Bool = true

    /// The point size this keycap will actually draw at its current bounds.
    var effectiveFontSize: CGFloat {
        fontSize ?? KeycapView.glyphSize(forBox: min(bounds.width, bounds.height))
    }

    override var isFlipped: Bool { false }

    /// Origin for `draw(at:)` that centers a glyph's VISUAL box in `box`.
    ///
    /// The old centering used `NSAttributedString.size().height`, i.e. the line box, which hangs the
    /// mark off-center by roughly half the descender — plainly visible on a keycap this small, and
    /// badly wrong for a rebound key whose glyph actually descends (`,` `;`). Centre on the glyph's own
    /// path bounds instead, both axes: `size().width` is the advance and carries side bearings too.
    static func glyphOrigin(for s: NSAttributedString, font: NSFont, in box: NSRect) -> NSPoint {
        let ink = Phosphor.inkBox(for: s)
        let baseline = Phosphor.baselineOffset(for: s, font: font)
        return NSPoint(x: box.midX - (ink.minX + ink.width / 2),
                       y: box.midY - (ink.minY + ink.height / 2) - baseline)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: cornerRadius, yRadius: cornerRadius)
        // Unlit ("cleanup OFF") reads as clearly DARK — a near-black keycap with a faint outline and a
        // dim glyph — so lighting up on toggle is unmistakable. Lit is the full phosphor look.
        Phosphor.themed(NSColor(srgbRed: 0, green: 0.16, blue: 0.06, alpha: lit ? 0.9 : 0.22)).setFill()
        path.fill()
        tint.withAlphaComponent(lit ? 0.55 : 0.15).setStroke()
        path.lineWidth = 1.4
        path.stroke()

        let pt = effectiveFontSize
        let font = NSFont(name: Phosphor.font, size: pt) ?? .systemFont(ofSize: pt, weight: .bold)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tint.withAlphaComponent(lit ? 1.0 : 0.22),
            .paragraphStyle: para,
        ]
        if lit {
            let shadow = NSShadow()
            shadow.shadowColor = tint.withAlphaComponent(0.7)
            shadow.shadowBlurRadius = glowRadius
            attrs[.shadow] = shadow
        }
        let s = NSAttributedString(string: glyph, attributes: attrs)
        s.draw(at: KeycapView.glyphOrigin(for: s, font: font, in: bounds))
    }
}
