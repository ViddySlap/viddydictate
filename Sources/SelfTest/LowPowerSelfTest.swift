import Foundation

/// Backward-compatible `--lowpower-selftest` flag, rewritten for A3's Power Mode contract. The test is
/// pure/scratch-only: no provider, battery API, live preference, model, network, AppKit, or user-data call.
enum LowPowerSelfTest {
    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate Power Mode + battery advisory — selftest ===")
        let reporter = SelfTestReporter()

        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let before = defaults.persistentDomain(forName: domain)
        defer {
            if let before = before { defaults.setPersistentDomain(before, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }

        checkPowerModeContract(reporter.record)
        checkPowerCopy(reporter.record)
        checkSettingsTabConsolidation(reporter.record)
        checkMigration(reporter.record, defaults: defaults)
        checkManualStickyProviderIndependence(reporter.record, defaults: defaults)
        checkBatteryAdvisory(reporter.record)
        checkDismissalPersistence(reporter.record)

        print("\n=== RESULT ===")
        print("power mode contract:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nPOWER MODE CONTRACT GREEN" : "\nPOWER MODE CONTRACT FAILED")
        return reporter.passed
    }

    private static func checkPowerModeContract(_ check: (String, Bool) -> Void) {
        print("--- Live versus Final-only transcription/presentation ---")
        check("Power Mode has exactly the manual Live and Final-only choices",
              PowerMode.allCases == [.live, .finalOnly])
        check("Live schedules repeated partial transcription and uses the full HUD",
              PowerMode.live.partialTranscriptionInterval == 0.7 && !PowerMode.live.usesCompactHUD)
        check("Final-only schedules no partial transcription and uses the compact HUD",
              PowerMode.finalOnly.partialTranscriptionInterval == nil && PowerMode.finalOnly.usesCompactHUD)
        check("both modes share exactly one final STT pass at release",
              PowerMode.finalTranscriptionPassCount == 1)
    }

    private static func checkPowerCopy(_ check: (String, Bool) -> Void) {
        print("--- power copy ---")
        check("Live copy explains repeated held-take passes and the final release pass",
              PowerSettingsCopy.liveHint.contains("repeats partial transcription passes while the take is held")
                && PowerSettingsCopy.liveHint.contains("one final pass at release"))
        check("Final-only copy says the compact pill draws less power and why",
              PowerSettingsCopy.finalOnlyHint.contains("compact pill draws less power")
                && PowerSettingsCopy.finalOnlyHint.contains("skipping partial passes")
                && PowerSettingsCopy.finalOnlyHint.contains("one pass at release"))
        check("Models copy points to Appearance and says cloud providers move work off the laptop",
              PowerSettingsCopy.modelsIntro.contains("Appearance tab")
                && PowerSettingsCopy.modelsIntro.contains("Cloud providers move the work off this laptop"))
        check("status copy uses the Transcription behavior name",
              PowerSettingsCopy.status(for: .finalOnly)
                == "Transcription behavior set to Final-only. Provider choices were unchanged.")
    }

    private static func checkSettingsTabConsolidation(_ check: (String, Bool) -> Void) {
        print("--- Settings tab consolidation ---")
        let labels = SettingsTab.allCases.map(\.rawValue)
        check("Settings has one Appearance tab and no standalone Display tab",
              labels.filter { $0 == "Appearance" }.count == 1 && !labels.contains("Display"))
        check("Settings has one Hotkeys tab and no standalone Models tab",
              labels.filter { $0 == "Hotkeys" }.count == 1 && !labels.contains("Models"))
        check("Sticky Skills is exactly the third Settings tab",
              labels.filter { $0 == "Sticky Skills" }.count == 1
                && labels.firstIndex(of: "Sticky Skills") == 2)
        check("consolidation preserves every unrelated tab and their order",
              labels == ["Setup", "Hotkeys", "Sticky Skills", "Audio", "Appearance",
                         "Dictionary", "History", "Notes"])
    }

    private static func checkMigration(_ check: (String, Bool) -> Void, defaults: UserDefaults) {
        print("--- legacy Bool -> canonical sticky Power Mode migration ---")

        defaults.removeObject(forKey: "powerMode")
        defaults.set(true, forKey: "lowPowerMode")
        Settings.migrateLegacyPowerModeIfNeeded()
        check("legacy Low Power ON migrates to Final-only",
              Settings.powerMode == .finalOnly && defaults.string(forKey: "powerMode") == "finalOnly")
        check("the legacy Bool is removed after migration", defaults.object(forKey: "lowPowerMode") == nil)

        defaults.removeObject(forKey: "powerMode")
        defaults.set(false, forKey: "lowPowerMode")
        Settings.migrateLegacyPowerModeIfNeeded()
        check("legacy Low Power OFF migrates to Live",
              Settings.powerMode == .live && defaults.string(forKey: "powerMode") == "live")

        defaults.set("finalOnly", forKey: "powerMode")
        defaults.set(false, forKey: "lowPowerMode")
        Settings.migrateLegacyPowerModeIfNeeded()
        check("a valid canonical choice wins over stale legacy data",
              Settings.powerMode == .finalOnly && defaults.object(forKey: "lowPowerMode") == nil)

        defaults.set("future-invalid-value", forKey: "powerMode")
        defaults.removeObject(forKey: "lowPowerMode")
        Settings.migrateLegacyPowerModeIfNeeded()
        check("invalid persisted data safely canonicalizes to Live",
              Settings.powerMode == .live && defaults.string(forKey: "powerMode") == "live")
    }

    private static func checkManualStickyProviderIndependence(_ check: (String, Bool) -> Void,
                                                               defaults: UserDefaults) {
        print("--- manual/sticky selection and provider independence ---")
        Settings.promptPrepModel = "user-kept-local-p"
        Settings.promptPrepProvider = .local
        Settings.emailModel = "user-kept-local-m"
        Settings.emailProvider = .claude
        var legacy = ModelsPowerLegacyState.empty
        legacy.selectedBundles[.promptPrep] = .local("user-kept-local-p")
        legacy.selectedBundles[.email] = LLMProviderDefaults.currentClaudeSelection
        let routingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-power-routing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: routingURL) }
        let routing = ModelsPowerSettingsStore(url: routingURL, legacy: legacy)
        let pBefore = routing.selectedBundle(for: .promptPrep)
        let mBefore = routing.selectedBundle(for: .email)
        let fixedModels = (Settings.cleanupModel, Settings.searchModel, Settings.searchSynthModel)

