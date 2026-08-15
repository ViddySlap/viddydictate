import Cocoa

/// Identifier parsers treat a missing identifier, a prefix mismatch, and an empty suffix uniformly as nil.
func stripIdentifierPrefix(_ id: NSUserInterfaceItemIdentifier?, prefix: String) -> String? {
    guard let raw = id?.rawValue, raw.hasPrefix(prefix) else { return nil }
    let suffix = String(raw.dropFirst(prefix.count))
    return suffix.isEmpty ? nil : suffix
}

private final class ModelsPowerCardView: NSView {
    override var isFlipped: Bool { true }
}

/// The routing half of the consolidated Hotkeys tab (L9), and the single Settings surface for every
/// synthesis route: the global provider/bulk-routing section, then one card per route carrying that
/// route's provider, model, effort and prompts behind an Advanced disclosure — plus, when a
/// `bindingRowSource` is attached, the chord and traits of the hotkey that fires it. It is a thin AppKit layer over
/// `ModelsPowerSettingsStore`: provider/model/prompt mutations stay
/// transactional in A4's authority, while this view owns presentation, validation, and explicit user
/// gestures only. Search retrieval never appears as an editable control; the L/G cards expose synthesis.
final class ModelsPowerSettingsView: NSView {
    override var isFlipped: Bool { true }

    struct ProvenancePresentation: Equatable {
        let bundle: LLMProviderBundle
        let badge: String
    }

    /// The inline rescue's way out (D6). Picking a disconnected provider for a route does not change the
    /// route; it hands that provider to the host's ONE connect flow - `ProviderSignInPresenter`, the same
    /// object the Setup tab and the first-run window drive. This tab owns no connect implementation of its
    /// own, and since L4 it owns no connect BUTTON either: those live on the Setup tab.
    var onConnectProvider: ((LLMProvider) -> Void)?
    /// The runtime retry center enables one failed route at a time; clicking never selects a fallback or
    /// runs work inside this view. The window owner presents named provider confirmation buttons.
    var onRetry: ((LLMRouteID, LLMProvider) -> Void)?
    /// L9: the Hotkeys half of the merged tab, which supplies each route card with the binding controls
    /// for the hotkey that fires it. Nil when this surface is rendered on its own (probes, renders), in
    /// which case the cards simply carry no binding row.
    weak var bindingRowSource: HotkeyBindingRowSource?
    /// Fired after every rebuild, once this view has resized itself to its content. The merged tab
    /// re-stacks on it; a standalone host can ignore it.
    var onContentChanged: (() -> Void)?

    private struct RouteCard {
        let key: String
        let title: String
        let subtitle: String
        let routes: [LLMRouteID]
        let customID: String?

        var isCleanup: Bool { key == "cleanup" }
        var primaryRoute: LLMRouteID { routes[0] }
    }

    private let W: CGFloat
    private let L: CGFloat = 20
    private let settingsStore: ModelsPowerSettingsStore
    private let customStore: CustomModeStore
    private let stickySkillStore: StickySkillStore
    private let codexOutcomeStore: CodexUpdateOutcomeStore
    private let codexCatalogLoader: () -> CodexModelCatalogCache?
    private let localCatalogLoader: () -> [LMStudioModelOption]?
    private var expandedCards = Set<String>()
    private var statusMessage: String?
    private var statusIsError = false
    private var freshnessCache: ModelFreshnessCache?
    private var codexCatalogCache: CodexModelCatalogCache?
    private var localCatalog: [LMStudioModelOption]?
    private var localCatalogRefreshInFlight = false
    private var retryProviders: [LLMRouteID: LLMProvider] = [:]
    private var observers: [NSObjectProtocol] = []

