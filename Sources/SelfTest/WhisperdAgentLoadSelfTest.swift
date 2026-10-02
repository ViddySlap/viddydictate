import Foundation

/// A fresh account must get a running transcription daemon without a logout.
///
/// Until 2026-10-01 the installer only ran `launchctl kickstart -k gui/<uid>/com.viddydictate.whisperd`.
/// On a fresh account the plist it had just written was not loaded, kickstart answered 113 ("Could not find
/// service"), and nothing transcribed until the next login. `WhisperdAgentLoader` bootstraps an agent that
/// is not loaded and never bootstraps one that is.
///
/// Pure: a fake launchctl models one `gui/<uid>` domain. `print` succeeds only for loaded labels, `kickstart`
/// of a label that is not loaded answers 113, `bootstrap` of a loaded label answers 5 ("already loaded"), and
/// `bootstrap` of a known plist loads its label. The real `/bin/launchctl` is never run. The negative control
/// runs the old kickstart-only strategy against the same not-loaded domain and requires it to fail, so the
/// gate is proven able to see the bug. A last check reads the two production call sites, so the loader is
/// not merely correct but actually the path the installer and the on-demand wake take.
enum WhisperdAgentLoadSelfTest {
    private static let uid: uid_t = 501
    private static let label = "com.viddydictate.whisperd"
    private static let plistPath = "/scratch/home/Library/LaunchAgents/com.viddydictate.whisperd.plist"
    private static var target: String { "gui/\(uid)/\(label)" }

