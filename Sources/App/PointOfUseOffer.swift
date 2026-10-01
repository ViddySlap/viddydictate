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

    /// The same feature on Ollama, the advanced option (spec D3): its app, then the model it holds. Only a
    /// feature a local text model serves has one.
    var ollamaComponents: [InstallerComponentDescriptor] {
        guard satisfaction == .textProvider else { return [] }
        return [BootstrapInstallPlan.ollama] + (ollamaModel.map { [$0] } ?? [])
    }

    /// The feature's own model in Ollama (spec D4): Ollama's staff pick for the family LM Studio's model row
    /// holds (`StaffPicks.localModelID`, the mapping `testedLocalBundle(for:on:)` uses), as the same queue row
    /// the first-run window pulls. So email is `gemma4:e4b`, and cleanup and prompt prep are `qwen3-coder:30b`.
    /// A pull only: the row makes Ollama ready, then pulls. nil for a feature with no local text model.
    var ollamaModel: InstallerComponentDescriptor? {
        guard satisfaction == .textProvider else { return nil }
        for component in components {
            for case .model(let ref) in component.localSteps where ref.backend == .lmStudio {
                guard let tag = StaffPicks.localModelID(forLMStudioDefault: ref.modelID, on: .ollama) else {
                    continue
                }
                let id = BootstrapInstallPlan.componentID(for: LocalModelRef(backend: .ollama, modelID: tag))
                return BootstrapInstallPlan.optionalLocalModels.first { $0.id == id }
            }
        }
        return nil
    }

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
    /// Set only on a Mac with neither local app: "Install now" then opens this choice instead of installing.
    /// `components` stays the recommended LM Studio install, which is also the choice's LM Studio option.
    var localAppChoice: PointOfUseLocalAppChoice? = nil

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
    /// Set only on a Mac with neither local app: "Set up local models" then asks WHICH app. `localComponents`
    /// stays the recommended LM Studio install, which is also the choice's LM Studio option.
    var localAppChoice: PointOfUseLocalAppChoice? = nil
}

/// One app "Set up local models" can install on a Mac with neither (spec D3/D8).
struct PointOfUseLocalAppOption: Equatable {
    let backend: LocalBackendID
    /// The app's own name.
    let title: String
    /// "Simple - recommended" or "Advanced". Never the same words for both: D3 says never as equals.
    let label: String
    let recommended: Bool
    let detail: String
    /// What the user must expect and do during the install, said before they commit to it. Ollama's macOS
    /// prompt; nil for LM Studio, which raises none.
    let warning: String?
    /// Exactly what the install queue is handed, in dependency order.
    let components: [InstallerComponentDescriptor]
    /// Always `.install`. Picking an app is choosing an install, not a new kind of action.
    let button: PointOfUseButton
}

/// Which local app to install, when the machine has neither (spec D3): **LM Studio, the simple install,
/// first and recommended; Ollama, the advanced option, second.** Never presented as equals: most users will
/// run one app, and Ollama is the more technical one.
///
/// Every button here is `.install` or `.skip`, so the `PointOfUseRoute` invariant holds on this page too:
/// the panel can still only skip, install, or open a provider's sign-in.
///
/// `InstallOfferPanel` draws this as its own page, which "Set up local models" (or "Install now") opens when
/// an offer carries it (`PointOfUsePolicy.installStep`). The picked app goes to
/// `PointOfUseOfferPresenter.installLocalApp(_:)`. The page opens on LM Studio, its first button.
struct PointOfUseLocalAppChoice: Equatable {
    let header: String
    let lines: [String]
    /// LM Studio first. `--installer-local-steps-selftest` pins the order and the single recommendation.
    let options: [PointOfUseLocalAppOption]

    /// The options' install buttons in order, then Not now.
    var buttons: [PointOfUseButton] {
        options.map(\.button) + [PointOfUseButton(
            id: PointOfUsePolicy.skipButtonID, title: "Not now",
            detail: "Nothing is installed and your text is untouched.", route: .skip)]
    }

