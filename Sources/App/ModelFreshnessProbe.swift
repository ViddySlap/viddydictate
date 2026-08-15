import Foundation
import Darwin

enum ModelFreshnessProbeState: String, Codable, Equatable {
    case resolved
    case unknown
    case failed
}

struct ModelFreshnessResolution: Codable, Equatable {
    var state: ModelFreshnessProbeState
    var modelID: String?
    var failureKind: String?

    static func resolved(_ modelID: String) -> ModelFreshnessResolution {
        ModelFreshnessResolution(state: .resolved, modelID: modelID, failureKind: nil)
    }

    static let unknown = ModelFreshnessResolution(
        state: .unknown, modelID: nil, failureKind: "explicit-model-unknown")

    static func failed(_ kind: String) -> ModelFreshnessResolution {
        ModelFreshnessResolution(state: .failed, modelID: nil, failureKind: kind)
    }
}

/// Alias resolutions only. The held-candidate map this used to carry belonged to the opportunistic
/// upgrade path ADR 0014 removed; a decoder simply ignores the key in an older file on disk.
struct ModelFreshnessCache: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var checkedAt: String
    var resolutions: [String: ModelFreshnessResolution]

    init(version: Int = currentVersion, checkedAt: String,
         resolutions: [String: ModelFreshnessResolution]) {
        self.version = version
        self.checkedAt = checkedAt
        self.resolutions = resolutions
    }
}

/// Headless Claude alias resolution. Callers must gate every live probe on dictation-idle. The probe
/// uses the same allowlisted environment, argument builder, process group, and watchdog as production
/// Claude transforms. It sends only the fixed one-token string "x" and never receives user text.
enum ModelFreshnessProbe {
    static let aliases = ["sonnet", "haiku"]
    static let defaultTimeout: TimeInterval = 45

    static var defaultCacheURL: URL {
        AppPaths.applicationSupportDirectory()
            .appendingPathComponent("model-freshness.json", isDirectory: false)
    }

    static func checkedAtString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parse the one model in the probed alias family. Ambiguous or missing usage fails closed.
    static func resolvedModelID(fromJSON text: String, alias: String) -> String? {
        let familyPrefix: String
        switch alias.lowercased() {
        case "sonnet": familyPrefix = "claude-sonnet"
        case "haiku": familyPrefix = "claude-haiku"
        case "opus": familyPrefix = "claude-opus"
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String] = {
            if let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
                as? [String: Any], let usage = object["modelUsage"] as? [String: Any] {
                return usage.keys.sorted()
            }
            guard let brace = trimmed.firstIndex(of: "{") else { return [] }
            let tail = String(trimmed[brace...])
            guard let object = (try? JSONSerialization.jsonObject(with: Data(tail.utf8)))
                    as? [String: Any],
                  let usage = object["modelUsage"] as? [String: Any] else { return [] }
            return usage.keys.sorted()
        }()
        let nonempty = candidates.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let familyMatches = nonempty.filter { $0.hasPrefix(familyPrefix) }
        return familyMatches.count == 1 ? familyMatches[0] : nil
    }

    /// Only explicit CLI model-registry failures count as deprecation. A normal transform failure does
    /// not flow into this predicate and therefore can never retire a route.
    static func explicitlyReportsUnknownModel(stdout: String, stderr: String) -> Bool {
        let text = "\(stdout)\n\(stderr)".lowercased()
        return text.contains("unknown model")
            || text.contains("model not found")
            || text.contains("invalid model")
            || text.contains("model is not available")
            || text.contains("model is no longer available")
    }

