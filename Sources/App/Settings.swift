import Foundation

/// User-tunable settings (UserDefaults-backed) plus the derived audio-meter parameters.
///
/// Three meter knobs map to a proper dBFS level mapping (replaces the old linear `sqrt(rms)*4.5`
/// hack that pinned normal speech into the bottom few percent). One transcription toggle controls
/// whether the daemon reduces repeated-word / end-of-audio hallucinations.
enum Settings {
    private static let d = UserDefaults.standard
    static let legacyDefaultsMigrationMarker =
        "didMigrateDefaultsFromComViddyslapViddyDictate"
    /// A4's single durable routing authority. Kept lazy so pure settings registration and build-time
    /// theme emission do not touch the Models & Power file.
    static var modelsPower: ModelsPowerSettingsStore { ModelsPowerSettingsStore.shared }
    static let didChange = Notification.Name("VDSettingsDidChange")
    static let cloudUpdateAutoCheckDidChange =
        Notification.Name("VDCloudUpdateAutoCheckDidChange")
    /// Posted true when a real dictation starts, false when it ends — lets the settings preview
    /// release the mic so it never races the dictation recorder for the input device.
    static let dictationActive = Notification.Name("VDDictationActive")
    static let cloudUpdateAutoCheckDefault = true

    private enum K {
        static let sensitivity = "meterSensitivity"   // 0…1
        static let gain        = "meterGain"          // 0…1
        static let reactivity  = "meterReactivity"    // 0…1
        static let reduceRepeats = "reduceRepeats"    // Bool
        // Cleanup mode (post-processing layer). Model-pluggable: the model id, endpoint, prompt,
        // and safety timeout are all config so the pending Gemma 3 4B IT QAT head-to-head swaps in
        // without a code change.
        static let cleanupModel       = "cleanupModel"
        static let cleanupEndpoint    = "cleanupEndpoint"
        static let cleanupSystemPrompt = "cleanupSystemPrompt"   // Level 0 (Cleanup) prompt
        static let cleanupPromptL1    = "cleanupPromptLevel1"    // Level 1 (Tighten) prompt
        static let cleanupPromptL2    = "cleanupPromptLevel2"    // Level 2 (Summarize) prompt
        static let cleanupLevel       = "cleanupLevel"           // 0…2, remembered across launches
        // Option+P prompt-prep sticky level. INDEPENDENT of `cleanupLevel` (the `?`-slider level): the
        // two hotkeys remember their last-used level separately. Default Tighten (1) — the middle pick.
        static let promptPrepLevel    = "promptPrepLevel"        // 0…2, remembered across launches
        // Option+P's own model, independent of the `?`-toggle cleanup model (mirrors promptPrepLevel).
        // The Models & Power Prompt-prep row edits this; default = the cleanup model, so behavior is unchanged.
        static let promptPrepModel    = "promptPrepModel"
        // Legacy storage key for Option+P's provider. A1 preserves the key for migration compatibility but
        // canonical values are now typed LLMProvider raw values (local/claude/codex); `cloud` migrates.
        static let promptPrepModelKind = "promptPrepModelKind"
        static let cleanupTimeout     = "cleanupTimeoutSeconds"
        static let cleanupTemperature = "cleanupTemperature"
        // Email mode (Option+M). A DISTINCT model from cleanup (a small reasoner), kept resident by a
        // keep-alive. All config so the model / endpoint / prompt / budget swap without a code change.
        static let emailModel         = "emailModel"
        // Legacy storage key for Option+M's typed provider (see promptPrepModelKind).
        static let emailModelKind     = "emailModelKind"
        static let emailEndpoint      = "emailEndpoint"
        static let emailSystemPrompt  = "emailSystemPrompt"
        static let emailTimeout       = "emailTimeoutSeconds"
        static let emailTemperature   = "emailTemperature"
        static let emailMaxTokens     = "emailMaxTokens"
        // Mode ids whose eligible Hotkeys rows opt into persistent-toggle chord semantics. The setting
        // survives launch; the armed transform slot itself deliberately does not.
        static let persistentToggleModeIDs = "persistentToggleModeIDs"
        // Web-search modes (Option+L local / Option+G Gemini). Two-model Shape C: a retrieval model
        // (qwen, agentic tool loop) + a synthesis model (gemma, spoken answer). All config so the
        // models / endpoint / prompts / budgets swap without a code change. Defaults live in
        // SearchClient (the bench-locked prompts) + below.
        static let searchModel        = "searchModel"        // retrieval / agentic loop
        static let searchSynthModel   = "searchSynthModel"   // spoken-answer synthesis
        static let searchEndpoint     = "searchEndpoint"
        static let searchSynthPrompt  = "searchSynthPrompt"
        static let searchAgenticPrompt = "searchAgenticPrompt"
        static let searchTimeout      = "searchSearchTimeoutSeconds"
        static let searchSynthMaxTokens = "searchSynthMaxTokens"
        static let searchRetrievalMaxTokens = "searchRetrievalMaxTokens"
        static let searchMaxSearches  = "searchMaxSearches"
        static let geminiModel        = "geminiModel"
        // The Gemini API key is NOT a setting: it lives in the login keychain (see SecretStore), so it
        // never lands in this defaults plist. Resolution order is Keychain, then VIDDYDICTATE_GEMINI_API_KEY.
        // History retention caps, tunable per tab from the History window (default 25).
        static let dictationHistoryMax = "dictationHistoryMax"
        static let clipboardHistoryMax = "clipboardHistoryMax"
        // Infinite dictation-history store (L4). OFF by default. When ON, every delivered
        // transcript is appended forever to an app-local per-day markdown log (DictationHistoryStore),
        // which lives OUTSIDE Obsidian vaults so external tools can index it through the read-only file
        // seam. Independent of the rolling-25 caps above (those are unchanged).
        static let keepFullHistory = "keepFullHistory"
        // Local WAV ring for debugging real end-of-recording behavior. ON by default; the Audio tab
        // exposes both an off switch and a purge control. Independent of transcript history.
        static let retainDictationAudio = "retainDictationAudio"
        // Provider onboarding (Public V1 spec W4). Records that a text provider has been signed in at least
        // once, which is what makes the first-run window first-run-only: it appears before a user has ever had
        // a provider and never again after. NOT a "we showed it" flag - a user who dismisses it and then signs
        // in through Settings is done, and a user who later signs out is told by the re-runnable Setup tab
        // rather than nagged at launch.
        static let providerOnboardingSatisfied = "providerOnboardingSatisfied"
        // Sticky notes (Option+N): save-as destination and soft-delete retention.
        static let stickyNotesSaveDirectory = "stickyNotesSaveDirectory"
        static let stickyNotesRetention = "stickyNotesRetention"
        // Whether the sticky-notes floating "i" markdown-cheat-sheet button exists at all (L5).
        // Toggled from the hamburger settings strip; OFF removes the button + cheat-sheet access.
        static let stickyNotesCheatSheetButton = "stickyNotesCheatSheetButton"  // Bool, default true
        // Input-device pin. UID is the binding key (stable across unplug/reconnect); "" = follow the
        // macOS system default. Name is display-only, so the picker can label a pinned-but-absent mic.
        static let inputDeviceUID  = "inputDeviceUID"
        static let inputDeviceName = "inputDeviceName"
        // Power behavior: the canonical enum is manual/sticky. `lowPowerMode` is read once only to migrate
        // the pre-A3 Bool without changing the user's chosen presentation/transcription behavior.
        static let powerMode       = "powerMode"
        static let legacyLowPowerMode = "lowPowerMode"
        // The pre-A3 Low Power policy's per-route Claude bundles remain readable for A1 migration
        // compatibility, but A3 makes this blob inert: Power Mode never selects a provider or model.
        static let lowPowerPolicy  = "lowPowerPolicy"
        // Material battery state for which the one-shot advisory has already been shown/dismissed.
        static let batteryAdvisoryDismissal = "batteryAdvisoryDismissal"
        static let cloudUpdateAutoCheck = "cloudUpdateAutoCheck"
        static let hudPosition     = "hudPosition"        // HUDPosition rawValue
        static let hudScale        = "hudScale"           // regular-HUD scale factor
        static let hudPillScale    = "hudLowPowerScale"   // low-power pill scale factor
        static let hudSpinnerScale = "hudSpinnerScale"    // cleanup-wait spinner (ring) scale factor
        // Appearance: the one monochromatic theme accent ("#rrggbb"). Phosphor derives the whole palette
        // (native panels + the sticky-notes web island) from it; default = the phosphor green.
        static let themeColor      = "themeColorHex"
    }

