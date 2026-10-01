import Foundation

/// Where the Codex CLI is found, how its snapshot is addressed, and how many snapshots stay on disk.
///
/// This exists because ChatGPT 26.924 moved the CLI into `Resources/codex-cli/CodexCLI.app` (plus a
/// `bin/codex` sh shim) and the single pinned path vanished, so every Codex route refused for two
/// weeks. Each rule below carries a negative control: the resolver that picks the shim, and the store
/// that is never pruned, must both be caught.
///
/// Offline and synthetic: fake ChatGPT.app layouts and fake snapshot stores under TMPDIR, and pure
/// receipt values. The real /Applications is never consulted; no Codex, ditto, or codesign runs.
enum CodexCLILocationSelfTest {
    static func run() -> Bool {
        print("=== Codex CLI location, snapshot addressing, and retention selftest ===")
        let reporter = SelfTestReporter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "viddydictate-codex-location-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: root.path) {
                try? CodexSnapshotRetention.removeSnapshotEntry(root)
            }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try checkResolution(root: root, reporter: reporter)
            try checkRetention(root: root, reporter: reporter)
            checkReceiptAddressing(reporter: reporter)
        } catch {
            reporter.record("selftest setup", false, String(describing: error))
        }
        print(reporter.summaryLine(prefix: "[codex-cli-location-selftest]"))
        print(reporter.passed
              ? "CODEX CLI LOCATION SELFTEST PASS" : "CODEX CLI LOCATION SELFTEST FAIL")
        return reporter.passed
    }

    // MARK: resolution

    private enum FakePart { case bundleExecutable, standalone, shim }

    private static func fakeChatGPT(_ parent: URL, _ name: String, _ parts: [FakePart]) throws -> String {
        let app = parent.appendingPathComponent("\(name)/ChatGPT.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        for part in parts {
            let relative: String
            let body: String
            switch part {
            case .bundleExecutable:
                relative = CodexCLILocation.cliBundleRelativePath + "/"
                    + CodexCLILocation.bundleExecutableRelativePath
                body = "synthetic bundle executable"
            case .standalone:
                relative = CodexCLILocation.standaloneRelativePath
                body = "synthetic standalone executable"
            case .shim:
                relative = CodexCLILocation.refusedShimRelativePath
                body = "#!/bin/sh\nexec \"$(dirname \"$0\")/../CodexCLI.app/Contents/MacOS/codex\" \"$@\"\n"
            }
            let file = app.appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        }
        return app.path
    }

    /// The 1.1.0-era mistake this suite must catch if anyone "fixes" a not-found by adding the shim.
    private static func shimAcceptingResolve(appRoot: String) -> CodexCLILocation.Resolution {
        let widened = CodexCLILocation.candidates(appRoot: appRoot) + [
            CodexCLILocation.Candidate(
                layout: .standalone,
                executable: appRoot + "/" + CodexCLILocation.refusedShimRelativePath,
                bundleRoot: nil),
        ]
        for candidate in widened where FileManager.default.isExecutableFile(atPath: candidate.executable) {
            return .found(candidate)
        }
        return .notFound(checked: widened.map(\.executable))
    }

    private static func checkResolution(root: URL, reporter: SelfTestReporter) throws {
        let check = reporter.check
        let both = try fakeChatGPT(root, "both", [.bundleExecutable, .standalone, .shim])
        let newOnly = try fakeChatGPT(root, "new", [.bundleExecutable, .shim])
        let oldOnly = try fakeChatGPT(root, "old", [.standalone])
        let shimOnly = try fakeChatGPT(root, "shim", [.shim])
        let empty = try fakeChatGPT(root, "empty", [])

        let expectedBundle = CodexCLILocation.Candidate(
            layout: .appBundle,
            executable: newOnly + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            bundleRoot: newOnly + "/Contents/Resources/codex-cli/CodexCLI.app")
        check("new layout: the CodexCLI.app executable is chosen, with its bundle root",
              CodexCLILocation.resolve(appRoot: newOnly) == .found(expectedBundle))
        check("both layouts present: the bundle wins over the old standalone path",
              CodexCLILocation.resolve(appRoot: both).candidate?.layout == .appBundle)
        check("old-only layout falls back to Resources/codex as a single-file candidate",
              CodexCLILocation.resolve(appRoot: oldOnly) == .found(.init(
                layout: .standalone, executable: oldOnly + "/Contents/Resources/codex",
                bundleRoot: nil)))
        let shimResolution = CodexCLILocation.resolve(appRoot: shimOnly)
        check("shim-only layout is refused and reports not found",
              shimResolution.candidate == nil
                && shimResolution == .notFound(checked: CodexCLILocation.candidates(appRoot: shimOnly)
                    .map(\.executable)))
        check("the shim is never among the checked candidates",
              !CodexCLILocation.candidates(appRoot: shimOnly).contains {
                  $0.executable.hasSuffix(CodexCLILocation.refusedShimRelativePath)
              })
        check("empty layout reports not found",
              CodexCLILocation.resolve(appRoot: empty).candidate == nil)
        check("mutant: a resolver that accepts the shim picks it in the shim-only layout",
              shimAcceptingResolve(appRoot: shimOnly).candidate?.executable
                == shimOnly + "/" + CodexCLILocation.refusedShimRelativePath)

        check("an explicit Contents/MacOS executable is classified as bundle-signed",
              CodexCLILocation.candidate(forExecutable: expectedBundle.executable) == expectedBundle)
        check("an explicit flat executable is classified as standalone",
              CodexCLILocation.candidate(forExecutable: "/opt/fixture/codex").layout == .standalone)
        check("the shipped primary candidate is the CodexCLI.app executable",
              CodexCLILocation.primaryExecutable
                == "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

        // The production boundary resolves through the same rule. Nothing executable anywhere must be
        // reported as not found, before any receipt, quarantine, or containment work starts.
        let boundaryPaths = CodexIsolationFoundation.scratchPaths(
            root: root.appendingPathComponent("boundary", isDirectory: true))
        let absent = CodexProviderRuntime.boundaryPreparationErrorForTest(
            paths: boundaryPaths, runnerPath: "/usr/bin/true", isExecutableFile: { _ in false })
        check("boundary with no CLI anywhere names the not-found cause and both checked paths",
              absent?.hasPrefix("Codex CLI not found") == true
                && CodexCLILocation.candidates().allSatisfy { absent?.contains($0.executable) == true })
    }

    // MARK: retention

    private static func checkRetention(root: URL, reporter: SelfTestReporter) throws {
        let check = reporter.check
        let fm = FileManager.default
        check("retention keeps the current snapshot plus exactly one previous",
              CodexSnapshotRetention.retainedSnapshotCount == 2)

        let store = root.appendingPathComponent("codex-executables", isDirectory: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        func sha(_ digit: Character) -> String { String(repeating: String(digit), count: 64) }
        let oldestFlat = "codex-\(sha("1"))"
        let olderBundle = "codex-\(sha("2")).app"
        let previousFlat = "codex-\(sha("3"))"
        let currentBundle = "codex-\(sha("4")).app"
        let recency: [String: Int64] = [
            oldestFlat: 100, olderBundle: 200, previousFlat: 300, currentBundle: 400,
        ]
        for name in [oldestFlat, previousFlat] {
            try Data("flat".utf8).write(to: store.appendingPathComponent(name))
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o500)],
                                 ofItemAtPath: store.appendingPathComponent(name).path)
        }
        for name in [olderBundle, currentBundle] {
            // Installed bundles are read-only all the way down; pruning must still remove them.
            let macos = store.appendingPathComponent("\(name)/Contents/MacOS", isDirectory: true)
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try Data("bundle".utf8).write(to: macos.appendingPathComponent("codex"))
            for path in [macos.appendingPathComponent("codex").path] {
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: path)
            }
            for path in [macos.path, macos.deletingLastPathComponent().path,
                         store.appendingPathComponent(name).path] {
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: path)
            }
        }
        let bystanders = ["runner-\(sha("9"))", ".codex-\(sha("8")).app.staged-fixture", "notes.txt"]
        for name in bystanders { try Data("keep".utf8).write(to: store.appendingPathComponent(name)) }

        let selected = CodexSnapshotRetention.entriesToPrune(
            recency.map { (name: $0.key, recency: $0.value) }, current: currentBundle)
        check("selection prunes exactly the two oldest of four snapshots",
              selected == [oldestFlat, olderBundle])
        check("a reused older current snapshot is kept, with the newest other",
              CodexSnapshotRetention.entriesToPrune(
                recency.map { (name: $0.key, recency: $0.value) }, current: oldestFlat)
                == [olderBundle, previousFlat])
        check("only receipt-addressable entries are ever selected",
              !CodexSnapshotRetention.isSnapshotEntryName("runner-\(sha("9"))")
                && !CodexSnapshotRetention.isSnapshotEntryName(".codex-\(sha("8")).app.staged-x")
                && CodexSnapshotRetention.isSnapshotEntryName(currentBundle)
                && CodexSnapshotRetention.isSnapshotEntryName(previousFlat))

        let pruned = try CodexSnapshotRetention.prune(
            store: store, current: currentBundle,
            recency: { recency[$0.lastPathComponent] ?? 0 })
        let remaining = Set(try fm.contentsOfDirectory(atPath: store.path))
        check("pruning 4 fake snapshots leaves exactly current + 1 previous on disk",
              pruned == [oldestFlat, olderBundle]
                && Set(remaining.filter(CodexSnapshotRetention.isSnapshotEntryName))
                    == Set([currentBundle, previousFlat]))
        check("pruning leaves runner snapshots, staging leftovers, and other files alone",
              Set(bystanders).isSubset(of: remaining))

        // Negative control: the 1.1.0 store never pruned. Four snapshots stay, which the rule forbids.
        let unpruned = store.deletingLastPathComponent().appendingPathComponent(
            "unpruned-store", isDirectory: true)
        try fm.createDirectory(at: unpruned, withIntermediateDirectories: true)
        for name in recency.keys { try Data("x".utf8).write(to: unpruned.appendingPathComponent(name)) }
        let noPruneRemaining = try fm.contentsOfDirectory(atPath: unpruned.path)
            .filter(CodexSnapshotRetention.isSnapshotEntryName)
        check("mutant: a store that is never pruned keeps four snapshots and violates retention",
              noPruneRemaining.count == 4
                && noPruneRemaining.count > CodexSnapshotRetention.retainedSnapshotCount)
    }

    // MARK: receipt addressing

    private static func checkReceiptAddressing(reporter: SelfTestReporter) {
        let check = reporter.check
        let paths = CodexIsolationFoundation.scratchPaths(
            root: URL(fileURLWithPath: "/private/tmp/viddydictate-codex-location-fixture", isDirectory: true))
        let digest = String(repeating: "a", count: 64)
        let identity = CodexIsolationFoundation.StrongFileIdentity(
            cheap: .init(device: 1, inode: 2, size: 3, modifiedSeconds: 4,
                         modifiedNanoseconds: 5, mode: 0o500),
            sha256: digest,
            codeSigning: .init(identifier: "codex", cdHash: String(repeating: "c", count: 40),
                               teamIdentifier: "SYNTHETIC"))
        let seal = CodexIsolationFoundation.ExecutableBundleIdentity(
            codeResourcesSHA256: String(repeating: "b", count: 64))
        func receipt(filename: String,
                     bundle: CodexIsolationFoundation.ExecutableBundleIdentity?)
            -> CodexIsolationFoundation.CompatibilityReceipt {
            .init(originExecutable: identity, executable: identity,
                  executableSnapshotFilename: filename,
                  originRunner: identity, runner: identity,
                  runnerSnapshotFilename: "runner-\(digest)",
                  cliVersion: "codex-cli synthetic", restrictiveConfigSHA256: digest,
                  effectiveFeatures: [], featureContinuityBaseline: [],
                  seededSkillTreeSHA256: digest, skillsRootSHA256: digest,
                  schemaSHA256: digest, executionContractSHA256: digest,
                  originExecutablePath: "/synthetic/CodexCLI.app/Contents/MacOS/codex",
                  executableBundle: bundle)
        }
        let bundled = receipt(filename: "codex-\(digest).app", bundle: seal)
        check("a bundle receipt executes <store>/codex-<sha256>.app/Contents/MacOS/codex",
              (try? CodexIsolationFoundation.executableSnapshotURL(paths: paths, receipt: bundled))
                == paths.executableStore.appendingPathComponent("codex-\(digest).app/Contents/MacOS/codex"))
        check("a flat receipt still executes <store>/codex-<sha256>",
              (try? CodexIsolationFoundation.executableSnapshotURL(
                paths: paths, receipt: receipt(filename: "codex-\(digest)", bundle: nil)))
                == paths.executableSnapshot(filename: "codex-\(digest)"))
        check("a bundle receipt naming a flat entry is refused",
              (try? CodexIsolationFoundation.executableSnapshotURL(
                paths: paths, receipt: receipt(filename: "codex-\(digest)", bundle: seal))) == nil)
        check("a flat receipt naming a bundle entry is refused",
              (try? CodexIsolationFoundation.executableSnapshotURL(
                paths: paths, receipt: receipt(filename: "codex-\(digest).app", bundle: nil))) == nil)
        check("receipt format 4 round-trips the origin path and bundle seal",
              (try? CodexIsolationFoundation.decodeCompatibilityReceipt(
                CodexIsolationFoundation.encodeCompatibilityReceipt(bundled))) == bundled
                && bundled.formatVersion == 4)

        func failure(path: String?, origin: CodexIsolationFoundation.ExecutableBundleIdentity?,
                     snapshot: CodexIsolationFoundation.ExecutableBundleIdentity?) -> String? {
            CodexIsolationFoundation.compatibilityReceiptBoundaryFailure(
                receipt: bundled, originExecutable: identity, executable: identity,
                originRunner: identity, runner: identity, configSHA256: digest,
                skillTreeSHA256: digest, skillsRootSHA256: digest,
                originExecutablePath: path, originBundle: origin, snapshotBundle: snapshot)
        }
        let otherSeal = CodexIsolationFoundation.ExecutableBundleIdentity(
            codeResourcesSHA256: String(repeating: "d", count: 64))
        check("an unchanged bundle receipt passes the location and seal bindings",
              failure(path: bundled.originExecutablePath, origin: seal, snapshot: seal)
                == "Codex envelope/schema identity changed")
        check("a different origin location invalidates the receipt",
              failure(path: "/Applications/ChatGPT.app/Contents/Resources/codex", origin: seal,
                      snapshot: seal) == "Codex origin executable location changed")
        check("a changed origin bundle seal invalidates the receipt",
              failure(path: bundled.originExecutablePath, origin: otherSeal, snapshot: seal)
                == "Codex origin bundle seal changed")
        check("a changed snapshot bundle seal invalidates the receipt",
              failure(path: bundled.originExecutablePath, origin: seal, snapshot: otherSeal)
                == "Codex executable snapshot bundle seal changed")
    }
}
