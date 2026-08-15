import Cocoa

/// The offscreen render-to-PNG mechanics shared by every UI capture gate (`--setup-render`,
/// `--models-power-render`, `--provider-onboarding-render`).
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
    static func capture(_ view: NSView, card: String? = nil, to path: String, name: String,
                        report: Report) {
        let target = card.flatMap { find($0, in: view) } ?? view
        target.layoutSubtreeIfNeeded()
        // A layer-backed subtree serves `cacheDisplay` out of cached layer contents. Capturing the same
        // view twice — the shape a gate takes when it drives a control and photographs each state — then
        // silently writes the FIRST state's pixels into the second file, and the blank-detector cannot
        // see it because both images are full of ink. Dirty the tree and force the draw.
        for subview in allViews(in: target) { subview.needsDisplay = true }
        target.displayIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
            report("\(name) render", false, "no bitmap rep")
            return
        }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            report("\(name) render", false, "PNG encode failed")
            return
        }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch {
            report("\(name) render", false, "write failed: \(error.localizedDescription)")
            return
        }
        let ink = inkFraction(rep)
        report("\(name) render is not blank", ink > 0.01,
               "\(rep.pixelsWide)x\(rep.pixelsHigh) px, ink=\(String(format: "%.3f", ink)) -> \(path)")
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
}
