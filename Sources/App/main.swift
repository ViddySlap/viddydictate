import Cocoa

// Name-keyed manifest authority shared by the shipped rejection path and the SELFTEST handlers.
// Case order preserves the historical first-matching-flag dispatch behavior.
enum SelfTestManifestFlag: String, CaseIterable {
    case codexIsolationSelftest = "--codex-isolation-selftest"
    case codexIsolationPreflight = "--codex-isolation-preflight"
    case codexFeatureInventorySelftest = "--codex-feature-inventory-selftest"
    case codexFeatureInventory = "--codex-feature-inventory"
    case codexModelCatalogSelftest = "--codex-model-catalog-selftest"
    case codexCatalogLive = "--codex-catalog-live"
    case codexDeviceAuthLive = "--codex-device-auth-live"
    case claudeModelCatalogSelftest = "--claude-model-catalog-selftest"
    case claudeCatalogLive = "--claude-catalog-live"
    case claudeAuthStatusSelftest = "--claude-auth-status-selftest"
    case claudeAuthStatusLive = "--claude-auth-status-live"
    case claudeConnectFlowSelftest = "--claude-connect-flow-selftest"
    case audioTrimSelftest = "--audio-trim-selftest"
    case cleanupSelftest = "--selftest"
    case emailSelftest = "--email-selftest"
    case perTakeArmService = "--per-take-arm-service"
    case customModeSelftest = "--custommode-selftest"
    case stickySkillSelftest = "--sticky-skill-selftest"
    case freshInstallRehearsal = "--fresh-install-rehearsal"
    case networkPathSelftest = "--network-path-selftest"
    case lmStudioInstallerSelftest = "--lmstudio-installer-selftest"
    case lmStudioModelCatalogSelftest = "--lmstudio-model-catalog-selftest"
    case lmStudioModelCatalogLive = "--lmstudio-model-catalog-live"
    case modelRoutingSelftest = "--model-routing-selftest"
    case availabilityRoutingSelftest = "--availability-routing-selftest"
    case modelsPowerSelftest = "--models-power-selftest"
    case systemMemorySelftest = "--system-memory-selftest"
    case modelCapacitySelftest = "--model-capacity-selftest"
    case promptOverlaySelftest = "--prompt-overlay-selftest"
    case promptWorkstationSelftest = "--prompt-workstation-selftest"
    case promptTestBenchSelftest = "--prompt-test-bench-selftest"
    case modelFreshnessSelftest = "--model-freshness-selftest"
    case settingsPrefixSelftest = "--settings-prefix-selftest"
    case settingsDefaultsSelftest = "--settings-defaults-selftest"
    case secretStoreSelftest = "--secret-store-selftest"
    case bundledPythonSelftest = "--bundled-python-selftest"
    case installerEngineSelftest = "--installer-engine-selftest"
    case bootstrapStateSelftest = "--bootstrap-state-selftest"
    case pointOfUseOfferSelftest = "--point-of-use-offer-selftest"
    case preflightSelftest = "--preflight-selftest"
    case preflightSurfaceSelftest = "--preflight-surface-selftest"
    case providerOnboardingSelftest = "--provider-onboarding-selftest"
    case geminiKeySetupSelftest = "--gemini-key-setup-selftest"
    case localModelSetupSelftest = "--local-model-setup-selftest"
    case componentPickerSelftest = "--component-picker-selftest"
    case componentPickerRender = "--component-picker-render"
    case installProgressSelftest = "--install-progress-selftest"
    case installProgressRender = "--install-progress-render"
    case localModelsReadoutLive = "--local-models-readout-live"
    case setupRender = "--setup-render"
    case pointOfUseRender = "--point-of-use-render"
    case providerOnboardingRender = "--provider-onboarding-render"
    case modelsPowerUIProbe = "--models-power-ui-probe"
    case modelsPowerRender = "--models-power-render"
    case hotkeysTabRender = "--hotkeys-tab-render"
    case stickySkillsRender = "--sticky-skills-render"
    case textTransformSelftest = "--text-transform-selftest"
    case codexProviderSelftest = "--codex-provider-selftest"
    case cloudModeSelftest = "--cloudmode-selftest"
    case stickyCloudService = "--sticky-cloud-service"
    case webSearchTransportSelftest = "--websearch-transport-selftest"
    case webSearchSelftest = "--websearch-selftest"
    case lowPowerSelftest = "--lowpower-selftest"
    case hudPolishSelftest = "--hud-polish-selftest"
    case residencySelftest = "--residency-selftest"
    case historySelftest = "--history-selftest"
    case hangWatchdogSelftest = "--hang-watchdog-selftest"
    case lockedDeliverySelftest = "--locked-delivery-selftest"
    case pathClassifierProbe = "--path-classifier-probe"
    case filesProbe = "--files-probe"
    case clobberProbe = "--clobber-probe"
    case mergeProbe = "--merge-probe"
    case notesProbe = "--notes-probe"
    case notesUndoLifetimeProbe = "--notes-undo-lifetime-probe"
    case notesHTTPSelftest = "--notes-http-selftest"
    case hudProbe = "--hud-probe"
    case hudRender = "--hud-render"
    case micProbe = "--mic-probe"
    case micCaptureTest = "--mic-capture-test"
    case recorderTest = "--recorder-test"
    // Chain vdfit GA1: the six model-fit arms (--only <arm>). Excluded tier on purpose — WIRE1 promotes
    // this once the arms pass; wiring a deliberately-red test into deterministic now would fail
    // check_selftest_flag_drift and make verify.sh red at HEAD.
    case modelFitSelftest = "--modelfit-selftest"
    // RTY1: the same defect graded through the seam production dispatches on, rather than through the
    // pure policy function. Its own flag because ModelFitSelfTest is protected by chain vdfit.
    case modelFitRetryWiringSelftest = "--modelfit-wiring-selftest"
    // DMGD1: the daemon staged into the app bundle and installed by the app. Deterministic: it drives the
    // real DaemonInstaller over a scratch tree with an injected restart spy, and its four arms are each
    // exercised by a scripts/verify.sh gate.
    case daemonInstallSelftest = "--daemon-install-selftest"
    // DMGU1: app-update availability policy, with an injected transport and opener. Deterministic: five
    // arms (compare/failures/nag/link/control), each exercised by a scripts/verify.sh gate.
    case appUpdateSelftest = "--app-update-selftest"
    // Ollama lane S2 (G1): the pure /api/tags, /api/show and /api/ps parser over offline fixtures, with
    // built-in negative controls. Appended, so every earlier flag keeps its first-wins dispatch position.
    case ollamaCatalogSelftest = "--ollama-catalog-selftest"
    // Ollama lane S2 (G2): the pure OpenAI <-> native /api/chat translator, run through the existing
    // CleanupClient classifiers, with built-in negative controls.
    case ollamaTransportSelftest = "--ollama-transport-selftest"
    // Ollama lane S1: the local-backend identity types, the bundle's tolerant localBackend field (a 1.1.0
    // models-power.json round-trips byte-identical) and the LM Studio adapter, with built-in negative controls.
    case localBackendCodecSelftest = "--local-backend-codec-selftest"
    // Ollama lane S2b: the native-HTTP OllamaBackend over a scripted transport (catalog + show cache,
    // resident reuse, keep_alive load/unload, /api/chat), with built-in negative controls.
    case ollamaBackendSelftest = "--ollama-backend-selftest"
    // Ollama lane S2b (G9): the same backend against the real Ollama on this Mac. Services tier; abstains
    // when Ollama is absent or not answering.
    case ollamaLive = "--ollama-live"
    // The Option+L retrieval leg only ever hands LM Studio a Local model id, even after the header's
    // global provider action pins .searchRetrieval to Claude or Codex. Scratch stores, built-in mutants.
    case searchRetrievalLocalOnlySelftest = "--search-retrieval-local-only-selftest"
    // Ollama lane S3a (G3): Local routes resolve by (app, model), step once across local apps when the
    // pinned app is down or nothing in it fits, and never into the cloud. Scratch stores, built-in mutants.
    case localBackendRoutingSelftest = "--local-backend-routing-selftest"
    // Ollama lane S3a (G6): the merged .local presence over scripted LM Studio and Ollama backends, the
    // pinned-app start (recorded, never launched), and the Preferred-local-app truth table. Built-in mutants.
    case localPresenceSelftest = "--local-presence-selftest"
    // Ollama lane S3b: the Local model dropdown over the merged catalog, as data. One app keeps the
    // pre-Ollama titles byte for byte; both apps are grouped and named; picks are (app, id). Built-in mutants.
    case localPickerMergeSelftest = "--local-picker-merge-selftest"
    // Ollama lane S6 (G5): the Ollama installer's trust chain (every hop allowlisted, bundle id, codesign,
    // Team ID), the no-overwrite rule, start by path and the approval wait, and pull progress, over scripted
    // I/O with built-in negative controls.
    case ollamaInstallerSelftest = "--ollama-installer-selftest"
    // Ollama lane S6: the local-app install plan (LM Studio app -> lms-ready -> model, Ollama app -> server-ready
    // -> pull), the D3 point-of-use app choice, and unchanged persisted ids. Scratch only; built-in mutants.
    case installerLocalStepsSelftest = "--installer-local-steps-selftest"
    // Ollama lane S3c: the Setup tab's local app rows (state, Install/Open/Start, LM Studio first and the only
    // one ever recommended), the headline, the Preferred local app, the point-of-use app choice and running
    // page, and the app-named Local preset line, as data. Built-in mutants.
    case localAppsSetupSelftest = "--local-apps-setup-selftest"
    // Ollama lane S8: the revived first-run setup window as data. D8's LM Studio / Ollama / Skip choice, the
    // Ollama rows' plan and fit check, Skip's empty plan, the first-launch rule over scratch stores (an upgraded
    // working install is never shown it), and the LM Studio picker unchanged. Built-in mutants.
    case firstRunSetupSelftest = "--first-run-setup-selftest"
    // Ollama lane D11: every built-in default reads "Staff pick" on every user-visible surface (badges, prompt
    // labels, pickers, the global control, Codex and cloud update copy), and ratification survives a store
    // round-trip internally. Pure label functions plus one scratch store. Built-in mutants.
    case staffPicksCopySelftest = "--staff-picks-copy-selftest"
}

