import Cocoa
import ApplicationServices

/// The application-owned callbacks every controller instance requires. Construction is the wiring gate: a
/// forgotten menu/status/notes-window hook is a compiler error instead of a silent optional no-op.
struct DictationControllerCallbacks {
    let onStateChange: (String) -> Void
    let onOpenSettings: () -> Void
    let onOpenDictionary: () -> Void
    let onOpenHistory: () -> Void
    let onOpenNotes: () -> Void
    let notesWindowIsKey: () -> Bool
    let onCleanupModeChange: (Bool) -> Void
}

/// The state machine that ties the hotkey, audio, daemon, HUD, and target delivery together.
///
/// States:
///   idle      — nothing happening
///   recording — right-Option held (PTT); releasing it sends
///   locked    — hands-free; key released, recording continues until unlock/stop
///   finishing — final transcribe in flight
///   oneShotFinishing — a one-shot take is transcribing / transforming / landing
///
/// Transitions:
///   right-Option down (idle)        -> recording
///   right-Option up   (recording)   -> finish + send
///   Space chord       (recording)   -> locked          (right-Option+Space)
///   Space chord       (locked)      -> finish + send    (re-hold right-Option + Space)
///   HUD Lock button   (recording)   -> locked
///   HUD Stop button   (any active)  -> finish + send
final class DictationController {
    /// `hotkey.takeActive`, not this enum, is authoritative for whether Esc can cancel. `setActive(_:)`
    /// keeps the two aligned for the main flow; one-shot finishing re-arms the tap after dropping the
    /// app-wide active flag because its transcribe / client / landing pipeline is still abortable.
    ///   reviewing / asking / writing (VDASK-3): a Tighten or Summarize take with ask-back on, between
    ///   `.finishing` (transcribe) and the paste: the review call runs, a question card waits, the write runs.
    private enum State { case idle, recording, locked, finishing, oneShotFinishing, reviewing, asking, writing }
    private var state: State = .idle {
        didSet {
            // BUG 1 take-liveness: push the HUD a single "is a take live" signal on EVERY state change, so a
            // mid-take confirmation toast (Option+N bullseye-set, Option+B no-bullseye) reverts to the
            // recording scope when its dwell fires instead of stranding the HUD off-screen. recording/locked =
            // live; idle = no take; finishing = false too (the mic has stopped — the cleanup-wait spinner owns
            // that phase, and every terminal toast there should hide, not revert). `hud` is initialized at
            // declaration, so this observer (which never fires for the .idle default) always has it available.
            hud.setTakeActive(state == .recording || state == .locked)
            if !(state == .recording || state == .locked) { pasteMarker.stop() }
            if oldValue != state { heldKick() }
        }
    }

    private let hotkey = HotkeyMonitor()
    private let audio: AudioRecorder = { let recorder = AudioRecorder(); recorder.honorsDeckMic = true; return recorder }()
    private let audioWorkQueue = DispatchQueue(label: AppIdentity.queueLabel("audio-work"),
                                               qos: .userInitiated)
    private lazy var retainedTakeRecovery = RetainedTakeRecovery(progress: { [weak self] takeID, pending in
        // Recovery callbacks may arrive from the retention or daemon queues. The HUD stays on main and
        // displays one shared ring for all pending take IDs.
        DispatchQueue.main.async { [weak self] in
            self?.hud.setRecoveryPending(takeID: takeID, pending: pending)
        }
    })
    /// Internal, not private (same reasoning as `wasLocked` below): part of the OneShotContext seam
    /// (piece 8). Constructor-injectable (vdtpwg4 repair, master ruling item iv) against the
    /// `HUDPresenting` protocol, not the concrete `HUDPanel` class, so a headless test fixture can
    /// supply a plain no-op conformer (`NullHUDPresenter`) that never constructs any real AppKit
    /// control -- never reaching the construction-time crash site `vdtpwg3-JW3.md` traced
    /// (`HUDPanel.init` -> `NSTextField.labelWithString` -> `_RegisterApplication`, with no window-
    /// server session). Production's own construction site (`AppDelegate`) passes nothing and gets
    /// the exact same real `HUDPanel()` as before.
    let hud: HUDPresenting
    /// The Family-3 notes-delivery collaborator (ADR 0012): owns the notes-bullseye / replace-highlight /
    /// note-target / cross-focus-undo state + JS-bridge callbacks + delivery routing. The seam is deliberately
    /// HUD-free, so the thin Option+N/Option+B entry points and `finalize()`'s tail keep their `hud.*` calls on
    /// this controller. `AppDelegate` wires its callbacks (formerly wired onto the controller directly).
    let notesDelivery: NotesDeliveryCoordinator
    private let callbacks: DictationControllerCallbacks
    private var recentDictationsPanel: RecentDictationsPanel?
    private var dictionaryAddPanel: DictionaryAddPanel?
    private var target: DictationTarget?
    private var targetWasNotesWindow = false
    /// Internal, not private (vdtpwg2 repair, part D): `TailCheckSelfTest`'s `hook-wired`/`hook-after-paste`
    /// arms drive a REAL `finalize()` call through the deterministic, AX-free no-target delivery branch, which
    /// this flag's fixture selects together with `takeLandAtStart`. Production behavior is unchanged -- the
    /// hotkey/state-machine path still sets it exactly as before. Since VDLAND1 it routes NOTHING: learning
    /// whether a take was ever locked does not change where its text lands.
    var wasLocked = false
    /// The landing rule frozen for THIS take (VDLAND1): a copy of `Settings.bullseyeLandAtStart` taken at
    /// take START. ON lands in the field that was focused at take start (or in the sticky note the take
    /// started in, through its take-start snapshot), OFF at live focus when the take ends. `finalize` reads
    /// only this copy, never the live setting and never the lock, so a B press mid-take changes the NEXT take
    /// alone.
    var takeLandAtStart = false
    private var recordingStartedAt: Date?
    private lazy var pasteMarker = PasteTargetMarker()

    /// The persistent Cleanup toggle state captured at the moment of release — "state-at-release
    /// wins": the dictation being held is processed according to the toggle when right-Option is let
    /// go, so flipping `?` mid-ramble still cleans (or un-cleans) the in-progress audio.
    private var cleanupAtRelease = false

    /// The cleanup strength level captured at release — "level-at-release wins", same rule as the
    /// on/off toggle: the dictation lands at whatever strength the slider was set to when right-Option
    /// was let go, so stepping `=`/`-` mid-ramble still applies to the in-progress audio.
    private var levelAtRelease: CleanupLevel = .cleanup

    /// The most recent reversible cleanup delivery, for `right-Option + Z` undo. Tier 1 (in-place
    /// backspace+retype) when it was the freshest push-to-talk paste; tier 2 (raw to clipboard)
    /// otherwise. Single-shot; replaced on each new delivery; downgraded to tier 2 once stale.
    private struct PendingUndo { let raw: String; let cleaned: String; let canRevertInPlace: Bool; let at: Date }
    private var pendingUndo: PendingUndo?

    /// Pure classification for the completion-based locked foreign-app delivery branch. A captured-target
    /// failure has already copied the dictation to the clipboard; a missing target still needs that copy.
    struct LockedDeliveryResolution: Equatable {
        enum ReceiptKind: Equatable { case foreign, clipboard }
        let receipt: ReceiptKind
        let shouldCopyToClipboard: Bool
        let toast: String?
    }

    static func lockedDeliveryResolution(
        targetAvailable: Bool,
        outcome: TargetResolver.CapturedTargetLandingOutcome?
    ) -> LockedDeliveryResolution {
        guard targetAvailable, let outcome = outcome else {
            return LockedDeliveryResolution(
                receipt: .clipboard,
                shouldCopyToClipboard: true,
                toast: "📋 Put on your clipboard — couldn't reach the locked field. ⌘V to paste.")
        }
        switch outcome {
        case .landed:
            return LockedDeliveryResolution(receipt: .foreign, shouldCopyToClipboard: false, toast: nil)
        case .clipboardOnly(let failure):
            return LockedDeliveryResolution(
                receipt: .clipboard,
                shouldCopyToClipboard: false,
                toast: "📋 \(failure.userMessage) — dictation copied to clipboard. ⌘V to paste.")
        }
    }

    /// Runtime-only destination receipt for replacing a cleanup raw fallback after an explicit retry.
    /// It carries no transcript or provider response text. Internal, not private (vdtpwg2 repair, part
    /// C/D): `finalize()`'s own access level widened to let `TailCheckSelfTest` call it directly, which
    /// requires its return type to be at least as visible.
    enum CleanupFallbackReceipt {
        case note(String?)
        case foreign(DictationTarget?)
        case pastePark
        case clipboard(changeCount: Int)
    }

    /// BT5: monotonically-bumped generation for the in-flight take. `cancelTake()` (Esc) bumps it so any pending
    /// transcribe / cleanup completion for the aborted take is dropped instead of landing — the "nothing lands on
    /// abort" contract holds even when Esc fires mid-processing (`.finishing`).
    private let takeGenerationLock = NSLock()
    private var takeGenerationStorage = 0
    private var takeGeneration: Int {
        get {
            takeGenerationLock.lock()
            defer { takeGenerationLock.unlock() }
            return takeGenerationStorage
        }
        set {
            takeGenerationLock.lock()
            defer { takeGenerationLock.unlock() }
            takeGenerationStorage = newValue
        }
    }

    /// Re-says what the speech engine is doing while a retained take waits on a warming daemon, so a slow
    /// cold start reads as "starting… 12s" rather than as a broken engine. Main thread only; it stops
    /// itself when the take is delivered, given up, or cancelled.
    private var warmingTicker: Timer?

    /// The cleanup-suspect A/B picker (prompt-injection backstop). When `CleanupLogic.cleanupSuspect`
    /// flags an output, we show this instead of auto-pasting; `pendingPick` holds the two candidates
    /// awaiting the user's Left/Right/Return choice (driven via `hotkey.abPickerActive`).
    // Built lazily: ABPickerPanel.init touches AppKit; built on first use so a headless controller can be made.
    private lazy var abPicker = ABPickerPanel()

    /// VDASK-3 ask-back. The flow for the take in progress (nil when the take never asked), its review runner,
    /// the card panel (built on first use) and the point the card anchors to, frozen when the take ends.
    private var askFlow: AskBackFlow?
    private var askRunner: AskBackReviewRunner?
    private var askCardPanel: AskCardPresenting?
    private var askAnchor = CGPoint.zero
    /// S2: the old take's flow while a hold that started on its card is still down (its release detaches it, an
    /// Esc under the same press resumes it), and the old take's own target fields, restored on a resume because
    /// the new take's start overwrote them.
    private var askParkedFlow: AskBackFlow?
    /// VDASK-5: the observers that keep the HUD's ? button current when the setting or a route changes.
    private var askToggleObservers: [NSObjectProtocol] = []
    private var askParkedTake: (target: DictationTarget?, wasNotes: Bool, landAtStart: Bool, noteTarget: NotesDictationTarget?)?

    /// Test seams for the headless controller trace test (AskBackControllerSelfTest). Production leaves every
    /// field nil and the code takes its normal path. `resolve` replaces the route resolution, `reviewProvider`
    /// the review call, `claudeWrite` the Claude write adapter (first write, retry and the detached job),
    /// `schedule` / `now` the flow's timers and clock, `beginNewTake` the audio-and-AX start of a new take.
    struct AskBackSeams {
        var resolve: ((LLMRouteID) -> LLMRouteResolution)?
        var reviewProvider: AskBackReviewRunner.Provider?
        var claudeWrite: TextTransformClient.AsyncAdapter?
        var schedule: AskBackFlow.Schedule?
        var now: (() -> TimeInterval)?
        var beginNewTake: (() -> Void)?
        var cardPanel: AskCardPresenting?
        var abPickerShow: ((_ raw: String, _ cleaned: String) -> Void)?
        /// Stands in for the one-shot registry's busy latch (`oneShot.isBusy`), which a headless row cannot set.
        var oneShotLatch: (() -> Bool)?
        /// Stands in for the push-to-talk landing's real paste (focus check, `pasteIntoFocus`): called with the
        /// text and the delivery's completion, it returns false when focus has left the field (the click-away
        /// clipboard park runs), or pastes and calls the completion when the paste check and clipboard restore
        /// would have finished. A headless row cannot reach a focused field.
        var livePaste: ((_ text: String, _ onComplete: @escaping () -> Void) -> Bool)?
        /// VDASK-4 voice answer: stand in for the take's audio recorder and transcriber. `voiceStart` returns
        /// false for a busy or unpermitted mic; `voiceDiscard` stops capture; `voiceTranscribe` stops capture and
        /// hands the transcript (nil: failed) to the closure it is given, whenever the fake chooses.
        var voiceStart: (() -> Bool)?
        var voiceDiscard: (() -> Void)?
        var voiceTranscribe: ((_ done: @escaping (String?) -> Void) -> Void)?
        /// Stands in for the microphone grant check (`Permissions.microphoneAuthorization()`), which reads the
        /// real TCC state. nil in production.
        var micAuthorized: (() -> Bool)?
    }
    var askSeams = AskBackSeams()

    /// The detached old takes' results, held until the take in front has finished (`AskBackHeldQueue`). In
    /// memory only: a result that has not pasted when the app quits is not pasted on relaunch.
    private var askHeld = AskBackHeldQueue()
    private var askHeldInfo: [UUID: (raw: String, level: Int)] = [:]
    /// Deliveries (a take's paste, a one-shot's landing) that have not finished with the clipboard yet: their
    /// paste check and clipboard restore are still pending. A held result never pastes while one is open.
    private var askDeliveries = 0
    private var askHeldKick: (() -> Void)?
    private var askHeldPoll: (() -> Void)?
    private var askGraceUntil: TimeInterval = -1
    /// A selection one-shot throws its incidental take away (the controller goes idle) and only then copies the
    /// selection (`TargetResolver.captureSelectionViaCopy`: a fixed 0.18 s) before it sets its busy latch. A held
    /// result must not paste into that gap: this covers the 0.18 s copy plus slack on a congested main thread.
    static let heldOneShotGrace: TimeInterval = 0.5
    /// How often a waiting held result looks at the one-shot latch (the registry has no release callback).
    static let heldPollInterval: TimeInterval = 0.25
    private var pendingPick: (raw: String, cleaned: String, level: CleanupLevel,
                              takeID: UUID, lateRecovery: Bool)?

    /// The Family-2 one-shot registry engine (ADR 0010): a table of `OneShotMode` descriptors driven
    /// through one shared flow (arbiter -> acquire input -> optional level pick -> augment prompt ->
    /// client -> land), behind the `OneShotContext` seam (`DictationController` conforms below). Owns the
    /// single busy-latch for the one-shot arbiter. The controller keeps only: routing each chord to
    /// `run(mode)`, forwarding the level-picker nav keys, and reading `isBusy`. `lazy` — it captures `self`.
    private lazy var oneShot = OneShotRegistry(context: self)

