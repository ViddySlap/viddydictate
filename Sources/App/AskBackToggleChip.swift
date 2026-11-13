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

    /// The chip's frame, or nil (hidden) when the info pill is not shown. Vertically centred on the capsule and
    /// kept inside the screen's visible frame.
    static func frame(for placement: AskBackChipPlacement?, size: CGSize) -> CGRect? {
        guard let p = placement else { return nil }
        var x = p.onRight ? p.capsule.maxX + gap : p.capsule.minX - gap - size.width
        x = max(p.visible.minX, min(x, p.visible.maxX - size.width))
        return CGRect(x: x, y: p.capsule.midY - size.height / 2, width: size.width, height: size.height)
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
    private let button = AskBackToggleButton()
    private(set) var isShown = false
    private(set) var frame = CGRect.zero

    override init() {
        let size = button.intrinsicContentSize
        panel = ChipWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Phosphor.configureFloatingPanel(panel)
        panel.hasShadow = false
        panel.ignoresMouseEvents = false        // unlike the info pill: this one is clickable
        panel.becomesKeyOnlyIfNeeded = true
        button.frame = NSRect(origin: .zero, size: size)
        button.target = self
        button.action = #selector(clicked)
        panel.contentView = button
    }

    @objc private func clicked() { onClick?() }

    /// The state the chip's button shows now (the same value the full-box ? shows).
    var appliedState: AskBackToggleState { button.appliedState }

    func apply(_ state: AskBackToggleState) { button.apply(state) }

    /// Follow the info pill: show beside it, or hide when it is not shown (`placement == nil`).
    func place(_ placement: AskBackChipPlacement?) {
        guard let f = AskBackChipRules.frame(for: placement, size: button.intrinsicContentSize) else {
            isShown = false
            panel.orderOut(nil)
            return
        }
        isShown = true
        frame = f
        panel.setFrame(f, display: true)
        panel.orderFrontRegardless()            // never becomes key: the user's field keeps focus
    }
}
