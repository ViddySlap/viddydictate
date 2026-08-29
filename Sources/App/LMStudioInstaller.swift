import Foundation

/// The side-effecting LM Studio part of first-run setup.
///
/// This is deliberately a mechanism, not an installer queue. The setup engine owns consent,
/// progress, retry, cancellation, and persistence; these functions perform one bounded operation
/// and return the real failure when that operation cannot complete.
enum LMStudioInstaller {
    static let officialDMGEndpoint = URL(string: "https://lmstudio.ai/download/latest/darwin/arm64")!
    static let appName = "LM Studio.app"
    static let bundleIdentifier = "ai.elementlabs.lmstudio"
    static let appExecutable = "LM Studio"

    // O3: the exact refs used by `lms get`; these are also the production route defaults.
    static let gemmaModelID = "google/gemma-4-e4b"
    static let qwenModelID = "qwen3-coder-30b-a3b-instruct-mlx"

    enum AppInstallOutcome: Equatable {
        case alreadyInstalled(URL)
        case installed(URL)
    }

    enum ModelInstallOutcome: Equatable {
        case alreadyInstalled(String)
        case installed(String)
    }

    struct DMGSource: Equatable {
        let url: URL
        let expectedBytes: Int64
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { status == 0 }
    }

    typealias CommandRunner = (_ executable: String, _ arguments: [String]) throws -> CommandResult

    enum InstallerError: Error, CustomStringConvertible {
        case invalidModelIdentifier(String)
        case invalidPublishedResponse(String)
        case network(String)
        case httpStatus(Int)
        case command(String, CommandResult)
        case commandLaunch(String, Error)
        case invalidDMG(String)
        case invalidMountedImage(String)
        case invalidApplication(String)
        case destinationExists(URL)
        case operation(String)

        var description: String {
            switch self {
            case let .invalidModelIdentifier(id):
                return "invalid LM Studio model identifier: \(id)"
            case let .invalidPublishedResponse(reason):
                return "LM Studio published DMG response is unverified: \(reason)"
            case let .network(reason):
                return "LM Studio DMG request failed: \(reason)"
            case let .httpStatus(status):
                return "LM Studio DMG request returned HTTP \(status)"
            case let .command(name, result):
                return Self.commandDescription(name: name, result: result)
            case let .commandLaunch(name, error):
                return "could not launch \(name): \(error.localizedDescription)"
            case let .invalidDMG(reason):
                return "LM Studio DMG failed verification: \(reason)"
            case let .invalidMountedImage(reason):
                return "LM Studio mounted image failed verification: \(reason)"
            case let .invalidApplication(reason):
                return "LM Studio application failed verification: \(reason)"
            case let .destinationExists(url):
                return "refusing to overwrite existing LM Studio application at \(url.path)"
            case let .operation(reason):
                return reason
            }
        }

        private static func commandDescription(name: String, result: CommandResult) -> String {
            var text = "\(name) failed with status \(result.status)"
            if !result.stdout.isEmpty { text += "; stdout: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))" }
            if !result.stderr.isEmpty { text += "; stderr: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))" }
            return text
        }
    }

    // MARK: Published DMG resolution and verification

