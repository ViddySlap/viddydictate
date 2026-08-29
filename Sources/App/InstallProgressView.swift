import Cocoa

/// B7's progress display, drawn.
///
/// It holds no judgement and measures nothing. `InstallProgressState` decides what each row says and
/// how fast bytes are arriving; this turns that into labels.
///
/// Two styles, one view, because they are the same readout at two sizes and B19 needs both at once:
/// `.full` is the list from B7, and `.strip` is that list compressed to the running row plus the
/// total, which is what sits along the bottom of the permissions screen. Building them as two views
/// is how the strip ends up saying something the list does not.
final class InstallProgressView: NSView {
    enum Style {
        case full
        case strip
    }

    override var isFlipped: Bool { true }

    /// B10's Retry, on the row that failed. The view performs nothing: the host re-enters the same
    /// queue, so a retry is the installer running again rather than a second recovery path.
    var onRetry: ((ComponentPicker.RowID) -> Void)?

    private let style: Style
    private let W: CGFloat
    private let L: CGFloat = 20
    private let statusColumn: CGFloat = 170

    private var rows: [InstallProgress.Row]
    private var aggregate: InstallProgress.Aggregate

    init(width: CGFloat = 620, style: Style = .full,
         rows: [InstallProgress.Row] = [],
         aggregate: InstallProgress.Aggregate = InstallProgress.aggregate([])) {
        self.W = width
        self.style = style
        self.rows = rows
        self.aggregate = aggregate
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier(
            style == .full ? InstallProgress.surfaceIdentifier : PermissionsScreen.stripIdentifier)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    @discardableResult
    func apply(_ state: InstallProgressState) -> CGFloat {
        apply(rows: state.rows, aggregate: state.aggregate)
    }

    @discardableResult
    func apply(rows: [InstallProgress.Row], aggregate: InstallProgress.Aggregate) -> CGFloat {
        self.rows = rows
        self.aggregate = aggregate
        rebuild()
        return frame.height
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        switch style {
        case .full: buildFull()
        case .strip: buildStrip()
        }
    }

    private func buildFull() {
        let contentW = W - L - 20
        var y: CGFloat = 0

        let headline = SettingsSectionKit.label(InstallProgress.headline, x: L, y: y, width: contentW,
                                                size: 19, weight: .semibold, color: .labelColor)
        headline.frame.size.height = 26
        headline.identifier = NSUserInterfaceItemIdentifier(InstallProgress.headlineIdentifier)
        addSubview(headline)
        y = headline.frame.maxY + 6

        let note = SettingsSectionKit.wrapped(InstallProgress.dismissNote, x: L, y: y, width: contentW,
                                              size: 11, color: .secondaryLabelColor)
        note.identifier = NSUserInterfaceItemIdentifier(InstallProgress.dismissNoteIdentifier)
        addSubview(note)
        y = note.frame.maxY + 16

        for row in rows { y = addRow(row, at: y, width: contentW) + 6 }

        y += 8
        let line = NSBox(frame: NSRect(x: L, y: y, width: contentW, height: 1))
        line.boxType = .separator
        addSubview(line)
        y += 14

        y = addTotals(at: y, width: contentW, size: 13)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y + 18)
    }

