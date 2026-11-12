import Cocoa

/// The Option+D pop-up: a borderless panel beside the mouse pointer for adding ONE dictionary entry.
/// It copies the Recent dictations pop-up's chrome and dismissal rules (`RecentDictationsPanel`) and
/// differs in one thing: it must take the keyboard, so `canBecomeKey` is true. Two fields ("When I say",
/// "always write"), a column choice, a live list of similar existing entries, and an Add button that is
/// on only when the model says the pair is new. Every write goes through
/// `CorrectionDictionary.addIfNew`; this file never saves the dictionary itself.
final class DictionaryAddPanel: NSPanel, NSTextFieldDelegate {
    private let onOpenDictionary: () -> Void
    private let container = FlippedContainer()
    private let titleLabel = NSTextField(labelWithString: "Add to dictionary")
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let columnControl = NSSegmentedControl(labels: ["Hard-coded", "Context-aware"],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    private let heardField = NSTextField(string: "")
    private let intendedField = NSTextField(string: "")
    private var hintRows: [(text: NSTextField, tag: NSTextField)] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Dictionary", target: nil, action: nil)
    private var statusToken = CopyTitleToken()
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    private static let panelWidth: CGFloat = 400
    private static let panelHeight: CGFloat = 284
    private static let pad: CGFloat = 12
    private static let hintRowH: CGFloat = 18

    override var canBecomeKey: Bool { true }

    init(onOpenDictionary: @escaping () -> Void) {
        self.onOpenDictionary = onOpenDictionary
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
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

        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        contentView = root
        container.frame = root.bounds
        container.wantsLayer = true
        container.layer?.backgroundColor = Phosphor.panelBG.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Phosphor.green.withAlphaComponent(0.35).cgColor
        root.addSubview(container)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    // MARK: content

    private func buildContent() {
        let pad = Self.pad
        let inner = Self.panelWidth - 2 * pad

        titleLabel.font = NSFont(name: Phosphor.font, size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Phosphor.green
        titleLabel.frame = NSRect(x: pad, y: 12, width: inner - 70, height: 18)
        container.addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.font = .systemFont(ofSize: 11)
        closeButton.frame = NSRect(x: Self.panelWidth - pad - 60, y: 10, width: 60, height: 22)
        container.addSubview(closeButton)

        columnControl.controlSize = .small
        columnControl.target = self
        columnControl.action = #selector(columnChanged)
        columnControl.selectedSegment = 0
        columnControl.frame = NSRect(x: pad, y: 40, width: inner, height: 22)
        container.addSubview(columnControl)

        for (field, placeholder, y) in [(heardField, "vidi dictate", CGFloat(72)),
                                        (intendedField, "ViddyDictate", CGFloat(100))] {
            field.font = .systemFont(ofSize: 12)
            field.placeholderString = placeholder
            field.delegate = self
            field.frame = NSRect(x: pad, y: y, width: inner, height: 22)
            container.addSubview(field)
        }
        heardField.nextKeyView = intendedField
        intendedField.nextKeyView = heardField

        for i in 0..<DictionaryAddModel.maxHints {
            let y = 132 + CGFloat(i) * Self.hintRowH
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: 11)
            text.textColor = .labelColor
            text.lineBreakMode = .byTruncatingTail
            text.frame = NSRect(x: pad, y: y, width: inner - 92, height: 16)
            text.isHidden = true
            let tag = NSTextField(labelWithString: "")
            tag.font = .systemFont(ofSize: 9.5)
            tag.textColor = .tertiaryLabelColor
            tag.alignment = .right
            tag.frame = NSRect(x: Self.panelWidth - pad - 88, y: y + 1, width: 88, height: 14)
            tag.isHidden = true
            container.addSubview(text)
            container.addSubview(tag)
            hintRows.append((text, tag))
        }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: pad, y: 228, width: inner, height: 16)
        container.addSubview(statusLabel)

        openButton.target = self
        openButton.action = #selector(openDictionaryTapped)
        openButton.isBordered = false
        openButton.font = .systemFont(ofSize: 12)
        openButton.contentTintColor = Phosphor.green
        openButton.frame = NSRect(x: pad, y: 250, width: 130, height: 22)
        container.addSubview(openButton)

        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        addButton.frame = NSRect(x: Self.panelWidth - pad - 70, y: 248, width: 70, height: 26)
        container.addSubview(addButton)
    }

    // MARK: show / dismiss

    /// Show the pop-up beside the pointer, reset to a fresh add (Hard-coded selected, fields empty), and
    /// put the cursor in the first field.
    func show() {
        resetContent()
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = RecentDictationsPlacement.origin(for: frame.size, pointer: pointer, in: visible)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(heardField)
        installMonitors()
    }

    /// Remove every monitor and hide the panel. Called by every dismissal path and by the controller's
    /// second Option+D.
    func dismiss() {
        removeMonitors()
        orderOut(nil)
    }

    private func resetContent() {
        _ = statusToken.press()
        columnControl.selectedSegment = 0
        heardField.stringValue = ""
        intendedField.stringValue = ""
        refresh()
    }

    // MARK: live search and verdict

    private func selectedColumn() -> DictionaryColumn {
        columnControl.selectedSegment == 1 ? .contextAware : .hardCoded
    }

    private static func columnName(_ column: DictionaryColumn) -> String {
        column == .contextAware ? "Context-aware" : "Hard-coded"
    }

    /// Re-list the similar entries and set the Add button and the status line from the model's verdict.
    private func refresh() {
        let store = CorrectionDictionary.shared
        let entries = CorrectionDictionary.addEntries(hardCoded: store.hardCoded, contextAware: store.contextAware)
        let heard = heardField.stringValue
        let intended = intendedField.stringValue

        let matches = DictionaryAddModel.search(query: heard, entries: entries)
        for (i, row) in hintRows.enumerated() {
            if i < matches.count {
                let e = matches[i].entry
                row.text.stringValue = "\(e.heard) → \(e.intended)"
                row.tag.stringValue = Self.columnName(e.column)
                row.text.isHidden = false
                row.tag.isHidden = false
            } else {
                row.text.stringValue = ""
                row.tag.stringValue = ""
                row.text.isHidden = true
                row.tag.isHidden = true
            }
        }

        switch DictionaryAddModel.verdict(heard: heard, intended: intended, entries: entries) {
        case .ok:
            addButton.isEnabled = true
            setStatus("", color: .systemRed)
        case .blank:
            addButton.isEnabled = false
            setStatus("", color: .systemRed)
        case .duplicate(let existing):
            addButton.isEnabled = false
            showDuplicate(existing)
        }
    }

    private func showDuplicate(_ existing: DictionaryAddEntry) {
        setStatus("Already in the dictionary (\(Self.columnName(existing.column))): "
                  + "\(existing.heard) → \(existing.intended)", color: .systemRed)
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    func controlTextDidChange(_ obj: Notification) {
        _ = statusToken.press()
        refresh()
    }

    /// Return inside a field: add when Add is on, otherwise do nothing (no beep, no close).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if addButton.isEnabled { addTapped() }
            return true
        }
        return false
    }

    // MARK: actions

    @objc private func columnChanged() { refresh() }

    @objc private func closeTapped() { dismiss() }

    @objc private func openDictionaryTapped() {
        onOpenDictionary()
        dismiss()
    }

    /// Add reads the verdict the store returns; it does not trust the earlier live one.
    @objc private func addTapped() {
        let column = selectedColumn()
        let verdict = CorrectionDictionary.shared.addIfNew(heard: heardField.stringValue,
                                                           intended: intendedField.stringValue, column: column)
        switch verdict {
        case .ok:
            heardField.stringValue = ""
            intendedField.stringValue = ""
            refresh()
            setStatus("Added", color: Phosphor.green)
            let token = statusToken.press()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, self.statusToken.isCurrent(token) else { return }
                self.refresh()
            }
            makeFirstResponder(heardField)
        case .duplicate(let existing):
            addButton.isEnabled = false
            showDuplicate(existing)
        case .blank:
            refresh()
        }
    }

    // MARK: dismissal

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func installMonitors() {
        removeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors see every window of the app: an Esc meant for Settings or the Recent pop-up
            // passes through untouched.
            guard let self, self.isVisible, event.window === self else { return event }
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

/// Top-left origin, so the panel's rows are laid out top to bottom.
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
