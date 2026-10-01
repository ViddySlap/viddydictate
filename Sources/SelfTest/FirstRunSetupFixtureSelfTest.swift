import Foundation

/// `--first-run-setup-selftest`: the revived first-run setup window (spec D8) as DATA.
///
/// - **(a) The choice.** LM Studio first, the simple and only recommended option; Ollama second, the advanced
///   option, carrying the macOS-prompt warning (Touch ID or password, "Ollama is trying to install its command
///   line interface tool", approve it); Skip for now last. No "both".
/// - **(b) The Ollama plan.** Choosing Ollama swaps the rows to Ollama's (`qwen3-coder:30b`, `gemma4:e4b`) and
///   plans app -> ready -> pulls through S6's descriptors; choosing LM Studio plans exactly what it always did.
/// - **(c) Skip** plans the core alone: no app, no model.
/// - **(d) The fit check** runs on the Ollama rows, with the loader's own 1.15 arithmetic: a 16 GB Mac does not
///   pre-tick qwen3-coder:30b, and cannot be made to queue it.
/// - **(e) The first-launch rule.** A fresh store shows the window; an upgraded store whose core is installed
///   does not, and neither does a 1.1.0 Mac whose working core came from `install-daemon.sh` (its
///   `bootstrap.json` never heard of it). Read from a real `BootstrapStateStore` and a scratch Application
///   Support tree.
/// - **(f) LM Studio unchanged.** On the four fixture Macs the LM-Studio picker says what it said at 11ddc70,
///   checked against `ComponentPickerSelfTest`'s own literal expectations rather than against this slice's code.
///
/// Every machine is synthetic and every store is scratch: nothing reads this Mac's sysctls, Application
/// Support, LM Studio or Ollama, and nothing is installed.
///
/// Negative controls, each of which the gate must catch:
/// (1) Ollama listed first, or recommended;
/// (2) the window shown to an upgraded user with a working install (B12 alone);
/// (3) Ollama rows that skip the fit check.
enum FirstRunSetupFixtureSelfTest {

    // Assertion names the negative controls look up.
    private static let choiceOrderCheck = "LM Studio is first and the only recommended option; Ollama is second"
    private static let upgradeCheck =
        "a 1.1.0 Mac whose core came from install-daemon.sh (bootstrap.json still pending) gets no window"
    private static let completeCheck = "an upgraded store whose core is installed gets no window"
    private static let ollamaFitCheck =
        "a 16 GB Mac is told qwen3-coder:30b is too large, by the loader's own arithmetic"

