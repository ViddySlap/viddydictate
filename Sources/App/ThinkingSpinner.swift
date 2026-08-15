import Cocoa

/// The post-release "thinking" indicator: the live oscilloscope BENT INTO A RING. A clean green
/// circle, around whose edge a single localized burst of audio-style distortion travels — mostly
/// bulging OUTWARD (with the odd inward dip), jittering like the live mic scope, and dragging a
/// phosphor comet-wake behind it as it laps the ring. Intro-then-continuous: it enters as a clean
/// circle, the burst emerges once, then circles continuously until the cleaned text lands.
///
/// There is NO live audio during the cleanup wait (recording is already done), so the jitter is
/// SYNTHETIC — a sum of incommensurate harmonics tuned to read as organic scope noise rather than a
/// clean sine. Same phosphor language as `WaveformView` (an offscreen buffer faded a notch each
/// frame for the CRT persistence trail), the same #00ff41 green, and the same glow.
///
/// (Replaces the old whole-ring `sin(6a)+sin(11a)` harmonic trace, which rippled the ENTIRE ring at
/// once — a four/six-petal blob — rather than one distortion travelling around a clean circle.)
final class ThinkingSpinner: NSView {
    private var t: CGFloat = 0          // time accumulator (churns the jitter)
    private var head: CGFloat = 0       // angle of the travelling distortion window's centre
    private var age = 0                 // frames since start() — drives the intro ramp-in
    private let canvas = PhosphorCanvas()
    private var bright: NSColor { Phosphor.green }   // live theme accent (default #00ff41)

    // --- tunables (the live-tuning surface; tweak these on the user's feedback) ---
    private let headSpeed: CGFloat    = 0.075   // rad/frame the window travels (~1.4s per lap @60fps)
    private let timeSpeed: CGFloat    = 0.16    // how fast the jitter churns
    private let winSigma: CGFloat     = 0.55    // angular half-width of the distortion window (rad)
    private let ampFrac: CGFloat      = 0.30    // distortion amplitude as a fraction of baseR
    private let outwardBias: CGFloat  = 0.42    // shifts the jitter mostly-outward (some inward)
    private let introFrames: CGFloat  = 22      // frames to ramp the burst in from a clean circle
    private let fadePerFrame: CGFloat = 0.30    // phosphor decay (comet-wake length)

    override var isFlipped: Bool { false }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("no coder") }

    func start() {
        age = 0; t = 0; head = -.pi / 2    // emerge once, then travel
        canvas.start(fps: 60) { [weak self] in self?.renderFrame() }
    }
    func stop() { canvas.stop() }

    private func ensureBuffer() -> CGContext? {
        canvas.context(bounds: bounds, scale: window?.backingScaleFactor ?? 2)
    }

    /// Synthetic oscilloscope jitter at angle `a`, churning over time `t`, roughly in [-1, 1]. The
    /// high angular frequencies (13/23/37) give the jagged scope texture; the incommensurate rates
    /// keep it from visibly repeating.
    private func jitter(_ a: CGFloat) -> CGFloat {
        let n = 0.55 * sin(13 * a - 2.1 * t)
              + 0.30 * sin(23 * a + 1.7 * t)
              + 0.22 * sin(37 * a - 3.3 * t)
              + 0.18 * sin( 7 * a + 0.9 * t)
        return n / 1.25
    }

    /// Smallest signed angular distance from `b` to `a`, in (-pi, pi].
    private func angDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
        return d
    }

    private func renderFrame() {
        guard let bctx = ensureBuffer() else { return }
        let W = bounds.width, H = bounds.height
        guard W > 4, H > 4 else { return }

        // phosphor decay: pull existing alpha down a notch each frame so the moving distortion leaves
        // a fading comet-wake behind it (same trick as the live waveform's persistence). The clean
        // ring is redrawn at the same radius every frame, so it stays steady and bright.
        PhosphorBuffer.decayFill(bctx, alpha: fadePerFrame,
                                 in: CGRect(x: 0, y: 0, width: W, height: H))

        let cx = W / 2, cy = H / 2
        let baseR = min(W, H) * 0.30
        let amp = baseR * ampFrac
        let intro = min(1, CGFloat(age) / introFrames)   // 0 -> clean circle; 1 -> full burst
        let sig2 = 2 * winSigma * winSigma
        let n = 260

        let path = CGMutablePath()
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            // a single Gaussian window of distortion around the travelling head; everywhere else the
            // ring is clean (env ~ 0).
            let d = angDelta(a, head)
            let env = CGFloat(exp(-Double(d * d) / Double(sig2)))
            let dist = amp * intro * env * (jitter(a) + outwardBias)
            let r = baseR + dist
            let x = cx + r * cos(a), y = cy + r * sin(a)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()

        bctx.setShadow(offset: .zero, blur: 9, color: bright.cgColor)
        bctx.setStrokeColor(bright.withAlphaComponent(0.95).cgColor)
        bctx.setLineWidth(2)
        bctx.setLineJoin(.round)
        bctx.addPath(path)
        bctx.strokePath()
        bctx.setShadow(offset: .zero, blur: 0, color: nil)

        canvas.capture(bctx)
        t += timeSpeed
        head -= headSpeed                       // decrement = travel CLOCKWISE (view is y-up)
        if head < -.pi { head += 2 * .pi }
        age += 1
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        canvas.blit(in: bounds)
    }
}