    /// Follows LM Studio's own latest-download endpoint and accepts only a verified final DMG URL.
    /// The final host, suffix, MIME type, and byte count are all checked before a download is allowed.
    static func resolveOfficialDMG(session: URLSession = .shared,
                                   timeout: TimeInterval = 30) throws -> DMGSource {
        var request = URLRequest(url: officialDMGEndpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var requestError: Error?
        let task = session.dataTask(with: request) { _, rawResponse, error in
            response = rawResponse as? HTTPURLResponse
            requestError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw InstallerError.network("timed out resolving \(officialDMGEndpoint.absoluteString)")
        }
        if let requestError { throw InstallerError.network(requestError.localizedDescription) }
        guard let response else {
            throw InstallerError.network("the download endpoint returned no HTTP response")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw InstallerError.httpStatus(response.statusCode)
        }
        return try validatePublishedResponse(response)
    }

    /// Pure seam for the deterministic selftest and for future endpoint changes.
    static func validatePublishedResponse(_ response: HTTPURLResponse) throws -> DMGSource {
        guard let url = response.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "lmstudio.ai" || host.hasSuffix(".lmstudio.ai") else {
            throw InstallerError.invalidPublishedResponse("final URL is not an HTTPS LM Studio host")
        }
        guard url.pathExtension.lowercased() == "dmg" else {
            throw InstallerError.invalidPublishedResponse("final URL does not end in .dmg")
        }
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let acceptedMIMEs = ["application/octet-stream", "application/x-apple-diskimage"]
        guard let mime, acceptedMIMEs.contains(mime) else {
            throw InstallerError.invalidPublishedResponse("content type is \(mime ?? "missing")")
        }
        guard let length = response.value(forHTTPHeaderField: "Content-Length"),
              let bytes = Int64(length), bytes > 0 else {
            throw InstallerError.invalidPublishedResponse("positive Content-Length is missing")
        }
        return DMGSource(url: url, expectedBytes: bytes)
    }

    /// Downloads a previously verified source without replacing either the destination or a
    /// pre-existing partial file. Hashes are not invented: the mounted image and signed app are
    /// verified after the byte-count check, and the real HTTP/command error is retained on failure.
    static func downloadDMG(source: DMGSource,
                            to destination: URL,
                            session: URLSession = .shared,
                            timeout: TimeInterval = 300) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            throw InstallerError.destinationExists(destination)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(".LMStudio-\(UUID().uuidString).dmg.part")
        defer { try? fileManager.removeItem(at: partial) }

        var request = URLRequest(url: source.url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var requestError: Error?
        var moveError: Error?
        let task = session.downloadTask(with: request) { temporaryURL, rawResponse, error in
            response = rawResponse as? HTTPURLResponse
            requestError = error
            if error == nil, let temporaryURL {
                do {
                    // URLSession owns its temporary download URL and may remove it when this
                    // callback returns, so take ownership before signalling the waiting caller.
                    try fileManager.moveItem(at: temporaryURL, to: partial)
                } catch {
                    moveError = error
                }
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw InstallerError.network("timed out downloading \(source.url.absoluteString)")
        }
        if let requestError { throw InstallerError.network(requestError.localizedDescription) }
        if let moveError {
            throw InstallerError.network("could not retain the downloaded DMG: \(moveError.localizedDescription)")
        }
        guard let response else { throw InstallerError.network("download returned no HTTP response") }
        guard (200..<300).contains(response.statusCode) else {
            throw InstallerError.httpStatus(response.statusCode)
        }
        let returnedSource = try validatePublishedResponse(response)
        guard returnedSource.url == source.url,
              returnedSource.expectedBytes == source.expectedBytes else {
            throw InstallerError.invalidDMG(
                "GET resolved to \(returnedSource.url.absoluteString) with \(returnedSource.expectedBytes) bytes,"
                    + " not the verified HEAD source")
        }
        guard fileManager.fileExists(atPath: partial.path) else {
            throw InstallerError.network("download returned no file")
        }
        let actualBytes = try fileManager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
        guard actualBytes?.int64Value == source.expectedBytes else {
            throw InstallerError.invalidDMG(
                "downloaded \(actualBytes?.int64Value ?? 0) bytes; expected \(source.expectedBytes)")
        }
        try fileManager.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: DMG attach/copy/detach

    static func installDMG(at dmg: URL,
                           expectedBytes: Int64,
                           applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                           fileManager: FileManager = .default,
                           commandRunner: @escaping CommandRunner = runCommand) throws -> AppInstallOutcome {
        let destination = applicationsDirectory.appendingPathComponent(appName, isDirectory: true)

        // This check is intentionally first. An existing install is user-owned state; even a newer
        // DMG must not cause a first-run flow to overwrite it.
        if fileManager.fileExists(atPath: destination.path) {
            return .alreadyInstalled(destination)
        }
        try validateDMGFile(dmg, expectedBytes: expectedBytes, fileManager: fileManager,
                           commandRunner: commandRunner)

        let attach = try commandRunner("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard attach.succeeded else { throw InstallerError.command("hdiutil attach", attach) }
        guard let mountPoint = mountPoint(from: attach.stdout) else {
            throw InstallerError.invalidMountedImage("hdiutil attach returned no mount point")
        }

        var primaryError: Error?
        var copied = false
        do {
            guard let mountedApp = findApplication(named: appName, under: mountPoint, fileManager: fileManager) else {
                throw InstallerError.invalidMountedImage("\(appName) was not found on the mounted image")
            }
            try verifyApplication(at: mountedApp, fileManager: fileManager, commandRunner: commandRunner)
            try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
            let staging = applicationsDirectory.appendingPathComponent(
                ".LM Studio.app.installing-\(UUID().uuidString)", isDirectory: true)
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
            if !detach.succeeded {
                let error = InstallerError.command("hdiutil detach", detach)
                if primaryError == nil { primaryError = error }
            }
        } catch {
            if primaryError == nil { primaryError = error }
        }
        if let primaryError { throw primaryError }
        guard copied else { throw InstallerError.operation("LM Studio DMG copy did not complete") }
        return .installed(destination)
    }

    private static func validateDMGFile(_ dmg: URL, expectedBytes: Int64,
                                       fileManager: FileManager,
                                       commandRunner: @escaping CommandRunner) throws {
        guard fileManager.fileExists(atPath: dmg.path) else {
            throw InstallerError.invalidDMG("file does not exist at \(dmg.path)")
        }
        let attributes = try fileManager.attributesOfItem(atPath: dmg.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value == expectedBytes else {
            throw InstallerError.invalidDMG(
                "file size is \((attributes[.size] as? NSNumber)?.int64Value ?? 0); expected \(expectedBytes)")
        }
        let imageInfo = try commandRunner("/usr/bin/hdiutil", ["imageinfo", "-plist", dmg.path])
        guard imageInfo.succeeded else { throw InstallerError.command("hdiutil imageinfo", imageInfo) }
    }

    private static func mountPoint(from plist: String) -> URL? {
        guard let data = plist.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = root as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    private static func findApplication(named name: String, under root: URL,
                                        fileManager: FileManager) -> URL? {
        let direct = root.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for case let item as URL in enumerator where item.lastPathComponent == name {
            return item
        }
        return nil
    }

    private static func verifyApplication(at app: URL, fileManager: FileManager,
                                          commandRunner: @escaping CommandRunner) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = root as? [String: Any] else {
            throw InstallerError.invalidApplication("Info.plist is missing or unreadable")
        }
        guard info["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw InstallerError.invalidApplication("bundle identifier is not \(bundleIdentifier)")
        }
        guard info["CFBundleExecutable"] as? String == appExecutable else {
            throw InstallerError.invalidApplication("executable name is not \(appExecutable)")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/\(appExecutable)")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw InstallerError.invalidApplication("the signed executable is missing")
        }
        let codesign = try commandRunner("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard codesign.succeeded else { throw InstallerError.command("codesign --verify", codesign) }
    }

    // MARK: LM Studio's model CLI

    /// Detects an exact installed model through LM Studio, then delegates acquisition to LM Studio's
    /// own catalog-aware CLI. No GGUF path or LM Studio model-directory write is ever performed here.
    static func installModel(_ modelID: String,
                             lmsURL: URL = URL(fileURLWithPath: NSHomeDirectory())
                                .appendingPathComponent(".lmstudio/bin/lms"),
                             fileManager: FileManager = .default,
                             commandRunner: @escaping CommandRunner = runCommand) throws -> ModelInstallOutcome {
        guard validModelIdentifier(modelID) else {
            throw InstallerError.invalidModelIdentifier(modelID)
        }
        guard fileManager.isExecutableFile(atPath: lmsURL.path) else {
            throw InstallerError.operation("LM Studio CLI is not executable at \(lmsURL.path)")
        }

        let listed = try commandRunner(lmsURL.path, ["ls", "--llm", "--json"])
        guard listed.succeeded else { throw InstallerError.command("lms ls", listed) }
        guard let data = listed.stdout.data(using: .utf8),
              let models = LMStudioModelCatalog.parse(data) else {
            throw InstallerError.operation("lms ls returned invalid JSON; refusing to guess whether \(modelID) exists")
        }
        if models.contains(where: { $0.modelID == modelID }) {
            return .alreadyInstalled(modelID)
        }

        let fetched = try commandRunner(lmsURL.path, ["get", modelID])
        guard fetched.succeeded else { throw InstallerError.command("lms get \(modelID)", fetched) }
        return .installed(modelID)
    }

    private static func validModelIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        return identifier.unicodeScalars.allSatisfy {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }
    }

    // MARK: Default command runner

    /// Captures stdout and stderr concurrently so a verbose CLI cannot deadlock on a full pipe. This
    /// intentionally has no retry policy or download-specific timeout; the setup engine owns those.
    private static func runCommand(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw InstallerError.commandLaunch(executable, error)
        }

        var stdout = Data()
        var stderr = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: stdout, as: UTF8.self),
                             stderr: String(decoding: stderr, as: UTF8.self))
    }
}
