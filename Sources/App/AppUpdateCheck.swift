import Cocoa

/// DMGU1: app-update availability. Pure policy with an INJECTED transport, so no test ever touches the
/// network: the default transport is the only code that talks to GitHub, and every failure mode (offline,
/// DNS, HTTP non-200, rate limit, malformed JSON, empty list, unparseable tag) collapses to `nil` with no
/// user-visible error and no escaping throw.
///
/// This never auto-updates and never auto-downloads. It only answers "is there a newer release?" and
/// builds the closure a clickable toast runs to open that release's page in the default browser.
enum AppUpdateCheck {

    /// What the caller can show: a newer version string and the release page to open.
    struct Offer: Equatable {
        let version: String
        let releasePageURL: URL
    }

    /// Raw JSON for the releases endpoint, or `nil` for ANY failure. Must never throw.
    typealias Transport = (URL) -> Data?

    static let releasesAPIURL =
        URL(string: "https://api.github.com/repos/ViddySlap/viddydictate/releases")!
    static let releasePagePrefix = "https://github.com/ViddySlap/viddydictate/releases/tag/"

    // MARK: - Running version

    /// Injectable source of the running version, so tests can set it without a stamped bundle.
    static var runningVersionProvider: () -> String = { bundleRunningVersion() }

    /// The running app version (`CFBundleShortVersionString`, stamped by `build.sh` from `VD_APP_VERSION`).
    static var runningVersion: String { runningVersionProvider() }

    /// The app-wide nag policy: a single instance so the per-launch "already shown" latch is shared by the
    /// post-first-dictation toast, the menu-bar item, and the Settings row. Persisted state (last checked,
    /// dismissed version) lives in `UserDefaults`; this adds no new behavior to the policy itself.
    static let nagPolicy = AppUpdateNagPolicy()

    /// Reads the stamped bundle version; empty string when the key is absent or non-string.
    static func bundleRunningVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }

    // MARK: - Version parsing / comparison

    /// Parse a release tag into numeric components. Tolerates a single leading `v`/`V`. Returns `nil` for
    /// anything that is not purely dot-separated integers, which includes every prerelease tag
    /// (`1.3.0-beta.1`, `1.4.0-rc1`, ...) and every malformed tag.
    static func parseVersion(_ raw: String) -> [Int]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        return components
    }

    /// Component-by-component NUMERIC comparison, zero-padding the shorter side, so `1.10.0` sorts above
    /// `1.9.0` and `1.2` equals `1.2.0`. Never a string comparison.
    static func compareVersions(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True when `candidate` is strictly newer than `running` by numeric comparison.
    static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard let candidateParts = parseVersion(candidate),
              let runningParts = parseVersion(running) else { return false }
        return compareVersions(candidateParts, runningParts) == .orderedDescending
    }

    // MARK: - Release decision

    /// The pure decision over the GitHub releases JSON. Drafts and prereleases are skipped; a release
    /// whose tag cannot be parsed is skipped; the newest remaining release is offered only when it is
    /// strictly newer than `runningVersion`. Everything else returns `nil`.
    static func offer(fromReleasesJSON data: Data?, runningVersion: String) -> Offer? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let releases = object as? [[String: Any]] else { return nil }

        var best: (version: String, parsed: [Int], url: URL)?
        for release in releases {
            if (release["draft"] as? Bool) == true { continue }
            if (release["prerelease"] as? Bool) == true { continue }
            guard let tag = release["tag_name"] as? String,
                  let parsed = parseVersion(tag) else { continue }
            let url = releasePageURL(forRelease: release, tag: tag)
            if let current = best {
                if compareVersions(parsed, current.parsed) == .orderedDescending {
                    best = (tag, parsed, url)
                }
            } else {
                best = (tag, parsed, url)
            }
        }

        guard let best,
              let runningParts = parseVersion(runningVersion),
              compareVersions(best.parsed, runningParts) == .orderedDescending else { return nil }
        return Offer(version: best.version, releasePageURL: best.url)
    }

    /// Convenience over the injected transport, synchronous and throwing-free. Used by the tests and by
    /// `check` below.
    static func offer(transport: Transport, runningVersion: String) -> Offer? {
        offer(fromReleasesJSON: transport(releasesAPIURL), runningVersion: runningVersion)
    }

    /// The release page URL: the release's `html_url` when present and valid, else the canonical
    /// `/releases/tag/<tag>` URL.
    static func releasePageURL(forRelease release: [String: Any], tag: String) -> URL {
        if let html = release["html_url"] as? String, let url = URL(string: html) { return url }
        return URL(string: releasePagePrefix + tag) ?? URL(string: releasePagePrefix)!
    }

    // MARK: - Production check

    /// One attempt, off the main thread, against the injected transport (default: URLSession with a ~5s
    /// timeout). The completion fires exactly once with an `Offer` or `nil`; there is no error channel.
    static func check(transport: @escaping Transport = defaultTransport,
                      completion: @escaping (Offer?) -> Void) {
        let running = runningVersion
        DispatchQueue.global(qos: .utility).async {
            let result = offer(transport: transport, runningVersion: running)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Default network transport: a single GET with a ~5s timeout. Non-200 responses, transport errors,
    /// and timeouts all return `nil`.
    static let defaultTransport: Transport = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ViddyDictate", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return }
            payload = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return payload
    }

    // MARK: - Toast action

    /// The closure a clickable toast runs. Running it calls `opener` exactly once with the offer's
    /// release page URL and records the dismissal for that version. The opener seam is copied from
    /// `PermissionsGrant.perform`, so a test asserts the URL without launching a browser.
    static func toastAction(for offer: Offer,
                            opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
                            nagPolicy: AppUpdateNagPolicy? = nil) -> () -> Void {
        return {
            _ = opener(offer.releasePageURL)
            nagPolicy?.dismiss(version: offer.version)
        }
    }
}

