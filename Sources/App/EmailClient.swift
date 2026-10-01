import Foundation

/// Direct HTTP to LM Studio's OpenAI-compatible local server for the Option+M email transform.
///
/// Sibling of `CleanupClient`, but a DISTINCT model and request shape:
///  - Model `google/gemma-4-e4b` (a small reasoner), DISTINCT from the resident cleanup model.
///  - A HIGH `max_tokens` (16384): gemma-4-e4b is a thinking model and needs room to reason before
///    it emits the email. LM Studio returns the chain-of-thought in a separate `reasoning_content`
///    field, so `content` is already the final email; `CleanupClient.stripReasoning` additionally strips
///    any inline <think> block as a belt-and-suspenders guard.
///  - Temperature 0.0, a latency-relaxed safety timeout (email is deliberate, not latency-bound).
///  - Model residency: the email model (gemma) is loaded on demand and idle-unloaded by `ModelManager`
///    (ADR 0006); `email(_:)` calls `ensureReady` before the request so a cold load happens under the
///    thinking spinner, not against the request timeout.
///
/// Output is routed through the SAME `CleanupClient.asciiPunctuationNormalized` choke point (which
/// also strips markdown backticks) so the no-markdown / plain-ASCII rules hold deterministically.
///
/// Reuses `CleanupClient.Result` so the controller's failure-path wiring is identical to Option+P:
/// `.ok` pastes in place; everything else leaves the text untouched + a toast (NEVER paste an empty).
enum EmailClient {

    /// Wrap the captured selection in the `Notes:` user message the email prompt expects. The system
    /// prompt (everything BEFORE this block in the locked prompt) is sent as the system message, so
    /// `system + user` reconstitutes the exact locked prompt with `{selection}` substituted.
    static func wrap(_ selection: String) -> String {
        "Notes:\n<<<NOTES>>>\n\(selection)\n<<<END NOTES>>>"
    }

    /// Run the email transform on `selection`. Ensures the model is resident first (ADR 0006), then
    /// issues one timed request. Calls back on an arbitrary queue; the caller hops to main.
    ///
    /// `backend` is the app the caller's route resolved to. LM Studio is today's path, byte for byte. Ollama
    /// sends the same body through `transport.ollamaChat` with the email profile: 8k context and `think:
    /// true` for a thinking-capable model, whose reasoning comes back as `message.thinking`, which the
    /// translator maps to `reasoning_content` exactly where LM Studio puts gemma's, so `content` stays the
    /// email alone.
    static func email(_ selection: String,
                      timeout: TimeInterval = Settings.emailTimeout,
                      model: String = Settings.emailModel,
                      backend: LocalBackendID = .lmStudio,
                      endpoint: URL = Settings.emailEndpoint,
                      systemPrompt: String = Settings.emailSystemPrompt,
                      transport: LocalChatTransport = .live,
                      readiness: ((String) -> ModelManager.ReadinessResult)? = nil,
                      completion: @escaping (CleanupClient.Result) -> Void) {
        // LM Studio readiness: the caller's own check, else the transport's (`ModelManager.shared
        // .ensureReady(model)` in production, exactly the call this default always made).
        let readiness = readiness ?? { transport.prepareLMStudio($0, nil) }
        // Make the model resident BEFORE the timed request, on a background queue under the caller's
        // thinking spinner: the email model (gemma) may have been TTL-evicted by LM Studio, so the cold
        // load happens here instead of eating the request timeout. ensureReady loads it with its
        // per-model TTL (interop ADR 0004); the request below resets LM Studio's idle clock.
        DispatchQueue.global(qos: .userInitiated).async {
            if backend == .ollama {
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { completion(.badOutput("empty input")); return }
                let t0 = Date()
                switch transport.ollamaChat(LocalModelRef(backend: .ollama, modelID: model),
                                            body: requestBody(selection, model: model, systemPrompt: systemPrompt),
                                            profile: .email, timeout: timeout) {
                case .notReady(let readinessResult):
                    Log.write("email: \(model) could not be made resident in Ollama")
                    completion(CleanupClient.failureResult(for: readinessResult, loadFailureMessage: "model not loaded")
                               ?? .unavailable("model not loaded"))
                case .response(let data, let response, let error):
                    finish(selection, data: data, response: response, error: error, startedAt: t0,
                           completion: completion)
                }
                return
            }
            let readinessResult = readiness(model)
            if let failure = CleanupClient.failureResult(
                for: readinessResult, loadFailureMessage: "model not loaded"
            ) {
                Log.write("email: \(model) could not be made resident")
                completion(failure); return
            }
            request(selection, timeout: timeout, model: model, endpoint: endpoint,
                    systemPrompt: systemPrompt, transport: transport, completion: completion)
        }
    }

