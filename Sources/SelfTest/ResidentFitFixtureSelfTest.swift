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
/// Negative controls, each of which must be caught:
/// (1) the double-counting fit (1.1.0's code): the capacity facts carry no resident set;
/// (2) a backend-blind resident set: a model resident in ONE app makes the same id free in the other.
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
