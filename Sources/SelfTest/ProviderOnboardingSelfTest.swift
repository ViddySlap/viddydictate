import Foundation

/// Pure coverage for provider onboarding (Public V1 spec W4, item P9): what a user is told about a provider
/// that is signed out versus one that is not installed, and what they are offered in each case.
///
/// Every fixture is a synthetic presence map, so a green run here means the POLICY is right rather than that
/// this machine happens to have a provider signed in. No AppKit: the offscreen render gate
/// (`--provider-onboarding-render`) proves the view draws these strings, that an absent provider grows no
/// button, and that the two providers' buttons match in size and position; this gate proves the strings and
/// the derivation are right.
enum ProviderOnboardingSelfTest {

    static func run() -> Bool {
        Settings.registerDefaults()
        print("=== ViddyDictate provider onboarding (W4) - selftest ===")
        let reporter = SelfTestReporter()

        checkSatisfiedMachine(reporter)
        checkTwoStatesReadDifferently(reporter)
        checkOnlyInstalledIsOfferedAnAction(reporter)
        checkInlineRescueIsGeneralized(reporter)
        checkDerivedFromInstalledNotStored(reporter)
        checkOneProviderIsEnough(reporter)
        checkLocalCannotSatisfyOnboarding(reporter)
        checkEveryRowIsDistinctAndActionable(reporter)
        checkAsksNothingBeyondSigningIn(reporter)
        checkNeverBlocks(reporter)
        checkAgreesWithPreflight(reporter)
        checkFirstRunIsFirstRunOnly(reporter)
        checkClaudeSignInCommand(reporter)
        checkIdentifiersAreAddressable(reporter)
        checkPurity(reporter)

        print("\n=== RESULT ===")
        print(reporter.summaryLine(prefix: "Provider onboarding"))
        print(reporter.passed ? "PROVIDER ONBOARDING GREEN" : "PROVIDER ONBOARDING FAILED")
        return reporter.passed
    }

    // MARK: - Fixtures

    private static func presence(installed: Bool,
                                 _ state: LLMProviderAvailabilityState)
        -> LLMProviderDetection.Presence {
        LLMProviderDetection.Presence(installed: installed, state: state)
    }

    /// The presence a provider has in each of the three situations. Codex's signed-out signal is its own
    /// `.disconnected` case and Claude's is an unreadable credential file, which is exactly why the split is
    /// derived from `installed` rather than from the state vocabulary: the two vendors say it differently.
    private static func presence(_ provider: LLMProvider,
                                 _ situation: ProviderOnboardingSituation)
        -> LLMProviderDetection.Presence {
        switch (provider, situation) {
        case (_, .ready):
            return presence(installed: true, .available)
        case (.claude, .signedOut):
            return presence(installed: true, .disconnected)
        case (.codex, .signedOut):
            return presence(installed: true, .disconnected)
        case (.local, .signedOut):
            return presence(installed: true, .unavailable("LM Studio is not running"))
        case (.claude, .unavailable):
            return presence(
                installed: true,
                .unavailable(
                    "signed in with Claude auth method apiKey; ViddyDictate does not support it yet"))
        case (.codex, .unavailable):
            return presence(installed: true, .unavailable("connection audit unavailable"))
        case (.local, .unavailable):
            return presence(installed: true, .unavailable("LM Studio state unavailable"))
        case (.claude, .notInstalled):
            return presence(installed: false, .unavailable("CLI unavailable"))
        case (.codex, .notInstalled):
            return presence(installed: false, .unavailable("the codex CLI is not installed"))
        case (.local, .notInstalled):
            return presence(installed: false, .unavailable("LM Studio is not installed"))
        }
    }

    /// A whole map in one situation, including Local - which is deliberately available in every fixture, so
    /// every check below is also a check that a seeded-available Local arm never leaks into onboarding.
    private static func map(_ situation: ProviderOnboardingSituation)
        -> [LLMProvider: LLMProviderDetection.Presence] {
        var measured: [LLMProvider: LLMProviderDetection.Presence] = [
            .local: presence(installed: true, .available),
        ]
        for provider in ProviderOnboarding.providers {
            measured[provider] = presence(provider, situation)
        }
        return measured
    }

