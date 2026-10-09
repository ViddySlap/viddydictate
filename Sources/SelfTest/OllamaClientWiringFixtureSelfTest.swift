import Foundation

/// G-S5 (`--ollama-client-wiring-selftest`): every Local transform runs on the app its route resolved to.
///
/// Each surface's real client (CleanupClient for cleanup, prompt-prep and custom modes through
/// `CleanupClient.localAdapter`, EmailClient through `EmailClient.localAdapter`, SearchClient's retrieval
/// loop and synthesis adapter, the Note to Handoff vision helper) is driven over a scripted
/// `LocalChatTransport`. LM Studio is a recorder that answers OpenAI-shaped JSON; Ollama is the REAL
/// `OllamaBackend` and the REAL `ModelManager` over a scripted in-memory Ollama (`/api/tags`, `/api/show`,
/// `/api/ps`, `/api/generate`, `/api/chat`), so the translator, the capacity step and D5's context rule on the
/// wire are the shipped code. No socket, no app, no network, no preferences written.
///
/// Distinct values everywhere: the idle window is **437** (never 600) and the vision helper's is 300; the
/// same id `shared-id-on-both:7b` is used for both apps, so a client that ignores the app still finds a
/// model; the Ollama model reports `thinking`, so `think` is on the wire for every surface and a wrong value
/// is visible; Ollama's tool call carries an OBJECT argument, LM Studio's a string.
///
/// Negative controls: the contract is re-run against four broken clients, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) clients that ignore the resolved app (always LM Studio);
/// (b) search retrieval at 8192 instead of 16384;
/// (c) cleanup with `think: true`;
/// (d) a vision pass that unloads its helper unconditionally, even one another mode already had warm.
enum OllamaClientWiringFixtureSelfTest {
    private static let modelID = "shared-id-on-both:7b"
    /// The Ollama vision helper the warm/cold checks use: like gemma4:e4b, a model that can see and that
    /// another mode (email, synthesis) may already hold warm.
    private static let visionHelperID = "gemma4-fixture:e4b"
    private static let keepAlive = 437
    private static let reasoningCanary = "REASONING-CANARY-stays-out-of-the-text"
    private static let ollamaReply = "Ollama fixture reply."
    private static let lmReply = "LM Studio fixture reply."
    private static let ollamaQuery = "ollama fixture query"
    private static let lmQuery = "lm studio fixture query"
    private static let searchResults = [
        WebSearchBackend.Result(title: "Fixture result", href: "https://example.invalid/fixture",
                                body: "A scripted search hit."),
    ]

    // Assertion names the negative controls look up.
    private static let cleanupOnOllamaCheck =
        "cleanup: an (Ollama, shared-id-on-both:7b) bundle runs on Ollama's /api/chat, never LM Studio"
    private static let retrievalContextCheck =
        "search retrieval: every turn carries num_ctx 16384 and think false"
    private static let cleanupThinkCheck = "cleanup: the chat carries num_ctx 8192, think false, keep_alive 437"
    private static let warmHelperCheck =
        "vision: an (Ollama, gemma4-fixture) helper already resident before the pass is NOT unloaded after it"

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== Ollama client wiring fixture selftest (each transform on its resolved app) ===")
        let reporter = SelfTestReporter()

