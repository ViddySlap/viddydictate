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
    /// This Mac's memory, which an Ollama pull is fit-checked against before it is offered.
    private let machineFacts: () -> ComponentPicker.MachineFacts
    private var changeToken: NSObjectProtocol?
    private var activityToken: NSObjectProtocol?
    private var pendingFeature: PointOfUseFeature?
    private var measuring = false
    /// Whether the install on the running page came from the local-app choice, so a Retry of it still moves
    /// the Preferred local app the way the first attempt would have.
    private var installFollowsChoice = false

    init(panel: InstallOfferPanel = InstallOfferPanel(),
         coordinator: BootstrapInstallCoordinator = .shared,
         measure: @escaping () -> [LLMProvider: LLMProviderDetection.Presence]
            = { LLMProviderDetection.observeAll() },
         machineFacts: @escaping () -> ComponentPicker.MachineFacts = { .live }) {
        self.panel = panel
        self.coordinator = coordinator
        self.measure = measure
        self.machineFacts = machineFacts
        // The running page reads what each row last reported from the same queue it installs through.
        panel.activity = { [weak coordinator] id in coordinator?.activity(for: id) }
    }

    deinit {
        if let changeToken { NotificationCenter.default.removeObserver(changeToken) }
        if let activityToken { NotificationCenter.default.removeObserver(activityToken) }
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
            let facts = self.machineFacts()
            let bootstrap = self.coordinator.snapshot
            DispatchQueue.main.async {
                self.measuring = false
                guard !self.isPresenting else { return }
                // The Preferred local app decides which app's model is offered when both are installed (D1).
                guard let offer = PointOfUsePolicy.offer(
                    for: feature, presences: presences, bootstrap: bootstrap,
                    preferredLocalApp: Settings.preferredLocalBackend, facts: facts) else {
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
            // What an install button does depends on the page (`PointOfUsePolicy.installStep`): on a Mac with
            // neither app the offer's button opens the app choice, LM Studio first; the choice page installs
            // the app picked; Retry on the running page runs the same rows again.
            var offer: PointOfUseOffer?
            var choice: PointOfUseLocalAppChoice?
            var running = false
            switch panel.state {
            case .offer(let shown)?: offer = shown
            case .appChoice(_, let shown)?: choice = shown
            case .running?: running = true
            case nil: break
            }
            switch PointOfUsePolicy.installStep(pressed: button, offer: offer, choice: choice,
                                                running: running) {
            case .chooseApp(let appChoice):
                guard let offer else { return }
                let apps = appChoice.options.map(\.backend.rawValue).joined(separator: ",")
                Log.write("point-of-use: asking which local app (\(apps))")
                panel.show(.appChoice(offer, appChoice))
            case .installApp(let backend):
                installLocalApp(backend)
            case .installComponents:
                beginInstall()
            case .none:
                break
            }
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

    /// Install the app the user picked on the local-app choice page (spec D3), on a Mac with neither. The
    /// option's components go through the same queue as every other row.
    func installLocalApp(_ backend: LocalBackendID) {
        guard let feature = pendingFeature else { return }
        let choice: PointOfUseLocalAppChoice?
        switch panel.state {
        case .appChoice(_, let shown)?: choice = shown
        case .offer(let offer)?: choice = offer.localAppChoice
        default: choice = nil
        }
        guard let option = choice?.option(backend) else { return }
        beginInstall(feature: feature, components: option.components, fromLocalAppChoice: true)
    }

    private func beginInstall() {
        guard let feature = pendingFeature else { return }
        var fromChoice = false
        switch panel.state {
        case .offer(let offer)?: fromChoice = offer.localAppChoice != nil
        case .running?: fromChoice = installFollowsChoice
        default: break
        }
        beginInstall(feature: feature, components: installComponents(), fromLocalAppChoice: fromChoice)
    }

    /// `fromLocalAppChoice` is true when the machine had neither local app when the offer was made, so the
    /// app this installs is the one the Preferred local app must now follow.
    private func beginInstall(feature: PointOfUseFeature, components: [InstallerComponentDescriptor],
                              fromLocalAppChoice: Bool) {
        guard !components.isEmpty else { return }
        let offer = PointOfUsePolicy.installOffer(for: feature, outstanding: components)
        installFollowsChoice = fromLocalAppChoice
        startWatching()
        panel.show(.running(offer, rows(for: components)))
        // The SAME queue the setup surface drives, given the same descriptors. A second entry point,
        // not a second installer.
        let started = coordinator.start(descriptors: components) { [weak self] results in
            DispatchQueue.main.async {
                if fromLocalAppChoice {
                    PointOfUseOfferPresenter.followInstalledApp(components: components, results: results)
                }
                self?.finishInstall(feature: feature, results: results)
            }
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
        // The choice page installs through `installLocalApp`, never through here.
        case .appChoice: return []
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

    /// D3: once the chosen app's own row has landed, the Preferred local app follows it (see
    /// `PointOfUsePolicy.preferenceAfterInstalling`). Written only when it changes. Also used by the Setup
    /// tab's Install on a Mac that had neither app.
    static func followInstalledApp(components: [InstallerComponentDescriptor],
                                           results: [InstallerComponentResult]) {
        let landed = Set(results.filter(\.succeeded).map(\.componentID))
        for component in components where landed.contains(component.id) {
            for case .app(let backend) in component.localSteps {
                let explicit = Settings.preferredLocalBackend
                let next = PointOfUsePolicy.preferenceAfterInstalling(backend, explicit: explicit)
                if next != explicit {
                    Settings.preferredLocalBackend = next
                    Log.write("point-of-use: preferred local app follows the \(backend.rawValue) install")
                }
            }
        }
    }

    /// Redraw the running page on every durable change AND on every activity report, so an Ollama pull
    /// shows its bytes and the approval wait shows its own words (the panel renders rows through
    /// `PointOfUsePolicy.progressLine(_:activity:)`). Reports are throttled at the source to four a second.
    private func startWatching() {
        guard changeToken == nil else { return }
        let redraw: (Notification) -> Void = { [weak self] _ in
            guard let self, case .running(let offer, _) = self.panel.state else { return }
            self.panel.show(.running(offer, self.rows(for: offer.components)))
        }
        changeToken = NotificationCenter.default.addObserver(
            forName: BootstrapInstallCoordinator.didChange, object: coordinator, queue: .main, using: redraw)
        activityToken = NotificationCenter.default.addObserver(
            forName: BootstrapInstallCoordinator.didReportActivity, object: coordinator, queue: .main,
            using: redraw)
    }

    private func stopWatching() {
        if let changeToken { NotificationCenter.default.removeObserver(changeToken) }
        if let activityToken { NotificationCenter.default.removeObserver(activityToken) }
        changeToken = nil
        activityToken = nil
    }
}