// Sub-flags of --history-selftest, NOT manifest flags of their own: the retained-take deadlock repro
// is opt-in so the ordinary deterministic gate stays green rather than red-by-design. They still need
// naming here because an unrecognized flag falls through to app.run() below, and a stray second
// instance of this app is not a harmless no-op: one deleted live sticky notes on 2026-08-03.
enum AudioRetentionDeadlockFlag: String, CaseIterable {
    case repro = "--audio-retention-deadlock-repro"
    case child = "--audio-retention-deadlock-child"
    case scratchRoot = "--audio-retention-deadlock-scratch-root"
}

// Sub-flags of --text-transform-selftest, NOT manifest flags of their own: the escaped-pipe-holder
// drain repro is opt-in because it is RED BY DESIGN until CloudCleanupClient bounds its pipe drains,
// and a deterministic tier that is red by design teaches nobody anything. Same reason they are named
// here as the retained-take sub-flags above: an unrecognized flag falls through to app.run().
enum CloudDrainDeadlockFlag: String, CaseIterable {
    case repro = "--cloud-drain-deadlock-repro"
    case child = "--cloud-drain-deadlock-child"
    case scratchRoot = "--cloud-drain-deadlock-scratch-root"
}

// Sub-flag of --hang-watchdog-selftest, NOT a manifest flag of its own. It deliberately wedges the
// main thread and lets the shipped watchdog SIGABRT this process, so it must stay out of every
// verify.sh tier (it takes the real 45s threshold to fire and leaves a crash report by design) and it
// must never be reachable from the shipped app.
enum HangWatchdogFlag: String, CaseIterable {
    case abortProof = "--hang-watchdog-abort-proof"
}

