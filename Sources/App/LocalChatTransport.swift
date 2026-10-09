import Foundation

/// The Ollama request profile of each Local surface: the context window it asks for and whether it wants
/// the model's reasoning. One table, so a surface's numbers live in exactly one place.
///
/// D5 (decided 2026-09-30): ViddyDictate always sets `num_ctx` on its own Ollama requests, as fixed constants
/// with no setting: 8192 for cleanup, email and vision (and the surfaces that share their request shapes),
/// 16384 for search retrieval, whose tool results need the room. Without it Ollama loads at its default,
/// which on the maintainer's 64 GB test Mac is 262144 tokens (gemma4:e4b wired +7.31 GB at 8k against +11.25 GB at its
/// 131k max). A resident model already loaded with at least this much context is reused as it is.
///
/// `think` is true only where LM Studio already returns the model's reasoning in `reasoning_content` (email
/// and search synthesis on gemma), so the two apps behave alike; everything else sends `think: false`
/// explicitly, because Ollama's default is inconsistent (Mac probe). Either way it is sent only to a model
/// whose capabilities include `thinking` (`OllamaChatTranslator`).
struct OllamaSurfaceProfile: Equatable {
    let contextTokens: Int
    let think: Bool

    static let cleanup = OllamaSurfaceProfile(contextTokens: 8192, think: false)
    static let promptPrep = OllamaSurfaceProfile(contextTokens: 8192, think: false)
    static let email = OllamaSurfaceProfile(contextTokens: 8192, think: true)
    static let vision = OllamaSurfaceProfile(contextTokens: 8192, think: false)
    static let customMode = OllamaSurfaceProfile(contextTokens: 8192, think: false)
    static let tailCheck = OllamaSurfaceProfile(contextTokens: 8192, think: false)
    static let searchSynthesis = OllamaSurfaceProfile(contextTokens: 8192, think: true)
    static let searchRetrieval = OllamaSurfaceProfile(contextTokens: 16384, think: false)
}

/// How a Local client's chat reaches the app its route resolved to. The clients keep building the
/// OpenAI-shaped body they always built; only the transport forks (spec section 1):
///
/// - **LM Studio**: the client's own `URLRequest`, sent exactly as before (`URLSession.shared`), so an LM
///   Studio bundle hits today's endpoint with today's bytes.
/// - **Ollama**: `ModelManager` readiness at the surface's context (capacity, D5 reuse, the idle window as
///   the load's `keep_alive`), then one native `/api/chat` through `OllamaChatTranslator`, bracketed as a
///   request in flight so the eviction pass never unloads a model mid-answer.
///
/// Injected into every client so the deterministic gate can script both apps; production uses `live`.
struct LocalChatTransport {
    /// LM Studio: send the client's request and call back on an arbitrary queue.
    let sendLMStudio: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void
    /// LM Studio's readiness (`ModelManager.ensureReady` by id, with an optional TTL override), the call
    /// every LM Studio client made before Ollama existed, and whether that call cold-loaded the model.
    let prepareLMStudio: (_ model: String, _ ttlOverrideSeconds: Int?)
        -> (result: ModelManager.ReadinessResult, coldLoaded: Bool)
    /// LM Studio's unload, for the vision helper that unloads straight after its one call.
    let unloadLMStudio: (String) -> Void
    /// Make an Ollama model ready at `(contextTokens, ttlSeconds)`: the readiness, the `num_ctx` the chat
    /// must carry (a reused instance's own, larger context, so the chat does not force a reload), and whether
    /// this call cold-loaded it.
    let prepareOllama: (_ ref: LocalModelRef, _ contextTokens: Int, _ ttlSeconds: Int)
        -> (result: ModelManager.ReadinessResult, contextTokens: Int, coldLoaded: Bool)
    /// One native `/api/chat`, synchronous, its result shaped for `CleanupClient`'s classifiers.
    let chatOllama: (_ openAIBody: [String: Any], _ keepAliveSeconds: Int, _ contextTokens: Int,
                     _ think: Bool, _ timeout: TimeInterval) -> (Data?, HTTPURLResponse?, Error?)
    let unloadOllama: (LocalModelRef) -> Void
    /// The idle window every Ollama request carries as `keep_alive`.
    let keepAliveSeconds: () -> Int
    let beginRequest: (LocalModelRef) -> Void
    let endRequest: (LocalModelRef) -> Void

