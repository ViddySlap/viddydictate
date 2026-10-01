import Foundation

/// G-S2b (`--ollama-backend-selftest`): the live `OllamaBackend` driven end to end over a SCRIPTED
/// transport. A small in-memory Ollama answers `/api/version`, `/api/tags`, `/api/show`, `/api/ps`,
/// `/api/generate` and `/api/chat` from fixtures, keeps a resident set that loads and unloads really
/// change, and records every request (method, path, JSON body, timeout). No socket, no Ollama, no
/// filesystem: the install probe is scripted too.
///
/// Distinct values everywhere, so a default cannot pass by accident: the idle window is **437** (never the
/// app's 600), the requested context is 8192 while the resident one is **32768**, and the models are
/// `ollama-fixture-actually-installed:latest` and a separate thinking model.
///
/// Negative controls: the contract is re-run against three broken backends, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) `ensureLoaded` that always sends `/api/generate` (the real `load`, skipping the resident check);
/// (b) chat over `/v1/chat/completions` with the OpenAI body unchanged;
/// (c) no show cache (a fresh backend per catalog read).
enum OllamaBackendScriptedSelfTest {
    private static let keepAlive = 437
    private static let requestedContext = 8192
    private static let residentContext = 32768
    private static let installedName = "ollama-fixture-actually-installed:latest"
    private static let thinkerName = "ollama-fixture-deliberate-thinker:7b"
    private static let quietEmbedderName = "ollama-fixture-quiet-embedder:latest"
    private static let missingName = "ollama-fixture-never-pulled:latest"
    private static let fixtureHome = "/fixture-home"
    private static let residentExpiry = "2026-09-30T14:10:04.129643576-06:00"

    // Assertion names the negative controls look up.
    private static let showCacheCheck = "show runs once per model version across two installedModels() calls"
    private static let residentReuseCheck =
        "ensureLoaded on a model resident at a different context (32768) sends no /api/generate"
    private static let nativeChatCheck =
        "chat is POST /api/chat with a native body: keep_alive 437, options.num_ctx 8192, no tool_choice"

