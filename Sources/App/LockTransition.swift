import Foundation

/// Pure model of the spacebar LOCK toggle + the take-end condition (item 6). Space (keyCode 49
/// -> `HotkeyMap` -> `.lock` -> `DictationController.toggleLock()`) is a PURE toggle between interface-unlocked
/// recording and hands-free locked; it NEVER ends the take. The take ends ONLY when right-Option is released
/// while UNLOCKED. `wasLocked` (the delivery-routing latch: once a take has ever been locked, delivery uses
/// captured-target paste) latches true on lock and STAYS latched through a later unlock so routing is unaffected.
///
/// The live recording state machine (audio, HUD, transcription) can't run headless, so this pure slice — how
/// `space` moves between recording and locked, whether `wasLocked` sticks, and when a right-Option release
/// actually ends the take — is extracted here so `--notes-probe` can pin the contract (mirrors
/// `NotesBullseyeLogic`). The stateful `DictationController` drives these same rules against the real engine.
enum LockTransition {
    /// The lock-relevant view of `DictationController.State`. `.recording` (interface unlocked, take live),
    /// `.locked` (hands-free), and `.other` (idle / finishing — space is a no-op there). The controller maps
    /// its private `State` onto this so the pure rules never depend on the full state enum.
    enum Phase: Equatable { case recording, locked, other }

    /// The outcome of a `space` press (`toggleLock`). `.lock` engages hands-free; `.unlock` returns to
    /// interface-unlocked recording WITHOUT ending the take (the pure toggle — the fix for item 6, which used
    /// to call `finish()`); `.ignore` leaves an idle/finishing machine untouched. Neither transition
    /// transcribes, delivers, or idles — those belong ONLY to the right-Option-release path.
    enum ToggleOutcome: Equatable { case lock, unlock, ignore }

    /// Map a `space` press to its outcome. Recording locks, locked unlocks (pure toggle — never a finish),
    /// idle/finishing is ignored.
    static func toggle(_ phase: Phase) -> ToggleOutcome {
        switch phase {
        case .recording: return .lock
        case .locked:    return .unlock
        case .other:     return .ignore
        }
    }

    /// The `wasLocked` delivery-routing latch after a `space` press. It latches true on lock and is PRESERVED
    /// (never cleared) through a later unlock, so a take that was ever locked keeps captured-target paste
    /// delivery. Idle/finishing (`.other`) is a no-op and returns the current value unchanged.
    static func wasLockedAfterToggle(current wasLocked: Bool, phase: Phase) -> Bool {
        switch phase {
        case .recording: return true        // lock latches it
        case .locked:    return wasLocked   // unlock preserves it (must never clear)
        case .other:     return wasLocked   // no-op
        }
    }

    /// Whether releasing right-Option ends the take. The take ends ONLY from interface-unlocked recording;
    /// while `.locked` the release is a no-op (hands-free — waiting for the unlock chord or Stop), and in
    /// idle/finishing there is no take to end.
    static func rightOptionReleaseEndsTake(_ phase: Phase) -> Bool {
        releaseEndsTake(phase: phase, hasArmedOneShot: false)
    }

    /// The complete right-Option release decision. An armed one-shot changes what runs when the take ends,
    /// but deliberately does not change whether this release ends it.
    static func releaseEndsTake(phase: Phase, hasArmedOneShot: Bool) -> Bool {
        phase == .recording
    }
}
