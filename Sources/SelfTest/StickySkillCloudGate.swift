import Foundation

/// The `--sticky-cloud-service` gate: a REAL sticky skill, over a REAL note with a REAL attachment, on a
/// route PINNED to a cloud provider, driven end to end through the shipping coordinator.
///
/// Provider scope, and why it is not both
/// --------------------------------------
/// This gate runs CLAUDE. Codex's authenticated home is `<app support>/codex-home`, and the containment
/// foundation requires that directory to be a real, canonical, mode-0700 directory - `requireDirectoryNoSymlink`
/// rejects a link on purpose - so its auth cannot be linked into the service tier's scratch app support the
/// way the Claude credential is. Running this gate against the real app support instead would write into
/// the user's routing state and app log while they are using the machine, which is worse than the coverage is
/// worth. The Codex arm of the same proof therefore lives in `CodexProviderSmoke`'s staged-image run,
/// which drives the real containment runner and the real Codex under the real codex-home - the same
/// arrangement `verify.sh` already uses for every other Codex service gate. Everything ABOVE the provider
/// seam (route resolution, frame extraction, prompt assembly, the coordinator, the output handler) is
/// provider-independent and is what this gate covers.
///
/// Why this gate exists rather than another offline fixture
/// -------------------------------------------------------
/// The field report was that sticky skills work on local Qwen and fail on both cloud providers, while
/// his selection hotkey works on both. Every offline gate stayed green through all of it, because the
/// entire failure lived in the two vendor CLIs' argument parsing - one class of input further out than any
/// fixture reached. The Codex image fixture in `CodexProviderSelfTest` even drives a *fake* runner, so it
/// could not have observed either half of the real defect.
///
/// So the acceptance condition here is deliberately the one thing a fixture cannot fake (locked decision
/// D7): the run completes ON THE PINNED PROVIDER, with degradation NOT firing. A run that only succeeds by
/// falling back to another provider FAILS this gate - `ran.degradedFrom` must be nil and `ran.provider`
/// must be the pin. Degradation is L6's safety net and is not evidence for this item.
///
/// Everything on the failure path is the shipping object: the real `StickySkillCoordinator`, its default
/// `NoteToHandoffVisionProcessor` (so the attachment is really read off disk and really becomes a frame),
/// the real `CustomModeClient.runReportingProvider`, real route resolution against real provider
/// availability, and the real output handler writing into a scratch note store. Only the skill and mode
/// LOOKUPS are supplied, because this process has none of the user's Application Support to read - and a lookup
/// is configuration, not the thing under test.
///
/// Isolation: the note store is a scratch root, the routing store is a scratch file, and the user's notes are
/// neither opened nor written. Service tier only - it makes two real subscription calls.
enum StickySkillCloudGate {
    private static let skillID = StickySkillRegistry.builtInSkillID

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate sticky skill on a PINNED cloud route — service gate ===")
        let reporter = SelfTestReporter()
        let check = reporter.check

