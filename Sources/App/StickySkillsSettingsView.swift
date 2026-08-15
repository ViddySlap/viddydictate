import Cocoa

/// The third Settings tab: one card per whole-note Sticky Skill. It deliberately mirrors the compact
/// LLM-ROUTES card grammar (title, route controls, Advanced disclosure) without importing the Hotkeys
/// chord/input/landing composition: a sticky skill always receives the whole note and has no chord half.
final class StickySkillsSettingsView: NSView {
    override var isFlipped: Bool { true }

    var onContentChanged: (() -> Void)?

    private let W: CGFloat
    private let L: CGFloat = 20
    private let skillStore: StickySkillStore
    private let modeStore: CustomModeStore
    private let settingsStore: ModelsPowerSettingsStore
    private let codexCatalogLoader: () -> CodexModelCatalogCache?
    private let localCatalogLoader: () -> [LMStudioModelOption]?

    private var expandedCards = Set<String>()
    private var statusMessage: String?
    private var statusIsError = false
    private var codexCatalogCache: CodexModelCatalogCache?
    private var localCatalog: [LMStudioModelOption]?
    private var localCatalogRefreshInFlight = false
    private var observers: [NSObjectProtocol] = []

    init(
        width: CGFloat,
        skillStore: StickySkillStore = .shared,
        modeStore: CustomModeStore = .shared,
        settingsStore: ModelsPowerSettingsStore = Settings.modelsPower,
        codexCatalogLoader: @escaping () -> CodexModelCatalogCache? = {
            CodexModelCatalogDiskCache.loadLastKnownGood()
        },
        localCatalogLoader: @escaping () -> [LMStudioModelOption]? = {
            ModelResidency.availableModels()
        }
    ) {
        W = width
        self.skillStore = skillStore
        self.modeStore = modeStore
        self.settingsStore = settingsStore
        self.codexCatalogLoader = codexCatalogLoader
        self.localCatalogLoader = localCatalogLoader
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: StickySkillStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: CustomModeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: ModelsPowerSettingsStore.didChange, object: settingsStore, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() { rebuild() }

    /// Match Models & Power: use the last-known-good catalog immediately, then refresh installed Local
    /// choices away from the AppKit thread each time Settings opens.
    func refreshAvailableLocalModels() {
        guard !localCatalogRefreshInFlight else { return }
        localCatalogRefreshInFlight = true
        let loader = localCatalogLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discovered = loader()
            DispatchQueue.main.async {
                guard let self else { return }
                self.localCatalogRefreshInFlight = false
                self.localCatalog = discovered
                self.rebuild()
            }
        }
    }

    // MARK: - Build

    private func rebuild() {
        codexCatalogCache = codexCatalogLoader()
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 16

        addSubview(SettingsSectionKit.label(
            "Sticky Skills", x: L, y: y, width: W - 2 * L,
            size: 19, weight: .semibold, color: .labelColor))
        y += 28
        let intro = SettingsSectionKit.wrapped(
            "Run a repeatable task over a whole sticky note: its title, body, and attachments. Each skill owns a task prompt, model route, and result destination.",
            x: L, y: y, width: W - 2 * L, size: 10.5, color: .tertiaryLabelColor)
        addSubview(intro)
        y += intro.frame.height + 14

        if let statusMessage {
            let status = SettingsSectionKit.wrapped(
                statusMessage, x: L, y: y, width: W - 2 * L,
                size: 10.5, weight: .medium,
                color: statusIsError ? .systemRed : .secondaryLabelColor)
            status.identifier = NSUserInterfaceItemIdentifier("sticky-skill-status")
            addSubview(status)
            y += status.frame.height + 10
        }

        addSubview(SettingsSectionKit.sectionHeader(
            "STICKY SKILLS", x: L, y: y, width: W - 2 * L))
        y += 22
        for skill in skillStore.skills {
            y = addCard(for: skill, at: y)
        }

        let add = NSButton(title: "+ Add new sticky skill", target: self,
                           action: #selector(addSkill))
        add.bezelStyle = .rounded
        add.identifier = NSUserInterfaceItemIdentifier("sticky-skill-add")
        add.frame = NSRect(x: L, y: y, width: 210, height: 30)
        addSubview(add)
        y += 44

        let footer = SettingsSectionKit.wrapped(
            "New note is the default. Append uses the live editor when a note is open, and Copy to clipboard leaves every note unchanged.",
            x: L, y: y, width: W - 2 * L, size: 10.5, color: .tertiaryLabelColor)
        addSubview(footer)
        y += footer.frame.height + 18
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: W, height: y)
        onContentChanged?()
    }

