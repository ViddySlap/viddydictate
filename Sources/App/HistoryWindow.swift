import Cocoa
import QuartzCore
import AVFoundation

/// The dictation + clipboard history pane. Formerly its own menu-bar window; now embedded as the
/// Settings "History" tab. `makeEmbeddedView(size:)` builds the content (segmented Dictation/Clipboard
/// list + per-tab retention cap) for a host tab; the standalone window and its menu item are gone.
final class HistoryWindowController: NSObject, NSTextFieldDelegate {
    private enum Mode { case dictation, clipboard }

    /// The built content view; `hostWindow` resolves through it (used to drop the cap field's focus).
    private var contentView: NSView?
    private var hostWindow: NSWindow? { contentView?.window }
    private var scrollView: NSScrollView!
    private var doc: FlippedDoc!
    private var emptyLabel: NSTextField!
    private var clearButton: NSButton!
    // The retention-cap readout: "<count> of [cap] saved", where [cap] is an always-editable
    // bordered number field so the affordance is visible at rest.
    private var countContainer: NSView!
    private var countPrefixLabel: NSTextField!
    private var capField: NSTextField!
    private var countSuffixLabel: NSTextField!
    private var toast: NSTextField!
    private var segment: NSSegmentedControl!

    private var mode: Mode = .dictation
    private var dictationRows: [TranscriptionHistoryRowView] = []
    private var clipboardRows: [ClipboardHistoryRowView] = []
    private var transcriptionToken: NSObjectProtocol?
    private var clipboardToken: NSObjectProtocol?
    private var audioRetentionToken: NSObjectProtocol?
    private var lastWidth: CGFloat = -1

    /// Refresh the pane from the stores. Called when the Settings window is shown so the list is current
    /// even if it changed while Settings was closed (live observers keep it fresh while open).
    func refresh() { reload() }

    /// Build the history content view for embedding in a host tab (the Settings "History" tab), sized to
    /// `size` and autoresizing to fill it. Wires the same live observers + initial reload as the old window.
    func makeEmbeddedView(size: NSSize) -> NSView {
        let winSize = size

        let content = NSView(frame: NSRect(origin: .zero, size: winSize))
        content.autoresizingMask = [.width, .height]
        let barH: CGFloat = 52
        let bar = NSView(frame: NSRect(x: 0, y: winSize.height - barH, width: winSize.width, height: barH))
        bar.autoresizingMask = [.width, .minYMargin]

        clearButton = NSButton(title: "Clear history", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 16, y: (barH - 30) / 2, width: 126, height: 30)
        bar.addSubview(clearButton)

        segment = NSSegmentedControl(labels: ["Dictation", "Clipboard"],
                                     trackingMode: .selectOne,
                                     target: self,
                                     action: #selector(modeChanged))
        segment.selectedSegment = 0
        segment.frame = NSRect(x: (winSize.width - 210) / 2, y: (barH - 28) / 2, width: 210, height: 28)
        segment.autoresizingMask = [.minXMargin, .maxXMargin]
        bar.addSubview(segment)

        // Cap readout pinned to the bar's right edge: "<count> of [cap] saved". The cap is a small
        // bordered editable field so it visibly reads as editable; its contents are laid out
        // right-aligned inside a fixed-width container (so window resizing needs no relayout).
        let countW: CGFloat = 200
        countContainer = NSView(frame: NSRect(x: winSize.width - 16 - countW, y: 0, width: countW, height: barH))
        countContainer.autoresizingMask = [.minXMargin]

        countPrefixLabel = NSTextField(labelWithString: "")
        countPrefixLabel.font = .systemFont(ofSize: 11)
        countPrefixLabel.textColor = .secondaryLabelColor
        countContainer.addSubview(countPrefixLabel)

        capField = NSTextField()
        capField.font = .systemFont(ofSize: 11)
        capField.alignment = .center
        capField.isEditable = true
        capField.isSelectable = true
        capField.isBordered = true
        capField.bezelStyle = .roundedBezel
        capField.drawsBackground = true
        capField.delegate = self
        capField.toolTip = "How many items this tab keeps (\(Settings.historyMaxRange.lowerBound)-\(Settings.historyMaxRange.upperBound))"
        let capFmt = NumberFormatter()
        capFmt.numberStyle = .none
        capFmt.allowsFloats = false
        capFmt.minimum = NSNumber(value: Settings.historyMaxRange.lowerBound)
        capFmt.maximum = NSNumber(value: Settings.historyMaxRange.upperBound)
        capField.formatter = capFmt
        countContainer.addSubview(capField)

        countSuffixLabel = NSTextField(labelWithString: "saved")
        countSuffixLabel.font = .systemFont(ofSize: 11)
        countSuffixLabel.textColor = .secondaryLabelColor
        countContainer.addSubview(countSuffixLabel)

        bar.addSubview(countContainer)

        toast = NSTextField(labelWithString: "Copied to clipboard")
        toast.font = .systemFont(ofSize: 11, weight: .medium)
        toast.alignment = .center
        toast.textColor = .white
        toast.wantsLayer = true
        toast.drawsBackground = false
        toast.layer?.backgroundColor = Phosphor.themed(NSColor(srgbRed: 0, green: 0.55, blue: 0.22, alpha: 0.95)).cgColor
        toast.layer?.cornerRadius = 9
        toast.frame = NSRect(x: (winSize.width - 180) / 2, y: (barH - 22) / 2, width: 180, height: 22)
        toast.alphaValue = 0
        toast.isHidden = true
        toast.autoresizingMask = [.minXMargin, .maxXMargin]
        bar.addSubview(toast)
        content.addSubview(bar)

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: winSize.width, height: winSize.height - barH))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        doc = FlippedDoc(frame: NSRect(x: 0, y: 0, width: winSize.width, height: winSize.height - barH))
        scrollView.documentView = doc

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        doc.addSubview(emptyLabel)

