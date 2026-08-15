import Cocoa

// MARK: - HUD display mode

/// What the HUD is currently showing — HUDPanel's single source of truth for its layout (BUG 1 fix).
/// `relayout()` switches on this EXHAUSTIVELY (compiler-checked, so a new mode can't silently fall through
/// to the full-HUD branch), and every transition (`show`/`toast`/`dismissToast`/`setThinking`/`hide`/
/// `update`) sets it. It replaces the old loose booleans (`thinking`/`toasting`/`toastForceFull` +
/// `panel.isVisible`) that independently drove the layout — the tangle that let a dismissing mid-take
/// toast order the whole HUD off-screen for the rest of an actively-recording take.
enum HUDDisplayMode {
    case fullRecording   // the full CRT box: live scope + transcript (normal-power take)
    case pillScope       // the Final-only scope pill: just the oscilloscope
    case pillToast       // the Final-only in-pill status toast: a capsule grown to fit the message
    case fullToast       // a full-box toast: Live, or a forced-full / `answer()` toast in Final-only
    case thinking        // the post-release cleanup-wait spinner
}

/// Logical owners of the one shared thinking ring. Processing and retained-take recovery can overlap,
/// and several retained takes may be pending at once; the HUD still renders one ring until the final
/// owner clears. The take IDs make repeated begin/end signals idempotent instead of reference-counting
/// a duplicate notification twice.
struct HUDThinkingActivity {
    private(set) var processing = false
    private(set) var recoveryTakeIDs: Set<UUID> = []

    var isActive: Bool { processing || !recoveryTakeIDs.isEmpty }

    mutating func setProcessing(_ active: Bool) {
        processing = active
    }

    mutating func setRecovery(takeID: UUID, pending: Bool) {
        if pending {
            recoveryTakeIDs.insert(takeID)
        } else {
            recoveryTakeIDs.remove(takeID)
        }
    }
}

// MARK: - HUD panel

final class HUDPanel: NSObject {
    var onLock: (() -> Void)?
    var onStop: (() -> Void)?
    var onSettings: (() -> Void)?
    var samplesProvider: (() -> [Float])?

    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let display = DisplayView()
    private let handle = DragHandle()
    private let statusLabel = NSTextField(labelWithString: "")
    private let recDot = NSView()
    private let recLabel = NSTextField(labelWithString: "REC")
    private let settingsButton = NSButton()
    private let wave = WaveformView(frame: .zero)
    private let transcription = NSTextField(wrappingLabelWithString: "")
    /// Low-power pill-toast text: a short status `toast()` renders INSIDE a pill-styled capsule grown
    /// to fit the message (the scope is hidden for the dwell) instead of popping the full box.
    private let pillToastLabel = NSTextField(wrappingLabelWithString: "")
    private let lockButton: GlassButton
    private let stopButton: GlassButton

    private let badge = ModeBadgePanel()
    /// The universal transform-slot indicators in the info bar: one reused KeycapView for Cleanup or
    /// an armed one-shot mode, plus the compact 3-stop strength slider when Cleanup owns the slot.
    private let keycap = KeycapView()
    private let slider = StrengthSlider()
    /// The low-power INFO PILL (Item B): a separate content-gated capsule below the scope pill, holding
    /// the lock glyph + `?` keycap + labeled slider. Its own panel, so the scope pill never moves.
    private let infoPill = InfoPillPanel()
    /// The spinning green-phosphor wheel that replaces the whole HUD during the cleanup wait.
    private let spinner = ThinkingSpinner()
    /// Forwarded when the user drags the HUD slider, so the controller can set the level.
    var onSetLevel: ((Int) -> Void)?
    private var cleanupEnabled = false
    private var cleanupLevel = 0
    /// Cleanup's rebound glyph is the Raw-state keycap. An armed one-shot temporarily replaces it.
    private var cleanupGlyph = "?"
    private var armedModeGlyph: String?
    /// Latched from `update(...locked:)` so `layoutPill` / the info pill can read it (it was previously
    /// only used transiently inside `update`). Drives the info pill's lock glyph.
    private var lockedState = false
    /// Latched armed state of the sticky-note bullseye (notes-bullseye BT2). Drives the info pill's bullseye
    /// glyph, content-gated exactly like the lock glyph / `?` keycap.
    private var bullseyeArmed = false

    private var origin = NSPoint.zero
    private var currentText = ""
    private var caretOn = true
    private var caretTimer: Timer?
    private var toastTimer: Timer?
    private var showRec = true
    /// The single source of truth for the current layout (see `HUDDisplayMode`). Every transition sets it;
    /// `relayout()` switches on it. Replaces the old thinking/toasting/toastForceFull booleans.
    private var mode: HUDDisplayMode = .fullRecording
    /// All logical owners share the existing ring. Recovery IDs prevent one completed take from hiding
    /// progress for another take that is still waiting.
    private var thinkingActivity = HUDThinkingActivity()
    /// Final-only mode captured at show()/toast(): the recording HUD is the small scope pill and a plain
    /// toast renders in a pill. Feeds `recordingMode` / `toastMode(forceFull:)`, which pick the actual `mode`
    /// (so the display mode encodes compactness; `relayout()` never re-reads this field).
    private var finalOnly = false
    /// Whether a take is live. DictationController pushes this at its `State` transitions (recording/locked →
    /// true; idle/finishing → false). `dismissToast()` reads it to decide whether a dismissing toast reverts
    /// to the recording scope (take still live) or hides outright (no take) — the core of the BUG 1 fix.
    private var takeActive = false
    /// The user dragged the panel this take — keep their origin through relayouts instead of
    /// re-homing to the position setting (home resets on the next show, as before).
    private var userDragged = false

