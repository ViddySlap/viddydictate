import Cocoa
import AVFoundation

/// The Option+H pop-up (item 7): a borderless, non-activating panel beside the mouse pointer with
/// the last three dictations. Placement goes through ONE pure helper
/// (`RecentDictationsPlacement`); dismissal covers Close, Open History, a second Option+H (the
/// controller toggles it), Esc (local monitor while active, global otherwise), and a click outside
/// the panel (a global mouse-down monitor). Monitors are removed on every close. The panel never
/// touches `HotkeyMonitor` state and reads no HUD position preference.

enum RecentDictationsPlacement {
    /// Bottom-left of the panel at (pointer.x + 18, pointer.y - 18 - height); flipped to the LEFT
    /// of the pointer when it would pass the right edge, and ABOVE it when it would pass the bottom
    /// edge; then clamped inside `visibleFrame`.
    static func origin(for size: NSSize, pointer: NSPoint, in visibleFrame: NSRect) -> NSPoint {
        var x = pointer.x + 18
        var y = pointer.y - 18 - size.height
        if x + size.width > visibleFrame.maxX {
            x = pointer.x - 18 - size.width
        }
        if y < visibleFrame.minY {
            y = pointer.y + 18
        }
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}

struct CopyTitleToken {
    private(set) var latest = 0
    mutating func press() -> Int { latest += 1; return latest }
    func isCurrent(_ token: Int) -> Bool { token == latest }
}

final class RecentDictationsPanel: NSPanel {
    private let onOpenHistory: () -> Void
    private let container = NSView()
    private var rows: [RecentDictationsModel.Row] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    private static let panelWidth: CGFloat = 400
    private static let pad: CGFloat = 12
    private static let headerH: CGFloat = 30
    private static let rowH: CGFloat = 64
    private static let rowGap: CGFloat = 8
    private static let footerH: CGFloat = 26

    init(onOpenHistory: @escaping () -> Void) {
        self.onOpenHistory = onOpenHistory
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 120))
        contentView = root
        container.wantsLayer = true
        container.layer?.backgroundColor = Phosphor.panelBG.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Phosphor.green.withAlphaComponent(0.35).cgColor
        root.addSubview(container)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Show (or refresh-and-show) the pop-up beside the pointer.
    func show() {
        refresh()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = RecentDictationsPlacement.origin(for: frame.size, pointer: pointer, in: visible)
        setFrameOrigin(origin)
        orderFrontRegardless()
        installMonitors()
    }

    /// Remove every monitor and hide the panel. Called by every dismissal path and by the
    /// controller's second Option+H.
    func dismiss() {
        removeMonitors()
        orderOut(nil)
    }

    private func refresh() {
        container.subviews.forEach { $0.removeFromSuperview() }
        let transcripts = TranscriptionHistory.shared.all()
        let retained = AudioRetentionStore.shared.retainedTakes()
        rows = RecentDictationsModel.rows(
            transcripts: transcripts,
            retainedTakes: retained,
            hasAudio: { AudioRetentionStore.shared.recordingURL(for: $0) != nil })

        let title = NSTextField(labelWithString: "Recent dictations")
        title.font = NSFont(name: Phosphor.font, size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Phosphor.green
        title.frame = NSRect(x: Self.pad, y: Self.headerH - 22,
                             width: Self.panelWidth - 2 * Self.pad - 70, height: 18)
        container.addSubview(title)

        let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.controlSize = .small
        close.font = .systemFont(ofSize: 11)
        close.frame = NSRect(x: Self.panelWidth - Self.pad - 60, y: Self.headerH - 24, width: 60, height: 22)
        container.addSubview(close)

        var y = Self.headerH

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No dictations yet")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: Self.pad, y: y + 4, width: Self.panelWidth - 2 * Self.pad, height: 20)
            container.addSubview(empty)
            y += 40
        } else {
            for row in rows {
                let rowView = RecentDictationRowView(row: row, width: Self.panelWidth - 2 * Self.pad)
                rowView.frame = NSRect(x: Self.pad, y: y,
                                       width: Self.panelWidth - 2 * Self.pad, height: Self.rowH)
                rowView.onTranscribed = { [weak self] in self?.refresh() }
                container.addSubview(rowView)
                y += Self.rowH + Self.rowGap
            }
            y -= Self.rowGap
        }

        let openHistory = NSButton(title: "Open History", target: self, action: #selector(openHistoryTapped))
        openHistory.isBordered = false
        openHistory.font = .systemFont(ofSize: 12)
        openHistory.contentTintColor = Phosphor.green
        openHistory.frame = NSRect(x: Self.pad, y: y, width: 120, height: 20)
        container.addSubview(openHistory)

        let totalH = y + Self.footerH
        container.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: totalH)
        setContentSize(NSSize(width: Self.panelWidth, height: totalH))
    }

