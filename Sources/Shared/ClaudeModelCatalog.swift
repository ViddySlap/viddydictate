import Foundation

/// Bounds every Claude catalog acquisition obeys. The Claude side talks HTTPS to one pinned vendor
/// host rather than spawning a foreign binary, so it needs none of the process, isolation, or
/// containment budget `CodexCatalogBounds` carries — only the page, size, and time limits that keep a
/// hostile or broken response from becoming unbounded work.
struct ClaudeCatalogBounds {
    let maxPages: Int
    let pageSize: Int
    let maxBodyBytes: Int
    let maxModels: Int
    let maxStringBytes: Int
    let requestTimeout: TimeInterval

    init(
        maxPages: Int = 8,
        pageSize: Int = 1000,
        maxBodyBytes: Int = 1_048_576,
        maxModels: Int = 512,
        maxStringBytes: Int = 4_096,
        requestTimeout: TimeInterval = 20
    ) {
        precondition(maxPages > 0)
        precondition(pageSize > 0)
        precondition(maxBodyBytes > 0)
        precondition(maxModels > 0)
        precondition(maxStringBytes > 0)
        precondition(requestTimeout > 0)
        self.maxPages = maxPages
        self.pageSize = pageSize
        self.maxBodyBytes = maxBodyBytes
        self.maxModels = maxModels
        self.maxStringBytes = maxStringBytes
        self.requestTimeout = requestTimeout
    }
}

/// Every Claude acquisition failure is already spelled by the neutral `ModelCatalogDiagnostic`, so
/// this carries one rather than declaring a second parallel code set.
struct ClaudeCatalogFailure: Error, CustomStringConvertible {
    let diagnostic: ModelCatalogDiagnostic

    init(_ diagnostic: ModelCatalogDiagnostic) {
        self.diagnostic = diagnostic
    }

    var description: String { "claude-catalog:\(diagnostic.rawValue)" }
}

/// Reads the Claude Code OAuth access token the user's own CLI already minted and owns (spec decision
/// 2, piggyback auth: ViddyDictate never implements provider OAuth itself).
///
/// The token is returned to exactly one caller, the transport, which places it in a request header.
/// It is never logged, never written to disk, never placed in argv, and never named in a diagnostic —
/// a failure here reports `providerUnavailable` and nothing else.
enum ClaudeCatalogCredential {
    /// One owner for "where Claude Code keeps its credential"; the transform client resolves the same
    /// file for its availability check.
    static var defaultPath: String { CloudCleanupClient.credentialsPath }

    static func load(
        path: String = defaultPath,
        maxBytes: Int = 65_536
    ) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty,
              token.utf8.count <= maxBytes else {
            throw ClaudeCatalogFailure(.providerUnavailable)
        }
        return token
    }
}

/// `GET /v1/models`, the Claude catalog's source of truth (ADR 0014).
///
/// Two properties matter more than anything else here, because Claude expresses retirement by
/// REMOVING a model rather than by hiding a row:
///
/// 1. **A partial page set is never returned as a catalog.** The walk follows `last_id` until the
///    server clears `has_more`; running out of page budget first is a `paginationViolation`, not a
///    short catalog. A truncated enumeration would read as "everything below the cut is retired".
/// 2. **An empty catalog is invalid.** A well-formed response describing zero models would likewise
///    retire every pinned route at once, so it fails closed instead.
enum ClaudeModelCatalogTransport {
    static let host = "api.anthropic.com"
    static let path = "/v1/models"
    static let apiVersion = "2023-06-01"
    /// An `sk-ant-oat` Claude Code token authenticates only as an OAuth bearer plus this beta header;
    /// `x-api-key` returns 401 for it. A real `sk-ant-api` key still uses `x-api-key`.
    static let oauthBeta = "oauth-2025-04-20"
    static let oauthTokenPrefix = "sk-ant-oat"

    /// Claude advertises effort support as a capability map, and a JSON object has no order, so the
    /// rail publishes efforts in this fixed ascending order rather than inventing one per response.
    static let effortOrder = ["low", "medium", "high", "xhigh", "max"]

    typealias Fetch = (URLRequest) throws -> (status: Int, body: Data)

