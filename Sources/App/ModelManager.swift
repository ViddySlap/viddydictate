import Foundation

/// The single home for the app's local model policy: which models the app manages (the working set) and
/// the single app-configured idle TTL each is loaded with. Built on the stateless `ModelResidency` primitives
/// for LM Studio and on `OllamaBackend` for Ollama (ADR 0018's capacity policy, extended to both apps).
///
/// Eviction is owned by LM Studio, not the app (interop ADR 0004; reverses the app-managed-timer
/// MECHANISM of ViddyDictate ADR 0006 while keeping its intent — an idle Mac must not sit hot with
/// ~24GB pinned). Policy now: load on demand (a mode calls `ensureReady` before its inference) with a
/// configured `--ttl`, and let LM Studio unload the model after that idle window. No app-side unload
/// timer, no keep-alive ping. Making LM Studio the single eviction owner lets multiple local apps share
/// resident models without fighting over them; any app's use resets LM Studio's idle clock. See
/// `docs/model-residency.md`.
///
/// No "is it loaded" cache: `ensureReady` re-checks `lms ps` every call (~0.16s), so it self-corrects
/// if a model was evicted (its own TTL, an LM Studio restart, memory pressure) with no stale state.
final class ModelManager {
    enum CapacityRefusal: Equatable {
        /// A required live fact (resident snapshot, installed size, wired reading, or wire budget)
        /// could not be read. Refusing is failure-soft: callers keep their existing raw-output path.
        case factsUnavailable
        /// The incoming allocation still exceeds the selected budget after the one eviction pass.
        case overBudget
    }

    enum ReadinessResult: Equatable {
        case ready
        case capacityRefused(CapacityRefusal)
        case loadFailed

        var isReady: Bool { self == .ready }
    }

    /// Closure injection keeps the kernel/LM Studio policy deterministic under the Codex seatbelt,
    /// where the real wire ceiling is deliberately unreadable. Production uses `live` unchanged.
    struct CapacityDependencies {
        let availableInstalledModels: () -> [LMStudioInstalledModel]?
        let residentModels: () -> [ModelResidency.ResidentModel]?
        let wiredBytes: () -> UInt64?
        let budgetBytes: (Double) -> UInt64?
        let ensureLoaded: (String, Int) -> Bool
        let unload: (String) -> Void
        let log: (String) -> Void
        /// How long the recheck may wait for the kernel to reclaim an evicted model's wired pages.
        /// Defaults to 0 so a test supplying its own facts sees no wall-clock wait; production waits.
        var evictionSettleSeconds: Double = 0
        /// Ollama's facts, or nil for a caller with no Ollama at all. Nil keeps every decision exactly what it
        /// was before Ollama existed: an Ollama ref is then refused as `.factsUnavailable`, and an LM Studio
        /// request never looks for Ollama models to evict. The fields above stay LM Studio's.
        var ollama: OllamaCapacityDependencies?

        init(
            availableInstalledModels: @escaping () -> [LMStudioInstalledModel]?,
            residentModels: @escaping () -> [ModelResidency.ResidentModel]?,
            wiredBytes: @escaping () -> UInt64?,
            budgetBytes: @escaping (Double) -> UInt64?,
            ensureLoaded: @escaping (String, Int) -> Bool,
            unload: @escaping (String) -> Void,
            log: @escaping (String) -> Void = { Log.write($0) },
            evictionSettleSeconds: Double = 0,
            ollama: OllamaCapacityDependencies? = nil
        ) {
            self.availableInstalledModels = availableInstalledModels
            self.residentModels = residentModels
            self.wiredBytes = wiredBytes
            self.budgetBytes = budgetBytes
            self.ensureLoaded = ensureLoaded
            self.unload = unload
            self.log = log
            self.evictionSettleSeconds = evictionSettleSeconds
            self.ollama = ollama
        }

        static let live = CapacityDependencies(
            availableInstalledModels: { ModelResidency.availableInstalledModels() },
            residentModels: { ModelResidency.residentModels() },
            wiredBytes: { SystemMemory.wiredBytes },
            budgetBytes: { SystemMemory.budgetBytes(forSliderPosition: $0) },
            ensureLoaded: { ModelResidency.ensureLoaded($0, ttlSeconds: $1) },
            unload: { ModelResidency.unload($0) },
            log: { Log.write($0) },
            evictionSettleSeconds: evictionSettleWindow,
            ollama: .backed(by: OllamaBackend.shared))
    }

