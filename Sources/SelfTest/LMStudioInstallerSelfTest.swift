import Foundation

/// Deterministic proof of the L3 LM Studio mechanism. It uses synthetic HTTP metadata, a fake CLI,
/// and a scratch mounted-image tree; it never launches LM Studio, downloads a model, or touches the
/// user's /Applications or ~/.lmstudio paths.
enum LMStudioInstallerSelfTest {
    static func run() -> Bool {
        print("=== LM Studio bootstrap mechanism selftest ===")
        let reporter = SelfTestReporter()

        checkPublishedEndpoint(reporter)
        checkModelCLI(reporter)
        checkDMGInstall(reporter)

        print(reporter.passed
            ? "[lmstudio-installer-selftest] PASS"
            : "[lmstudio-installer-selftest] FAIL")
        return reporter.passed
    }

    private static func checkPublishedEndpoint(_ reporter: SelfTestReporter) {
        print("--- official endpoint and download verification ---")
        let response = HTTPURLResponse(
            url: URL(string: "https://installers.lmstudio.ai/darwin/arm64/0.4.21-2/LM-Studio-0.4.21-2-arm64.dmg")!,
            statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream; charset=binary",
                           "Content-Length": "573936156"])
        let source = try? LMStudioInstaller.validatePublishedResponse(response!)
        reporter.record(
            "the official latest endpoint accepts a verified HTTPS DMG response with a byte count",
            source?.url.host == "installers.lmstudio.ai" && source?.expectedBytes == 573936156)
        reporter.record(
            "the source URL is the LM Studio published endpoint rather than a bare pinned installer URL",
            LMStudioInstaller.officialDMGEndpoint.absoluteString
                == "https://lmstudio.ai/download/latest/darwin/arm64")

