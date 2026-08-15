import Cocoa

/// Compact 3-stop cleanup-strength slider for the HUD. Level 0 = Cleanup, 1 = Tighten, 2 = Summarize.
///
/// Two layouts, chosen by `threeLabels`:
///   - `false` (default, full-HUD status row): a single tight row — a short phosphor track with three
///     ticks flanked by "cleanup" (left) and "summarize" (right). The cramped status row has no space
///     for a third word between them, so the middle "tighten" stop is unlabeled here.
///   - `true` (low-power info pill): the pill gives the slider its own capsule with vertical room, so
///     the track sits on top and ALL THREE stops are labeled below — CLEANUP / TIGHTEN / SUMMARIZE —
///     each word centered under its dot, so every level is identifiable at a glance.
///
/// Mouse: click or drag the track to set the nearest level (the full-HUD affordance). Keyboard
/// (right-Option + `=`/`-`) is the primary control. The info-pill instance is passive (its panel
/// ignores mouse events), so there it is display-only. Dim when cleanup is OFF.
final class StrengthSlider: NSView {
    var level: Int = 0 { didSet { needsDisplay = true } }
    var enabled: Bool = true { didSet { needsDisplay = true } }
    var onSetLevel: ((Int) -> Void)?
    /// Label all three stops in a two-row layout (info pill). Default false = the compact end-labeled
    /// single row used by the full HUD, which stays pixel-for-pixel unchanged.
    var threeLabels: Bool = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    /// How far above this view's top edge the enclosing capsule's border sits (info pill only; 0 in the
    /// full HUD row). The divider centers in the band between the top of the label glyphs and that
    /// border, so the slider has to be told where the border is — it is not this control's own bounds.
    var capsuleTopGap: CGFloat = 0 { didSet { needsDisplay = true } }

    /// The three stop labels, ALL CAPS. This ONE array is what gets measured and what gets drawn: the
    /// trap here is uppercasing at draw time only, which leaves `trackW3` sized for the lowercase
    /// strings and makes the painted labels overlap.
    static let threeStopLabels = ["CLEANUP", "TIGHTEN", "SUMMARIZE"]

    private var phosphor: NSColor { Phosphor.green }   // live theme accent
    private let labelSize: CGFloat = 8.5
    private let trackW: CGFloat = 46
    private let gap: CGFloat = 6
    private let gapLbl: CGFloat = 4

    override var isFlipped: Bool { false }

