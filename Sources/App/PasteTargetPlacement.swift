import Foundation

/// Pure geometry for the paste-target bullseye (VDCURC): where the blinking marker disc sits for a
/// given focus snapshot, pointer, and screen list. Deliberately free of AppKit views and the
/// Accessibility APIs, so the placement rules can be proven as pure self-test rows.
enum PasteTargetPlacement {
    static let diameterBase: CGFloat = 14
    static let blinkPeriod: TimeInterval = 1.0
    static let blinkDimAlpha: CGFloat = 0.25

    enum Kind: Equatable { case caret, element, pointer }

    struct Focus {
        var caret: NSRect?     // Accessibility space: origin top-left of the primary screen, y grows DOWN
        var element: NSRect?   // same space
        var isTarget: Bool     // the focused element would receive the paste
    }

    struct Result: Equatable { let center: NSPoint; let kind: Kind }   // AppKit space: y grows UP

    static func appKitRect(fromAX r: NSRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.size.height, width: r.size.width, height: r.size.height)
    }

    private static func isFiniteRect(_ r: NSRect) -> Bool {
        r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite
    }

    static func place(focus: Focus?, pointer: NSPoint, screens: [HUDPointerPlacement.Screen], primaryHeight: CGFloat) -> Result {
        guard let focus = focus, focus.isTarget else {
            return Result(center: pointer, kind: .pointer)
        }
        if let caret = focus.caret {
            let rect = appKitRect(fromAX: caret, primaryHeight: primaryHeight)
            let point = NSPoint(x: rect.minX, y: rect.midY)
            if isFiniteRect(rect), rect.height > 0, rect.width >= 0,
               screens.contains(where: { $0.frame.contains(point) }) {
                return Result(center: point, kind: .caret)
            }
        }
        if let element = focus.element {
            let rect = appKitRect(fromAX: element, primaryHeight: primaryHeight)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            if isFiniteRect(rect), rect.width > 0, rect.height > 0,
               screens.contains(where: { $0.frame.contains(point) }) {
                return Result(center: point, kind: .element)
            }
        }
        return Result(center: pointer, kind: .pointer)
    }

    static func windowOrigin(center: NSPoint, diameter: CGFloat, screens: [HUDPointerPlacement.Screen], fallback: Int) -> NSPoint {
        let d = diameter
        guard let index = HUDPointerPlacement.screenIndex(for: center, in: screens, fallback: fallback) else {
            return NSPoint(x: center.x - d / 2, y: center.y - d / 2)
        }
        let v = screens[index].visible
        let x = min(max(center.x - d / 2, v.minX), max(v.minX, v.maxX - d))
        let y = min(max(center.y - d / 2, v.minY), max(v.minY, v.maxY - d))
        return NSPoint(x: x, y: y)
    }

    static func diameter(scale: Double) -> CGFloat {
        round(diameterBase * CGFloat(scale))
    }

    static func blinkAlpha(elapsed: TimeInterval) -> CGFloat {
        let t = elapsed - blinkPeriod * floor(elapsed / blinkPeriod)
        return t < blinkPeriod / 2 ? 1.0 : blinkDimAlpha
    }
}
