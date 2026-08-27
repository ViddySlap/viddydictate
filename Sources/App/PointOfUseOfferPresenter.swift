import Cocoa

/// The point-of-use offer, driven (B13, B14, B17).
///
/// It owns no policy and no installer. `PointOfUsePolicy` decides what to offer,
/// `BootstrapInstallCoordinator.shared` performs it, `LLMProviderDetection` measures the machine, and
/// `ProviderOnboardingWindowController` runs the guided provider panels. This type is the seam that lets
/// those four meet at the moment a hotkey did not work, and its whole job is to make sure that moment
/// produces an offer instead of a dead end.
///
/// **It cannot run a transform.** There is no provider call anywhere below, which is how B16 survives
/// contact with a class that is invoked precisely when no local model is available.
final class PointOfUseOfferPresenter {
    static let shared = PointOfUseOfferPresenter()

    /// Mirrored into `HotkeyMonitor.installOfferActive` by the controller that owns the tap, so the panel
    /// is keyboard-driven without this type reaching into the event tap.
    var onActiveChanged: ((Bool) -> Void)?
    /// Opens the guided sign-in panel for one provider (B17). Wired to the onboarding window.
    var onOpenProviderSetup: ((LLMProvider) -> Void)?
    /// A short line for the HUD when a component lands.
    var onNotice: ((String) -> Void)?

    private let panel: InstallOfferPanel
    private let coordinator: BootstrapInstallCoordinator
    private let measure: () -> [LLMProvider: LLMProviderDetection.Presence]
    private var changeToken: NSObjectProtocol?
    private var pendingFeature: PointOfUseFeature?
    private var measuring = false

    init(panel: InstallOfferPanel = InstallOfferPanel(),
         coordinator: BootstrapInstallCoordinator = .shared,
         measure: @escaping () -> [LLMProvider: LLMProviderDetection.Presence]
            = { LLMProviderDetection.observeAll() }) {
        self.panel = panel
        self.coordinator = coordinator
        self.measure = measure
    }

    deinit {
        if let changeToken { NotificationCenter.default.removeObserver(changeToken) }
    }

    var isPresenting: Bool { panel.state != nil }

    /// Measure, decide, and present - or say nothing at all.
    ///
    /// The measurement spawns processes (`claude auth status`, the Codex boundary audit, `lms ls`), so it
    /// runs off the main thread. It is deliberately fresh rather than the cached availability the router
    /// uses: the commonest reason a user arrives here twice is that they just installed the thing, and a
    /// cached "not installed" would tell them to install it again.
    func presentOffer(for feature: PointOfUseFeature) {
        guard !isPresenting, !measuring else { return }
        measuring = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let presences = self.measure()
            let bootstrap = self.coordinator.snapshot
            DispatchQueue.main.async {
                self.measuring = false
                guard !self.isPresenting else { return }
                guard let offer = PointOfUsePolicy.offer(
                    for: feature, presences: presences, bootstrap: bootstrap) else {
                    Log.write("point-of-use: nothing to offer for \(feature.id)")
                    return
                }
                Log.write(offer.logToken)
                self.pendingFeature = feature
                self.panel.show(.offer(offer))
                self.onActiveChanged?(true)
            }
        }
    }

    // MARK: - keyboard

    func moveLeft() { panel.moveLeft() }
    func moveRight() { panel.moveRight() }

    func commit() {
        guard let button = panel.selectedButton else { return }
        Log.write("point-of-use: chose \(button.id)")
        switch button.route {
        case .skip:
            dismiss()
        case .guidedProvider(let provider):
            // The guided panel is an ordinary window the user drives. Dismissing this one first is what
            // hands focus over cleanly; nothing is signed in and nothing is sent by opening it.
            dismiss()
            onOpenProviderSetup?(provider)
        case .install:
            beginInstall()
        }
    }

    /// Escape. It closes the panel and never cancels a running install - B9's rule, and the reason this
    /// does not call `coordinator.cancel()`.
    func dismiss() {
        guard isPresenting else { return }
        panel.hide()
        pendingFeature = nil
        stopWatching()
        onActiveChanged?(false)
    }

    // MARK: - install

    private func beginInstall() {
        guard let feature = pendingFeature else { return }
        let components = installComponents()
        guard !components.isEmpty else { return }
        let offer = PointOfUsePolicy.installOffer(for: feature, outstanding: components)
        startWatching()
        panel.show(.running(offer, rows(for: components)))
        // The SAME queue the setup surface drives, given the same descriptors. A second entry point,
        // not a second installer.
        let started = coordinator.start(descriptors: components) { [weak self] results in
            DispatchQueue.main.async { self?.finishInstall(feature: feature, results: results) }
        }
        if !started {
            // The queue is already busy with someone else's rows. Saying so is better than a second queue.
            panel.show(.running(offer, rows(for: components)))
            onNotice?("Setup is already installing. This continues in the background.")
        }
    }

    /// Which descriptors "Install now" installs. From the offer for an install page; from the chooser's
    /// own local list when the user pressed "Set up local models", so that button enters the same install
    /// rather than a second flow.
    private func installComponents() -> [InstallerComponentDescriptor] {
        switch panel.state {
        case .offer(.install(let offer)): return offer.components
        case .offer(.chooser(let chooser)): return chooser.localComponents
        case .running(let offer, _): return offer.components
        case .none: return []
        }
    }

    private func rows(for components: [InstallerComponentDescriptor]) -> [BootstrapComponentRecord] {
        let snapshot = coordinator.snapshot
        return components.map { component in
            snapshot.component(component.id)
                ?? BootstrapComponentRecord(id: component.id, title: component.title)
        }
    }

    private func finishInstall(feature: PointOfUseFeature,
                               results: [InstallerComponentResult]) {
        let failed = results.filter { !$0.succeeded }
        guard failed.isEmpty else {
            // B10: the failed row keeps its real error and stays on screen. The panel is already showing
            // it through the shared state; nothing is replaced with a generic message.
            Log.write("point-of-use: \(feature.id) install left \(failed.count) failed row(s)")
            return
        }
        Log.write("point-of-use: \(feature.id) components installed")
        dismiss()
        // B8 in one sentence. The mode is not re-run on the user's behalf: by the time an install
        // completes, whatever this landed beside is already in their document, and pasting a second
        // time into it would be a worse failure than one keypress.
        onNotice?("\(feature.title) is ready. Press \(feature.hotkey) again.")
    }

    private func startWatching() {
        guard changeToken == nil else { return }
        changeToken = NotificationCenter.default.addObserver(
            forName: BootstrapInstallCoordinator.didChange, object: coordinator, queue: .main
        ) { [weak self] _ in
            guard let self, case .running(let offer, _) = self.panel.state else { return }
            self.panel.show(.running(offer, self.rows(for: offer.components)))
        }
    }

    private func stopWatching() {
        guard let changeToken else { return }
        NotificationCenter.default.removeObserver(changeToken)
        self.changeToken = nil
    }
}