    static func run() -> Bool {
        print("=== Ollama backend scripted-transport selftest (native HTTP API) ===")
        let reporter = SelfTestReporter()

        print("--- backend contract (real backend) ---")
        checkContract(realSubject, reporter)
        checkDetection(reporter)
        checkServerResponds(reporter)
        checkCatalogDetails(reporter)
        checkResidency(reporter)
        checkChatDetails(reporter)
        checkHostNormalization(reporter)
        checkNegativeControls(reporter)

        print(reporter.passed
            ? "[ollama-backend-selftest] PASS"
            : "[ollama-backend-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - The scripted Ollama

    private struct Recorded {
        let method: String
        let path: String
        let host: String?
        let port: Int?
        let body: [String: Any]?
        let timeout: TimeInterval

        var model: String? { body?["model"] as? String }
    }

    private struct Reply {
        let data: Data?
        let status: Int?
        let error: Error?

        static func json(_ text: String, _ status: Int = 200) -> Reply {
            Reply(data: Data(text.utf8), status: status, error: nil)
        }
        static func failure(_ code: Int) -> Reply {
            Reply(data: nil, status: nil, error: NSError(domain: NSURLErrorDomain, code: code))
        }
    }

    private final class FakeOllama {
        private(set) var requests: [Recorded] = []
        /// name -> loaded context. The thinker starts resident at the "wrong" context.
        var resident: [String: Int]
        var residentOrder: [String]
        var tagsBody: String
        var showBodies: [String: String]
        /// Per-path replies that win over the scripted server, for failure cases.
        var overrides: [String: Reply] = [:]
        var chatReply: Reply = .json("""
        {"model":"ollama-fixture-actually-installed:latest","created_at":"2026-09-30T20:10:04Z",
         "message":{"role":"assistant","content":"Fixture cleaned text."},"done":true,"done_reason":"stop"}
        """)
        var paths: [String: OllamaBackend.PathStatus] = [:]

        init() {
            resident = [OllamaBackendScriptedSelfTest.thinkerName: OllamaBackendScriptedSelfTest.residentContext]
            residentOrder = [OllamaBackendScriptedSelfTest.thinkerName]
            tagsBody = OllamaBackendScriptedSelfTest.tagsFixture(installedDigest: "fixture-digest-installed-one")
            showBodies = OllamaBackendScriptedSelfTest.showFixtures
        }

        var transport: OllamaBackend.Transport {
            OllamaBackend.Transport(
                send: { request, timeout in self.handle(request, timeout: timeout) },
                pathStatus: { path in self.paths[path] ?? .missing })
        }

        func count(_ path: String, model: String? = nil) -> Int {
            requests.filter { $0.path == path && (model == nil || $0.model == model) }.count
        }

        func clearLog() { requests.removeAll() }

        private func handle(_ request: URLRequest, timeout: TimeInterval) -> (Data?, HTTPURLResponse?, Error?) {
            let url = request.url
            let path = url?.path ?? ""
            let body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            requests.append(Recorded(method: request.httpMethod ?? "GET", path: path, host: url?.host,
                                     port: url?.port, body: body, timeout: timeout))
            let reply = overrides[path] ?? serve(path: path, body: body)
            let response = reply.status.flatMap { status in
                url.flatMap { HTTPURLResponse(url: $0, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) }
            }
            return (reply.data, response, reply.error)
        }

        private func serve(path: String, body: [String: Any]?) -> Reply {
            let model = body?["model"] as? String
            switch path {
            case "/api/version":
                return .json("{\"version\":\"0.35.0\"}")
            case "/api/tags":
                return .json(tagsBody)
            case "/api/show":
                guard let model, let show = showBodies[model] else {
                    return .json("{\"error\":\"model not found\"}", 404)
                }
                return .json(show)
            case "/api/ps":
                let rows = residentOrder.compactMap { name -> String? in
                    guard let context = resident[name] else { return nil }
                    return "{\"name\":\"\(name)\",\"model\":\"\(name)\",\"size\":6100000000,"
                        + "\"size_vram\":6000000000,\"expires_at\":\"\(OllamaBackendScriptedSelfTest.residentExpiry)\","
                        + "\"context_length\":\(context)}"
                }
                return .json("{\"models\":[\(rows.joined(separator: ","))]}")
            case "/api/generate":
                guard let model else { return .json("{\"error\":\"model is required\"}", 400) }
                let keepAlive = (body?["keep_alive"] as? NSNumber)?.intValue
                if keepAlive == 0 {
                    resident[model] = nil
                    residentOrder.removeAll { $0 == model }
                    return .json("{\"model\":\"\(model)\",\"response\":\"\",\"done\":true,\"done_reason\":\"unload\"}")
                }
                guard showBodies[model] != nil else {
                    return .json("{\"error\":\"model '\(model)' not found\"}", 404)
                }
                let options = body?["options"] as? [String: Any]
                resident[model] = (options?["num_ctx"] as? NSNumber)?.intValue ?? 4096
                if !residentOrder.contains(model) { residentOrder.append(model) }
                return .json("{\"model\":\"\(model)\",\"response\":\"\",\"done\":true,\"done_reason\":\"load\"}")
            case "/api/chat":
                return chatReply
            case "/v1/chat/completions":
                // What a /v1 transport would get back: already OpenAI-shaped, so only the wire checks can
                // catch a backend that uses it.
                return .json("""
                {"choices":[{"index":0,"message":{"role":"assistant","content":"Fixture cleaned text."},
                 "finish_reason":"stop"}]}
                """)
            default:
                return .json("{\"error\":\"not found\"}", 404)
            }
        }
    }

    // MARK: - Fixtures

    /// Ollama 0.33-style tags (no capabilities on most rows), so show has work to do. One cloud row and one
    /// tags-declared embedding model must never be shown; one row is an embedder only show reveals.
    private static func tagsFixture(installedDigest: String) -> String {
        """
        {"models":[
          {"name":"\(installedName)","model":"\(installedName)","modified_at":"2026-09-29T10:00:00.5-06:00",
           "size":3338000000,"digest":"\(installedDigest)",
           "details":{"family":"gemma4","parameter_size":"4.3B","quantization_level":"Q4_K_M"}},
          {"name":"\(thinkerName)","model":"\(thinkerName)","modified_at":"2026-09-28T09:00:00Z",
           "size":5200000000,"digest":"fixture-digest-thinker",
           "details":{"family":"qwen3","parameter_size":"7.6B","quantization_level":"Q4_K_M"}},
          {"name":"ollama-fixture-remote:120b-cloud","model":"ollama-fixture-remote:120b-cloud",
           "size":384,"remote_host":"https://ollama.com:443","remote_model":"ollama-fixture-remote:120b"},
          {"name":"ollama-fixture-declared-embedder:latest","size":1200000000,"capabilities":["embedding"]},
          {"name":"\(quietEmbedderName)","size":670000000,"digest":"fixture-digest-quiet"}
        ]}
        """
    }

    private static let showFixtures: [String: String] = [
        installedName: "{\"capabilities\":[\"completion\",\"tools\"],\"model_info\":{}}",
        thinkerName: "{\"capabilities\":[\"completion\",\"thinking\",\"tools\"]}",
        quietEmbedderName: "{\"capabilities\":[\"embedding\"]}",
    ]

    /// Email-shaped, plus `tools` and a `tool_choice` the native body must drop.
    private static func chatBody(model: String) -> [String: Any] {
        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "web_search",
                "parameters": ["type": "object", "properties": ["query": ["type": "string"]]],
            ] as [String: Any],
        ]
        return [
            "model": model,
            "temperature": 0.3,
            "max_tokens": 1234,
            "stream": false,
            "tools": [tool],
            "tool_choice": "auto",
            "messages": [
                ["role": "system", "content": "fixture system prompt"],
                ["role": "user", "content": "fixture notes"],
            ],
        ]
    }

