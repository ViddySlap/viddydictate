import Cocoa

/// The offscreen render-to-PNG mechanics shared by every UI capture gate (`--setup-render`,
/// `--models-power-render`, `--provider-onboarding-render`), and the text-visibility helpers the Feature Tour's
/// gate introduced (contrast by colour resolution and by pixels), here so other renders can adopt them.
///
/// These are in-process renders, NOT screen captures: screen capture from an agent shell is TCC-blocked, so
/// this is how the link that builds a surface can actually look at what it built.
///
/// It lives here because the Setup and Models & Power gates had grown byte-identical copies of the same
/// capture, blank-detection, and view-lookup code, and a third copy is exactly the duplicate-concept the chain
/// post-mortem forbids. Reporting is injected, so each gate keeps its own check accounting and wording.
enum SelfTestRenderCapture {

    typealias Report = (_ name: String, _ ok: Bool, _ detail: String) -> Void

    /// Render `view` (or the descendant with identifier `card`) to a PNG at `path` and assert it carries real
    /// pixels. A blank capture is the failure mode that makes a render seam worthless, so it is a FAIL, not a
    /// note.
    /// Returns the bitmap it wrote, so a gate can go on to judge the pixels (`Pixels`); callers that only want
    /// the file ignore it.
    @discardableResult
    static func capture(_ view: NSView, card: String? = nil, to path: String, name: String,
                        report: Report) -> NSBitmapImageRep? {
        let target = card.flatMap { find($0, in: view) } ?? view
        guard let rep = render(target) else {
            report("\(name) render", false, "no bitmap rep")
            return nil
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            report("\(name) render", false, "PNG encode failed")
            return nil
        }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch {
            report("\(name) render", false, "write failed: \(error.localizedDescription)")
            return nil
        }
        let ink = inkFraction(rep)
        report("\(name) render is not blank", ink > 0.01,
               "\(rep.pixelsWide)x\(rep.pixelsHigh) px, ink=\(String(format: "%.3f", ink)) -> \(path)")
        return rep
    }

    /// The draw `capture` writes, without the file: for a mutant a gate must judge but not publish.
    static func render(_ target: NSView) -> NSBitmapImageRep? {
        target.layoutSubtreeIfNeeded()
        // A layer-backed subtree serves `cacheDisplay` out of cached layer contents. Capturing the same
        // view twice — the shape a gate takes when it drives a control and photographs each state — then
        // silently writes the FIRST state's pixels into the second file, and the blank-detector cannot
        // see it because both images are full of ink. Dirty the tree and force the draw.
        for subview in allViews(in: target) { subview.needsDisplay = true }
        target.displayIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        return rep
    }

