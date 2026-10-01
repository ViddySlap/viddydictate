import Foundation

/// The one way a gate abstains because its apparatus or a precondition is missing.
///
/// An abstain is not a pass. Until 2026-10-01 the Codex catalog and device-auth gates abstained with
/// exit 0 and a `[skip]` line, and `verify.sh` printed `[verify][service][PASS]` for both, so a Codex
/// outage read as two green lines for two weeks (the device-auth gate was printing the true cause while
/// it did). Every abstain now carries `preconditionMissingMarker`, which `verify.sh` counts as SKIP, and
/// its meta-gate fails any gate log that shows this marker beside a PASS line.
enum SelfTestAbstain {
    /// Must equal `PRECONDITION_MISSING_MARKER` in scripts/service-gate-classify.sh. The deterministic
    /// classifier selftest in verify.sh reads this line and fails if the two drift apart.
    static let preconditionMissingMarker = "[precondition-missing]"

    static func line(label: String, reason: String) -> String {
        "[skip] [\(label)] SKIPPED: \(reason) \(preconditionMissingMarker)"
    }

    /// Prints the abstain line and returns true (exit 0): the gate did not fail, and it did not pass.
    @discardableResult
    static func skip(label: String, reason: String) -> Bool {
        print(line(label: label, reason: reason))
        return true
    }
}
