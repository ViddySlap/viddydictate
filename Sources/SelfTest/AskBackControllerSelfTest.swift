import AppKit
import Foundation

// VDASK-3 controller trace test. Drives the REAL DictationController headless (null-style HUD that records,
// the way TailCheckSelfTest drives deliver()) with a fake review provider, a fake write provider and a fake
// clock, injected through DictationController.AskBackSeams. The rig installs the controller's real HotkeyMonitor
// callbacks (`installHotkeyCallbacks()`, the same call `startMonitoring()` makes first) and then drives the REAL
// HotkeyMonitor routing functions (`keyTakenBeforeWakeup`, `takeAskBackKey`, `fireWakeup`) the CGEvent tap
// calls, so a key or a press reaches the controller's own handlers; only the tap itself cannot run without a
// window server. Source-shape rows cover only wiring no headless row can reach:
// the tap callback's own call into those functions, beginRecording's placement clear (it needs the mic, AX
// and the daemon), and the card row's hit test (AppKit view). Every fixture is synthetic text.

private final class TraceHUD: HUDPresenting {
    var onLock: (() -> Void)?
    var onStop: (() -> Void)?
    var onSettings: (() -> Void)?
    var samplesProvider: (() -> [Float])?
    var onSetLevel: ((Int) -> Void)?
    var log: [String] = []

    func show() { log.append("show") }
    func hide() { log.append("hide") }
    func setTakeActive(_ active: Bool) { log.append("active:\(active)") }
    func setRecoveryPending(takeID: UUID, pending: Bool) {}
    func setHotkeyMap(_ map: HotkeyMap) {}
    func flashModeBadge(glyph: String, label: String) {}
    func flashCleanupBadge(label: String) {}
    func setThinking(_ on: Bool) { log.append("thinking:\(on ? "on" : "off")") }
    func setCleanup(enabled: Bool, level: Int) {}
    func setArmedMode(glyph: String?) {}
    func setBullseyeArmed(_ armed: Bool) {}
    func update(state: String, target: String?, text: String, locked: Bool) { log.append("update:\(state)") }
    func toast(_ message: String, duration: TimeInterval, forceFull: Bool, action: (() -> Void)?) { log.append("toast:\(message)") }
    func answer(_ text: String) {}
}

private final class TraceHook: TailCheckDictationHook {
    private(set) var finals: [String] = []
    /// Called after each landing with the number of landings so far; a row uses it to hold a delivery open.
    var onCall: ((Int) -> Void)?
    func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String) {
        finals.append(finalText)
        onCall?(finals.count)
    }
}

private final class TraceCard: AskCardPresenting {
    var onChoose: ((UUID, Int) -> Void)?
    var shown: [AskCardModel] = []
    var hides = 0
    func show(_ card: AskCardModel, anchor: CGPoint) { shown.append(card) }
    func setHighlight(cardID: UUID, index: Int) {}
    func hide() { hides += 1 }
}

private final class TraceClock {
    var now = 0.0
    private var nextID = 0
    private var timers: [(id: Int, due: Double, fire: () -> Void)] = []
    func schedule(_ after: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, now + after, fire))
        return { [self] in timers.removeAll { $0.id == id } }
    }
    func advance(by dt: Double) {
        let t = now + dt
        while let next = timers.filter({ $0.due <= t + 1e-9 }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.fire()
        }
        now = t
    }
}

private enum TKey {
    static let esc: Int64 = 53, ret: Int64 = 36, enter: Int64 = 76
    static let up: Int64 = 126, down: Int64 = 125, left: Int64 = 123, right: Int64 = 124
}

private let traceTranscript = "We should ship on Friday. Actually let\u{2019}s ship on Monday instead. Don\u{2019}t tell the client yet, it\u{2019}s risky. The Blue Folder goes to Ana. "
    + (0..<40).map { "filler\($0)" }.joined(separator: " ")
private let traceReviewJSON = "{\"spots\":[],\"questions\":[{\"question\":\"Which day?\",\"quote\":\"ship on Friday\","
    + "\"why\":\"two days are named\",\"options\":[\"Friday\",\"Monday\"]}]}"
private let traceCleaned = "Ship on Friday. Keep the Blue Folder with Ana."
private let traceNewText = "Lunch is at noon on Tuesday."

