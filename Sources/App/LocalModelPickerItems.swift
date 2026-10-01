import Foundation

/// The Local model dropdown's contents, as data (spec D1). The Hotkeys routing grid and the Sticky Skills
/// cards both build their Local picker from this, so the one rule lives in one place and is gated without
/// AppKit (`--local-picker-merge-selftest`).
///
/// The catalog is every running local app's models, each tagged with its app (`LLMProviderDetection`
/// merges them, LM Studio's first). The rule:
///
/// - **One app** in the list: every title is the row's own label, exactly as before a second app existed.
///   An LM-Studio-only Mac sees byte-identical menus.
/// - **Both apps** in the list: grouped by app (LM Studio, then Ollama, each in catalog order), a separator
///   between the groups, and every title prefixed with its app ("Ollama · qwen3-coder:30b"). The prefix is
///   on the item itself, not only on a group header, because a closed popup shows just the selected title,
///   and the same id can sit in both groups. (A disabled header row would also need `autoenablesItems` off
///   and `NSMenuItem.sectionHeader` is macOS 14+, while the app supports 13.)
///
/// Identity is the `(app, id)` pair throughout: duplicates collapse by ref, never by id, and the selected
/// item is the pinned ref, so a pin to Ollama's copy of an id LM Studio also has selects Ollama's.
enum LocalModelPickerItems {
    /// One row of the menu. `ref == nil` is the separator between the two apps' groups.
    struct Item: Equatable {
        let ref: LocalModelRef?
        let title: String
        let isSelected: Bool

        var isSeparator: Bool { ref == nil }
    }

    /// The joiner between an app's name and a model label. The same middle dot the routing grid already uses
    /// for its own qualifiers ("  ·  Custom"), without the wide spacing, so it reads as part of the name.
    static let appPrefixSeparator = " · "

    /// The menu for `options` with `selected` chosen. `options` may carry extra rows a view appends (the pin
    /// when the catalog lacks it, a shipped default); the first row for a ref wins, as the first row for an id
    /// did before. `suffix` is the view's own per-row qualifier, appended after the label unchanged.
    static func build(options: [LMStudioModelOption], selected: LocalModelRef?,
                      suffix: (LocalModelRef) -> String = { _ in "" }) -> [Item] {
        var seen = Set<LocalModelRef>()
        let unique = options.filter { seen.insert($0.ref).inserted }
        guard labelsApps(unique) else {
            return unique.map { option in
                Item(ref: option.ref, title: option.label + suffix(option.ref),
                     isSelected: option.ref == selected)
            }
        }

        var items: [Item] = []
        for backend in LocalBackendID.allCases {
            let group = unique.filter { $0.backend == backend }
            guard !group.isEmpty else { continue }
            if !items.isEmpty { items.append(Item(ref: nil, title: "", isSelected: false)) }
            for option in group {
                items.append(Item(
                    ref: option.ref,
                    title: backend.displayName + appPrefixSeparator + option.label + suffix(option.ref),
                    isSelected: option.ref == selected))
            }
        }
        return items
    }

    /// The routing grid's Local picker (Hotkeys tab, `ModelsPowerSettingsView`): the catalog (or the shipped
    /// fallback list when discovery has not answered), then the pin when the catalog lacks it. The pin's row
    /// reads "  ·  Custom" and each app's copy of the route's default "  ·  Staff pick" (D11), both matched by
    /// (app, id): Ollama's staff pick is its own tag for the same family (`StaffPicks.localRefs`), so Ollama's
    /// copy of LM Studio's default id is not called a staff pick.
    static func routingGrid(catalog: [LMStudioModelOption]?, pinned: LLMProviderBundle,
                            tested: LLMProviderBundle?) -> [Item] {
        let pin = pinned.localRef
        let options = routingGridOptions(catalog: catalog, pinned: pinned)
        let staffPicks = StaffPicks.localRefs(tested: tested)
        return build(options: options, selected: pin) { ref in
            if staffPicks.contains(ref) { return StaffPicks.gridQualifier }
            return ref == pin ? StaffPicks.gridCustomQualifier : ""
        }
    }

    /// The rows the routing grid's Local picker is built from: the catalog (or the shipped fallback list), then
    /// the pin when it has an id.
    static func routingGridOptions(catalog: [LMStudioModelOption]?,
                                   pinned: LLMProviderBundle) -> [LMStudioModelOption] {
        var options = LMStudioModelCatalog.pickerOptions(discovered: catalog)
        if !pinned.modelID.isEmpty {
            options.append(LMStudioModelOption(
                modelID: pinned.modelID, label: shortName(pinned.modelID), backend: pinned.resolvedLocalBackend))
        }
        return options
    }

