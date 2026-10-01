import Foundation

/// The side-effecting Ollama part of setup: `LMStudioInstaller`'s twin, with the same trust model.
///
/// Like LM Studio's, this is a mechanism and not a queue. `InstallerEngine` owns consent, progress, retry and
/// persistence; each function here performs one bounded operation and throws the real failure.
///
/// **The trust chain, as measured on Ben's Mac (Mac probe B2/B3, 2026-09-30).** `ollama.com/download/Ollama.dmg`
/// answers 307 to github.com, which answers 302 twice, the second time to a signed
/// release-assets.githubusercontent.com URL that answers 200 `application/octet-stream`. So:
/// - every hop is checked BEFORE it is requested: HTTPS, and a host on `allowedHosts` exactly. LM Studio's
///   endpoint never leaves its own domain, so it only checks the final URL; this chain crosses three hosts,
///   and a check of the final host alone would follow a redirect anywhere as long as it came back;
/// - the final response must be a disk image type with a positive Content-Length, and the GET must return
///   the same URL and the same length the HEAD did;
/// - the mounted app must be `com.electron.ollama`, pass `codesign --verify --deep --strict`, AND be signed by
///   Team ID `3MU9H2V9Y9`. The Team ID pin is Ollama-only: a signature that verifies proves only that SOME
///   Developer ID signed the bundle, and the pin is what says it was Ollama's;
/// - an existing `/Applications/Ollama.app` is never overwritten.
///
/// **A fresh install is not usable until the user approves a macOS prompt** (Mac probe B3). Ollama asks for
/// Touch ID or a password to install its command-line tool and does not start its server until answered.
/// ViddyDictate never automates that prompt: `ensureServerReady` opens the app by PATH and waits, reporting
/// the wait as its own state rather than as a failure.
///
/// Every side effect is injectable (`HTTP`, `CommandRunner`, `PullStreaming`, the clock and the sleep), so the
/// deterministic gate never touches the network, `hdiutil`, `open` or `codesign`.
enum OllamaInstaller {
    static let officialDMGEndpoint = URL(string: "https://ollama.com/download/Ollama.dmg")!
    static let appName = "Ollama.app"
    static let bundleIdentifier = "com.electron.ollama"
    /// Infra Technologies, Inc, read from `codesign -dv` on the official 0.35.0 DMG (Mac probe B3).
    static let teamIdentifier = "3MU9H2V9Y9"
    /// The three hosts of the measured chain, exactly. No suffix match: a look-alike subdomain is not Ollama.
    static let allowedHosts: Set<String> = ["ollama.com", "github.com", "release-assets.githubusercontent.com"]
    /// The measured chain is three redirects. A little room for GitHub to add one, none for a loop.
    static let maximumRedirects = 5
    /// The same types `LMStudioInstaller` accepts. The measured final response is `application/octet-stream`.
    static let acceptedMIMEs = ["application/octet-stream", "application/x-apple-diskimage"]

    /// How long the installer waits for the user to answer Ollama's macOS prompt. Long, because a person may
    /// be reading it or fetching their password; bounded, because a row must never hang forever.
    static let approvalWaitBound: TimeInterval = 10 * 60
    static let approvalPollInterval: TimeInterval = 1
    /// An app that was approved on an earlier launch still takes a few seconds to bring its server up. The
    /// prompt state is only announced after this, so a plain slow start does not ask the user to approve
    /// something that is not on screen.
    static let approvalAnnounceDelay: TimeInterval = 3
    /// A pull whose bytes have not moved at all for this long is stalled. Minutes of apparent stall are
    /// normal (the measured 6.58 GB pull restarted parts and rode out DNS failures by itself), so this is
    /// deliberately far longer than any of them.
    static let pullIdleBound: TimeInterval = 15 * 60
    /// At most four progress reports a second. Ollama emits a line every few hundred KB per layer (46,404
    /// lines for one measured pull), far more than any row can usefully redraw.
    static let pullProgressInterval: TimeInterval = 0.25

    /// Said up front, wherever Ollama is offered for install (spec D8).
    static let adminPromptWarning =
        "macOS will ask for Touch ID or your password so Ollama can install its command-line tool; approve it."
    /// The actionable end of an unanswered prompt. The row does not retry this on its own: waiting again
    /// would only ask the same question of a user who is not there.
    static let approvalTimeoutMessage = "Open Ollama and approve its macOS prompt, then choose Try again."