    private func addCard(for skill: StickySkill, at originY: CGFloat) -> CGFloat {
        let expanded = expandedCards.contains(skill.id)
        let height: CGFloat = expanded ? 278 : 170
        let card = SettingsSectionKit.card(
            frame: NSRect(x: L, y: originY, width: W - 2 * L, height: height),
            identifier: "sticky-skill-card|\(skill.id)")
        addSubview(card)
        let innerW = card.bounds.width
        let displayName = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)

        card.addSubview(SettingsSectionKit.label(
            displayName.isEmpty ? "Untitled sticky skill" : displayName,
            x: 14, y: 14, width: innerW - 236,
            size: 13, weight: .semibold, color: .labelColor))
        let advanced = button(
            expanded ? "Hide Advanced" : "Advanced...",
            id: "sticky-skill-advanced|\(skill.id)", action: #selector(toggleAdvanced(_:)),
            x: innerW - 206, y: 8, width: 118)
        card.addSubview(advanced)
        let remove = button(
            "Remove", id: "sticky-skill-remove|\(skill.id)", action: #selector(removeSkill(_:)),
            x: innerW - 82, y: 8, width: 68)
        remove.isEnabled = !skill.isBuiltIn
        remove.toolTip = skill.isBuiltIn
            ? "Note to Handoff is built in and cannot be removed."
            : "Remove this sticky skill and its private prompt/route record."
        card.addSubview(remove)

        let kind = skill.isBuiltIn
            ? "Built in - keeps the existing whole-note action and right-Option+period route."
            : "Whole-note task - no chord, input-mode, or in-place overwrite."
        card.addSubview(SettingsSectionKit.label(
            kind, x: 14, y: 38, width: innerW - 28,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))

        card.addSubview(SettingsSectionKit.label(
            "Name", x: 14, y: 65, width: 36,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))
        let name = NSTextField(string: skill.name)
        name.placeholderString = "sticky skill name"
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.identifier = NSUserInterfaceItemIdentifier("sticky-skill-name|\(skill.id)")
        name.target = self
        name.action = #selector(nameChanged(_:))
        name.frame = NSRect(x: 52, y: 61, width: 230, height: 24)
        card.addSubview(name)

        card.addSubview(SettingsSectionKit.label(
            "Output", x: 294, y: 65, width: 44,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))
        card.addSubview(outputPopup(skill: skill, x: 342, y: 60, width: innerW - 356))

        card.addSubview(SettingsSectionKit.label(
            "Provider", x: 14, y: 99, width: 56,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))
        card.addSubview(providerPopup(skill: skill, x: 74, y: 94, width: 160))
        let selected = settingsStore.selectedBundle(for: skill.routeID)
        let availability = settingsStore.availabilityState(for: selected.provider)
        let availableText = availability.canRun
            ? "Available"
            : (availability.requiresConnection ? "Disconnected - connect on Setup" : "Unavailable")
        card.addSubview(SettingsSectionKit.label(
            availableText, x: 246, y: 99, width: innerW - 260,
            size: 10.5, weight: .regular,
            color: availability.canRun ? .systemGreen : .secondaryLabelColor))

        card.addSubview(SettingsSectionKit.label(
            "Model", x: 14, y: 133, width: 40,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))
        card.addSubview(modelPopup(skill: skill, selected: selected, x: 58, y: 128, width: 300))
        card.addSubview(SettingsSectionKit.label(
            "Effort", x: 370, y: 133, width: 42,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))
        card.addSubview(effortPopup(skill: skill, selected: selected,
                                    x: 416, y: 128, width: innerW - 430))

