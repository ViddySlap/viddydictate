import Foundation

enum CodexTransformResult {
    static func resolve(_ outcome: CodexRuntimeOutcome,
                        request: TextTransformRequest) -> CleanupClient.Result {
        let result: CleanupClient.Result
        var diagnosticSuffix = ""
        switch outcome {
        case .success(let success):
            let normalized = CleanupClient.asciiPunctuationNormalized(success.result)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return .badOutput("empty Codex output") }
            Log.write(
                "codex OK route=\(request.route.rawValue) profile=\(success.profileHash) " +
                "bytes=\(success.stdoutBytes)/\(success.stderrBytes) " +
                "chars=\(request.userMessage.count)->\(normalized.count) " +
                "elapsed=\(String(format: "%.2f", success.elapsed))s")
            result = .ok(normalized)
        case .disconnected:
            result = .unavailable("Codex is disconnected; connect Codex in Settings > Setup")
        case .timedOut:
            result = .timedOut
        case .rejected(let classification):
            result = .badOutput("Codex response rejected: \(classification)")
        case .unavailable(let reason):
            result = .unavailable(reason)
        case .processFailure(let exitCode, let stderrBytes, let stderrHead):
            result = .unavailable("Codex contained process exited nonzero (\(exitCode))")
            diagnosticSuffix = " stderrBytes=\(stderrBytes)"
            if !stderrHead.isEmpty { diagnosticSuffix += " stderrHead=\(stderrHead)" }
        }
        updateAvailability(after: outcome)
        if case .ok = result {} else {
            let classification: String
            switch result {
            case .ok: classification = "ok"
            case .unavailable: classification = "unavailable"
            case .timedOut: classification = "timeout"
            case .badOutput: classification = "bad_output"
            }
            Log.write("codex FAIL route=\(request.route.rawValue) "
                + "classification=\(classification)\(diagnosticSuffix)")
        }
        return result
    }

    private static func updateAvailability(after outcome: CodexRuntimeOutcome) {
        let state: LLMProviderAvailabilityState?
        switch outcome {
        case .success, .timedOut, .rejected:
            state = .available
        case .disconnected:
            state = .disconnected
        case .unavailable(let reason):
            state = .unavailable(reason)
        case .processFailure(let exitCode, _, _):
            state = .unavailable("Codex contained process exited nonzero (\(exitCode))")
        }
        guard let state else { return }
        DispatchQueue.main.async {
            Settings.modelsPower.setAvailabilityState(state, for: .codex)
        }
    }
}
