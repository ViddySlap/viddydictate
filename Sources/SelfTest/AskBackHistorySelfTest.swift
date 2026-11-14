import Foundation

// VDASK-6 self-test: what the History window row shows for an entry's `askBack` record. The pure rules are
// AskBackHistoryFormat; source-shape rows cover the AppKit row a headless row cannot build. The Linux oracle
// (history-rows.swift) is generated from the rows between the BEGIN and END markers. Synthetic text only.

enum AskBackHistorySelfTest {
    static func run() -> Bool {
        print("--- ask-back history: tag, answers block, fallback body ---")
        let check = SelfTestReporter()
        let histSrc = (try? String(
            contentsOf: URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("App/HistoryWindow.swift"), encoding: .utf8)) ?? ""
        let selfSrc = (try? String(contentsOf: URL(fileURLWithPath: #file), encoding: .utf8)) ?? ""
        // BEGIN history-rows
        func qn(_ question: String, answer: String? = nil, how: String? = nil) -> AskBackRecord.Question {
            AskBackRecord.Question(question: question, quote: "q", why: "w", options: ["a", "b"], answer: answer, how: how)
        }
        func rec(_ qs: [AskBackRecord.Question]) -> AskBackRecord {
            AskBackRecord(provider: "claude", reviewModel: "m", tier: "careful", reviewMs: 5, writeProvider: nil,
                          writeModel: nil, writeMs: nil, spots: [AskBackRecord.Spot(quote: "s", issue: "i", impact: "high")],
                          questions: qs)
        }
        let existing = ["cleaned", "Tighten", "into Notes"]
        let r1 = rec([qn("Which day?", answer: "Monday", how: "tap")])

        check("history tag: no record leaves the tag line exactly as it is",
              AskBackHistoryFormat.tagLine(record: nil, status: nil, existing: existing) == "cleaned · Tighten · into Notes"
                && AskBackHistoryFormat.tagLine(record: nil, status: "asking", existing: existing) == "cleaned · Tighten · into Notes"
                && AskBackHistoryFormat.tagLine(record: nil, status: nil, existing: []) == "")
        check("history tag: a record puts ? first on the existing tags",
              AskBackHistoryFormat.tagLine(record: r1, status: nil, existing: existing) == "? · cleaned · Tighten · into Notes")
        check("history tag: a done record shows just ?",
              AskBackHistoryFormat.tagLine(record: r1, status: "done", existing: existing) == "? · cleaned · Tighten · into Notes")
        check("history tag: asking",
              AskBackHistoryFormat.tagLine(record: r1, status: "asking", existing: ["Tighten"]) == "? asking · Tighten")
        check("history tag: writing",
              AskBackHistoryFormat.tagLine(record: r1, status: "writing", existing: ["Tighten"]) == "? writing · Tighten")
        check("history tag: write failed",
              AskBackHistoryFormat.tagLine(record: r1, status: "write failed", existing: ["Tighten"]) == "? write failed · Tighten")
        check("history tag: canceled",
              AskBackHistoryFormat.tagLine(record: r1, status: "canceled", existing: ["Tighten"]) == "? canceled · Tighten")
        check("history tag: unanswered at quit",
              AskBackHistoryFormat.tagLine(record: r1, status: "unanswered at quit", existing: ["Tighten"]) == "? unanswered at quit · Tighten")
        check("history tag: a record with no other tags is just the ? tag",
              AskBackHistoryFormat.tagLine(record: r1, status: "asking", existing: []) == "? asking")
        check("history tag: the status words are the stored AskBackHistoryStatus values",
              [AskBackHistoryStatus.asking, AskBackHistoryStatus.writing, AskBackHistoryStatus.writeFailed,
               AskBackHistoryStatus.canceled, AskBackHistoryStatus.unansweredAtQuit]
                .allSatisfy { (s: String) in AskBackHistoryFormat.tag(status: s) == "? \(s)" }
                && AskBackHistoryFormat.tag(status: AskBackHistoryStatus.done) == "?")
        check("history tag: a relaunch reads asking and writing as unanswered at quit, so it shows what is stored",
              AskBackHistoryFormat.tag(status: AskBackHistoryStatus.afterRelaunch("asking")) == "? unanswered at quit"
                && AskBackHistoryFormat.tag(status: AskBackHistoryStatus.afterRelaunch("writing")) == "? unanswered at quit"
                && AskBackHistoryFormat.tag(status: AskBackHistoryStatus.afterRelaunch("done")) == "?")

        check("history answers: a tapped answer shows its answer and how",
              AskBackHistoryFormat.answerLines(r1) == ["Q: Which day?", "\u{2192} Monday (tap)"])
        let hows = ["tap", "arrows", "click", "voice", "agent decided", "new take"]
        check("history answers: every stored how value shows as stored",
              hows.allSatisfy { (h: String) in AskBackHistoryFormat.answerLine(qn("Q", answer: "A", how: h)) == "\u{2192} A (\(h))" })
        check("history answers: a nil answer reads agent decided",
              AskBackHistoryFormat.answerLine(qn("Q", answer: nil, how: "agent decided")) == "\u{2192} agent decided"
                && AskBackHistoryFormat.answerLine(qn("Q", answer: nil, how: "new take")) == "\u{2192} agent decided")
        check("history answers: a nil how reads unanswered, with or without an answer",
              AskBackHistoryFormat.answerLine(qn("Q")) == "\u{2192} unanswered"
                && AskBackHistoryFormat.answerLine(qn("Q", answer: "A", how: nil)) == "\u{2192} unanswered")
        check("history answers: one Q and one arrow line per question, in order",
              AskBackHistoryFormat.answerLines(rec([qn("One?", answer: "x", how: "click"), qn("Two?")]))
                == ["Q: One?", "\u{2192} x (click)", "Q: Two?", "\u{2192} unanswered"])
        check("history answers: no questions shows one line",
              AskBackHistoryFormat.answerLines(rec([])) == ["No questions asked"])
        check("history answers: the block is the lines joined by newlines",
              AskBackHistoryFormat.answersText(r1) == "Q: Which day?\n\u{2192} Monday (tap)"
                && AskBackHistoryFormat.answersText(rec([])) == "No questions asked")
        check("history answers: spots, quotes, options, models and timings are not shown in v1",
              !AskBackHistoryFormat.answersText(r1).contains("claude") && !AskBackHistoryFormat.answersText(r1).contains("high")
                && !AskBackHistoryFormat.answersText(r1).contains("careful"))

        check("history body: delivered text shows as it is",
              AskBackHistoryFormat.body(delivered: "Ship Monday.", transcript: "raw words").text == "Ship Monday."
                && !AskBackHistoryFormat.body(delivered: "Ship Monday.", transcript: "raw words").isTranscriptFallback)
        let fb = AskBackHistoryFormat.body(delivered: "", transcript: "raw words")
        check("history body: empty delivered text falls back to the transcript, flagged",
              fb.text == "raw words" && fb.isTranscriptFallback)
        check("history body: whitespace-only delivered text also falls back",
              AskBackHistoryFormat.body(delivered: " \n ", transcript: "raw words").isTranscriptFallback)
        check("history body: nothing to fall back on keeps the delivered text",
              AskBackHistoryFormat.body(delivered: "", transcript: nil) == ("", false))

        let rtData = try? JSONEncoder().encode(r1)
        check("history record: round trip through JSON keeps the record",
              rtData.flatMap { try? JSONDecoder().decode(AskBackRecord.self, from: $0) } == r1)

        // Source-shape rows: the AppKit row a headless row cannot build.
        func part(_ from: String, _ upTo: String) -> String {
            guard let r = histSrc.range(of: from), let e = histSrc[r.upperBound...].range(of: upTo) else { return "" }
            return String(histSrc[r.lowerBound..<e.lowerBound])
        }
        let rowSrc = part("private final class TranscriptionHistoryRowView", "private final class ClipboardHistoryRowView")
        let layout = part("func layoutContents(width: CGFloat) -> CGFloat {", "override func hitTest")
        check("wiring (row): the tag line is built by AskBackHistoryFormat from the entry's record, status and existing tags",
              rowSrc.contains("AskBackHistoryFormat.tagLine(")
                && rowSrc.contains("record: entry.askBack, status: entry.status,")
                && rowSrc.contains("existing: [modeTag, levelTag, intoTag].compactMap { $0 })"))
        check("wiring (row): the body is the fallback-aware text, secondary colour when it is the transcript",
              rowSrc.contains("AskBackHistoryFormat.body(delivered: entry.text, transcript: entry.raw)")
                && rowSrc.contains("textLabel.textColor = displayBody.isTranscriptFallback ? .secondaryLabelColor : .labelColor")
                && rowSrc.contains("textLabel.stringValue = displayBody.text")
                && layout.contains("HistoryFormat.textHeight(displayBody.text, font: textFont, width: textW)"))
        check("wiring (row): the answers block is secondary colour at the tag font size",
              rowSrc.contains("answersLabel.font = .systemFont(ofSize: 11)")
                && rowSrc.contains("tagLabel.font = .systemFont(ofSize: 11)")
                && rowSrc.contains("answersLabel.textColor = .secondaryLabelColor"))
        check("wiring (row): the answers block starts hidden and shows only when expanded with a record",
              rowSrc.contains("answersLabel.isHidden = true\n        addSubview(answersLabel)")
                && layout.contains("if expanded, entry.askBack != nil {")
                && layout.contains("answersLabel.isHidden = false"))
        check("wiring (row): collapsed or without a record the answers block is hidden and adds no height",
              layout.contains("} else {\n            answersLabel.isHidden = true\n        }\n        return bottom + padBottom")
                && layout.contains("var bottom = textY + shownH"))
        check("wiring (row): the answers label shows the helper's answers text for the entry's record",
              rowSrc.contains("answersLabel.stringValue = entry.askBack.map { AskBackHistoryFormat.answersText($0) } ?? \"\""))
        check("wiring (row): the answers label wraps and is not limited to one line",
              rowSrc.contains("answersLabel.maximumNumberOfLines = 0")
                && rowSrc.contains("answersLabel.lineBreakMode = .byWordWrapping"))
        check("wiring (row): expanded, the answers sit below the body, measured at the text width",
              layout.contains("let answersH = HistoryFormat.textHeight(answersLabel.stringValue, font: answersFont, width: textW)")
                && layout.contains("answersLabel.frame = NSRect(x: padX, y: bottom + gap, width: textW, height: answersH)"))
        check("wiring (row): expanded, the row height includes the gap and the answers",
              layout.contains("bottom += gap + answersH")
                && layout.contains("return bottom + padBottom"))
        check("wiring (row): the collapsed height and fade still come from the three-line text rule",
              layout.contains("let collapsedH = ceil(lineH * 3)")
                && layout.contains("let shownH = expanded ? fullH : min(fullH, collapsedH)")
                && layout.contains("applyFadeMask(active: overflowing && !expanded)"))
        check("wiring (row): Copy and Cleaned copy what they copied before; the answers are never copied",
              rowSrc.contains("TargetResolver.copyToClipboard(entry.original)")
                && rowSrc.contains("TargetResolver.copyToClipboard(entry.cleaned ?? entry.text)")
                && !rowSrc.contains("copyToClipboard(answersLabel") && !rowSrc.contains("copyToClipboard(AskBackHistoryFormat"))
        // The round-trip rows below call TranscriptionHistory.record, which also appends to the real
        // DictationHistoryStore. Pin the guard that keeps them out of the user's real history.
        let afterRows = selfSrc.range(of: "// END " + "history-rows").map { String(selfSrc[$0.upperBound...]) } ?? ""
        let guardAt = afterRows.range(of: "Settings.keepFullHistory = false")?.lowerBound
        let recordAt = afterRows.range(of: "store.record(")?.lowerBound
        check("self-test guard: full history is switched off before the round-trip row records",
              guardAt != nil && recordAt != nil && guardAt! < recordAt!)
        check("self-test guard: the defaults domain is restored on exit",
              afterRows.contains("defaults.persistentDomain(forName: domain)")
                && afterRows.contains("defaults.setPersistentDomain(before, forName: domain)")
                && afterRows.contains("defaults.removePersistentDomain(forName: domain)"))
        // END history-rows

        // history.json round trip on a scratch store: with and without askBack. record() also writes the real
        // full history, so keep it off and restore the defaults, as TranscriptionHistorySelfTest does.
        Settings.registerDefaults()
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        let before = defaults.persistentDomain(forName: domain)
        defer {
            if let before = before { defaults.setPersistentDomain(before, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        Settings.keepFullHistory = false   // M1: no write to the real full history
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vd-askhist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptionHistory(directory: root, maxEntries: { 100 })
        let plainID = UUID(), askID = UUID()
        store.record(delivered: "Plain text.", raw: "plain raw", cleaned: nil, mode: .raw, app: "Notes", id: plainID)
        store.insertPending(id: askID, transcript: "pending transcript", askBack: r1, app: "Notes")
        store.flush()
        let back = TranscriptionHistory(directory: root, maxEntries: { 100 }).all()
        let plain = back.first { $0.id == plainID }, pending = back.first { $0.id == askID }
        check("history.json round trip: an entry without askBack decodes with no record and no status",
              plain?.askBack == nil && plain?.status == nil && plain?.text == "Plain text.")
        check("history.json round trip: a pending entry decodes with its record, empty text and the status the store left",
              pending?.askBack == r1 && pending?.text == "" && pending?.raw == "pending transcript"
                && pending?.status == AskBackHistoryStatus.unansweredAtQuit)

        print(check.summaryLine(prefix: "[askback-history-selftest]"))
        return check.passed
    }
}