    // MARK: - Subjects (what the negative controls replace)

    private struct BackendSubject {
        let installedModels: () -> [LocalInstalledModel]?
        let ensureLoaded: (LocalModelRef, Int, Int?) -> Bool
        let chat: ([String: Any], Int, Int, Bool, TimeInterval) -> (Data?, HTTPURLResponse?, Error?)
    }

    private typealias SubjectFactory = (FakeOllama) -> BackendSubject

    private static func makeBackend(_ fake: FakeOllama, environment: [String: String] = [:]) -> OllamaBackend {
        OllamaBackend(transport: fake.transport, environment: environment, homeDirectory: fixtureHome)
    }

    private static let realSubject: SubjectFactory = { fake in
        let backend = makeBackend(fake)
        return BackendSubject(
            installedModels: { backend.installedModels() },
            ensureLoaded: { backend.ensureLoaded($0, ttlSeconds: $1, contextTokens: $2) },
            chat: { backend.chat(openAIBody: $0, keepAliveSeconds: $1, contextTokens: $2, think: $3, timeout: $4) })
    }

    // MARK: - Contract (the part the mutants are run against)

    private static func checkContract(_ factory: SubjectFactory, _ reporter: SelfTestReporter) {
        let fake = FakeOllama()
        let subject = factory(fake)

        let first = subject.installedModels()
        let second = subject.installedModels()
        reporter.record(
            "installedModels: tags + show merge to the usable list; cloud and embedding rows excluded",
            first?.map(\.ref.modelID) == [installedName, thinkerName] && second == first,
            first?.map(\.ref.modelID).joined(separator: ", ") ?? "nil")
        let shows = [installedName, thinkerName, quietEmbedderName].map { fake.count("/api/show", model: $0) }
        reporter.record(showCacheCheck, shows == [1, 1, 1] && fake.count("/api/show") == 3,
                        "show calls per model \(shows)")

        fake.clearLog()
        let loaded = subject.ensureLoaded(
            LocalModelRef(backend: .ollama, modelID: installedName), keepAlive, requestedContext)
        let generates = fake.requests.filter { $0.path == "/api/generate" }
        let load = generates.first?.body
        let options = load?["options"] as? [String: Any]
        reporter.record(
            "ensureLoaded on a non-resident model sends exactly one /api/generate: keep_alive 437, num_ctx 8192",
            loaded && generates.count == 1 && generates.first?.method == "POST"
                && (load?["keep_alive"] as? NSNumber)?.intValue == keepAlive && !(load?["keep_alive"] is String)
                && (options?["num_ctx"] as? NSNumber)?.intValue == requestedContext
                && load?["prompt"] as? String == "" && load?["model"] as? String == installedName,
            "generates=\(generates.count) keep_alive=\(load?["keep_alive"] ?? "absent")")

        fake.clearLog()
        let reused = subject.ensureLoaded(
            LocalModelRef(backend: .ollama, modelID: thinkerName), keepAlive, requestedContext)
        reporter.record(residentReuseCheck,
                        reused && fake.count("/api/generate") == 0 && fake.resident[thinkerName] == residentContext,
                        "generates=\(fake.count("/api/generate"))")

        fake.clearLog()
        let (data, response, error) = subject.chat(chatBody(model: installedName), keepAlive, requestedContext,
                                                   true, 30)
        let sent = fake.requests.last
        let sentOptions = sent?.body?["options"] as? [String: Any]
        reporter.record(
            nativeChatCheck,
            fake.requests.count >= 1 && sent?.path == "/api/chat" && sent?.method == "POST"
                && (sent?.body?["keep_alive"] as? NSNumber)?.intValue == keepAlive
                && (sentOptions?["num_ctx"] as? NSNumber)?.intValue == requestedContext
                && sent?.body?["tool_choice"] == nil && (sent?.body?["stream"] as? NSNumber)?.boolValue == false,
            "\(sent?.method ?? "-") \(sent?.path ?? "-")")
        var content: String?
        if case .content(let value) = CleanupClient.classifyChatResponse(
            data: data, response: response, error: error, logPrefix: "ollama-backend-selftest", elapsed: 0) {
            content = value
        }
        reporter.record("the chat result classifies as content through CleanupClient.classifyChatResponse",
                        content == "Fixture cleaned text.", content ?? "nil")
    }