        for mode in PowerMode.allCases {
            Settings.powerMode = mode
            check("\(mode.label): the manual Power Mode choice persists",
                  Settings.powerMode == mode && defaults.string(forKey: "powerMode") == mode.rawValue)
            check("\(mode.label): P/M keep their explicit Local/Claude provider choices",
                  routing.selectedBundle(for: .promptPrep) == pBefore
                    && routing.selectedBundle(for: .email) == mBefore
                    && pBefore.modelID == "user-kept-local-p"
                    && mBefore.provider == .claude
                    && mBefore.modelID == LLMProviderDefaults.currentClaudeSelection.modelID
                    && mBefore.effort == LLMProviderDefaults.currentClaudeSelection.effort)
            check("\(mode.label): cleanup and fixed L/G model defaults are unchanged",
                  (Settings.cleanupModel, Settings.searchModel, Settings.searchSynthModel) == fixedModels)
        }
    }

    private static func checkBatteryAdvisory(_ check: (String, Bool) -> Void) {
        print("--- pure battery advisory threshold and dismissal state machine ---")
        func evaluation(_ plugged: Bool?, _ percent: Int?, _ systemLowPower: Bool,
                        mode: PowerMode = .live,
                        dismissed: BatteryAdvisoryMaterialState? = nil) -> BatteryAdvisoryEvaluation {
            BatteryAdvisoryPolicy.evaluate(
                snapshot: BatterySnapshot(isPluggedIn: plugged, percentage: percent,
                                          macOSLowPowerMode: systemLowPower),
                powerMode: mode, dismissedFor: dismissed)
        }

        check("plugged in at 30% does not suggest Final-only", !evaluation(true, 30, false).shouldSuggest)
        check("unplugged at 31% does not suggest Final-only", !evaluation(false, 31, false).shouldSuggest)
        let threshold = evaluation(false, 30, false)
        check("unplugged at exactly 30% suggests Final-only", threshold.shouldSuggest && threshold.reason == .lowBattery)
        check("macOS Low Power Mode suggests even while plugged in",
              evaluation(true, 80, true).reason == .macOSLowPowerMode)
        check("both advisory causes are retained",
              evaluation(false, 20, true).reason == .lowBatteryAndMacOSLowPowerMode)
        check("Final-only never produces an advisory",
              !evaluation(false, 20, true, mode: .finalOnly).shouldSuggest)

        let dismissed = threshold.materialState
        let onePercentLater = evaluation(false, 29, false, dismissed: dismissed)
        check("dismissal survives non-material drain within the low-battery band",
              !onePercentLater.shouldSuggest && !onePercentLater.shouldClearDismissal)
        let recharged = evaluation(false, 31, false, dismissed: dismissed)
        check("crossing above 30% clears the dismissal without suggesting",
              !recharged.shouldSuggest && recharged.shouldClearDismissal)
        let unplugAgain = evaluation(false, 30, false, dismissed: recharged.materialState)
        check("crossing back to 30% makes a fresh suggestion eligible",
              unplugAgain.shouldSuggest && unplugAgain.shouldClearDismissal)
        let lpmChanged = evaluation(false, 29, true, dismissed: dismissed)
        check("macOS Low Power Mode changing is material and permits one fresh suggestion",
              lpmChanged.shouldSuggest && lpmChanged.shouldClearDismissal)
    }

    private static func checkDismissalPersistence(_ check: (String, Bool) -> Void) {
        print("--- dismissal persistence ---")
        let state = BatteryAdvisoryPolicy.evaluate(
            snapshot: BatterySnapshot(isPluggedIn: false, percentage: 30, macOSLowPowerMode: false),
            powerMode: .live, dismissedFor: nil).materialState
        Settings.batteryAdvisoryDismissedState = state
        check("material dismissal state round-trips canonically", Settings.batteryAdvisoryDismissedState == state)
        Settings.batteryAdvisoryDismissedState = nil
        check("dismissal can be cleared after a material state change", Settings.batteryAdvisoryDismissedState == nil)
    }
}
