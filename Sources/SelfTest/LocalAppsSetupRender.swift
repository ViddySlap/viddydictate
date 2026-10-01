import Cocoa
import Security

/// Ollama lane S3c: render cases for the Setup tab's local app rows and the Preferred local app, run by
/// `--setup-render`.
///
/// Every case is a real `SetupSettingsView` whose observer answers the healthy preflight fixture with ONE
/// change: its `.local` presence is the merged presence S3a's `observeLocal` builds from per-app readings
/// (`LLMProviderDetection.mergedLocalPresence`). So the rows are drawn from the tab's own observation, exactly
/// as in production, and nothing here probes an app. The buttons' side effects are a recorder
/// (`LocalAppActionsRecorder`): nothing is installed, opened, or started, ever. The Preferred local app is an
/// in-memory store, never `Settings`.
///
/// PNGs written (the whole Local models section, so the two existing cards are photographed under the rows):
///   - `setup-local-apps-neither.png`        - neither app: both Install, LM Studio tagged simple and recommended,
///                                              Ollama advanced with the macOS-prompt warning.
///   - `setup-local-apps-ollama-installing.png` - the same after Install on Ollama, waiting on its prompt.
///   - `setup-local-apps-lmstudio-only.png`  - LM Studio running, Ollama not installed: 1.1.0's headline and cards.
///   - `setup-local-apps-ollama-not-running.png` - the Ollama app installed and stopped: Open and Start.
///   - `setup-local-apps-ollama-starting.png` - the same with Start pressed and not back yet.
///   - `setup-local-apps-ollama-cli.png`     - a Homebrew Ollama, stopped: no Open, no Start, how to start it.
///   - `setup-local-apps-both-running.png`   - both running, with their model counts.
/// and of the apps card alone:
///   - `setup-local-apps-preferred-automatic.png` / `setup-local-apps-preferred-ollama.png` - the Preferred row
///                                              on Automatic (LM Studio), then on an explicit Ollama.
enum LocalAppsSetupRenderCases {
    typealias Report = SelfTestRenderCapture.Report

    private static func reading(_ backend: LocalBackendID, installed: Bool = false, responding: Bool = false,
                                models count: Int = 0, app: Bool = true)
        -> LLMProviderDetection.LocalBackendReading {
        let models = (0..<count).map {
            LMStudioModelOption(modelID: "\(backend.rawValue)-render-fixture-\($0)", label: "fixture \($0)",
                                backend: backend)
        }
        return LLMProviderDetection.LocalBackendReading(
            backend: backend, installed: installed, responding: responding, models: responding ? models : nil,
            startable: backend == .ollama && installed && app)
    }

    private static func presence(_ lmStudio: LLMProviderDetection.LocalBackendReading,
                                 _ ollama: LLMProviderDetection.LocalBackendReading)
        -> LLMProviderDetection.Presence {
        LLMProviderDetection.mergedLocalPresence([lmStudio, ollama])
    }

    /// Where the captures go, beside the other Setup captures. Set by `run`.
    private static var outDir = ""

    static func run(outDir: String, report: Report) {
        self.outDir = outDir
        print("--- Ollama lane S3c: local app rows and the Preferred local app ---")
        let neither = presence(reading(.lmStudio), reading(.ollama))
        let lmStudioOnly = presence(reading(.lmStudio, installed: true, responding: true, models: 3),
                                    reading(.ollama))
        let ollamaStopped = presence(reading(.lmStudio), reading(.ollama, installed: true))
        let ollamaRunning = presence(reading(.lmStudio), reading(.ollama, installed: true, responding: true,
                                                                 models: 2))
        let commandLine = presence(reading(.lmStudio, installed: true, responding: true, models: 3),
                                   reading(.ollama, installed: true, app: false))
        let both = presence(reading(.lmStudio, installed: true, responding: true, models: 3),
                            reading(.ollama, installed: true, responding: true, models: 2))

        runNeither(neither, after: ollamaStopped, outDir: outDir, report: report)
        runLMStudioOnly(lmStudioOnly, outDir: outDir, report: report)
        runOllamaStopped(ollamaStopped, after: ollamaRunning, outDir: outDir, report: report)
        runCommandLine(commandLine, outDir: outDir, report: report)
        runBoth(both, outDir: outDir, report: report)
    }

    // MARK: - Cases