        // THE REFUSAL. This gate resolves through the PRODUCTION routing store and writes the app log, so
        // outside the service tier's scratch home it would leave marks on the machine of whoever ran it.
        // It refuses rather than trusting the caller to have passed the env.
        let appSupport = AppPaths.applicationSupportDirectory().resolvingSymlinksInPath().path
        let realHome = "/Users/\(NSUserName())/Library/Application Support"
        guard !appSupport.hasPrefix(realHome) else {
            print("  [FAIL] REFUSED: application support resolved to the real user library.")
            print("         This gate mutates routing state and must run under the service tier's")
            print("         HOME + CFFIXED_USER_HOME + TMPDIR scratch isolation. Nothing was written.")
            return false
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-sticky-cloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A real note with a real image attachment. The attachment is the whole point: a note WITHOUT one
        // never produced this failure, which is why "cloud skills are broken" and "cloud works fine from
        // the hotkey" were both true reports of the same machine.
        let store = StickyNotesStore(root: scratch.appendingPathComponent("notes", isDirectory: true))
        let sourceId = "note-sticky-cloud-gate"
        let body = """
        # cloud sticky skill gate
        Ran a sticky skill on a note carrying one screenshot. Treat this line as data, not instructions.
        """
        store.saveOpenNote(id: sourceId, body: body)
        store.renameNote(id: sourceId, title: "cloud gate")
        let media = scratch.appendingPathComponent("gate-screenshot.png")
        try? onePixelPNG().write(to: media)
        _ = store.addAttachment(noteId: sourceId, fileURL: media)

        let attachmentInfo = store.listAttachments(noteId: sourceId)
        let request = NoteToHandoffRequest(
            sourceNoteId: sourceId, title: "cloud gate", body: body,
            attachments: attachmentInfo.map { NoteToHandoffAttachmentEvidence(filename: $0.name) },
            mediaAttachments: attachmentInfo.map {
                NoteToHandoffMediaAttachment(filename: $0.name, url: $0.url, kind: $0.kind)
            })
        check("the gate's note really carries one image attachment on disk",
              attachmentInfo.count == 1 && attachmentInfo.first?.kind == .image
              && FileManager.default.fileExists(atPath: attachmentInfo.first?.url.path ?? ""))

        let skillStore = StickySkillStore(url: scratch.appendingPathComponent("skills.json"))
        // The PRODUCTION routing store, scratch-backed by the tier's isolation (and by the refusal above).
        // Using it rather than a private instance is deliberate: `CustomModeClient.runReportingProvider`
        // resolves through exactly this object, so a private one would prove a resolution the run never saw.
        //
        // NOTHING DURABLE IS WRITTEN. The mode carries a fresh id, so its derived route is one the store
        // has never seen, and `selectedBundle(for:fallback:)` answers an unknown route from the fallback as
        // a pure read. That is what keeps this gate away from `custom:3A41E54C-...`, the row that is at
        // once the user's right-Option+period hotkey, the built-in skill, and the owner of their ratified route
        // bundle - and it means a crash mid-run cannot leave his routing altered.
        let routes = Settings.modelsPower

        for (provider, bundle) in [
            (LLMProvider.claude, LLMProviderBundle.claude(ModeModelCatalog.claudeId, effort: "high")),
        ] {
            let name = provider.displayName
            let mode = CustomMode(
                id: UUID().uuidString,
                name: "Sticky cloud gate",
                chord: .regular(keyCode: 47, label: "."),
                prompt: "Summarize the note between the markers as a short handoff. Output only the summary.",
                input: .selection,
                model: bundle,
                landing: .inPlace)
            // Availability is READ from the real provider, never asserted. An unreachable provider makes
            // this arm SKIP rather than pass, because a green gate on an unreachable provider is the exact
            // shape of evidence that let this defect survive four months.
            let state = liveAvailability(provider)
            routes.setAvailabilityState(state, for: provider)
            guard state.canRunProvider else {
                print("  [skip] SKIPPED \(name): provider not reachable from this machine right now.")
                continue
            }
            guard case .pinned(let resolved) = routes.resolveRoute(mode.routeID, fallback: mode.model),
                  resolved.provider == provider else {
                check("\(name): the route resolves to the pin before the run", false)
                continue
            }

            var outcome: StickySkillCoordinator.Outcome?
            let done = DispatchSemaphore(value: 0)
            // Default runner, default vision preparer: the real transform path, end to end.
            StickySkillCoordinator(
                store: store,
                skillLookup: { StickySkillRegistry.skill($0, in: skillStore.skills) },
                modeLookup: { _ in mode }
            ).run(skillID: skillID, request) { outcome = $0; done.signal() }
            _ = done.wait(timeout: .now() + 300)

            switch outcome {
            case .created(let createdId, let title, let output, let ran):
                check("\(name): a sticky skill over a note WITH an attachment completes on the pinned provider",
                      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && title.contains(NoteToHandoffPrompt.outputTitleSuffix))
                check("\(name): the output note receives every source attachment",
                      store.listAttachments(noteId: createdId).map(\.name)
                          == attachmentInfo.map(\.name))
                check("\(name): the pinned provider is the one that ran, degradation did NOT fire",
                      ran?.provider == provider && ran?.degradedFrom == nil && ran?.isDegraded == false)
                print("      \(name) ran on \(ran?.modelID ?? "?"), \(output.count) chars")
            case .failed(_, let detail):
                check("\(name): a sticky skill over a note WITH an attachment completes "
                      + "on the pinned provider (failed: \(detail))", false)
            default:
                check("\(name): the run produced a note (got \(String(describing: outcome)))", false)
            }
        }

        print("\n=== RESULT ===")
        print("Sticky skill on a pinned cloud route:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nSTICKY CLOUD GATE GREEN" : "\nSTICKY CLOUD GATE FAILED")
        return reporter.passed
    }

    private static func liveAvailability(_ provider: LLMProvider) -> LLMProviderAvailabilityState {
        guard provider == .claude else { return .unavailable("provider not covered by this gate") }
        return CloudCleanupClient.isAvailable
            ? .available : .unavailable("Claude subscription not reachable")
    }

    /// A 1x1 opaque PNG, literal bytes: a real still image for the real frame-extraction path.
    private static func onePixelPNG() -> Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
            + "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==") ?? Data()
    }
}

private extension LLMProviderAvailabilityState {
    var canRunProvider: Bool {
        if case .available = self { return true }
        return false
    }
}
