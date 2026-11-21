import Cocoa

/// The route-popup pieces the Models & Power grid and the Sticky Skills cards build identically. Each
/// view keeps its own same-named private method (identifier, target, action and catalog are its own) and
/// forwards here, so there is one implementation of the effort popup, the model-name shortener and the
/// identifier lookup. The provider, model and Local-picker builders are NOT here: they differ in
/// structure between the two views (staff-pick qualifier, no-staff-pick state, tested-bundle lookup).
enum RoutePopupBuilders {
    /// `owner/name` shows as `name`; anything else is returned unchanged.
    static func compactModelName(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last!) : id
    }

    /// First descendant of `root`, depth-first in subview order, whose identifier equals `id`.
    static func descendant(id: String, in root: NSView) -> NSView? {
        func find(_ root: NSView) -> NSView? {
            for child in root.subviews {
                if child.identifier?.rawValue == id { return child }
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(root)
    }

    /// The Effort popup: "Default" plus the catalog-advertised efforts for a Codex model (or low/medium/high),
    /// with a persisted effort the list does not carry appended so an open-string value is never dropped.
    /// Disabled, with a tooltip, on a Local route.
    static func effortPopup(identifier: String, selected: LLMProviderBundle,
                            catalog: ModelCatalog?, x: CGFloat, y: CGFloat, width: CGFloat,
                            target: AnyObject, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25), pullsDown: false)
        var efforts: [String]
        if selected.provider == .codex,
           let advertised = CodexPickerCatalog.efforts(
                for: selected.modelID, catalog: catalog) {
            efforts = [""] + advertised
        } else {
            efforts = ["", "low", "medium", "high"]
        }
        if let effort = selected.effort, !efforts.contains(effort) { efforts.append(effort) }
        for effort in efforts {
            p.addItem(withTitle: effort.isEmpty ? "Default" : CodexPickerCatalog.safeLabel(effort))
            p.lastItem?.representedObject = effort
        }
        let selectedRaw = selected.effort ?? ""
        if let item = p.itemArray.first(where: { ($0.representedObject as? String) == selectedRaw }) {
            p.select(item)
        }
        p.identifier = NSUserInterfaceItemIdentifier(identifier)
        p.target = target
        p.action = action
        p.isEnabled = selected.provider != .local
        p.toolTip = selected.provider == .local ? "Local routes do not use an effort setting." : nil
        return p
    }
}
