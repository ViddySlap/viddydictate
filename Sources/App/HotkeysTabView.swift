import Cocoa

/// A top-to-bottom flipped container, so hand-laid-out rows read in the order they are written.
final class FlippedContainerView: NSView { override var isFlipped: Bool { true } }

/// The binding half of a merged hotkey card.
///
/// `ModelsPowerSettingsView` owns every route's provider, model, effort and prompt controls;
/// `HotkeysSettingsView` owns chord capture, custom-mode CRUD, and the per-mode input/landing traits.
/// L9 merged the two Settings tabs into one, so a routing card asks its binding source for the controls
/// belonging to the SAME hotkey and hosts them inline. The controls are built by — and still target —
/// the Hotkeys view, so rebinding keeps exactly one implementation and routing keeps exactly one
/// authority. The merge is composition, not a fork.
protocol HotkeyBindingRowSource: AnyObject {
    /// The binding controls for the hotkey that fires this route, laid out to `width`, or nil when the
    /// route has no chord of its own (dictation cleanup rides the wakeup plus the level keys).
    func hotkeyBindingRow(routeKey: String, customID: String?, width: CGFloat) -> NSView?
    /// "Add new hotkey", rendered after the last route card so a new hotkey and the card where it is
    /// configured appear in the same place — the whole point of the merge.
    func hotkeyAddControl() -> NSView
}

/// The consolidated Hotkeys tab (L9). One scroll document carrying, in order: the hotkey legend, the
/// dictation wakeup, the rebind-only core keys, then the global provider/routing section and one card
/// per LLM route — each card headed by the hotkey that fires it and holding that hotkey's Advanced
/// disclosure.
///
/// Both halves keep their own view class and their own store ownership. This container only stacks
/// them, and re-stacks whenever either half rebuilds itself to a new height (both size themselves from
/// their content, so the stack cannot be computed once). Callers MUST hand both halves the same
/// `CustomModeStore`, or a custom hotkey's binding row and its routing card would read different files.
final class HotkeysTabView: NSView {
    override var isFlipped: Bool { true }

    let hotkeys: HotkeysSettingsView
    let routing: ModelsPowerSettingsView

    private let gap: CGFloat = 14
    private var observers: [NSObjectProtocol] = []
    private var restacking = false

    init(hotkeys: HotkeysSettingsView, routing: ModelsPowerSettingsView) {
        self.hotkeys = hotkeys
        self.routing = routing
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: max(hotkeys.frame.width, routing.frame.width), height: 10))
        addSubview(hotkeys)
        addSubview(routing)

        routing.bindingRowSource = hotkeys
        // A chord capture, a rename, an input/landing change or a delete all change what a routing card
        // must draw (its title, its keycap, its binding row), so the routing half re-renders from the
        // same gesture rather than waiting for the next time Settings opens.
        hotkeys.onStructuralChange = { [weak self] in self?.routing.refresh() }
        hotkeys.onContentChanged = { [weak self] in self?.restack() }
        routing.onContentChanged = { [weak self] in self?.restack() }
        // A custom mode edited from a routing card (the task-prompt workstation, Remove, Add) has to
        // reach the legend too, which only the Hotkeys half draws.
        observers.append(NotificationCenter.default.addObserver(
            forName: CustomModeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.hotkeys.refresh() })
        observers.append(NotificationCenter.default.addObserver(
            forName: StickySkillStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hotkeys.refresh()
            self?.routing.refresh()
        })

        routing.refresh()   // first pass with the binding source attached
        restack()
    }

    required init?(coder: NSCoder) { fatalError("no coder") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Re-stack the two halves and resize the document to fit. Guarded because moving a child changes
    /// its frame, and both children report frame changes back through `onContentChanged`.
    func restack() {
        guard !restacking else { return }
        restacking = true
        defer { restacking = false }
        hotkeys.frame.origin = .zero
        routing.frame.origin = NSPoint(x: 0, y: hotkeys.frame.height + gap)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y,
                       width: max(hotkeys.frame.width, routing.frame.width),
                       height: routing.frame.maxY)
    }
}