    /// One-shot clipboard restore for the click-away delivery fallback. When delivery can't reach a
    /// field, the dictation is parked on the clipboard so you can paste it yourself; `pastePark` holds
    /// the clipboard contents from BEFORE the park plus the changeCount at park time, so the very next
    /// Cmd+V restores the prior clipboard once the paste has landed. Skipped (your content left alone)
    /// if you copied something else after the park.
    private struct PastePark { let previous: PasteboardSnapshot; let changeCount: Int }
    private var pastePark: PastePark?
    /// VDASK-3: what the last delivery left on the clipboard when it closed, and the pasteboard changeCount then.
    private var askLastClipboardOnly = false
    private var askLastClosedCount = 0

    /// The notes-delivery JS-bridge callbacks (`onSnapshotNoteTarget` / `onDeliverToNoteTarget` /
    /// `onInsertIntoActiveNote` / `onSetBullseyeAtCaret` / `onDeliverToBullseye` / `onBullseyeStateChanged` /
    /// `onResolveReplaceHighlightTarget` / `onShowReplaceHighlight` / `onClearReplaceHighlight` /
    /// `onUndoNoteDelivery` / `onCurrentNoteId`) now live on `notesDelivery` (ADR 0012); `AppDelegate` wires them
    /// there. The required `notesWindowIsKey` callback stays on this controller — the recording lifecycle +
    /// `landSelectionTransform` read it too.
    ///
    /// This search-result hook is intentionally the one optional AppDelegate callback: when no notes bridge is
    /// available, `OneShotRegistry` has a documented read-only HUD fallback.
    var onOpenSearchResultNote: ((String, String) -> Void)?

    /// Fires once per SUCCESSFUL dictation, after `finalize()`'s `finish` tail has torn the take down, so a
    /// listener can never be reached at launch, mid-take, or on an error / cancel / nothing-heard path. DMGU1's
    /// post-first-dictation update toast is the only listener and a `Bool` latch on the delegate makes it
    /// once-per-app-session.
    var onDictationSucceeded: (() -> Void)?

    /// The tail-check dictation-path seam (2026-10-06 scope addition, part D; vdtpwg2 repair, part C/D).
    /// Constructor-injectable, same pattern as `ModelManager.CapacityDependencies`: the production
    /// default wires through `TailCheckObserver.makeDefaultHook`, the one real construction path, so a
    /// test substituting `tailCheckHook` here proves `finalize()`'s own wiring/gating for real, and a
    /// test substituting nothing still gets the real production hook. The override is captured at
    /// `init` as a plain, self-free value; the hook itself builds `lazy`, once `self` (and `hud`) are
    /// fully initialized, since its production default closes over `hud`.
    private let tailCheckHookOverride: TailCheckDictationHook?
    private lazy var tailCheckHook: TailCheckDictationHook = tailCheckHookOverride
        ?? TailCheckObserver.makeDefaultHook(hudSink: { [hud] suffix in
            hud.toast("Possible trailing junk: \"\(suffix)\"")
        })
    /// The pasteboard `finalize()`'s locked-no-target branch copies to. Defaults to the real system
    /// pasteboard in production; a self-test overrides it with a private, uniquely-named one so driving
    /// a real delivery branch never touches the user's actual clipboard (see `CleanupSelfTest`'s own
    /// `runClipboardTests` for the same "private named pasteboard, never general" convention).
    private let clipboardPasteboard: NSPasteboard

    init(callbacks: DictationControllerCallbacks, notesDelivery: NotesDeliveryCoordinator,
         tailCheckHook: TailCheckDictationHook? = nil,
         clipboardPasteboard: NSPasteboard = .general, hud: HUDPresenting = HUDPanel()) {
        self.callbacks = callbacks
        self.notesDelivery = notesDelivery
        self.clipboardPasteboard = clipboardPasteboard
        self.tailCheckHookOverride = tailCheckHook
        self.hud = hud
    }

