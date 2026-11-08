import Cocoa
import ApplicationServices

/// The paste-target bullseye (VDCURC): a small blinking disc in the user's accent color that shows,
/// while a take is live (recording or locked), where dictated text will land — at the caret of the
/// focused field, at the middle of a focused element with no caret, or at the pointer tip when there
/// is no paste target. The panel is created lazily on the first `start`, reads Accessibility off the
/// main thread on a per-run serial queue, and never blocks input or takes focus.
final class PasteTargetMarker {

    /// Draws the three rings (outer, middle, center dot) in `Phosphor.accent`, centered in the view.
    private final class BullseyeView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let color = Phosphor.accent
            color.setStroke()
            let r = bounds.width / 2
            let center = NSPoint(x: bounds.midX, y: bounds.midY)

            let outer = NSBezierPath(ovalIn: NSRect(x: center.x - 0.9 * r, y: center.y - 0.9 * r,
                                                    width: 1.8 * r, height: 1.8 * r))
            outer.lineWidth = 1.5
            outer.stroke()

            let middle = NSBezierPath(ovalIn: NSRect(x: center.x - 0.55 * r, y: center.y - 0.55 * r,
                                                     width: 1.1 * r, height: 1.1 * r))
            middle.lineWidth = 1.5
            middle.stroke()

