import Foundation

/// Pure decision logic for the Deck microphone: parse the helper's answer, choose whether a take
/// records from a BlackHole input, and say so in the log. Foundation only, so it compiles on Linux
/// and the oracle can pin it. Nothing here reads a device, a setting or the network.
enum DeckMicModel {
    /// Case-insensitive word that marks a BlackHole input device.
    static let deviceNameToken = "blackhole"
    /// The BlackHole input that wins when several BlackHole devices exist.
    static let preferredDeviceName = "BlackHole 2ch"
    /// How long the take start waits for the helper.
    static let timeoutSeconds: Double = 0.3

    struct Signal: Equatable {
        let on: Bool
        let since: Double?
    }

    struct InputDevice: Equatable {
        let uid: String
        let name: String
    }

    enum Choice: Equatable {
        case userSetting
        case blackHole(uid: String, name: String)
        case blackHoleMissing
    }

    /// The helper's body is a JSON object with a required boolean `on` and an optional, finite,
    /// non-negative number `since`. Anything else is nil (treated as "off").
    static func parse(_ data: Data) -> Signal? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // The helper never sends a backslash; refusing one means no JSON escape can hide a key
        // from the duplicate check below.
        if text.contains("\\") { return nil }
        // No decoder chooses a winner between duplicate keys.
        if occurrences(of: "\"on\"\\s*:", in: text) > 1 { return nil }
        if occurrences(of: "\"since\"\\s*:", in: text) > 1 { return nil }
        // Strict typed decode: `on` must be a JSON boolean (not 1, "true" or null), `since` a number or
        // null or absent, and the top level an object. Other keys are ignored.
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        if let since = body.since, !(since.isFinite && since >= 0) { return nil }
        return Signal(on: body.on, since: body.since)
    }

    static func choose(signal: Signal?, devices: [InputDevice]) -> Choice {
        guard let signal = signal, signal.on else { return .userSetting }
        let matches = devices.filter {
            !$0.uid.isEmpty && $0.name.range(of: deviceNameToken, options: .caseInsensitive) != nil
        }
        let exact = matches.first { $0.name.caseInsensitiveCompare(preferredDeviceName) == .orderedSame }
        guard let winner = exact ?? matches.first else { return .blackHoleMissing }
        return .blackHole(uid: winner.uid, name: winner.name)
    }

    static func effectiveUID(userUID: String, choice: Choice) -> String {
        switch choice {
        case .blackHole(let uid, _): return uid
        case .userSetting, .blackHoleMissing: return userUID
        }
    }

    static func describe(choice: Choice) -> String {
        switch choice {
        case .userSetting:
            return "deckmic: off, using the user's input setting"
        case .blackHole(_, let name):
            return "deckmic: on, using BlackHole input \(name)"
        case .blackHoleMissing:
            return "deckmic: on, no BlackHole input present, using the user's input setting"
        }
    }

    private struct Body: Decodable {
        let on: Bool
        let since: Double?
    }

    private static func occurrences(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
