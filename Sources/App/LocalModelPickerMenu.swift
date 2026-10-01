import Cocoa

/// The AppKit half of `LocalModelPickerItems`: putting its rows into an `NSPopUpButton` and reading the
/// chosen ref back out. Shared by the routing grid and the Sticky Skills cards so both menus are built and
/// read the same way.
extension LocalModelPickerItems {
    /// Append `items` to `popup` and select the chosen one. Each model row carries the bare model id as its
    /// `representedObject` (what every other picker row carries) and its full ref in its identifier.
    static func populate(_ popup: NSPopUpButton, with items: [Item]) {
        var chosen: NSMenuItem?
        for item in items {
            guard let ref = item.ref else {
                popup.menu?.addItem(NSMenuItem.separator())
                continue
            }
            popup.addItem(withTitle: item.title)
            popup.lastItem?.representedObject = ref.modelID
            popup.lastItem?.identifier = NSUserInterfaceItemIdentifier(itemIdentifier(for: ref))
            if item.isSelected { chosen = popup.lastItem }
        }
        if let chosen { popup.select(chosen) }
        showSelectedTitleAsToolTip(popup)
    }

    /// A popup this narrow truncates "Ollama · qwen3-coder:30b (19.00 GB)  ·  Custom" when it is closed, so
    /// the full selected title rides on the popup's tooltip. Call again after the selection changes.
    static func showSelectedTitleAsToolTip(_ popup: NSPopUpButton) {
        popup.toolTip = popup.titleOfSelectedItem
    }

    /// The ref of the selected row, or nil when the selection is not a Local model row.
    static func selectedRef(in popup: NSPopUpButton) -> LocalModelRef? {
        ref(fromItemIdentifier: popup.selectedItem?.identifier?.rawValue)
    }
}
