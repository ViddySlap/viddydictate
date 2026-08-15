import Foundation
import Darwin

/// The one owner of "can this provider run right now, and is it even installed".
///
/// Before this existed the derivation lived in two places — the cloud update check's inline ladder and
/// the Codex connection controller's publish switch — and preflight (W5) needed a third. Three copies of
/// one rule is exactly the duplicate-concept the chain post-mortem forbids, so the rule moved here and
/// both original call sites now read it from this type.
///
/// Everything above the `live` mark is pure: it takes measured facts and returns a state. The live half
/// performs the measurements and is deliberately a 1:1 transcription of existing accessors, so all of the
/// judgement stays in the pure half where the deterministic rail can reach it.
enum LLMProviderDetection {
    /// The content-safe subset of `claude auth status --json`. The command also returns account
    /// identity fields; ViddyDictate neither needs nor retains them.
    struct ClaudeAuthStatus: Equatable {
        let loggedIn: Bool
        let authMethod: String
        let apiProvider: String
        let subscriptionType: String?
    }

    /// A real status response is kept distinct from a missing measuring apparatus and from vendor
    /// output that claimed success without satisfying the JSON contract. The services gate may
    /// abstain only on `.apparatusUnavailable`; `.invalidResponse` is a blocking protocol failure.
    enum ClaudeAuthStatusObservation: Equatable {
        case status(ClaudeAuthStatus)
        case apparatusUnavailable(String)
        case invalidResponse(String)
    }


    /// A provider's installed-ness alongside its runnable state. The two are separate questions with
    /// separate remedies — "install it" versus "sign in to it" — and `LLMProviderAvailabilityState` alone
    /// cannot answer the first.
    struct Presence: Equatable {
        let installed: Bool
        let state: LLMProviderAvailabilityState

        init(installed: Bool, state: LLMProviderAvailabilityState) {
            self.installed = installed
            self.state = state
        }
    }

    // MARK: - Pure derivations

    /// Claude Code owns both of its credential stores, so its own status command is the only
    /// connection authority. The method check is deliberately a whitelist: an unknown future value
    /// remains a named unsupported state instead of silently gaining subscription privileges.
    static func claudeState(binaryFound: Bool,
                            authStatus: ClaudeAuthStatusObservation)
        -> LLMProviderAvailabilityState {
        if !binaryFound { return .unavailable("CLI unavailable") }
        switch authStatus {
        case .status(let status):
            guard status.loggedIn else { return .disconnected }
            guard status.authMethod == "claude.ai" else {
                return .unavailable(
                    "signed in with Claude auth method \(status.authMethod); "
                        + "ViddyDictate does not support it yet")
            }
            return .available
        case .apparatusUnavailable:
            return .unavailable("Claude auth status unavailable")
        case .invalidResponse:
            return .unavailable("Claude auth status response invalid")
        }
    }

    /// The fuller question the cloud update check asks after it has also run a `--version` probe and the
    /// live alias probe: the connection authority above, then the two further ways a present, supported
    /// CLI can still fail to run.
    static func claudeState(connectionState: LLMProviderAvailabilityState,
                            versionResolved: Bool,
                            aliasProbeFailed: Bool) -> LLMProviderAvailabilityState {
        guard connectionState.canRun else { return connectionState }
        if !versionResolved { return .unavailable("CLI version check failed") }
        if aliasProbeFailed { return .unavailable("live alias probe failed") }
        return .available
    }

    /// Parse fixture or live JSON without retaining account identity fields. Required strings are
    /// short provider metadata tokens; bounding and restricting them keeps a future vendor value
    /// safe to place in a user-facing diagnostic.
    static func parseClaudeAuthStatus(_ data: Data) -> ClaudeAuthStatus? {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool,
              let authMethod = boundedStatusToken(object["authMethod"]),
              let apiProvider = boundedStatusToken(object["apiProvider"]) else {
            return nil
        }
        let subscriptionType: String?
        if !object.keys.contains("subscriptionType") {
            // Current Claude CLI omits subscriptionType from its logged-out response and exits 1.
            // A logged-in response without the field is still malformed.
            guard !loggedIn else { return nil }
            subscriptionType = nil
        } else if object["subscriptionType"] is NSNull {
            subscriptionType = nil
        } else {
            guard let value = boundedStatusToken(object["subscriptionType"]) else { return nil }
            subscriptionType = value
        }
        return ClaudeAuthStatus(
            loggedIn: loggedIn,
            authMethod: authMethod,
            apiProvider: apiProvider,
            subscriptionType: subscriptionType)
    }

    private static func boundedStatusToken(_ value: Any?) -> String? {
        guard let token = value as? String,
              !token.isEmpty, token.utf8.count <= 128,
              token.unicodeScalars.allSatisfy({
                  (0x20...0x7e).contains(Int($0.value))
              }) else {
            return nil
        }
        return token
    }

    // MARK: - Live Claude auth measurement

