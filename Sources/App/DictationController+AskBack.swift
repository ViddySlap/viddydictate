import Cocoa
import ApplicationServices

extension DictationController {
    // MARK: VDASK-7: Option+P ask-back host

    /// Host the same ask-back flow a dictation take uses for Option+P's selected text. The registry has
    /// already closed the level picker, frozen the prompt-prep provider and captured the landing target; this
    /// method owns only the controller-side effects: the review runner, the card/keys/voice answer, History,
    /// the detached save-only job, and the latch hand-back. Landing runs through the normal selection-transform
    /// tail so the write replaces the captured selection exactly as it does without ask-back.
    func startSelectionAskBack(_ request: SelectionAskRequest,
                               releaseLatch: @escaping () -> Void,
                               reacquireLatch: @escaping () -> Void) {
        // Freeze where the card opens before the review wait, like a dictation take freezes its anchor at
        // `finish()`: the marker's last placement, else the pointer (the HUD rides with it).
        if let placed = pasteMarker.lastPlacement, placed.kind != .pointer { askAnchor = placed.center }
        else { askAnchor = NSEvent.mouseLocation }

        let level = AskBackLevel(request.level)
        let provider = request.resolution.bundle.map { AskBackProvider($0.provider) } ?? .local
        let tier = Settings.askBackTier
        weak var flowRef: AskBackFlow?
        var latchReleased = false
        let release = {
            guard !latchReleased else { return }
            latchReleased = true
            releaseLatch()
        }
        let reacquire = {
            guard latchReleased else { return }
            latchReleased = false
            reacquireLatch()
        }

        // A review or write is cancelable exactly like a dictation take's (Option+Esc). The audio is gone
        // (Option+P discarded its incidental take), but the take-active flag is what routes that chord.
        setActive(true)

        let context = AskBackFlow.Context(
            historyID: request.historyID, transcript: request.input, level: level,
            levelRaw: request.level.rawValue, tier: tier, provider: provider,
            writeModel: request.resolution.bundle?.modelID ?? "", generation: takeGeneration,
            source: .selection)

        let hooks = AskBackFlow.Hooks(
            phaseChanged: { [weak self] phase in
                // S5: a right-Option hold parks the Option+P take and releases the registry latch at once,
                // so the old flow can never land over the new take. An Esc under that hold resumes it.
                if phase == .parked || phase == .cancelled { release() }
                if phase == .asking { reacquire() }
                self?.askPhaseChanged(phase)
            },
            readingCue: { [weak self] on in self?.askReadingCue(on) },
            startReview: { [weak self] id in
                let deliverReview: AskBackReviewRunner.Deliver = { reviewID, outcome in
                    DispatchQueue.main.async { flowRef?.reviewOutcome(reviewID, outcome) }
                }
                let runner: AskBackReviewRunner
                if let provider = self?.askSeams.reviewProvider {
                    runner = AskBackReviewRunner(schedule: self?.askSeams.schedule ?? Self.mainSchedule,
                                                 provider: provider, deliver: deliverReview)
                } else {
                    runner = AskBackReviewRunner.live(resolution: request.resolution, deliver: deliverReview)
                }
                self?.askRunner = runner
                runner.start(id: id, text: request.input, level: level, tier: tier, source: .selection)
            },
            skipReview: { [weak self] id in self?.askRunner?.skip(id) },
            showCard: { [weak self] card in self?.askShowCard(card) },
            highlight: { [weak self] id, index in self?.askCardPanel?.setHighlight(cardID: id, index: index) },
            closeCard: { [weak self] _ in self?.hotkey.askCardActive = false },
            startWrite: { [weak self] spec in
                self?.hud.update(state: "Cleaning…", target: self?.target?.label, text: "", locked: false)
                self?.hud.setThinking(true)
                self?.note("cleaning")
                // The explicit-retry landing is NOT the flow's write completion: that completion is already
                // `.finished` after the first attempt and would drop a confirmed Retry. It lands through the
                // same captured request (answers, destination and History id) without touching the flow again.
                let retryLanding: TextTransformClient.Completion = { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.landSelectionAskResult(result, request: request)
                    }
                }
                request.write(spec.questions, spec.answers, { result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        var ok = false
                        if case .ok = result { ok = true }
                        flowRef?.writeFinished(spec.writeID, ok: ok) {
                            self.landSelectionAskResult(result, request: request)
                            release()
                        }
                    }
                }, retryLanding)
            },
            history: { [weak self] event in
                TranscriptionHistory.shared.apply(event, app: self?.target?.label ?? "")
            },
            saveDetached: { [weak self] job in
                // Option+P keeps History only: the detached write never lands, never touches the HUD and
                // never offers an install. The latch already dropped when the card parked.
                release()
                AskBackDetached.run(
                    job,
                    now: self?.askSeams.now ?? { ProcessInfo.processInfo.systemUptime },
                    write: { _, done in request.writeDetached(job.questions, job.answers, done) },
                    history: { event in TranscriptionHistory.shared.apply(event) })
            },
            startNewTake: { [weak self] in self?.askStartNewTake() },
            voiceStart: { [weak self] in self?.askVoiceStart() ?? false },
            voiceDiscard: { [weak self] in self?.askVoiceDiscard() },
            voiceStop: { [weak self] id in
                self?.askVoiceStop { text in DispatchQueue.main.async { flowRef?.voiceTranscript(id, text: text) } }
            },
            voiceStatus: { [weak self] card, status in self?.askCardPanel?.setStatus(cardID: card, text: status?.text) })
        let flow = AskBackFlow(context: context, schedule: askSeams.schedule ?? Self.mainSchedule,
                               now: askSeams.now ?? { ProcessInfo.processInfo.systemUptime }, hooks: hooks)
        flowRef = flow
        askFlow = flow
        flow.start()
    }

    /// Land an Option+P ask write through the unchanged selection-transform tail, then hand the take back to
    /// idle and release the registry latch. The History record is the same pending id the flow inserted, so
    /// `record` updates it with the landed text and keeps the `askBack` record.
    private func landSelectionAskResult(_ result: CleanupClient.Result, request: SelectionAskRequest) {
        hud.setThinking(false)
        landInPlaceTransform(result, input: request.input, mode: .cleanupSelection,
                             level: request.level.rawValue, wireUndo: false,
                             uiNoun: "Transform", logNoun: "prompt-prep",
                             levelLabel: request.level.label, inputSource: .selection,
                             noteTarget: request.noteTarget, foreignTarget: request.foreignTarget,
                             preferCapturedForeignTarget: request.foreignTarget != nil,
                             lateRecovery: false, historyID: request.historyID)
        // Same B13 offer the normal Option+P tail shows. A detached job never reaches here.
        if case .unavailable = result, let feature = PointOfUseFeature.forRoute(.promptPrep) {
            PointOfUseOfferPresenter.shared.presentOffer(for: feature)
        }
        setActive(false)
        state = .idle
        note(readyHint)
    }

    // MARK: ask-back glue (VDASK-3). The rules live in `AskBackFlow`; these are its hands.

    static let mainSchedule: AskBackFlow.Schedule = { after, fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
        return { item.cancel() }
    }

    // MARK: held results. The rules live in `AskBackHeldQueue`; these feed it events and do its pastes.

    func heldNow() -> TimeInterval { (askSeams.now ?? { ProcessInfo.processInfo.systemUptime })() }

    /// A card, an A/B picker, or a selection one-shot (its latch from capture to landing, plus the gap before the
    /// latch is set) holds the stage.
    private func heldBusy() -> Bool {
        AskBackHeldPolicy.busy(pendingPick: pendingPick != nil, abPicker: hotkey.abPickerActive,
                               askCard: hotkey.askCardActive, oneShotLatch: heldOneShotLatch(),
                               oneShotGrace: heldNow() < askGraceUntil)
    }

    private func heldOneShotLatch() -> Bool { askSeams.oneShotLatch?() ?? oneShot.isBusy }

    /// Feeds the queue one event with its inputs freshly read (a take is live, something is busy, a delivery is
    /// still open), then pastes what it releases. A waiting result that is held only by the one-shot latch is
    /// looked at again on a timer (while the line is not empty), because the registry has no release callback and
    /// the one-shot mark needs a look at the latch.
    func heldApply(_ event: (inout AskBackHeldQueue) -> [AskBackHeldQueue.Paste]) {
        askHeld.setInputs(takeLive: state != .idle, busy: heldBusy(), delivering: askDeliveries > 0,
                          oneShotUp: heldOneShotLatch())
        let pastes = event(&askHeld)
        for paste in pastes { heldPaste(paste) }
        if !askHeld.isEmpty, askHeldPoll == nil {
            askHeldPoll = (askSeams.schedule ?? Self.mainSchedule)(Self.heldPollInterval) { [weak self] in
                self?.askHeldPoll = nil
                self?.heldApply { $0.poke() }
            }
        }
    }

    /// Something the queue waits on may have changed (a take ended, a delivery completed, a card closed): look
    /// again one run-loop turn later, never inside the call that changed it (a teardown, a landing completion).
    /// Level-triggered: the inputs are read when it fires, so a take that has started by then keeps the line waiting.
    func heldKick() {
        guard !askHeld.isEmpty, askHeldKick == nil else { return }
        askHeldKick = (askSeams.schedule ?? Self.mainSchedule)(0) { [weak self] in
            self?.askHeldKick = nil
            self?.heldApply { $0.poke() }
        }
    }

    /// Opens a delivery: its paste check and clipboard restore have not finished. The returned closure closes it
    /// (once) and gives a waiting held result its turn.
    func beginDelivery() -> () -> Void {
        askDeliveries += 1
        var closed = false
        return { [weak self] in
            guard !closed, let self = self else { return }
            closed = true
            self.askDeliveries -= 1
            self.heldKick()
        }
    }

    /// The delivery in front parked its text on the clipboard for a manual Cmd+V (`pastePark` armed) and the
    /// pasteboard has not changed since: the held result must not overwrite it. (`clipboardPasteboard` is the
    /// general pasteboard in the app; a self-test points it at a private one.)
    private func heldDeliveryParked() -> Bool {
        if let park = pastePark, clipboardPasteboard.changeCount == park.changeCount { return true }
        return AskBackHeldPolicy.clipboardHeld(receiptClipboardOnly: askLastClipboardOnly,
                                               changeCountAtClose: askLastClosedCount,
                                               nowChangeCount: clipboardPasteboard.changeCount)
    }

    /// Pastes one held result through the normal delivery path (`finalize`: History by id, notes routing, the
    /// frozen landing rule of the last take, paste or clipboard park). Only ever runs with no take live, nothing
    /// busy and no delivery open. It is itself a delivery: the next held result waits for its completion. A result
    /// the rogue-output check flags, or one that would overwrite parked text, stays in History only (already
    /// written) and the line moves on.
    private func heldPaste(_ paste: AskBackHeldQueue.Paste) {
        let info = askHeldInfo.removeValue(forKey: paste.id)
        let suspect = info.map { CleanupLogic.cleanupSuspect(rawCount: $0.raw.count, cleanedCount: paste.text.count) } ?? false
        switch AskBackHeldPolicy.turn(suspect: suspect, parked: heldDeliveryParked(), oneShotSeen: paste.oneShotSeen) {
        case .skipOneShot:
            Log.write("held result not pasted: a selection one-shot ran while it waited, History only")
            heldKick()
            return
        case .skipSuspect:
            Log.write("held result not pasted: cleanup suspect (\(info?.raw.count ?? 0)->\(paste.text.count) chars), History only")
            heldKick()
            return
        case .skipParked:
            Log.write("held result not pasted: the delivery in front is parked on the clipboard, History only")
            heldKick()
            return
        case .paste:
            break
        }
        Log.write("held result pastes afterwards (\(paste.text.count) chars)")
        finalize(delivered: paste.text, raw: info?.raw ?? paste.text, cleaned: paste.text, mode: .cleanup,
                 level: info?.level, historyID: paste.id)
        heldKick()
    }

    func askPhaseChanged(_ phase: AskBackFlow.Phase) {
        hotkey.askReviewActive = phase == .reviewing
        if phase != .asking { hotkey.askCardActive = false }
        heldKick()
        switch phase {
        case .reviewing: state = .reviewing
        case .asking: state = .asking
        case .writing: state = .writing
        case .notStarted, .finished, .cancelled, .detached, .parked: break
        }
        if phase != .asking { askCardPanel?.hide() }
    }

    func askReadingCue(_ on: Bool) {
        if on {
            hud.update(state: AskCardText.readingCue, target: target?.label, text: "", locked: false)
            hud.setThinking(true)
            note("reading your take")
        } else {
            hud.setThinking(false)
        }
    }

    func askShowCard(_ card: AskCardModel) {
        let panel: AskCardPresenting = askSeams.cardPanel ?? askCardPanel ?? AskCardPanel()
        askCardPanel = panel
        panel.onChoose = { [weak self] id, index in self?.askFlow?.click(cardID: id, option: index) }
        hud.setThinking(false)
        hud.hide()
        panel.show(card, anchor: askAnchor)
        hotkey.askCardActive = true
        heldKick()
        note("answer the question")
    }

    /// A hold while a card is up: the flow has closed the card and PARKED the old take (S2). The new take starts
    /// as if right Option had just gone down on an idle controller, and the old flow is kept (with the old take's
    /// own target fields) until that press ends: its release detaches the old take, an Esc under the same press
    /// discards the new take and resumes the old one.
    func askStartNewTake() {
        askParkedFlow = askFlow
        askParkedTake = (target, targetWasNotesWindow, takeLandAtStart, notesDelivery.noteTarget)
        askFlow = nil
        endAskFlowUI()
        state = .idle
        startRecording()
    }

    /// False when the mic cannot start (busy or permission missing).
    func askVoiceStart() -> Bool {
        // AVAudioEngine commonly starts and delivers silence when the grant is missing, so ask the grant first.
        let authorized = askSeams.micAuthorized?() ?? Self.askVoiceMicGranted(Permissions.microphoneAuthorization())
        guard authorized else {
            Log.write("ask-back voice: microphone not authorized")
            return false
        }
        if let start = askSeams.voiceStart { return start() }
        do { try audio.start(); return true } catch {
            Log.write("ask-back voice: mic start ERROR: \(error.localizedDescription)")
            return false
        }
    }

    func askVoiceDiscard() {
        if let discard = askSeams.voiceDiscard { discard(); return }
        audio.stop()
    }

    /// Stops capture and transcribes; `done` gets the text, or nil when nothing was heard or the daemon failed.
    func askVoiceStop(_ done: @escaping (String?) -> Void) {
        if let transcribe = askSeams.voiceTranscribe { transcribe(done); return }
        audio.stop()
        guard audio.detectedSpeech else { done(nil); return }      // silence never goes to Whisper
        transcribeAudioSnapshot { text, _, _ in done(text) }
    }

    /// Starts a take's recording. The headless trace test replaces the audio-and-AX start with
    /// `askSeams.beginNewTake`; production always takes `beginRecording()`.
    func startRecording() {
        if let begin = askSeams.beginNewTake {
            begin()
            setActive(true)
            state = .recording
        } else {
            beginRecording()
        }
    }

    /// Esc (with Option) while the press that started a hold-on-a-card is still down: throw the new take away
    /// silently (no toast, no History entry, no generation bump, so the old take's late write still lands) and
    /// resume the old take as agent-decides.
    func resumeParkedOldTake(_ parked: AskBackFlow) {
        Log.write("take canceled (Esc under the card hold) state=\(state): the old take goes on")
        askParkedFlow = nil
        let saved = askParkedTake
        askParkedTake = nil
        if let arm = TransformArmState.shared.cancelPerTakeArm() {
            Log.write("\(arm.id) per-take arm cleared by cancel")
            hud.setArmedMode(glyph: nil)
        }
        teardownTake(.full)
        setActive(true)            // the old take is in flight again: Option+Esc must still be able to cancel it
        hud.setThinking(false)
        hud.hide()
        if let saved = saved {
            target = saved.target
            targetWasNotesWindow = saved.wasNotes
            takeLandAtStart = saved.landAtStart
            notesDelivery.noteTarget = saved.noteTarget
        }
        askFlow = parked
        parked.parkedEsc()
    }

    func endAskFlowUI() {
        hotkey.askCardActive = false
        hotkey.askReviewActive = false
        askCardPanel?.hide()
    }
}
