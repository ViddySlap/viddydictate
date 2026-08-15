import Cocoa

final class NotesSettingsView: NSView {
    private let contentWidth: CGFloat
    private var pathField: NSTextField!
    private var retentionPopup: NSPopUpButton!

    init(width: CGFloat) {
        self.contentWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 220))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let L: CGFloat = 20
        addSubview(sectionHeader("STICKY NOTES", y: 18))

        addSubview(label("Default save location", x: L, y: 48, w: contentWidth - 2 * L, bold: true))
        pathField = NSTextField(frame: NSRect(x: L, y: 72, width: contentWidth - 112, height: 24))
        pathField.isEditable = false
        pathField.isSelectable = true
        pathField.isBordered = true
        pathField.bezelStyle = .roundedBezel
        pathField.drawsBackground = true
        addSubview(pathField)

        let choose = NSButton(title: "Choose...", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: contentWidth - 84, y: 70, width: 70, height: 28)
        addSubview(choose)

        addSubview(label("History retention", x: L, y: 122, w: 130, bold: true))
        retentionPopup = NSPopUpButton(frame: NSRect(x: 154, y: 117, width: 180, height: 28), pullsDown: false)
        for option in StickyNotesRetention.allCases {
            retentionPopup.addItem(withTitle: option.label)
            retentionPopup.lastItem?.representedObject = option.rawValue
        }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        addSubview(retentionPopup)

        refresh()
    }

    private func refresh() {
        pathField.stringValue = Settings.stickyNotesSaveDirectory
        let raw = Settings.stickyNotesRetention.rawValue
        if let item = retentionPopup.itemArray.first(where: { ($0.representedObject as? String) == raw }) {
            retentionPopup.select(item)
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.stickyNotesSaveDirectoryURL
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.stickyNotesSaveDirectory = url.path
            self?.refresh()
        }
    }

    @objc private func retentionChanged() {
        let raw = (retentionPopup.selectedItem?.representedObject as? String) ?? StickyNotesRetention.oneDay.rawValue
        let retention = StickyNotesRetention(rawValue: raw) ?? .oneDay
        StickyNotesStore.shared.setRetention(retention)
    }

    private func sectionHeader(_ s: String, y: CGFloat) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = .secondaryLabelColor
        t.frame = NSRect(x: 20, y: y, width: 300, height: 14)
        return t
    }

    private func label(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat, bold: Bool) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12, weight: bold ? .medium : .regular)
        t.frame = NSRect(x: x, y: y, width: w, height: 16)
        return t
    }
}
