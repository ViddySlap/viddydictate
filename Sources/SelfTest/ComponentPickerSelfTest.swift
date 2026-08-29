import Foundation

/// Deterministic proof for the first-run component picker (spec B1-B6, O1, O2).
///
/// Every machine below is synthetic. Nothing here reads this Mac's sysctls, contacts Hugging Face, or
/// asks LM Studio anything, because the properties worth pinning are exactly the ones a developer's own
/// 64 GB machine would hide: what an 8 GB Air is offered, and what the running total says when a row
/// nobody has measured is ticked.
enum ComponentPickerSelfTest {

    /// The measured kernel ratio this Mac reports, used to synthesize other machines.
    ///
    /// `vm.global_user_wire_limit` was 56,349,970,923 against a `hw.memsize` of 68,719,476,736 on
    /// 2026-08-27, so macOS lets user processes wire about 82% of installed memory and reserves the
    /// rest. Synthesizing an 8 GB machine from that ratio is an extrapolation and is labelled as one;
    /// what the checks below actually pin is the PICKER's arithmetic, which is the part that can be
    /// wrong in a way a user pays 17 GB for.
    private static let measuredWireLimitFraction = 0.820

    static func run() -> Bool {
        print("=== ViddyDictate first-run component picker - selftest ===")
        let reporter = SelfTestReporter()
        checkCoreIsNotAChoice(reporter)
        checkMeasuredSizes(reporter)
        checkRunningTotal(reporter)
        checkMachineTiers(reporter)
        checkPickerAgreesWithLoader(reporter)
        checkUnreadableMemory(reporter)
        checkInstallChoice(reporter)
        checkPlanHandedOn(reporter)
        checkCopy(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "component picker"))
        print(reporter.passed ? "\nCOMPONENT PICKER GREEN" : "\nCOMPONENT PICKER FAILED")
        return reporter.passed
    }

    // MARK: - Synthetic machines

    private static func mac(gibibytes: Double, wiredGB: Double) -> ComponentPicker.MachineFacts {
        let physical = UInt64(gibibytes * 1_073_741_824)
        let wireLimit = Double(physical) * measuredWireLimitFraction
        return ComponentPicker.MachineFacts(
            physicalBytes: physical,
            budgetBytes: UInt64(wireLimit * SystemMemory.realFraction(
                forSliderPosition: Settings.modelMemoryBudgetSliderPosition)),
            maxBudgetBytes: UInt64(wireLimit * SystemMemory.realFraction(
                forSliderPosition: Settings.modelMemoryBudgetSliderRange.upperBound)),
            wiredBytes: UInt64(wiredGB * 1_000_000_000))
    }

    private static let air8 = mac(gibibytes: 8, wiredGB: 3)
    private static let mac16 = mac(gibibytes: 16, wiredGB: 3)
    private static let mac32 = mac(gibibytes: 32, wiredGB: 4)
    private static let mac64 = mac(gibibytes: 64, wiredGB: 5)

    private static let bare = ComponentPicker.Environment()

    // MARK: - B2 / B3

    private static func checkCoreIsNotAChoice(_ check: SelfTestReporter) {
        let rows = ComponentPicker.rows(selection: .init(), facts: mac64, environment: bare)
        let core = rows.filter(\.id.isCore)
        check.record("the mandatory core is four rows, none of them a checkbox",
                     core.count == 4 && core.allSatisfy { state in
                         if case .optional = state.state { return false }
                         return true
                     }, core.map { "\($0.id.rawValue)=\($0.state.statusText)" }.joined(separator: " "))
        check.record("no core row can be switched off, so none carries a ticked flag",
                     core.allSatisfy { !$0.state.isTicked })
        let python = rows.first { $0.id == .pythonRuntime }
        check.record("the Python row is a disclosure, not an install (B3)",
                     python?.state == .bundled && python?.downloadBytes == nil
                        && python?.countsTowardTotal == false)
        check.record("the Python row says where the runtime lives and that deleting the app removes it",
                     (python?.detail.contains("/usr/local") ?? false)
                        && (python?.detail.contains("log in") ?? false)
                        && (python?.detail.contains("deleting ViddyDictate") ?? false),
                     python?.detail ?? "missing")
        check.record("the three fetched core rows are the ones the engine already owns",
                     rows.filter { $0.id.isCore && $0.countsTowardTotal }.map(\.id)
                        == [.transcriptionEngine, .voiceModel, .webSearch])
    }

    // MARK: - O1

    private static func checkMeasuredSizes(_ check: SelfTestReporter) {
        let sizes = ComponentPicker.SizeCatalog.measured
        // The transcription engine was re-measured on 2026-08-29 when B20's torch cut landed: the
        // with-torch closure was 242_159_990 bytes across 35 wheels, the torch-free one is
        // 121_077_755 across 28. Every other figure is L5's 2026-08-27 measurement, unchanged.
        check.record("the shipped sizes are the measured ones, not the grill's estimates",
                     sizes.transcriptionEngine == 121_077_755 && sizes.voiceModel == 1_613_979_758
                        && sizes.webSearch == 14_028_533 && sizes.gemma == 6_861_935_454
                        && sizes.qwen == 17_190_793_452)
        // The two figures O1 named. gemma's estimate was out by 1.7x, which is the whole reason O1
        // called this a correctness issue rather than a copy issue.
        check.record("the email model is the measured 6.9 GB, not the estimated 4 GB",
                     ComponentPicker.downloadSize(sizes.gemma ?? 0) == "6.9 GB",
                     ComponentPicker.downloadSize(sizes.gemma ?? 0))
        check.record("the cleanup model is the measured 17.2 GB, not the estimated 18 GB",
                     ComponentPicker.downloadSize(sizes.qwen ?? 0) == "17.2 GB",
                     ComponentPicker.downloadSize(sizes.qwen ?? 0))
        check.record("no size is ever presented as zero when it is simply unmeasured",
                     sizes.lmStudio == nil)
        check.record("megabyte-scale rows are quoted in megabytes rather than as 0.1 GB",
                     ComponentPicker.downloadSize(121_077_755) == "121 MB"
                        && ComponentPicker.downloadSize(14_028_533) == "14 MB",
                     ComponentPicker.downloadSize(121_077_755))
        // B20's cut is a user-visible number, so pin the saving itself rather than only the new total.
        check.record("the torch cut took 121 MB off the transcription engine row",
                     242_159_990 - (sizes.transcriptionEngine ?? 0) == 121_082_235,
                     ComponentPicker.downloadSize(242_159_990 - (sizes.transcriptionEngine ?? 0)))
    }

    // MARK: - B6

    private static func checkRunningTotal(_ check: SelfTestReporter) {
        let core = ComponentPicker.rows(selection: .init(), facts: air8, environment: bare)
        let coreTotal = ComponentPicker.total(core)
        check.record("the core total is the sum of the measured core rows, in bytes",
                     coreTotal.bytes == 121_077_755 + 1_613_979_758 + 14_028_533
                        && coreTotal.unmeasured.isEmpty, "\(coreTotal.bytes)")
        check.record("the core total reads 1.7 GB, below both the spec's 2.1 GB estimate and L5's 1.9 GB",
                     ComponentPicker.totalLine(core) == "Total download: 1.7 GB",
                     ComponentPicker.totalLine(core))

        var everything = ComponentPicker.Selection(lmStudio: true, gemma: true, qwen: true)
        let full = ComponentPicker.rows(selection: everything, facts: mac64, environment: bare)
        let fullTotal = ComponentPicker.total(full)
        check.record("ticking every row moves the total by exactly the measured model bytes",
                     fullTotal.bytes == coreTotal.bytes + 6_861_935_454 + 17_190_793_452,
                     "\(fullTotal.bytes)")
        check.record("a row whose size nobody measured is NAMED in the total, never dropped from it",
                     fullTotal.unmeasured == [.lmStudio]
                        && ComponentPicker.totalLine(full) == "Total download: 25.8 GB, plus LM Studio",
                     ComponentPicker.totalLine(full))

        everything.qwen = false
        let withoutQwen = ComponentPicker.rows(selection: everything, facts: mac64, environment: bare)
        check.record("unticking a row takes its bytes back out of the total",
                     ComponentPicker.total(withoutQwen).bytes == fullTotal.bytes - 17_190_793_452)

        let installed = ComponentPicker.Environment(
            lmStudioInstalled: true,
            installedModelIDs: [LLMProviderDefaults.localEmailModelID])
        let detected = ComponentPicker.rows(selection: .init(lmStudio: true, gemma: true),
                                            facts: mac64, environment: installed)
        check.record("what is already on the Mac is not charged to the user again",
                     ComponentPicker.total(detected).bytes == coreTotal.bytes
                        && ComponentPicker.total(detected).unmeasured.isEmpty
                        && detected.first { $0.id == .gemma }?.state == .alreadyInstalled)
        check.record("an installed row does not describe work that will not happen",
                     detected.first { $0.id == .gemma }?.consequence == nil
                        && detected.first { $0.id == .lmStudio }?.consequence == nil
                        && !(detected.first { $0.id == .lmStudio }?.detail
                                .contains("not in the total yet") ?? true))
    }

    // MARK: - B5 / O2

    private static func checkMachineTiers(_ check: SelfTestReporter) {
        // The B5 table keyed to installed RAM would have pre-ticked both of these on a 32 GB Mac and
        // pre-ticked gemma on a 16 GB one. Measured against the budget the loader actually enforces,
        // neither is true; the three tiers and their strings survive, the boundaries move up a class.
        let expected: [(String, ComponentPicker.MachineFacts,
                        ComponentPicker.Availability, ComponentPicker.Availability)] = [
            ("8 GB", air8, .tooLarge, .tooLarge),
            ("16 GB", mac16, .tightFit, .tooLarge),
            ("32 GB", mac32, .fits, .tightFit),
            ("64 GB", mac64, .fits, .fits),
        ]
        for (name, facts, gemma, qwen) in expected {
            let actualGemma = ComponentPicker.availability(.gemma, facts: facts)
            let actualQwen = ComponentPicker.availability(.qwen, facts: facts)
            check.record("a \(name) Mac is offered the measured truth about both models",
                         actualGemma == gemma && actualQwen == qwen,
                         "gemma=\(actualGemma) qwen=\(actualQwen)")
        }

        check.record("only a model that clears the bar as the machine stands is pre-ticked",
                     ComponentPicker.defaultSelection(facts: mac64, environment: bare)
                        == ComponentPicker.Selection(gemma: true, qwen: true)
                        && ComponentPicker.defaultSelection(facts: mac32, environment: bare)
                            == ComponentPicker.Selection(gemma: true)
                        && ComponentPicker.defaultSelection(facts: mac16, environment: bare)
                            == ComponentPicker.Selection()
                        && ComponentPicker.defaultSelection(facts: air8, environment: bare)
                            == ComponentPicker.Selection())

        // The disabled row is the one that must not be reachable. Ticking it in the selection is not
        // enough to turn it on, so no caller and no restored preference can queue a 17 GB download onto
        // a machine that will refuse to load it.
        let forced = ComponentPicker.rows(selection: .init(lmStudio: true, gemma: true, qwen: true),
                                          facts: air8, environment: bare)
        check.record("a row this Mac cannot run stays off even when the selection says otherwise",
                     forced.filter { !$0.id.isCore && $0.id != .lmStudio }
                        .allSatisfy { !$0.state.isTicked && !$0.countsTowardTotal })
        check.record("the disabled row states the machine's own memory, in B5's words",
                     forced.first { $0.id == .qwen }?.machineNote == "Your Mac has 8 GB - this model needs more.",
                     forced.first { $0.id == .qwen }?.machineNote ?? "missing")
        check.record("the squeezed row keeps B5's warning rather than a new one",
                     ComponentPicker.machineNote(.gemma, facts: mac16, environment: bare)
                        == "Will run, but slowly, and will squeeze everything else.")
        check.record("a model that simply fits says nothing, so a warning means something",
                     ComponentPicker.machineNote(.gemma, facts: mac64, environment: bare) == nil)

        // A 16 GB machine sitting at any believable idle load cannot hold the email model. Pinned as a
        // range rather than at one wired figure, so this check is not an artifact of the constant above.
        let knifeEdge = (1...6).allSatisfy {
            ComponentPicker.availability(.gemma, facts: mac(gibibytes: 16, wiredGB: Double($0)))
                == .tightFit
        }
        check.record("the 16 GB verdict does not depend on picking a flattering idle figure", knifeEdge)
    }

    /// The property that makes the picker honest: it must never pre-tick a model the loader would
    /// refuse, and never disable one the loader would accept at some reachable budget.
    private static func checkPickerAgreesWithLoader(_ check: SelfTestReporter) {
        var disagreements: [String] = []
        for gib in [8.0, 16.0, 24.0, 32.0, 36.0, 48.0, 64.0, 96.0] {
            for wired in [1.0, 4.0, 12.0] {
                let facts = mac(gibibytes: gib, wiredGB: wired)
                for id in [ComponentPicker.RowID.gemma, .qwen] {
                    guard let size = ComponentPicker.bytes(for: id),
                          let signed = Int64(exactly: size),
                          let incoming = ModelManager.estimatedIncomingBytes(sizeBytes: signed),
                          let budget = facts.budgetBytes, let maxBudget = facts.maxBudgetBytes,
                          let wiredBytes = facts.wiredBytes else { continue }
                    let loaderWouldLoadNow = ModelManager.fits(
                        wiredBytes: wiredBytes, incomingBytes: incoming, budgetBytes: budget)
                    let everPossible = ModelManager.fits(
                        wiredBytes: 0, incomingBytes: incoming, budgetBytes: maxBudget)
                    let verdict = ComponentPicker.availability(id, facts: facts)
                    if (verdict == .fits) != loaderWouldLoadNow {
                        disagreements.append("\(Int(gib))GB/\(Int(wired))w \(id.rawValue) pre-tick")
                    }
                    if (verdict == .tooLarge) == everPossible {
                        disagreements.append("\(Int(gib))GB/\(Int(wired))w \(id.rawValue) disable")
                    }
                }
            }
        }
        check.record("the picker never pre-ticks a model the loader would refuse, on 48 machines",
                     disagreements.isEmpty, disagreements.joined(separator: ", "))
    }

    private static func checkUnreadableMemory(_ check: SelfTestReporter) {
        let blind = ComponentPicker.MachineFacts(physicalBytes: nil, budgetBytes: nil,
                                                 maxBudgetBytes: nil, wiredBytes: nil)
        check.record("an unreadable kernel ceiling is its own answer, not a verdict about the model",
                     ComponentPicker.availability(.gemma, facts: blind) == .memoryUnknown
                        && ComponentPicker.availability(.qwen, facts: blind) == .memoryUnknown)
        check.record("a machine that could not be measured is never pre-ticked",
                     ComponentPicker.defaultSelection(facts: blind, environment: bare)
                        == ComponentPicker.Selection())
        check.record("the unmeasured machine says macOS did not answer, and offers the row anyway",
                     (ComponentPicker.machineNote(.qwen, facts: blind, environment: bare) ?? "")
                        .contains("macOS did not report")
                        && ComponentPicker.availability(.qwen, facts: blind).isSelectable)
        let partial = ComponentPicker.MachineFacts(physicalBytes: 17_179_869_184,
                                                   budgetBytes: 8_000_000_000,
                                                   maxBudgetBytes: 12_000_000_000, wiredBytes: nil)
        check.record("a missing wired reading fails toward measuring nothing, not toward pre-ticking",
                     ComponentPicker.availability(.gemma, facts: partial) == .memoryUnknown)
    }

    // MARK: - B4

    private static func checkInstallChoice(_ check: SelfTestReporter) {
        let selection = ComponentPicker.Selection(lmStudio: true, gemma: true,
                                                  gemmaChoice: .myself)
        let rows = ComponentPicker.rows(selection: selection, facts: mac64, environment: bare)
        let gemma = rows.first { $0.id == .gemma }
        check.record("both options are offered on every row that involves a third-party install",
                     ComponentPicker.InstallChoice.allCases.map(\.title)
                        == ["Install it for me", "I'll install it myself"])
        check.record("I'll install it myself keeps the row chosen but stops the app fetching it",
                     gemma?.state.isTicked == true && gemma?.countsTowardTotal == false)
        let plan = ComponentPicker.installPlan(selection: selection, facts: mac64, environment: bare)
        check.record("a row the user will install themselves produces no queue entry",
                     plan.models.isEmpty && plan.lmStudio)
    }

    private static func checkPlanHandedOn(_ check: SelfTestReporter) {
        let none = ComponentPicker.installPlan(selection: .init(), facts: air8, environment: bare)
        check.record("the mandatory core is in the plan even when nothing optional was picked",
                     none.components == BootstrapInstallPlan.mandatoryCore
                        && !none.lmStudio && none.models.isEmpty)
        check.record("the plan carries the engine's own descriptors rather than a second package list",
                     none.components.map(\.id) == ["stt-daemon", "web-search"])

        let models = ComponentPicker.installPlan(
            selection: .init(gemma: true, qwen: true), facts: mac64, environment: bare)
        check.record("picking a model implies the runtime that loads it",
                     models.lmStudio
                        && models.models == [LLMProviderDefaults.localEmailModelID,
                                             LLMProviderDefaults.localCleanupModelID])
        check.record("the plan passes lms the identifiers production already routes to",
                     models.models == ["google/gemma-4-e4b", "qwen3-coder-30b-a3b-instruct-mlx"])

        let present = ComponentPicker.installPlan(
            selection: .init(gemma: true), facts: mac64,
            environment: ComponentPicker.Environment(lmStudioInstalled: true))
        check.record("a Mac that already has LM Studio is not made to install it again",
                     !present.lmStudio && present.models == [LLMProviderDefaults.localEmailModelID])

        let forcedRow = ComponentPicker.rows(selection: .init(gemma: true), facts: mac64,
                                             environment: bare).first { $0.id == .lmStudio }
        check.record("the forced runtime row shows as chosen rather than turning on invisibly",
                     forcedRow?.state.isTicked == true)
    }

    // MARK: - Copy

    private static func checkCopy(_ check: SelfTestReporter) {
        let rows = ComponentPicker.rows(selection: .init(lmStudio: true), facts: mac64,
                                        environment: bare)
        check.record("every optional row states what leaving it off costs (B4)",
                     rows.filter { !$0.id.isCore }.allSatisfy { ($0.consequence ?? "").hasPrefix("Without it:") })
        check.record("no core row invents a consequence there is no way to incur",
                     rows.filter(\.id.isCore).allSatisfy { $0.consequence == nil })
        let everyString = rows.flatMap { [$0.title, $0.detail, $0.consequence ?? "", $0.machineNote ?? ""] }
            + [ComponentPicker.headline, ComponentPicker.subtitle, ComponentPicker.coreNote,
               ComponentPicker.optionalNote, ComponentPicker.totalLine(rows)]
        check.record("nothing on the screen is a Setup-failed-class string (O7)",
                     everyString.allSatisfy { !$0.lowercased().contains("please try again")
                        && !$0.lowercased().contains("an error occurred") })
        check.record("no remedy on this surface names a script from a repository the user lacks",
                     everyString.allSatisfy { !$0.contains(".sh") && !$0.contains("repo") })
        check.record("the row that cannot be counted says so where the size would be",
                     rows.first { $0.id == .lmStudio }.map(ComponentPicker.sizeText) == "not counted yet")
        check.record("a row that fetches nothing says so rather than showing a zero",
                     rows.first { $0.id == .pythonRuntime }.map(ComponentPicker.sizeText) == "no download")
        check.record("the network seam's words are reused rather than respelled",
                     NetworkPathCopy.waitForWiFiButton == "Wait for Wi-Fi"
                        && !NetworkPathCopy.waitingForWiFiMessage.isEmpty)
    }
}
