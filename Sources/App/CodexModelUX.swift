import Foundation

struct CodexPickerModelOption: Equatable {
    let model: String
    let label: String
    let efforts: [String]
}

/// Picker policy over the validated last-known-good cache. Executable model strings remain opaque
/// represented values; preset ids never enter this surface and display names are presentation only.
enum CodexPickerCatalog {
    static func visibleOptions(_ catalog: ModelCatalog?) -> [CodexPickerModelOption] {
        guard let catalog else { return [] }
        return catalog.rows.compactMap { row in
            guard !row.hidden,
                  row.inputModalities == nil || row.inputModalities?.contains("text") == true else {
                return nil
            }
            return CodexPickerModelOption(
                model: row.model,
                label: modelLabel(displayName: row.displayName, model: row.model),
                efforts: row.supportedReasoningEfforts.map(\.reasoningEffort))
        }
    }

    static func efforts(
        for model: String,
        catalog: ModelCatalog?
    ) -> [String]? {
        visibleOptions(catalog).first { $0.model == model }?.efforts
    }

    static func applyingModelSelection(
        _ model: String,
        to bundle: LLMProviderBundle
    ) -> LLMProviderBundle {
        var selected = bundle
        if selected.modelID != model {
            selected.ratified = nil
            selected.autoUpdated = nil
        }
        selected.modelID = model
        return selected
    }

    static func applyingEffortSelection(
        _ effort: String,
        to bundle: LLMProviderBundle
    ) -> LLMProviderBundle {
        var selected = bundle
        let resolved = effort.isEmpty ? nil : effort
        if selected.effort != resolved {
            selected.ratified = nil
            selected.autoUpdated = nil
        }
        selected.effort = resolved
        return selected
    }

    private static func modelLabel(displayName: String?, model: String) -> String {
        let safeModel = safeLabel(model)
        guard let displayName else { return safeModel }
        let safeDisplay = safeLabel(displayName)
        guard !safeDisplay.isEmpty, safeDisplay != safeModel else { return safeModel }
        return "\(safeDisplay) — \(safeModel)"
    }

    static func safeLabel(_ raw: String, maxCharacters: Int = 160) -> String {
        let singleLine = raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        return String(singleLine.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexUpdateRecordState: String, Codable, Equatable {
    case checkPending = "check_pending"
    case checkedUnchanged = "checked_unchanged"
    case routesMigrated = "routes_migrated"
    case recommendationAvailable = "recommendation_available"
    case candidateHeld = "candidate_held"
    case classificationHeld = "classification_held"
    case staleCatalog = "stale_catalog"
    case compatibilityQuarantinePending = "compatibility_quarantine_pending"
    case compatibilityQuarantinePassed = "compatibility_quarantine_passed"
    case compatibilityQuarantineFailed = "compatibility_quarantine_failed"
    case persistenceFailed = "persistence_failed"
    case checkCoalesced = "check_coalesced"
}

/// Deliberately contains only timestamps and fixed outcome/reason codes. Catalog rows, display copy,
/// provider stdout/stderr, URLs, and user content have no field in this schema.
struct CodexUpdateOutcomeRecord: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let state: CodexUpdateRecordState
    let lastAttempt: String
    let lastSuccessfulCatalogTime: String?
    let reasonCode: String?
    let nextRetry: String?

    init(
        version: Int = currentVersion,
        state: CodexUpdateRecordState,
        lastAttempt: String,
        lastSuccessfulCatalogTime: String?,
        reasonCode: String?,
        nextRetry: String?
    ) {
        self.version = version
        self.state = state
        self.lastAttempt = lastAttempt
        self.lastSuccessfulCatalogTime = lastSuccessfulCatalogTime
        self.reasonCode = reasonCode
        self.nextRetry = nextRetry
    }

    var isValid: Bool {
        version == Self.currentVersion
            && Self.isTimestamp(lastAttempt)
            && lastSuccessfulCatalogTime.map(Self.isTimestamp) != false
            && (reasonCode?.utf8.count ?? 0) <= 128
            && nextRetry.map(Self.isTimestamp) != false
            && reasonCode.map(Self.allowedReasonCodes.contains) != false
    }

    private static func isTimestamp(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 128 else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw) != nil
    }

    private static let allowedReasonCodes: Set<String> =
        Set([
            "compatibility_pending",
            "check_pending",
            "compatibility_boundary",
            "compatibility_accepted",
            "settings_persistence",
            "qualification_failed",
            "candidate_held",
            "single_flight",
        ])
        .union(ModelCatalogDiagnostic.allCases.map { "catalog_\($0.rawValue)" })
        .union(ModelMigrationHoldReason.allCases.map {
            "planner_\($0.rawValue)"
        })
}

final class CodexUpdateOutcomeStore {
    static let didChange = Notification.Name("VDCodexUpdateOutcomeDidChange")
    typealias Writer = (Data, URL) throws -> Void