    static func loadCache(from url: URL = defaultCacheURL) -> ModelFreshnessCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelFreshnessCache.self, from: data)
    }

    static func save(_ cache: ModelFreshnessCache, to url: URL = defaultCacheURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cache).write(to: url, options: .atomic)
    }

    /// The live probe is exactly one fixed one-token call for each Claude alias.
    ///
    /// It answers "can Claude run right now, and what does each alias currently point at" — an
    /// availability and display signal. It is NOT a retirement signal: since ADR 0014 the Claude
    /// catalog owns retirement detection, so this no longer probes pinned model ids one by one, and an
    /// alias resolving to a newer model no longer moves any route.
    static func probeAliases(at date: Date = Date(), binary: String? = nil,
                             cacheURL: URL = defaultCacheURL) throws -> ModelFreshnessCache {
        let checkedAt = checkedAtString(date)
        let references = Array(Set(aliases)).sorted()
        var results: [String: ModelFreshnessResolution] = [:]

        func persisted(_ resolutions: [String: ModelFreshnessResolution]) throws
            -> ModelFreshnessCache {
            let cache = ModelFreshnessCache(checkedAt: checkedAt, resolutions: resolutions)
            try save(cache, to: cacheURL)
            return cache
        }

        guard let executable = binary ?? CloudCleanupClient.resolveBinary() else {
            for reference in references { results[reference] = .failed("cli-unavailable") }
            return try persisted(results)
        }
        guard LLMProviderDetection.observeClaude(binary: executable).state.canRun else {
            for reference in references { results[reference] = .failed("subscription-unavailable") }
            return try persisted(results)
        }

        for reference in references {
            results[reference] = runOneTokenProbe(executable: executable, modelReference: reference)
        }
        return try persisted(results)
    }

    private static func runOneTokenProbe(executable: String,
                                         modelReference: String) -> ModelFreshnessResolution {
        let promptDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("viddydictate-model-freshness-\(UUID().uuidString)",
                                    isDirectory: true)
        let promptFile = promptDirectory.appendingPathComponent("system-prompt.txt")
        do {
            try FileManager.default.createDirectory(
                at: promptDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data("Reply with exactly one token: OK".utf8).write(to: promptFile, options: .atomic)
            _ = chmod(promptDirectory.path, 0o700)
            _ = chmod(promptFile.path, 0o600)
        } catch {
            try? FileManager.default.removeItem(at: promptDirectory)
            return .failed("prompt-file")
        }
        defer { try? FileManager.default.removeItem(at: promptDirectory) }

        let childEnvironment = CloudCleanupClient.buildEnv(from: ProcessInfo.processInfo.environment)
        let environmentArguments = childEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        let claudeArguments = CloudCleanupClient.buildArgs(
            systemPromptFilePath: promptFile.path, model: modelReference)
        let shellScript = "printf x | \"$@\""
        let arguments = ["-i"] + environmentArguments
            + ["/bin/sh", "-c", shellScript, "vd-model-freshness", executable]
            + claudeArguments
        guard let run = CloudCleanupClient.runProcessForTest(
            executable: "/usr/bin/env", arguments: arguments,
            timeout: defaultTimeout, grace: 2) else {
            return .failed("process-setup")
        }
        let stdout = String(decoding: run.stdout, as: UTF8.self)
        let stderr = String(decoding: run.stderr, as: UTF8.self)
        guard !run.timedOut && !run.terminatedBySignal
                && CloudCleanupClient.processGroupExitWasClean(
                    leaderReaped: run.leaderReaped,
                    residualProcessGroup: run.residualProcessGroup) else {
            return .failed("process-timeout-or-signal")
        }
        if run.exitCode == 0,
           let modelID = resolvedModelID(fromJSON: stdout, alias: modelReference) {
            return .resolved(modelID)
        }
        if explicitlyReportsUnknownModel(stdout: stdout, stderr: stderr) { return .unknown }
        return .failed(run.exitCode == 0 ? "missing-model-usage" : "cli-error")
    }
}

struct PresetUpdateRoute: Equatable {
    var route: LLMRouteID
    var bundle: LLMProviderBundle
}

enum PresetUpdateDisposition: Equatable {
    case unchanged
    case swapped(LLMAutoUpdateReason)
    /// The catalog was acquired but could not judge this pin. Carries the planner's reason so the
    /// surface can say which of "not a Claude id", "family not served", "successor unusable" it was.
    case held(ModelMigrationHoldReason)
    /// No usable catalog this check, so no route can be judged at all. Reported once for the provider
    /// rather than once per route.
    case catalogUnavailable
    case codexDetectOnly
}

struct PresetUpdateDecision: Equatable {
    var route: LLMRouteID
    var originalBundle: LLMProviderBundle
    var resultingBundle: LLMProviderBundle
    var disposition: PresetUpdateDisposition
}

/// Pure Claude preset policy, driven by the provider-neutral catalog seam.
///
/// ADR 0014: a route moves only when Claude RETIRED its pin, and a merely newer model is ignored.
/// Before this the Claude arm resolved the `sonnet`/`haiku` alias and adopted whatever it pointed at,
/// which shipped untested quality changes to other people's machines; that arm is gone, and a
/// `.recommend` from any source is deliberately treated as no change rather than as a candidate.
///
/// A retirement swap is NOT gated on a smoke of the replacement. The guarantee ADR 0014 buys is that
/// the app never runs on a dead model, and holding a route on a model the provider has already deleted
/// in order to wait for a smoke would trade that guarantee away for a weaker one. The Codex arm can
/// afford to hold because a Codex preset stays listed after retirement; a deleted Claude model does
/// not. Codex routes stay detect-only here — `CodexModelUpdater` owns their qualification and
/// compare-and-swap — and Local routes are untouched.
enum PresetUpdatePolicy {
    static func decide(routes: [PresetUpdateRoute],
                       checkedAt: String,
                       migration: [LLMRouteID: ModelMigrationAction]) -> [PresetUpdateDecision] {
        routes.map { route -> PresetUpdateDecision in
            let original = route.bundle
            func decision(_ disposition: PresetUpdateDisposition,
                          resulting: LLMProviderBundle = original) -> PresetUpdateDecision {
                PresetUpdateDecision(
                    route: route.route, originalBundle: original,
                    resultingBundle: resulting, disposition: disposition)
            }

            switch original.provider {
            case .local:
                return decision(.unchanged)
            case .codex:
                return decision(.codexDetectOnly)
            case .claude:
                break
            }

            switch migration[route.route] {
            case nil:
                return decision(.catalogUnavailable)
            case .unchanged, .recommend:
                return decision(.unchanged)
            case .hold(let reason):
                return decision(.held(reason))
            case .migrate(let destination):
                var replacement = original
                replacement.version = LLMProviderBundle.currentVersion
                replacement.modelID = destination.model
                // Claude carries the stored effort across a migration unchanged; the empty string is
                // the planner's spelling for "this pin had no level", which stays no level.
                replacement.effort = destination.effort.isEmpty ? nil : destination.effort
                replacement.autoUpdated = LLMAutoUpdateProvenance(
                    fromModelID: original.modelID, date: checkedAt, reason: .deprecation)
                return decision(.swapped(.deprecation), resulting: replacement)
            }
        }
    }
}
