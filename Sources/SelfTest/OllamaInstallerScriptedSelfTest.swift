import Foundation

/// G5 (`--ollama-installer-selftest`): the real `OllamaInstaller` driven end to end over SCRIPTED I/O. A small
/// in-memory web answers the measured redirect chain hop by hop, a scratch tree stands in for the mounted
/// disk image and `/Applications`, a command recorder stands in for `hdiutil`, `codesign` and `open`, a
/// scripted `OllamaBackend` transport answers `/api/version` and `/api/tags`, and a scripted stream feeds
/// `/api/pull` lines against a fake clock. No socket, no disk image, no app launch, no download.
///
/// Distinct values, so a default cannot pass by accident: the disk image is **4243** bytes (never the real
/// 199580406), the pull's two layers are **5,000,000** and **241** bytes, and the wrong Team ID is
/// `FIXTUREWRONG1`. No fixture carries a real digest or signature (the probe's DMG sha256 stays out).
///
/// Negative controls: the contract is re-run against three broken installers, and the gate FAILS unless the
/// assertion aimed at each one reports it:
/// (a) a resolver whose allowlist checks only the first host;
/// (b) an app check with no Team ID pin (bundle id and `codesign --verify` only);
/// (c) pull progress that reports each layer's raw latest `completed`, so it goes backward.
enum OllamaInstallerScriptedSelfTest {
    private static let dmgBytes: Int64 = 4243
    private static let weightsTotal: UInt64 = 5_000_000
    private static let paramsTotal: UInt64 = 241
    private static let wrongTeam = "FIXTUREWRONG1"
    private static let pulledName = "installer-fixture-pulled:4b"

    // The measured chain (Mac probe B2), with fixture paths. The signed query is a placeholder, not a signature.
    private static let hop1 = "https://github.com/ollama/ollama/releases/latest/download/Ollama.dmg"
    private static let hop2 = "https://github.com/ollama/ollama/releases/download/v0.35.0/Ollama.dmg"
    private static let hop3 = "https://release-assets.githubusercontent.com/github-production-release-asset/"
        + "fixture-asset/fixture-object?sig=fixture-signature"

    // Assertion names the negative controls look up.
    private static let anyHopCheck =
        "an off-list host at ANY hop of the chain is refused before it is requested"
    private static let teamIDCheck =
        "a wrong Team ID is rejected even when codesign --verify passes"
    private static let monotonicCheck =
        "pull progress never goes backward across a stalled part's restart"