    typealias CommandResult = LMStudioInstaller.CommandResult
    typealias CommandRunner = LMStudioInstaller.CommandRunner
    typealias DMGSource = LMStudioInstaller.DMGSource
    typealias AppInstallOutcome = LMStudioInstaller.AppInstallOutcome
    typealias ModelInstallOutcome = LMStudioInstaller.ModelInstallOutcome

    enum ReadyOutcome: Equatable {
        case alreadyRunning
        case started
    }

    enum InstallerError: Error, CustomStringConvertible {
        case invalidModelIdentifier(String)
        case invalidPublishedResponse(String)
        case network(String)
        case httpStatus(Int)
        case command(String, CommandResult)
        case invalidDMG(String)
        case invalidMountedImage(String)
        case invalidApplication(String)
        case destinationExists(URL)
        /// The user did not answer Ollama's macOS prompt within `approvalWaitBound`.
        case approvalTimedOut
        /// Ollama is on this Mac in a form ViddyDictate does not start (a CLI-only install).
        case serverNotRunning(String)
        /// An `{"error": ...}` line from `/api/pull`, carried verbatim.
        case pullFailed(model: String, reason: String)
        case pullStalled(model: String)
        case pullIncomplete(model: String)
        case operation(String)

        var description: String {
            switch self {
            case let .invalidModelIdentifier(id):
                return "invalid Ollama model identifier: \(id)"
            case let .invalidPublishedResponse(reason):
                return "Ollama download response is unverified: \(reason)"
            case let .network(reason):
                return "Ollama download request failed: \(reason)"
            case let .httpStatus(status):
                return "Ollama request returned HTTP \(status)"
            case let .command(name, result):
                var text = "\(name) failed with status \(result.status)"
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stdout.isEmpty { text += "; stdout: \(stdout)" }
                if !stderr.isEmpty { text += "; stderr: \(stderr)" }
                return text
            case let .invalidDMG(reason):
                return "Ollama DMG failed verification: \(reason)"
            case let .invalidMountedImage(reason):
                return "Ollama mounted image failed verification: \(reason)"
            case let .invalidApplication(reason):
                return "Ollama application failed verification: \(reason)"
            case let .destinationExists(url):
                return "refusing to overwrite existing Ollama application at \(url.path)"
            case .approvalTimedOut:
                return OllamaInstaller.approvalTimeoutMessage
            case let .serverNotRunning(reason):
                return reason
            case let .pullFailed(model, reason):
                return "Ollama could not download \(model): \(reason)"
            case let .pullStalled(model):
                return "Ollama's download of \(model) made no progress for "
                    + "\(Int(OllamaInstaller.pullIdleBound / 60)) minutes. Check the network, then choose Try again."
            case let .pullIncomplete(model):
                return "Ollama's download of \(model) stopped before it finished"
            case let .operation(reason):
                return reason
            }
        }
    }

    // MARK: - HTTP seam

    /// The two requests the download makes. Neither follows a redirect on its own: a 3xx comes back as the
    /// response, so `resolveOfficialDMG` sees, and checks, every hop.
    struct HTTP {
        /// One HEAD. Transport failures throw `InstallerError.network`.
        let head: (_ url: URL, _ timeout: TimeInterval) throws -> HTTPURLResponse
        /// One GET whose body is written to `destination`, which does not exist yet.
        let download: (_ url: URL, _ destination: URL, _ timeout: TimeInterval) throws -> HTTPURLResponse

        static let live = HTTP(head: OllamaInstaller.liveHead, download: OllamaInstaller.liveDownload)
    }

    // MARK: - Published DMG resolution

    /// Follows the official endpoint hop by hop. Each hop's URL is checked against the allowlist BEFORE it is
    /// requested, so a redirect off the list is refused without a byte going to its host.
    static func resolveOfficialDMG(http: HTTP = .live, timeout: TimeInterval = 30) throws -> DMGSource {
        var url = officialDMGEndpoint
        for _ in 0...maximumRedirects {
            try validateHop(url)
            let response = try http.head(url, timeout)
            switch response.statusCode {
            case 300...399:
                guard let next = redirectTarget(of: response, from: url) else {
                    throw InstallerError.invalidPublishedResponse(
                        "HTTP \(response.statusCode) from \(origin(of: url)) has no usable Location")
                }
                url = next
            case 200...299:
                return try validateFinalResponse(response, requested: url)
            default:
                throw InstallerError.httpStatus(response.statusCode)
            }
        }
        throw InstallerError.invalidPublishedResponse("more than \(maximumRedirects) redirects")
    }

