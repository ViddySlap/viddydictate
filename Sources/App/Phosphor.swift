import Cocoa
import CoreText

/// The shared CRT-phosphor theme + panel helpers for ViddyDictate's floating UI (the HUD, the mode
/// badge, the strength slider, the waveform/spinner, and the A/B + level pickers). Centralizes the
/// brand accent, the keyboard-only floating-panel config, the rounded panel-container chrome, the
/// selected/idle "cell" styling, the kerned-label helper, and centered presentation — so the look is
/// defined once instead of copy-pasted per panel.
///
/// The theme is monochromatic: the whole palette derives from ONE accent color. The `base*` constants
/// below are the reference palette at the default phosphor green (#00ff41); every visible shade is that
/// base transformed by the same HSB delta that maps the base green to the user's chosen `accent`
/// (`Settings.themeColorHex`). Picking a new accent therefore rotates the entire app to that hue while
/// preserving each shade's role (dark backgrounds stay dark, light text stays light) and reproducing
/// the default green byte-for-byte when unchanged. Consumers keep calling `Phosphor.green` / `.panelBG`
/// / etc.; those now read the live derived palette. Arbitrary one-off greens scattered in draw code go
/// through `Phosphor.themed(_:)`, which applies the same transform (and returns the input untouched at
/// the default theme, so the default look never drifts). Semantic non-theme colors (the stop-button
/// red, "REC") are left unwrapped on purpose.
enum Phosphor {
    // MARK: base (reference) palette — the default #00ff41 phosphor look, the source the theme derives FROM.

    /// The reference phosphor green (#00ff41), fully opaque — the hue the accent transform is measured from.
    static let baseGreen = NSColor(srgbRed: 0, green: 1.0, blue: 0.255, alpha: 1)
    private static let basePanelBG = NSColor(srgbRed: 0, green: 0.086, blue: 0.031, alpha: 0.95)
    private static let baseCellOn  = NSColor(srgbRed: 0, green: 0.14, blue: 0.05, alpha: 0.9)
    private static let baseCellOff = NSColor(srgbRed: 0, green: 0.06, blue: 0.025, alpha: 0.6)
    private static let baseNoteBodyBG = NSColor(srgbRed: 0.018, green: 0.035, blue: 0.028, alpha: 1)
    private static let baseNoteBodyText = NSColor(srgbRed: 0.78, green: 0.91, blue: 0.82, alpha: 1)
    private static let baseNoteMutedText = NSColor(srgbRed: 0.47, green: 0.62, blue: 0.50, alpha: 1)

    /// The default accent as a hex string — the single source for "is this the untouched theme?".
    static let defaultAccentHex = "#00ff41"

    static let font = "Helvetica Neue"

    // MARK: palette + theme derivation

    /// One resolved monochromatic palette (an accent plus the shades derived from it).
    struct Palette {
        let green, panelBG, cellOn, cellOff, noteBodyBG, noteBodyText, noteMutedText: NSColor
    }

    /// The reference palette at the default green — used as the flash-free web baseline and the fast path.
    static let base = Palette(green: baseGreen, panelBG: basePanelBG, cellOn: baseCellOn, cellOff: baseCellOff,
                              noteBodyBG: baseNoteBodyBG, noteBodyText: baseNoteBodyText, noteMutedText: baseNoteMutedText)

    /// The user's chosen accent (`Settings.themeColorHex`), or the default green if unset/unparseable.
    static var accent: NSColor { color(hex: Settings.themeColorHex) ?? baseGreen }

    /// True while the accent is the untouched default — the fast path that guarantees zero drift.
    static var isDefaultTheme: Bool {
        Settings.themeColorHex.caseInsensitiveCompare(defaultAccentHex) == .orderedSame
    }

    // Cache the derived palette so per-frame draw code doesn't recompute HSB transforms every call;
    // invalidated implicitly by keying on the accent hex.
    private static var cachedPalette: Palette?
    private static var cachedHex: String?

    /// The live palette for the current accent (cached until the accent hex changes).
    static var current: Palette {
        let hex = Settings.themeColorHex
        if let c = cachedPalette, cachedHex == hex { return c }
        let p = palette(for: color(hex: hex) ?? baseGreen)
        cachedPalette = p; cachedHex = hex
        return p
    }

    /// Derive a full palette from an accent: the accent itself plus each base shade rotated by the
    /// base-green -> accent HSB delta. Short-circuits to the base palette at the default accent.
    static func palette(for accent: NSColor) -> Palette {
        guard !approxEqual(accent, baseGreen) else { return base }
        func t(_ c: NSColor) -> NSColor { transform(c, from: baseGreen, to: accent) }
        return Palette(green: accent, panelBG: t(basePanelBG), cellOn: t(baseCellOn), cellOff: t(baseCellOff),
                       noteBodyBG: t(baseNoteBodyBG), noteBodyText: t(baseNoteBodyText), noteMutedText: t(baseNoteMutedText))
    }