    /// The same map with Local in the same situation as the cloud providers. Used where the fixture has to be a
    /// machine on which NOTHING can run - `map` deliberately leaves Local available, so it cannot express that.
    private static func mapIncludingLocal(_ situation: ProviderOnboardingSituation)
        -> [LLMProvider: LLMProviderDetection.Presence] {
        var measured = map(situation)
        measured[.local] = presence(.local, situation)
        return measured
    }

    private static func plan(_ situation: ProviderOnboardingSituation) -> ProviderOnboarding.Plan {
        ProviderOnboarding.plan(providers: mapIncludingLocal(situation))
    }

    private static func step(_ provider: LLMProvider,
                             _ situation: ProviderOnboardingSituation) -> ProviderOnboardingStep {
        ProviderOnboarding.step(for: provider, presence: presence(provider, situation))
    }

    /// Every (provider, situation) pair onboarding can present. Derived from `allCases` on both axes, so a new
    /// situation or a newly onboardable provider cannot be added without landing in the distinctness and
    /// actionability checks below.
    private static var rows: [(provider: LLMProvider,
                               situation: ProviderOnboardingSituation,
                               step: ProviderOnboardingStep)] {
        ProviderOnboarding.providers.flatMap { provider in
            ProviderOnboardingSituation.allCases.map { situation in
                (provider, situation, step(provider, situation))
            }
        }
    }

    private static var everyString: [String] {
        rows.flatMap { [$0.step.title, $0.step.opening, $0.step.step, $0.step.detail ?? "",
                        $0.step.actionTitle ?? ""] }
            + [ProviderOnboarding.subtitle, ProviderOnboarding.footer,
               ProviderOnboarding.checkingHeadline,
               ProviderOnboarding.headline(plan(.ready)),
               ProviderOnboarding.headline(plan(.signedOut)),
               ProviderOnboarding.headline(plan(.notInstalled)),
               // The something-else-is-running headline is a string this surface owns too, so it is held to the
               // same never-block and names-no-model rules.
               ProviderOnboarding.headline(ProviderOnboarding.plan(providers: map(.notInstalled)))]
    }

    // MARK: - Checks

    private static func checkSatisfiedMachine(_ check: SelfTestReporter) {
        print("--- a machine with a provider signed in is done ---")
        let ready = plan(.ready)
        check("a signed-in provider satisfies onboarding", ready.isSatisfied)
        // L4/D3: the button stays for visual parity, and it is the SAME action - one flow, two labels.
        check("a signed-in row still carries a button, in the same place as the other row",
              ready.steps.allSatisfy { $0.action == .connect($0.provider) })
        check("the signed-in Claude button is not called Reconnect, because it does not reconnect (D3)",
              !ProviderOnboarding.actionTitle(.claude, .ready).lowercased().contains("reconnect")
                && ProviderOnboarding.actionTitle(.claude, .ready) == "About this sign-in",
              ProviderOnboarding.actionTitle(.claude, .ready))
        check("Codex keeps its genuine Reconnect, because its credential is ViddyDictate's own",
              ProviderOnboarding.actionTitle(.codex, .ready).contains("Reconnect"),
              ProviderOnboarding.actionTitle(.codex, .ready))
        check("the connected rows say what their own button is for",
              ready.step(.claude)?.step.contains("About this sign-in") == true
                && ready.step(.codex)?.step.contains("Reconnect Codex") == true)
        check("a signed-in row still says what was found",
              ready.steps.allSatisfy { !$0.opening.isEmpty && !$0.step.isEmpty })
        check("a signed-in row quotes no vendor reason",
              ready.steps.allSatisfy { $0.detail == nil })
        check("the satisfied headline names the provider that is signed in",
              ProviderOnboarding.headline(ready).contains(ProviderOnboarding.productName(for: .claude)))
        check("the log token records the situation per provider and nothing else",
              ready.logToken == "onboarding satisfied=true other=true claude=ready codex=ready",
              ready.logToken)
    }

