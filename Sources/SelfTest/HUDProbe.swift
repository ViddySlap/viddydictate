import Cocoa

/// Headless-ish HUD layout probe (`--hud-probe`): drive the real `HUDPanel` through the scope-pill and
/// toast display settings — anchors, both size scales —
/// and assert the resulting panel frames numerically. Needs a GUI session (panels flash briefly on
/// screen) but no mic, no key tap, no LM Studio. It covers the layout math, which is where regressions
/// would hide.
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
        // Stable providers for the whole run: the scope pill's frame is now derived from the pointer, so
        // every probe that asserts a scope-* frame pins the pointer to one spot on the one visible screen.
        // (The pointer and screen seams both fall back to production when not set.)
        hud.pointerProviderForTesting = { NSPoint(x: vf.minX + 400, y: vf.maxY - 200) }
        hud.screensProviderForTesting = { [HUDPointerPlacement.Screen(frame: vf, visible: vf)] }

        probeLowPowerPill(hud, visibleFrame: vf)
        probeInfoPill(hud)
        probeLowPowerToast(hud, visibleFrame: vf)
        probeModeAdaptiveRouterToast(hud, visibleFrame: vf)
        probePillAfterToast(hud)
        probeToastRevertMidTake(hud, visibleFrame: vf)
        probePointerFollow(hud, visibleFrame: vf)

        hud.hide()
        print("[hud-probe] \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
        return failures == 0
    }

    private static func probeLowPowerPill(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 4) Low-power pill: compact capsule, scaled, and FOLLOWING THE POINTER (VDCURB1) — the pill no
        //    longer homes to the position setting, so the pointer and screen sources are pinned here.
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .topRight
        let point = NSPoint(x: vf.minX + 400, y: vf.maxY - 200)
        let screens = [HUDPointerPlacement.Screen(frame: vf, visible: vf)]
        hud.pointerProviderForTesting = { point }
        hud.screensProviderForTesting = { screens }
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()
        var f = hud.frameForTesting
        check("pill-size", approx(f.width, 300) && approx(f.height, 64), "size=\(f.size) expect≈(300, 64)")
        let pillExpect = HUDPointerPlacement.origin(pointer: point, size: f.size, scale: 1.0,
                                                    screens: screens, fallback: 0)
        check("pill-follows-pointer",
              approx(f.origin.x, pillExpect.x) && approx(f.origin.y, pillExpect.y),
              "origin=\(f.origin) expect≈\(pillExpect) (equals HUDPointerPlacement.origin(...) for the provider pointer)")

        // Item A: the scope spans the FULL pill width (x≈0, width≈pill width).
        var wf = hud.pillWaveFrameForTesting
        check("pill-scope-full-width",
              approx(wf.origin.x, 0) && approx(wf.width, 300),
              "waveFrame=\(wf) expect x≈0, width≈300")

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
        // Router status toasts use the default non-forced path. Pin that exact path renders in the pill
        // so a current-mode refresh cannot silently collapse back to an always-full presentation.
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .bottomCenter
        let fullBoxW = min(1080, vf.width - 80)
        let message = "🔒 Private vault files are refused."

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
        Settings.hudScale = 1.0
        Settings.hudPillScale = 1.0
        Settings.hudPosition = .topRight            // toasts still home here; the scope follows the pointer

        let point = NSPoint(x: vf.minX + 400, y: vf.maxY - 200)
        let screens = [HUDPointerPlacement.Screen(frame: vf, visible: vf)]
        hud.pointerProviderForTesting = { point }
        hud.screensProviderForTesting = { screens }

        hud.hide()
        hud.setCleanup(enabled: false, level: 0)
        hud.setTakeActive(false)
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()                                  // the low-power scope pill is up, wave running
        let scopeBefore = hud.frameForTesting
        let scopeExpected = HUDPointerPlacement.origin(pointer: point, size: scopeBefore.size,
                                                       scale: 1.0, screens: screens, fallback: 0)
        check("revert-scope-at-pointer-before-toast",
              approx(scopeBefore.minX, scopeExpected.x) && approx(scopeBefore.minY, scopeExpected.y),
              "origin=\(scopeBefore.origin) expect≈\(scopeExpected) (HUDPointerPlacement.origin(...))")
        check("revert-scope-up-before-toast",
              hud.panelVisibleForTesting && hud.pillWaveActiveForTesting && approx(scopeBefore.width, 300),
              "visible=\(hud.panelVisibleForTesting) wave=\(hud.pillWaveActiveForTesting) w=\(scopeBefore.width)")

        hud.setTakeActive(true)                     // the take is live
        hud.toast(NotesBullseyeLogic.setToast, duration: 0.2)         // the exact mid-take confirmation toast
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))   // mid-dwell: the toast is up, scope stopped
        let toastDuring = hud.frameForTesting
        let toastHome = Settings.hudPosition.origin(for: toastDuring.size, in: vf)
        check("revert-toast-at-home-during-toast",
              approx(toastDuring.minX, toastHome.x) && approx(toastDuring.minY, toastHome.y),
              "origin=\(toastDuring.origin) expect home=\(toastHome) (toast placement unchanged)")
        check("revert-toast-stops-scope-mid-dwell", !hud.pillWaveActiveForTesting,
              "wave=\(hud.pillWaveActiveForTesting) expect false (scope stopped for the toast dwell)")

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))   // the dwell timer fires dismissToast()
        let scopeAfter = hud.frameForTesting
        check("revert-scope-onscreen-after-dwell", hud.panelVisibleForTesting,
              "visible=\(hud.panelVisibleForTesting) expect true (HUD must NOT order out mid-take)")
        check("revert-wave-active-after-dwell", hud.pillWaveActiveForTesting,
              "wave=\(hud.pillWaveActiveForTesting) expect true (oscilloscope back)")
        check("revert-scope-at-pointer-after-dwell",
              approx(scopeAfter.minX, scopeExpected.x) && approx(scopeAfter.minY, scopeExpected.y),
              "origin=\(scopeAfter.origin) expect≈\(scopeExpected) (back at the pointer)")
        check("revert-is-scope-pill", approx(scopeAfter.width, 300) && frameEq(scopeAfter, scopeBefore),
              "after=\(scopeAfter) before=\(scopeBefore) expect the 300x64 scope pill back in place")

        // With NO take live, a toast over a scope pill must still re-home the toast and then hide it.
        hud.setTakeActive(false)
        hud.update(state: "Listening…", target: "probe", text: "", locked: false)
        hud.show()
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

    private static func probePointerFollow(_ hud: HUDPanel, visibleFrame vf: NSRect) {
        // 8) VDCURB1: the scope pill and the thinking ring follow the pointer (30 Hz), the info pill
        //    rides with them, and a toast keeps the fixed home. Two screens are described through the
        //    screen seam so "uses the pointer's screen, not NSScreen.main" is assertable on one display.
        let oneScreen = [HUDPointerPlacement.Screen(frame: vf, visible: vf)]
        let ringScale = CGFloat(Settings.hudSpinnerScale)

        // 8a) A moved pointer moves the pill.
        hud.hide()
        Settings.hudPillScale = 1.0
        hud.screensProviderForTesting = { oneScreen }
        let a = NSPoint(x: vf.minX + 300, y: vf.maxY - 300)
        let b = NSPoint(x: a.x + 120, y: a.y - 120)
        hud.pointerProviderForTesting = { a }
        hud.show()
        hud.followTickForTesting()
        hud.pointerProviderForTesting = { b }
        hud.followTickForTesting()
        var f = hud.frameForTesting
        var expected = HUDPointerPlacement.origin(pointer: b, size: f.size, scale: 1.0,
                                                 screens: oneScreen, fallback: 0)
        check("pill-tracks-pointer-move",
              approx(f.origin.x, expected.x) && approx(f.origin.y, expected.y),
              "origin=\(f.origin) expect≈\(expected)")

        // 8b) The thinking ring follows too, at the spinner scale.
        hud.hide()
        hud.setThinking(true)
        let c = NSPoint(x: vf.minX + 260, y: vf.maxY - 260)
        let d = NSPoint(x: c.x + 140, y: c.y - 140)
        hud.pointerProviderForTesting = { c }
        hud.followTickForTesting()
        hud.pointerProviderForTesting = { d }
        hud.followTickForTesting()
        f = hud.frameForTesting
        expected = HUDPointerPlacement.origin(pointer: d, size: f.size, scale: ringScale,
                                             screens: oneScreen, fallback: 0)
        check("thinking-tracks-pointer-move",
              approx(f.origin.x, expected.x) && approx(f.origin.y, expected.y),
              "origin=\(f.origin) expect≈\(expected) ringScale=\(ringScale)")
        hud.setThinking(false)

        // 8c) On a second screen the pill goes there — it is NOT clamped back to NSScreen.main.
        hud.hide()
        Settings.hudPillScale = 1.0
        let second = NSRect(x: vf.maxX, y: vf.minY, width: vf.width, height: vf.height)
        let twoScreens = [HUDPointerPlacement.Screen(frame: vf, visible: vf),
                          HUDPointerPlacement.Screen(frame: second, visible: second)]
        hud.screensProviderForTesting = { twoScreens }
        hud.pointerProviderForTesting = { NSPoint(x: vf.maxX + 200, y: vf.maxY - 200) }
        hud.show()
        f = hud.frameForTesting
        check("pill-not-clamped-to-main-screen",
              f.minX >= second.minX - 1.5 && f.maxX <= second.maxX + 1.5
                  && f.minY >= second.minY - 1.5 && f.maxY <= second.maxY + 1.5,
              "frame=\(f) expect inside second visible=\(second)")

        // 8d) A plain toast does NOT follow: a tick leaves it exactly where it was.
        hud.hide()
        hud.screensProviderForTesting = { oneScreen }
        hud.pointerProviderForTesting = { NSPoint(x: vf.minX + 300, y: vf.maxY - 300) }
        hud.toast("probe", duration: 10)
        let toastBefore = hud.frameForTesting
        hud.pointerProviderForTesting = { NSPoint(x: vf.minX + 700, y: vf.maxY - 500) }
        hud.followTickForTesting()
        check("toast-does-not-follow-pointer", frameEq(hud.frameForTesting, toastBefore),
              "frame=\(hud.frameForTesting) expect unchanged=\(toastBefore)")
        hud.hide()   // hide() also invalidates the still-pending toast timer

        // 8e) The follow timer's lifecycle: exactly one, 30 Hz, only while a following mode is shown.
        hud.hide()
        hud.screensProviderForTesting = { oneScreen }
        hud.pointerProviderForTesting = { NSPoint(x: vf.minX + 300, y: vf.maxY - 300) }
        hud.setTakeActive(false)
        hud.show()
        let activeAfterShow = hud.followTimerIsActiveForTesting
        let interval = hud.followTimerIntervalForTesting
        var lifecycleOK = activeAfterShow
            && (interval.map { abs($0 - 1.0 / 30) <= 1e-6 } ?? false)
        hud.show()
        lifecycleOK = lifecycleOK && hud.followTimerIsActiveForTesting
        hud.hide()
        lifecycleOK = lifecycleOK && !hud.followTimerIsActiveForTesting
        hud.setThinking(true)
        lifecycleOK = lifecycleOK && hud.followTimerIsActiveForTesting
        hud.setThinking(false)
        hud.toast("probe", duration: 10)
        lifecycleOK = lifecycleOK && !hud.followTimerIsActiveForTesting
        check("pill-follow-timer-lifecycle", lifecycleOK,
              "show=\(activeAfterShow) interval=\(String(describing: interval)) final=\(hud.followTimerIsActiveForTesting)")
        hud.hide()

        // 8f) The 30 Hz loop moves the pill with NO manual tick: change the provider, pump the runloop.
        hud.hide()
        hud.screensProviderForTesting = { oneScreen }
        Settings.hudPillScale = 1.0
        let pa = NSPoint(x: vf.minX + 200, y: vf.maxY - 200)
        let pb = NSPoint(x: pa.x + 100, y: pa.y - 100)
        hud.pointerProviderForTesting = { pa }
        hud.show()
        f = hud.frameForTesting
        let targetA = HUDPointerPlacement.origin(pointer: pa, size: f.size, scale: 1.0,
                                                 screens: oneScreen, fallback: 0)
        let startsAtA = approx(f.origin.x, targetA.x) && approx(f.origin.y, targetA.y)
        hud.pointerProviderForTesting = { pb }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        f = hud.frameForTesting
        let targetB = HUDPointerPlacement.origin(pointer: pb, size: f.size, scale: 1.0,
                                                 screens: oneScreen, fallback: 0)
        let endsAtB = approx(f.origin.x, targetB.x) && approx(f.origin.y, targetB.y)
        let targetsDiffer = abs(targetB.x - targetA.x) >= 50 && abs(targetB.y - targetA.y) >= 50
        let leftA = !(approx(f.origin.x, targetA.x) && approx(f.origin.y, targetA.y))
        check("pill-follows-without-manual-tick", startsAtA && endsAtB && targetsDiffer && leftA,
              "start=\(startsAtA) atA=\(targetA) end=\(f.origin) atB=\(targetB) differs=\(targetsDiffer)")

        hud.hide()
        hud.pointerProviderForTesting = nil
        hud.screensProviderForTesting = nil
    }
}
