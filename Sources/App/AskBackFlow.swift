import Foundation

// VDASK-3: the ask-back take flow, pure parts. Foundation-only so the Linux oracle compiles this file with
// AskBackReview.swift and CleanupFidelity.swift. The controller owns the real review runner, panel, HUD,
// provider call and paste; this file owns WHEN each of them happens: the .reviewing / .asking / .writing
// states, the card gestures (taps, hold, arrows, Return, Esc, click), the detached save-only job, the
// answers block, the History record, and card placement. Every outside effect is a hook, every timer comes
// from an injected schedule, and the clock is injected, so tests drive it with a fake clock and fake hooks.
// All entry points run on the main thread.

// MARK: - answers

/// How a question was answered. Raw values are what History stores.
enum AskBackAnswerHow: String, Codable, Equatable {
    case tap
    case arrows
    case click
    case voice                              // slice 4; stored here so the record never needs a migration
    case agentDecided = "agent decided"
    case newTake = "new take"
}

/// One answer. `text` nil means the agent decides.
struct AskBackAnswer: Equatable {
    let text: String?
    let how: AskBackAnswerHow
}

/// The block appended to the Tighten / Summarize write call's system text, after the fidelity rules.
enum AskBackAnswersBlock {
    static let header = "The user already answered these questions. Follow the answers; a voice answer overrides the transcript:\n"
    static let noAnswer = "(no answer: use your best reading of the text; if it is still unclear, keep both readings)"

    /// "" when there are no questions. `answers[i]` nil (or missing) is a question the agent decides.
    static func block(questions: [AskBackQuestion], answers: [AskBackAnswer?]) -> String {
        guard !questions.isEmpty else { return "" }
        let entries = questions.enumerated().map { i, q -> String in
            let a: String? = i < answers.count ? (answers[i]?.text) : nil
            return "\(i + 1). Q: \(q.question)\n   A: \(a ?? noAnswer)"
        }
        return header + entries.joined(separator: "\n")
    }

    /// `system` unchanged unless the level is Tighten or Summarize and there is at least one question.
    /// Same separator rule as `CleanupFidelity.appending`.
    static func appending(to system: String, level: AskBackLevel,
                          questions: [AskBackQuestion], answers: [AskBackAnswer?]) -> String {
        guard level == .tighten || level == .summarize, !questions.isEmpty else { return system }
        let sep = system.isEmpty ? "" : (system.hasSuffix("\n") ? "\n" : "\n\n")
        return system + sep + block(questions: questions, answers: answers)
    }
}

// MARK: - History record

/// The optional `askBack` record on a History entry. Optional on the entry so an old history.json still decodes.
struct AskBackRecord: Codable, Equatable {
    struct Spot: Codable, Equatable {
        var quote: String
        var issue: String
        var impact: String
    }
    struct Question: Codable, Equatable {
        var question: String
        var quote: String
        var why: String
        var options: [String]
        var answer: String?     // nil until answered, and nil when the agent decided
        var how: String?        // AskBackAnswerHow.rawValue, nil until answered
    }

    var provider: String        // review provider
    var reviewModel: String
    var tier: String
    var reviewMs: Int?
    var writeProvider: String?
    var writeModel: String?
    var writeMs: Int?
    var spots: [Spot]
    var questions: [Question]
}

/// The status strings History stores for an ask-back take.
enum AskBackHistoryStatus {
    static let asking = "asking"
    static let writing = "writing"
    static let done = "done"
    static let writeFailed = "write failed"
    static let canceled = "canceled"
    static let unansweredAtQuit = "unanswered at quit"

    /// What a stored status reads as at the next launch: a model call does not survive a quit.
    static func afterRelaunch(_ stored: String?) -> String? {
        stored == asking || stored == writing ? unansweredAtQuit : stored
    }
}

struct AskBackHistoryUpdate: Equatable {
    let id: UUID
    let record: AskBackRecord
    let status: String
    /// nil leaves the entry's text alone (the normal `record` call at paste time fills it in).
    let delivered: String?
    let raw: String?
    let levelRaw: Int?
}

enum AskBackHistoryEvent: Equatable {
    case insertPending(id: UUID, transcript: String, record: AskBackRecord)
    case update(AskBackHistoryUpdate)
}

