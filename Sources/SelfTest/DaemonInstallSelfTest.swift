import Foundation

/// DMGD1: proves a build made from this repository actually carries the transcription daemon and that
/// the app's own installer puts it where launchd will find it.
///
/// Four arms, each driving the REAL `DaemonInstaller` over a scratch tree and an injected restart spy.
/// No arm touches the real home, the real `~/Library/LaunchAgents`, or the real launchd domain, and no
/// arm runs `launchctl`. `absent` is the mandatory negative control: it points the resource lookup at
/// an empty directory and asserts a typed failure with no file written, so the other three arms cannot
/// be green merely because the installer always writes something.
enum DaemonInstallSelfTest {
    enum Arm: String, CaseIterable {
        case bundled
        case installs
        case upgrade
        case absent
    }

    static func run(arguments: [String]) -> Int32 {
        guard let i = arguments.firstIndex(of: "--only"), i + 1 < arguments.count,
              let arm = Arm(rawValue: arguments[i + 1])
        else {
            let names = Arm.allCases.map(\.rawValue).joined(separator: "|")
            print("[daemon-install-selftest] FAIL: --only <\(names)> is required")
            return 2
        }
        let ok: Bool
        switch arm {
        case .bundled:  ok = runBundled()
        case .installs: ok = runInstalls()
        case .upgrade:  ok = runUpgrade()
        case .absent:   ok = runAbsent()
        }
        return ok ? 0 : 1
    }

    // MARK: - bundled

