import Foundation

/// Live D2 gate: asks the installed Claude CLI to resolve its own credential store and verifies
/// the real JSON contract. Before running the command it proves the named login-Keychain item can be
/// resolved without requesting its data. A Keychain-denied sandbox therefore abstains before a
/// synthetic logged-out response can be mistaken for the user's real state.
///
/// Raw JSON is never printed because current CLI builds include account identity fields. Only the
/// bounded provider metadata retained by `ClaudeAuthStatus` appears in the PASS line.
enum ClaudeAuthStatusLiveGate {
    private static let label = "claude-auth-status-live"

    private static func skip(_ reason: String) -> Bool {
        print("[skip] [\(label)] SKIPPED \(reason)")
        return true
    }

    static func run(arguments: [String]) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_SANDBOX"] == "seatbelt",
           environment["CODEX_PERMISSION_PROFILE"] == "viddyvault-workspace" {
            return skip("viddyvault-workspace seatbelt denies login Keychain access")
        }

        var explicitBinary: String?
        var statusHome: String?
        if let index = arguments.firstIndex(of: "--binary"), index + 1 < arguments.count {
            explicitBinary = arguments[index + 1]
        }
        if let index = arguments.firstIndex(of: "--status-home"), index + 1 < arguments.count {
            statusHome = arguments[index + 1]
        }
        guard let binary = explicitBinary ?? CloudCleanupClient.resolveBinary() else {
            return skip("Claude CLI is not installed")
        }
        guard keychainItemIsReachable(home: statusHome) else {
            return skip("login Keychain credential is absent or unavailable")
        }

        var parent = environment
        if let statusHome { parent["HOME"] = statusHome }
        let observation = LLMProviderDetection.claudeAuthStatus(
            binary: binary,
            environment: CloudCleanupClient.buildEnv(from: parent))
        switch observation {
        case .apparatusUnavailable(let reason):
            return skip("\(reason); Keychain access or the CLI apparatus is unavailable")
        case .invalidResponse(let reason):
            print("[\(label)] FAIL \(reason)")
            return false
        case .status(let status):
            let state = LLMProviderDetection.claudeState(
                binaryFound: true,
                authStatus: observation)
            let mappingIsValid: Bool
            if !status.loggedIn {
                mappingIsValid = state == .disconnected
            } else if status.authMethod == "claude.ai" {
                mappingIsValid = state == .available
            } else if case .unavailable(let reason) = state {
                mappingIsValid = !state.requiresConnection
                    && reason.contains(status.authMethod)
                    && reason.contains("does not support it yet")
            } else {
                mappingIsValid = false
            }
            guard mappingIsValid else {
                print("[\(label)] FAIL the real response did not map through the D4 whitelist")
                return false
            }
            print("[\(label)] PASS well-formed status loggedIn=\(status.loggedIn) "
                    + "authMethod=\(status.authMethod) apiProvider=\(status.apiProvider) "
                    + "subscriptionType=\(status.subscriptionType ?? "none")")
            return true
        }
    }

    /// Existence/access probe only. No attributes and no secret data cross this boundary.
    private static func keychainItemIsReachable(home: String?) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-a", NSUserName(),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var parent = ProcessInfo.processInfo.environment
        if let home { parent["HOME"] = home }
        process.environment = CloudCleanupClient.buildEnv(from: parent)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return false }
        guard exited.wait(timeout: .now() + 5) == .success else {
            if process.isRunning { process.terminate() }
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
