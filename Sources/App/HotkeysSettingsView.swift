import Cocoa

/// The binding half of the Hotkeys page (glossary "Hotkeys page", 2026-07-06 grill). Top is a compact
/// legend (every chord + a one-line description). Below, in order:
///  - the dictation wakeup (rebind),
///  - the core keys as rebind-only rows (chord editable, nothing else),
///  - restore-all, the help text, and the conflict status line.
///
/// Since L9 merged Models into Hotkeys, every hotkey that RUNS A MODEL — Option+P, Option+M, the two
/// web-search modes, and each custom hotkey — is drawn inside its own routing card further down the same
/// tab, with its chord, input, landing and Toggleable controls supplied from here through
/// `HotkeyBindingRowSource` and its provider/model/effort/prompt controls supplied by
/// `ModelsPowerSettingsView`. Nothing was removed by that move: the binding controls are the same
/// controls, built by the same code, hosted next to the routing they belong to.
///
/// Persistence: built-in chords + wakeup edit a `HotkeyMap` (UserDefaults); custom modes edit the
/// `CustomModeStore` (app-local JSON) — this view keeps sole ownership of both, so routing never becomes
/// a second binding authority any more than binding is a second routing authority. Every capture is
/// conflict-checked across the WHOLE namespace via `HotkeyConflicts` (built-ins + wakeup + custom).
/// Structural changes rebuild the view and fire `onStructuralChange` so the routing half re-renders;
/// `onChanged` reloads the live tap (map + custom chords).
final class HotkeysSettingsView: NSView {
    override var isFlipped: Bool { true }

    /// Arm capture in the live tap. The view passes a (onCapture, onCancel) pair; the controller wires
    /// these to `HotkeyMonitor.beginCapture`.
    var beginCapture: ((@escaping (KeySpec) -> Void, @escaping () -> Void) -> Void)?
    /// Cancel an in-flight capture (the view closed / a second click).
    var cancelCapture: (() -> Void)?
    /// Fired after any persisted change so the controller can reload the live tap (map + custom chords).
    var onChanged: (() -> Void)?
    /// Fired alongside `onChanged` for changes that alter what a routing card must DRAW — a chord, a
    /// name, an input/landing trait, an added or removed custom hotkey. The merged tab re-renders the
    /// routing half on it, so a card and its binding row can never disagree.
    var onStructuralChange: (() -> Void)?
    /// Fired after every rebuild, once this view has resized itself to its content, so the merged tab can
    /// re-stack. A standalone host can ignore it.
    var onContentChanged: (() -> Void)?

    private var map = HotkeyMap.load()
    private let store: CustomModeStore
    private let stickySkillStore: StickySkillStore
    private var capturing = false
    private weak var capturingButton: KeycapButton?
    private var statusLabel: NSTextField!
    private var statusTimer: Timer?

    private(set) var contentHeight: CGFloat = 0
    private let W: CGFloat
    private let L: CGFloat = 20