            color.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 0.2 * r, y: center.y - 0.2 * r,
                                                  width: 0.4 * r, height: 0.4 * r))
            dot.fill()
        }
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var focusQueue: DispatchQueue?

    // Main-thread-only run state.
    private var runGeneration = 0
    private var inFlightGeneration: Int? = nil
    private var tickCount = 0
    private var latestSnapshot: PasteTargetPlacement.Focus?
    private var startedAt = Date()
    private var captured: DictationTarget?
    /// Whether the marker follows LIVE focus (the landing setting is OFF) or sits on the field captured at take
    /// START (the setting is ON). Frozen for the whole run, exactly like the take's landing route (VDLAND1).
    private var followsLive = true

    /// Main thread only; idempotent (a start while running restarts cleanly). `followsLive` is the take's frozen
    /// route: true reads live focus as before, false pins the marker to the captured element's own frame/caret so
    /// it cannot drift away from the field the text will land in.
    func start(captured: DictationTarget?, followsLive: Bool) {
        self.captured = captured
        self.followsLive = followsLive
        timer?.invalidate()
        runGeneration += 1
        inFlightGeneration = nil
        latestSnapshot = nil
        tickCount = 0
        startedAt = Date()
        // Every run owns its own serial focus queue; the old one (if any) is dropped, and a read
        // still running on it finishes by itself with a stale completion that touches nothing.
        focusQueue = DispatchQueue(label: AppIdentity.queueLabel("paste-target-focus"), qos: .utility)

        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = BullseyeView()
            panel = p
        }

        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The first tick of a new run requests its own read and places the marker at the pointer
        // until that run's snapshot arrives.
        tick()
    }

    /// Main thread only; idempotent (stop while stopped does nothing at all).
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        runGeneration += 1
        inFlightGeneration = nil
        latestSnapshot = nil
        focusQueue = nil
        panel?.orderOut(nil)
    }

    private func tick() {
        // REQUEST (top of tick): every sixth tick (5 Hz), ask this run's queue for a fresh snapshot
        // unless a read is already in flight. A tick while a read is in flight keeps the latest
        // snapshot as it is.
        if tickCount % 6 == 0 && inFlightGeneration == nil {
            inFlightGeneration = runGeneration
            let g = runGeneration
            let q = focusQueue
            let captured = self.captured
            let followsLive = self.followsLive
            q?.async { [weak self] in
                let result = PasteTargetMarker.readFocus(captured: captured, followsLive: followsLive)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // COMPLETION: a stale or stopped completion touches NOTHING.
                    guard g == self.runGeneration, self.timer != nil else { return }
                    self.latestSnapshot = result
                    self.inFlightGeneration = nil
                }
            }
        }

        let nsScreens = NSScreen.screens
        let screens = nsScreens.map { HUDPointerPlacement.Screen(frame: $0.frame, visible: $0.visibleFrame) }
        let primaryHeight = nsScreens.first?.frame.height ?? 0
        let scale = Settings.hudUIScale
        let d = PasteTargetPlacement.diameter(scale: scale)
        let pointer = NSEvent.mouseLocation
        let result = PasteTargetPlacement.place(focus: latestSnapshot, pointer: pointer,
                                                screens: screens, primaryHeight: primaryHeight)
        let fallback: Int
        if let main = NSScreen.main, let idx = nsScreens.firstIndex(where: { $0 === main }) {
            fallback = idx
        } else {
            fallback = 0
        }
        let origin = PasteTargetPlacement.windowOrigin(center: result.center, diameter: d,
                                                       screens: screens, fallback: fallback)
        panel?.setFrame(NSRect(origin: origin, size: NSSize(width: d, height: d)), display: true)
        panel?.alphaValue = PasteTargetPlacement.blinkAlpha(elapsed: Date().timeIntervalSince(startedAt))
        panel?.orderFrontRegardless()

        tickCount += 1
    }

    /// The focus read, run OFF the main thread on this run's serial queue. Returns nil when no focused element
    /// could be read (or the app is not trusted for Accessibility). With `followsLive == false` it reads the
    /// CAPTURED element instead of live focus and returns nil when that element cannot be read, so a pinned
    /// take's marker never falls back to whatever the user has since clicked.
    private static func readFocus(captured: DictationTarget?, followsLive: Bool) -> PasteTargetPlacement.Focus? {
        if !followsLive {
            guard let captured = captured else { return nil }
            let element = captured.element
            AXUIElementSetMessagingTimeout(element, 0.25)
            let pinnedElementRect = readFrame(of: element)
            let pinnedCaretRect = readCaret(of: element)
            guard pinnedElementRect != nil || pinnedCaretRect != nil else { return nil }
            return PasteTargetPlacement.Focus(caret: pinnedCaretRect, element: pinnedElementRect, isTarget: true)
        }
        // (i) Resolve the focused element: system-wide first, then the frontmost app's own focused
        // element (the same two strategies the target resolver uses, but without calling its
        // capture function, which writes log lines on every call). Set the 0.25s messaging timeout
        // on the system-wide element and, when the fallback runs, on the frontmost app's element,
        // BOTH before their kAXFocusedUIElementAttribute read.
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focusedRef: CFTypeRef?
        let e1 = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if e1 == .success, let ref = focusedRef {
            element = (ref as! AXUIElement)
        } else if let front = NSWorkspace.shared.frontmostApplication {
            let appEl = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.25)
            var f2: CFTypeRef?
            let e2 = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f2)
            if e2 == .success, let ref = f2 { element = (ref as! AXUIElement) }
        }
        guard let element = element else { return nil }

        // (ii) Set the 0.25s messaging timeout on the focused element before ANY attribute read on it.
        AXUIElementSetMessagingTimeout(element, 0.25)

        // (iii) isTarget: text-like role, a settable value, or the exact element the take captured.
        // This is the same test DictationController.deliverPushToTalk uses (a text-like field, or the
        // same field the take captured); keep the two in step.
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let sameElement = captured.map { CFEqual(element, $0.element) } ?? false
        let isTarget = textRoles.contains(role) || settable.boolValue || sameElement

        // (iv) Element frame in Accessibility space from position + size; nil when either read fails.
        let elementRect = readFrame(of: element)

        // (v) Caret from the selected text range's bounds; nil when it cannot be read.
        let caretRect = readCaret(of: element)

        return PasteTargetPlacement.Focus(caret: caretRect, element: elementRect, isTarget: isTarget)
    }

    private static func readFrame(of element: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef = posRef, CFGetTypeID(posRef) == AXValueGetTypeID() else { return nil }
        let posValue = posRef as! AXValue
        guard AXValueGetType(posValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(posValue, .cgPoint, &point) else { return nil }

        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef = sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(sizeValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }

        return NSRect(origin: point, size: size)
    }

    private static func readCaret(of element: AXUIElement) -> NSRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef = rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let rangeValue = rangeRef as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }

        // First try: bounds for the selected range, used as is when it is not empty.
        if let rect = boundsForRange(parameter: rangeValue, element: element) {
            if !(rect.width == 0 && rect.height == 0) || range.location <= 0 {
                return rect
            }
        }
        // Retry once with the one-character range just before the (empty) caret, using a rect whose
        // x is that character's maxX and whose width is 0.
        guard range.location > 0 else { return nil }
        var oneBack = CFRange(location: range.location - 1, length: 1)
        guard let oneBackValue = AXValueCreate(.cfRange, &oneBack) else { return nil }
        guard let back = boundsForRange(parameter: oneBackValue, element: element) else { return nil }
        return NSRect(x: back.maxX, y: back.origin.y, width: 0, height: back.height)
    }

    private static func boundsForRange(parameter: AXValue, element: AXUIElement) -> NSRect? {
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out)
        guard err == .success, let out = out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        let value = out as! AXValue
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }
}
