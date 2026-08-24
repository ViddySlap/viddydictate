import Foundation

/// Live-kernel, headless coverage for `SystemMemory`. No shell, UI, provider, or user data.
enum SystemMemorySelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate system memory facts and budget math - selftest ===")
        let reporter = SelfTestReporter()

        let userWireLimit = SystemMemory.userWireLimitBytes
        let noUserWire = SystemMemory.noUserWireBytes
        let physical = SystemMemory.physicalBytes
        let wired = SystemMemory.wiredBytes

        // `hw.memsize` and HOST_VM_INFO64 are reachable from every environment this suite runs in,
        // so their absence is a real failure. The two `vm.global_*` names are NOT: a seatbelted
        // Codex worker gets EPERM for exactly those, measured by vdmg-L1 on 2026-08-24. Recording
        // that as FAIL would put a permanent red in the deterministic tier for every sandboxed
        // link, which says "this is broken" when the truth is "this cannot be tested here". So the
        // unavailable case prints a marker the gate downgrades to UNVERIFIED, mirroring what the
        // Codex S1 isolation gate already does for nested `sandbox_apply`. The unsandboxed review
        // link still proves the invariant for real.
        reporter.record("hw.memsize is readable", physical != nil)
        reporter.record("HOST_VM_INFO64 wired bytes are readable", wired != nil)

        if let userWireLimit, let noUserWire, let physical {
            reporter.record("vm.global_user_wire_limit is readable", true)
            reporter.record("vm.global_no_user_wire_amount is readable", true)
            reporter.record(
                "user-wire ceiling plus reserved bytes equals physical memory",
                userWireLimit.addingReportingOverflow(noUserWire) == (physical, false),
                "userWireLimit=\(userWireLimit) reserved=\(noUserWire) physical=\(physical)"
            )
            checkBudget(position: 0, expectedFraction: 0.25,
                        userWireLimit: userWireLimit, reporter: reporter)
            checkBudget(position: 54, expectedFraction: 0.601,
                        userWireLimit: userWireLimit, reporter: reporter)
            checkBudget(position: 100, expectedFraction: 0.90,
                        userWireLimit: userWireLimit, reporter: reporter)
        } else if physical == nil {
            // hw.memsize itself is unreachable. That is a genuine failure, already recorded above.
            reporter.record("sysctl invariant is testable", false, "hw.memsize unavailable")
        } else {
            // Only the vm.global_* pair is denied. Not testable here; not broken.
            print("KERNEL WIRE FACTS UNAVAILABLE: vm.global_user_wire_limit / "
                + "vm.global_no_user_wire_amount denied in this environment "
                + "(userWireLimit=\(String(describing: userWireLimit)) "
                + "noUserWire=\(String(describing: noUserWire))); "
                + "the sysctl invariant and the budget mapping cannot be proven here.")
        }

        // The pure slider mapping needs no kernel facts at all, so it is asserted unconditionally.
        // This is what keeps a sandboxed run from proving nothing: the formula is still gated even
        // when the ceiling it multiplies is unreadable.
        for (position, expected) in [(0.0, 0.25), (54.0, 0.601), (100.0, 0.90)] {
            reporter.record(
                "slider position \(positionLabel(position)) maps to \(percentLabel(expected)) (pure)",
                abs(SystemMemory.realFraction(forSliderPosition: position) - expected) < 1e-12,
                String(format: "mapped=%.12f expected=%.12f",
                       SystemMemory.realFraction(forSliderPosition: position), expected)
            )
        }

        if let wired, let physical {
            reporter.record(
                "wired memory is plausible and below physical memory",
                wired > 0 && wired < physical,
                "wired=\(wired) physical=\(physical)"
            )
        } else {
            reporter.record("wired memory is plausible and below physical memory", false,
                            "wired or physical memory unavailable")
        }

        reporter.record(
            "GB formatter uses decimal gigabytes and one decimal place",
            SystemMemory.formatGB(36_060_000_000) == "36.1 GB"
                && SystemMemory.formatGB(12_360_000_000) == "12.4 GB"
        )

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "System memory"))
        return reporter.passed
    }

    private static func checkBudget(position: Double, expectedFraction: Double,
                                    userWireLimit: UInt64, reporter: SelfTestReporter) {
        let mappedFraction = SystemMemory.realFraction(forSliderPosition: position)
        guard let budget = SystemMemory.budgetBytes(forSliderPosition: position) else {
            reporter.record("slider position \(positionLabel(position)) maps to \(percentLabel(expectedFraction))",
                            false, "budget unavailable")
            return
        }

        // The budget conversion drops at most a fractional byte. Compare the independently derived
        // observed ratio with enough room for that one-byte truncation, not with a copy of the formula.
        let observedFraction = Double(budget) / Double(userWireLimit)
        let tolerance = 2.0 / Double(userWireLimit)
        reporter.record(
            "slider position \(positionLabel(position)) maps to \(percentLabel(expectedFraction))",
            abs(mappedFraction - expectedFraction) < 1e-12
                && abs(observedFraction - expectedFraction) <= tolerance,
            String(format: "mapped=%.3f observed=%.9f budget=%llu limit=%llu",
                   mappedFraction, observedFraction, budget, userWireLimit)
        )
    }

    private static func positionLabel(_ position: Double) -> String {
        String(format: "%.0f", position)
    }

    private static func percentLabel(_ fraction: Double) -> String {
        let percentage = fraction * 100.0
        return percentage.rounded() == percentage
            ? String(format: "%.0f%%", percentage)
            : String(format: "%.1f%%", percentage)
    }
}
