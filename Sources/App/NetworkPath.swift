import Foundation
import Network

/// The part of the current network path that first-run setup needs to know.
///
/// `NWPath` is deliberately reduced to these three facts at the boundary. The picker and download
/// queue must not make their own guesses from interface names: `isExpensive` covers a hotspot or
/// cellular route, while `isConstrained` covers Low Data Mode even when the interface is Wi-Fi.
struct NetworkPathState: Equatable {
    let isSatisfied: Bool
    let isExpensive: Bool
    let isConstrained: Bool

    static let unavailable = NetworkPathState(isSatisfied: false)

    init(isSatisfied: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(path: NWPath) {
        self.init(isSatisfied: path.status == .satisfied,
                  isExpensive: path.isExpensive,
                  isConstrained: path.isConstrained)
    }

    /// A satisfied but expensive or constrained path should not be treated as offline. Continue remains
    /// available, while the separate Wait for Wi-Fi action can hold the queue without starting it.
    var needsWiFi: Bool {
        isSatisfied && (isExpensive || isConstrained)
    }

    var isReadyForDownload: Bool {
        isSatisfied && !needsWiFi
    }

    /// The warning names the situation the user can act on, rather than hiding it behind "large download".
    /// The total is supplied by the picker so this type never owns a stale estimate or byte count.
    func warningLine(totalDownload: String) -> String? {
        guard needsWiFi else { return nil }
        switch (isExpensive, isConstrained) {
        case (true, true):
            return "You are on a hotspot with Low Data Mode. This will use about "
                + "\(totalDownload) of your data"
        case (true, false):
            return "You are on a hotspot. This will use about \(totalDownload) of your data"
        case (false, true):
            return "Low Data Mode is on. This will use about \(totalDownload) of your data"
        case (false, false):
            return nil
        }
    }
}

/// User-facing strings owned by the network-path seam. Later setup surfaces consume these instead of
/// inventing a second spelling for the same no-network and metered-path decisions.
enum NetworkPathCopy {
    static let waitForWiFiButton = "Wait for Wi-Fi"
    static let setUpLaterButton = "Set up later"
    /// What the screen says while the queue is held. The gate releases itself on the first clear path,
    /// so the line has to promise that rather than leave the user waiting for something to press.
    static let waitingForWiFiMessage =
        "Waiting for Wi-Fi. The download starts on its own the moment you are on one."
    static let noNetworkMessage =
        "No network connection. You can set up later and come back when you are online."
}

/// A tiny protocol keeps policy tests offline and prevents them from consulting this Mac's real path.
protocol NetworkPathMonitoring: AnyObject {
    var onChange: ((NetworkPathState) -> Void)? { get set }
    func start()
    func cancel()
}

/// The production Network framework adapter. Its callback is intentionally value-shaped so the picker,
/// queue, and selftests all consume the same three measured path facts.
final class NetworkPathMonitor: NetworkPathMonitoring {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private var didStart = false
    private var didCancel = false

    var onChange: ((NetworkPathState) -> Void)?

    init(monitor: NWPathMonitor = NWPathMonitor(),
         queue: DispatchQueue = DispatchQueue(label: "com.viddydictate.network-path-monitor",
                                               qos: .utility),
         deliveryQueue: DispatchQueue = .main) {
        self.monitor = monitor
        self.queue = queue
        self.deliveryQueue = deliveryQueue
    }

    func start() {
        guard !didStart, !didCancel else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            let state = NetworkPathState(path: path)
            self?.deliveryQueue.async { [weak self] in self?.onChange?(state) }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        monitor.cancel()
        onChange = nil
    }
}

enum NetworkDownloadDecision: Equatable {
    case started
    case waitingForWiFi
    case setUpLater
}

enum NetworkDownloadGateState: Equatable {
    case noNetwork
    case ready
    case meteredOrConstrained
    case waitingForWiFi
}

/// Coordinates the picker action with the current path without owning the installer or its retry policy.
///
/// Continue starts on any satisfied path, including a hotspot. The explicit Wait for Wi-Fi action stores
/// the queue's start closure and releases it once, automatically, on the first satisfied path that is
/// neither expensive nor constrained. An unsatisfied path never enters a retry loop: callers get the
/// immediate Set up later decision and can leave the app in its reduced state.
final class NetworkDownloadGate {
    private let monitor: NetworkPathMonitoring
    private var pendingStart: (() -> Void)?
    private var monitoring = false
    private var waitingForWiFi = false

    private(set) var path: NetworkPathState
    private(set) var state: NetworkDownloadGateState

    /// Called after every path/state change. UI callers can re-render from `path` and `state`; the gate
    /// itself never assumes an AppKit queue.
    var onStateChange: (() -> Void)?

    init(monitor: NetworkPathMonitoring,
         initialPath: NetworkPathState = .unavailable) {
        self.monitor = monitor
        self.path = initialPath
        self.state = Self.state(for: initialPath, waitingForWiFi: false)
    }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        monitor.onChange = { [weak self] path in self?.apply(path) }
        monitor.start()
    }

    func stopMonitoring() {
        pendingStart = nil
        waitingForWiFi = false
        monitoring = false
        monitor.cancel()
    }

    /// Continue's action. A satisfied path starts immediately; a missing path does not spend retries.
    @discardableResult
    func startDownload(_ start: @escaping () -> Void) -> NetworkDownloadDecision {
        pendingStart = nil
        waitingForWiFi = false
        guard path.isSatisfied else {
            publish(state: .noNetwork)
            return .setUpLater
        }
        publish(state: Self.state(for: path, waitingForWiFi: false))
        start()
        return .started
    }

    /// The explicit Wait for Wi-Fi action. If the path clears between rendering and the click, starting
    /// immediately is the safe race-free outcome; otherwise this keeps the queue pending until `apply`.
    @discardableResult
    func waitForWiFi(_ start: @escaping () -> Void) -> NetworkDownloadDecision {
        guard path.isSatisfied else {
            publish(state: .noNetwork)
            return .setUpLater
        }
        guard path.needsWiFi else { return startDownload(start) }
        pendingStart = start
        waitingForWiFi = true
        publish(state: .waitingForWiFi)
        return .waitingForWiFi
    }

    /// Set up later cancels only this pending queue action. It does not alter the measured path.
    func setUpLater() {
        pendingStart = nil
        waitingForWiFi = false
        publish(state: Self.state(for: path, waitingForWiFi: false))
    }

    private func apply(_ newPath: NetworkPathState) {
        path = newPath
        guard waitingForWiFi, newPath.isReadyForDownload else {
            publish(state: Self.state(for: newPath, waitingForWiFi: waitingForWiFi))
            return
        }
        let start = pendingStart
        pendingStart = nil
        waitingForWiFi = false
        publish(state: .ready)
        start?()
    }

    private func publish(state: NetworkDownloadGateState) {
        self.state = state
        onStateChange?()
    }

    private static func state(for path: NetworkPathState, waitingForWiFi: Bool) -> NetworkDownloadGateState {
        if !path.isSatisfied { return .noNetwork }
        if waitingForWiFi { return .waitingForWiFi }
        return path.needsWiFi ? .meteredOrConstrained : .ready
    }
}