// Log any uncaught exception (helps catch a silent AppKit-swallowed throw).
NSSetUncaughtExceptionHandler { ex in
    Log.write("FATAL \(ex.name.rawValue): \(ex.reason ?? "?") :: \(ex.callStackSymbols.prefix(6).joined(separator: " | "))")
}
Log.rotateIfNeeded()
Log.write("=== launch ===")

if CommandLine.arguments.contains("--emit-theme-css") {
    Settings.registerDefaults()
    print(Phosphor.emitThemeCSS())
    exit(0)
}

#if !SELFTEST
// The theme emitter above runs during builds and must remain free of live Keychain access. Normal
// shipped-app launches and the shipped maintenance CLI migrate both old storage domains first.
Settings.migrateLegacyDefaultsDomainIfNeeded()
SecretStore.migrateLegacyItemsIfNeeded()
#endif
Settings.registerDefaults()

// Secret-store maintenance. These stay in the SHIPPED app on purpose: an item written by the app is
// on its own keychain access list and reads back without an authorization prompt, whereas one written
// by `security add-generic-password` or by the test bundle is not. Value arrives on stdin, never argv.
if CommandLine.arguments.contains("--set-gemini-key") {
    exit(SecretStore.runSetFromStdin(.geminiAPIKey))
}
if CommandLine.arguments.contains("--gemini-key-status") {
    exit(SecretStore.runStatus(.geminiAPIKey))
}
if CommandLine.arguments.contains("--clear-gemini-key") {
    exit(SecretStore.runClear(.geminiAPIKey))
}

