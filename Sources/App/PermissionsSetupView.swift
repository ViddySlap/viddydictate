import Cocoa

/// B19's permissions screen, drawn, with the download running underneath it in a strip.
///
/// The strip is not decoration. B19's reasoning is that the download is dead time and the grants are
/// the only other thing between the user and a working app, so one is spent inside the other - and the
/// user has to be able to SEE that the time they spend in System Settings was not time the download
/// was paused.
final class PermissionsSetupView: NSView {
    override var isFlipped: Bool { true }

    /// Fired when a row's Grant button is pressed. The host performs it; the view neither prompts nor
    /// opens anything itself, so what a press does is decided in one place and testable there.
    var onGrant: ((SetupPermission) -> Void)?
    var onContinue: (() -> Void)?
    /// Fired by the Relaunch button. The host performs the relaunch (`AppRelauncher`), so the view
    /// neither spawns a process nor terminates the app itself.
    var onRelaunch: (() -> Void)?

    private(set) var status: PermissionsStatus
    private var progressRows: [InstallProgress.Row]
    private var aggregate: InstallProgress.Aggregate
    private var relaunchOffer: Bool = false

    private let W: CGFloat
    private let L: CGFloat = 20
    private let statusColumn: CGFloat = 84
    private let grantColumn: CGFloat = 84

    private var strip: InstallProgressView?

