import Cocoa

/// The first-run half of provider onboarding (Public V1 spec W4, item P9).
///
/// Locked decision 5 is why this is its own small window rather than "open Settings on first launch":
/// onboarding signs the user in and asks nothing else, and the Settings window asks about nine other things.
/// The rows themselves are the same `ProviderOnboardingView` the Setup tab hosts, and the connect flow is the
/// same `ProviderSignInPresenter`, so there is one implementation entered from two places.
///
/// It never blocks (W5): it is an ordinary closable window, the app is already running, and dictation works
/// while it is open. Closing it is not a decision - the Setup tab reports the same thing every time Settings
/// is opened.
final class ProviderOnboardingWindowController: NSObject, NSWindowDelegate {
    /// The measuring half, injected. Production passes `Preflight.observe`; the offscreen probe passes a
    /// synthetic observation so the window can be driven through every state without a provider on the
    /// machine.
    typealias Observer = (@escaping (PreflightObservation) -> Void) -> Void

    /// Called with the plan each time a measurement lands, so the caller can persist "a provider was ready at
    /// least once" without this type owning that fact.
    var onMeasured: ((ProviderOnboarding.Plan) -> Void)?
    /// Called whenever the window closes. The launch path uses it to hand off to the Feature Tour, so the two
    /// windows never stack; any other caller may ignore it.
    var onClose: (() -> Void)?

    private let observer: Observer
    private let signIn = ProviderSignInPresenter()
    private var window: NSWindow?
    private var rows: ProviderOnboardingView?
    private var recheck: NSButton?
    private var checking = false
    /// Set when the window was opened from a point-of-use "Set up Claude" / "Set up Codex" button, so it
    /// answers the question that was actually asked instead of showing both providers.
    private var focusProvider: LLMProvider?
    private var focusTokens: [NSObjectProtocol] = []

    private let contentWidth: CGFloat = 560

    init(observer: @escaping Observer = Preflight.observe) {
        self.observer = observer
        super.init()
        signIn.onFinished = { [weak self] in self?.check() }
        observeFocus()
    }

    deinit {
        focusTokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// B17: re-check whenever this panel regains focus.
    ///
    /// The install and sign-in steps both happen OUTSIDE ViddyDictate - in Terminal, in a browser, in the
    /// Applications folder - so the moment that matters is the user coming back. Watching for that is what
    /// removes the last "then check again" from the flow: the row flips to SIGNED IN on its own and the
    /// user never has to find their way back to a button.
    ///
    /// Both notifications are needed and neither is redundant. Reactivating the app fires the application
    /// notification while this window is already key, and clicking this window while the app is already
    /// active fires only the window one.
    private func observeFocus() {
        let center = NotificationCenter.default
        focusTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.recheckOnFocus() })
        focusTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = self.window,
                  (note.object as? NSWindow) === window else { return }
            self.recheckOnFocus()
        })
    }

    /// Only while the window is actually on screen. `check()` spawns provider processes, and a background
    /// re-measure on every app activation for a window nobody opened is work the user did not ask for.
    private func recheckOnFocus() {
        guard let window, window.isVisible else { return }
        check()
    }

    func show(focus provider: LLMProvider? = nil) {
        focusProvider = provider
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        check()
    }

    /// Measure and re-render. The same `Preflight.observe` the Setup tab uses, so re-running the check is one
    /// mechanism with two buttons rather than two mechanisms (W4).
    func check() {
        guard !checking else { return }
        checking = true
        syncRecheckTitle()
        rows?.apply(nil)
        layoutContent()
        observer { [weak self] observation in
            Self.onMain {
                guard let self = self else { return }
                self.checking = false
                let measured = ProviderOnboarding.plan(providers: observation.providers)
                let plan = self.focusProvider.map(measured.focused(on:)) ?? measured
                Log.write("first-run onboarding: \(measured.logToken)")
                self.syncRecheckTitle()
                self.rows?.apply(plan)
                self.layoutContent()
                self.onMeasured?(measured)
            }
        }
    }

    /// `Preflight.observe` completes on a background queue, never on the main one, so a UI hop is mandatory.
    /// Conditional rather than unconditional because the probe's observer answers synchronously on the main
    /// thread and its result has to be on screen before the call returns.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - build

    /// Exposed for the offscreen render gate: the rows plus their chrome, with no window involved.
    func makeContentView() -> NSView {
        let root = FlippedOnboardingRoot(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 200))

        let heading = NSTextField(labelWithString: "Set up ViddyDictate")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        heading.frame = NSRect(x: 20, y: 16, width: contentWidth - 40 - 120, height: 24)
        root.addSubview(heading)

        let button = NSButton(title: "Check again", target: self, action: #selector(recheckClicked))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.identifier = NSUserInterfaceItemIdentifier(ProviderOnboarding.recheckIdentifier)
        button.frame = NSRect(x: contentWidth - 20 - 116, y: 12, width: 116, height: 28)
        root.addSubview(button)
        recheck = button

        let done = NSButton(title: "Start dictating", target: self, action: #selector(dismissClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.identifier = NSUserInterfaceItemIdentifier(ProviderOnboarding.dismissIdentifier)
        root.addSubview(done)

        let view = ProviderOnboardingView(width: contentWidth)
        view.onConnect = { [weak self] provider in
            guard let self = self else { return }
            self.signIn.begin(provider, in: self.window)
        }
        view.frame.origin = NSPoint(x: 0, y: 50)
        root.addSubview(view)
        rows = view
        root.rows = view
        root.dismiss = done
        layoutContent(in: root)
        return root
    }

    private func build() {
        let content = makeContentView()
        let w = NSWindow(contentRect: content.bounds,
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Set up ViddyDictate"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 520))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = content
        let host = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 520))
        scroll.frame = host.bounds
        host.addSubview(scroll)
        w.contentView = host
        w.setContentSize(NSSize(width: contentWidth, height: 520))
        window = w
    }

    private func syncRecheckTitle() {
        recheck?.title = checking ? "Checking..." : "Check again"
        recheck?.isEnabled = !checking
    }

    private func layoutContent(in explicit: NSView? = nil) {
        guard let root = (explicit ?? rows?.superview) as? FlippedOnboardingRoot else { return }
        root.relayout()
    }

    @objc private func recheckClicked() { check() }
    @objc private func dismissClicked() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        CodexConnectionController.shared.cancelDeviceLogin()
        onClose?()
    }
}

/// Owns the vertical stack below the heading: the rows grow with their content, and the dismiss button sits
/// under whatever height they ended up at, so a three-line row cannot land on top of it.
private final class FlippedOnboardingRoot: NSView {
    override var isFlipped: Bool { true }
    weak var rows: ProviderOnboardingView?
    weak var dismiss: NSButton?

    func relayout() {
        guard let rows = rows else { return }
        rows.frame.origin = NSPoint(x: 0, y: 50)
        let bottom = rows.frame.maxY + 14
        dismiss?.frame = NSRect(x: 20, y: bottom, width: 140, height: 30)
        frame.size.height = bottom + 30 + 16
    }
}
