import Cocoa
import CoreGraphics

/// Global key listener via a CGEventTap. The grammar is now fully **data-driven** by a `HotkeyMap`
/// (ADR 0003 — the fixed-grammar invariant is retired): hold the wakeup key, tap a chord key.
///   - The **wakeup** may be a modifier (default right-Option, tracked via the device flag) OR a
///     regular key (tracked via keyDown/keyUp and *consumed* — it can no longer type while held).
///   - Each **chord** fires its command while the wakeup is held and is swallowed so the bare key
///     never types. Chords are regular keys by default but may also be modifiers.
/// A **capture** mode (used by the Settings rebinding table) swallows the next key press and reports
/// it as a `KeySpec` instead of running any command — so binding a key never triggers a dictation.
/// Requires Input Monitoring + Accessibility.
final class HotkeyMonitor {
    private struct ModalPicker {
        let active: Bool
        let onLeft: (() -> Void)?
        let onRight: (() -> Void)?
        let onCommit: (() -> Void)?
        let onCancel: (() -> Void)?
    }

    /// The live binding map. Swap it (then nothing else) to apply a rebind; reads are lock-free on the
    /// main thread where the tap callback dispatches.
    var map = HotkeyMap.defaults()

    var onRightOptionDown: (() -> Void)?   // wakeup down
    var onRightOptionUp: (() -> Void)?     // wakeup up

    /// Single sink for every built-in chord command. `fire()` forwards the matched `HotkeyCommand` here
    /// instead of through one bespoke closure per command; the controller switches on it once. Adding a
    /// built-in hotkey no longer touches this file - it is a new `HotkeyCommand` case (HotkeyMap) plus one
    /// dispatch arm in the controller (review item 3).
    var onCommand: ((HotkeyCommand) -> Void)?

    /// User-defined custom-mode chords, matched after the built-in map. Snapshot of (id, spec) refreshed
    /// alongside `map` on `reloadHotkeys`. Conflict detection keeps these disjoint from the built-in keys,
    /// so at most one of `map`/`customChords` matches a given press.
    var customChords: [(id: String, spec: KeySpec)] = []
    /// Sink for a matched custom-mode chord (the mode's id). The controller resolves it to the descriptor
    /// and runs it through the shared one-shot engine.
    var onCustomCommand: ((String) -> Void)?

    /// Rebinding capture (Settings Hotkeys tab). While `captureActive`, the tap swallows the next key
    /// press and reports it instead of running any command — Escape cancels. Set by `beginCapture`.
    private(set) var captureActive = false
    private var onKeyCaptured: ((KeySpec) -> Void)?
    private var onCaptureCancelled: (() -> Void)?
    /// The shift bit pressed during a capture but not yet committed (see `handleCapture`): shift doubles as a
    /// chord qualifier, so capture waits to see whether a key follows it (⇧key) or it is released alone (Shift
    /// itself as the chord). Nil whenever no capture is in flight.
    private var pendingShiftMask: Int64?
    /// The device shift bits (left + right), the only modifiers that also act as a chord qualifier.
    private static let shiftMasks: Int64 = 0x04 | 0x02

    /// A/B picker (cleanup-suspect guard) navigation. While `abPickerActive`, the tap swallows the
    /// arrow / Return / Escape keys and routes them here instead of letting them reach the focused
    /// field — so the picker is keyboard-driven without ever stealing focus from the user's text field
    /// (the chosen text then pastes straight back into that still-focused field).
    var abPickerActive = false
    var onABLeft: (() -> Void)?
    var onABRight: (() -> Void)?
    var onABCommit: (() -> Void)?
    var onABCancel: (() -> Void)?

    /// Cleanup-selection level picker. Same keyboard-over-the-tap pattern as the A/B picker but for the
    /// 3-level Cleanup / Tighten / Summarize pick: while `levelPickerActive`, the tap swallows the
    /// arrow / Return / Escape keys and routes them here, so the user's text field keeps focus and the
    /// transformed text pastes straight back into it. The two pickers are never up simultaneously.
    var levelPickerActive = false
    var onLevelLeft: (() -> Void)?
    var onLevelRight: (() -> Void)?
    var onLevelCommit: (() -> Void)?
    var onLevelCancel: (() -> Void)?

