import Foundation
import Darwin

/// The one owner of "can this provider run right now, and is it even installed".
///
/// Before this existed the derivation lived in two places — the cloud update check's inline ladder and
/// the Codex connection controller's publish switch — and preflight (W5) needed a third. Three copies of
/// one rule is exactly the duplicate-concept the chain post-mortem forbids, so the rule moved here and
/// both original call sites now read it from this type.
///
/// Everything above the `live` mark is pure: it takes measured facts and returns a state. The live half
/// performs the measurements and is deliberately a 1:1 transcription of existing accessors, so all of the
/// judgement stays in the pure half where the deterministic rail can reach it.
enum LLMProviderDetection {
    /// The content-safe subset of `claude auth status --json`. The command also returns account
    /// identity fields; ViddyDictate neither needs nor retains them.
    struct ClaudeAuthStatus: Equatable {
        let loggedIn: Bool
        let authMethod: String
        let apiProvider: String
        let subscriptionType: String?
    }

    /// A real status response is kept distinct from a missing measuring apparatus and from vendor
    /// output that claimed success without satisfying the JSON contract. The services gate may
    /// abstain only on `.apparatusUnavailable`; `.invalidResponse` is a blocking protocol failure.
    enum ClaudeAuthStatusObservation: Equatable {
        case status(ClaudeAuthStatus)
        case apparatusUnavailable(String)
        case invalidResponse(String)
    }


    /// A provider's installed-ness alongside its runnable state. The two are separate questions with
    /// separate remedies — "install it" versus "sign in to it" — and `LLMProviderAvailabilityState` alone
    /// cannot answer the first.
    struct Presence: Equatable {
        let installed: Bool
        let state: LLMProviderAvailabilityState
        /// Local-only installed model catalog. nil means discovery could not answer; an empty list is a
        /// measured zero-model state. Cloud presences leave this nil. For `.local` it is every running local
        /// app's models, each tagged with its app: LM Studio's first, then Ollama's, each in its own order.
        let availableLocalModels: [LMStudioModelOption]?
        /// Each local app's own reading, for a `.local` presence built by `observeLocal`. nil for a cloud
        /// presence and for one built by hand: `installed` then says only "some local app", so a caller that
        /// needs one app in particular (the LM Studio install offer) falls back to the merged fields.
        let localBackendReadings: [LocalBackendReading]?

        init(installed: Bool, state: LLMProviderAvailabilityState,
             availableLocalModels: [LMStudioModelOption]? = nil,
             localBackendReadings: [LocalBackendReading]? = nil) {
            self.installed = installed
            self.state = state
            self.availableLocalModels = availableLocalModels
            self.localBackendReadings = localBackendReadings
        }

        /// One app's reading, or nil when this presence carries no per-app breakdown.
        func localReading(_ backend: LocalBackendID) -> LocalBackendReading? {
            localBackendReadings?.first { $0.backend == backend }
        }

        /// The installed local apps, or nil when this presence carries no per-app breakdown.
        var installedLocalBackends: Set<LocalBackendID>? {
            localBackendReadings.map { Set($0.filter(\.installed).map(\.backend)) }
        }
    }

    // MARK: - Pure derivations

    /// Claude Code owns both of its credential stores, so its own status command is the only
    /// connection authority. The method check is deliberately a whitelist: an unknown future value
    /// remains a named unsupported state instead of silently gaining subscription privileges.
    static func claudeState(binaryFound: Bool,
                            authStatus: ClaudeAuthStatusObservation)
        -> LLMProviderAvailabilityState {
        if !binaryFound { return .unavailable("CLI unavailable") }
        switch authStatus {
        case .status(let status):
            guard status.loggedIn else { return .disconnected }
            guard status.authMethod == "claude.ai" else {
                return .unavailable(
                    "signed in with Claude auth method \(status.authMethod); "
                        + "ViddyDictate does not support it yet")
            }
            return .available
        case .apparatusUnavailable:
            return .unavailable("Claude auth status unavailable")
        case .invalidResponse:
            return .unavailable("Claude auth status response invalid")
        }
    }

    /// The fuller question the cloud update check asks after it has also run a `--version` probe and the
    /// live alias probe: the connection authority above, then the two further ways a present, supported
    /// CLI can still fail to run.
    static func claudeState(connectionState: LLMProviderAvailabilityState,
                            versionResolved: Bool,
                            aliasProbeFailed: Bool) -> LLMProviderAvailabilityState {
        guard connectionState.canRun else { return connectionState }
        if !versionResolved { return .unavailable("CLI version check failed") }
        if aliasProbeFailed { return .unavailable("live alias probe failed") }
        return .available
    }