// MARK: - card text and keys

struct AskCardModel: Equatable {
    let cardID: UUID
    let index: Int          // 0-based
    let total: Int
    let question: AskBackQuestion
    var highlighted: Int
}

enum AskCardText {
    static let footer = "Tap right \u{2325} 1-4\u{00D7} \u{B7} \u{2191}\u{2193} \u{23CE} \u{B7} esc: you decide"
    static let readingCue = "Reading your take\u{2026}"

    /// "1 of 3" for a multi-question review, nil for a single question.
    static func progress(index: Int, total: Int) -> String? {
        total > 1 ? "\(index + 1) of \(total)" : nil
    }
    static func youSaid(_ quote: String) -> String { "You said: \"\(quote)\"" }
    static func optionLine(number: Int, text: String, highlighted: Bool) -> String {
        (highlighted ? "\u{25B8} " : "  ") + "\(number)  " + text
    }
}

enum AskBackKeyAction: Equatable {
    case up, down, commit, esc, optionEsc, skipReview
}

enum AskBackKeyRouter {
    static let upArrow: Int64 = 126
    static let downArrow: Int64 = 125
    static let returnKey: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let escape: Int64 = 53

    /// nil means the key is NOT swallowed. With no card up and no review running, nothing is ever swallowed.
    /// While a review runs only plain Esc is taken (it skips the review); Option+Esc falls through to the
    /// take's own cancel.
    static func route(keyCode: Int64, optionHeld: Bool, cardUp: Bool, reviewing: Bool) -> AskBackKeyAction? {
        if cardUp {
            switch keyCode {
            case upArrow: return .up
            case downArrow: return .down
            case returnKey, keypadEnter: return .commit
            case escape: return optionHeld ? .optionEsc : .esc
            default: return nil
            }
        }
        if reviewing, keyCode == escape, !optionHeld { return .skipReview }
        return nil
    }
}

// MARK: - card placement

enum AskCardGeometry {
    static let gap: CGFloat = 24

    /// Keep `frame` fully inside the visible frame of the screen it overlaps most (the first when none does).
    static func clamp(_ frame: CGRect, to screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        let screen = screens.max { overlap($0, frame) < overlap($1, frame) } ?? screens[0]
        let target = overlap(screen, frame) > 0 ? screen : screens[0]
        var out = frame
        out.origin.x = min(max(out.origin.x, target.minX), max(target.minX, target.maxX - out.width))
        out.origin.y = min(max(out.origin.y, target.minY), max(target.minY, target.maxY - out.height))
        return out
    }

    /// The card opens above `anchor` (the take's paste target, or the pointer when there was none), centered
    /// on it, flips below when there is no room above, and is clamped on screen.
    static func frame(size: CGSize, anchor: CGPoint, screens: [CGRect]) -> CGRect {
        let home = screens.first { $0.contains(anchor) } ?? screens.first
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y + gap)
        if let home = home, origin.y + size.height > home.maxY {
            origin.y = anchor.y - gap - size.height
        }
        return clamp(CGRect(origin: origin, size: size), to: screens)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}

// MARK: - detached save-only job

/// An immutable copy of an old take, handed off when a new take starts while its card is up. It runs the write
/// with "agent decides" for every open question and writes only a History update.
struct AskBackDetachedJob: Equatable {
    let historyID: UUID
    let transcript: String
    let level: AskBackLevel
    let levelRaw: Int
    let questions: [AskBackQuestion]
    let answers: [AskBackAnswer?]       // nil = open question, written as agent-decides
    let record: AskBackRecord           // open questions already marked "new take"
    let writeProvider: String
    let writeModel: String
    let generation: Int
    let source: AskBackSource

    /// A dictation take's detached result is held and pastes afterwards (`AskBackHeldQueue`); an Option+P
    /// (selection) result stays in History only, because pasting over a selection later would replace text the
    /// user has moved on from.
    var holdsResult: Bool { source == .dictation }

    var answersBlock: String { AskBackAnswersBlock.block(questions: questions, answers: answers) }

