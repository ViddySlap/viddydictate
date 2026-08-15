import Foundation

/// Live device-authorization gate: runs the REAL `codex login --device-auth` and asserts the app can
/// still extract the verification URL and the one-time code from what the vendor actually prints.
///
/// This exists because of a specific miss, of the same family as the live catalog gate. The only
/// coverage for `parseDeviceAuthorizationInfo` was a hand-written one-line fixture
/// ("Open https://... and enter ABCD-EFGH"): plain ASCII, code groups of exactly four. It passed
/// forever while production could not parse a single real code, for two independent reasons - the
/// vendor colourises the block (and a colour escape ends in the LETTER `m`, which defeats a `\b`
/// anchor), and the vendor now issues 4-then-5 codes. The user got a browser page demanding a code the
/// app had never displayed, which reads as "Connect does nothing".
///
/// A hand-authored fixture cannot catch presentation drift by construction: it replays bytes we already
/// believe in. Only the real command can.
///
/// Side-effect discipline: this runs against a THROWAWAY scratch codex home, never the production
/// dedicated home, so it can never disturb the user's credential. It requests one device code and
/// abandons it without completing authorization.
///
/// Output is content-free by contract. The verification URL host and the code's SHAPE are reported;
/// the code itself is a live short-lived authorization secret and is never printed.
enum CodexDeviceAuthLiveGate {
    private static let label = "codex-device-auth-live"
    private static let readDeadline: TimeInterval = 25

    /// Apparatus is missing rather than the product being wrong: abstain, exit 0, and say so with the
    /// marker `verify.sh` recognises. A gate that reds on a machine with no network teaches everyone to
    /// ignore it.
    private static func skip(_ reason: String) -> Bool {
        print("[skip] [\(label)] SKIPPED \(reason)")
        return true
    }

    static func run() -> Bool {
        let binary = CodexIsolationFoundation.codexBinary
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return skip("vendored Codex CLI is not installed at the expected path")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddydictate-device-auth-live-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexIsolationFoundation.scratchPaths(root: root)
        do { try CodexIsolationFoundation.prepareDirectories(paths) }
        catch { return skip("scratch Codex home could not be prepared") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = CodexProviderRuntime.deviceLoginArguments
        process.environment = CodexProviderRuntime.deviceLoginEnvironment(paths: paths)
        process.currentDirectoryURL = paths.cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() }
        catch { return skip("device-login command could not be started") }

        // Read on a background queue so a vendor that never speaks cannot hang the gate.
        let lock = NSLock()
        var captured = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                // `availableData`, for the same reason the production reader must use it: the login
                // command speaks once and then waits for the user, so a fill-the-buffer read would
                // only yield at EOF and this gate would measure the deadline instead of the vendor.
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock()
                captured.append(chunk)
                let enough = captured.count > 65_536
                    || CodexProviderRuntime.parseDeviceAuthorizationInfo(captured)?.userCode != nil
                lock.unlock()
                if enough { break }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + readDeadline)

        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        lock.lock()
        let bytes = captured
        lock.unlock()

        guard !bytes.isEmpty else {
            return skip("device-login command produced no output within "
                            + "\(Int(readDeadline))s (offline or vendor unreachable)")
        }

        guard let info = CodexProviderRuntime.parseDeviceAuthorizationInfo(bytes) else {
            print("[\(label)] FAIL vendor emitted \(bytes.count) bytes but nothing was parsed "
                    + "from them")
            return false
        }
        guard let host = info.verificationURL?.host?.lowercased() else {
            print("[\(label)] FAIL vendor emitted \(bytes.count) bytes with no allowlisted "
                    + "verification URL")
            return false
        }
        guard let code = info.userCode else {
            print("[\(label)] FAIL vendor emitted \(bytes.count) bytes and an allowlisted URL "
                    + "(\(host)) but no one-time code could be extracted - the user would be sent "
                    + "to a verification page with nothing to type")
            return false
        }

        // Shape only. The code itself is a live authorization secret.
        let shape = code.split(separator: "-", omittingEmptySubsequences: false)
            .map { String($0.count) }
            .joined(separator: "-")
        print("[\(label)] PASS real device-auth output yielded host=\(host) "
                + "codeShape=\(shape) bytes=\(bytes.count)")
        return true
    }
}