    // MARK: - Detection

    private static func checkDetection(_ reporter: SelfTestReporter) {
        print("--- install detection (scripted path probe) ---")
        let directory = OllamaBackend.PathStatus(exists: true, isDirectory: true, isExecutable: true)
        let executable = OllamaBackend.PathStatus(exists: true, isDirectory: false, isExecutable: true)
        let plainFile = OllamaBackend.PathStatus(exists: true, isDirectory: false, isExecutable: false)
        func kind(_ paths: [String: OllamaBackend.PathStatus]) -> (OllamaInstallKind?, Bool, Int) {
            let fake = FakeOllama()
            fake.paths = paths
            let backend = makeBackend(fake)
            return (backend.installKind, backend.isInstalled(), fake.requests.count)
        }
        let appOnly = kind(["/Applications/Ollama.app": directory])
        let userApp = kind(["\(fixtureHome)/Applications/Ollama.app": directory])
        let brewCLI = kind(["/opt/homebrew/bin/ollama": executable])
        let localCLI = kind(["/usr/local/bin/ollama": executable])
        let both = kind(["/Applications/Ollama.app": directory, "/opt/homebrew/bin/ollama": executable])
        let notExecutable = kind(["/opt/homebrew/bin/ollama": plainFile])
        let nothing = kind([:])
        reporter.record("the desktop app in /Applications or ~/Applications is an app install",
                        appOnly.0 == .app && appOnly.1 && userApp.0 == .app && both.0 == .app)
        reporter.record("an executable Homebrew or /usr/local CLI with no app is a CLI install (Ben's Mac)",
                        brewCLI.0 == .cli && brewCLI.1 && localCLI.0 == .cli)
        reporter.record("a non-executable ollama file, or nothing at all, is not installed",
                        notExecutable.0 == nil && !notExecutable.1 && nothing.0 == nil && !nothing.1)
        reporter.record("detection opens no connection",
                        [appOnly, userApp, brewCLI, localCLI, both, notExecutable, nothing].allSatisfy { $0.2 == 0 })
    }

    // MARK: - serverResponds

