import Foundation
import CryptoKit

// VDASK-2 self-test: review prompt pins, parser, caps, gate, runner identity, call seam and settings.
// Synthetic text only. Mirrors the Linux oracle's rows (b2-out/oracle) plus the app-type rows.

private final class AskBackFakeClock {
    var now = 0.0
    var timers: [(id: Int, due: Double, fire: () -> Void)] = []
    var cancelled = 0
    var nextID = 0
    func schedule(_ after: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append((id, now + after, fire))
        return { [self] in
            if timers.contains(where: { $0.id == id }) { cancelled += 1 }
            timers.removeAll { $0.id == id }
        }
    }
    func advance(_ s: Double) {
        now += s
        let due = timers.filter { $0.due <= now }
        timers.removeAll { $0.due <= now }
        due.forEach { $0.fire() }
    }
}
private final class AskBackFakeProvider {
    var calls: [(system: String, input: String, done: (AskBackProviderReply) -> Void)] = []
    func call(_ s: String, _ i: String, _ done: @escaping (AskBackProviderReply) -> Void) { calls.append((s, i, done)) }
}

enum AskBackReviewSelfTest {
    private static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func run() -> Bool {
        print("--- ask-back review: prompt, parser, gate, runner, seam, settings ---")
        Settings.registerDefaults()
        let reporter = SelfTestReporter()
        let check = reporter
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let before = defaults.persistentDomain(forName: domain)
        defer {
            if let before = before { defaults.setPersistentDomain(before, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }

        // The 8 prompt pins: sha256 of system + blank line + input for the fixed sample text.
        let sample = "SAMPLE TEXT, with \"quotes\" and it's here."
        let pins: [(AskBackTier, AskBackLevel, AskBackSource, String)] = [
            (.careful, .tighten, .dictation, "cf979d919fb02690c234f108465a5e161d2e123dd88661af9d4c491586eb9444"),
            (.careful, .tighten, .selection, "4c203fd4755cb4c371a368e4fd9c7981ea6d6635bab30c35ccee6562fe866cd8"),
            (.careful, .summarize, .dictation, "4af9ad1e289b9e0154ad424898c82bc0947195101616cef1474dd2fb615e895e"),
            (.careful, .summarize, .selection, "cba05378c62a3036a14d326f946ece49aba8fc449c68bea78bd43444a8c90afb"),
            (.fast, .tighten, .dictation, "4f2d101920cd89d1c50e9f0ef8340059503b3f661b70fd09bfdbf157e3419cde"),
            (.fast, .tighten, .selection, "0c87fe497172caf4ec4e6c072405cde3a744ee569b0fb9472e2845da8fa5af2c"),
            (.fast, .summarize, .dictation, "bc7ebc4aba66b60a2b5f53d1f226445f66016849c2aac5bf2ff3df2956acd5e4"),
            (.fast, .summarize, .selection, "80d4a56b53d2261dcc06b0a0cab1c8269f7a4e3c7e755ae99f2f052e4ccc427d"),
        ]
        for (tier, level, source, want) in pins {
            let p = AskBackReview.reviewPrompt(text: sample, level: level, tier: tier, source: source)
            check("prompt-hash \(tier.rawValue) \(level.rawValue) \(source.rawValue)",
                  sha(p.system + "\n\n" + p.input) == want)
        }

// MARK: parse
let T = "We should ship on Friday. Actually let\u{2019}s ship on Monday instead. Don't tell the client yet, it's risky. The Blue Folder goes to Ana."
func q(_ question: String, _ quote: String, _ options: [String]) -> String {
    let opts = options.map { "\"\($0)\"" }.joined(separator: ",")
    return "{\"question\":\"\(question)\",\"quote\":\"\(quote)\",\"why\":\"w\",\"options\":[\(opts)]}"
}
func reply(_ qs: [String], spots: String = "[{\"quote\":\"ship on Friday\",\"issue\":\"i\",\"impact\":\"high\"}]") -> String {
    "{\"spots\":\(spots),\"questions\":[\(qs.joined(separator: ","))]}"
}
let good = q("Which day?", "ship on Friday", ["Friday", "Monday"])
let valid = AskBackReview.parse(reply([good]), transcript: T, level: .summarize)
check("parse: valid JSON", valid?.questions.count == 1 && valid?.questions[0].options == ["Friday", "Monday"]
    && valid?.questions[0].question == "Which day?" && valid?.questions[0].why == "w")
check("parse: spots are kept as given",
    valid?.spots == [AskBackSpot(quote: "ship on Friday", issue: "i", impact: "high")])
let fenced = AskBackReview.parse("```json\n" + reply([good]) + "\n```", transcript: T, level: .summarize)
check("parse: fenced JSON", fenced == valid)
let around = AskBackReview.parse("Sure, here you go:\n" + reply([good]) + "\nHope that helps {really}.",
                                 transcript: T, level: .summarize)
check("parse: JSON with text around it", around == valid)
let fenceFirst = AskBackReview.parse("A {sketch} first:\n```json\n" + reply([good]) + "\n```", transcript: T, level: .summarize)
check("parse: a fenced block wins over stray braces before it", fenceFirst == valid)
check("parse: invalid JSON is nil", AskBackReview.parse("not json at all", transcript: T, level: .summarize) == nil)
check("parse: unbalanced object is nil", AskBackReview.parse("{\"spots\":[", transcript: T, level: .summarize) == nil)
check("parse: broken object is nil", AskBackReview.parse("{spots: nope}", transcript: T, level: .summarize) == nil)
check("parse: a JSON array is nil", AskBackReview.parse("[1,2]", transcript: T, level: .summarize) == nil)
let noQ = AskBackReview.parse("{\"spots\":[]}", transcript: T, level: .summarize)
check("parse: missing questions key gives empty questions, not nil", noQ != nil && noQ?.questions.isEmpty == true)
let nonVerbatim = AskBackReview.parse(reply([q("Q?", "ship on Tuesday", ["a", "b"])]), transcript: T, level: .summarize)
check("parse: a non-verbatim quote is dropped", nonVerbatim?.questions.isEmpty == true)
let curly = AskBackReview.parse(reply([q("Q?", "Let's SHIP   on Monday", ["a", "b"])]), transcript: T, level: .summarize)
check("parse: curly vs straight quote, case and spacing are ignored", curly?.questions.count == 1)
let curly2 = AskBackReview.parse(reply([q("Q?", "Don\u{2019}t tell the client", ["a", "b"])]), transcript: T, level: .summarize)
check("parse: curly quote in the model's quote matches a straight one in the transcript", curly2?.questions.count == 1)
let oneOpt = AskBackReview.parse(reply([q("Q?", "ship on Friday", ["only"])]), transcript: T, level: .summarize)
check("parse: a 1-option question is dropped", oneOpt?.questions.isEmpty == true)
let five = AskBackReview.parse(reply([q("Q?", "ship on Friday", ["a", "b", "c", "d", "e"])]), transcript: T, level: .summarize)
check("parse: 5 options are trimmed to 4", five?.questions.first?.options == ["a", "b", "c", "d"])
let dup = AskBackReview.parse(reply([q("Q1?", "ship on Friday", ["a", "b"]), q("Q2?", "Ship on  friday", ["c", "d"])]),
                              transcript: T, level: .summarize)
check("parse: a duplicate quote is dropped", dup?.questions.map { $0.question } == ["Q1?"])
let four = [q("A?", "ship on Friday", ["a", "b"]), q("B?", "ship on Monday", ["a", "b"]),
            q("C?", "tell the client", ["a", "b"]), q("D?", "Blue Folder", ["a", "b"])]
check("cap: 4 questions -> 3 for Summarize",
    AskBackReview.parse(reply(four), transcript: T, level: .summarize)?.questions.map { $0.question } == ["A?", "B?", "C?"])
check("cap: 2 questions -> 1 for Tighten",
    AskBackReview.parse(reply(Array(four.prefix(2))), transcript: T, level: .tighten)?.questions.map { $0.question } == ["A?"])
check("cap: Cleanup never asks",
    AskBackReview.parse(reply(four), transcript: T, level: .cleanup)?.questions.isEmpty == true)
check("cap: dropped questions do not use up the cap",
    AskBackReview.parse(reply([q("X?", "never said", ["a", "b"])] + Array(four.prefix(3))),
                        transcript: T, level: .summarize)?.questions.count == 3)

// MARK: judge round 1: S3 adapter-normalized replies, S5 word boundaries, S6 escapes and blank question
func reply2(_ qs: [String]) -> String { "{\"spots\":[],\"questions\":[" + qs.joined(separator: ",") + "]}" }
let TD = "We ship Friday\u{2014}no, Monday. Earlier\u{2026} I think we wait. She said \u{201C}keep the blue one\u{201D} and left."
// What the adapters hand parse: every reply already went through asciiPunctuationNormalized.
let emRep = reply2([q("Which?", AskBackReview.asciiPunctuationNormalized("We ship Friday\u{2014}no, Monday"), ["a", "b"])])
let emRes = AskBackReview.parse(emRep, transcript: TD, level: .summarize)
check("S3 parse: an em dash quote after adapter normalization keeps the question, quote as spoken",
    emRes?.questions.count == 1 && emRes?.questions.first?.quote == "We ship Friday\u{2014}no, Monday")
let elRes = AskBackReview.parse(reply2([q("Which?", AskBackReview.asciiPunctuationNormalized("Earlier\u{2026} I think"), ["a", "b"])]),
                                transcript: TD, level: .summarize)
check("S3 parse: an ellipsis quote after adapter normalization keeps the question",
    elRes?.questions.count == 1 && elRes?.questions.first?.quote == "Earlier\u{2026} I think"
    && AskBackReview.parse(reply2([q("Which?", "Earlier\u{2026} I think", ["a", "b"])]), transcript: TD, level: .summarize)?.questions.count == 1)
let curlyJSON = AskBackReview.asciiPunctuationNormalized(
    "{\"spots\":[{\"quote\":\"She said \u{201C}keep the blue one\u{201D}\",\"issue\":\"i\",\"impact\":\"high\"}],\"questions\":[{\"question\":\"Which one?\",\"quote\":\"She said \u{201C}keep the blue one\u{201D} and left\",\"why\":\"w\",\"options\":[\"Blue\",\"Other\"]}]}")
let curlyRes = AskBackReview.parse(curlyJSON, transcript: TD, level: .summarize)
check("S3 parse: curly double quotes inside a string become bare quotes and the review survives",
    curlyRes != nil && curlyRes?.questions.count == 1 && curlyRes?.questions.first?.options == ["Blue", "Other"]
    && curlyRes?.questions.first?.quote == "She said \u{201C}keep the blue one\u{201D} and left"
    && curlyRes?.spots.count == 1)
let fenceCurly = AskBackReview.parse("```json\n" + curlyJSON + "\n```", transcript: TD, level: .summarize)
check("S3 parse: a fenced reply with bare quotes inside a string survives", fenceCurly == curlyRes)
let TW = "I think we should wait until the launch."
let frag = AskBackReview.parse(reply2([q("Q?", "ink we sh", ["a", "b"])]), transcript: TW, level: .summarize)
check("S5 parse: a mid-word fragment is dropped", frag?.questions.isEmpty == true
    && AskBackReview.parse(reply2([q("Q?", "hink we should", ["a", "b"])]), transcript: TW, level: .summarize)?.questions.isEmpty == true)
let half = AskBackReview.parse(reply2([q("Q?", "think we should wai", ["a", "b"])]), transcript: TW, level: .summarize)
check("S5 parse: a quote cut inside its last word is dropped", half?.questions.isEmpty == true)
let recase = AskBackReview.parse(reply2([q("Q?", "I THINK   we", ["a", "b"])]), transcript: TW, level: .summarize)
check("S5 parse: a recased quote is shown as the transcript has it", recase?.questions.first?.quote == "I think we")
let whole = AskBackReview.parse(reply2([q("Q?", "wait until the", ["a", "b"])]), transcript: TW, level: .summarize)
check("S5 parse: a whole-word span in the middle is kept", whole?.questions.first?.quote == "wait until the")
let TB = "He said it was {done} and \"ready\" now, then left."
let escRep = "{\"spots\":[],\"questions\":[{\"question\":\"Is it done?\",\"quote\":\"it was {done} and \\\"ready\\\" now\",\"why\":\"w\",\"options\":[\"Yes\",\"No\"]}]}"
let escRes = AskBackReview.parse(escRep, transcript: TB, level: .summarize)
check("S6 parse: escaped quotes and braces inside a string parse and the quote is kept",
    escRes?.questions.count == 1 && escRes?.questions.first?.quote == "it was {done} and \"ready\" now"
    && AskBackReview.parse("{\"questions\":[{\"question\":\"Set?\",\"quote\":\"the \\\"{done} flag\",\"options\":[\"Yes\",\"No\"]}]}",
                           transcript: "Mark the \"{done} flag as set.", level: .summarize)?.questions.count == 1)
let blankQ = AskBackReview.parse(reply2([q("   ", "ship on Friday", ["a", "b"]), q("", "ship on Monday", ["a", "b"]), q("Real?", "tell the client", ["a", "b"])]),
                                 transcript: T, level: .summarize)
check("S6 parse: a blank or whitespace question is dropped", blankQ?.questions.map { $0.question } == ["Real?"])

check("S3 fold: AskBackReview.asciiPunctuationNormalized agrees with CleanupClient's on every typographic glyph",
    ["We ship Friday\u{2014}no", "earlier\u{2026} I think", "\u{201C}keep\u{201D} \u{201E}x\u{201F}", "it\u{2019}s \u{2018}a\u{2019} \u{201A}b",
     "a\u{2013}b\u{2012}c\u{2015}d", "x\u{00A0}\u{00A0}y   z", "bullet \u{2022} `code`", "plain text", ""].allSatisfy {
        AskBackReview.asciiPunctuationNormalized($0) == CleanupClient.asciiPunctuationNormalized($0) })

// MARK: gate
var gateOK = true
for words in [24, 25, 49, 50] {
    for level in AskBackLevel.allCases {
        for provider in AskBackProvider.allCases {
            let want = words >= 50 && level != .cleanup && provider != .local
            if AskBackReview.gate(wordCount: words, level: level, provider: provider, enabled: true) != want { gateOK = false }
            if AskBackReview.gate(wordCount: words, level: level, provider: provider, enabled: false) { gateOK = false }
        }
    }
}
check("gate: table at 24, 25, 49, 50 words x level x provider, enabled and disabled", gateOK)
check("gate: 50 words passes for Tighten and Summarize on Claude and Codex",
    [AskBackLevel.tighten, .summarize].allSatisfy { l in
        [AskBackProvider.claude, .codex].allSatisfy { AskBackReview.gate(wordCount: 50, level: l, provider: $0, enabled: true) } })
check("gate: 49 words fails", !AskBackReview.gate(wordCount: 49, level: .summarize, provider: .claude, enabled: true))
check("gate: local never passes", !AskBackReview.gate(wordCount: 500, level: .summarize, provider: .local, enabled: true))
check("gate: Cleanup never passes", !AskBackReview.gate(wordCount: 500, level: .cleanup, provider: .claude, enabled: true))
check("gate: disabled never passes", !AskBackReview.gate(wordCount: 500, level: .tighten, provider: .codex, enabled: false))
check("wordCount: counts like the controller's whitespace split",
    ["", "  ", "one", " a  b\tc\nd ", "x\u{00A0}y z"].allSatisfy {
        AskBackReview.wordCount($0) == $0.split(whereSeparator: { $0.isWhitespace }).count }
        && AskBackReview.wordCount(" a  b\tc\nd ") == 4)

// MARK: models
check("models: Claude sonnet-5-5, Codex gpt-6.1-sol medium, local none",
    AskBackReview.model(for: .claude) == AskBackModel(modelID: "claude-sonnet-5-5", effort: nil)
    && AskBackReview.model(for: .codex) == AskBackModel(modelID: "gpt-6.1-sol", effort: "medium")
    && AskBackReview.model(for: .local) == nil)

// MARK: fidelity (S2 follow-up)
check("fidelity: appending(to: B, routeKey: cleanupL1) == B + blank line + rules",
    CleanupFidelity.appending(to: "B", routeKey: "cleanupL1") == "B\n\n" + CleanupFidelity.rules)

// MARK: runner
func makeRunner() -> (AskBackReviewRunner, AskBackFakeClock, AskBackFakeProvider, () -> [(UUID, AskBackOutcome)]) {
    let clock = AskBackFakeClock(), prov = AskBackFakeProvider()
    var delivered: [(UUID, AskBackOutcome)] = []
    let r = AskBackReviewRunner(timeout: 90, schedule: clock.schedule, provider: prov.call,
                                deliver: { delivered.append(($0, $1)) })
    return (r, clock, prov, { delivered })
}
let goodReply = reply([good])
do {
    let (r, clock, prov, out) = makeRunner()
    let id = UUID()
    r.start(id: id, text: T, level: .summarize, tier: .careful, source: .dictation)
    check("runner: the provider gets the prompt, system and input split",
        prov.calls.count == 1 && prov.calls[0].input == "TEXT:\n<<<\n" + T + "\n>>>"
        && prov.calls[0].system.hasPrefix("You review a raw voice-dictation transcript"))
    prov.calls[0].done(.text(goodReply))
    clock.advance(200)
    prov.calls[0].done(.text(goodReply))
    check("runner: a result is delivered exactly once", out().count == 1 && out()[0].0 == id
        && out()[0].1 == .result(valid!))
    check("runner: delivering cancels the timeout timer", clock.cancelled == 1 && clock.timers.isEmpty)
}
do {
    let (r, clock, prov, out) = makeRunner()
    let id = UUID()
    r.start(id: id, text: T, level: .summarize, tier: .careful, source: .dictation)
    r.skip(id)
    prov.calls[0].done(.text(goodReply))
    clock.advance(200)
    check("runner: skip then a late result is dropped", out().count == 1 && out()[0].1 == .skipped)
}
do {
    let (r, clock, prov, out) = makeRunner()
    let id = UUID()
    r.start(id: id, text: T, level: .summarize, tier: .careful, source: .dictation)
    clock.advance(89)
    check("runner: nothing is delivered before the timeout", out().isEmpty)
    clock.advance(1)
    prov.calls[0].done(.text(goodReply))
    clock.advance(500)
    check("runner: timeout then a late result is dropped", out().count == 1 && out()[0].1 == .timedOut)
}
do {
    let (r, _, prov, out) = makeRunner()
    let a = UUID(), b = UUID()
    r.start(id: a, text: T, level: .summarize, tier: .careful, source: .dictation)
    r.start(id: b, text: T, level: .tighten, tier: .fast, source: .selection)
    r.skip(a)
    prov.calls[1].done(.text(reply(four)))
    prov.calls[0].done(.text(goodReply))
    let o = out()
    check("runner: two reviews with different ids do not cross",
        o.count == 2 && o[0].0 == a && o[0].1 == .skipped && o[1].0 == b
        && { if case .result(let res) = o[1].1 { return res.questions.count == 1 } else { return false } }())
}
do {
    let (r, _, prov, out) = makeRunner()
    r.start(id: UUID(), text: T, level: .summarize, tier: .careful, source: .dictation)
    prov.calls[0].done(.text("garbage"))
    let (r2, _, prov2, out2) = makeRunner()
    r2.start(id: UUID(), text: T, level: .summarize, tier: .careful, source: .dictation)
    prov2.calls[0].done(.failed("down"))
    let (r3, _, prov3, out3) = makeRunner()
    r3.start(id: UUID(), text: T, level: .summarize, tier: .careful, source: .dictation)
    prov3.calls[0].done(.timedOut)
    check("runner: unparseable, failed and provider-timeout replies each deliver one outcome",
        out().count == 1 && { if case .failed = out()[0].1 { return true } else { return false } }()
        && out2().first?.1 == .failed("down") && out3().first?.1 == .timedOut)
}
do {
    let (r, _, _, _) = makeRunner()
    let id = UUID()
    let first = r.start(id: id, text: T, level: .summarize, tier: .careful, source: .dictation)
    let second = r.start(id: id, text: T, level: .summarize, tier: .careful, source: .dictation)
    check("runner: reusing an id is refused", first && !second)
}

// S4: the caller drops its reference; the runner keeps itself alive until it delivers.
do {
    let clock = AskBackFakeClock(), prov = AskBackFakeProvider()
    var delivered: [AskBackOutcome] = []
    weak var weakRunner: AskBackReviewRunner?
    do {
        let r = AskBackReviewRunner(timeout: 90, schedule: clock.schedule, provider: prov.call,
                                    deliver: { delivered.append($1) })
        weakRunner = r
        r.start(id: UUID(), text: T, level: .summarize, tier: .careful, source: .dictation)
    }
    check("S4 runner: a review in flight keeps the runner alive after the caller drops it", weakRunner != nil)
    prov.calls[0].done(.text(goodReply))
    check("S4 runner: a dropped reference still gets exactly one result outcome",
        delivered.count == 1 && delivered[0] == .result(valid!))
    check("S4 runner: the runner is released once it has delivered", weakRunner == nil)
}
do {
    let clock = AskBackFakeClock(), prov = AskBackFakeProvider()
    var delivered: [AskBackOutcome] = []
    do {
        let r = AskBackReviewRunner(timeout: 90, schedule: clock.schedule, provider: prov.call,
                                    deliver: { delivered.append($1) })
        r.start(id: UUID(), text: T, level: .summarize, tier: .careful, source: .dictation)
    }
    clock.advance(90)
    prov.calls[0].done(.text(goodReply))
    check("S4 runner: a dropped reference still gets exactly one timed-out outcome", delivered == [.timedOut])
}


        // MARK: call seam (fake adapters: nothing is spawned)
        func seam(_ resolution: LLMRouteResolution) -> (claude: [TextTransformRequest], codex: [TextTransformRequest], result: CleanupClient.Result?) {
            var claudeCalls: [TextTransformRequest] = []
            var codexCalls: [TextTransformRequest] = []
            var got: CleanupClient.Result?
            TextTransformClient.complete(
                system: "SYS", input: "IN", resolution: resolution,
                claude: { req, done in claudeCalls.append(req); done(.ok("c")) },
                codex: { req, done in codexCalls.append(req); done(.ok("x")) },
                completion: { got = $0 })
            return (claudeCalls, codexCalls, got)
        }
        let viaClaude = seam(.pinned(.claude("claude-haiku-5-5", effort: "low")))
        check("seam: Claude resolution reaches the Claude adapter with the review model, not the route bundle",
              viaClaude.claude.count == 1 && viaClaude.codex.isEmpty
                && viaClaude.claude[0].bundle.modelID == "claude-sonnet-5-5"
                && viaClaude.claude[0].bundle.effort == nil
                && viaClaude.claude[0].systemPrompt == "SYS" && viaClaude.claude[0].userMessage == "IN"
                && viaClaude.claude[0].timeout == CloudCleanupClient.defaultTimeout)
        let viaCodex = seam(.pinned(.codex("gpt-6-luna", effort: "low")))
        check("seam: Codex resolution reaches the Codex adapter with gpt-6.1-sol at medium",
              viaCodex.codex.count == 1 && viaCodex.claude.isEmpty
                && viaCodex.codex[0].bundle.modelID == "gpt-6.1-sol" && viaCodex.codex[0].bundle.effort == "medium")
        let viaDegraded = seam(.degraded(.codex("gpt-6-luna", effort: "low"), from: .claude, reason: "r", upgradeOffer: nil))
        check("seam: a degraded resolution follows the provider that actually runs",
              viaDegraded.codex.count == 1 && viaDegraded.claude.isEmpty)
        let viaLocal = seam(.pinned(.local("some-local-model")))
        check("seam: a local resolution is refused without dispatching",
              viaLocal.claude.isEmpty && viaLocal.codex.isEmpty
                && { if case .unavailable? = viaLocal.result { return true } else { return false } }())
        let viaOff = seam(.off(reason: "nothing connected"))
        check("seam: an off resolution is refused without dispatching",
              viaOff.claude.isEmpty && viaOff.codex.isEmpty
                && { if case .unavailable? = viaOff.result { return true } else { return false } }())
        check("seam: provider mapping from the app enums",
              AskBackProvider(.claude) == .claude && AskBackProvider(.codex) == .codex && AskBackProvider(.local) == .local
                && AskBackLevel(.tighten) == .tighten && AskBackLevel(.summarize) == .summarize
                && AskBackLevel(.cleanup) == .cleanup)

        // S1: a review's Codex outcome never writes app-wide Codex availability.
        func settleMain() {
            if Thread.isMainThread { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }
            else { DispatchQueue.main.sync {} }
        }
        let priorCodex = Settings.modelsPower.availabilityState(for: .codex)
        Settings.modelsPower.setAvailabilityState(.available, for: .codex)
        let reviewReq = TextTransformRequest(route: .custom("askBackReview"), bundle: .codex("gpt-6.1-sol", effort: "medium"),
                                             sourceText: "IN", systemPrompt: "SYS", userMessage: "IN", timeout: 5)
        let reviewOutcomes: [CodexRuntimeOutcome] = [.unavailable("synthetic"), .disconnected,
            .processFailure(exitCode: 1, stderrBytes: 0, stderrHead: "")]
        for outcome in reviewOutcomes { _ = CodexTransformResult.resolve(outcome, request: reviewReq, updatesAvailability: false) }
        settleMain()
        check("S1 codex: a review outcome (unavailable, disconnected, process failure) leaves Codex availability unchanged",
              Settings.modelsPower.availabilityState(for: .codex) == .available)
        _ = CodexTransformResult.resolve(.unavailable("synthetic"), request: reviewReq)
        settleMain()
        check("S1 codex: the default (every existing caller) still writes availability",
              Settings.modelsPower.availabilityState(for: .codex) == .unavailable("synthetic"))
        Settings.modelsPower.setAvailabilityState(priorCodex, for: .codex)

        // S7: the seam leaves a pending cleanup Retry (and its epoch) alone.
        let retryCenter = TextTransformRetryCenter.shared
        let retryEpoch = retryCenter.beginNewRequest()
        let failedReq = TextTransformRequest(route: .promptPrep, bundle: .local("failed-local"), sourceText: "SYN",
                                             systemPrompt: "SYN", userMessage: "SYN", timeout: 5)
        let retryDescriptor = TextTransformClient.retryDescriptor(for: failedReq, after: .unavailable("x"))!
        retryCenter.capture(retryDescriptor, expectedEpoch: retryEpoch) { _, _ in }
        let pendingBefore = retryCenter.summary
        _ = seam(.pinned(.claude("claude-haiku-5-5", effort: "low")))
        _ = seam(.pinned(.codex("gpt-6-luna", effort: "low")))
        _ = seam(.pinned(.local("some-local-model")))
        check("S7 seam: complete leaves a pending cleanup retry unchanged", pendingBefore != nil
              && retryCenter.summary == pendingBefore)
        retryCenter.capture(retryDescriptor, expectedEpoch: retryEpoch) { _, _ in }
        check("S7 seam: complete leaves the retry epoch unchanged (a capture at the old epoch still lands)",
              retryCenter.summary != nil && retryCenter.summary != pendingBefore)
        retryCenter.invalidate()

        // MARK: settings
        defaults.removeObject(forKey: "askBackEnabled")
        defaults.removeObject(forKey: "askBackTier")
        check("settings: askBackEnabled defaults to true", Settings.askBackEnabled == true)
        check("settings: askBackTier defaults to careful", Settings.askBackTier == .careful
              && defaults.string(forKey: "askBackTier") == "careful")
        Settings.askBackEnabled = false
        Settings.askBackTier = .fast
        check("settings: both keys round-trip through UserDefaults",
              Settings.askBackEnabled == false && Settings.askBackTier == .fast
                && defaults.string(forKey: "askBackTier") == "fast" && defaults.bool(forKey: "askBackEnabled") == false)
        defaults.set("bogus", forKey: "askBackTier")
        check("settings: an unknown tier string reads as careful", Settings.askBackTier == .careful)

        print(reporter.summaryLine(prefix: "[askback-review-selftest]"))
        return reporter.passed
    }
}
