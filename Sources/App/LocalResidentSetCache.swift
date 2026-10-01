import Foundation

/// Which local models are resident right now, for route resolution's fit check (`LLMLocalCapacityFacts`).
///
/// Live wired memory already contains every resident model, so routing must not charge a resident model's
/// size a second time. This supplies the resident set from the SAME reads `ModelManager` decides on: LM
/// Studio's `lms ps --json` (`ModelResidency.residentModels`) and, only when the measured catalog has an
/// Ollama model (so Ollama is installed and answering on this Mac), Ollama's `/api/ps`
/// (`OllamaBackend.residentModels`). Each app is read on its own: one failing never hides the other.
///
/// Resolution must never wait on a slow read. The read runs on a private queue, and a caller waits for it
/// at most `waitSeconds`; the main thread never waits at all (`lms ps` is a subprocess, and the 2026-07-13
/// freeze was exactly that kind of call on the main thread). A caller that does not get an answer in time,
/// or any failed read, gets the EMPTY set, which is the pre-fix arithmetic: it can only refuse more.
///
/// The answer is kept briefly, alongside the wired reading it was taken with. It is reused only while it is
/// younger than `freshnessSeconds` AND the live wired reading is within `wiredDriftBytes` of that one: a model
/// loading or unloading moves wired memory by gigabytes, so a cached set never pairs with a wired reading
/// that already includes a model it does not know about.
///
/// The main thread, which never waits, may also take the last known answer up to `mainThreadReuseSeconds`
/// old, under the same wired-drift test. With only the 2 s window a main-thread resolution (the dictation
/// cleanup, Option+P, Option+M) practically never had an answer, since takes are further apart than that, so
/// a model another app or an earlier run had loaded was always charged twice there. The drift test is what
/// shows the set is still current: no model of chat size can load or unload without moving wired memory by
/// far more than `wiredDriftBytes`. The age bound only limits the one case it cannot see (one model swapped
/// for another of the same size), and that case is safe: `ModelManager` re-checks the live resident set and
/// the budget before any load. The main thread still starts a fresh read for the next resolution.
///
/// This is the second source. The first is `RecentLocalLoads`, `ModelManager`'s own record of what it just
/// made ready, which needs no read at all (`ModelsPowerSettingsStore.routingResidentRefs` joins the two).
final class LocalResidentSetCache {
    /// Reads the resident models of `backends`. Production is `liveRead`; a self-test injects its own.
    typealias Reader = (Set<LocalBackendID>) -> Set<LocalModelRef>

    static let shared = LocalResidentSetCache(read: LocalResidentSetCache.liveRead)

    static let defaultFreshnessSeconds: TimeInterval = 2.0
    /// How old a last known answer the never-waiting main thread may take while wired memory has not moved.
    static let defaultMainThreadReuseSeconds: TimeInterval = 300
    /// Far below any chat model's footprint, far above the noise of an idle Mac's wired count.
    static let defaultWiredDriftBytes: UInt64 = 512 * 1_048_576
    /// `lms ps --json` measured at ~0.16 s; a wedged CLI is cut loose here, not at the CLI's own 90 s.
    static let defaultWaitSeconds: TimeInterval = 1.0

    private struct Entry {
        let refs: Set<LocalModelRef>
        let backends: Set<LocalBackendID>
        let wiredBytes: UInt64
        let takenAt: Date
    }

    private let read: Reader
    private let now: () -> Date
    private let isMainThread: () -> Bool
    private let freshnessSeconds: TimeInterval
    private let mainThreadReuseSeconds: TimeInterval
    private let wiredDriftBytes: UInt64
    private let waitSeconds: TimeInterval
    private let queue = DispatchQueue(label: "com.viddydictate.local-resident-set", qos: .userInitiated)
    private let lock = NSLock()
    private var entry: Entry?
    private var inFlight: DispatchGroup?

    init(read: @escaping Reader,
         now: @escaping () -> Date = Date.init,
         isMainThread: @escaping () -> Bool = { Thread.isMainThread },
         freshnessSeconds: TimeInterval = LocalResidentSetCache.defaultFreshnessSeconds,
         mainThreadReuseSeconds: TimeInterval = LocalResidentSetCache.defaultMainThreadReuseSeconds,
         wiredDriftBytes: UInt64 = LocalResidentSetCache.defaultWiredDriftBytes,
         waitSeconds: TimeInterval = LocalResidentSetCache.defaultWaitSeconds) {
        self.read = read
        self.now = now
        self.isMainThread = isMainThread
        self.freshnessSeconds = freshnessSeconds
        self.mainThreadReuseSeconds = mainThreadReuseSeconds
        self.wiredDriftBytes = wiredDriftBytes
        self.waitSeconds = waitSeconds
    }