    private static func checkServerResponds(_ reporter: SelfTestReporter) {
        print("--- serverResponds ---")
        let fake = FakeOllama()
        let backend = makeBackend(fake)
        let up = backend.serverResponds()
        let probe = fake.requests.last
        fake.overrides["/api/version"] = .failure(NSURLErrorCannotConnectToHost)
        let refused = backend.serverResponds()
        fake.overrides["/api/version"] = .json("<html>not ollama</html>")
        let html = backend.serverResponds()
        fake.overrides["/api/version"] = .json("{\"version\":\"0.35.0\"}", 503)
        let unavailable = backend.serverResponds()
        reporter.record("a 200 JSON version answers: GET /api/version within 1.5 s",
                        up && probe?.method == "GET" && probe?.path == "/api/version" && probe?.timeout == 1.5)
        reporter.record("a refused connection is not responding", !refused)
        reporter.record("a 200 non-JSON body (another server on the port) is not responding", !html)
        reporter.record("a non-200 is not responding, even with a version body", !unavailable)
    }

    // MARK: - Catalog details

    private static func checkCatalogDetails(_ reporter: SelfTestReporter) {
        print("--- catalog details ---")
        let fake = FakeOllama()
        let backend = makeBackend(fake)
        let models = backend.installedModels() ?? []
        let installed = models.first { $0.ref.modelID == installedName }
        let thinker = models.first { $0.ref.modelID == thinkerName }
        reporter.record("refs are (.ollama, tag) and sizes are carried from tags",
                        models.allSatisfy { $0.ref.backend == .ollama && $0.label == $0.ref.modelID }
                            && installed?.sizeBytes == 3_338_000_000 && thinker?.sizeBytes == 5_200_000_000)
        reporter.record("capabilities come from show: tools on both, thinking only on the thinker, no vision",
                        installed?.supportsTools == true && installed?.supportsThinking == false
                            && thinker?.supportsThinking == true && installed?.isVision == false)
        let showRequests = fake.requests.filter { $0.path == "/api/show" }
        let shownNames = showRequests.map { $0.model ?? "" }
        reporter.record("show is POST {\"model\": name}, never sent for the cloud or tags-declared embedding row",
                        showRequests.allSatisfy { $0.method == "POST" && $0.body?.count == 1 }
                            && !shownNames.contains { $0.contains("remote") || $0.contains("declared") })

        fake.tagsBody = tagsFixture(installedDigest: "fixture-digest-installed-two")
        _ = backend.installedModels()
        reporter.record("a new digest for the same tag (a re-pull) asks show again, once, for that model only",
                        fake.count("/api/show", model: installedName) == 2
                            && fake.count("/api/show", model: thinkerName) == 1)

        let failing = FakeOllama()
        let failingBackend = makeBackend(failing)
        failing.overrides["/api/tags"] = .failure(NSURLErrorCannotConnectToHost)
        let refused = failingBackend.installedModels()
        failing.overrides["/api/tags"] = .json("{\"error\":\"boom\"}", 500)
        let serverError = failingBackend.installedModels()
        failing.overrides["/api/tags"] = .json("not json")
        let garbage = failingBackend.installedModels()
        failing.overrides["/api/tags"] = .json("{\"models\":[]}")
        let empty = failingBackend.installedModels()
        failing.overrides["/api/tags"] = nil
        failing.overrides["/api/show"] = .failure(NSURLErrorTimedOut)
        let showDown = failingBackend.installedModels()
        reporter.record("nil (unavailable) on a tags transport error, a tags 500 and a non-JSON tags body",
                        refused == nil && serverError == nil && garbage == nil)
        reporter.record("a real empty catalog is [] rather than nil", empty == [])
        reporter.record("a show transport failure fails the catalog closed (nil)", showDown == nil)
    }

    // MARK: - Residency