    private var W: CGFloat
    private var waveH: CGFloat = 72
    private var scale: CGFloat = 1
    private let PADX: CGFloat = 24
    private let padTop: CGFloat = 9, padBottom: CGFloat = 11
    private let statusH: CGFloat = 13
    private let gap1: CGFloat = 7, gap2: CGFloat = 7
    private let buttonsH: CGFloat = 28, gapDB: CGFloat = 8

    /// The recording layout for the current power mode — the mode `show()` / `dismissToast()` /
    /// `setThinking(false)` / `update()` revert to. Final-only uses the scope pill; Live uses the full box.
    private var recordingMode: HUDDisplayMode { finalOnly ? .pillScope : .fullRecording }
    /// The toast layout for the current power mode: a plain Final-only toast rides in a pill; a forced-full
    /// toast (`answer()`) or any full-power toast uses the readable full box.
    private func toastMode(forceFull: Bool) -> HUDDisplayMode { (finalOnly && !forceFull) ? .pillToast : .fullToast }

    override init() {
        W = min(1080, (NSScreen.main?.visibleFrame.width ?? 1100) - 80)
        lockButton = GlassButton(title: "Lock", symbol: "lock.fill", isStop: false, target: nil, action: #selector(noop))
        stopButton = GlassButton(title: "Stop", symbol: "stop.fill", isStop: true, target: nil, action: #selector(noop))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        root.wantsLayer = true

        effect.wantsLayer = true
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        statusLabel.maximumNumberOfLines = 1
        recDot.wantsLayer = true
        recDot.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1).cgColor
        recDot.layer?.cornerRadius = 3.5
        recDot.layer?.shadowColor = NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1).cgColor
        recDot.layer?.shadowRadius = 4; recDot.layer?.shadowOpacity = 0.8; recDot.layer?.shadowOffset = .zero
        recDot.layer?.masksToBounds = false
        recLabel.attributedStringValue = Phosphor.kerned("REC", color: NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1), size: 11, kern: 2)

        transcription.maximumNumberOfLines = 0
        transcription.lineBreakMode = .byWordWrapping
        transcription.cell?.wraps = true
        transcription.cell?.isScrollable = false
        // Belt-and-suspenders for the body color: the attributed string already carries phosphor green
        // (transcriptionAttr), but on current macOS the multi-line wrapping-label layout path can drop
        // the attributed .foregroundColor and fall back to the field's textColor (= labelColor, ~white
        // on the dark HUD) — which is what turned the transcript white. Pin textColor to green so the
        // body stays green whichever path AppKit takes. (The single-line status label is unaffected.)
        transcription.textColor = Phosphor.green.withAlphaComponent(0.9)

        // The low-power pill-toast text: centered, up to two lines, truncating tail. Pin textColor to
        // phosphor green (same reason as `transcription` above — the wrapping-label path can otherwise
        // drop the attributed foreground color).
        pillToastLabel.maximumNumberOfLines = 2
        pillToastLabel.alignment = .center
        pillToastLabel.lineBreakMode = .byWordWrapping     // wrap up to two lines...
        pillToastLabel.cell?.truncatesLastVisibleLine = true   // ...then ellipsize the tail of line 2
        pillToastLabel.cell?.wraps = true
        pillToastLabel.cell?.isScrollable = false
        pillToastLabel.textColor = Phosphor.green.withAlphaComponent(0.92)
        pillToastLabel.isHidden = true

        handle.onMoved = { [weak self] o in self?.origin = o; self?.userDragged = true }   // drag moves it live; home resets on next show
        lockButton.target = self; lockButton.action = #selector(lockClicked)
        stopButton.target = self; stopButton.action = #selector(stopClicked)
        // The scope only ever shows live mic input now; the cleanup wait is a separate spinner that
        // replaces the whole HUD (see setThinking), not a sine in this box.
        wave.samplesProvider = { [weak self] in self?.samplesProvider?() ?? [] }