    /// The ONE home for every persisted default. `registerDefaults()` registers exactly these values
    /// and `resetToDefaults()` restores from them; getters trust the registration (the optional
    /// String accessors keep a `??` fallback, but it reads the same constant here — never a second
    /// literal). Exceptions with their own single home, referenced directly: the prompt texts
    /// (`Prompts.swift`) and the sticky-notes directory (`defaultStickyNotesSaveDirectory`).
    /// UserDefaults caveat: a value already persisted on this machine (e.g. a bench-era
    /// `defaults write`) silently shadows whatever is registered here.
    private enum Defaults {
        private static let lmStudioEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
        static let sensitivity = 0.62
        static let gain = 0.20
        static let reactivity = 0.72
        static let reduceRepeats = true
        // Cleanup model: qwen3-coder-30b-a3b is the on-disk pick that clears the golden green
        // bar (the locked first-pass llama-3.2-3b hallucinates on the hardest meta-dictation,
        // golden sample 3). Model-pluggable: change this one value to swap back to the 3B or to
        // gemma-3-4b-it-qat once it downloads. See the repository history for the evaluation record.
        static let cleanupModel = LLMProviderDefaults.localCleanupModelID
        static let cleanupEndpoint = lmStudioEndpoint
        static let cleanupLevel = 0
        static let promptPrepLevel = 1     // Option+P default = Tighten (the middle pick)
        static let promptPrepModel = cleanupModel   // Option+P's model defaults to the cleanup model
        static let promptPrepModelKind = LLMProvider.local.rawValue
        static let cleanupTimeout = 12.0   // headroom for the 30B on a long dictation (~4.5s worst seen)
        static let cleanupTemperature = 0.0  // greedy, for reproducible maximally-faithful cleanup
        // Email mode: gemma-4-e4b (the bench winner — a reliable lightweight reasoner), temp 0.0,
        // a HIGH token ceiling so the reasoner can think before emitting, and a latency-relaxed
        // timeout (median ~10s, ~17s worst; budget covers a cold JIT load + retry).
        static let emailModel = LLMProviderDefaults.localEmailModelID
        static let emailModelKind = LLMProvider.local.rawValue
        static let emailEndpoint = lmStudioEndpoint
        static let emailTimeout = 60.0
        static let emailTemperature = 0.0
        static let emailMaxTokens = 16384
        static let persistentToggleModeIDs: [String] = []
        // Web-search modes. Retrieval = qwen3-coder-30b (purpose-built for tools), synthesis =
        // gemma-4-e4b (the faithful spoken voice) — Shape C, the bench winner (18/18 evergreen).
        // Both already resident (cleanup + email keep-alives + the search keep-alive pin them).
        static let searchModel = LLMProviderDefaults.localCleanupModelID
        static let searchSynthModel = LLMProviderDefaults.localSearchSynthesisModelID
        static let searchEndpoint = lmStudioEndpoint
        static let searchTimeout = 45.0           // per LM Studio call (gemma synth is the slow leg)
        static let searchSynthMaxTokens = 8192    // gemma thinks before it speaks; room not to be cut off
        static let searchRetrievalMaxTokens = 1024
        static let searchMaxSearches = 2          // the bounded-agentic cap (rewrite + one optional re-search)
        static let geminiModel = "gemini-2.5-flash"
        static let dictationHistoryMax = 25
        static let clipboardHistoryMax = 25
        static let keepFullHistory = false   // L4: opt-in and off by default
        static let retainDictationAudio = true
        static let providerOnboardingSatisfied = false   // a fresh install has never had a provider
        static let stickyNotesRetention = StickyNotesRetention.oneDay
        static let stickyNotesCheatSheetButton = true   // the "i" cheat-sheet button exists by default
        static let inputDeviceUID = ""     // default: follow the macOS system default input device
        static let inputDeviceName = ""
        static let powerMode = PowerMode.live
        static let cloudUpdateAutoCheck = Settings.cloudUpdateAutoCheckDefault
        static let hudPosition = HUDPosition.bottomCenter
        static let hudScale = 1.0
        static let hudPillScale = 1.0
        static let hudSpinnerScale = 1.0
        static let themeColor = Phosphor.defaultAccentHex   // "#00ff41" — the untouched phosphor green
    }

