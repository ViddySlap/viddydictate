import Cocoa

/// Live audio oscilloscope. Draws the actual recent mic samples as a full-width waveform with
/// phosphor persistence — each frame fades the previous trace toward transparent (like an old
/// scope), so a trail follows the signal as it scrolls. Brightness and thickness grow with level;
/// when silent it rests as a still centre line. Reads samples from `samplesProvider` and honours the
/// meter settings: Gain/Sensitivity scale the height, Reactivity sets the trail length.
final class WaveformView: NSView {
    var samplesProvider: (() -> [Float])?

    private let canvas = PhosphorCanvas()
    private var bright: NSColor { Phosphor.green }   // live theme accent (default #00ff41)

    /// Fraction of the width over which the trace alpha-fades to nothing at EACH end. The low-power
    /// pill uses this soft horizontal fade instead of a hard bounding-box edge, so the scope melts
    /// into the capsule's rounded ends. ~15% each side keeps the fade wider than the pill's cap
    /// radius, so nothing pokes out of the rounded corner.
    static let edgeFadePortion: CGFloat = 0.15

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Start rendering. `fps` lets the low-power pill run the scope at half rate.
    func start(fps: Double = 60) {
        canvas.start(fps: fps) { [weak self] in self?.renderFrame() }
    }

    func stop() { canvas.stop() }

    /// Test seam (`--hud-probe`, BUG 1 revert pin): whether the scope's render timer is live. The pill
    /// scope runs it (`start`); a toast dwell / hide stops it. Lets the probe assert the oscilloscope is
    /// animating again after a mid-take toast reverts to the recording scope.
    var isRunningForTesting: Bool { canvas.isRunning }

    private func ensureBuffer() -> CGContext? {
        canvas.context(bounds: bounds, scale: window?.backingScaleFactor ?? 2)
    }

    private func renderFrame() {
        guard let bctx = ensureBuffer() else { return }
        let W = bounds.width, H = bounds.height, cy = H / 2
        guard W > 1, H > 4 else { return }

        // phosphor decay: pull existing alpha down a notch each frame (Reactivity = trail length).
        let fade = CGFloat(0.10 + min(max(Settings.reactivity, 0), 1) * 0.30)
        PhosphorBuffer.decayFill(bctx, alpha: fade,
                                 in: CGRect(x: 0, y: 0, width: W, height: H))

        let samp = samplesProvider?() ?? []
        if samp.count > 1 {
            let n = samp.count
            var sum: Float = 0
            for v in samp { sum += v * v }
            let energy = CGFloat(min(1, sqrtf(sum / Float(n)) * 6))     // brightness/thickness
            let vGain = (H * 0.40) / 0.25
                * CGFloat(min(max(Settings.linearGain, 0.3), 6))
                * CGFloat(0.5 + min(max(Settings.sensitivity, 0), 1))

            let path = CGMutablePath()
            var first = true
            var x: CGFloat = 0
            while x <= W {
                let si = Int(Double(x / W) * Double(n - 1))
                var y = cy - CGFloat(samp[si]) * vGain
                if y < 1 { y = 1 } else if y > H - 1 { y = H - 1 }
                if first { path.move(to: CGPoint(x: x, y: y)); first = false }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 1
            }
            bctx.setShadow(offset: .zero, blur: 5 + energy * 10, color: bright.cgColor)
            bctx.setStrokeColor(bright.withAlphaComponent(0.95).cgColor)
            bctx.setLineWidth(1.2 + energy * 3)
            bctx.setLineJoin(.round)
            bctx.addPath(path)
            bctx.strokePath()
            bctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        canvas.capture(bctx)
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard canvas.blit(in: bounds), let ctx = NSGraphicsContext.current?.cgContext else { return }
        paintEdgeFade(ctx, bounds)
    }

    /// Soft-fade the trace's alpha to nothing over `edgeFadePortion` of the width at each end. Drawn
    /// with `.destinationOut` so it erases only the trace this view painted (the CRT fill/scanlines
    /// live in a sibling `DisplayView` behind it), turning the old hard left/right edges into a
    /// gradient that reaches the capsule's rounded ends.
    private func paintEdgeFade(_ ctx: CGContext, _ b: CGRect) {
        let w = b.width
        guard w > 2 else { return }
        let fade = max(1, w * WaveformView.edgeFadePortion)
        let cols = [NSColor(white: 0, alpha: 1).cgColor,
                    NSColor(white: 0, alpha: 0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols,
                                 locations: [0, 1]) else { return }
        let midY = b.midY
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        // Fully erase at each edge (alpha 1) tapering to no erase (alpha 0) `fade` points inward.
        ctx.drawLinearGradient(g, start: CGPoint(x: b.minX, y: midY),
                               end: CGPoint(x: b.minX + fade, y: midY), options: [])
        ctx.drawLinearGradient(g, start: CGPoint(x: b.maxX, y: midY),
                               end: CGPoint(x: b.maxX - fade, y: midY), options: [])
        ctx.restoreGState()
    }

    /// Offscreen render seam for `--hud-render` (and any Item-A visual check): force one render pass
    /// with a fixed synthetic sample set and return the RAW phosphor image (pre-fade, so a test can
    /// confirm the trace spans the full width) plus a COMPOSITE image with the edge fade applied
    /// (so a test can confirm the soft ends). In-process — no window, no screen capture.
    func renderForSeam(samples: [Float]) -> (raw: CGImage, faded: CGImage)? {
        let prev = samplesProvider
        samplesProvider = { samples }
        defer { samplesProvider = prev }
        // Two passes so the phosphor buffer carries a solid, decayed-in trace.
        renderFrame(); renderFrame()
        guard let raw = canvas.image else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let pxW = Int(bounds.width * scale), pxH = Int(bounds.height * scale)
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)   // draw in point coordinates, matching the live buffer
        ctx.draw(raw, in: bounds)
        paintEdgeFade(ctx, bounds)
        guard let faded = ctx.makeImage() else { return nil }
        return (raw, faded)
    }
}
