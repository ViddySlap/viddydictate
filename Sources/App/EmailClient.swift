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
    static func email(_ selection: String,
                      timeout: TimeInterval = Settings.emailTimeout,
                      model: String = Settings.emailModel,
                      endpoint: URL = Settings.emailEndpoint,
                      systemPrompt: String = Settings.emailSystemPrompt,
                      completion: @escaping (CleanupClient.Result) -> Void) {
        // Make the model resident BEFORE the timed request, on a background queue under the caller's
        // thinking spinner: the email model (gemma) may have been TTL-evicted by LM Studio, so the cold
        // load happens here instead of eating the request timeout. ensureReady loads it with its
        // per-model TTL (interop ADR 0004); the request below resets LM Studio's idle clock.
        DispatchQueue.global(qos: .userInitiated).async {
            guard ModelManager.shared.ensureReady(model) else {
                Log.write("email: \(model) could not be made resident")
                completion(.unavailable("model not loaded")); return
            }
            request(selection, timeout: timeout, model: model, endpoint: endpoint,
                    systemPrompt: systemPrompt, completion: completion)
        }
    }

    /// A single chat-completions attempt. No retry, no JIT — `email(_:)` owns that.
    private static func request(_ selection: String,
                                timeout: TimeInterval,
                                model: String,
                                endpoint: URL,
                                systemPrompt: String,
                                completion: @escaping (CleanupClient.Result) -> Void) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.badOutput("empty input")); return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // gemma-4-e4b is a reasoner: give it a high ceiling so it can think before emitting the email
        // (the bench's key methodology adaptation — a low cap cut reasoners off mid-thought).
        let body: [String: Any] = [
            "model": model,
            "temperature": Settings.emailTemperature,
            "max_tokens": Settings.emailMaxTokens,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": wrap(selection)],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.unavailable("encode failed")); return
        }
        req.httpBody = data

        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, response, error in
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
            // content is already the final email (LM Studio splits reasoning into reasoning_content),
            // but strip any inline <think> block defensively, then run the shared ASCII/markdown
            // normalizer (em/en dashes, curly quotes, AND markdown backticks).
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
        }.resume()
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
