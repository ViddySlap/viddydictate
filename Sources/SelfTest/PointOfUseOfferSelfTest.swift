import Foundation

/// The deterministic rail under the point-of-use offer (`--point-of-use-offer-selftest`).
///
/// Everything here is pure: synthetic provider presences, a synthetic bootstrap snapshot, and an injected
/// LM Studio performer. Nothing attaches a disk image, writes to `/Applications`, runs `lms`, or spends a
/// byte of anybody's bandwidth - which is the point, because the surface under test is the one that
/// appears when a several-gigabyte download is the missing piece.
///
/// **The check this file exists for is B16.** With zero local models the app must not silently route
/// dictated text to Claude or Codex, and getting that wrong is not recoverable. It is pinned twice: once
/// structurally, by asserting that the set of things a point-of-use button can express is exactly
/// {skip, install, guidedProvider} - so a future automatic cloud hop cannot be added without reding this
/// gate - and once behaviourally, by driving the zero-everything state through the policy and asserting
/// the result is a chooser whose cloud entries are buttons.
enum PointOfUseOfferSelfTest {

    // MARK: - Fixtures

    private static func presence(_ installed: Bool, _ state: LLMProviderAvailabilityState,
                                 models: [LMStudioModelOption]? = nil)
        -> LLMProviderDetection.Presence {
        LLMProviderDetection.Presence(installed: installed, state: state, availableLocalModels: models)
    }

    /// Nothing at all: no LM Studio, no Claude CLI, no Codex CLI. The B14 state.
    private static var bareMachine: [LLMProvider: LLMProviderDetection.Presence] {
        [.local: presence(false, .unavailable("LM Studio is not installed")),
         .claude: presence(false, .unavailable("CLI unavailable")),
         .codex: presence(false, .unavailable("the codex CLI is not installed"))]
    }

