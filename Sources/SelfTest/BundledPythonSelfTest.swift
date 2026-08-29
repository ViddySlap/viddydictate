import Foundation

/// Proves the interpreter ViddyDictate ships inside its own bundle is present, relocatable, usable,
/// and sealed the way notarization requires.
///
/// It runs against a bundle PATH rather than against `Bundle.main`, for one reason: the thing worth
/// proving is that the shipped app works at its FINAL location, and the only executable allowed to
/// run self-tests is the verification bundle beside it. Passing `--app` therefore points the same
/// checks at `build/ViddyDictate.app` during the deterministic tier and at
/// `~/Applications/ViddyDictate.app` after a deploy, and both are the real question.
///
/// Nothing here touches the network or the user's home. `python -m venv` installs pip from the
/// stdlib's own bundled wheel, so the venv check is offline; it builds into `TMPDIR`, which
/// `verify.sh` has already pointed at a scratch tree.
enum BundledPythonSelfTest {
    static func run(arguments: [String]) -> Bool {
        print("=== ViddyDictate bundled Python runtime - selftest ===")
        let reporter = SelfTestReporter()

        guard let bundleURL = resolveBundleURL(arguments: arguments) else {
            print("[bundled-python-selftest] FAIL: no app bundle to check. Pass --app <path/to/ViddyDictate.app>")
            return false
        }
        print("  bundle: \(bundleURL.path)")

        let root = BundledPython.runtimeRoot(inBundleAt: bundleURL)
        let interpreter = BundledPython.interpreter(inBundleAt: bundleURL)
        let fm = FileManager.default

        reporter.record("runtime is staged at \(BundledPython.bundleRelativePath)",
                        fm.fileExists(atPath: root.path), root.path)
        reporter.record("interpreter is executable",
                        BundledPython.isInstalled(inBundleAt: bundleURL), interpreter.path)

        guard BundledPython.isInstalled(inBundleAt: bundleURL) else {
            // Every remaining check runs the interpreter, so there is nothing further to learn here
            // and a wall of consequential failures would only bury the one that matters.
            print(reporter.summaryLine(prefix: "[bundled-python-selftest]"))
            return false
        }

        // Snapshot first, and check the seal LAST, on purpose. Both halves of the ordering matter:
        // running the interpreter is what used to write .pyc files into the bundle and break its
        // signature, so a seal check that ran before the interpreter did would report a bundle
        // healthy that the app's own first launch destroys.
        let before = fileList(under: root)

        checkInterpreterFacts(interpreter: interpreter, bundleURL: bundleURL, reporter: reporter)
        checkVenvCreation(interpreter: interpreter, bundleURL: bundleURL, reporter: reporter)

        let added = fileList(under: root).subtracting(before)
        reporter.record("running the interpreter left the bundle untouched", added.isEmpty,
                        added.sorted().prefix(5).joined(separator: ", "))

        checkSigning(bundleURL: bundleURL, reporter: reporter)

        print(reporter.summaryLine(prefix: "[bundled-python-selftest]"))
        return reporter.passed
    }

    // MARK: - The interpreter itself

    /// One Python process reports every fact at once. Facts, not opinions: the script prints values
    /// and this side decides whether they pass, so a failure names the value that was wrong.
    private static let factsScript = """
    import json, sys, sysconfig, ssl, os
    missing = []
    for name in ("ssl", "ctypes", "sqlite3", "lzma", "bz2", "zlib", "hashlib",
                 "venv", "ensurepip", "wave", "array", "socket", "select"):
        try:
            __import__(name)
        except Exception as exc:
            missing.append("%s: %s" % (name, exc))
    paths = ssl.get_default_verify_paths()
    print(json.dumps({
        "version": "%d.%d" % sys.version_info[:2],
        "full_version": sys.version.split()[0],
        "prefix": sys.prefix,
        "base_prefix": sys.base_prefix,
        "executable": sys.executable,
        "missing": missing,
        "cafile": paths.cafile or paths.openssl_cafile or "",
        "cafile_exists": os.path.exists(paths.cafile or paths.openssl_cafile or ""),
        "platlib": sysconfig.get_path("platlib"),
    }))
    """

