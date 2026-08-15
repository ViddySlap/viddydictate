import Foundation

/// Pure coverage for the Setup surface (Public V1 spec W5, item P11): the preflight report, as a user
/// reads it.
///
/// P8's gate proves the POLICY produces a specific actionable message per failure mode. This one proves the
/// SURFACE still carries it - that the presentation layer between a finding and a Settings row cannot drop
/// the fix, paraphrase it, hide a passing check, or make a not-yet-run check look like a pass. The failure
/// modes are P8's own table rather than a second copy, so the two gates cannot cover different machines.
///
/// No AppKit here on purpose: the offscreen render gate (`--setup-render`) proves the view draws these
/// strings, and this gate proves the strings are right. A claim about wording should not need a window.
enum PreflightSurfaceSelfTest {

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate setup surface (preflight presentation) - selftest ===")
        let reporter = SelfTestReporter()

        checkCleanReport(reporter)
        checkHeadlineCounts(reporter)
        checkEveryWarningKeepsItsFix(reporter)
        checkSurfaceAddsNoWordingOfItsOwn(reporter)
        checkPassingChecksAreStillShown(reporter)
        checkNotYetRunIsNotAPass(reporter)
        checkIdentifiersAreAddressable(reporter)
        checkSurfaceNeverBlocks(reporter)

