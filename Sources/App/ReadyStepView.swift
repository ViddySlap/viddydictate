import Cocoa

/// The Ready screen, drawn (spec section 2): the window's last step once the install queue has settled.
/// A check per component, a permissions summary, a practice box, Relaunch when offered, and Done.
///
/// It holds no judgement of its own. `InstallProgress.Row.phase` says which components landed and which
/// failed; `FeatureTourPractice` - the Feature Tour's own practice-box state machine, not a second one -
/// says what the practice box can show; `PermissionsStatus` says what to summarise.
final class ReadyStepView: NSView {
    override var isFlipped: Bool { true }

    /// B10's Retry, re-entered: the host restarts the exact rows that failed.
    var onResumeSetup: (() -> Void)?
    var onRelaunch: (() -> Void)?
    var onDone: (() -> Void)?

    private var rows: [InstallProgress.Row]
    private var permissions: PermissionsStatus
    private var practice: FeatureTourPractice.State
    private var offerRelaunch: Bool
    private(set) weak var practiceField: NSTextView?

    private let W: CGFloat
    private let L: CGFloat = 20

    init(width: CGFloat = 620, rows: [InstallProgress.Row] = [],
        permissions: PermissionsStatus = .init(), practice: FeatureTourPractice.State = .grantFirst,
        offerRelaunch: Bool = false) {
        self.W = width
        self.rows = rows
        self.permissions = permissions
        self.practice = practice
        self.offerRelaunch = offerRelaunch
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier(ReadyStep.surfaceIdentifier)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    @discardableResult
    func apply(rows: [InstallProgress.Row]? = nil, permissions: PermissionsStatus? = nil,
              practice: FeatureTourPractice.State? = nil, offerRelaunch: Bool? = nil) -> CGFloat {
        if let rows { self.rows = rows }
        if let permissions { self.permissions = permissions }
        if let practice { self.practice = practice }
        if let offerRelaunch { self.offerRelaunch = offerRelaunch }
        rebuild()
        return frame.height
    }

    private var failedRows: [InstallProgress.Row] { rows.filter { $0.phase == .failed } }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let contentW = W - L - 20
        var y: CGFloat = 0

        let degraded = !failedRows.isEmpty
        let headline = SettingsSectionKit.label(ReadyStep.headline, x: L, y: y, width: contentW,
                                                size: 19, weight: .semibold, color: .labelColor)
        headline.frame.size.height = 26
        headline.identifier = NSUserInterfaceItemIdentifier(ReadyStep.headlineIdentifier)
        addSubview(headline)
        y = headline.frame.maxY + 6

        let subtitle = SettingsSectionKit.wrapped(
            degraded ? ReadyStep.degradedSubtitle : ReadyStep.allDoneSubtitle,
            x: L, y: y, width: contentW, size: 11,
            color: degraded ? .systemOrange : .secondaryLabelColor)
        subtitle.identifier = NSUserInterfaceItemIdentifier(ReadyStep.subtitleIdentifier)
        addSubview(subtitle)
        y = subtitle.frame.maxY + 16

        y = addComponents(at: y, width: contentW) + 10
        y = addPermissionsSummary(at: y, width: contentW) + 14
        y = addPractice(at: y, width: contentW) + 14

        if offerRelaunch { y = addRelaunch(at: y, width: contentW) + 14 }

        let note = SettingsSectionKit.wrapped(WelcomeChoose.menuBarNote, x: L, y: y, width: contentW,
                                              size: 10.5, color: .tertiaryLabelColor)
        note.identifier = NSUserInterfaceItemIdentifier(ReadyStep.menuBarNoteIdentifier)
        addSubview(note)
        y = note.frame.maxY + 16

        let done = NSButton(title: ReadyStep.doneTitle, target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: L, y: y, width: 100, height: 28)
        done.identifier = NSUserInterfaceItemIdentifier(ReadyStep.doneIdentifier)
        addSubview(done)
        y = done.frame.maxY + 16

        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y)
    }

    /// One line per component: a check once it has landed, or Resume setup on the row that failed (B10:
    /// never silently - the siblings that landed keep their check).
    private func addComponents(at originY: CGFloat, width: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: "ready-components-card")
        addSubview(card)
        var y: CGFloat = 12
        for row in rows {
            let failed = row.phase == .failed
            let mark = SettingsSectionKit.label(failed ? "\u{2717}" : "\u{2713}", x: 14, y: y, width: 20,
                                                size: 13, weight: .semibold,
                                                color: failed ? .systemRed : .systemGreen)
            card.addSubview(mark)
            let title = SettingsSectionKit.label(row.title, x: 38, y: y + 1, width: width - 160, size: 12.5,
                                                 weight: .semibold, color: .labelColor)
            title.identifier = NSUserInterfaceItemIdentifier(ReadyStep.identifier(.status, row.id))
            card.addSubview(title)
            if failed {
                let resume = NSButton(title: ReadyStep.resumeSetupTitle, target: self,
                                      action: #selector(resumeSetupClicked))
                resume.bezelStyle = .rounded
                resume.font = .systemFont(ofSize: 10.5)
                resume.frame = NSRect(x: width - 128, y: y - 4, width: 114, height: 22)
                resume.identifier = NSUserInterfaceItemIdentifier(ReadyStep.identifier(.resume, row.id))
                card.addSubview(resume)
            }
            y += 27
        }
        card.frame.size.height = y + 6
        return card.frame.maxY
    }

    private func addPermissionsSummary(at originY: CGFloat, width: CGFloat) -> CGFloat {
        let line = permissions.allGranted
            ? ReadyStep.permissionsAllGrantedLine
            : (permissions.bannerLine ?? ReadyStep.permissionsAllGrantedLine)
        let field = SettingsSectionKit.wrapped(line, x: L, y: originY, width: width, size: 11,
                                               color: permissions.allGranted ? .secondaryLabelColor
                                                                              : .systemOrange)
        field.identifier = NSUserInterfaceItemIdentifier(ReadyStep.permissionsSummaryIdentifier)
        addSubview(field)
        return field.frame.maxY
    }

    /// D9's practice box, reusing the Feature Tour's own state and words (`FeatureTourPractice`) and its
    /// own editable text view (`FeatureTourPracticeTextView`) rather than a second practice box.
    private func addPractice(at originY: CGFloat, width: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: ReadyStep.practiceCardIdentifier)
        addSubview(card)
        let ready = practice == .ready
        var y: CGFloat = 12

        let header = SettingsSectionKit.sectionHeader(ReadyStep.practiceHeader, x: 14, y: y, width: width - 28)
        card.addSubview(header)
        y = header.frame.maxY + 6

        let note = SettingsSectionKit.wrapped(FeatureTourPractice.note(practice, map: HotkeyMap.load()),
                                              x: 14, y: y, width: width - 28, size: 11.5,
                                              color: ready ? .secondaryLabelColor : .systemOrange)
        note.identifier = NSUserInterfaceItemIdentifier(ReadyStep.practiceNoteIdentifier)
        card.addSubview(note)
        y = note.frame.maxY + 8

        let box = NSScrollView(frame: NSRect(x: 14, y: y, width: width - 28, height: 48))
        box.borderType = .bezelBorder
        box.hasVerticalScroller = true
        box.autohidesScrollers = true
        let text = FeatureTourPracticeTextView(frame: box.contentView.bounds)
        text.isRichText = false
        text.font = .systemFont(ofSize: 12.5)
        text.isEditable = ready
        text.isSelectable = ready
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.identifier = NSUserInterfaceItemIdentifier(ReadyStep.practiceFieldIdentifier)
        text.setAccessibilityPlaceholderValue(FeatureTourPractice.placeholder)
        box.documentView = text
        card.addSubview(box)
        practiceField = text
        y = box.frame.maxY

        card.frame.size.height = y + 10
        return card.frame.maxY
    }

    private func addRelaunch(at originY: CGFloat, width: CGFloat) -> CGFloat {
        var y = originY
        let caption = SettingsSectionKit.wrapped(
            "macOS needs ViddyDictate to restart before the keyboard shortcut works",
            x: L, y: y, width: width, size: 11, color: .secondaryLabelColor)
        caption.identifier = NSUserInterfaceItemIdentifier(ReadyStep.relaunchCaptionIdentifier)
        addSubview(caption)
        y = caption.frame.maxY + 8

        let relaunch = NSButton(title: ReadyStep.relaunchTitle, target: self,
                                action: #selector(relaunchClicked))
        relaunch.bezelStyle = .rounded
        relaunch.frame = NSRect(x: L, y: y, width: 180, height: 26)
        relaunch.identifier = NSUserInterfaceItemIdentifier(ReadyStep.relaunchIdentifier)
        addSubview(relaunch)
        return relaunch.frame.maxY
    }

    @objc private func resumeSetupClicked() { onResumeSetup?() }
    @objc private func relaunchClicked() { onRelaunch?() }
    @objc private func doneClicked() { onDone?() }
}