    /// HTTPS, no credentials, the default port, and a host on `allowedHosts` exactly.
    static func isAllowedHop(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    static func validateHop(_ url: URL) throws {
        guard isAllowedHop(url) else {
            throw InstallerError.invalidPublishedResponse(
                "\(origin(of: url)) is not an HTTPS Ollama download host")
        }
    }

    /// A redirect's Location, resolved against the URL that answered (it may be relative).
    static func redirectTarget(of response: HTTPURLResponse, from url: URL) -> URL? {
        guard let location = response.value(forHTTPHeaderField: "Location")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    /// The 200 at the end of the chain. The measured final URL is a signed release-asset path with no `.dmg`
    /// suffix, so the file type is read from its `Content-Disposition` (`filename=Ollama.dmg`) when the path
    /// does not carry it.
    static func validateFinalResponse(_ response: HTTPURLResponse, requested: URL) throws -> DMGSource {
        let url = response.url ?? requested
        guard isAllowedHop(url) else {
            throw InstallerError.invalidPublishedResponse(
                "final URL \(origin(of: url)) is not an HTTPS Ollama download host")
        }
        guard url.pathExtension.lowercased() == "dmg" || dispositionNamesDiskImage(response) else {
            throw InstallerError.invalidPublishedResponse("the final response does not name a .dmg")
        }
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let mime, acceptedMIMEs.contains(mime) else {
            throw InstallerError.invalidPublishedResponse("content type is \(mime ?? "missing")")
        }
        guard let length = response.value(forHTTPHeaderField: "Content-Length"),
              let bytes = Int64(length.trimmingCharacters(in: .whitespaces)), bytes > 0 else {
            throw InstallerError.invalidPublishedResponse("positive Content-Length is missing")
        }
        return DMGSource(url: url, expectedBytes: bytes)
    }

    private static func dispositionNamesDiskImage(_ response: HTTPURLResponse) -> Bool {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
              let marker = disposition.range(of: "filename=") else { return false }
        let name = disposition[marker.upperBound...]
            .split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).hasSuffix(".dmg")
    }

    /// Scheme and host only. The last hop is a signed URL, and its query must not reach a log or a row.
    static func origin(of url: URL) -> String {
        "\(url.scheme ?? "?")://\(url.host ?? "?")"
    }

    // MARK: - Download

    /// `LMStudioInstaller.downloadDMG`'s rules: a per-attempt `.part` beside the destination, the GET must be
    /// the verified HEAD source, and the byte count must match before the file is kept.
    static func downloadDMG(source: DMGSource,
                            to destination: URL,
                            http: HTTP = .live,
                            fileManager: FileManager = .default,
                            timeout: TimeInterval = 900) throws -> URL {
        if fileManager.fileExists(atPath: destination.path) {
            throw InstallerError.destinationExists(destination)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(".Ollama-\(UUID().uuidString).dmg.part")
        defer { try? fileManager.removeItem(at: partial) }

        let response = try http.download(source.url, partial, timeout)
        guard (200..<300).contains(response.statusCode) else {
            throw InstallerError.httpStatus(response.statusCode)
        }
        let returned = try validateFinalResponse(response, requested: source.url)
        guard returned.url == source.url, returned.expectedBytes == source.expectedBytes else {
            throw InstallerError.invalidDMG(
                "GET answered from \(origin(of: returned.url)) with \(returned.expectedBytes) bytes,"
                    + " not the verified HEAD source")
        }
        guard fileManager.fileExists(atPath: partial.path) else {
            throw InstallerError.network("download returned no file")
        }
        let actual = (try fileManager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value
        guard actual == source.expectedBytes else {
            throw InstallerError.invalidDMG("downloaded \(actual ?? 0) bytes; expected \(source.expectedBytes)")
        }
        try fileManager.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: - DMG attach, verify, stage, detach

    static func installDMG(at dmg: URL,
                           expectedBytes: Int64,
                           applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                           fileManager: FileManager = .default,
                           commandRunner: @escaping CommandRunner = LMStudioInstaller.runCommand)
        throws -> AppInstallOutcome {
        let destination = applicationsDirectory.appendingPathComponent(appName, isDirectory: true)

        // First, as in LM Studio's: an existing install is the user's, and even a newer DMG must not replace it.
        if fileManager.fileExists(atPath: destination.path) {
            return .alreadyInstalled(destination)
        }
        guard fileManager.fileExists(atPath: dmg.path) else {
            throw InstallerError.invalidDMG("file does not exist at \(dmg.path)")
        }
        let size = (try fileManager.attributesOfItem(atPath: dmg.path)[.size] as? NSNumber)?.int64Value
        guard size == expectedBytes else {
            throw InstallerError.invalidDMG("file size is \(size ?? 0); expected \(expectedBytes)")
        }
        let imageInfo = try commandRunner("/usr/bin/hdiutil", ["imageinfo", "-plist", dmg.path])
        guard imageInfo.succeeded else { throw InstallerError.command("hdiutil imageinfo", imageInfo) }

        let attach = try commandRunner("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard attach.succeeded else { throw InstallerError.command("hdiutil attach", attach) }
        guard let mountPoint = LMStudioInstaller.mountPoint(from: attach.stdout) else {
            throw InstallerError.invalidMountedImage("hdiutil attach returned no mount point")
        }

        var primaryError: Error?
        var copied = false
        do {
            guard let mountedApp = LMStudioInstaller.findApplication(named: appName, under: mountPoint,
                                                                     fileManager: fileManager) else {
                throw InstallerError.invalidMountedImage("\(appName) was not found on the mounted image")
            }
            try verifyApplication(at: mountedApp, fileManager: fileManager, commandRunner: commandRunner)
            try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
            let staging = applicationsDirectory.appendingPathComponent(
                ".Ollama.app.installing-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: mountedApp, to: staging)
            try verifyApplication(at: staging, fileManager: fileManager, commandRunner: commandRunner)
            if fileManager.fileExists(atPath: destination.path) {
                throw InstallerError.destinationExists(destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            copied = true
        } catch {
            primaryError = error
        }

        do {
            let detach = try commandRunner("/usr/bin/hdiutil", ["detach", mountPoint.path])
            if !detach.succeeded, primaryError == nil {
                primaryError = InstallerError.command("hdiutil detach", detach)
            }
        } catch {
            if primaryError == nil { primaryError = error }
        }
        if let primaryError { throw primaryError }
        guard copied else { throw InstallerError.operation("Ollama DMG copy did not complete") }
        return .installed(destination)
    }

    /// The whole identity check: bundle, signature, and the Team ID pin. Split into its three parts so the
    /// gate can prove the pin is load-bearing on its own.
    static func verifyApplication(at app: URL, fileManager: FileManager,
                                  commandRunner: @escaping CommandRunner) throws {
        try verifyBundle(at: app, fileManager: fileManager)
        try verifySignature(at: app, commandRunner: commandRunner)
        try verifyTeamIdentifier(at: app, commandRunner: commandRunner)
    }

    /// `CFBundleIdentifier` is Ollama's, and the executable it names is present. The executable's name is
    /// read rather than pinned: it is Electron's product name, which the signature already covers.
    static func verifyBundle(at app: URL, fileManager: FileManager) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = root as? [String: Any] else {
            throw InstallerError.invalidApplication("Info.plist is missing or unreadable")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw InstallerError.invalidApplication("bundle identifier is not \(bundleIdentifier)")
        }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"),
              fileManager.isExecutableFile(
                atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw InstallerError.invalidApplication("the signed executable is missing")
        }
    }

    static func verifySignature(at app: URL, commandRunner: @escaping CommandRunner) throws {
        let codesign = try commandRunner("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard codesign.succeeded else { throw InstallerError.command("codesign --verify", codesign) }
    }

    /// `codesign -dv` writes its details to STDERR; `TeamIdentifier=` must name Ollama's team.
    static func verifyTeamIdentifier(at app: URL, commandRunner: @escaping CommandRunner) throws {
        let details = try commandRunner("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard details.succeeded else { throw InstallerError.command("codesign -dv", details) }
        let found = teamIdentifier(inCodesignOutput: details.stderr + "\n" + details.stdout)
        guard found == teamIdentifier else {
            throw InstallerError.invalidApplication(
                "signed by Team ID \(found ?? "none"), not Ollama's \(teamIdentifier)")
        }
    }

    /// The value of the `TeamIdentifier=` line, or nil when there is none or it reads `not set` (ad hoc).
    static func teamIdentifier(inCodesignOutput output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(trimmed.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value.lowercased() == "not set" ? nil : value
        }
        return nil
    }

    // MARK: - Start, and wait for the user's approval

    /// Opens the app by PATH in the background. Never by name: straight after the copy LaunchServices has not
    /// registered it, and `open -a Ollama` fails with "Unable to find application" (Mac probe B3).
    static func openApplication(atPath path: String, commandRunner: @escaping CommandRunner) throws {
        let opened = try commandRunner("/usr/bin/open", ["-g", path])
        guard opened.succeeded else { throw InstallerError.command("open -g \(path)", opened) }
    }

    /// Makes Ollama's server answer `/api/version`, through `OllamaBackend`'s own transport.
    ///
    /// Already answering is done. An installed desktop app is opened by path and waited for, for up to
    /// `bound`: a fresh install sits on its macOS prompt until the user answers, so once the wait passes
    /// `approvalAnnounceDelay` the row reports `onAwaitingApproval` - a state, not a failure. Only the full
    /// bound ends it, with `approvalTimeoutMessage`. A CLI-only install is a daemon the user runs, so it is
    /// never started here.
    static func ensureServerReady(backend: OllamaBackend = OllamaBackend(),
                                  commandRunner: @escaping CommandRunner = LMStudioInstaller.runCommand,
                                  clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                  sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                  bound: TimeInterval = approvalWaitBound,
                                  pollInterval: TimeInterval = approvalPollInterval,
                                  onAwaitingApproval: () -> Void = {}) throws -> ReadyOutcome {
        if backend.serverResponds() { return .alreadyRunning }
        guard let appPath = backend.installedAppPath else {
            if backend.isInstalled() {
                throw InstallerError.serverNotRunning(
                    "Ollama is installed as a command-line tool, but its server is not running. "
                        + "Start it with ollama serve, then choose Try again.")
            }
            throw InstallerError.serverNotRunning("Ollama is not installed")
        }
        try openApplication(atPath: appPath, commandRunner: commandRunner)
        let started = clock()
        var announced = false
        while true {
            if backend.serverResponds() { return .started }
            let waited = clock() - started
            if waited >= bound { throw InstallerError.approvalTimedOut }
            if !announced && waited >= approvalAnnounceDelay {
                announced = true
                onAwaitingApproval()
            }
            sleep(pollInterval)
        }
    }

    // MARK: - Model pull

    /// POSTs `request` and hands each newline-delimited line to `onLine` as it arrives; `onLine` returning
    /// false ends the stream. Returns the HTTP status. `idleTimeout` bounds a stream that sends nothing.
    typealias PullStreaming = (_ request: URLRequest, _ idleTimeout: TimeInterval,
                               _ onLine: @escaping (Data) -> Bool) throws -> Int

    /// `POST /api/pull`, streamed, with real byte progress (see `OllamaPullProgress` for the arithmetic).
    ///
    /// A model the catalog already lists is left alone: a pull of a present tag re-checks its manifest, and a
    /// moving tag (the measured `gemma4:e4b` was republished the day of the probe) would download gigabytes
    /// the user already has a working copy of. An unreadable catalog is refused rather than guessed at, as
    /// `lms ls` failing is in LM Studio's.
    static func pullModel(_ modelID: String,
                          backend: OllamaBackend = OllamaBackend(),
                          stream: PullStreaming = livePullStream,
                          clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                          idleBound: TimeInterval = pullIdleBound,
                          minimumInterval: TimeInterval = pullProgressInterval,
                          progress: @escaping (InstallerByteProgress) -> Void = { _ in })
        throws -> ModelInstallOutcome {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == modelID,
              !modelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InstallerError.invalidModelIdentifier(modelID)
        }
        guard let installed = backend.installedModels() else {
            throw InstallerError.operation(
                "Ollama's model list did not answer; refusing to guess whether \(modelID) is installed")
        }
        let wanted = OllamaBackend.canonicalModelName(modelID)
        if installed.contains(where: { OllamaBackend.canonicalModelName($0.ref.modelID) == wanted }) {
            return .alreadyInstalled(modelID)
        }
        guard let url = backend.endpoint("api/pull"),
              let body = try? JSONSerialization.data(withJSONObject: ["model": modelID, "stream": true],
                                                     options: [.sortedKeys]) else {
            throw InstallerError.operation("could not build the Ollama pull request for \(modelID)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var tracker = OllamaPullProgress(startedAt: clock(), idleBound: idleBound,
                                         minimumInterval: minimumInterval)
        var terminal: OllamaPullProgress.Event?
        let status: Int
        do {
            status = try stream(request, idleBound) { line in
                let event = tracker.consume(line, at: clock())
                switch event {
                case .quiet:
                    return true
                case .progress(let reading):
                    progress(reading)
                    return true
                case .success, .failed, .stalled:
                    terminal = event
                    return false
                }
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                throw InstallerError.pullStalled(model: modelID)
            }
            if let own = error as? InstallerError { throw own }
            throw InstallerError.network("Ollama pull of \(modelID): \(error.localizedDescription)")
        }
        switch terminal {
        case .success?:
            if let final = tracker.finalReading { progress(final) }
            return .installed(modelID)
        case .failed(let reason)?:
            throw InstallerError.pullFailed(model: modelID, reason: reason)
        case .stalled?:
            throw InstallerError.pullStalled(model: modelID)
        default:
            guard (200..<300).contains(status) else { throw InstallerError.httpStatus(status) }
            // Ollama resumes the blobs it already has, so this one is worth the engine's retry.
            throw InstallerError.pullIncomplete(model: modelID)
        }
    }

    // MARK: - Live transport

    /// Refuses every redirect, so the 3xx itself is what the task completes with and `resolveOfficialDMG`
    /// checks the next hop before anything is sent to it.
    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    private static func liveHead(_ url: URL, _ timeout: TimeInterval) throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var requestError: Error?
        let task = liveSession.dataTask(with: request) { _, rawResponse, error in
            response = rawResponse as? HTTPURLResponse
            requestError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw InstallerError.network("timed out resolving \(origin(of: url))")
        }
        if let requestError { throw InstallerError.network(requestError.localizedDescription) }
        guard let response else { throw InstallerError.network("\(origin(of: url)) returned no HTTP response") }
        return response
    }

    private static func liveDownload(_ url: URL, _ destination: URL,
                                     _ timeout: TimeInterval) throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var requestError: Error?
        var moveError: Error?
        let task = liveSession.downloadTask(with: request) { temporaryURL, rawResponse, error in
            response = rawResponse as? HTTPURLResponse
            requestError = error
            if error == nil, let temporaryURL {
                // URLSession removes its temporary file when this returns; take it before signalling.
                do { try FileManager.default.moveItem(at: temporaryURL, to: destination) }
                catch { moveError = error }
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw InstallerError.network("timed out downloading from \(origin(of: url))")
        }
        if let requestError { throw InstallerError.network(requestError.localizedDescription) }
        if let moveError {
            throw InstallerError.network("could not retain the downloaded DMG: \(moveError.localizedDescription)")
        }
        guard let response else { throw InstallerError.network("download returned no HTTP response") }
        return response
    }

    /// Splits the pull's body into lines as it streams. The delegate queue is serial, so `onLine` (and the
    /// tracker it drives) runs on one thread at a time; the caller reads the result after `done`.
    private final class PullStreamReader: NSObject, URLSessionDataDelegate {
        let onLine: (Data) -> Bool
        let done = DispatchSemaphore(value: 0)
        private(set) var status: Int?
        private(set) var failure: Error?
        private var buffer = Data()
        private var stoppedByReader = false

        init(onLine: @escaping (Data) -> Bool) { self.onLine = onLine }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !stoppedByReader else { return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty && !onLine(line) {
                    stoppedByReader = true
                    dataTask.cancel()
                    return
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if !stoppedByReader {
                if !buffer.isEmpty { _ = onLine(buffer) }
                failure = error
            }
            buffer.removeAll()
            done.signal()
        }
    }

    static let livePullStream: PullStreaming = { request, idleTimeout, onLine in
        let reader = PullStreamReader(onLine: onLine)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        // The request timeout is URLSession's IDLE timer: it restarts whenever bytes arrive.
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        var timed = request
        timed.timeoutInterval = idleTimeout
        session.dataTask(with: timed).resume()
        reader.done.wait()
        if let failure = reader.failure { throw failure }
        return reader.status ?? 0
    }
}

/// Overall byte progress for one `/api/pull` stream, from its lines. Pure: lines and timestamps in, events out.
///
/// The rules come from a measured pull (Mac probe B5), not from Ollama's docs:
/// - `total` is PER LAYER, so the total is the sum over every layer seen so far;
/// - `completed` is NOT monotonic: a stalled part restarts and a layer's counter jumps backward (4.04 GB to
///   1.03 GB was measured). Each layer therefore reports the most it has ever shown, so the overall number
///   never goes backward;
/// - updates are throttled to `minimumInterval`;
/// - minutes of no movement are not a failure. Only `idleBound` with no byte movement at all is, and a counter
///   moving BACKWARD still counts as movement: bytes are flowing, they are just being fetched again;
/// - `{"status":"success"}` completes; a line with `error` fails with Ollama's own text.
struct OllamaPullProgress {
    enum Event: Equatable {
        /// Nothing to report: the line changed nothing, or a report would break the throttle.
        case quiet
        case progress(InstallerByteProgress)
        case success
        case failed(String)
        case stalled
    }

    let idleBound: TimeInterval
    let minimumInterval: TimeInterval
    private var layerTotals: [String: UInt64] = [:]
    private var layerBest: [String: UInt64] = [:]
    private var layerLatest: [String: UInt64] = [:]
    private var lastStatus: String?
    private var lastMovement: TimeInterval
    private var lastReportAt: TimeInterval?
    private var lastReported: InstallerByteProgress?

    init(startedAt: TimeInterval, idleBound: TimeInterval = OllamaInstaller.pullIdleBound,
         minimumInterval: TimeInterval = OllamaInstaller.pullProgressInterval) {
        self.idleBound = idleBound
        self.minimumInterval = minimumInterval
        self.lastMovement = startedAt
    }

    /// Bytes so far over bytes known so far. `expected` is nil until a layer has announced its size.
    var reading: InstallerByteProgress {
        InstallerByteProgress(completed: layerBest.values.reduce(0, &+),
                              expected: layerTotals.isEmpty ? nil : layerTotals.values.reduce(0, &+))
    }

    /// The reading once Ollama says `success`: every layer is on disk, including those whose last line
    /// carried only a `total`.
    var finalReading: InstallerByteProgress? {
        reading.expected.map { InstallerByteProgress(completed: $0, expected: $0) }
    }

    mutating func consume(_ line: Data, at now: TimeInterval) -> Event {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return idle(at: now) ? .stalled : .quiet
        }
        if let error = object["error"] as? String {
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(text.isEmpty ? "Ollama reported an error without any text" : text)
        }
        let status = object["status"] as? String
        if status == "success" { return .success }
        if status != lastStatus {
            // "pulling <layer>", "verifying sha256 digest", "writing manifest": each is Ollama moving on.
            lastStatus = status
            lastMovement = now
        }
        if let total = Self.unsigned(object["total"]), total > 0 {
            let layer = (object["digest"] as? String) ?? status ?? "layer"
            if layerTotals[layer] == nil { lastMovement = now }
            layerTotals[layer] = total
            if let raw = Self.unsigned(object["completed"]) {
                let completed = min(raw, total)
                if layerLatest[layer] != completed {
                    layerLatest[layer] = completed
                    lastMovement = now
                }
                layerBest[layer] = max(layerBest[layer] ?? 0, completed)
            }
        }
        if idle(at: now) { return .stalled }

        let current = reading
        guard current.expected != nil, current != lastReported else { return .quiet }
        if let at = lastReportAt, now - at < minimumInterval { return .quiet }
        lastReportAt = now
        lastReported = current
        return .progress(current)
    }

    private func idle(at now: TimeInterval) -> Bool { now - lastMovement > idleBound }

    /// `OllamaCatalog.integer`'s rules (a JSON boolean or fraction is not a byte count), non-negative only.
    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let signed = OllamaCatalog.integer(value), signed >= 0 else { return nil }
        return UInt64(signed)
    }
}
