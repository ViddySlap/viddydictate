import Foundation

/// The provider-neutral seam of the evergreen model rail.
///
/// A source owns everything that differs between providers: where the catalog comes from, what
/// "retired" looks like in that catalog, and which model a retired pin moves to. Everything above
/// this protocol — qualification, compare-and-swap persistence, and the auto-update provenance ADR
/// 0014 requires on a migrated pin — is written once and shared, so the two catalogs are one
/// mechanism with two sources rather than two parallel implementations.
///
/// The four capabilities the seam has to carry map onto it as follows:
///
/// - **discover** is `discover(checkedAt:)`.
/// - **detect-retirement** is `isRetired(model:in:)`.
/// - **migrate** is `plan(requests:catalog:)`, whose `.migrate` decisions name the destination.
/// - **provenance** rides on those decisions as `ModelMigrationProvenance`, which records exactly
///   which catalog rows justified the move. The bundle-level `LLMAutoUpdateProvenance` is *not* a
///   source concern: ADR 0014 applies the same unratified auto-update stamp to both providers, so
///   it belongs above the seam.
///
/// Retirement detection and migration stay two members rather than one because they answer
/// different questions and have different callers: `isRetired` judges a single pin against the
/// catalog and gates whether a planner hold is blocking, while `plan` walks whatever structure the
/// provider exposes for a whole request set. They are deliberately not folded together, but a
/// conformance is free to implement both from the same underlying policy.
protocol ModelCatalogSource {
    /// Acquire the current catalog, falling back to the last-known-good cache. Never throws: an
    /// unreachable provider is reported as a stale result carrying a specific diagnostic.
    func discover(checkedAt: String) -> ModelCatalogCheckResult

    /// Whether `model` is a pin the provider has retired, judged against an acquired catalog.
    /// A model this catalog simply does not describe is not, by itself, retired — a source says so
    /// only when its own catalog gives positive evidence of retirement.
    func isRetired(model: String, in catalog: ModelCatalog) -> Bool

    /// Pure policy over an acquired catalog: which pins are unchanged, which have a newer model
    /// available that ADR 0014 says to ignore (`.recommend`), which are retired and must move
    /// (`.migrate`), and which are unresolvable (`.hold`).
    func plan(requests: [ModelMigrationRequest], catalog: ModelCatalog) -> ModelMigrationPlan
}

/// Codex conformance: the app-server `model/list` catalog behind the compatibility boundary, with
/// retirement expressed as a hidden row and migration as the advertised upgrade chain.
///
/// `discover` is injectable so tests can drive the policy members against a fixture catalog without
/// spawning the real provider; production uses the default, which is the untouched
/// `CodexModelCatalogProvider.refresh` path.
struct CodexModelCatalogSource: ModelCatalogSource {
    private let discoverCatalog: (String) -> ModelCatalogCheckResult

    init(
        discover: @escaping (String) -> ModelCatalogCheckResult = {
            CodexModelCatalogProvider.refresh(checkedAt: $0)
        }
    ) {
        discoverCatalog = discover
    }

    func discover(checkedAt: String) -> ModelCatalogCheckResult {
        discoverCatalog(checkedAt)
    }

    /// Codex retires a preset by hiding its row rather than removing it, which is what lets the
    /// planner still find the row and follow its upgrade edge.
    func isRetired(model: String, in catalog: ModelCatalog) -> Bool {
        catalog.rows.first { $0.model == model }?.hidden == true
    }

    func plan(
        requests: [ModelMigrationRequest],
        catalog: ModelCatalog
    ) -> ModelMigrationPlan {
        CodexModelMigrationPlanner.plan(requests: requests, catalog: catalog)
    }
}

/// Claude conformance: `GET /v1/models` authorized by the Claude Code OAuth token, with retirement
/// expressed as removal from that list and migration derived from the id's own family and version.
///
/// The two sources are the same mechanism with genuinely different provider shapes, which is the seam
/// earning its keep: Codex hides a retired preset and advertises where it went, so its policy follows
/// an edge; Claude deletes the model and advertises nothing, so its policy reads what the catalog no
/// longer says. Everything above — the ADR 0014 unratified stamp, the compare-and-swap, the surfaces —
/// is written once for both.
///
/// `discover` is injectable so tests drive the policy members against a fixture catalog without a
/// network call; production uses `ClaudeModelCatalogProvider.refresh`.
struct ClaudeModelCatalogSource: ModelCatalogSource {
    private let discoverCatalog: (String) -> ModelCatalogCheckResult

    init(
        discover: @escaping (String) -> ModelCatalogCheckResult = {
            ClaudeModelCatalogProvider.refresh(checkedAt: $0)
        }
    ) {
        discoverCatalog = discover
    }

    func discover(checkedAt: String) -> ModelCatalogCheckResult {
        discoverCatalog(checkedAt)
    }

    /// Absence alone is NOT retirement, exactly as the protocol requires. Claude's positive evidence
    /// is the pairing "this pin is gone AND its family is still served"; an unrecognizable id, or a
    /// family the token cannot see at all, reports not-retired and gets held and surfaced instead.
    func isRetired(model: String, in catalog: ModelCatalog) -> Bool {
        ClaudeModelMigrationPlanner.isRetired(model: model, in: catalog)
    }

    func plan(
        requests: [ModelMigrationRequest],
        catalog: ModelCatalog
    ) -> ModelMigrationPlan {
        ClaudeModelMigrationPlanner.plan(requests: requests, catalog: catalog)
    }
}
