import Foundation

/// Fixture-only coverage for locked decisions D2 and D4. These JSON objects are synthetic provider
/// metadata; they contain no account identity, credential, or machine-derived value.
enum ClaudeAuthStatusSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate Claude auth status - selftest ===")
        let reporter = SelfTestReporter()

        let subscription = fixture(
            loggedIn: true,
            authMethod: "claude.ai",
            apiProvider: "firstParty",
            subscriptionType: "max",
            extra: #","email":"fixture@example.invalid","futureField":{"ignored":true}"#)
        let signedOut = fixture(
            loggedIn: false,
            authMethod: "none",
            apiProvider: "none",
            subscriptionType: nil,
            includeSubscriptionType: false)
        let apiBilling = fixture(
            loggedIn: true,
            authMethod: "apiKey",
            apiProvider: "firstParty",
            subscriptionType: nil)
        let futureMethod = fixture(
            loggedIn: true,
            authMethod: "future-auth",
            apiProvider: "futureProvider",
            subscriptionType: "futurePlan")

        guard let subscriptionStatus = LLMProviderDetection.parseClaudeAuthStatus(subscription),
              let signedOutStatus = LLMProviderDetection.parseClaudeAuthStatus(signedOut),
              let apiBillingStatus = LLMProviderDetection.parseClaudeAuthStatus(apiBilling),
              let futureStatus = LLMProviderDetection.parseClaudeAuthStatus(futureMethod) else {
            reporter.record("well-formed fixture JSON parses", false)
            print(reporter.summaryLine(prefix: "Claude auth status"))
            print("CLAUDE AUTH STATUS FAILED")
            return false
        }

        reporter.record(
            "the parser retains only the four status fields",
            subscriptionStatus == LLMProviderDetection.ClaudeAuthStatus(
                loggedIn: true,
                authMethod: "claude.ai",
                apiProvider: "firstParty",
                subscriptionType: "max"))
        reporter.record(
            "loggedIn true plus the whitelisted claude.ai method is available",
            state(subscriptionStatus) == .available)
        reporter.record(
            "loggedIn false is the real disconnected state",
            state(signedOutStatus) == .disconnected)

        let apiState = state(apiBillingStatus)
        reporter.record(
            "a logged-in API method is not misreported as signed out",
            !apiState.requiresConnection && !apiState.canRun)
        reporter.record(
            "the unsupported API state names the method and says it is not supported yet",
            unsupportedReason(apiState)?.contains("apiKey") == true
                && unsupportedReason(apiState)?.contains("does not support it yet") == true)
        let unsupportedStep = ProviderOnboarding.step(
            for: .claude,
            presence: LLMProviderDetection.Presence(installed: true, state: apiState))
        reporter.record(
            "unsupported auth reaches a distinct user state with no sign-in-loop action",
            unsupportedStep.situation == .unavailable
                && unsupportedStep.action == nil
                && unsupportedStep.detail?.contains("apiKey") == true)

        let futureState = state(futureStatus)
        reporter.record(
            "the method rule is a whitelist, so an unknown future value fails closed",
            !futureState.requiresConnection && !futureState.canRun
                && unsupportedReason(futureState)?.contains("future-auth") == true)
        reporter.record(
            "binary absence remains the source of not-installed state",
            LLMProviderDetection.claudeState(
                binaryFound: false,
                authStatus: .status(subscriptionStatus))
                == .unavailable("CLI unavailable"))
        reporter.record(
            "missing apparatus and malformed successful output stay unavailable, never disconnected",
            !LLMProviderDetection.claudeState(
                binaryFound: true,
                authStatus: .apparatusUnavailable("fixture")).requiresConnection
                && !LLMProviderDetection.claudeState(
                    binaryFound: true,
                    authStatus: .invalidResponse("fixture")).requiresConnection)

        let malformed: [Data] = [
            Data(),
            Data(#"{"loggedIn":"yes","authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#.utf8),
            Data(#"{"loggedIn":true,"apiProvider":"firstParty","subscriptionType":"max"}"#.utf8),
            Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#.utf8),
            Data(#"{"loggedIn":true,"authMethod":"claude.ai\nforged","apiProvider":"firstParty","subscriptionType":"max"}"#.utf8),
        ]
        reporter.record(
            "missing, mistyped, incomplete, and unsafe status JSON all fail parsing",
            malformed.allSatisfy { LLMProviderDetection.parseClaudeAuthStatus($0) == nil })
        checkCommandExitContract(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Claude auth status"))
        print(reporter.passed ? "CLAUDE AUTH STATUS GREEN" : "CLAUDE AUTH STATUS FAILED")
        return reporter.passed
    }

    private static func fixture(
        loggedIn: Bool,
        authMethod: String,
        apiProvider: String,
        subscriptionType: String?,
        includeSubscriptionType: Bool = true,
        extra: String = ""
    ) -> Data {
        let subscription: String
        if includeSubscriptionType {
            let value = subscriptionType.map { #""\#($0)""# } ?? "null"
            subscription = #","subscriptionType":\#(value)"#
        } else {
            subscription = ""
        }
        return Data(
            """
            {"loggedIn":\(loggedIn),"authMethod":"\(authMethod)",\
            "apiProvider":"\(apiProvider)"\(subscription)\(extra)}
            """.utf8)
    }

    private static func state(_ status: LLMProviderDetection.ClaudeAuthStatus)
        -> LLMProviderAvailabilityState {
        LLMProviderDetection.claudeState(
            binaryFound: true,
            authStatus: .status(status))
    }

    private static func unsupportedReason(_ state: LLMProviderAvailabilityState) -> String? {
        guard case .unavailable(let reason) = state else { return nil }
        return reason
    }

    /// Current Claude CLI exits 1 for a real logged-out JSON response. Pin that transport detail so
    /// the command runner cannot regress the pure `.disconnected` mapping into apparatus failure.
    private static func checkCommandExitContract(_ reporter: SelfTestReporter) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-claude-auth-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude-fixture")
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data(
                """
                #!/bin/sh
                printf '%s\\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
                exit 1
                """.utf8
            ).write(to: executable, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path)
            let observed = LLMProviderDetection.claudeAuthStatus(
                binary: executable.path,
                timeout: 1,
                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"])
            guard case .status(let status) = observed else {
                reporter.record("exit-1 logged-out JSON remains a real status response", false)
                return
            }
            reporter.record(
                "exit-1 logged-out JSON remains a real status response",
                !status.loggedIn && state(status) == .disconnected)
        } catch {
            reporter.record(
                "exit-1 logged-out JSON remains a real status response",
                false,
                String(describing: error))
        }
    }
}