    static let live = LocalChatTransport.live(keepAliveOverride: nil)

    /// `live` with the idle window overridden, for the services gate that watches a model unload on its own.
    static func live(keepAliveOverride: Int?) -> LocalChatTransport {
        LocalChatTransport(
            sendLMStudio: { request, completion in
                URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
            },
            prepareLMStudio: { model, ttl in
                // Exactly `ensureReady(model, ttlOverrideSeconds: ttl)`, which is this call minus `coldLoaded`.
                let prepared = ModelManager.shared.ensureReadyForChat(
                    LocalModelRef(backend: .lmStudio, modelID: model), ttlOverrideSeconds: ttl)
                return (prepared.result, prepared.coldLoaded)
            },
            // Through ModelManager, so routing stops counting the helper as resident (`RecentLocalLoads`).
            unloadLMStudio: { ModelManager.shared.unload(LocalModelRef(backend: .lmStudio, modelID: $0)) },
            prepareOllama: { ref, contextTokens, ttlSeconds in
                let prepared = ModelManager.shared.ensureReadyForChat(
                    ref, contextTokens: contextTokens, ttlOverrideSeconds: ttlSeconds)
                return (prepared.result, prepared.contextTokens ?? contextTokens, prepared.coldLoaded)
            },
            chatOllama: { body, keepAlive, contextTokens, think, timeout in
                OllamaBackend.shared.chat(openAIBody: body, keepAliveSeconds: keepAlive,
                                          contextTokens: contextTokens, think: think, timeout: timeout)
            },
            unloadOllama: { ModelManager.shared.unload($0) },
            keepAliveSeconds: { keepAliveOverride ?? Settings.modelIdleUnloadSeconds },
            beginRequest: { ModelManager.shared.beginRequest(on: $0) },
            endRequest: { ModelManager.shared.endRequest(on: $0) })
    }

    /// What one Ollama call came to: refused before any chat (the readiness, for the caller's own wording),
    /// or the chat's transport result for the caller's existing classifier, with whether the readiness step
    /// cold-loaded the model for this call.
    enum OllamaOutcome {
        case notReady(ModelManager.ReadinessResult)
        case response(Data?, URLResponse?, Error?, coldLoaded: Bool)
    }

    /// The Ollama half every Local client shares. Synchronous: call it OFF the main thread. The cold load
    /// (if any) happens in `prepareOllama`, before the timed chat, as it does for LM Studio.
    ///
    /// `keepAliveSeconds` overrides the configured window for the one surface that has its own (the vision
    /// helper's five minutes, ADR 0006); everything else carries the configured window on both the load and
    /// the chat, so Ollama drops the model after the same idle time LM Studio would.
    func ollamaChat(_ ref: LocalModelRef, body: [String: Any], profile: OllamaSurfaceProfile,
                    timeout: TimeInterval, keepAliveSeconds: Int? = nil) -> OllamaOutcome {
        let keepAlive = keepAliveSeconds ?? self.keepAliveSeconds()
        let prepared = prepareOllama(ref, profile.contextTokens, keepAlive)
        guard prepared.result.isReady else { return .notReady(prepared.result) }
        beginRequest(ref)
        defer { endRequest(ref) }
        let (data, response, error) = chatOllama(body, keepAlive, prepared.contextTokens, profile.think, timeout)
        return .response(data, response, error, coldLoaded: prepared.coldLoaded)
    }
}

