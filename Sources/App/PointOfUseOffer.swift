import Foundation

/// B13, B14 and B16 as one pure decision: what a user is offered at the exact moment they reach for a
/// feature this machine cannot run yet.
///
/// **The rule this file exists to enforce is B16.** With no local model installed, pressing a hotkey must
/// never route dictated text to Claude or Codex. It may only ever produce a BUTTON that says so. That is
/// enforced here structurally rather than by care: `PointOfUseRoute` can express skipping, an install, and
/// opening a provider's guided sign-in panel, and there is no case that runs a transform. A future cloud
/// hop would have to be a new case added on purpose, and `--point-of-use-offer-selftest` reds if one appears.
///
/// Everything below is Foundation-only and takes its facts as arguments, so the whole offer surface is
/// decidable offline from a measurement someone else made.
enum PointOfUseRoute: Equatable {
    /// Leave it. The user's text is already where it was; nothing is installed and nothing is sent.
    case skip
    /// Install the feature's own outstanding components through the first-run installer.
    case install
    /// Open the guided sign-in panel for a cloud provider (B17). Opening a panel is not running a route:
    /// the user still has to sign in, and the mode still has to be pressed again afterwards.
    case guidedProvider(LLMProvider)

    /// Discriminator so a gate can assert that these three are the ONLY things a point-of-use button can
    /// do. A fourth case - "run this on Claude", say - would have to be added deliberately and would red
    /// `--point-of-use-offer-selftest`. That is the whole enforcement of B16 on this surface: not that
    /// nobody wrote an automatic cloud hop, but that there is no case in which one could be expressed.
    enum Kind: String, CaseIterable {
        case skip
        case install
        case guidedProvider
    }

    var kind: Kind {
        switch self {
        case .skip: return .skip
        case .install: return .install
        case .guidedProvider: return .guidedProvider
        }
    }
}

/// One thing a hotkey needs, as data. Adding a mode is a row here, not a second offer implementation.
struct PointOfUseFeature: Equatable {
    /// Whether a signed-in cloud provider is an honest answer for this feature.
    enum Satisfaction: Equatable {
        /// Only this machine can do it. Transcription and the local search helper are not things Claude
        /// or Codex can stand in for, so the four-button chooser is never offered for them.
        case localOnly
        /// Any signed-in text provider could do it, which is what makes B14's chooser applicable.
        case textProvider
    }

    let id: String
    /// How the user would name it: "Email mode", not "email".
    let title: String
    let hotkey: String
    let satisfaction: Satisfaction
    /// In dependency order. LM Studio before the model it holds, because a model row cannot run before
    /// the CLI that fetches it exists.
    let components: [InstallerComponentDescriptor]

    static let dictation = PointOfUseFeature(
        id: "dictation", title: "Dictation", hotkey: "right Option",
        satisfaction: .localOnly,
        components: [BootstrapInstallPlan.sttDaemon])

    static let webSearch = PointOfUseFeature(
        id: "web-search", title: "Web search", hotkey: "Option+L",
        satisfaction: .localOnly,
        components: [BootstrapInstallPlan.webSearch])

    static let email = PointOfUseFeature(
        id: "email", title: "Email mode", hotkey: "Option+M",
        satisfaction: .textProvider,
        components: [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.gemma])

    static let cleanup = PointOfUseFeature(
        id: "cleanup", title: "Cleanup", hotkey: "the ? slider",
        satisfaction: .textProvider,
        components: [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.qwen])

    static let promptPrep = PointOfUseFeature(
        id: "prompt-prep", title: "Prompt prep", hotkey: "Option+P",
        satisfaction: .textProvider,
        components: [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.qwen])

    static let all = [dictation, webSearch, email, cleanup, promptPrep]

    /// The feature behind a route, so a landing that already knows which route it ran can ask for the
    /// offer without a second mapping table growing somewhere else.
    static func forRoute(_ route: LLMRouteID) -> PointOfUseFeature? {
        switch route {
        case .email: return email
        case .promptPrep: return promptPrep
        case .cleanupL1, .cleanupL2, .cleanupL3: return cleanup
        default: return nil
        }
    }
}

/// One button on the offer panel.
struct PointOfUseButton: Equatable {
    let id: String
    let title: String
    /// One line under the title saying what pressing it actually does. A button whose consequence is not
    /// stated is the thing B1's reasoning is against: a choice the user did not understand is not consent.
    let detail: String
    let route: PointOfUseRoute
}

