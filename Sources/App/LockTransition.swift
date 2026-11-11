import Foundation

/// Pure model of the spacebar LOCK toggle + the take-end condition (item 6). Space (keyCode 49
/// -> `HotkeyMap` -> `.lock` -> `DictationController.toggleLock()`) is a PURE toggle between interface-unlocked
/// recording and hands-free locked; it NEVER ends the take. The take ends ONLY when right-Option is released
/// while UNLOCKED. `wasLocked` (the lock UI's latch: once a take has ever been locked, it stays latched through
/// a later unlock) no longer decides where text lands — landing is decided by `LandingRoute` (VDLAND1).
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

    /// The `wasLocked` lock latch after a `space` press. It latches true on lock and is PRESERVED (never cleared)
    /// through a later unlock, so the lock UI can tell a hands-free take from a push-to-talk take. Since VDLAND1
    /// it decides NOTHING about delivery: `LandingRoute` alone routes a take. Idle/finishing (`.other`) is a
    /// no-op and returns the current value unchanged.
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

// MARK: - Landing route (VDLAND1)

/// Where a completed take lands. The ONE rule: `Settings.bullseyeLandAtStart`, copied per take, decides.
///
/// ON  — the take lands in the field that was focused at take START (or in the sticky note the take
///       started in, through its take-start snapshot), whether the take was push-to-talk or locked.
/// OFF — the take lands in whatever field is focused when the take ENDS.
///
/// The spacebar LOCK plays no part: it is the hands-free latch, nothing else. Pure, so `--notes-probe` can pin
/// every branch headlessly; `DictationController` drives the same values against the live machine.
enum LandingRoute {
    /// The delivery branch for one take. `.pinnedNoTarget` is "land at the start field", but there is no
    /// captured target to land in, so the locked no-target path (clipboard-preserving) runs.
    enum Route: Equatable { case live, pinned, pinnedNoTarget }

    static func route(bullseyeOn: Bool, hasTarget: Bool) -> Route {
        guard bullseyeOn else { return .live }
        return hasTarget ? .pinned : .pinnedNoTarget
    }

    /// Whether the paste-target marker follows LIVE focus (the setting is OFF) or sits on the field captured
    /// at take start (the setting is ON).
    static func markerFollowsLive(bullseyeOn: Bool) -> Bool { !bullseyeOn }

    /// The Option+B toast: the bare armed/disarmed copy, plus a "for the next dictation" suffix while a take is
    /// in flight, so a mid-take change is never silent about which take it applies to.
    static func toggleToast(on: Bool, takeInFlight: Bool) -> String {
        let base = on ? NotesBullseyeLogic.armedToast : NotesBullseyeLogic.disarmedToast
        return takeInFlight ? base + " for the next dictation" : base
    }
}
