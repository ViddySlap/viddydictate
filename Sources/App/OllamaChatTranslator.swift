import Foundation

/// The one seam between the OpenAI-shaped chat the clients already speak and Ollama's native
/// `POST /api/chat`.
///
/// `CleanupClient`, `EmailClient`, `SearchClient` and `NoteToHandoffLocalVisionClient` keep building the
/// request they build for LM Studio (`messages`, `tools`, `image_url` data URLs) and keep parsing the
/// response LM Studio returns (`choices[0].message`, `tool_calls[].function.arguments` as a JSON STRING,
/// `reasoning_content`). Only the transport forks, so every client stays single-path (spec section 1).
///
/// Why native and not Ollama's `/v1`: `/v1` cannot carry `keep_alive` or `num_ctx`. Every `/v1` call would
/// reset the model's expiry to Ollama's global default (our idle-unload setting would silently stop
/// applying) and, on a 48 GB+ Mac, load a 256k-token KV cache: the MLX-panic shape ADR 0018 exists for.
///
/// Pure: no networking, no `Settings` reads. The caller supplies the idle window and context size, which is
/// also what lets `--ollama-transport-selftest` prove a configured value (not a default) reaches the wire.
enum OllamaChatTranslator {

    // MARK: - Request: OpenAI shape -> native /api/chat

    /// Translate an OpenAI chat-completions body into a native `/api/chat` body.
    ///
    /// - `stream` is always false: delivery is atomic land-when-ready, as it is for LM Studio.
    /// - `keep_alive` is an integer number of seconds, the app's idle window. This is the whole residency
    ///   contract on Ollama (spec section 5): the backend owns eviction, the app supplies one window.
    /// - `options.num_ctx` is always set; `temperature` and `max_tokens` (as `num_predict`) move into
    ///   `options` when present.
    /// - `think` is sent ONLY for a model whose `/api/show` capabilities include `thinking`. Ollama rejects
    ///   `think` on a model that cannot think, so a non-thinking model gets no key at all.
    /// - `tools` pass through unchanged (Ollama takes the OpenAI function schema); `tool_choice` is dropped,
    ///   because native has no equivalent.
    ///
    /// Returns nil when the body cannot be represented faithfully: no `messages`, a message that is not an
    /// object, an image that is not a base64 data URL (Ollama cannot fetch a remote URL), tool arguments
    /// that are not a JSON object, or a non-positive `contextTokens`. Nil surfaces as the clients' existing
    /// "encode failed", rather than as a request that silently lost an image or a tool call.
    static func nativeRequestBody(fromOpenAI body: [String: Any],
                                  keepAliveSeconds: Int,
                                  contextTokens: Int,
                                  thinkingCapable: Bool,
                                  think: Bool) -> [String: Any]? {
        guard contextTokens > 0,
              let rawMessages = body["messages"] as? [Any],
              let messages = nativeMessages(rawMessages) else { return nil }

        var options: [String: Any] = ["num_ctx": contextTokens]
        if let temperature = body["temperature"], !(temperature is NSNull) {
            options["temperature"] = temperature
        }
        if let maxTokens = body["max_tokens"], !(maxTokens is NSNull) {
            options["num_predict"] = maxTokens
        }

        var native: [String: Any] = [
            "messages": messages,
            "stream": false,
            "keep_alive": keepAliveSeconds,
            "options": options,
        ]
        if let model = body["model"] as? String {
            native["model"] = model
        }
        if let tools = body["tools"] as? [Any], !tools.isEmpty {
            native["tools"] = tools
        }
        if thinkingCapable {
            native["think"] = think
        }
        return native
    }