private func traceSettle() {
    if Thread.isMainThread { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
    else { DispatchQueue.main.sync {} }
}

private final class TraceRig {
    let clock = TraceClock()
    let hud = TraceHUD()
    let hook = TraceHook()
    let card = TraceCard()
    let pasteboard: NSPasteboard
    let store: TranscriptionHistory
    let root: URL
    let previousStore: TranscriptionHistory
    var ctl: DictationController!
    var reviews: [(system: String, input: String, done: (AskBackProviderReply) -> Void)] = []
    var writes: [(request: TextTransformRequest, done: TextTransformClient.Completion)] = []
    var newTakeStates: [String] = []
    var abShown: [(raw: String, cleaned: String)] = []
    var retryPosts = 0
    private var observer: NSObjectProtocol?
    var takeID = UUID()
    /// Where the rig's takes land. `.live` (the default, bullseye landing off) pastes through the controller's
    /// `livePaste` seam, whose completion the rig controls; `.noTarget` is the locked landing with no captured
    /// field, which only copies the text to the clipboard for a manual Cmd+V.
    enum Route { case live, noTarget }
    var route = Route.live
    /// The faked paste on the live route. `liveAttempts` records every call; `liveCanPaste = false` is "focus left
    /// the field" (the click-away park). With `liveHold` the paste's completion waits for `finishLivePaste()`.
    var liveAttempts: [String] = []
    var liveCanPaste = true
    var liveHold = false
    var liveDone: [() -> Void] = []

    init() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name(AppIdentity.queueLabel("askback-ctl-selftest-\(UUID().uuidString)")))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("askback-ctl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TranscriptionHistory(directory: root, maxEntries: { 100 })
        previousStore = TranscriptionHistory.shared
        TranscriptionHistory.shared = store
        let notesCallbacks = NotesDeliveryCallbacks(
            onSnapshotNoteTarget: { _ in nil },
            onDeliverToNoteTarget: { _, _ in .noWindow },
            onInsertIntoActiveNote: { _ in .noWindow },
            onResolveReplaceHighlightTarget: { nil },
            onShowReplaceHighlight: { _, _, _ in },
            onClearReplaceHighlight: { _ in },
            onUndoNoteDelivery: { _ in false },
            onReplaceNoteDelivery: { _, _ in false },
            onCurrentNoteId: { nil })
        ctl = DictationController(
            callbacks: DictationControllerCallbacks(
                onStateChange: { _ in }, onOpenSettings: {}, onOpenDictionary: {}, onOpenHistory: {}, onOpenNotes: {},
                notesWindowIsKey: { false }, onCleanupModeChange: { _ in }),
            notesDelivery: NotesDeliveryCoordinator(callbacks: notesCallbacks),
            tailCheckHook: hook,
            clipboardPasteboard: pasteboard,
            hud: hud)
        ctl.wasLocked = true
        ctl.takeLandAtStart = false
        ctl.askSeams.livePaste = { [unowned self] text, done in
            liveAttempts.append(text)
            guard liveCanPaste else { return false }
            if liveHold { liveDone.append(done) } else { done() }
            return true
        }
        ctl.askSeams.resolve = { _ in .pinned(.claude("claude-trace-model")) }
        ctl.askSeams.reviewProvider = { [unowned self] system, input, done in reviews.append((system, input, done)) }
        ctl.askSeams.claudeWrite = { [unowned self] request, done in writes.append((request, done)) }
        ctl.askSeams.schedule = { [unowned self] after, fire in clock.schedule(after, fire) }
        ctl.askSeams.now = { [unowned self] in clock.now }
        ctl.askSeams.beginNewTake = { [unowned self] in newTakeStates.append(ctl.traceStateName) }
        ctl.askSeams.cardPanel = card
        ctl.askSeams.abPickerShow = { [unowned self] raw, cleaned in abShown.append((raw, cleaned)) }
        ctl.installHotkeyCallbacks()      // the monitor's callbacks reach this controller, as in production (no tap)
        observer = NotificationCenter.default.addObserver(
            forName: TextTransformRetryCenter.didChange, object: TextTransformRetryCenter.shared, queue: nil) { [weak self] _ in
                self?.retryPosts += 1
            }
    }

    func close() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        TranscriptionHistory.shared = previousStore
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    var hotkey: HotkeyMonitor { ctl.traceHotkey }
    var state: String { ctl.traceStateName }
    var pastes: Int { hook.finals.count }
    var toasts: [String] { hud.log.filter { $0.hasPrefix("toast:") } }

    /// A take that ended and whose transcript has arrived: the real `deliver()` entry point.
    @discardableResult
    func startTake(level: CleanupLevel = .summarize, cleanup: Bool = true, text: String = traceTranscript) -> UUID {
        let id = UUID()
        takeID = id
        ctl.takeLandAtStart = route == .noTarget
        ctl.traceEnterFinishing(cleanup: cleanup, level: level)
        ctl.deliver(text: text, error: nil, generation: ctl.traceGeneration, takeID: id, retentionWasEnabled: false)
        return id
    }
    func answerReview(_ json: String = traceReviewJSON) {
        reviews.last?.done(.text(json))
        traceSettle()
    }
    func key(_ code: Int64, option: Bool = false) -> Bool {
        let taken = hotkey.keyTakenBeforeWakeup(keyCode: code, optionHeld: option)
        traceSettle()
        return taken
    }
    func pressDown() { hotkey.fireWakeup(down: true); traceSettle() }
    func release() { hotkey.fireWakeup(down: false); traceSettle() }
    func finishWrite(_ text: String = traceCleaned) {
        writes.last?.done(.ok(text))
        traceSettle()
    }
    func entries(_ id: UUID) -> [TranscriptionHistory.Entry] {
        store.flush()
        return store.all().filter { $0.id == id }
    }
    /// The take reaches its card: a review that returns one question.
    func toCard() {
        startTake()
        answerReview()
    }
    /// A hold on the card: the old take is parked and a new take is recording. Returns the old take's id.
    @discardableResult
    func holdOnCard() -> UUID {
        let old = takeID
        pressDown()
        clock.advance(by: 0.6)
        traceSettle()
        return old
    }
    /// The new take ends after speech: its transcript arrives (a short Cleanup take, one write, one paste).
    func newTakeSpeaks(_ text: String = "A short new take about lunch plans.", writes result: String = traceNewText) {
        startTake(level: .cleanup, text: text)
        finishWrite(result)
    }
    func heldCount() -> Int { ctl.traceHeldCount }
    /// The faked paste's verify and restore end: the oldest open completion runs, then the controller looks again.
    func finishLivePaste() {
        guard !liveDone.isEmpty else { return }
        liveDone.removeFirst()()
        clock.advance(by: 0)
    }
    /// The card is reached, held on, and the old take detached: its write is `writes[0]` (not finished).
    func detachedOne() -> UUID {
        toCard()
        let old = holdOnCard()
        ctl.traceParkedFlow?.parkedRelease()
        return old
    }
}