    init(width: CGFloat, customStore: CustomModeStore = .shared,
         stickySkillStore: StickySkillStore = .shared) {
        self.W = width
        self.store = customStore
        self.stickySkillStore = stickySkillStore
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    /// The commands that run no model at all, so a chord is the only thing there is to edit. Every OTHER
    /// command — P, M, and the two web-search modes — has an LLM route, and since L9 its chord is edited
    /// on that route's card rather than here, beside the model and prompt it shares a hotkey with.
    private let rebindOnlyCore: [HotkeyCommand] = [.lock, .cleanupToggle, .undo, .levelUp, .levelDown, .notes, .dictionary,
                                                   .bullseyeToggle, .bullseyeReveal]

    /// The hotkey that fires each routed card, keyed by the card's route key. The merged tab reads this
    /// in one direction only: routing asks which hotkey owns a route, never the reverse.
    static func hotkeyCommand(forRouteKey key: String) -> HotkeyCommand? {
        switch key {
        case LLMRouteID.promptPrep.rawValue:        return .cleanupSelection
        case LLMRouteID.email.rawValue:             return .email
        case LLMRouteID.searchLocalSynth.rawValue:  return .searchLocal
        case LLMRouteID.searchGeminiSynth.rawValue: return .searchGemini
        default:                                    return nil   // "cleanup" rides the wakeup + level keys
        }
    }

    // MARK: - build

    /// Tear down and re-lay-out from the current map + store. Called on init and after any structural
    /// change (rebind, custom add/delete) so the legend + rows stay in sync.
    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        map = HotkeyMap.load()
        store.load()
        var y: CGFloat = 16

        // LEGEND
        y = header("LEGEND  (hold the wakeup, tap a key)", y: y)
        y = legendRow(key: map.wakeup.label, desc: "Dictation wakeup — hold to dictate", y: y)
        for c in HotkeyCommand.displayOrder {
            y = legendRow(key: map.key(for: c).label, desc: c.label, y: y)
        }
        for m in visibleCustomModes {
            y = legendRow(key: m.hasChord ? m.chord.label : "—",
                          desc: (m.name.isEmpty ? "(unnamed custom mode)" : m.name) + " (custom)", y: y)
        }
        y += 10

        // DICTATION WAKEUP
        y = header("DICTATION WAKEUP", y: y)
        y = rebindRow(owner: .wakeup, title: "Hold to dictate",
                      hint: "The held push-to-talk key (any key; a modifier is cleanest)",
                      keyLabel: map.wakeup.label, y: y)
        y += 8

        // CORE KEYS (rebind only)
        y = header("CORE KEYS  (rebind only)", y: y)
        for c in rebindOnlyCore {
            y = rebindRow(owner: .builtin(c), title: c.label, hint: c.hint, keyLabel: map.key(for: c).label, y: y)
        }
        y += 8

        // Restore-all + help + status. Every model-running hotkey now lives in a card below, so the page
        // says where they went rather than leaving a reader to find out by scrolling.
        let restoreAll = NSButton(title: "Restore all default hotkeys", target: self, action: #selector(restoreAll))
        restoreAll.bezelStyle = .rounded
        restoreAll.frame = NSRect(x: L, y: y, width: 220, height: 28)
        addSubview(restoreAll)
        y += 34

        let help = wrapHint("Click a key, then press the new key (Esc cancels). Any key works; a regular key "
                            + "becomes unavailable for typing while ViddyDictate runs, since every press triggers "
                            + "dictation. Every hotkey that runs a model — Option+P, Option+M, the two web-search "
                            + "keys, and each custom hotkey — is configured in its own card below: chord, input, "
                            + "landing, provider, model, effort and prompt in one place.",
                            x: L, y: y, width: W - 2 * L, height: 62)
        addSubview(help); y += 66

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: L, y: y, width: W - 2 * L, height: 16)
        addSubview(statusLabel)
        y += 24

        contentHeight = y
        frame = NSRect(x: 0, y: 0, width: W, height: y)
        onContentChanged?()
    }

    /// Rebuild from the current map + store on demand (the merged tab does this when a routing card edits
    /// a custom mode, so the legend cannot go stale).
    func refresh() { rebuild() }

    // MARK: - rows