    func startMonitoring() -> Bool {
        installHotkeyCallbacks()
        hud.onLock = { [weak self] in self?.toggleLock() }
        hud.onStop = { [weak self] in self?.finish() }
        hud.onSettings = { [weak self] in self?.callbacks.onOpenSettings() }
        hud.samplesProvider = { [weak self] in self?.audio.scopeSamples ?? [] }
        hud.onSetLevel = { [weak self] lvl in self?.setLevelFromSlider(lvl) }
        hud.onToggleAskBack = { [weak self] in self?.toggleAskBackFromHUD() }
        let nc = NotificationCenter.default
        askToggleObservers = [
            nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshAskBackToggle() },
            nc.addObserver(forName: ModelsPowerSettingsStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshAskBackToggle() },
        ]
        refreshAskBackToggle()
        // B13/B14's panel, on the same keyboard-over-the-tap contract as the two pickers below.
        let offers = PointOfUseOfferPresenter.shared
        hotkey.onInstallOfferLeft = { offers.moveLeft() }
        hotkey.onInstallOfferRight = { offers.moveRight() }
        hotkey.onInstallOfferCommit = { offers.commit() }
        hotkey.onInstallOfferCancel = { offers.dismiss() }
        offers.onActiveChanged = { [weak self] active in self?.hotkey.installOfferActive = active }
        offers.onNotice = { [weak self] message in self?.hud.toast(message) }
        let liveHotkeyMap = HotkeyMap.load()
        hotkey.map = liveHotkeyMap
        hud.setHotkeyMap(liveHotkeyMap)
        hotkey.customChords = CustomModeStore.shared.chordSnapshot()
        return hotkey.start()
    }

    /// Wires every `HotkeyMonitor` callback of the take flow to this controller. `startMonitoring()` calls it
    /// first; the headless controller trace test calls it on its own controller so key and press events reach the
    /// real handlers without starting the CGEvent tap. Installs callbacks only: no tap, no HUD, no global state.
    func installHotkeyCallbacks() {
        hotkey.onRightOptionDown = { [weak self] in self?.rightOptionDown() }
        hotkey.onRightOptionUp = { [weak self] in self?.rightOptionUp() }
        hotkey.onCommand = { [weak self] command in self?.handle(command: command) }
        hotkey.onCustomCommand = { [weak self] id in self?.handleCustom(id: id) }
        hotkey.onABLeft = { [weak self] in self?.abPicker.selectRaw() }
        hotkey.onABRight = { [weak self] in self?.abPicker.selectCleaned() }
        hotkey.onABCommit = { [weak self] in self?.commitABPick() }
        hotkey.onABCancel = { [weak self] in self?.commitABPick(forceRaw: true) }
        hotkey.onLevelLeft = { [weak self] in self?.oneShot.pickerMoveLeft() }
        hotkey.onLevelRight = { [weak self] in self?.oneShot.pickerMoveRight() }
        hotkey.onLevelCommit = { [weak self] in self?.oneShot.commitLevelPick() }
        hotkey.onLevelCancel = { [weak self] in self?.oneShot.cancelLevelPick() }
        hotkey.onPasteWhileArmed = { [weak self] in self?.restoreParkedClipboard() }
        hotkey.onCancelTake = { [weak self] in self?.cancelTake() }   // BT5: Esc aborts the in-progress take
        hotkey.onAskBackKey = { [weak self] action in self?.askFlow?.key(action) }
        hotkey.onAskCardOptionDown = { [weak self] in self?.askFlow?.optionDown() }
        hotkey.onAskCardOptionUp = { [weak self] in self?.askFlow?.optionUp() }
        hotkey.onAskVoiceKey = { [weak self] down in
            if down { self?.askFlow?.voiceDown() } else { self?.askFlow?.voiceUp() }
        }
    }

    /// Re-read the persisted hotkey map + custom-mode chords into the live tap (called after a rebind /
    /// restore-default / custom-mode create/edit/delete in Settings). Cheap pointer swaps — the tap reads
    /// both on the main thread where it dispatches.
    func reloadHotkeys() {
        let liveHotkeyMap = HotkeyMap.load()
        hotkey.map = liveHotkeyMap
        hud.setHotkeyMap(liveHotkeyMap)
        CustomModeStore.shared.load()
        if let arm = TransformArmState.shared.armedOneShot,
           arm.lifetime == .persistent,
           !persistentArmRemainsEnabled(arm) {
            _ = TransformArmState.shared.disarmPersistentOneShot(id: arm.id)
            Log.write("\(arm.id) persistent arm cleared because toggleability is off or ineligible")
        }
        hud.setArmedMode(glyph: TransformArmState.shared.armedOneShot?.glyph)
        hotkey.customChords = CustomModeStore.shared.chordSnapshot()
        if state == .idle { note(readyHint) }   // reflect a rebound wakeup in the menubar right away
    }

    /// Arm the rebinding capture in the live tap (Settings Hotkeys tab). The next key press is reported
    /// via `onCapture`; Escape reports `onCancel`. Routed through the controller because it owns the tap.
    func beginHotkeyCapture(onCapture: @escaping (KeySpec) -> Void, onCancel: @escaping () -> Void) {
        hotkey.beginCapture(onCapture: onCapture, onCancel: onCancel)
    }
    func cancelHotkeyCapture() { hotkey.cancelCapture() }

    /// Re-arm the global key tap after the Mac wakes — taps can be left disabled across sleep, and
    /// a dead tap looks identical to "the app isn't running" from the outside.
    func handleWake() {
        Log.write("wake — re-enabling hotkey tap")
        hotkey.reEnable()
        DaemonClient.health { ok, detail in Log.write("wake daemon health ok=\(ok) (\(detail))") }
    }

    private func setActive(_ active: Bool) {
        Settings.isDictationActive = active
        // BT5: mirror take-active into the tap so Esc is swallowed + routed to `cancelTake()` ONLY while a take is
        // in flight (recording / locked / the main take's `.finishing` processing, where active stays true); when
        // no take is active Esc passes through to the focused app as a normal key.
        hotkey.takeActive = active
        NotificationCenter.default.post(name: Settings.dictationActive, object: NSNumber(value: active))
    }

    private func transcribeAudioSnapshot(retainingAs takeID: UUID? = nil,
                                         retentionEnabled: Bool? = nil,
                                         completion: @escaping (String?, String?, [TailCheck.Segment]) -> Void) {
        audioWorkQueue.async { [audio] in
            let snapshot = audio.snapshotWavWithMetrics()
            let wav = snapshot.wav
            // This enqueue is intentionally before the POST and returns immediately. The retention store
            // owns a separate utility queue, so disk I/O and eviction overlap the existing URLSession work.
            if let takeID {
                AudioRetentionStore.shared.retain(
                    wav, id: takeID, enabled: retentionEnabled ?? Settings.retainDictationAudio)
            }
            let take = takeID?.uuidString ?? "final"
            Log.write("audio.snapshot take=\(take) raw_s=\(String(format: "%.3f", snapshot.rawDuration)) "
                + "post_trim_s=\(String(format: "%.3f", snapshot.retainedDuration)) "
                + "trailing_trimmed_s=\(String(format: "%.3f", snapshot.trimmedTrailingDuration)) "
                + "wav_bytes=\(wav.count)")
            DaemonClient.transcribe(wav, takeID: takeID, completion: completion)
        }
    }

    /// Finalize an in-flight take for a one-shot mode that acts on the fresh transcript (email
    /// dictation, web search): snapshot + stop the audio, drop the active flag,
    /// switch the HUD to the thinking ring, and transcribe. `completion` runs on the MAIN thread with
    /// the transcript (or nil) plus any daemon error. Part of the `OneShotContext` seam: the registry's
    /// transcript-acting modes (email dictation, web search) call it through the seam rather than reaching
    /// onto the coordinator.
    func finalizeTakeAndTranscribe(noteLabel: String,
                                   completion: @escaping (String?, String?, UUID, Bool) -> Void) {
        state = .oneShotFinishing
        let takeID = UUID()
        let retentionEnabled = Settings.retainDictationAudio
        logRecordingStop(takeID: takeID)
        audio.stop()
        setActive(false)
        // This one-shot is still cancelable while transcribe / client / landing run, so undo
        // setActive(false)'s takeActive side effect without restoring the app-wide active flag.
        hotkey.takeActive = true
        hud.update(state: "Transcribing…", target: target?.label, text: "", locked: false)
        hud.setThinking(true)
        note(noteLabel)
        transcribeAudioSnapshot(retainingAs: takeID, retentionEnabled: retentionEnabled) { text, err, _ in
            DispatchQueue.main.async { completion(text, err, takeID, retentionEnabled) }
        }
    }

    // MARK: hotkey

    /// Route a chord command to its handler. The single place that maps `HotkeyCommand` -> action:
    /// adding a hotkey is a new `HotkeyCommand` case plus one arm here, with no edit to HotkeyMonitor.
    private func handle(command: HotkeyCommand) {
        switch command {
        case .lock:             toggleLock()
        case .cleanupToggle:    toggleCleanupMode()
        case .undo:             undo()
        case .levelUp:          changeLevel(+1)
        case .levelDown:        changeLevel(-1)
        case .cleanupSelection: oneShot.run(.cleanupSelection)
        case .email:            armBuiltIn(.email, command: .email)
        case .searchLocal:      armBuiltIn(.searchLocal, command: .searchLocal)
        case .searchGemini:     armBuiltIn(.searchGemini, command: .searchGemini)
        case .notes:            notes()
        case .dictionary:       showDictionaryAdd()
        case .bullseyeToggle:   toggleBullseye()
        case .history:          callbacks.onOpenHistory()
        case .recentDictations: showRecentDictations()
        }
    }

    /// Right-Option+H toggles the recent-dictations pop-up: a second press closes it. (VDLAND1 moved this off
    /// Shift+H; right-Option+Shift+H now opens Settings on the History tab.)
    private func showRecentDictations() {
        if let panel = recentDictationsPanel, panel.isVisible {
            panel.dismiss()
            return
        }
        if recentDictationsPanel == nil {
            recentDictationsPanel = RecentDictationsPanel(onOpenHistory: callbacks.onOpenHistory)
        }
        recentDictationsPanel?.show()
    }

    /// Right-Option+D toggles the add-to-dictionary pop-up: a second press closes it. (VDDICT moved the
    /// Dictionary tab off this chord; the pop-up's Open Dictionary button and the Settings window reach it.)
    private func showDictionaryAdd() {
        if let panel = dictionaryAddPanel, panel.isVisible {
            panel.dismiss()
            return
        }
        if dictionaryAddPanel == nil {
            dictionaryAddPanel = DictionaryAddPanel(onOpenDictionary: callbacks.onOpenDictionary)
        }
        dictionaryAddPanel?.show()
    }

    /// Route a matched custom-mode chord (by id) through the shared one-shot engine. Resolves the id to
    /// its live descriptor in the store; a stale id (deleted between tap dispatch and here) is a no-op.
    private func handleCustom(id: String) {
        guard let mode = CustomModeStore.shared.mode(id: id) else {
            Log.write("custom chord dispatch: no mode for id \(id) (stale)")
            return
        }
        let descriptor = mode.oneShotMode
        if descriptor.consumesTake {
            armOneShot(
                source: .custom(mode),
                descriptor: descriptor,
                glyph: mode.chord.keycapGlyph)
        } else {
            oneShot.runCustom(mode)
        }
    }

    /// Dictation-capable built-ins arm for this take; selection-only Option+P never reaches this helper
    /// and retains its immediate registry flow.
    private func armBuiltIn(_ mode: OneShotRegistry.Mode, command: HotkeyCommand) {
        let descriptor = OneShotRegistry.descriptor(for: mode)
        precondition(descriptor.consumesTake, "\(descriptor.id) is not dictation-capable")
        armOneShot(
            source: .builtIn(mode),
            descriptor: descriptor,
            glyph: hotkey.map.key(for: command).keycapGlyph)
    }

    /// Activate the one universal transform slot. Normal modes arm for this take; opted-in eligible
    /// modes flip their persistent occupant on or off. Neither path begins the existing registry flow
    /// yet: its guard/discard ordering and retry invalidation stay together at release.
    private func armOneShot(source: OneShotArmSource, descriptor: OneShotMode, glyph: String) {
        guard !rejectOneShotIfBusy(descriptor.id) else { return }
        let cleanupWasEnabled = CleanupState.shared.cleanupEnabled
        let lifetime: OneShotArmLifetime =
            descriptor.supportsPersistentToggle && Settings.persistentToggleEnabled(for: descriptor.id)
            ? .persistent : .perTake
        let arm = ArmedOneShot(
            source: source, id: descriptor.id, label: descriptor.label, glyph: glyph,
            lifetime: lifetime)
        let armed: Bool
        if lifetime == .persistent {
            armed = TransformArmState.shared.togglePersistentOneShot(arm)
        } else {
            armed = TransformArmState.shared.armOneShot(arm)
        }
        guard armed else {
            let restored = CleanupState.shared.badgeMode(forEnabled: CleanupState.shared.cleanupEnabled)
            Log.write("\(descriptor.id) \(lifetime == .persistent ? "persistent" : "per-take") toggle -> \(restored.label)")
            restoreDisplacedTransformPresentation(announce: true)
            return
        }
        Log.write(lifetime == .persistent
                  ? "\(descriptor.id) persistent toggle -> armed"
                  : "\(descriptor.id) armed for current take")

        hud.setCleanup(enabled: false, level: CleanupState.shared.cleanupLevel.rawValue)
        refreshAskBackToggle()
        hud.setArmedMode(glyph: glyph)
        hud.flashModeBadge(glyph: glyph, label: descriptor.label)
        if cleanupWasEnabled {
            callbacks.onCleanupModeChange(false)
            notesDelivery.refreshReplaceHighlightLevel()
        }
        note(lifetime == .persistent
             ? "\(descriptor.label): persistent"
             : "\(descriptor.label): armed")
    }

    /// Project the helper-restored Raw/Cleanup occupant back onto every live presentation surface. Both
    /// explicit un-toggle and per-take release use this path so Cleanup returns at its unchanged level.
    private func restoreDisplacedTransformPresentation(announce: Bool) {
        let cleanupEnabled = CleanupState.shared.cleanupEnabled
        let restored = CleanupState.shared.badgeMode(forEnabled: cleanupEnabled)
        hud.setArmedMode(glyph: nil)
        hud.setCleanup(enabled: cleanupEnabled, level: CleanupState.shared.cleanupLevel.rawValue)
        refreshAskBackToggle()
        callbacks.onCleanupModeChange(cleanupEnabled)
        notesDelivery.refreshReplaceHighlightLevel()
        if announce {
            hud.flashCleanupBadge(label: restored.label)
            note(restored.label)
        }
    }

    /// Route the stored descriptor through the pre-existing registry flow. The slot consumes a per-take
    /// arm before this returns it, while a persistent arm stays occupied for the next take.
    @discardableResult
    private func runArmedOneShotIfPresent() -> Bool {
        guard let arm = TransformArmState.shared.takeOneShotForRelease() else { return false }
        if arm.lifetime == .perTake {
            restoreDisplacedTransformPresentation(announce: false)
        }
        Log.write("\(arm.id) released from \(arm.lifetime == .persistent ? "persistent" : "per-take") arm")
        switch arm.source {
        case .builtIn(let mode):
            oneShot.run(mode)
        case .custom(let mode):
            oneShot.runCustom(mode)
        }
        return true
    }

    /// Re-check a persistent snapshot against the live setting and live custom descriptor. This is used
    /// after a Hotkeys edit so hiding an ineligible checkbox cannot strand an armed transform that its
    /// chord no longer knows how to turn off.
    private func persistentArmRemainsEnabled(_ arm: ArmedOneShot) -> Bool {
        guard Settings.persistentToggleEnabled(for: arm.id) else { return false }
        switch arm.source {
        case .builtIn(let mode):
            let descriptor = OneShotRegistry.descriptor(for: mode)
            return descriptor.id == arm.id && descriptor.supportsPersistentToggle
        case .custom(let snapshot):
            guard let current = CustomModeStore.shared.mode(id: snapshot.id) else { return false }
            return current.oneShotMode.id == arm.id && current.oneShotMode.supportsPersistentToggle
        }
    }

    private var secureInputGate = SecureInputWarningGate()
    /// The warning shown at this take's wakeup press. It is shown again at release, because a quick
    /// right-Option tap (the usual failed-lock gesture) ends the take at once and its "Nothing heard" toast
    /// would replace the warning after well under a second.
    private var secureWarningThisTake: String?

    private func rightOptionDown() {
        Log.write("ctrl.rightOptionDown state=\(state)")
        let holderPid = SecureInput.currentHolderPid()
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let warnPid = secureInputGate.shouldWarn(
            holderPid: holderPid, ownPid: ownPid, now: ProcessInfo.processInfo.systemUptime)
        if let holderPid, holderPid != ownPid {
            Log.write("secure input held by pid=\(holderPid): hotkeys that need a regular key are blocked\(warnPid == nil ? "" : ", warned")")
        }
        let wasIdle = state == .idle
        // The take starts first. The holder's name is looked up only afterwards (the press path before
        // recording does the session-dictionary read and nothing else), and only when a warning is due.
        // If beginRecording failed, its mic-error toast is the reason nothing records, so the warning
        // neither covers it now nor replays it at release. The toast comes after beginRecording so its HUD
        // presentation does not cover it; the toast's dwell returns the HUD to the recording scope.
        secureWarningThisTake = SecureInputPress.afterGate(
            warnPid: warnPid,
            beginRecording: {
                if wasIdle { self.startRecording() }
                return !(wasIdle && self.state == .idle)
            },
            appName: SecureInput.appName(pid:),
            toast: { self.hud.toast($0, duration: 7) })
        // In .locked, holding right-Option just arms the unlock chord; nothing else to do.
    }

    private func rightOptionUp() {
        // S2: the press that started a hold on a card ends with no Esc: the old take becomes the detached job.
        if let parked = askParkedFlow { askParkedFlow = nil; askParkedTake = nil; parked.parkedRelease() }
        // End the take ONLY from interface-unlocked recording. Arming changes what runs at the real end,
        // never what a wakeup release means while hands-free.
        if LockTransition.releaseEndsTake(
            phase: lockPhase(),
            hasArmedOneShot: TransformArmState.shared.armedOneShot != nil
        ) { finish() }
        if let warning = secureWarningThisTake {
            secureWarningThisTake = nil
            hud.toast(warning, duration: 7)
        }
    }

    /// The lock-relevant view of `state`, so `toggleLock` / `rightOptionUp` drive the pure `LockTransition`
    /// rules instead of open-coding the state check (item 6).
    private func lockPhase() -> LockTransition.Phase {
        switch state {
        case .recording: return .recording
        case .locked:    return .locked
        case .idle, .finishing, .oneShotFinishing, .reviewing, .asking, .writing: return .other
        }
    }

    private func toggleLock() {
        Log.write("toggleLock state=\(state)")
        let phase = lockPhase()
        switch LockTransition.toggle(phase) {
        case .lock:
            state = .locked
            wasLocked = LockTransition.wasLockedAfterToggle(current: wasLocked, phase: phase)  // latches true
            hud.update(state: "Locked — speaking", target: target?.label, text: "", locked: true)
            note("locked")
        case .unlock:
            // PURE toggle back to interface-unlocked recording — NOT finish(). The take keeps recording; it
            // ends only when right-Option is released while unlocked (see rightOptionUp). `wasLocked` stays
            // latched (the lock UI remembers a hands-free take); it does NOT select a delivery route. This is
            // the item-6 fix: the old .locked case called finish(), so a second spacebar transcribed +
            // delivered + idled the session.
            state = .recording
            wasLocked = LockTransition.wasLockedAfterToggle(current: wasLocked, phase: phase)  // preserved (true)
            hud.update(state: "Listening…", target: target?.label, text: "", locked: false)
            note("recording")
        case .ignore:
            break
        }
    }

    // MARK: cleanup mode (the `?` toggle and `Z` undo)

    /// `right-Option + ?`: flip the persistent Cleanup toggle. Per the control-key audio rule, `?`
    /// is a *mode selector tied to the current dictation* — it does NOT discard audio. The in-flight
    /// take keeps recording; state-at-release decides how it lands. Pops the keycap badge + updates
    /// the menubar indicator.
    private func toggleCleanupMode() {
        let enabled = CleanupState.shared.toggleCleanup()
        let mode = CleanupState.shared.badgeMode(forEnabled: enabled)
        // TransformArmState.toggleCleanup() clears any per-take mode because both occupy the same slot.
        hud.setArmedMode(glyph: nil)
        hud.flashCleanupBadge(label: mode.label)
        hud.setCleanup(enabled: enabled, level: CleanupState.shared.cleanupLevel.rawValue)
        refreshAskBackToggle()
        callbacks.onCleanupModeChange(enabled)
        notesDelivery.refreshReplaceHighlightLevel()   // BT4: a mid-take Raw<->Cleanup flip recolors the replace highlight
    }

    /// `right-Option + =` / `right-Option + -`: step the cleanup strength level (toward Summarize /
    /// toward Cleanup). No-op when cleanup is off (the slider is hidden then). Flashes the keycap badge
    /// with the new level label for live feedback and updates the persistent HUD slider + menubar.
    private func changeLevel(_ delta: Int) {
        guard CleanupState.shared.cleanupEnabled else { return }
        let before = CleanupState.shared.cleanupLevel
        let level = CleanupState.shared.stepLevel(delta)
        guard level != before else { return }
        hud.flashCleanupBadge(label: level.label)
        hud.setCleanup(enabled: true, level: level.rawValue)
        refreshAskBackToggle()
        notesDelivery.refreshReplaceHighlightLevel()   // BT4: a mid-take level step recolors the replace highlight
    }

    // MARK: VDASK-5 — the ? toggle on the HUD

    /// The ? button's state now: the setting, the active level and the provider that level's route resolves to
    /// (nil when the route is off). The same route resolution `deliver` uses, so the button and the review gate
    /// agree on what "local" means.
    func askBackToggleState() -> AskBackToggleState {
        let cleanupLevel = CleanupState.shared.cleanupLevel
        let route = LLMRouteID.cleanupRoute(for: cleanupLevel)
        let resolution = askSeams.resolve?(route) ?? Settings.modelsPower.resolveRoute(
            route, fallback: .local(Settings.cleanupModel))
        return AskBackToggleRules.state(enabled: Settings.askBackEnabled, level: AskBackLevel(cleanupLevel),
                                        provider: resolution.bundle.map { AskBackProvider($0.provider) })
    }

    /// Push the ? button's look to the HUD. Called when the level, the setting or a route changes.
    func refreshAskBackToggle() {
        hud.setAskBackToggle(askBackToggleState())
    }

    /// The ? button was clicked: flip the same setting the Settings checkbox writes, unless the button is greyed.
    /// It touches the setting only: no take starts, ends or is cancelled, and a flow already running keeps the
    /// context it froze when it began, so a click mid-take counts from the NEXT take.
    func toggleAskBackFromHUD() {
        guard let next = AskBackToggleRules.settingAfterClick(enabled: Settings.askBackEnabled, state: askBackToggleState())
        else { return }
        Settings.askBackEnabled = next
        refreshAskBackToggle()
    }

    /// The HUD strength slider was dragged with the mouse — set the level directly (no-op when off).
    private func setLevelFromSlider(_ raw: Int) {
        guard CleanupState.shared.cleanupEnabled else { return }
        let level = CleanupLevel.clamped(raw)
        guard level != CleanupState.shared.cleanupLevel else { return }
        CleanupState.shared.setLevel(level)
        hud.setCleanup(enabled: true, level: level.rawValue)
        refreshAskBackToggle()
        notesDelivery.refreshReplaceHighlightLevel()   // BT4: a mid-take slider drag recolors the replace highlight
    }

    /// What a take teardown clears. The distinction is whether the *gesture* is over too, not just the take:
    /// the one-shot seams below throw their incidental take away but keep running, and their landing still
    /// reads the take-START note snapshot (`notesDelivery.noteTarget`).
    /// - `full`: take and gesture are both over — clear every take-scoped field, stop audio, go idle.
    /// - `gestureContinues`: the incidental take is discarded but the one-shot gesture that started it
    ///   continues into a selection transform, which REUSES the take-START snapshot (refine2 BUG 2 / BT
    ///   item-4: by then the tint has collapsed the live selection, so re-snapshotting reads a bare caret and
    ///   the transform inserts-at-a-point instead of replacing the range). Audio still stops, state goes idle.
    /// - `stateOnly`: a finalized one-shot transcript was consumed — audio / activity / HUD ownership stays
    ///   with the one-shot caller, whose landing (or word-gate selection fallback) still needs the snapshot.
    private enum TeardownScope { case full, gestureContinues, stateOnly }

    private func teardownTake(_ scope: TeardownScope) {
        targetWasNotesWindow = false
        // Only a take whose gesture is also over may drop the snapshot; see TeardownScope.
        if case .full = scope { notesDelivery.noteTarget = nil }
        notesDelivery.teardownReplaceHighlight()   // BT4: always clear any tint the take armed
        if case .stateOnly = scope {} else { endAskFlowUI() }
        switch scope {
        case .full, .gestureContinues:
            logRecordingStop(takeID: nil)
            audio.stop(); setActive(false); state = .idle
        case .stateOnly:
            state = .idle
        }
    }

    /// Holding right-Option always starts audio capture, so a *pure command* chord (Z undo, P
    /// prompt-prep) must throw that incidental take away — no transcription, no history. No-op unless
    /// a take is actually in flight.
    func discardIncidentalAudio() {   // internal: OneShotContext seam
        guard state == .recording || state == .locked else { return }
        // A pure command (Option+P, a selection-only custom mode, or Undo) ends this take immediately.
        // If the user armed a dictation mode first, that per-take arm must not leak into the next take.
        // A persistent toggle deliberately survives this command.
        if let arm = TransformArmState.shared.cancelPerTakeArm() {
            Log.write("\(arm.id) per-take arm cleared by immediate command")
            hud.setArmedMode(glyph: nil)
        }
        // The gesture continues: OneShotRegistry.run() calls this, then captureSelection() reads the
        // take-START note snapshot back through authoritativeNoteTargetForGesture().
        askGraceUntil = heldNow() + Self.heldOneShotGrace
        teardownTake(.gestureContinues)
        hud.hide()
    }

    /// BT5 (Esc-cancel): abort the in-progress dictation take — nothing lands. Unlike `discardIncidentalAudio()`
    /// (the pure-command-chord seam, which only ever fires while a take is RECORDING because the wakeup is held),
    /// Esc can also arrive during `.finishing` (the main final transcribe / cleanup pass) or
    /// `.oneShotFinishing` (the one-shot transcribe / client / landing pipeline), so this covers every in-flight
    /// state and bumps `takeGeneration` to invalidate any pending completion for the aborted take. The target
    /// selection is left untouched (we never delivered), and the BT4 replace highlight is cleared.
    private func cancelTake() {
        guard state == .recording || state == .locked || state == .finishing || state == .oneShotFinishing
            || state == .reviewing || state == .writing else { return }
        if let parked = askParkedFlow { resumeParkedOldTake(parked); return }
        Log.write("take canceled (Esc) state=\(state)")
        // VDASK-3: a review or write in flight is cancelled with the take; its late answer pastes nothing.
        askFlow?.cancel()
        if let arm = TransformArmState.shared.cancelPerTakeArm() {
            Log.write("\(arm.id) per-take arm cleared by cancel")
            hud.setArmedMode(glyph: nil)
        }
        takeGeneration += 1          // invalidate any in-flight transcribe / cleanup completion (nothing lands)
        teardownTake(.full)
        hud.setThinking(false)
        hud.hide()
        note(readyHint)
    }

    /// `right-Option + N`: open or focus the sticky-notes surface, and nothing else (VDLAND2). The old
    /// dual-purpose in-note arm is gone with the note pin, so this chord behaves the same inside and outside
    /// a note. It is still a pure control: it never discards the in-flight take.
    private func notes() {
        Log.write("sticky notes (Option+N) invoked state=\(state)")
        callbacks.onOpenNotes()
        note(readyHint)
    }

    /// `right-Option + B` (rebindable): flips the ONE landing rule `Settings.bullseyeLandAtStart`. It stays
    /// where the user left it across takes and restarts. Like the `?` cleanup toggle, this is a mode change
    /// tied to the CURRENT dictation — it does NOT discard the in-flight take: the take keeps its frozen
    /// route and the toast says so while a take is in flight.
    private func toggleBullseye() {
        Log.write("bullseye toggle (Option+B) invoked state=\(state)")
        Settings.bullseyeLandAtStart = !Settings.bullseyeLandAtStart
        refreshBullseyeIndicator()
        hud.toast(LandingRoute.toggleToast(on: Settings.bullseyeLandAtStart, takeInFlight: state != .idle))
        note(readyHint)
    }

    /// Push the bullseye landing setting into the HUD so the info-pill glyph shows exactly when it is ON
    /// (VDLAND1). Cheap; safe to call whenever the state may have changed. Stays on the controller because it
    /// is a HUD call (the notes-delivery seam is deliberately HUD-free — ADR 0012).
    private func refreshBullseyeIndicator() {
        hud.setBullseyeArmed(Settings.bullseyeLandAtStart)
    }

    /// `right-Option + Z`: the two-tier undo. First, because holding right-Option started audio
    /// capture, discard any incidental audio (Z is a pure control — no transcription, no history).
    /// Then revert the last cleanup delivery: tier 1 backspaces the cleaned text and re-pastes the
    /// raw in place (freshest paste); tier 2 puts the raw on the clipboard with a toast.
    private func undo() {
        Log.write("undo invoked state=\(state)")
        if state == .recording || state == .locked {
            discardIncidentalAudio()
            note(readyHint)
        }
        // BT5: notes-only cross-focus undo. If the last delivery landed in a note, reach BACK into that note by
        // id and revert the edit (restoring any overwritten text) even when focus has moved away — a note is a
        // controlled surface the bridge can reach into. The routing + reach-back live on the coordinator; the
        // toast stays here (the seam is HUD-free). The foreign-app tier below is left as-is (it cannot cross
        // focus); the two are mutually exclusive, so `.notNote` falls through to it.
        switch notesDelivery.undoLastNoteDelivery() {
        case .reverted:
            hud.toast(NotesUndoLogic.notesRevertToast)
            return
        case .gone:
            hud.toast(NotesUndoLogic.notesGoneToast)
            return
        case .notNote:
            break
        }
        let tier = CleanupLogic.undoTier(hasPending: pendingUndo != nil,
                                         canRevertInPlace: pendingUndo?.canRevertInPlace ?? false,
                                         ageSeconds: pendingUndo.map { Date().timeIntervalSince($0.at) } ?? .infinity)
        guard let pending = pendingUndo else {
            hud.toast("Nothing to undo")
            return
        }
        pendingUndo = nil
        switch tier {
        case .inPlace:
            TargetResolver.undoLastPasteAndPasteRaw(pending.raw)
            hud.toast("Reverted to raw transcript")
        case .clipboard:
            TargetResolver.copyToClipboard(pending.raw)
            hud.toast("Original transcription on clipboard, ⌘V to use")
        case .none:
            hud.toast("Nothing to undo")
        }
    }

    // MARK: cleanup-suspect A/B picker

    /// Show the A/B picker for a flagged cleanup output. The HUD hides; the picker is driven entirely
    /// from the global tap (`abPickerActive`) so the user's text field keeps focus and the chosen text
    /// pastes straight back into it. We stay out of `.idle` until the user commits.
    private func presentABPicker(raw: String, cleaned: String, level: CleanupLevel, takeID: UUID,
                                 lateRecovery: Bool = false) {
        Log.write("cleanup suspect (\(raw.count)->\(cleaned.count) chars) — showing A/B picker")
        pendingPick = (raw: raw, cleaned: cleaned, level: level, takeID: takeID,
                       lateRecovery: lateRecovery)
        hud.hide()
        if let show = askSeams.abPickerShow { show(raw, cleaned) } else { abPicker.show(raw: raw, cleaned: cleaned) }
        hotkey.abPickerActive = true
        heldKick()
        note("pick raw or cleaned")
    }

    /// Commit the A/B picker choice: paste the selected candidate via the normal delivery path (which
    /// wires undo for free). Escape / `forceRaw` always lands the safe raw side.
    private func commitABPick(forceRaw: Bool = false) {
        guard let pick = pendingPick else { return }
        pendingPick = nil
        hotkey.abPickerActive = false
        heldKick()
        abPicker.hide()
        let chooseCleaned = !forceRaw && abPicker.selection == .cleaned
        if chooseCleaned {
            Log.write("A/B pick: cleaned")
            finalize(delivered: pick.cleaned, raw: pick.raw, cleaned: pick.cleaned, mode: .cleanup,
                     level: pick.level.rawValue, historyID: pick.takeID,
                     lateRecovery: pick.lateRecovery)
        } else {
            Log.write("A/B pick: raw")
            finalize(delivered: pick.raw, raw: pick.raw, cleaned: nil, mode: .raw,
                     historyID: pick.takeID, lateRecovery: pick.lateRecovery)
        }
    }

    // MARK: one-shot flow arbiter

    /// The single source of truth for "a mutually-exclusive one-shot flow is already running." Every
    /// one-shot entry asks this before starting. Reads `oneShot.isBusy` (which spans any one-shot mode's
    /// whole cycle, including its level-pick window) plus the Family-1 A/B picker, which stays bespoke on
    /// the coordinator (the transient picker counts as busy — a dictation is then mid-review). Adding a
    /// one-shot mode means adding its in-flight state to the registry's latch, not editing this predicate.
    /// VDASK-3: a card, a review in flight (`.reviewing`) and a question being asked (`.asking`) all count.
    var oneShotBusy: Bool {
        oneShot.isBusy || pendingPick != nil || hotkey.abPickerActive || hotkey.askCardActive
            || state == .reviewing || state == .asking
    }

    /// Reject a one-shot entry when another flow owns the stage (log + return true). The caller then
    /// returns, so two one-shot flows never overlap.
    func rejectOneShotIfBusy(_ label: String) -> Bool {   // internal: OneShotContext seam
        guard oneShotBusy else { return false }
        Log.write("\(label): a one-shot flow is already active — ignoring")
        return true
    }

    /// Shared "the LLM pass failed, leave the selected text untouched" routing for selection-input
    /// transforms (Cleanup-selection and email-selection). `.ok` is handled by the caller (payload + landing
    /// differ per mode); the three failure cases collapse to a logged reason + a mode-nouned toast, gated
    /// by `CleanupLogic.landing(for:)`. Search and the inline cleanup switch keep bespoke fallbacks because
    /// their failure ACTION differs (answer-surface toast / paste-raw), so routing them here would be false
    /// unification.
    private func failInPlace(_ result: CleanupClient.Result, uiNoun: String, logNoun: String,
                             timeoutDetail: LocalStreamTimeoutDetail?) {
        guard CleanupLogic.landing(for: result) == .rawFallback else { return }  // .ok: caller lands it
        guard let failure = TextTransformClient.safeFailure(for: result) else { return }
        guard let presentation = TextTransformClient.safeFailurePresentation(for: result, timeoutDetail: timeoutDetail) else { return }
        Log.write("\(logNoun) fallback classification=\(failure.logToken) — text untouched")
        hud.toast(
            "⚠️ \(uiNoun): \(presentation.userMessage) — text left as-is. Retry under Models on the Hotkeys tab.")
    }

    /// Land a successful selection-transform result through the focus fallback. The shared notes delivery
    /// helper has already attempted any snapshotted note target before this method runs. When the Notes web
    /// island is currently key, use its bridge because AX paste synthesis into a WKWebView is unreliable.
    private func landSelectionTransform(
        _ text: String,
        foreignTarget: DictationTarget?,
        lateRecovery: Bool,
        settled: @escaping () -> Void,
        completion: @escaping (TargetResolver.CapturedTargetLandingOutcome) -> Void
    ) {
        if !lateRecovery, callbacks.notesWindowIsKey(),
           notesDelivery.insertIntoActiveNote(text) == .delivered {
            Log.write("selection-transform landed via sticky-note bridge (\(text.count) chars)")
            completion(.landed)
            settled()
            return
        }
        if let foreignTarget = foreignTarget {
            if lateRecovery {
                TargetResolver.pasteIntoCapturedTargetWithoutActivation(
                    text, target: foreignTarget, settled: settled, completion: completion)
            } else {
                TargetResolver.pasteIntoCapturedTarget(
                    text, target: foreignTarget, settled: settled, completion: completion)
            }
        } else {
            if lateRecovery {
                TargetResolver.copyToClipboard(text)
                completion(.clipboardOnly(.destinationUnverifiable))
                settled()
            } else {
                completion(TargetResolver.pasteIntoFocus(text, onComplete: settled)
                    ? .landed : .clipboardOnly(.eventDispatchFailed))
            }
        }
    }

    /// The shared "land a one-shot selection-transform RESULT" path for the in-place transform modes
    /// (Option+P Cleanup-selection, Option+M email). On success: paste the transformed text back over
    /// the selection, record provenance to History, and — for undo-wired modes (email) — register the
    /// raw word-vomit as the tier-1 smart-undo source. On any failure: leave the text untouched via
    /// `failInPlace`. `levelLabel` only tunes the success log line (Cleanup-selection logs its picked
    /// level; email has none). Search and the inline cleanup switch in `deliver` deliberately do NOT
    /// route here — their landing surfaces and failure actions differ, so unifying would be false
    /// unification (see `failInPlace`).
    func landInPlaceTransform(_ result: CleanupClient.Result, input: String, mode: HistoryMode,
                                      level: Int?, wireUndo: Bool, uiNoun: String, logNoun: String,
                                      levelLabel: String?, inputSource: NotesBullseyeLogic.InputSource,
                                      noteTarget: NotesDictationTarget?,
                                      foreignTarget: DictationTarget?, historyID: UUID?,
                                      lateRecovery: Bool = false) {
        switch result {
        case .ok(let transformed):
            let levelSuffix = levelLabel.map { ", level=\($0)" } ?? ""
            Log.write("\(logNoun) paste-back attempt (\(input.count)->\(transformed.count) chars\(levelSuffix))")
            let recordHistory = {
                TranscriptionHistory.shared.record(
                    delivered: transformed, raw: input, cleaned: transformed,
                    mode: mode, level: level,
                    app: foreignTarget?.label ?? TargetResolver.captureFocused()?.label ?? "",
                    id: historyID ?? UUID())
            }

            // C1 / ADR 0016: this is the same stateful precedence helper raw / `?` delivery calls. A fresh
            // dictation with an in-place landing can route to the bullseye; selection input cannot.
            switch notesDelivery.routeNotesDelivery(
                delivered: transformed, mode: mode,
                landingKind: .inPlace, inputSource: inputSource, noteTarget: noteTarget,
                shouldInsertIntoNotes: false, startedInNotes: false, currentlyKey: false) {
            case .landed(let noteUndo):
                // Preserve the pre-C1 selection undo bookkeeping. Fresh dictation at a bullseye instead owns
                // the cross-focus note undo tier, exactly like raw / `?` delivery.
                let foreignUndo = inputSource == .selection && wireUndo
                    ? makePendingUndo(raw: input, delivered: transformed,
                                      revertable: true, canRevertInPlace: true)
                    : nil
                landDelivery(foreignUndo: foreignUndo,
                             noteUndo: inputSource == .dictation ? noteUndo : nil,
                             toast: nil, keepHUD: false)
                recordHistory()
                Log.write("\(logNoun) paste-back classification=landed")
                return
            case .parked(let toast, let refreshBullseye):
                if refreshBullseye { refreshBullseyeIndicator() }
                let foreignUndo = wireUndo
                    ? makePendingUndo(raw: input, delivered: transformed,
                                      revertable: true, canRevertInPlace: false)
                    : nil
                landDelivery(foreignUndo: foreignUndo, noteUndo: nil, toast: toast, keepHUD: false)
                recordHistory()
                Log.write("\(logNoun) paste-back classification=clipboard_parked")
                return
            case .notNotes:
                break
            }

            // The one-shot's own landing is the delivery in front of any held result: open until its paste check
            // and clipboard restore have finished (the registry's latch drops before this landing starts).
            let settle = beginDelivery()
            landSelectionTransform(transformed, foreignTarget: foreignTarget,
                                   lateRecovery: lateRecovery, settled: settle) {
                [weak self] outcome in
                guard let self = self else { return }
                if outcome.didLand {
                    if wireUndo {
                        self.pendingUndo = self.makePendingUndo(
                            raw: input, delivered: transformed,
                            revertable: true, canRevertInPlace: true)
                    }
                    self.notesDelivery.pendingNoteUndo = nil
                    recordHistory()
                    Log.write("\(logNoun) paste-back classification=landed")
                    self.hud.hide()
                } else {
                    Log.write("\(logNoun) paste-back classification=\(outcome.logToken) — original text unchanged")
                    self.hud.toast("📋 \(outcome.userMessage). Original text left unchanged.")
                }
            }
        case .unavailable, .timedOut, .badOutput:
            switch CleanupLogic.inPlaceFailureLanding(for: inputSource) {
            case .leaveExistingText:
                failInPlace(result, uiNoun: uiNoun, logNoun: logNoun,
                            timeoutDetail: oneShot.inFlightTimeoutDetail)
            case .deliverRawTranscript:
                let failure = TextTransformClient.safeFailure(for: result)!
                let presentation = TextTransformClient.safeFailurePresentation(for: result, timeoutDetail: oneShot.inFlightTimeoutDetail)!
                Log.write("\(logNoun) fallback classification=\(failure.logToken) — raw")
                hud.toast(
                    "⚠️ \(uiNoun): \(presentation.userMessage) — pasted raw. Retry under Models on the Hotkeys tab.")
                finalize(
                    delivered: input, raw: input, cleaned: nil, mode: .raw,
                    historyID: historyID ?? UUID(), keepHUD: true,
                    lateRecovery: lateRecovery)
            }
        }
    }

    // MARK: lifecycle

    private static func diagnosticTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func logRecordingStop(takeID: UUID?) {
        guard let started = recordingStartedAt else { return }
        let stopped = Date()
        recordingStartedAt = nil
        Log.write("recording.stop at=\(Self.diagnosticTimestamp(stopped)) "
            + "started_at=\(Self.diagnosticTimestamp(started)) "
            + "duration_s=\(String(format: "%.3f", stopped.timeIntervalSince(started))) "
            + "take=\(takeID?.uuidString ?? "not-transcribed")")
    }

    private func beginRecording() {
        // VDASK-3: a take that never starts the paste marker (a sticky-note target) must not anchor its ask card
        // to an earlier take's target.
        pasteMarker.lastPlacement = nil
        // A fresh take owns a new destination gesture; an older failed transform must never land later.
        TextTransformRetryCenter.shared.invalidate()
        // refine2 BUG 2: a fresh take is a fresh gesture — bump the monotonic generation the coordinator stamps
        // onto every snapshotTarget/replaceHighlight payload, so the JS snapshot store treats this take's writes
        // as newer than any prior gesture's (a genuinely new selection/caret always wins) while a same-gesture
        // collapsed re-read still cannot clobber the range captured just below.
        notesDelivery.gestureGeneration += 1
        // BT1: clear any stale snapshot up front so a take that does NOT start in a note (or a prior aborted
        // take) can never inherit an earlier take's note target. Re-captured below only in the notes-key branch.
        notesDelivery.noteTarget = nil
        if callbacks.notesWindowIsKey() {
            target = DictationTarget(element: AXUIElementCreateApplication(getpid()),
                                     pid: getpid(),
                                     label: "ViddyDictate — Sticky Notes",
                                     isTextLike: true)
            targetWasNotesWindow = true
            // BT1: snapshot the {note id, anchor} now, at take-START, if the caret is in a note. Delivery then
            // lands there even if focus moves during the take. nil (blank home / history) keeps today's path.
            let noteId = notesDelivery.captureNoteTargetForTake()
            Log.write("beginRecording target=ViddyDictate — Sticky Notes textLike=true notesWindow=true ax=skipped noteTarget=\(noteId ?? "nil")")
            // BT4: a take that started overwriting a selection in a note tints that range by the active
            // `?`-cleanup level (Raw color when cleanup is off) so the user sees what will be replaced. Only a
            // B-ON take overwrites its start selection; a B-OFF take lands at end focus, so it must not tint the
            // note's start range (VDLAND2 D14). The island no-ops on a bare-caret snapshot (nothing to replace).
            if Settings.bullseyeLandAtStart {
                notesDelivery.armReplaceHighlightForTake()
            }
        } else {
            target = TargetResolver.captureFocused()
            targetWasNotesWindow = (target?.pid == getpid()) && callbacks.notesWindowIsKey()
            Log.write("beginRecording target=\(target?.label ?? "nil") textLike=\(target?.isTextLike ?? false) notesWindow=\(targetWasNotesWindow)")
        }
        wasLocked = false
        takeLandAtStart = Settings.bullseyeLandAtStart
        DaemonClient.ensureUp { ok in Log.write("daemon ensureUp ok=\(ok)") }
        // Mark active BEFORE starting the engine so the settings preview releases the input device
        // first (the dictationActive observer is synchronous) — avoids two input taps at once.
        setActive(true)
        do {
            try audio.start()
            recordingStartedAt = Date()
            Log.write("recording.start at=\(Self.diagnosticTimestamp(recordingStartedAt!))")
        } catch {
            Log.write("mic start ERROR: \(error.localizedDescription)")
            hud.toast("⚠️ Mic error: \(error.localizedDescription)")
            teardownTake(.full)
            return
        }
        state = .recording
        // BT2: push the live bullseye armed state so the info-pill glyph gates correctly on this take.
        refreshBullseyeIndicator()
        hud.update(state: "Listening…", target: target?.label, text: "", locked: false)
        hud.show()
        if hud is HUDPanel && !targetWasNotesWindow { pasteMarker.start(captured: target, followsLive: LandingRoute.markerFollowsLive(bullseyeOn: takeLandAtStart)) }
        hud.setCleanup(enabled: CleanupState.shared.cleanupEnabled, level: CleanupState.shared.cleanupLevel.rawValue)
        refreshAskBackToggle()
        hud.setArmedMode(glyph: TransformArmState.shared.armedOneShot?.glyph)
        note("recording")
    }

    /// The one "Nothing heard" landing for both audio-side silence and text-side punctuation-only
    /// transcripts. Keeping the full teardown and toast here prevents the text safety net from
    /// becoming a second post-processing path.
    private func finishNothingHeard(_ reason: String) {
        Log.write(reason)
        teardownTake(.full)
        hud.toast("Nothing heard")
        note(readyHint)
    }

    private func finish() {
        guard state == .recording || state == .locked else { return }
        // Dictation-capable one-shot modes own release. Their existing registry flow performs the speech
        // check now, after the user has had the whole take to speak.
        if runArmedOneShotIfPresent() { return }
        // State-at-release wins: lock in how this dictation is processed at the instant of release.
        cleanupAtRelease = CleanupState.shared.cleanupEnabled
        levelAtRelease = CleanupState.shared.cleanupLevel
        Log.write("finish → final transcribe (cleanup=\(cleanupAtRelease) level=\(levelAtRelease.label))")
        // VDASK-3: freeze where the ask card would open BEFORE `state` changes and the marker clears: the paste
        // target the marker last placed, else the pointer (the HUD rides with it).
        if let placed = pasteMarker.lastPlacement, placed.kind != .pointer { askAnchor = placed.center }
        else { askAnchor = NSEvent.mouseLocation }
        state = .finishing
        let spoke = audio.detectedSpeech
        let takeID = spoke ? UUID() : nil
        logRecordingStop(takeID: takeID)
        audio.stop()
        // Silent / accidental tap: never paste a hallucinated phrase for audio that had no speech.
        guard spoke, let takeID else {
            finishNothingHeard("finish: no speech this take - skipping (silent tap)")
            return
        }
        let retentionEnabled = Settings.retainDictationAudio
        hud.update(state: "Transcribing…", target: target?.label, text: "", locked: false)
        note("transcribing")
        let generation = takeGeneration   // BT5: capture so an Esc-cancel during transcribe drops this landing
        transcribeAudioSnapshot(retainingAs: takeID, retentionEnabled: retentionEnabled) { [weak self] text, err, segments in
            DispatchQueue.main.async {
                self?.deliver(text: text, error: err, generation: generation, takeID: takeID,
                              retentionWasEnabled: retentionEnabled, segments: segments)
            }
        }
    }

    /// Keep the failed take live and retry only from its retained on-disk WAV. The generation check preserves
    /// Escape cancellation while the daemon is warming; no fresh microphone capture can enter this path.
    func retryRetainedTake(takeID: UUID, retentionWasEnabled: Bool, generation: Int,
                           completion: @escaping (RetainedTakeRecoveryResult) -> Void) {
        if retentionWasEnabled {
            Log.write("stt.recovery queued take=\(takeID.uuidString) source=retained-clip")
            // A daemon that reports its warm-up phase gets a plain "Speech engine is starting… 12s";
            // an older one keeps the original wording (DaemonWarmingHUD.legacyRetryToast).
            hud.toast(DaemonWarmingHUD.recoveryToast(for: DaemonClient.lastWarmStatus, now: Date()))
            note("retrying transcription")
            startWarmingTicker(generation: generation)
        }
        let stillCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return generation == self.takeGeneration
        }
        retainedTakeRecovery.recover(
            takeID: takeID, retentionWasEnabled: retentionWasEnabled,
            stillCurrent: stillCurrent
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard stillCurrent() else { return }
                self?.stopWarmingTicker()
                completion(result)
            }
        }
    }

    /// Every 2 s while this take's retained retry is pending, toast the daemon's latest warm-up phase.
    /// Says nothing when there is nothing true to say (an older daemon, a ready one, a stale reading), so
    /// the recovery spinner shows exactly as before. Stops on its own once the take is no longer this
    /// generation or no longer finishing, which covers Esc and a new take.
    private func startWarmingTicker(generation: Int) {
        stopWarmingTicker()
        warmingTicker = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard generation == self.takeGeneration,
                  self.state == .finishing || self.state == .oneShotFinishing else {
                self.stopWarmingTicker()
                return
            }
            guard let message = DaemonWarmingHUD.message(for: DaemonClient.lastWarmStatus, now: Date())
            else { return }
            self.hud.toast(message, duration: 2.5)
        }
    }

    private func stopWarmingTicker() {
        warmingTicker?.invalidate()
        warmingTicker = nil
    }

    /// Pure request builder shared by the runtime cleanup path and deterministic route-coverage tests.
    static func makeCleanupRequest(route: LLMRouteID, input: String,
                                   selected: LLMProviderBundle, systemPrompt: String,
                                   timeout: TimeInterval,
                                   timeoutDetail: LocalStreamTimeoutDetail? = nil) -> TextTransformRequest {
        TextTransformRequest(
            route: route, bundle: selected, sourceText: input,
            systemPrompt: systemPrompt,
            userMessage: CleanupClient.wrap(input), timeout: timeout,
            timeoutDetail: timeoutDetail ?? LocalStreamTimeoutDetail())
    }

    /// Internal, not private (vdtpwg3 repair, point 3): `TailCheckSelfTest`'s `hook-wired` arm drives
    /// the REAL raw-mode upstream call chain through this entry point (same pattern as `finalize()`'s
    /// own `private` -> `internal` widening in `vdtpwg2`). `segments` (vdtpwg4 repair, master ruling
    /// item v) is the real per-dictation daemon diagnostics, threaded all the way from
    /// `DaemonClient.transcribe` through `transcribeAudioSnapshot`'s completion to here, and now
    /// forwarded into every real `finalize()` call site below -- closing the gap `hook-wired`'s raw
    /// branch used to bless (`segmentRawTexts: []` asserted as correct). The retained-retry re-entry
    /// (`recovered: true`) is a narrower, pre-existing path with no daemon round-trip of its own
    /// (`RetainedTakeRecovery`'s own `Transcribe` typealias carries no segments); it keeps landing
    /// with `[]`, unchanged from today's real behavior, not a regression this link introduces.
    func deliver(text rawText: String?, error: String?, generation: Int, takeID: UUID,
                 retentionWasEnabled: Bool, recovered: Bool = false,
                 segments: [TailCheck.Segment] = []) {
        // BT5: an Esc-cancel that fired while this take was transcribing bumped `takeGeneration`; drop the stale
        // landing so nothing lands for the aborted take.
        guard generation == takeGeneration else {
            Log.write("deliver: dropped — take was canceled (gen \(generation) != \(takeGeneration))")
            return
        }
        guard let rawIn = rawText else {
            Log.write("deliver: transcription unavailable (error=\(error ?? "none")); retained retry requested")
            retryRetainedTake(
                takeID: takeID, retentionWasEnabled: retentionWasEnabled,
                generation: generation
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .recovered(let text):
                    self.deliver(text: text, error: nil, generation: generation, takeID: takeID,
                                 retentionWasEnabled: retentionWasEnabled, recovered: true)
                case .unavailable(let reason):
                    Log.write("deliver: retained retry unavailable take=\(takeID.uuidString) reason=\(reason)")
                    self.hud.toast("Take could not be retried: \(reason)")
                    self.teardownTake(.full)
                    self.note(self.readyHint)
                }
            }
            return
        }
        guard CleanupLogic.transcriptHasLettersOrDigits(rawIn) else {
            finishNothingHeard("deliver: transcript contains no letters or digits - skipping")
            return
        }
        // Daemon already filters hallucinations; this is a light second net before the LLM pass.
        // Correction dictionary Layer 1: deterministic hard-coded replacements run as the first
        // transform after STT, on EVERY dictation including raw passthrough (see ADR 0002).
        let raw = CorrectionDictionary.shared.applyHardCoded(CleanupLogic.cleanRepeats(rawIn))
        Log.write("transcript.app-postprocess take=\(takeID.uuidString) "
            + "daemon=\(String(reflecting: rawIn)) app=\(String(reflecting: raw))")

        // Raw mode (toggle off at release): land exactly as v1 does.
        guard cleanupAtRelease else {
            finalize(delivered: raw, raw: raw, cleaned: nil, mode: .raw, historyID: takeID,
                     lateRecovery: recovered, segments: segments)
            return
        }

        // Cleanup mode: atomic land-when-ready. Show the green-sine "thinking" spinner, run the raw
        // transcript through the LM Studio cleanup, and land the cleaned text in one shot. On
        // LM-Studio-down / timeout / bad output, fall back to the raw transcript + a toast (the two
        // failure modes collapse to one recovery path).
        hud.update(state: "Cleaning…", target: target?.label, text: "", locked: false)
        hud.setThinking(true)
        note("cleaning")
        // Length gate: short single utterances fall back to plain Cleanup so Tighten/Summarize can't
        // over-condense or drift them (see CleanupLogic.effectiveLevel).
        let wordCount = raw.split(whereSeparator: { $0.isWhitespace }).count
        let effectiveLevel = CleanupLogic.effectiveLevel(for: levelAtRelease, wordCount: wordCount)
        if effectiveLevel != levelAtRelease {
            Log.write("length gate: \(wordCount) words -> \(effectiveLevel.label) (was \(levelAtRelease.label))")
        }
        // Layer 2: ride the context-aware glossary into the cleanup pass's system prompt ("" when the
        // Dictionary's context column is empty, so this is a no-op until the user adds entries).
        let route = LLMRouteID.cleanupRoute(for: effectiveLevel)
        // Availability-resolved at release: the pin runs when it can, else the highest-preference available
        // provider does, else the route reports itself off and the raw transcript still lands below.
        let resolution = askSeams.resolve?(route) ?? Settings.modelsPower.resolveRoute(
            route, fallback: .local(Settings.cleanupModel))
        // RTY1: cleanup is the one path that steps down after a RAM-capacity refusal. Resolution already
        // avoids a model this machine cannot hold, but that judgement is made from wired bytes read a
        // moment earlier; when the actual load disagrees, the only thing left was the raw transcript. One
        // re-resolve, excluding the model that ACTUALLY ran (not the pin - routing may already have
        // substituted), lands the next largest installed model that fits. `effectiveResolution` tracks
        // which resolution finally ran so a crossing notice below still describes the model the user got.
        var effectiveResolution = resolution
        let capacityStepDown: TextTransformClient.CapacityStepDown = { ranModelID in
            let stepped = Settings.modelsPower.resolveRoute(
                route, fallback: .local(Settings.cleanupModel),
                failedProviders: [.local: CleanupClient.overBudgetMessage],
                failedLocalModelID: ranModelID)
            effectiveResolution = stepped
            return stepped
        }
        // Every provider returns the shared `CleanupClient.Result`, so landing/raw fallback stays in one
        // closure. Power Mode never participates in the dispatch choice.
        let timeoutDetail = LocalStreamTimeoutDetail()
        var fallbackReceipt: CleanupFallbackReceipt?
        var deferredRetryResult: CleanupClient.Result?
        // VDASK-3: the ask-back flow of this take (nil when the take never asks) and its current write id.
        weak var flowRef: AskBackFlow?
        var askWriteID: UUID?
        // What a finished write does (main thread, take still current). The ask-back flow admits the
        // take's one write result and then calls this; every other take reaches it directly from `onResult`.
        let handleResult: (CleanupClient.Result) -> Void = { [weak self] result in
            do {
                guard let self = self else { return }
                self.hud.setThinking(false)
                switch result {
                case .ok(let cleaned):
                    // Sanity guard: a cleanup output that grew well past the input is the rogue
                    // signal (it answered instead of cleaning). Don't auto-paste — let the user pick.
                    if CleanupLogic.cleanupSuspect(rawCount: raw.count, cleanedCount: cleaned.count) {
                        self.presentABPicker(raw: raw, cleaned: cleaned, level: effectiveLevel,
                                             takeID: takeID, lateRecovery: recovered)
                    } else {
                        self.finalize(delivered: cleaned, raw: raw, cleaned: cleaned, mode: .cleanup,
                                      level: effectiveLevel.rawValue, historyID: takeID,
                                      lateRecovery: recovered, segments: segments)
                        if let offer = effectiveResolution.upgradeOffer {
                            self.hud.toast(offer.message)
                        }
                    }
                case .unavailable, .timedOut, .badOutput:
                    let failure = TextTransformClient.safeFailure(for: result)!
                    let presentation = TextTransformClient.safeFailurePresentation(for: result, timeoutDetail: timeoutDetail)!
                    Log.write("cleanup fallback classification=\(failure.logToken) → raw")
                    self.hud.toast(
                        "⚠️ \(presentation.userMessage) — pasted raw. Retry under Models on the Hotkeys tab.")
                    // B13: the raw transcript still lands exactly as before, and THEN the missing piece
                    // explains itself and offers to install itself. Only for `.unavailable`: a timeout or
                    // a bad output means the model ran, and there is nothing to install.
                    if case .unavailable = result {
                        PointOfUseOfferPresenter.shared.presentOffer(for: .cleanup)
                    }
                    self.finalize(
                        delivered: raw, raw: raw, cleaned: nil, mode: .raw,
                        historyID: takeID, keepHUD: true, lateRecovery: recovered, segments: segments
                    ) { [weak self] receipt in
                        guard let self = self else { return }
                        fallbackReceipt = receipt
                        if let deferred = deferredRetryResult {
                            deferredRetryResult = nil
                            self.landCleanupRetry(deferred, raw: raw, level: effectiveLevel,
                                                  receipt: receipt, timeoutDetail: timeoutDetail,
                                                  historyID: flowRef?.record != nil ? takeID : nil)
                        }
                    }
                }
            }
        }
        let onResult: (CleanupClient.Result) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // BT5: an Esc-cancel during the cleanup pass bumped `takeGeneration`; drop this landing so nothing
                // lands for the aborted take.
                guard generation == self.takeGeneration else {
                    Log.write("cleanup result: dropped — take was canceled (gen \(generation) != \(self.takeGeneration))")
                    return
                }
                if let flow = flowRef, let writeID = askWriteID {
                    var ok = false
                    if case .ok = result { ok = true }
                    flow.writeFinished(writeID, ok: ok) { handleResult(result) }
                } else {
                    handleResult(result)
                }
            }
        }
        let onRetryResult: (CleanupClient.Result) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.takeGeneration else { return }
                if let receipt = fallbackReceipt {
                    self.landCleanupRetry(result, raw: raw, level: effectiveLevel,
                                          receipt: receipt, timeoutDetail: timeoutDetail,
                                          historyID: flowRef?.record != nil ? takeID : nil)
                } else {
                    // Locked captured-target landing is completion-based. Preserve a fast explicit retry
                    // until its first-attempt destination receipt exists instead of guessing a destination.
                    deferredRetryResult = result
                    Log.write("cleanup explicit retry deferred until fallback landing receipt")
                }
            }
        }
        // VDASK-3: the answers block rides in the request this closure builds, so the first write, an explicit
        // retry and the A/B picker all send the same answers. Zero questions (or no review) adds nothing.
        var askQuestions: [AskBackQuestion] = []
        var askAnswers: [AskBackAnswer?] = []
        let makeRequest: (LLMProviderBundle, [AskBackQuestion], [AskBackAnswer?], LocalStreamTimeoutDetail)
            -> TextTransformRequest = { bundle, questions, answers, detail in
            let providerPrompt = Settings.modelsPower.effectiveDeveloperInstructions(
                for: route, provider: bundle.provider,
                glossarySuffix: CorrectionDictionary.shared.contextGlossarySuffix())
            let retryTimeout = Settings.timeout(
                local: Settings.cleanupTimeout, provider: bundle.provider)
            let withFidelity = CleanupFidelity.appending(to: providerPrompt, routeKey: route.rawValue)
            return Self.makeCleanupRequest(
                route: route, input: raw, selected: bundle,
                systemPrompt: AskBackAnswersBlock.appending(
                    to: withFidelity, level: AskBackLevel(effectiveLevel), questions: questions, answers: answers),
                timeout: retryTimeout, timeoutDetail: detail)
        }
        let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
            makeRequest(bundle, askQuestions, askAnswers, timeoutDetail)
        }
        let claudeAdapter: TextTransformClient.AsyncAdapter = askSeams.claudeWrite
            ?? TextTransformClient.liveClaudeAdapter
        let runWrite: () -> Void = {
            TextTransformClient.transformResolved(
                resolution, route: route, requestForBundle: requestForBundle,
                local: CleanupClient.localAdapter(surface: .cleanup), claude: claudeAdapter,
                capacityStepDown: capacityStepDown,
                retryCompletion: onRetryResult, completion: onResult)
        }

        // The review gate: ask-back on, Tighten or Summarize, a Claude or Codex route, at least 50 words, and a
        // live take (a late retained-clip recovery has no card to ask on). Otherwise the write runs as before.
        guard !recovered, let askProvider = resolution.bundle.map({ AskBackProvider($0.provider) }),
              AskBackReview.gate(wordCount: wordCount, level: AskBackLevel(effectiveLevel),
                                 provider: askProvider, enabled: Settings.askBackEnabled)
        else { runWrite(); return }
        let tier = Settings.askBackTier
        let context = AskBackFlow.Context(
            historyID: takeID, transcript: raw, level: AskBackLevel(effectiveLevel),
            levelRaw: effectiveLevel.rawValue, tier: tier, provider: askProvider,
            writeModel: resolution.bundle?.modelID ?? "", generation: generation)
        let hooks = AskBackFlow.Hooks(
            phaseChanged: { [weak self] phase in self?.askPhaseChanged(phase) },
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
                    runner = AskBackReviewRunner.live(resolution: resolution, deliver: deliverReview)
                }
                self?.askRunner = runner
                runner.start(id: id, text: raw, level: AskBackLevel(effectiveLevel), tier: tier, source: .dictation)
            },
            skipReview: { [weak self] id in self?.askRunner?.skip(id) },
            showCard: { [weak self] card in self?.askShowCard(card) },
            highlight: { [weak self] id, index in self?.askCardPanel?.setHighlight(cardID: id, index: index) },
            closeCard: { [weak self] _ in self?.hotkey.askCardActive = false },
            startWrite: { [weak self] spec in
                askQuestions = spec.questions
                askAnswers = spec.answers
                askWriteID = spec.writeID
                self?.hud.update(state: "Cleaning…", target: self?.target?.label, text: "", locked: false)
                self?.hud.setThinking(true)
                self?.note("cleaning")
                runWrite()
            },
            history: { [weak self] event in TranscriptionHistory.shared.apply(event, app: self?.target?.label ?? "") },
            saveDetached: { [weak self] job in
                // The write touches nothing of the controller: the old take's own request and a History update. A
                // dictation take's result is then held (`AskBackHeldQueue`) and pastes after the new take.
                if job.holdsResult {
                    self?.askHeldInfo[job.historyID] = (job.transcript, job.levelRaw)
                    self?.heldApply { $0.resultExpected(job.historyID) }
                }
                AskBackDetached.run(job, now: self?.askSeams.now ?? { ProcessInfo.processInfo.systemUptime }, write: { _, done in
                    guard let bundle = resolution.bundle else { done(nil); return }
                    let request = makeRequest(bundle, job.questions, job.answers, LocalStreamTimeoutDetail())
                    TextTransformClient.transform(request, local: CleanupClient.localAdapter(surface: .cleanup),
                                                  claude: claudeAdapter, arming: .inert) { result in
                        DispatchQueue.main.async { if case .ok(let text) = result { done(text) } else { done(nil) } }
                    }
                }, history: { event in TranscriptionHistory.shared.apply(event) },
                completed: { [weak self] id, text in
                    guard job.holdsResult else { return }
                    if text == nil { self?.askHeldInfo.removeValue(forKey: id) }
                    self?.heldApply { queue in
                        if let text = text { return queue.resultReady(id, text: text) }
                        return queue.resultFailed(id)
                    }
                })
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
                request.write(spec.questions, spec.answers) { result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        var ok = false
                        if case .ok = result { ok = true }
                        flowRef?.writeFinished(spec.writeID, ok: ok) {
                            self.landSelectionAskResult(result, request: request)
                            release()
                        }
                    }
                }
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
                             historyID: request.historyID)
        // Same B13 offer the normal Option+P tail shows. A detached job never reaches here.
        if case .unavailable = result, let feature = PointOfUseFeature.forRoute(.promptPrep) {
            PointOfUseOfferPresenter.shared.presentOffer(for: feature)
        }
        setActive(false)
        state = .idle
        note(readyHint)
    }

    // MARK: ask-back glue (VDASK-3). The rules live in `AskBackFlow`; these are its hands.

    private static let mainSchedule: AskBackFlow.Schedule = { after, fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
        return { item.cancel() }
    }

    // MARK: held results. The rules live in `AskBackHeldQueue`; these feed it events and do its pastes.

    private func heldNow() -> TimeInterval { (askSeams.now ?? { ProcessInfo.processInfo.systemUptime })() }

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
    private func heldApply(_ event: (inout AskBackHeldQueue) -> [AskBackHeldQueue.Paste]) {
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
    private func heldKick() {
        guard !askHeld.isEmpty, askHeldKick == nil else { return }
        askHeldKick = (askSeams.schedule ?? Self.mainSchedule)(0) { [weak self] in
            self?.askHeldKick = nil
            self?.heldApply { $0.poke() }
        }
    }

    /// Opens a delivery: its paste check and clipboard restore have not finished. The returned closure closes it
    /// (once) and gives a waiting held result its turn.
    private func beginDelivery() -> () -> Void {
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

    private func askPhaseChanged(_ phase: AskBackFlow.Phase) {
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

    private func askReadingCue(_ on: Bool) {
        if on {
            hud.update(state: AskCardText.readingCue, target: target?.label, text: "", locked: false)
            hud.setThinking(true)
            note("reading your take")
        } else {
            hud.setThinking(false)
        }
    }

    private func askShowCard(_ card: AskCardModel) {
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
    private func askStartNewTake() {
        askParkedFlow = askFlow
        askParkedTake = (target, targetWasNotesWindow, takeLandAtStart, notesDelivery.noteTarget)
        askFlow = nil
        endAskFlowUI()
        state = .idle
        startRecording()
    }

    // VDASK-4 voice answer. The take's own recorder and its own transcriber (`transcribeAudioSnapshot`, which posts
    // to the same daemon and Whisper model a take uses): no second capture stack. The take's audio is stopped
    // while a card is up, so the recorder is free; the HUD and the take's state are not touched.

    // BEGIN askvoice-mic (the Linux oracle cuts this region out and runs it)
    /// Whether the mic grant lets a voice answer start: only `.authorized`. Not determined, denied and restricted
    /// (which `Permissions.microphoneAuthorization()` reports as denied) all give "Mic unavailable.".
    static func askVoiceMicGranted(_ status: MicrophoneAuthorization) -> Bool {
        switch status {
        case .authorized: return true
        case .notDetermined, .denied: return false
        }
    }
    // END askvoice-mic

    /// False when the mic cannot start (busy or permission missing).
    private func askVoiceStart() -> Bool {
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

    private func askVoiceDiscard() {
        if let discard = askSeams.voiceDiscard { discard(); return }
        audio.stop()
    }

    /// Stops capture and transcribes; `done` gets the text, or nil when nothing was heard or the daemon failed.
    private func askVoiceStop(_ done: @escaping (String?) -> Void) {
        if let transcribe = askSeams.voiceTranscribe { transcribe(done); return }
        audio.stop()
        guard audio.detectedSpeech else { done(nil); return }      // silence never goes to Whisper
        transcribeAudioSnapshot { text, _, _ in done(text) }
    }

    /// Starts a take's recording. The headless trace test replaces the audio-and-AX start with
    /// `askSeams.beginNewTake`; production always takes `beginRecording()`.
    private func startRecording() {
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
    private func resumeParkedOldTake(_ parked: AskBackFlow) {
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

    private func endAskFlowUI() {
        hotkey.askCardActive = false
        hotkey.askReviewActive = false
        askCardPanel?.hide()
    }

    /// Replace the first attempt's raw fallback at its captured destination. A retry failure only refreshes
    /// the exact safe classification and re-arms Retry; raw is never pasted a second time.
    private func landCleanupRetry(_ result: CleanupClient.Result, raw: String, level: CleanupLevel,
                                  receipt: CleanupFallbackReceipt?,
                                  timeoutDetail: LocalStreamTimeoutDetail,
                                  historyID: UUID? = nil) {
        switch result {
        case .ok(let cleaned):
            let landed: Bool
            switch receipt {
            case .note(let noteID):
                landed = noteID.map { notesDelivery.replaceLastNoteDelivery(noteId: $0, text: cleaned) } ?? false
                if landed { pendingUndo = nil; notesDelivery.pendingNoteUndo = noteID }
            case .foreign(let captured):
                if let captured = captured {
                    TargetResolver.replaceLastPaste(in: captured, with: cleaned) { [weak self] outcome in
                        guard let self = self else { return }
                        self.completeForeignCleanupRetryLanding(
                            outcome, cleaned: cleaned, raw: raw, level: level,
                            targetLabel: captured.label, historyID: historyID)
                    }
                    return
                } else {
                    TargetResolver.copyToClipboard(cleaned)
                    completeForeignCleanupRetryLanding(
                        .clipboardOnly(.destinationUnverifiable),
                        cleaned: cleaned, raw: raw, level: level, targetLabel: "", historyID: historyID)
                    return
                }
            case .pastePark:
                landed = replaceParkedClipboard(with: cleaned)
                if landed { pendingUndo = nil; notesDelivery.pendingNoteUndo = nil }
            case .clipboard(let changeCount):
                if NSPasteboard.general.changeCount == changeCount {
                    TargetResolver.copyToClipboard(cleaned)
                    askLastClosedCount = NSPasteboard.general.changeCount   // the record follows the clipboard (as replaceParkedClipboard does)
                    landed = true
                } else {
                    landed = false
                }
                if landed { pendingUndo = nil; notesDelivery.pendingNoteUndo = nil }
            case nil:
                landed = false
            }
            if landed {
                Log.write("cleanup explicit retry landed (\(raw.count)->\(cleaned.count) chars, level=\(level.label))")
                TranscriptionHistory.shared.record(
                    delivered: cleaned, raw: raw, cleaned: cleaned, mode: .cleanup,
                    level: level.rawValue, app: target?.label ?? "", id: historyID ?? UUID())
                hud.hide()
            } else {
                Log.write("cleanup explicit retry output could not restore captured landing")
                hud.answer(cleaned)
            }
        case .unavailable, .timedOut, .badOutput:
            let failure = TextTransformClient.safeFailure(for: result)!
            let presentation = TextTransformClient.safeFailurePresentation(for: result, timeoutDetail: timeoutDetail)!
            Log.write("cleanup explicit retry classification=\(failure.logToken) — raw unchanged")
            hud.toast(
                "⚠️ \(presentation.userMessage) — raw text left unchanged. Retry under Models on the Hotkeys tab.")
        }
    }

    /// The retry state owner records/arms undo only for a validated field landing. Clipboard recovery is
    /// deliberately non-landing even though it preserves the successful provider output for manual use.
    static func shouldRecordForeignRetryLanding(
        _ outcome: TargetResolver.CapturedTargetLandingOutcome
    ) -> Bool {
        outcome.didLand
    }

    private func completeForeignCleanupRetryLanding(
        _ outcome: TargetResolver.CapturedTargetLandingOutcome,
        cleaned: String,
        raw: String,
        level: CleanupLevel,
        targetLabel: String,
        historyID: UUID? = nil
    ) {
        guard Self.shouldRecordForeignRetryLanding(outcome) else {
            Log.write("cleanup explicit retry classification=\(outcome.logToken) — raw unchanged")
            hud.toast("📋 \(outcome.userMessage). Raw text left unchanged.")
            return
        }
        pendingUndo = makePendingUndo(raw: raw, delivered: cleaned,
                                      revertable: true, canRevertInPlace: true)
        notesDelivery.pendingNoteUndo = nil
        Log.write("cleanup explicit retry landed (\(raw.count)->\(cleaned.count) chars, level=\(level.label))")
        TranscriptionHistory.shared.record(
            delivered: cleaned, raw: raw, cleaned: cleaned, mode: .cleanup,
            level: level.rawValue, app: targetLabel, id: historyID ?? UUID())
        hud.hide()
    }

    private func replaceParkedClipboard(with text: String) -> Bool {
        guard let park = pastePark, NSPasteboard.general.changeCount == park.changeCount else { return false }
        SyntheticPasteboard.write(text)
        pastePark = PastePark(previous: park.previous, changeCount: NSPasteboard.general.changeCount)
        hotkey.pasteRestoreArmed = true
        return true
    }

    /// Land `delivered` into the captured target and record the raw/cleaned/mode provenance. Sets up
    /// the undo state when a distinct cleaned version was delivered. `keepHUD` leaves a fallback toast
    /// on screen instead of hiding the HUD. Always returns the state machine to idle. Synchronous branches
    /// return their receipt immediately; locked captured-target delivery returns nil and reports the receipt
    /// through `completion` after the captured target either lands or recovers to the clipboard.
    /// One place that builds the two-tier undo record: a revertable take gets a `PendingUndo`
    /// (in-place only for the push-to-talk same-field path, which passes `canRevertInPlace: true`),
    /// everything else gets nil. Centralized so undo-eligibility policy lives in one spot rather than
    /// duplicated across `finalize()`'s delivery branches.
    private func makePendingUndo(raw: String, delivered: String, revertable: Bool,
                                 canRevertInPlace: Bool) -> PendingUndo? {
        revertable
            ? PendingUndo(raw: raw, cleaned: delivered, canRevertInPlace: canRevertInPlace, at: Date())
            : nil
    }

    /// Internal, not private (vdtpwg2 repair, part C/D): `TailCheckSelfTest`'s `hook-wired`/
    /// `hook-after-paste` arms call this directly (the smallest real entry point that reaches the
    /// tail-check hook) to prove the hook is wired, gated, and ordered for real, rather than by
    /// grepping this file's source text. `segments` (vdtpwg4 repair, master ruling item v): `deliver()`
    /// now threads the daemon's real per-dictation segments into every one of its own three real calls
    /// here (raw, cleanup-success, cleanup-fallback) -- a test can still prove exact pass-through of
    /// whatever this parameter is given, for a direct call that bypasses `deliver()` entirely.
    @discardableResult
    func finalize(delivered: String, raw: String, cleaned: String?, mode: HistoryMode,
                  level: Int? = nil, historyID: UUID, keepHUD: Bool = false,
                  lateRecovery: Bool = false, segments: [TailCheck.Segment] = [],
                  completion: ((CleanupFallbackReceipt) -> Void)? = nil) -> CleanupFallbackReceipt? {
        // VDASK-3: this delivery is open until its paste check and clipboard restore have finished (or it never
        // pasted); a held result waits for that. Every branch below closes it exactly once.
        let settle = beginDelivery()
        let finish: (CleanupFallbackReceipt) -> CleanupFallbackReceipt = { receipt in
            // The tail-check hook (2026-10-06 scope addition, part D): every branch above this closure
            // already performed its real delivery (paste synth, clipboard write, or notes landing)
            // before calling `finish`, so this call is always strictly after that write is observable --
            // `finish` is finalize()'s one shared tail, reached exactly once per delivered dictation.
            if Settings.tailCheckEnabled {
                let cleanupLevel = TailCheck.cleanupLevelString(for: level.flatMap(CleanupLevel.init(rawValue:)))
                self.tailCheckHook.call(finalText: delivered, rawText: raw, segments: segments,
                                        cleanupLevel: cleanupLevel)
            }
            // The delivery's own outcome, for a held result whose turn comes next: did it leave its text on the
            // clipboard for a manual Cmd+V, and what was the pasteboard's changeCount then.
            switch receipt {
            case .clipboard(let count): self.askLastClipboardOnly = true; self.askLastClosedCount = count
            case .pastePark: self.askLastClipboardOnly = true; self.askLastClosedCount = self.clipboardPasteboard.changeCount
            case .note, .foreign: self.askLastClipboardOnly = false
            }
            self.teardownTake(.full)
            self.note(self.readyHint)
            completion?(receipt)
            self.onDictationSucceeded?()
            return receipt
        }
        TranscriptionHistory.shared.record(delivered: delivered, raw: raw, cleaned: cleaned,
                                           mode: mode, level: level, app: target?.label ?? "",
                                           id: historyID)
        let revertable = CleanupLogic.isRevertable(raw: raw, cleaned: cleaned)

        // Notes delivery (ADR 0012): the coordinator routes the take's snapshotted note target (B ON only,
        // plus a late-recovery retry, which keeps its base inputs) > the key-window insert, and performs the
        // note-undo bookkeeping + the gone-note clipboard-park. The HUD + the foreign `pendingUndo` tail stay
        // here (the seam is HUD-free), applied via `landDelivery`. The key-window discriminators read `target`,
        // so they are computed here and passed in (VDLAND2 D14: with B OFF a live take is offered no snapshot
        // and inserts only when a sticky note is the key window when the take ENDS).
        let notesWindowCurrentlyKey = callbacks.notesWindowIsKey()
        // A late retry may run after the user has moved to another note. Only its exact take-start snapshot may
        // receive the text; never reinterpret the currently active note as the old target.
        let shouldInsertIntoNotes = lateRecovery ? false : (takeLandAtStart ? (targetWasNotesWindow || (notesWindowCurrentlyKey && (target?.pid == getpid()))) : notesWindowCurrentlyKey)
        switch notesDelivery.routeNotesDelivery(delivered: delivered, mode: mode,
                                                landingKind: .inPlace,
                                                inputSource: .dictation,
                                                noteTarget: (takeLandAtStart || lateRecovery) ? notesDelivery.noteTarget : nil,
                                                shouldInsertIntoNotes: shouldInsertIntoNotes,
                                                startedInNotes: targetWasNotesWindow,
                                                currentlyKey: notesWindowCurrentlyKey) {
        case .landed(let noteUndo):
            landDelivery(foreignUndo: nil, noteUndo: noteUndo, toast: nil, keepHUD: keepHUD)
            defer { settle() }
            return finish(.note(noteUndo))
        case .parked(let toast, let refreshBullseye):
            // The info-pill push is a HUD call, so it stays here; it reads the post-drop armed state (false),
            // which the coordinator already committed, so its exact position relative to the drop is immaterial.
            if refreshBullseye { refreshBullseyeIndicator() }
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: false),
                         noteUndo: nil, toast: toast, keepHUD: keepHUD)
            defer { settle() }
            return finish(.clipboard(changeCount: NSPasteboard.general.changeCount))
        case .notNotes:
            break
        }

        if lateRecovery {
            guard let captured = target else {
                TargetResolver.copyToClipboard(delivered)
                Log.write("deliver: recovered take has no captured target; copied to clipboard "
                    + "(\(delivered.count) chars, mode=\(mode))")
                landDelivery(
                    foreignUndo: makePendingUndo(
                        raw: raw, delivered: delivered, revertable: revertable,
                        canRevertInPlace: false),
                    noteUndo: nil,
                    toast: "Recovered take copied to clipboard; original field unavailable.",
                    keepHUD: true)
                defer { settle() }
                return finish(.clipboard(changeCount: NSPasteboard.general.changeCount))
            }
            TargetResolver.pasteIntoCapturedTargetWithoutActivation(
                delivered, target: captured, settled: settle
            ) { [weak self] outcome in
                guard let self else { return }
                if outcome.didLand {
                    Log.write("deliver: recovered take landed at captured target without activation "
                        + "(\(delivered.count) chars, mode=\(mode))")
                    self.landDelivery(
                        foreignUndo: self.makePendingUndo(
                            raw: raw, delivered: delivered, revertable: revertable,
                            canRevertInPlace: false),
                        noteUndo: nil, toast: nil, keepHUD: keepHUD)
                    _ = finish(.foreign(captured))
                } else {
                    Log.write("deliver: recovered take preserved on clipboard "
                        + "(classification=\(outcome.logToken), \(delivered.count) chars, mode=\(mode))")
                    self.landDelivery(
                        foreignUndo: self.makePendingUndo(
                            raw: raw, delivered: delivered, revertable: revertable,
                            canRevertInPlace: false),
                        noteUndo: nil,
                        toast: "Recovered take copied to clipboard; original field changed.",
                        keepHUD: true)
                    _ = finish(.clipboard(changeCount: NSPasteboard.general.changeCount))
                }
            }
            return nil
        }

        // Where this take lands is decided by the FROZEN per-take rule and nothing else (VDLAND1): the setting
        // captured at take START picks live focus at take END, the field captured at take START, or — when it
        // says "start field" but no field was captured — the locked no-target landing. The hands-free lock is a
        // lock, not a route.
        switch LandingRoute.route(bullseyeOn: takeLandAtStart, hasTarget: target != nil) {
        case .live:
            let receipt = deliverPushToTalk(
                delivered: delivered, raw: raw, mode: mode,
                revertable: revertable, keepHUD: keepHUD, settled: settle)
            return finish(receipt)

        case .pinned:
            // `.pinned` means the route saw `target != nil`, so this guard never fires; it keeps the compiler
            // honest without a second no-target delivery call in this function.
            guard let captured = target else { settle(); return nil }
            deliverLocked(
                delivered: delivered, raw: raw, mode: mode, captured: captured,
                revertable: revertable, keepHUD: keepHUD, settled: settle, finish: finish)
            return nil

        case .pinnedNoTarget:
            let receipt = deliverLockedNoTarget(
                delivered: delivered, raw: raw, mode: mode,
                revertable: revertable, keepHUD: keepHUD)
            defer { settle() }
            return finish(receipt)
        }
    }

    /// Push-to-talk: focus is still on the field we dictated into, so synthesize a paste. This is
    /// the universal path - native, Electron (Claude/Obsidian/Slack), browsers, terminals. We do
    /// NOT use AX insert here: Electron returns "success" for an AX set while silently dropping
    /// the text, so paste is both more reliable and consistent across apps.
    private func deliverPushToTalk(delivered: String, raw: String, mode: HistoryMode,
                                   revertable: Bool, keepHUD: Bool,
                                   settled: @escaping () -> Void) -> CleanupFallbackReceipt {
        // Re-check focus at delivery. Push-to-talk normally lands by synthesizing Cmd+V into the
        // field you dictated into, but if you clicked away first, that paste lands nowhere AND the
        // clipboard-preservation restore then wipes the text back off the clipboard, so it survives
        // only in History. Detect "focus left the field" and drop the text durably on the clipboard
        // instead (the safety net the locked path below already has). Gate on element identity first
        // so a still-in-the-field paste is never misrouted, with a text-like fallback for when you
        // moved to another usable field; only a non-text destination (or nothing focused) takes the
        // clipboard branch.
        let fakePaste = askSeams.livePaste
        let current = fakePaste == nil ? TargetResolver.captureFocused() : nil
        let sameField: Bool
        if let c = current, let t = target { sameField = CFEqual(c.element, t.element) }
        else { sameField = false }
        let canPaste = sameField || (current?.isTextLike ?? false)
        if let fakePaste = fakePaste, fakePaste(delivered, settled) {
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: true),
                         noteUndo: nil, toast: nil, keepHUD: keepHUD)
            return .foreign(target)
        } else if fakePaste == nil && canPaste {
            Log.write("deliver: paste-synth into focus (\(delivered.count) chars, mode=\(mode), sameField=\(sameField))")
            TargetResolver.pasteIntoFocus(delivered, onComplete: settled)
            // BT5: foreign-app landing - Option+Z uses the in-place foreign tier (noteUndo nil).
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: true),
                         noteUndo: nil, toast: nil, keepHUD: keepHUD)
            return .foreign(target)
        } else {
            // Park the dictation on the clipboard for a single Cmd+V, then restore your prior
            // clipboard. A paste is a clipboard read and fires no event, so HotkeyMonitor watches
            // for the next Cmd+V via the existing key tap to know when the paste has happened.
            Log.write("deliver: focus left the field, clipboard park + one-shot restore (\(delivered.count) chars, mode=\(mode))")
            let pb = clipboardPasteboard      // the general pasteboard in the app; a self-test points it at a private one
            let previous = PasteboardSnapshot.capture(from: pb)
            SyntheticPasteboard.write(delivered, to: pb)
            pastePark = PastePark(previous: previous, changeCount: pb.changeCount)
            hotkey.pasteRestoreArmed = true
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: false),
                         noteUndo: nil, toast: "📋 Couldn't reach your field. ⌘V once to paste; your clipboard then restores.", keepHUD: keepHUD)
            settled()   // nothing pastes now; `pastePark` itself tells a held result the text waits for a manual paste
            return .pastePark
        }
    }

    private func deliverLocked(delivered: String, raw: String, mode: HistoryMode,
                               captured: DictationTarget, revertable: Bool, keepHUD: Bool,
                               settled: @escaping () -> Void,
                               finish: @escaping (CleanupFallbackReceipt) -> CleanupFallbackReceipt) {
        // Locked mode: focus may have moved, so reactivate and validate the specific captured field before
        // synthesizing Cmd+V. The completion distinguishes a real landing from durable clipboard recovery.
        TargetResolver.pasteIntoCapturedTarget(delivered, target: captured, settled: settled) { [weak self] outcome in
            guard let self = self else { return }
            let resolution = Self.lockedDeliveryResolution(targetAvailable: true, outcome: outcome)
            switch resolution.receipt {
            case .foreign:
                Log.write("deliver: paste-synth into \(captured.label) (locked, \(delivered.count) chars, mode=\(mode))")
                self.landDelivery(
                    foreignUndo: self.makePendingUndo(
                        raw: raw, delivered: delivered, revertable: revertable,
                        canRevertInPlace: false),
                    noteUndo: nil, toast: nil, keepHUD: keepHUD)
                _ = finish(.foreign(captured))
            case .clipboard:
                if resolution.shouldCopyToClipboard { TargetResolver.copyToClipboard(delivered) }
                Log.write("deliver: clipboard fallback (locked, classification=\(outcome.logToken), \(delivered.count) chars, mode=\(mode))")
                self.landDelivery(
                    foreignUndo: self.makePendingUndo(
                        raw: raw, delivered: delivered, revertable: revertable,
                        canRevertInPlace: false),
                    noteUndo: nil, toast: resolution.toast, keepHUD: keepHUD)
                _ = finish(.clipboard(changeCount: NSPasteboard.general.changeCount))
            }
        }
    }

    private func deliverLockedNoTarget(delivered: String, raw: String, mode: HistoryMode,
                                       revertable: Bool,
                                       keepHUD: Bool) -> CleanupFallbackReceipt {
        // Locked + no captured field — clipboard safety net.
        let resolution = Self.lockedDeliveryResolution(targetAvailable: false, outcome: nil)
        Log.write("deliver: clipboard fallback (locked, \(delivered.count) chars, mode=\(mode))")
        if resolution.shouldCopyToClipboard { TargetResolver.copyToClipboard(delivered, to: clipboardPasteboard) }
        landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: false),
                     noteUndo: nil, toast: resolution.toast, keepHUD: keepHUD)
        return .clipboard(changeCount: clipboardPasteboard.changeCount)
    }

    /// The shared delivery tail every `finalize()` branch ends in: record the two-tier undo — a foreign-app
    /// `PendingUndo` XOR the notes cross-focus id on `notesDelivery` (mutually exclusive; every landing sets
    /// exactly one) — then either hide the HUD (a successful landing, unless `keepHUD`) or leave a fallback
    /// toast (a clipboard park, which always shows). The HUD stays on the controller (ADR 0012); each branch
    /// above chooses only the delivery attempt + these params.
    private func landDelivery(foreignUndo: PendingUndo?, noteUndo: String?, toast: String?, keepHUD: Bool) {
        pendingUndo = foreignUndo
        notesDelivery.pendingNoteUndo = noteUndo
        if let toast = toast {
            hud.toast(toast)
        } else if !keepHUD {
            hud.hide()
        }
    }

    /// The one-shot clipboard restore: fired by HotkeyMonitor when you press Cmd+V after a click-away
    /// clipboard park. Let the target app finish reading the pasteboard, then swap the prior clipboard
    /// back. Backs off if the clipboard changed since the park (you copied something else first).
    private func restoreParkedClipboard() {
        guard pastePark != nil else { return }
        // Same settle delay pasteIntoFocus uses after a synthetic paste, so the app reads our parked
        // text before we swap it out from under the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, let park = self.pastePark else { return }
            self.pastePark = nil
            let pb = NSPasteboard.general
            guard pb.changeCount == park.changeCount else {
                Log.write("paste-park: clipboard changed since park, skipping restore")
                return
            }
            // Restoring the empty snapshot clears the pasteboard — the faithful "no prior
            // clipboard" restore.
            SyntheticPasteboard.restore(park.previous, to: pb)
            if park.previous.isEmpty {
                Log.write("paste-park: cleared parked text (no prior clipboard) after one-shot paste")
            } else {
                Log.write("paste-park: prior clipboard restored after one-shot paste")
            }
        }
    }

    func note(_ s: String) { callbacks.onStateChange(s) }   // internal: OneShotContext seam

    /// The idle prompt, sourced from the live wakeup binding so it tracks a rebind (default "right ⌥").
    var readyHint: String { "ready (hold \(hotkey.map.wakeup.label))" }
}

