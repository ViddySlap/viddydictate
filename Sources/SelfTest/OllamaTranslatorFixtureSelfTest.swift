import Foundation

/// G2 (`--ollama-transport-selftest`): the pure OpenAI <-> native `/api/chat` translation, proven against
/// the request bodies the clients really build and the response parsers they really run. No Ollama, no
/// network, no preferences.
///
/// - Requests come from the real builders where one is callable (`NoteToHandoffLocalVisionClient.
///   requestBody`, `SearchClient.webSearchTool`) and otherwise mirror the client's inline body key for key
///   (`EmailClient` / `CleanupClient` / `SearchClient.lmChat` build theirs inside private functions).
/// - Responses are fed through the EXISTING `CleanupClient.classifyChatResponse` and
///   `CleanupClient.classifyToolCapableChatResponse`, unchanged, with a synthetic 200 `HTTPURLResponse`.
///   The search loop's argument read is private, so its three casts are mirrored exactly.
///
/// The idle window is **437**, never 600: a translator that hard-codes the app's default would otherwise
/// pass. Every other number is distinct too (num_ctx 8192/16384, max_tokens 1234/777).
///
/// Negative controls: the contract is re-run against three broken translators (forward the OpenAI body
/// unchanged, hard-code `keep_alive` 600, leave response arguments as an object), and the gate FAILS unless
/// the assertion aimed at each one reports it.
enum OllamaTranslatorFixtureSelfTest {
    private typealias RequestTranslator = (_ body: [String: Any], _ keepAliveSeconds: Int,
                                           _ contextTokens: Int, _ thinkingCapable: Bool,
                                           _ think: Bool) -> [String: Any]?
    private typealias ResponseTranslator = (Data) -> Data?

    private struct TransportSubject {
        let request: RequestTranslator
        let response: ResponseTranslator
    }

    private static let keepAliveFixture = 437
    private static let modelFixture = "ollama-fixture-actually-installed:latest"

    // Assertion names the negative controls look up.
    private static let keepAliveCheck = "keep_alive on the wire is the configured idle window (437 s), as an integer"
    private static let argumentsStringCheck =
        "response tool arguments reach the client as a JSON string the search loop decodes"