    /// The one History update when the write ends. A failed write keeps the transcript as the entry text so
    /// nothing is lost, and says "write failed".
    func completion(result: String?, writeMs: Int) -> AskBackHistoryUpdate {
        var r = record
        r.writeProvider = writeProvider
        r.writeModel = writeModel
        r.writeMs = writeMs
        let text = result?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = text, !text.isEmpty {
            return AskBackHistoryUpdate(id: historyID, record: r, status: AskBackHistoryStatus.done,
                                        delivered: text, raw: transcript, levelRaw: levelRaw)
        }
        return AskBackHistoryUpdate(id: historyID, record: r, status: AskBackHistoryStatus.writeFailed,
                                    delivered: transcript, raw: transcript, levelRaw: nil)
    }
}

enum AskBackDetached {
    /// Runs the write and applies exactly one History update. Never pastes, never touches controller state,
    /// the HUD, the paste target, audio or any modal: its only outputs are the two closures it is handed.
    /// `completed` (optional) is told once, after the History update is applied, the job's id and the text to
    /// paste (nil when the write failed).
    static func run(_ job: AskBackDetachedJob,
                    now: @escaping () -> TimeInterval,
                    write: (_ answersBlock: String, _ done: @escaping (String?) -> Void) -> Void,
                    history: @escaping (AskBackHistoryEvent) -> Void,
                    completed: ((UUID, String?) -> Void)? = nil) {
        let started = now()
        var finished = false
        write(job.answersBlock) { result in
            guard !finished else { return }
            finished = true
            let update = job.completion(result: result, writeMs: Int((now() - started) * 1000))
            history(.update(update))
            completed?(job.historyID, update.status == AskBackHistoryStatus.done ? update.delivered : nil)
        }
    }
}

// MARK: - the flow

struct AskBackWriteSpec: Equatable {
    let writeID: UUID
    let questions: [AskBackQuestion]
    let answers: [AskBackAnswer?]
}

final class AskBackFlow {
    /// `parked`: a hold started on a card (the card is closed and the new take is recording) but the old take
    /// still waits. The release of that press detaches it; Esc while it is still down resumes it as agent-decides.
    enum Phase: Equatable { case notStarted, reviewing, asking, writing, finished, cancelled, detached, parked }

    struct Context {
        let historyID: UUID
        let transcript: String
        let level: AskBackLevel
        let levelRaw: Int
        let tier: AskBackTier
        let provider: AskBackProvider
        let writeModel: String
        let generation: Int
        var source: AskBackSource = .dictation
    }

    typealias Schedule = AskBackReviewRunner.Schedule

    /// Everything the flow does to the outside world.
    struct Hooks {
        var phaseChanged: (Phase) -> Void
        var readingCue: (Bool) -> Void
        var startReview: (UUID) -> Void
        var skipReview: (UUID) -> Void
        var showCard: (AskCardModel) -> Void
        var highlight: (UUID, Int) -> Void
        var closeCard: (UUID) -> Void
        var startWrite: (AskBackWriteSpec) -> Void
        var history: (AskBackHistoryEvent) -> Void
        var saveDetached: (AskBackDetachedJob) -> Void
        var startNewTake: () -> Void
    }

    static let holdThreshold: TimeInterval = 0.300
    static let tapWindow: TimeInterval = 0.400

    private let context: Context
    private let schedule: Schedule
    private let now: () -> TimeInterval
    private let newID: () -> UUID
    private let hooks: Hooks

    private(set) var phase: Phase = .notStarted { didSet { if phase != oldValue { hooks.phaseChanged(phase) } } }
    private(set) var reviewID: UUID?
    private(set) var cardID: UUID?
    private(set) var writeID: UUID?
    private(set) var highlighted = 0
    private(set) var cardIndex = 0
    private(set) var questions: [AskBackQuestion] = []
    private(set) var answers: [AskBackAnswer?] = []
    private(set) var record: AskBackRecord?
    private(set) var writeCount = 0

    private var reviewStartedAt = 0.0
    private var writeStartedAt = 0.0

    // gesture state, valid while a card is up
    private var taps = 0
    private var pressActive = false
    private var consumeRelease = false
    private var holdCancel: (() -> Void)?
    private var tapCancel: (() -> Void)?
    private var parkedCardID: UUID?

