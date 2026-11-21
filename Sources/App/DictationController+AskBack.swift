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
}