    private static func runNeither(_ neither: LLMProviderDetection.Presence,
                                   after installed: LLMProviderDetection.Presence, outDir: String, report: Report) {
        let harness = Harness(presence: neither)
        assertRows(harness, "neither", report: report)
        let ollama = SelfTestRenderCapture.label(LocalAppRows.identifier(.detail, .ollama), in: harness.view)
        report("[neither] the Ollama row warns about the macOS prompt before Install is pressed",
               ollama?.stringValue.contains(OllamaInstaller.adminPromptWarning) == true,
               ollama?.stringValue ?? "missing")
        report("[neither] only LM Studio's tag is the recommended one, and it reads first",
               tag(.lmStudio, harness) == "Simple - recommended" && tag(.ollama, harness) == "Advanced"
                   && rowY(.lmStudio, harness) < rowY(.ollama, harness),
               "\(tag(.lmStudio, harness) ?? "-") / \(tag(.ollama, harness) ?? "-")")
        harness.capture("setup-local-apps-neither.png", report: report)

        // Install on Ollama: one request to the shared queue, flagged to move the Preferred app (D3), nothing
        // launched. The queue then reports the prompt wait, and the row says so.
        press(.install, .ollama, harness)
        report("[neither] Install queues Ollama's own row once, following the preference, launching nothing",
               harness.recorder.installs.count == 1 && harness.recorder.installs.first?.0 == .ollama
                   && harness.recorder.installs.first?.1 == true && harness.recorder.opens.isEmpty
                   && harness.recorder.starts.isEmpty,
               "\(harness.recorder.installs)")
        harness.recorder.activity[.ollama] = .installing(detail: InstallProgress.awaitingApprovalText(.ollama))
        harness.refreshSection()
        assertRows(harness, "neither, Ollama installing", report: report)
        report("[neither] the installing row reads the queue's approval wait and cannot be pressed again",
               buttonTitles(.ollama, harness) == ["Installing..."] && !isEnabled(.install, .ollama, harness)
                   && SelfTestRenderCapture.label(LocalAppRows.identifier(.detail, .ollama), in: harness.view)?
                       .stringValue.contains("waiting for you to approve Ollama's macOS prompt") == true,
               buttonTitles(.ollama, harness).joined(separator: ","))
        harness.capture("setup-local-apps-ollama-installing.png", report: report)

        // The queue finishes: the tab re-measures instead of the row believing its own click.
        let checks = harness.calls
        harness.presence = installed
        harness.recorder.activity = [:]
        harness.recorder.finishInstalls()
        report("[neither] a finished install re-measures the tab", harness.calls == checks + 1,
               "calls \(checks) -> \(harness.calls)")
        assertRows(harness, "after the Ollama install", report: report)
        harness.close()
    }

    private static func runLMStudioOnly(_ presence: LLMProviderDetection.Presence, outDir: String,
                                        report: Report) {
        let harness = Harness(presence: presence)
        assertRows(harness, "LM Studio only", report: report)
        // Today's layout: 1.1.0's words in the existing cards, and nothing new written into them.
        let expected: [(LocalModelSetup.Part, String)] = [
            (.headline, "Local models run in LM Studio, on this Mac."),
            (.purpose, LocalModelSetup.purpose),
            (.residencyTitle, "Loaded now"),
            (.budgetTitle, LocalModelSetup.budgetTitle),
            (.timerTitle, LocalModelSetup.timerTitle),
            (.jitTitle, "LM Studio JIT model timeout"),
        ]
        let wrong = expected.filter {
            SelfTestRenderCapture.label(LocalModelSetup.identifier($0.0), in: harness.view)?.stringValue != $0.1
        }.map(\.0.rawValue)
        report("[LM Studio only] the existing cards read 1.1.0's text byte for byte", wrong.isEmpty,
               wrong.joined(separator: ","))
        report("[LM Studio only] Unload all is still LM Studio's button, unchanged",
               (SelfTestRenderCapture.find(LocalModelSetup.identifier(.unloadAll), in: harness.view) as? NSButton)?
                   .title == "Unload all")
        report("[LM Studio only] no row carries a recommendation once an app is installed",
               tag(.lmStudio, harness) == nil && tag(.ollama, harness) == nil)
        harness.capture("setup-local-apps-lmstudio-only.png", report: report)
        harness.close()
    }

