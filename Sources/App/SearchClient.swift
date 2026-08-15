import Foundation

/// The web-search orchestration for Option+L (local) and Option+G (Gemini). Ports the signed-off
/// process-shape bench's **Shape C** verbatim: the app drives the tool-calls
/// (LM Studio's MCP host is GUI-only, so the API client orchestrates), two models, bounded-agentic.
///
///  - **Option+L** = `localAnswer`: qwen3-coder-30b runs a tool-calling loop (rewrite -> web_search ->
///    judge -> optional ONE re-search, MAX 2 searches), then the independently configured
///    `searchLocalSynth` route synthesizes a short spoken-style answer from the retrieved results.
///  - **Option+G** = `geminiAnswer`: Gemini 2.5 Flash with google_search grounding produces the
///    answer, then the independently configured `searchGeminiSynth` route reshapes it into the same
///    spoken format. The routes intentionally share default prompt bytes but never routing state.
///
/// Both return a `CleanupClient.Result` so the controller's land/fallback wiring is identical to
/// Option+M (`.ok` -> land the answer; every failure -> a toast, never an empty answer). Output runs
/// through `CleanupClient.stripReasoning` + `CleanupClient.asciiPunctuationNormalized` (the shared
/// no-markdown / plain-ASCII choke point).
enum SearchClient {

    // MARK: - Locked prompts (VERBATIM from the bench: websearch_bench.py)
    //
    // The two search system prompts (`defaultSearchSynthPrompt` / `defaultSearchAgenticPrompt`) and the
    // finalize instruction (`searchAgenticFinalize`) were rehomed to `Prompts.swift` by item-4 piece 11
    // so every mode's default prompt is a locatable facet in one file (ADR 0010 point 5). They stay the
    // defaults behind `Settings.searchSynthPrompt` / `Settings.searchAgenticPrompt`; resolve them via
    // `Settings` (never read the raw constant) so a user override is honored.