        print("\n=== RESULT ===")
        print(reporter.passed ? "SETUP SURFACE GREEN" : "SETUP SURFACE FAILED")
        return reporter.passed
    }

    // MARK: - Fixtures

    private static var healthy: PreflightObservation { PreflightSelfTest.healthy }

    private static var failureModes: [(label: String, check: PreflightCheck, obs: PreflightObservation)] {
        PreflightSelfTest.failureModes
    }

    /// Every check failing at once: the worst machine the surface has to render.
    private static var broken: PreflightObservation { PreflightSelfTest.broken }

    private static func finding(_ check: PreflightCheck,
                                _ observation: PreflightObservation) -> PreflightFinding? {
        Preflight.evaluate(observation).finding(check)
    }

    // MARK: - Checks

    private static func checkCleanReport(_ check: SelfTestReporter) {
        print("--- a set-up machine reads as set up ---")
        let report = Preflight.evaluate(healthy)
        check("a clean report gets the clean headline",
              PreflightSurface.headline(report) == PreflightSurface.cleanHeadline)
        check("every row on a clean machine reads OK",
              report.findings.allSatisfy { PreflightSurface.statusText($0) == "OK" })
        check("a passing row is one line: what was found, and nothing to do about it",
              report.findings.allSatisfy { PreflightSurface.detailLines($0).count == 1 })
        check("a passing row offers no fix and claims no lost function",
              report.findings.allSatisfy {
                  PreflightSurface.remedyLine($0) == nil && PreflightSurface.reducedLine($0) == nil
              })
    }

    private static func checkHeadlineCounts(_ check: SelfTestReporter) {
        print("--- the headline counts what is wrong ---")
        var one = healthy
        one.webSearchHelperInstalled = false
        let singular = PreflightSurface.headline(Preflight.evaluate(one))
        check("one warning is counted in the singular", singular == "1 thing needs attention.", singular)

        let all = Preflight.evaluate(broken)
        let plural = PreflightSurface.headline(all)
        check("every check failing is counted in the plural",
              plural == "\(PreflightCheck.allCases.count) things need attention.", plural)
        check("a report with warnings never reads as clean",
              plural != PreflightSurface.cleanHeadline && singular != PreflightSurface.cleanHeadline)
    }

    private static func checkEveryWarningKeepsItsFix(_ check: SelfTestReporter) {
        print("--- a warning row cannot render without its fix ---")
        var everyRowIsComplete = true
        var everyRowIsPrefixed = true
        var missing: [String] = []

        for mode in failureModes {
            guard let f = finding(mode.check, mode.obs), f.isWarning else {
                missing.append(mode.label)
                continue
            }
            let lines = PreflightSurface.detailLines(f)
            if lines.count != 3 { everyRowIsComplete = false; missing.append(mode.label) }
            if !(lines.count == 3 && lines[1].hasPrefix("Fix: ") && lines[2].hasPrefix("Until then: ")) {
                everyRowIsPrefixed = false
            }
        }

        check("every failure mode still produces a warning row",
              missing.isEmpty, missing.joined(separator: ","))
        check("every warning row carries all three lines: state, fix, and what stops working",
              everyRowIsComplete, "\(failureModes.count) modes")
        check("the fix and the consequence are labelled as such", everyRowIsPrefixed)
        check("a warning row is marked as needing attention",
              failureModes.allSatisfy {
                  guard let f = finding($0.check, $0.obs) else { return false }
                  return PreflightSurface.statusText(f) == "NEEDS ATTENTION"
              })
        check("an OK row and a warning row do not read the same",
              PreflightSurface.statusText(
                PreflightFinding(check: .sttDaemon, severity: .ok, summary: "x",
                                 remedy: nil, reducedFunction: nil))
                != PreflightSurface.statusText(
                    PreflightFinding(check: .sttDaemon, severity: .warning, summary: "x",
                                     remedy: "y", reducedFunction: "z")))
    }

    private static func checkSurfaceAddsNoWordingOfItsOwn(_ check: SelfTestReporter) {
        print("--- the surface quotes the finding rather than rewriting it ---")
        var paraphrased: [String] = []
        for mode in failureModes {
            guard let f = finding(mode.check, mode.obs),
                  let remedy = PreflightSurface.remedyLine(f),
                  let reduced = PreflightSurface.reducedLine(f) else {
                paraphrased.append(mode.label)
                continue
            }
            // Byte-identical after the prefix. A surface that "tidied" a remedy could quietly drop the
            // command a user has to paste, and the P8 gate that proved the remedy actionable would still
            // be green while the row on screen was not.
            if remedy != "Fix: \(f.remedy ?? "")" { paraphrased.append("\(mode.label).remedy") }
            if reduced != "Until then: \(f.reducedFunction ?? "")" {
                paraphrased.append("\(mode.label).reduced")
            }
            if PreflightSurface.detailLines(f).first != f.summary {
                paraphrased.append("\(mode.label).summary")
            }
        }
        check("every row's text is the finding's own, prefixed and otherwise untouched",
              paraphrased.isEmpty, paraphrased.joined(separator: ","))

        check("the row title is the check's own title, not a second set of names",
              PreflightCheck.allCases.allSatisfy { !$0.title.isEmpty }
                && Set(PreflightCheck.allCases.map(\.title)).count == PreflightCheck.allCases.count)
    }

    private static func checkPassingChecksAreStillShown(_ check: SelfTestReporter) {
        print("--- a passing check is shown, in a fixed order ---")
        let all = Preflight.evaluate(broken)
        check("the surface renders one row per check, in declaration order",
              all.findings.map(\.check) == PreflightCheck.allCases)

        var mixed = healthy
        mixed.accessibility = .notGranted
        let report = Preflight.evaluate(mixed)
        check("a mostly-healthy machine still lists the checks that passed",
              report.findings.count == PreflightCheck.allCases.count
                && report.findings.filter { !$0.isWarning }.count == PreflightCheck.allCases.count - 1)
        check("the row that failed is the row that is marked",
              report.findings.filter { PreflightSurface.statusText($0) == "NEEDS ATTENTION" }
                .map(\.check) == [.accessibility])
    }

    private static func checkNotYetRunIsNotAPass(_ check: SelfTestReporter) {
        print("--- a check that has not run yet does not look like a pass ---")
        check("the in-flight headline is not the clean headline",
              PreflightSurface.checkingHeadline != PreflightSurface.cleanHeadline)
        check("the in-flight headline says it is still working",
              PreflightSurface.checkingHeadline.lowercased().contains("checking"))
        check("the subtitle says the check re-runs rather than being a one-off",
              PreflightSurface.subtitle.contains("Check again")
                && PreflightSurface.subtitle.contains("every time you open Settings"))
    }

    private static func checkIdentifiersAreAddressable(_ check: SelfTestReporter) {
        print("--- every part of every row is addressable exactly once ---")
        var identifiers: [String] = []
        for part in PreflightSurface.RowPart.allCases {
            for target in PreflightCheck.allCases {
                identifiers.append(PreflightSurface.identifier(part, target))
            }
        }
        identifiers.append(contentsOf: PreflightCheck.allCases.map(PreflightSurface.cardIdentifier))
        identifiers.append(contentsOf: [
            PreflightSurface.headlineIdentifier, PreflightSurface.subtitleIdentifier,
            PreflightSurface.recheckIdentifier, PreflightSurface.footerIdentifier,
        ])
        check("no two controls claim the same identifier",
              Set(identifiers).count == identifiers.count,
              "\(Set(identifiers).count) of \(identifiers.count)")
        check("a row identifier names both the part and the check",
              PreflightSurface.identifier(.remedy, .webAnswerKey)
                == "preflight-remedy|\(PreflightCheck.webAnswerKey.rawValue)")
    }

    private static func checkSurfaceNeverBlocks(_ check: SelfTestReporter) {
        print("--- W5: the surface warns and says so; it never gates the app ---")
        // The same phrase list P8's gate applies to the messages, applied to the strings this layer owns.
        // A report full of warnings whose HEADLINE said "fix these before continuing" would violate W5 just
        // as surely as a blocking severity, and the type system cannot catch a sentence.
        let blockingPhrases = ["cannot continue", "before you can use", "you must fix",
                               "not allowed", "disabled until", "required before",
                               "before continuing", "must be fixed"]
        let owned = [PreflightSurface.cleanHeadline, PreflightSurface.checkingHeadline,
                     PreflightSurface.subtitle, PreflightSurface.footer,
                     PreflightSurface.headline(Preflight.evaluate(broken))]
        check("no surface-owned string tells the user they may not proceed",
              owned.allSatisfy { text in
                  let lower = text.lowercased()
                  return !blockingPhrases.contains { lower.contains($0) }
              })
        check("the surface states outright that nothing here blocks the app",
              PreflightSurface.subtitle.contains("Nothing here blocks ViddyDictate"))
        check("the surface says one provider is enough, matching locked decision 3",
              PreflightSurface.footer.contains("never needs both"))
        check("a blocking severity is still not expressible, so no row can carry one",
              PreflightSeverity.allCases.count == 2)
    }
}
