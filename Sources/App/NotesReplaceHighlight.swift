import Foundation

/// Pure decision + modelling logic for the four-color REPLACE HIGHLIGHT (notes-bullseye BT4).
///
/// A pending level-based operation that will REPLACE note text tints that text with one of four colors keyed
/// to Raw / Cleanup / Tighten / Summarize, so the user sees exactly what is about to be overwritten and at
/// which strength. It covers BOTH replace-flows:
///   - the Option+P selection-transform pick — tint the note selection to the focused level, live-updating as
///     the pick moves (Cleanup / Tighten / Summarize; never Raw, since the picker has no Raw cell);
///   - a dictation take overwriting a selection — tint by the active `?`-cleanup level, or the Raw color when
///     cleanup is off.
/// It clears on cancel (Esc) or commit. Email/custom one-shot modes are NOT tinted. The tint is a CodeMirror
/// decoration in the notes web island (never the HUD).
///
/// This type carries NO AppKit / CodeMirror state so the `--notes-probe` seam can lock the contract
/// headlessly; the live editor renders the equivalent CodeMirror `mark` decoration (`replaceHighlight` in the
/// bundled web island), and the probe pins these funcs + the JS/CSS shipping.
enum NotesReplaceHighlightLogic {
    /// The four replace-highlight colors, keyed to the pending operation. The rawValue IS the wire token
    /// pushed to the island (which forms the CSS class `cm-replace-<rawValue>`); Swift and JS both derive the
    /// class from it, so a rename goes red in the probe rather than silently losing the tint.
    enum Level: String, CaseIterable {
        case raw, cleanup, tighten, summarize
    }

    /// The CSS class the island tints the range with for a given level. Mirrored by the JS `replaceClass`.
    static func cssClass(_ level: Level) -> String { "cm-replace-\(level.rawValue)" }

    /// The replace-highlight level for an Option+P pick: the picker offers only the three CleanupLevels
    /// (Cleanup / Tighten / Summarize) — never Raw — so a picked level maps straight across.
    static func from(_ level: CleanupLevel) -> Level {
        switch level {
        case .cleanup:   return .cleanup
        case .tighten:   return .tighten
        case .summarize: return .summarize
        }
    }

    /// The replace-highlight level for a dictation take overwriting a selection: the Raw color when cleanup is
    /// off, otherwise the active `?`-cleanup strength level.
    static func level(cleanupEnabled: Bool, cleanupLevel: CleanupLevel) -> Level {
        cleanupEnabled ? from(cleanupLevel) : .raw
    }

    /// Whether the replace highlight should render in the editor right now. It shows ONLY when a non-empty
    /// STORED range was captured (a deterministic snapshot of the range to replace — NOT the live selection at
    /// push time, which the Option+P picker leaves stale), in the note it was captured for, when that note is
    /// the active (non-history) editor note. No stored range (nothing to replace), a different active note, the
    /// history view, or a missing id -> no tint. Pure mirror of the JS `syncReplaceHighlight` gate — which
    /// renders from `getReplaceHighlight()`'s stored range — so the probe can lock the contract headlessly; the
    /// CodeMirror mark render needs live GUI verification.
    static func highlightVisible(hasStoredRange: Bool, highlightNoteId: String?,
                                 activeNoteId: String?, showingHistory: Bool) -> Bool {
        guard hasStoredRange, !showingHistory,
              let highlightNoteId = highlightNoteId, !highlightNoteId.isEmpty,
              let activeNoteId = activeNoteId else { return false }
        return highlightNoteId == activeNoteId
    }
}
