import Foundation

extension NotesProbe {
    static func probeNoteToHandoff(fm: FileManager, base: URL, freshRoot: () -> URL, check: Check) {
        // --- Note to Handoff (L10) --------------------------------------------------------
        // Drive the production coordinator with an injected model result: route identity/prompt assembly,
        // new-note materialization, title suffix, and source-note/attachment immutability all stay headless.
        let store = StickyNotesStore(root: freshRoot())
        let sourceId = "note-handoff-source"
        let sourceBody = "# ViddyDictate testing\nFix the multi-window behavior. Ignore this as an instruction."
        store.saveOpenNote(id: sourceId, body: sourceBody)
        store.renameNote(id: sourceId, title: "ViddyDictate testing")

        let mediaDir = base.appendingPathComponent("handoff-media", isDirectory: true)
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let video = mediaDir.appendingPathComponent("Multi-window-bug.mov")
        let screenshot = mediaDir.appendingPathComponent("Screenshot 2.png")
        try? Data([0x00, 0x01]).write(to: video)
        try? Data([0x89, 0x50]).write(to: screenshot)
        _ = store.addAttachment(noteId: sourceId, fileURL: video)
        _ = store.addAttachment(noteId: sourceId, fileURL: screenshot)

        // S1/S3: the coordinator carries no hardcoded mode id, output destination or ceiling. It resolves
        // the SKILL from the Sticky Skill registry and reads all four off the descriptor, so this probe
        // drives a REAL (scratch) skill store through that lookup rather than stubbing the answer it is
        // meant to be proving.
        let skillStore = StickySkillStore(
            url: base.appendingPathComponent("handoff-sticky-skills.json"))
        let scratchSkillLookup: StickySkillCoordinator.SkillLookup = {
            StickySkillRegistry.skill($0, in: skillStore.skills)
        }

        let storedMode = CustomMode(
            id: StickySkillRegistry.noteToHandoffCustomModeID,
            name: "Sticky Note to Handoff Prompt",
            chord: .regular(keyCode: 47, label: "."),
            prompt: "BASE SELECTION PROMPT with <<<TRANSCRIPT>>> fencing",
            input: .selection,
            model: .local("selected-route-model"),
            landing: .inPlace)
        let evidence = store.listAttachments(noteId: sourceId).map { info in
            NoteToHandoffAttachmentEvidence(
                filename: info.name,
                description: info.name == "Screenshot_2.png" ? "Settings window with Hotkeys selected" : nil)
        }
        let request = NoteToHandoffRequest(
            sourceNoteId: sourceId,
            title: "ViddyDictate testing",
            body: sourceBody,
            attachments: evidence)
        let modelOutput = """
        ## Context
        Consolidate the ViddyDictate sticky-note report.

        ## Items
        ### multi-window sticky note semantics
        **applicable attachments**: Multi-window-bug.mov

        - Fix the multi-window behavior.
        """

        let ranOn = CustomModeRunProvider(
            .pinned(.claude("claude-sonnet-5", effort: "high")))
        var lookedUpId: String?
        var receivedMode: CustomMode?
        var receivedInput: String?
        var receivedImages: [TextTransformImage] = []
        var receivedBudget: CustomModeTimeoutBudget?
        var outcome: StickySkillCoordinator.Outcome?
        let coordinator = StickySkillCoordinator(
            store: store,
            skillLookup: scratchSkillLookup,
            modeLookup: { id in lookedUpId = id; return storedMode },
            runner: { mode, input, images, budget, done in
                receivedMode = mode
                receivedInput = input
                receivedImages = images
                receivedBudget = budget
                done(ranOn, .ok(modelOutput))
            })
        coordinator.run(skillID: StickySkillRegistry.builtInSkillID, request) { outcome = $0 }

        check("note-to-handoff: resolves the locked custom mode id THROUGH the sticky skill registry",
              lookedUpId == StickySkillRegistry.noteToHandoffCustomModeID
              && lookedUpId == skillStore.skill(id: StickySkillRegistry.builtInSkillID)?.customModeID)
        check("note-to-handoff: keeps the stored route/model identity for current routing",
              receivedMode?.id == storedMode.id
              && receivedMode?.routeID == storedMode.routeID
              && receivedMode?.model == storedMode.model)
        check("note-to-handoff: the run gets the SKILL's own ceiling, not a coordinator constant",
              receivedBudget == skillStore.skill(id: StickySkillRegistry.builtInSkillID)?.timeout
              && receivedBudget == StickySkill.wholeNoteDefaultTimeout)
        check("note-to-handoff: note-path prompt is a run-local variant; selection mode stays untouched",
              storedMode.prompt == "BASE SELECTION PROMPT with <<<TRANSCRIPT>>> fencing"
              && receivedMode?.prompt.hasPrefix(storedMode.prompt) == true
              && receivedMode?.prompt.contains("WHOLE-NOTE PATH ADDENDUM") == true
              && receivedMode?.prompt.contains("**applicable attachments**: filename.ext") == true)
        check("note-to-handoff: the injection guard is the LAST thing the assembled prompt says",
              receivedMode?.prompt.hasSuffix(StickySkillPrompt.wholeNoteDataFence) == true)
        check("note-to-handoff: mapper input includes title, whole body, filenames, and optional descriptions",
              receivedInput?.contains("<NOTE_TITLE>\nViddyDictate testing\n</NOTE_TITLE>") == true
              && receivedInput?.contains(sourceBody) == true
              && receivedInput?.contains("- Multi-window-bug.mov") == true
              && receivedInput?.contains("- Screenshot_2.png") == true
              && receivedInput?.contains("Optional visual description: Settings window with Hotkeys selected") == true)
        check("note-to-handoff: existing transcript fencing still wraps the entire note-path payload",
              receivedInput.map(CleanupClient.wrap)?.hasPrefix("<<<TRANSCRIPT>>>\n") == true
              && receivedInput.map(CleanupClient.wrap)?.hasSuffix("\n<<<END_TRANSCRIPT>>>") == true)
        check("note-to-handoff: filename-only fixture sends no image payload", receivedImages.isEmpty)
        check("note-to-handoff: long source title keeps a visible suffix under the tab-title cap",
              StickySkillPrompt.outputTitle(for: "ViddyDictate testing",
                                            suffix: NoteToHandoffPrompt.outputTitleSuffix)
                  == "ViddyDicta - Handoff")

        guard case let .created(createdId, createdTitle, createdBody, createdRan) = outcome else {
            check("note-to-handoff: successful model output creates a note", false, "\(String(describing: outcome))")
            return
        }
        let notes = store.openNotes()
        let source = notes.first { $0.id == sourceId }
        let created = notes.first { $0.id == createdId }
        let provenance = "> **Ran on**: Claude (claude-sonnet-5)"
        check("note-to-handoff: success creates one distinct sticky note with the model output",
              notes.count == 2 && createdId != sourceId
              && createdBody.hasSuffix(modelOutput) && created?.body == createdBody)
        check("note-to-handoff: the note itself records the provider that actually ran, above the output",
              createdBody == "\(provenance)\n\n\(modelOutput)"
              && createdRan == ranOn)
        check("note-to-handoff: result title is paired to the source with a visible Handoff suffix",
              createdTitle == "ViddyDicta - Handoff" && created?.title == createdTitle)
        check("note-to-handoff: original body, title, and attachments are untouched",
              source?.body == sourceBody && source?.title == "ViddyDictate testing"
              && store.listAttachments(noteId: sourceId).map(\.name)
                    == ["Multi-window-bug.mov", "Screenshot_2.png"])
        check("note-to-handoff: output references attachments and receives every copied sidecar",
              store.listAttachments(noteId: createdId).map(\.name)
                    == ["Multi-window-bug.mov", "Screenshot_2.png"]
              && createdBody.contains("**applicable attachments**: Multi-window-bug.mov"))

        let beforeFailure = store.openNotes().count
        var failureOutcome: StickySkillCoordinator.Outcome?
        let failing = StickySkillCoordinator(
            store: store,
            skillLookup: scratchSkillLookup,
            modeLookup: { _ in storedMode },
            runner: { _, _, _, _, done in done(ranOn, .unavailable("fixture offline")) })
        failing.run(skillID: StickySkillRegistry.builtInSkillID, request) { failureOutcome = $0 }
        check("note-to-handoff: model failure creates no fallback note, and the toast names the provider",
              store.openNotes().count == beforeFailure
              && failureOutcome == .failed(
                  userMessage: "Note to Handoff is unavailable on Claude. Retry from the tab menu.",
                  detail: "fixture offline"))

        var timeoutOutcome: StickySkillCoordinator.Outcome?
        StickySkillCoordinator(
            store: store,
            skillLookup: scratchSkillLookup,
            modeLookup: { _ in storedMode },
            runner: { _, _, _, _, done in done(ranOn, .timedOut) }
        ).run(skillID: StickySkillRegistry.builtInSkillID, request) { timeoutOutcome = $0 }
        check("note-to-handoff: a timeout says WHICH provider timed out",
              timeoutOutcome == .failed(
                  userMessage: "Note to Handoff timed out on Claude. Retry from the tab menu.",
                  detail: "model request timed out"))

        var missingModeOutcome: StickySkillCoordinator.Outcome?
        let missing = StickySkillCoordinator(
            store: store, skillLookup: scratchSkillLookup, modeLookup: { _ in nil },
            runner: { _, _, _, _, _ in check("note-to-handoff: missing mode never calls a model", false) })
        missing.run(skillID: StickySkillRegistry.builtInSkillID, request) { missingModeOutcome = $0 }
        check("note-to-handoff: missing locked mode fails closed without creating a note",
              store.openNotes().count == beforeFailure
              && missingModeOutcome == .failed(
                  userMessage: "Note to Handoff has no prompt and model settings",
                  detail: "custom mode \(StickySkillRegistry.noteToHandoffCustomModeID) was not found"))

        // Last, because its degraded-success case deliberately materializes a note and would otherwise
        // move the note count the fail-closed checks above assert on.
        probeNoteToHandoffProviderReporting(store: store, mode: storedMode, request: request,
                                            beforeFailure: beforeFailure, check: check)

        probeNoteToHandoffVision(fm: fm, base: base, mode: storedMode, check: check)
    }