    /// Allowed range for the per-tab history retention caps.
    static let historyMaxRange = 1...500

    /// Live flag (not persisted) so the settings preview can avoid starting a second mic while a
    /// real dictation is in flight. Set by the controller around each take.
    static var isDictationActive = false

    static func registerDefaults() {
        migrateLegacyPowerModeIfNeeded()
        d.register(defaults: [
            K.sensitivity: Defaults.sensitivity,
            K.gain: Defaults.gain,
            K.reactivity: Defaults.reactivity,
            K.reduceRepeats: Defaults.reduceRepeats,
            K.cleanupModel: Defaults.cleanupModel,
            K.cleanupEndpoint: Defaults.cleanupEndpoint,
            K.cleanupSystemPrompt: firmCleanupPrompt,
            K.cleanupPromptL1: tightenCleanupPrompt,
            K.cleanupPromptL2: summarizeCleanupPrompt,
            K.cleanupLevel: Defaults.cleanupLevel,
            K.promptPrepLevel: Defaults.promptPrepLevel,
            K.promptPrepModel: Defaults.promptPrepModel,
            K.promptPrepModelKind: Defaults.promptPrepModelKind,
            K.cleanupTimeout: Defaults.cleanupTimeout,
            K.cleanupTemperature: Defaults.cleanupTemperature,
            K.emailModel: Defaults.emailModel,
            K.emailModelKind: Defaults.emailModelKind,
            K.emailEndpoint: Defaults.emailEndpoint,
            K.emailSystemPrompt: defaultEmailSystemPrompt,
            K.emailTimeout: Defaults.emailTimeout,
            K.emailTemperature: Defaults.emailTemperature,
            K.emailMaxTokens: Defaults.emailMaxTokens,
            K.persistentToggleModeIDs: Defaults.persistentToggleModeIDs,
            K.searchModel: Defaults.searchModel,
            K.searchSynthModel: Defaults.searchSynthModel,
            K.searchEndpoint: Defaults.searchEndpoint,
            K.searchSynthPrompt: defaultSearchSynthPrompt,
            K.searchAgenticPrompt: defaultSearchAgenticPrompt,
            K.searchTimeout: Defaults.searchTimeout,
            K.searchSynthMaxTokens: Defaults.searchSynthMaxTokens,
            K.searchRetrievalMaxTokens: Defaults.searchRetrievalMaxTokens,
            K.searchMaxSearches: Defaults.searchMaxSearches,
            K.geminiModel: Defaults.geminiModel,
            K.dictationHistoryMax: Defaults.dictationHistoryMax,
            K.clipboardHistoryMax: Defaults.clipboardHistoryMax,
            K.keepFullHistory: Defaults.keepFullHistory,
            K.retainDictationAudio: Defaults.retainDictationAudio,
            K.providerOnboardingSatisfied: Defaults.providerOnboardingSatisfied,
            K.stickyNotesSaveDirectory: defaultStickyNotesSaveDirectory.path,
            K.stickyNotesRetention: Defaults.stickyNotesRetention.rawValue,
            K.stickyNotesCheatSheetButton: Defaults.stickyNotesCheatSheetButton,
            K.inputDeviceUID: Defaults.inputDeviceUID,
            K.inputDeviceName: Defaults.inputDeviceName,
            K.powerMode: Defaults.powerMode.rawValue,
            K.cloudUpdateAutoCheck: Defaults.cloudUpdateAutoCheck,
            K.hudPosition: Defaults.hudPosition.rawValue,
            K.hudScale: Defaults.hudScale,
            K.hudPillScale: Defaults.hudPillScale,
            K.hudSpinnerScale: Defaults.hudSpinnerScale,
            K.themeColor: Defaults.themeColor,
        ])
    }

    // MARK: power behavior, battery advisory, and HUD position + size

    /// Allowed range for the regular-HUD scale factor (1.0 = today's full-width HUD).
    static let hudScaleRange = 0.6...1.25
    /// Allowed range for the Final-only pill scale factor (1.0 = the compact default pill).
    static let hudPillScaleRange = 0.5...2.0
    /// Allowed range for the cleanup-wait spinner scale factor (1.0 = the default ring).
    static let hudSpinnerScaleRange = 0.5...2.0

