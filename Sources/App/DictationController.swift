import Cocoa
import ApplicationServices

/// The application-owned callbacks every controller instance requires. Construction is the wiring gate: a
/// forgotten menu/status/notes-window hook is a compiler error instead of a silent optional no-op.
struct DictationControllerCallbacks {
    let onStateChange: (String) -> Void
    let onOpenSettings: () -> Void
    let onOpenDictionary: () -> Void
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
    private enum State { case idle, recording, locked, finishing, oneShotFinishing }
    private var state: State = .idle {
        didSet {
            // BUG 1 take-liveness: push the HUD a single "is a take live" signal on EVERY state change, so a
            // mid-take confirmation toast (Option+N bullseye-set, Option+B no-bullseye) reverts to the
            // recording scope when its dwell fires instead of stranding the HUD off-screen. recording/locked =
            // live; idle = no take; finishing = false too (the mic has stopped — the cleanup-wait spinner owns
            // that phase, and every terminal toast there should hide, not revert). `hud` is initialized at
            // declaration, so this observer (which never fires for the .idle default) always has it available.
            hud.setTakeActive(state == .recording || state == .locked)
        }
    }

    private let hotkey = HotkeyMonitor()
    private let audio = AudioRecorder()
    private let audioWorkQueue = DispatchQueue(label: AppIdentity.queueLabel("audio-work"),
                                               qos: .userInitiated)
    private lazy var retainedTakeRecovery = RetainedTakeRecovery(progress: { [weak self] takeID, pending in
        // Recovery callbacks may arrive from the retention or daemon queues. The HUD stays on main and
        // displays one shared ring for all pending take IDs.
        DispatchQueue.main.async { [weak self] in
            self?.hud.setRecoveryPending(takeID: takeID, pending: pending)
        }
    })
    let hud = HUDPanel()   // internal: part of the OneShotContext seam (piece 8)
    /// The Family-3 notes-delivery collaborator (ADR 0012): owns the notes-bullseye / replace-highlight /
    /// note-target / cross-focus-undo state + JS-bridge callbacks + delivery routing. The seam is deliberately
    /// HUD-free, so the thin Option+N/Option+B entry points and `finalize()`'s tail keep their `hud.*` calls on
    /// this controller. `AppDelegate` wires its callbacks (formerly wired onto the controller directly).
    let notesDelivery: NotesDeliveryCoordinator
    private let callbacks: DictationControllerCallbacks
    private var target: DictationTarget?
    private var targetWasNotesWindow = false
    private var partialTimer: Timer?
    private var partialInFlight = false
    private var liveText = ""
    private var wasLocked = false
    private var recordingStartedAt: Date?

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
    /// It carries no transcript or provider response text.
    private enum CleanupFallbackReceipt {
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

    /// The cleanup-suspect A/B picker (prompt-injection backstop). When `CleanupLogic.cleanupSuspect`
    /// flags an output, we show this instead of auto-pasting; `pendingPick` holds the two candidates
    /// awaiting the user's Left/Right/Return choice (driven via `hotkey.abPickerActive`).
    private let abPicker = ABPickerPanel()
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

    init(callbacks: DictationControllerCallbacks, notesDelivery: NotesDeliveryCoordinator) {
        self.callbacks = callbacks
        self.notesDelivery = notesDelivery
    }

    func startMonitoring() -> Bool {
        hud.onLock = { [weak self] in self?.toggleLock() }
        hud.onStop = { [weak self] in self?.finish() }
        hud.onSettings = { [weak self] in self?.callbacks.onOpenSettings() }
        hud.samplesProvider = { [weak self] in self?.audio.scopeSamples ?? [] }
        hud.onSetLevel = { [weak self] lvl in self?.setLevelFromSlider(lvl) }
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
        let liveHotkeyMap = HotkeyMap.load()
        hotkey.map = liveHotkeyMap
        hud.setHotkeyMap(liveHotkeyMap)
        hotkey.customChords = CustomModeStore.shared.chordSnapshot()
        return hotkey.start()
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
                                         completion: @escaping (String?, String?) -> Void) {
        audioWorkQueue.async { [audio] in
            let snapshot = audio.snapshotWavWithMetrics()
            let wav = snapshot.wav
            // This enqueue is intentionally before the POST and returns immediately. The retention store
            // owns a separate utility queue, so disk I/O and eviction overlap the existing URLSession work.
            if let takeID {
                AudioRetentionStore.shared.retain(
                    wav, id: takeID, enabled: retentionEnabled ?? Settings.retainDictationAudio)
            }
            let take = takeID?.uuidString ?? "partial-preview"
            Log.write("audio.snapshot take=\(take) raw_s=\(String(format: "%.3f", snapshot.rawDuration)) "
                + "post_trim_s=\(String(format: "%.3f", snapshot.retainedDuration)) "
                + "trailing_trimmed_s=\(String(format: "%.3f", snapshot.trimmedTrailingDuration)) "
                + "wav_bytes=\(wav.count)")
            DaemonClient.transcribe(wav, takeID: takeID, completion: completion)
        }
    }

