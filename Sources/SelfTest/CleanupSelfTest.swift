import Foundation
import AppKit

/// The headless `--selftest` seam (build-spec inner loop, step 2-4).
///
/// Two layers:
///  1. **Unit coverage** of the non-audio decision logic — the chord/mode logic, state-at-release,
///     the two-tier undo routing, the LM-down / timeout / bad-output fallback routing, the
///     confident-or-clipboard gate, and `cleanRepeats`. No audio, no event tap, no UI.
///  2. **The golden-sample output test** — the 7 hand-authored raw samples run through the REAL
///     compiled `CleanupClient` -> LM Studio -> cleaned output, then graded for the green bar's
///     critical failures with deterministic detectors AND an LLM judge.
///
/// Exits 0 only when every unit test passes AND there are zero critical failures across the set.
enum CleanupSelfTest {

    // MARK: golden fixtures (raw + the user's hand-cleaned target, from summarize-golden-samples.md)

    struct Golden { let id: String; let raw: String; let target: String }

    static let goldens: [Golden] = [
        Golden(id: "1-heavy",
            raw: "You're being a little bit short with your recommendation here. I probably mostly agree with you on these points, but let's slow down a little bit and go piece by piece. I mean, for me, the definition of done looks like hold down right option to start dictation. if I tap on question mark at any point rather than pasting the raw dictation into the text field it's going to take the raw dictation pass it to an LMStudio model which will clean it up like you said clean up the rambling, repetition, stutter and we may have to tweak this a little bit to get good results but in general the the summary version via the question mark hotkey um i don't know i expect to use it a lot the goal here is that i will be able to dictate more casually and not have to worry about like stuttering or anything like that and the output will still be good um you know using the ll the local llm to be able to clean up the prompt a little bit is going to make it so that I'm using less tokens on the token input so it'll save me some cost not a ton but it'll that you know if I'm doing this a lot then that compounds over time so it's worth it to build this tool because the local LLM compute is free does that all make sense um so i'm thinking that question mark and version one is basically going to be just basic cleanup you know uh i'll give you an example of what i'm thinking here with this exact dictation uh what you're reading right now is my raw dictation and I'm going to make a copy of this dictation below and clean up some of the things that I think ought to be cleaned up. To be clear, I'm not as concerned about cleaning up, capitalizing the first letter in a sentence or getting the grammar perfect. It's more about clarity. and also reducing wordiness but it I want it I want to reduce work I don't want it to cut massive sections because it thinks because my cheap and fast model thinks that I've worded it poorly if that makes sense so here's the example.",
            target: "You're being a little bit short with your recommendation here. ... uses '...' for pauses, removes fillers and false starts, keeps every point."),
        Golden(id: "2-light",
            raw: "I think you interpreted this exactly how I wanted, and you're understanding me here really well. So, I agree with everything you're saying here. The goal of this very first V1 is not to massively clean things up, and you've understood that very well. I'm thinking that throughout the rest of this grill me session, I will probably continue to dictate casually as I do. And before I send you each prompt, I'll just give you a copied version in quotations and give you basically another test sample to go on. so that we can try and run a batch of tests once this tool is actually complete based on these test samples that I'm going to generate for you during this grill session. So let's go ahead and continue the grill and note these tester prompts as we go.",
            target: "Lighter touch: drop 'here' x2, a stray 'So,', collapse the repeated 'give you'. No substantive content dropped."),
        Golden(id: "3-medium",
            raw: "I'm feeling like we should add something very obvious to indicate that it registered, like maybe a little question mark bubble or a little box above the UI that shows the hotkey that was pressed. make it look like the Mac keyboard perhaps not like the actual keyboard because the question mark key has the question mark and the forward slash rather give the outline of the box the same shape as the MacBook keyboard, the rectangle with lightly rounded corners and, you know, guess at the aspect ratio of the square and put a question mark in it. And then in text next to that, we say summary or something to indicate what the mode is. Because remember that in the future we plan to make the hotkeys editable. So the hotkey icon that's getting pressed may change. But the function of it, the summarize, it's not really summary is it? It's more like... Clean up. What would you suggest calling it, perhaps?",
            target: "Filler removal, run-on splitting, drop the abandoned 'But the function of it, the summarize,' self-interruption."),
        Golden(id: "4-medium",
            raw: "You know, now that I'm thinking about it, this specific version that we're making right now, maybe it doesn't want to be like a hotkey. I'm thinking that this specific version should be more of a toggle. So when you hit question mark while option is being held down, that should toggle on the cleanup mode. and remind me we're not using whisper flow here right whisper flow is like a service or an app off of the internet right so we do need to build auto cleanup into this app am i correct in that reading.",
            target: "Filler removal, one reorder, question marks added. No substantive content dropped."),
        Golden(id: "5-medium",
            raw: "i think default off is good. I also think that we should take a moment here to think about like how, what happens if I dictate something and LM Studio freaked out, so the dictation is crazy and I need to just paste the original audio instead. I'm thinking that basically the history tab in the settings is my path to recovery. If something like that happens and I need to restore the pre-LM Studio transcription, I can always just go up to settings, go to the history tab, and grab the original transcript. but we need to make sure we build it that way like the history tab almost needs to have like copy original or copy cleaned up version does that make sense? Grill me about this restoration path a little bit more, please.",
            target: "Filler removal; 'freaked out'->'freaks out'; quotes added. (Do not over-trim 'a little bit more' to 'a more'.)"),
        Golden(id: "6-floor",
            raw: "I'm agreeing with you here on everything you're saying and I think that my immediate one key reversal should be right option plus Z. Basically, if I hold down the right option and hit Z at any time, it shouldn't do any kind of transcription or save any kind of transcription from the audio that it may briefly pick up. And instead, it functions as my Command Z, but specifically for the Viddy Dictate app.",
            target: "Lightest sample: a single filler-phrase trim ('agreeing with you here on everything'->'agreeing with everything'). Near-zero edit is acceptable."),
        Golden(id: "7-medium",
            raw: "I'm leaning towards immediately after a cleanup lands. Basically, I'm leaning towards the recommended behavior that you're suggesting here. if I dictate something, see it land, and decide I want to go back to raw rather than the auto cleanup version. I should be able to type option plus Z and it will just automatically undo whatever I just did or not it will automatically replace the text that I just pasted with the original text If it can't identify that text field, then yes, original copy, paste, or I feel like the wording should be original transcription on clipboard paste to use. Or command V to use. And not literally command, but like the command symbol that Max use. Does that sound about right?",
            target: "Collapse the redundant 'I'm leaning towards' restatement; drop abandoned 'or not'; split run-ons. (Do not expect 'Max'->'Macs' — that's correction-dictionary, not cleanup.)"),
    ]