    /// Manual/sticky Power Mode. Provider/model routing is deliberately absent from this accessor.
    static var powerMode: PowerMode {
        get {
            let raw = d.string(forKey: K.powerMode) ?? Defaults.powerMode.rawValue
            return PowerMode(rawValue: raw) ?? Defaults.powerMode
        }
        set { d.set(newValue.rawValue, forKey: K.powerMode); notify() }
    }

    /// On restart, wait for the app to settle and then check cloud provider health and preset freshness.
    /// The launch scheduler still defers the live calls until dictation is idle.
    static var cloudUpdateAutoCheck: Bool {
        get { d.bool(forKey: K.cloudUpdateAutoCheck) }
        set {
            let changed = d.bool(forKey: K.cloudUpdateAutoCheck) != newValue
            d.set(newValue, forKey: K.cloudUpdateAutoCheck)
            notify()
            if changed {
                NotificationCenter.default.post(
                    name: cloudUpdateAutoCheckDidChange,
                    object: NSNumber(value: newValue))
            }
        }
    }

    /// Migrate the old Bool once. A valid canonical value always wins; invalid canonical data safely
    /// falls back to Live. The legacy key is removed after conversion so there is only one authority.
    static func migrateLegacyPowerModeIfNeeded() {
        let domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let persisted = d.persistentDomain(forName: domain) ?? [:]
        if let raw = persisted[K.powerMode] as? String, PowerMode(rawValue: raw) != nil {
            if persisted[K.legacyLowPowerMode] != nil { d.removeObject(forKey: K.legacyLowPowerMode) }
            return
        }

        let legacy: Bool?
        if let value = persisted[K.legacyLowPowerMode] as? Bool { legacy = value }
        else if let value = persisted[K.legacyLowPowerMode] as? NSNumber { legacy = value.boolValue }
        else { legacy = nil }

        if legacy != nil || persisted[K.powerMode] != nil {
            d.set((legacy == true ? PowerMode.finalOnly : .live).rawValue, forKey: K.powerMode)
        }
        if persisted[K.legacyLowPowerMode] != nil { d.removeObject(forKey: K.legacyLowPowerMode) }
    }

    /// Copy the former bundle-id preferences into the new domain exactly once. Existing values in
    /// the destination win so a partially initialized new domain is never rolled back by stale data.
    /// The old domain remains intact as a non-destructive fallback for the pre-rename app.
    static func migrateLegacyDefaultsDomainIfNeeded() {
        migrateLegacyDefaultsDomainIfNeeded(
            defaults: d,
            currentDomain: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID,
            legacyDomain: AppIdentity.legacyBundleID)
    }

    static func migrateLegacyDefaultsDomainIfNeeded(defaults: UserDefaults,
                                                     currentDomain: String,
                                                     legacyDomain: String,
                                                     expectedCurrentDomain: String = AppIdentity.bundleID) {
        guard currentDomain == expectedCurrentDomain, currentDomain != legacyDomain else { return }

        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard current[legacyDefaultsMigrationMarker] as? Bool != true else { return }

        var migrated = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        for (key, value) in current { migrated[key] = value }
        migrated[legacyDefaultsMigrationMarker] = true
        defaults.setPersistentDomain(migrated, forName: currentDomain)
    }