    private static func checkTwoStatesReadDifferently(_ check: SelfTestReporter) {
        print("--- W4: installed-but-signed-out and not-installed are two different messages ---")
        for provider in ProviderOnboarding.providers {
            let out = step(provider, .signedOut)
            let absent = step(provider, .notInstalled)
            check("\(provider.rawValue): the two states do not share an opening sentence",
                  out.opening != absent.opening)
            check("\(provider.rawValue): the two states do not share a next step",
                  out.step != absent.step)
            check("\(provider.rawValue): the two states do not share a state word",
                  out.situation.statusText != absent.situation.statusText)
            check("\(provider.rawValue): signed out says it is installed and does not say to install it",
                  out.opening.contains("installed on this Mac but not signed in")
                    && !out.step.lowercased().contains("install "))
            check("\(provider.rawValue): not installed says to install it and does not say to sign in",
                  absent.opening.contains("is not installed")
                    && absent.step.lowercased().contains("install ")
                    && !absent.step.lowercased().contains("signs in with"))
            // W4: re-running the check IS the transition between the two states, and no second mechanism is
            // built for it, so the absent row has to say that is what makes the button appear.
            check("\(provider.rawValue): not installed says re-checking is what turns it into the other state",
                  absent.step.contains("check again") && absent.step.contains("appears once it is here"))
        }
        check("the two providers do not read as each other",
              step(.claude, .signedOut).opening != step(.codex, .signedOut).opening
                && step(.claude, .notInstalled).step != step(.codex, .notInstalled).step)
    }

    private static func checkOnlyInstalledIsOfferedAnAction(_ check: SelfTestReporter) {
        print("--- W4: an installed provider is offered a button, an absent one is not ---")
        for provider in ProviderOnboarding.providers {
            check("\(provider.rawValue): signed out is offered its own connect action",
                  step(provider, .signedOut).action == .connect(provider))
            check("\(provider.rawValue): not installed is offered no action",
                  step(provider, .notInstalled).action == nil)
            check("\(provider.rawValue): already signed in is offered the same action, not a second one",
                  step(provider, .ready).action == .connect(provider))
            check("\(provider.rawValue): installed but unavailable is not offered a sign-in loop",
                  step(provider, .unavailable).action == nil)
            check("\(provider.rawValue): the button names the vendor's own word for signing in",
                  ProviderOnboarding.actionTitle(provider, .signedOut)
                    .contains(provider == .codex ? "Connect" : "Sign in"))
            check("\(provider.rawValue): the two labels differ, because the two situations do",
                  ProviderOnboarding.actionTitle(provider, .ready)
                    != ProviderOnboarding.actionTitle(provider, .signedOut))
        }
        // W4's one-flow rule, stated as an invariant over every row this surface can produce: whatever a
        // button says, clicking it enters the one connect flow for that row's own provider.
        check("every button anywhere in onboarding enters the one connect flow for its own row",
              rows.allSatisfy { $0.step.action == nil || $0.step.action == .connect($0.provider) })
        check("only the rows ViddyDictate can act on carry buttons",
              plan(.signedOut).steps.allSatisfy(\.offersAction)
                && plan(.ready).steps.allSatisfy(\.offersAction)
                && plan(.unavailable).steps.allSatisfy { !$0.offersAction }
                && plan(.notInstalled).steps.allSatisfy { !$0.offersAction })
        check("a row without an action has no label to render either",
              rows.allSatisfy { $0.step.offersAction == ($0.step.actionTitle != nil) })
    }

