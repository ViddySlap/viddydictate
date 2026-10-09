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
    /// Fired when the Recommended card's local-app selector changes, before the card is clicked.
    var onSelectLocalApp: ((LocalBackendID) -> Void)?
    /// The Recommended card's current "Local models app" choice, starting at the model's default.
    private(set) var localApp: LocalBackendID
    /// The PURE selector model the Recommended card is rendered from (options, titles, identifiers,
    /// default, caption, detail). This view holds none of that itself.
    private let selector: WelcomeChoose.RecommendedSelector
    private weak var localAppSelector: NSView?
    private weak var recommendedDetail: NSTextField?

    private let W: CGFloat
    private let L: CGFloat = 20

    init(width: CGFloat = 620,
         selector: WelcomeChoose.RecommendedSelector = WelcomeChoose.recommendedSelectorDefault) {
        self.W = width
        self.selector = selector
        self.localApp = selector.defaultApp
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

        // Recommended alone carries the compact local-app selector; Advanced and Dictation-only do not.
        if choice == .recommended {
            y = addLocalAppSelector(in: card, at: y, textX: textX, textW: textW)
        }

        // The Recommended line follows the selector; the other two cards' copy is fixed and the model
        // (which only exists for Recommended) is not involved.
        let detailText = choice == .recommended ? selector.detail(for: localApp)
                                                : WelcomeChoose.detail(choice)
        let detail = SettingsSectionKit.wrapped(detailText, x: textX, y: y, width: textW,
                                                size: 10.5, color: .secondaryLabelColor)
        detail.identifier = NSUserInterfaceItemIdentifier(WelcomeChoose.identifier(.detail, choice))
        detail.toolTip = detailText
        if choice == .recommended { recommendedDetail = detail }
        card.addSubview(detail)
        y = detail.frame.maxY + 3

        card.frame.size.height = y + 10
        return card.frame.maxY
    }

    private func tag(for choice: FirstRunSetupFlow.SetupChoice) -> Int {
        (FirstRunSetupFlow.setupChoices().firstIndex(of: choice) ?? 0) + 1
    }

    /// The compact two-option "Local models app" selector the Recommended card alone carries: a small
    /// label, the LM Studio | Ollama radios, and the one-line caption. Every string, identifier, the
    /// option order and the selected default come from `selector`; the view places them but decides
    /// nothing. It sits between the title row and the detail line, so the detail can follow the selection
    /// without moving anything else.
    private func addLocalAppSelector(in card: NSView, at originY: CGFloat,
                                     textX: CGFloat, textW: CGFloat) -> CGFloat {
        var y = originY
        let label = SettingsSectionKit.label(selector.label, x: textX, y: y,
                                             width: textW, size: 10.5, weight: .semibold,
                                             color: .secondaryLabelColor)
        label.identifier = NSUserInterfaceItemIdentifier(selector.labelIdentifier)
        card.addSubview(label)
        y = label.frame.maxY + 2

        let control = FlippedSectionView(frame: NSRect(x: textX, y: y, width: textW, height: 20))
        control.identifier = NSUserInterfaceItemIdentifier(selector.identifier)
        var x: CGFloat = 0
        for (index, option) in selector.options.enumerated() {
            let button = NSButton(radioButtonWithTitle: option.title, target: self,
                                  action: #selector(localAppClicked(_:)))
            button.font = .systemFont(ofSize: 11)
            button.tag = index + 1
            button.state = option.backend == localApp ? .on : .off
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: 0)
            button.identifier = NSUserInterfaceItemIdentifier(option.identifier)
            control.addSubview(button)
            x = button.frame.maxX + 16
        }
        card.addSubview(control)
        localAppSelector = control
        y = control.frame.maxY + 1

        let caption = SettingsSectionKit.wrapped(selector.caption, x: textX, y: y,
                                                 width: textW, size: 9.5, color: .tertiaryLabelColor)
        caption.identifier = NSUserInterfaceItemIdentifier(selector.captionIdentifier)
        card.addSubview(caption)
        y = caption.frame.maxY + 3
        return y
    }

    /// Move the selector and follow the choice in the Recommended detail line. The card is not re-laid
    /// out: the radios toggle, and the one text line whose promise changed is rewritten in place. Option
    /// order and the detail text come from the model.
    @objc private func localAppClicked(_ sender: NSButton) {
        guard selector.options.indices.contains(sender.tag - 1) else { return }
        let selected = selector.options[sender.tag - 1].backend
        guard selected != localApp else { return }
        localApp = selected
        for case let button as NSButton in localAppSelector?.subviews ?? [] {
            button.state = button.tag == sender.tag ? .on : .off
        }
        let text = selector.detail(for: selected)
        recommendedDetail?.stringValue = text
        recommendedDetail?.toolTip = text
        onSelectLocalApp?(selected)
    }

    @objc private func cardClicked(_ sender: NSButton) {
        let index = sender.tag - 1
        let choices = FirstRunSetupFlow.setupChoices()
        guard choices.indices.contains(index) else { return }
        onChoose?(choices[index])
    }

    @objc private func setUpLaterClicked() { onSetUpLater?() }
}