    init(context: Context, schedule: @escaping Schedule, now: @escaping () -> TimeInterval,
         newID: @escaping () -> UUID = { UUID() }, hooks: Hooks) {
        self.context = context
        self.schedule = schedule
        self.now = now
        self.newID = newID
        self.hooks = hooks
    }

    var cardUp: Bool { phase == .asking }
    var isReviewing: Bool { phase == .reviewing }
    /// True while the flow still owns the take (it has not pasted, been cancelled or been handed off).
    var isLive: Bool { phase == .reviewing || phase == .asking || phase == .writing }

    // MARK: review

    func start() {
        guard phase == .notStarted else { return }
        let id = newID()
        reviewID = id
        reviewStartedAt = now()
        phase = .reviewing
        hooks.readingCue(true)
        hooks.startReview(id)
    }

    /// The review's one outcome (the runner delivers one per review id). Anything after a skip, a timeout, a
    /// cancel or for a different review id is dropped.
    func reviewOutcome(_ id: UUID, _ outcome: AskBackOutcome) {
        guard phase == .reviewing, id == reviewID else { return }
        reviewID = nil
        hooks.readingCue(false)
        guard case .result(let result) = outcome else {
            beginWrite()      // skipped, timed out or failed: write with no questions and no record
            return
        }
        questions = result.questions
        answers = Array(repeating: nil, count: questions.count)
        let ms = Int((now() - reviewStartedAt) * 1000)
        let review = AskBackReview.model(for: context.provider)
        let rec = AskBackRecord(
            provider: context.provider.rawValue, reviewModel: review?.modelID ?? "", tier: context.tier.rawValue,
            reviewMs: ms, writeProvider: nil, writeModel: nil, writeMs: nil,
            spots: result.spots.map { .init(quote: $0.quote, issue: $0.issue, impact: $0.impact) },
            questions: result.questions.map {
                .init(question: $0.question, quote: $0.quote, why: $0.why, options: $0.options, answer: nil, how: nil)
            })
        record = rec
        hooks.history(.insertPending(id: context.historyID, transcript: context.transcript, record: rec))
        if questions.isEmpty { beginWrite() } else { showCard(0) }
    }

    /// Plain Esc while the review runs: write now with no questions; the late review answer is dropped.
    func skipReview() {
        guard phase == .reviewing, let id = reviewID else { return }
        reviewID = nil
        hooks.skipReview(id)
        hooks.readingCue(false)
        beginWrite()
    }

    /// Option+Esc while the review runs or the write runs (the controller's cancel of the whole take).
    func cancel() {
        guard isLive else { return }
        let was = phase
        cancelTimers()
        if was == .reviewing, let id = reviewID { hooks.skipReview(id) }
        reviewID = nil
        writeID = nil
        if was == .asking, let id = cardID { hooks.closeCard(id) }
        cardID = nil
        if was == .reviewing { hooks.readingCue(false) }
        phase = .cancelled
        if record != nil { pushUpdate(status: AskBackHistoryStatus.canceled) }
    }

    // MARK: write

    private func beginWrite() {
        let id = newID()
        writeID = id
        writeStartedAt = now()
        phase = .writing
        if record != nil { pushUpdate(status: AskBackHistoryStatus.writing) }
        hooks.startWrite(AskBackWriteSpec(writeID: id, questions: questions, answers: answers))
    }

    /// The write call finished. Runs `deliver` at most once for the take, and only while the take is still
    /// writing under this write id; a cancelled, detached or repeated result does nothing.
    func writeFinished(_ id: UUID, ok: Bool, deliver: () -> Void) {
        guard phase == .writing, id == writeID else { return }
        writeID = nil
        phase = .finished
        writeCount += 1
        if var rec = record {
            rec.writeProvider = context.provider.rawValue
            rec.writeModel = context.writeModel
            rec.writeMs = Int((now() - writeStartedAt) * 1000)
            record = rec
            pushUpdate(status: ok ? AskBackHistoryStatus.done : AskBackHistoryStatus.writeFailed)
        }
        deliver()
    }

    // MARK: cards

    private func showCard(_ index: Int) {
        cancelTimers()
        cardIndex = index
        highlighted = 0
        taps = 0
        let id = newID()
        cardID = id
        phase = .asking
        hooks.showCard(AskCardModel(cardID: id, index: index, total: questions.count,
                                    question: questions[index], highlighted: 0))
    }