    private static func checkResidency(_ reporter: SelfTestReporter) {
        print("--- residency ---")
        let fake = FakeOllama()
        let backend = makeBackend(fake)
        let resident = backend.residentModels()
        let thinker = resident?.first
        // The ps row says 6.1 GB and tags says 5.2 GB: the footprint is the TAGS size (S4), because ps
        // under-reports a loaded model 10-20x on a real Mac and must never size a budget or a ranking.
        reporter.record(
            "residentModels maps /api/ps with the tags size (never ps size), context_length and expires_at; "
                + "no lastUsed, no idle flag",
            resident?.count == 1 && thinker?.ref == LocalModelRef(backend: .ollama, modelID: thinkerName)
                && thinker?.residentBytes == 5_200_000_000 && thinker?.contextLength == residentContext
                && thinker?.expiresAt == OllamaCatalog.parseTimestamp(residentExpiry) && thinker?.expiresAt != nil
                && thinker?.lastUsed == nil && thinker?.isIdle == nil)

        fake.clearLog()
        let loaded = backend.ensureLoaded(LocalModelRef(backend: .ollama, modelID: installedName),
                                          ttlSeconds: keepAlive, contextTokens: nil)
        let load = fake.requests.first { $0.path == "/api/generate" }
        reporter.record("with no requested context the load omits options, and it waits up to 120 s",
                        loaded && load?.body?["options"] == nil && load?.timeout == 120)
        reporter.record("the load is confirmed with /api/ps afterwards",
                        fake.requests.last?.path == "/api/ps")

        fake.clearLog()
        backend.unload(LocalModelRef(backend: .ollama, modelID: installedName))
        let unload = fake.requests.filter { $0.path == "/api/generate" }
        reporter.record("unload sends exactly one /api/generate with keep_alive 0 and no prompt",
                        unload.count == 1 && (unload.first?.body?["keep_alive"] as? NSNumber)?.intValue == 0
                            && !(unload.first?.body?["keep_alive"] is String)
                            && unload.first?.model == installedName && unload.first?.body?["prompt"] == nil
                            && fake.resident[installedName] == nil)
        fake.clearLog()
        backend.unload(LocalModelRef(backend: .ollama, modelID: installedName))
        reporter.record("unloading a model that is not resident sends no generate (idempotent)",
                        fake.count("/api/generate") == 0)

        fake.clearLog()
        let lmStudioLoad = backend.ensureLoaded(LocalModelRef(backend: .lmStudio, modelID: installedName),
                                                ttlSeconds: keepAlive, contextTokens: requestedContext)
        backend.unload(LocalModelRef(backend: .lmStudio, modelID: thinkerName))
        reporter.record("an LM Studio ref is refused by ensureLoaded and ignored by unload, with no request",
                        !lmStudioLoad && fake.requests.isEmpty && fake.resident[thinkerName] == residentContext)

        fake.overrides["/api/ps"] = .failure(NSURLErrorCannotConnectToHost)
        fake.clearLog()
        let blind = backend.ensureLoaded(LocalModelRef(backend: .ollama, modelID: installedName),
                                         ttlSeconds: keepAlive, contextTokens: requestedContext)
        reporter.record("an unreadable /api/ps is false with no load (cannot tell a cold load from a reload)",
                        !blind && fake.count("/api/generate") == 0 && backend.residentModels() == nil)
        fake.overrides["/api/ps"] = nil

        let missing = backend.ensureLoaded(LocalModelRef(backend: .ollama, modelID: missingName),
                                           ttlSeconds: keepAlive, contextTokens: requestedContext)
        reporter.record("a load Ollama refuses (404, not pulled) is false", !missing)
    }

    // MARK: - Chat details

