import Foundation

/// The one global Whisper choice (selectable Whisper versions, part 1 of 3, backend only).
///
/// Every effect is injected, so a deterministic test can drive the whole decision without a real
/// `whisper-model` file, daemon, or launchd. The production entry point supplies the real effects.
/// There are deliberately no callers yet besides the tests — part 2 adds the Settings UI.
enum WhisperModelSwitch {
    enum Result: Equatable {
        /// The choice is now active (written, persisted, daemon restarted) — or was already active.
        case switched
        /// The repo is not one this build offers; nothing was changed.
        case notOffered
        /// The repo is offered but has no complete local snapshot; a later UI can offer to install it.
        case notInstalled
        /// The write failed; nothing was changed and the daemon was not restarted.
        case failed(String)
    }

    /// Select `repo` as the global Whisper model. Order is the contract:
    ///
    /// 1. refuse a repo that is not offered;
    /// 2. an already-active repo is idempotent (no write, no restart);
    /// 3. refuse an offered repo that is not installed;
    /// 4. write the choice file, and on failure return `.failed` WITHOUT changing the setting or
    ///    restarting;
    /// 5. persist the setting, restart the daemon, and report `.switched`.
    static func select(repo: String,
                       installed: (String) -> Bool,
                       write: (String) throws -> Void,
                       restart: () -> Void) -> Result {
        guard WhisperModelCatalog.isOffered(repo: repo) else { return .notOffered }
        if Settings.whisperModelRepo == repo { return .switched }
        guard installed(repo) else { return .notInstalled }
        do {
            try write(repo)
        } catch {
            return .failed(String(describing: error))
        }
        Settings.whisperModelRepo = repo
        restart()
        return .switched
    }

    /// Production wiring: the real installed-probe, the real atomic `whisper-model` write, and the
    /// existing `WhisperdAgentLoader` restart (bootstrap if not loaded, `-k` if it is). No UI yet.
    static func select(repo: String) -> Result {
        select(repo: repo,
               installed: { WhisperModelStore.isInstalled(repo: $0) },
               write: { try WhisperModelStore.writeChoice(repo: $0) },
               restart: { _ = WhisperdAgentLoader.forCurrentUser().loadAndStart(restartIfLoaded: true) })
    }
}
