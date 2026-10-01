import Foundation

/// Which LM Studio models are resident right now, for route resolution's fit check (`LLMLocalCapacityFacts`).
///
/// Live wired memory already contains every resident model, so routing must not charge a resident model's
/// size a second time. This supplies the resident set from the SAME read `ModelManager` decides on: LM
/// Studio's `lms ps --json` (`ModelResidency.residentModels`), by identifier, the field `ModelManager`
/// matches a request against.
///
/// Resolution must never wait on a slow read. The read runs on a private queue, and a caller waits for it
/// at most `waitSeconds`; the main thread never waits at all (`lms ps` is a subprocess, and the 2026-07-13
/// freeze was exactly that kind of call on the main thread). A caller that does not get an answer in time,
/// or any failed read, gets the EMPTY set, which is the pre-fix arithmetic: it can only refuse more.
///
/// The answer is kept briefly, alongside the wired reading it was taken with. It is reused only while it is
/// younger than `freshnessSeconds` AND the live wired reading has moved less than `wiredDriftBytes` from that
/// one: a model loading or unloading moves wired memory by gigabytes, so a cached set never pairs with a
/// wired reading that already includes a model it does not know about.
final class LocalResidentSetCache {
    /// Reads LM Studio's resident identifiers. Production is `liveRead`; a self-test injects its own.
    typealias Reader = () -> Set<String>

    static let shared = LocalResidentSetCache(read: LocalResidentSetCache.liveRead)

    static let defaultFreshnessSeconds: TimeInterval = 2.0
    /// Far below any chat model's footprint, far above the noise of an idle Mac's wired count.
    static let defaultWiredDriftBytes: UInt64 = 512 * 1_048_576
    /// `lms ps --json` measured at ~0.16 s; a wedged CLI is cut loose here, not at the CLI's own 90 s.
    static let defaultWaitSeconds: TimeInterval = 1.0

    private struct Entry {
        let modelIDs: Set<String>
        let wiredBytes: UInt64
        let takenAt: Date
    }

    private let read: Reader
    private let now: () -> Date
    private let isMainThread: () -> Bool
    private let freshnessSeconds: TimeInterval
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
         wiredDriftBytes: UInt64 = LocalResidentSetCache.defaultWiredDriftBytes,
         waitSeconds: TimeInterval = LocalResidentSetCache.defaultWaitSeconds) {
        self.read = read
        self.now = now
        self.isMainThread = isMainThread
        self.freshnessSeconds = freshnessSeconds
        self.wiredDriftBytes = wiredDriftBytes
        self.waitSeconds = waitSeconds
    }

    /// LM Studio's resident identifiers, judged against the live `wiredBytes`. Empty when nothing usable
    /// arrives in time; never blocks longer than `waitSeconds`, and never at all on the main thread.
    func residentModelIDs(wiredBytes: UInt64) -> Set<String> {
        lock.lock()
        if let usable = usableLocked(wiredBytes: wiredBytes) {
            lock.unlock()
            return usable
        }
        let group = inFlight ?? startReadLocked(wiredBytes: wiredBytes)
        lock.unlock()

        guard !isMainThread() else { return [] }
        guard group.wait(timeout: .now() + waitSeconds) == .success else { return [] }
        lock.lock()
        defer { lock.unlock() }
        // The read that just finished. Its wired reading may be another caller's, so it is judged against
        // this one's the same way a cached answer is.
        return usableLocked(wiredBytes: wiredBytes) ?? []
    }

    /// Forget the cached answer, so the next resolution reads again.
    func invalidate() {
        lock.lock()
        entry = nil
        lock.unlock()
    }

    private func usableLocked(wiredBytes: UInt64) -> Set<String>? {
        guard let entry, now().timeIntervalSince(entry.takenAt) < freshnessSeconds else { return nil }
        let drift = wiredBytes > entry.wiredBytes ? wiredBytes - entry.wiredBytes : entry.wiredBytes - wiredBytes
        guard drift < wiredDriftBytes else { return nil }
        return entry.modelIDs
    }

    private func startReadLocked(wiredBytes: UInt64) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        inFlight = group
        let read = self.read
        queue.async { [weak self] in
            let modelIDs = read()
            if let self {
                self.lock.lock()
                self.entry = Entry(modelIDs: modelIDs, wiredBytes: wiredBytes, takenAt: self.now())
                self.inFlight = nil
                self.lock.unlock()
            }
            group.leave()
        }
        return group
    }

    /// The production read: `lms ps --json`, exactly the rows `ModelManager` matches a request against. A
    /// failed read contributes nothing.
    static func liveRead() -> Set<String> {
        Set((ModelResidency.residentModels() ?? []).map(\.identifier))
    }
}
