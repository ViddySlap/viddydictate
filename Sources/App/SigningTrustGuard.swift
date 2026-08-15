import Foundation

/// Launch-time self-heal for the stable code-signing identity (2026-07-13 incident).
///
/// A macOS update can wipe the user-domain trust-settings store. The RUNNING app never notices
/// (TCC matches the signature's certificate hash, trust not required), but the next `build.sh`
/// finds "ViddyDictate Self-Signed" invalid (CSSMERR_TP_NOT_TRUSTED) — and before the build-time
/// guard existed, builds silently fell back to ad-hoc signing, whose per-build cdhash voided the
/// Accessibility / Input-Monitoring grants on every rebuild (the no-paste + clipboard-park bug).
///
/// This guard re-blesses the existing cert in the background on every UI launch, so a wipe is
/// repaired long before anyone builds against it. It NEVER mints a new identity (that would reset
/// the TCC grants) — if the keychain or cert is missing it only logs. `build.sh` carries the same
/// heal as a second layer for builds on a machine where the app isn't running.
enum SigningTrustGuard {
    private static let cn = "ViddyDictate Self-Signed"
    private static let keychain = NSHomeDirectory() + "/Library/Keychains/vd-signing.keychain-db"

    /// Check-and-heal on a utility queue. Cheap when healthy (one `security find-identity`), and
    /// never touches the main thread — the event tap must stay serviced.
    static func healIfNeeded() {
        DispatchQueue.global(qos: .utility).async { healNow() }
    }

    private static func healNow() {
        guard FileManager.default.fileExists(atPath: keychain) else {
            Log.write("signing-trust: keychain missing — skip (run setup-signing.sh once)")
            return
        }
        if identityIsValid() { return }   // healthy — the common case, stay silent
        Log.write("signing-trust: identity INVALID (trust-settings wipe?) — restoring")
        let pem = security(["find-certificate", "-c", cn, "-p", keychain])
        guard pem.status == 0, pem.out.contains("BEGIN CERTIFICATE") else {
            Log.write("signing-trust: cert not found in keychain — cannot heal")
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-signing-heal-\(getpid()).pem")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try pem.out.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            Log.write("signing-trust: temp cert write failed — \(error.localizedDescription)")
            return
        }
        let add = security(["add-trusted-cert", "-p", "codeSign", "-k", keychain, tmp.path])
        if add.status == 0, identityIsValid() {
            Log.write("signing-trust: RESTORED trust for \(cn)")
        } else {
            Log.write("signing-trust: heal FAILED (add-trusted-cert exit \(add.status)) — "
                + "manual fix: security add-trusted-cert -p codeSign -k \(keychain) <cert.pem>")
        }
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
