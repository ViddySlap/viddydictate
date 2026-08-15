import Foundation

/// Shared result accumulator for headless self-tests.
///
/// Self-tests keep ownership of their domain-specific section and summary wording; this type owns the
/// repeated per-check output, pass/fail accumulation, and count reporting contract.
final class SelfTestReporter {
    struct Result {
        let name: String
        let ok: Bool
    }

    private(set) var results: [Result] = []
    private let successLabel: String
    private let failureLabel: String

    init(successLabel: String = "ok ", failureLabel: String = "FAIL") {
        self.successLabel = successLabel
        self.failureLabel = failureLabel
    }

    var passed: Bool { results.allSatisfy(\.ok) }
    var passedCount: Int { results.filter(\.ok).count }
    var failedCount: Int { results.count - passedCount }

    func record(_ name: String, _ ok: Bool) {
        record(name, ok, "")
    }

    func record(_ name: String, _ ok: Bool, _ detail: String) {
        results.append(Result(name: name, ok: ok))
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        print("  [\(ok ? successLabel : failureLabel)] \(name)\(suffix)")
    }

    /// The throwing autoclosure covers both ordinary Boolean checks and checks whose expression can throw.
    /// A thrown expression is recorded as one failed check with the same content-rich error detail that the
    /// Codex isolation self-test historically printed.
    func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do {
            record(name, try condition())
        } catch {
            record(name, false, String(describing: error))
        }
    }

    /// Lets the detail-oriented tests retain their compact `check(name, ok, detail)` call sites while using
    /// this shared accumulator rather than a local results array and closure.
    func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
        record(name, ok, detail)
    }

    func summaryLine(prefix: String) -> String {
        "\(prefix) ok=\(passed) checks=\(results.count) passed=\(passedCount) failed=\(failedCount)"
    }
}
