import AppKit
import Foundation

// VDASK-3 controller trace test. Drives the REAL DictationController headless (null-style HUD that records,
// the way TailCheckSelfTest drives deliver()) with a fake review provider, a fake write provider and a fake
// clock, injected through DictationController.AskBackSeams. It also drives the REAL HotkeyMonitor routing
// functions (`keyTakenBeforeWakeup`, `takeAskBackKey`, `fireWakeup`) the CGEvent tap calls, because the tap
// itself cannot run without a window server. Source-shape rows cover only wiring no headless row can reach:
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
    func call(finalText: String, rawText: String, segments: [TailCheck.Segment], cleanupLevel: String) {
        finals.append(finalText)
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
        ctl.takeLandAtStart = true
        ctl.askSeams.resolve = { _ in .pinned(.claude("claude-trace-model")) }
        ctl.askSeams.reviewProvider = { [unowned self] system, input, done in reviews.append((system, input, done)) }
        ctl.askSeams.claudeWrite = { [unowned self] request, done in writes.append((request, done)) }
        ctl.askSeams.schedule = { [unowned self] after, fire in clock.schedule(after, fire) }
        ctl.askSeams.now = { [unowned self] in clock.now }
        ctl.askSeams.beginNewTake = { [unowned self] in newTakeStates.append(ctl.traceStateName) }
        ctl.askSeams.cardPanel = card
        ctl.askSeams.abPickerShow = { [unowned self] raw, cleaned in abShown.append((raw, cleaned)) }
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
            check("trace: with no card up a right-Option press and release start and end the take, never the card",
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
            check("trace S2: the detached result is one History update, status done, and nothing is pasted",
                  e.count == 1 && e[0].status == "done" && e[0].text == traceCleaned && rig.pastes == 0)
            check("trace: the detached write never supersedes or touches the retry (arming inert)", rig.retryPosts == 0)
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
            Settings.isDictationActive = false
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