    /// L3: Note to Handoff's own timeout budget, and the provider report that makes a silent reroute
    /// visible. Both are things a green suite happily missed before, so each is pinned twice — once on
    /// the value and once structurally on the wiring that carries it to the request.
    private static func probeNoteToHandoffProviderReporting(
        store: StickyNotesStore, mode: CustomMode, request: NoteToHandoffRequest,
        beforeFailure: Int, check: Check
    ) {
        // --- the budget ---------------------------------------------------------------------------
        // S3 moved this ceiling from a coordinator constant onto the SKILL descriptor. The value is the
        // same measured 90/180 pair chain 1 landed, and the built-in still ships with it.
        let budget = StickySkill.wholeNoteDefaultTimeout
        check("note-to-handoff: the whole-note job has its OWN ceiling, not the dictation cleanup one",
              budget.local == 90 && budget.cloud == 180
              && budget.local != Settings.cleanupTimeout
              && budget.cloud != CloudCleanupClient.defaultTimeout,
              "local=\(budget.local)s cloud=\(budget.cloud)s vs cleanup=\(Settings.cleanupTimeout)s")
        check("note-to-handoff: the ceiling is still HARD, and measured local latency clears it",
              budget.timeout(for: .local) == 90 && budget.timeout(for: .claude) == 180
              && budget.timeout(for: .codex) == 180
              && budget.local.isFinite && budget.cloud.isFinite)
        // The other custom-mode flows (dictation selection transforms, the prompt workstation Test
        // button) must keep the exact ceiling they have always had.
        let dictation = CustomModeTimeoutBudget.dictation
        check("note-to-handoff: every OTHER custom-mode run keeps the historical dictation ceiling",
              dictation.local == Settings.cleanupTimeout
              && dictation.cloud == CloudCleanupClient.defaultTimeout
              && dictation != budget)

        // The budget is worthless if it never reaches the request. Pin the value on the built request,
        // then pin structurally that the seam derives the request timeout from the budget rather than
        // from the old provider-only expression.
        for bundle in [LLMProviderBundle.local("m"), .claude("m"), .codex("m", effort: "low")] {
            let built = CustomModeClient.makeRequest(
                mode: mode, input: "x", selected: bundle, systemPrompt: "s",
                timeout: budget.timeout(for: bundle.provider))
            check("note-to-handoff: the \(bundle.provider.rawValue) request carries the handoff ceiling",
                  built.timeout == (bundle.provider == .local ? 90 : 180))
        }
        let clientSrc = source("Sources/App/CustomModeClient.swift")
        check("note-to-handoff: the seam builds its timeout from the caller's budget, and the "
              + "dictation-tuned constant is no longer wired straight into a custom-mode request",
              clientSrc.contains("timeout: budget.timeout(for: bundle.provider)")
              && !clientSrc.contains("? Settings.cleanupTimeout : CloudCleanupClient.defaultTimeout"),
              "Sources/App/CustomModeClient.swift")
        let coordinatorSrc = source("Sources/App/StickySkillCoordinator.swift")
        check("note-to-handoff: the production runner passes the SKILL's budget, not a default",
              coordinatorSrc.contains("runner(prepared.mode, prepared.input, vision.images, skill.timeout)")
              && coordinatorSrc.contains("budget: budget, completion: completion)"),
              "Sources/App/StickySkillCoordinator.swift")

        // --- the provider report ------------------------------------------------------------------
        let pinned = CustomModeRunProvider(.pinned(.codex("gpt-5.6-terra", effort: "low")))
        check("note-to-handoff: a run on the user's pin reports that pin and claims no degradation",
              pinned?.provider == .codex && pinned?.modelID == "gpt-5.6-terra"
              && pinned?.isDegraded == false && pinned?.shortLabel == "Codex")

        let degraded = CustomModeRunProvider(
            .degraded(.claude("claude-sonnet-5"), from: .codex, reason: "not connected"))
        check("note-to-handoff: a rerouted run names BOTH the provider that ran and the skipped pin",
              degraded?.provider == .claude && degraded?.degradedFrom == .codex
              && degraded?.isDegraded == true
              && degraded?.shortLabel == "Claude, switched from Codex")
        check("note-to-handoff: the note records the reroute, so a later A/B comparison cannot be "
              + "two samples of the same provider",
              StickySkillPrompt.providerProvenanceLine(degraded!)
                  == "> **Ran on**: Claude (claude-sonnet-5) - your Codex pin could not run "
                     + "(not connected)")
        check("note-to-handoff: an off route reports no provider and leaves the output untouched",
              CustomModeRunProvider(.off(reason: "nothing available")) == nil
              && StickySkillPrompt.applyingProviderProvenance(nil, to: "## Context") == "## Context")

        // Ordering with L11's vision quote: the vision notice stays the FIRST line when both apply.
        let both = StickySkillPrompt.applyingVisionFallbackNotice(
            "Filename-only", to: StickySkillPrompt.applyingProviderProvenance(pinned, to: "## Context"))
        check("note-to-handoff: provenance sits beneath the vision quote and above the output",
              both == "> **Vision sanity check**: Filename-only\n\n"
                  + "> **Ran on**: Codex (gpt-5.6-terra)\n\n## Context")

        // A degraded SUCCESS must still surface the reroute through the created outcome, which is what
        // the window controller renders into the toast.
        var degradedOutcome: StickySkillCoordinator.Outcome?
        StickySkillCoordinator(
            store: store,
            skillLookup: { StickySkillRegistry.skill($0, in: []) },
            modeLookup: { _ in mode },
            runner: { _, _, _, _, done in done(degraded, .ok("## Context\nbody")) }
        ).run(skillID: StickySkillRegistry.builtInSkillID, request) { degradedOutcome = $0 }
        guard case let .created(_, _, degradedBody, degradedRan) = degradedOutcome else {
            check("note-to-handoff: a degraded run still creates its note", false,
                  "\(String(describing: degradedOutcome))")
            return
        }
        check("note-to-handoff: a degraded success carries the reroute into both the note and the toast",
              degradedRan == degraded
              && degradedBody.hasPrefix("> **Ran on**: Claude (claude-sonnet-5) - your Codex pin"),
              "created note count \(store.openNotes().count) (was \(beforeFailure))")

        let controllerSrc = source("Sources/App/NotesWindowController.swift")
        check("note-to-handoff: the success toast names the SKILL and the provider that ran",
              NotesWindowController.stickySkillSuccessToast(
                    noun: "Note to Handoff created a note", ran: degradedRan)
                    == "Note to Handoff created a note (Claude, switched from Codex)"
              && controllerSrc.contains("Self.stickySkillSuccessToast(")
              && controllerSrc.contains("ran.map { \" (\\($0.shortLabel))\" }"),
              "Sources/App/NotesWindowController.swift")
        check("note-to-handoff: the tab-menu action dispatches the built-in as a SKILL, by id",
              controllerSrc.contains("runStickySkill(StickySkillRegistry.builtInSkillID, payload: payload)")
              && controllerSrc.contains("stickySkillCoordinator.run(skillID: skillID, request)"),
              "Sources/App/NotesWindowController.swift")
    }