    func option(_ backend: LocalBackendID) -> PointOfUseLocalAppOption? {
        options.first { $0.backend == backend }
    }

    /// The option a button on this page installs, or nil for Not now.
    func option(forButton id: String) -> PointOfUseLocalAppOption? {
        options.first { $0.button.id == id }
    }

    /// One cell of the choice page: the option's label above its install button's title, and under it what
    /// the option is, what it downloads, and (Ollama) what macOS will ask. Not now has no label.
    struct Cell: Equatable {
        let button: PointOfUseButton
        /// Drawn above the title, so "simple, recommended" and "advanced" read before the app's name.
        let badge: String?
        let detail: String
    }

    /// The page's cells in button order. Every option's warning is IN its cell rather than in a footnote,
    /// so the prompt is read by whoever is about to pick the app that raises it.
    var cells: [Cell] {
        buttons.map { button in
            guard let option = option(forButton: button.id) else {
                return Cell(button: button, badge: nil, detail: button.detail)
            }
            let detail = [option.detail, button.detail, option.warning].compactMap { $0 }.joined(separator: " ")
            return Cell(button: button, badge: option.label.uppercased(), detail: detail)
        }
    }
}

/// What pressing an install button does on the panel, decided from the page it was pressed on (spec D3).
enum PointOfUseInstallStep: Equatable {
    /// The offer carries a local-app choice (the Mac has neither app): open the choice page instead of
    /// installing on the user's behalf.
    case chooseApp(PointOfUseLocalAppChoice)
    /// The choice page's button for this app was pressed.
    case installApp(LocalBackendID)
    /// Install the page's own components: an offer with no choice, or Retry on the running page.
    case installComponents
    /// Nothing: a button that installs nothing on this page.
    case none
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

    /// Which app to install, when the machine has neither.
    var localAppChoice: PointOfUseLocalAppChoice? {
        switch self {
        case .install(let offer): return offer.localAppChoice
        case .chooser(let chooser): return chooser.localAppChoice
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
        let apps = localAppChoice.map { " apps=" + $0.options.map(\.backend.rawValue).joined(separator: ",") } ?? ""
        return "point-of-use offer=\(kind) feature=\(featureID) "
            + "buttons=\(buttons.map(\.id).joined(separator: ","))" + apps
    }
}

enum PointOfUsePolicy {

    /// Whether a component is already in place. `nil` means the measuring apparatus did not answer, which
    /// is deliberately NOT folded into "missing": offering to install a model while LM Studio is merely
    /// stopped would send the user on a several-gigabyte errand to fix a thing that is already there.
    static func isSatisfied(_ component: InstallerComponentDescriptor,
                            presences: [LLMProvider: LLMProviderDetection.Presence],
                            bootstrap: BootstrapSnapshot) -> Bool? {
        guard !component.localSteps.isEmpty else {
            return bootstrap.isComponentUsable(component.id)
        }
        let local = presences[.local]
        // Each step names its app, and that app's OWN reading answers: its install, and its catalog (nil
        // while it is stopped, even when the other app's answered). Models match on the app too, since the
        // same id in the other app is not the model this row would install. Without that app's own reading
        // (a hand-built presence), LM Studio keeps the merged single-app reading it had in 1.1.0; for Ollama
        // the merged fields measure nothing, so it answers nil rather than guessing.
        for step in component.localSteps {
            let backend = step.backend
            let reading = local.flatMap { $0.localReading(backend) }
            let mergedFallback = backend == .lmStudio
            let installed = reading.map(\.installed) ?? (mergedFallback ? local?.installed : nil)
            let models = reading.map(\.models) ?? (mergedFallback ? local?.availableLocalModels : nil)
            switch step {
            case .app, .ready:
                guard let installed else { return nil }
                if !installed { return false }
            case .model(let ref):
                guard let installed else { return nil }
                guard installed else { return false }
                guard let models else { return nil }
                if !models.contains(where: { $0.backend == ref.backend && Self.sameModel($0.modelID, ref) }) {
                    return false
                }
            }
        }
        return true
    }

