import Cocoa

/// Copy and identity for the Ready screen (spec section 2, gap G-READY): the window's last step, shown
/// once the install queue has settled - everything either landed or failed, nothing left waiting or
/// running.
enum ReadyStep {
    static let headline = "You're ready"
    static let allDoneSubtitle = "Everything you picked is installed."
    static let degradedSubtitle = "Setup finished, but something needs another look."

    static let permissionsAllGrantedLine = "All three permissions are granted."
    static let resumeSetupTitle = "Resume setup"
    static let relaunchTitle = "Relaunch ViddyDictate"
    static let doneTitle = "Done"
    /// D9's practice box header, named once here so the Ready screen reads as the same feature the
    /// Feature Tour teaches rather than a second thing with a different name.
    static let practiceHeader = "TRY IT"

    enum Part: String, CaseIterable {
        case status
        case resume
    }

    static func identifier(_ part: Part, _ id: ComponentPicker.RowID) -> String {
        "ready-\(id.rawValue)-\(part.rawValue)"
    }

    static func rowIdentifier(_ id: ComponentPicker.RowID) -> String { "ready-row-\(id.rawValue)" }

    static let surfaceIdentifier = "ready-step"
    static let headlineIdentifier = "ready-headline"
    static let subtitleIdentifier = "ready-subtitle"
    static let permissionsSummaryIdentifier = "ready-permissions-summary"
    static let menuBarNoteIdentifier = "ready-menu-bar-note"
    static let practiceCardIdentifier = "ready-practice-card"
    static let practiceNoteIdentifier = "ready-practice-note"
    static let practiceFieldIdentifier = "ready-practice-field"
    static let relaunchIdentifier = "ready-relaunch-button"
    static let relaunchCaptionIdentifier = "ready-relaunch-caption"
    static let doneIdentifier = "ready-done-button"
}