    /// Ollama's half of the capacity facts, every one keyed by `LocalModelRef`. Whole-machine accounting is
    /// unchanged: the budget still compares live WIRED memory (measured on Ben's Mac, Ollama loads are wired,
    /// +7.31 GB for gemma4:e4b at 8k, released within 1 s of `keep_alive: 0`), so this only supplies what the
    /// incoming estimate and the eviction pass need.
    struct OllamaCapacityDependencies {
        /// `/api/tags`, where the incoming size comes from. NEVER `/api/ps`: ps under-reports a loaded
        /// model 10-20x (0.34 GB for that same 7.31 GB load), so an estimate built on it would wave through
        /// a load that cannot fit.
        let installedModels: () -> [LocalInstalledModel]?
        /// `/api/ps`, with `residentBytes` from tags (see `OllamaBackend.residentModels`). Fails closed.
        let residentModels: () -> [LocalResidentModel]?
        /// The S2 upper-bound KV cache for `(ref, num_ctx)`, nil when `model_info` lacks the geometry.
        let kvCacheBytes: (LocalModelRef, Int) -> Int64?
        /// Load `ref` with an idle window (seconds) and a context (tokens). D5's reuse rule is the backend's.
        let ensureLoaded: (LocalModelRef, Int, Int) -> Bool
        let unload: (LocalModelRef) -> Void

        static func backed(by backend: OllamaBackend) -> OllamaCapacityDependencies {
            OllamaCapacityDependencies(
                installedModels: { backend.installedModels() },
                residentModels: { backend.residentModels() },
                kvCacheBytes: { backend.kvCacheBytes(for: $0, contextTokens: $1) },
                ensureLoaded: { backend.ensureLoaded($0, ttlSeconds: $1, contextTokens: $2) },
                unload: { backend.unload($0) })
        }
    }

    /// `lms unload` returns before macOS has unwired the model worker's pages. Measured on this Mac
    /// (`vdmg-REV`, 2026-08-24): unload returned at +0.148s with `wire_count` still reporting 10.00 of
    /// 10.43 GB, and the reading did not settle to 3.50 GB until ~+0.68s. Re-reading immediately
    /// therefore compares the INCOMING model against the PRE-eviction number, so the recheck can never
    /// pass on the strength of the eviction it just performed - the app unloads its own warm model and
    /// refuses anyway. Waiting for the reading to catch up is what makes LOCKED DECISION 2's recheck
    /// mean anything; it is still ONE eviction pass, not a second one.
    ///
    /// Kept for both apps: the Mac probe (2026-09-30) measured Ollama releasing a model's wired pages within
    /// 1 s of `keep_alive: 0`, inside the same window, and the wait still exits on the first good reading.
    static let evictionSettleWindow: Double = 2.0
    /// Sampling interval inside that window. Short enough that the common case costs ~1 sample.
    static let evictionSettleInterval: Double = 0.05

    static let shared = ModelManager()

    /// Conservative allowance for runtime allocation around the installed weights. L3 validates
    /// this against a real cold load and records the measurement in the chain baton.
    static let incomingFootprintFactor = 1.15

    /// What an Ollama KV cache is assumed to cost, as a fraction of the model's on-disk size per 8,192
    /// tokens of context, when `/api/show` gives no usable geometry. Deliberately pessimistic: the Mac probe
    /// measured gemma4:e4b's whole load at 1.11x its size at 8k (so KV plus runtime ~0.11), and small models
    /// with wide attention run higher, so 0.25 over-counts rather than under-counts. ADR 0018's guard must
    /// err toward refusing a load, never toward a Metal panic.
    static let ollamaFallbackKVFractionPer8K = 0.25

    /// The context an Ollama readiness check assumes when its caller names none (D5's smallest constant).
    static let ollamaDefaultContextTokens = 8192

    private let policyLock = NSLock()
    /// Models whose cold load this process actually initiated, keyed by `(app, id)`. A model merely found
    /// resident is never adopted, even when its identifier is one ViddyDictate commonly uses, and the same id
    /// in the OTHER app is a different model: owning LM Studio's `x` never makes Ollama's `x` evictable.
    private var ownedModels = Set<LocalModelRef>()

