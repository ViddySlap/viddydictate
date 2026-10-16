import Foundation

/// Deterministic, scratch-only coverage for the installer's Voice models choice (selectable Whisper
/// versions, part 3 of 3). The model is pure (no AppKit), every installed probe is injected, and the
/// choice-write rule is driven through the real `InstallerEngine` with a scripted process runner and
/// an injected select effect, so this touches no daemon, launchd, network, real preference file, or
/// window.
///
/// Row names use the prefixes `whisper-adv: new:` (the behaviour this change adds and which must
/// fail by assertion on the pre-repair scaffold) and `whisper-adv: guard:` (what must already pass
/// and keep passing).
enum WhisperAdvancedSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate installer Voice models choice - selftest ===")
        let reporter = SelfTestReporter()
        checkDefaultState(reporter)
        checkTicking(reporter)
        checkEngineChoice(reporter)
        checkGuards(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "whisper advanced"))
        print(reporter.passed ? "\nWHISPER ADVANCED GREEN" : "\nWHISPER ADVANCED FAILED")
        return reporter.passed
    }

    private static let turbo = WhisperModelCatalog.default.repo
    private static let largeV3 = "mlx-community/whisper-large-v3-mlx"
    private static let largeV2 = "mlx-community/whisper-large-v2-mlx"
    private static let large = "mlx-community/whisper-large-mlx"

    /// Any valid MachineFacts works: the whisper model never consults RAM. Same helper shape as
    /// ComponentPickerSelfTest, kept minimal.
    private static func facts() -> ComponentPicker.MachineFacts {
        let physical = UInt64(64 * 1_073_741_824)
        let limit = Double(physical) * 0.820
        return ComponentPicker.MachineFacts(
            physicalBytes: physical,
            budgetBytes: UInt64(limit * 0.6),
            maxBudgetBytes: UInt64(limit * 1.0),
            wiredBytes: UInt64(5 * 1_000_000_000))
    }

    private static func source(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - default state and plan equality

    private static func checkDefaultState(_ reporter: SelfTestReporter) {
        print("--- default state ---")
        let defaultState = WhisperVoiceModels.State.defaultState
        reporter.record(
            "whisper-adv: guard: the default state ticks and activates only Large V3 Turbo",
            defaultState.ticked == Set([turbo]) && defaultState.active == turbo,
            "ticked=\(defaultState.ticked.sorted()) active=\(defaultState.active)")

        let plan = ComponentPicker.installPlan(
            selection: ComponentPicker.Selection(), facts: facts(),
            environment: ComponentPicker.Environment(), installed: { _ in false })
        let queueEquals = plan.queue == BootstrapInstallPlan.mandatoryCore
        reporter.record(
            "whisper-adv: guard: with only Turbo ticked the plan equals today's plan exactly",
            plan.whisperModels.isEmpty
                && plan.components == BootstrapInstallPlan.mandatoryCore
                && queueEquals,
            "whisperModels=\(plan.whisperModels.count) queueEqual=\(queueEquals)")

        let rows = ComponentPicker.rows(selection: .init(), facts: facts(),
                                        environment: .init())
        let extra = ComponentPicker.voiceModelExtraBytes(selection: .init(), installed: { _ in false })
        let combined = ComponentPicker.totalLine(rows, voiceExtraBytes: extra)
        let single = ComponentPicker.totalLine(rows)
        reporter.record(
            "whisper-adv: guard: with only Turbo ticked the total equals today's total",
            extra == 0 && combined == single,
            "extra=\(extra) combined=\(combined) single=\(single)")
    }

    // MARK: - tick arithmetic and descriptors

    private static func checkTicking(_ reporter: SelfTestReporter) {
        print("--- tick arithmetic ---")
        var ticked = WhisperVoiceModels.State.defaultState
        _ = ticked.setTicked(largeV3, true)
        let descriptors = WhisperVoiceModels.descriptors(state: ticked, installed: { _ in false })
        let tickedPlan = ComponentPicker.installPlan(
            selection: ComponentPicker.Selection(whisper: ticked), facts: facts(),
            environment: .init(), installed: { _ in false })
        reporter.record(
            "whisper-adv: guard: ticking Large V3 adds exactly its catalog bytes and one descriptor",
            WhisperVoiceModels.extraDownloadBytes(state: ticked, installed: { _ in false })
                == 3_080_000_000
                && descriptors.count == 1
                && descriptors.first?.id == "whisper-model:large-v3"
                && descriptors.first?.modelArtifacts
                    == [InstallerModelArtifact(repository: "mlx-community/whisper-large-v3-mlx")]
                && descriptors.first?.virtualEnvironmentRelativePath == "stt-venv"
                && tickedPlan.whisperModels.map(\.id) == ["whisper-model:large-v3"],
            "bytes=\(WhisperVoiceModels.extraDownloadBytes(state: ticked, installed: { _ in false })) ids=\(descriptors.map(\.id)) planIds=\(tickedPlan.whisperModels.map(\.id))")

        reporter.record(
            "whisper-adv: guard: an already-installed ticked variant adds zero bytes",
            WhisperVoiceModels.extraDownloadBytes(state: ticked, installed: { $0 == largeV3 }) == 0
                && WhisperVoiceModels.descriptors(state: ticked, installed: { $0 == largeV3 }).isEmpty)

        let installedActive = WhisperVoiceModels.State(ticked: [turbo, largeV3], active: largeV3)
        let installedDescriptors = WhisperVoiceModels.descriptors(
            state: installedActive, installed: { $0 == largeV3 })
        let emptyChoice = installedDescriptors.first { $0.id == "whisper-model:large-v3" }
        reporter.record(
            "whisper-adv: new: an already-installed active non-default repo still yields a choice-write descriptor with no download work",
            installedDescriptors.count == 1
                && emptyChoice?.writeWhisperChoiceOnSuccess == largeV3
                && emptyChoice?.virtualEnvironmentRelativePath == nil
                && emptyChoice?.packages.isEmpty == true
                && emptyChoice?.modelArtifacts.isEmpty == true
                && emptyChoice?.localSteps.isEmpty == true
                && emptyChoice?.downloadBytes == 0,
            "count=\(installedDescriptors.count) desc=\(emptyChoice.map { "venv=\(String(describing: $0.virtualEnvironmentRelativePath)) packages=\($0.packages.count) artifacts=\($0.modelArtifacts.count) steps=\($0.localSteps.count) bytes=\(String(describing: $0.downloadBytes)) choice=\(String(describing: $0.writeWhisperChoiceOnSuccess))" } ?? "nil")")

        let pickerSource = source("Sources/App/ComponentPicker.swift")
        reporter.record(
            "whisper-adv: new: the install plan keeps whisperModels as the one voice source and drops whisperActiveRepo",
            pickerSource.contains("whisperModels") && !pickerSource.contains("whisperActiveRepo"),
            "hasWhisperModels=\(pickerSource.contains("whisperModels")) hasWhisperActiveRepo=\(pickerSource.contains("whisperActiveRepo"))")

        var sole = WhisperVoiceModels.State.defaultState
        let beforeSole = sole
        let refused = sole.setTicked(turbo, false)
        reporter.record(
            "whisper-adv: guard: unticking the only ticked variant is refused",
            refused == false && sole == beforeSole,
            "refused=\(refused) ticked=\(sole.ticked.sorted()) active=\(sole.active)")

        var multi = WhisperVoiceModels.State(ticked: [turbo, largeV3, large], active: turbo)
        let moved = multi.setTicked(turbo, false)
        reporter.record(
            "whisper-adv: guard: unticking the active variant moves active to the first remaining ticked one",
            moved == true && multi.active == largeV3 && !multi.ticked.contains(turbo)
                && multi.ticked.contains(largeV3),
            "moved=\(moved) active=\(multi.active) ticked=\(multi.ticked.sorted())")

        var refusesUnticked = WhisperVoiceModels.State.defaultState
        let refusedSetActive = refusesUnticked.setActive(largeV2)
        reporter.record(
            "whisper-adv: guard: the active variant is always ticked",
            multi.ticked.contains(multi.active)
                && refusedSetActive == false
                && refusesUnticked == WhisperVoiceModels.State.defaultState,
            "active=\(multi.active) inTicked=\(multi.ticked.contains(multi.active))")
    }

    // MARK: - engine choice write rule

    private final class EventLog {
        var events: [String] = []
    }

    private final class ScriptedRunner: InstallerProcessRunning {
        var responses: [InstallerCommandResult]
        var invocations: [[String]] = []
        private let onModelDownload: (String) -> Void

        init(responses: [InstallerCommandResult], onModelDownload: @escaping (String) -> Void) {
            self.responses = responses
            self.onModelDownload = onModelDownload
        }

        func run(executable: URL, arguments: [String], environment: [String: String],
                 timeout: TimeInterval) -> InstallerCommandResult {
            invocations.append(arguments)
            let result = responses.isEmpty
                ? InstallerCommandResult(exitCode: 0)
                : responses.removeFirst()
            if result.succeeded, arguments.contains("-m"), arguments.contains("venv"),
               let path = arguments.last {
                let python = URL(fileURLWithPath: path).appendingPathComponent("bin/python")
                try? FileManager.default.createDirectory(at: python.deletingLastPathComponent(),
                                                          withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: python.path, contents: Data())
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: python.path)
            } else if arguments.first == "-c",
                      arguments.dropFirst().first?.contains("snapshot_download") == true {
                onModelDownload(result.stdout)
            }
            return result
        }
    }

    private static func runEngine(
        descriptor: InstallerComponentDescriptor,
        modelDownload: InstallerCommandResult?,
        select: @escaping (String) -> WhisperModelSwitch.Result,
        log: EventLog
    ) -> (result: InstallerComponentResult, runner: ScriptedRunner) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-whisper-adv-\(UUID().uuidString)", isDirectory: true)
        let paths = InstallerPaths(
            python: URL(fileURLWithPath: "/bin/sh"),
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            modelCache: root.appendingPathComponent("model-cache", isDirectory: true),
            packageCache: root.appendingPathComponent("package-cache", isDirectory: true))

        var responses: [InstallerCommandResult] = []
        if descriptor.virtualEnvironmentRelativePath != nil {
            responses.append(InstallerCommandResult(exitCode: 0))  // venv
            if let modelDownload {
                if modelDownload.succeeded {
                    responses.append(InstallerCommandResult(
                        exitCode: 0,
                        stdout: "VIDDYDICTATE_SNAPSHOT=\(paths.modelCache.path)/snapshot\n"
                            + "VIDDYDICTATE_HASHES={}\n"))
                } else {
                    responses.append(modelDownload)
                }
            }
        }

        let runner = ScriptedRunner(responses: responses, onModelDownload: { _ in
            log.events.append("download")
        })
        let engine = InstallerEngine(paths: paths, runner: runner, sleep: { _ in },
                                     whisperChoiceSelect: { repo in
            log.events.append("select:\(repo)")
            return select(repo)
        })
        let result = engine.install(descriptor)
        defer { try? FileManager.default.removeItem(at: root) }
        return (result, runner)
    }

    private static func failed(_ result: InstallerComponentResult) -> InstallerFailure? {
        if case .failed(let failure, _) = result.state { return failure }
        return nil
    }

    private static func checkEngineChoice(_ reporter: SelfTestReporter) {
        print("--- engine choice write rule ---")

        let activeLog = EventLog()
        let activeDescriptor = InstallerComponentDescriptor(
            id: "whisper-model:large-v3",
            title: "Large V3",
            detail: "The Large V3 speech model",
            virtualEnvironmentRelativePath: "stt-venv",
            modelArtifacts: [InstallerModelArtifact(repository: largeV3)],
            downloadBytes: 3_080_000_000,
            writeWhisperChoiceOnSuccess: largeV3)
        let active = runEngine(
            descriptor: activeDescriptor,
            modelDownload: InstallerCommandResult(
                exitCode: 1, stderr: "HTTP error 404 Not Found MARKER_PROVIDER_BODY"),
            select: { _ in .switched }, log: activeLog)
        let activeFailure = failed(active.result)
        reporter.record(
            "whisper-adv: new: a failed active whisper download reports a fixed title and never process output",
            activeFailure?.message == "Large V3 could not be downloaded"
                && activeFailure?.category == .client(404)
                && !(activeFailure?.message.contains("MARKER_PROVIDER_BODY") ?? true)
                && !(activeFailure?.message.contains("404") ?? true)
                && !activeLog.events.contains { $0.hasPrefix("select:") },
            "message=\(activeFailure?.message ?? "nil") category=\(String(describing: activeFailure?.category)) events=\(activeLog.events)")

        let nonActiveLog = EventLog()
        let nonActiveDescriptor = InstallerComponentDescriptor(
            id: "whisper-model:large-v3",
            title: "Large V3",
            detail: "The Large V3 speech model",
            virtualEnvironmentRelativePath: "stt-venv",
            modelArtifacts: [InstallerModelArtifact(repository: largeV3)],
            downloadBytes: 3_080_000_000,
            writeWhisperChoiceOnSuccess: nil)
        let nonActive = runEngine(
            descriptor: nonActiveDescriptor,
            modelDownload: InstallerCommandResult(
                exitCode: 1, stderr: "HTTP error 404 Not Found MARKER_PROVIDER_BODY"),
            select: { _ in .switched }, log: nonActiveLog)
        let nonActiveFailure = failed(nonActive.result)
        reporter.record(
            "whisper-adv: new: a failed non-active whisper download leaves the choice untouched and reports the fixed title",
            nonActiveFailure?.message == "Large V3 could not be downloaded"
                && !(nonActiveFailure?.message.contains("MARKER_PROVIDER_BODY") ?? true)
                && !nonActiveLog.events.contains { $0.hasPrefix("select:") },
            "message=\(nonActiveFailure?.message ?? "nil") events=\(nonActiveLog.events)")

        let orderLog = EventLog()
        let order = runEngine(
            descriptor: activeDescriptor,
            modelDownload: InstallerCommandResult(exitCode: 0),
            select: { _ in .switched }, log: orderLog)
        reporter.record(
            "whisper-adv: new: the engine selects the active repo exactly once, after its download, and nothing else",
            order.result.succeeded && orderLog.events == ["download", "select:\(largeV3)"],
            "succeeded=\(order.result.succeeded) events=\(orderLog.events)")

        let installedLog = EventLog()
        let installedState = WhisperVoiceModels.State(ticked: [turbo, largeV3], active: largeV3)
        let installedChoice = WhisperVoiceModels.descriptors(
            state: installedState, installed: { $0 == largeV3 })
            .first { $0.id == "whisper-model:large-v3" }
        if let installedChoice {
            let installed = runEngine(descriptor: installedChoice, modelDownload: nil,
                                      select: { _ in .switched }, log: installedLog)
            reporter.record(
                "whisper-adv: new: an already-installed active repo selects once and downloads nothing",
                installed.result.succeeded
                    && installedLog.events == ["select:\(largeV3)"]
                    && installed.runner.invocations.isEmpty,
                "succeeded=\(installed.result.succeeded) events=\(installedLog.events) invocations=\(installed.runner.invocations.count)")
        } else {
            reporter.record(
                "whisper-adv: new: an already-installed active repo selects once and downloads nothing",
                false, "no descriptor produced")
        }
    }

    // MARK: - guards

    private static func checkGuards(_ reporter: SelfTestReporter) {
        print("--- guards ---")
        reporter.record(
            "whisper-adv: guard: every RowID raw value is unchanged",
            ComponentPicker.RowID.allCases.map(\.rawValue)
                == ["pythonRuntime", "transcriptionEngine", "voiceModel", "webSearch",
                    "lmStudio", "gemma", "qwen", "ollama", "ollamaGemma", "ollamaQwen"])

        let componentPickerSource = source("Sources/SelfTest/ComponentPickerSelfTest.swift")
        reporter.record(
            "whisper-adv: guard: the existing --component-picker-selftest rows are unchanged",
            componentPickerSource.contains("the mandatory core is four rows, none of them a checkbox")
                && componentPickerSource.contains("the core total reads 1.7 GB")
                && componentPickerSource.contains("the core total is the sum of the measured core rows, in bytes"))

        let simple = ComponentPicker.installPlan(
            selection: .init(), facts: facts(), environment: .init(),
            installed: { _ in false })
        reporter.record(
            "whisper-adv: guard: the simple-path plan is unchanged",
            simple.queue.map(\.id) == ["stt-daemon", "web-search"]
                && simple.whisperModels.isEmpty,
            "queue=\(simple.queue.map(\.id)) whisperModels=\(simple.whisperModels.count)")
    }
}