    // MARK: entry point

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate Cleanup v2 — selftest ===")
        print("model=\(Settings.cleanupModel)  endpoint=\(Settings.cleanupEndpoint.absoluteString)")
        print("live-path timeout=\(Settings.cleanupTimeout)s  (selftest uses a generous timeout)\n")

        let unitOK = runUnitTests()
        let clipboardOK = runClipboardTests()
        let (goldenOK, summary) = runGoldenTests()

        let judgeFlagged = summary.filter { !$0.judgeCriticals.isEmpty }.map { $0.id }
        print("\n=== RESULT ===")
        print("unit tests:      \(unitOK ? "PASS" : "FAIL")")
        print("clipboard layer: \(clipboardOK ? "PASS" : "FAIL")")
        print("golden bar:      \(goldenOK ? "PASS (zero deterministic critical failures)" : "FAIL (deterministic critical failures present)")")
        print("gate = unit tests + clipboard layer + deterministic detectors. LLM judge is ADVISORY (too noisy to gate).")
        if !judgeFlagged.isEmpty {
            print("advisory judge flagged (review manually, NOT a gate): \(judgeFlagged.joined(separator: ", "))")
        }
        writeSummary(unitOK: unitOK, clipboardOK: clipboardOK, goldenOK: goldenOK, samples: summary)
        let green = unitOK && clipboardOK && goldenOK
        print(green ? "\nGREEN BAR CLEARED ✅" : "\nGREEN BAR NOT CLEARED ❌")
        return green
    }

    // MARK: unit coverage

    private static func runUnitTests() -> Bool {
        print("--- unit coverage (no audio / no UI) ---")
        let reporter = SelfTestReporter()

        checkCleanupStateBasics(reporter.record)
        checkHistoryAndAsciiBasics(reporter.record)
        checkUndoAndFallbackLogic(reporter.record)
        checkPromptPrepAndHotkeys(reporter.record)
        checkCorrectionDictionary(reporter.record)
        checkStickyNotesContracts(reporter.record)
        checkOneShotDescriptors(reporter.record)
        checkCriticalFailureDetectors(reporter.record)

        print("  -> unit: \(reporter.passed ? "PASS" : "FAIL")\n")
        return reporter.passed
    }

    private static func checkCleanupStateBasics(_ check: (String, Bool) -> Void) {
        // CleanupState: persistent toggle, default off, data-driven labels.
        let reg = CleanupState.shared
        check("registry default OFF (Raw)", reg.cleanupEnabled == false && reg.current.id == "raw")
        check("toggle -> Cleanup", reg.toggleCleanup() == true && reg.current.id == "cleanup")
        // Assert the level->label invariant against the enum (not reg.cleanup.label, which reflects
        // the persisted live slider level — and whose setter persists, so we must not mutate it here).
        check("cleanup badge label/glyph", CleanupLevel.cleanup.label == "Cleanup"
            && CleanupLevel.tighten.label == "Tighten" && CleanupLevel.summarize.label == "Summarize"
            && reg.cleanup.glyph == "?")
        check("toggle -> Raw", reg.toggleCleanup() == false && reg.current.id == "raw")
        check("raw mode does not transform", reg.raw.transformsText == false)
        check("cleanup mode transforms", reg.cleanup.transformsText == true)
    }

    private static func checkHistoryAndAsciiBasics(_ check: (String, Bool) -> Void) {
        // HistoryMode taxonomy (review item 2): raw values are the exact legacy history.json strings, so
        // existing entries keep decoding and the History window keeps displaying them.
        check("history mode raw values match legacy strings",
              HistoryMode.raw.rawValue == "raw" && HistoryMode.cleanup.rawValue == "cleanup"
              && HistoryMode.cleanupSelection.rawValue == "prompt-prep" && HistoryMode.email.rawValue == "email"
              && HistoryMode.search.rawValue == "search" && HistoryMode.searchGemini.rawValue == "search-gemini")

        // ASCII punctuation normalizer (the hard plain-ASCII guarantee on cleanup output).
        check("ascii normalizer maps typographic punctuation",
            CleanupClient.asciiPunctuationNormalized("a\u{2014}b \u{201C}c\u{201D} d\u{2026} e\u{2019}s")
                == "a - b \"c\" d... e's")
        check("ascii normalizer leaves plain ASCII untouched",
            CleanupClient.asciiPunctuationNormalized("plain - text, with \"quotes\" and... dots")
                == "plain - text, with \"quotes\" and... dots")
    }

    private static func checkUndoAndFallbackLogic(_ check: (String, Bool) -> Void) {
        // Two-tier undo routing.
        check("undo none when no pending", CleanupLogic.undoTier(hasPending: false, canRevertInPlace: true, ageSeconds: 1) == .none)
        check("undo in-place when fresh push-to-talk paste", CleanupLogic.undoTier(hasPending: true, canRevertInPlace: true, ageSeconds: 2) == .inPlace)
        check("undo clipboard when stale", CleanupLogic.undoTier(hasPending: true, canRevertInPlace: true, ageSeconds: 999) == .clipboard)
        check("undo clipboard when not revertible (locked/captured-target)", CleanupLogic.undoTier(hasPending: true, canRevertInPlace: false, ageSeconds: 1) == .clipboard)

        // Fallback routing (down / timeout / bad output all collapse to raw).
        check("ok -> cleaned", CleanupLogic.landing(for: .ok("x")) == .cleaned)
        check("unavailable -> raw fallback", CleanupLogic.landing(for: .unavailable("down")) == .rawFallback)
        check("timeout -> raw fallback", CleanupLogic.landing(for: .timedOut) == .rawFallback)
        check("bad output -> raw fallback", CleanupLogic.landing(for: .badOutput("empty")) == .rawFallback)

        // Undo-eligibility: only a DISTINCT cleaned/transformed version is revertable.
        check("revertable when cleaned differs from raw", CleanupLogic.isRevertable(raw: "hello world", cleaned: "Hello, world."))
        check("not revertable when cleaned equals raw", !CleanupLogic.isRevertable(raw: "same", cleaned: "same"))
        check("not revertable when no cleaned (raw passthrough)", !CleanupLogic.isRevertable(raw: "raw", cleaned: nil))

        // STT repeat-collapse net (unchanged from v1, but covered).
        check("cleanRepeats collapses 3x", CleanupLogic.cleanRepeats("hello hello hello world") == "hello world")
        check("cleanRepeats keeps 2x", CleanupLogic.cleanRepeats("no no") == "no no")
    }

    private static func checkPromptPrepAndHotkeys(_ check: (String, Bool) -> Void) {
        // Option+P prompt-prep input resolution: selection preferred, clipboard fallback, nil when blank.
        check("prompt-prep prefers selection", CleanupLogic.promptPrepInput(selection: "picked text", clipboard: "clip") == "picked text")
        check("prompt-prep falls back to clipboard when no selection", CleanupLogic.promptPrepInput(selection: nil, clipboard: "clip") == "clip")
        check("prompt-prep falls back to clipboard when selection blank", CleanupLogic.promptPrepInput(selection: "   \n", clipboard: "clip") == "clip")
        check("prompt-prep nil when both blank", CleanupLogic.promptPrepInput(selection: "  ", clipboard: "") == nil)
        check("prompt-prep nil when both nil", CleanupLogic.promptPrepInput(selection: nil, clipboard: nil) == nil)
        // Sticky default level is Tighten (the middle pick); the picker honors it exactly (no length gate).
        check("prompt-prep default level is Tighten", CleanupLevel.clamped(1) == .tighten && CleanupLevel.tighten.label == "Tighten")

        // Hotkey rebinding map (ADR 0003): defaults, conflict detection, restore.
        let defs = HotkeyMap.defaults()
        check("hotkey defaults: wakeup is right-Option modifier",
              defs.wakeup.isModifier && defs.wakeup.code == 0x40)
        check("hotkey defaults: lock=Space, email=M",
              defs.key(for: .lock) == .regular(keyCode: 49, label: "x")
              && defs.key(for: .email) == .regular(keyCode: 46, label: "y"))
        check("hotkey defaults: sticky notes=N",
              defs.key(for: .notes) == .regular(keyCode: 45, label: "x"))
        check("hotkey defaults: dictionary=D",
              defs.key(for: .dictionary) == .regular(keyCode: 2, label: "x"))
        check("hotkey lookup: keyCode 2 resolves to dictionary",
              defs.command(forKeyCode: 2) == .dictionary)
        // notes-bullseye BT2: the rebindable bullseye-toggle command defaults to B (keyCode 11).
        check("hotkey defaults: bullseye toggle=B",
              defs.key(for: .bullseyeToggle) == .regular(keyCode: 11, label: "x"))
        check("hotkey lookup: keyCode 11 resolves to bullseyeToggle",
              defs.command(forKeyCode: 11) == .bullseyeToggle)
        check("hotkey conflict: reassigning B (bullseye's key) to undo flags bullseyeToggle",
              defs.conflict(of: .regular(keyCode: 11, label: "B"), assigningTo: .command(.undo)) == .some(.command(.bullseyeToggle)))
        check("hotkey defaults: every command bound",
              HotkeyCommand.allCases.allSatisfy { defs.bindings[$0.rawValue] != nil })
        check("hotkey chord lookup by keycode", defs.command(forKeyCode: 44) == .cleanupToggle)
        check("hotkey conflict: reassigning Space (lock's key) to undo flags lock",
              defs.conflict(of: .regular(keyCode: 49, label: "Space"), assigningTo: .command(.undo)) == .some(.command(.lock)))
        check("hotkey conflict: a free key is free",
              defs.conflict(of: .regular(keyCode: 3, label: "F"), assigningTo: .command(.undo)) == nil)
        check("hotkey conflict: rebinding a slot to its own key is not a conflict",
              defs.conflict(of: .regular(keyCode: 49, label: "Space"), assigningTo: .command(.lock)) == nil)
        check("hotkey conflict: wakeup vs chord shares one namespace",
              defs.conflict(of: defs.wakeup, assigningTo: .command(.undo)) == .some(.wakeup))
        var mut = HotkeyMap.defaults()
        mut.assign(.regular(keyCode: 3, label: "F"), to: .command(.undo))
        check("hotkey assign + restore round-trips", mut.key(for: .undo).code == 3
              && { mut.restoreDefault(.command(.undo)); return mut.key(for: .undo).code == 6 }())
    }

    private static func checkCorrectionDictionary(_ check: (String, Bool) -> Void) {
        // Correction dictionary (ADR 0002) — Layer 1 hard-coded replacements.
        let hc = [CorrectionEntry(heard: "vidi dictate", intended: "ViddyDictate"),
                  CorrectionEntry(heard: "max", intended: "Macs")]
        check("hard-coded: case-insensitive, stored-casing output",
              CorrectionDictionary.applyHardCoded("I love Vidi Dictate so much", entries: hc)
                == "I love ViddyDictate so much")
        check("hard-coded: whole-word only (no substring hits)",
              CorrectionDictionary.applyHardCoded("maximum maxed", entries: hc) == "maximum maxed")
        check("hard-coded: word boundary replace",
              CorrectionDictionary.applyHardCoded("two max here", entries: hc) == "two Macs here")
        check("hard-coded: longest phrase wins / literal (no regex metachars)",
              CorrectionDictionary.applyHardCoded("a.b", entries: [CorrectionEntry(heard: "a.b", intended: "Z")]) == "Z")
        check("hard-coded: empty list is a no-op",
              CorrectionDictionary.applyHardCoded("untouched", entries: []) == "untouched")
        check("hard-coded: blank rows ignored",
              CorrectionDictionary.applyHardCoded("x", entries: [CorrectionEntry(heard: "", intended: "y")]) == "x")

        // Layer 2 — context glossary suffix.
        check("context glossary: empty when no entries",
              CorrectionDictionary.contextGlossarySuffix([]) == "")
        let ctx = [CorrectionEntry(heard: "session closed", intended: "session close")]
        let suffix = CorrectionDictionary.contextGlossarySuffix(ctx)
        check("context glossary: contains the pair + a glossary header",
              suffix.contains("\"session closed\" -> \"session close\"") && suffix.contains("CORRECTION GLOSSARY"))

        // Layer 0 — whisper bias derivation (both columns' intended forms, context-aware last).
        check("whisper bias: empty when both columns empty",
              CorrectionDictionary.whisperBias(hardCoded: [], contextAware: []) == "")
        let bias = CorrectionDictionary.whisperBias(hardCoded: hc, contextAware: ctx)
        check("whisper bias: includes both columns' intended forms",
              bias.contains("ViddyDictate") && bias.contains("Macs") && bias.contains("session close"))
        check("whisper bias: context-aware forms ordered last (tail = highest weight)",
              bias.range(of: "session close")!.lowerBound > bias.range(of: "ViddyDictate")!.lowerBound)
        check("whisper bias: dedupes intended forms",
              CorrectionDictionary.whisperBias(
                hardCoded: [CorrectionEntry(heard: "a", intended: "Foo"), CorrectionEntry(heard: "b", intended: "foo")],
                contextAware: []).components(separatedBy: "Foo").count == 2)
    }

    private static func checkStickyNotesContracts(_ check: (String, Bool) -> Void) {
        // Sticky Notes (Option+N): pure store / agent-contract coverage.
        check("sticky title: first non-empty line, markdown stripped",
              StickyNotesStore.title(for: "\n# Groceries\n- milk") == "Groceries")
        check("sticky title: Untitled fallback",
              StickyNotesStore.title(for: " \n\t") == "Untitled")
        let aggregate = StickyNotesStore.aggregateMarkdown(notes: [
            StickyNoteWire(id: "note-a", body: "# Groceries\n- milk\n- eggs", title: "Groceries"),
            StickyNoteWire(id: "note-b", body: "Phosphor CSS idea\nuse green borders", title: "Phosphor CSS idea"),
        ], activeId: "note-b")
        check("sticky aggregate: comment header, no frontmatter",
              aggregate.hasPrefix("<!-- Auto-generated by ViddyDictate. Read-only. Open sticky notes, in tab order. -->\n\n## Groceries"))
        check("sticky aggregate: active marker + raw markdown body",
              aggregate.contains("## Phosphor CSS idea (active)\n\nPhosphor CSS idea\nuse green borders"))

        // Crash-reload active-tab restore (queued-insertion misfile fix): keep the pre-crash active tab
        // when it still exists, else fall back to the first tab.
        check("sticky active-restore: keeps last-active when still open",
              NotesTransientTabs.resolveActiveId(lastActive: "note-b", noteIds: ["note-a", "note-b"]) == "note-b")
        check("sticky active-restore: falls back to first when last-active is gone",
              NotesTransientTabs.resolveActiveId(lastActive: "note-x", noteIds: ["note-a", "note-b"]) == "note-a")
        check("sticky active-restore: falls back to first when none known",
              NotesTransientTabs.resolveActiveId(lastActive: nil, noteIds: ["note-a", "note-b"]) == "note-a")
        check("sticky active-restore: nil when no notes",
              NotesTransientTabs.resolveActiveId(lastActive: "note-a", noteIds: []) == nil)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-sticky-notes-selftest-\(UUID().uuidString)", isDirectory: true)
        let stickyStore = StickyNotesStore(root: tmp)
        stickyStore.saveOpenNote(id: "note-test", body: "   \n")
        check("sticky store: empty note is lazy",
              stickyStore.openNotes().isEmpty
              && !FileManager.default.fileExists(atPath: tmp.appendingPathComponent("note-test.md").path))
        stickyStore.saveOpenNote(id: "note-test", body: "# Groceries\n- milk")
        check("sticky store: non-empty note materializes",
              stickyStore.openNotes().first?.title == "Groceries")
        stickyStore.renameNote(id: "note-test", title: "Errands")
        check("sticky store: renamed note title overrides first line",
              stickyStore.openNotes().first?.title == "Errands")
        stickyStore.rewriteAggregate(tabOrder: ["note-test"], activeId: "note-test")
        let aggregateURL = tmp.appendingPathComponent("_open-notes.md")
        let aggregateOnDisk = (try? String(contentsOf: aggregateURL, encoding: .utf8)) ?? ""
        check("sticky store: writes open-notes aggregate",
              aggregateOnDisk.contains("## Errands (active)\n\n# Groceries\n- milk"))
        stickyStore.renameNote(id: "note-test", title: "")
        check("sticky store: blank rename returns to body-derived title",
              stickyStore.openNotes().first?.title == "Groceries")
        stickyStore.closeNote(id: "note-test", body: "# Groceries\n- milk")
        let historyRows = stickyStore.history(retention: .oneDay)
        check("sticky store: close soft-deletes to history",
              stickyStore.openNotes().isEmpty && historyRows.first?.title == "Groceries")
        let restored = historyRows.first.flatMap { stickyStore.restoreHistory(id: $0.id) }
        check("sticky store: restore reopens note",
              restored?.body == "# Groceries\n- milk" && stickyStore.openNotes().count == 1)
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func checkOneShotDescriptors(_ check: (String, Bool) -> Void) {
        // One-shot mode descriptors (item-4 piece 3): the shared scaffold pieces 4-6 migrate onto.
        // Pure classification + gate coverage; nothing is wired onto it yet (behavior-preserving).
        check("one-shot: cleanup-selection classification",
              OneShotMode.cleanupSelection.historyMode == .cleanupSelection
              && OneShotMode.cleanupSelection.input == .selection
              && OneShotMode.cleanupSelection.landing == .inPlace(wireUndo: false))
        check("one-shot: email classification",
              OneShotMode.email.historyMode == .email
              && OneShotMode.email.input == .transcriptOrSelection(minWords: 3)
              && OneShotMode.email.landing == .inPlace(wireUndo: true))
        check("one-shot: search-local classification",
              OneShotMode.searchLocal.historyMode == .search
              && OneShotMode.searchLocal.input == .transcript(minWords: 2)
              && OneShotMode.searchLocal.landing == .nonDestructive)
        check("one-shot: search-gemini classification",
              OneShotMode.searchGemini.historyMode == .searchGemini
              && OneShotMode.searchGemini.input == .transcript(minWords: 2)
              && OneShotMode.searchGemini.landing == .nonDestructive)
        // minWords floors match the modes they will replace.
        check("one-shot: minWords floors (email 3, search 2, selection none)",
              OneShotMode.email.minWords == 3 && OneShotMode.searchLocal.minWords == 2
              && OneShotMode.searchGemini.minWords == 2 && OneShotMode.cleanupSelection.minWords == nil)
        // Selection-only mode has no transcript take, so its word gate is vacuously false at any count.
        check("one-shot: selection mode word gate vacuously false",
              !OneShotMode.cleanupSelection.clearsWordGate(wordCount: 0)
              && !OneShotMode.cleanupSelection.clearsWordGate(wordCount: 50))
        // Bridge assertion: the descriptor gate is a faithful drop-in for the current per-mode gates at
        // their shared thresholds, so pieces 5-6 migrate without changing behavior.
        check("one-shot: email gate matches isDictationEmail across the boundary",
              (0...6).allSatisfy { OneShotMode.email.clearsWordGate(wordCount: $0)
                                   == CleanupLogic.isDictationEmail(wordCount: $0) })
        check("one-shot: search gate matches isSearchQuestion across the boundary",
              (0...6).allSatisfy { OneShotMode.searchLocal.clearsWordGate(wordCount: $0)
                                   == CleanupLogic.isSearchQuestion(wordCount: $0) })
        // Cleanup-selection migration (item-4 piece 4): the Option+P flow now reads its identity + route
        // constants from the descriptor (finishPrep's History row + undo wiring + log noun, promptPrep's
        // picker label). Pin the exact values it depends on so a later descriptor edit that drifted them
        // is a visible test failure rather than a silent change to the mode's History row / undo / labels.
        check("one-shot: cleanup-selection carries prompt-prep's identity + route constants",
              OneShotMode.cleanupSelection.id == "prompt-prep"
              && OneShotMode.cleanupSelection.label == "Cleanup selection"
              && OneShotMode.cleanupSelection.historyMode == .cleanupSelection)
        // Email migration (item-4 piece 5): the dual-mode Option+M flow now reads its identity + route
        // constants from the descriptor (finishEmail's History row + smart-undo wiring + log noun,
        // email/emailFromDictation/emailFromSelection's log/note noun, and the dictation-vs-selection
        // word gate). Pin the exact values it depends on so a later descriptor edit that drifted them is
        // a visible test failure rather than a silent change to the mode's History row / undo / labels /
        // dual-mode gate. (The gate == isDictationEmail equality is the bridge assert just above.)
        check("one-shot: email carries its identity + route constants",
              OneShotMode.email.id == "email"
              && OneShotMode.email.label == "email"
              && OneShotMode.email.historyMode == .email
              && OneShotMode.email.minWords == 3)
        // Search migration (item-4 piece 6): the dual-engine Option+L / Option+G flow now reads its
        // identity + route constants from the resolved descriptor (engine == .local ? .searchLocal :
        // .searchGemini) - finishSearch's History row, the search/note/log noun (label), and the
        // dictate-the-question word gate (drop-in for isSearchQuestion, the bridge assert above). Unlike
        // cleanup/email, search lands NON-DESTRUCTIVE: it keeps its bespoke answer-note/HUD landing
        // rather than the shared landInPlaceTransform tail. The classification checks above pin both
        // engines' `.nonDestructive` landing; these checks pin their remaining exact values.
        check("one-shot: search-local carries its identity + route constants",
              OneShotMode.searchLocal.id == "search-local"
              && OneShotMode.searchLocal.label == "search"
              && OneShotMode.searchLocal.historyMode == .search
              && OneShotMode.searchLocal.minWords == 2)
        check("one-shot: search-gemini carries its identity + route constants",
              OneShotMode.searchGemini.id == "search-gemini"
              && OneShotMode.searchGemini.label == "Gemini search"
              && OneShotMode.searchGemini.historyMode == .searchGemini
              && OneShotMode.searchGemini.minWords == 2)
    }

    private static func checkCriticalFailureDetectors(_ check: (String, Bool) -> Void) {
        // Critical-failure detectors (validate the detectors themselves).
        check("detect preamble", criticalDeterministic(raw: "a b c d e", cleaned: "Here's the cleaned text: a b c").contains { $0.hasPrefix("preamble") })
        check("no false preamble on normal text", !criticalDeterministic(raw: "you're being short here so here's the example", cleaned: "you're being short, so here's the example").contains { $0.hasPrefix("preamble") })
        check("detect refusal", criticalDeterministic(raw: "send the email to John and Lisa", cleaned: "I cannot send an email to both people at once.").contains { $0.hasPrefix("refusal") })
        check("detect residual disfluency", criticalDeterministic(raw: "so um the thing uh yeah", cleaned: "so um the thing").contains { $0.hasPrefix("disfluency") })
        check("detect over-deletion", criticalDeterministic(raw: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen", cleaned: "one two three").contains { $0.hasPrefix("over-deletion") })
        check("detect invented number", criticalDeterministic(raw: "guess at the aspect ratio of the square and put it there", cleaned: "i'm guessing it would be around 1x1 in size there").contains { $0.hasPrefix("hallucination: invented number") })
        check("no false number flag when preserved", !criticalDeterministic(raw: "this very first V1 is not the V2", cleaned: "this very first V1 is not the V2.").contains { $0.hasPrefix("hallucination: invented number") })
        check("clean output has no deterministic critical", criticalDeterministic(raw: "so um the the thing is good you know", cleaned: "the thing is good.").isEmpty)
    }

    // MARK: clipboard-layer coverage (no audio / no UI)

    /// Pure coverage of the pasteboard/clipboard-history layer round 2 rewrote twice (fixes 4 and 5)
    /// and that had zero headless coverage. Exercises the full SyntheticPasteboard write/mark/capture/
    /// restore cycle on a PRIVATE named pasteboard (never the general pasteboard), plus the two
    /// display formatters and the dedup identity predicate as pure functions. No timers, no singleton
    /// state. Runs before the LM-dependent golden section.
    private static func runClipboardTests() -> Bool {
        print("--- clipboard-layer coverage (private pasteboard, no UI) ---")
        let reporter = SelfTestReporter()
        let check = reporter.check

        // (a) write / mark / capture / restore cycle on a uniquely-named private pasteboard.
        let pb = NSPasteboard(name: NSPasteboard.Name(
            AppIdentity.queueLabel("selftest-\(UUID().uuidString)")))
        defer { pb.releaseGlobally() }

        SyntheticPasteboard.write("bridge sample text", to: pb)
        check("synthetic write stamps the marker", SyntheticPasteboard.isMarked(pb))

        let snap = PasteboardSnapshot.capture(from: pb)
        check("capture non-empty after a write", !snap.isEmpty)
        // The marker's data is empty, and capture skips empty-data types, so the snapshot never
        // carries the marker (the invariant fix 5's convention rests on).
        check("snapshot omits the empty-data synthetic marker type",
              !snap.items.contains { $0.types.contains { $0.name == SyntheticPasteboard.markerType.rawValue } })

        let tiny = PasteboardSnapshot.capture(from: pb, maxBytes: 1)
        check("tiny byte budget yields an empty snapshot", tiny.isEmpty)

        SyntheticPasteboard.restore(PasteboardSnapshot(items: [], totalBytes: 0), to: pb)
        check("restoring the empty snapshot clears the pasteboard", (pb.pasteboardItems ?? []).isEmpty)

        // (b) display formatters (now `static`) — empty-snapshot string, kb rounding, count previews.
        let emptySnap = PasteboardSnapshot(items: [], totalBytes: 0)
        check("detailText: metadata-only for the empty snapshot",
              ClipboardHistory.detailText(snapshot: emptySnap, items: [], typeNames: [])
                == "Metadata only - too large or not restorable")
        let stringType = NSPasteboard.PasteboardType.string.rawValue
        let pngType = NSPasteboard.PasteboardType.png.rawValue
        let fileType = NSPasteboard.PasteboardType.fileURL.rawValue
        let dummy = PasteboardSnapshot.StoredItem(types: [.init(name: stringType, data: Data())])
        // kb = ceil(bytes/1024), floored at 1: 1500 bytes -> 2 KB (ceil rounds up), 3072 -> 3 KB.
        check("detailText: text label + ceil kb rounding",
              ClipboardHistory.detailText(snapshot: PasteboardSnapshot(items: [dummy], totalBytes: 1500),
                                          items: [], typeNames: [stringType]) == "Text - 2 KB")
        check("detailText: image label + kb",
              ClipboardHistory.detailText(snapshot: PasteboardSnapshot(items: [dummy], totalBytes: 3072),
                                          items: [], typeNames: [pngType]) == "Image - 3 KB")
        check("previewText: prefers text, whitespace-collapsed and trimmed",
              ClipboardHistory.previewText(text: "  hello\n  world ", items: [], typeNames: []) == "hello world")
        check("previewText: count-based single image when no text",
              ClipboardHistory.previewText(text: nil, items: [NSPasteboardItem()], typeNames: [pngType])
                == "1 copied image")
        check("previewText: count-based plural files when no text",
              ClipboardHistory.previewText(text: nil, items: [NSPasteboardItem(), NSPasteboardItem()],
                                           typeNames: [fileType]) == "2 copied files")

        // (c) dedup identity predicate (the seam the image-dedup fix extends). Keyed on preview +
        // types + snapshot byte count.
        func entry(_ preview: String, _ types: [String], bytes: Int = 0) -> ClipboardHistory.Entry {
            ClipboardHistory.Entry(id: UUID(), date: Date(), preview: preview, detail: "d",
                                   types: types, snapshot: PasteboardSnapshot(items: [dummy], totalBytes: bytes))
        }
        let head = entry("1 copied image", [pngType], bytes: 2048)
        check("dedup: true when preview + types + byte count match the head",
              ClipboardHistory.isDuplicate(head: head, candidate: entry("1 copied image", [pngType], bytes: 2048)))
        check("dedup: false when the preview differs",
              !ClipboardHistory.isDuplicate(head: head, candidate: entry("2 copied images", [pngType], bytes: 2048)))
        check("dedup: false when the type set differs",
              !ClipboardHistory.isDuplicate(head: head, candidate: entry("1 copied image", [stringType], bytes: 2048)))
        // The item-5 fix: two distinct images share preview + types but differ in byte count, so the
        // second is no longer silently dropped.
        check("dedup: false when byte count differs (distinct images, same preview + types)",
              !ClipboardHistory.isDuplicate(head: head, candidate: entry("1 copied image", [pngType], bytes: 4096)))
        check("dedup: false against an empty history (no head)",
              !ClipboardHistory.isDuplicate(head: nil, candidate: head))

        print("  -> clipboard: \(reporter.passed ? "PASS" : "FAIL")\n")
        return reporter.passed
    }

    // MARK: golden output test

    struct SampleResult {
        let id: String
        let raw: String
        let cleaned: String
        let latency: TimeInterval
        let detCriticals: [String]
        let judgeCriticals: [String]   // ADVISORY ONLY — the LLM judge proved too noisy to gate on
        let judgeRan: Bool
        /// The GATE is the deterministic detectors. The LLM judge is logged as advisory because in
        /// testing it produced both false negatives (missed an invented "1x1") and false positives
        /// (claimed verbatim-preserved text was invented), so it cannot be trusted as the hard gate
        /// for an irreversible install. Semantic faithfulness is confirmed by the build session's
        /// manual review (recorded in the build-log) and re-checked by the adversarial test-design
        /// session that follows.
        var critical: Bool { !detCriticals.isEmpty }
    }

    private static func runGoldenTests() -> (Bool, [SampleResult]) {
        print("--- golden output test (real CleanupClient -> LM Studio) ---")
        var results: [SampleResult] = []
        var allClear = true
        for g in goldens {
            let (res, wall) = CleanupClient.cleanupSync(g.raw, timeout: 30)
            var cleaned = ""
            var det: [String] = []
            switch res {
            case .ok(let c): cleaned = c
            case .unavailable(let w): det = ["service-unavailable: \(w)"]
            case .timedOut: det = ["service-timeout"]
            case .badOutput(let w): det = ["bad-output: \(w)"]
            }
            if !cleaned.isEmpty { det += criticalDeterministic(raw: g.raw, cleaned: cleaned) }

            let (jCrit, jRan) = cleaned.isEmpty ? ([], false) : judge(raw: g.raw, cleaned: cleaned)

            let r = SampleResult(id: g.id, raw: g.raw, cleaned: cleaned, latency: wall,
                                 detCriticals: det, judgeCriticals: jCrit, judgeRan: jRan)
            results.append(r)
            if r.critical { allClear = false }

            print("\n  [\(g.id)]  \(String(format: "%.2fs", wall))  \(r.critical ? "CRITICAL ❌" : "clean ✓")\(jRan ? "" : "  (judge unavailable)")")
            print("    raw     : \(snippet(g.raw))")
            print("    cleaned : \(snippet(cleaned))")
            if !det.isEmpty { print("    det-criticals (GATE): \(det.joined(separator: " | "))") }
            if !jCrit.isEmpty { print("    judge-flags (advisory only): \(jCrit.joined(separator: " | "))") }
        }
        return (allClear, results)
    }

    // MARK: deterministic critical-failure detectors

    /// Objective critical failures (the green bar's hard, machine-checkable ones). Semantic failures
    /// (hallucination, dropped substantive point, lost voice) are the judge's job.
    static func criticalDeterministic(raw: String, cleaned: String) -> [String] {
        var out: [String] = []
        let c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let lc = c.lowercased()
        if c.isEmpty { return ["empty-output"] }

        // Preamble / meta-commentary — anchored at the START so legitimate "...here's the example"
        // mid-sentence never trips it.
        let preambleStarts = ["here is", "here's", "here are", "sure,", "sure!", "sure.", "certainly",
                              "of course", "okay, here", "ok, here", "i've cleaned", "i have cleaned",
                              "cleaned text", "cleaned-up", "cleaned up version", "below is", "the cleaned",
                              "this is the cleaned", "i cleaned"]
        if preambleStarts.contains(where: { lc.hasPrefix($0) }) { out.append("preamble: leading meta phrase") }
        if lc.contains("option 1") || lc.contains("option 2") || lc.contains("option 3") {
            out.append("preamble: option-menu format")
        }

        // Refusal — refusals lead, so check the opening window only (avoids mid-text false hits).
        let head = String(lc.prefix(90))
        let refusals = ["i can't", "i cannot", "i'm unable", "i am unable", "as an ai", "i won't",
                        "i will not", "i'm sorry, but", "i am sorry, but"]
        if refusals.contains(where: { head.contains($0) }) { out.append("refusal: leading refusal phrase") }

        // Residual disfluency the cleaner was supposed to remove (only flag tokens present in raw).
        for token in ["um", "uh"] {
            if containsWord(lc, token) && containsWord(raw.lowercased(), token) {
                out.append("disfluency: residual '\(token)'")
            }
        }
        if c.range(of: #"\b(\w+)\s+\1\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // immediate doubled word like "the the" — only a critical if raw had a doubled word too
            if raw.range(of: #"\b(\w+)\s+\1\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                out.append("disfluency: residual doubled word")
            }
        }

        // Novel-number hallucination: any number in CLEANED that is not in RAW is invented (this is
        // exactly the "guess at the aspect ratio" -> "around 1x1" failure). Deterministic and
        // high-signal — the LLM judge proved too noisy to gate on, so we catch this class here.
        let rawNums = Set(matches(#"\d+"#, in: raw))
        for n in matches(#"\d+"#, in: c) where !rawNums.contains(n) {
            out.append("hallucination: invented number '\(n)'")
        }

        // Length sanity: over-deletion (#1 failure mode) and runaway expansion (hallucination proxy).
        let rw = wordCount(raw), cw = wordCount(c)
        if rw >= 12 && Double(cw) < 0.6 * Double(rw) { out.append("over-deletion: \(cw)/\(rw) words (<60%)") }
        if rw >= 12 && Double(cw) > 1.35 * Double(rw) { out.append("over-expansion: \(cw)/\(rw) words (>135%)") }

        return out
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: LLM judge (semantic critical failures)

    private static let judgeModels = ["qwen3-coder-30b-a3b-instruct-mlx", "llama-3.2-3b-instruct"]

    /// Returns (criticalReasons, judgeRan). judgeRan=false means no judge model answered (a judge
    /// outage must not falsely fail the gate — the deterministic detectors still apply).
    static func judge(raw: String, cleaned: String) -> ([String], Bool) {
        let system = """
        You are a strict grader for a transcription-cleanup tool. The tool must ONLY remove \
        disfluencies (um, uh, filler 'like'), false starts, stutters, and word repetitions, and \
        lightly tighten run-ons. It MUST preserve every substantive point and the speaker's casual \
        voice, and MUST NOT summarize, invent/hallucinate content, refuse, add preamble or \
        commentary, change word choices, or over-delete. Note: leaving the text nearly unchanged is \
        ACCEPTABLE (conservative is fine); under-cleaning is NOT a failure. Misheard proper nouns \
        (e.g. 'Max' vs 'Macs') are NOT the tool's job and NOT a failure. Judge ONLY for CRITICAL \
        failures: (1) hallucination/invented content, (2) refusal, (3) preamble/meta-commentary, \
        (4) a dropped or merged-away substantive/distinct point, (5) over-deletion of substance. \
        Reply with ONLY a JSON object, no prose: {"critical": true|false, "reasons": ["..."]}. \
        If unsure whether something is critical, set critical=false.
        """
        let user = "RAW:\n\(raw)\n\nCLEANED:\n\(cleaned)\n\nGrade for CRITICAL failures only. JSON:"
        for model in judgeModels {
            guard let reply = chat(model: model, system: system, user: user, timeout: 90) else { continue }
            if let parsed = parseJudge(reply) { return (parsed, true) }
            // model answered but unparseable -> try the next model
        }
        return ([], false)
    }

    private static func parseJudge(_ reply: String) -> [String]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else { return nil }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let critical = (obj["critical"] as? Bool) ?? false
        let reasons = (obj["reasons"] as? [String]) ?? []
        return critical ? (reasons.isEmpty ? ["judge flagged critical (no reason given)"] : reasons) : []
    }

    /// Minimal synchronous chat helper for the judge (CleanupClient is specialized to the cleanup
    /// request shape). Returns nil on any transport/decode error so the caller can fall through.
    private static func chat(model: String, system: String, user: String, timeout: TimeInterval) -> String? {
        var req = URLRequest(url: Settings.cleanupEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "temperature": 0.0, "max_tokens": 800, "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { return }
            out = content
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 10)
        return out
    }

    // MARK: helpers

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
    private static func containsWord(_ haystack: String, _ word: String) -> Bool {
        haystack.range(of: "\\b\(word)\\b", options: [.regularExpression]) != nil
    }
    private static func snippet(_ s: String, _ n: Int = 220) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count <= n ? t : String(t.prefix(n)) + " …"
    }

    private static func writeSummary(unitOK: Bool, clipboardOK: Bool, goldenOK: Bool, samples: [SampleResult]) {
        var lines = ["{",
            "  \"unitTestsPass\": \(unitOK),",
            "  \"clipboardTestsPass\": \(clipboardOK),",
            "  \"goldenBarPass\": \(goldenOK),",
            "  \"model\": \"\(Settings.cleanupModel)\",",
            "  \"samples\": ["]
        for (i, s) in samples.enumerated() {
            let crit = (s.detCriticals + s.judgeCriticals).map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }
            lines.append("    {\"id\":\"\(s.id)\",\"latency\":\(String(format: "%.2f", s.latency)),\"critical\":\(s.critical),\"judgeRan\":\(s.judgeRan),\"criticals\":[\(crit.joined(separator: ","))]}\(i == samples.count - 1 ? "" : ",")")
        }
        lines += ["  ]", "}"]
        let json = lines.joined(separator: "\n")
        let url = URL(fileURLWithPath: "/tmp/viddydictate-selftest.json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        print("wrote machine summary -> \(url.path)")
    }
}