        content.addSubview(scrollView)
        contentView = content

        transcriptionToken = NotificationCenter.default.addObserver(
            forName: TranscriptionHistory.didChange, object: nil, queue: .main) { [weak self] _ in
            if self?.mode == .dictation { self?.reload() }
        }
        clipboardToken = NotificationCenter.default.addObserver(
            forName: ClipboardHistory.didChange, object: nil, queue: .main) { [weak self] _ in
            if self?.mode == .clipboard { self?.reload() }
        }
        audioRetentionToken = NotificationCenter.default.addObserver(
            forName: AudioRetentionStore.didChange, object: nil, queue: .main) { [weak self] _ in
            if self?.mode == .dictation { self?.reload() }
        }

        reload()
        return content
    }

    deinit {
        if let t = transcriptionToken { NotificationCenter.default.removeObserver(t) }
        if let t = clipboardToken { NotificationCenter.default.removeObserver(t) }
        if let t = audioRetentionToken { NotificationCenter.default.removeObserver(t) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func modeChanged() {
        // Commit any in-progress cap edit (against the still-current tab) before switching.
        hostWindow?.makeFirstResponder(nil)
        mode = segment.selectedSegment == 1 ? .clipboard : .dictation
        reload()
    }

    // MARK: per-tab retention cap

    /// Render "<count> of [cap] saved". Skips overwriting the cap field while the user is editing it.
    private func updateCountGroup(count: Int, cap: Int) {
        countPrefixLabel.stringValue = "\(count) of"
        let editing = capField.currentEditor() != nil
        if !editing { capField.stringValue = "\(cap)" }
        layoutCountGroup()
    }

    /// Right-align the prefix label, cap field, and suffix label inside the fixed-width container.
    private func layoutCountGroup() {
        guard let container = countContainer else { return }
        let font = NSFont.systemFont(ofSize: 11)
        // +4px cushion so the last glyph (the 'f' in "of", the 'd' in "saved") never clips.
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) + 4 }
        let h: CGFloat = 20
        let labelY = (container.bounds.height - h) / 2
        // The rounded bezel renders its text a couple px lower than a borderless label at the same
        // frame, so nudge the box up to share the labels' baseline.
        let fieldY = labelY + 2
        let prefixW = width(countPrefixLabel.stringValue)
        let suffixW = width(countSuffixLabel.stringValue)
        let capW: CGFloat = 50
        let gap: CGFloat = 5
        let rightCushion: CGFloat = 4   // a little air before the container's right edge
        var x = container.bounds.width - rightCushion - (prefixW + gap + capW + gap + suffixW)
        countPrefixLabel.frame = NSRect(x: x, y: labelY, width: prefixW, height: h)
        x += prefixW + gap
        capField.frame = NSRect(x: x, y: fieldY, width: capW, height: h)
        x += capW + gap
        countSuffixLabel.frame = NSRect(x: x, y: labelY, width: suffixW, height: h)
    }

    /// Apply the typed cap to the current tab's store (clamp, persist, trim), then refresh.
    private func commitCap() {
        let current = mode == .dictation ? Settings.dictationHistoryMax : Settings.clipboardHistoryMax
        let typed = Int(capField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? current
        let clamped = min(Settings.historyMaxRange.upperBound,
                          max(Settings.historyMaxRange.lowerBound, typed))
        if clamped != current {
            if mode == .dictation { TranscriptionHistory.shared.setMaxEntries(clamped) }
            else { ClipboardHistory.shared.setMaxEntries(clamped) }
        }
        reload()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === capField else { return }
        commitCap()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === capField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc: revert to the stored cap and drop focus without applying.
            let cap = mode == .dictation ? Settings.dictationHistoryMax : Settings.clipboardHistoryMax
            capField.stringValue = "\(cap)"
            hostWindow?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func reload() {
        guard doc != nil else { return }
        dictationRows.forEach { $0.removeFromSuperview() }
        clipboardRows.forEach { $0.removeFromSuperview() }
        dictationRows = []
        clipboardRows = []

        switch mode {
        case .dictation:
            let entries = TranscriptionHistory.shared.all()
            dictationRows = entries.map { entry in
                let row = TranscriptionHistoryRowView(entry: entry)
                row.onToggle = { [weak self] in self?.relayout() }
                row.onCopied = { [weak self] in self?.flashToast("Copied to clipboard") }
                row.onPlaybackFailed = { [weak self] in self?.flashToast("Cannot play retained audio") }
                doc.addSubview(row)
                return row
            }
            emptyLabel.stringValue = "No transcriptions yet.\nDictations you record will show up here."
            emptyLabel.isHidden = !entries.isEmpty
            clearButton.isEnabled = !entries.isEmpty
            updateCountGroup(count: entries.count, cap: Settings.dictationHistoryMax)
        case .clipboard:
            let entries = ClipboardHistory.shared.all()
            clipboardRows = entries.map { entry in
                let row = ClipboardHistoryRowView(entry: entry)
                row.onToggle = { [weak self] in self?.relayout() }
                row.onCopied = { [weak self] ok in
                    self?.flashToast(ok ? "Restored to clipboard" : "Cannot restore item")
                }
                doc.addSubview(row)
                return row
            }
            emptyLabel.stringValue = "No clipboard items yet.\nCopied items will show up here while ViddyDictate is running."
            emptyLabel.isHidden = !entries.isEmpty
            clearButton.isEnabled = !entries.isEmpty
            updateCountGroup(count: entries.count, cap: Settings.clipboardHistoryMax)
        }
        relayout()
    }

    @objc private func viewportChanged() {
        guard let scrollView = scrollView else { return }
        if abs(scrollView.contentView.bounds.width - lastWidth) < 0.5 { return }
        relayout()
    }

    private func relayout() {
        guard let scrollView = scrollView else { return }
        let width = scrollView.contentView.bounds.width
        lastWidth = width
        var y: CGFloat = 0
        switch mode {
        case .dictation:
            for row in dictationRows {
                let h = row.layoutContents(width: width)
                row.frame = NSRect(x: 0, y: y, width: width, height: h)
                y += h
            }
        case .clipboard:
            for row in clipboardRows {
                let h = row.layoutContents(width: width)
                row.frame = NSRect(x: 0, y: y, width: width, height: h)
                y += h
            }
        }
        let docHeight = max(y, scrollView.contentView.bounds.height)
        doc.frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
        let isEmpty = mode == .dictation ? dictationRows.isEmpty : clipboardRows.isEmpty
        if isEmpty {
            emptyLabel.frame = NSRect(x: 20, y: docHeight / 2 - 34,
                                      width: max(width - 40, 0), height: 68)
        }
    }

    private func flashToast(_ message: String) {
        toast.stringValue = message
        toast.isHidden = false
        toast.alphaValue = 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideToast), object: nil)
        perform(#selector(hideToast), with: nil, afterDelay: 1.3)
    }

    @objc private func hideToast() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            toast.animator().alphaValue = 0
        } completionHandler: {
            self.toast.isHidden = true
        }
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = mode == .dictation ? "Clear dictation history?" : "Clear clipboard history?"
        alert.informativeText = "This permanently deletes the saved items in the current tab. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            mode == .dictation ? TranscriptionHistory.shared.clear() : ClipboardHistory.shared.clear()
        }
    }
}

