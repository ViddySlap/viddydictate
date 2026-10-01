import Foundation

/// `--resident-fit-selftest`: route resolution does not charge an already-resident local model twice.
///
/// The 1.1.0 fit check computed `liveWired + size x 1.15 <= budget` even for a model the machine already
/// held, and live wired memory already contains it. On a 64 GB Mac at the default budget (33.87 GB), once
/// the cleanup model (17.2 GB) and the email model (6.9 GB) were both resident, neither "fit", so Option+L
/// answered once and then reported "local pin has no installed model". `ModelManager.prepareCapacity`
/// never charged a resident model; this gate holds routing to the same rule.
///
/// Real code throughout: real `ModelsPowerSettingsStore`s in a fresh temporary folder, the real
/// `resolveRoute` / `resolveLocalRoute`, and the real live-facts path
/// (`ModelsPowerSettingsStore.capacityFacts` fed by a `LocalResidentSetCache`), with only the resident
/// READ injected. The wired and budget figures are fixed, so nothing reads the kernel, `lms` or Ollama.
///
/// Fixture ids are this gate's own (`residentfit-fixture-*`), never a production default, so no hardcoded
/// model id anywhere in the app can make a check pass by accident.
///
/// The second half drives a real `ModelManager` over a scripted LM Studio (`CapacityDependencies`), and
/// resolves on the main thread's view of the live read: none, since the main thread never waits and the
/// wired reading has just moved. That is the Mac's 2026-10-01 failure at ffa0a3c (`--websearch-selftest`
/// runs the pipeline on the main thread; ev01 answered, ev04 stepped retrieval down to a 4B model and then
/// found nothing fit). Routing must still know what `ModelManager` itself just loaded (`RecentLocalLoads`),
/// forget it on ViddyDictate's own unload, and stop counting it once its idle window has passed.
///
/// Negative controls, each of which must be caught:
/// (1) the double-counting fit (1.1.0's code): the capacity facts carry no resident set;
/// (2) a backend-blind resident set: a model resident in ONE app makes the same id free in the other;
/// (3) the live read alone, `ModelManager`'s record not consulted (ffa0a3c's code);
/// (4) a record that never expires (a model counts as resident forever after one load).
enum ResidentFitFixtureSelfTest {
    private static let coderID = "residentfit-fixture-coder-30b"
    private static let mailID = "residentfit-fixture-mail-e4b"
    private static let smallID = "residentfit-fixture-small-1b"

    private static let coderBytes: Int64 = 17_200_000_000
    private static let mailBytes: Int64 = 6_900_000_000
    private static let smallBytes: Int64 = 1_000_000_000
    /// What the Mac had wired before either model loaded (bge-m3 and the system), measured in the A/B.
    private static let baselineWired: UInt64 = 3_400_000_000
    /// Both big models resident: the live wired reading already contains them.
    private static let bothResidentWired: UInt64 = baselineWired + UInt64(coderBytes) + UInt64(mailBytes)
    /// The default slider position's budget on that 64 GB Mac.
    private static let budget: UInt64 = 33_870_000_000

    private static func lm(_ id: String) -> LocalModelRef { LocalModelRef(backend: .lmStudio, modelID: id) }

    private static func option(_ id: String, _ size: Int64) -> LMStudioModelOption {
        LMStudioModelOption(modelID: id, label: id, sizeBytes: size)
    }

    private static let withSmall = [option(coderID, coderBytes), option(mailID, mailBytes), option(smallID, smallBytes)]
    private static let bigOnly = [option(coderID, coderBytes), option(mailID, mailBytes)]

    // MARK: - The seam the mutants replace

    /// Builds the store's capacity provider from a fixed wired reading and an injected resident read.
    private typealias ProviderFactory = (_ wired: UInt64, _ residents: Set<LocalModelRef>)
        -> ModelsPowerSettingsStore.LocalCapacityProvider

    /// Production's shape: `capacityFacts` with the resident set a `LocalResidentSetCache` hands back.
    private static let realProvider: ProviderFactory = { wired, residents in
        let cache = LocalResidentSetCache(read: { backends in residents.filter { backends.contains($0.backend) } },
                                          isMainThread: { false })
        return { models in
            guard let models, !models.isEmpty else { return nil }
            return ModelsPowerSettingsStore.capacityFacts(
                models: models, wiredBytes: wired, budgetBytes: budget,
                residentRefs: cache.residentRefs(backends: Set(models.map(\.backend)), wiredBytes: wired))
        }
    }