    private static func checkInterpreterFacts(interpreter: URL, bundleURL: URL, reporter: SelfTestReporter) {
        let result = capture(interpreter.path, ["-I", "-c", factsScript])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let facts = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reporter.record("interpreter runs and reports its own facts", false,
                            "exit \(result.status): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
            return
        }

        let version = facts["version"] as? String ?? ""
        reporter.record("interpreter is the pinned \(BundledPython.seriesVersion) series",
                        version == BundledPython.seriesVersion,
                        "reported \(facts["full_version"] as? String ?? "?")")

        // The point of a relocatable runtime: every path it resolves for itself has to land inside
        // the bundle. A prefix pointing at /usr/local or a Homebrew Cellar means the app is quietly
        // borrowing the developer's machine and would break on the first stranger's.
        let bundlePath = bundleURL.standardizedFileURL.path
        for key in ["prefix", "base_prefix", "executable", "platlib"] {
            let value = facts[key] as? String ?? ""
            reporter.record("sys.\(key) resolves inside the app bundle",
                            isInside(value, bundlePath: bundlePath), value)
        }

        let missing = facts["missing"] as? [String] ?? []
        reporter.record("stdlib the installers depend on all imports", missing.isEmpty,
                        missing.joined(separator: "; "))

        // pip and huggingface_hub both need TLS, and this build links its own OpenSSL rather than
        // Apple's. Without a CA file it reaches PyPI and fails at verification, which reads to the
        // user as "the download is broken" rather than "certificates are missing".
        let cafile = facts["cafile"] as? String ?? ""
        reporter.record("TLS has a certificate authority file on this Mac",
                        (facts["cafile_exists"] as? Bool) == true,
                        cafile.isEmpty ? "no cafile reported" : cafile)
    }

    // MARK: - What the installers will actually do with it

    private static func checkVenvCreation(interpreter: URL, bundleURL: URL, reporter: SelfTestReporter) {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-bundled-python-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }

        let venv = scratch.appendingPathComponent("venv", isDirectory: true)
        let created = capture(interpreter.path, ["-m", "venv", venv.path])
        reporter.record("python -m venv builds an environment", created.status == 0,
                        created.status == 0 ? venv.path
                            : "exit \(created.status): \(created.stderr.isEmpty ? created.stdout : created.stderr)")
        guard created.status == 0 else { return }

        let venvPython = venv.appendingPathComponent("bin/python", isDirectory: false)
        reporter.record("the new environment has bin/python",
                        fm.isExecutableFile(atPath: venvPython.path), venvPython.path)
        guard fm.isExecutableFile(atPath: venvPython.path) else { return }

        // The venv must trace back to the BUNDLED interpreter and to nothing else. If it resolved to
        // a Homebrew or system Python the daemon would run on an interpreter that is not there on a
        // stranger's Mac, and the failure would only appear after the app had been dragged across.
        let base = capture(venvPython.path, ["-c", "import sys; print(sys.base_prefix)"])
        let reported = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        reporter.record("the environment's base interpreter is the bundled one",
                        isInside(reported, bundlePath: bundleURL.standardizedFileURL.path), reported)