/// The coordinator's conformance to the one-shot decompose seam (`OneShotContext`, ADR 0010). The single
/// client is the `OneShotRegistry` engine, which drives all Family-2 modes through only these capabilities;
/// the recording state machine and Family-1 stay bespoke on the class above. Most requirements are met by
/// class members directly (`hud` / `note` / `landInPlaceTransform` / the stored `onOpenSearchResultNote`);
/// the projections below are the ones the extension adds.
extension DictationController: OneShotContext {
    /// The recording-state description, for a flow's entry log line only (keeps the pre-extraction
    /// diagnostic verbatim without leaking the state machine itself).
    var stateLabel: String { String(describing: state) }

    /// The BT5 cancellation generation. Esc bumps it so one-shot completions can drop stale work.
    var currentTakeGeneration: Int { takeGeneration }

    /// The level-picker armed flag, backed by the hotkey tap (which reads it to route level-nav keys).
    var levelPickerActive: Bool {
        get { hotkey.levelPickerActive }
        set { hotkey.levelPickerActive = newValue }
    }

    /// The dual-mode discriminator the transcript-acting flows branch on: the recording machine is
    /// capturing AND the VAD flag fired (real speech this take). Reads the private state + `audio`.
    var takeHasSpeech: Bool { (state == .recording || state == .locked) && audio.detectedSpeech }

