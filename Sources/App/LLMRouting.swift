import Foundation

/// The closed provider identity set for ViddyDictate text transforms. Persisted `cloud` values from the
/// pre-A1 model are accepted only as a migration alias for `.claude`; all new writes use these explicit
/// provider identities. Codex defaults exist only for routes ratified through the sealed D1 and rescue
/// bakeoffs; a nil tested bundle is never an invitation to substitute another provider or model.
enum LLMProvider: String, Codable, CaseIterable {
    case local
    case claude
    case codex

    static func decodeStored(_ raw: String) -> LLMProvider? {
        raw == "cloud" ? .claude : LLMProvider(rawValue: raw)
    }

    /// How this provider is NAMED to the user inside ViddyDictate. One owner, because the name now
    /// appears in two very different places — the Models & Power settings grid and a run's own
    /// "what actually executed" report — and those two must never disagree about what "Codex" is
    /// called. Distinct from `ProviderOnboarding.productName`, which names the thing to go install.
    var displayName: String {
        switch self {
        case .local: return "Local"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// Stable identity for every LLM job. Built-in raw values intentionally preserve the legacy route keys
/// byte-for-byte. A custom hotkey is namespaced by its durable CustomMode UUID, never by its
/// mutable chord or name.
enum LLMRouteID: Hashable, Codable, RawRepresentable {
    case cleanupL1
    case cleanupL2
    case cleanupL3
    case promptPrep
    case email
    case searchLocalSynth
    case searchGeminiSynth
    case custom(String)

    static let builtIns: [LLMRouteID] = [
        .cleanupL1, .cleanupL2, .cleanupL3, .promptPrep, .email,
        .searchLocalSynth, .searchGeminiSynth,
    ]

    static let cleanupRoutes: [LLMRouteID] = [.cleanupL1, .cleanupL2, .cleanupL3]

    static func cleanupRoute(for level: CleanupLevel) -> LLMRouteID {
        switch level {
        case .cleanup:   return .cleanupL1
        case .tighten:   return .cleanupL2
        case .summarize: return .cleanupL3
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "cleanupL1":         self = .cleanupL1
        case "cleanupL2":         self = .cleanupL2
        case "cleanupL3":         self = .cleanupL3
        case "promptPrep":        self = .promptPrep
        case "email":             self = .email
        case "searchLocalSynth":  self = .searchLocalSynth
        case "searchGeminiSynth": self = .searchGeminiSynth
        default:
            let prefix = "custom:"
            guard rawValue.hasPrefix(prefix), rawValue.count > prefix.count else { return nil }
            self = .custom(String(rawValue.dropFirst(prefix.count)))
        }
    }

    var rawValue: String {
        switch self {
        case .cleanupL1:         return "cleanupL1"
        case .cleanupL2:         return "cleanupL2"
        case .cleanupL3:         return "cleanupL3"
        case .promptPrep:        return "promptPrep"
        case .email:             return "email"
        case .searchLocalSynth:  return "searchLocalSynth"
        case .searchGeminiSynth: return "searchGeminiSynth"
        case .custom(let id):    return "custom:\(id)"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = LLMRouteID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unsupported LLM route id: \(raw)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct LLMRatificationProvenance: Equatable, Codable {
    var modelID: String
    var date: String
    var evidence: String
}

enum LLMAutoUpdateReason: String, Equatable, Codable {
    case deprecation
    case freshness
}

struct LLMAutoUpdateProvenance: Equatable, Codable {
    var fromModelID: String
    var date: String
    var reason: LLMAutoUpdateReason
}

/// Versioned provider/model/effort choice. A4's version 2 added the complete tested-default identity
/// needed by Restore: the base-prompt version/hash and the provider envelope version. Those fields are
/// descriptive routing metadata; request call sites still pass the exact effective prompt explicitly,
/// so adding them cannot change the shipped Local/Claude prompt bytes.
/// L6 extends that same schema with optional ratification and auto-update provenance. Old stored bundles
/// decode with both fields nil, preserving their exact bundle and making no retroactive ratification claim.
///
/// The decoder accepts both pre-A1 persisted shapes:
/// - custom/P/M model choice: `{kind:"local|cloud", id:"..."}`
/// - legacy Low Power Claude arm: `{model:"...", effort:"..."}`
/// New writes are canonical `{version, provider, modelID, effort?, basePromptVersion?,
/// basePromptHash?, envelopeVersion?, ratified?, autoUpdated?}` bundles.
struct LLMProviderBundle: Equatable, Codable {
    static let currentVersion = 2

    var version: Int
    var provider: LLMProvider
    var modelID: String
    var effort: String?
    var basePromptVersion: String?
    var basePromptHash: String?
    var envelopeVersion: String?
    var ratified: LLMRatificationProvenance?
    var autoUpdated: LLMAutoUpdateProvenance?

    init(version: Int = currentVersion, provider: LLMProvider, modelID: String, effort: String? = nil,
         basePromptVersion: String? = nil, basePromptHash: String? = nil,
         envelopeVersion: String? = nil, ratified: LLMRatificationProvenance? = nil,
         autoUpdated: LLMAutoUpdateProvenance? = nil) {
        self.version = version
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
        self.basePromptVersion = basePromptVersion
        self.basePromptHash = basePromptHash
        self.envelopeVersion = envelopeVersion
        self.ratified = ratified
        self.autoUpdated = autoUpdated
    }

    static func local(_ id: String) -> LLMProviderBundle {
        LLMProviderBundle(provider: .local, modelID: id)
    }

    static func claude(_ id: String, effort: String? = nil) -> LLMProviderBundle {
        LLMProviderBundle(provider: .claude, modelID: id, effort: effort)
    }

    static func codex(_ id: String, effort: String? = nil) -> LLMProviderBundle {
        LLMProviderBundle(provider: .codex, modelID: id, effort: effort)
    }

    /// Compatibility spelling for the UI/dispatch code that historically called the model id `id`.
    var id: String { modelID }
    var isLocal: Bool { provider == .local }

    private enum CodingKeys: String, CodingKey {
        case version, provider, modelID, effort
        case basePromptVersion, basePromptHash, envelopeVersion
        case ratified, autoUpdated
        case kind, id       // pre-A1 ModeModel
        case model          // pre-A1 LowPowerPolicy.CloudArm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        basePromptVersion = try c.decodeIfPresent(String.self, forKey: .basePromptVersion)
        basePromptHash = try c.decodeIfPresent(String.self, forKey: .basePromptHash)
        envelopeVersion = try c.decodeIfPresent(String.self, forKey: .envelopeVersion)
        ratified = try c.decodeIfPresent(LLMRatificationProvenance.self, forKey: .ratified)
        autoUpdated = try c.decodeIfPresent(LLMAutoUpdateProvenance.self, forKey: .autoUpdated)

        if let rawProvider = try c.decodeIfPresent(String.self, forKey: .provider),
           let decodedProvider = LLMProvider.decodeStored(rawProvider) {
            provider = decodedProvider
            modelID = try c.decode(String.self, forKey: .modelID)
            return
        }

        if let legacyKind = try c.decodeIfPresent(String.self, forKey: .kind),
           let decodedProvider = LLMProvider.decodeStored(legacyKind) {
            provider = decodedProvider
            modelID = try c.decode(String.self, forKey: .id)
            return
        }

        if let legacyModel = try c.decodeIfPresent(String.self, forKey: .model) {
            provider = .claude
            modelID = legacyModel
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .provider, in: c,
            debugDescription: "Provider bundle has no supported provider/legacy discriminator")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(provider.rawValue, forKey: .provider)
        try c.encode(modelID, forKey: .modelID)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(basePromptVersion, forKey: .basePromptVersion)
        try c.encodeIfPresent(basePromptHash, forKey: .basePromptHash)
        try c.encodeIfPresent(envelopeVersion, forKey: .envelopeVersion)
        try c.encodeIfPresent(ratified, forKey: .ratified)
        try c.encodeIfPresent(autoUpdated, forKey: .autoUpdated)
    }
}

/// Compatibility name retained for the current Hotkeys UI and CustomMode descriptor. Its underlying
/// representation is now the typed, versioned provider bundle above.
typealias ModeModel = LLMProviderBundle

/// The single home for Local, Claude, and shipped Codex defaults. Sealed evidence remains attached to
/// the model it actually covered; a migrated replacement is explicitly auto-updated and unratified.
enum LLMProviderDefaults {
    static let localCleanupModelID = "qwen3-coder-30b-a3b-instruct-mlx"
    static let localEmailModelID = "google/gemma-4-e4b"
    static let localSearchSynthesisModelID = "google/gemma-4-e4b"

    static let claudeSonnetModelID = "claude-sonnet-5"
    static let claudeHaikuModelID = "claude-haiku-4-5-20251001"
    static let claudeRatificationDate = "2026-07-07"
    static let claudeRatificationEvidence =
        "low-power bakeoff 20260706 + cleanupL3 revision 949aeaa 20260707"
    static let codexRatificationDate = "2026-07-14"
    static let codexRatificationEvidence = "sealed bakeoffs 20260714"
    static let retiredCleanupL1CodexModelID = "gpt-5.4-mini"
    static let cleanupL1CodexModelID = CodexShippedDefaults.lunaLow.model
    static let cleanupL1CodexAutoUpdateDate = "2026-07-27"

    /// Sealed BAKEOFF-GATE identity. Keep this literal independent from the runtime foundation constant:
    /// deterministic coverage must fail if either side drifts without a new ratification/migration.
    static let ratifiedCodexEnvelopeVersion = "viddydictate-transform-v1"

    /// The existing explicit Claude dropdown choice. It intentionally carries no effort, preserving the
    /// current `claude -p` argv exactly; route-specific Claude arms live in `testedBundle` below.
    static let currentClaudeSelection = ratifiedClaude(claudeSonnetModelID)

    private static func ratifiedClaude(_ id: String, effort: String? = nil) -> LLMProviderBundle {
        LLMProviderBundle(
            provider: .claude, modelID: id, effort: effort,
            ratified: LLMRatificationProvenance(
                modelID: id, date: claudeRatificationDate, evidence: claudeRatificationEvidence))
    }

    private static func ratifiedCodex(_ id: String, effort: String? = nil) -> LLMProviderBundle {
        LLMProviderBundle(
            provider: .codex, modelID: id, effort: effort,
            ratified: LLMRatificationProvenance(
                modelID: id, date: codexRatificationDate, evidence: codexRatificationEvidence))
    }

    /// Cleanup L1's original bakeoff evidence belongs to the retired model, not its replacement.
    /// Keeping that record as superseded history makes the shipped replacement visibly unratified.
    private static func migratedCleanupL1Codex() -> LLMProviderBundle {
        LLMProviderBundle(
            provider: .codex,
            modelID: cleanupL1CodexModelID,
            effort: CodexShippedDefaults.lunaLow.effort,
            ratified: LLMRatificationProvenance(
                modelID: retiredCleanupL1CodexModelID,
                date: codexRatificationDate,
                evidence: codexRatificationEvidence),
            autoUpdated: LLMAutoUpdateProvenance(
                fromModelID: retiredCleanupL1CodexModelID,
                date: cleanupL1CodexAutoUpdateDate,
                reason: .deprecation))
    }

    private enum TestedPromptRecipe {
        case single(String)
        case cleanupLadder

        func prompt(for variant: LLMPromptVariant) -> String {
            switch self {
            case .single(let prompt):
                return prompt
            case .cleanupLadder:
                switch variant {
                case .cleanupL1, .primary: return firmCleanupPrompt
                case .cleanupL2: return tightenCleanupPrompt
                case .cleanupL3: return summarizeCleanupPrompt
                }
            }
        }
    }

    /// Every route configures every provider so execution never invents a missing provider default.
    private struct RouteConfig {
        let basePromptVersion: String
        let basePromptBytes: Data
        let testedPromptRecipe: TestedPromptRecipe
        let localModelID: String
        let claudeBundle: LLMProviderBundle
        let codexBundle: LLMProviderBundle
        let envelopeShape: String
        let ratifiedCodexPromptIdentity: (version: String, hash: String)?
        let ratifiedCodexPromptVariant: CodexRatifiedPromptVariant?

        init(basePromptVersion: String, basePromptIdentityText: String,
             testedPromptRecipe: TestedPromptRecipe, localModelID: String,
             claudeBundle: LLMProviderBundle, codexBundle: LLMProviderBundle,
             envelopeShape: String,
             ratifiedCodexPromptIdentity: (version: String, hash: String)?,
             ratifiedCodexPromptVariant: CodexRatifiedPromptVariant? = nil) {
            self.basePromptVersion = basePromptVersion
            basePromptBytes = Data(basePromptIdentityText.utf8)
            self.testedPromptRecipe = testedPromptRecipe
            self.localModelID = localModelID
            self.claudeBundle = claudeBundle
            self.codexBundle = codexBundle
            self.envelopeShape = envelopeShape
            self.ratifiedCodexPromptIdentity = ratifiedCodexPromptIdentity
            self.ratifiedCodexPromptVariant = ratifiedCodexPromptVariant
        }
    }

    /// One registry owns every built-in route's tested model, effort, prompt, and envelope identity.
    /// Custom routes use the same shape through the explicit residual config below; their user prompt
    /// remains provider-neutral data and is never stored here.
    private static let builtInRouteConfigs: [LLMRouteID: RouteConfig] = [
        .cleanupL1: RouteConfig(
            basePromptVersion: "cleanup-l1-v1", basePromptIdentityText: firmCleanupPrompt,
            testedPromptRecipe: .single(firmCleanupPrompt), localModelID: localCleanupModelID,
            claudeBundle: ratifiedClaude(claudeSonnetModelID, effort: "medium"),
            codexBundle: migratedCleanupL1Codex(),
            envelopeShape: "transcript-markers",
            ratifiedCodexPromptIdentity: (
                "cleanup-l1-v1", "e65dcaab45927d5eecb5c08e1bc6d26114cb462e1a6ef61edb52ae04e7809334")),
        .cleanupL2: RouteConfig(
            basePromptVersion: "cleanup-l2-v1", basePromptIdentityText: tightenCleanupPrompt,
            testedPromptRecipe: .single(tightenCleanupPrompt), localModelID: localCleanupModelID,
            claudeBundle: ratifiedClaude(claudeSonnetModelID, effort: "medium"),
            codexBundle: ratifiedCodex(
                CodexShippedDefaults.legacyCleanupL2Medium.model,
                effort: CodexShippedDefaults.legacyCleanupL2Medium.effort),
            envelopeShape: "transcript-markers",
            ratifiedCodexPromptIdentity: (
                "cleanup-l2-v1", "a648ee725f01bdbbf60e8cd9676a2254664eff2d14ab0a8afa806952a8f021c8")),
        .cleanupL3: RouteConfig(
            basePromptVersion: "cleanup-l3-v1", basePromptIdentityText: summarizeCleanupPrompt,
            testedPromptRecipe: .single(summarizeCleanupPrompt), localModelID: localCleanupModelID,
            claudeBundle: ratifiedClaude(claudeSonnetModelID, effort: "medium"),
            codexBundle: ratifiedCodex(
                CodexShippedDefaults.lunaLow.model,
                effort: CodexShippedDefaults.lunaLow.effort),
            envelopeShape: "transcript-markers",
            ratifiedCodexPromptIdentity: (
                CodexRatifiedPromptDefaults.cleanupL3.id,
                CodexRatifiedPromptDefaults.cleanupL3.contentHash),
            ratifiedCodexPromptVariant: CodexRatifiedPromptDefaults.cleanupL3),
        .promptPrep: RouteConfig(
            basePromptVersion: "prompt-prep-cleanup-ladder-v1",
            basePromptIdentityText: [firmCleanupPrompt, tightenCleanupPrompt, summarizeCleanupPrompt]
                .joined(separator: "\n\u{0}\n"),
            testedPromptRecipe: .cleanupLadder, localModelID: localCleanupModelID,
            claudeBundle: ratifiedClaude(claudeSonnetModelID, effort: "medium"),
            codexBundle: ratifiedCodex(
                CodexShippedDefaults.solMedium.model,
                effort: CodexShippedDefaults.solMedium.effort),
            envelopeShape: "transcript-markers",
            ratifiedCodexPromptIdentity: (
                CodexRatifiedPromptDefaults.promptPrep.id,
                CodexRatifiedPromptDefaults.promptPrep.contentHash),
            ratifiedCodexPromptVariant: CodexRatifiedPromptDefaults.promptPrep),
        .email: RouteConfig(
            basePromptVersion: "email-v1", basePromptIdentityText: defaultEmailSystemPrompt,
            testedPromptRecipe: .single(defaultEmailSystemPrompt), localModelID: localEmailModelID,
            claudeBundle: ratifiedClaude(claudeSonnetModelID, effort: "medium"),
            codexBundle: ratifiedCodex(
                CodexShippedDefaults.lunaLow.model,
                effort: CodexShippedDefaults.lunaLow.effort),
            envelopeShape: "email-notes-markers",
            ratifiedCodexPromptIdentity: (
                CodexRatifiedPromptDefaults.email.id,
                CodexRatifiedPromptDefaults.email.contentHash),
            ratifiedCodexPromptVariant: CodexRatifiedPromptDefaults.email),
        .searchLocalSynth: RouteConfig(
            basePromptVersion: "search-synthesis-v1",
            basePromptIdentityText: defaultSearchSynthPrompt,
            testedPromptRecipe: .single(defaultSearchSynthPrompt),
            localModelID: localSearchSynthesisModelID,
            claudeBundle: ratifiedClaude(claudeHaikuModelID, effort: "high"),
            codexBundle: ratifiedCodex(
                CodexShippedDefaults.lunaLow.model,
                effort: CodexShippedDefaults.lunaLow.effort),
            envelopeShape: "search-question-results",
            ratifiedCodexPromptIdentity: (
                "search-synthesis-v1", "ae106bbe1ac41a6a1d59496f17d1b81e2ea8caa35b66cf738313ad09273a7262")),
        .searchGeminiSynth: RouteConfig(
            basePromptVersion: "search-synthesis-v1",
            basePromptIdentityText: defaultSearchSynthPrompt,
            testedPromptRecipe: .single(defaultSearchSynthPrompt),
            localModelID: localSearchSynthesisModelID,
            claudeBundle: ratifiedClaude(claudeHaikuModelID, effort: "medium"),
            codexBundle: ratifiedCodex(
                CodexShippedDefaults.lunaLow.model,
                effort: CodexShippedDefaults.lunaLow.effort),
            envelopeShape: "search-question-results",
            ratifiedCodexPromptIdentity: (
                "search-synthesis-v1", "ae106bbe1ac41a6a1d59496f17d1b81e2ea8caa35b66cf738313ad09273a7262")),
    ]

    private static let customRouteConfig = RouteConfig(
        basePromptVersion: "custom-shared-task-v1",
        basePromptIdentityText: "viddydictate-custom-shared-task-prompt",
        testedPromptRecipe: .single(""), localModelID: localCleanupModelID,
        claudeBundle: ratifiedClaude(claudeSonnetModelID, effort: "high"),
        codexBundle: ratifiedCodex(
            CodexShippedDefaults.terraLow.model,
            effort: CodexShippedDefaults.terraLow.effort),
        envelopeShape: "transcript-markers",
        ratifiedCodexPromptIdentity: (
            "custom-shared-task-v1", "58967a6a5a0da7a53d50a4807a40f99d09d9d48b42d93ad3ea2905ac74662cad"))

    private static func routeConfig(for route: LLMRouteID) -> RouteConfig {
        if case .custom = route { return customRouteConfig }
        guard let config = builtInRouteConfigs[route] else {
            preconditionFailure("Missing tested route config for \(route.rawValue)")
        }
        return config
    }

    private static func basePromptIdentity(for route: LLMRouteID) -> (version: String, hash: String) {
        let config = routeConfig(for: route)
        return (config.basePromptVersion, CodexIsolationFoundation.sha256Hex(config.basePromptBytes))
    }

    /// Prompt identities ratified with the D1 and I1 model/effort slates. The original five D1 hashes
    /// exclude the dynamic glossary. The three rescue hashes are the exact sealed variant-content hashes;
    /// production rebuilds their prompt recipe with the live glossary without changing this identity.
    /// Custom routes pin the shared-task contract marker, not user prompt text.
    private static func ratifiedCodexPromptIdentity(
        for route: LLMRouteID
    ) -> (version: String, hash: String)? {
        routeConfig(for: route).ratifiedCodexPromptIdentity
    }

    static func ratifiedCodexPromptVariant(for route: LLMRouteID) -> CodexRatifiedPromptVariant? {
        routeConfig(for: route).ratifiedCodexPromptVariant
    }

    static func testedPrompt(for route: LLMRouteID, provider: LLMProvider,
                             variant: LLMPromptVariant) -> String {
        let config = routeConfig(for: route)
        if provider == .codex, let ratified = config.ratifiedCodexPromptVariant {
            return ratified.promptWithoutGlossary
        }
        return config.testedPromptRecipe.prompt(for: variant)
    }

    private static func envelopeVersion(for provider: LLMProvider, route: LLMRouteID) -> String? {
        if provider == .codex { return ratifiedCodexEnvelopeVersion }
        return "\(provider.rawValue)-\(routeConfig(for: route).envelopeShape)-v1"
    }

    /// Attach the route's complete tested prompt/envelope identity without changing model or effort.
    /// Custom selections use the same helper so Restore can be complete while leaving their shared task
    /// prompt untouched.
    static func withTestedMetadata(_ bundle: LLMProviderBundle, route: LLMRouteID) -> LLMProviderBundle {
        let prompt = bundle.provider == .codex
            ? (ratifiedCodexPromptIdentity(for: route) ?? basePromptIdentity(for: route))
            : basePromptIdentity(for: route)
        var out = bundle
        out.version = LLMProviderBundle.currentVersion
        out.basePromptVersion = prompt.version
        out.basePromptHash = prompt.hash
        out.envelopeVersion = envelopeVersion(for: bundle.provider, route: route)
        return out
    }

    /// The one shipped default retired before this schema version is migrated only in the route where
    /// it was formerly seeded. Arbitrary custom identifiers and every other route remain untouched.
    static func replacingRetiredShippedDefault(
        _ bundle: LLMProviderBundle,
        route: LLMRouteID
    ) -> LLMProviderBundle {
        guard route == .cleanupL1,
              bundle.provider == .codex,
              bundle.modelID == retiredCleanupL1CodexModelID else {
            return bundle
        }
        return migratedCleanupL1Codex()
    }

    static func testedBundle(for provider: LLMProvider, route: LLMRouteID) -> LLMProviderBundle? {
        let config = routeConfig(for: route)
        let bundle: LLMProviderBundle
        switch provider {
        case .local:
            bundle = .local(config.localModelID)
        case .claude:
            bundle = config.claudeBundle
        case .codex:
            bundle = config.codexBundle
        }
        return withTestedMetadata(bundle, route: route)
    }

}