    static var batteryAdvisoryDismissedState: BatteryAdvisoryMaterialState? {
        get {
            guard let data = d.data(forKey: K.batteryAdvisoryDismissal) else { return nil }
            return try? JSONDecoder().decode(BatteryAdvisoryMaterialState.self, from: data)
        }
        set {
            guard let newValue = newValue else {
                d.removeObject(forKey: K.batteryAdvisoryDismissal)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(newValue) { d.set(data, forKey: K.batteryAdvisoryDismissal) }
        }
    }

    // MARK: one-time legacy Low Power provider-bundle migration (inert after A3)

    /// Decode both the legacy `{model, effort}` map and A1's canonical provider bundles. Successful legacy
    /// reads are rewritten canonically in place; user-selected model/effort bytes are retained exactly.
    private static func legacyLowPowerPolicyMap() -> [String: LLMProviderBundle] {
        guard let data = d.data(forKey: K.lowPowerPolicy),
              let map = try? JSONDecoder().decode([String: LLMProviderBundle].self, from: data)
        else { return [:] }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let canonical = try? enc.encode(map), canonical != data {
            d.set(canonical, forKey: K.lowPowerPolicy)
        }
        return map
    }

    /// Capture every pre-A4 provider/model/prompt choice without consulting the new store. The returned
    /// value seeds `models-power.json` exactly once; the inert legacy map becomes remembered Claude
    /// arms, never a power-driven runtime choice. Its old shared `custom` arm is carried separately so
    /// the first custom-route reconciliation can fan it into each pre-existing custom route.
    static func modelsPowerLegacyState() -> ModelsPowerLegacyState {
        var legacy = ModelsPowerLegacyState.empty
        let legacyBundles = legacyLowPowerPolicyMap()

        addLegacyCleanupRoutes(to: &legacy, legacyBundles: legacyBundles)
        addLegacyPromptPrepRoute(to: &legacy, legacyBundles: legacyBundles)
        addLegacyEmailRoute(to: &legacy, legacyBundles: legacyBundles)
        addLegacySearchRoutes(to: &legacy, legacyBundles: legacyBundles)
        addLegacyPromptOverrides(to: &legacy)
        return legacy
    }

    private static func addLegacyCleanupRoutes(
        to legacy: inout ModelsPowerLegacyState,
        legacyBundles: [String: LLMProviderBundle]
    ) {
        for route in LLMRouteID.cleanupRoutes {
            let selected = LLMProviderBundle.local(cleanupModel)
            legacy.selectedBundles[route] = selected
            rememberLegacyBundle(selected, route: route, in: &legacy)
            if let claude = legacyClaudeBundle(route.rawValue, in: legacyBundles) {
                rememberLegacyBundle(claude, route: route, in: &legacy)
            }
        }
    }

    private static func addLegacyPromptPrepRoute(
        to legacy: inout ModelsPowerLegacyState,
        legacyBundles: [String: LLMProviderBundle]
    ) {
        let pLocal = LLMProviderBundle.local(promptPrepModel)
        let pSelected = ModeModelCatalog.legacySelection(
            provider: promptPrepProvider, localId: promptPrepModel) ?? pLocal
        legacy.selectedBundles[.promptPrep] = pSelected
        rememberLegacyBundle(pLocal, route: .promptPrep, in: &legacy)
        if pSelected.provider == .claude {
            rememberLegacyBundle(pSelected, route: .promptPrep, in: &legacy)
        } else if let claude = legacyClaudeBundle(LLMRouteID.promptPrep.rawValue, in: legacyBundles) {
            rememberLegacyBundle(claude, route: .promptPrep, in: &legacy)
        }
    }

    private static func addLegacyEmailRoute(
        to legacy: inout ModelsPowerLegacyState,
        legacyBundles: [String: LLMProviderBundle]
    ) {
        let mLocal = LLMProviderBundle.local(emailModel)
        let mSelected = ModeModelCatalog.legacySelection(
            provider: emailProvider, localId: emailModel) ?? mLocal
        legacy.selectedBundles[.email] = mSelected
        rememberLegacyBundle(mLocal, route: .email, in: &legacy)
        if mSelected.provider == .claude {
            rememberLegacyBundle(mSelected, route: .email, in: &legacy)
        } else if let claude = legacyClaudeBundle(LLMRouteID.email.rawValue, in: legacyBundles) {
            rememberLegacyBundle(claude, route: .email, in: &legacy)
        }
    }

    private static func addLegacySearchRoutes(
        to legacy: inout ModelsPowerLegacyState,
        legacyBundles: [String: LLMProviderBundle]
    ) {
        for route in [LLMRouteID.searchLocalSynth, .searchGeminiSynth] {
            let selected = LLMProviderBundle.local(searchSynthModel)
            legacy.selectedBundles[route] = selected
            rememberLegacyBundle(selected, route: route, in: &legacy)
            if let claude = legacyClaudeBundle(route.rawValue, in: legacyBundles) {
                rememberLegacyBundle(claude, route: route, in: &legacy)
            }
        }
        if let sharedCustomClaude = legacyClaudeBundle("custom", in: legacyBundles) {
            legacy.sharedCustomRememberedBundles[.claude] = sharedCustomClaude
        }
    }

    private static func addLegacyPromptOverrides(to legacy: inout ModelsPowerLegacyState) {
        // Provider-neutral prompt keys are copied into independent Local and Claude arms only when
        // they differ from the tested bytes. The dynamic correction glossary is not persisted here.
        func copyOverride(_ prompt: String, tested: String, route: LLMRouteID,
                          variant: LLMPromptVariant = .primary) {
            guard prompt != tested else { return }
            for provider in [LLMProvider.local, .claude] {
                var routeMap = legacy.promptOverrides[route] ?? [:]
                var providerMap = routeMap[provider] ?? [:]
                providerMap[variant] = prompt
                routeMap[provider] = providerMap
                legacy.promptOverrides[route] = routeMap
            }
        }

        let cleanupRows: [(CleanupLevel, LLMRouteID, String)] = [
            (.cleanup, .cleanupL1, firmCleanupPrompt),
            (.tighten, .cleanupL2, tightenCleanupPrompt),
            (.summarize, .cleanupL3, summarizeCleanupPrompt),
        ]
        for (level, route, tested) in cleanupRows {
            let prompt = cleanupPrompt(level)
            copyOverride(prompt, tested: tested, route: route)
            copyOverride(prompt, tested: tested, route: .promptPrep, variant: .cleanup(level))
        }
        copyOverride(emailSystemPrompt, tested: defaultEmailSystemPrompt, route: .email)
        copyOverride(searchSynthPrompt, tested: defaultSearchSynthPrompt, route: .searchLocalSynth)
        copyOverride(searchSynthPrompt, tested: defaultSearchSynthPrompt, route: .searchGeminiSynth)
    }

    private static func legacyClaudeBundle(
        _ key: String,
        in legacyBundles: [String: LLMProviderBundle]
    ) -> LLMProviderBundle? {
        guard let bundle = legacyBundles[key], bundle.provider == .claude else { return nil }
        return bundle
    }

    private static func rememberLegacyBundle(
        _ bundle: LLMProviderBundle,
        route: LLMRouteID,
        in legacy: inout ModelsPowerLegacyState
    ) {
        var row = legacy.rememberedBundles[route] ?? [:]
        row[bundle.provider] = bundle
        legacy.rememberedBundles[route] = row
    }

    /// Where the HUD (full or pill) homes itself each time it appears. Dragging still moves it for
    /// the current take; the next show returns to this anchor.
    static var hudPosition: HUDPosition {
        get {
            let raw = d.string(forKey: K.hudPosition) ?? Defaults.hudPosition.rawValue
            return HUDPosition(rawValue: raw) ?? Defaults.hudPosition
        }
        set { d.set(newValue.rawValue, forKey: K.hudPosition); notify() }
    }

    /// Regular-HUD scale factor, clamped to `hudScaleRange`.
    static var hudScale: Double {
        get { clampScale(d.double(forKey: K.hudScale), to: hudScaleRange, fallback: Defaults.hudScale) }
        set { d.set(clampScale(newValue, to: hudScaleRange, fallback: Defaults.hudScale), forKey: K.hudScale); notify() }
    }

    /// Final-only pill scale factor, clamped to `hudPillScaleRange`.
    static var hudPillScale: Double {
        get { clampScale(d.double(forKey: K.hudPillScale), to: hudPillScaleRange, fallback: Defaults.hudPillScale) }
        set { d.set(clampScale(newValue, to: hudPillScaleRange, fallback: Defaults.hudPillScale), forKey: K.hudPillScale); notify() }
    }

    /// Cleanup-wait spinner (ring) scale factor, clamped to `hudSpinnerScaleRange`.
    static var hudSpinnerScale: Double {
        get { clampScale(d.double(forKey: K.hudSpinnerScale), to: hudSpinnerScaleRange, fallback: Defaults.hudSpinnerScale) }
        set { d.set(clampScale(newValue, to: hudSpinnerScaleRange, fallback: Defaults.hudSpinnerScale), forKey: K.hudSpinnerScale); notify() }
    }

    private static func clampScale(_ v: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard v > 0 else { return fallback }   // 0 = unset (UserDefaults double default)
        return min(range.upperBound, max(range.lowerBound, v))
    }

    // MARK: appearance (theme accent)

    /// The monochromatic theme accent as "#rrggbb" — the single color Phosphor derives the whole app
    /// palette from (native panels + the sticky-notes web island). Writing it posts `didChange`, which
    /// the notes window observes to re-inject its CSS variables; the native panels read Phosphor live.
    static var themeColorHex: String {
        get { d.string(forKey: K.themeColor) ?? Defaults.themeColor }
        set { d.set(newValue, forKey: K.themeColor); notify() }
    }

    // MARK: history retention caps (per tab)

    /// Max delivered dictations kept in history. Clamped to `historyMaxRange`.
    static var dictationHistoryMax: Int {
        get { clampHistoryMax(d.integer(forKey: K.dictationHistoryMax)) }
        set { d.set(clampHistoryMax(newValue), forKey: K.dictationHistoryMax); notify() }
    }
    /// Max clipboard items kept in history. Clamped to `historyMaxRange`.
    static var clipboardHistoryMax: Int {
        get { clampHistoryMax(d.integer(forKey: K.clipboardHistoryMax)) }
        set { d.set(clampHistoryMax(newValue), forKey: K.clipboardHistoryMax); notify() }
    }
    private static func clampHistoryMax(_ v: Int) -> Int {
        min(historyMaxRange.upperBound, max(historyMaxRange.lowerBound, v))
    }

    /// Infinite dictation-history opt-in (L4). Read live per delivery (like the caps above), so a
    /// flip applies to the next dictation without a relaunch. When true, `DictationHistoryStore` appends
    /// every delivered transcript to its app-local per-day log; when false it writes nothing.
    static var keepFullHistory: Bool {
        get { d.bool(forKey: K.keepFullHistory) }
        set { d.set(newValue, forKey: K.keepFullHistory); notify() }
    }

    /// Keep the most recent 100 final, post-trim dictation WAVs locally. Read at the store enqueue so
    /// switching it off applies to the very next final take without a relaunch.
    static var retainDictationAudio: Bool {
        get { d.bool(forKey: K.retainDictationAudio) }
        set { d.set(newValue, forKey: K.retainDictationAudio); notify() }
    }

    /// Whether a text provider has ever been signed in on this machine. Written the first time a measurement
    /// finds one; read at launch to decide whether first-run onboarding appears at all. Not a model
    /// preference: it records what was observed, never what should run (locked decision 5).
    static var providerOnboardingSatisfied: Bool {
        get { d.bool(forKey: K.providerOnboardingSatisfied) }
        set { d.set(newValue, forKey: K.providerOnboardingSatisfied) }
    }

    // MARK: sticky notes (Option+N)

    static var defaultStickyNotesSaveDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
    }