    static let shared = CodexUpdateOutcomeStore(
        url: AppPaths.applicationSupportDirectory()
            .appendingPathComponent("codex-update-outcome.json", isDirectory: false))

    private let lock = NSLock()
    private let url: URL
    private let writer: Writer
    private var stored: CodexUpdateOutcomeRecord?

    init(
        url: URL,
        writer: @escaping Writer = CodexUpdateOutcomeStore.atomicWriter
    ) {
        self.url = url
        self.writer = writer
        stored = Self.load(url: url)
    }

    var latest: CodexUpdateOutcomeRecord? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func beginAttempt(at lastAttempt: String, nextRetry: String?) {
        let prior = latest
        publish(CodexUpdateOutcomeRecord(
            state: .checkPending,
            lastAttempt: lastAttempt,
            lastSuccessfulCatalogTime: prior?.lastSuccessfulCatalogTime,
            reasonCode: "check_pending",
            nextRetry: nextRetry))
    }

    func markCompatibilityQuarantinePending(at lastAttempt: String) {
        let prior = latest
        publish(CodexUpdateOutcomeRecord(
            state: .compatibilityQuarantinePending,
            lastAttempt: lastAttempt,
            lastSuccessfulCatalogTime: prior?.lastSuccessfulCatalogTime,
            reasonCode: "compatibility_pending",
            nextRetry: prior?.nextRetry))
    }

    func markCompatibilityQuarantineFinished(
        success: Bool,
        at lastAttempt: String
    ) {
        let prior = latest
        publish(CodexUpdateOutcomeRecord(
            state: success
                ? .compatibilityQuarantinePassed
                : .compatibilityQuarantineFailed,
            lastAttempt: lastAttempt,
            lastSuccessfulCatalogTime: prior?.lastSuccessfulCatalogTime,
            reasonCode: success
                ? "compatibility_accepted"
                : "compatibility_boundary",
            nextRetry: prior?.nextRetry))
    }

