import Foundation

/// The real Codex bundle-snapshot install, run on the host filesystem with the real `codesign`.
///
/// This exists because `--codex-cli-location-selftest` never installed a bundle snapshot, and the
/// 74b34e6 install failed on every Mac: it made the staged bundle root 0500 and then renamed it, and
/// APFS refuses `rename(2)` of a directory without owner write (EACCES). Linux does not enforce that, so
/// Docker stayed green. On the Mac the deterministic tier's TMPDIR is on APFS, so this gate sees the
/// filesystem production installs into.
///
/// It builds a tiny ad hoc signed `CodexCLI.app` fixture (Info.plist, a resource, and a copy of
/// /usr/bin/true as `Contents/MacOS/codex`) under TMPDIR and drives
/// `CodexIsolationFoundation.installExecutableSnapshot(for:...)` into a scratch store. It never reads
/// /Applications, any HOME, or the live Codex store, and it never runs Codex.
///
/// Negative controls, each of which must fail: (a) the 74b34e6 order, restrict the root and then
/// rename, is refused with EACCES; (b) one flipped byte in the installed snapshot's Info.plist fails
/// `codesign --verify --strict` and the installer refuses to reuse it; (c) a lone copy of the bundle's
/// executable, outside its bundle, is refused as a single-file snapshot with a named cause.
///
/// Without codesign (Linux, the Boxx) it abstains with `[precondition-missing]`, never PASS. On macOS a
/// missing codesign is a FAIL, so the Mac's deterministic tier cannot skip it silently.
enum CodexBundleSnapshotHostSelfTest {
    static let label = "codex-bundle-snapshot-host-selftest"
    private static let codesign = "/usr/bin/codesign"
    private static let ditto = "/usr/bin/ditto"
    private static let fixtureIdentifier = "com.viddydictate.selftest.codexbundlefixture"

    static func run() -> Bool {
        print("=== Codex bundle snapshot host selftest (real install path, host filesystem) ===")
        let fm = FileManager.default
        let toolsPresent = fm.isExecutableFile(atPath: codesign) && fm.isExecutableFile(atPath: ditto)
        #if os(macOS)
        guard toolsPresent else {
            print("[\(label)] FAIL: \(codesign) or \(ditto) is missing on macOS; this gate may not abstain here")
            return false
        }
        #else
        if !toolsPresent {
            return SelfTestAbstain.skip(
                label: label,
                reason: "codesign is absent (not macOS); the bundle snapshot install needs codesign and APFS")
        }
        #endif

        let reporter = SelfTestReporter()
        let root = fm.temporaryDirectory.appendingPathComponent(
            "viddydictate-codex-bundle-host-\(UUID().uuidString)", isDirectory: true)
        defer {
            if fm.fileExists(atPath: root.path) {
                try? CodexSnapshotRetention.removeSnapshotEntry(root)
            }
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = try makeSignedFixture(in: root, reporter: reporter)
            try checkInstall(root: root, fixture: fixture, reporter: reporter)
            try checkRestrictThenRenameMutant(root: root, fixture: fixture, reporter: reporter)
            try checkLoneExecutable(root: root, fixture: fixture, reporter: reporter)
        } catch {
            reporter.record("selftest setup", false, String(describing: error))
        }
        print(reporter.summaryLine(prefix: "[\(label)]"))
        print(reporter.passed
              ? "CODEX BUNDLE SNAPSHOT HOST SELFTEST PASS" : "CODEX BUNDLE SNAPSHOT HOST SELFTEST FAIL")
        return reporter.passed
    }

    // MARK: fixture

    private struct Fixture {
        let bundle: URL
        let executable: URL
        let candidate: CodexCLILocation.Candidate
        let identity: CodexIsolationFoundation.StrongFileIdentity
        let seal: CodexIsolationFoundation.ExecutableBundleIdentity
    }

