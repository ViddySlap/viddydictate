import Cocoa

/// Offscreen render-to-PNG seam (`--hud-render <outdir>`): render the Final-only scope pill's
/// `WaveformView` OFFSCREEN to a bitmap, driven by a fixed synthetic sample set, and write PNGs plus
/// a pixel-metric report. This is an in-process render, NOT a screen capture (screen capture from an
/// agent shell is TCC-blocked). Item A owns this seam; later links extend it for the info pill.
///
/// It writes two PNGs under `<outdir>`:
///   - `scope-raw.png`   — the trace pre-fade, so you can confirm the scope spans the FULL width.
///   - `scope-faded.png` — the composite with the edge fade, so you can confirm the soft ends.
/// and asserts, by pixel metric, that the raw trace reaches both ends (full width) while the faded
/// image's edge columns are far darker than its center (the soft fade).
enum HUDRender {
    static func run(outDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        } catch {
            print("[hud-render] cannot create \(outDir): \(error)")
            return false
        }

        // The pill scope interior at scale 1.0: full capsule width, 6pt top/bottom inset (matches
        // layoutPill's `wave.frame`).
        let pw: CGFloat = HUDPillMetrics.baseWidth, ph: CGFloat = HUDPillMetrics.baseHeight
        let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: pw, height: ph - 12))

        // A few cycles of a low-amplitude sine so the trace is clearly visible AND spans the width.
        let n = 256
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = 0.18 * sinf(Float(i) / Float(n) * 2 * .pi * 6)
        }

        guard let (raw, faded) = wave.renderForSeam(samples: samples) else {
            print("[hud-render] render failed (no image)")
            return false
        }

        writePNG(raw, to: outDir + "/scope-raw.png")
        writePNG(faded, to: outDir + "/scope-faded.png")
        print("[hud-render] wrote scope-raw.png + scope-faded.png under \(outDir)")

        print("[hud-render] --- Item A (scope pill) ---")
        let scopeOK = verify(raw: raw, faded: faded)
        print("[hud-render] --- Item B (info pill) ---")
        let infoOK = renderInfo(outDir: outDir)
        print("[hud-render] --- low-power pill toasts ---")
        let toastOK = renderToasts(outDir: outDir)
        print("[hud-render] --- V1 keycap proportion + glyph centering ---")
        let keycapOK = renderKeycaps(outDir: outDir)
        print("[hud-render] --- V1 strength labels + divider ---")
        let sliderOK = renderSliderGeometry()
        let all = scopeOK && infoOK && toastOK && keycapOK && sliderOK
        print("[hud-render] \(all ? "ALL PASS (A+B+toasts+V1)" : "FAILURE(S)")")
        return all
    }

    // MARK: V1 — keycap proportion + glyph centering (the SHARED KeycapView)

    /// The info pill and the pop-up toast badge draw through the same `KeycapView`, and V1 changed that
    /// renderer, so both surfaces are gated here — the badge because it is the proportion REFERENCE
    /// that already looked right, the pill because it is the one that was wrong.
    ///
    /// Three properties, and deliberately NOT the constants they produce (a gate pinning "11pt in a
    /// 20x20 box" would happily wave through a future change that moved both numbers together):
    ///   1. the glyph point size is `KeycapView.glyphToBoxRatio` of the box, at every pill scale;
    ///   2. the glyph's rendered ink stays INSIDE the keycap border — the `?` used to bleed past it;
    ///   3. that ink is CENTERED in the box, which centering on the line height never was.
    /// (2) and (3) are measured off the real bitmap by diffing the drawn glyph against a blank keycap,
    /// so the renderer cannot gate its own arithmetic green.
    private static func renderKeycaps(outDir: String) -> Bool {
        var pass = true
        func chk(_ name: String, _ ok: Bool, _ detail: String) {
            print("  [\(ok ? "PASS" : "FAIL")] \(name) — \(detail)")
            if !ok { pass = false }
        }

        // 1) THE RATIO, read off the live views at several pill scales.
        let ratio = KeycapView.glyphToBoxRatio
        let info = InfoPillPanel()
        for ps in [InfoPillPanel.minScale, 1.0, 1.2, 1.5] as [CGFloat] {
            _ = info.renderCapsule(locked: false, cleanupEnabled: true, level: 1, ps: ps)
            let g = info.keycapGeometryForTesting
            let side = min(g.box.width, g.box.height)
            let want = KeycapView.glyphSize(forBox: side)
            chk("keycap-ratio-info-pill-ps\(fmt(Double(ps)))",
                side > 0 && abs(g.fontSize - want) < 0.01 && abs(g.fontSize / side - ratio) < 0.03,
                "box=\(fmt(Double(g.box.width)))x\(fmt(Double(g.box.height))) glyph=\(fmt(Double(g.fontSize)))pt "
                + "ratio=\(fmt3(Double(g.fontSize / max(side, 1)))) want=\(fmt3(Double(ratio)))")
        }

        let hud = HUDPanel()
        let badgeImage = hud.renderBadgeForSeam(glyph: "?", label: "Cleanup")
        if let img = badgeImage { writePNG(img, to: outDir + "/badge-cleanup.png") }
        let bg = hud.badgeKeycapGeometryForTesting
        let badgeSide = min(bg.box.width, bg.box.height)
        chk("keycap-ratio-toast-badge",
            badgeSide > 0 && abs(bg.fontSize - KeycapView.glyphSize(forBox: badgeSide)) < 0.01
                && abs(bg.fontSize / badgeSide - ratio) < 0.03,
            "box=\(fmt(Double(bg.box.width)))x\(fmt(Double(bg.box.height))) glyph=\(fmt(Double(bg.fontSize)))pt "
            + "ratio=\(fmt3(Double(bg.fontSize / max(badgeSide, 1))))")

        // 2 + 3) INK, measured. Diff the drawn glyph against the same keycap holding a blank glyph:
        // what is left is the mark itself (plus its glow), free of the fill and the border ring.
        func inkCheck(_ surface: String, lit: CGImage?, blank: CGImage?, box: NSRect, viewHeight: CGFloat) {
            guard let lit = lit, let blank = blank,
                  let ink = glyphInkBox(lit, blank, imageHeightInPoints: viewHeight) else {
                chk("keycap-glyph-ink-\(surface)", false, "no ink measured")
                return
            }
            // The border is a 1.4pt stroke on a 1.5pt inset; anything inside that is clear of it.
            let interior = box.insetBy(dx: 2.2, dy: 2.2)
            chk("keycap-glyph-inside-box-\(surface)",
                interior.contains(ink),
                "ink=\(fmtRect(ink)) must sit inside interior=\(fmtRect(interior)) of box=\(fmtRect(box))")
            let dx = ink.midX - box.midX, dy = ink.midY - box.midY
            chk("keycap-glyph-centered-\(surface)",
                abs(dx) <= 0.75 && abs(dy) <= 0.75,
                "ink center off by dx=\(fmt(Double(dx))) dy=\(fmt(Double(dy))) (box center \(fmt(Double(box.midX))),\(fmt(Double(box.midY))))")
        }

        // Info pill: an armed-mode keycap is the capsule holding ONLY the keycap, so the blank render is
        // pixel-identical apart from the glyph.
        let pillLit = info.renderCapsule(locked: false, cleanupEnabled: false, level: 0,
                                         armedModeGlyph: "?", ps: 1.0)
        let pillBox = info.keycapGeometryForTesting.frame
        let pillH = info.capsuleTargetFrame.height
        let pillBlank = info.renderCapsule(locked: false, cleanupEnabled: false, level: 0,
                                           armedModeGlyph: " ", ps: 1.0)
        if let img = pillLit { writePNG(img, to: outDir + "/info-keycap-glyph.png") }
        inkCheck("info-pill", lit: pillLit, blank: pillBlank, box: pillBox, viewHeight: pillH)

        // Toast badge: same treatment on the reference surface, so V1 has to prove it did not regress
        // the keycap it copied its proportion from. The label is identical in both renders.
        let badgeBlank = hud.renderBadgeForSeam(glyph: " ", label: "Cleanup")
        inkCheck("toast-badge", lit: badgeImage, blank: badgeBlank, box: bg.frame, viewHeight: bg.canvasHeight)

        // A DESCENDING glyph is the case line-height centering got most wrong, and a rebound cleanup key
        // can be one. Same box, comma instead of `?`: it must still land centered and inside.
        let commaLit = info.renderCapsule(locked: false, cleanupEnabled: false, level: 0,
                                          armedModeGlyph: ",", ps: 1.0)
        if let img = commaLit { writePNG(img, to: outDir + "/info-keycap-descender.png") }
        inkCheck("descender", lit: commaLit, blank: pillBlank,
                 box: info.keycapGeometryForTesting.frame, viewHeight: info.capsuleTargetFrame.height)

        return pass
    }

    // MARK: V1 — ALL-CAPS strength labels + the recentered divider

    /// The labels are uppercased through MEASUREMENT as well as drawing (uppercasing only at draw time
    /// makes them overlap, because the track width is derived from the measured strings), and the
    /// three-dot divider sits centered between the top of the words and the top of the pill border.
    /// Both are read off the live control, in capsule coordinates.
    private static func renderSliderGeometry() -> Bool {
        var pass = true
        func chk(_ name: String, _ ok: Bool, _ detail: String) {
            print("  [\(ok ? "PASS" : "FAIL")] \(name) — \(detail)")
            if !ok { pass = false }
        }

        let info = InfoPillPanel()
        _ = info.renderCapsule(locked: false, cleanupEnabled: true, level: 1, ps: 1.0)
        let (labels, frames) = info.sliderLabelsForTesting
        let g = info.sliderGeometryForTesting
        let capsuleH = info.capsuleTargetFrame.height

        chk("slider-labels-uppercase",
            labels.count == 3 && labels.allSatisfy { $0 == $0.uppercased() && !$0.isEmpty },
            "labels=\(labels.joined(separator: ","))")

        // The trap, stated as geometry: the frames the control will actually paint into must not run
        // into each other, and must stay inside the width it asked the pill for.
        let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
        chk("slider-labels-no-overlap",
            frames.count == 3 && gaps.allSatisfy { $0 > 0 },
            "gaps=\(gaps.map { fmt(Double($0)) }.joined(separator: ",")) frames=\(frames.map { fmtRect($0) }.joined(separator: " "))")
        chk("slider-labels-within-slider",
            frames.count == 3 && (frames[0].minX >= -0.5) && (frames[2].maxX <= g.frame.width + 0.5),
            "first.minX=\(fmt(Double(frames.first?.minX ?? -99))) last.maxX=\(fmt(Double(frames.last?.maxX ?? -99))) "
            + "sliderW=\(fmt(Double(g.frame.width)))")

        // The divider, in CAPSULE coordinates: equally far from the top of the words as from the top of
        // the pill border. Measured against the frame the pill really gave the slider, not re-derived.
        let dividerY = g.frame.minY + g.trackCenterY
        let wordsTopY = g.frame.minY + g.labelInkTop
        let toWords = dividerY - wordsTopY, toBorder = capsuleH - dividerY
        chk("slider-divider-centered-in-band",
            toWords > 0 && toBorder > 0 && abs(toWords - toBorder) <= 0.75,
            "divider y=\(fmt(Double(dividerY))) words top=\(fmt(Double(wordsTopY))) capsule h=\(fmt(Double(capsuleH))) "
            + "gapToWords=\(fmt(Double(toWords))) gapToBorder=\(fmt(Double(toBorder)))")
        chk("slider-divider-inside-control",
            g.trackCenterY <= g.frame.height && g.trackCenterY > g.labelInkTop,
            "trackCenterY=\(fmt(Double(g.trackCenterY))) height=\(fmt(Double(g.frame.height))) "
            + "labelInkTop=\(fmt(Double(g.labelInkTop)))")

        return pass
    }

    /// Bounding box of what `lit` draws and `blank` does not, in POINTS of a view `imageHeightInPoints`
    /// tall (the bitmap is at backing scale). Thresholded high so the box tracks the glyph core rather
    /// than the soft phosphor glow around it. Nil when nothing differs.
    private static func glyphInkBox(_ lit: CGImage, _ blank: CGImage, imageHeightInPoints: CGFloat) -> CGRect? {
        guard lit.width == blank.width, lit.height == blank.height, lit.width > 0, lit.height > 0,
              imageHeightInPoints > 0 else { return nil }
        let w = lit.width, h = lit.height
        func bytes(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ok = data.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? data : nil
        }
        guard let a = bytes(lit), let b = bytes(blank) else { return nil }
        var delta = [Int](repeating: 0, count: w * h)
        var peak = 0
        for i in 0..<(w * h) {
            let d = abs(Int(a[i * 4 + 1]) - Int(b[i * 4 + 1]))   // green channel — the phosphor
            delta[i] = d
            if d > peak { peak = d }
        }
        guard peak > 20 else { return nil }
        let cut = Int(Double(peak) * 0.55)
        var minX = w, maxX = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            for x in 0..<w where delta[row * w + x] >= cut {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if row < minRow { minRow = row }; if row > maxRow { maxRow = row }
            }
        }
        guard maxX >= minX, maxRow >= minRow else { return nil }
        let scale = CGFloat(h) / imageHeightInPoints          // pixels per point
        // Memory row 0 is the TOP of the image; view coordinates run bottom-up.
        let top = imageHeightInPoints - CGFloat(minRow) / scale
        let bottom = imageHeightInPoints - CGFloat(maxRow + 1) / scale
        return CGRect(x: CGFloat(minX) / scale, y: bottom,
                      width: CGFloat(maxX + 1 - minX) / scale, height: top - bottom)
    }

    private static func fmt3(_ d: Double) -> String { String(format: "%.3f", d) }
    private static func fmtRect(_ r: CGRect) -> String {
        "(\(fmt(Double(r.minX))),\(fmt(Double(r.minY))) \(fmt(Double(r.width)))x\(fmt(Double(r.height))))"
    }

    // MARK: low-power in-pill status toasts

    /// Render the low-power in-pill status toast: a SHORT message and a LONGER (wrapping) one as
    /// pill-styled capsules grown to fit, plus a paragraph-length `answer()` that must stay the full
    /// box. Writes a PNG each (for a human/vision legibility check) and asserts the capsule grows with
    /// the message while `answer()` stays wider (full box) and every capture is non-blank green.
    private static func renderToasts(outDir: String) -> Bool {
        let snapshot = HUDDefaultsSnapshot()
        defer { snapshot.restore() }

        Settings.powerMode = .finalOnly
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .bottomCenter

        let hud = HUDPanel()
        var widths: [String: CGFloat] = [:]
        var centers: [String: Double] = [:]

        func render(_ name: String, _ message: String, forceFull: Bool) {
            guard let img = hud.renderToastForSeam(message: message, forceFull: forceFull) else {
                widths[name] = 0; centers[name] = 0
                print("  \(name): render failed")
                return
            }
            writePNG(img, to: outDir + "/\(name).png")
            widths[name] = hud.frameForTesting.width
            centers[name] = avg(columnGreen(img), 0.4, 0.6)
            print("  wrote \(name).png (panel width \(fmt(Double(widths[name] ?? 0))), center-green \(fmt(centers[name] ?? 0)))")
        }

        render("toast-short", "Nothing heard", forceFull: false)
        render("toast-long", "📋 Couldn't reach the locked field, so your transcript is on the clipboard instead — press ⌘V once to paste it, and your previous clipboard then restores automatically.", forceFull: false)
        render("answer-full", "The tallest mountain in the world is Mount Everest at 8,849 metres above sea level, on the border of Nepal and the Tibet Autonomous Region of China.", forceFull: true)

        var pass = true
        func chk(_ name: String, _ ok: Bool, _ detail: String) {
            print("  [\(ok ? "PASS" : "FAIL")] \(name) — \(detail)")
            if !ok { pass = false }
        }
        let short = widths["toast-short"] ?? 0, long = widths["toast-long"] ?? 0, ans = widths["answer-full"] ?? 0
        chk("toast-short-is-pill", short >= 290 && short < 700, "short width=\(fmt(Double(short)))")
        chk("toast-long-grows-wider", long > short, "long=\(fmt(Double(long))) short=\(fmt(Double(short)))")
        chk("answer-stays-full", ans > 700, "answer width=\(fmt(Double(ans)))")
        chk("toast-short-legible", (centers["toast-short"] ?? 0) > 20, "center-green=\(fmt(centers["toast-short"] ?? 0))")
        chk("toast-long-legible", (centers["toast-long"] ?? 0) > 20, "center-green=\(fmt(centers["toast-long"] ?? 0))")
        return pass
    }

    // MARK: Item B — the content-gated info pill

    /// Render the info pill's four gating states offscreen, write a PNG per shown state, and assert the
    /// content-gating (idle ⇒ no pill) and "more active elements ⇒ a wider pill" by capsule width.
    private static func renderInfo(outDir: String) -> Bool {
        let info = InfoPillPanel()
        let states: [(name: String, locked: Bool, cleanup: Bool, level: Int)] = [
            ("idle", false, false, 0),
            ("locked", true, false, 0),
            ("cleanup", false, true, 1),
            ("both", true, true, 2),
        ]
        var widths: [String: CGFloat] = [:]
        for s in states {
            if let img = info.renderCapsule(locked: s.locked, cleanupEnabled: s.cleanup, level: s.level, ps: 1.0) {
                writePNG(img, to: outDir + "/info-\(s.name).png")
                widths[s.name] = info.lastCapsuleWidth
                print("  wrote info-\(s.name).png (capsule width \(fmt(Double(info.lastCapsuleWidth))))")
            } else {
                widths[s.name] = 0
                print("  info-\(s.name): not shown (content-gated)")
            }
        }

        var pass = true
        func chk(_ name: String, _ ok: Bool, _ detail: String) {
            print("  [\(ok ? "PASS" : "FAIL")] \(name) — \(detail)")
            if !ok { pass = false }
        }
        let idle = widths["idle"] ?? -1, locked = widths["locked"] ?? 0
        let cleanup = widths["cleanup"] ?? 0, both = widths["both"] ?? 0
        // 1) idle (nothing locked, cleanup off) shows NO info pill at all.
        chk("info-gated-idle", idle == 0, "idle width=\(fmt(Double(idle))) expect 0")
        // 2) each single-category state shows a pill.
        chk("info-shown-locked", locked > 0, "locked width=\(fmt(Double(locked)))")
        chk("info-shown-cleanup", cleanup > 0, "cleanup width=\(fmt(Double(cleanup)))")
        // 3) more elements => wider pill (both = lock + keycap + slider is widest).
        chk("info-both-widest", both > locked && both > cleanup,
            "both=\(fmt(Double(both))) locked=\(fmt(Double(locked))) cleanup=\(fmt(Double(cleanup)))")

        // S1: prove a live-map rebind reaches BOTH cleanup keycaps and changes the actual info-pill
        // pixels. The exact glyph checks catch a stale/hardcoded path; the bitmap delta catches a seam
        // that updates model state without redrawing the view.
        let defaultMap = HotkeyMap.defaults()
        var reboundMap = defaultMap
        reboundMap.assign(.regular(keyCode: 18, label: "1"), to: .command(.cleanupToggle))

        let defaultInfo = InfoPillPanel()
        defaultInfo.setHotkeyMap(defaultMap)
        let defaultGlyphImage = defaultInfo.renderCapsule(
            locked: false, cleanupEnabled: true, level: 1, ps: 1.0)
        if let image = defaultGlyphImage {
            writePNG(image, to: outDir + "/info-cleanup-default-glyph.png")
        }

        let reboundHUD = HUDPanel()
        reboundHUD.setHotkeyMap(reboundMap)
        let reboundGlyphs = reboundHUD.cleanupGlyphsForTesting
        let reboundInfo = InfoPillPanel()
        reboundInfo.setHotkeyMap(reboundMap)
        let reboundGlyphImage = reboundInfo.renderCapsule(
            locked: false, cleanupEnabled: true, level: 1, ps: 1.0)
        if let image = reboundGlyphImage {
            writePNG(image, to: outDir + "/info-cleanup-rebound-glyph.png")
        }

        let changedPixels: Int
        if let before = defaultGlyphImage, let after = reboundGlyphImage {
            changedPixels = differingPixelCount(before, after) ?? 0
        } else {
            changedPixels = 0
        }
        let bindingOK = reboundGlyphs.full == "1"
            && reboundGlyphs.pill == "1"
            && changedPixels > 5
        print("  [\(bindingOK ? "PASS" : "FAIL")] info-bound-cleanup-glyph - "
              + "full=\(reboundGlyphs.full) pill=\(reboundGlyphs.pill) "
              + "changedPixels=\(changedPixels)")
        if !bindingOK { pass = false }

        // S2: an armed dictation-capable mode owns the same keycap slot without inheriting Cleanup's
        // slider. Assert both HUD paths, the exact armed glyph, the content set, and a real pixel delta
        // between two mode glyphs so updating only backing state cannot pass.
        let armedHUD = HUDPanel()
        armedHUD.setCleanup(enabled: false, level: 1)
        armedHUD.setArmedMode(glyph: "L")
        let fullArm = armedHUD.armedModeIndicatorForTesting

        let armedInfo = InfoPillPanel()
        let armedImage = armedInfo.renderCapsule(
            locked: false, cleanupEnabled: false, level: 1,
            armedModeGlyph: "L", ps: 1.0)
        if let image = armedImage {
            writePNG(image, to: outDir + "/info-armed-mode-L.png")
        }
        let otherArmedInfo = InfoPillPanel()
        let otherArmedImage = otherArmedInfo.renderCapsule(
            locked: false, cleanupEnabled: false, level: 1,
            armedModeGlyph: "G", ps: 1.0)
        let armedChangedPixels: Int
        if let before = armedImage, let after = otherArmedImage {
            armedChangedPixels = differingPixelCount(before, after) ?? 0
        } else {
            armedChangedPixels = 0
        }
        let armedElements = armedInfo.activeElementsForTesting
        let armedOK = fullArm.glyph == "L"
            && fullArm.lit
            && fullArm.sliderHidden
            && armedInfo.cleanupGlyphForTesting == "L"
            && armedElements == ["keycap"]
            && armedImage != nil
            && armedChangedPixels > 5
        print("  [\(armedOK ? "PASS" : "FAIL")] info-armed-mode-keycap - "
              + "full=\(fullArm.glyph) lit=\(fullArm.lit ? 1 : 0) "
              + "pill=\(armedInfo.cleanupGlyphForTesting) "
              + "elements=\(armedElements.joined(separator: ",")) "
              + "changedPixels=\(armedChangedPixels)")
        if !armedOK { pass = false }

        // 3b) BULLSEYE glyph (notes-bullseye BT2): the leftmost target glyph, content-gated on the
        // armed sticky-note bullseye exactly like the lock. The headless build links could not run this
        // seam (`--hud-render`/`--hud-probe` need a GUI session), so the glyph shipped unpinned; this is
        // the GUI-context confirmation. Render it alone (PNG for a human/vision look) and alongside the
        // lock, and assert it renders + occupies pill width. See InfoPillPanel.apply(bullseyeArmed:).
        var bullseyeAlone: CGFloat = 0, lockPlusBullseye: CGFloat = 0
        if let img = info.renderCapsule(locked: false, cleanupEnabled: false, level: 0,
                                        bullseyeArmed: true, ps: 1.0) {
            writePNG(img, to: outDir + "/info-bullseye.png")
            bullseyeAlone = info.lastCapsuleWidth
            print("  wrote info-bullseye.png (capsule width \(fmt(Double(bullseyeAlone))))")
        }
        if let img = info.renderCapsule(locked: true, cleanupEnabled: false, level: 0,
                                        bullseyeArmed: true, ps: 1.0) {
            writePNG(img, to: outDir + "/info-bullseye-lock.png")
            lockPlusBullseye = info.lastCapsuleWidth
            print("  wrote info-bullseye-lock.png (capsule width \(fmt(Double(lockPlusBullseye))))")
        }
        chk("info-shown-bullseye", bullseyeAlone > 0, "bullseye-alone width=\(fmt(Double(bullseyeAlone)))")
        chk("info-bullseye-adds-width", lockPlusBullseye > locked,
            "lock+bullseye=\(fmt(Double(lockPlusBullseye))) lock=\(fmt(Double(locked)))")

        // 4) FIXED MINIMUM SIZE: a pill-size BELOW the floor renders IDENTICALLY to the floor (the user's
        // "the bottom pill needs a fixed minimum size regardless of the overall UI scale"). Render the
        // widest state at the floor and well below it, and assert equal capsule widths.
        let atFloor = info.renderCapsule(locked: true, cleanupEnabled: true, level: 2, ps: InfoPillPanel.minScale)
        let wFloor = info.lastCapsuleWidth
        if let f = atFloor { writePNG(f, to: outDir + "/info-floor.png") }
        let belowFloor = info.renderCapsule(locked: true, cleanupEnabled: true, level: 2, ps: 0.5)
        let wBelow = info.lastCapsuleWidth
        if let b = belowFloor { writePNG(b, to: outDir + "/info-belowfloor.png") }
        print("  wrote info-floor.png (\(fmt(Double(wFloor)))) + info-belowfloor.png (\(fmt(Double(wBelow))))")
        chk("info-floored-below-min", abs(wFloor - wBelow) < 0.5,
            "floor(\(fmt(Double(InfoPillPanel.minScale))))=\(fmt(Double(wFloor))) below(0.5)=\(fmt(Double(wBelow)))")
        return pass
    }

    // MARK: pixel metrics

    /// Count pixels whose rendered RGBA values differ. Used by the S1 rebound-glyph assertion so the
    /// GUI gate proves the keycap was redrawn, not merely that its backing string changed.
    private static func differingPixelCount(_ lhs: CGImage, _ rhs: CGImage) -> Int? {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return nil }
        let width = lhs.width, height = lhs.height

        func bytes(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    return false
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return rendered ? data : nil
        }

        guard let left = bytes(lhs), let right = bytes(rhs) else { return nil }
        var count = 0
        for offset in stride(from: 0, to: left.count, by: 4) {
            if left[offset] != right[offset]
                || left[offset + 1] != right[offset + 1]
                || left[offset + 2] != right[offset + 2]
                || left[offset + 3] != right[offset + 3] {
                count += 1
            }
        }
        return count
    }

    /// Per-column peak green value (0…255). The trace is green premultiplied over transparent, so a
    /// column's peak green tracks trace presence AND the edge fade (fade -> alpha -> premultiplied
    /// green fall together).
    private static func columnGreen(_ img: CGImage) -> [Double] {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }
        var cols = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var m: Double = 0
            for y in 0..<h {
                let g = Double(data[(y * w + x) * 4 + 1])   // green channel, premultiplied
                if g > m { m = g }
            }
            cols[x] = m
        }
        return cols
    }

    private static func avg(_ a: [Double], _ lo: Double, _ hi: Double) -> Double {
        let w = a.count
        let l = max(0, Int(Double(w) * lo)), h = min(w, Int(Double(w) * hi))
        guard h > l else { return 0 }
        return a[l..<h].reduce(0, +) / Double(h - l)
    }

    private static func verify(raw: CGImage, faded: CGImage) -> Bool {
        let rc = columnGreen(raw), fc = columnGreen(faded)
        guard !rc.isEmpty, !fc.isEmpty else {
            print("[hud-render] FAIL — no pixel data")
            return false
        }

        let center     = avg(fc, 0.45, 0.55)
        let leftEdge    = avg(fc, 0.0, 0.03)
        let rightEdge   = avg(fc, 0.97, 1.0)
        let rawLeft     = avg(rc, 0.0, 0.03)
        let rawRight    = avg(rc, 0.97, 1.0)
        let rawCenter   = avg(rc, 0.45, 0.55)

        var pass = true
        func chk(_ name: String, _ ok: Bool, _ detail: String) {
            print("  [\(ok ? "PASS" : "FAIL")] \(name) — \(detail)")
            if !ok { pass = false }
        }

        // 1) Raw (pre-fade) trace reaches both ends -> the scope spans the full pill width.
        chk("scope-full-width",
            rawLeft > 0.15 * rawCenter && rawRight > 0.15 * rawCenter,
            "rawLeft=\(fmt(rawLeft)) rawRight=\(fmt(rawRight)) rawCenter=\(fmt(rawCenter))")
        // 2) Faded edges are far darker than the center -> the soft horizontal fade at both ends.
        chk("edge-fade-left", leftEdge < 0.35 * center, "leftEdge=\(fmt(leftEdge)) center=\(fmt(center))")
        chk("edge-fade-right", rightEdge < 0.35 * center, "rightEdge=\(fmt(rightEdge)) center=\(fmt(center))")
        // 3) The trace itself is actually visible in the center (guards against a blank render).
        chk("center-visible", center > 20, "center=\(fmt(center))")

        return pass
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }

    private static func writePNG(_ img: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("[hud-render] PNG encode failed for \(path)")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
