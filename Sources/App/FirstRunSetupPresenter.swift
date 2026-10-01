import Cocoa

/// The first-run setup window, revived (spec D8): shown on first launch BEFORE provider onboarding and, later,
/// the feature tour; re-opened from the Setup tab.
///
/// It owns no policy and no installer, the same way `PointOfUseOfferPresenter` doesn't:
/// `FirstRunSetupLaunchRule` decides whether launch shows the window, `ComponentPicker` decides what it offers,
/// `BootstrapInstallCoordinator.shared` performs it, and `LLMProviderDetection.observeLocal` measures which
/// local apps and models are already here. This type is where they meet.
///
/// **One queue.** Continue hands the plan to the SAME coordinator the point-of-use offer and the Setup tab's
/// Install buttons drive, as the same descriptors (`ComponentPicker.InstallPlan.queue`): a third entry point,
/// not a third installer.
final class FirstRunSetupPresenter {
    static let shared = FirstRunSetupPresenter()

    /// The Setup tab's re-open button (D8). The Setup tab, not the menu bar: this is a setup action and that tab
    /// is where setup is re-run from ("Check again", the local app rows' Install), while the menu stays the short
    /// list of things used every day.
    static let rerunTitle = "Run first-run setup again\u{2026}"
    static let rerunIdentifier = "setup-rerun-first-run"

    private let coordinator: BootstrapInstallCoordinator
    private var controller: FirstRunSetupWindowController?
    private var tokens: [NSObjectProtocol] = []
    private var measuring = false
    /// What follows when the window closes. Set only by the launch path.
    private var afterClose: (() -> Void)?
    /// The rows the last Continue queued, so B10's Retry re-enters the same queue with the same rows.
    private var lastQueue: [InstallerComponentDescriptor] = []

    init(coordinator: BootstrapInstallCoordinator = .shared) {
        self.coordinator = coordinator
    }

    deinit { stopWatching() }

    // MARK: - entry points

    /// Launch. Shows the window when `FirstRunSetupLaunchRule` says so and calls `next` once it closes; calls
    /// `next` straight away otherwise. `next` is the hand-off to whatever follows setup, so a Mac that skips the
    /// window loses nothing that came after it.
    func presentOnLaunchIfNeeded(then next: @escaping () -> Void) {
        let facts = launchFacts()
        guard FirstRunSetupLaunchRule.shouldPresent(facts) else {
            Log.write("first-run setup: not shown - core installed="
                + "\(facts.snapshot.mandatoryCoreComplete) earlier-core-on-disk=\(facts.earlierCoreOnDisk)")
            next()
            return
        }
        // B12's own bookkeeping, so the coordinator knows a setup surface is up.
        _ = coordinator.presentSetup()
        Log.write("first-run setup: shown at launch")
        present(then: next)
    }

    /// Whether this launch will show the window, by the same rule and the same facts `presentOnLaunchIfNeeded`
    /// reads. The Feature Tour asks it once, before anything is shown, to tell a fresh install from an existing one
    /// (`FeatureTourFirstShow`): S8's upgrader detection, not a second one.
    var launchShowsWindow: Bool { FirstRunSetupLaunchRule.shouldPresent(launchFacts()) }

    private func launchFacts() -> FirstRunSetupLaunchRule.Facts {
        FirstRunSetupLaunchRule.Facts(
            snapshot: coordinator.snapshot,
            earlierCoreOnDisk: FirstRunSetupLaunchRule.coreEnvironmentOnDisk(
                applicationSupport: AppPaths.applicationSupportDirectory()))
    }

    /// The Setup tab's button. Brings an open window forward rather than opening a second.
    func presentAgain() {
        Log.write("first-run setup: re-opened from the Setup tab")
        present(then: nil)
    }

    // MARK: - window

    private func present(then next: (() -> Void)?) {
        if let next { afterClose = next }
        if let controller, controller.isVisible {
            controller.show()
            return
        }
        guard !measuring else { return }
        measuring = true
        // Which apps and models are already here. It spawns `lms` and asks Ollama's port, so it runs off the main
        // thread, and with the default starter it never opens either app.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let presence = LLMProviderDetection.observeLocal().presence
            DispatchQueue.main.async {
                guard let self else { return }
                self.measuring = false
                self.show(environment: ComponentPicker.Environment(localPresence: presence))
            }
        }
    }

    private func show(environment: ComponentPicker.Environment) {
        let controller = FirstRunSetupWindowController(environment: environment)
        controller.activity = { [weak self] id in self?.coordinator.activity(for: id) }
        controller.onContinue = { [weak self] plan in self?.begin(plan) }
        controller.onRetry = { [weak self] _ in self?.retry() }
        controller.onSetUpLater = { [weak self] in self?.setUpLater() }
        controller.onClose = { [weak self] in self?.closed() }
        self.controller = controller
        startWatching()
        // Activates first (the app is an accessory), then makeKeyAndOrderFront.
        controller.show()
        controller.apply(snapshot: coordinator.snapshot)
    }

    // MARK: - install

    private func begin(_ plan: ComponentPicker.InstallPlan) {
        let queue = plan.queue
        lastQueue = queue
        Log.write("first-run setup: continue - " + queue.map(\.id).joined(separator: ","))
        start(queue)
    }

    private func retry() {
        guard !lastQueue.isEmpty else { return }
        Log.write("first-run setup: retry")
        start(lastQueue)
    }

    private func start(_ queue: [InstallerComponentDescriptor]) {
        let started = coordinator.start(descriptors: queue) { results in
            DispatchQueue.main.async {
                // D3: the Preferred local app follows the app this window installed, by S3c's rule. Only an app
                // row that LANDED moves it; a model row or a failure leaves it alone.
                PointOfUseOfferPresenter.followInstalledApp(components: queue, results: results)
                let failed = results.filter { !$0.succeeded }.map(\.componentID)
                Log.write("first-run setup: queue finished, failed=[\(failed.joined(separator: ","))]")
            }
        }
        if !started {
            // Someone else's rows are running. The window still mirrors the one shared queue; a second queue
            // would be two installers racing for the same venv.
            Log.write("first-run setup: the install queue is busy; the window shows its progress")
        }
    }

    /// B11: Set up later is the one degraded state. Only when nothing is running: a queue the point-of-use offer
    /// started is not this window's to stop.
    private func setUpLater() {
        guard !coordinator.isRunning else { return }
        coordinator.cancel()
    }

    // MARK: - lifecycle

    private func closed() {
        // B9: closing is not cancelling. The queue carries on and each row goes live as it lands.
        coordinator.dismiss()
        stopWatching()
        // The closed controller is kept, not released: this runs inside its own windowWillClose. The next
        // present() sees it is not visible and builds a fresh one against a fresh measurement.
        let next = afterClose
        afterClose = nil
        next?()
    }

    private func startWatching() {
        guard tokens.isEmpty else { return }
        let refresh: (Notification) -> Void = { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            controller.apply(snapshot: self.coordinator.snapshot)
        }
        tokens = [BootstrapInstallCoordinator.didChange, BootstrapInstallCoordinator.didReportActivity].map {
            NotificationCenter.default.addObserver(forName: $0, object: coordinator, queue: .main, using: refresh)
        }
    }

    private func stopWatching() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}
