import Foundation

/// The single home for the app's LM Studio model policy: which models the app manages (the working
/// set) and the single app-configured idle TTL each is loaded with. Built on the stateless `ModelResidency`
/// primitives.
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
/// `recentLoads` is a record kept FOR route resolution; nothing here ever decides from it.
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

        init(
            availableInstalledModels: @escaping () -> [LMStudioInstalledModel]?,
            residentModels: @escaping () -> [ModelResidency.ResidentModel]?,
            wiredBytes: @escaping () -> UInt64?,
            budgetBytes: @escaping (Double) -> UInt64?,
            ensureLoaded: @escaping (String, Int) -> Bool,
            unload: @escaping (String) -> Void,
            log: @escaping (String) -> Void = { Log.write($0) },
            evictionSettleSeconds: Double = 0
        ) {
            self.availableInstalledModels = availableInstalledModels
            self.residentModels = residentModels
            self.wiredBytes = wiredBytes
            self.budgetBytes = budgetBytes
            self.ensureLoaded = ensureLoaded
            self.unload = unload
            self.log = log
            self.evictionSettleSeconds = evictionSettleSeconds
        }

        static let live = CapacityDependencies(
            availableInstalledModels: { ModelResidency.availableInstalledModels() },
            residentModels: { ModelResidency.residentModels() },
            wiredBytes: { SystemMemory.wiredBytes },
            budgetBytes: { SystemMemory.budgetBytes(forSliderPosition: $0) },
            ensureLoaded: { ModelResidency.ensureLoaded($0, ttlSeconds: $1) },
            unload: { ModelResidency.unload($0) },
            log: { Log.write($0) },
            evictionSettleSeconds: evictionSettleWindow)
    }

    /// `lms unload` returns before macOS has unwired the model worker's pages. Measured on this Mac
    /// (`vdmg-REV`, 2026-08-24): unload returned at +0.148s with `wire_count` still reporting 10.00 of
    /// 10.43 GB, and the reading did not settle to 3.50 GB until ~+0.68s. Re-reading immediately
    /// therefore compares the INCOMING model against the PRE-eviction number, so the recheck can never
    /// pass on the strength of the eviction it just performed - the app unloads its own warm model and
    /// refuses anyway. Waiting for the reading to catch up is what makes LOCKED DECISION 2's recheck
    /// mean anything; it is still ONE eviction pass, not a second one.
    static let evictionSettleWindow: Double = 2.0
    /// Sampling interval inside that window. Short enough that the common case costs ~1 sample.
    static let evictionSettleInterval: Double = 0.05

    static let shared = ModelManager()

    /// Conservative allowance for runtime allocation around the installed weights. L3 validates
    /// this against a real cold load and records the measurement in the chain baton.
    static let incomingFootprintFactor = 1.15

    private let policyLock = NSLock()
    /// Models whose cold load this process actually initiated. A model merely found resident is
    /// never adopted, even when its identifier is one ViddyDictate commonly uses.
    private var ownedModels = Set<String>()

    /// What this process just made ready, for route resolution's fit check (see `RecentLocalLoads`). Every
    /// successful readiness records into it, a reuse included, and every unload ViddyDictate itself performs
    /// (the eviction pass, `unload`, `unloadAll`) removes from it. Lock only, so routing can read it on the
    /// main thread.
    let recentLoads: RecentLocalLoads

    private enum CapacityPreparation {
        case alreadyResident
        case loadAllowed
        case refused(CapacityRefusal)
    }

    /// `clock` ages `recentLoads`; a gate passes its own.
    init(clock: @escaping () -> Date = Date.init) {
        self.recentLoads = RecentLocalLoads(clock: clock)
    }

    /// The idle TTL handed to LM Studio at load time. One persisted setting governs every model role.
    func ttl(for _: String) -> Int {
        Settings.modelIdleUnloadSeconds
    }

    /// Ensure `model` is resident for an imminent inference. BLOCKS until the model is loaded (a cold
    /// load) or the load fails — so call it OFF the main thread, before a timed request, so the cold
    /// load does not count against that request's timeout. Loads with the app's configured TTL so LM
    /// Studio owns the eviction; `ttlOverrideSeconds` is a test-only seam (the residency self-test uses
    /// a short TTL so eviction is observable without waiting for the configured interval). Returns
    /// a typed result so every client must distinguish a capacity refusal from an LM Studio load
    /// failure instead of silently collapsing the policy outcome to a Bool.
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
        policyLock.lock()
        defer { policyLock.unlock() }

        switch prepareCapacity(for: model, dependencies: dependencies) {
        case .alreadyResident, .loadAllowed:
            return .ready
        case .refused(let reason):
            return .capacityRefused(reason)
        }
    }

    @discardableResult
    func ensureReady(
        _ model: String,
        ttlOverrideSeconds: Int? = nil,
        dependencies: CapacityDependencies
    ) -> ReadinessResult {
        policyLock.lock()
        defer { policyLock.unlock() }

        let ttl = ttlOverrideSeconds ?? ttl(for: model)
        switch prepareCapacity(for: model, dependencies: dependencies) {
        case .alreadyResident:
            // A use: LM Studio's idle clock restarts, so routing's does too.
            recentLoads.recordUse(model, ttlSeconds: ttl)
            return .ready
        case .refused(let reason):
            return .capacityRefused(reason)
        case .loadAllowed:
            break
        }

        let loaded = dependencies.ensureLoaded(model, ttl)
        guard loaded else { return .loadFailed }
        ownedModels.insert(model)
        recentLoads.recordUse(model, ttlSeconds: ttl)
        return .ready
    }

    // MARK: - ViddyDictate's own unloads

    /// Unload one model ViddyDictate loaded for itself (the handoff vision helper after its one call).
    /// Routing stops treating it as resident first, so a resolution racing the unload can only charge it,
    /// never exempt it.
    func unload(_ model: String, dependencies: CapacityDependencies = .live) {
        recentLoads.forget(model)
        dependencies.unload(model)
    }

    /// The Setup tab's Unload all (`lms unload --all`). Every routing record goes, whoever loaded the model.
    /// `unloadAll` is LM Studio's own command; a gate passes a scripted one.
    func unloadAll(unloadAll: () -> Void = { ModelResidency.unloadAll() }) {
        recentLoads.forgetAll()
        unloadAll()
    }

    /// Shared capacity preparation for the early Option+G check and the authoritative load path.
    /// Keeping the facts, estimate, ownership filter, one-pass eviction, and recheck in one function
    /// prevents the early-out from drifting into a looser policy than `ensureReady`.
    private func prepareCapacity(
        for model: String,
        dependencies: CapacityDependencies
    ) -> CapacityPreparation {

        guard let residents = dependencies.residentModels() else {
            return .refused(.factsUnavailable)
        }

        // Drop ownership as soon as a previously owned instance is observed absent (for example,
        // after its LM Studio TTL fires). A later foreign load with that identifier is not adopted.
        ownedModels.formIntersection(residents.map(\.identifier))
        // The same proof ends routing's record: a model LM Studio no longer holds (its TTL fired early, the
        // user unloaded it in LM Studio) stops counting as resident at the first read that shows it.
        recentLoads.retainOnly(Set(residents.map(\.identifier)))

        // A resident request allocates nothing new. Do not re-load it (LM Studio would create :2),
        // and do not claim ownership if another caller made it resident.
        if let resident = residents.first(where: { $0.identifier == model }) {
            // This read is diagnostic only. Reusing a resident remains authorized even when the
            // selected budget was lowered beneath its footprint, or when the budget is unreadable:
            // the request wires no new model memory. Keep this inside the resident short-circuit so
            // it can never become a refusal or trigger the cold-load eviction path.
            if let budget = dependencies.budgetBytes(Settings.modelMemoryBudgetSliderPosition),
               resident.sizeBytes > budget {
                dependencies.log(
                    "model capacity: \(model) is already resident at "
                        + "\(SystemMemory.formatGB(resident.sizeBytes)), above the current "
                        + "\(SystemMemory.formatGB(budget)) budget; reusing it because this request "
                        + "allocates no new model memory")
            }
            return .alreadyResident
        }

        guard let installed = dependencies.availableInstalledModels(),
              let size = installed.first(where: { $0.modelID == model })?.sizeBytes,
              size > 0,
              let estimatedIncoming = Self.estimatedIncomingBytes(sizeBytes: size),
              let firstWired = dependencies.wiredBytes(),
              let firstBudget = dependencies.budgetBytes(Settings.modelMemoryBudgetSliderPosition)
        else { return .refused(.factsUnavailable) }

        if !Self.fits(wiredBytes: firstWired, incomingBytes: estimatedIncoming,
                      budgetBytes: firstBudget) {
            // ONE bounded pass over one snapshot, LRU first. Only models cold-loaded by this process
            // are candidates; an older/larger foreign model is never touched. Busy/loading owned
            // models and the requested identifier are also excluded.
            let candidates = residents
                .filter {
                    ownedModels.contains($0.identifier)
                        && $0.identifier != model
                        && $0.isIdle
                }
                .sorted(by: Self.isOlderForEviction)
            for candidate in candidates {
                dependencies.unload(candidate.identifier)
                // Even a failed/no-op unload cannot justify a later, broader attempt. Forgetting the
                // claim makes the safety boundary tighter; the live recheck below decides capacity.
                ownedModels.remove(candidate.identifier)
                recentLoads.forget(candidate.identifier)
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

    /// Missing recency cannot prove that a model is stale, so it sorts after every row with a known
    /// last-use time. This is deliberately explicit instead of using a zero sentinel: zero would make
    /// an active row the first eviction candidate.
    private static func isOlderForEviction(
        _ lhs: ModelResidency.ResidentModel,
        _ rhs: ModelResidency.ResidentModel
    ) -> Bool {
        switch (lhs.lastUsedTime, rhs.lastUsedTime) {
        case let (left?, right?):
            return left == right ? lhs.identifier < rhs.identifier : left < right
        case (nil, nil):
            return lhs.identifier < rhs.identifier
        case (nil, _):
            return false
        case (_, nil):
            return true
        }
    }

    static func estimatedIncomingBytes(sizeBytes: Int64) -> UInt64? {
        guard sizeBytes > 0 else { return nil }
        let estimate = (Double(sizeBytes) * incomingFootprintFactor).rounded(.up)
        guard estimate.isFinite, estimate > 0, estimate < Double(UInt64.max) else { return nil }
        return UInt64(estimate)
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

/// ViddyDictate's own record of the LM Studio models it just made ready, by model id: the source route
/// resolution's fit check can read with no I/O at all.
///
/// Routing must not charge a resident model twice: live wired memory already holds it. Its other source,
/// `LocalResidentSetCache`, is a live read (`lms ps`) that a main-thread resolution never waits for, and that
/// cannot be reused right after a load because the wired reading moved by the model's size. The dictation
/// cleanup, Option+P and Option+M resolve on the main thread, and so does `--websearch-selftest`, so after a
/// load they all saw an empty set and charged the model again: on the Mac (2026-10-01) Option+L answered
/// once, then stepped retrieval down to a 4B model and reported that nothing fits. This record is fed by
/// `ModelManager` itself, so it is right there whatever thread asks.
///
/// - Every successful `ensureReady` records `(model id, lastUse, ttl)`, `ttl` being the idle window it handed
///   LM Studio (the configured one, or a caller's override). A reuse of a resident model records too: the
///   use restarts LM Studio's idle clock.
/// - A model counts as resident while `now - lastUse < ttl`. LM Studio starts its idle clock when a request
///   ENDS, after the `lastUse` stamped before it, so this window closes no later than LM Studio's own.
/// - ViddyDictate's own unloads remove it (`ModelManager.unload`, `unloadAll`, the eviction pass), and so
///   does any `ModelManager` read of `lms ps` that shows it absent.
///
/// A stale entry is SAFE. If LM Studio evicted the model early (memory pressure, a restart) or the user
/// unloaded it by hand, routing may pick that model on the strength of this record, but routing only picks:
/// `ModelManager.prepareCapacity` is still the authority for every load, reads LM Studio's live resident set,
/// finds the model absent, budgets it as a cold load against live wired memory, runs its one eviction pass,
/// and refuses with `.overBudget` when it still does not fit. Nothing is ever loaded past the budget on this
/// record's say-so. The refusal is the existing `CleanupClient.overBudgetMessage`: the dictation cleanup
/// takes its one over-budget step-down retry to the next model that fits; other routes surface the refusal.
/// The same read drops the entry (`retainOnly`), so the next resolution is right again.
final class RecentLocalLoads {
    struct Entry: Equatable {
        let lastUse: Date
        let ttlSeconds: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// `modelID` was just made ready (or reused) with `ttlSeconds` of idle window. A window of 0 or less
    /// records nothing: no idle window is known, so routing is not told the model will stay.
    func recordUse(_ modelID: String, ttlSeconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard ttlSeconds > 0 else {
            entries[modelID] = nil
            return
        }
        entries[modelID] = Entry(lastUse: clock(), ttlSeconds: TimeInterval(ttlSeconds))
    }

    func forget(_ modelID: String) {
        lock.lock()
        entries[modelID] = nil
        lock.unlock()
    }

    func forgetAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
    }

    /// A read of `lms ps` listed exactly `present`: anything else on record is gone.
    func retainOnly(_ present: Set<String>) {
        lock.lock()
        entries = entries.filter { present.contains($0.key) }
        lock.unlock()
    }

    /// The model ids still inside their idle window. Expired entries are dropped as they are seen.
    func residentModelIDs() -> Set<String> {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.lastUse) < $0.value.ttlSeconds }
        return Set(entries.keys)
    }
}
