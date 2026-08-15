import Foundation

/// Provider onboarding (Public V1 spec W4, item P9): what a user is told, and offered, about getting a text
/// provider signed in.
///
/// Product decision: TWO DISTINCT MESSAGES, ONE SHARED FLOW. A provider that is installed
/// but signed out and a provider that is not installed at all get different wording, because the user's next
/// action genuinely differs and being wrong is costly in opposite directions - telling someone to install
/// software they already have sends them on a pointless errand, and telling someone to sign in to something
/// absent leaves them hunting a button that does not exist. They share one flow, because both end at the same
/// place and both ride machinery that already exists.
///
/// The two states are DERIVED here, never stored: `LLMProviderDetection.Presence` already carries `installed`
/// separately from `state`, and this file reads that one pair. Onboarding is therefore not a second owner of
/// provider detection - it has no measurement of its own, and `plan(providers:)` cannot be called without
/// someone else's observation.
///
/// **Locked decision 5: onboarding signs the user in and asks nothing else.** No model choices and no
/// per-route decisions - a new user has no basis to answer them. That is enforced by the shape of
/// `ProviderOnboardingAction`, which can express connecting a provider and nothing else, so a model or route
/// preference is not something this layer could set even by mistake.
///
/// **W5 still governs: nothing here blocks the app.** There is no refusal state, every message is a
/// suggestion, and raw dictation runs on local speech-to-text with no provider at all.
enum ProviderOnboardingSituation: String, CaseIterable {
    /// The provider can run. Nothing needs doing, but the row still carries a button (L4/D3) so the two
    /// providers sit side by side in the same place whatever state the machine is in.
    case ready
    /// Installed, but not usable yet. This is the state that offers the sign-in action directly, because it
    /// now works: Codex device login in-app, and `claude auth login` for Claude Code.
    case signedOut
    /// Installed, but not signed out: the CLI reported a connection or runtime state ViddyDictate
    /// cannot use. No sign-in action is offered, because repeating login cannot change this verdict.
    case unavailable
    /// Not on this Mac at all. States the one install step and offers NO action, because there is nothing to
    /// connect to yet. Re-running the check is the transition to `signedOut`; that is the same re-measure the
    /// Setup surface already provides, not a second mechanism.
    case notInstalled

    /// The row's own state word. Deliberately a word rather than a colour alone, for the same reason the
    /// preflight surface uses one: a screenshot in a bug report has to be readable without relying on hue.
    var statusText: String {
        switch self {
        case .ready: return "SIGNED IN"
        case .signedOut: return "SIGN IN"
        case .unavailable: return "UNAVAILABLE"
        case .notInstalled: return "INSTALL FIRST"
        }
    }
}

/// The only thing onboarding can do. One case on purpose; see the decision-5 note above.
///
/// It stays one case even now that a signed-in row carries a button too (L4/D3), because that button enters
/// the SAME flow: `ProviderSignInPresenter` measures and then either signs the user in or says why it will
/// not. A second case for "reconnect" would be a second implementation of one outcome, which is exactly what
/// W4 forbids. What differs between the two situations is only what the button SAYS - see
/// `ProviderOnboarding.actionTitle`.
enum ProviderOnboardingAction: Equatable {
    case connect(LLMProvider)

    /// Discriminator so a gate can assert that connecting is the ONLY expressible action. A second case here
    /// - "pin this model", "choose an effort" - would have to be added deliberately and would red that gate.
    enum Kind: String, CaseIterable {
        case connect
    }

    var kind: Kind {
        switch self {
        case .connect: return .connect
        }
    }

    var provider: LLMProvider {
        switch self {
        case .connect(let provider): return provider
        }
    }
}

/// One provider, as onboarding presents it.
struct ProviderOnboardingStep: Equatable {
    let provider: LLMProvider
    let situation: ProviderOnboardingSituation
    /// The product a user would go looking for, not the internal provider name: "Claude Code", not "Claude".
    let title: String
    /// The opening sentence. This is the half W4 requires to differ per state.
    let opening: String
    /// The one concrete next step. For `signedOut` it describes what the button will do; for `notInstalled`
    /// it is the install line plus the re-check that turns this row into the signed-out one.
    let step: String
    /// The vendor's own reason, bounded, when the measured state carried one beyond a plain disconnect.
    /// Present so a provider that is installed and still not usable says why rather than reading as an
    /// ordinary sign-out.
    let detail: String?
    /// Offered for an installed provider whose connection ViddyDictate can actually act on: a real
    /// disconnect, and - since L4/D3 - a working connection, so the two rows carry buttons in the same
    /// place and read as one section. An unsupported logged-in method and an absent CLI get none: neither
    /// would do anything, and a button that changes nothing is worse than no button.
    let action: ProviderOnboardingAction?

