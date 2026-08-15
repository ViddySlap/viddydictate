import Cocoa

/// The Family-2 one-shot registry engine (item-4 piece 11, the registry step under ADR 0010).
///
/// Pieces 8-10 lifted the three one-shot command flows (Option+P Cleanup-selection, Option+M email,
/// Option+L/G web search) off the God object into three parallel types (`CleanupSelectionFlow` /
/// `EmailFlow` / `SearchFlow`), each driving the coordinator through the `OneShotContext` seam. This piece
/// collapses those three types into ONE data-driven engine: a table of `OneShotMode` descriptors, each
/// paired with its per-mode hooks (the client call, the optional level-pick pre-step, the landing), driven
/// through one shared flow:
///
///     arbiter guard -> acquire input per `descriptor.input` -> optional level pick -> augment prompt
///     -> client -> land per `descriptor.landing`
///
/// The engine is the single client of the seam. It owns the ONE busy-latch that used to be three per-flow
/// booleans (`prepInput != nil` / `emailInFlight` / `searchInFlight`) - one Family-2 flow at a time; the
/// Family-1 A/B picker stays on the coordinator and is folded into its arbiter via the seam. Adding a
/// one-shot mode #N is now a new `OneShotMode` descriptor plus one `Entry` row here, with zero new flow
/// methods on the controller (the north-star ADR 0010 names).
///
/// Three shapes are genuinely bespoke and are NOT force-unified (the false-unification trap ADR 0010
/// warns against): Cleanup-selection carries the async level-picker pre-step; email/search have no picker;
/// and search lands NON-destructively (answer note / HUD) so it deliberately keeps its own landing rather
/// than routing through the shared in-place tail. The engine models these as an `input`-typed acquisition
/// switch, an `usesLevelPicker` facet, and a `landNonDestructive` hook, not as three hard-coded methods.
final class OneShotRegistry {
    private unowned let context: OneShotContext

    /// The single engine busy-latch (replaces the three former per-flow in-flight booleans). One Family-2
    /// flow runs at a time, so the union of the old flags is a single bool. Set the moment a path commits
    /// (a fresh dictation take, or a resolved selection), cleared only when the flow lands, cancels, or
    /// no-ops. The coordinator's one-shot arbiter reads this through `isBusy`.
    private var busy = false

    /// The level picker (Option+P's interactive pre-step) and the input captured across it. `pending`
    /// holds the descriptor row + captured text + input source between showing the picker and
    /// committing/cancelling it - the async gap the other modes do not have. Only picker modes populate it.
    private let levelPicker = LevelPickerPanel()
    private var pending: (entry: Entry, input: String, inputSource: NotesBullseyeLogic.InputSource)?

    /// BT4 (notes-bullseye): the note showing the Option+P replace highlight while the level picker is up, or
    /// nil when the pick is over a foreign-app selection (not tinted). Held so `pickerMove*` can recolor the
    /// tint live and `commit`/`cancel` can clear it.
    private var replaceHighlightNoteId: String?

    /// BT (item-4): the note target snapshotted at selection-capture for the in-flight one-shot SELECTION
    /// transform, or nil when the selection was in a foreign app (or none is in flight). Captured in
    /// `captureSelection` while the note is key + the selection is live — before the copy churn / level picker /
    /// LLM round-trip can move focus — and threaded into `finish`'s in-place landing so the transform lands BY
    /// NOTE ID (focus-independent) instead of pasting into whatever app is focused when the model returns. Reset
    /// at every flow entry (`run(entry:)`) so a captured-then-no-op flow can never leak its target into a later
    /// non-selection flow; the busy-latch guarantees one flow at a time. Lives here (not on `DictationController`)
    /// to keep this state off the shared controller header and preserve separation of concerns.
    private var oneShotNoteTarget: NotesDictationTarget?

    init(context: OneShotContext) { self.context = context }

    /// Test seam: override the custom-mode transform call so the headless selftest drives the shared
    /// flow with a stub instead of a live `CleanupClient` -> LM Studio round trip. nil in production
    /// (custom modes resolve through `CustomModeClient.run`, dispatching on the model kind).
    var customClientForTest: ((CustomMode, String, @escaping (CleanupClient.Result) -> Void) -> Void)?

