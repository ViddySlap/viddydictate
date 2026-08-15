import Foundation
import AppKit

/// Headless verification seam for the Sticky Notes surface. Run with
/// `--notes-probe`. No LM Studio, audio, or UI. This is the durable contract that later changes
/// verify against, so it MUST run entirely against scratch working
/// directories under the OS temp dir and never touch the user's real
/// `~/Library/Application Support/ViddyDictate/sticky-notes/` store.
///
/// `StickyNotesStore` already supports a scratch root via `init(root:)`, so every case here builds its
/// own throwaway store and deletes it on the way out. Coverage:
///   - note create / save / load round-trip
///   - title derivation (first non-empty line, markdown-stripped, 20-char cap) + rename override
///     persisted through `note-titles.json`
///   - `_open-notes.md` regeneration (tab order honored, single `(active)` marker)
///   - close -> history -> restore -> hard-delete lifecycle
///   - retention purge for 24h / 1 week / forever (seeded closed-at ages, cascade)
///   - save-as naming + never-overwrite dedup
///   - empty-note evaporation (whitespace body never materializes; emptying an existing note deletes it)
///   - duplicate note (L2): the web-island "Duplicate note" store outcome — a fresh id carrying the same
///     body plus a "<source title> copy" rename override, source left intact, copy ordered right of it
///   - bridge-contract PARITY: the Swift `NotesInbound` / `NotesOutbound` rawValue sets must equal the
///     wire names in the JS `MSG` table and in the BUNDLED web island (`Resources/StickyNotes/app.js`)
///     — the JS that actually ships and runs — so a Swift-vs-JS drift is a visible red bar, not a silent
///     runtime typo.
///   - multi-window (L6): windows.json round-trip + load-sanitize, the cross-window aggregate
///     (window-then-tab order + exactly one global `(active)` marker on the most-recently-key window's
///     active tab), active-window resolution, title-bar-close migration without History, secondary pruning,
///     and single-window equivalence (the live single-primary path is byte-identical to the pre-L6 rewrite)
///   - tab drag rail (L7): the pure drop-index helper (`NotesWindowRegistry.insertionIndex`, which the JS
///     `insertionIndexForX` mirrors), the store-visible reorder round-trip (a reordered tabOrder flips
///     `_open-notes.md` and keeps the single active marker on the still-active tab), and the bundled
///     web-island selection guard contract that prevents tab drags from creating phantom note-body selections
///   - cross-window tab moves (L8): the store-visible membership move — docking a note into another window
///     (aggregate window-then-tab order + the single active marker following the docked note into the target)
///     and dragging a note out to a new window (the new window holds just that note, the source loses it),
///     plus the source-empty-secondary prune both moves rely on
///
/// The `--notes-render` offscreen-render stretch seam (explicitly optional and should-NOT-block)
/// is intentionally NOT built here: headless WKWebView offscreen rendering is flaky, and this probe's value is
/// the store/contract probe. It can be added later if it proves reliable.
enum NotesProbe {

    struct Check {
        let record: (String, Bool, String) -> Void

