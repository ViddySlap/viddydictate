import Foundation

/// Pure coverage for `PasteTargetPlacement` (VDCURC): the Accessibility-space -> AppKit-space flip,
/// caret-over-element preference, element-middle and pointer fallbacks, per-screen placement, window
/// centering and clamping, size scaling, and the blink phase.
enum PasteTargetPlacementSelfTest {
    static func run(_ reporter: SelfTestReporter) {
        print("--- paste target placement ---")
        let primaryHeight: CGFloat = 900
        let oneScreen = [HUDPointerPlacement.Screen(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visible: NSRect(x: 0, y: 0, width: 1440, height: 875))]
        let pointer = NSPoint(x: 50, y: 60)

        let caretA = NSRect(x: 300, y: 200, width: 2, height: 18)
        let elementA = NSRect(x: 100, y: 100, width: 600, height: 400)
        let elementZero = NSRect(x: 100, y: 100, width: 0, height: 0)
        let caretOff = NSRect(x: 5000, y: 200, width: 2, height: 18)
        let elementOff = NSRect(x: 5000, y: 100, width: 600, height: 400)

        func focus(caret: NSRect?, element: NSRect?, isTarget: Bool) -> PasteTargetPlacement.Focus {
            PasteTargetPlacement.Focus(caret: caret, element: element, isTarget: isTarget)
        }

        // 1. A caret is centered on its left edge after the Accessibility flip.
        let r1 = PasteTargetPlacement.place(focus: focus(caret: caretA, element: nil, isTarget: true),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: a caret is centered on its left edge after the Accessibility flip",
                        r1.center == NSPoint(x: 300, y: 691) && r1.kind == .caret)

        // 2. The caret wins over the element.
        let r2 = PasteTargetPlacement.place(focus: focus(caret: caretA, element: elementA, isTarget: true),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: the caret wins over the element",
                        r2.center == NSPoint(x: 300, y: 691) && r2.kind == .caret)

        // 3. An element with no caret is marked at its middle.
        let r3 = PasteTargetPlacement.place(focus: focus(caret: nil, element: elementA, isTarget: true),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: an element with no caret is marked at its middle",
                        r3.center == NSPoint(x: 400, y: 600) && r3.kind == .element)

        // 4. An element with no size falls back to the pointer.
        let r4 = PasteTargetPlacement.place(focus: focus(caret: nil, element: elementZero, isTarget: true),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: an element with no size falls back to the pointer",
                        r4.center == NSPoint(x: 50, y: 60) && r4.kind == .pointer)

        // 5. No focus means the pointer tip.
        let r5 = PasteTargetPlacement.place(focus: nil,
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: no focus means the pointer tip",
                        r5.center == NSPoint(x: 50, y: 60) && r5.kind == .pointer)

        // 6. A focus that is not a paste target means the pointer tip.
        let r6 = PasteTargetPlacement.place(focus: focus(caret: caretA, element: elementA, isTarget: false),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: a focus that is not a paste target means the pointer tip",
                        r6.center == NSPoint(x: 50, y: 60) && r6.kind == .pointer)

        // 7. A caret off every screen falls through to the element.
        let r7 = PasteTargetPlacement.place(focus: focus(caret: caretOff, element: elementA, isTarget: true),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: a caret off every screen falls through to the element",
                        r7.center == NSPoint(x: 400, y: 600) && r7.kind == .element)

        // 8. A caret and element off every screen fall through to the pointer.
        let r8 = PasteTargetPlacement.place(focus: focus(caret: caretOff, element: elementOff, isTarget: true),
                                            pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: a caret and element off every screen fall through to the pointer",
                        r8.center == NSPoint(x: 50, y: 60) && r8.kind == .pointer)

        // 9. A screen above the primary one flips to a y above the primary height.
        let upperScreens = [
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 0, y: 0, width: 1440, height: 900)),
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 900, width: 1440, height: 900),
                                       visible: NSRect(x: 0, y: 900, width: 1440, height: 900)),
        ]
        let upperCaret = NSRect(x: 300, y: -500, width: 2, height: 18)
        let r9 = PasteTargetPlacement.place(focus: focus(caret: upperCaret, element: nil, isTarget: true),
                                            pointer: pointer, screens: upperScreens, primaryHeight: primaryHeight)
        reporter.record("paste target: a screen above the primary one flips to a y above the primary height",
                        r9.center == NSPoint(x: 300, y: 1391) && r9.kind == .caret)

        // 10. A screen left of the primary one keeps its negative x.
        let leftScreens = [
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 0, y: 0, width: 1440, height: 900)),
            HUDPointerPlacement.Screen(frame: NSRect(x: -1440, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: -1440, y: 0, width: 1440, height: 900)),
        ]
        let leftCaret = NSRect(x: -700, y: 200, width: 2, height: 18)
        let r10 = PasteTargetPlacement.place(focus: focus(caret: leftCaret, element: nil, isTarget: true),
                                             pointer: pointer, screens: leftScreens, primaryHeight: primaryHeight)
        reporter.record("paste target: a screen left of the primary one keeps its negative x",
                        r10.center == NSPoint(x: -700, y: 691) && r10.kind == .caret)

        // 11. The window origin centers the disc on the point.
        reporter.record("paste target: the window origin centers the disc on the point",
                        PasteTargetPlacement.windowOrigin(center: NSPoint(x: 400, y: 600), diameter: 14,
                                                          screens: oneScreen, fallback: 0) == NSPoint(x: 393, y: 593))

        // 12. The window origin clamps inside the visible frame (center in the menu-bar band).
        reporter.record("paste target: the window origin clamps inside the visible frame",
                        PasteTargetPlacement.windowOrigin(center: NSPoint(x: 400, y: 880), diameter: 14,
                                                          screens: oneScreen, fallback: 0) == NSPoint(x: 393, y: 861))

        // 13. The window origin clamps on the screen under the point.
        let sideScreens = [
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 0, y: 0, width: 1440, height: 900)),
            HUDPointerPlacement.Screen(frame: NSRect(x: 1440, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 1440, y: 0, width: 1440, height: 900)),
        ]
        reporter.record("paste target: the window origin clamps on the screen under the point",
                        PasteTargetPlacement.windowOrigin(center: NSPoint(x: 2878, y: 450), diameter: 14,
                                                          screens: sideScreens, fallback: 0) == NSPoint(x: 2866, y: 443))

        // 14. The disc scales with the UI size.
        reporter.record("paste target: the disc scales with the UI size",
                        PasteTargetPlacement.diameter(scale: 1.0) == 14
                            && PasteTargetPlacement.diameter(scale: 0.7) == 10
                            && PasteTargetPlacement.diameter(scale: 1.6) == 22)

        // 15. The blink is bright for the first half and dim for the second.
        reporter.record("paste target: the blink is bright for the first half and dim for the second",
                        PasteTargetPlacement.blinkAlpha(elapsed: 0) == 1
                            && PasteTargetPlacement.blinkAlpha(elapsed: 0.49) == 1
                            && PasteTargetPlacement.blinkAlpha(elapsed: 0.5) == 0.25
                            && PasteTargetPlacement.blinkAlpha(elapsed: 0.99) == 0.25
                            && PasteTargetPlacement.blinkAlpha(elapsed: 1.0) == 1
                            && PasteTargetPlacement.blinkAlpha(elapsed: 2.6) == 0.25)

        // 16. A non-finite caret is skipped (only the finite test rejects it).
        let infiniteCaret = NSRect(x: 300, y: 200, width: CGFloat.infinity, height: 18)
        let r16 = PasteTargetPlacement.place(focus: focus(caret: infiniteCaret, element: elementA, isTarget: true),
                                             pointer: pointer, screens: oneScreen, primaryHeight: primaryHeight)
        reporter.record("paste target: a non-finite caret is skipped",
                        r16.center == NSPoint(x: 400, y: 600) && r16.kind == .element)
    }
}