    /// The one-shot modes the engine drives. `handle(command:)` maps each chord to one of these.
    enum Mode { case cleanupSelection, email, searchLocal, searchGemini }

    /// The descriptor selected by a built-in chord. DictationController reads the same descriptor to
    /// decide immediate selection execution versus per-take arming; the registry rows below consume it
    /// when the take releases.
    static func descriptor(for mode: Mode) -> OneShotMode {
        switch mode {
        case .cleanupSelection: return .cleanupSelection
        case .email:            return .email
        case .searchLocal:      return .searchLocal
        case .searchGemini:     return .searchGemini
        }
    }

    /// Whether a built-in mode inserts the async level-picker pre-step. Option+P only; every other
    /// built-in and EVERY custom mode is plain-shape (no picker). The single source `entry(for:)` and the
    /// selftest both read, so "P keeps its level picker" is asserted against the same fact the flow uses.
    static func usesLevelPicker(_ mode: Mode) -> Bool { mode == .cleanupSelection }

    /// Pure request builders shared by the built-in rows and deterministic route-coverage tests.
    static func makeCleanupSelectionRequest(input: String, selected: LLMProviderBundle,
                                            systemPrompt: String,
                                            timeout: TimeInterval) -> TextTransformRequest {
        TextTransformRequest(
            route: .promptPrep, bundle: selected, sourceText: input,
            systemPrompt: systemPrompt,
            userMessage: CleanupClient.wrap(input), timeout: timeout)
    }

    static func makeEmailRequest(input: String, selected: LLMProviderBundle,
                                 systemPrompt: String,
                                 timeout: TimeInterval) -> TextTransformRequest {
        TextTransformRequest(
            route: .email, bundle: selected, sourceText: input,
            systemPrompt: systemPrompt,
            userMessage: EmailClient.wrap(input), timeout: timeout)
    }

    /// True while a one-shot flow owns the stage (the coordinator's arbiter folds this in). Spans the
    /// whole cycle: the level-pick window, the transcribe, the client call, and the land.
    var isBusy: Bool { busy }

    // MARK: - The shared flow

    /// Route a built-in chord to its descriptor row, then the shared flow.
    func run(_ mode: Mode) { run(entry: entry(for: mode)) }

    /// Route a user-defined custom mode through the SAME shared flow the built-ins use — the descriptor
    /// is data, the engine is one. This is the whole "a custom mode becomes a live OneShotMode without a
    /// rebuild" mechanic: `customEntry` builds the same `Entry` shape `entry(for:)` builds for a built-in.
    func runCustom(_ mode: CustomMode) { run(entry: customEntry(for: mode)) }

    /// Run a resolved one-shot entry: log it, then acquire its input per the descriptor's `input`
    /// taxonomy. The arbiter guard + the incidental-audio discard ordering are per input type, preserved
    /// exactly from the three former flows (a pure-selection mode discards the held take up front; a
    /// transcript-acting mode keeps the take unless it is rejected or unused).
    private func run(entry: Entry) {
        // A new command owns a new landing gesture. Any earlier failed transform can no longer safely
        // restore its captured selection/answer surface, so drop it before acquisition or retrieval begins.
        TextTransformRetryCenter.shared.invalidate()
        Log.write("\(entry.invokePrefix) invoked state=\(context.stateLabel)")
        // BT (item-4): clear any stale remembered target up front so a prior captured-then-no-op flow can never
        // leak its note target into this one. `captureSelection` re-captures it (to a target or nil) for the
        // selection-input paths below; transcript-only / dictate-fresh paths keep it nil and land via the fallback.
        oneShotNoteTarget = nil
        switch entry.mode.input {
        case .selection:
            // Pure command: discard the incidental take the held wakeup started, THEN gate on the arbiter.
            context.discardIncidentalAudio()
            if context.rejectOneShotIfBusy(entry.mode.id) { return }
            captureSelection(entry)
        case .transcript:
            // Dictate-the-input: gate first (still discard the phantom take if rejected), then require the
            // take to carry real speech; a silent tap no-ops with a nudge (no selection fallback).
            if context.rejectOneShotIfBusy(entry.mode.id) { context.discardIncidentalAudio(); return }
            let takeHasSpeech = context.takeHasSpeech
            guard takeHasSpeech else {
                context.discardIncidentalAudio()
                context.hud.toast(entry.noSpeechToast)
                context.note(context.readyHint)
                return
            }
            busy = true
            transcribe(entry)
        case .transcriptOrSelection:
            // Dual-mode: gate first, then branch on whether the take carried speech - dictate fresh, or
            // (a silent take) discard it and transform the current selection.
            if context.rejectOneShotIfBusy(entry.mode.id) { context.discardIncidentalAudio(); return }
            let takeHasSpeech = context.takeHasSpeech
            if takeHasSpeech {
                busy = true
                transcribe(entry)
            } else {
                context.discardIncidentalAudio()
                captureSelection(entry)
            }
        }
    }

