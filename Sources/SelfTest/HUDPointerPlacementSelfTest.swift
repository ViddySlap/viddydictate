import Foundation

/// Pure coverage for `HUDPointerPlacement` (VDCURB1): the recording pill's top-left corner sits
/// `offset * scale` right of and below the pointer tip, flips left at the pointer screen's right
/// edge, flips above its bottom edge, and is finally clamped inside that screen's visible frame.
/// Screen selection handles seams (fallback wins) and a pointer off every screen (nearest wins,
/// lower index on a tie).
enum HUDPointerPlacementSelfTest {
    static func run(_ reporter: SelfTestReporter) {
        print("--- HUD pointer placement ---")
        let oneScreen = [HUDPointerPlacement.Screen(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visible: NSRect(x: 0, y: 0, width: 1440, height: 900))]
        let size = NSSize(width: 300, height: 64)

        // 1. The base offset: 18 right of and 18 below the tip (AppKit y grows upward).
        let plain = HUDPointerPlacement.origin(pointer: NSPoint(x: 400, y: 500), size: size,
                                               scale: 1, screens: oneScreen, fallback: 0)
        reporter.record("pointer: pill sits 18 right of and 18 below the pointer",
                        plain == NSPoint(x: 418, y: 418))

        // 2. Pointer 80 from the right edge: the capsule would overflow, so it flips to the LEFT.
        let rightEdge = HUDPointerPlacement.origin(pointer: NSPoint(x: 1440 - 80, y: 500), size: size,
                                                   scale: 1, screens: oneScreen, fallback: 0)
        reporter.record("pointer: flips left at the right screen edge",
                        rightEdge.x == 1360 - 18 - 300)

        // 3. Pointer 30 above the bottom edge: it would hang off, so it flips ABOVE the tip.
        let bottomEdge = HUDPointerPlacement.origin(pointer: NSPoint(x: 400, y: 30), size: size,
                                                    scale: 1, screens: oneScreen, fallback: 0)
        reporter.record("pointer: flips above at the bottom screen edge",
                        bottomEdge.y == 30 + 18)

        // 4. The final clamp: a short visible band (y 40...120) means the flipped result (718, 68)
        //    would put the capsule's top at 132, above visible.maxY. It must clamp to 56 and stay inside.
        let band = [HUDPointerPlacement.Screen(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visible: NSRect(x: 0, y: 40, width: 1440, height: 80))]
        let clamped = HUDPointerPlacement.origin(pointer: NSPoint(x: 700, y: 50), size: size,
                                                 scale: 1, screens: band, fallback: 0)
        let clampedRect = NSRect(origin: clamped, size: size)
        reporter.record("pointer: clamps inside the visible frame",
                        clamped == NSPoint(x: 718, y: 56)
                            && band[0].visible.contains(clampedRect))

        // 5. Two screens side by side: a pointer on the second screen places the capsule there.
        let twoScreens = [
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 0, y: 0, width: 1440, height: 900)),
            HUDPointerPlacement.Screen(frame: NSRect(x: 1440, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 1440, y: 0, width: 1440, height: 900)),
        ]
        let onSecond = HUDPointerPlacement.origin(pointer: NSPoint(x: 2000, y: 500), size: size,
                                                  scale: 1, screens: twoScreens, fallback: 0)
        reporter.record("pointer: uses the screen under the pointer on two screens",
                        onSecond == NSPoint(x: 2018, y: 418))

        // 6. A seam: two frames that overlap contain the pointer, so the fallback screen wins.
        let overlapping = [
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 0, y: 0, width: 1440, height: 900)),
            HUDPointerPlacement.Screen(frame: NSRect(x: 1000, y: 0, width: 1440, height: 900),
                                       visible: NSRect(x: 1000, y: 0, width: 1440, height: 900)),
        ]
        let seam = NSPoint(x: 1200, y: 500)
        reporter.record("pointer: a seam prefers the fallback screen",
                        HUDPointerPlacement.screenIndex(for: seam, in: overlapping, fallback: 1) == 1
                            && HUDPointerPlacement.screenIndex(for: seam, in: overlapping, fallback: 0) == 0)

        // 7. Off every screen: nearest frame wins, and an equidistant point takes the lower index.
        let apart = [
            HUDPointerPlacement.Screen(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                       visible: NSRect(x: 0, y: 0, width: 100, height: 100)),
            HUDPointerPlacement.Screen(frame: NSRect(x: 200, y: 0, width: 100, height: 100),
                                       visible: NSRect(x: 200, y: 0, width: 100, height: 100)),
        ]
        reporter.record("pointer: off every screen takes the nearest",
                        HUDPointerPlacement.screenIndex(for: NSPoint(x: 120, y: 50),
                                                        in: apart, fallback: 0) == 0
                            && HUDPointerPlacement.screenIndex(for: NSPoint(x: 150, y: 50),
                                                               in: apart, fallback: 1) == 0)

        // 8. The offset is multiplied by the scale: 18 * 1.5 = 27.
        let scaled = HUDPointerPlacement.origin(pointer: NSPoint(x: 400, y: 500), size: size,
                                                scale: 1.5, screens: oneScreen, fallback: 0)
        reporter.record("pointer: scale scales the offset",
                        scaled == NSPoint(x: 400 + 27, y: 500 - 27 - 64))

        // 9. No screens at all: the plain offset, unclamped and unflipped.
        let noScreens = HUDPointerPlacement.origin(pointer: NSPoint(x: 400, y: 500), size: size,
                                                   scale: 1, screens: [], fallback: 0)
        reporter.record("pointer: no screens gives the unclamped offset",
                        noScreens == NSPoint(x: 418, y: 418))

        // VDCURB2: the trailing toast moves a fifth of the way each step and snaps within half a point.
        let stepFifth = HUDPointerPlacement.trailStep(current: NSPoint(x: 0, y: 0),
                                                      target: NSPoint(x: 100, y: 40))
        reporter.record("trail: steps a fifth of the way toward the target",
                        abs(stepFifth.x - 20) <= 1e-9 && abs(stepFifth.y - 8) <= 1e-9)

        let snap = HUDPointerPlacement.trailStep(current: NSPoint(x: 99.7, y: 39.8),
                                                 target: NSPoint(x: 100, y: 40))
        reporter.record("trail: snaps to the target within half a point",
                        snap == NSPoint(x: 100, y: 40))

        let noSnap = HUDPointerPlacement.trailStep(current: NSPoint(x: 0, y: 0),
                                                   target: NSPoint(x: 3, y: 0))
        reporter.record("trail: does not snap beyond half a point",
                        abs(noSnap.x - 1) <= 1e-9 && noSnap.y == 0 && noSnap != NSPoint(x: 3, y: 0))

        var cur = NSPoint(x: 0, y: 0)
        let finalTarget = NSPoint(x: 300, y: -200)
        var lastDX = abs(finalTarget.x - cur.x)
        var lastDY = abs(finalTarget.y - cur.y)
        var converges = true
        for _ in 0..<80 {
            let next = HUDPointerPlacement.trailStep(current: cur, target: finalTarget)
            let dx = abs(finalTarget.x - next.x)
            let dy = abs(finalTarget.y - next.y)
            if dx > lastDX || dy > lastDY { converges = false }
            lastDX = dx
            lastDY = dy
            cur = next
        }
        reporter.record("trail: converges to the target and never overshoots",
                        converges && cur == finalTarget)

        let parked = NSPoint(x: 42, y: -17)
        reporter.record("trail: a point already at the target stays put",
                        HUDPointerPlacement.trailStep(current: parked, target: parked) == parked)

        let small = HUDPointerPlacement.trailStep(current: NSPoint(x: 0, y: 0), target: NSPoint(x: 4, y: -3))
        let capped = HUDPointerPlacement.trailStep(current: NSPoint(x: 0, y: 0), target: NSPoint(x: 0.8, y: 0))
        reporter.record("trail: a small gap moves a point per step and never overshoots",
                        abs(small.x - 1) <= 1e-9 && abs(small.y + 1) <= 1e-9 && capped == NSPoint(x: 0.8, y: 0))

        var gapFour = NSPoint(x: 914, y: 402)
        var gapFourSteps = 0
        while gapFour != NSPoint(x: 918, y: 402) && gapFourSteps < 10 {
            gapFour = HUDPointerPlacement.trailStep(current: gapFour, target: NSPoint(x: 918, y: 402))
            gapFourSteps += 1
        }
        reporter.record("trail: a gap of four points arrives in at most four steps",
                        gapFour == NSPoint(x: 918, y: 402) && gapFourSteps <= 4)

        func wholePointWalk(_ quantize: (CGFloat) -> CGFloat) -> Bool {
            let goal = NSPoint(x: 918, y: 402)
            var at = NSPoint(x: 518, y: 702)
            var steps = 0
            while at != goal && steps < 200 {
                let next = HUDPointerPlacement.trailStep(current: at, target: goal)
                at = NSPoint(x: quantize(next.x), y: quantize(next.y))
                steps += 1
            }
            return at == goal
        }
        reporter.record("trail: a whole-point walk still arrives",
                        wholePointWalk({ $0.rounded(.down) }) && wholePointWalk({ $0.rounded() }))
    }
}
