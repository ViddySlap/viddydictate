import Foundation

/// `--local-backend-codec-selftest` (Ollama lane S1): the local-backend identity types and the bundle's new
/// `localBackend` field, over offline fixtures. No LM Studio, no Ollama, no preferences; the only files are
/// under a fresh scratch directory.
///
/// What it holds the codec to:
/// 1. a 1.1.0-shaped `models-power.json`, written by the REAL `ModelsPowerSettingsStore` with its real
///    encoder (pretty-printed, sorted keys), decodes and re-encodes byte-identical, and the real store
///    reopens it without rewriting it;
/// 2. `"localBackend":"ollama"` decodes to `.ollama` and re-encodes with the key;
/// 3. an unknown backend (`"vllm"`) decodes to nil and the rest of the bundle survives;
/// 4. a nil backend resolves to LM Studio;
/// 5. two refs with one model id on two backends are different identities;
/// 6. `LMStudioBackend` maps an injected LM Studio catalog and resident snapshot into the neutral types.
///
/// The gate carries its own negative controls, in the house style of the S2 gates: the codec contract is
/// run again against three deliberately broken stand-ins (nil encoded as `null`, an unknown backend that
/// fails the whole bundle, identity keyed by model id alone), and the gate FAILS unless the named assertion
/// aimed at each one reports it.
enum LocalBackendCodecFixtureSelfTest {
    /// The three seams a mutant may replace. The real subject is the production `LLMProviderBundle` codec
    /// and `LocalModelRef`'s own `Hashable`.
    private struct CodecSubject {
        let decodeBundle: (Decoder) throws -> LLMProviderBundle
        let encodeBundle: (LLMProviderBundle, Encoder) throws -> Void
        let identity: (LocalModelRef) -> AnyHashable
    }

    private static let realSubject = CodecSubject(
        decodeBundle: { try LLMProviderBundle(from: $0) },
        encodeBundle: { try $0.encode(to: $1) },
        identity: { AnyHashable($0) })

    /// The subject the mirror types below code through. `Decodable.init(from:)` cannot take an argument, so
    /// the contract sets this for the length of one run and restores it. Self-tests are single-threaded.
    private static var activeSubject = realSubject

    /// A bundle coded through `activeSubject` rather than directly, so a mutant codec can be swapped in
    /// underneath an otherwise ordinary `Codable` tree.
    private struct SubjectBundle: Codable {
        let bundle: LLMProviderBundle

        init(_ bundle: LLMProviderBundle) { self.bundle = bundle }

        init(from decoder: Decoder) throws {
            bundle = try LocalBackendCodecFixtureSelfTest.activeSubject.decodeBundle(decoder)
        }

        func encode(to encoder: Encoder) throws {
            try LocalBackendCodecFixtureSelfTest.activeSubject.encodeBundle(bundle, encoder)
        }
    }

    /// Field-for-field mirrors of the store's private `ModelsPowerSnapshot` / `ModelsPowerRouteState`, with
    /// every bundle coded through the subject. If the real snapshot ever gains a field these lack, the
    /// byte-identical round trip loses it and this gate goes red, so the mirror cannot drift silently.
    private struct MirrorRouteState: Codable {
        var selectedProvider: LLMProvider
        var bundles: [String: SubjectBundle]
        var promptOverrides: [String: [String: String]]
    }

    private struct MirrorSnapshot: Codable {
        var version: Int
        var routes: [String: MirrorRouteState]
        var codexDefaults: [String: SubjectBundle]?

        var allBundles: [LLMProviderBundle] {
            routes.values.flatMap { $0.bundles.values.map(\.bundle) }
                + (codexDefaults ?? [:]).values.map(\.bundle)
        }
    }

    private enum MutantKey: String, CodingKey {
        case localBackend
    }

    // Assertion names the negative controls look up. Named once so a rename cannot silently detach a
    // mutant from the check that is supposed to catch it.
    private static let legacyRoundTripCheck =
        "a 1.1.0-shaped models-power.json decodes and re-encodes BYTE-IDENTICAL"
    private static let unknownBackendCheck =
        "an unknown localBackend (\"vllm\") decodes to nil and the rest of the bundle survives"
    private static let refIdentityCheck =
        "one model id on two backends is two identities (unequal, and two members of a Set)"