enum AskBackControllerSelfTest {
    static func run() -> Bool {
        print("--- ask-back controller trace: the real controller and tap routing, fake providers and clock ---")
        Settings.registerDefaults()
        let check = SelfTestReporter()
        let savedEnabled = Settings.askBackEnabled
        let savedTier = Settings.askBackTier
        let savedTailCheck = Settings.tailCheckEnabled
        Settings.askBackEnabled = true
        Settings.askBackTier = .careful
        Settings.tailCheckEnabled = true
        defer {
            Settings.askBackEnabled = savedEnabled
            Settings.askBackTier = savedTier
            Settings.tailCheckEnabled = savedTailCheck
            Settings.isDictationActive = false
        }

        // ---------------------------------------------------------------- a full take: review, card, answer, write, paste
        do {
            let rig = TraceRig(); defer { rig.close() }
            check("trace: before any take nothing is busy and no key is taken",
                  !rig.ctl.oneShotBusy && !rig.hotkey.askCardActive && !rig.hotkey.askReviewActive)
            let id = rig.startTake()
            check("trace: a 50-word Summarize take with ask-back on enters reviewing with the reading cue and one review call",
                  rig.state == "reviewing" && rig.reviews.count == 1 && rig.writes.isEmpty
                    && rig.hud.log.contains("update:" + AskCardText.readingCue) && rig.hotkey.askReviewActive
                    && rig.ctl.traceAskFlow?.phase == .reviewing)
            check("trace: while reviewing a one-shot command counts as busy (S7)", rig.ctl.oneShotBusy)
            check("trace: while reviewing Return, Enter and the arrows are not swallowed",
                  !rig.hotkey.takeAskBackKey(keyCode: TKey.ret, optionHeld: false)
                    && !rig.hotkey.takeAskBackKey(keyCode: TKey.enter, optionHeld: false)
                    && !rig.hotkey.takeAskBackKey(keyCode: TKey.up, optionHeld: false)
                    && !rig.hotkey.takeAskBackKey(keyCode: TKey.down, optionHeld: false))
            rig.answerReview()
            check("trace: a review with a question opens the card: state asking, card flag up, one card, no write yet",
                  rig.state == "asking" && rig.hotkey.askCardActive && !rig.hotkey.askReviewActive
                    && rig.card.shown.count == 1 && rig.writes.isEmpty && rig.hud.log.last != "thinking:on")
            check("trace: while a card is up a one-shot command counts as busy (S7)", rig.ctl.oneShotBusy)
            check("trace: the card swallows Return, up, down and Esc but not left or right",
                  rig.hotkey.takeAskBackKey(keyCode: TKey.down, optionHeld: false)
                    && rig.hotkey.takeAskBackKey(keyCode: TKey.up, optionHeld: false)
                    && !rig.hotkey.takeAskBackKey(keyCode: TKey.left, optionHeld: false)
                    && !rig.hotkey.takeAskBackKey(keyCode: TKey.right, optionHeld: false))
            traceSettle()
            check("trace: the pending History entry is already on disk with status asking and an empty text",
                  rig.entries(id).count == 1 && rig.entries(id)[0].status == "asking" && rig.entries(id)[0].text == "")
            check("trace: Return on the card is swallowed and starts the write",
                  rig.key(TKey.ret) && rig.writes.count == 1 && rig.state == "writing")
            check("trace: the write call carries the answers block with the picked option",
                  rig.writes.first?.request.systemPrompt.contains("1. Q: Which day?\n   A: Friday") == true
                    && rig.writes.first?.request.systemPrompt.contains(AskBackAnswersBlock.header) == true)
            check("trace: once the write runs both key flags are down",
                  !rig.hotkey.askCardActive && !rig.hotkey.askReviewActive)
            check("trace: while writing plain Esc is not swallowed in any app (the review flag is cleared)",
                  !rig.key(TKey.esc) && !rig.hotkey.takeAskBackKey(keyCode: TKey.esc, optionHeld: false))
            check("trace: while writing Return and the arrows are not swallowed",
                  !rig.key(TKey.ret) && !rig.key(TKey.up) && !rig.key(TKey.down))
            check("trace: nothing is pasted before the write returns", rig.pastes == 0)
            rig.finishWrite()
            check("trace: the take's one write pastes once and the controller ends idle",
                  rig.pastes == 1 && rig.hook.finals == [traceCleaned] && rig.state == "idle" && !rig.ctl.oneShotBusy)
            check("trace: the flow saw its own write finish (phase finished)", rig.ctl.traceAskFlow?.phase == .finished)
            let entries = rig.entries(id)
            check("trace: History has exactly one entry for the take, with the answer, the status done and the pasted text",
                  entries.count == 1 && entries[0].status == "done" && entries[0].text == traceCleaned
                    && entries[0].askBack?.questions.first?.answer == "Friday" && entries[0].askBack?.questions.first?.how == "arrows"
                    && entries[0].raw?.isEmpty == false)
            rig.writes.last?.done(.ok("a repeated result")); traceSettle()
            check("trace: a repeated write result pastes nothing more", rig.pastes == 1)
        }

        // ---------------------------------------------------------------- Option+Esc during a review
        do {
            let rig = TraceRig(); defer { rig.close() }
            rig.startTake()
            check("trace: Option+Esc during the review is swallowed and cancels the take (state idle, flow cancelled)",
                  rig.key(TKey.esc, option: true) && rig.state == "idle" && rig.ctl.traceAskFlow?.phase == .cancelled
                    && !rig.hotkey.askReviewActive)
            rig.answerReview()
            check("trace: a late review answer after the cancel opens no card and starts no write",
                  rig.card.shown.isEmpty && !rig.hotkey.askCardActive && rig.state == "idle" && rig.writes.isEmpty && rig.pastes == 0)
        }

        // ---------------------------------------------------------------- Option+Esc during the write
        do {
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            let hid = rig.takeID
            _ = rig.key(TKey.ret)
            check("trace: Option+Esc during the write cancels the take",
                  rig.key(TKey.esc, option: true) && rig.state == "idle" && rig.ctl.traceAskFlow?.phase == .cancelled)
            rig.finishWrite()
            check("trace: the late write after the cancel pastes nothing", rig.pastes == 0 && rig.state == "idle")
            check("trace: the cancelled ask-back take keeps one History entry marked canceled",
                  rig.entries(hid).count == 1 && rig.entries(hid)[0].status == "canceled")
        }

        // ---------------------------------------------------------------- plain Esc during the review
        do {
            let rig = TraceRig(); defer { rig.close() }
            rig.startTake()
            check("trace: plain Esc during the review is swallowed and skips to the write",
                  rig.key(TKey.esc) && rig.writes.count == 1 && rig.state == "writing")
            check("trace: the skipped review writes with no answers block",
                  rig.writes.first?.request.systemPrompt.contains("already answered") == false)
            check("trace: the reading cue goes off when the review is skipped", rig.hud.log.contains("thinking:off"))
            rig.answerReview()
            check("trace: the late review answer after the skip opens no card and starts no second write",
                  rig.card.shown.isEmpty && rig.writes.count == 1 && !rig.hotkey.askCardActive)
            rig.finishWrite()
            check("trace: the skipped take still pastes once", rig.pastes == 1 && rig.state == "idle")
        }

        // ---------------------------------------------------------------- no card up: nothing taken, normal take path
        do {
            let idle = HotkeyMonitor()
            let all: [Int64] = [TKey.esc, TKey.ret, TKey.enter, TKey.up, TKey.down, TKey.left, TKey.right]
            check("trace: with no card, no review and no take no key is swallowed",
                  all.allSatisfy { code in [false, true].allSatisfy { !idle.keyTakenBeforeWakeup(keyCode: code, optionHeld: $0) } })
            idle.takeActive = true
            check("trace: during a normal take Esc, Return and the arrows still pass through",
                  all.allSatisfy { !idle.keyTakenBeforeWakeup(keyCode: $0, optionHeld: false) })
            check("trace: during a normal take Option+Esc is still taken to cancel it",
                  idle.keyTakenBeforeWakeup(keyCode: TKey.esc, optionHeld: true))
            traceSettle()

            var downs = 0, ups = 0, cardDowns = 0, cardUps = 0
            let m = HotkeyMonitor()
            m.onRightOptionDown = { downs += 1 }
            m.onRightOptionUp = { ups += 1 }
            m.onAskCardOptionDown = { cardDowns += 1 }
            m.onAskCardOptionUp = { cardUps += 1 }
            m.takeActive = true
            m.fireWakeup(down: true); m.fireWakeup(down: false); traceSettle()
            check("trace (routing only, separate monitor): with no card up a press and release go to the take, never the card",
                  downs == 1 && ups == 1 && cardDowns == 0 && cardUps == 0)
            m.askCardActive = true
            m.fireWakeup(down: true); m.fireWakeup(down: false); traceSettle()
            check("trace: with a card up the press and release go to the card, not the take",
                  downs == 1 && ups == 1 && cardDowns == 1 && cardUps == 1)
            m.askCardActive = false
            m.askReviewActive = true
            m.fireWakeup(down: true); m.fireWakeup(down: false); traceSettle()
            check("trace: while only a review runs the press and release still belong to the take",
                  downs == 2 && ups == 2 && cardDowns == 1 && cardUps == 1)

            // The same on the rig's own controller (callbacks installed): the press starts a take, the release ends it.
            let rig = TraceRig(); defer { rig.close() }
            rig.pressDown()
            check("trace: with no card up a right-Option press starts a normal take on the controller: recording, takeActive, one start, no card",
                  rig.state == "recording" && rig.hotkey.takeActive && rig.newTakeStates == ["idle"] && rig.card.shown.isEmpty
                    && rig.ctl.traceAskFlow == nil)
            check("trace: during that take plain Esc, Return and the arrows pass through to the app",
                  all.allSatisfy { !rig.key($0) } && rig.state == "recording")
            rig.release()
            check("trace: the release ends that take through the controller (nothing heard here: no audio): idle, takeActive off",
                  rig.state == "idle" && !rig.hotkey.takeActive && rig.toasts.contains("toast:Nothing heard") && rig.card.shown.isEmpty)
            rig.pressDown()
            check("trace: a second press starts a second take", rig.state == "recording" && rig.newTakeStates.count == 2)
            check("trace: Option+Esc during a normal take is swallowed and cancels it through the controller",
                  rig.key(TKey.esc, option: true) && rig.state == "idle" && !rig.hotkey.takeActive)
        }

        // ---------------------------------------------------------------- ask-back off, Cleanup mode, short take: the old path
        do {
            Settings.askBackEnabled = false
            let off = TraceRig(); defer { off.close() }
            let id = off.startTake()
            check("trace: with ask-back off the take starts its write at once: no review, no flow, no new state",
                  off.reviews.isEmpty && off.writes.count == 1 && off.ctl.traceAskFlow == nil
                    && off.state == "finishing" && !off.hotkey.askReviewActive)
            check("trace: with ask-back off the write has no answers block",
                  off.writes.first?.request.systemPrompt.contains("already answered") == false)
            check("trace control: a normal take's write supersedes the retry (the retry observer sees it)", off.retryPosts >= 1)
            off.finishWrite()
            let e = off.entries(id)
            check("trace: with ask-back off the take pastes once and its History entry has no ask-back record",
                  off.pastes == 1 && off.state == "idle" && e.count == 1 && e[0].askBack == nil && e[0].status == nil
                    && e[0].text == traceCleaned)
            Settings.askBackEnabled = true

            let cleanup = TraceRig(); defer { cleanup.close() }
            cleanup.startTake(level: .cleanup)
            check("trace: Cleanup mode never reviews, with ask-back on",
                  cleanup.reviews.isEmpty && cleanup.writes.count == 1 && cleanup.ctl.traceAskFlow == nil && cleanup.state == "finishing")
            cleanup.finishWrite()
            check("trace: Cleanup mode pastes once", cleanup.pastes == 1 && cleanup.state == "idle")

            let short = TraceRig(); defer { short.close() }
            short.startTake(text: "We should ship on Friday. Actually ship on Monday instead of that day.")
            check("trace: a take under 50 words never reviews", short.reviews.isEmpty && short.writes.count == 1 && short.ctl.traceAskFlow == nil)
            short.finishWrite()
            check("trace: a take under 50 words pastes once", short.pastes == 1)
        }

        // ---------------------------------------------------------------- the A/B picker is unchanged
        do {
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            _ = rig.key(TKey.ret)
            rig.finishWrite(String(repeating: "padding words that make the cleaned text far longer than the transcript. ", count: 20))
            check("trace: a suspect result after an ask flow still opens the A/B picker and pastes nothing",
                  rig.abShown.count == 1 && rig.hotkey.abPickerActive && rig.pastes == 0 && rig.ctl.oneShotBusy
                    && rig.ctl.traceAskFlow?.phase == .finished && !rig.hotkey.askCardActive)
            rig.hotkey.abPickerActive = false
            Settings.isDictationActive = false

            let plain = TraceRig(); defer { plain.close() }
            Settings.askBackEnabled = false
            plain.startTake()
            plain.finishWrite(String(repeating: "padding words that make the cleaned text far longer than the transcript. ", count: 20))
            check("trace: a suspect result with ask-back off opens the A/B picker as before",
                  plain.abShown.count == 1 && plain.hotkey.abPickerActive && plain.pastes == 0)
            plain.hotkey.abPickerActive = false
            Settings.askBackEnabled = true
            Settings.isDictationActive = false
        }

        // ---------------------------------------------------------------- S2: right Option + Esc on a card
        do {
            // Esc at 200 ms: before the hold mark. Agent decides, no new take, the normal write and paste.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            rig.pressDown()
            rig.clock.advance(by: 0.2)
            let taken = rig.key(TKey.esc, option: true)
            rig.clock.advance(by: 1.0)
            check("trace S2: Esc at 200 ms under the press is agent-decides: no new take, one write with no answer",
                  taken && rig.newTakeStates.isEmpty && rig.writes.count == 1 && rig.state == "writing"
                    && rig.writes[0].request.systemPrompt.contains(AskBackAnswersBlock.noAnswer))
            rig.release()
            rig.finishWrite()
            check("trace S2: after that chord the old take pastes once", rig.pastes == 1 && rig.state == "idle")
        }
        do {
            // Esc at 600 ms: the hold fired at 300 ms. The new take started but the old one waits; Esc resumes it.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            let id = rig.takeID
            let gen = rig.ctl.traceGeneration
            rig.pressDown()
            rig.clock.advance(by: 0.6)
            traceSettle()
            check("trace S2: the hold closes the card and starts a new take on an idle controller",
                  rig.newTakeStates == ["idle"] && rig.state == "recording" && !rig.hotkey.askCardActive && rig.hotkey.takeActive)
            check("trace S2: the old take waits: no write, no detached job, flow parked",
                  rig.writes.isEmpty && rig.ctl.traceParkedFlow?.phase == .parked && rig.ctl.traceAskFlow == nil)
            let before = rig.hud.log.count
            let taken = rig.key(TKey.esc, option: true)
            check("trace S2: Esc under the same press discards the new take silently and the old take goes on as agent-decides",
                  taken && rig.state == "writing" && rig.writes.count == 1 && rig.ctl.traceParkedFlow == nil
                    && rig.writes[0].request.systemPrompt.contains(AskBackAnswersBlock.noAnswer)
                    && rig.ctl.traceAskFlow?.phase == .writing)
            check("trace S2: that discard shows no toast and does not bump the take generation",
                  !rig.hud.log[before...].contains { $0.hasPrefix("toast:") } && rig.ctl.traceGeneration == gen)
            rig.release()
            rig.finishWrite()
            let e = rig.entries(id)
            check("trace S2: the old take then pastes once with its normal write and has one History entry, status done",
                  rig.pastes == 1 && rig.writes.count == 1 && rig.state == "idle" && e.count == 1 && e[0].status == "done"
                    && rig.store.all().count == 1)
        }
        do {
            // Hold then release with no Esc: the old take detaches, the new take is kept and ends normally.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            let id = rig.takeID
            rig.pressDown()
            rig.clock.advance(by: 0.6)
            traceSettle()
            rig.release()
            check("trace S2: release with no Esc detaches the old take: one detached write, with agent-decides for the open question",
                  rig.writes.count == 1 && rig.writes[0].request.systemPrompt.contains(AskBackAnswersBlock.noAnswer)
                    && rig.ctl.traceParkedFlow == nil)
            check("trace S2: the new take is kept: it ran its own normal release (Nothing heard), not a cancel",
                  rig.newTakeStates == ["idle"] && rig.state == "idle" && rig.toasts == ["toast:Nothing heard"])
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            let e = rig.entries(id)
            check("trace S2: the detached result is one History update, status done, and is held (not pasted yet)",
                  e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned && rig.pastes == 0 && rig.heldCount() == 1)
            check("trace: the detached write never supersedes or touches the retry (arming inert)", rig.retryPosts == 0)
            rig.clock.advance(by: 1.0)
            let after = rig.entries(id)
            check("trace S2: after the new take ended (nothing heard) the held result pastes once, History still one entry, done",
                  rig.pastes == 1 && rig.hook.finals == [traceCleaned] && rig.heldCount() == 0 && after.count == 1
                    && after[0].status == "done" && after[0].text == traceCleaned)
        }

        // ---------------------------------------------------------------- a detached old take leaves the new take alone
        do {
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            let id = rig.takeID
            rig.pressDown()
            rig.clock.advance(by: 0.6)
            traceSettle()
            let stateBefore = rig.state
            let hudBefore = rig.hud.log.count
            let gen = rig.ctl.traceGeneration
            let targetBefore = rig.ctl.authoritativeForeignTargetForGesture()?.label
            let anchor = rig.ctl.traceAskAnchor
            rig.ctl.traceParkedFlow?.parkedRelease()          // the old take detaches; the new take keeps recording
            let wrote = rig.writes.count
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            check("trace: the detached job ran exactly one write", wrote == 1 && rig.writes.count == 1)
            check("trace: the detached job leaves the new take's state untouched (still recording, takeActive)",
                  stateBefore == "recording" && rig.state == "recording" && rig.hotkey.takeActive)
            check("trace: the detached job writes nothing to the HUD (no text, spinner, toast or hide)", rig.hud.log.count == hudBefore)
            check("trace: the detached job leaves the paste target, anchor and generation untouched",
                  rig.ctl.authoritativeForeignTargetForGesture()?.label == targetBefore && rig.ctl.traceAskAnchor == anchor
                    && rig.ctl.traceGeneration == gen)
            check("trace: the detached job leaves the new take's retry untouched and pastes nothing",
                  rig.retryPosts == 0 && rig.pastes == 0)
            check("trace: the detached job's History update is by the old take's id", rig.entries(id).first?.status == "done")
            check("trace: the held result still waits while the new take is live", rig.heldCount() == 1 && rig.pastes == 0)
            rig.release()                      // the new take ends (nothing heard); the old take was detached already
            rig.clock.advance(by: 1.0)
            check("trace: once the new take has ended the held result pastes", rig.pastes == 1 && rig.hook.finals == [traceCleaned])
            Settings.isDictationActive = false
        }

        // ---------------------------------------------------------------- an earlier take pastes afterwards (held results)
        do {
            // Ready before the new take finishes: pastes once, right after the new take's own paste, never before it.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            let old = rig.holdOnCard()
            rig.ctl.traceParkedFlow?.parkedRelease()            // the old take detaches: one detached write
            let hudBefore = rig.hud.log.count
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            let e = rig.entries(old)
            check("held: the detached result is written to History at once, before any paste (status done, its text)",
                  e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned && rig.pastes == 0)
            check("held: while the new take is live the held result changes nothing of it: state, HUD, target, retry",
                  rig.state == "recording" && rig.hotkey.takeActive && rig.hud.log.count == hudBefore
                    && rig.retryPosts == 0 && rig.ctl.authoritativeForeignTargetForGesture() == nil && rig.heldCount() == 1)
            rig.newTakeSpeaks()
            check("held: the new take pastes first, and only its own text",
                  rig.pastes == 1 && rig.hook.finals == [traceNewText] && rig.heldCount() == 1)
            check("held: the held result does not paste inside the call that ended the new take (it waits a turn)",
                  rig.hook.finals == [traceNewText])
            rig.clock.advance(by: 0)
            check("held: then it pastes once, after the new take's paste, through the normal delivery (a route that really pastes)",
                  rig.hook.finals == [traceNewText, traceCleaned] && rig.liveAttempts == [traceNewText, traceCleaned]
                    && rig.heldCount() == 0 && rig.state == "idle")
            rig.clock.advance(by: 5)
            let again = rig.entries(old)
            check("held: nothing pastes twice and the History entry is still one, done, with the landed text",
                  rig.pastes == 2 && again.count == 1 && again[0].status == "done" && again[0].text == traceCleaned
                    && again[0].askBack?.questions.first?.how == "new take")
        }
        do {
            // The result arrives after the new take finished and nothing is busy: it pastes on arrival.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            rig.holdOnCard()
            rig.ctl.traceParkedFlow?.parkedRelease()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 2)
            check("held: a result not ready when the new take finished has not pasted and is still waiting",
                  rig.hook.finals == [traceNewText] && rig.heldCount() == 1)
            rig.writes.first?.done(.ok(traceCleaned)); traceSettle()
            check("held: it pastes when it arrives, nothing being busy", rig.hook.finals == [traceNewText, traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // A third take is recording when it arrives: it waits for that take too.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            rig.holdOnCard()
            rig.ctl.traceParkedFlow?.parkedRelease()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 2)
            rig.pressDown()                                    // a third take starts recording
            rig.writes.first?.done(.ok(traceCleaned)); traceSettle()
            check("held: a result arriving while a third take is recording waits",
                  rig.state == "recording" && rig.hook.finals == [traceNewText] && rig.heldCount() == 1)
            rig.release()                                      // the third take ends (nothing heard)
            rig.clock.advance(by: 1)
            check("held: it pastes after that third take finishes", rig.hook.finals == [traceNewText, traceCleaned] && rig.state == "idle")
        }
        do {
            // A take that starts inside the settle window after the new take's paste keeps the held result waiting.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            rig.holdOnCard()
            rig.ctl.traceParkedFlow?.parkedRelease()
            rig.writes.first?.done(.ok(traceCleaned)); traceSettle()
            rig.newTakeSpeaks()
            rig.pressDown()                                    // a take starts before the held result's turn comes
            rig.clock.advance(by: 3)
            check("held: a take started before the held result's turn keeps it waiting",
                  rig.state == "recording" && rig.hook.finals == [traceNewText] && rig.heldCount() == 1)
            rig.release()
            rig.clock.advance(by: 1)
            check("held: and it pastes after that take", rig.hook.finals == [traceNewText, traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // The new take ends with nothing heard (hold then release): the held result still pastes.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            rig.holdOnCard()
            rig.release()                                      // detaches the old take; the new take heard nothing
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            check("held: a new take that heard nothing does not drop the held result, which waits",
                  rig.pastes == 0 && rig.state == "idle" && rig.heldCount() == 1)
            rig.clock.advance(by: 1)
            check("held: it pastes after the nothing-heard take", rig.hook.finals == [traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // The take it waits behind is cancelled: the held result still pastes.
            let rig = TraceRig(); defer { rig.close() }
            rig.toCard()
            rig.holdOnCard()
            rig.release()
            rig.clock.advance(by: 1)
            rig.pressDown()                                    // another take starts recording
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            check("held: the result waits behind a take that is recording", rig.state == "recording" && rig.pastes == 0 && rig.heldCount() == 1)
            check("held: Option+Esc cancels that take", rig.key(TKey.esc, option: true) && rig.state == "idle")
            rig.clock.advance(by: 1)
            check("held: the held result still pastes after the cancel", rig.hook.finals == [traceCleaned] && rig.heldCount() == 0)
        }
        // Two held results (the old take, then a second old take that was started on the first's new take).
        func twoDetached(_ rig: TraceRig) -> (UUID, UUID) {
            rig.toCard()
            let first = rig.holdOnCard()
            rig.ctl.traceParkedFlow?.parkedRelease()           // the first old take detaches: writes[0]
            rig.startTake()                                    // the new take is a long take of its own and reaches a card
            rig.answerReview()
            let second = rig.holdOnCard()
            rig.ctl.traceParkedFlow?.parkedRelease()           // the second old take detaches: writes[1]
            return (first, second)
        }
        do {
            let rig = TraceRig(); defer { rig.close() }
            let (first, second) = twoDetached(rig)
            check("held: two takes were detached, each with its own write", rig.writes.count == 2 && first != second)
            rig.writes[1].done(.ok("Held two.")); traceSettle()
            rig.writes[0].done(.ok("Held one.")); traceSettle()
            check("held: both results are written to History before either pastes",
                  rig.pastes == 0 && rig.entries(first).first?.text == "Held one." && rig.entries(second).first?.text == "Held two."
                    && rig.heldCount() == 2)
            var firstHeldCompletes: (() -> Void)?
            rig.hook.onCall = { n in if n == 2 { firstHeldCompletes = rig.ctl.traceBeginDelivery() } }   // its paste is still verifying
            rig.newTakeSpeaks()
            check("held: the last take pastes first", rig.hook.finals == [traceNewText])
            rig.clock.advance(by: 1)
            check("held: then the earlier detached result, alone", rig.hook.finals == [traceNewText, "Held one."] && rig.heldCount() == 1)
            rig.clock.advance(by: 5)
            check("held: the second held result waits for the first one's delivery to complete, however long that takes",
                  rig.hook.finals == [traceNewText, "Held one."] && rig.heldCount() == 1)
            firstHeldCompletes?()
            rig.clock.advance(by: 0)
            check("held: then the later one, in order", rig.hook.finals == [traceNewText, "Held one.", "Held two."] && rig.heldCount() == 0)
            rig.clock.advance(by: 5)
            check("held: two held results paste one each, no doubles", rig.pastes == 3 && rig.entries(first).count == 1 && rig.entries(second).count == 1)
        }
        do {
            // The first detached write fails: nothing pastes for it, History says write failed, the line moves on.
            let rig = TraceRig(); defer { rig.close() }
            let (first, second) = twoDetached(rig)
            rig.writes[0].done(.timedOut); traceSettle()
            rig.writes[1].done(.ok("Held two.")); traceSettle()
            check("held: a failed detached write says write failed in History and waits for nothing",
                  rig.entries(first).first?.status == "write failed" && rig.heldCount() == 1 && rig.pastes == 0)
            rig.newTakeSpeaks()
            rig.clock.advance(by: 2)
            check("held: the failed result pastes nothing and the next result pastes in its turn",
                  rig.hook.finals == [traceNewText, "Held two."] && rig.heldCount() == 0
                    && rig.entries(second).first?.status == "done")
        }
        // ---------------------------------------------------------------- round 3: a held result waits for the delivery in front
        do {
            // M1: the new take has finished but its own paste check and clipboard restore have not.
            let rig = TraceRig(); defer { rig.close() }
            _ = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            let inFront = rig.ctl.traceBeginDelivery()          // the new take's paste: verify and restore still pending
            rig.newTakeSpeaks()
            rig.clock.advance(by: 5)
            check("M1: the new take has finished, but its delivery has not completed: the held result does not paste, however long that takes",
                  rig.state == "idle" && rig.hook.finals == [traceNewText] && rig.heldCount() == 1)
            inFront()
            check("M1: completing the delivery does not paste inside its own call", rig.hook.finals == [traceNewText])
            rig.clock.advance(by: 0)
            check("M1: when the delivery in front completes the held result pastes once, after it",
                  rig.hook.finals == [traceNewText, traceCleaned] && rig.heldCount() == 0 && rig.ctl.traceDeliveriesOpen == 0)
        }
        do {
            // A delivery that never opened (nothing heard) releases the held result at once (a turn later), no settle.
            let rig = TraceRig(); defer { rig.close() }
            _ = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.release()
            rig.clock.advance(by: 0)
            check("M1: with no delivery in front and no take live the held result pastes without a fixed wait",
                  rig.hook.finals == [traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // The delivery in front parked its text on the clipboard for a manual Cmd+V: no paste, History kept, line moves on.
            let rig = TraceRig(); defer { rig.close() }
            let first = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.newTakeSpeaks()
            rig.ctl.traceParkPaste()
            rig.clock.advance(by: 5)
            let e = rig.entries(first)
            check("M1 park: a parked delivery in front means the held result does not paste",
                  rig.hook.finals == [traceNewText] && rig.pasteboard.string(forType: .string) != traceCleaned)
            check("M1 park: the held result stays in History (done, its text) and the queue has moved on",
                  e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned && rig.heldCount() == 0)
        }
        do {
            let rig = TraceRig(); defer { rig.close() }
            _ = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.newTakeSpeaks()
            rig.ctl.traceParkPaste()
            rig.pasteboard.clearContents()                       // the user copied something since: nothing is parked any more
            rig.clock.advance(by: 5)
            check("M1 park: once the pasteboard has changed since the park the held result pastes as usual",
                  rig.hook.finals == [traceNewText, traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // Two held results behind a parked delivery: both stay History only, in order, and the line ends empty.
            let rig = TraceRig(); defer { rig.close() }
            let (first, second) = twoDetached(rig)
            rig.writes[0].done(.ok("Held one.")); traceSettle()
            rig.writes[1].done(.ok("Held two.")); traceSettle()
            rig.newTakeSpeaks()
            rig.ctl.traceParkPaste()
            rig.clock.advance(by: 5)
            check("M1 park: every held result behind a parked delivery stays History only and the queue is empty",
                  rig.hook.finals == [traceNewText] && rig.heldCount() == 0
                    && rig.entries(first).first?.text == "Held one." && rig.entries(second).first?.text == "Held two.")
        }
        // ---------------------------------------------------------------- round 4: the delivery's own outcome and the live route
        do {
            // Live route: the held paste waits for the new take's paste to complete, however long (rig-controlled completion).
            let rig = TraceRig(); defer { rig.close() }
            rig.liveHold = true
            _ = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 30)
            check("live: the new take pasted through the faked paste and its completion is still pending",
                  rig.liveAttempts == [traceNewText] && rig.liveDone.count == 1 && rig.ctl.traceDeliveriesOpen == 1)
            check("live: the held result does not paste while the new take's paste has not completed",
                  rig.hook.finals == [traceNewText] && rig.heldCount() == 1)
            rig.finishLivePaste()
            check("live: when the paste completes the held result pastes once, after it, and is itself a delivery in front",
                  rig.liveAttempts == [traceNewText, traceCleaned] && rig.heldCount() == 0 && rig.ctl.traceDeliveriesOpen == 1)
            rig.finishLivePaste()
            check("live: and that delivery closes when its own paste completes", rig.ctl.traceDeliveriesOpen == 0 && rig.hook.finals == [traceNewText, traceCleaned])
        }
        do {
            // Live route, focus left the field: the click-away park. The delivery closes at once (the park's settled()),
            // the new take's text waits on the clipboard, and the held result stays in History only.
            let rig = TraceRig(); defer { rig.close() }
            let old = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.liveCanPaste = false
            rig.newTakeSpeaks()
            check("live park: the click-away park leaves the new take's text on the clipboard and closes its delivery",
                  rig.pasteboard.string(forType: .string) == traceNewText && rig.ctl.traceDeliveriesOpen == 0)
            rig.clock.advance(by: 5)
            let e = rig.entries(old)
            check("live park: the held result is not pasted, the clipboard still holds the new take's text, the queue has moved on",
                  rig.liveAttempts == [traceNewText] && rig.pasteboard.string(forType: .string) == traceNewText && rig.heldCount() == 0)
            check("live park: the held result stays in History (done, its text)", e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned)
        }
        do {
            // M1: the new take left its text on the clipboard for a manual Cmd+V (the locked landing with no field).
            let rig = TraceRig(); defer { rig.close() }
            rig.route = .noTarget
            let old = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.newTakeSpeaks()
            check("M1 clipboard-only: the new take's text is on the clipboard for a manual paste",
                  rig.pasteboard.string(forType: .string) == traceNewText && rig.toasts.contains { $0.contains("Put on your clipboard") })
            rig.clock.advance(by: 5)
            let e = rig.entries(old)
            check("M1 clipboard-only: after the held turn the clipboard still holds the new take's text and the held result is History only",
                  rig.pasteboard.string(forType: .string) == traceNewText && rig.hook.finals == [traceNewText] && rig.heldCount() == 0
                    && e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned)
        }
        do {
            // Control: the user copied something since the clipboard-only delivery closed, so the held result delivers as normal.
            let rig = TraceRig(); defer { rig.close() }
            rig.route = .noTarget
            _ = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.newTakeSpeaks()
            rig.pasteboard.clearContents()
            rig.pasteboard.setString("something Ben copied", forType: .string)
            rig.clock.advance(by: 5)
            check("M1 clipboard-only control: the pasteboard changed first, so the held result is delivered (to the clipboard, same route)",
                  rig.hook.finals == [traceNewText, traceCleaned] && rig.pasteboard.string(forType: .string) == traceCleaned && rig.heldCount() == 0)
        }
        do {
            // Two held results behind a clipboard-only delivery: both stay History only, in order.
            let rig = TraceRig(); defer { rig.close() }
            rig.route = .noTarget
            let (first, second) = twoDetached(rig)
            rig.writes[0].done(.ok("Held one.")); traceSettle()
            rig.writes[1].done(.ok("Held two.")); traceSettle()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 5)
            check("M1 clipboard-only: every held result behind it is History only and the clipboard holds the new take's text",
                  rig.hook.finals == [traceNewText] && rig.heldCount() == 0 && rig.pasteboard.string(forType: .string) == traceNewText
                    && rig.entries(first).first?.text == "Held one." && rig.entries(second).first?.text == "Held two.")
        }
        do {
            // A delivery that really pasted leaves nothing on the clipboard: the next held result is not held back by an
            // earlier clipboard-only delivery (the record is replaced by every delivery).
            let rig = TraceRig(); defer { rig.close() }
            rig.route = .noTarget
            rig.startTake(level: .cleanup, text: "A short earlier take."); rig.finishWrite("Earlier text.")
            rig.route = .live
            let (_, _) = twoDetached(rig)
            rig.writes[1].done(.ok("Held one.")); traceSettle()     // writes[0] was the earlier take's own write
            rig.writes[2].done(.ok("Held two.")); traceSettle()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 5)
            check("M1 clipboard-only: a clipboard-only delivery two takes back does not hold the held results back",
                  rig.hook.finals == ["Earlier text.", traceNewText, "Held one.", "Held two."])
        }
        do {
            // M2: a selection one-shot holds the user's selection from capture to landing.
            let rig = TraceRig(); defer { rig.close() }
            var latch = false
            rig.ctl.askSeams.oneShotLatch = { latch }
            _ = rig.detachedOne()
            rig.release()                                        // the new take ends (nothing heard): controller idle
            latch = true                                         // the one-shot has captured the selection
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.clock.advance(by: 3)
            check("M2: a held result ready while a selection one-shot is busy waits, with no take live",
                  rig.state == "idle" && rig.hook.finals.isEmpty && rig.heldCount() == 1)
            let landing = rig.ctl.traceBeginDelivery()           // the one-shot's own landing starts as its latch drops
            latch = false
            rig.clock.advance(by: 2)
            check("M2: the one-shot's latch has dropped but its landing has not completed: the held result still waits",
                  rig.hook.finals.isEmpty && rig.heldCount() == 1)
            landing()
            rig.clock.advance(by: 0)
            check("M2: it pastes only after the one-shot's landing completes", rig.hook.finals == [traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // Cancelled one-shot: a held result that waited behind a selection one-shot whose latch then drops with no
            // landing (cancelled at the level picker, failed, nothing selected) stays in History only; the line moves on.
            let rig = TraceRig(); defer { rig.close() }
            var latch = false
            rig.ctl.askSeams.oneShotLatch = { latch }
            let old = rig.detachedOne()
            rig.release()
            latch = true
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.clock.advance(by: 1)
            check("cancelled one-shot: while the latch is up the held result waits", rig.hook.finals.isEmpty && rig.heldCount() == 1)
            latch = false                                        // the one-shot ended without a landing (cancelled)
            rig.clock.advance(by: 0.5)
            let e = rig.entries(old)
            check("cancelled one-shot: when the latch drops with no landing the held result does not paste and nothing is attempted",
                  rig.hook.finals.isEmpty && rig.liveAttempts.isEmpty && rig.heldCount() == 0)
            check("cancelled one-shot: the result stays in History (done, its text)",
                  e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned)
            rig.clock.advance(by: 5)
            check("cancelled one-shot: and it does not paste later either", rig.hook.finals.isEmpty && rig.liveAttempts.isEmpty)
        }
        do {
            // Cancelled one-shot, two results: the one that waited is History only; one whose write ends later keeps its turn.
            let rig = TraceRig(); defer { rig.close() }
            var latch = false
            rig.ctl.askSeams.oneShotLatch = { latch }
            let (first, _) = twoDetached(rig)
            rig.release()
            latch = true
            rig.writes[0].done(.ok("Held one.")); traceSettle()
            rig.clock.advance(by: 1)
            latch = false
            rig.clock.advance(by: 0.5)
            check("cancelled one-shot: the ready result is History only, the one still writing keeps its slot",
                  rig.hook.finals.isEmpty && rig.heldCount() == 1 && rig.entries(first).first?.text == "Held one.")
            rig.writes[1].done(.ok("Held two.")); traceSettle()
            rig.clock.advance(by: 1)
            check("cancelled one-shot: the later result pastes in its turn", rig.hook.finals == ["Held two."] && rig.heldCount() == 0)
        }
        do {
            // A one-shot that lands counts as the delivery in front: the held result pastes after its completion.
            let rig = TraceRig(); defer { rig.close() }
            var latch = false
            rig.ctl.askSeams.oneShotLatch = { latch }
            _ = rig.detachedOne()
            rig.release()
            latch = true
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.clock.advance(by: 1)
            let landing = rig.ctl.traceBeginDelivery()
            latch = false
            rig.clock.advance(by: 0.5)
            check("landed one-shot: the held result still waits while the landing is open", rig.hook.finals.isEmpty && rig.heldCount() == 1)
            landing()
            rig.clock.advance(by: 0)
            check("landed one-shot: it pastes after the landing completes", rig.hook.finals == [traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // M2: the gap between a one-shot discarding its incidental take and setting its latch (the selection copy).
            let rig = TraceRig(); defer { rig.close() }
            _ = rig.detachedOne()
            rig.writes.last?.done(.ok(traceCleaned)); traceSettle()
            rig.ctl.discardIncidentalAudio()                     // Option+P on the new take's press: the take is thrown away
            rig.clock.advance(by: 0.3)
            check("M2: right after a one-shot throws its incidental take away (selection copy pending) the held result waits",
                  rig.state == "idle" && rig.hook.finals.isEmpty && rig.heldCount() == 1)
            rig.clock.advance(by: 0.6)
            check("M2: if no one-shot latch follows, it pastes once the copy window is over",
                  rig.hook.finals == [traceCleaned] && rig.heldCount() == 0)
        }
        do {
            // S3: a held result the rogue-output check flags is not pasted unasked.
            let rig = TraceRig(); defer { rig.close() }
            let old = rig.detachedOne()
            let rogue = String(repeating: "an answer instead of a summary ", count: 40)
            rig.writes.last?.done(.ok(rogue)); traceSettle()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 5)
            let e = rig.entries(old)
            check("S3: a held result that trips the cleanup-suspect check is not pasted, and no picker opens",
                  rig.hook.finals == [traceNewText] && rig.abShown.isEmpty)
            check("S3: it stays in History (done, its text) and the queue has moved on",
                  e.count == 1 && e[0].status == "done" && e[0].text == rogue && rig.heldCount() == 0)
        }
        do {
            // S3 and order: a suspect first result does not block the second one.
            let rig = TraceRig(); defer { rig.close() }
            let (first, _) = twoDetached(rig)
            rig.writes[0].done(.ok(String(repeating: "an answer instead of a summary ", count: 40))); traceSettle()
            rig.writes[1].done(.ok("Held two.")); traceSettle()
            rig.newTakeSpeaks()
            rig.clock.advance(by: 5)
            check("S3: the queue moves on past a suspect result and pastes the next one",
                  rig.hook.finals == [traceNewText, "Held two."] && rig.heldCount() == 0 && rig.entries(first).first?.status == "done")
        }

        do {
            // Option+P: its detached result stays History only. The controller has no Option+P detach path yet
            // (slice 7 adds it), so no controller row can reach it; the rule is pinned where it lives
            // (AskBackDetachedJob.holdsResult, oracle rows and mutant H-option-p-held).
            let rec = AskBackRecord(provider: "claude", reviewModel: "m", tier: "careful", reviewMs: 1, writeProvider: nil,
                                    writeModel: nil, writeMs: nil, spots: [], questions: [])
            func job(_ source: AskBackSource) -> AskBackDetachedJob {
                AskBackDetachedJob(historyID: UUID(), transcript: "t", level: .summarize, levelRaw: 2, questions: [], answers: [],
                                   record: rec, writeProvider: "claude", writeModel: "m", generation: 1, source: source)
            }
            check("held: only a dictation take's detached job holds its result; an Option+P job stays History only",
                  job(.dictation).holdsResult && !job(.selection).holdsResult)
        }

        // ---------------------------------------------------------------- S2: the completion plumbing, exit by exit
        do {
            struct Exit { var completes = 0, restores = 0, giveUps = 0, started = false }
            func drive(states: [PasteFieldState], posts: [Bool] = [true], seen: Bool = true, canContinue: Bool = true,
                       pasteboardUnchanged: Bool = true) -> Exit {
                var out = Exit()
                var si = 0, pi = 0, scheduled = 0
                let driver = PasteVerifyDriver(
                    delivered: "world",
                    readState: { let st = states[min(si, states.count - 1)]; si += 1; return st },
                    postPaste: { let r = posts[min(pi, posts.count - 1)]; pi += 1; return r },
                    scheduleAfter: { _, work in scheduled += 1; if scheduled <= 60 { work() } },
                    pasteboardUnchanged: { pasteboardUnchanged },
                    canContinue: { canContinue },
                    seenLive: { seen }, markSeenLive: { },
                    restore: { out.restores += 1 },
                    onGiveUp: { out.giveUps += 1 },
                    log: { _ in },
                    onComplete: { out.completes += 1 })
                out.started = driver.run()
                return out
            }
            func st(_ t: String) -> PasteFieldState { PasteFieldState(value: t) }
            let landed = drive(states: [st("hello"), st("hello world")])
            check("S2 driver: the paste landed and the restore ran: onComplete fires exactly once, after the restore",
                  landed.started && landed.restores == 1 && landed.completes == 1)
            let skipped = drive(states: [st("hello"), st("hello world")], pasteboardUnchanged: false)
            check("S2 driver: the paste landed but the pasteboard changed (restore skipped): onComplete fires exactly once",
                  skipped.started && skipped.restores == 0 && skipped.completes == 1)
            let gaveUp = drive(states: [st("hello")])
            check("S2 driver: the check gave up after its retries: onGiveUp once and onComplete exactly once",
                  gaveUp.started && gaveUp.giveUps == 1 && gaveUp.completes == 1 && gaveUp.restores == 0)
            let repostFailed = drive(states: [st("hello")], posts: [true, false])
            check("S2 driver: the re-post failed (give up): onComplete exactly once",
                  repostFailed.started && repostFailed.giveUps == 1 && repostFailed.completes == 1)
            let stopped = drive(states: [st("hello")], canContinue: false)
            check("S2 driver: stopped because the pasteboard changed under the retry: no restore, onComplete exactly once",
                  stopped.started && stopped.restores == 0 && stopped.giveUps == 0 && stopped.completes == 1)
            let unreadable = drive(states: [st("hello"), PasteFieldState(value: nil)])
            check("S2 driver: the field became unreadable: restore runs and onComplete fires exactly once",
                  unreadable.started && unreadable.completes == 1)
            let notStarted = drive(states: [st("hello")], posts: [false])
            check("S2 driver: the first keystroke could not be posted: run() is false and the driver does not call onComplete (the caller owns it)",
                  !notStarted.started && notStarted.completes == 0)
            // The two callers that cannot run headless (a real focused field, the general pasteboard): named source-shape rows.
            let here = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let resolver = (try? String(contentsOf: here.appendingPathComponent("Sources/App/TargetResolver.swift"), encoding: .utf8)) ?? ""
            let controller = (try? String(contentsOf: here.appendingPathComponent("Sources/App/DictationController.swift"), encoding: .utf8)) ?? ""
            check("S2 source shape: pasteIntoFocus calls onComplete itself when the first keystroke was not posted",
                  resolver.contains("let started = driver.run()\n        if !started { onComplete?() }"))
            check("S2 source shape: pasteIntoCapturedTarget hands settled to the paste when the operation ran and fires it itself otherwise",
                  resolver.contains("done(pasteIntoFocus(text, onComplete: settled))") && resolver.contains("if !operationRan { settled?() }")
                    && resolver.contains("operationRan = true"))
            check("S2 source shape: the click-away park closes its delivery, and every receipt is recorded when a delivery finishes",
                  controller.contains("settled()   // nothing pastes now") && controller.contains("case .clipboard(let count): self.askLastClipboardOnly = true")
                    && controller.contains("case .pastePark: self.askLastClipboardOnly = true"))
        }

        // ---------------------------------------------------------------- S4, S5, S6 and tap wiring that no headless row reaches
        do {
            let here = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let app = here.appendingPathComponent("Sources").appendingPathComponent("App")
            func source(_ name: String) -> String { (try? String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)) ?? "" }
            let hot = source("HotkeyMonitor.swift")
            let handle = hot.range(of: "private func handleKeyDown")
                .map { String(hot[$0.lowerBound...].prefix(2200)) } ?? ""
            check("wiring (tap callback, no window server): handleKeyDown calls keyTakenBeforeWakeup before the wakeup key",
                  handle.contains("keyTakenBeforeWakeup(keyCode: keyCode"))
            check("wiring (tap callback): the wakeup press and release sites all go through fireWakeup",
                  hot.components(separatedBy: "fireWakeup(down:").count - 1 == 4)
            let ctlSrc = source("DictationController.swift")
            let begin = ctlSrc.range(of: "private func beginRecording()")
                .map { String(ctlSrc[$0.lowerBound...].prefix(6000)) } ?? ""
            check("wiring (beginRecording needs mic, AX and the daemon) S4: a take start clears the marker's last placement first",
                  begin.contains("pasteMarker.lastPlacement = nil") && (begin.range(of: "pasteMarker.lastPlacement = nil")?.lowerBound ?? begin.endIndex)
                    < (begin.range(of: "pasteMarker.start(")?.lowerBound ?? begin.startIndex))
            let panel = source("AskCardPanel.swift")
            let optionRow = panel.range(of: "private final class OptionRow")
                .map { String(panel[$0.lowerBound...].prefix(1200)) } ?? ""
            check("wiring (AppKit view) S5: OptionRow takes the click itself through hitTest, as the History rows do",
                  optionRow.contains("override func hitTest(_ point: NSPoint) -> NSView?") && optionRow.contains("? self : nil"))
        }
        do {
            let rec = AskBackRecord(provider: "claude", reviewModel: "m", tier: "careful", reviewMs: 1, writeProvider: nil,
                                    writeModel: nil, writeMs: nil, spots: [], questions: [])
            func entry(text: String, record: AskBackRecord?, raw: String?) -> TranscriptionHistory.Entry {
                TranscriptionHistory.Entry(id: UUID(), date: Date(), text: text, app: "App", raw: raw, cleaned: nil,
                                           mode: nil, level: nil, askBack: record, status: record == nil ? nil : "canceled")
            }
            func row(_ e: TranscriptionHistory.Entry) -> RecentDictationsModel.Row? {
                RecentDictationsModel.rows(transcripts: [e], retainedTakes: [], hasAudio: { _ in false }).first
            }
            let blank = row(entry(text: "", record: rec, raw: "the raw words of a cancelled ask-back take"))
            check("S6: Recent dictations shows the raw transcript for an ask-back entry with empty text, and Copy copies it",
                  blank?.preview.contains("raw words") == true && blank?.copyText == "the raw words of a cancelled ask-back take")
            let landed = row(entry(text: "landed text", record: rec, raw: "raw"))
            check("S6: an ask-back entry whose text landed shows that text", landed?.copyText == "landed text")
            let plain = row(entry(text: "", record: nil, raw: "raw"))
            check("S6: an entry with no ask-back record and empty text is unchanged", plain?.copyText == "")
        }

        print(check.summaryLine(prefix: "[askback-controller-selftest]"))
        return check.passed
    }
}