    static func run() -> Bool {
        print("=== First-run setup fixture selftest (D8 choice, Ollama rows and plan, first-launch rule) ===")
        let reporter = SelfTestReporter()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-setup-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        print("--- (a) the choice ---")
        checkChoice(ComponentPicker.localAppOptions, reporter)
        checkChoiceDefaults(reporter)
        print("--- (b) the Ollama rows and plan; LM Studio's plan ---")
        checkOllamaPlan(reporter)
        checkLMStudioPlan(reporter)
        checkProgressRows(reporter)
        print("--- (c) Skip ---")
        checkSkip(reporter)
        print("--- (d) the fit check on the Ollama rows ---")
        checkOllamaFit({ ComponentPicker.availability($0, facts: $1) }, reporter)
        checkOllamaPreTicks(reporter)
        print("--- (e) the first-launch rule ---")
        checkLaunchRule(FirstRunSetupLaunchRule.shouldPresent, scratch: scratch, reporter)
        checkEnvironmentOnDisk(scratch: scratch, reporter)
        checkEnvironmentFromPresence(reporter)
        print("--- (f) the LM Studio picker is unchanged from 11ddc70 ---")
        checkLMStudioUnchanged(reporter)
        checkNegativeControls(scratch: scratch, reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "first-run setup"))
        print(reporter.passed ? "[first-run-setup-selftest] PASS" : "[first-run-setup-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Synthetic machines (the same ratio ComponentPickerSelfTest synthesizes from)

    private static func mac(gibibytes: Double, wiredGB: Double) -> ComponentPicker.MachineFacts {
        let physical = UInt64(gibibytes * 1_073_741_824)
        let wireLimit = Double(physical) * 0.820
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

    private static let coreIDs: [ComponentPicker.RowID] = [.pythonRuntime, .transcriptionEngine, .voiceModel,
                                                           .webSearch]
    private static let gemmaTag = "gemma4:e4b"
    private static let qwenTag = "qwen3-coder:30b"

    private static func ollamaSelection(_ facts: ComponentPicker.MachineFacts,
                                        _ environment: ComponentPicker.Environment = bare)
        -> ComponentPicker.Selection {
        ComponentPicker.selecting(.ollama,
                                  from: ComponentPicker.defaultSelection(facts: facts, environment: environment),
                                  facts: facts, environment: environment)
    }

    // MARK: - (a)

    private static func checkChoice(_ options: [ComponentPicker.LocalAppOption], _ r: SelfTestReporter) {
        let order = options.map(\.choice)
        let lmStudio = options.first { $0.choice == .lmStudio }
        let ollama = options.first { $0.choice == .ollama }
        r.record(choiceOrderCheck,
                 order == [.lmStudio, .ollama, .skip]
                    && options.filter(\.recommended).map(\.choice) == [.lmStudio],
                 order.map(\.rawValue).joined(separator: ","))
        r.record("the badges are S3c's words: Simple - recommended, then Advanced; Skip has none",
                 lmStudio?.badge == "Simple - recommended" && ollama?.badge == "Advanced"
                    && options.first { $0.choice == .skip }?.badge == nil,
                 options.map { $0.badge ?? "-" }.joined(separator: " | "))
        let warning = ollama?.warning ?? ""
        r.record("the Ollama option warns of Touch ID or a password, quotes the prompt, and says to approve it",
                 warning.contains("Touch ID or your password") && warning.contains("approve it")
                    && warning.contains("Ollama is trying to install its command line interface tool")
                    && warning.contains("never answers it for you"),
                 warning)
        r.record("the warning starts with the point-of-use page's own sentence, so the app says it one way",
                 warning.hasPrefix(OllamaInstaller.adminPromptWarning))
        r.record("only Ollama carries a warning",
                 options.filter { $0.warning != nil }.map(\.choice) == [.ollama])
        r.record("the choice has no 'both' option",
                 !options.contains { $0.title.lowercased().contains("both") }
                    && ComponentPicker.LocalAppChoice.allCases.count == 3)
        r.record("the screen order is the enum's order, so a re-ordered list cannot ship unseen",
                 ComponentPicker.LocalAppChoice.allCases == [.lmStudio, .ollama, .skip])
    }

    private static func checkChoiceDefaults(_ r: SelfTestReporter) {
        let defaults = [air8, mac16, mac32, mac64].map {
            ComponentPicker.defaultSelection(facts: $0, environment: bare).localApp
        }
        r.record("a fresh window opens on LM Studio on every fixture Mac, small ones included",
                 defaults.allSatisfy { $0 == .lmStudio }, defaults.map(\.rawValue).joined(separator: ","))
        let ollamaOnly = ComponentPicker.Environment(ollamaInstallKind: .app)
        r.record("a Mac that already has Ollama and not LM Studio opens on Ollama, not on a second app",
                 ComponentPicker.defaultSelection(facts: mac64, environment: ollamaOnly).localApp == .ollama
                    && ComponentPicker.defaultSelection(
                        facts: mac64, environment: .init(lmStudioInstalled: true, ollamaInstallKind: .app))
                        .localApp == .lmStudio)

        let ollama = ollamaSelection(mac64)
        r.record("a one-line Ollama reminder sits above Continue while Ollama is chosen and still to install",
                 ComponentPicker.continueWarning(selection: ollama, environment: bare)
                    == "Remember to approve Ollama's macOS prompt when it appears."
                    && ComponentPicker.continueWarning(selection: ollama, environment: ollamaOnly) == nil
                    && ComponentPicker.continueWarning(
                        selection: ComponentPicker.defaultSelection(facts: mac64, environment: bare),
                        environment: bare) == nil)
    }

    // MARK: - (b)

    private static func describe(_ step: InstallerLocalStep) -> String {
        switch step {
        case .app(let backend): return "app(\(backend.rawValue))"
        case .ready(let backend): return "ready(\(backend.rawValue))"
        case .model(let ref): return "model(\(ref.backend.rawValue):\(ref.modelID))"
        }
    }

    private static func checkOllamaPlan(_ r: SelfTestReporter) {
        let selection = ollamaSelection(mac64)
        let rows = ComponentPicker.rows(selection: selection, facts: mac64, environment: bare)
        r.record("choosing Ollama shows the core and Ollama's three rows, and no LM Studio row",
                 rows.map(\.id) == coreIDs + [.ollama, .ollamaGemma, .ollamaQwen],
                 rows.map(\.id.rawValue).joined(separator: ","))
        r.record("the Ollama model rows are D4's two families, by tag",
                 ComponentPicker.RowID.ollamaGemma.localModel == LocalModelRef(backend: .ollama, modelID: gemmaTag)
                    && ComponentPicker.RowID.ollamaQwen.localModel
                        == LocalModelRef(backend: .ollama, modelID: qwenTag)
                    && rows.first { $0.id == .ollamaGemma }?.detail.hasPrefix(gemmaTag) == true
                    && rows.first { $0.id == .ollamaQwen }?.detail.hasPrefix(qwenTag) == true)
        r.record("the Ollama rows keep the picker's existing words (no new pick label)",
                 ComponentPicker.title(.ollamaGemma) == "Email model"
                    && ComponentPicker.title(.ollamaQwen) == "Cleanup model"
                    && rows.allSatisfy { !$0.detail.contains("ratified") && !$0.detail.contains("Staff pick") })
        r.record("ticking an Ollama model turns Ollama itself on, and says why",
                 rows.first { $0.id == .ollama }?.state.isTicked == true
                    && rows.first { $0.id == .ollama }?.machineNote == "Required by the models you picked.")

        let plan = ComponentPicker.installPlan(selection: selection, facts: mac64, environment: bare)
        r.record("the Ollama plan names Ollama and both tags, and nothing of LM Studio's",
                 plan.ollama && plan.ollamaModels == [gemmaTag, qwenTag] && !plan.lmStudio && plan.models.isEmpty,
                 "ollama=\(plan.ollama) models=\(plan.ollamaModels)")
        let steps = plan.localComponents.flatMap(\.localSteps)
        let gemmaRef = LocalModelRef(backend: .ollama, modelID: gemmaTag)
        let qwenRef = LocalModelRef(backend: .ollama, modelID: qwenTag)
        r.record("the queue runs Ollama app -> ready -> pulls, through S6's own descriptors",
                 steps == [.app(.ollama), .ready(.ollama), .ready(.ollama), .model(gemmaRef),
                           .ready(.ollama), .model(qwenRef)],
                 steps.map(describe).joined(separator: " -> "))
        r.record("the queue is the core, then Ollama's rows, by their durable ids",
                 plan.queue.map(\.id) == ["stt-daemon", "web-search", "ollama", "ollama-model:gemma4:e4b",
                                          "ollama-model:qwen3-coder:30b"],
                 plan.queue.map(\.id).joined(separator: ","))
        let tracked = Set(BootstrapInstallPlan.allComponents.map(\.id))
        r.record("every queued row is one bootstrap.json tracks, so its progress is recorded",
                 plan.queue.allSatisfy { tracked.contains($0.id) })
        r.record("the queued app row is the one the Preferred local app follows (it carries .app(.ollama))",
                 plan.queue.contains { $0.localSteps.contains(.app(.ollama)) })

        // Ollama already installed with gemma pulled: only the missing model is queued, and no app.
        let has = ComponentPicker.Environment(ollamaInstallKind: .app, ollamaModelIDs: ["gemma4:e4b"])
        let partial = ComponentPicker.installPlan(selection: ollamaSelection(mac64, has), facts: mac64,
                                                  environment: has)
        r.record("an installed Ollama and an already-pulled model are not fetched again",
                 !partial.ollama && partial.ollamaModels == [qwenTag]
                    && partial.localComponents.map(\.id) == ["ollama-model:qwen3-coder:30b"],
                 partial.localComponents.map(\.id).joined(separator: ","))
        r.record("a model is matched in Ollama only, never by an LM Studio id",
                 !ComponentPicker.isInstalled(.ollamaGemma, environment: .init(
                    lmStudioInstalled: true, installedModelIDs: ["gemma4:e4b"], ollamaInstallKind: .app))
                    && !ComponentPicker.isInstalled(.gemma, environment: .init(
                        ollamaInstallKind: .app, ollamaModelIDs: ["google/gemma-4-e4b"])))
        let cli = ComponentPicker.Environment(ollamaInstallKind: .cli)
        r.record("a command-line Ollama is installed, and its row says ViddyDictate will not start it",
                 ComponentPicker.isInstalled(.ollama, environment: cli)
                    && (ComponentPicker.machineNote(.ollama, facts: mac64, environment: cli,
                                                    selection: ollamaSelection(mac64, cli)) ?? "")
                        .contains("ollama serve"))
    }

    private static func checkLMStudioPlan(_ r: SelfTestReporter) {
        let plan = ComponentPicker.installPlan(
            selection: ComponentPicker.defaultSelection(facts: mac64, environment: bare),
            facts: mac64, environment: bare)
        r.record("choosing LM Studio plans exactly what 1.1.0 planned: LM Studio and its two model keys",
                 plan == ComponentPicker.InstallPlan(
                    components: BootstrapInstallPlan.mandatoryCore, lmStudio: true,
                    models: ["google/gemma-4-e4b", "qwen3-coder-30b-a3b-instruct-mlx"]))
        r.record("and queues the 1.1.0 descriptors, by their 1.1.0 ids",
                 plan.queue.map(\.id) == ["stt-daemon", "web-search", "lm-studio", "model:google/gemma-4-e4b",
                                          "model:qwen3-coder-30b-a3b-instruct-mlx"],
                 plan.queue.map(\.id).joined(separator: ","))
        r.record("with LM Studio's app -> lms-ready -> model order",
                 plan.localComponents.flatMap(\.localSteps).first == .app(.lmStudio)
                    && plan.localComponents.flatMap(\.localSteps).filter { $0 == .ready(.lmStudio) }.count == 3)
    }

    /// The launch-time progress list the window turns into after Continue, fed an Ollama queue.
    private static func checkProgressRows(_ r: SelfTestReporter) {
        let plan = ComponentPicker.installPlan(selection: ollamaSelection(mac64), facts: mac64, environment: bare)
        var state = InstallProgressState(plan: plan)
        r.record("the progress list carries the Ollama rows the plan queued, in order",
                 state.order == [.pythonRuntime, .transcriptionEngine, .voiceModel, .webSearch, .ollama,
                                 .ollamaGemma, .ollamaQwen],
                 state.order.map(\.rawValue).joined(separator: ","))
        r.record("Ollama's own size is named in the total, not counted as zero",
                 state.aggregate.unmeasured == [.ollama]
                    && InstallProgress.totalLine(state.aggregate).hasSuffix("plus Ollama"),
                 InstallProgress.totalLine(state.aggregate))

        var snapshot = BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents)
        func set(_ id: String, _ phase: BootstrapComponentPhase) {
            snapshot.components = snapshot.components.map { record in
                var record = record
                if record.id == id { record.phase = phase }
                return record
            }
        }
        struct NoBytes: InstallByteSampling { func bytes(at source: InstallProgress.ByteSource) -> UInt64 { 0 } }
        set("stt-daemon", .installed)
        set("web-search", .installed)
        set("ollama", .installing)
        state.apply(snapshot: snapshot, sampler: NoBytes(), at: 0,
                    activity: { $0 == "ollama" ? .awaitingApproval(.ollama) : nil })
        let app = state.rows.first { $0.id == .ollama }
        r.record("the Ollama app row follows the queue and shows the approval wait in its own words",
                 app?.phase == .running && app.map(InstallProgress.statusText)
                    == "waiting for you to approve Ollama's macOS prompt",
                 app.map(InstallProgress.statusText) ?? "missing")

        set("ollama", .installed)
        set("ollama-model:gemma4:e4b", .installing)
        let pulled: UInt64 = 1_300_000_000
        state.apply(snapshot: snapshot, sampler: NoBytes(), at: 1, activity: { id in
            id == "ollama-model:gemma4:e4b"
                ? .bytes(InstallerByteProgress(completed: pulled, expected: nil)) : nil
        })
        let gemma = state.rows.first { $0.id == .ollamaGemma }
        r.record("a pull shows its real bytes against the measured size",
                 gemma.map(InstallProgress.statusText) == "1.3 GB of 6.6 GB"
                    && state.rows.first { $0.id == .ollama }?.phase == .done,
                 gemma.map(InstallProgress.statusText) ?? "missing")
        let qwen = state.rows.first { $0.id == .ollamaQwen }
        r.record("a model still queued reads waiting", qwen?.phase == .waiting)
    }

    // MARK: - (c)

    private static func checkSkip(_ r: SelfTestReporter) {
        let skip = ComponentPicker.selecting(.skip, from: ComponentPicker.defaultSelection(facts: mac64,
                                                                                          environment: bare),
                                             facts: mac64, environment: bare)
        let rows = ComponentPicker.rows(selection: skip, facts: mac64, environment: bare)
        r.record("Skip shows the core and no local row", rows.map(\.id) == coreIDs,
                 rows.map(\.id.rawValue).joined(separator: ","))
        let plan = ComponentPicker.installPlan(selection: skip, facts: mac64, environment: bare)
        r.record("Skip installs no app and no model: the plan is the core alone",
                 plan.localComponents.isEmpty && !plan.lmStudio && !plan.ollama && plan.models.isEmpty
                    && plan.ollamaModels.isEmpty && plan.queue.map(\.id) == ["stt-daemon", "web-search"])
        // Even with every model of both apps ticked underneath it.
        var everything = skip
        for id in ComponentPicker.RowID.allCases where !id.isCore { everything.setTicked(id, true) }
        let forced = ComponentPicker.installPlan(selection: everything, facts: mac64, environment: bare)
        r.record("Skip stays empty even when the ticks underneath it say otherwise",
                 forced.localComponents.isEmpty, forced.localComponents.map(\.id).joined(separator: ","))
        r.record("Skip's total is the core's",
                 ComponentPicker.totalLine(rows) == "Total download: 1.7 GB", ComponentPicker.totalLine(rows))
        r.record("Skip raises no warning", ComponentPicker.continueWarning(selection: skip, environment: bare) == nil)
    }

    // MARK: - (d)

    /// Run against the picker's verdict function, so negative control (3) can hand it one that skips the check.
    private static func checkOllamaFit(
        _ availability: (ComponentPicker.RowID, ComponentPicker.MachineFacts) -> ComponentPicker.Availability,
        _ r: SelfTestReporter) {
        r.record(ollamaFitCheck, availability(.ollamaQwen, mac16) == .tooLarge,
                 "\(availability(.ollamaQwen, mac16))")
        // The same sweep ComponentPickerSelfTest runs for LM Studio: the verdict is the loader's, on 48 machines.
        var disagreements: [String] = []
        for gib in [8.0, 16.0, 24.0, 32.0, 36.0, 48.0, 64.0, 96.0] {
            for wired in [1.0, 4.0, 12.0] {
                let facts = mac(gibibytes: gib, wiredGB: wired)
                for id in [ComponentPicker.RowID.ollamaGemma, .ollamaQwen] {
                    guard let size = ComponentPicker.bytes(for: id), let signed = Int64(exactly: size),
                          let incoming = ModelManager.estimatedIncomingBytes(sizeBytes: signed),
                          let budget = facts.budgetBytes, let maxBudget = facts.maxBudgetBytes,
                          let wiredBytes = facts.wiredBytes else {
                        disagreements.append("\(id.rawValue) unsized")
                        continue
                    }
                    let now = ModelManager.fits(wiredBytes: wiredBytes, incomingBytes: incoming, budgetBytes: budget)
                    let ever = ModelManager.fits(wiredBytes: 0, incomingBytes: incoming, budgetBytes: maxBudget)
                    let verdict = availability(id, facts)
                    if (verdict == .fits) != now { disagreements.append("\(Int(gib))GB/\(Int(wired))w \(id.rawValue)") }
                    if (verdict == .tooLarge) == ever {
                        disagreements.append("\(Int(gib))GB/\(Int(wired))w \(id.rawValue) disable")
                    }
                }
            }
        }
        r.record("the Ollama rows never pre-tick a model the loader would refuse, on 48 machines",
                 disagreements.isEmpty, disagreements.prefix(4).joined(separator: ", "))
    }

    private static func checkOllamaPreTicks(_ r: SelfTestReporter) {
        r.record("the 1.15 factor is the loader's own, unchanged",
                 ModelManager.estimatedIncomingBytes(sizeBytes: 1_000_000_000) == 1_150_000_000)
        r.record("gemma4:e4b is sized from its measured /api/tags bytes",
                 ComponentPicker.bytes(for: .ollamaGemma) == 6_583_656_505
                    && BootstrapInstallPlan.ollamaGemma.downloadBytes == 6_583_656_505)
        r.record("qwen3-coder:30b carries the one flagged library figure until the Mac measures it",
                 ComponentPicker.bytes(for: .ollamaQwen) == ComponentPicker.ollamaQwenMeasuredBytes
                    && BootstrapInstallPlan.ollamaQwen.downloadBytes.map(UInt64.init) == ComponentPicker.bytes(for: .ollamaQwen))

        let small = ollamaSelection(mac16)
        let rows = ComponentPicker.rows(selection: small, facts: mac16, environment: bare)
        func word(_ id: ComponentPicker.RowID) -> String { rows.first { $0.id == id }?.state.statusText ?? "missing" }
        r.record("a 16 GB Mac does not pre-tick qwen3-coder:30b (or gemma4:e4b, which only squeezes in)",
                 !small.isTicked(.ollamaQwen) && !small.isTicked(.ollamaGemma)
                    && word(.ollamaQwen) == "TOO BIG" && word(.ollamaGemma) == "OPTIONAL",
                 "qwen=\(word(.ollamaQwen)) gemma=\(word(.ollamaGemma))")
        r.record("the too-large row states this Mac's memory in B5's words",
                 rows.first { $0.id == .ollamaQwen }?.machineNote == "Your Mac has 16 GB - this model needs more.")
        var forced = small
        forced.setTicked(.ollamaQwen, true)
        let plan = ComponentPicker.installPlan(selection: forced, facts: mac16, environment: bare)
        r.record("ticking it anyway cannot queue a pull the loader would refuse",
                 !plan.ollamaModels.contains(qwenTag), plan.ollamaModels.joined(separator: ","))

        let big = ollamaSelection(mac64)
        r.record("a 64 GB Mac pre-ticks both Ollama models",
                 big.isTicked(.ollamaGemma) && big.isTicked(.ollamaQwen))
        let mid = ollamaSelection(mac32)
        r.record("a 32 GB Mac pre-ticks gemma4:e4b and offers qwen3-coder:30b unticked",
                 mid.isTicked(.ollamaGemma) && !mid.isTicked(.ollamaQwen)
                    && ComponentPicker.availability(.ollamaQwen, facts: mac32) == .tightFit)
    }

    // MARK: - (e)

    private static func store(at url: URL, json: String?) -> BootstrapStateStore {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let json { try? Data(json.utf8).write(to: url) }
        return BootstrapStateStore(url: url, writer: { _, _ in })
    }

    /// A `bootstrap.json` shaped the way 1.1.0 writes one: every row pending, nothing attempted.
    private static func legacyJSON(sttPhase: String = "pending", attempts: Int = 0) -> String {
        """
        {"components":[{"attempts":\(attempts),"id":"stt-daemon","phase":"\(sttPhase)","title":"Transcription engine"},\
        {"attempts":0,"id":"web-search","phase":"pending","title":"Web search"},\
        {"attempts":0,"id":"lm-studio","phase":"pending","title":"LM Studio"}],\
        "lifecycle":"idle","mandatoryComponentIDs":["stt-daemon","web-search"],"version":1}
        """
    }

    private static let completeJSON = """
        {"components":[{"attempts":1,"id":"stt-daemon","phase":"installed","title":"Transcription engine"},\
        {"attempts":1,"id":"web-search","phase":"installed","title":"Web search"}],\
        "lifecycle":"complete","mandatoryComponentIDs":["stt-daemon","web-search"],"version":1}
        """

    /// Lays down an earlier install's transcription environment: the interpreter, and optionally mlx_whisper.
    @discardableResult
    private static func earlierEnvironment(in support: URL, withPackage: Bool) -> Bool {
        let fm = FileManager.default
        let venv = support.appendingPathComponent("stt-venv", isDirectory: true)
        let bin = venv.appendingPathComponent("bin", isDirectory: true)
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let python = bin.appendingPathComponent("python")
            try Data("#!/bin/sh\n".utf8).write(to: python)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            if withPackage {
                try fm.createDirectory(
                    at: venv.appendingPathComponent("lib/python3.12/site-packages/mlx_whisper", isDirectory: true),
                    withIntermediateDirectories: true)
            }
            return true
        } catch {
            return false
        }
    }

