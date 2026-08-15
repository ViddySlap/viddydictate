import Cocoa

/// The provider-onboarding rows (Public V1 spec W4, item P9), as one view used by both hosts: the first-run
/// window and the Setup tab in Settings. W4 requires one shared flow entered from two states, so there is one
/// view rather than a first-run copy and a Settings copy that get fixed on different days.
///
/// It holds no judgement and no measurement. A `ProviderOnboarding.Plan` comes in, rows go out, and the only
/// thing a click does is hand the provider back to the host through `onConnect`. That is what keeps the
/// signed-out/not-installed split derived in one place: the view cannot decide to offer a button, it can only
/// render the action the plan carries.
final class ProviderOnboardingView: NSView {
    override var isFlipped: Bool { true }

    /// One size for every provider's button, so the Setup tab's two rows read as one section rather than as
    /// two controls that happen to be near each other (L4). Wide enough for the longest title this build
    /// ships; the offscreen gate reds if a future title stops fitting.
    static let actionButtonSize = NSSize(width: 190, height: 26)

    /// Invoked with the provider whose action was clicked. The host owns the flow
    /// (`ProviderSignInPresenter`); the view never starts a login itself.
    var onConnect: ((LLMProvider) -> Void)?

    /// nil while the measurement is in flight. A not-yet-measured surface must not read like a verdict, so
    /// this renders its own headline rather than an empty plan.
    private var plan: ProviderOnboarding.Plan?

    private let W: CGFloat
    private let L: CGFloat
    /// Set when the host already shows the standing copy itself, so the Setup tab does not repeat the
    /// first-run window's subtitle and footer under a second heading.
    private let showsStandingCopy: Bool

    init(width: CGFloat, leftInset: CGFloat = 20, showsStandingCopy: Bool = true) {
        self.W = width
        self.L = leftInset
        self.showsStandingCopy = showsStandingCopy
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Render a measurement, or the in-flight state when `plan` is nil. Returns the height it needs, so a
    /// host laying out a taller document can place what follows.
    @discardableResult
    func apply(_ plan: ProviderOnboarding.Plan?) -> CGFloat {
        self.plan = plan
        rebuild()
        return frame.height
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        let contentW = W - L - 20

        let headlineText = plan.map(ProviderOnboarding.headline) ?? ProviderOnboarding.checkingHeadline
        // Attention colour tracks whether anything is actually MISSING, not whether a cloud provider is signed
        // in: a machine whose transforms already run has nothing to flag.
        let missing = !(plan?.nothingIsMissing ?? false)
        let headline = wrapped(headlineText, x: L, y: y, width: contentW, size: 13, weight: .medium,
                               color: missing ? .systemOrange : .labelColor)
        headline.identifier = NSUserInterfaceItemIdentifier(ProviderOnboarding.headlineIdentifier)
        addSubview(headline)
        y = headline.frame.maxY + 6

        if showsStandingCopy {
            let subtitle = wrapped(ProviderOnboarding.subtitle, x: L, y: y, width: contentW,
                                   size: 10.5, weight: .regular, color: .tertiaryLabelColor)
            subtitle.identifier = NSUserInterfaceItemIdentifier(ProviderOnboarding.subtitleIdentifier)
            addSubview(subtitle)
            y = subtitle.frame.maxY + 10
        }

        for step in plan?.steps ?? [] {
            y = addRow(step, at: y, width: contentW)
        }

        if showsStandingCopy {
            let footer = wrapped(ProviderOnboarding.footer, x: L, y: y + 4, width: contentW,
                                 size: 10.5, weight: .regular, color: .tertiaryLabelColor)
            footer.identifier = NSUserInterfaceItemIdentifier(ProviderOnboarding.footerIdentifier)
            addSubview(footer)
            y = footer.frame.maxY
        }

        frame = NSRect(x: 0, y: frame.origin.y, width: W, height: y)
    }

    /// One provider, as a card: state word, product name, opening sentence, the vendor reason when there is
    /// one, the next step, and the action button only when the plan carries an action. The card grows to its
    /// measured text rather than a guessed height - a clipped next step is not actionable.
    private func addRow(_ step: ProviderOnboardingStep, at originY: CGFloat, width: CGFloat) -> CGFloat {
        // The card chrome is `SettingsSectionKit`'s, shared with the preflight rows and the Gemini key
        // section, so the sections on the Setup tab cannot drift apart.
        let card = SettingsSectionKit.card(
            frame: NSRect(x: L, y: originY, width: width, height: 0),
            identifier: ProviderOnboarding.cardIdentifier(step.provider))
        addSubview(card)

        let statusW: CGFloat = 110
        let textX = statusW + 20
        let textW = width - textX - 14
        var y: CGFloat = 12

        let status = label(step.situation.statusText, x: 14, y: y + 1, width: statusW - 8,
                           size: 10, weight: .semibold,
                           color: step.situation == .ready ? .systemGreen : .systemOrange)
        status.identifier = NSUserInterfaceItemIdentifier(
            ProviderOnboarding.identifier(.status, step.provider))
        card.addSubview(status)

        let title = label(step.title, x: textX, y: y, width: textW, size: 12.5, weight: .semibold,
                          color: .labelColor)
        title.identifier = NSUserInterfaceItemIdentifier(
            ProviderOnboarding.identifier(.title, step.provider))
        card.addSubview(title)
        y += 20

        // Laid out from one list so a row cannot lose a line by forgetting a call, and so the identifiers are
        // assigned positionally from the order the surface documents.
        let lines: [(ProviderOnboarding.RowPart, String?, NSColor)] = [
            (.opening, step.opening, .secondaryLabelColor),
            (.detail, step.detail, .tertiaryLabelColor),
            (.step, step.step, .labelColor),
        ]
        for (part, value, color) in lines {
            guard let value = value else { continue }
            let field = wrapped(value, x: textX, y: y, width: textW, size: 10.5, weight: .regular,
                                color: color)
            field.identifier = NSUserInterfaceItemIdentifier(
                ProviderOnboarding.identifier(part, step.provider))
            field.toolTip = value
            card.addSubview(field)
            y += field.frame.height + 3
        }

        if step.action != nil, let title = step.actionTitle {
            let button = NSButton(title: title, target: self, action: #selector(actionClicked(_:)))
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.identifier = NSUserInterfaceItemIdentifier(
                ProviderOnboarding.identifier(.action, step.provider))
            // Fixed rather than sized to its own title: the two providers' buttons sit in the same place
            // and are the same size whatever each one currently says (L4's visual parity). A title that
            // outgrows this width would be clipped, so the render gate asserts every title still fits
            // instead of letting the button quietly resize itself.
            button.frame = NSRect(origin: NSPoint(x: textX, y: y + 4), size: Self.actionButtonSize)
            card.addSubview(button)
            y = button.frame.maxY
        }

        card.frame.size.height = y + 9
        return originY + card.frame.height + 8
    }

    /// The provider comes from the clicked control's own identifier, so one selector serves every row and the
    /// button cannot be wired to a provider other than the one it was drawn for.
    @objc private func actionClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let provider = LLMProvider.allCases.first(where: {
                  raw == ProviderOnboarding.identifier(.action, $0)
              }) else { return }
        onConnect?(provider)
    }

    // MARK: - view helpers

    private func label(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                       size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        SettingsSectionKit.label(value, x: x, y: y, width: width, size: size, weight: weight, color: color)
    }

    private func wrapped(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                         size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        SettingsSectionKit.wrapped(value, x: x, y: y, width: width, size: size, weight: weight,
                                   color: color)
    }
}
