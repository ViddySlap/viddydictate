import Foundation

/// The kind of Ollama install found on this Mac. Presentation input for later setup copy: the desktop app
/// can be opened, a bare CLI (Homebrew's formula, which is all some Macs have) has to be started with
/// `ollama serve` or `brew services`.
enum OllamaInstallKind: String, Equatable {
    case app
    case cli
}

/// Ollama as a `LocalModelBackend`, over its NATIVE HTTP API only (`/api/*`). It never shells out, for
/// inference or residency: the CLI may be absent (app-only installs) and its output is not a contract.
///
/// Why native and not `/v1`: see `OllamaChatTranslator`. In short, `/v1` cannot carry `keep_alive` or
/// `num_ctx`, so every call through it would reset the model's expiry to Ollama's default and, on a
/// 48 GB+ Mac, load a 256k-token KV cache.
///
/// All I/O goes through the injected `Transport`, so the scripted gate can drive every path with no
/// server, no socket and no filesystem. Production uses `.live`.
///
/// **Every method BLOCKS** on a socket for up to its timeout (`ensureLoaded` up to two minutes). Callers
/// run them on a background queue and must never call them on the main thread.
///
/// Residency contract (spec section 5): Ollama owns eviction, ViddyDictate supplies one idle window.
/// Every load and every chat carries `keep_alive` in integer seconds; `unload` is `keep_alive: 0`.
final class OllamaBackend: LocalModelBackend {

    // MARK: - Transport (the gate seam)

    /// What a path probe reports. `exists` follows symlinks, so Homebrew's `bin/ollama` link to the Cellar
    /// counts as the file it points at.
    struct PathStatus: Equatable {
        let exists: Bool
        let isDirectory: Bool
        let isExecutable: Bool

        static let missing = PathStatus(exists: false, isDirectory: false, isExecutable: false)
    }

    /// Every side effect this backend has. `send` is synchronous and must return by `timeout` plus a
    /// small grace, whatever the server does; `pathStatus` answers for one absolute path.
    struct Transport {
        let send: (_ request: URLRequest, _ timeout: TimeInterval) -> (Data?, HTTPURLResponse?, Error?)
        let pathStatus: (_ path: String) -> PathStatus