extension LocalInstalledModel {
    /// The vision helper from one app's catalog: the smallest model whose capabilities say it can see, a
    /// model with no reported size sorting last. Nil when none can see.
    static func smallestVision(in models: [LocalInstalledModel]?) -> LocalInstalledModel? {
        (models ?? []).filter(\.isVision).min {
            switch ($0.sizeBytes, $1.sizeBytes) {
            case let (left?, right?): return left == right ? $0.ref.modelID < $1.ref.modelID : left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.ref.modelID < $1.ref.modelID
            }
        }
    }
}

/// LM Studio's `reasoning_effort` key and the process-wide memory of the models that reject it.
///
/// A reasoning-capable local model answers a cleanup/selection request in a fraction of the time when
/// told not to think, which is what keeps those surfaces inside `Settings.cleanupTimeout`. LM Studio's
/// OpenAI-compatible server refuses the field for a model that does not accept it with HTTP 400 (or an
/// error body naming the field), and such a model must keep working. A rejection is therefore
/// remembered for the rest of the process, so every later request for that model omits the field: one
/// retry per model, never one per call.
///
/// The key is added on the LM Studio send path ONLY. Ollama's `transport.ollamaChat` receives the same
/// app-built body it always did, byte for byte.
enum LMStudioReasoningEffort {
    static let key = "reasoning_effort"
    static let off = "none"

    private static let lock = NSLock()
    private static var rejectedModels: Set<String> = []

    /// Whether `modelID` has already rejected the field in this process.
    static func isRejected(_ modelID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rejectedModels.contains(modelID)
    }

    /// Remember that `modelID` does not accept the field, so later calls omit it.
    static func rememberRejected(_ modelID: String) {
        lock.lock(); defer { lock.unlock() }
        rejectedModels.insert(modelID)
    }

    /// `baseBody` plus the field, unless the model is known to reject it. Never mutates `baseBody`.
    static func body(_ baseBody: [String: Any], modelID: String) -> [String: Any] {
        guard !isRejected(modelID) else { return baseBody }
        var out = baseBody
        out[key] = off
        return out
    }

    /// True when LM Studio's answer means it rejected the field: HTTP 400, or an error body naming it.
    /// A success-shaped completion that merely mentions the key (choices present) is never a rejection.
    static func rejected(_ data: Data?, _ response: URLResponse?, _ error: Error?) -> Bool {
        if let http = response as? HTTPURLResponse, http.statusCode == 400 { return true }
        guard let data, let text = String(data: data, encoding: .utf8), text.contains(key) else {
            return false
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["choices"] != nil {
            return false
        }
        return true
    }

    /// Build one JSON `POST` for `body` (nil when it cannot be encoded).
    static func request(_ body: [String: Any], endpoint: URL, timeout: TimeInterval) -> URLRequest? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data
        return req
    }

    /// The one LM Studio send path for the reasoning-capable surfaces: send with the field, and on a
    /// rejection retry the same body exactly once without it and remember the model. The completion runs
    /// on the transport's queue, exactly as a bare `sendLMStudio` would.
    static func send(
        baseBody: [String: Any],
        modelID: String,
        endpoint: URL,
        timeout: TimeInterval,
        transport: LocalChatTransport,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        let alreadyRejected = isRejected(modelID)
        let outbound = alreadyRejected ? baseBody : body(baseBody, modelID: modelID)
        guard let outboundRequest = request(outbound, endpoint: endpoint, timeout: timeout) else {
            completion(nil, nil, encodeError())
            return
        }
        transport.sendLMStudio(outboundRequest) { data, response, error in
            guard !alreadyRejected, rejected(data, response, error) else {
                completion(data, response, error)
                return
            }
            rememberRejected(modelID)
            guard let retry = request(baseBody, endpoint: endpoint, timeout: timeout) else {
                completion(nil, nil, encodeError())
                return
            }
            transport.sendLMStudio(retry, completion)
        }
    }

    /// An encode failure carried like an ordinary transport error, so every existing classifier reports
    /// the same "encode failed" reason it did before this helper existed.
    private static func encodeError() -> Error {
        NSError(domain: "ViddyDictate.LMStudioReasoningEffort", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "encode failed"])
    }
}