    /// Records the answer for the current card, closes it and shows the next card or starts the write.
    /// `option` nil means the agent decides.
    private func decide(option: Int?, how: AskBackAnswerHow) {
        guard phase == .asking, let id = cardID else { return }
        let q = questions[cardIndex]
        let text = option.flatMap { q.options.indices.contains($0) ? q.options[$0] : nil }
        let answer = AskBackAnswer(text: text, how: text == nil ? .agentDecided : how)
        answers[cardIndex] = answer
        record?.questions[cardIndex].answer = answer.text
        record?.questions[cardIndex].how = answer.how.rawValue
        cancelTimers()
        cardID = nil
        if pressActive { consumeRelease = true }   // the press in progress already did its job
        hooks.closeCard(id)
        if record != nil { pushUpdate(status: AskBackHistoryStatus.asking) }
        if cardIndex + 1 < questions.count { showCard(cardIndex + 1) } else { beginWrite() }
    }

    // MARK: keys

    func key(_ action: AskBackKeyAction) {
        switch action {
        case .up: moveHighlight(-1)
        case .down: moveHighlight(1)
        case .commit:
            guard phase == .asking else { return }
            cancelTaps()
            decide(option: highlighted, how: .arrows)
        case .esc, .optionEsc:
            guard phase == .asking else { return }
            decide(option: nil, how: .agentDecided)
        case .skipReview:
            skipReview()
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard phase == .asking, let id = cardID else { return }
        cancelTaps()
        let count = questions[cardIndex].options.count
        let next = min(max(highlighted + delta, 0), count - 1)
        guard next != highlighted else { return }
        highlighted = next
        hooks.highlight(id, next)
    }

    /// A click on option `index` of card `card`. A stale card id does nothing.
    func click(cardID card: UUID, option index: Int) {
        guard phase == .asking, card == cardID else { return }
        guard questions[cardIndex].options.indices.contains(index) else { return }
        cancelTaps()
        decide(option: index, how: .click)
    }

    // MARK: right Option while a card is up

    /// Returns false when no card is up, so the caller handles the press exactly as it does today.
    @discardableResult
    func optionDown() -> Bool {
        guard phase == .asking, let id = cardID else { return false }
        tapCancel?(); tapCancel = nil      // a new press suspends the pending tap deadline; the count stays
        pressActive = true
        consumeRelease = false
        holdCancel?()
        holdCancel = schedule(Self.holdThreshold) { [weak self] in self?.holdFired(id) }
        return true
    }

    @discardableResult
    func optionUp() -> Bool {
        guard phase == .asking, let id = cardID else { return false }
        guard pressActive else { return true }
        pressActive = false
        if consumeRelease { consumeRelease = false; return true }
        holdCancel?(); holdCancel = nil
        taps += 1
        tapCancel?()
        tapCancel = schedule(Self.tapWindow) { [weak self] in self?.tapsSettled(id) }
        return true
    }

    private func tapsSettled(_ id: UUID) {
        guard phase == .asking, id == cardID, taps > 0 else { return }
        let count = questions[cardIndex].options.count
        let pick = min(taps, count) - 1        // more taps than options picks the last one
        taps = 0
        tapCancel = nil
        decide(option: pick, how: .tap)
    }

    private func holdFired(_ id: UUID) {
        guard phase == .asking, id == cardID, pressActive else { return }
        holdCancel = nil
        park()
    }

    /// A hold while a card is up: the card closes and a new take starts, but the old take WAITS (parked) until
    /// the press that started the hold ends: `parkedRelease` (no Esc) detaches it; `parkedEsc` resumes it.
    private func park() {
        guard phase == .asking, let id = cardID else { return }
        cancelTimers()
        pressActive = false
        consumeRelease = false
        parkedCardID = id
        cardID = nil
        phase = .parked
        hooks.closeCard(id)
        hooks.startNewTake()
    }

    /// The press that started the hold was released with no Esc: the old take becomes the detached save-only
    /// job, built from an immutable copy. The new take (already recording) goes on as today.
    func parkedRelease() {
        guard phase == .parked else { return }
        parkedCardID = nil
        var rec = record ?? AskBackRecord(provider: context.provider.rawValue, reviewModel: "",
                                          tier: context.tier.rawValue, reviewMs: nil, writeProvider: nil,
                                          writeModel: nil, writeMs: nil, spots: [], questions: [])
        for i in questions.indices where answers[i] == nil {
            rec.questions[i].answer = nil
            rec.questions[i].how = AskBackAnswerHow.newTake.rawValue
        }
        let job = AskBackDetachedJob(
            historyID: context.historyID, transcript: context.transcript, level: context.level,
            levelRaw: context.levelRaw, questions: questions, answers: answers, record: rec,
            writeProvider: context.provider.rawValue, writeModel: context.writeModel,
            generation: context.generation, source: context.source)
        phase = .detached
        hooks.saveDetached(job)
    }

    /// Esc while that same press is still down (the chord): the caller has discarded the new take silently; the
    /// old take goes on as agent-decides for the card that was open (same as Esc on the card), and the next card,
    /// the write and the paste follow as usual. Returns false when the flow is not parked.
    @discardableResult
    func parkedEsc() -> Bool {
        guard phase == .parked, let id = parkedCardID else { return false }
        parkedCardID = nil
        cardID = id
        phase = .asking
        decide(option: nil, how: .agentDecided)
        return true
    }

    // MARK: timers

    private func cancelTaps() {
        taps = 0
        tapCancel?(); tapCancel = nil
    }

    private func cancelTimers() {
        cancelTaps()
        holdCancel?(); holdCancel = nil
    }

    private func pushUpdate(status: String) {
        guard let rec = record else { return }
        hooks.history(.update(AskBackHistoryUpdate(id: context.historyID, record: rec, status: status,
                                                   delivered: nil, raw: nil, levelRaw: nil)))
    }
}

// MARK: - held results (an earlier take pastes afterwards)

/// The rules for the detached old take's result. It is held until the take in front of it has finished, then
/// pastes through the normal delivery path; results queue in the order their takes were detached, one paste at
/// a time. Pure: the controller feeds it events and performs the pastes it returns.
///
/// - `resultExpected(id)`: a take was detached; its slot in the line is reserved at once.
/// - `resultReady(id, text)` / `resultFailed(id)`: its write ended. A failed write pastes nothing and the line
///   moves on.
/// - `takeStarted` / `takeFinished`: a take (or the paste of the result in front) began / ended.
/// - `flowBusy(Bool)`: a card or an A/B picker is up.
/// Nothing is persisted: a result that has not pasted when the app quits is not pasted on relaunch.
struct AskBackHeldQueue {
    struct Paste: Equatable { let id: UUID; let text: String }