    /// D6: the Models tab's inline rescue - picking a disconnected provider for a route - stays, and stops
    /// being Codex-only. The route is still not changed; the connect flow opens for whichever provider was
    /// picked. The wording is pure, so it is covered here rather than only by the GUI probe that clicks it.
    private static func checkInlineRescueIsGeneralized(_ check: SelfTestReporter) {
        print("--- D6: the inline rescue opens the same flow for either provider ---")
        for provider in ProviderOnboarding.providers {
            let line = ModelsPowerSettingsView.inlineRescueStatus(for: provider)
            check("\(provider.rawValue): the rescue names the provider that was picked",
                  line.contains(ModelsPowerSettingsView.displayName(for: provider)), line)
            check("\(provider.rawValue): the rescue names the button it just opened",
                  line.contains(ProviderOnboarding.actionTitle(provider, .signedOut)), line)
            check("\(provider.rawValue): the rescue says the route did not change",
                  line.contains("without changing any route"), line)
        }
        check("neither provider is the special case any more",
              ModelsPowerSettingsView.inlineRescueStatus(for: .claude)
                != ModelsPowerSettingsView.inlineRescueStatus(for: .codex)
                && !ModelsPowerSettingsView.inlineRescueStatus(for: .claude).contains("Codex"))
        check("a provider ViddyDictate cannot sign in to is not promised a sign-in",
              !ProviderOnboarding.canDriveSignIn(.local)
                && !ModelsPowerSettingsView.inlineRescueStatus(for: .local).contains("Opened")
                && ModelsPowerSettingsView.inlineRescueStatus(for: .local).contains("no route changed"))
    }

    private static func checkDerivedFromInstalledNotStored(_ check: SelfTestReporter) {
        print("--- install state and connection state remain distinct ---")
        // A real disconnect plus the installed bit drives W4's sign-in versus install split.
        for provider in ProviderOnboarding.providers {
            let state = LLMProviderAvailabilityState.disconnected
            let installed = ProviderOnboarding.step(
                for: provider, presence: presence(installed: true, state))
            let absent = ProviderOnboarding.step(
                for: provider, presence: presence(installed: false, state))
            check("\(provider.rawValue): flipping only `installed` flips the situation",
                  installed.situation == .signedOut && absent.situation == .notInstalled)
            check("\(provider.rawValue): flipping only `installed` flips whether an action is offered",
                  installed.offersAction && !absent.offersAction)
            let unavailable = ProviderOnboarding.step(
                for: provider,
                presence: presence(
                    installed: true, .unavailable("something the vendor said")))
            check("\(provider.rawValue): installed non-disconnect is a separate unavailable situation",
                  unavailable.situation == .unavailable && !unavailable.offersAction)
            check("\(provider.rawValue): an installed-but-unavailable provider quotes the reason",
                  unavailable.detail?.contains("something the vendor said") == true)
        }
        check("a plain disconnect adds no reason line, because the sentence already says it",
              ProviderOnboarding.step(for: .codex,
                                      presence: presence(installed: true, .disconnected)).detail == nil)
        check("a runaway vendor reason is bounded before it reaches a row",
              (ProviderOnboarding.step(
                for: .codex,
                presence: presence(installed: true,
                                   .unavailable(String(repeating: "x", count: 4_000)))).detail?.count ?? 0)
                < 400)
        check("a provider nobody measured is never counted as signed in",
              ProviderOnboarding.plan(providers: [:]).steps.allSatisfy {
                  $0.situation == .notInstalled
              } && !ProviderOnboarding.plan(providers: [:]).isSatisfied)
    }

    private static func checkOneProviderIsEnough(_ check: SelfTestReporter) {
        print("--- locked decision 3: one provider is enough, never both ---")
        for ready in ProviderOnboarding.providers {
            var measured = map(.signedOut)
            measured[ready] = presence(installed: true, .available)
            let plan = ProviderOnboarding.plan(providers: measured)
            check("only \(ready.rawValue) signed in satisfies onboarding", plan.isSatisfied)
            check("the other provider is still listed with its own next step",
                  plan.steps.count == ProviderOnboarding.providers.count
                    && plan.steps.filter { $0.situation != .ready }.allSatisfy(\.offersAction))
            check("the headline names the one that is signed in and not the one that is not",
                  ProviderOnboarding.headline(plan)
                    .contains(ProviderOnboarding.productName(for: ready)))
        }
        check("onboarding covers exactly the providers whose sign-in it can drive",
              ProviderOnboarding.providers == [.claude, .codex],
              ProviderOnboarding.providers.map(\.rawValue).joined(separator: ","))
        check("the providers are listed in the order routing would try them",
              ProviderOnboarding.providers
                == LLMAvailabilityRouting.fallbackOrder.filter(ProviderOnboarding.canDriveSignIn))
    }

