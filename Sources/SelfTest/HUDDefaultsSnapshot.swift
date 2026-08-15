import Foundation

/// A restorable capture of the four HUD display-setting UserDefaults keys touched by the offscreen
/// render/probe seams (`--hud-render`, `--hud-probe`), so those tools can mutate Settings for the
/// duration of a run and leave the user's real values untouched on exit.
///
/// Reads the PERSISTENT domain, not `object(forKey:)` — the latter also returns registered defaults,
/// and restoring those would persist shadow copies of the defaults (the UserDefaults shadowing trap
/// documented in Settings.swift).
struct HUDDefaultsSnapshot {
    static let keys = ["powerMode", "hudPosition", "hudScale", "hudLowPowerScale"]

    private let saved: [(String, Any?)]
    private let domain: String

    init(fileManagerDefaults defaults: UserDefaults = .standard) {
        domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let persisted = defaults.persistentDomain(forName: domain) ?? [:]
        saved = Self.keys.map { ($0, persisted[$0]) }
    }

    func restore(to defaults: UserDefaults = .standard) {
        for (key, value) in saved {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