    private static func checkLaunchRule(_ rule: (FirstRunSetupLaunchRule.Facts) -> Bool, scratch: URL,
                                        _ r: SelfTestReporter) {
        let base = scratch.appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
        func facts(_ name: String, json: String?, environment: Bool?) -> FirstRunSetupLaunchRule.Facts {
            let support = base.appendingPathComponent(name, isDirectory: true)
            if let environment { earlierEnvironment(in: support, withPackage: environment) }
            let snapshot = store(at: support.appendingPathComponent("bootstrap.json"), json: json).snapshot()
            return FirstRunSetupLaunchRule.Facts(
                snapshot: snapshot,
                earlierCoreOnDisk: FirstRunSetupLaunchRule.coreEnvironmentOnDisk(applicationSupport: support))
        }

        r.record("a fresh store (no bootstrap.json, nothing on disk) shows the window",
                 rule(facts("fresh", json: nil, environment: nil)))
        r.record(completeCheck, !rule(facts("complete", json: completeJSON, environment: nil)))
        r.record(upgradeCheck, !rule(facts("legacy", json: legacyJSON(), environment: true)))
        r.record("a 1.1.0 Mac with no bootstrap.json at all but a working core gets no window either",
                 !rule(facts("legacy-nofile", json: nil, environment: true)))
        r.record("a 1.1.0 Mac that never got a working core (DMG only) is shown the window",
                 rule(facts("legacy-dmg", json: legacyJSON(), environment: nil)))
        r.record("a venv that was only begun (no mlx_whisper) is not a working core",
                 rule(facts("begun", json: legacyJSON(), environment: false)))
        r.record("once the queue has worked on the core, its own record decides, not a half-built venv",
                 rule(facts("failed", json: legacyJSON(sttPhase: "failed", attempts: 3), environment: true)))
        r.record("B12 holds: dismissing (or Set up later) is not an opt-out while the core is missing",
                 rule(FirstRunSetupLaunchRule.Facts(
                    snapshot: BootstrapSnapshot(lifecycle: .degraded, components:
                        BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents).components),
                    earlierCoreOnDisk: false)))
    }

    private static func checkEnvironmentOnDisk(scratch: URL, _ r: SelfTestReporter) {
        let support = scratch.appendingPathComponent("disk-\(UUID().uuidString)", isDirectory: true)
        r.record("no environment reads as none",
                 !FirstRunSetupLaunchRule.coreEnvironmentOnDisk(applicationSupport: support))
        earlierEnvironment(in: support, withPackage: false)
        r.record("an interpreter alone reads as none",
                 !FirstRunSetupLaunchRule.coreEnvironmentOnDisk(applicationSupport: support))
        earlierEnvironment(in: support, withPackage: true)
        r.record("the interpreter plus mlx_whisper reads as an earlier install's core",
                 FirstRunSetupLaunchRule.coreEnvironmentOnDisk(applicationSupport: support))
        r.record("the folder is the engine's own (install-daemon.sh uses the same stt-venv)",
                 BootstrapInstallPlan.sttDaemon.virtualEnvironmentRelativePath == "stt-venv")
    }

    private static func checkEnvironmentFromPresence(_ r: SelfTestReporter) {
        typealias Reading = LLMProviderDetection.LocalBackendReading
        func presence(_ readings: [Reading]) -> LLMProviderDetection.Presence {
            LLMProviderDetection.mergedLocalPresence(readings)
        }
        let neither = presence([Reading(backend: .lmStudio, installed: false, responding: false, models: nil),
                                Reading(backend: .ollama, installed: false, responding: false, models: nil)])
        r.record("a Mac with neither app reads as bare", ComponentPicker.Environment(localPresence: neither) == bare)
        r.record("an unmeasured Mac reads as bare", ComponentPicker.Environment(localPresence: nil) == bare)

        let both = presence([
            Reading(backend: .lmStudio, installed: true, responding: true,
                    models: [LMStudioModelOption(modelID: "google/gemma-4-e4b", label: "g")]),
            Reading(backend: .ollama, installed: true, responding: true,
                    models: [LMStudioModelOption(modelID: "gemma4:e4b", label: "g", backend: .ollama)],
                    startable: true),
        ])
        let environment = ComponentPicker.Environment(localPresence: both)
        r.record("each app's models are read from its own reading",
                 environment.lmStudioInstalled && environment.installedModelIDs == ["google/gemma-4-e4b"]
                    && environment.ollamaInstallKind == .app && environment.ollamaModelIDs == ["gemma4:e4b"])
        let cli = presence([Reading(backend: .lmStudio, installed: false, responding: false, models: nil),
                            Reading(backend: .ollama, installed: true, responding: false, models: nil)])
        r.record("an Ollama with no app to open is the command-line install",
                 ComponentPicker.Environment(localPresence: cli).ollamaInstallKind == .cli)
        let handBuilt = LLMProviderDetection.Presence(
            installed: true, state: .available,
            availableLocalModels: [LMStudioModelOption(modelID: "qwen3-coder-30b-a3b-instruct-mlx", label: "q")])
        let legacy = ComponentPicker.Environment(localPresence: handBuilt)
        r.record("a presence with no per-app breakdown keeps 1.1.0's LM Studio reading",
                 legacy.lmStudioInstalled && legacy.installedModelIDs == ["qwen3-coder-30b-a3b-instruct-mlx"]
                    && !legacy.ollamaInstalled)
        r.record("the 1.1.0 initializer still builds an LM Studio-only environment",
                 ComponentPicker.Environment(lmStudioInstalled: true, installedModelIDs: ["x"]).ollamaInstallKind == nil)
    }

    // MARK: - (f)

    /// Literals from `ComponentPickerSelfTest` and `ComponentPickerRender` at 11ddc70.
    private static func checkLMStudioUnchanged(_ r: SelfTestReporter) {
        let ids = ComponentPicker.rows(selection: .init(), facts: mac64, environment: bare).map(\.id.rawValue)
        r.record("an LM Studio selection shows 1.1.0's seven rows in 1.1.0's order",
                 ids == ["pythonRuntime", "transcriptionEngine", "voiceModel", "webSearch", "lmStudio", "gemma",
                         "qwen"], ids.joined(separator: ","))
        r.record("the default ticks are 11ddc70's on all four fixture Macs",
                 ComponentPicker.defaultSelection(facts: mac64, environment: bare)
                    == ComponentPicker.Selection(gemma: true, qwen: true)
                    && ComponentPicker.defaultSelection(facts: mac32, environment: bare)
                        == ComponentPicker.Selection(gemma: true)
                    && ComponentPicker.defaultSelection(facts: mac16, environment: bare) == ComponentPicker.Selection()
                    && ComponentPicker.defaultSelection(facts: air8, environment: bare) == ComponentPicker.Selection())
        let verdicts: [(ComponentPicker.MachineFacts, ComponentPicker.Availability, ComponentPicker.Availability,
                        String, String)] = [
            (air8, .tooLarge, .tooLarge, "TOO BIG", "TOO BIG"),
            (mac16, .tightFit, .tooLarge, "OPTIONAL", "TOO BIG"),
            (mac32, .fits, .tightFit, "SELECTED", "OPTIONAL"),
            (mac64, .fits, .fits, "SELECTED", "SELECTED"),
        ]
        var wrong: [String] = []
        for (facts, gemma, qwen, gemmaWord, qwenWord) in verdicts {
            let rows = ComponentPicker.rows(selection: ComponentPicker.defaultSelection(facts: facts, environment: bare),
                                            facts: facts, environment: bare)
            let words = (rows.first { $0.id == .gemma }?.state.statusText, rows.first { $0.id == .qwen }?.state.statusText)
            if ComponentPicker.availability(.gemma, facts: facts) != gemma
                || ComponentPicker.availability(.qwen, facts: facts) != qwen
                || words.0 != gemmaWord || words.1 != qwenWord {
                wrong.append("\(facts.physicalBytes ?? 0)")
            }
        }
        r.record("the verdicts and state words are 11ddc70's on all four fixture Macs", wrong.isEmpty,
                 wrong.joined(separator: ","))
        let core = ComponentPicker.rows(selection: .init(), facts: air8, environment: bare)
        let full = ComponentPicker.rows(selection: .init(lmStudio: true, gemma: true, qwen: true),
                                        facts: mac64, environment: bare)
        r.record("the totals are 11ddc70's",
                 ComponentPicker.totalLine(core) == "Total download: 1.7 GB"
                    && ComponentPicker.totalLine(full) == "Total download: 25.8 GB, plus LM Studio",
                 ComponentPicker.totalLine(full))
        let detected = ComponentPicker.Environment(lmStudioInstalled: true,
                                                   installedModelIDs: ["google/gemma-4-e4b"])
        r.record("the already-installed Mac's total is 11ddc70's",
                 ComponentPicker.totalLine(ComponentPicker.rows(
                    selection: ComponentPicker.defaultSelection(facts: mac64, environment: detected),
                    facts: mac64, environment: detected)) == "Total download: 18.9 GB")
        let myself = ComponentPicker.installPlan(selection: .init(lmStudio: true, gemma: true, gemmaChoice: .myself),
                                                 facts: mac64, environment: bare)
        r.record("I'll install it myself still queues nothing for that row", myself.models.isEmpty && myself.lmStudio)
        r.record("the LM Studio rows' words are 11ddc70's",
                 ComponentPicker.title(.lmStudio) == "LM Studio" && ComponentPicker.title(.gemma) == "Email model"
                    && ComponentPicker.title(.qwen) == "Cleanup model"
                    && ComponentPicker.machineNote(.gemma, facts: mac16, environment: bare)
                        == "Will run, but slowly, and will squeeze everything else."
                    && full.filter { !$0.id.isCore }.allSatisfy { ($0.consequence ?? "").hasPrefix("Without it:") })
        r.record("the shipped LM Studio sizes are 11ddc70's",
                 ComponentPicker.SizeCatalog.measured.gemma == 6_861_935_454
                    && ComponentPicker.SizeCatalog.measured.qwen == 17_190_793_452
                    && ComponentPicker.SizeCatalog.measured.lmStudio == nil)
        r.record("routing's conservative sizes still know only LM Studio's ids",
                 ComponentPicker.RowID.allCases.compactMap(\.modelID)
                    == ["google/gemma-4-e4b", "qwen3-coder-30b-a3b-instruct-mlx"])
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(scratch: URL, _ r: SelfTestReporter) {
        let real = ComponentPicker.localAppOptions
        requireCaught(r, mutant: "choice with Ollama listed first", by: choiceOrderCheck) {
            checkChoice([real[1], real[0], real[2]], $0)
        }
        requireCaught(r, mutant: "choice with Ollama recommended", by: choiceOrderCheck) {
            let ollama = real[1]
            checkChoice([real[0],
                         ComponentPicker.LocalAppOption(choice: ollama.choice, title: ollama.title, badge: ollama.badge,
                                                        recommended: true, detail: ollama.detail,
                                                        warning: ollama.warning),
                         real[2]], $0)
        }
        requireCaught(r, mutant: "launch rule that is B12 alone (shows an upgraded working install)",
                      by: upgradeCheck) {
            checkLaunchRule({ $0.snapshot.shouldPresentSetupOnLaunch }, scratch: scratch, $0)
        }
        requireCaught(r, mutant: "launch rule that always shows the window", by: completeCheck) {
            checkLaunchRule({ _ in true }, scratch: scratch, $0)
        }
        requireCaught(r, mutant: "fit check keyed on LM Studio's model id (Ollama rows waved through)",
                      by: ollamaFitCheck) {
            checkOllamaFit({ id, facts in
                id.modelID == nil ? .fits : ComponentPicker.availability(id, facts: facts)
            }, $0)
        }
    }

    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