    static func resolvedStickyNotesSaveDirectory(storedPath: String?) -> String {
        let path = storedPath ?? defaultStickyNotesSaveDirectory.path
        return path.isEmpty ? defaultStickyNotesSaveDirectory.path : path
    }

    static var stickyNotesSaveDirectory: String {
        get {
            resolvedStickyNotesSaveDirectory(storedPath: d.string(forKey: K.stickyNotesSaveDirectory))
        }
        set { d.set(newValue, forKey: K.stickyNotesSaveDirectory); notify() }
    }

    static var stickyNotesSaveDirectoryURL: URL {
        URL(fileURLWithPath: stickyNotesSaveDirectory, isDirectory: true)
    }

    static var stickyNotesRetention: StickyNotesRetention {
        get {
            let raw = d.string(forKey: K.stickyNotesRetention) ?? Defaults.stickyNotesRetention.rawValue
            return StickyNotesRetention(rawValue: raw) ?? Defaults.stickyNotesRetention
        }
        set { d.set(newValue.rawValue, forKey: K.stickyNotesRetention); notify() }
    }

    /// Whether the sticky-notes floating "i" markdown-cheat-sheet button exists (L5). The
    /// hamburger settings strip toggles this; OFF removes the button and cheat-sheet access. Writing posts
    /// `didChange`, which the notes window observes to live-apply the flag into the open web island.
    static var stickyNotesCheatSheetButton: Bool {
        get { d.bool(forKey: K.stickyNotesCheatSheetButton) }
        set { d.set(newValue, forKey: K.stickyNotesCheatSheetButton); notify() }
    }

    // MARK: input device pin

