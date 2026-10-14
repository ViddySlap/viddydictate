import Cocoa

/// The real Speech card in Settings: ONE global Whisper model choice, rendered from a
/// `WhisperPickerModel`. The view only renders rows and forwards one action per row; every decision is
/// tested on the model with injected effects, so this file stays a thin, dummy-free presentation layer.
final class WhisperSpeechSettingsView: NSView {
    override var isFlipped: Bool { true }

    /// The model that owns every decision. Exposed so the Settings window builder can drive it.
    let model: WhisperPickerModel
    /// One action per row. The view never decides; it forwards (action, repo) to the owner.
    var onAction: ((WhisperPickerModel.RowAction, String) -> Void)?

    private let contentWidth: CGFloat
    private var card: NSView?
    private let statusField: NSTextField
    private let footerField: NSTextField
    private static let footerBottomPadding: CGFloat = 16

    init(width: CGFloat, model: WhisperPickerModel) {
        self.contentWidth = width
        self.model = model
        self.statusField = Self.statusField(width: width)
        self.footerField = Self.footerField(width: width)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        model.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.render() }
        }
        buildChrome()
        render()
    }

    /// Production build for the Settings tab: measured installed set and free disk, real effects.
    convenience init(width: CGFloat) {
        let effects = WhisperPickerModel.Effects.production()
        let model = WhisperPickerModel(
            activeRepo: Settings.whisperModelRepo,
            installed: Self.measureInstalled(effects),
            freeDiskBytes: effects.freeDiskBytes(),
            effects: effects)
        self.init(width: width, model: model)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: chrome

    private func buildChrome() {
        addSubview(sectionHeader("WHISPER MODEL", y: 16))
        let cardView = SettingsSectionKit.card(
            frame: NSRect(x: 20, y: 38, width: contentWidth - 40, height: 10),
            identifier: "card.speech")
        self.card = cardView
        addSubview(cardView)
        addSubview(statusField)
        addSubview(footerField)
    }

    // MARK: render

    func render() {
        guard let card else { return }
        for sub in card.subviews where sub.identifier?.rawValue.hasPrefix("whisper-speech-row|") == true {
            sub.removeFromSuperview()
        }

        let rows = model.rows
        let innerWidth = card.bounds.width - 28
        let rowHeight: CGFloat = 68
        var y: CGFloat = 12
        for row in rows {
            let container = FlippedSectionView(
                frame: NSRect(x: 14, y: y, width: innerWidth, height: rowHeight))
            container.identifier = NSUserInterfaceItemIdentifier("whisper-speech-row|\(row.repo)")
            card.addSubview(container)

            let nameText = row.isDefault ? row.name + " — Default" : row.name
            let name = SettingsSectionKit.label(
                nameText, x: 0, y: 6, width: innerWidth - 130, size: 12, weight: .medium,
                color: .labelColor)
            name.identifier = NSUserInterfaceItemIdentifier("whisper-speech-name|\(row.repo)")
            container.addSubview(name)

            let size = SettingsSectionKit.label(
                row.sizeText, x: 0, y: 26, width: innerWidth - 130, size: 11, weight: .regular,
                color: .secondaryLabelColor)
            size.identifier = NSUserInterfaceItemIdentifier("whisper-speech-size|\(row.repo)")
            container.addSubview(size)

            let state = SettingsSectionKit.label(
                Self.stateText(row.state), x: 0, y: 44, width: innerWidth - 130, size: 11,
                weight: .regular, color: Self.stateColor(row.state))
            state.identifier = NSUserInterfaceItemIdentifier("whisper-speech-state|\(row.repo)")
            container.addSubview(state)

            if row.action != .none {
                let button = NSButton(title: Self.actionTitle(row.action), target: self,
                                      action: #selector(actionPressed(_:)))
                button.bezelStyle = .rounded
                button.identifier = NSUserInterfaceItemIdentifier("whisper-speech-action|\(row.repo)")
                button.frame = NSRect(x: innerWidth - 110, y: 20, width: 110, height: 26)
                container.addSubview(button)
            }
            y += rowHeight
        }
        card.frame.size.height = y + 12

        let notice = model.notice ?? ""
        statusField.stringValue = notice
        statusField.isHidden = notice.isEmpty
        var statusHeight: CGFloat = 0
        if !notice.isEmpty {
            let fitted = statusField.sizeThatFits(
                NSSize(width: contentWidth - 40, height: .greatestFiniteMagnitude))
            statusHeight = ceil(fitted.height)
        }
        let statusY = card.frame.maxY + 12
        statusField.frame = NSRect(x: 20, y: statusY, width: contentWidth - 40, height: statusHeight)

        let footerHeight = ceil(footerField.sizeThatFits(
            NSSize(width: contentWidth - 40, height: .greatestFiniteMagnitude)).height)
        let footerY = statusY + statusHeight + 8
        footerField.frame = NSRect(x: 20, y: footerY, width: contentWidth - 40, height: footerHeight)

        frame.size.height = footerY + footerHeight + Self.footerBottomPadding
    }

    /// Re-measure the machine and re-render (Settings opens are re-measured by contract, like every
    /// sibling tab).
    func refresh() {
        model.activeRepo = Settings.whisperModelRepo
        model.installed = Self.measureInstalled(model.effects)
        model.freeDiskBytes = model.effects.freeDiskBytes()
        render()
    }

    // MARK: actions

    @objc private func actionPressed(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let repo = raw.components(separatedBy: "|").last, !repo.isEmpty else { return }
        guard let row = model.rows.first(where: { $0.repo == repo }) else { return }
        onAction?(row.action, repo)
    }

    // MARK: helpers

    static func measureInstalled(_ effects: WhisperPickerModel.Effects) -> Set<String> {
        var installed = Set<String>()
        for variant in WhisperModelCatalog.variants where effects.installed(variant.repo) {
            installed.insert(variant.repo)
        }
        return installed
    }

    private static func stateText(_ state: WhisperPickerModel.RowState) -> String {
        WhisperPickerModel.stateText(state)
    }

    private static func stateColor(_ state: WhisperPickerModel.RowState) -> NSColor {
        switch state {
        case .active: return .labelColor
        case .failed: return .systemRed
        default: return .secondaryLabelColor
        }
    }

    private static func actionTitle(_ action: WhisperPickerModel.RowAction) -> String {
        switch action {
        case .none: return ""
        case .useThis: return "Use this"
        case .install: return "Install"
        }
    }

    private func sectionHeader(_ text: String, y: CGFloat) -> NSTextField {
        SettingsSectionKit.label(text, x: 20, y: y, width: contentWidth - 40,
                                 size: 10, weight: .semibold, color: .labelColor)
    }

    private static func statusField(width: CGFloat) -> NSTextField {
        let field = SettingsSectionKit.wrapped(
            "", x: 20, y: 0, width: width - 40, size: 12, color: .labelColor)
        field.identifier = NSUserInterfaceItemIdentifier("whisper-speech-status")
        return field
    }

    private static func footerField(width: CGFloat) -> NSTextField {
        let field = SettingsSectionKit.wrapped(
            "Changing this restarts the speech engine.", x: 20, y: 0, width: width - 40,
            size: 10.5, color: .labelColor)
        field.identifier = NSUserInterfaceItemIdentifier("whisper-speech-footer")
        return field
    }
}