    /// Copy-capture the current selection (clipboard fallback), snapshotting + restoring the user's real
    /// clipboard around the copy so it is never disturbed. No-op + a per-mode toast when both selection and
    /// clipboard are blank; otherwise arm the busy-latch and continue. The arbiter + discard have already
    /// run in `run` (or, for the dual-mode fallback, this is a continuation after the take was consumed).
    private func captureSelection(_ entry: Entry) {
        let pb = NSPasteboard.general
        let original = PasteboardSnapshot.capture(from: pb)
        let originalString = pb.string(forType: .string)
        // BT (item-3 + item-4), refine2 BUG 2: reuse the ONE authoritative note-selection target the coordinator
        // already captured at take-START, rather than re-snapshotting here. By this point the replace-highlight
        // tint has COLLAPSED the live selection, so a fresh snapshot would re-read a bare caret and delivery
        // would insert-at-a-point instead of replacing the range (THE bug), and the copy below would copy
        // nothing. The take-start snapshot's range is still correct in the JS store; teardown restored the live
        // selection so the Cmd+C copies the real text. A foreign-app pick captured no target -> nil (not in a
        // note). item-4 remembers the target so the in-place landing delivers BY NOTE ID (focus-independent).
        oneShotNoteTarget = context.authoritativeNoteTargetForGesture()
        TargetResolver.captureSelectionViaCopy { [weak self] captured in
            guard let self = self else { return }
            SyntheticPasteboard.restore(original, to: pb)
            guard let input = CleanupLogic.promptPrepInput(selection: captured, clipboard: originalString) else {
                Log.write("\(entry.mode.id): no selection and empty clipboard — no-op")
                self.context.hud.toast(entry.blankToast)
                self.context.note(self.context.readyHint)
                return
            }
            self.busy = true
            self.haveSelectionInput(entry, input: input)
        }
    }

    /// The selection is captured. Picker modes hide the HUD and show the level picker (the async pre-step,
    /// held in `pending`); non-picker selection modes go straight to the thinking ring + client.
    private func haveSelectionInput(_ entry: Entry, input: String) {
        context.hud.hide()
        if entry.usesLevelPicker {
            let sticky = CleanupLevel.clamped(Settings.promptPrepLevel)
            // BT4: push the tint FIRST (the range was snapshotted at selection-capture, while live), then show
            // the picker — so the tint is up the moment the picker appears. The island renders from the stored
            // snapshot range and collapses the now-copied selection so the tint shows. nil when the selection
            // is in a foreign app (copied from another window) — that is not tinted.
            replaceHighlightNoteId = context.showReplaceHighlight(level: NotesReplaceHighlightLogic.from(sticky).rawValue)
            levelPicker.show(selected: sticky.rawValue)
            context.levelPickerActive = true
            pending = (entry, input, .selection)
            context.note("\(entry.mode.label): pick a level")
        } else {
            context.hud.setThinking(true)
            runClient(entry, input: input, wordCount: nil, level: nil, inputSource: .selection)
        }
    }