    /// The pinned input device UID, or "" to follow the macOS system default. Read live at every
    /// recorder start (`AudioRecorder.start()`), which binds the fresh engine to this device by UID.
    static var inputDeviceUID: String {
        get { d.string(forKey: K.inputDeviceUID) ?? Defaults.inputDeviceUID }
        set { d.set(newValue, forKey: K.inputDeviceUID) }
    }
    /// Display-only friendly name of the pinned device (for the picker to label one that's unplugged).
    static var inputDeviceName: String {
        get { d.string(forKey: K.inputDeviceName) ?? Defaults.inputDeviceName }
        set { d.set(newValue, forKey: K.inputDeviceName) }
    }

    // MARK: raw 0…1 control values

    static var sensitivity: Float { get { d.float(forKey: K.sensitivity) } set { setF(K.sensitivity, newValue) } }
    static var gain:        Float { get { d.float(forKey: K.gain) }        set { setF(K.gain, newValue) } }
    static var reactivity:  Float { get { d.float(forKey: K.reactivity) }  set { setF(K.reactivity, newValue) } }

    static var reduceRepeats: Bool {
        get { d.bool(forKey: K.reduceRepeats) }
        set { d.set(newValue, forKey: K.reduceRepeats); notify() }
    }

    /// The persisted checkbox setting for eligible Hotkeys rows. Stable descriptor ids keep a rebind
    /// from changing the setting; sorted writes make the stored representation deterministic.
    static var persistentToggleModeIDs: Set<String> {
        get { Set(d.stringArray(forKey: K.persistentToggleModeIDs) ?? Defaults.persistentToggleModeIDs) }
        set { d.set(newValue.sorted(), forKey: K.persistentToggleModeIDs); notify() }
    }

    static func persistentToggleEnabled(for modeID: String) -> Bool {
        persistentToggleModeIDs.contains(modeID)
    }

    static func setPersistentToggle(_ enabled: Bool, for modeID: String) {
        var ids = persistentToggleModeIDs
        if enabled {
            ids.insert(modeID)
        } else {
            ids.remove(modeID)
        }
        persistentToggleModeIDs = ids
    }

    static func resetToDefaults() {
        d.set(Defaults.sensitivity, forKey: K.sensitivity)
        d.set(Defaults.gain, forKey: K.gain)
        d.set(Defaults.reactivity, forKey: K.reactivity)
        d.set(Defaults.reduceRepeats, forKey: K.reduceRepeats)
        d.set(Defaults.retainDictationAudio, forKey: K.retainDictationAudio)
        notify()
    }

    private static func setF(_ k: String, _ v: Float) { d.set(v, forKey: k); notify() }
    private static func notify() { NotificationCenter.default.post(name: didChange, object: nil) }

    private static func positiveDouble(_ key: String, fallback: Double) -> Double {
        let value = d.double(forKey: key)
        return value > 0 ? value : fallback
    }

    private static func positiveInt(_ key: String, fallback: Int) -> Int {
        let value = d.integer(forKey: key)
        return value > 0 ? value : fallback
    }

    private static func url(_ key: String, fallback: String) -> URL {
        URL(string: d.string(forKey: key) ?? fallback) ?? URL(string: fallback)!
    }

    /// Decode a provider from a legacy scalar key. Pre-A1 `cloud` means Claude; an unknown historical
    /// value keeps the old resolver's behavior and falls back to Local instead of gaining a new route.
    private static func migratedProvider(forKey key: String, fallback: String) -> LLMProvider {
        let raw = d.string(forKey: key) ?? fallback
        let provider = LLMProvider.decodeStored(raw) ?? .local
        if raw == "cloud" { d.set(provider.rawValue, forKey: key) }
        return provider
    }

    // MARK: derived audio-meter parameters

    /// Noise floor in dBFS. More-negative floor = livelier meter (a given speech level reads higher
    /// and quieter sounds register). Maps sensitivity 0…1 to [-30 … -72] dB.
    static var floorDb: Float { -30 - sensitivity * 42 }

    /// Pre-log linear gain for a quiet mic. Maps gain 0…1 to [0.7 … 4.0]×.
    static var linearGain: Float { 0.7 + gain * 3.3 }

    // MARK: transcription

    /// The dictation app's request preference. `reduceRepeats` on = hallucination reduction on
    /// (daemon runs with condition_on_previous_text off + output cleanup).
    static var conditionOnPreviousText: Bool { !reduceRepeats }
    static var cleanTranscript: Bool { reduceRepeats }

    // MARK: cleanup mode (post-processing layer)

    static var cleanupModel: String { d.string(forKey: K.cleanupModel) ?? Defaults.cleanupModel }

    /// Cleanup strength level (0…2), remembered across launches; applied only when the toggle is on.
    static var cleanupLevel: Int {
        get { min(2, max(0, d.integer(forKey: K.cleanupLevel))) }
        set { d.set(min(2, max(0, newValue)), forKey: K.cleanupLevel) }
    }

    /// Option+P prompt-prep sticky level (0…2). Independent of `cleanupLevel`; default Tighten (1).
    static var promptPrepLevel: Int {
        get { min(2, max(0, d.integer(forKey: K.promptPrepLevel))) }
        set { d.set(min(2, max(0, newValue)), forKey: K.promptPrepLevel) }
    }

