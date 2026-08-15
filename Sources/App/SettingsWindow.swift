import Cocoa

/// Flipped container so we can lay out top-to-bottom with increasing y.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// L9 merged Models into Hotkeys, as L3 merged Display into Appearance: one hotkey, one card, chord and
/// routing together. Nothing was dropped in either merge — only regrouped.
enum SettingsTab: String, CaseIterable {
    case setup = "Setup"
    case hotkeys = "Hotkeys"
    case stickySkills = "Sticky Skills"
    case audio = "Audio"
    case appearance = "Appearance"
    case dictionary = "Dictionary"
    case history = "History"
    case notes = "Notes"
}

/// The settings panel: three meter sliders with a live mic preview, and the transcription toggle.
/// Opened from the menu-bar "Settings…" item or the gear on the HUD.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var tabView: NSTabView?

    // Live preview meter (its own recorder so it never touches the dictation recorder's buffer).
    private let previewRecorder = AudioRecorder()
    private let previewWave = WaveformView(frame: .zero)
    private var previewing = false

    private var micPopup: NSPopUpButton!
    private var sensitivity: NSSlider!
    private var gain: NSSlider!
    private var reactivity: NSSlider!
    private var sensitivityVal: NSTextField!
    private var gainVal: NSTextField!
    private var reactivityVal: NSTextField!
    private var reduceSwitch: NSSwitch!
    private var retainAudioSwitch: NSSwitch!
    private var keepHistorySwitch: NSSwitch!
    private var positionPopup: NSPopUpButton!

    /// Invoked when Power Mode flips, so the menubar checkmark stays in sync.
    var onPowerModeChanged: (() -> Void)?

    /// Hotkey-rebinding plumbing: the Hotkeys tab arms/cancels capture in the live tap and reports
    /// persisted changes, all routed through the controller (which owns the tap). Wired by AppDelegate.
    var onBeginHotkeyCapture: ((@escaping (KeySpec) -> Void, @escaping () -> Void) -> Void)?
    var onCancelHotkeyCapture: (() -> Void)?
    var onHotkeysChanged: (() -> Void)?

    private var dictationToken: NSObjectProtocol?
    private var retryToken: NSObjectProtocol?
    private let contentWidth: CGFloat = 640
    private weak var modelsPowerView: ModelsPowerSettingsView?
    private weak var stickySkillsView: StickySkillsSettingsView?
    private weak var setupView: SetupSettingsView?
    private weak var powerView: PowerSettingsView?
    /// One flow for getting a provider connected (Public V1 spec W4, item P9), shared by the Setup tab's
    /// per-provider sign-in buttons - both of them, since L4 moved Codex's here - and the Hotkeys tab's
    /// inline rescue (D6). The first-run window owns a second presenter only because it outlives no window
    /// this controller has; it drives the same `ProviderSignInPresenter` type.
    private let providerSignIn = ProviderSignInPresenter()
    private let retryConfirmationPresenter = RetryConfirmationPresenter()
    /// The embedded History pane (dictation + clipboard). Formerly a standalone window + menu item;
    /// now hosted as the "History" tab. Built once when the tab view is assembled.
    private let historyPane = HistoryWindowController()

    override init() {
        super.init()
        previewRecorder.captureSamples = false
        previewWave.samplesProvider = { [weak self] in self?.previewRecorder.scopeSamples ?? [] }
        // queue: nil = deliver synchronously on the poster's (main) thread, so the preview mic is
        // released BEFORE the dictation recorder starts its own input tap (no two-engine race).
        dictationToken = NotificationCenter.default.addObserver(
            forName: Settings.dictationActive, object: nil, queue: nil) { [weak self] note in
            guard let self = self else { return }
            let active = (note.object as? NSNumber)?.boolValue ?? false
            // Release the mic while a real dictation runs; resume when it ends if still visible.
            if active { self.stopPreview() }
            else if self.window?.isVisible == true { self.startPreview() }
        }
        retryToken = NotificationCenter.default.addObserver(
            forName: TextTransformRetryCenter.didChange,
            object: TextTransformRetryCenter.shared, queue: .main) { [weak self] _ in
                self?.retryConfirmationPresenter.syncPendingRetry()
            }
        // A sign-in attempt is never assumed to have worked: when the flow returns, the surface re-MEASURES.
        providerSignIn.onFinished = { [weak self] in self?.setupView?.check() }
    }
    deinit {
        if let t = dictationToken { NotificationCenter.default.removeObserver(t) }
        if let t = retryToken { NotificationCenter.default.removeObserver(t) }
    }

    // MARK: show

    func show(tab: SettingsTab? = nil) {
        if window == nil { build() }
        if let tab {
            tabView?.selectTabViewItem(withIdentifier: tab.rawValue)
        }
        populateMicPopup()   // refresh the device list each open (a mic may have been (un)plugged)
        historyPane.refresh()   // pull any dictations/clips added while Settings was closed
        // Preflight is re-runnable by contract (W5): every open measures the machine again rather than
        // showing whatever was true the first time Settings was built.
        setupView?.check()
        modelsPowerView?.refresh()
        modelsPowerView?.refreshAvailableLocalModels()
        stickySkillsView?.refresh()
        stickySkillsView?.refreshAvailableLocalModels()
        powerView?.refresh()
        CodexConnectionController.shared.refreshAvailability()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Don't grab the mic if a dictation is already running; the observer resumes it on end.
        if !Settings.isDictationActive { startPreview() }
    }

    private func startPreview() {
        guard !previewing else { return }
        do { try previewRecorder.start(); previewWave.start(); previewing = true }
        catch { Log.write("settings preview mic start failed: \(error.localizedDescription)") }
    }
    private func stopPreview() {
        guard previewing else { return }
        previewWave.stop(); previewRecorder.stop(); previewing = false
    }

    func windowWillClose(_ notification: Notification) {
        stopPreview()
        CodexConnectionController.shared.cancelDeviceLogin()
        // The wait sheet dies with its host window, so the poll behind it has to stop too rather than keep
        // spawning a status check every two seconds for the rest of its 15-minute bound.
        ClaudeConnectionController.shared.cancelSignIn()
        onCancelHotkeyCapture?()   // never leave the tap armed for capture after the window closes
    }

    // MARK: build

    private func build() {
        let WIN = NSSize(width: 700, height: 680)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: WIN),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "ViddyDictate Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: WIN))   // non-flipped: bottom-origin chrome

        let tabView = NSTabView(frame: NSRect(x: 10, y: 50, width: WIN.width - 20, height: WIN.height - 62))
        tabView.autoresizingMask = [.width, .height]
        // Setup leads: it is the tab that tells a half-installed machine what is wrong, so burying it
        // behind the others would defeat the point of a self-diagnosing install (W5).
        for tab in SettingsTab.allCases {
            let content: NSView
            switch tab {
            case .setup: content = scrollWrap(buildSetupContent())
            case .hotkeys: content = scrollWrap(buildHotkeysContent())
            case .stickySkills: content = scrollWrap(buildStickySkillsContent())
            case .audio: content = scrollWrap(buildAudioContent())
            case .appearance: content = scrollWrap(buildAppearanceContent())
            case .dictionary: content = scrollWrap(buildDictionaryContent())
            // History manages its own internal scrolling, so it is embedded directly (no scrollWrap).
            case .history: content = buildHistoryContent()
            case .notes: content = scrollWrap(buildNotesContent())
            }
            tabView.addTabViewItem(tabItem(tab.rawValue, content))
        }
        root.addSubview(tabView)
        self.tabView = tabView

        let reset = NSButton(title: "Reset audio defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 14, y: 12, width: 170, height: 30)
        root.addSubview(reset)

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: WIN.width - 14 - 90, y: 12, width: 90, height: 30)
        root.addSubview(done)

        w.contentView = root
        window = w
        refreshValueLabels()
    }

    // MARK: tab scaffolding

    private func tabItem(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    /// Wrap a (flipped, content-height-sized) view in a vertically-scrolling, transparent scroll view
    /// that fills the tab content area.
    private func scrollWrap(_ content: NSView) -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth + 30, height: 480))
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        sv.autoresizingMask = [.width, .height]
        sv.documentView = content
        return sv
    }

    /// The consolidated Hotkeys tab (L9): the binding page and the routing page composed into one scroll
    /// document, sharing `CustomModeStore.shared`, so every hotkey's chord and its provider/model/effort/
    /// prompt are edited in the same card without leaving the tab.
    private func buildHotkeysContent() -> NSView {
        let v = HotkeysSettingsView(width: contentWidth)
        v.beginCapture = { [weak self] onCap, onCancel in self?.onBeginHotkeyCapture?(onCap, onCancel) }
        v.cancelCapture = { [weak self] in self?.onCancelHotkeyCapture?() }
        v.onChanged = { [weak self] in self?.onHotkeysChanged?() }
        return HotkeysTabView(hotkeys: v, routing: buildModelsPowerContent())
    }

    private func buildSetupContent() -> NSView {
        let v = SetupSettingsView(width: contentWidth)
        v.onConnect = { [weak self] provider in
            guard let self else { return }
            self.providerSignIn.begin(provider, in: self.window)
        }
        setupView = v
        return v
    }

    private func buildStickySkillsContent() -> NSView {
        let view = StickySkillsSettingsView(width: contentWidth)
        stickySkillsView = view
        return view
    }

    /// The routing half of the Hotkeys tab. Kept a builder of its own: every wire it owns — the shared
    /// sign-in presenter, the retry presenter, the weak ref `show()` re-measures through — survives the
    /// merge unchanged, and the surface is still constructible on its own for probes and renders.
    private func buildModelsPowerContent() -> ModelsPowerSettingsView {
        let v = ModelsPowerSettingsView(width: contentWidth)
        // D6: the inline rescue enters the SAME presenter the Setup tab does, for either provider. One
        // `providerSignIn` object serves both tabs, so there is no second connect implementation to keep in
        // step with this one.
        v.onConnectProvider = { [weak self] provider in
            guard let self else { return }
            self.providerSignIn.begin(provider, in: self.window)
        }
        v.onRetry = { [weak self] route, provider in
            guard let self else { return }
            self.retryConfirmationPresenter.present(
                route: route, failedProvider: provider, in: self.window)
        }
        modelsPowerView = v
        retryConfirmationPresenter.bind(v)
        return v
    }

    private func buildDictionaryContent() -> NSView {
        DictionarySettingsView(width: contentWidth)
    }

    private func buildNotesContent() -> NSView {
        NotesSettingsView(width: contentWidth)
    }

    private func buildHistoryContent() -> NSView {
        historyPane.makeEmbeddedView(size: NSSize(width: contentWidth, height: 500))
    }

    /// The Audio tab content (the former flat window: mic + meter + transcription + history), laid out
    /// top-to-bottom in a flipped view sized to its content.
    private func buildAudioContent() -> NSView {
        let AW = contentWidth
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: AW, height: 420))
        let L: CGFloat = 20, labelW: CGFloat = 92
        let sliderX: CGFloat = 116, sliderW: CGFloat = AW - sliderX - 72
        let valX: CGFloat = AW - 72, valW: CGFloat = 64
        let WIN = NSSize(width: AW, height: 420)

        root.addSubview(sectionHeader("METER", y: 16))

        // Microphone picker (option 0 = follow the system default; below it each input device by name).
        // Sits atop the METER block — the meter below previews the chosen mic. Shifts the rest of the
        // block down by `dy`.
        root.addSubview(plainLabel("Microphone", x: L, y: 45, w: labelW, bold: false))
        micPopup = NSPopUpButton(frame: NSRect(x: sliderX, y: 42, width: WIN.width - sliderX - L, height: 25),
                                 pullsDown: false)
        micPopup.target = self
        micPopup.action = #selector(micChanged)
        root.addSubview(micPopup)
        populateMicPopup()
        // Interop callout (ADR 0004, L3): local voice integrations follow this pin read-only through
        // shared defaults. ViddyDictate remains the only writer.
        root.addSubview(hint("Available read-only to local voice integrations.",
                             y: 68, width: WIN.width - 2 * L, x: L))

        let dy: CGFloat = 58   // vertical shift applied to the meter rows below the mic picker + interop callout

        sensitivity = slider(at: 44 + dy, value: Settings.sensitivity, action: #selector(metersChanged),
                             label: "Sensitivity", L: L, labelW: labelW, sx: sliderX, sw: sliderW, into: root)
        sensitivityVal = valueLabel(at: 44 + dy, x: valX, w: valW, into: root)

        gain = slider(at: 74 + dy, value: Settings.gain, action: #selector(metersChanged),
                      label: "Gain", L: L, labelW: labelW, sx: sliderX, sw: sliderW, into: root)
        gainVal = valueLabel(at: 74 + dy, x: valX, w: valW, into: root)

        reactivity = slider(at: 104 + dy, value: Settings.reactivity, action: #selector(metersChanged),
                            label: "Reactivity", L: L, labelW: labelW, sx: sliderX, sw: sliderW, into: root)
        reactivityVal = valueLabel(at: 104 + dy, x: valX, w: valW, into: root)

        // live preview box
        let box = NSView(frame: NSRect(x: L, y: 138 + dy, width: WIN.width - 2 * L, height: 60))
        box.wantsLayer = true
        box.layer?.backgroundColor = Phosphor.panelBG.withAlphaComponent(0.85).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Phosphor.green.withAlphaComponent(0.18).cgColor
        previewWave.frame = box.bounds
        previewWave.autoresizingMask = [.width, .height]
        box.addSubview(previewWave)
        root.addSubview(box)
        root.addSubview(hint("Speak to test the meter — adjust the sliders until it moves the way you like.",
                             y: 202 + dy, width: WIN.width - 2 * L, x: L))

        root.addSubview(sectionHeader("TRANSCRIPTION", y: 240 + dy))
        reduceSwitch = NSSwitch(frame: NSRect(x: L, y: 264 + dy, width: 40, height: 22))
        reduceSwitch.state = Settings.reduceRepeats ? .on : .off
        reduceSwitch.target = self
        reduceSwitch.action = #selector(toggleReduce)
        root.addSubview(reduceSwitch)
        root.addSubview(plainLabel("Reduce repeated-word hallucinations", x: L + 52, y: 266 + dy, w: WIN.width - L - 52 - L, bold: true))
        root.addSubview(hint("Turns off Whisper's condition-on-previous-text and cleans repeated / end-of-clip garbage before pasting.",
                             y: 290 + dy, width: WIN.width - 2 * L, x: L))

        root.addSubview(hint("Hotkeys — and the provider, model, effort and prompt each one runs — are editable on the Hotkeys tab; correction words on the Dictionary tab; past transcriptions on the History tab.",
                             y: 330 + dy, width: WIN.width - 2 * L, x: L))

        // The exact post-trim WAV sent to Whisper is retained locally under the same take UUID History
        // stores. ON by default so a future hallucination investigation has evidence; the user can stop new
        // retention or purge the ring without deleting any transcript rows.
        root.addSubview(sectionHeader("RECORDING DIAGNOSTICS", y: 382 + dy))
        retainAudioSwitch = NSSwitch(frame: NSRect(x: L, y: 406 + dy, width: 40, height: 22))
        retainAudioSwitch.state = Settings.retainDictationAudio ? .on : .off
        retainAudioSwitch.target = self
        retainAudioSwitch.action = #selector(toggleRetainAudio)
        root.addSubview(retainAudioSwitch)
        root.addSubview(plainLabel("Retain recent dictation audio", x: L + 52, y: 408 + dy,
                                   w: 270, bold: true))
        let purgeAudio = NSButton(title: "Delete retained audio…", target: self,
                                  action: #selector(purgeRetainedAudio))
        purgeAudio.bezelStyle = .rounded
        purgeAudio.frame = NSRect(x: WIN.width - L - 184, y: 402 + dy, width: 184, height: 30)
        root.addSubview(purgeAudio)
        root.addSubview(hint("Keeps only the 100 newest final takes in Application Support/"
            + "ViddyDictate/recordings. Files never leave this Mac; History rows with audio get a Play button.",
                             y: 438 + dy, width: WIN.width - 2 * L, x: L))

        // FULL HISTORY (L4): opt-in infinite per-day dictation log, separate from the rolling
        // "Past Transcriptions" window above. The hint says where the data lives (app-local, outside the
        // vaults) and that local search tools can read it.
        root.addSubview(sectionHeader("FULL HISTORY", y: 500 + dy))
        keepHistorySwitch = NSSwitch(frame: NSRect(x: L, y: 524 + dy, width: 40, height: 22))
        keepHistorySwitch.state = Settings.keepFullHistory ? .on : .off
        keepHistorySwitch.target = self
        keepHistorySwitch.action = #selector(toggleKeepHistory)
        root.addSubview(keepHistorySwitch)
        root.addSubview(plainLabel("Keep full dictation history", x: L + 52, y: 526 + dy, w: WIN.width - L - 52 - L, bold: true))
        let historyHint = NSTextField(wrappingLabelWithString:
            "When on, every dictation (all modes) is appended forever to a private per-day log at "
            + "~/Library/Application Support/ViddyDictate/history. That folder is outside your Obsidian "
            + "vaults and never synced; local tools can search this history. Off by default; the "
            + "\"Past Transcriptions\" list above is unaffected.")
        historyHint.font = .systemFont(ofSize: 10.5)
        historyHint.textColor = .tertiaryLabelColor
        historyHint.frame = NSRect(x: L, y: 550 + dy, width: WIN.width - 2 * L, height: 72)
        root.addSubview(historyHint)

        let finalH: CGFloat = 634 + dy   // content height for the scroll document view
        root.frame = NSRect(x: 0, y: 0, width: WIN.width, height: finalH)
        return root
    }

    /// The former Display page, now the leading group on Appearance: HUD placement and the independent
    /// Live / Final-only presentation choice. It stays a child view so both former pages retain every
    /// control while the combined document view owns only their vertical composition.
    private func buildDisplayContent() -> NSView {
        let AW = contentWidth
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: AW, height: 10))
        let L: CGFloat = 20

        root.addSubview(sectionHeader("HUD", y: 16))
        let card = SettingsSectionKit.card(
            frame: NSRect(x: L, y: 38, width: AW - 2 * L, height: 86),
            identifier: "card.appearance-hud")
        root.addSubview(card)
        card.addSubview(plainLabel("Position", x: 14, y: 13, w: 82, bold: false))
        positionPopup = NSPopUpButton(frame: NSRect(x: 96, y: 8, width: card.bounds.width - 110, height: 25),
                                      pullsDown: false)
        positionPopup.identifier = NSUserInterfaceItemIdentifier("hud-position")
        for pos in HUDPosition.allCases {
            positionPopup.addItem(withTitle: pos.label)
            positionPopup.lastItem?.representedObject = pos.rawValue
        }
        if let item = positionPopup.itemArray.first(where: {
            ($0.representedObject as? String) == Settings.hudPosition.rawValue
        }) { positionPopup.select(item) }
        positionPopup.target = self
        positionPopup.action = #selector(positionChanged)
        card.addSubview(positionPopup)
        card.addSubview(hint("Where the dictation popup appears on screen — applies to the full HUD and the Final-only pill. Dragging it moves it for that take only.",
                             y: 42, width: card.bounds.width - 28, x: 14))

        let powerY = card.frame.maxY + 14
        let pv = PowerSettingsView(width: AW)
        pv.onPowerModeChanged = { [weak self] in self?.onPowerModeChanged?() }
        pv.frame.origin = NSPoint(x: 0, y: powerY)
        powerView = pv
        root.addSubview(pv)

        root.frame = NSRect(x: 0, y: 0, width: AW, height: powerY + pv.frame.height)
        return root
    }

    /// One scroll document for the two former adjacent tabs. The child views keep ownership of their
    /// controls and actions; this view only stacks them so nothing is deleted or rewired by consolidation.
    private func buildAppearanceContent() -> NSView {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 10))
        let display = buildDisplayContent()
        display.identifier = NSUserInterfaceItemIdentifier("appearance-display-groups")
        display.frame.origin = .zero
        root.addSubview(display)

        let appearance = AppearanceSettingsView(width: contentWidth)
        appearance.identifier = NSUserInterfaceItemIdentifier("appearance-theme-groups")
        appearance.frame.origin = NSPoint(x: 0, y: display.frame.maxY + 8)
        root.addSubview(appearance)
        root.frame.size.height = appearance.frame.maxY
        return root
    }

    // MARK: builders

    private func sectionHeader(_ s: String, y: CGFloat) -> NSTextField {
        SettingsSectionKit.sectionHeader(s, x: 20, y: y, width: contentWidth - 40)
    }

    private func plainLabel(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, bold: Bool) -> NSTextField {
        SettingsSectionKit.label(
            s, x: x, y: y, width: w, size: 12,
            weight: bold ? .medium : .regular, color: .labelColor)
    }

    private func hint(_ s: String, y: CGFloat, width: CGFloat, x: CGFloat) -> NSTextField {
        let field = SettingsSectionKit.wrapped(
            s, x: x, y: y, width: width, size: 10.5, color: .tertiaryLabelColor)
        field.frame.size.height = max(30, field.frame.height)
        return field
    }

    private func slider(at y: CGFloat, value: Float, action: Selector, label: String,
                        L: CGFloat, labelW: CGFloat, sx: CGFloat, sw: CGFloat, into root: NSView) -> NSSlider {
        root.addSubview(plainLabel(label, x: L, y: y + 1, w: labelW, bold: false))
        let s = NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: self, action: action)
        s.frame = NSRect(x: sx, y: y, width: sw, height: 20)
        s.isContinuous = true
        root.addSubview(s)
        return s
    }

    private func valueLabel(at y: CGFloat, x: CGFloat, w: CGFloat, into root: NSView) -> NSTextField {
        let t = NSTextField(labelWithString: "")
        t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        t.textColor = .secondaryLabelColor
        t.alignment = .right
        t.frame = NSRect(x: x, y: y + 1, width: w, height: 16)
        root.addSubview(t)
        return t
    }

    // MARK: actions

    @objc private func metersChanged() {
        Settings.sensitivity = Float(sensitivity.doubleValue)
        Settings.gain = Float(gain.doubleValue)
        Settings.reactivity = Float(reactivity.doubleValue)
        refreshValueLabels()
    }

    @objc private func toggleReduce() { Settings.reduceRepeats = (reduceSwitch.state == .on) }

    @objc private func toggleRetainAudio() {
        Settings.retainDictationAudio = (retainAudioSwitch.state == .on)
        Log.write("settings: retain-dictation-audio -> \(Settings.retainDictationAudio ? "ON" : "OFF")")
    }

    @objc private func purgeRetainedAudio() {
        let alert = NSAlert()
        alert.messageText = "Delete all retained dictation audio?"
        alert.informativeText = "This deletes the local WAV files only. Your transcription History rows remain. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Audio")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AudioRetentionStore.shared.purge()
        Log.write("settings: retained dictation audio purge requested")
    }

    @objc private func toggleKeepHistory() {
        Settings.keepFullHistory = (keepHistorySwitch.state == .on)
        Log.write("settings: keep-full-dictation-history -> \(Settings.keepFullHistory ? "ON" : "OFF")")
    }

    // MARK: display tab actions

    @objc private func positionChanged() {
        let raw = (positionPopup.selectedItem?.representedObject as? String) ?? ""
        Settings.hudPosition = HUDPosition(rawValue: raw) ?? .bottomCenter
        Log.write("settings: HUD position -> \(Settings.hudPosition.rawValue)")
    }

    /// Reflect an external Power Mode flip (the menubar toggle) in the Appearance tab, if built.
    func refreshPowerModeSwitch() {
        powerView?.refresh()
    }

    // MARK: mic picker

    /// Fill the popup: option 0 = follow the system default, then each present input device by name.
    /// Each item carries its device UID in `representedObject` ("" for follow). If the pinned device is
    /// currently unplugged, add a disabled item for it so the choice stays visible (and persists) until
    /// the device returns; the recorder still falls back to the default in the meantime.
    private func populateMicPopup() {
        guard micPopup != nil else { return }
        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "System Default (follow)")
        micPopup.lastItem?.representedObject = ""

        let pinned = Settings.inputDeviceUID
        var matched = pinned.isEmpty
        for dev in AudioDevices.inputDevices() {
            micPopup.addItem(withTitle: dev.name)
            micPopup.lastItem?.representedObject = dev.uid
            if dev.uid == pinned { matched = true }
        }
        if !pinned.isEmpty && !matched {
            let label = Settings.inputDeviceName.isEmpty ? "Pinned mic" : Settings.inputDeviceName
            micPopup.addItem(withTitle: "\(label) (unavailable)")
            micPopup.lastItem?.representedObject = pinned
            micPopup.lastItem?.isEnabled = false
        }
        if let item = micPopup.itemArray.first(where: { ($0.representedObject as? String) == pinned }) {
            micPopup.select(item)
        }
    }

    @objc private func micChanged() {
        let uid = (micPopup.selectedItem?.representedObject as? String) ?? ""
        Settings.inputDeviceUID = uid
        Settings.inputDeviceName = uid.isEmpty ? "" : (micPopup.selectedItem?.title ?? "")
        Log.write("settings: input device -> \(uid.isEmpty ? "system default" : uid)")
        // Re-point the live preview at the chosen mic so the meter previews the right device.
        if previewing { stopPreview(); startPreview() }
    }

    @objc private func resetDefaults() {
        Settings.resetToDefaults()
        sensitivity.doubleValue = Double(Settings.sensitivity)
        gain.doubleValue = Double(Settings.gain)
        reactivity.doubleValue = Double(Settings.reactivity)
        reduceSwitch.state = Settings.reduceRepeats ? .on : .off
        retainAudioSwitch.state = Settings.retainDictationAudio ? .on : .off
        refreshValueLabels()
    }

    @objc private func closeWindow() { window?.close() }

    private func refreshValueLabels() {
        sensitivityVal.stringValue = String(format: "%.0f dB", Settings.floorDb)
        gainVal.stringValue = String(format: "x%.1f", Settings.linearGain)
        reactivityVal.stringValue = "\(Int(Settings.reactivity * 100))%"
    }
}