private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

private class HistoryRowView: NSView {
    override var isFlipped: Bool { true }

    var expanded = false
    var onToggle: (() -> Void)?
    let textLabel = NSTextField(wrappingLabelWithString: "")

    let padX: CGFloat = 16
    let padTop: CGFloat = 12
    let padBottom: CGFloat = 14
    let headerH: CGFloat = 18
    let gap: CGFloat = 6
    let textFont = NSFont.systemFont(ofSize: 13)

    func applyFadeMask(active: Bool) {
        guard active else { textLabel.layer?.mask = nil; return }
        let mask = CAGradientLayer()
        mask.frame = textLabel.bounds
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        mask.locations = [0.0, 0.5, 1.0]
        textLabel.layer?.mask = mask
    }

    override func mouseDown(with event: NSEvent) {
        expanded.toggle()
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        HistoryFormat.drawSeparator(in: bounds, inset: padX)
    }
}

private final class TranscriptionHistoryRowView: HistoryRowView, AVAudioPlayerDelegate {
    private let entry: TranscriptionHistory.Entry

    var onCopied: (() -> Void)?
    var onPlaybackFailed: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")
    // Single "Copy" for Raw-mode entries; "Original" + "Cleaned" when both versions exist.
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let copyCleanedButton = NSButton(title: "Cleaned", target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private var player: AVAudioPlayer?
    private var showsBoth: Bool { entry.hasBothVersions }
    private var hasAudio: Bool { AudioRetentionStore.shared.recordingURL(for: entry.id) != nil }

    init(entry: TranscriptionHistory.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true

        timeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.stringValue = HistoryFormat.formatTimestamp(entry.date)
        addSubview(timeLabel)

        tagLabel.font = .systemFont(ofSize: 11)
        tagLabel.textColor = .tertiaryLabelColor
        tagLabel.lineBreakMode = .byTruncatingTail
        let modeTag = entry.hasBothVersions ? "cleaned" : nil
        let levelTag = entry.level.flatMap { CleanupLevel(rawValue: $0)?.label }
        let intoTag = entry.app.isEmpty ? nil : "into \(entry.app)"
        tagLabel.stringValue = [modeTag, levelTag, intoTag].compactMap { $0 }.joined(separator: " · ")
        addSubview(tagLabel)

        textLabel.font = textFont
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.stringValue = entry.text
        textLabel.wantsLayer = true
        textLabel.layer?.masksToBounds = true
        addSubview(textLabel)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.title = showsBoth ? "Original" : "Copy"
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        addSubview(copyButton)

        copyCleanedButton.bezelStyle = .rounded
        copyCleanedButton.controlSize = .small
        copyCleanedButton.font = .systemFont(ofSize: 11)
        copyCleanedButton.target = self
        copyCleanedButton.action = #selector(copyCleanedTapped)
        copyCleanedButton.isHidden = !showsBoth
        addSubview(copyCleanedButton)

        playButton.bezelStyle = .rounded
        playButton.controlSize = .small
        playButton.font = .systemFont(ofSize: 11)
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.toolTip = "Play the exact post-trim audio sent to transcription"
        playButton.isHidden = !hasAudio
        addSubview(playButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutContents(width: CGFloat) -> CGFloat {
        let copyH: CGFloat = 18
        let copyW: CGFloat = showsBoth ? 72 : 60
        var buttonsLeft: CGFloat
        if showsBoth {
            let x2 = width - padX - copyW
            let x1 = x2 - 6 - copyW
            copyButton.frame = NSRect(x: x1, y: padTop - 1, width: copyW, height: copyH)
            copyCleanedButton.frame = NSRect(x: x2, y: padTop - 1, width: copyW, height: copyH)
            buttonsLeft = x1
        } else {
            let x1 = width - padX - copyW
            copyButton.frame = NSRect(x: x1, y: padTop - 1, width: copyW, height: copyH)
            buttonsLeft = x1
        }
        if hasAudio {
            let playW: CGFloat = 64
            let playX = buttonsLeft - 6 - playW
            playButton.frame = NSRect(x: playX, y: padTop - 1, width: playW, height: copyH)
            playButton.isHidden = false
            buttonsLeft = playX
        } else {
            playButton.isHidden = true
        }
        timeLabel.frame = NSRect(x: padX, y: padTop, width: 150, height: headerH)
        let tagX = padX + 156
        tagLabel.frame = NSRect(x: tagX, y: padTop,
                                width: max((buttonsLeft - 8) - tagX, 0), height: headerH)

        let textW = max(width - 2 * padX, 1)
        let fullH = HistoryFormat.textHeight(entry.text, font: textFont, width: textW)
        let lineH = NSLayoutManager().defaultLineHeight(for: textFont)
        let collapsedH = ceil(lineH * 3)
        let overflowing = fullH > collapsedH + 1
        let shownH = expanded ? fullH : min(fullH, collapsedH)

        let textY = padTop + headerH + gap
        textLabel.frame = NSRect(x: padX, y: textY, width: textW, height: shownH)
        applyFadeMask(active: overflowing && !expanded)
        return textY + shownH + padBottom
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        let p = convert(point, from: sv)
        if copyButton.frame.contains(p) { return copyButton }
        if showsBoth && copyCleanedButton.frame.contains(p) { return copyCleanedButton }
        if !playButton.isHidden && playButton.frame.contains(p) { return playButton }
        return bounds.contains(p) ? self : nil
    }

    @objc private func playTapped() {
        if player?.isPlaying == true {
            player?.stop()
            player = nil
            playButton.title = "Play"
            return
        }
        guard let url = AudioRetentionStore.shared.recordingURL(for: entry.id) else {
            playButton.isHidden = true
            onPlaybackFailed?()
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            next.prepareToPlay()
            guard next.play() else { throw NSError(domain: "ViddyDictate.HistoryPlayback", code: 1) }
            player = next
            playButton.title = "Stop"
        } catch {
            player = nil
            playButton.title = "Play"
            Log.write("history audio playback failed take=\(entry.id.uuidString): \(error.localizedDescription)")
            onPlaybackFailed?()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playButton.title = "Play"
        if !flag { onPlaybackFailed?() }
    }

    @objc private func copyTapped() {
        // "Original" when both versions exist, else the plain delivered text.
        TargetResolver.copyToClipboard(entry.original)
        let restore = showsBoth ? "Original" : "Copy"
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = restore }
        onCopied?()
    }

    @objc private func copyCleanedTapped() {
        TargetResolver.copyToClipboard(entry.cleaned ?? entry.text)
        copyCleanedButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyCleanedButton.title = "Cleaned" }
        onCopied?()
    }

}

private final class ClipboardHistoryRowView: HistoryRowView {
    private let entry: ClipboardHistory.Entry

    var onCopied: ((Bool) -> Void)?

    private let timeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)

    init(entry: ClipboardHistory.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true

        timeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.stringValue = HistoryFormat.formatTimestamp(entry.date)
        addSubview(timeLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.stringValue = entry.detail
        addSubview(detailLabel)

        textLabel.font = textFont
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.stringValue = entry.preview
        textLabel.wantsLayer = true
        textLabel.layer?.masksToBounds = true
        addSubview(textLabel)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.isEnabled = !entry.snapshot.isEmpty
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutContents(width: CGFloat) -> CGFloat {
        let copyW: CGFloat = 60, copyH: CGFloat = 18
        copyButton.frame = NSRect(x: width - padX - copyW, y: padTop - 1, width: copyW, height: copyH)
        timeLabel.frame = NSRect(x: padX, y: padTop, width: 150, height: headerH)
        let detailX = padX + 156
        detailLabel.frame = NSRect(x: detailX, y: padTop,
                                   width: max((width - padX - copyW - 8) - detailX, 0), height: headerH)

        let textW = max(width - 2 * padX, 1)
        let fullH = HistoryFormat.textHeight(entry.preview, font: textFont, width: textW)
        let lineH = NSLayoutManager().defaultLineHeight(for: textFont)
        let collapsedH = ceil(lineH * 3)
        let overflowing = fullH > collapsedH + 1
        let shownH = expanded ? fullH : min(fullH, collapsedH)

        let textY = padTop + headerH + gap
        textLabel.frame = NSRect(x: padX, y: textY, width: textW, height: shownH)
        applyFadeMask(active: overflowing && !expanded)
        return textY + shownH + padBottom
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        let p = convert(point, from: sv)
        return copyButton.frame.contains(p) ? copyButton : (bounds.contains(p) ? self : nil)
    }

    @objc private func copyTapped() {
        let ok = ClipboardHistory.shared.copyToClipboard(entry)
        copyButton.title = ok ? "Copied" : "No data"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.title = "Copy" }
        onCopied?(ok)
    }

}

private enum HistoryFormat {
    static func textHeight(_ s: String, font: NSFont, width: CGFloat) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let rect = attr.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(rect.height)
    }

    static func formatTimestamp(_ date: Date) -> String {
        let now = Date()
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        if delta < 3600 {
            let mins = Int(delta / 60)
            return mins == 1 ? "1 min ago" : "\(mins) min ago"
        }
        let cal = Calendar.current
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"
        let time = tf.string(from: date)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        let df = DateFormatter()
        df.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now)
            ? "MMM d" : "MMM d, yyyy"
        return "\(df.string(from: date)) \(time)"
    }

    static func drawSeparator(in bounds: NSRect, inset: CGFloat) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset, y: bounds.maxY - 0.5))
        path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.maxY - 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