    /// The resident models of `backends`, judged against the live `wiredBytes`. Empty when nothing usable
    /// arrives in time; never blocks longer than `waitSeconds`, and never at all on the main thread, which
    /// takes the last known answer instead when wired memory has not moved since it was read.
    func residentRefs(backends: Set<LocalBackendID>, wiredBytes: UInt64) -> Set<LocalModelRef> {
        guard !backends.isEmpty else { return [] }
        lock.lock()
        if let usable = usableLocked(backends: backends, wiredBytes: wiredBytes, maxAge: freshnessSeconds) {
            lock.unlock()
            return usable
        }
        let group = inFlight ?? startReadLocked(backends: backends, wiredBytes: wiredBytes)
        if isMainThread() {
            let lastKnown = usableLocked(backends: backends, wiredBytes: wiredBytes,
                                         maxAge: mainThreadReuseSeconds) ?? []
            lock.unlock()
            return lastKnown
        }
        lock.unlock()

        guard group.wait(timeout: .now() + waitSeconds) == .success else { return [] }
        lock.lock()
        defer { lock.unlock() }
        // The read that just finished, if it covers these apps. Its wired reading may be another caller's,
        // so it is judged against this one's the same way a cached answer is.
        return usableLocked(backends: backends, wiredBytes: wiredBytes, maxAge: freshnessSeconds) ?? []
    }

    /// Start a read now and return at once, so the first resolution that will not wait (the main thread) has
    /// a last known answer to take. A no-op while a usable answer or a read is already there.
    func prime(backends: Set<LocalBackendID>, wiredBytes: UInt64) {
        guard !backends.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == nil,
              usableLocked(backends: backends, wiredBytes: wiredBytes, maxAge: freshnessSeconds) == nil
        else { return }
        _ = startReadLocked(backends: backends, wiredBytes: wiredBytes)
    }

    /// `prime` the shared cache for a freshly measured catalog, against the live wired reading. Called where
    /// the app measures its local catalog (launch, each Preflight pass, and `--websearch-selftest`, which
    /// establishes the same precondition), so a main-thread resolution soon after, a dictation cleanup
    /// for one, already knows the models another app or an earlier run left resident.
    static func primeLive(models: [LMStudioModelOption]?) {
        guard let models, !models.isEmpty, let wired = SystemMemory.wiredBytes else { return }
        shared.prime(backends: Set(models.map(\.backend)), wiredBytes: wired)
    }

    /// Forget the cached answer, so the next resolution reads again.
    func invalidate() {
        lock.lock()
        entry = nil
        lock.unlock()
    }

    private func usableLocked(backends: Set<LocalBackendID>, wiredBytes: UInt64,
                              maxAge: TimeInterval) -> Set<LocalModelRef>? {
        guard let entry, backends.isSubset(of: entry.backends),
              now().timeIntervalSince(entry.takenAt) <= maxAge else { return nil }
        let drift = wiredBytes > entry.wiredBytes ? wiredBytes - entry.wiredBytes : entry.wiredBytes - wiredBytes
        guard drift <= wiredDriftBytes else { return nil }
        return entry.refs.filter { backends.contains($0.backend) }
    }

    private func startReadLocked(backends: Set<LocalBackendID>, wiredBytes: UInt64) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        inFlight = group
        let read = self.read
        queue.async { [weak self] in
            let refs = Set(read(backends).map(ModelManager.canonical))
            if let self {
                self.lock.lock()
                self.entry = Entry(refs: refs, backends: backends, wiredBytes: wiredBytes, takenAt: self.now())
                self.inFlight = nil
                self.lock.unlock()
            }
            group.leave()
        }
        return group
    }

    /// The production read. LM Studio from `lms ps --json`, exactly the rows `ModelManager` matches a request
    /// against; Ollama from `/api/ps`, only when asked for (its models are in the catalog) and only on this
    /// Mac. A failed read contributes nothing.
    static func liveRead(_ backends: Set<LocalBackendID>) -> Set<LocalModelRef> {
        var refs = Set<LocalModelRef>()
        if backends.contains(.lmStudio), let rows = ModelResidency.residentModels() {
            for row in rows { refs.insert(LocalModelRef(backend: .lmStudio, modelID: row.identifier)) }
        }
        if backends.contains(.ollama), OllamaBackend.shared.localOnlyRefusal == nil,
           let rows = OllamaBackend.shared.residentModels() {
            for row in rows { refs.insert(row.ref) }
        }
        return refs
    }
}