        static let live = Transport(
            send: { request, timeout in OllamaBackend.liveSend(request, timeout: timeout) },
            pathStatus: { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    return .missing
                }
                return PathStatus(exists: true, isDirectory: isDirectory.boolValue,
                                  isExecutable: FileManager.default.isExecutableFile(atPath: path))
            })
    }

    // MARK: - Constants

    static let defaultBaseURL = "http://127.0.0.1:11434"
    static let defaultPort = 11434

    /// `/api/version` must answer within this (spec section 3 says ~1 s; 1.5 s leaves room for a busy Mac
    /// without making a stopped server feel slow).
    static let versionTimeout: TimeInterval = 1.5
    static let catalogTimeout: TimeInterval = 5
    static let residencyTimeout: TimeInterval = 3
    /// A cold load of a 30B model from disk. The request only returns once the weights are resident.
    static let loadTimeout: TimeInterval = 120
    static let unloadTimeout: TimeInterval = 10

    /// The error domain for failures this backend authors itself (never Ollama's own text).
    static let errorDomain = "OllamaBackend"
    enum ErrorCode: Int {
        /// The OpenAI-shaped body could not be represented as a native `/api/chat` body (no model, no
        /// messages, a remote image, ...). Surfaces as the clients' existing `.unavailable` path.
        case requestNotRepresentable = 1
    }

    /// The desktop app, system-wide and per-user.
    static let appBundlePaths = ["/Applications/Ollama.app", "~/Applications/Ollama.app"]
    /// The CLI's install locations: Homebrew on Apple Silicon, then Intel Homebrew and the app's own
    /// `/usr/local/bin` symlink.
    static let cliPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]

    // MARK: - State

    let baseURL: URL
    private let transport: Transport
    private let homeDirectory: String

    /// `/api/show` capabilities, keyed by model name plus its version (`digest`, else `modified_at`), so
    /// show runs once per model version: a re-pull under the same tag gets a new key and is asked again.
    private var showCache: [String: Set<String>] = [:]
    /// The latest capability answer per canonical model name, for `chat`'s `think` decision.
    private var capabilitiesByName: [String: Set<String>] = [:]
    private let cacheLock = NSLock()

    /// - Parameters:
    ///   - environment: read for `OLLAMA_HOST` only. See `baseURL(ollamaHost:)` for the rules.
    ///   - homeDirectory: expands `~` in `appBundlePaths`. Under verify's scratch HOME only the
    ///     system-wide paths can match, which is the point of the scratch HOME.
    init(transport: Transport = .live,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: String = NSHomeDirectory()) {
        self.transport = transport
        self.homeDirectory = homeDirectory
        self.baseURL = OllamaBackend.baseURL(ollamaHost: environment["OLLAMA_HOST"])
    }

    var id: LocalBackendID { .ollama }

    // MARK: - Detection

    /// The app wins over the CLI when both are present, because the app is what the user opens. Nil when
    /// neither is found. The app's bundle is only checked for existence here; the installer slice owns
    /// bundle-id and signature checks.
    var installKind: OllamaInstallKind? {
        if installedAppPath != nil { return .app }
        for path in Self.cliPaths {
            let status = transport.pathStatus(path)
            if status.exists && !status.isDirectory && status.isExecutable { return .cli }
        }
        return nil
    }

    /// The expanded path of the first desktop app found, in `appBundlePaths` order, or nil for a CLI-only or
    /// absent install. Recorded because the app must be opened by PATH: right after an install LaunchServices
    /// has not registered it yet, and `open -a Ollama` fails with "Unable to find application" (Mac probe B3).
    var installedAppPath: String? {
        for path in Self.appBundlePaths {
            let expanded = path.hasPrefix("~/")
                ? (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
                : path
            let status = transport.pathStatus(expanded)
            if status.exists && status.isDirectory { return expanded }
        }
        return nil
    }

    func isInstalled() -> Bool { installKind != nil }

    /// Only the desktop app is ever started by observation. A CLI-only (Homebrew) install is a daemon the user
    /// runs with `ollama serve` or `brew services`; ViddyDictate does not own it and never starts it.
    var backgroundLaunchPath: String? { installedAppPath }

    /// `GET /api/version` answers 200 with a JSON `version` string within `versionTimeout`. Anything else
    /// (refused, timed out, a non-Ollama server on the port answering with HTML) is "not responding".
    func serverResponds() -> Bool {
        guard let data = get("api/version", timeout: Self.versionTimeout),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    // MARK: - Catalog

    /// `/api/tags`, enriched by `/api/show` for every usable row whose capabilities `/api/tags` did not
    /// answer (Ollama before 0.34 omits them there). Cloud and non-completion models are excluded, by
    /// `OllamaCatalog.usableLocalModels`, both before show (no show for a model we would drop anyway) and
    /// after it (show may reveal an embedding-only model).
    ///
    /// Fails CLOSED: nil on any tags or show transport failure, a non-200, or an unparseable tags body. A
    /// 200 show body without a capability list is an answer ("Ollama said nothing"), not a failure; the
    /// row keeps its unanswered capabilities and stays usable. `[]` is a real empty catalog.
    func installedModels() -> [LocalInstalledModel]? {
        guard let tagsData = get("api/tags", timeout: Self.catalogTimeout),
              let tagged = OllamaCatalog.parseLocalTags(tagsData) else { return nil }
        let versions = Self.tagVersions(tagsData)

        var enriched: [OllamaInstalledModel] = []
        for model in tagged {
            guard model.capabilities.isEmpty else {
                enriched.append(model)
                continue
            }
            let key = "\(model.name)\u{0}\(versions[model.name] ?? "")"
            if let cached = cachedShow(key) {
                enriched.append(model.mergingCapabilities(cached))
                continue
            }
            guard let showData = post("api/show", body: ["model": model.name], timeout: Self.catalogTimeout)
            else { return nil }
            let answered = OllamaCatalog.parseShowCapabilities(showData) ?? []
            storeShow(answered, key: key)
            enriched.append(model.mergingCapabilities(answered))
        }

        let usable = OllamaCatalog.usableLocalModels(enriched)
        cacheLock.lock()
        for model in usable {
            capabilitiesByName[Self.canonicalModelName(model.name)] = model.capabilities
        }
        cacheLock.unlock()
        return usable.map(Self.installedModel(from:))
    }

    /// One Ollama row in the backend-neutral shape. An empty capability list means Ollama did not answer,
    /// so tools and thinking stay nil ("unknown"), never false.
    static func installedModel(from model: OllamaInstalledModel) -> LocalInstalledModel {
        let answered = !model.capabilities.isEmpty
        return LocalInstalledModel(
            ref: LocalModelRef(backend: .ollama, modelID: model.name),
            label: model.name,
            sizeBytes: model.sizeBytes,
            isVision: model.isVision,
            supportsTools: answered ? model.supportsTools : nil,
            supportsThinking: answered ? model.supportsThinking : nil)
    }

    /// Every usable model from `installedModels()`, tagged `.ollama`, in Ollama's own order. Ollama's catalog
    /// already drops cloud and non-completion models, so nothing further is filtered here.
    func routableModelOptions() -> [LMStudioModelOption]? {
        installedModels()?.map {
            LMStudioModelOption(modelID: $0.ref.modelID, label: $0.label, sizeBytes: $0.sizeBytes,
                                backend: .ollama)
        }
    }

    // MARK: - Residency

    /// `GET /api/ps`, fail closed (see `OllamaCatalog.parseResident`). Ollama reports no last-use time and
    /// no idle/busy flag, so both stay nil; the capacity slice stamps its own last use.
    func residentModels() -> [LocalResidentModel]? {
        residentSnapshot()?.map(Self.residentModel(from:))
    }

    static func residentModel(from model: OllamaResidentModel) -> LocalResidentModel {
        LocalResidentModel(
            ref: LocalModelRef(backend: .ollama, modelID: model.name),
            residentBytes: UInt64(max(0, model.sizeBytes)),
            lastUsed: nil,
            isIdle: nil,
            expiresAt: model.expiresAt,
            contextLength: model.contextLength)
    }

    /// Already resident (in `/api/ps`) is success with NO request, even when it is loaded with a different
    /// context. A request carrying another `num_ctx` would force a reload, and any request would reset the
    /// expiry the model was loaded with; spec section 4 reuses the resident context instead.
    ///
    /// An unreadable `/api/ps` is false: without it this cannot tell a cold load from a forced reload of a
    /// model someone else is using. A ref naming another backend is refused.
    func ensureLoaded(_ ref: LocalModelRef, ttlSeconds: Int, contextTokens: Int?) -> Bool {
        guard ref.backend == id, let resident = residentSnapshot() else { return false }
        if Self.contains(resident, ref.modelID) { return true }
        return load(ref, ttlSeconds: ttlSeconds, contextTokens: contextTokens)
    }

    /// The unconditional load: `POST /api/generate` with an empty prompt (Ollama loads and returns without
    /// generating), then confirmed with `/api/ps`. `options` is omitted when no context is requested, so
    /// Ollama's own default applies rather than a guessed number. Split out of `ensureLoaded` so the gate
    /// can run the "always loads" mutant against the real request.
    func load(_ ref: LocalModelRef, ttlSeconds: Int, contextTokens: Int?) -> Bool {
        guard ref.backend == id else { return false }
        var body: [String: Any] = [
            "model": ref.modelID,
            "prompt": "",
            "stream": false,
            "keep_alive": ttlSeconds,
        ]
        if let contextTokens {
            body["options"] = ["num_ctx": contextTokens]
        }
        guard post("api/generate", body: body, timeout: Self.loadTimeout) != nil else {
            Log.write("ollama: load of \(ref.modelID) failed")
            return false
        }
        guard let resident = residentSnapshot(), Self.contains(resident, ref.modelID) else {
            Log.write("ollama: \(ref.modelID) answered the load but is not in /api/ps")
            return false
        }
        return true
    }

    /// `POST /api/generate {"model", "keep_alive": 0}`. Idempotent: a model `/api/ps` does not list is left
    /// alone with no request at all. An unreadable `/api/ps` still sends the unload, which Ollama treats
    /// as a no-op for a model it is not holding. A ref naming another backend is ignored.
    func unload(_ ref: LocalModelRef) {
        guard ref.backend == id else { return }
        if let resident = residentSnapshot(), !Self.contains(resident, ref.modelID) { return }
        let body: [String: Any] = ["model": ref.modelID, "keep_alive": 0]
        if post("api/generate", body: body, timeout: Self.unloadTimeout) == nil {
            Log.write("ollama: unload of \(ref.modelID) failed")
        }
    }

    // MARK: - Chat

    /// One chat turn for a client that speaks OpenAI chat-completions, sent as native `POST /api/chat`.
    ///
    /// The result is shaped for `CleanupClient.classifyChatResponse` / `classifyToolCapableChatResponse`
    /// to consume unchanged. The rule is that success is only ever synthesized from a translated body:
    /// - translated: OpenAI-shaped Data and a synthesized 200 whose URL is the `/api/chat` URL;
    /// - a transport error (refused, timed out): passed through untouched, so a timeout stays `.timedOut`;
    /// - a non-2xx (Ollama's `{"error": "model 'x' not found"}` is a 404): Ollama's own body and status,
    ///   so the classifier reports `.unavailable("HTTP 404")`;
    /// - a 2xx that does not translate (an in-body `error`, no `message`, a malformed tool call): Ollama's
    ///   own body and status, which has no `choices`, so the classifier reports `.unavailable("bad
    ///   response shape")`, the same outcome as a malformed LM Studio body.
    /// Ollama's error text is logged, never put into the result: `.unavailable` strings are app-authored
    /// (`CleanupClient.capacityRefusalMessage` is the allowlist for what reaches the user).
    ///
    /// `think` is sent only when the catalog says the model has the `thinking` capability (Ollama rejects
    /// it otherwise). The answer comes from the capability cache, filled by `installedModels()` on a miss.
    ///
    /// `contextTokens` goes on the wire as `num_ctx` exactly. A caller that has already reused a resident
    /// model (`ensureLoaded` returned true without loading) must pass that model's `contextLength` from
    /// `residentModels()`, or this request reloads it at the new size.
    func chat(openAIBody: [String: Any], keepAliveSeconds: Int, contextTokens: Int, think: Bool,
              timeout: TimeInterval) -> (Data?, HTTPURLResponse?, Error?) {
        guard let model = (openAIBody["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            return (nil, nil, Self.notRepresentable("no model in the chat body"))
        }
        let thinkingCapable = capabilities(for: model)?.contains(OllamaCatalog.Capability.thinking) ?? false
        guard let native = OllamaChatTranslator.nativeRequestBody(
                fromOpenAI: openAIBody, keepAliveSeconds: keepAliveSeconds, contextTokens: contextTokens,
                thinkingCapable: thinkingCapable, think: think),
              let url = endpoint("api/chat"),
              let request = Self.jsonRequest(url: url, method: "POST", body: native) else {
            return (nil, nil, Self.notRepresentable("chat body is not representable as /api/chat"))
        }

        let (data, response, error) = transport.send(request, timeout)
        if error != nil { return (data, response, error) }
        guard let response else { return (data, nil, nil) }
        guard (200..<300).contains(response.statusCode) else {
            Log.write("ollama: /api/chat HTTP \(response.statusCode): \(Self.providerErrorText(data) ?? "no error text")")
            return (data, response, nil)
        }
        guard let data else { return (nil, response, nil) }
        do {
            let translated = try OllamaChatTranslator.openAIResponse(fromNative: data)
            let synthesized = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
            return (translated, synthesized, nil)
        } catch {
            Log.write("ollama: /api/chat reply did not translate: \(error)")
            return (data, response, nil)
        }
    }

    /// The model's capabilities from the cache, refreshing the catalog once on a miss. Nil when the model
    /// is not in the catalog at all.
    private func capabilities(for model: String) -> Set<String>? {
        let key = Self.canonicalModelName(model)
        if let cached = cachedCapabilities(key) { return cached }
        _ = installedModels()
        return cachedCapabilities(key)
    }

    // MARK: - OLLAMA_HOST

    /// The server URL for an `OLLAMA_HOST` value, mirroring Ollama's own `envconfig.Host()` (the server
    /// binds with that function, so reading it the same way connects to where the server listens), with
    /// ONE deliberate difference:
    ///
    /// - unset, blank → `http://127.0.0.1:11434`;
    /// - no scheme → `http`, and a missing port is 11434 (`example.local` → `http://example.local:11434`);
    /// - an explicit `http://` or `https://` with no port gets that scheme's port, 80 or 443, as Ollama
    ///   does (`http://example.local` → `http://example.local:80`);
    /// - `[v6]:port` is accepted; a bare host that is an IP is kept as given;
    /// - a path after the host is kept as a prefix for every endpoint (a reverse proxy mount);
    /// - an unparseable port, a port outside 0...65535, or a scheme other than http(s) → the default URL;
    /// - THE DIFFERENCE: an unspecified bind address (`0.0.0.0`, `::`, or an empty host as in `:11434`)
    ///   becomes `127.0.0.1`. It is how a user tells the SERVER to listen on every interface, not an
    ///   address to connect to, and the server it names is this Mac.
    ///
    /// A non-loopback host is honoured as given, which means text would leave this Mac; the routing slice
    /// decides whether Local may use such a host (`isLoopback`).
    static func baseURL(ollamaHost raw: String?) -> URL {
        let fallback = URL(string: defaultBaseURL)!
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return fallback }

        var scheme = "http"
        var remainder = value
        var defaultPort = Self.defaultPort
        if let marker = value.range(of: "://") {
            scheme = value[..<marker.lowerBound].lowercased()
            remainder = String(value[marker.upperBound...])
            switch scheme {
            case "http": defaultPort = 80
            case "https": defaultPort = 443
            default: return fallback
            }
        }

        var hostPort = remainder
        var path = ""
        if let slash = remainder.firstIndex(of: "/") {
            hostPort = String(remainder[..<slash])
            path = String(remainder[slash...])
            while path.hasSuffix("/") { path.removeLast() }
        }

        var host: String
        var port: String
        if let split = splitHostPort(hostPort) {
            (host, port) = split
        } else {
            // Ollama's fallback: no parseable port means the whole thing is the host (brackets dropped
            // from an IPv6 literal) on the default port.
            host = hostPort.hasPrefix("[") && hostPort.hasSuffix("]")
                ? String(hostPort.dropFirst().dropLast())
                : hostPort
            port = String(defaultPort)
        }
        guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }),
              let portNumber = Int(port), (0...65535).contains(portNumber) else { return fallback }

        if ["", "0.0.0.0", "::", "0:0:0:0:0:0:0:0"].contains(host) {
            host = "127.0.0.1"
        }
        let hostForURL = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(hostForURL):\(portNumber)\(path)") ?? fallback
    }

    /// Go's `net.SplitHostPort`: `host:port` or `[v6]:port`. Nil when there is no port, or when an
    /// unbracketed host has more than one colon (a bare IPv6 literal).
    private static func splitHostPort(_ value: String) -> (String, String)? {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            return (host, String(rest.dropFirst()))
        }
        guard let colon = value.lastIndex(of: ":") else { return nil }
        let host = String(value[..<colon])
        guard !host.contains(":") else { return nil }
        return (host, String(value[value.index(after: colon)...]))
    }

    /// Whether `baseURL` points at this Mac.
    var isLoopback: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    // MARK: - Names

    /// Ollama's implicit tag: `llama3` and `llama3:latest` name the same model, and `/api/ps` reports the
    /// tagged form. Only the last path segment carries the tag (`hf.co/org/repo:Q4_K_M`).
    static func canonicalModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastSegment = trimmed.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        return lastSegment.contains(":") ? trimmed : trimmed + ":latest"
    }

    private static func contains(_ resident: [OllamaResidentModel], _ modelID: String) -> Bool {
        let wanted = canonicalModelName(modelID)
        return resident.contains { canonicalModelName($0.name) == wanted }
    }

    // MARK: - HTTP helpers

    private func residentSnapshot() -> [OllamaResidentModel]? {
        get("api/ps", timeout: Self.residencyTimeout).flatMap(OllamaCatalog.parseResident)
    }

    func endpoint(_ path: String) -> URL? {
        URL(string: baseURL.absoluteString + "/" + path)
    }

    /// The body of a 2xx GET, or nil on a transport error or any other status.
    private func get(_ path: String, timeout: TimeInterval) -> Data? {
        guard let url = endpoint(path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return successBody(transport.send(request, timeout))
    }

    /// The body of a 2xx POST (an empty body reads as empty Data), or nil on failure.
    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) -> Data? {
        guard let url = endpoint(path),
              let request = Self.jsonRequest(url: url, method: "POST", body: body) else { return nil }
        return successBody(transport.send(request, timeout))
    }

    private func successBody(_ result: (Data?, HTTPURLResponse?, Error?)) -> Data? {
        let (data, response, error) = result
        guard error == nil, let response, (200..<300).contains(response.statusCode) else { return nil }
        return data ?? Data()
    }

    /// Keys sorted, so the same request is the same bytes. Validity is checked first because
    /// `data(withJSONObject:)` raises an Objective-C exception, not a Swift error, on a non-JSON value.
    private static func jsonRequest(url: URL, method: String, body: [String: Any]) -> URLRequest? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func notRepresentable(_ reason: String) -> NSError {
        NSError(domain: errorDomain, code: ErrorCode.requestNotRepresentable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Ollama request not representable: \(reason)"])
    }

    /// Ollama's `error` string, for the log only.
    private static func providerErrorText(_ data: Data?) -> String? {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }

    /// Each `/api/tags` row's version: `digest`, else `modified_at`, keyed by the name `parseTags` reports
    /// (trimmed `name`, else `model`). A row with neither version field keys on its name alone.
    static func tagVersions(_ data: Data) -> [String: String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["models"] as? [Any] else { return [:] }
        var versions: [String: String] = [:]
        for element in rows {
            guard let row = element as? [String: Any] else { continue }
            let name = ((row["name"] as? String) ?? (row["model"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, versions[name] == nil else { continue }
            versions[name] = (row["digest"] as? String) ?? (row["modified_at"] as? String) ?? ""
        }
        return versions
    }

    // MARK: - Cache access

    private func cachedShow(_ key: String) -> Set<String>? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return showCache[key]
    }

    private func storeShow(_ capabilities: Set<String>, key: String) {
        cacheLock.lock()
        showCache[key] = capabilities
        cacheLock.unlock()
    }

    private func cachedCapabilities(_ canonicalName: String) -> Set<String>? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return capabilitiesByName[canonicalName]
    }

    // MARK: - Live transport

    /// One URLSession request made synchronous. The request's own `timeoutInterval` is the idle timeout;
    /// the semaphore adds a hard ceiling one second later, after which the task is cancelled and the
    /// caller gets `NSURLErrorTimedOut`, so a wedged socket can never hold a background queue past it.
    /// The box is locked because a late completion can race the timed-out return.
    private static func liveSend(_ original: URLRequest,
                                 timeout: TimeInterval) -> (Data?, HTTPURLResponse?, Error?) {
        final class Box {
            private let lock = NSLock()
            private var value: (Data?, HTTPURLResponse?, Error?)?
            func set(_ result: (Data?, HTTPURLResponse?, Error?)) {
                lock.lock(); if value == nil { value = result }; lock.unlock()
            }
            func get() -> (Data?, HTTPURLResponse?, Error?)? {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        var request = original
        request.timeoutInterval = timeout
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = liveSession.dataTask(with: request) { data, response, error in
            box.set((data, response as? HTTPURLResponse, error))
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            box.set((nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        }
        return box.get() ?? (nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
    }

    /// Ephemeral: nothing about local inference is cached or persisted by URLSession.
    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