        // Persistent cleanup keycap (small, matches the pop-up badge) + the compact strength slider.
        // Its glyph is installed from the live HotkeyMap below and on every Settings rebind.
        keycap.fontSize = 10; keycap.cornerRadius = 3; keycap.glowRadius = 5
        keycap.tint = Phosphor.green
        keycap.lit = false; keycap.isHidden = false
        slider.isHidden = true
        slider.onSetLevel = { [weak self] lvl in self?.onSetLevel?(lvl) }
        spinner.isHidden = true

        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.imagePosition = .imageOnly
        settingsButton.toolTip = "Settings"
        let gearCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        settingsButton.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(gearCfg)
        settingsButton.contentTintColor = Phosphor.green.withAlphaComponent(0.55)
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)

        display.addSubview(handle)
        display.addSubview(statusLabel)
        display.addSubview(recDot)
        display.addSubview(recLabel)
        display.addSubview(settingsButton)
        display.addSubview(keycap)
        display.addSubview(slider)
        display.addSubview(wave)
        display.addSubview(transcription)
        display.addSubview(pillToastLabel)
        root.addSubview(effect)
        root.addSubview(display)
        root.addSubview(lockButton)
        root.addSubview(stopButton)
        root.addSubview(spinner)
        panel.contentView = root
        setHotkeyMap(.defaults())
    }

    @objc private func noop() {}
    @objc private func lockClicked() { onLock?() }
    @objc private func stopClicked() { onStop?() }
    @objc private func settingsClicked() { onSettings?() }

    // MARK: layout

    private func transcriptionAttr(_ s: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = Phosphor.green.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 10
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3
        // The body font follows the HUD size setting (floored so a shrunken HUD stays readable).
        let fontSize = max(11, round(14 * scale))
        return NSAttributedString(string: s, attributes: [
            .font: NSFont(name: Phosphor.font, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: Phosphor.green.withAlphaComponent(0.9),
            .shadow: shadow, .paragraphStyle: para,
        ])
    }

    /// Re-read the display settings that shape the panel (called at each show, so settings changes
    /// apply from the next take). Scale drives the full HUD's width, scope height, and body font;
    /// the pill has its own scale applied in `layoutPill`.
    private func refreshDisplaySettings() {
        finalOnly = Settings.powerMode.usesCompactHUD
        scale = CGFloat(Settings.hudScale)
        W = min(1080 * scale, (NSScreen.main?.visibleFrame.width ?? 1100) - 80)
        waveH = round(72 * scale)
        // Re-read the accent so a theme change recolors the one-shot-tinted chrome from the next take
        // (these are set once at init; the per-relayout body text already reads Phosphor.green live).
        keycap.tint = Phosphor.green
        settingsButton.contentTintColor = Phosphor.green.withAlphaComponent(0.55)
        transcription.textColor = Phosphor.green.withAlphaComponent(0.9)
        pillToastLabel.textColor = Phosphor.green.withAlphaComponent(0.92)
    }

    /// Home the panel per the position setting for its current size — unless the user dragged it
    /// this take, in which case their origin wins until the next show.
    private func applyHome(for size: NSSize) {
        guard !userDragged else { return }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        origin = Settings.hudPosition.origin(for: size, in: vf)
    }

    /// Apply the shared window/content/display framing used by every HUD mode. The thinking mode
    /// may supply the origin that preserves its current on-screen anchor; all other modes home
    /// normally for their new size.
    @discardableResult
    private func presentBox(panelSize: NSSize, displayBox: NSRect? = nil,
                            cornerRadius: CGFloat, visibleOrigin: NSPoint? = nil) -> NSRect {
        if panel.isVisible, let visibleOrigin {
            origin = visibleOrigin
        } else {
            applyHome(for: panelSize)
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
        let box = displayBox ?? NSRect(origin: .zero, size: panelSize)
        effect.frame = box
        display.frame = box
        display.cornerRadius = cornerRadius
        effect.layer?.cornerRadius = cornerRadius
        return box
    }

    private func relayout() {
        // The cleanup-wait spinner floats free: hide the frosted panel + CRT box and drop the window
        // shadow so the ring is fully transparent (you can see the UI behind it). Every other layout
        // below restores them (a plain assignment each relayout, so leaving the spinner is self-healing).
        let thinking = (mode == .thinking)
        effect.isHidden = thinking
        display.isHidden = thinking
        panel.hasShadow = !thinking
        switch mode {
        case .thinking:  infoPill.hide(); layoutThinking(); return
        case .pillToast: infoPill.hide(); layoutPillToast(); return   // in-pill status toast
        case .pillScope: layoutPill(); return                         // layoutPill drives the info pill
        case .fullRecording, .fullToast: break                        // fall through to the full CRT box below
        }
        layoutFullBox()
    }

    private func layoutFullBox() {
        infoPill.hide()   // full HUD carries the same indicators inline; no separate info pill
        pillToastLabel.isHidden = true

        let innerW = W - 2 * PADX
        let attr = transcriptionAttr(currentText.isEmpty ? "…" : currentText)
        let textH = max(24, ceil(attr.boundingRect(
            with: NSSize(width: innerW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
        let displayH = padTop + statusH + gap1 + waveH + gap2 + textH + padBottom
        let winH = displayH + gapDB + buttonsH
        let dispRect = NSRect(x: 0, y: buttonsH + gapDB, width: W, height: displayH)
        presentBox(panelSize: NSSize(width: W, height: winH), displayBox: dispRect, cornerRadius: 10)

        let rowY = displayH - padTop - statusH
        let rowMidY = rowY + statusH / 2
        let gearW: CGFloat = 18
        handle.frame = NSRect(x: PADX, y: rowY, width: 16, height: statusH)
        statusLabel.frame = NSRect(x: PADX + 24, y: rowY - 1, width: W * 0.5, height: statusH + 2)
        wave.frame = NSRect(x: PADX, y: padBottom + textH + gap2, width: innerW, height: waveH)
        transcription.frame = NSRect(x: PADX, y: padBottom, width: innerW, height: textH)

        // Right cluster, laid out right-to-left: gear, transform keycap (FIXED spot),
        // [Cleanup slider when Cleanup owns the slot], REC.
        settingsButton.frame = NSRect(x: W - PADX - gearW, y: rowY - 2, width: gearW, height: statusH + 4)
        var rx = W - PADX - gearW - 10
        let kcW: CGFloat = 14
        keycap.frame = NSRect(x: rx - kcW, y: rowMidY - 7.5, width: kcW, height: 15)
        keycap.lit = cleanupEnabled || armedModeGlyph != nil
        keycap.isHidden = false
        rx -= kcW + 8
        if cleanupEnabled {
            let sw2 = ceil(slider.intrinsicWidthValue)
            slider.frame = NSRect(x: rx - sw2, y: rowMidY - 7.5, width: sw2, height: 15)
            slider.level = cleanupLevel; slider.enabled = true; slider.isHidden = false
            rx -= sw2 + 10
        } else {
            slider.isHidden = true
        }
        // Measure "REC" rather than hardcoding a width — the Helvetica Neue + kerning rendering is
        // wider than the old fixed 32px box and was clipping to "RE".
        let recW = ceil(recLabel.attributedStringValue.size().width) + 4
        recLabel.frame = NSRect(x: rx - recW, y: rowY - 1, width: recW, height: statusH + 2)
        recDot.frame = NSRect(x: rx - recW - 11, y: rowY + (statusH - 7) / 2, width: 7, height: 7)

        let lw = lockButton.intrinsicContentSize.width, sw = stopButton.intrinsicContentSize.width
        let total = lw + 12 + sw
        let startX = (W - total) / 2
        lockButton.frame = NSRect(x: startX, y: 0, width: lw, height: buttonsH)
        stopButton.frame = NSRect(x: startX + lw + 12, y: 0, width: sw, height: buttonsH)

        spinner.isHidden = true
        handle.isHidden = false; statusLabel.isHidden = false; settingsButton.isHidden = false
        wave.isHidden = false; transcription.isHidden = false
        recDot.isHidden = !showRec; recLabel.isHidden = !showRec
        lockButton.isHidden = false; stopButton.isHidden = false
    }

    // MARK: public API (unchanged shape for DictationController)

    func show() {
        refreshDisplaySettings()         // re-read Power Mode + scales for this take
        mode = recordingMode             // a fresh take: Final-only scope pill or Live box
        userDragged = false              // always spawn at the position-setting home
        presentForCurrentMode()
    }

    /// Order the panel on screen and start/stop the wave + caret to match the CURRENT `mode`. Shared by
    /// `show()` (a fresh take), `toast()`, and `dismissToast()`'s revert so the on-screen bring-up is
    /// identical however the mode was reached. It does NOT choose the mode or re-read settings — the caller
    /// sets `mode` first (this is what lets `dismissToast()` re-summon the recording scope after a toast).
    private func presentForCurrentMode() {
        relayout()                       // sizes the panel, then applyHome anchors it
        clampOnScreen()
        if mode == .pillScope { updateInfoPill() }   // re-anchor the info pill to the CLAMPED scope frame
        Log.write("HUD present frame=\(panel.frame) mode=\(mode) screen=\(NSScreen.main?.visibleFrame ?? .zero)")
        switch mode {
        case .pillToast:
            wave.stop()                                  // the pill-toast hides the scope for its dwell
            caretTimer?.invalidate(); caretTimer = nil
        case .pillScope:
            // The Final-only pill's scope runs at half rate.
            wave.start(fps: 30)
            caretTimer?.invalidate(); caretTimer = nil   // no visible transcript -> no caret blink
        case .fullRecording, .fullToast:
            wave.start(fps: 60)
            startCaret()
        case .thinking:
            break                                        // setThinking owns the spinner bring-up
        }
        panel.orderFrontRegardless()
    }

    private func clampOnScreen() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        var f = panel.frame
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        if f.minY < vf.minY { f.origin.y = vf.minY }
        origin = f.origin
        panel.setFrameOrigin(f.origin)
    }

    func hide() {
        toastTimer?.invalidate(); caretTimer?.invalidate(); caretTimer = nil
        thinkingActivity.setProcessing(false)
        mode = .fullRecording            // neutral resting mode; the next show()/toast() re-derives it
        pillToastLabel.isHidden = true
        wave.stop()
        spinner.stop(); spinner.isHidden = true
        badge.hide()
        infoPill.hide()
        panel.orderOut(nil)              // the genuine take-end path; dismissToast reserves this for takeActive == false
    }

    /// Take-liveness signal. DictationController pushes this at its `State` transitions (recording/locked →
    /// true; idle/finishing → false). `dismissToast()` reads it so a mid-take toast's dwell reverts to the
    /// recording scope instead of stranding the HUD off-screen for the rest of the take (BUG 1).
    func setTakeActive(_ active: Bool) { takeActive = active }

    // MARK: cleanup mode — badge + thinking spinner

    /// Refresh both cleanup indicators from the same live binding map used by HotkeyMonitor.
    /// DictationController calls this after loading and after every Settings rebind.
    func setHotkeyMap(_ map: HotkeyMap) {
        cleanupGlyph = map.key(for: .cleanupToggle).keycapGlyph
        if armedModeGlyph == nil { keycap.glyph = cleanupGlyph }
        keycap.needsDisplay = true
        infoPill.setHotkeyMap(map)
    }

    /// Pop the keycap mode badge above the HUD the instant the `?` chord registers.
    func flashModeBadge(glyph: String, label: String) {
        badge.flash(glyph: glyph, label: label, above: panel.frame)
    }

    /// Pop the badge for a Raw/Cleanup state change. Deliberately takes NO glyph: the cleanup keycap
    /// glyph comes from the same live `HotkeyMap` snapshot the two persistent keycaps already read, so
    /// a rebound cleanup key cannot flash a stale `?` in the toast while the info pill shows the new
    /// key. Every caller that used to pass `ProcessingMode.glyph` — which is hardcoded `"?"` — goes
    /// through here, so there is no call site left holding its own copy of the glyph.
    func flashCleanupBadge(label: String) {
        badge.flash(glyph: cleanupGlyph, label: label, above: panel.frame)
    }

    /// Enter/leave the post-release cleanup wait. The ENTIRE recording HUD collapses to a small box
    /// containing only the spinning green-phosphor wheel (the mic has stopped; nothing should imply it
    /// is still listening), and restores to normal when the cleaned text is about to land.
    func setThinking(_ on: Bool) {
        thinkingActivity.setProcessing(on)
        applyThinkingActivity()
    }

    /// Retained-take recovery shares the cleanup ring. A set of take IDs produces one unstacked spinner,
    /// and the last completion owns the clear. A visible retry/failure toast is allowed to finish its dwell;
    /// `dismissToast()` returns to this ring when any owner remains.
    func setRecoveryPending(takeID: UUID, pending: Bool) {
        thinkingActivity.setRecovery(takeID: takeID, pending: pending)
        applyThinkingActivity()
    }

    private func applyThinkingActivity() {
        guard thinkingActivity.isActive else {
            spinner.stop()
            spinner.isHidden = true
            if mode == .thinking {
                mode = recordingMode
                relayout()
            }
            return
        }

        // Toast text is visible progress too. Keep it for its dwell, then dismissToast() resumes the ring.
        guard mode != .pillToast && mode != .fullToast else { return }
        presentThinking()
    }

    private func presentThinking() {
        let wasThinking = (mode == .thinking)
        mode = .thinking
        caretTimer?.invalidate(); caretTimer = nil
        wave.stop()
        badge.hide()
        if panel.isVisible { origin = panel.frame.origin }  // else applyHome positions it
        relayout()
        if !wasThinking { spinner.start() }
        panel.orderFrontRegardless()
    }

    /// Update the persistent cleanup indicators in the info bar: the `?` keycap lights when cleanup is
    /// ON, and the strength slider appears at the current level (hidden when OFF).
    func setCleanup(enabled: Bool, level: Int) {
        cleanupEnabled = enabled
        cleanupLevel = CleanupLevel.clamped(level).rawValue
        keycap.glyph = armedModeGlyph ?? cleanupGlyph
        keycap.lit = enabled || armedModeGlyph != nil
        keycap.needsDisplay = true
        slider.level = cleanupLevel
        slider.enabled = enabled
        if panel.isVisible && mode != .thinking { relayout() }
    }

    /// Show or clear the Family-2 occupant of the transform slot. Cleanup exclusivity and arm lifetime
    /// are owned by TransformArmState; this method renders that state on both full-HUD and info-pill paths.
    func setArmedMode(glyph: String?) {
        armedModeGlyph = glyph
        keycap.glyph = glyph ?? cleanupGlyph
        keycap.lit = cleanupEnabled || glyph != nil
        keycap.needsDisplay = true
        if panel.isVisible && mode != .thinking { relayout() }
    }

    /// Show/hide the whole recording chrome in one shot (used when collapsing to / from the spinner).
    private func setRecordingChrome(hidden: Bool) {
        handle.isHidden = hidden; statusLabel.isHidden = hidden; settingsButton.isHidden = hidden
        wave.isHidden = hidden; transcription.isHidden = hidden; keycap.isHidden = hidden
        lockButton.isHidden = hidden; stopButton.isHidden = hidden
        pillToastLabel.isHidden = true   // never part of the recording chrome; the pill-toast shows it explicitly
        slider.isHidden = hidden || !cleanupEnabled
        recDot.isHidden = hidden || !showRec; recLabel.isHidden = hidden || !showRec
    }

    /// The compact "thinking" layout: a small CRT box centered where the HUD was, holding only the
    /// spinning wheel. When the HUD isn't up, it homes to the position setting like every layout.
    private func layoutThinking() {
        // The spinner rides in a transparent square whose size (and thus the ring's radius) follows the
        // spinner-size setting. The frosted box + CRT fill are hidden (see relayout), so only the ring
        // shows — a bigger square just gives a bigger ring, centered where the HUD was.
        let ss = CGFloat(Settings.hudSpinnerScale)
        let tw = round(200 * ss), th = round(130 * ss)
        let visibleOrigin: NSPoint?
        if panel.isVisible {
            let f = panel.frame
            visibleOrigin = NSPoint(x: f.midX - tw / 2, y: f.minY)
        } else {
            visibleOrigin = nil
        }
        let box = presentBox(panelSize: NSSize(width: tw, height: th), cornerRadius: 10,
                             visibleOrigin: visibleOrigin)
        panel.invalidateShadow()   // force the (now-off) window shadow to drop cleanly around the ring
        spinner.frame = box
        spinner.isHidden = false
        setRecordingChrome(hidden: true)
    }

    /// The Final-only layout: a small capsule holding ONLY the live oscilloscope — roughly an eighth
    /// of the full HUD. No REC dot, no status line, no transcript preview, no buttons; the chords
    /// still drive everything. This surface only says "the mic is hot and hearing you." The scope
    /// spans the FULL capsule width and `WaveformView` alpha-fades the trace at both rounded ends
    /// (no hard bounding box).
    private func layoutPill() {
        let ps = CGFloat(Settings.hudPillScale)
        let pw = round(HUDPillMetrics.baseWidth * ps), ph = round(HUDPillMetrics.baseHeight * ps)
        presentBox(panelSize: NSSize(width: pw, height: ph), cornerRadius: ph / 2)
        spinner.isHidden = true
        setRecordingChrome(hidden: true)   // hides the REC dot/label too — the pill is strictly the scope now
        recDot.isHidden = true
        recLabel.isHidden = true
        // The scope fills the whole capsule interior; the trace's alpha fade (WaveformView) softens
        // the left/right ends into the rounded caps.
        wave.isHidden = false
        wave.frame = NSRect(x: 0, y: 6, width: pw, height: ph - 12)
        updateInfoPill()   // the second, content-gated capsule below the scope
    }

    /// Phosphor-green attributed text for the low-power pill-toast — centered, with the same soft green
    /// glow as the full-box body, truncating tail so an over-long message clips gracefully at two lines.
    private func pillToastAttr(_ s: String, size: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = Phosphor.green.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 8
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 2
        para.lineBreakMode = .byWordWrapping   // measure + render wrap up to two lines (see label config)
        return NSAttributedString(string: s, attributes: [
            .font: NSFont(name: Phosphor.font, size: size) ?? .systemFont(ofSize: size, weight: .regular),
            .foregroundColor: Phosphor.green.withAlphaComponent(0.92),
            .shadow: shadow, .paragraphStyle: para,
        ])
    }

    /// The low-power IN-PILL status toast: a pill-styled capsule (same phosphor CRT look as the scope
    /// pill) grown ONLY as much as the message needs — wider for a longer line, taller up to ~2 lines —
    /// with the oscilloscope + info pill hidden for the dwell. It floors at the scope pill's own size so
    /// a short notice ("Nothing heard") is the same capsule the scope lived in (no jarring jump), and it
    /// homes to the same anchor as the scope pill so the anchored edge never moves as it grows.
    private func layoutPillToast() {
        let ps = CGFloat(Settings.hudPillScale)
        let baseW = round(HUDPillMetrics.baseWidth * ps)          // scope-pill width — the floor
        let baseH = round(HUDPillMetrics.baseHeight * ps)           // scope-pill height — the floor
        let padX = round(26 * ps)
        let padY = round(12 * ps)
        let fontSize = max(12, round(15 * ps))
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = min(round(660 * ps), vf.width - 96)   // cap so the toast stays pill-ish, never the full box

        let attr = pillToastAttr(currentText.isEmpty ? "…" : currentText, size: fontSize)
        let naturalW = ceil(attr.size().width)           // unconstrained single-line width
        let innerMaxW = maxW - 2 * padX
        let capW: CGFloat, textW: CGFloat
        if naturalW <= baseW - 2 * padX {
            capW = baseW; textW = baseW - 2 * padX       // fits within the base capsule (one line)
        } else if naturalW <= innerMaxW {
            capW = naturalW + 2 * padX; textW = naturalW // one line, grown wider than the base
        } else {
            capW = maxW; textW = innerMaxW               // wraps to <=2 lines at the max width
        }

        // Wrapped height within textW, capped to two lines.
        let lineH = ceil(attr.size().height)
        let twoLineH = lineH * 2 + 2                      // + lineSpacing
        let bounds = attr.boundingRect(with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textH = min(ceil(bounds.height), twoLineH)
        let capH = max(baseH, textH + 2 * padY)

        presentBox(panelSize: NSSize(width: capW, height: capH), cornerRadius: capH / 2)
        display.borderColor = nil                        // same borderless CRT look as the scope pill
        spinner.isHidden = true
        setRecordingChrome(hidden: true)                 // scope + REC + buttons hidden for the dwell
        recDot.isHidden = true; recLabel.isHidden = true

        pillToastLabel.attributedStringValue = attr
        pillToastLabel.frame = NSRect(x: (capW - textW) / 2, y: (capH - textH) / 2, width: textW, height: textH)
        pillToastLabel.isHidden = false
    }

    /// Refresh the low-power info pill (Item B) from the latched live state, anchored under the current
    /// scope-pill frame. Content-gated inside `InfoPillPanel`: nothing locked and cleanup off ⇒ no pill.
    private func updateInfoPill() {
        infoPill.apply(locked: lockedState, cleanupEnabled: cleanupEnabled, level: cleanupLevel,
                       bullseyeArmed: bullseyeArmed, armedModeGlyph: armedModeGlyph,
                       scope: panel.frame, ps: CGFloat(Settings.hudPillScale), animated: true)
    }

    /// Latch the sticky-note bullseye armed state and refresh the info pill so its bullseye glyph appears /
    /// disappears (notes-bullseye BT2). Content-gated inside `InfoPillPanel`. Re-anchors under the current
    /// scope only while the low-power pill is up; otherwise just latches for the next take.
    func setBullseyeArmed(_ armed: Bool) {
        bullseyeArmed = armed
        // Only the live scope pill carries the info pill; `mode == .pillScope` already excludes toast/thinking.
        if mode == .pillScope, panel.isVisible { updateInfoPill() }
    }

    func update(state: String, target: String?, text: String, locked: Bool) {
        toastTimer?.invalidate()
        // A real dictation state supersedes any lingering toast layout; the cleanup-wait spinner (thinking)
        // is not a toast and stays until setThinking(false) tears it down.
        if mode != .thinking { mode = recordingMode }
        lockedState = locked   // latch so the pill's info capsule can gate its lock glyph
        let up = state.uppercased()
        showRec = !(up.contains("TRANSCRIB") || up.contains("CLEAN"))
        let line = NSMutableAttributedString(attributedString:
            Phosphor.kerned(state.uppercased(), color: Phosphor.green.withAlphaComponent(0.5), size: 11, kern: 3))
        if let target = target {
            line.append(Phosphor.kerned("    \(target)", color: Phosphor.green.withAlphaComponent(0.28), size: 11, kern: 1))
        }
        statusLabel.attributedStringValue = line
        lockButton.set(title: locked ? "Unlock" : "Lock", symbol: locked ? "lock.open.fill" : "lock.fill")
        currentText = text
        renderText()
        relayout()
    }

    /// Show a transient status message. In Final-only a plain toast renders inside the scope pill (a
    /// capsule grown to fit); pass `forceFull: true` (as `answer()` does) to keep the full readable box
    /// even in Final-only. Live mode always uses the full box.
    func toast(_ message: String, duration: TimeInterval = 3.5, forceFull: Bool = false) {
        toastTimer?.invalidate()
        caretTimer?.invalidate(); caretTimer = nil
        refreshDisplaySettings()          // re-read Power Mode so the pill/full pick is current
        mode = toastMode(forceFull: forceFull)
        // A toast over a live take is transient, so preserve the origin chosen through the drag handle.
        // Standalone toasts keep the historical behavior of re-homing to the position setting.
        if !takeActive { userDragged = false }
        showRec = false
        statusLabel.attributedStringValue = NSAttributedString(string: "")
        currentText = message
        transcription.attributedStringValue = transcriptionAttr(message)   // full-box path (forceFull / full mode)
        presentForCurrentMode()
        // The dwell fires dismissToast(), NOT hide(): while a take is live it reverts to the recording
        // scope so the oscilloscope returns; only with no take live does it hide (BUG 1).
        toastTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.dismissToast() }
    }

    /// End a toast's dwell. If a take is still live (DictationController pushed `setTakeActive(true)`), the
    /// toast was a transient overlay ON TOP of an actively-recording take, so revert to the recording scope —
    /// re-summon the panel and restart the wave/caret — and the oscilloscope returns while audio keeps
    /// capturing. Only when no take is live is the toast the last thing on screen; then `hide()` as before,
    /// reserving `panel.orderOut(nil)` for the genuine take-end. Deciding this in HUDPanel (rather than
    /// auditing every toast call site) means it holds for every current and future toast.
    private func dismissToast() {
        toastTimer?.invalidate(); toastTimer = nil
        if thinkingActivity.isActive {
            presentThinking()
            return
        }
        guard takeActive else { hide(); return }
        refreshDisplaySettings()          // re-read Power Mode so the revert target matches the take
        mode = recordingMode
        showRec = true                    // recording shows the REC dot again (the toast hid it; the scope pill hides it regardless)
        presentForCurrentMode()           // re-orderFrontRegardless + restart the wave/caret for the recording scope
    }

    /// Land a web-search answer (Option+L / Option+G) in the read-only CRT box. Reuses the proven toast
    /// rendering (auto-sizes to the answer, non-activating, non-destructive — it never pastes into the
    /// focused field), but with a generous length-scaled dwell so a paragraph stays up long enough to
    /// read. The caller also copies the answer to the clipboard. Dismisses on its own timer.
    func answer(_ text: String) {
        // ~0.06s per character on top of a 12s floor, capped at 45s — a one-liner gets ~12s, a full
        // paragraph ~30-40s.
        let dwell = min(45.0, max(12.0, 12.0 + Double(text.count) * 0.06))
        toast(text, duration: dwell, forceFull: true)   // a paragraph stays in the full box in either mode
    }

    /// Offscreen render seam for `--hud-render`: lay out a Final-only `toast()` (in-pill capsule) or a
    /// forced-full toast / `answer()` (full box) for `message` WITHOUT ordering the panel on screen, and
    /// return a bitmap of the CRT `display` composite (capsule/box + text). In-process — no screen
    /// capture. The caller sets Power Mode and display scales via Settings before calling.
    func renderToastForSeam(message: String, forceFull: Bool) -> CGImage? {
        refreshDisplaySettings()
        mode = toastMode(forceFull: forceFull)
        userDragged = false
        showRec = false
        statusLabel.attributedStringValue = NSAttributedString(string: "")
        currentText = message
        transcription.attributedStringValue = transcriptionAttr(message)
        relayout()
        display.layoutSubtreeIfNeeded()
        let b = display.bounds
        guard b.width > 0, b.height > 0, let rep = display.bitmapImageRepForCachingDisplay(in: b) else { return nil }
        display.cacheDisplay(in: b, to: rep)
        return rep.cgImage
    }

    /// Test seam for `--hud-probe`: the live panel frame, so the layout probe can assert
    /// position/size numerically without reaching into the private panel.
    var frameForTesting: NSRect { panel.frame }

    /// Test seam for `--hud-probe`: mirror DragHandle.mouseDragged followed by mouseUp so the probe
    /// exercises the real onMoved closure that records both the panel origin and user-drag state.
    func simulateDragForTesting(to newOrigin: NSPoint) {
        panel.setFrameOrigin(newOrigin)
        handle.onMoved?(newOrigin)
    }

    /// Test seams for the Item-A scope pill: the scope's frame (to assert it now spans the full pill
    /// width) and whether the REC dot is hidden (it must be, in pill mode).
    var pillWaveFrameForTesting: NSRect { wave.frame }
    var pillRecDotHiddenForTesting: Bool { recDot.isHidden }

    /// Test seams for the BUG 1 revert pin: whether the panel is on screen, and whether the scope
    /// oscilloscope is animating. After a mid-take toast dwell reverts to the recording scope, BOTH must
    /// be true (under the old code the dwell called `hide()`, leaving the panel off-screen + wave stopped).
    var panelVisibleForTesting: Bool { panel.isVisible }
    var pillWaveActiveForTesting: Bool { wave.isRunningForTesting }

    /// Test seams for the Item-B info pill: whether it is currently shown (content-gated), and its
    /// capsule's on-screen frame (so the probe can assert more active elements ⇒ a wider pill). Both
    /// are synchronous logical targets, valid even mid-animation.
    var infoPillShownForTesting: Bool { infoPill.isShown }
    var infoPillFrameForTesting: NSRect { infoPill.capsuleTargetFrame }
    /// GUI-render seam: both HUD paths must consume the same rebound cleanup glyph.
    /// Offscreen render seam for `--hud-render` (V1): the pop-up mode badge, which is the keycap
    /// proportion REFERENCE the info pill was brought into line with. Returns the composite bitmap and
    /// the keycap geometry the badge laid out, so a change to the shared `KeycapView` has to prove it
    /// did not regress the surface that already looked right.
    func renderBadgeForSeam(glyph: String, label: String) -> CGImage? {
        badge.renderForSeam(glyph: glyph, label: label)
    }
    var badgeKeycapGeometryForTesting: (box: NSSize, fontSize: CGFloat, frame: NSRect, canvasHeight: CGFloat) {
        badge.keycapGeometryForTesting
    }
    /// The glyph the toast badge will draw for a Raw/Cleanup change — the live bound key, not `?`.
    var cleanupBadgeGlyphForTesting: String { cleanupGlyph }

    var cleanupGlyphsForTesting: (full: String, pill: String) {
        (keycap.glyph, infoPill.cleanupGlyphForTesting)
    }
    /// GUI-render seam for S2: an armed one-shot replaces Cleanup's glyph, lights the full-HUD keycap,
    /// and leaves the Cleanup-only slider hidden.
    var armedModeIndicatorForTesting: (glyph: String, lit: Bool, sliderHidden: Bool) {
        (keycap.glyph, keycap.lit, slider.isHidden)
    }
    /// Elements the info pill's state says should be showing but are effectively invisible (hidden or
    /// alpha≈0). Empty = healthy. Guards the cancelled-fade-in class (see HUDProbe).
    var infoPillInvisibleContentForTesting: [String] { infoPill.invisibleContentForTesting }
    /// Elements NOT in the info pill's current set that are still visible on screen (stray leak under
    /// the capsule). Empty = healthy. Symmetric to `infoPillInvisibleContentForTesting`; guards the
    /// stranded-content class (item 1a bleed / item 2 jumble). See HUDProbe.
    var infoPillStrayVisibleContentForTesting: [String] { infoPill.strayVisibleContentForTesting }

    // MARK: caret + text

    private func renderText() {
        let shown = currentText + (caretOn ? " ▋" : "")
        transcription.attributedStringValue = transcriptionAttr(shown.isEmpty ? "…" : shown)
    }
    private func startCaret() {
        caretTimer?.invalidate()
        caretOn = true
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.caretOn.toggle()
            self.renderText()
        }
    }
}