    /// The routing grid's "Local preset:" badge, naming the app by the picker's own rule: only when the
    /// route's Local picker names apps (`labelsApps` over the same rows), "STAFF PICK <id>" reads
    /// "STAFF PICK · Ollama · <id>" (and "CUSTOM <id>" likewise). The badge word is everything before the
    /// bundle's id, so a two-word badge keeps both words. With one app, or for any bundle that is not Local or a
    /// badge whose leading upper-case word is not followed by the bundle's id, it is returned unchanged, so an
    /// LM-Studio-only Mac's line names no app.
    static func presetBadge(_ badge: String, bundle: LLMProviderBundle,
                            catalog: [LMStudioModelOption]?) -> String {
        guard bundle.provider == .local, !bundle.modelID.isEmpty,
              labelsApps(routingGridOptions(catalog: catalog, pinned: bundle)),
              let idStart = badge.range(of: " " + bundle.modelID) else { return badge }
        let word = String(badge[..<idStart.lowerBound])
        guard !word.isEmpty, word == word.uppercased(),
              word.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }) else { return badge }
        let rest = String(badge[badge.index(after: idStart.lowerBound)...])
        return word + appPrefixSeparator + bundle.resolvedLocalBackend.displayName + appPrefixSeparator + rest
    }

    /// A Sticky Skill card's Local picker (`StickySkillsSettingsView`): the catalog (or the fallback list),
    /// then the shipped default and the pin when the catalog lacks them, each with its own qualifier. A tested
    /// Local bundle carries no app, which means LM Studio.
    static func stickySkill(catalog: [LMStudioModelOption]?, pinned: LLMProviderBundle,
                            tested: LLMProviderBundle?) -> [Item] {
        var options = LMStudioModelCatalog.pickerOptions(discovered: catalog)
        if let tested {
            options.append(LMStudioModelOption(
                modelID: tested.modelID, label: shortName(tested.modelID) + StaffPicks.stickyQualifier,
                backend: tested.resolvedLocalBackend))
        }
        options.append(LMStudioModelOption(
            modelID: pinned.modelID, label: shortName(pinned.modelID) + " - Current",
            backend: pinned.resolvedLocalBackend))
        return build(options: options.filter { !$0.modelID.isEmpty }, selected: pinned.localRef)
    }

    /// The short label both views give a Local id the catalog does not describe: the id without its org
    /// prefix, the catalog's own rule for a Local model.
    private static func shortName(_ modelID: String) -> String {
        ModeModelCatalog.displayName(.local(modelID))
    }

    /// App names appear only when the list holds models from more than one app.
    static func labelsApps(_ options: [LMStudioModelOption]) -> Bool {
        Set(options.map(\.backend)).count > 1
    }

    /// The route's bundle after the user picks `ref`: the model id through the shared model-selection rule
    /// (a different model drops the ratification and auto-update provenance), and the app written the way
    /// `LLMProviderBundle.local(ref:)` spells it. LM Studio is nil, the spelling every 1.1.0 bundle uses, so
    /// picking an LM Studio model on a one-app Mac writes no `localBackend` key at all. The same id in the
    /// OTHER app is a different model, so switching apps also drops the provenance.
    static func applying(_ ref: LocalModelRef, to bundle: LLMProviderBundle) -> LLMProviderBundle {
        var out = CodexPickerCatalog.applyingModelSelection(ref.modelID, to: bundle)
        if bundle.resolvedLocalBackend != ref.backend {
            out.ratified = nil
            out.autoUpdated = nil
        }
        out.localBackend = LLMProviderBundle.local(ref: ref).localBackend
        return out
    }

    /// The stable identifier of a Local model menu item, `local-model|<app>|<id>`. The item's
    /// `representedObject` stays the bare model id (what every other picker row carries), and the app rides
    /// here, so the action can recover the full ref without a side table.
    static let itemIdentifierPrefix = "local-model|"

    static func itemIdentifier(for ref: LocalModelRef) -> String {
        itemIdentifierPrefix + ref.backend.rawValue + "|" + ref.modelID
    }

    /// The ref an item identifier names, or nil for anything else (a cloud row, a separator, a malformed id).
    /// The model id is everything after the app, so an id that itself contains `|` survives.
    static func ref(fromItemIdentifier raw: String?) -> LocalModelRef? {
        guard let raw, raw.hasPrefix(itemIdentifierPrefix) else { return nil }
        let rest = raw.dropFirst(itemIdentifierPrefix.count)
        guard let bar = rest.firstIndex(of: "|"),
              let backend = LocalBackendID(rawValue: String(rest[..<bar])) else { return nil }
        let modelID = String(rest[rest.index(after: bar)...])
        return modelID.isEmpty ? nil : LocalModelRef(backend: backend, modelID: modelID)
    }
}