    private func labelFont() -> NSFont {
        NSFont(name: Phosphor.font, size: labelSize) ?? .systemFont(ofSize: labelSize, weight: .regular)
    }
    private func labelWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: labelFont()]).width
    }

    /// Track width in the three-label layout: wide enough that adjacent labels (centered on their
    /// stops) never overlap. Tick spacing = trackW/2, so require it to clear each adjacent label pair.
    private var trackW3: CGFloat {
        let w = Self.threeStopLabels.map { labelWidth($0) / 2 }
        return 2 * (max(w[0] + w[1], w[1] + w[2]) + gapLbl)
    }

    /// Width this control wants. Two-end layout: "cleanup" + track + "summarize". Three-label layout:
    /// the extreme labels overhang the track ends by half their width.
    var intrinsicWidthValue: CGFloat {
        if threeLabels {
            return labelWidth(Self.threeStopLabels[0]) / 2 + trackW3 + labelWidth(Self.threeStopLabels[2]) / 2
        }
        return labelWidth("cleanup") + gap + trackW + gap + labelWidth("summarize")
    }
    override var intrinsicContentSize: NSSize { NSSize(width: intrinsicWidthValue, height: threeLabels ? 22 : 15) }

    /// Top of the label glyphs when they are drawn at y = 0 — the cap height above a baseline that
    /// itself sits `baselineOffset` above the drawing origin. The visual top of the words, not the top
    /// of their line box.
    private var labelInkTop: CGFloat {
        let f = labelFont()
        let s = NSAttributedString(string: Self.threeStopLabels[0], attributes: [.font: f])
        return Phosphor.baselineOffset(for: s, font: f) + Phosphor.inkBox(for: s).maxY
    }

    /// Radius of the glowing level handle — the tallest thing drawn on the track, and therefore what
    /// bounds how high the track may sit inside this control.
    private static let handleRadius: CGFloat = 2.6

    /// The track's vertical center: middle of the view for the one-row layout. For the three-label
    /// layout it is centered in the band between the TOP OF THE WORDS and the TOP OF THE PILL BORDER
    /// (`capsuleTopGap` above this view), which is where the design places it — it used to sit at a flat
    /// `bounds.height - 4`, closer to the border than to the words. Clamped so a large pill scale, which
    /// grows the capsule but not this fixed-size control, can never push the handle outside its bounds.
    private var trackCenterY: CGFloat {
        guard threeLabels else { return bounds.midY }
        let band = (labelInkTop + bounds.height + capsuleTopGap) / 2
        return min(band, bounds.height - Self.handleRadius)
    }

    /// The track rect in local coords, horizontally placed so labels fit.
    private func trackRect() -> NSRect {
        if threeLabels {
            return NSRect(x: labelWidth(Self.threeStopLabels[0]) / 2, y: 0, width: trackW3, height: bounds.height)
        }
        let lx = labelWidth("cleanup") + gap
        return NSRect(x: lx, y: 0, width: trackW, height: bounds.height)
    }
    private func stopX(_ i: Int) -> CGFloat {
        let t = trackRect()
        return t.minX + t.width * CGFloat(i) / 2.0
    }

    /// Where the three labels are painted, each centered under its stop. `draw` uses this and so does
    /// the gate, so a "uppercase when drawing, lowercase when measuring" split shows up as overlapping
    /// frames instead of as overlapping pixels nobody asserted on.
    var labelFrames: [NSRect] {
        guard threeLabels else { return [] }
        let f = labelFont()
        return Self.threeStopLabels.enumerated().map { i, name in
            let sz = (name as NSString).size(withAttributes: [.font: f])
            return NSRect(x: stopX(i) - sz.width / 2, y: 0, width: sz.width, height: sz.height)
        }
    }

    /// GUI-render seams (V1): the divider height this control settled on and the reference it centered
    /// against, so the gate reads the live derivation rather than re-deriving it.
    var trackCenterYForTesting: CGFloat { trackCenterY }
    var labelInkTopForTesting: CGFloat { labelInkTop }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = enabled ? 1.0 : 0.4
        let cy = trackCenterY
        let para = NSMutableParagraphStyle(); para.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont(),
            .foregroundColor: phosphor.withAlphaComponent(0.55 * alpha),
        ]
        let lh = (("cleanup" as NSString).size(withAttributes: attrs)).height

        if threeLabels {
            // Three labels centered under their stops, on the bottom row.
            for (i, f) in labelFrames.enumerated() {
                (Self.threeStopLabels[i] as NSString).draw(at: f.origin, withAttributes: attrs)
            }
        } else {
            // left label "cleanup"
            ("cleanup" as NSString).draw(at: NSPoint(x: 0, y: cy - lh / 2), withAttributes: attrs)
            // right label "summarize"
            let rw = labelWidth("summarize")
            ("summarize" as NSString).draw(at: NSPoint(x: bounds.width - rw, y: cy - lh / 2), withAttributes: attrs)
        }

        // track baseline
        let t = trackRect()
        phosphor.withAlphaComponent(0.30 * alpha).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: t.minX, y: cy)); line.line(to: NSPoint(x: t.maxX, y: cy))
        line.stroke()
        // three ticks
        for i in 0...2 {
            let x = stopX(i)
            phosphor.withAlphaComponent(0.45 * alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1, y: cy - 1, width: 2, height: 2)).fill()
        }
        // handle at current level (glowing dot)
        let hx = stopX(CleanupLevel.clamped(level).rawValue)
        let dot = NSBezierPath(ovalIn: NSRect(x: hx - 2.6, y: cy - 2.6, width: 5.2, height: 5.2))
        if enabled {
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 5, color: phosphor.cgColor)
        }
        phosphor.withAlphaComponent(alpha).setFill()
        dot.fill()
        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    }

    // MARK: mouse -> nearest stop

    private func setFromMouse(_ p: NSPoint) {
        guard enabled else { return }
        let t = trackRect()
        let frac = max(0, min(1, (p.x - t.minX) / t.width))
        let lvl = Int((frac * 2).rounded())
        if lvl != level { level = lvl; onSetLevel?(lvl) }
    }
    override func mouseDown(with event: NSEvent) { setFromMouse(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { setFromMouse(convert(event.locationInWindow, from: nil)) }
}
