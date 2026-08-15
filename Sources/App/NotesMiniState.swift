import Cocoa

/// The mini-view decision for a single notes window. Each window carries
/// ONE boolean that drives everything: the window is in mini view when the user's MANUAL toggle is on OR the
/// window's content is narrower than the auto-flip threshold.
///
///   effective mini = manualToggle OR contentWidth < 560
///
/// Only the MANUAL half is persisted (in `windows.json`, see `WindowMembership.manualMini`); the size-derived
/// half recomputes from the live window width on every resize and on page-ready, so it never needs storing.
/// Each window resolves this independently — one window can be mini while another is full.
///
/// The decision is a PURE function so `--notes-probe` can assert the whole truth table headlessly. The real
/// effect (hide the tab strip / button row / hamburger via `body.mini-mode`, leaving only the active note's
/// editor edge-to-edge) is WKWebView/CSS-side and is exercised by real-app GUI verification.
enum NotesMiniState {
    /// Content narrower than this (points) auto-flips the window into mini view. At or above it, only the
    /// manual toggle can hold mini. This matches the PRE-mini minimum window width (the old 560 `minSize`
    /// floor), so a full-chrome window that has not been shrunk never auto-flips.
    static let autoFlipWidth: CGFloat = 560

    /// The mini floor: the lowered window `minSize` (points), replacing the old 560x380. A window can shrink
    /// to here; content ~280 wide is always below `autoFlipWidth`, so the floor is always mini.
    static let minWidth: CGFloat = 280
    static let minHeight: CGFloat = 190

    /// One boolean drives everything: the manual toggle OR content below the auto-flip width.
    static func effectiveMini(manual: Bool, contentWidth: CGFloat) -> Bool {
        manual || contentWidth < autoFlipWidth
    }
}