    init(
        width: CGFloat,
        settingsStore: ModelsPowerSettingsStore = Settings.modelsPower,
        customStore: CustomModeStore = .shared,
        stickySkillStore: StickySkillStore = .shared,
        codexOutcomeStore: CodexUpdateOutcomeStore = .shared,
        codexCatalogLoader: @escaping () -> CodexModelCatalogCache? = {
            CodexModelCatalogDiskCache.loadLastKnownGood()
        },
        localCatalogLoader: @escaping () -> [LMStudioModelOption]? = {
            ModelResidency.availableModels()
        }
    ) {
        self.W = width
        self.settingsStore = settingsStore
        self.customStore = customStore
        self.stickySkillStore = stickySkillStore
        self.codexOutcomeStore = codexOutcomeStore
        self.codexCatalogLoader = codexCatalogLoader
        self.localCatalogLoader = localCatalogLoader
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: ModelsPowerSettingsStore.didChange, object: settingsStore, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: CustomModeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: StickySkillStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: CloudUpdateRuntimeState.didChange,
            object: CloudUpdateRuntimeState.shared, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(nc.addObserver(
            forName: CodexUpdateOutcomeStore.didChange,
            object: codexOutcomeStore, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() { rebuild() }

    /// Refreshes installed Local models each time Settings opens. The CLI work is never performed on
    /// the AppKit thread; the existing fallback remains visible until discovery completes. No result
    /// is persisted, so a shared LM Studio install changing underneath the app is re-measured rather
    /// than served from a stale cache.
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

    /// Retry state is runtime-only and carries no dictated/selected text. The exact failed request stays
    /// with the provider integration; this view retains only route + provider presentation state.
    func setRetryAvailable(_ available: Bool, for route: LLMRouteID, provider: LLMProvider) {
        if available { retryProviders[route] = provider }
        else { retryProviders.removeValue(forKey: route) }
        rebuild()
    }

    func clearRetryAvailability() {
        guard !retryProviders.isEmpty else { return }
        retryProviders.removeAll()
        rebuild()
    }

    static func displayName(for provider: LLMProvider) -> String {
        provider.displayName
    }

    /// The provenance row describes the provider that will actually run this route. Remembered bundles for
    /// other providers remain available for switching, but they are not evidence about the selected model.
    static func provenancePresentation(
        for route: LLMRouteID,
        store: ModelsPowerSettingsStore,
        ratification: (LLMProvider) -> LLMRatificationState
    ) -> ProvenancePresentation {
        let bundle = store.selectedBundle(for: route)
        return ProvenancePresentation(
            bundle: bundle,
            badge: CloudUpdateSurface.provenanceRow(
                bundle: bundle, ratification: ratification(bundle.provider)))
    }

    /// What the inline rescue says (D6). Pure, so the deterministic rail covers the wording rather than only
    /// a GUI probe, and one string for both providers so neither can quietly become the special case again.
    ///
    /// It names the button the user is about to see rather than paraphrasing it, and it says outright that
    /// nothing was routed anywhere - the whole point of the rescue is that the pick did NOT take effect.
    static func inlineRescueStatus(for provider: LLMProvider) -> String {
        let name = displayName(for: provider)
        guard ProviderOnboarding.canDriveSignIn(provider) else {
            // Nothing to open: ViddyDictate does not sign anyone in to a local server.
            return "\(name) is disconnected. ViddyDictate cannot sign in to it, and no route changed."
        }
        return "\(name) is disconnected. Opened "
            + "\(ProviderOnboarding.actionTitle(provider, .signedOut)) without changing any route."
    }

    static func displayName(for route: LLMRouteID) -> String {
        switch route {
        case .cleanupL1: return "Cleanup"
        case .cleanupL2: return "Tighten"
        case .cleanupL3: return "Summarize"
        case .promptPrep: return "Prompt prep (Option+P)"
        case .email: return "Email (Option+M)"
        case .searchLocalSynth: return "Local search synthesis (Option+L)"
        case .searchGeminiSynth: return "Gemini search synthesis (Option+G)"
        case .custom: return "Custom hotkey"
        }
    }

    // MARK: build

    private func rebuild() {
        freshnessCache = ModelFreshnessProbe.loadCache()
        codexCatalogCache = codexCatalogLoader()
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 16

        addSubview(text("Models", x: L, y: y, width: W - 2 * L,
                        size: 19, weight: .semibold, color: .labelColor))
        y += 28
        let intro = wrap(PowerSettingsCopy.modelsIntro,
                         x: L, y: y, width: W - 2 * L, height: 42)
        addSubview(intro)
        y += 50

        y = addProviderAndBulkCard(at: y)

        if let statusMessage = statusMessage {
            let status = wrap(statusMessage, x: L, y: y, width: W - 2 * L, height: 34)
            status.identifier = NSUserInterfaceItemIdentifier("models-power-status")
            status.textColor = statusIsError ? .systemRed : .secondaryLabelColor
            addSubview(status)
            y += 42
        }

        addSubview(sectionHeader("LLM ROUTES", y: y))
        y += 22
        for card in routeCards() {
            y = addRouteCard(card, at: y)
        }

        // L9: adding a hotkey and dialling it in happen in the same place. The button sits where the new
        // card will appear, so there is no second surface to switch to after creating one.
        if let add = bindingRowSource?.hotkeyAddControl() {
            add.frame.origin = NSPoint(x: L, y: y)
            addSubview(add)
            y += add.frame.height + 12
        }

        let footer = wrap("Provider choice is strict: unavailable, timeout, and bad-output failures keep the original text and never hop providers automatically. Retry is enabled only for the route that failed and still requires an explicit provider confirmation.",
                          x: L, y: y + 2, width: W - 2 * L, height: 46)
        addSubview(footer)
        y += 58
        frame = NSRect(x: 0, y: 0, width: W, height: y)
        onContentChanged?()
    }

    private func routeCards() -> [RouteCard] {
        var cards: [RouteCard] = [
            RouteCard(key: "cleanup", title: "Dictation cleanup",
                      subtitle: "One provider for Cleanup, Tighten, and Summarize. Per-strength models live under Advanced.",
                      routes: LLMRouteID.cleanupRoutes, customID: nil),
            RouteCard(key: LLMRouteID.promptPrep.rawValue, title: "Prompt prep  ·  Option+P",
                      subtitle: "Transforms the selection with the chosen Cleanup / Tighten / Summarize prompt.",
                      routes: [.promptPrep], customID: nil),
            RouteCard(key: LLMRouteID.email.rawValue, title: "Email  ·  Option+M",
                      subtitle: "Writes an email from dictation or selection and replaces in place.",
                      routes: [.email], customID: nil),
            RouteCard(key: LLMRouteID.searchLocalSynth.rawValue, title: "Web answer  ·  Option+L",
                      subtitle: "Retrieval: local web-search pipeline (fixed). Only answer synthesis is routed here.",
                      routes: [.searchLocalSynth], customID: nil),
            RouteCard(key: LLMRouteID.searchGeminiSynth.rawValue, title: "Grounded answer  ·  Option+G",
                      subtitle: "Retrieval: Gemini grounding (fixed). Only answer synthesis is routed here.",
                      routes: [.searchGeminiSynth], customID: nil),
        ]
        for mode in StickySkillRegistry.hotkeyVisibleModes(
            customStore.modes, skills: stickySkillStore.skills
        ) {
            let name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
            cards.append(RouteCard(
                key: mode.routeID.rawValue,
                title: name.isEmpty ? "Custom hotkey" : name,
                subtitle: "Custom route · \(mode.hasChord ? mode.chord.label : "unbound") · one provider-neutral task prompt",
                routes: [mode.routeID], customID: mode.id))
        }
        return cards
    }

    private func addProviderAndBulkCard(at originY: CGFloat) -> CGFloat {
        addSubview(sectionHeader("PROVIDERS & GLOBAL ROUTING", y: originY))
        let cardY = originY + 22
        let card = cardView(y: cardY, height: 274, id: "card.providers")
        let colW = (card.bounds.width - 28) / 3
        let latest = CloudUpdateRuntimeState.shared.latest
        for (index, provider) in LLMProvider.allCases.enumerated() {
            let x = 14 + CGFloat(index) * colW
            card.addSubview(text(Self.displayName(for: provider), x: x, y: 12, width: colW - 8,
                                 size: 12.5, weight: .semibold, color: .labelColor))
            let state = settingsStore.availabilityState(for: provider)
            let stateText = availabilityText(state)
            let status = text(stateText, x: x, y: 33, width: colW - 8,
                              size: 10.5, weight: .regular,
                              color: state.canRun ? .systemGreen : .secondaryLabelColor)
            status.identifier = NSUserInterfaceItemIdentifier("availability|\(provider.rawValue)")
            card.addSubview(status)
            if let liveText = CloudUpdateSurface.providerLiveStatus(
                provider,
                latest: latest,
                cache: freshnessCache,
                codexOutcome: codexOutcomeStore.latest,
                codexAvailability: state) {
                let live = wrap(liveText, x: x, y: 51, width: colW - 8, height: 30)
                live.identifier = NSUserInterfaceItemIdentifier("live-availability|\(provider.rawValue)")
                live.toolTip = liveText
                card.addSubview(live)
            }
        }

        // L4: the Codex Connect/Reconnect button MOVED to the Setup tab, where it sits beside Claude's.
        // It is not duplicated here - a second copy is how two buttons for one outcome start behaving
        // differently - so this column block ends with a pointer instead of a control.
        let signInPointer = text(
            "Signing in lives on the Setup tab: it connects Claude Code or Codex.",
            x: 14, y: 84, width: card.bounds.width - 28,
            size: 10.5, weight: .regular, color: .secondaryLabelColor)
        signInPointer.identifier = NSUserInterfaceItemIdentifier("provider-signin-pointer")
        signInPointer.toolTip = signInPointer.stringValue
        card.addSubview(signInPointer)

        let divider = NSBox(frame: NSRect(x: 14, y: 110, width: card.bounds.width - 28, height: 1))
        divider.boxType = .separator
        card.addSubview(divider)

        let bulk = settingsStore.bulkProviderState()
        let bulkLabel: String
        switch bulk {
        case .mixed: bulkLabel = "All routes: Mixed"
        case .provider(let provider): bulkLabel = "All routes: \(Self.displayName(for: provider))"
        }
        let derived = text(bulkLabel, x: 14, y: 124, width: 160,
                           size: 12, weight: .semibold, color: .labelColor)
        derived.identifier = NSUserInterfaceItemIdentifier("bulk-derived-state")
        card.addSubview(derived)
        card.addSubview(text("Set every provider-capable route to its tested default:", x: 174, y: 125,
                             width: 260, size: 10.5, weight: .regular, color: .secondaryLabelColor))

        var bx = card.bounds.width - 300
        for provider in LLMProvider.allCases {
            var title = Self.displayName(for: provider)
            if case .provider(let selected) = bulk, selected == provider { title = "✓ \(title)" }
            let b = button(title, id: "bulk|\(provider.rawValue)", action: #selector(bulkProviderClicked(_:)),
                           x: bx, y: 144, width: 92)
            if provider == .codex {
                b.toolTip = "Uses the eight shipped Codex defaults; Cleanup is auto-updated and unratified."
            }
            card.addSubview(b)
            bx += 98
        }

        let cloudDivider = NSBox(frame: NSRect(
            x: 14, y: 178, width: card.bounds.width - 28, height: 1))
        cloudDivider.boxType = .separator
        card.addSubview(cloudDivider)
        let lastChecked = latest?.checkedAt ?? freshnessCache?.checkedAt
        let lastCheckedLabel = text(
            "Cloud presets: last checked \(lastChecked ?? "never")",
            x: 14, y: 193, width: card.bounds.width - 140,
            size: 10.5, weight: .medium, color: .secondaryLabelColor)
        lastCheckedLabel.identifier = NSUserInterfaceItemIdentifier("cloud-presets-last-checked")
        card.addSubview(lastCheckedLabel)
        card.addSubview(button(
            "Check now", id: "cloud-update-check", action: #selector(checkCloudUpdatesNow),
            x: card.bounds.width - 114, y: 188, width: 100))
        let codexStatus = text(
            CodexUpdateSurface.statusText(codexOutcomeStore.latest),
            x: 14, y: 213, width: card.bounds.width - 28,
            size: 10.5, weight: .medium, color: .secondaryLabelColor)
        codexStatus.identifier = NSUserInterfaceItemIdentifier("codex-update-status")
        codexStatus.toolTip = codexStatus.stringValue
        card.addSubview(codexStatus)
        let autoCheck = NSButton(
            checkboxWithTitle: "Check cloud presets automatically after restart",
            target: self, action: #selector(cloudUpdateAutoCheckChanged(_:)))
        autoCheck.identifier = NSUserInterfaceItemIdentifier("cloud-update-auto-check")
        autoCheck.state = Settings.cloudUpdateAutoCheck ? .on : .off
        autoCheck.font = .systemFont(ofSize: 10.5)
        autoCheck.frame = NSRect(x: 14, y: 240, width: 340, height: 22)
        card.addSubview(autoCheck)
        return cardY + card.frame.height + 14
    }

    private func addRouteCard(_ spec: RouteCard, at originY: CGFloat) -> CGFloat {
        let card = cardView(y: originY, height: 0, id: "card.\(spec.key)")
        let innerW = card.bounds.width
        var y: CGFloat = 12

        y = addRouteHeaderRow(spec: spec, card: card, y: y)
        y = addHotkeyBindingRow(spec: spec, card: card, y: y)
        y = addRouteProviderRow(spec: spec, card: card, y: y)
        y = addRouteProvenanceRows(spec: spec, card: card, y: y)

        if spec.isCleanup {
            let providerSummary = cleanupBundleSummary(spec)
            card.addSubview(text(providerSummary, x: 14, y: y + 3, width: innerW - 28,
                                 size: 11, weight: .regular, color: .secondaryLabelColor))
            y += 28
        } else {
            addModelEffortControls(to: card, route: spec.primaryRoute, y: y)
            y += 34
        }

        y = addRoutePromptSummaryRow(spec: spec, card: card, y: y)

        if expandedCards.contains(spec.key) {
            y = addRouteExpandedSection(spec: spec, card: card, y: y)
        }

        card.frame.size.height = y + 12
        return originY + card.frame.height + 12
    }

    private func addRouteHeaderRow(spec: RouteCard, card: NSView, y: CGFloat) -> CGFloat {
        let innerW = card.bounds.width
        card.addSubview(text(spec.title, x: 14, y: y, width: innerW - 160,
                             size: 13, weight: .semibold, color: .labelColor))
        let expanded = expandedCards.contains(spec.key)
        let disclosure = button(expanded ? "Hide Advanced" : "Advanced…",
                                id: "advanced|\(spec.key)", action: #selector(toggleAdvanced(_:)),
                                x: innerW - 132, y: y - 4, width: 118)
        card.addSubview(disclosure)
        let subtitleY = y + 24
        card.addSubview(wrap(spec.subtitle, x: 14, y: subtitleY, width: innerW - 28, height: 34))
        return subtitleY + 40
    }

    /// The hotkey that fires this route, hosted inside its own routing card (L9's merge). The controls
    /// are built and owned by the Hotkeys page, so rebinding still has exactly one implementation; this
    /// view only gives them a home beside the provider, model, effort and prompt controls for the same
    /// hotkey. A route with no chord of its own (dictation cleanup) simply gets no row.
    private func addHotkeyBindingRow(spec: RouteCard, card: NSView, y: CGFloat) -> CGFloat {
        guard let row = bindingRowSource?.hotkeyBindingRow(
            routeKey: spec.key, customID: spec.customID, width: card.bounds.width - 28) else { return y }
        row.frame.origin = NSPoint(x: 14, y: y)
        row.identifier = NSUserInterfaceItemIdentifier("hotkey-binding|\(spec.key)")
        card.addSubview(row)
        return y + row.frame.height + 10
    }

    private func addRouteProviderRow(spec: RouteCard, card: NSView, y: CGFloat) -> CGFloat {
        let innerW = card.bounds.width
        card.addSubview(text("Provider", x: 14, y: y + 4, width: 62,
                             size: 10.5, weight: .regular, color: .secondaryLabelColor))
        let provider = providerPopup(for: spec, x: 78, y: y, width: 160)
        card.addSubview(provider)
        let availability = selectedAvailability(for: spec)
        let availabilityLabel = text(routeAvailabilityText(for: spec), x: 250, y: y + 4,
                                     width: innerW - 264, size: 10.5, weight: .regular,
                                     color: availability.canRun ? .systemGreen : .secondaryLabelColor)
        availabilityLabel.identifier = NSUserInterfaceItemIdentifier("route-availability|\(spec.key)")
        card.addSubview(availabilityLabel)
        return y + 34
    }

    private func addRouteProvenanceRows(spec: RouteCard, card: NSView, y: CGFloat) -> CGFloat {
        var nextY = y
        for route in spec.routes {
            let provenance = Self.provenancePresentation(for: route, store: settingsStore) {
                routeRatification(route: route, provider: $0)
            }
            let bundle = provenance.bundle
            let badge = provenance.badge
            let routePrefix = spec.routes.count > 1 ? "\(Self.displayName(for: route)): " : ""
            let prefix = "\(routePrefix)\(Self.displayName(for: bundle.provider)) preset: "
            let color: NSColor
            if badge.hasPrefix("RATIFIED") { color = .systemGreen }
            else if badge.hasPrefix("AUTO-UPDATED") || badge.hasPrefix("UNRATIFIED") {
                color = .systemOrange
            } else {
                color = .secondaryLabelColor
            }
            let label = text(prefix + badge, x: 14, y: nextY + 2,
                             width: card.bounds.width - 28, size: 10.5,
                             weight: .semibold, color: color)
            label.identifier = NSUserInterfaceItemIdentifier("provenance|\(route.rawValue)")
            label.toolTip = prefix + badge
            card.addSubview(label)
            nextY += 20
        }
        return nextY + 2
    }

    private func addRoutePromptSummaryRow(spec: RouteCard, card: NSView, y: CGFloat) -> CGFloat {
        let innerW = card.bounds.width
        let promptSummary = promptSummary(for: spec)
        let prompt = text(promptSummary, x: 14, y: y + 4, width: innerW - 150,
                          size: 10.5, weight: .medium, color: .secondaryLabelColor)
        prompt.identifier = NSUserInterfaceItemIdentifier("prompt-summary|\(spec.key)")
        card.addSubview(prompt)
        let retry = button("Retry…", id: "retry|\(spec.key)", action: #selector(retryClicked(_:)),
                           x: innerW - 104, y: y, width: 90)
        retry.isEnabled = retryRoute(in: spec) != nil
        retry.toolTip = retry.isEnabled
            ? "Explicitly retry this failed route; no provider is selected automatically."
            : "Available only after this exact route reports a failure."
        card.addSubview(retry)
        return y + 36
    }

    private func addRouteExpandedSection(spec: RouteCard, card: NSView, y: CGFloat) -> CGFloat {
        let innerW = card.bounds.width
        let divider = NSBox(frame: NSRect(x: 14, y: y, width: innerW - 28, height: 1))
        divider.boxType = .separator
        card.addSubview(divider)
        var nextY = y + 12
        if spec.isCleanup {
            for route in spec.routes {
                card.addSubview(text(Self.displayName(for: route), x: 14, y: nextY + 4, width: 82,
                                     size: 11, weight: .semibold, color: .labelColor))
                addModelEffortControls(to: card, route: route, y: nextY, xOffset: 92)
                nextY += 34
                nextY = addAdvancedBundleEditor(to: card, route: route, y: nextY)
                nextY = addPromptRows(to: card, route: route, y: nextY, xOffset: 92)
                nextY += 8
            }
        } else {
            nextY = addAdvancedBundleEditor(to: card, route: spec.primaryRoute, y: nextY)
            nextY = addPromptRows(to: card, route: spec.primaryRoute, customID: spec.customID, y: nextY)
        }
        return addRestoreButtons(to: card, spec: spec, y: nextY)
    }

    // MARK: route controls

    private func providerPopup(for spec: RouteCard, x: CGFloat, y: CGFloat, width: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25), pullsDown: false)
        let bulk = settingsStore.bulkProviderState(routes: spec.routes)
        if case .mixed = bulk {
            p.addItem(withTitle: "Mixed")
            p.lastItem?.representedObject = "mixed"
            p.lastItem?.isEnabled = false
        }
        for provider in LLMProvider.allCases {
            let defaultCount = spec.routes.filter {
                LLMProviderDefaults.testedBundle(for: provider, route: $0) != nil
            }.count
            var title = Self.displayName(for: provider)
            if defaultCount == 0 {
                title += " · No tested default"
            } else if defaultCount < spec.routes.count {
                title += " · \(defaultCount)/\(spec.routes.count) defaults"
            }
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = provider.rawValue
        }
        switch bulk {
        case .mixed: p.selectItem(at: 0)
        case .provider(let selected):
            if let item = p.itemArray.first(where: { ($0.representedObject as? String) == selected.rawValue }) {
                p.select(item)
            }
        }
        p.identifier = NSUserInterfaceItemIdentifier("provider|\(spec.key)")
        p.target = self
        p.action = #selector(providerChanged(_:))
        return p
    }

    private func addModelEffortControls(to card: NSView, route: LLMRouteID, y: CGFloat,
                                        xOffset: CGFloat = 14) {
        let selected = settingsStore.selectedBundle(for: route)
        card.addSubview(text("Model", x: xOffset, y: y + 4, width: 44,
                             size: 10.5, weight: .regular, color: .secondaryLabelColor))
        card.addSubview(modelPopup(route: route, selected: selected,
                                   x: xOffset + 48, y: y, width: 250))
        card.addSubview(text("Effort", x: xOffset + 310, y: y + 4, width: 42,
                             size: 10.5, weight: .regular, color: .secondaryLabelColor))
        card.addSubview(effortPopup(route: route, selected: selected,
                                    x: xOffset + 354, y: y, width: 112))
    }

    private func modelPopup(route: LLMRouteID, selected: LLMProviderBundle,
                            x: CGFloat, y: CGFloat, width: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25), pullsDown: false)
        var choices: [(model: String, label: String)] = []
        if selected.provider == .local {
            for option in LMStudioModelCatalog.pickerOptions(discovered: localCatalog) {
                if !choices.contains(where: { $0.model == option.modelID }) {
                    choices.append((option.modelID, option.label))
                }
            }
        } else if selected.provider == .codex {
            for option in CodexPickerCatalog.visibleOptions(codexCatalogCache?.catalog) {
                if !choices.contains(where: { $0.model == option.model }) {
                    choices.append((option.model, option.label))
                }
            }
        }
        if selected.provider != .local,
           let tested = LLMProviderDefaults.testedBundle(for: selected.provider, route: route) {
            if !choices.contains(where: { $0.model == tested.modelID }) {
                choices.append((tested.modelID, compactModelName(tested.modelID)))
            }
        }
        if selected.provider != .local {
            for candidate in ModeModelCatalog.options where candidate.provider == selected.provider {
                if !choices.contains(where: { $0.model == candidate.modelID }) {
                    choices.append((candidate.modelID, compactModelName(candidate.modelID)))
                }
            }
        }
        if !selected.modelID.isEmpty,
           !choices.contains(where: { $0.model == selected.modelID }) {
            choices.append((selected.modelID, compactModelName(selected.modelID)))
        }
        if choices.isEmpty {
            p.addItem(withTitle: "No tested model yet")
            p.lastItem?.representedObject = ""
            p.lastItem?.isEnabled = false
            p.isEnabled = false
        } else {
            let testedID = LLMProviderDefaults.testedBundle(for: selected.provider, route: route)?.modelID
            for choice in choices {
                var title = choice.label
                if choice.model == testedID { title += "  ·  Shipped default" }
                else if choice.model == selected.modelID && choice.model != testedID {
                    title += "  ·  Custom"
                }
                p.addItem(withTitle: title)
                p.lastItem?.representedObject = choice.model
            }
            if let item = p.itemArray.first(where: { ($0.representedObject as? String) == selected.modelID }) {
                p.select(item)
            }
        }
        p.identifier = NSUserInterfaceItemIdentifier("model|\(route.rawValue)")
        p.target = self
        p.action = #selector(modelChanged(_:))
        return p
    }