    private static func checkLocalCannotSatisfyOnboarding(_ check: SelfTestReporter) {
        print("--- a seeded-available Local arm cannot make onboarding look satisfied ---")
        // P6 recorded that nothing ever writes `.local` availability, so in production a Local arm always
        // reads available. If onboarding counted it, every machine on earth would look set up while no cloud
        // provider was signed in - the exact false green this whole surface exists to prevent.
        let measured = map(.notInstalled)
        check("Local is measured as available in this fixture, so the check means something",
              measured[.local]?.state.canRun == true)
        let plan = ProviderOnboarding.plan(providers: measured)
        check("an available Local arm does not satisfy onboarding", !plan.isSatisfied)
        check("Local gets no row at all", plan.step(.local) == nil)
        check("onboarding does not claim to drive an LM Studio sign-in",
              !ProviderOnboarding.canDriveSignIn(.local))

        // ...but it is not ignored either. Onboarding and the preflight provider row share the Setup tab, and
        // preflight passes when ANY provider can run. Without this, a machine with LM Studio running would read
        // "Signed in to Local" one inch below "Sign in to one provider" and one of the two would be false.
        check("a running Local arm is recognised as something that can already run the transforms",
              plan.otherProviderCanRun && plan.nothingIsMissing)
        check("the headline says signing in is optional rather than telling the user to fix it",
              ProviderOnboarding.headline(plan).contains("running on LM Studio")
                && ProviderOnboarding.headline(plan).contains("optional"))
        check("the sign-in buttons are still offered, because a cloud provider is still the V1 baseline",
              plan.steps.filter { $0.situation == .signedOut }.allSatisfy(\.offersAction))
        check("a machine that already works is not interrupted on first run",
              !ProviderOnboarding.shouldPresentFirstRun(hasEverBeenSatisfied: false, plan: plan))
        // The flag records a real sign-in, not "something happened to be running", so if that local server goes
        // away the window does appear - at that point something genuinely is missing.
        check("nothing else running is not recorded as a provider having been signed in", !plan.isSatisfied)
    }

    private static func checkEveryRowIsDistinctAndActionable(_ check: SelfTestReporter) {
        print("--- every row reads differently and names something concrete to do ---")
        let readable = rows.map { row in
            "\(row.step.title) [\(row.step.situation.statusText)] \(row.step.opening) \(row.step.step)"
        }
        check("no two rows read the same to a user",
              Set(readable).count == readable.count,
              "\(Set(readable).count) distinct of \(readable.count)")
        check("every row says what state it is in and what happens next",
              rows.allSatisfy { !$0.step.opening.isEmpty && !$0.step.step.isEmpty })

        // "Actionable" means it names a command, an app to install, or a button - not merely non-empty.
        let actionTokens = ["claude auth login", "Install Claude Code", "Install ChatGPT.app",
                            "Connect Codex", "Sign in to Claude Code", "Nothing to do",
                            "does not support this Claude connection", "Review the reported Codex"]
        check("every next step names a command, an app to install, or the button that does it",
              rows.allSatisfy { row in actionTokens.contains { row.step.step.contains($0) } })
        check("every row names the product a user would go looking for, not the internal provider name",
              ProviderOnboarding.providers.allSatisfy { provider in
                  let name = ProviderOnboarding.productName(for: provider)
                  return name != ModelsPowerSettingsView.displayName(for: provider)
                      && rows.filter { $0.provider == provider }.allSatisfy { $0.step.title == name }
              })
    }

