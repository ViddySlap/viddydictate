import Cocoa
import QuartzCore

/// The low-power INFO PILL (Item B): a second, smaller phosphor capsule that floats just below the
/// scope pill and surfaces the passive transform/lock indicators that the full HUD would otherwise show
/// in its status row. It is CONTENT-GATED: it only exists while hands-free is locked, Cleanup is on, or
/// a one-shot mode is armed; when none is true it is not shown at all, leaving the scope pill alone.
///
/// Its own NSPanel (like the pop-up mode badge), so the scope pill's panel is never resized or moved
/// when the info pill appears/disappears — the scope's on-screen position is invariant by construction,
/// and the scope pill's `--hud-probe` `pill-size`/`pill-scale` assertions stay untouched.
///
/// Contents, laid out left→right, each conditional:
///   - a passive `lock.fill` glyph (only when locked),
///   - the reused transform `KeycapView` (when Cleanup or a one-shot mode is armed),
///   - the reused `StrengthSlider` in three-label mode (only when cleanup is on).
///
/// WIDTH is content-driven and ANIMATES: turning an element on widens the capsule first, THEN the new
/// element fades in; turning one off fades it out first, THEN the capsule shrinks. The panel itself is
/// a fixed transparent max-width band centered under the scope; only the inner capsule (`display`)
/// grows/shrinks and re-centers, so the animation never disturbs the scope above it.
final class InfoPillPanel: NSObject {
    private let panel: NSPanel
    private let container = NSView()
    private let display = DisplayView()
    /// Bullseye glyph (notes-bullseye BT2), shown while the sticky-note bullseye is armed. Leftmost element,
    /// content-gated exactly like the lock glyph.
    private let bullseyeGlyph = NSImageView()
    private let lockGlyph = NSImageView()
    private let keycap = KeycapView()
    private let slider = StrengthSlider()
    private var cleanupGlyph = "?"
    private var armedModeGlyph: String?

    /// Canonical left-to-right element order; every layout pass filters this by the active set so the
    /// elements never reorder. Bullseye leads, then lock, then the `?` keycap + strength slider.
    private static let order = ["bullseye", "lock", "keycap", "slider"]

    private var phosphor: NSColor { Phosphor.green }   // live theme accent

    /// Logical "is the info pill showing" — set synchronously in `apply`, so tests read a deterministic
    /// value even mid-animation.
    private(set) var isShown = false
    /// The capsule's final on-screen frame for the current state (synchronous target, animation aside).
    private(set) var capsuleTargetFrame = NSRect.zero

    /// Which elements the capsule currently holds ("lock" / "keycap" / "slider"), for animation diffing.
    private var curSet: Set<String> = []
    private var applyGen = 0
    private var ps: CGFloat = 1

    /// The info pill has a FIXED MINIMUM size, independent of the scope pill's size setting. The scope
    /// pill can shrink freely, but the info pill floors here so its content (the `?` keycap and the
    /// three-word labeled slider — whose labels are drawn at a fixed font size) always stays legible.
    /// 0.9 is the smallest scale at which the fixed-height slider still clears the capsule and the
    /// keycap reads cleanly; below it, `apply` clamps up to this floor. See `apply`.
    static let minScale: CGFloat = 0.9

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true          // passive indicator — chords drive everything
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container.wantsLayer = true

        // Passive bullseye glyph — a green targeting glyph with the same soft phosphor glow as the lock.
        // Non-interactive; shown only while the sticky-note bullseye is armed (notes-bullseye BT2).
        bullseyeGlyph.imageScaling = .scaleProportionallyUpOrDown
        bullseyeGlyph.contentTintColor = phosphor
        bullseyeGlyph.wantsLayer = true
        bullseyeGlyph.layer?.shadowColor = phosphor.cgColor
        bullseyeGlyph.layer?.shadowRadius = 4
        bullseyeGlyph.layer?.shadowOpacity = 0.6
        bullseyeGlyph.layer?.shadowOffset = .zero
        bullseyeGlyph.layer?.masksToBounds = false

        // Passive lock glyph — a green `lock.fill` with a soft phosphor glow. Non-interactive.
        lockGlyph.imageScaling = .scaleProportionallyUpOrDown
        lockGlyph.contentTintColor = phosphor
        lockGlyph.wantsLayer = true
        lockGlyph.layer?.shadowColor = phosphor.cgColor
        lockGlyph.layer?.shadowRadius = 4
        lockGlyph.layer?.shadowOpacity = 0.6
        lockGlyph.layer?.shadowOffset = .zero
        lockGlyph.layer?.masksToBounds = false

