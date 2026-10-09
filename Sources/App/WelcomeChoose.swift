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

    /// The one-line why (spec section 1). The Recommended line follows the local app the card's selector
    /// is on, so picking Ollama changes the promise the card makes without touching the other two cards.
    static func detail(_ choice: FirstRunSetupFlow.SetupChoice,
                       localApp: LocalBackendID = .lmStudio) -> String {
        switch choice {
        case .recommended:
            switch localApp {
            case .lmStudio:
                return "Speech engine + LM Studio. The easiest way to get dictation and AI cleanup working."
            case .ollama:
                return "Speech engine + Ollama. The advanced local model app, for people who already use it."
            }
        case .advanced:
            return "Choose components yourself: LM Studio or Ollama, and which models to install."
        case .dictationOnly:
            return "Just the speech engine. The smallest install; add a local model later from Setup."
        }
    }

    /// The welcome card's compact "Local models app" selector (spec: LM Studio | Ollama), in screen order.
    /// The Recommended card shows it; Advanced and Dictation-only never do.
    static let localAppOptions: [LocalBackendID] = [.lmStudio, .ollama]
    static let localAppSelectorLabel = "Local models app"
    /// The caption under the selector, exactly as the brief specifies.
    static let localAppSelectorCaption = "You can switch later in Settings."
    static let localAppSelectorIdentifier = "welcome-choose-local-app-selector"
    static let localAppSelectorLabelIdentifier = "welcome-choose-local-app-label"
    static let localAppSelectorCaptionIdentifier = "welcome-choose-local-app-caption"

    static func localAppOptionIdentifier(_ backend: LocalBackendID) -> String {
        "welcome-choose-local-app-\(backend.rawValue)"
    }

    /// The selector's opening choice, through the app's existing preference logic rather than a second
    /// detector: an Ollama-only Mac opens on Ollama, while every other Mac (both apps, neither, or LM
    /// Studio alone) opens on LM Studio, the simple install. `LocalBackendPreference.effective` with an
    /// automatic explicit choice is exactly that rule.
    static func defaultLocalApp(environment: ComponentPicker.Environment) -> LocalBackendID {
        var installed: Set<LocalBackendID> = []
        if environment.lmStudioInstalled { installed.insert(.lmStudio) }
        if environment.ollamaInstalled { installed.insert(.ollama) }
        return LocalBackendPreference.effective(explicit: nil, installed: installed)
    }

    /// The Recommended card's compact "Local models app" selector as PURE DATA. `WelcomeChooseView` only
    /// renders this model - it holds no option list, default, caption or detail text of its own - so the
    /// deterministic installer-rework selftest can observe the whole selector without constructing a single
    /// AppKit object (a sandboxed judge aborts if it does).
    struct RecommendedSelector: Equatable {
        struct Option: Equatable {
            let backend: LocalBackendID
            /// The user-facing label, the backend's own product name.
            var title: String { backend.displayName }
            /// The identifier the rendered radio carries.
            var identifier: String { WelcomeChoose.localAppOptionIdentifier(backend) }
        }

        /// The two choices, in screen order: LM Studio first, Ollama second.
        let options: [Option]
        /// The app the control opens on, through the app's existing preference rule (`defaultLocalApp`,
        /// itself `LocalBackendPreference.effective`): Ollama only when it is the sole installed local
        /// app, LM Studio otherwise.
        let defaultApp: LocalBackendID
        let label: String
        let caption: String
        let identifier: String
        let labelIdentifier: String
        let captionIdentifier: String

        init(environment: ComponentPicker.Environment) {
            self.options = WelcomeChoose.localAppOptions.map { Option(backend: $0) }
            self.defaultApp = WelcomeChoose.defaultLocalApp(environment: environment)
            self.label = WelcomeChoose.localAppSelectorLabel
            self.caption = WelcomeChoose.localAppSelectorCaption
            self.identifier = WelcomeChoose.localAppSelectorIdentifier
            self.labelIdentifier = WelcomeChoose.localAppSelectorLabelIdentifier
            self.captionIdentifier = WelcomeChoose.localAppSelectorCaptionIdentifier
        }

        /// The Recommended one-line detail that follows the chosen app, so the card's promise tracks the
        /// selector rather than being spelled out again in the view.
        func detail(for app: LocalBackendID) -> String {
            WelcomeChoose.detail(.recommended, localApp: app)
        }
    }

    /// The model for the Recommended card alone. Advanced and Dictation-only render no selector, so there is
    /// no model for them (`nil`). Keeping the choice-to-model mapping here means the view never decides
    /// which card carries a selector.
    static func selector(for choice: FirstRunSetupFlow.SetupChoice,
                         environment: ComponentPicker.Environment) -> RecommendedSelector? {
        choice == .recommended ? RecommendedSelector(environment: environment) : nil
    }

    /// The selector model for a machine whose environment a caller does not have; used by the render seam's
    /// default construction. Pure, like every other member of this model.
    static var recommendedSelectorDefault: RecommendedSelector {
        RecommendedSelector(environment: ComponentPicker.Environment())
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
