import Foundation

/// D11 (decided 2026-09-30): every built-in default, on every provider and local app, reads as a **Staff pick**.
/// "Here is what we would use", not a quality gate, so the app reads as something each user can customize.
///
/// This is the ONE home for that vocabulary on screen. Ratification stays internal: `LLMRatificationProvenance`,
/// `LLMAutoUpdateProvenance`, the derived `LLMRatificationState` and ADR 0014's retirement migration are
/// untouched, and nothing below changes a persisted key or a Codable raw value. Only the words change.
///
/// The badge rule, one for every route on every provider:
/// - **STAFF PICK** when what runs is a built-in default: a bundle carrying the app's own provenance (ratified
///   for the model it runs, or an auto-updated replacement of a ratified default), or the route's default model
///   and effort for its provider and app (a Local arm on LM Studio or Ollama, an unratified default, or a 1.0
///   bundle stored before provenance existed).
/// - **CUSTOM** when the user picked the model or the effort.
/// - A prompt edit never changes the badge word; it appends " - custom prompt", so the row still answers
///   "is my prompt what runs?" without an evidence word.
enum StaffPicks {
    /// The prompt state label and the pickers' qualifier for the built-in default row.
    static let label = "Staff pick"
    /// The prompt state label for a user's own prompt. Unchanged by D11.
    static let customizedLabel = "Customized"
    /// The preset line's badge words.
    static let badgeWord = "STAFF PICK"
    static let customBadgeWord = "CUSTOM"
    /// Appended to the preset line while any of the route's prompts is the user's own.
    static let customPromptNote = "custom prompt"

    /// The routing grid's qualifiers, with the grid's own wide-spaced middle dot.
    static let gridQualifier = "  ·  " + label
    static let gridCustomQualifier = "  ·  Custom"
    /// The Sticky Skill cards' qualifier for the appended default row.
    static let stickyQualifier = " - " + label

    /// Models & Power (Hotkeys tab): the global control beside the per-provider buttons.
    static let globalControlTitle = "Set every route to its staff pick:"
    static let codexGlobalToolTip = "Uses Codex's staff pick on all eight routes."
    /// The prompt editor's Restore button, and the editor subtitle that names it.
    static let restorePromptTitle = "Restore staff pick"
    static let customizedPromptSubtitle = "Customized. Restore staff pick, then Save, clears your override."
    static let staffPickPromptSubtitle = "This is the staff pick's prompt. Saving an edit marks it customized."

    /// The Codex catalog line (Hotkeys tab status and the update toast) after a migration moved routes.
    static let codexMigratedStatus = "Codex routes migrated to new staff picks"
    /// The cloud preset toast's suffix for a route the app moved to a new model.
    static let newStaffPickSuffix = "(new staff pick)"

    static func promptStateLabel(_ state: LLMPromptCustomizationState) -> String {
        switch state {
        case .testedDefault: return label
        case .customized: return customizedLabel
        }
    }

    /// The route's prompt summary ("Prompt: Staff pick" / "Prompt: Customized").
    static func promptSummary(customized: Bool) -> String {
        "Prompt: \(customized ? customizedLabel : label)"
    }

    /// A provider popup suffix when the route group has no default, or only some of its routes do.
    static func providerCoverageSuffix(defaults: Int, of routes: Int) -> String {
        if defaults == 0 { return " · No staff pick" }
        if defaults < routes { return " · \(defaults)/\(routes) staff picks" }
        return ""
    }

    // MARK: - Which bundle is a staff pick

    /// The local app's own id for a route's Local default. LM Studio's is the route's tested id; Ollama's is the
    /// same model family by Ollama's tag (D4: same families on both apps). nil when that app has no pick for it.
    static func localModelID(forLMStudioDefault lmStudioID: String, on backend: LocalBackendID) -> String? {
        switch backend {
        case .lmStudio:
            return lmStudioID
        case .ollama:
            switch lmStudioID {
            case LLMProviderDefaults.localCleanupModelID: return BootstrapInstallPlan.ollamaCleanupModelID
            case LLMProviderDefaults.localEmailModelID: return BootstrapInstallPlan.ollamaEmailModelID
            default: return nil
            }
        }
    }

