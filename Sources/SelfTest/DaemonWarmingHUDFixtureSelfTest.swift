import Foundation

/// The speech engine's warm-up must be visible. On a user's Mac a cold start waited five minutes on the
/// network while the app only retried silently, so the user saw a broken engine. The daemon now reports
/// `phase` / `phase_s` in `/health`; this pins what the HUD (and Preflight) say from them.
///
/// Deterministic: fixed `/health` JSON bodies parsed by the production parser, a fixed clock, no daemon,
/// no HUD, no network. The negative control is a presenter that ignores `phase` and shows nothing - the
/// pre-fix behaviour - and the same fixtures must catch it, or this test is vacuous.
enum DaemonWarmingHUDFixtureSelfTest {
    typealias Presenter = (DaemonWarmStatus?, Date) -> String?

    private struct Fixture {
        let name: String
        let json: String?
        let ageSeconds: Double
        let expected: String?
    }

    private static let observedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let model = "mlx-community/whisper-large-v3-turbo"

    /// `"text"` for a value, `nil` for none: one helper for both the JSON bodies and the report lines.
    private static func quoted(_ text: String?, none: String = "nil") -> String {
        guard let text else { return none }
        return "\"" + text + "\""
    }

    private static func body(_ phase: String, _ seconds: Double, detail: String? = nil,
                             ready: Bool = false, error: String? = nil) -> String {
        // Joined from typed parts: one long `+` chain of literals is slow for the type checker.
        let fields: [String] = [
            "\"ready\": " + (ready ? "true" : "false"),
            "\"model\": " + quoted(model),
            "\"idle_s\": 0.0",
            "\"error\": " + quoted(error, none: "null"),
            "\"phase\": " + quoted(phase),
            "\"phase_s\": " + String(seconds),
            "\"phase_detail\": " + quoted(detail, none: "null"),
        ]
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// The four-key body every daemon before the phase fields sent.
    private static let olderDaemonBody =
        "{\"ready\": false, \"model\": \"\(model)\", \"idle_s\": 12.5, \"error\": null}"

    private static let fixtures: [Fixture] = [
        Fixture(name: "a daemon loading for 12.4s, read just now",
                json: body("loading", 12.4), ageSeconds: 0,
                expected: "Speech engine is starting… 12s"),
        Fixture(name: "the count keeps running between polls",
                json: body("starting", 3.0), ageSeconds: 4,
                expected: "Speech engine is starting… 7s"),
        Fixture(name: "a slow load past the 30s threshold says it is still loading",
                json: body("loading", 45.0), ageSeconds: 0,
                expected: "Still loading the speech model… 45s"),
        Fixture(name: "a slow first download says downloading",
                json: body("downloading", 61.2), ageSeconds: 0,
                expected: "Still loading the speech model (downloading)… 61s"),
        Fixture(name: "a download that cannot reach the Hub says waiting for the network",
                json: body("downloading", 30.0, detail: "waiting for the network"), ageSeconds: 0,
                expected: "Still loading the speech model (waiting for the network)… 30s"),
        Fixture(name: "a resolve stuck past the threshold still says it is loading",
                json: body("resolving", 31.0), ageSeconds: 0,
                expected: "Still loading the speech model… 31s"),
        Fixture(name: "a failed warm says it failed, with the daemon's reason",
                json: body("error", 1.0, error: "model load failed"), ageSeconds: 0,
                expected: "Speech engine failed to start: model load failed"),
        Fixture(name: "a ready daemon adds nothing",
                json: body("ready", 900.0, ready: true), ageSeconds: 0, expected: nil),
        Fixture(name: "an older daemon without phase fields adds nothing (today's behaviour)",
                json: olderDaemonBody, ageSeconds: 0, expected: nil),
        Fixture(name: "a stale reading adds nothing rather than a guessed count",
                json: body("loading", 5.0), ageSeconds: 11, expected: nil),
        Fixture(name: "an unknown phase name is treated like an older daemon",
                json: body("warming-up", 5.0), ageSeconds: 0, expected: nil),
        Fixture(name: "no answer at all adds nothing",
                json: nil, ageSeconds: 0, expected: nil),
    ]

    private static func status(_ json: String?) -> DaemonWarmStatus? {
        guard let json,
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        else { return nil }
        return DaemonWarmStatus.parse(object, observedAt: observedAt)
    }

    /// Names of the fixtures `presenter` gets wrong.
    private static func failures(of presenter: Presenter, verbose: Bool,
                                 reporter: SelfTestReporter?) -> [String] {
        var wrong: [String] = []
        for fixture in fixtures {
            let now = observedAt.addingTimeInterval(fixture.ageSeconds)
            let got = presenter(status(fixture.json), now)
            let ok = got == fixture.expected
            if !ok { wrong.append(fixture.name) }
            if verbose {
                reporter?.record(fixture.name, ok,
                                 "got " + quoted(got) + ", want " + quoted(fixture.expected))
            }
        }
        return wrong
    }

    static func run() -> Int32 {
        print("=== ViddyDictate daemon-warming HUD fixture selftest ===")
        let reporter = SelfTestReporter()

        // The production parser reads the additive fields, and leaves them nil for an older daemon.
        let parsed = status(body("downloading", 12.4, detail: "waiting for the network"))
        reporter.record("parse reads phase, phase_s and phase_detail from /health",
                        parsed?.phase == .downloading && parsed?.phaseSeconds == 12.4
                            && parsed?.phaseDetail == "waiting for the network" && parsed?.ready == false,
                        String(describing: parsed))
        let older = status(olderDaemonBody)
        reporter.record("parse of an older daemon's body has no phase and no phase_s",
                        older != nil && older?.phase == nil && older?.phaseSeconds == nil,
                        String(describing: older))

        // Every HUD decision, through the production presenter.
        _ = failures(of: DaemonWarmingHUD.message(for:now:), verbose: true, reporter: reporter)

        // The retained-take toast: phase-aware when it can be, verbatim legacy wording when it cannot.
        let warming = status(body("loading", 12.4))
        reporter.record("a queued retained take toasts the warm-up phase",
                        DaemonWarmingHUD.recoveryToast(for: warming, now: observedAt)
                            == "Speech engine is starting… 12s")
        reporter.record("with an older daemon the queued take keeps the original toast verbatim",
                        DaemonWarmingHUD.recoveryToast(for: older, now: observedAt)
                            == "Transcription unavailable. Retrying retained take...")

        // Preflight's speech-to-text row.
        reporter.record("Preflight names the phase and its seconds",
                        DaemonWarmingHUD.preflightDetail(for: warming) == "loading for 12s",
                        DaemonWarmingHUD.preflightDetail(for: warming) ?? "nil")
        reporter.record("Preflight carries the network wait",
                        DaemonWarmingHUD.preflightDetail(for: parsed)
                            == "downloading, waiting for the network, 12s",
                        DaemonWarmingHUD.preflightDetail(for: parsed) ?? "nil")
        reporter.record("Preflight falls back to plain \"loading\" for an older daemon (nil detail)",
                        DaemonWarmingHUD.preflightDetail(for: older) == nil)

        // NEGATIVE CONTROL: the pre-fix behaviour - ignore phase, show nothing - must be caught.
        let ignoresPhase: Presenter = { _, _ in nil }
        let caught = failures(of: ignoresPhase, verbose: false, reporter: nil)
        reporter.record("NEGATIVE CONTROL: a presenter that ignores phase and shows nothing is caught",
                        !caught.isEmpty,
                        "\(caught.count) of \(fixtures.count) fixtures fail it; first: \(caught.first ?? "none")")
        // And the opposite mistake: a presenter that ignores the daemon's version and always says
        // "starting" would misreport an older daemon and a ready one.
        let alwaysStarting: Presenter = { _, _ in "Speech engine is starting… 0s" }
        let caughtOpposite = failures(of: alwaysStarting, verbose: false, reporter: nil)
        reporter.record("NEGATIVE CONTROL: a presenter that always claims \"starting\" is caught",
                        !caughtOpposite.isEmpty,
                        "\(caughtOpposite.count) of \(fixtures.count) fixtures fail it")

        print(reporter.summaryLine(prefix: "[daemon-warming-hud-selftest]"))
        return reporter.passed ? 0 : 1
    }
}
