import Foundation

/// DMGU1: graders for the app-update policy. Five arms, each driving the REAL `AppUpdateCheck` policy
/// and `AppUpdateNagPolicy` over injected transports, an injected opener, and an in-memory nag store.
///
/// No arm makes a network request, opens a browser, or touches the real `UserDefaults.standard` /
/// `$HOME`. `control` is the mandatory negative control: with the running version equal to the newest
/// release, nothing may be offered, no toast may be raised, and the opener must never run.
enum AppUpdateSelfTest {
    enum Arm: String, CaseIterable {
        case compare
        case failures
        case nag
        case link
        case control
    }

    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count,
              let arm = Arm(rawValue: arguments[i + 1])
        else {
            let names = Arm.allCases.map(\.rawValue).joined(separator: "|")
            print("[app-update-selftest] FAIL: --only <\(names)> is required")
            return 2
        }
        let ok: Bool
        switch arm {
        case .compare:  ok = runCompare()
        case .failures: ok = runFailures()
        case .nag:      ok = runNag()
        case .link:     ok = runLink()
        case .control:  ok = runControl()
        }
        return ok ? 0 : 1
    }

    // MARK: - Fixtures

    private static func release(tag: String, prerelease: Bool = false, draft: Bool = false,
                                html: String? = nil) -> [String: Any] {
        var dictionary: [String: Any] = ["tag_name": tag, "prerelease": prerelease, "draft": draft]
        if let html { dictionary["html_url"] = html }
        return dictionary
    }

    private static func releasesJSON(_ releases: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: releases)) ?? Data()
    }

    private static func finish(_ reporter: SelfTestReporter, prefix: String) -> Bool {
        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: prefix))
        return reporter.passed
    }

    // MARK: - compare

    /// One row per required case. Each row is a single release run through the real policy, so the
    /// decision under test is the shipped one rather than a hand-rolled comparison.
    private static func runCompare() -> Bool {
        print("=== ViddyDictate app-update — compare arm ===")
        let reporter = SelfTestReporter()

        struct Row {
            let name: String
            let tag: String
            let running: String
            let prerelease: Bool
            let draft: Bool
            let expected: String?
        }
        let rows: [Row] = [
            Row(name: "older", tag: "1.0.0", running: "2.0.0",
                prerelease: false, draft: false, expected: nil),
            Row(name: "equal", tag: "1.2.0", running: "1.2.0",
                prerelease: false, draft: false, expected: nil),
            Row(name: "newer", tag: "1.3.0", running: "1.2.0",
                prerelease: false, draft: false, expected: "1.3.0"),
            Row(name: "1.10.0 beats 1.9.0 numerically", tag: "1.10.0", running: "1.9.0",
                prerelease: false, draft: false, expected: "1.10.0"),
            Row(name: "1.2 equals 1.2.0 (differing component counts)", tag: "1.2", running: "1.2.0",
                prerelease: false, draft: false, expected: nil),
            Row(name: "leading v", tag: "v1.5.0", running: "1.4.0",
                prerelease: false, draft: false, expected: "v1.5.0"),
            Row(name: "malformed tag", tag: "not-a-version", running: "1.0.0",
                prerelease: false, draft: false, expected: nil),
            Row(name: "prerelease tag", tag: "1.3.0-beta.1", running: "1.2.0",
                prerelease: false, draft: false, expected: nil),
            Row(name: "prerelease flag", tag: "1.5.0", running: "1.4.0",
                prerelease: true, draft: false, expected: nil),
            Row(name: "draft flag", tag: "1.5.0", running: "1.4.0",
                prerelease: false, draft: true, expected: nil),
        ]

        for row in rows {
            let data = releasesJSON([release(tag: row.tag, prerelease: row.prerelease, draft: row.draft)])
            let offer = AppUpdateCheck.offer(fromReleasesJSON: data, runningVersion: row.running)
            reporter.record(
                "compare: \(row.name) [\(row.tag) vs \(row.running)]",
                offer?.version == row.expected,
                "got=\(offer?.version ?? "nil") want=\(row.expected ?? "nil")")
        }

        reporter.record("numeric compare: 1.10.0 is newer than 1.9.0",
                        AppUpdateCheck.isNewer("1.10.0", than: "1.9.0"))
        reporter.record("numeric compare: 1.2 is NOT newer than 1.2.0",
                        !AppUpdateCheck.isNewer("1.2", than: "1.2.0"))
        reporter.record("numeric compare: 1.2.0 is NOT newer than 1.2",
                        !AppUpdateCheck.isNewer("1.2.0", than: "1.2"))

        let savedProvider = AppUpdateCheck.runningVersionProvider
        AppUpdateCheck.runningVersionProvider = { "9.9.9" }
        let overridden = AppUpdateCheck.runningVersion
        AppUpdateCheck.runningVersionProvider = savedProvider
        reporter.record("the running-version accessor honors its injectable override",
                        overridden == "9.9.9", "got=\(overridden)")

        return finish(reporter, prefix: "app-update compare")
    }

    // MARK: - failures

    /// Every transport failure is a silent nil: no offer AND no user-visible error, because the policy
    /// has no error channel and never throws. `visibleErrors` is the post-state that proves a user would
    /// have seen nothing.
    private static func runFailures() -> Bool {
        print("=== ViddyDictate app-update — failures arm ===")
        let reporter = SelfTestReporter()

        let offline: AppUpdateCheck.Transport = { _ in nil }
        let http403: AppUpdateCheck.Transport = { _ in
            Data(#"{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com"}"#.utf8)
        }
        let http500: AppUpdateCheck.Transport = { _ in
            Data("<html><body>500 Internal Server Error</body></html>".utf8)
        }
        let malformedJSON: AppUpdateCheck.Transport = { _ in Data("{ this is not json".utf8) }
        let emptyList: AppUpdateCheck.Transport = { _ in Data("[]".utf8) }
        let unparseableTag: AppUpdateCheck.Transport = { _ in
            releasesJSON([release(tag: "release-candidate")])
        }

        let cases: [(String, AppUpdateCheck.Transport)] = [
            ("offline / no data", offline),
            ("HTTP 403 rate limit body", http403),
            ("HTTP 500 HTML body", http500),
            ("malformed JSON", malformedJSON),
            ("empty release list", emptyList),
            ("unparseable tag", unparseableTag),
        ]

        var visibleErrors = 0
        for (name, transport) in cases {
            let offer = AppUpdateCheck.offer(transport: transport, runningVersion: "1.0.0")
            if offer != nil { visibleErrors += 1 }
            reporter.record("failure: \(name) offers nothing",
                            offer == nil, "got=\(offer?.version ?? "nil")")
        }
        reporter.record("failure: no failure produced any user-visible error",
                        visibleErrors == 0, "visibleErrors=\(visibleErrors)")

        return finish(reporter, prefix: "app-update failures")
    }

    // MARK: - nag

    /// Asserts on POST-STATE: the per-launch latch and the persisted dismissed version, read back from a
    /// fresh policy over the same storage. Nothing here observes "was a method called".
    private static func runNag() -> Bool {
        print("=== ViddyDictate app-update — nag arm ===")
        let reporter = SelfTestReporter()
        let storage = MemoryNagStorage()

        let v13 = AppUpdateCheck.Offer(
            version: "1.3.0",
            releasePageURL: URL(string: "\(AppUpdateCheck.releasePagePrefix)1.3.0")!)
        let v14 = AppUpdateCheck.Offer(
            version: "1.4.0",
            releasePageURL: URL(string: "\(AppUpdateCheck.releasePagePrefix)1.4.0")!)

        let firstLaunch = AppUpdateNagPolicy(storage: storage)
        reporter.record("first launch offers the newer version", firstLaunch.shouldNag(v13))
        firstLaunch.markShown()
        reporter.record("second call in the same launch does not nag again",
                        !firstLaunch.shouldNag(v13))

        let relaunch = AppUpdateNagPolicy(storage: storage)
        reporter.record("a new launch with no dismissal can nag again", relaunch.shouldNag(v13))

        relaunch.dismiss(version: "1.3.0")
        reporter.record("dismissal is persisted",
                        AppUpdateNagPolicy(storage: storage).dismissedVersion == "1.3.0")

        let afterDismiss = AppUpdateNagPolicy(storage: storage)
        reporter.record("the dismissed version never nags again",
                        !afterDismiss.shouldNag(v13))
        reporter.record("a strictly newer version than the dismissed one DOES nag",
                        afterDismiss.shouldNag(v14))

        afterDismiss.markShown()
        reporter.record("the newer version is still once-per-launch",
                        !afterDismiss.shouldNag(v14))

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        afterDismiss.recordCheck(at: fixedDate)
        reporter.record("the last-checked timestamp is stored and read back",
                        AppUpdateNagPolicy(storage: storage).lastChecked == fixedDate,
                        "got=\(String(describing: AppUpdateNagPolicy(storage: storage).lastChecked))")

        return finish(reporter, prefix: "app-update nag")
    }

    // MARK: - link

    /// The toast's action must call the injected opener exactly once with the offered version's release
    /// page URL, and record the dismissal. The URL comes from the REAL offer decision over fixture JSON.
    private static func runLink() -> Bool {
        print("=== ViddyDictate app-update — link arm ===")
        let reporter = SelfTestReporter()

        // No html_url => the canonical /releases/tag/<tag> URL.
        let data = releasesJSON([release(tag: "v1.3.0")])
        guard let offer = AppUpdateCheck.offer(fromReleasesJSON: data, runningVersion: "1.2.0") else {
            reporter.record("fixture: a newer release produces an offer", false)
            return finish(reporter, prefix: "app-update link")
        }
        reporter.record("fixture: a newer release produces an offer", offer.version == "v1.3.0",
                        "got=\(offer.version)")

        var opened: [URL] = []
        let policy = AppUpdateNagPolicy(storage: MemoryNagStorage())
        let action = AppUpdateCheck.toastAction(for: offer, opener: { url in
            opened.append(url)
            return true
        }, nagPolicy: policy)
        action()

        reporter.record("the toast action calls the injected opener exactly once",
                        opened.count == 1, "opened=\(opened.count)")
        reporter.record(
            "the opener receives the offered version's release page URL",
            opened.first?.absoluteString
                == "https://github.com/ViddySlap/viddydictate/releases/tag/v1.3.0",
            "url=\(opened.first?.absoluteString ?? "nil")")
        reporter.record("the toast action records the dismissal for that version",
                        policy.dismissedVersion == "v1.3.0",
                        "dismissed=\(policy.dismissedVersion ?? "nil")")

        // html_url wins when the release carries one.
        let html = "https://github.com/ViddySlap/viddydictate/releases/tag/1.4.0"
        let htmlData = releasesJSON([release(tag: "1.4.0", html: html)])
        let htmlOffer = AppUpdateCheck.offer(fromReleasesJSON: htmlData, runningVersion: "1.3.0")
        reporter.record("a release's html_url is preferred for the offer's page",
                        htmlOffer?.releasePageURL.absoluteString == html,
                        "url=\(htmlOffer?.releasePageURL.absoluteString ?? "nil")")

        return finish(reporter, prefix: "app-update link")
    }

    // MARK: - control (mandatory negative control)

    /// Running version == newest release. Nothing may be offered, no toast may be raised, and the opener
    /// must never run. An arm that cannot fail is not a gate; this one fails if any of those three moves.
    private static func runControl() -> Bool {
        print("=== ViddyDictate app-update — control arm (negative control) ===")
        let reporter = SelfTestReporter()

        let data = releasesJSON([release(tag: "1.3.0")])
        let offer = AppUpdateCheck.offer(fromReleasesJSON: data, runningVersion: "1.3.0")

        var toastRaised = false
        var opened: [URL] = []
        if let offer {
            toastRaised = true
            AppUpdateCheck.toastAction(for: offer, opener: { opened.append($0); return true })()
        }

        reporter.record("equal running and release versions offer nothing",
                        offer == nil, "got=\(offer?.version ?? "nil")")
        reporter.record("equal versions raise no toast", !toastRaised)
        reporter.record("equal versions never call the opener", opened.isEmpty,
                        "opened=\(opened.count)")

        return finish(reporter, prefix: "app-update control")
    }

    // MARK: - In-memory nag storage (no UserDefaults, no HOME)

    private final class MemoryNagStorage: AppUpdateNagStorage {
        private var strings: [String: String] = [:]
        private var dates: [String: Date] = [:]

        func nagString(forKey key: String) -> String? { strings[key] }
        func nagSetString(_ value: String?, forKey key: String) { strings[key] = value }
        func nagDate(forKey key: String) -> Date? { dates[key] }
        func nagSetDate(_ value: Date?, forKey key: String) { dates[key] = value }
    }
}
