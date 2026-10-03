import CryptoKit
import Foundation

/// Why a daemon install could not complete. Typed so a caller can tell "this app bundle never shipped
/// the daemon" apart from "the machine refused the write", and so a self-test can assert the negative
/// control without parsing a human string.
enum DaemonInstallFailure: Equatable {
    case bundledResourceMissing(String)
    case writeFailed(String)

    var message: String {
        switch self {
        case .bundledResourceMissing(let detail):
            return "the app bundle is missing its transcription daemon resource: \(detail)"
        case .writeFailed(let detail):
            return "the transcription daemon could not be written: \(detail)"
        }
    }
}

/// What one install pass did. `unchanged` is the idempotent case the app hits on every launch after
/// the first; `upgraded` names the previous build that was preserved, if it was not one this app
/// shipped.
enum DaemonInstallResult: Equatable {
    case installed
    case upgraded(preservedBackup: URL?)
    case unchanged
    /// The daemon script was staged, but `stt-venv/bin/python` does not exist yet, so the LaunchAgent
    /// plist was NOT written and no agent was bootstrapped or kickstarted. First-run setup builds that
    /// environment and calls the STT row again, which then completes the install.
    case stagedWithoutAgent
    case failed(DaemonInstallFailure)
}

/// Installs the bundled STT daemon into the user's home.
///
/// A DMG-only Mac has no repository to run `install-daemon.sh` from, so the app ships the daemon
/// script and its LaunchAgent template inside its own bundle and writes them itself. Everything that
/// touches the machine is INJECTED: the home directory, the resource directory whose `daemon/` child
/// holds the staged files, and the action that asks launchd to restart the agent. The type itself is
/// policy plus `FileManager`, so a deterministic self-test can drive every branch inside a scratch
/// directory and never reach the real home, the real LaunchAgents directory, or the real launchd
/// domain.
struct DaemonInstaller {
    /// Script hashes this app has shipped before. A differing installed script that is NOT in this set
    /// is somebody else's build, so it is preserved beside the new file rather than overwritten. Empty
    /// today: the first release that ships this installer has no predecessor it authored.
    static let knownShippedScriptHashes: Set<String> = []

    private static let scriptName = "viddydictate_whisperd.py"
    private static let plistName = "com.viddydictate.whisperd.plist"
    private static let homePlaceholder = "__HOME__"

    let homeDirectory: URL
    let resourceDirectory: URL
    let restartAgent: () -> Void
    private let fileManager: FileManager

    init(homeDirectory: URL,
         resourceDirectory: URL,
         restartAgent: @escaping () -> Void,
         fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.resourceDirectory = resourceDirectory
        self.restartAgent = restartAgent
        self.fileManager = fileManager
    }

    // MARK: - Canonical destinations