    /// ViddyDictate's own last use of each Ollama model, and its requests in flight on each. Ollama's
    /// `/api/ps` has neither a last-use time nor a busy flag, so these are the only recency and idleness the
    /// eviction pass has for an Ollama model. Behind their own lock: a chat beginning or ending must never
    /// wait on a cold load holding `policyLock`.
    private let usageLock = NSLock()
    private var ollamaLastUsed: [LocalModelRef: Date] = [:]
    private var ollamaInFlight: [LocalModelRef: Int] = [:]
    private let clock: () -> Date

    private enum CapacityPreparation {
        /// Resident and usable as it is. `contextLength` is the context it is loaded with, when known.
        case alreadyResident(contextLength: Int?)
        case loadAllowed
        case refused(CapacityRefusal)
    }

    /// One resident model, either app, in the shape the eviction pass ranks. LM Studio rows carry LM Studio's
    /// own recency and status; Ollama rows carry ViddyDictate's stamp and in-flight count.
    private struct Resident {
        let ref: LocalModelRef
        let sizeBytes: UInt64
        /// Epoch milliseconds, the unit `lms ps` reports.
        let lastUsedMillis: UInt64?
        let isIdle: Bool
        let contextLength: Int?
    }

    /// `clock` stamps ViddyDictate's own use of an Ollama model; a gate passes a fixed one.
    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// The idle TTL handed to the local app at load time. One persisted setting governs every model role.
    func ttl(for _: String) -> Int {
        Settings.modelIdleUnloadSeconds
    }

    // MARK: - LM Studio by id (every pre-Ollama call site)

    /// Ensure LM Studio's `model` is resident for an imminent inference. BLOCKS until the model is loaded (a
    /// cold load) or the load fails — so call it OFF the main thread, before a timed request, so the cold
    /// load does not count against that request's timeout. Loads with the app's configured TTL so LM
    /// Studio owns the eviction; `ttlOverrideSeconds` is a test-only seam (the residency self-test uses
    /// a short TTL so eviction is observable without waiting for the configured interval). Returns
    /// a typed result so every client must distinguish a capacity refusal from an LM Studio load
    /// failure instead of silently collapsing the policy outcome to a Bool.
    ///
    /// A bare id is LM Studio's: every caller that predates Ollama passes one, and this is exactly
    /// `ensureReady(LocalModelRef(backend: .lmStudio, modelID: model))`.
    @discardableResult
    func ensureReady(_ model: String, ttlOverrideSeconds: Int? = nil) -> ReadinessResult {
        ensureReady(model, ttlOverrideSeconds: ttlOverrideSeconds, dependencies: .live)
    }

    /// Cheap early-out for a caller that has expensive work to do before the model is needed. It runs
    /// the same live-fact check and bounded self-eviction pass as `ensureReady`, but never loads the
    /// requested model. `ensureReady` must still run immediately before inference: memory can change
    /// after this snapshot, so this is an optimization rather than load authorization.
    func capacityPrecheck(_ model: String) -> ReadinessResult {
        capacityPrecheck(model, dependencies: .live)
    }

    func capacityPrecheck(
        _ model: String,
        dependencies: CapacityDependencies
    ) -> ReadinessResult {
        capacityPrecheck(LocalModelRef(backend: .lmStudio, modelID: model), dependencies: dependencies)
    }

    @discardableResult
    func ensureReady(
        _ model: String,
        ttlOverrideSeconds: Int? = nil,
        dependencies: CapacityDependencies
    ) -> ReadinessResult {
        ensureReady(LocalModelRef(backend: .lmStudio, modelID: model),
                    ttlOverrideSeconds: ttlOverrideSeconds, dependencies: dependencies)
    }

    // MARK: - Either app, by (app, id)

    /// `ensureReady` for a model in either app. For Ollama, `contextTokens` is the `num_ctx` the caller's
    /// surface needs (spec D5; `ollamaDefaultContextTokens` when nil): a resident instance with at least that
    /// context is reused, a smaller one is budgeted and reloaded at it. LM Studio ignores it, as its load did
    /// before Ollama existed.
    @discardableResult
    func ensureReady(
        _ ref: LocalModelRef,
        contextTokens: Int? = nil,
        ttlOverrideSeconds: Int? = nil,
        dependencies: CapacityDependencies = .live
    ) -> ReadinessResult {
        ensureReadyForChat(ref, contextTokens: contextTokens, ttlOverrideSeconds: ttlOverrideSeconds,
                           dependencies: dependencies).result
    }