    static func request(
        token: String,
        afterID: String?,
        bounds: ClaudeCatalogBounds = ClaudeCatalogBounds()
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        var query = [URLQueryItem(name: "limit", value: String(bounds.pageSize))]
        if let afterID {
            guard isBoundedNonempty(afterID, bounds: bounds) else {
                throw ClaudeCatalogFailure(.paginationViolation)
            }
            query.append(URLQueryItem(name: "after_id", value: afterID))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw ClaudeCatalogFailure(.paginationViolation)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = bounds.requestTimeout
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if token.hasPrefix(oauthTokenPrefix) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    static func acquire(
        token: String,
        bounds: ClaudeCatalogBounds = ClaudeCatalogBounds(),
        fetch: Fetch
    ) throws -> ModelCatalog {
        var rows: [ModelCatalogRow] = []
        var seen: Set<String> = []
        var afterID: String?
        var pages = 0

        while pages < bounds.maxPages {
            pages += 1
            let response = try fetch(try request(
                token: token, afterID: afterID, bounds: bounds))
            guard response.status == 200 else {
                throw ClaudeCatalogFailure(.providerUnavailable)
            }
            guard response.body.count <= bounds.maxBodyBytes else {
                throw ClaudeCatalogFailure(.boundExceeded)
            }
            let page = try decodePage(response.body, bounds: bounds)
            for row in page.rows {
                guard rows.count < bounds.maxModels else {
                    throw ClaudeCatalogFailure(.boundExceeded)
                }
                guard seen.insert(row.model).inserted else {
                    throw ClaudeCatalogFailure(.invalidCatalog)
                }
                rows.append(row)
            }
            guard page.hasMore else {
                guard !rows.isEmpty else {
                    throw ClaudeCatalogFailure(.invalidCatalog)
                }
                return ModelCatalog(rows: rows, pageMetadata: [])
            }
            guard let lastID = page.lastID,
                  isBoundedNonempty(lastID, bounds: bounds),
                  lastID != afterID else {
                throw ClaudeCatalogFailure(.paginationViolation)
            }
            afterID = lastID
        }
        throw ClaudeCatalogFailure(.paginationViolation)
    }

    struct Page {
        let rows: [ModelCatalogRow]
        let hasMore: Bool
        let lastID: String?
    }

    static func decodePage(
        _ data: Data,
        bounds: ClaudeCatalogBounds = ClaudeCatalogBounds()
    ) throws -> Page {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [Any] else {
            throw ClaudeCatalogFailure(.protocolViolation)
        }
        guard entries.count <= bounds.maxModels else {
            throw ClaudeCatalogFailure(.boundExceeded)
        }
        let rows = try entries.map { entry -> ModelCatalogRow in
            guard let fields = entry as? [String: Any] else {
                throw ClaudeCatalogFailure(.protocolViolation)
            }
            return try row(from: fields, bounds: bounds)
        }
        // A missing `has_more` is the documented last page; anything present must be a real boolean,
        // because guessing here is the difference between a complete catalog and a truncated one.
        let hasMore: Bool
        switch object["has_more"] {
        case nil, is NSNull: hasMore = false
        case let value as Bool: hasMore = value
        default: throw ClaudeCatalogFailure(.protocolViolation)
        }
        return Page(rows: rows, hasMore: hasMore, lastID: object["last_id"] as? String)
    }

    static func row(
        from fields: [String: Any],
        bounds: ClaudeCatalogBounds = ClaudeCatalogBounds()
    ) throws -> ModelCatalogRow {
        guard let type = fields["type"] as? String, type == "model",
              let id = fields["id"] as? String,
              isBoundedNonempty(id, bounds: bounds) else {
            throw ClaudeCatalogFailure(.protocolViolation)
        }
        let displayName = fields["display_name"] as? String
        if let displayName, !isBoundedNonempty(displayName, bounds: bounds) {
            throw ClaudeCatalogFailure(.boundExceeded)
        }
        let capabilities = fields["capabilities"] as? [String: Any] ?? [:]
        return ModelCatalogRow(
            // Claude has no preset-vs-model split: the id a user pins IS the model the API serves,
            // so both neutral columns carry the same opaque string.
            id: id,
            model: id,
            displayName: displayName,
            description: nil,
            // Retirement is expressed by REMOVAL from this list, never by a hidden row. A listed
            // Claude model is by definition still served.
            hidden: false,
            // Claude advertises no default effort; the CLI's own default is "omit --effort".
            defaultReasoningEffort: nil,
            supportedReasoningEfforts: efforts(from: capabilities),
            inputModalities: modalities(from: capabilities),
            supportsPersonality: nil,
            isDefault: nil,
            // Claude advertises no upgrade edge, which is why its planner derives a successor from the
            // family instead of following one.
            upgrade: nil,
            upgradeInfo: nil,
            unknownFields: [:])
    }

    /// The advertised effort axis, or empty for a model that has none (`effort.supported == false`).
    /// This is metadata for the picker UX, NOT an execution gate: `--effort` is a CLI flag the
    /// transform client omits when empty, and a shipped route may legitimately pin an effort on a
    /// model whose catalog row advertises no effort axis.
    static func efforts(from capabilities: [String: Any]) -> [ModelCatalogReasoningEffort] {
        guard let effort = capabilities["effort"] as? [String: Any],
              effort["supported"] as? Bool == true else { return [] }
        return effortOrder.compactMap { level in
            guard let entry = effort[level] as? [String: Any],
                  entry["supported"] as? Bool == true else { return nil }
            return ModelCatalogReasoningEffort(
                reasoningEffort: level, description: nil, unknownFields: [:])
        }
    }

    /// Every Claude model accepts text; image and PDF are advertised per model.
    static func modalities(from capabilities: [String: Any]) -> [String] {
        var out = ["text"]
        if (capabilities["image_input"] as? [String: Any])?["supported"] as? Bool == true {
            out.append("image")
        }
        if (capabilities["pdf_input"] as? [String: Any])?["supported"] as? Bool == true {
            out.append("pdf")
        }
        return out
    }

    private static func isBoundedNonempty(
        _ value: String,
        bounds: ClaudeCatalogBounds
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= bounds.maxStringBytes
    }
}

/// Refuses to follow a redirect. `api.anthropic.com` never redirects the models endpoint, so a
/// redirect means the request is going somewhere the credential was not minted for.
private final class ClaudeCatalogNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum ClaudeModelCatalogProvider {
    /// Deliberately has NO last-known-good disk cache, unlike the Codex side.
    ///
    /// Claude retirement is judged from what the catalog does NOT contain, so a stale catalog is not
    /// merely less fresh — it is actively dangerous: yesterday's list would keep declaring a model
    /// live, and a list from before a model shipped would declare it retired. The rail already
    /// requires `diagnostic == .current` before it will migrate anything, so a cache could only ever
    /// serve display. Display is P9/P11's surface, and it can render the diagnostic instead.
    static func refresh(
        checkedAt: String,
        bounds: ClaudeCatalogBounds = ClaudeCatalogBounds(),
        credential: () throws -> String = { try ClaudeCatalogCredential.load() },
        fetch: ClaudeModelCatalogTransport.Fetch? = nil
    ) -> ModelCatalogCheckResult {
        do {
            let token = try credential()
            let catalog = try ClaudeModelCatalogTransport.acquire(
                token: token,
                bounds: bounds,
                fetch: fetch ?? productionFetch(bounds: bounds))
            return ModelCatalogCheckResult(
                catalog: catalog,
                checkedAt: checkedAt,
                isStale: false,
                diagnostic: .current)
        } catch let failure as ClaudeCatalogFailure {
            return ModelCatalogCheckResult(
                catalog: nil, checkedAt: nil, isStale: true,
                diagnostic: failure.diagnostic)
        } catch {
            return ModelCatalogCheckResult(
                catalog: nil, checkedAt: nil, isStale: true,
                diagnostic: .providerUnavailable)
        }
    }

    /// One ephemeral session per acquisition: no cookie store, no credential store, no shared cache,
    /// and no reuse of a connection authenticated for something else.
    static func productionFetch(
        bounds: ClaudeCatalogBounds = ClaudeCatalogBounds()
    ) -> ClaudeModelCatalogTransport.Fetch {
        { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = bounds.requestTimeout
            configuration.timeoutIntervalForResource = bounds.requestTimeout
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let delegate = ClaudeCatalogNoRedirectDelegate()
            let session = URLSession(
                configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            var status: Int?
            var body = Data()
            var transportFailed = false
            let done = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: request) { data, response, error in
                if error != nil || !(response is HTTPURLResponse) {
                    transportFailed = true
                } else {
                    status = (response as? HTTPURLResponse)?.statusCode
                    body = data ?? Data()
                }
                done.signal()
            }
            task.resume()
            // The task carries its own request/resource timeouts, so this wait is bounded by them
            // plus a margin rather than being an independent deadline that could outlive the task.
            guard done.wait(timeout: .now() + bounds.requestTimeout * 2 + 5) == .success else {
                task.cancel()
                throw ClaudeCatalogFailure(.timeout)
            }
            guard !transportFailed, let status else {
                throw ClaudeCatalogFailure(.providerUnavailable)
            }
            return (status: status, body: body)
        }
    }
}
