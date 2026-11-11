import Foundation

/// Pure decision logic for a dictation that starts INSIDE a sticky note. Before VDLAND2 this file also
/// carried the PINNED note target (`NotesBullseye` / `NotesBullseyeState`). The pin is gone: there is no
/// persisted note target, no arm/disarm state, and Option+N only opens or focuses the sticky notes. What
/// remains is the one rule a take still needs from here: whether the take's START note snapshot receives
/// the text (landing at the take-start field) or the requested destination does (end focus, the notes
/// key-window insert, or the foreign paste path).
enum NotesBullseyeLogic {
    /// The descriptor's requested landing shape. Raw / `?` delivery is an in-place dictation landing too,
    /// which lets it and one-shot in-place delivery consult the same rule.
    enum LandingKind: Equatable {
        case inPlace
        case nonDestructive
    }

    /// The input source latched from `takeHasSpeech` before a one-shot consumes the recording state. It is
    /// still threaded through by the one-shot callers (and still decides the gone-target fallback), but the
    /// VDLAND2 delivery rule no longer treats a selection differently: only the landing kind can suppress
    /// the take-start snapshot.
    enum InputSource: Equatable {
        case dictation
        case selection
    }

    /// Set/move + arm confirmation copy. The arm itself is gone; this one string is kept because
    /// `HUDProbe` uses it as a plain mid-take toast string.
    static let setToast = "Bullseye set + armed"
    /// Option+B armed / disarmed confirmations (feedback outside a take, where the info pill is not visible).
    static let armedToast = "Bullseye armed"
    static let disarmedToast = "Bullseye disarmed"

    /// Where a completed delivery lands. `.snapshot` is the note the take STARTED in (the take-start
    /// field); `.requested` means the take keeps its normal destination (the notes key-window insert, or
    /// live focus for a foreign app). There is no third destination any more: the pin is gone.
    enum Delivery: Equatable {
        case snapshot(noteId: String)
        case requested
    }

    /// The VDLAND2 delivery rule. A snapshot is offered first, and only for an in-place landing: a
    /// non-destructive mode keeps the mode-owned landing. `inputSource` stays a parameter because the
    /// one-shot callers already thread it, but it is deliberately not read — a selection transform that
    /// started in a note lands in that note's snapshot just like a dictation does.
    static func delivery(snapshotNoteId: String?, landingKind: LandingKind, inputSource: InputSource) -> Delivery {
        guard landingKind == .inPlace else { return .requested }
        if let id = snapshotNoteId, !id.isEmpty { return .snapshot(noteId: id) }
        return .requested
    }
}