        print("--- contract (real clients, real OllamaBackend + ModelManager over a scripted Ollama) ---")
        checkContract(Subject(), reporter)
        checkResidentContextReuse(reporter)
        checkVisionHelperChoice(reporter)
        checkProductionCallSites(reporter)
        checkReasoningOff(reporter)
        checkStallTimeout(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[ollama-client-wiring-selftest] PASS"
            : "[ollama-client-wiring-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - The scripted Mac

    private final class ScriptedMac {
        var lmRequests: [URLRequest] = []
        var lmBodies: [[String: Any]] {
            lmRequests.compactMap { $0.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
        }
        var lmUnloads: [String] = []
        var ollamaRequests: [(path: String, body: [String: Any]?)] = []
        var chats: [[String: Any]] { ollamaRequests.filter { $0.path == "/api/chat" }.compactMap(\.body) }
        var generates: [[String: Any]] { ollamaRequests.filter { $0.path == "/api/generate" }.compactMap(\.body) }
        /// What OllamaBackend.chat handed the client, already translated to the OpenAI shape.
        var translated: [Data] = []
        /// The OpenAI-shaped bodies the clients handed `transport.ollamaChat`, before translation.
        var ollamaChatBodies: [[String: Any]] = []
        var resident: [String: Int] = [:]
        var webSearches: [String] = []
        /// Whether LM Studio's readiness reports a cold load (the scripted answer to "was it resident").
        var lmColdLoad = true
        /// The mutant seam: readiness that cannot tell a warm model from a cold one, so every pass unloads.
        var alwaysCold = false

        private lazy var backend = OllamaBackend(
            transport: OllamaBackend.Transport(send: { request, _ in self.serve(request) },
                                               pathStatus: { _ in .missing }),
            environment: [:], homeDirectory: "/fixture-home")
        private lazy var manager = ModelManager()
        private lazy var capacity = ModelManager.CapacityDependencies(
            availableInstalledModels: { [] }, residentModels: { [] }, wiredBytes: { 0 },
            budgetBytes: { _ in UInt64.max / 2 }, ensureLoaded: { _, _ in false }, unload: { _ in },
            log: { _ in }, ollama: .backed(by: backend))

        var transport: LocalChatTransport {
            LocalChatTransport(
                sendLMStudio: { request, completion in
                    self.lmRequests.append(request)
                    let (data, status) = self.lmAnswer(request)
                    completion(data, request.url.flatMap {
                        HTTPURLResponse(url: $0, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
                    }, nil)
                },
                prepareLMStudio: { _, _ in (.ready, self.alwaysCold || self.lmColdLoad) },
                unloadLMStudio: { self.lmUnloads.append($0) },
                prepareOllama: { ref, context, ttl in
                    let prepared = self.manager.ensureReadyForChat(
                        ref, contextTokens: context, ttlOverrideSeconds: ttl, dependencies: self.capacity)
                    return (prepared.result, prepared.contextTokens ?? context, self.alwaysCold || prepared.coldLoaded)
                },
                chatOllama: { body, keepAlive, context, think, timeout in
                    self.ollamaChatBodies.append(body)
                    let result = self.backend.chat(openAIBody: body, keepAliveSeconds: keepAlive,
                                                   contextTokens: context, think: think, timeout: timeout)
                    if let data = result.0 { self.translated.append(data) }
                    return result
                },
                unloadOllama: { self.backend.unload($0) },
                keepAliveSeconds: { OllamaClientWiringFixtureSelfTest.keepAlive },
                beginRequest: { self.manager.beginRequest(on: $0) },
                endRequest: { self.manager.endRequest(on: $0) })
        }

        func search(_ query: String) -> [WebSearchBackend.Result] {
            webSearches.append(query)
            return OllamaClientWiringFixtureSelfTest.searchResults
        }

        /// LM Studio's chat-completions answers: a string-argument tool call on a first tool turn, DONE after
        /// a tool result, a JSON description for an image, else a reply with reasoning beside it.
        private func lmAnswer(_ request: URLRequest) -> (Data, Int) {
            let body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let messages = (body?["messages"] as? [[String: Any]]) ?? []
            var message: [String: Any] = ["role": "assistant", "content": lmReply,
                                          "reasoning_content": reasoningCanary]
            if messages.contains(where: { $0["role"] as? String == "tool" }) {
                message = ["role": "assistant", "content": "DONE"]
            } else if body?["tools"] != nil {
                message = ["role": "assistant", "content": "", "tool_calls": [[
                    "id": "lm_call_1", "type": "function",
                    "function": ["name": "web_search", "arguments": "{\"query\":\"\(lmQuery)\"}"],
                ]]]
            } else if messages.contains(where: { $0["content"] is [Any] }) {
                message = ["role": "assistant", "content": "{\"a1\":\"lm fixture description\"}"]
            }
            let reply: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": "stop"]]]
            return ((try? JSONSerialization.data(withJSONObject: reply)) ?? Data(), 200)
        }

        private func serve(_ request: URLRequest) -> (Data?, HTTPURLResponse?, Error?) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            ollamaRequests.append((path, body))
            let text = reply(path: path, body: body)
            return (Data(text.utf8), request.url.flatMap {
                HTTPURLResponse(url: $0, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            }, nil)
        }

        private func reply(path: String, body: [String: Any]?) -> String {
            let fixture = OllamaClientWiringFixtureSelfTest.self
            switch path {
            case "/api/tags":
                let rows = [fixture.modelID, fixture.visionHelperID].map { name in
                    "{\"name\":\"\(name)\",\"model\":\"\(name)\",\"size\":4200000000,"
                        + "\"capabilities\":[\"completion\",\"tools\",\"thinking\",\"vision\"]}"
                }
                return "{\"models\":[\(rows.joined(separator: ","))]}"
            case "/api/show":
                return "{\"capabilities\":[\"completion\",\"tools\",\"thinking\",\"vision\"],\"model_info\":{"
                    + "\"general.architecture\":\"fixturearch\",\"fixturearch.block_count\":24,"
                    + "\"fixturearch.attention.head_count\":8,\"fixturearch.attention.head_count_kv\":2,"
                    + "\"fixturearch.attention.key_length\":128,\"fixturearch.attention.value_length\":128}}"
            case "/api/ps":
                let rows = resident.keys.sorted().map { name in
                    "{\"name\":\"\(name)\",\"model\":\"\(name)\",\"size\":210000000,"
                        + "\"expires_at\":\"2026-09-30T14:10:00Z\",\"context_length\":\(resident[name]!)}"
                }
                return "{\"models\":[\(rows.joined(separator: ","))]}"
            case "/api/generate":
                let model = (body?["model"] as? String) ?? ""
                if (body?["keep_alive"] as? NSNumber)?.intValue == 0 {
                    resident[model] = nil
                } else {
                    resident[model] = ((body?["options"] as? [String: Any])?["num_ctx"] as? NSNumber)?.intValue ?? 4096
                }
                return "{\"done\":true}"
            case "/api/chat":
                let messages = (body?["messages"] as? [[String: Any]]) ?? []
                var message: [String: Any] = ["role": "assistant", "content": fixture.ollamaReply]
                if messages.contains(where: { $0["role"] as? String == "tool" }) {
                    message = ["role": "assistant", "content": "DONE"]
                } else if body?["tools"] != nil {
                    // Native shape: arguments is an OBJECT, and no id.
                    message = ["role": "assistant", "content": "", "tool_calls": [[
                        "function": ["name": "web_search", "arguments": ["query": fixture.ollamaQuery]],
                    ]]]
                } else if messages.contains(where: { $0["images"] != nil }) {
                    message = ["role": "assistant", "content": "{\"a1\":\"ollama fixture description\"}"]
                }
                if (body?["think"] as? NSNumber)?.boolValue == true {
                    message["thinking"] = fixture.reasoningCanary
                }
                let reply: [String: Any] = ["model": fixture.modelID, "message": message, "done": true,
                                            "done_reason": "stop"]
                return String(data: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(),
                              encoding: .utf8) ?? "{}"
            default:
                return "{\"error\":\"not found\"}"
            }
        }
    }

    // MARK: - The seam the mutants replace

    /// What a client does with the bundle its route resolved to, and the two profiles the mutants bend.
    private struct Subject {
        /// The bundle the client acts on. Real clients use the resolved one as it is.
        var rebundle: (LLMProviderBundle) -> LLMProviderBundle = { $0 }
        var cleanupSurface: OllamaSurfaceProfile = .cleanup
        var retrievalProfile: OllamaSurfaceProfile = .searchRetrieval
        /// The vision pass cannot tell a warm helper from one it loaded, so it unloads every time.
        var unloadsUnconditionally = false
    }

    private static let ollamaBundle = LLMProviderBundle.local(ref: LocalModelRef(backend: .ollama, modelID: modelID))
    private static let lmStudioBundle = LLMProviderBundle.local(modelID)

    private static func request(_ bundle: LLMProviderBundle, route: LLMRouteID, system: String,
                                user: String) -> TextTransformRequest {
        TextTransformRequest(route: route, bundle: bundle, sourceText: "fixture source text",
                             systemPrompt: system, userMessage: user, timeout: 30)
    }

    /// Run one async adapter to completion (the clients call back on a background queue).
    private static func complete(_ adapter: TextTransformClient.AsyncAdapter,
                              _ request: TextTransformRequest) -> CleanupClient.Result {
        let done = DispatchSemaphore(value: 0)
        var result: CleanupClient.Result = .unavailable("no result")
        adapter(request) { result = $0; done.signal() }
        _ = done.wait(timeout: .now() + 10)
        return result
    }

    private static func okText(_ result: CleanupClient.Result) -> String? {
        if case .ok(let text) = result { return text }
        return nil
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    /// A chat body's wire facts: num_ctx, think, keep_alive.
    private static func wire(_ chat: [String: Any]?) -> (context: Int?, think: Bool?, keepAlive: Int?) {
        ((chat?["options"] as? [String: Any]).flatMap { int($0["num_ctx"]) },
         (chat?["think"] as? NSNumber)?.boolValue,
         int(chat?["keep_alive"]))
    }

    /// The same JSON object: both sides through one parse and a sorted-keys serialization, so number and
    /// boolean bridging cannot make two equal bodies differ (or two different ones agree).
    private static func same(_ lhs: [String: Any]?, _ rhs: [String: Any]) -> Bool {
        func canonical(_ object: Any) -> Data? {
            guard JSONSerialization.isValidJSONObject(object),
                  let once = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let parsed = try? JSONSerialization.jsonObject(with: once) else { return nil }
            return try? JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
        }
        guard let lhs, let left = canonical(lhs) else { return false }
        return left == canonical(rhs)
    }

    private static let frame = NoteToHandoffFrame(
        attachmentIndex: 0, filename: "fixture.png", position: "still",
        data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), mediaType: "image/png")

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(_ subject: Subject, _ reporter: SelfTestReporter) {
        // Cleanup-shaped routes: cleanup, prompt-prep and custom modes share CleanupClient's body.
        let cleanupShaped: [(name: String, route: LLMRouteID, surface: OllamaSurfaceProfile, check: String?)] = [
            ("cleanup", .cleanupL1, subject.cleanupSurface, cleanupThinkCheck),
            ("prompt-prep", .promptPrep, .promptPrep, nil),
            ("custom mode", .cleanupL1, .customMode, nil),
        ]
        for (index, shape) in cleanupShaped.enumerated() {
            let mac = ScriptedMac()
            let result = complete(CleanupClient.localAdapter(surface: shape.surface, transport: mac.transport),
                               request(subject.rebundle(ollamaBundle), route: shape.route,
                                       system: "fixture system prompt", user: "unused"))
            let chat = mac.chats.first
            let (context, think, alive) = wire(chat)
            if index == 0 {
                reporter.record(cleanupOnOllamaCheck,
                                mac.chats.count == 1 && mac.lmRequests.isEmpty && chat?["model"] as? String == modelID
                                    && okText(result) == ollamaReply,
                                "chats=\(mac.chats.count) lm=\(mac.lmRequests.count) result=\(result)")
            } else {
                reporter.record("\(shape.name): an (Ollama, X) bundle runs on Ollama's /api/chat",
                                mac.chats.count == 1 && mac.lmRequests.isEmpty && okText(result) == ollamaReply,
                                "chats=\(mac.chats.count) lm=\(mac.lmRequests.count)")
            }
            reporter.record(shape.check ?? "\(shape.name): the chat carries num_ctx 8192, think false, keep_alive 437",
                            context == 8192 && think == false && alive == keepAlive,
                            "num_ctx=\(context ?? -1) think=\(think.map(String.init) ?? "absent") keep_alive=\(alive ?? -1)")
            let load = mac.generates.first
            reporter.record("\(shape.name): ModelManager loaded it first with keep_alive 437 and the same num_ctx",
                            int(load?["keep_alive"]) == keepAlive
                                && int((load?["options"] as? [String: Any])?["num_ctx"]) == context)

            let lmMac = ScriptedMac()
            let lmResult = complete(CleanupClient.localAdapter(surface: shape.surface, transport: lmMac.transport),
                                 request(subject.rebundle(lmStudioBundle), route: shape.route,
                                         system: "fixture system prompt", user: "unused"))
            let expected: [String: Any] = [
                "model": modelID, "temperature": Settings.cleanupTemperature, "max_tokens": 4096, "stream": false,
                "reasoning_effort": "none",
                "messages": [["role": "system", "content": "fixture system prompt"],
                             ["role": "user", "content": CleanupClient.wrap("fixture source text")]],
            ]
            reporter.record("\(shape.name): an (LM Studio, X) bundle with the same id hits LM Studio's endpoint "
                                + "with today's body",
                            lmMac.lmRequests.count == 1 && lmMac.ollamaRequests.isEmpty
                                && lmMac.lmRequests.first?.url == Settings.cleanupEndpoint
                                && lmMac.lmRequests.first?.httpMethod == "POST"
                                && same(lmMac.lmBodies.first, expected) && okText(lmResult) == lmReply,
                            "lm=\(lmMac.lmRequests.count) ollama=\(lmMac.ollamaRequests.count)")
        }

        // Email: thinking on, and the model's reasoning never reaches the delivered text.
        do {
            let mac = ScriptedMac()
            let result = complete(EmailClient.localAdapter(transport: mac.transport),
                               request(subject.rebundle(ollamaBundle), route: .email,
                                       system: "fixture email prompt", user: "unused"))
            let (context, think, alive) = wire(mac.chats.first)
            reporter.record("email: an (Ollama, X) bundle runs on /api/chat with num_ctx 8192, think true, keep_alive 437",
                            mac.chats.count == 1 && mac.lmRequests.isEmpty && context == 8192 && think == true
                                && alive == keepAlive,
                            "num_ctx=\(context ?? -1) think=\(think.map(String.init) ?? "absent")")
            let reasoning = mac.translated.first
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .flatMap { ($0["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] }
            reporter.record("email: Ollama's thinking lands in reasoning_content and never in the delivered email",
                            reasoning?["reasoning_content"] as? String == reasoningCanary
                                && okText(result) == ollamaReply && !(okText(result) ?? "").contains("CANARY"),
                            "result=\(result)")

            let lmMac = ScriptedMac()
            let lmResult = complete(EmailClient.localAdapter(transport: lmMac.transport),
                                 request(subject.rebundle(lmStudioBundle), route: .email,
                                         system: "fixture email prompt", user: "unused"))
            let expected: [String: Any] = [
                "model": modelID, "temperature": Settings.emailTemperature, "max_tokens": Settings.emailMaxTokens,
                "stream": false, "reasoning_effort": "none",
                "messages": [["role": "system", "content": "fixture email prompt"],
                             ["role": "user", "content": EmailClient.wrap("fixture source text")]],
            ]
            reporter.record("email: an (LM Studio, X) bundle hits LM Studio's endpoint with today's body",
                            lmMac.lmRequests.count == 1 && lmMac.ollamaRequests.isEmpty
                                && lmMac.lmRequests.first?.url == Settings.emailEndpoint
                                && same(lmMac.lmBodies.first, expected) && okText(lmResult) == lmReply)
        }

        // Search synthesis: 8k, think true, reasoning kept out of the answer.
        do {
            let mac = ScriptedMac()
            let synthesis = SearchClient.makeSynthesisRequest(
                route: .searchLocalSynth, question: "fixture question", resultsBlock: "fixture results",
                selected: subject.rebundle(ollamaBundle), systemPrompt: "fixture synth prompt", timeout: 30)
            let result = SearchClient.localSynthesis(synthesis, transport: mac.transport)
            let (context, think, alive) = wire(mac.chats.first)
            reporter.record("search synthesis: an (Ollama, X) bundle runs on /api/chat with num_ctx 8192, think true, "
                                + "keep_alive 437, its reasoning out of the answer",
                            mac.chats.count == 1 && mac.lmRequests.isEmpty && context == 8192 && think == true
                                && alive == keepAlive && okText(result) == ollamaReply,
                            "num_ctx=\(context ?? -1) think=\(think.map(String.init) ?? "absent") result=\(result)")

            let lmMac = ScriptedMac()
            let lmSynthesis = SearchClient.makeSynthesisRequest(
                route: .searchLocalSynth, question: "fixture question", resultsBlock: "fixture results",
                selected: subject.rebundle(lmStudioBundle), systemPrompt: "fixture synth prompt", timeout: 30)
            let lmResult = SearchClient.localSynthesis(lmSynthesis, transport: lmMac.transport)
            let expected: [String: Any] = [
                "model": modelID, "temperature": 0.0, "max_tokens": Settings.searchSynthMaxTokens, "stream": false,
                "messages": [["role": "system", "content": "fixture synth prompt"],
                             ["role": "user", "content": lmSynthesis.userMessage]],
            ]
            reporter.record("search synthesis: an (LM Studio, X) bundle hits Settings.searchEndpoint with today's body",
                            lmMac.lmRequests.count == 1 && lmMac.ollamaRequests.isEmpty
                                && lmMac.lmRequests.first?.url == Settings.searchEndpoint
                                && same(lmMac.lmBodies.first, expected) && okText(lmResult) == lmReply)
        }

        // Search retrieval: one full tool round-trip over the translator.
        do {
            let mac = ScriptedMac()
            let ref = subject.rebundle(ollamaBundle).localRef
            let (results, failure) = SearchClient.agenticLoop(
                question: "fixture question", retrieval: ref, profile: subject.retrievalProfile,
                transport: mac.transport, webSearch: { mac.search($0) })
            let chats = mac.chats
            reporter.record(retrievalContextCheck,
                            chats.count == 2 && chats.allSatisfy {
                                let facts = wire($0)
                                return facts.context == 16384 && facts.think == false && facts.keepAlive == keepAlive
                            },
                            "chats=\(chats.count) num_ctx=\(chats.map { wire($0).context ?? -1 })")
            let toolTurn = (chats.last?["messages"] as? [[String: Any]])?.first { $0["role"] as? String == "tool" }
            let echoedCall = ((chats.last?["messages"] as? [[String: Any]])?
                .first { $0["tool_calls"] != nil }?["tool_calls"] as? [[String: Any]])?.first
            reporter.record("search retrieval: Ollama's object arguments are parsed, the search runs once with them, "
                                + "and the tool result goes back by name for the second turn",
                            failure == nil && mac.webSearches == [ollamaQuery] && results.count == 1
                                && results.first?.href == searchResults[0].href
                                && chats.first?["tools"] != nil && mac.lmRequests.isEmpty
                                && toolTurn?["tool_name"] as? String == "web_search"
                                && toolTurn?["content"] as? String == WebSearchBackend.format(searchResults)
                                && ((echoedCall?["function"] as? [String: Any])?["arguments"] as? [String: Any])?["query"]
                                    as? String == ollamaQuery,
                            "searches=\(mac.webSearches) failure=\(String(describing: failure))")

            let lmMac = ScriptedMac()
            let (lmResults, lmFailure) = SearchClient.agenticLoop(
                question: "fixture question", retrieval: subject.rebundle(lmStudioBundle).localRef,
                profile: subject.retrievalProfile, transport: lmMac.transport, webSearch: { lmMac.search($0) })
            let first = lmMac.lmBodies.first
            reporter.record("search retrieval: an (LM Studio, X) ref runs today's loop on Settings.searchEndpoint "
                                + "(tools, tool_choice auto, string arguments)",
                            lmFailure == nil && lmMac.lmRequests.count == 2 && lmMac.ollamaRequests.isEmpty
                                && lmMac.lmRequests.allSatisfy { $0.url == Settings.searchEndpoint }
                                && first?["model"] as? String == modelID && first?["tool_choice"] as? String == "auto"
                                && int(first?["max_tokens"]) == Settings.searchRetrievalMaxTokens
                                && first?["tools"] != nil && lmMac.webSearches == [lmQuery] && lmResults.count == 1,
                            "lm=\(lmMac.lmRequests.count) searches=\(lmMac.webSearches)")
        }

        // Vision: the helper's description pass, images as bare base64, then unloaded.
        do {
            let mac = ScriptedMac()
            let ref = subject.rebundle(ollamaBundle).localRef
            let described = describe(ref, mac)
            let chat = mac.chats.first
            let (context, think, alive) = wire(chat)
            let user = (chat?["messages"] as? [[String: Any]])?.last
            reporter.record("vision: an (Ollama, X) helper runs on /api/chat with num_ctx 8192, think false and the "
                                + "helper's own keep_alive 300; images go as bare base64",
                            mac.chats.count == 1 && mac.lmRequests.isEmpty && context == 8192 && think == false
                                && alive == NoteToHandoffLocalVisionClient.idleTTLSeconds
                                && (user?["images"] as? [String]) == [frame.data.base64EncodedString()],
                            "num_ctx=\(context ?? -1) keep_alive=\(alive ?? -1)")
            reporter.record("vision: the description lands and the helper is unloaded straight after",
                            described == [0: "ollama fixture description"]
                                && int(mac.generates.last?["keep_alive"]) == 0 && mac.resident[modelID] == nil,
                            "described=\(String(describing: described))")

            // Warm and cold, with the gemma-like helper: only a helper this pass loaded is unloaded.
            let helper = LocalModelRef(backend: .ollama, modelID: visionHelperID)
            let warm = ScriptedMac()
            warm.alwaysCold = subject.unloadsUnconditionally
            warm.resident[visionHelperID] = 8192
            let warmDescribed = describe(helper, warm)
            reporter.record(warmHelperCheck,
                            warmDescribed == [0: "ollama fixture description"] && warm.chats.count == 1
                                && warm.generates.isEmpty && warm.resident[visionHelperID] == 8192,
                            "generates=\(warm.generates.map { int($0["keep_alive"]) ?? -1 })")
            let cold = ScriptedMac()
            cold.alwaysCold = subject.unloadsUnconditionally
            let coldDescribed = describe(helper, cold)
            reporter.record("vision: an (Ollama, gemma4-fixture) helper the pass cold-loaded IS unloaded after it",
                            coldDescribed == [0: "ollama fixture description"]
                                && cold.generates.map { int($0["keep_alive"]) } == [300, 0]
                                && cold.resident[visionHelperID] == nil,
                            "generates=\(cold.generates.map { int($0["keep_alive"]) ?? -1 })")

            let lmMac = ScriptedMac()
            lmMac.alwaysCold = subject.unloadsUnconditionally
            let lmDescribed = describe(subject.rebundle(lmStudioBundle).localRef, lmMac)
            let expected = NoteToHandoffLocalVisionClient.requestBody(model: modelID, frames: [frame])
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            reporter.record("vision: an (LM Studio, X) helper hits the cleanup endpoint with today's body, then "
                                + "LM Studio unloads it",
                            lmMac.lmRequests.count == 1 && lmMac.ollamaRequests.isEmpty
                                && lmMac.lmRequests.first?.url == Settings.cleanupEndpoint
                                && expected.map { same(lmMac.lmBodies.first, $0) } == true
                                && lmDescribed == [0: "lm fixture description"] && lmMac.lmUnloads == [modelID])
            let lmWarm = ScriptedMac()
            lmWarm.alwaysCold = subject.unloadsUnconditionally
            lmWarm.lmColdLoad = false
            let lmWarmDescribed = describe(subject.rebundle(lmStudioBundle).localRef, lmWarm)
            reporter.record("vision: an (LM Studio, X) helper that was already resident is NOT unloaded after the pass",
                            lmWarmDescribed == [0: "lm fixture description"] && lmWarm.lmUnloads.isEmpty,
                            "unloads=\(lmWarm.lmUnloads)")
        }
    }

    private static func describe(_ ref: LocalModelRef, _ mac: ScriptedMac) -> [Int: String]? {
        let done = DispatchSemaphore(value: 0)
        var described: [Int: String]?
        NoteToHandoffLocalVisionClient.describe(ref: ref, frames: [frame], transport: mac.transport) {
            described = $0
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return described
    }

    // MARK: - D5 on the wire

    private static func checkResidentContextReuse(_ reporter: SelfTestReporter) {
        print("--- D5: a larger resident context is reused and sent as it is ---")
        let mac = ScriptedMac()
        mac.resident[modelID] = 32768
        let result = complete(CleanupClient.localAdapter(surface: .cleanup, transport: mac.transport),
                           request(ollamaBundle, route: .cleanupL1, system: "fixture system prompt", user: "unused"))
        reporter.record("cleanup on a model resident at 32768 sends num_ctx 32768 (no reload) and loads nothing",
                        wire(mac.chats.first).context == 32768 && mac.generates.isEmpty && okText(result) == ollamaReply,
                        "num_ctx=\(wire(mac.chats.first).context ?? -1) generates=\(mac.generates.count)")
        let small = ScriptedMac()
        small.resident[modelID] = 4096
        _ = complete(CleanupClient.localAdapter(surface: .cleanup, transport: small.transport),
                  request(ollamaBundle, route: .cleanupL1, system: "fixture system prompt", user: "unused"))
        reporter.record("cleanup on a model resident at 4096 reloads it at 8192 and chats at 8192",
                        small.generates.count == 1 && wire(small.chats.first).context == 8192)
    }

    private static func checkVisionHelperChoice(_ reporter: SelfTestReporter) {
        print("--- the Ollama vision helper is the smallest model that can see ---")
        func model(_ id: String, _ size: Int64?, vision: Bool) -> LocalInstalledModel {
            LocalInstalledModel(ref: LocalModelRef(backend: .ollama, modelID: id), label: id, sizeBytes: size,
                                isVision: vision, supportsTools: nil, supportsThinking: nil)
        }
        let catalog = [model("ollama-fixture-big-vl:8b", 6_000_000_000, vision: true),
                       model("ollama-fixture-tiny-text:1b", 800_000_000, vision: false),
                       model("ollama-fixture-small-vl:2b", 1_900_000_000, vision: true),
                       model("ollama-fixture-unsized-vl:latest", nil, vision: true)]
        reporter.record("smallestVision picks the smallest sized vision model, never a smaller text-only one",
                        LocalInstalledModel.smallestVision(in: catalog)?.ref.modelID == "ollama-fixture-small-vl:2b"
                            && LocalInstalledModel.smallestVision(in: [catalog[1]]) == nil
                            && LocalInstalledModel.smallestVision(in: nil) == nil)
    }

    // MARK: - Production call sites

    /// The clients above are only half the wiring: each route's call site must hand them the adapter that
    /// reads the resolved bundle. Read from the worktree root, comments stripped.
    private static func checkProductionCallSites(_ reporter: SelfTestReporter) {
        print("--- production call sites hand each route the backend-aware adapter ---")
        func source(_ name: String) -> String {
            let text = (try? String(contentsOfFile: "Sources/App/\(name)", encoding: .utf8)) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }.joined(separator: "\n")
        }
        let dictation = source("DictationController.swift")
        let registry = source("OneShotRegistry.swift")
        let custom = source("CustomModeClient.swift")
        let search = source("SearchClient.swift")
        let vision = source("NoteToHandoffVision.swift")
        reporter.record("the call sites are readable from the worktree root",
                        ![dictation, registry, custom, search, vision].contains(""),
                        "run this gate from the repository root")
        reporter.record("cleanup, prompt-prep, email and custom modes use the backend-aware adapters",
                        dictation.contains("local: CleanupClient.localAdapter(surface: .cleanup)")
                            && registry.contains("local: CleanupClient.localAdapter(surface: .promptPrep)")
                            && registry.contains("local: EmailClient.localAdapter()")
                            && custom.contains("local: CleanupClient.localAdapter(surface: .customMode)"))
        let blind = ["DictationController.swift", "OneShotRegistry.swift", "CustomModeClient.swift",
                     "StickySkillCoordinator.swift", "PromptTestBench.swift"]
            .filter { source($0).contains("CleanupClient.cleanup(") || source($0).contains("EmailClient.email(") }
        reporter.record("no route calls CleanupClient.cleanup or EmailClient.email around the adapters",
                        blind.isEmpty, blind.joined(separator: ", "))
        reporter.record("search runs retrieval on the route's (app, model) and synthesis through localSynthesis",
                        search.contains("let retrieval = retrievalModelRef()")
                            && search.contains("agenticLoop(question: question, retrieval: retrieval)")
                            && search.contains("local: { localSynthesis($0) }"))
        reporter.record("the vision pass picks its helper and describer on the route's app",
                        vision.contains("localBackendLookup(mode) == .ollama")
                            && vision.contains("NoteToHandoffLocalVisionClient.describe(ref: ref"))
    }

    // MARK: - reasoning-off (the LM Studio send path only)

    /// The model id the fallback checks use; deliberately distinct from `modelID` so marking it
    /// "rejects the field" for the rest of the process cannot disturb any other check.
    private static let reasoningOffFallbackModelID = "reasoning-off-fallback:7b"

    /// Cleanup/selection transforms, email and the tail-check judge ask LM Studio for
    /// `reasoning_effort: none`; a model that rejects it is retried once without it and remembered;
    /// Ollama and the web-search loop are untouched.
    private static func checkReasoningOff(_ reporter: SelfTestReporter) {
        print("--- reasoning-off: LM Studio cleanup/selection/email/judge bodies, 400 fallback, Ollama untouched ---")

        // (a) cleanup exact LM Studio body, every old key unchanged.
        do {
            let mac = ScriptedMac()
            let result = complete(CleanupClient.localAdapter(surface: .cleanup, transport: mac.transport),
                                  request(lmStudioBundle, route: .cleanupL1,
                                          system: "fixture system prompt", user: "unused"))
            let expected: [String: Any] = [
                "model": modelID, "temperature": Settings.cleanupTemperature, "max_tokens": 4096,
                "stream": false, "reasoning_effort": "none",
                "messages": [["role": "system", "content": "fixture system prompt"],
                             ["role": "user", "content": CleanupClient.wrap("fixture source text")]],
            ]
            reporter.record(
                "reasoning-off: cleanup LM Studio body carries reasoning_effort none with every old key unchanged",
                mac.lmRequests.count == 1 && same(mac.lmBodies.first, expected)
                    && okText(result) == lmReply,
                "reasoning_effort=\(mac.lmBodies.first?["reasoning_effort"] as? String ?? "absent")")
        }

        // (b) Option+P selection transform, through the same adapter the registry's row uses.
        do {
            let mac = ScriptedMac()
            let result = complete(CleanupClient.localAdapter(surface: .promptPrep, transport: mac.transport),
                                  request(lmStudioBundle, route: .promptPrep,
                                          system: "fixture prep prompt", user: "unused"))
            reporter.record(
                "reasoning-off: Option+P selection transform LM Studio body carries reasoning_effort none",
                mac.lmRequests.count == 1
                    && mac.lmBodies.first?["reasoning_effort"] as? String == "none"
                    && okText(result) == lmReply,
                "reasoning_effort=\(mac.lmBodies.first?["reasoning_effort"] as? String ?? "absent")")
        }

        // (b2) email cleanup.
        do {
            let mac = ScriptedMac()
            let result = complete(EmailClient.localAdapter(transport: mac.transport),
                                  request(lmStudioBundle, route: .email,
                                          system: "fixture email prompt", user: "unused"))
            reporter.record(
                "reasoning-off: email cleanup LM Studio body carries reasoning_effort none",
                mac.lmRequests.count == 1
                    && mac.lmBodies.first?["reasoning_effort"] as? String == "none"
                    && okText(result) == lmReply,
                "reasoning_effort=\(mac.lmBodies.first?["reasoning_effort"] as? String ?? "absent")")
        }

        // (b3) tail-check judge.
        do {
            let mac = ScriptedMac()
            let judgeModel = "reasoning-off-judge:7b"
            let judge = LocalRouteTailJudge(
                routeResolver: { .pinned(.local(judgeModel)) }, transport: mac.transport)
            let done = DispatchSemaphore(value: 0)
            judge.judge(context: "fixture context", tail: "fixture tail", timeoutMs: 400) { _ in done.signal() }
            _ = done.wait(timeout: .now() + 5)
            let body = mac.lmBodies.first
            let userCount = ((body?["messages"] as? [[String: Any]]) ?? [])
                .filter { $0["role"] as? String == "user" }.count
            reporter.record(
                "reasoning-off: tail-check judge LM Studio body carries reasoning_effort none and one user message",
                mac.lmRequests.count == 1 && body?["reasoning_effort"] as? String == "none" && userCount == 1,
                "reasoning_effort=\(body?["reasoning_effort"] as? String ?? "absent") users=\(userCount)")
        }

        // (c)+(d) a 400 rejection retries once without the field and is remembered.
        do {
            let fallbackModel = reasoningOffFallbackModelID
            var sentBodies: [[String: Any]] = []
            let transport = LocalChatTransport(
                sendLMStudio: { request, completion in
                    let body = request.httpBody
                        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                    sentBodies.append(body)
                    let url = request.url ?? Settings.cleanupEndpoint
                    if body["reasoning_effort"] == nil {
                        let reply: [String: Any] = ["choices": [[
                            "index": 0, "message": ["role": "assistant", "content": lmReply],
                            "finish_reason": "stop",
                        ]]]
                        completion(try? JSONSerialization.data(withJSONObject: reply),
                                   HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                   headerFields: nil), nil)
                    } else {
                        let error = #"{"error":{"message":"unknown field reasoning_effort"}}"#
                        completion(error.data(using: .utf8),
                                   HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1",
                                                   headerFields: nil), nil)
                    }
                },
                prepareLMStudio: { _, _ in (.ready, false) },
                unloadLMStudio: { _ in },
                prepareOllama: { _, context, _ in (.ready, context, false) },
                chatOllama: { _, _, _, _, _ in (nil, nil, nil) },
                unloadOllama: { _ in },
                keepAliveSeconds: { keepAlive },
                beginRequest: { _ in },
                endRequest: { _ in })

            let first = complete(CleanupClient.localAdapter(surface: .cleanup, transport: transport),
                                 request(LLMProviderBundle.local(fallbackModel), route: .cleanupL1,
                                         system: "fixture system prompt", user: "unused"))
            reporter.record(
                "reasoning-off: an LM Studio 400 naming the field retries once without it and returns the good result",
                sentBodies.count == 2 && sentBodies[0]["reasoning_effort"] as? String == "none"
                    && sentBodies[1]["reasoning_effort"] == nil && okText(first) == lmReply,
                "calls=\(sentBodies.count) fields=\(sentBodies.map { $0["reasoning_effort"] as? String ?? "absent" })")

            let second = complete(CleanupClient.localAdapter(surface: .cleanup, transport: transport),
                                  request(LLMProviderBundle.local(fallbackModel), route: .cleanupL1,
                                          system: "fixture system prompt", user: "unused"))
            reporter.record(
                "reasoning-off: after a rejection the same model id is never sent the field again",
                sentBodies.count == 3 && sentBodies[2]["reasoning_effort"] == nil && okText(second) == lmReply,
                "calls=\(sentBodies.count) last=\(sentBodies.last?["reasoning_effort"] as? String ?? "absent")")
        }

        // (e) web-search synthesis and the tool loop never carry the field.
        do {
            let mac = ScriptedMac()
            let synthesis = SearchClient.makeSynthesisRequest(
                route: .searchLocalSynth, question: "fixture question", resultsBlock: "fixture results",
                selected: lmStudioBundle, systemPrompt: "fixture synth prompt", timeout: 30)
            _ = SearchClient.localSynthesis(synthesis, transport: mac.transport)
            let retrievalMac = ScriptedMac()
            _ = SearchClient.agenticLoop(
                question: "fixture question", retrieval: lmStudioBundle.localRef,
                transport: retrievalMac.transport, webSearch: { retrievalMac.search($0) })
            reporter.record(
                "reasoning-off: web-search synthesis and tool-loop bodies never carry reasoning_effort",
                !mac.lmBodies.isEmpty && !retrievalMac.lmBodies.isEmpty
                    && mac.lmBodies.allSatisfy { $0["reasoning_effort"] == nil }
                    && retrievalMac.lmBodies.allSatisfy { $0["reasoning_effort"] == nil },
                "synth=\(mac.lmBodies.count) retrieval=\(retrievalMac.lmBodies.count)")
        }

        // (f) Ollama's shared body is unchanged, key and all.
        do {
            let mac = ScriptedMac()
            _ = complete(CleanupClient.localAdapter(surface: .cleanup, transport: mac.transport),
                         request(ollamaBundle, route: .cleanupL1,
                                 system: "fixture system prompt", user: "unused"))
            let expected: [String: Any] = [
                "model": modelID, "temperature": Settings.cleanupTemperature, "max_tokens": 4096,
                "stream": false,
                "messages": [["role": "system", "content": "fixture system prompt"],
                             ["role": "user", "content": CleanupClient.wrap("fixture source text")]],
            ]
            reporter.record(
                "reasoning-off: the shared Ollama cleanup body is byte-for-byte unchanged (no reasoning_effort)",
                mac.chats.count == 1 && same(mac.ollamaChatBodies.first, expected)
                    && mac.ollamaChatBodies.first?["reasoning_effort"] == nil,
                "reasoning_effort=\(mac.ollamaChatBodies.first?["reasoning_effort"] as? String ?? "absent")")
        }
    }

    // MARK: - stall-timeout (opted-in streaming, guard: the tail judge is not opted in)

    /// The LM Studio send closure's session seam and a scripted wire, no socket and no model. Every
    /// `stall-timeout: new:` check asserts behaviour that did not exist before the streaming sender.
    private static func checkStallTimeout(_ reporter: SelfTestReporter) {
        print("--- stall-timeout: opted-in streaming, stall window and hard ceiling ---")
        let stubbed = { stubSession() }

        // (a) content and reasoning deltas accumulate; [DONE] ends the stream while the source is STILL
        // OPEN. The script deliberately never closes after `[DONE]`, so an implementation that waits for
        // the transport to close instead of acting on the marker cannot pass (the old script closed 20 ms
        // after `[DONE]`, which is exactly why the defect slipped through).
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(reasoning: "think ").utf8)),
                .init(delay: 0.02, data: Data(sseEvent(content: "Hello").utf8)),
                .init(delay: 0.02, data: Data(sseEvent(content: " world").utf8)),
                .init(delay: 0.02, data: Data(sseDone.utf8)),
                .init(delay: 4.0, data: nil), // never reached before the assertion; [DONE] must end the stream
            ]))
            let started = Date()
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []], timeout: 0.6),
                               LocalStreamSender.sender(session: stubbed()))
            let elapsed = Date().timeIntervalSince(started)
            let fields = messageFields(out.data)
            // No elapsed bound here: the first streamed session pays a one-time URLProtocol cold start.
            // `out.error == nil` (not `.timedOut`) already proves the completion came from `[DONE]` and
            // not from the stall window, since the source never closes.
            reporter.record("stall-timeout: new: SSE content and reasoning deltas accumulate and [DONE] ends the stream",
                            fields.content == "Hello world" && fields.reasoning == "think " && out.error == nil
                                && !isTimedOut(out),
                            "content=\(fields.content ?? "nil") reasoning=\(fields.reasoning ?? "nil") elapsed=\(String(format: "%.3f", elapsed))")
        }

        // (b) [DONE] then a source that stays open far past the stall window: the request must return the
        // complete answer promptly (never `.timedOut`) instead of waiting for the connection to close.
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "Complete").utf8)),
                .init(delay: 0.05, data: Data(sseDone.utf8)),
                .init(delay: 3.0, data: nil), // held open longer than the 1.0 s stall window, after [DONE]
            ]))
            let started = Date()
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []], timeout: 1.0),
                               LocalStreamSender.sender(session: stubbed()))
            let elapsed = Date().timeIntervalSince(started)
            reporter.record("stall-timeout: new: [DONE] with the source left open past the stall window returns the full answer promptly",
                            messageFields(out.data).content == "Complete" && out.error == nil && !isTimedOut(out)
                                && elapsed < 0.8,
                            "content=\(messageFields(out.data).content ?? "nil") error=\(String(describing: out.error)) elapsed=\(String(format: "%.3f", elapsed))")
        }

        // (c) EOF arrives after [DONE]: completion is delivered exactly once (a later
        // `didCompleteWithError` must be a no-op) and it happens at [DONE], not at the EOF.
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "once").utf8)),
                .init(delay: 0.10, data: Data(sseDone.utf8)),
                .init(delay: 0.80, data: nil), // the old "success" path: EOF after [DONE]
            ]))
            let out = sendCounting(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                                  "messages": []], timeout: 1.0),
                                   LocalStreamSender.sender(session: stubbed()))
            reporter.record("stall-timeout: new: [DONE] completes exactly once when EOF follows and never a second time",
                            out.completions == 1 && messageFields(out.data).content == "once" && out.error == nil
                                && out.firstElapsed < 0.7,
                            "completions=\(out.completions) content=\(messageFields(out.data).content ?? "nil") firstElapsed=\(String(format: "%.3f", out.firstElapsed))")
        }

        // (d) the stall polling detects silence no later than window + window/4 + epsilon (short windows,
        // no long sleeps): one token then quiet must fail `.timedOut` inside the bound.
        do {
            LMStudioStreamStubProtocol.reset()
            let window: TimeInterval = 0.3
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "tick").utf8)),
                .init(delay: 2.0, data: nil), // a backstop finish, long past the stall window
            ]))
            let started = Date()
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []], timeout: window),
                               LocalStreamSender.sender(session: stubbed()))
            let elapsed = Date().timeIntervalSince(started)
            let bound = window + window / 4 + 0.2
            reporter.record("stall-timeout: guard: stall polling detects silence no later than window + window/4 + epsilon",
                            isTimedOut(out) && elapsed >= window * 0.5 && elapsed <= bound,
                            "timedOut=\(isTimedOut(out)) elapsed=\(String(format: "%.3f", elapsed)) bound=\(String(format: "%.3f", bound))")
        }

        // guard: a stream that never sends [DONE] and closes normally still completes on EOF.
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "eof").utf8)),
                .init(delay: 0.05, data: Data(sseEvent(content: " answer").utf8)),
                .init(delay: 0.05, data: nil),
            ]))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []], timeout: 1.0),
                               LocalStreamSender.sender(session: stubbed()))
            reporter.record("stall-timeout: new: a stream with no [DONE] that closes normally still completes on EOF",
                            messageFields(out.data).content == "eof answer" && out.error == nil,
                            "content=\(messageFields(out.data).content ?? "nil") error=\(String(describing: out.error))")
        }

        // (a) an event split across two network chunks still parses, and a keep-alive comment is ignored.
        do {
            LMStudioStreamStubProtocol.reset()
            let first = "data: {\"choices\":[{\"delta\":{\"cont"
            let second = "ent\":\"split\"}}]}\n\n"
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(first.utf8)),
                .init(delay: 0.02, data: Data(second.utf8)),
                .init(delay: 0.02, data: Data(": keep-alive\n\n".utf8)),
                .init(delay: 0.02, data: Data(sseEvent(content: " together").utf8)),
                .init(delay: 0.02, data: Data(sseDone.utf8)),
                .init(delay: 0.02, data: nil),
            ]))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []]), LocalStreamSender.sender(session: stubbed()))
            reporter.record("stall-timeout: new: SSE events split across chunk boundaries parse and a keep-alive comment is ignored",
                            messageFields(out.data).content == "split together" && out.error == nil,
                            "content=\(messageFields(out.data).content ?? "nil")")
        }

        // (a) malformed JSON in one event never crashes; later content still arrives.
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data("data: {not json}\n\n".utf8)),
                .init(delay: 0.02, data: Data(sseEvent(content: "ok").utf8)),
                .init(delay: 0.02, data: Data(sseDone.utf8)),
                .init(delay: 0.02, data: nil),
            ]))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []]), LocalStreamSender.sender(session: stubbed()))
            reporter.record("stall-timeout: new: malformed JSON in one event does not crash and later content still arrives",
                            messageFields(out.data).content == "ok" && out.error == nil,
                            "content=\(messageFields(out.data).content ?? "nil") error=\(String(describing: out.error))")
        }

        // (b) the re-assembled JSON is the exact non-stream shape CleanupClient classifies to .ok(text).
        do {
            LMStudioStreamStubProtocol.reset()
            let usage: [String: Any] = ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "Clean text.", usage: usage).utf8)),
                .init(delay: 0.02, data: Data(sseDone.utf8)),
                .init(delay: 0.02, data: nil),
            ]))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false,
                                              "messages": []]), LocalStreamSender.sender(session: stubbed()))
            let object = out.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let message = (object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            var classifiedOK = false
            if case .content(let text) = CleanupClient.classifyChatResponse(
                data: out.data, response: out.response, error: out.error, logPrefix: "stall", elapsed: 0) {
                classifiedOK = text == "Clean text."
            }
            reporter.record("stall-timeout: new: re-assembled stream JSON feeds CleanupClient's classifier to .ok(text)",
                            message?["role"] as? String == "assistant" && message?["content"] as? String == "Clean text."
                                && object?["usage"] != nil && classifiedOK,
                            "content=\(message?["content"] as? String ?? "nil") usage=\(object?["usage"] != nil)")
        }

        // (c) a slow stream longer than the fixed window succeeds when every gap is under the stall window.
        do {
            LMStudioStreamStubProtocol.reset()
            let stall: TimeInterval = 0.5
            var chunks: [LMStudioStreamStubProtocol.Chunk] = []
            for index in 0..<6 {
                chunks.append(.init(delay: index == 0 ? 0 : 0.15,
                                    data: Data(sseEvent(content: "c\(index)").utf8)))
            }
            chunks.append(.init(delay: 0.15, data: Data(sseDone.utf8)))
            chunks.append(.init(delay: 0.05, data: nil))
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: chunks))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false, "messages": []], timeout: stall),
                               LocalStreamSender.sender(session: stubbed()))
            reporter.record("stall-timeout: new: a slow stream longer than the fixed window with every gap under the stall window succeeds",
                            messageFields(out.data).content == "c0c1c2c3c4c5" && out.error == nil,
                            "content=\(messageFields(out.data).content ?? "nil") error=\(String(describing: out.error))")
        }

        // (d) a stream silent past the stall window fails .timedOut.
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 2.0, data: nil), // a backstop finish, long past the stall window
            ]))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false, "messages": []],
                                       timeout: 0.3),
                               LocalStreamSender.sender(session: stubbed()))
            let streamedBody = LMStudioStreamStubProtocol.snapshot().bodies.first?["stream"] as? Bool
            reporter.record("stall-timeout: new: a stream silent longer than the stall window fails .timedOut",
                            isTimedOut(out) && out.data == nil && streamedBody == true,
                            "error=\(String(describing: out.error)) data=\(out.data?.count ?? -1) stream=\(String(describing: streamedBody))")
        }

        // (e) reasoning-only deltas reset the stall clock; a following content delta succeeds.
        do {
            LMStudioStreamStubProtocol.reset()
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(reasoning: "r0").utf8)),
                .init(delay: 0.15, data: Data(sseEvent(reasoning: "r1").utf8)),
                .init(delay: 0.15, data: Data(sseEvent(reasoning: "r2").utf8)),
                .init(delay: 0.15, data: Data(sseEvent(content: "answer").utf8)),
                .init(delay: 0.15, data: Data(sseDone.utf8)),
                .init(delay: 0.10, data: nil),
            ]))
            let out = sendSync(optedIn(body: ["model": "stall-fixture:7b", "stream": false, "messages": []],
                                       timeout: 0.5),
                               LocalStreamSender.sender(session: stubbed()))
            let fields = messageFields(out.data)
            reporter.record("stall-timeout: new: reasoning-only deltas reset the stall clock and a later content delta succeeds",
                            fields.content == "answer" && fields.reasoning == "r0r1r2" && out.error == nil,
                            "content=\(fields.content ?? "nil") reasoning=\(fields.reasoning ?? "nil")")
        }

        // (f) the hard ceiling stops an endless trickle (injected clock; no 45 s wait).
        do {
            let policy = LocalStreamStallPolicy(stallWindow: 12)
            let start = Date()
            var clock = LocalStreamProgressClock(policy: policy, startedAt: start)
            var now = start
            for _ in 0..<48 {
                now = now.addingTimeInterval(1)
                clock.recordProgress(at: now)
            }
            let verdict = clock.verdict(at: start.addingTimeInterval(policy.hardCeiling))
            let classified = isTimedOut((data: nil, response: nil,
                                        error: LocalStreamStallPolicy.timedOutError()))
            reporter.record("stall-timeout: new: the hard ceiling stops an endless trickle with .timedOut",
                            policy.hardCeiling == 48 && verdict == .ceiling && classified,
                            "ceiling=\(policy.hardCeiling) verdict=\(String(describing: verdict))")
        }

        // (g) an ordinary request keeps today's untouched dataTask path; an opted-in one streams.
        do {
            LMStudioStreamStubProtocol.reset()
            let session = stubbed()
            let sender = LocalStreamSender.sender(session: session)
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "application/json", chunks: [
                .init(delay: 0, data: plainMessageJSON("plain answer")),
                .init(delay: 0.02, data: nil),
            ]))
            let plain = LMStudioReasoningEffort.request(
                ["model": "stall-fixture:7b", "stream": false, "messages": []],
                endpoint: Settings.cleanupEndpoint, timeout: 2, progressTimeout: false)!
            let plainOut = sendSync(plain, sender)
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "streamed answer").utf8)),
                .init(delay: 0.02, data: Data(sseDone.utf8)),
                .init(delay: 0.02, data: nil),
            ]))
            let opted = optedIn(body: ["model": "stall-fixture:7b", "stream": false, "messages": []])
            let optedOut = sendSync(opted, sender)
            let snapshot = LMStudioStreamStubProtocol.snapshot()
            let plainStream = snapshot.bodies.first?["stream"] as? Bool
            let optedStream = snapshot.bodies.count > 1 ? snapshot.bodies[1]["stream"] as? Bool : nil
            reporter.record("stall-timeout: new: a non-opted-in request takes the untouched dataTask path",
                            messageFields(plainOut.data).content == "plain answer" && plainStream == false
                                && messageFields(optedOut.data).content == "streamed answer" && optedStream == true,
                            "plainStream=\(String(describing: plainStream)) optedStream=\(String(describing: optedStream))")
        }

        // (h) a 400 error body passes through unchanged so the retry-without-field gets the good stream.
        do {
            LMStudioStreamStubProtocol.reset()
            let retryModel = "stall-timeout-retry:7b"
            LMStudioStreamStubProtocol.queue(.init(status: 400, contentType: "application/json", chunks: [
                .init(delay: 0, data: Data("{\"error\":\"unknown field\"}".utf8)),
                .init(delay: 0.02, data: nil),
            ]))
            LMStudioStreamStubProtocol.queue(.init(status: 200, contentType: "text/event-stream", chunks: [
                .init(delay: 0, data: Data(sseEvent(content: "retry answer").utf8)),
                .init(delay: 0.02, data: Data(sseDone.utf8)),
                .init(delay: 0.02, data: nil),
            ]))
            let transport = stallTransport(session: stubbed())
            let result = complete(CleanupClient.localAdapter(surface: .cleanup, transport: transport),
                                  request(LLMProviderBundle.local(retryModel), route: .cleanupL1,
                                          system: "fixture system prompt", user: "unused"))
            let snapshot = LMStudioStreamStubProtocol.snapshot()
            reporter.record("stall-timeout: new: a 400 error body passes through unchanged so retry-without-reasoning_effort returns the good stream",
                            okText(result) == "retry answer" && snapshot.requests.count == 2
                                && snapshot.bodies.first?["reasoning_effort"] as? String == "none"
                                && snapshot.bodies.count > 1 && snapshot.bodies[1]["reasoning_effort"] == nil,
                            "result=\(result) calls=\(snapshot.requests.count)")
        }

        // guard: the tail-check judge resolves LM Studio but must stay on the untouched non-streaming path.
        do {
            var caught: URLRequest?
            let transport = LocalChatTransport(
                sendLMStudio: { req, completion in
                    caught = req
                    completion(plainMessageJSON("{\"tail\":\"clean\"}"),
                               req.url.flatMap {
                                   HTTPURLResponse(url: $0, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
                               }, nil)
                },
                prepareLMStudio: { _, _ in (.ready, false) },
                unloadLMStudio: { _ in },
                prepareOllama: { _, context, _ in (.ready, context, false) },
                chatOllama: { _, _, _, _, _ in (nil, nil, nil) },
                unloadOllama: { _ in },
                keepAliveSeconds: { keepAlive },
                beginRequest: { _ in },
                endRequest: { _ in })
            let judge = LocalRouteTailJudge(routeResolver: { .pinned(.local("stall-guard-judge:7b")) },
                                           transport: transport)
            let done = DispatchSemaphore(value: 0)
            judge.judge(context: "fixture context", tail: "fixture tail", timeoutMs: 400) { _ in done.signal() }
            _ = done.wait(timeout: .now() + 5)
            let header = caught?.value(forHTTPHeaderField: LocalStreamSender.progressHeader)
            let streamed = caught?.httpBody.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }?["stream"] as? Bool
            reporter.record("stall-timeout: guard: the tail-check judge request is not opted in (no progress header, stream false)",
                            caught != nil && header == nil && streamed == false,
                            "header=\(header ?? "absent") stream=\(String(describing: streamed))")
        }
    }

    /// An opted-in request body: a header-bearing `LMStudioReasoningEffort.request` with the default
    /// `stream: false` the clients still build (the sender sets the stream copy itself).
    private static func optedIn(body: [String: Any], timeout: TimeInterval = 2) -> URLRequest {
        LMStudioReasoningEffort.request(body, endpoint: Settings.cleanupEndpoint,
                                        timeout: timeout, progressTimeout: true)!
    }

    /// The transport shape the stall checks need: the real streaming sender over a scripted session,
    /// every other seam inert.
    private static func stallTransport(session: URLSession) -> LocalChatTransport {
        LocalChatTransport(
            sendLMStudio: LocalStreamSender.sender(session: session),
            prepareLMStudio: { _, _ in (.ready, false) },
            unloadLMStudio: { _ in },
            prepareOllama: { _, context, _ in (.ready, context, false) },
            chatOllama: { _, _, _, _, _ in (nil, nil, nil) },
            unloadOllama: { _ in },
            keepAliveSeconds: { keepAlive },
            beginRequest: { _ in },
            endRequest: { _ in })
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LMStudioStreamStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @discardableResult
    private static func sendSync(_ request: URLRequest,
                                 _ sender: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void)
        -> (data: Data?, response: URLResponse?, error: Error?) {
        let done = DispatchSemaphore(value: 0)
        var data: Data?
        var response: URLResponse?
        var error: Error?
        sender(request) { d, r, e in
            data = d
            response = r
            error = e
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return (data, response, error)
    }

    /// Like `sendSync`, but counts every completion call and records how soon the first one arrived, so a
    /// second `didCompleteWithError` after `[DONE]` is visible. The settle sleep (well under 2 s) lets an
    /// incorrect second completion arrive before the count is read.
    @discardableResult
    private static func sendCounting(_ request: URLRequest,
                                     _ sender: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void,
                                     settle: TimeInterval = 0.3)
        -> (data: Data?, response: URLResponse?, error: Error?, completions: Int, firstElapsed: TimeInterval) {
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var data: Data?
        var response: URLResponse?
        var error: Error?
        var completions = 0
        var firstElapsed = TimeInterval.infinity
        sender(request) { d, r, e in
            lock.lock()
            completions += 1
            let first = completions == 1
            if first {
                data = d
                response = r
                error = e
                firstElapsed = Date().timeIntervalSince(started)
            }
            lock.unlock()
            if first { done.signal() }
        }
        _ = done.wait(timeout: .now() + 5)
        Thread.sleep(forTimeInterval: settle)
        lock.lock(); defer { lock.unlock() }
        return (data, response, error, completions, firstElapsed)
    }

    private static func messageFields(_ data: Data?) -> (content: String?, reasoning: String?) {
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        else { return (nil, nil) }
        return (message["content"] as? String, message["reasoning_content"] as? String)
    }

    private static func isTimedOut(_ out: (data: Data?, response: URLResponse?, error: Error?)) -> Bool {
        if case .failure(.timedOut) = CleanupClient.classifyChatResponse(
            data: out.data, response: out.response, error: out.error, logPrefix: "stall", elapsed: 0) {
            return true
        }
        return false
    }

    private static let sseDone = "data: [DONE]\n\n"

    private static func sseEvent(content: String? = nil, reasoning: String? = nil,
                                 usage: [String: Any]? = nil) -> String {
        var delta: [String: Any] = [:]
        if let content { delta["content"] = content }
        if let reasoning { delta["reasoning_content"] = reasoning }
        var object: [String: Any] = ["choices": [["index": 0, "delta": delta]]]
        if let usage { object["usage"] = usage }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private static func plainMessageJSON(_ content: String) -> Data {
        let message: [String: Any] = ["role": "assistant", "content": content]
        let object: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": "stop"]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A scripted URLProtocol that feeds SSE chunks on a schedule with no socket. Non-2xx replies carry
    /// a raw JSON error body, exactly as LM Studio's 400 does.
    private final class LMStudioStreamStubProtocol: URLProtocol {
        struct Chunk {
            let delay: TimeInterval
            let data: Data? // nil finishes loading
        }
        struct Reply {
            let status: Int
            let contentType: String
            let chunks: [Chunk]
        }

        private static let lock = NSLock()
        private static var replies: [Reply] = []
        private static var recordedRequests: [URLRequest] = []
        private static var recordedBodies: [[String: Any]] = []

        private var pendingChunks: [Chunk] = []
        private let deliveryQueue = DispatchQueue(label: "viddydictate.stall-stub.delivery")

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            replies = []
            recordedRequests = []
            recordedBodies = []
        }

        static func queue(_ reply: Reply) {
            lock.lock(); defer { lock.unlock() }
            replies.append(reply)
        }

        static func snapshot() -> (requests: [URLRequest], bodies: [[String: Any]]) {
            lock.lock(); defer { lock.unlock() }
            return (recordedRequests, recordedBodies)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            LMStudioStreamStubProtocol.lock.lock()
            LMStudioStreamStubProtocol.recordedRequests.append(request)
            if let body = LMStudioStreamStubProtocol.body(of: request) {
                LMStudioStreamStubProtocol.recordedBodies.append(body)
            }
            let reply = LMStudioStreamStubProtocol.replies.isEmpty
                ? nil : LMStudioStreamStubProtocol.replies.removeFirst()
            LMStudioStreamStubProtocol.lock.unlock()

            guard let reply else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let url = request.url ?? URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": reply.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            pendingChunks = reply.chunks
            deliver(index: 0)
        }

        /// Deliver one chunk at a time, scheduling the next only after the previous landed, so even a
        /// 20 ms gap cannot reorder chunks on a concurrent queue.
        private func deliver(index: Int) {
            guard index < pendingChunks.count else { return }
            let chunk = pendingChunks[index]
            deliveryQueue.asyncAfter(deadline: .now() + chunk.delay) { [weak self] in
                guard let self else { return }
                if let data = chunk.data {
                    self.client?.urlProtocol(self, didLoad: data)
                    self.deliver(index: index + 1)
                } else {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }

        override func stopLoading() {}

        /// URLSession hands a custom protocol the body as a stream more often than as `httpBody`.
        private static func body(of request: URLRequest) -> [String: Any]? {
            if let data = request.httpBody {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) The resolved app is dropped: every bundle is rewritten as an LM Studio one.
        var ignoresApp = Subject()
        ignoresApp.rebundle = { LLMProviderBundle.local($0.modelID) }
        requireCaught(reporter, mutant: "clients that ignore the resolved app (always LM Studio)",
                      by: cleanupOnOllamaCheck) { checkContract(ignoresApp, $0) }

        // (b) Retrieval with the 8k profile.
        var smallRetrieval = Subject()
        smallRetrieval.retrievalProfile = OllamaSurfaceProfile(contextTokens: 8192, think: false)
        requireCaught(reporter, mutant: "search retrieval at 8192", by: retrievalContextCheck) {
            checkContract(smallRetrieval, $0)
        }

        // (c) Cleanup asking for the model's reasoning.
        var thinkingCleanup = Subject()
        thinkingCleanup.cleanupSurface = OllamaSurfaceProfile(contextTokens: 8192, think: true)
        requireCaught(reporter, mutant: "cleanup with think true", by: cleanupThinkCheck) {
            checkContract(thinkingCleanup, $0)
        }

        // (d) The vision helper unloaded whether or not this pass loaded it.
        var unconditional = Subject()
        unconditional.unloadsUnconditionally = true
        requireCaught(reporter, mutant: "vision pass that unloads its helper unconditionally", by: warmHelperCheck) {
            checkContract(unconditional, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
