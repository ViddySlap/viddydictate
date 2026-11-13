import Foundation

// VDASK-3 self-test: the ask-back take flow (fake clock, fake hooks), keys router, answers block, card text and
// placement, and the History record on a real on-disk store in a scratch folder. Synthetic text only. The
// flow rows mirror the Linux oracle's (b3-out/oracle/flow-rows.swift); the History rows run the real
// TranscriptionHistory. Focus, drag and the event tap are Mac-only checks and are not covered here.

private final class FlowClock {
    var now = 0.0
    private var nextID = 0
    private var timers: [(id: Int, due: Double, fire: () -> Void)] = []
    func schedule(_ after: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, now + after, fire))
        return { [self] in timers.removeAll { $0.id == id } }
    }
    func advance(to t: Double) {
        while let next = timers.filter({ $0.due <= t + 1e-9 }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            now = max(now, next.due)
            next.fire()
        }
        now = t
    }
}

private final class FlowHarness {
    static let transcript = "We should ship on Friday. Actually let\u{2019}s ship on Monday. Don't tell the client yet."
    let clock = FlowClock()
    var flow: AskBackFlow!
    var reviews: [UUID] = [], skipped: [UUID] = [], cues: [Bool] = [], phases: [AskBackFlow.Phase] = []
    var cards: [AskCardModel] = [], closed: [UUID] = []
    var writes: [AskBackWriteSpec] = [], history: [AskBackHistoryEvent] = []
    var detached: [AskBackDetachedJob] = []
    var newTakes = 0, pastes = 0
    let historyID = UUID()

    init(provider: AskBackProvider = .claude) {
        let context = AskBackFlow.Context(historyID: historyID, transcript: Self.transcript, level: .summarize, levelRaw: 2,
                                          tier: .careful, provider: provider, writeModel: "write-model-x", generation: 7)
        let hooks = AskBackFlow.Hooks(
            phaseChanged: { [unowned self] in phases.append($0) },
            readingCue: { [unowned self] in cues.append($0) },
            startReview: { [unowned self] in reviews.append($0) },
            skipReview: { [unowned self] in skipped.append($0) },
            showCard: { [unowned self] in cards.append($0) },
            highlight: { _, _ in },
            closeCard: { [unowned self] in closed.append($0) },
            startWrite: { [unowned self] in writes.append($0) },
            history: { [unowned self] in history.append($0) },
            saveDetached: { [unowned self] in detached.append($0) },
            startNewTake: { [unowned self] in newTakes += 1 })
        flow = AskBackFlow(context: context, schedule: clock.schedule, now: { [unowned self] in clock.now }, hooks: hooks)
    }

    static func question(_ n: Int, options: Int = 4) -> AskBackQuestion {
        AskBackQuestion(question: "Question \(n)?", quote: "quote \(n)", why: "why \(n)",
                        options: (1...options).map { "opt\(n)-\($0)" })
    }
    func review(_ qs: [AskBackQuestion], at t: Double? = nil) {
        if let t = t { clock.advance(to: t) }
        flow.reviewOutcome(reviews.last!, .result(AskBackReviewResult(
            spots: [AskBackSpot(quote: "ship on Friday", issue: "two days", impact: "high")], questions: qs)))
    }
    func finishWrite(ok: Bool = true) {
        guard let w = writes.last else { return }
        flow.writeFinished(w.writeID, ok: ok) { pastes += 1 }
    }
    func tap() { clock.advance(to: clock.now + 0.05); flow.optionDown(); clock.advance(to: clock.now + 0.1); flow.optionUp() }
    func taps(_ n: Int) { for _ in 0..<n { tap() }; clock.advance(to: clock.now + 0.4) }
}

