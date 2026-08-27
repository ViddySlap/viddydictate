import Foundation

/// Offline policy and queue proof for B18. The production adapter is `NWPathMonitor`; this test only
/// drives its value-shaped boundary so it never depends on this Mac's current Wi-Fi, hotspot, or route.
enum NetworkPathSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate network path awareness - selftest ===")
        let reporter = SelfTestReporter()

        checkStateMapping(reporter.record)
        checkCopy(reporter.record)
        checkGate(reporter.record)

        print("\n=== RESULT ===")
        print("network path:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nNETWORK PATH GREEN" : "\nNETWORK PATH FAILED")
        return reporter.passed
    }

    private static func checkStateMapping(_ check: (String, Bool) -> Void) {
        print("--- satisfied, expensive, constrained, and offline states ---")
        let offline = NetworkPathState.unavailable
        let wifi = NetworkPathState(isSatisfied: true)
        let hotspot = NetworkPathState(isSatisfied: true, isExpensive: true)
        let lowData = NetworkPathState(isSatisfied: true, isConstrained: true)
        let both = NetworkPathState(isSatisfied: true, isExpensive: true, isConstrained: true)

        check("unsatisfied path is offline and not download-ready",
              !offline.isSatisfied && !offline.isReadyForDownload && !offline.needsWiFi)
        check("ordinary satisfied path is immediately download-ready",
              wifi.isSatisfied && wifi.isReadyForDownload && !wifi.needsWiFi)
        check("expensive path is satisfied but needs Wi-Fi choice",
              hotspot.isSatisfied && hotspot.needsWiFi && !hotspot.isReadyForDownload)
        check("constrained path is satisfied but needs Wi-Fi choice",
              lowData.isSatisfied && lowData.needsWiFi && !lowData.isReadyForDownload)
        check("both path facts are retained rather than collapsed to offline",
              both.isSatisfied && both.isExpensive && both.isConstrained && both.needsWiFi)
    }

    private static func checkCopy(_ check: (String, Bool) -> Void) {
        print("--- situation-specific warning and immediate offline copy ---")
        let hotspot = NetworkPathState(isSatisfied: true, isExpensive: true)
        let lowData = NetworkPathState(isSatisfied: true, isConstrained: true)
        let both = NetworkPathState(isSatisfied: true, isExpensive: true, isConstrained: true)
        let wifi = NetworkPathState(isSatisfied: true)

        check("hotspot warning names the hotspot and measured total",
              hotspot.warningLine(totalDownload: "2.1 GB")
                == "You are on a hotspot. This will use about 2.1 GB of your data")
        check("Low Data Mode warning names the constrained situation",
              lowData.warningLine(totalDownload: "2.1 GB")
                == "Low Data Mode is on. This will use about 2.1 GB of your data")
        check("combined warning names both actual conditions",
              both.warningLine(totalDownload: "20.4 GB")
                == "You are on a hotspot with Low Data Mode. This will use about 20.4 GB of your data")
        check("a clear path has no metered warning",
              wifi.warningLine(totalDownload: "2.1 GB") == nil)
        check("offline copy says no network and offers Set up later",
              NetworkPathCopy.noNetworkMessage.contains("No network connection")
                && NetworkPathCopy.noNetworkMessage.contains("set up later")
                && NetworkPathCopy.setUpLaterButton == "Set up later")
        check("the Wi-Fi action uses the locked button label",
              NetworkPathCopy.waitForWiFiButton == "Wait for Wi-Fi")
    }

    private static func checkGate(_ check: (String, Bool) -> Void) {
        print("--- continue, wait, cancel, and automatic release ---")
        let fake = FakeMonitor()
        let gate = NetworkDownloadGate(
            monitor: fake,
            initialPath: NetworkPathState(isSatisfied: true, isExpensive: true))
        var starts = 0
        var stateChanges = 0
        gate.onStateChange = { stateChanges += 1 }
        gate.startMonitoring()

        let continued = gate.startDownload { starts += 1 }
        check("Continue starts immediately on an available hotspot",
              continued == .started && starts == 1 && gate.state == .meteredOrConstrained)

        let held = gate.waitForWiFi { starts += 1 }
        check("Wait for Wi-Fi holds the queue on a metered path",
              held == .waitingForWiFi && starts == 1 && gate.state == .waitingForWiFi)

        fake.emit(.unavailable)
        check("a path loss while waiting is shown as no network immediately",
              starts == 1 && gate.state == .noNetwork)
        fake.emit(NetworkPathState(isSatisfied: true, isExpensive: true, isConstrained: true))
        check("a still constrained update does not release the queue",
              starts == 1 && gate.state == .waitingForWiFi)

        fake.emit(NetworkPathState(isSatisfied: true))
        check("the first clear path releases the queue exactly once",
              starts == 2 && gate.state == .ready)
        fake.emit(NetworkPathState(isSatisfied: true))
        check("later clear updates do not replay the queued start",
              starts == 2)

        fake.emit(.unavailable)
        let offline = gate.startDownload { starts += 1 }
        check("offline Continue returns Set up later without spending retries",
              offline == .setUpLater && starts == 2 && gate.state == .noNetwork)

        fake.emit(NetworkPathState(isSatisfied: true, isConstrained: true))
        _ = gate.waitForWiFi { starts += 1 }
        gate.setUpLater()
        fake.emit(NetworkPathState(isSatisfied: true))
        check("Set up later cancels a held queue and prevents a late start",
              starts == 2 && gate.state == .ready)
        check("monitoring starts once and publishes state changes",
              fake.startCount == 1 && stateChanges >= 7)

        gate.stopMonitoring()
        check("stopping the gate cancels its injected monitor",
              fake.cancelCount == 1)
    }

    private final class FakeMonitor: NetworkPathMonitoring {
        var onChange: ((NetworkPathState) -> Void)?
        private(set) var startCount = 0
        private(set) var cancelCount = 0

        func start() { startCount += 1 }
        func cancel() { cancelCount += 1 }
        func emit(_ state: NetworkPathState) { onChange?(state) }
    }
}