/// B13's in-place offer: what the feature needs, and the one button that gets it.
struct PointOfUseInstallOffer: Equatable {
    let featureID: String
    /// How the user names the feature. Carried beside the id because the running page has a heading of
    /// its own, and reading "INSTALLING - EMAIL" there instead of "EMAIL MODE" is the id leaking into a
    /// user-facing string.
    let featureTitle: String
    let header: String
    let lines: [String]
    /// The outstanding components, in dependency order. This is exactly what is handed to the first-run
    /// installer - the same descriptors, the same engine, a second entry point rather than a second path.
    let components: [InstallerComponentDescriptor]
    let buttons: [PointOfUseButton]

    var totalDownloadBytes: Int64? {
        let measured = components.compactMap(\.downloadBytes)
        guard measured.count == components.count, !measured.isEmpty else { return nil }
        return measured.reduce(0, +)
    }
}

/// B14's four-button chooser: the user has nothing at all installed, so every available route is offered
/// at once rather than one of them being taken on their behalf.
struct PointOfUseChooser: Equatable {
    let featureID: String
    let header: String
    let lines: [String]
    let buttons: [PointOfUseButton]
    /// The components "Set up local models" would install, kept beside the chooser so pressing that button
    /// enters the same install offer rather than a second flow.
    let localComponents: [InstallerComponentDescriptor]
}

enum PointOfUseOffer: Equatable {
    case install(PointOfUseInstallOffer)
    case chooser(PointOfUseChooser)

    var featureID: String {
        switch self {
        case .install(let offer): return offer.featureID
        case .chooser(let chooser): return chooser.featureID
        }
    }

    var header: String {
        switch self {
        case .install(let offer): return offer.header
        case .chooser(let chooser): return chooser.header
        }
    }

    var lines: [String] {
        switch self {
        case .install(let offer): return offer.lines
        case .chooser(let chooser): return chooser.lines
        }
    }

    var buttons: [PointOfUseButton] {
        switch self {
        case .install(let offer): return offer.buttons
        case .chooser(let chooser): return chooser.buttons
        }
    }

    /// Content-safe one-line record for the app log. Feature identity and button ids only: this surface
    /// appears at the exact moment a transcript was in flight, so it must not be able to log one.
    var logToken: String {
        let kind: String
        switch self {
        case .install: kind = "install"
        case .chooser: kind = "chooser"
        }
        return "point-of-use offer=\(kind) feature=\(featureID) "
            + "buttons=\(buttons.map(\.id).joined(separator: ","))"
    }
}

enum PointOfUsePolicy {

    /// Whether a component is already in place. `nil` means the measuring apparatus did not answer, which
    /// is deliberately NOT folded into "missing": offering to install a model while LM Studio is merely
    /// stopped would send the user on a several-gigabyte errand to fix a thing that is already there.
    static func isSatisfied(_ component: InstallerComponentDescriptor,
                            presences: [LLMProvider: LLMProviderDetection.Presence],
                            bootstrap: BootstrapSnapshot) -> Bool? {
        guard !component.lmStudioSteps.isEmpty else {
            return bootstrap.isComponentUsable(component.id)
        }
        let local = presences[.local]
        // These steps are LM Studio's: its app, and a model in IT. A merged `.local` presence also counts
        // Ollama, so when it carries per-app readings, LM Studio's own reading answers: its install, and its
        // catalog (nil while it is stopped, even when Ollama's answered). Models match on the app too, since
        // the same id in Ollama is not the LM Studio model this row would install. A hand-built presence
        // without the breakdown keeps the single-app reading.
        let lmStudio = local.flatMap { $0.localReading(.lmStudio) }
        let lmStudioInstalled = lmStudio.map(\.installed) ?? local?.installed
        let lmStudioModels = lmStudio.map(\.models) ?? local?.availableLocalModels
        for step in component.lmStudioSteps {
            switch step {
            case .application:
                guard let lmStudioInstalled else { return nil }
                if !lmStudioInstalled { return false }
            case .model(let modelID):
                guard let lmStudioInstalled else { return nil }
                guard lmStudioInstalled else { return false }
                guard let models = lmStudioModels else { return nil }
                if !models.contains(where: { $0.backend == .lmStudio && $0.modelID == modelID }) {
                    return false
                }
            }
        }
        return true
    }