    @objc private func closeTapped() { dismiss() }

    @objc private func openHistoryTapped() {
        onOpenHistory()
        dismiss()
    }

    // MARK: monitors

    private func installMonitors() {
        removeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return }
            // Global monitors only observe; they cannot swallow the key.
            if event.keyCode == 53 { self.dismiss() }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if !self.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
        }
    }

    private func removeMonitors() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
    }
}

/// One row of the pop-up: preview label + Copy, Play/Stop (DISABLED, not hidden, when there is no
/// audio), and, on audio-only rows only, a Transcribe button that recovers the retained WAV.
private final class RecentDictationRowView: NSView, AVAudioPlayerDelegate {
    let row: RecentDictationsModel.Row
    var onTranscribed: (() -> Void)?

    private let previewLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let transcribeButton = NSButton(title: "Transcribe", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var player: AVAudioPlayer?
    private var copyToken = CopyTitleToken()

    init(row: RecentDictationsModel.Row, width: CGFloat) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Phosphor.cellOff.cgColor
        layer?.cornerRadius = 8

        previewLabel.stringValue = row.preview.replacingOccurrences(of: "\n", with: " ")
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2
        addSubview(previewLabel)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        addSubview(copyButton)

        playButton.bezelStyle = .rounded
        playButton.controlSize = .small
        playButton.font = .systemFont(ofSize: 11)
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.isEnabled = row.playEnabled
        addSubview(playButton)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        addSubview(statusLabel)

        if row.canTranscribe {
            transcribeButton.bezelStyle = .rounded
            transcribeButton.controlSize = .small
            transcribeButton.font = .systemFont(ofSize: 11)
            transcribeButton.target = self
            transcribeButton.action = #selector(transcribeTapped)
            addSubview(transcribeButton)
        }

        layout(width: width)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    private func layout(width: CGFloat) {
        let pad: CGFloat = 8
        var right = width - pad
        if row.canTranscribe {
            transcribeButton.frame = NSRect(x: right - 78, y: pad, width: 78, height: 20)
            right -= 84
        }
        playButton.frame = NSRect(x: right - 64, y: pad, width: 64, height: 20)
        right -= 70
        copyButton.frame = NSRect(x: right - 60, y: pad, width: 60, height: 20)
        right -= 68
        previewLabel.frame = NSRect(x: pad, y: pad, width: max(10, right - pad), height: 30)
        statusLabel.frame = NSRect(x: pad, y: 42, width: width - 2 * pad, height: 14)
    }

    @objc private func copyTapped() {
        TargetResolver.copyToClipboard(row.copyText)
        let token = copyToken.press()
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.copyToken.isCurrent(token) else { return }
            self.copyButton.title = "Copy"
        }
    }

    @objc private func playTapped() {
        if player?.isPlaying == true {
            player?.stop()
            player = nil
            playButton.title = "Play"
            return
        }
        guard let url = AudioRetentionStore.shared.recordingURL(for: row.id) else {
            playButton.isEnabled = false
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            next.prepareToPlay()
            guard next.play() else {
                throw NSError(domain: "ViddyDictate.RecentPlayback", code: 1)
            }
            player = next
            playButton.title = "Stop"
        } catch {
            player = nil
            playButton.title = "Play"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playButton.title = "Play"
    }

    @objc private func transcribeTapped() {
        transcribeButton.isEnabled = false
        statusLabel.isHidden = false
        statusLabel.stringValue = "Transcribing…"
        let takeID = row.id
        RetainedTakeRecovery().recover(takeID: takeID, retentionWasEnabled: true,
                                       stillCurrent: { true }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .recovered(let text):
                    TranscriptionHistory.shared.record(
                        delivered: text, raw: text, cleaned: nil,
                        mode: .raw, level: nil, app: "", id: takeID)
                    TranscriptionHistory.shared.flush()
                    self.onTranscribed?()
                case .unavailable(let reason):
                    self.transcribeButton.isEnabled = true
                    self.statusLabel.isHidden = false
                    self.statusLabel.stringValue = reason
                }
            }
        }
    }
}
