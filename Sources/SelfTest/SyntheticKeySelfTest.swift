import Cocoa
import CoreGraphics

enum SyntheticKeySelfTest {
    static func run() -> Bool {
        print("[synthetic-key-selftest] running")
        let reporter = SelfTestReporter()

        // Row 1: the marker is stamped on events built by the one construction site.
        let made = SyntheticKeystroke.make(virtualKey: 8, keyDown: true, flags: .maskCommand)
        let markerSet = made?.getIntegerValueField(.eventSourceUserData) == SyntheticKeystroke.marker
        reporter.record("synthetic keys: the marker is set on an event made by SyntheticKeystroke.make", markerSet)

        // Row 2: source check of the repository copies (no live construction, no event posted).
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDir = repoRoot.appendingPathComponent("Sources").appendingPathComponent("App")
        var swiftFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: appDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }
        var totalConstructors = 0
        var synthConstructors = 0
        var synthMarkerWrites = 0
        var targetConstructors = 0
        var targetMakes = 0
        for url in swiftFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            totalConstructors += text.components(separatedBy: "CGEvent(keyboardEventSource").count - 1
            if url.lastPathComponent == "SyntheticKeystroke.swift" {
                synthConstructors = text.components(separatedBy: "CGEvent(keyboardEventSource").count - 1
                synthMarkerWrites = text.components(separatedBy: "setIntegerValueField(.eventSourceUserData").count - 1
            }
            if url.lastPathComponent == "TargetResolver.swift" {
                targetConstructors = text.components(separatedBy: "CGEvent(").count - 1
                targetMakes = text.components(separatedBy: "SyntheticKeystroke.make(").count - 1
            }
        }
        let sourceOK = totalConstructors == 1
            && synthConstructors == 1
            && synthMarkerWrites == 1
            && targetConstructors == 0
            && targetMakes == 8
        reporter.record("synthetic keys: TargetResolver builds every keystroke through SyntheticKeystroke.make", sourceOK)

        // Row 3: an own Cmd+C keyDown while the wakeup is held passes through and fires nothing.
        var countC = 0
        let monitorC = monitorWithChords([("c", 8), ("v", 9)])
        monitorC.onCustomCommand = { _ in countC += 1 }
        holdWakeup(monitorC)
        let ownC = SyntheticKeystroke.make(virtualKey: 8, keyDown: true, flags: .maskCommand)!
        let retC = monitorC.selfTestHandle(type: .keyDown, event: ownC)
        drain()
        reporter.record("synthetic keys: an own Cmd+C keyDown while the wakeup is held passes through and fires nothing",
            retC != nil && countC == 0)

        // Row 4: an own Cmd+V keyDown while the wakeup is held passes through and fires nothing.
        var countV = 0
        let monitorV = monitorWithChords([("c", 8), ("v", 9)])
        monitorV.onCustomCommand = { _ in countV += 1 }
        holdWakeup(monitorV)
        let ownV = SyntheticKeystroke.make(virtualKey: 9, keyDown: true, flags: .maskCommand)!
        let retV = monitorV.selfTestHandle(type: .keyDown, event: ownV)
        drain()
        reporter.record("synthetic keys: an own Cmd+V keyDown while the wakeup is held passes through and fires nothing",
            retV != nil && countV == 0)

        // Row 5: an unmarked C keyDown while the wakeup is held fires the bound custom chord exactly once and is swallowed.
        var countUnmarked = 0
        let monitorUnmarked = monitorWithChords([("c", 8)])
        monitorUnmarked.onCustomCommand = { _ in countUnmarked += 1 }
        holdWakeup(monitorUnmarked)
        let unmarkedC = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        let retUnmarked = monitorUnmarked.selfTestHandle(type: .keyDown, event: unmarkedC)
        drain()
        reporter.record("synthetic keys: an unmarked C keyDown while the wakeup is held fires the bound custom chord exactly once and is swallowed",
            retUnmarked == nil && countUnmarked == 1)

        // Row 6: 50 own Cmd+C keyDowns in a row fire the custom chord zero times.
        var countBurst = 0
        let monitorBurst = monitorWithChords([("c", 8), ("v", 9)])
        monitorBurst.onCustomCommand = { _ in countBurst += 1 }
        holdWakeup(monitorBurst)
        for _ in 0..<50 {
            let ev = SyntheticKeystroke.make(virtualKey: 8, keyDown: true, flags: .maskCommand)!
            _ = monitorBurst.selfTestHandle(type: .keyDown, event: ev)
        }
        drain()
        reporter.record("synthetic keys: 50 own Cmd+C keyDowns in a row fire the custom chord zero times",
            countBurst == 0)

        // Row 7: an own keyUp passes through unchanged.
        let monitorUp = HotkeyMonitor()
        monitorUp.map.wakeup = .regular(keyCode: 42, label: "W")
        let latch = CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true)!
        _ = monitorUp.selfTestHandle(type: .keyDown, event: latch)
        let ownUp = SyntheticKeystroke.make(virtualKey: 42, keyDown: false, flags: [])!
        let retUp = monitorUp.selfTestHandle(type: .keyUp, event: ownUp)
        drain()
        reporter.record("synthetic keys: an own keyUp passes through unchanged", retUp != nil)

        // Row 8: an own keyDown during key capture is not captured and passes through.
        var captured = false
        let monitorCapture = HotkeyMonitor()
        monitorCapture.beginCapture(onCapture: { _ in captured = true }, onCancel: {})
        let ownCapture = SyntheticKeystroke.make(virtualKey: 8, keyDown: true, flags: .maskCommand)!
        let retCapture = monitorCapture.selfTestHandle(type: .keyDown, event: ownCapture)
        drain()
        reporter.record("synthetic keys: an own keyDown during key capture is not captured and passes through",
            retCapture != nil && captured == false)

        // Row 9: an own Cmd+V while paste-restore is armed still triggers the paste-restore observer once and passes through.
        var observed = 0
        let monitorPaste = HotkeyMonitor()
        monitorPaste.pasteRestoreArmed = true
        monitorPaste.onPasteWhileArmed = { observed += 1 }
        let ownPaste = SyntheticKeystroke.make(virtualKey: 9, keyDown: true, flags: .maskCommand)!
        let retPaste = monitorPaste.selfTestHandle(type: .keyDown, event: ownPaste)
        drain()
        reporter.record("synthetic keys: an own Cmd+V while paste-restore is armed still triggers the paste-restore observer once and passes through",
            retPaste != nil && observed == 1)

        // Row 10: a plain Esc (keyCode 53, no modifiers) with a take active does NOT cancel and passes through.
        var plainCancel = 0
        let monitorPlainEsc = HotkeyMonitor()
        monitorPlainEsc.takeActive = true
        monitorPlainEsc.onCancelTake = { plainCancel += 1 }
        let plainEsc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        let retPlainEsc = monitorPlainEsc.selfTestHandle(type: .keyDown, event: plainEsc)
        drain()
        reporter.record("synthetic keys: plain Esc with a take active does not cancel and passes through",
            retPlainEsc != nil && plainCancel == 0)

        // Row 11: Option+Esc (keyCode 53, .maskAlternate) with a take active DOES cancel and is swallowed.
        var optionCancel = 0
        let monitorOptionEsc = HotkeyMonitor()
        monitorOptionEsc.takeActive = true
        monitorOptionEsc.onCancelTake = { optionCancel += 1 }
        let optionEsc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        optionEsc.flags = .maskAlternate
        let retOptionEsc = monitorOptionEsc.selfTestHandle(type: .keyDown, event: optionEsc)
        drain()
        reporter.record("synthetic keys: Option+Esc with a take active cancels and is swallowed",
            retOptionEsc == nil && optionCancel == 1)

        print(reporter.summaryLine(prefix: "[synthetic-key-selftest]"))
        return reporter.passed
    }

    private static func monitorWithChords(_ chords: [(String, Int64)]) -> HotkeyMonitor {
        let monitor = HotkeyMonitor()
        for (id, keyCode) in chords {
            monitor.selfTestInstallCustomChord(id: id, keyCode: keyCode)
        }
        return monitor
    }

    private static func holdWakeup(_ monitor: HotkeyMonitor) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        e.flags = CGEventFlags(rawValue: 0x40)
        _ = monitor.selfTestHandle(type: .flagsChanged, event: e)
    }

    private static func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