    private static func makeSignedFixture(in root: URL, reporter: SelfTestReporter) throws -> Fixture {
        let fm = FileManager.default
        let bundle = root.appendingPathComponent("fixture/CodexCLI.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources/nested", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>codex</string>
            <key>CFBundleIdentifier</key>
            <string>\(fixtureIdentifier)</string>
            <key>CFBundleName</key>
            <string>CodexCLI</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleVersion</key>
            <string>1</string>
        </dict>
        </plist>

        """
        try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("synthetic sealed resource\n".utf8)
            .write(to: resources.appendingPathComponent("fixture.txt"))
        let executable = bundle.appendingPathComponent(
            CodexCLILocation.bundleExecutableRelativePath, isDirectory: false)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executable.path)

        let signed = try runTool(codesign, ["-s", "-", "--force", bundle.path], in: root)
        reporter.record("fixture CodexCLI.app is ad hoc signed in TMPDIR", signed.status == 0,
                        signed.status == 0 ? "" : signed.stderrLine)
        let verified = try verifyStrict(bundle, in: root)
        reporter.record("fixture bundle passes codesign --verify --strict before any snapshot",
                        verified.status == 0, verified.stderrLine)

        let candidate = CodexCLILocation.candidate(forExecutable: executable.path)
        reporter.check("the fixture executable classifies as a bundle candidate rooted at the fixture",
                       candidate.layout == .appBundle && candidate.bundleRoot == bundle.path)
        let identity = try CodexIsolationFoundation.strongFileIdentity(
            at: executable, includeCodeSigning: true)
        reporter.check("the fixture executable has an ad hoc code-signing identity",
                       identity.codeSigning?.identifier == fixtureIdentifier)
        let seal = try CodexIsolationFoundation.bundleIdentity(atBundle: bundle)
        return Fixture(bundle: bundle, executable: executable, candidate: candidate,
                       identity: identity, seal: seal)
    }

    // MARK: install

    private static func checkInstall(root: URL, fixture: Fixture, reporter: SelfTestReporter) throws {
        let check = reporter.check
        let fm = FileManager.default
        let paths = CodexIsolationFoundation.scratchPaths(
            root: root.appendingPathComponent("store-install", isDirectory: true))
        let expectedEntry = "codex-\(fixture.identity.sha256).app"
        let entry = paths.executableStore.appendingPathComponent(expectedEntry, isDirectory: true)

        let installed: CodexIsolationFoundation.InstalledExecutableSnapshot
        do {
            installed = try CodexIsolationFoundation.installExecutableSnapshot(
                for: fixture.candidate, originIdentity: fixture.identity,
                originBundle: fixture.seal, paths: paths)
            reporter.record("the real installer installs the signed fixture bundle", true)
        } catch {
            reporter.record("the real installer installs the signed fixture bundle", false,
                            String(describing: error))
            return
        }
        check("the store entry is codex-<sha256>.app",
              installed.entryName == expectedEntry && installed.bundle == fixture.seal)
        check("the executed path is <entry>/Contents/MacOS/codex",
              installed.url.path == entry.appendingPathComponent(
                CodexCLILocation.bundleExecutableRelativePath).path)
        check("the installed snapshot root is a real directory with mode 0500",
              try mode(entry, directory: true) == 0o500)
        check("the installed executable is 0500 and Info.plist 0400",
              try mode(installed.url, directory: false) == 0o500
                && mode(entry.appendingPathComponent("Contents/Info.plist"), directory: false) == 0o400)
        let verified = try verifyStrict(entry, in: root)
        reporter.record("the installed snapshot passes codesign --verify --strict",
                        verified.status == 0, verified.stderrLine)
        check("no staging leftover remains in the store",
              try fm.contentsOfDirectory(atPath: paths.executableStore.path) == [expectedEntry])

        do {
            let reused = try CodexIsolationFoundation.installExecutableSnapshot(
                for: fixture.candidate, originIdentity: fixture.identity,
                originBundle: fixture.seal, paths: paths)
            reporter.record("a second install reuses the read-only snapshot unchanged",
                            reused.entryName == expectedEntry && reused.identity == installed.identity)
        } catch {
            reporter.record("a second install reuses the read-only snapshot unchanged", false,
                            String(describing: error))
        }

        // (b) One flipped byte in the snapshot's Info.plist. Permission bits are not signed; content is.
        let infoPlist = entry.appendingPathComponent("Contents/Info.plist")
        guard chmod(infoPlist.path, 0o600) == 0 else {
            reporter.record("negative control (b) could open the snapshot Info.plist", false)
            return
        }
        var bytes = try Data(contentsOf: infoPlist)
        let marker = Data("codexbundlefixture".utf8)
        if let range = bytes.range(of: marker) {
            bytes[range.lowerBound] ^= 0x01
            try bytes.write(to: infoPlist)
        }
        _ = chmod(infoPlist.path, 0o400)
        let tampered = try verifyStrict(entry, in: root)
        reporter.record("negative control (b): a flipped Info.plist byte fails codesign --verify --strict",
                        tampered.status != 0, tampered.stderrLine)
        do {
            _ = try CodexIsolationFoundation.installExecutableSnapshot(
                for: fixture.candidate, originIdentity: fixture.identity,
                originBundle: fixture.seal, paths: paths)
            reporter.record("negative control (b): the installer refuses to reuse the tampered snapshot", false)
        } catch {
            reporter.record("negative control (b): the installer refuses to reuse the tampered snapshot",
                            String(describing: error).contains("failed codesign --verify --strict"),
                            String(describing: error))
        }

        // Retention removes bundles of exactly this shape; it must restore owner write to do so.
        do {
            try CodexSnapshotRetention.removeSnapshotEntry(entry)
            reporter.record("retention removes the 0500 bundle snapshot", !fm.fileExists(atPath: entry.path))
        } catch {
            reporter.record("retention removes the 0500 bundle snapshot", false, String(describing: error))
        }
    }

    // MARK: (a) the 74b34e6 order

    private static func checkRestrictThenRenameMutant(
        root: URL, fixture: Fixture, reporter: SelfTestReporter
    ) throws {
        let fm = FileManager.default
        let paths = CodexIsolationFoundation.scratchPaths(
            root: root.appendingPathComponent("store-mutant", isDirectory: true))
        do {
            _ = try CodexIsolationFoundation.installExecutableSnapshot(
                for: fixture.candidate, originIdentity: fixture.identity,
                originBundle: fixture.seal, paths: paths, bundleRootOrder: .restrictThenRename)
            reporter.record("negative control (a): restrict-then-rename is refused with EACCES", false,
                            "the 74b34e6 order installed; this filesystem does not enforce APFS rename rules")
        } catch {
            let text = String(describing: error)
            reporter.record("negative control (a): restrict-then-rename is refused with EACCES",
                            text.contains("could not install Codex bundle snapshot")
                                && text.contains("errno \(EACCES):"),
                            text)
        }
        let left = (try? fm.contentsOfDirectory(atPath: paths.executableStore.path)) ?? ["<unreadable>"]
        reporter.record("the refused install leaves no snapshot and no staging copy", left.isEmpty,
                        left.joined(separator: ","))
    }

    // MARK: (c) a lone executable

    private static func checkLoneExecutable(root: URL, fixture: Fixture, reporter: SelfTestReporter) throws {
        let fm = FileManager.default
        let loneDirectory = root.appendingPathComponent("lone", isDirectory: true)
        try fm.createDirectory(at: loneDirectory, withIntermediateDirectories: true)
        let lone = loneDirectory.appendingPathComponent("codex", isDirectory: false)
        try fm.copyItem(at: fixture.executable, to: lone)
        let loneVerify = try verifyStrict(lone, in: root)
        reporter.record("a lone copy of the bundle executable fails codesign --verify --strict",
                        loneVerify.status != 0, loneVerify.stderrLine)

        let candidate = CodexCLILocation.candidate(forExecutable: lone.path)
        let paths = CodexIsolationFoundation.scratchPaths(
            root: root.appendingPathComponent("store-lone", isDirectory: true))
        do {
            // The lone copy still carries its signature, so production would derive a signed identity.
            let identity = try (try? CodexIsolationFoundation.strongFileIdentity(
                at: lone, includeCodeSigning: true))
                ?? CodexIsolationFoundation.strongFileIdentity(at: lone, includeCodeSigning: false)
            _ = try CodexIsolationFoundation.installExecutableSnapshot(
                for: candidate, originIdentity: identity, originBundle: nil, paths: paths)
            reporter.record("negative control (c): a lone single-file copy is refused with a named cause",
                            false, "installed as a single-file snapshot")
        } catch {
            let text = String(describing: error)
            reporter.record("negative control (c): a lone single-file copy is refused with a named cause",
                            candidate.layout == .standalone
                                && text.contains(CodexIsolationFoundation.bundleSignedLoneExecutableCause),
                            text)
        }
        let flat = paths.executableStore.appendingPathComponent("codex-\(fixture.identity.sha256)").path
        reporter.check("the refused lone copy left no flat snapshot", !fm.fileExists(atPath: flat))

        // Control for the refusal: a Mach-O signed on its own (the pre-26.924 standalone layout) still
        // installs as a single-file snapshot.
        let standaloneDirectory = root.appendingPathComponent("standalone", isDirectory: true)
        try fm.createDirectory(at: standaloneDirectory, withIntermediateDirectories: true)
        let standalone = standaloneDirectory.appendingPathComponent("codex", isDirectory: false)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: standalone)
        _ = try runTool(codesign, ["-s", "-", "--force", standalone.path], in: root)
        do {
            let identity = try CodexIsolationFoundation.strongFileIdentity(
                at: standalone, includeCodeSigning: true)
            let snapshot = try CodexIsolationFoundation.installExecutableSnapshot(
                for: CodexCLILocation.candidate(forExecutable: standalone.path),
                originIdentity: identity, originBundle: nil, paths: paths)
            let snapshotMode = try mode(snapshot.url, directory: false)
            reporter.record("control: a standalone-signed executable still installs as codex-<sha256>",
                            snapshot.entryName == "codex-\(identity.sha256)" && snapshot.bundle == nil
                                && snapshotMode == 0o500)
        } catch {
            reporter.record("control: a standalone-signed executable still installs as codex-<sha256>",
                            false, String(describing: error))
        }
    }

    // MARK: helpers

    private struct ToolResult {
        let status: Int32
        let stderrLine: String
    }

    private static func verifyStrict(_ url: URL, in directory: URL) throws -> ToolResult {
        try runTool(codesign, ["--verify", "--strict", url.path], in: directory)
    }

    /// Bounded run of a host tool. Only the first stderr line is kept, with the scratch root elided.
    private static func runTool(_ executable: String, _ arguments: [String], in directory: URL)
        throws -> ToolResult {
        let result = try CodexIsolationFoundation.runBoundedProcess(
            executable: executable,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"],
            currentDirectory: directory,
            timeout: 120,
            stdoutLimit: 4_096,
            stderrLimit: 65_536)
        let status: Int32 = result.leaderReaped && !result.timedOut && !result.captureFailure
            ? result.status : -1
        let line = String(decoding: result.stderr, as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? ""
        return ToolResult(
            status: status,
            stderrLine: line.replacingOccurrences(of: directory.path, with: "<scratch>"))
    }

    private static func mode(_ url: URL, directory: Bool) throws -> mode_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw CodexIsolationError.failed("cannot inspect \(url.lastPathComponent)")
        }
        let type = st.st_mode & S_IFMT
        guard type == (directory ? S_IFDIR : S_IFREG) else {
            throw CodexIsolationError.failed("\(url.lastPathComponent) has the wrong file type")
        }
        return st.st_mode & 0o777
    }
}