    static func run() -> Bool {
        print("=== Ollama installer scripted selftest (trust chain, prompt wait, pull progress) ===")
        let reporter = SelfTestReporter()

        guard let scratch = scratchDirectory(reporter) else {
            print("[ollama-installer-selftest] FAIL")
            return false
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        print("--- contract (real installer) ---")
        checkContract(realSubject, scratch: scratch, reporter)
        checkChainDetails(reporter)
        checkDownload(scratch: scratch, reporter)
        checkInstall(scratch: scratch, reporter)
        checkStart(reporter)
        checkPullDetails(reporter)
        checkNegativeControls(scratch: scratch, reporter)

        print(reporter.passed
            ? "[ollama-installer-selftest] PASS"
            : "[ollama-installer-selftest] FAIL")
        return reporter.passed
    }

    // MARK: - The subject (what the negative controls swap out)

    private struct PullRun {
        var reports: [InstallerByteProgress] = []
        var reportTimes: [TimeInterval] = []
        var outcome: Result<OllamaInstaller.ModelInstallOutcome, Error>?
    }

    private struct Subject {
        let resolve: (OllamaInstaller.HTTP) throws -> OllamaInstaller.DMGSource
        let verify: (_ app: URL, _ runner: @escaping OllamaInstaller.CommandRunner) throws -> Void
        let pull: (_ lines: [(TimeInterval, String)]) -> PullRun
    }

    private static var realSubject: Subject {
        Subject(
            resolve: { try OllamaInstaller.resolveOfficialDMG(http: $0) },
            verify: { app, runner in
                try OllamaInstaller.verifyApplication(at: app, fileManager: .default, commandRunner: runner)
            },
            pull: { lines in runRealPull(lines: lines) })
    }

    // MARK: - The scripted web

    private struct Page {
        let status: Int
        let headers: [String: String]
    }

    private final class ScriptedWeb {
        var pages: [String: Page] = [:]
        private(set) var requested: [String] = []
        var downloadBody: Data = Data()
        /// What the GET answers with, by default the HEAD's page for that URL.
        var downloadPage: Page?
        var downloadURLOverride: URL?

        var http: OllamaInstaller.HTTP {
            OllamaInstaller.HTTP(
                head: { url, _ in
                    self.requested.append(url.absoluteString)
                    guard let page = self.pages[url.absoluteString] else {
                        throw OllamaInstaller.InstallerError.network("no scripted page for \(url.host ?? "?")")
                    }
                    return HTTPURLResponse(url: url, statusCode: page.status, httpVersion: "HTTP/1.1",
                                           headerFields: page.headers)!
                },
                download: { url, destination, _ in
                    self.requested.append("GET " + url.absoluteString)
                    try self.downloadBody.write(to: destination)
                    let page = self.downloadPage ?? self.pages[url.absoluteString] ?? Page(status: 404, headers: [:])
                    return HTTPURLResponse(url: self.downloadURLOverride ?? url, statusCode: page.status,
                                           httpVersion: "HTTP/1.1", headerFields: page.headers)!
                })
        }

        func wasRequested(host: String) -> Bool {
            requested.contains { URL(string: $0.replacingOccurrences(of: "GET ", with: ""))?.host == host }
        }
    }

    private static func redirect(_ status: Int, to location: String) -> Page {
        Page(status: status, headers: ["Location": location, "Content-Type": "text/html; charset=utf-8"])
    }

    private static var finalPage: Page {
        Page(status: 200, headers: ["Content-Type": "application/octet-stream",
                                    "Content-Length": String(dmgBytes),
                                    "Content-Disposition": "attachment; filename=Ollama.dmg"])
    }

    /// The measured chain: 307, 302, 302, 200.
    private static func measuredWeb() -> ScriptedWeb {
        let web = ScriptedWeb()
        web.pages[OllamaInstaller.officialDMGEndpoint.absoluteString] = redirect(307, to: hop1)
        web.pages[hop1] = redirect(302, to: hop2)
        web.pages[hop2] = redirect(302, to: hop3)
        web.pages[hop3] = finalPage
        return web
    }

    // MARK: - Contract (the three negative-control targets, plus their neighbours)

    private static func checkContract(_ subject: Subject, scratch: URL, _ reporter: SelfTestReporter) {
        // The measured chain resolves to the signed final URL with its byte count.
        let web = measuredWeb()
        let source = try? subject.resolve(web.http)
        reporter.record("the measured 307 -> 302 -> 302 -> 200 chain resolves to the final signed URL",
                        source?.url.absoluteString == hop3 && source?.expectedBytes == dmgBytes
                            && web.requested == [OllamaInstaller.officialDMGEndpoint.absoluteString, hop1, hop2, hop3],
                        web.requested.map { URL(string: $0)?.host ?? $0 }.joined(separator: " -> "))

        // An off-list host swapped in at each hop in turn. It is scripted to answer helpfully (a redirect
        // straight back into the real chain, or the DMG itself), so only a check at THAT hop can refuse it.
        let evilHosts = ["ollama.com.fixture-lookalike.example", "objects.githubusercontent.example",
                         "release-assets.fixture-mirror.example"]
        var refusedEverywhere = true
        var detail: [String] = []
        for (index, evil) in evilHosts.enumerated() {
            let web = measuredWeb()
            let evilURL = "https://\(evil)/Ollama.dmg"
            switch index {
            case 0: web.pages[OllamaInstaller.officialDMGEndpoint.absoluteString] = redirect(307, to: evilURL)
                    web.pages[evilURL] = redirect(302, to: hop2)
            case 1: web.pages[hop1] = redirect(302, to: evilURL)
                    web.pages[evilURL] = redirect(302, to: hop3)
            default: web.pages[hop2] = redirect(302, to: evilURL)
                     web.pages[evilURL] = finalPage
            }
            let resolved = (try? subject.resolve(web.http)) != nil
            let contacted = web.wasRequested(host: evil)
            if resolved || contacted { refusedEverywhere = false }
            detail.append("hop \(index + 1): resolved=\(resolved) contacted=\(contacted)")
        }
        reporter.record(anyHopCheck, refusedEverywhere, detail.joined(separator: "; "))

        // The Team ID pin, on a bundle whose id and signature are otherwise fine.
        guard let app = makeApp(in: scratch.appendingPathComponent("contract-\(UUID().uuidString)"),
                                bundleID: OllamaInstaller.bundleIdentifier) else {
            reporter.record("contract app fixture", false)
            return
        }
        let offTeam = runner(verifyStatus: 0, team: wrongTeam)
        reporter.record(teamIDCheck, (try? subject.verify(app, offTeam.run)) == nil
                            && offTeam.calls.contains { $0.contains("--verify") })
        let rightTeam = runner(verifyStatus: 0, team: OllamaInstaller.teamIdentifier)
        reporter.record("Ollama's own Team ID, bundle id and signature pass",
                        (try? subject.verify(app, rightTeam.run)) != nil)

        // Progress through a stalled part's restart (measured: 4.04 GB fell back to 1.03 GB on one blob).
        let run = subject.pull(backwardJumpLines)
        let completed = run.reports.map(\.completed)
        reporter.record(monotonicCheck,
                        !completed.isEmpty && zip(completed, completed.dropFirst()).allSatisfy { $0 <= $1 },
                        completed.map(String.init).joined(separator: ","))
        var installed = false
        if case .success(.installed(pulledName))? = run.outcome { installed = true }
        reporter.record("the pull through a restart completes as installed, not as a failure", installed)
    }

    // MARK: - Chain details

    private static func checkChainDetails(_ reporter: SelfTestReporter) {
        print("--- the rest of the chain rules ---")
        reporter.record("the endpoint is Ollama's official HTTPS download",
                        OllamaInstaller.officialDMGEndpoint.absoluteString == "https://ollama.com/download/Ollama.dmg")
        reporter.record("the allowlist is exactly the three measured hosts",
                        OllamaInstaller.allowedHosts
                            == ["ollama.com", "github.com", "release-assets.githubusercontent.com"])

        let plain = measuredWeb()
        let plainHop = hop2.replacingOccurrences(of: "https://", with: "http://")
        plain.pages[hop1] = redirect(302, to: plainHop)
        plain.pages[plainHop] = redirect(302, to: hop3)
        reporter.record("an http:// hop on an allowed host is refused before it is requested",
                        (try? OllamaInstaller.resolveOfficialDMG(http: plain.http)) == nil
                            && !plain.requested.contains(plainHop))

        let port = measuredWeb()
        let portHop = "https://github.com:8443/ollama/Ollama.dmg"
        port.pages[hop1] = redirect(302, to: portHop)
        port.pages[portHop] = redirect(302, to: hop3)
        reporter.record("an allowed host on a non-default port is refused",
                        (try? OllamaInstaller.resolveOfficialDMG(http: port.http)) == nil
                            && !port.requested.contains(portHop))

        let relative = measuredWeb()
        relative.pages[hop1] = redirect(302, to: "/ollama/ollama/releases/download/v0.35.0/Ollama.dmg")
        reporter.record("a relative Location resolves against the host that sent it",
                        (try? OllamaInstaller.resolveOfficialDMG(http: relative.http))?.url.absoluteString == hop3)

        let loop = measuredWeb()
        loop.pages[hop2] = redirect(302, to: hop1)
        reporter.record("a redirect loop ends in a refusal, not a hang",
                        (try? OllamaInstaller.resolveOfficialDMG(http: loop.http)) == nil
                            && loop.requested.count == OllamaInstaller.maximumRedirects + 1)

        for (name, headers) in [
            ("an HTML final response is refused", ["Content-Type": "text/html", "Content-Length": "4243",
                                                   "Content-Disposition": "attachment; filename=Ollama.dmg"]),
            ("a final response with no Content-Length is refused",
             ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=Ollama.dmg"]),
            ("a final response that names no .dmg is refused",
             ["Content-Type": "application/octet-stream", "Content-Length": "4243",
              "Content-Disposition": "attachment; filename=Ollama.zip"]),
        ] {
            let web = measuredWeb()
            web.pages[hop3] = Page(status: 200, headers: headers)
            reporter.record(name, (try? OllamaInstaller.resolveOfficialDMG(http: web.http)) == nil)
        }
        let missing = measuredWeb()
        missing.pages[hop3] = Page(status: 404, headers: [:])
        do {
            _ = try OllamaInstaller.resolveOfficialDMG(http: missing.http)
            reporter.record("a 404 at the end of the chain is an HTTP failure, not retried", false)
        } catch {
            let failure = InstallerEngine.failure(forLocal: error)
            reporter.record("a 404 at the end of the chain is an HTTP failure, not retried",
                            failure.category == .client(404) && !failure.isRetryable, failure.message)
        }
        do {
            let web = measuredWeb()
            web.pages[hop1] = redirect(302, to: "https://fixture-offlist.example/x.dmg")
            _ = try OllamaInstaller.resolveOfficialDMG(http: web.http)
            reporter.record("a refused hop is a trust failure that is never retried and names no query", false)
        } catch {
            let failure = InstallerEngine.failure(forLocal: error)
            reporter.record("a refused hop is a trust failure that is never retried and names no query",
                            failure.category == .checksumMismatch && !failure.isRetryable
                                && !failure.message.contains("sig="), failure.message)
        }
    }

    // MARK: - Download

    private static func checkDownload(scratch: URL, _ reporter: SelfTestReporter) {
        print("--- GET to .part, then the byte count ---")
        let fileManager = FileManager.default
        let source = OllamaInstaller.DMGSource(url: URL(string: hop3)!, expectedBytes: dmgBytes)

        let good = measuredWeb()
        good.downloadBody = Data(repeating: 0x4F, count: Int(dmgBytes))
        let destination = scratch.appendingPathComponent("downloads/Ollama-good.dmg")
        let saved = try? OllamaInstaller.downloadDMG(source: source, to: destination, http: good.http)
        let partials = (try? fileManager.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path))?
            .filter { $0.hasSuffix(".part") } ?? []
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
        reporter.record("the GET lands in a .part file, is counted, then moved into place",
                        saved == destination && size == dmgBytes && partials.isEmpty
                            && good.requested.last == "GET " + hop3)

        let short = measuredWeb()
        short.downloadBody = Data(repeating: 0x4F, count: Int(dmgBytes) - 1)
        let shortDestination = scratch.appendingPathComponent("downloads/Ollama-short.dmg")
        reporter.record("a body shorter than the verified length is refused and not kept",
                        (try? OllamaInstaller.downloadDMG(source: source, to: shortDestination, http: short.http)) == nil
                            && !fileManager.fileExists(atPath: shortDestination.path))

        let longer = measuredWeb()
        longer.downloadBody = Data(repeating: 0x4F, count: Int(dmgBytes))
        longer.downloadPage = Page(status: 200, headers: ["Content-Type": "application/octet-stream",
                                                          "Content-Length": String(dmgBytes + 17),
                                                          "Content-Disposition": "attachment; filename=Ollama.dmg"])
        let longerDestination = scratch.appendingPathComponent("downloads/Ollama-length.dmg")
        reporter.record("a GET whose Content-Length differs from the HEAD's is refused",
                        (try? OllamaInstaller.downloadDMG(source: source, to: longerDestination, http: longer.http)) == nil
                            && !fileManager.fileExists(atPath: longerDestination.path))

        let moved = measuredWeb()
        moved.downloadBody = Data(repeating: 0x4F, count: Int(dmgBytes))
        moved.downloadURLOverride = URL(string: "https://release-assets.githubusercontent.com/another-object")
        let movedDestination = scratch.appendingPathComponent("downloads/Ollama-moved.dmg")
        reporter.record("a GET answered from a different URL than the verified HEAD is refused",
                        (try? OllamaInstaller.downloadDMG(source: source, to: movedDestination, http: moved.http)) == nil)
    }

    // MARK: - Attach, verify, stage, detach

    private final class Recorder {
        var calls: [[String]] = []
        let attachPlist: String
        let verifyStatus: Int32
        let team: String?

        init(attachPlist: String, verifyStatus: Int32, team: String?) {
            self.attachPlist = attachPlist
            self.verifyStatus = verifyStatus
            self.team = team
        }

        func run(_ executable: String, _ arguments: [String]) throws -> OllamaInstaller.CommandResult {
            calls.append([executable] + arguments)
            if executable == "/usr/bin/hdiutil", arguments.first == "attach" {
                return .init(status: 0, stdout: attachPlist, stderr: "")
            }
            if executable == "/usr/bin/codesign", arguments.contains("--verify") {
                return .init(status: verifyStatus, stdout: "",
                             stderr: verifyStatus == 0 ? "" : "fixture: code object is not signed at all")
            }
            if executable == "/usr/bin/codesign", arguments.contains("-dv") {
                // codesign -dv writes its details to STDERR, one key per line.
                let teamLine = team.map { "TeamIdentifier=\($0)" } ?? "TeamIdentifier=not set"
                return .init(status: 0, stdout: "", stderr: """
                    Executable=/fixture/Ollama.app/Contents/MacOS/Ollama
                    Identifier=com.electron.ollama
                    Format=app bundle with Mach-O universal (x86_64 arm64)
                    Authority=Developer ID Application: Fixture Signer
                    \(teamLine)
                    Sealed Resources version=2 rules=13 files=42
                    """)
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
    }

    private static func runner(verifyStatus: Int32, team: String?, mount: URL? = nil) -> Recorder {
        let plist = mount.map { mount in
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>system-entities</key><array><dict>
            <key>mount-point</key><string>\(mount.path)</string>
            </dict></array></dict></plist>
            """
        } ?? ""
        return Recorder(attachPlist: plist, verifyStatus: verifyStatus, team: team)
    }

    /// A minimal `Ollama.app`: an Info.plist naming `bundleID` and an executable `Contents/MacOS/Ollama`.
    private static func makeApp(in parent: URL, bundleID: String) -> URL? {
        let fileManager = FileManager.default
        let app = parent.appendingPathComponent(OllamaInstaller.appName, isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Ollama")
        do {
            try fileManager.createDirectory(at: executable.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Ollama"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            guard fileManager.createFile(atPath: executable.path, contents: Data("fixture executable".utf8),
                                         attributes: [.posixPermissions: 0o700]) else { return nil }
            return app
        } catch {
            return nil
        }
    }

    private static func checkInstall(scratch: URL, _ reporter: SelfTestReporter) {
        print("--- read-only attach, bundle id, signature, Team ID, stage, detach ---")
        let fileManager = FileManager.default
        let root = scratch.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        let mount = root.appendingPathComponent("mounted", isDirectory: true)
        let dmg = root.appendingPathComponent("Ollama.dmg")
        guard makeApp(in: mount, bundleID: OllamaInstaller.bundleIdentifier) != nil,
              fileManager.createFile(atPath: dmg.path, contents: Data(repeating: 0x44, count: Int(dmgBytes))) else {
            reporter.record("install fixture setup", false)
            return
        }

        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let good = runner(verifyStatus: 0, team: OllamaInstaller.teamIdentifier, mount: mount)
        let installed = try? OllamaInstaller.installDMG(at: dmg, expectedBytes: dmgBytes,
                                                       applicationsDirectory: applications,
                                                       commandRunner: good.run)
        let destination = applications.appendingPathComponent(OllamaInstaller.appName)
        let staged = (try? fileManager.contentsOfDirectory(atPath: applications.path))?
            .filter { $0.contains("installing") } ?? []
        reporter.record("a verified image is attached read-only, checked, staged, renamed into place, and detached",
                        installed == .installed(destination) && fileManager.fileExists(atPath: destination.path)
                            && staged.isEmpty
                            && good.calls.contains { $0.starts(with: ["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly"]) }
                            && good.calls.last?.starts(with: ["/usr/bin/hdiutil", "detach"]) == true)
        reporter.record("the Team ID is read from codesign -dv on the mounted AND the staged copy",
                        good.calls.filter { $0.contains("-dv") }.count == 2)

        // An existing install is the user's: left byte-identical, with no image attached at all.
        let before = snapshot(of: destination)
        try? Data("the user's own settings".utf8).write(to: destination.appendingPathComponent("Contents/user-marker"))
        let withMarker = snapshot(of: destination)
        let again = runner(verifyStatus: 0, team: OllamaInstaller.teamIdentifier, mount: mount)
        let second = try? OllamaInstaller.installDMG(at: dmg, expectedBytes: dmgBytes,
                                                    applicationsDirectory: applications,
                                                    commandRunner: again.run)
        reporter.record("an existing /Applications/Ollama.app is left byte-identical, with nothing attached",
                        second == .alreadyInstalled(destination) && again.calls.isEmpty
                            && !before.isEmpty && snapshot(of: destination) == withMarker)

        let wrongBundleMount = root.appendingPathComponent("wrong-bundle", isDirectory: true)
        _ = makeApp(in: wrongBundleMount, bundleID: "com.fixture.not-ollama")
        let wrongBundle = runner(verifyStatus: 0, team: OllamaInstaller.teamIdentifier, mount: wrongBundleMount)
        let otherApps = root.appendingPathComponent("Applications-bundle", isDirectory: true)
        reporter.record("a wrong bundle id is rejected, installs nothing, and still detaches",
                        (try? OllamaInstaller.installDMG(at: dmg, expectedBytes: dmgBytes,
                                                         applicationsDirectory: otherApps,
                                                         commandRunner: wrongBundle.run)) == nil
                            && !fileManager.fileExists(atPath: otherApps.appendingPathComponent(OllamaInstaller.appName).path)
                            && wrongBundle.calls.last?.starts(with: ["/usr/bin/hdiutil", "detach"]) == true)

        let wrongTeamRunner = runner(verifyStatus: 0, team: wrongTeam, mount: mount)
        let teamApps = root.appendingPathComponent("Applications-team", isDirectory: true)
        do {
            _ = try OllamaInstaller.installDMG(at: dmg, expectedBytes: dmgBytes, applicationsDirectory: teamApps,
                                               commandRunner: wrongTeamRunner.run)
            reporter.record("a wrong Team ID installs nothing, and is a trust failure that is never retried", false)
        } catch {
            let failure = InstallerEngine.failure(forLocal: error)
            reporter.record("a wrong Team ID installs nothing, and is a trust failure that is never retried",
                            !fileManager.fileExists(atPath: teamApps.appendingPathComponent(OllamaInstaller.appName).path)
                                && failure.category == .checksumMismatch && failure.message.contains(wrongTeam),
                            failure.message)
        }

        guard let loose = makeApp(in: root.appendingPathComponent("loose"), bundleID: OllamaInstaller.bundleIdentifier) else { return }
        reporter.record("an unsigned (ad hoc) bundle with no Team ID is rejected",
                        (try? OllamaInstaller.verifyApplication(
                            at: loose, fileManager: fileManager,
                            commandRunner: runner(verifyStatus: 0, team: nil).run)) == nil)
        reporter.record("a failing codesign --verify is rejected whatever the Team ID says",
                        (try? OllamaInstaller.verifyApplication(
                            at: loose, fileManager: fileManager,
                            commandRunner: runner(verifyStatus: 1, team: OllamaInstaller.teamIdentifier).run)) == nil)
        reporter.record("TeamIdentifier is parsed from codesign's stderr lines",
                        OllamaInstaller.teamIdentifier(inCodesignOutput: "Identifier=x\n  TeamIdentifier=3MU9H2V9Y9\n")
                            == "3MU9H2V9Y9"
                            && OllamaInstaller.teamIdentifier(inCodesignOutput: "TeamIdentifier=not set") == nil
                            && OllamaInstaller.teamIdentifier(inCodesignOutput: "Identifier=x") == nil)

        let wrongSizeApps = root.appendingPathComponent("Applications-size", isDirectory: true)
        let sized = runner(verifyStatus: 0, team: OllamaInstaller.teamIdentifier, mount: mount)
        reporter.record("an image whose size is not the verified length fails before hdiutil runs",
                        (try? OllamaInstaller.installDMG(at: dmg, expectedBytes: dmgBytes + 1,
                                                         applicationsDirectory: wrongSizeApps,
                                                         commandRunner: sized.run)) == nil && sized.calls.isEmpty)
    }

    /// Every regular file under `root`, by relative path, with its bytes.
    private static func snapshot(of root: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return files }
        for case let url as URL in walk {
            guard let data = try? Data(contentsOf: url) else { continue }
            files[String(url.path.dropFirst(root.path.count))] = data
        }
        return files
    }

    // MARK: - Start by path, and the prompt wait

    private final class ScriptedServer {
        var answerAfterProbes: Int?
        private(set) var probes = 0
        var paths: [String: OllamaBackend.PathStatus] = [
            "/Applications/Ollama.app": OllamaBackend.PathStatus(exists: true, isDirectory: true, isExecutable: true),
        ]
        var tagsBody = "{\"models\":[]}"
        var tagsStatus = 200
        private(set) var requested: [String] = []

        var backend: OllamaBackend {
            OllamaBackend(
                transport: OllamaBackend.Transport(
                    send: { request, _ in self.answer(request) },
                    pathStatus: { self.paths[$0] ?? .missing }),
                environment: [:], homeDirectory: "/fixture-home")
        }

        private func answer(_ request: URLRequest) -> (Data?, HTTPURLResponse?, Error?) {
            let path = request.url?.path ?? ""
            requested.append(path)
            func reply(_ body: String, _ status: Int) -> (Data?, HTTPURLResponse?, Error?) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                  headerFields: nil), nil)
            }
            switch path {
            case "/api/version":
                probes += 1
                guard let after = answerAfterProbes, probes > after else {
                    return (nil, nil, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
                }
                return reply("{\"version\":\"0.35.0\"}", 200)
            case "/api/tags":
                return reply(tagsBody, tagsStatus)
            default:
                return reply("{\"error\":\"not found\"}", 404)
            }
        }
    }

    private final class FakeClock {
        var now: TimeInterval = 1000
    }

    private static func checkStart(_ reporter: SelfTestReporter) {
        print("--- start by path, and wait for the user's approval ---")
        // Approved after a while: opened by path, the wait is announced, and it is NOT a failure.
        let slow = ScriptedServer()
        slow.answerAfterProbes = 41
        let clock = FakeClock()
        let opener = runner(verifyStatus: 0, team: nil)
        var announcements = 0
        let outcome = try? OllamaInstaller.ensureServerReady(
            backend: slow.backend, commandRunner: opener.run, clock: { clock.now },
            sleep: { clock.now += $0 }, onAwaitingApproval: { announcements += 1 })
        reporter.record("the app is started by PATH in the background, never by name",
                        opener.calls == [["/usr/bin/open", "-g", "/Applications/Ollama.app"]]
                            && !opener.calls.contains { $0.contains("-a") },
                        opener.calls.map { $0.joined(separator: " ") }.joined(separator: " | "))
        reporter.record("a server that answers after the user approves is started, not failed",
                        outcome == .started, String(describing: outcome))
        reporter.record("while it waits, the row reports the approval wait exactly once",
                        announcements == 1, "\(announcements)")

        let record = BootstrapComponentRecord(id: BootstrapInstallPlan.ollama.id, title: "Ollama", phase: .installing)
        let waitingText = InstallProgress.statusText(for: record, activity: .awaitingApproval(.ollama))
        reporter.record("the wait is its own user-visible state, in its own words",
                        waitingText == "waiting for you to approve Ollama's macOS prompt"
                            && PointOfUsePolicy.progressLine(record, activity: .awaitingApproval(.ollama))
                                == "Ollama   waiting for you to approve Ollama's macOS prompt",
                        waitingText)

        // Never approved: bounded at ten minutes, then the actionable message, and not retried.
        let silent = ScriptedServer()
        let neverClock = FakeClock()
        let started = neverClock.now
        var neverAnnounced = 0
        do {
            _ = try OllamaInstaller.ensureServerReady(
                backend: silent.backend, commandRunner: runner(verifyStatus: 0, team: nil).run,
                clock: { neverClock.now }, sleep: { neverClock.now += $0 },
                onAwaitingApproval: { neverAnnounced += 1 })
            reporter.record("an unanswered prompt ends at ten minutes with the actionable message", false)
        } catch {
            let failure = InstallerEngine.failure(forLocal: error)
            let waited = neverClock.now - started
            reporter.record("an unanswered prompt ends at ten minutes with the actionable message",
                            waited >= 600 && waited < 600 + 2 * OllamaInstaller.approvalPollInterval
                                && failure.message.contains("Open Ollama and approve its macOS prompt, then choose Try again")
                                && neverAnnounced == 1,
                            "waited \(Int(waited)) s: \(failure.message)")
            reporter.record("that timeout is never retried by the engine",
                            failure.category == .process && !failure.isRetryable)
        }

        let running = ScriptedServer()
        running.answerAfterProbes = 0
        let untouched = runner(verifyStatus: 0, team: nil)
        reporter.record("a server that already answers opens nothing",
                        (try? OllamaInstaller.ensureServerReady(backend: running.backend,
                                                                 commandRunner: untouched.run)) == .alreadyRunning
                            && untouched.calls.isEmpty)

        let cliOnly = ScriptedServer()
        cliOnly.paths = ["/opt/homebrew/bin/ollama": OllamaBackend.PathStatus(exists: true, isDirectory: false,
                                                                             isExecutable: true)]
        let cliRunner = runner(verifyStatus: 0, team: nil)
        reporter.record("a stopped CLI-only install is never started by ViddyDictate",
                        (try? OllamaInstaller.ensureServerReady(backend: cliOnly.backend,
                                                                 commandRunner: cliRunner.run)) == nil
                            && cliRunner.calls.isEmpty)
    }

    // MARK: - Pull

    private static func line(_ status: String, digest: String? = nil, total: UInt64? = nil,
                             completed: UInt64? = nil) -> String {
        var fields = ["\"status\":\"\(status)\""]
        if let digest { fields.append("\"digest\":\"\(digest)\"") }
        if let total { fields.append("\"total\":\(total)") }
        if let completed { fields.append("\"completed\":\(completed)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static let weights = "sha256:fixture-layer-weights"
    private static let params = "sha256:fixture-layer-params"

    /// Two layers; the big one climbs to 4 MB, restarts at 1 MB, then finishes. One line a second.
    private static var backwardJumpLines: [(TimeInterval, String)] {
        var lines: [String] = [line("pulling manifest"), line("pulling weights", digest: weights, total: weightsTotal)]
        for mb in [1, 2, 3, 4, 1, 2, 3, 4, 5] as [UInt64] {
            lines.append(line("pulling weights", digest: weights, total: weightsTotal, completed: mb * 1_000_000))
        }
        lines.append(line("pulling params", digest: params, total: paramsTotal))
        lines.append(line("pulling params", digest: params, total: paramsTotal, completed: paramsTotal))
        lines += [line("verifying sha256 digest"), line("writing manifest"), line("success")]
        return lines.enumerated().map { (TimeInterval($0.offset), $0.element) }
    }

    /// Runs the REAL `pullModel` over a scripted catalog and a scripted stream, on a fake clock that each
    /// line sets to its own timestamp.
    private static func runRealPull(lines: [(TimeInterval, String)], tagsBody: String = "{\"models\":[]}",
                                    tagsStatus: Int = 200, streamError: Error? = nil,
                                    recordRequest: ((URLRequest) -> Void)? = nil,
                                    streamCalls: ((Int) -> Void)? = nil) -> PullRun {
        let server = ScriptedServer()
        server.tagsBody = tagsBody
        server.tagsStatus = tagsStatus
        let clock = FakeClock()
        clock.now = lines.first?.0 ?? 0
        var run = PullRun()
        var calls = 0
        let stream: OllamaInstaller.PullStreaming = { request, _, onLine in
            calls += 1
            recordRequest?(request)
            for (time, text) in lines {
                clock.now = time
                if !onLine(Data(text.utf8)) { break }
            }
            if let streamError { throw streamError }
            return 200
        }
        do {
            let outcome = try OllamaInstaller.pullModel(
                pulledName, backend: server.backend, stream: stream, clock: { clock.now },
                progress: { reading in
                    run.reports.append(reading)
                    run.reportTimes.append(clock.now)
                })
            run.outcome = .success(outcome)
        } catch {
            run.outcome = .failure(error)
        }
        streamCalls?(calls)
        return run
    }

    private static func failureText(_ run: PullRun) -> String? {
        guard case .failure(let error)? = run.outcome else { return nil }
        return InstallerEngine.failure(forLocal: error).message
    }

    private static func checkPullDetails(_ reporter: SelfTestReporter) {
        print("--- /api/pull progress ---")
        var request: URLRequest?
        let run = runRealPull(lines: backwardJumpLines, recordRequest: { request = $0 })
        let body = request?.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        reporter.record("the pull is POST /api/pull with the model and stream:true",
                        request?.httpMethod == "POST" && request?.url?.path == "/api/pull"
                            && body?["model"] as? String == pulledName && body?["stream"] as? Bool == true)
        let final = run.reports.last
        reporter.record("progress sums every layer's own total",
                        final?.expected == weightsTotal + paramsTotal && final?.completed == weightsTotal + paramsTotal,
                        String(describing: final))
        reporter.record("before the second layer is announced, the total is the first layer's alone",
                        run.reports.contains { $0.expected == weightsTotal })
        let afterRestart = run.reports.drop { $0.completed < 4_000_000 }
        reporter.record("each layer holds its best, so after the restart the row still reads 4 MB, not 1 MB",
                        !afterRestart.isEmpty && afterRestart.allSatisfy { $0.completed >= 4_000_000 })

        // Throttle: 400 lines in two seconds.
        var dense: [(TimeInterval, String)] = [(0, line("pulling weights", digest: weights, total: weightsTotal))]
        for step in 1...400 {
            dense.append((Double(step) * 0.005, line("pulling weights", digest: weights, total: weightsTotal,
                                                     completed: UInt64(step) * 10_000)))
        }
        dense.append((2.1, line("success")))
        let throttled = runRealPull(lines: dense)
        let times = throttled.reportTimes.dropLast()
        let busiest = times.map { start in times.filter { $0 >= start && $0 < start + 1 }.count }.max() ?? 0
        reporter.record("progress reports are throttled to at most four a second",
                        busiest <= 4 && throttled.reports.count >= 3,
                        "busiest second \(busiest), \(throttled.reports.count) reports for 401 lines")

        // Stalls: fourteen minutes of no movement is patience; sixteen is a stall.
        func stalled(minutes: Int) -> [(TimeInterval, String)] {
            var lines: [(TimeInterval, String)] = [(0, line("pulling weights", digest: weights, total: weightsTotal,
                                                            completed: 3_000_000))]
            for minute in 1...minutes {
                lines.append((Double(minute) * 60, line("pulling weights", digest: weights, total: weightsTotal,
                                                        completed: 3_000_000)))
            }
            let end = Double(minutes) * 60 + 1
            lines.append((end, line("pulling weights", digest: weights, total: weightsTotal, completed: weightsTotal)))
            lines.append((end + 1, line("success")))
            return lines
        }
        let patient = runRealPull(lines: stalled(minutes: 14))
        var patientInstalled = false
        if case .success(.installed)? = patient.outcome { patientInstalled = true }
        reporter.record("a fourteen-minute stall with no bytes moving is not a failure", patientInstalled)

        let dead = runRealPull(lines: stalled(minutes: 16))
        var deadFailure: InstallerFailure?
        if case .failure(let error)? = dead.outcome { deadFailure = InstallerEngine.failure(forLocal: error) }
        reporter.record("sixteen minutes with no bytes moving at all is a stall, said as one",
                        deadFailure?.message.contains("made no progress for 15 minutes") == true
                            && deadFailure?.isRetryable == false,
                        deadFailure?.message ?? "no failure")

        let silent = runRealPull(lines: [(0, line("pulling manifest"))],
                                 streamError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        reporter.record("a stream that goes silent past the idle bound is the same stall",
                        failureText(silent)?.contains("made no progress") == true, failureText(silent) ?? "")

        let refused = runRealPull(lines: [(0, line("pulling manifest")),
                                          (1, "{\"error\":\"pull model manifest: fixture file does not exist\"}")])
        reporter.record("an error line fails the row with Ollama's own text",
                        failureText(refused)?.contains("pull model manifest: fixture file does not exist") == true,
                        failureText(refused) ?? "")

        let cut = runRealPull(lines: [(0, line("pulling weights", digest: weights, total: weightsTotal,
                                                completed: 2_000_000))])
        var cutRetryable = false
        if case .failure(let error)? = cut.outcome { cutRetryable = InstallerEngine.failure(forLocal: error).isRetryable }
        reporter.record("a stream that ends before success is retried, since Ollama resumes its blobs",
                        cutRetryable, failureText(cut) ?? "")

        var presentCalls = -1
        let present = runRealPull(
            lines: backwardJumpLines,
            tagsBody: "{\"models\":[{\"name\":\"\(pulledName)\",\"size\":4200000,\"capabilities\":[\"completion\"]}]}",
            streamCalls: { presentCalls = $0 })
        var alreadyThere = false
        if case .success(.alreadyInstalled)? = present.outcome { alreadyThere = true }
        reporter.record("a model Ollama already lists is not pulled again", alreadyThere && presentCalls == 0)

        var blindCalls = -1
        let blind = runRealPull(lines: backwardJumpLines, tagsStatus: 500, streamCalls: { blindCalls = $0 })
        reporter.record("an unreadable catalog refuses to guess and pulls nothing",
                        failureText(blind) != nil && blindCalls == 0, failureText(blind) ?? "")

        let bytesText = InstallProgress.statusText(
            for: BootstrapComponentRecord(id: "ollama-model:\(pulledName)", title: pulledName, phase: .installing),
            activity: .bytes(InstallerByteProgress(completed: 340_000_000, expected: 570_000_000)))
        reporter.record("an Ollama row shows real bytes in the progress channel's own words",
                        bytesText == "340 MB of 570 MB", bytesText)
    }

    // MARK: - Negative controls

    private static func checkNegativeControls(scratch: URL, _ reporter: SelfTestReporter) {
        // (a) The allowlist is applied to the first host only; the real final-response check still runs.
        let firstHostOnly = Subject(
            resolve: { http in
                var url = OllamaInstaller.officialDMGEndpoint
                try OllamaInstaller.validateHop(url)
                for _ in 0...OllamaInstaller.maximumRedirects {
                    let response = try http.head(url, 30)
                    guard (300...399).contains(response.statusCode) else {
                        return try OllamaInstaller.validateFinalResponse(response, requested: url)
                    }
                    guard let next = OllamaInstaller.redirectTarget(of: response, from: url) else { break }
                    url = next
                }
                throw OllamaInstaller.InstallerError.invalidPublishedResponse("mutant: too many redirects")
            },
            verify: realSubject.verify,
            pull: realSubject.pull)
        requireCaught(reporter, mutant: "allowlist that checks only the first host", by: anyHopCheck) {
            checkContract(firstHostOnly, scratch: scratch, $0)
        }

        // (b) Bundle id and codesign --verify, but no Team ID pin.
        let noTeamPin = Subject(
            resolve: realSubject.resolve,
            verify: { app, runner in
                try OllamaInstaller.verifyBundle(at: app, fileManager: .default)
                try OllamaInstaller.verifySignature(at: app, commandRunner: runner)
            },
            pull: realSubject.pull)
        requireCaught(reporter, mutant: "app check with no Team ID pin", by: teamIDCheck) {
            checkContract(noTeamPin, scratch: scratch, $0)
        }

        // (c) Each layer's raw latest `completed`, summed and throttled like the real one, so it goes backward.
        let rawCompleted = Subject(
            resolve: realSubject.resolve,
            verify: realSubject.verify,
            pull: { lines in
                var run = PullRun()
                var latest: [String: UInt64] = [:]
                var totals: [String: UInt64] = [:]
                var lastAt: TimeInterval?
                for (time, text) in lines {
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                    else { continue }
                    if object["status"] as? String == "success" {
                        run.outcome = .success(.installed(pulledName))
                        break
                    }
                    guard let digest = object["digest"] as? String,
                          let total = (object["total"] as? NSNumber)?.uint64Value else { continue }
                    totals[digest] = total
                    if let completed = (object["completed"] as? NSNumber)?.uint64Value { latest[digest] = completed }
                    if let at = lastAt, time - at < OllamaInstaller.pullProgressInterval { continue }
                    lastAt = time
                    run.reports.append(InstallerByteProgress(completed: latest.values.reduce(0, +),
                                                             expected: totals.values.reduce(0, +)))
                    run.reportTimes.append(time)
                }
                return run
            })
        requireCaught(reporter, mutant: "pull progress that reports raw completed", by: monotonicCheck) {
            checkContract(rawCompleted, scratch: scratch, $0)
        }
    }

    /// Runs `contract` on a throwaway reporter (its lines print as `mutant passes` / `caught`, so the log
    /// never shows a bare FAIL for an expected failure) and records on the real reporter whether the named
    /// assertion caught the mutant.
    private static func requireCaught(_ reporter: SelfTestReporter, mutant: String, by check: String,
                                      _ contract: (SelfTestReporter) -> Void) {
        print("--- negative control: \(mutant) (must be caught) ---")
        let probe = SelfTestReporter(successLabel: "mutant passes", failureLabel: "caught")
        contract(probe)
        let caught = probe.results.contains { $0.name == check && !$0.ok }
        reporter.record("negative control: the \(mutant) is caught by \"\(check)\"", caught)
    }

    private static func scratchDirectory(_ reporter: SelfTestReporter) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-ollama-installer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            reporter.record("scratch fixture setup", false, String(describing: error))
            return nil
        }
    }
}
