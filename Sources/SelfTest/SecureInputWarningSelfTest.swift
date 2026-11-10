import Foundation

/// Locks the once-per-episode rule of `SecureInputWarningGate` with fake holders and a fake clock.
enum SecureInputWarningSelfTest {
    static func run() -> Bool {
        print("--- secure-input warning gate selftest ---")
        let check = SelfTestReporter()
        let own: pid_t = 100
        let chrome = SecureInput.Holder(pid: 200, appName: "Google Chrome")
        let terminal = SecureInput.Holder(pid: 300, appName: "Terminal")

        var g = SecureInputWarningGate()
        check("no holder: no warning", g.check(holder: nil, ownPid: own, now: 0) == nil)
        check("own process holding: no warning",
              g.check(holder: .init(pid: own, appName: "ViddyDictate"), ownPid: own, now: 1) == nil)

        let first = g.check(holder: chrome, ownPid: own, now: 10)
        check("first press of an episode warns", first != nil)
        check("warning names the holder", first?.contains("Google Chrome") == true)
        check("warning names the lock", first?.contains("the lock") == true)
        check("same holder soon after: quiet", g.check(holder: chrome, ownPid: own, now: 20) == nil)
        check("same holder just under the repeat interval: quiet",
              g.check(holder: chrome, ownPid: own, now: 10 + SecureInputWarningGate.repeatInterval - 1) == nil)
        check("same holder after the repeat interval: warns again",
              g.check(holder: chrome, ownPid: own, now: 10 + SecureInputWarningGate.repeatInterval + 1) != nil)

        let t0: TimeInterval = 5000
        check("same holder long after: warns", g.check(holder: chrome, ownPid: own, now: t0) != nil)
        check("a different holder warns at once", g.check(holder: terminal, ownPid: own, now: t0 + 1) != nil)

        check("holder released", g.check(holder: nil, ownPid: own, now: t0 + 2) == nil)
        check("same holder again after release warns at once",
              g.check(holder: terminal, ownPid: own, now: t0 + 3) != nil)

        print(check.summaryLine(prefix: "[secure-input-warning-selftest]"))
        return check.passed
    }
}