    /// One-shot clipboard restore for the click-away delivery fallback. When a dictation can't reach a
    /// field it is parked on the clipboard; while `pasteRestoreArmed` the tap OBSERVES (never swallows)
    /// the next Cmd+V and reports it, so the controller can snap the clipboard back to its pre-dictation
    /// contents once the paste has landed.
    var pasteRestoreArmed = false
    var onPasteWhileArmed: (() -> Void)?

    /// Take controls (notes-bullseye BT5). While `takeActive` (a dictation take is recording / locked / in its
    /// final processing) the tap swallows Escape and routes it to `onCancelTake`, so Esc aborts the in-progress
    /// take instead of reaching the focused app. When no take is active, Escape passes through as a normal key.
    /// Mirrored from the controller's `setActive`. The transient pickers above take Escape priority (their blocks
    /// run first), so an Esc during the A/B / level pick cancels the pick, not the whole take.
    /// DictationController.State mirrors the lifecycle split, but this flag — not that enum — gates Esc here.
    var takeActive = false
    var onCancelTake: (() -> Void)?

    private(set) var wakeupHeld = false
    /// Set true once a regular-key wakeup's keyDown latched, so autorepeat keyDowns are swallowed
    /// silently and only the first one fires `onRightOptionDown`.
    private var regularWakeupLatched = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var sawAnyEvent = false

    /// Running snapshot of the known device-modifier bits currently set, so a flagsChanged can tell a
    /// NEW press (for a modifier chord or a capture) from a release or a still-held modifier.
    private var currentModifierBits: Int64 = 0

