import Foundation

/// The headless `--websearch-selftest` seam for the web-search modes (Option+L / Option+G). Mirrors
/// `EmailSelfTest` / `CleanupSelfTest`.
///
/// Two layers:
///  1. **Unit coverage** of the search-specific pure logic — the locked bench prompts survived into
///     Settings, the `web_search` tool def has the right shape, the loop's 2-search cap logic, the
///     Gemini key loader (against a fixture), the search-question gate, and the shared no-markdown /
///     plain-ASCII hygiene. No network.
///  2. **The end-to-end output test** — a few evergreen corpus questions run through the REAL compiled
///     `SearchClient.localAnswerSync` (qwen agentic loop -> DuckDuckGo via the venv helper -> gemma
///     synthesis), checked for the answer's required SHAPE: non-empty, pure ASCII, no markdown. The
///     gate covers what the BUILD guarantees (shape + hygiene + a real non-empty pipeline run); the
///     `must_include` token is printed as an advisory plausibility note (DDG content is not
///     deterministic, so it never gates the green bar). Option+G is exercised best-effort and SKIPPED
///     (never failed) when the key or network is unavailable.
///
/// Exits 0 only when every unit check passes AND every local-search answer clears the shape gate.
enum WebSearchSelfTest {

    struct Fixture { let id: String; let question: String; let mustInclude: [String] }

    static let fixtures: [Fixture] = [
        Fixture(id: "ev01-chernobyl", question: "what year did the chernobyl disaster happen again", mustInclude: ["1986"]),
        Fixture(id: "ev04-1984", question: "who wrote the book nineteen eighty four", mustInclude: ["Orwell"]),
        Fixture(id: "ev17-chicken", question: "whats a safe internal temperature to cook chicken to", mustInclude: ["165"]),
    ]

    // MARK: entry point

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate Web-Search (Option+L / Option+G) — selftest ===")
        print("retrieval=\(Settings.searchModel)  synth=\(Settings.searchSynthModel)")
        print("endpoint=\(Settings.searchEndpoint.absoluteString)  maxSearches=\(Settings.searchMaxSearches)")
        print("backend installed: \(WebSearchBackend.isInstalled)  gemini=\(Settings.geminiModel)\n")

        let unitOK = runUnitTests()
        let (outputOK, results) = runOutputTests()
        runGeminiProbe()   // advisory only

