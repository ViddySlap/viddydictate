import Foundation

/// Live authenticated catalog gate: performs the REAL app-server handshake through the same
/// production entry point the app uses, instead of a fixture transport.
///
/// This exists because of a specific miss. Every fixture-based catalog test passed while the
/// real daemon broke the catalog outright: codex-cli 0.146.0 began emitting a
/// `remoteControl/status/changed` notification immediately after the initialize response, and
/// the catalog's strict notification allow-list turned that vendor drift into a hard
/// `protocolViolation`. `model/list` therefore never completed, no last-known-good catalog was
/// ever written, and Codex reported itself disconnected with "compatibility not established" -
/// while the transform path, and so the authenticated isolation audit and the shipped-pair
/// smoke, stayed green the whole time.
///
/// A fixture transport cannot catch protocol drift by construction: it replays bytes we already
/// believe in. Only the real handshake can. Keep this gate REQUIRED so a vendor adding a frame
/// fails here, loudly, instead of silently disabling a provider for the user.
///
/// Output is content-free by contract: counts and a diagnostic code only, never catalog payload
/// text, model copy, or anything read out of the daemon's params.
enum CodexCatalogLiveGate {
    static func run(arguments: [String]) -> Bool {
        var runner: String?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--runner", index + 1 < arguments.count {
                runner = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        // The verification bundle carries no Contents/Helpers, so bundledRunnerPath cannot
        // resolve here; the caller passes the shipped app's runner explicitly, exactly as
        // verify.sh already does for the production provider smoke.
        guard let runner, runner.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: runner) else {
            print("[codex-catalog-live] FAIL: --runner <absolute CodexContainmentRunner path> "
                    + "is required and must be executable")
            return false
        }

        // ABSTAIN when the apparatus is absent rather than reporting a product failure. A catalog
        // handshake needs an authenticated dedicated home; on a machine that has never connected
        // Codex there is nothing to hand shake WITH, and reddening the rail there teaches everyone
        // to ignore this gate - which is exactly how the drift it guards against hid in the first
        // place. Note `normal` in verify.sh does NOT mean "allowed to fail": run_service_gate
        // records a failure on ANY non-zero exit and only treats `required` as also forbidding a
        // skip. So abstention has to be an exit-0 SKIPPED marker, not a non-zero exit.
        let connection = CodexProviderRuntime.connectionState(runnerPath: runner)
        guard case .connected = connection else {
            let cause: String
            switch connection {
            case .connected: cause = "connected"
            case .disconnected: cause = "dedicated Codex home is not logged in"
            case .unavailable(let reason): cause = reason
            }
            print("[skip] [codex-catalog-live] SKIPPED apparatus unavailable: \(cause)")
            return true
        }

        // VDDBG_PATIENT lets a diagnosing run wait far past the production line-read
        // deadline, to separate "the daemon is slow" from "the daemon only answers once
        // our stdin closes". Not used by the verify gate.
        let bounds: CodexCatalogBounds =
            ProcessInfo.processInfo.environment["VDDBG_PATIENT"] != nil
            ? CodexCatalogBounds(wallClockSeconds: 90, lineReadSeconds: 45)
            : CodexCatalogBounds()
        let result = CodexModelCatalogProvider.refresh(
            checkedAt: ModelFreshnessProbe.checkedAtString(Date()),
            runnerPath: runner,
            bounds: bounds)

        let rows = result.catalog?.rows.count ?? 0
        let visible = result.catalog?.rows.filter { !$0.hidden }.count ?? 0
        print("[codex-catalog-live] diagnostic=\(result.diagnostic.rawValue) "
                + "stale=\(result.isStale) rows=\(rows) visible=\(visible)")

        guard result.diagnostic == .current else {
            print("[codex-catalog-live] FAIL real app-server handshake returned "
                    + "\(result.diagnostic.rawValue) instead of a current catalog")
            return false
        }
        guard !result.isStale, rows > 0, visible > 0 else {
            print("[codex-catalog-live] FAIL handshake reported current but produced no "
                    + "usable catalog rows")
            return false
        }
        print("[codex-catalog-live] PASS real app-server handshake produced a current catalog")
        return true
    }
}