    private static func checkAsksNothingBeyondSigningIn(_ check: SelfTestReporter) {
        print("--- locked decision 5: onboarding signs the user in and asks nothing else ---")
        // A model, effort, or route action is not expressible, so onboarding cannot set a model preference by
        // mistake. Adding a second case here would red this check rather than shipping quietly.
        check("connecting a provider is the only action onboarding can express",
              ProviderOnboardingAction.Kind.allCases.map(\.rawValue) == ["connect"])

        // Every model this build ships as a tested default. Onboarding must name none of them: a first-run
        // user has no basis to choose between them, so it must not present one either.
        var modelIDs: Set<String> = []
        for route in LLMRouteID.builtIns {
            for provider in LLMProvider.allCases {
                if let bundle = LLMProviderDefaults.testedBundle(for: provider, route: route) {
                    modelIDs.insert(bundle.modelID)
                }
            }
        }
        check("the shipped model list is non-empty, so this check means something", !modelIDs.isEmpty)
        let named = modelIDs.filter { id in everyString.contains { $0.contains(id) } }
        check("no onboarding string names a specific model",
              named.isEmpty, named.sorted().joined(separator: ","))
        check("no onboarding string asks the user to choose an effort or a route",
              everyString.allSatisfy { text in
                  let lower = text.lowercased()
                  return !lower.contains("effort") && !lower.contains("route")
              })
        check("the footer says outright that it sets no model choices",
              ProviderOnboarding.footer.contains("sets no model choices"))
        check("the footer says an API key is never asked for, per locked decision 2",
              ProviderOnboarding.footer.contains("never asks for an API key"))
    }

    private static func checkNeverBlocks(_ check: SelfTestReporter) {
        print("--- W5: onboarding warns and says so; it never gates the app ---")
        // The same phrase list preflight's gates apply to their messages, applied to the strings this surface
        // owns. A first-run window whose headline said "sign in before continuing" would violate W5 as surely
        // as a blocking severity, and no type can catch a sentence.
        let blockingPhrases = ["cannot continue", "before you can use", "you must fix", "not allowed",
                               "disabled until", "required before", "before continuing", "must be fixed",
                               "must sign in", "you may not"]
        let offenders = everyString.filter { text in
            let lower = text.lowercased()
            return blockingPhrases.contains { lower.contains($0) }
        }
        check("no onboarding string tells the user they may not proceed",
              offenders.isEmpty, offenders.joined(separator: " | "))
        check("the subtitle says dictation already works without a provider",
              ProviderOnboarding.subtitle.contains("Dictation already works")
                && ProviderOnboarding.subtitle.contains("never stops you from dictating"))
        check("the subtitle says one provider is enough, matching locked decision 3",
              ProviderOnboarding.subtitle.contains("never needs both"))
        check("the unsatisfied headline is an instruction, not a refusal",
              ProviderOnboarding.headline(plan(.notInstalled))
                == "Sign in to one provider to turn on the text features.")
    }

    private static func checkAgreesWithPreflight(_ check: SelfTestReporter) {
        print("--- onboarding and preflight never contradict each other on the same tab ---")
        // P8's provider check and this surface both read the same presence map and both appear on the Setup
        // tab. They word things for different shapes - a menu of alternatives versus one row per provider - so
        // the wording is deliberately not shared. What must never differ is the VERDICT, and this is the
        // invariant that pins it: preflight warns about providers exactly when onboarding says something is
        // missing. It is what caught the LM-Studio-running case, where the first draft had onboarding telling
        // a user to sign in while preflight reported the very same machine green.
        func providerWarns(_ measured: [LLMProvider: LLMProviderDetection.Presence]) -> Bool {
            var observation = PreflightSelfTest.healthy
            observation.providers = measured
            return Preflight.evaluate(observation).finding(.textProvider)?.isWarning == true
        }

        var disagreed: [String] = []
        var fixtures: [(String, [LLMProvider: LLMProviderDetection.Presence])] = []
        for situation in ProviderOnboardingSituation.allCases {
            fixtures.append(("all-\(situation.rawValue)", mapIncludingLocal(situation)))
            fixtures.append(("cloud-\(situation.rawValue)-local-running", map(situation)))
            for provider in ProviderOnboarding.providers {
                var one = mapIncludingLocal(situation)
                one[provider] = presence(installed: true, .available)
                fixtures.append(("\(provider.rawValue)-ready-others-\(situation.rawValue)", one))
            }
        }
        fixtures.append(("nothing-measured", [:]))
        for (label, measured) in fixtures {
            let plan = ProviderOnboarding.plan(providers: measured)
            if providerWarns(measured) != !plan.nothingIsMissing { disagreed.append(label) }
        }
        check("across every fixture, preflight warns exactly when onboarding says something is missing",
              disagreed.isEmpty, disagreed.joined(separator: ","))
        check("the fixture set covers both verdicts, so the invariant is not vacuous",
              fixtures.contains { providerWarns($0.1) } && fixtures.contains { !providerWarns($0.1) },
              "\(fixtures.count) fixtures")

        // The two states still have to agree on WHICH remedy they are pointing at, not just on the verdict.
        let absentRemedy: String = {
            var o = PreflightSelfTest.healthy
            o.providers = mapIncludingLocal(.notInstalled)
            return Preflight.evaluate(o).finding(.textProvider)?.remedy ?? ""
        }()
        check("when nothing is installed, preflight says install and onboarding offers no button",
              absentRemedy.contains("install Claude Code")
                && absentRemedy.contains("install ChatGPT.app")
                && plan(.notInstalled).steps.allSatisfy { !$0.offersAction })

        let signedOutRemedy: String = {
            var o = PreflightSelfTest.healthy
            o.providers = mapIncludingLocal(.signedOut)
            return Preflight.evaluate(o).finding(.textProvider)?.remedy ?? ""
        }()
        check("when both are installed, preflight says sign in and onboarding offers both buttons",
              signedOutRemedy.contains("claude auth login")
                && signedOutRemedy.contains("click Connect")
                && !signedOutRemedy.contains("install ChatGPT.app")
                && plan(.signedOut).steps.allSatisfy(\.offersAction))
    }