    /// Return the recording state machine to idle and clear the take's shared target/tint state once a
    /// finalized transcript has been consumed (the take went `.finishing` in
    /// `finalizeTakeAndTranscribe`). The state-only scope leaves audio/activity/HUD ownership with the
    /// one-shot caller while making the trailing right-Option release a no-op.
    func markTakeConsumed() { teardownTake(.stateOnly) }

    /// The current dictation target's app label (empty when none), for the Search answer's History
    /// provenance - the coordinator owns `target`, the non-destructive Search landing only records it.
    var targetLabel: String { target?.label ?? "" }

    /// BT4 (replace highlight): the Option+P pick shows the four-color highlight on the KEY window's active
    /// note. The resolve + tint + note-id return now live on `notesDelivery` (ADR 0012); this projection just
    /// forwards so the `OneShotContext` contract (the registry's client) is unchanged.
    func showReplaceHighlight(level: String) -> String? { notesDelivery.showReplaceHighlight(level: level) }

    /// BT4: recolor the Option+P replace highlight as the pick moves (Cleanup / Tighten / Summarize).
    func updateReplaceHighlight(noteId: String, level: String) {
        notesDelivery.updateReplaceHighlight(noteId: noteId, level: level)
    }

    /// BT4: clear the Option+P replace highlight (the pick was canceled or committed).
    func clearReplaceHighlight(noteId: String) { notesDelivery.clearReplaceHighlight(noteId: noteId) }