        func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
            record(name, ok, detail)
        }
    }

    static let insertionIndexFixturesPath = "Web/StickyNotes/fixtures/insertion-index.json"
    static let bridgeSourcePath = "Web/StickyNotes/src/bridge.js"
    static let bundledAppJS = bundledResource("StickyNotes/app.js")
    static let bundledAppCSS = bundledResource("StickyNotes/app.css")
    static let sourceDictationTargetJS = sourceFile("Web/StickyNotes/src/dictation-target.js")
    static let sourceEditorJS = sourceFile("Web/StickyNotes/src/editor.js")
    static let sourceDictationSeparatorJS = sourceFile("Web/StickyNotes/src/dictation-separator.js")
    static let sourceActionsJS = sourceFile("Web/StickyNotes/src/actions.js")
    static let sourceRenderJS = sourceFile("Web/StickyNotes/src/render.js")
    static let sourceStickySkillMenuJS = sourceFile("Web/StickyNotes/src/sticky-skill-menu.js")
    static let sourceIndexHTML = sourceFile("Web/StickyNotes/static/index.html")
    static let sourceAppCSS = sourceFile("Web/StickyNotes/static/app.css")
    static let sourceDictationController = sourceFile("Sources/App/DictationController.swift")
    // S8 (mini hover without focus): the three files the Swift-driven hover latch spans.
    static let sourceEventsJS = sourceFile("Web/StickyNotes/src/events.js")
    static let sourceMainJS = sourceFile("Web/StickyNotes/src/main.js")
    static let sourceNotesWebView = sourceFile("Sources/App/NotesDropWebView.swift")
    static let sourceNotesWindowController = sourceFile("Sources/App/NotesWindowController.swift")

    struct InsertionIndexFixtures: Decodable {
        let cases: [InsertionIndexFixture]
    }

    struct InsertionIndexFixture: Decodable {
        let name: String
        let tabs: [InsertionIndexFixtureTab]
        let x: CGFloat
        let expected: Int
        /// Live horizontal scroll of the strip (round-5 R3, item-9); absent == 0 (unscrolled). The `tabs` are
        /// content-frame (scroll-invariant) positions; the scroll-aware `insertionIndex` folds this back in.
        let scrollOffset: CGFloat?

        var midpoints: [CGFloat] {
            tabs.map { $0.left + ($0.width / 2) }
        }
    }

    struct InsertionIndexFixtureTab: Decodable {
        let left: CGFloat
        let width: CGFloat
    }

    static func run() -> Bool {
        print("--- notes probe: Sticky Notes store + bridge-contract verify seam (L1) ---\n")

        var results: [(name: String, ok: Bool)] = []
        let check = Check { name, ok, detail in
            results.append((name, ok))
            print("  [\(ok ? "ok " : "FAIL")] \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        let fm = FileManager.default
        let base = scratchStoreBase()
        defer { try? fm.removeItem(at: base) }
        let freshRoot = scratchStoreRootFactory(base: base)

        probeStoreRoundTrip(freshRoot: freshRoot, check: check)
        probeTitleDerivation(fm: fm, freshRoot: freshRoot, check: check)
        probeAggregateRegeneration(freshRoot: freshRoot, check: check)
        guard probeCloseHistoryLifecycle(freshRoot: freshRoot, check: check) else { return finish(results) }
        probeRetentionPurge(fm: fm, freshRoot: freshRoot, check: check)
        probeSaveAs(fm: fm, base: base, freshRoot: freshRoot, check: check)
        probeEmptyNoteEvaporation(fm: fm, freshRoot: freshRoot, check: check)
        probeDuplicateNote(freshRoot: freshRoot, check: check)
        probeAggregateRewritePolicy(check: check)
        probeBridgeParity(check: check)
        probeDictationSeparator(check: check)
        probeNoteToHandoff(fm: fm, base: base, freshRoot: freshRoot, check: check)
        probePasteRouting(check: check)
        guard probeAttachmentsBackend(fm: fm, base: base, freshRoot: freshRoot, check: check) else { return finish(results) }
        probeMultiWindowMembership(freshRoot: freshRoot, check: check)
        probeMiniViewState(freshRoot: freshRoot, check: check)
        probeMiniControls(freshRoot: freshRoot, check: check)
        probeMiniHoverFocus(check: check)
        probeNoteTargetSnapshot(check: check)
        probeBullseye(freshRoot: freshRoot, check: check)
        probeBullseyeMarker(check: check)
        probeBullseyeReveal(freshRoot: freshRoot, check: check)
        probeReplaceHighlight(check: check)
        probeTakeTeardown(check: check)
        probeTakeControls(check: check)
        probeSpaceLock(check: check)
        probeTabDragRail(freshRoot: freshRoot, check: check)
        probeCrossWindowMoves(fm: fm, freshRoot: freshRoot, check: check)
        probeDropCoordinator(freshRoot: freshRoot, check: check)

        return finish(results)
    }

    private static func probeAggregateRewritePolicy(check: Check) {
        let fixtures: [(String, NotesRenderIntent, AggregateRewritePolicy)] = [
            ("create", .create(id: "note", body: "body", title: nil), .onlyOnMiss),
            ("set body", .setBody(id: "note", body: "body"), .onlyOnMiss),
            ("insert at caret", .insertAtCaret(id: "note", text: "text"), .onlyOnMiss),
            ("rename", .rename(id: "note", title: "title"), .always),
            ("close", .close(id: "note"), .onlyOnMiss),
            ("restore", .restore(id: "note", body: "body", title: "title"), .onlyOnMiss),
            ("duplicate", .duplicate(id: "note", body: "body", title: "title"), .onlyOnMiss),
            ("focus", .focus(id: "note"), .never),
            ("attachments changed", .attachmentsChanged(id: "note"), .always),
        ]

        for (name, intent, expected) in fixtures {
            check("render policy: \(name)", intent.aggregateRewritePolicy == expected)
        }

        let policies = fixtures.map { $0.2 }
        check("render policy: distribution is 2 always / 6 only-on-miss / 1 never",
              policies.filter { $0 == .always }.count == 2
              && policies.filter { $0 == .onlyOnMiss }.count == 6
              && policies.filter { $0 == .never }.count == 1)
    }

    private static func finish(_ results: [(name: String, ok: Bool)]) -> Bool {
        let passed = results.filter { $0.ok }.count
        let ok = results.allSatisfy { $0.ok }
        print("\n=== notes-probe RESULT ===")
        print("[notes-probe] ok=\(ok) checks=\(results.count) passed=\(passed) failed=\(results.count - passed)")
        return ok
    }

    // MARK: - helpers

    private static func scratchStoreBase() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-notes-probe-\(UUID().uuidString)", isDirectory: true)
    }

    private static func scratchStoreRootFactory(base: URL) -> () -> URL {
        var rootCounter = 0
        return {
            rootCounter += 1
            return base.appendingPathComponent("store-\(rootCounter)", isDirectory: true)
        }
    }

    /// True iff the first occurrence of `a` precedes the first occurrence of `b` in `text` (both present).
    static func orderedBefore(_ a: String, _ b: String, in text: String) -> Bool {
        guard let ra = text.range(of: a), let rb = text.range(of: b) else { return false }
        return ra.lowerBound < rb.lowerBound
    }

    static func countOccurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = text.startIndex
        while let r = text.range(of: needle, range: idx..<text.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }

    static func sourceSlice(_ source: String, from: String, to: String) -> String {
        guard let start = source.range(of: from),
              let end = source.range(of: to, range: start.upperBound..<source.endIndex)
        else { return "" }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private static func bundledResource(_ path: String) -> String {
        guard let resourceURL = Bundle.main.resourceURL else { return "" }
        return (try? String(contentsOf: resourceURL.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    private static func sourceFile(_ path: String) -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    static func loadInsertionIndexFixtures() throws -> [InsertionIndexFixture] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let url = cwd.appendingPathComponent(insertionIndexFixturesPath, isDirectory: false)
        let data = try Data(contentsOf: url)
        let fixtures = try JSONDecoder().decode(InsertionIndexFixtures.self, from: data)
        guard !fixtures.cases.isEmpty else {
            throw NSError(domain: "NotesProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixture table has no cases"])
        }
        return fixtures.cases
    }

    /// Seed history rows straight to disk (id, filename, closedAt) with the same JSON/date shape the
    /// store persists, so a purge test can control closed-at ages the public API cannot inject.
    static func seedHistory(root: URL, entries: [(id: String, filename: String, closedAt: Date)]) {
        let fm = FileManager.default
        let historyDir = root.appendingPathComponent("notes-history", isDirectory: true)
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        for e in entries {
            try? "seeded body for \(e.id)".write(to: historyDir.appendingPathComponent(e.filename),
                                                 atomically: true, encoding: .utf8)
        }
        let rows = entries.map { StickyNotesStore.HistoryEntry(id: $0.id, filename: $0.filename, closedAt: $0.closedAt) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(rows) {
            try? data.write(to: root.appendingPathComponent("notes-history.json"), options: .atomic)
        }
    }

    /// Extract the top-level property keys of the FIRST object literal that follows `marker` in `text`.
    /// Brace/paren/bracket-depth and string-aware, so it survives minified single-line output. Returns
    /// nil when the marker or an opening brace is not found (so the caller reports a real red bar rather
    /// than a spurious empty-set match).
    private static func objectKeys(afterMarker marker: String, in text: String) -> Set<String>? {
        guard let mr = text.range(of: marker) else { return nil }
        guard let open = text[mr.upperBound...].firstIndex(of: "{") else { return nil }
        // Capture the inner content between the outermost braces.
        var depth = 0
        var inStr = false
        var quote: Character = "\""
        var inner = ""
        var i = open
        var closed = false
        while i < text.endIndex {
            let c = text[i]
            if inStr {
                inner.append(c)
                if c == quote { inStr = false }
            } else {
                switch c {
                case "\"", "'", "`":
                    inStr = true; quote = c; inner.append(c)
                case "{":
                    depth += 1
                    if depth > 1 { inner.append(c) }
                case "}":
                    depth -= 1
                    if depth == 0 { closed = true }
                    else { inner.append(c) }
                default:
                    inner.append(c)
                }
            }
            if closed { break }
            i = text.index(after: i)
        }
        guard closed else { return nil }
        return topLevelKeys(inner)
    }

    static func objectKeys(afterAnyMarker markers: [String], in text: String) -> Set<String>? {
        for marker in markers {
            if let keys = objectKeys(afterMarker: marker, in: text) {
                return keys
            }
        }
        return nil
    }

    static func stripLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")
    }

    /// Keys of a flat object body: split top-level (comma at nesting depth 0), key = text before the
    /// first colon of each entry, stripped of quotes/whitespace.
    private static func topLevelKeys(_ inner: String) -> Set<String> {
        var keys = Set<String>()
        var depth = 0
        var inStr = false
        var quote: Character = "\""
        var entry = ""
        func flush() {
            if let ci = entry.firstIndex(of: ":") {
                let key = entry[..<ci].trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'`"))
                if !key.isEmpty { keys.insert(key) }
            }
            entry = ""
        }
        for c in inner {
            if inStr {
                entry.append(c)
                if c == quote { inStr = false }
                continue
            }
            switch c {
            case "\"", "'", "`":
                inStr = true; quote = c; entry.append(c)
            case "(", "[", "{":
                depth += 1; entry.append(c)
            case ")", "]", "}":
                depth -= 1; entry.append(c)
            case ",":
                if depth == 0 { flush() } else { entry.append(c) }
            default:
                entry.append(c)
            }
        }
        flush()
        return keys
    }

    static func driftDetail(swift: [String], js: Set<String>?) -> String {
        guard let js = js else { return "JS set not extracted" }
        let swiftSet = Set(swift)
        if swiftSet == js { return "" }
        let onlySwift = swiftSet.subtracting(js).sorted()
        let onlyJS = js.subtracting(swiftSet).sorted()
        var parts: [String] = []
        if !onlySwift.isEmpty { parts.append("swift-only=\(onlySwift)") }
        if !onlyJS.isEmpty { parts.append("js-only=\(onlyJS)") }
        return parts.joined(separator: " ")
    }
}