    private static func runOllamaStopped(_ stopped: LLMProviderDetection.Presence,
                                         after running: LLMProviderDetection.Presence, outDir: String,
                                         report: Report) {
        let harness = Harness(presence: stopped)
        assertRows(harness, "Ollama app stopped", report: report)
        report("[Ollama app stopped] the headline names Ollama",
               headline(harness) == "Local models run in Ollama, on this Mac.", headline(harness))
        harness.capture("setup-local-apps-ollama-not-running.png", report: report)

        press(.start, .ollama, harness)
        report("[Ollama app stopped] Start goes to the starter once, and nothing is installed or opened",
               harness.recorder.starts == [.ollama] && harness.recorder.installs.isEmpty
                   && harness.recorder.opens.isEmpty, "\(harness.recorder.starts)")
        report("[Ollama app stopped] a pending start reads Starting... and cannot be pressed twice",
               buttonTitles(.ollama, harness) == ["Open", "Starting..."] && !isEnabled(.start, .ollama, harness),
               buttonTitles(.ollama, harness).joined(separator: ","))
        harness.capture("setup-local-apps-ollama-starting.png", report: report)

        let checks = harness.calls
        harness.presence = running
        harness.recorder.finishStarts()
        report("[Ollama app stopped] the start coming back re-measures the tab", harness.calls == checks + 1,
               "calls \(checks) -> \(harness.calls)")
        assertRows(harness, "Ollama app started", report: report)
        press(.open, .ollama, harness)
        report("[Ollama app started] Open goes to the opener for Ollama", harness.recorder.opens == [.ollama],
               "\(harness.recorder.opens)")
        harness.close()
    }

    private static func runCommandLine(_ presence: LLMProviderDetection.Presence, outDir: String,
                                       report: Report) {
        let harness = Harness(presence: presence)
        assertRows(harness, "Ollama command line", report: report)
        report("[Ollama command line] the row has no Start and no Open control at all",
               SelfTestRenderCapture.find(LocalAppRows.buttonIdentifier(.start, .ollama), in: harness.view) == nil
                   && SelfTestRenderCapture.find(LocalAppRows.buttonIdentifier(.open, .ollama), in: harness.view)
                       == nil)
        report("[Ollama command line] it says how the user starts it",
               SelfTestRenderCapture.label(LocalAppRows.identifier(.detail, .ollama), in: harness.view)?
                   .stringValue == LocalAppRows.commandLineStartCopy)
        harness.capture("setup-local-apps-ollama-cli.png", report: report)
        harness.close()
    }

    private static func runBoth(_ presence: LLMProviderDetection.Presence, outDir: String, report: Report) {
        let harness = Harness(presence: presence)
        assertRows(harness, "both running", report: report)
        report("[both running] the headline names both apps",
               headline(harness) == "Local models run in LM Studio or Ollama, on this Mac.", headline(harness))
        harness.capture("setup-local-apps-both-running.png", report: report)

        guard let popup = SelfTestRenderCapture.find(LocalAppRows.preferencePopupIdentifier, in: harness.view)
            as? NSPopUpButton else {
            report("[preferred] the Preferred local app row offers a popup", false, "")
            harness.close()
            return
        }
        report("[preferred] Automatic says what it resolves to, and is selected while nothing is stored",
               popup.itemTitles == ["Automatic (LM Studio)", "LM Studio", "Ollama"]
                   && popup.titleOfSelectedItem == "Automatic (LM Studio)" && harness.store.preferred == nil,
               popup.itemTitles.joined(separator: " | "))
        harness.capture("setup-local-apps-preferred-automatic.png", card: LocalAppRows.cardIdentifier,
                        report: report)

        choose(popup, "Ollama")
        let after = SelfTestRenderCapture.find(LocalAppRows.preferencePopupIdentifier, in: harness.view)
            as? NSPopUpButton
        report("[preferred] choosing Ollama stores it, and the row reads it back from the store",
               harness.store.preferred == .ollama && after?.titleOfSelectedItem == "Ollama"
                   && after?.itemTitles.first == "Automatic (LM Studio)",
               after?.titleOfSelectedItem ?? "nil")
        harness.capture("setup-local-apps-preferred-ollama.png", card: LocalAppRows.cardIdentifier,
                        report: report)
        if let after { choose(after, "Automatic (LM Studio)") }
        report("[preferred] choosing Automatic clears the stored choice", harness.store.preferred == nil)
        harness.close()
    }

    // MARK: - Assertions