    /// Run the store-agnostic CLI status check with a short wall-clock bound. Both streams are
    /// drained concurrently so vendor diagnostics cannot deadlock the caller. No raw output is
    /// logged or returned: newer CLI builds include account identity fields in this JSON.
    static func claudeAuthStatus(
        binary: String,
        timeout: TimeInterval = 5,
        environment: [String: String] = CloudCleanupClient.buildEnv(
            from: ProcessInfo.processInfo.environment)
    ) -> ClaudeAuthStatusObservation {
        guard binary.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: binary) else {
            return .apparatusUnavailable("Claude CLI is not executable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "status", "--json"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return .apparatusUnavailable("Claude auth status could not start") }

        var stdout = Data()
        var stderr = Data()
        let outputDone = DispatchSemaphore(value: 0)
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            outputDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderr = errors.fileHandleForReading.readDataToEndOfFile()
            errorDone.signal()
        }

        guard exited.wait(timeout: .now() + max(0.1, timeout)) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = outputDone.wait(timeout: .now() + 1)
            _ = errorDone.wait(timeout: .now() + 1)
            return .apparatusUnavailable("Claude auth status timed out")
        }
        _ = outputDone.wait(timeout: .now() + 1)
        _ = errorDone.wait(timeout: .now() + 1)

        guard stdout.count <= 65_536, stderr.count <= 65_536 else {
            return .invalidResponse("Claude auth status output exceeded its bound")
        }
        if let parsed = parseClaudeAuthStatus(stdout) {
            if process.terminationReason == .exit, process.terminationStatus == 0 {
                return .status(parsed)
            }
            // Claude CLI spells a real logged-out state as well-formed JSON plus exit 1. Preserve
            // that state instead of collapsing it into apparatus failure.
            if !parsed.loggedIn { return .status(parsed) }
            return .invalidResponse(
                "Claude auth status returned logged-in JSON with a nonzero exit")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .apparatusUnavailable(
                "Claude auth status exited \(process.terminationStatus) before returning JSON")
        }
        return .invalidResponse("Claude auth status returned malformed JSON")
    }

    // MARK: - Remaining pure derivations

    /// Codex reports its own connection state through the audited boundary; this is only the projection
    /// onto the routing/preflight vocabulary. `.disconnected` is the meaningful one: it is precisely
    /// "installed but signed out", which is what lets preflight offer a sign-in remedy rather than an
    /// install one.
    static func availability(from state: CodexConnectionState) -> LLMProviderAvailabilityState {
        switch state {
        case .connected: return .available
        case .disconnected: return .disconnected
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    /// Local is the optional post-V1 power path (locked decision 1), so "not installed" is an ordinary
    /// state rather than a defect. The two reasons are distinct because they have distinct remedies.
    static func localState(lmsInstalled: Bool, serverResponding: Bool) -> LLMProviderAvailabilityState {
        if !lmsInstalled { return .unavailable("LM Studio is not installed") }
        if !serverResponding { return .unavailable("LM Studio is not running") }
        return .available
    }

    // MARK: - Live measurement

    /// Measure every provider. Synchronous and process-spawning (the Codex boundary audit and the `lms`
    /// probe both shell out), so call it OFF the main thread.
    ///
    /// The Claude arm deliberately runs only `auth status`: the `--version` and live-alias probes belong
    /// to the scheduled cloud update check, and re-running them on every preflight would charge a
    /// user-initiated status refresh for work that answers a different question.
    static func observeAll(codexState: @autoclosure () -> CodexConnectionState
                            = CodexProviderRuntime.connectionState()) -> [LLMProvider: Presence] {
        let claude = observeClaude()

        let codexInstalled = FileManager.default.isExecutableFile(
            atPath: CodexIsolationFoundation.codexBinary)
        // The boundary audit is only meaningful when the vendor binary it audits exists; without it the
        // honest answer is "not installed" rather than whatever the audit failed with.
        let codexAvailability: LLMProviderAvailabilityState = codexInstalled
            ? availability(from: codexState())
            : .unavailable("the codex CLI is not installed")

        let lmsInstalled = ModelResidency.isInstalled
        return [
            .claude: claude,
            .codex: Presence(installed: codexInstalled, state: codexAvailability),
            .local: Presence(
                installed: lmsInstalled,
                state: localState(lmsInstalled: lmsInstalled,
                                  serverResponding: lmsInstalled && ModelResidency.serverResponds())),
        ]
    }

    /// The single live owner for Claude connection state. Callers may pass an already-resolved
    /// binary to avoid resolving the same path twice; no caller supplies a connection verdict.
    static func observeClaude(binary: String? = CloudCleanupClient.resolveBinary()) -> Presence {
        guard let binary else {
            return Presence(installed: false, state: .unavailable("CLI unavailable"))
        }
        let authStatus = claudeAuthStatus(binary: binary)
        return Presence(
            installed: true,
            state: claudeState(binaryFound: true, authStatus: authStatus))
    }
}
