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
    .networkPathSelftest: .init(tier: .deterministic) { _ in
        NetworkPathSelfTest.run() ? 0 : 1
    },
    // Pure: synthetic provider presences, a synthetic bootstrap snapshot, and an injected LM Studio
    // performer. It never attaches a disk image, writes to /Applications, runs `lms`, or downloads a byte.
    .pointOfUseOfferSelftest: .init(tier: .deterministic) { _ in
        PointOfUseOfferSelfTest.run() ? 0 : 1
    },
    .lmStudioInstallerSelftest: .init(tier: .deterministic) { _ in
        LMStudioInstallerSelfTest.run() ? 0 : 1
    },
    // Pure: every machine it reasons about is synthesized from a recorded kernel ratio, so the picker's
    // 8 GB and 16 GB verdicts are pinned on a developer machine that is neither.
    .componentPickerSelftest: .init(tier: .deterministic) { _ in
        ComponentPickerSelfTest.run() ? 0 : 1
    },
    // Pure: the byte sampler is a stub and the clock is a number, so a download that takes minutes on a
    // real network is stepped through here in microseconds.
    .installProgressSelftest: .init(tier: .deterministic) { _ in
        InstallProgressSelfTest.run() ? 0 : 1
    },
    .componentPickerRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--component-picker-render"), i + 1 < arguments.count
        else {
            print("[component-picker-render] FAIL: an output directory is required")
            return 2
        }
        return ComponentPickerRender.run(outDir: arguments[i + 1]) ? 0 : 1
    },
    .installProgressRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--install-progress-render"), i + 1 < arguments.count
        else {
            print("[install-progress-render] FAIL: an output directory is required")
            return 2
        }
        return InstallProgressRender.run(outDir: arguments[i + 1]) ? 0 : 1
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
    .systemMemorySelftest: .init(tier: .deterministic) { _ in
        SystemMemorySelfTest.run() ? 0 : 1
    },
    .modelCapacitySelftest: .init(tier: .deterministic) { _ in
        ModelCapacitySelfTest.run() ? 0 : 1
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
    // Offline and home-free: it inspects a built app bundle and runs the interpreter inside it. The
    // venv it creates goes to TMPDIR, and `venv` installs pip from the stdlib's own wheel rather than
    // from the network. Takes `--app <bundle>` so the same checks can be pointed at the DEPLOYED app
    // in ~/Applications, which is the placement that actually has to work.
    .bundledPythonSelftest: .init(tier: .deterministic) { arguments in
        BundledPythonSelfTest.run(arguments: arguments) ? 0 : 1
    },
    .installerEngineSelftest: .init(tier: .deterministic) { _ in
        InstallerEngineSelfTest.run() ? 0 : 1
    },
    .bootstrapStateSelftest: .init(tier: .deterministic) { _ in
        BootstrapStateSelfTest.run() ? 0 : 1
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
    // Pure: the slider's two renderings, the LM Studio JIT reader driven against fixtures in this run's own
    // TMPDIR, and what each reading is reported as. No view and no real settings file.
    // Live: it reads THIS machine's LM Studio. The offscreen render gate proves the readout's wiring
    // against a stub; this proves the stub was telling the truth about the real CLI.
    .localModelsReadoutLive: .init(tier: .services) { arguments in
        LocalModelsReadoutLiveGate.run(arguments: arguments) ? 0 : 1
    },
    .localModelSetupSelftest: .init(tier: .deterministic) { _ in
        LocalModelSetupSelfTest.run() ? 0 : 1
    },
    .setupRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--setup-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/setup-render"
        return SetupRender.run(outDir: out) ? 0 : 1
    },
    .pointOfUseRender: .init(tier: .gui) { arguments in
        guard let i = arguments.firstIndex(of: "--point-of-use-render") else { return 1 }
        let out = arguments.count > i + 1 ? arguments[i + 1] : "build/point-of-use-render"
        return PointOfUseOfferRender.run(outDir: out) ? 0 : 1
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
    // Chain vdfit GA1: all six arms are green now that the fit/retry/catalog/seed/search-retrieval
    // fixes have landed; `preference` remains the control. `--only <arm>` is required.
    .modelFitSelftest: .init(tier: .deterministic) { arguments in
        ModelFitSelfTest.run(arguments: arguments)
    },
    // RTY1: proves the capacity step-down fires from the production dispatch seam, not just from the
    // policy function. Takes no --only; it is one arm.
    .modelFitRetryWiringSelftest: .init(tier: .deterministic) { _ in
        ModelFitRetryWiringSelfTest.run()
    },
    // DMGD1: four arms over the injected DaemonInstaller (bundled/installs/upgrade/absent). Deterministic:
    // a build-artifact gate whose four arms are each exercised by a scripts/verify.sh gate.
    .daemonInstallSelftest: .init(tier: .deterministic) { arguments in
        DaemonInstallSelfTest.run(arguments: arguments)
    },
    // DMGU1: five arms over the injected-transport app-update policy. Deterministic: no network, no
    // browser, no real HOME; each arm is exercised by a scripts/verify.sh gate.
    .appUpdateSelftest: .init(tier: .deterministic) { arguments in
        AppUpdateSelfTest.run(arguments: arguments)
    },
    // Pure: inline /api/tags, /api/show and /api/ps fixtures through a parser with no networking, no
    // Process and no Settings reads. No Ollama needs to be installed or running.
    .ollamaCatalogSelftest: .init(tier: .deterministic) { _ in
        OllamaTagsFixtureSelfTest.run() ? 0 : 1
    },
    // Pure: dictionaries in, dictionaries out, then the in-process CleanupClient classifiers over a
    // synthetic 200 response. No socket is opened and no model is loaded.
    .ollamaTransportSelftest: .init(tier: .deterministic) { _ in
        OllamaTranslatorFixtureSelfTest.run() ? 0 : 1
    },
    // Scratch-only: the real ModelsPowerSettingsStore writes under a fresh temporary directory, and the LM
    // Studio adapter runs over an injected catalog. No lms process, no model, no live preferences.
    .localBackendCodecSelftest: .init(tier: .deterministic) { _ in
        LocalBackendCodecFixtureSelfTest.run() ? 0 : 1
    },
    // Scripted: every request goes to an in-memory Ollama through the injected transport, and the install
    // probe is scripted too. No socket, no Ollama, no filesystem, no preferences.
    .ollamaBackendSelftest: .init(tier: .deterministic) { _ in
        OllamaBackendScriptedSelfTest.run() ? 0 : 1
    },
    // Loads and unloads a real model in the real Ollama (only one that was not resident, never a foreign
    // one), so it belongs in services. Abstains when Ollama is absent, stopped, or has no usable model.
    .ollamaLive: .init(tier: .services) { _ in
        OllamaLiveBackendGate.run() ? 0 : 1
    },
    // Scratch-only: real ModelsPowerSettingsStores under a fresh temporary directory with an injected Local
    // catalog and availability. No LM Studio, no model, no live preferences; negative controls built in.
    .searchRetrievalLocalOnlySelftest: .init(tier: .deterministic) { _ in
        SearchRetrievalLocalOnlyFixtureSelfTest.run() ? 0 : 1
    },
    // Pure policy plus scratch ModelsPowerSettingsStores under a fresh temporary directory, with injected
    // two-app catalogs and capacity facts. No LM Studio, no Ollama, no live preferences.
    .localBackendRoutingSelftest: .init(tier: .deterministic) { _ in
        LocalBackendRoutingFixtureSelfTest.run() ? 0 : 1
    },
    // Scripted: the real LMStudioBackend over injected dependencies and the real OllamaBackend over a
    // scripted transport; the app launch is a recorder. No lms, no socket, no process, no preferences.
    .localPresenceSelftest: .init(tier: .deterministic) { _ in
        LocalPresenceFixtureSelfTest.run() ? 0 : 1
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
