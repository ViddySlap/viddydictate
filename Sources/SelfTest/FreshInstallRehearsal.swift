import Foundation

/// Process-level first-run rehearsal for the production store graph.
///
/// Unlike the store unit tests, this deliberately injects no file URLs. The verification script launches
/// a fresh test-bundle process with HOME, CFFIXED_USER_HOME, and TMPDIR all pointing at a new scratch tree,
/// then independently requires that this process populated scratch Application Support. The process exits
/// before NSApplication is created, so it cannot take focus, enter single-instance logic, or bind the live
/// notes control-server port.
enum FreshInstallRehearsal {
    private static let adoptedID = "3A41E54C-1E85-4E4F-8684-9CD1D82949B4"

    /// Foundation spells the same macOS temporary root as `/tmp`, while mktemp reports `/private/tmp`.
    /// Normalize only that OS-provided alias; every component below it must still match exactly.
    private static func normalizingTemporaryRoot(_ path: String) -> String {
        path == "/tmp" || path.hasPrefix("/tmp/") ? "/private" + path : path
    }

    static func run() -> Bool {
        print("=== ViddyDictate fresh-install rehearsal ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? ""
        let coreFoundationHome = environment["CFFIXED_USER_HOME"] ?? ""
        let temporaryDirectory = environment["TMPDIR"] ?? ""
        let realHome = environment["VIDDYDICTATE_REAL_HOME"] ?? ""
        let support = AppPaths.applicationSupportDirectory(fileManager: fm)
        let expectedSupport = URL(fileURLWithPath: coreFoundationHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/ViddyDictate", isDirectory: true)

        reporter.record("HOME and CFFIXED_USER_HOME name the same non-real scratch home",
                        !home.isEmpty && !realHome.isEmpty
                            && home == coreFoundationHome && home != realHome,
                        "HOME=\(home) CFFIXED_USER_HOME=\(coreFoundationHome)")
        reporter.record("TMPDIR is inside the scratch home",
                        !temporaryDirectory.isEmpty
                            && URL(fileURLWithPath: temporaryDirectory).standardizedFileURL.path
                                .hasPrefix(URL(fileURLWithPath: home).standardizedFileURL.path + "/"),
                        "TMPDIR=\(temporaryDirectory)")
        reporter.record("Foundation resolves Application Support inside CFFIXED_USER_HOME",
                        normalizingTemporaryRoot(support.standardizedFileURL.path)
                            == normalizingTemporaryRoot(expectedSupport.standardizedFileURL.path),
                        support.path)
        reporter.record("the rehearsal starts before ViddyDictate Application Support exists",
                        !fm.fileExists(atPath: support.path), support.path)

        // These are the same default constructors production reaches during app bootstrap. No injected URL
        // is allowed here: an injected scratch file could go green while the app's real default path regressed.
        let routing = Settings.modelsPower
        let modes = CustomModeStore()
        let skills = StickySkillStore()
        let notes = StickyNotesStore()

        let skill = skills.skill(id: adoptedID)
        let mode = modes.mode(id: adoptedID)
        let route = LLMRouteID.custom(adoptedID)
        reporter.record("the shipped built-in is present on first run and keeps the adopted identity",
                        skill?.id == adoptedID && skill?.customModeID == adoptedID,
                        "skill=\(skill?.id ?? "missing") mode=\(skill?.customModeID ?? "missing")")
        reporter.record("the built-in has a non-empty task prompt on first run",
                        mode?.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                        mode == nil ? "backing mode missing" : "prompt bytes=\(mode!.prompt.utf8.count)")
        reporter.record("the built-in has a complete selected route on first run",
                        mode?.routeID == route && routing.routeIDs().contains(route),
                        "route=\(mode?.routeID.rawValue ?? "missing")")

        let unavailable: [LLMProvider: LLMProviderDetection.Presence] = [
            .claude: .init(installed: false, state: .unavailable("CLI unavailable")),
            .codex: .init(installed: false, state: .unavailable("CLI unavailable")),
            .local: .init(installed: false, state: .unavailable("LM Studio unavailable")),
        ]
        let onboarding = ProviderOnboarding.plan(providers: unavailable)
        reporter.record("a stranger with no provider reaches the first-run onboarding path",
                        !Settings.providerOnboardingSatisfied
                            && ProviderOnboarding.shouldPresentFirstRun(
                                hasEverBeenSatisfied: Settings.providerOnboardingSatisfied,
                                plan: onboarding),
                        ProviderOnboarding.headline(onboarding))

        let sourceID = "note-fresh-install-rehearsal"
        notes.saveOpenNote(id: sourceID, body: "A stranger can run the shipped built-in.")
        var receivedMode: CustomMode?
        var outcome: StickySkillCoordinator.Outcome?
        StickySkillCoordinator(
            store: notes,
            skillLookup: { skills.skill(id: $0) },
            modeLookup: { modes.mode(id: $0) },
            runner: { runMode, _, _, _, done in
                receivedMode = runMode
                done(CustomModeRunProvider(.pinned(runMode.model)), .ok("## Context\nFirst run works."))
            },
            visionPreparer: { _, request, done in
                done(NoteToHandoffVisionPreparation(request: request, images: []))
            }
        ).run(
            skillID: adoptedID,
            NoteToHandoffRequest(
                sourceNoteId: sourceID,
                title: "Fresh install",
                body: "A stranger can run the shipped built-in.",
                attachments: [])
        ) { outcome = $0 }

        let created: Bool
        if case .created = outcome { created = true } else { created = false }
        reporter.record("the first-run built-in reaches its model and creates a handoff",
                        receivedMode?.id == adoptedID && created,
                        String(describing: outcome))
        if case .failed(let userMessage, _) = outcome {
            reporter.record("the first run never reports a missing prompt or model settings",
                            !userMessage.contains("has no prompt and model settings"), userMessage)
        } else {
            reporter.record("the first run never reports a missing prompt or model settings", true)
        }

        let required = ["custom-modes.json", "sticky-skills.json", "models-power.json"]
        reporter.record("production defaults persisted the first-run stores in scratch Application Support",
                        required.allSatisfy {
                            fm.fileExists(atPath: support.appendingPathComponent($0).path)
                        } && fm.fileExists(atPath: notes.root.path),
                        support.path)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "[fresh-install-rehearsal]"))
        return reporter.passed
    }
}
