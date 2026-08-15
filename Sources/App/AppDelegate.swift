import Cocoa

struct CloudPresetChange: Equatable {
    var route: LLMRouteID
    var fromModelID: String
    var toModelID: String
    var reason: LLMAutoUpdateReason
}

struct CloudUpdateCheckResult: Equatable {
    var checkedAt: String
    var claudeVersion: String?
    var aliasResolutions: [String: ModelFreshnessResolution]
    var codexVendoredVersion: String?
    var codexPinnedVersion: String
    var changes: [CloudPresetChange]
    var failures: [String]
    var claudeAvailability: LLMProviderAvailabilityState
}

final class CloudUpdateRuntimeState {
    static let shared = CloudUpdateRuntimeState()
    static let didChange = Notification.Name("VDCloudUpdateRuntimeDidChange")
    static let checkRequested = Notification.Name("VDCloudUpdateCheckRequested")

    private let lock = NSLock()
    private var storedLatest: CloudUpdateCheckResult?

    var latest: CloudUpdateCheckResult? {
        lock.lock()
        defer { lock.unlock() }
        return storedLatest
    }

    func publish(_ result: CloudUpdateCheckResult) {
        lock.lock()
        storedLatest = result
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

enum CloudUpdateSurface {
    static func provenanceBadge(bundle: LLMProviderBundle) -> String {
        if let update = bundle.autoUpdated {
            return "AUTO-UPDATED \(update.date) unratified"
        }
        if let ratified = bundle.ratified, ratified.modelID == bundle.modelID {
            return "RATIFIED \(ratified.modelID)"
        }
        if bundle.provider == .local { return "LOCAL \(bundle.modelID)" }
        return "UNRATIFIED \(bundle.modelID)"
    }

    /// Why a slate reads unratified, in the words a user can act on. One case per
    /// `LLMUnratifiedReason`, so a new reason cannot be added without landing here.
    static func unratifiedReasonText(_ reason: LLMUnratifiedReason) -> String {
        switch reason {
        case .noEvidence: return "no tested slate covers this choice"
        case .evidenceCoversAnotherModel: return "the tested slate covers a different model"
        case .promptOverridden: return "your prompt edit replaced the tested wording"
        }
    }

    /// The provenance row as a user reads it: the bundle's own badge plus every reason the DERIVED verdict
    /// gives for calling the slate unratified.
    ///
    /// `provenanceBadge` can only see the bundle, so it cannot see a prompt override - which meant a route
    /// whose bundle carried ratified evidence kept showing a green `RATIFIED` row after the user replaced
    /// the prompt bytes, while `ModelsPowerSettingsStore.ratificationState` said the opposite. Two answers
    /// to one question, and the wrong one was the one on screen. The badge stays the bundle's own fact and
    /// this composes it with the store's verdict, which is the authority on whether the evidence still
    /// covers what runs.
    static func provenanceRow(bundle: LLMProviderBundle,
                              ratification: LLMRatificationState) -> String {
        let badge = provenanceBadge(bundle: bundle)
        guard case .unratified(let reasons) = ratification else { return badge }
        // `noEvidence` is precisely what the badge's own UNRATIFIED / LOCAL wording already means, so
        // restating it would add a clause to every Local row without adding a fact. The other two are
        // invisible to a bundle-only badge, which is the whole reason this composition exists.
        let explained = reasons.filter { $0 != .noEvidence }
        guard !explained.isEmpty else { return badge }
        let listed = explained.map(unratifiedReasonText).joined(separator: "; ")
        // A bundle-shaped RATIFIED badge with an unratified verdict is exactly the disagreement above. The
        // verdict wins and the badge is restated as UNRATIFIED, because appending a reason to the word
        // RATIFIED would leave the row's own headline claiming the opposite of its explanation.
        guard badge.hasPrefix("RATIFIED") else { return "\(badge) - \(listed)" }
        return "UNRATIFIED \(bundle.modelID) - \(listed)"
    }

    static func lastCheckedText(cache: ModelFreshnessCache?) -> String {
        "Cloud presets: last checked \(cache?.checkedAt ?? "never")"
    }

    static func toastLines(for result: CloudUpdateCheckResult) -> [String] {
        guard requiresFullToast(result) else { return ["Cloud presets up to date"] }
        let changes = result.changes.sorted { $0.route.rawValue < $1.route.rawValue }.map { change in
            "\(routeName(change.route)) -> \(change.toModelID) (unratified - auto-updated)"
        }
        return changes + result.failures
    }

    static func requiresFullToast(_ result: CloudUpdateCheckResult) -> Bool {
        !result.changes.isEmpty || !result.failures.isEmpty
    }

    static func providerLiveStatus(_ provider: LLMProvider,
                                   latest: CloudUpdateCheckResult?,
                                   cache: ModelFreshnessCache?,
                                   codexOutcome: CodexUpdateOutcomeRecord? = nil,
                                   codexAvailability: LLMProviderAvailabilityState = .disconnected)
        -> String? {
        switch provider {
        case .local:
            return nil
        case .claude:
            let resolutions = latest?.aliasResolutions ?? cache?.resolutions ?? [:]
            let resolved = ModelFreshnessProbe.aliases.compactMap { alias -> String? in
                guard let value = resolutions[alias], value.state == .resolved,
                      let modelID = value.modelID else { return nil }
                return "\(alias) -> \(modelID)"
            }
            if !resolved.isEmpty {
                let prefix = latest?.claudeVersion.map { "Live \($0):" } ?? "Last probe:"
                return "\(prefix) \(resolved.joined(separator: ", "))"
            }
            if latest != nil || cache != nil { return "Live: alias probe failed" }
            return "Live: not checked"
        case .codex:
            if codexOutcome?.state == .compatibilityQuarantinePending {
                return "Live: compatibility quarantine pending"
            }
            if codexOutcome?.state == .compatibilityQuarantineFailed {
                return "Live: compatibility quarantine failed"
            }
            guard let latest = latest else { return "Live: not checked" }
            guard let vendored = latest.codexVendoredVersion else {
                return "Live: vendored CLI unavailable"
            }
            let compatible: Bool
            switch codexAvailability {
            case .available:
                compatible = true
            case .disconnected, .unavailable:
                compatible =
                    codexOutcome?.state == .compatibilityQuarantinePassed
                    || codexOutcome?.lastSuccessfulCatalogTime != nil
            }
            if vendored == latest.codexPinnedVersion {
                return compatible
                    ? "Live: compatible reviewed CLI"
                    : "Live: reviewed CLI; compatibility not established"
            }
            return compatible
                ? "Live: compatible newer CLI \(vendored)"
                : "Live: newer CLI awaiting compatibility quarantine"
        }
    }

    static func routeName(_ route: LLMRouteID) -> String {
        switch route {
        case .cleanupL1: return "cleanup L1"
        case .cleanupL2: return "cleanup L2"
        case .cleanupL3: return "cleanup L3"
        case .promptPrep: return "prompt prep"
        case .email: return "email"
        case .searchLocalSynth: return "local search synthesis"
        case .searchGeminiSynth: return "Gemini search synthesis"
        case .custom(let id): return "custom \(id)"
        }
    }
}

enum CloudUpdateChecker {
    private static let versionTimeout: TimeInterval = 5
    private static let versionCaptureLimit = 65_536

    static func run(settings: ModelsPowerSettingsStore = Settings.modelsPower,
                    claudeSource: ModelCatalogSource = ClaudeModelCatalogSource())
        -> CloudUpdateCheckResult {
        let checkedAt = ModelFreshnessProbe.checkedAtString(Date())
        var failures: [String] = []
        func fail(_ message: String) {
            if !failures.contains(message) { failures.append(message) }
        }

        let claudeBinary = CloudCleanupClient.resolveBinary()
        let claudeConnection = LLMProviderDetection.observeClaude(binary: claudeBinary).state
        let claudeVersion = claudeBinary.flatMap { version(executable: $0) }
        if claudeBinary == nil { fail("Claude: CLI unavailable") }
        switch claudeConnection {
        case .available:
            break
        case .disconnected:
            fail("Claude: signed out")
        case .unavailable(let reason):
            fail("Claude: \(reason)")
        }
        if claudeBinary != nil && claudeVersion == nil { fail("Claude: CLI version check failed") }

        let routes = settings.routeIDs().compactMap { route -> PresetUpdateRoute? in
            guard let bundle = settings.rememberedBundle(for: .claude, route: route) else { return nil }
            return PresetUpdateRoute(route: route, bundle: bundle)
        }
        var cache: ModelFreshnessCache
        do {
            cache = try ModelFreshnessProbe.probeAliases(at: Date(), binary: claudeBinary)
        } catch {
            let failed = Dictionary(uniqueKeysWithValues: ModelFreshnessProbe.aliases.map {
                ($0, ModelFreshnessResolution.failed("cache-write"))
            })
            cache = ModelFreshnessCache(checkedAt: checkedAt, resolutions: failed)
            fail("Claude: freshness results could not be saved")
        }

        let aliasFailures = ModelFreshnessProbe.aliases.filter {
            cache.resolutions[$0]?.state != .resolved
        }
        for alias in aliasFailures {
            let kind = cache.resolutions[alias]?.failureKind ?? "no-result"
            fail("Claude \(alias): live probe failed (\(kind))")
        }
        let claudeAvailability = LLMProviderDetection.claudeState(
            connectionState: claudeConnection,
            versionResolved: claudeVersion != nil,
            aliasProbeFailed: !aliasFailures.isEmpty)

        // ADR 0014 retirement detection for Claude: the catalog, not the alias probe.
        let refreshed = claudeSource.discover(checkedAt: checkedAt)
        let migration: [LLMRouteID: ModelMigrationAction]
        if !refreshed.isStale, refreshed.diagnostic == .current, let catalog = refreshed.catalog {
            migration = migrationActions(
                routes: routes, catalog: catalog, source: claudeSource)
        } else {
            migration = [:]
            fail("Claude: model catalog unavailable (\(refreshed.diagnostic.rawValue))")
        }

        let decisions = PresetUpdatePolicy.decide(
            routes: routes, checkedAt: checkedAt, migration: migration)
        var changes: [CloudPresetChange] = []
        for decision in decisions {
            switch decision.disposition {
            case .swapped(let reason):
                switch applyIfUnchanged(decision, settings: settings) {
                case .applied:
                    changes.append(CloudPresetChange(
                        route: decision.route,
                        fromModelID: decision.originalBundle.modelID,
                        toModelID: decision.resultingBundle.modelID,
                        reason: reason))
                case .changed:
                    fail("\(CloudUpdateSurface.routeName(decision.route)): settings changed during check - update not applied")
                case .failed:
                    fail("\(CloudUpdateSurface.routeName(decision.route)): auto-update could not be saved")
                }
            case .held(let reason):
                fail("\(CloudUpdateSurface.routeName(decision.route)): \(decision.originalBundle.modelID) not judged by the Claude catalog (\(reason.rawValue))")
            case .unchanged, .catalogUnavailable, .codexDetectOnly:
                break
            }
        }
        do { try ModelFreshnessProbe.save(cache) }
        catch { fail("Cloud presets: final check results could not be saved") }

        let codexPinned = CodexIsolationFoundation.pinnedCLIVersion
        let codexVendored = FileManager.default.isExecutableFile(
            atPath: CodexIsolationFoundation.codexBinary)
            ? version(executable: CodexIsolationFoundation.codexBinary) : nil
        if codexVendored == nil { fail("Codex: vendored CLI unavailable") }

        return CloudUpdateCheckResult(
            checkedAt: cache.checkedAt,
            claudeVersion: claudeVersion,
            aliasResolutions: Dictionary(uniqueKeysWithValues: ModelFreshnessProbe.aliases.compactMap {
                alias in cache.resolutions[alias].map { (alias, $0) }
            }),
            codexVendoredVersion: codexVendored,
            codexPinnedVersion: codexPinned,
            changes: changes,
            failures: failures,
            claudeAvailability: claudeAvailability)
    }

    private static func version(executable: String) -> String? {
        boundedVersion(executable: executable, timeout: versionTimeout)
    }

    private static func boundedVersion(executable: String, timeout: TimeInterval) -> String? {
        guard let run = CloudCleanupClient.runProcessForTest(
                executable: executable, arguments: ["--version"], timeout: timeout),
              !run.timedOut, !run.terminatedBySignal, run.exitCode == 0,
              CloudCleanupClient.processGroupExitWasClean(
                leaderReaped: run.leaderReaped,
                residualProcessGroup: run.residualProcessGroup),
              run.stdout.count <= versionCaptureLimit,
              run.stderr.count <= versionCaptureLimit else { return nil }
        let data = run.stdout + run.stderr
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

#if SELFTEST
    static func versionForTest(executable: String, timeout: TimeInterval) -> String? {
        boundedVersion(executable: executable, timeout: timeout)
    }
#endif

    /// Correlate the seam's index-keyed plan back onto routes. The planner is deliberately
    /// content-free and returns `inputIndex` as its only route correlation, so this is the one place
    /// the two orderings have to agree; it is a pure function precisely so a fixture can prove they do.
    static func migrationActions(routes: [PresetUpdateRoute],
                                 catalog: ModelCatalog,
                                 source: ModelCatalogSource) -> [LLMRouteID: ModelMigrationAction] {
        let claudeRoutes = routes.filter { $0.bundle.provider == .claude }
        let plan = source.plan(
            requests: claudeRoutes.map {
                ModelMigrationRequest(model: $0.bundle.modelID, effort: $0.bundle.effort)
            },
            catalog: catalog)
        var actions: [LLMRouteID: ModelMigrationAction] = [:]
        for decision in plan.decisions where claudeRoutes.indices.contains(decision.inputIndex) {
            actions[claudeRoutes[decision.inputIndex].route] = decision.action
        }
        return actions
    }

    private enum ApplyResult { case applied, changed, failed }

    /// UI settings mutations are main-thread gestures. Compare and write in one main-queue block so a
    /// long provider smoke can never overwrite a route that the user edited while the check was running.
    private static func applyIfUnchanged(_ decision: PresetUpdateDecision,
                                         settings: ModelsPowerSettingsStore) -> ApplyResult {
        let body = { () -> ApplyResult in
            guard settings.rememberedBundle(for: .claude, route: decision.route)
                    == decision.originalBundle else { return .changed }
            do {
                try settings.setRememberedBundle(
                    decision.resultingBundle, for: .claude, route: decision.route)
                return .applied
            } catch {
                return .failed
            }
        }
        return Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLabel = NSMenuItem(title: "Dictation: starting…", action: nil, keyEquivalent: "")
    private let cleanupLabel = NSMenuItem(title: "Cleanup mode: OFF", action: nil, keyEquivalent: "")
    private let finalOnlyItem = NSMenuItem(title: "Power Mode: Final-only", action: #selector(toggleFinalOnly), keyEquivalent: "")
    private let pathClassifier = PathClassifier()
    private let pathClassifierBackupStore = PathClassifierBackupStore()
    /// The controller and its notes collaborator are constructed as one required wiring graph. Every callback
    /// below except the deliberately optional search-result note hook is compiler-enforced by its init bundle.
    private lazy var controller: DictationController = {
        let notesDelivery = NotesDeliveryCoordinator(callbacks: NotesDeliveryCallbacks(
            // BT1: snapshot the note target at take-start and deliver back to it by id even if focus moved.
            onSnapshotNoteTarget: { [weak self] generation in
                self?.notesRegistry.snapshotDictationTarget(generation: generation)
            },
            onDeliverToNoteTarget: { [weak self] target, text in
                self?.notesRegistry.deliverToTarget(target, text: text) ?? .noWindow
            },
            onInsertIntoActiveNote: { [weak self] text in
                self?.notesRegistry.insertIntoKeyWindow(text) ?? .noWindow
            },
            // BT2: Option+N can set the bullseye, whose delivery remains focus-independent.
            onSetBullseyeAtCaret: { [weak self] in self?.notesRegistry.setBullseyeAtCaret() },
            onDeliverToBullseye: { [weak self] text in
                self?.notesRegistry.deliverToBullseye(text: text) ?? .noWindow
            },
            // BT3: a bullseye toggle or delivery-time drop refreshes every inline marker.
            onBullseyeStateChanged: { [weak self] in self?.notesRegistry.broadcastBullseyeState() },
            // BT6: Option+Shift+N reveals where the bullseye is (front + select tab + arm + scroll to it).
            onRevealBullseye: { [weak self] in self?.notesRegistry.revealBullseye() ?? .noneSet },
            // BT4: resolve, show/update, and clear the four-color replace highlight by note id.
            onResolveReplaceHighlightTarget: { [weak self] in
                self?.notesRegistry.replaceHighlightTargetNoteId()
            },
            onShowReplaceHighlight: { [weak self] id, level, generation in
                self?.notesRegistry.showReplaceHighlight(
                    noteId: id, level: level, generation: generation)
            },
            onClearReplaceHighlight: { [weak self] id in
                self?.notesRegistry.clearReplaceHighlight(noteId: id)
            },
            // BT5: note delivery undo/retry and the key window's active note id.
            onUndoNoteDelivery: { [weak self] id in
                self?.notesRegistry.undoNoteDelivery(noteId: id) ?? false
            },
            onReplaceNoteDelivery: { [weak self] id, text in
                self?.notesRegistry.replaceNoteDelivery(noteId: id, text: text) ?? false
            },
            onCurrentNoteId: { [weak self] in self?.notesRegistry.currentActiveNoteId() }
        ))
        let controller = DictationController(
            callbacks: DictationControllerCallbacks(
                onStateChange: { [weak self] state in
                    DispatchQueue.main.async { self?.statusLabel.title = "Dictation: \(state)" }
                },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onOpenDictionary: { [weak self] in self?.openDictionarySettings() },
                onOpenNotes: { [weak self] in self?.openNotes() },
                notesWindowIsKey: { [weak self] in self?.notesRegistry.isAnyKey == true },
                onCleanupModeChange: { [weak self] enabled in
                    DispatchQueue.main.async { self?.updateCleanupIndicator(enabled) }
                }
            ),
            notesDelivery: notesDelivery
        )
        // Search is intentionally optional: OneShotRegistry falls back to a read-only HUD answer when absent.
        controller.onOpenSearchResultNote = { [weak self] question, answer in
            self?.notesRegistry.openSearchResult(question: question, answer: answer)
        }
        return controller
    }()
    private lazy var settingsWC = SettingsWindowController()
    /// First-run provider onboarding (item P9). Built lazily, so a machine that already has a provider never
    /// constructs it. Its own re-check records the same "has ever been satisfied" fact, so signing in from the
    /// window is what retires it rather than the window having been shown.
    private lazy var onboardingWC: ProviderOnboardingWindowController = {
        let controller = ProviderOnboardingWindowController()
        controller.onMeasured = { [weak self] plan in self?.recordOnboardingOutcome(plan) }
        return controller
    }()
    private var batteryAdvisoryTimer: Timer?
    private var powerStateToken: NSObjectProtocol?
    private var writeFailureToken: NSObjectProtocol?
    private var cloudCheckRequestToken: NSObjectProtocol?
    private var cloudCheckIdleToken: NSObjectProtocol?
    private var codexAutoCheckToken: NSObjectProtocol?
    private var codexClockChangeToken: NSObjectProtocol?
    private var codexQuarantineToken: NSObjectProtocol?
    private var codexQuarantineFinishedToken: NSObjectProtocol?
    private var codexScheduleTimer: Timer?
    private let codexSchedule = CodexModelUpdateSchedule()
    private var codexScheduledToastGate = CodexScheduledToastGate()
    private var cloudCheckInFlight = false
    private var pendingCloudCheck: CloudCheckTrigger?
    private enum CloudCheckTrigger { case manual, automatic }
    // Multi-window Sticky Notes registry (L6): owns the primary + any secondary notes
    // windows. Retires the old singleton NotesWindowController.
    private lazy var notesRegistry: NotesWindowRegistry = {
        let registry = NotesWindowRegistry()
        registry.onMarkdownFileRequest = { [weak self] url, windowId in
            self?.routeOpenedPath(url, preferredWindowId: windowId)
        }
        return registry
    }()
    // Loopback control endpoint for the Sticky Notes toolset. Binds 127.0.0.1
    // only; the "open" target + list active-flag resolve against the live registry on the main thread, and
    // L2 content writes push their live-render intent through the registry on the main thread.
    private lazy var notesControlServer = NotesControlServer(
        store: .shared,
        activeNoteId: { [weak self] in
            guard let self = self else { return nil }
            if Thread.isMainThread { return self.notesRegistry.currentActiveNoteId() }
            return DispatchQueue.main.sync { self.notesRegistry.currentActiveNoteId() }
        },
        renderSink: { [weak self] intent in
            guard let self = self else { return .persistedOnly }
            if Thread.isMainThread { return self.notesRegistry.renderExternalWrite(intent) }
            return DispatchQueue.main.sync { self.notesRegistry.renderExternalWrite(intent) }
        })

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldRunThisInstance() else {
            NSApplication.shared.terminate(nil)
            return
        }
        setupMenu()
        setupEditMenu()
        _ = controller   // Force the lazy required-callback graph before any controller-dependent setup.
        // Re-bless the stable signing identity if a macOS update wiped trust settings (background,
        // never main-thread). Keeps future builds from ever ad-hoc-signing and voiding TCC grants.
        SigningTrustGuard.healIfNeeded()
        codexQuarantineToken = NotificationCenter.default.addObserver(
            forName: CodexProviderRuntime.compatibilityQuarantineWillBegin,
            object: nil,
            queue: .main
        ) { _ in
            CodexUpdateOutcomeStore.shared.markCompatibilityQuarantinePending(
                at: ModelFreshnessProbe.checkedAtString(Date()))
        }
        codexQuarantineFinishedToken = NotificationCenter.default.addObserver(
            forName: CodexProviderRuntime.compatibilityQuarantineDidFinish,
            object: nil,
            queue: .main
        ) { note in
            guard let success = (note.object as? NSNumber)?.boolValue else {
                return
            }
            CodexUpdateOutcomeStore.shared.markCompatibilityQuarantineFinished(
                success: success,
                at: ModelFreshnessProbe.checkedAtString(Date()))
        }
        // Status is established only from ViddyDictate's audited dedicated CODEX_HOME. This is a
        // background inventory/login-status check; it never starts login or a model call.
        CodexConnectionController.shared.refreshAvailability()
        writeFailureToken = NotificationCenter.default.addObserver(
            forName: UserDataWriteFailureCenter.didReport, object: nil, queue: .main) { [weak self] note in
                guard let failure = note.userInfo?[UserDataWriteFailureCenter.notificationKey]
                        as? UserDataWriteFailure else { return }
                self?.statusLabel.title = "Dictation: save failed — \(failure.subsystem)"
                self?.controller.hud.toast("⚠️ \(failure.userMessage)", duration: 8, forceFull: true)
            }
        ClipboardHistory.shared.startMonitoring()
        // Model residency needs no launch-time arming: LM Studio owns eviction via the per-model TTL
        // set on each `ensureReady` load (interop ADR 0004, reversing ADR 0006's app-side idle timer),
        // and the LM Studio server is started lazily on the first load. See docs/model-residency.md.
        // The registry owns this inverse notification; it is not one of the controller/coordinator contracts.
        notesRegistry.onBullseyeAutoDisarmed = { [weak self] in self?.controller.handleBullseyeAutoDisarmed() }
        // Hotkey rebinding: the Settings Hotkeys tab drives capture through the controller (tap owner).
        settingsWC.onBeginHotkeyCapture = { [weak self] onCap, onCancel in
            self?.controller.beginHotkeyCapture(onCapture: onCap, onCancel: onCancel)
        }
        settingsWC.onCancelHotkeyCapture = { [weak self] in self?.controller.cancelHotkeyCapture() }
        settingsWC.onHotkeysChanged = { [weak self] in self?.controller.reloadHotkeys() }
        settingsWC.onPowerModeChanged = { [weak self] in
            self?.finalOnlyItem.state = Settings.powerMode == .finalOnly ? .on : .off
            self?.evaluateBatteryAdvisory()
        }
        configureCloudUpdateChecks()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Bring up the loopback Sticky Notes control endpoint inside the live process.
        if let port = notesControlServer.start() {
            Log.write("notes-control: listening on 127.0.0.1:\(port)")
        } else {
            Log.write("notes-control: FAILED to bind a loopback port (8766..) — control endpoint unavailable")
        }
        requestPermissions()
        startBatteryAdvisoryMonitoring()
        presentFirstRunOnboardingIfNeeded()
    }

    /// First-run provider onboarding (Public V1 spec W4, item P9).
    ///
    /// Gated on the persisted "a provider has been ready at least once" fact BEFORE measuring, so a machine
    /// that is already set up pays nothing at launch: no Codex boundary audit, no LM Studio probe, no daemon
    /// request beyond what launch already does. That is also why this is not a general launch-time preflight -
    /// the re-runnable Setup tab owns reporting, and this owns only the one-time sign-in.
    ///
    /// It never blocks (W5): the window is ordinary and closable, and the app is fully running behind it.
    private func presentFirstRunOnboardingIfNeeded() {
        guard !Settings.providerOnboardingSatisfied else { return }
        Preflight.observe { observation in
            let plan = ProviderOnboarding.plan(providers: observation.providers)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Already set up on first launch, which is the common case for the audience this ships to
                // (locked decision 2: every user arrives holding Claude Code or Codex). Recorded first, so the
                // presentation rule below reads the same fact a later launch would.
                self.recordOnboardingOutcome(plan)
                guard ProviderOnboarding.shouldPresentFirstRun(
                    hasEverBeenSatisfied: Settings.providerOnboardingSatisfied, plan: plan) else {
                    Log.write("first-run onboarding: not shown - \(plan.logToken)")
                    return
                }
                self.onboardingWC.show()
            }
        }
    }

    private func recordOnboardingOutcome(_ plan: ProviderOnboarding.Plan) {
        guard plan.isSatisfied, !Settings.providerOnboardingSatisfied else { return }
        Settings.providerOnboardingSatisfied = true
    }

    /// Finder, Open With, drag-to-app, and `open -a` all converge here. Each URL is independently
    /// classified inside the app; LaunchServices is registration, not the privacy boundary.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            routeOpenedPath(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard notesRegistry.prepareForApplicationTermination() else {
            controller.hud.toast(
                "Resolve the file conflict, then quit again.", duration: 8, forceFull: true)
            return .terminateCancel
        }
        return .terminateNow
    }

    private func routeOpenedPath(_ url: URL, preferredWindowId: String? = nil) {
        let classification = pathClassifier.classification(for: url)
        let decision = classification.decision
        if decision == .refuseDeniedRoot {
            // Never log the refused path: its filename is itself Private-vault metadata.
            Log.write("files-router: REFUSED denied-root open")
            controller.hud.toast(
                "🔒 Private vault files are refused.", duration: 8)
            return
        }

        // The document claim is intentionally .md-only. Classification still ran first so every handed
        // path crosses the privacy boundary even when `open -a` bypasses LaunchServices filtering.
        guard classification.resolvedURL.isFileURL,
              classification.resolvedURL.pathExtension.lowercased() == "md" else {
            Log.write("files-router: ignored unsupported non-.md URL")
            return
        }

        do {
            _ = try pathClassifierBackupStore.backup(classification.resolvedURL)
        } catch {
            Log.write("files-router: backup failed; open stopped — \(error.localizedDescription)")
            controller.hud.toast(
                "⚠️ Markdown backup failed; file was not opened.", duration: 8)
            return
        }

        switch decision {
        case .refuseDeniedRoot:
            assertionFailure("Denied-root opens must return before backup")
        case .readOnlyVault, .readOnlyFailClosed, .readWriteLoose:
            do {
                let opened = try notesRegistry.openFileBackedNote(
                    at: classification.resolvedURL, preferredWindowId: preferredWindowId)
                if opened.focusedExisting {
                    Log.write("files-router: focused existing file-backed tab")
                } else if decision == .readOnlyFailClosed {
                    Log.write("files-router: opened file-backed tab READ-ONLY (FAIL CLOSED)")
                    controller.hud.toast(
                        "🔒 Vault status is ambiguous; opened read-only.", duration: 8)
                } else {
                    Log.write("files-router: opened file-backed tab")
                }
            } catch {
                Log.write("files-router: file-backed open failed — \(error.localizedDescription)")
                controller.hud.toast(
                    "⚠️ Could not open this markdown file.", duration: 8)
            }
        }
    }

    private func shouldRunThisInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let current = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current }
        if !others.isEmpty {
            Log.write("duplicate app instance detected — exiting pid=\(current)")
            return false
        }
        return true
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "ViddyDictate")
            b.image?.isTemplate = true
        }
        let menu = NSMenu()
        statusLabel.isEnabled = false
        cleanupLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(cleanupLabel)
        menu.addItem(.separator())
        finalOnlyItem.state = Settings.powerMode == .finalOnly ? .on : .off
        menu.addItem(finalOnlyItem)
        menu.addItem(NSMenuItem(title: "Check for cloud updates...",
                                action: #selector(checkCloudUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Sticky Notes", action: #selector(openNotes), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ViddyDictate", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu

    }

    /// Install an application Edit menu so text fields get the standard editing shortcuts.
    /// An accessory (menu-bar-only) app has no main menu by default, so Cmd+V / C / X / A / Z have no
    /// key equivalent and never reach the focused field editor — typing works but paste silently no-ops
    /// (the Settings Dictionary fields, the History count field). The menu bar stays hidden for an
    /// accessory app; only the key equivalents matter. Items target nil = the first responder (the
    /// field editor), which implements cut:/copy:/paste:/selectAll: and undo:/redo:.
    private func setupEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// Persistent "Cleanup is ON" indicator: a green dot beside the menubar mic plus a menu line, so
    /// the user always knows whether the next dictation will be cleaned.
    private func updateCleanupIndicator(_ on: Bool) {
        cleanupLabel.title = "Cleanup mode: \(on ? "ON" : "OFF")"
        guard let b = statusItem.button else { return }
        if on {
            b.attributedTitle = NSAttributedString(string: " ●", attributes: [
                .foregroundColor: NSColor(srgbRed: 0, green: 0.85, blue: 0.30, alpha: 1),
                .font: NSFont.systemFont(ofSize: 9),
            ])
        } else {
            b.attributedTitle = NSAttributedString(string: "")
        }
    }

    @objc private func requestPermissions() {
        let ax = Permissions.accessibility(prompt: true)
        let im = Permissions.inputMonitoring(prompt: true)
        Permissions.microphone { granted in Log.write("mic permission granted=\(granted)") }
        Log.write("perms ax=\(ax) im=\(im)")
        if ax && im {
            startController()
        } else {
            statusLabel.title = "Dictation: grant Accessibility + Input Monitoring, then relaunch"
        }
    }

    private func startController() {
        if controller.startMonitoring() {
            statusLabel.title = "Dictation: \(controller.readyHint)"
            Log.write("monitoring started — tap live")
        } else {
            statusLabel.title = "Dictation: key tap failed — grant Input Monitoring + relaunch"
            Log.write("TAP CREATE FAILED")
        }
    }

    /// Menubar Power Mode toggle — manual/sticky and independent of provider/model selection.
    @objc private func toggleFinalOnly() {
        Settings.powerMode = Settings.powerMode == .live ? .finalOnly : .live
        finalOnlyItem.state = Settings.powerMode == .finalOnly ? .on : .off
        settingsWC.refreshPowerModeSwitch()
        Log.write("menubar: power mode -> \(Settings.powerMode.label)")
        evaluateBatteryAdvisory()
    }

    private func startBatteryAdvisoryMonitoring() {
        powerStateToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.evaluateBatteryAdvisory()
            }
        batteryAdvisoryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateBatteryAdvisory()
        }
        DispatchQueue.main.async { [weak self] in self?.evaluateBatteryAdvisory() }
    }

    private func evaluateBatteryAdvisory() {
        // Never interrupt an active take. The next timer/wake/power-state event can present it when idle.
        guard !Settings.isDictationActive else { return }
        let evaluation = BatteryAdvisoryPolicy.evaluate(
            snapshot: SystemBatteryReader.current(), powerMode: Settings.powerMode,
            dismissedFor: Settings.batteryAdvisoryDismissedState)
        if evaluation.shouldClearDismissal { Settings.batteryAdvisoryDismissedState = nil }
        guard evaluation.shouldSuggest, let reason = evaluation.reason else { return }

        // Recording the material state at presentation makes the auto-dismissing toast a one-shot advisory.
        // It becomes eligible again only after plug/unplug, threshold crossing, or macOS Low Power change.
        Settings.batteryAdvisoryDismissedState = evaluation.materialState
        Log.write("battery advisory: shown reason=\(reason)")
        controller.hud.toast(reason.message, duration: 8, forceFull: true)
    }

    private func configureCloudUpdateChecks() {
        hydrateClaudeAvailability()
        codexSchedule.launched(
            enabled: Settings.cloudUpdateAutoCheck,
            now: Date().timeIntervalSince1970)
        cloudCheckRequestToken = NotificationCenter.default.addObserver(
            forName: CloudUpdateRuntimeState.checkRequested, object: nil, queue: .main
        ) { [weak self] _ in self?.requestCloudUpdateCheck(.manual) }
        cloudCheckIdleToken = NotificationCenter.default.addObserver(
            forName: Settings.dictationActive, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? NSNumber)?.boolValue == false,
                  let self = self else { return }
            if let pending = self.pendingCloudCheck {
                self.pendingCloudCheck = nil
                self.requestCloudUpdateCheck(pending)
            }
            self.codexSchedule.becameIdle(now: Date().timeIntervalSince1970)
            self.armCodexScheduleTimer()
        }
        codexAutoCheckToken = NotificationCenter.default.addObserver(
            forName: Settings.cloudUpdateAutoCheckDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let enabled = (note.object as? NSNumber)?.boolValue else { return }
            self.codexSchedule.setEnabled(
                enabled, now: Date().timeIntervalSince1970)
            self.armCodexScheduleTimer()
        }
        codexClockChangeToken = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.codexSchedule.clockChanged(now: Date().timeIntervalSince1970)
            self.armCodexScheduleTimer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard Settings.cloudUpdateAutoCheck else { return }
            self?.requestCloudUpdateCheck(.automatic)
        }
    }

    private func hydrateClaudeAvailability() {
        let measured = LLMProviderDetection.observeClaude()
        guard measured.state.canRun else {
            Settings.modelsPower.setAvailabilityState(measured.state, for: .claude)
            return
        }
        if let cache = ModelFreshnessProbe.loadCache(),
           ModelFreshnessProbe.aliases.contains(where: {
               cache.resolutions[$0]?.state != .resolved
           }) {
            Settings.modelsPower.setAvailabilityState(
                .unavailable("last live alias probe failed"), for: .claude)
        }
    }

    @objc private func checkCloudUpdates() {
        requestCloudUpdateCheck(.manual)
    }

    private func requestCloudUpdateCheck(_ trigger: CloudCheckTrigger) {
        if case .automatic = trigger, !Settings.cloudUpdateAutoCheck { return }
        if Settings.isDictationActive {
            if trigger == .manual || pendingCloudCheck == nil { pendingCloudCheck = trigger }
            if trigger == .manual {
                controller.hud.toast("Cloud update check queued until dictation is idle")
            }
            return
        }
        if cloudCheckInFlight {
            if trigger == .manual { pendingCloudCheck = .manual }
            return
        }
        cloudCheckInFlight = true
        CodexUpdateOutcomeStore.shared.beginAttempt(
            at: ModelFreshnessProbe.checkedAtString(Date()),
            nextRetry: codexNextRetryText())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = CloudUpdateChecker.run()
            let codexOutcome = CodexModelUpdater.shared.run()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cloudCheckInFlight = false
                self.completeCodexUpdate(codexOutcome)
                Settings.modelsPower.setAvailabilityState(
                    result.claudeAvailability, for: .claude)
                CloudUpdateRuntimeState.shared.publish(result)
                let cloudFull = CloudUpdateSurface.requiresFullToast(result)
                let codexFull = CodexUpdateSurface.requiresFullToast(codexOutcome)
                if trigger == .manual || cloudFull || codexFull {
                    var lines: [String] = []
                    if trigger == .manual || cloudFull {
                        lines.append(contentsOf: CloudUpdateSurface.toastLines(for: result))
                    }
                    lines.append(contentsOf: CodexUpdateSurface.toastLines(for: codexOutcome))
                    let full = cloudFull || codexFull
                    self.controller.hud.toast(
                        lines.joined(separator: "\n"),
                        duration: full ? 10 : 5, forceFull: full)
                }
                if let pending = self.pendingCloudCheck, !Settings.isDictationActive {
                    self.pendingCloudCheck = nil
                    self.requestCloudUpdateCheck(pending)
                }
            }
        }
    }

    private func armCodexScheduleTimer() {
        codexScheduleTimer?.invalidate()
        codexScheduleTimer = nil
        guard let next = codexSchedule.nextCheckAt else { return }
        let delay = max(0.01, next - Date().timeIntervalSince1970)
        codexScheduleTimer = Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { [weak self] _ in
            self?.runDueCodexScheduledCheck()
        }
    }

    private func runDueCodexScheduledCheck() {
        let now = Date().timeIntervalSince1970
        guard codexSchedule.takeDue(
            now: now, isIdle: !Settings.isDictationActive) else {
            armCodexScheduleTimer()
            return
        }
        CodexUpdateOutcomeStore.shared.beginAttempt(
            at: ModelFreshnessProbe.checkedAtString(Date()),
            nextRetry: codexNextRetryText())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = CodexModelUpdater.shared.run()
            DispatchQueue.main.async {
                guard let self else { return }
                let record = self.completeCodexUpdate(outcome)
                if self.codexScheduledToastGate.shouldPresentFullToast(
                    for: outcome,
                    record: record
                ) {
                    self.controller.hud.toast(
                        CodexUpdateSurface.toastLines(for: outcome)
                            .joined(separator: "\n"),
                        duration: 10,
                        forceFull: true)
                }
            }
        }
    }

    @discardableResult
    private func completeCodexUpdate(
        _ outcome: CodexModelUpdateOutcome
    ) -> CodexUpdateOutcomeRecord {
        codexSchedule.completed(
            outcome.scheduleCompletion,
            now: Date().timeIntervalSince1970)
        armCodexScheduleTimer()
        return CodexUpdateOutcomeStore.shared.complete(
            outcome, nextRetry: codexNextRetryText())
    }

    private func codexNextRetryText() -> String? {
        codexSchedule.nextCheckAt.map {
            ModelFreshnessProbe.checkedAtString(Date(timeIntervalSince1970: $0))
        }
    }

    @objc private func openSettings() { settingsWC.show() }

    private func openDictionarySettings() { settingsWC.show(tab: .dictionary) }

    @objc private func openNotes() { notesRegistry.show() }

    @objc private func didWake() {
        controller.handleWake()
        evaluateBatteryAdvisory()
        codexSchedule.woke(now: Date().timeIntervalSince1970)
        armCodexScheduleTimer()
        // A revoked Accessibility/Input-Monitoring grant after wake looks like a dead app; surface it.
        let ax = Permissions.accessibility(prompt: false)
        let im = Permissions.inputMonitoring(prompt: false)
        if !(ax && im) {
            DispatchQueue.main.async {
                self.statusLabel.title = "Dictation: permission lost — re-grant Accessibility + Input Monitoring"
            }
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    deinit {
        batteryAdvisoryTimer?.invalidate()
        if let token = powerStateToken { NotificationCenter.default.removeObserver(token) }
        if let token = writeFailureToken { NotificationCenter.default.removeObserver(token) }
        if let token = cloudCheckRequestToken { NotificationCenter.default.removeObserver(token) }
        if let token = cloudCheckIdleToken { NotificationCenter.default.removeObserver(token) }
        if let token = codexAutoCheckToken { NotificationCenter.default.removeObserver(token) }
        if let token = codexClockChangeToken { NotificationCenter.default.removeObserver(token) }
        if let token = codexQuarantineToken { NotificationCenter.default.removeObserver(token) }
        if let token = codexQuarantineFinishedToken {
            NotificationCenter.default.removeObserver(token)
        }
        codexScheduleTimer?.invalidate()
    }
}
