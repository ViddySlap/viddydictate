import Cocoa

/// The welcome/choose screen, drawn (spec section 1): the FIRST page of the `.picker` step, ahead of the
/// existing picker. One click on a card picks a `FirstRunSetupFlow.SetupChoice` and is gone; there is
/// nothing else to tick here.
///
/// It draws one card per `FirstRunSetupFlow.setupChoices()` entry rather than three fixed ones, so this
/// view has no list of its own to fall out of step with that seam's order.
final class WelcomeChooseView: NSView {
    override var isFlipped: Bool { true }

    /// Fired once, with whichever card was clicked. The host decides what each choice means: Advanced
    /// swaps to the existing picker page, the other two start the install directly.
    var onChoose: ((FirstRunSetupFlow.SetupChoice) -> Void)?
    var onSetUpLater: (() -> Void)?

    private let W: CGFloat
    private let L: CGFloat = 20

    init(width: CGFloat = 620) {
        self.W = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.surfaceIdentifier)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let contentW = W - L - 20
        var y: CGFloat = 0

        let headline = SettingsSectionKit.label(WelcomeChoose.headline, x: L, y: y, width: contentW,
                                                size: 19, weight: .semibold, color: .labelColor)
        headline.frame.size.height = 26
        headline.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.headlineIdentifier)
        addSubview(headline)
        y = headline.frame.maxY + 6

        let subtitle = SettingsSectionKit.wrapped(WelcomeChoose.subtitle, x: L, y: y, width: contentW,
                                                  size: 11, color: .secondaryLabelColor)
        subtitle.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.subtitleIdentifier)
        addSubview(subtitle)
        y = subtitle.frame.maxY + 18

        for choice in FirstRunSetupFlow.setupChoices() { y = addCard(choice, at: y, width: contentW) + 10 }

        let note = SettingsSectionKit.wrapped(WelcomeChoose.menuBarNote, x: L, y: y, width: contentW,
                                              size: 10.5, color: .tertiaryLabelColor)
        note.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.menuBarNoteIdentifier)
        addSubview(note)
        y = note.frame.maxY + 16

        let later = NSButton(title: NetworkPathCopy.setUpLaterButton, target: self,
                             action: #selector(setUpLaterClicked))
        later.bezelStyle = .rounded
        later.sizeToFit()
        later.frame = NSRect(x: L, y: y, width: max(later.frame.width + 18, 96), height: 28)
        later.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.setUpLaterIdentifier)
        addSubview(later)
        y = later.frame.maxY + 16

        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y)
    }

    /// One choice, as a card: its title as a one-click button so the whole card is the hit target, a
    /// one-line why, and - for the default choice only - a small DEFAULT badge beside the title. Every
    /// card shares the same title row and the same detail row, so the three read as a deck of equal
    /// choices rather than one that is taller than the others.
    private func addCard(_ choice: FirstRunSetupFlow.SetupChoice, at originY: CGFloat,
                         width: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: WelcomeChoose.cardIdentifier(choice))
        // The default is marked twice: a DEFAULT badge beside the title and a stronger border, so the
        // card reads as the one to pick even before its words are read.
        if choice == .recommended {
            card.layer?.borderWidth = 1.5
            card.layer?.borderColor = Phosphor.green.withAlphaComponent(0.5).cgColor
        }
        addSubview(card)
        let textX: CGFloat = 14
        let textW = width - textX - 14
        var y: CGFloat = 12

        let button = NSButton(title: WelcomeChoose.title(choice), target: self,
                              action: #selector(cardClicked(_:)))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.tag = tag(for: choice)
        button.sizeToFit()
        let buttonW = max(button.frame.width + 24, 140)
        button.frame = NSRect(x: textX, y: y, width: buttonW, height: 26)
        button.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.identifier(.title, choice))
        card.addSubview(button)

        if choice == .recommended {
            let badge = SettingsSectionKit.label(WelcomeChoose.recommendedBadge, x: 0, y: 0,
                                                 width: textW, size: 9, weight: .semibold,
                                                 color: .systemGreen)
            badge.attributedStringValue = NSAttributedString(string: WelcomeChoose.recommendedBadge,
                attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .kern: 1.2,
                            .foregroundColor: NSColor.systemGreen])
            badge.sizeToFit()
            badge.frame.origin = NSPoint(x: textX + buttonW + 12, y: y + 6)
            badge.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.identifier(.badge, choice))
            card.addSubview(badge)
        }
        y = button.frame.maxY + 8

        let detail = SettingsSectionKit.wrapped(WelcomeChoose.detail(choice), x: textX, y: y, width: textW,
                                                size: 10.5, color: .secondaryLabelColor)
        detail.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.identifier(.detail, choice))
        detail.toolTip = WelcomeChoose.detail(choice)
        card.addSubview(detail)
        y = detail.frame.maxY + 3

        card.frame.size.height = y + 10
        return card.frame.maxY
    }

    private func tag(for choice: FirstRunSetupFlow.SetupChoice) -> Int {
        (FirstRunSetupFlow.setupChoices().firstIndex(of: choice) ?? 0) + 1
    }

    @objc private func cardClicked(_ sender: NSButton) {
        let index = sender.tag - 1
        let choices = FirstRunSetupFlow.setupChoices()
        guard choices.indices.contains(index) else { return }
        onChoose?(choices[index])
    }

    @objc private func setUpLaterClicked() { onSetUpLater?() }
}