        let untrusted = HTTPURLResponse(
            url: URL(string: "https://example.invalid/LM-Studio.dmg")!, statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "10"])
        reporter.record(
            "an untrusted final host is rejected before any download",
            (try? LMStudioInstaller.validatePublishedResponse(untrusted!)) == nil)
        let missingLength = HTTPURLResponse(
            url: response!.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"])
        reporter.record(
            "a DMG response without a positive Content-Length is rejected",
            (try? LMStudioInstaller.validatePublishedResponse(missingLength!)) == nil)
    }

    private static func checkModelCLI(_ reporter: SelfTestReporter) {
        print("--- existing-model detection and lms get delegation ---")
        let root = temporaryDirectory(reporter, label: "model")
        guard let root else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        let lms = root.appendingPathComponent("lms")
        FileManager.default.createFile(atPath: lms.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o700])
        var calls: [(String, [String])] = []
        let runner: LMStudioInstaller.CommandRunner = { executable, arguments in
            calls.append((executable, arguments))
            if arguments.first == "ls" {
                return .init(status: 0,
                             stdout: "[{\"type\":\"llm\",\"modelKey\":\"\(LMStudioInstaller.gemmaModelID)\"}]",
                             stderr: "")
            }
            if arguments.first == "get" {
                return .init(status: 0, stdout: "downloaded", stderr: "")
            }
            return .init(status: 1, stdout: "", stderr: "unexpected command")
        }

        let existing = try? LMStudioInstaller.installModel(
            LMStudioInstaller.gemmaModelID, lmsURL: lms, commandRunner: runner)
        reporter.record(
            "an already-installed exact model returns without lms get",
            existing == .alreadyInstalled(LMStudioInstaller.gemmaModelID) && calls.count == 1
                && calls[0].1 == ["ls", "--llm", "--json"])

        let missing = try? LMStudioInstaller.installModel(
            LMStudioInstaller.qwenModelID, lmsURL: lms, commandRunner: runner)
        let getCall = calls.last
        reporter.record(
            "a missing model delegates the exact identifier to lms get",
            missing == .installed(LMStudioInstaller.qwenModelID)
                && getCall?.1 == ["get", LMStudioInstaller.qwenModelID])

        let failingRunner: LMStudioInstaller.CommandRunner = { _, arguments in
            if arguments.first == "ls" {
                return .init(status: 0, stdout: "[]", stderr: "")
            }
            return .init(status: 17, stdout: "partial", stderr: "real lms failure")
        }
        do {
            _ = try LMStudioInstaller.installModel("vendor/missing", lmsURL: lms,
                                                   commandRunner: failingRunner)
            reporter.record("lms failure retains the real stderr", false)
        } catch {
            reporter.record("lms failure retains the real stderr",
                            String(describing: error).contains("real lms failure"))
        }
        reporter.record(
            "O3 pins the 16 GB gemma and 32 GB qwen identifiers",
            LMStudioInstaller.gemmaModelID == "google/gemma-4-e4b"
                && LMStudioInstaller.qwenModelID == "qwen3-coder-30b-a3b-instruct-mlx")
    }

    private static func checkDMGInstall(_ reporter: SelfTestReporter) {
        print("--- read-only attach, signed app verification, copy, and detach ---")
        let fileManager = FileManager.default
        guard let root = temporaryDirectory(reporter, label: "dmg") else { return }
        defer { try? fileManager.removeItem(at: root) }
        let mount = root.appendingPathComponent("mounted", isDirectory: true)
        let mountedApp = mount.appendingPathComponent(LMStudioInstaller.appName, isDirectory: true)
        let executable = mountedApp.appendingPathComponent("Contents/MacOS/LM Studio")
        try? fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": LMStudioInstaller.bundleIdentifier,
                                   "CFBundleExecutable": LMStudioInstaller.appExecutable]
        let infoData = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        fileManager.createFile(atPath: mountedApp.appendingPathComponent("Contents/Info.plist").path,
                               contents: infoData)
        fileManager.createFile(atPath: executable.path, contents: Data("synthetic executable".utf8),
                               attributes: [.posixPermissions: 0o700])
        let dmg = root.appendingPathComponent("LM-Studio.dmg")
        let bytes = Data("valid".utf8)
        fileManager.createFile(atPath: dmg.path, contents: bytes)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let attachPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array><dict>
        <key>mount-point</key><string>\(mount.path)</string>
        </dict></array></dict></plist>
        """
        var calls: [[String]] = []
        let runner: LMStudioInstaller.CommandRunner = { executable, arguments in
            calls.append([executable] + arguments)
            if arguments.first == "attach" {
                return .init(status: 0, stdout: attachPlist, stderr: "")
            }
            return .init(status: 0, stdout: "", stderr: "")
        }
        let result = try? LMStudioInstaller.installDMG(
            at: dmg, expectedBytes: Int64(bytes.count), applicationsDirectory: apps,
            fileManager: fileManager, commandRunner: runner)
        let destination = apps.appendingPathComponent(LMStudioInstaller.appName)
        reporter.record(
            "a verified DMG is attached read-only, copied, and detached",
            result == .installed(destination) && fileManager.fileExists(atPath: destination.path)
                && calls.contains { $0.count >= 6 && $0[0] == "/usr/bin/hdiutil"
                    && $0[1] == "attach" && $0.contains("-readonly") }
                && calls.contains { $0.count >= 2 && $0[0] == "/usr/bin/hdiutil" && $0[1] == "detach" })

        let countBeforeSecondInstall = calls.count
        let second = try? LMStudioInstaller.installDMG(
            at: dmg, expectedBytes: Int64(bytes.count), applicationsDirectory: apps,
            fileManager: fileManager, commandRunner: runner)
        reporter.record(
            "an existing /Applications destination is detected without another attach or overwrite",
            second == .alreadyInstalled(destination) && calls.count == countBeforeSecondInstall)

        let wrongSize = try? LMStudioInstaller.installDMG(
            at: dmg, expectedBytes: Int64(bytes.count + 1), applicationsDirectory: root.appendingPathComponent("Other"),
            fileManager: fileManager, commandRunner: runner)
        reporter.record(
            "a DMG byte-count mismatch fails before hdiutil attach",
            wrongSize == nil && calls.count == countBeforeSecondInstall)
    }

    private static func temporaryDirectory(_ reporter: SelfTestReporter, label: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vd-lmstudio-\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            reporter.record("scratch \(label) fixture setup", false, String(describing: error))
            return nil
        }
    }
}
