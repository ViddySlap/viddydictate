import Foundation

/// A pure description of the first-run setup window's flow (the baton's "Locked flow spec"): the screens
/// it shows, in order, and what the welcome screen in front of the existing picker offers.
///
/// Closes gaps G-CHOICE and G-READY. `FirstRunSetupWindowController` consumes this directly - its own
/// `Step` is a `typealias` for `StepKind`, `WelcomeChooseView` draws one card per `setupChoices()` entry,
/// and `choose(_:)` calls `plan(for:facts:environment:)` through the same `begin(_:)` path Continue uses -
/// so there is one list of screens and one list of choices, not a production copy beside this pure one.
enum FirstRunSetupFlow {
    enum StepKind: Equatable, CaseIterable {
        case picker
        case permissions
        case progress
        case ready
    }

    /// The welcome screen's three cards (spec: Recommended / Advanced / Dictation only).
    enum SetupChoice: Equatable, CaseIterable {
        case recommended
        case advanced
        case dictationOnly
    }

    /// The screens shown, in order: the welcome/choose card deck and the existing picker share `.picker`
    /// (spec: the welcome screen is the FIRST PAGE of that step, not a step of its own), then Permissions,
    /// Progress, and the Ready step the window reaches once the queue settles.
    static func steps() -> [StepKind] { [.picker, .permissions, .progress, .ready] }

    /// The choices the welcome screen offers before the picker, in the order its cards are drawn.
    static func setupChoices() -> [SetupChoice] { [.recommended, .advanced, .dictationOnly] }

    /// What choosing `choice` installs. Recommended and Advanced both default to today's picker
    /// selection (Advanced then lets the user change it on the picker page itself); Dictation only skips
    /// every local-model app. No branch ever reaches a Codex component.
    static func plan(for choice: SetupChoice, facts: ComponentPicker.MachineFacts,
                     environment: ComponentPicker.Environment) -> ComponentPicker.InstallPlan {
        let selection: ComponentPicker.Selection
        switch choice {
        case .recommended, .advanced:
            selection = ComponentPicker.defaultSelection(facts: facts, environment: environment)
        case .dictationOnly:
            selection = ComponentPicker.selecting(.skip, from: ComponentPicker.Selection(),
                                                  facts: facts, environment: environment)
        }
        return ComponentPicker.installPlan(selection: selection, facts: facts, environment: environment)
    }
}
