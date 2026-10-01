import Foundation

/// Which app on this Mac serves a Local model. A BACKEND under `LLMProvider.local`, never a provider of its
/// own, and that split is load-bearing rather than cosmetic:
///
/// - `LLMProvider` is switched on exhaustively in code the vdfit chain protects (`ModelFitSelfTest`). A
///   fourth provider case breaks that file, which no slice of this lane may edit.
/// - B16 ("a Local pin never climbs to the cloud") and the one capacity step-down are carried by
///   `provider == .local` comparisons in `LLMAvailabilityRouting.resolve`. An `.ollama` provider would fail
///   every one of those comparisons and silently fall outside the privacy boundary.
/// - `LLMAvailabilityRouting.fallbackOrder` is `[.claude, .codex, .local]`, the ladder a CLOUD pin walks.
///   A fourth provider would need a place on it, and any place it took would either let a cloud pin land
///   on a second local app ahead of Local or put a local app between the two cloud providers.
///
/// "Local" stays the user's word for "on this Mac"; this enum only says which app answers.
enum LocalBackendID: String, Codable, CaseIterable {
    case lmStudio
    case ollama

    /// How the backend is NAMED to the user. The app's own product name, since that is what the user
    /// installed and what they see in the Dock.
    var displayName: String {
        switch self {
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        }
    }
}

/// The identity of one local model: the app that serves it AND that app's id for it.
///
/// Both halves are the identity. The same string can name two different files on two backends (each app
/// ships its own build of a model, with its own quantization, footprint and context behaviour), so anything
/// that reasons about capacity, residency, eviction or routing must key on the pair. A bare model id is never
/// enough in the local path once a second backend exists.
struct LocalModelRef: Hashable, Codable {
    let backend: LocalBackendID
    let modelID: String
}

/// One installed model, whichever backend listed it. The backend adapters map their own catalog rows into
/// this shape; nothing above them needs to know which catalog a row came from.
struct LocalInstalledModel: Equatable {
    let ref: LocalModelRef
    /// Presentation only. Never parsed for capability or identity.
    let label: String
    /// On-disk size, or nil when the backend did not report a usable number. Its absence must not hide the
    /// model.
    let sizeBytes: Int64?
    let isVision: Bool
    /// Nil means "this backend's catalog does not answer the question", which is NOT "no". LM Studio's
    /// installed-model listing carries neither tool nor thinking capability, so its rows are nil here and
    /// callers keep today's behaviour for them.
    let supportsTools: Bool?
    let supportsThinking: Bool?
}

/// One model currently resident in a backend. Only `ref` and `residentBytes` are required: capacity policy
/// needs those two as one coherent reading. Everything else is metadata a backend may not report.
struct LocalResidentModel: Equatable {
    let ref: LocalModelRef
    /// The whole resident footprint the backend reports for this model.
    let residentBytes: UInt64
    /// When it last served a request. Nil while a model is generating (LM Studio reports null then), or when
    /// the backend does not say.
    let lastUsed: Date?
    /// Nil when the backend has no idle/busy notion.
    let isIdle: Bool?
    /// When the backend will unload it on its own, or nil when it carries no timeout or does not say.
    let expiresAt: Date?
    /// The context the model is loaded with, when the backend reports it.
    let contextLength: Int?
}

/// The residency and catalog primitives every local backend provides. This is the stateless "talk to the
/// app" layer, like `ModelResidency` is for LM Studio today. Policy (which models the app owns, the capacity
/// budget, the one eviction pass) stays in `ModelManager` and is not duplicated per backend.
///
/// Every method is synchronous and may block on a subprocess or a socket, so callers run them OFF the main
/// thread. Failures are nil/false, never a throw: the caller surfaces its own original error.
///
/// Chat is deliberately not here yet. It joins in the slice that routes the clients through this seam (S5),
/// so this protocol cannot be half-adopted by a client before that transport exists.
protocol LocalModelBackend {
    var id: LocalBackendID { get }

    /// Is the app present on this Mac at all?
    func isInstalled() -> Bool
    /// Does its local server answer right now?
    func serverResponds() -> Bool

    /// Every installed chat model, or nil when the catalog could not be read. An empty list is a real
    /// answer (nothing installed) and is different from nil.
    func installedModels() -> [LocalInstalledModel]?
    /// Every resident model, or nil when the snapshot could not be read. Fails closed: a partial list is nil.
    func residentModels() -> [LocalResidentModel]?

    /// Make `ref` resident for an imminent inference, holding it for `ttlSeconds` of idle time. Returns true
    /// when it is resident afterwards. A ref naming ANOTHER backend is refused (false), never loaded here.
    /// `contextTokens` is the context the caller wants; a backend that cannot set it ignores it.
    func ensureLoaded(_ ref: LocalModelRef, ttlSeconds: Int, contextTokens: Int?) -> Bool
    /// Unload `ref`. Harmless when it is not resident. A ref naming another backend is ignored.
    func unload(_ ref: LocalModelRef)
}

extension LLMProviderBundle {
    /// Which local app a Local bundle runs on. A stored bundle without the key predates backends, and every
    /// one of those meant LM Studio, so absent resolves to `.lmStudio` and an existing `models-power.json`
    /// keeps exactly the meaning it had. Only meaningful when `provider == .local`.
    var resolvedLocalBackend: LocalBackendID { localBackend ?? .lmStudio }
}