enum AskBackFlowSelfTest {
    static func run() -> Bool {
        print("--- ask-back flow: states, keys, taps, hold, answers block, History, card text ---")
        Settings.registerDefaults()
        let check = SelfTestReporter()
        typealias H = FlowHarness

        // start, cue, one card at a time, one write, one paste
        do {
            let h = H(); h.flow.start()
            check("flow: start shows the reading cue and starts one review",
                  h.flow.phase == .reviewing && h.cues == [true] && h.reviews.count == 1 && AskCardText.readingCue == "Reading your take\u{2026}")
            h.review([H.question(1), H.question(2)], at: 12.5)
            check("flow: questions open card 1 of 2, the cue goes off, History is inserted once",
                  h.cards.count == 1 && h.cards[0].total == 2 && h.cues == [true, false]
                    && h.history.filter { if case .insertPending = $0 { return true } else { return false } }.count == 1)
            h.flow.key(.commit); h.flow.key(.commit)
            h.finishWrite(); h.finishWrite()
            check("flow: cards in order, one write, at most one paste",
                  h.cards.map { $0.index } == [0, 1] && h.writes.count == 1 && h.pastes == 1
                    && h.phases == [.reviewing, .asking, .writing, .finished])
        }
        do {
            let h = H(); h.flow.start(); h.review([])
            check("flow: no questions writes at once with no card", h.cards.isEmpty && h.writes.count == 1 && h.writes[0].questions.isEmpty)
        }

        // Esc, Option+Esc, skip, cancel
        do {
            let h = H(); h.flow.start(); h.review([H.question(1)]); h.flow.key(.esc)
            check("keys: Esc during a card is agent-decides and the take continues",
                  h.writes.count == 1 && h.writes[0].answers == [AskBackAnswer(text: nil, how: .agentDecided)])
            let o = H(); o.flow.start(); o.review([H.question(1)]); o.flow.key(.optionEsc)
            check("keys: Option+Esc during a card is agent-decides, not a cancel", o.writes.count == 1 && o.flow.phase == .writing)
            let r = H(); r.flow.start(); let id = r.reviews[0]; r.flow.cancel()
            r.flow.reviewOutcome(id, .result(AskBackReviewResult(spots: [], questions: [H.question(1)])))
            check("keys: cancel during reviewing drops a late review answer", r.flow.phase == .cancelled && r.cards.isEmpty && r.writes.isEmpty)
            let w = H(); w.flow.start(); w.review([]); let wid = w.writes[0].writeID; w.flow.cancel()
            w.flow.writeFinished(wid, ok: true) { w.pastes += 1 }
            check("keys: cancel during writing pastes nothing for a late write", w.pastes == 0 && w.flow.phase == .cancelled)
            let s = H(); s.flow.start(); let sid = s.reviews[0]; s.flow.key(.skipReview)
            s.flow.reviewOutcome(sid, .result(AskBackReviewResult(spots: [], questions: [H.question(1)])))
            check("keys: plain Esc during reviewing skips to the write and the late answer is dropped",
                  s.skipped == [sid] && s.writes.count == 1 && s.cards.isEmpty && s.history.isEmpty)
        }

        // taps
        for n in 1...5 {
            let h = H(); h.flow.start(); h.review([H.question(1)]); h.taps(n)
            let want = min(n, 4)
            check("taps: \(n) tap(s) pick option \(want)", h.writes.first?.answers == [AskBackAnswer(text: "opt1-\(want)", how: .tap)])
        }
        do {
            let h = H(); h.flow.start(); h.review([H.question(1)])
            h.flow.optionDown(); h.flow.optionUp()                      // release at 0 ms
            h.clock.advance(to: 0.35); h.flow.optionDown()               // press at 350 ms
            h.clock.advance(to: 0.40)
            let quiet = h.writes.isEmpty && h.newTakes == 0
            h.clock.advance(to: 0.65)
            check("gesture: release at 0, press at 350: nothing at 400 ms, hold at 650 ms (the old take waits, parked)",
                  quiet && h.newTakes == 1 && h.detached.isEmpty && h.flow.phase == .parked)
        }
        do {
            let h = H(); h.flow.start(); h.review([H.question(1), H.question(2)])
            h.tap(); h.flow.key(.commit); h.clock.advance(to: h.clock.now + 1)
            check("keys: Return while taps are pending uses Return and cancels the taps",
                  h.flow.answers[0] == AskBackAnswer(text: "opt1-1", how: .arrows) && h.flow.answers[1] == nil)
            let c = H(); c.flow.start(); c.review([H.question(1), H.question(2)])
            c.tap(); c.flow.click(cardID: c.cards[0].cardID, option: 2); c.clock.advance(to: c.clock.now + 1)
            check("keys: a click while taps are pending uses the click",
                  c.flow.answers[0] == AskBackAnswer(text: "opt1-3", how: .click) && c.flow.answers[1] == nil)
            let k = H(); k.flow.start(); k.review([H.question(1), H.question(2)])
            let first = k.cards[0].cardID; k.flow.key(.commit); k.flow.click(cardID: first, option: 1)
            check("click: a stale card id does nothing", k.flow.answers[1] == nil && k.writes.isEmpty)
        }

        // S2: right Option + Esc on a card
        do {
            let early = H(); early.flow.start(); early.review([H.question(1)])
            early.flow.optionDown(); early.clock.advance(to: 0.2); early.flow.key(.optionEsc); early.clock.advance(to: 1.0)
            check("S2 chord: Esc at 200 ms is agent-decides and no new take starts",
                  early.newTakes == 0 && early.detached.isEmpty && early.writes.count == 1
                    && early.writes[0].answers == [AskBackAnswer(text: nil, how: .agentDecided)])
            let late = H(); late.flow.start(); late.review([H.question(1)])
            late.flow.optionDown(); late.clock.advance(to: 0.6)
            let waiting = late.newTakes == 1 && late.detached.isEmpty && late.writes.isEmpty && late.flow.phase == .parked
            let resumed = late.flow.parkedEsc()
            late.finishWrite()
            check("S2 chord: Esc at 600 ms resumes the old take as agent-decides with its normal write and one paste",
                  waiting && resumed && late.detached.isEmpty && late.writes.count == 1 && late.pastes == 1
                    && late.writes[0].answers == [AskBackAnswer(text: nil, how: .agentDecided)])
            let rel = H(); rel.flow.start(); rel.review([H.question(1)])
            rel.flow.optionDown(); rel.clock.advance(to: 0.6); rel.flow.parkedRelease()
            check("S2 chord: hold then release with no Esc detaches the old take and keeps the new take",
                  rel.detached.count == 1 && rel.newTakes == 1 && rel.flow.phase == .detached && !rel.flow.parkedEsc())
        }

        // hold: detached save-only job
        do {
            let h = H(); h.flow.start(); h.review([H.question(1), H.question(2)])
            h.flow.optionDown(); h.clock.advance(to: h.clock.now + 0.3)
            h.flow.parkedRelease()                                       // the press ends with no Esc
            let job = h.detached.first
            check("detached: a hold hands the old take to one save-only job and starts one new take",
                  h.detached.count == 1 && h.newTakes == 1 && h.writes.isEmpty && h.pastes == 0 && h.flow.phase == .detached
                    && job?.record.questions.map { $0.how } == ["new take", "new take"])
            var updates: [AskBackHistoryEvent] = []
            AskBackDetached.run(job!, now: { 0 }, write: { _, done in done("Written."); done("again") }, history: { updates.append($0) })
            check("detached: exactly one History update with the result", updates.count == 1
                  && { if case .update(let u) = updates[0] { return u.id == h.historyID && u.status == "done" && u.delivered == "Written." } else { return false } }())
            var failed: [AskBackHistoryEvent] = []
            AskBackDetached.run(job!, now: { 0 }, write: { _, done in done(nil) }, history: { failed.append($0) })
            check("detached: a failed write says write failed and keeps the transcript",
                  { if case .update(let u)? = failed.first { return u.status == "write failed" && u.delivered == H.transcript } else { return false } }())
        }

        // keys router
        do {
            var noCard = false
            for code in Int64(0)...127 { for opt in [false, true] where AskBackKeyRouter.route(keyCode: code, optionHeld: opt, cardUp: false, reviewing: false) != nil { noCard = true } }
            var up: Set<Int64> = []
            for code in Int64(0)...127 where AskBackKeyRouter.route(keyCode: code, optionHeld: false, cardUp: true, reviewing: false) != nil { up.insert(code) }
            check("router: no key is swallowed when no card is up", !noCard)
            check("router: with a card up only up, down, Return, Enter and Esc are taken", up == [126, 125, 36, 76, 53])
            check("router: while a review runs only plain Esc is taken",
                  AskBackKeyRouter.route(keyCode: 53, optionHeld: false, cardUp: false, reviewing: true) == .skipReview
                    && AskBackKeyRouter.route(keyCode: 53, optionHeld: true, cardUp: false, reviewing: true) == nil)
        }

        // 50-word gate on the take path
        func gate(_ n: Int, _ level: AskBackLevel = .summarize, _ p: AskBackProvider = .claude, enabled: Bool = true) -> Bool {
            AskBackReview.gate(wordCount: AskBackReview.wordCount((0..<n).map { "w\($0)" }.joined(separator: " ")),
                               level: level, provider: p, enabled: enabled)
        }
        check("take gate: 49 words no, 50 words yes for Tighten and Summarize on Claude and Codex",
              !gate(49) && gate(50) && gate(50, .tighten, .codex) && !gate(500, .cleanup) && !gate(500, .summarize, .local) && !gate(500, enabled: false))

        // answers block
        do {
            let qs = [AskBackQuestion(question: "Which day?", quote: "q", why: "w", options: ["Friday", "Monday"]),
                      AskBackQuestion(question: "Tell the client?", quote: "q2", why: "w", options: ["Yes", "No"])]
            let want = "The user already answered these questions. Follow the answers; a voice answer overrides the transcript:\n1. Q: Which day?\n   A: Monday\n2. Q: Tell the client?\n   A: (no answer: use your best reading of the text; if it is still unclear, keep both readings)"
            let ans: [AskBackAnswer?] = [AskBackAnswer(text: "Monday", how: .tap), nil]
            check("answers: the exact block format", AskBackAnswersBlock.block(questions: qs, answers: ans) == want)
            check("answers: appended after the fidelity rules, Cleanup and zero questions unchanged",
                  AskBackAnswersBlock.appending(to: "BASE\n" + CleanupFidelity.rules, level: .tighten, questions: qs, answers: ans)
                    == "BASE\n" + CleanupFidelity.rules + "\n\n" + want
                    && AskBackAnswersBlock.appending(to: "BASE", level: .cleanup, questions: qs, answers: ans) == "BASE"
                    && AskBackAnswersBlock.appending(to: "BASE", level: .summarize, questions: [], answers: []) == "BASE")
        }

        // card text and placement
        check("card: footer, progress, you-said and option lines",
              AskCardText.footer == "Tap right \u{2325} 1-4\u{00D7} \u{B7} \u{2191}\u{2193} \u{23CE} \u{B7} esc: you decide"
                && AskCardText.progress(index: 0, total: 3) == "1 of 3" && AskCardText.progress(index: 0, total: 1) == nil
                && AskCardText.youSaid("x") == "You said: \"x\""
                && AskCardText.optionLine(number: 2, text: "Monday", highlighted: true) == "\u{25B8} 2  Monday")
        do {
            let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875)]
            let size = CGSize(width: 460, height: 220)
            let f = AskCardGeometry.frame(size: size, anchor: CGPoint(x: 700, y: 400), screens: screens)
            let flip = AskCardGeometry.frame(size: size, anchor: CGPoint(x: 700, y: 800), screens: screens)
            let edge = AskCardGeometry.frame(size: size, anchor: CGPoint(x: 1435, y: 400), screens: screens)
            let dragged = AskCardGeometry.clamp(CGRect(x: -300, y: -50, width: 460, height: 220), to: screens)
            check("geometry: above the anchor, flips below, clamps at the edge and after a drag",
                  f.midX == 700 && f.minY == 424 && flip.maxY == 776 && edge.maxX == 1440 && dragged.origin == .zero)
        }

        // History on a real store in a scratch folder
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("viddydictate-askback-flow-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let h = H(); h.flow.start(); h.review([H.question(1), H.question(2)], at: 4)
            h.flow.key(.commit)                                        // answer card 1, then "quit at once"
            let store = TranscriptionHistory(directory: root, maxEntries: { 100 })
            h.history.forEach { store.apply($0, app: "TestApp") }
            let live = store.all()
            check("history: insert pending then update by id keeps one entry with the answer stored",
                  live.count == 1 && live[0].id == h.historyID && live[0].text == "" && live[0].status == "asking"
                    && live[0].askBack?.questions[0].answer == "opt1-1" && live[0].askBack?.questions[0].how == "arrows"
                    && live[0].askBack?.reviewMs == 4000)
            let relaunched = TranscriptionHistory(directory: root, maxEntries: { 100 }).all()
            check("history: answer a card, quit, relaunch: the answer is there and it reads unanswered at quit",
                  relaunched.count == 1 && relaunched[0].status == "unanswered at quit"
                    && relaunched[0].askBack?.questions[0].answer == "opt1-1")
            let done = H(); done.flow.start(); done.review([H.question(1)]); done.flow.key(.commit); done.clock.advance(to: 9); done.finishWrite()
            let store2 = TranscriptionHistory(directory: root, maxEntries: { 100 })
            done.history.forEach { store2.apply($0) }
            let failed = H(provider: .codex); failed.flow.start(); failed.review([H.question(1)]); failed.flow.key(.commit); failed.finishWrite(ok: false)
            failed.history.forEach { store2.apply($0) }
            let all = store2.all()
            check("history: statuses after a finished write and after a failed write",
                  all.first { $0.id == done.historyID }?.status == "done"
                    && all.first { $0.id == failed.historyID }?.status == "write failed")
            let ids = Set(all.map { $0.id })
            check("history: each take has exactly one entry", ids.count == all.count && all.count == 3)
        }

        // ---------------------------------------------------------------- the held-result queue (pure rules, run on the Mac)
        do {
            let a = UUID()
            var q = AskBackHeldQueue()
            _ = q.resultExpected(a)
            var out = q.flowBusy(true)
            out += q.resultReady(a, text: "held A")
            check("held queue: a ready result waits while a card, picker or one-shot is busy, with no take live", out.isEmpty && q.count == 1)
            out = q.flowBusy(false)
            check("held queue: it pastes when the busy signal drops", out == [AskBackHeldQueue.Paste(id: a, text: "held A")] && q.isEmpty)
        }
        do {
            let a = UUID(), b = UUID()
            var q = AskBackHeldQueue()
            _ = q.takeStarted()
            _ = q.resultExpected(a); _ = q.resultExpected(b)
            var out = q.resultReady(b, text: "held B")
            out += q.resultReady(a, text: "held A")
            check("held queue: nothing pastes while a take is live", out.isEmpty && q.count == 2)
            out = q.takeFinished()
            check("held queue: results paste in the order their takes were detached, one at a time",
                  out == [AskBackHeldQueue.Paste(id: a, text: "held A")] && q.count == 1)
            out = q.takeFinished()
            check("held queue: the next one pastes after the one in front has finished",
                  out == [AskBackHeldQueue.Paste(id: b, text: "held B")] && q.isEmpty)
        }
        do {
            let a = UUID(), b = UUID()
            var q = AskBackHeldQueue()
            _ = q.takeStarted()
            _ = q.resultExpected(a); _ = q.resultExpected(b)
            _ = q.resultReady(b, text: "held B")
            var out = q.resultFailed(a)
            check("held queue: a failed result pastes nothing and does not block the next while a take is live", out.isEmpty && q.count == 1)
            out = q.takeFinished()
            check("held queue: the line moves on past a failed result", out == [AskBackHeldQueue.Paste(id: b, text: "held B")] && q.isEmpty)
        }
        do {
            let a = UUID(), b = UUID()
            var q = AskBackHeldQueue()
            _ = q.takeStarted()
            _ = q.resultExpected(a); _ = q.resultExpected(b)
            _ = q.resultReady(a, text: "held A"); _ = q.resultReady(b, text: "held B")
            _ = q.deliveryOpen(true)                                    // the new take's paste is still verifying
            var out = q.takeFinished()
            check("held queue: a take that has finished does not release a result while its delivery is open", out.isEmpty && q.count == 2)
            out = q.deliveryOpen(false)
            check("held queue: the result pastes when the delivery completes", out == [AskBackHeldQueue.Paste(id: a, text: "held A")] && q.count == 1)
            _ = q.deliveryOpen(true)                                    // that paste's own verify and restore
            out = q.takeFinished()
            check("held queue: the second result waits for the first one's delivery to complete", out.isEmpty && q.count == 1)
            out = q.deliveryOpen(false)
            check("held queue: and then pastes", out == [AskBackHeldQueue.Paste(id: b, text: "held B")] && q.isEmpty)
        }
        do {
            check("held policy: a selection one-shot's latch or its copy window counts as busy, as a card or a picker does",
                  AskBackHeldPolicy.busy(pendingPick: false, abPicker: false, askCard: false, oneShotLatch: true, oneShotGrace: false)
                    && AskBackHeldPolicy.busy(pendingPick: false, abPicker: false, askCard: false, oneShotLatch: false, oneShotGrace: true)
                    && AskBackHeldPolicy.busy(pendingPick: true, abPicker: false, askCard: false, oneShotLatch: false, oneShotGrace: false)
                    && AskBackHeldPolicy.busy(pendingPick: false, abPicker: true, askCard: false, oneShotLatch: false, oneShotGrace: false)
                    && AskBackHeldPolicy.busy(pendingPick: false, abPicker: false, askCard: true, oneShotLatch: false, oneShotGrace: false)
                    && !AskBackHeldPolicy.busy(pendingPick: false, abPicker: false, askCard: false, oneShotLatch: false, oneShotGrace: false))
            check("held policy: a suspect result or a parked delivery in front means no paste; otherwise it pastes",
                  AskBackHeldPolicy.turn(suspect: false, parked: false) == .paste
                    && AskBackHeldPolicy.turn(suspect: true, parked: false) == .skipSuspect
                    && AskBackHeldPolicy.turn(suspect: false, parked: true) == .skipParked)
            check("held policy: a clipboard-only delivery holds the clipboard only while the pasteboard is unchanged since it closed",
                  AskBackHeldPolicy.clipboardHeld(receiptClipboardOnly: true, changeCountAtClose: 7, nowChangeCount: 7)
                    && !AskBackHeldPolicy.clipboardHeld(receiptClipboardOnly: true, changeCountAtClose: 7, nowChangeCount: 8)
                    && !AskBackHeldPolicy.clipboardHeld(receiptClipboardOnly: false, changeCountAtClose: 7, nowChangeCount: 7))
            do {
                var w = AskBackOneShotWatch()
                check("one-shot watch: nothing is released while the latch is up, or when no result waited behind it",
                      !w.observe(latch: true, hasReady: true, deliveriesBegun: 3) && !w.observe(latch: true, hasReady: true, deliveriesBegun: 3)
                        && !AskBackOneShotWatch().observe(latch: false, hasReady: true, deliveriesBegun: 3))
                check("one-shot watch: the latch dropping with no delivery begun since is a cancelled one-shot (released once)",
                      w.observe(latch: false, hasReady: true, deliveriesBegun: 3) && !w.observe(latch: false, hasReady: true, deliveriesBegun: 3))
                var landed = AskBackOneShotWatch()
                _ = landed.observe(latch: true, hasReady: true, deliveriesBegun: 3)
                check("one-shot watch: a delivery begun while the latch was up is a landing, not released",
                      !landed.observe(latch: false, hasReady: true, deliveriesBegun: 4))
                var late = AskBackOneShotWatch()
                _ = late.observe(latch: true, hasReady: false, deliveriesBegun: 3)
                check("one-shot watch: a result that was not ready while the latch was up did not wait behind it",
                      !late.observe(latch: false, hasReady: true, deliveriesBegun: 3))
            }
            do {
                let x = UUID(), y = UUID(), z = UUID()
                var dq = AskBackHeldQueue()
                _ = dq.resultExpected(x); _ = dq.resultExpected(y); _ = dq.resultExpected(z)
                dq.setInputs(takeLive: false, busy: true, delivering: false)
                _ = dq.resultReady(x, text: "x"); _ = dq.resultFailed(z)
                let dropped = dq.dropReady()
                check("held queue: dropReady takes out the ready results only; one still writing keeps its slot and turn",
                      dropped == [x] && dq.hasReady == false && dq.count == 2)
                dq.setInputs(takeLive: false, busy: false, delivering: false)
                check("held queue: and the next result pastes when it is ready",
                      dq.resultReady(y, text: "y") == [AskBackHeldQueue.Paste(id: y, text: "y")])
            }
            let a = UUID()
            var q = AskBackHeldQueue()
            q.setInputs(takeLive: false, busy: true, delivering: false)
            _ = q.resultExpected(a)
            check("held queue: set inputs alone release nothing", q.resultReady(a, text: "held A").isEmpty && q.poke().isEmpty)
            q.setInputs(takeLive: false, busy: false, delivering: true)
            check("held queue: an open delivery holds it", q.poke().isEmpty)
            q.setInputs(takeLive: false, busy: false, delivering: false)
            check("held queue: with nothing in the way a poke releases it", q.poke().count == 1 && q.isEmpty)
        }

        print(check.summaryLine(prefix: "[askback-flow-selftest]"))
        return check.passed
    }
}