    /// A legend line: a compact key chip + a one-line description.
    private func legendRow(key: String, desc: String, y: CGFloat) -> CGFloat {
        let chip = NSTextField(labelWithString: key)
        chip.font = NSFont(name: "Helvetica Neue", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        chip.textColor = Phosphor.green
        chip.lineBreakMode = .byTruncatingTail
        chip.frame = NSRect(x: L, y: y, width: 74, height: 15)
        addSubview(chip)
        let d = NSTextField(labelWithString: desc)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.lineBreakMode = .byTruncatingTail
        d.frame = NSRect(x: L + 82, y: y, width: W - L - 82 - L, height: 15)
        addSubview(d)
        return y + 17
    }

    /// A rebind-only row: title + hint on the left, a keycap button + per-row Restore on the right.
    private func rebindRow(owner: HotkeyOwner, title: String, hint: String, keyLabel: String, y: CGFloat) -> CGFloat {
        let rowH: CGFloat = 40
        addSubview(label(title, x: L, y: y + 2, w: W - L - 200, size: 12.5, weight: .medium, color: .labelColor))
        let h = label(hint, x: L, y: y + 19, w: W - L - 200, size: 10.5, weight: .regular, color: .secondaryLabelColor)
        h.lineBreakMode = .byTruncatingTail
        addSubview(h)

        addSubview(keycap(owner: owner, label: keyLabel, x: W - 178, y: y + 4))
        addSubview(restoreButton(owner: owner, x: W - 62, y: y + 5))
        return y + rowH
    }

    // MARK: - merged-tab binding rows (L9)

    /// The binding controls for one hotkey, laid out into a free-standing row that a routing card hosts.
    /// Built fresh on every routing rebuild, and every control still targets THIS view — so capture, the
    /// whole-namespace conflict check, and custom-mode persistence keep the single owner they had when
    /// these rows lived on their own tab.
    private func builtinBindingRow(command: HotkeyCommand, width: CGFloat) -> NSView {
        let owner = HotkeyOwner.builtin(command)
        // Only P and M carry one-shot input/landing traits; the web-search modes are chord-only because
        // their retrieval shape is fixed, exactly as before the merge.
        let descriptor: OneShotMode? = {
            switch command {
            case .cleanupSelection: return OneShotMode.cleanupSelection
            case .email:            return OneShotMode.email
            default:                return nil
            }
        }()
        let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        var y: CGFloat = 0

        host.addSubview(label("Chord", x: 0, y: y + 6, w: 44, size: 10.5,
                              weight: .regular, color: .secondaryLabelColor))
        host.addSubview(keycap(owner: owner, label: map.key(for: command).label, x: 48, y: y))
        host.addSubview(restoreButton(owner: owner, x: 166, y: y + 1))
        y += 32

        if let descriptor {
            let inputFixed = command == .cleanupSelection ? "Selection" : "Dictation or selection"
            host.addSubview(label("Input", x: 0, y: y + 3, w: 44, size: 10.5,
                                  weight: .regular, color: .secondaryLabelColor))
            host.addSubview(fixedField(value: inputFixed, x: 48, y: y, w: 150))
            host.addSubview(label("Landing", x: 208, y: y + 3, w: 52, size: 10.5,
                                  weight: .regular, color: .secondaryLabelColor))
            host.addSubview(fixedField(value: "Replace in place", x: 264, y: y,
                                       w: max(120, width - 264)))
            y += 28
            if descriptor.supportsPersistentToggle {
                host.addSubview(toggleableCheckbox(modeID: descriptor.id, x: 0, y: y))
                y += 24
            }
        }

        host.frame.size.height = y
        return host
    }

    /// The same row for a user-defined custom hotkey: its name, its chord, its input/landing traits, its
    /// Toggleable trait, and Remove. Its shared task prompt and provider/model/effort sit in the very card
    /// that hosts this row, which is the whole point of the merge.
    private func customBindingRow(_ m: CustomMode, width: CGFloat) -> NSView {
        let host = FlippedContainerView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        var y: CGFloat = 0

        host.addSubview(label("Name", x: 0, y: y + 4, w: 44, size: 10.5,
                              weight: .regular, color: .secondaryLabelColor))
        let name = NSTextField(string: m.name)
        name.placeholderString = "name"
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.frame = NSRect(x: 48, y: y + 1, width: max(120, width - 238), height: 22)
        name.identifier = NSUserInterfaceItemIdentifier("name|custom:\(m.id)")
        name.target = self
        name.action = #selector(nameChanged(_:))
        host.addSubview(name)
        host.addSubview(keycap(owner: .custom(id: m.id, name: m.name),
                               label: m.hasChord ? m.chord.label : "set a key", x: width - 182, y: y))
        let remove = NSButton(title: "Remove", target: self, action: #selector(deleteClicked(_:)))
        remove.bezelStyle = .inline
        remove.font = .systemFont(ofSize: 10.5)
        remove.identifier = NSUserInterfaceItemIdentifier("delete|\(m.id)")
        remove.frame = NSRect(x: width - 66, y: y + 2, width: 62, height: 22)
        host.addSubview(remove)
        y += 32

        host.addSubview(label("Input", x: 0, y: y + 3, w: 44, size: 10.5,
                              weight: .regular, color: .secondaryLabelColor))
        host.addSubview(enumPopup(options: CustomInput.allCases.map { ($0.label, $0.rawValue) },
                                  selectedRaw: m.input.rawValue, identifier: "input|\(m.id)",
                                  action: #selector(inputChanged(_:)), x: 48, y: y, w: 150))
        host.addSubview(label("Landing", x: 208, y: y + 3, w: 52, size: 10.5,
                              weight: .regular, color: .secondaryLabelColor))
        host.addSubview(enumPopup(options: CustomLanding.allCases.map { ($0.label, $0.rawValue) },
                                  selectedRaw: m.landing.rawValue, identifier: "landing|\(m.id)",
                                  action: #selector(landingChanged(_:)), x: 264, y: y,
                                  w: max(120, width - 264)))
        y += 28
        if m.oneShotMode.supportsPersistentToggle {
            host.addSubview(toggleableCheckbox(modeID: m.oneShotMode.id, x: 0, y: y))
            y += 24
        }

        host.frame.size.height = y
        return host
    }

    // MARK: - control builders

    private func keycap(owner: HotkeyOwner, label: String, x: CGFloat, y: CGFloat) -> KeycapButton {
        let btn = KeycapButton(keyLabel: label)
        btn.frame = NSRect(x: x, y: y, width: 110, height: 26)
        btn.owner = owner
        btn.identifier = NSUserInterfaceItemIdentifier("chord|\(ownerKey(owner))")
        btn.target = self
        btn.action = #selector(keycapClicked(_:))
        return btn
    }

    /// Prefixed `hotkey-restore|` rather than `restore|`: since L9 a binding row shares a card with the
    /// routing half's own `restore|<card>|<provider>` buttons, and two different owners parsing the same
    /// identifier prefix is exactly how the wrong thing gets restored.
    private func restoreButton(owner: HotkeyOwner, x: CGFloat, y: CGFloat) -> NSButton {
        let b = NSButton(title: "Restore", target: self, action: #selector(restoreOne(_:)))
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 10.5)
        b.identifier = NSUserInterfaceItemIdentifier("hotkey-restore|\(ownerKey(owner))")
        b.frame = NSRect(x: x, y: y, width: 50, height: 24)
        return b
    }

    /// A locked field (a disabled popup showing a fixed value) — used for the migrated P/M input +
    /// landing, whose special traits are not knobs.
    private func fixedField(value: String, x: CGFloat, y: CGFloat, w: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: w, height: 24), pullsDown: false)
        p.addItem(withTitle: value)
        p.isEnabled = false
        return p
    }

    private func enumPopup(options: [(String, String)], selectedRaw: String, identifier: String,
                           action: Selector, x: CGFloat, y: CGFloat, w: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: w, height: 24), pullsDown: false)
        for (title, raw) in options {
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = raw
        }
        if let idx = options.firstIndex(where: { $0.1 == selectedRaw }) { p.selectItem(at: idx) }
        p.identifier = NSUserInterfaceItemIdentifier(identifier)
        p.target = self
        p.action = action
        return p
    }

