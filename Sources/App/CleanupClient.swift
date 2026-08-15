import Foundation

/// Direct HTTP to LM Studio's OpenAI-compatible local server (`127.0.0.1:1234`) for the cleanup
/// transform. Mirrors Handy's MIT `llm_client.rs` shape: one chat-completions call, the firm system
/// prompt, low temperature, a hard safety timeout, and a clean down/error signal so the controller
/// can fall back to the raw transcript.
///
/// Non-streaming on purpose: delivery is **atomic land-when-ready** (we never paste partials, we
/// wait for the whole cleaned string), so streaming would add complexity with no UX gain here.
///
/// Model-pluggable: the model id, endpoint, system prompt, and timeout all come from `Settings`, so
/// the pending `gemma-3-4b-it-qat` head-to-head swaps in via config with no code change.
enum CleanupClient {

    /// Fence the raw transcript inside the delimiter markers the prompts reference, so the model sees
    /// the dictation strictly as a delimited DATA block (the prompt-injection fix). Coupled to the
    /// marker constants + prompt wording in `Prompts.swift`.
    static func wrap(_ raw: String) -> String {
        "\(transcriptStartMarker)\n\(raw)\n\(transcriptEndMarker)"
    }

    /// Enforce the plain-ASCII punctuation rule deterministically, no matter what the model returns.
    /// All three prompts instruct "plain ASCII only; never em/en dashes", but that instruction is
    /// defeatable (the clarity-framed L2 prompt occasionally leaks em dashes, and some models emit
    /// curly quotes / ellipses) and there is no other safety net before the text lands. This is the
    /// single choke point for cleanup output, so normalizing here guarantees the rule for every level
    /// and every model. Maps the common typographic glyphs to their ASCII equivalents, strips markdown
    /// backticks (the email model's no-markdown rule's only other guard — the typographic map does not
    /// touch them, so the choke point handles it for both cleanup and email), then collapses the double
    /// spaces a spaced-hyphen substitution can introduce (space runs only; newlines kept).
    static func asciiPunctuationNormalized(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("\u{2014}", " - "),  // em dash -> spaced hyphen
            ("\u{2015}", " - "),  // horizontal bar -> spaced hyphen
            ("\u{2013}", "-"),    // en dash -> hyphen
            ("\u{2012}", "-"),    // figure dash -> hyphen
            ("\u{2018}", "'"),    // left single quote
            ("\u{2019}", "'"),    // right single quote / apostrophe
            ("\u{201A}", "'"),    // single low-9 quote
            ("\u{201C}", "\""),   // left double quote
            ("\u{201D}", "\""),   // right double quote
            ("\u{201E}", "\""),   // double low-9 quote
            ("\u{2026}", "..."),  // ellipsis
            ("\u{00A0}", " "),    // non-breaking space
            ("\u{2022}", "-"),    // bullet
            ("`", ""),            // markdown backtick -> removed (no-markdown guard; ` is never wanted)
        ]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    /// Strip an inline reasoning channel from model content. Removes every closed <think> block;
    /// if an unclosed <think> is present, drops everything from the tag onward.
    static func stripReasoning(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>", options: .caseInsensitive) {
            if let close = out.range(of: "</think>", options: .caseInsensitive, range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
                break
            }
        }
        return out
    }

    /// Outcome of a cleanup attempt. `.ok` carries the cleaned text; everything else means "deliver
    /// the raw transcript + the cleanup-unavailable toast" (the two failure modes collapse to one
    /// recovery path: raw fallback).
    enum Result {
        case ok(String)
        case unavailable(String)   // LM Studio down / connection refused / bad response
        case timedOut              // ran too long past the safety timeout
        case badOutput(String)     // ran, but produced empty / unusable output
    }

    enum ChatResponseClassification {
        case content(String)
        case failure(Result)
    }

    enum ToolCapableChatResponseClassification {
        case message(content: String, toolCalls: [[String: Any]])
        case failure(Result)
    }

    private enum ChatTransportClassification {
        case data(Data)
        case failure(Result)
    }

    private static func classifyChatTransport(
        data: Data?, response: URLResponse?, error: Error?,
        logPrefix: String?, elapsed: TimeInterval
    ) -> ChatTransportClassification {
        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                if let logPrefix {
                    Log.write("\(logPrefix) TIMEOUT after \(String(format: "%.2f", elapsed))s")
                }
                return .failure(.timedOut)
            }
            if let logPrefix {
                Log.write("\(logPrefix) unavailable: \(error.localizedDescription)")
            }
            return .failure(.unavailable(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.unavailable("no response"))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.unavailable("HTTP \(http.statusCode)"))
        }
        guard let data else {
            return .failure(.unavailable("bad response shape"))
        }
        return .data(data)
    }

    static func classifyChatResponse(data: Data?, response: URLResponse?, error: Error?,
                                     logPrefix: String, elapsed: TimeInterval) -> ChatResponseClassification {
        let responseData: Data
        switch classifyChatTransport(
            data: data, response: response, error: error,
            logPrefix: logPrefix, elapsed: elapsed
        ) {
        case .data(let data):
            responseData = data
        case .failure(let result):
            return .failure(result)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return .failure(.unavailable("bad response shape"))
        }
        return .content(content)
    }

    static func classifyToolCapableChatResponse(
        data: Data?, response: URLResponse?, error: Error?,
        logPrefix: String? = nil, elapsed: TimeInterval = 0
    ) -> ToolCapableChatResponseClassification {
        let responseData: Data
        switch classifyChatTransport(
            data: data, response: response, error: error,
            logPrefix: logPrefix, elapsed: elapsed
        ) {
        case .data(let data):
            responseData = data
        case .failure(let result):
            return .failure(result)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return .failure(.unavailable("bad response shape"))
        }
        let content = (message["content"] as? String) ?? ""
        let toolCalls = (message["tool_calls"] as? [[String: Any]]) ?? []
        return .message(content: content, toolCalls: toolCalls)
    }

    /// Run the cleanup transform on `raw`. Calls back on an arbitrary URLSession queue — the caller
    /// hops to main. `timeout` is the hard safety ceiling (spec: ~5s starting point, tunable).
    static func cleanup(_ raw: String,
                        timeout: TimeInterval = Settings.cleanupTimeout,
                        model: String = Settings.cleanupModel,
                        endpoint: URL = Settings.cleanupEndpoint,
                        systemPrompt: String = Settings.cleanupPrompt(.cleanup),
                        completion: @escaping (Result) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.badOutput("empty input")); return }
        // Make the model resident BEFORE the timed request: a cold load happens here, on a background
        // queue under the caller's thinking spinner, instead of eating the request timeout and forcing
        // a raw fallback. ensureReady loads the model with its per-model TTL; LM Studio owns eviction
        // now (interop ADR 0004), and the request below resets LM Studio's idle clock.
        DispatchQueue.global(qos: .userInitiated).async {
            guard ModelManager.shared.ensureReady(model) else {
                Log.write("cleanup: \(model) could not be made resident")
                completion(.unavailable("model not loaded")); return
            }
            sendRequest(raw, timeout: timeout, model: model, endpoint: endpoint,
                        systemPrompt: systemPrompt, completion: completion)
        }
    }

    /// One chat-completions attempt against the cleanup endpoint. `cleanup(_:)` owns making the model
    /// resident first; this just issues the timed request and reports the `Result`.
    private static func sendRequest(_ raw: String,
                                    timeout: TimeInterval,
                                    model: String,
                                    endpoint: URL,
                                    systemPrompt: String,
                                    completion: @escaping (Result) -> Void) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Generous output ceiling: cleanup never lengthens much, but a long ramble (golden sample 1)
        // needs room. The model stops on its own well before this.
        let body: [String: Any] = [
            "model": model,
            "temperature": Settings.cleanupTemperature,
            "max_tokens": 4096,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": wrap(raw)],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.unavailable("encode failed")); return
        }
        req.httpBody = data

        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, response, error in
            let dt = Date().timeIntervalSince(t0)
            let classification = classifyChatResponse(
                data: data, response: response, error: error, logPrefix: "cleanup", elapsed: dt)
            let content: String
            switch classification {
            case .content(let value):
                content = value
            case .failure(let result):
                completion(result); return
            }
            let cleaned = asciiPunctuationNormalized(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                Log.write("cleanup produced empty output (\(String(format: "%.2f", dt))s)")
                completion(.badOutput("empty output")); return
            }
            Log.write("cleanup OK \(raw.count)->\(cleaned.count) chars in \(String(format: "%.2f", dt))s")
            completion(.ok(cleaned))
        }.resume()
    }

    /// Synchronous variant for the headless `--selftest` seam: exercises the exact same request path
    /// and returns the `Result` plus the wall-clock latency. Blocks the calling thread on a semaphore
    /// (selftest runs off the main loop, so this is safe there only).
    static func cleanupSync(_ raw: String, timeout: TimeInterval) -> (Result, TimeInterval) {
        let sem = DispatchSemaphore(value: 0)
        var out: Result = .unavailable("no result")
        let t0 = Date()
        cleanup(raw, timeout: timeout) { r in out = r; sem.signal() }
        // Wait a touch past the request timeout so a genuine timeout returns through the normal path.
        _ = sem.wait(timeout: .now() + timeout + 10)
        return (out, Date().timeIntervalSince(t0))
    }
}