    /// LM Studio absent, but Claude Code is here and signed in. NOT the chooser state: the user has
    /// something, so the honest offer is the local model they reached for.
    private static var claudeOnly: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = bareMachine
        providers[.claude] = presence(true, .available)
        return providers
    }

    /// LM Studio installed and answering, with one unrelated model. gemma and qwen are both absent.
    private static var lmStudioWithoutTheModel: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = bareMachine
        providers[.local] = presence(true, .available,
                                     models: [LMStudioModelOption(modelID: "llama-3.2-1b-instruct",
                                                                  label: "llama")])
        return providers
    }

    /// LM Studio installed but its catalog did not answer. Measurably unknown, which is NOT "missing".
    private static var lmStudioCatalogUnknown: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = bareMachine
        providers[.local] = presence(true, .unavailable("LM Studio is not running"), models: nil)
        return providers
    }

    private static var gemmaInstalled: [LLMProvider: LLMProviderDetection.Presence] {
        var providers = bareMachine
        providers[.local] = presence(
            true, .available,
            models: [LMStudioModelOption(modelID: LMStudioInstaller.gemmaModelID, label: "gemma")])
        return providers
    }

    private static var freshBootstrap: BootstrapSnapshot {
        BootstrapSnapshot.fresh(descriptors: BootstrapInstallPlan.allComponents)
    }

    private static var coreInstalled: BootstrapSnapshot {
        var snapshot = freshBootstrap
        for descriptor in BootstrapInstallPlan.mandatoryCore {
            snapshot.apply(InstallerComponentResult(componentID: descriptor.id,
                                                    title: descriptor.title, state: .installed))
        }
        return snapshot
    }

    // MARK: - Run

    static func run() -> Bool {
        let report = SelfTestReporter()

        print("--- B16: what a point-of-use button can express, and nothing more ---")
        checkNoAutomaticCloudHop(report)
        print("--- B14: the four-button chooser, and only when the machine has nothing ---")
        checkChooser(report)
        print("--- B13: the in-place install offer and its prerequisite chain ---")
        checkInstallOffer(report)
        print("--- O1: measured byte counts only ---")
        checkMeasuredSizes(report)
        print("--- B10 / O7: real errors, and no generic setup string ---")
        checkCopy(report)
        print("--- one installer: descriptors, validation, and the O5 retry rule on the new arm ---")
        checkEngine(report)
        print("--- B17: the guided panel for a CLI that is not on this Mac ---")
        checkGuidance(report)
        print("--- identity ---")
        checkIdentifiers(report)

        print(report.summaryLine(prefix: "[point-of-use-offer-selftest]"))
        return report.passed
    }

    // MARK: - B16

    private static func checkNoAutomaticCloudHop(_ check: SelfTestReporter) {
        check("a point-of-use button can express exactly skip, install, and guidedProvider",
              PointOfUseRoute.Kind.allCases.map(\.rawValue).sorted()
                == ["guidedProvider", "install", "skip"],
              PointOfUseRoute.Kind.allCases.map(\.rawValue).joined(separator: ","))

        // Every offer this policy can produce, over every feature and every fixture, and not one of them
        // may carry a route that executes anything.
        var produced: [PointOfUseOffer] = []
        let machines = [bareMachine, claudeOnly, lmStudioWithoutTheModel, gemmaInstalled]
        for feature in PointOfUseFeature.all {
            for machine in machines {
                for bootstrap in [freshBootstrap, coreInstalled] {
                    if let offer = PointOfUsePolicy.offer(for: feature, presences: machine,
                                                          bootstrap: bootstrap) {
                        produced.append(offer)
                    }
                }
            }
        }
        check("the policy produced offers to inspect", !produced.isEmpty, "\(produced.count)")
        let kinds = Set(produced.flatMap { $0.buttons.map(\.route.kind) })
        check("no produced button routes anywhere but skip / install / guidedProvider",
              kinds.isSubset(of: [.skip, .install, .guidedProvider]),
              kinds.map(\.rawValue).sorted().joined(separator: ","))

        // A cloud button may exist ONLY on the chooser, and the chooser may exist ONLY for a feature a
        // text provider could genuinely satisfy. Transcription can never be offered a cloud button,
        // because Claude cannot transcribe and pretending otherwise would be the same lie in a new place.
        for feature in PointOfUseFeature.all where feature.satisfaction == .localOnly {
            let offer = PointOfUsePolicy.offer(for: feature, presences: bareMachine,
                                               bootstrap: freshBootstrap)
            let hasCloudButton = offer?.buttons.contains { $0.route.kind == .guidedProvider } ?? false
            check("\(feature.id) is never offered a cloud provider", !hasCloudButton)
            if case .chooser = offer {
                check("\(feature.id) is never offered the chooser", false)
            } else {
                check("\(feature.id) is never offered the chooser", true)
            }
        }
    }

    // MARK: - B14

    private static func checkChooser(_ check: SelfTestReporter) {
        guard case .chooser(let chooser)? = PointOfUsePolicy.offer(
            for: .email, presences: bareMachine, bootstrap: coreInstalled) else {
            check("a machine with nothing installed gets the chooser", false)
            return
        }
        check("a machine with nothing installed gets the chooser", true)
        check("the chooser offers exactly the four spec buttons, in order",
              chooser.buttons.map(\.id) == [
                PointOfUsePolicy.skipButtonID, PointOfUsePolicy.claudeButtonID,
                PointOfUsePolicy.codexButtonID, PointOfUsePolicy.localButtonID],
              chooser.buttons.map(\.id).joined(separator: ","))
        check("every chooser button states what pressing it does",
              chooser.buttons.allSatisfy { !$0.detail.isEmpty })
        check("the chooser says outright that nothing has been sent anywhere",
              chooser.lines.contains { $0.contains("has sent nothing anywhere") },
              chooser.lines.joined(separator: " | "))
        check("Set up local models enters the same install rather than a second flow",
              chooser.buttons.first { $0.id == PointOfUsePolicy.localButtonID }?.route == .install)
        check("the chooser carries the local components that button would install",
              chooser.localComponents.map(\.id)
                == [BootstrapInstallPlan.lmStudio.id, BootstrapInstallPlan.gemma.id])

        // One installed cloud CLI is enough to make this NOT the nothing-at-all state.
        if case .install? = PointOfUsePolicy.offer(for: .email, presences: claudeOnly,
                                                   bootstrap: coreInstalled) {
            check("a machine that already has the Claude CLI gets the install offer, not the chooser", true)
        } else {
            check("a machine that already has the Claude CLI gets the install offer, not the chooser", false)
        }
        check("an unmeasured provider is never counted as absent",
              !PointOfUsePolicy.hasNothingInstalled(presences: [:]))
    }

    // MARK: - B13

    private static func checkInstallOffer(_ check: SelfTestReporter) {
        guard case .install(let offer)? = PointOfUsePolicy.offer(
            for: .email, presences: claudeOnly, bootstrap: coreInstalled) else {
            check("email mode with no LM Studio offers an install", false)
            return
        }
        check("email mode with no LM Studio offers an install", true)
        check("LM Studio comes before the model it holds",
              offer.components.map(\.id)
                == [BootstrapInstallPlan.lmStudio.id, BootstrapInstallPlan.gemma.id])
        check("the same panel says LM Studio goes first",
              offer.lines.contains { $0.contains("LM Studio is not installed yet") },
              offer.lines.joined(separator: " | "))
        check("the offer names the feature and the exact model",
              offer.lines.first?.contains("Email mode uses \(LMStudioInstaller.gemmaModelID)") == true,
              offer.lines.first ?? "")
        check("the offer promises the component goes live on its own (B8)",
              offer.lines.contains { $0.contains("runs as soon as it lands") })
        check("the offer's two buttons are Install now and Not now",
              offer.buttons.map(\.id) == [PointOfUsePolicy.installButtonID,
                                          PointOfUsePolicy.skipButtonID])

        // ONE mechanism: the components handed over are the shipped descriptors themselves, not a
        // second description of the same thing that could drift from what setup installs.
        check("the offer hands over the shipped descriptors unchanged",
              offer.components == [BootstrapInstallPlan.lmStudio, BootstrapInstallPlan.gemma])

        guard case .install(let modelOnly)? = PointOfUsePolicy.offer(
            for: .email, presences: lmStudioWithoutTheModel, bootstrap: coreInstalled) else {
            check("an installed LM Studio is not re-offered", false)
            return
        }
        check("an installed LM Studio is not re-offered",
              modelOnly.components.map(\.id) == [BootstrapInstallPlan.gemma.id])

        check("an installed model produces no offer at all",
              PointOfUsePolicy.offer(for: .email, presences: gemmaInstalled,
                                     bootstrap: coreInstalled) == nil)
        // The one that would send a user on a several-gigabyte errand to fix a thing that is already
        // there: LM Studio installed, merely stopped, so its catalog cannot answer.
        check("an unanswerable catalog produces no offer rather than a guess",
              PointOfUsePolicy.offer(for: .email, presences: lmStudioCatalogUnknown,
                                     bootstrap: coreInstalled) == nil)
        check("a mandatory core row that is not installed is offered",
              PointOfUsePolicy.offer(for: .dictation, presences: gemmaInstalled,
                                     bootstrap: freshBootstrap) != nil)
        check("a mandatory core row that IS installed is not offered",
              PointOfUsePolicy.offer(for: .dictation, presences: gemmaInstalled,
                                     bootstrap: coreInstalled) == nil)

        // The route a mode ran is the only key from a landing to an offer, so the two cannot disagree.
        check("the email route maps to email mode", PointOfUseFeature.forRoute(.email) == .email)
        check("every cleanup level maps to the cleanup feature",
              LLMRouteID.cleanupRoutes.allSatisfy { PointOfUseFeature.forRoute($0) == .cleanup })
        check("prompt prep maps to prompt prep",
              PointOfUseFeature.forRoute(.promptPrep) == .promptPrep)
        check("a search route has no point-of-use component to offer",
              PointOfUseFeature.forRoute(.searchGeminiSynth) == nil)
        check("a custom mode has no point-of-use component to offer",
              PointOfUseFeature.forRoute(.custom("abc")) == nil)
    }

    // MARK: - O1

    private static func checkMeasuredSizes(_ check: SelfTestReporter) {
        // Measured from `lms ls --llm --json` on 2026-08-27. The spec's "~4 GB" for gemma was an
        // estimate and it was out by 1.7x, which is exactly why O1 forbids shipping one.
        check("gemma carries its measured byte count",
              BootstrapInstallPlan.gemma.downloadBytes == 6_861_935_454,
              String(describing: BootstrapInstallPlan.gemma.downloadBytes))
        check("qwen carries its measured byte count",
              BootstrapInstallPlan.qwen.downloadBytes == 17_190_793_452,
              String(describing: BootstrapInstallPlan.qwen.downloadBytes))
        check("the LM Studio DMG quotes no size, because nobody has measured one",
              BootstrapInstallPlan.lmStudio.downloadBytes == nil)
        check("the shared formatter renders gemma the way lms itself would",
              LMStudioModelCatalog.decimalSize(6_861_935_454) == "6.86 GB",
              LMStudioModelCatalog.decimalSize(6_861_935_454))

        guard case .install(let modelOnly)? = PointOfUsePolicy.offer(
            for: .email, presences: lmStudioWithoutTheModel, bootstrap: coreInstalled) else {
            check("a measured offer quotes the measured number", false)
            return
        }
        check("a measured offer quotes the measured number",
              modelOnly.lines.first?.hasSuffix("6.86 GB.") == true, modelOnly.lines.first ?? "")

        // The chain includes LM Studio, whose size is unmeasurable until its URL resolves (O4). A total
        // that silently dropped it would be a user-facing byte count nobody measured.
        guard case .install(let chained)? = PointOfUsePolicy.offer(
            for: .email, presences: claudeOnly, bootstrap: coreInstalled) else {
            check("an unmeasurable component suppresses the total", false)
            return
        }
        check("an unmeasurable component suppresses the total", chained.totalDownloadBytes == nil)
        // The number that IS measured stays, because it is true and the user needs it. What must not
        // happen is a measured part being presented as the whole: an offer that installs LM Studio too
        // has to say so in the same breath, or 6.86 GB reads as the size of a larger download.
        check("a measured part is never quoted as if it were the whole",
              chained.lines.first == "Email mode uses \(LMStudioInstaller.gemmaModelID), "
                + "6.86 GB plus LM Studio.",
              chained.lines.first ?? "")
        check("the Install now button quotes the same qualified size",
              chained.buttons.first?.detail == "Downloads 6.86 GB plus LM Studio.",
              chained.buttons.first?.detail ?? "")
        check("every offer that quotes a size either has a measured total or names what is missing",
              PointOfUseFeature.all.allSatisfy { feature in
                  [bareMachine, claudeOnly, lmStudioWithoutTheModel, gemmaInstalled].allSatisfy { machine in
                      guard case .install(let offer)? = PointOfUsePolicy.offer(
                          for: feature, presences: machine, bootstrap: freshBootstrap) else { return true }
                      let quotesSize = (offer.lines + offer.buttons.map(\.detail))
                          .contains { $0.contains(" GB") || $0.contains(" MB") }
                      guard quotesSize else { return true }
                      if offer.totalDownloadBytes != nil { return true }
                      let unnamed = offer.components.filter { $0.downloadBytes == nil }.map(\.title)
                      return unnamed.allSatisfy { title in
                          offer.lines.contains { $0.contains("plus \(title)") }
                      }
                  }
              })
    }

    // MARK: - B10 / O7

    private static func checkCopy(_ check: SelfTestReporter) {
        var record = BootstrapComponentRecord(id: BootstrapInstallPlan.gemma.id, title: "gemma")
        record.apply(InstallerComponentResult(
            componentID: record.id, title: record.title,
            state: .failed(InstallerFailure(category: .transport,
                                            message: "Could not resolve host: huggingface.co"),
                           attempts: 3)))
        let line = PointOfUsePolicy.progressLine(record)
        check("a failed row shows the vendor's own words",
              line.contains("Could not resolve host: huggingface.co"), line)

        let banned = ["Setup failed", "Please try again", "Something went wrong", "An error occurred"]
        var everyString: [String] = [PointOfUsePolicy.keyHint, line]
        for feature in PointOfUseFeature.all {
            for machine in [bareMachine, claudeOnly, lmStudioWithoutTheModel] {
                guard let offer = PointOfUsePolicy.offer(for: feature, presences: machine,
                                                         bootstrap: freshBootstrap) else { continue }
                everyString.append(offer.header)
                everyString.append(contentsOf: offer.lines)
                everyString.append(contentsOf: offer.buttons.map(\.title))
                everyString.append(contentsOf: offer.buttons.map(\.detail))
            }
        }
        check("no surface string is a generic setup message",
              !everyString.contains { candidate in banned.contains { candidate.contains($0) } })
        check("every surface string is non-empty", !everyString.contains(where: \.isEmpty))
        check("no progress line promises a time",
              !everyString.contains { $0.lowercased().contains("remaining")
                  || $0.lowercased().contains("eta") })
        check("a running row says the download survives closing the panel",
              PointOfUsePolicy.progressLine(BootstrapComponentRecord(
                id: "x", title: "Row", phase: .installing)) == "Row   installing")
    }

    // MARK: - the installer

    /// A local-app performer that fails a scripted number of times, then succeeds. Its readiness step always
    /// succeeds and consumes no scripted failure, so every count below is the app or model step's alone.
    private final class ScriptedPerformer: InstallerLocalPerforming {
        private var remaining: [Error]
        private(set) var applicationCalls = 0
        private(set) var modelCalls: [String] = []

        init(failures: [Error]) { self.remaining = failures }

        func installApplication(_ backend: LocalBackendID,
                                report: @escaping (InstallerLocalActivity) -> Void) throws {
            applicationCalls += 1
            if !remaining.isEmpty { throw remaining.removeFirst() }
        }

        func makeReady(_ backend: LocalBackendID, report: @escaping (InstallerLocalActivity) -> Void) throws {}

        func installModel(_ ref: LocalModelRef, report: @escaping (InstallerLocalActivity) -> Void) throws {
            modelCalls.append(ref.modelID)
            if !remaining.isEmpty { throw remaining.removeFirst() }
        }
    }

    private static func engine(_ performer: InstallerLocalPerforming) -> InstallerEngine {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("point-of-use-\(UUID().uuidString)", isDirectory: true)
        return InstallerEngine(
            paths: InstallerPaths(python: URL(fileURLWithPath: "/nonexistent/python"),
                                  applicationSupport: scratch,
                                  modelCache: scratch.appendingPathComponent("cache"),
                                  packageCache: scratch.appendingPathComponent("package-cache")),
            local: performer,
            sleep: { _ in })
    }

    private static func checkEngine(_ check: SelfTestReporter) {
        check("an LM Studio row is a descriptor, not a special case",
              BootstrapInstallPlan.gemma.localSteps == [
                .ready(.lmStudio), .model(LocalModelRef(backend: .lmStudio, modelID: LMStudioInstaller.gemmaModelID))])
        check("an LM Studio row owns no python environment",
              BootstrapInstallPlan.lmStudio.virtualEnvironmentRelativePath == nil)
        check("the shipped component list is the core plus the optional rows",
              BootstrapInstallPlan.allComponents.map(\.id)
                == (BootstrapInstallPlan.mandatoryCore + BootstrapInstallPlan.optionalLocalModels)
                    .map(\.id))
        check("adding an optional row does not change what setup requires",
              BootstrapSnapshot.mandatoryCoreIDs == BootstrapInstallPlan.mandatoryCore.map(\.id))

        let clean = ScriptedPerformer(failures: [])
        let installed = engine(clean).install(BootstrapInstallPlan.gemma)
        check("a model row delegates to LM Studio's own CLI and reports installed",
              installed.succeeded && clean.modelCalls == [LMStudioInstaller.gemmaModelID],
              clean.modelCalls.joined(separator: ","))

        // O5, on the arm this link added: transport retries, a 4xx does not, and a verification failure
        // never does. The rule is the engine's, so this is the same policy the pip rows already obey.
        let flaky = ScriptedPerformer(failures: [LMStudioInstaller.InstallerError.network("connection reset")])
        let recovered = engine(flaky).install(BootstrapInstallPlan.lmStudio)
        check("a transport failure is retried and can succeed",
              recovered.succeeded && flaky.applicationCalls == 2, "\(flaky.applicationCalls) attempts")

        let notFound = ScriptedPerformer(failures: (0..<5).map { _ in
            LMStudioInstaller.InstallerError.httpStatus(404) })
        let refused = engine(notFound).install(BootstrapInstallPlan.lmStudio)
        check("a 404 is not retried", !refused.succeeded && notFound.applicationCalls == 1,
              "\(notFound.applicationCalls) attempts")

        let serverError = ScriptedPerformer(failures: (0..<5).map { _ in
            LMStudioInstaller.InstallerError.httpStatus(503) })
        let exhausted = engine(serverError).install(BootstrapInstallPlan.lmStudio)
        check("a 5xx is retried exactly three times",
              !exhausted.succeeded && serverError.applicationCalls == InstallerRetryPolicy.maxAttempts,
              "\(serverError.applicationCalls) attempts")

        let unverified = ScriptedPerformer(failures: (0..<5).map { _ in
            LMStudioInstaller.InstallerError.invalidDMG("downloaded 12 bytes; expected 900000000") })
        let rejected = engine(unverified).install(BootstrapInstallPlan.lmStudio)
        check("a disk image that failed verification is never retried into a pass",
              !rejected.succeeded && unverified.applicationCalls == 1,
              "\(unverified.applicationCalls) attempts")
        if case .failed(let failure, _) = rejected.state {
            check("and the row keeps the real verification text",
                  failure.message.contains("expected 900000000") && failure.category == .checksumMismatch,
                  failure.message)
        } else {
            check("and the row keeps the real verification text", false)
        }

        // A refused overwrite is the safety rule L3 built, seen from the queue: never retried, and the
        // reason is preserved rather than becoming "setup failed".
        let occupied = ScriptedPerformer(failures: (0..<5).map { _ in
            LMStudioInstaller.InstallerError.destinationExists(
                URL(fileURLWithPath: "/Applications/LM Studio.app")) })
        let refusedOverwrite = engine(occupied).install(BootstrapInstallPlan.lmStudio)
        check("refusing to overwrite an existing install is not retried",
              !refusedOverwrite.succeeded && occupied.applicationCalls == 1)

        // Plan validation: a row that installs packages without an environment, and a row with no work
        // at all, are both plan bugs rather than things to discover mid-download.
        let noEnvironment = InstallerComponentDescriptor(
            id: "broken", title: "Broken", packages: [InstallerPackage(name: "requests")])
        let empty = InstallerComponentDescriptor(id: "idle", title: "Idle")
        for (descriptor, name) in [(noEnvironment, "packages without an environment"),
                                   (empty, "a row with no work")] {
            let result = engine(ScriptedPerformer(failures: [])).install(descriptor)
            if case .failed(let failure, _) = result.state {
                check("\(name) is rejected as an invalid plan", failure.category == .invalidPlan,
                      failure.message)
            } else {
                check("\(name) is rejected as an invalid plan", false)
            }
        }
    }

    // MARK: - B17

    private static func checkGuidance(_ check: SelfTestReporter) {
        let claudeAbsent = LLMProviderDetection.Presence(
            installed: false, state: .unavailable("CLI unavailable"))
        let claudeStep = ProviderOnboarding.step(for: .claude, presence: claudeAbsent)
        check("an absent Claude CLI is given the one command that installs it",
              claudeStep.installGuidance?.command == "npm install -g @anthropic-ai/claude-code",
              claudeStep.installGuidance?.command ?? "nil")
        check("and a link to the vendor's own docs",
              claudeStep.installGuidance?.links.first?.url.absoluteString
                == "https://docs.claude.com/en/docs/claude-code/setup")
        check("an absent CLI still offers no sign-in action, because there is nothing to sign in to",
              claudeStep.action == nil)

        let codexAbsent = LLMProviderDetection.Presence(
            installed: false, state: .unavailable("the codex CLI is not installed"))
        let codexStep = ProviderOnboarding.step(for: .codex, presence: codexAbsent)
        check("Codex is deliberately given no command, because its CLI ships inside an app",
              codexStep.installGuidance != nil && codexStep.installGuidance?.command == nil)
        check("Codex still gets a link and a sentence",
              codexStep.installGuidance?.links.isEmpty == false
                && codexStep.installGuidance?.summary.isEmpty == false)

        for (situation, presence) in [
            ("signed out", LLMProviderDetection.Presence(installed: true, state: .disconnected)),
            ("ready", LLMProviderDetection.Presence(installed: true, state: .available)),
        ] {
            let step = ProviderOnboarding.step(for: .claude, presence: presence)
            check("a \(situation) provider is not told to install anything",
                  step.installGuidance == nil)
        }
        check("the narrow Terminal exception is not widened to Local",
              ProviderOnboarding.installGuidance(for: .local) == nil)

        // The point-of-use chooser enters this surface rather than a second one.
        let plan = ProviderOnboarding.plan(providers: [
            .claude: claudeAbsent, .codex: codexAbsent,
            .local: LLMProviderDetection.Presence(installed: false,
                                                  state: .unavailable("LM Studio is not installed"))])
        check("the guided window can answer about one provider only",
              plan.focused(on: .claude).steps.map(\.provider) == [.claude],
              plan.focused(on: .claude).steps.map { $0.provider.rawValue }.joined(separator: ","))
    }

    // MARK: - identity

    private static func checkIdentifiers(_ check: SelfTestReporter) {
        var identifiers = [PointOfUsePolicy.surfaceIdentifier, PointOfUsePolicy.headerIdentifier,
                           PointOfUsePolicy.footerIdentifier]
        identifiers += (0..<6).map(PointOfUsePolicy.lineIdentifier)
        identifiers += [PointOfUsePolicy.installButtonID, PointOfUsePolicy.skipButtonID,
                        PointOfUsePolicy.claudeButtonID, PointOfUsePolicy.codexButtonID,
                        PointOfUsePolicy.localButtonID].map(PointOfUsePolicy.buttonIdentifier)
        identifiers += BootstrapInstallPlan.allComponents.map {
            PointOfUsePolicy.progressIdentifier($0.id)
        }
        check("no two controls on the offer panel claim the same identifier",
              Set(identifiers).count == identifiers.count,
              "\(Set(identifiers).count) of \(identifiers.count)")
        check("every shipped component has a distinct id",
              Set(BootstrapInstallPlan.allComponents.map(\.id)).count
                == BootstrapInstallPlan.allComponents.count)
    }
}