    /// Every local app's copy of the route's Local default, given that route's tested Local bundle (LM Studio's,
    /// `LLMProviderDefaults.testedBundle(for: .local, route:)`).
    static func localRefs(tested: LLMProviderBundle?) -> Set<LocalModelRef> {
        guard let tested, tested.provider == .local, !tested.modelID.isEmpty else { return [] }
        return Set(LocalBackendID.allCases.compactMap { backend in
            localModelID(forLMStudioDefault: tested.modelID, on: backend)
                .map { LocalModelRef(backend: backend, modelID: $0) }
        })
    }

    static func isStaffPick(_ bundle: LLMProviderBundle, route: LLMRouteID) -> Bool {
        // The app's own provenance: a ratified default still on the model its evidence names, or a migration's
        // replacement of one (the migration keeps the superseded ratification as history and stamps
        // `autoUpdated`). The pickers drop both fields when the user changes the model or the effort; evidence
        // naming another model with no migration stamp is not the app's pick, so it falls through.
        if let evidence = bundle.ratified,
           evidence.modelID == bundle.modelID || bundle.autoUpdated != nil {
            return true
        }
        guard let shipped = LLMProviderDefaults.testedBundle(for: bundle.provider, route: route) else {
            return false
        }
        switch bundle.provider {
        case .local:
            return localRefs(tested: shipped).contains(bundle.localRef)
        case .claude, .codex:
            return bundle.modelID == shipped.modelID && bundle.effort == shipped.effort
        }
    }

    // MARK: - Untouched Local routes follow the Preferred local app (D1)

    /// Whether a Local bundle is the route's UNTOUCHED staff pick, the one state that follows the Preferred
    /// local app. It is a staff pick by the rule above, in the store's one spelling for "on the staff pick",
    /// which predates backends: the tested Local bundle, LM Studio's id with NO `localBackend` key. Seeding,
    /// "Set every route to its staff pick", Restore and a never-used provider all write exactly that, and so
    /// does picking the staff pick that runs now (`LocalModelPickerItems.applying`).
    ///
    /// Anything else is the user's choice and keeps its exact (app, model): another id, or a bundle that names
    /// its app. That includes Ollama's own staff pick picked by name, and LM Studio's spelled out
    /// (`localBackend: lmStudio`), which is how a pick of LM Studio's copy is stored while another app is
    /// preferred. Nothing new is stored to tell the two apart.
    static func followsPreferredApp(_ bundle: LLMProviderBundle, route: LLMRouteID) -> Bool {
        guard bundle.provider == .local, bundle.localBackend == nil,
              let lmStudioPick = LLMProviderDefaults.testedLocalBundle(for: route, on: .lmStudio) else {
            return false
        }
        return bundle.modelID == lmStudioPick.modelID && isStaffPick(bundle, route: route)
    }

    /// What `bundle` runs on this Mac when `preferred` is the effective Preferred local app
    /// (`LocalBackendPreference.effective`): an untouched route runs that app's staff pick for the route; every
    /// other bundle is returned unchanged. Read-only: storage is never rewritten, so a later switch of the
    /// Preferred app moves the route again. With LM Studio preferred the pick IS the stored bundle, so an
    /// LM-Studio Mac gets its bundle back unchanged, byte for byte. D2's cross-app step-down still applies
    /// after this, when the pick does not fit or its app is down.
    static func followingPreferredApp(_ bundle: LLMProviderBundle, route: LLMRouteID,
                                      preferred: LocalBackendID) -> LLMProviderBundle {
        guard followsPreferredApp(bundle, route: route),
              let pick = LLMProviderDefaults.testedLocalBundle(for: route, on: preferred) else { return bundle }
        var out = bundle
        out.modelID = pick.modelID
        out.localBackend = pick.localBackend
        return out
    }

    /// The preset badge: "STAFF PICK <model>" or "CUSTOM <model>".
    static func badge(bundle: LLMProviderBundle, route: LLMRouteID) -> String {
        "\(isStaffPick(bundle, route: route) ? badgeWord : customBadgeWord) \(bundle.modelID)"
    }

    /// The preset line as the user reads it: the badge, plus the custom-prompt note when the store's derived
    /// verdict says a prompt edit replaced what ships. That verdict is the authority on the prompt, which the
    /// bundle alone cannot see; its other reasons are evidence bookkeeping and stay internal.
    static func provenanceRow(bundle: LLMProviderBundle, route: LLMRouteID,
                              ratification: LLMRatificationState) -> String {
        let badge = badge(bundle: bundle, route: route)
        guard ratification.hasReason(.promptOverridden) else { return badge }
        return "\(badge) - \(customPromptNote)"
    }
}