    /// The built bundle must carry the staged daemon and plist, and the staged script must be
    /// byte-identical to the repository copy.
    private static func runBundled() -> Bool {
        print("=== ViddyDictate daemon-install — bundled arm ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default

        guard let resources = Bundle.main.resourceURL else {
            reporter.record("the test bundle exposes a Contents/Resources directory", false)
            return finish(reporter, prefix: "daemon-install bundled")
        }

        let bundledScript = resources.appendingPathComponent("daemon/viddydictate_whisperd.py")
        let bundledPlist = resources.appendingPathComponent("daemon/com.viddydictate.whisperd.plist")
        reporter.record("the built bundle stages the daemon script",
                        fm.fileExists(atPath: bundledScript.path), bundledScript.path)
        reporter.record("the built bundle stages the LaunchAgent plist template",
                        fm.fileExists(atPath: bundledPlist.path), bundledPlist.path)

        if let root = repositoryRoot() {
            let repoScript = root.appendingPathComponent("viddydictate_whisperd.py")
            let repoHash = try? InstallerEngine.sha256(ofFileAt: repoScript, fileManager: fm)
            let bundledHash = try? InstallerEngine.sha256(ofFileAt: bundledScript, fileManager: fm)
            reporter.record(
                "the staged daemon script is byte-identical to the repository copy",
                repoHash != nil && repoHash == bundledHash,
                "repo=\(repoHash ?? "nil") staged=\(bundledHash ?? "nil")")
        } else {
            reporter.record("the repository root is reachable from the test bundle path", false,
                            Bundle.main.bundleURL.path)
        }

        return finish(reporter, prefix: "daemon-install bundled")
    }

    // MARK: - installs

    /// A fresh scratch home installs the daemon: the LaunchAgent lands at its canonical path, parses,
    /// names a file that exists, and the installed script equals the bundled one.
    private static func runInstalls() -> Bool {
        print("=== ViddyDictate daemon-install — installs arm ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default

        guard let scratch = makeScratch() else {
            reporter.record("a scratch directory can be created under the temporary directory", false)
            return finish(reporter, prefix: "daemon-install installs")
        }
        defer { try? fm.removeItem(at: scratch) }

        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let resources = scratch.appendingPathComponent("res", isDirectory: true)
        guard stageBundledDaemon(into: resources) else {
            reporter.record("the real bundled daemon copies into the scratch resource directory", false)
            return finish(reporter, prefix: "daemon-install installs")
        }

        // The LaunchAgent's program is `stt-venv/bin/python`; production only writes the plist and
        // restarts the agent once first-run setup has created it. Stage an executable stand-in so this
        // arm exercises the venv-present path it is about.
        guard stageVenvPython(in: home) else {
            reporter.record("a fixture stt-venv/bin/python can be staged", false)
            return finish(reporter, prefix: "daemon-install installs")
        }

        let spy = DaemonInstallRestartSpy()
        let installer = DaemonInstaller(homeDirectory: home, resourceDirectory: resources,
                                        restartAgent: { spy.restart() })
        let result = installer.install()
        reporter.record("a fresh scratch home reports itself installed", isInstalled(result),
                        "result=\(result)")
        reporter.record("the first install requests exactly one agent restart", spy.count == 1,
                        "restarts=\(spy.count)")

        let installedPlist = home.appendingPathComponent(
            "Library/LaunchAgents/com.viddydictate.whisperd.plist")
        reporter.record("the LaunchAgent plist lands at the canonical path",
                        fm.fileExists(atPath: installedPlist.path), installedPlist.path)

        let installedScript = home.appendingPathComponent(
            "Library/Application Support/ViddyDictate/viddydictate_whisperd.py")
        let bundledScript = resources.appendingPathComponent("daemon/viddydictate_whisperd.py")
        let installedBytes = try? Data(contentsOf: installedScript)
        let bundledBytes = try? Data(contentsOf: bundledScript)
        reporter.record("the installed script's bytes equal the bundled script's bytes",
                        installedBytes != nil && installedBytes == bundledBytes)

        if let data = try? Data(contentsOf: installedPlist),
           let text = String(data: data, encoding: .utf8) {
            reporter.record("the installed plist carries no __HOME__ placeholder",
                            !text.contains("__HOME__"))
        } else {
            reporter.record("the installed plist is readable UTF-8 text", false)
        }

        if let plist = plistDictionary(at: installedPlist),
           let arguments = plist["ProgramArguments"] as? [String] {
            reporter.record("ProgramArguments name at least one path that exists on disk",
                            arguments.contains { fm.fileExists(atPath: $0) },
                            arguments.joined(separator: " "))
            reporter.record("ProgramArguments name the installed daemon script",
                            arguments.contains {
                                $0.hasSuffix("viddydictate_whisperd.py")
                                    && fm.fileExists(atPath: $0)
                            })
        } else {
            reporter.record("the installed LaunchAgent parses as a property list dictionary", false)
        }

        return finish(reporter, prefix: "daemon-install installs")
    }

    // MARK: - upgrade

    /// A differing predecessor is preserved and replaced, with one restart; installing the same bytes
    /// again writes nothing and requests no restart.
    private static func runUpgrade() -> Bool {
        print("=== ViddyDictate daemon-install — upgrade arm ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default

        guard let scratch = makeScratch() else {
            reporter.record("a scratch directory can be created under the temporary directory", false)
            return finish(reporter, prefix: "daemon-install upgrade")
        }
        defer { try? fm.removeItem(at: scratch) }

        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let resources = scratch.appendingPathComponent("res", isDirectory: true)
        guard stageBundledDaemon(into: resources) else {
            reporter.record("the real bundled daemon copies into the scratch resource directory", false)
            return finish(reporter, prefix: "daemon-install upgrade")
        }

        // See the installs arm: production needs `stt-venv/bin/python` before it writes the plist.
        guard stageVenvPython(in: home) else {
            reporter.record("a fixture stt-venv/bin/python can be staged", false)
            return finish(reporter, prefix: "daemon-install upgrade")
        }

        let installedDirectory = home.appendingPathComponent(
            "Library/Application Support/ViddyDictate", isDirectory: true)
        let installedScript = installedDirectory.appendingPathComponent("viddydictate_whisperd.py")
        let oldBytes = Data("a previous daemon build that this app never shipped\n".utf8)
        do {
            try fm.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
            try oldBytes.write(to: installedScript)
        } catch {
            reporter.record("the fixture can pre-place an older daemon script", false,
                            String(describing: error))
            return finish(reporter, prefix: "daemon-install upgrade")
        }

        let spy = DaemonInstallRestartSpy()
        let installer = DaemonInstaller(homeDirectory: home, resourceDirectory: resources,
                                        restartAgent: { spy.restart() })

        let first = installer.install()
        reporter.record("installing over a different build reports an upgrade", isUpgraded(first),
                        "result=\(first)")
        reporter.record("the upgrade requests one agent restart", spy.count == 1,
                        "restarts=\(spy.count)")

        let bundledScript = resources.appendingPathComponent("daemon/viddydictate_whisperd.py")
        let newBytes = try? Data(contentsOf: installedScript)
        let bundledBytes = try? Data(contentsOf: bundledScript)
        reporter.record("the installed script is replaced with the bundled bytes",
                        newBytes != nil && newBytes == bundledBytes)

        let entries = (try? fm.contentsOfDirectory(atPath: installedDirectory.path)) ?? []
        let backups = entries.filter { $0.hasPrefix("viddydictate_whisperd.py.preserved-") }
        reporter.record("the previous build is preserved beside the new script", !backups.isEmpty,
                        backups.joined(separator: ", "))
        if let backup = backups.first {
            let backupBytes = try? Data(contentsOf: installedDirectory.appendingPathComponent(backup))
            reporter.record("the preserved file is the previous build, byte-for-byte",
                            backupBytes == oldBytes)
        }

        let before = modificationStamp(of: installedScript)
        let second = installer.install()
        reporter.record("installing the same bytes again reports unchanged", isUnchanged(second),
                        "result=\(second)")
        reporter.record("a no-op install requests no further restart", spy.count == 1,
                        "restarts=\(spy.count)")
        let after = modificationStamp(of: installedScript)
        reporter.record("a no-op install rewrites nothing", before != nil && before == after,
                        "before=\(before ?? "nil") after=\(after ?? "nil")")

        return finish(reporter, prefix: "daemon-install upgrade")
    }

    // MARK: - absent (mandatory negative control)

    /// A resource directory with no daemon must produce a typed bundle-resource failure and write NO
    /// file at all. This arm is what stops the other three going green over an installer that always
    /// writes something.
    private static func runAbsent() -> Bool {
        print("=== ViddyDictate daemon-install — absent arm (negative control) ===")
        let reporter = SelfTestReporter()
        let fm = FileManager.default

        guard let scratch = makeScratch() else {
            reporter.record("a scratch directory can be created under the temporary directory", false)
            return finish(reporter, prefix: "daemon-install absent")
        }
        defer { try? fm.removeItem(at: scratch) }

        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let emptyResources = scratch.appendingPathComponent("empty-res", isDirectory: true)
        do {
            try fm.createDirectory(at: emptyResources, withIntermediateDirectories: true)
        } catch {
            reporter.record("an empty scratch resource directory can be created", false,
                            String(describing: error))
            return finish(reporter, prefix: "daemon-install absent")
        }

        let spy = DaemonInstallRestartSpy()
        let installer = DaemonInstaller(homeDirectory: home, resourceDirectory: emptyResources,
                                        restartAgent: { spy.restart() })
        let result = installer.install()

        var typedBundleFailure = false
        if case .failed(.bundledResourceMissing(_)) = result { typedBundleFailure = true }
        reporter.record("a bundle with no daemon is a typed bundle-resource failure",
                        typedBundleFailure, "result=\(result)")

        let installedPlist = home.appendingPathComponent(
            "Library/LaunchAgents/com.viddydictate.whisperd.plist")
        let installedScript = home.appendingPathComponent(
            "Library/Application Support/ViddyDictate/viddydictate_whisperd.py")
        reporter.record("no LaunchAgent plist was written",
                        !fm.fileExists(atPath: installedPlist.path), installedPlist.path)
        reporter.record("no daemon script was written",
                        !fm.fileExists(atPath: installedScript.path), installedScript.path)
        reporter.record("the restart action was never requested", spy.count == 0,
                        "restarts=\(spy.count)")

        return finish(reporter, prefix: "daemon-install absent")
    }

    // MARK: - Shared helpers

    private static func finish(_ reporter: SelfTestReporter, prefix: String) -> Bool {
        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: prefix))
        return reporter.passed
    }

    /// The present test bundle lives at `<repo>/build/ViddyDictateTests.app`; walking up finds the
    /// directory that holds the repository's daemon script. A missing root is a recorded failure, never
    /// a crash.
    private static func repositoryRoot() -> URL? {
        let fm = FileManager.default
        var directory = Bundle.main.bundleURL
        for _ in 0..<12 {
            if fm.fileExists(atPath: directory.appendingPathComponent("viddydictate_whisperd.py").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func makeScratch() -> URL? {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent("viddydictate-daemon-install-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Copy the REAL bundled `daemon/` directory into a scratch resource root, so the installer under
    /// test reads exactly the bytes the build staged.
    private static func stageBundledDaemon(into resourceDirectory: URL) -> Bool {
        let fm = FileManager.default
        guard let bundled = Bundle.main.resourceURL?
                .appendingPathComponent("daemon", isDirectory: true),
              fm.fileExists(atPath: bundled.path) else { return false }
        do {
            try fm.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
            try fm.copyItem(at: bundled,
                            to: resourceDirectory.appendingPathComponent("daemon", isDirectory: true))
            return true
        } catch {
            return false
        }
    }

    /// The LaunchAgent's program is `stt-venv/bin/python`. Production only writes the plist and restarts
    /// the agent once first-run setup has built that interpreter, so these arms stage an executable
    /// stand-in to exercise the venv-present path; the no-venv path is owned by the protected
    /// installer-rework `no-bootstrap-before-venv` arm.
    private static func stageVenvPython(in home: URL) -> Bool {
        let fm = FileManager.default
        let python = home.appendingPathComponent(
            "Library/Application Support/ViddyDictate/stt-venv/bin/python", isDirectory: false)
        do {
            try fm.createDirectory(at: python.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            fm.createFile(atPath: python.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                                 ofItemAtPath: python.path)
            return true
        } catch {
            return false
        }
    }

    private static func isInstalled(_ result: DaemonInstallResult) -> Bool {
        if case .installed = result { return true }
        return false
    }

    private static func isUpgraded(_ result: DaemonInstallResult) -> Bool {
        if case .upgraded(let backup) = result { return backup != nil }
        return false
    }

    private static func isUnchanged(_ result: DaemonInstallResult) -> Bool {
        if case .unchanged = result { return true }
        return false
    }

    private static func plistDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func modificationStamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.intValue)@\(modified.timeIntervalSince1970)"
    }

    /// The injected restart action for the arms. A class so the closure can mutate it; nested inside
    /// this type so the shipped binary never links it.
    private final class DaemonInstallRestartSpy {
        private(set) var count = 0
        func restart() { count += 1 }
    }
}