    /// `ensureReady`, also answering the `num_ctx` the imminent Ollama chat must carry: the resident
    /// instance's own context when it was reused (sending a different one would make Ollama reload it), else
    /// the one it was just loaded with. Nil for LM Studio, whose requests carry no context.
    func ensureReadyForChat(
        _ ref: LocalModelRef,
        contextTokens: Int? = nil,
        ttlOverrideSeconds: Int? = nil,
        dependencies: CapacityDependencies = .live
    ) -> (result: ReadinessResult, contextTokens: Int?) {
        policyLock.lock()
        defer { policyLock.unlock() }

        let canonical = Self.canonical(ref)
        let wanted = canonical.backend == .ollama ? (contextTokens ?? Self.ollamaDefaultContextTokens) : nil
        switch prepareCapacity(for: canonical, contextTokens: wanted, dependencies: dependencies) {
        case .alreadyResident(let resident):
            stampUse(canonical)
            return (.ready, canonical.backend == .ollama ? (resident ?? wanted) : nil)
        case .refused(let reason):
            return (.capacityRefused(reason), nil)
        case .loadAllowed:
            break
        }

        let ttl = ttlOverrideSeconds ?? ttl(for: ref.modelID)
        let loaded: Bool
        switch ref.backend {
        case .lmStudio:
            loaded = dependencies.ensureLoaded(ref.modelID, ttl)
        case .ollama:
            // prepareCapacity refuses an Ollama ref without Ollama facts, so `ollama` is present here.
            loaded = dependencies.ollama?.ensureLoaded(ref, ttl, wanted ?? Self.ollamaDefaultContextTokens)
                ?? false
        }
        guard loaded else { return (.loadFailed, nil) }
        ownedModels.insert(canonical)
        stampUse(canonical)
        return (.ready, wanted)
    }

    /// `capacityPrecheck` for a model in either app; `contextTokens` as in `ensureReady`.
    func capacityPrecheck(
        _ ref: LocalModelRef,
        contextTokens: Int? = nil,
        dependencies: CapacityDependencies = .live
    ) -> ReadinessResult {
        policyLock.lock()
        defer { policyLock.unlock() }

        let canonical = Self.canonical(ref)
        let wanted = canonical.backend == .ollama ? (contextTokens ?? Self.ollamaDefaultContextTokens) : nil
        switch prepareCapacity(for: canonical, contextTokens: wanted, dependencies: dependencies) {
        case .alreadyResident, .loadAllowed:
            return .ready
        case .refused(let reason):
            return .capacityRefused(reason)
        }
    }

    // MARK: - ViddyDictate's own use of an Ollama model

    /// Bracket every Ollama request: while one is in flight the model is busy, and is never an eviction
    /// candidate; when it ends, its last use is now. LM Studio reports both itself, so its refs are ignored.
    func beginRequest(on ref: LocalModelRef) {
        guard ref.backend == .ollama else { return }
        let canonical = Self.canonical(ref)
        usageLock.lock()
        ollamaInFlight[canonical, default: 0] += 1
        ollamaLastUsed[canonical] = clock()
        usageLock.unlock()
    }

    func endRequest(on ref: LocalModelRef) {
        guard ref.backend == .ollama else { return }
        let canonical = Self.canonical(ref)
        usageLock.lock()
        let remaining = (ollamaInFlight[canonical] ?? 1) - 1
        ollamaInFlight[canonical] = remaining > 0 ? remaining : nil
        ollamaLastUsed[canonical] = clock()
        usageLock.unlock()
    }

    private func stampUse(_ ref: LocalModelRef) {
        guard ref.backend == .ollama else { return }
        usageLock.lock()
        ollamaLastUsed[ref] = clock()
        usageLock.unlock()
    }

