import Cocoa

/// The Local models section on the Setup tab, as two cards: the controls that govern how much memory local
/// models may hold and how long ViddyDictate keeps its own, then a read-only row reporting LM Studio's own
/// JIT model timeout.
///
/// Built the same way L4's provider sign-in section and L5's Gemini key section are: the judgement and the
/// words belong to `LocalModelSetup`, the card and label chrome come from `SettingsSectionKit`, and this
/// file only decides where things sit. The controls card uses the label / control / value-label row the
/// Appearance tab's sliders already use; the JIT card uses the preflight row's own geometry, because that
/// is what it is.
///
/// Everything it reads is injected. That is not ceremony: the offscreen render gate has to drive a machine
/// whose kernel ceiling is unreadable and an LM Studio whose timeout is set four different ways, and it must
/// do it without writing this Mac's real settings. Production passes none of it.
final class LocalModelsSectionView: NSView {
    override var isFlipped: Bool { true }

    /// The two persisted settings this section owns, as functions. Production is `Settings`; there is no
    /// second store. Injected so the render gate can drive the slider through its whole range without
    /// touching the defaults of the app the user is running.
    struct Store {
        var budgetPosition: () -> Double
        var setBudgetPosition: (Double) -> Void
        var idleSeconds: () -> Int
        var setIdleSeconds: (Int) -> Void

        static var live: Store {
            Store(budgetPosition: { Settings.modelMemoryBudgetSliderPosition },
                  setBudgetPosition: { Settings.modelMemoryBudgetSliderPosition = $0 },
                  idleSeconds: { Settings.modelIdleUnloadSeconds },
                  setIdleSeconds: { Settings.modelIdleUnloadSeconds = $0 })
        }
    }

    /// One coherent reading of what the machine is holding: LM Studio's resident set and the Mac's own
    /// wired total, taken together rather than through two calls that could describe two moments.
    ///
    /// `models` is nil when `lms ps` could not be read at all, which the section reports as its own state
    /// rather than as an empty machine.
    struct ResidencyReading {
        var models: [ModelResidency.ResidentModel]?
        var wiredBytes: UInt64?

        /// The live reading. `ModelResidency.residentModels()` SHELLS THE LM STUDIO CLI and costs about
        /// 0.16s; `SystemMemory.wiredBytes` is an in-process `host_statistics64`. Both are taken here, on
        /// whatever queue the caller is running, so the pair is one snapshot.
        static var live: ResidencyReading {
            ResidencyReading(models: ModelResidency.residentModels(),
                             wiredBytes: SystemMemory.wiredBytes)
        }
    }

    /// The reading, injected as a CALLBACK rather than a return value, and that shape is the whole point.
    ///
    /// `lms ps` is a subprocess and this section is built on the main thread. The 2026-07-13 freeze was a
    /// blocking call of exactly this kind sitting behind the filtering event tap: it stalled every
    /// keystroke on the Mac, not merely this window. So production hops to a background queue and back,
    /// and nothing on this path can be made synchronous by a later edit without changing this type.
    ///
    /// The render gate answers inline on the main thread instead, which is why every completion here is
    /// delivered through `onMain` rather than assumed to arrive off it.
    typealias ResidencyReader = (@escaping (ResidencyReading) -> Void) -> Void

    /// Unload everything LM Studio holds, then call back. Same threading contract as `ResidencyReader`,
    /// for the same reason: `lms unload --all` is a subprocess and takes as long as it takes.
    typealias UnloadAll = (@escaping () -> Void) -> Void

    /// Everything the section reads from outside itself, in one value so the host's initialiser does not
    /// grow a parameter per seam.
    struct Environment {
        var store: Store
        var facts: () -> LocalModelSetup.MemoryFacts
        var jit: LocalModelSetup.JITReader
        var residency: ResidencyReader
        var unloadAll: UnloadAll
        /// Injected so a gate can drive TTL countdowns against a fixed clock instead of racing one.
        var now: () -> Date