    /// Every row reads exactly what `LocalAppRows` built from the presence the tab observed: state word, name,
    /// tag, status, detail, and the buttons in order with their enabled state. Then the layout: nothing in
    /// the apps card is clipped or runs past it, buttons do not sit on the text, and the card ends above the
    /// controls card.
    private static func assertRows(_ harness: Harness, _ name: String, report: Report) {
        let rows = LocalAppRows.build(presence: harness.presence,
                                      activity: harness.recorder.activity.merging(
                                        harness.recorder.pendingStarts.map { ($0, LocalAppRows.Activity.starting) }
                                      ) { $1 })
        var wrong: [String] = []
        for row in rows {
            let id = { LocalAppRows.identifier($0, row.backend) }
            let text = { SelfTestRenderCapture.label(id($0), in: harness.view)?.stringValue }
            if text(.state) != row.stateWord { wrong.append("\(row.backend.rawValue).state=\(text(.state) ?? "-")") }
            if text(.title) != row.title { wrong.append("\(row.backend.rawValue).title") }
            if text(.tag) != row.tag { wrong.append("\(row.backend.rawValue).tag") }
            if text(.status) != row.status { wrong.append("\(row.backend.rawValue).status=\(text(.status) ?? "-")") }
            if text(.detail) != row.detail { wrong.append("\(row.backend.rawValue).detail") }
            if buttonTitles(row.backend, harness) != row.buttons.map(\.title) {
                wrong.append("\(row.backend.rawValue).buttons=\(buttonTitles(row.backend, harness))")
            }
            for button in row.buttons where isEnabled(button.action, row.backend, harness) != button.isEnabled {
                wrong.append("\(row.backend.rawValue).\(button.action.rawValue).enabled")
            }
        }
        report("[\(name)] every row is on screen and reads exactly what LocalAppRows built",
               wrong.isEmpty, wrong.joined(separator: ", "))
        print("  [rows] \(name): " + rows.map { "\($0.title): \($0.stateWord) / \($0.status) / "
            + "[\($0.buttons.map(\.title).joined(separator: ","))]" }.joined(separator: " | "))
        report("[\(name)] the headline is LocalAppRows' for this machine",
               headline(harness) == LocalAppRows.headline(presence: harness.presence), headline(harness))

        guard let card = SelfTestRenderCapture.find(LocalAppRows.cardIdentifier, in: harness.view),
              let controls = SelfTestRenderCapture.find(LocalModelSetup.cardIdentifier, in: harness.view) else {
            report("[\(name)] the section has its apps card and its controls card", false, "")
            return
        }
        var clipped: [String] = []
        var outside: [String] = []
        for field in card.subviews.compactMap({ $0 as? NSTextField }) {
            let needed = field.sizeThatFits(NSSize(width: field.frame.width, height: .greatestFiniteMagnitude))
            if field.frame.height + 0.5 < needed.height { clipped.append(field.identifier?.rawValue ?? "?") }
        }
        for subview in card.subviews where subview.frame.maxX > card.bounds.maxX + 0.5
            || subview.frame.maxY > card.frame.height + 0.5 {
            outside.append(subview.identifier?.rawValue ?? String(describing: type(of: subview)))
        }
        report("[\(name)] no line of the apps card is clipped", clipped.isEmpty, clipped.joined(separator: ","))
        report("[\(name)] nothing runs past the apps card", outside.isEmpty, outside.joined(separator: ","))
        var overlaps: [String] = []
        for row in rows {
            let controlsOfRow = row.buttons.compactMap {
                SelfTestRenderCapture.find(LocalAppRows.buttonIdentifier($0.action, row.backend), in: card)
            }
            let texts = [LocalAppRows.RowPart.title, .tag, .status].compactMap {
                SelfTestRenderCapture.find(LocalAppRows.identifier($0, row.backend), in: card)
            }
            for control in controlsOfRow {
                for text in texts where control.frame.intersects(text.frame) {
                    overlaps.append("\(control.identifier?.rawValue ?? "?") over \(text.identifier?.rawValue ?? "?")")
                }
            }
        }
        report("[\(name)] no button sits on its row's name, tag or status", overlaps.isEmpty,
               overlaps.joined(separator: ", "))
        report("[\(name)] the apps card ends above the controls card",
               card.frame.maxY <= controls.frame.minY + 0.5,
               "apps end \(Int(card.frame.maxY)), controls start \(Int(controls.frame.minY))")
    }

    // MARK: - Reading and driving the view

    private static func headline(_ harness: Harness) -> String {
        SelfTestRenderCapture.label(LocalModelSetup.identifier(.headline), in: harness.view)?.stringValue ?? "missing"
    }

    private static func tag(_ backend: LocalBackendID, _ harness: Harness) -> String? {
        SelfTestRenderCapture.label(LocalAppRows.identifier(.tag, backend), in: harness.view)?.stringValue
    }

    private static func rowY(_ backend: LocalBackendID, _ harness: Harness) -> CGFloat {
        SelfTestRenderCapture.find(LocalAppRows.identifier(.title, backend), in: harness.view)?.frame.minY ?? -1
    }

