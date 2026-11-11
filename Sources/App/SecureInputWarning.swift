import Cocoa
import CoreGraphics

/// macOS Secure Keyboard Entry. While any app holds it (a focused password or PIN field, Terminal's
/// "Secure Keyboard Entry", a password manager), the system hides every keyDown from every event tap.
/// Modifier changes still arrive, so right-Option hold-to-talk and any command bound to modifiers alone
/// keep working, while every command that needs a regular key (right-Option+H, D, B...) silently does nothing. Chrome is known to keep holding it after its
/// password field loses focus (seen 2026-11-09). This file names the holder so the HUD can say so.
enum SecureInput {
    /// The pid of the app holding Secure Keyboard Entry right now, or nil when nobody holds it. Reads the
    /// window server's session dictionary, the same `kCGSSessionSecureInputPID` that `ioreg -l` shows. It
    /// does nothing else: the app name is resolved by `appName(pid:)` only when a warning is about to show.
    static func currentHolderPid() -> pid_t? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let raw = dict["kCGSSessionSecureInputPID"] as? NSNumber else { return nil }
        let pid = pid_t(raw.int32Value)
        guard pid > 0 else { return nil }
        return pid
    }

    /// The holder's display name. Called only after the gate decided to warn.
    static func appName(pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
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

    /// Call on every wakeup press with the current holder's pid. Returns the pid to warn about, or nil.
    /// It does no name lookup: the caller resolves the name only after the take has started.
    mutating func shouldWarn(holderPid: pid_t?, ownPid: pid_t, now: TimeInterval) -> pid_t? {
        guard let holderPid, holderPid != ownPid else {
            lastWarnedPid = nil   // episode over: the next hold by anyone warns again
            return nil
        }
        if holderPid == lastWarnedPid, now - lastWarnedAt < Self.repeatInterval { return nil }
        lastWarnedPid = holderPid
        lastWarnedAt = now
        return holderPid
    }

    /// `shouldWarn` plus the toast text. `appName` runs only when a warning will be returned, never for no
    /// holder, the app's own pid or a throttled repeat.
    mutating func check(holderPid: pid_t?, ownPid: pid_t, now: TimeInterval,
                        appName: (pid_t) -> String) -> String? {
        guard let pid = shouldWarn(holderPid: holderPid, ownPid: ownPid, now: now) else { return nil }
        return Self.message(appName: appName(pid))
    }

    static func message(appName: String) -> String {
        "⚠️ \(appName) has secure typing on, so ViddyDictate shortcuts that need a regular key (like right-Option+H) won't work. "
            + "Hold-to-talk still works. Click out of its password field, or quit \(appName)."
    }
}

/// The order of one right-Option press after the gate decided: start the take first, then (only if the take
/// started and a warning is due) resolve the holder's name and show the toast. Pure, so the self-test can
/// prove the name is never resolved before `beginRecording` returns.
enum SecureInputPress {
    /// Returns the warning to show again at release, or nil (no warning due, or the take failed to start).
    static func afterGate(warnPid: pid_t?, beginRecording: () -> Bool,
                          appName: (pid_t) -> String, toast: (String) -> Void) -> String? {
        let started = beginRecording()
        guard started, let warnPid else { return nil }
        let warning = SecureInputWarningGate.message(appName: appName(warnPid))
        toast(warning)
        return warning
    }
}
