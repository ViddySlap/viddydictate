import Cocoa

/// The Setup tab: P8's preflight report as a re-runnable Settings surface (Public V1 spec W5, item P11).
///
/// Until this existed nothing called `Preflight.observe`, so the app measured its own install and told
/// nobody. This view is the reader. It holds no judgement: rows come from the findings `Preflight.evaluate`
/// produced, wording comes from `PreflightSurface`, and there is no code path here that can refuse
/// anything - W5's warn-never-block answer is enforced a layer down by `PreflightSeverity` having no
/// blocking case, and this file could not express one if it tried.
///
/// "Re-runnable" is literal: there is no cached verdict and no first-run-only path. Opening Settings runs
/// the check, and the button runs it again.
final class SetupSettingsView: NSView {
    override var isFlipped: Bool { true }

    /// The measuring half, injected. Production passes `Preflight.observe`; the offscreen probe passes a
    /// synthetic observation, so the surface can be driven through every failure mode without depending on
    /// the daemon, the providers, the keychain, or this machine's TCC grants.
    typealias Observer = (@escaping (PreflightObservation) -> Void) -> Void

    private enum Content {
        case checking
        /// The report, the onboarding plan, and the Gemini key state all come from ONE observation. The Setup
        /// tab measures once and every surface on it reads that measurement, so the provider rows and the
        /// provider preflight row can never disagree about what is signed in - and (L5) the Gemini section
        /// and the "Gemini answer key" preflight row can never disagree about whether a key is stored.
        case report(PreflightReport, ProviderOnboarding.Plan, GeminiKeySetup.Status)
    }

    /// Invoked with the provider whose sign-in action was clicked (Public V1 spec W4, item P9). The host wires
    /// this to `ProviderSignInPresenter`, the same flow the first-run window drives.
    var onConnect: ((LLMProvider) -> Void)?

    private let W: CGFloat
    private let L: CGFloat = 20
    private let observer: Observer
    private var content: Content = .checking
    private let onboarding: ProviderOnboardingView
    private let geminiKey: GeminiKeySectionView
    /// One check at a time. The button is disabled while a check runs, so the state the user sees and the
    /// state that guards re-entry are the same fact rather than two that can disagree.
    private var checking = false

