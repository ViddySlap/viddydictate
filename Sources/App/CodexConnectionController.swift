import Cocoa

/// App-facing status and one-time/reconnect subscription-OAuth flow. Device auth is the sole login
/// command; it runs against ViddyDictate's audited dedicated home with a sterile allowlist environment.
/// Raw CLI output and auth material are never logged. Only the user-facing verification URL/code are
/// surfaced to the Settings sheet.
final class CodexConnectionController {
    static let shared = CodexConnectionController()

    private let lock = NSLock()
    private var loginProcess: Process?
    private var loginInProgress = false
    private var cancelRequested = false

    private init() {}

    var isConnecting: Bool {
        lock.lock(); defer { lock.unlock() }
        return loginInProgress
    }

    func refreshAvailability(completion: ((CodexConnectionState) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let state = CodexProviderRuntime.connectionState()
            DispatchQueue.main.async {
                self.publish(state)
                completion?(state)
            }
        }
    }

    func startDeviceLogin(onInstructions: @escaping (CodexDeviceAuthorizationInfo) -> Void,
                          completion: @escaping (CodexConnectionState) -> Void) {
        lock.lock()
        guard !loginInProgress else {
            lock.unlock()
            DispatchQueue.main.async {
                completion(.unavailable("Codex connection is already in progress"))
            }
            return
        }
        loginInProgress = true
        cancelRequested = false
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            switch CodexProviderRuntime.prepareForDeviceLogin() {
            case .failure:
                self.finishLogin(
                    state: .unavailable("Codex isolation setup failed before device login"),
                    completion: completion)
            case .success(let paths):
                self.runDeviceLogin(paths: paths,
                                    onInstructions: onInstructions,
                                    completion: completion)
            }
        }
    }

    func cancelDeviceLogin() {
        lock.lock()
        cancelRequested = true
        let process = loginProcess
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func runDeviceLogin(paths: CodexIsolationFoundation.Paths,
                                onInstructions: @escaping (CodexDeviceAuthorizationInfo) -> Void,
                                completion: @escaping (CodexConnectionState) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CodexIsolationFoundation.codexBinary)
        process.arguments = CodexProviderRuntime.deviceLoginArguments
        process.environment = CodexProviderRuntime.deviceLoginEnvironment(paths: paths)
        process.currentDirectoryURL = paths.cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        loginProcess = process
        let wasCancelled = cancelRequested
        lock.unlock()

        if wasCancelled {
            finishLogin(state: CodexProviderRuntime.connectionState(), completion: completion)
            return
        }

        do { try process.run() }
        catch {
            finishLogin(state: .unavailable("Could not start Codex device login"),
                        completion: completion)
            return
        }

        var captured = Data()
        var lastInfo: CodexDeviceAuthorizationInfo?
        while true {
            // MUST be `availableData`. `readData(ofLength:)` blocks until it has the full requested
            // length or EOF, and the device-login command prints its ~486-byte instruction block and
            // then waits up to 15 minutes for the user. Asking for 4096 bytes therefore surrendered
            // the block only after the login process died, so `onInstructions` never fired: no browser
            // was opened and no one-time code was ever displayed. That is what "Connect does nothing"
            // was.
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if captured.count + chunk.count > 65_536 {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                finishLogin(state: .unavailable("Codex device-login output exceeded its bound"),
                            completion: completion)
                return
            }
            captured.append(chunk)
            if let info = CodexProviderRuntime.parseDeviceAuthorizationInfo(captured), info != lastInfo {
                lastInfo = info
                DispatchQueue.main.async { onInstructions(info) }
            }
        }
        process.waitUntilExit()

        // Success is never inferred from the login command's prose. Re-audit the dedicated boundary and
        // require the exact `Logged in using ChatGPT` status; API-key or ambiguous states fail closed.
        let state = CodexProviderRuntime.connectionState()
        finishLogin(state: state, completion: completion)
    }

    private func finishLogin(state: CodexConnectionState,
                             completion: @escaping (CodexConnectionState) -> Void) {
        lock.lock()
        loginProcess = nil
        loginInProgress = false
        cancelRequested = false
        lock.unlock()
        DispatchQueue.main.async {
            self.publish(state)
            completion(state)
        }
    }

    private func publish(_ state: CodexConnectionState) {
        Settings.modelsPower.setAvailabilityState(
            LLMProviderDetection.availability(from: state), for: .codex)
    }
}
