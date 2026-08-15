import Foundation

/// How P8's preflight report READS (Public V1 spec W5, item P11).
///
/// This is presentation only: it adds no check, no judgement, and no severity. Every fact it shows comes
/// from a `PreflightFinding` the pure evaluator already produced and from `PreflightCheck.title`, which P8
/// deliberately parked beside the check identity so the surface would inherit the wording rather than
/// invent a second set of names. The strings this type owns are exactly the ones a report does not carry:
/// the headline, the two detail prefixes, and the footer.
///
/// It exists as a separate type from the view because a claim about what the surface SAYS should be
/// checkable without AppKit. The view and its offscreen probe both read the constants and identifiers
/// below, so the thing rendered and the thing asserted cannot drift into two different surfaces.
enum PreflightSurface {

    // MARK: - Identity

    /// The addressable parts of one row. The probe drives the same identifiers the view builds, so a row
    /// that silently stopped rendering its remedy fails the gate instead of shipping a half message.
    enum RowPart: String, CaseIterable {
        case status
        case title
        case summary
        case remedy
        case reduced
    }

    static let headlineIdentifier = "preflight-headline"
    static let subtitleIdentifier = "preflight-subtitle"
    static let recheckIdentifier = "preflight-recheck"
    static let footerIdentifier = "preflight-footer"

    static func identifier(_ part: RowPart, _ check: PreflightCheck) -> String {
        "preflight-\(part.rawValue)|\(check.rawValue)"
    }

    static func cardIdentifier(_ check: PreflightCheck) -> String {
        "preflight-card|\(check.rawValue)"
    }

    // MARK: - Headline

    /// Shown while the measuring half is running. It is a state, not a verdict: an empty report and a
    /// clean report must never read the same, or a check that has not run yet looks like a pass.
    static let checkingHeadline = "Checking your setup..."

    static let cleanHeadline = "Everything ViddyDictate needs is set up."

    /// Re-runnability and the never-block promise, said once at the top rather than implied. W5's answer
    /// is that preflight warns and lets the user proceed, so the surface states that outright instead of
    /// leaving a user to infer it from the absence of a wall.
    static let subtitle =
        "This reads your machine every time you open Settings, and again whenever you click Check again. "
        + "Nothing here blocks ViddyDictate: anything missing costs only the feature that needs it, and "
        + "each row below says which."

    static let footer =
        "Speech-to-text runs on your own machine. The text transforms use whichever provider you are "
        + "signed in to, and one is enough - ViddyDictate never needs both."

    static func headline(_ report: PreflightReport) -> String {
        let count = report.warnings.count
        guard count > 0 else { return cleanHeadline }
        return count == 1
            ? "1 thing needs attention."
            : "\(count) things need attention."
    }

    // MARK: - Rows

    /// The row's own state word. Deliberately not a colour or an icon alone: the render seam captures
    /// pixels, and a user reading a screenshot in a bug report should be able to tell the rows apart
    /// without relying on hue.
    static func statusText(_ finding: PreflightFinding) -> String {
        finding.isWarning ? "NEEDS ATTENTION" : "OK"
    }

    /// P8 writes remedies as lowercase imperatives ("run ./install-daemon.sh...") precisely so a prefix
    /// like this can head them. nil for a passing check, which is why the view has nothing to lay out.
    static func remedyLine(_ finding: PreflightFinding) -> String? {
        finding.remedy.map { "Fix: \($0)" }
    }

    static func reducedLine(_ finding: PreflightFinding) -> String? {
        finding.reducedFunction.map { "Until then: \($0)" }
    }

    /// Everything under the row's title, in order. A warning always contributes three lines and a passing
    /// check exactly one, so "a warning never renders without its fix" is a property of this one function
    /// rather than a convention repeated at each call site.
    static func detailLines(_ finding: PreflightFinding) -> [String] {
        [finding.summary] + [remedyLine(finding), reducedLine(finding)].compactMap { $0 }
    }
}