    static func run() -> Bool {
        print("=== local-backend identity + bundle codec fixture selftest ===")
        let reporter = SelfTestReporter()

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-local-backend-codec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch {
            reporter.record("scratch root", false, error.localizedDescription)
            return reporter.passed
        }

        let storeBytes = checkRealStore(root: root, reporter)
        print("--- codec contract (real LLMProviderBundle codec, real LocalModelRef identity) ---")
        checkCodecContract(realSubject, storeBytes: storeBytes, reporter)
        checkResolvedBackend(reporter)
        checkLMStudioAdapter(reporter)
        checkNegativeControls(storeBytes: storeBytes, reporter)

        print(reporter.passed
            ? "[local-backend-codec-selftest] PASS"
            : "[local-backend-codec-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - Fixtures

    /// A new-format Local bundle on Ollama, in the exact compact sorted-key form `JSONEncoder` writes, so
    /// the re-encode can be compared byte for byte. The hash is a literal, never 64 hex characters.
    private static let ollamaBundleJSON =
        #"{"basePromptHash":"fixture-prompt-hash","basePromptVersion":"cleanup-l1-v1","#
        + #""envelopeVersion":"local-transcript-markers-v1","localBackend":"ollama","#
        + #""modelID":"fixture-ollama-model:8b","provider":"local","version":2}"#

    /// A bundle naming a backend this build does not know, as a newer build or a hand edit could write it.
    private static let unknownBackendBundleJSON =
        #"{"basePromptVersion":"email-v1","effort":"low","localBackend":"vllm","#
        + #""modelID":"fixture-future-backend-model","provider":"local","version":2}"#

    /// `lms ls --llm --json` rows: vision by `type` only, vision by the boolean flag only, a plain text
    /// model, and an embedding row the catalog itself drops. Every size is distinct.
    private static let lmStudioCatalogJSON = """
    [
      {"type":"vlm","modelKey":"fixture-vlm-by-type","displayName":"Fixture VLM By Type","sizeBytes":3141592653},
      {"type":"llm","modelKey":"fixture-llm-with-vision-flag","displayName":"Fixture Flagged",
       "sizeBytes":2718281828,"vision":true},
      {"type":"llm","modelKey":"fixture-text-only","displayName":"Fixture Text","sizeBytes":1414213562,
       "vision":false},
      {"type":"embedding","modelKey":"fixture-embedder","displayName":"Fixture Embedder","sizeBytes":577215664}
    ]
    """

    // MARK: - The real store (produces the 1.1.0-shaped fixture)

    /// Writes a realistic models-power.json through the real store: seeded tested defaults, a Claude
    /// selection, a user-picked Local model, a prompt override and a custom route, all through the store's
    /// public mutations. Returns the bytes of its last write. The store and bundle sources are unchanged
    /// since the v1.1.0 tag apart from this slice's field, so these bytes are exactly what 1.1.0 writes.
    private static func checkRealStore(root: URL, _ reporter: SelfTestReporter) -> Data? {
        print("--- the real ModelsPowerSettingsStore codec ---")
        let url = root.appendingPathComponent("models-power.json", isDirectory: false)
        var writes: [Data] = []
        let store = ModelsPowerSettingsStore(url: url, writer: { data, destination in
            writes.append(data)
            try ModelsPowerSettingsStore.atomicWriter(data, destination)
        })
        let custom = LLMRouteID.custom("fixture-custom-route")
        do {
            try store.selectProvider(.claude, for: .email)
            try store.setSelectedBundle(.local("fixture-user-picked-local"), for: .cleanupL2)
            try store.setPromptOverride("Fixture override prompt.", for: .cleanupL3, provider: .local)
            try store.syncCustomRoutes([custom: .local("fixture-custom-local")])
        } catch {
            reporter.record("the real store accepts the fixture mutations", false, "\(error)")
            return nil
        }
        guard let stored = writes.last else {
            reporter.record("the real store wrote a models-power.json", false)
            return nil
        }
        let text = String(decoding: stored, as: UTF8.self)
        reporter.record(
            "the real store still writes the 1.1.0 shape: no localBackend key anywhere",
            !text.contains("localBackend") && text.contains("\"bundles\"") && text.contains("\"codexDefaults\""),
            "\(stored.count) bytes over \(writes.count) writes")

        var reopenWrites: [Data] = []
        let reopened = ModelsPowerSettingsStore(url: url, writer: { data, destination in
            reopenWrites.append(data)
            try ModelsPowerSettingsStore.atomicWriter(data, destination)
        })
        let picked = reopened.selectedBundle(for: .cleanupL2)
        reporter.record(
            "the real store reopens that file without rewriting it, and a pre-backend Local bundle is LM Studio",
            reopenWrites.isEmpty && picked.modelID == "fixture-user-picked-local"
                && picked.localBackend == nil && picked.resolvedLocalBackend == .lmStudio
                && reopened.selectedBundle(for: .email).provider == .claude,
            "rewrites=\(reopenWrites.count) picked=\(picked.modelID)")

        // A backend pin must survive the store's own canonicalization (withTestedMetadata copies the bundle
        // rather than rebuilding it) and a reopen from disk.
        let pinnedURL = root.appendingPathComponent("models-power-pinned.json", isDirectory: false)
        let pinnedStore = ModelsPowerSettingsStore(url: pinnedURL)
        var pinnedWrite = false
        do {
            try pinnedStore.setSelectedBundle(
                LLMProviderBundle(provider: .local, modelID: "fixture-ollama-model:8b", localBackend: .ollama),
                for: .cleanupL1)
            pinnedWrite = true
        } catch {
            reporter.record("the real store accepts an Ollama-pinned Local bundle", false, "\(error)")
        }
        if pinnedWrite {
            let reread = ModelsPowerSettingsStore(url: pinnedURL).selectedBundle(for: .cleanupL1)
            reporter.record(
                "an Ollama pin survives the store's canonicalization and a reopen from disk",
                reread.localBackend == .ollama && reread.modelID == "fixture-ollama-model:8b"
                    && reread.basePromptVersion == "cleanup-l1-v1",
                "localBackend=\(reread.localBackend?.rawValue ?? "nil")")
        }
        return stored
    }

    // MARK: - Codec contract (the part the mutants are run against)

    private static func checkCodecContract(_ subject: CodecSubject, storeBytes: Data?,
                                           _ reporter: SelfTestReporter) {
        let previous = activeSubject
        activeSubject = subject
        defer { activeSubject = previous }

        // (1) The store's own bytes, through the store's own encoder settings.
        var mirror: MirrorSnapshot?
        var reencoded: Data?
        if let storeBytes {
            mirror = try? JSONDecoder().decode(MirrorSnapshot.self, from: storeBytes)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            reencoded = mirror.flatMap { try? encoder.encode($0) }
        }
        reporter.record(
            legacyRoundTripCheck,
            storeBytes != nil && reencoded == storeBytes,
            "stored=\(storeBytes?.count ?? -1) reencoded=\(reencoded?.count ?? -1)")
        let bundles = mirror?.allBundles ?? []
        reporter.record(
            "every bundle in that file decodes with localBackend nil (absent key)",
            bundles.count > 20 && bundles.allSatisfy { $0.localBackend == nil },
            "bundles=\(bundles.count)")

        // (2) A bundle pinned to Ollama.
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys]
        let ollama = try? JSONDecoder().decode(SubjectBundle.self, from: Data(ollamaBundleJSON.utf8)).bundle
        let ollamaBytes = ollama.flatMap { try? compact.encode(SubjectBundle($0)) }
        reporter.record(
            "\"localBackend\":\"ollama\" decodes to .ollama and re-encodes with the key, byte-identical",
            ollama?.localBackend == .ollama && ollama?.modelID == "fixture-ollama-model:8b"
                && ollamaBytes == Data(ollamaBundleJSON.utf8),
            ollamaBytes.map { String(decoding: $0, as: UTF8.self) } ?? "nil")

        // (3) A backend from the future.
        let future = try? JSONDecoder().decode(
            SubjectBundle.self, from: Data(unknownBackendBundleJSON.utf8)).bundle
        reporter.record(
            unknownBackendCheck,
            future == LLMProviderBundle(
                provider: .local, modelID: "fixture-future-backend-model", effort: "low",
                basePromptVersion: "email-v1"),
            future.map { "model=\($0.modelID) backend=\($0.localBackend?.rawValue ?? "nil")" }
                ?? "the whole bundle failed to decode")
        let wrongType = try? JSONDecoder().decode(SubjectBundle.self, from: Data(
            #"{"localBackend":7,"modelID":"fixture-wrong-type","provider":"local","version":2}"#.utf8)).bundle
        reporter.record(
            "a localBackend of the wrong JSON type also decodes to nil without failing the bundle",
            wrongType?.localBackend == nil && wrongType?.modelID == "fixture-wrong-type")

        // (5) Identity is the pair.
        let onStudio = LocalModelRef(backend: .lmStudio, modelID: "shared-id-on-both")
        let onOllama = LocalModelRef(backend: .ollama, modelID: "shared-id-on-both")
        let keys: Set<AnyHashable> = [subject.identity(onStudio), subject.identity(onOllama)]
        reporter.record(
            refIdentityCheck,
            subject.identity(onStudio) != subject.identity(onOllama) && keys.count == 2)
    }

    // MARK: - resolvedLocalBackend (4)

    private static func checkResolvedBackend(_ reporter: SelfTestReporter) {
        print("--- resolvedLocalBackend + identity type ---")
        reporter.record(
            "a nil localBackend resolves to LM Studio; an explicit one resolves to itself",
            LLMProviderBundle.local("fixture-any").resolvedLocalBackend == .lmStudio
                && LLMProviderBundle(provider: .local, modelID: "fixture-any", localBackend: .ollama)
                    .resolvedLocalBackend == .ollama)
        let onStudio = LocalModelRef(backend: .lmStudio, modelID: "shared-id-on-both")
        let onOllama = LocalModelRef(backend: .ollama, modelID: "shared-id-on-both")
        reporter.record(
            "LocalModelRef's own Equatable and Hashable keep the two apart",
            onStudio != onOllama && Set([onStudio, onOllama, onStudio]).count == 2)
        reporter.record(
            "backend display names and the closed case list",
            LocalBackendID.lmStudio.displayName == "LM Studio" && LocalBackendID.ollama.displayName == "Ollama"
                && LocalBackendID.allCases == [.lmStudio, .ollama])
    }

    // MARK: - LMStudioBackend (6)

    private static func checkLMStudioAdapter(_ reporter: SelfTestReporter) {
        print("--- LMStudioBackend over an injected catalog (no lms process) ---")
        let catalog = LMStudioModelCatalog.parseInstalled(Data(lmStudioCatalogJSON.utf8))
        var loads: [String] = []
        var unloads: [String] = []
        let residents = [
            ModelResidency.ResidentModel(
                identifier: "fixture-vlm-by-type", sizeBytes: 4_669_201_609,
                lastUsedTime: 1_790_799_000_000, status: "idle", ttlSeconds: 437),
            ModelResidency.ResidentModel(
                identifier: "fixture-text-only", sizeBytes: 2_502_907_875,
                lastUsedTime: nil, status: "generating", ttlSeconds: nil),
        ]
        let backend = LMStudioBackend(dependencies: LMStudioBackend.Dependencies(
            isInstalled: { true },
            serverResponds: { false },
            installedCatalog: { catalog },
            residentSnapshot: { residents },
            ensureLoaded: { model, ttl in loads.append("\(model)@\(ttl)"); return true },
            unload: { unloads.append($0) }))

        let installed = backend.installedModels()
        func row(_ id: String) -> LocalInstalledModel? { installed?.first { $0.ref.modelID == id } }
        let byType = row("fixture-vlm-by-type")
        let source = catalog?.first { $0.modelID == "fixture-vlm-by-type" }
        reporter.record(
            "an LM Studio vlm row maps to backend .lmStudio, vision from type == \"vlm\", size and label carried",
            backend.id == .lmStudio
                && byType?.ref == LocalModelRef(backend: .lmStudio, modelID: "fixture-vlm-by-type")
                && byType?.isVision == true && source?.visionFlag == nil
                && byType?.sizeBytes == 3_141_592_653 && byType?.label == source?.label
                && byType?.label.hasPrefix("Fixture VLM By Type") == true)
        reporter.record(
            "the boolean vision flag also counts; a plain text model is not vision; tools/thinking are unanswered",
            row("fixture-llm-with-vision-flag")?.isVision == true && row("fixture-text-only")?.isVision == false
                && installed?.allSatisfy { $0.supportsTools == nil && $0.supportsThinking == nil } == true)
        reporter.record(
            "the catalog's own filtering and order are kept (the embedding row is not a chat model)",
            installed?.map(\.ref.modelID)
                == ["fixture-vlm-by-type", "fixture-llm-with-vision-flag", "fixture-text-only"]
                && installed?.allSatisfy { $0.ref.backend == .lmStudio } == true)
        let unreadable = LMStudioBackend(dependencies: LMStudioBackend.Dependencies(
            isInstalled: { false }, serverResponds: { false }, installedCatalog: { nil },
            residentSnapshot: { nil }, ensureLoaded: { _, _ in true }, unload: { _ in }))
        reporter.record(
            "an unreadable catalog or snapshot stays nil, never an empty authoritative list",
            unreadable.installedModels() == nil && unreadable.residentModels() == nil
                && backend.isInstalled() && !backend.serverResponds())

        // 1,790,799,000,000 ms = 1,790,799,000 s; + 437 s TTL = 1,790,799,437 s.
        let resident = backend.residentModels()
        let idle = resident?.first
        let busy = resident?.dropFirst().first
        reporter.record(
            "an lms ps row maps bytes, last use (ms), idle state and expiry = last use + TTL",
            resident?.count == 2
                && idle?.ref == LocalModelRef(backend: .lmStudio, modelID: "fixture-vlm-by-type")
                && idle?.residentBytes == 4_669_201_609 && idle?.isIdle == true
                && idle?.lastUsed == Date(timeIntervalSince1970: 1_790_799_000)
                && idle?.expiresAt == Date(timeIntervalSince1970: 1_790_799_437)
                && idle?.contextLength == nil)
        reporter.record(
            "a generating row with no TTL has no last use and no expiry, and is not idle",
            busy?.ref.modelID == "fixture-text-only" && busy?.residentBytes == 2_502_907_875
                && busy?.isIdle == false && busy?.lastUsed == nil && busy?.expiresAt == nil)

        let ollamaRef = LocalModelRef(backend: .ollama, modelID: "fixture-vlm-by-type")
        let loadedOllama = backend.ensureLoaded(ollamaRef, ttlSeconds: 437, contextTokens: 8192)
        backend.unload(ollamaRef)
        reporter.record(
            "a ref naming Ollama is refused by the LM Studio backend: no load, no unload reaches lms",
            !loadedOllama && loads.isEmpty && unloads.isEmpty)
        let studioRef = LocalModelRef(backend: .lmStudio, modelID: "fixture-text-only")
        let loadedStudio = backend.ensureLoaded(studioRef, ttlSeconds: 437, contextTokens: 8192)
        backend.unload(studioRef)
        reporter.record(
            "an LM Studio ref reaches the injected load with its model id and TTL, and the unload with its id",
            loadedStudio && loads == ["fixture-text-only@437"] && unloads == ["fixture-text-only"])
    }

    // MARK: - Negative controls

    /// Each mutant replaces one seam of the real codec with the bug it is named for. The contract above must
    /// report that exact bug through the named assertion; if the mutant passes, this gate fails.
    private static func checkNegativeControls(storeBytes: Data?, _ reporter: SelfTestReporter) {
        // (a) `encode` instead of `encodeIfPresent`: every nil writes `"localBackend": null`, so every
        // existing file changes bytes on its next write.
        let nilAsNull = CodecSubject(
            decodeBundle: realSubject.decodeBundle,
            encodeBundle: { bundle, encoder in
                try bundle.encode(to: encoder)
                if bundle.localBackend == nil {
                    var extra = encoder.container(keyedBy: MutantKey.self)
                    try extra.encodeNil(forKey: .localBackend)
                }
            },
            identity: realSubject.identity)
        requireCaught(reporter, mutant: "encoder that writes a nil backend as null", by: legacyRoundTripCheck) {
            checkCodecContract(nilAsNull, storeBytes: storeBytes, $0)
        }

        // (b) A strict `decodeIfPresent(LocalBackendID.self, ...)`: one unknown backend bricks the bundle.
        let strictDecode = CodecSubject(
            decodeBundle: { decoder in
                let strict = try decoder.container(keyedBy: MutantKey.self)
                _ = try strict.decodeIfPresent(LocalBackendID.self, forKey: .localBackend)
                return try LLMProviderBundle(from: decoder)
            },
            encodeBundle: realSubject.encodeBundle,
            identity: realSubject.identity)
        requireCaught(reporter, mutant: "decoder that fails the whole bundle on an unknown backend",
                      by: unknownBackendCheck) {
            checkCodecContract(strictDecode, storeBytes: storeBytes, $0)
        }

        // (c) The bare-model-id identity the local path must never use again.
        let modelIDOnly = CodecSubject(
            decodeBundle: realSubject.decodeBundle,
            encodeBundle: realSubject.encodeBundle,
            identity: { AnyHashable($0.modelID) })
        requireCaught(reporter, mutant: "identity keyed by model id alone", by: refIdentityCheck) {
            checkCodecContract(modelIDOnly, storeBytes: storeBytes, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log never
    /// shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }
}
