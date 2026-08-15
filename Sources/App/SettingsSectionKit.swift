import Cocoa

/// Settings section chrome, in one place.
///
/// It began on Setup, where the preflight rows (P11), provider sign-in section (L4), and Gemini key section
/// (L5) all draw the same card, section heading, and two kinds of label. Those were already written twice
/// when the third arrived, so they are written once here instead: a card that changes corner radius or a
/// label that changes size changes everywhere,
/// and consolidated tabs can reuse the same idiom instead of redrawing it.
///
/// It holds no state and no judgement. Callers own their own layout and their own identifiers; this only
/// answers "what does a card look like" and "what does a label look like".
enum SettingsSectionKit {

    /// A card, styled and flipped, at the caller's frame. Flipped because Settings cards lay their own
    /// contents out top-to-bottom.
    static func card(frame: NSRect, identifier: String) -> NSView {
        let card = FlippedSectionView(frame: frame)
        card.identifier = NSUserInterfaceItemIdentifier(identifier)
        card.wantsLayer = true
        card.layer?.backgroundColor = Phosphor.panelBG.withAlphaComponent(0.45).cgColor
        card.layer?.cornerRadius = 9
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Phosphor.green.withAlphaComponent(0.14).cgColor
        return card
    }

    /// A section heading: the small all-caps line that names what follows.
    static func sectionHeader(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        label(value, x: x, y: y, width: width, size: 10, weight: .semibold, color: .secondaryLabelColor)
    }

    /// A single-line label. Truncates rather than wraps, so it is for titles and state words - anything a
    /// user has to READ in full belongs in `wrapped`.
    static func label(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.frame = NSRect(x: x, y: y, width: width, height: max(15, size + 4))
        return field
    }

    /// A wrapping label sized to the height its text actually needs at this width. Every message on this
    /// tab grows to its text rather than a guessed height, because a clipped fix is not an actionable one.
    static func wrapped(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                        size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        let fitted = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        field.frame = NSRect(x: x, y: y, width: width, height: ceil(fitted.height))
        return field
    }
}

/// Top-to-bottom layout, like every Settings card and section.
final class FlippedSectionView: NSView {
    override var isFlipped: Bool { true }
}
