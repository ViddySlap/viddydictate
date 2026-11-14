import Foundation

// VDASK-5 self-test: the compact pill word and the ? toggle's pure rules, plus source-shape rows for the AppKit
// wiring no headless row can reach (the controller-level click rows live in AskBackControllerSelfTest.swift).
// Mirrors the Linux oracle's pill-rows.swift. Synthetic only.

enum AskBackPillSelfTest {
    static func run() -> Bool {
        print("--- ask-back pill: compact word, ? toggle rules, wiring ---")
        let check = SelfTestReporter()

        // The compact word, from the level.
        check("pill: compact word for Cleanup, Tighten and Summarize",
              CompactPillWord.word(forLevel: 0) == "CLEANUP" && CompactPillWord.word(forLevel: 1) == "TIGHTEN"
                && CompactPillWord.word(forLevel: 2) == "SUMMARIZE")
        check("pill: an out-of-range level clamps to the end words",
              CompactPillWord.word(forLevel: -3) == "CLEANUP" && CompactPillWord.word(forLevel: 9) == "SUMMARIZE")
        check("pill: compact paints only the active word; the full layout paints all three",
              (0...2).allSatisfy { CompactPillWord.drawnIndices(level: $0, compact: true) == [$0] }
                && CompactPillWord.drawnIndices(level: 1, compact: false) == [0, 1, 2])
        check("pill: the slider's three labels are the compact words (one source)",
              StrengthSlider.threeStopLabels == CompactPillWord.words)

        // The ? state for each combination of setting, level and provider.
        let providers: [AskBackProvider?] = [.claude, .codex, .local, nil]
        var tableOK = true, greyOK = true, cleanupOK = true, brightOK = true, tipOK = true
        for enabled in [true, false] {
            for level in AskBackLevel.allCases {
                for p in providers {
                    let s = AskBackToggleRules.state(enabled: enabled, level: level, provider: p)
                    let cloud = (p == .claude || p == .codex)
                    if cloud != s.clickable { tableOK = false }
                    if !cloud && (s.bright || s.outlined || s.tooltip != "Ask-back needs Claude or Codex") { greyOK = false }
                    if cloud && level == .cleanup && !(s.clickable && !s.bright && s.outlined) { cleanupOK = false }
                    if cloud && level != .cleanup && (s.bright != enabled || s.outlined) { brightOK = false }
                    if cloud && s.tooltip != (enabled ? "Ask-back on: questions before Tighten and Summarize" : "Ask-back off") { tipOK = false }
                }
            }
        }
        check("toggle: clickable exactly when the route is Claude or Codex (setting x level x provider)", tableOK)
        check("toggle: a local or off route is greyed with the tooltip, whatever the setting or level", greyOK)
        check("toggle: Cleanup on Claude or Codex stays clickable but dim-outlined", cleanupOK)
        check("toggle: Tighten and Summarize are bright when on, dim when off", brightOK)
        check("toggle: the on and off tooltips are exact", tipOK)

        let live = AskBackToggleRules.state(enabled: true, level: .tighten, provider: .claude)
        let grey = AskBackToggleRules.state(enabled: true, level: .tighten, provider: .local)
        check("click: a clickable ? flips the setting both ways",
              AskBackToggleRules.settingAfterClick(enabled: true, state: live) == false
                && AskBackToggleRules.settingAfterClick(enabled: false, state: live) == true)
        check("click: a greyed ? ignores a click", AskBackToggleRules.settingAfterClick(enabled: true, state: grey) == nil
              && AskBackToggleRules.settingAfterClick(enabled: false, state: grey) == nil)

        // Source-shape rows, named: AppKit views and the tap-free HUD wiring a headless row cannot construct.
        let appDir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        func src(_ name: String) -> String {
            (try? String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let hud = src("HUDPanel.swift")
        func body(_ from: String, _ upTo: String) -> String {
            guard let r = hud.range(of: from), let e = hud[r.upperBound...].range(of: upTo) else { return "" }
            return String(hud[r.lowerBound..<e.lowerBound])
        }
        check("wiring (AppKit button): the ? button refuses first responder, so a click never takes key focus from the paste target",
              body("final class AskBackToggleButton", "required init?").contains("refusesFirstResponder = true"))
        let apply = body("func apply(_ s: AskBackToggleState)", "private func updateStyle")
        check("wiring (AppKit button): the ? button is disabled when greyed and carries the state's tooltip",
              apply.contains("isEnabled = s.clickable") && apply.contains("toolTip = s.tooltip"))
        check("wiring (HUD panel): the button's action calls onToggleAskBack and it hides and shows with Lock and Stop",
              hud.contains("@objc private func askBackClicked() { onToggleAskBack?() }")
                && hud.contains("root.addSubview(askBackButton)")
                && hud.contains("lockButton.isHidden = hidden; stopButton.isHidden = hidden; askBackButton.isHidden = hidden")
                && hud.contains("lockButton.isHidden = false; stopButton.isHidden = false; askBackButton.isHidden = false"))
        check("wiring (info pill): the pill's slider is compact and paints through CompactPillWord.drawnIndices",
              src("InfoPill.swift").contains("slider.compactWord = true")
                && src("StrengthSlider.swift").contains("CompactPillWord.drawnIndices(level: CleanupLevel.clamped(level).rawValue, compact: compactWord)"))
        let dc = src("DictationController.swift")
        check("wiring (controller): the HUD click reaches toggleAskBackFromHUD, and a Settings or route change refreshes the ?",
              dc.contains("hud.onToggleAskBack = { [weak self] in self?.toggleAskBackFromHUD() }")
                && dc.contains("forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshAskBackToggle() }")
                && dc.contains("forName: ModelsPowerSettingsStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshAskBackToggle() }"))
        let settingsView = src("ModelsPowerSettingsView.swift")
        check("wiring (Settings): the checkbox reads Settings.askBackEnabled and the Settings view rebuilds on Settings.didChange, so it follows the ?",
              settingsView.contains("askCheck.state = Settings.askBackEnabled ? .on : .off")
                && settingsView.contains("forName: Settings.didChange, object: nil, queue: .main\n        ) { [weak self] _ in self?.rebuild() }"))

        // VDASK-5 repair round 1 (M1): the ? chip beside the info pill. Pure geometry here; the shown/hidden, position,
        // click and same-state rows that need the real HUD are in HUDProbe (probeAskBackChip).
        let vis = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cap = CGRect(x: 600, y: 300, width: 150, height: 34)
        let sz = CGSize(width: 40, height: 28)
        check("chip: no frame (hidden) when the info pill is not shown, a frame when it is",
              AskBackChipRules.frame(for: nil, size: sz) == nil
                && AskBackChipRules.frame(for: AskBackChipPlacement(capsule: cap, visible: vis, onRight: true), size: sz) != nil)
        let rf = AskBackChipRules.frame(for: AskBackChipPlacement(capsule: cap, visible: vis, onRight: true), size: sz)
        check("chip: sits at the pill's right end after a few points of gap, centred on the pill",
              rf?.minX == cap.maxX + AskBackChipRules.gap && rf?.midY == cap.midY)
        let wide = CGRect(x: 600, y: 300, width: 210, height: 34)
        check("chip: follows the pill's right edge after a width change",
              AskBackChipRules.frame(for: AskBackChipPlacement(capsule: wide, visible: vis, onRight: true), size: sz)?.minX
                == wide.maxX + AskBackChipRules.gap)
        let lf = AskBackChipRules.frame(for: AskBackChipPlacement(capsule: cap, visible: vis, onRight: false), size: sz)
        check("chip: with the pill left of the scope the chip goes on the capsule's left end",
              lf?.maxX == cap.minX - AskBackChipRules.gap)
        let edge = AskBackChipRules.frame(for: AskBackChipPlacement(
            capsule: CGRect(x: 1380, y: 300, width: 50, height: 34), visible: vis, onRight: true), size: sz)
        check("chip: stays inside the screen's visible frame", (edge?.maxX ?? 9999) <= vis.maxX)
        // VDASK-5 repair round 2 (M1): the near-chip hold that makes the moving ? reachable.
        let chipRect = CGRect(x: 680, y: 450, width: 37, height: 28)
        var hold = AskBackChipHold()
        check("chip hold: no chip means no hold, and reset is explicit",
              !hold.update(pointer: NSPoint(x: 700, y: 460), previousPointer: nil, chip: nil)
                && !hold.isHolding)
        check("chip hold: starts within 40 points of the real chip frame and stays while inside",
              hold.update(pointer: NSPoint(x: chipRect.minX - 39, y: chipRect.midY), previousPointer: nil, chip: chipRect)
                && hold.isHolding
                && hold.update(pointer: NSPoint(x: chipRect.midX, y: chipRect.midY), previousPointer: nil, chip: chipRect))
        check("chip hold: releases outside the 40-point halo",
              !hold.update(pointer: NSPoint(x: chipRect.maxX + 41, y: chipRect.midY), previousPointer: nil, chip: chipRect)
                && !hold.isHolding)
        check("chip hold: reset drops an active hold",
              hold.update(pointer: NSPoint(x: chipRect.midX, y: chipRect.midY), previousPointer: nil, chip: chipRect)
                && { hold.reset(); return !hold.isHolding }())
        var approach = AskBackChipHold()
        let farStart = NSPoint(x: 400, y: 500), farOne = NSPoint(x: 450, y: 500)
        let firstMove = approach.update(pointer: farOne, previousPointer: farStart, chip: chipRect)
        let secondMove = approach.update(pointer: NSPoint(x: 500, y: 500), previousPointer: farOne, chip: chipRect)
        let awayAgain = approach.update(pointer: NSPoint(x: 430, y: 500), previousPointer: NSPoint(x: 500, y: 500), chip: chipRect)
        check("chip hold: one move tick keeps following; a sustained approach freezes; turning away releases",
              !firstMove && secondMove && awayAgain == false && !approach.isHolding)
        // A pointer starting at the scope can travel to the chip only if the approach latches the hold before
        // the next tick moves the row. Model the real rigid row (chip = pointer + a fixed offset) across scales.
        func reachable(scale: CGFloat) -> Bool {
            var latch = AskBackChipHold()
            var pointer = NSPoint(x: 500, y: 500)
            let offset = CGPoint(x: 180 * scale, y: -50 * scale)
            var chip = CGRect(x: pointer.x + offset.x, y: pointer.y + offset.y, width: 37, height: 28)
            for _ in 0..<200 {
                let target = NSPoint(x: chip.midX, y: chip.midY)
                let next = NSPoint(x: pointer.x + (target.x - pointer.x) * 0.1,
                                   y: pointer.y + (target.y - pointer.y) * 0.1)
                let held = latch.update(pointer: next, previousPointer: pointer, chip: chip)
                pointer = next
                if held { if chip.contains(pointer) { return true } }
                else { chip = CGRect(x: pointer.x + offset.x, y: pointer.y + offset.y,
                                     width: chip.width, height: chip.height) }
            }
            return false
        }
        check("chip hold: a pointer approaching from the scope can reach the chip at 60%, 100% and 150% scale",
              reachable(scale: 0.6) && reachable(scale: 1.0) && reachable(scale: 1.5))
        // A clamped chip at the screen's right edge is still reachable by the same approach.
        let edgeChip = CGRect(x: vis.maxX - 37, y: 450, width: 37, height: 28)
        var edgeHold = AskBackChipHold()
        var edgePointer = NSPoint(x: edgeChip.midX - 180, y: edgeChip.midY)
        var edgeReached = false
        for _ in 0..<40 {
            let next = NSPoint(x: edgePointer.x + (edgeChip.midX - edgePointer.x) * 0.1,
                               y: edgePointer.y + (edgeChip.midY - edgePointer.y) * 0.1)
            if edgeHold.update(pointer: next, previousPointer: edgePointer, chip: edgeChip) { edgePointer = next }
            else { edgePointer = next }
            if edgeChip.contains(edgePointer) { edgeReached = true; break }
        }
        check("chip hold: a chip clamped at the screen edge is reachable", edgeReached)
        let chipSrc = src("AskBackToggleChip.swift")
        check("wiring (chip panel): non-activating, never key, mouse-taking, holds the shared AskBackToggleButton, only reports a click",
              chipSrc.contains("override var canBecomeKey: Bool { false }") && chipSrc.contains("styleMask: [.borderless, .nonactivatingPanel]")
                && chipSrc.contains("panel.ignoresMouseEvents = false") && chipSrc.contains("private let button = AskBackToggleButton()")
                && chipSrc.contains("@objc private func clicked() { onClick?() }") && !chipSrc.contains("Settings."))
        check("wiring (HUD and info pill): the chip follows the pill's placement, its click goes to onToggleAskBack, and one state call feeds both ?s",
              hud.contains("infoPill.onPlacement = { [weak self] placement in self?.askBackChip.place(placement) }")
                && hud.contains("askBackChip.onClick = { [weak self] in self?.onToggleAskBack?() }")
                && hud.contains("askBackChip.apply(state)")
                && src("InfoPill.swift").contains("onPlacement?(isShown ? AskBackChipPlacement(")
                && src("InfoPill.swift").contains("panel.ignoresMouseEvents = true"))
        check("wiring (HUD): the chip hold is decided before the row re-anchors and is reset on hide and mode changes",
              body("private func followTick()", "private func startFollowTimer()").contains("chipHold.update(")
                && body("private func followTick()", "private func startFollowTimer()").contains("if holding { return }")
                && body("    func hide() {", "    func setTakeActive").contains("resetChipHold()")
                && body("    func show() {", "private func presentForCurrentMode").contains("resetChipHold()")
                && hud.contains("didSet { if mode != oldValue { resetChipHold() } }"))

        print(check.summaryLine(prefix: "[askback-pill-selftest]"))
        return check.passed
    }
}
