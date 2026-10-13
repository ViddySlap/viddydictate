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

    /// The two-step Local picker: the app popup lists `appChoices` (LM Studio first) with the pinned
    /// ref's app shown, then the model popup holds that app's own models. When the pin belongs to the
    /// shown app its row is selected; when it does not (the user switched apps), `populateModelPopup`
    /// puts `modelPlaceholder` up as the selected row and NOTHING is written. Returns the shown app so a
    /// caller can remember a switched choice; the pin is never read or written here.
    @discardableResult
    static func populateAppModel(_ appPopup: NSPopUpButton, _ modelPopup: NSPopUpButton,
                                 options: [LMStudioModelOption], pinned: LocalModelRef?,
                                 suffix: @escaping (LocalModelRef) -> String = { _ in "" })
        -> LocalBackendID? {
        let choices = appChoices(options: options)
        let shown = shownApp(options: options, selected: pinned)
        appPopup.removeAllItems()
        for app in choices {
            appPopup.addItem(withTitle: app.displayName)
            appPopup.lastItem?.representedObject = app.rawValue
            appPopup.lastItem?.identifier = NSUserInterfaceItemIdentifier(app.rawValue)
        }
        if let shown, let item = appPopup.itemArray.first(where: {
            ($0.representedObject as? String) == shown.rawValue
        }) {
            appPopup.select(item)
        }
        populateModelPopup(modelPopup, for: shown, options: options, selected: pinned, suffix: suffix)
        return shown
    }

    /// Repopulate just the model popup for `app`. Called when the app popup changes (so switching apps
    /// never changes a route's pin) and by `populateAppModel` at build time. `modelPlaceholder` is the
    /// selected row when the shown app carries none of the pin.
    static func populateModelPopup(_ popup: NSPopUpButton, for app: LocalBackendID?,
                                   options: [LMStudioModelOption], selected: LocalModelRef?,
                                   suffix: (LocalModelRef) -> String = { _ in "" }) {
        popup.removeAllItems()
        guard let app else {
            popup.addItem(withTitle: modelPlaceholder)
            popup.lastItem?.representedObject = ""
            popup.isEnabled = false
            showSelectedTitleAsToolTip(popup)
            return
        }
        popup.isEnabled = true
        var chosen: NSMenuItem?
        if showsModelPlaceholder(for: app, selected: selected) {
            popup.addItem(withTitle: modelPlaceholder)
            popup.lastItem?.representedObject = ""
            chosen = popup.lastItem
        }
        for item in models(for: app, options: options, selected: selected, suffix: suffix) {
            guard let ref = item.ref else { continue }
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