        // Reused cleanup keycap (matches the pop-up badge + the full-HUD indicator) and the
        // three-label slider. The controller replaces the default with the live HotkeyMap snapshot.
        keycap.cornerRadius = 3; keycap.glowRadius = 5
        keycap.tint = phosphor
        keycap.lit = true
        slider.threeLabels = true
        slider.enabled = true

        display.borderColor = phosphor.withAlphaComponent(0.5)
        display.addSubview(bullseyeGlyph)
        display.addSubview(lockGlyph)
        display.addSubview(keycap)
        display.addSubview(slider)
        container.addSubview(display)
        panel.contentView = container
        setHotkeyMap(.defaults())
    }

    /// Refresh the cleanup keycap from the same live map used by the event tap. Called at startup and
    /// after every Settings rebind, so this long-lived panel never keeps its launch-time glyph.
    func setHotkeyMap(_ map: HotkeyMap) {
        cleanupGlyph = map.key(for: .cleanupToggle).keycapGlyph
        if armedModeGlyph == nil { keycap.glyph = cleanupGlyph }
        keycap.needsDisplay = true
    }

    // MARK: metrics

    /// Capsule height. Grown from 30 to 34 so the keycap can carry a box big enough to hold its glyph
    /// at `KeycapView.glyphToBoxRatio` — the capsule, the keycap box and the glyph are ONE sizing
    /// decision, not three independent ones.
    private func infoH(_ ps: CGFloat) -> CGFloat { round(34 * ps) }
    private func padX(_ ps: CGFloat) -> CGFloat { round(12 * ps) }
    private func gapEl(_ ps: CGFloat) -> CGFloat { round(9 * ps) }
    private func gapBelow(_ ps: CGFloat) -> CGFloat { round(7 * ps) }
    private func bullseyeSize(_ ps: CGFloat) -> NSSize { NSSize(width: round(15 * ps), height: round(15 * ps)) }
    private func lockSize(_ ps: CGFloat) -> NSSize { NSSize(width: round(13 * ps), height: round(15 * ps)) }
    /// Square keycap box. The glyph size is NOT set here: `KeycapView` derives it from this box through
    /// the shared ratio, so growing or shrinking the box can never leave the glyph behind.
    private func keycapSize(_ ps: CGFloat) -> NSSize { NSSize(width: round(20 * ps), height: round(20 * ps)) }
    /// The slider draws at fixed font sizes (its three labels), so its size is intrinsic, not scaled.
    private var sliderSize: NSSize { NSSize(width: ceil(slider.intrinsicWidthValue), height: 22) }

    private func elementSet(bullseye: Bool, locked: Bool, cleanup: Bool, oneShotArmed: Bool) -> Set<String> {
        var s = Set<String>()
        if bullseye { s.insert("bullseye") }
        if locked { s.insert("lock") }
        if cleanup || oneShotArmed { s.insert("keycap") }
        if cleanup { s.insert("slider") }
        return s
    }

    private func view(_ e: String) -> NSView {
        switch e {
        case "bullseye": return bullseyeGlyph
        case "lock":     return lockGlyph
        case "keycap":   return keycap
        default:         return slider
        }
    }
    private func elementWidth(_ e: String, _ ps: CGFloat) -> CGFloat {
        switch e {
        case "bullseye": return bullseyeSize(ps).width
        case "lock":     return lockSize(ps).width
        case "keycap":   return keycapSize(ps).width
        default:         return sliderSize.width
        }
    }

    /// Full-set (lock + keycap + slider) capsule width — the panel is sized to this max so it never
    /// moves; the inner capsule is what grows/shrinks within it.
    private func maxCapsuleWidth(_ ps: CGFloat) -> CGFloat {
        let content = Self.order.reduce(0) { $0 + elementWidth($1, ps) }
        return padX(ps) * 2 + content + gapEl(ps) * CGFloat(Self.order.count - 1)
    }

    private func capsuleWidth(_ set: Set<String>, _ ps: CGFloat) -> CGFloat {
        let present = Self.order.filter { set.contains($0) }
        guard !present.isEmpty else { return 0 }
        let content = present.reduce(0) { $0 + elementWidth($1, ps) }
        return padX(ps) * 2 + content + gapEl(ps) * CGFloat(present.count - 1)
    }

    /// The capsule (`display`) frame WITHIN the panel for a given set, centered in the max-width band.
    private func capsuleLocalFrame(_ set: Set<String>, _ ps: CGFloat) -> NSRect {
        let wMax = maxCapsuleWidth(ps), wc = capsuleWidth(set, ps), h = infoH(ps)
        return NSRect(x: (wMax - wc) / 2, y: 0, width: wc, height: h)
    }

    /// An element's frame WITHIN `display`'s bounds for a given set (nil if absent from the set).
    private func localFrame(_ e: String, _ set: Set<String>, _ ps: CGFloat) -> NSRect? {
        guard set.contains(e) else { return nil }
        let h = infoH(ps)
        var x = padX(ps)
        for name in Self.order where set.contains(name) {
            let w = elementWidth(name, ps)
            if name == e {
                let sz: NSSize
                switch e {
                case "bullseye": sz = bullseyeSize(ps)
                case "lock":     sz = lockSize(ps)
                case "keycap":   sz = keycapSize(ps)
                default:         sz = sliderSize
                }
                return NSRect(x: x, y: (h - sz.height) / 2, width: sz.width, height: sz.height)
            }
            x += w + gapEl(ps)
        }
        return nil
    }

    private func panelFrame(_ ps: CGFloat, under scope: NSRect) -> NSRect {
        let wMax = maxCapsuleWidth(ps), h = infoH(ps)
        let x = scope.midX - wMax / 2
        let y = scope.minY - gapBelow(ps) - h
        return NSRect(x: x, y: y, width: wMax, height: h)
    }

    // MARK: apply

    /// Recompute + re-render the info pill for the live state, positioned under `scope`. `animated`
    /// choreographs the widen-then-fade / fade-then-shrink transition; `false` snaps to the final
    /// layout synchronously (used by the offscreen render seam and any headless probe).
    func apply(locked: Bool, cleanupEnabled: Bool, level: Int, bullseyeArmed: Bool = false,
               armedModeGlyph: String? = nil, scope: NSRect, ps rawPs: CGFloat, animated: Bool) {
        // Floor the pill's own scale so it never shrinks below its legible minimum, no matter how small
        // the scope pill's size setting is. Above the floor it tracks the setting (so 150% grows it too).
        let ps = max(rawPs, InfoPillPanel.minScale)
        self.ps = ps
        self.armedModeGlyph = armedModeGlyph
        keycap.glyph = armedModeGlyph ?? cleanupGlyph
        keycap.needsDisplay = true
        keycap.lit = true
        // No explicit glyph size: KeycapView derives it from the box it is given, so the glyph tracks
        // both the box AND `ps` by construction. It used to be pinned at 19pt in a 15x16 box, which is
        // why the `?` bled past its own border.
        slider.level = CleanupLevel.clamped(level).rawValue
        slider.enabled = true
        // The three-dot divider centers against the TOP OF THE CAPSULE BORDER, which sits above this
        // fixed-height control (the pill scales with `ps`; the slider's labels are drawn at a fixed
        // size and do not). Hand it that distance rather than letting it guess.
        slider.capsuleTopGap = max(0, (infoH(ps) - sliderSize.height) / 2)
        let cfg = NSImage.SymbolConfiguration(pointSize: round(11 * ps), weight: .regular)
        lockGlyph.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "hands-free locked")?
            .withSymbolConfiguration(cfg)
        let bullseyeCfg = NSImage.SymbolConfiguration(pointSize: round(13 * ps), weight: .regular)
        bullseyeGlyph.image = NSImage(systemSymbolName: "smallcircle.filled.circle",
                                      accessibilityDescription: "sticky-note bullseye armed")?
            .withSymbolConfiguration(bullseyeCfg)

        let newSet = elementSet(
            bullseye: bullseyeArmed,
            locked: locked,
            cleanup: cleanupEnabled,
            oneShotArmed: armedModeGlyph != nil)
        let pf = panelFrame(ps, under: scope)
        let capLocal = capsuleLocalFrame(newSet, ps)

        applyGen += 1; let gen = applyGen

        // Position the transparent max-width band synchronously (scope stays put regardless).
        panel.setFrame(pf, display: true)
        container.frame = NSRect(origin: .zero, size: pf.size)
        display.cornerRadius = infoH(ps) / 2
        display.borderWidth = max(1, round(1 * ps))

        // Synchronous logical/target state for tests.
        isShown = !newSet.isEmpty
        capsuleTargetFrame = NSRect(x: pf.minX + capLocal.minX, y: pf.minY + capLocal.minY,
                                    width: capLocal.width, height: capLocal.height)

        // Empty state — hide.
        if newSet.isEmpty {
            curSet = []
            if !animated || !panel.isVisible {
                panel.orderOut(nil); display.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.16
                display.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, gen == self.applyGen else { return }
                self.panel.orderOut(nil); self.display.alphaValue = 1
            })
            return
        }

        // Non-empty. Snap path (render / probe): set everything to final immediately.
        if !animated {
            display.frame = capLocal
            display.alphaValue = 1
            for e in Self.order {
                let v = view(e)
                if let f = localFrame(e, newSet, ps) { v.frame = f; v.isHidden = false; v.alphaValue = 1 }
                else { v.isHidden = true }
            }
            panel.orderFrontRegardless()
            curSet = newSet
            return
        }

        // Animated path.
        let appearing = curSet.isEmpty
        var added = newSet.subtracting(curSet)
        // Rescue elements stranded invisible by a cancelled fade-in: a newer apply() bumps applyGen
        // between the widen phase and the fade phase (e.g. show()'s post-clamp re-anchor lands right
        // after layoutPill's apply), the guarded completion never fires, and the view sits at model
        // alpha 0 inside a visible capsule. Any element that should be showing but is effectively
        // invisible re-enters `added`, so this pass's phase 3 fades it in. Mid-fade elements are NOT
        // rescued (animator() sets the model alpha to 1 up front), so steady states re-animate nothing.
        for e in newSet where !added.contains(e) {
            let v = view(e)
            if v.isHidden || v.alphaValue < 0.99 { added.insert(e) }
        }
        let removed = curSet.subtracting(newSet)

        // Symmetric to the rescue loop above (should-show-but-invisible): enforce should-hide-but-visible.
        // Every element NOT in the new set and NOT being choreographed out (`removed`) is a STRAY — content
        // left over from a prior dirty/cancelled transition, or absent from both curSet and newSet (the
        // class the old animated path never touched, so keycap/slider leaked under the bullseye/lock
        // capsule). Hard-hide it synchronously, mirroring the snap path's completeness. The `removed`
        // fade-out below then stays purely cosmetic, and a fade stranded by a rapid re-apply can never
        // survive: once curSet advances, that element becomes a stray here on the very next apply.
        for e in Self.order where !newSet.contains(e) && !removed.contains(e) {
            let v = view(e)
            v.isHidden = true
            v.alphaValue = 1
        }

        // Place newSet elements: added ones at their final frame, invisible; survivors keep their
        // current frame (they reflow in phase 2). Removed ones stay visible for the fade-out.
        for e in newSet {
            guard let f = localFrame(e, newSet, ps) else { continue }
            let v = view(e)
            v.isHidden = false
            if added.contains(e) { v.frame = f; v.alphaValue = 0 }
        }

        if appearing {
            // Seed a narrow empty capsule, then grow it — "the pill expands, then the element appears."
            let seedW = padX(ps) * 2
            display.frame = NSRect(x: (pf.width - seedW) / 2, y: 0, width: seedW, height: infoH(ps))
            display.alphaValue = 1
        }
        panel.orderFrontRegardless()

        // Phase 2: grow/shrink the capsule to final + reflow survivors; then phase 3 fades in added.
        let survivors = newSet.subtracting(added)
        let phase2: () -> Void = { [weak self] in
            guard let self = self, gen == self.applyGen else { return }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.17
                c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.display.animator().frame = capLocal
                for e in survivors {
                    if let f = self.localFrame(e, newSet, ps) { self.view(e).animator().frame = f }
                }
            }, completionHandler: {
                guard gen == self.applyGen, !added.isEmpty else { return }
                NSAnimationContext.runAnimationGroup({ c in
                    c.duration = 0.14
                    for e in added { self.view(e).animator().alphaValue = 1 }
                })
            })
        }

        // Phase 1: fade out removed elements first (then phase 2 shrinks the capsule around the rest).
        if removed.isEmpty {
            phase2()
        } else {
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.12
                for e in removed { view(e).animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self = self, gen == self.applyGen else { return }
                for e in removed { let v = self.view(e); v.isHidden = true; v.alphaValue = 1 }
                phase2()
            })
        }

        curSet = newSet
    }

    /// Tear the info pill down (leaving pill mode, toast, or HUD hide). Immediate, no animation.
    func hide() {
        applyGen += 1
        isShown = false
        curSet = []
        // Reset per-element visual state so a toast→pill return (or any re-show) starts from a clean
        // slate. Without this, a tear-down mid-animation leaves stale isHidden/alpha on the glyphs, and
        // the next apply — which only touches added ∪ removed — inherits the leftovers, re-stranding
        // content under the returning capsule. curSet is now empty, so every element is a fresh add.
        for e in Self.order {
            let v = view(e)
            v.isHidden = true
            v.alphaValue = 1
        }
        panel.orderOut(nil)
        display.alphaValue = 1
    }

    // MARK: render seam (Item B visual check)

    /// Snap to a state synchronously and return a bitmap of the capsule composite (CRT capsule +
    /// whichever indicators the state gates in), for the offscreen `--hud-render` PNG check. Returns
    /// nil for the empty state (the pill is not shown at all). In-process — no screen capture.
    func renderCapsule(locked: Bool, cleanupEnabled: Bool, level: Int, bullseyeArmed: Bool = false,
                       armedModeGlyph: String? = nil, ps: CGFloat) -> CGImage? {
        // A fixed scope frame so the panel has somewhere to live; only the capsule bitmap is returned.
        let scope = NSRect(x: 200, y: 400, width: round(HUDPillMetrics.baseWidth * ps),
                           height: round(HUDPillMetrics.baseHeight * ps))
        apply(locked: locked, cleanupEnabled: cleanupEnabled, level: level,
              bullseyeArmed: bullseyeArmed, armedModeGlyph: armedModeGlyph,
              scope: scope, ps: ps, animated: false)
        guard isShown else { return nil }
        display.layoutSubtreeIfNeeded()
        let b = display.bounds
        guard b.width > 0, b.height > 0, let rep = display.bitmapImageRepForCachingDisplay(in: b) else { return nil }
        display.cacheDisplay(in: b, to: rep)
        return rep.cgImage
    }

    /// The capsule width the current render-seam state produced (points), so the seam can assert that
    /// more active elements ⇒ a wider pill.
    var lastCapsuleWidth: CGFloat { capsuleTargetFrame.width }

    /// GUI-render seam: the glyph the nested keycap will actually draw.
    var cleanupGlyphForTesting: String { keycap.glyph }

    /// GUI-render seam (V1): the keycap's live box, the point size it will actually draw at, and its
    /// frame inside the capsule bitmap `renderCapsule` returns. The ratio gate reads THESE — the live
    /// values the pill really lays out with — so pinning the helper alone cannot make it pass.
    var keycapGeometryForTesting: (box: NSSize, fontSize: CGFloat, frame: NSRect) {
        (keycap.frame.size, keycap.effectiveFontSize, keycap.frame)
    }

    /// GUI-render seam (V1): the slider's frame inside the capsule bitmap, plus the divider geometry it
    /// derived, so "the divider is centered between the top of the words and the top of the pill border"
    /// is gated on the numbers that actually shipped.
    var sliderGeometryForTesting: (frame: NSRect, trackCenterY: CGFloat, labelInkTop: CGFloat, capsuleTopGap: CGFloat) {
        (slider.frame, slider.trackCenterYForTesting, slider.labelInkTopForTesting, slider.capsuleTopGap)
    }

    /// GUI-render seam (V1): the three stop labels the slider both MEASURES and DRAWS, and the frames
    /// it will paint them into. One source for both, so an uppercase-at-draw-time-only regression (the
    /// trap that makes the labels overlap) shows up as overlapping frames.
    var sliderLabelsForTesting: (labels: [String], frames: [NSRect]) {
        (StrengthSlider.threeStopLabels, slider.labelFrames)
    }

    /// GUI-render seam for S2: the exact content set distinguishes an armed-mode keycap from Cleanup,
    /// which also carries the strength slider.
    var activeElementsForTesting: [String] { curSet.sorted() }

    /// Test seam: elements of the CURRENT set that are effectively invisible (hidden or fully
    /// transparent model alpha) even though the state says they should be showing. Reads MODEL values,
    /// so once a fade-in has been scheduled (animator sets the model immediately) the element counts
    /// as visible; only a genuinely stranded element (a cancelled fade-in) shows up here.
    var invisibleContentForTesting: [String] {
        curSet.filter { let v = view($0); return v.isHidden || v.alphaValue < 0.99 }.sorted()
    }

    /// Test seam symmetric to `invisibleContentForTesting`: elements NOT in the current set that are
    /// still on-screen visible (not hidden AND some alpha) — i.e. stray content leaking under the
    /// capsule from a prior dirty or cancelled transition. Reads MODEL values (a fade-out sets the
    /// model alpha to 0 up front, so a `removed` element mid-fade does not count). MUST be empty after
    /// every transition; the animated path is the one that strands content, so the probe asserts this
    /// on that path. This is the negative the old build never checked — which is why the bug shipped.
    var strayVisibleContentForTesting: [String] {
        Set(Self.order).subtracting(curSet)
            .filter { let v = view($0); return !v.isHidden && v.alphaValue > 0.01 }
            .sorted()
    }
}
