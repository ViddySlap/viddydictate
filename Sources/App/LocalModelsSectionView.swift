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

    /// Everything the section reads from outside itself, in one value so the host's initialiser does not
    /// grow a parameter per seam.
    struct Environment {
        var store: Store
        var facts: () -> LocalModelSetup.MemoryFacts
        var jit: LocalModelSetup.JITReader

        static var live: Environment {
            Environment(store: .live,
                        facts: { .live },
                        jit: { LocalModelSetup.readJITSettings() })
        }
    }

    private let W: CGFloat
    private let L: CGFloat
    private let environment: Environment

    /// The last reading of LM Studio's settings file. Re-taken on every `apply`, which is what makes the
    /// tab's Check again button refresh this row along with everything else on the tab.
    private var jitSettings: LocalModelSetup.JITSettings?

    /// The kernel ceiling as of the last build. Held rather than re-read because the readout below refreshes
    /// on every mouse move during a drag, and the machine's wire limit does not change between two of them.
    private var facts = LocalModelSetup.MemoryFacts(userWireLimitBytes: nil, noUserWireBytes: nil)

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
        return frame.height
    }

    // MARK: - build

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let contentW = W - L - 20
        var y = buildControlsCard(width: contentW, at: 0)
        y = buildJITCard(width: contentW, at: y + 8)
        frame = NSRect(x: 0, y: frame.origin.y, width: W, height: y)
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

        let hint = wrapped(.timerHint, LocalModelSetup.timerHint, x: textX, y: y, width: textW,
                           size: 10.5, color: .tertiaryLabelColor)
        card.addSubview(hint)
        y = hint.frame.maxY

        card.frame.size.height = y + 9
        return card.frame.maxY
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
        let lines: [(LocalModelSetup.Part, String?, NSColor)] = [
            (.jitSummary, LocalModelSetup.jitSummary(status), .secondaryLabelColor),
            (.jitRemedy, LocalModelSetup.jitRemedy(status), attention ? .labelColor : .tertiaryLabelColor),
            (.jitConsequence, LocalModelSetup.jitConsequence(status), .tertiaryLabelColor),
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
    }

    /// Changing the app's own timer changes what the LM Studio row is measured against, so the row is
    /// re-derived rather than left reporting a comparison against the previous value.
    @objc private func timerChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, tag > 0 else { return }
        environment.store.setIdleSeconds(tag)
        rebuild()
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

    private func wrapped(_ part: LocalModelSetup.Part, _ text: String, x: CGFloat, y: CGFloat,
                         width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                         color: NSColor) -> NSTextField {
        let field = SettingsSectionKit.wrapped(text, x: x, y: y, width: width, size: size,
                                               weight: weight, color: color)
        field.identifier = identifier(part)
        return field
    }
}