    /// Finalize an in-flight take for a one-shot mode that acts on the fresh transcript (email
    /// dictation, web search): stop the partial loop, snapshot + stop the audio, drop the active flag,
    /// switch the HUD to the thinking ring, and transcribe. `completion` runs on the MAIN thread with
    /// the transcript (or nil) plus any daemon error. Part of the `OneShotContext` seam: the registry's
    /// transcript-acting modes (email dictation, web search) call it through the seam rather than reaching
    /// onto the coordinator.
    func finalizeTakeAndTranscribe(noteLabel: String,
                                   completion: @escaping (String?, String?, UUID, Bool) -> Void) {
        partialTimer?.invalidate(); partialTimer = nil
        state = .oneShotFinishing
        let takeID = UUID()
        let retentionEnabled = Settings.retainDictationAudio
        logRecordingStop(takeID: takeID)
        audio.stop()
        setActive(false)
        // This one-shot is still cancelable while transcribe / client / landing run, so undo
        // setActive(false)'s takeActive side effect without restoring the app-wide active flag.
        hotkey.takeActive = true
        hud.update(state: "Transcribing…", target: target?.label, text: liveText, locked: false)
        hud.setThinking(true)
        note(noteLabel)
        transcribeAudioSnapshot(retainingAs: takeID, retentionEnabled: retentionEnabled) { text, err in
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
        case .dictionary:       callbacks.onOpenDictionary()
        case .bullseyeToggle:   toggleBullseye()
        case .bullseyeReveal:   revealBullseye()
        }
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

    private func rightOptionDown() {
        Log.write("ctrl.rightOptionDown state=\(state)")
        if state == .idle { beginRecording() }
        // In .locked, holding right-Option just arms the unlock chord; nothing else to do.
    }

    private func rightOptionUp() {
        // End the take ONLY from interface-unlocked recording. Arming changes what runs at the real end,
        // never what a wakeup release means while hands-free.
        if LockTransition.releaseEndsTake(
            phase: lockPhase(),
            hasArmedOneShot: TransformArmState.shared.armedOneShot != nil
        ) { finish() }
    }

    /// The lock-relevant view of `state`, so `toggleLock` / `rightOptionUp` drive the pure `LockTransition`
    /// rules instead of open-coding the state check (item 6).
    private func lockPhase() -> LockTransition.Phase {
        switch state {
        case .recording: return .recording
        case .locked:    return .locked
        case .idle, .finishing, .oneShotFinishing: return .other
        }
    }

    private func toggleLock() {
        Log.write("toggleLock state=\(state)")
        let phase = lockPhase()
        switch LockTransition.toggle(phase) {
        case .lock:
            state = .locked
            wasLocked = LockTransition.wasLockedAfterToggle(current: wasLocked, phase: phase)  // latches true
            hud.update(state: "Locked — speaking", target: target?.label, text: liveText, locked: true)
            note("locked")
        case .unlock:
            // PURE toggle back to interface-unlocked recording — NOT finish(). The take keeps recording; it
            // ends only when right-Option is released while unlocked (see rightOptionUp). `wasLocked` stays
            // latched so captured-target delivery routing is unaffected. This is the item-6 fix: the old
            // .locked case called finish(), so a second spacebar transcribed + delivered + idled the session.
            state = .recording
            wasLocked = LockTransition.wasLockedAfterToggle(current: wasLocked, phase: phase)  // preserved (true)
            hud.update(state: "Listening…", target: target?.label, text: liveText, locked: false)
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
        notesDelivery.refreshReplaceHighlightLevel()   // BT4: a mid-take level step recolors the replace highlight
    }

    /// The HUD strength slider was dragged with the mouse — set the level directly (no-op when off).
    private func setLevelFromSlider(_ raw: Int) {
        guard CleanupState.shared.cleanupEnabled else { return }
        let level = CleanupLevel.clamped(raw)
        guard level != CleanupState.shared.cleanupLevel else { return }
        CleanupState.shared.setLevel(level)
        hud.setCleanup(enabled: true, level: level.rawValue)
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
        partialTimer?.invalidate(); partialTimer = nil
        partialInFlight = false
        targetWasNotesWindow = false
        // Only a take whose gesture is also over may drop the snapshot; see TeardownScope.
        if case .full = scope { notesDelivery.noteTarget = nil }
        notesDelivery.teardownReplaceHighlight()   // BT4: always clear any tint the take armed
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
        guard state == .recording || state == .locked || state == .finishing || state == .oneShotFinishing else { return }
        Log.write("take canceled (Esc) state=\(state)")
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

    /// `right-Option + N`: DUAL-PURPOSE (notes-bullseye BT2). When a notes window is key AND the caret is in a
    /// note, set/move the pinned bullseye at the caret and ARM it (delivery then lands there regardless of
    /// focus). Otherwise keep the original behavior: open/focus the sticky-notes surface. Like the `?` cleanup
    /// toggle, arming is a mode change tied to the CURRENT dictation — it does NOT discard the in-flight take
    /// (item 5a): the take keeps recording and state-at-release decides how it lands.
    private func notes() {
        Log.write("sticky notes (Option+N) invoked state=\(state)")
        if let noteId = notesDelivery.setBullseyeAtCaret() {
            Log.write("bullseye set + armed at note \(noteId) (Option+N in a note)")
            refreshBullseyeIndicator()
            hud.toast(NotesBullseyeLogic.setToast)
        } else {
            callbacks.onOpenNotes()
        }
        note(readyHint)
    }

    /// `right-Option + B` (rebindable): pure toggle of the pinned bullseye's ARMED state, preserving its
    /// location. No bullseye set yet -> the "No bullseye set" toast. Like the `?` cleanup toggle, this is a mode
    /// change tied to the CURRENT dictation — it does NOT discard the in-flight take (item 5a): the take keeps
    /// recording. No armed/disarmed toast mid-take (item 5b) — the inline glyph reflects the new state on the
    /// next take; only the "No bullseye set" case toasts (there is nothing to reflect).
    private func toggleBullseye() {
        Log.write("bullseye toggle (Option+B) invoked state=\(state)")
        switch notesDelivery.toggleBullseye() {
        case .toggled:
            refreshBullseyeIndicator()
            notesDelivery.broadcastBullseyeState()   // BT3: show/hide the inline marker to match the new armed state
        case .noneSet:
            hud.toast(NotesBullseyeLogic.noneSetToast)
        }
        note(readyHint)
    }

    /// A membership change closed/deleted the bullseye's note, so the registry auto-disarmed it. Reflect the
    /// disarm in the info pill and toast the user (notes-bullseye BT2). Wired from AppDelegate.
    func handleBullseyeAutoDisarmed() {
        Log.write("bullseye auto-disarmed: target note closed/deleted")
        refreshBullseyeIndicator()
        hud.toast(NotesBullseyeLogic.goneToast)
    }

    /// `right-Option + Shift + N` (rebindable): REVEAL where the bullseye is — front its window, select its tab,
    /// arm it if it was disarmed, and scroll its anchor into view. Navigation, not visibility: the inline marker
    /// already renders persistently, just only while its note is the active tab in a visible window.
    ///
    /// Success is silent on purpose — the window coming forward with the glyph on screen IS the feedback, and a
    /// toast here would reintroduce exactly the mid-take noise BT5b removed from Option+B. Both failures do
    /// toast: nothing set reuses the Option+B copy, and a bullseye whose note is closed says so rather than
    /// silently doing nothing (reopening it would be the durability work, which is out of scope).
    private func revealBullseye() {
        Log.write("bullseye reveal (Option+Shift+N) invoked state=\(state)")
        switch notesDelivery.revealBullseye() {
        case .reveal(_, let armed):
            if armed { refreshBullseyeIndicator() }
        case .noneSet:
            hud.toast(NotesBullseyeLogic.noneSetToast)
        case .noteClosed:
            hud.toast(NotesBullseyeLogic.revealNoteClosedToast)
        }
        note(readyHint)
    }

    /// Push the live bullseye armed state into the HUD so the info-pill glyph gates on it (content-gated like
    /// the lock glyph / `?` keycap). Cheap; safe to call whenever the arm state may have changed. Stays on the
    /// controller because it is a HUD call (the notes-delivery seam is deliberately HUD-free — ADR 0012).
    private func refreshBullseyeIndicator() {
        hud.setBullseyeArmed(NotesBullseyeState.shared.armed)
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
        abPicker.show(raw: raw, cleaned: cleaned)
        hotkey.abPickerActive = true
        note("pick raw or cleaned")
    }

    /// Commit the A/B picker choice: paste the selected candidate via the normal delivery path (which
    /// wires undo for free). Escape / `forceRaw` always lands the safe raw side.
    private func commitABPick(forceRaw: Bool = false) {
        guard let pick = pendingPick else { return }
        pendingPick = nil
        hotkey.abPickerActive = false
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
    private var oneShotBusy: Bool {
        oneShot.isBusy || pendingPick != nil || hotkey.abPickerActive
    }

    /// Reject a one-shot entry when another flow owns the stage (log + return true). The caller then
    /// returns, so two one-shot flows never overlap.
    func rejectOneShotIfBusy(_ label: String) -> Bool {   // internal: OneShotContext seam
        guard oneShotBusy else { return false }
        Log.write("\(label): a one-shot flow is already active — ignoring")
        return true
    }

    /// Shared "the LLM pass failed, leave the user's text untouched" routing for the in-place transform
    /// modes (Cleanup-selection, email). `.ok` is handled by the caller (the success payload + landing
    /// differ per mode); the three failure cases collapse to a logged reason + a mode-nouned toast, gated
    /// by `CleanupLogic.landing(for:)`. Search and the inline cleanup switch keep bespoke fallbacks because
    /// their failure ACTION differs (answer-surface toast / paste-raw), so routing them here would be false
    /// unification.
    private func failInPlace(_ result: CleanupClient.Result, uiNoun: String, logNoun: String) {
        guard CleanupLogic.landing(for: result) == .rawFallback else { return }  // .ok: caller lands it
        guard let failure = TextTransformClient.safeFailure(for: result) else { return }
        Log.write("\(logNoun) fallback classification=\(failure.logToken) — text untouched")
        hud.toast("⚠️ \(uiNoun): \(failure.userMessage) — text left as-is. Retry in Models.")
    }

    /// Land a successful selection-transform result through the focus fallback. The shared notes delivery
    /// helper has already attempted any snapshotted note target before this method runs. When the Notes web
    /// island is currently key, use its bridge because AX paste synthesis into a WKWebView is unreliable.
    private func landSelectionTransform(
        _ text: String,
        foreignTarget: DictationTarget?,
        lateRecovery: Bool,
        completion: @escaping (TargetResolver.CapturedTargetLandingOutcome) -> Void
    ) {
        if !lateRecovery, callbacks.notesWindowIsKey(),
           notesDelivery.insertIntoActiveNote(text) == .delivered {
            Log.write("selection-transform landed via sticky-note bridge (\(text.count) chars)")
            completion(.landed)
            return
        }
        if let foreignTarget = foreignTarget {
            if lateRecovery {
                TargetResolver.pasteIntoCapturedTargetWithoutActivation(
                    text, target: foreignTarget, completion: completion)
            } else {
                TargetResolver.pasteIntoCapturedTarget(
                    text, target: foreignTarget, completion: completion)
            }
        } else {
            if lateRecovery {
                TargetResolver.copyToClipboard(text)
                completion(.clipboardOnly(.destinationUnverifiable))
            } else {
                completion(TargetResolver.pasteIntoFocus(text)
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

            landSelectionTransform(transformed, foreignTarget: foreignTarget,
                                   lateRecovery: lateRecovery) {
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
            failInPlace(result, uiNoun: uiNoun, logNoun: logNoun)
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
            // `?`-cleanup level (Raw color when cleanup is off) so the user sees what will be replaced. Gated
            // on NOT armed: an armed bullseye take delivers to the bullseye (an insert point), NOT the
            // selection, so nothing is overwritten and nothing is tinted. The island no-ops on a bare-caret
            // snapshot (nothing to replace).
            notesDelivery.armReplaceHighlightForTake()
        } else {
            target = TargetResolver.captureFocused()
            targetWasNotesWindow = (target?.pid == getpid()) && callbacks.notesWindowIsKey()
            Log.write("beginRecording target=\(target?.label ?? "nil") textLike=\(target?.isTextLike ?? false) notesWindow=\(targetWasNotesWindow)")
        }
        liveText = ""
        wasLocked = false
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
        hud.setCleanup(enabled: CleanupState.shared.cleanupEnabled, level: CleanupState.shared.cleanupLevel.rawValue)
        hud.setArmedMode(glyph: TransformArmState.shared.armedOneShot?.glyph)
        note("recording")
        partialTimer?.invalidate()
        // Final-only: no live preview loop — the repeated Whisper passes on the growing take are the
        // dictation-time power cost. Both modes still perform one final transcription at release.
        guard let partialInterval = Settings.powerMode.partialTranscriptionInterval else {
            partialTimer = nil
            Log.write("power mode final-only: partial-preview loop skipped")
            return
        }
        partialTimer = Timer.scheduledTimer(withTimeInterval: partialInterval, repeats: true) { [weak self] _ in
            self?.tickPartial()
        }
    }

    private func tickPartial() {
        // Second gate for a mid-take settings flip: an already-armed timer goes inert immediately.
        guard Settings.powerMode.partialTranscriptionInterval != nil else { return }
        guard state == .recording || state == .locked, !partialInFlight, audio.hasAudio else { return }
        partialInFlight = true
        transcribeAudioSnapshot { [weak self] text, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.partialInFlight = false
                guard self.state == .recording || self.state == .locked else { return }
                if let raw = text, !raw.isEmpty {
                    let cleaned = CleanupLogic.cleanRepeats(raw)
                    self.liveText = cleaned
                    let label = self.state == .locked ? "Locked — speaking" : "Listening…"
                    self.hud.update(state: label, target: self.target?.label, text: cleaned,
                                    locked: self.state == .locked)
                }
            }
        }
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
        state = .finishing
        partialTimer?.invalidate(); partialTimer = nil
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
        hud.update(state: "Transcribing…", target: target?.label, text: liveText, locked: false)
        note("transcribing")
        let generation = takeGeneration   // BT5: capture so an Esc-cancel during transcribe drops this landing
        transcribeAudioSnapshot(retainingAs: takeID, retentionEnabled: retentionEnabled) { [weak self] text, err in
            DispatchQueue.main.async {
                self?.deliver(text: text, error: err, generation: generation, takeID: takeID,
                              retentionWasEnabled: retentionEnabled)
            }
        }
    }

    /// Keep the failed take live and retry only from its retained on-disk WAV. The generation check preserves
    /// Escape cancellation while the daemon is warming; no fresh microphone capture can enter this path.
    func retryRetainedTake(takeID: UUID, retentionWasEnabled: Bool, generation: Int,
                           completion: @escaping (RetainedTakeRecoveryResult) -> Void) {
        if retentionWasEnabled {
            Log.write("stt.recovery queued take=\(takeID.uuidString) source=retained-clip")
            hud.toast("Transcription unavailable. Retrying retained take...")
            note("retrying transcription")
        }
        let stillCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return generation == self.takeGeneration
        }
        retainedTakeRecovery.recover(
            takeID: takeID, retentionWasEnabled: retentionWasEnabled,
            stillCurrent: stillCurrent
        ) { result in
            DispatchQueue.main.async {
                guard stillCurrent() else { return }
                completion(result)
            }
        }
    }

    /// Pure request builder shared by the runtime cleanup path and deterministic route-coverage tests.
    static func makeCleanupRequest(route: LLMRouteID, input: String,
                                   selected: LLMProviderBundle, systemPrompt: String,
                                   timeout: TimeInterval) -> TextTransformRequest {
        TextTransformRequest(
            route: route, bundle: selected, sourceText: input,
            systemPrompt: systemPrompt,
            userMessage: CleanupClient.wrap(input), timeout: timeout)
    }

    private func deliver(text rawText: String?, error: String?, generation: Int, takeID: UUID,
                         retentionWasEnabled: Bool, recovered: Bool = false) {
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
                     lateRecovery: recovered)
            return
        }

        // Cleanup mode: atomic land-when-ready. Show the green-sine "thinking" spinner, run the raw
        // transcript through the LM Studio cleanup, and land the cleaned text in one shot. On
        // LM-Studio-down / timeout / bad output, fall back to the raw transcript + a toast (the two
        // failure modes collapse to one recovery path).
        hud.update(state: "Cleaning…", target: target?.label, text: raw, locked: false)
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
        let resolution = Settings.modelsPower.resolveRoute(
            route, fallback: .local(Settings.cleanupModel))
        // Every provider returns the shared `CleanupClient.Result`, so landing/raw fallback stays in one
        // closure. Power Mode never participates in the dispatch choice.
        var fallbackReceipt: CleanupFallbackReceipt?
        var deferredRetryResult: CleanupClient.Result?
        let onResult: (CleanupClient.Result) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // BT5: an Esc-cancel during the cleanup pass bumped `takeGeneration`; drop this landing so nothing
                // lands for the aborted take.
                guard generation == self.takeGeneration else {
                    Log.write("cleanup result: dropped — take was canceled (gen \(generation) != \(self.takeGeneration))")
                    return
                }
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
                                      lateRecovery: recovered)
                    }
                case .unavailable, .timedOut, .badOutput:
                    let failure = TextTransformClient.safeFailure(for: result)!
                    Log.write("cleanup fallback classification=\(failure.logToken) → raw")
                    self.hud.toast("⚠️ \(failure.userMessage) — pasted raw. Retry in Models.")
                    self.finalize(
                        delivered: raw, raw: raw, cleaned: nil, mode: .raw,
                        historyID: takeID, keepHUD: true, lateRecovery: recovered
                    ) { [weak self] receipt in
                        guard let self = self else { return }
                        fallbackReceipt = receipt
                        if let deferred = deferredRetryResult {
                            deferredRetryResult = nil
                            self.landCleanupRetry(deferred, raw: raw, level: effectiveLevel,
                                                  receipt: receipt)
                        }
                    }
                }
            }
        }
        let onRetryResult: (CleanupClient.Result) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.takeGeneration else { return }
                if let receipt = fallbackReceipt {
                    self.landCleanupRetry(result, raw: raw, level: effectiveLevel,
                                          receipt: receipt)
                } else {
                    // Locked captured-target landing is completion-based. Preserve a fast explicit retry
                    // until its first-attempt destination receipt exists instead of guessing a destination.
                    deferredRetryResult = result
                    Log.write("cleanup explicit retry deferred until fallback landing receipt")
                }
            }
        }
        let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
            let providerPrompt = Settings.modelsPower.effectiveDeveloperInstructions(
                for: route, provider: bundle.provider,
                glossarySuffix: CorrectionDictionary.shared.contextGlossarySuffix())
            let retryTimeout = Settings.timeout(
                local: Settings.cleanupTimeout, provider: bundle.provider)
            return Self.makeCleanupRequest(
                route: route, input: raw, selected: bundle,
                systemPrompt: providerPrompt, timeout: retryTimeout)
        }
        TextTransformClient.transformResolved(
            resolution, route: route, requestForBundle: requestForBundle,
            local: { req, done in
                CleanupClient.cleanup(req.sourceText, timeout: req.timeout,
                                      model: req.bundle.modelID,
                                      systemPrompt: req.systemPrompt,
                                      completion: done)
            }, retryCompletion: onRetryResult, completion: onResult)
    }

    /// Replace the first attempt's raw fallback at its captured destination. A retry failure only refreshes
    /// the exact safe classification and re-arms Retry; raw is never pasted a second time.
    private func landCleanupRetry(_ result: CleanupClient.Result, raw: String, level: CleanupLevel,
                                  receipt: CleanupFallbackReceipt?) {
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
                            targetLabel: captured.label)
                    }
                    return
                } else {
                    TargetResolver.copyToClipboard(cleaned)
                    completeForeignCleanupRetryLanding(
                        .clipboardOnly(.destinationUnverifiable),
                        cleaned: cleaned, raw: raw, level: level, targetLabel: "")
                    return
                }
            case .pastePark:
                landed = replaceParkedClipboard(with: cleaned)
                if landed { pendingUndo = nil; notesDelivery.pendingNoteUndo = nil }
            case .clipboard(let changeCount):
                if NSPasteboard.general.changeCount == changeCount {
                    TargetResolver.copyToClipboard(cleaned)
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
                    level: level.rawValue, app: target?.label ?? "")
                hud.hide()
            } else {
                Log.write("cleanup explicit retry output could not restore captured landing")
                hud.answer(cleaned)
            }
        case .unavailable, .timedOut, .badOutput:
            let failure = TextTransformClient.safeFailure(for: result)!
            Log.write("cleanup explicit retry classification=\(failure.logToken) — raw unchanged")
            hud.toast("⚠️ \(failure.userMessage) — raw text left unchanged. Retry in Models.")
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
        targetLabel: String
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
            level: level.rawValue, app: targetLabel)
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

    @discardableResult
    private func finalize(delivered: String, raw: String, cleaned: String?, mode: HistoryMode,
                          level: Int? = nil, historyID: UUID, keepHUD: Bool = false,
                          lateRecovery: Bool = false,
                          completion: ((CleanupFallbackReceipt) -> Void)? = nil) -> CleanupFallbackReceipt? {
        let finish: (CleanupFallbackReceipt) -> CleanupFallbackReceipt = { receipt in
            self.teardownTake(.full)
            self.note(self.readyHint)
            completion?(receipt)
            return receipt
        }
        TranscriptionHistory.shared.record(delivered: delivered, raw: raw, cleaned: cleaned,
                                           mode: mode, level: level, app: target?.label ?? "",
                                           id: historyID)
        let revertable = CleanupLogic.isRevertable(raw: raw, cleaned: cleaned)

        // Notes delivery (ADR 0012): the coordinator routes an armed bullseye > the take's snapshotted note
        // target (BT1) > the key-window insert, and performs the note-undo bookkeeping + the gone-note
        // clipboard-park. The HUD + the foreign `pendingUndo` tail stay here (the seam is HUD-free), applied via
        // `landDelivery`. The key-window discriminators read `target`, so they are computed here and passed in.
        let notesWindowCurrentlyKey = callbacks.notesWindowIsKey()
        // A late retry may run after the user has moved to another note. Only its exact take-start snapshot may
        // receive the text; never reinterpret the currently active note as the old target.
        let shouldInsertIntoNotes = lateRecovery ? false : (targetWasNotesWindow
            || (notesWindowCurrentlyKey && (target?.pid == getpid())))
        switch notesDelivery.routeNotesDelivery(delivered: delivered, mode: mode,
                                                landingKind: .inPlace,
                                                inputSource: .dictation,
                                                noteTarget: notesDelivery.noteTarget,
                                                shouldInsertIntoNotes: shouldInsertIntoNotes,
                                                startedInNotes: targetWasNotesWindow,
                                                currentlyKey: notesWindowCurrentlyKey) {
        case .landed(let noteUndo):
            landDelivery(foreignUndo: nil, noteUndo: noteUndo, toast: nil, keepHUD: keepHUD)
            return finish(.note(noteUndo))
        case .parked(let toast, let refreshBullseye):
            // The info-pill push is a HUD call, so it stays here; it reads the post-drop armed state (false),
            // which the coordinator already committed, so its exact position relative to the drop is immaterial.
            if refreshBullseye { refreshBullseyeIndicator() }
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: false),
                         noteUndo: nil, toast: toast, keepHUD: keepHUD)
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
                return finish(.clipboard(changeCount: NSPasteboard.general.changeCount))
            }
            TargetResolver.pasteIntoCapturedTargetWithoutActivation(
                delivered, target: captured
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

        if !wasLocked {
            let receipt = deliverPushToTalk(
                delivered: delivered, raw: raw, mode: mode,
                revertable: revertable, keepHUD: keepHUD)
            return finish(receipt)
        }

        if let captured = target {
            deliverLocked(
                delivered: delivered, raw: raw, mode: mode, captured: captured,
                revertable: revertable, keepHUD: keepHUD, finish: finish)
            return nil
        }

        let receipt = deliverLockedNoTarget(
            delivered: delivered, raw: raw, mode: mode,
            revertable: revertable, keepHUD: keepHUD)
        return finish(receipt)
    }

    /// Push-to-talk: focus is still on the field we dictated into, so synthesize a paste. This is
    /// the universal path - native, Electron (Claude/Obsidian/Slack), browsers, terminals. We do
    /// NOT use AX insert here: Electron returns "success" for an AX set while silently dropping
    /// the text, so paste is both more reliable and consistent across apps.
    private func deliverPushToTalk(delivered: String, raw: String, mode: HistoryMode,
                                   revertable: Bool, keepHUD: Bool) -> CleanupFallbackReceipt {
        // Re-check focus at delivery. Push-to-talk normally lands by synthesizing Cmd+V into the
        // field you dictated into, but if you clicked away first, that paste lands nowhere AND the
        // clipboard-preservation restore then wipes the text back off the clipboard, so it survives
        // only in History. Detect "focus left the field" and drop the text durably on the clipboard
        // instead (the safety net the locked path below already has). Gate on element identity first
        // so a still-in-the-field paste is never misrouted, with a text-like fallback for when you
        // moved to another usable field; only a non-text destination (or nothing focused) takes the
        // clipboard branch.
        let current = TargetResolver.captureFocused()
        let sameField: Bool
        if let c = current, let t = target { sameField = CFEqual(c.element, t.element) }
        else { sameField = false }
        let canPaste = sameField || (current?.isTextLike ?? false)
        if canPaste {
            Log.write("deliver: paste-synth into focus (\(delivered.count) chars, mode=\(mode), sameField=\(sameField))")
            TargetResolver.pasteIntoFocus(delivered)
            // BT5: foreign-app landing - Option+Z uses the in-place foreign tier (noteUndo nil).
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: true),
                         noteUndo: nil, toast: nil, keepHUD: keepHUD)
            return .foreign(target)
        } else {
            // Park the dictation on the clipboard for a single Cmd+V, then restore your prior
            // clipboard. A paste is a clipboard read and fires no event, so HotkeyMonitor watches
            // for the next Cmd+V via the existing key tap to know when the paste has happened.
            Log.write("deliver: focus left the field, clipboard park + one-shot restore (\(delivered.count) chars, mode=\(mode))")
            let pb = NSPasteboard.general
            let previous = PasteboardSnapshot.capture(from: pb)
            SyntheticPasteboard.write(delivered, to: pb)
            pastePark = PastePark(previous: previous, changeCount: pb.changeCount)
            hotkey.pasteRestoreArmed = true
            landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: false),
                         noteUndo: nil, toast: "📋 Couldn't reach your field. ⌘V once to paste; your clipboard then restores.", keepHUD: keepHUD)
            return .pastePark
        }
    }

    private func deliverLocked(delivered: String, raw: String, mode: HistoryMode,
                               captured: DictationTarget, revertable: Bool, keepHUD: Bool,
                               finish: @escaping (CleanupFallbackReceipt) -> CleanupFallbackReceipt) {
        // Locked mode: focus may have moved, so reactivate and validate the specific captured field before
        // synthesizing Cmd+V. The completion distinguishes a real landing from durable clipboard recovery.
        TargetResolver.pasteIntoCapturedTarget(delivered, target: captured) { [weak self] outcome in
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
        if resolution.shouldCopyToClipboard { TargetResolver.copyToClipboard(delivered) }
        landDelivery(foreignUndo: makePendingUndo(raw: raw, delivered: delivered, revertable: revertable, canRevertInPlace: false),
                     noteUndo: nil, toast: resolution.toast, keepHUD: keepHUD)
        return .clipboard(changeCount: NSPasteboard.general.changeCount)
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
