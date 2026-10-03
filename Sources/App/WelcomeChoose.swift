import Cocoa

/// Copy and identity for the welcome/choose screen (spec section 1, gap G-CHOICE): the first page of the
/// `.picker` step, three cards wide, one click away from starting the install.
///
/// This file holds no judgement of its own - `FirstRunSetupFlow.setupChoices()` is the list, in order, and
/// `WelcomeChooseView` draws one card per entry it returns rather than three hand-written ones, so a choice
/// added there appears here without a second edit.
enum WelcomeChoose {
    static let headline = "Welcome to ViddyDictate"
    static let subtitle = "Pick a setup. Each one gets you dictating; the difference is how much you choose."
    /// The spec's line under the cards: the one thing a stranger needs told, since the app itself has no
    /// window once setup is done.
    static let menuBarNote = "ViddyDictate lives in your menu bar. Look for the microphone icon."

    static func title(_ choice: FirstRunSetupFlow.SetupChoice) -> String {
        switch choice {
        case .recommended: return "Recommended"
        case .advanced: return "Advanced"
        case .dictationOnly: return "Dictation only"
        }
    }

    /// The one-line why (spec section 1).
    static func detail(_ choice: FirstRunSetupFlow.SetupChoice) -> String {
        switch choice {
        case .recommended:
            return "Speech engine + LM Studio. The easiest way to get dictation and AI cleanup working."
        case .advanced:
            return "Choose components yourself: LM Studio or Ollama, and which models to install."
        case .dictationOnly:
            return "Just the speech engine. The smallest install; add a local model later from Setup."
        }
    }

    static let recommendedBadge = "DEFAULT"

    enum Part: String, CaseIterable {
        case badge
        case title
        case detail
    }

    static func identifier(_ part: Part, _ choice: FirstRunSetupFlow.SetupChoice) -> String {
        "welcome-choose-\(choice)-\(part.rawValue)"
    }

    static func cardIdentifier(_ choice: FirstRunSetupFlow.SetupChoice) -> String {
        "welcome-choose-card-\(choice)"
    }

    static let surfaceIdentifier = "welcome-choose"
    static let headlineIdentifier = "welcome-choose-headline"
    static let subtitleIdentifier = "welcome-choose-subtitle"
    static let menuBarNoteIdentifier = "welcome-choose-menu-bar-note"
    static let setUpLaterIdentifier = "welcome-choose-set-up-later"
}