    private static func makeStore(root: URL, models: [LMStudioModelOption],
                                  provider: @escaping ModelsPowerSettingsStore.LocalCapacityProvider)
        -> ModelsPowerSettingsStore {
        let url = root.appendingPathComponent("models-power-\(UUID().uuidString).json")
        let store = ModelsPowerSettingsStore(url: url, legacy: .empty, localCapacity: provider,
                                             preferredLocalBackend: { nil })
        store.setLocalAvailabilityState(.available, models: models, installedBackends: [.lmStudio])
        for route in [LLMRouteID.cleanupL1, .searchRetrieval] { try? store.setSelectedBundle(.local(coderID), for: route) }
        for route in [LLMRouteID.email, .searchLocalSynth] { try? store.setSelectedBundle(.local(mailID), for: route) }
        return store
    }

    static func run() -> Bool {
        print("=== ViddyDictate resident-fit selftest (routing never charges a resident model twice) ===")
        Settings.registerDefaults()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-resident-fit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reporter = SelfTestReporter()
        checkFixture(reporter)
        checkContract(realProvider, root: root, reporter)
        checkCache(reporter)
        checkMainThreadReuse(reporter)
        print("--- on the main thread now: \(Thread.isMainThread ? "yes" : "no") (the gate also pins it by injection) ---")
        checkOwnLoads(realSeam, root: root, reporter)
        checkSearchSequence(realSeam, root: root, reporter)
        checkStaleEntryIsSafe(root: root, reporter)
        checkNegativeControls(root: root, reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "resident-fit"))
        print(reporter.passed ? "[resident-fit-selftest] PASS" : "[resident-fit-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Fixture sanity

    private static func charged(_ size: Int64, wired: UInt64) -> Bool {
        guard let incoming = ModelManager.estimatedIncomingBytes(sizeBytes: size) else { return false }
        return ModelManager.fits(wiredBytes: wired, incomingBytes: incoming, budgetBytes: budget)
    }

    private static func checkFixture(_ reporter: SelfTestReporter) {
        print("--- fixture: the A/B's machine, both big models resident ---")
        reporter.record("fixture: charged again, the coder model does not fit on top of the wired reading",
                        !charged(coderBytes, wired: bothResidentWired))
        reporter.record("fixture: charged again, the mail model does not fit on top of the wired reading",
                        !charged(mailBytes, wired: bothResidentWired))
        reporter.record("fixture: the small model fits even charged",
                        charged(smallBytes, wired: bothResidentWired))
    }

    // MARK: - Contract (the part the mutants are run against)

    private static let coderPinnedCheck =
        "both resident: cleanup resolves pinned on the coder model, no step-down"
    private static let mailPinnedCheck =
        "both resident: email resolves pinned on the mail model, no step-down"
    private static let backendAwareCheck =
        "a model resident in Ollama does not make LM Studio's same-id model free"

    private static func isPinned(_ resolution: LLMRouteResolution, on id: String) -> Bool {
        guard case .pinned(let bundle) = resolution else { return false }
        return bundle.provider == .local && bundle.modelID == id && bundle.resolvedLocalBackend == .lmStudio
            && resolution.upgradeOffer == nil
    }

    private static func checkContract(_ provider: ProviderFactory, root: URL, _ reporter: SelfTestReporter) {
        print("--- both models resident, wired = 3.4 + 17.2 + 6.9 GB, budget 33.87 GB ---")
        let resident = makeStore(root: root, models: withSmall,
                                 provider: provider(bothResidentWired, [lm(coderID), lm(mailID)]))
        let cleanup = resident.resolveRoute(.cleanupL1)
        reporter.record(coderPinnedCheck, isPinned(cleanup, on: coderID), cleanup.logToken)
        let retrieval = resident.resolveLocalRoute(.searchRetrieval)
        reporter.record("both resident: search retrieval resolves pinned on the coder model, no step-down",
                        isPinned(retrieval, on: coderID), retrieval.logToken)
        let email = resident.resolveRoute(.email)
        reporter.record(mailPinnedCheck, isPinned(email, on: mailID), email.logToken)
        let synth = resident.resolveRoute(.searchLocalSynth)
        reporter.record("both resident: search synthesis resolves pinned on the mail model, no step-down",
                        isPinned(synth, on: mailID), synth.logToken)

        print("--- the same models NOT resident, the same wired reading ---")
        let cold = makeStore(root: root, models: withSmall, provider: provider(bothResidentWired, []))
        let coldCleanup = cold.resolveRoute(.cleanupL1)
        reporter.record("not resident: cleanup still steps down to the installed model that fits",
                        coldCleanup.bundle?.modelID == smallID
                            && coldCleanup.upgradeOffer?.preferredModelID == coderID,
                        coldCleanup.logToken)
        let coldEmail = cold.resolveRoute(.email)
        reporter.record("not resident: email still steps down to the installed model that fits",
                        coldEmail.bundle?.modelID == smallID && coldEmail.upgradeOffer?.preferredModelID == mailID,
                        coldEmail.logToken)

        print("--- the resident set is (app, id) ---")
        let otherApp = makeStore(root: root, models: withSmall,
                                 provider: provider(bothResidentWired, [LocalModelRef(backend: .ollama, modelID: coderID)]))
        let crossed = otherApp.resolveRoute(.cleanupL1)
        reporter.record(backendAwareCheck, crossed.bundle?.modelID == smallID, crossed.logToken)

        print("--- nothing fits: the reason says so ---")
        let noFit = makeStore(root: root, models: bigOnly, provider: provider(bothResidentWired, []))
        let off = noFit.resolveRoute(.cleanupL1)
        let reason = off.offReason ?? ""
        reporter.record("nothing fits: the route is off and the reason says nothing fits the memory budget",
                        off.bundle == nil && reason.contains("fits the memory budget")
                            && reason.hasPrefix(LLMAvailabilityRouting.nothingFitsReason),
                        reason)
        reporter.record("nothing fits: the reason does not claim no model is installed",
                        !reason.contains("no installed model"), reason)
        reporter.record("nothing fits: cloud fallback is still disabled for a Local pin",
                        reason.contains("automatic cloud fallback is disabled"), reason)

        let empty = makeStore(root: root, models: [], provider: provider(bothResidentWired, []))
        let emptyReason = empty.resolveRoute(.cleanupL1).offReason ?? ""
        reporter.record("an empty catalog keeps the existing no-installed-model reason",
                        emptyReason.hasPrefix("local pin has no installed model; automatic cloud fallback is disabled")
                            && emptyReason.contains("no local models installed"),
                        emptyReason)

        print("--- facts built without a resident set are the old arithmetic exactly ---")
        let legacy = LLMLocalCapacityFacts(sizeBytes: { $0 == coderID ? coderBytes : nil },
                                           wiredBytes: bothResidentWired, budgetBytes: budget)
        reporter.record("the three-argument initializer charges the model as before (no resident exemption)",
                        !legacy.fits(coderID) && legacy.residentRefs.isEmpty)
    }

    // MARK: - The resident read never blocks resolution

    private static func checkCache(_ reporter: SelfTestReporter) {
        print("--- LocalResidentSetCache: reuse, refresh, and never blocking ---")
        var reads = 0
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let counting = LocalResidentSetCache(
            read: { _ in reads += 1; return [lm(coderID)] }, now: { clock }, isMainThread: { false })
        let first = counting.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired)
        let again = counting.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired + 1_000_000)
        reporter.record("a fresh answer is reused while wired memory has not moved",
                        first == [lm(coderID)] && again == first && reads == 1, "reads=\(reads)")
        _ = counting.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired - UInt64(mailBytes))
        reporter.record("a wired swing of a model's size forces a fresh read", reads == 2, "reads=\(reads)")
        clock = clock.addingTimeInterval(LocalResidentSetCache.defaultFreshnessSeconds + 1)
        _ = counting.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired - UInt64(mailBytes))
        reporter.record("an answer older than its freshness window is read again", reads == 3, "reads=\(reads)")
        let ollamaToo = counting.residentRefs(backends: [.lmStudio, .ollama],
                                              wiredBytes: bothResidentWired - UInt64(mailBytes))
        reporter.record("asking about an app the cached answer did not read reads again",
                        reads == 4 && ollamaToo == [lm(coderID)], "reads=\(reads)")

        let release = DispatchSemaphore(value: 0)
        let slow = LocalResidentSetCache(read: { _ in
            _ = release.wait(timeout: .now() + 5)
            return [lm(coderID)]
        }, isMainThread: { false }, waitSeconds: 0.2)
        let started = Date()
        let timedOut = slow.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired)
        let waited = Date().timeIntervalSince(started)
        reporter.record("a slow read returns the empty set within the wait budget, not after the read",
                        timedOut.isEmpty && waited < 2.0, String(format: "waited=%.2fs", waited))
        release.signal()

        var mainReads = 0
        let mainLatch = DispatchSemaphore(value: 0)
        let onMain = LocalResidentSetCache(read: { _ in
            mainReads += 1
            mainLatch.signal()
            return [lm(coderID)]
        }, isMainThread: { true }, waitSeconds: 5)
        let mainStarted = Date()
        let mainAnswer = onMain.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired)
        let mainWaited = Date().timeIntervalSince(mainStarted)
        reporter.record("on the main thread the read never blocks: empty now, read in the background",
                        mainAnswer.isEmpty && mainWaited < 1.0, String(format: "waited=%.2fs", mainWaited))
        let backgroundDone = mainLatch.wait(timeout: .now() + 5) == .success
        var mainLater = Set<LocalModelRef>()
        let pollUntil = Date().addingTimeInterval(2)
        while mainLater.isEmpty && Date() < pollUntil {
            Thread.sleep(forTimeInterval: 0.02)
            mainLater = onMain.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired)
        }
        reporter.record("the background read serves the next resolution",
                        backgroundDone && mainLater == [lm(coderID)] && mainReads == 1, "reads=\(mainReads)")

        let failing = LocalResidentSetCache(read: { _ in [] }, isMainThread: { false })
        reporter.record("a failed read is the empty set (the old arithmetic, refusing more never less)",
                        failing.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired).isEmpty)
        reporter.record("an empty catalog asks no local app anything",
                        LocalResidentSetCache(read: { _ in
                            reads += 100
                            return []
                        }).residentRefs(backends: [], wiredBytes: 0).isEmpty && reads == 4,
                        "reads=\(reads)")
    }

    // MARK: - The main thread may reuse a drift-checked last known answer

    /// One cache with its own clock and thread flag, populated once off the main thread at `wired`.
    private static func populatedCache(wired: UInt64) -> (LocalResidentSetCache, (TimeInterval) -> Void) {
        final class Knobs { var clock = Date(timeIntervalSince1970: 1_900_000_000); var onMain = false }
        let knobs = Knobs()
        let cache = LocalResidentSetCache(read: { _ in [lm(coderID)] }, now: { knobs.clock },
                                          isMainThread: { knobs.onMain })
        _ = cache.residentRefs(backends: [.lmStudio], wiredBytes: wired)
        knobs.onMain = true
        return (cache, { knobs.clock = knobs.clock.addingTimeInterval($0) })
    }

    private static func checkMainThreadReuse(_ reporter: SelfTestReporter) {
        print("--- LocalResidentSetCache: the never-waiting main thread and the last known answer ---")
        let (reused, ageReused) = populatedCache(wired: bothResidentWired)
        ageReused(LocalResidentSetCache.defaultFreshnessSeconds + 8)
        let reuse = reused.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired + 1_000_000)
        reporter.record("main thread: a last known answer past the 2 s window is served while wired has not moved",
                        reuse == [lm(coderID)], "\(reuse.map(\.modelID))")
        let (moved, ageMoved) = populatedCache(wired: bothResidentWired)
        ageMoved(LocalResidentSetCache.defaultFreshnessSeconds + 8)
        let afterMove = moved.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired - UInt64(mailBytes))
        reporter.record("main thread: not once wired memory moved by a model's size", afterMove.isEmpty,
                        "\(afterMove.map(\.modelID))")
        let (old, ageOld) = populatedCache(wired: bothResidentWired)
        ageOld(LocalResidentSetCache.defaultMainThreadReuseSeconds + 1)
        let tooOld = old.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired)
        reporter.record("main thread: not past the reuse window", tooOld.isEmpty, "\(tooOld.map(\.modelID))")

        final class Counter { var reads = 0 }
        let counter = Counter()
        let release = DispatchSemaphore(value: 0)
        let primed = LocalResidentSetCache(read: { _ in
            _ = release.wait(timeout: .now() + 5)
            counter.reads += 1
            return [lm(coderID)]
        }, isMainThread: { true })
        let primeStarted = Date()
        primed.prime(backends: [.lmStudio], wiredBytes: bothResidentWired)
        let primeWaited = Date().timeIntervalSince(primeStarted)
        release.signal()
        var served = Set<LocalModelRef>()
        let until = Date().addingTimeInterval(2)
        while served.isEmpty && Date() < until {
            Thread.sleep(forTimeInterval: 0.02)
            served = primed.residentRefs(backends: [.lmStudio], wiredBytes: bothResidentWired)
        }
        reporter.record("prime returns at once and its read serves the main thread's first resolution",
                        primeWaited < 1.0 && served == [lm(coderID)] && counter.reads == 1,
                        String(format: "prime=%.2fs reads=%d", primeWaited, counter.reads))
    }

    // MARK: - ModelManager's own loads (the seam mutants 3 and 4 replace)

    /// A scripted LM Studio: installed sizes, a resident list, and a wired reading its loads and unloads move.
    private final class ScriptedLMStudio {
        var residents: [ModelResidency.ResidentModel] = []
        var wired: UInt64 = ResidentFitFixtureSelfTest.baselineWired
        var loads: [String] = []
        let sizes: [String: Int64] = [
            ResidentFitFixtureSelfTest.coderID: ResidentFitFixtureSelfTest.coderBytes,
            ResidentFitFixtureSelfTest.mailID: ResidentFitFixtureSelfTest.mailBytes,
            ResidentFitFixtureSelfTest.smallID: ResidentFitFixtureSelfTest.smallBytes,
        ]

        /// LM Studio dropping a model on its own (memory pressure, a restart, the user in its GUI).
        func evictBehindOurBack(_ id: String, wiredFalls: Bool) {
            guard let i = residents.firstIndex(where: { $0.identifier == id }) else { return }
            if wiredFalls { wired -= residents[i].sizeBytes }
            residents.remove(at: i)
        }

        func setStatus(_ id: String, _ status: String) {
            residents = residents.map {
                $0.identifier == id
                    ? ModelResidency.ResidentModel(identifier: $0.identifier, sizeBytes: $0.sizeBytes,
                                                   lastUsedTime: $0.lastUsedTime, status: status)
                    : $0
            }
        }

        var dependencies: ModelManager.CapacityDependencies {
            ModelManager.CapacityDependencies(
                availableInstalledModels: {
                    self.sizes.sorted { $0.key < $1.key }.map {
                        LMStudioInstalledModel(modelID: $0.key, label: $0.key, type: "llm",
                                               sizeBytes: $0.value, visionFlag: nil)
                    }
                },
                residentModels: { self.residents },
                wiredBytes: { self.wired },
                budgetBytes: { _ in ResidentFitFixtureSelfTest.budget },
                ensureLoaded: { id, ttl in
                    guard let size = self.sizes[id] else { return false }
                    self.loads.append(id)
                    if !self.residents.contains(where: { $0.identifier == id }) {
                        self.residents.append(ModelResidency.ResidentModel(
                            identifier: id, sizeBytes: UInt64(size), lastUsedTime: UInt64(self.loads.count),
                            status: "idle", ttlSeconds: ttl))
                        self.wired += UInt64(size)
                    }
                    return true
                },
                unload: { id in self.evictBehindOurBack(id, wiredFalls: true) },
                log: { _ in })
        }
    }

    /// How routing reads residency: which `ModelManager` keeps the record, and how the record and the live
    /// read are joined. Production is `realSeam`; mutants 3 and 4 replace one half each.
    private struct OwnLoadsSeam {
        let makeManager: (@escaping () -> Date) -> ModelManager
        let residentRefs: (_ manager: ModelManager, _ cache: LocalResidentSetCache,
                           _ backends: Set<LocalBackendID>, _ wired: UInt64) -> Set<LocalModelRef>
    }

    private static let realSeam = OwnLoadsSeam(
        makeManager: { ModelManager(clock: $0) },
        residentRefs: { manager, cache, backends, wired in
            ModelsPowerSettingsStore.routingResidentRefs(backends: backends, wiredBytes: wired,
                                                         residents: cache, recentLoads: manager.recentLoads)
        })

    /// The main thread's view of the live read right after a load: no usable answer, and it never waits.
    /// The read itself answers empty too, so nothing a background read lands can help: forced empty AND stale.
    private static func mainThreadCache() -> LocalResidentSetCache {
        LocalResidentSetCache(read: { _ in [] }, isMainThread: { true })
    }

    /// The store's capacity provider over the scripted machine: live wired from the script, the resident set
    /// through `seam`. `facts` keeps the last facts built, so a check can ask them directly.
    private final class FactsProbe { var facts: LLMLocalCapacityFacts? }

    private static func provider(_ seam: OwnLoadsSeam, manager: ModelManager, machine: ScriptedLMStudio,
                                 probe: FactsProbe) -> ModelsPowerSettingsStore.LocalCapacityProvider {
        let cache = mainThreadCache()
        return { models in
            guard let models, !models.isEmpty else { return nil }
            let facts = ModelsPowerSettingsStore.capacityFacts(
                models: models, wiredBytes: machine.wired, budgetBytes: budget,
                residentRefs: seam.residentRefs(manager, cache, Set(models.map(\.backend)), machine.wired))
            probe.facts = facts
            return facts
        }
    }

    private static let ownCoderPinnedCheck =
        "after ModelManager loaded both, a main-thread resolution keeps cleanup pinned on the coder model"
    private static let ownExpiryCheck =
        "once the mail model's idle window passes unused, routing charges it again (email steps down)"
    private static let searchSecondQuestionCheck =
        "web search: the second question resolves the same pinned retrieval and synthesis models as the first"

    private static func checkOwnLoads(_ seam: OwnLoadsSeam, root: URL, _ reporter: SelfTestReporter) {
        print("--- ModelManager's own loads, resolved with no live read (the main thread right after a load) ---")
        let ttl = 120
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        let machine = ScriptedLMStudio()
        let manager = seam.makeManager { clock }
        let probe = FactsProbe()
        let store = makeStore(root: root, models: withSmall,
                              provider: provider(seam, manager: manager, machine: machine, probe: probe))
        let deps = machine.dependencies

        let coderReady = manager.ensureReady(coderID, ttlOverrideSeconds: ttl, dependencies: deps)
        let mailReady = manager.ensureReady(mailID, ttlOverrideSeconds: ttl, dependencies: deps)
        reporter.record("scripted: ModelManager loads both models and wired memory now holds them",
                        coderReady == .ready && mailReady == .ready && machine.wired == bothResidentWired,
                        "loads=\(machine.loads)")

        let cleanup = store.resolveRoute(.cleanupL1)
        reporter.record(ownCoderPinnedCheck, isPinned(cleanup, on: coderID), cleanup.logToken)
        let retrieval = store.resolveLocalRoute(.searchRetrieval)
        reporter.record("after ModelManager loaded both: search retrieval stays pinned on the coder model",
                        isPinned(retrieval, on: coderID), retrieval.logToken)
        let email = store.resolveRoute(.email)
        reporter.record("after ModelManager loaded both: email stays pinned on the mail model",
                        isPinned(email, on: mailID), email.logToken)
        let synth = store.resolveRoute(.searchLocalSynth)
        reporter.record("after ModelManager loaded both: search synthesis stays pinned on the mail model",
                        isPinned(synth, on: mailID), synth.logToken)

        print("--- the idle window: a use restarts it, and an unused model's ends ---")
        clock = clock.addingTimeInterval(100)
        _ = manager.ensureReady(coderID, ttlOverrideSeconds: ttl, dependencies: deps)   // a use of the resident
        clock = clock.addingTimeInterval(50)   // coder used 50 s ago, mail 150 s ago, window 120 s
        let usedCleanup = store.resolveRoute(.cleanupL1)
        reporter.record("a use restarts the window: 150 s after its load the coder model is still exempt",
                        isPinned(usedCleanup, on: coderID), usedCleanup.logToken)
        let expiredEmail = store.resolveRoute(.email)
        let mailStillExempt = probe.facts?.isResident(lm(mailID)) ?? true
        // Charged again it does not fit, so email steps down (to the coder model, resident and free).
        reporter.record(ownExpiryCheck,
                        !mailStillExempt && !isPinned(expiredEmail, on: mailID)
                            && expiredEmail.upgradeOffer?.preferredModelID == mailID,
                        expiredEmail.logToken)

        print("--- ViddyDictate's own unload ---")
        _ = store.resolveRoute(.cleanupL1)
        let before = probe.facts?.isResident(lm(coderID)) ?? false
        manager.unload(lm(coderID), dependencies: deps)
        _ = store.resolveRoute(.cleanupL1)
        let after = probe.facts?.isResident(lm(coderID)) ?? true
        reporter.record("after ViddyDictate unloads the coder model, routing no longer counts it resident",
                        before && !after && !machine.residents.contains { $0.identifier == coderID },
                        "before=\(before) after=\(after)")
        _ = manager.ensureReady(coderID, ttlOverrideSeconds: ttl, dependencies: deps)
        manager.unloadAll(in: .lmStudio, unloadAll: { _ in machine.residents.forEach {
            machine.evictBehindOurBack($0.identifier, wiredFalls: true)
        } })
        _ = store.resolveRoute(.cleanupL1)
        reporter.record("Unload all forgets every LM Studio record",
                        manager.recentLoads.residentRefs(backends: [.lmStudio]).isEmpty
                            && probe.facts?.isResident(lm(coderID)) == false)
    }

    /// Option+L's route sequence, twice, the way `SearchClient.localAnswerSync` runs it: retrieval resolves
    /// (`retrievalModelRef`, the real seam) and is made ready, then synthesis resolves and is made ready. On
    /// the Mac the first question answered and the second stepped retrieval down; here it must not.
    private static func checkSearchSequence(_ seam: OwnLoadsSeam, root: URL, _ reporter: SelfTestReporter) {
        print("--- web search: retrieval, synthesis, then a second question (scripted, main thread) ---")
        let machine = ScriptedLMStudio()
        let manager = seam.makeManager { Date(timeIntervalSince1970: 1_900_000_000) }
        let probe = FactsProbe()
        let store = makeStore(root: root, models: withSmall,
                              provider: provider(seam, manager: manager, machine: machine, probe: probe))
        let deps = machine.dependencies

        func ask() -> (retrieval: LocalModelRef, synth: LLMRouteResolution, ready: Bool) {
            let retrieval = SearchClient.retrievalModelRef(store: store)
            let retrievalReady = manager.ensureReady(retrieval, dependencies: deps)
            let synth = store.resolveRoute(.searchLocalSynth, fallback: .local(Settings.searchSynthModel))
            let synthReady = synth.bundle.map { manager.ensureReady($0.localRef, dependencies: deps) }
            return (retrieval, synth, retrievalReady == .ready && synthReady == .ready)
        }
        let first = ask()
        reporter.record("web search: the first question runs the pinned coder retrieval and mail synthesis",
                        first.retrieval == lm(coderID) && isPinned(first.synth, on: mailID) && first.ready,
                        "retrieval=\(first.retrieval.modelID) synth=\(first.synth.logToken)")
        let second = ask()
        reporter.record(searchSecondQuestionCheck,
                        second.retrieval == first.retrieval && isPinned(second.synth, on: mailID) && second.ready,
                        "retrieval=\(second.retrieval.modelID) synth=\(second.synth.logToken) loads=\(machine.loads)")
        reporter.record("web search: the second question loads nothing new",
                        machine.loads == [coderID, mailID], "loads=\(machine.loads)")
    }

    /// A record that outlived its model is safe: routing picks the model, `ModelManager` finds it absent,
    /// budgets it as a cold load, and refuses past the budget; the same read ends the record.
    private static func checkStaleEntryIsSafe(root: URL, _ reporter: SelfTestReporter) {
        print("--- a stale record is safe: ModelManager stays the authority ---")
        let machine = ScriptedLMStudio()
        let manager = ModelManager(clock: { Date(timeIntervalSince1970: 1_900_000_000) })
        let probe = FactsProbe()
        let store = makeStore(root: root, models: withSmall,
                              provider: provider(realSeam, manager: manager, machine: machine, probe: probe))
        let deps = machine.dependencies
        _ = manager.ensureReady(coderID, dependencies: deps)
        _ = manager.ensureReady(mailID, dependencies: deps)
        // LM Studio drops the mail model on its own, and something else takes its wired memory; the coder
        // model is mid-request, so the one eviction pass has nothing it may unload.
        machine.evictBehindOurBack(mailID, wiredFalls: false)
        machine.setStatus(coderID, "generating")
        let stale = store.resolveRoute(.email)
        reporter.record("stale: routing still picks the mail model on the record's say-so",
                        isPinned(stale, on: mailID), stale.logToken)
        let refused = manager.ensureReady(mailID, dependencies: deps)
        reporter.record("stale: ModelManager budgets the absent model as a cold load and refuses past the budget",
                        refused == .capacityRefused(.overBudget) && machine.loads == [coderID, mailID]
                            && machine.wired == bothResidentWired,
                        "\(refused) loads=\(machine.loads)")
        let healed = store.resolveRoute(.email)
        reporter.record("stale: the read that found it absent ends the record, so email steps down next time",
                        probe.facts?.isResident(lm(mailID)) == false && !isPinned(healed, on: mailID)
                            && healed.upgradeOffer?.preferredModelID == mailID,
                        healed.logToken)
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(root: URL, _ reporter: SelfTestReporter) {
        // (1) 1.1.0: the facts know nothing about residency, so live wired + size x 1.15 for every model.
        let doubleCounting: ProviderFactory = { wired, _ in
            { models in
                guard let models, !models.isEmpty else { return nil }
                return ModelsPowerSettingsStore.capacityFacts(models: models, wiredBytes: wired, budgetBytes: budget)
            }
        }
        requireCaught(reporter, mutant: "double-counting fit (a resident model charged again)", by: coderPinnedCheck) {
            checkContract(doubleCounting, root: root, $0)
        }
        requireCaught(reporter, mutant: "double-counting fit (a resident model charged again)", by: mailPinnedCheck) {
            checkContract(doubleCounting, root: root, $0)
        }

        // (2) A resident id counts in every app.
        let backendBlind: ProviderFactory = { wired, residents in
            let blind = Set(residents.flatMap { ref in
                LocalBackendID.allCases.map { LocalModelRef(backend: $0, modelID: ref.modelID) }
            })
            return realProvider(wired, blind)
        }
        requireCaught(reporter, mutant: "backend-blind resident set", by: backendAwareCheck) {
            checkContract(backendBlind, root: root, $0)
        }

        // (3) ffa0a3c: routing reads only the live resident set, never ModelManager's record.
        let cacheOnly = OwnLoadsSeam(
            makeManager: realSeam.makeManager,
            residentRefs: { _, cache, backends, wired in cache.residentRefs(backends: backends, wiredBytes: wired) })
        requireCaught(reporter, mutant: "live read only, ModelManager's record not consulted",
                      by: ownCoderPinnedCheck) {
            checkOwnLoads(cacheOnly, root: root, $0)
        }
        requireCaught(reporter, mutant: "live read only, ModelManager's record not consulted",
                      by: searchSecondQuestionCheck) {
            checkSearchSequence(cacheOnly, root: root, $0)
        }

        // (4) A record that never expires: its clock never moves past the load, so every entry stays resident.
        let neverExpires = OwnLoadsSeam(
            makeManager: { _ in
                let frozen = Date(timeIntervalSince1970: 1_900_000_000)
                return ModelManager(clock: { frozen })
            },
            residentRefs: realSeam.residentRefs)
        requireCaught(reporter, mutant: "record with no expiry", by: ownExpiryCheck) {
            checkOwnLoads(neverExpires, root: root, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`) and records on
    /// the real reporter whether the named assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
