import Cocoa

enum PowerSettingsCopy {
    static let liveHint =
        "Live repeats partial transcription passes while the take is held, then does one final pass at release."
    static let finalOnlyHint =
        "Final-only's compact pill draws less power by skipping partial passes and doing one pass at release."
    static let modelsIntro =
        "Compute routing is independent of Transcription behavior on the Appearance tab. "
        + "Every LLM route keeps its own explicit provider, model, effort, and prompt choices. "
        + "Cloud providers move the work off this laptop."

    static func status(for mode: PowerMode) -> String {
        "Transcription behavior set to \(mode.label). Provider choices were unchanged."
    }
}

/// Appearance-tab surface for the manual Live / Final-only choice and its battery advisory.
final class PowerSettingsView: NSView {
    override var isFlipped: Bool { true }

    var onPowerModeChanged: (() -> Void)?

    private let W: CGFloat
    private let L: CGFloat = 20
    private var statusMessage: String?

    init(width: CGFloat) {
        self.W = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    func refresh() { rebuild() }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }

        let originY: CGFloat = 16
        addSubview(sectionHeader("POWER", y: originY))
        let cardY = originY + 22
        let card = cardView(y: cardY, height: 128, id: "card.power")

        card.addSubview(text("Transcription behavior", x: 14, y: 12, width: 210,
                             size: 13, weight: .semibold, color: .labelColor))
        let segmented = NSSegmentedControl(labels: ["Live", "Final-only"], trackingMode: .selectOne,
                                           target: self, action: #selector(powerModeChanged(_:)))
        segmented.identifier = NSUserInterfaceItemIdentifier("power-mode")
        segmented.selectedSegment = Settings.powerMode == .live ? 0 : 1
        segmented.frame = NSRect(x: card.bounds.width - 232, y: 8, width: 216, height: 28)
        card.addSubview(segmented)

        let modeHint = Settings.powerMode == .live
            ? PowerSettingsCopy.liveHint
            : PowerSettingsCopy.finalOnlyHint
        card.addSubview(wrap(modeHint, x: 14, y: 42, width: card.bounds.width - 28, height: 32))

        let evaluation = BatteryAdvisoryPolicy.evaluate(
            snapshot: SystemBatteryReader.current(), powerMode: Settings.powerMode,
            dismissedFor: Settings.batteryAdvisoryDismissedState)
        let batteryText: String
        if let reason = evaluation.reason {
            batteryText = "Battery advisory: \(reason.message)"
        } else if Settings.powerMode == .finalOnly {
            batteryText = "Battery advisory: Final-only is already enabled. Settings never change automatically."
        } else {
            batteryText = "Battery advisory: no suggestion right now. Settings never change automatically."
        }
        let battery = wrap(batteryText, x: 14, y: 78,
                           width: card.bounds.width - (evaluation.shouldSuggest ? 142 : 28), height: 36)
        battery.identifier = NSUserInterfaceItemIdentifier("battery-advisory")
        card.addSubview(battery)
        if evaluation.shouldSuggest {
            let use = button("Use Final-only", id: "battery-use-final-only",
                             action: #selector(useFinalOnly), x: card.bounds.width - 124, y: 82, width: 110)
            card.addSubview(use)
        }

        let statusY = cardY + card.frame.height + 12
        if let statusMessage = statusMessage {
            let status = wrap(statusMessage, x: L, y: statusY,
                              width: W - 2 * L, height: 34)
            status.identifier = NSUserInterfaceItemIdentifier("power-status")
            status.textColor = .secondaryLabelColor
            addSubview(status)
        }
        // Resize in place: the Appearance tab positions this view below the HUD block, so a rebuild must
        // never reset the origin the owner assigned.
        frame = NSRect(origin: frame.origin, size: NSSize(width: W, height: statusY + 38))
    }

    @objc private func powerModeChanged(_ sender: NSSegmentedControl) {
        Settings.powerMode = sender.selectedSegment == 1 ? .finalOnly : .live
        Log.write("settings: power mode -> \(Settings.powerMode.label)")
        status(PowerSettingsCopy.status(for: Settings.powerMode))
        onPowerModeChanged?()
    }

    @objc private func useFinalOnly() {
        Settings.powerMode = .finalOnly
        Log.write("settings: battery advisory accepted -> Final-only")
        status(PowerSettingsCopy.status(for: .finalOnly))
        onPowerModeChanged?()
    }

    private func status(_ message: String) {
        statusMessage = message
        rebuild()
    }

    private func cardView(y: CGFloat, height: CGFloat, id: String) -> NSView {
        let v = SettingsSectionKit.card(
            frame: NSRect(x: L, y: y, width: W - 2 * L, height: height), identifier: id)
        addSubview(v)
        return v
    }

    private func sectionHeader(_ title: String, y: CGFloat) -> NSTextField {
        SettingsSectionKit.sectionHeader(title, x: L, y: y, width: W - 2 * L)
    }

    private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        SettingsSectionKit.label(
            value, x: x, y: y, width: width, size: size, weight: weight, color: color)
    }

    private func wrap(_ value: String, x: CGFloat, y: CGFloat,
                      width: CGFloat, height: CGFloat) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: value)
        t.font = .systemFont(ofSize: 10.5)
        t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: x, y: y, width: width, height: height)
        return t
    }

    private func button(_ title: String, id: String, action: Selector,
                        x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 10.5)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.frame = NSRect(x: x, y: y, width: width, height: 26)
        return b
    }
}