    init(width: CGFloat,
         observer: @escaping Observer = Preflight.observe,
         geminiKeyWriter: GeminiKeySectionView.Writer? = nil,
         geminiKeyDeleter: GeminiKeySectionView.Deleter? = nil) {
        self.W = width
        self.observer = observer
        // The Setup tab owns its own subtitle and footer, so the shared rows contribute only their headline
        // and cards here rather than repeating the first-run window's standing copy.
        self.onboarding = ProviderOnboardingView(width: width, showsStandingCopy: false)
        // The keychain halves are injected together or not at all, both defaulting to `SecretStore`'s own.
        // Production passes neither; only the offscreen probe passes both, because an agent shell can
        // neither write nor delete a login keychain item.
        self.geminiKey = GeminiKeySectionView(
            width: width,
            writer: geminiKeyWriter ?? { SecretStore.write(.geminiAPIKey, value: $0) },
            deleter: geminiKeyDeleter ?? { SecretStore.delete(.geminiAPIKey) })
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        onboarding.onConnect = { [weak self] provider in self?.onConnect?(provider) }
        // Storing or removing a key changes what the machine would report, so the tab re-measures rather
        // than letting the section believe its own write or its own delete. That is what refreshes the
        // preflight row below it too, and it is what keeps a Delete button from claiming Option+G is off
        // when something else is still supplying a key.
        geminiKey.onStored = { [weak self] in self?.check() }
        check()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Measure and re-render. Called on construction, on every Settings open, and on every click.
    func check() {
        guard !checking else { return }
        checking = true
        content = .checking
        rebuild()
        observer { [weak self] observation in
            Self.onMain {
                guard let self = self else { return }
                self.checking = false
                let report = Preflight.evaluate(observation)
                let plan = ProviderOnboarding.plan(providers: observation.providers)
                // Derived from the same observation the preflight key row reads, never measured again here.
                let key = GeminiKeySetup.status(observation.webAnswerKeySource)
                Log.write("setup tab: \(report.logToken) \(plan.logToken) gemini-key=\(key.isStored)")
                self.content = .report(report, plan, key)
                self.rebuild()
            }
        }
    }

    /// `Preflight.observe` completes on whichever background queue finished its health request, never on
    /// the main queue, so a UI hop is mandatory. It is conditional rather than an unconditional
    /// `DispatchQueue.main.async` because the probe's observer answers synchronously on the main thread and
    /// its result has to be on screen before the call returns.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 16

        addSubview(text("Setup", x: L, y: y, width: W - 2 * L - 130,
                        size: 19, weight: .semibold, color: .labelColor))

        let recheck = NSButton(title: checking ? "Checking..." : "Check again",
                               target: self, action: #selector(recheckClicked))
        recheck.bezelStyle = .rounded
        recheck.font = .systemFont(ofSize: 11)
        recheck.identifier = NSUserInterfaceItemIdentifier(PreflightSurface.recheckIdentifier)
        recheck.isEnabled = !checking
        recheck.frame = NSRect(x: W - L - 116, y: y - 4, width: 116, height: 28)
        addSubview(recheck)
        y += 30

        let headlineText: String
        var warnings = 0
        switch content {
        case .checking:
            headlineText = PreflightSurface.checkingHeadline
        case .report(let report, _, _):
            headlineText = PreflightSurface.headline(report)
            warnings = report.warnings.count
        }
        let headline = text(headlineText, x: L, y: y, width: W - 2 * L,
                            size: 13, weight: .medium,
                            color: warnings > 0 ? .systemOrange : .labelColor)
        headline.identifier = NSUserInterfaceItemIdentifier(PreflightSurface.headlineIdentifier)
        addSubview(headline)
        y += 22

        y = add(wrapped(PreflightSurface.subtitle, x: L, y: y, width: W - 2 * L,
                        size: 10.5, color: .tertiaryLabelColor),
                id: PreflightSurface.subtitleIdentifier) + 14

        // Provider sign-in leads the tab (item P9). It is the one check on this surface with an action
        // attached, and the only one a first-run user is likely to need, so it sits above the read-only rows
        // instead of being reachable only from the provider row's remedy text.
        addSubview(sectionHeader("TEXT PROVIDER SIGN-IN", y: y))
        y += 18
        onboarding.frame.origin = NSPoint(x: 0, y: y)
        onboarding.apply({ if case .report(_, let plan, _) = content { return plan } else { return nil } }())
        addSubview(onboarding)
        y = onboarding.frame.maxY + 14

        // The Gemini key section (L5), placed the same way: a section heading, then a child view that is
        // handed a state and asked how tall it needs to be. Second on the tab because signing a provider in
        // is what a first-run user needs first, and Option+G is optional on top of it.
        addSubview(sectionHeader(GeminiKeySetup.header, y: y))
        y += 18
        geminiKey.frame.origin = NSPoint(x: 0, y: y)
        geminiKey.apply({ if case .report(_, _, let key) = content { return key } else { return nil } }())
        addSubview(geminiKey)
        y = geminiKey.frame.maxY + 14

        if case .report(let report, _, _) = content {
            addSubview(sectionHeader("EVERYTHING ELSE THIS INSTALL NEEDS", y: y))
            y += 18
            for finding in report.findings {
                y = addRow(finding, at: y)
            }
        }

        y = add(wrapped(PreflightSurface.footer, x: L, y: y + 4, width: W - 2 * L,
                        size: 10.5, color: .tertiaryLabelColor),
                id: PreflightSurface.footerIdentifier) + 16

        frame = NSRect(x: 0, y: 0, width: W, height: y)
    }

    /// One check, as a card: state word, title, then every line `PreflightSurface.detailLines` produced.
    /// The card grows to its measured text rather than a guessed height, because the longest row here is
    /// the no-provider remedy - a menu of three alternatives - and a clipped remedy is not actionable.
    private func addRow(_ finding: PreflightFinding, at originY: CGFloat) -> CGFloat {
        let card = cardView(y: originY, id: PreflightSurface.cardIdentifier(finding.check))
        let statusW: CGFloat = 124
        let textX = statusW + 20
        let textW = card.bounds.width - textX - 14
        var y: CGFloat = 12

        let status = text(PreflightSurface.statusText(finding), x: 14, y: y + 1, width: statusW - 8,
                          size: 10, weight: .semibold,
                          color: finding.isWarning ? .systemOrange : .systemGreen)
        status.identifier = NSUserInterfaceItemIdentifier(
            PreflightSurface.identifier(.status, finding.check))
        card.addSubview(status)

        let title = text(finding.check.title, x: textX, y: y, width: textW,
                         size: 12.5, weight: .semibold, color: .labelColor)
        title.identifier = NSUserInterfaceItemIdentifier(
            PreflightSurface.identifier(.title, finding.check))
        card.addSubview(title)
        y += 20

        // The parts are laid out from one list so a row cannot lose a line by forgetting a call, and the
        // identifiers are assigned positionally from the same order the surface documents.
        let parts: [(PreflightSurface.RowPart, String?, NSColor)] = [
            (.summary, finding.summary, .secondaryLabelColor),
            (.remedy, PreflightSurface.remedyLine(finding), .labelColor),
            (.reduced, PreflightSurface.reducedLine(finding), .tertiaryLabelColor),
        ]
        for (part, value, color) in parts {
            guard let value = value else { continue }
            let label = wrapped(value, x: textX, y: y, width: textW, size: 10.5, color: color)
            label.identifier = NSUserInterfaceItemIdentifier(
                PreflightSurface.identifier(part, finding.check))
            label.toolTip = value
            card.addSubview(label)
            y += label.frame.height + 3
        }

        card.frame.size.height = y + 9
        return originY + card.frame.height + 8
    }

    @objc private func recheckClicked() { check() }

    // MARK: - view helpers

    private func sectionHeader(_ value: String, y: CGFloat) -> NSTextField {
        SettingsSectionKit.sectionHeader(value, x: L, y: y, width: W - 2 * L)
    }

    private func add(_ label: NSTextField, id: String) -> CGFloat {
        label.identifier = NSUserInterfaceItemIdentifier(id)
        addSubview(label)
        return label.frame.maxY
    }

    /// The card chrome is `SettingsSectionKit`'s, shared with the two sections above these rows, so a card on
    /// this tab looks the same wherever it was drawn from.
    private func cardView(y: CGFloat, id: String) -> NSView {
        let card = SettingsSectionKit.card(
            frame: NSRect(x: L, y: y, width: W - 2 * L, height: 0), identifier: id)
        addSubview(card)
        return card
    }

    private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        SettingsSectionKit.label(value, x: x, y: y, width: width, size: size, weight: weight, color: color)
    }

    private func wrapped(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                         size: CGFloat, color: NSColor) -> NSTextField {
        SettingsSectionKit.wrapped(value, x: x, y: y, width: width, size: size, color: color)
    }
}