    private func effortPopup(route: LLMRouteID, selected: LLMProviderBundle,
                             x: CGFloat, y: CGFloat, width: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 25), pullsDown: false)
        var efforts: [String]
        if selected.provider == .codex,
           let advertised = CodexPickerCatalog.efforts(
                for: selected.modelID, catalog: codexCatalogCache?.catalog) {
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
        p.identifier = NSUserInterfaceItemIdentifier("effort|\(route.rawValue)")
        p.target = self
        p.action = #selector(effortChanged(_:))
        p.isEnabled = selected.provider != .local
        p.toolTip = selected.provider == .local ? "Local routes do not use an effort setting." : nil
        return p
    }

    private func addAdvancedBundleEditor(to card: NSView, route: LLMRouteID, y: CGFloat,
                                         xOffset: CGFloat = 14) -> CGFloat {
        let selected = settingsStore.selectedBundle(for: route)
        card.addSubview(text("Custom ID", x: xOffset, y: y + 4, width: 64,
                             size: 10.5, weight: .regular, color: .secondaryLabelColor))
        let model = NSTextField(string: selected.modelID)
        model.placeholderString = "exact provider model ID"
        model.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        model.identifier = NSUserInterfaceItemIdentifier("custom-model|\(route.rawValue)")
        model.frame = NSRect(x: xOffset + 68, y: y, width: 224, height: 24)
        card.addSubview(model)
        let effort = NSTextField(string: selected.effort ?? "")
        effort.placeholderString = "effort (optional)"
        effort.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        effort.identifier = NSUserInterfaceItemIdentifier("custom-effort|\(route.rawValue)")
        effort.frame = NSRect(x: xOffset + 298, y: y, width: 122, height: 24)
        effort.isEnabled = selected.provider != .local
        card.addSubview(effort)
        card.addSubview(button("Save custom", id: "save-custom|\(route.rawValue)",
                               action: #selector(saveCustomBundle(_:)),
                               x: xOffset + 426, y: y - 1, width: 102))
        return y + 34
    }

    private func addPromptRows(to card: NSView, route: LLMRouteID, customID: String? = nil,
                               y: CGFloat, xOffset: CGFloat = 14) -> CGFloat {
        var y = y
        if let customID = customID, let mode = customStore.mode(id: customID) {
            let state = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty" : "Ready"
            card.addSubview(text("Shared task prompt: \(state)", x: xOffset, y: y + 4, width: 240,
                                 size: 10.5, weight: .medium, color: .secondaryLabelColor))
            card.addSubview(button("Edit task prompt", id: "edit-custom-prompt|\(customID)",
                                   action: #selector(editCustomPrompt(_:)),
                                   x: card.bounds.width - 142, y: y, width: 128))
            return y + 34
        }

        // The overlay is per PROVIDER, so this row is about the provider this route is pinned to. Naming it
        // is the difference between "my edit vanished" and "that edit belongs to the other provider" when
        // the pin changes.
        let provider = settingsStore.selectedBundle(for: route).provider
        let editX = card.bounds.width - 116
        let resetX = editX - 106
        for variant in promptVariants(for: route) {
            let state = settingsStore.promptCustomizationState(for: route, provider: provider, variant: variant)
            let stateLabel = state == .testedDefault ? "Tested default" : "Customized"
            let variantName = promptVariantName(variant, route: route)
            let title = "\(variantName) prompt · \(Self.displayName(for: provider)): \(stateLabel)"
            let label = text(title, x: xOffset, y: y + 4, width: max(120, resetX - 8 - xOffset),
                             size: 10.5, weight: .medium, color: .secondaryLabelColor)
            label.identifier = NSUserInterfaceItemIdentifier(
                "prompt-state|\(route.rawValue)|\(provider.rawValue)|\(variant.rawValue)")
            label.toolTip = title
            card.addSubview(label)
            let target = "\(route.rawValue)|\(provider.rawValue)|\(variant.rawValue)"
            let reset = button("Reset prompt", id: "reset-prompt|\(target)",
                               action: #selector(resetPrompt(_:)),
                               x: resetX, y: y, width: 100)
            reset.isEnabled = state == .customized
            reset.toolTip = reset.isEnabled
                ? "Delete your \(variantName) edit and run the prompt this build ships. Model and effort are untouched."
                : "This route already runs the \(variantName) prompt this build ships."
            card.addSubview(reset)
            card.addSubview(button("Edit prompt", id: "edit-prompt|\(target)",
                                   action: #selector(editPrompt(_:)),
                                   x: editX, y: y, width: 102))
            y += 32
        }
        return y
    }

    private func addRestoreButtons(to card: NSView, spec: RouteCard, y: CGFloat) -> CGFloat {
        card.addSubview(text("Restore complete tested bundle:", x: 14, y: y + 5, width: 188,
                             size: 10.5, weight: .regular, color: .secondaryLabelColor))
        var x: CGFloat = 205
        for provider in LLMProvider.allCases {
            let b = button("Restore \(Self.displayName(for: provider)) default",
                           id: "restore|\(spec.key)|\(provider.rawValue)",
                           action: #selector(restoreProvider(_:)), x: x, y: y, width: 126)
            let available = spec.routes.filter {
                LLMProviderDefaults.testedBundle(for: provider, route: $0) != nil
            }
            b.isEnabled = !available.isEmpty
            if available.isEmpty {
                b.toolTip = "No shipped \(Self.displayName(for: provider)) default exists for this route."
            } else if available.count < spec.routes.count {
                let skipped = spec.routes.filter { !available.contains($0) }
                    .map { Self.displayName(for: $0) }.joined(separator: ", ")
                b.toolTip = "Restores available defaults only. No \(Self.displayName(for: provider)) default: \(skipped)."
            }
            card.addSubview(b)
            x += 132
        }
        return y + 36
    }

    // MARK: actions

    @objc private func checkCloudUpdatesNow() {
        status("Checking cloud presets...")
        NotificationCenter.default.post(
            name: CloudUpdateRuntimeState.checkRequested, object: nil)
    }

    @objc private func cloudUpdateAutoCheckChanged(_ sender: NSButton) {
        Settings.cloudUpdateAutoCheck = sender.state == .on
        status("Automatic restart check \(Settings.cloudUpdateAutoCheck ? "enabled" : "disabled").")
    }

    @objc private func bulkProviderClicked(_ sender: NSButton) {
        guard let provider = Self.providerFrom(sender.identifier, prefix: "bulk|") else { return }
        guard providerCanBeSelected(provider) else { return }
        do {
            try settingsStore.applyGlobalProvider(provider)
            let skipped = noTestedDefaultRoutes(provider: provider, routes: settingsStore.routeIDs())
            if skipped.isEmpty {
                status("All provider-capable routes now use their tested \(Self.displayName(for: provider)) defaults.")
            } else {
                status("Applied tested \(Self.displayName(for: provider)) defaults where available. No default; unchanged: \(routeList(skipped)).")
            }
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let key = Self.identifierSuffix(sender, prefix: "provider|"),
              let raw = sender.selectedItem?.representedObject as? String,
              let provider = LLMProvider(rawValue: raw),
              let spec = routeCards().first(where: { $0.key == key }) else {
            rebuild()
            return
        }
        guard providerCanBeSelected(provider) else { return }
        do {
            if spec.isCleanup {
                let skipped = spec.routes.filter {
                    settingsStore.rememberedBundle(for: provider, route: $0) == nil
                        && LLMProviderDefaults.testedBundle(for: provider, route: $0) == nil
                }
                try settingsStore.applyCleanupProvider(provider)
                if skipped.isEmpty {
                    status("\(spec.title) now uses \(Self.displayName(for: provider)).")
                } else {
                    status("Applied \(Self.displayName(for: provider)) where available. No default; unchanged: \(routeList(skipped)).")
                }
            } else {
                try settingsStore.selectProvider(provider, for: spec.primaryRoute)
                status("\(spec.title) now uses \(Self.displayName(for: provider)).")
            }
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let route = Self.routeFrom(sender.identifier, prefix: "model|"),
              let id = sender.selectedItem?.representedObject as? String, !id.isEmpty else { return }
        let bundle = CodexPickerCatalog.applyingModelSelection(
            id, to: settingsStore.selectedBundle(for: route))
        do {
            try settingsStore.setSelectedBundle(bundle, for: route)
            status("Saved \(Self.displayName(for: route)) model \(compactModelName(id)).")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        guard let route = Self.routeFrom(sender.identifier, prefix: "effort|"),
              let raw = sender.selectedItem?.representedObject as? String else { return }
        let bundle = CodexPickerCatalog.applyingEffortSelection(
            raw, to: settingsStore.selectedBundle(for: route))
        do {
            try settingsStore.setSelectedBundle(bundle, for: route)
            status("Saved \(Self.displayName(for: route)) effort \(raw.isEmpty ? "Default" : raw).")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func saveCustomBundle(_ sender: NSButton) {
        guard let route = Self.routeFrom(sender.identifier, prefix: "save-custom|"),
              let modelField = descendant(id: "custom-model|\(route.rawValue)") as? NSTextField,
              let effortField = descendant(id: "custom-effort|\(route.rawValue)") as? NSTextField else { return }
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { status("Custom model ID cannot be empty.", error: true); return }
        var bundle = settingsStore.selectedBundle(for: route)
        guard providerCanBeSelected(bundle.provider) else { return }
        bundle.modelID = model
        let effort = effortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        bundle.effort = bundle.provider == .local || effort.isEmpty ? nil : effort
        do {
            try settingsStore.setSelectedBundle(bundle, for: route)
            status("Saved custom \(Self.displayName(for: bundle.provider)) model/effort for \(Self.displayName(for: route)).")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        guard let key = Self.identifierSuffix(sender, prefix: "advanced|") else { return }
        if expandedCards.contains(key) { expandedCards.remove(key) }
        else { expandedCards.insert(key) }
        rebuild()
    }

    @objc private func editPrompt(_ sender: NSButton) {
        guard let target = Self.promptTarget(sender.identifier, prefix: "edit-prompt|"),
              let window = window else { return }
        let (route, provider, variant) = target
        let customized = settingsStore.promptCustomizationState(
            for: route, provider: provider, variant: variant) == .customized
        PromptEditorSheet.present(
            on: window,
            title: "\(Self.displayName(for: provider)) · \(Self.displayName(for: route)) · \(promptVariantName(variant, route: route))",
            subtitle: customized
                ? "Customized. Restore shipped default, then Save, clears your override."
                : "This is the prompt this build ships. Saving an edit marks it customized.",
            text: settingsStore.effectivePrompt(for: route, provider: provider, variant: variant),
            shippedDefault: settingsStore.factoryPrompt(for: route, provider: provider, variant: variant)
        ) { [weak self] text in
            self?.applyPromptEdit(text, route: route, provider: provider, variant: variant)
        }
    }

    /// What a saved prompt edit means. Blank text and the shipped bytes both mean "no override"; the store
    /// owns that rule, so the sheet hands over exactly what the user typed and this reports the state that
    /// resulted — which is why restoring the shipped default inside the editor and saving it reads back as
    /// Tested default rather than as an override that happens to match.
    func applyPromptEdit(_ text: String, route: LLMRouteID, provider: LLMProvider,
                         variant: LLMPromptVariant) {
        do {
            try settingsStore.setPromptOverride(text, for: route, provider: provider, variant: variant)
            let restored = settingsStore.promptCustomizationState(
                for: route, provider: provider, variant: variant) == .testedDefault
            status(restored ? "Prompt restored to Tested default." : "Prompt saved as Customized.")
        } catch { status(error.localizedDescription, error: true) }
    }

    /// Prompt-only reset: it deletes the overlay entry and nothing else. "Restore <provider> default" below
    /// reinstalls the whole tested bundle and selects that provider, which is a much bigger gesture than
    /// "put the prompt back" — a user who only retuned wording should not have to accept a model/effort
    /// rewrite to undo it.
    @objc private func resetPrompt(_ sender: NSButton) {
        guard let target = Self.promptTarget(sender.identifier, prefix: "reset-prompt|") else { return }
        let (route, provider, variant) = target
        do {
            try settingsStore.setPromptOverride(nil, for: route, provider: provider, variant: variant)
            status("\(promptVariantName(variant, route: route)) prompt reset to the shipped \(Self.displayName(for: provider)) default. Model and effort unchanged.")
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func editCustomPrompt(_ sender: NSButton) {
        guard let id = Self.identifierSuffix(sender, prefix: "edit-custom-prompt|"),
              let mode = customStore.mode(id: id), let window = window else { return }
        PromptEditorSheet.presentCustomModeWorkstation(
            on: window, title: Self.customPromptTitle(for: mode), mode: mode
        ) { [weak self] text in
            self?.applyCustomPromptEdit(text, id: id)
        }
    }

    /// The workstation's title line, shared with the probes so they open the same sheet the button does.
    static func customPromptTitle(for mode: CustomMode) -> String {
        let name = mode.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "Custom hotkey" : name) · Shared task prompt"
    }

    /// What a saved workstation edit means: the editable region's bytes become the mode's stored task
    /// prompt, and nothing else moves. The panel's scaffold is presentation, so it can never arrive
    /// here — saving with no edit rewrites the mode with the bytes it already had.
    func applyCustomPromptEdit(_ text: String, id: String) {
        guard var candidate = customStore.mode(id: id) else { return }
        candidate.prompt = text
        do {
            try customStore.upsert(candidate)
            status("Saved the provider-neutral custom task prompt.")
        } catch { status("Could not save custom task prompt — \(error.localizedDescription)", error: true) }
    }

    @objc private func restoreProvider(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("restore|") else { return }
        let parts = raw.dropFirst("restore|".count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = LLMProvider(rawValue: String(parts[1])),
              let spec = routeCards().first(where: { $0.key == String(parts[0]) }) else { return }
        do {
            try settingsStore.restoreProviderDefault(provider, for: spec.routes)
            let skipped = noTestedDefaultRoutes(provider: provider, routes: spec.routes)
            if skipped.isEmpty {
                status("Restored \(spec.title) to its complete tested \(Self.displayName(for: provider)) bundle.")
            } else {
                status("Restored available \(Self.displayName(for: provider)) defaults. No default; unchanged: \(routeList(skipped)).")
            }
        } catch { status(error.localizedDescription, error: true) }
    }

    @objc private func retryClicked(_ sender: NSButton) {
        guard let key = Self.identifierSuffix(sender, prefix: "retry|"),
              let spec = routeCards().first(where: { $0.key == key }),
              let route = retryRoute(in: spec), let provider = retryProviders[route] else { return }
        onRetry?(route, provider)
    }

    // MARK: state helpers

    private func providerCanBeSelected(_ provider: LLMProvider) -> Bool {
        switch settingsStore.availabilityState(for: provider) {
        case .available:
            return true
        case .disconnected:
            // D6, the inline rescue, generalized from Codex-only to either provider. Picking a disconnected
            // provider still does NOT change the route - the route keeps the provider that can actually run
            // it - and the connect flow opens instead, so the user is one click from fixing what they just
            // asked for. It is the same `ProviderSignInPresenter` the Setup tab drives, reached through the
            // host: this view has no connect implementation of its own to drift from it.
            status(Self.inlineRescueStatus(for: provider))
            if ProviderOnboarding.canDriveSignIn(provider) { onConnectProvider?(provider) }
            return false
        case .unavailable(let reason):
            status("\(Self.displayName(for: provider)) is unavailable: \(reason)", error: true)
            return false
        }
    }

    private func selectedAvailability(for spec: RouteCard) -> LLMProviderAvailabilityState {
        switch settingsStore.bulkProviderState(routes: spec.routes) {
        case .mixed: return .unavailable("Mixed per-strength providers")
        case .provider(let provider): return settingsStore.availabilityState(for: provider)
        }
    }

    private func routeAvailabilityText(for spec: RouteCard) -> String {
        if case .mixed = settingsStore.bulkProviderState(routes: spec.routes) {
            return "Mixed per-strength providers"
        }
        return availabilityText(selectedAvailability(for: spec))
    }

    private func availabilityText(_ state: LLMProviderAvailabilityState) -> String {
        switch state {
        case .available: return "Available"
        case .disconnected: return "Disconnected"
        case .unavailable(let reason): return "Unavailable · \(reason)"
        }
    }

    private func cleanupBundleSummary(_ spec: RouteCard) -> String {
        switch settingsStore.bulkProviderState(routes: spec.routes) {
        case .mixed: return "Mixed per-strength provider/model choices · open Advanced to review."
        case .provider(let provider):
            let bundles = spec.routes.map { settingsStore.selectedBundle(for: $0) }
            let models = Set(bundles.map(\.modelID))
            let effort = Set(bundles.compactMap(\.effort))
            let modelText = models.count == 1 ? compactModelName(models.first!) : "per-strength models"
            let effortText = effort.count == 1 ? (effort.first ?? "Default") : "per-strength effort"
            return "\(Self.displayName(for: provider)) · \(modelText) · \(effortText)"
        }
    }

    private func promptSummary(for spec: RouteCard) -> String {
        if let id = spec.customID, let mode = customStore.mode(id: id) {
            return mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Shared task prompt: Empty" : "Shared task prompt: Ready"
        }
        var customized = false
        for route in spec.routes {
            let provider = settingsStore.selectedBundle(for: route).provider
            for variant in promptVariants(for: route) {
                if settingsStore.promptCustomizationState(for: route, provider: provider, variant: variant) == .customized {
                    customized = true
                }
            }
        }
        return "Prompt: \(customized ? "Customized" : "Tested default")"
    }

    /// The route-level ratification verdict: a fold of the store's per-variant judgement, not a new one.
    /// Option+P carries three prompt variants, so a route is unratified if ANY of them is, and the reasons
    /// are collected in declaration order rather than variant order so the row's wording does not depend on
    /// which variant the user happened to edit first.
    private func routeRatification(route: LLMRouteID, provider: LLMProvider) -> LLMRatificationState {
        let states = promptVariants(for: route).map {
            settingsStore.ratificationState(for: route, provider: provider, variant: $0)
        }
        let reasons = LLMUnratifiedReason.allCases.filter { reason in
            states.contains { $0.hasReason(reason) }
        }
        guard reasons.isEmpty else { return .unratified(reasons) }
        // Every variant ratified against the same bundle, so any one of their provenances is the route's.
        return states.first ?? .unratified([.noEvidence])
    }

    private func promptVariants(for route: LLMRouteID) -> [LLMPromptVariant] {
        route == .promptPrep ? [.cleanupL1, .cleanupL2, .cleanupL3] : [.primary]
    }

    private func promptVariantName(_ variant: LLMPromptVariant, route: LLMRouteID) -> String {
        switch variant {
        case .primary: return route == .email ? "Email" : (route == .searchLocalSynth || route == .searchGeminiSynth ? "Synthesis" : Self.displayName(for: route))
        case .cleanupL1: return "Cleanup"
        case .cleanupL2: return "Tighten"
        case .cleanupL3: return "Summarize"
        }
    }

    private func retryRoute(in spec: RouteCard) -> LLMRouteID? {
        spec.routes.first { retryProviders[$0] != nil }
    }

    private func noTestedDefaultRoutes(provider: LLMProvider,
                                       routes: [LLMRouteID]) -> [LLMRouteID] {
        routes.filter { LLMProviderDefaults.testedBundle(for: provider, route: $0) == nil }
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func routeList(_ routes: [LLMRouteID]) -> String {
        routes.map { Self.displayName(for: $0) }.joined(separator: ", ")
    }

    private func status(_ message: String, error: Bool = false) {
        statusMessage = message
        statusIsError = error
        rebuild()
    }

    // MARK: view helpers

    private func cardView(y: CGFloat, height: CGFloat, id: String) -> ModelsPowerCardView {
        let v = ModelsPowerCardView(frame: NSRect(x: L, y: y, width: W - 2 * L, height: height))
        v.identifier = NSUserInterfaceItemIdentifier(id)
        v.wantsLayer = true
        v.layer?.backgroundColor = Phosphor.panelBG.withAlphaComponent(0.45).cgColor
        v.layer?.cornerRadius = 9
        v.layer?.borderWidth = 1
        v.layer?.borderColor = Phosphor.green.withAlphaComponent(0.14).cgColor
        addSubview(v)
        return v
    }

    private func sectionHeader(_ title: String, y: CGFloat) -> NSTextField {
        text(title, x: L, y: y, width: W - 2 * L,
             size: 10, weight: .semibold, color: .secondaryLabelColor)
    }

    private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: value)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: x, y: y, width: width, height: max(15, size + 4))
        return t
    }

    private func wrap(_ value: String, x: CGFloat, y: CGFloat,
                      width: CGFloat, height: CGFloat) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: value)
        t.font = .systemFont(ofSize: 10.5)
        t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: x, y: y, width: width, height: height)
        return t
    }

    private func button(_ title: String, id: String, action: Selector,
                        x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 10.5)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.frame = NSRect(x: x, y: y, width: width, height: 26)
        return b
    }

    private func compactModelName(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last!) : id
    }

    static func identifierSuffix(_ control: NSControl, prefix: String) -> String? {
        stripIdentifierPrefix(control.identifier, prefix: prefix)
    }

    static func providerFrom(_ id: NSUserInterfaceItemIdentifier?, prefix: String) -> LLMProvider? {
        stripIdentifierPrefix(id, prefix: prefix).flatMap(LLMProvider.init(rawValue:))
    }

    static func routeFrom(_ id: NSUserInterfaceItemIdentifier?, prefix: String) -> LLMRouteID? {
        stripIdentifierPrefix(id, prefix: prefix).flatMap(LLMRouteID.init(rawValue:))
    }

    /// The `route|provider|variant` triple every prompt control carries. Edit and Reset address exactly the
    /// same overlay entry, so they parse it through one function rather than two copies that can drift.
    static func promptTarget(
        _ id: NSUserInterfaceItemIdentifier?, prefix: String
    ) -> (route: LLMRouteID, provider: LLMProvider, variant: LLMPromptVariant)? {
        guard let suffix = stripIdentifierPrefix(id, prefix: prefix) else { return nil }
        let parts = suffix.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let route = LLMRouteID(rawValue: String(parts[0])),
              let provider = LLMProvider(rawValue: String(parts[1])),
              let variant = LLMPromptVariant(rawValue: String(parts[2])) else { return nil }
        return (route, provider, variant)
    }

    private func descendant(id: String) -> NSView? {
        func find(_ root: NSView) -> NSView? {
            for child in root.subviews {
                if child.identifier?.rawValue == id { return child }
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(self)
    }
}
