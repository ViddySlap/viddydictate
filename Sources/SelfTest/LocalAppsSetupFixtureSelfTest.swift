import Foundation

/// Ollama lane S3c (`--local-apps-setup-selftest`): the Setup tab's local app rows, headline and Preferred
/// local app choices (`LocalAppRows`), the point-of-use panel's local-app choice page and running page
/// (`PointOfUsePolicy`), and the routing grid's app-named Local preset line, all as data. Pure: hand-built
/// S3a presences (with the per-app readings `observeLocal` produces), hand-built bootstrap records, no view,
/// no store, no LM Studio, no Ollama, no install queue. The AppKit half is photographed by `--setup-render`
/// and `--point-of-use-render`.
///
/// Fixture values are distinct so a default cannot pass by accident: LM Studio lists **3** models and
/// Ollama **2**, and the failed install's error is a sentence no copy in the app contains.
///
/// Negative controls: the contract is re-run against broken row builders, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) a Start button on a command-line (Homebrew) Ollama;
/// (b) Ollama listed first, and separately Ollama marked recommended;
/// (c) an app-neutral headline on an LM-Studio-only Mac.
enum LocalAppsSetupFixtureSelfTest {

    // Assertion names the negative controls look up.
    private static let commandLineCheck = "a command-line Ollama offers no Start and no Open, and says how to start it"
    private static let orderCheck = "LM Studio is the first row and Ollama the second in every case"
    private static let recommendedCheck =
        "the recommended marker is only on LM Studio, and only when neither app is installed"
    private static let headlineCheck = "an LM-Studio-only Mac reads 1.1.0's headline byte for byte"

    /// 1.1.0's Local models copy, verbatim. An LM-Studio-only Mac must read exactly this.
    private static let headline110 = "Local models run in LM Studio, on this Mac."
    private static let purpose110 =
        "ViddyDictate refuses to load a model when doing so would push the machine past the budget below, "
        + "and says so rather than crashing. The budget counts everything on the Mac holding wired memory, "
        + "not just ViddyDictate's own models."
    private static let warning =
        "macOS will ask for Touch ID or your password so Ollama can install its command-line tool; approve it."
    private static let failedInstall = "fixture: the LM Studio disk image went away halfway through"

    /// The row builder and headline under test, so a mutant can stand in for either.
    struct Subject {
        let rows: (LLMProviderDetection.Presence?, [LocalBackendID: LocalAppRows.Activity]) -> [LocalAppRows.Row]
        let headline: (LLMProviderDetection.Presence?) -> String
    }

    private static let real = Subject(rows: { LocalAppRows.build(presence: $0, activity: $1) },
                                      headline: { LocalAppRows.headline(presence: $0) })

    static func run() -> Bool {
        print("=== Local apps on the Setup tab, the point-of-use app choice, and the Local preset line ===")
        let reporter = SelfTestReporter()

        print("--- row and button matrix (real LocalAppRows) ---")
        checkContract(real, reporter)
        print("--- installs, starts, and the one word for Retry ---")
        checkActivity(reporter)
        print("--- Preferred local app ---")
        checkPreference(reporter)
        print("--- 1.1.0's Local models copy is untouched ---")
        checkUnchangedCopy(reporter)
        print("--- point-of-use: the local-app choice page and the running page ---")
        checkPointOfUse(reporter)
        print("--- routing grid: the Local preset line names the app only when the picker does ---")
        checkPresetBadge(reporter)
        checkNegativeControls(reporter)

        print(reporter.summaryLine(prefix: "[local-apps-setup]"))
        return reporter.passed
    }

    // MARK: - Fixtures

    private static func models(_ backend: LocalBackendID, _ count: Int) -> [LMStudioModelOption] {
        (0..<count).map {
            LMStudioModelOption(modelID: "\(backend.rawValue)-fixture-\($0)", label: "fixture \($0)",
                                backend: backend)
        }
    }