    static func run() -> Bool {
        print("=== Ollama chat translator fixture selftest (OpenAI <-> /api/chat) ===")
        let reporter = SelfTestReporter()

        let real = TransportSubject(
            request: { body, keepAlive, context, capable, think in
                OllamaChatTranslator.nativeRequestBody(
                    fromOpenAI: body, keepAliveSeconds: keepAlive, contextTokens: context,
                    thinkingCapable: capable, think: think)
            },
            response: { OllamaChatTranslator.openAIResponseData(fromNative: $0) })
        print("--- transport contract (real translator) ---")
        checkTransportContract(real, reporter)
        checkRequestDetails(reporter)
        checkResponseDetails(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[ollama-transport-selftest] PASS"
            : "[ollama-transport-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Fixtures

    /// Mirrors `EmailClient.request`'s body key for key (it is built inside a private function).
    private static var emailShapedBody: [String: Any] {
        [
            "model": modelFixture,
            "temperature": 0.3,
            "max_tokens": 1234,
            "stream": false,
            "messages": [
                ["role": "system", "content": "fixture system prompt"],
                ["role": "user", "content": "Notes:\n<<<NOTES>>>\nfixture notes\n<<<END NOTES>>>"],
            ],
        ]
    }

    /// Mirrors `SearchClient.lmChat` on a second-turn thread: the assistant turn echoes two tool calls
    /// with STRING arguments, and their results come back in the REVERSE order, so `tool_name` can only be
    /// right if it is looked up by id rather than by position. `tools` is the real `webSearchTool`.
    private static var searchShapedBody: [String: Any] {
        let searchFunction: [String: Any] = [
            "name": "web_search", "arguments": "{\"query\":\"ollama keep alive\"}",
        ]
        let fetchFunction: [String: Any] = [
            "name": "fetch_page", "arguments": "{\"url\":\"https://example.invalid/a\"}",
        ]
        let toolCalls: [[String: Any]] = [
            ["id": "call_0_web_search", "type": "function", "function": searchFunction],
            ["id": "call_1_fetch_page", "type": "function", "function": fetchFunction],
        ]
        let assistant: [String: Any] = ["role": "assistant", "content": "", "tool_calls": toolCalls]
        let messages: [[String: Any]] = [
            ["role": "system", "content": "fixture agentic prompt"],
            ["role": "user", "content": "fixture question"],
            assistant,
            ["role": "tool", "tool_call_id": "call_1_fetch_page", "content": "page text"],
            ["role": "tool", "tool_call_id": "call_0_web_search", "content": "search results"],
            ["role": "tool", "tool_call_id": "call_9_unknown", "content": "orphan result"],
        ]
        return [
            "model": modelFixture,
            "temperature": 0.0,
            "max_tokens": 777,
            "stream": false,
            "tools": [SearchClient.webSearchTool],
            "tool_choice": "auto",
            "messages": messages,
        ]
    }

    /// The real vision builder's body for one PNG frame. Its base64 is fixed below by hand.
    private static let frameBytes = Data("fixture-frame-bytes".utf8)
    private static let frameBase64 = "Zml4dHVyZS1mcmFtZS1ieXRlcw=="

    private static var visionBody: [String: Any]? {
        let frame = NoteToHandoffFrame(
            attachmentIndex: 0, filename: "fixture-shot.png", position: "still",
            data: frameBytes, mediaType: "image/png")
        guard let data = NoteToHandoffLocalVisionClient.requestBody(model: modelFixture, frames: [frame])
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Native `/api/chat` responses in Ollama 0.34's non-streaming shape.
    private static let nativeThinkingResponse = """
    {"model":"ollama-fixture-actually-installed:latest","created_at":"2026-09-30T20:10:04.129643576Z",
     "message":{"role":"assistant","content":"Fixture email body.","thinking":"Fixture private reasoning."},
     "done":true,"done_reason":"stop","total_duration":123456789,"load_duration":2345678,
     "prompt_eval_count":42,"prompt_eval_duration":3456789,"eval_count":17,"eval_duration":4567890}
    """

    private static let nativeToolResponse = """
    {"model":"ollama-fixture-actually-installed:latest","created_at":"2026-09-30T20:10:05Z",
     "message":{"role":"assistant","content":"",
       "tool_calls":[
         {"function":{"name":"web_search","arguments":{"query":"ollama keep alive","max_results":3}}},
         {"function":{"index":1,"name":"fetch_page","arguments":{"url":"https://example.invalid/a"}}}
       ]},
     "done":true,"done_reason":"stop"}
    """

    // MARK: - Transport contract (the part the mutants are run against)

    private static func checkTransportContract(_ subject: TransportSubject, _ reporter: SelfTestReporter) {
        let email = wire(subject.request(emailShapedBody, keepAliveFixture, 8192, false, true))
        let options = email?["options"] as? [String: Any]
        reporter.record(
            keepAliveCheck,
            (email?["keep_alive"] as? NSNumber)?.intValue == keepAliveFixture
                && !(email?["keep_alive"] is String),
            "\(email?["keep_alive"] ?? "absent")")
        reporter.record(
            "num_ctx carries the per-surface context, and the body is non-streaming",
            (options?["num_ctx"] as? NSNumber)?.intValue == 8192
                && (email?["stream"] as? NSNumber)?.boolValue == false)
        reporter.record(
            "think is omitted for a model without the thinking capability, even when requested",
            email != nil && email?["think"] == nil)

        let capable = wire(subject.request(emailShapedBody, keepAliveFixture, 8192, true, true))
        let capableOff = wire(subject.request(emailShapedBody, keepAliveFixture, 8192, true, false))
        reporter.record(
            "think is sent, with the requested value, for a thinking-capable model",
            (capable?["think"] as? NSNumber)?.boolValue == true
                && (capableOff?["think"] as? NSNumber)?.boolValue == false)

        let vision = wire(visionBody.flatMap { subject.request($0, keepAliveFixture, 8192, false, false) })
        let visionUser = (vision?["messages"] as? [[String: Any]])?.first { ($0["role"] as? String) == "user" }
        reporter.record(
            "an image_url data URL becomes bare base64 in images, and content becomes plain text",
            (visionUser?["images"] as? [String]) == [frameBase64]
                && (visionUser?["content"] as? String)?.contains("FRAME still") == true
                && (visionUser?["content"] as? String)?.contains("data:") == false)

        let search = wire(subject.request(searchShapedBody, keepAliveFixture, 16_384, false, false))
        let searchMessages = search?["messages"] as? [[String: Any]]
        let assistant = searchMessages?.first { ($0["role"] as? String) == "assistant" }
        let firstCall = (assistant?["tool_calls"] as? [[String: Any]])?.first
        let firstArguments = (firstCall?["function"] as? [String: Any])?["arguments"] as? [String: Any]
        reporter.record(
            "request tool arguments go from a JSON string to an object",
            firstArguments?["query"] as? String == "ollama keep alive")
        let toolNames = searchMessages?.filter { ($0["role"] as? String) == "tool" }
            .map { ($0["tool_name"] as? String) ?? "-" }
        reporter.record(
            "tool_name is filled from the earlier assistant call with the same tool_call_id",
            toolNames == ["fetch_page", "web_search", "-"],
            toolNames?.joined(separator: ", ") ?? "nil")

        // Response side. The translated body must pass the EXISTING classifiers unchanged.
        let thinking = subject.response(Data(nativeThinkingResponse.utf8))
        var classifiedContent: String?
        if case .content(let value) = CleanupClient.classifyChatResponse(
            data: thinking, response: ok200(), error: nil,
            logPrefix: "ollama-transport-selftest", elapsed: 0) {
            classifiedContent = value
        }
        reporter.record(
            "a plain native reply classifies as content through CleanupClient.classifyChatResponse",
            classifiedContent == "Fixture email body.", classifiedContent ?? "nil")

        let tools = subject.response(Data(nativeToolResponse.utf8))
        var classifiedCalls: [[String: Any]] = []
        var classifiedAsMessage = false
        if case .message(_, let calls) = CleanupClient.classifyToolCapableChatResponse(
            data: tools, response: ok200(), error: nil) {
            classifiedAsMessage = true
            classifiedCalls = calls
        }
        reporter.record(
            "a native tool-call reply is recognized as tool calls by classifyToolCapableChatResponse",
            classifiedAsMessage && classifiedCalls.count == 2)
        reporter.record(
            argumentsStringCheck,
            searchLoopQuery(classifiedCalls.first) == "ollama keep alive")
    }

    // MARK: - Request details the mutants do not target

    private static func checkRequestDetails(_ reporter: SelfTestReporter) {
        print("--- request details ---")
        func translate(_ body: [String: Any], context: Int = 8192) -> [String: Any]? {
            wire(OllamaChatTranslator.nativeRequestBody(
                fromOpenAI: body, keepAliveSeconds: keepAliveFixture, contextTokens: context,
                thinkingCapable: false, think: false))
        }
        let email = translate(emailShapedBody)
        let options = email?["options"] as? [String: Any]
        reporter.record(
            "temperature moves into options and max_tokens becomes options.num_predict",
            (options?["temperature"] as? NSNumber)?.doubleValue == 0.3
                && (options?["num_predict"] as? NSNumber)?.intValue == 1234
                && email?["max_tokens"] == nil && email?["temperature"] == nil)
        reporter.record(
            "model and string message content pass through untouched",
            email?["model"] as? String == modelFixture
                && ((email?["messages"] as? [[String: Any]])?.last?["content"] as? String)
                    == "Notes:\n<<<NOTES>>>\nfixture notes\n<<<END NOTES>>>")

        let search = translate(searchShapedBody, context: 16_384)
        let tools = search?["tools"] as? [[String: Any]]
        reporter.record(
            "tools pass through unchanged and tool_choice is dropped; num_ctx follows the surface",
            tools?.count == 1
                && ((tools?.first?["function"] as? [String: Any])?["name"] as? String) == "web_search"
                && search?["tool_choice"] == nil
                && ((search?["options"] as? [String: Any])?["num_ctx"] as? NSNumber)?.intValue == 16_384)

        var remote = emailShapedBody
        remote["messages"] = [[
            "role": "user",
            "content": [
                ["type": "text", "text": "look"],
                ["type": "image_url", "image_url": ["url": "https://example.invalid/a.png"]],
            ] as [[String: Any]],
        ] as [String: Any]]
        reporter.record(
            "an image that is not a base64 data URL is refused (nil), never silently dropped",
            OllamaChatTranslator.nativeRequestBody(
                fromOpenAI: remote, keepAliveSeconds: keepAliveFixture, contextTokens: 8192,
                thinkingCapable: false, think: false) == nil)
        reporter.record(
            "data URL stripping keeps exactly the payload after the comma",
            OllamaChatTranslator.bareBase64(fromDataURL: "data:image/jpeg;base64,QUJD") == "QUJD"
                && OllamaChatTranslator.bareBase64(fromDataURL: "data:text/plain,QUJD") == nil)
        reporter.record(
            "a non-positive context size is refused rather than sent",
            OllamaChatTranslator.nativeRequestBody(
                fromOpenAI: emailShapedBody, keepAliveSeconds: keepAliveFixture, contextTokens: 0,
                thinkingCapable: false, think: false) == nil)
        let data = try? JSONSerialization.data(withJSONObject: emailShapedBody)
        let viaData = data.flatMap {
            OllamaChatTranslator.nativeRequestData(
                fromOpenAI: $0, keepAliveSeconds: keepAliveFixture, contextTokens: 8192,
                thinkingCapable: false, think: false)
        }
        let reparsed = viaData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        reporter.record(
            "the Data form carries the same keep_alive",
            (reparsed?["keep_alive"] as? NSNumber)?.intValue == keepAliveFixture)
    }

    // MARK: - Response details the mutants do not target

    private static func checkResponseDetails(_ reporter: SelfTestReporter) {
        print("--- response details ---")
        let thinking = OllamaChatTranslator.openAIResponseData(fromNative: Data(nativeThinkingResponse.utf8))
        let thinkingMessage = firstMessage(thinking)
        reporter.record(
            "thinking becomes reasoning_content and content stays clean",
            thinkingMessage?["reasoning_content"] as? String == "Fixture private reasoning."
                && (thinkingMessage?["content"] as? String)?.contains("reasoning") == false
                && thinkingMessage?["tool_calls"] == nil)

        let tools = OllamaChatTranslator.openAIResponseData(fromNative: Data(nativeToolResponse.utf8))
        let toolMessage = firstMessage(tools)
        let calls = toolMessage?["tool_calls"] as? [[String: Any]]
        reporter.record(
            "synthesized tool-call ids are stable: call_<index>_<name>, typed function",
            calls?.map { ($0["id"] as? String) ?? "-" } == ["call_0_web_search", "call_1_fetch_page"]
                && calls?.allSatisfy { ($0["type"] as? String) == "function" } == true)
        reporter.record(
            "no reasoning_content when the model did not think",
            toolMessage != nil && toolMessage?["reasoning_content"] == nil)
        reporter.record(
            "the translation is deterministic byte for byte",
            tools != nil
                && tools == OllamaChatTranslator.openAIResponseData(fromNative: Data(nativeToolResponse.utf8)))
        let secondArgs = searchLoopArguments(calls?.dropFirst().first)
        reporter.record(
            "argument values survive the object -> string trip, numbers included",
            searchLoopArguments(calls?.first)?["max_results"] as? Int == 3
                && secondArgs?["url"] as? String == "https://example.invalid/a")

        // Round trip: echo the translated calls back exactly as SearchClient's loop does, then translate the
        // next request. The synthesized id must resolve to the right tool_name on the way back in.
        let echoed: [[String: Any]] = [
            ["role": "user", "content": "fixture question"],
            ["role": "assistant", "content": (toolMessage?["content"] as? String) ?? "",
             "tool_calls": calls ?? []],
            ["role": "tool", "tool_call_id": (calls?.last?["id"] as? String) ?? "", "content": "page"],
        ]
        let next = wire(OllamaChatTranslator.nativeRequestBody(
            fromOpenAI: ["model": modelFixture, "messages": echoed], keepAliveSeconds: keepAliveFixture,
            contextTokens: 16_384, thinkingCapable: false, think: false))
        let nextMessages = next?["messages"] as? [[String: Any]]
        let nextTool = nextMessages?.last
        let nextAssistant = nextMessages?.first { ($0["role"] as? String) == "assistant" }
        let nextCall = (nextAssistant?["tool_calls"] as? [[String: Any]])?.first
        let nextArgs = (nextCall?["function"] as? [String: Any])?["arguments"] as? [String: Any]
        reporter.record(
            "tool-call id round trip: the echoed synthesized id resolves back to its tool_name",
            nextTool?["tool_name"] as? String == "fetch_page"
                && nextArgs?["query"] as? String == "ollama keep alive")

        let truncatedReply =
            "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"cut\"},"
            + "\"done\":true,\"done_reason\":\"length\"}"
        var finishReason: String?
        if let data = OllamaChatTranslator.openAIResponseData(fromNative: Data(truncatedReply.utf8)),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let choice = (object["choices"] as? [[String: Any]])?.first {
            finishReason = choice["finish_reason"] as? String
        }
        reporter.record("done_reason carries through as finish_reason", finishReason == "length")

        var providerError: OllamaChatTranslator.ResponseError?
        do {
            _ = try OllamaChatTranslator.openAIResponse(
                fromNative: Data("{\"error\":\"fixture model not found\"}".utf8))
        } catch let error as OllamaChatTranslator.ResponseError {
            providerError = error
        } catch {
            providerError = nil
        }
        reporter.record(
            "an Ollama error body is a typed providerError, and nil from the convenience form",
            providerError == .providerError("fixture model not found")
                && OllamaChatTranslator.openAIResponseData(
                    fromNative: Data("{\"error\":\"fixture model not found\"}".utf8)) == nil)
        reporter.record(
            "undecodable JSON and a body without a message are refused",
            OllamaChatTranslator.openAIResponseData(fromNative: Data("{not-json".utf8)) == nil
                && OllamaChatTranslator.openAIResponseData(fromNative: Data("{\"done\":true}".utf8)) == nil)
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        let realRequest: RequestTranslator = { body, keepAlive, context, capable, think in
            OllamaChatTranslator.nativeRequestBody(
                fromOpenAI: body, keepAliveSeconds: keepAlive, contextTokens: context,
                thinkingCapable: capable, think: think)
        }
        let realResponse: ResponseTranslator = { OllamaChatTranslator.openAIResponseData(fromNative: $0) }

        // 1. The /v1-shaped transport: the OpenAI body goes out as-is, so no keep_alive at all.
        let forwardsUnchanged = TransportSubject(
            request: { body, _, _, _, _ in body }, response: realResponse)
        requireCaught(reporter, mutant: "translator that forwards the OpenAI body unchanged",
                      by: keepAliveCheck) {
            checkTransportContract(forwardsUnchanged, $0)
        }

        // 2. The configured window is ignored in favor of the app's default.
        let hardCoded600 = TransportSubject(
            request: { body, _, context, capable, think in
                guard var native = realRequest(body, 600, context, capable, think) else { return nil }
                native["keep_alive"] = 600
                return native
            },
            response: realResponse)
        requireCaught(reporter, mutant: "translator that hard-codes keep_alive 600", by: keepAliveCheck) {
            checkTransportContract(hardCoded600, $0)
        }

        // 3. The response copies native arguments through as an object.
        let objectArguments = TransportSubject(request: realRequest, response: argumentsLeftAsObject)
        requireCaught(reporter, mutant: "translator that leaves response arguments as an object",
                      by: argumentsStringCheck) {
            checkTransportContract(objectArguments, $0)
        }
    }

    /// The third mutant: a plausible translator that does everything right except stringify arguments.
    private static func argumentsLeftAsObject(_ data: Data) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let native = object["message"] as? [String: Any] else { return nil }
        var message: [String: Any] = ["role": "assistant", "content": (native["content"] as? String) ?? ""]
        if let thinking = native["thinking"] as? String { message["reasoning_content"] = thinking }
        if let calls = native["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            var translated: [[String: Any]] = []
            for (index, call) in calls.enumerated() {
                let function = (call["function"] as? [String: Any]) ?? [:]
                let name = (function["name"] as? String) ?? ""
                translated.append(["id": "call_\(index)_\(name)", "type": "function", "function": function])
            }
            message["tool_calls"] = translated
        }
        let choice: [String: Any] = ["index": 0, "message": message, "finish_reason": "stop"]
        let response: [String: Any] = ["choices": [choice]]
        guard JSONSerialization.isValidJSONObject(response) else { return nil }
        return try? JSONSerialization.data(withJSONObject: response)
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

    // MARK: - Helpers

    /// What actually goes on the wire: the translator's dictionary serialized and parsed back, so every
    /// assertion reads JSON types (an Int that became a String would show). Nil for a non-JSON value.
    private static func wire(_ body: [String: Any]?) -> [String: Any]? {
        guard let body, JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func ok200() -> HTTPURLResponse? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/chat") else { return nil }
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    }

    private static func firstMessage(_ data: Data?) -> [String: Any]? {
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]] else { return nil }
        return choices.first?["message"] as? [String: Any]
    }

    /// `SearchClient.agenticLoop`'s argument read, cast for cast (it is private there): `arguments` must
    /// be a String, decode as UTF-8 JSON, and be an object.
    private static func searchLoopArguments(_ call: [String: Any]?) -> [String: Any]? {
        let fn = call?["function"] as? [String: Any]
        guard let argStr = fn?["arguments"] as? String,
              let argData = argStr.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] else { return nil }
        return args
    }

    private static func searchLoopQuery(_ call: [String: Any]?) -> String? {
        (searchLoopArguments(call)?["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