    /// Ollama's implicit `:latest` and LM Studio's ids verbatim, so one model is one key however it was named.
    static func canonical(_ ref: LocalModelRef) -> LocalModelRef {
        guard ref.backend == .ollama else { return ref }
        return LocalModelRef(backend: .ollama, modelID: OllamaBackend.canonicalModelName(ref.modelID))
    }

    // MARK: - The policy

    /// Shared capacity preparation for the early Option+G check and the authoritative load path.
    /// Keeping the facts, estimate, ownership filter, one-pass eviction, and recheck in one function
    /// prevents the early-out from drifting into a looser policy than `ensureReady`.
    ///
    /// The requested app's resident snapshot is required (fail closed). The OTHER app is read only when this
    /// process owns a model there, because its only use is offering those models to the eviction pass; so an
    /// LM-Studio-only Mac never asks Ollama anything and decides exactly as 1.1.0 did, and an unreadable
    /// other app means "no candidates there", never a refusal of a request it has no part in.
    private func prepareCapacity(
        for ref: LocalModelRef,
        contextTokens: Int?,
        dependencies: CapacityDependencies
    ) -> CapacityPreparation {
        var lmStudio: [Resident]?
        var ollama: [Resident]?
        switch ref.backend {
        case .lmStudio:
            guard let rows = dependencies.residentModels() else { return .refused(.factsUnavailable) }
            lmStudio = rows.map(Self.resident(fromLMStudio:))
            if ownsAny(.ollama), let rows = dependencies.ollama?.residentModels() {
                ollama = residents(fromOllama: rows)
            }
        case .ollama:
            guard let rows = dependencies.ollama?.residentModels() else { return .refused(.factsUnavailable) }
            ollama = residents(fromOllama: rows)
            if ownsAny(.lmStudio), let rows = dependencies.residentModels() {
                lmStudio = rows.map(Self.resident(fromLMStudio:))
            }
        }

        // Drop ownership as soon as a previously owned instance is observed absent (for example,
        // after its LM Studio TTL or Ollama keep_alive fires). A later foreign load with that identifier is
        // not adopted. Only an app that was actually read can prove an absence.
        for (backend, snapshot) in [(LocalBackendID.lmStudio, lmStudio), (.ollama, ollama)] {
            guard let snapshot else { continue }
            let present = Set(snapshot.map(\.ref))
            ownedModels = ownedModels.filter { $0.backend != backend || present.contains($0) }
        }
        let residents = (lmStudio ?? []) + (ollama ?? [])

        // A resident request allocates nothing new. Do not re-load it (LM Studio would create :2),
        // and do not claim ownership if another caller made it resident. An Ollama instance is only
        // "resident" for this request when its context is large enough (D5); a smaller one is about to be
        // reloaded, so it is budgeted below like a cold load.
        if let resident = residents.first(where: { $0.ref == ref }) {
            if ref.backend == .lmStudio
                || OllamaBackend.reusesResident(contextLength: resident.contextLength, wanted: contextTokens) {
                // This read is diagnostic only. Reusing a resident remains authorized even when the
                // selected budget was lowered beneath its footprint, or when the budget is unreadable:
                // the request wires no new model memory. Keep this inside the resident short-circuit so
                // it can never become a refusal or trigger the cold-load eviction path.
                if let budget = dependencies.budgetBytes(Settings.modelMemoryBudgetSliderPosition),
                   resident.sizeBytes > budget {
                    dependencies.log(
                        "model capacity: \(Self.logName(ref)) is already resident at "
                            + "\(SystemMemory.formatGB(resident.sizeBytes)), above the current "
                            + "\(SystemMemory.formatGB(budget)) budget; reusing it because this request "
                            + "allocates no new model memory")
                }
                return .alreadyResident(contextLength: resident.contextLength)
            }
            dependencies.log(
                "model capacity: \(Self.logName(ref)) is resident at context "
                    + "\(resident.contextLength.map(String.init) ?? "unreported"), below the "
                    + "\(contextTokens.map(String.init) ?? "requested") this request needs; budgeting the reload")
        }

        guard let estimatedIncoming = incomingEstimate(for: ref, contextTokens: contextTokens,
                                                       dependencies: dependencies),
              let firstWired = dependencies.wiredBytes(),
              let firstBudget = dependencies.budgetBytes(Settings.modelMemoryBudgetSliderPosition)
        else { return .refused(.factsUnavailable) }

        if !Self.fits(wiredBytes: firstWired, incomingBytes: estimatedIncoming,
                      budgetBytes: firstBudget) {
            // ONE bounded pass over one snapshot, LRU first. Only models cold-loaded by this process
            // are candidates; an older/larger foreign model is never touched, in either app. Busy/loading
            // owned models and the requested model are also excluded.
            let candidates = residents
                .filter {
                    ownedModels.contains($0.ref)
                        && $0.ref != ref
                        && $0.isIdle
                }
                .sorted(by: Self.isOlderForEviction)
            for candidate in candidates {
                switch candidate.ref.backend {
                case .lmStudio: dependencies.unload(candidate.ref.modelID)
                case .ollama: dependencies.ollama?.unload(candidate.ref)
                }
                // Even a failed/no-op unload cannot justify a later, broader attempt. Forgetting the
                // claim makes the safety boundary tighter; the live recheck below decides capacity.
                ownedModels.remove(candidate.ref)
            }

            // Let the wired reading catch up with the unload before the recheck reads it. Bounded, and
            // it exits the instant the reading is good enough, so a machine that frees promptly pays
            // one sample and a machine that never frees still refuses exactly as it would have.
            if !candidates.isEmpty, dependencies.evictionSettleSeconds > 0 {
                let deadline = Date().addingTimeInterval(dependencies.evictionSettleSeconds)
                while Date() < deadline {
                    guard let settling = dependencies.wiredBytes(),
                          let budget = dependencies.budgetBytes(
                            Settings.modelMemoryBudgetSliderPosition)
                    else { break }
                    if Self.fits(wiredBytes: settling, incomingBytes: estimatedIncoming,
                                 budgetBytes: budget) { break }
                    Thread.sleep(forTimeInterval: Self.evictionSettleInterval)
                }
            }

            guard let recheckedWired = dependencies.wiredBytes(),
                  let recheckedBudget = dependencies.budgetBytes(
                    Settings.modelMemoryBudgetSliderPosition)
            else { return .refused(.factsUnavailable) }
            guard Self.fits(wiredBytes: recheckedWired, incomingBytes: estimatedIncoming,
                            budgetBytes: recheckedBudget)
            else { return .refused(.overBudget) }
        }

        return .loadAllowed
    }

