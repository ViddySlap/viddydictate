import Foundation

/// Live authenticated Claude catalog gate: performs the REAL `GET /v1/models` with the user's own
/// Claude Code OAuth token, through the same production entry point the app uses.
///
/// The Codex side learned this the expensive way — every fixture test stayed green while vendor
/// protocol drift disabled the provider outright — and the Claude side is if anything more exposed,
/// because Claude expresses retirement by REMOVING a model. A response shape this parser stopped
/// understanding would not read as an error; it would read as "every model is gone", which is the one
/// input that moves a user's pins. A fixture transport cannot catch that by construction: it replays
/// bytes we already believe in.
///
/// The gate additionally proves the property that makes absence safe to act on: the acquired
/// enumeration is COMPLETE, and it still contains the models this build ships as its Claude defaults.
/// If a shipped default is missing, that is either a real retirement (which the rail is about to
/// migrate, and the user should know) or a parser fault — and either way it should be loud here.
///
/// Output is content-free by contract: counts, model ids the app already ships in its own source, and
/// a diagnostic code. The token is never read here and never printed anywhere.
enum ClaudeCatalogLiveGate {
    static func run(arguments: [String]) -> Bool {
        _ = arguments
        let result = ClaudeModelCatalogProvider.refresh(
            checkedAt: ModelFreshnessProbe.checkedAtString(Date()))

        let rows = result.catalog?.rows.count ?? 0
        print("[claude-catalog-live] diagnostic=\(result.diagnostic.rawValue) "
                + "stale=\(result.isStale) rows=\(rows)")

        // Not reaching or not authenticating with the vendor is the measuring apparatus, not the
        // product: a machine with no Claude Code credential is a supported configuration (either
        // provider is sufficient), and an expired token is a state the app already degrades from
        // correctly. Abstain loudly instead of turning that into a false red. Everything past this
        // point is a real claim about a response we DID get, and every one of those is blocking.
        guard result.diagnostic != .providerUnavailable else {
            print("[claude-catalog-live] [skip] SKIPPED: no reachable, authenticated Claude "
                    + "credential on this machine, so there is no live response to judge")
            return true
        }
        guard result.diagnostic == .current else {
            print("[claude-catalog-live] FAIL real /v1/models returned "
                    + "\(result.diagnostic.rawValue) instead of a current catalog")
            return false
        }
        guard !result.isStale, let catalog = result.catalog, rows > 0 else {
            print("[claude-catalog-live] FAIL endpoint reported current but produced no "
                    + "usable catalog rows")
            return false
        }

        let source = ClaudeModelCatalogSource()
        let shipped = LLMRouteID.builtIns.compactMap {
            LLMProviderDefaults.testedBundle(for: .claude, route: $0)?.modelID
        }
        let missing = Set(shipped).filter { source.isRetired(model: $0, in: catalog) }
        guard missing.isEmpty else {
            print("[claude-catalog-live] FAIL this build's shipped Claude pins are no longer "
                    + "served: \(missing.sorted().joined(separator: ", "))")
            return false
        }
        let unchanged = source.plan(
            requests: shipped.map { ModelMigrationRequest(model: $0, effort: nil) },
            catalog: catalog
        ).decisions.allSatisfy { $0.action == .unchanged }
        guard unchanged else {
            print("[claude-catalog-live] FAIL a shipped Claude pin was not judged unchanged "
                    + "against the live catalog")
            return false
        }

        print("[claude-catalog-live] PASS real /v1/models produced a complete current catalog "
                + "still serving every shipped Claude pin")
        return true
    }
}