    /// Apply the current theme's transform to an arbitrary base (green) color. Used to theme the one-off
    /// green literals in the HUD / mode-badge draw code. Returns the input unchanged at the default theme.
    static func themed(_ base: NSColor) -> NSColor {
        isDefaultTheme ? base : transform(base, from: baseGreen, to: accent)
    }

    /// Map `base` by the HSB delta that carries `from` to `to`: rotate hue by the same amount and scale
    /// saturation/brightness by the same ratios, preserving `base`'s alpha. Because green's base S and B
    /// are both 1, the scales collapse to the accent's own S and B — the whole palette moves as one.
    private static func transform(_ base: NSColor, from ref: NSColor, to accent: NSColor) -> NSColor {
        let (rh, rs, rb, _) = hsba(ref)
        let (ah, as_, ab, _) = hsba(accent)
        let (bh, bs, bb, ba) = hsba(base)
        var nh = bh + (ah - rh)
        nh -= floor(nh)                                  // wrap hue into 0...1
        let ns = clamp01(bs * (rs > 0.0001 ? as_ / rs : 1))
        let nb = clamp01(bb * (rb > 0.0001 ? ab / rb : 1))
        let out = NSColor(hue: nh, saturation: ns, brightness: nb, alpha: ba)
        return out.usingColorSpace(.sRGB) ?? base
    }

    private static func hsba(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let s = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, sa: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        s.getHue(&h, saturation: &sa, brightness: &b, alpha: &a)
        return (h, sa, b, a)
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    private static func approxEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        let x = a.usingColorSpace(.sRGB) ?? a, y = b.usingColorSpace(.sRGB) ?? b
        return abs(x.redComponent - y.redComponent) < 0.004
            && abs(x.greenComponent - y.greenComponent) < 0.004
            && abs(x.blueComponent - y.blueComponent) < 0.004
    }

    // MARK: live accent accessors (read `current` so a theme change applies without touching call sites)

    /// The brand accent (was the fixed phosphor green). Tint with `.withAlphaComponent(_:)` per use.
    static var green: NSColor { current.green }
    /// The dark panel-container fill used by the keyboard pickers.
    static var panelBG: NSColor { current.panelBG }
    /// Selected-cell fill (brighter) and idle-cell fill, shared by the A/B panes and the level cells.
    static var cellOn:  NSColor { current.cellOn }
    static var cellOff: NSColor { current.cellOff }
    /// Sticky-note editor body palette: dark-mode, low saturation, lighter than the HUD chrome.
    static var noteBodyBG:   NSColor { current.noteBodyBG }
    static var noteBodyText: NSColor { current.noteBodyText }
    static var noteMutedText: NSColor { current.noteMutedText }

    // MARK: hex <-> NSColor (accent persistence + the color well)

    /// Opaque `#rrggbb` for an NSColor, in sRGB. The single spelling used by both the picker and CSS.
    static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { min(255, max(0, Int(round(v * 255)))) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Parse `#rrggbb` (or `rrggbb`) into an opaque sRGB NSColor. Returns nil on a malformed string.
    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    // MARK: helpers (unchanged behavior, now reading the live palette)

    struct HeaderContentFooterLayout {
        let totalHeight: CGFloat
        let headerFrame: NSRect
        let contentY: CGFloat
        let footerFrame: NSRect
    }

    /// Shared vertical layout for the keyboard pickers: a header, one content row, and a footer.
    static func headerContentFooterLayout(
        width: CGFloat,
        contentH: CGFloat,
        padX: CGFloat,
        headerH: CGFloat,
        footerH: CGFloat,
        padTop: CGFloat,
        padMid: CGFloat,
        padBottom: CGFloat
    ) -> HeaderContentFooterLayout {
        let totalHeight = padTop + headerH + padMid + contentH + padMid + footerH + padBottom
        return HeaderContentFooterLayout(
            totalHeight: totalHeight,
            headerFrame: NSRect(
                x: padX,
                y: totalHeight - padTop - headerH,
                width: width - padX * 2,
                height: headerH
            ),
            contentY: padBottom + footerH + padMid,
            footerFrame: NSRect(
                x: padX,
                y: padBottom,
                width: width - padX * 2,
                height: footerH
            )
        )
    }

    // MARK: single-line text geometry (visual box, not line box)

    /// `NSAttributedString.size()` is the LINE box — ascender + descender + leading — so centering a
    /// glyph on it centers the *typographic* slot, not the mark you can see. These two helpers give the
    /// glyph's real ink instead, and every HUD surface that centers a single glyph or measures where
    /// the top of a word sits goes through them.
    private static let textLayout = NSLayoutManager()

    /// Distance from a single-line `draw(at:)` origin UP to the text baseline. AppKit lays one line as
    /// a fragment `size().height` tall with the baseline `defaultBaselineOffset` down from its top;
    /// verified against rendered pixels at 8.5/11/16.5/19pt.
    static func baselineOffset(for s: NSAttributedString, font: NSFont) -> CGFloat {
        s.size().height - textLayout.defaultBaselineOffset(for: font)
    }

    /// The glyph-path bounds of a single line, RELATIVE TO ITS BASELINE (so `minY` is negative for a
    /// mark that descends, and `maxY` is the cap height for upper case).
    static func inkBox(for s: NSAttributedString) -> CGRect {
        CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(s), .useGlyphPathBounds)
    }