    /// Finalize the in-flight take (via the seam), transcribe it, clean it (Layer-1 hard-coded corrections
    /// ride the fresh STT transcript too), and word-gate it. On pass, consume the take and run the client;
    /// on fail, hand off to `gateFailed` (the failure ACTION differs by input taxonomy). `busy` was armed
    /// by the caller before the transcribe, so it spans the whole teardown.
    private func transcribe(_ entry: Entry) {
        let generation = context.currentTakeGeneration
        context.finalizeTakeAndTranscribe(noteLabel: "\(entry.mode.label): transcribing") {
            [weak self] text, err, takeID, retentionEnabled in
            guard let self = self else { return }
            guard generation == self.context.currentTakeGeneration else {
                Log.write("\(entry.mode.id): transcribe dropped — take canceled (gen \(generation) != \(self.context.currentTakeGeneration))")
                self.busy = false
                return
            }
            guard let text else {
                Log.write("\(entry.mode.id): transcription unavailable (error=\(err ?? "none")); retained retry requested")
                self.context.retryRetainedTake(
                    takeID: takeID, retentionWasEnabled: retentionEnabled, generation: generation
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .recovered(let recovered):
                        self.consumeTranscription(
                            entry, text: recovered, err: nil, takeID: takeID,
                            generation: generation, lateRecovery: true)
                    case .unavailable(let reason):
                        Log.write("\(entry.mode.id): retained retry unavailable "
                            + "take=\(takeID.uuidString) reason=\(reason)")
                        self.context.markTakeConsumed()
                        self.busy = false
                        self.context.hud.setThinking(false)
                        self.context.hud.toast("Take could not be retried: \(reason)")
                        self.context.note(self.context.readyHint)
                    }
                }
                return
            }
            self.consumeTranscription(
                entry, text: text, err: err, takeID: takeID,
                generation: generation, lateRecovery: false)
        }
    }

    private func consumeTranscription(_ entry: Entry, text: String, err: String?, takeID: UUID,
                                      generation: Int, lateRecovery: Bool) {
        guard generation == context.currentTakeGeneration else {
            Log.write("\(entry.mode.id): recovered transcribe dropped - take canceled "
                + "(gen \(generation) != \(context.currentTakeGeneration))")
            busy = false
            return
        }
        let raw = CorrectionDictionary.shared.applyHardCoded(CleanupLogic.cleanRepeats(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = raw.split(whereSeparator: { $0.isWhitespace }).count
        guard entry.mode.clearsWordGate(wordCount: wordCount) else {
            gateFailed(entry, wordCount: wordCount, err: err)
            return
        }
        context.markTakeConsumed()
        Log.write("transcript.app-postprocess take=\(takeID.uuidString) "
            + "daemon=\(String(reflecting: text)) app=\(String(reflecting: raw))")
        runClient(entry, input: raw, wordCount: wordCount, level: nil,
                  inputSource: .dictation, historyID: takeID, lateRecovery: lateRecovery)
    }

    /// A dictated take did not clear the word gate. The action is per input taxonomy: a dual-mode mode
    /// (email) falls back to the selection transform; a transcript-only mode (search) nudges and aborts.
    /// The take is consumed, the busy-latch dropped, and the thinking ring cleared before either path.
    private func gateFailed(_ entry: Entry, wordCount: Int, err: String?) {
        switch entry.mode.input {
        case .transcript:
            Log.write("search: transcript \(wordCount) words (err=\(err ?? "none")) — no question heard")
        case .transcriptOrSelection:
            Log.write("\(entry.mode.id): transcript \(wordCount) words (err=\(err ?? "none")) — falling back to selection path")
        case .selection:
            break   // unreachable: a pure-selection mode never transcribes
        }
        context.markTakeConsumed()
        busy = false
        context.hud.setThinking(false)
        switch entry.mode.input {
        case .transcript:
            context.hud.toast(entry.noQuestionToast)
            context.note(context.readyHint)
        case .transcriptOrSelection:
            captureSelection(entry)
        case .selection:
            break
        }
    }

    /// Note the working status, log the run, augment + call the mode's client, and land the result on the
    /// main thread. The single "augment prompt -> client -> land" tail every mode shares; the thinking ring
    /// is already on (armed by the transcribe, the selection-resolve, or the level-pick commit).
    private func runClient(_ entry: Entry, input: String, wordCount: Int?, level: CleanupLevel?,
                           inputSource: NotesBullseyeLogic.InputSource, historyID: UUID? = nil,
                           lateRecovery: Bool = false) {
        context.note(entry.workingNote)
        Log.write(entry.runLog(input, wordCount, level))
        // Snapshot both landing worlds before the first result consumes mutable registry/controller state.
        // The same immutable values stay captured by TextTransformClient's retry completion.
        let noteTarget = oneShotNoteTarget
        let foreignTarget = noteTarget == nil ? context.authoritativeForeignTargetForGesture() : nil
        oneShotNoteTarget = nil
        entry.client(input, level) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.context.hud.setThinking(false)
                self.finish(entry, result: result, input: input, level: level,
                            inputSource: inputSource, noteTarget: noteTarget,
                            foreignTarget: foreignTarget, historyID: historyID,
                            lateRecovery: lateRecovery)
            }
        }
    }

    /// Land the result and release the stage, dispatching on `descriptor.landing` (the single
    /// authoritative representation of where a mode's result goes). `.inPlace` routes through the shared
    /// piece-2 `landInPlaceTransform` tail (paste-back + provenance + optional smart-undo, or
    /// leave-untouched on failure); `.nonDestructive` runs the mode's bespoke hook (search's answer
    /// note / HUD) — a `.nonDestructive` row with no hook is a table bug and fails loudly rather than
    /// falling through to a destructive paste over the selection. Either way the busy-latch drops, the
    /// pending pick clears, and the idle hint is restored exactly once.
    private func finish(_ entry: Entry, result: CleanupClient.Result, input: String, level: CleanupLevel?,
                        inputSource: NotesBullseyeLogic.InputSource,
                        noteTarget: NotesDictationTarget?, foreignTarget: DictationTarget?,
                        historyID: UUID?, lateRecovery: Bool = false) {
        busy = false
        pending = nil
        defer { context.note(context.readyHint) }
        switch entry.mode.landing {
        case .inPlace(let wireUndo):
            context.landInPlaceTransform(result, input: input, mode: entry.mode.historyMode,
                                         level: level?.rawValue, wireUndo: wireUndo,
                                         uiNoun: entry.landUINoun, logNoun: entry.mode.id,
                                         levelLabel: level?.label, inputSource: inputSource,
                                         noteTarget: noteTarget,
                                         foreignTarget: foreignTarget, historyID: historyID,
                                         lateRecovery: lateRecovery)
        case .nonDestructive:
            guard let landNonDestructive = entry.landNonDestructive else {
                preconditionFailure("\(entry.mode.id): .nonDestructive descriptor has no landNonDestructive hook")
            }
            landNonDestructive(result, input, historyID)
        }
    }

    // MARK: - Level picker (Option+P's async pre-step; routed from the coordinator's hotkey tap)

    func pickerMoveLeft() { levelPicker.moveLeft(); refreshReplaceHighlight() }
    func pickerMoveRight() { levelPicker.moveRight(); refreshReplaceHighlight() }

    /// BT4: recolor the Option+P replace highlight to the now-focused level as the pick moves. No-op when the
    /// selection is not in a note (`replaceHighlightNoteId` nil).
    private func refreshReplaceHighlight() {
        guard let id = replaceHighlightNoteId else { return }
        let level = NotesReplaceHighlightLogic.from(CleanupLevel.clamped(levelPicker.selectedIndex))
        context.updateReplaceHighlight(noteId: id, level: level.rawValue)
    }

    /// BT4: clear the Option+P replace highlight, if any (the pick committed or canceled). Idempotent.
    private func clearReplaceHighlight() {
        guard let id = replaceHighlightNoteId else { return }
        replaceHighlightNoteId = nil
        context.clearReplaceHighlight(noteId: id)
    }

    /// Return in the level picker: run the picked level's cleanup prompt over the captured text. The pick
    /// is persisted as the sticky last-used; there is no length gate (the level is an explicit pick).
    func commitLevelPick() {
        guard context.levelPickerActive, let p = pending else { return }
        context.levelPickerActive = false
        let level = CleanupLevel.clamped(levelPicker.selectedIndex)
        levelPicker.hide()
        clearReplaceHighlight()   // BT4: committed — the transform will replace the text; drop the tint

        Settings.promptPrepLevel = level.rawValue   // sticky last-used, independent of the ?-slider
        context.hud.setThinking(true)
        runClient(p.entry, input: p.input, wordCount: nil, level: level,
                  inputSource: p.inputSource)
    }

    /// Escape in the level picker: cancel, leaving the text untouched and the stage released.
    func cancelLevelPick() {
        guard context.levelPickerActive, let p = pending else { return }
        context.levelPickerActive = false
        levelPicker.hide()
        clearReplaceHighlight()   // BT4: canceled — text untouched; drop the tint
        pending = nil
        busy = false
        Log.write("\(p.entry.mode.id) canceled (esc) — text untouched")
        context.note(context.readyHint)
    }

    // MARK: - The table (descriptor + per-mode hooks)

    /// One row of the registry: the declarative `OneShotMode` descriptor paired with the imperative hooks
    /// that genuinely differ per mode - the client call (with its augmented system prompt), the run-log
    /// line, the per-mode toasts, and (for the non-destructive modes) the bespoke landing. Everything else
    /// is the shared flow above.
    private struct Entry {
        let mode: OneShotMode
        /// The invocation-log prefix, kept byte-identical to each former flow's entry line.
        let invokePrefix: String
        /// Whether acquisition inserts the async level-pick pre-step (Cleanup-selection only).
        let usesLevelPicker: Bool
        /// The no-op toast when a selection mode finds neither a selection nor a clipboard.
        let blankToast: String
        /// The nudge when a transcript-only mode's take carried no speech.
        let noSpeechToast: String
        /// The nudge when a transcript-only mode's take did not clear the word gate.
        let noQuestionToast: String
        /// The gerund in the working-status note ("transforming" / "writing" / "searching").
        let workingNoun: String
        /// The failure-toast noun for the in-place tail ("Transform" / "Email writer").
        let landUINoun: String
        /// Resolve + augment this mode's system prompt and call its underlying client; the completion may
        /// run off the main thread (the engine hops back before landing).
        let client: (String, CleanupLevel?, @escaping (CleanupClient.Result) -> Void) -> Void
        /// Build the run-log line just before the client call (formats differ: level vs word count).
        let runLog: (String, Int?, CleanupLevel?) -> String
        /// The bespoke landing for a `.nonDestructive` descriptor (search's answer-note / HUD). Dispatch
        /// is on `mode.landing`, not this hook's nil-ness: an in-place mode leaves it nil (ignored), and
        /// a `.nonDestructive` mode MUST supply it — `finish` preconditions on the pairing.
        let landNonDestructive: ((CleanupClient.Result, String, UUID?) -> Void)?

        var workingNote: String { "\(mode.label): \(workingNoun)" }
    }

    /// Build the descriptor + hooks row for a mode. This is the "table": adding a one-shot mode is a new
    /// case here (plus its `OneShotMode` descriptor), with no change to the shared flow.
    private func entry(for mode: Mode) -> Entry {
        switch mode {
        case .cleanupSelection:
            let m = OneShotMode.cleanupSelection
            return Entry(
                mode: m,
                invokePrefix: "\(m.id) (Option+P)",
                usesLevelPicker: OneShotRegistry.usesLevelPicker(mode),
                blankToast: "Nothing to transform — select text or copy something first",
                noSpeechToast: "", noQuestionToast: "",
                workingNoun: "transforming",
                landUINoun: "Transform",
                client: { input, level, done in
                    // Layer 2: the context-aware glossary rides the Cleanup-selection pass too. Model is
                    // Option+P's own choice (`promptPrepModeModel`, default = the cleanup model), so the P
                    // row's model is independent of the `?`-toggle model — mirroring how `promptPrepLevel`
                    // is P's own level. Any selected remote provider receives the same augmented prompt
                    // and fenced input (same Result contract, same in-place landing).
                    let resolution = Settings.promptPrepRouteResolution
                    let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
                        let providerPrompt = Settings.modelsPower.effectiveDeveloperInstructions(
                            for: .promptPrep, provider: bundle.provider,
                            variant: .cleanup(level!),
                            glossarySuffix: CorrectionDictionary.shared.contextGlossarySuffix())
                        let timeout = Settings.timeout(
                            local: Settings.cleanupTimeout, provider: bundle.provider)
                        return Self.makeCleanupSelectionRequest(
                            input: input, selected: bundle,
                            systemPrompt: providerPrompt, timeout: timeout)
                    }
                    TextTransformClient.transformResolved(
                        resolution, route: .promptPrep, requestForBundle: requestForBundle,
                        local: { req, finish in
                            CleanupClient.cleanup(req.sourceText, timeout: req.timeout,
                                                  model: req.bundle.modelID,
                                                  systemPrompt: req.systemPrompt,
                                                  completion: finish)
                        }, completion: done)
                },
                runLog: { input, _, level in "\(m.id) run level=\(level!.label) (\(input.count) chars)" },
                landNonDestructive: nil)

        case .email:
            let m = OneShotMode.email
            return Entry(
                mode: m,
                invokePrefix: "\(m.id) (Option+M)",
                usesLevelPicker: OneShotRegistry.usesLevelPicker(mode),
                blankToast: "Nothing to send — select your notes or copy them first",
                noSpeechToast: "", noQuestionToast: "",
                workingNoun: "writing",
                landUINoun: "Email writer",
                client: { input, _, done in
                    // Option+M's system prompt expects the selection between EmailClient's NOTES markers, so
                    // every provider arm uses EmailClient.wrap (not the TRANSCRIPT wrap) to keep the prompt
                    // shape identical to the local gemma path.
                    let resolution = Settings.emailRouteResolution
                    let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
                        let providerPrompt = Settings.modelsPower.effectiveDeveloperInstructions(
                            for: .email, provider: bundle.provider,
                            glossarySuffix: CorrectionDictionary.shared.contextGlossarySuffix())
                        let timeout = Settings.timeout(
                            local: Settings.emailTimeout, provider: bundle.provider)
                        return Self.makeEmailRequest(
                            input: input, selected: bundle,
                            systemPrompt: providerPrompt, timeout: timeout)
                    }
                    TextTransformClient.transformResolved(
                        resolution, route: .email, requestForBundle: requestForBundle,
                        local: { req, finish in
                            EmailClient.email(req.sourceText, timeout: req.timeout,
                                              model: req.bundle.modelID,
                                              systemPrompt: req.systemPrompt,
                                              completion: finish)
                        }, completion: done)
                },
                runLog: { input, wc, _ in
                    wc.map { "\(m.id)-from-dictation run (\($0) words, \(input.count) chars)" }
                        ?? "\(m.id) run (\(input.count) chars)"
                },
                landNonDestructive: nil)

        case .searchLocal, .searchGemini:
            let isLocal = (mode == .searchLocal)
            let m: OneShotMode = isLocal ? .searchLocal : .searchGemini
            let runSearch: (String, @escaping (CleanupClient.Result) -> Void) -> Void = isLocal
                ? { q, done in SearchClient.localAnswer(question: q, completion: done) }
                : { q, done in SearchClient.geminiAnswer(question: q, completion: done) }
            return Entry(
                mode: m,
                // The arbiter reject + invoke log use the resolved descriptor id/label, so the busy-reject
                // and entry lines are engine-specific ("search (search)" / "search (Gemini search)").
                invokePrefix: "search (\(m.label))",
                usesLevelPicker: OneShotRegistry.usesLevelPicker(mode),
                blankToast: "",
                noSpeechToast: "Hold the key and speak your question first",
                noQuestionToast: "Didn't catch a question — try again",
                workingNoun: "searching",
                landUINoun: "",
                // Search resolves its own two-stage prompts internally (agentic rewrite + gemma synth),
                // both Settings-overridable; there is no single flow-level system prompt to thread here, so
                // "augment prompt -> client" collapses to the client call (NOT false-unified with the
                // in-place modes' single-prompt shape).
                client: { input, _, done in runSearch(input, done) },
                runLog: { input, wc, _ in "search-from-dictation (\(m.label), \(wc ?? 0) words, \(input.count) chars)" },
                landNonDestructive: { [weak self] result, question, historyID in
                    guard let self = self else { return }
                    switch result {
                    case .ok(let answer):
                        Log.write("search answer (\(m.label), \(question.count)q -> \(answer.count)a chars)")
                        if let openNote = self.context.onOpenSearchResultNote {
                            openNote(question, answer)
                            self.context.hud.hide()
                        } else {
                            Log.write("search answer fallback: notes bridge unavailable")
                            self.context.hud.answer(answer)
                        }
                        TranscriptionHistory.shared.record(delivered: answer, raw: question, cleaned: answer,
                                                           mode: m.historyMode, level: nil,
                                                           app: self.context.targetLabel,
                                                           id: historyID ?? UUID())
                    case .unavailable, .timedOut, .badOutput:
                        let failure = TextTransformClient.safeFailure(for: result)!
                        Log.write("search fallback classification=\(failure.logToken) — \(m.label)")
                        self.context.hud.toast("⚠️ Search: \(failure.userMessage) — no answer inserted.")
                    }
                })
        }
    }

    /// Build the descriptor + hooks row for a user-defined custom mode. The declarative half is the
    /// custom mode's `oneShotMode`; the imperative half is the same shape a built-in row supplies — the
    /// transform client (correction-glossary-augmented custom prompt run against the chosen model,
    /// stubbable for the headless selftest) and, for a note-landing mode, the bespoke sticky-note landing
    /// the web-search modes use. Custom modes are plain-shape: no level picker, and the "augment prompt"
    /// step is owned by `CustomModeClient`, so the flow-level client here is a single call.
    private func customEntry(for m: CustomMode) -> Entry {
        let osm = m.oneShotMode
        let label = m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "custom mode" : m.name
        let landNote: ((CleanupClient.Result, String, UUID?) -> Void)? = m.landing == .note
            ? { [weak self] result, input, historyID in
                guard let self = self else { return }
                switch result {
                case .ok(let output):
                    Log.write("custom \(m.id) note (\(input.count)i -> \(output.count)o chars)")
                    if let openNote = self.context.onOpenSearchResultNote {
                        openNote(input, output)
                        self.context.hud.hide()
                    } else {
                        Log.write("custom \(m.id) note fallback: notes bridge unavailable")
                        self.context.hud.answer(output)
                    }
                    TranscriptionHistory.shared.record(delivered: output, raw: input, cleaned: output,
                                                       mode: osm.historyMode, level: nil,
                                                       app: self.context.targetLabel,
                                                       id: historyID ?? UUID())
                case .unavailable, .timedOut, .badOutput:
                    let failure = TextTransformClient.safeFailure(for: result)!
                    Log.write("custom \(m.id) fallback classification=\(failure.logToken)")
                    self.context.hud.toast("⚠️ \(label): \(failure.userMessage) — no output inserted. Retry in Models.")
                }
            }
            : nil

        return Entry(
            mode: osm,
            invokePrefix: "custom \(m.id) (\(label))",
            usesLevelPicker: false,
            blankToast: "Nothing to transform — select text or copy something first",
            noSpeechToast: "Hold the key and speak first",
            noQuestionToast: "Didn't catch anything — try again",
            workingNoun: "running",
            landUINoun: label,
            client: { [weak self] input, _, done in
                if let stub = self?.customClientForTest {
                    stub(m, input, done)
                } else {
                    CustomModeClient.run(m, input: input, completion: done)
                }
            },
            runLog: { input, wc, _ in
                wc.map { "custom \(m.id) run (\($0) words, \(input.count) chars)" }
                    ?? "custom \(m.id) run (\(input.count) chars)"
            },
            landNonDestructive: landNote)
    }
}
