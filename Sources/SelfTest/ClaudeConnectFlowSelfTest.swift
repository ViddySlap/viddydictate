import Foundation

/// Pure coverage for the Claude connect flow (spec D1, D3, D5). Every fixture is synthetic provider
/// metadata and a fake clock: no Terminal is opened, no status command is run, no credential store is
/// touched, and nothing here sleeps.
///
/// The check this file exists for is `checkAlreadyConnectedNeverReauthenticates`. Claude's credential is one
/// per macOS account, so a login launched against an already-signed-in machine rotates the token every
/// Claude Code session on that Mac is holding. Asserting the copy would not have caught that; asserting
/// that the LAUNCHER IS NEVER CALLED does.
enum ClaudeConnectFlowSelfTest {

    static func run() -> Bool {
        print("=== ViddyDictate Claude connect flow (D1, D3, D5) - selftest ===")
        let reporter = SelfTestReporter()

        checkOnlySignedOutLaunchesALogin(reporter)
        checkAlreadyConnectedNeverReauthenticates(reporter)
        checkSignedOutPollsUntilItSeesTheSignIn(reporter)
        checkTheWaitIsBoundedAndCancellable(reporter)
        checkTransientApparatusFailureDoesNotAbandonTheUser(reporter)
        checkAnUnsupportedAnswerStopsRatherThanLooping(reporter)
        checkALaunchThatDidNotHappenIsNotPolled(reporter)
        checkPollingNumbersAndCountdown(reporter)
        checkEveryMessageIsSayableAndSafe(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Claude connect flow"))
        print(reporter.passed ? "CLAUDE CONNECT FLOW GREEN" : "CLAUDE CONNECT FLOW FAILED")
        return reporter.passed
    }

    // MARK: - Fixtures

    private static func status(loggedIn: Bool,
                              authMethod: String,
                              subscriptionType: String? = nil)
        -> LLMProviderDetection.ClaudeAuthStatusObservation {
        .status(LLMProviderDetection.ClaudeAuthStatus(
            loggedIn: loggedIn,
            authMethod: authMethod,
            apiProvider: "firstParty",
            subscriptionType: subscriptionType))
    }

    private static var subscription: LLMProviderDetection.ClaudeAuthStatusObservation {
        status(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max")
    }

    private static var signedOut: LLMProviderDetection.ClaudeAuthStatusObservation {
        status(loggedIn: false, authMethod: "none")
    }

    private static var apiBilling: LLMProviderDetection.ClaudeAuthStatusObservation {
        status(loggedIn: true, authMethod: "apiKey")
    }

    private static let fixtureBinary = "/usr/local/bin/claude"
    private static var fixtureCommand: String { ClaudeSignIn.command(binary: fixtureBinary) }

    /// One whole attempt on a fake clock. `observations` is consumed in order; the last entry repeats once
    /// exhausted, which is what lets a never-connects fixture run to the real 15-minute bound in no time.
    private struct Attempt {
        let result: ClaudeConnectionFlow.SignInResult
        let launches: Int
        let observations: Int
        let elapsed: TimeInterval
        let countdown: [TimeInterval]
        let launchedCommand: String?
    }

    private static func attempt(
        observations: [LLMProviderDetection.ClaudeAuthStatusObservation],
        launch: ClaudeSignIn.Outcome = .launched(command: fixtureCommand),
        polling: ClaudeConnectionFlow.Polling = ClaudeConnectionFlow.defaultPolling,
        cancelAfterObservations: Int? = nil
    ) -> Attempt {
        var clock: TimeInterval = 0
        var launches = 0
        var taken = 0
        var countdown: [TimeInterval] = []
        var launchedCommand: String?
        let result = ClaudeConnectionFlow.runSignIn(
            polling: polling,
            launch: {
                launches += 1
                return launch
            },
            observe: {
                let observation = observations[min(taken, observations.count - 1)]
                taken += 1
                return observation
            },
            now: { clock },
            // No real sleeping: the injected clock is what advances, so a 15-minute bound costs nothing.
            wait: { clock += $0 },
            isCancelled: {
                guard let limit = cancelAfterObservations else { return false }
                return taken >= limit
            },
            onLaunched: { launchedCommand = $0 },
            onWaiting: { countdown.append($0) })
        return Attempt(result: result,
                       launches: launches,
                       observations: taken,
                       elapsed: clock,
                       countdown: countdown,
                       launchedCommand: launchedCommand)
    }

    // MARK: - Checks

    private static func checkOnlySignedOutLaunchesALogin(_ check: SelfTestReporter) {
        print("--- D3: a login is launched for exactly one measured situation ---")
        for situation in ProviderOnboardingSituation.allCases {
            let launches = ClaudeConnectionFlow.launchesSignIn(situation)
            check("\(situation.rawValue): \(launches ? "launches" : "does not launch") a login",
                  launches == (situation == .signedOut))
        }
        check("the situations the flow answers for are the ones onboarding derives",
              ProviderOnboardingSituation.allCases.count == 4)
    }

    private static func checkAlreadyConnectedNeverReauthenticates(_ check: SelfTestReporter) {
        print("--- D3: an already-connected machine is confirmed, and NOTHING is launched ---")
        let connected = attempt(observations: [subscription])
        check("a signed-in machine is refused rather than re-authenticated",
              connected.result == .refusedAlreadyConnected)
        check("the login command is never handed to Terminal",
              connected.launches == 0,
              "launches=\(connected.launches)")
        check("no waiting sheet countdown is started either", connected.countdown.isEmpty)
        check("the refusal is decided from ONE reading, taken immediately before the launch would be",
              connected.observations == 1,
              "observations=\(connected.observations)")

        // D4's sibling hazard: an unsupported logged-in method must not be sent round a sign-in loop.
        let unsupported = attempt(observations: [apiBilling])
        check("a logged-in method ViddyDictate cannot use is also not launched into",
              unsupported.launches == 0)
        check("the unsupported answer is reported with the vendor's own method named",
              unsupported.result == .unusable(
                "signed in with Claude auth method apiKey; ViddyDictate does not support it yet"),
              "\(unsupported.result)")

        // The message a user sees for that refusal has to give them a way out, per D3.
        let message = ClaudeConnectionFlow.resultMessage(.refusedAlreadyConnected,
                                                         command: fixtureCommand)
        check("the confirmation names the Terminal command that forces a fresh sign-in",
              message?.body.contains(fixtureCommand) == true)
        check("the confirmation says why the app does not do it for you",
              message?.body.contains("shared by everything using Claude Code") == true)
        check("the confirmation is not phrased as a reconnect",
              message?.title.lowercased().contains("reconnect") == false
                && message?.body.lowercased().contains("reconnect") == false)
        check("the confirmation is not an error",
              message?.severity == .info)
    }

    private static func checkSignedOutPollsUntilItSeesTheSignIn(_ check: SelfTestReporter) {
        print("--- D5: the flow hands off to Terminal, then polls and finishes by itself ---")
        // Guard reading, then two polls that still say signed out, then the sign-in lands.
        let run = attempt(observations: [signedOut, signedOut, signedOut, subscription])
        check("the sign-in is launched exactly once", run.launches == 1)
        check("the command reported to the host is the one Terminal was given",
              run.launchedCommand == fixtureCommand)
        check("polling continues while the machine still reports signed out",
              run.observations == 4,
              "observations=\(run.observations)")
        check("success is concluded from a re-measured status, not from what the command printed",
              run.result == .connected)
        check("the wait ended long before the bound", run.elapsed == 6, "elapsed=\(run.elapsed)")
        check("the host is given a countdown per poll so it can show one",
              run.countdown == [900, 898, 896],
              "\(run.countdown)")
    }

    private static func checkTheWaitIsBoundedAndCancellable(_ check: SelfTestReporter) {
        print("--- D5: the wait is bounded and the user can stop it ---")
        let neverConnects = attempt(observations: [signedOut])
        check("a sign-in that never happens ends in a timeout rather than forever",
              neverConnects.result == .timedOut)
        check("the timeout lands at the bound, not before it",
              neverConnects.elapsed == ClaudeConnectionFlow.defaultPolling.deadline,
              "elapsed=\(neverConnects.elapsed)")
        check("the bound is reached in interval-sized steps",
              neverConnects.observations
                == 1 + Int(ClaudeConnectionFlow.defaultPolling.deadline
                            / ClaudeConnectionFlow.defaultPolling.interval),
              "observations=\(neverConnects.observations)")

        let cancelled = attempt(observations: [signedOut], cancelAfterObservations: 3)
        check("cancelling stops the wait", cancelled.result == .cancelled)
        check("no status reading is taken after the cancel",
              cancelled.observations == 3,
              "observations=\(cancelled.observations)")
        check("a cancel is not reported back as a failure the user has to acknowledge",
              ClaudeConnectionFlow.resultMessage(.cancelled) == nil)
    }

    private static func checkTransientApparatusFailureDoesNotAbandonTheUser(_ check: SelfTestReporter) {
        print("--- a status command that hiccups is apparatus, not a verdict ---")
        let recovered = attempt(observations: [
            .apparatusUnavailable("fixture: timed out"),
            .apparatusUnavailable("fixture: could not start"),
            .invalidResponse("fixture: malformed"),
            subscription,
        ])
        check("a failed reading before the launch does not block the user's own request",
              recovered.launches == 1)
        check("failed readings during the wait keep the poll alive",
              recovered.result == .connected,
              "\(recovered.result)")
        check("the poll still finishes on the first real signed-in reading",
              recovered.observations == 4)
    }

    private static func checkAnUnsupportedAnswerStopsRatherThanLooping(_ check: SelfTestReporter) {
        print("--- D4: an unsupported sign-in mid-wait is a settled answer ---")
        let switched = attempt(observations: [signedOut, signedOut, apiBilling, subscription])
        check("a logged-in-but-unsupported reading ends the wait",
              switched.result == .unusable(
                "signed in with Claude auth method apiKey; ViddyDictate does not support it yet"),
              "\(switched.result)")
        check("the poll stops there rather than waiting for a state that cannot arrive",
              switched.observations == 3,
              "observations=\(switched.observations)")
        let message = ClaudeConnectionFlow.resultMessage(.unusable("signed in with method future-auth"),
                                                         command: fixtureCommand)
        check("the user is told what was reported rather than told to sign in again",
              message?.body.contains("future-auth") == true
                && message?.body.contains("would not change this") == true)
        check("the whitelist stays the state owner's: an unknown method is unusable, not connected",
              attempt(observations: [status(loggedIn: true, authMethod: "console")]).launches == 0)
    }

    private static func checkALaunchThatDidNotHappenIsNotPolled(_ check: SelfTestReporter) {
        print("--- a login that never started is reported, not waited on ---")
        let absent = attempt(observations: [signedOut], launch: .notInstalled)
        check("a missing CLI is reported", absent.result == .notInstalled)
        check("nothing is polled after a launch that did not happen",
              absent.observations == 1,
              "observations=\(absent.observations)")
        let refused = attempt(observations: [signedOut],
                              launch: .failed("Terminal did not open."))
        check("a refused Terminal is reported with its reason",
              refused.result == .launchFailed("Terminal did not open."))
        check("the failure message still gives the user the command to run themselves",
              ClaudeConnectionFlow.resultMessage(refused.result, command: fixtureCommand)?
                .body.contains(fixtureCommand) == true)
        check("a second concurrent attempt is a distinct, non-alarming outcome",
              ClaudeConnectionFlow.resultMessage(.alreadyInProgress)?.severity == .info)
    }

    private static func checkPollingNumbersAndCountdown(_ check: SelfTestReporter) {
        print("--- D5's numbers, and the countdown the wait field shows ---")
        check("the poll interval is 2s", ClaudeConnectionFlow.defaultPolling.interval == 2)
        check("the wait is bounded at 15 minutes",
              ClaudeConnectionFlow.defaultPolling.deadline == 900)
        check("the timeout message quotes the same bound it enforces",
              ClaudeConnectionFlow.deadlineText == "15 minutes"
                && ClaudeConnectionFlow.resultMessage(.timedOut)?
                    .body.contains("15 minutes") == true)
        check("the countdown is mm:ss",
              ClaudeConnectionFlow.waitingFieldText(remaining: 900)
                .contains("15:00")
                && ClaudeConnectionFlow.waitingFieldText(remaining: 62).contains("1:02")
                && ClaudeConnectionFlow.waitingFieldText(remaining: 9).contains("0:09"))
        check("the countdown never goes negative",
              ClaudeConnectionFlow.waitingFieldText(remaining: -30).contains("0:00")
                && ClaudeConnectionFlow.remaining(elapsed: 1_000, deadline: 900) == 0)
        check("remaining counts down from the bound",
              ClaudeConnectionFlow.remaining(elapsed: 0, deadline: 900) == 900
                && ClaudeConnectionFlow.remaining(elapsed: 300, deadline: 900) == 600)
        check("the placeholder says the same thing before any countdown exists",
              ClaudeConnectionFlow.awaitingFieldText.contains("waiting for sign-in"))
    }

    private static func checkEveryMessageIsSayableAndSafe(_ check: SelfTestReporter) {
        print("--- every string the flow can say, held to the project's rules ---")
        let results: [ClaudeConnectionFlow.SignInResult] = [
            .connected, .refusedAlreadyConnected, .unusable("fixture reason"), .timedOut,
            .notInstalled, .launchFailed("fixture failure"), .alreadyInProgress,
        ]
        var messages = results.compactMap {
            ClaudeConnectionFlow.resultMessage($0, command: fixtureCommand)
        }
        messages += ProviderOnboardingSituation.allCases.map {
            ClaudeConnectionFlow.situationMessage($0, reason: "fixture reason", command: fixtureCommand)
        }
        check("every result except a cancel says something",
              messages.count == results.count + ProviderOnboardingSituation.allCases.count)
        check("no message is empty",
              messages.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        check("no two situations read the same to a user",
              Set(ProviderOnboardingSituation.allCases.map {
                  ClaudeConnectionFlow.situationMessage($0, reason: "r", command: fixtureCommand).title
              }).count == ProviderOnboardingSituation.allCases.count)
        check("plain ASCII only: no em dash, no smart quote, no emoji",
              messages.allSatisfy { message in
                  (message.title + message.body).unicodeScalars.allSatisfy {
                      $0.value == 0x0a || (0x20...0x7e).contains(Int($0.value))
                  }
              })
        // The real status payload also carries email, orgId, and orgName. L2 parses none of them; nothing
        // here may reintroduce them, and no raw JSON may reach a sheet.
        let forbidden = ["loggedIn", "authMethod", "apiProvider", "subscriptionType",
                         "email", "orgId", "orgName", "{", "}"]
        check("no message leaks a status payload field or raw JSON",
              messages.allSatisfy { message in
                  forbidden.allSatisfy { !(message.title + message.body).contains($0) }
              })
        check("a runaway vendor reason is bounded before it reaches a sheet",
              (ClaudeConnectionFlow.resultMessage(
                .unusable(String(repeating: "x", count: 4_000)))?.body.count ?? 0) < 600)
        check("the waiting sheet explains that it closes itself and that Cancel undoes nothing",
              ClaudeConnectionFlow.situationMessage(.signedOut, command: fixtureCommand)
                .body.contains("closes this by itself")
                && ClaudeConnectionFlow.situationMessage(.signedOut, command: fixtureCommand)
                    .body.contains("does not undo a sign-in"))
        check("the waiting sheet names the command Terminal was given",
              ClaudeConnectionFlow.situationMessage(.signedOut, command: fixtureCommand)
                .body.contains(fixtureCommand))
        check("a message with no resolved CLI still names a runnable command",
              ClaudeConnectionFlow.situationMessage(.ready).body.contains("claude auth login"))
        check("the sign-in script no longer tells the user to click a button that is not the mechanism",
              !ClaudeSignIn.scriptBody(binary: fixtureBinary).contains("Check again"))
    }
}