    /// True only when the machine measurably has nothing: no local model, no Claude CLI, no Codex CLI.
    /// An unmeasured provider is never counted as absent - that is the false negative that would put the
    /// cloud chooser in front of a user who already has a signed-in provider.
    static func hasNothingInstalled(
        presences: [LLMProvider: LLMProviderDetection.Presence]) -> Bool {
        guard let local = presences[.local], let claude = presences[.claude],
              let codex = presences[.codex] else { return false }
        let noLocalModel: Bool
        if !local.installed {
            noLocalModel = true
        } else if let models = local.availableLocalModels {
            noLocalModel = models.isEmpty
        } else {
            return false
        }
        return noLocalModel && !claude.installed && !codex.installed
    }

    /// The whole decision. `nil` means say nothing: either the feature is already installed, or something
    /// could not be measured and a panel would be guessing at the user's expense.
    static func offer(for feature: PointOfUseFeature,
                      presences: [LLMProvider: LLMProviderDetection.Presence],
                      bootstrap: BootstrapSnapshot) -> PointOfUseOffer? {
        var outstanding: [InstallerComponentDescriptor] = []
        for component in feature.components {
            guard let satisfied = isSatisfied(component, presences: presences, bootstrap: bootstrap) else {
                return nil
            }
            if !satisfied { outstanding.append(component) }
        }
        guard !outstanding.isEmpty else { return nil }

        if feature.satisfaction == .textProvider, hasNothingInstalled(presences: presences) {
            return .chooser(chooser(for: feature, localComponents: outstanding))
        }
        return .install(installOffer(for: feature, outstanding: outstanding))
    }

    // MARK: - Copy
    //
    // O7: the spec's strings are the intent and the tone is "plain, specific, names the user's actual
    // situation". These name the feature, the exact component, and the measured size when there is one -
    // and never invent a "Setup failed. Please try again."-class line.

    static func installOffer(for feature: PointOfUseFeature,
                             outstanding: [InstallerComponentDescriptor]) -> PointOfUseInstallOffer {
        var lines = [needsLine(feature: feature, outstanding: outstanding)]
        // B13: when LM Studio itself is missing, the SAME panel says so and installs it first, rather than
        // a model install failing later with a CLI-not-found error the user cannot act on.
        if outstanding.contains(where: { $0.id == BootstrapInstallPlan.lmStudio.id }),
           outstanding.count > 1 {
            lines.append("LM Studio is not installed yet, so that goes first and the model follows.")
        }
        // B8: a component is usable the moment it lands. Saying so is what makes Install now a smaller
        // decision than it looks.
        lines.append("It installs here. \(feature.title) runs as soon as it lands, and you can close this.")
        return PointOfUseInstallOffer(
            featureID: feature.id,
            featureTitle: feature.title,
            header: "\(feature.title.uppercased()) - NOT INSTALLED YET",
            lines: lines,
            components: outstanding,
            buttons: [
                PointOfUseButton(
                    id: installButtonID, title: "Install now",
                    detail: sizeDetail(for: outstanding),
                    route: .install),
                PointOfUseButton(
                    id: skipButtonID, title: "Not now",
                    detail: "Nothing is installed and your text is untouched.",
                    route: .skip),
            ])
    }

    static func chooser(for feature: PointOfUseFeature,
                        localComponents: [InstallerComponentDescriptor]) -> PointOfUseChooser {
        PointOfUseChooser(
            featureID: feature.id,
            header: "\(feature.title.uppercased()) NEEDS A MODEL - PICK A ROUTE",
            lines: [
                "This Mac has no local model installed, and neither the Claude nor the Codex CLI is here.",
                // B16, said to the user at the only moment it matters. The app has NOT sent anything, and
                // the reason it has not is that this is a button and not a fallback.
                "ViddyDictate has sent nothing anywhere. A cloud provider only ever runs if you pick one here.",
            ],
            buttons: [
                PointOfUseButton(
                    id: skipButtonID, title: "Skip this time",
                    detail: "Leave it. Your text is untouched.",
                    route: .skip),
                PointOfUseButton(
                    id: claudeButtonID, title: "Set up Claude",
                    detail: "Sign in to Claude Code. Your text would then leave this Mac.",
                    route: .guidedProvider(.claude)),
                PointOfUseButton(
                    id: codexButtonID, title: "Set up Codex",
                    detail: "Sign in to Codex. Your text would then leave this Mac.",
                    route: .guidedProvider(.codex)),
                PointOfUseButton(
                    id: localButtonID, title: "Set up local models",
                    detail: localRouteDetail(localComponents),
                    route: .install),
            ],
            localComponents: localComponents)
    }

