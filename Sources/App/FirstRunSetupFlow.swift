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
    ///
    /// `localApp` is the welcome card's "Local models app" choice and is honored by `.recommended` alone:
    /// `.lmStudio` keeps today's plan exactly (the default, so every pre-existing caller is unchanged),
    /// while `.ollama` asks the picker's own `selecting(.ollama, ...)` for the Ollama rows and their
    /// model pulls. `.advanced` and `.dictationOnly` ignore it, as their own screens own that choice.
    static func plan(for choice: SetupChoice, facts: ComponentPicker.MachineFacts,
                     environment: ComponentPicker.Environment,
                     localApp: LocalBackendID = .lmStudio) -> ComponentPicker.InstallPlan {
        let selection: ComponentPicker.Selection
        switch choice {
        case .recommended:
            // The welcome card's selector is honored here and ONLY here. Ollama asks the picker for its
            // own Ollama selection (`selecting(.ollama, ...)`, the same call its Ollama radio makes), so
            // the two Ollama rows and their tags come from the picker rather than a hand-built list. LM
            // Studio (the default) keeps the historical `defaultSelection` path byte for byte.
            if localApp == .ollama {
                selection = ComponentPicker.selecting(.ollama, from: ComponentPicker.Selection(),
                                                      facts: facts, environment: environment)
            } else {
                selection = ComponentPicker.defaultSelection(facts: facts, environment: environment)
            }
        case .advanced:
            selection = ComponentPicker.defaultSelection(facts: facts, environment: environment)
        case .dictationOnly:
            selection = ComponentPicker.selecting(.skip, from: ComponentPicker.Selection(),
                                                  facts: facts, environment: environment)
        }
        return ComponentPicker.installPlan(selection: selection, facts: facts, environment: environment)
    }
}
