import Cocoa

/// The capability surface a Family-2 one-shot flow needs from the coordinator (`DictationController`).
///
/// This is the decompose seam (item-4 piece 8, ADR 0010). The one-shot flows (Cleanup-selection, and
/// later Email + Search) are deeply entangled with the coordinator's private state - the recording
/// state machine, the HUD, audio, target, and the two-tier undo - so lifting them off the God object is
/// not a free-standing move: each extracted flow needs a defined set of coordinator capabilities. Rather
/// than reach into `DictationController` directly, a flow holds an `OneShotContext` and calls only these.
/// `DictationController` conforms to it (same-file extension), keeping the recording lifecycle bespoke
/// while the per-mode step-sequences move out. Piece 11 makes the `OneShotRegistry` engine the single
/// client of this seam; pieces 9-10 widen it as the transcript-acting flows are extracted. Piece 9 (Email)
/// added the transcript-take trio (`takeHasSpeech` / `finalizeTakeAndTranscribe` / `markTakeConsumed`);
/// piece 10 (Search) reuses that trio unchanged. It is deliberately narrow: only what a flow actually uses.
protocol OneShotContext: AnyObject {
    /// The shared HUD (toast / thinking ring / hide). The flows surface their status through it exactly
    /// as the inline methods did.
    var hud: HUDPanel { get }

    /// The idle prompt string, tracking the live wakeup binding (a flow restores it when it finishes).
    var readyHint: String { get }

    /// The coordinator's recording-state description, for the flow's entry log line only (the flow is
    /// decoupled from the state machine itself; this preserves the pre-extraction diagnostic verbatim).
    var stateLabel: String { get }

    /// The level-picker armed flag, backed by the hotkey tap (which reads it to route level-nav keys).
    /// The Cleanup-selection flow owns the panel but the tap owns this flag, so it flows through here.
    var levelPickerActive: Bool { get set }

    /// Update the menubar / idle-hint status line.
    func note(_ s: String)

    /// Throw away the incidental audio take that holding the wakeup key started (pure-command chords do
    /// not transcribe). Recording-state-machine logic that stays on the coordinator.
    func discardIncidentalAudio()

    /// The one-shot arbiter: true (and logs) when another one-shot flow already owns the stage, so the
    /// caller returns. Centralized on the coordinator so one flow never overlaps another.
    func rejectOneShotIfBusy(_ label: String) -> Bool

    /// The shared piece-2 "land a one-shot selection-transform RESULT" tail: on success paste back over
    /// the selection, record provenance, and (for undo-wired modes) register the smart-undo source; on
    /// failure leave the text untouched via `failInPlace`. The in-place transform modes route here.
    func landInPlaceTransform(_ result: CleanupClient.Result, input: String, mode: HistoryMode,
                              level: Int?, wireUndo: Bool, uiNoun: String, logNoun: String,
                              levelLabel: String?, inputSource: NotesBullseyeLogic.InputSource,
                              noteTarget: NotesDictationTarget?,
                              foreignTarget: DictationTarget?, historyID: UUID?,
                              lateRecovery: Bool)

    /// True when the just-held take actually carried speech: the recording machine is capturing AND the
    /// VAD flag fired. The dual-mode discriminator the transcript-acting flows branch on (email: dictate
    /// fresh vs transform the selection; search: a spoken question vs a silent tap). Reads the recording
    /// state + `audio.detectedSpeech`, both owned by the coordinator.
    var takeHasSpeech: Bool { get }

    /// Finalize an in-flight take (stop the partial loop, snapshot + stop audio, drop the active flag,
    /// switch the HUD to the thinking ring) and transcribe it; `completion` runs on the MAIN thread with
    /// the transcript (or nil) plus any daemon error. The shared piece-2 teardown that was byte-identical
    /// across the email + search dictation paths; a transcript-acting one-shot flow reuses it here.
    func finalizeTakeAndTranscribe(noteLabel: String,
                                   completion: @escaping (String?, String?, UUID, Bool) -> Void)

    /// Retry a failed transcription from its retained WAV after the daemon is ready. The generation pins
    /// cancellation to the original take; the flow keeps its snapshotted landing state until completion.
    func retryRetainedTake(takeID: UUID, retentionWasEnabled: Bool, generation: Int,
                           completion: @escaping (RetainedTakeRecoveryResult) -> Void)

    /// Return the recording state machine to idle once a finalized take's transcript has been consumed.
    /// The take went `.finishing` in `finalizeTakeAndTranscribe`; a transcript-acting flow calls this after
    /// pulling the transcript, which also makes the trailing right-Option release a no-op (no second
    /// `finish()`). The state-machine write stays the coordinator's; the flow only signals the transition.
    func markTakeConsumed()

    /// BT5 Esc-cancel generation counter. A transcript-acting flow captures this before finalizing the take and
    /// drops its completion when `cancelTake()` has bumped the coordinator's generation in the meantime.
    var currentTakeGeneration: Int { get }

    /// The Search flow's non-destructive landing hook: open/focus the sticky-notes surface and create an
    /// editable answer note (question as heading, answer as body). This is intentionally the ONE optional
    /// AppDelegate callback: nil when the notes bridge is not wired, so the flow falls back to the read-only HUD
    /// answer. Read-only through the seam. Added in piece 10 for the Search extraction (Email +
    /// Cleanup-selection land in place instead).
    var onOpenSearchResultNote: ((String, String) -> Void)? { get }

    /// The current dictation target's app label (empty when none), for the Search answer's History
    /// provenance. The coordinator owns target resolution; the non-destructive Search landing records the
    /// target it never pastes into. Added in piece 10 (the in-place tail sources its own label internally).
    var targetLabel: String { get }

    /// BT4 (notes-bullseye): the four-color replace highlight for the Option+P selection-transform pick.
    /// `showReplaceHighlight` resolves the key notes window's active note (nil when the pick is over a
    /// foreign-app selection — not tinted, CodeMirror-only), tints it to `level`, and returns the note id;
    /// `updateReplaceHighlight` recolors it as the pick moves; `clearReplaceHighlight` clears it on
    /// commit/cancel. The dictation-take replace flow is driven directly by the coordinator, not through here.
    func showReplaceHighlight(level: String) -> String?
    func updateReplaceHighlight(noteId: String, level: String)
    func clearReplaceHighlight(noteId: String)

    /// BT4 (item-3) + BT (item-4), refine2 BUG 2: the ONE authoritative note-selection target for the current
    /// gesture — the `NotesDictationTarget` the coordinator ALREADY captured at take-START (`beginRecording`),
    /// whose snapshot range is still the live selection. A one-shot selection-transform flow (Option+P
    /// cleanup-selection, the Option+M email selection arm, custom in-place modes) reuses THIS instead of
    /// re-snapshotting: by chord-resolve time the replace-highlight tint has collapsed the live selection, so a
    /// fresh snapshot would degenerate to a bare caret and delivery would insert-at-a-point instead of replacing
    /// the range (THE bug). There is exactly one authoritative note-selection range per gesture, owned by the
    /// coordinator. nil when the take did not start in a note (a foreign-app pick — not tinted; the landing
    /// falls back to today's key-window / paste path).
    func authoritativeNoteTargetForGesture() -> NotesDictationTarget?

    /// The foreign Accessibility target captured at the same gesture start. A retry may be confirmed from
    /// ViddyDictate's Settings window after focus has moved, so the landing closure must retain this target
    /// instead of pasting into whichever Settings control happens to be focused.
    func authoritativeForeignTargetForGesture() -> DictationTarget?
}
