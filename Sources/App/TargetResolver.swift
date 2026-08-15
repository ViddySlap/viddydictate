import Cocoa
import ApplicationServices
import CoreGraphics

/// A captured destination for dictated text: the focused Accessibility element + its app.
struct DictationTarget {
    let element: AXUIElement
    let pid: pid_t
    let label: String
    let isTextLike: Bool
    /// Content-free Accessibility identity for a captured selection/caret. Selection transforms use it
    /// when the target exposes AXSelectedTextRange; dictation retry replacement validates the field only
    /// because the first raw landing necessarily moved this range.
    let selectedTextRange: CFRange?

    init(element: AXUIElement, pid: pid_t, label: String, isTextLike: Bool,
         selectedTextRange: CFRange? = nil) {
        self.element = element
        self.pid = pid
        self.label = label
        self.isTextLike = isTextLike
        self.selectedTextRange = selectedTextRange
    }
}

/// "Confident-or-clipboard" delivery: capture the focused field at press/lock time, validate that exact
/// destination before a synthesized paste, and fall back durably to the clipboard when it cannot be verified.
enum TargetResolver {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// A captured foreign-app landing never calls clipboard recovery a landing. The reason tokens and
    /// messages are fixed classifications: they contain no field labels, selection text, or provider output.
    enum CapturedTargetLandingOutcome: Equatable {
        enum Failure: String, Equatable {
            case targetAppUnavailable = "target_app_unavailable"
            case destinationUnverifiable = "destination_unverifiable"
            case destinationChanged = "destination_changed"
            case selectionChanged = "selection_changed"
            case eventDispatchFailed = "event_dispatch_failed"

            var userMessage: String {
                switch self {
                case .targetAppUnavailable: return "Original app is no longer running"
                case .destinationUnverifiable: return "Original field could not be verified"
                case .destinationChanged: return "Focus moved to a different field"
                case .selectionChanged: return "The original selection changed"
                case .eventDispatchFailed: return "The paste shortcut could not be sent"
                }
            }
        }

        case landed
        case clipboardOnly(Failure)

        var didLand: Bool {
            if case .landed = self { return true }
            return false
        }

        var logToken: String {
            switch self {
            case .landed: return "landed"
            case .clipboardOnly(let failure): return "clipboard_only_\(failure.rawValue)"
            }
        }

        var userMessage: String {
            switch self {
            case .landed: return "Output landed in the original field"
            case .clipboardOnly(let failure):
                return "\(failure.userMessage) — output copied to clipboard"
            }
        }
    }