    /// The row's buttons as drawn, left to right.
    private static func buttonTitles(_ backend: LocalBackendID, _ harness: Harness) -> [String] {
        LocalAppRows.Action.allCases
            .compactMap { SelfTestRenderCapture.find(LocalAppRows.buttonIdentifier($0, backend), in: harness.view)
                as? NSButton }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.title)
    }

    private static func isEnabled(_ action: LocalAppRows.Action, _ backend: LocalBackendID,
                                  _ harness: Harness) -> Bool {
        (SelfTestRenderCapture.find(LocalAppRows.buttonIdentifier(action, backend), in: harness.view)
            as? NSButton)?.isEnabled ?? false
    }

    /// Press a row's button the way a click does: send its action to its target.
    private static func press(_ action: LocalAppRows.Action, _ backend: LocalBackendID, _ harness: Harness) {
        guard let button = SelfTestRenderCapture.find(LocalAppRows.buttonIdentifier(action, backend),
                                                      in: harness.view) as? NSButton,
              let target = button.target, let selector = button.action else { return }
        _ = target.perform(selector, with: button)
    }

    /// Pick a menu item, then fire the action. Not `performClick`, which opens the menu modally.
    private static func choose(_ popup: NSPopUpButton, _ title: String) {
        popup.selectItem(withTitle: title)
        guard let target = popup.target, let selector = popup.action else { return }
        _ = target.perform(selector, with: popup)
    }

    // MARK: - Harness

    /// One Setup tab over a scripted observation, an in-memory store and the recorder, in an offscreen
    /// window so captures have a real backing store.
    private final class Harness {
        var presence: LLMProviderDetection.Presence?
        private(set) var calls = 0
        let recorder = LocalAppActionsRecorder()
        let store = LocalModelStore(position: 54, seconds: 600)
        var view: SetupSettingsView!
        private let host: NSWindow

        init(presence: LLMProviderDetection.Presence) {
            self.presence = presence
            host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 2400),
                            styleMask: [.borderless], backing: .buffered, defer: false)
            let residency = LocalResidencyStub(models: SetupRender.bensModels, wired: 21_400_000_000)
            view = SetupSettingsView(
                width: 640,
                observer: { [unowned self] completion in
                    self.calls += 1
                    var observation = PreflightSelfTest.healthy
                    observation.providers[.local] = self.presence
                    completion(observation)
                },
                geminiKeyWriter: { _ in errSecSuccess }, geminiKeyDeleter: { errSecSuccess },
                localModels: .init(store: store.store, facts: { .live }, jit: { .init(ttlSeconds: 600, enabled: true) },
                                   residency: residency.reader, unloadAll: residency.unloader,
                                   now: { SetupRender.clock }, apps: recorder.actions))
            host.contentView?.addSubview(view)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        /// Ask the section to rebuild from its environment, the way a queue notification does.
        func refreshSection() {
            (SelfTestRenderCapture.find(LocalModelSetup.sectionIdentifier, in: view) as? LocalModelsSectionView)?
                .apply()
        }

        func capture(_ file: String, card: String = LocalModelSetup.sectionIdentifier, report: Report) {
            SelfTestRenderCapture.capture(view, card: card, to: "\(LocalAppsSetupRenderCases.outDir)/\(file)",
                                          name: file, report: report)
        }

        func close() {
            view.removeFromSuperview()
            host.orderOut(nil)
        }
    }
}

/// The local app rows' side effects, recorded instead of performed: nothing is installed, opened, or
/// started. Completions are HELD until the gate releases them, which is what production's asynchronous
/// queue and starter do, and is the only way to photograph "Starting..." or an install mid-flight.
final class LocalAppActionsRecorder {
    private(set) var installs: [(LocalBackendID, Bool)] = []
    private(set) var opens: [LocalBackendID] = []
    private(set) var starts: [LocalBackendID] = []
    /// What the "queue" reports for each app's install row.
    var activity: [LocalBackendID: LocalAppRows.Activity] = [:]
    private var heldInstalls: [() -> Void] = []
    private var heldStarts: [(LocalBackendID, () -> Void)] = []

    /// Starts pressed and not yet released.
    var pendingStarts: [LocalBackendID] { heldStarts.map(\.0) }

    var actions: LocalModelsSectionView.AppActions {
        LocalModelsSectionView.AppActions(
            install: { [self] backend, followsPreference, completion in
                installs.append((backend, followsPreference))
                heldInstalls.append(completion)
                return true
            },
            open: { [self] backend in
                opens.append(backend)
                return true
            },
            start: { [self] backend, completion in
                starts.append(backend)
                heldStarts.append((backend, completion))
            },
            activity: { [self] backend in activity[backend] ?? .idle })
    }

    func finishInstalls() {
        let held = heldInstalls
        heldInstalls = []
        held.forEach { $0() }
    }

    func finishStarts() {
        let held = heldStarts
        heldStarts = []
        held.forEach { $0.1() }
    }
}