        if expanded { addAdvanced(to: card, skill: skill, selected: selected, y: 164) }
        return originY + card.frame.height + 12
    }

    private func addAdvanced(to card: NSView, skill: StickySkill,
                             selected: LLMProviderBundle, y: CGFloat) {
        let innerW = card.bounds.width
        let divider = NSBox(frame: NSRect(x: 14, y: y, width: innerW - 28, height: 1))
        divider.boxType = .separator
        card.addSubview(divider)

        let mode = modeStore.mode(id: skill.customModeID)
        let promptState = mode.map {
            $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty" : "Ready"
        } ?? "Missing backing record"
        card.addSubview(SettingsSectionKit.label(
            "Task prompt: \(promptState)", x: 14, y: y + 18, width: innerW - 172,
            size: 10.5, weight: .medium, color: .secondaryLabelColor))
        let edit = button(
            "Edit task prompt", id: "sticky-skill-edit-prompt|\(skill.id)",
            action: #selector(editTaskPrompt(_:)), x: innerW - 142, y: y + 12, width: 128)
        edit.isEnabled = mode != nil
        card.addSubview(edit)

        card.addSubview(SettingsSectionKit.label(
            "Exact ID", x: 14, y: y + 53, width: 54,
            size: 10.5, weight: .regular, color: .secondaryLabelColor))
        let model = NSTextField(string: selected.modelID)
        model.placeholderString = "exact provider model ID"
        model.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        model.identifier = NSUserInterfaceItemIdentifier("sticky-skill-custom-model|\(skill.id)")
        model.frame = NSRect(x: 72, y: y + 48, width: 260, height: 24)
        card.addSubview(model)
        let effort = NSTextField(string: selected.effort ?? "")
        effort.placeholderString = "effort"
        effort.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        effort.identifier = NSUserInterfaceItemIdentifier("sticky-skill-custom-effort|\(skill.id)")
        effort.isEnabled = selected.provider != .local
        effort.frame = NSRect(x: 338, y: y + 48, width: 100, height: 24)
        card.addSubview(effort)
        card.addSubview(button(
            "Save custom", id: "sticky-skill-save-custom|\(skill.id)",
            action: #selector(saveCustomBundle(_:)), x: 448, y: y + 47, width: 118))

        let ceiling = "Request ceiling: Local \(Int(skill.timeout.local))s, cloud \(Int(skill.timeout.cloud))s. Input is always the whole note."
        card.addSubview(SettingsSectionKit.label(
            ceiling, x: 14, y: y + 87, width: innerW - 28,
            size: 10.5, weight: .regular, color: .tertiaryLabelColor))
    }

    // MARK: - Controls

    private func outputPopup(skill: StickySkill, x: CGFloat, y: CGFloat,
                             width: CGFloat) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25),
                                  pullsDown: false)
        for output in StickySkillOutputMode.allCases {
            popup.addItem(withTitle: output.label)
            popup.lastItem?.representedObject = output.rawValue
        }
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == skill.outputMode.rawValue
        }) { popup.select(item) }
        popup.identifier = NSUserInterfaceItemIdentifier("sticky-skill-output|\(skill.id)")
        popup.target = self
        popup.action = #selector(outputChanged(_:))
        return popup
    }

    private func providerPopup(skill: StickySkill, x: CGFloat, y: CGFloat,
                               width: CGFloat) -> NSPopUpButton {
        let selected = settingsStore.selectedBundle(for: skill.routeID)
        let popup = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25),
                                  pullsDown: false)
        for provider in LLMProvider.allCases {
            popup.addItem(withTitle: provider.displayName)
            popup.lastItem?.representedObject = provider.rawValue
        }
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == selected.provider.rawValue
        }) { popup.select(item) }
        popup.identifier = NSUserInterfaceItemIdentifier("sticky-skill-provider|\(skill.id)")
        popup.target = self
        popup.action = #selector(providerChanged(_:))
        return popup
    }

    private func modelPopup(skill: StickySkill, selected: LLMProviderBundle,
                            x: CGFloat, y: CGFloat, width: CGFloat) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25),
                                  pullsDown: false)
        var choices: [(id: String, label: String)] = []
        func append(_ id: String, _ label: String) {
            guard !id.isEmpty, !choices.contains(where: { $0.id == id }) else { return }
            choices.append((id, label))
        }
        if selected.provider == .local {
            for option in LMStudioModelCatalog.pickerOptions(discovered: localCatalog) {
                append(option.modelID, option.label)
            }
        } else if selected.provider == .codex {
            for option in CodexPickerCatalog.visibleOptions(codexCatalogCache?.catalog) {
                append(option.model, option.label)
            }
        }
        if let tested = LLMProviderDefaults.testedBundle(
            for: selected.provider, route: skill.routeID) {
            append(tested.modelID, compactModelName(tested.modelID) + " - Shipped default")
        }
        if selected.provider != .local {
            for option in ModeModelCatalog.options where option.provider == selected.provider {
                append(option.modelID, ModeModelCatalog.displayName(option))
            }
        }
        append(selected.modelID, compactModelName(selected.modelID) + " - Current")
        for choice in choices {
            popup.addItem(withTitle: choice.label)
            popup.lastItem?.representedObject = choice.id
        }
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == selected.modelID
        }) { popup.select(item) }
        popup.identifier = NSUserInterfaceItemIdentifier("sticky-skill-model|\(skill.id)")
        popup.target = self
        popup.action = #selector(modelChanged(_:))
        return popup
    }

    private func effortPopup(skill: StickySkill, selected: LLMProviderBundle,
                             x: CGFloat, y: CGFloat, width: CGFloat) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25),
                                  pullsDown: false)
        var efforts: [String]
        if selected.provider == .codex,
           let advertised = CodexPickerCatalog.efforts(
               for: selected.modelID, catalog: codexCatalogCache?.catalog) {
            efforts = [""] + advertised
        } else {
            efforts = ["", "low", "medium", "high"]
        }
        if let current = selected.effort, !efforts.contains(current) { efforts.append(current) }
        for effort in efforts {
            popup.addItem(withTitle: effort.isEmpty ? "Default" : CodexPickerCatalog.safeLabel(effort))
            popup.lastItem?.representedObject = effort
        }
        let raw = selected.effort ?? ""
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == raw
        }) { popup.select(item) }
        popup.identifier = NSUserInterfaceItemIdentifier("sticky-skill-effort|\(skill.id)")
        popup.target = self
        popup.action = #selector(effortChanged(_:))
        popup.isEnabled = selected.provider != .local
        popup.toolTip = selected.provider == .local ? "Local routes do not use an effort setting." : nil
        return popup
    }

    // MARK: - Actions

    @objc private func addSkill() {
        do {
            let skill = try StickySkillSettingsOperations.add(
                skillStore: skillStore, modeStore: modeStore)
            expandedCards.insert(skill.id)
            status("Added \(skill.name). Edit its name and task prompt below.")
        } catch { status("Could not add sticky skill - \(error.localizedDescription)", error: true) }
    }

    @objc private func removeSkill(_ sender: NSButton) {
        guard let id = suffix(sender, prefix: "sticky-skill-remove|") else { return }
        do {
            try StickySkillSettingsOperations.remove(
                id: id, skillStore: skillStore, modeStore: modeStore)
            expandedCards.remove(id)
            status("Removed sticky skill.")
        } catch { status("Could not remove sticky skill - \(error.localizedDescription)", error: true) }
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        guard let id = suffix(sender, prefix: "sticky-skill-name|") else { return }
        do {
            try StickySkillSettingsOperations.rename(
                id: id, to: sender.stringValue,
                skillStore: skillStore, modeStore: modeStore)
            status("Saved sticky skill name.")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func outputChanged(_ sender: NSPopUpButton) {
        guard let id = suffix(sender, prefix: "sticky-skill-output|"),
              let raw = sender.selectedItem?.representedObject as? String,
              let output = StickySkillOutputMode(rawValue: raw) else { return }
        do {
            try StickySkillSettingsOperations.setOutputMode(
                id: id, outputMode: output, skillStore: skillStore)
            status("Saved output: \(output.label).")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let skill = skill(for: sender, prefix: "sticky-skill-provider|"),
              let raw = sender.selectedItem?.representedObject as? String,
              let provider = LLMProvider(rawValue: raw) else { return }
        do {
            try settingsStore.selectProvider(provider, for: skill.routeID)
            status("\(skill.name) now uses \(provider.displayName).")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let skill = skill(for: sender, prefix: "sticky-skill-model|"),
              let model = sender.selectedItem?.representedObject as? String,
              !model.isEmpty else { return }
        let current = settingsStore.selectedBundle(for: skill.routeID)
        let candidate = CodexPickerCatalog.applyingModelSelection(model, to: current)
        do {
            try settingsStore.setSelectedBundle(candidate, for: skill.routeID)
            status("Saved \(skill.name) model.")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        guard let skill = skill(for: sender, prefix: "sticky-skill-effort|"),
              let effort = sender.selectedItem?.representedObject as? String else { return }
        let current = settingsStore.selectedBundle(for: skill.routeID)
        let candidate = CodexPickerCatalog.applyingEffortSelection(effort, to: current)
        do {
            try settingsStore.setSelectedBundle(candidate, for: skill.routeID)
            status("Saved \(skill.name) effort.")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func saveCustomBundle(_ sender: NSButton) {
        guard let id = suffix(sender, prefix: "sticky-skill-save-custom|"),
              let skill = skillStore.skill(id: id),
              let model = descendant(id: "sticky-skill-custom-model|\(id)") as? NSTextField,
              let effort = descendant(id: "sticky-skill-custom-effort|\(id)") as? NSTextField else { return }
        let modelID = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { status("Model ID cannot be blank.", error: true); return }
        let rawEffort = effort.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = settingsStore.selectedBundle(for: skill.routeID)
        candidate = CodexPickerCatalog.applyingModelSelection(modelID, to: candidate)
        candidate = CodexPickerCatalog.applyingEffortSelection(
            candidate.provider == .local ? "" : rawEffort, to: candidate)
        do {
            try settingsStore.setSelectedBundle(candidate, for: skill.routeID)
            status("Saved custom model and effort for \(skill.name).")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        guard let id = suffix(sender, prefix: "sticky-skill-advanced|") else { return }
        if expandedCards.contains(id) { expandedCards.remove(id) }
        else { expandedCards.insert(id) }
        rebuild()
    }

    @objc private func editTaskPrompt(_ sender: NSButton) {
        guard let id = suffix(sender, prefix: "sticky-skill-edit-prompt|"),
              let skill = skillStore.skill(id: id),
              let mode = modeStore.mode(id: skill.customModeID),
              let window else { return }
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        PromptEditorSheet.presentStickySkillWorkstation(
            on: window,
            title: "\(name.isEmpty ? "Sticky skill" : name) - Task prompt",
            skill: skill,
            mode: mode
        ) { [weak self] prompt in
            guard let self else { return }
            do {
                try StickySkillSettingsOperations.setTaskPrompt(
                    id: id, prompt: prompt,
                    skillStore: self.skillStore, modeStore: self.modeStore)
                self.status("Saved provider-neutral task prompt.")
            } catch { self.status(error.localizedDescription, error: true) }
        }
    }

    // MARK: - Helpers

    private func status(_ message: String, error: Bool = false) {
        statusMessage = message
        statusIsError = error
        rebuild()
    }

    private func button(_ title: String, id: String, action: Selector,
                        x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 10.5)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.frame = NSRect(x: x, y: y, width: width, height: 26)
        return button
    }

    private func suffix(_ control: NSControl, prefix: String) -> String? {
        stripIdentifierPrefix(control.identifier, prefix: prefix)
    }

    private func skill(for control: NSControl, prefix: String) -> StickySkill? {
        guard let id = suffix(control, prefix: prefix) else { return nil }
        return skillStore.skill(id: id)
    }

    private func compactModelName(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last!) : id
    }

    private func descendant(id: String) -> NSView? {
        func find(_ root: NSView) -> NSView? {
            for child in root.subviews {
                if child.identifier?.rawValue == id { return child }
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(self)
    }
}