    /// One component: its name, and what it is doing. B7's list is deliberately this plain - the row
    /// IS the progress, so there is nothing else on it to read.
    private func addRow(_ row: InstallProgress.Row, at originY: CGFloat, width: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(frame: NSRect(x: L, y: originY, width: width, height: 0),
                                           identifier: InstallProgress.rowIdentifier(row.id))
        addSubview(card)

        var y: CGFloat = 10
        let titleW = width - statusColumn - 28
        let title = SettingsSectionKit.label(row.title, x: 14, y: y, width: titleW, size: 12.5,
                                             weight: .semibold, color: titleColor(row))
        title.identifier = NSUserInterfaceItemIdentifier(
            InstallProgress.identifier(.title, row.id))
        card.addSubview(title)

        let status = SettingsSectionKit.label(InstallProgress.statusText(row),
                                              x: width - statusColumn - 14, y: y + 1,
                                              width: statusColumn, size: 11.5, weight: .medium,
                                              color: statusColor(row))
        status.alignment = .right
        status.identifier = NSUserInterfaceItemIdentifier(
            InstallProgress.identifier(.status, row.id))
        card.addSubview(status)
        y += 21

        // B10: the failed row shows the vendor's own words. A stranger who reads "Could not resolve
        // huggingface.co" checks their wifi; a stranger who reads "Setup failed" files an issue.
        if row.phase == .failed {
            if let message = row.failureMessage, !message.isEmpty {
                let field = SettingsSectionKit.wrapped(message, x: 14, y: y, width: width - 28,
                                                       size: 10.5, color: .systemRed)
                field.identifier = NSUserInterfaceItemIdentifier(InstallProgress.failureIdentifier)
                field.toolTip = message
                card.addSubview(field)
                y += field.frame.height + 5
            }
            // B10 names this button explicitly, and it is the difference between an error the user can
            // act on and one they can only read. Only ever on the row that failed - the siblings kept
            // going and have nothing to retry.
            let retry = NSButton(title: InstallProgress.retryTitle, target: self,
                                 action: #selector(retryClicked(_:)))
            retry.bezelStyle = .rounded
            retry.font = .systemFont(ofSize: 11)
            retry.tag = tag(for: row.id)
            retry.frame = NSRect(x: 14, y: y, width: 80, height: 22)
            retry.identifier = NSUserInterfaceItemIdentifier(InstallProgress.retryIdentifier(row.id))
            card.addSubview(retry)
            y += 26
        }

        card.frame.size.height = y + 8
        return card.frame.maxY
    }

    /// The bottom of B7's block: the bar, `1.4 GB of 2.1 GB`, and a speed. Never a time.
    private func addTotals(at originY: CGFloat, width: CGFloat, size: CGFloat) -> CGFloat {
        var y = originY

        let bar = NSProgressIndicator(frame: NSRect(x: L, y: y, width: width, height: 6))
        bar.isIndeterminate = false
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = aggregate.bytesExpected == 0 ? 0
            : Double(aggregate.bytesCompleted) / Double(aggregate.bytesExpected)
        bar.identifier = NSUserInterfaceItemIdentifier(InstallProgress.barIdentifier)
        addSubview(bar)
        y = bar.frame.maxY + 10

        // The total and the speed are two labels, not one string, so the speed can disappear the moment
        // nothing is running without the total reflowing under it.
        let speed = InstallProgress.speedLine(aggregate)
        let speedW: CGFloat = speed == nil ? 0 : 110
        let total = SettingsSectionKit.label(InstallProgress.totalLine(aggregate), x: L, y: y,
                                             width: width - speedW - 8, size: size, weight: .medium,
                                             color: .labelColor)
        total.identifier = NSUserInterfaceItemIdentifier(InstallProgress.totalIdentifier)
        addSubview(total)

        if let speed {
            let field = SettingsSectionKit.label(speed, x: L + width - speedW, y: y, width: speedW,
                                                 size: size, weight: .regular,
                                                 color: .secondaryLabelColor)
            field.alignment = .right
            field.identifier = NSUserInterfaceItemIdentifier(InstallProgress.speedIdentifier)
            addSubview(field)
        }
        return total.frame.maxY
    }

    /// The strip B19 puts along the bottom of the permissions screen: what is happening right now, and
    /// the same total. It names the running row, because "1.4 GB of 2.1 GB" alone does not tell the
    /// user which part of their app is arriving.
    private func buildStrip() {
        let contentW = W - L - 20
        var y: CGFloat = 12

        let line = NSBox(frame: NSRect(x: L, y: 0, width: contentW, height: 1))
        line.boxType = .separator
        addSubview(line)

        let running = rows.first { $0.phase == .running }
        let failed = rows.first { $0.phase == .failed }
        let caption: String
        let captionColor: NSColor
        if let failed {
            caption = "\(failed.title): \(InstallProgress.statusText(failed))"
            captionColor = .systemRed
        } else if let running {
            caption = "\(running.title)  \(InstallProgress.statusText(running))"
            captionColor = .secondaryLabelColor
        } else if rows.allSatisfy({ $0.phase == .done }) && !rows.isEmpty {
            caption = "Everything you picked is installed."
            captionColor = .secondaryLabelColor
        } else {
            caption = "Starting the download."
            captionColor = .secondaryLabelColor
        }

        let field = SettingsSectionKit.label(caption, x: L, y: y, width: contentW, size: 11.5,
                                             weight: .medium, color: captionColor)
        field.identifier = NSUserInterfaceItemIdentifier(
            InstallProgress.identifier(.status, running?.id ?? failed?.id ?? .transcriptionEngine))
        addSubview(field)
        y = field.frame.maxY + 8

        y = addTotals(at: y, width: contentW, size: 11.5)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y + 14)
    }

    private func tag(for id: ComponentPicker.RowID) -> Int {
        (ComponentPicker.RowID.allCases.firstIndex(of: id) ?? 0) + 1
    }

    @objc private func retryClicked(_ sender: NSButton) {
        let index = sender.tag - 1
        guard ComponentPicker.RowID.allCases.indices.contains(index) else { return }
        onRetry?(ComponentPicker.RowID.allCases[index])
    }

    private func titleColor(_ row: InstallProgress.Row) -> NSColor {
        switch row.phase {
        case .waiting: return .secondaryLabelColor
        case .running, .done, .failed: return .labelColor
        }
    }

    private func statusColor(_ row: InstallProgress.Row) -> NSColor {
        switch row.phase {
        case .waiting: return .tertiaryLabelColor
        case .running: return .labelColor
        case .done: return Phosphor.green
        case .failed: return .systemRed
        }
    }
}