    /// Whether this row carries a button at all. Derived from the situation through
    /// `ProviderOnboarding.offersAction`; nothing stores it.
    var offersAction: Bool { action != nil }

    /// What that button says. The title depends on the SITUATION as well as the provider, because the same
    /// flow means two different things either side of a working connection (D3), so it is resolved here
    /// rather than carried on the action - one action, two labels, no second flow.
    var actionTitle: String? {
        action.map { ProviderOnboarding.actionTitle($0.provider, situation) }
    }
}

enum ProviderOnboarding {

    // MARK: - Which providers onboarding covers

    /// Whether ViddyDictate can drive this provider's sign-in at all. Written as an exhaustive switch so a
    /// new provider cannot be added without deciding whether onboarding speaks for it.
    ///
    /// Local is excluded, and the reason is not cosmetic. LM Studio is an optional post-V1 power path (locked
    /// decision 1), onboarding asks nothing beyond signing in (locked decision 5), and - decisively - P6
    /// recorded that nothing ever writes `.local` availability, so a Local row would read as available on
    /// every machine and would make onboarding claim to be satisfied while no cloud provider was signed in.
    static func canDriveSignIn(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .claude, .codex: return true
        case .local: return false
        }
    }

    /// The providers onboarding covers, in the order routing would actually try them, so the surface and the
    /// routing ladder cannot disagree about precedence.
    static var providers: [LLMProvider] {
        LLMAvailabilityRouting.fallbackOrder.filter(canDriveSignIn)
    }

    /// The product name a user would search for. Distinct from `ModelsPowerSettingsView.displayName`, which
    /// names the PROVIDER inside ViddyDictate's own settings; onboarding has to name the thing to install.
    static func productName(for provider: LLMProvider) -> String {
        switch provider {
        case .claude: return "Claude Code"
        case .codex: return "ChatGPT.app"
        case .local: return "LM Studio"
        }
    }

    // MARK: - Derivation

    /// W4's install split plus D4's do-not-call-unsupported-auth-signed-out rule. A real
    /// `.disconnected` is the only installed state that can offer login.
    static func situation(_ presence: LLMProviderDetection.Presence) -> ProviderOnboardingSituation {
        if presence.state.canRun { return .ready }
        guard presence.installed else { return .notInstalled }
        return presence.state.requiresConnection ? .signedOut : .unavailable
    }

    /// The reason worth showing beside a row. A plain disconnect says nothing the opening sentence does not
    /// already say, and a not-installed provider's "reason" is just a restatement of being absent.
    static func detail(_ presence: LLMProviderDetection.Presence) -> String? {
        guard situation(presence) == .unavailable else { return nil }
        guard case .unavailable(let why) = presence.state else { return nil }
        return "Reported: \(Preflight.bounded(why))"
    }

    /// Which situations carry a button, as an exhaustive switch so a new situation cannot be added without
    /// deciding (L4, D3, D4).
    ///
    /// `.ready` gains one for VISUAL PARITY: the Codex button that used to live on Models & Power was
    /// always present and read Connect or Reconnect, and moving it beside Claude's on the Setup tab would
    /// otherwise make a signed-in machine's section look empty. `.unavailable` gets none because signing in
    /// again cannot change a method ViddyDictate does not support, and `.notInstalled` gets none because
    /// there is nothing on this Mac to sign in to (W4).
    static func offersAction(_ situation: ProviderOnboardingSituation) -> Bool {
        switch situation {
        case .signedOut, .ready: return true
        case .unavailable, .notInstalled: return false
        }
    }

    /// What the button says. Named for the vendor's own word for the act, because that is what the user will
    /// see next: Codex calls it connecting a device, Claude Code calls it signing in.
    ///
    /// **The connected labels are asymmetric on purpose (D3).** Codex's credential is ViddyDictate's own, so
    /// re-running its device login costs nothing and Reconnect is an honest word for it. Claude's credential
    /// is one per macOS account, so the flow deliberately does NOT re-authenticate - calling its button
    /// Reconnect would promise something it refuses to do, and would be read as an offer to fix a connection
    /// that is not broken. It names what actually happens instead: it explains the sign-in and the command
    /// the user can run themselves.
    static func actionTitle(_ provider: LLMProvider,
                            _ situation: ProviderOnboardingSituation) -> String {
        let connected = situation == .ready
        switch provider {
        case .claude: return connected ? "About this sign-in" : "Sign in to Claude Code"
        case .codex: return connected ? "Reconnect Codex" : "Connect Codex"
        case .local: return "Start LM Studio"
        }
    }

    static func step(for provider: LLMProvider,
                     presence: LLMProviderDetection.Presence) -> ProviderOnboardingStep {
        let situation = situation(presence)
        let name = productName(for: provider)
        return ProviderOnboardingStep(
            provider: provider,
            situation: situation,
            title: name,
            opening: opening(situation, name),
            step: nextStep(situation, provider),
            detail: detail(presence),
            // W4, D3 and D4, in one place: which situations act, decided once above.
            action: offersAction(situation) ? .connect(provider) : nil)
    }

    private static func opening(_ situation: ProviderOnboardingSituation, _ name: String) -> String {
        switch situation {
        case .ready:
            return "\(name) is signed in. ViddyDictate can use it now."
        case .signedOut:
            return "\(name) is installed on this Mac but not signed in yet."
        case .unavailable:
            return "\(name) is installed, but ViddyDictate cannot use its current connection."
        case .notInstalled:
            return "\(name) is not installed on this Mac."
        }
    }

    /// The concrete next step per (state, provider). The `notInstalled` lines both end at running the check
    /// again, because that re-measure IS the transition into the signed-out state where the button appears -
    /// W4 is explicit that no second mechanism should be built for it.
    private static func nextStep(_ situation: ProviderOnboardingSituation,
                                 _ provider: LLMProvider) -> String {
        switch (situation, provider) {
        case (.ready, .claude):
            // The row now carries a button (L4), so it has to say what that button is for. D3: it never
            // replaces the sign-in, because one Claude Code sign-in is shared by this whole Mac.
            return "Nothing to do here. About this sign-in explains why ViddyDictate never replaces the "
                + "one on this Mac, and names the command to run if you ever want a fresh one."
        case (.ready, .codex):
            return "Nothing to do here. Reconnect Codex signs in again inside ViddyDictate's own Codex "
                + "home if you ever need to; your everyday Codex login is still never read or changed."
        case (.ready, .local):
            return "Nothing to do here."
        case (.signedOut, .claude):
            // D5: ViddyDictate polls the vendor's own status command and closes its sheet itself, so this
            // no longer sends the user back to a button. Naming the command still matters - it is what a
            // user can always run themselves.
            return "Sign in to Claude Code opens Terminal running claude auth login. Finish there and "
                + "ViddyDictate notices by itself."
        case (.signedOut, .codex):
            return "Connect Codex signs in with your ChatGPT subscription in ViddyDictate's own Codex "
                + "home. Your everyday Codex login is never read or changed."
        case (.signedOut, .local):
            return "Start LM Studio so its local server answers, then check again."
        case (.unavailable, .claude):
            return "ViddyDictate does not support this Claude connection yet. Use Codex instead, or "
                + "switch Claude Code to a claude.ai subscription outside ViddyDictate."
        case (.unavailable, .codex):
            return "Review the reported Codex connection state or use Claude instead."
        case (.unavailable, .local):
            return "Review the reported LM Studio state."
        case (.notInstalled, .claude):
            return "Install Claude Code, then check again - the sign-in button appears once it is here."
        case (.notInstalled, .codex):
            return "Install ChatGPT.app, which ships the codex command ViddyDictate signs in through, "
                + "then check again - the connect button appears once it is here."
        case (.notInstalled, .local):
            return "Install LM Studio, then check again."
        }
    }

    // MARK: - Plan

    struct Plan: Equatable {
        let steps: [ProviderOnboardingStep]
        /// Whether a provider onboarding does NOT cover can already run the transforms - in practice a running
        /// LM Studio. Carried rather than ignored because onboarding and the preflight provider row sit on the
        /// same Setup tab: preflight passes when ANY provider can run, so without this a machine with LM Studio
        /// running would read "signed in to Local" one inch below "sign in to one provider", and one of those
        /// two sentences would be false. It is read from the same measurement, not measured here.
        let otherProviderCanRun: Bool

        var ready: [ProviderOnboardingStep] { steps.filter { $0.situation == .ready } }

        /// One signed-in provider is enough and ViddyDictate never needs both (locked decision 3). Only the
        /// providers onboarding covers can satisfy it; see `canDriveSignIn`. Deliberately NOT true merely
        /// because something else can run: signing in is still the thing this surface exists to offer.
        var isSatisfied: Bool { !ready.isEmpty }

        /// Whether anything is actually missing for the text features to work. This, not `isSatisfied`, is what
        /// the headline and the first-run decision read, so the surface never tells a user to fix something
        /// that is already working.
        var nothingIsMissing: Bool { isSatisfied || otherProviderCanRun }

        func step(_ provider: LLMProvider) -> ProviderOnboardingStep? {
            steps.first { $0.provider == provider }
        }

        /// Content-safe one-line record for the app log: which provider is in which state, and nothing else.
        var logToken: String {
            "onboarding satisfied=\(isSatisfied) other=\(otherProviderCanRun) "
                + steps.map { "\($0.provider.rawValue)=\($0.situation.rawValue)" }.joined(separator: " ")
        }
    }

    /// Build the plan from someone else's measurement. An unmeasured provider is reported as absent rather
    /// than assumed present, for the same reason preflight does it: counting a provider nobody measured as
    /// signed in is the one false green this surface exists to prevent.
    static func plan(providers measured: [LLMProvider: LLMProviderDetection.Presence]) -> Plan {
        Plan(steps: providers.map { provider in
                 step(for: provider,
                      presence: measured[provider]
                        ?? LLMProviderDetection.Presence(installed: false,
                                                        state: .unavailable("not measured")))
             },
             otherProviderCanRun: LLMProvider.allCases.contains {
                 !canDriveSignIn($0) && measured[$0]?.state.canRun == true
             })
    }

    // MARK: - Headline and standing copy

    static let checkingHeadline = "Looking for a text provider..."

    static func headline(_ plan: Plan) -> String {
        let names = plan.ready.map(\.title)
        guard names.isEmpty else {
            return "Signed in to \(names.joined(separator: " and ")). ViddyDictate is ready."
        }
        // Nothing is broken, so nothing is asked for. Telling a user whose transforms already run to sign in
        // would be the one false sentence this surface can produce.
        guard !plan.otherProviderCanRun else {
            return "The text features are running on \(productName(for: .local)). Signing in to a cloud "
                + "provider is optional."
        }
        if plan.steps.contains(where: { $0.situation == .unavailable }) {
            return "Set up one supported provider to turn on the text features."
        }
        return "Sign in to one provider to turn on the text features."
    }

    /// Said once, at the top. W5's answer is that nothing gates the app, so the surface states that outright
    /// rather than leaving a user to infer it from the absence of a wall - and it names what already works,
    /// because a first-run user who thinks the app is broken will not try dictating.
    static let subtitle =
        "Dictation already works: speech-to-text runs on your own machine. A provider is what turns on "
        + "cleanup, tighten, summarize, prompt prep, email, and search. One is enough - ViddyDictate never "
        + "needs both, and it never stops you from dictating without one."

    /// The two promises worth making explicit on first run: nobody is asked for an API key (locked decision 2
    /// - the vendor's own client owns the credential), and nothing about models is decided here (locked
    /// decision 5).
    static let footer =
        "ViddyDictate never asks for an API key: your provider's own app owns the sign-in. It sets no model "
        + "choices for you either - everything else has a working default you can change later in Settings."

    // MARK: - First run

    /// Whether to show the first-run window. `hasEverBeenSatisfied` is the persisted fact that a provider was
    /// ready at least once, so onboarding appears before a user has ever had one and never again after - it
    /// does not reappear as a nag when a provider is later signed out, because the re-runnable Setup surface
    /// is what reports that.
    ///
    /// It reads `nothingIsMissing`, not `isSatisfied`: a machine whose transforms already run through LM Studio
    /// is not interrupted. The persisted flag is still written only on a real sign-in, so if that local server
    /// later goes away the window does appear - at that point something genuinely is missing.
    static func shouldPresentFirstRun(hasEverBeenSatisfied: Bool, plan: Plan) -> Bool {
        !hasEverBeenSatisfied && !plan.nothingIsMissing
    }

    // MARK: - Identity

    /// The addressable parts of one row, so the offscreen probe drives the same identifiers the view builds
    /// and a row that silently stopped rendering its step fails the gate instead of shipping half a message.
    enum RowPart: String, CaseIterable {
        case status
        case title
        case opening
        case step
        case detail
        case action
    }

    static let headlineIdentifier = "onboarding-headline"
    static let subtitleIdentifier = "onboarding-subtitle"
    static let footerIdentifier = "onboarding-footer"
    static let recheckIdentifier = "onboarding-recheck"
    static let dismissIdentifier = "onboarding-dismiss"

    static func identifier(_ part: RowPart, _ provider: LLMProvider) -> String {
        "onboarding-\(part.rawValue)|\(provider.rawValue)"
    }

    static func cardIdentifier(_ provider: LLMProvider) -> String {
        "onboarding-card|\(provider.rawValue)"
    }
}