    /// Parse fixture or live JSON without retaining account identity fields. Required strings are
    /// short provider metadata tokens; bounding and restricting them keeps a future vendor value
    /// safe to place in a user-facing diagnostic.
    static func parseClaudeAuthStatus(_ data: Data) -> ClaudeAuthStatus? {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool,
              let authMethod = boundedStatusToken(object["authMethod"]),
              let apiProvider = boundedStatusToken(object["apiProvider"]) else {
            return nil
        }
        let subscriptionType: String?
        if !object.keys.contains("subscriptionType") {
            // Current Claude CLI omits subscriptionType from its logged-out response and exits 1.
            // A logged-in response without the field is still malformed.
            guard !loggedIn else { return nil }
            subscriptionType = nil
        } else if object["subscriptionType"] is NSNull {
            subscriptionType = nil
        } else {
            guard let value = boundedStatusToken(object["subscriptionType"]) else { return nil }
            subscriptionType = value
        }
        return ClaudeAuthStatus(
            loggedIn: loggedIn,
            authMethod: authMethod,
            apiProvider: apiProvider,
            subscriptionType: subscriptionType)
    }

    private static func boundedStatusToken(_ value: Any?) -> String? {
        guard let token = value as? String,
              !token.isEmpty, token.utf8.count <= 128,
              token.unicodeScalars.allSatisfy({
                  (0x20...0x7e).contains(Int($0.value))
              }) else {
            return nil
        }
        return token
    }

    // MARK: - Live Claude auth measurement

    /// Run the store-agnostic CLI status check with a short wall-clock bound. Both streams are
    /// drained concurrently so vendor diagnostics cannot deadlock the caller. No raw output is
    /// logged or returned: newer CLI builds include account identity fields in this JSON.
    static func claudeAuthStatus(
        binary: String,
        timeout: TimeInterval = 5,
        environment: [String: String] = CloudCleanupClient.buildEnv(
            from: ProcessInfo.processInfo.environment)
    ) -> ClaudeAuthStatusObservation {
        guard binary.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: binary) else {
            return .apparatusUnavailable("Claude CLI is not executable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "status", "--json"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return .apparatusUnavailable("Claude auth status could not start") }

        var stdout = Data()
        var stderr = Data()
        let outputDone = DispatchSemaphore(value: 0)
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            outputDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderr = errors.fileHandleForReading.readDataToEndOfFile()
            errorDone.signal()
        }

        guard exited.wait(timeout: .now() + max(0.1, timeout)) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = outputDone.wait(timeout: .now() + 1)
            _ = errorDone.wait(timeout: .now() + 1)
            return .apparatusUnavailable("Claude auth status timed out")
        }
        _ = outputDone.wait(timeout: .now() + 1)
        _ = errorDone.wait(timeout: .now() + 1)