    /// refine2 BUG 2: the ONE authoritative note-selection target for the current gesture — the target the
    /// coordinator captured at take-START (`beginRecording` -> `captureNoteTargetForTake`), whose JS snapshot
    /// range is still the live selection. The one-shot selection-transform flow reuses it instead of
    /// re-snapshotting the (by-then collapsed) live selection, so the transform lands BY NOTE ID and REPLACES the
    /// original range. nil when the take did not start in a note (a foreign-app pick). Forwards to `notesDelivery`.
    func authoritativeNoteTargetForGesture() -> NotesDictationTarget? {
        notesDelivery.noteTarget
    }

    /// Foreign-app twin of the note snapshot above. Retained by the retry landing closure so confirming
    /// from Settings restores the original app/field instead of writing into the Settings window.
    func authoritativeForeignTargetForGesture() -> DictationTarget? { target }
}

// MARK: - trace-test access (VDASK-3)
//
// Read-only views and one entry point for AskBackControllerSelfTest, which drives the real controller headless
// (null HUD, fake review and write providers, fake clock). Nothing here is used by the app.
extension DictationController {
    var traceStateName: String { "\(state)" }
    var traceHotkey: HotkeyMonitor { hotkey }
    var traceAskFlow: AskBackFlow? { askFlow }
    var traceParkedFlow: AskBackFlow? { askParkedFlow }
    var traceAskAnchor: CGPoint { askAnchor }
    var traceGeneration: Int { takeGeneration }
    var traceHeldCount: Int { askHeld.count }
    /// A delivery the rig cannot run for real (a paste with its verify and restore): open until the closure runs.
    func traceBeginDelivery() -> () -> Void { beginDelivery() }
    /// Arms `pastePark` as a delivery that could not reach its field does, on the controller's own pasteboard.
    func traceParkPaste() {
        pastePark = PastePark(previous: PasteboardSnapshot.capture(from: clipboardPasteboard),
                              changeCount: clipboardPasteboard.changeCount)
    }
    var traceDeliveriesOpen: Int { askDeliveries }

