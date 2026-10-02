import Foundation

/// A pure description of the first-run setup window's flow (the baton's "Locked flow spec"): the screens
/// it shows, in order, and what a welcome screen in front of the existing picker would offer.
///
/// Seam only, for gaps G-CHOICE and G-READY. 42eec8e has no welcome/choose screen at all -
/// `ComponentPickerView` IS the first screen, by way of `FirstRunSetupWindowController.Step` (picker,
/// permissions, progress) - and no Ready step at the end. This stub reproduces that exactly: three
/// steps, no choices. Nothing in `FirstRunSetupWindowController` reads this type yet; a later link wires
/// it in once the welcome screen and the Ready step exist.
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

    /// The screens shown, in order. 42eec8e's three, with no welcome/choose step in front and no Ready
    /// step at the end.
    static func steps() -> [StepKind] { [.picker, .permissions, .progress] }

    /// The choices a welcome screen would offer before the picker. Empty today, because there is no such
    /// screen: the existing picker is reached directly, which is what `.advanced` will eventually mean.
    static func setupChoices() -> [SetupChoice] { [] }

    /// What choosing `choice` would install, once a welcome screen exists to make the choice. Unreachable
    /// from production today (`setupChoices()` is empty) and kept total only so a selftest can already
    /// pin its SHAPE, and assert that no choice's plan ever contains a Codex component.
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
