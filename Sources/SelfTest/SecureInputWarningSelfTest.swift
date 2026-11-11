import Foundation

/// Locks the once-per-episode rule of `SecureInputWarningGate` with fake holders and a fake clock.
enum SecureInputWarningSelfTest {
    static func run() -> Bool {
        print("--- secure-input warning gate selftest ---")
        let check = SelfTestReporter()
        let own: pid_t = 100
        let chrome: pid_t = 200
        let terminal: pid_t = 300
        let names: [pid_t: String] = [chrome: "Google Chrome", terminal: "Terminal", own: "ViddyDictate"]
        var lookups = 0
        let name: (pid_t) -> String = { lookups += 1; return names[$0] ?? "pid \($0)" }

        var g = SecureInputWarningGate()
        check("no holder: no warning", g.check(holderPid: nil, ownPid: own, now: 0, appName: name) == nil)
        check("own process holding: no warning", g.check(holderPid: own, ownPid: own, now: 1, appName: name) == nil)
        check("no holder and own process: the name is never looked up", lookups == 0)

        let first = g.check(holderPid: chrome, ownPid: own, now: 10, appName: name)
        check("first press of an episode warns", first != nil)
        check("warning names the holder", first?.contains("Google Chrome") == true)
        check("warning does not promise the lock fails (modifier-bound commands still work)",
              first?.contains("the lock") == false && first?.contains("regular key") == true)
        check("warning says hold-to-talk still works", first?.contains("Hold-to-talk still works") == true)
        check("the name is looked up once for the one warning", lookups == 1)
        check("same holder soon after: quiet", g.check(holderPid: chrome, ownPid: own, now: 20, appName: name) == nil)
        check("a throttled press does not look the name up", lookups == 1)
        check("same holder just under the repeat interval: quiet",
              g.check(holderPid: chrome, ownPid: own, now: 10 + SecureInputWarningGate.repeatInterval - 1, appName: name) == nil)
        check("same holder exactly at the repeat interval: warns again",
              g.check(holderPid: chrome, ownPid: own, now: 10 + SecureInputWarningGate.repeatInterval, appName: name) != nil)
        check("same holder after the repeat interval: quiet right after that warning",
              g.check(holderPid: chrome, ownPid: own, now: 10 + SecureInputWarningGate.repeatInterval + 1, appName: name) == nil)

        let t0: TimeInterval = 5000
        check("same holder long after: warns", g.check(holderPid: chrome, ownPid: own, now: t0, appName: name) != nil)
        check("a different holder warns at once", g.check(holderPid: terminal, ownPid: own, now: t0 + 1, appName: name) != nil)

        check("holder released", g.check(holderPid: nil, ownPid: own, now: t0 + 2, appName: name) == nil)
        check("same holder again after release warns at once",
              g.check(holderPid: terminal, ownPid: own, now: t0 + 3, appName: name) != nil)

        // Own-pid episode resets the throttle: external, then the app's own hold, then the same external holder.
        var h = SecureInputWarningGate()
        check("episode A: external holder warns", h.check(holderPid: chrome, ownPid: own, now: 100, appName: name) != nil)
        check("own pid after the external holder: quiet", h.check(holderPid: own, ownPid: own, now: 110, appName: name) == nil)
        check("the same external holder after an own-pid episode warns at once",
              h.check(holderPid: chrome, ownPid: own, now: 120, appName: name) != nil)

        // Press ordering: the take starts before the holder's name is looked up.
        var events: [String] = []
        let shown = SecureInputPress.afterGate(
            warnPid: chrome,
            beginRecording: { events.append("begin"); return true },
            appName: { events.append("name"); return names[$0] ?? "pid \($0)" },
            toast: { _ in events.append("toast") })
        check("press order: begin, then name lookup, then toast", events == ["begin", "name", "toast"])
        check("the warning is kept for the release replay", shown?.contains("Google Chrome") == true)

        events = []
        let none = SecureInputPress.afterGate(
            warnPid: nil,
            beginRecording: { events.append("begin"); return true },
            appName: { events.append("name"); return names[$0] ?? "pid \($0)" },
            toast: { _ in events.append("toast") })
        check("no warning due: begin only, no name lookup, no toast", events == ["begin"] && none == nil)

        events = []
        let failed = SecureInputPress.afterGate(
            warnPid: chrome,
            beginRecording: { events.append("begin"); return false },
            appName: { events.append("name"); return names[$0] ?? "pid \($0)" },
            toast: { _ in events.append("toast") })
        check("take failed to start: no name lookup, no toast, nothing kept for release",
              events == ["begin"] && failed == nil)

        print(check.summaryLine(prefix: "[secure-input-warning-selftest]"))
        return check.passed
    }
}