    private enum Slot { case expected, ready(String), failed }
    private var slots: [(id: UUID, slot: Slot)] = []
    private var takeLive = false
    private var busy = false

    var isEmpty: Bool { slots.isEmpty }
    var count: Int { slots.count }

    mutating func resultExpected(_ id: UUID) -> [Paste] {
        guard !slots.contains(where: { $0.id == id }) else { return [] }
        slots.append((id, .expected))
        return drain()
    }

    mutating func resultReady(_ id: UUID, text: String) -> [Paste] {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return [] }
        slots[i].slot = .ready(text)
        return drain()
    }

    mutating func resultFailed(_ id: UUID) -> [Paste] {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return [] }
        slots[i].slot = .failed
        return drain()
    }

    mutating func takeStarted() -> [Paste] { takeLive = true; return [] }

    mutating func takeFinished() -> [Paste] { takeLive = false; return drain() }

    mutating func flowBusy(_ on: Bool) -> [Paste] { busy = on; return drain() }

    /// Pastes the head of the line when it is ready and nothing is live or busy. A paste counts as a take in
    /// front of the next result: the caller reports `takeFinished` once it has settled.
    private mutating func drain() -> [Paste] {
        while let head = slots.first {
            switch head.slot {
            case .failed: slots.removeFirst()
            case .expected: return []
            case .ready(let text):
                guard !takeLive, !busy else { return [] }
                slots.removeFirst()
                takeLive = true
                return [Paste(id: head.id, text: text)]
            }
        }
        return []
    }
}