    /// What loading `ref` would add, or nil when a fact it needs is unreadable (a refusal).
    ///
    /// - LM Studio: installed size x 1.15, exactly as ADR 0018 shipped it.
    /// - Ollama: (tags size + KV(num_ctx)) x 1.15. The size is the CATALOG's (`/api/tags`), never `/api/ps`,
    ///   which under-reports 10-20x; the KV is S2's upper bound from `model_info`, or the pessimistic
    ///   fallback when the geometry is missing. Without the KV term an 8k load and a 262k load would
    ///   budget the same, which is the exact gap D5 exists to close.
    private func incomingEstimate(for ref: LocalModelRef, contextTokens: Int?,
                                  dependencies: CapacityDependencies) -> UInt64? {
        switch ref.backend {
        case .lmStudio:
            guard let installed = dependencies.availableInstalledModels(),
                  let size = installed.first(where: { $0.modelID == ref.modelID })?.sizeBytes,
                  size > 0
            else { return nil }
            return Self.estimatedIncomingBytes(sizeBytes: size)
        case .ollama:
            guard let ollama = dependencies.ollama,
                  let installed = ollama.installedModels(),
                  let size = installed.first(where: { Self.canonical($0.ref) == ref })?.sizeBytes,
                  size > 0
            else { return nil }
            let context = contextTokens ?? Self.ollamaDefaultContextTokens
            let kv = ollama.kvCacheBytes(ref, context)
                ?? Self.fallbackKVCacheBytes(sizeBytes: size, contextTokens: context)
            return Self.estimatedIncomingBytes(sizeBytes: size, kvCacheBytes: kv)
        }
    }

    private func ownsAny(_ backend: LocalBackendID) -> Bool {
        ownedModels.contains { $0.backend == backend }
    }

    private static func resident(fromLMStudio row: ModelResidency.ResidentModel) -> Resident {
        Resident(ref: LocalModelRef(backend: .lmStudio, modelID: row.identifier), sizeBytes: row.sizeBytes,
                 lastUsedMillis: row.lastUsedTime, isIdle: row.isIdle, contextLength: nil)
    }