    /// Fraction of pixels that differ from the image's most common (background) value. A surface that failed to
    /// draw is a flat fill and scores ~0.
    static func inkFraction(_ rep: NSBitmapImageRep) -> Double {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let base = rep.bitmapData else { return 0 }
        let rowBytes = rep.bytesPerRow
        let pixelBytes = max(1, rep.bitsPerPixel / 8)
        var histogram = [Int](repeating: 0, count: 256)
        var luma = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * rowBytes + x * pixelBytes
                let v = UInt8((Int(p[0]) + Int(p[min(1, pixelBytes - 1)]) + Int(p[min(2, pixelBytes - 1)])) / 3)
                luma[y * w + x] = v
                histogram[Int(v)] += 1
            }
        }
        let background = histogram.firstIndex(of: histogram.max() ?? 0) ?? 0
        var differing = 0
        for v in luma where abs(Int(v) - background) > 12 { differing += 1 }
        return Double(differing) / Double(w * h)
    }

    static func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews(in: $0) }
    }

    static func find(_ id: String, in root: NSView) -> NSView? {
        allViews(in: root).first { $0.identifier?.rawValue == id }
    }

    static func label(_ id: String, in root: NSView) -> NSTextField? {
        find(id, in: root) as? NSTextField
    }

    /// The nearest identifier at or above `view`, to name what a failing check is about.
    static func owner(of view: NSView) -> String {
        var current: NSView? = view
        while let candidate = current {
            if let id = candidate.identifier?.rawValue { return id }
            current = candidate.superview
        }
        return "unidentified"
    }

    // MARK: - is the text actually visible

    // The ink check above passes a page whose title is white on white so long as something else on it drew.
    // These judge each piece of text on its own, two ways. Colour resolution (`textContrast`) reads the colour a
    // label is drawn in and the colours stacked behind it, each resolved under the appearance AppKit draws it
    // in, and is exact for labels. Pixels (`Pixels.textContrast`) read the rendered capture inside the text's
    // own rect; they are the way to judge a bezelled button, whose bezel colour AppKit does not expose, and the
    // way to catch a capture that is not what the screen shows.

    /// An opaque sRGB colour, each channel 0...1.
    struct RGB: Equatable {
        var r: CGFloat, g: CGFloat, b: CGFloat

        static let white = RGB(r: 1, g: 1, b: 1)

        func distance(to other: RGB) -> CGFloat {
            ((r - other.r) * (r - other.r) + (g - other.g) * (g - other.g) + (b - other.b) * (b - other.b))
                .squareRoot()
        }

        func composited(_ top: RGB, alpha: CGFloat) -> RGB {
            let a = min(1, max(0, alpha))
            return RGB(r: top.r * a + r * (1 - a), g: top.g * a + g * (1 - a), b: top.b * a + b * (1 - a))
        }
    }

    /// WCAG 2 relative luminance.
    static func luminance(_ c: RGB) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// WCAG 2 contrast ratio, 1...21. 4.5 is the floor for body text, 3 for large text and for UI shapes.
    static func contrast(luminance a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> CGFloat { contrast(luminance: luminance(a), luminance(b)) }

    /// `color` as AppKit draws it under `appearance`: sRGB components and alpha. A dynamic system colour
    /// (`labelColor`, `windowBackgroundColor`) resolves to its light or dark value here.
    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> (rgb: RGB, alpha: CGFloat) {
        var out = (rgb: RGB(r: 0, g: 0, b: 0), alpha: CGFloat(1))
        appearance.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = (RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), c.alphaComponent)
        }
        return out
    }

    /// The colour behind `view`: the window backdrop (resolved under the window's appearance, or the view's when
    /// it has no window), then every fill painted between it and `view`, outermost first - layer backgrounds,
    /// filled text fields, scroll and clip views that draw, custom boxes - each over the one below at its alpha.
    static func backdrop(behind view: NSView) -> RGB {
        var chain: [NSView] = []
        var current: NSView? = view
        while let candidate = current {
            chain.append(candidate)
            current = candidate.superview
        }
        let windowFill = resolve(view.window?.backgroundColor ?? .windowBackgroundColor,
                                 in: view.window?.effectiveAppearance ?? view.effectiveAppearance)
        var colour = RGB.white.composited(windowFill.rgb, alpha: windowFill.alpha)
        func paint(_ fill: NSColor?, in candidate: NSView) {
            guard let fill else { return }
            let resolved = resolve(fill, in: candidate.effectiveAppearance)
            colour = colour.composited(resolved.rgb, alpha: resolved.alpha)
        }
        for candidate in chain.reversed() {
            if let layerFill = candidate.layer?.backgroundColor { paint(NSColor(cgColor: layerFill), in: candidate) }
            if let field = candidate as? NSTextField, field.drawsBackground { paint(field.backgroundColor, in: field) }
            if let scroll = candidate as? NSScrollView, scroll.drawsBackground { paint(scroll.backgroundColor, in: scroll) }
            if let clip = candidate as? NSClipView, clip.drawsBackground { paint(clip.backgroundColor, in: clip) }
            if let box = candidate as? NSBox, box.boxType == .custom, !box.isTransparent { paint(box.fillColor, in: box) }
        }
        return colour
    }

    /// The contrast of `field`'s text against what is behind it, by colour resolution: each colour the text is
    /// drawn in (every foreground-colour run of its attributed value, or `textColor` where a run sets none), under
    /// the field's effective appearance, laid over `backdrop(behind:)` at its own alpha (label colours are partly
    /// transparent), against that backdrop. The lowest run's ratio is the field's.
    static func textContrast(_ field: NSTextField) -> CGFloat {
        let behind = backdrop(behind: field)
        let value = field.attributedStringValue
        var colours: [NSColor] = []
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { colour, _, _ in
            colours.append((colour as? NSColor) ?? field.textColor ?? .labelColor)
        }
        if colours.isEmpty { colours = [field.textColor ?? .labelColor] }
        return colours.map { colour -> CGFloat in
            let text = resolve(colour, in: field.effectiveAppearance)
            return contrast(behind.composited(text.rgb, alpha: text.alpha), behind)
        }.min() ?? 1
    }

    /// Where a field's text is drawn, in the field's own coordinates: its drawing rect, narrowed to the text's
    /// width on the side its alignment puts it.
    static func textRect(of field: NSTextField) -> NSRect {
        let area = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
        let width = min(area.width, ceil(field.attributedStringValue.size().width) + 2)
        switch field.alignment {
        case .right: return NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        case .center: return NSRect(x: area.midX - width / 2, y: area.minY, width: width, height: area.height)
        default: return NSRect(x: area.minX, y: area.minY, width: width, height: area.height)
        }
    }

    /// Where a button's title is drawn, in the button's own coordinates: the title's size, centred in the cell's
    /// title rect. Kept inside the bezel, so the bezel is what the title is judged against.
    static func titleRect(of button: NSButton) -> NSRect {
        var area = button.cell?.titleRect(forBounds: button.bounds) ?? button.bounds
        if area.width < 4 || area.height < 4 { area = button.bounds }
        let size = button.attributedTitle.size()
        let width = min(area.width, ceil(size.width) + 2)
        let height = min(area.height, ceil(size.height) + 2)
        return NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// A rendered capture, read back as 8-bit sRGB with the top row first, and seen the way an image viewer
    /// shows it: anything the capture left transparent is laid over white. Coordinates go through `root`, the
    /// view the capture was taken of.
    struct Pixels {
        let root: NSView
        let width: Int
        let height: Int
        private let bytes: [UInt8]   // premultiplied RGBA

        init?(_ rep: NSBitmapImageRep, of root: NSView) {
            guard let image = rep.cgImage, image.width > 0, image.height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let data = context.data else { return nil }
            self.root = root
            width = image.width
            height = image.height
            bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        }

        func alpha(x: Int, y: Int) -> CGFloat { CGFloat(bytes[(y * width + x) * 4 + 3]) / 255 }

        /// The fraction of pixels whose largest channel difference from `other` exceeds `tolerance`; 1 when the
        /// two are not the same size. Two renders of a surface that ignores the system appearance score 0.
        func fractionDiffering(from other: Pixels, tolerance: Int = 8) -> Double {
            guard width == other.width, height == other.height, !bytes.isEmpty else { return 1 }
            var differing = 0
            var i = 0
            while i < bytes.count {
                var largest = 0
                for channel in 0..<4 { largest = max(largest, abs(Int(bytes[i + channel]) - Int(other.bytes[i + channel]))) }
                if largest > tolerance { differing += 1 }
                i += 4
            }
            return Double(differing) / Double(width * height)
        }

        /// The pixel over a white matte (premultiplied, so the matte shows through by 1 - alpha).
        func rgb(x: Int, y: Int) -> RGB {
            let i = (y * width + x) * 4
            let clear = 1 - CGFloat(bytes[i + 3]) / 255
            return RGB(r: CGFloat(bytes[i]) / 255 + clear, g: CGFloat(bytes[i + 1]) / 255 + clear,
                       b: CGFloat(bytes[i + 2]) / 255 + clear)
        }

        /// `rect` (in `view`'s coordinates) as pixel bounds, clamped to the image; nil when nothing is left.
        func bounds(of rect: NSRect, in view: NSView) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
            let r = root.convert(rect, from: view)
            guard root.bounds.width > 0, root.bounds.height > 0 else { return nil }
            let sx = CGFloat(width) / root.bounds.width
            let sy = CGFloat(height) / root.bounds.height
            let top = root.isFlipped ? r.minY : root.bounds.height - r.maxY
            let x0 = max(0, Int((r.minX * sx).rounded(.down)))
            let x1 = min(width, Int((r.maxX * sx).rounded(.up)))
            let y0 = max(0, Int((top * sy).rounded(.down)))
            let y1 = min(height, Int(((top + r.height) * sy).rounded(.up)))
            return x1 > x0 && y1 > y0 ? (x0, y0, x1, y1) : nil
        }

        /// The contrast of text drawn inside `rect` (in `view`'s coordinates). The background is the most common
        /// luminance in the rect; the ink is the pixel at the 99th percentile of distance from it, which is a glyph
        /// core rather than an antialiased edge or one stray pixel. Text that did not draw, or drew in the
        /// background's colour, scores about 1.
        func textContrast(in rect: NSRect, of view: NSView) -> CGFloat? {
            guard let b = bounds(of: rect, in: view) else { return nil }
            var levels: [CGFloat] = []
            levels.reserveCapacity((b.x1 - b.x0) * (b.y1 - b.y0))
            for y in b.y0..<b.y1 {
                for x in b.x0..<b.x1 { levels.append(SelfTestRenderCapture.luminance(rgb(x: x, y: y))) }
            }
            var bins = [Int](repeating: 0, count: 1001)
            for level in levels { bins[min(1000, max(0, Int((level * 1000).rounded())))] += 1 }
            guard let mode = bins.indices.max(by: { bins[$0] < bins[$1] }) else { return nil }
            let background = CGFloat(mode) / 1000
            let byDistance = levels.sorted { abs($0 - background) < abs($1 - background) }
            let ink = byDistance[min(byDistance.count - 1, Int(Double(byDistance.count - 1) * 0.99))]
            return SelfTestRenderCapture.contrast(luminance: ink, background)
        }
    }
}