    /// The web_search tool definition handed to the retrieval model (verbatim TOOLS[0]).
    static var webSearchTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web and return the top results as title / url / snippet.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "the search query string"]],
                    "required": ["query"],
                ],
            ],
        ]
    }

    // MARK: - Pure helpers (unit-tested headlessly)

    /// The loop's hard cap: force the final (no-tools) turn once the search budget is spent.
    static func shouldForceFinalize(nSearches: Int, maxSearches: Int) -> Bool {
        nSearches >= maxSearches
    }

    /// Force a synthesized answer to pure-ASCII, no-markdown spoken text. Starts from the shared house
    /// normalizer (em/en dashes, curly quotes, backticks) — the choke point the handoff specifies — then
    /// applies the spoken-answer specifics the shared path leaves: strip markdown emphasis asterisks,
    /// say the degree sign aloud, fold Latin diacritics to ASCII, and drop any remaining non-ASCII.
    ///
    /// The diacritic fold + non-ASCII drop is SEARCH-ONLY and intentionally NOT in the shared
    /// normalizer: a search answer is disposable spoken text, so "deja vu" / "cafe" / "165 degrees F"
    /// are fine, whereas the email path must preserve a name's accent ("Jose") byte-for-byte. So the
    /// shared normalizer stays byte-identical for cleanup/email and this hard pure-ASCII guarantee is
    /// layered on top only here.
    static func toSpokenAscii(_ s: String) -> String {
        var out = CleanupClient.asciiPunctuationNormalized(s)
        out = out.replacingOccurrences(of: "*", with: "")            // markdown *italic* / **bold**
        out = out.replacingOccurrences(of: "\u{00B0}", with: " degrees ")  // 165°F -> 165 degrees F
        // Fold accents (NFD then drop combining marks + any other non-ASCII scalar).
        var scalars = String.UnicodeScalarView()
        for u in out.decomposedStringWithCanonicalMapping.unicodeScalars where u.value <= 127 {
            scalars.append(u)
        }
        out = String(scalars)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Gemini key (runtime)

    /// Resolve the Gemini grounding key through the app's secret store: login Keychain, then the
    /// testing environment override, then nothing. Returns nil when the user has not stored a key —
    /// Option+G is then simply off, and `geminiOffResult` says how to turn it on.
    static func resolveGeminiKey() -> String? {
        SecretStore.value(.geminiAPIKey)
    }

    /// What Option+G returns when no key is stored: the feature reports itself off with the exact
    /// command that turns it on, rather than failing mid-request. Pure and argument-free so the
    /// deterministic rail asserts the message a user actually sees without depending on whether this
    /// machine happens to have a key stored.
    static func geminiOffResult() -> CleanupClient.Result {
        .unavailable("no \(SecretStore.Secret.geminiAPIKey.label) stored - "
                     + SecretStore.Secret.geminiAPIKey.setupHint)
    }

    // MARK: - LM Studio chat (tool-capable, synchronous)

    private struct ChatOutcome {
        let content: String
        let toolCalls: [[String: Any]]
        /// Non-nil means the call failed; carries the failure mode to surface to the controller.
        let failure: CleanupClient.Result?
    }

    /// One non-streaming LM Studio chat-completions call. Synchronous (semaphore) — call OFF the main
    /// thread. With `tools` set, parses `tool_calls` off the response message.
    private static func lmChat(model: String, messages: [[String: Any]],
                              tools: [[String: Any]]? = nil, toolChoice: String? = nil,
                              maxTokens: Int, temperature: Double = 0.0,
                              timeout: TimeInterval) -> ChatOutcome {
        var body: [String: Any] = [
            "model": model, "messages": messages,
            "temperature": temperature, "max_tokens": maxTokens, "stream": false,
        ]
        if let tools = tools {
            body["tools"] = tools
            body["tool_choice"] = toolChoice ?? "auto"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return ChatOutcome(content: "", toolCalls: [], failure: .unavailable("encode failed"))
        }
        var req = URLRequest(url: Settings.searchEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let sem = DispatchSemaphore(value: 0)
        var outcome = ChatOutcome(content: "", toolCalls: [], failure: .unavailable("no result"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            switch CleanupClient.classifyToolCapableChatResponse(
                data: data, response: response, error: error
            ) {
            case .message(let content, let toolCalls):
                outcome = ChatOutcome(content: content, toolCalls: toolCalls, failure: nil)
            case .failure(let result):
                outcome = ChatOutcome(content: "", toolCalls: [], failure: result)
            }
        }.resume()
        // Wait a touch past the request timeout so a genuine timeout returns through the normal path.
        _ = sem.wait(timeout: .now() + timeout + 10)
        return outcome
    }

    // MARK: - Agentic retrieval loop (Shape C, ported from _agentic_loop)

    /// Run the qwen tool-calling loop and return the union of retrieved results (or a failure). Mirrors
    /// the bench: rewrite -> web_search -> judge -> optional ONE re-search, capped at `maxSearches`,
    /// then a forced final (no-tools) turn. `collected` may be empty even on success (search throttled).
    private static func agenticLoop(question: String) -> (results: [WebSearchBackend.Result], failure: CleanupClient.Result?) {
        let maxSearches = Settings.searchMaxSearches
        let maxTurns = maxSearches + 1
        let system = Settings.searchAgenticPrompt + searchAgenticFinalize
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": question],
        ]
        var collected: [WebSearchBackend.Result] = []
        var nSearches = 0

        for _ in 0..<maxTurns {
            let forceFinal = shouldForceFinalize(nSearches: nSearches, maxSearches: maxSearches)
            let outcome = lmChat(model: Settings.searchModel, messages: messages,
                                 tools: forceFinal ? nil : [webSearchTool],
                                 toolChoice: forceFinal ? "none" : "auto",
                                 maxTokens: Settings.searchRetrievalMaxTokens,
                                 timeout: Settings.searchTimeout)
            if let failure = outcome.failure {
                // A retrieval failure with nothing collected is fatal; if we already have results,
                // fall through and let synthesis use them.
                if collected.isEmpty { return ([], failure) }
                return (collected, nil)
            }
            if !outcome.toolCalls.isEmpty && !forceFinal {
                // Echo the assistant tool-call turn back into the thread, then execute each call.
                messages.append(["role": "assistant", "content": outcome.content,
                                 "tool_calls": outcome.toolCalls])
                for tc in outcome.toolCalls {
                    let fn = tc["function"] as? [String: Any]
                    var query = question
                    if let argStr = fn?["arguments"] as? String,
                       let argData = argStr.data(using: .utf8),
                       let args = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
                       let q = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !q.isEmpty {
                        query = q
                    }
                    let res = WebSearchBackend.search(query)
                    collected.append(contentsOf: res)
                    nSearches += 1
                    let id = (tc["id"] as? String) ?? "call_\(nSearches)"
                    messages.append(["role": "tool", "tool_call_id": id,
                                     "content": WebSearchBackend.format(res)])
                }
                continue
            }
            // Final assistant message (qwen said DONE / no more tool calls) — retrieval is complete.
            return (collected, nil)
        }
        return (collected, nil)
    }

    // MARK: - Provider-routed synthesis

    /// Pure request builder shared by runtime and deterministic H1 route-coverage tests. Retrieval is
    /// intentionally absent: only the selected synthesis route/provider crosses this transform seam.
    static func makeSynthesisRequest(route: LLMRouteID, question: String, resultsBlock: String,
                                     selected: LLMProviderBundle, systemPrompt: String,
                                     timeout: TimeInterval) -> TextTransformRequest {
        precondition(route == .searchLocalSynth || route == .searchGeminiSynth)
        return TextTransformRequest(
            route: route, bundle: selected, sourceText: question,
            systemPrompt: systemPrompt,
            userMessage: "Question: \(question)\n\nSearch results:\n\(resultsBlock)",
            timeout: timeout)
    }

    /// Provider-routed synthesis: turn (question + formatted results) into the short spoken answer.
    /// Retrieval remains fixed per Option+L/G; only this stable synthesis route consults Models & Power.
    private static func synthesize(route: LLMRouteID, question: String,
                                   resultsBlock: String,
                                   resolution: LLMRouteResolution,
                                   retryCompletion: ((CleanupClient.Result) -> Void)? = nil) -> CleanupClient.Result {
        // Layer 2: the context-aware glossary rides the synthesis pass (the post-dictation LLM pass that
        // composes the answer from the spoken question), so search no longer silently skips Layer 2 the
        // way it used to (review item 6 / correction-dictionary finding). No-op when the context column
        // is empty, so this is byte-identical until the user adds context entries.
        let requestForBundle: TextTransformClient.RetryRequestBuilder = { bundle in
            let basePrompt = Settings.modelsPower.effectivePrompt(
                for: route, provider: bundle.provider)
            let timeout = bundle.provider == .local
                ? Settings.searchTimeout : CloudCleanupClient.defaultTimeout
            return makeSynthesisRequest(
                route: route, question: question, resultsBlock: resultsBlock,
                selected: bundle,
                systemPrompt: CorrectionDictionary.shared.augment(basePrompt), timeout: timeout)
        }
        let normalize: TextTransformClient.ResultMap = { transformed in
            switch transformed {
            case .ok(let content):
                let answer = toSpokenAscii(CleanupClient.stripReasoning(content))
                return answer.isEmpty ? .badOutput("empty synthesis") : .ok(answer)
            case .unavailable, .timedOut, .badOutput:
                return transformed
            }
        }
        return TextTransformClient.transformSyncResolved(
            resolution, route: route, requestForBundle: requestForBundle,
            local: { req in
                let outcome = lmChat(model: req.bundle.modelID, messages: [
                    ["role": "system", "content": req.systemPrompt],
                    ["role": "user", "content": req.userMessage],
                ], maxTokens: Settings.searchSynthMaxTokens, timeout: req.timeout)
                if let failure = outcome.failure { return failure }
                return .ok(outcome.content)
            }, resultMap: normalize, retryCompletion: retryCompletion)
    }

    /// The synthesis route's execution decision, taken once per pipeline so residency prep and the synth
    /// pass cannot disagree about which provider is running.
    private static func synthesisResolution(route: LLMRouteID) -> LLMRouteResolution {
        Settings.modelsPower.resolveRoute(route, fallback: .local(Settings.searchSynthModel))
    }

    /// Preserve the existing JIT/residency timing for the Local arm. Remote arms have no LM Studio
    /// residency step and are invoked strictly through TextTransformClient. Residency follows the RESOLVED
    /// provider, so a route that degraded onto Local still gets its cold load out of the call timeout.
    private static func prepareSynthesis(_ resolution: LLMRouteResolution) -> CleanupClient.Result? {
        guard let bundle = resolution.bundle, bundle.provider == .local else { return nil }
        return ModelManager.shared.ensureReady(bundle.modelID)
            ? nil : .unavailable("synthesis model not loaded")
    }

    // MARK: - Gemini grounding (Option+G retrieval)

    /// Gemini 2.5 Flash with google_search grounding. Returns the raw grounded answer text, or a
    /// failure. Synchronous (semaphore) — call OFF the main thread.
    private static func geminiGrounded(question: String, key: String) -> (answer: String, failure: CleanupClient.Result?) {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(Settings.geminiModel):generateContent"
        guard let url = URL(string: urlStr) else { return ("", .unavailable("bad gemini url")) }
        let body: [String: Any] = [
            "contents": [["parts": [["text": question]]]],
            "tools": [["google_search": [String: Any]()]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return ("", .unavailable("encode failed"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Settings.searchTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = data

        let sem = DispatchSemaphore(value: 0)
        var result: (answer: String, failure: CleanupClient.Result?) = ("", .unavailable("no result"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                    result = ("", .timedOut); return
                }
                result = ("", .unavailable(error.localizedDescription)); return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = ("", .unavailable("gemini HTTP \(code)")); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                result = ("", .unavailable("bad gemini response shape")); return
            }
            let text = parts.compactMap { $0["text"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result = text.isEmpty ? ("", .badOutput("empty gemini answer")) : (text, nil)
        }.resume()
        _ = sem.wait(timeout: .now() + Settings.searchTimeout + 10)
        return result
    }

    // MARK: - Public pipelines (synchronous; run on a background queue)

    /// Option+L (Shape C): agentic retrieval -> gemma synthesis. Synchronous — call OFF the main thread.
    static func localAnswerSync(question: String,
                                retryCompletion: ((CleanupClient.Result) -> Void)? = nil) -> CleanupClient.Result {
        guard WebSearchBackend.isInstalled else {
            return .unavailable("search backend not installed (run install-websearch-helper.sh)")
        }
        // Make the fixed Local retrieval model resident, plus the synthesis model only when this route's
        // selected provider is Local. Either Local model may have been TTL-evicted by LM Studio; loading
        // here (with each model's per-model TTL) keeps the cold load out of the per-call timeouts.
        // Fail-fast on a load failure with a clear diagnostic, matching CleanupClient/EmailClient —
        // proceeding into the pipeline against an unloaded model just hangs/times out with a murkier
        // error (model-lifecycle finding: ensureReady's contract must not silently fork between clients).
        guard ModelManager.shared.ensureReady(Settings.searchModel) else {       // retrieval / agentic (qwen)
            return .unavailable("retrieval model not loaded")
        }
        // Resolve before retrieval: an off route cannot synthesize an answer, so the agentic loop is not
        // worth running, and the mode reports itself off with the specific reason instead.
        let resolution = synthesisResolution(route: .searchLocalSynth)
        if let off = TextTransformClient.offResult(resolution, route: .searchLocalSynth) { return off }
        if let failure = prepareSynthesis(resolution) { return failure }
        let (results, failure) = agenticLoop(question: question)
        if let failure = failure { return failure }
        if results.isEmpty {
            // Retrieval ran but found nothing (DDG throttled / no hits). Let gemma answer honestly
            // ("I couldn't find that") rather than fabricating — the synth prompt handles "(no results)".
            return synthesize(route: .searchLocalSynth, question: question, resultsBlock: "(no results)",
                              resolution: resolution, retryCompletion: retryCompletion)
        }
        return synthesize(route: .searchLocalSynth, question: question,
                          resultsBlock: WebSearchBackend.format(results),
                          resolution: resolution, retryCompletion: retryCompletion)
    }

    /// Option+G: Gemini grounding -> gemma synthesis (so the spoken format matches Option+L).
    /// Synchronous — call OFF the main thread.
    static func geminiAnswerSync(question: String,
                                 retryCompletion: ((CleanupClient.Result) -> Void)? = nil) -> CleanupClient.Result {
        guard let key = resolveGeminiKey() else { return geminiOffResult() }
        // Resolve before the grounded call for the same reason Option+L resolves before retrieval.
        let resolution = synthesisResolution(route: .searchGeminiSynth)
        if let off = TextTransformClient.offResult(resolution, route: .searchGeminiSynth) { return off }
        let (raw, failure) = geminiGrounded(question: question, key: key)
        if let failure = failure { return failure }
        // If the resolved synthesis provider is Local, make that model resident before the synth pass.
        // Gemini did retrieval remotely; Claude/Codex synthesis needs no LM Studio residency step.
        if let failure = prepareSynthesis(resolution) { return failure }
        // Feed Gemini's grounded answer to the resolved synthesis route as "search results" so the
        // voice + ASCII/no-markdown rules match Option+L exactly.
        return synthesize(route: .searchGeminiSynth, question: question, resultsBlock: raw,
                          resolution: resolution, retryCompletion: retryCompletion)
    }

    /// Async wrappers: run the (blocking) pipeline on a background queue, call back on an arbitrary
    /// queue — the controller hops to main, mirroring EmailClient.email.
    static func localAnswer(question: String, completion: @escaping (CleanupClient.Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(localAnswerSync(question: question, retryCompletion: completion))
        }
    }
    static func geminiAnswer(question: String, completion: @escaping (CleanupClient.Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(geminiAnswerSync(question: question, retryCompletion: completion))
        }
    }
}