    private static func checkChatDetails(_ reporter: SelfTestReporter) {
        print("--- chat details ---")
        let fake = FakeOllama()
        let backend = makeBackend(fake)

        // A fresh backend has no catalog yet: the thinker's first chat must fill it before deciding think.
        _ = backend.chat(openAIBody: chatBody(model: thinkerName), keepAliveSeconds: keepAlive,
                         contextTokens: requestedContext, think: false, timeout: 30)
        let thinkerChat = fake.requests.last { $0.path == "/api/chat" }
        reporter.record("a thinking-capable model gets think with the requested value (false), catalog filled lazily",
                        (thinkerChat?.body?["think"] as? NSNumber)?.boolValue == false
                            && fake.count("/api/tags") == 1)
        _ = backend.chat(openAIBody: chatBody(model: thinkerName), keepAliveSeconds: keepAlive,
                         contextTokens: requestedContext, think: true, timeout: 30)
        let thinkerOn = fake.requests.last { $0.path == "/api/chat" }
        reporter.record("think true reaches the wire for the thinker, and the cached catalog is not re-read",
                        (thinkerOn?.body?["think"] as? NSNumber)?.boolValue == true && fake.count("/api/tags") == 1)

        let (data, response, error) = backend.chat(
            openAIBody: chatBody(model: installedName), keepAliveSeconds: keepAlive,
            contextTokens: requestedContext, think: true, timeout: 30)
        let plain = fake.requests.last { $0.path == "/api/chat" }
        reporter.record("a model without the thinking capability gets no think key, even when asked",
                        plain != nil && plain?.body?["think"] == nil)
        reporter.record("the chat timeout is the caller's, and the result is a 200 whose URL is /api/chat",
                        plain?.timeout == 30 && response?.statusCode == 200 && response?.url?.path == "/api/chat"
                            && error == nil && data != nil)

        fake.chatReply = .json("""
        {"model":"ollama-fixture-actually-installed:latest","message":{"role":"assistant","content":"",
         "tool_calls":[{"function":{"name":"web_search","arguments":{"query":"fixture query"}}}]},
         "done":true,"done_reason":"stop"}
        """)
        let tools = backend.chat(openAIBody: chatBody(model: installedName), keepAliveSeconds: keepAlive,
                                 contextTokens: requestedContext, think: false, timeout: 30)
        var toolQuery: String?
        if case .message(_, let calls) = CleanupClient.classifyToolCapableChatResponse(
            data: tools.0, response: tools.1, error: tools.2),
           let arguments = (calls.first?["function"] as? [String: Any])?["arguments"] as? String,
           let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] {
            toolQuery = object["query"] as? String
        }
        reporter.record("a native tool call reaches classifyToolCapableChatResponse with string arguments",
                        toolQuery == "fixture query", toolQuery ?? "nil")

        fake.chatReply = .json("{\"error\":\"model '\(missingName)' not found\"}", 404)
        let notFound = backend.chat(openAIBody: chatBody(model: missingName), keepAliveSeconds: keepAlive,
                                    contextTokens: requestedContext, think: false, timeout: 30)
        var notFoundMessage: String?
        var notFoundIsContent = false
        switch CleanupClient.classifyChatResponse(data: notFound.0, response: notFound.1, error: notFound.2,
                                                  logPrefix: "ollama-backend-selftest", elapsed: 0) {
        case .content: notFoundIsContent = true
        case .failure(.unavailable(let message)): notFoundMessage = message
        case .failure: break
        }
        reporter.record("an Ollama 404 {\"error\": \"model ... not found\"} is NOT ok: .unavailable(\"HTTP 404\")",
                        !notFoundIsContent && notFoundMessage == "HTTP 404" && notFound.1?.statusCode == 404,
                        notFoundMessage ?? "nil")

        fake.chatReply = .json("{\"error\":\"fixture load failure\"}")
        let inBody = backend.chat(openAIBody: chatBody(model: installedName), keepAliveSeconds: keepAlive,
                                  contextTokens: requestedContext, think: false, timeout: 30)
        var inBodyMessage: String?
        if case .failure(.unavailable(let message)) = CleanupClient.classifyChatResponse(
            data: inBody.0, response: inBody.1, error: inBody.2, logPrefix: "ollama-backend-selftest", elapsed: 0) {
            inBodyMessage = message
        }
        reporter.record("a 200 carrying an Ollama error body is not ok either (bad response shape)",
                        inBodyMessage == "bad response shape", inBodyMessage ?? "nil")

        fake.overrides["/api/chat"] = .failure(NSURLErrorTimedOut)
        let slow = backend.chat(openAIBody: chatBody(model: installedName), keepAliveSeconds: keepAlive,
                                contextTokens: requestedContext, think: false, timeout: 30)
        var timedOut = false
        if case .failure(.timedOut) = CleanupClient.classifyChatResponse(
            data: slow.0, response: slow.1, error: slow.2, logPrefix: "ollama-backend-selftest", elapsed: 0) {
            timedOut = true
        }
        reporter.record("a transport timeout passes through and classifies as .timedOut", timedOut)
        fake.overrides["/api/chat"] = nil