    private static func checkFirstRunIsFirstRunOnly(_ check: SelfTestReporter) {
        print("--- the first-run window appears before a provider has ever been signed in, and not after ---")
        check("a fresh install with no provider is shown onboarding",
              ProviderOnboarding.shouldPresentFirstRun(hasEverBeenSatisfied: false,
                                                       plan: plan(.notInstalled)))
        check("a fresh install that already has a provider is not interrupted",
              !ProviderOnboarding.shouldPresentFirstRun(hasEverBeenSatisfied: false,
                                                        plan: plan(.ready)))
        check("a machine that has had a provider before is never shown it again",
              !ProviderOnboarding.shouldPresentFirstRun(hasEverBeenSatisfied: true,
                                                        plan: plan(.signedOut)))
        check("a signed-out provider on a set-up machine is not a reason to nag at launch",
              !ProviderOnboarding.shouldPresentFirstRun(hasEverBeenSatisfied: true,
                                                        plan: plan(.notInstalled)))
        // The gate runs against a scratch HOME, so this reads the REGISTERED default rather than a value some
        // earlier run left behind. Nothing in this gate writes the flag.
        check("the persisted flag defaults to never-satisfied on a fresh install",
              Settings.providerOnboardingSatisfied == false)
    }

    private static func checkClaudeSignInCommand(_ check: SelfTestReporter) {
        print("--- the Claude action runs the vendor's own login command, and only that ---")
        let body = ClaudeSignIn.scriptBody(binary: "/usr/local/bin/claude")
        check("the script runs claude auth login",
              body.contains("'/usr/local/bin/claude' auth login"))
        check("the script is a shell script Terminal will execute", body.hasPrefix("#!/bin/zsh"))
        check("the script hands the terminal over to the vendor's own UI", body.contains("exec "))
        // D5 replaced the manual re-check: the app polls the vendor's status command and closes its own
        // sheet, so the script must not send the user looking for a button that is no longer the mechanism.
        check("the script tells the user the app notices by itself",
              body.contains("ViddyDictate notices by itself") && !body.contains("Check again"))
        // `--console` would switch the user to Anthropic Console API-usage billing, which is not what a
        // subscription sign-in means (locked decision 2). No API key is ever passed either.
        check("the script never switches the login to API-usage billing", !body.contains("--console"))
        check("the script carries no key material or key environment variable",
              !body.contains("ANTHROPIC") && !body.lowercased().contains("api_key"))
        check("a path with a space or a quote is quoted for the shell",
              ClaudeSignIn.scriptBody(binary: "/Users/a b/it's/claude")
                .contains("'/Users/a b/it'\\''s/claude' auth login"))
        check("the command shown to the user is the command the script runs",
              body.contains(ClaudeSignIn.command(binary: "/usr/local/bin/claude")))
        var openedWithoutABinary = false
        let missing = ClaudeSignIn.launch(binary: nil, open: { _ in
            openedWithoutABinary = true
            return true
        })
        check("a missing CLI is reported rather than launched",
              missing == .notInstalled && !openedWithoutABinary)
        check("the launcher reports failure when the terminal refuses to open",
              ClaudeSignIn.launch(binary: "/usr/local/bin/claude", open: { _ in false })
                == .failed("Terminal did not open."))
        var handed: URL?
        let outcome = ClaudeSignIn.launch(binary: "/usr/local/bin/claude", open: { url in
            handed = url
            return true
        })
        check("a successful launch reports the command it handed over",
              outcome == .launched(command: ClaudeSignIn.command(binary: "/usr/local/bin/claude")))
        check("the file handed to Terminal is an executable .command it can run",
              handed?.lastPathComponent == ClaudeSignIn.scriptName
                && handed?.pathExtension == "command"
                && (try? FileManager.default.attributesOfItem(atPath: handed?.path ?? "")[.posixPermissions]
                    as? NSNumber)?.intValue == 0o700,
              handed?.path ?? "nothing handed over")
        check("the staged script on disk is the script the gate asserted",
              (try? String(contentsOf: handed ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8))
                == body)
    }