        guard stdout.count <= 65_536, stderr.count <= 65_536 else {
            return .invalidResponse("Claude auth status output exceeded its bound")
        }
        if let parsed = parseClaudeAuthStatus(stdout) {
            if process.terminationReason == .exit, process.terminationStatus == 0 {
                return .status(parsed)
            }
            // Claude CLI spells a real logged-out state as well-formed JSON plus exit 1. Preserve
            // that state instead of collapsing it into apparatus failure.
            if !parsed.loggedIn { return .status(parsed) }
            return .invalidResponse(
                "Claude auth status returned logged-in JSON with a nonzero exit")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .apparatusUnavailable(
                "Claude auth status exited \(process.terminationStatus) before returning JSON")
        }
        return .invalidResponse("Claude auth status returned malformed JSON")
    }

    // MARK: - Remaining pure derivations

    /// Codex reports its own connection state through the audited boundary; this is only the projection
    /// onto the routing/preflight vocabulary. `.disconnected` is the meaningful one: it is precisely
    /// "installed but signed out", which is what lets preflight offer a sign-in remedy rather than an
    /// install one.
    static func availability(from state: CodexConnectionState) -> LLMProviderAvailabilityState {
        switch state {
        case .connected: return .available
        case .disconnected: return .disconnected
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    /// Local is the optional post-V1 power path (locked decision 1), so "not installed" is an ordinary
    /// state rather than a defect. The two reasons are distinct because they have distinct remedies.
    /// A running LM Studio server without a registered LLM is not a runnable Local provider.
    static func localState(lmsInstalled: Bool,
                           serverResponding: Bool)
        -> LLMProviderAvailabilityState {
        if !lmsInstalled { return .unavailable("LM Studio is not installed") }
        if !serverResponding { return .unavailable("LM Studio is not running") }
        return .available
    }

    /// Catalog-aware Local state. A nil catalog means the measuring apparatus did not answer; an empty
    /// catalog is a measured zero-model state. Both are unavailable for text execution.
    static func localState(lmsInstalled: Bool,
                           serverResponding: Bool,
                           availableModels: [LMStudioModelOption]?)
        -> LLMProviderAvailabilityState {
        if !lmsInstalled { return .unavailable("LM Studio is not installed") }
        if !serverResponding { return .unavailable("LM Studio is not running") }
        if let availableModels, availableModels.isEmpty {
            return .unavailable("no local models installed")
        }
        if availableModels == nil {
            return .unavailable("local model catalog unavailable")
        }
        return .available
    }

    /// Measure Local once, retaining the catalog beside the provider state so execution can distinguish a
    /// missing preferred model from a machine with no local model at all. Synchronous and process-spawning;
    /// callers must invoke it off the main thread.
    struct LocalObservation: Equatable {
        let presence: Presence
        let models: [LMStudioModelOption]?
    }

    /// What one local app measured as, before the merge. `startAttempted` records that observation opened
    /// the app and it still did not answer inside the bounded poll, which changes what the user is told.
    struct LocalBackendReading: Equatable {
        let backend: LocalBackendID
        let installed: Bool
        let responding: Bool
        /// Its routable models, tagged with its app. nil when it is not responding or its catalog did not
        /// answer; empty is a measured zero-model app.
        let models: [LMStudioModelOption]?
        /// Only an Ollama desktop app is ever started (see `LocalModelBackend.backgroundLaunchPath`).
        let startable: Bool
        let startAttempted: Bool
        /// Set when ViddyDictate will not use this installed app at all (`LocalModelBackend.localOnlyRefusal`):
        /// it was not probed, read or started, and this is the reason the user is given.
        let refusal: String?

        init(backend: LocalBackendID, installed: Bool, responding: Bool, models: [LMStudioModelOption]?,
             startable: Bool = false, startAttempted: Bool = false, refusal: String? = nil) {
            self.backend = backend
            self.installed = installed
            self.responding = responding
            self.models = models
            self.startable = startable
            self.startAttempted = startAttempted
            self.refusal = refusal
        }

        /// Running with at least one model it can route to.
        var isUsable: Bool { responding && !(models ?? []).isEmpty }
    }

    /// How observation may start a local app that is installed but not answering (spec D2, step 1). Every
    /// side effect is a closure, so a gate records the launch instead of performing it; `.never` is the
    /// default everywhere except the two production observers (launch hydration and preflight).
    ///
    /// The start is attempted at most ONCE per observation, only for an app that is the backend of some Local
    /// route pin or is the Preferred local app, only when that app has a `backgroundLaunchPath`, and then
    /// polled for at most `pollTimeout` before one re-probe. LM Studio is never started here (its server
    /// comes up lazily inside the load, as in 1.1.0), and neither is a CLI-only Ollama.
    struct LocalBackendStarter {
        /// The backends of every Local route pin, independent of what is installed.
        let pinnedBackends: Set<LocalBackendID>
        /// The explicit Preferred local app, nil for automatic. Resolved against what is installed with
        /// `LocalBackendPreference.effective` once the installs are measured.
        let preferredExplicit: LocalBackendID?
        /// Open the app at this path in the background. Production runs `open -g <path>`.
        let launch: (String) -> Void
        let pollTimeout: TimeInterval
        let pollInterval: TimeInterval
        let now: () -> Date
        let sleep: (TimeInterval) -> Void

        /// Starts nothing: no app is a target and the launch closure is inert.
        static let never = LocalBackendStarter(
            pinnedBackends: [], preferredExplicit: nil, launch: { _ in }, pollTimeout: 0, pollInterval: 0,
            now: { Date() }, sleep: { _ in })

        /// The bound on the post-open poll. Long enough for an installed app to bring its server up; a
        /// first-run app waiting on its macOS prompt (Mac probe B3) never answers, and costs this one wait
        /// followed by guidance, not a hang.
        static let defaultPollTimeout: TimeInterval = 10
        static let defaultPollInterval: TimeInterval = 0.5

        /// Production: the current Local route pins and the stored Preferred local app.
        static func live(store: ModelsPowerSettingsStore = Settings.modelsPower) -> LocalBackendStarter {
            let pinned = Set(store.routeIDs().compactMap { route -> LocalBackendID? in
                let bundle = store.selectedBundle(for: route)
                return bundle.provider == .local ? bundle.resolvedLocalBackend : nil
            })
            return LocalBackendStarter(
                pinnedBackends: pinned, preferredExplicit: Settings.preferredLocalBackend,
                launch: LLMProviderDetection.openInBackground, pollTimeout: defaultPollTimeout,
                pollInterval: defaultPollInterval, now: { Date() }, sleep: { Thread.sleep(forTimeInterval: $0) })
        }

        /// The apps observation may start this time, given what is installed.
        func targets(installed: Set<LocalBackendID>) -> Set<LocalBackendID> {
            pinnedBackends.union([
                LocalBackendPreference.effective(explicit: preferredExplicit, installed: installed),
            ])
        }
    }

    /// The copy for an Ollama app observation opened that still did not answer. A fresh install does not
    /// start its server until the user answers macOS's "install its command line tool" prompt (Mac probe
    /// B3), which ViddyDictate must never automate, so this tells the user what to do rather than a state.
    static let ollamaDidNotStartReason =
        "Ollama didn't start. Open Ollama and approve its macOS prompt, then try again."

    /// One app's reason for not being usable, in its own name. `soleApp` is true when it is the only local
    /// app installed: LM Studio then keeps its exact 1.1.0 strings (the catalog-neutral ones included), and
    /// Ollama's mirror them.
    static func localReason(_ reading: LocalBackendReading, soleApp: Bool) -> String {
        let name = reading.backend.displayName
        if !reading.installed { return "\(name) is not installed" }
        if let refusal = reading.refusal { return refusal }
        if !reading.responding {
            if reading.startAttempted { return ollamaDidNotStartReason }
            // A CLI-only Ollama is a daemon the user runs; say what is true and nothing more.
            if reading.backend == .ollama && !reading.startable { return "Ollama is installed but not running" }
            return "\(name) is not running"
        }
        if let models = reading.models, models.isEmpty {
            return soleApp ? "no local models installed" : "\(name) has no models installed"
        }
        return soleApp ? "local model catalog unavailable" : "\(name)'s model catalog is unavailable"
    }

    /// Merge every local app's reading into the ONE `.local` presence routing and preflight read. Pure.
    ///
    /// - Available when ANY app is running with at least one routable model.
    /// - The catalog is every responding app's models, in `readings` order (LM Studio, then Ollama). nil only
    ///   when no app's catalog answered at all, which keeps "unmeasured" distinct from "empty".
    /// - With LM Studio the only app installed, every field is exactly what the single-app `localState`
    ///   produced in 1.1.0. With neither installed the reason names both apps; with both installed and
    ///   neither usable it gives each app's own reason.
    static func mergedLocalPresence(_ readings: [LocalBackendReading]) -> Presence {
        let installed = readings.filter(\.installed)
        let answered = readings.compactMap(\.models)
        let models: [LMStudioModelOption]? = answered.isEmpty ? nil : answered.flatMap { $0 }

        let state: LLMProviderAvailabilityState
        if readings.contains(where: \.isUsable) {
            state = .available
        } else if installed.isEmpty {
            state = .unavailable(readings.count > 1
                ? readings.map(\.backend.displayName).joined(separator: " and ") + " are not installed"
                : readings.first.map { localReason($0, soleApp: true) } ?? "local model availability not measured")
        } else if installed.count == 1 {
            state = .unavailable(localReason(installed[0], soleApp: true))
        } else {
            state = .unavailable(installed.map { localReason($0, soleApp: false) }.joined(separator: "; "))
        }
        return Presence(installed: !installed.isEmpty, state: state, availableLocalModels: models,
                        localBackendReadings: readings)
    }

    /// The local apps production observes, in merge order.
    static func liveLocalBackends() -> [LocalModelBackend] {
        [LMStudioBackend(), OllamaBackend()]
    }

    /// Measure every local app and merge them. Each app is probed exactly as far as it can answer: not
    /// installed stops there, not responding stops before the catalog. LM Studio's probe runs the same three
    /// `lms` reads 1.1.0's single-app observation ran, in the same order.
    ///
    /// Before a non-responding app is written off, `starter` may open it once (see `LocalBackendStarter`),
    /// wait for it within the bound, and re-probe. The default starts nothing, so a gate or a diagnostic
    /// that calls this can never launch an app.
    static func observeLocal(backends: [LocalModelBackend] = liveLocalBackends(),
                             starter: LocalBackendStarter = .never) -> LocalObservation {
        let installedFlags = backends.map { $0.isInstalled() }
        let installedSet = Set(zip(backends, installedFlags).filter { $0.1 }.map { $0.0.id })
        let targets = starter.targets(installed: installedSet)

        var readings: [LocalBackendReading] = []
        for (backend, installed) in zip(backends, installedFlags) {
            guard installed else {
                readings.append(LocalBackendReading(
                    backend: backend.id, installed: false, responding: false, models: nil))
                continue
            }
            let launchPath = backend.backgroundLaunchPath
            if let refusal = backend.localOnlyRefusal {
                // Not on this Mac: no probe, no catalog, no start, so nothing is ever sent there.
                Log.write("local: \(backend.id.displayName) is not used: \(refusal)")
                readings.append(LocalBackendReading(
                    backend: backend.id, installed: true, responding: false, models: nil,
                    startable: launchPath != nil, refusal: refusal))
                continue
            }
            var responding = backend.serverResponds()
            var attempted = false
            if !responding, let launchPath, targets.contains(backend.id) {
                attempted = true
                Log.write("local: \(backend.id.displayName) is installed but not answering; "
                    + "opening it in the background")
                starter.launch(launchPath)
                responding = waitForServer(backend, starter: starter)
            }
            let models = responding ? backend.routableModelOptions() : nil
            readings.append(LocalBackendReading(
                backend: backend.id, installed: true, responding: responding, models: models,
                startable: launchPath != nil, startAttempted: attempted && !responding))
        }

        let presence = mergedLocalPresence(readings)
        return LocalObservation(presence: presence, models: presence.availableLocalModels)
    }

    /// Poll `serverResponds` until it answers or `pollTimeout` passes, sleeping `pollInterval` between
    /// probes. Bounded by the injected clock, so a scripted gate that never answers still ends.
    private static func waitForServer(_ backend: LocalModelBackend, starter: LocalBackendStarter) -> Bool {
        let deadline = starter.now().addingTimeInterval(starter.pollTimeout)
        repeat {
            starter.sleep(starter.pollInterval)
            if backend.serverResponds() { return true }
        } while starter.now() < deadline
        return false
    }

    /// `open -g <path>`: launch without taking focus. By path, never by name (see `backgroundLaunchPath`).
    /// Waits for `open` itself, which returns once LaunchServices has the request, not for the app, and
    /// never longer than a few seconds: a wedged `open` must not hold the observation past its own bound.
    static func openInBackground(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch {
            Log.write("local: could not open \(path) in the background")
            return
        }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { process.terminate() }
            Log.write("local: open of \(path) did not return in time")
        }
    }

    // MARK: - Live measurement

    /// Measure every provider. Synchronous and process-spawning (the Codex boundary audit and the `lms`
    /// probe both shell out), so call it OFF the main thread.
    ///
    /// The Claude arm deliberately runs only `auth status`: the `--version` and live-alias probes belong
    /// to the scheduled cloud update check, and re-running them on every preflight would charge a
    /// user-initiated status refresh for work that answers a different question.
    static func observeAll(codexState: @autoclosure () -> CodexConnectionState
                            = CodexProviderRuntime.connectionState(),
                           localStarter: @autoclosure () -> LocalBackendStarter = .live())
        -> [LLMProvider: Presence] {
        let claude = observeClaude()

        let codexInstalled = CodexCLILocation.resolve().candidate != nil
        let local = observeLocal(starter: localStarter())
        return [
            .claude: claude,
            .codex: codexPresence(cliFound: codexInstalled, state: codexInstalled ? codexState() : nil),
            .local: local.presence,
        ]
    }

    /// The Setup/Preflight row's two Codex failures stay distinct: no CLI at any supported location is
    /// "not installed" (install ChatGPT.app), while a CLI the boundary could not sandbox is "installed
    /// but not usable" with the sandbox sentence. The boundary audit is only meaningful when the vendor
    /// binary exists, and a boundary that itself reports not found (the CLI vanished mid-check) wins.
    static func codexPresence(cliFound: Bool, state: CodexConnectionState?) -> Presence {
        guard cliFound, let state else {
            return Presence(installed: false, state: .unavailable("the codex CLI is not installed"))
        }
        if case .unavailable(let reason) = state, reason == CodexProviderRuntime.codexNotFoundMessage {
            return Presence(installed: false, state: .unavailable(reason))
        }
        return Presence(installed: true, state: availability(from: state))
    }

    /// The single live owner for Claude connection state. Callers may pass an already-resolved
    /// binary to avoid resolving the same path twice; no caller supplies a connection verdict.
    static func observeClaude(binary: String? = CloudCleanupClient.resolveBinary()) -> Presence {
        guard let binary else {
            return Presence(installed: false, state: .unavailable("CLI unavailable"))
        }
        let authStatus = claudeAuthStatus(binary: binary)
        return Presence(
            installed: true,
            state: claudeState(binaryFound: true, authStatus: authStatus))
    }
}