    var supportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/ViddyDictate",
                                             isDirectory: true)
    }
    var installedScriptURL: URL {
        supportDirectory.appendingPathComponent(Self.scriptName, isDirectory: false)
    }
    var launchAgentsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
    var installedPlistURL: URL {
        launchAgentsDirectory.appendingPathComponent(Self.plistName, isDirectory: false)
    }

    // MARK: - Bundled sources

    var bundledDaemonDirectory: URL {
        resourceDirectory.appendingPathComponent("daemon", isDirectory: true)
    }
    var bundledScriptURL: URL {
        bundledDaemonDirectory.appendingPathComponent(Self.scriptName, isDirectory: false)
    }
    var bundledPlistURL: URL {
        bundledDaemonDirectory.appendingPathComponent(Self.plistName, isDirectory: false)
    }

    // MARK: - Install

    /// Install, upgrade, or leave alone. Never traps: every failure is a typed `DaemonInstallResult`.
    ///
    /// Both staged resources are read BEFORE any destination directory or file is created, so a bundle
    /// that is missing the script or the template produces a typed failure and NO partial LaunchAgent.
    func install() -> DaemonInstallResult {
        let scriptData: Data
        let plistTemplate: String
        do {
            scriptData = try Data(contentsOf: bundledScriptURL)
            let plistData = try Data(contentsOf: bundledPlistURL)
            guard let text = String(data: plistData, encoding: .utf8) else {
                return .failed(.bundledResourceMissing(
                    "the staged LaunchAgent plist is not UTF-8 text"))
            }
            plistTemplate = text
        } catch {
            return .failed(.bundledResourceMissing(String(describing: error)))
        }

        let bundledHash = Self.sha256Hex(scriptData)

        // Idempotence first: the common launch path after the first run must not write or restart.
        if let installedHash = hashOfInstalledScript(), installedHash == bundledHash,
           fileManager.fileExists(atPath: installedPlistURL.path) {
            return .unchanged
        }

        // Preserve a differing predecessor this app did not ship. Preservation is a promise, so if
        // the copy fails we refuse to overwrite rather than silently destroy the user's old build.
        var preservedBackup: URL?
        if fileManager.fileExists(atPath: installedScriptURL.path),
           let installedHash = hashOfInstalledScript(),
           installedHash != bundledHash,
           !Self.knownShippedScriptHashes.contains(installedHash) {
            guard let backup = preserveInstalledScript(hashPrefix: String(installedHash.prefix(12)))
            else {
                return .failed(.writeFailed(
                    "could not preserve the existing daemon script at \(installedScriptURL.path)"))
            }
            preservedBackup = backup
        }

        let plistText = plistTemplate.replacingOccurrences(of: Self.homePlaceholder,
                                                           with: homeDirectory.path)

        // The LaunchAgent's program is `stt-venv/bin/python`, which first-run setup creates. Until that
        // interpreter exists, writing the plist and bootstrapping the agent would load a service whose
        // program is missing and make macOS announce a spurious "Background Items Added: python". The
        // daemon script is always staged; the plist and launchd are touched only once python exists.
        let venvPython = homeDirectory.appendingPathComponent(
            "Library/Application Support/ViddyDictate/stt-venv/bin/python", isDirectory: false)
        let venvPythonExists = fileManager.isExecutableFile(atPath: venvPython.path)
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try scriptData.write(to: installedScriptURL, options: .atomic)
            if venvPythonExists {
                try fileManager.createDirectory(at: launchAgentsDirectory,
                                                withIntermediateDirectories: true)
                guard let plistData = plistText.data(using: .utf8) else {
                    return .failed(.writeFailed("the LaunchAgent plist could not be encoded as UTF-8"))
                }
                try plistData.write(to: installedPlistURL, options: .atomic)
            }
        } catch {
            return .failed(.writeFailed(String(describing: error)))
        }

        guard venvPythonExists else {
            if let preservedBackup {
                Log.write("daemon-install: staged the daemon and preserved the previous build at "
                    + "\(preservedBackup.path); the speech-to-text environment is not built yet, so no "
                    + "LaunchAgent was installed or loaded")
            }
            return .stagedWithoutAgent
        }

        restartAgent()
        if let preservedBackup {
            Log.write("daemon-install: preserved previous daemon build at \(preservedBackup.path)")
            return .upgraded(preservedBackup: preservedBackup)
        }
        return .installed
    }

    // MARK: - Helpers

    private func hashOfInstalledScript() -> String? {
        guard let data = try? Data(contentsOf: installedScriptURL) else { return nil }
        return Self.sha256Hex(data)
    }

    private func preserveInstalledScript(hashPrefix: String) -> URL? {
        var candidate = installedScriptURL.appendingPathExtension("preserved-\(hashPrefix)")
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = installedScriptURL.appendingPathExtension("preserved-\(hashPrefix)-\(suffix)")
            suffix += 1
            if suffix > 100 { return nil }
        }
        do {
            try fileManager.copyItem(at: installedScriptURL, to: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    /// The same SHA-256 mechanism `InstallerEngine.sha256(ofFileAt:)` already uses (CryptoKit), factored
    /// onto `Data` so the staged template can be hashed before it is written anywhere.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension DaemonInstaller {
    /// Production entry point. Uses the real home and the app bundle's own `Resources` directory, and
    /// asks launchd to restart the agent after a write. Kept separate from the injected core so no test
    /// can reach the real home or the real launchd domain by accident.
    @discardableResult
    static func installForCurrentUser(fileManager: FileManager = .default) -> DaemonInstallResult {
        guard let resources = Bundle.main.resourceURL else {
            let failure = DaemonInstallFailure.bundledResourceMissing("Bundle.main.resourceURL is nil")
            Log.write("daemon-install: failed — \(failure.message)")
            return .failed(failure)
        }
        let installer = DaemonInstaller(
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            resourceDirectory: resources,
            restartAgent: { restartDaemonAgent() },
            fileManager: fileManager)
        let result = installer.install()
        switch result {
        case .installed:
            Log.write("daemon-install: installed the bundled transcription daemon")
        case .upgraded(let backup):
            let detail = backup.map { " (preserved previous build at \($0.path))" } ?? ""
            Log.write("daemon-install: upgraded the transcription daemon\(detail)")
        case .unchanged:
            break
        case .stagedWithoutAgent:
            Log.write("daemon-install: staged the transcription daemon; the speech-to-text "
                + "environment is not built yet, so the LaunchAgent was not installed or loaded")
        case .failed(let failure):
            Log.write("daemon-install: failed — \(failure.message)")
        }
        return result
    }

    /// The production restart action. A kickstart alone cannot start a fresh plist: launchd has not
    /// loaded it yet (it would on the next login), so kickstart answers 113 and transcription waits for
    /// a logout. `WhisperdAgentLoader` bootstraps the agent when it is not loaded and restarts it (`-k`)
    /// when it is. Runs on the installer's own background queue, never the main thread.
    private static func restartDaemonAgent() {
        let outcome = WhisperdAgentLoader.forCurrentUser().loadAndStart(restartIfLoaded: true)
        if case .failed(let detail) = outcome {
            Log.write("daemon-install: launchctl restart failed — \(detail)")
        }
    }
}
