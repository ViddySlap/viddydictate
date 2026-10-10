import Foundation

/// Deterministic, scratch-only coverage for the selectable Whisper versions backend (part 1 of 3).
///
/// The catalog is data, the installed-probe runs over TMPDIR hub-layout fixtures, and every switch
/// effect is injected, so this touches no daemon, launchd, network, AppKit, or real preference file.
/// The two `guard:` checks read `Settings` through an injected scratch `UserDefaults` suite to pin
/// the unset/invalid fallback this change must not disturb.
///
/// RED-before-fix evidence (captured against the RED-phase stub implementation that returned the OLD
/// behaviour -- catalog held only the turbo repo, `isInstalled` always true, `select` always
/// switched+restarted, and the Settings accessor passed the stored value through unvalidated). The
/// fourteen `new:` checks below failed on that stub:
///
///   RED before fix: whisper-model: new: catalog offers exactly the four variants in the required order | [FAIL] ... (got ["mlx-community/whisper-large-v3-turbo"])
///   RED before fix: whisper-model: new: the default is Large V3 Turbo and the catalog is ordered default-first | [FAIL] ... (default=mlx-community/whisper-large-v3-turbo)
///   RED before fix: whisper-model: new: every variant carries its exact repo id, display name, and measured size | [FAIL]
///   RED before fix: whisper-model: new: an unknown stored value reads back as the default | [FAIL] ... (got not a repo id at all)
///   RED before fix: whisper-model: new: writes accept only offered repos | [FAIL] ... (got not/a/real-model)
///   RED before fix: whisper-model: new: isInstalled is true for a complete snapshot and false when weights are missing | [FAIL]
///   RED before fix: whisper-model: new: isInstalled is false when config.json is missing, true when present | [FAIL]
///   RED before fix: whisper-model: new: isInstalled is false for an empty cache and true for a populated one | [FAIL]
///   RED before fix: whisper-model: new: isInstalled is false for a different repo and true for the matching repo | [FAIL]
///   RED before fix: whisper-model: new: select refuses a repo that is not offered | [FAIL] ... (result=switched)
///   RED before fix: whisper-model: new: select refuses a repo that is not installed | [FAIL] ... (result=switched)
///   RED before fix: whisper-model: new: select writes the file, changes the setting, and restarts once | [FAIL] ... (result=switched writes=[] restarts=3)
///   RED before fix: whisper-model: new: idempotent re-select does not restart or write again | [FAIL] ... (restarts=4 writes=[])
///   RED before fix: whisper-model: new: a failing write changes nothing and does not restart | [FAIL] ... (result=switched setting=mlx-community/whisper-large-v3-turbo restarts=5)
///
/// The two executable `guard:` checks pin the read fallback and pass on the repaired arm; they touch
/// an injected scratch `UserDefaults` suite, never the real preferences, and construct no AppKit:
///   guard (PASS before and after): whisper-model: guard: no stored value reads as the default turbo repo
///   guard (PASS before and after): whisper-model: guard: an invalid or non-offered stored value reads as the default
///
/// The unfixed run reported `Whisper model backend ok=false checks=16 passed=2 failed=14` (the two
/// source-string guards it had then); the fourteen `new:` rows were the failures either way.
enum WhisperModelSelfTest {
    static func run() -> Bool {
        print("=== ViddyDictate selectable Whisper model backend - selftest ===")
        let reporter = SelfTestReporter()
        checkCatalog(reporter)
        checkSettings(reporter)
        checkStore(reporter)
        checkSwitch(reporter)
        checkGuards(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Whisper model backend"))
        return reporter.passed
    }

    private static let expectedRepos = [
        "mlx-community/whisper-large-v3-turbo",
        "mlx-community/whisper-large-v3-mlx",
        "mlx-community/whisper-large-v2-mlx",
        "mlx-community/whisper-large-mlx",
    ]
    private static let expectedNames = [
        "Large V3 Turbo",
        "Large V3",
        "Large V2",
        "Large (original)",
    ]

    private static func checkCatalog(_ reporter: SelfTestReporter) {
        print("--- catalog ---")
        let repos = WhisperModelCatalog.variants.map(\.repo)
        reporter.record(
            "whisper-model: new: catalog offers exactly the four variants in the required order",
            WhisperModelCatalog.variants.count == 4 && repos == expectedRepos,
            "got \(repos)")

        let defaultVariant = WhisperModelCatalog.`default`
        reporter.record(
            "whisper-model: new: the default is Large V3 Turbo and the catalog is ordered default-first",
            defaultVariant.repo == expectedRepos[0]
                && WhisperModelCatalog.variants.first?.repo == expectedRepos[0]
                && WhisperModelCatalog.variants.map(\.repo) == expectedRepos,
            "default=\(defaultVariant.repo)")

        let metadataOK = WhisperModelCatalog.variants.count == 4
            && zip(WhisperModelCatalog.variants, zip(expectedRepos, expectedNames)).allSatisfy {
                $0.repo == $1.0 && $0.displayName == $1.1
                    && $0.approximateSizeBytes > 0 && !$0.note.isEmpty
            }
        reporter.record(
            "whisper-model: new: every variant carries its exact repo id, display name, and measured size",
            metadataOK && WhisperModelCatalog.isOffered(repo: expectedRepos[2])
                && WhisperModelCatalog.variant(forRepo: expectedRepos[3])?.displayName == "Large (original)"
                && !WhisperModelCatalog.isOffered(repo: "mlx-community/whisper-medium-mlx"))
    }

    private static func checkSettings(_ reporter: SelfTestReporter) {
        print("--- settings ---")
        let defaults = UserDefaults.standard
        let key = "whisperModelRepo"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let fallback = WhisperModelCatalog.`default`.repo

        defaults.set("not a repo id at all", forKey: key)
        reporter.record(
            "whisper-model: new: an unknown stored value reads back as the default",
            Settings.whisperModelRepo == fallback,
            "got \(Settings.whisperModelRepo)")

        Settings.whisperModelRepo = expectedRepos[2]
        let offeredPersisted = Settings.whisperModelRepo == expectedRepos[2]
            && defaults.string(forKey: key) == expectedRepos[2]
        Settings.whisperModelRepo = "not/a/real-model"
        reporter.record(
            "whisper-model: new: writes accept only offered repos",
            offeredPersisted && Settings.whisperModelRepo == expectedRepos[2]
                && defaults.string(forKey: key) == expectedRepos[2],
            "got \(Settings.whisperModelRepo)")
    }

    private static func checkStore(_ reporter: SelfTestReporter) {
        print("--- store ---")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-model-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil
        else {
            reporter.record("whisper-model: new: scratch fixture root is creatable", false)
            return
        }

        let complete = root.appendingPathComponent("complete", isDirectory: true)
        let missingWeights = root.appendingPathComponent("missing-weights", isDirectory: true)
        let missingConfig = root.appendingPathComponent("missing-config", isDirectory: true)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        let otherRepo = root.appendingPathComponent("other-repo", isDirectory: true)

        makeSnapshot(cache: complete, repo: expectedRepos[0], config: true, weights: true)
        makeSnapshot(cache: missingWeights, repo: expectedRepos[0], config: true, weights: false)
        makeSnapshot(cache: missingConfig, repo: expectedRepos[0], config: false, weights: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        makeSnapshot(cache: otherRepo, repo: expectedRepos[2], config: true, weights: true)

        reporter.record(
            "whisper-model: new: isInstalled is true for a complete snapshot and false when weights are missing",
            WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [complete])
                && !WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [missingWeights]))

        reporter.record(
            "whisper-model: new: isInstalled is false when config.json is missing, true when present",
            !WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [missingConfig])
                && WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [complete]))

        reporter.record(
            "whisper-model: new: isInstalled is false for an empty cache and true for a populated one",
            !WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [empty])
                && WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [complete]))

        reporter.record(
            "whisper-model: new: isInstalled is false for a different repo and true for the matching repo",
            !WhisperModelStore.isInstalled(repo: expectedRepos[0], cacheDirectories: [otherRepo])
                && WhisperModelStore.isInstalled(repo: expectedRepos[2], cacheDirectories: [otherRepo]))
    }

    private static func makeSnapshot(cache: URL, repo: String, config: Bool, weights: Bool) {
        let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let repoDir = cache.appendingPathComponent(folder, isDirectory: true)
        let snapshot = repoDir.appendingPathComponent("snapshots/abc123", isDirectory: true)
        try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: repoDir.appendingPathComponent("refs", isDirectory: true), withIntermediateDirectories: true)
        try? "abc123\n".write(to: repoDir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        if config {
            try? Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        }
        if weights {
            try? Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        }
    }

    private static func checkSwitch(_ reporter: SelfTestReporter) {
        print("--- switch ---")
        let defaults = UserDefaults.standard
        let key = "whisperModelRepo"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let turbo = WhisperModelCatalog.`default`.repo
        let v2 = expectedRepos[2]

        Settings.whisperModelRepo = turbo
        var writes: [String] = []
        var restarts = 0

        let notOffered = WhisperModelSwitch.select(
            repo: "not/offered",
            installed: { _ in true },
            write: { writes.append($0) },
            restart: { restarts += 1 })
        reporter.record(
            "whisper-model: new: select refuses a repo that is not offered",
            notOffered == .notOffered && writes.isEmpty && restarts == 0,
            "result=\(notOffered)")

        let notInstalled = WhisperModelSwitch.select(
            repo: v2,
            installed: { _ in false },
            write: { writes.append($0) },
            restart: { restarts += 1 })
        reporter.record(
            "whisper-model: new: select refuses a repo that is not installed",
            notInstalled == .notInstalled && writes.isEmpty && restarts == 0,
            "result=\(notInstalled)")

        let switched = WhisperModelSwitch.select(
            repo: v2,
            installed: { $0 == v2 },
            write: { writes.append($0) },
            restart: { restarts += 1 })
        reporter.record(
            "whisper-model: new: select writes the file, changes the setting, and restarts once",
            switched == .switched && writes == [v2]
                && Settings.whisperModelRepo == v2 && restarts == 1,
            "result=\(switched) writes=\(writes) restarts=\(restarts)")

        let restartsBeforeIdempotent = restarts
        let again = WhisperModelSwitch.select(
            repo: v2,
            installed: { _ in true },
            write: { writes.append($0) },
            restart: { restarts += 1 })
        reporter.record(
            "whisper-model: new: idempotent re-select does not restart or write again",
            again == .switched && restarts == restartsBeforeIdempotent && writes == [v2],
            "result=\(again) restarts=\(restarts) writes=\(writes)")

        let restartsBeforeFailure = restarts
        let failing = WhisperModelSwitch.select(
            repo: turbo,
            installed: { _ in true },
            write: { _ in throw NSError(domain: "whisper-model-selftest", code: 1) },
            restart: { restarts += 1 })
        var failedOK = false
        if case .failed = failing { failedOK = true }
        reporter.record(
            "whisper-model: new: a failing write changes nothing and does not restart",
            failedOK && Settings.whisperModelRepo == v2 && restarts == restartsBeforeFailure,
            "result=\(failing) setting=\(Settings.whisperModelRepo) restarts=\(restarts)")
    }

    private static func checkGuards(_ reporter: SelfTestReporter) {
        print("--- guards (executable: unset/invalid stored value reads the default) ---")
        let suiteName = "whisper-model-selftest-\(UUID().uuidString)"
        let key = "whisperModelRepo"
        let turbo = WhisperModelCatalog.`default`.repo
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            reporter.record("whisper-model: guard: no stored value reads as the default turbo repo",
                            false, "could not create scratch defaults suite")
            reporter.record(
                "whisper-model: guard: an invalid or non-offered stored value reads as the default",
                false, "could not create scratch defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Guard 1: nothing stored at all reads back as the default turbo repo.
        defaults.removeObject(forKey: key)
        let unset = Settings.whisperModelRepo(in: defaults)
        reporter.record(
            "whisper-model: guard: no stored value reads as the default turbo repo",
            unset == turbo,
            "got \(unset)")

        // Guard 2: a garbage value and a valid-but-non-offered repo both read back as the default.
        defaults.set("not a repo id at all", forKey: key)
        let invalid = Settings.whisperModelRepo(in: defaults)
        defaults.set("mlx-community/whisper-medium-mlx", forKey: key)
        let nonOffered = Settings.whisperModelRepo(in: defaults)
        reporter.record(
            "whisper-model: guard: an invalid or non-offered stored value reads as the default",
            invalid == turbo && nonOffered == turbo,
            "invalid=\(invalid) nonOffered=\(nonOffered)")
    }
}