    /// Recency is ViddyDictate's own stamp and idleness is "no ViddyDictate request in flight", both from
    /// `beginRequest`/`endRequest`. ps's `expires_at` is NOT recency: it moves with any app's request.
    private func residents(fromOllama rows: [LocalResidentModel]) -> [Resident] {
        usageLock.lock()
        defer { usageLock.unlock() }
        return rows.map { row in
            let ref = Self.canonical(row.ref)
            let stamp = ollamaLastUsed[ref].map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) }
            return Resident(ref: ref, sizeBytes: row.residentBytes, lastUsedMillis: stamp,
                            isIdle: ollamaInFlight[ref] == nil, contextLength: row.contextLength)
        }
    }

    /// LM Studio's ids are logged verbatim (unchanged lines); an Ollama model says which app holds it.
    private static func logName(_ ref: LocalModelRef) -> String {
        ref.backend == .lmStudio ? ref.modelID : "\(ref.modelID) (Ollama)"
    }

    /// Missing recency cannot prove that a model is stale, so it sorts after every row with a known
    /// last-use time. This is deliberately explicit instead of using a zero sentinel: zero would make
    /// an active row the first eviction candidate.
    private static func isOlderForEviction(_ lhs: Resident, _ rhs: Resident) -> Bool {
        switch (lhs.lastUsedMillis, rhs.lastUsedMillis) {
        case let (left?, right?):
            return left == right ? isOrderedByName(lhs.ref, rhs.ref) : left < right
        case (nil, nil):
            return isOrderedByName(lhs.ref, rhs.ref)
        case (nil, _):
            return false
        case (_, nil):
            return true
        }
    }

    /// The id first, exactly as before Ollama; the app only splits a tie between two apps' same id.
    private static func isOrderedByName(_ lhs: LocalModelRef, _ rhs: LocalModelRef) -> Bool {
        lhs.modelID == rhs.modelID ? lhs.backend.rawValue < rhs.backend.rawValue : lhs.modelID < rhs.modelID
    }

    static func estimatedIncomingBytes(sizeBytes: Int64) -> UInt64? {
        guard sizeBytes > 0 else { return nil }
        let estimate = (Double(sizeBytes) * incomingFootprintFactor).rounded(.up)
        guard estimate.isFinite, estimate > 0, estimate < Double(UInt64.max) else { return nil }
        return UInt64(estimate)
    }

    /// Ollama's incoming estimate: the same 1.15 headroom over the tags size PLUS the KV cache for the
    /// requested context. A saturated KV (`Int64.max`, an overflowing geometry) estimates past any budget.
    static func estimatedIncomingBytes(sizeBytes: Int64, kvCacheBytes: Int64) -> UInt64? {
        guard sizeBytes > 0, kvCacheBytes >= 0 else { return nil }
        let (total, overflow) = sizeBytes.addingReportingOverflow(kvCacheBytes)
        guard !overflow else { return UInt64.max }
        return estimatedIncomingBytes(sizeBytes: total)
    }

    /// The pessimistic KV stand-in for a model whose `/api/show` carries no usable geometry; see
    /// `ollamaFallbackKVFractionPer8K`. Scales linearly with context, as the cache does.
    static func fallbackKVCacheBytes(sizeBytes: Int64, contextTokens: Int) -> Int64 {
        let estimate = (Double(sizeBytes) * ollamaFallbackKVFractionPer8K
            * Double(max(0, contextTokens)) / 8192.0).rounded(.up)
        guard estimate.isFinite, estimate >= 0 else { return Int64.max }
        return estimate < Double(Int64.max) ? Int64(estimate) : Int64.max
    }

    /// Internal rather than private so the first-run picker can ask the LOADER's question instead of
    /// asking a copy of it. A picker that pre-ticks a model this predicate would refuse is exactly the
    /// lie spec B5 exists to prevent, and the only way to guarantee they cannot drift is for there to
    /// be one predicate.
    static func fits(wiredBytes: UInt64, incomingBytes: UInt64,
                     budgetBytes: UInt64) -> Bool {
        let (total, overflow) = wiredBytes.addingReportingOverflow(incomingBytes)
        return !overflow && total <= budgetBytes
    }
}
