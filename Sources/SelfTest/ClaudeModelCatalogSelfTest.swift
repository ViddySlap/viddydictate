import Foundation

/// Synthetic Claude catalogs. Model ids are provider metadata, never user content, and every fixture
/// here is written by hand rather than captured from a live account.
enum ClaudeCatalogFixture {
    static func row(_ model: String, efforts: [String] = []) -> ModelCatalogRow {
        ModelCatalogRow(
            id: model,
            model: model,
            displayName: model,
            description: nil,
            hidden: false,
            defaultReasoningEffort: nil,
            supportedReasoningEfforts: efforts.map {
                ModelCatalogReasoningEffort(
                    reasoningEffort: $0, description: nil, unknownFields: [:])
            },
            inputModalities: ["text"],
            supportsPersonality: nil,
            isDefault: nil,
            upgrade: nil,
            upgradeInfo: nil,
            unknownFields: [:])
    }

    static func catalog(_ models: (String, [String])...) -> ModelCatalog {
        ModelCatalog(
            rows: models.map { row($0.0, efforts: $0.1) },
            pageMetadata: [])
    }

    /// One `/v1/models` page in the exact shape the endpoint returns.
    static func page(models: [String], hasMore: Bool = false, effortModel: String? = nil,
                     lastID: String? = nil) -> Data {
        let entries = models.map { model -> [String: Any] in
            var fields: [String: Any] = [
                "type": "model",
                "id": model,
                "display_name": model,
                "created_at": "2026-01-01T00:00:00Z",
            ]
            if model == effortModel {
                fields["capabilities"] = [
                    "effort": [
                        "supported": true,
                        "low": ["supported": true],
                        "medium": ["supported": false],
                        "high": ["supported": true],
                    ],
                    "image_input": ["supported": true],
                ]
            }
            return fields
        }
        var body: [String: Any] = ["data": entries, "has_more": hasMore]
        if let last = lastID ?? models.last { body["last_id"] = last }
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

enum ClaudeModelCatalogSelfTest {
    /// `Result` needs an `Error` failure type and the diagnostic deliberately is not one, so the
    /// transport fixtures compare against this instead.
    private enum Acquired: Equatable {
        case catalog(ModelCatalog)
        case failed(ModelCatalogDiagnostic)
    }

    static func run() -> Bool {
        print("=== ViddyDictate Claude model catalog - selftest ===")
        let reporter = SelfTestReporter()

        checkIdentityParsing(reporter.record)
        checkTransport(reporter.record)
        checkSeamConformance(reporter.record)
        checkPlannerPolicy(reporter.record)

        print("\n=== RESULT ===")
        print("claude model catalog:  \(reporter.passed ? "PASS" : "FAIL")")
        print(reporter.passed ? "\nCLAUDE MODEL CATALOG GREEN" : "\nCLAUDE MODEL CATALOG FAILED")
        return reporter.passed
    }

    private static func checkIdentityParsing(_ check: (String, Bool) -> Void) {
        print("--- Claude model id identity ---")
        func parsed(_ id: String) -> ClaudeModelIdentity? { ClaudeModelIdentity.parse(id) }

        check("an evergreen alias parses as family plus version with no snapshot",
              parsed("claude-opus-5") == ClaudeModelIdentity(
                family: "opus", version: [5], snapshot: nil))
        check("a dated id parses its trailing snapshot out of the version",
              parsed("claude-haiku-4-5-20251001") == ClaudeModelIdentity(
                family: "haiku", version: [4, 5], snapshot: 20251001))
        check("the legacy family-after-version spelling parses to the same shape",
              parsed("claude-3-5-sonnet-20240620") == ClaudeModelIdentity(
                family: "sonnet", version: [3, 5], snapshot: 20240620))
        check("an id with no family word or the wrong vendor prefix does not parse",
              parsed("claude-4-5") == nil && parsed("sonnet-latest") == nil
                && parsed("gpt-5-codex") == nil)
        check("a two-word id does not parse rather than guessing which word is the family",
              parsed("claude-opus-experimental-5") == nil)

        func newer(_ lhs: String, _ rhs: String) -> Bool {
            ClaudeModelIdentity.isNewer(parsed(lhs)!, than: parsed(rhs)!)
        }
        check("a higher major beats more minor components",
              newer("claude-opus-5", "claude-opus-4-8")
                && !newer("claude-opus-4-8", "claude-opus-5"))
        check("a longer equal prefix is newer",
              newer("claude-sonnet-4-6", "claude-sonnet-4"))
        check("the newer snapshot wins when versions tie",
              newer("claude-opus-4-5-20260101", "claude-opus-4-5-20251101"))
        check("an evergreen alias outranks a dated snapshot of the same version",
              newer("claude-opus-4-5", "claude-opus-4-5-20251101")
                && !newer("claude-opus-4-5-20251101", "claude-opus-4-5"))
        check("ordering is irreflexive",
              !newer("claude-opus-5", "claude-opus-5"))
    }

    private static func checkTransport(_ check: (String, Bool) -> Void) {
        print("--- /v1/models transport ---")
        let bounds = ClaudeCatalogBounds(maxPages: 3, pageSize: 2, maxModels: 8)

        let oauthRequest = try? ClaudeModelCatalogTransport.request(
            token: "sk-ant-oat-fixture", afterID: nil, bounds: bounds)
        check("an OAuth token authenticates as a bearer with the oauth beta header",
              oauthRequest?.value(forHTTPHeaderField: "authorization") == "Bearer sk-ant-oat-fixture"
                && oauthRequest?.value(forHTTPHeaderField: "anthropic-beta")
                    == ClaudeModelCatalogTransport.oauthBeta
                && oauthRequest?.value(forHTTPHeaderField: "x-api-key") == nil)
        check("a plain API key authenticates as x-api-key with no oauth beta header",
              (try? ClaudeModelCatalogTransport.request(
                token: "sk-ant-api03-fixture", afterID: nil, bounds: bounds))?
                .value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-fixture"
                && (try? ClaudeModelCatalogTransport.request(
                    token: "sk-ant-api03-fixture", afterID: nil, bounds: bounds))?
                    .value(forHTTPHeaderField: "authorization") == nil)
        check("every request pins the vendor host, path, version header, and page size",
              oauthRequest?.url?.host == ClaudeModelCatalogTransport.host
                && oauthRequest?.url?.path == ClaudeModelCatalogTransport.path
                && oauthRequest?.url?.query?.contains("limit=2") == true
                && oauthRequest?.value(forHTTPHeaderField: "anthropic-version")
                    == ClaudeModelCatalogTransport.apiVersion)
        check("a follow-up page carries the cursor",
              (try? ClaudeModelCatalogTransport.request(
                token: "t", afterID: "claude-sonnet-5", bounds: bounds))?
                .url?.query?.contains("after_id=claude-sonnet-5") == true)

        func acquire(
            _ pages: [(status: Int, body: Data)],
            bounds: ClaudeCatalogBounds = ClaudeCatalogBounds(maxPages: 3, pageSize: 2, maxModels: 8)
        ) -> Acquired {
            var remaining = pages
            do {
                return .catalog(try ClaudeModelCatalogTransport.acquire(
                    token: "sk-ant-oat-fixture", bounds: bounds,
                    fetch: { _ in
                        guard !remaining.isEmpty else { return (status: 500, body: Data()) }
                        return remaining.removeFirst()
                    }))
            } catch let failure as ClaudeCatalogFailure {
                return .failed(failure.diagnostic)
            } catch {
                return .failed(.providerUnavailable)
            }
        }

        let paged = acquire([
            (200, ClaudeCatalogFixture.page(
                models: ["claude-opus-5", "claude-sonnet-5"], hasMore: true)),
            (200, ClaudeCatalogFixture.page(
                models: ["claude-haiku-4-5-20251001"],
                effortModel: "claude-haiku-4-5-20251001")),
        ])
        if case .catalog(let catalog) = paged {
            check("the walk follows the cursor and concatenates pages in order",
                  catalog.rows.map(\.model)
                    == ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5-20251001"])
            check("a Claude row carries the model id in both neutral columns and is never hidden",
                  catalog.rows.allSatisfy { $0.id == $0.model && !$0.hidden
                      && $0.upgrade == nil && $0.defaultReasoningEffort == nil })
            let haiku = catalog.rows.last
            check("advertised efforts publish in fixed ascending order, unsupported ones dropped",
                  haiku?.supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "high"])
            check("advertised input modalities always include text",
                  haiku?.inputModalities == ["text", "image"]
                    && catalog.rows.first?.inputModalities == ["text"])
        } else {
            check("the walk follows the cursor and concatenates pages in order", false)
        }

        // The four ways a bad response could become a false mass retirement.
        check("a page set that never clears has_more fails rather than truncating the catalog",
              acquire([
                (200, ClaudeCatalogFixture.page(models: ["claude-opus-5"], hasMore: true)),
                (200, ClaudeCatalogFixture.page(models: ["claude-sonnet-5"], hasMore: true)),
                (200, ClaudeCatalogFixture.page(models: ["claude-haiku-5"], hasMore: true)),
              ]) == .failed(.paginationViolation))
        check("a well-formed response describing zero models is invalid, not an empty catalog",
              acquire([(200, ClaudeCatalogFixture.page(models: []))])
                == .failed(.invalidCatalog))
        check("a non-200 response is a provider outage and yields no catalog at all",
              acquire([(401, ClaudeCatalogFixture.page(models: ["claude-opus-5"]))])
                == .failed(.providerUnavailable))
        check("a duplicate model across pages is an invalid catalog",
              acquire([
                (200, ClaudeCatalogFixture.page(models: ["claude-opus-5"], hasMore: true)),
                (200, ClaudeCatalogFixture.page(models: ["claude-opus-5"])),
              ]) == .failed(.invalidCatalog))
        check("a cursor that does not advance fails instead of looping on the same page",
              acquire([
                (200, ClaudeCatalogFixture.page(
                    models: ["claude-opus-5"], hasMore: true, lastID: "cursor-a")),
                (200, ClaudeCatalogFixture.page(
                    models: ["claude-sonnet-5"], hasMore: true, lastID: "cursor-a")),
              ]) == .failed(.paginationViolation))
        check("a malformed body, a non-model entry, and a non-boolean has_more are protocol errors",
              acquire([(200, Data("not json".utf8))]) == .failed(.protocolViolation)
                && acquire([(200, try! JSONSerialization.data(withJSONObject: [
                    "data": [["type": "not-a-model", "id": "claude-opus-5"]],
                ]))]) == .failed(.protocolViolation)
                && acquire([(200, try! JSONSerialization.data(withJSONObject: [
                    "data": [["type": "model", "id": "claude-opus-5"]],
                    "has_more": "yes",
                ]))]) == .failed(.protocolViolation))
        check("more models than the bound allows is a bound failure, not a short catalog",
              acquire([(200, ClaudeCatalogFixture.page(
                models: (0..<9).map { "claude-opus-\($0)" }))],
                bounds: ClaudeCatalogBounds(maxPages: 3, pageSize: 2, maxModels: 8))
                == .failed(.boundExceeded))

        // The credential is read from Claude Code's own file, and a missing or malformed one is a
        // provider outage rather than a crash or a partial catalog.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-claude-credential-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = root.appendingPathComponent("good.json")
        let bad = root.appendingPathComponent("bad.json")
        try? Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-fixture"}}"#.utf8).write(to: good)
        try? Data(#"{"claudeAiOauth":{}}"#.utf8).write(to: bad)
        check("the Claude Code OAuth access token is read out of its credentials file",
              (try? ClaudeCatalogCredential.load(path: good.path)) == "sk-ant-oat-fixture")
        check("a missing or tokenless credentials file reports the provider unavailable",
              (try? ClaudeCatalogCredential.load(path: bad.path)) == nil
                && (try? ClaudeCatalogCredential.load(
                    path: root.appendingPathComponent("absent.json").path)) == nil)

        let unavailable = ClaudeModelCatalogProvider.refresh(
            checkedAt: "2026-07-29T00:00:00Z",
            credential: { throw ClaudeCatalogFailure(.providerUnavailable) })
        check("a failed acquisition yields no catalog and a specific diagnostic, never a stale one",
              unavailable == ModelCatalogCheckResult(
                catalog: nil, checkedAt: nil, isStale: true, diagnostic: .providerUnavailable))
        let acquired = ClaudeModelCatalogProvider.refresh(
            checkedAt: "2026-07-29T00:00:00Z",
            credential: { "sk-ant-oat-fixture" },
            fetch: { _ in (200, ClaudeCatalogFixture.page(models: ["claude-opus-5"])) })
        check("a successful acquisition is current and never stale",
              acquired.diagnostic == .current && !acquired.isStale
                && acquired.checkedAt == "2026-07-29T00:00:00Z"
                && acquired.catalog?.rows.map(\.model) == ["claude-opus-5"])
    }

    /// The four capabilities the seam requires of any provider, asserted against the Claude
    /// conformance rather than inferred from the rail's behaviour.
    private static func checkSeamConformance(_ check: (String, Bool) -> Void) {
        print("--- catalog source seam (Claude conformance) ---")
        let catalog = ClaudeCatalogFixture.catalog(
            ("claude-sonnet-5", ["low", "medium", "high"]),
            ("claude-haiku-4-5-20251001", []))
        let source = ClaudeModelCatalogSource(discover: { at in
            ModelCatalogCheckResult(
                catalog: catalog, checkedAt: at, isStale: false, diagnostic: .current)
        })

        check("seam discovery returns what the source acquired",
              source.discover(checkedAt: "2026-07-29T00:00:00Z")
                == ModelCatalogCheckResult(
                    catalog: catalog, checkedAt: "2026-07-29T00:00:00Z",
                    isStale: false, diagnostic: .current))
        check("seam reports a pin the catalog no longer lists, whose family it still lists, retired",
              source.isRetired(model: "claude-sonnet-4-20240101", in: catalog))
        check("seam reports a listed pin as not retired",
              !source.isRetired(model: "claude-sonnet-5", in: catalog))
        check("seam does not infer retirement from absence alone",
              !source.isRetired(model: "claude-fable-2", in: catalog)
                && !source.isRetired(model: "sonnet-latest", in: catalog))
        check("seam policy is the Claude planner, not a second copy",
              source.plan(
                requests: [ModelMigrationRequest(model: "claude-sonnet-4", effort: "high")],
                catalog: catalog)
                == ClaudeModelMigrationPlanner.plan(
                    requests: [ModelMigrationRequest(model: "claude-sonnet-4", effort: "high")],
                    catalog: catalog))
        check("the retirement predicate agrees with the policy on the same pin",
              source.isRetired(model: "claude-sonnet-4", in: catalog)
                && isMigrate(source.plan(
                    requests: [ModelMigrationRequest(model: "claude-sonnet-4", effort: "high")],
                    catalog: catalog).decisions.first?.action))
    }

    private static func checkPlannerPolicy(_ check: (String, Bool) -> Void) {
        print("--- Claude migration policy ---")
        let catalog = ClaudeCatalogFixture.catalog(
            ("claude-opus-5", ["low", "medium", "high", "xhigh", "max"]),
            ("claude-opus-4-8", ["low", "medium", "high"]),
            ("claude-sonnet-5", ["low", "medium", "high"]),
            ("claude-haiku-4-5-20251001", []))

        func plan(_ requests: [ModelMigrationRequest]) -> ModelMigrationPlan {
            ClaudeModelMigrationPlanner.plan(requests: requests, catalog: catalog)
        }

        let retired = plan([
            ModelMigrationRequest(model: "claude-opus-4-1-20250805", effort: "high"),
        ]).decisions.first?.action
        guard case .migrate(let destination)? = retired else {
            check("a retired opus pin migrates to the newest live opus", false)
            return
        }
        check("a retired pin migrates to the newest live model in its family, not the nearest",
              destination.model == "claude-opus-5")
        check("the destination carries the terminal's advertised effort axis for later pickers",
              destination.supportedEfforts == ["low", "medium", "high", "xhigh", "max"])
        check("provenance names the exact source and terminal and claims no upgrade edge",
              destination.provenance == ModelMigrationProvenance(
                sourcePresetID: "claude-opus-4-1-20250805",
                sourceModel: "claude-opus-4-1-20250805",
                explicitTargetPresetIDs: [],
                terminalPresetID: "claude-opus-5",
                terminalModel: "claude-opus-5",
                effortResolution: .stored))
        check("the stored effort rides across the migration unchanged",
              destination.effort == "high")

        let unpinned = plan([ModelMigrationRequest(model: "claude-opus-4-1", effort: nil)])
        if case .migrate(let destination)? = unpinned.decisions.first?.action {
            check("a pin with no effort keeps none and records the resolution honestly",
                  destination.effort.isEmpty
                    && destination.provenance.effortResolution == .advertisedDefault)
        } else {
            check("a pin with no effort keeps none and records the resolution honestly", false)
        }

        check("ADR 0014: a live pin never moves, however much newer the catalog's best model is",
              plan([
                ModelMigrationRequest(model: "claude-opus-4-8", effort: "high"),
                ModelMigrationRequest(model: "claude-haiku-4-5-20251001", effort: nil),
              ]).decisions.map(\.action) == [.unchanged, .unchanged])
        check("a family the catalog does not serve is held, never cross-promoted",
              plan([ModelMigrationRequest(model: "claude-fable-2", effort: nil)])
                .decisions.first?.action == .hold(.unknownSource))
        check("an unparseable or empty pin is held with a specific reason",
              plan([ModelMigrationRequest(model: "sonnet-latest", effort: nil)])
                .decisions.first?.action == .hold(.unknownSource)
                && plan([ModelMigrationRequest(model: "", effort: nil)])
                    .decisions.first?.action == .hold(.invalidStoredModel)
                && plan([ModelMigrationRequest(model: "claude-opus-4-1", effort: "")])
                    .decisions.first?.action == .hold(.invalidStoredEffort))
        check("a duplicated catalog model holds every request rather than picking a winner",
              ClaudeModelMigrationPlanner.plan(
                requests: [ModelMigrationRequest(model: "claude-opus-4-1", effort: nil)],
                catalog: ClaudeCatalogFixture.catalog(
                    ("claude-opus-5", []), ("claude-opus-5", [])))
                .decisions.first?.action == .hold(.duplicateCatalogModel))
        check("a hidden row is neither a live pin nor a successor",
              ClaudeModelMigrationPlanner.isRetired(
                model: "claude-opus-5",
                in: ModelCatalog(
                    rows: [hidden("claude-opus-5"), ClaudeCatalogFixture.row("claude-opus-4-8")],
                    pageMetadata: [])))
        check("a terminal that cannot accept text is held rather than migrated onto",
              ClaudeModelMigrationPlanner.plan(
                requests: [ModelMigrationRequest(model: "claude-opus-4-1", effort: nil)],
                catalog: ModelCatalog(
                    rows: [imageOnly("claude-opus-5")], pageMetadata: []))
                .decisions.first?.action == .hold(.nonTextTerminal))

        let batch = plan([
            ModelMigrationRequest(model: "claude-opus-4-1", effort: "high"),
            ModelMigrationRequest(model: "claude-opus-4-2", effort: "high"),
            ModelMigrationRequest(model: "claude-sonnet-4", effort: "high"),
        ])
        check("qualifications dedupe on the complete executable pair in first-use order",
              batch.qualifications == [
                ModelQualification(model: "claude-opus-5", effort: "high"),
                ModelQualification(model: "claude-sonnet-5", effort: "high"),
              ])
        check("decisions keep their stable request order as the only route correlation",
              batch.decisions.map(\.inputIndex) == [0, 1, 2])
    }

    private static func isMigrate(_ action: ModelMigrationAction?) -> Bool {
        if case .migrate = action { return true }
        return false
    }

    private static func hidden(_ model: String) -> ModelCatalogRow {
        let base = ClaudeCatalogFixture.row(model)
        return ModelCatalogRow(
            id: base.id, model: base.model, displayName: base.displayName,
            description: nil, hidden: true, defaultReasoningEffort: nil,
            supportedReasoningEfforts: [], inputModalities: base.inputModalities,
            supportsPersonality: nil, isDefault: nil, upgrade: nil, upgradeInfo: nil,
            unknownFields: [:])
    }

    private static func imageOnly(_ model: String) -> ModelCatalogRow {
        let base = ClaudeCatalogFixture.row(model)
        return ModelCatalogRow(
            id: base.id, model: base.model, displayName: base.displayName,
            description: nil, hidden: false, defaultReasoningEffort: nil,
            supportedReasoningEfforts: [], inputModalities: ["image"],
            supportsPersonality: nil, isDefault: nil, upgrade: nil, upgradeInfo: nil,
            unknownFields: [:])
    }
}