    /// Ollama's implicit `:latest` makes `x` and `x:latest` one model; LM Studio ids compare exactly.
    private static func sameModel(_ listed: String, _ ref: LocalModelRef) -> Bool {
        switch ref.backend {
        case .lmStudio: return listed == ref.modelID
        case .ollama: return OllamaBackend.canonicalModelName(listed) == OllamaBackend.canonicalModelName(ref.modelID)
        }
    }

    /// True only when the machine measurably has NEITHER local app, the one situation D3's choice is for.
    /// An unmeasured local presence is never counted as neither.
    static func hasNoLocalApp(presences: [LLMProvider: LLMProviderDetection.Presence]) -> Bool {
        guard let local = presences[.local] else { return false }
        if let installed = local.installedLocalBackends { return installed.isEmpty }
        return !local.installed
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

    /// Which app a feature's model is offered in on a Mac that has at least one local app (spec D1/D3: the
    /// Preferred local app follows what is installed). Ollama when it is the only app installed, or when both
    /// are and the effective Preferred local app is Ollama; LM Studio otherwise, which is every offer this
    /// policy made before Ollama existed. A presence with no per-app breakdown (one built by hand) is LM Studio's.
    static func offeredLocalApp(presences: [LLMProvider: LLMProviderDetection.Presence],
                                preferredLocalApp: LocalBackendID?) -> LocalBackendID {
        guard let installed = presences[.local]?.installedLocalBackends, installed.contains(.ollama) else {
            return .lmStudio
        }
        guard installed.contains(.lmStudio) else { return .ollama }
        return LocalBackendPreference.effective(explicit: preferredLocalApp, installed: installed)
    }

    /// The fit check for an Ollama pull (`ComponentPicker.availability`, the loader's own 1.15 arithmetic, the
    /// same verdict the first-run window gives the row). Only a model that cannot fit at the budget ceiling is
    /// refused; unmeasured facts (`nil`, or a kernel fact macOS did not report) are not a verdict.
    static func ollamaModelFits(_ model: InstallerComponentDescriptor,
                                facts: ComponentPicker.MachineFacts?) -> Bool {
        guard let facts, let row = pickerRow(for: model) else { return true }
        return ComponentPicker.availability(row, facts: facts) != .tooLarge
    }

    private static func pickerRow(for model: InstallerComponentDescriptor) -> ComponentPicker.RowID? {
        ComponentPicker.RowID.allCases.first { row in
            row.localModel.map { BootstrapInstallPlan.componentID(for: $0) } == model.id
        }
    }

    /// The whole decision. `nil` means say nothing: either the feature is already installed, or something
    /// could not be measured and a panel would be guessing at the user's expense.
    ///
    /// `preferredLocalApp` is the EXPLICIT Preferred local app (nil for Automatic) and `facts` this Mac's
    /// memory, which the Ollama pull is fit-checked against. A Mac with LM Studio and not Ollama never reads
    /// either: its offer is the one this policy has always made.
    static func offer(for feature: PointOfUseFeature,
                      presences: [LLMProvider: LLMProviderDetection.Presence],
                      bootstrap: BootstrapSnapshot,
                      preferredLocalApp: LocalBackendID? = nil,
                      facts: ComponentPicker.MachineFacts? = nil) -> PointOfUseOffer? {
        if feature.satisfaction == .textProvider, let model = feature.ollamaModel,
           offeredLocalApp(presences: presences, preferredLocalApp: preferredLocalApp) == .ollama {
            return ollamaOffer(for: feature, model: model, presences: presences, bootstrap: bootstrap,
                               facts: facts)
        }

        var outstanding: [InstallerComponentDescriptor] = []
        for component in feature.components {
            guard let satisfied = isSatisfied(component, presences: presences, bootstrap: bootstrap) else {
                return nil
            }
            if !satisfied { outstanding.append(component) }
        }
        guard !outstanding.isEmpty else { return nil }

        // D3: on a Mac with neither app, the offer also carries which app to install. The LM Studio option
        // is exactly the outstanding list above, so "Install now" is unchanged by the choice existing. The
        // Ollama option is its app and then the feature's own model, unless that model cannot fit this Mac,
        // in which case it is the app alone and says why.
        var appChoice: PointOfUseLocalAppChoice?
        if feature.satisfaction == .textProvider, hasNoLocalApp(presences: presences),
           outstanding.contains(where: { $0.id == BootstrapInstallPlan.lmStudio.id }) {
            let tooLarge = feature.ollamaModel.flatMap { ollamaModelFits($0, facts: facts) ? nil : $0 }
            let ollama = feature.ollamaComponents.filter {
                $0.id != tooLarge?.id && isSatisfied($0, presences: presences, bootstrap: bootstrap) != true
            }
            appChoice = localAppChoice(for: feature, lmStudioComponents: outstanding,
                                       ollamaComponents: ollama, ollamaModelTooLarge: tooLarge)
        }

        if feature.satisfaction == .textProvider, hasNothingInstalled(presences: presences) {
            var offer = chooser(for: feature, localComponents: outstanding)
            offer.localAppChoice = appChoice
            return .chooser(offer)
        }
        var offer = installOffer(for: feature, outstanding: outstanding)
        offer.localAppChoice = appChoice
        return .install(offer)
    }

    /// D3's two options, LM Studio first as the simple, recommended install and Ollama second as the
    /// advanced option, which carries the warning about its macOS prompt.
    static func localAppChoice(for feature: PointOfUseFeature,
                               lmStudioComponents: [InstallerComponentDescriptor],
                               ollamaComponents: [InstallerComponentDescriptor],
                               ollamaModelTooLarge: InstallerComponentDescriptor? = nil) -> PointOfUseLocalAppChoice {
        // What the Ollama option fetches after the app, said the way LM Studio's option says it.
        let pullsModel = ollamaComponents.flatMap(\.localSteps).contains {
            if case .model = $0 { return true }
            return false
        }
        let ollamaModelClause: String
        if let tooLarge = ollamaModelTooLarge {
            ollamaModelClause = ". \(tooLarge.title) needs more memory than this Mac can give it, so no model is "
                + "pulled."
        } else if pullsModel {
            ollamaModelClause = ", then pulls the model \(feature.title.lowercased()) uses."
        } else {
            ollamaModelClause = "."
        }
        return PointOfUseLocalAppChoice(
            header: "SET UP LOCAL MODELS - PICK ONE APP",
            lines: [
                "\(feature.title) runs on a local model app on this Mac. Most people only need one.",
                "You can add the other later from Settings > Setup.",
            ],
            options: [
                PointOfUseLocalAppOption(
                    backend: .lmStudio, title: LocalBackendID.lmStudio.displayName,
                    label: "Simple - recommended", recommended: true,
                    detail: "The simple install. ViddyDictate installs LM Studio from its own installer, "
                        + "then the model \(feature.title.lowercased()) uses.",
                    warning: nil,
                    components: lmStudioComponents,
                    button: PointOfUseButton(
                        id: lmStudioAppButtonID, title: "Install LM Studio",
                        detail: sizeDetail(for: lmStudioComponents), route: .install)),
                PointOfUseLocalAppOption(
                    backend: .ollama, title: LocalBackendID.ollama.displayName,
                    label: "Advanced", recommended: false,
                    detail: "The advanced option, for people who already use Ollama. ViddyDictate installs "
                        + "it from Ollama's own download" + ollamaModelClause,
                    warning: OllamaInstaller.adminPromptWarning,
                    components: ollamaComponents,
                    button: PointOfUseButton(
                        id: ollamaAppButtonID, title: "Install Ollama",
                        detail: sizeDetail(for: ollamaComponents), route: .install)),
            ])
    }

    /// D3: the Preferred local app follows what got installed from the choice. Automatic (nil) already does,
    /// through `LocalBackendPreference.effective`: with one app installed it IS that app. An explicit choice
    /// naming the OTHER app would keep new routes pinned to an app the user just passed over, so it returns
    /// to automatic; an explicit choice of this app is kept as it is.
    static func preferenceAfterInstalling(_ backend: LocalBackendID,
                                          explicit: LocalBackendID?) -> LocalBackendID? {
        explicit == backend ? explicit : nil
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
        // D8: Ollama's macOS prompt is said before the install and stays on the running page beside it.
        if outstanding.contains(where: { $0.id == BootstrapInstallPlan.ollama.id }) {
            lines.append(OllamaInstaller.adminPromptWarning)
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

    /// The offer on a Mac whose local app is Ollama (`offeredLocalApp`): the feature's own model, pulled into
    /// the Ollama already here. Never LM Studio, and never a model this Mac cannot fit, which is said instead.
    private static func ollamaOffer(for feature: PointOfUseFeature, model: InstallerComponentDescriptor,
                                    presences: [LLMProvider: LLMProviderDetection.Presence],
                                    bootstrap: BootstrapSnapshot,
                                    facts: ComponentPicker.MachineFacts?) -> PointOfUseOffer? {
        // Unmeasured (Ollama stopped, its catalog unread) is not missing, exactly as for LM Studio.
        guard let satisfied = isSatisfied(model, presences: presences, bootstrap: bootstrap), !satisfied else {
            return nil
        }
        guard ollamaModelFits(model, facts: facts) else {
            return .install(ollamaModelTooLargeOffer(for: feature, model: model, facts: facts))
        }
        if hasNothingInstalled(presences: presences) {
            return .chooser(chooser(for: feature, localComponents: [model]))
        }
        return .install(ollamaModelOffer(for: feature, model: model))
    }

    /// B13 on an Ollama Mac: the pull, named with its app and its measured size.
    static func ollamaModelOffer(for feature: PointOfUseFeature,
                                 model: InstallerComponentDescriptor) -> PointOfUseInstallOffer {
        let size = size(of: [model]).map { ", \($0)" } ?? ""
        return PointOfUseInstallOffer(
            featureID: feature.id,
            featureTitle: feature.title,
            header: "\(feature.title.uppercased()) - NOT INSTALLED YET",
            lines: [
                "\(feature.title) uses \(model.title) in Ollama\(size).",
                "It installs here. \(feature.title) runs as soon as it lands, and you can close this.",
            ],
            components: [model],
            buttons: [
                PointOfUseButton(
                    id: installButtonID, title: "Install \(model.title) in Ollama",
                    detail: sizeDetail(for: [model]),
                    route: .install),
                PointOfUseButton(
                    id: skipButtonID, title: "Not now",
                    detail: "Nothing is installed and your text is untouched.",
                    route: .skip),
            ])
    }

    /// The feature's Ollama model cannot fit this Mac even at the memory budget's ceiling. There is nothing to
    /// install, so the page says why in the first-run window's words and only closes.
    static func ollamaModelTooLargeOffer(for feature: PointOfUseFeature, model: InstallerComponentDescriptor,
                                         facts: ComponentPicker.MachineFacts?) -> PointOfUseInstallOffer {
        let size = size(of: [model]).map { ", \($0)" } ?? ""
        let verdict = facts.flatMap { facts in
            pickerRow(for: model).flatMap {
                ComponentPicker.machineNote($0, facts: facts, environment: ComponentPicker.Environment())
            }
        } ?? "This model needs more memory than this Mac can give it."
        return PointOfUseInstallOffer(
            featureID: feature.id,
            featureTitle: feature.title,
            header: "\(feature.title.uppercased()) - TOO BIG FOR THIS MAC",
            lines: ["\(feature.title) uses \(model.title) in Ollama\(size). \(verdict)"],
            components: [],
            buttons: [
                PointOfUseButton(
                    id: skipButtonID, title: "Close",
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
        let apps = [BootstrapInstallPlan.lmStudio.id, BootstrapInstallPlan.ollama.id]
        let named = outstanding.filter { !apps.contains($0.id) }
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
    static let lmStudioAppButtonID = "install-lm-studio"
    static let ollamaAppButtonID = "install-ollama"
    static let retryButtonID = "retry"

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

    /// `progressLine` with what the running row reported: real bytes for an Ollama pull, or the wait for
    /// Ollama's macOS prompt. Every other phase reads exactly as `progressLine` does. `InstallOfferPanel`'s
    /// running page renders its rows through this with `BootstrapInstallCoordinator.activity(for:)`, and the
    /// presenter redraws it on `didReportActivity`.
    static func progressLine(_ record: BootstrapComponentRecord,
                             activity: InstallerLocalActivity?) -> String {
        guard record.phase == .installing, activity != nil else { return progressLine(record) }
        return "\(record.title)   \(InstallProgress.statusText(for: record, activity: activity))"
    }

    /// The running page's lines: one per row, then, while Ollama's own row has not landed, the warning about
    /// its macOS prompt (D8: said before the install and kept beside it while it runs, because the prompt
    /// appears in the middle of the install, behind whatever the user went back to).
    static func runningLines(_ records: [BootstrapComponentRecord],
                             activity: (String) -> InstallerLocalActivity?) -> [String] {
        var lines = records.map { progressLine($0, activity: activity($0.id)) }
        if records.contains(where: { $0.id == BootstrapInstallPlan.ollama.id && $0.phase != .installed }) {
            lines.append(OllamaInstaller.adminPromptWarning)
        }
        return lines
    }

    /// The running page's buttons. None while anything is still waiting or installing: the page reports, and
    /// esc closes it without cancelling (B9). Once the queue has finished with a failed row, Retry runs the
    /// same rows again through the same queue - the word every installer failure tells the user to choose
    /// (`InstallProgress.retryTitle`) - and Close leaves it. Both are `.install` / `.skip`, so the
    /// `PointOfUseRoute` invariant holds on this page too.
    static func runningButtons(_ records: [BootstrapComponentRecord]) -> [PointOfUseButton] {
        let finished = !records.contains { $0.phase == .pending || $0.phase == .installing }
        guard finished, records.contains(where: { $0.phase == .failed }) else { return [] }
        return [
            PointOfUseButton(id: retryButtonID, title: InstallProgress.retryTitle,
                             detail: "Runs the rows that stopped again. The ones that finished stay.",
                             route: .install),
            PointOfUseButton(id: skipButtonID, title: "Close",
                             detail: "Nothing else is installed and your text is untouched.",
                             route: .skip),
        ]
    }

    /// What an `.install` button does on the page it was pressed on. `offer` is the offer page (nil on the
    /// other pages), `choice` the app-choice page (nil elsewhere); `running` is true on the running page.
    ///
    /// On a Mac with neither app the offer's install button ("Install now", or the chooser's "Set up local
    /// models") opens the choice rather than installing LM Studio unasked; only the choice page installs an
    /// app. A button whose route is not `.install` never reaches an install from here.
    static func installStep(pressed button: PointOfUseButton, offer: PointOfUseOffer?,
                            choice: PointOfUseLocalAppChoice?, running: Bool) -> PointOfUseInstallStep {
        guard button.route == .install else { return .none }
        if let choice {
            return choice.option(forButton: button.id).map { .installApp($0.backend) } ?? .none
        }
        if let offer {
            if let appChoice = offer.localAppChoice { return .chooseApp(appChoice) }
            return .installComponents
        }
        return running ? .installComponents : .none
    }
}