    @discardableResult
    func complete(
        _ outcome: CodexModelUpdateOutcome,
        nextRetry: String?
    ) -> CodexUpdateOutcomeRecord {
        let prior = latest
        let attempt = outcome.checkedAt ?? prior?.lastAttempt
            ?? ModelFreshnessProbe.checkedAtString(Date())
        let state: CodexUpdateRecordState
        let reason: String?
        let successfulCatalogTime: String?

        switch outcome.status {
        case .catalogFailed(.compatibilityBoundary):
            state = .compatibilityQuarantineFailed
            reason = "compatibility_boundary"
            successfulCatalogTime = prior?.lastSuccessfulCatalogTime
        case .catalogFailed(let diagnostic):
            state = .staleCatalog
            reason = "catalog_\(diagnostic.rawValue)"
            successfulCatalogTime = prior?.lastSuccessfulCatalogTime
        case .persistenceFailed:
            state = .persistenceFailed
            reason = "settings_persistence"
            successfulCatalogTime = outcome.checkedAt ?? prior?.lastSuccessfulCatalogTime
        case .held:
            if !outcome.held.isEmpty {
                state = .candidateHeld
                reason = "qualification_failed"
            } else if outcome.blockingPlannerHolds.isEmpty,
                      let first = CodexUpdateSurface.surfacedPlannerHold(
                        for: outcome) {
                state = .classificationHeld
                reason = "planner_\(first.value.rawValue)"
            } else if let first = CodexUpdateSurface.surfacedPlannerHold(
                for: outcome) {
                state = .candidateHeld
                reason = "planner_\(first.value.rawValue)"
            } else {
                state = .candidateHeld
                reason = "candidate_held"
            }
            successfulCatalogTime = outcome.checkedAt ?? prior?.lastSuccessfulCatalogTime
        case .current:
            if !outcome.applied.isEmpty {
                state = .routesMigrated
            } else if !outcome.recommendations.isEmpty {
                state = .recommendationAvailable
            } else {
                state = .checkedUnchanged
            }
            reason = nil
            successfulCatalogTime = outcome.checkedAt ?? prior?.lastSuccessfulCatalogTime
        case .coalesced:
            state = .checkCoalesced
            reason = "single_flight"
            successfulCatalogTime = prior?.lastSuccessfulCatalogTime
        }

        let record = CodexUpdateOutcomeRecord(
            state: state,
            lastAttempt: attempt,
            lastSuccessfulCatalogTime: successfulCatalogTime,
            reasonCode: reason,
            nextRetry: nextRetry)
        publish(record)
        return record
    }

    private func publish(_ record: CodexUpdateOutcomeRecord) {
        guard record.isValid else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= 16_384 else { return }
            try writer(data, url)
            lock.lock()
            stored = record
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } catch {
            UserDataWriteFailureCenter.report(
                subsystem: "Codex update outcome",
                operation: "save",
                url: url,
                error: error)
        }
    }