    /// Option+P's last-used Local model id. Provider migration never overwrites this scalar, so switching
    /// from legacy `cloud` to typed Claude and back preserves the user's Local choice.
    static var promptPrepModel: String {
        get { d.string(forKey: K.promptPrepModel) ?? Defaults.promptPrepModel }
        set { d.set(newValue, forKey: K.promptPrepModel) }
    }
    /// Typed provider. A stored pre-A1 `cloud` value is atomically canonicalized to `claude` on read.
    static var promptPrepProvider: LLMProvider {
        get { migratedProvider(forKey: K.promptPrepModelKind, fallback: Defaults.promptPrepModelKind) }
        set { d.set(newValue.rawValue, forKey: K.promptPrepModelKind) }
    }
    /// Option+P's execution-time route resolution: its Models & Power pin when that provider is available,
    /// else the highest-preference available provider, else off. The scalar fallback exists only for pre-A4
    /// Local/Claude preferences; route-specific Codex choices never pass through that legacy representation.
    static var promptPrepRouteResolution: LLMRouteResolution {
        modelsPower.resolveRoute(
            .promptPrep,
            fallback: ModeModelCatalog.legacySelection(
                provider: promptPrepProvider, localId: promptPrepModel))
    }

    /// The system prompt for a strength level (user override, else the built-in default). Each is a
    /// tuning surface; the defaults are the qwen-verified ladder (see v2-strength-slider-spec.md).
    static func cleanupPrompt(_ level: CleanupLevel) -> String {
        switch level {
        case .cleanup:   return d.string(forKey: K.cleanupSystemPrompt) ?? firmCleanupPrompt
        case .tighten:   return d.string(forKey: K.cleanupPromptL1) ?? tightenCleanupPrompt
        case .summarize: return d.string(forKey: K.cleanupPromptL2) ?? summarizeCleanupPrompt
        }
    }

    static var cleanupTimeout: TimeInterval {
        positiveDouble(K.cleanupTimeout, fallback: Defaults.cleanupTimeout)
    }
    static func timeout(local: TimeInterval, provider: LLMProvider) -> TimeInterval {
        provider == .local ? local : CloudCleanupClient.defaultTimeout
    }
    static var cleanupTemperature: Double { d.double(forKey: K.cleanupTemperature) }
    static var cleanupEndpoint: URL {
        url(K.cleanupEndpoint, fallback: Defaults.cleanupEndpoint)
    }

    // MARK: email mode (Option+M)

    /// Option+M's LOCAL model id (the Models & Power Email row edits it). Get + set — the row writes the chosen
    /// local model here; default = gemma, so the migrated M row is behavior-identical until the user changes it.
    /// Always a Local id (safe for `EmailClient` + `localModels`); typed provider ownership is separate.
    static var emailModel: String {
        get { d.string(forKey: K.emailModel) ?? Defaults.emailModel }
        set { d.set(newValue, forKey: K.emailModel) }
    }
    /// Typed provider. A stored pre-A1 `cloud` value is atomically canonicalized to `claude` on read.
    static var emailProvider: LLMProvider {
        get { migratedProvider(forKey: K.emailModelKind, fallback: Defaults.emailModelKind) }
        set { d.set(newValue.rawValue, forKey: K.emailModelKind) }
    }
    /// Option+M's execution-time route resolution, on the same contract as `promptPrepRouteResolution`.
    /// The scalar fallback exists only for pre-A4 Local/Claude preferences; route-specific Codex choices
    /// never pass through that legacy representation.
    static var emailRouteResolution: LLMRouteResolution {
        modelsPower.resolveRoute(
            .email,
            fallback: ModeModelCatalog.legacySelection(
                provider: emailProvider, localId: emailModel))
    }
    /// Option+M's legacy provider-neutral system prompt. A4 migrates any customization into independent
    /// Models & Power provider arms; this accessor remains the exact tested fallback and migration source.
    static var emailSystemPrompt: String {
        get {
            let s = d.string(forKey: K.emailSystemPrompt) ?? defaultEmailSystemPrompt
            return s.isEmpty ? defaultEmailSystemPrompt : s
        }
        set { d.set(newValue, forKey: K.emailSystemPrompt) }
    }
    static var emailTemperature: Double { d.double(forKey: K.emailTemperature) }
    static var emailMaxTokens: Int {
        positiveInt(K.emailMaxTokens, fallback: Defaults.emailMaxTokens)
    }
    static var emailTimeout: TimeInterval {
        positiveDouble(K.emailTimeout, fallback: Defaults.emailTimeout)
    }
    static var emailEndpoint: URL {
        url(K.emailEndpoint, fallback: Defaults.emailEndpoint)
    }

    // MARK: web-search modes (Option+L local / Option+G Gemini)

    static var searchModel: String { d.string(forKey: K.searchModel) ?? Defaults.searchModel }
    static var searchSynthModel: String { d.string(forKey: K.searchSynthModel) ?? Defaults.searchSynthModel }
    static var searchSynthPrompt: String { d.string(forKey: K.searchSynthPrompt) ?? defaultSearchSynthPrompt }
    static var searchAgenticPrompt: String { d.string(forKey: K.searchAgenticPrompt) ?? defaultSearchAgenticPrompt }
    static var searchTimeout: TimeInterval {
        positiveDouble(K.searchTimeout, fallback: Defaults.searchTimeout)
    }
    static var searchSynthMaxTokens: Int {
        positiveInt(K.searchSynthMaxTokens, fallback: Defaults.searchSynthMaxTokens)
    }
    static var searchRetrievalMaxTokens: Int {
        positiveInt(K.searchRetrievalMaxTokens, fallback: Defaults.searchRetrievalMaxTokens)
    }
    static var searchMaxSearches: Int {
        positiveInt(K.searchMaxSearches, fallback: Defaults.searchMaxSearches)
    }
    static var searchEndpoint: URL {
        url(K.searchEndpoint, fallback: Defaults.searchEndpoint)
    }
    static var geminiModel: String { d.string(forKey: K.geminiModel) ?? Defaults.geminiModel }
}