    /// `nativeRequestBody` over encoded JSON, for callers that hold the body as `Data` (the vision client's
    /// `requestBody` does). Keys are sorted so the same input always yields the same bytes.
    static func nativeRequestData(fromOpenAI data: Data,
                                  keepAliveSeconds: Int,
                                  contextTokens: Int,
                                  thinkingCapable: Bool,
                                  think: Bool) -> Data? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let native = nativeRequestBody(
                fromOpenAI: body, keepAliveSeconds: keepAliveSeconds, contextTokens: contextTokens,
                thinkingCapable: thinkingCapable, think: think),
              // `data(withJSONObject:)` raises an Objective-C exception, not a Swift error, on a value
              // JSON cannot hold, so validity is checked first rather than trusted.
              JSONSerialization.isValidJSONObject(native) else { return nil }
        return try? JSONSerialization.data(withJSONObject: native, options: [.sortedKeys])
    }

    /// Messages in order, with three rewrites and everything else passed through:
    /// 1. array content becomes the joined text parts plus `images` of bare base64;
    /// 2. an assistant's `tool_calls[].function.arguments` JSON string becomes the object native expects;
    /// 3. a `tool` message gains `tool_name`, looked up from the earlier assistant call with its
    ///    `tool_call_id`. Native pairs a result with its call by name, not by id.
    private static func nativeMessages(_ raw: [Any]) -> [[String: Any]]? {
        var toolNamesByCallID: [String: String] = [:]
        var out: [[String: Any]] = []
        for element in raw {
            guard var message = element as? [String: Any] else { return nil }
            let role = message["role"] as? String

            if let parts = message["content"] as? [Any] {
                guard let flattened = flattenContent(parts) else { return nil }
                message["content"] = flattened.text
                if !flattened.images.isEmpty {
                    message["images"] = flattened.images
                }
            } else if message["content"] == nil || message["content"] is NSNull {
                // LM Studio accepts a null assistant content beside tool_calls; native wants a string.
                message["content"] = ""
            }

            if let calls = message["tool_calls"] as? [Any] {
                var nativeCalls: [[String: Any]] = []
                for callElement in calls {
                    guard let call = callElement as? [String: Any],
                          let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let arguments = argumentsObject(function["arguments"]) else { return nil }
                    if let id = call["id"] as? String {
                        toolNamesByCallID[id] = name
                    }
                    var nativeCall: [String: Any] = [
                        "function": ["name": name, "arguments": arguments] as [String: Any],
                    ]
                    if let id = call["id"] as? String {
                        nativeCall["id"] = id
                    }
                    nativeCalls.append(nativeCall)
                }
                message["tool_calls"] = nativeCalls
            }

            if role == "tool", let callID = message["tool_call_id"] as? String,
               let name = toolNamesByCallID[callID] {
                message["tool_name"] = name
            }
            out.append(message)
        }
        return out
    }

    /// Joined text plus bare base64 images from an OpenAI content-part array. Text parts are joined with
    /// newlines so labels that sat between images (the vision client's "FRAME first") stay separate lines.
    private static func flattenContent(_ parts: [Any]) -> (text: String, images: [String])? {
        var texts: [String] = []
        var images: [String] = []
        for element in parts {
            guard let part = element as? [String: Any], let type = part["type"] as? String else { return nil }
            switch type {
            case "text":
                texts.append((part["text"] as? String) ?? "")
            case "image_url":
                // OpenAI's shape is {"image_url": {"url": ...}}; a bare string is accepted as well.
                let url = ((part["image_url"] as? [String: Any])?["url"] as? String)
                    ?? (part["image_url"] as? String)
                guard let url, let bare = bareBase64(fromDataURL: url) else { return nil }
                images.append(bare)
            default:
                return nil
            }
        }
        return (texts.joined(separator: "\n"), images)
    }

    /// `data:<mime>;base64,XXXX` -> `XXXX`. Nil for anything else, including a data URL that is not base64.
    static func bareBase64(fromDataURL url: String) -> String? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.startIndex..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let payload = String(url[url.index(after: comma)...])
        return payload.isEmpty ? nil : payload
    }

    /// OpenAI carries arguments as a JSON string; native wants the object. An object passes through, an
    /// empty string or absent value is `{}`, and anything that does not decode to an object is nil.
    private static func argumentsObject(_ raw: Any?) -> [String: Any]? {
        if let object = raw as? [String: Any] { return object }
        if raw == nil || raw is NSNull { return [:] }
        guard let string = raw as? String else { return nil }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Response: native /api/chat -> OpenAI shape

    /// Why a native response could not be translated. The response side throws this typed error rather
    /// than returning nil so the backend slice can log WHICH failure happened; `openAIResponseData` is the
    /// nil-returning convenience for callers that only need "usable or not".
    ///
    /// `.providerError` carries Ollama's own `error` text. It is diagnostic only and must never reach
    /// user-facing copy: `CleanupClient.capacityRefusalMessage` is the allowlist for what may.
    enum ResponseError: Error, Equatable {
        /// Not JSON, or JSON that is not an object.
        case undecodable
        /// Ollama answered with `{"error": "..."}`.
        case providerError(String)
        /// No `message` object in an otherwise valid body.
        case missingMessage
        /// A tool call without a function name, or with arguments that are neither object nor string.
        case malformedToolCall
    }

    /// Translate a native `/api/chat` response into the chat-completions body `CleanupClient`'s classifiers
    /// and `SearchClient`'s tool loop already parse:
    ///
    /// `{"choices":[{"index":0,"message":{"role":"assistant","content":…,"reasoning_content":…,
    ///   "tool_calls":[{"id":"call_<i>_<name>","type":"function","function":{"name":…,"arguments":"<JSON>"}}]},
    ///   "finish_reason":<done_reason or "stop">}],"model":…}`
    ///
    /// - `message.thinking` becomes `reasoning_content`, so `content` stays clean, as it does on LM Studio.
    ///   Omitted when there is no thinking.
    /// - Tool arguments (an object on native) become a JSON STRING with sorted keys, because the search loop
    ///   reads `arguments as? String`. An object there would silently lose the query.
    /// - Each call gets a synthesized, deterministic id `call_<index>_<name>`. The loop echoes it back as
    ///   `tool_call_id`, and `nativeRequestBody` resolves it to `tool_name`. Ids repeat across turns
    ///   (turn two's first call is `call_0_…` again); that is harmless because the lookup only needs the
    ///   name, and every call with a given id has the same name by construction.
    /// - `tool_calls` is omitted when there are none.
    static func openAIResponse(fromNative data: Data) throws -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ResponseError.undecodable
        }
        if let error = object["error"], !(error is NSNull) {
            throw ResponseError.providerError((error as? String) ?? String(describing: error))
        }
        guard let native = object["message"] as? [String: Any] else {
            throw ResponseError.missingMessage
        }

        var message: [String: Any] = [
            "role": "assistant",
            "content": (native["content"] as? String) ?? "",
        ]
        if let thinking = native["thinking"] as? String, !thinking.isEmpty {
            message["reasoning_content"] = thinking
        }

        if let calls = native["tool_calls"] as? [Any], !calls.isEmpty {
            var translated: [[String: Any]] = []
            for (index, element) in calls.enumerated() {
                guard let call = element as? [String: Any],
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String, !name.isEmpty,
                      let arguments = argumentsString(function["arguments"]) else {
                    throw ResponseError.malformedToolCall
                }
                translated.append([
                    "id": "call_\(index)_\(name)",
                    "type": "function",
                    "function": ["name": name, "arguments": arguments] as [String: Any],
                ])
            }
            message["tool_calls"] = translated
        }

        var choice: [String: Any] = [
            "index": 0,
            "message": message,
            "finish_reason": "stop",
        ]
        if let reason = object["done_reason"] as? String, !reason.isEmpty {
            choice["finish_reason"] = reason
        }
        var response: [String: Any] = ["choices": [choice]]
        if let model = object["model"] as? String {
            response["model"] = model
        }
        guard JSONSerialization.isValidJSONObject(response),
              let out = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            throw ResponseError.undecodable
        }
        return out
    }

    /// Nil-returning form of `openAIResponse(fromNative:)`: nil for every `ResponseError`.
    static func openAIResponseData(fromNative data: Data) -> Data? {
        try? openAIResponse(fromNative: data)
    }

    /// Native arguments object -> the JSON string OpenAI clients expect. A string passes through untouched
    /// (some Ollama builds already send one), absent is `"{}"`, and anything else is malformed.
    private static func argumentsString(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if raw == nil || raw is NSNull { return "{}" }
        guard let object = raw as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