    private static func load(url: URL) -> CodexUpdateOutcomeRecord? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 16_384,
              let data = try? Data(contentsOf: url),
              data.count <= 16_384,
              let decoded = try? JSONDecoder().decode(
                CodexUpdateOutcomeRecord.self, from: data),
              decoded.isValid else {
            return nil
        }
        return decoded
    }

    static func atomicWriter(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

enum CodexUpdateSurface {
    static func statusText(_ record: CodexUpdateOutcomeRecord?) -> String {
        guard let record else { return "Codex catalog: never checked" }
        let retry = record.nextRetry.map { " · next retry \($0)" } ?? ""
        switch record.state {
        case .checkPending:
            return "Codex catalog/compatibility check pending\(retry)"
        case .checkedUnchanged:
            return "Codex catalog checked; routes unchanged\(retry)"
        case .routesMigrated:
            return "Codex routes migrated; replacements are unratified\(retry)"
        case .recommendationAvailable:
            return "Codex recommendation available; route unchanged\(retry)"
        case .candidateHeld:
            return "Codex candidate held (\(record.reasonCode ?? "candidate_held"))\(retry)"
        case .classificationHeld:
            let reasonCode = record.reasonCode ?? "candidate_held"
            let wording = classificationHoldWording(
                for: plannerHoldReason(from: reasonCode))
            return "Codex route classification held (\(reasonCode)); \(wording)\(retry)"
        case .staleCatalog:
            if record.lastSuccessfulCatalogTime == nil {
                return "Codex catalog unavailable (\(record.reasonCode ?? "catalog_failure")); no last-known-good catalog is available\(retry)"
            }
            return "Codex catalog stale (\(record.reasonCode ?? "catalog_failure")); using last-known-good picker data\(retry)"
        case .compatibilityQuarantinePending:
            return "Codex compatibility quarantine pending\(retry)"
        case .compatibilityQuarantinePassed:
            return "Codex compatibility quarantine passed; catalog not yet checked\(retry)"
        case .compatibilityQuarantineFailed:
            return "Codex compatibility quarantine failed; routes unchanged\(retry)"
        case .persistenceFailed:
            return "Codex settings update could not be saved; routes unchanged\(retry)"
        case .checkCoalesced:
            return "Codex catalog check coalesced with one already running\(retry)"
        }
    }

    static func toastLines(for outcome: CodexModelUpdateOutcome) -> [String] {
        switch outcome.status {
        case .catalogFailed(.compatibilityBoundary):
            return ["Codex compatibility quarantine failed; routes unchanged"]
        case .catalogFailed(let diagnostic):
            return [
                "Codex catalog stale or unavailable (\(diagnostic.rawValue)); routes unchanged",
            ]
        case .persistenceFailed:
            return ["Codex settings update could not be saved; routes unchanged"]
        case .held:
            if !outcome.held.isEmpty {
                return ["Codex candidate held; qualification failed"]
            }
            let hold = surfacedPlannerHold(for: outcome)
            let reason = hold?.value.rawValue ?? "candidate_held"
            if outcome.blockingPlannerHolds.isEmpty,
               !outcome.plannerHolds.isEmpty {
                return [
                    "Codex route classification held (\(reason)); "
                        + classificationHoldWording(for: hold?.value),
                ]
            }
            return ["Codex candidate held (\(reason)); route unchanged"]
        case .coalesced:
            return ["Codex catalog check coalesced with one already running"]
        case .current:
            var lines: [String] = []
            if !outcome.applied.isEmpty {
                lines.append("Codex routes migrated; replacements are unratified")
            }
            if !outcome.recommendations.isEmpty {
                lines.append("Codex recommendation available; route unchanged")
            }
            if lines.isEmpty {
                lines.append("Codex catalog checked; routes unchanged")
            }
            return lines
        }
    }

    static func requiresFullToast(_ outcome: CodexModelUpdateOutcome) -> Bool {
        switch outcome.status {
        case .current:
            return !outcome.applied.isEmpty || !outcome.recommendations.isEmpty
        case .coalesced:
            return false
        case .held, .catalogFailed, .persistenceFailed:
            return true
        }
    }

    static func surfacedPlannerHold(
        for outcome: CodexModelUpdateOutcome
    ) -> (key: LLMRouteID, value: ModelMigrationHoldReason)? {
        let holds = outcome.plannerHolds.sorted {
            $0.key.rawValue < $1.key.rawValue
        }
        guard !outcome.blockingPlannerHolds.isEmpty else {
            return holds.first
        }
        let blocking = Set(outcome.blockingPlannerHolds)
        return holds.first { blocking.contains($0.key) } ?? holds.first
    }

    private static func plannerHoldReason(
        from reasonCode: String
    ) -> ModelMigrationHoldReason? {
        let prefix = "planner_"
        guard reasonCode.hasPrefix(prefix) else { return nil }
        return ModelMigrationHoldReason(
            rawValue: String(reasonCode.dropFirst(prefix.count)))
    }

    private static func classificationHoldWording(
        for reason: ModelMigrationHoldReason?
    ) -> String {
        switch reason {
        case .invalidStoredModel?,
             .invalidStoredEffort?,
             .invalidCatalogIdentifier?,
             .duplicateCatalogID?,
             .duplicateCatalogModel?,
             .invalidEffortCatalog?,
             .unknownSource?,
             nil:
            return "route remains runnable and unchanged; catalog visibility is not established"
        default:
            return "visible route remains runnable and unchanged"
        }
    }
}

/// Launch-local memory for the Codex-only scheduled rail. Persisted timestamps and retry times do
/// not retrigger a full HUD: only the content-free state/reason classification does.
struct CodexScheduledToastGate {
    private struct Signature: Equatable {
        let state: CodexUpdateRecordState
        let reasonCode: String?
    }

    private var lastObserved: Signature?

    mutating func shouldPresentFullToast(
        for outcome: CodexModelUpdateOutcome,
        record: CodexUpdateOutcomeRecord
    ) -> Bool {
        let current = Signature(
            state: record.state,
            reasonCode: record.reasonCode)
        let isFirstObservation = lastObserved == nil
        let changed = current != lastObserved
        lastObserved = current
        return CodexUpdateSurface.requiresFullToast(outcome)
            && (isFirstObservation || changed)
    }
}