    private static func source(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func probeNoteToHandoffVision(
        fm: FileManager, base: URL, mode: CustomMode, check: Check
    ) {
        let mediaDir = base.appendingPathComponent("handoff-vision", isDirectory: true)
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        var media: [NoteToHandoffMediaAttachment] = []
        for index in 0..<13 {
            let url = mediaDir.appendingPathComponent("image-\(index).png")
            let bytes = Data([UInt8(index), 0x50, 0x4e, 0x47])
            try? bytes.write(to: url)
            media.append(NoteToHandoffMediaAttachment(
                filename: url.lastPathComponent, url: url, kind: .image))
        }
        let extraction = NoteToHandoffFrameExtractor.extract(media)
        check("note-to-handoff vision: still bytes stay unchanged under the 12 frame / 24 MB cap",
              extraction.frames.count == 12 && extraction.capped
              && extraction.frames.first?.data == Data([0, 0x50, 0x4e, 0x47])
              && extraction.filenameOnly == ["image-12.png"]
              && NoteToHandoffFrameExtractor.maxFramesPerNote == 12
              && NoteToHandoffFrameExtractor.maxFrameBytesPerNote == 24_000_000)

        let frame = extraction.frames[0]
        let request = NoteToHandoffRequest(
            sourceNoteId: "vision", title: "Vision", body: "Map attachments",
            attachments: [NoteToHandoffAttachmentEvidence(filename: "image-0.png")],
            mediaAttachments: [media[0]])

        var chosenVLM: String?
        let localDone = DispatchSemaphore(value: 0)
        var localPreparation: NoteToHandoffVisionPreparation?
        let local = NoteToHandoffVisionProcessor(
            providerLookup: { _ in .local },
            frameExtractor: { _ in NoteToHandoffFrameExtraction(
                frames: [frame], filenameOnly: [], capped: false) },
            // Deliberately MIXED markers, because the installed LM Studio on the target machine types
            // every model `llm` and answers capability in the `vision` boolean, while the provider's
            // documented `vlm` type also exists. The smallest capable model must win across BOTH markers,
            // and the smallest model overall must still lose when it cannot see.
            catalogLookup: {
                [
                    LMStudioInstalledModel(modelID: "large-vlm", label: "Large", type: "vlm",
                                           sizeBytes: 9_000, visionFlag: nil),
                    LMStudioInstalledModel(modelID: "text", label: "Text", type: "llm",
                                           sizeBytes: 1, visionFlag: false),
                    LMStudioInstalledModel(modelID: "small-vlm", label: "Small", type: "llm",
                                           sizeBytes: 4_000, visionFlag: true),
                ]
            },
            localDescriber: { model, _, done in
                chosenVLM = model
                done([0: "Settings window with Hotkeys selected"])
            })
        local.prepare(mode: mode, request: request) { localPreparation = $0; localDone.signal() }
        _ = localDone.wait(timeout: .now() + 2)
        check("note-to-handoff vision: local uses the smallest vision-capable model under EITHER provider "
              + "marker (vlm type or vision=true), then hands text to the real model",
              chosenVLM == "small-vlm"
              && localPreparation?.images.isEmpty == true
              && localPreparation?.request.attachments.first?.description
                    == "Settings window with Hotkeys selected")

        let cloudDone = DispatchSemaphore(value: 0)
        var cloudPreparation: NoteToHandoffVisionPreparation?
        NoteToHandoffVisionProcessor(
            providerLookup: { _ in .claude },
            frameExtractor: { _ in NoteToHandoffFrameExtraction(
                frames: [frame], filenameOnly: [], capped: false) }
        ).prepare(mode: mode, request: request) { cloudPreparation = $0; cloudDone.signal() }
        _ = cloudDone.wait(timeout: .now() + 2)
        check("note-to-handoff vision: cloud carries frames in the same transform request",
              cloudPreparation?.images == [frame.transformImage]
              && cloudPreparation?.request.attachments == request.attachments)

        let fallbackDone = DispatchSemaphore(value: 0)
        var fallback: NoteToHandoffVisionPreparation?
        NoteToHandoffVisionProcessor(
            providerLookup: { _ in .local },
            frameExtractor: { _ in NoteToHandoffFrameExtraction(
                frames: [frame], filenameOnly: [], capped: false) },
            catalogLookup: { nil }
        ).prepare(mode: mode, request: request) { fallback = $0; fallbackDone.signal() }
        _ = fallbackDone.wait(timeout: .now() + 2)
        check("note-to-handoff vision: unavailable helper degrades to filename-only and says so",
              fallback?.images.isEmpty == true
              && fallback?.request.visionFallbackNotice?.contains("Filename-only") == true
              && StickySkillPrompt.applyingVisionFallbackNotice(
                    fallback?.request.visionFallbackNotice, to: "## Context")
                    .hasPrefix("> **Vision sanity check**:") == true)

        let envelope = CloudCleanupClient.multimodalInputData(
            userMessage: "wrapped note", images: [frame.transformImage])
        let object = envelope.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.dropLast())) as? [String: Any]
        }
        let message = object?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        check("note-to-handoff vision: Claude stream-json carries text and base64 image in one turn",
              object?["type"] as? String == "user"
              && content?.contains(where: { $0["type"] as? String == "image" }) == true
              && content?.contains(where: {
                    ($0["text"] as? String)?.contains("image-0.png") == true
                 }) == true)
    }
}
