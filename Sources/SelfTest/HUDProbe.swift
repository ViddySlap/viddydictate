import Cocoa

/// Headless-ish HUD layout probe (`--hud-probe`): drive the real `HUDPanel` through the display
/// settings matrix — Final-only pill vs Live HUD, all nine `HUDPosition` anchors, both size scales —
/// and assert the resulting panel frames numerically. Needs a GUI session (panels flash briefly on
/// screen) but no mic, no key tap, no LM Studio. The dictation-side Final-only behavior (the skipped
/// partial-preview loop) is a one-line guard exercised in live use; this probe covers the layout
/// math, which is where regressions would hide.
enum HUDProbe {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("  [\(ok ? "PASS" : "FAIL")] \(name) — \(detail)")
        if !ok { failures += 1 }
    }

    private static func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 1.5) -> Bool { abs(a - b) <= tol }
    private static func frameEq(_ a: NSRect, _ b: NSRect) -> Bool {
        approx(a.minX, b.minX) && approx(a.minY, b.minY) && approx(a.width, b.width) && approx(a.height, b.height)
    }

    static func run() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let snapshot = HUDDefaultsSnapshot()
        defer { snapshot.restore() }

        guard let vf = NSScreen.main?.visibleFrame else {
            print("[hud-probe] no screen — cannot probe layout")
            return false
        }
        print("[hud-probe] screen visibleFrame=\(vf)")
        let hud = HUDPanel()

        probeFullHUDDefault(hud, visibleFrame: vf)
        probeFullHUDAnchors(hud, visibleFrame: vf)
        probeFullHUDScale(hud, visibleFrame: vf)
        probeLowPowerPill(hud, visibleFrame: vf)
        probeInfoPill(hud)
        probeLowPowerToast(hud, visibleFrame: vf)
        probeModeAdaptiveRouterToast(hud, visibleFrame: vf)
        probePillAfterToast(hud)
        probeToastRevertMidTake(hud, visibleFrame: vf)

        hud.hide()
        print("[hud-probe] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    private static func probeFullHUDDefault(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 1) Full HUD at scale 1.0, default position: today's layout (width min(1080, screen-80),
        //    bottom-centered 80pt up).
        Settings.powerMode = .live
        Settings.hudScale = 1.0
        Settings.hudPosition = .bottomCenter
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()
        let f = hud.frameForTesting
        let expectW = min(1080, vf.width - 80)
        check("full-width", approx(f.width, expectW), "width=\(f.width) expect≈\(expectW)")
        check("full-bottom-center-x", approx(f.midX, vf.midX), "midX=\(f.midX) expect≈\(vf.midX)")
        check("full-bottom-center-y", approx(f.minY, vf.minY + 80), "minY=\(f.minY) expect≈\(vf.minY + 80)")
    }

    private static func probeFullHUDAnchors(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 2) Every anchor position homes the panel to the right corner/edge (full HUD).
        for pos in HUDPosition.allCases {
            Settings.hudPosition = pos
            hud.show()
            let f = hud.frameForTesting
            let expect = pos.origin(for: f.size, in: vf)
            check("anchor-\(pos.rawValue)",
                  approx(f.origin.x, expect.x) && approx(f.origin.y, expect.y),
                  "origin=\(f.origin) expect≈\(expect)")
        }
    }

    private static func probeFullHUDScale(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 3) HUD scale shrinks the full layout.
        Settings.hudPosition = .bottomCenter
        Settings.hudScale = 0.6
        hud.show()
        let f = hud.frameForTesting
        check("full-scaled-width", approx(f.width, 1080 * 0.6), "width=\(f.width) expect≈\(1080 * 0.6)")
    }

    private static func probeLowPowerPill(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 4) Low-power pill: compact capsule, scaled, honoring the anchor.
        Settings.powerMode = .finalOnly
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .topRight
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()
        var f = hud.frameForTesting
        check("pill-size", approx(f.width, 300) && approx(f.height, 64), "size=\(f.size) expect≈(300, 64)")
        let pillExpect = HUDPosition.topRight.origin(for: f.size, in: vf)
        check("pill-anchor-topRight",
              approx(f.origin.x, pillExpect.x) && approx(f.origin.y, pillExpect.y),
              "origin=\(f.origin) expect≈\(pillExpect)")

        // Item A: the scope spans the FULL pill width (x≈0, width≈pill width), and the REC dot is
        // gone in pill mode (the pill is strictly the oscilloscope now).
        var wf = hud.pillWaveFrameForTesting
        check("pill-scope-full-width",
              approx(wf.origin.x, 0) && approx(wf.width, 300),
              "waveFrame=\(wf) expect x≈0, width≈300")
        check("pill-no-rec-dot", hud.pillRecDotHiddenForTesting, "recDot hidden=\(hud.pillRecDotHiddenForTesting) expect true")

        Settings.hudPillScale = 1.5
        hud.show()
        f = hud.frameForTesting
        check("pill-scale", approx(f.width, 450) && approx(f.height, 96), "size=\(f.size) expect≈(450, 96)")
        // The full-width scope tracks the pill scale.
        wf = hud.pillWaveFrameForTesting
        check("pill-scope-full-width-scaled",
              approx(wf.origin.x, 0) && approx(wf.width, 450),
              "waveFrame=\(wf) expect x≈0, width≈450")
    }

    private static func probeInfoPill(_ hud: HUDPanel) {
        // Item B: the low-power INFO PILL is content-gated (lock and/or cleanup), grows as more
        // elements join, sits just below the scope, and NEVER moves the scope pill — its on-screen
        // frame is invariant across every info-pill show/hide/resize.
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .topRight   // 300x64 topRight needs no clamp, so the scope home is stable

        // idle: nothing locked, cleanup off -> scope only, no info pill.
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.setCleanup(enabled: false, level: 0)
        hud.show()
        let scopeIdle = hud.frameForTesting
        check("info-hidden-when-idle", !hud.infoPillShownForTesting,
              "shown=\(hud.infoPillShownForTesting) expect false")

        // locked only -> the info pill appears, just below the scope; the scope stays put.
        hud.update(state: "Locked — speaking", target: "probe", text: "", locked: true)
        check("info-shown-when-locked", hud.infoPillShownForTesting, "shown=\(hud.infoPillShownForTesting)")
        let infoLocked = hud.infoPillFrameForTesting
        check("scope-invariant-locked", frameEq(hud.frameForTesting, scopeIdle),
              "scope=\(hud.frameForTesting) expect=\(scopeIdle)")
        check("info-below-scope", infoLocked.maxY <= scopeIdle.minY + 1.5,
              "infoMaxY=\(infoLocked.maxY) scopeMinY=\(scopeIdle.minY)")
        check("info-centered-under-scope", approx(infoLocked.midX, scopeIdle.midX),
              "infoMidX=\(infoLocked.midX) scopeMidX=\(scopeIdle.midX)")

        // cleanup only -> the info pill appears (keycap + labeled slider); the scope stays put.
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.setCleanup(enabled: true, level: 1)
        check("info-shown-when-cleanup", hud.infoPillShownForTesting, "shown=\(hud.infoPillShownForTesting)")
        let infoCleanup = hud.infoPillFrameForTesting
        check("scope-invariant-cleanup", frameEq(hud.frameForTesting, scopeIdle),
              "scope=\(hud.frameForTesting) expect=\(scopeIdle)")

        // both -> the widest pill (lock + keycap + slider); the scope still stays put.
        hud.update(state: "Locked — speaking", target: "probe", text: "", locked: true)
        hud.setCleanup(enabled: true, level: 2)
        check("info-shown-when-both", hud.infoPillShownForTesting, "shown=\(hud.infoPillShownForTesting)")
        let infoBoth = hud.infoPillFrameForTesting
        check("scope-invariant-both", frameEq(hud.frameForTesting, scopeIdle),
              "scope=\(hud.frameForTesting) expect=\(scopeIdle)")
        check("info-wider-with-more-elements",
              infoBoth.width > infoLocked.width && infoBoth.width > infoCleanup.width,
              "both=\(infoBoth.width) locked=\(infoLocked.width) cleanup=\(infoCleanup.width)")

        // The REAL take-start path: hide() then show() with lock+cleanup already latched. show()
        // applies the info pill twice (layoutPill, then the post-clamp re-anchor); the second apply
        // must not strand the appear animation — once it settles, every gated element must actually
        // be visible (not stuck at alpha 0 inside a visible empty capsule). Spin the runloop so the
        // phase-2 grow completes and phase 3 gets scheduled (model alphas flip to 1 at that point).
        hud.hide()
        hud.show()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        let invis = hud.infoPillInvisibleContentForTesting
        check("info-contents-visible-after-show", hud.infoPillShownForTesting && invis.isEmpty,
              "shown=\(hud.infoPillShownForTesting) invisible=\(invis)")
        // The symmetric negative: NOTHING that is not part of the current set may still be visible under
        // the capsule (item 1a bleed / item 2 jumble). Before the content-gating rebuild the animated
        // path never hid elements absent from both curSet and newSet, so a glyph left over from an
        // earlier transition (or never touched at all) leaked under the lock/bullseye band. Must be [].
        let stray = hud.infoPillStrayVisibleContentForTesting
        check("info-no-stray-after-show", stray.isEmpty,
              "stray=\(stray) expect [] (no content leaking under the capsule)")
        check("scope-invariant-after-reshow", frameEq(hud.frameForTesting, scopeIdle),
              "scope=\(hud.frameForTesting) expect=\(scopeIdle)")

        // turning everything back off hides the info pill again; the scope is still invariant.
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.setCleanup(enabled: false, level: 0)
        check("info-hidden-again", !hud.infoPillShownForTesting, "shown=\(hud.infoPillShownForTesting)")
        check("scope-invariant-after-hide", frameEq(hud.frameForTesting, scopeIdle),
              "scope=\(hud.frameForTesting) expect=\(scopeIdle)")

        // BULLSEYE glyph (notes-bullseye BT2): arming the sticky-note bullseye adds the leftmost target
        // glyph to the pill and widens it, and the scope still never moves; disarming clears it. This is
        // the GUI-context confirmation the headless build links could not run (--hud-probe needs a GUI
        // session) — it pins the info-pill bullseye glyph so it cannot silently regress.
        hud.update(state: "Locked — speaking", target: "probe", text: "", locked: true)
        hud.setCleanup(enabled: false, level: 0)
        hud.setBullseyeArmed(false)
        let infoLockOnly = hud.infoPillFrameForTesting
        hud.setBullseyeArmed(true)
        check("info-shown-when-bullseye", hud.infoPillShownForTesting,
              "shown=\(hud.infoPillShownForTesting)")
        let infoLockBullseye = hud.infoPillFrameForTesting
        check("info-bullseye-widens-pill", infoLockBullseye.width > infoLockOnly.width,
              "lock+bullseye=\(infoLockBullseye.width) lock=\(infoLockOnly.width)")
        check("scope-invariant-bullseye", frameEq(hud.frameForTesting, scopeIdle),
              "scope=\(hud.frameForTesting) expect=\(scopeIdle)")
        // NEW live-path pin (a): stray-content EMPTY right after setBullseyeArmed on a SHOWN pill — the
        // DIRECT setBullseyeArmed -> updateInfoPill path, not the hide()/show()-mediated one the earlier
        // "info-no-stray-after-show" pin covers. Arming/disarming the bullseye glyph on a live pill must
        // never leave a glyph stranded under the capsule (the item 1a bleed class). This is the assertion
        // the last conductor recommended but never added; it is one of the pins that would have surfaced a
        // stray-content leak on the very path BUG 1's toast-revert re-runs.
        check("info-no-stray-after-bullseye-arm", hud.infoPillStrayVisibleContentForTesting.isEmpty,
              "stray=\(hud.infoPillStrayVisibleContentForTesting) expect [] (armed on a shown pill)")
        hud.setBullseyeArmed(false)
        check("info-bullseye-clears-on-disarm",
              approx(hud.infoPillFrameForTesting.width, infoLockOnly.width),
              "afterDisarm=\(hud.infoPillFrameForTesting.width) lockOnly=\(infoLockOnly.width)")
        check("info-no-stray-after-bullseye-disarm", hud.infoPillStrayVisibleContentForTesting.isEmpty,
              "stray=\(hud.infoPillStrayVisibleContentForTesting) expect [] (disarmed on a shown pill)")
    }

    private static func probeLowPowerToast(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 5) In low power, a short `toast()` now renders as a pill-styled capsule grown to fit (NOT the
        //    full box); a LONGER message grows the capsule wider; and `answer()` (paragraph-length web
        //    results) still forces the full readable box. This is the intended behavior change from the
        //    old "every low-power toast pops the full box".
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .bottomCenter
        let fullBoxW = min(1080, vf.width - 80)

        hud.toast("Nothing heard", duration: 0.2)
        let shortToast = hud.frameForTesting
        check("lowpower-toast-is-pill",
              shortToast.width >= 290 && shortToast.width < fullBoxW * 0.6,
              "width=\(shortToast.width) expect pill-ish (>=290, <\(fullBoxW * 0.6))")

        hud.toast("⚠️ Cleanup timed out — pasted raw. Your original transcript is on the clipboard; ⌘V to paste it.", duration: 0.2)
        let longToast = hud.frameForTesting
        check("lowpower-longer-toast-grows-wider", longToast.width > shortToast.width,
              "long=\(longToast.width) short=\(shortToast.width)")
        check("lowpower-toast-never-full-box", longToast.width <= fullBoxW + 1.5,
              "long=\(longToast.width) fullBox=\(fullBoxW)")

        hud.answer("The tallest mountain in the world is Mount Everest at 8,849 metres above sea level, on the border of Nepal and the Tibet Autonomous Region of China.")
        let answerBox = hud.frameForTesting
        check("lowpower-answer-stays-full", answerBox.width > 600, "width=\(answerBox.width) expect>600 (full box)")
    }

    private static func probeModeAdaptiveRouterToast(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // Router status toasts use the default non-forced path. Pin that exact path against BOTH Power
        // Modes so a current-mode refresh cannot silently collapse back to an always-full presentation.
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .bottomCenter
        let fullBoxW = min(1080, vf.width - 80)
        let message = "🔒 Private vault files are refused."

        Settings.powerMode = .live
        hud.toast(message, duration: 0.2)
        let liveToast = hud.frameForTesting
        check("router-toast-live-uses-full-box", approx(liveToast.width, fullBoxW),
              "width=\(liveToast.width) expect~\(fullBoxW)")

        Settings.powerMode = .finalOnly
        hud.toast(message, duration: 0.2)
        let finalOnlyToast = hud.frameForTesting
        check("router-toast-final-only-uses-pill",
              finalOnlyToast.width >= 290 && finalOnlyToast.width < fullBoxW * 0.75,
              "width=\(finalOnlyToast.width) expect pill-ish (>=290, <\(fullBoxW * 0.75))")
    }

    private static func probePillAfterToast(_ hud: HUDPanel) {
        // 6) After a toast, a fresh take returns to the scope pill.
        hud.hide()
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.setCleanup(enabled: false, level: 0)
        hud.show()
        let f = hud.frameForTesting
        check("pill-after-toast", approx(f.width, 300), "width=\(f.width) expect≈300")

        // 6b) The toast-cycle half of the stray-visible guard: with lock + cleanup latched, a toast
        // tears the info pill down (its dwell timer fires the pill's hide(), which now resets per-element
        // state) and the returning take re-shows lock + keycap + slider. Nothing may strand under the
        // returning capsule, and every gated element must actually be visible. This is the path item 2
        // hit — toast→pill cycles started `apply` from a dirty per-element state.
        hud.update(state: "Locked — speaking", target: "probe", text: "", locked: true)
        hud.setCleanup(enabled: true, level: 2)
        hud.show()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))   // let the pill settle with content in
        hud.toast("Nothing heard", duration: 0.2)                     // tears the info pill down for the dwell
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))   // dwell timer fires the pill's hide()
        hud.update(state: "Locked — speaking", target: "probe", text: "", locked: true)
        hud.setCleanup(enabled: true, level: 2)
        hud.show()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))   // returning take settles
        let strayReturn = hud.infoPillStrayVisibleContentForTesting
        let invisReturn = hud.infoPillInvisibleContentForTesting
        check("info-no-stray-after-toast-return", hud.infoPillShownForTesting && strayReturn.isEmpty,
              "shown=\(hud.infoPillShownForTesting) stray=\(strayReturn) expect shown, []")
        check("info-contents-visible-after-toast-return", invisReturn.isEmpty,
              "invisible=\(invisReturn) expect []")
    }

    private static func probeToastRevertMidTake(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 7) NEW live-path pin (b): the BUG 1 regression pin. In low power with a take LIVE, fire the exact
        //    mid-take Option+N confirmation toast; when its dwell fires, the HUD must revert to the recording
        //    SCOPE (panel back on screen + oscilloscope animating), NOT order itself off-screen. Under the
        //    pre-fix code the dwell called hide(), so the whole HUD vanished for the rest of the take while
        //    audio kept capturing — the exact BUG 1 symptom. This pin fails there and passes only with the
        //    take-aware dismissToast(). It is the pin the last conductor recommended but never added.
        Settings.powerMode = .finalOnly
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .topRight            // 300x64 topRight needs no clamp — a stable scope home

        hud.hide()
        hud.setCleanup(enabled: false, level: 0)
        hud.setTakeActive(false)
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()                                  // the low-power scope pill is up, wave running
        let homeScope = hud.frameForTesting
        let draggedOrigin = NSPoint(x: homeScope.minX - 72, y: homeScope.minY - 36)
        hud.simulateDragForTesting(to: draggedOrigin)
        let scopeBefore = hud.frameForTesting
        check("revert-drag-applied-before-toast",
              approx(scopeBefore.minX, draggedOrigin.x) && approx(scopeBefore.minY, draggedOrigin.y),
              "origin=\(scopeBefore.origin) expect=\(draggedOrigin)")
        check("revert-scope-up-before-toast",
              hud.panelVisibleForTesting && hud.pillWaveActiveForTesting && approx(scopeBefore.width, 300),
              "visible=\(hud.panelVisibleForTesting) wave=\(hud.pillWaveActiveForTesting) w=\(scopeBefore.width)")

        hud.setTakeActive(true)                     // the drag is complete; now the take is live
        hud.toast(NotesBullseyeLogic.setToast, duration: 0.2)         // the exact mid-take confirmation toast
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))   // mid-dwell: the toast is up, scope stopped
        let toastDuring = hud.frameForTesting
        check("revert-drag-origin-during-toast",
              approx(toastDuring.minX, draggedOrigin.x) && approx(toastDuring.minY, draggedOrigin.y),
              "origin=\(toastDuring.origin) expect=\(draggedOrigin)")
        check("revert-toast-stops-scope-mid-dwell", !hud.pillWaveActiveForTesting,
              "wave=\(hud.pillWaveActiveForTesting) expect false (scope stopped for the toast dwell)")

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))   // the dwell timer fires dismissToast()
        let scopeAfter = hud.frameForTesting
        check("revert-scope-onscreen-after-dwell", hud.panelVisibleForTesting,
              "visible=\(hud.panelVisibleForTesting) expect true (HUD must NOT order out mid-take)")
        check("revert-wave-active-after-dwell", hud.pillWaveActiveForTesting,
              "wave=\(hud.pillWaveActiveForTesting) expect true (oscilloscope back)")
        check("revert-drag-origin-after-dwell",
              approx(scopeAfter.minX, draggedOrigin.x) && approx(scopeAfter.minY, draggedOrigin.y),
              "origin=\(scopeAfter.origin) expect=\(draggedOrigin)")
        check("revert-is-scope-pill", approx(scopeAfter.width, 300) && frameEq(scopeAfter, scopeBefore),
              "after=\(scopeAfter) before=\(scopeBefore) expect the 300x64 scope pill back in place")

        // With NO take live, the same drag-first sequence must still re-home the toast and then hide it.
        hud.setTakeActive(false)
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()
        let noTakeScope = hud.frameForTesting
        let noTakeDraggedOrigin = NSPoint(x: noTakeScope.minX - 72, y: noTakeScope.minY - 36)
        hud.simulateDragForTesting(to: noTakeDraggedOrigin)
        hud.toast(NotesBullseyeLogic.setToast, duration: 0.2)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let noTakeToast = hud.frameForTesting
        let noTakeHome = Settings.hudPosition.origin(for: noTakeToast.size, in: vf)
        check("revert-no-take-toast-rehomes",
              approx(noTakeToast.minX, noTakeHome.x) && approx(noTakeToast.minY, noTakeHome.y),
              "origin=\(noTakeToast.origin) expect home=\(noTakeHome)")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))   // dwell fires; no take -> hide()
        check("revert-hides-when-no-take", !hud.panelVisibleForTesting,
              "visible=\(hud.panelVisibleForTesting) expect false (no take -> dwell hides)")

        hud.hide()
    }
}
