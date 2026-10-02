import Foundation

/// Loads the whisperd LaunchAgent into the user's `gui/<uid>` domain when launchd does not have it yet,
/// then starts it.
///
/// `launchctl kickstart` only starts a service launchd already knows. On a fresh account the plist the app
/// has just written to `~/Library/LaunchAgents` is NOT loaded until the next login, so a bare kickstart
/// answers 113 ("Could not find service") and transcription waits for a logout. The rule here:
///
/// - not loaded (`launchctl print gui/<uid>/<label>` fails): `bootstrap gui/<uid> <plist>`, then `kickstart`;
/// - loaded: today's kickstart (`-k` when the caller wants a restart), and NEVER a second bootstrap, which
///   launchd refuses with "service already loaded".
///
/// A bootstrap that reports already-loaded lost a race to another loader; it falls through to the kickstart,
/// whose own exit code decides the outcome. Every step is logged with its exit code. Running it twice is
/// harmless: the second pass finds the agent loaded and only kickstarts.
///
/// launchctl is INJECTED (`run`), so a deterministic self-test can model the domain without launchd.
/// Production uses `forCurrentUser`, which blocks on each launchctl call: call it off the main thread.
struct WhisperdAgentLoader {
    /// One launchctl invocation: the executable path and its arguments, answered with exit code and output.
    typealias Runner = (_ executable: String, _ arguments: [String]) -> InstallerCommandResult

    enum Outcome: Equatable {
        /// The agent was already loaded and was kickstarted (restarted when asked).
        case kickstarted
        /// The agent was not loaded; it was bootstrapped (or found loaded by a racing bootstrap) and started.
        case loadedAndStarted
        case failed(String)

        var succeeded: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    static let launchctlPath = "/bin/launchctl"
    /// What `launchctl bootstrap` exits with when the service is already in the domain: 5 (EIO, "Bootstrap
    /// failed: 5: Input/output error") on current macOS, 37 (EALREADY) on older releases.
    static let alreadyLoadedBootstrapCodes: Set<Int32> = [5, 37]

    let uid: uid_t
    let label: String
    let plistPath: String
    let run: Runner
    let log: (String) -> Void

    init(uid: uid_t, label: String, plistPath: String, run: @escaping Runner,
         log: @escaping (String) -> Void = { Log.write($0) }) {
        self.uid = uid
        self.label = label
        self.plistPath = plistPath
        self.run = run
        self.log = log
    }

    var domain: String { "gui/\(uid)" }
    var serviceTarget: String { "\(domain)/\(label)" }

    /// Load if needed, then start. `restartIfLoaded` keeps each caller's existing kickstart: the installer
    /// restarts a loaded agent (`-k`) so it runs the script it just replaced; the on-demand wake does not,
    /// so it never kills a daemon that is still loading its model.
    @discardableResult
    func loadAndStart(restartIfLoaded: Bool) -> Outcome {
        let printed = step(["print", serviceTarget])
        if printed.succeeded {
            let kick = step(restartIfLoaded ? ["kickstart", "-k", serviceTarget] : ["kickstart", serviceTarget])
            return kick.succeeded ? .kickstarted : .failed("kickstart \(describe(kick))")
        }

        let boot = step(["bootstrap", domain, plistPath])
        if !boot.succeeded {
            guard let code = boot.exitCode, Self.alreadyLoadedBootstrapCodes.contains(code), !boot.timedOut
            else {
                return .failed("bootstrap \(describe(boot))")
            }
            log("whisperd-agent: bootstrap reports \(label) already loaded (exit \(code)); kickstarting it")
        }
        let kick = step(["kickstart", serviceTarget])
        return kick.succeeded ? .loadedAndStarted : .failed("kickstart \(describe(kick))")
    }

    private func step(_ arguments: [String]) -> InstallerCommandResult {
        let result = run(Self.launchctlPath, arguments)
        log("whisperd-agent: launchctl \(arguments.joined(separator: " ")) \(describe(result))")
        return result
    }

    private func describe(_ result: InstallerCommandResult) -> String {
        var text = "exit=" + (result.exitCode.map { String($0) } ?? "none")
        if result.timedOut { text += " timed-out" }
        if let launchError = result.launchError { text += " launch-error=\(launchError)" }
        if !result.succeeded {
            let firstLine = result.stderr.split(whereSeparator: { $0.isNewline }).first.map { String($0) } ?? ""
            if !firstLine.isEmpty { text += " stderr=\(firstLine.prefix(200))" }
        }
        return text
    }
}

extension WhisperdAgentLoader {
    /// The production loader: the real uid, `DaemonClient.agentLabel`, the canonical plist in the real home,
    /// and `/bin/launchctl` through the installer's draining Process adapter.
    static func forCurrentUser(fileManager: FileManager = .default) -> WhisperdAgentLoader {
        let plist = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(DaemonClient.agentLabel).plist", isDirectory: false)
        let runner = FoundationInstallerProcessRunner()
        return WhisperdAgentLoader(
            uid: getuid(), label: DaemonClient.agentLabel, plistPath: plist.path,
            run: { executable, arguments in
                runner.run(executable: URL(fileURLWithPath: executable), arguments: arguments,
                           environment: [:], timeout: 15)
            })
    }
}