    static func run() -> Bool {
        print("=== ViddyDictate whisperd LaunchAgent load-if-needed selftest ===")
        let reporter = SelfTestReporter()
        let check = reporter.check

        print("--- (1) not loaded: bootstrap, then kickstart ---")
        let fresh = FakeLaunchdDomain(uid: uid, plists: [plistPath: label])
        var lines: [String] = []
        let freshOutcome = loader(fresh, log: { lines.append($0) }).loadAndStart(restartIfLoaded: true)
        check("a fresh account's agent is loaded and started", freshOutcome == .loadedAndStarted)
        check("exactly print, bootstrap, kickstart, in that order",
              fresh.calls == [["print", target], ["bootstrap", "gui/\(uid)", plistPath], ["kickstart", target]])
        check("the agent ends loaded and started", fresh.loaded.contains(label) && fresh.started.contains(label))
        check("every launchctl step is logged with its exit code",
              lines.filter { $0.contains("launchctl ") && $0.contains("exit=") }.count == 3
                && lines.contains { $0.contains("launchctl print") && $0.contains("exit=113") })
        check("only /bin/launchctl was invoked", fresh.executables == [WhisperdAgentLoader.launchctlPath])

        let wake = FakeLaunchdDomain(uid: uid, plists: [plistPath: label])
        let wakeOutcome = loader(wake).loadAndStart(restartIfLoaded: false)
        check("the on-demand wake loads a not-loaded agent the same way",
              wakeOutcome == .loadedAndStarted && wake.bootstrapCount == 1 && wake.started.contains(label))

        print("--- (2) already loaded: kickstart only, never a second bootstrap ---")
        let loaded = FakeLaunchdDomain(uid: uid, plists: [plistPath: label], loaded: [label])
        let loadedOutcome = loader(loaded).loadAndStart(restartIfLoaded: true)
        check("a loaded agent is restarted", loadedOutcome == .kickstarted)
        check("the installer restarts it with kickstart -k and nothing else",
              loaded.calls == [["print", target], ["kickstart", "-k", target]])
        check("zero bootstrap calls for a loaded agent (no duplicate)", loaded.bootstrapCount == 0)

        let loadedWake = FakeLaunchdDomain(uid: uid, plists: [plistPath: label], loaded: [label])
        _ = loader(loadedWake).loadAndStart(restartIfLoaded: false)
        check("the on-demand wake kickstarts a loaded agent without -k (a loading daemon is not killed)",
              loadedWake.calls == [["print", target], ["kickstart", target]])

        let twice = FakeLaunchdDomain(uid: uid, plists: [plistPath: label])
        let first = loader(twice).loadAndStart(restartIfLoaded: true)
        let second = loader(twice).loadAndStart(restartIfLoaded: true)
        check("idempotent: a second pass only kickstarts, one bootstrap in total",
              first == .loadedAndStarted && second == .kickstarted && twice.bootstrapCount == 1)

        print("--- (3) bootstrap race: already loaded by someone else ---")
        let race = FakeLaunchdDomain(uid: uid, plists: [plistPath: label], loadsBeforeBootstrap: true)
        var raceLines: [String] = []
        let raceOutcome = loader(race, log: { raceLines.append($0) }).loadAndStart(restartIfLoaded: true)
        check("a bootstrap that reports already-loaded still kickstarts and succeeds",
              raceOutcome == .loadedAndStarted && race.started.contains(label))
        check("the race ran print, bootstrap (exit 5), kickstart",
              race.calls == [["print", target], ["bootstrap", "gui/\(uid)", plistPath], ["kickstart", target]]
                && race.lastBootstrapExit == 5)
        check("the already-loaded bootstrap is logged as such",
              raceLines.contains { $0.contains("already loaded") && $0.contains("exit 5") })

        // Treating 5 as already-loaded must not hide a bootstrap that loaded nothing: the kickstart decides.
        let unknown = FakeLaunchdDomain(uid: uid, plists: [:])
        let unknownOutcome = loader(unknown).loadAndStart(restartIfLoaded: true)
        check("a bootstrap that loaded nothing ends failed, not silently green",
              !unknownOutcome.succeeded && !unknown.loaded.contains(label))

        print("--- (4) negative control: the old kickstart-only strategy ---")
        let legacyDomain = FakeLaunchdDomain(uid: uid, plists: [plistPath: label])
        let legacy = legacyKickstartOnly(legacyDomain.run)
        check("the old kickstart -k on a fresh account answers 113", legacy.exitCode == 113)
        check("the old strategy leaves the agent NOT loaded and NOT started",
              !legacyDomain.loaded.contains(label) && !legacyDomain.started.contains(label))
        check("the gate's success criterion rejects the old strategy",
              !(legacy.succeeded && legacyDomain.loaded.contains(label)))

        print("--- production call sites use the loader ---")
        if let root = repositoryRoot() {
            let installer = (try? String(contentsOf: root.appendingPathComponent(
                "Sources/App/DaemonInstaller.swift"), encoding: .utf8)) ?? ""
            let client = (try? String(contentsOf: root.appendingPathComponent(
                "Sources/App/DaemonClient.swift"), encoding: .utf8)) ?? ""
            check("the installer restarts through WhisperdAgentLoader",
                  installer.contains("WhisperdAgentLoader.forCurrentUser().loadAndStart(restartIfLoaded: true)"))
            check("the on-demand wake goes through WhisperdAgentLoader",
                  client.contains("WhisperdAgentLoader.forCurrentUser().loadAndStart(restartIfLoaded: false)"))
            check("neither call site runs its own launchctl kickstart any more",
                  !installer.contains("\"kickstart\"") && !client.contains("\"kickstart\""))
        } else {
            reporter.record("the repository root is reachable from the test bundle path", false,
                            Bundle.main.bundleURL.path)
        }

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "whisperd-agent-load"))
        return reporter.passed
    }

    private static func loader(_ domain: FakeLaunchdDomain,
                               log: @escaping (String) -> Void = { _ in }) -> WhisperdAgentLoader {
        WhisperdAgentLoader(uid: uid, label: label, plistPath: plistPath, run: domain.run, log: log)
    }

    /// What `DaemonInstaller.restartDaemonAgent` did before this fix, kept only as the negative control.
    private static func legacyKickstartOnly(_ run: WhisperdAgentLoader.Runner) -> InstallerCommandResult {
        run("/bin/launchctl", ["kickstart", "-k", target])
    }

    /// Walks up from `<repo>/build/ViddyDictateTests.app` to the directory holding the daemon script, as
    /// `DaemonInstallSelfTest` does. A missing root is a recorded failure, never a crash.
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

    /// One `gui/<uid>` domain as launchctl answers it. A class so the runner closure can mutate it; nested
    /// inside this type so the shipped binary never links it.
    private final class FakeLaunchdDomain {
        let domain: String
        /// plist path -> the label that plist declares. A path not here is a plist launchd cannot load.
        let plists: [String: String]
        /// Another loader wins the race: the label is loaded just before our bootstrap reaches launchd.
        let loadsBeforeBootstrap: Bool
        private(set) var loaded: Set<String>
        private(set) var started: Set<String> = []
        private(set) var calls: [[String]] = []
        private(set) var executables: Set<String> = []
        private(set) var lastBootstrapExit: Int32?

        init(uid: uid_t, plists: [String: String], loaded: Set<String> = [], loadsBeforeBootstrap: Bool = false) {
            self.domain = "gui/\(uid)"
            self.plists = plists
            self.loaded = loaded
            self.loadsBeforeBootstrap = loadsBeforeBootstrap
        }

        var bootstrapCount: Int { calls.filter { $0.first == "bootstrap" }.count }

        func run(_ executable: String, _ arguments: [String]) -> InstallerCommandResult {
            executables.insert(executable)
            calls.append(arguments)
            guard executable == WhisperdAgentLoader.launchctlPath, let verb = arguments.first else {
                return InstallerCommandResult(exitCode: nil, launchError: "not launchctl: \(executable)")
            }
            switch verb {
            case "print":
                guard arguments.count == 2, let name = serviceLabel(arguments[1]), loaded.contains(name) else {
                    return notFound()
                }
                return InstallerCommandResult(exitCode: 0, stdout: "\(arguments[1]) = {\n\tstate = waiting\n}\n")
            case "kickstart":
                let rest = Array(arguments.dropFirst()).filter { $0 != "-k" }
                guard rest.count == 1, let name = serviceLabel(rest[0]), loaded.contains(name) else {
                    return notFound()
                }
                started.insert(name)
                return InstallerCommandResult(exitCode: 0)
            case "bootstrap":
                guard arguments.count == 3, arguments[1] == domain else {
                    return InstallerCommandResult(
                        exitCode: 125, stderr: "Bootstrap failed: 125: Domain does not support specified action\n")
                }
                guard let name = plists[arguments[2]] else {
                    return bootstrapExit(5, stderr: "Bootstrap failed: 5: Input/output error\n")
                }
                if loadsBeforeBootstrap { loaded.insert(name) }
                if loaded.contains(name) {
                    return bootstrapExit(5, stderr: "Bootstrap failed: 5: Input/output error\n"
                        + "Try re-running the command as root for richer errors.\n")
                }
                loaded.insert(name)
                return bootstrapExit(0, stderr: "")
            default:
                return InstallerCommandResult(exitCode: 64, stderr: "Unrecognized subcommand: \(verb)\n")
            }
        }

        private func serviceLabel(_ serviceTarget: String) -> String? {
            let prefix = domain + "/"
            guard serviceTarget.hasPrefix(prefix) else { return nil }
            return String(serviceTarget.dropFirst(prefix.count))
        }

        private func notFound() -> InstallerCommandResult {
            InstallerCommandResult(exitCode: 113, stderr: "Could not find service in domain for port\n")
        }

        private func bootstrapExit(_ code: Int32, stderr: String) -> InstallerCommandResult {
            lastBootstrapExit = code
            return InstallerCommandResult(exitCode: code, stderr: stderr)
        }
    }
}