    private static func reading(_ backend: LocalBackendID, installed: Bool = false, responding: Bool = false,
                                models count: Int? = nil, app: Bool = true,
                                startAttempted: Bool = false) -> LLMProviderDetection.LocalBackendReading {
        LLMProviderDetection.LocalBackendReading(
            backend: backend, installed: installed, responding: responding,
            models: responding ? count.map { models(backend, $0) } : nil,
            startable: backend == .ollama && installed && app, startAttempted: startAttempted)
    }

    /// The merged presence exactly as `observeLocal` builds it from these readings.
    private static func presence(_ lmStudio: LLMProviderDetection.LocalBackendReading,
                                 _ ollama: LLMProviderDetection.LocalBackendReading)
        -> LLMProviderDetection.Presence {
        LLMProviderDetection.mergedLocalPresence([lmStudio, ollama])
    }

    private static var neither: LLMProviderDetection.Presence {
        presence(reading(.lmStudio), reading(.ollama))
    }
    private static var lmStudioOnly: LLMProviderDetection.Presence {
        presence(reading(.lmStudio, installed: true, responding: true, models: 3), reading(.ollama))
    }
    private static var lmStudioStopped: LLMProviderDetection.Presence {
        presence(reading(.lmStudio, installed: true), reading(.ollama))
    }
    private static var ollamaAppStopped: LLMProviderDetection.Presence {
        presence(reading(.lmStudio), reading(.ollama, installed: true))
    }
    private static var ollamaAppDidNotStart: LLMProviderDetection.Presence {
        presence(reading(.lmStudio), reading(.ollama, installed: true, startAttempted: true))
    }
    private static var ollamaCommandLineStopped: LLMProviderDetection.Presence {
        presence(reading(.lmStudio, installed: true, responding: true, models: 3),
                 reading(.ollama, installed: true, app: false))
    }
    private static var ollamaCommandLineRunning: LLMProviderDetection.Presence {
        presence(reading(.lmStudio), reading(.ollama, installed: true, responding: true, models: 2, app: false))
    }
    private static var bothRunning: LLMProviderDetection.Presence {
        presence(reading(.lmStudio, installed: true, responding: true, models: 3),
                 reading(.ollama, installed: true, responding: true, models: 2))
    }