    private func toggleableCheckbox(modeID: String, x: CGFloat, y: CGFloat) -> NSButton {
        let b = NSButton(checkboxWithTitle: "Toggleable", target: self,
                         action: #selector(toggleableChanged(_:)))
        b.font = .systemFont(ofSize: 10.5)
        b.identifier = NSUserInterfaceItemIdentifier("toggleable|\(modeID)")
        b.state = Settings.persistentToggleEnabled(for: modeID) ? .on : .off
        b.frame = NSRect(x: x, y: y, width: 110, height: 20)
        return b
    }

    // MARK: - capture (rebind)

    @objc private func keycapClicked(_ sender: KeycapButton) {
        guard let owner = sender.owner else { return }
        if capturing { return }
        capturing = true
        capturingButton = sender
        sender.setCapturing(true)
        clearStatus()
        beginCapture?({ [weak self] spec in
            self?.handleCaptured(spec, owner: owner, button: sender)
        }, { [weak self] in
            self?.handleCancelled(owner: owner, button: sender)
        })
    }

    private func handleCaptured(_ spec: KeySpec, owner: HotkeyOwner, button: KeycapButton) {
        capturing = false
        button.setCapturing(false)
        if let other = HotkeyConflicts.owner(of: spec, in: map, custom: visibleCustomModes,
                                             excluding: owner) {
            toast("\"\(spec.label)\" is already used by \(other.label) — pick another")
            button.setKeyLabel(currentLabel(owner))   // revert
            return
        }
        guard assign(spec, to: owner) else { return }
        onChanged?()
        onStructuralChange?()   // the keycap may live in a routing card, which redraws from the map
        rebuild()   // refresh the legend + this row's keycap
    }

    private var visibleCustomModes: [CustomMode] {
        StickySkillRegistry.hotkeyVisibleModes(store.modes, skills: stickySkillStore.skills)
    }

    private func handleCancelled(owner: HotkeyOwner, button: KeycapButton) {
        capturing = false
        button.setCapturing(false)
        button.setKeyLabel(currentLabel(owner))
    }

    /// Apply a captured key to its owner (map slot or custom mode chord).
    private func assign(_ spec: KeySpec, to owner: HotkeyOwner) -> Bool {
        switch owner {
        case .wakeup:
            map.assign(spec, to: .wakeup); map.save()
        case .builtin(let c):
            map.assign(spec, to: .command(c)); map.save()
        case .custom(let id, _):
            guard var m = store.mode(id: id) else { return false }
            m.chord = spec
            guard saveCustom(m) else { return false }
        }
        return true
    }

    // MARK: - field actions

    @objc private func inputChanged(_ sender: NSPopUpButton) {
        guard let id = idFrom(sender, prefix: "input|"),
              let raw = sender.selectedItem?.representedObject as? String,
              let input = CustomInput(rawValue: raw), var m = store.mode(id: id) else { return }
        m.input = input
        if saveCustom(m) {
            onChanged?()
            rebuild()
        }
    }

    @objc private func landingChanged(_ sender: NSPopUpButton) {
        guard let id = idFrom(sender, prefix: "landing|"),
              let raw = sender.selectedItem?.representedObject as? String,
              let landing = CustomLanding(rawValue: raw), var m = store.mode(id: id) else { return }
        m.landing = landing
        if saveCustom(m) {
            onChanged?()
            rebuild()
        }
    }

    @objc private func toggleableChanged(_ sender: NSButton) {
        guard let modeID = idFrom(sender, prefix: "toggleable|") else { return }
        Settings.setPersistentToggle(sender.state == .on, for: modeID)
        onChanged?()
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        guard let id = idFrom(sender, prefix: "name|custom:"), var m = store.mode(id: id) else { return }
        m.name = sender.stringValue
        if saveCustom(m) { onChanged?() } else { rebuild() }
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.replacingOccurrences(of: "delete|", with: ""), !id.isEmpty else { return }
        do { try store.delete(id: id) }
        catch { toast("Could not delete custom mode — \(error.localizedDescription)"); return }
        onChanged?()
        rebuild()
    }

    @objc private func addNewHotkey() {
        guard saveCustom(CustomMode.blank(id: CustomModeStore.newId())) else { return }
        onChanged?()
        rebuild()
    }

    // MARK: - restore

    @objc private func restoreOne(_ sender: NSButton) {
        guard let key = stripIdentifierPrefix(sender.identifier, prefix: "hotkey-restore|") else { return }
        if capturing { cancelActiveCapture() }
        switch key {
        case "wakeup": map.restoreDefault(.wakeup)
        default:
            if key.hasPrefix("builtin:"), let c = HotkeyCommand(rawValue: String(key.dropFirst("builtin:".count))) {
                map.restoreDefault(.command(c))
            }
        }
        map.save()
        onChanged?()
        onStructuralChange?()
        rebuild()
    }

    @objc private func restoreAll() {
        if capturing { cancelActiveCapture() }
        map = HotkeyMap.defaults()
        map.save()
        clearStatus()
        onChanged?()
        onStructuralChange?()
        rebuild()
    }

    private func cancelActiveCapture() {
        capturing = false
        cancelCapture?()
        capturingButton?.setCapturing(false)
    }

    // MARK: - helpers

    private func ownerKey(_ owner: HotkeyOwner) -> String {
        switch owner {
        case .wakeup:         return "wakeup"
        case .builtin(let c): return "builtin:\(c.rawValue)"
        case .custom(let id, _): return "custom:\(id)"
        }
    }

    private func currentLabel(_ owner: HotkeyOwner) -> String {
        switch owner {
        case .wakeup:            return map.wakeup.label
        case .builtin(let c):    return map.key(for: c).label
        case .custom(let id, _): return store.mode(id: id)?.chord.label ?? "set a key"
        }
    }

    static func ownerKeyFrom(_ control: NSControl, prefix: String) -> String? {
        stripIdentifierPrefix(control.identifier, prefix: prefix)
    }
    private func idFrom(_ control: NSControl, prefix: String) -> String? {
        Self.ownerKeyFrom(control, prefix: prefix)
    }

    private func toast(_ msg: String) {
        statusLabel.stringValue = msg
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.clearStatus()
        }
    }

