import Foundation

/// The single home for the app's LM Studio model policy: which models the app manages (the working
/// set) and the per-model idle TTL each is loaded with. Built on the stateless `ModelResidency`
/// primitives.
///
/// Eviction is owned by LM Studio, not the app (interop ADR 0004; reverses the app-managed-timer
/// MECHANISM of ViddyDictate ADR 0006 while keeping its intent — an idle Mac must not sit hot with
/// ~24GB pinned). Policy now: load on demand (a mode calls `ensureReady` before its inference) with a
/// per-model `--ttl`, and let LM Studio unload the model after that idle window. No app-side unload
/// timer, no keep-alive ping. Making LM Studio the single eviction owner lets multiple local apps share
/// resident models without fighting over them; any app's use resets LM Studio's idle clock. See
/// `docs/model-residency.md`.
///
/// No "is it loaded" cache: `ensureReady` re-checks `lms ps` every call (~0.16s), so it self-corrects
/// if a model was evicted (its own TTL, an LM Studio restart, memory pressure) with no stale state.
final class ModelManager {
    static let shared = ModelManager()
    private init() {}

    /// Per-model idle TTL (seconds) handed to LM Studio at load time. qwen (the heavy cleanup /
    /// retrieval coder) gets the longer window; gemma (email / synthesis) the shorter one.
    static let qwenIdleTTL = 900    // 15 min
    static let gemmaIdleTTL = 300   //  5 min

    /// The idle TTL to load `model` with. Derived from Settings (no second hardcoded copy of the model
    /// IDs): the cleanup/retrieval model gets `qwenIdleTTL`, the email/synth model `gemmaIdleTTL`. An
    /// unrecognized model falls back to the longer TTL (safer: cool eventually, but do not thrash a
    /// model the app does not know the role of).
    func ttl(for model: String) -> Int {
        var byModel: [String: Int] = [:]
        for id in [Settings.cleanupModel, Settings.searchModel] { byModel[id] = Self.qwenIdleTTL }
        for id in [Settings.emailModel, Settings.searchSynthModel] { byModel[id] = Self.gemmaIdleTTL }
        return byModel[model] ?? Self.qwenIdleTTL
    }

    /// Ensure `model` is resident for an imminent inference. BLOCKS until the model is loaded (a cold
    /// load) or the load fails — so call it OFF the main thread, before a timed request, so the cold
    /// load does not count against that request's timeout. Loads with the model's per-model TTL so LM
    /// Studio owns the eviction; `ttlOverrideSeconds` is a test-only seam (the residency self-test uses
    /// a short TTL so eviction is observable without a 15-minute wait). Returns false if it could not
    /// be loaded.
    @discardableResult
    func ensureReady(_ model: String, ttlOverrideSeconds: Int? = nil) -> Bool {
        ModelResidency.ensureLoaded(model, ttlSeconds: ttlOverrideSeconds ?? ttl(for: model))
    }
}