    /// Every case the gate states a matrix for, by name.
    private static var cases: [(String, LLMProviderDetection.Presence?)] {
        [("checking", nil), ("neither", neither), ("LM Studio only", lmStudioOnly),
         ("LM Studio stopped", lmStudioStopped), ("Ollama app stopped", ollamaAppStopped),
         ("Ollama app did not start", ollamaAppDidNotStart),
         ("Ollama command line stopped", ollamaCommandLineStopped),
         ("Ollama command line running", ollamaCommandLineRunning), ("both running", bothRunning),
         ("hand-built presence", LLMProviderDetection.Presence(installed: true, state: .available,
                                                               availableLocalModels: models(.lmStudio, 3)))]
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func row(_ rows: [LocalAppRows.Row], _ backend: LocalBackendID) -> LocalAppRows.Row? {
        rows.first { $0.backend == backend }
    }

    private static func buttons(_ row: LocalAppRows.Row?) -> String {
        row?.buttons.map { "\($0.title)\($0.isEnabled ? "" : " (off)")" }.joined(separator: ",") ?? "-"
    }

    private static func line(_ row: LocalAppRows.Row?) -> String {
        guard let row else { return "missing" }
        return "\(row.stateWord) / \(row.status) / [\(buttons(row))]"
    }

    private static func checkContract(_ subject: Subject, _ reporter: SelfTestReporter) {
        var expected: [(String, LLMProviderDetection.Presence?, String, String)] = []
        expected.append(("checking", nil, "CHECKING / Checking... / []", "CHECKING / Checking... / []"))
        expected.append(("neither", neither, "NOT INSTALLED / Not installed / [Install]",
                         "NOT INSTALLED / Not installed / [Install]"))
        expected.append(("LM Studio only", lmStudioOnly, "RUNNING / Running with 3 models / [Open]",
                         "NOT INSTALLED / Not installed / [Install]"))
        expected.append(("LM Studio stopped", lmStudioStopped,
                         "NOT RUNNING / Installed, not running / [Open,Start]",
                         "NOT INSTALLED / Not installed / [Install]"))
        expected.append(("Ollama app stopped", ollamaAppStopped, "NOT INSTALLED / Not installed / [Install]",
                         "NOT RUNNING / Installed, not running / [Open,Start]"))
        expected.append(("Ollama command line stopped", ollamaCommandLineStopped,
                         "RUNNING / Running with 3 models / [Open]",
                         "NOT RUNNING / Installed as a command-line tool (Homebrew), not running / []"))
        expected.append(("Ollama command line running", ollamaCommandLineRunning,
                         "NOT INSTALLED / Not installed / [Install]", "RUNNING / Running with 2 models / []"))
        expected.append(("both running", bothRunning, "RUNNING / Running with 3 models / [Open]",
                         "RUNNING / Running with 2 models / [Open]"))
        for (name, presence, lmStudio, ollama) in expected {
            let rows = subject.rows(presence, [:])
            let got = (line(row(rows, .lmStudio)), line(row(rows, .ollama)))
            reporter.record("\(name): LM Studio \(lmStudio) | Ollama \(ollama)",
                            got.0 == lmStudio && got.1 == ollama, "\(got.0) | \(got.1)")
        }

        // The order and the single recommendation, over every case.
        let orders = cases.map { subject.rows($0.1, [:]).map(\.backend) }
        reporter.record(orderCheck, orders.allSatisfy { $0 == [.lmStudio, .ollama] },
                        orders.map { $0.map(\.rawValue).joined(separator: ",") }.joined(separator: " | "))
        let marked = cases.map { name, presence -> String in
            let rows = subject.rows(presence, [:])
            return "\(name): " + rows.filter(\.recommended).map(\.backend.rawValue).joined(separator: ",")
        }
        let recommendationRight = cases.allSatisfy { name, presence in
            let rows = subject.rows(presence, [:])
            let recommended = rows.filter(\.recommended).map(\.backend)
            return name == "neither" ? recommended == [.lmStudio] : recommended.isEmpty
        }
        reporter.record(recommendedCheck, recommendationRight, marked.joined(separator: " | "))
        let neitherRows = subject.rows(neither, [:])
        reporter.record("with neither app, LM Studio is tagged the simple install and Ollama the advanced one",
                        row(neitherRows, .lmStudio)?.tag == "Simple - recommended"
                            && row(neitherRows, .ollama)?.tag == "Advanced",
                        neitherRows.map { $0.tag ?? "-" }.joined(separator: " / "))
        reporter.record("with either app installed, neither row carries a tag",
                        cases.filter { $0.0 != "neither" && $0.0 != "checking" }
                            .allSatisfy { subject.rows($0.1, [:]).allSatisfy { $0.tag == nil } })

        // The command-line Ollama: no app to open, a daemon ViddyDictate never starts, and the row says how.
        let commandLine = row(subject.rows(ollamaCommandLineStopped, [:]), .ollama)
        reporter.record(commandLineCheck,
                        commandLine?.button(.start) == nil && commandLine?.button(.open) == nil
                            && commandLine?.detail?.contains("ollama serve") == true,
                        "\(line(commandLine)) / \(commandLine?.detail ?? "no detail")")
        let commandLineUp = row(subject.rows(ollamaCommandLineRunning, [:]), .ollama)
        reporter.record("a running command-line Ollama still offers no Open, and says it is the Homebrew tool",
                        commandLineUp?.buttons.isEmpty == true
                            && commandLineUp?.detail?.contains("command-line tool (Homebrew)") == true,
                        commandLineUp?.detail ?? "no detail")
        reporter.record("Start is offered only on an installed APP that is not running",
                        cases.allSatisfy { _, presence in
                            subject.rows(presence, [:]).allSatisfy { row in
                                (row.button(.start) != nil) == (row.state == .notRunning)
                            }
                        })

        // The Ollama Install copy carries the approval warning, word for word; LM Studio's never mentions it.
        let ollamaInstall = row(neitherRows, .ollama)?.detail ?? ""
        let lmStudioInstall = row(neitherRows, .lmStudio)?.detail ?? ""
        reporter.record("the Ollama Install copy carries the macOS approval warning",
                        ollamaInstall.contains(warning) && OllamaInstaller.adminPromptWarning == warning,
                        ollamaInstall)
        reporter.record("the Ollama Install copy keeps the warning once LM Studio is installed",
                        row(subject.rows(lmStudioOnly, [:]), .ollama)?.detail?.contains(warning) == true)
        reporter.record("LM Studio's Install copy raises no prompt warning",
                        !lmStudioInstall.contains("Touch ID") && lmStudioInstall.hasPrefix("The simple install."),
                        lmStudioInstall)

        reporter.record("an Ollama app S3a already tried to start says to approve its prompt",
                        row(subject.rows(ollamaAppDidNotStart, [:]), .ollama)?.detail
                            == LLMProviderDetection.ollamaDidNotStartReason
                            && row(subject.rows(ollamaAppDidNotStart, [:]), .ollama)?.needsAttention == true)
        reporter.record("an app that is merely not running is not flagged as a problem",
                        row(subject.rows(lmStudioStopped, [:]), .lmStudio)?.needsAttention == false)

        // The headline.
        reporter.record(headlineCheck,
                        subject.headline(lmStudioOnly) == headline110
                            && subject.headline(lmStudioStopped) == headline110,
                        subject.headline(lmStudioOnly))
        reporter.record("a Mac with neither app, or not yet measured, keeps 1.1.0's headline too",
                        subject.headline(neither) == headline110 && subject.headline(nil) == headline110)
        reporter.record("with Ollama installed the headline names the apps that are there",
                        subject.headline(bothRunning) == "Local models run in LM Studio or Ollama, on this Mac."
                            && subject.headline(ollamaAppStopped) == "Local models run in Ollama, on this Mac."
                            && subject.headline(ollamaCommandLineStopped)
                                == "Local models run in LM Studio or Ollama, on this Mac.",
                        subject.headline(bothRunning))

        // Identity.
        let identifiers = LocalAppRows.order.flatMap { backend in
            LocalAppRows.Action.allCases.map { LocalAppRows.buttonIdentifier($0, backend) }
        }
        reporter.record("every button identifier names its app and action, and reads back",
                        Set(identifiers).count == identifiers.count
                            && LocalAppRows.order.allSatisfy { backend in
                                LocalAppRows.Action.allCases.allSatisfy {
                                    let back = LocalAppRows.button(
                                        fromIdentifier: LocalAppRows.buttonIdentifier($0, backend))
                                    return back?.0 == backend && back?.1 == $0
                                }
                            }
                            && LocalAppRows.button(fromIdentifier: "local-apps-button|ollama") == nil,
                        identifiers.joined(separator: " "))
    }

    // MARK: - Activity

    /// A durable record titled as the install plan titles it ("Ollama", "LM Studio").
    private static func record(_ id: String, _ phase: BootstrapComponentPhase,
                               failure: String? = nil) -> BootstrapComponentRecord {
        let title = BootstrapInstallPlan.allComponents.first { $0.id == id }?.title ?? id
        return BootstrapComponentRecord(id: id, title: title, phase: phase, attempts: phase == .failed ? 3 : 0,
                                        failureMessage: failure)
    }

    private static func checkActivity(_ reporter: SelfTestReporter) {
        let ollamaID = LocalAppRows.installDescriptor(.ollama).id
        let lmStudioID = LocalAppRows.installDescriptor(.lmStudio).id
        reporter.record("each app's Install queues exactly the row the point-of-use offer queues for it",
                        lmStudioID == BootstrapInstallPlan.lmStudio.id && ollamaID == BootstrapInstallPlan.ollama.id)

        let waiting = LocalAppRows.activity(record: record(ollamaID, .installing), queueRunning: true,
                                            reported: .awaitingApproval(.ollama))
        reporter.record("an Ollama install waiting on its prompt reads as that wait, from the queue's report",
                        waiting == .installing(detail: "waiting for you to approve Ollama's macOS prompt"),
                        "\(waiting)")
        reporter.record("an installing record left by a queue that is not running reads as idle",
                        LocalAppRows.activity(record: record(ollamaID, .installing), queueRunning: false,
                                              reported: nil) == .idle)
        reporter.record("a pending record is idle: a fresh snapshot lists every component as pending",
                        LocalAppRows.activity(record: record(ollamaID, .pending), queueRunning: true,
                                              reported: nil) == .idle)
        let failed = LocalAppRows.activity(record: record(lmStudioID, .failed, failure: failedInstall),
                                           queueRunning: false, reported: nil)
        reporter.record("a failed install carries the installer's own text",
                        failed == .installFailed(message: failedInstall))

        let installing = LocalAppRows.build(presence: neither, activity: [.ollama: waiting])
        reporter.record("an installing row offers a disabled Installing... and keeps the prompt warning",
                        buttons(row(installing, .ollama)) == "Installing... (off)"
                            && row(installing, .ollama)?.detail?.contains("waiting for you to approve") == true
                            && row(installing, .ollama)?.detail?.contains(warning) == true,
                        line(row(installing, .ollama)))
        let retry = LocalAppRows.build(presence: neither, activity: [.lmStudio: failed])
        reporter.record("a failed install offers Retry, says why, and reads as needing attention",
                        buttons(row(retry, .lmStudio)) == "Retry" && row(retry, .lmStudio)?.detail == failedInstall
                            && row(retry, .lmStudio)?.needsAttention == true,
                        line(row(retry, .lmStudio)))
        let starting = LocalAppRows.build(presence: ollamaAppStopped, activity: [.ollama: .starting])
        reporter.record("a pressed Start reads Starting... and cannot be pressed twice",
                        buttons(row(starting, .ollama)) == "Open,Starting... (off)", line(row(starting, .ollama)))
        reporter.record("queue activity never changes a running row",
                        LocalAppRows.build(presence: bothRunning, activity: [.lmStudio: failed, .ollama: waiting])
                            == LocalAppRows.build(presence: bothRunning))

        // One word app-wide: the button is Retry, so every failure message says to choose Retry.
        let messages = [OllamaInstaller.approvalTimeoutMessage,
                        OllamaInstaller.InstallerError.pullStalled(model: "m").description,
                        OllamaInstaller.InstallerError.approvalTimedOut.description]
        reporter.record("the retry button is one word everywhere: Retry",
                        LocalAppRows.retryTitle == "Retry" && InstallProgress.retryTitle == "Retry"
                            && PointOfUsePolicy.runningButtons([record(ollamaID, .failed)]).first?.title == "Retry")
        reporter.record("installer failure messages tell the user to choose Retry, never Try again",
                        messages.allSatisfy { $0.contains("choose Retry") && !$0.contains("Try again") },
                        messages.joined(separator: " | "))
    }

    // MARK: - Preferred local app

    private static func titles(_ choices: [LocalAppRows.PreferenceChoice]) -> String {
        choices.map { ($0.isSelected ? "*" : "") + $0.title }.joined(separator: " | ")
    }

    private static func checkPreference(_ reporter: SelfTestReporter) {
        let automatic = LocalAppRows.preferenceChoices(explicit: nil, presence: bothRunning)
        reporter.record("Automatic with both apps names LM Studio and is selected",
                        titles(automatic) == "*Automatic (LM Studio) | LM Studio | Ollama", titles(automatic))
        let explicit = LocalAppRows.preferenceChoices(explicit: .ollama, presence: bothRunning)
        reporter.record("an explicit Ollama is selected, and Automatic still says what it would be",
                        titles(explicit) == "Automatic (LM Studio) | LM Studio | *Ollama", titles(explicit))
        reporter.record("the choices carry nil for Automatic and each app for itself",
                        explicit.map(\.value) == [nil, .lmStudio, .ollama])
        let ollamaOnly = LocalAppRows.preferenceChoices(explicit: nil, presence: ollamaAppStopped)
        reporter.record("Automatic on an Ollama-only Mac is Ollama",
                        ollamaOnly.first?.title == "Automatic (Ollama)", titles(ollamaOnly))
        reporter.record("Automatic on a Mac with neither app is LM Studio (D3)",
                        LocalAppRows.preferenceChoices(explicit: nil, presence: neither).first?.title
                            == "Automatic (LM Studio)")
        reporter.record("before a measurement, Automatic names nothing rather than guess",
                        LocalAppRows.preferenceChoices(explicit: nil, presence: nil).first?.title == "Automatic")
        reporter.record("Automatic's label is S3a's own effective preference",
                        [neither, lmStudioOnly, ollamaAppStopped, bothRunning].allSatisfy { presence in
                            let installed = LocalAppRows.installedApps(presence) ?? []
                            let effective = LocalBackendPreference.effective(explicit: nil, installed: installed)
                            return LocalAppRows.preferenceChoices(explicit: nil, presence: presence).first?.title
                                == "Automatic (\(effective.displayName))"
                        })
    }

    // MARK: - 1.1.0's copy

    private static func checkUnchangedCopy(_ reporter: SelfTestReporter) {
        reporter.record("the 1.1.0 headline constant is unchanged", LocalModelSetup.headline == headline110)
        reporter.record("the purpose line is unchanged", LocalModelSetup.purpose == purpose110)
        // TODO(S4) keeps these exactly as they are until ViddyDictate tracks the models it loaded.
        reporter.record("Loaded now and Unload all are unchanged, still LM Studio's",
                        LocalModelSetup.residencyTitle == "Loaded now" && LocalModelSetup.unloadAllTitle == "Unload all"
                            && LocalModelSetup.unloadingTitle == "Unloading...")
        reporter.record("the timer hint and the JIT row title are unchanged",
                        LocalModelSetup.timerHint == "ViddyDictate asks LM Studio to drop a model it loaded once it "
                            + "has gone this long unused. It applies to every model ViddyDictate loads, and never "
                            + "to one another app loaded."
                            && LocalModelSetup.jitTitle == "LM Studio JIT model timeout")
    }

    // MARK: - Point of use

    private static func checkPointOfUse(_ reporter: SelfTestReporter) {
        let choice = PointOfUsePolicy.localAppChoice(
            for: .email, lmStudioComponents: [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.gemma],
            ollamaComponents: [BootstrapInstallPlan.ollama])
        let cells = choice.cells
        reporter.record("the choice page lists LM Studio, then Ollama, then Not now",
                        cells.map(\.button.id) == [PointOfUsePolicy.lmStudioAppButtonID,
                                                   PointOfUsePolicy.ollamaAppButtonID, PointOfUsePolicy.skipButtonID],
                        cells.map(\.button.id).joined(separator: ","))
        reporter.record("LM Studio's cell is badged simple and recommended, Ollama's advanced, Not now nothing",
                        cells.map { $0.badge ?? "-" } == ["SIMPLE - RECOMMENDED", "ADVANCED", "-"],
                        cells.map { $0.badge ?? "-" }.joined(separator: ","))
        reporter.record("Ollama's cell carries the macOS approval warning; LM Studio's does not",
                        cells[1].detail.contains(warning) && !cells[0].detail.contains("Touch ID"), cells[1].detail)
        reporter.record("every button on the choice page only installs or skips",
                        cells.allSatisfy { [.install, .skip].contains($0.button.route.kind) })

        let offer = PointOfUseOffer.install(PointOfUseInstallOffer(
            featureID: "email", featureTitle: "Email mode", header: "H", lines: [], components: [],
            buttons: [], localAppChoice: choice))
        let install = PointOfUseButton(id: PointOfUsePolicy.installButtonID, title: "Install now", detail: "",
                                       route: .install)
        let skip = PointOfUseButton(id: PointOfUsePolicy.skipButtonID, title: "Not now", detail: "", route: .skip)
        reporter.record("on a Mac with neither app, Install now opens the choice instead of installing",
                        PointOfUsePolicy.installStep(pressed: install, offer: offer, choice: nil, running: false)
                            == .chooseApp(choice))
        reporter.record("the choice page installs the app whose button was pressed",
                        PointOfUsePolicy.installStep(pressed: cells[0].button, offer: nil, choice: choice,
                                                     running: false) == .installApp(.lmStudio)
                            && PointOfUsePolicy.installStep(pressed: cells[1].button, offer: nil, choice: choice,
                                                            running: false) == .installApp(.ollama))
        reporter.record("Not now on the choice page installs nothing",
                        PointOfUsePolicy.installStep(pressed: skip, offer: nil, choice: choice, running: false)
                            == PointOfUseInstallStep.none)
        let plain = PointOfUseOffer.install(PointOfUseInstallOffer(
            featureID: "email", featureTitle: "Email mode", header: "H", lines: [], components: [], buttons: []))
        reporter.record("an offer with no choice installs its own components, as before",
                        PointOfUsePolicy.installStep(pressed: install, offer: plain, choice: nil, running: false)
                            == .installComponents)

        let ollamaID = BootstrapInstallPlan.ollama.id
        let runningRows = [record(BootstrapInstallPlan.lmStudio.id, .installed), record(ollamaID, .installing)]
        reporter.record("while a row is still installing, the running page offers nothing to press",
                        PointOfUsePolicy.runningButtons(runningRows).isEmpty
                            && PointOfUsePolicy.runningButtons([record(ollamaID, .pending),
                                                                record("x", .failed)]).isEmpty)
        let stopped = [record(BootstrapInstallPlan.lmStudio.id, .installed), record(ollamaID, .failed, failure: "x")]
        let after = PointOfUsePolicy.runningButtons(stopped)
        reporter.record("once the queue stops on a failure, the running page offers Retry (install) and Close (skip)",
                        after.map(\.title) == ["Retry", "Close"] && after.map(\.route) == [.install, .skip],
                        after.map(\.title).joined(separator: ","))
        reporter.record("Retry on the running page runs the page's own rows again",
                        PointOfUsePolicy.installStep(pressed: after[0], offer: nil, choice: nil, running: true)
                            == .installComponents)
        reporter.record("a finished install with nothing failed offers nothing",
                        PointOfUsePolicy.runningButtons([record(ollamaID, .installed)]).isEmpty)

        let lines = PointOfUsePolicy.runningLines(runningRows) { id in
            id == ollamaID ? .awaitingApproval(.ollama) : nil
        }
        reporter.record("the running page shows the approval wait on Ollama's row and keeps the warning under it",
                        lines.count == 3 && lines[1] == "Ollama   waiting for you to approve Ollama's macOS prompt"
                            && lines[2] == warning,
                        lines.joined(separator: " | "))
        reporter.record("once Ollama's row has landed the warning goes",
                        PointOfUsePolicy.runningLines([record(ollamaID, .installed)]) { _ in nil }
                            == [PointOfUsePolicy.progressLine(record(ollamaID, .installed))])
    }

    // MARK: - Local preset line

    private static func checkPresetBadge(_ reporter: SelfTestReporter) {
        let shared = "preset-fixture-shared"
        let oneApp = [LMStudioModelOption(modelID: shared, label: "shared")]
        let twoApps = oneApp + [LMStudioModelOption(modelID: shared, label: "shared", backend: .ollama)]
        let lmsPin = LLMProviderBundle.local(ref: LocalModelRef(backend: .lmStudio, modelID: shared))
        let ollamaPin = LLMProviderBundle.local(ref: LocalModelRef(backend: .ollama, modelID: shared))
        // D11's two badge words: a user's own model reads CUSTOM, a built-in default STAFF PICK (two words, so
        // the app name must go after both, not after the first).
        let badge = "CUSTOM \(shared)"
        let staffPick = "STAFF PICK \(shared)"

        reporter.record("one app: the Local preset badge names no app",
                        LocalModelPickerItems.presetBadge(badge, bundle: lmsPin, catalog: oneApp) == badge
                            && LocalModelPickerItems.presetBadge(badge, bundle: lmsPin, catalog: nil) == badge
                            && LocalModelPickerItems.presetBadge(staffPick, bundle: lmsPin, catalog: oneApp)
                                == staffPick)
        reporter.record("both apps: the badge names the pinned app",
                        LocalModelPickerItems.presetBadge(badge, bundle: ollamaPin, catalog: twoApps)
                            == "CUSTOM · Ollama · \(shared)"
                            && LocalModelPickerItems.presetBadge(badge, bundle: lmsPin, catalog: twoApps)
                            == "CUSTOM · LM Studio · \(shared)",
                        LocalModelPickerItems.presetBadge(badge, bundle: ollamaPin, catalog: twoApps))
        reporter.record("both apps: a two-word STAFF PICK badge keeps both words before the app",
                        LocalModelPickerItems.presetBadge(staffPick, bundle: ollamaPin, catalog: twoApps)
                            == "STAFF PICK · Ollama · \(shared)"
                            && LocalModelPickerItems.presetBadge(
                                staffPick + " - custom prompt", bundle: lmsPin, catalog: twoApps)
                            == "STAFF PICK · LM Studio · \(shared) - custom prompt",
                        LocalModelPickerItems.presetBadge(staffPick, bundle: ollamaPin, catalog: twoApps))
        reporter.record("an Ollama pin over an LM-Studio-only catalog is named, as the picker names it",
                        LocalModelPickerItems.presetBadge(badge, bundle: ollamaPin, catalog: oneApp)
                            == "CUSTOM · Ollama · \(shared)"
                            && LocalModelPickerItems.labelsApps(
                                LocalModelPickerItems.routingGridOptions(catalog: oneApp, pinned: ollamaPin)))
        let cloud = LLMProviderBundle(provider: .claude, modelID: shared)
        reporter.record("a cloud bundle's badge is never touched",
                        LocalModelPickerItems.presetBadge("CUSTOM \(shared)", bundle: cloud, catalog: twoApps)
                            == "CUSTOM \(shared)")
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) Start offered on a command-line Ollama, as if it were the app.
        let startsDaemon = Subject(rows: { presence, activity in
            real.rows(presence, activity).map { row in
                guard row.state == .commandLineNotRunning else { return row }
                return LocalAppRows.Row(
                    backend: row.backend, title: row.title, tag: row.tag, recommended: row.recommended,
                    state: row.state, stateWord: row.stateWord, needsAttention: row.needsAttention,
                    status: row.status, detail: row.detail,
                    buttons: row.buttons + [LocalAppRows.Button(action: .start, title: "Start", isEnabled: true)])
            }
        }, headline: real.headline)
        requireCaught(reporter, mutant: "Start on a command-line Ollama", by: commandLineCheck) {
            checkContract(startsDaemon, $0)
        }

        // (b) Ollama first.
        let ollamaFirst = Subject(rows: { real.rows($0, $1).reversed() }, headline: real.headline)
        requireCaught(reporter, mutant: "Ollama listed first", by: orderCheck) {
            checkContract(ollamaFirst, $0)
        }
        // (b') Ollama recommended on a Mac with neither app.
        let ollamaRecommended = Subject(rows: { presence, activity in
            real.rows(presence, activity).map { row in
                LocalAppRows.Row(
                    backend: row.backend, title: row.title, tag: row.tag,
                    recommended: row.tag != nil && row.backend == .ollama,
                    state: row.state, stateWord: row.stateWord, needsAttention: row.needsAttention,
                    status: row.status, detail: row.detail, buttons: row.buttons)
            }
        }, headline: real.headline)
        requireCaught(reporter, mutant: "Ollama marked recommended", by: recommendedCheck) {
            checkContract(ollamaRecommended, $0)
        }

        // (c) The headline made app-neutral everywhere, including an LM-Studio-only Mac.
        let neutralHeadline = Subject(rows: real.rows, headline: { _ in "Local models run on this Mac." })
        requireCaught(reporter, mutant: "app-neutral headline on an LM-Studio-only Mac", by: headlineCheck) {
            checkContract(neutralHeadline, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