    @discardableResult
    private func saveCustom(_ mode: CustomMode) -> Bool {
        do {
            try store.upsert(mode)
            return true
        } catch {
            toast("Could not save custom mode — \(error.localizedDescription)")
            return false
        }
    }
    private func clearStatus() { statusTimer?.invalidate(); statusLabel?.stringValue = "" }

    @discardableResult
    private func header(_ s: String, y: CGFloat) -> CGFloat {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = .secondaryLabelColor
        t.frame = NSRect(x: L, y: y, width: W - 2 * L, height: 14)
        addSubview(t)
        return y + 20
    }

    private func label(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat,
                       weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.frame = NSRect(x: x, y: y, width: w, height: max(14, size + 3))
        return t
    }

    private func wrapHint(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 10.5)
        t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: x, y: y, width: width, height: height)
        return t
    }
}

// MARK: - the merged tab's binding source

/// L9: the Hotkeys page hands its binding controls to the routing cards that share a hotkey with them.
/// Everything here is a factory — the caller owns where the controls sit, this view still owns what they
/// do — so a card and the page can never hold two different ideas of a chord.
extension HotkeysSettingsView: HotkeyBindingRowSource {
    func hotkeyBindingRow(routeKey: String, customID: String?, width: CGFloat) -> NSView? {
        if let customID {
            guard let mode = store.mode(id: customID) else { return nil }
            return customBindingRow(mode, width: width)
        }
        guard let command = Self.hotkeyCommand(forRouteKey: routeKey) else { return nil }
        return builtinBindingRow(command: command, width: width)
    }

    func hotkeyAddControl() -> NSView {
        let add = NSButton(title: "+  Add new hotkey", target: self, action: #selector(addNewHotkey))
        add.bezelStyle = .rounded
        add.identifier = NSUserInterfaceItemIdentifier("add-new-hotkey")
        add.frame = NSRect(x: 0, y: 0, width: 200, height: 28)
        return add
    }
}

/// A keycap-styled button that shows the bound key and, while capturing, prompts for a press. Carries
/// the `HotkeyOwner` it rebinds (wakeup / built-in command / custom mode), so one action handler serves
/// every row.
final class KeycapButton: NSButton {
    var owner: HotkeyOwner?

    init(keyLabel: String) {
        super.init(frame: .zero)
        bezelStyle = .roundRect
        setButtonType(.momentaryPushIn)
        font = NSFont(name: "Helvetica Neue", size: 12) ?? .systemFont(ofSize: 12, weight: .medium)
        setKeyLabel(keyLabel)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    func setKeyLabel(_ label: String) {
        title = label
        contentTintColor = nil
    }

    func setCapturing(_ on: Bool) {
        if on {
            title = "press a key…"
            contentTintColor = Phosphor.green
        } else {
            contentTintColor = nil
        }
        isEnabled = true
    }
}