        // pip has to be present and runnable, because it is how every later component gets installed.
        let pip = capture(venvPython.path, ["-m", "pip", "--version", "--disable-pip-version-check"])
        reporter.record("pip runs inside the new environment", pip.status == 0,
                        pip.status == 0 ? pip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                            : "exit \(pip.status): \(pip.stderr)")
    }

    // MARK: - The seal

    /// Notarization refuses a submission in which ANY Mach-O is unsigned, signed by a different
    /// identity, or missing the hardened runtime — and `codesign --verify --deep --strict` reports
    /// such a bundle valid, so it cannot be the check. This is the check.
    private static func checkSigning(bundleURL: URL, reporter: SelfTestReporter) {
        let deep = capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundleURL.path])
        reporter.record("codesign --verify --deep --strict passes on the bundle", deep.status == 0,
                        deep.status == 0 ? "" : deep.stderr)

        let executable = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(bundleURL.deletingPathExtension().lastPathComponent)
        guard let expected = signingAuthority(of: executable.path) else {
            reporter.record("the main executable's signing identity is readable", false, executable.path)
            return
        }

        let machOs = machOFiles(in: bundleURL)
        reporter.record("the bundle contains nested Mach-O files to check", !machOs.isEmpty,
                        "\(machOs.count) found")

        var unhardened: [String] = []
        var mismatched: [String] = []
        for path in machOs {
            let output = codesignDescription(of: path)
            if !output.contains("runtime") { unhardened.append(relative(path, to: bundleURL)) }
            if signingAuthority(of: path) != expected {
                mismatched.append("\(relative(path, to: bundleURL)) -> \(signingAuthority(of: path) ?? "unsigned")")
            }
        }

        reporter.record("every nested Mach-O carries the hardened runtime", unhardened.isEmpty,
                        unhardened.prefix(8).joined(separator: ", "))
        reporter.record("every nested Mach-O carries the same identity as the app (\(expected))",
                        mismatched.isEmpty, mismatched.prefix(8).joined(separator: ", "))
    }

    /// `codesign -dvv` writes its description to stderr; both streams are folded together because the
    /// caller only ever reads it as one blob of facts about one file.
    private static func codesignDescription(of path: String) -> String {
        let result = capture("/usr/bin/codesign", ["-dvv", path])
        return result.stdout + result.stderr
    }

    /// The signer, in a form that compares equal across files: the first `Authority=` line for a
    /// certificate-signed binary, and the literal `Signature=` value (`adhoc`) when there is none.
    /// Identity-agnostic on purpose — the same assertion has to hold for an ad-hoc developer build,
    /// Ben's stable local identity, and a Developer ID release.
    private static func signingAuthority(of path: String) -> String? {
        let description = codesignDescription(of: path)
        guard !description.isEmpty else { return nil }
        for line in description.split(separator: "\n") {
            if line.hasPrefix("Authority=") { return String(line) }
        }
        for line in description.split(separator: "\n") {
            if line.hasPrefix("Signature=") { return String(line) }
        }
        return nil
    }

    private static func machOFiles(in bundleURL: URL) -> [String] {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true).path
        // Mirrors build.sh's scan: one `file` pass, symlinks skipped so nothing is inspected twice
        // through an alias, and Contents/MacOS excluded because the bundle signature covers it.
        let script = """
        find \(shellQuote(contents)) -type f -not -path \(shellQuote(contents + "/MacOS/*")) -print0 \
        | xargs -0 file -F '|' --no-dereference \
        | awk -F '|' '$2 ~ /Mach-O/ { print $1 }'
        """
        let result = capture("/bin/sh", ["-c", script])
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Small shared pieces

    private static func resolveBundleURL(arguments: [String]) -> URL? {
        if let i = arguments.firstIndex(of: "--app"), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
        }
        // The verification bundle's sibling. build.sh writes both into build/, and after a deploy the
        // caller passes --app instead, so this default is only ever the development one.
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("ViddyDictate.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling.standardizedFileURL : nil
    }

    /// Every path under `root`, relative to it. Compared before and after the interpreter runs, so a
    /// failure names the files that appeared rather than the sealed-resource error they cause.
    private static func fileList(under root: URL) -> Set<String> {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return Set(walker.compactMap { $0 as? String })
    }

    private static func isInside(_ path: String, bundlePath: String) -> Bool {
        guard !path.isEmpty else { return false }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        return resolved == bundlePath || resolved.hasPrefix(bundlePath + "/")
    }

    private static func relative(_ path: String, to bundleURL: URL) -> String {
        let prefix = bundleURL.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct CaptureResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func capture(_ executable: String, _ arguments: [String]) -> CaptureResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return CaptureResult(status: -1, stdout: "", stderr: String(describing: error))
        }
        // Read before waiting: a process that fills a 64 KB pipe buffer while we wait on it deadlocks,
        // and `python -m venv` is chatty enough to make that a real possibility rather than a rule.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CaptureResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}