#if SELFTEST
if CommandLine.arguments.contains("--list-selftest-flags") {
    for entry in selfTestManifest {
        print("\(entry.flag)\t\(entry.tier.rawValue)")
    }
    exit(0)
}

if !CommandLine.arguments.contains(SelfTestManifestFlag.historySelftest.rawValue),
   let stray = CommandLine.arguments.first(where: {
       AudioRetentionDeadlockFlag(rawValue: $0) != nil
   }) {
    FileHandle.standardError.write(Data("[viddydictate] \(stray) is a --history-selftest sub-flag; run it as: --history-selftest \(stray)\n".utf8))
    exit(2)
}

if !CommandLine.arguments.contains(SelfTestManifestFlag.textTransformSelftest.rawValue),
   let stray = CommandLine.arguments.first(where: {
       CloudDrainDeadlockFlag(rawValue: $0) != nil
   }) {
    FileHandle.standardError.write(Data("[viddydictate] \(stray) is a --text-transform-selftest sub-flag; run it as: --text-transform-selftest \(stray)\n".utf8))
    exit(2)
}

if !CommandLine.arguments.contains(SelfTestManifestFlag.hangWatchdogSelftest.rawValue),
   let stray = CommandLine.arguments.first(where: {
       HangWatchdogFlag(rawValue: $0) != nil
   }) {
    FileHandle.standardError.write(Data("[viddydictate] \(stray) is a --hang-watchdog-selftest sub-flag; run it as: --hang-watchdog-selftest \(stray)\n".utf8))
    exit(2)
}

if let entry = selfTestManifest.first(where: { CommandLine.arguments.contains($0.flag) }) {
    exit(entry.handler(CommandLine.arguments))
}
#else
// Risk 2: the shipped app no longer answers these; a stale flag must fail fast, NOT fall through to app.run().
let flagsMovedToTestBundle = ["--list-selftest-flags"]
    + SelfTestManifestFlag.allCases.map(\.rawValue)
    + AudioRetentionDeadlockFlag.allCases.map(\.rawValue)
    + CloudDrainDeadlockFlag.allCases.map(\.rawValue)
    + HangWatchdogFlag.allCases.map(\.rawValue)
if let bad = CommandLine.arguments.first(where: { flagsMovedToTestBundle.contains($0) }) {
    FileHandle.standardError.write(Data("[viddydictate] \(bad): this test/probe flag moved to build/ViddyDictateTests.app — run it there, not the shipped app\n".utf8))
    exit(2)
}
#endif

// Manual app bootstrap (no storyboard / no @main): menu-bar-only agent app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only — no Dock icon, no app menu
app.run()