// MARK: - Nag policy

/// Minimal persistence seam for the nag policy. Production uses `UserDefaults`; tests use an in-memory
/// implementation, so no real `UserDefaults.standard` and no real `$HOME` is touched.
protocol AppUpdateNagStorage: AnyObject {
    func nagString(forKey key: String) -> String?
    func nagSetString(_ value: String?, forKey key: String)
    func nagDate(forKey key: String) -> Date?
    func nagSetDate(_ value: Date?, forKey key: String)
}

/// The app's real store: standard `UserDefaults`.
final class AppUpdateUserDefaultsStorage: AppUpdateNagStorage {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func nagString(forKey key: String) -> String? { defaults.string(forKey: key) }
    func nagSetString(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    func nagDate(forKey key: String) -> Date? { defaults.object(forKey: key) as? Date }
    func nagSetDate(_ value: Date?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Nag state: at most one show per app launch, permanently silent for a dismissed version, and willing
/// to fire again for a strictly newer version than the one dismissed. Also keeps the "last checked"
/// timestamp a Settings row can read later.
final class AppUpdateNagPolicy {
    static let dismissedVersionKey = "ViddyDictateAppUpdateDismissedVersion"
    static let lastCheckedKey = "ViddyDictateAppUpdateLastChecked"

    private let storage: AppUpdateNagStorage
    /// In-memory only: resets on every launch, which is exactly the "once per app launch" rule.
    private var shownThisLaunch = false

    init(storage: AppUpdateNagStorage = AppUpdateUserDefaultsStorage()) {
        self.storage = storage
    }

    /// The last version the user dismissed, persisted across launches. `nil` when never dismissed.
    var dismissedVersion: String? {
        get { storage.nagString(forKey: Self.dismissedVersionKey) }
        set { storage.nagSetString(newValue, forKey: Self.dismissedVersionKey) }
    }

    /// The last time an update check completed, persisted for the Settings row.
    var lastChecked: Date? {
        get { storage.nagDate(forKey: Self.lastCheckedKey) }
        set { storage.nagSetDate(newValue, forKey: Self.lastCheckedKey) }
    }

    /// Record a completed check (success or silent failure) for the Settings row.
    func recordCheck(at date: Date = Date()) { lastChecked = date }

    /// True only while this launch has not yet shown an update and `offer` is strictly newer than
    /// anything the user has dismissed.
    func shouldNag(_ offer: AppUpdateCheck.Offer) -> Bool {
        guard !shownThisLaunch else { return false }
        if let dismissed = dismissedVersion {
            let offerParts = AppUpdateCheck.parseVersion(offer.version) ?? []
            let dismissedParts = AppUpdateCheck.parseVersion(dismissed) ?? []
            if AppUpdateCheck.compareVersions(offerParts, dismissedParts) != .orderedDescending {
                return false
            }
        }
        return true
    }

    /// Mark that this launch has shown an update, so it is never shown twice in one launch.
    func markShown() { shownThisLaunch = true }

    /// Remember that the user dismissed `version`; that version (and anything older) stays silent.
    func dismiss(version: String) { dismissedVersion = version }

    /// Test seam: clear only the in-memory per-launch latch, leaving persisted state alone.
    func resetLaunchLatch() { shownThisLaunch = false }
}