        print("\n=== RESULT ===")
        print("unit tests:   \(unitOK ? "PASS" : "FAIL")")
        print("output shape: \(outputOK ? "PASS (every local answer cleared the shape gate)" : "FAIL (a local answer failed the shape gate)")")
        for r in results {
            print("  [\(r.id)] \(String(format: "%.2fs", r.latency)) \(r.failures.isEmpty ? "clean ✓" : "FAIL ❌ — " + r.failures.joined(separator: " | "))")
        }
        let green = unitOK && outputOK
        print(green ? "\nGREEN BAR CLEARED ✅" : "\nGREEN BAR NOT CLEARED ❌")
        return green
    }

    // MARK: unit coverage (no network)

    static func runTransportPrivacyTests() -> Bool {
        print("=== ViddyDictate Web-Search transport privacy selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check

        let canary = "ARGVSENTINEL_privacy_query_fragment_47"
        guard let transport = WebSearchBackend.processTransport(query: canary, maxResults: 3) else {
            reporter.record("transport request encodes", false)
            return reporter.passed
        }
        let expectedArguments = ["\(NSHomeDirectory())/.local/share/viddydictate/websearch.py"]
        check("app helper argv is exactly the helper path", transport.arguments == expectedArguments)
        check("app helper argv omits the query", !transport.arguments.joined(separator: " ").contains(canary))

        let request = (try? JSONSerialization.jsonObject(with: transport.stdin)) as? [String: Any]
        check("stdin request has exactly query + maxResults",
              Set(request?.keys.map { $0 } ?? []) == Set(["query", "maxResults"]))
        check("stdin request carries the complete query", (request?["query"] as? String) == canary)
        check("stdin request carries maxResults", (request?["maxResults"] as? Int) == 3)

        let logLines = [
            WebSearchBackend.parseFailureLogLine(query: canary, outputBytes: 17),
            WebSearchBackend.successLogLine(query: canary, resultCount: 2),
        ]
        check("search log assembly omits query text", logLines.allSatisfy { !$0.contains(canary) })
        check("search log assembly omits query fragments",
              logLines.allSatisfy { !$0.contains("ARGVSENTINEL") && !$0.contains("query_fragment") })

        let root = FileManager.default.currentDirectoryPath
        let helperPath = root + "/bin/websearch.py"
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-websearch-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let ddgsFixture = """
            import sys
            class DDGS:
                def text(self, query, max_results):
                    print("third-party-query-leak:" + query, file=sys.stderr)
                    return [{"title": "query-length-" + str(len(query)),
                             "href": "fixture://transport",
                             "body": "max-results-" + str(max_results)}]
            """
            try ddgsFixture.write(to: scratch.appendingPathComponent("ddgs.py"),
                                  atomically: true, encoding: .utf8)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [helperPath]
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = scratch.path
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            proc.environment = environment
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            proc.standardInput = input
            proc.standardOutput = output
            proc.standardError = errors
            try proc.run()
            input.fileHandleForWriting.write(transport.stdin)
            input.fileHandleForWriting.closeFile()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let rows = (try? JSONSerialization.jsonObject(with: outputData)) as? [[String: Any]]
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            check("repo helper accepts the stdin request with no query argv", proc.terminationStatus == 0)
            check("repo helper passes the complete stdin query to ddgs",
                  (rows?.first?["title"] as? String) == "query-length-\(canary.count)")
            check("repo helper passes maxResults from stdin",
                  (rows?.first?["body"] as? String) == "max-results-3")
            check("repo helper suppresses third-party query diagnostics",
                  !errorText.contains(canary) && !errorText.contains("ARGVSENTINEL"))
        } catch {
            reporter.record("repo helper stdin protocol probe", false, String(describing: type(of: error)))
        }

        print(reporter.passed ? "WEBSEARCH TRANSPORT PRIVACY PASS" : "WEBSEARCH TRANSPORT PRIVACY FAIL")
        return reporter.passed
    }

    private static func runUnitTests() -> Bool {
        print("--- unit coverage (no network) ---")
        let reporter = SelfTestReporter()
        let check = reporter.check

        // The bench-locked prompts survive into Settings (default, no user override).
        let synth = Settings.searchSynthPrompt
        check("synth prompt non-empty", !synth.isEmpty)
        check("synth prompt forbids markdown/citations", synth.contains("No markdown") && synth.contains("attributions"))
        check("synth prompt is spoken-style", synth.contains("spoken-style"))
        check("synth prompt leads with the direct answer", synth.contains("Lead with the direct answer"))

        let agentic = Settings.searchAgenticPrompt
        check("agentic prompt non-empty", !agentic.isEmpty)
        check("agentic prompt names web_search", agentic.contains("web_search"))
        check("agentic prompt caps at two searches", agentic.contains("at most TWICE"))
        check("finalize is DONE", searchAgenticFinalize.contains("DONE"))

        // web_search tool def shape.
        let tool = SearchClient.webSearchTool
        let fn = tool["function"] as? [String: Any]
        let params = fn?["parameters"] as? [String: Any]
        let props = params?["properties"] as? [String: Any]
        let required = params?["required"] as? [String]
        check("tool is a function", (tool["type"] as? String) == "function")
        check("tool name is web_search", (fn?["name"] as? String) == "web_search")
        check("tool has a query property", props?["query"] != nil)
        check("tool requires query", required == ["query"])

        // Loop 2-search cap logic.
        check("cap: 0 searches does not force finalize", !SearchClient.shouldForceFinalize(nSearches: 0, maxSearches: 2))
        check("cap: 1 search does not force finalize", !SearchClient.shouldForceFinalize(nSearches: 1, maxSearches: 2))
        check("cap: 2 searches forces finalize", SearchClient.shouldForceFinalize(nSearches: 2, maxSearches: 2))

        // Gemini key sourcing. The store itself is characterized by --secret-store-selftest; what
        // belongs here is that Option+G goes through it and degrades to a named off state.
        check("gemini key comes from the secret store",
              SearchClient.resolveGeminiKey() == SecretStore.value(.geminiAPIKey))
        if case .unavailable(let why) = SearchClient.geminiOffResult() {
            check("no stored key reports Option+G off with a fix", why.contains("set-gemini-key.sh"))
        } else {
            check("no stored key reports Option+G off with a fix", false)
        }

        // Search-question gate (>= 2 words is a real spoken question).
        check("search gate accepts 2 words", CleanupLogic.isSearchQuestion(wordCount: 2))
        check("search gate accepts a long question", CleanupLogic.isSearchQuestion(wordCount: 9))
        check("search gate rejects 1 word (incidental)", !CleanupLogic.isSearchQuestion(wordCount: 1))
        check("search gate rejects empty", !CleanupLogic.isSearchQuestion(wordCount: 0))

        // Shared no-markdown / plain-ASCII hygiene (the choke point every answer runs through).
        check("normalizer strips backticks", CleanupClient.asciiPunctuationNormalized("the `snout` shape") == "the snout shape")
        check("normalizer maps typographic punctuation",
              CleanupClient.asciiPunctuationNormalized("it\u{2019}s \u{201C}deja vu\u{201D}") == "it's \"deja vu\"")
        check("reasoning stripper removes a think block",
              CleanupClient.stripReasoning("<think>plan</think>The answer is 1986.") == "The answer is 1986.")
        // Search-only spoken-ASCII fold: strip markdown emphasis, voice the degree sign, fold accents.
        check("spoken-ascii strips markdown emphasis",
              SearchClient.toSpokenAscii("the book *Nineteen Eighty-Four* and **bold**") == "the book Nineteen Eighty-Four and bold")
        check("spoken-ascii voices the degree sign",
              SearchClient.toSpokenAscii("cook chicken to 165\u{00B0}F") == "cook chicken to 165 degrees F")
        check("spoken-ascii folds accents to ASCII",
              SearchClient.toSpokenAscii("it's called d\u{00E9}j\u{00E0} vu") == "it's called deja vu")
        check("spoken-ascii drops other non-ascii",
              SearchClient.toSpokenAscii("answer \u{1F600} here").allSatisfy { $0.isASCII })

        // Result formatter shape (numbered title / body / url blocks).
        let block = WebSearchBackend.format([
            WebSearchBackend.Result(title: "T1", href: "https://a", body: "B1"),
            WebSearchBackend.Result(title: "T2", href: "https://b", body: "B2"),
        ])
        check("format numbers results", block.contains("[1] T1") && block.contains("[2] T2"))
        check("format empty -> (no results)", WebSearchBackend.format([]) == "(no results)")

        check("argv/stdin/log/helper privacy seam", runTransportPrivacyTests())

        // The shape detector validates itself (so a real-output FAIL means the model, not the gate).
        check("detect non-ascii answer", !shapeFailures(answer: "The sky is blue \u{2014} scattered light.").isEmpty)
        check("detect markdown answer", !shapeFailures(answer: "Here:\n- point one\n- point two").isEmpty)
        check("clean answer passes the gate", shapeFailures(answer: "The Chernobyl disaster happened in 1986.").isEmpty)

        print("  -> unit: \(reporter.passed ? "PASS" : "FAIL")\n")
        return reporter.passed
    }

    // MARK: end-to-end output test (real local pipeline)

    struct OutputResult { let id: String; let latency: TimeInterval; let failures: [String] }

    private static func runOutputTests() -> (Bool, [OutputResult]) {
        print("--- end-to-end output test (real SearchClient local pipeline -> LM Studio + DuckDuckGo) ---")
        guard WebSearchBackend.isInstalled else {
            print("  search backend NOT installed — run ./install-websearch-helper.sh. Cannot run E2E.")
            return (false, [])
        }
        var results: [OutputResult] = []
        var allClear = true
        for f in fixtures {
            let t0 = Date()
            let res = SearchClient.localAnswerSync(question: f.question)
            let wall = Date().timeIntervalSince(t0)
            var answer = ""
            var failures: [String] = []
            switch res {
            case .ok(let a): answer = a
            case .unavailable(let w): failures = ["service-unavailable: \(w)"]
            case .timedOut: failures = ["service-timeout"]
            case .badOutput(let w): failures = ["bad-output: \(w)"]
            }
            if !answer.isEmpty { failures += shapeFailures(answer: answer) }
            let r = OutputResult(id: f.id, latency: wall, failures: failures)
            results.append(r)
            if !failures.isEmpty { allClear = false }

            let hit = f.mustInclude.contains { answer.range(of: $0, options: .caseInsensitive) != nil }
            print("\n  [\(f.id)]  \(String(format: "%.2fs", wall))  \(failures.isEmpty ? "clean ✓" : "FAIL ❌")  plausible:\(hit ? "yes" : "no (advisory)")")
            print("    Q: \(snippet(f.question))")
            print("    A: \(snippet(answer))")
            if !failures.isEmpty { print("    failures: \(failures.joined(separator: " | "))") }
        }
        return (allClear, results)
    }

    // MARK: Gemini probe (advisory — never gates)

    private static func runGeminiProbe() {
        print("\n--- Gemini (Option+G) probe — advisory, does not gate ---")
        guard SearchClient.resolveGeminiKey() != nil else {
            print("  SKIP: no Gemini key in the keychain or the environment. Option+G untested.")
            return
        }
        let q = "who wrote the book nineteen eighty four"
        let t0 = Date()
        let res = SearchClient.geminiAnswerSync(question: q)
        let wall = Date().timeIntervalSince(t0)
        switch res {
        case .ok(let a):
            let fails = shapeFailures(answer: a)
            print("  [gemini]  \(String(format: "%.2fs", wall))  \(fails.isEmpty ? "clean ✓" : "shape: " + fails.joined(separator: " | "))")
            print("    A: \(snippet(a))")
        case .unavailable(let w): print("  [gemini] unavailable: \(w) (advisory — network / key access)")
        case .timedOut: print("  [gemini] timed out (advisory)")
        case .badOutput(let w): print("  [gemini] bad output: \(w) (advisory)")
        }
    }

    // MARK: shape gate

    /// The answer's required shape: non-empty, pure ASCII (the normalizer's hard guarantee), and no
    /// markdown (no backticks, no bold, no bullet lines, no `[](...)` links). This is exactly what the
    /// build controls; content correctness is checked advisorily via `must_include`.
    static func shapeFailures(answer: String) -> [String] {
        var out: [String] = []
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ["empty-answer"] }
        for scalar in trimmed.unicodeScalars where scalar.value > 127 {
            out.append("non-ascii: U+\(String(format: "%04X", scalar.value))")
            break
        }
        if trimmed.contains("`") { out.append("markdown: residual backtick") }
        if trimmed.contains("*") { out.append("markdown: emphasis asterisk") }
        if trimmed.contains("](") { out.append("markdown: link syntax") }
        for line in trimmed.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("# ") {
                out.append("markdown: bullet/heading line"); break
            }
        }
        return out
    }

    private static func snippet(_ s: String, _ n: Int = 200) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count <= n ? t : String(t.prefix(n)) + " …"
    }
}