    init(width: CGFloat = 620, status: PermissionsStatus = .init(),
         progressRows: [InstallProgress.Row] = [],
         aggregate: InstallProgress.Aggregate = InstallProgress.aggregate([])) {
        self.W = width
        self.status = status
        self.progressRows = progressRows
        self.aggregate = aggregate
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier(PermissionsScreen.surfaceIdentifier)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    @discardableResult
    func apply(status: PermissionsStatus? = nil, progress: InstallProgressState? = nil,
               relaunchOffer: Bool? = nil) -> CGFloat {
        if let status { self.status = status }
        if let progress {
            progressRows = progress.rows
            aggregate = progress.aggregate
        }
        if let relaunchOffer { self.relaunchOffer = relaunchOffer }
        rebuild()
        return frame.height
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let contentW = W - L - 20
        var y: CGFloat = 0

        let headline = SettingsSectionKit.label(PermissionsScreen.headline, x: L, y: y,
                                                width: contentW, size: 19, weight: .semibold,
                                                color: .labelColor)
        headline.frame.size.height = 26
        headline.identifier = NSUserInterfaceItemIdentifier(PermissionsScreen.headlineIdentifier)
        addSubview(headline)
        y = headline.frame.maxY + 6

        let subtitle = SettingsSectionKit.wrapped(
            status.allGranted ? PermissionsScreen.allGrantedNote : PermissionsScreen.subtitle,
            x: L, y: y, width: contentW, size: 11, color: .secondaryLabelColor)
        subtitle.identifier = NSUserInterfaceItemIdentifier(PermissionsScreen.subtitleIdentifier)
        addSubview(subtitle)
        y = subtitle.frame.maxY + 16

        for permission in SetupPermission.allCases {
            y = addRow(permission, at: y, width: contentW) + 8
        }

        // Spec item 5: once Accessibility and Input Monitoring are both granted but this launch's tap
        // never started, the only thing that revives the hotkey is a restart. Shown between the rows
        // and Continue so it reads as part of the permission walkthrough, never overlapped by it.
        if relaunchOffer {
            let caption = SettingsSectionKit.wrapped(
                aggregate.anyRunning
                    ? "Relaunch becomes available when setup finishes"
                    : "macOS needs ViddyDictate to restart before the keyboard shortcut works",
                x: L, y: y, width: contentW, size: 11, color: .secondaryLabelColor)
            caption.identifier = NSUserInterfaceItemIdentifier("permissions-relaunch-caption")
            addSubview(caption)
            y = caption.frame.maxY + 8

            let relaunch = NSButton(title: "Relaunch ViddyDictate", target: self,
                                    action: #selector(relaunchClicked))
            relaunch.bezelStyle = .rounded
            // SAFETY: never relaunch while the install queue is running - it would kill a download.
            relaunch.isEnabled = !aggregate.anyRunning
            relaunch.frame = NSRect(x: L, y: y, width: 180, height: 26)
            relaunch.identifier = NSUserInterfaceItemIdentifier("permissions-relaunch-button")
            addSubview(relaunch)
            y = relaunch.frame.maxY + 16
        }

        y += 6
        let button = NSButton(title: PermissionsScreen.continueTitle, target: self,
                              action: #selector(continueClicked))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: L, y: y, width: 120, height: 26)
        button.identifier = NSUserInterfaceItemIdentifier(PermissionsScreen.continueIdentifier)
        addSubview(button)
        y = button.frame.maxY + 16

        // B19: "download progress in a strip along the bottom". Below every control on the screen, so
        // it reads as the thing running underneath rather than as another row to act on.
        let strip = InstallProgressView(width: W, style: .strip, rows: progressRows,
                                        aggregate: aggregate)
        strip.frame.origin = NSPoint(x: 0, y: y)
        addSubview(strip)
        self.strip = strip
        y = strip.frame.maxY

        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y + 8)
    }

    /// One permission: its name, what it buys, whether it has landed, and the button that takes the
    /// user to the exact pane. Each row flips on its own (B19) because each grant lands on its own.
    private func addRow(_ permission: SetupPermission, at originY: CGFloat,
                        width: CGFloat) -> CGFloat {
        let granted = status.isGranted(permission)
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: PermissionsScreen.cardIdentifier(permission))
        addSubview(card)

        var y: CGFloat = 12
        let textX: CGFloat = 14
        let textW = width - textX - statusColumn - grantColumn - 24

        let title = SettingsSectionKit.label(permission.title, x: textX, y: y, width: textW,
                                             size: 12.5, weight: .semibold, color: .labelColor)
        title.identifier = NSUserInterfaceItemIdentifier(
            PermissionsScreen.identifier(.title, permission))
        card.addSubview(title)

        let state = SettingsSectionKit.label(
            granted ? PermissionsScreen.grantedText : PermissionsScreen.pendingText,
            x: width - statusColumn - grantColumn - 14, y: y + 2, width: statusColumn, size: 10,
            weight: .semibold, color: granted ? Phosphor.green : .systemOrange)
        state.alignment = .right
        state.identifier = NSUserInterfaceItemIdentifier(
            PermissionsScreen.identifier(.status, permission))
        card.addSubview(state)

        // A granted row keeps its state word and loses its button. Leaving a live Grant button on a
        // row that is already on is how a user ends up in System Settings wondering what they missed.
        if !granted {
            let button = NSButton(title: PermissionsScreen.grantTitle, target: self,
                                  action: #selector(grantClicked(_:)))
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.tag = tag(for: permission)
            button.frame = NSRect(x: width - grantColumn - 14, y: y - 3, width: grantColumn, height: 24)
            button.identifier = NSUserInterfaceItemIdentifier(
                PermissionsScreen.identifier(.grant, permission))
            card.addSubview(button)
        }
        y += 21

        let detail = SettingsSectionKit.wrapped(permission.detail, x: textX, y: y, width: textW,
                                                size: 10.5, color: .secondaryLabelColor)
        detail.identifier = NSUserInterfaceItemIdentifier(
            PermissionsScreen.identifier(.detail, permission))
        detail.toolTip = permission.detail
        card.addSubview(detail)
        y += detail.frame.height + 3

        card.frame.size.height = y + 10
        return card.frame.maxY
    }

    private func tag(for permission: SetupPermission) -> Int {
        (SetupPermission.allCases.firstIndex(of: permission) ?? 0) + 1
    }

    private func permission(forTag tag: Int) -> SetupPermission? {
        let index = tag - 1
        guard SetupPermission.allCases.indices.contains(index) else { return nil }
        return SetupPermission.allCases[index]
    }

    @objc private func grantClicked(_ sender: NSButton) {
        guard let permission = permission(forTag: sender.tag) else { return }
        onGrant?(permission)
    }

    @objc private func continueClicked() { onContinue?() }

    @objc private func relaunchClicked() { onRelaunch?() }
}