        static var live: Environment {
            Environment(store: .live,
                        facts: { .live },
                        jit: { LocalModelSetup.readJITSettings() },
                        residency: { completion in
                            DispatchQueue.global(qos: .utility).async {
                                let reading = ResidencyReading.live
                                DispatchQueue.main.async { completion(reading) }
                            }
                        },
                        unloadAll: { completion in
                            DispatchQueue.global(qos: .utility).async {
                                ModelResidency.unloadAll()
                                DispatchQueue.main.async { completion() }
                            }
                        },
                        now: Date.init)
        }
    }

    /// Fired when the section's own height changed outside a host-driven `apply()`.
    ///
    /// The live readout grows and shrinks with the resident set, and the tab lays this section out by
    /// running from its `maxY`. Without this the section would silently overlap the read-only preflight
    /// rows below it the moment a model was loaded or unloaded.
    var onHeightChanged: (() -> Void)?

    /// How often the resident set is re-read while the tab is on screen. Long enough that the CLI is not
    /// being spawned constantly, short enough that Unload all and a model load both show up while the
    /// user is still looking at the slider they pressed.
    static let refreshInterval: TimeInterval = 5

    private let W: CGFloat
    private let L: CGFloat
    private let environment: Environment

    /// The last reading of LM Studio's settings file. Re-taken on every `apply`, which is what makes the
    /// tab's Check again button refresh this row along with everything else on the tab.
    private var jitSettings: LocalModelSetup.JITSettings?

    /// The kernel ceiling as of the last build. Held rather than re-read because the readout below refreshes
    /// on every mouse move during a drag, and the machine's wire limit does not change between two of them.
    private var facts = LocalModelSetup.MemoryFacts(userWireLimitBytes: nil, noUserWireBytes: nil)

    /// The last reading of LM Studio's resident set, and the wired total taken with it. `pending` until
    /// the first background read lands, which is the honest answer rather than an empty list.
    private var residency: LocalModelSetup.Residency = .pending
    private var lastWired: UInt64?
    /// One reading at a time. `wantsAnotherReading` coalesces a request that arrived while one was in
    /// flight, so an Unload all that lands mid-refresh still shows its result immediately.
    private var readingInFlight = false
    private var wantsAnotherReading = false
    private var unloading = false
    /// A refresh that needed to move the layout while a mouse button was down. Taken on the next tick;
    /// see `showResidency`.
    private var needsRelayout = false
    private var refreshTimer: Timer?

    init(width: CGFloat, leftInset: CGFloat = 20, environment: Environment = .live) {
        self.W = width
        self.L = leftInset
        self.environment = environment
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        identifier = NSUserInterfaceItemIdentifier(LocalModelSetup.sectionIdentifier)
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Re-measure and re-render. Returns the height it needs, so a host laying out a taller document can
    /// place what follows.
    ///
    /// There is no in-flight state here and no cached verdict: both settings and the LM Studio file are read
    /// synchronously on every call, so the section cannot show a number the machine has stopped agreeing
    /// with.
    @discardableResult
    func apply() -> CGFloat {
        jitSettings = environment.jit()
        rebuild()
        // The resident set is the one thing on this section that is NOT read synchronously, because
        // reading it is a subprocess. The card above renders `pending` and this fills it in.
        refreshResidency()
        return frame.height
    }

    // MARK: - the live resident set

    /// Start and stop the refresh with the section's presence on screen. A timer left running behind a
    /// closed Settings window would spawn `lms ps` forever for nobody.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRefreshing() } else { startRefreshing() }
    }

