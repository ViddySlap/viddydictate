import Foundation

/// S2 live service gate. It consumes a synthetic email arm through the production transform-slot
/// lifecycle, then runs one real LM Studio transform without printing either the input or output.
///
/// A managed Codex seatbelt cannot reach loopback services, so it abstains explicitly. The unsandboxed
/// release host must run the same gate and receive the real PASS line.
enum PerTakeArmServiceGate {
    static func run() -> Bool {
        Settings.registerDefaults()

        let state = TransformArmState()
        state.armOneShot(ArmedOneShot(
            source: .builtIn(.email),
            id: OneShotMode.email.id,
            label: OneShotMode.email.label,
            glyph: "M"))
        guard let released = state.takeOneShotForRelease(),
              released.id == OneShotMode.email.id,
              state.armedOneShot == nil else {
            print("[per-take-arm-service] FAIL: release did not consume the synthetic email arm")
            return false
        }
        guard case .builtIn(.email) = released.source else {
            print("[per-take-arm-service] FAIL: release changed the armed source")
            return false
        }

        if let sandbox = ProcessInfo.processInfo.environment["CODEX_SANDBOX"], !sandbox.isEmpty {
            print("[skip] per-take armed transform SKIPPED: managed sandbox denies live LM Studio access")
            return true
        }

        let syntheticInput =
            "Write a short email to Casey confirming the synthetic rehearsal is booked for Friday at ten."
        let (result, wall) = EmailClient.emailSync(syntheticInput, timeout: Settings.emailTimeout)
        switch result {
        case .ok(let output):
            let asciiOnly = output.unicodeScalars.allSatisfy(\.isASCII)
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, asciiOnly else {
                print("[per-take-arm-service] FAIL: live transform returned empty or non-ASCII output")
                return false
            }
            print("[per-take-arm-service] PASS: released=email outputChars=\(output.count) "
                  + "wall=\(String(format: "%.2f", wall))s")
            return true
        case .unavailable(let reason):
            print("[per-take-arm-service] FAIL: live transform unavailable (\(reason))")
        case .timedOut:
            print("[per-take-arm-service] FAIL: live transform timed out")
        case .badOutput(let reason):
            print("[per-take-arm-service] FAIL: live transform returned bad output (\(reason))")
        }
        return false
    }
}
