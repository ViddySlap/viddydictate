import Cocoa
import CoreGraphics

/// macOS Secure Keyboard Entry. While any app holds it (a focused password or PIN field, Terminal's
/// "Secure Keyboard Entry", a password manager), the system hides every keyDown from every event tap.
/// Modifier changes still arrive, so right-Option hold-to-talk keeps working while every right-Option
/// chord (Space lock, H, D, B...) silently does nothing. Chrome is known to keep holding it after its
/// password field loses focus (seen 2026-11-09). This file names the holder so the HUD can say so.
enum SecureInput {
    struct Holder: Equatable {
        let pid: pid_t
        let appName: String
    }

    /// The app holding Secure Keyboard Entry right now, or nil when nobody holds it. Reads the window
    /// server's session dictionary, the same `kCGSSessionSecureInputPID` that `ioreg -l` shows.
    static func currentHolder() -> Holder? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let raw = dict["kCGSSessionSecureInputPID"] as? NSNumber else { return nil }
        let pid = pid_t(raw.int32Value)
        guard pid > 0 else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return Holder(pid: pid, appName: name)
    }
}

/// Decides when to show the warning. Pure, so the self-test can drive it with fake clocks and holders.
/// It warns on the first right-Option press of each episode (a new holder, or the same holder again
/// after it let go), then at most once every `repeatInterval` while the same holder keeps it, so
/// ordinary hold-to-talk, which still works, is not nagged on every press.
struct SecureInputWarningGate {
    static let repeatInterval: TimeInterval = 600

    private var lastWarnedPid: pid_t?
    private var lastWarnedAt: TimeInterval = 0

    /// Call on every wakeup press with the current holder. Returns the toast text to show, or nil.
    mutating func check(holder: SecureInput.Holder?, ownPid: pid_t, now: TimeInterval) -> String? {
        guard let holder, holder.pid != ownPid else {
            lastWarnedPid = nil   // episode over: the next hold by anyone warns again
            return nil
        }
        if holder.pid == lastWarnedPid, now - lastWarnedAt < Self.repeatInterval { return nil }
        lastWarnedPid = holder.pid
        lastWarnedAt = now
        return Self.message(appName: holder.appName)
    }

    static func message(appName: String) -> String {
        "⚠️ \(appName) has secure typing on, so ViddyDictate's key shortcuts (like the lock) won't work. "
            + "Hold-to-talk still works. Click out of its password field, or quit \(appName)."
    }
}