    /// A kerned, colored attributed string in the phosphor font.
    static func kerned(_ s: String, color: NSColor, size: CGFloat, kern: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont(name: font, size: size) ?? .systemFont(ofSize: size),
            .foregroundColor: color, .kern: kern,
        ])
    }

    /// Configure a borderless, non-activating, keyboard-only floating panel: focus stays on the
    /// user's text field, the panel ignores the mouse and never activates the app, and it rides above
    /// other windows across all Spaces.
    static func configureFloatingPanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true   // keyboard-only; focus stays on the user's field
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// Apply the rounded phosphor panel-container chrome (dark fill, faint accent border).
    static func styleContainer(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = panelBG.cgColor
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = green.withAlphaComponent(0.35).cgColor
    }

    /// Apply the selected/idle "cell" styling shared by the A/B panes and the level cells: brighten
    /// the border + fill and add an outward phosphor glow when selected. The view must already have a
    /// layer with its own corner radius / border width.
    static func styleCell(_ view: NSView, selected on: Bool) {
        view.layer?.borderColor = (on ? green.withAlphaComponent(0.9) : green.withAlphaComponent(0.18)).cgColor
        view.layer?.backgroundColor = (on ? cellOn : cellOff).cgColor
        if on {
            view.layer?.shadowColor = green.cgColor; view.layer?.shadowRadius = 10
            view.layer?.shadowOpacity = 0.55; view.layer?.shadowOffset = .zero; view.layer?.masksToBounds = false
        } else {
            view.layer?.shadowOpacity = 0; view.layer?.masksToBounds = true
        }
    }

    /// Size `container` to (W, H), center the panel on the main screen, and order it front without
    /// activating the app (focus-preserving). Used by the keyboard pickers.
    static func presentCentered(_ panel: NSPanel, container: NSView, width W: CGFloat, height H: CGFloat,
                                on screen: NSRect) {
        container.frame = NSRect(x: 0, y: 0, width: W, height: H)
        panel.setFrame(NSRect(x: screen.midX - W / 2, y: screen.midY - H / 2, width: W, height: H), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    // MARK: web-island theme (CSS variables)

    /// The `:root { --vd-* }` block the sticky-notes web island themes off. Defaults to the live palette
    /// (used for runtime injection); the build baseline passes `Phosphor.base` via `--emit-theme-css`.
    static func emitThemeCSS(_ p: Palette = current) -> String {
        """
        :root {
          --vd-green: \(css(p.green));
          --vd-green-70: \(css(p.green.withAlphaComponent(0.70)));
          --vd-green-28: \(css(p.green.withAlphaComponent(0.28)));
          --vd-green-24: \(css(p.green.withAlphaComponent(0.24)));
          --vd-green-18: \(css(p.green.withAlphaComponent(0.18)));
          --vd-panel-bg: \(css(p.panelBG));
          --vd-cell-on: \(css(p.cellOn));
          --vd-cell-off: \(css(p.cellOff));
          --vd-note-bg: \(css(p.noteBodyBG));
          --vd-note-bg-soft: \(css(p.noteBodyBG.withAlphaComponent(0.96)));
          --vd-note-text: \(css(p.noteBodyText));
          --vd-note-muted: \(css(p.noteMutedText));
          --vd-font: "\(font)", system-ui, sans-serif;
        }

        """
    }

    private static func css(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { min(255, max(0, Int(round(v * 255)))) }
        let r = byte(c.redComponent)
        let g = byte(c.greenComponent)
        let b = byte(c.blueComponent)
        let a = Double(c.alphaComponent)
        if a >= 0.999 { return String(format: "#%02x%02x%02x", r, g, b) }
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, a)
    }
}

/// Shared timer and persistent offscreen buffer for the phosphor waveform and spinner views.
final class PhosphorCanvas {
    private var timer: Timer?
    private var phosphor = PhosphorBuffer()
    private(set) var image: CGImage?

    func start(fps: Double, onTick: @escaping () -> Void) {
        phosphor = PhosphorBuffer()
        image = nil
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / max(1, fps), repeats: true) { _ in onTick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isRunning: Bool { timer != nil }

    func context(bounds: NSRect, scale: CGFloat) -> CGContext? {
        phosphor.ensure(bounds: bounds, scale: scale)
    }

    func capture(_ context: CGContext) {
        image = context.makeImage()
    }

    @discardableResult
    func blit(in bounds: NSRect) -> Bool {
        guard let context = NSGraphicsContext.current?.cgContext, let image else { return false }
        context.draw(image, in: bounds)
        return true
    }
}