    private static func axErr(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notImplemented: return "notImplemented"
        case .noValue: return "noValue"
        case .apiDisabled: return "apiDisabled"
        default: return "err(\(e.rawValue))"
        }
    }

    private static func selectedTextRange(in element: AXUIElement) -> CFRange? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &valueRef) == .success,
            let valueRef = valueRef,
            CFGetTypeID(valueRef) == AXValueGetTypeID()
        else { return nil }
        let value = valueRef as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    private static func focusedElement(in pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef = focusedRef
        else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// Pure classification seam used by the production AX probe and the deterministic retry tests.
    /// A nil return is the only state that permits a global undo/paste event.
    static func capturedTargetValidation(
        appIsRunning: Bool,
        elementIdentityAvailable: Bool,
        focusedDestinationAvailable: Bool,
        sameElement: Bool,
        selectionIdentityRequired: Bool,
        selectionIdentityAvailable: Bool,
        selectionMatches: Bool
    ) -> CapturedTargetLandingOutcome.Failure? {
        guard appIsRunning else { return .targetAppUnavailable }
        guard elementIdentityAvailable, focusedDestinationAvailable else {
            return .destinationUnverifiable
        }
        guard sameElement else { return .destinationChanged }
        guard !selectionIdentityRequired || selectionIdentityAvailable else {
            return .destinationUnverifiable
        }
        guard !selectionIdentityRequired || selectionMatches else { return .selectionChanged }
        return nil
    }

    static func captureFocused() -> DictationTarget? {
        var element: AXUIElement?

        // Strategy 1: the system-wide focused element.
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let e1 = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        if e1 == .success, let ref = focused {
            element = (ref as! AXUIElement)
        } else if let front = NSWorkspace.shared.frontmostApplication {
            // Strategy 2: ask the frontmost app directly (far more reliable than system-wide).
            let appEl = AXUIElementCreateApplication(front.processIdentifier)
            var f2: CFTypeRef?
            let e2 = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f2)
            Log.write("AX capture: systemwide=\(axErr(e1)) app[\(front.localizedName ?? "?")]=\(axErr(e2))")
            if e2 == .success, let ref = f2 { element = (ref as! AXUIElement) }
        } else {
            Log.write("AX capture: systemwide=\(axErr(e1)) no frontmost app")
        }

        guard let element = element else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let isTextLike = textRoles.contains(role) || settable.boolValue

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "app"
        let roleDesc = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        let label = "\(appName) — \(roleDesc.isEmpty ? "field" : roleDesc)"
        Log.write("AX capture OK role=\(role.isEmpty ? "?" : role) textLike=\(isTextLike) app=\(appName)")
        return DictationTarget(element: element, pid: pid, label: label, isTextLike: isTextLike,
                               selectedTextRange: selectedTextRange(in: element))
    }

    /// PRE-DISCOVERY / UNUSED: legacy AX-only insertion retained for regression evidence. An AX `.success`
    /// is not proof that text landed: Claude's Accessibility element was measured accepting this write while
    /// silently dropping the text. Production delivery must use a completion-based, honest landing path.
    static func insertViaAX(_ text: String, into target: DictationTarget) -> Bool {
        // Tier 1: replace the selection / insert at the caret.
        let e1 = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
        if e1 == .success { Log.write("insert AX tier1 selectedText OK"); return true }

        // Tier 2: append to the field's value.
        var e2: AXError = .failure
        if target.isTextLike {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(target.element, kAXValueAttribute as CFString, &valueRef)
            let existing = (valueRef as? String) ?? ""
            let combined = existing.isEmpty ? text : existing + text
            e2 = AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, combined as CFString)
            if e2 == .success { Log.write("insert AX tier2 value OK"); return true }
        }
        Log.write("insert AX failed tier1=\(axErr(e1)) tier2=\(target.isTextLike ? axErr(e2) : "skip")")
        return false
    }

    /// Synthesize Cmd+V into whatever field is currently focused. Universal — works in native apps,
    /// Electron (Claude/Obsidian/Slack/Discord/VS Code), browsers, and terminals, because it is the
    /// exact path of the user pressing Cmd+V. The previous clipboard is captured before the write and
    /// restored ~0.35s after the paste (skipped if the pasteboard changed in between), so the dictated
    /// text is NOT left on the clipboard; its durable copy is the dictation-history entry recorded on
    /// delivery.
    @discardableResult
    static func pasteIntoFocus(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pb)
        SyntheticPasteboard.write(text, to: pb)
        let temporaryChangeCount = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        guard let down = down, let up = up else {
            Log.write("paste event dispatch unavailable — output retained on clipboard")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pb.changeCount == temporaryChangeCount else {
                Log.write("paste clipboard restore skipped: pasteboard changed")
                return
            }
            SyntheticPasteboard.restore(previous, to: pb)
            Log.write("paste clipboard restored")
        }
        return true
    }

    /// Paste into the exact app/field/selection that owned a captured transform. Explicit retry is
    /// confirmed from Settings, so reactivate the target app and then validate its Accessibility identity
    /// before sending a global paste. A failed validation leaves the output on the clipboard and reports
    /// that recovery honestly through `completion`; it is never called a landing.
    static func pasteIntoCapturedTarget(
        _ text: String,
        target: DictationTarget,
        completion: @escaping (CapturedTargetLandingOutcome) -> Void
    ) {
        performCapturedTargetLanding(text, target: target, validateSelection: true,
                                     operation: { done in done(pasteIntoFocus(text)) },
                                     completion: completion)
    }

    /// Deliver a late recovered take to its captured field without activating the target app. The app may
    /// have moved to the background while its model warmed; posting Cmd+V directly to its pid preserves the
    /// user's current focus. We still require the exact captured AX element and selection/caret to match.
    /// If either changed, the transcript is preserved on the clipboard rather than guessed into a new place.
    static func pasteIntoCapturedTargetWithoutActivation(
        _ text: String,
        target: DictationTarget,
        completion: @escaping (CapturedTargetLandingOutcome) -> Void
    ) {
        let clipboardFallback: (CapturedTargetLandingOutcome.Failure) -> Void = { failure in
            copyToClipboard(text)
            let outcome = CapturedTargetLandingOutcome.clipboardOnly(failure)
            Log.write("late captured-target landing classification=\(outcome.logToken)")
            completion(outcome)
        }

        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            clipboardFallback(.targetAppUnavailable)
            return
        }
        var elementPID: pid_t = 0
        let elementIdentityAvailable = AXUIElementGetPid(target.element, &elementPID) == .success
            && elementPID == target.pid
        let focused = focusedElement(in: target.pid)
        let sameElement = focused.map { CFEqual($0, target.element) } ?? false
        let expectedRange = target.selectedTextRange
        let currentRange = focused.flatMap { selectedTextRange(in: $0) }
        let selectionMatches = expectedRange.flatMap { expected in
            currentRange.map { current in
                expected.location == current.location && expected.length == current.length
            }
        } ?? false
        if let failure = capturedTargetValidation(
            appIsRunning: true,
            elementIdentityAvailable: elementIdentityAvailable,
            focusedDestinationAvailable: focused != nil,
            sameElement: sameElement,
            selectionIdentityRequired: expectedRange != nil,
            selectionIdentityAvailable: currentRange != nil,
            selectionMatches: selectionMatches
        ) {
            clipboardFallback(failure)
            return
        }
        guard pasteIntoProcess(text, pid: target.pid) else {
            clipboardFallback(.eventDispatchFailed)
            return
        }
        completion(.landed)
    }

    /// Clipboard-preserving Cmd+V directed to one process. Unlike `pasteIntoFocus`, this never changes the
    /// frontmost application or the user's current caret/focus.
    private static func pasteIntoProcess(_ text: String, pid: pid_t) -> Bool {
        let pb = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pb)
        SyntheticPasteboard.write(text, to: pb)
        let temporaryChangeCount = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
            Log.write("late paste event dispatch unavailable - output retained on clipboard")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pb.changeCount == temporaryChangeCount else {
                Log.write("late paste clipboard restore skipped: pasteboard changed")
                return
            }
            SyntheticPasteboard.restore(previous, to: pb)
            Log.write("late paste clipboard restored")
        }
        return true
    }

    /// Replace the freshest raw fallback in the captured app with successful explicit-retry output. This
    /// mirrors the shipped smart-undo recovery (native Cmd+Z, then clipboard-preserving paste), but first
    /// restores and validates the app/field that owned the original landing because confirmation happens
    /// in Settings. The first raw paste moved the caret, so this path validates exact field identity but
    /// deliberately does not compare the gesture-start selection range.
    static func replaceLastPaste(
        in target: DictationTarget,
        with text: String,
        completion: @escaping (CapturedTargetLandingOutcome) -> Void
    ) {
        performCapturedTargetLanding(text, target: target, validateSelection: false,
                                     operation: { done in
                                         undoLastPasteAndPasteRaw(text, completion: done)
                                     },
                                     completion: completion)
    }

    private static func performCapturedTargetLanding(
        _ text: String,
        target: DictationTarget,
        validateSelection: Bool,
        operation: @escaping (@escaping (Bool) -> Void) -> Void,
        completion: @escaping (CapturedTargetLandingOutcome) -> Void
    ) {
        let clipboardFallback: (CapturedTargetLandingOutcome.Failure) -> Void = { failure in
            copyToClipboard(text)
            let outcome = CapturedTargetLandingOutcome.clipboardOnly(failure)
            Log.write("captured-target landing classification=\(outcome.logToken)")
            completion(outcome)
        }

        let validateAndLand = {
            let runningApp = NSRunningApplication(processIdentifier: target.pid)
            let appIsRunning = runningApp.map { !$0.isTerminated } ?? false
            var elementPID: pid_t = 0
            let elementIdentityAvailable = AXUIElementGetPid(target.element, &elementPID) == .success
                && elementPID == target.pid
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
            let focused = isFrontmost ? focusedElement(in: target.pid) : nil
            let sameElement = focused.map { CFEqual($0, target.element) } ?? false

            let expectedRange = validateSelection ? target.selectedTextRange : nil
            let currentRange = focused.flatMap { selectedTextRange(in: $0) }
            let selectionMatches = expectedRange.flatMap { expected in
                currentRange.map { current in
                    expected.location == current.location && expected.length == current.length
                }
            } ?? false
            if let failure = capturedTargetValidation(
                appIsRunning: appIsRunning,
                elementIdentityAvailable: elementIdentityAvailable,
                focusedDestinationAvailable: focused != nil,
                sameElement: sameElement,
                selectionIdentityRequired: expectedRange != nil,
                selectionIdentityAvailable: currentRange != nil,
                selectionMatches: selectionMatches
            ) {
                clipboardFallback(failure)
                return
            }

            operation { sent in
                guard sent else {
                    clipboardFallback(.eventDispatchFailed)
                    return
                }
                completion(.landed)
            }
        }

        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            clipboardFallback(.targetAppUnavailable)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            validateAndLand()
        } else {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: validateAndLand)
        }
    }

    /// Copy-capture the current selection for the Option+P prompt-prep flow: synthesize Cmd+C and,
    /// after a short delay (the copy is async — the target app writes the pasteboard on its own turn),
    /// read what landed. Calls back on the main queue with the captured selection text, or nil when
    /// nothing was selected (the pasteboard `changeCount` never moved). The caller owns snapshotting +
    /// restoring the user's real clipboard around this — this is the mirror of `pasteIntoFocus`'s
    /// Cmd+V synthesis. Synthesizing a Cmd-modified keystroke while right-Option is physically held is
    /// the same path the shipped `undo` Cmd+Z chord uses, so the modifier state is set cleanly.
    static func captureSelectionViaCopy(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let beforeCount = pb.changeCount
        // The frontmost app performs this pasteboard write, so it cannot carry the synthetic
        // marker. Blind the history poller across the whole transient window instead — the copy
        // lands at the target app's leisure and the caller's marked restore replaces it at +0.18s,
        // so 1s covers the transient with ample slack for a congested main thread.
        ClipboardHistory.shared.suppressCapture(for: 1.0)

        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if pb.changeCount != beforeCount {
                let s = pb.string(forType: .string)
                Log.write("copy-capture: selection \(s?.count ?? 0) chars")
                completion(s)
            } else {
                Log.write("copy-capture: no selection (clipboard unchanged)")
                completion(nil)
            }
        }
    }

    static func copyToClipboard(_ text: String) {
        SyntheticPasteboard.write(text)
    }

    /// Two-tier-undo TIER 1 (native-undo revert): fire the focused app's OWN undo (Cmd+Z) to remove
    /// the last paste exactly, then paste the raw transcript in its place. This is literally the user's
    /// manual recovery motion automated (Cmd+Z, then re-paste the original), and it replaces the old
    /// backspace-by-character-count approach — which miscounted whenever the landed text length
    /// differed from the count it deleted (e.g. a runaway model answer) and wiped the whole field.
    /// Leaning on the app's native undo is reliable because the app knows precisely what its last edit
    /// was; we never guess a glyph count.
    ///
    /// Best-effort by nature: native undo reverts the MOST RECENT edit, so this stays correct only for
    /// the freshest paste (caret unmoved, nothing typed since). The controller gates to that case and
    /// downgrades to the clipboard tier otherwise.
    static func undoLastPasteAndPasteRaw(_ raw: String, completion: ((Bool) -> Void)? = nil) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let zKey: CGKeyCode = 6 // 'z'
        let down = CGEvent(keyboardEventSource: src, virtualKey: zKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: zKey, keyDown: false)
        guard let down = down, let up = up else {
            Log.write("undo: native Cmd+Z event unavailable — output retained on clipboard")
            copyToClipboard(raw)
            completion?(false)
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.write("undo: native Cmd+Z fired, pasting raw (\(raw.count) chars)")
        // Let the app apply its undo before we paste, so the raw lands after the revert completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let pasted = TargetResolver.pasteIntoFocus(raw)
            completion?(pasted)
        }
    }
}
