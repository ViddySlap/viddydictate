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
    case lmStudioModelCatalogSelftest = "--lmstudio-model-catalog-selftest"
    case lmStudioModelCatalogLive = "--lmstudio-model-catalog-live"
    case modelRoutingSelftest = "--model-routing-selftest"
    case availabilityRoutingSelftest = "--availability-routing-selftest"
    case modelsPowerSelftest = "--models-power-selftest"
    case promptOverlaySelftest = "--prompt-overlay-selftest"
    case promptWorkstationSelftest = "--prompt-workstation-selftest"
    case promptTestBenchSelftest = "--prompt-test-bench-selftest"
    case modelFreshnessSelftest = "--model-freshness-selftest"
    case settingsPrefixSelftest = "--settings-prefix-selftest"
    case settingsDefaultsSelftest = "--settings-defaults-selftest"
    case secretStoreSelftest = "--secret-store-selftest"
    case preflightSelftest = "--preflight-selftest"
    case preflightSurfaceSelftest = "--preflight-surface-selftest"
    case providerOnboardingSelftest = "--provider-onboarding-selftest"
    case geminiKeySetupSelftest = "--gemini-key-setup-selftest"
    case setupRender = "--setup-render"
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