    /// The Local adapter Option+M hands `TextTransformClient`: the request's own model on the app its
    /// bundle resolved to.
    static func localAdapter(transport: LocalChatTransport = .live) -> TextTransformClient.AsyncAdapter {
        { req, done in
            email(req.sourceText, timeout: req.timeout, model: req.bundle.modelID,
                  backend: req.bundle.resolvedLocalBackend, systemPrompt: req.systemPrompt,
                  transport: transport, completion: done)
        }
    }

    /// gemma-4-e4b is a reasoner: give it a high ceiling so it can think before emitting the email
    /// (the bench's key methodology adaptation — a low cap cut reasoners off mid-thought).
    private static func requestBody(_ selection: String, model: String, systemPrompt: String) -> [String: Any] {
        [
            "model": model,
            "temperature": Settings.emailTemperature,
            "max_tokens": Settings.emailMaxTokens,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": wrap(selection)],
            ],
        ]
    }

    /// A single chat-completions attempt. No retry, no JIT — `email(_:)` owns that.
    private static func request(_ selection: String,
                                timeout: TimeInterval,
                                model: String,
                                endpoint: URL,
                                systemPrompt: String,
                                transport: LocalChatTransport,
                                completion: @escaping (CleanupClient.Result) -> Void) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.badOutput("empty input")); return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = requestBody(selection, model: model, systemPrompt: systemPrompt)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.unavailable("encode failed")); return
        }
        req.httpBody = data

        let t0 = Date()
        transport.sendLMStudio(req) { data, response, error in
            finish(selection, data: data, response: response, error: error, startedAt: t0,
                   completion: completion)
        }
    }

    /// Classify one answer, from either app, into the delivered email.
    private static func finish(_ selection: String, data: Data?, response: URLResponse?, error: Error?,
                               startedAt t0: Date, completion: @escaping (CleanupClient.Result) -> Void) {
        let dt = Date().timeIntervalSince(t0)
        let classification = CleanupClient.classifyChatResponse(
            data: data, response: response, error: error, logPrefix: "email", elapsed: dt)
        let content: String
        switch classification {
        case .content(let value):
            content = value
        case .failure(let result):
            completion(result); return
        }
        // content is already the final email (LM Studio splits reasoning into reasoning_content, and the
        // Ollama translator maps message.thinking there too), but strip any inline <think> block
        // defensively, then run the shared ASCII/markdown normalizer (em/en dashes, curly quotes, AND
        // markdown backticks).
        let email = CleanupClient.asciiPunctuationNormalized(CleanupClient.stripReasoning(content))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty {
            // The rare transient empty generation. NEVER paste it — surface as bad output so the
            // controller leaves the text untouched + toasts.
            Log.write("email produced empty output (\(String(format: "%.2f", dt))s)")
            completion(.badOutput("empty output")); return
        }
        Log.write("email OK \(selection.count)->\(email.count) chars in \(String(format: "%.2f", dt))s")
        completion(.ok(email))
    }

    /// Synchronous variant for the headless `--email-selftest` seam (mirrors `CleanupClient.cleanupSync`).
    /// Blocks the calling thread on a semaphore — safe off the main loop only.
    static func emailSync(_ selection: String, timeout: TimeInterval) -> (CleanupClient.Result, TimeInterval) {
        let sem = DispatchSemaphore(value: 0)
        var out: CleanupClient.Result = .unavailable("no result")
        let t0 = Date()
        email(selection, timeout: timeout) { r in out = r; sem.signal() }
        // Wait past the request timeout (plus a JIT-load retry budget) so a genuine timeout returns
        // through the normal path rather than the semaphore wait.
        _ = sem.wait(timeout: .now() + timeout * 2 + 100)
        return (out, Date().timeIntervalSince(t0))
    }
}