    deinit { refreshTimer?.invalidate() }

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshResidency()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshResidency()
        }
        // `.common`, so the readout keeps moving while a menu or a slider drag is tracking the mouse -
        // which is exactly when the budget numbers are most likely to be changing under the user.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Take a reading, OFF the main thread, and put it on screen when it lands.
    ///
    /// Nothing in this method calls the LM Studio CLI itself; `environment.residency` owns the hop. That
    /// separation is deliberate - it is what keeps a synchronous `lms` call out of the main thread by
    /// construction rather than by remembering to wrap one.
    private func refreshResidency() {
        guard !unloading else { return }
        guard !readingInFlight else { wantsAnotherReading = true; return }
        readingInFlight = true
        environment.residency { [weak self] reading in
            Self.onMain {
                guard let self = self else { return }
                self.readingInFlight = false
                self.lastWired = reading.wiredBytes
                self.residency = reading.models.map { .models($0) } ?? .unavailable
                self.showResidency()
                if self.wantsAnotherReading {
                    self.wantsAnotherReading = false
                    self.refreshResidency()
                }
            }
        }
    }

    /// `Environment.live` completes on the main queue, but the render gate answers inline on whatever
    /// thread called it. Conditional rather than an unconditional `DispatchQueue.main.async` so the
    /// gate's result is on screen before its call returns - the same reason `SetupSettingsView` does it.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Put a fresh reading on screen.
    ///
    /// The list changes HEIGHT with the number of resident models, and unlike the budget labels that
    /// cannot always be done in place: everything below it has to move. But a rebuild removes the slider,
    /// and a rebuild landing while the mouse is holding that slider kills the drag (see `budgetChanged`).
    /// So the strings are refreshed in place - the common case, since a tick usually finds the same models
    /// with less time left - and a relayout is deferred while any mouse button is down.
    private func showResidency() {
        if needsRelayout, NSEvent.pressedMouseButtons == 0 {
            needsRelayout = false
            rebuild(notifyingHost: true)
            return
        }
        guard let list = text(.residencyList) else { rebuild(notifyingHost: true); return }

        let hadSummary = text(.residencySummary) != nil
        let before = list.frame.height
        let width = list.frame.width
        list.stringValue = LocalModelSetup.residencyList(residency, now: environment.now())
        // The face travels with the state, so a machine that just emptied does not keep the columns' font
        // for its sentence. Re-sizing here is also what makes the height comparison below honest.
        sizeResidencyBlock(list, width: width)
        let after = list.frame.height

        let summary = LocalModelSetup.residencySummary(
            position: LocalModelSetup.normalized(environment.store.budgetPosition()),
            facts: facts, wiredBytes: lastWired)
        if let summary = summary {
            text(.residencySummary)?.stringValue = summary
            text(.residencySummary)?.textColor = LocalModelSetup.residencyOverBudget(
                position: LocalModelSetup.normalized(environment.store.budgetPosition()),
                facts: facts, wiredBytes: lastWired) ? .systemOrange : .labelColor
        }
        if let button = unloadAllButton() {
            button.title = unloading ? LocalModelSetup.unloadingTitle : LocalModelSetup.unloadAllTitle
            button.isEnabled = !unloading && LocalModelSetup.canUnloadAll(residency)
        }

        // A summary that only now became available (or stopped being) changes the block's shape too.
        guard abs(after - before) > 0.5 || hadSummary != (summary != nil) else { return }
        if NSEvent.pressedMouseButtons != 0 { needsRelayout = true; return }
        rebuild(notifyingHost: true)
    }

    private func unloadAllButton() -> NSButton? {
        let wanted = LocalModelSetup.identifier(.unloadAll)
        func search(_ root: NSView) -> NSButton? {
            if root.identifier?.rawValue == wanted { return root as? NSButton }
            for child in root.subviews { if let hit = search(child) { return hit } }
            return nil
        }
        return search(self)
    }

    // MARK: - build

    /// `notifyingHost` is set by every rebuild that is NOT the host's own `apply()`: a timer landing a
    /// new resident set, or the idle timer being changed. Both can change this section's height, and the
    /// tab above has to be told or it will leave the rows below sitting on top of it.
    private func rebuild(notifyingHost: Bool = false) {
        let before = frame.height
        subviews.forEach { $0.removeFromSuperview() }
        let contentW = W - L - 20
        var y = buildControlsCard(width: contentW, at: 0)
        y = buildJITCard(width: contentW, at: y + 8)
        frame = NSRect(x: 0, y: frame.origin.y, width: W, height: y)
        if notifyingHost, abs(frame.height - before) > 0.5 { onHeightChanged?() }
    }

    /// The budget slider and the idle timer. Returns the y this card ends at.
    private func buildControlsCard(width contentW: CGFloat, at originY: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(
            frame: NSRect(x: L, y: originY, width: contentW, height: 0),
            identifier: LocalModelSetup.cardIdentifier)
        addSubview(card)

        let textX: CGFloat = 14
        let textW = contentW - 28
        // The control column. Wide enough for the longer of the two titles at their own size, so neither
        // gets truncated into "Unload idle models aft...".
        let titleW: CGFloat = 170
        let controlX = textX + titleW + 8
        let valW: CGFloat = 34
        let valX = contentW - textX - valW
        var y: CGFloat = 12

        let headline = wrapped(.headline, LocalModelSetup.headline, x: textX, y: y, width: textW,
                               size: 12.5, weight: .semibold, color: .labelColor)
        card.addSubview(headline)
        y = headline.frame.maxY + 3

        let purpose = wrapped(.purpose, LocalModelSetup.purpose, x: textX, y: y, width: textW,
                              size: 10.5, color: .secondaryLabelColor)
        card.addSubview(purpose)
        y = purpose.frame.maxY + 12

        // --- The budget slider (LOCKED DECISION 6) ---
        let position = LocalModelSetup.normalized(environment.store.budgetPosition())
        facts = environment.facts()

        card.addSubview(title(.budgetTitle, LocalModelSetup.budgetTitle, x: textX, y: y + 2, width: titleW))

        let slider = NSSlider(value: position,
                              minValue: Settings.modelMemoryBudgetSliderRange.lowerBound,
                              maxValue: Settings.modelMemoryBudgetSliderRange.upperBound,
                              target: self, action: #selector(budgetChanged))
        slider.identifier = identifier(.budgetSlider)
        slider.frame = NSRect(x: controlX, y: y, width: valX - controlX - 10, height: 20)
        slider.isContinuous = true
        card.addSubview(slider)

        // The bare level. No unit and no percent sign: the face is 0...100 but it maps onto 25...90% of the
        // wire ceiling, so a "%" here would state something false. The gigabyte line below is the only
        // quantitative claim on this row.
        let level = value(.budgetLevel, LocalModelSetup.budgetLevelText(position), x: valX, y: y + 2,
                          width: valW)
        card.addSubview(level)
        y += 24

        let budgetLine = wrapped(.budgetLine, LocalModelSetup.budgetLine(position: position, facts: facts),
                                 x: textX, y: y, width: textW, size: 11,
                                 color: facts.isAvailable ? .labelColor : .systemOrange)
        card.addSubview(budgetLine)
        y = budgetLine.frame.maxY + 2

        if let reserved = LocalModelSetup.reservedLine(facts: facts) {
            // Secondary rather than tertiary, for the reason the Gemini section already records about its
            // own `turnsOn` line: at tertiary against this card fill it is legible only if you already know
            // it is there. This is one of the three lines LOCKED DECISION 6 specifies, not an aside.
            let line = wrapped(.reservedLine, reserved, x: textX, y: y, width: textW,
                               size: 10.5, color: .secondaryLabelColor)
            card.addSubview(line)
            y = line.frame.maxY
        }
        y += 14

        // --- What is loaded right now (LOCKED DECISION 2) ---
        // Directly under the slider and its two lines, and above the idle timer, because the only control
        // this readout explains is the budget. Separating the number from the knob is what made the budget
        // feel like a lie on 2026-08-27.
        y = buildResidency(in: card, position: position, x: textX, width: textW, at: y) + 14

        // --- The idle-unload timer ---
        card.addSubview(title(.timerTitle, LocalModelSetup.timerTitle, x: textX, y: y + 4, width: titleW))

        let popup = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: 130, height: 25),
                                  pullsDown: false)
        popup.identifier = identifier(.timerControl)
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(timerChanged)
        let seconds = environment.store.idleSeconds()
        var offered = LocalModelSetup.timerChoicesMinutes.map { $0 * 60 }
        // A value set outside this menu - by a test seam, or by an older build - must still be shown rather
        // than silently snapped to the nearest choice the moment the tab is opened.
        if !offered.contains(seconds) { offered.append(seconds); offered.sort() }
        for value in offered {
            popup.addItem(withTitle: LocalModelSetup.duration(value))
            popup.lastItem?.tag = value
        }
        popup.selectItem(withTag: seconds)
        card.addSubview(popup)
        y = popup.frame.maxY + 4

        // Secondary, not tertiary, for the same reason the reserved-RAM caption above is: measured
        // against this card's composited fill, tertiary body copy comes out at 2.26:1 and secondary at
        // 5.72:1, and 2.26:1 is below the 3:1 floor for even large text. This line is what tells you
        // what the control beside it actually does, so it has to be readable.
        let hint = wrapped(.timerHint, LocalModelSetup.timerHint, x: textX, y: y, width: textW,
                           size: 10.5, color: .secondaryLabelColor)
        card.addSubview(hint)
        y = hint.frame.maxY

        card.frame.size.height = y + 9
        return card.frame.maxY
    }

    /// The live readout: what LM Studio holds, what that costs against the budget, what lowering the
    /// budget will and will not do, and the one button that makes a lowered budget true immediately.
    ///
    /// Returns the y it ends at.
    private func buildResidency(in card: NSView, position: Double,
                                x: CGFloat, width: CGFloat, at originY: CGFloat) -> CGFloat {
        var y = originY
        let buttonW: CGFloat = 104

        card.addSubview(title(.residencyTitle, LocalModelSetup.residencyTitle,
                              x: x, y: y + 4, width: width - buttonW - 8))

        // Offered even with nothing to unload, disabled rather than hidden: a button that appears and
        // disappears with the resident set would move every line under it on a five-second timer.
        let unload = NSButton(title: unloading ? LocalModelSetup.unloadingTitle
                                               : LocalModelSetup.unloadAllTitle,
                              target: self, action: #selector(unloadAllClicked))
        unload.bezelStyle = .rounded
        unload.font = .systemFont(ofSize: 11)
        unload.identifier = identifier(.unloadAll)
        unload.frame = NSRect(x: x + width - buttonW, y: y, width: buttonW, height: 24)
        unload.isEnabled = !unloading && LocalModelSetup.canUnloadAll(residency)
        card.addSubview(unload)
        y += 28

        let list = residencyBlock(LocalModelSetup.residencyList(residency, now: environment.now()),
                                  x: x, y: y, width: width)
        card.addSubview(list)
        y = list.frame.maxY + 5

        // Omitted rather than guessed on a machine with no readable ceiling, exactly like the reserved
        // line: `budgetLine` has already said there is no budget to be in use against.
        if let summary = LocalModelSetup.residencySummary(position: position, facts: facts,
                                                          wiredBytes: lastWired) {
            let field = wrapped(.residencySummary, summary, x: x, y: y, width: width, size: 11,
                                color: LocalModelSetup.residencyOverBudget(
                                    position: position, facts: facts, wiredBytes: lastWired)
                                    ? .systemOrange : .labelColor)
            card.addSubview(field)
            y = field.frame.maxY + 2
        }

        // The sentence this whole item exists for. Secondary rather than tertiary for the reason the rest
        // of this section records: tertiary body copy on this card fill measures 2.26:1.
        let note = wrapped(.residencyNote, LocalModelSetup.residencyNote, x: x, y: y, width: width,
                           size: 10.5, color: .secondaryLabelColor)
        card.addSubview(note)
        return note.frame.maxY
    }

    /// LM Studio's own JIT timeout, as a preflight row (LOCKED DECISION 4). Read only: nothing in this
    /// section writes `~/.lmstudio/settings.json`, and `LocalModelSetup` has no writer to call.
    private func buildJITCard(width contentW: CGFloat, at originY: CGFloat) -> CGFloat {
        let card = SettingsSectionKit.card(
            frame: NSRect(x: L, y: originY, width: contentW, height: 0),
            identifier: LocalModelSetup.jitCardIdentifier)
        addSubview(card)

        // The preflight row's own geometry, so this row lines up with the ones further down the tab.
        let statusW: CGFloat = 124
        let textX = statusW + 20
        let textW = contentW - textX - 14
        var y: CGFloat = 12

        let status = LocalModelSetup.jitStatus(jitSettings,
                                               appIdleSeconds: environment.store.idleSeconds())
        let attention = LocalModelSetup.jitNeedsAttention(status)

        let state = SettingsSectionKit.label(
            LocalModelSetup.jitStatusText(status), x: 14, y: y + 1, width: statusW - 8,
            size: 10, weight: .semibold,
            color: attention ? .systemOrange : (status == .unknown ? .secondaryLabelColor : .systemGreen))
        state.identifier = identifier(.jitStatus)
        card.addSubview(state)

        card.addSubview(title(.jitTitle, LocalModelSetup.jitTitle, x: textX, y: y, width: textW))
        y += 20

        // Laid out from one list so the row cannot lose a line by forgetting a call, and so the identifiers
        // are assigned positionally from the order the pure layer documents.
        // Same legibility rule as the controls card: nothing in this section renders at tertiary. The
        // consequence line in particular carries LOCKED DECISION 1's most surprising cost - that another
        // app's model spends your budget - and it renders in exactly the state Ben's Mac is in today.
        let lines: [(LocalModelSetup.Part, String?, NSColor)] = [
            (.jitSummary, LocalModelSetup.jitSummary(status), .secondaryLabelColor),
            (.jitRemedy, LocalModelSetup.jitRemedy(status), attention ? .labelColor : .secondaryLabelColor),
            (.jitConsequence, LocalModelSetup.jitConsequence(status), .secondaryLabelColor),
        ]
        for (part, text, color) in lines {
            guard let text = text else { continue }
            let field = wrapped(part, text, x: textX, y: y, width: textW, size: 10.5, color: color)
            field.toolTip = text
            card.addSubview(field)
            y += field.frame.height + 3
        }

        card.frame.size.height = y + 9
        return card.frame.maxY
    }

    // MARK: - actions

    /// Store the rounded position and refresh the two labels the handle governs.
    ///
    /// Rounding here rather than at draw time is what keeps the level and the gigabytes derived from one
    /// number: nothing fractional is ever persisted.
    ///
    /// It refreshes IN PLACE rather than rebuilding, and that is load-bearing. The slider is continuous, so
    /// this fires on every mouse move of a drag; a rebuild would remove the very control the mouse is
    /// tracking, and the drag would die after the first pixel. It would still read correctly in any gate
    /// that sets a value and fires the action, and be unusable with a hand on the trackpad. Nothing else on
    /// the card depends on the position, and the kernel facts cannot change between two mouse moves, so the
    /// two strings are the whole of what changes.
    @objc private func budgetChanged(_ sender: NSSlider) {
        let position = LocalModelSetup.normalized(sender.doubleValue)
        environment.store.setBudgetPosition(position)
        text(.budgetLevel)?.stringValue = LocalModelSetup.budgetLevelText(position)
        text(.budgetLine)?.stringValue = LocalModelSetup.budgetLine(position: position, facts: facts)
        // The denominator of the residency summary IS this handle, so it moves with it for exactly the
        // reason the gigabyte line does - and in place, without touching the list above it, so the drag
        // survives. A summary that is absent (no readable ceiling) stays absent; nothing appears mid-drag.
        if let summary = LocalModelSetup.residencySummary(position: position, facts: facts,
                                                          wiredBytes: lastWired) {
            text(.residencySummary)?.stringValue = summary
            // The colour is part of the reading, not decoration on it: dragging the handle BELOW what is
            // already in use is the whole scenario this readout exists for, so it has to change here too.
            text(.residencySummary)?.textColor = LocalModelSetup.residencyOverBudget(
                position: position, facts: facts, wiredBytes: lastWired) ? .systemOrange : .labelColor
        }
    }

    /// Make the budget true right now instead of at the next cold load.
    ///
    /// It re-MEASURES afterwards rather than believing its own request: the button reports what LM Studio
    /// says is resident once the unload returns, not what it asked for. A model another app is actively
    /// using can come straight back, and the readout should show that rather than an empty list.
    @objc private func unloadAllClicked(_ sender: NSButton) {
        guard !unloading else { return }
        unloading = true
        sender.isEnabled = false
        sender.title = LocalModelSetup.unloadingTitle
        Log.write("setup tab: unload all requested")
        environment.unloadAll { [weak self] in
            Self.onMain {
                guard let self = self else { return }
                self.unloading = false
                self.refreshResidency()
            }
        }
    }

    /// Changing the app's own timer changes what the LM Studio row is measured against, so the row is
    /// re-derived rather than left reporting a comparison against the previous value.
    @objc private func timerChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, tag > 0 else { return }
        environment.store.setIdleSeconds(tag)
        rebuild(notifyingHost: true)
    }

    // MARK: - view helpers

    private func identifier(_ part: LocalModelSetup.Part) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(LocalModelSetup.identifier(part))
    }

    /// The label carrying `part`, wherever in the section it currently sits.
    private func text(_ part: LocalModelSetup.Part) -> NSTextField? {
        let wanted = LocalModelSetup.identifier(part)
        func search(_ root: NSView) -> NSTextField? {
            if root.identifier?.rawValue == wanted { return root as? NSTextField }
            for child in root.subviews {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(self)
    }

    private func title(_ part: LocalModelSetup.Part, _ text: String,
                       x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = SettingsSectionKit.label(text, x: x, y: y, width: width, size: 12.5,
                                             weight: .semibold, color: .labelColor)
        field.identifier = identifier(part)
        return field
    }

    private func value(_ part: LocalModelSetup.Part, _ text: String,
                       x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .labelColor
        field.alignment = .right
        field.frame = NSRect(x: x, y: y, width: width, height: 16)
        field.identifier = identifier(part)
        return field
    }

    /// The resident-set block.
    ///
    /// A monospaced face is not a style choice for the ROWS: the pure layer pads names, sizes and states to
    /// a common width, and in a proportional font that padding lines up with nothing. It is the wrong face
    /// for the other three states, which are ordinary sentences and read as a code dump in it - so the font
    /// follows what the block currently IS, not where it sits.
    private func residencyBlock(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .labelColor
        field.preferredMaxLayoutWidth = width
        field.identifier = identifier(.residencyList)
        sizeResidencyBlock(field, width: width)
        field.frame.origin = NSPoint(x: x, y: y)
        return field
    }

    /// Put the right face on the block and size it to the text it now carries. Shared by the build and the
    /// in-place refresh so a state change cannot leave columns in a proportional font, or the reverse.
    private func sizeResidencyBlock(_ field: NSTextField, width: CGFloat) {
        field.font = LocalModelSetup.residencyIsTabular(residency)
            ? .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            : .systemFont(ofSize: 10.5)
        let fitted = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        field.frame.size = NSSize(width: width, height: ceil(fitted.height))
    }

    private func wrapped(_ part: LocalModelSetup.Part, _ text: String, x: CGFloat, y: CGFloat,
                         width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                         color: NSColor) -> NSTextField {
        let field = SettingsSectionKit.wrapped(text, x: x, y: y, width: width, size: size,
                                               weight: weight, color: color)
        field.identifier = identifier(part)
        return field
    }
}
