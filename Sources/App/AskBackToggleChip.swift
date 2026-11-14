import Cocoa

// BEGIN askback-chip-rules
/// VDASK-5 repair round 1 (M1): where the info pill's clickable ? chip sits. Pure geometry, Foundation only.
/// `placement` is nil exactly when the info pill is not shown; then the chip is not shown either.
struct AskBackChipPlacement: Equatable {
    /// The info pill's capsule frame (screen coordinates, final size, animation aside).
    let capsule: CGRect
    /// The visible frame of the screen the pill is on.
    let visible: CGRect
    /// True when the pill sits to the right of the scope pill, so the chip goes after the level word at the
    /// capsule's right end. False (pill on the scope's left): the right end touches the scope pill, so the
    /// chip goes on the capsule's left end instead of covering the scope.
    let onRight: Bool
}

enum AskBackChipRules {
    /// Points between the capsule's edge and the chip.
    static let gap: CGFloat = 4
    /// VDASK-5 repair round 2 (M1): the pointer-to-chip halo that freezes the row so the ? can be reached.
    static let holdRadius: CGFloat = 40

    /// The chip's frame, or nil (hidden) when the info pill is not shown. Vertically centred on the capsule and
    /// kept inside the screen's visible frame.
    static func frame(for placement: AskBackChipPlacement?, size: CGSize) -> CGRect? {
        guard let p = placement else { return nil }
        var x = p.onRight ? p.capsule.maxX + gap : p.capsule.minX - gap - size.width
        x = max(p.visible.minX, min(x, p.visible.maxX - size.width))
        return CGRect(x: x, y: p.capsule.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Euclidean distance from a point to a rectangle: 0 inside, otherwise the distance to the nearest edge.
    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// VDASK-5 repair round 2 (M1): the row-freeze latch. The scope, info pill and chip move as one rigid group
/// with the pointer, so a pointer moving toward the visible chip would otherwise chase it forever. While the
/// pointer is on or within `AskBackChipRules.holdRadius` of the real chip frame, the latch keeps the group
/// still. A pointer outside the halo that keeps moving toward it also starts a short approach hold (without
/// that, the group's own translation would keep the halo out of reach); the approach hold becomes the normal
/// halo hold once the pointer arrives, or ends if the pointer turns away. `reset()` is called on hide and on
/// every display-mode change, so a stale hold can never survive a toast, the thinking spinner or a new take.
struct AskBackChipHold: Equatable {
    private(set) var isHolding = false
    /// True while the hold exists only to let an outside pointer finish its approach into the halo. Such a
    /// hold is kept while the pointer keeps closing on the chip or stops, and released the moment it turns
    /// away; a normal (inside-the-halo) hold instead releases only after the pointer leaves the halo.
    private var approaching = false
    /// Consecutive ticks that moved toward the chip. Two ticks (about 66 ms at 30 Hz) distinguish a deliberate
    /// approach from a single programmatic reposition (a probe, a one-tick jump) that must keep following.
    private var approachTicks = 0

    mutating func update(pointer: CGPoint, previousPointer: CGPoint?, chip: CGRect?) -> Bool {
        guard let chip, !chip.isNull, !chip.isEmpty else {
            reset()
            return false
        }
        let now = AskBackChipRules.distance(from: pointer, to: chip)
        let before = previousPointer.map { AskBackChipRules.distance(from: $0, to: chip) }
        if isHolding {
            if now <= AskBackChipRules.holdRadius {
                approaching = false
            } else if approaching {
                // Freeze was started from outside the halo: keep it while the pointer closes in or holds
                // still, and release as soon as it turns away (the normal follow path then resumes).
                if let before, now > before + 0.5 { reset() }
            } else {
                reset()
            }
        } else if now <= AskBackChipRules.holdRadius {
            isHolding = true
            approaching = false
            approachTicks = 0
        } else if let before, now < before {
            // Moving into the halo: freeze before the next re-anchor can move the chip away again. Requiring a
            // second consecutive approach tick keeps a single one-tick move (existing follow rows, a test's
            // one-shot reposition) on the normal follow path.
            approachTicks += 1
            if approachTicks >= 2 {
                isHolding = true
                approaching = true
                approachTicks = 0
            }
        } else {
            approachTicks = 0
        }
        return isHolding
    }

    mutating func reset() {
        isHolding = false
        approaching = false
        approachTicks = 0
    }
}
// END askback-chip-rules

/// VDASK-5 repair round 1 (M1): the ? button beside the compact info pill, so ask-back can be switched while a
/// take is recording. The info pill's own panel is passive (it ignores the mouse), and Lock and Stop only show in
/// full-box toasts, so this is a small panel of its own. It takes clicks the way `AskCardPanel` does: a
/// non-activating panel that never becomes key, holding a button that refuses first responder, so the paste
/// target keeps focus and the caret. It lives in its own file (not HUDPanel.swift) because it is a separate
/// window with its own lifetime. The button is the same `AskBackToggleButton` as the full-box ?, fed the same
/// `AskBackToggleState` by the same HUD call, so the looks, tooltips and click rule are one set of code. A click
/// only reports through `onClick`; the controller flips the setting and never starts, ends or cancels a take.
final class AskBackToggleChip: NSObject {
    private final class ChipWindow: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    var onClick: (() -> Void)?
    private let panel: NSPanel
    private let container = NSView()
    private let button = AskBackToggleButton()
    /// Room for the button's 7-pt phosphor glow (S2): the window is larger than the button and clear around it,
    /// so the rounded window edge cannot clip the glow the full-box ? shows.
    private static let glowPadding: CGFloat = 8

    override init() {
        panel = ChipWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Phosphor.configureFloatingPanel(panel)
        panel.hasShadow = false
        panel.ignoresMouseEvents = false        // unlike the info pill: this one is clickable
        panel.becomesKeyOnlyIfNeeded = true
        let buttonSize = button.intrinsicContentSize
        let panelSize = NSSize(width: buttonSize.width + 2 * Self.glowPadding,
                               height: buttonSize.height + 2 * Self.glowPadding)
        panel.setContentSize(panelSize)
        container.frame = NSRect(origin: .zero, size: panelSize)
        button.frame = NSRect(x: Self.glowPadding, y: Self.glowPadding,
                              width: buttonSize.width, height: buttonSize.height)
        button.target = self
        button.action = #selector(clicked)
        container.addSubview(button)
        panel.contentView = container
    }

    @objc private func clicked() { onClick?() }

    /// The state the chip's button shows now (the same value the full-box ? shows).
    var appliedState: AskBackToggleState { button.appliedState }

    func apply(_ state: AskBackToggleState) { button.apply(state) }

    /// The real on-screen panel state and frames (read from AppKit, not a stored mirror).
    var isOnScreen: Bool { panel.isVisible }
    var panelFrame: CGRect { panel.frame }
    /// The button's real hit frame in screen points, derived from the live window + button frames.
    var frame: CGRect {
        CGRect(x: panel.frame.minX + button.frame.minX, y: panel.frame.minY + button.frame.minY,
               width: button.frame.width, height: button.frame.height)
    }
    /// The hit frame only while the panel is actually on screen, for the hold rule.
    var onScreenFrame: CGRect? { panel.isVisible ? frame : nil }
    /// Kept for older callers: logical shown state is now the real panel visibility.
    var isShown: Bool { panel.isVisible }

    /// Follow the info pill: show beside it, or hide when it is not shown (`placement == nil`).
    func place(_ placement: AskBackChipPlacement?) {
        guard let f = AskBackChipRules.frame(for: placement, size: button.intrinsicContentSize) else {
            panel.orderOut(nil)
            return
        }
        let p = Self.glowPadding
        panel.setFrame(NSRect(x: f.minX - p, y: f.minY - p,
                              width: f.width + 2 * p, height: f.height + 2 * p), display: true)
        panel.orderFrontRegardless()            // never becomes key: the user's field keeps focus
    }
}
