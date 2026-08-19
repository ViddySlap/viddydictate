import Foundation

enum SelfTestTier: String {
    case deterministic
    case services
    case gui
    case excluded
}

struct SelfTestManifestEntry {
    let flag: String
    let tier: SelfTestTier
    let handler: ([String]) -> Int32
}

private struct SelfTestManifestDefinition {
    let tier: SelfTestTier
    let handler: ([String]) -> Int32
}

// Every pre-AppKit verification/probe flag except the build-only --emit-theme-css utility lives here.
// Ordering is behavior: if callers provide multiple flags, the first entry wins just as the old dispatch did.
private let selfTestManifestDefinitions: [SelfTestManifestFlag: SelfTestManifestDefinition] = [
    .codexIsolationSelftest: .init(tier: .deterministic) { arguments in
        guard let i = arguments.firstIndex(of: "--runner"), i + 1 < arguments.count else {
            print("[codex-s1-selftest] FAIL: --runner is required")
            return 2
        }
        return CodexIsolationSelfTest.run(runnerPath: arguments[i + 1]) ? 0 : 1
    },
    .codexIsolationPreflight: .init(tier: .excluded) { arguments in
        guard let i = arguments.firstIndex(of: "--runner"), i + 1 < arguments.count else {
            print("[codex-s1-preflight] FAIL: --runner is required")
            return 2
        }
        let mode: CodexIsolationPreflight.Mode = arguments.contains("--stage-production")
            ? .stageProduction : .scratch
        return CodexIsolationPreflight.run(mode: mode, runnerPath: arguments[i + 1]) ? 0 : 1
    },
    .codexFeatureInventorySelftest: .init(tier: .deterministic) { _ in
        CodexFeatureInventorySelfTest.run() ? 0 : 1
    },
    .codexFeatureInventory: .init(tier: .excluded) { arguments in
        CodexFeatureInventoryTool.run(arguments: arguments)
    },
    .codexModelCatalogSelftest: .init(tier: .deterministic) { _ in
        CodexModelCatalogSelfTest.run() ? 0 : 1
    },
    // Authenticated: performs the REAL app-server handshake, so it belongs in the same tier
    // as the production provider smoke rather than the offline deterministic rail.
    .codexCatalogLive: .init(tier: .services) { arguments in
        CodexCatalogLiveGate.run(arguments: arguments) ? 0 : 1
    },
    // Authenticated in the same sense: it invokes the real vendor login command, so it cannot run
    // on the offline deterministic rail. It touches only a throwaway scratch home.
    .codexDeviceAuthLive: .init(tier: .services) { _ in
        CodexDeviceAuthLiveGate.run() ? 0 : 1
    },
    .claudeModelCatalogSelftest: .init(tier: .deterministic) { _ in
        ClaudeModelCatalogSelfTest.run() ? 0 : 1
    },
    // Authenticated: performs the REAL GET /v1/models with the user's Claude Code OAuth token, so it
    // belongs beside the other live provider gates rather than on the offline deterministic rail.
    .claudeCatalogLive: .init(tier: .services) { arguments in
        ClaudeCatalogLiveGate.run(arguments: arguments) ? 0 : 1
    },
    // Pure fixture JSON: pins the store-agnostic status schema, the subscription-method whitelist,
    // and the distinct unsupported-auth state without reading this machine's credential stores.
    .claudeAuthStatusSelftest: .init(tier: .deterministic) { _ in
        ClaudeAuthStatusSelfTest.run() ? 0 : 1
    },
    // Reads the real Claude Code login Keychain through the vendor CLI. It belongs in services and
    // may abstain when Keychain access is structurally unavailable to the verification process.
    .claudeAuthStatusLive: .init(tier: .services) { arguments in
        ClaudeAuthStatusLiveGate.run(arguments: arguments) ? 0 : 1
    },
    // Pure: a fake clock and synthetic status readings drive the whole connect flow, including the
    // already-connected path that must launch nothing. No Terminal, no CLI, no credential store.
    .claudeConnectFlowSelftest: .init(tier: .deterministic) { _ in
        ClaudeConnectFlowSelfTest.run() ? 0 : 1
    },
    // Pure synthetic PCM only: proves the production trim removes long low-energy tails while a
    // deliberately quiet final-word fixture survives. No microphone, daemon, or provider is used.
    .audioTrimSelftest: .init(tier: .deterministic) { _ in
        AudioTrimSelfTest.run() ? 0 : 1
    },
    .cleanupSelftest: .init(tier: .services) { _ in
        CleanupSelfTest.run() ? 0 : 1
    },
    .emailSelftest: .init(tier: .services) { _ in
        EmailSelfTest.run() ? 0 : 1
    },
    .perTakeArmService: .init(tier: .services) { _ in
        PerTakeArmServiceGate.run() ? 0 : 1
    },
    .customModeSelftest: .init(tier: .deterministic) { _ in
        CustomModeSelfTest.run() ? 0 : 1
    },
    // Pure: every store is built on an injected scratch URL, so the adopted custom-mode row, the real
    // sticky-skills.json, and the real models-power.json are never read or written.
    .stickySkillSelftest: .init(tier: .deterministic) { _ in
        StickySkillSelfTest.run() ? 0 : 1
    },
    // Process-level but pre-AppKit: verify.sh supplies a brand-new Core Foundation home and independently
    // requires populated scratch Application Support after this exits. Default production store URLs are
    // intentional here; injecting files would not rehearse what a stranger's first launch actually opens.
    .freshInstallRehearsal: .init(tier: .deterministic) { _ in
        FreshInstallRehearsal.run() ? 0 : 1
    },
    .lmStudioModelCatalogSelftest: .init(tier: .deterministic) { _ in
        LMStudioModelCatalogSelfTest.run() ? 0 : 1
    },
    .lmStudioModelCatalogLive: .init(tier: .services) { _ in
        LMStudioModelCatalogLiveGate.run() ? 0 : 1
    },
    .modelRoutingSelftest: .init(tier: .deterministic) { _ in
        ModelRoutingSelfTest.run() ? 0 : 1
    },
    .availabilityRoutingSelftest: .init(tier: .deterministic) { _ in
        AvailabilityRoutingSelfTest.run() ? 0 : 1
    },
    .modelsPowerSelftest: .init(tier: .deterministic) { _ in
        ModelsPowerSettingsSelfTest.run() ? 0 : 1
    },
    .promptOverlaySelftest: .init(tier: .deterministic) { _ in
        PromptOverlaySelfTest.run() ? 0 : 1
    },
    // Pure: the workstation's composition is compared against the request the runtime builds, over
    // synthetic prompts. No provider, no window, no stored mode.
    .promptWorkstationSelftest: .init(tier: .deterministic) { _ in
        PromptWorkstationSelfTest.run() ? 0 : 1
    },
    // Pure: synthetic history entries and synthetic Results only. No provider runs and the machine's own
    // history.json is never read - the sourcing rules are asserted over fixtures.
    .promptTestBenchSelftest: .init(tier: .deterministic) { _ in
        PromptTestBenchSelfTest.run() ? 0 : 1
    },
    .modelFreshnessSelftest: .init(tier: .deterministic) { _ in
        ModelFreshnessSelfTest.run() ? 0 : 1
    },
    .settingsPrefixSelftest: .init(tier: .deterministic) { _ in
        SettingsPrefixSelfTest.run() ? 0 : 1
    },
    .settingsDefaultsSelftest: .init(tier: .deterministic) { _ in
        SettingsDefaultsSelfTest.run() ? 0 : 1
    },
    .secretStoreSelftest: .init(tier: .deterministic) { _ in
        SecretStoreSelfTest.run() ? 0 : 1
    },
    // Pure: every fixture is a synthetic observation, so no daemon, provider, keychain, or TCC grant is
    // consulted and the gate reports on the policy rather than on this machine's setup.
    .preflightSelftest: .init(tier: .deterministic) { _ in
        PreflightSelfTest.run() ? 0 : 1
    },
    // Pure: presentation over synthetic reports. The strings a Settings row shows are asserted here; that
    // the view draws them is the gui-tier render gate's job.
    .preflightSurfaceSelftest: .init(tier: .deterministic) { _ in
        PreflightSurfaceSelfTest.run() ? 0 : 1
    },
    // Pure: synthetic presence maps only, so the gate reports on the W4 policy rather than on whether this
    // machine happens to have a provider signed in.
    .providerOnboardingSelftest: .init(tier: .deterministic) { _ in
        ProviderOnboardingSelfTest.run() ? 0 : 1
    },
    // Pure: the copy, the derived stored state, and the save policy driven through an injected writer, so no
    // login keychain is touched. D7's in-app write is the app's own by construction; the live write is a
    // hand-test step because an agent shell cannot perform one.
    .geminiKeySetupSelftest: .init(tier: .deterministic) { _ in
        GeminiKeySetupSelfTest.run() ? 0 : 1
    },
    .setupRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--setup-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/setup-render"
        return SetupRender.run(outDir: out) ? 0 : 1
    },
    .providerOnboardingRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--provider-onboarding-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/provider-onboarding-render"
        return ProviderOnboardingRender.run(outDir: out) ? 0 : 1
    },
    .modelsPowerUIProbe: .init(tier: .gui) { _ in
        ModelsPowerUIProbe.run() ? 0 : 1
    },
    .modelsPowerRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--models-power-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/models-power-render"
        return ModelsPowerRender.run(outDir: out) ? 0 : 1
    },
    .hotkeysTabRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--hotkeys-tab-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/hotkeys-tab-render"
        return HotkeysTabRender.run(outDir: out) ? 0 : 1
    },
    .stickySkillsRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--sticky-skills-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/sticky-skills-render"
        return StickySkillsTabRender.run(outDir: out) ? 0 : 1
    },
    .textTransformSelftest: .init(tier: .deterministic) { arguments in
        if let reproExit = CloudDrainDeadlockSelfTest.reproExit(arguments: arguments) {
            return reproExit
        }
        return TextTransformSelfTest.run() ? 0 : 1
    },
    .codexProviderSelftest: .init(tier: .deterministic) { _ in
        CodexProviderSelfTest.run() ? 0 : 1
    },
    .cloudModeSelftest: .init(tier: .services) { _ in
        CloudCleanupSelfTest.run() ? 0 : 1
    },
    .stickyCloudService: .init(tier: .services) { _ in
        StickySkillCloudGate.run() ? 0 : 1
    },
    .webSearchTransportSelftest: .init(tier: .deterministic) { _ in
        WebSearchSelfTest.runTransportPrivacyTests() ? 0 : 1
    },
    .webSearchSelftest: .init(tier: .services) { _ in
        WebSearchSelfTest.run() ? 0 : 1
    },
    .lowPowerSelftest: .init(tier: .deterministic) { _ in
        LowPowerSelfTest.run() ? 0 : 1
    },
    .hudPolishSelftest: .init(tier: .deterministic) { _ in
        HUDPolishSelfTest.run() ? 0 : 1
    },
    .residencySelftest: .init(tier: .services) { _ in
        ModelResidencySelfTest.run() ? 0 : 1
    },
    .historySelftest: .init(tier: .deterministic) { arguments in
        if let deadlockExit = AudioRetentionSelfTest.deadlockReproExit(arguments: arguments) {
            return deadlockExit
        }
        var samplesDirectory: URL?
        if let i = arguments.firstIndex(of: "--encoder-samples") {
            guard i + 1 < arguments.count else {
                print("[history-selftest] FAIL: --encoder-samples requires a directory")
                return 2
            }
            samplesDirectory = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        let infiniteOK = DictationHistorySelfTest.run()
        let rollingOK = TranscriptionHistorySelfTest.run(encoderSamplesDirectory: samplesDirectory)
        let audioOK = AudioRetentionSelfTest.run()
        return infiniteOK && rollingOK && audioOK ? 0 : 1
    },
    .hangWatchdogSelftest: .init(tier: .deterministic) { arguments in
        if let proofExit = HangWatchdogSelfTest.abortProofExit(arguments: arguments) {
            return proofExit
        }
        return HangWatchdogSelfTest.run() ? 0 : 1
    },
    .lockedDeliverySelftest: .init(tier: .deterministic) { _ in
        LockedDeliverySelfTest.run() ? 0 : 1
    },
    .pathClassifierProbe: .init(tier: .deterministic) { _ in
        PathClassifierProbe.run() ? 0 : 1
    },
    .filesProbe: .init(tier: .deterministic) { _ in
        FilesProbe.run() ? 0 : 1
    },
    .clobberProbe: .init(tier: .deterministic) { _ in
        ClobberProbe.run() ? 0 : 1
    },
    .mergeProbe: .init(tier: .deterministic) { _ in
        MergeProbe.run() ? 0 : 1
    },
    .notesProbe: .init(tier: .deterministic) { _ in
        NotesProbe.run() ? 0 : 1
    },
    .notesUndoLifetimeProbe: .init(tier: .gui) { _ in
        NotesUndoLifetimeProbe.run() ? 0 : 1
    },
    .notesHTTPSelftest: .init(tier: .deterministic) { _ in
        NotesControlSelfTest.run() ? 0 : 1
    },
    .hudProbe: .init(tier: .gui) { _ in
        HUDProbe.run() ? 0 : 1
    },
    .hudRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--hud-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/hud-render"
        return HUDRender.run(outDir: out) ? 0 : 1
    },
    .micProbe: .init(tier: .gui) { _ in
        MicProbe.run() ? 0 : 1
    },
    .micCaptureTest: .init(tier: .excluded) { _ in
        MicProbe.runCapture() ? 0 : 1
    },
    .recorderTest: .init(tier: .excluded) { arguments in
        guard let i = arguments.firstIndex(of: "--recorder-test") else { return 1 }
        let uid = arguments.count > i + 1 ? arguments[i + 1] : nil
        return MicProbe.runRecorderTest(forcedUID: uid) ? 0 : 1
    },
]

let selfTestManifest: [SelfTestManifestEntry] = SelfTestManifestFlag.allCases.map { flag in
    guard let definition = selfTestManifestDefinitions[flag] else {
        preconditionFailure("missing selftest manifest definition for \(flag.rawValue)")
    }
    return SelfTestManifestEntry(flag: flag.rawValue,
                                 tier: definition.tier,
                                 handler: definition.handler)
}
