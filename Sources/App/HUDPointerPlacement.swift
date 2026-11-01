import Foundation

/// Pure geometry for the pointer-following HUD (VDCURB1): where the recording scope pill and the
/// post-release thinking ring should be placed for a given pointer, panel size, and screen list.
///
/// Deliberately free of AppKit views: `Foundation` already vends `NSPoint`/`NSSize`/`NSRect`/
/// `CGFloat` on macOS, and keeping `NSScreen`/`NSEvent` out of here is what lets the placement rules
/// be exercised as a pure self-test row instead of only through a GUI probe.
enum HUDPointerPlacement {
    /// A screen as the placement rules need it: the full `frame` (for hit-testing the pointer) and
    /// the `visible` frame (for the final clamp, so the panel never hides under the menu bar/dock).
    struct Screen {
        let frame: NSRect
        let visible: NSRect
    }

    /// The capsule's top-left corner sits this far right of and below the pointer tip, times the
    /// pill's (or ring's) own scale.
    static let offset: CGFloat = 18

    /// The screen whose frame contains `pointer`. A seam (a point inside two frames) prefers `fallback`
    /// when `fallback` is one of those frames. A pointer outside every screen takes the nearest frame,
    /// measured as the Euclidean distance from the point to the rectangle; ties take the lower index.
    static func screenIndex(for pointer: NSPoint, in screens: [Screen], fallback: Int) -> Int? {
        guard !screens.isEmpty else { return nil }
        if fallback >= 0, fallback < screens.count, screens[fallback].frame.contains(pointer) {
            return fallback
        }
        if let first = screens.firstIndex(where: { $0.frame.contains(pointer) }) {
            return first
        }
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, screen) in screens.enumerated() {
            let distance = distanceToRect(pointer, screen.frame)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Where the panel's origin goes for this pointer/size/scale: `offset * scale` right of and below
    /// the tip, flipping left at the pointer screen's right edge and above at its bottom edge, then
    /// clamped inside that screen's visible frame. With no screens at all the unclamped offset is
    /// returned (the rules only apply once a screen is known).
    static func origin(pointer: NSPoint, size: NSSize, scale: CGFloat,
                       screens: [Screen], fallback: Int) -> NSPoint {
        let d = offset * scale
        guard let index = screenIndex(for: pointer, in: screens, fallback: fallback) else {
            return NSPoint(x: pointer.x + d, y: pointer.y - d - size.height)
        }
        let visible = screens[index].visible
        var x = pointer.x + d
        var y = pointer.y - d - size.height
        // AppKit y grows upward, so the capsule hangs BELOW the tip; "below the bottom edge" is a
        // flip to ABOVE the tip.
        if x + size.width > visible.maxX { x = pointer.x - d - size.width }
        if y < visible.minY { y = pointer.y + d }
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return NSPoint(x: x, y: y)
    }

    /// Euclidean distance from a point to a rectangle: 0 inside, otherwise the distance to the
    /// nearest edge (axis deltas combined).
    private static func distanceToRect(_ point: NSPoint, _ rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        return (dx * dx + dy * dy).squareRoot()
    }
}