        fake.clearLog()
        var noModel = chatBody(model: installedName)
        noModel["model"] = nil
        let refused = backend.chat(openAIBody: noModel, keepAliveSeconds: keepAlive,
                                   contextTokens: requestedContext, think: false, timeout: 30)
        var refusedUnavailable = false
        if case .failure(.unavailable) = CleanupClient.classifyChatResponse(
            data: refused.0, response: refused.1, error: refused.2, logPrefix: "ollama-backend-selftest", elapsed: 0) {
            refusedUnavailable = true
        }
        reporter.record("a body with no model is refused before any request, as .unavailable",
                        refusedUnavailable && fake.requests.isEmpty)
    }

    // MARK: - OLLAMA_HOST

    private static func checkHostNormalization(_ reporter: SelfTestReporter) {
        print("--- OLLAMA_HOST normalization ---")
        let cases: [(String?, String)] = [
            (nil, "http://127.0.0.1:11434"),
            ("   ", "http://127.0.0.1:11434"),
            ("0.0.0.0:11434", "http://127.0.0.1:11434"),
            ("0.0.0.0", "http://127.0.0.1:11434"),
            ("[::]:11434", "http://127.0.0.1:11434"),
            (":11500", "http://127.0.0.1:11500"),
            ("example.local:9999", "http://example.local:9999"),
            ("example.local", "http://example.local:11434"),
            ("https://x:1", "https://x:1"),
            ("http://example.local", "http://example.local:80"),
            ("HTTPS://proxy.example.local/ollama/", "https://proxy.example.local:443/ollama"),
            ("[::1]:8080", "http://[::1]:8080"),
            ("127.0.0.1:notaport", "http://127.0.0.1:11434"),
            ("127.0.0.1:70000", "http://127.0.0.1:11434"),
            ("ftp://x:1", "http://127.0.0.1:11434"),
        ]
        for (raw, expected) in cases {
            let actual = OllamaBackend.baseURL(ollamaHost: raw).absoluteString
            reporter.record("OLLAMA_HOST \(raw.map { "\"\($0)\"" } ?? "unset") -> \(expected)",
                            actual == expected, actual == expected ? "" : actual)
        }

        let fake = FakeOllama()
        let custom = makeBackend(fake, environment: ["OLLAMA_HOST": "example.local:9999"])
        _ = custom.serverResponds()
        let request = fake.requests.last
        reporter.record("the environment's OLLAMA_HOST is where requests actually go",
                        request?.host == "example.local" && request?.port == 9999 && !custom.isLoopback
                            && makeBackend(fake, environment: ["OLLAMA_HOST": "0.0.0.0"]).isLoopback)
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(_ reporter: SelfTestReporter) {
        // (a) The resident check is skipped: every ensureLoaded goes straight to the real load.
        let alwaysLoads: SubjectFactory = { fake in
            let backend = makeBackend(fake)
            let real = realSubject(fake)
            return BackendSubject(
                installedModels: real.installedModels,
                ensureLoaded: { backend.load($0, ttlSeconds: $1, contextTokens: $2) },
                chat: real.chat)
        }
        requireCaught(reporter, mutant: "ensureLoaded that always sends /api/generate", by: residentReuseCheck) {
            checkContract(alwaysLoads, $0)
        }

        // (b) The /v1 transport: the OpenAI body goes to /v1/chat/completions as-is.
        let overV1: SubjectFactory = { fake in
            let real = realSubject(fake)
            let transport = fake.transport
            return BackendSubject(
                installedModels: real.installedModels,
                ensureLoaded: real.ensureLoaded,
                chat: { body, _, _, _, timeout in
                    guard let url = URL(string: "http://127.0.0.1:11434/v1/chat/completions"),
                          let data = try? JSONSerialization.data(withJSONObject: body) else {
                        return (nil, nil, nil)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = data
                    return transport.send(request, timeout)
                })
        }
        requireCaught(reporter, mutant: "chat over /v1/chat/completions with the body unchanged", by: nativeChatCheck) {
            checkContract(overV1, $0)
        }

        // (c) No show cache: a fresh backend (and so an empty cache) for every catalog read.
        let noShowCache: SubjectFactory = { fake in
            let real = realSubject(fake)
            return BackendSubject(
                installedModels: { makeBackend(fake).installedModels() },
                ensureLoaded: real.ensureLoaded,
                chat: real.chat)
        }
        requireCaught(reporter, mutant: "backend with no show cache", by: showCacheCheck) {
            checkContract(noShowCache, $0)
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