    private static func checkIdentifiersAreAddressable(_ check: SelfTestReporter) {
        print("--- every part of every row is addressable exactly once ---")
        var identifiers: [String] = []
        for part in ProviderOnboarding.RowPart.allCases {
            for provider in LLMProvider.allCases {
                identifiers.append(ProviderOnboarding.identifier(part, provider))
            }
        }
        identifiers.append(contentsOf: LLMProvider.allCases.map(ProviderOnboarding.cardIdentifier))
        identifiers.append(contentsOf: [
            ProviderOnboarding.headlineIdentifier, ProviderOnboarding.subtitleIdentifier,
            ProviderOnboarding.footerIdentifier, ProviderOnboarding.recheckIdentifier,
            ProviderOnboarding.dismissIdentifier,
        ])
        check("no two controls claim the same identifier",
              Set(identifiers).count == identifiers.count,
              "\(Set(identifiers).count) of \(identifiers.count)")
        check("a row identifier names both the part and the provider",
              ProviderOnboarding.identifier(.action, .codex) == "onboarding-action|codex")
        // The Setup tab hosts both surfaces at once, so a collision between them would make the probe address
        // the wrong control.
        var preflightIdentifiers: [String] = []
        for part in PreflightSurface.RowPart.allCases {
            for target in PreflightCheck.allCases {
                preflightIdentifiers.append(PreflightSurface.identifier(part, target))
            }
        }
        preflightIdentifiers.append(contentsOf: PreflightCheck.allCases.map(PreflightSurface.cardIdentifier))
        preflightIdentifiers.append(PreflightSurface.recheckIdentifier)
        check("onboarding claims no identifier the preflight surface already owns",
              Set(identifiers).isDisjoint(with: Set(preflightIdentifiers)))
    }

    private static func checkPurity(_ check: SelfTestReporter) {
        print("--- the plan is a pure function of the measurement ---")
        let measured = map(.signedOut)
        check("the same measurement plans identically twice",
              ProviderOnboarding.plan(providers: measured)
                == ProviderOnboarding.plan(providers: measured))

        var changed = measured
        changed[.claude] = presence(installed: true, .available)
        let before = ProviderOnboarding.plan(providers: measured)
        let after = ProviderOnboarding.plan(providers: changed)
        let differing = zip(before.steps.sorted { $0.provider.rawValue < $1.provider.rawValue },
                            after.steps.sorted { $0.provider.rawValue < $1.provider.rawValue })
            .filter { $0 != $1 }
            .map(\.0.provider)
        check("signing one provider in changes exactly that provider's row", differing == [.claude])
        check("it also flips the plan from unsatisfied to satisfied",
              !before.isSatisfied && after.isSatisfied)
        check("re-planning over an unchanged measurement is stable",
              (0..<3).allSatisfy { _ in
                  ProviderOnboarding.plan(providers: changed) == ProviderOnboarding.plan(providers: changed)
              })
    }
}
