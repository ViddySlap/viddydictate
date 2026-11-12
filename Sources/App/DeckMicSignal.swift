import Foundation

/// Reads the Deck microphone signal from RM's local helper, once, at take start. Loopback only,
/// bounded by `DeckMicModel.timeoutSeconds`, never retried, never remembered. It never writes a
/// setting or a file: when the helper is absent, slow or odd, the caller gets nil and the take
/// uses the user's own input setting.
enum DeckMicSignal {
    static let url = URL(string: "http://127.0.0.1:8796/deckmic")!

    /// Lock-protected hand-off from the URLSession callback to the waiting caller.
    private final class ResultBox {
        private let lock = NSLock()
        private var value: DeckMicModel.Signal?
        func set(_ signal: DeckMicModel.Signal?) { lock.lock(); value = signal; lock.unlock() }
        func get() -> DeckMicModel.Signal? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// One request on a fresh ephemeral session. nil on any error, any status other than 200, a
    /// body the model rejects, or a timeout.
    static func read() -> DeckMicModel.Signal? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = DeckMicModel.timeoutSeconds
        config.timeoutIntervalForResource = DeckMicModel.timeoutSeconds
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data {
                box.set(DeckMicModel.parse(data))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + DeckMicModel.timeoutSeconds + 0.05) == .timedOut {
            task.cancel()
            return nil
        }
        return box.get()
    }

    /// The input uid and the choice behind it for this take. Reads the signal once; when it is not on,
    /// returns `userUID` and `.userSetting` without listing devices or logging.
    static func effectiveInput(userUID: String) -> (uid: String, choice: DeckMicModel.Choice) {
        let signal = read()
        guard let signal = signal, signal.on else { return (userUID, .userSetting) }
        let devices = AudioDevices.inputDevices().map { DeckMicModel.InputDevice(uid: $0.uid, name: $0.name) }
        let choice = DeckMicModel.choose(signal: signal, devices: devices)
        Log.write(DeckMicModel.describe(choice: choice))
        return (DeckMicModel.effectiveUID(userUID: userUID, choice: choice), choice)
    }

    /// The input uid this take should record from.
    static func effectiveInputUID(userUID: String) -> String {
        effectiveInput(userUID: userUID).uid
    }
}