    private static func needsLine(feature: PointOfUseFeature,
                                  outstanding: [InstallerComponentDescriptor]) -> String {
        let named = outstanding.filter { $0.id != BootstrapInstallPlan.lmStudio.id }
        let subjects = named.isEmpty ? outstanding : named
        let titles = list(subjects.map(\.title))
        guard let size = size(of: outstanding) else {
            // Nothing measured, so no size is quoted at all. O1: an estimate must not ship as a
            // user-facing byte count.
            return "\(feature.title) uses \(titles)."
        }
        return "\(feature.title) uses \(titles), \(size)."
    }

    private static func sizeDetail(for outstanding: [InstallerComponentDescriptor]) -> String {
        guard let size = size(of: outstanding) else {
            return "Downloads what is missing. The size is not known until it starts."
        }
        return "Downloads \(size)."
    }

    private static func localRouteDetail(_ components: [InstallerComponentDescriptor]) -> String {
        let base = "Nothing you dictate leaves this Mac."
        guard let size = size(of: components) else { return base }
        return "\(size). \(base)"
    }

    /// How big this set is, in words the user can act on.
    ///
    /// A partial sum presented as a total is the failure O1 is about, and it is not hypothetical here: the
    /// LM Studio DMG's byte count cannot be known until its URL resolves (O4), so an email-mode offer that
    /// installs LM Studio AND gemma would otherwise quote 6.86 GB for a download that is larger than that.
    /// The unmeasured components are therefore NAMED rather than dropped - "6.86 GB plus LM Studio" - so
    /// the number stays true and the sentence stays complete.
    private static func size(of components: [InstallerComponentDescriptor]) -> String? {
        guard !components.isEmpty else { return nil }
        let measured = components.compactMap(\.downloadBytes)
        let unmeasured = components.filter { $0.downloadBytes == nil }
        guard !measured.isEmpty else { return nil }
        let total = LMStudioModelCatalog.decimalSize(measured.reduce(0, +))
        guard !unmeasured.isEmpty else { return total }
        return "\(total) plus \(list(unmeasured.map(\.title)))"
    }

    private static func list(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + ", and " + values[values.count - 1]
        }
    }

    // MARK: - Identity

    static let installButtonID = "install-now"
    static let skipButtonID = "skip"
    static let claudeButtonID = "set-up-claude"
    static let codexButtonID = "set-up-codex"
    static let localButtonID = "set-up-local-models"

    static let surfaceIdentifier = "point-of-use-offer"
    static let headerIdentifier = "point-of-use-header"
    static let footerIdentifier = "point-of-use-footer"

    static func lineIdentifier(_ index: Int) -> String { "point-of-use-line|\(index)" }
    static func buttonIdentifier(_ id: String) -> String { "point-of-use-button|\(id)" }
    static func progressIdentifier(_ componentID: String) -> String {
        "point-of-use-progress|\(componentID)"
    }

    static let keyHint = "left / right to choose      return to pick      esc dismisses"

    /// The per-row status line shown while the install runs. B7 forbids an ETA, and this deliberately
    /// carries no byte or speed figure either: the headless engine reports a row's PHASE, and the byte and
    /// live-speed readout is the progress link's item. When that lands, this surface renders the same rows
    /// it already renders, with numbers in them - which is what "the same per-row progress" means.
    static func progressLine(_ record: BootstrapComponentRecord) -> String {
        switch record.phase {
        case .pending: return "\(record.title)   waiting"
        case .installing: return "\(record.title)   installing"
        case .installed: return "\(record.title)   done"
        case .failed:
            // B10: the vendor's real text, never a generic setup message.
            let reason = record.failureMessage.map { Preflight.bounded($0) } ?? "stopped"
            return "\(record.title)   failed - \(reason)"
        }
    }
}