    /// Put the controller where `finish()` leaves it just before the transcript arrives: a take that ended with
    /// its cleanup setting and level frozen at release.
    func traceEnterFinishing(cleanup: Bool, level: CleanupLevel) {
        cleanupAtRelease = cleanup
        levelAtRelease = level
        setActive(true)
        state = .finishing
    }

    // VDASK-7 Option+P trace seams. Production never calls these; they replace only the selection copy, the
    // prompt-prep route and the provider adapters a headless row cannot reach.
    func traceRunOptionP() { oneShot.run(.cleanupSelection) }
    func traceCommitLevelPick() { oneShot.commitLevelPick() }
    var traceOneShotBusy: Bool { oneShot.isBusy }
    func traceSetSelectionCapture(_ capture: (() -> String?)?) {
        oneShot.selectionCaptureForTest = capture
    }
    func traceSetOneShotLevelPicker(_ picker: LevelPickerPresenting?) {
        oneShot.levelPickerForTest = picker
    }
    func traceSetOneShotResolution(_ resolution: LLMRouteResolution?) {
        oneShot.routeResolutionForTest = resolution.map { fixed in { _ in fixed } }
    }
    func traceSetOneShotClaudeWrite(_ write: TextTransformClient.AsyncAdapter?) {
        oneShot.claudeWriteForTest = write
    }
    func traceSetOneShotLocalWrite(_ write: TextTransformClient.AsyncAdapter?) {
        oneShot.localWriteForTest = write
    }
    func traceSelectionRetryRequest(bundle: LLMProviderBundle) -> TextTransformRequest? {
        oneShot.selectionRetryRequestForTest(bundle: bundle)
    }
}
