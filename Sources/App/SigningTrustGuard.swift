import Foundation

/// Launch-time check on the stable code-signing identity (2026-07-13 incident).
///
/// A macOS update can wipe the user-domain trust-settings store. The RUNNING app never notices
/// (TCC matches the signature's certificate hash, trust not required), but the next `build.sh`
/// finds "ViddyDictate Self-Signed" invalid (CSSMERR_TP_NOT_TRUSTED) — and before the build-time
/// guard existed, builds silently fell back to ad-hoc signing, whose per-build cdhash voided the
/// Accessibility / Input-Monitoring grants on every rebuild (the no-paste + clipboard-park bug).
///
/// This guard used to REPAIR the trust store here, by shelling out to `security add-trusted-cert`
/// on every launch. That is no longer done, for two reasons:
///
///   1. The signing keychain now auto-locks and its password is not stored anywhere, so the repair
///      could not succeed unattended. It would raise a keychain password dialog on every launch.
///   2. An app holding Accessibility and Input Monitoring should not be mutating the trust store as
///      a background side effect of starting up.
///
/// `build.sh` carries the same heal and runs it immediately before signing, which is the only
/// moment the trust state actually matters. This is now observation only: it records the condition
/// so the log explains a later build-time failure.
enum SigningTrustGuard {
    private static let cn = "ViddyDictate Self-Signed"
    private static let keychain = NSHomeDirectory() + "/Library/Keychains/vd-signing.keychain-db"

    /// Check on a utility queue. Cheap (one `security find-identity`), never touches the main
    /// thread — the event tap must stay serviced.
    static func healIfNeeded() {
        DispatchQueue.global(qos: .utility).async { checkNow() }
    }

    private static func checkNow() {
        guard FileManager.default.fileExists(atPath: keychain) else {
            Log.write("signing-trust: keychain missing — skip (run setup-signing.sh once)")
            return
        }
        if identityIsValid() { return }   // healthy, or simply locked — the common case, stay silent
        // A locked keychain is indistinguishable from a wiped trust store here, and locked is the
        // expected resting state, so this is not treated as an error.
        Log.write("signing-trust: identity not resolvable (keychain locked, or trust-settings "
            + "wipe). build.sh repairs trust before signing; no action taken at runtime.")
    }

    private static func identityIsValid() -> Bool {
        security(["find-identity", "-v", "-p", "codesigning", keychain]).out.contains(cn)
    }

    private static func security(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
