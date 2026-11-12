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

    /// What the next take will try, worded as a prediction. Names exactly the device `choose` would pick.
    static func nextTakeText(signal: Signal?, devices: [InputDevice], userUID: String, defaultName: String?) -> String {
        let prefix = "Next dictation uses: "
        let choice = choose(signal: signal, devices: devices)
        if case .blackHole(_, let name) = choice { return prefix + name + " (Steam Deck on)" }
        var text: String
        if userUID.isEmpty {
            text = prefix + (defaultName.map { $0 + " (system default)" } ?? "system default")
        } else if let pinned = devices.first(where: { $0.uid == userUID }) {
            text = prefix + pinned.name
        } else {
            text = prefix + (defaultName.map { $0 + " (system default; pinned mic unavailable)" }
                             ?? "system default (pinned mic unavailable)")
        }
        if case .blackHoleMissing = choice { text += " (Steam Deck on, no BlackHole input)" }
        return text
    }

    /// The device a take is recording from right now. A follow-default take names the route, with the
    /// start device only as a fact about the start.
    static func activeText(name: String?, followsDefault: Bool, viaDeck: Bool) -> String {
        let prefix = "Dictating now from: "
        if followsDefault {
            return prefix + (name.map { "system default (\($0) at start)" } ?? "system default")
        }
        return prefix + (name ?? "unnamed input") + (viaDeck ? " (Steam Deck)" : "")
    }

    /// True when the next take would use a BlackHole input that is not the picker's device.
    static func nextDiffersFromPicker(signal: Signal?, devices: [InputDevice], userUID: String) -> Bool {
        if case .blackHole(let uid, _) = choose(signal: signal, devices: devices) { return uid != userUID }
        return false
    }

    /// Whether the "meter below uses the picker" line shows: the active take's value when a take is
    /// recording, otherwise the idle prediction's.
    static func meterNoteNeeded(nextDiffersFromPicker: Bool, activeDiffersFromPicker: Bool?) -> Bool {
        activeDiffersFromPicker ?? nextDiffersFromPicker
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