    // Fixed picker / paste navigation keys (NOT rebindable — they drive transient panels).
    private let vKeyCode: Int64 = 9           // Cmd+V, observed for one-shot clipboard restore
    private let leftArrowKeyCode: Int64 = 123
    private let rightArrowKeyCode: Int64 = 124
    private let returnKeyCode: Int64 = 36
    private let escapeKeyCode: Int64 = 53

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)   // needed to release a regular-key wakeup
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Force the tap back on (e.g. after the Mac wakes, where the system may have disabled it).
    func reEnable() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("tap re-enabled")
    }

    // MARK: capture (rebinding)

    /// Arm capture: the next key press is reported via `onCapture` (or `onCancel` on Escape) instead of
    /// running a command. Safe to call from the main thread (the Settings UI). Cancels any prior arm.
    func beginCapture(onCapture: @escaping (KeySpec) -> Void, onCancel: @escaping () -> Void) {
        onKeyCaptured = onCapture
        onCaptureCancelled = onCancel
        pendingShiftMask = nil
        captureActive = true
    }

    func cancelCapture() {
        captureActive = false
        onKeyCaptured = nil
        onCaptureCancelled = nil
        pendingShiftMask = nil
    }

    // MARK: tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if !sawAnyEvent { sawAnyEvent = true; Log.write("tap: first event received (type=\(type.rawValue))") }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("tap DISABLED (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")) — re-enabling")
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Rebinding capture takes absolute priority so binding a key never starts a dictation.
        if captureActive {
            return handleCapture(type: type, event: event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }
        if type == .keyUp {
            // Only meaningful for a regular-key wakeup release.
            let w = map.wakeup
            if !w.isModifier, event.getIntegerValueField(.keyboardEventKeycode) == w.code, wakeupHeld {
                wakeupHeld = false
                regularWakeupLatched = false
                Log.write("wakeup (regular) UP")
                DispatchQueue.main.async { self.onRightOptionUp?() }
                return nil   // consumed
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            return handleKeyDown(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let bits = Int64(bitPattern: UInt64(event.flags.rawValue)) & KeyNaming.allModifierBits
        let newlySet = bits & ~currentModifierBits
        defer { currentModifierBits = bits }

        let w = map.wakeup
        // Wakeup held-state when the wakeup is a modifier.
        if w.isModifier {
            let held = (bits & w.code) != 0
            if held != wakeupHeld {
                wakeupHeld = held
                Log.write("wakeup (mod) \(held ? "DOWN" : "UP")")
                DispatchQueue.main.async { held ? self.onRightOptionDown?() : self.onRightOptionUp?() }
            }
        }
        // Modifier-as-chord: a newly-pressed modifier (other than the wakeup) while the wakeup is held.
        if wakeupHeld, newlySet != 0 {
            for (mask, _) in KeyNaming.modifiers where (newlySet & mask) != 0 {
                if w.isModifier && mask == w.code { continue }
                if let c = map.command(forModifierMask: mask) {
                    Log.write("chord (mod 0x\(String(mask, radix: 16))) -> \(c.rawValue)")
                    fire(c)
                    break
                }
                if let id = customChords.first(where: { $0.spec.isModifier && $0.spec.code == mask })?.id {
                    Log.write("chord (mod 0x\(String(mask, radix: 16))) -> custom \(id)")
                    fireCustom(id)
                    break
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // One-shot clipboard restore: observe (never swallow) the next Cmd+V after a click-away
        // clipboard park, so the controller can restore the prior clipboard once the paste lands.
        if pasteRestoreArmed, keyCode == vKeyCode, event.flags.contains(.maskCommand) {
            pasteRestoreArmed = false
            DispatchQueue.main.async { self.onPasteWhileArmed?() }
            // fall through and pass the event so the paste itself still happens
        }

        // Transient pickers take priority over take-cancel and normal hotkeys. Matching navigation
        // keys are swallowed so they never reach the focused field.
        if dispatchModalPickerKey(keyCode) { return nil }

        // BT5: Esc aborts an in-progress take. Only while a take is active (recording / locked / final
        // processing); otherwise Esc is a normal key and passes through. Placed AFTER the picker blocks so an Esc
        // during the A/B / level pick cancels the pick (handled above), not the whole take.
        if takeActive, keyCode == escapeKeyCode {
            DispatchQueue.main.async { self.onCancelTake?() }
            return nil   // swallow so Esc never reaches the focused app while a take is being canceled
        }

        let w = map.wakeup
        // Regular-key wakeup: latch on its keyDown (swallow autorepeat), fire once.
        if !w.isModifier, keyCode == w.code {
            if !regularWakeupLatched {
                regularWakeupLatched = true
                wakeupHeld = true
                Log.write("wakeup (regular) DOWN")
                DispatchQueue.main.async { self.onRightOptionDown?() }
            }
            return nil   // consumed — a regular wakeup key never types while the app runs
        }

        // Chords: while the wakeup is held, a regular chord key fires its command and is swallowed. The shift
        // state is read from the live event because a chord may be SHIFT-QUALIFIED (Option+Shift+N reveal),
        // which is a different binding from the same key unshifted (Option+N).
        if wakeupHeld, let hit = resolveChord(keyCode: keyCode, shiftHeld: event.flags.contains(.maskShift)) {
            switch hit {
            case .builtIn(let c):
                Log.write("chord (key \(keyCode)) -> \(c.rawValue)")
                fire(c)
            case .custom(let id):
                Log.write("chord (key \(keyCode)) -> custom \(id)")
                fireCustom(id)
            }
            return nil   // swallow so the bare key never types into the field
        }
        return Unmanaged.passUnretained(event)
    }

    private enum ChordHit {
        case builtIn(HotkeyCommand)
        case custom(String)
    }

    /// Resolve a regular chord keyDown to the command (or custom mode) it fires, in two passes.
    ///
    /// **Pass 1 — exact.** When Shift is held, a binding explicitly qualified with Shift wins. This is what
    /// lets Option+Shift+N reach the bullseye reveal while Option+N still sets/arms.
    /// **Pass 2 — unshifted.** Otherwise fall back to the plain binding for that keycode. This is what keeps
    /// every pre-existing chord behaving exactly as before: nothing claims Shift+P, so right-Option+Shift+P
    /// still fires Cleanup selection, as it always did.
    ///
    /// Built-ins are checked before custom modes within each pass, matching the pre-shift precedence (conflict
    /// detection keeps the two namespaces disjoint, so at most one can match anyway).
    private func resolveChord(keyCode: Int64, shiftHeld: Bool) -> ChordHit? {
        if shiftHeld {
            if let c = map.command(forKeyCode: keyCode, shift: true) { return .builtIn(c) }
            if let id = customChord(forKeyCode: keyCode, shift: true) { return .custom(id) }
        }
        if let c = map.command(forKeyCode: keyCode, shift: false) { return .builtIn(c) }
        if let id = customChord(forKeyCode: keyCode, shift: false) { return .custom(id) }
        return nil
    }

    private func customChord(forKeyCode keyCode: Int64, shift: Bool) -> String? {
        customChords.first { !$0.spec.isModifier && $0.spec.code == keyCode && $0.spec.shift == shift }?.id
    }

    /// Route transient picker keys in declared priority order. A/B intentionally wins if both
    /// pickers are ever active despite their normal mutual-exclusion invariant.
    private func dispatchModalPickerKey(_ keyCode: Int64) -> Bool {
        let pickersInPriorityOrder = [
            ModalPicker(
                active: abPickerActive,
                onLeft: onABLeft,
                onRight: onABRight,
                onCommit: onABCommit,
                onCancel: onABCancel
            ),
            ModalPicker(
                active: levelPickerActive,
                onLeft: onLevelLeft,
                onRight: onLevelRight,
                onCommit: onLevelCommit,
                onCancel: onLevelCancel
            ),
        ]

        for picker in pickersInPriorityOrder where picker.active {
            switch keyCode {
            case leftArrowKeyCode:
                DispatchQueue.main.async { picker.onLeft?() }
                return true
            case rightArrowKeyCode:
                DispatchQueue.main.async { picker.onRight?() }
                return true
            case returnKeyCode:
                DispatchQueue.main.async { picker.onCommit?() }
                return true
            case escapeKeyCode:
                DispatchQueue.main.async { picker.onCancel?() }
                return true
            default:
                continue
            }
        }
        return false
    }

    private func handleCapture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            let bits = Int64(bitPattern: UInt64(event.flags.rawValue)) & KeyNaming.allModifierBits
            let newlySet = bits & ~currentModifierBits
            currentModifierBits = bits
            // Shift is DEFERRED, every other modifier commits on the spot. Shift is the one modifier that is
            // also a chord QUALIFIER (Option+Shift+N), so committing it the instant it goes down would make a
            // shift-qualified binding uncapturable — the user could never get past pressing Shift. Instead we
            // remember it and wait: a following keyDown becomes ⇧key; releasing Shift on its own (bits back to
            // no shift with no key pressed) commits Shift itself, so binding a bare Shift chord still works.
            let newShift = newlySet & Self.shiftMasks
            if newShift != 0 {
                pendingShiftMask = KeyNaming.modifiers.first { ($0.mask & newShift) != 0 }?.mask
                return Unmanaged.passUnretained(event)
            }
            if let pending = pendingShiftMask, (bits & Self.shiftMasks) == 0 {
                pendingShiftMask = nil
                finishCapture(with: .modifier(mask: pending, label: KeyNaming.modifierLabel(forMask: pending)))
                return Unmanaged.passUnretained(event)
            }
            for (mask, label) in KeyNaming.modifiers where (newlySet & mask) != 0 {
                let spec = KeySpec.modifier(mask: mask, label: label)
                finishCapture(with: spec)
                break
            }
            return Unmanaged.passUnretained(event)   // modifiers don't type — safe to pass through
        }
        if type == .keyUp {
            return nil   // swallow stray key-ups during capture
        }
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == escapeKeyCode {
                let cancel = onCaptureCancelled
                cancelCapture()
                DispatchQueue.main.async { cancel?() }
                return nil
            }
            let shift = pendingShiftMask != nil || event.flags.contains(.maskShift)
            let char = unicodeString(from: event)
            let spec = KeySpec.regular(keyCode: keyCode,
                                       label: KeyNaming.regularLabel(keyCode: keyCode, char: char, shift: shift),
                                       shift: shift)
            finishCapture(with: spec)
            return nil   // swallow so the captured key never types
        }
        return Unmanaged.passUnretained(event)
    }

    private func finishCapture(with spec: KeySpec) {
        let cb = onKeyCaptured
        cancelCapture()
        DispatchQueue.main.async { cb?(spec) }
    }

    /// Dispatch a chord command to the single sink (on the main thread, as the rest of the tap does).
    private func fire(_ command: HotkeyCommand) {
        DispatchQueue.main.async { self.onCommand?(command) }
    }

    /// Dispatch a matched custom-mode chord (by id) to its sink (main thread, as the rest of the tap does).
    private func fireCustom(_ id: String) {
        DispatchQueue.main.async { self.onCustomCommand?(id) }
    }

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        return length > 0 ? String(utf16CodeUnits: chars, count: length) : ""
    }
}