/// The visual half of the consolidated Appearance tab: the one monochromatic theme color (the macOS
/// color panel via a color well), a live preview of the derived shades, and all three HUD-size controls.
private final class AppearanceSettingsView: NSView {
    override var isFlipped: Bool { true }

    private var hudSizeSlider: NSSlider!
    private var hudSizeVal: NSTextField!
    private var pillSizeSlider: NSSlider!
    private var pillSizeVal: NSTextField!
    private var spinnerSizeSlider: NSSlider!
    private var spinnerSizeVal: NSTextField!
    private var colorWell: NSColorWell!
    private var themePreview: ThemePreviewView!

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        let L: CGFloat = 20

        addSubview(sectionHeader("THEME COLOR", y: 16))
        let themeCard = SettingsSectionKit.card(
            frame: NSRect(x: L, y: 38, width: width - 2 * L, height: 188),
            identifier: "card.appearance-theme")
        addSubview(themeCard)
        themeCard.addSubview(plainLabel("Color", x: 14, y: 13, w: 82, bold: false))
        colorWell = NSColorWell(frame: NSRect(x: 96, y: 8, width: 50, height: 26))
        colorWell.identifier = NSUserInterfaceItemIdentifier("theme-color")
        colorWell.color = Phosphor.accent
        colorWell.target = self
        colorWell.action = #selector(themeColorChanged)
        themeCard.addSubview(colorWell)
        let resetColor = NSButton(title: "Reset to green", target: self, action: #selector(resetThemeColor))
        resetColor.bezelStyle = .rounded
        resetColor.identifier = NSUserInterfaceItemIdentifier("theme-color-reset")
        resetColor.frame = NSRect(x: 158, y: 7, width: 140, height: 28)
        themeCard.addSubview(resetColor)
        themeCard.addSubview(hint("Pick one color; the whole app derives its shades from it — the panels, the dictation HUD, and the sticky notes. Opens the macOS color panel (wheel, brightness/saturation, hex, eyedropper).",
                                  y: 42, width: themeCard.bounds.width - 28, x: 14))

        themePreview = ThemePreviewView(
            frame: NSRect(x: 14, y: 82, width: themeCard.bounds.width - 28, height: 92))
        themePreview.identifier = NSUserInterfaceItemIdentifier("theme-preview")
        themeCard.addSubview(themePreview)

        let sizeHeaderY = themeCard.frame.maxY + 16
        addSubview(sectionHeader("UI SIZE", y: sizeHeaderY))
        let sizeCard = SettingsSectionKit.card(
            frame: NSRect(x: L, y: sizeHeaderY + 22, width: width - 2 * L, height: 198),
            identifier: "card.appearance-size")
        addSubview(sizeCard)
        let labelW: CGFloat = 82
        let sliderX: CGFloat = 96
        let valX = sizeCard.bounds.width - 58
        let valW: CGFloat = 44
        let sliderW = valX - sliderX - 8

        sizeCard.addSubview(plainLabel("Pill size", x: 14, y: 14, w: labelW, bold: false))
        pillSizeSlider = NSSlider(value: Settings.hudPillScale,
                                  minValue: Settings.hudPillScaleRange.lowerBound,
                                  maxValue: Settings.hudPillScaleRange.upperBound,
                                  target: self, action: #selector(displaySlidersChanged))
        pillSizeSlider.identifier = NSUserInterfaceItemIdentifier("hud-pill-scale")
        pillSizeSlider.frame = NSRect(x: sliderX, y: 13, width: sliderW, height: 20)
        pillSizeSlider.isContinuous = true
        sizeCard.addSubview(pillSizeSlider)
        pillSizeVal = valueLabel(at: 13, x: valX, w: valW, into: sizeCard)
        sizeCard.addSubview(hint("Size of the Final-only pill (the oscilloscope capsule).",
                                 y: 37, width: sizeCard.bounds.width - 28, x: 14))

        sizeCard.addSubview(plainLabel("HUD size", x: 14, y: 74, w: labelW, bold: false))
        hudSizeSlider = NSSlider(value: Settings.hudScale,
                                 minValue: Settings.hudScaleRange.lowerBound,
                                 maxValue: Settings.hudScaleRange.upperBound,
                                 target: self, action: #selector(displaySlidersChanged))
        hudSizeSlider.identifier = NSUserInterfaceItemIdentifier("hud-scale")
        hudSizeSlider.frame = NSRect(x: sliderX, y: 73, width: sliderW, height: 20)
        hudSizeSlider.isContinuous = true
        sizeCard.addSubview(hudSizeSlider)
        hudSizeVal = valueLabel(at: 73, x: valX, w: valW, into: sizeCard)
        sizeCard.addSubview(hint("Size of the full dictation HUD (normal mode). 100% is today's full-width layout.",
                                 y: 97, width: sizeCard.bounds.width - 28, x: 14))

        sizeCard.addSubview(plainLabel("Spinner size", x: 14, y: 134, w: labelW, bold: false))
        spinnerSizeSlider = NSSlider(value: Settings.hudSpinnerScale,
                                     minValue: Settings.hudSpinnerScaleRange.lowerBound,
                                     maxValue: Settings.hudSpinnerScaleRange.upperBound,
                                     target: self, action: #selector(displaySlidersChanged))
        spinnerSizeSlider.identifier = NSUserInterfaceItemIdentifier("hud-spinner-scale")
        spinnerSizeSlider.frame = NSRect(x: sliderX, y: 133, width: sliderW, height: 20)
        spinnerSizeSlider.isContinuous = true
        sizeCard.addSubview(spinnerSizeSlider)
        spinnerSizeVal = valueLabel(at: 133, x: valX, w: valW, into: sizeCard)
        sizeCard.addSubview(hint("Size of the processing spinner — the ring shown while your dictation is being cleaned up.",
                                 y: 157, width: sizeCard.bounds.width - 28, x: 14))

        frame = NSRect(x: 0, y: 0, width: width, height: sizeCard.frame.maxY + 16)
        refreshDisplayValueLabels()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func sectionHeader(_ text: String, y: CGFloat) -> NSTextField {
        SettingsSectionKit.sectionHeader(text, x: 20, y: y, width: frame.width - 40)
    }

    private func plainLabel(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        bold: Bool
    ) -> NSTextField {
        SettingsSectionKit.label(
            text, x: x, y: y, width: w, size: 12,
            weight: bold ? .medium : .regular, color: .labelColor)
    }

    private func hint(_ text: String, y: CGFloat, width: CGFloat, x: CGFloat) -> NSTextField {
        let field = SettingsSectionKit.wrapped(
            text, x: x, y: y, width: width, size: 10.5, color: .tertiaryLabelColor)
        field.frame.size.height = max(30, field.frame.height)
        return field
    }

    private func valueLabel(at y: CGFloat, x: CGFloat, w: CGFloat, into parent: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        field.frame = NSRect(x: x, y: y + 1, width: w, height: 16)
        parent.addSubview(field)
        return field
    }

    @objc private func displaySlidersChanged() {
        Settings.hudScale = hudSizeSlider.doubleValue
        Settings.hudPillScale = pillSizeSlider.doubleValue
        Settings.hudSpinnerScale = spinnerSizeSlider.doubleValue
        refreshDisplayValueLabels()
    }

    private func refreshDisplayValueLabels() {
        guard hudSizeVal != nil, pillSizeVal != nil, spinnerSizeVal != nil else { return }
        hudSizeVal.stringValue = "\(Int(round(Settings.hudScale * 100)))%"
        pillSizeVal.stringValue = "\(Int(round(Settings.hudPillScale * 100)))%"
        spinnerSizeVal.stringValue = "\(Int(round(Settings.hudSpinnerScale * 100)))%"
    }

    /// The color well changed (continuous, so this fires while the user drags in the color panel). Persist the
    /// hex value through Settings and repaint the local preview.
    @objc private func themeColorChanged() {
        Settings.themeColorHex = Phosphor.hexString(colorWell.color)
        themePreview?.needsDisplay = true
    }

    /// Restore the default phosphor green.
    @objc private func resetThemeColor() {
        Settings.themeColorHex = Phosphor.defaultAccentHex
        colorWell.color = Phosphor.accent
        themePreview?.needsDisplay = true
    }
}

/// Rendering contract for the device-authorization code, owned in one place so the presenter and its
/// GUI probe cannot drift apart.
///
/// An `NSAlert` computes its layout when it is presented and never re-lays-out afterwards. Assigning
/// `informativeText` while the sheet is already on screen does swap the string into the text field, but
/// the field keeps its original height and the window never grows, so the added lines are clipped away
/// unseen. The one-time code therefore MUST NOT arrive via `informativeText`; it goes into a
/// fixed-size accessory field that is already big enough before the sheet is shown.
enum CodexDeviceCodePresentation {
    static let awaitingText = "waiting for code…"
    static let noCodeText = "no code received"
    static let fieldSize = NSSize(width: 320, height: 30)

    static func makeCodeField() -> NSTextField {
        let field = NSTextField(labelWithString: awaitingText)
        field.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold)
        field.alignment = .center
        field.isSelectable = true
        field.lineBreakMode = .byClipping
        field.setFrameSize(fieldSize)
        return field
    }

    /// True when the field's current string renders inside its own frame. The original defect was a
    /// string that did not fit and was silently clipped, so "it fits" is the assertion that bites.
    static func textFits(_ field: NSTextField) -> Bool {
        field.attributedStringValue.size().width <= field.frame.width
    }
}

/// Internal rather than private since P9: the provider-onboarding surface and the Models & Power card both
/// reach the Codex device login through `ProviderSignInPresenter`, which owns one of these. W4 requires ONE
/// code path for getting a provider connected, so this presenter has exactly one owner above it.
final class CodexConnectionPresenter {
    private var connectionAlert: NSAlert?
    private var codeField: NSTextField?
    private var openedVerificationURL: URL?
    /// Called when the attempt is over, whichever way it ended, so a host can RE-MEASURE. Success is never
    /// inferred from this callback firing.
    private var onFinished: (() -> Void)?

    func present(in window: NSWindow?, onFinished: (() -> Void)? = nil) {
        guard let window else { return }
        self.onFinished = onFinished
        let connected = Settings.modelsPower.availabilityState(for: .codex).canRun
        let alert = NSAlert()
        alert.messageText = connected ? "Reconnect Codex" : "Connect Codex"
        alert.informativeText = "ViddyDictate will use ChatGPT subscription device authorization in its dedicated Codex home. It never copies your normal Codex state and never accepts an API key. No route or default changes during connection."
        alert.alertStyle = .informational
        alert.addButton(withTitle: connected ? "Reconnect" : "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.finish()
                return
            }
            self.beginDeviceLogin(in: window)
        }
    }

    private func finish() {
        let callback = onFinished
        onFinished = nil
        callback?()
    }

    private func beginDeviceLogin(in window: NSWindow) {
        let progress = NSAlert()
        progress.messageText = "Connect Codex"
        // Every word that has to be readable later is set BEFORE presenting, because the sheet's layout
        // is frozen once it is shown (see CodexDeviceCodePresentation). Only the accessory field's
        // string changes afterwards.
        progress.informativeText = "A browser page is opening. Enter the one-time code below to authorize ViddyDictate's dedicated Codex home, then come back here. ViddyDictate is waiting…"
        progress.alertStyle = .informational
        let field = CodexDeviceCodePresentation.makeCodeField()
        progress.accessoryView = field
        codeField = field
        progress.addButton(withTitle: "Cancel")
        connectionAlert = progress
        openedVerificationURL = nil
        progress.beginSheetModal(for: window) { [weak self, weak progress] _ in
            guard let self, let progress, self.connectionAlert === progress else { return }
            self.connectionAlert = nil
            self.codeField = nil
            CodexConnectionController.shared.cancelDeviceLogin()
        }

        CodexConnectionController.shared.startDeviceLogin(
            onInstructions: { [weak self, weak progress] info in
                guard let self, let progress, self.connectionAlert === progress else { return }
                if let url = info.verificationURL, self.openedVerificationURL != url {
                    self.openedVerificationURL = url
                    NSWorkspace.shared.open(url)
                }
                self.codeField?.stringValue =
                    info.userCode ?? CodexDeviceCodePresentation.noCodeText
            },
            completion: { [weak self, weak progress] state in
                guard let self else { return }
                if let progress, self.connectionAlert === progress {
                    self.connectionAlert = nil
                    self.codeField = nil
                    if progress.window.sheetParent != nil { window.endSheet(progress.window) }
                }
                self.presentResult(state, in: window)
                self.finish()
            })
    }

    private func presentResult(_ state: CodexConnectionState, in window: NSWindow) {
        let alert = NSAlert()
        switch state {
        case .connected:
            alert.messageText = "Codex connected"
            alert.informativeText = "The dedicated ViddyDictate home is authenticated with ChatGPT. Existing route choices and the pending Codex-default slate are unchanged."
            alert.alertStyle = .informational
        case .disconnected:
            alert.messageText = "Codex not connected"
            alert.informativeText = "Device authorization did not complete. No route or provider default changed."
            alert.alertStyle = .warning
        case .unavailable(let reason):
            alert.messageText = "Codex unavailable"
            alert.informativeText = reason
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

private final class RetryConfirmationPresenter {
    private weak var view: ModelsPowerSettingsView?

    func bind(_ view: ModelsPowerSettingsView) {
        self.view = view
        syncPendingRetry()
    }

    func syncPendingRetry() {
        guard let view else { return }
        view.clearRetryAvailability()
        if let summary = TextTransformRetryCenter.shared.summary {
            view.setRetryAvailable(true, for: summary.route, provider: summary.failedProvider)
        }
    }

    /// Present only explicitly named, currently available provider bundles. Clicking one named button is
    /// the confirmation; the retry center then consumes the exact pending generation and dispatches once.
    func present(route: LLMRouteID, failedProvider: LLMProvider, in window: NSWindow?) {
        guard let window,
              let summary = TextTransformRetryCenter.shared.summary,
              summary.route == route, summary.failedProvider == failedProvider else {
            syncPendingRetry()
            return
        }
        let eligible = TextTransformRetryCenter.eligibleProviderBundles(
            for: summary, settings: Settings.modelsPower)
        let alert = NSAlert()
        alert.messageText = "Retry \(ModelsPowerSettingsView.displayName(for: route))"
        if eligible.isEmpty {
            alert.informativeText = "\(summary.safeFailureText). No configured provider for this route is currently available. The original text and landing state remain unchanged."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window)
            return
        }
        alert.informativeText = "\(summary.safeFailureText). Choose exactly one provider to run once. This does not change the route's saved provider, and no fallback is automatic."
        alert.alertStyle = .warning
        for (provider, _) in eligible {
            alert.addButton(withTitle: "Retry \(ModelsPowerSettingsView.displayName(for: provider))")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < eligible.count else { return }
            let (_, bundle) = eligible[index]
            if !TextTransformRetryCenter.shared.retry(
                summaryID: summary.id, explicitlyUsing: bundle) {
                self.syncPendingRetry()
            }
        }
    }
}

/// A small live preview of the current theme on the Appearance tab: a rounded phosphor panel showing the
/// accent as a glowing heading + border, a muted subtitle, and three derived "cell" chips — so the user sees
/// the derived shades update as he drags the macOS color panel. Reads `Phosphor.current`, so a
/// `needsDisplay` repaints it to the freshly-picked accent.
private final class ThemePreviewView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = Phosphor.current
        let r = bounds.insetBy(dx: 1, dy: 1)
        let panel = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        p.noteBodyBG.setFill(); panel.fill()
        p.green.withAlphaComponent(0.5).setStroke(); panel.lineWidth = 1; panel.stroke()

        let shadow = NSShadow(); shadow.shadowColor = p.green.withAlphaComponent(0.6); shadow.shadowBlurRadius = 6
        let heading = NSAttributedString(string: "ViddyDictate", attributes: [
            .font: NSFont(name: Phosphor.font, size: 15) ?? .systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: p.green, .kern: 1.5, .shadow: shadow,
        ])
        heading.draw(at: NSPoint(x: r.minX + 14, y: r.minY + 12))

        let sub = NSAttributedString(string: "sample theme preview", attributes: [
            .font: NSFont(name: Phosphor.font, size: 11) ?? .systemFont(ofSize: 11),
            .foregroundColor: p.noteMutedText,
        ])
        sub.draw(at: NSPoint(x: r.minX + 14, y: r.minY + 36))

        // Three derived "cell" chips: idle, selected, accent — the shades panels/cells actually use.
        let chipY = r.minY + 58, chipW: CGFloat = 34, chipH: CGFloat = 20, gap: CGFloat = 8
        let chips: [(NSColor, NSColor)] = [
            (p.cellOff, p.green.withAlphaComponent(0.35)),
            (p.cellOn,  p.green.withAlphaComponent(0.70)),
            (p.green,   p.green),
        ]
        var x = r.minX + 14
        for (fill, stroke) in chips {
            let chip = NSBezierPath(roundedRect: NSRect(x: x, y: chipY, width: chipW, height: chipH), xRadius: 5, yRadius: 5)
            fill.setFill(); chip.fill()
            stroke.setStroke(); chip.lineWidth = 1; chip.stroke()
            x += chipW + gap
        }
    }
}
